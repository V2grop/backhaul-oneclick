package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHealthCheck(t *testing.T) {
	t.Setenv("V2QUANTUM_PSK", strings.Repeat("k", 48))
	for _, tc := range []struct {
		name    string
		status  int
		wantErr bool
	}{
		{name: "ready", status: http.StatusOK},
		{name: "not-ready", status: http.StatusServiceUnavailable, wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/healthz" {
					t.Fatalf("unexpected health path %q", r.URL.Path)
				}
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(`{"ready":true}` + "\n"))
			}))
			defer server.Close()
			parsed, err := url.Parse(server.URL)
			if err != nil {
				t.Fatal(err)
			}
			configPath := filepath.Join(t.TempDir(), "config.json")
			body := fmt.Sprintf(`{
  "version": 1,
  "role": "server",
  "node_name": "test",
  "carrier": {"mode":"tcp","listen":"127.0.0.1:18890","pool":1},
  "security": {"psk_env":"V2QUANTUM_PSK"},
  "mappings": [{"name":"map-1","protocol":"tcp","listen":"127.0.0.1:12445"}],
  "health": {"listen":%q,"allow_public_listen":false},
  "logging": {"level":"error","json":false}
}`, parsed.Host)
			if err := os.WriteFile(configPath, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			err = healthCheck([]string{"-config", configPath, "-timeout", "2s"})
			if (err != nil) != tc.wantErr {
				t.Fatalf("healthCheck() error = %v, wantErr %v", err, tc.wantErr)
			}
		})
	}
}
