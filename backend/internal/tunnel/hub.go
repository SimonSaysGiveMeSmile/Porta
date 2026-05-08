package tunnel

import (
	"sync"
)

// Hub tracks one active Tunnel per share ID. When a sender reconnects, the
// previous tunnel is evicted so the newest socket wins.
//
// Keyed by shareID.String() because that is what the public /p/ route
// resolves to after looking up the session.
type Hub struct {
	mu      sync.RWMutex
	tunnels map[string]*Tunnel
}

func NewHub() *Hub { return &Hub{tunnels: map[string]*Tunnel{}} }

// Register stores t under shareID. If another tunnel was already registered,
// it is returned so the caller can close it (duplicate-connect eviction).
func (h *Hub) Register(shareID string, t *Tunnel) *Tunnel {
	h.mu.Lock()
	defer h.mu.Unlock()
	prev := h.tunnels[shareID]
	h.tunnels[shareID] = t
	return prev
}

// Unregister clears the entry for shareID iff the current entry is still t.
// Guards against a race where a new tunnel has already replaced this one.
func (h *Hub) Unregister(shareID string, t *Tunnel) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.tunnels[shareID] == t {
		delete(h.tunnels, shareID)
	}
}

func (h *Hub) Get(shareID string) *Tunnel {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.tunnels[shareID]
}

func (h *Hub) Count() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.tunnels)
}
