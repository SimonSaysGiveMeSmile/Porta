package tunnel

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Conn is the transport the Tunnel drives. A real WebSocket conn or an
// in-memory pipe (for tests) can both satisfy it.
type Conn interface {
	WriteMessage(data []byte) error
	ReadMessage() ([]byte, error)
	Close() error
}

// Tunnel is a sender-side reverse proxy: the edge writes OpOpen/OpBody/OpEnd
// frames for inbound receiver requests, the sender writes OpHead/OpBody/OpEnd
// frames back as responses.
type Tunnel struct {
	conn    Conn
	writeMu sync.Mutex

	mu       sync.Mutex
	requests map[RequestID]*Request
	closed   bool
	closeErr error
}

type Request struct {
	ID RequestID

	Head    chan HeadMessage // size 1
	Body    chan []byte      // buffered
	Err     chan error       // size 1
	Done    chan struct{}    // closed on end
	cancel  chan struct{}    // closed when receiver disconnects
	closeFn func()
}

var (
	ErrTunnelClosed = errors.New("tunnel: closed")
	ErrRequestGone  = errors.New("tunnel: request not found")
	ErrCancelled    = errors.New("tunnel: cancelled by receiver")
)

func New(c Conn) *Tunnel {
	return &Tunnel{
		conn:     c,
		requests: map[RequestID]*Request{},
	}
}

// Run pumps inbound frames until the connection ends. Intended to run in its
// own goroutine. Returns when conn.ReadMessage errors.
func (t *Tunnel) Run() error {
	for {
		raw, err := t.conn.ReadMessage()
		if err != nil {
			t.shutdown(err)
			return err
		}
		op, id, payload, err := decodeFrame(raw)
		if err != nil {
			continue
		}
		t.dispatch(op, id, payload)
	}
}

func (t *Tunnel) dispatch(op byte, id RequestID, payload []byte) {
	t.mu.Lock()
	req := t.requests[id]
	t.mu.Unlock()
	if req == nil {
		return // stray frame for an already-finished request
	}
	switch op {
	case OpHead:
		var h HeadMessage
		if err := json.Unmarshal(payload, &h); err != nil {
			t.failRequest(req, err)
			return
		}
		select {
		case req.Head <- h:
		default:
		}
	case OpBody:
		chunk := make([]byte, len(payload))
		copy(chunk, payload)
		select {
		case req.Body <- chunk:
		case <-req.cancel:
		}
	case OpEnd:
		req.finish()
	case OpErr:
		t.failRequest(req, errors.New(string(payload)))
	}
}

func (t *Tunnel) failRequest(req *Request, err error) {
	select {
	case req.Err <- err:
	default:
	}
	req.finish()
}

// Open begins a new reverse-proxied request. The caller should feed request
// body chunks via WriteBody/CloseBody (not yet used for GET), and read head
// + body out of the returned Request.
func (t *Tunnel) Open(ctx context.Context, header OpenHeader) (*Request, error) {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil, ErrTunnelClosed
	}
	id := RequestID(uuid.New())
	req := &Request{
		ID:     id,
		Head:   make(chan HeadMessage, 1),
		Body:   make(chan []byte, 32),
		Err:    make(chan error, 1),
		Done:   make(chan struct{}),
		cancel: make(chan struct{}),
	}
	var once sync.Once
	req.closeFn = func() {
		once.Do(func() {
			close(req.Done)
			close(req.Body)
		})
	}
	t.requests[id] = req
	t.mu.Unlock()

	payload, err := json.Marshal(header)
	if err != nil {
		t.removeRequest(id)
		return nil, err
	}
	if err := t.writeFrame(OpOpen, id, payload); err != nil {
		t.removeRequest(id)
		return nil, err
	}

	// Receiver-context cancellation → push OpCancel to sender.
	if ctx != nil {
		go func() {
			select {
			case <-ctx.Done():
				_ = t.writeFrame(OpCancel, id, nil)
				close(req.cancel)
				req.finish()
			case <-req.Done:
			}
		}()
	}

	return req, nil
}

func (t *Tunnel) removeRequest(id RequestID) {
	t.mu.Lock()
	delete(t.requests, id)
	t.mu.Unlock()
}

func (r *Request) finish() { r.closeFn() }

// ReadBody returns an io.Reader that concatenates body chunks. EOF is
// delivered when OpEnd arrives; an ErrCancelled is returned if the receiver
// disconnected mid-stream.
func (r *Request) ReadBody() io.Reader { return &bodyReader{r: r} }

type bodyReader struct {
	r   *Request
	buf []byte
}

func (br *bodyReader) Read(p []byte) (int, error) {
	if len(br.buf) == 0 {
		select {
		case b, ok := <-br.r.Body:
			if !ok {
				select {
				case err := <-br.r.Err:
					return 0, err
				default:
					return 0, io.EOF
				}
			}
			br.buf = b
		case <-br.r.cancel:
			return 0, ErrCancelled
		}
	}
	n := copy(p, br.buf)
	br.buf = br.buf[n:]
	return n, nil
}

// writeFrame serializes writes to the underlying conn; WS writes are not
// concurrency-safe so we serialize everything through writeMu.
func (t *Tunnel) writeFrame(op byte, id RequestID, payload []byte) error {
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	return t.conn.WriteMessage(encodeFrame(op, id, payload))
}

// Close terminates all in-flight requests and closes the underlying conn.
func (t *Tunnel) Close() error {
	t.shutdown(ErrTunnelClosed)
	return t.conn.Close()
}

func (t *Tunnel) shutdown(cause error) {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return
	}
	t.closed = true
	t.closeErr = cause
	reqs := t.requests
	t.requests = map[RequestID]*Request{}
	t.mu.Unlock()
	for _, r := range reqs {
		t.failRequest(r, cause)
	}
}

// Ping writes an empty OpEnd to a zero request ID as a liveness probe.
// (Simple — no PING opcode needed for MVP; real impl would add one.)
func (t *Tunnel) Ping(_ time.Duration) error {
	return t.writeFrame(OpEnd, RequestID{}, nil)
}
