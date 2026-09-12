//go:build linux

package rawip

import (
	"bytes"
	"net"
	"os"
	"testing"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

func TestPacketConnLoopback(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("raw ICMP integration requires root or CAP_NET_RAW")
	}
	settings := config.RawSettings{
		LocalIP:             "127.0.0.1",
		PeerIP:              "127.0.0.1",
		ICMPIdentifier:      0x5633,
		PayloadMTU:          1200,
		ExperimentalEnabled: true,
	}
	server, err := ListenPacket(settings, true)
	if err != nil {
		t.Skipf("raw ICMP unavailable: %v", err)
	}
	defer server.Close()
	client, err := ListenPacket(settings, false)
	if err != nil {
		t.Skipf("raw ICMP unavailable: %v", err)
	}
	defer client.Close()

	want := bytes.Repeat([]byte("v2q"), settings.PayloadMTU/3)
	errCh := make(chan error, 1)
	go func() {
		_ = server.SetReadDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 2048)
		n, remote, readErr := server.ReadFrom(buf)
		if readErr != nil {
			errCh <- readErr
			return
		}
		_, writeErr := server.WriteTo(buf[:n], remote)
		errCh <- writeErr
	}()

	if _, err := client.WriteTo(want, &net.IPAddr{IP: net.ParseIP("127.0.0.1")}); err != nil {
		t.Fatal(err)
	}
	_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 2048)
	n, _, err := client.ReadFrom(buf)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buf[:n], want) {
		t.Fatalf("payload mismatch: got %q want %q", buf[:n], want)
	}
	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
}
