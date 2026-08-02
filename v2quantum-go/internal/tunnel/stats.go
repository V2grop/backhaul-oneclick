package tunnel

import "sync/atomic"

type Stats struct {
	sessions    atomic.Int64
	streams     atomic.Int64
	bytesToExit atomic.Int64
	bytesToUser atomic.Int64
	reconnects  atomic.Int64
	authFailed  atomic.Int64
	openFailed  atomic.Int64
}

type Snapshot struct {
	Sessions    int64 `json:"sessions"`
	Streams     int64 `json:"streams"`
	BytesToExit int64 `json:"bytes_to_exit"`
	BytesToUser int64 `json:"bytes_to_user"`
	Reconnects  int64 `json:"reconnects"`
	AuthFailed  int64 `json:"auth_failed"`
	OpenFailed  int64 `json:"open_failed"`
}

func (s *Stats) Snapshot() Snapshot {
	return Snapshot{
		Sessions:    s.sessions.Load(),
		Streams:     s.streams.Load(),
		BytesToExit: s.bytesToExit.Load(),
		BytesToUser: s.bytesToUser.Load(),
		Reconnects:  s.reconnects.Load(),
		AuthFailed:  s.authFailed.Load(),
		OpenFailed:  s.openFailed.Load(),
	}
}
