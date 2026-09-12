package quantum

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	packetMagic   = "V2QU"
	packetVersion = 1
	packetHeader  = 24
	maxDatagram   = 1400
	maxPayload    = 1150
)

type packetType uint8

const (
	packetHello packetType = iota + 1
	packetCookie
	packetConnect
	packetAccept
	packetData
	packetACK
	packetClose
)

type packet struct {
	typeID    packetType
	sessionID uint64
	sequence  uint32
	ack       uint32
	payload   []byte
}

func (p packet) marshal() ([]byte, error) {
	if len(p.payload) > maxPayload {
		return nil, fmt.Errorf("quantum payload exceeds %d", maxPayload)
	}
	b := make([]byte, packetHeader+len(p.payload))
	copy(b[:4], packetMagic)
	b[4] = packetVersion
	b[5] = byte(p.typeID)
	binary.BigEndian.PutUint64(b[6:14], p.sessionID)
	binary.BigEndian.PutUint32(b[14:18], p.sequence)
	binary.BigEndian.PutUint32(b[18:22], p.ack)
	binary.BigEndian.PutUint16(b[22:24], uint16(len(p.payload)))
	copy(b[packetHeader:], p.payload)
	return b, nil
}

func parsePacket(b []byte) (packet, error) {
	if len(b) < packetHeader || len(b) > maxDatagram {
		return packet{}, errors.New("invalid quantum datagram size")
	}
	if !bytes.Equal(b[:4], []byte(packetMagic)) || b[4] != packetVersion {
		return packet{}, errors.New("invalid quantum datagram magic or version")
	}
	size := int(binary.BigEndian.Uint16(b[22:24]))
	if size != len(b)-packetHeader || size > maxPayload {
		return packet{}, errors.New("invalid quantum payload length")
	}
	typeID := packetType(b[5])
	if typeID < packetHello || typeID > packetClose {
		return packet{}, errors.New("unknown quantum packet type")
	}
	return packet{
		typeID:    typeID,
		sessionID: binary.BigEndian.Uint64(b[6:14]),
		sequence:  binary.BigEndian.Uint32(b[14:18]),
		ack:       binary.BigEndian.Uint32(b[18:22]),
		payload:   append([]byte(nil), b[packetHeader:]...),
	}, nil
}
