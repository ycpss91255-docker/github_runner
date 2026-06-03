#!/usr/bin/env bash
# List local runner directories and their GitHub-side online status.
# Use --watch for periodic refresh with row-level diff highlighting.
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

WATCH=0
INTERVAL=5
COLOR="auto"
USE_ANSI=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [-w] [-i SECONDS] [--no-color]

Options:
  -w, --watch              Refresh continuously (Ctrl-C to exit).
  -i, --interval SECONDS   Refresh interval for --watch (default: ${INTERVAL}).
      --no-color           Disable color output (also honors NO_COLOR).
  -h, --help               Show this help.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -w|--watch) WATCH=1; shift ;;
      -i|--interval)
        [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 1; }
        [[ $2 =~ ^[0-9]+$ ]] || { echo "interval must be a positive integer" >&2; exit 1; }
        INTERVAL=$2; shift 2 ;;
      --no-color) COLOR="never"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

setup_colors() {
  local use=0
  # U6: honor the cross-tool NO_COLOR convention, overriding tty auto-detect.
  [[ -n ${NO_COLOR:-} ]] && COLOR="never"
  case ${COLOR} in
    always) use=1 ;;
    never) use=0 ;;
    auto) [[ -t 1 ]] && use=1 ;;
  esac
  # Expose the same gate for non-SGR ANSI control sequences (e.g. the
  # --watch clear-screen). UX: --no-color / NO_COLOR / non-TTY all suppress
  # raw escapes, not just colors, so piped/captured output stays clean.
  USE_ANSI=${use}
  if (( use )); then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    C_HL=$'\033[7m'
  else
    C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_RED="" C_YELLOW="" C_HL=""
  fi
}

state_color() {
  case $1 in
    running|online|public-ok) printf '%s' "${C_GREEN}" ;;
    stopped|offline|public-BLOCKED) printf '%s' "${C_RED}" ;;
    *) printf '%s' "${C_YELLOW}" ;;
  esac
}

# Print one state cell with color, padded to $1 visible characters.
print_state() {
  local width=$1 text=$2
  local pad=$(( width - ${#text} ))
  (( pad < 0 )) && pad=0
  printf '%s%s%s%*s' "$(state_color "${text}")" "${text}" "${C_RESET}" "${pad}" ""
}

collect_rows() {
  local scope org name scope_id
  # runner_dir (4th field) is unused here; the underscore discards it
  # while keeping positional alignment with list_runners' contract.
  while IFS=$'\t' read -r scope org name _ scope_id; do
    local svc_state="stopped"
    if runner_service_running "${name}"; then
      svc_state="running"
    fi

    # One call to GitHub for both status and labels; this script owns the
    # display vocabulary, the adapter only reports what GitHub said:
    #   exit 0 -> "<status>\t<labels>"   exit 2 -> not-found   exit 1 -> n/a
    local gh_state public_state labels row rc
    row=$(github_runner_status "$(runner_api_base "${scope}" "${org}" "${scope_id}")" "${name}")
    rc=$?
    case ${rc} in
      0) IFS=$'\t' read -r gh_state labels <<<"${row}" ;;
      2) gh_state="not-found"; labels="" ;;
      *) gh_state="n/a";       labels="" ;;
    esac

    if [[ ${scope} == "org" ]]; then
      # Check Default runner-group public-repo dispatch flag. Without this
      # flag set true, public-repo workflows silently stay queued even
      # when the runner is online + idle (see lib/common.sh enable_public_
      # repos_dispatch comment + #6). Surfaces as a column here so the
      # mismatch is visible at a glance.
      local flag
      flag=$(_gh api "/orgs/${org}/actions/runner-groups/1" \
        --jq '.allows_public_repositories' 2>/dev/null || echo "")
      case ${flag} in
        true)  public_state="public-ok" ;;
        false) public_state="public-BLOCKED" ;;
        *)     public_state="n/a" ;;
      esac
    else
      # Repo-scoped runners don't have a runner-group flag; the
      # public/private decision is per-repo visibility.
      public_state="-"
    fi
    [[ -z ${labels} ]] && labels="-"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${name}" "${scope}" "${svc_state}" "${gh_state}" "${public_state}" "${labels}"
  done < <(list_runners)
}

render_header() {
  printf '%sEvery %ss: %s runners%s  %s\n\n' \
    "${C_DIM}" "${INTERVAL}" "$(hostname)" "${C_RESET}" "$(date '+%Y-%m-%d %H:%M:%S')"
}

render_table() {
  local rows=$1 prev=$2
  printf '%s%-40s %-10s %-10s %-10s %-16s %s%s\n' "${C_BOLD}" \
    "NAME" "SCOPE" "LOCAL-SVC" "GITHUB" "PUBLIC-DISPATCH" "LABELS" "${C_RESET}"
  printf '%-40s %-10s %-10s %-10s %-16s %s\n' \
    "----" "-----" "---------" "------" "---------------" "------"

  if [[ -z ${rows} ]]; then
    printf '%s(no runners found in %s)%s\n' "${C_DIM}" "${RUNNER_HOME}" "${C_RESET}"
    return
  fi

  local name scope svc gh public labels line changed hl rst
  while IFS=$'\t' read -r name scope svc gh public labels; do
    line="${name}"$'\t'"${scope}"$'\t'"${svc}"$'\t'"${gh}"$'\t'"${public}"$'\t'"${labels}"
    changed=0
    if (( WATCH )) && [[ -n ${prev} ]] && ! grep -qxF -- "${line}" <<<"${prev}"; then
      changed=1
    fi
    hl=""; rst=""
    (( changed )) && { hl="${C_HL}"; rst="${C_RESET}"; }

    printf '%s%-40s %-10s ' "${hl}" "${name}" "${scope}"
    print_state 10 "${svc}"; printf ' '
    print_state 10 "${gh}"; printf ' '
    print_state 16 "${public}"; printf ' %s' "${labels}"
    printf '%s\n' "${rst}"
  done <<<"${rows}"
}

main() {
  parse_args "$@"
  setup_colors

  if [[ ! -d ${RUNNER_HOME} ]]; then
    echo "no ${RUNNER_HOME} directory. run ./script/init.sh first."
    exit 0
  fi

  if (( WATCH )); then
    trap 'printf "\n"; exit 0' INT TERM
    local prev_rows="" rows
    while :; do
      rows=$(collect_rows)
      # Gate the cursor-home + clear-screen the same way SGR colors are
      # gated (setup_colors' USE_ANSI): a raw escape into a pipe / non-TTY
      # or under --no-color would corrupt captured output.
      (( USE_ANSI )) && printf '\033[H\033[2J'
      render_header
      render_table "${rows}" "${prev_rows}"
      prev_rows=${rows}
      sleep "${INTERVAL}"
    done
  else
    render_table "$(collect_rows)" ""
  fi
}

main "$@"
