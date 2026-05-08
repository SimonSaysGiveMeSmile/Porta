package api

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/session"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/tunnel"
	fiberws "github.com/gofiber/contrib/websocket"
	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
)

// tunnelUpgrade authenticates the sender and stashes the share ID on locals
// for the websocket handler. Query params: ?share=<share_id>&token=<jwt>.
func (s *Server) tunnelUpgrade(c *fiber.Ctx) error {
	if !fiberws.IsWebSocketUpgrade(c) {
		return fiber.ErrUpgradeRequired
	}
	shareID, err := uuid.Parse(c.Query("share"))
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid share id")
	}
	claims, err := s.d.Auth.Parse(c.Query("token"))
	if err != nil {
		return fiber.NewError(fiber.StatusUnauthorized, "invalid token")
	}
	did, err := uuid.Parse(claims.DeviceID)
	if err != nil {
		return fiber.NewError(fiber.StatusUnauthorized, "bad device id")
	}
	sh, err := s.d.Shares.GetByID(c.Context(), shareID)
	if err != nil {
		return mapShareErr(err)
	}
	if sh.OwnerDeviceID != did {
		return fiber.NewError(fiber.StatusForbidden, "not the share owner")
	}
	c.Locals("shareID", shareID)
	return c.Next()
}

// fiberWSConn adapts *fiberws.Conn to tunnel.Conn.
type fiberWSConn struct{ c *fiberws.Conn }

func (f fiberWSConn) WriteMessage(b []byte) error {
	return f.c.WriteMessage(fiberws.BinaryMessage, b)
}
func (f fiberWSConn) ReadMessage() ([]byte, error) {
	_, b, err := f.c.ReadMessage()
	return b, err
}
func (f fiberWSConn) Close() error { return f.c.Close() }

func (s *Server) handleTunnel(c *fiberws.Conn) {
	shareID, _ := c.Locals("shareID").(uuid.UUID)
	t := tunnel.New(fiberWSConn{c: c})

	if prev := s.d.Tunnels.Register(shareID.String(), t); prev != nil {
		_ = prev.Close()
	}
	defer s.d.Tunnels.Unregister(shareID.String(), t)

	s.d.Log.Info("tunnel opened", "share_id", shareID)
	err := t.Run()
	s.d.Log.Info("tunnel closed", "share_id", shareID, "err", err)
}

// handleProxy forwards /p/:sessionId/<subpath> through the sender's tunnel.
// Session must be approved; share must be live; tunnel must be connected.
func (s *Server) handleProxy(c *fiber.Ctx) error {
	sessionID, err := uuid.Parse(c.Params("sessionId"))
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid session id")
	}
	sess, err := s.d.Sessions.Get(c.Context(), sessionID)
	if err != nil {
		if errors.Is(err, session.ErrNotFound) {
			return fiber.NewError(fiber.StatusNotFound, "session not found")
		}
		return err
	}
	if sess.Status != session.StatusApproved {
		return fiber.NewError(fiber.StatusForbidden, "session not approved")
	}
	if _, err := s.d.Shares.GetByID(c.Context(), sess.ShareID); err != nil {
		return mapShareErr(err)
	}

	t := s.d.Tunnels.Get(sess.ShareID.String())
	if t == nil {
		return fiber.NewError(fiber.StatusBadGateway, "sender offline")
	}

	req, err := t.Open(context.Background(), tunnel.OpenHeader{
		Method:  c.Method(),
		Path:    "/" + c.Params("*"),
		Headers: map[string][]string{"User-Agent": {c.Get("User-Agent")}},
	})
	if err != nil {
		return fiber.NewError(fiber.StatusBadGateway, "tunnel unavailable")
	}

	var head tunnel.HeadMessage
	select {
	case head = <-req.Head:
	case e := <-req.Err:
		return fiber.NewError(fiber.StatusBadGateway, e.Error())
	case <-time.After(30 * time.Second):
		return fiber.NewError(fiber.StatusGatewayTimeout, "sender did not respond")
	}

	c.Status(head.Status)
	for k, vals := range head.Headers {
		if isHopByHop(k) {
			continue
		}
		for _, v := range vals {
			c.Response().Header.Add(k, v)
		}
	}
	c.Response().SetBodyStream(req.ReadBody(), -1)
	return nil
}

func isHopByHop(k string) bool {
	switch http.CanonicalHeaderKey(k) {
	case "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
		"Te", "Trailer", "Transfer-Encoding", "Upgrade":
		return true
	}
	return false
}
