#!/usr/bin/env bash
# Provision a self-hosted runner (org or repo level).
#
# DEFAULT = ephemeral / JIT (ADR-0001, advances #77 -- closes the migration):
# the supported model is now ephemeral runners orchestrated by the scale-set
# listener (listener/, the Runner Scale Set Client), each job in a fresh,
# single-use, rootless container. add-runner no longer registers a long-lived
# systemd service by default; without --persistent it points the operator at
# that scale-set path (the live listener needs operator scale-set creds, so it
# cannot be brought up offline from here).
#
# LEGACY = persistent systemd (--persistent opt-in): the original config.sh-once
# + svc.sh-install path that registers a runner serving an unbounded sequence of
# jobs. ADR-0001 SUPERSEDES it (state residue / secrets survive across jobs on a
# shared runner); it is kept, behind the explicit opt-in, for hosts not yet on
# the ephemeral path -- do not build new flows on it.
# Usage:
#   ./script/add-runner.sh org <org>                 # ephemeral guidance (default)
#   ./script/add-runner.sh --persistent org <org>    # legacy systemd path
#   ./script/add-runner.sh --persistent repo <owner> <repo>
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") org <org>                    # ephemeral / JIT (default)
  $(basename "$0") repo <owner> <repo>
  $(basename "$0") --persistent [--force] org <org>   # legacy systemd path

Provision a self-hosted runner (org- or repo-level).

By default this prints the ephemeral / JIT (scale-set) provisioning path
(ADR-0001): one fresh, single-use container per job via the scale-set
listener, no long-lived systemd service. This is the supported model.

Options:
  --persistent  Use the LEGACY persistent systemd path (config.sh-once +
                svc.sh install) instead of the ephemeral default. ADR-0001
                supersedes it; kept behind this opt-in for hosts not yet on
                the ephemeral path. Idempotent.
  --force       (--persistent org only) Enable public-repo dispatch even when
                the org's fork-PR approval gate is not
                "all_external_contributors". Without it, registration refuses
                to lower the public-repo default while the complementary
                approval gate is open. #48.
EOF
}

# The ephemeral / JIT (default) front door (ADR-0001 Phase 5). add-runner can no
# longer bring up a runner offline in this model: the scale-set listener holds
# the outbound long-poll session and provisions one fresh, single-use container
# per job, which needs operator scale-set credentials it does not have here. So
# the default DIRECTS the operator to that path rather than registering anything
# -- it resolves the target only to echo the scope back, never touching a runner
# dir, tarball, gh token, config.sh, or svc.sh. --persistent opts back into the
# legacy systemd flow below.
ephemeral_guidance() {
  resolve_target "$@"
  cat <<EOF
ephemeral / JIT is now the default runner model for ${TARGET_NAME} (ADR-0001).

Each job runs once in a fresh, single-use, rootless container, then the
runner de-registers -- no long-lived systemd service, no '.runner' marker,
no long-lived registration token on the host (advances #77, #80, #82).

To provision ${TARGET_NAME}, run the scale-set listener instead of this
script. It maintains the outbound long-poll scale set session and provisions
one container per assigned job:

  see ./listener/README.md  (cmd/scaleset-listener; needs scale-set creds)
  see ./doc/adr/0001-ephemeral-jit-runners.md

Legacy persistent systemd path (superseded): re-run with --persistent.
EOF
}

main() {
  # Extract --persistent / --force from anywhere in the args, then dispatch on
  # the positional scope as before. -h/--help short-circuits here too.
  local force=0
  local persistent=0
  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --persistent) persistent=1; shift ;;
      --force)      force=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            rest+=("$1"); shift ;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"}

  case "${1:-}" in
    org|repo) ;;
    *) usage >&2; exit 1 ;;
  esac

  # Default = ephemeral / JIT (ADR-0001): direct the operator to the scale-set
  # listener and exit, without touching the persistent register/service path.
  # --persistent opts into the legacy systemd flow below.
  if (( ! persistent )); then
    ephemeral_guidance "$@"
    exit 0
  fi

  resolve_target "$@"

  if [[ -f "${TARGET_DIR}/.runner" ]]; then
    # The runner is registered. Only treat it as "already configured" if its
    # systemd service is actually active: a prior run whose `sudo ./svc.sh
    # install/start` failed after config.sh wrote .runner leaves the runner
    # registered with its service missing/stopped. In that case converge by
    # (re)running the service-install/start steps instead of falsely reporting
    # success.
    if runner_service_running "${TARGET_NAME}"; then
      echo "runner at ${TARGET_DIR} already configured."
      echo "use ./script/remove-runner.sh first if you want to re-register."
      exit 0
    fi
    echo "runner at ${TARGET_DIR} is registered but its service is missing/stopped; (re)installing it." >&2
    runner_service_install "${TARGET_DIR}" "$(whoami)"
    runner_service_start "${TARGET_DIR}"
    echo "service (re)installed for ${TARGET_NAME} at ${TARGET_DIR}"
    exit 0
  fi

  local tarball_path
  tarball_path=$(find_cached_tarball)
  if [[ -z ${tarball_path} ]]; then
    echo "tarball missing. run ./script/init.sh first." >&2
    exit 1
  fi

  # Resolve registration labels from setup.conf (default gpu when absent).
  load_config

  require_gh_auth

  # #48: an org runner enables public-repo dispatch below, which lowers
  # GitHub's 2024+ safe default. The complementary protection is the org's
  # fork-PR approval gate. Verify it BEFORE registering so we never lower one
  # knob without the other; --force opts out (accepting the fork-PR exposure).
  if [[ ${1:-} == "org" ]] && (( ! force )) && ! fork_pr_gate_is_safe "$2"; then
    echo "FAIL: refusing to register an org runner that would enable public-repo dispatch." >&2
    echo "  The org's fork-PR approval gate is '$(github_fork_pr_approval_policy "$2")', not 'all_external_contributors'." >&2
    echo "  Without it, any fork PR could dispatch workflows to this root-equivalent runner." >&2
    echo "  Fix: set 'Require approval for all outside collaborators' in the org's Actions" >&2
    echo "  settings, then re-run; or pass --force to proceed anyway." >&2
    exit 1
  fi

  local token
  token=$(github_runner_token "${TARGET_API_TOKEN_PATH}")

  mkdir -p "${TARGET_DIR}"
  # B1 idempotency: if extraction or registration fails before .runner is
  # written, remove the partial dir so a retry starts clean (the re-run guard
  # keys on .runner, which a crashed run would leave absent over a half-
  # populated tree). Cleared once config.sh has persisted .runner.
  trap 'rm -rf "${TARGET_DIR}"' ERR
  tar -xzf "${tarball_path}" -C "${TARGET_DIR}"

  runner_config_register "${TARGET_DIR}" "${TARGET_URL}" "${token}" "${LABELS}" "${TARGET_NAME}"
  trap - ERR   # registration persisted (.runner written); keep the dir
  runner_service_install "${TARGET_DIR}" "$(whoami)"
  runner_service_start "${TARGET_DIR}"

  # Unstick public-repo workflow dispatch (see lib/common.sh comment + #6).
  # Only meaningful for org-scoped runners; repo-scoped runners do not have
  # a runner-group flag.
  if [[ ${1:-} == "org" ]]; then
    if (( force )) && ! fork_pr_gate_is_safe "$2"; then
      echo "WARN: --force: the org's fork-PR approval gate is not 'all_external_contributors'; any fork PR can dispatch to this root-equivalent runner." >&2
    fi
    # #51: this flag is idempotent and non-critical -- the runner is already
    # registered and online by this point. A failure here must warn, not abort
    # the whole run (which would falsely signal the registration failed).
    enable_public_repos_dispatch "$2" \
      || echo "WARN: runner is registered and online, but enabling org public-repo dispatch failed; re-run ./script/add-runner.sh (idempotent) or set 'allows_public_repositories' manually." >&2
  fi

  echo "registered: ${TARGET_NAME} at ${TARGET_DIR}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
