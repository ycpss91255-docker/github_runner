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
- [Rebuild SOP](#rebuild-sop)
- [References](#references)
- [License](#license)

## TL;DR

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
gh auth login --scopes admin:org        # if not already

./script/init.sh ycpss91255-docker             # prep host + register first runner
./script/add-runner.sh org ycpss91255-research # register second runner
./script/status.sh                             # local + GitHub-side state
```

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
| `script/init.sh` | Verify host prerequisites; resolve the actions/runner version (`RUNNER_VERSION=...` override, else the latest release via `gh api`, falling back to a pinned version when `gh` is missing / unauthenticated / offline), then download + cache the tarball into `<repo_root>/runners/.bin/` (i.e. `$RUNNER_HOME/.bin/`). If given an org arg, also registers the first runner for that org |
| `script/add-runner.sh` | Register a new runner. Usage: `org <org>` or `repo <owner> <repo>`. Labels come from `setup.conf` (default `gpu`, see Configuration). For `org` scope also flips the Default runner group's `allows_public_repositories=true` so public-repo workflows can dispatch (see Security model below) |
| `script/configure.sh` | Generate / update `${RUNNER_HOME}/setup.conf`. `--labels <csv>` sets the labels for newly registered runners; no args prints the current effective config |
| `script/set-labels.sh` | Relabel an already-registered runner live via the GitHub API (no remove + re-register). Usage: `org <org> <csv>` or `repo <owner> <repo> <csv>` |
| `script/remove-runner.sh` | Deregister + uninstall systemd service + remove directory |
| `script/status.sh` | List all registered runners with local + GitHub-side state and their current labels. `-w`/`--watch` refreshes continuously (configurable `-i`/`--interval`, default 5s) with row-level diff highlighting; `--no-color` disables color |
| `script/update.sh` | Resolve the runner version (`RUNNER_VERSION=...` override or latest release, same fallback as init), download into the cache if absent, then seed the new versioned runner files into each runner dir (existing files are left in place); the runner picks up the new version via its normal self-update on next connect; preserves config |
| `script/uninstall.sh` | Counterpart to `script/init.sh`: tear down every runner registered through this checkout + remove the cached tarball. Prompts by default; `--yes` skips, `--dry-run` previews. Does NOT change org runner-group flags or remove the checkout itself (see #11) |
| `script/cleanup.sh` | Prune disk-heavy leftovers from GitHub's auto-update cycle: stale `bin.X` / `externals.X` version dirs, older cached tarballs in `${RUNNER_HOME}/.bin/`, and `_work/_update*` remnants. Safe to schedule; never touches registration state, logs, or in-flight job dirs. Prompts by default; `--yes` skips, `--dry-run` previews |
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

The Makefile is named `Makefile.ci` (no top-level `Makefile`) to match the
base repo convention -- always invoke with `-f Makefile.ci`:

```bash
make -f Makefile.ci pull       # pull test-tools + kcov images (once)
make -f Makefile.ci lint       # shellcheck on all scripts (in docker)
make -f Makefile.ci test       # bats smoke tests (in docker)
make -f Makefile.ci check      # lint + test (no coverage)
make -f Makefile.ci coverage   # bats with kcov coverage -> ./coverage/
make -f Makefile.ci help       # list targets
```

If you prefer to run on the host (requires `shellcheck` / `bats` installed
locally):

```bash
make -f Makefile.ci lint-host
make -f Makefile.ci test-host
```

CI mirrors `make -f Makefile.ci lint` + `test` on every push / PR and
`coverage` on push-to-main only (kcov is 2-5x slower than plain bats, so
coverage is reserved for release-quality signal). Codecov upload uses the
`CODECOV_TOKEN` repo secret.

## Security model

Public-repo dispatch on self-hosted runners has two GitHub knobs that
matter and must agree:

1. **Outside-collaborator approval gate** (org Settings -> Actions ->
   General -> "Require approval for all outside collaborators"). Set per
   ADR-0011 Public repo security. Blocks fork PRs from running arbitrary
   code on the runner until the maintainer clicks "Approve and run".
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

`script/status.sh` surfaces a `PUBLIC-DISPATCH` column showing whether knob 2 is
set on each org so the configuration cannot drift silently.

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

What *is* hardened in-repo: the downloaded actions/runner tarball is verified
against the SHA-256 GitHub publishes for the release asset before it is
extracted (a supply-chain check, orthogonal to the above).

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

`script/init.sh <org>` prepares the host AND registers the first runner. Additional
runners are added with `script/add-runner.sh`:

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/install-deps.sh                       # install gh/jq/curl/sudo + gh auth login
                                               # (skip if already set up; Docker+NVIDIA must pre-exist)

./script/init.sh ycpss91255-docker             # prep + first runner (for -docker org)
./script/add-runner.sh org ycpss91255-research # second runner (for -research org)
./script/status.sh
```

If you want prep-only without registering (e.g. CI lint, or you'll register
later):

```bash
./script/init.sh   # no org arg = bootstrap only
```

Org- vs repo-scoped: an org runner serves every repo in the org; a repo runner
is pinned to a single repo. `script/init.sh` only registers org-scoped first
runners, so for a repo-scoped runner prep the host first, then add it explicitly
with `script/add-runner.sh`:

```bash
./script/init.sh                                      # prep-only (no org arg, as above)
./script/add-runner.sh repo ycpss91255-docker my-repo # runner pinned to ycpss91255-docker/my-repo
```

Expected output of `./script/status.sh`:

```
NAME                                     SCOPE      LOCAL-SVC  GITHUB     PUBLIC-DISPATCH  LABELS
<hostname>-ycpss91255-docker-org         org        running    online     public-ok        self-hosted,Linux,X64,gpu
<hostname>-ycpss91255-research-org       org        running    online     public-ok        self-hosted,Linux,X64,gpu
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

## Rebuild SOP

After machine loss / reformat:

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/init.sh ycpss91255-docker
./script/add-runner.sh org ycpss91255-research
```

No undocumented machine state. Registration tokens are fetched fresh via
`gh api`, so previous tokens / runner entries on GitHub side need cleanup
via the UI (Settings -> Actions -> Runners -> Remove offline runners) if
the old machine is gone for good.

## References

- [ADR-0011] -- original CI architecture (since revised)
- [ADR-0012] -- research org split + dual org-level runners (this repo
  implements its tooling section)
- GitHub docs: [Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- GitHub docs: [Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)

## License

[Apache-2.0](./LICENSE) -- aligns with [ycpss91255-docker/base] and the
rest of the org's repos.

[ADR-0011]: https://github.com/ycpss91255-research/isaac/blob/main/doc/adr/0011-ci-architecture-with-self-hosted-gpu-runner.md
[ADR-0012]: https://github.com/ycpss91255-research/isaac/blob/main/doc/adr/0012-research-org-split-dual-org-runners.md
[ycpss91255-docker/base]: https://github.com/ycpss91255-docker/base
