# Deploying the scale-set listener under systemd (#108/#109)

Package and supervise the [scale-set listener](../listener/) as a host binary
under systemd (option a, [ADR-0001](../doc/adr/0001-ephemeral-jit-runners.md)).
The host needs **no Go toolchain**: the binary is built inside a golang
container (#108) and only the static binary plus its sibling shell scripts are
installed.

## 1. Build & install the binary (#108)

```sh
# Build the static binary inside a pinned golang container:
just build-listener                 # -> bin/scaleset-listener

# Install binary + provision-job.sh + reap.sh + lib/ under PREFIX:
sudo just PREFIX=/opt/github-runner-listener install-listener
```

This lays down a self-contained tree the listener shells out against:

```
/opt/github-runner-listener/
├── bin/scaleset-listener           # the static binary systemd runs
├── listener/provision-job.sh       # per-job container entrypoint
├── listener/reap.sh                # orphan-sweep entrypoint
└── lib/*.sh                         # the bash seams those scripts source
```

## 2. Create the unprivileged service user

The unit runs as a dedicated non-root user (acceptance: never root). It must be
able to reach the rootless container engine (rootless podman session, or
membership in the `docker` group):

```sh
sudo useradd --system --create-home --shell /usr/sbin/nologin ci-runner
# If using rootful docker, also: sudo usermod -aG docker ci-runner
```

## 3. Provide the token via an EnvironmentFile (mode 0600) (#109)

The scale-set admin token is **never** baked into the unit, passed on the
command line, or logged — it is read from a root-only EnvironmentFile:

```sh
sudo install -d -m 0755 /etc/github-runner-listener
sudo install -m 0600 deploy/scaleset-listener.env.sample \
  /etc/github-runner-listener/scaleset-listener.env
sudo "${EDITOR:-vi}" /etc/github-runner-listener/scaleset-listener.env
# Fill in GITHUB_CONFIG_URL, GITHUB_TOKEN, SCALE_SET_NAME.
# Verify it is 0600 and root-owned:
sudo stat -c '%a %U' /etc/github-runner-listener/scaleset-listener.env   # -> 600 root
```

## 3a. (Optional) Register a runner type via the per-type config (#110/#112/#113)

Instead of the discrete `SCALE_SET_NAME` / `RUNNER_IMAGE` knobs, drive the
listener from a **runner-type config**. Each entry maps one runner type to one
homogeneous scale set (labels, image, device passthrough, runtime, build tool,
hardening profile, concurrency); adding a type is a new entry, not a code change.
Concurrency is reactive live-admission by default — the count is derived from
live host headroom, not configured, and the only knob is `reserve` percent
([ADR-0005](../doc/adr/0005-reactive-live-admission.md)); a GPU type opts into
device-count sizing with `mode: auto`. The Go listener is the authoritative
parser ([ADR-0003](../doc/adr/0003-go-bash-boundary.md)).

```sh
sudo install -m 0644 deploy/runner-types.sample.yaml \
  /etc/github-runner-listener/runner-types.yaml
sudo "${EDITOR:-vi}" /etc/github-runner-listener/runner-types.yaml
# Then in the EnvironmentFile, point at it and pick the type this unit serves:
#   RUNNER_TYPES_CONFIG=/etc/github-runner-listener/runner-types.yaml
#   RUNNER_TYPE=gpu
```

The shipped sample defines the first concrete **GPU** type (auto concurrency =
detected GPU count via `nvidia-smi -L`, precise `--device` passthrough, no
`--privileged`) plus a second **CPU** type — proving two types run side by side
with no code change. One listener process serves one scale set, so run **one
unit per type** (copy the unit under a per-type name, each with its own
`RUNNER_TYPE`).

> **Live GPU validation is HITL.** The config, its loading, and auto-concurrency
> from the GPU count are exercised AFK (the detector is stubbed in the Go tests).
> A GPU job *actually running* needs a real GPU host with the NVIDIA stack — an
> operator step on the target host.

## 3b. Build (or pin) the per-type runner images (#92: #120/#121/#122)

The `image` each runner type references is produced one of two ways (ADR-0001
"Runner images"):

**Self-built image, SEC-5 supply chain (#120).** Device/GPU types need a
self-built image because stock actions-runner images can't run GPU jobs. The
runner tarball baked into that image is obtained through the **same SEC-5 check
the host bootstrap uses** (`verify_runner_tarball`, strict) — a tampered mirror
/ MITM can never reach the image. The wrapper downloads + verifies on the host,
then hands the already-verified tarball to a digest-pinned, hermetic build:

```sh
# Build the SEC-5 base (gh is a prereq: the digest is verified strict).
# RUNNER_VERSION pins the version; omit for the resolved latest.
RUNNER_VERSION=2.334.0 \
  images/build-runner-image.sh --tag ghcr.io/your-org/runner-base:2.334.0
```

**GPU/device image, layered on the SEC-5 base (#121).** The CUDA/device stack
is layered on that base (so the runner stays the SEC-5-verified one). Both
`FROM`s are pinned by digest; the build is hermetic (the CUDA libs are copied
from a pinned `nvidia/cuda` image, no NVIDIA apt repo at build time):

```sh
docker build -f images/runner-gpu.Dockerfile \
  --build-arg RUNNER_BASE_IMAGE=ghcr.io/your-org/runner-base:2.334.0 \
  --build-arg RUNNER_VERSION=2.334.0 \
  -t ghcr.io/your-org/gpu-runner:2.334.0 .

# Push, then pin the runner-type config's `image:` by the resulting DIGEST:
docker push ghcr.io/your-org/gpu-runner:2.334.0
docker buildx imagetools inspect ghcr.io/your-org/gpu-runner:2.334.0   # copy Digest
# -> image: ghcr.io/your-org/gpu-runner@sha256:<digest>
```

> **A GPU job actually executing is HITL.** The images *build* and are wired
> into the GPU runner-type config AFK; running a real GPU job needs a host with
> the NVIDIA driver + container runtime — an operator step on the target host.

**Plain CPU type — pin the upstream image by digest (#122).** A CPU type needs
no self-built image; it uses the **official** `ghcr.io/actions/actions-runner`
image pinned by `@sha256:` digest (never `:latest`). Bump the digest
deliberately:

```sh
docker buildx imagetools inspect ghcr.io/actions/actions-runner:latest
# copy the top-level "Digest: sha256:..." into the cpu type's image:, then commit.
# (Pin the version you validated, not whatever :latest moved to.)
```

## 4. Install, enable & start the unit

```sh
sudo install -m 0644 deploy/scaleset-listener.service \
  /etc/systemd/system/scaleset-listener.service
sudo systemctl daemon-reload
sudo systemctl enable --now scaleset-listener.service

# Watch it come up (the token never appears in the logs):
journalctl -u scaleset-listener -f
```

`Restart=always` (with a 5s backoff) keeps the listener supervised across a
clean drain (SIGTERM cancels the context, in-flight jobs drain within
`TimeoutStopSec`) or a transient error, so the host is never left without a
listener.

## Verifying the unit file

The unit is checkable without a live install:

```sh
systemd-analyze verify deploy/scaleset-listener.service
```

> **Live install is HITL.** Enabling the unit on a real host needs that host,
> a real scale set, and a valid admin token (none exist in CI). The unit file,
> the env sample, and these steps are the deliverable; the live
> enable/verify is performed by an operator on the target host.
