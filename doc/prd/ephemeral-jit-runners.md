# PRD — Ephemeral JIT self-hosted runners + job history

Consolidates [ADR-0001](../adr/0001-ephemeral-jit-runners.md) and
[ADR-0002](../adr/0002-job-history-audit-trail.md). Implemented on branch
`feat/ephemeral-jit-runners`. Tracker: parents #84–#94, sub-issues #95–#131.

## Problem Statement

As the operator of self-hosted GitHub Actions runners, I run **persistent**
runners that serve an unbounded sequence of jobs. This means:

- State and secrets **leak between jobs** — a prior job can poison the next
  checkout (root-owned residue) or leave credentials a later job can read. I
  cannot fully scrub this away; it is inherent to one runner serving many jobs.
- My hosts sit in the `docker` group, which is **root-equivalent** — a worry as
  the repos served may not stay fully trusted.
- When something goes wrong, the runner environment is long-lived and noisy, and
  GitHub only keeps job console logs (~90 days) **without** the self-hosted
  execution context (which host, image, device ran it) — so I **cannot reliably
  trace a failure** back to its cause.
- My fleet is **heterogeneous** (a GPU host today; many device-bound types
  later) and I want each type configured independently, scaling to the hardware
  it actually has.

## Solution

Move to **ephemeral, just-in-time (JIT) runners**: each runner serves exactly
one job in a **fresh, single-use container** and is then destroyed — eliminating
cross-job residue and secret carryover by construction.

- Orchestrated by the official **Runner Scale Set Client** (`actions/scaleset`,
  Go), run as a **non-privileged host listener under systemd**. The Go binary is
  built **inside a container**, so the host needs no Go toolchain.
- Each runner **type** is one config entry mapping to one GitHub **scale set**
  (labels, image, device passthrough, runtime, build tool, hardening profile,
  auto-sized concurrency). Start with GPU; add types without code changes.
- Security comes from the **architecture**: the untrusted job runs in a hardened
  throwaway container that, by default, **cannot reach the Docker socket**, so
  the host `docker`-group root-equivalence is not reachable by job code.
- **Job history** is captured **before teardown** into a durable,
  retention-bounded local store with a query tool, so failures can be traced
  after the ephemeral environment is gone.

## User Stories

1. As an operator, I want each job to run in a fresh container that is destroyed
   afterward, so that no state or secret carries into the next job.
2. As an operator, I want runners minted just-in-time with a single-use config,
   so that no long-lived registration token sits on the host.
3. As an operator, I want the orchestrator to be the official scale-set client,
   so that GitHub maintains the protocol and I do not chase API drift.
4. As an operator, I want the Go listener built inside a container, so that my
   host never needs a Go toolchain installed.
5. As an operator, I want the listener supervised by systemd with restart, so
   that a transient error or clean drain does not take my fleet permanently dark.
6. As an operator, I want the listener to run as a non-privileged user, so that
   compromising it does not hand over the host.
7. As an operator, I want jobs provisioned concurrently up to a bound, so that
   the listener is not limited to one job at a time.
8. As an operator, I want the concurrency bound auto-sized from my hardware
   (e.g. GPU count), so that I do not hand-tune numbers per host.
9. As an operator, I want reported capacity to reflect what the host can really
   run, so that GitHub does not queue jobs against headroom that does not exist.
10. As an operator, I want a single failed job to be logged and skipped, so that
    one bad job never tears down the whole listener session.
11. As an operator, I want messages acknowledged when a job is acquired, so that
    long jobs do not leave messages unacked and risk redelivery.
12. As an operator, I want orphaned containers and stale temp dirs reaped, so
    that a crash mid-job does not leak resources and break "zero residue".
13. As an operator, I want each job container bounded by a max lifetime, so that
    a hung job cannot hold a GPU/host resource forever.
14. As an operator, I want one config entry per runner type, so that I can add a
    new type (labels/image/devices) without touching code.
15. As an operator with a GPU host, I want GPU devices passed into the job
    container, so that GPU workflows actually run.
16. As an operator with special-device runners, I want only the declared devices
    passed through (no `--privileged`), so that access is least-privilege.
17. As a security reviewer, I want every job container hardened (cap-drop,
    no-new-privileges, seccomp + MAC kept, pids-limit), so that escape is hard.
18. As a security reviewer, I want the Docker socket never mounted into a job by
    default, so that job code cannot control the host daemon.
19. As an operator whose jobs build images, I want daemonless builds (Kaniko /
    BuildKit-rootless), so that builds need no socket and no privileged mode.
20. As an operator, I want the option (later) to run untrusted types under a
    stronger sandbox (gVisor/Kata/Sysbox/userns-remap), so that I can escalate
    isolation per type when needed.
21. As an operator, I want device runners to rely on the ADR-0011 approval gate,
    so that unapproved untrusted code never reaches a rootful device host.
22. As an operator, I want GPU/device runner images self-built from a SEC-5
    verified runner tarball, so that the image supply chain matches my standard.
23. As an operator, I want plain CPU runners to use an upstream image pinned by
    digest, so that I avoid `:latest` drift without maintaining an image.
24. As an operator, I want a full history record for every job (id, labels,
    image+digest, host, type, devices, timing, exit, trigger), so that I can
    audit what ran where.
25. As an operator, I want the job's full log and runner `_diag` archived before
    teardown, so that I can post-mortem a failure after the container is gone.
26. As an operator, I want the history store to never contain the JIT config or
    any secret, so that the audit trail is not itself a credential leak.
27. As an operator, I want to query history by job id / time / repo / outcome,
    so that I can find the problem point quickly when something breaks.
28. As an operator, I want history bounded by both a size cap and an age cap with
    oldest-first eviction, so that the audit trail cannot fill my disk.
29. As an operator, I want a reserved seam to push history to an external store
    later, so that evidence survives losing the host.
30. As a maintainer, I want the Go module built/vetted/tested in CI and gating
    merges, so that a Go regression cannot ship silently.
31. As a maintainer, I want per-job work dirs under `RUNNER_HOME`, so that the
    SEC-3 `rm -rf` chokepoint and existing tooling still apply.
32. As a maintainer, I want structured per-job logging via journald, so that I
    keep the operational visibility the persistent model had.
33. As a maintainer, I want the persistent path kept behind an explicit opt-in,
    so that the migration is reversible and not a hard cutover.

## Implementation Decisions

- **Language boundary (Go vs bash).** Go is used **only** where the official
  scale-set client requires it — the listener "brain". Everything else stays in
  the repo's native bash, reusing existing seams (`_gh`, `RUNNER_HOME`/SEC-3,
  `schedule-cleanup`). The boundary is a single shell-out: the Go listener, per
  acquired job, invokes the bash container provisioner with explicit parameters.
  - **Go modules**: JIT Minter (over the client's `GenerateJitRunnerConfig`);
    Listener loop (injectable `Session`, ack-on-acquire, per-job failure
    isolation); Concurrency controller + capacity detector (bounded pool,
    locally-derived capacity, hardware auto-sizing); Runner-type config loader
    (authoritative parser; passes per-job params to bash).
  - **Bash modules**: Container provisioner (hardened single-use container,
    `--device` passthrough, naming/labels, no socket by default); Reaper
    (orphan containers + stale temp dirs + per-job lifetime); Build seam
    (daemonless Kaniko/BuildKit); Job history store (capture hook, append-only
    ledger, log/`_diag` archive, query, retention, external-push seam).
- **Deep modules / interfaces.** `JITConfigMinter.Mint(req) -> encodedConfig`;
  `Session` (the long-poll surface, mockable); the concurrency controller
  exposes acquire/release + `Capacity()` derived from a stubbable capacity
  detector; the config loader exposes `Load() -> []RunnerType` + validation; the
  history store exposes append / query / prune over a single durable store.
- **Container engine: single rootful Docker.** Rootless Docker/Podman rejected
  (#82 evaluated): device passthrough + `--privileged` needs break rootless
  (no `--privileged`, broken GPU CDI, no USB hotplug) and would force two
  daemons. Security is delivered by the architecture (sandboxed job, no socket)
  + per-type sandbox knobs, not by rootless.
- **JIT minting is the Go client's job**; the first-pass bash JIT seam and the
  orphaned bash run seam are removed (named-once doctrine).
- **Concurrency is auto-sized** from host capacity and reported from a local
  in-flight count, not the server's `TotalAssignedJobs`.
- **Per-runner-type config** maps one type to one homogeneous scale set; config
  is read authoritatively by the Go loader and relevant fields passed to bash.
- **Job history captured before teardown**, never storing secrets, bounded by
  size (GB) + age (days) via the existing `schedule-cleanup` harness.

## Testing Decisions

- **TDD throughout** — every module is built test-first (red → green → refactor).
- **Good tests assert external behavior, not implementation.** Go deep modules
  (minter, listener loop, concurrency, config loader) are tested in isolation
  with **fake `Session` / mock minter / recording provisioner / stub capacity
  detector** — asserting demand→provision, capacity arithmetic, ack timing,
  failure isolation, validation outcomes. Bash seams are tested with **bats
  stub-and-capture** (stub `docker`/`podman`/`run.sh` on PATH, capture argv),
  asserting hardening flags, device passthrough, no socket mount, naming/labels,
  reaper sweeps, history records (incl. secret redaction) and retention caps.
- **Prior art**: `test/bats/unit/runner_service.bats`, `runner_config_jit.bats`,
  `runner_container.bats` (stub-and-capture); the listener `*_test.go`
  fake-session tests. Do **not** use the `run bash -c "source X; func"` pattern.
- The Go module is built/vetted/tested **in a container** in CI and gates merges.

## Out of Scope

- **ARC / Kubernetes** — no k8s; rejected as over-engineering for a single host.
- **Universal rootless / Podman** — rejected for device/privileged workloads.
- **Live multi-tenant autoscaling beyond a single host** — single-host fleet.
- **Sandbox runtimes (gVisor/Kata/Sysbox/userns-remap) enablement** — plumbed as
  future per-type knobs (tracking #91), not enabled by default in this scope.
- **External history backends** — only the push seam (no-op default) is in scope;
  concrete Loki/ELK/object-storage shippers are later.
- Inbound webhook autoscaling — the scale-set client is outbound long-poll only.

## Further Notes

- Ephemeral isolation is **additive** to the ADR-0011 (isaac) approval gate; the
  gate controls *who* may run code, ephemeral controls *cross-job contamination*.
- Known residual: device (GPU/USB) runners remain rootful with precise
  `--device` passthrough — a conscious trade-off recorded in ADR-0001, mitigated
  by the approval gate.
- The 48 published issues (#84–#131) map to this PRD; reconcile against it rather
  than recreating.
