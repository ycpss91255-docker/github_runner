# 0004 — Defer Kubernetes; stay bespoke now, migrate at defined tripwires

> Serves: mechanism, no corresponding invariant

- **Status**: Accepted
- **Date**: 2026-07-07

## Context

While discussing "run many runners on one host to parallelize and use idle
resources", the *feature* ambitions (dynamic resource-aware packing, GPU
sharing, GitHub **and** GitLab, multi-host expansion) pointed at **Kubernetes**,
which is exactly what k8s is built for. But weighing that against **scale and
maintenance cost** flipped the near-term answer. This ADR records the decision
and — importantly — the concrete facts that drove it, so the team does not
re-litigate it every few months.

### Facts provided by the operator (recorded verbatim in substance)

- **Team / usage**: ~**10–20 people** using it for **test/CI** → that many need
  runners.
- **Load**: concurrent running-job **peak is roughly single-digit to low-teens**.
- **Runner intent**: a **generic / universal** runner. Two wishes:
  1. If possible, also usable for **GitLab** (a *future possibility*, not a
     current requirement).
  2. The workload is **not fixed as CPU or GPU** — it varies by application; the
     system should **adjust** rather than be pinned to one.
- **"Idle resources" they want to use**: e.g. a GPU job is running but the **CPU
  sits idle**; wanting to run **many jobs on one GPU**; wanting **CPU or GPU to
  carry multiple jobs**.
- **Control preference**: **dynamic**, not static — static sizing "goes stale
  easily and has high maintenance cost".
- **Hosts today vs future**: currently single-host, but **multi-host expansion
  is expected**.
- **Fleet is highly heterogeneous**: confirmed mix of **Raspberry Pi, Jetson,
  IPC, server, notebook, desktop PC** (mixed arch ARM/x86; some GPU/edge; some
  **intermittent** — notebooks / desktops are not always on).
- **Two job-placement classes**:
  - **A — pinned to specific hardware/platform**: the job *must* run on that
    device (device-under-test / platform-required). Placement is fixed.
  - **B — generic compute worker**: the job can run anywhere with capacity;
    **servers still differ from each other** (heterogeneous B pool).
  - **Ratio: currently A:B ≈ 7:3**, expected to keep shifting toward **3:7 or
    2:8** (B-dominant). **Only jobs that require a specific platform go to A.**

### Cost/benefit reading

- **k8s cost ≈ a fixed operational tax** (cluster upgrades, YAML/RBAC,
  networking/storage, GPU device-plugin, and "cluster down = everyone's CI
  stops" on-call), roughly the same whether you run 5 jobs or 500. <!-- doc-lint-allow -->
- **k8s benefit scales with fleet size, heterogeneity, and dynamism.**
- **Today** (A-dominant, ~10–20 users, low peak): A placement is fixed by
  hardware, so the headline k8s benefit (dynamic bin-packing) barely applies →
  **benefit < cost → not worth it yet.**
- **Trajectory** (B-dominant + heterogeneous servers + growth): "match a job to a
  capable *and* free server" is k8s's core competency → **the tax starts paying
  off.** So k8s is the likely **destination**, not a "never".

## Decision

**Stay bespoke now. Treat k8s (k3s + ARC, and a GitLab Kubernetes executor if
GitLab ever materializes) as the planned eventual destination. Migrate when
defined tripwires fire, and keep the bespoke layer thin so the migration stays
cheap.**

Concretely for now:
- **B jobs** on a few heterogeneous servers → one bespoke listener **per host**,
  each locally auto-sized, jobs routed by label. Do **not** build a bespoke
  cross-host scheduler (k8s would replace it — wasted effort).
- **A jobs** → label-route to the specific device, as today.
- **Do not adopt k8s/k3s in production yet.**

## Alternatives

- **Full k8s now** — rejected: over-engineering for 10–20 users / low peak; heavy
  fixed tax with little benefit while A-dominant.
- **k3s now** — rejected as a production step: k3s lowers the *footprint* but not
  the *conceptual/operational* tax (still Kubernetes: YAML, ARC, upgrades, GPU
  plugin, debugging). Not justified yet. (Still endorsed as a **throwaway PoC**,
  see Consequences.)
- **Stay bespoke forever** — rejected: the B-dominant, heterogeneous-server,
  growing trajectory outgrows per-host bespoke management.
- **Bespoke now → migrate at tripwires (chosen)** — matches the trajectory while
  not paying the k8s tax before it's earned.

## Tripwires (start migrating when any one or two hold)

- **B ratio crosses ~50%** *and* the B server pool is **regularly saturated** at
  peak (you start *wanting* global "send it to whichever server has capacity").
- **B pool grows past ~5–8 servers** and manual per-host management / load
  imbalance becomes painful.
- A **hard** requirement appears for **global resource-aware scheduling** or
  **centralized GPU pooling/sharing** (not merely nice-to-have).
- **User count / job volume** grows enough that CI **queueing or imbalance**
  hurts the team.

Migrate **at** a tripwire, not after a crisis — the migration cost is roughly the
same now vs later, so the only way it becomes "too late" is doing it under fire.

## Consequences

- **Keep the bespoke layer thin.** The ADR-0003 boundary (minimal Go surface, one
  clean shell-out) already protects a cheap swap of the orchestration layer
  (bespoke listener → ARC).
- **A assets transfer unchanged.** k8s subsumes both classes: **A** via
  `nodeSelector` / taints pinning a pod to a specific labeled node; **B** via the
  scheduler bin-packing across the heterogeneous pool by `requests`/`limits`. So
  migrating does not discard the pinned-device capability.
- **Intermittent nodes (notebooks / desktops) stay loose.** They are awkward for
  k8s (node churn) and unreliable as always-on runners; keep them as opportunistic
  bespoke runners (or out of any future cluster), not cluster nodes.
- **Low-cost de-risking now (recommended):** stand up a **throwaway k3s + ARC
  PoC** on one spare server to build familiarity, so a tripwire migration is not
  a cold start. High option-value, low cost.
- **GPU one-card-many-jobs** stays per-host (time-slicing / MIG) until k8s lands;
  k8s later centralizes it via the NVIDIA device plugin.

## References

- [k8s migration primer](../k8s-migration-primer.md) — learning path + concept
  mapping (bespoke ↔ k8s).
- [ADR-0001](0001-ephemeral-jit-runners.md) (ephemeral design),
  [ADR-0003](0003-go-bash-boundary.md) (the boundary that keeps migration cheap).
- [Actions Runner Controller (ARC)](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller),
  [k3s](https://docs.k3s.io/),
  [GitLab Kubernetes executor](https://docs.gitlab.com/runner/executors/kubernetes/).
