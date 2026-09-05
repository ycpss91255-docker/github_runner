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

# Coverage uses kcov's own image (Debian-based, ships kcov but no bats).
# bats used to be apt-installed at runtime inside the container, which made
# every coverage run depend on the Debian archive being reachable and on
# whatever bats version it carried that day. It is now a pinned,
# sha256-verified bats-core release cached on the host by
# `script/fetch-bats.sh` and mounted into the container -- see the `coverage`
# recipe below. Override with COVERAGE_IMAGE=... if you want to pin a tag.
COVERAGE_IMAGE := env_var_or_default('COVERAGE_IMAGE', 'kcov/kcov:latest')

SCRIPTS := 'script/install-deps.sh script/init.sh script/add-runner.sh script/remove-runner.sh script/status.sh script/update.sh script/uninstall.sh script/cleanup.sh script/schedule-cleanup.sh script/configure.sh script/set-labels.sh lib/common.sh lib/runner-layout.sh lib/runner-service.sh lib/runner-release.sh lib/runner-config.sh lib/runner-container.sh lib/runner-build.sh lib/runner-reaper.sh lib/runner-history.sh script/history.sh listener/provision-job.sh listener/reap.sh listener/host-probe.sh images/build-runner-image.sh script/lint-adr.sh script/fetch-bats.sh script/coverage-gate.sh script/lint-changelog.sh script/lint-readme-sync.sh script/lint-doc-citations.sh script/deploy-listener.sh script/teardown-listener.sh lib/listener-deploy.sh'

# Self-built runner-image Dockerfiles (#120/#121), hadolint-checked. The
# test-tools image ships hadolint, so this needs no extra dependency.
DOCKERFILES := 'images/runner-base.Dockerfile images/runner-gpu.Dockerfile'

# ShellCheck / hadolint / bats all run inside the test-tools container.
_docker_run := 'docker run --rm -v "$PWD:/source" -w /source ' + TEST_TOOLS_IMAGE

# Coverage container needs seccomp=unconfined for kcov's ptrace, and writable
# /source so coverage/ output lands on the host. `--network none` is the point
# of the pinned bats cache: nothing inside the container may reach out, so the
# run is the same on a laptop, on a restricted network and in CI. The cached
# bats-core release is mounted read-only at /opt/bats -- OUTSIDE /source, so
# kcov's `--include-path=.` never mistakes bats' own sources for ours.
# `--user` writes the report as the invoking user instead of root; without it
# the report is root-owned and the recipe's own `rm -rf coverage` fails on the
# NEXT run, so a second `just coverage` could not be reproduced locally at all.
_kcov_run := 'docker run --rm --network none --user "$(id -u):$(id -g)" --security-opt seccomp=unconfined -v "$PWD:/source" -w /source'

# Show available recipes.
default:
    @just --list

# Pull both test-tools and coverage images, and cache the pinned bats-core
# release. This is the whole "fetch everything" step: after it, `lint`, `test`
# and `coverage` all run with no outbound network.
pull:
    docker pull {{TEST_TOOLS_IMAGE}}
    docker pull {{COVERAGE_IMAGE}}
    bash script/fetch-bats.sh

# ShellCheck + hadolint in the test-tools container, after the repo lints
# (below). The repo lints run first because they are pure bash + grep and cost
# nothing, so a structural failure is reported before a container is started.
lint: lint-adr lint-changelog lint-readme-sync lint-doc-citations
    {{_docker_run}} shellcheck -x {{SCRIPTS}}
    {{_docker_run}} hadolint {{DOCKERFILES}}

# The whole layered bats suite, inside the test-tools container.
#
# The suite is split by level (doc/test-levels.md): `unit` exercises one
# function or one file in isolation, `integration` exercises several scripts or
# libraries working together. Both levels are named explicitly rather than
# handed to `bats --recursive`, so adding a level is a deliberate edit here -- a
# level nobody wired up would otherwise sit unrun and look green.
test: test-unit test-integration

# One function or one file in isolation.
test-unit:
    {{_docker_run}} bats test/bats/unit/

# Several scripts / libraries working together.
test-integration:
    {{_docker_run}} bats test/bats/integration/

# lint + test (no coverage).
check: lint test

# Bats with kcov coverage -> ./coverage/ (slow; CI / release).
#
# script/fetch-bats.sh prints the cache dir for the pinned bats-core release,
# downloading and sha256-verifying it only when it is not cached yet. So the
# first run needs the network for that one tarball and every run after it needs
# none at all -- the container itself is started with --network none.
coverage:
    rm -rf coverage
    bats_dir="$(bash script/fetch-bats.sh)" \
      && {{_kcov_run}} -v "$bats_dir:/opt/bats:ro" {{COVERAGE_IMAGE}} \
           kcov --include-path=. /source/coverage /opt/bats/bin/bats \
             test/bats/unit/ test/bats/integration/
    @echo "coverage report: ./coverage/index.html"

# Measure bash coverage, then enforce its floor (PRD.md §0.4). This is the
# recipe the CI `coverage` job runs: measuring and enforcing in one place means
# CI cannot drift from what a maintainer runs locally.
coverage-gate: coverage
    bash script/coverage-gate.sh bash coverage

# Go coverage for the listener core, then its floor (PRD.md §0.4).
#
# The package list deliberately EXCLUDES listener/cmd/ -- that entrypoint reads
# environment variables and wires the pieces together, and is covered at the
# integration and system level instead. Measuring a wiring layer as line
# coverage only invites tests that assert it was called; see the layered
# coverage strategy in PRD.md §0.4.
#
# Everything except the func report stays inside the container (profile in
# /tmp, module and build caches in the image), so the run leaves no root-owned
# files on the bind mount; the report is captured through stdout.
coverage-go:
    docker run --rm -v "$PWD:/repo" -w /repo/listener {{GO_IMAGE}} \
      sh -c 'go test -coverprofile=/tmp/cover.out $(go list ./... | grep -v "/cmd/") >&2 && go tool cover -func=/tmp/cover.out' \
      > listener/coverage.func
    bash script/coverage-gate.sh go listener/coverage.func

# --- repo structure lints -------------------------------------------------
# All four are pure bash + grep, so unlike shellcheck / hadolint / bats they
# need no test-tools container: they run on the host and are the cheapest jobs
# in the gate. Each also has its own CI job in the ci-rollup needs list, so a
# structural failure blocks a merge on its own name rather than hiding inside
# another job's log.

# ADR structure lint (doc/adr/), per PRD.md §0.5: the `> Serves:` back-pointer,
# the four required sections, the permitted Status values, the filename /
# numbering rules, and that a `Superseded by` target exists.
lint-adr:
    bash script/lint-adr.sh

# The ref a branch is judged against. Override when the branch was taken from
# something other than main.
BASE := env_var_or_default('BASE', 'origin/main')

# A change an operator can observe must carry a CHANGELOG entry (PRD.md §0.7).
# Judged against the merge base with BASE, so it asks what this branch changed
# rather than what main gained meanwhile.
lint-changelog:
    bash script/lint-changelog.sh --base {{BASE}}

# README.md and the three translations must not drift apart structurally: a
# section that exists in one language and not the others leaves the other
# readers told less.
lint-readme-sync:
    bash script/lint-readme-sync.sh

# No `file:line` citations and no hardcoded counts in the project's own
# documentation -- both are copies of what the tree already states, and both go
# stale with no signal (invariant 3).
lint-doc-citations:
    bash script/lint-doc-citations.sh

# ShellCheck on host (requires shellcheck installed locally), plus the same
# repo lints, so the host path covers exactly what the container one does.
lint-host: lint-adr lint-changelog lint-readme-sync lint-doc-citations
    shellcheck -x {{SCRIPTS}}

# The layered bats suite on host (requires bats installed locally).
test-host:
    bats test/bats/unit/ test/bats/integration/

# --- scale-set listener build / install (ADR-0001 Phase 4 deployment, #108) ---
# The host needs NO Go toolchain: the binary is built INSIDE a golang container
# and only the resulting static binary + its sibling shell scripts are installed
# to the host, where systemd (#109) supervises it.

# Pinned Go image -- the same version actions/scaleset v0.4.0 requires. Override
# via env or `just GO_IMAGE=... build-listener` for a local toolchain image.
GO_IMAGE := env_var_or_default('GO_IMAGE', 'golang:1.25.3')

# Where the built binaries land on the host (gitignored build output).
#
# Two binaries, one deployment unit: the listener runs the jobs, and
# scaleset-admin creates (and deletes) the GitHub scale set the listener binds
# to. Installing only the listener leaves an operator exactly where the deploy
# runbook used to leave them: told to fill in a scale set name, with nothing in
# the repo that produces one.
BIN_DIR := env_var_or_default('BIN_DIR', 'bin')
LISTENER_BIN := BIN_DIR / 'scaleset-listener'
ADMIN_BIN := BIN_DIR / 'scaleset-admin'

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

# Build the scale-set lifecycle command (create / delete a runner scale set),
# with the same static containerized build as the listener. It is a separate
# binary because it is a separate act: the listener is a supervised long-running
# service, this is an operator command that changes something on GitHub.
build-admin:
    @mkdir -p {{BIN_DIR}}
    docker run --rm -e CGO_ENABLED=0 -v "$PWD:/repo" -w /repo/listener {{GO_IMAGE}} go build -trimpath -buildvcs=false -ldflags='-s -w' -o /repo/{{ADMIN_BIN}} ./cmd/scaleset-admin
    @echo "built: {{ADMIN_BIN}}"

# The listener shells out to provision-job.sh / reap.sh, which source
# ../lib/*.sh -- so the install preserves that sibling layout:
# <prefix>/bin/, <prefix>/listener/, <prefix>/lib/.
#
# Install both binaries + the scripts to PREFIX.
install-listener: build-listener build-admin
    install -d "{{DESTDIR}}{{PREFIX}}/bin"
    install -m 0755 "{{LISTENER_BIN}}" "{{DESTDIR}}{{PREFIX}}/bin/scaleset-listener"
    install -m 0755 "{{ADMIN_BIN}}" "{{DESTDIR}}{{PREFIX}}/bin/scaleset-admin"
    install -d "{{DESTDIR}}{{PREFIX}}/listener"
    install -m 0755 listener/provision-job.sh "{{DESTDIR}}{{PREFIX}}/listener/provision-job.sh"
    install -m 0755 listener/reap.sh "{{DESTDIR}}{{PREFIX}}/listener/reap.sh"
    install -m 0755 listener/host-probe.sh "{{DESTDIR}}{{PREFIX}}/listener/host-probe.sh"
    install -d "{{DESTDIR}}{{PREFIX}}/lib"
    install -m 0644 lib/*.sh "{{DESTDIR}}{{PREFIX}}/lib/"
    @echo "installed to {{DESTDIR}}{{PREFIX}}"

# Remove the built binaries.
clean-listener:
    rm -rf {{BIN_DIR}}
