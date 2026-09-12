package secure

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/protocol"
)

const (
	magic         = "V2QG1"
	nonceSize     = 32
	macSize       = 32
	handshakeWait = 10 * time.Second
	maxRecordSize = protocol.HeaderSize + protocol.MaxPayload + 32
)

type Conn struct {
	net.Conn
	sendAEAD   cipher.AEAD
	recvAEAD   cipher.AEAD
	sendPrefix [4]byte
	recvPrefix [4]byte
	sendSeq    uint64
	recvSeq    uint64
	writeMu    sync.Mutex
}

func Client(conn net.Conn, psk []byte) (*Conn, error) {
	if len(psk) < 32 {
		return nil, errors.New("PSK must contain at least 32 bytes")
	}
	if err := conn.SetDeadline(time.Now().Add(handshakeWait)); err != nil {
		return nil, err
	}
	defer conn.SetDeadline(time.Time{})

	clientNonce := make([]byte, nonceSize)
	if _, err := rand.Read(clientNonce); err != nil {
		return nil, fmt.Errorf("client nonce: %w", err)
	}
	helloMAC := authMAC(psk, []byte("client-hello"), clientNonce)
	if err := writeAll(conn, append(append([]byte(magic), clientNonce...), helloMAC...)); err != nil {
		return nil, fmt.Errorf("write client hello: %w", err)
	}

	reply := make([]byte, len(magic)+nonceSize+macSize)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return nil, fmt.Errorf("read server hello: %w", err)
	}
	if subtle.ConstantTimeCompare(reply[:len(magic)], []byte(magic)) != 1 {
		return nil, errors.New("unexpected server protocol magic")
	}
	serverNonce := reply[len(magic) : len(magic)+nonceSize]
	want := authMAC(psk, []byte("server-hello"), clientNonce, serverNonce)
	if subtle.ConstantTimeCompare(reply[len(magic)+nonceSize:], want) != 1 {
		return nil, errors.New("server authentication failed")
	}
	finish := authMAC(psk, []byte("client-finish"), clientNonce, serverNonce)
	if err := writeAll(conn, finish); err != nil {
		return nil, fmt.Errorf("write client finish: %w", err)
	}
	return newConn(conn, psk, clientNonce, serverNonce, true)
}

func Server(conn net.Conn, psk []byte) (*Conn, error) {
	if len(psk) < 32 {
		return nil, errors.New("PSK must contain at least 32 bytes")
	}
	if err := conn.SetDeadline(time.Now().Add(handshakeWait)); err != nil {
		return nil, err
	}
	defer conn.SetDeadline(time.Time{})

	hello := make([]byte, len(magic)+nonceSize+macSize)
	if _, err := io.ReadFull(conn, hello); err != nil {
		return nil, fmt.Errorf("read client hello: %w", err)
	}
	if subtle.ConstantTimeCompare(hello[:len(magic)], []byte(magic)) != 1 {
		return nil, errors.New("unexpected client protocol magic")
	}
	clientNonce := hello[len(magic) : len(magic)+nonceSize]
	want := authMAC(psk, []byte("client-hello"), clientNonce)
	if subtle.ConstantTimeCompare(hello[len(magic)+nonceSize:], want) != 1 {
		return nil, errors.New("client authentication failed")
	}
	serverNonce := make([]byte, nonceSize)
	if _, err := rand.Read(serverNonce); err != nil {
		return nil, fmt.Errorf("server nonce: %w", err)
	}
	replyMAC := authMAC(psk, []byte("server-hello"), clientNonce, serverNonce)
	if err := writeAll(conn, append(append([]byte(magic), serverNonce...), replyMAC...)); err != nil {
		return nil, fmt.Errorf("write server hello: %w", err)
	}
	finish := make([]byte, macSize)
	if _, err := io.ReadFull(conn, finish); err != nil {
		return nil, fmt.Errorf("read client finish: %w", err)
	}
	wantFinish := authMAC(psk, []byte("client-finish"), clientNonce, serverNonce)
	if subtle.ConstantTimeCompare(finish, wantFinish) != 1 {
		return nil, errors.New("client finish authentication failed")
	}
	return newConn(conn, psk, clientNonce, serverNonce, false)
}

func newConn(conn net.Conn, psk, clientNonce, serverNonce []byte, client bool) (*Conn, error) {
	salt := append(append([]byte(nil), clientNonce...), serverNonce...)
	c2sKey := hkdfSHA256(psk, salt, []byte("v2quantum-go/c2s/key"), 32)
	s2cKey := hkdfSHA256(psk, salt, []byte("v2quantum-go/s2c/key"), 32)
	c2sPrefix := hkdfSHA256(psk, salt, []byte("v2quantum-go/c2s/nonce"), 4)
	s2cPrefix := hkdfSHA256(psk, salt, []byte("v2quantum-go/s2c/nonce"), 4)

	makeAEAD := func(key []byte) (cipher.AEAD, error) {
		block, err := aes.NewCipher(key)
		if err != nil {
			return nil, err
		}
		return cipher.NewGCM(block)
	}
	c2s, err := makeAEAD(c2sKey)
	if err != nil {
		return nil, err
	}
	s2c, err := makeAEAD(s2cKey)
	if err != nil {
		return nil, err
	}
	sc := &Conn{Conn: conn}
	if client {
		sc.sendAEAD, sc.recvAEAD = c2s, s2c
		copy(sc.sendPrefix[:], c2sPrefix)
		copy(sc.recvPrefix[:], s2cPrefix)
	} else {
		sc.sendAEAD, sc.recvAEAD = s2c, c2s
		copy(sc.sendPrefix[:], s2cPrefix)
		copy(sc.recvPrefix[:], c2sPrefix)
	}
	return sc, nil
}

func (c *Conn) WriteFrame(frame protocol.Frame) error {
	plain, err := frame.MarshalBinary()
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	seq := c.sendSeq
	c.sendSeq++
	nonce := recordNonce(c.sendPrefix, seq)
	aad := make([]byte, 8)
	binary.BigEndian.PutUint64(aad, seq)
	ciphertext := c.sendAEAD.Seal(nil, nonce, plain, aad)
	header := make([]byte, 12)
	binary.BigEndian.PutUint64(header[:8], seq)
	binary.BigEndian.PutUint32(header[8:], uint32(len(ciphertext)))
	if err := writeAll(c.Conn, header); err != nil {
		return err
	}
	return writeAll(c.Conn, ciphertext)
}

func (c *Conn) ReadFrame() (protocol.Frame, error) {
	header := make([]byte, 12)
	if _, err := io.ReadFull(c.Conn, header); err != nil {
		return protocol.Frame{}, err
	}
	seq := binary.BigEndian.Uint64(header[:8])
	if seq != c.recvSeq {
		return protocol.Frame{}, fmt.Errorf("record sequence mismatch: got %d want %d", seq, c.recvSeq)
	}
	size := binary.BigEndian.Uint32(header[8:])
	if size < uint32(c.recvAEAD.Overhead()+protocol.HeaderSize) || size > maxRecordSize {
		return protocol.Frame{}, fmt.Errorf("invalid encrypted record size %d", size)
	}
	ciphertext := make([]byte, size)
	if _, err := io.ReadFull(c.Conn, ciphertext); err != nil {
		return protocol.Frame{}, err
	}
	nonce := recordNonce(c.recvPrefix, seq)
	aad := header[:8]
	plain, err := c.recvAEAD.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return protocol.Frame{}, errors.New("encrypted record authentication failed")
	}
	c.recvSeq++
	return protocol.UnmarshalBinary(plain)
}

func recordNonce(prefix [4]byte, seq uint64) []byte {
	nonce := make([]byte, 12)
	copy(nonce[:4], prefix[:])
	binary.BigEndian.PutUint64(nonce[4:], seq)
	return nonce
}

func authMAC(key []byte, parts ...[]byte) []byte {
	h := hmac.New(sha256.New, key)
	for _, part := range parts {
		_, _ = h.Write(part)
	}
	return h.Sum(nil)
}

func hkdfSHA256(secret, salt, info []byte, n int) []byte {
	extract := hmac.New(sha256.New, salt)
	_, _ = extract.Write(secret)
	prk := extract.Sum(nil)
	out := make([]byte, 0, n)
	var previous []byte
	for counter := byte(1); len(out) < n; counter++ {
		expand := hmac.New(sha256.New, prk)
		_, _ = expand.Write(previous)
		_, _ = expand.Write(info)
		_, _ = expand.Write([]byte{counter})
		previous = expand.Sum(nil)
		out = append(out, previous...)
	}
	return out[:n]
}

func writeAll(w io.Writer, b []byte) error {
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
