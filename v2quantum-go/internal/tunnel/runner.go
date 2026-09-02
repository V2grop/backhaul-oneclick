package tunnel

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net"
	"sync"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/quantum"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/quantumv2"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/rawip"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/secure"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/tun"
)

type Runtime struct {
	cfg     *config.Config
	logger  *slog.Logger
	stats   *Stats
	pool    *sessionPool
	openTUN tun.OpenFunc
	tunDev  tun.Device
	tunIn   chan []byte
}

func NewRuntime(cfg *config.Config, logger *slog.Logger) *Runtime {
	return &Runtime{
		cfg: cfg, logger: logger, stats: &Stats{}, pool: newSessionPool(),
		openTUN: tun.Open,
	}
}

func (r *Runtime) Snapshot() Snapshot { return r.stats.Snapshot() }

func (r *Runtime) Ready() bool {
	return r.pool.count() > 0
}

func (r *Runtime) Run(ctx context.Context) error {
	if r.cfg.TUN != nil && r.cfg.TUN.Enabled {
		return r.runTUN(ctx)
	}
	return r.runRole(ctx)
}

func (r *Runtime) runRole(ctx context.Context) error {
	if r.cfg.Role == "server" {
		return r.runServer(ctx)
	}
	return r.runClient(ctx)
}

func (r *Runtime) runTUN(ctx context.Context) error {
	device, err := r.openTUN(ctx, *r.cfg.TUN)
	if err != nil {
		return fmt.Errorf("initialize tun: %w", err)
	}
	r.tunDev = device
	r.tunIn = make(chan []byte, 1024)
	r.logger.Info("tun interface ready", "device", device.Name(), "address", r.cfg.TUN.LocalAddress, "peer", r.cfg.TUN.PeerAddress, "mtu", r.cfg.TUN.MTU)

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer device.Close()
	errCh := make(chan error, 3)
	go func() { errCh <- r.runRole(runCtx) }()
	go func() { errCh <- r.readTUN(runCtx) }()
	go func() { errCh <- r.writeTUN(runCtx) }()

	select {
	case <-ctx.Done():
		return nil
	case err := <-errCh:
		if err == nil || IsExpectedShutdown(err) {
			return nil
		}
		return err
	}
}

func (r *Runtime) readTUN(ctx context.Context) error {
	buffer := make([]byte, r.cfg.TUN.MTU+256)
	for {
		n, err := r.tunDev.Read(buffer)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("read tun packet: %w", err)
		}
		if n == 0 {
			continue
		}
		packet := append([]byte(nil), buffer[:n]...)
		for {
			s, err := r.pool.waitPick(ctx)
			if err != nil {
				return nil
			}
			if err := s.sendPacket(packet); err != nil {
				s.close(err)
				continue
			}
			r.stats.tunPacketsToPeer.Add(1)
			r.stats.tunBytesToPeer.Add(int64(len(packet)))
			break
		}
	}
}

func (r *Runtime) writeTUN(ctx context.Context) error {
	for {
		select {
		case packet := <-r.tunIn:
			n, err := r.tunDev.Write(packet)
			if err != nil {
				if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
					return nil
				}
				return fmt.Errorf("write tun packet: %w", err)
			}
			if n != len(packet) {
				return fmt.Errorf("write tun packet: %w (%d of %d bytes)", io.ErrShortWrite, n, len(packet))
			}
			r.stats.tunPacketsFromPeer.Add(1)
			r.stats.tunBytesFromPeer.Add(int64(len(packet)))
		case <-ctx.Done():
			return nil
		}
	}
}

func (r *Runtime) receiveTUNPacket(packet []byte) error {
	if r.tunIn == nil {
		return errors.New("peer sent a tun packet to a non-tun instance")
	}
	if len(packet) < 1 || (packet[0]>>4 != 4 && packet[0]>>4 != 6) {
		return errors.New("peer sent an invalid IP packet")
	}
	if len(packet) > r.cfg.TUN.MTU+256 {
		return fmt.Errorf("peer tun packet exceeds configured MTU: %d", len(packet))
	}
	copyPacket := append([]byte(nil), packet...)
	select {
	case r.tunIn <- copyPacket:
		return nil
	default:
		return errors.New("tun receive queue is full")
	}
}

func (r *Runtime) runServer(ctx context.Context) error {
	listener, err := r.listenCarrier()
	if err != nil {
		return fmt.Errorf("listen carrier: %w", err)
	}
	defer listener.Close()
	r.logger.Info("carrier listening", "address", listener.Addr(), "mode", r.cfg.Carrier.Mode)
	go func() {
		<-ctx.Done()
		_ = listener.Close()
		r.pool.closeAll()
	}()
	go r.acceptCarriers(ctx, listener)

	var wg sync.WaitGroup
	errCh := make(chan error, len(r.cfg.Mappings))
	for _, mapping := range r.cfg.Mappings {
		mapping := mapping
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := r.serveMapping(ctx, mapping); err != nil && ctx.Err() == nil {
				errCh <- err
			}
		}()
	}
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-ctx.Done():
		<-done
		return nil
	case err := <-errCh:
		return err
	}
}

func (r *Runtime) acceptCarriers(ctx context.Context, listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() == nil {
				r.logger.Warn("carrier accept failed", "error", err)
			}
			return
		}
		tuneTCPConn(conn, r.cfg.Keepalive())
		go func(raw net.Conn) {
			secured, err := secure.Server(raw, []byte(r.cfg.Security.PSK))
			if err != nil {
				r.stats.authFailed.Add(1)
				_ = raw.Close()
				r.logger.Warn("carrier authentication rejected", "remote", raw.RemoteAddr(), "error", err)
				return
			}
			var packetHandler func([]byte) error
			if r.cfg.TUN != nil && r.cfg.TUN.Enabled {
				packetHandler = r.receiveTUNPacket
			}
			s := newSession(secured, r.logger, r.stats, nil, false, packetHandler, r.cfg.Carrier.MaxStreamsPerSession, r.cfg.Keepalive(), r.cfg.DialTimeout())
			r.pool.add(s)
			r.logger.Info("carrier connected", "remote", raw.RemoteAddr(), "sessions", r.pool.count())
			s.wait()
			r.pool.remove(s)
			r.logger.Info("carrier disconnected", "remote", raw.RemoteAddr(), "sessions", r.pool.count())
		}(conn)
	}
}

func (r *Runtime) serveMapping(ctx context.Context, mapping config.Mapping) error {
	listener, err := net.Listen("tcp", mapping.Listen)
	if err != nil {
		return fmt.Errorf("listen mapping %s: %w", mapping.Name, err)
	}
	defer listener.Close()
	r.logger.Info("mapping listening", "name", mapping.Name, "address", listener.Addr())
	go func() { <-ctx.Done(); _ = listener.Close() }()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("accept mapping %s: %w", mapping.Name, err)
		}
		tuneTCPConn(conn, r.cfg.Keepalive())
		go r.openUserConnection(ctx, mapping.Name, conn)
	}
}

func (r *Runtime) openUserConnection(ctx context.Context, mapping string, conn net.Conn) {
	openCtx, cancel := context.WithTimeout(ctx, r.cfg.DialTimeout()+3*time.Second)
	defer cancel()
	s, err := r.pool.waitPick(openCtx)
	if err != nil {
		_ = conn.Close()
		r.stats.openFailed.Add(1)
		return
	}
	if err := s.open(openCtx, mapping, conn); err != nil {
		_ = conn.Close()
		r.stats.openFailed.Add(1)
		r.logger.Debug("mapping open failed", "mapping", mapping, "error", err)
	}
}

func (r *Runtime) runClient(ctx context.Context) error {
	targets := make(map[string]string, len(r.cfg.Mappings))
	for _, mapping := range r.cfg.Mappings {
		targets[mapping.Name] = mapping.Target
	}
	var wg sync.WaitGroup
	for i := 0; i < r.cfg.Carrier.Pool; i++ {
		wg.Add(1)
		go func(slot int) {
			defer wg.Done()
			r.clientSlot(ctx, slot, targets)
		}(i)
	}
	<-ctx.Done()
	r.pool.closeAll()
	wg.Wait()
	return nil
}

func (r *Runtime) clientSlot(ctx context.Context, slot int, targets map[string]string) {
	backoff := r.cfg.ReconnectMin()
	for ctx.Err() == nil {
		raw, err := r.dialCarrier(ctx)
		if err != nil {
			r.stats.reconnects.Add(1)
			r.sleepBackoff(ctx, backoff)
			backoff = minDuration(backoff*2, r.cfg.ReconnectMax())
			continue
		}
		secured, err := secure.Client(raw, []byte(r.cfg.Security.PSK))
		if err != nil {
			r.stats.authFailed.Add(1)
			_ = raw.Close()
			r.sleepBackoff(ctx, backoff)
			backoff = minDuration(backoff*2, r.cfg.ReconnectMax())
			continue
		}
		backoff = r.cfg.ReconnectMin()
		var packetHandler func([]byte) error
		if r.cfg.TUN != nil && r.cfg.TUN.Enabled {
			packetHandler = r.receiveTUNPacket
		}
		s := newSession(secured, r.logger, r.stats, targets, true, packetHandler, r.cfg.Carrier.MaxStreamsPerSession, r.cfg.Keepalive(), r.cfg.DialTimeout())
		r.pool.add(s)
		r.logger.Info("carrier connected", "slot", slot, "server", r.cfg.Carrier.Server)
		select {
		case <-ctx.Done():
			s.close(nil)
		case <-s.closed:
		}
		r.pool.remove(s)
		r.stats.reconnects.Add(1)
	}
}

func (r *Runtime) listenCarrier() (net.Listener, error) {
	switch r.cfg.Carrier.Mode {
	case "tcp":
		return net.Listen("tcp", r.cfg.Carrier.Listen)
	case "quantum_udp":
		return quantumv2.Listen(r.cfg.Carrier.Listen, 4*r.cfg.Keepalive(), r.quantumSettings())
	case "raw_icmp":
		packetConn, err := rawip.ListenPacket(r.cfg.Carrier.Raw, true)
		if err != nil {
			return nil, err
		}
		return quantum.ListenPacket(packetConn, 4*r.cfg.Keepalive())
	default:
		return nil, fmt.Errorf("unsupported carrier mode %q", r.cfg.Carrier.Mode)
	}
}

func (r *Runtime) dialCarrier(ctx context.Context) (net.Conn, error) {
	switch r.cfg.Carrier.Mode {
	case "tcp":
		dialer := net.Dialer{Timeout: r.cfg.DialTimeout(), KeepAlive: r.cfg.Keepalive()}
		conn, err := dialer.DialContext(ctx, "tcp", r.cfg.Carrier.Server)
		if err == nil {
			tuneTCPConn(conn, r.cfg.Keepalive())
		}
		return conn, err
	case "quantum_udp":
		return quantumv2.DialContext(ctx, r.cfg.Carrier.Server, r.cfg.DialTimeout(), 4*r.cfg.Keepalive(), r.quantumSettings())
	case "raw_icmp":
		packetConn, err := rawip.ListenPacket(r.cfg.Carrier.Raw, false)
		if err != nil {
			return nil, err
		}
		return quantum.DialPacket(ctx, packetConn, rawip.ExpectedPeerAddr(r.cfg.Carrier.Raw), r.cfg.DialTimeout(), 4*r.cfg.Keepalive())
	default:
		return nil, fmt.Errorf("unsupported carrier mode %q", r.cfg.Carrier.Mode)
	}
}

func (r *Runtime) quantumSettings() quantumv2.Settings {
	q := r.cfg.Carrier.Quantum
	return quantumv2.Settings{
		Profile:           q.Profile,
		AutoTune:          r.cfg.QuantumAutoTune(),
		MaxDatagramSize:   q.MaxDatagramSize,
		SendWindow:        q.SendWindow,
		ReceiveWindow:     q.ReceiveWindow,
		InitialRTO:        time.Duration(q.InitialRTOMillis) * time.Millisecond,
		MinRTO:            time.Duration(q.MinRTOMillis) * time.Millisecond,
		MaxRTO:            time.Duration(q.MaxRTOMillis) * time.Millisecond,
		FastResend:        q.FastResend,
		FECDataShards:     q.FECDataShards,
		FECParityShards:   q.FECParityShards,
		SocketBufferBytes: q.SocketBufferBytes,
		MaxRetries:        q.MaxRetries,
		Observer:          quantumObserver{stats: r.stats},
	}
}

func tuneTCPConn(conn net.Conn, keepalive time.Duration) {
	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tcp.SetNoDelay(true)
	_ = tcp.SetKeepAlive(true)
	_ = tcp.SetKeepAlivePeriod(keepalive)
}

func (r *Runtime) sleepBackoff(ctx context.Context, base time.Duration) {
	jitter := time.Duration(rand.Int64N(max(int64(base/3), 1)))
	timer := time.NewTimer(base + jitter)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-timer.C:
	}
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

func IsExpectedShutdown(err error) bool {
	return err == nil || errors.Is(err, context.Canceled) || errors.Is(err, net.ErrClosed)
}
