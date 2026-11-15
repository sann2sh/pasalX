package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"pasalx/server/internal/auth"
	"pasalx/server/internal/db"
	psync "pasalx/server/internal/sync"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	keys, err := auth.LoadKeysFromEnv()
	if err != nil {
		log.Fatalf("Key configuration error: %v", err)
	}

	pool, err := db.ConnectPool(ctx)
	if err != nil {
		log.Fatalf("Database connection failed: %v", err)
	}
	defer pool.Close()

	authSvc := auth.NewService(pool, keys)
	authHandler := auth.NewHandler(authSvc, os.Getenv("TRUST_PROXY") == "1")

	syncHub := psync.NewHub()
	authSvc.SetOnDeviceRevoked(func(deviceID, _ string) {
		syncHub.RevokeDevice(deviceID)
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
	authHandler.Routes(mux)
	syncHandler.Routes(mux, authHandler.RequireAuth)

	srv := &http.Server{
		Addr:              fmt.Sprintf(":%s", port),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
		// WriteTimeout intentionally unset: Step 4 SSE streams are long-lived.
	}

	go func() {
		log.Printf("PasalX API server listening on %s", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("Server failed: %v", err)
		}
	}()

	<-ctx.Done()
	log.Printf("Shutting down...")
	syncHub.Shutdown()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("Graceful shutdown error: %v", err)
	}
}
