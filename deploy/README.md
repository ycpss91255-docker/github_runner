# Deploying the scale-set listener under systemd (#108/#109)

Package and supervise the [scale-set listener](../listener/) as a host binary
under systemd (option a, [ADR-0001](../doc/adr/0001-ephemeral-jit-runners.md)).
The host needs **no Go toolchain**: the binary is built inside a golang
container (#108) and only the static binary plus its sibling shell scripts are
installed.

## 0. Read this first: what a workflow actually targets

**Workflows target a runner type by its `labels`. The scale set name is only an
identifier.** A workflow's `runs-on` is matched against the scale set's
**labels**, which are fixed when the scale set is created.

The name and the labels coincide only when the scale set was created with its
name as its single label. That is the default here when a runner type declares
no labels of its own, and it is exactly why the name *looks* like the routing
target when it is not.

Getting this wrong is the most expensive mistake available in this system,
because it produces no error at all: the job simply sits in `queued`. Note also
that the REST job status **stays `queued` even after a job has been assigned to
a scale set**, so `queued` on its own is not evidence of a routing failure.

Two ways to decide the labels, both explicit:

| Runner type declares | Scale set is created with | A workflow writes |
| --- | --- | --- |
| no `labels` | labels = exactly the scale set name | `runs-on: <scale-set-name>` |
| `labels: [a, b]` | labels = `a`, `b` verbatim (the name is never added) | `runs-on: [a, b]` |

Either way the labels are **written into the scale set explicitly** and recorded
in `runner-types.yaml`, so the configuration always states what the routing key
is. `scaleset-admin` prints the exact `runs-on:` line to paste; use what it
prints.

> **What has been confirmed.** A scale set created this way received and ran a
> real job end to end, which confirmed matching against the scale set's labels.
> It did not exercise a job requesting a *subset* of a multi-label scale set.
> Standard Actions semantics is that every label a job requests must be present
> on the runner, but that subset case is unverified here -- so have the workflow
> request exactly what `scaleset-admin` printed.

## 1. Build & install the binaries (#108)

```sh
# Build the static binaries inside a pinned golang container:
just build-listener                 # -> bin/scaleset-listener
just build-admin                    # -> bin/scaleset-admin

# Install both binaries + provision-job.sh + reap.sh + lib/ under PREFIX:
sudo just PREFIX=/opt/github-runner-listener install-listener
```

This lays down a self-contained tree the listener shells out against:

```
/opt/github-runner-listener/
├── bin/scaleset-listener           # the static binary systemd runs
├── bin/scaleset-admin              # create / delete a runner scale set
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
# SCALE_SET_NAME names a scale set; it is NOT what workflows target (section 0).
# Verify it is 0600 and root-owned:
sudo stat -c '%a %U' /etc/github-runner-listener/scaleset-listener.env   # -> 600 root
```

## 3a. (Optional) Register a runner type via the per-type config (#110/#112/#113)

Instead of the discrete `SCALE_SET_NAME` / `RUNNER_IMAGE` knobs, drive the
listener from a **runner-type config**. Each entry maps one runner type to one
homogeneous scale set (labels, image, device passthrough, runtime, build tool,
concurrency); adding a type is a new entry, not a code change.
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

## 3c. Create the runner type's scale set on GitHub (`scaleset-admin`)

The listener **connects to** a scale set; it never creates one. Until this step
has run there is nothing for `SCALE_SET_NAME` / the type's `scale_set` to name,
and the listener exits telling you so.

`scaleset-admin` is driven by the same runner-type config the listener reads --
the name comes from the type's `scale_set` and the routing labels from its
`labels`, and neither can be passed as a flag. That is deliberate: it makes
`runner-types.yaml` the single source of truth for routing, so the config and
the live scale set cannot be made to disagree by a one-off command line.

```sh
export GITHUB_CONFIG_URL=https://github.com/<org>
read -rs GITHUB_TOKEN && export GITHUB_TOKEN   # scale-set admin scope
                                               # (prompted: never in argv or history)

# Preview first -- prints exactly what would be created on GitHub:
scaleset-admin create --config /etc/github-runner-listener/runner-types.yaml \
  --type gpu --dry-run

# Then create it. Running it again is a no-op that says so.
scaleset-admin create --config /etc/github-runner-listener/runner-types.yaml \
  --type gpu
```

It prints the literal line to paste into a workflow, which is the answer to the
question section 0 is about:

```
Workflows target this runner type by its LABELS (the name is only an identifier).
Paste into your workflow job:

    runs-on: [self-hosted, linux, gpu]
```

**Idempotent.** A second run over an existing scale set changes nothing,
reports the existing id, and exits 0 -- so standing up a second machine against
the same runner type needs no GitHub-side step at all. If the live scale set's
labels have drifted from the config, it says so loudly rather than reusing a
scale set nobody's config describes.

Options: `--group <name>` picks the runner group to create in (default
`Default`); `--type` may be omitted when the config holds exactly one type.
`GITHUB_CONFIG_URL` and `GITHUB_TOKEN` are read from the environment and are
deliberately not flags -- a token in a flag is a token in the host process
table.

**Deleting is a separate, explicit act.** Nothing else in this repo deletes a
scale set; no install, teardown or uninstall path touches it. Removing it makes
every workflow targeting those labels stop being served, so it is its own verb
and it insists on `--yes`:

```sh
scaleset-admin delete --config /etc/github-runner-listener/runner-types.yaml \
  --type gpu --dry-run     # preview
scaleset-admin delete --config /etc/github-runner-listener/runner-types.yaml \
  --type gpu --yes
```

Deleting one that is not there succeeds as a no-op, so a teardown can be re-run.

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
