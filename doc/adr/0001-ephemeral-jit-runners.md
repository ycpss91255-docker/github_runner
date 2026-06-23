# 0001 — Ephemeral JIT runners via Runner Scale Set Client, one fresh container per job

- **Status**: accepted — supersedes the persistent systemd-service runner model; implementation is phased, not a flag flip
- **Date**: 2026-06-23

## Context

github_runner today provisions **persistent** self-hosted runners: `config.sh`
registers a runner once (writing the `.runner` marker) and `svc.sh install` runs
it as a long-lived systemd service that processes an unbounded sequence of jobs.
The repos served are currently trusted/private, but that is **not guaranteed to
stay true**.

Untrusted *fork* code is already gated at admission by the outside-collaborator
approval gate (ADR-0011 in the isaac repo — the two GitHub knobs documented in
the README "Security model"). The threats that remain **unaddressed** are
intrinsic to the persistent model:

- **State residue / poisoning between jobs** — a shared `_work` tree and
  root-owned residue from a prior job can poison the next checkout (issue #77).
- **Secrets surviving across jobs** — credentials left in env / cache / disk on
  the same runner are readable by the next job.

These classes cannot be *eliminated* by cleanup; they are a direct consequence
of one runner serving many jobs. GitHub's own guidance is explicit:
*"autoscaling with persistent self-hosted runners is not recommended"* —
ephemeral runners are recommended because GitHub assigns at most one job per
runner.

## Decision

Move from persistent runners to **ephemeral, just-in-time (JIT) runners**: each
runner serves exactly one job, then de-registers. Specifically —

- **Orchestration**: the official **Runner Scale Set Client** (`actions/scaleset`,
  Go). It maintains the outbound long-poll scale-set session and reports demand
  (`TotalAssignedJobs`); we supply the provisioning logic. No inbound webhook
  endpoint is exposed.
- **Isolation depth**: each job runs in a **fresh, single-use container** (tying
  into #82, rootless Docker/Podman), torn down after the job.
- Ephemeral isolation is **additive** to ADR-0011's approval gate, not a
  replacement: the gate controls *who* may run code; ephemeral controls
  *cross-job contamination after admission*.

## Considered options

- **Stay persistent + per-job cleanup (#77)** — lowest cost, keeps the systemd
  architecture, but only *reduces* residue, never eliminates the residue/secret
  classes. Rejected: does not meet the isolation goal.
- **ARC (Actions Runner Controller)** — GitHub's primary recommended autoscaler,
  but **Kubernetes-native** (*"recommended for organizations with Kubernetes
  infrastructure and teams that have Kubernetes expertise"*). We run a single
  shell-based host with no k8s; adopting ARC means operating a Kubernetes
  cluster purely for the official badge. Rejected: over-engineering for this
  scale.
- **DIY supervisor loop** (`--ephemeral` / `--jitconfig` + systemd
  `Restart=always`) — simplest, pure-bash, closest to the current codebase, but
  not an official autoscaler product. Rejected in favour of the official
  scale-set client for first-class lifecycle management and forward alignment
  with the scale-set API.

## Consequences

- **New Go dependency** in a previously bash-only + bats repo: the scale-set
  listener (vendored binary or a thin integration). Affects the toolchain (#78).
- **Provisioning logic is ours to write.** The scale-set client orchestrates
  *when / how many* runners; it does **not** provide the per-job container
  lifecycle — that isolation is implemented by us, and is where the
  residue/secret guarantees actually land. Choosing the scale-set client does
  not by itself buy isolation.
- **Supersedes the persistent model.** The `config.sh`-once + `svc.sh install`
  systemd path (`runner-config.sh` register-once, `runner-service.sh`,
  `add-runner.sh`) is replaced by a scale-set listener + per-job container
  provisioner. Migration is phased.
- **Glossary changes** (CONTEXT.md): "Runner" is no longer "install + a systemd
  service"; "Configured = `.runner` marker present" no longer holds for JIT
  (config is server-generated and single-use). New canonical terms: Ephemeral
  runner, JIT config, Scale set, Runner Scale Set Client.
- **Advances open security issues**: #80 (no long-lived registration token on the
  host — JIT configs are server-side single-use), #77 (residue eliminated rather
  than scrubbed), #82 (rootless per-job containers).

## References

- ADR-0011 (isaac) — outside-collaborator approval gate / public-repo security;
  the admission-time control this decision is *additive* to.
- GitHub Docs — [Autoscaling with self-hosted runners](https://docs.github.com/actions/hosting-your-own-runners/autoscaling-with-self-hosted-runners),
  [Self-hosted runners reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners),
  [Actions Runner Controller](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller),
  [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use).
- [`actions/scaleset`](https://github.com/actions/scaleset) — Runner Scale Set Client.
- Issues: #77 (workspace residue poisoning checkout), #80 (operator secrets on
  the runner host), #82 (rootless Docker/Podman).
