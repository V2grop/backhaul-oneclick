//go:build !linux

package rawip

import (
	"errors"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

func SendProbe(_ config.RawSettings, _ []byte) error {
	return errors.New("raw ICMP transport is Linux-only")
}
