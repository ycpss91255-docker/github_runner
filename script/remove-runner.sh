#!/usr/bin/env bash
# Deregister + uninstall service + remove directory. Idempotent.
#
# Destructive on its own, so it carries the same preview/confirm contract as
# uninstall.sh and cleanup.sh (reversibility first): print the plan, then gate
# the teardown behind an explicit confirmation.
#
# Usage:
#   ./script/remove-runner.sh org <org>                # prompt before removing
#   ./script/remove-runner.sh repo <owner> <repo>
#   ./script/remove-runner.sh --dry-run org <org>      # print the plan, do nothing
#   ./script/remove-runner.sh --yes org <org>          # skip the prompt (non-TTY)
#   ./script/remove-runner.sh -h | --help              # show help
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

DRY_RUN=0
YES=0
# Positional args left over once the flags are stripped (scope + identifiers).
POSITIONAL=()

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--yes | -y] [--dry-run | -n] org <org>
  $(basename "$0") [--yes | -y] [--dry-run | -n] repo <owner> <repo>

Deregister a runner, uninstall its systemd service, and remove its
directory. Idempotent.

Options:
  -y, --yes        Skip the destructive-confirmation prompt. REQUIRED for
                   non-interactive runs (stdin is not a TTY).
  -n, --dry-run    Print the plan; do not touch anything.
  -h, --help       Show this help.

Exit code:
  0  Removed (or dry-run / nothing to remove / aborted at the prompt).
  1  Bad usage, deregistration failed, or a non-interactive run was
     attempted without --yes.
EOF
}

# Like lib/common.sh::parse_destructive_flags, but this script also takes
# positional args (the scope + its identifiers), so the flags are stripped
# here and the rest handed back through POSITIONAL. Flags may appear before
# or after the scope; only a leading '-' is treated as an option.
parse_args() {
  POSITIONAL=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      -y|--yes)     YES=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      -*)           echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
      *)            POSITIONAL+=("$1"); shift ;;
    esac
  done
}

main() {
  parse_args "$@"
  set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

  case "${1:-}" in
    org|repo) : ;;
    *) usage >&2; exit 1 ;;
  esac
  resolve_target "$@"

  if [[ ! -f "${TARGET_DIR}/.runner" ]]; then
    echo "no runner at ${TARGET_DIR}, nothing to remove."
    exit 0
  fi

  echo "Plan:"
  echo "  Runner:            ${TARGET_NAME}"
  echo "  Deregister from:   ${TARGET_URL}"
  echo "  Uninstall service: the systemd service for ${TARGET_NAME}"
  echo "  Remove directory:  ${TARGET_DIR}"
  echo

  if (( DRY_RUN )); then
    echo "Dry-run; nothing removed."
    exit 0
  fi

  # Gate the teardown on explicit consent. A non-TTY run without --yes is
  # refused (exit 1) instead of proceeding -- same contract as uninstall.sh.
  confirm_or_abort "Proceed? [y/N] "

  # U3: gate on auth and fetch the remove-token BEFORE any service teardown,
  # so an unauthenticated / offline host fails cleanly instead of leaving a
  # stopped-but-still-registered (half-removed) runner.
  require_gh_auth
  local token
  token=$(github_runner_token "${TARGET_API_REMOVE_PATH}")

  runner_service_stop "${TARGET_DIR}"
  runner_service_uninstall "${TARGET_DIR}"
  runner_config_deregister "${TARGET_DIR}" "${token}"

  # SEC-4 defense-in-depth: TARGET_DIR is already confined by RUNNER_HOME's
  # SEC-3 normalization + resolve_target's identifier validation, but anchor
  # the rm to RUNNER_HOME lexically before deleting, so no future change can
  # turn this into an out-of-tree rm -rf.
  assert_under_runner_home "${TARGET_DIR}" || exit 1
  rm -rf "${TARGET_DIR}"
  echo "removed: ${TARGET_NAME}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
