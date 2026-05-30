#!/usr/bin/env bash
# List local runner directories and their GitHub-side online status.
# Use --watch for periodic refresh with row-level diff highlighting.
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

WATCH=0
INTERVAL=5
COLOR="auto"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-w] [-n SECONDS] [--no-color]

Options:
  -w, --watch              Refresh continuously (Ctrl-C to exit).
  -n, --interval SECONDS   Refresh interval for --watch (default: ${INTERVAL}).
      --no-color           Disable color output.
  -h, --help               Show this help.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -w|--watch) WATCH=1; shift ;;
      -n|--interval)
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
  case ${COLOR} in
    always) use=1 ;;
    never) use=0 ;;
    auto) [[ -t 1 ]] && use=1 ;;
  esac
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
    if systemctl list-units --type=service --no-legend 2>/dev/null \
         | grep -q "actions.runner.*${name}"; then
      svc_state="running"
    fi

    local gh_state public_state labels
    if [[ ${scope} == "org" ]]; then
      gh_state=$(gh api "/orgs/${org}/actions/runners" \
        --jq ".runners[] | select(.name==\"${name}\") | .status" 2>/dev/null \
        || echo "n/a")
      labels=$(gh api "/orgs/${org}/actions/runners" \
        --jq "[.runners[] | select(.name==\"${name}\") | .labels[].name] | join(\",\")" 2>/dev/null \
        || echo "")
      # Check Default runner-group public-repo dispatch flag. Without this
      # flag set true, public-repo workflows silently stay queued even
      # when the runner is online + idle (see lib/common.sh enable_public_
      # repos_dispatch comment + #6). Surfaces as a column here so the
      # mismatch is visible at a glance.
      local flag
      flag=$(gh api "/orgs/${org}/actions/runner-groups/1" \
        --jq '.allows_public_repositories' 2>/dev/null || echo "")
      case ${flag} in
        true)  public_state="public-ok" ;;
        false) public_state="public-BLOCKED" ;;
        *)     public_state="n/a" ;;
      esac
    else
      gh_state=$(gh api "/repos/${org}/${scope_id}/actions/runners" \
        --jq ".runners[] | select(.name==\"${name}\") | .status" 2>/dev/null \
        || echo "n/a")
      labels=$(gh api "/repos/${org}/${scope_id}/actions/runners" \
        --jq "[.runners[] | select(.name==\"${name}\") | .labels[].name] | join(\",\")" 2>/dev/null \
        || echo "")
      # Repo-scoped runners don't have a runner-group flag; the
      # public/private decision is per-repo visibility.
      public_state="-"
    fi
    [[ -z ${gh_state} ]] && gh_state="not-found"
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
      printf '\033[H\033[2J'
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
