#!/usr/bin/env bash
# Tear down all runners on this host + clear the tarball cache.
# Counterpart to init.sh. See #11 for the design discussion.
#
# Usage:
#   ./script/uninstall.sh                  # prompt before any destructive action
#   ./script/uninstall.sh --yes            # skip the prompt (required for non-TTY runs)
#   ./script/uninstall.sh --dry-run        # print the plan, do nothing
#   ./script/uninstall.sh -h | --help      # show help
#
# Deliberate non-actions (mirror #11 design):
#   - Does NOT change org-level runner-group flags. The
#     allows_public_repositories flag is org-scoped, not host-scoped;
#     flipping it back would silently break other machines / maintainers
#     sharing the same org's runner pool. See #6 for context.
#   - Does NOT remove the github_runner checkout itself. The user invokes
#     this script *from* the checkout.
#   - Does NOT touch gh auth state.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

DRY_RUN=0
YES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes | -y] [--dry-run | -n] [-h | --help]

Tear down every runner registered through this checkout + remove the
cached actions-runner tarball.

Options:
  -y, --yes        Skip the destructive-confirmation prompt. REQUIRED for
                   non-interactive runs (stdin is not a TTY).
  -n, --dry-run    Print the plan; do not touch anything.
  -h, --help       Show this help.

Exit code:
  0  Success (or dry-run / no-op).
  1  At least one target failed to deregister, or non-interactive run was
     attempted without --yes.
EOF
}

# Emit one TAB-separated line per registered runner, reusing the contract
# from lib/common.sh::list_runners but dropping fields uninstall doesn't
# need (name + runner_dir) so the rest of this script keeps its current
# read-and-dispatch shape:
#   org\t<org-name>
#   repo\t<owner>\t<repo>
enumerate_targets() {
  local scope org scope_id
  while IFS=$'\t' read -r scope org _ _ scope_id; do
    if [[ ${scope} == "org" ]]; then
      printf 'org\t%s\n' "${org}"
    else
      printf 'repo\t%s\t%s\n' "${org}" "${scope_id}"
    fi
  done < <(list_runners)
}

# Pretty-print one target line. $1 = scope, $2 = arg1, $3 = arg2 (optional).
format_target() {
  if [[ $1 == "org" ]]; then
    printf 'org %s' "$2"
  else
    printf 'repo %s/%s' "$2" "$3"
  fi
}

main() {
  parse_destructive_flags "$@"

  local targets
  targets=$(enumerate_targets)

  local target_count=0
  if [[ -n ${targets} ]]; then
    target_count=$(grep -c '^' <<<"${targets}")
  fi

  local cache_size=""
  if [[ -d "${RUNNER_HOME}/.bin" ]]; then
    cache_size=$(du -sh "${RUNNER_HOME}/.bin" 2>/dev/null | cut -f1 || true)
  fi

  if (( target_count == 0 )) && [[ -z ${cache_size} ]]; then
    echo "Nothing to remove (no registered runners, no tarball cache under ${RUNNER_HOME})."
    exit 0
  fi

  echo "Plan:"
  echo "  Runners to deregister: ${target_count}"
  if [[ -n ${targets} ]]; then
    while IFS=$'\t' read -r scope a1 a2; do
      printf '    - %s\n' "$(format_target "${scope}" "${a1}" "${a2}")"
    done <<<"${targets}"
  fi
  if [[ -n ${cache_size} ]]; then
    echo "  Tarball cache: ${RUNNER_HOME}/.bin (${cache_size})"
  fi
  echo

  if (( DRY_RUN )); then
    echo "Dry-run; nothing removed."
    exit 0
  fi

  confirm_or_abort "Proceed? [y/N] "

  local removed=0 failed=0
  local fail_lines=()
  if [[ -n ${targets} ]]; then
    local idx=0
    while IFS=$'\t' read -r scope a1 a2; do
      idx=$(( idx + 1 ))
      local label
      label="[${idx}/${target_count}] $(format_target "${scope}" "${a1}" "${a2}")"
      local rc=0
      if [[ ${scope} == "org" ]]; then
        "${SCRIPT_DIR}/remove-runner.sh" org "${a1}" || rc=$?
      else
        "${SCRIPT_DIR}/remove-runner.sh" repo "${a1}" "${a2}" || rc=$?
      fi
      if (( rc == 0 )); then
        echo "${label}  ✓ removed"
        removed=$(( removed + 1 ))
      else
        echo "${label}  ✗ FAILED (exit ${rc})"
        fail_lines+=("${label}")
        failed=$(( failed + 1 ))
      fi
    done <<<"${targets}"
  fi

  if [[ -n ${cache_size} ]]; then
    if rm -rf "${RUNNER_HOME}/.bin"; then
      echo "[cache] ${RUNNER_HOME}/.bin  ✓ removed (${cache_size})"
    else
      echo "[cache] ${RUNNER_HOME}/.bin  ✗ FAILED"
      fail_lines+=("[cache] ${RUNNER_HOME}/.bin")
      failed=$(( failed + 1 ))
    fi
  fi

  print_summary "${removed}" "${failed}" ${fail_lines[@]+"${fail_lines[@]}"}
}

main "$@"
