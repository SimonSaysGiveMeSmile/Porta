package tunnel

import (
	"context"
	"encoding/json"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// pipeConn is a symmetric pair of channels; one end's Write is the other's Read.
type pipeConn struct {
	in  chan []byte
	out chan []byte
	mu  sync.Mutex
	cl  bool
}

func newPipePair() (*pipeConn, *pipeConn) {
	a2b := make(chan []byte, 64)
	b2a := make(chan []byte, 64)
	return &pipeConn{in: b2a, out: a2b}, &pipeConn{in: a2b, out: b2a}
}

func (p *pipeConn) WriteMessage(b []byte) error {
	p.mu.Lock()
	closed := p.cl
	p.mu.Unlock()
	if closed {
		return io.ErrClosedPipe
	}
	cp := make([]byte, len(b))
	copy(cp, b)
	p.out <- cp
	return nil
}

func (p *pipeConn) ReadMessage() ([]byte, error) {
	b, ok := <-p.in
	if !ok {
		return nil, io.EOF
	}
	return b, nil
}

func (p *pipeConn) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.cl {
		p.cl = true
		close(p.out)
	}
	return nil
}

// TestTunnelRoundtrip runs the full edge ↔ sender handshake over an in-memory
// conn: edge opens a request, fake sender replies with head + 2 body chunks +
// end, edge reads the assembled body.
func TestTunnelRoundtrip(t *testing.T) {
	edgeConn, senderConn := newPipePair()

	edge := New(edgeConn)
	go edge.Run()

	// Fake sender: read the OpOpen, respond with head + body.
	senderDone := make(chan struct{})
	go func() {
		defer close(senderDone)
		raw, err := senderConn.ReadMessage()
		require.NoError(t, err)
		op, id, payload, err := decodeFrame(raw)
		require.NoError(t, err)
		require.Equal(t, OpOpen, op)

		var oh OpenHeader
		require.NoError(t, json.Unmarshal(payload, &oh))
		require.Equal(t, "GET", oh.Method)
		require.Equal(t, "/files/foo.txt", oh.Path)

		head, _ := json.Marshal(HeadMessage{Status: 200, Headers: map[string][]string{
			"Content-Type":   {"text/plain"},
			"Content-Length": {"11"},
		}})
		require.NoError(t, senderConn.WriteMessage(encodeFrame(OpHead, id, head)))
		require.NoError(t, senderConn.WriteMessage(encodeFrame(OpBody, id, []byte("hello "))))
		require.NoError(t, senderConn.WriteMessage(encodeFrame(OpBody, id, []byte("world"))))
		require.NoError(t, senderConn.WriteMessage(encodeFrame(OpEnd, id, nil)))
	}()

	req, err := edge.Open(context.Background(), OpenHeader{Method: "GET", Path: "/files/foo.txt"})
	require.NoError(t, err)

	select {
	case h := <-req.Head:
		require.Equal(t, 200, h.Status)
		require.Equal(t, "text/plain", h.Headers["Content-Type"][0])
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for head")
	}

	body, err := io.ReadAll(req.ReadBody())
	require.NoError(t, err)
	require.Equal(t, "hello world", string(body))

	<-senderDone
	require.NoError(t, edge.Close())
}

// TestTunnelCancelPropagates verifies that when the receiver-side context is
// cancelled, the sender gets an OpCancel frame.
func TestTunnelCancelPropagates(t *testing.T) {
	edgeConn, senderConn := newPipePair()
	edge := New(edgeConn)
	go edge.Run()

	ctx, cancel := context.WithCancel(context.Background())
	_, err := edge.Open(ctx, OpenHeader{Method: "GET", Path: "/big"})
	require.NoError(t, err)

	// Drain OpOpen off the sender side.
	_, err = senderConn.ReadMessage()
	require.NoError(t, err)

	cancel()

	select {
	case raw := <-readAsync(senderConn):
		op, _, _, err := decodeFrame(raw)
		require.NoError(t, err)
		require.Equal(t, OpCancel, op)
	case <-time.After(time.Second):
		t.Fatal("sender did not receive OpCancel")
	}

	require.NoError(t, edge.Close())
}

func readAsync(c *pipeConn) <-chan []byte {
	ch := make(chan []byte, 1)
	go func() {
		b, err := c.ReadMessage()
		if err == nil {
			ch <- b
		}
		close(ch)
	}()
	return ch
}

func TestHubRegisterEviction(t *testing.T) {
	h := NewHub()
	a := New(&pipeConn{})
	b := New(&pipeConn{})
	require.Nil(t, h.Register("share-1", a))
	prev := h.Register("share-1", b)
	require.Equal(t, a, prev)
	require.Equal(t, b, h.Get("share-1"))
	require.Equal(t, 1, h.Count())
	h.Unregister("share-1", b)
	require.Equal(t, 0, h.Count())
}

func TestHubUnregisterSkipsIfReplaced(t *testing.T) {
	h := NewHub()
	a := New(&pipeConn{})
	b := New(&pipeConn{})
	h.Register("share-1", a)
	h.Register("share-1", b) // eviction of a
	// Old owner calling Unregister should be a no-op.
	h.Unregister("share-1", a)
	require.Equal(t, b, h.Get("share-1"))
}
