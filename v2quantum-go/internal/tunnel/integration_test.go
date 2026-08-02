package tunnel

import (
	"bytes"
	"context"
	"crypto/rand"
	"io"
	"log/slog"
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

func TestEncryptedReverseTunnelEndToEnd(t *testing.T) {
	for _, mode := range []string{"tcp", "quantum_udp", "raw_icmp"} {
		t.Run(mode, func(t *testing.T) { testEncryptedReverseTunnelEndToEnd(t, mode) })
	}
}

func TestClientReconnectsAfterCarrierDrop(t *testing.T) {
	for _, mode := range []string{"tcp", "quantum_udp"} {
		t.Run(mode, func(t *testing.T) {
			echoAddr, stopEcho := startEcho(t)
			defer stopEcho()
			carrierAddr := reserveCarrierAddress(t, mode)
			userAddr := reserveAddress(t)
			psk := strings.Repeat("reconnect-secret-", 3)

			serverCfg := testConfig("server", psk)
			serverCfg.Carrier.Mode = mode
			serverCfg.Carrier.Listen = carrierAddr
			serverCfg.Carrier.Pool = 1
			serverCfg.Mappings = []config.Mapping{{Name: "echo", Protocol: "tcp", Listen: userAddr}}
			clientCfg := testConfig("client", psk)
			clientCfg.Carrier.Mode = mode
			clientCfg.Carrier.Server = carrierAddr
			clientCfg.Carrier.Pool = 1
			clientCfg.Mappings = []config.Mapping{{Name: "echo", Protocol: "tcp", Target: echoAddr}}

			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			server := NewRuntime(serverCfg, logger)
			client := NewRuntime(clientCfg, logger)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			errCh := make(chan error, 2)
			go func() { errCh <- server.Run(ctx) }()
			time.Sleep(30 * time.Millisecond)
			go func() { errCh <- client.Run(ctx) }()
			waitReady(t, server, client)

			server.pool.closeAll()
			deadline := time.Now().Add(5 * time.Second)
			for time.Now().Before(deadline) {
				if client.Snapshot().Reconnects > 0 && server.Ready() && client.Ready() {
					break
				}
				time.Sleep(20 * time.Millisecond)
			}
			if client.Snapshot().Reconnects == 0 || !server.Ready() || !client.Ready() {
				t.Fatalf("carrier did not recover: server=%+v client=%+v", server.Snapshot(), client.Snapshot())
			}

			conn, err := net.DialTimeout("tcp", userAddr, 2*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			want := []byte("reconnected")
			if _, err := conn.Write(want); err != nil {
				t.Fatal(err)
			}
			got := make([]byte, len(want))
			if _, err := io.ReadFull(conn, got); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, want) {
				t.Fatalf("reconnected echo mismatch: got %q", got)
			}

			cancel()
			for i := 0; i < 2; i++ {
				select {
				case err := <-errCh:
					if err != nil {
						t.Fatalf("runtime shutdown: %v", err)
					}
				case <-time.After(5 * time.Second):
					t.Fatal("runtime did not shut down")
				}
			}
		})
	}
}

func testEncryptedReverseTunnelEndToEnd(t *testing.T, mode string) {
	echoAddr, stopEcho := startEcho(t)
	defer stopEcho()
	carrierAddr := reserveCarrierAddress(t, mode)
	userAddr := reserveAddress(t)
	psk := strings.Repeat("integration-secret-", 3)

	serverCfg := testConfig("server", psk)
	serverCfg.Carrier.Mode = mode
	serverCfg.Carrier.Listen = carrierAddr
	serverCfg.Mappings = []config.Mapping{{Name: "echo", Protocol: "tcp", Listen: userAddr}}
	clientCfg := testConfig("client", psk)
	clientCfg.Carrier.Mode = mode
	clientCfg.Carrier.Server = carrierAddr
	clientCfg.Mappings = []config.Mapping{{Name: "echo", Protocol: "tcp", Target: echoAddr}}
	if mode == "raw_icmp" {
		if os.Geteuid() != 0 {
			t.Skip("raw ICMP integration requires root or CAP_NET_RAW")
		}
		identifier := int(uint16(time.Now().UnixNano()))
		if identifier == 0 {
			identifier = 0x5632
		}
		raw := config.RawSettings{
			LocalIP:             "127.0.0.1",
			PeerIP:              "127.0.0.1",
			ICMPIdentifier:      identifier,
			PayloadMTU:          1200,
			ExperimentalEnabled: true,
		}
		serverCfg.Carrier.Pool = 1
		clientCfg.Carrier.Pool = 1
		serverCfg.Carrier.Raw = raw
		clientCfg.Carrier.Raw = raw
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelDebug}))
	server := NewRuntime(serverCfg, logger)
	client := NewRuntime(clientCfg, logger)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	errCh := make(chan error, 2)
	go func() { errCh <- server.Run(ctx) }()
	time.Sleep(30 * time.Millisecond)
	go func() { errCh <- client.Run(ctx) }()
	waitReady(t, server, client)

	const streams = 12
	var wg sync.WaitGroup
	for i := 0; i < streams; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := net.DialTimeout("tcp", userAddr, 3*time.Second)
			if err != nil {
				t.Errorf("dial mapped port: %v", err)
				return
			}
			defer conn.Close()
			payload := make([]byte, 128<<10)
			if _, err := rand.Read(payload); err != nil {
				t.Errorf("random payload: %v", err)
				return
			}
			if err := writeFull(conn, payload); err != nil {
				t.Errorf("write payload: %v", err)
				return
			}
			got := make([]byte, len(payload))
			if _, err := io.ReadFull(conn, got); err != nil {
				t.Errorf("read echo: %v", err)
				return
			}
			if !bytes.Equal(got, payload) {
				t.Error("echo payload mismatch")
			}
		}()
	}
	wg.Wait()
	if t.Failed() {
		return
	}
	snapshot := server.Snapshot()
	if snapshot.BytesToExit == 0 || snapshot.BytesToUser == 0 {
		t.Fatalf("traffic counters were not updated: %+v", snapshot)
	}
	cancel()
	for i := 0; i < 2; i++ {
		select {
		case err := <-errCh:
			if err != nil {
				t.Fatalf("runtime shutdown: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("runtime did not shut down")
		}
	}
}

func testConfig(role, psk string) *config.Config {
	return &config.Config{
		Version:  config.CurrentVersion,
		Role:     role,
		NodeName: role + "-test",
		Carrier: config.Carrier{
			Mode:                 "tcp",
			Pool:                 2,
			KeepaliveSeconds:     2,
			DialTimeoutSeconds:   2,
			ReconnectMinMillis:   100,
			ReconnectMaxMillis:   1_000,
			MaxStreamsPerSession: 64,
		},
		Security: config.Security{PSK: psk},
		Health:   config.Health{Listen: "127.0.0.1:0"},
		Logging:  config.Logging{Level: "debug"},
	}
}

func reserveAddress(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := listener.Addr().String()
	_ = listener.Close()
	return addr
}

func reserveCarrierAddress(t *testing.T, mode string) string {
	t.Helper()
	if mode == "quantum_udp" {
		conn, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := conn.LocalAddr().String()
		_ = conn.Close()
		return addr
	}
	return reserveAddress(t)
}

func waitReady(t *testing.T, runtimes ...*Runtime) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		ready := true
		for _, runtime := range runtimes {
			if !runtime.Ready() {
				ready = false
				break
			}
		}
		if ready {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("runtimes did not become ready")
}

func startEcho(t *testing.T) (string, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
			select {
			case <-ctx.Done():
				return
			default:
			}
		}
	}()
	return listener.Addr().String(), func() {
		cancel()
		_ = listener.Close()
	}
}
