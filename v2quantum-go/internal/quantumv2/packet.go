package quantumv2

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
)

const (
	packetMagic   = "V2Q3"
	packetVersion = 3
	packetHeader  = 34
)

type packetType uint8

const (
	packetHello packetType = iota + 1
	packetCookie
	packetConnect
	packetAccept
	packetData
	packetACK
	packetFEC
	packetClose
)

type packet struct {
	typeID    packetType
	sessionID uint64
	sequence  uint32
	ack       uint32
	ackMask   uint64
	payload   []byte
}

func (p packet) marshal() ([]byte, error) {
	if len(p.payload) > hardMaxDatagram-packetHeader {
		return nil, fmt.Errorf("quantum v2 payload exceeds %d", hardMaxDatagram-packetHeader)
	}
	b := make([]byte, packetHeader+len(p.payload))
	copy(b[:4], packetMagic)
	b[4] = packetVersion
	b[5] = byte(p.typeID)
	binary.BigEndian.PutUint64(b[6:14], p.sessionID)
	binary.BigEndian.PutUint32(b[14:18], p.sequence)
	binary.BigEndian.PutUint32(b[18:22], p.ack)
	binary.BigEndian.PutUint64(b[22:30], p.ackMask)
	binary.BigEndian.PutUint16(b[30:32], uint16(len(p.payload)))
	// Bytes 32-33 are reserved for forward-compatible flags.
	copy(b[packetHeader:], p.payload)
	return b, nil
}

func parsePacket(b []byte) (packet, error) {
	if len(b) < packetHeader || len(b) > hardMaxDatagram {
		return packet{}, errors.New("invalid quantum v2 datagram size")
	}
	if !bytes.Equal(b[:4], []byte(packetMagic)) || b[4] != packetVersion {
		return packet{}, errors.New("invalid quantum v2 datagram magic or version")
	}
	size := int(binary.BigEndian.Uint16(b[30:32]))
	if size != len(b)-packetHeader {
		return packet{}, errors.New("invalid quantum v2 payload length")
	}
	typeID := packetType(b[5])
	if typeID < packetHello || typeID > packetClose {
		return packet{}, errors.New("unknown quantum v2 packet type")
	}
	return packet{
		typeID:    typeID,
		sessionID: binary.BigEndian.Uint64(b[6:14]),
		sequence:  binary.BigEndian.Uint32(b[14:18]),
		ack:       binary.BigEndian.Uint32(b[18:22]),
		ackMask:   binary.BigEndian.Uint64(b[22:30]),
		payload:   append([]byte(nil), b[packetHeader:]...),
	}, nil
}

type fecBlock struct {
	base    uint32
	lengths []int
	parity  map[int][]byte
}

var errFECInsufficientParity = errors.New("insufficient FEC parity")

func encodeFEC(base uint32, payloads [][]byte, parityShards int) ([][]byte, error) {
	if len(payloads) < 2 || len(payloads) > maxFECDataShards {
		return nil, errors.New("invalid FEC data shard count")
	}
	if parityShards < 1 || parityShards > maxFECParity {
		return nil, errors.New("invalid FEC parity shard count")
	}
	maxLen := 0
	for _, payload := range payloads {
		if len(payload) > maxLen {
			maxLen = len(payload)
		}
		if len(payload) > 0xffff {
			return nil, errors.New("FEC shard is too large")
		}
	}
	meta := 6 + 2*len(payloads)
	out := make([][]byte, parityShards)
	for parityIndex := range parityShards {
		b := make([]byte, meta+maxLen)
		binary.BigEndian.PutUint32(b[:4], base)
		b[4] = byte(len(payloads))
		b[5] = byte(parityIndex)
		for dataIndex, payload := range payloads {
			binary.BigEndian.PutUint16(b[6+2*dataIndex:8+2*dataIndex], uint16(len(payload)))
			coefficient := fecCoefficient(parityIndex, dataIndex)
			for offset, value := range payload {
				b[meta+offset] ^= gfMultiply(coefficient, value)
			}
		}
		out[parityIndex] = b
	}
	return out, nil
}

func decodeFEC(payload []byte) (fecBlock, error) {
	if len(payload) < 10 {
		return fecBlock{}, errors.New("truncated FEC block")
	}
	count := int(payload[4])
	if count < 2 || count > maxFECDataShards {
		return fecBlock{}, errors.New("invalid FEC data shard count")
	}
	parityIndex := int(payload[5])
	if parityIndex < 0 || parityIndex >= maxFECParity {
		return fecBlock{}, errors.New("invalid FEC parity index")
	}
	meta := 6 + 2*count
	if len(payload) < meta {
		return fecBlock{}, errors.New("truncated FEC lengths")
	}
	lengths := make([]int, count)
	maxLen := 0
	for i := range lengths {
		lengths[i] = int(binary.BigEndian.Uint16(payload[6+2*i : 8+2*i]))
		if lengths[i] > maxLen {
			maxLen = lengths[i]
		}
	}
	if len(payload)-meta != maxLen {
		return fecBlock{}, errors.New("invalid FEC parity length")
	}
	return fecBlock{
		base:    binary.BigEndian.Uint32(payload[:4]),
		lengths: lengths,
		parity:  map[int][]byte{parityIndex: append([]byte(nil), payload[meta:]...)},
	}, nil
}

func mergeFECBlock(dst *fecBlock, src fecBlock) error {
	if dst.base != src.base || len(dst.lengths) != len(src.lengths) {
		return errors.New("inconsistent FEC block metadata")
	}
	for i := range dst.lengths {
		if dst.lengths[i] != src.lengths[i] {
			return errors.New("inconsistent FEC shard lengths")
		}
	}
	for index, parity := range src.parity {
		if existing, ok := dst.parity[index]; ok && !bytes.Equal(existing, parity) {
			return errors.New("conflicting FEC parity shard")
		}
		dst.parity[index] = append([]byte(nil), parity...)
	}
	return nil
}

// recoverFEC reconstructs every missing data shard when enough independent
// parity rows are present. The Cauchy generator matrix is maximum-distance
// separable for the bounded data/parity ranges used by Quantum v3.
func recoverFEC(block fecBlock, known map[int][]byte) (map[int][]byte, error) {
	missing := make([]int, 0, len(block.lengths))
	maxLen := 0
	for index, length := range block.lengths {
		if length > maxLen {
			maxLen = length
		}
		if payload, ok := known[index]; ok {
			if len(payload) != length {
				return nil, errors.New("known FEC shard has an invalid length")
			}
			continue
		}
		missing = append(missing, index)
	}
	if len(missing) == 0 {
		return map[int][]byte{}, nil
	}
	if len(block.parity) < len(missing) {
		return nil, errFECInsufficientParity
	}
	parityIndexes := make([]int, 0, len(block.parity))
	for index, parity := range block.parity {
		if index < 0 || index >= maxFECParity || len(parity) != maxLen {
			return nil, errors.New("invalid FEC parity shard")
		}
		parityIndexes = append(parityIndexes, index)
	}
	sort.Ints(parityIndexes)
	parityIndexes = parityIndexes[:len(missing)]

	matrix := make([][]byte, len(missing))
	right := make([][]byte, len(missing))
	for row, parityIndex := range parityIndexes {
		matrix[row] = make([]byte, len(missing))
		for column, dataIndex := range missing {
			matrix[row][column] = fecCoefficient(parityIndex, dataIndex)
		}
		right[row] = append([]byte(nil), block.parity[parityIndex]...)
		for dataIndex, payload := range known {
			coefficient := fecCoefficient(parityIndex, dataIndex)
			for offset, value := range payload {
				right[row][offset] ^= gfMultiply(coefficient, value)
			}
		}
	}
	inverse, err := invertGFMatrix(matrix)
	if err != nil {
		return nil, err
	}
	recovered := make(map[int][]byte, len(missing))
	for outputIndex, dataIndex := range missing {
		payload := make([]byte, maxLen)
		for row := range right {
			coefficient := inverse[outputIndex][row]
			for offset, value := range right[row] {
				payload[offset] ^= gfMultiply(coefficient, value)
			}
		}
		recovered[dataIndex] = payload[:block.lengths[dataIndex]]
	}
	return recovered, nil
}

func fecCoefficient(parityIndex, dataIndex int) byte {
	// x=data index (0..31), y=32+parity index (32..39). Every
	// square submatrix of 1/(x+y) is invertible in GF(256).
	return gfInverse(byte(dataIndex) ^ byte(maxFECDataShards+parityIndex))
}

var gfExponent, gfLogarithm = buildGFTables()

func buildGFTables() ([512]byte, [256]byte) {
	var exponent [512]byte
	var logarithm [256]byte
	value := 1
	for i := 0; i < 255; i++ {
		exponent[i] = byte(value)
		logarithm[value] = byte(i)
		value <<= 1
		if value&0x100 != 0 {
			value ^= 0x11d
		}
	}
	for i := 255; i < len(exponent); i++ {
		exponent[i] = exponent[i-255]
	}
	return exponent, logarithm
}

func gfMultiply(a, b byte) byte {
	if a == 0 || b == 0 {
		return 0
	}
	return gfExponent[int(gfLogarithm[a])+int(gfLogarithm[b])]
}

func gfInverse(value byte) byte {
	if value == 0 {
		return 0
	}
	return gfExponent[255-int(gfLogarithm[value])]
}

func invertGFMatrix(input [][]byte) ([][]byte, error) {
	size := len(input)
	if size == 0 {
		return nil, errors.New("empty FEC matrix")
	}
	augmented := make([][]byte, size)
	for row := range size {
		if len(input[row]) != size {
			return nil, errors.New("non-square FEC matrix")
		}
		augmented[row] = make([]byte, 2*size)
		copy(augmented[row], input[row])
		augmented[row][size+row] = 1
	}
	for column := range size {
		pivot := column
		for pivot < size && augmented[pivot][column] == 0 {
			pivot++
		}
		if pivot == size {
			return nil, errors.New("singular FEC matrix")
		}
		augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
		inversePivot := gfInverse(augmented[column][column])
		for index := range augmented[column] {
			augmented[column][index] = gfMultiply(augmented[column][index], inversePivot)
		}
		for row := range size {
			if row == column || augmented[row][column] == 0 {
				continue
			}
			factor := augmented[row][column]
			for index := range augmented[row] {
				augmented[row][index] ^= gfMultiply(factor, augmented[column][index])
			}
		}
	}
	out := make([][]byte, size)
	for row := range size {
		out[row] = append([]byte(nil), augmented[row][size:]...)
	}
	return out, nil
}
