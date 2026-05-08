package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// Device attestation: on first launch the iOS app generates an Ed25519 keypair
// (stored in the Keychain) and registers the public key with the backend. To
// authenticate, the device requests a random nonce, signs it with its private
// key, and exchanges the signature for a short-lived JWT.
//
// The backend does not handle passwords. Device identity is the only auth.

var (
	ErrBadSignature = errors.New("bad signature")
	ErrBadNonce     = errors.New("bad or expired nonce")
)

type Claims struct {
	DeviceID string `json:"did"`
	jwt.RegisteredClaims
}

type Issuer struct {
	secret []byte
	ttl    time.Duration
}

func NewIssuer(secret string, ttl time.Duration) *Issuer {
	return &Issuer{secret: []byte(secret), ttl: ttl}
}

func (i *Issuer) Issue(deviceID uuid.UUID) (string, error) {
	now := time.Now()
	claims := Claims{
		DeviceID: deviceID.String(),
		RegisteredClaims: jwt.RegisteredClaims{
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(i.ttl)),
			Subject:   deviceID.String(),
		},
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return tok.SignedString(i.secret)
}

func (i *Issuer) Parse(tokStr string) (*Claims, error) {
	c := &Claims{}
	_, err := jwt.ParseWithClaims(tokStr, c, func(_ *jwt.Token) (any, error) {
		return i.secret, nil
	})
	if err != nil {
		return nil, err
	}
	return c, nil
}

// NewNonce returns a random 32-byte nonce, base64url-encoded.
func NewNonce() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// VerifySignature returns nil iff `sig` is a valid Ed25519 signature of
// `nonce` under `publicKey`.
func VerifySignature(publicKey, nonce, sigB64 []byte) error {
	if len(publicKey) != ed25519.PublicKeySize {
		return ErrBadSignature
	}
	if !ed25519.Verify(publicKey, nonce, sigB64) {
		return ErrBadSignature
	}
	return nil
}
