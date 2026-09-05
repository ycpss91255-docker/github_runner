# github_runner CI self-test entry (just). Ported verbatim from the old
# Makefile.ci (#78): `just lint|test|check|coverage|pull` (+ lint-host /
# test-host), same prebuilt test-tools + kcov pattern. github_runner is a
# flat repo (no `.base/` subtree, no template container wrapper), so this
# single root `justfile` is the whole self-test entry -- the flat analogue
# of ycpss91255-docker/base's layered `test` namespace, kept aligned
# recipe-for-recipe.

# Aligns with ycpss91255-docker/base: same prebuilt test-tools image
# (alpine + shellcheck + bats + hadolint + bats-{support,assert,mock}).
# env_var_or_default keeps a caller's TEST_TOOLS_IMAGE=... override winning
# (the old Makefile `?=`), e.g. for local rebuild flows.
TEST_TOOLS_IMAGE := env_var_or_default('TEST_TOOLS_IMAGE', 'ghcr.io/ycpss91255-docker/test-tools:latest')

# Coverage uses kcov's own image (Debian-based, ships kcov). bats is
# apt-installed at runtime inside the container -- a one-time ~15s tax per
# run; acceptable given coverage is a slow / release-time signal anyway.
# Override with COVERAGE_IMAGE=... if you want to pin a tag.
COVERAGE_IMAGE := env_var_or_default('COVERAGE_IMAGE', 'kcov/kcov:latest')

SCRIPTS := 'script/install-deps.sh script/init.sh script/add-runner.sh script/remove-runner.sh script/status.sh script/update.sh script/uninstall.sh script/cleanup.sh script/schedule-cleanup.sh script/configure.sh script/set-labels.sh lib/common.sh lib/runner-layout.sh lib/runner-service.sh lib/runner-release.sh lib/runner-config.sh lib/runner-container.sh lib/runner-build.sh lib/runner-reaper.sh lib/runner-history.sh script/history.sh listener/provision-job.sh listener/reap.sh listener/host-probe.sh images/build-runner-image.sh script/lint-adr.sh'

# Self-built runner-image Dockerfiles (#120/#121), hadolint-checked. The
# test-tools image ships hadolint, so this needs no extra dependency.
DOCKERFILES := 'images/runner-base.Dockerfile images/runner-gpu.Dockerfile'

# ShellCheck / hadolint / bats all run inside the test-tools container.
_docker_run := 'docker run --rm -v "$PWD:/source" -w /source ' + TEST_TOOLS_IMAGE

# Coverage container needs seccomp=unconfined for kcov's ptrace, and
# writable /source so coverage/ output lands on the host.
_kcov_run := 'docker run --rm --security-opt seccomp=unconfined -v "$PWD:/source" -w /source ' + COVERAGE_IMAGE

# Show available recipes.
default:
    @just --list

# Pull both test-tools and coverage images.
pull:
    docker pull {{TEST_TOOLS_IMAGE}}
    docker pull {{COVERAGE_IMAGE}}

# ADR structure lint (doc/adr/): required sections, the Status vocabulary, and
# the `> Serves:` invariant back-pointer. Pure bash + grep, so unlike shellcheck
# / hadolint / bats it needs no test-tools container -- it runs on the host and
# is therefore also the cheapest gate to fail fast on.
lint-adr:
    bash script/lint-adr.sh

# ShellCheck + hadolint inside test-tools container, after the ADR structure
# lint (a dependency, so `just lint` alone covers every lint the gate runs).
lint: lint-adr
    {{_docker_run}} shellcheck -x {{SCRIPTS}}
    {{_docker_run}} hadolint {{DOCKERFILES}}

# Bats smoke tests inside test-tools container.
test:
    {{_docker_run}} bats test/smoke/

# lint + test (no coverage).
check: lint test

# Bats with kcov coverage -> ./coverage/ (slow; CI / release).
coverage:
    rm -rf coverage
    {{_kcov_run}} bash -c 'apt-get update -qq && apt-get install -qq -y bats >/dev/null && kcov --include-path=. /source/coverage /usr/bin/bats test/smoke/'
    @echo "coverage report: ./coverage/index.html"

# ShellCheck on host (requires shellcheck installed locally), plus the ADR
# structure lint, so the host path covers the same lints as the container one.
lint-host: lint-adr
    shellcheck -x {{SCRIPTS}}

# Bats on host (requires bats installed locally).
test-host:
    bats test/smoke/

# --- scale-set listener build / install (ADR-0001 Phase 4 deployment, #108) ---
# The host needs NO Go toolchain: the binary is built INSIDE a golang container
# and only the resulting static binary + its sibling shell scripts are installed
# to the host, where systemd (#109) supervises it.

# Pinned Go image -- the same version actions/scaleset v0.4.0 requires. Override
# via env or `just GO_IMAGE=... build-listener` for a local toolchain image.
GO_IMAGE := env_var_or_default('GO_IMAGE', 'golang:1.25.3')

# Where the built binary lands on the host (gitignored build output).
BIN_DIR := env_var_or_default('BIN_DIR', 'bin')
LISTENER_BIN := BIN_DIR / 'scaleset-listener'

# Install layout: a self-contained dir holding the binary and the shell seams it
# shells out to (provision-job.sh / reap.sh, which source ../lib/*). PREFIX is
# the install root; DESTDIR supports staged installs / packaging.
PREFIX := env_var_or_default('PREFIX', '/opt/github-runner-listener')
DESTDIR := env_var_or_default('DESTDIR', '')

# Static, reproducible containerized build: CGO off so the binary has no libc
# dependency (runs on any host), -trimpath for reproducible paths, building the
# cmd/scaleset-listener entrypoint. -v mounts the module; the host go cache is
# not required.
#
# Build the listener as a static binary inside a golang container.
# -buildvcs=false: the container runs as root over the host-owned bind mount, so
# git refuses the repo as "dubious ownership" and VCS stamping errors out (exit
# 128) -- the binary needs no embedded VCS info, so skip the stamp to keep the
# build robust regardless of the host checkout's ownership.
build-listener:
    @mkdir -p {{BIN_DIR}}
    docker run --rm -e CGO_ENABLED=0 -v "$PWD:/repo" -w /repo/listener {{GO_IMAGE}} go build -trimpath -buildvcs=false -ldflags='-s -w' -o /repo/{{LISTENER_BIN}} ./cmd/scaleset-listener
    @echo "built: {{LISTENER_BIN}}"

# The listener shells out to provision-job.sh / reap.sh, which source
# ../lib/*.sh -- so the install preserves that sibling layout:
# <prefix>/bin/, <prefix>/listener/, <prefix>/lib/.
#
# Install the listener + its scripts to PREFIX.
install-listener: build-listener
    install -d "{{DESTDIR}}{{PREFIX}}/bin"
    install -m 0755 "{{LISTENER_BIN}}" "{{DESTDIR}}{{PREFIX}}/bin/scaleset-listener"
    install -d "{{DESTDIR}}{{PREFIX}}/listener"
    install -m 0755 listener/provision-job.sh "{{DESTDIR}}{{PREFIX}}/listener/provision-job.sh"
    install -m 0755 listener/reap.sh "{{DESTDIR}}{{PREFIX}}/listener/reap.sh"
    install -m 0755 listener/host-probe.sh "{{DESTDIR}}{{PREFIX}}/listener/host-probe.sh"
    install -d "{{DESTDIR}}{{PREFIX}}/lib"
    install -m 0644 lib/*.sh "{{DESTDIR}}{{PREFIX}}/lib/"
    @echo "installed to {{DESTDIR}}{{PREFIX}}"

# Remove the built binary.
clean-listener:
    rm -rf {{BIN_DIR}}
