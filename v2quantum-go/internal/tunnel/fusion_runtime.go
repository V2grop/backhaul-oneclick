package tunnel

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/config"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/protocol"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/quantumv2"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/secure"
	"github.com/V2grop/backhaul-oneclick/v2quantum-go/internal/wsstream"
)

func (r *Runtime) runFusion(ctx context.Context) error {
	targets := make(map[string]string, len(r.cfg.Mappings))
	if r.cfg.Role == "client" {
		for _, mapping := range r.cfg.Mappings {
			targets[mapping.Name] = mapping.Target
		}
	}
	fusionCfg := r.cfg.Carrier.Fusion
	fusion := newFusionHub(
		ctx, r.logger, r.stats, r.cfg.Role, targets,
		r.cfg.Keepalive(), r.cfg.DialTimeout(),
		time.Duration(fusionCfg.UnavailableTimeoutSecs)*time.Second,
		time.Duration(fusionCfg.RecoveryHoldSeconds)*time.Second,
		fusionCfg.ReplayBufferBytes,
	)
	r.fusion.Store(fusion)
	defer func() {
		fusion.closeAll()
	}()
	if r.cfg.Role == "server" {
		return r.runFusionServer(ctx)
	}
	return r.runFusionClient(ctx)
}

func (r *Runtime) runFusionServer(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	type pathListener struct {
		path     config.FusionPath
		listener net.Listener
	}
	listeners := make([]pathListener, 0, len(r.cfg.Carrier.Fusion.Paths))
	for _, path := range r.cfg.Carrier.Fusion.Paths {
		listener, err := r.listenFusionPath(path)
		if err != nil {
			for _, item := range listeners {
				_ = item.listener.Close()
			}
			return fmt.Errorf("listen FusionMux path %s: %w", path.Name, err)
		}
		listeners = append(listeners, pathListener{path: path, listener: listener})
		r.logger.Info("FusionMux path listening", "path", path.Name, "mode", path.Mode, "address", listener.Addr(), "priority", path.Priority)
	}

	errCh := make(chan error, len(listeners)+len(r.cfg.Mappings))
	var wg sync.WaitGroup
	for _, item := range listeners {
		item := item
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := r.acceptFusionPath(runCtx, item.path, item.listener); err != nil && runCtx.Err() == nil {
				errCh <- err
			}
		}()
	}
	for _, mapping := range r.cfg.Mappings {
		mapping := mapping
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := r.serveFusionMapping(runCtx, mapping); err != nil && runCtx.Err() == nil {
				errCh <- err
			}
		}()
	}
	go func() {
		<-runCtx.Done()
		for _, item := range listeners {
			_ = item.listener.Close()
		}
		r.fusion.Load().closeAll()
	}()

	select {
	case <-ctx.Done():
		cancel()
		wg.Wait()
		return nil
	case err := <-errCh:
		cancel()
		wg.Wait()
		return err
	}
}

func (r *Runtime) runFusionClient(ctx context.Context) error {
	var wg sync.WaitGroup
	for _, path := range r.cfg.Carrier.Fusion.Paths {
		for slot := 0; slot < path.Pool; slot++ {
			path, slot := path, slot
			wg.Add(1)
			go func() {
				defer wg.Done()
				r.fusionClientSlot(ctx, path, slot)
			}()
		}
	}
	<-ctx.Done()
	r.fusion.Load().closeAll()
	wg.Wait()
	return nil
}

func (r *Runtime) listenFusionPath(path config.FusionPath) (net.Listener, error) {
	switch path.Mode {
	case "tcp":
		return net.Listen("tcp", path.Listen)
	case "quantum_udp":
		return quantumv2.Listen(path.Listen, 4*r.cfg.Keepalive(), r.quantumSettingsFor(path.Quantum))
	case "websocket":
		return wsstream.Listen(path.Listen, wsstream.ServerSettings{
			Path: path.WebSocket.Path, TLSCertFile: path.WebSocket.TLSCertFile,
			TLSKeyFile: path.WebSocket.TLSKeyFile, HandshakeTimeout: r.cfg.DialTimeout(),
		})
	default:
		return nil, fmt.Errorf("unsupported FusionMux path mode %q", path.Mode)
	}
}

func (r *Runtime) dialFusionPath(ctx context.Context, path config.FusionPath) (net.Conn, error) {
	switch path.Mode {
	case "tcp":
		dialer := net.Dialer{Timeout: r.cfg.DialTimeout(), KeepAlive: r.cfg.Keepalive()}
		conn, err := dialer.DialContext(ctx, "tcp", path.Server)
		if err == nil {
			tuneTCPConn(conn, r.cfg.Keepalive())
		}
		return conn, err
	case "quantum_udp":
		return quantumv2.DialContext(ctx, path.Server, r.cfg.DialTimeout(), 4*r.cfg.Keepalive(), r.quantumSettingsFor(path.Quantum))
	case "websocket":
		return wsstream.DialContext(ctx, path.Server, wsstream.ClientSettings{
			Path: path.WebSocket.Path, Host: path.WebSocket.Host,
			TLS: path.WebSocket.TLS, ServerName: path.WebSocket.ServerName,
			InsecureSkipVerify: path.WebSocket.InsecureSkipVerify,
			HandshakeTimeout:   r.cfg.DialTimeout(),
		})
	default:
		return nil, fmt.Errorf("unsupported FusionMux path mode %q", path.Mode)
	}
}

func (r *Runtime) acceptFusionPath(ctx context.Context, path config.FusionPath, listener net.Listener) error {
	for {
		raw, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("accept path %s: %w", path.Name, err)
		}
		go r.acceptFusionConn(ctx, path, raw)
	}
}

func (r *Runtime) acceptFusionConn(ctx context.Context, path config.FusionPath, raw net.Conn) {
	tuneTCPConn(raw, r.cfg.Keepalive())
	secured, err := secure.Server(raw, []byte(r.cfg.Security.PSK))
	if err != nil {
		r.stats.authFailed.Add(1)
		_ = raw.Close()
		return
	}
	_ = secured.SetDeadline(time.Now().Add(r.cfg.DialTimeout()))
	hello, err := secured.ReadFrame()
	if err != nil || hello.Type != protocol.FusionHello || string(hello.Payload) != path.Name {
		r.stats.authFailed.Add(1)
		_ = secured.Close()
		return
	}
	if err := secured.WriteFrame(protocol.Frame{Type: protocol.FusionHelloOK}); err != nil {
		_ = secured.Close()
		return
	}
	_ = secured.SetDeadline(time.Time{})
	link := r.fusion.Load().addLink(secured, path.Name, path.Mode, path.Priority)
	if link == nil {
		return
	}
	select {
	case <-ctx.Done():
		link.shutdown(nil)
	case <-link.closed:
	}
}

func (r *Runtime) fusionClientSlot(ctx context.Context, path config.FusionPath, slot int) {
	backoff := r.cfg.ReconnectMin()
	for ctx.Err() == nil {
		raw, err := r.dialFusionPath(ctx, path)
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
		_ = secured.SetDeadline(time.Now().Add(r.cfg.DialTimeout()))
		if err := secured.WriteFrame(protocol.Frame{Type: protocol.FusionHello, Payload: []byte(path.Name)}); err != nil {
			_ = secured.Close()
			r.sleepBackoff(ctx, backoff)
			continue
		}
		ack, err := secured.ReadFrame()
		if err != nil || ack.Type != protocol.FusionHelloOK {
			_ = secured.Close()
			r.sleepBackoff(ctx, backoff)
			continue
		}
		_ = secured.SetDeadline(time.Time{})
		backoff = r.cfg.ReconnectMin()
		link := r.fusion.Load().addLink(secured, path.Name, path.Mode, path.Priority)
		if link == nil {
			return
		}
		r.logger.Info("FusionMux client slot ready", "path", path.Name, "mode", path.Mode, "slot", slot, "server", path.Server)
		select {
		case <-ctx.Done():
			link.shutdown(nil)
			return
		case <-link.closed:
			r.stats.reconnects.Add(1)
		}
	}
}

func (r *Runtime) serveFusionMapping(ctx context.Context, mapping config.Mapping) error {
	listener, err := net.Listen("tcp", mapping.Listen)
	if err != nil {
		return fmt.Errorf("listen FusionMux mapping %s: %w", mapping.Name, err)
	}
	defer listener.Close()
	r.logger.Info("FusionMux mapping listening", "name", mapping.Name, "address", listener.Addr())
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		tuneTCPConn(conn, r.cfg.Keepalive())
		go r.openFusionUser(ctx, mapping.Name, conn)
	}
}

func (r *Runtime) openFusionUser(ctx context.Context, mapping string, conn net.Conn) {
	fusion := r.fusion.Load()
	id := fusion.nextFlowID()
	flow := newFusionFlow(id, fusion, mapping, conn, true)
	if !fusion.addFlow(flow) {
		_ = conn.Close()
		r.stats.openFailed.Add(1)
		return
	}
	openCtx, cancel := context.WithTimeout(ctx, r.cfg.DialTimeout()+time.Duration(r.cfg.Carrier.Fusion.UnavailableTimeoutSecs)*time.Second)
	defer cancel()
	if err := flow.open(openCtx); err != nil {
		r.stats.openFailed.Add(1)
		flow.terminate(false, err)
	}
}

func (r *Runtime) quantumSettingsFor(q config.Quantum) quantumv2.Settings {
	autoTune := q.AutoTune == nil || *q.AutoTune
	return quantumv2.Settings{
		Profile: q.Profile, AutoTune: autoTune,
		MaxDatagramSize: q.MaxDatagramSize, SendWindow: q.SendWindow,
		ReceiveWindow: q.ReceiveWindow,
		InitialRTO:    time.Duration(q.InitialRTOMillis) * time.Millisecond,
		MinRTO:        time.Duration(q.MinRTOMillis) * time.Millisecond,
		MaxRTO:        time.Duration(q.MaxRTOMillis) * time.Millisecond,
		FastResend:    q.FastResend, FECDataShards: q.FECDataShards,
		FECParityShards: q.FECParityShards, SocketBufferBytes: q.SocketBufferBytes,
		MaxRetries: q.MaxRetries, Observer: quantumObserver{stats: r.stats},
	}
}
