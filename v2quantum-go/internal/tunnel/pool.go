package tunnel

import (
	"context"
	"errors"
	"sync"
)

var errNoSession = errors.New("no healthy carrier session is available")

type sessionPool struct {
	mu       sync.RWMutex
	sessions map[*session]struct{}
	notify   chan struct{}
}

func newSessionPool() *sessionPool {
	return &sessionPool{sessions: make(map[*session]struct{}), notify: make(chan struct{}, 1)}
}

func (p *sessionPool) add(s *session) {
	p.mu.Lock()
	p.sessions[s] = struct{}{}
	p.mu.Unlock()
	p.signal()
}

func (p *sessionPool) remove(s *session) {
	p.mu.Lock()
	delete(p.sessions, s)
	p.mu.Unlock()
	p.signal()
}

func (p *sessionPool) signal() {
	select {
	case p.notify <- struct{}{}:
	default:
	}
}

func (p *sessionPool) count() int {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return len(p.sessions)
}

func (p *sessionPool) pick() (*session, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	var best *session
	var bestActive int64
	for s := range p.sessions {
		if s.isClosed() || s.active.Load() >= int64(s.maxStreams) {
			continue
		}
		active := s.active.Load()
		if best == nil || active < bestActive {
			best, bestActive = s, active
		}
	}
	if best == nil {
		return nil, errNoSession
	}
	return best, nil
}

func (p *sessionPool) waitPick(ctx context.Context) (*session, error) {
	for {
		if s, err := p.pick(); err == nil {
			return s, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-p.notify:
		}
	}
}

func (p *sessionPool) closeAll() {
	p.mu.RLock()
	items := make([]*session, 0, len(p.sessions))
	for s := range p.sessions {
		items = append(items, s)
	}
	p.mu.RUnlock()
	for _, s := range items {
		s.close(nil)
	}
}
