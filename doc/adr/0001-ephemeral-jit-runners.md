# 0001 — Ephemeral JIT runners via Runner Scale Set Client

- **Status**: accepted — supersedes the persistent systemd-service runner model; implementation is phased. Revised after the security / system / code design review.
- **Date**: 2026-06-23

## Context

github_runner today provisions **persistent** self-hosted runners: `config.sh`
registers a runner once (writing the `.runner` marker) and `svc.sh install` runs
it as a long-lived systemd service that processes an unbounded sequence of jobs.
The repos served are currently trusted/private, but that is **not guaranteed to
stay true**.

Untrusted *fork* code is already gated at admission by the outside-collaborator
approval gate (ADR-0011 in the isaac repo). The threats that remain
**unaddressed** are intrinsic to the persistent model:

- **State residue / poisoning between jobs** — a shared `_work` tree and
  root-owned residue from a prior job can poison the next checkout (issue #77).
- **Secrets surviving across jobs** — credentials left in env / cache / disk on
  the same runner are readable by the next job.

These cannot be *eliminated* by cleanup; they are a direct consequence of one
runner serving many jobs. GitHub's guidance is explicit: *"autoscaling with
persistent self-hosted runners is not recommended"* — ephemeral runners are
recommended because GitHub assigns at most one job per runner.

## Decision

Move to **ephemeral, just-in-time (JIT) runners**: each runner serves exactly
one job, then de-registers.

- **Orchestration**: the official **Runner Scale Set Client** (`actions/scaleset`,
  Go), outbound long-poll, no inbound webhook. It is **built and tested only
  inside a `golang` container**, so the host needs **no Go toolchain**.
- **Listener runtime**: runs as a **host process under a non-privileged CI user,
  supervised by systemd (`Restart=always`)** — *option (a)*. It is deliberately
  **not** containerized: containerizing it would require mounting a container
  socket into the listener (root-equivalence), which on a single host without
  k8s mediation is ARC's shape without ARC's safety.
- **JIT minting**: the Go client's **`GenerateJitRunnerConfig`** is the single
  canonical minting path. The bash JIT seam built in the first implementation
  pass is removed.
- **Concurrency**: a **bounded worker pool sized automatically from host
  capacity** (e.g. GPU / device count), reporting **locally-derived** capacity —
  not the server's `TotalAssignedJobs`.
- **Per-job isolation**: each job runs in a **fresh, single-use container** torn
  down after the job.

Ephemeral isolation is **additive** to ADR-0011's approval gate: the gate
controls *who* may run code; ephemeral controls *cross-job contamination after
admission*.

## Container runtime & security posture

- **Engine: a single rootful Docker daemon** (the host's existing Docker). We
  evaluated rootless Docker / Podman (#82) and **rejected rootless as the
  universal default**: device-bound runners (GPU / USB / special hardware) need
  device passthrough and sometimes `--privileged`; rootless Docker cannot run
  `--privileged`, has broken/fiddly GPU (CDI) and USB passthrough (no hotplug),
  and would force maintaining two daemons.
- **Security comes from the architecture, not from rootless.** The untrusted
  thing — the job — runs inside a throwaway container that, by default, does
  **not** receive the Docker socket. So the "runner in the `docker` group = host
  root" exposure (#82) is **no longer reachable by job code**; the listener that
  holds Docker access runs only our trusted code.
- **Defense-in-depth on every job container**: `--cap-drop=ALL` (+ minimal
  add-back), `--security-opt no-new-privileges`, default seccomp kept, MAC
  (SELinux/AppArmor) kept **enforced** (no `label=disable`; use `:Z` relabel for
  mounts), `--pids-limit`, non-root in-container user where possible.
- **DinD / image builds**: **never mount the host Docker socket** into a job.
  Image builds use a daemonless rootless builder (**Kaniko / BuildKit-rootless /
  Buildah**). Jobs that genuinely need an inner daemon use **Sysbox** or rootless
  DinD-in-container.
- **Per-type sandbox knobs**: stronger isolation runtimes (**gVisor / Kata
  microVM**) and **userns-remap** are available as per-runner-type escalations
  for genuinely untrusted CPU runners (Kata is the lightweight path back to
  per-job-VM isolation). Not enabled by default given the current trusted-repo +
  ADR-0011 gate.
- **Hardware-runner residual**: sandbox runtimes + device passthrough don't
  always coexist; device runners stay rootful with **precise `--device`
  passthrough** + baseline hardening and rely on the ADR-0011 approval gate to
  keep unapproved untrusted code from reaching them. A conscious, documented
  trade-off.

## Per-runner-type configuration

Runners are heterogeneous (GPU now; many types later). Each runner type is one
config entry: `{ labels, image, device passthrough, runtime, build tool,
hardening profile, auto-sized concurrency }`, mapping to **one GitHub scale set
per type** (scale sets are homogeneous). Start with the GPU type; adding a type
is a new config entry, not a code change.

## Considered options

- **Stay persistent + cleanup (#77)** — rejected (reduces, never eliminates the
  residue/secret classes).
- **ARC** — rejected (Kubernetes-native; we have no k8s).
- **DIY supervisor loop** — rejected (non-official; weaker lifecycle management).
- **Rootless Docker / Podman as the universal engine** — rejected (breaks
  device/privileged workloads; two-daemon burden). Security is achieved via the
  architecture + per-type sandbox knobs instead.
- **Containerized listener (option b)** — rejected (mounting a container socket
  reintroduces root-equivalence).

## Consequences

- Go enters the repo but is **built/tested only in containers**; host needs no
  Go. CI gains a Go job (#78 toolchain).
- Provisioning + lifecycle (concurrency, supervision, container/temp reaping,
  job history) are **ours to implement**; the scale-set client only decides
  when / how many.
- **Supersedes** the persistent path (`config.sh`-once + `svc.sh`); migration is
  phased. The bash JIT seam from the first pass is removed in favour of the Go
  client's minting.
- **Glossary changes** (CONTEXT.md): canonical terms — Ephemeral runner, JIT
  config, Scale set, Runner Scale Set Client, runner-type config.
- **Advances** #80 (no long-lived token on host), #77 (residue eliminated), #82
  (root-equivalence not reachable by job code; rootless evaluated and scoped).
- **Forensic tension**: ephemeral destroys evidence on teardown → addressed by
  **ADR-0002** (job history captured before teardown).

## References

- ADR-0011 (isaac) — outside-collaborator approval gate / public-repo security.
- GitHub Docs — [Autoscaling with self-hosted runners](https://docs.github.com/actions/hosting-your-own-runners/autoscaling-with-self-hosted-runners),
  [Self-hosted runners reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners),
  [Actions Runner Controller](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller).
- [`actions/scaleset`](https://github.com/actions/scaleset) — Runner Scale Set Client.
- [Docker Rootless mode](https://docs.docker.com/engine/security/rootless/) and its
  [device/GPU limitations (NVIDIA CDI)](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html).
- Secure DinD without privilege — [Kaniko](https://www.gocodeo.com/post/what-is-kaniko-building-container-images-without-docker-daemon),
  Sysbox; container-escape isolation — [gVisor / Kata](https://www.systemshardening.com/articles/linux/linux-container-runtime-alternatives/).
- Issues: #77 (residue), #80 (operator secrets on host), #82 (rootless / docker-group root-equivalence).
