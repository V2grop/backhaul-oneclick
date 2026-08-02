package tunnel

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/protocol"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/secure"
)

type session struct {
	conn       *secure.Conn
	logger     *slog.Logger
	stats      *Stats
	targets    map[string]string
	allowOpen  bool
	maxStreams int
	keepalive  time.Duration
	dial       time.Duration

	streamsMu sync.RWMutex
	streams   map[uint32]*stream
	nextID    atomic.Uint32
	active    atomic.Int64
	lastPong  atomic.Int64
	closed    chan struct{}
	closeOnce sync.Once
}

type stream struct {
	id      uint32
	session *session
	conn    net.Conn
	ready   chan error
	recv    chan []byte
	done    chan struct{}
	once    sync.Once
}

func newSession(conn *secure.Conn, logger *slog.Logger, stats *Stats, targets map[string]string, allowOpen bool, maxStreams int, keepalive, dial time.Duration) *session {
	s := &session{
		conn:       conn,
		logger:     logger,
		stats:      stats,
		targets:    targets,
		allowOpen:  allowOpen,
		maxStreams: maxStreams,
		keepalive:  keepalive,
		dial:       dial,
		streams:    make(map[uint32]*stream),
		closed:     make(chan struct{}),
	}
	s.nextID.Store(1)
	s.lastPong.Store(time.Now().UnixNano())
	stats.sessions.Add(1)
	go s.readLoop()
	go s.keepaliveLoop()
	return s
}

func (s *session) wait() { <-s.closed }

func (s *session) isClosed() bool {
	select {
	case <-s.closed:
		return true
	default:
		return false
	}
}

func (s *session) open(ctx context.Context, mapping string, conn net.Conn) error {
	if s.isClosed() {
		return net.ErrClosed
	}
	if s.active.Load() >= int64(s.maxStreams) {
		return errors.New("carrier session reached its stream limit")
	}
	id := s.nextID.Add(2)
	st := &stream{
		id:      id,
		session: s,
		conn:    conn,
		ready:   make(chan error, 1),
		recv:    make(chan []byte, 64),
		done:    make(chan struct{}),
	}
	if !s.addStream(st) {
		return net.ErrClosed
	}
	if err := s.conn.WriteFrame(protocol.Frame{Type: protocol.Open, StreamID: id, Payload: []byte(mapping)}); err != nil {
		st.terminate(false)
		return err
	}
	wait := time.NewTimer(s.dial + 2*time.Second)
	defer wait.Stop()
	select {
	case err := <-st.ready:
		if err != nil {
			st.terminate(false)
			return err
		}
		st.start()
		return nil
	case <-ctx.Done():
		st.terminate(true)
		return ctx.Err()
	case <-wait.C:
		st.terminate(true)
		return errors.New("remote target open timed out")
	case <-s.closed:
		st.terminate(false)
		return net.ErrClosed
	}
}

func (s *session) addStream(st *stream) bool {
	s.streamsMu.Lock()
	defer s.streamsMu.Unlock()
	if s.isClosed() {
		return false
	}
	if _, exists := s.streams[st.id]; exists {
		return false
	}
	s.streams[st.id] = st
	s.active.Add(1)
	s.stats.streams.Add(1)
	return true
}

func (s *session) getStream(id uint32) *stream {
	s.streamsMu.RLock()
	defer s.streamsMu.RUnlock()
	return s.streams[id]
}

func (s *session) removeStream(id uint32) {
	s.streamsMu.Lock()
	if _, ok := s.streams[id]; ok {
		delete(s.streams, id)
		s.active.Add(-1)
		s.stats.streams.Add(-1)
	}
	s.streamsMu.Unlock()
}

func (s *session) readLoop() {
	for {
		frame, err := s.conn.ReadFrame()
		if err != nil {
			s.close(err)
			return
		}
		switch frame.Type {
		case protocol.Open:
			if !s.allowOpen {
				_ = s.conn.WriteFrame(protocol.Frame{Type: protocol.OpenError, StreamID: frame.StreamID, Payload: []byte("peer is not allowed to open streams")})
				continue
			}
			go s.handleOpen(frame)
		case protocol.OpenOK:
			if st := s.getStream(frame.StreamID); st != nil {
				select {
				case st.ready <- nil:
				default:
				}
			}
		case protocol.OpenError:
			if st := s.getStream(frame.StreamID); st != nil {
				select {
				case st.ready <- fmt.Errorf("remote open failed: %s", frame.Payload):
				default:
				}
			}
		case protocol.Data:
			st := s.getStream(frame.StreamID)
			if st == nil {
				_ = s.conn.WriteFrame(protocol.Frame{Type: protocol.Close, StreamID: frame.StreamID})
				continue
			}
			if err := st.deliver(frame.Payload); err != nil {
				s.close(err)
				return
			}
		case protocol.Close:
			if st := s.getStream(frame.StreamID); st != nil {
				st.terminate(false)
			}
		case protocol.Ping:
			if err := s.conn.WriteFrame(protocol.Frame{Type: protocol.Pong, Payload: frame.Payload}); err != nil {
				s.close(err)
				return
			}
		case protocol.Pong:
			s.lastPong.Store(time.Now().UnixNano())
		}
	}
}

func (s *session) handleOpen(frame protocol.Frame) {
	name := string(frame.Payload)
	target, ok := s.targets[name]
	if !ok {
		s.stats.openFailed.Add(1)
		_ = s.conn.WriteFrame(protocol.Frame{Type: protocol.OpenError, StreamID: frame.StreamID, Payload: []byte("unknown mapping")})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), s.dial)
	defer cancel()
	dialer := net.Dialer{}
	conn, err := dialer.DialContext(ctx, "tcp", target)
	if err != nil {
		s.stats.openFailed.Add(1)
		_ = s.conn.WriteFrame(protocol.Frame{Type: protocol.OpenError, StreamID: frame.StreamID, Payload: []byte("target unavailable")})
		return
	}
	st := &stream{
		id:      frame.StreamID,
		session: s,
		conn:    conn,
		ready:   make(chan error, 1),
		recv:    make(chan []byte, 64),
		done:    make(chan struct{}),
	}
	if !s.addStream(st) {
		_ = conn.Close()
		_ = s.conn.WriteFrame(protocol.Frame{Type: protocol.OpenError, StreamID: frame.StreamID, Payload: []byte("stream limit reached")})
		return
	}
	if err := s.conn.WriteFrame(protocol.Frame{Type: protocol.OpenOK, StreamID: frame.StreamID}); err != nil {
		st.terminate(false)
		return
	}
	st.start()
}

func (s *session) keepaliveLoop() {
	ticker := time.NewTicker(s.keepalive)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if time.Since(time.Unix(0, s.lastPong.Load())) > 3*s.keepalive {
				s.close(errors.New("keepalive timeout"))
				return
			}
			stamp := []byte(time.Now().UTC().Format(time.RFC3339Nano))
			if err := s.conn.WriteFrame(protocol.Frame{Type: protocol.Ping, Payload: stamp}); err != nil {
				s.close(err)
				return
			}
		case <-s.closed:
			return
		}
	}
}

func (s *session) close(cause error) {
	s.closeOnce.Do(func() {
		close(s.closed)
		_ = s.conn.Close()
		s.stats.sessions.Add(-1)
		s.streamsMu.RLock()
		items := make([]*stream, 0, len(s.streams))
		for _, st := range s.streams {
			items = append(items, st)
		}
		s.streamsMu.RUnlock()
		for _, st := range items {
			st.terminate(false)
		}
		if cause != nil && !errors.Is(cause, io.EOF) && !errors.Is(cause, net.ErrClosed) {
			s.logger.Debug("carrier session closed", "error", cause)
		}
	})
}

func (st *stream) start() {
	go st.writeLocal()
	go st.readLocal()
}

func (st *stream) deliver(payload []byte) error {
	data := append([]byte(nil), payload...)
	select {
	case st.recv <- data:
		st.session.stats.bytesToUser.Add(int64(len(data)))
		return nil
	case <-st.done:
		return nil
	default:
		return errors.New("stream receive queue overflow")
	}
}

func (st *stream) writeLocal() {
	for {
		select {
		case data := <-st.recv:
			if err := writeFull(st.conn, data); err != nil {
				st.terminate(true)
				return
			}
		case <-st.done:
			return
		}
	}
}

func (st *stream) readLocal() {
	buf := make([]byte, protocol.DataChunk)
	for {
		n, err := st.conn.Read(buf)
		if n > 0 {
			payload := append([]byte(nil), buf[:n]...)
			if writeErr := st.session.conn.WriteFrame(protocol.Frame{Type: protocol.Data, StreamID: st.id, Payload: payload}); writeErr != nil {
				st.session.close(writeErr)
				return
			}
			st.session.stats.bytesToExit.Add(int64(n))
		}
		if err != nil {
			st.terminate(true)
			return
		}
	}
}

func (st *stream) terminate(sendClose bool) {
	st.once.Do(func() {
		close(st.done)
		_ = st.conn.Close()
		st.session.removeStream(st.id)
		if sendClose && !st.session.isClosed() {
			_ = st.session.conn.WriteFrame(protocol.Frame{Type: protocol.Close, StreamID: st.id})
		}
	})
}

func writeFull(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrUnexpectedEOF
		}
		b = b[n:]
	}
	return nil
}
