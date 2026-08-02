package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

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

func runTunnel(args []string) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	path := fs.String("config", "", "path to JSON configuration")
	if err := fs.Parse(args); err != nil {
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

func usage() {
	fmt.Printf(`V2Quantum-Go %s - independent clean-room reverse tunnel

Usage:
  v2quantum run -config FILE
  v2quantum check -config FILE
  v2quantum keygen
  v2quantum spoof-check -config FILE [-send]
  v2quantum version
`, version)
}
