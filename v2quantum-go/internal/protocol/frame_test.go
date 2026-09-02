package protocol

import (
	"bytes"
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
