# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities **privately**, not via public issues
or pull requests.

Use GitHub's **private vulnerability reporting** for this repository:
**Security → Advisories → "Report a vulnerability"**
(`https://github.com/ycpss91255-docker/github_runner/security/advisories/new`).

This opens a private advisory visible only to you and the maintainers. Please
include:

- the affected script(s) / function(s) and version or commit,
- a description of the impact and the conditions required to trigger it,
- reproduction steps or a proof of concept where possible.

This is a small, best-effort project: expect an initial acknowledgement within
a few days. Fixes are prioritised by severity. Please allow a reasonable window
for a fix before any public disclosure.

## Threat model (summary)

This tooling provisions and manages self-hosted GitHub Actions runners on a
**single-tenant, self-managed Linux host**. Two properties shape what is and is
not in scope. The full discussion lives in the README "Security model" section.

- **Runner user ≈ root.** Workflow jobs run on the host as the runner service
  user, which is in the `docker` group — root-equivalent (`docker run -v /:/host`
  reaches the whole host). This is an accepted trade-off for a single-tenant
  host. The real boundary is *which workflows are allowed to run*, not the
  runner user's local privilege. For untrusted or multi-tenant use, the upgrade
  path is rootless Docker / Podman.

- **A dedicated CI user is not a boundary on its own.** Under the docker-group
  model above, running the runner as a separate non-root user does *not* protect
  host secrets: any job can `docker run -v /:/host` and read `~/.ssh`,
  credentials, and tokens regardless of ownership. A CI user only becomes a real
  boundary when paired with rootless (the user is no longer root) *or*
  host-no-secrets (the box is CI-only). See the
  [host hardening runbook](doc/runbook/HOST-HARDENING.md).

- **Two org safety knobs must agree.** Public-repo dispatch depends on the
  outside-collaborator **approval gate** (`all_external_contributors`) plus the
  runner group's `allows_public_repositories` flag. `add-runner.sh` refuses to
  enable the latter unless the gate is set (override with `--force`), and
  `status.sh` surfaces both via the `PUBLIC-DISPATCH` and `APPROVAL-GATE`
  columns so the configuration cannot drift silently.

- **Supply chain.** The downloaded actions/runner tarball is verified against
  the SHA-256 GitHub publishes for the release asset before extraction. Note
  this verifies transport/mirror integrity, not GitHub upstream itself, since
  the checksum and the asset come from the same source.

### Out of scope

- Multi-tenant or untrusted-workflow isolation on a shared host (use rootless
  runtimes / ephemeral runners instead).
- The short-lived registration token being visible via `ps` to other local
  users (a non-issue on a single-tenant host; inherent to the runner's
  `config.sh` CLI interface).
- Vulnerabilities in GitHub, the `actions/runner` agent, Docker, or the host OS
  themselves — report those to their respective projects.

## Supported versions

Only the latest release / `main` is supported. There are no backports.
