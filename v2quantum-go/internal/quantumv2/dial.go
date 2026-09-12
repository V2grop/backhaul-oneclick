package quantumv2

import (
	"context"
	"crypto/rand"
	"net"
	"time"
)

func DialContext(ctx context.Context, address string, timeout, idleTimeout time.Duration, settings Settings) (*Conn, error) {
	remote, err := net.ResolveUDPAddr("udp", address)
	if err != nil {
		return nil, err
	}
	pc, err := net.ListenPacket("udp", "0.0.0.0:0")
	if err != nil {
		return nil, err
	}
	return DialPacket(ctx, pc, remote, timeout, idleTimeout, settings)
}

func DialPacket(ctx context.Context, pc net.PacketConn, remote net.Addr, timeout, idleTimeout time.Duration, settings Settings) (*Conn, error) {
	settings = settings.normalized()
	tunePacketBuffers(pc, settings.SocketBufferBytes)
	success := false
	defer func() {
		if !success {
			_ = pc.Close()
		}
	}()
	if timeout <= 0 {
		timeout = 8 * time.Second
	}
	handshakeCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	nonce := make([]byte, handshakeNonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	hello, _ := (packet{typeID: packetHello, payload: nonce}).marshal()
	buf := make([]byte, hardMaxDatagram)
	var sessionID uint64
	var connect []byte
	stage := packetCookie
	retry := clampDuration(settings.InitialRTO, 100*time.Millisecond, 500*time.Millisecond)
	for {
		if stage == packetCookie {
			if _, err := pc.WriteTo(hello, remote); err != nil {
				return nil, err
			}
		} else {
			if _, err := pc.WriteTo(connect, remote); err != nil {
				return nil, err
			}
		}
		_ = pc.SetReadDeadline(time.Now().Add(retry))
		n, from, err := pc.ReadFrom(buf)
		if err != nil {
			if netErr, ok := err.(net.Error); !ok || !netErr.Timeout() {
				return nil, err
			}
			select {
			case <-handshakeCtx.Done():
				return nil, handshakeCtx.Err()
			default:
				continue
			}
		}
		if !sameAddr(from, remote) {
			continue
		}
		p, err := parsePacket(buf[:n])
		if err != nil {
			continue
		}
		if stage == packetCookie && p.typeID == packetCookie && len(p.payload) == handshakeNonceSize+cookieSize {
			if !equalBytes(p.payload[:handshakeNonceSize], nonce) {
				continue
			}
			sessionID = p.sessionID
			connect, _ = (packet{typeID: packetConnect, sessionID: sessionID, payload: p.payload}).marshal()
			stage = packetAccept
			continue
		}
		if stage == packetAccept && p.typeID == packetAccept && p.sessionID == sessionID {
			_ = pc.SetReadDeadline(time.Time{})
			conn := newConn(pc, remote, sessionID, idleTimeout, settings, true, nil)
			go clientReadLoop(conn)
			success = true
			return conn, nil
		}
	}
}

func clientReadLoop(conn *Conn) {
	buf := make([]byte, hardMaxDatagram)
	for {
		n, from, err := conn.pc.ReadFrom(buf)
		if err != nil {
			conn.close(false)
			return
		}
		if !sameAddr(from, conn.remote) {
			continue
		}
		p, err := parsePacket(buf[:n])
		if err == nil && p.sessionID == conn.sessionID {
			conn.handle(p)
		}
	}
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
