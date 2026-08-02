GO ?= go
VERSION ?= 0.1.0
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
	bash -n scripts/install.sh scripts/install-remote.sh scripts/manager.sh tests/test-manager.sh
	bash tests/test-manager.sh ./bin/v2quantum

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
	cp systemd/v2quantum@.service dist/v2quantum@.service
	chmod 755 dist/v2quantum-manager
	cd dist && sha256sum v2quantum-linux-amd64 v2quantum-linux-arm64 v2quantum-manager v2quantum@.service > SHA256SUMS

clean:
	rm -f bin/v2quantum dist/v2quantum-linux-amd64 dist/v2quantum-linux-arm64 dist/v2quantum-manager dist/v2quantum@.service dist/SHA256SUMS
