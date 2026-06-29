# 0003 — Go/bash boundary: minimal Go surface, one clean shell-out

- **Status**: accepted
- **Date**: 2026-06-24

## Context

Choosing the official **Runner Scale Set Client** (`actions/scaleset`, a Go
library) in [ADR-0001](0001-ephemeral-jit-runners.md) forced **Go** into what was
a pure **bash + bats** repo. That raises an unavoidable question a future reader
will ask: given both languages now exist, **where does the line between them
go**, and why isn't it all one language?

The repo's whole existing surface — `add-runner`, `cleanup`, `status`,
`lib/runner-*.sh`, the `_gh` seam, `RUNNER_HOME`/SEC-3, the `schedule-cleanup`
harness — is bash with bats coverage. Only the scale-set session protocol
genuinely *requires* Go (there is no bash equivalent).

## Decision

**Two languages coexist by design, under one rule: keep the Go surface minimal,
and make the Go↔bash boundary a single clean shell-out.**

- **Go** is used **only** for what the scale-set client requires — the listener
  "brain": the long-poll `Session`, JIT minting (`GenerateJitRunnerConfig`),
  ack, the bounded concurrency pool / capacity, and the **authoritative**
  runner-type config parse.
- **Bash** does **everything else**, reusing the existing seams: the per-job
  container provisioner, the reaper, the build seam, and the job-history store.
- **The boundary is one shell-out**: per acquired job, the Go listener invokes
  the bash container provisioner with **explicit parameters** (image, devices,
  hardening profile, and the JIT config via a file, not argv). Go does not
  reimplement container/host/cleanup logic; bash does not talk to the scale-set
  API.

Stated as a standing principle: **new logic defaults to bash; it only goes into
Go if it cannot be done without the scale-set client.**

## Considered options

- **All-Go** — move provisioning, reaping, history, config into Go too.
  Rejected: abandons the tested bash seams, reimplements `RUNNER_HOME`/SEC-3 /
  `_gh` / `schedule-cleanup`, and grows the Go surface (and its maintenance) far
  beyond what the client needs.
- **All-bash** — avoid Go entirely. Rejected at ADR-0001: that is the DIY
  supervisor-loop option (no official scale-set client), which we declined for
  maintenance/official-support reasons.
- **Minimal-Go with a shell-out boundary** — chosen: Go only where the client
  forces it; everything else stays in the repo's native, already-tested bash.

## Consequences

- The maintenance cost is **"a small Go brain + the existing bash hands"**, not
  two co-equal systems. Reviewers should resist drifting logic into Go.
- **Runner-type config is read by both sides.** Resolution: Go is the
  **authoritative parser**; it passes the per-job fields a provision needs to
  bash via the shell-out — only one parser of record.
- The **shell-out contract** (its parameters) is an interface that must stay
  explicit and stable; changing it is a cross-language change.
- Each side is tested in its own idiom: Go deep modules via mock/fake; bash
  seams via bats stub-and-capture. CI runs both (Go in a container).
- The JIT config crosses the boundary **as a file**, never on argv, so it is not
  exposed in the process table. **This file-not-argv rule is necessary but not
  sufficient**: bash must also avoid re-splicing the credential back onto the
  HOST `podman/docker run` argv (which would re-expose it in the host process
  table, /proc/<pid>/cmdline). Bash therefore hands the credential to the engine
  via a mode-0600 `--env-file` and lets `run.sh` read it from the env inside the
  container's own process namespace — the secret stays off the host argv end to
  end (#136). **This must hold for the IN-CONTAINER argv too**: passing
  `./run.sh --jitconfig "${JITCONFIG}"` lets the container's `sh -c` expand the
  credential onto `run.sh`'s argv, and for rootless/rootful engines `run.sh` is
  an ordinary HOST process whose `/proc/<pid>/cmdline` (mode 0444, no ptrace
  check, unlike `/proc/<pid>/environ`) is world-readable — re-exposing the secret
  to any local host user. So the env-file sets the runner's native
  `ACTIONS_RUNNER_INPUT_JITCONFIG` input and the in-container command is just
  `./run.sh` with NO `--jitconfig` flag: the credential rides the environment
  only, never any cmdline (#155). As defense-in-depth, mount host `/proc` with
  `hidepid=2` (see
  [HOST-HARDENING](../runbook/HOST-HARDENING.md)) so non-CI local users cannot
  read other processes' cmdline at all.

## References

- [ADR-0001](0001-ephemeral-jit-runners.md) — the scale-set client choice that
  introduced Go.
- [PRD — Ephemeral JIT runners](../prd/ephemeral-jit-runners.md) — Implementation
  Decisions (language boundary, modules).
