package tun

import (
	"context"
	"io"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

// Device is a layer-3 packet interface. Every Read and Write is exactly one
// IP packet because the Linux device is opened with IFF_NO_PI.
type Device interface {
	io.ReadWriteCloser
	Name() string
}

type OpenFunc func(context.Context, config.TUN) (Device, error)
