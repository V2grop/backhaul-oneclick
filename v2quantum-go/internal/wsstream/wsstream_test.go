package wsstream

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPlainRoundTrip(t *testing.T) {
	listener, err := Listen("127.0.0.1:0", ServerSettings{Path: "/fusion"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	serverErr := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			serverErr <- err
			return
		}
		defer conn.Close()
		_, err = io.Copy(conn, conn)
		serverErr <- err
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := DialContext(ctx, listener.Addr().String(), ClientSettings{Path: "/fusion"})
	if err != nil {
		t.Fatal(err)
	}
	payload := bytes.Repeat([]byte("fusion-websocket-"), 32<<10)
	if _, err := client.Write(payload); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(client, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("round-trip payload changed")
	}
	_ = client.Close()
	select {
	case err := <-serverErr:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server did not stop")
	}
}

func TestTLSRoundTrip(t *testing.T) {
	certFile, keyFile := testCertificate(t)
	listener, err := Listen("127.0.0.1:0", ServerSettings{
		Path: "/secure", TLSCertFile: certFile, TLSKeyFile: keyFile,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			defer conn.Close()
			buffer := make([]byte, 64)
			n, readErr := conn.Read(buffer)
			if readErr == nil {
				_, _ = conn.Write(buffer[:n])
			}
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := DialContext(ctx, listener.Addr().String(), ClientSettings{
		Path: "/secure", TLS: true, ServerName: "localhost", InsecureSkipVerify: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if _, err := client.Write([]byte("hello over wss")); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len("hello over wss"))
	if _, err := io.ReadFull(client, got); err != nil {
		t.Fatal(err)
	}
	if string(got) != "hello over wss" {
		t.Fatalf("got %q", got)
	}
}

func TestRejectWrongPath(t *testing.T) {
	listener, err := Listen("127.0.0.1:0", ServerSettings{Path: "/right"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if conn, err := DialContext(ctx, listener.Addr().String(), ClientSettings{Path: "/wrong"}); err == nil {
		_ = conn.Close()
		t.Fatal("wrong WebSocket path was accepted")
	}
}

func TestFragmentReassembly(t *testing.T) {
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	client := newConn(left, nil, true)
	server := newConn(right, nil, false)
	errCh := make(chan error, 1)
	go func() {
		client.writeMu.Lock()
		err := client.writeFrameLocked(false, opBinary, []byte("hello "))
		if err == nil {
			err = client.writeFrameLocked(true, opContinuation, []byte("world"))
		}
		client.writeMu.Unlock()
		errCh <- err
	}()
	got := make([]byte, 11)
	if _, err := io.ReadFull(server, got); err != nil {
		t.Fatal(err)
	}
	if string(got) != "hello world" {
		t.Fatalf("got %q", got)
	}
	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
}

func testCertificate(t *testing.T) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	template := x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	certFile, keyFile := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	return certFile, keyFile
}
