package api

import (
	"encoding/base64"
	"time"

	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/auth"
	"github.com/gofiber/fiber/v2"
)

type nonceResponse struct {
	Nonce string `json:"nonce"`
}

func (s *Server) handleAuthNonce(c *fiber.Ctx) error {
	n, err := auth.NewNonce()
	if err != nil {
		return err
	}
	s.d.Nonces.Put(n, 2*time.Minute)
	return c.JSON(nonceResponse{Nonce: n})
}

type verifyRequest struct {
	PublicKey string `json:"public_key"` // base64 (standard or URL)
	Nonce     string `json:"nonce"`
	Signature string `json:"signature"` // base64 (standard or URL)
	APNSToken string `json:"apns_token,omitempty"`
	Platform  string `json:"platform,omitempty"`
}

type verifyResponse struct {
	DeviceID string `json:"device_id"`
	JWT      string `json:"jwt"`
}

func (s *Server) handleAuthVerify(c *fiber.Ctx) error {
	var req verifyRequest
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.PublicKey == "" || req.Nonce == "" || req.Signature == "" {
		return fiber.NewError(fiber.StatusBadRequest, "public_key, nonce, signature required")
	}
	pub, err := decodeB64(req.PublicKey)
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "public_key must be base64")
	}
	sig, err := decodeB64(req.Signature)
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "signature must be base64")
	}
	nonce, err := decodeB64(req.Nonce)
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "nonce must be base64")
	}
	if !s.d.Nonces.ConsumeValid(req.Nonce) {
		return fiber.NewError(fiber.StatusUnauthorized, "nonce expired or unknown")
	}
	if err := auth.VerifySignature(pub, nonce, sig); err != nil {
		return fiber.NewError(fiber.StatusUnauthorized, "bad signature")
	}
	d, err := s.d.Devices.Register(c.Context(), pub, req.Platform, req.APNSToken)
	if err != nil {
		return err
	}
	tok, err := s.d.Auth.Issue(d.ID)
	if err != nil {
		return err
	}
	return c.JSON(verifyResponse{DeviceID: d.ID.String(), JWT: tok})
}

type registerRequest struct {
	PublicKey string `json:"public_key"`
	APNSToken string `json:"apns_token,omitempty"`
	Platform  string `json:"platform,omitempty"`
}

// handleDeviceRegister is an idempotent registration (no signature check).
// Intended for early bootstrap / re-registration of APNS token. Auth for
// everything beyond registration still requires the signed-nonce flow.
func (s *Server) handleDeviceRegister(c *fiber.Ctx) error {
	var req registerRequest
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	pub, err := decodeB64(req.PublicKey)
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "public_key must be base64")
	}
	d, err := s.d.Devices.Register(c.Context(), pub, req.Platform, req.APNSToken)
	if err != nil {
		return err
	}
	return c.JSON(fiber.Map{"device_id": d.ID.String()})
}

func decodeB64(s string) ([]byte, error) {
	if b, err := base64.RawURLEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.URLEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return base64.StdEncoding.DecodeString(s)
}
