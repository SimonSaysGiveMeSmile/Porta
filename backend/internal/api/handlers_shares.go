package api

import (
	"errors"

	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/share"
	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
)

type createShareRequest struct {
	Title string       `json:"title"`
	Files []share.File `json:"files"`
}

func (s *Server) handleShareCreate(c *fiber.Ctx) error {
	var req createShareRequest
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if len(req.Files) == 0 {
		return fiber.NewError(fiber.StatusBadRequest, "files required")
	}
	sh, err := s.d.Shares.Create(c.Context(), share.CreateInput{
		OwnerDeviceID: deviceID(c),
		Title:         req.Title,
		Files:         req.Files,
	})
	if err != nil {
		return err
	}
	return c.Status(fiber.StatusCreated).JSON(sh)
}

func (s *Server) handleShareList(c *fiber.Ctx) error {
	rows, err := s.d.Shares.ListForOwner(c.Context(), deviceID(c), 50)
	if err != nil {
		return err
	}
	return c.JSON(fiber.Map{"shares": rows})
}

func (s *Server) handleShareRevoke(c *fiber.Ctx) error {
	id, err := uuid.Parse(c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid id")
	}
	if err := s.d.Shares.Revoke(c.Context(), id, deviceID(c)); err != nil {
		if errors.Is(err, share.ErrNotFound) {
			return fiber.NewError(fiber.StatusNotFound, "not found")
		}
		return err
	}
	return c.SendStatus(fiber.StatusNoContent)
}

func (s *Server) handlePublicGetShare(c *fiber.Ctx) error {
	tok := c.Params("token")
	sh, err := s.d.Shares.GetByToken(c.Context(), tok)
	if err != nil {
		return mapShareErr(err)
	}
	// Receiver-facing view: hide owner device ID.
	return c.JSON(fiber.Map{
		"share_id":    sh.ID.String(),
		"title":       sh.Title,
		"files":       sh.Files,
		"file_count":  sh.FileCount,
		"total_bytes": sh.TotalBytes,
		"expires_at":  sh.ExpiresAt,
	})
}

func mapShareErr(err error) error {
	switch {
	case errors.Is(err, share.ErrNotFound):
		return fiber.NewError(fiber.StatusNotFound, "not found")
	case errors.Is(err, share.ErrExpired):
		return fiber.NewError(fiber.StatusGone, "link expired")
	case errors.Is(err, share.ErrRevoked):
		return fiber.NewError(fiber.StatusGone, "link revoked")
	default:
		return err
	}
}
