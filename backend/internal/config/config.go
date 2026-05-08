package config

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	Addr          string
	Env           string
	DatabaseURL   string
	PublicBaseURL string

	ShareHMACSecret string
	ShareTTL        time.Duration

	JWTSecret string
	JWTTTL    time.Duration

	APNSKeyPath  string
	APNSKeyID    string
	APNSTeamID   string
	APNSBundleID string
	APNSSandbox  bool
}

func Load() (*Config, error) {
	_ = godotenv.Load()

	c := &Config{
		Addr:            getEnv("PORTA_ADDR", ":8080"),
		Env:             getEnv("PORTA_ENV", "dev"),
		DatabaseURL:     os.Getenv("PORTA_DATABASE_URL"),
		PublicBaseURL:   getEnv("PORTA_PUBLIC_BASE_URL", "http://localhost:8080"),
		ShareHMACSecret: os.Getenv("PORTA_SHARE_HMAC_SECRET"),
		JWTSecret:       os.Getenv("PORTA_JWT_SECRET"),
		APNSKeyPath:     os.Getenv("PORTA_APNS_KEY_PATH"),
		APNSKeyID:       os.Getenv("PORTA_APNS_KEY_ID"),
		APNSTeamID:      os.Getenv("PORTA_APNS_TEAM_ID"),
		APNSBundleID:    getEnv("PORTA_APNS_BUNDLE_ID", "app.porta.ios"),
		APNSSandbox:     getEnvBool("PORTA_APNS_SANDBOX", true),
	}
	c.ShareTTL = time.Duration(getEnvInt("PORTA_SHARE_TTL_HOURS", 24)) * time.Hour
	c.JWTTTL = time.Duration(getEnvInt("PORTA_JWT_TTL_MINUTES", 30)) * time.Minute

	if c.DatabaseURL == "" {
		return nil, fmt.Errorf("PORTA_DATABASE_URL is required")
	}
	if c.ShareHMACSecret == "" || len(c.ShareHMACSecret) < 16 {
		return nil, fmt.Errorf("PORTA_SHARE_HMAC_SECRET must be set (>= 16 chars)")
	}
	if c.JWTSecret == "" || len(c.JWTSecret) < 16 {
		return nil, fmt.Errorf("PORTA_JWT_SECRET must be set (>= 16 chars)")
	}
	return c, nil
}

func getEnv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
func getEnvInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
func getEnvBool(k string, def bool) bool {
	if v := os.Getenv(k); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return def
}
