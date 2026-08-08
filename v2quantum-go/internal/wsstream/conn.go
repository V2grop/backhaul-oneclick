package wsstream

import (
	"bufio"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
)

const (
	opContinuation = 0x0
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xa

	maxMessageSize = 2 << 20
)

// Conn exposes a binary RFC 6455 WebSocket as an ordered net.Conn byte stream.
// Message boundaries are deliberately hidden: V2Quantum already supplies its
// own authenticated record framing above this layer.
type Conn struct {
	net.Conn
	reader   *bufio.Reader
	isClient bool

	readMu    sync.Mutex
	writeMu   sync.Mutex
	readBuf   []byte
	fragment  []byte
	closeOnce sync.Once
}

func newConn(raw net.Conn, reader *bufio.Reader, isClient bool) *Conn {
	if reader == nil {
		reader = bufio.NewReader(raw)
	}
	return &Conn{Conn: raw, reader: reader, isClient: isClient}
}

func (c *Conn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for len(c.readBuf) == 0 {
		fin, opcode, payload, err := c.readFrame()
		if err != nil {
			return 0, err
		}
		switch opcode {
		case opPing:
			if err := c.writeControl(opPong, payload); err != nil {
				return 0, err
			}
		case opPong:
			continue
		case opClose:
			_ = c.writeControl(opClose, payload)
			return 0, io.EOF
		case opBinary:
			if len(c.fragment) != 0 {
				return 0, errors.New("websocket: new data frame during fragmented message")
			}
			if fin {
				c.readBuf = payload
			} else {
				c.fragment = append(c.fragment[:0], payload...)
			}
		case opContinuation:
			if c.fragment == nil {
				return 0, errors.New("websocket: continuation without initial frame")
			}
			if len(c.fragment)+len(payload) > maxMessageSize {
				return 0, errors.New("websocket: fragmented message is too large")
			}
			c.fragment = append(c.fragment, payload...)
			if fin {
				c.readBuf = c.fragment
				c.fragment = nil
			}
		default:
			return 0, errors.New("websocket: unsupported frame opcode")
		}
	}
	n := copy(p, c.readBuf)
	c.readBuf = c.readBuf[n:]
	return n, nil
}

func (c *Conn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if len(p) > maxMessageSize {
		return 0, errors.New("websocket: write exceeds maximum message size")
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if err := c.writeFrameLocked(true, opBinary, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *Conn) Close() error {
	var err error
	c.closeOnce.Do(func() {
		_ = c.writeControl(opClose, nil)
		err = c.Conn.Close()
	})
	return err
}

func (c *Conn) writeControl(opcode byte, payload []byte) error {
	if len(payload) > 125 {
		payload = payload[:125]
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	return c.writeFrameLocked(true, opcode, payload)
}

func (c *Conn) writeFrameLocked(fin bool, opcode byte, payload []byte) error {
	first := opcode
	if fin {
		first |= 0x80
	}
	header := make([]byte, 0, 14)
	header = append(header, first)
	maskBit := byte(0)
	if c.isClient {
		maskBit = 0x80
	}
	switch n := len(payload); {
	case n < 126:
		header = append(header, maskBit|byte(n))
	case n <= 65535:
		header = append(header, maskBit|126, 0, 0)
		binary.BigEndian.PutUint16(header[len(header)-2:], uint16(n))
	default:
		header = append(header, maskBit|127, 0, 0, 0, 0, 0, 0, 0, 0)
		binary.BigEndian.PutUint64(header[len(header)-8:], uint64(n))
	}
	wirePayload := payload
	if c.isClient {
		var key [4]byte
		if _, err := rand.Read(key[:]); err != nil {
			return err
		}
		header = append(header, key[:]...)
		wirePayload = append([]byte(nil), payload...)
		applyMask(wirePayload, key)
	}
	if err := writeAll(c.Conn, header); err != nil {
		return err
	}
	return writeAll(c.Conn, wirePayload)
}

func (c *Conn) readFrame() (bool, byte, []byte, error) {
	var fixed [2]byte
	if _, err := io.ReadFull(c.reader, fixed[:]); err != nil {
		return false, 0, nil, err
	}
	if fixed[0]&0x70 != 0 {
		return false, 0, nil, errors.New("websocket: reserved bits are set")
	}
	fin := fixed[0]&0x80 != 0
	opcode := fixed[0] & 0x0f
	masked := fixed[1]&0x80 != 0
	if masked == c.isClient {
		return false, 0, nil, errors.New("websocket: invalid masking direction")
	}
	length := uint64(fixed[1] & 0x7f)
	switch length {
	case 126:
		var b [2]byte
		if _, err := io.ReadFull(c.reader, b[:]); err != nil {
			return false, 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err := io.ReadFull(c.reader, b[:]); err != nil {
			return false, 0, nil, err
		}
		length = binary.BigEndian.Uint64(b[:])
		if length>>63 != 0 {
			return false, 0, nil, errors.New("websocket: invalid 64-bit frame length")
		}
	}
	control := opcode >= opClose
	if control && (!fin || length > 125) {
		return false, 0, nil, errors.New("websocket: invalid control frame")
	}
	if length > maxMessageSize {
		return false, 0, nil, errors.New("websocket: frame is too large")
	}
	var key [4]byte
	if masked {
		if _, err := io.ReadFull(c.reader, key[:]); err != nil {
			return false, 0, nil, err
		}
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(c.reader, payload); err != nil {
		return false, 0, nil, err
	}
	if masked {
		applyMask(payload, key)
	}
	return fin, opcode, payload, nil
}

func applyMask(payload []byte, key [4]byte) {
	for i := range payload {
		payload[i] ^= key[i&3]
	}
}

func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		b = b[n:]
	}
	return nil
}

var _ net.Conn = (*Conn)(nil)
