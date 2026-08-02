package protocol

import (
	"encoding/binary"
	"errors"
	"fmt"
)

type Type uint8

const (
	Open Type = iota + 1
	OpenOK
	OpenError
	Data
	Close
	Ping
	Pong
)

const (
	HeaderSize = 5
	MaxPayload = 1 << 20
	DataChunk  = 32 << 10
)

type Frame struct {
	Type     Type
	StreamID uint32
	Payload  []byte
}

func (f Frame) Validate() error {
	if f.Type < Open || f.Type > Pong {
		return fmt.Errorf("invalid frame type %d", f.Type)
	}
	if len(f.Payload) > MaxPayload {
		return fmt.Errorf("payload exceeds %d bytes", MaxPayload)
	}
	if f.StreamID == 0 && f.Type != Ping && f.Type != Pong {
		return errors.New("stream id zero is reserved for session control")
	}
	if f.StreamID != 0 && (f.Type == Ping || f.Type == Pong) {
		return errors.New("ping/pong must use stream id zero")
	}
	return nil
}

func (f Frame) MarshalBinary() ([]byte, error) {
	if err := f.Validate(); err != nil {
		return nil, err
	}
	b := make([]byte, HeaderSize+len(f.Payload))
	b[0] = byte(f.Type)
	binary.BigEndian.PutUint32(b[1:5], f.StreamID)
	copy(b[HeaderSize:], f.Payload)
	return b, nil
}

func UnmarshalBinary(b []byte) (Frame, error) {
	if len(b) < HeaderSize {
		return Frame{}, errors.New("truncated frame")
	}
	f := Frame{
		Type:     Type(b[0]),
		StreamID: binary.BigEndian.Uint32(b[1:5]),
		Payload:  append([]byte(nil), b[HeaderSize:]...),
	}
	if err := f.Validate(); err != nil {
		return Frame{}, err
	}
	return f, nil
}
