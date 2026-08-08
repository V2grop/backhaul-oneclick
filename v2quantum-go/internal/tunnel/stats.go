package tunnel

import (
	"sync"
	"sync/atomic"
	"time"
)

type Stats struct {
	sessions            atomic.Int64
	streams             atomic.Int64
	bytesToExit         atomic.Int64
	bytesToUser         atomic.Int64
	reconnects          atomic.Int64
	authFailed          atomic.Int64
	openFailed          atomic.Int64
	tunPacketsToPeer    atomic.Int64
	tunPacketsFromPeer  atomic.Int64
	tunBytesToPeer      atomic.Int64
	tunBytesFromPeer    atomic.Int64
	quantumRetransmits  atomic.Int64
	quantumFastResends  atomic.Int64
	quantumFECSent      atomic.Int64
	quantumFECRecovered atomic.Int64
	quantumSRTTMillis   atomic.Int64
	quantumRTOMillis    atomic.Int64
	quantumWindow       atomic.Int64
	fusionLinks         atomic.Int64
	fusionFailovers     atomic.Int64
	fusionReplayedBytes atomic.Int64
	fusionMu            sync.RWMutex
	fusionPrimary       string
}

type Snapshot struct {
	Sessions            int64  `json:"sessions"`
	Streams             int64  `json:"streams"`
	BytesToExit         int64  `json:"bytes_to_exit"`
	BytesToUser         int64  `json:"bytes_to_user"`
	Reconnects          int64  `json:"reconnects"`
	AuthFailed          int64  `json:"auth_failed"`
	OpenFailed          int64  `json:"open_failed"`
	TUNPacketsToPeer    int64  `json:"tun_packets_to_peer"`
	TUNPacketsFromPeer  int64  `json:"tun_packets_from_peer"`
	TUNBytesToPeer      int64  `json:"tun_bytes_to_peer"`
	TUNBytesFromPeer    int64  `json:"tun_bytes_from_peer"`
	QuantumRetransmits  int64  `json:"quantum_retransmits"`
	QuantumFastResends  int64  `json:"quantum_fast_resends"`
	QuantumFECSent      int64  `json:"quantum_fec_sent"`
	QuantumFECRecovered int64  `json:"quantum_fec_recovered"`
	QuantumSRTTMillis   int64  `json:"quantum_srtt_millis"`
	QuantumRTOMillis    int64  `json:"quantum_rto_millis"`
	QuantumWindow       int64  `json:"quantum_congestion_window"`
	FusionLinks         int64  `json:"fusion_links"`
	FusionFailovers     int64  `json:"fusion_failovers"`
	FusionReplayedBytes int64  `json:"fusion_replayed_bytes"`
	FusionPrimary       string `json:"fusion_primary,omitempty"`
}

func (s *Stats) Snapshot() Snapshot {
	s.fusionMu.RLock()
	primary := s.fusionPrimary
	s.fusionMu.RUnlock()
	return Snapshot{
		Sessions:            s.sessions.Load(),
		Streams:             s.streams.Load(),
		BytesToExit:         s.bytesToExit.Load(),
		BytesToUser:         s.bytesToUser.Load(),
		Reconnects:          s.reconnects.Load(),
		AuthFailed:          s.authFailed.Load(),
		OpenFailed:          s.openFailed.Load(),
		TUNPacketsToPeer:    s.tunPacketsToPeer.Load(),
		TUNPacketsFromPeer:  s.tunPacketsFromPeer.Load(),
		TUNBytesToPeer:      s.tunBytesToPeer.Load(),
		TUNBytesFromPeer:    s.tunBytesFromPeer.Load(),
		QuantumRetransmits:  s.quantumRetransmits.Load(),
		QuantumFastResends:  s.quantumFastResends.Load(),
		QuantumFECSent:      s.quantumFECSent.Load(),
		QuantumFECRecovered: s.quantumFECRecovered.Load(),
		QuantumSRTTMillis:   s.quantumSRTTMillis.Load(),
		QuantumRTOMillis:    s.quantumRTOMillis.Load(),
		QuantumWindow:       s.quantumWindow.Load(),
		FusionLinks:         s.fusionLinks.Load(),
		FusionFailovers:     s.fusionFailovers.Load(),
		FusionReplayedBytes: s.fusionReplayedBytes.Load(),
		FusionPrimary:       primary,
	}
}

func (s *Stats) setFusionPrimary(name string) {
	s.fusionMu.Lock()
	s.fusionPrimary = name
	s.fusionMu.Unlock()
}

type quantumObserver struct {
	stats *Stats
}

func (o quantumObserver) ObserveRTT(srtt, rto time.Duration) {
	o.stats.quantumSRTTMillis.Store(srtt.Milliseconds())
	o.stats.quantumRTOMillis.Store(rto.Milliseconds())
}

func (o quantumObserver) ObserveWindow(cwnd int) {
	o.stats.quantumWindow.Store(int64(cwnd))
}

func (o quantumObserver) CountRetransmit(fast bool) {
	o.stats.quantumRetransmits.Add(1)
	if fast {
		o.stats.quantumFastResends.Add(1)
	}
}

func (o quantumObserver) CountFECSent() {
	o.stats.quantumFECSent.Add(1)
}

func (o quantumObserver) CountFECRecovered() {
	o.stats.quantumFECRecovered.Add(1)
}
