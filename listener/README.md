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
| `MAX_RUNNERS` | capacity ceiling offered to GitHub (0 = demand-sized) |
| `PROVISION_SCRIPT` | path to `provision-job.sh` (default sibling) |
