package token

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestShareTokenRoundtrip(t *testing.T) {
	s := NewSigner("test-secret-that-is-long-enough-ok")
	_, tok, err := s.NewShareToken(time.Hour)
	require.NoError(t, err)

	st, err := s.Verify(tok)
	require.NoError(t, err)
	require.WithinDuration(t, time.Now().Add(time.Hour), st.ExpiresAt, 5*time.Second)
}

func TestShareTokenTamper(t *testing.T) {
	s := NewSigner("secret-one-secret-one-secret-one")
	_, tok, err := s.NewShareToken(time.Hour)
	require.NoError(t, err)

	// flip a bit in the signature portion
	bad := tok[:len(tok)-1] + swapRune(tok[len(tok)-1:])
	_, err = s.Verify(bad)
	require.ErrorIs(t, err, ErrInvalidToken)
}

func TestShareTokenExpired(t *testing.T) {
	s := NewSigner("secret-secret-secret-secret-ok!!")
	_, tok, err := s.NewShareToken(-time.Minute)
	require.NoError(t, err)
	_, err = s.Verify(tok)
	require.ErrorIs(t, err, ErrExpiredToken)
}

func TestShareTokenWrongSecret(t *testing.T) {
	a := NewSigner("secret-aaaaaaaaaaaaaaaaaaaaaa")
	b := NewSigner("secret-bbbbbbbbbbbbbbbbbbbbbb")
	_, tok, err := a.NewShareToken(time.Hour)
	require.NoError(t, err)
	_, err = b.Verify(tok)
	require.ErrorIs(t, err, ErrInvalidToken)
}

func swapRune(s string) string {
	if s == "" {
		return s
	}
	r := []byte(s)
	if r[0] == 'A' {
		r[0] = 'B'
	} else {
		r[0] = 'A'
	}
	return string(r)
}
