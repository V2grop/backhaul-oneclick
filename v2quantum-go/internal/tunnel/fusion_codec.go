package tunnel

import "encoding/binary"

func fusionDataPayload(offset uint64, data []byte) []byte {
	payload := make([]byte, 8+len(data))
	binary.BigEndian.PutUint64(payload[:8], offset)
	copy(payload[8:], data)
	return payload
}

func fusionOffsetPayload(offset uint64) []byte {
	payload := make([]byte, 8)
	binary.BigEndian.PutUint64(payload, offset)
	return payload
}

func fusionPayloadOffset(payload []byte) uint64 {
	return binary.BigEndian.Uint64(payload[:8])
}
