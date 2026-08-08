package tunnel

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/protocol"
)

type fusionChunk struct {
	offset uint64
	data   []byte
}

type fusionFlow struct {
	id        uint32
	hub       *fusionHub
	mapping   string
	conn      net.Conn
	initiator bool

	openResult   chan error
	openResolved atomic.Bool
	started      sync.Once
	done         chan struct{}
	close        sync.Once

	sendMu      sync.Mutex
	sendOffset  uint64
	ackedOffset uint64
	pending     []fusionChunk
	pendingSize int
	wake        chan struct{}
	replayMu    sync.Mutex

	recvMu      sync.Mutex
	recvOffset  uint64
	reorder     map[uint64][]byte
	reorderSize int
	recv        chan []byte
	peerClosing bool
	peerFinal   uint64
}

func newFusionFlow(id uint32, hub *fusionHub, mapping string, conn net.Conn, initiator bool) *fusionFlow {
	return &fusionFlow{
		id: id, hub: hub, mapping: mapping, conn: conn, initiator: initiator,
		openResult: make(chan error, 1), done: make(chan struct{}),
		wake: make(chan struct{}, 1), reorder: make(map[uint64][]byte),
		recv: make(chan []byte, 256),
	}
}

func (f *fusionFlow) open(ctx context.Context) error {
	if err := f.hub.waitReady(ctx); err != nil {
		return err
	}
	if err := f.sendOpen(); err != nil {
		return err
	}
	timer := time.NewTimer(f.hub.unavailableTimeout + f.hub.dialTimeout)
	defer timer.Stop()
	select {
	case err := <-f.openResult:
		if err != nil {
			return err
		}
		f.start()
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return errors.New("FusionMux remote target open timed out")
	case <-f.done:
		return net.ErrClosed
	}
}

func (f *fusionFlow) sendOpen() error {
	return f.hub.send(protocol.Frame{Type: protocol.FusionOpen, StreamID: f.id, Payload: []byte(f.mapping)})
}

func (f *fusionFlow) resolveOpen(err error) {
	if !f.openResolved.CompareAndSwap(false, true) {
		return
	}
	select {
	case f.openResult <- err:
	default:
	}
}

func (f *fusionFlow) start() {
	f.started.Do(func() {
		go f.writeLocal()
		go f.readLocal()
	})
}

func (f *fusionFlow) readLocal() {
	buffer := make([]byte, 16<<10)
	for {
		n, err := f.conn.Read(buffer)
		if n > 0 {
			if queueErr := f.queueData(buffer[:n]); queueErr != nil {
				f.terminate(true, queueErr)
				return
			}
		}
		if err != nil {
			f.sendMu.Lock()
			final := f.sendOffset
			f.sendMu.Unlock()
			f.waitAcknowledged(final, f.hub.unavailableTimeout)
			_ = f.hub.send(protocol.Frame{Type: protocol.FusionClose, StreamID: f.id, Payload: fusionOffsetPayload(final)})
			f.terminate(false, err)
			return
		}
	}
}

func (f *fusionFlow) queueData(data []byte) error {
	copyData := append([]byte(nil), data...)
	for {
		f.sendMu.Lock()
		if f.pendingSize+len(copyData) <= f.hub.replayLimit {
			offset := f.sendOffset
			f.sendOffset += uint64(len(copyData))
			f.pending = append(f.pending, fusionChunk{offset: offset, data: copyData})
			f.pendingSize += len(copyData)
			f.sendMu.Unlock()
			f.hub.stats.bytesToExit.Add(int64(len(copyData)))
			_ = f.hub.send(protocol.Frame{Type: protocol.FusionData, StreamID: f.id, Payload: fusionDataPayload(offset, copyData)})
			return nil
		}
		f.sendMu.Unlock()
		select {
		case <-f.wake:
		case <-f.done:
			return net.ErrClosed
		case <-f.hub.ctx.Done():
			return f.hub.ctx.Err()
		}
	}
}

func (f *fusionFlow) writeLocal() {
	for {
		select {
		case data := <-f.recv:
			if err := writeFull(f.conn, data); err != nil {
				f.terminate(true, err)
				return
			}
			f.hub.stats.bytesToUser.Add(int64(len(data)))
		case <-f.done:
			return
		case <-f.hub.ctx.Done():
			return
		}
	}
}

func (f *fusionFlow) handleData(offset uint64, data []byte) error {
	if len(data) == 0 {
		return errors.New("FusionMux received an empty data segment")
	}
	f.recvMu.Lock()
	end := offset + uint64(len(data))
	if end < offset {
		f.recvMu.Unlock()
		return errors.New("FusionMux data offset overflow")
	}
	if end <= f.recvOffset {
		ack := f.recvOffset
		f.recvMu.Unlock()
		_ = f.sendAck(ack)
		return nil
	}
	if offset < f.recvOffset {
		trim := f.recvOffset - offset
		data = data[trim:]
		offset = f.recvOffset
	}
	if offset-f.recvOffset > uint64(f.hub.replayLimit) {
		f.recvMu.Unlock()
		return errors.New("FusionMux reorder window exceeded")
	}
	if offset > f.recvOffset {
		if _, exists := f.reorder[offset]; !exists {
			if f.reorderSize+len(data) > f.hub.replayLimit {
				f.recvMu.Unlock()
				return errors.New("FusionMux reorder buffer is full")
			}
			f.reorder[offset] = append([]byte(nil), data...)
			f.reorderSize += len(data)
		}
		ack := f.recvOffset
		f.recvMu.Unlock()
		_ = f.sendAck(ack)
		return nil
	}

	deliver := [][]byte{append([]byte(nil), data...)}
	f.recvOffset += uint64(len(data))
	for {
		next, exists := f.reorder[f.recvOffset]
		if !exists {
			break
		}
		delete(f.reorder, f.recvOffset)
		f.reorderSize -= len(next)
		deliver = append(deliver, next)
		f.recvOffset += uint64(len(next))
	}
	ack := f.recvOffset
	shouldClose := f.peerClosing && f.recvOffset >= f.peerFinal
	for _, item := range deliver {
		select {
		case f.recv <- item:
		case <-f.done:
			f.recvMu.Unlock()
			return nil
		case <-f.hub.ctx.Done():
			f.recvMu.Unlock()
			return f.hub.ctx.Err()
		}
	}
	f.recvMu.Unlock()
	_ = f.sendAck(ack)
	if shouldClose {
		f.terminate(false, io.EOF)
	}
	return nil
}

func (f *fusionFlow) sendAck(offset uint64) error {
	return f.hub.send(protocol.Frame{Type: protocol.FusionAck, StreamID: f.id, Payload: fusionOffsetPayload(offset)})
}

func (f *fusionFlow) handleAck(offset uint64) {
	f.sendMu.Lock()
	if offset <= f.ackedOffset || offset > f.sendOffset {
		f.sendMu.Unlock()
		return
	}
	f.ackedOffset = offset
	for len(f.pending) > 0 {
		chunk := &f.pending[0]
		end := chunk.offset + uint64(len(chunk.data))
		if end <= offset {
			f.pendingSize -= len(chunk.data)
			f.pending = f.pending[1:]
			continue
		}
		if chunk.offset < offset {
			trim := int(offset - chunk.offset)
			chunk.data = append([]byte(nil), chunk.data[trim:]...)
			chunk.offset = offset
			f.pendingSize -= trim
		}
		break
	}
	f.sendMu.Unlock()
	f.signalWake()
}

func (f *fusionFlow) handlePeerClose(final uint64) {
	f.recvMu.Lock()
	f.peerClosing = true
	f.peerFinal = final
	ready := f.recvOffset >= final
	f.recvMu.Unlock()
	if ready {
		f.terminate(false, io.EOF)
	}
}

func (f *fusionFlow) waitAcknowledged(final uint64, timeout time.Duration) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		f.sendMu.Lock()
		ready := f.ackedOffset >= final
		f.sendMu.Unlock()
		if ready {
			return
		}
		select {
		case <-f.wake:
		case <-timer.C:
			return
		case <-f.done:
			return
		case <-f.hub.ctx.Done():
			return
		}
	}
}

func (f *fusionFlow) resume() {
	select {
	case <-f.done:
		return
	default:
	}
	if f.initiator {
		_ = f.sendOpen()
	}
	f.replayPending()
}

func (f *fusionFlow) replayPending() {
	f.replayMu.Lock()
	defer f.replayMu.Unlock()
	select {
	case <-f.done:
		return
	default:
	}
	f.sendMu.Lock()
	chunks := make([]fusionChunk, len(f.pending))
	for i, chunk := range f.pending {
		chunks[i] = fusionChunk{offset: chunk.offset, data: append([]byte(nil), chunk.data...)}
	}
	f.sendMu.Unlock()
	for _, chunk := range chunks {
		if err := f.hub.send(protocol.Frame{Type: protocol.FusionData, StreamID: f.id, Payload: fusionDataPayload(chunk.offset, chunk.data)}); err != nil {
			return
		}
		f.hub.stats.fusionReplayedBytes.Add(int64(len(chunk.data)))
	}
}

func (f *fusionFlow) signalWake() {
	select {
	case f.wake <- struct{}{}:
	default:
	}
}

func (f *fusionFlow) terminate(sendClose bool, cause error) {
	f.close.Do(func() {
		if sendClose {
			f.sendMu.Lock()
			final := f.sendOffset
			f.sendMu.Unlock()
			_ = f.hub.send(protocol.Frame{Type: protocol.FusionClose, StreamID: f.id, Payload: fusionOffsetPayload(final)})
		}
		close(f.done)
		_ = f.conn.Close()
		f.hub.removeFlow(f.id)
		f.signalWake()
		if !f.openResolved.Load() {
			if cause == nil {
				cause = net.ErrClosed
			}
			f.resolveOpen(cause)
		}
		if cause != nil && !errors.Is(cause, io.EOF) && !errors.Is(cause, net.ErrClosed) {
			f.hub.logger.Debug("FusionMux stream closed", "stream", f.id, "mapping", f.mapping, "error", cause)
		}
	})
}

func (h *fusionHub) handleRemoteOpen(frame protocol.Frame) {
	h.openMu.Lock()
	defer h.openMu.Unlock()
	if existing := h.getFlow(frame.StreamID); existing != nil {
		_ = h.send(protocol.Frame{Type: protocol.FusionOpenOK, StreamID: frame.StreamID})
		existing.replayPending()
		return
	}
	mapping := string(frame.Payload)
	target, exists := h.targets[mapping]
	if !exists {
		h.stats.openFailed.Add(1)
		_ = h.send(protocol.Frame{Type: protocol.FusionOpenError, StreamID: frame.StreamID, Payload: []byte("unknown mapping")})
		return
	}
	ctx, cancel := context.WithTimeout(h.ctx, h.dialTimeout)
	defer cancel()
	dialer := net.Dialer{Timeout: h.dialTimeout, KeepAlive: h.keepalive}
	conn, err := dialer.DialContext(ctx, "tcp", target)
	if err != nil {
		h.stats.openFailed.Add(1)
		_ = h.send(protocol.Frame{Type: protocol.FusionOpenError, StreamID: frame.StreamID, Payload: []byte("target unavailable")})
		return
	}
	tuneTCPConn(conn, h.keepalive)
	flow := newFusionFlow(frame.StreamID, h, mapping, conn, false)
	if !h.addFlow(flow) {
		_ = conn.Close()
		_ = h.send(protocol.Frame{Type: protocol.FusionOpenError, StreamID: frame.StreamID, Payload: []byte("duplicate stream")})
		return
	}
	flow.resolveOpen(nil)
	flow.start()
	if err := h.send(protocol.Frame{Type: protocol.FusionOpenOK, StreamID: frame.StreamID}); err != nil {
		flow.terminate(false, fmt.Errorf("send open acknowledgement: %w", err))
	}
}
