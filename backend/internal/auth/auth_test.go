package auth

import (
	"crypto/ed25519"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

func TestSignatureVerify(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	nonce := []byte("some-random-nonce-bytes-here-ok")
	sig := ed25519.Sign(priv, nonce)

	require.NoError(t, VerifySignature(pub, nonce, sig))

	// Tamper nonce.
	bad := append([]byte{}, nonce...)
	bad[0] ^= 0xff
	require.Error(t, VerifySignature(pub, bad, sig))

	// Wrong key size.
	require.Error(t, VerifySignature([]byte("short"), nonce, sig))
}

func TestJWTRoundtrip(t *testing.T) {
	i := NewIssuer("jwt-secret-that-is-long-enough-for-tests", time.Hour)
	id := uuid.New()
	tok, err := i.Issue(id)
	require.NoError(t, err)

	c, err := i.Parse(tok)
	require.NoError(t, err)
	require.Equal(t, id.String(), c.DeviceID)
}

func TestJWTExpired(t *testing.T) {
	i := NewIssuer("jwt-secret-that-is-long-enough-for-tests", -time.Minute)
	tok, err := i.Issue(uuid.New())
	require.NoError(t, err)
	_, err = i.Parse(tok)
	require.Error(t, err)
}

func TestNonceUniqueness(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		n, err := NewNonce()
		require.NoError(t, err)
		require.False(t, seen[n])
		seen[n] = true
	}
}
