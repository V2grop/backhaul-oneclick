//go:build linux

package rawip

import (
	"encoding/binary"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

type PacketConn struct {
	recv         *net.IPConn
	sendFD       int
	settings     config.RawSettings
	server       bool
	identifier   uint16
	sequence     atomic.Uint32
	writeMu      sync.Mutex
	readMu       sync.Mutex
	readBuffer   []byte
	closeOnce    sync.Once
	localAddr    *net.IPAddr
	expectedPeer net.IP
}

func ListenPacket(settings config.RawSettings, server bool) (*PacketConn, error) {
	if _, err := Preflight(settings); err != nil {
		return nil, err
	}
	recv, err := net.ListenIP("ip4:icmp", &net.IPAddr{IP: net.IPv4zero})
	if err != nil {
		return nil, err
	}
	// Raw sockets receive the kernel's ordinary ICMP traffic too. A larger
	// buffer prevents tunnel bursts from being dropped behind unrelated packets.
	_ = recv.SetReadBuffer(4 << 20)
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_RAW)
	if err != nil {
		_ = recv.Close()
		return nil, err
	}
	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1); err != nil {
		_ = syscall.Close(fd)
		_ = recv.Close()
		return nil, err
	}
	if settings.Interface != "" {
		if err := syscall.SetsockoptString(fd, syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, settings.Interface); err != nil {
			_ = syscall.Close(fd)
			_ = recv.Close()
			return nil, err
		}
	}
	identifier := uint16(settings.ICMPIdentifier)
	if identifier == 0 {
		identifier = 0x5632
	}
	return &PacketConn{
		recv:       recv,
		sendFD:     fd,
		settings:   settings,
		server:     server,
		identifier: identifier,
		// Leave room for the IPv4 header as well. Depending on the kernel/socket
		// path, a raw receive can account for that header when deciding whether
		// the caller's buffer is large enough, even though ReadFromIP returns the
		// ICMP portion to Go.
		readBuffer:   make([]byte, settings.PayloadMTU+icmpHeaderLen+ipv4HeaderLen),
		localAddr:    &net.IPAddr{IP: net.ParseIP(settings.LocalIP)},
		expectedPeer: net.ParseIP(effectiveDestination(settings)),
	}, nil
}

func (c *PacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	buf := c.readBuffer
	for {
		n, remote, err := c.recv.ReadFromIP(buf)
		if err != nil {
			return 0, nil, err
		}
		if n < icmpHeaderLen || !remote.IP.Equal(c.expectedPeer) {
			continue
		}
		expectedType := byte(8)
		if !c.server {
			expectedType = 0
		}
		if buf[0] != expectedType || buf[1] != 0 {
			continue
		}
		if uint16(buf[4])<<8|uint16(buf[5]) != c.identifier {
			continue
		}
		// Linux automatically answers ICMP echo requests. Reserve the high
		// sequence bit for replies emitted by V2Quantum so the client can ignore
		// those kernel-generated reflections of its own encrypted packets.
		sequence := binary.BigEndian.Uint16(buf[6:8])
		if c.server && sequence&0x8000 != 0 {
			continue
		}
		if !c.server && sequence&0x8000 == 0 {
			continue
		}
		// Verify the checksum only after the cheap tunnel/direction filters. Raw
		// sockets see every ICMP packet on the host, including other instances.
		if checksum(buf[:n]) != 0 {
			continue
		}
		payload := buf[icmpHeaderLen:n]
		if len(payload) > len(p) {
			return 0, nil, errors.New("raw ICMP receive buffer is too small")
		}
		copied := copy(p, payload)
		return copied, remote, nil
	}
}

func (c *PacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	if len(p) > c.settings.PayloadMTU {
		return 0, errors.New("raw ICMP datagram exceeds configured payload_mtu")
	}
	destination := c.expectedPeer
	if c.settings.SpoofDestinationIP == "" {
		if ipAddr, ok := addr.(*net.IPAddr); ok && ipAddr.IP.To4() != nil {
			destination = ipAddr.IP
		}
	}
	source := net.ParseIP(effectiveSource(c.settings))
	sequence := uint16(c.sequence.Add(1) & 0x7fff)
	if sequence == 0 {
		sequence = 1
	}
	if c.server {
		sequence |= 0x8000
	}
	packet, err := BuildIPv4ICMPEcho(source, destination, c.identifier, sequence, p, c.server)
	if err != nil {
		return 0, err
	}
	dst := destination.To4()
	if dst == nil {
		return 0, errors.New("raw ICMP destination is not IPv4")
	}
	sockaddr := &syscall.SockaddrInet4{}
	copy(sockaddr.Addr[:], dst)
	c.writeMu.Lock()
	err = syscall.Sendto(c.sendFD, packet, 0, sockaddr)
	c.writeMu.Unlock()
	if err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *PacketConn) Close() error {
	c.closeOnce.Do(func() {
		_ = c.recv.Close()
		_ = syscall.Close(c.sendFD)
	})
	return nil
}

func (c *PacketConn) LocalAddr() net.Addr { return c.localAddr }

func (c *PacketConn) MaxDatagramSize() int { return c.settings.PayloadMTU }

func (c *PacketConn) SetDeadline(t time.Time) error      { return c.recv.SetDeadline(t) }
func (c *PacketConn) SetReadDeadline(t time.Time) error  { return c.recv.SetReadDeadline(t) }
func (c *PacketConn) SetWriteDeadline(_ time.Time) error { return nil }

func ExpectedPeerAddr(settings config.RawSettings) net.Addr {
	return &net.IPAddr{IP: net.ParseIP(effectiveDestination(settings))}
}

var _ net.PacketConn = (*PacketConn)(nil)
