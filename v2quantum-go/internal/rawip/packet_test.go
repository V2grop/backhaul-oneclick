package rawip

import (
	"encoding/binary"
	"net"
	"testing"
)

func TestBuildIPv4ICMPEcho(t *testing.T) {
	packet, err := BuildIPv4ICMPEcho(net.ParseIP("192.0.2.10"), net.ParseIP("198.51.100.20"), 7, 9, []byte("v2q"), false)
	if err != nil {
		t.Fatal(err)
	}
	if got := binary.BigEndian.Uint16(packet[2:4]); int(got) != len(packet) {
		t.Fatalf("total length=%d want=%d", got, len(packet))
	}
	if checksum(packet[:ipv4HeaderLen]) != 0 {
		t.Fatal("invalid IPv4 checksum")
	}
	if checksum(packet[ipv4HeaderLen:]) != 0 {
		t.Fatal("invalid ICMP checksum")
	}
	if packet[ipv4HeaderLen] != 8 {
		t.Fatalf("unexpected ICMP type %d", packet[ipv4HeaderLen])
	}
}
