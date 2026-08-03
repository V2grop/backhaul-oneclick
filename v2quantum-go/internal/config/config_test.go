package config

import (
	"strings"
	"testing"
)

func validServer() Config {
	c := Config{
		Version:  CurrentVersion,
		Role:     "server",
		NodeName: "iran-edge",
		Carrier: Carrier{
			Mode:                 "tcp",
			Listen:               "127.0.0.1:8443",
			Pool:                 4,
			KeepaliveSeconds:     10,
			DialTimeoutSeconds:   8,
			ReconnectMinMillis:   500,
			ReconnectMaxMillis:   15_000,
			MaxStreamsPerSession: 512,
		},
		Security: Security{PSK: strings.Repeat("a", 48)},
		Mappings: []Mapping{{Name: "xray", Protocol: "tcp", Listen: "127.0.0.1:2444"}},
		Health:   Health{Listen: "127.0.0.1:9090"},
		Logging:  Logging{Level: "info"},
	}
	return c
}

func TestValidateServer(t *testing.T) {
	c := validServer()
	if err := c.Validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
}

func TestRejectPublicHealth(t *testing.T) {
	c := validServer()
	c.Health.Listen = "0.0.0.0:9090"
	if err := c.Validate(); err == nil {
		t.Fatal("public health listener accepted without opt-in")
	}
}

func TestRejectUnroutedSpoofByDefault(t *testing.T) {
	c := validServer()
	c.Carrier.Mode = "raw_icmp"
	c.Carrier.Listen = ""
	c.Carrier.Raw = RawSettings{
		LocalIP:             "192.0.2.10",
		PeerIP:              "192.0.2.20",
		SpoofSourceIP:       "198.51.100.10",
		PayloadMTU:          1200,
		ExperimentalEnabled: true,
	}
	if err := c.Validate(); err == nil || !strings.Contains(err.Error(), "allow_unrouted_spoof") {
		t.Fatalf("expected spoof guard error, got %v", err)
	}
}

func TestValidateExpectedPeerSource(t *testing.T) {
	c := validServer()
	c.Carrier.Mode = "raw_icmp"
	c.Carrier.Listen = ""
	c.Carrier.Raw = RawSettings{
		LocalIP:              "192.0.2.10",
		PeerIP:               "192.0.2.20",
		ExpectedPeerSourceIP: "198.51.100.20",
		PayloadMTU:           1200,
		ExperimentalEnabled:  true,
	}
	if err := c.Validate(); err != nil {
		t.Fatalf("valid expected peer source rejected: %v", err)
	}
	c.Carrier.Raw.ExpectedPeerSourceIP = "not-an-ip"
	if err := c.Validate(); err == nil || !strings.Contains(err.Error(), "expected_peer_source_ip") {
		t.Fatalf("invalid expected peer source accepted: %v", err)
	}
}
