package secure

import (
	"bytes"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/protocol"
)

func TestMutualHandshakeAndFrames(t *testing.T) {
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	psk := []byte(strings.Repeat("p", 48))
	type result struct {
		conn *Conn
		err  error
	}
	serverResult := make(chan result, 1)
	go func() {
		conn, err := Server(left, psk)
		serverResult <- result{conn, err}
	}()
	client, err := Client(right, psk)
	if err != nil {
		t.Fatal(err)
	}
	server := <-serverResult
	if server.err != nil {
		t.Fatal(server.err)
	}
	want := protocol.Frame{Type: protocol.Data, StreamID: 7, Payload: []byte("secret payload")}
	errCh := make(chan error, 1)
	go func() { errCh <- client.WriteFrame(want) }()
	got, err := server.conn.ReadFrame()
	if err != nil {
		t.Fatal(err)
	}
	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
	if got.Type != want.Type || got.StreamID != want.StreamID || !bytes.Equal(got.Payload, want.Payload) {
		t.Fatalf("unexpected frame: %#v", got)
	}
}

func TestWrongPSKRejected(t *testing.T) {
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	_ = left.SetDeadline(time.Now().Add(2 * time.Second))
	_ = right.SetDeadline(time.Now().Add(2 * time.Second))
	serverErr := make(chan error, 1)
	go func() {
		_, err := Server(left, []byte(strings.Repeat("a", 48)))
		serverErr <- err
	}()
	if _, err := Client(right, []byte(strings.Repeat("b", 48))); err == nil {
		t.Fatal("client accepted server with a different PSK")
	}
	if err := <-serverErr; err == nil {
		t.Fatal("server accepted client with a different PSK")
	}
}
