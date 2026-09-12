//go:build !linux

package rawip

import (
	"errors"
	"net"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

func ListenPacket(_ config.RawSettings, _ bool) (net.PacketConn, error) {
	return nil, errors.New("raw ICMP transport is Linux-only")
}

func ExpectedPeerAddr(settings config.RawSettings) net.Addr {
	return &net.IPAddr{IP: net.ParseIP(settings.PeerIP)}
}
