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

func TestValidateTUN(t *testing.T) {
	c := validServer()
	c.Carrier.Pool = 1
	c.Mappings = nil
	c.TUN = &TUN{
		Enabled:      true,
		Name:         "v2q123456",
		LocalAddress: "10.77.0.1/30",
		PeerAddress:  "10.77.0.2",
		MTU:          1280,
		Routes:       []string{"10.88.0.0/16"},
	}
	if err := c.Validate(); err != nil {
		t.Fatalf("valid TUN config rejected: %v", err)
	}
}

func TestQuantumProfileDefaultsAndValidation(t *testing.T) {
	c := validServer()
	c.Carrier.Mode = "quantum_udp"
	c.Carrier.Quantum.Profile = "max"
	c.applyDefaults()
	q := c.Carrier.Quantum
	if q.AutoTune == nil || !*q.AutoTune {
		t.Fatal("max profile did not enable auto tuning")
	}
	if q.SendWindow != 1024 || q.ReceiveWindow != 2048 || q.FECDataShards != 10 || q.FECParityShards != 1 || q.MaxDatagramSize != 1400 {
		t.Fatalf("unexpected max profile defaults: %#v", q)
	}
	if err := c.Validate(); err != nil {
		t.Fatalf("valid quantum profile rejected: %v", err)
	}
}

func TestQuantumManualProfilePreservesDisabledAutoTuneAndFEC(t *testing.T) {
	c := validServer()
	c.Carrier.Mode = "quantum_udp"
	disabled := false
	c.Carrier.Quantum = Quantum{Profile: "manual", AutoTune: &disabled}
	c.applyDefaults()
	if c.QuantumAutoTune() {
		t.Fatal("manual auto_tune=false was not preserved")
	}
	if c.Carrier.Quantum.FECDataShards != 0 {
		t.Fatalf("manual FEC disable was not preserved: %d", c.Carrier.Quantum.FECDataShards)
	}
	if c.Carrier.Quantum.FECParityShards != 0 {
		t.Fatalf("manual FEC parity disable was not preserved: %d", c.Carrier.Quantum.FECParityShards)
	}
	if err := c.Validate(); err != nil {
		t.Fatalf("valid manual quantum profile rejected: %v", err)
	}
}

func TestRejectUnsafeQuantumParameters(t *testing.T) {
	c := validServer()
	c.Carrier.Mode = "quantum_udp"
	c.Carrier.Quantum.Profile = "balanced"
	c.applyDefaults()
	c.Carrier.Quantum.MaxDatagramSize = 9000
	c.Carrier.Quantum.FECDataShards = 1
	c.Carrier.Quantum.FECParityShards = 9
	err := c.Validate()
	if err == nil || !strings.Contains(err.Error(), "max_datagram_size") || !strings.Contains(err.Error(), "fec_data_shards") || !strings.Contains(err.Error(), "fec_parity_shards") {
		t.Fatalf("expected bounded quantum parameter errors, got %v", err)
	}
}

func TestRejectUnsafeTUNCombinations(t *testing.T) {
	tests := []struct {
		name   string
		change func(*Config)
		want   string
	}{
		{"pool", func(c *Config) { c.Carrier.Pool = 2 }, "carrier.pool=1"},
		{"raw", func(c *Config) { c.Carrier.Mode = "raw_icmp" }, "raw_icmp remains a separate"},
		{"mapping", func(c *Config) { c.Mappings = []Mapping{{Name: "x", Protocol: "tcp", Listen: "127.0.0.1:1"}} }, "separate instances"},
		{"device", func(c *Config) { c.TUN.Name = "name-is-far-too-long" }, "1-15"},
		{"peer", func(c *Config) { c.TUN.PeerAddress = "10.99.0.2" }, "inside"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := validServer()
			c.Carrier.Pool = 1
			c.Mappings = nil
			c.TUN = &TUN{Enabled: true, Name: "v2q123", LocalAddress: "10.77.0.1/30", PeerAddress: "10.77.0.2", MTU: 1280}
			tt.change(&c)
			if err := c.Validate(); err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("expected %q error, got %v", tt.want, err)
			}
		})
	}
}
