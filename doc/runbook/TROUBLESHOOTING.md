# Troubleshooting runbook

On-call reference for a self-hosted runner host managed by this repo. Start
from `./script/status.sh` — each column value below maps to a likely cause, a
first diagnostic command, and a fix. All commands run from the repo checkout
(`RUNNER_HOME` defaults to `<repo_root>/runners/`).

> Quick triage: `./script/status.sh` shows every runner's `LOCAL-SVC`
> (systemd) and `GITHUB` (control-plane) state side by side. A runner only
> picks up jobs when it is `running` **and** `online`.

## `status.sh` state → action

### `GITHUB = offline` (service `running`)

- **Means:** the local service is up but the runner is not connected to GitHub
  (lost long-poll, network/proxy/DNS, expired runner credentials, or a stuck
  process).
- **Diagnose:**
  - `systemctl status 'actions.runner.*'` — is the process actually alive?
  - `sudo journalctl -u 'actions.runner.*' -n 100 --no-pager` — look for
    listener disconnect / 401 / TLS errors.
  - Check outbound HTTPS to `github.com` / `api.github.com`.
- **Fix:** restart the unit (`sudo systemctl restart 'actions.runner.<...>.service'`).
  If it reconnects, done. If credentials are rejected, re-register:
  `./script/remove-runner.sh org <org>` then `./script/add-runner.sh org <org>`.

### `LOCAL-SVC = stopped`

- **Means:** the systemd unit is not active (crash, OOM-kill, host reboot
  without enable, or a failed `update.sh`).
- **Diagnose:** `systemctl status 'actions.runner.*'`;
  `sudo journalctl -u 'actions.runner.*' -n 100 --no-pager`;
  `dmesg | grep -i oom` for OOM kills.
- **Fix:** `sudo systemctl start 'actions.runner.<...>.service'`. If the unit
  is missing entirely, re-run `./script/add-runner.sh org <org>` — its re-run
  guard reinstalls the service for an already-registered runner. If it crashes
  again right after start, inspect the journal for the failing step.

### `GITHUB = not-found`

- **Means:** the local `.runner` registration no longer matches any runner on
  GitHub (deleted in the GitHub UI, or this is a stale/orphan dir).
- **Diagnose:** confirm in GitHub → org/repo → Settings → Actions → Runners.
- **Fix:** re-register: `./script/remove-runner.sh ...` then
  `./script/add-runner.sh ...`. (`remove-runner.sh` tolerates an
  already-absent GitHub side.)

### `GITHUB = n/a` or `PUBLIC-DISPATCH = n/a`

- **Means:** the GitHub API call failed — almost always `gh` auth expired, lost
  network, or a rate-limit. `n/a` is "couldn't ask", not "bad".
- **Diagnose:** `gh auth status`. If it reports not-logged-in / expired token,
  that is the cause (it is independent of the runner's own registration).
- **Fix:** `gh auth login --scopes admin:org`, then re-run `status.sh`.

### `PUBLIC-DISPATCH = public-BLOCKED` (jobs from public repos stay queued)

- **Means:** the org's Default runner group has `allows_public_repositories =
  false` (GitHub's 2024+ default), so public-repo workflows never dispatch even
  though the runner is `online` + idle.
- **Diagnose:** `status.sh` shows `public-BLOCKED`; the job sits `queued` in the
  Actions tab.
- **Fix:** re-run `./script/add-runner.sh org <org>` (idempotent; it flips the
  flag). **Before doing so, confirm the org's "Require approval for all outside
  collaborators" gate is set** — enabling public dispatch without it re-opens
  the fork-PR hole (see the README security model).

### Jobs stay `queued` although the runner is `running` + `online`

- **Means:** label mismatch. A job lands on a runner only when the job's
  `runs-on` labels are a subset of the runner's labels.
- **Diagnose:** compare the workflow's `runs-on` with the runner's `LABELS`
  column in `status.sh`. A common case after a host rebuild is labels reverting
  to the default `gpu` (see below).
- **Fix:** relabel live without re-registering:
  `./script/set-labels.sh org <org> <csv>` (or `repo <owner> <repo> <csv>`).

### Disk full / jobs failing with no space

- **Means:** `_work/<job-id>/` build dirs and `_diag` logs grow over time;
  `cleanup.sh` reclaims update leftovers but **not** in-flight `_work` job dirs.
- **Diagnose:** `df -h <repo_root>/runners`; find the biggest consumers:
  `du -sh <repo_root>/runners/*/*/_work 2>/dev/null | sort -h | tail`.
- **Fix:** run `./script/cleanup.sh` (prunes stale version dirs, old cached
  tarballs, `_work/_update` remnants, and aged `_diag` logs). If space is still
  tight, the culprit is usually a large `_work/<job-id>` — verify no job is
  running on that runner, then remove the specific job dir manually. Schedule
  recurring cleanup with `./script/schedule-cleanup.sh`.

### `gh` auth expired (mutating commands fail up front)

- **Means:** `add-runner.sh` / `remove-runner.sh` / `set-labels.sh` pre-check
  `gh` auth and fail with one clear line rather than erroring mid-operation.
  This is independent of whether the runner itself is registered/online.
- **Fix:** `gh auth login --scopes admin:org`, then re-run the command.

## Host rebuild gotchas

After rebuilding a host from the README "Rebuild SOP":

- **Labels silently revert to `gpu`.** `setup.conf` lives under the gitignored
  `runners/` state, so it does not survive a wiped host. Re-apply labels before
  (or right after) registering: `./script/configure.sh --labels <csv>`, or
  `./script/set-labels.sh ...` on the live runner. Otherwise jobs that target a
  custom label sit `queued`.
- **Orphan runners on GitHub.** The old host's runners linger as `offline` in
  the GitHub UI (and a different hostname produces a *new* agent name, so the
  old one is not reused). Remove the stale entries in
  org/repo → Settings → Actions → Runners.

## Useful one-liners

```bash
./script/status.sh                              # local + GitHub state, all runners
sudo journalctl -u 'actions.runner.*' -n 100 --no-pager
systemctl list-units 'actions.runner.*'
gh auth status
df -h <repo_root>/runners
./script/cleanup.sh --dry-run                   # what cleanup would reclaim
```
