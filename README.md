# github_runner

[![CI](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml/badge.svg)](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml)
![Language](https://img.shields.io/badge/Language-Bash-blue?style=flat-square)
![Testing](https://img.shields.io/badge/Testing-Bats-orange?style=flat-square)
![ShellCheck](https://img.shields.io/badge/ShellCheck-Compliant-brightgreen?style=flat-square)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](./LICENSE)
[![codecov](https://codecov.io/gh/ycpss91255-docker/github_runner/branch/main/graph/badge.svg)](https://codecov.io/gh/ycpss91255-docker/github_runner)

**[English](README.md)** | **[繁體中文](doc/readme/README.zh-TW.md)** | **[简体中文](doc/readme/README.zh-CN.md)** | **[日本語](doc/readme/README.ja.md)**

---

## Table of Contents

- [TL;DR](#tldr)
- [Overview](#overview)
- [Layout](#layout)
- [Scripts](#scripts)
- [Configuration](#configuration)
- [Testing](#testing)
- [Security model](#security-model)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Verifying a runner](#verifying-a-runner)
- [Upgrading the runner binary](#upgrading-the-runner-binary)
- [Uninstall](#uninstall)
- [Rebuild SOP](#rebuild-sop)
- [Troubleshooting](#troubleshooting)
- [References](#references)
- [License](#license)

## TL;DR

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
gh auth login --scopes admin:org        # if not already

./script/init.sh <your-org>             # prep host + register first runner
./script/add-runner.sh org <other-org>  # (optional) register another org runner
./script/status.sh                      # local + GitHub-side state
```

`<your-org>` is **your own GitHub organization** (the account name, e.g.
`my-company`) — not a repo and not this project's name. You need a GitHub org
you have **admin/owner** rights on. No org (a personal account)? Register a
repo-scoped runner instead — see [Quick start](#quick-start).

Two things to set up front, or the first run stops / your jobs sit queued:

- **Approval gate** — for an org runner, first enable *Settings → Actions →
  General → "Require approval for all outside collaborators"*, or
  `add-runner.sh org` refuses to register (pass `--force` to override). See
  Security model.
- **Labels** — the default label is `gpu`. On a non-GPU host, set a label
  first (`./script/configure.sh --labels <label>`) or jobs that don't target
  `gpu` will stay `queued` with no error.

Runner state installs under `<repo_root>/runners/` by default; override with
`RUNNER_HOME=...`.

## Overview

Tooling to provision, manage, and tear down self-hosted GitHub Actions
runners: register or remove org- and repo-level runners, install them as
systemd services, cache and upgrade the runner binary, report local +
GitHub-side state, and prune auto-update leftovers. One clone owns all runner
state under `<repo_root>/runners/`, and every script is idempotent.

The scripts are general-purpose -- pass any org or repo. The
`ycpss91255-research` and `ycpss91255-docker` orgs appear throughout only as
concrete examples (the orgs the author runs it for); nothing is hard-coded to
them.

## Layout

By default, all runner state lives in `<repo_root>/runners/` (alongside this
checkout, gitignored). One clone owns all the state -- no separate
`~/github_runner` directory:

```
<repo_root>/runners/                                   # default RUNNER_HOME
├── .bin/
│   └── actions-runner-linux-x64-<version>.tar.gz      # cached tarball
├── ycpss91255-docker/
│   └── _org/                                          # org-level runner
└── ycpss91255-research/
    └── _org/                                          # org-level runner
```

`_org` denotes "the org-level runner for this org". Repo-level runners would
live at `<org>/<repo>/` instead.

Override the install location by exporting `RUNNER_HOME` before invoking
any script (e.g. `RUNNER_HOME=/var/lib/gh-runners ./script/init.sh ...`).

## Scripts

| Script | Purpose |
|---|---|
| `script/install-deps.sh` | Install the CLI prerequisites (`gh`, `jq`, `curl`, `sudo`) on an apt/Ubuntu host and run `gh auth login`. `-y` accepts every install prompt; `--dry-run` reports what's missing. Docker + the NVIDIA Container Toolkit are assumed already installed. Idempotent |
| `script/init.sh` | Verify host prerequisites; resolve the actions/runner version (`RUNNER_VERSION=...` override, else the latest release via `gh api`, falling back to a pinned version when `gh` is missing / unauthenticated / offline), then download + cache the tarball into `<repo_root>/runners/.bin/` (i.e. `$RUNNER_HOME/.bin/`). If given a scope arg it also registers the first runner, forwarding it to `add-runner.sh` verbatim: `org <org>`, `repo <owner> <repo>`, or a bare org name as shorthand for the `org` form |
| `script/add-runner.sh` | Provision a runner. **Default = ephemeral / JIT**: `org <org>` / `repo <owner> <repo>` prints the scale-set listener path (one fresh, single-use container per job; no long-lived systemd service) and exits — see [`listener/`](listener/README.md). **`--persistent`** opts into the LEGACY systemd path (`config.sh`-once + `svc.sh install`), which the ephemeral default supersedes; under it, for `org` scope it verifies the outside-collaborator approval gate and flips `allows_public_repositories=true`, **refusing** if the gate is not set unless `--force` is given (see Security model). Labels come from `setup.conf` (default `gpu`) |
| `script/configure.sh` | Generate / update `${RUNNER_HOME}/setup.conf`. `--labels <csv>` sets the labels for newly registered runners; no args prints the current effective config |
| `script/set-labels.sh` | Relabel an already-registered runner live via the GitHub API (no remove + re-register). Usage: `org <org> <csv>` or `repo <owner> <repo> <csv>` |
| `script/remove-runner.sh` | Deregister + uninstall systemd service + remove directory. Prompts by default; `--yes` skips, `--dry-run` previews |
| `script/status.sh` | List all registered runners with local + GitHub-side state and their current labels. `-w`/`--watch` refreshes continuously (configurable `-i`/`--interval`, default 5s) with row-level diff highlighting; `--no-color` disables color |
| `script/update.sh` | Resolve the runner version (`RUNNER_VERSION=...` override or latest release, same fallback as init), download into the cache if absent, then seed the new versioned runner files into each runner dir (existing files are left in place); the runner picks up the new version via its normal self-update on next connect; preserves config |
| `script/uninstall.sh` | Counterpart to `script/init.sh`: tear down every runner registered through this checkout + remove the cached tarball. Prompts by default; `--yes` skips, `--dry-run` previews. Does NOT change org runner-group flags or remove the checkout itself (see #11) |
| `script/cleanup.sh` | Prune disk-heavy leftovers from GitHub's auto-update cycle: stale `bin.X` / `externals.X` version dirs, older cached tarballs in `${RUNNER_HOME}/.bin/`, `_work/_update*` remnants, and aged `_diag/*.log`. Safe to schedule; never touches registration state or in-flight job dirs. Prompts by default; `--yes` skips, `--dry-run` previews. Opt-in `--work-caches` also prunes old `_work/_tool` / `_work/_actions` cache entries for **idle** runners only (skips a runner with a running job; needs `pgrep`) |
| `script/schedule-cleanup.sh` | Install / remove a user-crontab entry that runs `cleanup.sh` on a schedule (daily / weekly / monthly, time and weekday selectable). Interactive prompts by default, or pass `--every` / `--at` / `--day`. `--status` shows the installed entry, `--uninstall` removes it. Output appends to `${RUNNER_HOME}/.cleanup.log`; concurrent runs are guarded by `flock` |

All scripts are idempotent.

## Configuration

Runner registration reads an optional config file at `${RUNNER_HOME}/setup.conf`
(`KEY=value`, shell-sourceable). Generate or update it with `script/configure.sh`:

```bash
./script/configure.sh --labels gpu,cuda12   # labels for newly registered runners
./script/configure.sh                         # print the current effective config
```

`LABELS` (default `gpu`) becomes the runner's custom labels at registration;
GitHub always keeps the system labels `self-hosted` / `Linux` / `X64`. Labels are
the routing key for `runs-on`: a job lands on a runner only when the job's
`runs-on` labels are a subset of that runner's labels.

`setup.conf` only affects runners registered after it is written. To relabel an
already-registered runner live (no remove + re-register), use `script/set-labels.sh`:

```bash
./script/set-labels.sh org ycpss91255-docker gpu,cuda12
./script/set-labels.sh repo <owner> <repo> gpu,cuda12
```

`script/status.sh` shows each runner's current labels in the `LABELS` column.

## Testing

Tests run inside the `ghcr.io/ycpss91255-docker/test-tools` image (alpine +
bats + shellcheck + hadolint, same image used by `ycpss91255-docker/base`).
Coverage runs inside `kcov/kcov` (Debian, ships `kcov`; `bats` is
apt-installed at run time). Local and CI runs share the same images.

The self-test entry is a root `justfile`, matching the base repo convention
(base migrated its self-test entry to `just`):

```bash
just pull       # pull test-tools + kcov images (once)
just lint       # shellcheck on all scripts (in docker)
just test       # bats smoke tests (in docker)
just check      # lint + test (no coverage)
just coverage   # bats with kcov coverage -> ./coverage/
just            # list recipes
```

If you prefer to run on the host (requires `shellcheck` / `bats` installed
locally):

```bash
just lint-host
just test-host
```

CI mirrors `just lint` + `test` on every push / PR and `coverage` on
push-to-main only (kcov is 2-5x slower than plain bats, so coverage is
reserved for release-quality signal). Codecov upload uses the
`CODECOV_TOKEN` repo secret.

## Security model

Public-repo dispatch on self-hosted runners has two GitHub knobs that
matter and must agree:

1. **Outside-collaborator approval gate** (org Settings -> Actions ->
   General -> "Require approval for all outside collaborators"). Blocks
   fork PRs from running arbitrary code on the runner until the maintainer
   clicks "Approve and run".
2. **Runner group `allows_public_repositories` flag** (Default group on
   each org). GitHub's 2024+ default is `false`, which silently keeps
   public-repo workflows queued forever even though the runner shows
   `online` + idle. `script/add-runner.sh org <org>` flips this to `true` so
   legitimate maintainer-triggered dispatches go through.

Both protections together are equivalent to the GitHub default: outside
contributors cannot run code on the runner without approval, but the
maintainer and trusted collaborators can. Closing one without the other
either re-strands public-repo jobs (knob 2 off) or re-opens the fork-PR
hole (knob 1 off). See #6 for the original analysis.

Because knob 2 lowers GitHub's safe default, `add-runner.sh org` **verifies
knob 1 first**: it reads the org's approval gate and *refuses to register*
unless it is set to require approval for all outside collaborators, so the
tool can never lower one knob without the other. Pass `--force` to proceed
anyway (accepting the fork-PR exposure — e.g. an internal-only org).

`script/status.sh` surfaces a `PUBLIC-DISPATCH` column (knob 2) **and an
`APPROVAL-GATE` column (knob 1)** so a one-sided configuration is visible at a
glance and cannot drift silently.

### Runner-user privilege

Workflow jobs run directly on the host as the runner service user, and that
user is in the `docker` group — which is **root-equivalent** (`docker run -v
/:/host …` reaches the whole host). This is an accepted trade-off for a
single-tenant, self-managed GPU host: the real security boundary is *which
workflows are allowed to run*, enforced by the two knobs above (only the
maintainer's and approved PRs dispatch), **not** the runner user's local
privilege. Consequences that follow from this and are intentionally *not*
chased in-repo: the short-lived registration token is passed to the runner's
`config.sh` on its command line (visible via `ps` to other local users — a
non-issue on a single-tenant host), and `sudo ./svc.sh` trusts the runner
tree. If this host ever needs to run untrusted workflows or be multi-tenant,
the upgrade path is **rootless Docker or rootless Podman** (no `docker` group;
the daemon runs unprivileged) — doable but with GPU + docker-in-docker
friction, so evaluate it separately at that point.

A dedicated CI user is **not** a boundary on its own. Because the runner user is
in the `docker` group (root-equivalent, above), a separate login, a clean home
directory, or `chmod 600 ~/.ssh` are cosmetic: any job that runs can `docker run
-v /:/host …` and read operator SSH keys, cloud credentials, and tokens
regardless of file ownership. A dedicated CI user only becomes a real boundary
when paired with **rootless** (the user is no longer root) *or* **host-no-secrets**
(root has nothing to take) — never one without the other. For the operational
steps, see the [host hardening runbook](doc/runbook/HOST-HARDENING.md).

What *is* hardened in-repo: the downloaded actions/runner tarball is verified
against the SHA-256 GitHub publishes for the release asset before it is
extracted (a supply-chain check, orthogonal to the above).

To report a security vulnerability, see [SECURITY.md](SECURITY.md) (use
GitHub's private vulnerability reporting — not a public issue).

## Prerequisites

**Host / hardware**

- Linux x64 (tested: Ubuntu 22.04)
- NVIDIA GPU — **optional**. With one, `nvidia-smi` must be reachable and
  `docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi`
  must succeed, and runners default to the `gpu` label. Without one,
  `script/init.sh` auto-detects the absence (no `nvidia-smi`), skips the GPU
  checks, and reminds you to set a non-GPU label
  (`./script/configure.sh --labels <label>`).
- Docker (with the NVIDIA Container Toolkit when using a GPU)
- Current user in the `docker` group (note: this is root-equivalent — see
  [Security model](#security-model))

**CLI tools**

- `gh`, `jq`, `curl`, `sudo`

**Access / network**

- A GitHub **organization you have admin/owner rights on** — the org-scoped
  flow (`init.sh <org>` / `add-runner.sh org <org>`) is the default. For a
  personal account, register a repo-scoped runner instead
  (`init.sh repo <owner> <repo>`, or `add-runner.sh repo <owner> <repo>`).
- `gh` authenticated with the `admin:org` scope (`gh auth login --scopes admin:org`)
- Outbound HTTPS to `github.com`, `api.github.com`, `cli.github.com`, and
  `objects.githubusercontent.com` (runner download + registration)
- `sudo` rights (the runner is installed as a systemd service)

**Installing the prerequisites**

Docker and the NVIDIA Container Toolkit must be installed first — follow
Docker's and NVIDIA's official guides (they involve kernel drivers / repos
this tool deliberately does not touch). Once those are in place,
`script/install-deps.sh` installs the remaining CLI tools (`gh`, `jq`, `curl`,
`sudo`) on an apt/Ubuntu host and walks you through `gh auth login`:

```bash
./script/install-deps.sh            # prompt before each install, then authenticate
./script/install-deps.sh -y         # accept every install prompt (apt -y); auth is still interactive
./script/install-deps.sh --dry-run  # report what's missing; install nothing
```

`script/init.sh` then re-checks all of the above and exits non-zero on failure
(listing every missing item).

## Quick start

`script/init.sh <your-org>` prepares the host AND registers the first runner.
Replace `<your-org>` / `<other-org>` below with **your own GitHub organization**
name(s) — they are placeholders, not literal values. Additional runners are
added with `script/add-runner.sh`:

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/install-deps.sh                # install gh/jq/curl/sudo + gh auth login
                                        # (skip if already set up; Docker+NVIDIA must pre-exist)

./script/init.sh <your-org>             # prep + first runner for your org
./script/add-runner.sh org <other-org>  # (optional) a runner for another org
./script/status.sh
```

If you want prep-only without registering (e.g. CI lint, or you'll register
later):

```bash
./script/init.sh   # no org arg = bootstrap only
```

Org- vs repo-scoped: an org runner serves every repo in the org; a repo runner
is pinned to a single repo. `script/init.sh` takes either scope, so a repo-level
runner is a one-shot too — pass `repo <owner> <repo>` and it preps the host then
registers that runner (forwarded to `script/add-runner.sh`). This is the path
for a personal account that has no org:

```bash
./script/init.sh repo <owner> <repo>      # prep host + runner pinned to <owner>/<repo>
```

(`init.sh <your-org>` in the org examples above is just shorthand for
`init.sh org <your-org>`.)

Expected output of `./script/status.sh` (the `APPROVAL-GATE` column shows knob 1,
`PUBLIC-DISPATCH` shows knob 2 — see Security model):

```
NAME                               SCOPE  LOCAL-SVC  GITHUB   PUBLIC-DISPATCH   APPROVAL-GATE   LABELS
<hostname>-<your-org>-org          org    running    online   public-ok         gate-ok         self-hosted,Linux,X64,gpu
<hostname>-<other-org>-org         org    running    online   public-ok         gate-ok         self-hosted,Linux,X64,gpu
```

## Verifying a runner

End-to-end verification needs a canary workflow inside a repo that lives
in the same org as the runner (GitHub org-level runners only accept
workflows from their own org). For an immediate sanity check,
`./script/status.sh` shows the GitHub-side `online` flag, and on a GPU host,
`script/init.sh` verifies `docker run --gpus all nvidia-smi` works (skipped
automatically when no GPU is detected).

## Upgrading the runner binary

```bash
RUNNER_VERSION=<new-version> ./script/update.sh
```

Stops each runner service, seeds the new versioned runner files into each
runner dir (existing files are left in place), restarts. The runner then
picks up the new version via its normal self-update on next connect. Config
and credentials are preserved.

## Uninstall

Remove a **single** runner (deregister + uninstall its systemd service +
delete its dir). Prompts by default; preview first, then confirm:

```bash
./script/remove-runner.sh --dry-run org <your-org>   # show what would be removed
./script/remove-runner.sh org <your-org>             # an org runner (prompts)
./script/remove-runner.sh repo <owner> <repo>        # a repo runner (prompts)
./script/remove-runner.sh --yes org <your-org>       # skip the prompt (required for non-TTY)
```

Tear down **everything** this checkout registered, plus the cached tarball
(prompts by default; preview first, then confirm):

```bash
./script/uninstall.sh --dry-run   # show what would be removed
./script/uninstall.sh --yes       # actually remove (required for non-TTY)
```

`uninstall.sh` deliberately does **not**: reset the org's
`allows_public_repositories` runner-group flag (it may be shared by other
hosts), or delete this checkout. Runners left `offline` on the GitHub side
after a host is gone are removed in the UI (Settings → Actions → Runners →
Remove). See [Troubleshooting](#troubleshooting) for stuck states.

## Rebuild SOP

After machine loss / reformat:

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/init.sh <your-org>
./script/add-runner.sh org <other-org>
```

No undocumented machine state. Registration tokens are fetched fresh via
`gh api`, so previous tokens / runner entries on GitHub side need cleanup
via the UI (Settings -> Actions -> Runners -> Remove offline runners) if
the old machine is gone for good. Note labels live in the gitignored
`setup.conf` and do not survive a host wipe — re-apply with
`./script/configure.sh --labels ...` (see Troubleshooting).

## Troubleshooting

On-call reference mapping each `status.sh` state (`offline`, `not-found`,
`n/a`, `stopped`, `public-BLOCKED`), plus queued-job / disk-full / `gh`-auth /
rebuild-label-drift situations, to a cause, a first diagnostic command, and a
fix: **[doc/runbook/TROUBLESHOOTING.md](doc/runbook/TROUBLESHOOTING.md)**.

## References

- GitHub docs: [Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- GitHub docs: [Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)

## License

[Apache-2.0](./LICENSE) -- aligns with [ycpss91255-docker/base] and the
rest of the org's repos.

[ycpss91255-docker/base]: https://github.com/ycpss91255-docker/base
