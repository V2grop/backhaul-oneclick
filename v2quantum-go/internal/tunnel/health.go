package tunnel

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"
)

func (r *Runtime) ServeHealth(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		status := http.StatusOK
		if !r.Ready() {
			status = http.StatusServiceUnavailable
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(struct {
			Ready bool     `json:"ready"`
			Stats Snapshot `json:"stats"`
		}{Ready: r.Ready(), Stats: r.Snapshot()})
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		s := r.Snapshot()
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		_, _ = fmt.Fprintf(w,
			"v2quantum_sessions %d\nv2quantum_streams %d\nv2quantum_bytes_to_exit_total %d\nv2quantum_bytes_to_user_total %d\nv2quantum_reconnects_total %d\nv2quantum_auth_failures_total %d\nv2quantum_open_failures_total %d\nv2quantum_tun_packets_to_peer_total %d\nv2quantum_tun_packets_from_peer_total %d\nv2quantum_tun_bytes_to_peer_total %d\nv2quantum_tun_bytes_from_peer_total %d\nv2quantum_udp_retransmits_total %d\nv2quantum_udp_fast_resends_total %d\nv2quantum_udp_fec_sent_total %d\nv2quantum_udp_fec_recovered_total %d\nv2quantum_udp_srtt_milliseconds %d\nv2quantum_udp_rto_milliseconds %d\nv2quantum_udp_congestion_window %d\n",
			s.Sessions, s.Streams, s.BytesToExit, s.BytesToUser, s.Reconnects, s.AuthFailed, s.OpenFailed,
			s.TUNPacketsToPeer, s.TUNPacketsFromPeer, s.TUNBytesToPeer, s.TUNBytesFromPeer,
			s.QuantumRetransmits, s.QuantumFastResends, s.QuantumFECSent, s.QuantumFECRecovered,
			s.QuantumSRTTMillis, s.QuantumRTOMillis, s.QuantumWindow)
	})
	server := &http.Server{
		Addr:              r.cfg.Health.Listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	r.logger.Info("health endpoint listening", "address", server.Addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

func NewLogger(level string, jsonOutput bool) *slog.Logger {
	var parsed slog.Level
	switch level {
	case "debug":
		parsed = slog.LevelDebug
	case "warn":
		parsed = slog.LevelWarn
	case "error":
		parsed = slog.LevelError
	default:
		parsed = slog.LevelInfo
	}
	options := &slog.HandlerOptions{Level: parsed}
	if jsonOutput {
		return slog.New(slog.NewJSONHandler(logWriter{}, options))
	}
	return slog.New(slog.NewTextHandler(logWriter{}, options))
}

type logWriter struct{}

func (logWriter) Write(p []byte) (int, error) {
	return fmt.Print(string(p))
}
