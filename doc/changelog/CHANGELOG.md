# Changelog

All notable user-facing changes to this repo are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Added

- `make coverage` target (Makefile.ci) running bats under kcov instrumentation
  inside `kcov/kcov` image. Refs #1.
- CI `coverage` job uploading kcov XML to Codecov on push-to-main only.
  Refs #1.
- Codecov badge on all four README variants.

### Changed

- `Makefile` renamed to `Makefile.ci` (no top-level `Makefile`), aligning
  with `ycpss91255-docker/base` convention. All `make` invocations now
  require `-f Makefile.ci`. Refs #1.
- `actions/checkout` bumped from `@v4` to `@v6` in `ci.yaml` to align with
  `ycpss91255-docker/base`. Refs #1.

### Added

- Apache-2.0 `LICENSE`.
- `Makefile` targets switched to running `shellcheck` / `bats` inside the
  `ghcr.io/ycpss91255-docker/test-tools:latest` image (aligns with
  `ycpss91255-docker/base`). `lint-host` / `test-host` retained for host-side
  runs that do not require docker.
- CI workflow (`.github/workflows/ci.yaml`) updated to use the same
  test-tools image so local and CI runs share the exact tool versions.
- `doc/changelog/CHANGELOG.md` initialized.

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
