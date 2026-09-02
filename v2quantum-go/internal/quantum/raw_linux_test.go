//go:build linux

package quantum_test

import (
	"bytes"
	"context"
	"io"
	"os"
	"testing"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/quantum"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/rawip"
)

func TestQuantumOverRawICMPLoopback(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("raw ICMP integration requires root or CAP_NET_RAW")
	}
	settings := config.RawSettings{
		LocalIP:             "127.0.0.1",
		PeerIP:              "127.0.0.1",
		ICMPIdentifier:      0x5634,
		PayloadMTU:          576,
		ExperimentalEnabled: true,
	}
	serverPackets, err := rawip.ListenPacket(settings, true)
	if err != nil {
		t.Skipf("raw ICMP unavailable: %v", err)
	}
	listener, err := quantum.ListenPacket(serverPackets, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	clientPackets, err := rawip.ListenPacket(settings, false)
	if err != nil {
		t.Skipf("raw ICMP unavailable: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := quantum.DialPacket(ctx, clientPackets, rawip.ExpectedPeerAddr(settings), 4*time.Second, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	serverCh := make(chan struct {
		conn io.ReadWriteCloser
		err  error
	}, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		serverCh <- struct {
			conn io.ReadWriteCloser
			err  error
		}{conn, acceptErr}
	}()
	server := <-serverCh
	if server.err != nil {
		t.Fatal(server.err)
	}
	defer server.conn.Close()

	// Keep this low-MTU test compact because -race substantially slows raw
	// socket delivery. The larger multiplexed raw transfer is covered by the
	// tunnel end-to-end test.
	want := bytes.Repeat([]byte("raw-quantum"), 512)
	writeErr := make(chan error, 1)
	go func() {
		_, err := client.Write(want)
		writeErr <- err
	}()
	got := make([]byte, len(want))
	if _, err := io.ReadFull(server.conn, got); err != nil {
		t.Fatal(err)
	}
	if err := <-writeErr; err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("payload mismatch")
	}
}
