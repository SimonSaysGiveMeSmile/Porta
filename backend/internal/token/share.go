package token

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Share tokens are opaque, URL-safe strings that carry a signed payload:
//
//	base64url( shareID[16] || expUnix[8] ) + "." + base64url( HMAC-SHA256 )
//
// The token is used in share URLs (portal.app/s/<token>) and is verified on
// every receiver request. It is self-contained — a lookup is still required
// against `shares.token` to pick up revocation, but the HMAC means we reject
// malformed or expired tokens without touching the DB.

var (
	ErrInvalidToken = errors.New("invalid share token")
	ErrExpiredToken = errors.New("share token expired")
)

type Signer struct {
	secret []byte
}

func NewSigner(secret string) *Signer {
	return &Signer{secret: []byte(secret)}
}

type ShareToken struct {
	ID       [16]byte
	ExpiresAt time.Time
}

func (s *Signer) NewShareToken(ttl time.Duration) (ShareToken, string, error) {
	var t ShareToken
	if _, err := rand.Read(t.ID[:]); err != nil {
		return t, "", err
	}
	t.ExpiresAt = time.Now().Add(ttl)
	tok, err := s.Encode(t)
	return t, tok, err
}

func (s *Signer) Encode(t ShareToken) (string, error) {
	payload := make([]byte, 16+8)
	copy(payload[:16], t.ID[:])
	binary.BigEndian.PutUint64(payload[16:], uint64(t.ExpiresAt.Unix()))

	mac := hmac.New(sha256.New, s.secret)
	mac.Write(payload)
	sig := mac.Sum(nil)

	return base64.RawURLEncoding.EncodeToString(payload) + "." +
		base64.RawURLEncoding.EncodeToString(sig), nil
}

func (s *Signer) Verify(tok string) (ShareToken, error) {
	var out ShareToken
	parts := strings.SplitN(tok, ".", 2)
	if len(parts) != 2 {
		return out, ErrInvalidToken
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || len(payload) != 24 {
		return out, ErrInvalidToken
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return out, ErrInvalidToken
	}

	mac := hmac.New(sha256.New, s.secret)
	mac.Write(payload)
	if !hmac.Equal(mac.Sum(nil), sig) {
		return out, ErrInvalidToken
	}

	copy(out.ID[:], payload[:16])
	out.ExpiresAt = time.Unix(int64(binary.BigEndian.Uint64(payload[16:])), 0)
	if time.Now().After(out.ExpiresAt) {
		return out, ErrExpiredToken
	}
	return out, nil
}

// ShortID returns the 22-char base62-ish (actually base64url) prefix of the
// share ID — suitable for URLs like /s/<short>. Collision-resistant at 128 bits.
func (t ShareToken) ShortID() string {
	return base64.RawURLEncoding.EncodeToString(t.ID[:])
}

// ParseShortID parses a ShortID back to the raw 16-byte ID.
func ParseShortID(s string) ([16]byte, error) {
	var id [16]byte
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || len(b) != 16 {
		return id, fmt.Errorf("invalid share id")
	}
	copy(id[:], b)
	return id, nil
}
