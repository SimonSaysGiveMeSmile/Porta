package api

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestMemoryNonceStore_ConsumeValid(t *testing.T) {
	s := NewMemoryNonceStore()
	s.Put("abc", time.Minute)
	require.True(t, s.ConsumeValid("abc"))
	// single-use: second read should fail
	require.False(t, s.ConsumeValid("abc"))
}

func TestMemoryNonceStore_Expired(t *testing.T) {
	s := NewMemoryNonceStore()
	s.Put("abc", -time.Second)
	require.False(t, s.ConsumeValid("abc"))
}

func TestMemoryNonceStore_Unknown(t *testing.T) {
	s := NewMemoryNonceStore()
	require.False(t, s.ConsumeValid("never-inserted"))
}
