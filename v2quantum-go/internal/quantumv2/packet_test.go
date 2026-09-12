package quantumv2

import (
	"bytes"
	"errors"
	"testing"
)

func TestPacketRoundTrip(t *testing.T) {
	want := packet{
		typeID: packetData, sessionID: 99, sequence: 7, ack: 4,
		ackMask: 0b10101, payload: []byte("hello"),
	}
	b, err := want.marshal()
	if err != nil {
		t.Fatal(err)
	}
	got, err := parsePacket(b)
	if err != nil {
		t.Fatal(err)
	}
	if got.typeID != want.typeID || got.sessionID != want.sessionID || got.sequence != want.sequence ||
		got.ack != want.ack || got.ackMask != want.ackMask || !bytes.Equal(got.payload, want.payload) {
		t.Fatalf("packet mismatch: %#v", got)
	}
}

func TestFECRecoversMultipleMissingShards(t *testing.T) {
	shards := [][]byte{
		[]byte("first packet"),
		[]byte("two"),
		[]byte("third packet is longer"),
		[]byte("four"),
	}
	wires, err := encodeFEC(100, shards, 2)
	if err != nil {
		t.Fatal(err)
	}
	block, err := decodeFEC(wires[0])
	if err != nil {
		t.Fatal(err)
	}
	second, err := decodeFEC(wires[1])
	if err != nil {
		t.Fatal(err)
	}
	if err := mergeFECBlock(&block, second); err != nil {
		t.Fatal(err)
	}
	known := map[int][]byte{0: shards[0], 2: shards[2]}
	recovered, err := recoverFEC(block, known)
	if err != nil {
		t.Fatal(err)
	}
	for _, missing := range []int{1, 3} {
		if !bytes.Equal(recovered[missing], shards[missing]) {
			t.Fatalf("FEC recovery mismatch for shard %d: got %q want %q", missing, recovered[missing], shards[missing])
		}
	}
}

func TestFECNeedsEnoughParity(t *testing.T) {
	shards := [][]byte{[]byte("one"), []byte("two"), []byte("three"), []byte("four")}
	wires, err := encodeFEC(1, shards, 1)
	if err != nil {
		t.Fatal(err)
	}
	block, err := decodeFEC(wires[0])
	if err != nil {
		t.Fatal(err)
	}
	_, err = recoverFEC(block, map[int][]byte{0: shards[0], 3: shards[3]})
	if !errors.Is(err, errFECInsufficientParity) {
		t.Fatalf("expected insufficient parity, got %v", err)
	}
}

func TestFECRecoveryPatterns(t *testing.T) {
	shards := [][]byte{
		bytes.Repeat([]byte{0x11}, 17),
		bytes.Repeat([]byte{0x22}, 63),
		bytes.Repeat([]byte{0x33}, 128),
		bytes.Repeat([]byte{0x44}, 7),
		bytes.Repeat([]byte{0x55}, 91),
		bytes.Repeat([]byte{0x66}, 32),
	}
	patterns := [][]int{{0}, {1, 4}, {0, 2, 5}}
	for _, missing := range patterns {
		wires, err := encodeFEC(500, shards, len(missing))
		if err != nil {
			t.Fatal(err)
		}
		block, err := decodeFEC(wires[0])
		if err != nil {
			t.Fatal(err)
		}
		for _, wire := range wires[1:] {
			next, decodeErr := decodeFEC(wire)
			if decodeErr != nil {
				t.Fatal(decodeErr)
			}
			if mergeErr := mergeFECBlock(&block, next); mergeErr != nil {
				t.Fatal(mergeErr)
			}
		}
		missingSet := make(map[int]bool, len(missing))
		for _, index := range missing {
			missingSet[index] = true
		}
		known := make(map[int][]byte, len(shards)-len(missing))
		for index, shard := range shards {
			if !missingSet[index] {
				known[index] = shard
			}
		}
		recovered, err := recoverFEC(block, known)
		if err != nil {
			t.Fatalf("missing %v: %v", missing, err)
		}
		for _, index := range missing {
			if !bytes.Equal(recovered[index], shards[index]) {
				t.Fatalf("missing %v: shard %d did not recover", missing, index)
			}
		}
	}
}

func TestSelectiveACK(t *testing.T) {
	ack := uint32(10)
	mask := uint64(0b101)
	for sequence, want := range map[uint32]bool{
		9: true, 10: true, 11: true, 12: false, 13: true, 14: false,
	} {
		if got := packetAcknowledged(sequence, ack, mask); got != want {
			t.Fatalf("sequence %d acknowledged=%v want %v", sequence, got, want)
		}
	}
}
