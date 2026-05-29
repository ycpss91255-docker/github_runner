#!/usr/bin/env bash
# Prune stale artifacts that accumulate as GitHub's auto-update cycles
# runners forward. Three categories, all reversible in the sense that
# the runner service simply re-fetches what it needs on next restart:
#
#   1. Old `bin.X` / `externals.X` siblings in each runner dir, when
#      the active `bin` / `externals` symlink already points elsewhere
#      (each pair ~600 MB).
#   2. Old `actions-runner-linux-x64-*.tar.gz` blobs in `${RUNNER_HOME}/.bin/`
#      that are not the highest-version cached tarball (mirrors what
#      `find_cached_tarball` already picks).
#   3. `_work/_update/` + `_work/_update.sh` left by completed self-updates
#      (the `update.finished` 0-byte marker is the trustworthy signal that
#      these are stale; we never touch in-flight job dirs under `_work/`).
#
# Out of scope (intentionally, so `cleanup.sh` is safe to schedule):
#   - `_diag/*.log`              keep for debugging
#   - `.credentials*` / `.runner` / `.path` / `.env` / `.service`
#     registration state; nuking these turns the runner into a brick
#   - current `bin`, `bin.<active>`, `externals`, `externals.<active>`
#   - per-job dirs under `_work/<job-id>/`
#   - `update.finished` marker
#
# Usage:
#   ./scripts/cleanup.sh              # prompt before deleting
#   ./scripts/cleanup.sh --yes        # skip prompt (required for non-TTY runs)
#   ./scripts/cleanup.sh --dry-run    # print the plan, do nothing
#   ./scripts/cleanup.sh -h | --help  # show help
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

DRY_RUN=0
YES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes | -y] [--dry-run | -n] [-h | --help]

Prune stale runner artifacts left behind by GitHub's auto-update cycle:
older bin.X / externals.X version dirs, older cached tarballs in
\${RUNNER_HOME}/.bin/, and _work/_update remnants.

Options:
  -y, --yes        Skip the destructive-confirmation prompt. REQUIRED for
                   non-interactive runs (stdin is not a TTY).
  -n, --dry-run    Print the plan; do not touch anything.
  -h, --help       Show this help.

Exit code:
  0  Success (or dry-run / no-op).
  1  At least one rm failed, or non-interactive run was attempted
     without --yes.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -y|--yes)     YES=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

# Return the active runner version (e.g. "2.334.0") for a runner dir by
# reading its `bin` symlink target. Empty string if the symlink is missing
# (unconfigured runner) or points somewhere unparseable.
active_runner_version() {
  local dir=$1 target
  [[ -L "${dir}/bin" ]] || return 0
  target=$(readlink "${dir}/bin")
  basename "${target}" | sed -n 's/^bin\.\(.*\)$/\1/p'
}

# Emit one TAB-separated item per prunable path:
#   <path>\t<short-label>
# `<short-label>` is a human one-liner used in the plan output.
enumerate_items() {
  shopt -s nullglob
  local org_dir scope_dir org ver variant cand sub work_update work_update_sh

  for org_dir in "${RUNNER_HOME}"/*/; do
    org=$(basename "${org_dir}")
    [[ ${org} == ".bin" ]] && continue
    for scope_dir in "${org_dir}"*/; do
      [[ -f "${scope_dir}/.runner" ]] || continue
      ver=$(active_runner_version "${scope_dir%/}")
      for variant in bin externals; do
        for cand in "${scope_dir}${variant}".*; do
          [[ -d "${cand}" ]] || continue
          sub=$(basename "${cand}" | sed -n "s/^${variant}\\.\\(.*\\)$/\\1/p")
          [[ -z ${sub} ]] && continue
          if [[ -n ${ver} && ${sub} == "${ver}" ]]; then
            continue
          fi
          printf '%s\t%s %s/%s -> %s.%s\n' \
            "${cand%/}" "stale" "${org}" "$(basename "${scope_dir}")" \
            "${variant}" "${sub}"
        done
      done
      work_update="${scope_dir}_work/_update"
      work_update_sh="${scope_dir}_work/_update.sh"
      if [[ -d ${work_update} ]]; then
        printf '%s\t%s\n' "${work_update}" \
          "self-update remnant ${org}/$(basename "${scope_dir}")/_work/_update/"
      fi
      if [[ -f ${work_update_sh} ]]; then
        printf '%s\t%s\n' "${work_update_sh}" \
          "self-update remnant ${org}/$(basename "${scope_dir}")/_work/_update.sh"
      fi
    done
  done

  # Tarball cache: keep the highest-version, drop the rest.
  if [[ -d "${RUNNER_HOME}/.bin" ]]; then
    local -a tarballs=()
    while IFS= read -r line; do tarballs+=("${line}"); done < <(
      shopt -s nullglob
      printf '%s\n' "${RUNNER_HOME}/.bin/"actions-runner-linux-x64-*.tar.gz \
        | sort -V
    )
    if (( ${#tarballs[@]} > 1 )); then
      local last_index=$(( ${#tarballs[@]} - 1 ))
      local i
      for (( i=0; i<last_index; i++ )); do
        printf '%s\t%s\n' "${tarballs[i]}" \
          "old cached tarball $(basename "${tarballs[i]}")"
      done
    fi
  fi
}

# Print one path's size, falling back gracefully on missing files / no du.
human_size() {
  du -sh "$1" 2>/dev/null | cut -f1 || echo "?"
}

main() {
  parse_args "$@"

  if [[ ! -d ${RUNNER_HOME} ]]; then
    echo "Nothing to clean (no ${RUNNER_HOME})."
    exit 0
  fi

  local items
  items=$(enumerate_items)

  if [[ -z ${items} ]]; then
    echo "Nothing to clean under ${RUNNER_HOME}."
    exit 0
  fi

  local item_count
  item_count=$(grep -c '^' <<<"${items}")

  echo "Plan:"
  while IFS=$'\t' read -r path label; do
    printf '    - %-50s (%s)\n' "${label}" "$(human_size "${path}")"
  done <<<"${items}"
  echo

  if (( DRY_RUN )); then
    echo "Dry-run; nothing removed."
    exit 0
  fi

  if (( ! YES )); then
    if [[ ! -t 0 ]]; then
      echo "FAIL: non-interactive run requires --yes (stdin is not a TTY)" >&2
      exit 1
    fi
    read -r -p "Proceed with ${item_count} item(s)? [y/N] " ans
    case ${ans} in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; exit 0 ;;
    esac
  fi

  local removed=0 failed=0
  local fail_lines=()
  while IFS=$'\t' read -r path label; do
    if rm -rf -- "${path}"; then
      printf '  %s  removed\n' "${label}"
      removed=$(( removed + 1 ))
    else
      printf '  %s  FAILED\n' "${label}"
      fail_lines+=("${label}")
      failed=$(( failed + 1 ))
    fi
  done <<<"${items}"

  echo
  if (( failed == 0 )); then
    echo "Summary: ${removed} removed, 0 failed."
    exit 0
  else
    echo "Summary: ${removed} removed, ${failed} failed."
    printf '  %s\n' "${fail_lines[@]}"
    exit 1
  fi
}

main "$@"
