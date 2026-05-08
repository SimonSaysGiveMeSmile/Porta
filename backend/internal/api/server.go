package api

import (
	"log/slog"
	"time"

	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/auth"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/device"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/push"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/session"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/share"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/tunnel"
	fiberws "github.com/gofiber/contrib/websocket"
	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/cors"
	"github.com/gofiber/fiber/v2/middleware/recover"
	"github.com/gofiber/fiber/v2/middleware/requestid"
	"github.com/google/uuid"
)

type Deps struct {
	Log        *slog.Logger
	Auth       *auth.Issuer
	Devices    *device.Service
	Shares     *share.Service
	Sessions   *session.Service
	Tunnels    *tunnel.Hub
	Push       push.Dispatcher
	Nonces     NonceStore
	PublicBase string
}

type Server struct {
	App *fiber.App
	d   Deps
}

type NonceStore interface {
	Put(nonce string, ttl time.Duration)
	ConsumeValid(nonce string) bool
}

func New(d Deps) *Server {
	app := fiber.New(fiber.Config{
		AppName:               "porta",
		DisableStartupMessage: true,
		ErrorHandler:          errorHandler,
		BodyLimit:             32 << 20,
	})
	app.Use(recover.New())
	app.Use(requestid.New())
	app.Use(cors.New(cors.Config{
		AllowOrigins: "*",
		AllowHeaders: "Origin, Content-Type, Accept, Authorization",
	}))

	s := &Server{App: app, d: d}
	s.routes()
	return s
}

func (s *Server) routes() {
	s.App.Get("/health", func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{
			"ok":             true,
			"service":        "porta",
			"active_tunnels": s.d.Tunnels.Count(),
		})
	})

	v1 := s.App.Group("/v1")

	// Device attestation.
	v1.Post("/auth/nonce", s.handleAuthNonce)
	v1.Post("/auth/verify", s.handleAuthVerify)
	v1.Post("/devices/register", s.handleDeviceRegister)

	// Authenticated sender routes.
	authed := v1.Group("", s.requireJWT)
	authed.Post("/shares", s.handleShareCreate)
	authed.Get("/shares", s.handleShareList)
	authed.Delete("/shares/:id", s.handleShareRevoke)
	authed.Post("/sessions/:id/approve", s.handleSessionApprove)
	authed.Post("/sessions/:id/reject", s.handleSessionReject)
	authed.Post("/sessions/:id/close", s.handleSessionClose)

	// Public receiver routes (unauthenticated; token grants access).
	v1.Get("/shares/by-token/:token", s.handlePublicGetShare)
	v1.Post("/shares/by-token/:token/requests", s.handlePublicRequest)
	v1.Get("/sessions/:id/status", s.handleSessionStatus)

	// Sender reverse-tunnel WebSocket.
	v1.Get("/tunnel", s.tunnelUpgrade, fiberws.New(s.handleTunnel))

	// Public byte proxy through the tunnel. `*` matches any sub-path.
	s.App.All("/p/:sessionId/*", s.handleProxy)

	// Static web receiver (built bundle in web/dist, mounted at PORTA_WEB_DIR
	// if set; otherwise a minimal inlined placeholder so the repo boots
	// without a build step).
	s.serveWeb()
}

func (s *Server) requireJWT(c *fiber.Ctx) error {
	h := c.Get("Authorization")
	if len(h) < 8 || h[:7] != "Bearer " {
		return fiber.NewError(fiber.StatusUnauthorized, "missing bearer token")
	}
	claims, err := s.d.Auth.Parse(h[7:])
	if err != nil {
		return fiber.NewError(fiber.StatusUnauthorized, "invalid token")
	}
	did, err := uuid.Parse(claims.DeviceID)
	if err != nil {
		return fiber.NewError(fiber.StatusUnauthorized, "invalid device id in token")
	}
	c.Locals("deviceID", did)
	s.d.Devices.Touch(c.Context(), did)
	return c.Next()
}

func deviceID(c *fiber.Ctx) uuid.UUID {
	v, _ := c.Locals("deviceID").(uuid.UUID)
	return v
}

func errorHandler(c *fiber.Ctx, err error) error {
	code := fiber.StatusInternalServerError
	msg := "internal error"
	if fe, ok := err.(*fiber.Error); ok {
		code = fe.Code
		msg = fe.Message
	}
	return c.Status(code).JSON(fiber.Map{"error": msg})
}
