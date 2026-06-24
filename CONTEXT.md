# CONTEXT — github_runner domain glossary

Shared vocabulary for this self-hosted GitHub Actions runner tooling. Use these
terms verbatim in code, tests, and docs so names don't drift.

## Core

- **Runner** — a self-hosted GitHub Actions runner that serves **exactly one
  job** in a fresh, single-use container, then de-registers. It is provisioned
  on demand by the scale-set listener from a server-side **JIT config**, not
  registered once and left running. "Configured" means the listener has minted
  that single-use config and handed it to a per-job container — there is **no**
  persistent `.runner` marker and no long-lived systemd service. This is the
  default model since [ADR-0001](doc/adr/0001-ephemeral-jit-runners.md) Phase 5
  closed the migration (`add-runner.sh` defaults here; the **Ephemeral / JIT**
  terms below are canonical).
  > **Legacy (persistent) runner** — the superseded model: an on-disk
  > actions/runner install plus a long-lived systemd service, where "Configured"
  > meant the dir held a **registration marker** (`.runner`). It is reachable
  > only via `add-runner.sh --persistent` and kept for hosts not yet on the
  > ephemeral path; ADR-0001 supersedes it (state/secrets survive across jobs on
  > a shared runner). The `.runner` marker, agent name, and systemd unit in the
  > **Runner Layout** module below describe this legacy mode.
- **Scope** — a runner is either **org-scoped** (serves every repo in an org)
  or **repo-scoped** (pinned to one repo). The two differ in their on-disk dir,
  agent name, and GitHub API paths.
- **RUNNER_HOME** — the single root that owns all runner state: the tarball
  cache (`.bin/`) and one dir per runner. Defaults to `<repo>/runners/`,
  overridable; validated once (SEC-3) as the `rm -rf` chokepoint.

## Ephemeral / JIT (default model — ADR-0001)

Vocabulary for the default runner model (it supersedes the legacy persistent
runner described above). See
[ADR-0001](doc/adr/0001-ephemeral-jit-runners.md) for the decision and trade-offs.

- **Ephemeral runner** — a runner that serves **exactly one job** and then
  de-registers itself. The opposite of a persistent runner; the unit of
  isolation against cross-job state/secret residue.
- **JIT config** — a single-use runner configuration generated server-side by
  GitHub (no long-lived registration token on the host). Replaces the
  `config.sh`-once registration + persistent `.runner` marker.
- **Scale set** — a named, homogeneous group of ephemeral runners that workflows
  target by name; the GitHub-side unit the orchestrator reports demand against.
- **Runner Scale Set Client** — the official `actions/scaleset` (Go) module that
  holds the outbound long-poll session and reports demand (`TotalAssignedJobs`).
  It decides *when / how many* runners; the **per-job container** provisioning
  (the actual isolation) is ours to implement.

The `lib/runner-*.sh` modules below follow a runner's install lifecycle:
**Layout** (where it lives) → **Release** (the tarball) → **Config** (register)
→ **Service** (run).

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

## Runner Config

The **Runner Config** module (`lib/runner-config.sh`) is the seam over a
runner's bundled `config.sh` (registration), which like `svc.sh` runs from the
runner dir (no sudo):

- `runner_config_register <dir> <url> <token> <labels> <name>` — `config.sh
  --unattended` (writes the `.runner` marker). Propagates failure so
  add-runner's ERR trap can rm the partial dir. **Legacy** (persistent) path —
  reached only via `add-runner.sh --persistent`.
- `runner_config_deregister <dir> <token>` — `config.sh remove`. Legacy path.
- `runner_config_jit_generate <scope> <owner> [<repo>] <labels> <name>` — the
  **default** counterpart (ADR-0001): mints a single-use server-side **JIT
  config** (no `.runner` marker, no long-lived registration token) for an
  ephemeral runner via the `_gh` seam, consumed once by `runner_run_jit` /
  `runner_container_run`.

`add-runner.sh` defaults to the ephemeral / JIT (scale-set) path and points at
the listener; the legacy register/service verbs run only under `--persistent`.
`add-runner.sh --persistent` / `remove-runner.sh` call register/deregister
instead of open-coding `pushd; ./config.sh ...; popd`.

## Runner Service

The **Runner Service** module (`lib/runner-service.sh`) is the sibling seam over
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
