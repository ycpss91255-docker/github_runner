# github_runner

Self-hosted GitHub Actions runner provisioning for `ycpss91255-research` and
`ycpss91255-docker` orgs. Implements ADR-0012.

Repo lives in `ycpss91255-docker` because runner provisioning is part of the
host environment / infrastructure layer (per the user's interpretation of
the docker-vs-research org boundary, see ADR-0012 for the original split
and its later refinement).

## Layout

```
~/github_runner/                                       # local install location
├── .bin/
│   └── actions-runner-linux-x64-<version>.tar.gz      # cached tarball
├── ycpss91255-docker/
│   └── _org/                                          # org-level runner
└── ycpss91255-research/
    └── _org/                                          # org-level runner
```

`_org` denotes "the org-level runner for this org". Repo-level runners would
live at `<org>/<repo>/` instead.

## Scripts

| Script | Purpose |
|---|---|
| `init.sh` | Verify host prerequisites; cache runner tarball into `~/github_runner/.bin/`. If given an org arg, also registers the first runner for that org |
| `add-runner.sh` | Register a new runner. Usage: `org <org>` or `repo <owner> <repo>` |
| `remove-runner.sh` | Deregister + uninstall systemd service + remove directory |
| `status.sh` | List all registered runners with local + GitHub-side state |
| `update.sh` | Upgrade runner binary across all runners; preserves config |

All scripts are idempotent.

## Prerequisites

- Linux x64 (tested: Ubuntu 22.04)
- Docker with GPU runtime (`docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` must work)
- `nvidia-smi` reachable on host
- `gh` CLI authenticated with `admin:org` scope
- Current user in `docker` group
- `curl`, `jq`, `sudo`

`init.sh` runs all of these checks and exits non-zero on failure.

## Quick start

`init.sh <org>` prepares the host AND registers the first runner. Additional
runners are added with `add-runner.sh`:

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
gh auth login --scopes admin:org   # if not already

./init.sh ycpss91255-docker             # prep + first runner (for -docker org)
./add-runner.sh org ycpss91255-research # second runner (for -research org)
./status.sh
```

If you want prep-only without registering (e.g. CI lint, or you'll register
later):

```bash
./init.sh   # no org arg = bootstrap only
```

Expected output of `./status.sh`:

```
NAME                                     SCOPE      LOCAL-SVC  GITHUB
<hostname>-ycpss91255-docker-org         org        running    online
<hostname>-ycpss91255-research-org       org        running    online
```

## Verifying a runner

End-to-end verification needs a canary workflow inside a repo that lives
in the same org as the runner (GitHub org-level runners only accept
workflows from their own org). Canary placement is still under design --
see the parent issue / ADR-0012 for the current decision. For an
immediate sanity check, `./status.sh` shows the GitHub-side `online` flag,
and `init.sh` already verifies `docker run --gpus all nvidia-smi` works
on the host.

## Upgrading the runner binary

```bash
RUNNER_VERSION=<new-version> ./update.sh
```

Stops each runner service, replaces binary, restarts. Config and credentials
are preserved.

## Rebuild SOP

After machine loss / reformat:

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
./init.sh ycpss91255-docker
./add-runner.sh org ycpss91255-research
```

No undocumented machine state. Registration tokens are fetched fresh via
`gh api`, so previous tokens / runner entries on GitHub side need cleanup
via the UI (Settings -> Actions -> Runners -> Remove offline runners) if
the old machine is gone for good.

## References

- ADR-0011 in `ycpss91255/isaac/doc/adr/` (pre-migration) or
  `ycpss91255-research/isaac/doc/adr/` (post-migration)
- ADR-0012 in same location
- GitHub docs: [Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- GitHub docs: [Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)
