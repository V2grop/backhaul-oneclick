package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/rawip"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/tunnel"
)

var version = "dev"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		usage()
		return errors.New("a command is required")
	}
	switch args[0] {
	case "run":
		return runTunnel(args[1:])
	case "check":
		return checkConfig(args[1:])
	case "keygen":
		return keygen()
	case "spoof-check":
		return spoofCheck(args[1:])
	case "spoof-scan":
		return spoofScan(args[1:])
	case "healthcheck":
		return healthCheck(args[1:])
	case "version", "-v", "--version":
		fmt.Println("v2quantum-go", version)
		return nil
	case "help", "-h", "--help":
		usage()
		return nil
	default:
		usage()
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func healthCheck(args []string) error {
	fs := flag.NewFlagSet("healthcheck", flag.ContinueOnError)
	path := fs.String("config", "", "path to JSON configuration")
	timeout := fs.Duration("timeout", 5*time.Second, "health request timeout")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if *path == "" {
		return errors.New("healthcheck requires -config")
	}
	if *timeout < time.Second || *timeout > 30*time.Second {
		return errors.New("healthcheck timeout must be between 1s and 30s")
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+cfg.Health.Listen+"/healthz", nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("health request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return fmt.Errorf("read health response: %w", err)
	}
	if len(body) > 0 {
		fmt.Print(string(body))
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("health endpoint returned %s", resp.Status)
	}
	return nil
}

func runTunnel(args []string) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	path := fs.String("config", "", "path to JSON configuration")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if *path == "" {
		return errors.New("run requires -config")
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return err
	}
	logger := tunnel.NewLogger(cfg.Logging.Level, cfg.Logging.JSON).With(
		"version", version,
		"node", cfg.NodeName,
		"role", cfg.Role,
	)
	runtime := tunnel.NewRuntime(cfg, logger)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	healthErr := make(chan error, 1)
	go func() { healthErr <- runtime.ServeHealth(ctx) }()
	runErr := make(chan error, 1)
	go func() { runErr <- runtime.Run(ctx) }()
	select {
	case err := <-runErr:
		stop()
		if !tunnel.IsExpectedShutdown(err) {
			return err
		}
	case err := <-healthErr:
		stop()
		if err != nil {
			return fmt.Errorf("health server: %w", err)
		}
	case <-ctx.Done():
	}
	logger.Info("shutdown complete")
	return nil
}

func checkConfig(args []string) error {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	path := fs.String("config", "", "path to JSON configuration")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if *path == "" {
		return errors.New("check requires -config")
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return err
	}
	fmt.Printf("configuration valid: role=%s carrier=%s mappings=%d\n", cfg.Role, cfg.Carrier.Mode, len(cfg.Mappings))
	return nil
}

func keygen() error {
	key := make([]byte, 48)
	if _, err := rand.Read(key); err != nil {
		return err
	}
	fmt.Println(base64.RawURLEncoding.EncodeToString(key))
	return nil
}

func spoofCheck(args []string) error {
	fs := flag.NewFlagSet("spoof-check", flag.ContinueOnError)
	path := fs.String("config", "", "path to a raw_icmp JSON configuration")
	send := fs.Bool("send", false, "send one authenticated-tag test packet after preflight")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if *path == "" {
		return errors.New("spoof-check requires -config")
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return err
	}
	if cfg.Carrier.Mode != "raw_icmp" {
		return errors.New("spoof-check requires carrier.mode=raw_icmp")
	}
	report, err := rawip.Preflight(cfg.Carrier.Raw)
	b, _ := json.MarshalIndent(report, "", "  ")
	fmt.Println(string(b))
	if err != nil {
		return err
	}
	if !*send {
		fmt.Println("preflight passed; no packet sent (use -send for an explicit probe)")
		return nil
	}
	tag := []byte("V2QUANTUM-GO-SPOOF-PREFLIGHT")
	if err := rawip.SendProbe(cfg.Carrier.Raw, tag); err != nil {
		return err
	}
	slog.Info("raw ICMP probe sent", "source", report.ConfiguredSource, "destination", report.ConfiguredTarget)
	return nil
}

func spoofScan(args []string) error {
	fs := flag.NewFlagSet("spoof-scan", flag.ContinueOnError)
	peerValue := fs.String("peer", "", "peer real IPv4 address")
	count := fs.Int("count", 3, "ICMP probes per locally assigned source (1-10)")
	timeout := fs.Duration("timeout", 2*time.Second, "timeout for each probe (200ms-10s)")
	jsonOutput := fs.Bool("json", false, "print the complete report as JSON")
	selectedOnly := fs.Bool("selected-only", false, "print the selected IP to stdout and the report to stderr")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if *jsonOutput && *selectedOnly {
		return errors.New("spoof-scan accepts only one of -json or -selected-only")
	}
	peer := net.ParseIP(*peerValue)
	if peer == nil || peer.To4() == nil {
		return errors.New("spoof-scan requires -peer with a valid IPv4 address")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	report, err := rawip.ScanAssignedSources(ctx, peer, *count, *timeout)
	if err != nil {
		return err
	}
	if *jsonOutput {
		encoded, err := json.MarshalIndent(report, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(encoded))
	} else {
		writer := io.Writer(os.Stdout)
		if *selectedOnly {
			writer = os.Stderr
		}
		printSourceScanReport(writer, report)
	}
	if report.Selected == "" {
		return errors.New("no locally assigned source passed the minimum ICMP delivery threshold")
	}
	if *selectedOnly {
		fmt.Println(report.Selected)
	}
	return nil
}

func printSourceScanReport(output io.Writer, report rawip.SourceScanReport) {
	fmt.Fprintf(output, "Authorized local-source ICMP scan -> %s\n", report.Peer)
	w := tabwriter.NewWriter(output, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "SOURCE\tINTERFACE\tSENT\tRECV\tLOSS\tAVG RTT\tSTATUS")
	for _, result := range report.Candidates {
		status := "ok"
		if result.Error != "" {
			status = result.Error
		} else if result.Received == 0 {
			status = "no reply"
		}
		fmt.Fprintf(w, "%s\t%s\t%d\t%d\t%.1f%%\t%.2f ms\t%s\n",
			result.IP, result.Interface, result.Sent, result.Received,
			result.LossPercent, result.AvgRTTMillis, status)
	}
	_ = w.Flush()
	if report.Selected != "" {
		fmt.Fprintf(output, "Selected verified source: %s\n", report.Selected)
	} else {
		fmt.Fprintln(output, "Selected verified source: none")
	}
	fmt.Fprintln(output, report.Note)
}

func usage() {
	fmt.Printf(`V2Quantum-Go %s - independent clean-room reverse tunnel

Usage:
  v2quantum run -config FILE
  v2quantum check -config FILE
  v2quantum keygen
  v2quantum healthcheck -config FILE [-timeout 5s]
  v2quantum spoof-check -config FILE [-send]
  v2quantum spoof-scan -peer IPv4 [-count 3] [-timeout 2s]
  v2quantum version
`, version)
}
