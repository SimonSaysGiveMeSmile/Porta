package api

import (
	"context"
	"errors"

	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/session"
	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
)

func (s *Server) handlePublicRequest(c *fiber.Ctx) error {
	tok := c.Params("token")
	sh, err := s.d.Shares.GetByToken(c.Context(), tok)
	if err != nil {
		return mapShareErr(err)
	}
	sess, err := s.d.Sessions.Request(c.Context(), session.RequestInput{
		ShareID:     sh.ID,
		RequesterIP: c.IP(),
		RequesterUA: c.Get("User-Agent"),
	})
	if err != nil {
		return err
	}

	// Fire silent push (fire-and-forget; request-scoped context would cancel
	// on return, so use a fresh background context).
	apnsToken := ownerAPNSToken(c.Context(), s, sh.OwnerDeviceID)
	if apnsToken != "" {
		go func(token, sessionID, shareID string) {
			if err := s.d.Push.WakeForSession(context.Background(), token, sessionID, shareID); err != nil {
				s.d.Log.Warn("push wake failed", "err", err, "session", sessionID)
			}
		}(apnsToken, sess.ID.String(), sh.ID.String())
	}

	return c.Status(fiber.StatusAccepted).JSON(fiber.Map{
		"session_id": sess.ID.String(),
		"status":     sess.Status,
	})
}

func ownerAPNSToken(ctx context.Context, s *Server, ownerID uuid.UUID) string {
	d, err := s.d.Devices.Get(ctx, ownerID)
	if err != nil {
		return ""
	}
	return d.APNSToken
}

func (s *Server) handleSessionStatus(c *fiber.Ctx) error {
	id, err := uuid.Parse(c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid id")
	}
	sess, err := s.d.Sessions.Get(c.Context(), id)
	if err != nil {
		if errors.Is(err, session.ErrNotFound) {
			return fiber.NewError(fiber.StatusNotFound, "not found")
		}
		return err
	}
	return c.JSON(fiber.Map{
		"session_id": sess.ID,
		"status":     sess.Status,
	})
}

func (s *Server) handleSessionsPending(c *fiber.Ctx) error {
	rows, err := s.d.Sessions.ListPendingForOwner(c.Context(), deviceID(c), 50)
	if err != nil {
		return err
	}
	return c.JSON(fiber.Map{"sessions": rows})
}

type sessionTxFn func(ctx context.Context, id, owner uuid.UUID) (*session.Session, error)

func (s *Server) handleSessionApprove(c *fiber.Ctx) error {
	return s.sessionTransition(c, s.d.Sessions.Approve)
}
func (s *Server) handleSessionReject(c *fiber.Ctx) error {
	return s.sessionTransition(c, s.d.Sessions.Reject)
}
func (s *Server) handleSessionClose(c *fiber.Ctx) error {
	return s.sessionTransition(c, s.d.Sessions.Close)
}

func (s *Server) sessionTransition(c *fiber.Ctx, fn sessionTxFn) error {
	id, err := uuid.Parse(c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid id")
	}
	sess, err := fn(c.Context(), id, deviceID(c))
	if err != nil {
		switch {
		case errors.Is(err, session.ErrNotFound):
			return fiber.NewError(fiber.StatusNotFound, "not found")
		case errors.Is(err, session.ErrWrongOwner):
			return fiber.NewError(fiber.StatusForbidden, "not your session")
		case errors.Is(err, session.ErrBadTransition):
			return fiber.NewError(fiber.StatusConflict, "invalid transition")
		default:
			return err
		}
	}
	return c.JSON(sess)
}
