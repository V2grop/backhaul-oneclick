package wsstream

import (
	"bufio"
	"context"
	"crypto/sha1" // #nosec G505 -- mandated by RFC 6455 for Sec-WebSocket-Accept.
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type ClientSettings struct {
	Path               string
	Host               string
	ServerName         string
	TLS                bool
	InsecureSkipVerify bool
	HandshakeTimeout   time.Duration
}

func DialContext(ctx context.Context, address string, settings ClientSettings) (net.Conn, error) {
	settings.Path = normalizePath(settings.Path)
	if settings.HandshakeTimeout <= 0 {
		settings.HandshakeTimeout = 10 * time.Second
	}
	hostHeader := strings.TrimSpace(settings.Host)
	if hostHeader == "" {
		hostHeader = address
	}
	if strings.ContainsAny(hostHeader, "\r\n") {
		return nil, errors.New("websocket: host contains a newline")
	}

	dialer := net.Dialer{Timeout: settings.HandshakeTimeout, KeepAlive: 15 * time.Second}
	raw, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, err
	}
	fail := func(err error) (net.Conn, error) {
		_ = raw.Close()
		return nil, err
	}

	if settings.TLS {
		serverName := strings.TrimSpace(settings.ServerName)
		if serverName == "" {
			serverName = hostOnly(hostHeader)
		}
		if serverName == "" {
			serverName = hostOnly(address)
		}
		tlsConn := tls.Client(raw, &tls.Config{
			MinVersion:         tls.VersionTLS12,
			ServerName:         serverName,
			InsecureSkipVerify: settings.InsecureSkipVerify, // Explicit operator option for private origins.
			NextProtos:         []string{"http/1.1"},
		})
		handshakeCtx, cancel := context.WithTimeout(ctx, settings.HandshakeTimeout)
		defer cancel()
		if err := tlsConn.HandshakeContext(handshakeCtx); err != nil {
			return fail(fmt.Errorf("websocket TLS handshake: %w", err))
		}
		raw = tlsConn
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = raw.SetDeadline(deadline)
	} else {
		_ = raw.SetDeadline(time.Now().Add(settings.HandshakeTimeout))
	}

	keyBytes := make([]byte, 16)
	if _, err := randRead(keyBytes); err != nil {
		return fail(err)
	}
	key := base64.StdEncoding.EncodeToString(keyBytes)
	req := &http.Request{
		Method: "GET",
		URL:    &url.URL{Path: settings.Path},
		Host:   hostHeader,
		Header: http.Header{
			"Upgrade":               []string{"websocket"},
			"Connection":            []string{"Upgrade"},
			"Sec-Websocket-Key":     []string{key},
			"Sec-Websocket-Version": []string{"13"},
			"User-Agent":            []string{"Mozilla/5.0"},
		},
	}
	if err := req.Write(raw); err != nil {
		return fail(fmt.Errorf("websocket request: %w", err))
	}
	reader := bufio.NewReader(raw)
	resp, err := http.ReadResponse(reader, req)
	if err != nil {
		return fail(fmt.Errorf("websocket response: %w", err))
	}
	if resp.StatusCode != http.StatusSwitchingProtocols ||
		!headerHasToken(resp.Header, "Upgrade", "websocket") ||
		!headerHasToken(resp.Header, "Connection", "upgrade") {
		_ = resp.Body.Close()
		return fail(fmt.Errorf("websocket upgrade rejected: %s", resp.Status))
	}
	if !constantStringEqual(resp.Header.Get("Sec-WebSocket-Accept"), websocketAccept(key)) {
		_ = resp.Body.Close()
		return fail(errors.New("websocket: invalid Sec-WebSocket-Accept"))
	}
	_ = raw.SetDeadline(time.Time{})
	return newConn(raw, reader, true), nil
}

func websocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + websocketGUID)) // #nosec G401 -- RFC 6455 compatibility, not password hashing.
	return base64.StdEncoding.EncodeToString(sum[:])
}

func normalizePath(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return "/v2q"
	}
	if !strings.HasPrefix(path, "/") {
		return "/" + path
	}
	return path
}

func hostOnly(address string) string {
	host, _, err := net.SplitHostPort(address)
	if err == nil {
		return strings.Trim(host, "[]")
	}
	return strings.Trim(address, "[]")
}

func headerHasToken(header http.Header, name, token string) bool {
	for _, value := range header.Values(name) {
		for _, part := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(part), token) {
				return true
			}
		}
	}
	return false
}

func constantStringEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
