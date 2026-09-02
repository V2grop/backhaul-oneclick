package rawip

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"runtime"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

const (
	ipv4HeaderLen = 20
	icmpHeaderLen = 8
)

type PreflightReport struct {
	Platform           string `json:"platform"`
	RunningAsRoot      bool   `json:"running_as_root"`
	InterfaceFound     bool   `json:"interface_found"`
	LocalIPAssigned    bool   `json:"local_ip_assigned"`
	SourceIPAssigned   bool   `json:"source_ip_assigned"`
	UnroutedSpoof      bool   `json:"unrouted_spoof"`
	ConfiguredSource   string `json:"configured_source"`
	ConfiguredTarget   string `json:"configured_target"`
	ExpectedPeerSource string `json:"expected_peer_source"`
	ProviderCheckNote  string `json:"provider_check_note"`
}

func Preflight(raw config.RawSettings) (PreflightReport, error) {
	report := PreflightReport{
		Platform:           runtime.GOOS,
		RunningAsRoot:      os.Geteuid() == 0,
		ConfiguredSource:   effectiveSource(raw),
		ConfiguredTarget:   effectiveDestination(raw),
		ExpectedPeerSource: effectiveExpectedPeer(raw),
		ProviderCheckNote:  "The program cannot verify provider BCP38/anti-spoof policy; confirm it with the provider and a peer-side packet capture.",
	}
	if runtime.GOOS != "linux" {
		return report, errors.New("raw ICMP transport is Linux-only")
	}
	if raw.Interface != "" {
		if _, err := net.InterfaceByName(raw.Interface); err == nil {
			report.InterfaceFound = true
		} else {
			return report, fmt.Errorf("interface %q: %w", raw.Interface, err)
		}
	} else {
		report.InterfaceFound = true
	}
	report.LocalIPAssigned = ipAssigned(net.ParseIP(raw.LocalIP))
	report.SourceIPAssigned = ipAssigned(net.ParseIP(report.ConfiguredSource))
	report.UnroutedSpoof = !report.SourceIPAssigned
	if !report.RunningAsRoot {
		return report, errors.New("raw mode requires root or CAP_NET_RAW")
	}
	if !report.LocalIPAssigned {
		return report, fmt.Errorf("local_ip %s is not assigned to this host", raw.LocalIP)
	}
	if report.UnroutedSpoof && !raw.AllowUnroutedSpoof {
		return report, errors.New("source IP is not assigned locally and allow_unrouted_spoof is false")
	}
	return report, nil
}

func BuildIPv4ICMPEcho(source, destination net.IP, identifier, sequence uint16, payload []byte, reply bool) ([]byte, error) {
	src := source.To4()
	dst := destination.To4()
	if src == nil || dst == nil {
		return nil, errors.New("source and destination must be IPv4")
	}
	if len(payload) > 65_507 {
		return nil, errors.New("payload is too large")
	}
	total := ipv4HeaderLen + icmpHeaderLen + len(payload)
	packet := make([]byte, total)
	packet[0] = 0x45
	packet[1] = 0
	binary.BigEndian.PutUint16(packet[2:4], uint16(total))
	binary.BigEndian.PutUint16(packet[4:6], identifier^sequence)
	binary.BigEndian.PutUint16(packet[6:8], 0x4000)
	packet[8] = 64
	packet[9] = 1
	copy(packet[12:16], src)
	copy(packet[16:20], dst)
	binary.BigEndian.PutUint16(packet[10:12], checksum(packet[:ipv4HeaderLen]))

	icmp := packet[ipv4HeaderLen:]
	if reply {
		icmp[0] = 0
	} else {
		icmp[0] = 8
	}
	icmp[1] = 0
	binary.BigEndian.PutUint16(icmp[4:6], identifier)
	binary.BigEndian.PutUint16(icmp[6:8], sequence)
	copy(icmp[icmpHeaderLen:], payload)
	binary.BigEndian.PutUint16(icmp[2:4], checksum(icmp))
	return packet, nil
}

func effectiveSource(raw config.RawSettings) string {
	if raw.SpoofSourceIP != "" {
		return raw.SpoofSourceIP
	}
	return raw.LocalIP
}

func effectiveDestination(raw config.RawSettings) string {
	if raw.SpoofDestinationIP != "" {
		return raw.SpoofDestinationIP
	}
	return raw.PeerIP
}

func effectiveExpectedPeer(raw config.RawSettings) string {
	if raw.ExpectedPeerSourceIP != "" {
		return raw.ExpectedPeerSourceIP
	}
	return effectiveDestination(raw)
}

func ipAssigned(want net.IP) bool {
	if want == nil {
		return false
	}
	// Some restricted containers hide IPv4 interface addresses from netlink even
	// though the kernel loopback route is present. A loopback address is local by
	// definition as long as the loopback interface exists.
	if want.IsLoopback() {
		return true
	}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return false
	}
	for _, addr := range addrs {
		var candidate net.IP
		switch value := addr.(type) {
		case *net.IPNet:
			candidate = value.IP
		case *net.IPAddr:
			candidate = value.IP
		}
		if candidate != nil && candidate.Equal(want) {
			return true
		}
	}
	return false
}

func checksum(data []byte) uint16 {
	var sum uint32
	for len(data) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(data[:2]))
		data = data[2:]
	}
	if len(data) == 1 {
		sum += uint32(data[0]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}
