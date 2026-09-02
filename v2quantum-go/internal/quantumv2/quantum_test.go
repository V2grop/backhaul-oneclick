package quantumv2

import (
	"bytes"
	"context"
	"crypto/rand"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type testObserver struct {
	retransmits  atomic.Int64
	fast         atomic.Int64
	fecSent      atomic.Int64
	fecRecovered atomic.Int64
	srttMillis   atomic.Int64
	rtoMillis    atomic.Int64
	window       atomic.Int64
}

func (o *testObserver) ObserveRTT(srtt, rto time.Duration) {
	o.srttMillis.Store(srtt.Milliseconds())
	o.rtoMillis.Store(rto.Milliseconds())
}
func (o *testObserver) ObserveWindow(cwnd int) { o.window.Store(int64(cwnd)) }
func (o *testObserver) CountRetransmit(fast bool) {
	o.retransmits.Add(1)
	if fast {
		o.fast.Add(1)
	}
}
func (o *testObserver) CountFECSent()      { o.fecSent.Add(1) }
func (o *testObserver) CountFECRecovered() { o.fecRecovered.Add(1) }

func TestReliableQuantumV2WithLossReorderAndFEC(t *testing.T) {
	observer := &testObserver{}
	settings := DefaultSettings("balanced")
	settings.FECDataShards = 4
	settings.FECParityShards = 2
	settings.Observer = observer
	listener, err := Listen("127.0.0.1:0", 10*time.Second, settings)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	serverCh := make(chan io.ReadWriteCloser, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			serverCh <- conn
		}
	}()
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	chaos := &chaosPacketConn{PacketConn: udp, seen: make(map[uint32]bool), fecGroup: 4, lossesPerGroup: 2}
	client, err := DialPacket(context.Background(), chaos, listener.Addr(), 3*time.Second, 10*time.Second, settings)
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
		_, writeError := client.Write(payload)
		writeErr <- writeError
	}()
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(server, got); err != nil {
		t.Fatal(err)
	}
	if err := <-writeErr; err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("quantum v2 payload mismatch after loss and reordering")
	}
	if observer.fecSent.Load() == 0 || observer.fecRecovered.Load() < 2 {
		t.Fatalf("FEC was not exercised: sent=%d recovered=%d", observer.fecSent.Load(), observer.fecRecovered.Load())
	}
	if observer.srttMillis.Load() <= 0 || observer.rtoMillis.Load() <= 0 || observer.window.Load() <= 0 {
		t.Fatalf("adaptive telemetry missing: srtt=%d rto=%d window=%d", observer.srttMillis.Load(), observer.rtoMillis.Load(), observer.window.Load())
	}
}

func TestReliableQuantumV2BothDirections(t *testing.T) {
	settings := DefaultSettings("max")
	listener, err := Listen("127.0.0.1:0", 10*time.Second, settings)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	serverCh := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			serverCh <- conn
		}
	}()
	client, err := DialContext(context.Background(), listener.Addr().String(), 3*time.Second, 10*time.Second, settings)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server := <-serverCh
	defer server.Close()

	wantClient := bytes.Repeat([]byte("client-to-server"), 8192)
	wantServer := bytes.Repeat([]byte("server-to-client"), 8192)
	errCh := make(chan error, 4)
	go func() { _, err := client.Write(wantClient); errCh <- err }()
	go func() { _, err := server.Write(wantServer); errCh <- err }()
	gotServer := make([]byte, len(wantClient))
	gotClient := make([]byte, len(wantServer))
	go func() { _, err := io.ReadFull(server, gotServer); errCh <- err }()
	go func() { _, err := io.ReadFull(client, gotClient); errCh <- err }()
	for range 4 {
		if err := <-errCh; err != nil {
			t.Fatal(err)
		}
	}
	if !bytes.Equal(gotServer, wantClient) || !bytes.Equal(gotClient, wantServer) {
		t.Fatal("bidirectional quantum v2 payload mismatch")
	}
}

func TestReliableQuantumV2RetransmitsWithoutFEC(t *testing.T) {
	observer := &testObserver{}
	settings := DefaultSettings("manual")
	settings.AutoTune = true
	settings.FECDataShards = 0
	settings.FECParityShards = 0
	settings.InitialRTO = 80 * time.Millisecond
	settings.MinRTO = 20 * time.Millisecond
	settings.MaxRTO = 500 * time.Millisecond
	settings.MaxRetries = 8
	settings.Observer = observer

	listener, err := Listen("127.0.0.1:0", 10*time.Second, settings)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	serverCh := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			serverCh <- conn
		}
	}()

	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	lossy := &dropOncePacketConn{PacketConn: udp, sequence: 2}
	client, err := DialPacket(context.Background(), lossy, listener.Addr(), 3*time.Second, 10*time.Second, settings)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server := <-serverCh
	defer server.Close()
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	_ = server.SetDeadline(time.Now().Add(5 * time.Second))

	payload := bytes.Repeat([]byte("quantum-v2-retransmit-"), 8192)
	writeErr := make(chan error, 1)
	go func() {
		_, writeError := client.Write(payload)
		writeErr <- writeError
	}()
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(server, got); err != nil {
		t.Fatal(err)
	}
	if err := <-writeErr; err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("quantum v2 payload mismatch after retransmission")
	}
	if !lossy.dropped.Load() {
		t.Fatal("loss fixture did not drop the selected packet")
	}
	if observer.retransmits.Load() == 0 {
		t.Fatal("transport did not report a retransmission with FEC disabled")
	}
	if observer.fecSent.Load() != 0 || observer.fecRecovered.Load() != 0 {
		t.Fatalf("FEC unexpectedly ran while disabled: sent=%d recovered=%d", observer.fecSent.Load(), observer.fecRecovered.Load())
	}
}

type chaosPacketConn struct {
	net.PacketConn
	mu             sync.Mutex
	seen           map[uint32]bool
	fecGroup       uint32
	lossesPerGroup uint32
}

func (c *chaosPacketConn) MaxDatagramSize() int { return 1400 }

func (c *chaosPacketConn) WriteTo(b []byte, addr net.Addr) (int, error) {
	p, err := parsePacket(b)
	if err != nil || p.typeID != packetData {
		return c.PacketConn.WriteTo(b, addr)
	}
	c.mu.Lock()
	first := !c.seen[p.sequence]
	if first {
		c.seen[p.sequence] = true
	}
	c.mu.Unlock()
	if first && c.fecGroup > 0 {
		offset := (p.sequence - 1) % c.fecGroup
		if offset > 0 && offset <= c.lossesPerGroup {
			return len(b), nil
		}
	}
	if first && p.sequence%11 == 0 {
		copyOfPacket := append([]byte(nil), b...)
		go func() {
			time.Sleep(15 * time.Millisecond)
			_, _ = c.PacketConn.WriteTo(copyOfPacket, addr)
		}()
		return len(b), nil
	}
	return c.PacketConn.WriteTo(b, addr)
}

type dropOncePacketConn struct {
	net.PacketConn
	sequence uint32
	dropped  atomic.Bool
}

func (c *dropOncePacketConn) MaxDatagramSize() int { return 1400 }

func (c *dropOncePacketConn) WriteTo(b []byte, addr net.Addr) (int, error) {
	p, err := parsePacket(b)
	if err == nil && p.typeID == packetData && p.sequence == c.sequence && c.dropped.CompareAndSwap(false, true) {
		return len(b), nil
	}
	return c.PacketConn.WriteTo(b, addr)
}
