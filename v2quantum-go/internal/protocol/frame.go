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
	Packet
	FusionHello
	FusionHelloOK
	FusionOpen
	FusionOpenOK
	FusionOpenError
	FusionData
	FusionAck
	FusionClose
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
	if f.Type < Open || f.Type > FusionClose {
		return fmt.Errorf("invalid frame type %d", f.Type)
	}
	if len(f.Payload) > MaxPayload {
		return fmt.Errorf("payload exceeds %d bytes", MaxPayload)
	}
	control := f.Type == Ping || f.Type == Pong || f.Type == Packet || f.Type == FusionHello || f.Type == FusionHelloOK
	if f.StreamID == 0 && !control {
		return errors.New("stream id zero is reserved for session control")
	}
	if f.StreamID != 0 && control {
		return errors.New("session control frames must use stream id zero")
	}
	if f.Type == Packet && len(f.Payload) == 0 {
		return errors.New("packet payload must not be empty")
	}
	if f.Type == FusionHello && (len(f.Payload) < 1 || len(f.Payload) > 32) {
		return errors.New("fusion hello path must contain 1-32 bytes")
	}
	if f.Type == FusionHelloOK && len(f.Payload) != 0 {
		return errors.New("fusion hello acknowledgement must be empty")
	}
	if f.Type == FusionOpen && (len(f.Payload) < 1 || len(f.Payload) > 64) {
		return errors.New("fusion mapping must contain 1-64 bytes")
	}
	if f.Type == FusionData && len(f.Payload) < 9 {
		return errors.New("fusion data must contain an offset and payload")
	}
	if (f.Type == FusionAck || f.Type == FusionClose) && len(f.Payload) != 8 {
		return errors.New("fusion acknowledgement/close payload must be 8 bytes")
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
