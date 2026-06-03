#!/usr/bin/env bash
# Install, inspect or remove a user-crontab entry that runs cleanup.sh on
# a schedule the user picks. Runs as the invoking user -- no sudo, no
# /etc/cron.d. The entry is tagged with a marker comment so this script
# can rewrite or remove it idempotently without touching unrelated lines.
#
# Usage:
#   ./script/schedule-cleanup.sh                       # interactive
#   ./script/schedule-cleanup.sh --install              # interactive (same)
#   ./script/schedule-cleanup.sh --install --every weekly --at 03:30 --day Sun
#   ./script/schedule-cleanup.sh --install --every daily --at 04:00
#   ./script/schedule-cleanup.sh --install --every monthly --at 05:00
#   ./script/schedule-cleanup.sh --status               # show installed entry
#   ./script/schedule-cleanup.sh --uninstall            # remove entry
#   ./script/schedule-cleanup.sh -h | --help
#
# Notes:
#   - The cron command uses `flock -n` against ${RUNNER_HOME}/.cleanup.lock
#     so an overlapping fire just exits silently instead of stacking.
#   - Output is appended to ${RUNNER_HOME}/.cleanup.log; rotate / inspect
#     with the user's usual tooling.
#   - Cron runs with an empty environment by default, so the entry uses
#     fully-resolved absolute paths captured at install time. If you move
#     the checkout or change RUNNER_HOME, re-run --install to refresh.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# Marker the install/uninstall logic uses to find its own entry. Anything
# else in the user's crontab is left untouched.
readonly CRON_MARKER="# github_runner cleanup"

# Override hook for the bats suite -- defaults to the real crontab binary.
CRONTAB_CMD=${CRONTAB_CMD:-crontab}

ACTION=""
EVERY=""
AT=""
DAY=""
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--install [--every FREQ] [--at HH:MM] [--day DOW]]
       $(basename "$0") --status
       $(basename "$0") --uninstall
       $(basename "$0") [--install | --uninstall] [--dry-run | -n]
       $(basename "$0") -h | --help

Install, inspect or remove a user-crontab entry that runs cleanup.sh on
a schedule.

Options:
      --install        Install / replace the cron entry. With no further
                       flags, prompts interactively for FREQ, HH:MM, DOW.
      --status         Print the installed cron entry (or "(none)").
      --uninstall      Remove the cron entry.
      --every FREQ     daily | weekly | monthly. Default: weekly.
      --at HH:MM       24-hour local time. Default: 03:30.
      --day DOW        Day of week for --every weekly (Sun..Sat or 0..6).
                       Default: Sun.
  -n, --dry-run    Print the merged crontab that --install / --uninstall
                       WOULD write, then exit without touching the crontab.
  -h, --help           Show this help.

Exit codes:
  0  Success / status reported / nothing-to-do / dry-run.
  1  Usage error or invalid input.
  2  --install requested with bad / unparseable flag combination.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --install)   ACTION="install";   shift ;;
      --uninstall) ACTION="uninstall"; shift ;;
      --status)    ACTION="status";    shift ;;
      --every)     [[ $# -ge 2 ]] || { echo "missing value for --every" >&2; exit 1; }
                   EVERY=$2; shift 2 ;;
      --at)        [[ $# -ge 2 ]] || { echo "missing value for --at" >&2; exit 1; }
                   AT=$2; shift 2 ;;
      --day)       [[ $# -ge 2 ]] || { echo "missing value for --day" >&2; exit 1; }
                   DAY=$2; shift 2 ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *)           echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
  # Bare invocation = interactive install.
  if [[ -z ${ACTION} ]]; then
    ACTION="install"
  fi
}

# Lowercase shorthand for branching on freq.
normalize_every() {
  case ${1,,} in
    d|daily)   echo "daily" ;;
    w|weekly)  echo "weekly" ;;
    m|monthly) echo "monthly" ;;
    *)         return 1 ;;
  esac
}

# Validate HH:MM (24-hour). Echoes the canonical "HH:MM" on success or
# returns 1 on failure. Single-digit hours / minutes are zero-padded.
parse_time() {
  local raw=$1 h m
  if [[ ! ${raw} =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    return 1
  fi
  h=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
  (( 10#${h} >= 0 && 10#${h} <= 23 )) || return 1
  (( 10#${m} >= 0 && 10#${m} <= 59 )) || return 1
  printf '%02d:%02d' "$((10#${h}))" "$((10#${m}))"
}

# Day of week -> cron field 0..6. Accepts Sun/Mon/.../Sat (case-insensitive)
# or 0..6 directly.
parse_dow() {
  case ${1,,} in
    sun|0) echo 0 ;;
    mon|1) echo 1 ;;
    tue|2) echo 2 ;;
    wed|3) echo 3 ;;
    thu|4) echo 4 ;;
    fri|5) echo 5 ;;
    sat|6) echo 6 ;;
    *)     return 1 ;;
  esac
}

# Build the schedule's `m h dom mon dow` prefix. Args: freq HH:MM dow.
# dow is only used for weekly; ignored otherwise.
build_schedule_prefix() {
  local freq=$1 hm=$2 dow=$3
  local h=${hm%:*} m=${hm#*:}
  case ${freq} in
    daily)   printf '%d %d * * *'   "$((10#${m}))" "$((10#${h}))" ;;
    weekly)  printf '%d %d * * %d'  "$((10#${m}))" "$((10#${h}))" "${dow}" ;;
    monthly) printf '%d %d 1 * *'   "$((10#${m}))" "$((10#${h}))" ;;
    *) return 1 ;;
  esac
}

# Compose the full crontab line we'll persist.
build_cron_line() {
  local freq=$1 hm=$2 dow=$3 lockfile=$4 logfile=$5 cleanup_bin=$6
  local prefix
  prefix=$(build_schedule_prefix "${freq}" "${hm}" "${dow}")
  # CRON_MARKER trails the command: under cron's `sh -c`, the `# ...` is a
  # shell COMMENT (the entry's tag for idempotent install/uninstall), NOT an
  # argument to flock. Keep it last so a refactor doesn't feed it to flock.
  printf "%s flock -n %s -c '%s --yes >> %s 2>&1' %s\n" \
    "${prefix}" "${lockfile}" "${cleanup_bin}" "${logfile}" "${CRON_MARKER}"
}

# Take "current crontab text" on stdin and emit "current minus our entry".
strip_marker() {
  grep -v -- "${CRON_MARKER}" || true
}

# Take "current crontab text" on stdin + new line as $1; emit the merged
# crontab. Uses strip_marker so re-install replaces idempotently.
merge_crontab() {
  local new_line=$1
  strip_marker
  printf '%s\n' "${new_line}"
}

# Read current crontab safely (returns empty if user has no crontab).
read_crontab() {
  "${CRONTAB_CMD}" -l 2>/dev/null || true
}

write_crontab() {
  "${CRONTAB_CMD}" -
}

# Interactive prompt for the three knobs. Default values are pre-filled.
prompt_install_params() {
  local choice
  if [[ -z ${EVERY} ]]; then
    read -r -p "Frequency? [d=daily, w=weekly (default), m=monthly] " choice
    EVERY=${choice:-w}
  fi
  EVERY=$(normalize_every "${EVERY}") || {
    echo "invalid --every: ${EVERY}" >&2; exit 1; }

  if [[ -z ${AT} ]]; then
    read -r -p "Time of day [HH:MM, default 03:30]? " choice
    AT=${choice:-03:30}
  fi
  AT=$(parse_time "${AT}") || {
    echo "invalid --at: not HH:MM in 00:00..23:59 range" >&2; exit 1; }

  local dow_field="-"
  if [[ ${EVERY} == "weekly" ]]; then
    if [[ -z ${DAY} ]]; then
      read -r -p "Day of week [Sun..Sat or 0..6, default Sun]? " choice
      DAY=${choice:-Sun}
    fi
    dow_field=$(parse_dow "${DAY}") || {
      echo "invalid --day: ${DAY}" >&2; exit 1; }
  fi
  # Echo the dow back via a global -- avoids passing it on every call.
  PARSED_DOW=${dow_field}
}

cmd_install() {
  prompt_install_params

  local cleanup_bin="${SCRIPT_DIR}/cleanup.sh"
  local lockfile="${RUNNER_HOME}/.cleanup.lock"
  local logfile="${RUNNER_HOME}/.cleanup.log"

  if [[ ! -x ${cleanup_bin} ]]; then
    echo "FAIL: ${cleanup_bin} not executable" >&2
    exit 2
  fi
  mkdir -p "${RUNNER_HOME}"

  local new_line
  new_line=$(build_cron_line \
    "${EVERY}" "${AT}" "${PARSED_DOW}" \
    "${lockfile}" "${logfile}" "${cleanup_bin}")

  echo "Cron entry:"
  echo "  ${new_line}"

  local current merged
  current=$(read_crontab)
  merged=$(merge_crontab "${new_line}" <<<"${current}")
  # Drop leading blank lines: a here-string of an empty crontab still feeds one
  # newline through strip_marker, which would otherwise persist as a stray
  # first line on every fresh install. sed '/./,$!d' is busybox-safe and keeps
  # intentional interior blanks.
  if (( DRY_RUN )); then
    echo "Dry-run; crontab that would be written:"
    printf '%s\n' "${merged}" | sed '/./,$!d'
    echo "Dry-run; crontab not modified."
    exit 0
  fi
  printf '%s\n' "${merged}" | sed '/./,$!d' | write_crontab
  echo "Installed (replaces any previous github_runner cleanup entry)."
  echo "Log:  ${logfile}"
  echo "Lock: ${lockfile}"
}

cmd_uninstall() {
  local current stripped
  current=$(read_crontab)
  if ! grep -q -- "${CRON_MARKER}" <<<"${current}"; then
    echo "No installed entry. Nothing to do."
    exit 0
  fi
  stripped=$(strip_marker <<<"${current}")
  if (( DRY_RUN )); then
    echo "Dry-run; crontab that would be written:"
    if [[ -z ${stripped} ]]; then
      echo "  (crontab would be removed entirely)"
    else
      printf '%s\n' "${stripped}"
    fi
    echo "Dry-run; crontab not modified."
    exit 0
  fi
  if [[ -z ${stripped} ]]; then
    # Empty crontab -- remove it entirely so `crontab -l` reports cleanly.
    "${CRONTAB_CMD}" -r 2>/dev/null || true
  else
    printf '%s\n' "${stripped}" | write_crontab
  fi
  echo "Removed."
}

cmd_status() {
  local current entry
  current=$(read_crontab)
  entry=$(grep -- "${CRON_MARKER}" <<<"${current}" || true)
  if [[ -z ${entry} ]]; then
    echo "(none)"
    exit 0
  fi
  printf '%s\n' "${entry}"
}

main() {
  parse_args "$@"
  case ${ACTION} in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    *) echo "internal: unknown action ${ACTION}" >&2; exit 1 ;;
  esac
}

main "$@"
