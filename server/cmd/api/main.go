package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/google/uuid"

	"pasalx/server/internal/auth"
	"pasalx/server/internal/db"
	"pasalx/server/internal/mail"
	psync "pasalx/server/internal/sync"
)

// buildVersion is injected at compile time via -ldflags "-X main.buildVersion=..."
var buildVersion = "dev"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	bindAddr := os.Getenv("BIND_ADDR")
	if bindAddr == "" {
		bindAddr = fmt.Sprintf(":%s", port)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	keys, err := auth.LoadKeysFromEnv()
	if err != nil {
		logger.Error("key configuration error", "err", err)
		os.Exit(1)
	}

	pool, err := db.ConnectPool(ctx)
	if err != nil {
		logger.Error("database connection failed", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	schemaVersion, err := db.CheckSchemaVersion(ctx, pool)
	if err != nil {
		logger.Error("database schema verification failed", "err", err)
		os.Exit(1)
	}

	trustProxy := os.Getenv("TRUST_PROXY") == "1"
	authSvc := auth.NewService(pool, keys)

	var mailer mail.Mailer = mail.NewLogMailer()
	if smtpCfg, ok := mail.ConfigFromEnv(); ok {
		sm, err := mail.NewSMTPMailer(smtpCfg)
		if err != nil {
			logger.Error("smtp mailer init failed", "err", err)
			os.Exit(1)
		}
		mailer = sm
		logger.Info("smtp mailer enabled", "host", smtpCfg.Host, "port", smtpCfg.Port)
	} else {
		logger.Warn("SMTP_USER/SMTP_PASS not set; using LogMailer (emails logged only)")
	}
	defer mailer.Close()
	authSvc.SetMailer(mailer)

	authHandler := auth.NewHandler(authSvc, trustProxy)

	syncHub := psync.NewHub()
	authSvc.SetOnDeviceRevoked(func(storeID, deviceID, _ string) {
		syncHub.RevokeDevice(storeID, deviceID)
	})
	authSvc.SetOnStoreDataChanged(func(storeID string) {
		syncHub.BroadcastDataChanged(psync.BroadcastEvent{
			StoreID:    storeID,
			ServerTime: time.Now().UTC(),
		})
	})
	syncSvc := psync.NewService(pool, syncHub)
	syncHandler := psync.NewHandler(syncSvc)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		pingCtx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := pool.Ping(pingCtx); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(`{"status":"degraded","service":"pasalx-server","db":"unreachable"}`))
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok","service":"pasalx-server","db":"ok"}`))
	})
	mux.HandleFunc("GET /api/version", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"service":        "pasalx-server",
			"version":        buildVersion,
			"schema_version": schemaVersion,
		})
	})
	authHandler.Routes(mux)
	syncHandler.Routes(mux, authHandler.RequireAuth)

	srv := &http.Server{
		Addr:              bindAddr,
		Handler:           requestLogger(logger, mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
		// WriteTimeout intentionally unset: SSE streams are long-lived.
	}

	go func() {
		logger.Info("pasalx-api listening", "addr", srv.Addr, "version", buildVersion, "schema_version", schemaVersion)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	logger.Info("shutting down")
	syncHub.Shutdown()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown error", "err", err)
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (sr *statusRecorder) WriteHeader(code int) {
	sr.status = code
	sr.ResponseWriter.WriteHeader(code)
}

// Flush preserves http.Flusher for SSE streams (/api/sync/events).
func (sr *statusRecorder) Flush() {
	if f, ok := sr.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Unwrap supports http.ResponseController (used for per-response write deadlines).
func (sr *statusRecorder) Unwrap() http.ResponseWriter {
	return sr.ResponseWriter
}

func requestLogger(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqID := r.Header.Get("X-Request-ID")
		if reqID == "" || len(reqID) > 64 {
			reqID = uuid.NewString()
		}
		w.Header().Set("X-Request-ID", reqID)

		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		// Skip noisy health checks unless degraded
		if r.URL.Path == "/api/health" && rec.status == http.StatusOK {
			return
		}
		logger.Info("http_request",
			"request_id", reqID,
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}
