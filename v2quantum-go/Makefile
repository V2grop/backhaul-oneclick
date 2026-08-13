GO ?= go
VERSION ?= 0.3.0
BINARY := bin/v2quantum
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: all build test shell-test race vet check release clean

all: check build

build:
	mkdir -p bin
	$(GO) build -buildvcs=false -trimpath -ldflags '$(LDFLAGS)' -o $(BINARY) ./cmd/v2quantum

test:
	$(GO) test ./...

shell-test: build
	bash -n scripts/install.sh scripts/install-remote.sh scripts/oneclick.sh scripts/manager.sh scripts/watchdog.sh scripts/portmap.sh tests/test-install.sh tests/test-manager.sh tests/test-portmap.sh tests/test-v2tun-bootstrap.sh tests/test-watchdog.sh tests/test-universal.sh ../install-v2tun.sh ../v2quantum-oneclick.sh ../oneclick-universal.sh ../oneclick-v3-en.sh ../oneclick-xwsmux-max.sh ../tests/test-backhaul-wrapper.sh ../tests/test-xwsmux-max.sh
	bash tests/test-install.sh ./bin/v2quantum
	bash tests/test-manager.sh ./bin/v2quantum
	bash tests/test-portmap.sh
	bash tests/test-v2tun-bootstrap.sh
	bash tests/test-watchdog.sh
	bash tests/test-universal.sh
	bash ../tests/test-xwsmux-max.sh
	bash ../tests/test-backhaul-wrapper.sh

race:
	$(GO) test -race ./...

vet:
	$(GO) vet ./...

check: vet test shell-test

release:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build -buildvcs=false -trimpath -ldflags '$(LDFLAGS)' -o dist/v2quantum-linux-amd64 ./cmd/v2quantum
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build -buildvcs=false -trimpath -ldflags '$(LDFLAGS)' -o dist/v2quantum-linux-arm64 ./cmd/v2quantum
	cp scripts/manager.sh dist/v2quantum-manager
	cp scripts/oneclick.sh dist/v2quantum-installer
	cp scripts/watchdog.sh dist/v2quantum-watchdog
	cp scripts/portmap.sh dist/v2quantum-portmap
	cp systemd/v2quantum@.service dist/v2quantum@.service
	cp systemd/v2quantum-portmap@.service dist/v2quantum-portmap@.service
	cp systemd/v2quantum-watchdog@.service dist/v2quantum-watchdog@.service
	cp systemd/v2quantum-watchdog@.timer dist/v2quantum-watchdog@.timer
	chmod 755 dist/v2quantum-manager dist/v2quantum-installer dist/v2quantum-watchdog dist/v2quantum-portmap
	cd dist && sha256sum v2quantum-linux-amd64 v2quantum-linux-arm64 v2quantum-manager v2quantum-installer v2quantum-watchdog v2quantum-portmap v2quantum@.service v2quantum-portmap@.service v2quantum-watchdog@.service v2quantum-watchdog@.timer > SHA256SUMS

clean:
	rm -f bin/v2quantum dist/v2quantum-linux-amd64 dist/v2quantum-linux-arm64 dist/v2quantum-manager dist/v2quantum-installer dist/v2quantum-watchdog dist/v2quantum-portmap dist/v2quantum@.service dist/v2quantum-portmap@.service dist/v2quantum-watchdog@.service dist/v2quantum-watchdog@.timer dist/SHA256SUMS
