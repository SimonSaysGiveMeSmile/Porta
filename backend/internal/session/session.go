package session

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Status string

const (
	StatusPending  Status = "pending"
	StatusApproved Status = "approved"
	StatusRejected Status = "rejected"
	StatusClosed   Status = "closed"
)

var (
	ErrNotFound      = errors.New("session not found")
	ErrWrongOwner    = errors.New("session does not belong to device")
	ErrBadTransition = errors.New("invalid session status transition")
)

type Session struct {
	ID            uuid.UUID  `json:"id"`
	ShareID       uuid.UUID  `json:"share_id"`
	OwnerDeviceID uuid.UUID  `json:"owner_device_id"`
	RequesterIP   string     `json:"requester_ip,omitempty"`
	RequesterUA   string     `json:"requester_ua,omitempty"`
	Status        Status     `json:"status"`
	ApprovedAt    *time.Time `json:"approved_at,omitempty"`
	RejectedAt    *time.Time `json:"rejected_at,omitempty"`
	ClosedAt      *time.Time `json:"closed_at,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
}

type Service struct {
	db *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service { return &Service{db: db} }

type RequestInput struct {
	ShareID     uuid.UUID
	RequesterIP string
	RequesterUA string
}

func (s *Service) Request(ctx context.Context, in RequestInput) (*Session, error) {
	sess := &Session{
		ID:          uuid.New(),
		ShareID:     in.ShareID,
		RequesterIP: in.RequesterIP,
		RequesterUA: in.RequesterUA,
		Status:      StatusPending,
		CreatedAt:   time.Now(),
	}
	var ipArg any
	if in.RequesterIP != "" {
		ipArg = in.RequesterIP
	}
	if err := s.db.QueryRow(ctx, `
		INSERT INTO sessions (id, share_id, requester_ip, requester_ua, status, created_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING (SELECT owner_device_id FROM shares WHERE id = $2)
	`, sess.ID, sess.ShareID, ipArg, sess.RequesterUA, sess.Status, sess.CreatedAt,
	).Scan(&sess.OwnerDeviceID); err != nil {
		return nil, err
	}
	return sess, nil
}

func (s *Service) Get(ctx context.Context, id uuid.UUID) (*Session, error) {
	var sess Session
	err := s.db.QueryRow(ctx, `
		SELECT s.id, s.share_id, sh.owner_device_id,
		       COALESCE(host(s.requester_ip), ''), COALESCE(s.requester_ua, ''),
		       s.status, s.approved_at, s.rejected_at, s.closed_at, s.created_at
		FROM sessions s JOIN shares sh ON sh.id = s.share_id
		WHERE s.id = $1
	`, id).Scan(&sess.ID, &sess.ShareID, &sess.OwnerDeviceID,
		&sess.RequesterIP, &sess.RequesterUA, &sess.Status,
		&sess.ApprovedAt, &sess.RejectedAt, &sess.ClosedAt, &sess.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &sess, nil
}

func (s *Service) Approve(ctx context.Context, id, ownerDeviceID uuid.UUID) (*Session, error) {
	return s.transition(ctx, id, ownerDeviceID, StatusPending, StatusApproved, "approved_at")
}

func (s *Service) Reject(ctx context.Context, id, ownerDeviceID uuid.UUID) (*Session, error) {
	return s.transition(ctx, id, ownerDeviceID, StatusPending, StatusRejected, "rejected_at")
}

func (s *Service) Close(ctx context.Context, id, ownerDeviceID uuid.UUID) (*Session, error) {
	return s.transition(ctx, id, ownerDeviceID, StatusApproved, StatusClosed, "closed_at")
}

// ListPendingForOwner returns pending session requests against any share
// owned by the device. Polled by the sender when APNS is unavailable.
func (s *Service) ListPendingForOwner(ctx context.Context, owner uuid.UUID, limit int) ([]*Session, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := s.db.Query(ctx, `
		SELECT s.id, s.share_id, sh.owner_device_id,
		       COALESCE(host(s.requester_ip), ''), COALESCE(s.requester_ua, ''),
		       s.status, s.approved_at, s.rejected_at, s.closed_at, s.created_at
		FROM sessions s JOIN shares sh ON sh.id = s.share_id
		WHERE sh.owner_device_id = $1 AND s.status = 'pending'
		ORDER BY s.created_at ASC
		LIMIT $2
	`, owner, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []*Session
	for rows.Next() {
		var sess Session
		if err := rows.Scan(&sess.ID, &sess.ShareID, &sess.OwnerDeviceID,
			&sess.RequesterIP, &sess.RequesterUA, &sess.Status,
			&sess.ApprovedAt, &sess.RejectedAt, &sess.ClosedAt, &sess.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, &sess)
	}
	return out, rows.Err()
}

func (s *Service) transition(ctx context.Context, id, owner uuid.UUID, from, to Status, tsCol string) (*Session, error) {
	tag, err := s.db.Exec(ctx, `
		UPDATE sessions SET status = $3, `+tsCol+` = now()
		WHERE id = $1 AND status = $2
		  AND share_id IN (SELECT id FROM shares WHERE owner_device_id = $4)
	`, id, from, to, owner)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		existing, err := s.Get(ctx, id)
		if err != nil {
			return nil, err
		}
		if existing.OwnerDeviceID != owner {
			return nil, ErrWrongOwner
		}
		return nil, ErrBadTransition
	}
	return s.Get(ctx, id)
}
