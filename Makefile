# Build & install the scale-set listener (ADR-0001 Phase 4 deployment, #108).
#
# The host needs NO Go toolchain: the binary is built INSIDE a golang container
# (ADR-0001) and only the resulting static binary + its sibling shell scripts
# are installed to the host, where systemd (#109) supervises it.
#
#   make build-listener    # containerized static build -> bin/scaleset-listener
#   make install-listener  # install binary + scripts + lib to PREFIX
#
# Reproducible: pinned Go image, CGO disabled (static), trimmed paths.
SHELL := /bin/bash

# Pinned Go image -- the same version actions/scaleset v0.4.0 requires. Override
# for a local toolchain image.
GO_IMAGE ?= golang:1.25.3

# Where the built binary lands on the host (gitignored build output).
BIN_DIR ?= bin
LISTENER_BIN := $(BIN_DIR)/scaleset-listener

# Install layout: a self-contained dir holding the binary and the shell seams
# it shells out to (provision-job.sh / reap.sh, which source ../lib/*). PREFIX
# is the install root; DESTDIR supports staged installs / packaging.
PREFIX ?= /opt/github-runner-listener
DESTDIR ?=

# Static, reproducible containerized build: CGO off so the binary has no libc
# dependency (runs on any host), -trimpath for reproducible paths, building the
# cmd/scaleset-listener entrypoint. -v mounts the module; the host go cache is
# not required.
.PHONY: build-listener
build-listener: ## Build the listener as a static binary inside a golang container
	@mkdir -p $(BIN_DIR)
	docker run --rm \
		-e CGO_ENABLED=0 \
		-v "$$PWD:/repo" -w /repo/listener \
		$(GO_IMAGE) \
		go build -trimpath -ldflags='-s -w' \
		  -o /repo/$(LISTENER_BIN) ./cmd/scaleset-listener
	@echo "built: $(LISTENER_BIN)"

# Install the built binary plus the shell seams it invokes. The listener shells
# out to provision-job.sh / reap.sh, which source ../lib/*.sh -- so the install
# preserves that sibling layout: <prefix>/bin/, <prefix>/listener/, <prefix>/lib/.
.PHONY: install-listener
install-listener: build-listener ## Install the listener + its scripts to PREFIX
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 0755 "$(LISTENER_BIN)" "$(DESTDIR)$(PREFIX)/bin/scaleset-listener"
	install -d "$(DESTDIR)$(PREFIX)/listener"
	install -m 0755 listener/provision-job.sh "$(DESTDIR)$(PREFIX)/listener/provision-job.sh"
	install -m 0755 listener/reap.sh "$(DESTDIR)$(PREFIX)/listener/reap.sh"
	install -d "$(DESTDIR)$(PREFIX)/lib"
	install -m 0644 lib/*.sh "$(DESTDIR)$(PREFIX)/lib/"
	@echo "installed to $(DESTDIR)$(PREFIX)"

.PHONY: clean-listener
clean-listener: ## Remove the built binary
	rm -rf $(BIN_DIR)
