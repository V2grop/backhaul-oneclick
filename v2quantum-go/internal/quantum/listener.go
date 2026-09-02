package quantum

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"
)

const (
	handshakeNonceSize = 16
	cookieSize         = 32
	cookieBucket       = 30 * time.Second
)

type Listener struct {
	pc          net.PacketConn
	secret      [32]byte
	idleTimeout time.Duration
	acceptCh    chan net.Conn
	done        chan struct{}
	closeOnce   sync.Once
	mu          sync.RWMutex
	conns       map[uint64]*Conn
}

func Listen(address string, idleTimeout time.Duration) (*Listener, error) {
	pc, err := net.ListenPacket("udp", address)
	if err != nil {
		return nil, err
	}
	return ListenPacket(pc, idleTimeout)
}

func tunePacketBuffers(pc net.PacketConn) {
	type bufferTuner interface {
		SetReadBuffer(int) error
		SetWriteBuffer(int) error
	}
	if tuned, ok := pc.(bufferTuner); ok {
		_ = tuned.SetReadBuffer(8 << 20)
		_ = tuned.SetWriteBuffer(8 << 20)
	}
}

func ListenPacket(pc net.PacketConn, idleTimeout time.Duration) (*Listener, error) {
	tunePacketBuffers(pc)
	l := &Listener{
		pc:          pc,
		idleTimeout: idleTimeout,
		acceptCh:    make(chan net.Conn, 128),
		done:        make(chan struct{}),
		conns:       make(map[uint64]*Conn),
	}
	if _, err := rand.Read(l.secret[:]); err != nil {
		_ = pc.Close()
		return nil, err
	}
	go l.readLoop()
	return l, nil
}

func (l *Listener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.acceptCh:
		return conn, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *Listener) Close() error {
	l.closeOnce.Do(func() {
		close(l.done)
		_ = l.pc.Close()
		l.mu.RLock()
		items := make([]*Conn, 0, len(l.conns))
		for _, conn := range l.conns {
			items = append(items, conn)
		}
		l.mu.RUnlock()
		for _, conn := range items {
			conn.close(false)
		}
	})
	return nil
}

func (l *Listener) Addr() net.Addr { return l.pc.LocalAddr() }

func (l *Listener) readLoop() {
	buf := make([]byte, maxDatagram)
	for {
		n, remote, err := l.pc.ReadFrom(buf)
		if err != nil {
			_ = l.Close()
			return
		}
		p, err := parsePacket(buf[:n])
		if err != nil {
			continue
		}
		switch p.typeID {
		case packetHello:
			l.handleHello(remote, p)
		case packetConnect:
			l.handleConnect(remote, p)
		default:
			l.mu.RLock()
			conn := l.conns[p.sessionID]
			l.mu.RUnlock()
			if conn != nil && sameAddr(conn.remote, remote) {
				conn.handle(p)
			}
		}
	}
}

func (l *Listener) handleHello(remote net.Addr, p packet) {
	if len(p.payload) != handshakeNonceSize {
		return
	}
	sessionID, err := randomSessionID()
	if err != nil {
		return
	}
	cookie := l.cookie(remote, p.payload, sessionID, time.Now())
	payload := append(append([]byte(nil), p.payload...), cookie...)
	wire, _ := (packet{typeID: packetCookie, sessionID: sessionID, payload: payload}).marshal()
	_, _ = l.pc.WriteTo(wire, remote)
}

func (l *Listener) handleConnect(remote net.Addr, p packet) {
	if p.sessionID == 0 || len(p.payload) != handshakeNonceSize+cookieSize {
		return
	}
	nonce := p.payload[:handshakeNonceSize]
	cookie := p.payload[handshakeNonceSize:]
	if !l.validCookie(remote, nonce, p.sessionID, cookie) {
		return
	}
	l.mu.Lock()
	conn := l.conns[p.sessionID]
	created := false
	if conn == nil {
		id := p.sessionID
		conn = newConn(l.pc, remote, id, l.idleTimeout, false, func() {
			l.mu.Lock()
			delete(l.conns, id)
			l.mu.Unlock()
		})
		l.conns[p.sessionID] = conn
		created = true
	}
	l.mu.Unlock()
	wire, _ := (packet{typeID: packetAccept, sessionID: p.sessionID}).marshal()
	_, _ = l.pc.WriteTo(wire, remote)
	if created {
		select {
		case l.acceptCh <- conn:
		case <-l.done:
			conn.close(false)
		}
	}
}

func (l *Listener) cookie(remote net.Addr, nonce []byte, sessionID uint64, at time.Time) []byte {
	h := hmac.New(sha256.New, l.secret[:])
	_, _ = h.Write([]byte(remote.String()))
	_, _ = h.Write(nonce)
	var number [16]byte
	binary.BigEndian.PutUint64(number[:8], sessionID)
	binary.BigEndian.PutUint64(number[8:], uint64(at.UnixNano()/int64(cookieBucket)))
	_, _ = h.Write(number[:])
	return h.Sum(nil)
}

func (l *Listener) validCookie(remote net.Addr, nonce []byte, sessionID uint64, got []byte) bool {
	now := time.Now()
	for _, at := range []time.Time{now, now.Add(-cookieBucket)} {
		if hmac.Equal(got, l.cookie(remote, nonce, sessionID, at)) {
			return true
		}
	}
	return false
}

func randomSessionID() (uint64, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return 0, err
	}
	id := binary.BigEndian.Uint64(b[:])
	if id == 0 {
		return 0, errors.New("random session id was zero")
	}
	return id, nil
}

func sameAddr(a, b net.Addr) bool {
	return a != nil && b != nil && a.Network() == b.Network() && a.String() == b.String()
}

var _ net.Listener = (*Listener)(nil)
var _ = fmt.Sprintf
