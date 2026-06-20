# Host hardening runbook

Operational steps for the machine that runs a self-hosted GitHub Actions
runner. Companion to the README ["Security model"](../../README.md#security-model)
section, which explains *why* these matter.

## The one rule that surprises people

The runner service user is in the `docker` group, which is **root-equivalent**
(`docker run -v /:/host …` reaches the whole host). A consequence that is easy
to get wrong:

> **A dedicated CI user is not a security boundary on its own.**

While that user is in the `docker` group, the defenses people reach for — a
separate login, a clean home directory, `chmod 600 ~/.ssh` — are cosmetic. Any
job that runs can `docker run -v /:/host …` and read `~/.ssh`, cloud
credentials, and tokens regardless of file ownership or the user it runs as.

A dedicated CI user only becomes a real boundary when paired with **one** of:

1. **Rootless Docker / Podman** — the daemon runs as the unprivileged CI user
   with no `docker` group, so the user genuinely cannot read root/other-user
   files. This is the documented upgrade path; the friction is GPU passthrough
   (NVIDIA Container Toolkit + CDI) and docker-in-docker.
2. **Host holds no secrets** — accept root-equivalence, but make the box
   CI-only so there is nothing worth stealing. Operator SSH keys / dev identity
   live on the workstation, not the runner host.

Neither knob alone closes the gap: a CI user *plus rootless*, or a CI user
*plus host-no-secrets*.

## Checklist

- [ ] Runner runs as a **dedicated CI user**, no `sudo`, home directory free of
      personal state.
- [ ] **No operator secrets on the host**: no personal SSH private keys, cloud
      credentials, account-wide PATs, kubeconfigs, or `~/.ssh` reachable on the
      box. Inventory first (`~/.ssh/*`, `~/.aws`, `~/.config`, `~/.kube`, …).
- [ ] Any secret that *sat* on the host while it was exposed is **re-keyed**
      (treat as potentially compromised).
- [ ] Any git push / deploy the CI needs uses a **per-repo deploy key or
      fine-grained PAT**, minimal scope, injected per-job via Actions Secrets —
      not a long-lived key on disk.
- [ ] Operator SSH identity uses a **hardware key** (FIDO2 `sk-ed25519` /
      YubiKey) so private key material is not extractable from any host it
      touches.
- [ ] Runner is **ephemeral** (one job per registration) + clean workspace each
      run, so a compromise cannot persist across jobs.
- [ ] Host is **network-isolated** (egress firewall / dedicated VLAN) so a
      compromise cannot pivot to other machines.
- [ ] Org safety knobs verified: outside-collaborator **approval gate** ON +
      runner-group `allows_public_repositories` consistent (enforced by
      `add-runner.sh`; surfaced by `status.sh`).
- [ ] Self-hosted GPU jobs are **gated to same-repo refs** so forked-PR code
      never reaches the host (see the org reusable workflow
      `gpu-self-hosted.yml`; e.g. `ycpss91255-docker/isaac`).
- [ ] (Upgrade) Evaluate **rootless Docker / Podman** to drop the
      root-equivalent premise entirely — at which point the dedicated CI user
      becomes a genuine boundary.

## Why a separate CI user feels safe but isn't

`A` controls *who* may run code on the host (the same-repo gate, the org
approval gate). `C` — this runbook — bounds *blast radius once code runs*. They
are different layers: gating fork PRs off the host does not protect the host
from your own merged code, or from a supply-chain compromise in a build
dependency, both of which still execute root-equivalent. A separate CI user
addresses neither until it is paired with rootless or host-no-secrets.
