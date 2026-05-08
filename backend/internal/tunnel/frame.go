// Package tunnel implements the sender-initiated reverse proxy that lets a
// phone expose file bytes to a browser without a public IP.
//
// Flow:
//  1. Sender opens an outbound WebSocket to /v1/tunnel. This is the tunnel.
//  2. A receiver GETs /p/<sessionId>/...; the edge finds the tunnel for that
//     session's share and forwards the request as a framed message.
//  3. Sender reads the request, streams the response back in BODY frames.
//
// The tunnel multiplexes many concurrent requests by tagging every frame with
// a 16-byte requestID. The wire format is deliberately tiny so that porting
// to a Cloudflare Worker later (or re-implementing in Swift) is straightforward.
package tunnel

import (
	"encoding/binary"
	"errors"
)

// Opcodes. Single byte at the start of every frame.
const (
	OpOpen   byte = 0x01 // edge → sender: begin request; payload = JSON header
	OpHead   byte = 0x02 // sender → edge: response head; payload = JSON head
	OpBody   byte = 0x03 // bidi:           body chunk; payload = raw bytes
	OpEnd    byte = 0x04 // bidi:           end of body; no payload
	OpErr    byte = 0x05 // sender → edge: error; payload = utf-8 message
	OpCancel byte = 0x06 // edge → sender: receiver disconnected; abort
)

// frameHeaderLen = opcode(1) + requestID(16).
const frameHeaderLen = 1 + 16

// RequestID is the raw bytes of a UUIDv4.
type RequestID [16]byte

var (
	ErrFrameTooShort = errors.New("tunnel: frame too short")
)

// encodeFrame prepends a 17-byte header to payload.
// The frame is binary and fits in one WebSocket message.
func encodeFrame(op byte, id RequestID, payload []byte) []byte {
	buf := make([]byte, frameHeaderLen+len(payload))
	buf[0] = op
	copy(buf[1:17], id[:])
	copy(buf[17:], payload)
	return buf
}

func decodeFrame(raw []byte) (op byte, id RequestID, payload []byte, err error) {
	if len(raw) < frameHeaderLen {
		err = ErrFrameTooShort
		return
	}
	op = raw[0]
	copy(id[:], raw[1:17])
	payload = raw[frameHeaderLen:]
	return
}

// OpenHeader is the JSON payload of an OpOpen frame.
type OpenHeader struct {
	Method  string              `json:"method"`
	Path    string              `json:"path"`
	Headers map[string][]string `json:"headers,omitempty"`
}

// HeadMessage is the JSON payload of an OpHead frame.
type HeadMessage struct {
	Status  int                 `json:"status"`
	Headers map[string][]string `json:"headers,omitempty"`
}

// For tests that want to examine the header bytes directly.
var _ = binary.BigEndian
