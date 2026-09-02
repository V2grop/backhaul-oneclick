//go:build !linux

package tun

import (
	"context"
	"errors"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

func Open(context.Context, config.TUN) (Device, error) {
	return nil, errors.New("TUN mode is supported only on Linux")
}
