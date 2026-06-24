# 0002 — Job history / audit trail for ephemeral runners

- **Status**: accepted
- **Date**: 2026-06-23

## Context

Ephemeral runners (ADR-0001) destroy the container and runner after **every**
job — that is the point (zero residue). But when something goes wrong, operators
need to trace what happened: which host / runner / image / devices ran a job,
its outcome, and its logs. GitHub retains job *console* logs (~90 days) but
**not** the self-hosted execution context (host, container, image digest,
device, runner `_diag`). Ephemeral teardown destroys that context unless it is
captured first.

This is a direct tension with ADR-0001: ephemeral exists to leave nothing
behind, yet forensics needs evidence. The resolution is to capture the evidence
**out-of-band, before teardown** — not to keep the container around.

## Decision

Capture job forensics **before the container is torn down**, into a durable
local store, with a management/query tool and bounded retention.

- **Capture hook**: a step in the provisioner lifecycle that runs **before the
  container is removed**, on **every** job (success and failure) — full records,
  per the requirement.
- **What is stored**:
  - **Ledger** (append-only): job id, scale set / labels, image + digest, host,
    runner type, device(s), start / end, duration, exit status, trigger (repo /
    workflow / commit / actor). **Never the JIT config / any secret.**
  - **Archive**: full container stdout/stderr + the runner `_diag` logs.
- **Storage**: under `RUNNER_HOME/history/` (+ ledger lines mirrored to
  journald). A **pluggable push seam is reserved** for shipping to an external
  store (Loki / ELK / object storage) later; local is the v1 default.
- **Management / query**: a dedicated script (e.g. `history.sh` /
  `status.sh --history`) to look up by job id / time / repo / outcome, and to
  organize/prune the store.
- **Retention**: bounded by **both a size cap (GB) and an age (days)**,
  oldest-first eviction, reusing the `schedule-cleanup.sh` harness. Defaults
  configurable (e.g. 20 GB / 30 days).

## Considered options

- **Rely on GitHub Actions logs only** — rejected: lacks the self-hosted
  execution context and is retention-limited; no host-level forensics.
- **Capture only on failure** — rejected by requirement (full records for every
  job are wanted).
- **Keep the container around for inspection** — rejected: violates ADR-0001's
  zero-residue guarantee.

## Consequences

- Adds disk usage, **bounded by the dual retention cap** (size + age), enforced
  so history cannot fill the disk — avoiding a new "residue" failure mode.
- Capture must **never** persist the JIT config or other secrets.
- Couples to the provisioner teardown ordering (**capture-before-`rm`**) and to
  the container labelling the reaper uses (job-id correlation).
- The external-push seam is **designed but not implemented** in v1.

## References

- ADR-0001 — ephemeral runner design (the teardown this captures before).
- Existing `schedule-cleanup.sh` / `cleanup.sh` retention harness.
