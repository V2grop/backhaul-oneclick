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
