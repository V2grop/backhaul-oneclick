//go:build linux

package tun

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
)

const (
	tunSetIFF = 0x400454ca
	iffTUN    = 0x0001
	iffNoPI   = 0x1000
	ifNameLen = 16
)

type ifreq struct {
	Name  [ifNameLen]byte
	Flags uint16
	Pad   [22]byte
}

type linuxDevice struct {
	*os.File
	name string
}

func (d *linuxDevice) Name() string { return d.name }

// Open creates a non-persistent TUN device. The interface disappears when the
// process exits, which keeps service removal and rollback deterministic.
func Open(ctx context.Context, settings config.TUN) (Device, error) {
	file, err := os.OpenFile("/dev/net/tun", os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("open /dev/net/tun: %w", err)
	}
	req := ifreq{Flags: iffTUN | iffNoPI}
	copy(req.Name[:], settings.Name)
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), uintptr(tunSetIFF), uintptr(unsafe.Pointer(&req)))
	if errno != 0 {
		_ = file.Close()
		return nil, fmt.Errorf("create tun device %s: %w", settings.Name, errno)
	}
	actualName := strings.TrimRight(string(req.Name[:]), "\x00")
	device := &linuxDevice{File: file, name: actualName}
	if err := configure(ctx, actualName, settings); err != nil {
		_ = device.Close()
		return nil, err
	}
	return device, nil
}

func configure(ctx context.Context, name string, settings config.TUN) error {
	if _, err := exec.LookPath("ip"); err != nil {
		return errors.New("iproute2 is required to configure the TUN interface")
	}
	commands := [][]string{
		{"link", "set", "dev", name, "mtu", fmt.Sprint(settings.MTU)},
		{"address", "replace", settings.LocalAddress, "peer", settings.PeerAddress + "/32", "dev", name},
		{"link", "set", "dev", name, "up"},
	}
	for _, route := range settings.Routes {
		commands = append(commands, []string{"-4", "route", "replace", route, "via", settings.PeerAddress, "dev", name})
	}
	for _, args := range commands {
		commandCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		output, err := exec.CommandContext(commandCtx, "ip", args...).CombinedOutput()
		cancel()
		if err != nil {
			message := strings.TrimSpace(string(output))
			if message != "" {
				return fmt.Errorf("configure tun %s: ip %s: %w: %s", name, strings.Join(args, " "), err, message)
			}
			return fmt.Errorf("configure tun %s: ip %s: %w", name, strings.Join(args, " "), err)
		}
	}
	return nil
}
