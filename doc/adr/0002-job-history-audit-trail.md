# 0002 — Job history / audit trail for ephemeral runners

> Serves: Invariant 1 — Never fail silently

- **Status**: Amended (2026-06-29, #154)
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
  - **Per-job record** (#154): the trusted, redacted ledger line mirrored into
    `jobs/<id>/record.tsv` — the only per-job artifact retention prunes and the
    push seam ships.
  - ~~**Archive**: full container stdout/stderr + the runner `_diag` logs.~~
    **Superseded by #154 (see below): the durable store no longer ingests any
    attacker-controlled raw job output.**
- **Storage**: under `RUNNER_HOME/history/` (+ ledger lines mirrored to
  journald). A **pluggable push seam is reserved** for shipping to an external
  store (Loki / ELK / object storage) later; local is the v1 default.
- **Management / query**: a dedicated script (e.g. `history.sh` /
  `status.sh --history`) to look up by job id / time / repo / outcome, and to
  organize/prune the store.
- **Retention**: bounded by **both a size cap (GB) and an age (days)**,
  oldest-first eviction, reusing the `schedule-cleanup.sh` harness. Defaults
  configurable (e.g. 20 GB / 30 days).

## Amendment (#154) — the durable store keeps only TRUSTED metadata

The original decision archived **full container stdout/stderr + the runner
`_diag` logs**. A red-team round (#140, #141, #143, #145, #146, #149, #150,
#151, #152, #153) showed this is **not safely achievable**: that data is *fully
attacker-controlled* (the job writes its own stdout/stderr, and `_diag` lives
inside the read-write `/runner` bind mount — content **and** file/dir names), so
"archive it but scrub the secrets first" is a non-convergent arms race. Each
content/name scrubber was bypassed by a new encoding (cross-line splits,
sub-16-char chunks, path-component chunking, bare values, symlink swaps), and one
scrub even put the live credential back on a host `sed` argv (#146).

The resolution is to fix the **root cause**, not add another scrub pass:

- **The durable store never ingests attacker-controlled raw streams.** The
  container's stdout/stderr is **not** durably persisted on the host — its
  authoritative copy already lives in GitHub's job console log (~90 days). This
  *supersedes* the "archive full container stdout/stderr" intent above, and the
  fragile content/name scrubbers are **deleted**.
- **`_diag` is captured only from a trusted, non-job-writable path, safely** (no
  symlink follow, anchored strictly under `RUNNER_HOME`, attacker-chosen names
  neutralised, treated as sensitive). In today's architecture the only `_diag`
  available lives *inside* the job-writable `/runner` mount, so there is **no
  trusted source** — and per policy we **prefer not capturing it** over capturing
  it unsafely. So `_diag` is not archived either.
- **The push hook ships only the trusted ledger metadata** — never raw job
  output, never anything the job could have written. The whole store is `0700`.
- **Credential reachability:** the enforced boundary is "the JIT credential must
  not survive teardown or leave the container." We accept that the single-use
  container's sole tenant can read its own already-redeemed credential; what we
  guarantee is that it reaches **no host-side durable sink** — neither the
  history store nor the listener's journald stdout (the container run's output is
  sent to `/dev/null`, not forwarded to provision-job's stdout).

Net: the durable store now holds **only trusted metadata** (ledger + per-job
`record.tsv`). Forensic "logs" are deferred to GitHub's console log; the
self-hosted execution context (host / image+digest / runner type / device /
outcome / trigger) is fully retained in the ledger.

## Alternatives

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
