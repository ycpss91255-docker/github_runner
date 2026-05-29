# Changelog

All notable user-facing changes to this repo are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- All entry-point scripts (`init.sh`, `add-runner.sh`, `remove-runner.sh`,
  `status.sh`, `update.sh`, `uninstall.sh`) moved from the repo root into
  `scripts/`. Invocation paths change to `./scripts/<name>.sh ...`;
  `RUNNER_HOME` resolution and shared `lib/common.sh` are unchanged. CI,
  Makefile.ci, all 4 README locales and bats tests follow.

### Added

- `scripts/cleanup.sh`: prune stale artifacts left behind by GitHub's
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
