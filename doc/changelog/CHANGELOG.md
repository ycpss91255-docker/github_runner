# Changelog

All notable user-facing changes to this repo are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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
