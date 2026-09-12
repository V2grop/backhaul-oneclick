package quantumv2

import (
	"errors"
	"math/bits"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type sentPacket struct {
	payload    []byte
	sentAt     time.Time
	retries    int
	gapReports int
	sequence   uint32
}

type outboundPacket struct {
	sequence uint32
	payload  []byte
}

type Conn struct {
	pc          net.PacketConn
	remote      net.Addr
	sessionID   uint64
	localAddr   net.Addr
	settings    Settings
	datagramMax int
	payloadMax  int
	closePC     bool
	onClose     func()

	sendMu       sync.Mutex
	sendNext     uint32
	unacked      map[uint32]*sentPacket
	windowSignal chan struct{}
	cwnd         int
	ssthresh     int
	ackCredit    int
	srtt         time.Duration
	rttvar       time.Duration
	rto          time.Duration
	rttReady     bool
	lastLoss     time.Time
	nextSend     time.Time
	fecSendBase  uint32
	fecSend      [][]byte

	recvMu     sync.Mutex
	recvNext   uint32
	reorder    map[uint32][]byte
	fecRecent  map[uint32][]byte
	fecPending map[uint32]*fecBlock
	readCh     chan []byte
	readMu     sync.Mutex
	readBuffer []byte

	readDeadline  atomic.Int64
	writeDeadline atomic.Int64
	lastReceive   atomic.Int64
	idleTimeout   time.Duration

	done      chan struct{}
	closeOnce sync.Once
}

type datagramSizer interface {
	MaxDatagramSize() int
}

func newConn(pc net.PacketConn, remote net.Addr, sessionID uint64, idleTimeout time.Duration, settings Settings, closePC bool, onClose func()) *Conn {
	settings = settings.normalized()
	if idleTimeout < 5*time.Second {
		idleTimeout = 30 * time.Second
	}
	datagramMax := settings.MaxDatagramSize
	if sized, ok := pc.(datagramSizer); ok {
		if candidate := sized.MaxDatagramSize(); candidate >= minDatagramSize && candidate < datagramMax {
			datagramMax = candidate
		}
	}
	fecOverhead := 0
	if settings.FECDataShards >= 2 && settings.FECParityShards > 0 {
		fecOverhead = 6 + 2*settings.FECDataShards
	}
	payloadMax := datagramMax - packetHeader - fecOverhead
	queueSize := min(settings.ReceiveWindow*4, 8192)
	if queueSize < 128 {
		queueSize = 128
	}
	initialWindow := settings.SendWindow
	if settings.AutoTune {
		initialWindow = min(10, settings.SendWindow)
	}
	c := &Conn{
		pc:           pc,
		remote:       remote,
		sessionID:    sessionID,
		localAddr:    pc.LocalAddr(),
		settings:     settings,
		datagramMax:  datagramMax,
		payloadMax:   payloadMax,
		closePC:      closePC,
		onClose:      onClose,
		sendNext:     1,
		unacked:      make(map[uint32]*sentPacket),
		windowSignal: make(chan struct{}, 1),
		cwnd:         initialWindow,
		ssthresh:     settings.SendWindow,
		rto:          settings.InitialRTO,
		recvNext:     1,
		reorder:      make(map[uint32][]byte),
		fecRecent:    make(map[uint32][]byte),
		fecPending:   make(map[uint32]*fecBlock),
		readCh:       make(chan []byte, queueSize),
		idleTimeout:  idleTimeout,
		done:         make(chan struct{}),
	}
	c.lastReceive.Store(time.Now().UnixNano())
	c.observeTransport()
	go c.retransmitLoop()
	return c
}

func (c *Conn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for len(c.readBuffer) == 0 {
		deadline := deadlineChan(c.readDeadline.Load())
		select {
		case chunk := <-c.readCh:
			c.readBuffer = chunk
		case <-deadline:
			return 0, timeoutError("read")
		case <-c.done:
			return 0, net.ErrClosed
		}
	}
	n := copy(p, c.readBuffer)
	c.readBuffer = c.readBuffer[n:]
	return n, nil
}

func (c *Conn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	written := 0
	for len(p) > 0 {
		size := min(len(p), c.payloadMax)
		if err := c.writeChunk(p[:size]); err != nil {
			return written, err
		}
		written += size
		p = p[size:]
	}
	return written, nil
}

func (c *Conn) writeChunk(payload []byte) error {
	for {
		c.sendMu.Lock()
		window := min(c.settings.SendWindow, c.cwnd)
		if len(c.unacked) < window {
			if delay := c.pacingDelayLocked(time.Now()); delay > 0 {
				c.sendMu.Unlock()
				if err := c.waitWrite(delay); err != nil {
					return err
				}
				continue
			}
			sequence := c.sendNext
			if sequence == 0 {
				c.sendMu.Unlock()
				c.close(true)
				return errors.New("quantum v2 sequence space exhausted")
			}
			c.sendNext++
			copyPayload := append([]byte(nil), payload...)
			now := time.Now()
			c.unacked[sequence] = &sentPacket{payload: copyPayload, sentAt: now, sequence: sequence}
			c.advancePacingLocked(now)
			fecPayloads, fecBase, fecReady, err := c.addFECShardLocked(sequence, copyPayload)
			c.sendMu.Unlock()
			if err != nil {
				c.close(true)
				return err
			}
			if err := c.sendData(sequence, copyPayload); err != nil {
				c.close(false)
				return err
			}
			if fecReady {
				for _, fecPayload := range fecPayloads {
					if err := c.sendControl(packetFEC, fecBase, fecPayload); err != nil {
						c.close(false)
						return err
					}
					if c.settings.Observer != nil {
						c.settings.Observer.CountFECSent()
					}
				}
			}
			return nil
		}
		c.sendMu.Unlock()
		deadline := deadlineChan(c.writeDeadline.Load())
		select {
		case <-c.windowSignal:
		case <-deadline:
			return timeoutError("write")
		case <-c.done:
			return net.ErrClosed
		}
	}
}

func (c *Conn) waitWrite(delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	deadline := deadlineChan(c.writeDeadline.Load())
	select {
	case <-timer.C:
		return nil
	case <-deadline:
		return timeoutError("write")
	case <-c.done:
		return net.ErrClosed
	}
}

func (c *Conn) pacingDelayLocked(now time.Time) time.Duration {
	if !c.settings.AutoTune || !c.rttReady || c.cwnd < 1 || c.nextSend.IsZero() || !now.Before(c.nextSend) {
		return 0
	}
	return c.nextSend.Sub(now)
}

func (c *Conn) advancePacingLocked(now time.Time) {
	if !c.settings.AutoTune || !c.rttReady || c.cwnd < 1 {
		return
	}
	interval := c.srtt / time.Duration(c.cwnd)
	if interval < 50*time.Microsecond {
		interval = 0
	}
	if interval > 2*time.Millisecond {
		interval = 2 * time.Millisecond
	}
	c.nextSend = now.Add(interval)
}

func (c *Conn) addFECShardLocked(sequence uint32, payload []byte) ([][]byte, uint32, bool, error) {
	count := c.settings.FECDataShards
	if count < 2 || c.settings.FECParityShards < 1 {
		return nil, 0, false, nil
	}
	if len(c.fecSend) == 0 {
		c.fecSendBase = sequence
	}
	c.fecSend = append(c.fecSend, append([]byte(nil), payload...))
	if len(c.fecSend) < count {
		return nil, 0, false, nil
	}
	encoded, err := encodeFEC(c.fecSendBase, c.fecSend, c.settings.FECParityShards)
	base := c.fecSendBase
	c.fecSend = c.fecSend[:0]
	c.fecSendBase = 0
	if err != nil {
		return nil, 0, false, err
	}
	return encoded, base, true, nil
}

func (c *Conn) sendData(sequence uint32, payload []byte) error {
	return c.sendControl(packetData, sequence, payload)
}

func (c *Conn) sendControl(typeID packetType, sequence uint32, payload []byte) error {
	ack, mask := c.currentACK()
	wire, err := (packet{
		typeID: typeID, sessionID: c.sessionID, sequence: sequence,
		ack: ack, ackMask: mask, payload: payload,
	}).marshal()
	if err != nil {
		return err
	}
	if len(wire) > c.datagramMax {
		return errors.New("quantum v2 datagram exceeds configured path size")
	}
	_, err = c.pc.WriteTo(wire, c.remote)
	return err
}

func (c *Conn) handle(p packet) {
	c.lastReceive.Store(time.Now().UnixNano())
	if p.ack > 0 || p.ackMask != 0 {
		c.applyACK(p.ack, p.ackMask)
	}
	switch p.typeID {
	case packetData:
		c.handleData(p)
	case packetFEC:
		c.handleFEC(p)
	case packetACK:
		return
	case packetClose:
		c.close(false)
	}
}

func (c *Conn) handleData(p packet) {
	if p.sequence == 0 {
		return
	}
	c.recvMu.Lock()
	if p.sequence < c.recvNext {
		c.recvMu.Unlock()
		c.sendACK()
		return
	}
	if p.sequence-c.recvNext >= uint32(c.settings.ReceiveWindow) {
		c.recvMu.Unlock()
		c.sendACK()
		return
	}
	if _, exists := c.reorder[p.sequence]; !exists {
		data := append([]byte(nil), p.payload...)
		c.reorder[p.sequence] = data
		c.fecRecent[p.sequence] = data
	}
	deliver, recovered := c.advanceReceiveLocked()
	c.recvMu.Unlock()
	c.deliverChunks(deliver)
	for i := 0; i < recovered; i++ {
		if c.settings.Observer != nil {
			c.settings.Observer.CountFECRecovered()
		}
	}
	c.sendACK()
}

func (c *Conn) handleFEC(p packet) {
	block, err := decodeFEC(p.payload)
	if err != nil {
		return
	}
	if block.base != p.sequence {
		return
	}
	c.recvMu.Lock()
	existing := c.fecPending[block.base]
	if existing == nil && len(c.fecPending) >= c.settings.ReceiveWindow {
		c.recvMu.Unlock()
		return
	}
	end := uint64(block.base) + uint64(len(block.lengths))
	receiveLimit := uint64(c.recvNext) + uint64(c.settings.ReceiveWindow)
	if end <= uint64(c.recvNext) || uint64(block.base) >= receiveLimit {
		c.recvMu.Unlock()
		return
	}
	if existing != nil {
		if err := mergeFECBlock(existing, block); err != nil {
			delete(c.fecPending, block.base)
			c.recvMu.Unlock()
			return
		}
	} else {
		copyBlock := block
		c.fecPending[block.base] = &copyBlock
	}
	deliver, recovered := c.advanceReceiveLocked()
	c.recvMu.Unlock()
	c.deliverChunks(deliver)
	for i := 0; i < recovered; i++ {
		if c.settings.Observer != nil {
			c.settings.Observer.CountFECRecovered()
		}
	}
	c.sendACK()
}

func (c *Conn) advanceReceiveLocked() ([][]byte, int) {
	recovered := c.recoverFECLocked()
	var deliver [][]byte
	for {
		payload, ok := c.reorder[c.recvNext]
		if !ok {
			break
		}
		delete(c.reorder, c.recvNext)
		deliver = append(deliver, payload)
		c.recvNext++
	}
	c.cleanupFECLocked()
	return deliver, recovered
}

func (c *Conn) recoverFECLocked() int {
	recovered := 0
	for {
		progress := false
		for base, block := range c.fecPending {
			known := make(map[int][]byte, len(block.lengths))
			outOfWindow := false
			for index := range block.lengths {
				sequenceValue := uint64(base) + uint64(index)
				if sequenceValue > uint64(^uint32(0)) {
					outOfWindow = true
					break
				}
				sequence := uint32(sequenceValue)
				if sequence < c.recvNext {
					if payload, ok := c.fecRecent[sequence]; ok {
						known[index] = payload
						continue
					}
					outOfWindow = true
					break
				}
				if sequence-c.recvNext >= uint32(c.settings.ReceiveWindow) {
					outOfWindow = true
					break
				}
				if payload, ok := c.fecRecent[sequence]; ok {
					known[index] = payload
				}
			}
			if outOfWindow {
				delete(c.fecPending, base)
				continue
			}
			items, err := recoverFEC(*block, known)
			if errors.Is(err, errFECInsufficientParity) {
				continue
			}
			if err != nil || len(items) == 0 {
				delete(c.fecPending, base)
				continue
			}
			for index, value := range items {
				sequence := base + uint32(index)
				c.reorder[sequence] = value
				c.fecRecent[sequence] = value
				recovered++
			}
			delete(c.fecPending, base)
			progress = true
		}
		if !progress {
			break
		}
	}
	return recovered
}

func (c *Conn) cleanupFECLocked() {
	keep := uint32(maxFECDataShards * 2)
	for sequence := range c.fecRecent {
		if sequence+keep < c.recvNext {
			delete(c.fecRecent, sequence)
		}
	}
	for base, block := range c.fecPending {
		if base+uint32(len(block.lengths))+keep < c.recvNext {
			delete(c.fecPending, base)
		}
	}
}

func (c *Conn) deliverChunks(chunks [][]byte) {
	for _, payload := range chunks {
		select {
		case c.readCh <- payload:
		case <-c.done:
			return
		default:
			c.close(true)
			return
		}
	}
}

func (c *Conn) currentACK() (uint32, uint64) {
	c.recvMu.Lock()
	defer c.recvMu.Unlock()
	ack := c.recvNext - 1
	var mask uint64
	for sequence := range c.reorder {
		if sequence <= ack {
			continue
		}
		delta := sequence - ack - 1
		if delta < 64 {
			mask |= uint64(1) << delta
		}
	}
	return ack, mask
}

func (c *Conn) sendACK() {
	_ = c.sendControl(packetACK, 0, nil)
}

func (c *Conn) applyACK(ack uint32, mask uint64) {
	now := time.Now()
	highest := ack
	if mask != 0 {
		highest = ack + uint32(bits.Len64(mask))
	}
	var resend []outboundPacket
	var samples []time.Duration
	ackedCount := 0
	fastCount := 0
	c.sendMu.Lock()
	for sequence, pending := range c.unacked {
		if packetAcknowledged(sequence, ack, mask) {
			if pending.retries == 0 {
				samples = append(samples, now.Sub(pending.sentAt))
			}
			delete(c.unacked, sequence)
			ackedCount++
			continue
		}
		if sequence > ack && sequence < highest {
			pending.gapReports++
			if pending.gapReports >= c.settings.FastResend && now.Sub(pending.sentAt) >= c.settings.MinRTO/2 {
				pending.gapReports = 0
				pending.retries++
				pending.sentAt = now
				resend = append(resend, outboundPacket{sequence: sequence, payload: append([]byte(nil), pending.payload...)})
				fastCount++
			}
		}
	}
	for _, sample := range samples {
		c.updateRTTLocked(sample)
	}
	if ackedCount > 0 {
		c.growWindowLocked(ackedCount)
	}
	if fastCount > 0 {
		c.onLossLocked(now)
	}
	c.sendMu.Unlock()
	if ackedCount > 0 {
		c.signalWindow()
	}
	c.observeTransport()
	for _, item := range resend {
		if c.settings.Observer != nil {
			c.settings.Observer.CountRetransmit(true)
		}
		if err := c.sendData(item.sequence, item.payload); err != nil {
			c.close(false)
			return
		}
	}
}

func packetAcknowledged(sequence, ack uint32, mask uint64) bool {
	if sequence <= ack {
		return true
	}
	delta := sequence - ack - 1
	return delta < 64 && mask&(uint64(1)<<delta) != 0
}

func (c *Conn) updateRTTLocked(sample time.Duration) {
	if sample <= 0 {
		return
	}
	if !c.settings.AutoTune {
		return
	}
	if !c.rttReady {
		c.srtt = sample
		c.rttvar = sample / 2
		c.rttReady = true
	} else {
		delta := c.srtt - sample
		if delta < 0 {
			delta = -delta
		}
		c.rttvar = (3*c.rttvar + delta) / 4
		c.srtt = (7*c.srtt + sample) / 8
	}
	c.rto = clampDuration(c.srtt+max(4*c.rttvar, 10*time.Millisecond), c.settings.MinRTO, c.settings.MaxRTO)
}

func (c *Conn) growWindowLocked(acked int) {
	if !c.settings.AutoTune {
		c.cwnd = c.settings.SendWindow
		return
	}
	if c.cwnd < c.ssthresh {
		c.cwnd = min(c.settings.SendWindow, c.cwnd+acked)
		return
	}
	c.ackCredit += acked
	for c.ackCredit >= c.cwnd && c.cwnd < c.settings.SendWindow {
		c.ackCredit -= c.cwnd
		c.cwnd++
	}
}

func (c *Conn) onLossLocked(now time.Time) {
	if !c.settings.AutoTune || (!c.lastLoss.IsZero() && now.Sub(c.lastLoss) < c.rto) {
		return
	}
	c.lastLoss = now
	c.ssthresh = max(c.cwnd/2, 2)
	c.cwnd = c.ssthresh
	c.ackCredit = 0
}

func (c *Conn) retransmitLoop() {
	interval := clampDuration(c.settings.MinRTO/4, 10*time.Millisecond, 100*time.Millisecond)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case now := <-ticker.C:
			if now.Sub(time.Unix(0, c.lastReceive.Load())) > c.idleTimeout {
				c.close(true)
				return
			}
			var resend []outboundPacket
			exhausted := false
			c.sendMu.Lock()
			for _, pending := range c.unacked {
				if now.Sub(pending.sentAt) < c.packetTimeoutLocked(pending.retries) {
					continue
				}
				if pending.retries >= c.settings.MaxRetries {
					exhausted = true
					break
				}
				pending.retries++
				pending.gapReports = 0
				pending.sentAt = now
				resend = append(resend, outboundPacket{sequence: pending.sequence, payload: append([]byte(nil), pending.payload...)})
			}
			if len(resend) > 0 {
				c.onLossLocked(now)
			}
			c.sendMu.Unlock()
			if exhausted {
				c.close(true)
				return
			}
			c.observeTransport()
			for _, item := range resend {
				if c.settings.Observer != nil {
					c.settings.Observer.CountRetransmit(false)
				}
				if err := c.sendData(item.sequence, item.payload); err != nil {
					c.close(false)
					return
				}
			}
		case <-c.done:
			return
		}
	}
}

func (c *Conn) packetTimeoutLocked(retries int) time.Duration {
	timeout := c.rto
	shift := min(retries, 3)
	for i := 0; i < shift; i++ {
		timeout *= 2
	}
	return min(timeout, c.settings.MaxRTO)
}

func (c *Conn) observeTransport() {
	if c.settings.Observer == nil {
		return
	}
	c.sendMu.Lock()
	srtt, rto, cwnd := c.srtt, c.rto, c.cwnd
	c.sendMu.Unlock()
	c.settings.Observer.ObserveRTT(srtt, rto)
	c.settings.Observer.ObserveWindow(cwnd)
}

func (c *Conn) signalWindow() {
	select {
	case c.windowSignal <- struct{}{}:
	default:
	}
}

func (c *Conn) Close() error { c.close(true); return nil }

func (c *Conn) close(send bool) {
	c.closeOnce.Do(func() {
		if send {
			_ = c.sendControl(packetClose, 0, nil)
		}
		close(c.done)
		if c.onClose != nil {
			c.onClose()
		}
		if c.closePC {
			_ = c.pc.Close()
		}
	})
}

func (c *Conn) LocalAddr() net.Addr  { return c.localAddr }
func (c *Conn) RemoteAddr() net.Addr { return c.remote }

func (c *Conn) SetDeadline(t time.Time) error {
	_ = c.SetReadDeadline(t)
	_ = c.SetWriteDeadline(t)
	return nil
}

func (c *Conn) SetReadDeadline(t time.Time) error {
	c.readDeadline.Store(timeValue(t))
	return nil
}

func (c *Conn) SetWriteDeadline(t time.Time) error {
	c.writeDeadline.Store(timeValue(t))
	return nil
}

func timeValue(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixNano()
}

func deadlineChan(value int64) <-chan time.Time {
	if value == 0 {
		return nil
	}
	d := time.Until(time.Unix(0, value))
	if d <= 0 {
		ch := make(chan time.Time, 1)
		ch <- time.Now()
		return ch
	}
	return time.After(d)
}

func clampDuration(value, low, high time.Duration) time.Duration {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

type timeoutError string

func (e timeoutError) Error() string   { return string(e) + " timeout" }
func (e timeoutError) Timeout() bool   { return true }
func (e timeoutError) Temporary() bool { return true }

var _ net.Conn = (*Conn)(nil)
