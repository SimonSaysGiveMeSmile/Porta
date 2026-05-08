package api

import (
	"os"
	"path/filepath"

	"github.com/gofiber/fiber/v2"
)

// serveWeb mounts the built web receiver (web/dist). /s/<token> and other
// unknown paths fall through to index.html so the SPA can handle them.
func (s *Server) serveWeb() {
	dir := os.Getenv("PORTA_WEB_DIR")
	if dir == "" {
		// Default: sibling web/dist relative to repo root.
		if _, err := os.Stat("../web/dist"); err == nil {
			dir = "../web/dist"
		}
	}
	if dir == "" {
		// No bundle present. Inline a minimal landing so the root still works.
		s.App.Get("/", placeholderIndex)
		s.App.Get("/s/:token", placeholderIndex)
		return
	}

	indexPath := filepath.Join(dir, "index.html")

	s.App.Static("/", dir, fiber.Static{MaxAge: 3600})
	s.App.Get("/s/:token", func(c *fiber.Ctx) error {
		return c.SendFile(indexPath)
	})
}

func placeholderIndex(c *fiber.Ctx) error {
	c.Type("html")
	return c.SendString(`<!doctype html><meta charset="utf-8"><title>Porta</title>
<style>body{font-family:-apple-system,sans-serif;background:#0b0d10;color:#e8ecf1;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}</style>
<main><h1>Porta</h1><p>Build the web receiver: <code>cd web && npm run build</code></p></main>`)
}
