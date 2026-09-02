package rawip

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"sort"
	"time"
)

const scanPayloadPrefix = "V2Q-SOURCE-SCAN-1"

// SourceCandidate is an IPv4 address that is actually assigned to an active
// local interface. The automatic scanner deliberately does not invent or
// expand third-party address ranges.
type SourceCandidate struct {
	IP        string `json:"ip"`
	Interface string `json:"interface"`
	Private   bool   `json:"private"`
}

// SourceScanResult contains an ordinary, non-spoofed ICMP reachability test
// bound to one locally assigned source address.
type SourceScanResult struct {
	SourceCandidate
	Sent         int     `json:"sent"`
	Received     int     `json:"received"`
	LossPercent  float64 `json:"loss_percent"`
	MinRTTMillis float64 `json:"min_rtt_millis,omitempty"`
	AvgRTTMillis float64 `json:"avg_rtt_millis,omitempty"`
	MaxRTTMillis float64 `json:"max_rtt_millis,omitempty"`
	Error        string  `json:"error,omitempty"`
}

type SourceScanReport struct {
	Peer       string             `json:"peer"`
	Count      int                `json:"count"`
	Timeout    string             `json:"timeout"`
	Candidates []SourceScanResult `json:"candidates"`
	Selected   string             `json:"selected,omitempty"`
	Note       string             `json:"note"`
}

// DiscoverAssignedIPv4 returns only addresses present on an UP interface.
// Loopback, link-local, unspecified and multicast addresses are excluded.
func DiscoverAssignedIPv4() ([]SourceCandidate, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, fmt.Errorf("list network interfaces: %w", err)
	}
	seen := make(map[string]struct{})
	candidates := make([]SourceCandidate, 0, len(interfaces))
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch value := addr.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			ip = ip.To4()
			if ip == nil || !ip.IsGlobalUnicast() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}
			value := ip.String()
			if _, exists := seen[value]; exists {
				continue
			}
			seen[value] = struct{}{}
			candidates = append(candidates, SourceCandidate{
				IP:        value,
				Interface: iface.Name,
				Private:   ip.IsPrivate(),
			})
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].Private != candidates[j].Private {
			return !candidates[i].Private
		}
		if candidates[i].Interface != candidates[j].Interface {
			return candidates[i].Interface < candidates[j].Interface
		}
		return candidates[i].IP < candidates[j].IP
	})
	return candidates, nil
}

// ScanAssignedSources probes a peer using each locally assigned source. It is
// a reachability/routing scan, not proof that a provider permits an arbitrary
// forged source address.
func ScanAssignedSources(ctx context.Context, peer net.IP, count int, timeout time.Duration) (SourceScanReport, error) {
	peer = peer.To4()
	if peer == nil || !peer.IsGlobalUnicast() {
		return SourceScanReport{}, errors.New("peer must be a unicast IPv4 address")
	}
	if count < 1 || count > 10 {
		return SourceScanReport{}, errors.New("scan count must be between 1 and 10")
	}
	if timeout < 200*time.Millisecond || timeout > 10*time.Second {
		return SourceScanReport{}, errors.New("scan timeout must be between 200ms and 10s")
	}
	candidates, err := DiscoverAssignedIPv4()
	if err != nil {
		return SourceScanReport{}, err
	}
	if len(candidates) == 0 {
		return SourceScanReport{}, errors.New("no non-loopback IPv4 address is assigned to an active interface")
	}
	if len(candidates) > 64 {
		return SourceScanReport{}, errors.New("more than 64 assigned IPv4 addresses found; use manual selection")
	}
	report := SourceScanReport{
		Peer:    peer.String(),
		Count:   count,
		Timeout: timeout.String(),
		Note:    "Automatic mode scans only locally assigned addresses. Peer-side/provider anti-spoof policy still requires an authorized two-sided test.",
	}
	for _, candidate := range candidates {
		result := SourceScanResult{SourceCandidate: candidate, Sent: count, LossPercent: 100}
		rtts, probeErr := probeAssignedSource(ctx, net.ParseIP(candidate.IP), peer, count, timeout)
		result.Received = len(rtts)
		result.LossPercent = float64(count-len(rtts)) * 100 / float64(count)
		if len(rtts) > 0 {
			result.MinRTTMillis, result.AvgRTTMillis, result.MaxRTTMillis = summarizeRTT(rtts)
		}
		if probeErr != nil {
			result.Error = probeErr.Error()
		}
		report.Candidates = append(report.Candidates, result)
	}
	report.Selected = SelectBestSource(report.Candidates, count)
	return report, nil
}

// SelectBestSource requires at least two thirds of probes to return, then
// ranks by loss, average RTT, public-before-private, and stable IP ordering.
func SelectBestSource(results []SourceScanResult, sent int) string {
	if sent < 1 {
		return ""
	}
	minimum := (2*sent + 2) / 3
	eligible := make([]SourceScanResult, 0, len(results))
	for _, result := range results {
		if result.Received >= minimum && result.Error == "" {
			eligible = append(eligible, result)
		}
	}
	if len(eligible) == 0 {
		return ""
	}
	sort.SliceStable(eligible, func(i, j int) bool {
		if eligible[i].LossPercent != eligible[j].LossPercent {
			return eligible[i].LossPercent < eligible[j].LossPercent
		}
		if eligible[i].AvgRTTMillis != eligible[j].AvgRTTMillis {
			return eligible[i].AvgRTTMillis < eligible[j].AvgRTTMillis
		}
		if eligible[i].Private != eligible[j].Private {
			return !eligible[i].Private
		}
		return eligible[i].IP < eligible[j].IP
	})
	return eligible[0].IP
}

func probeAssignedSource(ctx context.Context, source, peer net.IP, count int, timeout time.Duration) ([]time.Duration, error) {
	if source.To4() == nil || !ipAssigned(source) {
		return nil, fmt.Errorf("source %s is not assigned locally", source)
	}
	conn, err := net.ListenIP("ip4:icmp", &net.IPAddr{IP: source})
	if err != nil {
		return nil, fmt.Errorf("open ICMP socket for %s: %w", source, err)
	}
	defer conn.Close()

	var random [10]byte
	if _, err := rand.Read(random[:]); err != nil {
		return nil, fmt.Errorf("generate probe nonce: %w", err)
	}
	identifier := binary.BigEndian.Uint16(random[:2])
	if identifier == 0 {
		identifier = 1
	}
	payload := append([]byte(scanPayloadPrefix), random[2:]...)
	buffer := make([]byte, 2048)
	rtts := make([]time.Duration, 0, count)

	for sequence := 1; sequence <= count; sequence++ {
		if err := ctx.Err(); err != nil {
			return rtts, err
		}
		message := buildICMPMessage(8, identifier, uint16(sequence), payload)
		started := time.Now()
		deadline := started.Add(timeout)
		if err := conn.SetDeadline(deadline); err != nil {
			return rtts, err
		}
		if _, err := conn.WriteToIP(message, &net.IPAddr{IP: peer}); err != nil {
			return rtts, fmt.Errorf("send ICMP from %s: %w", source, err)
		}
		for {
			n, remote, err := conn.ReadFromIP(buffer)
			if err != nil {
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					break
				}
				return rtts, fmt.Errorf("receive ICMP on %s: %w", source, err)
			}
			packet := buffer[:n]
			if len(packet) >= ipv4HeaderLen && packet[0]>>4 == 4 {
				headerLen := int(packet[0]&0x0f) * 4
				if headerLen < ipv4HeaderLen || headerLen > len(packet) {
					continue
				}
				packet = packet[headerLen:]
			}
			if !remote.IP.Equal(peer) || !matchesICMPReply(packet, identifier, uint16(sequence), payload) {
				if time.Now().After(deadline) {
					break
				}
				continue
			}
			rtts = append(rtts, time.Since(started))
			break
		}
		if sequence < count {
			select {
			case <-ctx.Done():
				return rtts, ctx.Err()
			case <-time.After(50 * time.Millisecond):
			}
		}
	}
	return rtts, nil
}

func buildICMPMessage(messageType byte, identifier, sequence uint16, payload []byte) []byte {
	message := make([]byte, icmpHeaderLen+len(payload))
	message[0] = messageType
	binary.BigEndian.PutUint16(message[4:6], identifier)
	binary.BigEndian.PutUint16(message[6:8], sequence)
	copy(message[icmpHeaderLen:], payload)
	binary.BigEndian.PutUint16(message[2:4], checksum(message))
	return message
}

func matchesICMPReply(packet []byte, identifier, sequence uint16, payload []byte) bool {
	if len(packet) != icmpHeaderLen+len(payload) || packet[0] != 0 || packet[1] != 0 {
		return false
	}
	if checksum(packet) != 0 || binary.BigEndian.Uint16(packet[4:6]) != identifier || binary.BigEndian.Uint16(packet[6:8]) != sequence {
		return false
	}
	return string(packet[icmpHeaderLen:]) == string(payload)
}

func summarizeRTT(values []time.Duration) (float64, float64, float64) {
	minimum, maximum, total := values[0], values[0], time.Duration(0)
	for _, value := range values {
		if value < minimum {
			minimum = value
		}
		if value > maximum {
			maximum = value
		}
		total += value
	}
	toMillis := func(value time.Duration) float64 { return float64(value) / float64(time.Millisecond) }
	return toMillis(minimum), toMillis(total) / float64(len(values)), toMillis(maximum)
}
