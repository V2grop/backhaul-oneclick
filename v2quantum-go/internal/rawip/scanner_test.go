package rawip

import (
	"encoding/binary"
	"testing"
	"time"
)

func TestSelectBestSource(t *testing.T) {
	results := []SourceScanResult{
		{SourceCandidate: SourceCandidate{IP: "10.0.0.2", Private: true}, Sent: 3, Received: 3, LossPercent: 0, AvgRTTMillis: 4},
		{SourceCandidate: SourceCandidate{IP: "198.51.100.2"}, Sent: 3, Received: 2, LossPercent: 33.333, AvgRTTMillis: 1},
		{SourceCandidate: SourceCandidate{IP: "198.51.100.3"}, Sent: 3, Received: 3, LossPercent: 0, AvgRTTMillis: 8},
	}
	if got := SelectBestSource(results, 3); got != "10.0.0.2" {
		t.Fatalf("selected %q; want lowest-loss/RTT source", got)
	}
}

func TestSelectBestSourceRequiresTwoThirds(t *testing.T) {
	results := []SourceScanResult{{
		SourceCandidate: SourceCandidate{IP: "198.51.100.2"},
		Sent:            3,
		Received:        1,
		LossPercent:     66.667,
		AvgRTTMillis:    1,
	}}
	if got := SelectBestSource(results, 3); got != "" {
		t.Fatalf("selected weak candidate %q", got)
	}
}

func TestICMPScanMessageValidation(t *testing.T) {
	payload := []byte(scanPayloadPrefix + "nonce")
	request := buildICMPMessage(8, 42, 7, payload)
	if checksum(request) != 0 {
		t.Fatal("request checksum is invalid")
	}
	reply := buildICMPMessage(0, 42, 7, payload)
	if !matchesICMPReply(reply, 42, 7, payload) {
		t.Fatal("valid reply was rejected")
	}
	reply[icmpHeaderLen] ^= 0xff
	binary.BigEndian.PutUint16(reply[2:4], 0)
	binary.BigEndian.PutUint16(reply[2:4], checksum(reply))
	if matchesICMPReply(reply, 42, 7, payload) {
		t.Fatal("reply with the wrong nonce was accepted")
	}
}

func TestSummarizeRTT(t *testing.T) {
	minimum, average, maximum := summarizeRTT([]time.Duration{time.Millisecond, 3 * time.Millisecond, 2 * time.Millisecond})
	if minimum != 1 || average != 2 || maximum != 3 {
		t.Fatalf("unexpected RTT summary: min=%v avg=%v max=%v", minimum, average, maximum)
	}
}
