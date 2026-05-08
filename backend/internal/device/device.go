package device

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrNotFound = errors.New("device not found")

type Device struct {
	ID          uuid.UUID `json:"id"`
	PublicKey   []byte    `json:"-"`
	APNSToken   string    `json:"apns_token,omitempty"`
	Platform    string    `json:"platform"`
	TrustedMode string    `json:"trusted_mode"`
	LastSeenAt  time.Time `json:"last_seen_at"`
	CreatedAt   time.Time `json:"created_at"`
}

type Service struct {
	db *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service { return &Service{db: db} }

// Register creates a device record or returns an existing one that matches the
// supplied public key. Public key is the identity; callers should not create
// duplicate device rows for the same key.
func (s *Service) Register(ctx context.Context, publicKey []byte, platform, apnsToken string) (*Device, error) {
	d, err := s.getByPublicKey(ctx, publicKey)
	if err == nil {
		if apnsToken != "" && apnsToken != d.APNSToken {
			_, _ = s.db.Exec(ctx, `UPDATE devices SET apns_token = $2, last_seen_at = now() WHERE id = $1`, d.ID, apnsToken)
			d.APNSToken = apnsToken
		}
		return d, nil
	}
	if !errors.Is(err, ErrNotFound) {
		return nil, err
	}
	if platform == "" {
		platform = "ios"
	}
	d = &Device{
		ID:          uuid.New(),
		PublicKey:   publicKey,
		APNSToken:   apnsToken,
		Platform:    platform,
		TrustedMode: "manual",
		LastSeenAt:  time.Now(),
		CreatedAt:   time.Now(),
	}
	_, err = s.db.Exec(ctx, `
		INSERT INTO devices (id, public_key, apns_token, platform, trusted_mode, last_seen_at, created_at)
		VALUES ($1,$2,NULLIF($3,''),$4,$5,$6,$7)
	`, d.ID, d.PublicKey, d.APNSToken, d.Platform, d.TrustedMode, d.LastSeenAt, d.CreatedAt)
	return d, err
}

func (s *Service) Get(ctx context.Context, id uuid.UUID) (*Device, error) {
	var d Device
	var apns *string
	err := s.db.QueryRow(ctx, `
		SELECT id, public_key, apns_token, platform, trusted_mode, last_seen_at, created_at
		FROM devices WHERE id = $1
	`, id).Scan(&d.ID, &d.PublicKey, &apns, &d.Platform, &d.TrustedMode, &d.LastSeenAt, &d.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if apns != nil {
		d.APNSToken = *apns
	}
	return &d, nil
}

func (s *Service) Touch(ctx context.Context, id uuid.UUID) {
	_, _ = s.db.Exec(ctx, `UPDATE devices SET last_seen_at = now() WHERE id = $1`, id)
}

func (s *Service) getByPublicKey(ctx context.Context, pk []byte) (*Device, error) {
	var d Device
	var apns *string
	err := s.db.QueryRow(ctx, `
		SELECT id, public_key, apns_token, platform, trusted_mode, last_seen_at, created_at
		FROM devices WHERE public_key = $1
	`, pk).Scan(&d.ID, &d.PublicKey, &apns, &d.Platform, &d.TrustedMode, &d.LastSeenAt, &d.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if apns != nil {
		d.APNSToken = *apns
	}
	return &d, nil
}
