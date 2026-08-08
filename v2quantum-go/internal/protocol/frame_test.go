package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	want := Frame{Type: Data, StreamID: 42, Payload: []byte("hello")}
	b, err := want.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	got, err := UnmarshalBinary(b)
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != want.Type || got.StreamID != want.StreamID || !bytes.Equal(got.Payload, want.Payload) {
		t.Fatalf("round trip mismatch: %#v", got)
	}
}

func TestRejectInvalidControlStream(t *testing.T) {
	if _, err := (Frame{Type: Data, StreamID: 0}).MarshalBinary(); err == nil {
		t.Fatal("data frame accepted stream id zero")
	}
}

func TestTUNPacketFrameRoundTrip(t *testing.T) {
	want := Frame{Type: Packet, Payload: []byte{0x45, 0, 0, 20}}
	b, err := want.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	got, err := UnmarshalBinary(b)
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != Packet || got.StreamID != 0 || !bytes.Equal(got.Payload, want.Payload) {
		t.Fatalf("packet round trip mismatch: %#v", got)
	}
	if _, err := (Frame{Type: Packet, StreamID: 1, Payload: []byte{1}}).MarshalBinary(); err == nil {
		t.Fatal("packet frame accepted nonzero stream id")
	}
	if _, err := (Frame{Type: Packet}).MarshalBinary(); err == nil {
		t.Fatal("packet frame accepted an empty payload")
	}
}

func TestFusionFramesRoundTrip(t *testing.T) {
	offset := make([]byte, 8)
	binary.BigEndian.PutUint64(offset, 1234)
	tests := []Frame{
		{Type: FusionHello, Payload: []byte("quantum")},
		{Type: FusionHelloOK},
		{Type: FusionOpen, StreamID: 7, Payload: []byte("panel")},
		{Type: FusionOpenOK, StreamID: 7},
		{Type: FusionOpenError, StreamID: 7, Payload: []byte("unavailable")},
		{Type: FusionData, StreamID: 7, Payload: append(append([]byte(nil), offset...), []byte("payload")...)},
		{Type: FusionAck, StreamID: 7, Payload: append([]byte(nil), offset...)},
		{Type: FusionClose, StreamID: 7, Payload: append([]byte(nil), offset...)},
	}
	for _, want := range tests {
		encoded, err := want.MarshalBinary()
		if err != nil {
			t.Fatalf("marshal frame %d: %v", want.Type, err)
		}
		got, err := UnmarshalBinary(encoded)
		if err != nil {
			t.Fatalf("unmarshal frame %d: %v", want.Type, err)
		}
		if got.Type != want.Type || got.StreamID != want.StreamID || !bytes.Equal(got.Payload, want.Payload) {
			t.Fatalf("frame %d mismatch: got %#v want %#v", want.Type, got, want)
		}
	}
}

func TestRejectInvalidFusionFrames(t *testing.T) {
	tests := []Frame{
		{Type: FusionHello},
		{Type: FusionHelloOK, Payload: []byte("unexpected")},
		{Type: FusionOpen, StreamID: 9},
		{Type: FusionData, StreamID: 9, Payload: make([]byte, 8)},
		{Type: FusionAck, StreamID: 9, Payload: make([]byte, 7)},
		{Type: FusionClose, StreamID: 9, Payload: make([]byte, 9)},
	}
	for _, frame := range tests {
		if _, err := frame.MarshalBinary(); err == nil {
			t.Fatalf("invalid FusionMux frame %d was accepted", frame.Type)
		}
	}
}
