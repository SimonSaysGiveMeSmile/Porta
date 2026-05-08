package share

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/SimonSaysGiveMeSmile/Porta/backend/internal/token"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrNotFound = errors.New("share not found")
	ErrRevoked  = errors.New("share revoked")
	ErrExpired  = errors.New("share expired")
)

type File struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	MIME string `json:"mime,omitempty"`
}

type Share struct {
	ID            uuid.UUID `json:"id"`
	OwnerDeviceID uuid.UUID `json:"owner_device_id"`
	Token         string    `json:"token"`
	URL           string    `json:"share_url"`
	Title         string    `json:"title,omitempty"`
	Files         []File    `json:"files"`
	FileCount     int       `json:"file_count"`
	TotalBytes    int64     `json:"total_bytes"`
	ExpiresAt     time.Time `json:"expires_at"`
	CreatedAt     time.Time `json:"created_at"`
	RevokedAt     *time.Time `json:"revoked_at,omitempty"`
}

type Service struct {
	db      *pgxpool.Pool
	signer  *token.Signer
	baseURL string
	ttl     time.Duration
}

func NewService(db *pgxpool.Pool, signer *token.Signer, baseURL string, ttl time.Duration) *Service {
	return &Service{db: db, signer: signer, baseURL: baseURL, ttl: ttl}
}

type CreateInput struct {
	OwnerDeviceID uuid.UUID
	Title         string
	Files         []File
}

func (s *Service) Create(ctx context.Context, in CreateInput) (*Share, error) {
	st, tok, err := s.signer.NewShareToken(s.ttl)
	if err != nil {
		return nil, err
	}

	id, err := uuid.FromBytes(st.ID[:])
	if err != nil {
		return nil, err
	}

	var totalBytes int64
	for _, f := range in.Files {
		totalBytes += f.Size
	}

	manifest, err := json.Marshal(in.Files)
	if err != nil {
		return nil, err
	}

	row := &Share{
		ID:            id,
		OwnerDeviceID: in.OwnerDeviceID,
		Token:         tok,
		URL:           s.baseURL + "/s/" + tok,
		Title:         in.Title,
		Files:         in.Files,
		FileCount:     len(in.Files),
		TotalBytes:    totalBytes,
		ExpiresAt:     st.ExpiresAt,
		CreatedAt:     time.Now(),
	}

	_, err = s.db.Exec(ctx, `
		INSERT INTO shares (id, owner_device_id, token, title, file_count, total_bytes, manifest, expires_at, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
	`, row.ID, row.OwnerDeviceID, row.Token, row.Title, row.FileCount, row.TotalBytes, manifest, row.ExpiresAt, row.CreatedAt)
	if err != nil {
		return nil, err
	}
	return row, nil
}

func (s *Service) GetByToken(ctx context.Context, tok string) (*Share, error) {
	if _, err := s.signer.Verify(tok); err != nil {
		if errors.Is(err, token.ErrExpiredToken) {
			return nil, ErrExpired
		}
		return nil, ErrNotFound
	}
	return s.fetch(ctx, "token = $1", tok)
}

// GetByID returns a share by its DB id, applying the same expiry/revocation
// guards as GetByToken.
func (s *Service) GetByID(ctx context.Context, id uuid.UUID) (*Share, error) {
	return s.fetch(ctx, "id = $1", id)
}

func (s *Service) fetch(ctx context.Context, where string, arg any) (*Share, error) {
	var (
		out       Share
		manifest  []byte
		revokedAt *time.Time
	)
	err := s.db.QueryRow(ctx, `
		SELECT id, owner_device_id, token, COALESCE(title,''), file_count, total_bytes,
		       manifest, expires_at, revoked_at, created_at
		FROM shares WHERE `+where+`
	`, arg).Scan(&out.ID, &out.OwnerDeviceID, &out.Token, &out.Title, &out.FileCount,
		&out.TotalBytes, &manifest, &out.ExpiresAt, &revokedAt, &out.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if revokedAt != nil {
		out.RevokedAt = revokedAt
		return nil, ErrRevoked
	}
	if time.Now().After(out.ExpiresAt) {
		return nil, ErrExpired
	}
	_ = json.Unmarshal(manifest, &out.Files)
	out.URL = s.baseURL + "/s/" + out.Token
	return &out, nil
}

func (s *Service) Revoke(ctx context.Context, shareID, ownerDeviceID uuid.UUID) error {
	tag, err := s.db.Exec(ctx, `
		UPDATE shares SET revoked_at = now()
		WHERE id = $1 AND owner_device_id = $2 AND revoked_at IS NULL
	`, shareID, ownerDeviceID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Service) ListForOwner(ctx context.Context, ownerDeviceID uuid.UUID, limit int) ([]*Share, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := s.db.Query(ctx, `
		SELECT id, owner_device_id, token, COALESCE(title,''), file_count, total_bytes,
		       manifest, expires_at, revoked_at, created_at
		FROM shares WHERE owner_device_id = $1
		ORDER BY created_at DESC
		LIMIT $2
	`, ownerDeviceID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []*Share
	for rows.Next() {
		var (
			sh        Share
			manifest  []byte
			revokedAt *time.Time
		)
		if err := rows.Scan(&sh.ID, &sh.OwnerDeviceID, &sh.Token, &sh.Title, &sh.FileCount,
			&sh.TotalBytes, &manifest, &sh.ExpiresAt, &revokedAt, &sh.CreatedAt); err != nil {
			return nil, err
		}
		sh.RevokedAt = revokedAt
		_ = json.Unmarshal(manifest, &sh.Files)
		sh.URL = s.baseURL + "/s/" + sh.Token
		out = append(out, &sh)
	}
	return out, rows.Err()
}
