# Scale-set listener (ADR-0001 Phase 4)

The orchestration layer for the ephemeral / JIT runner model
([ADR-0001](../doc/adr/0001-ephemeral-jit-runners.md)). It integrates the
official **Runner Scale Set Client** ([`github.com/actions/scaleset`](https://github.com/actions/scaleset),
Go) as the non-k8s, outbound long-poll orchestrator and supplies the one piece
that client does *not*: the per-job container provisioning where the
residue/secret isolation actually lands.

## What this owns vs. what GitHub's client owns

The split is the whole point of the ADR:

| GitHub's `actions/scaleset` client owns | This package owns |
| --- | --- |
| The outbound long-poll **scale-set session** protocol (no inbound webhook) | The **provisioning glue** between demand and a container |
| Reading demand (`Statistics.TotalAssignedJobs`) | Reporting spare **capacity** back so GitHub never over-assigns |
| *When / how many* runners | *How* each job is isolated: one fresh, single-use, rootless container per job |

We never decide scheduling. For each **ASSIGNED** job the listener shells out
to [`provision-job.sh`](provision-job.sh), which bridges to the Phase 3 seam
[`lib/runner-container.sh`](../lib/runner-container.sh) (`runner_container_run`)
— so that seam stays the single source of truth for the
`--rm` single-use container.

## Layout

- [`listener.go`](listener.go) — the demand→provision loop. `Session` is an
  **injectable interface** mirroring the subset of
  `*scaleset.MessageSessionClient` the loop drives (`GetMessage`,
  `AcquireJobs`, `DeleteMessage`, `Session`, `Close`). A compile-time
  assertion (`var _ Session = (*scaleset.MessageSessionClient)(nil)`) proves
  the real client satisfies it, so the loop is unit-testable against a fake
  with no live GitHub.
- [`provisioner.go`](provisioner.go) — `ContainerProvisioner`, the production
  `Provisioner` that shells out to `provision-job.sh`.
- [`provision-job.sh`](provision-job.sh) — the per-job container entrypoint
  (`provision-job.sh <job-id> <encoded-jit-config> <image>`); sources the
  Phase 3 seam, runs one throwaway container, propagates its exit status, and
  removes the per-job runner dir so no residue survives.
- [`cmd/scaleset-listener`](cmd/scaleset-listener) — the production entrypoint
  that wires the real client into the listener (the **live** path).

## Build & test (in a container — `go` is not on the host)

The module requires Go ≥ 1.25.3 (a transitive constraint of
`actions/scaleset v0.4.0`):

```sh
cd listener
docker run --rm -v "$PWD:/src" -w /src golang:1.25.3 sh -c 'go build ./... && go test ./...'
```

The unit tests (`listener_test.go`, `provisioner_test.go`) drive the loop
through the `Session` seam with a scripted fake session and a recording
provisioner, asserting:

- an ASSIGNED job triggers the container shell-out with its JIT config + image,
- reported capacity **follows demand** (`MaxRunners − TotalAssignedJobs`),
- each processed message is acked (`DeleteMessage`),
- a provisioner error surfaces **and** the session is torn down (`Close`),
- a clean drain still tears the session down,
- available-but-unassigned jobs do **not** provision,
- the real client satisfies `Session`.

Host-side, [`test/smoke/listener_provision.bats`](../test/smoke/listener_provision.bats)
covers the entrypoint script with a stubbed container CLI.

## Live end-to-end gap (the one untested path)

The unit + bats suites cover every seam **except** a real long-poll against a
**live, provisioned GitHub scale set** — that needs operator credentials
(`GITHUB_TOKEN` with scale-set admin scope), a `GITHUB_CONFIG_URL`, and an
actual scale set, none of which exist in CI. That single gap is:

- documented here,
- exercised by [`integration_test.go`](integration_test.go), gated behind the
  `integration` build tag and skipped unless the live env knobs are set, so it
  never runs (or fails) in the default suite.

Run it manually against a real scale set:

```sh
GITHUB_CONFIG_URL=https://github.com/<org> \
GITHUB_TOKEN=<scale-set-admin-token> \
SCALE_SET_NAME=<name> \
docker run --rm -e GITHUB_CONFIG_URL -e GITHUB_TOKEN -e SCALE_SET_NAME \
  -v "$PWD:/src" -w /src golang:1.25.3 \
  go test -tags=integration -run TestLiveScaleSetSession -v ./...
```

## Production entrypoint env

`cmd/scaleset-listener` reads:

| Env | Meaning |
| --- | --- |
| `GITHUB_CONFIG_URL` | `https://github.com/<org>` (required) |
| `GITHUB_TOKEN` | token with scale-set admin scope (required) |
| `SCALE_SET_NAME` | the scale set workflows target (required) |
| `RUNNER_IMAGE` | per-job container image (default `ghcr.io/actions/actions-runner:latest`) |
| `MAX_RUNNERS` | worker-pool bound; the basis for locally-derived capacity (0 = default / auto-size) |
| `AUTO_SIZE_DEVICES` | when set (and `MAX_RUNNERS` unset), auto-size the pool to the detected device count (#103) |
| `DEVICE_DETECT_CMD` | device-enumeration command for auto-sizing (default `nvidia-smi`, one device per output line) |
| `PROVISION_SCRIPT` | path to `provision-job.sh` (default sibling) |
| `REAP_SCRIPT` | path to `reap.sh`, the orphan-sweep entrypoint (default sibling) |

The bash seams read a few more knobs at provision/reap time:
`RUNNER_WORK_ROOT` (parent of the per-job temp dir, default `/tmp`),
`RUNNER_JOB_MAX_LIFETIME` (per-job watchdog ceiling in seconds, default 6h, 0
disables, #107), and `RUNNER_MANAGED_BY` (the `managed-by` label value the
reaper keys on, #104/#105).

## Concurrency, capacity & lifecycle

- **Bounded worker pool (#101):** each acquired job provisions in its own
  goroutine gated by a semaphore sized to the pool bound, so the loop keeps
  long-polling; a clean shutdown drains in-flight jobs before teardown.
- **Locally-derived capacity (#102):** reported headroom is the pool bound
  minus the *local* in-flight count, not the server's `TotalAssignedJobs`.
- **Auto-sizing (#103):** with `AUTO_SIZE_DEVICES`, the bound follows the
  detected device count; otherwise `MAX_RUNNERS`, else a sane default.
- **Reaping (#104/#105/#106):** each container gets a deterministic name +
  `managed-by`/`job-id` labels; the listener sweeps orphaned labelled
  containers and leaked `jit-*` temp dirs on startup and on an interval,
  sparing in-flight jobs.
- **Watchdog (#107):** a per-job watchdog stops+removes a container that
  outlives `RUNNER_JOB_MAX_LIFETIME`.

## Deployment (host binary under systemd, #108/#109)

The host needs **no Go toolchain** — the binary is built inside a golang
container and only the resulting static binary + its sibling shell scripts are
installed.

```sh
# Build the static binary (containerized; reproducible, CGO off):
make build-listener            # -> bin/scaleset-listener

# Install binary + provision-job.sh + reap.sh + lib/ to PREFIX:
sudo make install-listener PREFIX=/opt/github-runner-listener
```

The install preserves the sibling layout the listener shells out against:
`<prefix>/bin/scaleset-listener`, `<prefix>/listener/{provision-job,reap}.sh`,
`<prefix>/lib/*.sh`. systemd then supervises it — see
[`deploy/scaleset-listener.service`](../deploy/scaleset-listener.service) and
[`deploy/README.md`](../deploy/README.md) for the unit and install steps.
