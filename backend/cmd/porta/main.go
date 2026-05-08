package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/api"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/auth"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/config"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/device"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/logger"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/push"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/session"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/share"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/storage"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/token"
	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/tunnel"
)

func main() {
	migrateOnly := flag.Bool("migrate", false, "run migrations then exit")
	flag.Parse()

	cfg, err := config.Load()
	if err != nil {
		slog.Error("config", "err", err)
		os.Exit(1)
	}
	log := logger.New(cfg.Env)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	db, err := storage.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("db open", "err", err)
		os.Exit(1)
	}
	defer db.Close()
	if err := db.Migrate(ctx); err != nil {
		log.Error("db migrate", "err", err)
		os.Exit(1)
	}
	if *migrateOnly {
		log.Info("migrations applied")
		return
	}

	deps := api.Deps{
		Log:        log,
		Auth:       auth.NewIssuer(cfg.JWTSecret, cfg.JWTTTL),
		Devices:    device.NewService(db.Pool),
		Shares:     share.NewService(db.Pool, token.NewSigner(cfg.ShareHMACSecret), cfg.PublicBaseURL, cfg.ShareTTL),
		Sessions:   session.NewService(db.Pool),
		Tunnels:    tunnel.NewHub(),
		Push:       &push.LogDispatcher{Log: log},
		Nonces:     api.NewMemoryNonceStore(),
		PublicBase: cfg.PublicBaseURL,
	}
	srv := api.New(deps)

	go func() {
		log.Info("porta listening", "addr", cfg.Addr, "env", cfg.Env)
		if err := srv.App.Listen(cfg.Addr); err != nil {
			log.Error("listen", "err", err)
			cancel()
		}
	}()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-sigs:
	case <-ctx.Done():
	}
	log.Info("shutting down")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	_ = srv.App.ShutdownWithContext(shutdownCtx)
}
