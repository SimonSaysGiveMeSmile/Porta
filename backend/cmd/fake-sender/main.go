// Command fake-sender runs the full sender flow end-to-end without an iOS
// device. Handy for local verification + CI smoke tests. It:
//
//  1. Generates an Ed25519 keypair in memory.
//  2. Registers with the backend (nonce → sign → JWT).
//  3. Creates a share for a single file on disk.
//  4. Opens the reverse tunnel WebSocket.
//  5. Polls GET /v1/sessions/pending and auto-approves anything that lands.
//  6. Serves OpOpen requests by streaming the file back through the tunnel.
//
// Flags:
//   -backend  http URL of the Porta backend           (default http://localhost:8080)
//   -file     file to serve                            (required)
//   -title    optional share title
//
// Intended for local dev and CI only. Do NOT deploy this — it auto-approves
// every incoming request.
package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

// --- Wire format --- (must match backend/internal/tunnel/frame.go) ---

const (
	opOpen   byte = 0x01
	opHead   byte = 0x02
	opBody   byte = 0x03
	opEnd    byte = 0x04
	opErr    byte = 0x05
	opCancel byte = 0x06
)

type openHeader struct {
	Method  string              `json:"method"`
	Path    string              `json:"path"`
	Headers map[string][]string `json:"headers,omitempty"`
}
type headMessage struct {
	Status  int                 `json:"status"`
	Headers map[string][]string `json:"headers,omitempty"`
}

func encodeFrame(op byte, id [16]byte, payload []byte) []byte {
	out := make([]byte, 17+len(payload))
	out[0] = op
	copy(out[1:17], id[:])
	copy(out[17:], payload)
	return out
}
func decodeFrame(raw []byte) (op byte, id [16]byte, payload []byte, ok bool) {
	if len(raw) < 17 {
		return 0, id, nil, false
	}
	op = raw[0]
	copy(id[:], raw[1:17])
	return op, id, raw[17:], true
}

// --- API client ---

type apiClient struct {
	baseURL *url.URL
	http    *http.Client
	jwt     string
}

func (a *apiClient) do(method, path string, body any, out any) error {
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, a.baseURL.ResolveReference(&url.URL{Path: path}).String(), rdr)
	if rdr != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if a.jwt != "" {
		req.Header.Set("Authorization", "Bearer "+a.jwt)
	}
	resp, err := a.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%s %s: %d %s", method, path, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// --- Main ---

func main() {
	var (
		backend = flag.String("backend", "http://localhost:8080", "Porta backend URL")
		path    = flag.String("file", "", "file to share (required)")
		title   = flag.String("title", "", "optional share title")
	)
	flag.Parse()
	if *path == "" {
		log.Fatal("-file is required")
	}
	st, err := os.Stat(*path)
	if err != nil {
		log.Fatalf("stat %s: %v", *path, err)
	}

	baseURL, err := url.Parse(*backend)
	if err != nil {
		log.Fatalf("bad -backend: %v", err)
	}

	api := &apiClient{baseURL: baseURL, http: &http.Client{Timeout: 30 * time.Second}}

	// 1. Keypair.
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		log.Fatal(err)
	}

	// 2. Nonce → sign → JWT.
	var nonceResp struct{ Nonce string }
	if err := api.do("POST", "/v1/auth/nonce", nil, &nonceResp); err != nil {
		log.Fatalf("nonce: %v", err)
	}
	nonceBytes, err := base64.RawURLEncoding.DecodeString(nonceResp.Nonce)
	if err != nil {
		log.Fatalf("bad nonce encoding: %v", err)
	}
	sig := ed25519.Sign(priv, nonceBytes)

	var verifyResp struct {
		DeviceID string `json:"device_id"`
		JWT      string `json:"jwt"`
	}
	if err := api.do("POST", "/v1/auth/verify", map[string]string{
		"public_key": b64url(pub),
		"nonce":      nonceResp.Nonce,
		"signature":  b64url(sig),
		"platform":   "cli",
	}, &verifyResp); err != nil {
		log.Fatalf("verify: %v", err)
	}
	api.jwt = verifyResp.JWT
	log.Printf("device registered: %s", verifyResp.DeviceID)

	// 3. Create share.
	filename := filepath.Base(*path)
	var share struct {
		ID        string `json:"id"`
		Token     string `json:"token"`
		ShareURL  string `json:"share_url"`
		ExpiresAt string `json:"expires_at"`
	}
	if err := api.do("POST", "/v1/shares", map[string]any{
		"title": *title,
		"files": []map[string]any{{"name": filename, "size": st.Size()}},
	}, &share); err != nil {
		log.Fatalf("create share: %v", err)
	}
	fmt.Println("share id:      ", share.ID)
	fmt.Println("share url:     ", share.ShareURL)
	fmt.Println()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	// 4. Open tunnel.
	wsURL := *baseURL
	if wsURL.Scheme == "https" {
		wsURL.Scheme = "wss"
	} else {
		wsURL.Scheme = "ws"
	}
	wsURL.Path = "/v1/tunnel"
	q := wsURL.Query()
	q.Set("share", share.ID)
	q.Set("token", api.jwt)
	wsURL.RawQuery = q.Encode()

	ws, _, err := websocket.DefaultDialer.DialContext(ctx, wsURL.String(), nil)
	if err != nil {
		log.Fatalf("tunnel dial: %v", err)
	}
	defer ws.Close()
	log.Println("tunnel open")

	var writeMu sync.Mutex
	writeFrame := func(op byte, id [16]byte, payload []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return ws.WriteMessage(websocket.BinaryMessage, encodeFrame(op, id, payload))
	}

	// 5. Auto-approver: poll for pending sessions and approve them.
	go runApprover(ctx, api)

	// 6. Frame loop.
	for {
		if ctx.Err() != nil {
			return
		}
		_ = ws.SetReadDeadline(time.Time{})
		_, raw, err := ws.ReadMessage()
		if err != nil {
			if !errors.Is(err, net.ErrClosed) && ctx.Err() == nil {
				log.Printf("read: %v", err)
			}
			return
		}
		op, id, payload, ok := decodeFrame(raw)
		if !ok || op != opOpen {
			continue
		}
		var oh openHeader
		if err := json.Unmarshal(payload, &oh); err != nil {
			continue
		}
		log.Printf("→ %s %s", oh.Method, oh.Path)
		go serveOpen(id, oh, *path, filename, writeFrame)
	}
}

func runApprover(ctx context.Context, api *apiClient) {
	tick := time.NewTicker(1 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		var pending struct {
			Sessions []struct {
				ID string `json:"id"`
			} `json:"sessions"`
		}
		if err := api.do("GET", "/v1/sessions/pending", nil, &pending); err != nil {
			continue
		}
		for _, s := range pending.Sessions {
			if err := api.do("POST", "/v1/sessions/"+s.ID+"/approve", nil, nil); err != nil {
				log.Printf("approve %s: %v", s.ID, err)
			} else {
				log.Printf("approved session %s", s.ID)
			}
		}
	}
}

func serveOpen(id [16]byte, oh openHeader, path, filename string, writeFrame func(byte, [16]byte, []byte) error) {
	f, err := os.Open(path)
	if err != nil {
		writeErr(id, err.Error(), writeFrame)
		return
	}
	defer f.Close()
	st, _ := f.Stat()

	head, _ := json.Marshal(headMessage{
		Status: 200,
		Headers: map[string][]string{
			"Content-Type":        {"application/octet-stream"},
			"Content-Length":      {fmt.Sprint(st.Size())},
			"Content-Disposition": {`attachment; filename="` + filename + `"`},
		},
	})
	if err := writeFrame(opHead, id, head); err != nil {
		return
	}

	buf := make([]byte, 64*1024)
	for {
		n, err := f.Read(buf)
		if n > 0 {
			if werr := writeFrame(opBody, id, buf[:n]); werr != nil {
				return
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			writeErr(id, err.Error(), writeFrame)
			return
		}
	}
	_ = writeFrame(opEnd, id, nil)
}

func writeErr(id [16]byte, msg string, writeFrame func(byte, [16]byte, []byte) error) {
	_ = writeFrame(opErr, id, []byte(msg))
	_ = writeFrame(opEnd, id, nil)
}

// Silence unused warnings for RequestID (we use raw arrays here).
var _ = uuid.Nil
var _ = binary.BigEndian
