package quantumv2

import "time"

const (
	minDatagramSize  = 576
	hardMaxDatagram  = 1472
	maxFECDataShards = 32
	maxFECParity     = 8
)

// Observer receives aggregate-friendly transport measurements. Implementations
// must be safe for concurrent use and should return quickly.
type Observer interface {
	ObserveRTT(srtt, rto time.Duration)
	ObserveWindow(cwnd int)
	CountRetransmit(fast bool)
	CountFECSent()
	CountFECRecovered()
}

// Settings controls the independent Quantum v2 UDP carrier. AutoTune keeps the
// configured send window as a ceiling while adapting the live congestion
// window and retransmission timer to the measured path.
type Settings struct {
	Profile           string
	AutoTune          bool
	MaxDatagramSize   int
	SendWindow        int
	ReceiveWindow     int
	InitialRTO        time.Duration
	MinRTO            time.Duration
	MaxRTO            time.Duration
	FastResend        int
	FECDataShards     int
	FECParityShards   int
	SocketBufferBytes int
	MaxRetries        int
	Observer          Observer
}

func DefaultSettings(profile string) Settings {
	switch profile {
	case "stable":
		return Settings{
			Profile:           "stable",
			AutoTune:          true,
			MaxDatagramSize:   1280,
			SendWindow:        256,
			ReceiveWindow:     512,
			InitialRTO:        320 * time.Millisecond,
			MinRTO:            100 * time.Millisecond,
			MaxRTO:            3 * time.Second,
			FastResend:        2,
			FECDataShards:     6,
			FECParityShards:   2,
			SocketBufferBytes: 8 << 20,
			MaxRetries:        16,
		}
	case "max":
		return Settings{
			Profile:           "max",
			AutoTune:          true,
			MaxDatagramSize:   1400,
			SendWindow:        1024,
			ReceiveWindow:     2048,
			InitialRTO:        220 * time.Millisecond,
			MinRTO:            60 * time.Millisecond,
			MaxRTO:            2 * time.Second,
			FastResend:        3,
			FECDataShards:     10,
			FECParityShards:   1,
			SocketBufferBytes: 16 << 20,
			MaxRetries:        16,
		}
	case "manual":
		return Settings{
			Profile:           "manual",
			AutoTune:          false,
			MaxDatagramSize:   1350,
			SendWindow:        512,
			ReceiveWindow:     1024,
			InitialRTO:        260 * time.Millisecond,
			MinRTO:            80 * time.Millisecond,
			MaxRTO:            2500 * time.Millisecond,
			FastResend:        3,
			FECDataShards:     0,
			FECParityShards:   0,
			SocketBufferBytes: 12 << 20,
			MaxRetries:        16,
		}
	default:
		return Settings{
			Profile:           "balanced",
			AutoTune:          true,
			MaxDatagramSize:   1350,
			SendWindow:        512,
			ReceiveWindow:     1024,
			InitialRTO:        260 * time.Millisecond,
			MinRTO:            80 * time.Millisecond,
			MaxRTO:            2500 * time.Millisecond,
			FastResend:        3,
			FECDataShards:     8,
			FECParityShards:   2,
			SocketBufferBytes: 12 << 20,
			MaxRetries:        16,
		}
	}
}

func (s Settings) normalized() Settings {
	defaults := DefaultSettings(s.Profile)
	if s.Profile == "" {
		s.Profile = defaults.Profile
	}
	if s.MaxDatagramSize == 0 {
		s.MaxDatagramSize = defaults.MaxDatagramSize
	}
	if s.SendWindow == 0 {
		s.SendWindow = defaults.SendWindow
	}
	if s.ReceiveWindow == 0 {
		s.ReceiveWindow = defaults.ReceiveWindow
	}
	if s.InitialRTO == 0 {
		s.InitialRTO = defaults.InitialRTO
	}
	if s.MinRTO == 0 {
		s.MinRTO = defaults.MinRTO
	}
	if s.MaxRTO == 0 {
		s.MaxRTO = defaults.MaxRTO
	}
	if s.FastResend == 0 {
		s.FastResend = defaults.FastResend
	}
	if s.FECDataShards == 0 && s.Profile != "manual" {
		s.FECDataShards = defaults.FECDataShards
	}
	if s.FECParityShards == 0 && s.Profile != "manual" {
		s.FECParityShards = defaults.FECParityShards
	}
	if s.SocketBufferBytes == 0 {
		s.SocketBufferBytes = defaults.SocketBufferBytes
	}
	if s.MaxRetries == 0 {
		s.MaxRetries = defaults.MaxRetries
	}
	return s
}
