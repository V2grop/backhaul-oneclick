package tunnel

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/protocol"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/secure"
)

var errFusionUnavailable = errors.New("no FusionMux path is available")

type fusionHub struct {
	ctx                context.Context
	logger             *slog.Logger
	stats              *Stats
	role               string
	targets            map[string]string
	keepalive          time.Duration
	dialTimeout        time.Duration
	unavailableTimeout time.Duration
	recoveryHold       time.Duration
	replayLimit        int

	mu      sync.RWMutex
	links   map[*fusionLink]struct{}
	primary *fusionLink
	flows   map[uint32]*fusionFlow
	openMu  sync.Mutex
	change  chan struct{}
	closed  bool
	nextID  atomic.Uint32
}

type fusionLink struct {
	hub      *fusionHub
	conn     *secure.Conn
	name     string
	mode     string
	priority int
	queue    chan protocol.Frame
	closed   chan struct{}
	close    sync.Once
	lastSeen atomic.Int64
	rttNanos atomic.Int64
}

func newFusionHub(ctx context.Context, logger *slog.Logger, stats *Stats, role string, targets map[string]string, keepalive, dialTimeout, unavailableTimeout, recoveryHold time.Duration, replayLimit int) *fusionHub {
	h := &fusionHub{
		ctx: ctx, logger: logger, stats: stats, role: role, targets: targets,
		keepalive: keepalive, dialTimeout: dialTimeout,
		unavailableTimeout: unavailableTimeout, recoveryHold: recoveryHold,
		replayLimit: replayLimit, links: make(map[*fusionLink]struct{}),
		flows: make(map[uint32]*fusionFlow), change: make(chan struct{}, 1),
	}
	h.nextID.Store(1)
	return h
}

func (h *fusionHub) ready() bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return !h.closed && len(h.links) > 0
}

func (h *fusionHub) addLink(conn *secure.Conn, name, mode string, priority int) *fusionLink {
	l := &fusionLink{
		hub: h, conn: conn, name: name, mode: mode, priority: priority,
		queue: make(chan protocol.Frame, 512), closed: make(chan struct{}),
	}
	l.lastSeen.Store(time.Now().UnixNano())

	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		_ = conn.Close()
		return nil
	}
	h.links[l] = struct{}{}
	previous := h.primary
	if previous == nil || (len(h.flows) == 0 && priority < previous.priority) {
		h.primary = l
	}
	selected := h.primary
	flows := h.flowSnapshotLocked()
	h.mu.Unlock()
	h.stats.sessions.Add(1)
	h.stats.fusionLinks.Add(1)
	h.signalChange()
	h.logger.Info("FusionMux path connected", "path", name, "mode", mode, "priority", priority)

	go l.writer()
	go l.reader()
	go l.keepaliveLoop()
	if previous != selected {
		h.notePrimary(previous, selected)
		for _, flow := range flows {
			go flow.resume()
		}
	} else if priority < previous.priority {
		go h.promoteAfter(l)
	} else {
		for _, flow := range flows {
			go flow.replayPending()
		}
	}
	return l
}

func (h *fusionHub) promoteAfter(candidate *fusionLink) {
	if h.recoveryHold > 0 {
		timer := time.NewTimer(h.recoveryHold)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-candidate.closed:
			return
		case <-h.ctx.Done():
			return
		}
	}
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	if _, exists := h.links[candidate]; !exists {
		h.mu.Unlock()
		return
	}
	previous := h.primary
	if previous != nil && previous.priority <= candidate.priority {
		h.mu.Unlock()
		return
	}
	h.primary = candidate
	flows := h.flowSnapshotLocked()
	h.mu.Unlock()
	h.notePrimary(previous, candidate)
	h.signalChange()
	for _, flow := range flows {
		go flow.resume()
	}
}

func (h *fusionHub) removeLink(link *fusionLink) {
	h.mu.Lock()
	if _, exists := h.links[link]; !exists {
		h.mu.Unlock()
		return
	}
	delete(h.links, link)
	previous := h.primary
	if h.primary == link {
		h.primary = h.bestLocked()
	}
	next := h.primary
	flows := h.flowSnapshotLocked()
	empty := len(h.links) == 0
	h.mu.Unlock()
	h.stats.sessions.Add(-1)
	h.stats.fusionLinks.Add(-1)
	h.signalChange()
	h.logger.Warn("FusionMux path disconnected", "path", link.name, "mode", link.mode)
	if previous != next {
		h.notePrimary(previous, next)
	}
	for _, flow := range flows {
		go flow.resume()
	}
	if empty {
		go h.expireIfUnavailable()
	}
}

func (h *fusionHub) expireIfUnavailable() {
	timer := time.NewTimer(h.unavailableTimeout)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-h.ctx.Done():
		return
	}
	h.mu.RLock()
	if h.closed || len(h.links) != 0 {
		h.mu.RUnlock()
		return
	}
	flows := h.flowSnapshotLocked()
	h.mu.RUnlock()
	for _, flow := range flows {
		flow.terminate(false, errFusionUnavailable)
	}
}

func (h *fusionHub) notePrimary(previous, next *fusionLink) {
	previousName, nextName := "", ""
	if previous != nil {
		previousName = previous.name
	}
	if next != nil {
		nextName = next.name
	}
	if previous != nil && previous != next {
		h.stats.fusionFailovers.Add(1)
	}
	h.stats.setFusionPrimary(nextName)
	h.logger.Info("FusionMux primary selected", "previous", previousName, "current", nextName)
}

func (h *fusionHub) bestLocked() *fusionLink {
	var best *fusionLink
	for link := range h.links {
		if link.isClosed() {
			continue
		}
		if best == nil || fusionLinkLess(link, best) {
			best = link
		}
	}
	return best
}

func fusionLinkLess(a, b *fusionLink) bool {
	if a.priority != b.priority {
		return a.priority < b.priority
	}
	if len(a.queue) != len(b.queue) {
		return len(a.queue) < len(b.queue)
	}
	if ar, br := a.rttNanos.Load(), b.rttNanos.Load(); ar != br {
		if ar == 0 {
			return false
		}
		if br == 0 {
			return true
		}
		return ar < br
	}
	return a.name < b.name
}

func (h *fusionHub) candidates() []*fusionLink {
	h.mu.RLock()
	defer h.mu.RUnlock()
	primary := h.primary
	items := make([]*fusionLink, 0, len(h.links))
	for link := range h.links {
		if link != primary && !link.isClosed() {
			items = append(items, link)
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return fusionLinkLess(items[i], items[j]) })
	if primary != nil && !primary.isClosed() {
		items = append([]*fusionLink{primary}, items...)
	}
	return items
}

func (h *fusionHub) send(frame protocol.Frame) error {
	for _, link := range h.candidates() {
		if err := link.enqueue(frame); err == nil {
			return nil
		}
	}
	return errFusionUnavailable
}

func (h *fusionHub) waitReady(ctx context.Context) error {
	timer := time.NewTimer(h.unavailableTimeout)
	defer timer.Stop()
	for {
		if h.ready() {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			return errFusionUnavailable
		case <-h.change:
		}
	}
}

func (h *fusionHub) signalChange() {
	select {
	case h.change <- struct{}{}:
	default:
	}
}

func (h *fusionHub) addFlow(flow *fusionFlow) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return false
	}
	if _, exists := h.flows[flow.id]; exists {
		return false
	}
	h.flows[flow.id] = flow
	h.stats.streams.Add(1)
	return true
}

func (h *fusionHub) getFlow(id uint32) *fusionFlow {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.flows[id]
}

func (h *fusionHub) removeFlow(id uint32) {
	h.mu.Lock()
	if _, exists := h.flows[id]; exists {
		delete(h.flows, id)
		h.stats.streams.Add(-1)
	}
	h.mu.Unlock()
}

func (h *fusionHub) flowSnapshotLocked() []*fusionFlow {
	items := make([]*fusionFlow, 0, len(h.flows))
	for _, flow := range h.flows {
		items = append(items, flow)
	}
	return items
}

func (h *fusionHub) nextFlowID() uint32 {
	for {
		id := h.nextID.Add(2)
		if id != 0 && h.getFlow(id) == nil {
			return id
		}
	}
}

func (h *fusionHub) closeAll() {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	h.closed = true
	links := make([]*fusionLink, 0, len(h.links))
	for link := range h.links {
		links = append(links, link)
	}
	flows := h.flowSnapshotLocked()
	h.mu.Unlock()
	for _, flow := range flows {
		flow.terminate(false, net.ErrClosed)
	}
	for _, link := range links {
		link.shutdown(net.ErrClosed)
	}
	h.signalChange()
}

func (h *fusionHub) handleFrame(link *fusionLink, frame protocol.Frame) error {
	switch frame.Type {
	case protocol.FusionOpen:
		if h.role != "client" {
			return errors.New("FusionMux server received an unexpected open request")
		}
		go h.handleRemoteOpen(frame)
		return nil
	case protocol.FusionOpenOK:
		if flow := h.getFlow(frame.StreamID); flow != nil {
			flow.resolveOpen(nil)
		}
		return nil
	case protocol.FusionOpenError:
		if flow := h.getFlow(frame.StreamID); flow != nil {
			flow.resolveOpen(fmt.Errorf("remote open failed: %s", frame.Payload))
		}
		return nil
	case protocol.FusionData:
		flow := h.getFlow(frame.StreamID)
		if flow == nil {
			_ = link.enqueue(protocol.Frame{Type: protocol.FusionClose, StreamID: frame.StreamID, Payload: fusionOffsetPayload(0)})
			return nil
		}
		return flow.handleData(fusionPayloadOffset(frame.Payload), frame.Payload[8:])
	case protocol.FusionAck:
		if flow := h.getFlow(frame.StreamID); flow != nil {
			flow.handleAck(fusionPayloadOffset(frame.Payload))
		}
		return nil
	case protocol.FusionClose:
		if flow := h.getFlow(frame.StreamID); flow != nil {
			flow.handlePeerClose(fusionPayloadOffset(frame.Payload))
		}
		return nil
	default:
		return fmt.Errorf("unexpected FusionMux frame type %d", frame.Type)
	}
}

func (l *fusionLink) enqueue(frame protocol.Frame) error {
	select {
	case <-l.closed:
		return net.ErrClosed
	default:
	}
	select {
	case l.queue <- frame:
		return nil
	case <-l.closed:
		return net.ErrClosed
	default:
		return errors.New("FusionMux path send queue is full")
	}
}

func (l *fusionLink) writer() {
	deadline := maxDuration(2*l.hub.keepalive, 5*time.Second)
	for {
		select {
		case frame := <-l.queue:
			_ = l.conn.SetWriteDeadline(time.Now().Add(deadline))
			if err := l.conn.WriteFrame(frame); err != nil {
				l.shutdown(err)
				return
			}
			_ = l.conn.SetWriteDeadline(time.Time{})
		case <-l.closed:
			return
		case <-l.hub.ctx.Done():
			l.shutdown(nil)
			return
		}
	}
}

func (l *fusionLink) reader() {
	for {
		frame, err := l.conn.ReadFrame()
		if err != nil {
			l.shutdown(err)
			return
		}
		l.lastSeen.Store(time.Now().UnixNano())
		switch frame.Type {
		case protocol.Ping:
			if err := l.enqueue(protocol.Frame{Type: protocol.Pong, Payload: frame.Payload}); err != nil {
				l.shutdown(err)
				return
			}
		case protocol.Pong:
			if len(frame.Payload) == 8 {
				sent := int64(fusionPayloadOffset(frame.Payload))
				if elapsed := time.Since(time.Unix(0, sent)); elapsed > 0 {
					l.rttNanos.Store(int64(elapsed))
				}
			}
		default:
			if err := l.hub.handleFrame(l, frame); err != nil {
				l.shutdown(err)
				return
			}
		}
	}
}

func (l *fusionLink) keepaliveLoop() {
	ticker := time.NewTicker(l.hub.keepalive)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if time.Since(time.Unix(0, l.lastSeen.Load())) > 3*l.hub.keepalive {
				l.shutdown(errors.New("FusionMux keepalive timeout"))
				return
			}
			stamp := fusionOffsetPayload(uint64(time.Now().UnixNano()))
			if err := l.enqueue(protocol.Frame{Type: protocol.Ping, Payload: stamp}); err != nil {
				l.shutdown(err)
				return
			}
		case <-l.closed:
			return
		case <-l.hub.ctx.Done():
			return
		}
	}
}

func (l *fusionLink) isClosed() bool {
	select {
	case <-l.closed:
		return true
	default:
		return false
	}
}

func (l *fusionLink) shutdown(cause error) {
	l.close.Do(func() {
		close(l.closed)
		_ = l.conn.Close()
		l.hub.removeLink(l)
		if cause != nil && !errors.Is(cause, net.ErrClosed) {
			l.hub.logger.Debug("FusionMux path closed", "path", l.name, "error", cause)
		}
	})
}

func maxDuration(a, b time.Duration) time.Duration {
	if a > b {
		return a
	}
	return b
}
