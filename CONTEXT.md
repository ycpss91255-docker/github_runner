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
