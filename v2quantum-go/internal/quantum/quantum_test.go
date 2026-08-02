package quantum

import (
	"bytes"
	"context"
	"crypto/rand"
	"io"
	"testing"
	"time"
)

func TestPacketRoundTrip(t *testing.T) {
	want := packet{typeID: packetData, sessionID: 99, sequence: 7, ack: 4, payload: []byte("hello")}
	b, err := want.marshal()
	if err != nil {
		t.Fatal(err)
	}
	got, err := parsePacket(b)
	if err != nil {
		t.Fatal(err)
	}
	if got.typeID != want.typeID || got.sessionID != want.sessionID || got.sequence != want.sequence || got.ack != want.ack || !bytes.Equal(got.payload, want.payload) {
		t.Fatalf("packet mismatch: %#v", got)
	}
}

func TestReliableQuantumConn(t *testing.T) {
	listener, err := Listen("127.0.0.1:0", 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	serverCh := make(chan io.ReadWriteCloser, 1)
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			serverCh <- conn
		}
	}()
	client, err := DialContext(context.Background(), listener.Addr().String(), 3*time.Second, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server := <-serverCh
	defer server.Close()
	payload := make([]byte, 512<<10)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	writeErr := make(chan error, 1)
	go func() {
		_, err := client.Write(payload)
		writeErr <- err
	}()
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(server, got); err != nil {
		t.Fatal(err)
	}
	if err := <-writeErr; err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("quantum payload mismatch")
	}
}
