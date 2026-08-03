package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"time"
)

const CurrentVersion = 1

type Config struct {
	Version  int       `json:"version"`
	Role     string    `json:"role"`
	NodeName string    `json:"node_name"`
	Carrier  Carrier   `json:"carrier"`
	Security Security  `json:"security"`
	Mappings []Mapping `json:"mappings"`
	Health   Health    `json:"health"`
	Logging  Logging   `json:"logging"`
}

type Carrier struct {
	Mode                 string      `json:"mode"`
	Listen               string      `json:"listen,omitempty"`
	Server               string      `json:"server,omitempty"`
	Pool                 int         `json:"pool"`
	KeepaliveSeconds     int         `json:"keepalive_seconds"`
	DialTimeoutSeconds   int         `json:"dial_timeout_seconds"`
	ReconnectMinMillis   int         `json:"reconnect_min_millis"`
	ReconnectMaxMillis   int         `json:"reconnect_max_millis"`
	MaxStreamsPerSession int         `json:"max_streams_per_session"`
	Raw                  RawSettings `json:"raw,omitempty"`
}

type RawSettings struct {
	LocalIP              string `json:"local_ip,omitempty"`
	PeerIP               string `json:"peer_ip,omitempty"`
	Interface            string `json:"interface,omitempty"`
	SpoofSourceIP        string `json:"spoof_source_ip,omitempty"`
	SpoofDestinationIP   string `json:"spoof_destination_ip,omitempty"`
	ExpectedPeerSourceIP string `json:"expected_peer_source_ip,omitempty"`
	AllowUnroutedSpoof   bool   `json:"allow_unrouted_spoof,omitempty"`
	ICMPIdentifier       int    `json:"icmp_identifier,omitempty"`
	PayloadMTU           int    `json:"payload_mtu,omitempty"`
	ExperimentalEnabled  bool   `json:"experimental_enabled,omitempty"`
}

type Security struct {
	PSK    string `json:"psk,omitempty"`
	PSKEnv string `json:"psk_env,omitempty"`
}

type Mapping struct {
	Name     string `json:"name"`
	Protocol string `json:"protocol"`
	Listen   string `json:"listen,omitempty"`
	Target   string `json:"target,omitempty"`
}

type Health struct {
	Listen            string `json:"listen"`
	AllowPublicListen bool   `json:"allow_public_listen"`
}

type Logging struct {
	Level string `json:"level"`
	JSON  bool   `json:"json"`
}

func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	var cfg Config
	dec := json.NewDecoder(strings.NewReader(string(b)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("decode config: %w", err)
	}
	cfg.applyDefaults()
	if cfg.Security.PSKEnv != "" {
		if value, ok := os.LookupEnv(cfg.Security.PSKEnv); ok {
			cfg.Security.PSK = value
		}
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func (c *Config) applyDefaults() {
	if c.Version == 0 {
		c.Version = CurrentVersion
	}
	c.Role = strings.ToLower(strings.TrimSpace(c.Role))
	c.Carrier.Mode = strings.ToLower(strings.TrimSpace(c.Carrier.Mode))
	if c.Carrier.Mode == "" {
		c.Carrier.Mode = "tcp"
	}
	if c.Carrier.Pool == 0 {
		c.Carrier.Pool = 4
	}
	if c.Carrier.KeepaliveSeconds == 0 {
		c.Carrier.KeepaliveSeconds = 10
	}
	if c.Carrier.DialTimeoutSeconds == 0 {
		c.Carrier.DialTimeoutSeconds = 8
	}
	if c.Carrier.ReconnectMinMillis == 0 {
		c.Carrier.ReconnectMinMillis = 500
	}
	if c.Carrier.ReconnectMaxMillis == 0 {
		c.Carrier.ReconnectMaxMillis = 15_000
	}
	if c.Carrier.MaxStreamsPerSession == 0 {
		c.Carrier.MaxStreamsPerSession = 512
	}
	if c.Carrier.Raw.PayloadMTU == 0 {
		c.Carrier.Raw.PayloadMTU = 1200
	}
	if c.Security.PSKEnv == "" {
		c.Security.PSKEnv = "V2QUANTUM_PSK"
	}
	if c.Health.Listen == "" {
		c.Health.Listen = "127.0.0.1:9090"
	}
	if c.Logging.Level == "" {
		c.Logging.Level = "info"
	}
	for i := range c.Mappings {
		c.Mappings[i].Protocol = strings.ToLower(strings.TrimSpace(c.Mappings[i].Protocol))
		if c.Mappings[i].Protocol == "" {
			c.Mappings[i].Protocol = "tcp"
		}
	}
}

func (c *Config) Validate() error {
	var errs []error
	if c.Version != CurrentVersion {
		errs = append(errs, fmt.Errorf("unsupported config version %d", c.Version))
	}
	if c.Role != "server" && c.Role != "client" {
		errs = append(errs, errors.New("role must be server or client"))
	}
	if c.NodeName == "" || len(c.NodeName) > 64 {
		errs = append(errs, errors.New("node_name must contain 1-64 characters"))
	}
	if c.Carrier.Mode != "tcp" && c.Carrier.Mode != "quantum_udp" && c.Carrier.Mode != "raw_icmp" {
		errs = append(errs, errors.New("carrier.mode must be tcp, quantum_udp, or raw_icmp"))
	}
	if c.Role == "server" && c.Carrier.Mode != "raw_icmp" {
		errs = append(errs, validateEndpoint("carrier.listen", c.Carrier.Listen))
	}
	if c.Role == "client" && c.Carrier.Mode != "raw_icmp" {
		errs = append(errs, validateEndpoint("carrier.server", c.Carrier.Server))
	}
	if c.Carrier.Pool < 1 || c.Carrier.Pool > 32 {
		errs = append(errs, errors.New("carrier.pool must be between 1 and 32"))
	}
	if c.Carrier.KeepaliveSeconds < 2 || c.Carrier.KeepaliveSeconds > 300 {
		errs = append(errs, errors.New("keepalive_seconds must be between 2 and 300"))
	}
	if c.Carrier.DialTimeoutSeconds < 1 || c.Carrier.DialTimeoutSeconds > 120 {
		errs = append(errs, errors.New("dial_timeout_seconds must be between 1 and 120"))
	}
	if c.Carrier.ReconnectMinMillis < 100 || c.Carrier.ReconnectMinMillis > 30_000 {
		errs = append(errs, errors.New("reconnect_min_millis must be between 100 and 30000"))
	}
	if c.Carrier.ReconnectMaxMillis < c.Carrier.ReconnectMinMillis || c.Carrier.ReconnectMaxMillis > 300_000 {
		errs = append(errs, errors.New("reconnect_max_millis must be >= reconnect_min_millis and <= 300000"))
	}
	if c.Carrier.MaxStreamsPerSession < 1 || c.Carrier.MaxStreamsPerSession > 65_535 {
		errs = append(errs, errors.New("max_streams_per_session must be between 1 and 65535"))
	}
	if len(c.Security.PSK) < 32 || len(c.Security.PSK) > 512 {
		errs = append(errs, fmt.Errorf("security PSK must be 32-512 characters (or set %s)", c.Security.PSKEnv))
	}
	if len(c.Mappings) == 0 {
		errs = append(errs, errors.New("at least one mapping is required"))
	}
	seen := make(map[string]struct{}, len(c.Mappings))
	for i, m := range c.Mappings {
		prefix := fmt.Sprintf("mappings[%d]", i)
		if m.Name == "" || len(m.Name) > 64 {
			errs = append(errs, fmt.Errorf("%s.name must contain 1-64 characters", prefix))
		} else if _, ok := seen[m.Name]; ok {
			errs = append(errs, fmt.Errorf("duplicate mapping name %q", m.Name))
		} else {
			seen[m.Name] = struct{}{}
		}
		if m.Protocol != "tcp" {
			errs = append(errs, fmt.Errorf("%s.protocol currently supports only tcp", prefix))
		}
		if c.Role == "server" {
			errs = append(errs, validateEndpoint(prefix+".listen", m.Listen))
		}
		if c.Role == "client" {
			errs = append(errs, validateEndpoint(prefix+".target", m.Target))
		}
	}
	if err := validateHealth(c.Health); err != nil {
		errs = append(errs, err)
	}
	if c.Carrier.Mode == "raw_icmp" {
		if err := validateRaw(c.Carrier.Raw); err != nil {
			errs = append(errs, err)
		}
	}
	switch strings.ToLower(c.Logging.Level) {
	case "debug", "info", "warn", "error":
	default:
		errs = append(errs, errors.New("logging.level must be debug, info, warn, or error"))
	}
	return errors.Join(nonNil(errs)...)
}

func validateEndpoint(name, value string) error {
	if value == "" {
		return fmt.Errorf("%s is required", name)
	}
	host, port, err := net.SplitHostPort(value)
	if err != nil || port == "" {
		return fmt.Errorf("%s must be IP-or-host:port", name)
	}
	if host == "" && !strings.HasPrefix(value, ":") {
		return fmt.Errorf("%s has an invalid host", name)
	}
	return nil
}

func validateHealth(h Health) error {
	host, _, err := net.SplitHostPort(h.Listen)
	if err != nil {
		return fmt.Errorf("health.listen: %w", err)
	}
	if h.AllowPublicListen {
		return nil
	}
	ip := net.ParseIP(host)
	if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return errors.New("health.listen must be loopback unless allow_public_listen is true")
	}
	return nil
}

func validateRaw(r RawSettings) error {
	if !r.ExperimentalEnabled {
		return errors.New("raw_icmp requires raw.experimental_enabled=true")
	}
	local := net.ParseIP(r.LocalIP)
	peer := net.ParseIP(r.PeerIP)
	if local == nil || local.To4() == nil || peer == nil || peer.To4() == nil {
		return errors.New("raw local_ip and peer_ip must be IPv4 addresses")
	}
	src := local
	if r.SpoofSourceIP != "" {
		src = net.ParseIP(r.SpoofSourceIP)
		if src == nil || src.To4() == nil {
			return errors.New("raw spoof_source_ip must be IPv4")
		}
	}
	if r.SpoofDestinationIP != "" {
		dst := net.ParseIP(r.SpoofDestinationIP)
		if dst == nil || dst.To4() == nil {
			return errors.New("raw spoof_destination_ip must be IPv4")
		}
	}
	if r.ExpectedPeerSourceIP != "" {
		peerSource := net.ParseIP(r.ExpectedPeerSourceIP)
		if peerSource == nil || peerSource.To4() == nil {
			return errors.New("raw expected_peer_source_ip must be IPv4")
		}
	}
	if !r.AllowUnroutedSpoof && !src.Equal(local) {
		return errors.New("spoof_source_ip differs from local_ip; set allow_unrouted_spoof only for addresses routed to this host and authorized by the provider")
	}
	if r.ICMPIdentifier < 0 || r.ICMPIdentifier > 65_535 {
		return errors.New("raw icmp_identifier must be 0-65535")
	}
	if r.PayloadMTU < 576 || r.PayloadMTU > 1400 {
		return errors.New("raw payload_mtu must be 576-1400")
	}
	return nil
}

func nonNil(in []error) []error {
	out := in[:0]
	for _, err := range in {
		if err != nil {
			out = append(out, err)
		}
	}
	return out
}

func (c *Config) DialTimeout() time.Duration {
	return time.Duration(c.Carrier.DialTimeoutSeconds) * time.Second
}

func (c *Config) Keepalive() time.Duration {
	return time.Duration(c.Carrier.KeepaliveSeconds) * time.Second
}

func (c *Config) ReconnectMin() time.Duration {
	return time.Duration(c.Carrier.ReconnectMinMillis) * time.Millisecond
}

func (c *Config) ReconnectMax() time.Duration {
	return time.Duration(c.Carrier.ReconnectMaxMillis) * time.Millisecond
}
