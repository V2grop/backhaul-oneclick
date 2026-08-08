package wsstream

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

type ServerSettings struct {
	Path             string
	TLSCertFile      string
	TLSKeyFile       string
	HandshakeTimeout time.Duration
}

type acceptResult struct {
	conn net.Conn
	err  error
}

type Listener struct {
	base     net.Listener
	settings ServerSettings
	tls      *tls.Config
	accepted chan acceptResult
	done     chan struct{}
	close    sync.Once
	errMu    sync.Mutex
	err      error
}

func Listen(address string, settings ServerSettings) (*Listener, error) {
	settings.Path = normalizePath(settings.Path)
	if settings.HandshakeTimeout <= 0 {
		settings.HandshakeTimeout = 10 * time.Second
	}
	if (settings.TLSCertFile == "") != (settings.TLSKeyFile == "") {
		return nil, errors.New("websocket: TLS certificate and key must be set together")
	}
	var tlsConfig *tls.Config
	if settings.TLSCertFile != "" {
		pair, err := tls.LoadX509KeyPair(settings.TLSCertFile, settings.TLSKeyFile)
		if err != nil {
			return nil, fmt.Errorf("websocket TLS certificate: %w", err)
		}
		tlsConfig = &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}, NextProtos: []string{"http/1.1"}}
	}
	base, err := net.Listen("tcp", address)
	if err != nil {
		return nil, err
	}
	l := &Listener{
		base: base, settings: settings, tls: tlsConfig,
		accepted: make(chan acceptResult, 128), done: make(chan struct{}),
	}
	go l.acceptLoop()
	return l, nil
}

func (l *Listener) Accept() (net.Conn, error) {
	select {
	case result := <-l.accepted:
		return result.conn, result.err
	case <-l.done:
		l.errMu.Lock()
		err := l.err
		l.errMu.Unlock()
		if err == nil {
			err = net.ErrClosed
		}
		return nil, err
	}
}

func (l *Listener) Close() error {
	var err error
	l.close.Do(func() {
		err = l.base.Close()
		close(l.done)
	})
	return err
}

func (l *Listener) Addr() net.Addr { return l.base.Addr() }

func (l *Listener) acceptLoop() {
	for {
		raw, err := l.base.Accept()
		if err != nil {
			l.errMu.Lock()
			if !errors.Is(err, net.ErrClosed) {
				l.err = err
			}
			l.errMu.Unlock()
			l.close.Do(func() { close(l.done) })
			return
		}
		go l.upgrade(raw)
	}
}

func (l *Listener) upgrade(raw net.Conn) {
	fail := func(status int) {
		_, _ = fmt.Fprintf(raw, "HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", status, http.StatusText(status))
		_ = raw.Close()
	}
	_ = raw.SetDeadline(time.Now().Add(l.settings.HandshakeTimeout))
	if l.tls != nil {
		tlsConn := tls.Server(raw, l.tls)
		ctx, cancel := context.WithTimeout(context.Background(), l.settings.HandshakeTimeout)
		defer cancel()
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			_ = raw.Close()
			return
		}
		raw = tlsConn
	}
	reader := bufio.NewReader(raw)
	req, err := http.ReadRequest(reader)
	if err != nil {
		fail(http.StatusBadRequest)
		return
	}
	defer req.Body.Close()
	if req.Method != http.MethodGet || req.URL.Path != l.settings.Path {
		fail(http.StatusNotFound)
		return
	}
	if !headerHasToken(req.Header, "Upgrade", "websocket") ||
		!headerHasToken(req.Header, "Connection", "upgrade") ||
		req.Header.Get("Sec-WebSocket-Version") != "13" {
		fail(http.StatusBadRequest)
		return
	}
	key := strings.TrimSpace(req.Header.Get("Sec-WebSocket-Key"))
	decoded, err := base64.StdEncoding.DecodeString(key)
	if err != nil || len(decoded) != 16 {
		fail(http.StatusBadRequest)
		return
	}
	response := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + websocketAccept(key) + "\r\n\r\n"
	if err := writeAll(raw, []byte(response)); err != nil {
		_ = raw.Close()
		return
	}
	_ = raw.SetDeadline(time.Time{})
	conn := newConn(raw, reader, false)
	select {
	case l.accepted <- acceptResult{conn: conn}:
	case <-l.done:
		_ = conn.Close()
	}
}

var _ net.Listener = (*Listener)(nil)
