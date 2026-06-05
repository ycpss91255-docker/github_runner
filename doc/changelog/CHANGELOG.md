# Changelog

All notable user-facing changes to this repo are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- `add-runner.sh` now verifies the org's fork-PR approval gate before enabling
  public-repo dispatch. Registering an org runner flips
  `allows_public_repositories=true` (lowering GitHub's 2024+ safe default); the
  complementary protection is the org's "Require approval for all outside
  collaborators" gate. add-runner now reads that gate
  (`fork-pr-contributor-approval`) and **refuses to register** unless it is
  `all_external_contributors`, so the tool can no longer leave one knob lowered
  without the other. `--force` opts out (accepting the fork-PR exposure).
  `status.sh` gains an `APPROVAL-GATE` column next to `PUBLIC-DISPATCH` so a
  one-sided configuration is visible and cannot drift silently. `lib/common.sh`
  gains `github_fork_pr_approval_policy` / `fork_pr_gate_is_safe`. (#48)
- The downloaded actions/runner tarball is now verified against the SHA-256
  GitHub publishes for the release asset before extraction (`init.sh` strict,
  `update.sh` best-effort on the offline/no-gh path; a mismatch always aborts).
  A supply-chain check at the download point. `lib/common.sh` gains
  `verify_sha256` / `runner_asset_digest` / `verify_runner_tarball`.
- Documented the runner-user privilege model in the README security section
  (all locales): the runner user is in the `docker` group (≈ root), an accepted
  trade-off for a single-tenant self-managed host whose real boundary is the
  dispatch approval gate; rootless Docker/Podman is the noted upgrade path for
  untrusted/multi-tenant use.

### Documentation

- README (all locales): documented `status.sh`'s `--watch` / `--interval` /
  `--no-color` flags; expanded the English `init.sh` / `update.sh` rows to
  describe runner-version resolution (the translations already had it);
  corrected the public-repo security note to GitHub's actual setting name
  ("Require approval for all outside collaborators"); and switched the
  quick-start to `git clone ... && cd github_runner` so it no longer collides
  with the deprecated `~/github_runner` runner-state path.

### Fixed

- `add-runner.sh` no longer fails the whole run when enabling org public-repo
  dispatch fails: the runner is already registered and online by that point, so
  the idempotent flag PATCH is now a warning (with retry guidance) instead of a
  fatal error that falsely signalled the registration had failed. (#51)
- `update.sh` now verifies a cached tarball before extraction, not only on
  download: a cache hit no longer skips the integrity check (best-effort on the
  offline/no-gh path, but a mismatch still aborts + rm's the file). H1.
- `update.sh` now upgrades each runner independently: a single runner's
  stop/extract/start failure is reported and no longer aborts the whole loop
  (which previously left earlier runners stopped and later runners untouched).
  The run ends with an `N updated, M failed` summary and a non-zero exit when
  any runner failed, mirroring `cleanup.sh` / `uninstall.sh`. (#49)
- `set-labels.sh` now pre-gates on `gh` auth like the other mutating scripts
  (`add-runner.sh` / `remove-runner.sh`), failing with one clear line instead
  of a raw mid-operation API error. M1.
- `add-runner.sh`'s re-run guard now detects a registered-but-serviceless
  runner (a prior run whose `svc.sh install` never landed) and reinstalls the
  service instead of falsely reporting "already configured".
- `add-runner.sh` / `remove-runner.sh` now print their full `usage()` on a bad
  scope argument; `resolve_target`'s usage strings no longer emit a literal
  "...".
- `schedule-cleanup.sh --install` no longer leaves a stray leading blank line
  in a previously-empty crontab (B3).
- `add-runner.sh` removes the partial target directory if extraction /
  registration fails before `.runner` is written, so a retry starts clean
  instead of re-extracting over a half-populated tree (B1).
- Documented the idempotency nuances of `update.sh` (the agent self-updates,
  the second run is a no-op, the extract is GNU-tar-only) and `set-labels.sh`
  (always a live API call, not a local no-op) in their headers (B2 / B5).

### Changed

- The shared library was reorganized into focused modules, each behind its own
  seam: `lib/runner-layout.sh` (on-disk layout — dir / agent name / `_org`
  marker / `.runner` / systemd unit / active version), `lib/runner-service.sh`
  (the `svc.sh` lifecycle + `runner_service_running`), `lib/runner-release.sh`
  (the release tarball — `resolve_runner_version`, the cache name / path / URL,
  `find_cached_tarball`, and the SEC-5 `verify_*` trio), and
  `lib/runner-config.sh` (the `config.sh` register / deregister). Functions
  other entries below describe as living in `lib/common.sh` (the `verify_*`
  trio, `resolve_runner_version`, `find_cached_tarball`, the layout helpers,
  `runner_service_running`) now live in those modules. Every entry script also
  guards its `main "$@"` so it can be `source`d for unit tests, and every
  GitHub call funnels through the single `_gh` seam. Behaviour is unchanged —
  this is internal structure + testability (`CONTEXT.md` documents the modules).
- README + zh-TW / zh-CN / ja docs corrected for `update.sh` semantics (it
  seeds the binary then lets each runner self-update on its next job, it does
  not "replace" the binaries in place) and for GPU verification being skipped
  on non-GPU hosts; the translations expanded the `init.sh` / `update.sh`
  version-fallback conditions to match the English rows.
- `schedule-cleanup.sh` gained `--dry-run` (`-n`): print the merged crontab
  `--install` / `--uninstall` would write without touching the live crontab.
- `status.sh --watch` no longer emits cursor-home / clear-screen escapes under
  `--no-color` / `NO_COLOR` / a non-TTY, so piped or captured output stays
  clean (the raw escapes are gated the same way SGR colors are).
- `install-deps.sh` now documents its apt-style (default-yes) prompts.
- `script/init.sh`: the NVIDIA GPU is now **optional** (#34). It auto-detects a
  GPU via `nvidia-smi` — present → the docker `--gpus` runtime check still runs;
  absent → both GPU checks are skipped and init proceeds as a non-GPU host,
  reminding you that the default `gpu` label should be changed
  (`configure.sh --labels …`). The runner binary was already GPU-agnostic; only
  init's gates assumed a GPU. README Requirements updated (all locales).
- UX alignment across scripts: `status.sh`'s interval short flag is now `-i`
  (was `-n`), removing the cross-script collision where `-n` means `--dry-run`
  in `cleanup.sh` / `uninstall.sh`; `status.sh` also honors the `NO_COLOR`
  convention. The mutating scripts (`add-runner.sh`, `remove-runner.sh`,
  `set-labels.sh`) now pre-check `gh` auth and fail with one clear line instead
  of a raw mid-operation error; `remove-runner.sh` fetches the remove-token
  before any service teardown so an auth/network failure can't strand a
  half-deregistered runner. `uninstall.sh` per-item markers are plain words
  (was unicode ✓/✗) to avoid mojibake in non-UTF-8 viewers.
- `init.sh`, `add-runner.sh`, `remove-runner.sh`, `update.sh` now accept
  `-h`/`--help` (intercepted before argument dispatch, so `init.sh --help` no
  longer tries to register a runner for an org literally named "--help").
- Runner labels are now configurable instead of hard-coded to `gpu`.
  `add-runner.sh` reads `LABELS` from an optional `${RUNNER_HOME}/setup.conf`
  (default `gpu`, so existing flows are unchanged) generated by the new
  `script/configure.sh`.
- CI gates merges through a single `ci-rollup` aggregator check (mirroring
  `base`'s self-test.yaml), required by branch protection on `main` together
  with `shellcheck` + `bats`. CI runs on GitHub-hosted `ubuntu-latest` so
  `github_runner` stays validatable without a working self-hosted runner
  (ADR-0012 — avoids the bootstrap chicken-and-egg; the runner-provisioning
  tool must not depend on the runners it provisions).

- All entry-point scripts (`init.sh`, `add-runner.sh`, `remove-runner.sh`,
  `status.sh`, `update.sh`, `uninstall.sh`) moved from the repo root into
  `script/`. Invocation paths change to `./script/<name>.sh ...`;
  `RUNNER_HOME` resolution and shared `lib/common.sh` are unchanged. CI,
  Makefile.ci, all 4 README locales and bats tests follow.

### Added

- `status.sh` health-check support: `--check` (`-c`) prints the table once then
  exits non-zero if any runner is unhealthy (not `online`, or its local service
  is not running), suitable for cron / monitoring; `--json` emits a
  machine-readable array (one object per runner) for piping into Prometheus
  textfile / Nagios-style checks. Notification is intentionally left to the
  caller's alerting (the exit code / JSON are the integration points). (#52)
- Substantial smoke-test coverage: the `status.sh` rendering pipeline, the
  `remove-runner.sh` rm-guard helper, `init.sh`'s `cache_tarball`, `update.sh`'s
  no-op + verify-fail paths, `uninstall.sh`'s cache-only run + failure summary,
  the `install-deps.sh` guards, and `lib/common.sh` helper edge cases.
- `script/install-deps.sh`: install the CLI prerequisites (`gh`, `jq`, `curl`,
  `sudo`) on an apt/Ubuntu host and drive `gh auth login --scopes admin:org`.
  `-y` accepts every install prompt, `--dry-run` reports what's missing without
  installing. Docker + the NVIDIA Container Toolkit are assumed already present.
  Idempotent. README Prerequisites gains install guidance + access/network
  requirements (all locales).
- `script/configure.sh`: generate / update `${RUNNER_HOME}/setup.conf`.
  `--labels <csv>` sets the labels for newly registered runners; no args
  prints the current effective config. `lib/common.sh` gains `load_config`,
  `validate_labels`, and `runner_agent_id` helpers (unit-tested in
  `common.bats`).
- `script/set-labels.sh`: relabel an already-registered runner live via the
  GitHub API (`PUT .../actions/runners/{id}/labels`) — no remove + re-register.
  Usage `org <org> <csv>` / `repo <owner> <repo> <csv>`.
- `script/status.sh` now shows each runner's current labels in a `LABELS`
  column.

- `lib/common.sh`: `list_runners` enumerates every configured runner under
  `${RUNNER_HOME}` as a TAB-separated stream
  (`scope · org · name · runner_dir · scope_id`, scope_id optional). Walk
  semantics (skip `.bin/`, require `.runner`, silent on missing
  `RUNNER_HOME`) match what every existing caller already did inline.
  `script/status.sh`, `script/uninstall.sh`, `script/cleanup.sh`, and
  `script/update.sh` now consume the helper instead of re-implementing
  the walk. Layout knowledge concentrates in `lib/common.sh`. Bats
  coverage: 7 new cases in `common.bats`, suite goes from 54 to 61.

- `script/schedule-cleanup.sh`: install / inspect / remove a user-crontab
  entry that runs `cleanup.sh` on a schedule (daily / weekly / monthly,
  time and day-of-week selectable). Interactive prompts by default; same
  flags also accepted non-interactively (`--every`, `--at`, `--day`,
  `--status`, `--uninstall`). Cron command wraps `cleanup.sh --yes` in
  `flock -n ${RUNNER_HOME}/.cleanup.lock` so overlapping fires exit
  silently, and appends output to `${RUNNER_HOME}/.cleanup.log`. A
  marker comment (`# github_runner cleanup`) tags the entry so install
  / uninstall stay idempotent without touching unrelated crontab lines.
- `script/cleanup.sh`: prune stale artifacts left behind by GitHub's
  auto-update cycle -- old `bin.X` / `externals.X` version dirs (each
  pair ~600 MB), older cached tarballs under `${RUNNER_HOME}/.bin/`
  (keeps the highest-version), and `_work/_update*` remnants. Mirrors
  `uninstall.sh` UX: `--dry-run` previews, `--yes` skips the prompt
  (required non-TTY). Never touches `.runner` / `.credentials*` / logs /
  in-flight job dirs, so safe to schedule.
- `lib/common.sh`: `resolve_runner_version()` queries GitHub for the
  latest released actions/runner tag at install time, falling back to a
  pinned safe version (bumped from `2.319.1` to `2.334.0`) when offline
  / `gh` missing / API rate-limited. `RUNNER_VERSION=...` env override
  still wins. Refs #10.
- `lib/common.sh`: `find_cached_tarball()` returns the highest-version
  tarball in `${RUNNER_HOME}/.bin/`, so `add-runner.sh` extracts the
  freshest cached release rather than a version pinned at source.
  Refs #10.
- Bats tests for both new helpers (env override, gh-missing fallback,
  empty cache, multi-version cache picks the highest).
- `uninstall.sh`: counterpart to `init.sh`. Enumerates every runner
  registered through this checkout, calls `remove-runner.sh` per target,
  and clears the cached tarball under `${RUNNER_HOME}/.bin/`. Prompts by
  default; `--yes` skips for non-interactive runs, `--dry-run` previews
  without touching state. Deliberately does NOT alter org runner-group
  flags (see Security model + #6) or remove the github_runner checkout
  itself. Closes #11.
- `.gitignore`: `/runners` (no trailing slash) so a symlink at
  `<repo_root>/runners` -- used when the user splits the parent dir into
  `src/` (this checkout) and a sibling `../runners/` install -- stays
  ignored. The directory case is still covered.
- Apache-2.0 `LICENSE`.
- `doc/changelog/CHANGELOG.md` initialized.
- `make coverage` target (`Makefile.ci`) running bats under kcov
  instrumentation inside `kcov/kcov` image. Refs #1.
- CI `coverage` job uploading kcov XML to Codecov on push-to-main only.
  Codecov badge added to all four README variants. Refs #1.
- `lib/common.sh`: `enable_public_repos_dispatch(org)` helper flips the
  Default runner group's `allows_public_repositories=true`. Required so
  workflows in public repos can dispatch to org-level self-hosted runners
  (GitHub's 2024+ default is `false`, which silently strands public-repo
  jobs in queued state). Refs #6.
- `add-runner.sh`: after registering an `org`-scoped runner, calls
  `enable_public_repos_dispatch` so the configuration is one-step rather
  than a follow-up workaround. Refs #6.
- `status.sh`: new `PUBLIC-DISPATCH` column shows the runner group flag
  per org (`public-ok` / `public-BLOCKED` / `n/a`) so configuration drift
  is visible at a glance. Refs #6.
- README + 4-language variants document the two-knob security model
  (outside-collaborator approval gate + `allows_public_repositories`)
  and why flipping the latter on is safe when the former is set. Refs #6.

### Changed

- `init.sh`, `add-runner.sh`, `update.sh` now use the dynamic helpers
  above; `RUNNER_TARBALL` constant in `lib/common.sh` removed (was
  version-pinned and stale every release). Behaviour unchanged when
  `RUNNER_VERSION` is set; otherwise these scripts now pick up the
  latest release automatically instead of starting on `2.319.1` and
  immediately self-updating on first connect. Refs #10.
- `Makefile` targets now run `shellcheck` / `bats` inside the
  `ghcr.io/ycpss91255-docker/test-tools:latest` image (aligns with
  `ycpss91255-docker/base`). `lint-host` / `test-host` retained for
  host-side runs that do not require docker.
- CI workflow (`.github/workflows/ci.yaml`) updated to use the same
  test-tools image so local and CI runs share the exact tool versions.
- `actions/checkout` bumped from `@v4` to `@v6` in `ci.yaml` to align
  with `ycpss91255-docker/base`. Refs #1.
- `Makefile` renamed to `Makefile.ci` (no top-level `Makefile`), aligning
  with `ycpss91255-docker/base` convention. All `make` invocations now
  require `-f Makefile.ci`. Refs #1.

### Changed (BREAKING for existing installs)

- Default `RUNNER_HOME` moved from `${HOME}/github_runner` to
  `<repo_root>/runners/` (alongside the repo checkout). Single clone now
  owns all runner state; no separate `~/github_runner` directory needed.
  Override via `RUNNER_HOME=...` env var before invoking any script.
  `.gitignore` covers `/runners/` and `/coverage/`.

  **Migration for existing runners installed at `~/github_runner/`**:
  before pulling this change, deregister with the old `RUNNER_HOME`
  pointing at the old location:

  ```bash
  RUNNER_HOME=~/github_runner ./remove-runner.sh org ycpss91255-docker
  RUNNER_HOME=~/github_runner ./remove-runner.sh org ycpss91255-research
  ```

  Then pull, and re-register with the new default location:

  ```bash
  ./init.sh ycpss91255-docker
  ./add-runner.sh org ycpss91255-research
  ```

## [0.1.0] - 2026-05-28

### Added

- Initial release: 5 shell scripts (`init.sh`, `add-runner.sh`,
  `remove-runner.sh`, `status.sh`, `update.sh`) plus `lib/common.sh` shared
  helpers for provisioning self-hosted GitHub Actions runners on a GPU host.
- `init.sh <org>` chains the first runner registration.
- `add-runner.sh` accepts `org <org>` or `repo <owner> <repo>`.
- `~/github_runner/<org>/_org/` layout, two-layer to leave room for future
  per-repo runner directories under `<org>/<repo>/`.
- Smoke-level `bats` tests covering argument parsing, idempotency, and
  prereq failure paths for all five scripts.
- CI: shellcheck + bats on hosted ubuntu-latest runner.

Implements [ADR-0012] in the consuming workspace repo.

[ADR-0012]: https://github.com/ycpss91255-research/isaac/blob/main/doc/adr/0012-research-org-split-dual-org-runners.md
[Unreleased]: https://github.com/ycpss91255-docker/github_runner/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ycpss91255-docker/github_runner/releases/tag/v0.1.0
