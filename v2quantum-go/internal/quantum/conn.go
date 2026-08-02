package quantum

import (
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

const (
	defaultWindow = 128
	defaultRTO    = 250 * time.Millisecond
	maxRetries    = 48
)

type sentPacket struct {
	wire     []byte
	sentAt   time.Time
	retries  int
	sequence uint32
}

type Conn struct {
	pc         net.PacketConn
	remote     net.Addr
	sessionID  uint64
	localAddr  net.Addr
	payloadMax int
	closePC    bool
	onClose    func()

	sendMu       sync.Mutex
	sendNext     uint32
	unacked      map[uint32]*sentPacket
	windowSignal chan struct{}

	recvMu     sync.Mutex
	recvNext   uint32
	reorder    map[uint32][]byte
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

func newConn(pc net.PacketConn, remote net.Addr, sessionID uint64, idleTimeout time.Duration, closePC bool, onClose func()) *Conn {
	if idleTimeout < 5*time.Second {
		idleTimeout = 30 * time.Second
	}
	c := &Conn{
		pc:           pc,
		remote:       remote,
		sessionID:    sessionID,
		localAddr:    pc.LocalAddr(),
		payloadMax:   payloadLimit(pc),
		closePC:      closePC,
		onClose:      onClose,
		sendNext:     1,
		unacked:      make(map[uint32]*sentPacket),
		windowSignal: make(chan struct{}, 1),
		recvNext:     1,
		reorder:      make(map[uint32][]byte),
		// ACKs confirm network delivery, while the encrypted stream above can
		// briefly lag during a burst of multiplexed connections. Keep a bounded
		// application queue large enough for that burst without stalling the one
		// packet-reader goroutine that also processes ACKs and retransmissions.
		readCh:      make(chan []byte, defaultWindow*8),
		idleTimeout: idleTimeout,
		done:        make(chan struct{}),
	}
	c.lastReceive.Store(time.Now().UnixNano())
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

type datagramSizer interface {
	MaxDatagramSize() int
}

func payloadLimit(pc net.PacketConn) int {
	limit := maxPayload
	if sized, ok := pc.(datagramSizer); ok {
		candidate := sized.MaxDatagramSize() - packetHeader
		if candidate > 0 && candidate < limit {
			limit = candidate
		}
	}
	return limit
}

func (c *Conn) writeChunk(payload []byte) error {
	for {
		c.sendMu.Lock()
		if len(c.unacked) < defaultWindow {
			sequence := c.sendNext
			c.sendNext++
			ack := c.currentACK()
			p := packet{typeID: packetData, sessionID: c.sessionID, sequence: sequence, ack: ack, payload: append([]byte(nil), payload...)}
			wire, err := p.marshal()
			if err != nil {
				c.sendMu.Unlock()
				return err
			}
			c.unacked[sequence] = &sentPacket{wire: wire, sentAt: time.Now(), sequence: sequence}
			c.sendMu.Unlock()
			if _, err := c.pc.WriteTo(wire, c.remote); err != nil {
				c.close(false)
				return err
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

func (c *Conn) handle(p packet) {
	c.lastReceive.Store(time.Now().UnixNano())
	if p.ack > 0 {
		c.applyACK(p.ack)
	}
	switch p.typeID {
	case packetData:
		c.handleData(p)
	case packetACK:
		return
	case packetClose:
		c.close(false)
	}
}

func (c *Conn) handleData(p packet) {
	c.recvMu.Lock()
	if p.sequence < c.recvNext {
		ack := c.recvNext - 1
		c.recvMu.Unlock()
		c.sendACK(ack)
		return
	}
	if p.sequence >= c.recvNext+defaultWindow*2 {
		ack := c.recvNext - 1
		c.recvMu.Unlock()
		c.sendACK(ack)
		return
	}
	if _, exists := c.reorder[p.sequence]; !exists {
		c.reorder[p.sequence] = p.payload
	}
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
	ack := c.recvNext - 1
	c.recvMu.Unlock()
	for _, payload := range deliver {
		select {
		case c.readCh <- payload:
		case <-c.done:
			return
		default:
			c.close(true)
			return
		}
	}
	c.sendACK(ack)
}

func (c *Conn) currentACK() uint32 {
	c.recvMu.Lock()
	defer c.recvMu.Unlock()
	return c.recvNext - 1
}

func (c *Conn) sendACK(ack uint32) {
	wire, err := (packet{typeID: packetACK, sessionID: c.sessionID, ack: ack}).marshal()
	if err == nil {
		_, _ = c.pc.WriteTo(wire, c.remote)
	}
}

func (c *Conn) applyACK(ack uint32) {
	c.sendMu.Lock()
	changed := false
	for sequence := range c.unacked {
		if sequence <= ack {
			delete(c.unacked, sequence)
			changed = true
		}
	}
	c.sendMu.Unlock()
	if changed {
		select {
		case c.windowSignal <- struct{}{}:
		default:
		}
	}
}

func (c *Conn) retransmitLoop() {
	ticker := time.NewTicker(defaultRTO / 2)
	defer ticker.Stop()
	for {
		select {
		case now := <-ticker.C:
			if now.Sub(time.Unix(0, c.lastReceive.Load())) > c.idleTimeout {
				c.close(true)
				return
			}
			var resend [][]byte
			c.sendMu.Lock()
			for _, pending := range c.unacked {
				if now.Sub(pending.sentAt) < defaultRTO {
					continue
				}
				if pending.retries >= maxRetries {
					c.sendMu.Unlock()
					c.close(true)
					return
				}
				pending.retries++
				pending.sentAt = now
				resend = append(resend, pending.wire)
			}
			c.sendMu.Unlock()
			for _, wire := range resend {
				if _, err := c.pc.WriteTo(wire, c.remote); err != nil {
					c.close(false)
					return
				}
			}
		case <-c.done:
			return
		}
	}
}

func (c *Conn) Close() error { c.close(true); return nil }

func (c *Conn) close(send bool) {
	c.closeOnce.Do(func() {
		if send {
			if wire, err := (packet{typeID: packetClose, sessionID: c.sessionID, ack: c.currentACK()}).marshal(); err == nil {
				_, _ = c.pc.WriteTo(wire, c.remote)
			}
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
		return make(chan time.Time)
	}
	d := time.Until(time.Unix(0, value))
	if d <= 0 {
		ch := make(chan time.Time, 1)
		ch <- time.Now()
		return ch
	}
	return time.After(d)
}

type timeoutError string

func (e timeoutError) Error() string   { return string(e) + " timeout" }
func (e timeoutError) Timeout() bool   { return true }
func (e timeoutError) Temporary() bool { return true }

var _ net.Conn = (*Conn)(nil)
var _ = io.EOF
var _ = errors.New
