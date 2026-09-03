# 0005 — Reactive live-admission for runner concurrency

- **Status**: accepted
- **Date**: 2026-09-03

## Context

Runner concurrency was a frozen number: `deploy/runner-types.sample.yaml` pinned
the CPU type to `concurrency: { mode: fixed, count: 4 }`, and the listener sized
a fixed worker-pool semaphore once at startup. Issue #159's grill concluded that
hand-typing this "roster" cannot manage a host well: the right number depends on
the host's live capacity and on what co-tenants (a research runner, a GitLab
runner, GPU workloads) are doing right now, and it goes stale the moment hardware
or load changes. The operator's steer was explicit: opening a runner slot must be
**dynamic, not hand-maintained** — manual maintenance cannot manage runners.

This ADR records the decision for the CPU/RAM case (#163). GPU/VRAM is a separate,
stricter follow-up (#164): VRAM overshoot is an OOM (the job dies), not a
recoverable slowdown like CPU thrash, so it needs its own tighter band and keeps
the existing device-count path untouched for now.

## Decision

**Admit each job reactively against a live per-resource reading, keeping a
reserve headroom free, so the concurrent-runner count emerges instead of being
configured.**

- **Per-resource reserve.** Before a job starts, every resource (CPU, memory)
  must keep at least `reserve` percent free, checked independently — the scarcest
  resource is the binding constraint (#159 Q1a). Default reserve is **10%**; it is
  the **only operator knob**, and it is **upward-only** (raise it to leave more
  room for co-tenant work; values 1–9 are rejected).
- **No stored N, no per-workload cost table.** The old `count` and the
  `MAX_RUNNERS` operator knob are retired. The one coarse global floor is a
  per-job CPU **footprint of `1/nproc`**, used only to predict a burst.
- **CPU predicted, memory raw.** loadavg lags a burst (just-started jobs are not
  yet in the 1-minute average), so CPU headroom is discounted by
  `(inFlight+1) * footprint`. MemAvailable is instantaneous, so memory is checked
  raw.
- **Far vs near the line.** Far from the reserve, jobs are admitted freely (cheap
  jobs and bursts sail through). Near it, admission serialises: admit one, wait a
  short **settle window** (default 3s) for the reading to reflect it, re-probe.
  The near-line margin is not a separate tuned constant — it is one footprint
  wide, implicit in the admission arithmetic.
- **Two gate points.** `capacityFor` reports the live admittable count to GitHub
  per poll (a batch far from the line, 1 near it, 0 over it); `provision` runs the
  same check before each container so a single matrix message brakes mid-batch.
- **Safety ceiling, not a roster.** The worker-pool semaphore stays, sized
  internally from the host CPU count — it only bounds goroutines; the reactive
  gate is the real limiter. The operator cannot set it.
- **Fail safe.** A probe error admits (the semaphore backstops; stranding
  acquired work is worse than a brief over-admit) and reports a conservative
  capacity of 1 (never 0, which would starve). Context cancellation unblocks a
  parked admission so shutdown never hangs on a full host.
- **Go decides, bash reads.** The admission decision lives in the Go listener
  (ADR-0003 already scopes "the concurrency pool / capacity" to Go). The host
  reading is a thin shell-out, `listener/host-probe.sh`, emitting `loadavg1 /
  nproc / mem_total_kb / mem_available_kb`; Go holds only the numbers and the
  arithmetic.

Empty `concurrency` therefore means reactive (dynamic by default). A GPU type opts
into device-count sizing with an explicit `mode: auto`.

## Considered options

- **Predictive precompute-N.** Compute N up front from host capacity ÷ per-job
  cost and run a fixed pool. Rejected: it needs a per-workload cost table that is
  exactly the hand-maintenance the operator ruled out, and N goes stale on any
  change.
- **Single blended utilisation metric** (e.g. keep overall utilisation ≤ 90%).
  Rejected: it hides a single saturated resource — a job could exhaust memory
  while "overall" still looks fine.
- **A coarse single global per-job reservation** debited on admit. Kept only as a
  possible future refinement; the per-resource live check plus the `1/nproc`
  footprint covers the burst case without another maintained number.

## Consequences

- The coarse `1/nproc` footprint can under-admit genuinely cheap jobs on
  small-core hosts (they are treated as ~one core each). A future measured /
  adaptive refinement can tighten the footprint; it is not load-bearing today.
- There is a small settle latency near the line, by design (back-pressure). Real
  waiting only happens when the host is actually full, where running more would
  make every job slower.
- A co-tenant that grows *after* admission can briefly cross the reserve; reactive
  admission corrects on the next decision, and ephemeral jobs finish and
  self-heal, so the breach is a tolerated transient.
- Reduced surface to maintain: one policy (reserve %) instead of a per-host,
  per-type roster.

## References

- #159 (derive host concurrency), #163 (this change), epic #165; follow-up #164
  (reactive GPU/VRAM, stricter band).
- ADR-0003 (Go/bash boundary): admission in Go, `/proc` reading in bash.
- `listener/hostprobe.go`, `listener/host-probe.sh`, `listener/listener.go`
  (`capacityFor`, `admitOne`, `provision`, `resolveBound`).
