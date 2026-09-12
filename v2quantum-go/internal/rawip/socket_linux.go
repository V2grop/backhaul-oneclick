//go:build linux

package rawip

import (
	"fmt"
	"net"
	"syscall"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

func SendProbe(raw config.RawSettings, payload []byte) error {
	if _, err := Preflight(raw); err != nil {
		return err
	}
	source := net.ParseIP(effectiveSource(raw))
	destination := net.ParseIP(effectiveDestination(raw))
	identifier := uint16(raw.ICMPIdentifier)
	if identifier == 0 {
		identifier = 0x5632
	}
	packet, err := BuildIPv4ICMPEcho(source, destination, identifier, 1, payload, false)
	if err != nil {
		return err
	}
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_RAW)
	if err != nil {
		return fmt.Errorf("open raw socket: %w", err)
	}
	defer syscall.Close(fd)
	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1); err != nil {
		return fmt.Errorf("enable IP_HDRINCL: %w", err)
	}
	if raw.Interface != "" {
		if err := syscall.SetsockoptString(fd, syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, raw.Interface); err != nil {
			return fmt.Errorf("bind raw socket to %s: %w", raw.Interface, err)
		}
	}
	dst := destination.To4()
	if dst == nil {
		return fmt.Errorf("destination is not IPv4")
	}
	addr := &syscall.SockaddrInet4{}
	copy(addr.Addr[:], dst)
	if err := syscall.Sendto(fd, packet, 0, addr); err != nil {
		return fmt.Errorf("send raw probe: %w", err)
	}
	return nil
}
