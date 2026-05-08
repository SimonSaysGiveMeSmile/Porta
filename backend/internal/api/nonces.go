package api

import (
	"sync"
	"time"
)

// MemoryNonceStore is a minimal, TTL-aware nonce store for dev and tests.
// Entries self-expire on read; a background sweeper is unnecessary at MVP
// scale (every ConsumeValid call also removes the entry regardless of validity).
type MemoryNonceStore struct {
	mu sync.Mutex
	m  map[string]time.Time
}

func NewMemoryNonceStore() *MemoryNonceStore {
	return &MemoryNonceStore{m: make(map[string]time.Time)}
}

func (s *MemoryNonceStore) Put(nonce string, ttl time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.m[nonce] = time.Now().Add(ttl)
}

func (s *MemoryNonceStore) ConsumeValid(nonce string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	exp, ok := s.m[nonce]
	delete(s.m, nonce)
	return ok && time.Now().Before(exp)
}
