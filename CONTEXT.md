# CONTEXT — github_runner domain glossary

Shared vocabulary for this self-hosted GitHub Actions runner tooling. Use these
terms verbatim in code, tests, and docs so names don't drift.

## Core

- **Runner** — a registered self-hosted GitHub Actions runner: an on-disk
  actions/runner install plus a systemd service. "Configured" means its dir
  holds a **registration marker** (`.runner`).
- **Scope** — a runner is either **org-scoped** (serves every repo in an org)
  or **repo-scoped** (pinned to one repo). The two differ in their on-disk dir,
  agent name, and GitHub API paths.
- **RUNNER_HOME** — the single root that owns all runner state: the tarball
  cache (`.bin/`) and one dir per runner. Defaults to `<repo>/runners/`,
  overridable; validated once (SEC-3) as the `rm -rf` chokepoint.

## Runner Layout

The **Runner Layout** module (`lib/runner-layout.sh`) is the single source of
truth for *where a runner's files live and what they are named*. It owns:

- **org marker / `_org` sentinel** (`RUNNER_ORG_MARKER`) — the on-disk dir name
  that distinguishes an org runner (`<owner>/_org`) from a repo runner
  (`<owner>/<repo>`). Shared by the path constructor and the inverse classifier.
- **runner dir** (`runner_dir`) — absolute dir for a runner from its scope +
  owner [+ repo].
- **agent name** (`runner_agent_name`) — the GitHub-facing runner name,
  `<hostname>-<owner>-org` / `<hostname>-<owner>-<repo>`.
- **registration marker** (`runner_marker_file`) — the `.runner` file whose
  presence means "configured".
- **service unit** (`runner_service_unit_pattern`) — the systemd unit
  actions/runner installs: `actions.runner.<url-slug>.<agent-name>.service`.
- **active version** (`runner_active_version`) — the runner version read from a
  dir's `bin` symlink target.

Consumers (`resolve_target`, `list_runners`, `runner_service_running`,
`cleanup.sh`) derive layout through this module rather than re-encoding it, so a
layout change in actions/runner lands in one place.

## Runner Service

The **Runner Service** module (`lib/runner-service.sh`) is the single seam over
a runner's systemd service. svc.sh ships inside each runner dir (from the
actions/runner tarball), so every verb runs from that dir as root:

- `runner_service_install` / `runner_service_start` — propagate failure (the
  caller cares whether the service came up).
- `runner_service_stop` / `runner_service_uninstall` — best-effort (teardown
  must not abort because the service was already gone).
- `runner_service_running` — is the unit active (uses the layout's
  `runner_service_unit_pattern`).

Consumers (`add-runner.sh`, `remove-runner.sh`, `update.sh`) call these instead
of open-coding the `pushd; sudo ./svc.sh <verb>; popd` dance.

## Runner Config

The **Runner Config** module (`lib/runner-config.sh`) is the sibling seam over a
runner's bundled `config.sh` (registration), which like `svc.sh` runs from the
runner dir (no sudo):

- `runner_config_register <dir> <url> <token> <labels> <name>` — `config.sh
  --unattended` (writes the `.runner` marker). Propagates failure so
  add-runner's ERR trap can rm the partial dir.
- `runner_config_deregister <dir> <token>` — `config.sh remove`.

add-runner.sh / remove-runner.sh call these instead of open-coding
`pushd; ./config.sh ...; popd`.

## Runner Release

The **Runner Release** module (`lib/runner-release.sh`) is the single source of
truth for the actions/runner release tarball:

- **version** (`resolve_runner_version`) — `RUNNER_VERSION` override, else the
  latest GitHub tag, else `RUNNER_VERSION_FALLBACK`.
- **name / cache path / download URL** (`runner_release_tarball_name`,
  `runner_release_cache_path`, `runner_release_download_url`) — the
  `actions-runner-linux-x64-<version>.tar.gz` convention, the `${RUNNER_HOME}/
  .bin/` cache, and the GitHub release URL, each named once.
- **download / cached list / find** (`runner_release_download`,
  `runner_release_cached_list`, `find_cached_tarball`).
- **integrity** (`verify_sha256`, `runner_asset_digest`,
  `verify_runner_tarball`) — SEC-5 supply-chain check at the download point.

init.sh and update.sh keep their own verify *policy* (strict on fresh download
vs best-effort on every run, H1) but share these primitives; cleanup.sh and
add-runner.sh derive the cache glob / highest cached tarball through the module.

## GitHub adapter

- **`_gh` seam** — every GitHub call funnels through `_gh()` (a `gh` wrapper)
  so tests can shadow one function. Higher-level adapters
  (`github_runner_status`, `github_set_labels`, `github_runner_token`,
  `runner_asset_digest`) sit on top.
- **registration token** — short-lived token from GitHub used to register /
  remove a runner (distinct from the user's `gh` auth).

## Destructive-action policy

- **destructive harness** — the shared `--yes` / `--dry-run` + confirm + summary
  policy (`parse_destructive_flags`, `confirm_or_abort`, `print_summary`) used
  verbatim by `cleanup.sh` and `uninstall.sh`.
