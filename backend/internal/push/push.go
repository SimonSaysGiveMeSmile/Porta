package push

import (
	"context"
	"log/slog"
)

// Dispatcher sends silent APNS pushes to wake a sender device when a receiver
// requests access to a share.
//
// For MVP, the default implementation logs payloads only; real APNS delivery
// plugs in when AuthKey_*.p8, key id, team id, and bundle id are configured.
// That split keeps local dev frictionless and CI hermetic.
type Dispatcher interface {
	WakeForSession(ctx context.Context, apnsToken, sessionID, shareID string) error
}

type LogDispatcher struct {
	Log *slog.Logger
}

func (d *LogDispatcher) WakeForSession(_ context.Context, apnsToken, sessionID, shareID string) error {
	d.Log.Info("apns wake (stub)",
		"apns_token", truncate(apnsToken, 12),
		"session_id", sessionID,
		"share_id", shareID,
	)
	return nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
