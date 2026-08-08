package tunnel

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/secure"
)

func TestFusionMuxRuntimeUsesAllUnderlaysAndFailsOver(t *testing.T) {
	echoAddr, stopEcho := startEcho(t)
	defer stopEcho()
	quantumAddr := reserveCarrierAddress(t, "quantum_udp")
	websocketAddr := reserveAddress(t)
	tcpAddr := reserveAddress(t)
	userAddr := reserveAddress(t)
	psk := strings.Repeat("fusion-runtime-secret-", 2)

	serverCfg := fusionRuntimeConfig("server", psk, []config.FusionPath{
		{Name: "quantum", Mode: "quantum_udp", Listen: quantumAddr, Priority: 10, Pool: 1},
		{Name: "websocket", Mode: "websocket", Listen: websocketAddr, Priority: 20, Pool: 1, WebSocket: config.WebSocket{Path: "/fusion-test"}},
		{Name: "tcp", Mode: "tcp", Listen: tcpAddr, Priority: 30, Pool: 1},
	})
	serverCfg.Mappings = []config.Mapping{{Name: "echo", Protocol: "tcp", Listen: userAddr}}
	clientCfg := fusionRuntimeConfig("client", psk, []config.FusionPath{
		{Name: "quantum", Mode: "quantum_udp", Server: quantumAddr, Priority: 10, Pool: 1},
		{Name: "websocket", Mode: "websocket", Server: websocketAddr, Priority: 20, Pool: 1, WebSocket: config.WebSocket{Path: "/fusion-test"}},
		{Name: "tcp", Mode: "tcp", Server: tcpAddr, Priority: 30, Pool: 1},
	})
	clientCfg.Mappings = []config.Mapping{{Name: "echo", Protocol: "tcp", Target: echoAddr}}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := NewRuntime(serverCfg, logger)
	client := NewRuntime(clientCfg, logger)
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 2)
	go func() { errCh <- server.Run(ctx) }()
	time.Sleep(30 * time.Millisecond)
	go func() { errCh <- client.Run(ctx) }()
	waitFusionLinks(t, server, client, 3)
	waitRuntimeFusionPrimary(t, server, "quantum")
	waitRuntimeFusionPrimary(t, client, "quantum")

	conn, err := net.DialTimeout("tcp", userAddr, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	assertFusionEcho(t, conn, []byte("runtime-before-failure"))

	serverHub := server.fusion.Load()
	serverHub.mu.RLock()
	primary := serverHub.primary
	serverHub.mu.RUnlock()
	if primary == nil || primary.name != "quantum" {
		t.Fatalf("unexpected primary before failure: %#v", primary)
	}
	primary.shutdown(net.ErrClosed)
	waitRuntimeFusionPrimary(t, server, "websocket")
	waitRuntimeFusionPrimary(t, client, "websocket")
	assertFusionEcho(t, conn, bytes.Repeat([]byte("runtime-after-failure-"), 2048))

	cancel()
	for i := 0; i < 2; i++ {
		select {
		case err := <-errCh:
			if err != nil {
				t.Fatalf("FusionMux runtime shutdown: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("FusionMux runtime did not shut down")
		}
	}
}

func fusionRuntimeConfig(role, psk string, paths []config.FusionPath) *config.Config {
	return &config.Config{
		Version: config.CurrentVersion, Role: role, NodeName: role + "-fusion-test",
		Carrier: config.Carrier{
			Mode: "fusion", Pool: 1, KeepaliveSeconds: 2, DialTimeoutSeconds: 2,
			ReconnectMinMillis: 100, ReconnectMaxMillis: 1_000, MaxStreamsPerSession: 64,
			Fusion: config.Fusion{
				Policy: "failover", UnavailableTimeoutSecs: 5, RecoveryHoldSeconds: 300,
				ReplayBufferBytes: 1 << 20, Paths: paths,
			},
		},
		Security: config.Security{PSK: psk},
		Health:   config.Health{Listen: "127.0.0.1:0"},
		Logging:  config.Logging{Level: "debug"},
	}
}

func waitFusionLinks(t *testing.T, server, client *Runtime, want int64) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if server.Snapshot().FusionLinks >= want && client.Snapshot().FusionLinks >= want {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("FusionMux paths did not become ready: server=%+v client=%+v", server.Snapshot(), client.Snapshot())
}

func waitRuntimeFusionPrimary(t *testing.T, runtime *Runtime, want string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if runtime.Snapshot().FusionPrimary == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("runtime primary did not become %q: %+v", want, runtime.Snapshot())
}

func TestFusionMuxActiveFlowSurvivesTwoPathFailures(t *testing.T) {
	echoAddr, stopEcho := startEcho(t)
	defer stopEcho()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	serverStats := &Stats{}
	clientStats := &Stats{}
	serverHub := newFusionHub(ctx, logger, serverStats, "server", nil,
		200*time.Millisecond, time.Second, 3*time.Second, time.Hour, 1<<20)
	clientHub := newFusionHub(ctx, logger, clientStats, "client", map[string]string{"echo": echoAddr},
		200*time.Millisecond, time.Second, 3*time.Second, time.Hour, 1<<20)
	defer serverHub.closeAll()
	defer clientHub.closeAll()

	psk := []byte(strings.Repeat("fusion-failover-secret-", 2))
	quantum := addFusionTestPath(t, serverHub, clientHub, psk, "quantum", "quantum_udp", 10)
	websocket := addFusionTestPath(t, serverHub, clientHub, psk, "websocket", "websocket", 20)
	_ = addFusionTestPath(t, serverHub, clientHub, psk, "tcp", "tcp", 30)
	waitFusionPrimary(t, serverHub, "quantum")
	waitFusionPrimary(t, clientHub, "quantum")

	userConn, tunnelConn := net.Pipe()
	defer userConn.Close()
	flow := newFusionFlow(serverHub.nextFlowID(), serverHub, "echo", tunnelConn, true)
	if !serverHub.addFlow(flow) {
		t.Fatal("could not add test FusionMux flow")
	}
	openCtx, openCancel := context.WithTimeout(ctx, 3*time.Second)
	defer openCancel()
	if err := flow.open(openCtx); err != nil {
		t.Fatalf("open FusionMux flow: %v", err)
	}

	assertFusionEcho(t, userConn, []byte("before-failover"))
	quantum.shutdown(net.ErrClosed)
	waitFusionPrimary(t, serverHub, "websocket")
	waitFusionPrimary(t, clientHub, "websocket")
	assertFusionEcho(t, userConn, bytes.Repeat([]byte("websocket-path-"), 4096))

	websocket.shutdown(net.ErrClosed)
	waitFusionPrimary(t, serverHub, "tcp")
	waitFusionPrimary(t, clientHub, "tcp")
	assertFusionEcho(t, userConn, bytes.Repeat([]byte("tcp-fallback-"), 4096))

	if got := serverStats.Snapshot().FusionFailovers; got < 2 {
		t.Fatalf("server recorded %d failovers, want at least 2", got)
	}
	if got := clientStats.Snapshot().FusionFailovers; got < 2 {
		t.Fatalf("client recorded %d failovers, want at least 2", got)
	}
}

func addFusionTestPath(t *testing.T, serverHub, clientHub *fusionHub, psk []byte, name, mode string, priority int) *fusionLink {
	t.Helper()
	serverRaw, clientRaw := net.Pipe()
	serverResult := make(chan struct {
		conn *secure.Conn
		err  error
	}, 1)
	go func() {
		conn, err := secure.Server(serverRaw, psk)
		serverResult <- struct {
			conn *secure.Conn
			err  error
		}{conn: conn, err: err}
	}()
	clientConn, err := secure.Client(clientRaw, psk)
	if err != nil {
		t.Fatalf("secure client path %s: %v", name, err)
	}
	serverHandshake := <-serverResult
	if serverHandshake.err != nil {
		t.Fatalf("secure server path %s: %v", name, serverHandshake.err)
	}
	serverLink := serverHub.addLink(serverHandshake.conn, name, mode, priority)
	if serverLink == nil {
		t.Fatalf("server rejected path %s", name)
	}
	if clientHub.addLink(clientConn, name, mode, priority) == nil {
		t.Fatalf("client rejected path %s", name)
	}
	return serverLink
}

func waitFusionPrimary(t *testing.T, hub *fusionHub, want string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		hub.mu.RLock()
		primary := hub.primary
		name := ""
		if primary != nil {
			name = primary.name
		}
		hub.mu.RUnlock()
		if name == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("FusionMux primary did not become %q", want)
}

func assertFusionEcho(t *testing.T, conn net.Conn, payload []byte) {
	t.Helper()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := writeFull(conn, payload); err != nil {
		t.Fatalf("write FusionMux payload: %v", err)
	}
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatalf("read FusionMux payload: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("FusionMux payload mismatch")
	}
	_ = conn.SetDeadline(time.Time{})
}
