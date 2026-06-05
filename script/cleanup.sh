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
# Also rotated (#55):
#   4. `_diag/*.log` older than RUNNER_DIAG_KEEP_DAYS (default 14). Kept for
#      debugging, but rotated so they cannot grow without bound; recent logs
#      stay.
#
# Opt-in, only with `--work-caches` (#58):
#   5. Entries under `_work/_tool` and `_work/_actions` (the runner's tool /
#      action download caches) older than RUNNER_WORK_CACHE_KEEP_DAYS (default
#      7), and only for runners that are NOT currently running a job. These
#      caches are reused across jobs, so pruning them is a space-vs-refetch
#      trade-off, hence opt-in. A runner is "busy" if a `Runner.Worker` process
#      is running under its `bin/` (only the idle `Runner.Listener` runs between
#      jobs); if `pgrep` is unavailable we treat the runner as busy and skip it
#      (fail-safe -- never prune a cache a live job might be using).
#
# Out of scope (intentionally, so the default run is safe to schedule):
#   - recent `_diag/*.log` (within the retention window) -- debugging
#   - `.credentials*` / `.runner` / `.path` / `.env` / `.service`
#     registration state; nuking these turns the runner into a brick
#   - current `bin`, `bin.<active>`, `externals`, `externals.<active>`
#   - `_work/<repo>/` checkout/build trees -- reused incremental build state;
#     too costly to reclaim automatically (left to the operator)
#   - `update.finished` marker
#
# Usage:
#   ./script/cleanup.sh              # prompt before deleting
#   ./script/cleanup.sh --yes        # skip prompt (required for non-TTY runs)
#   ./script/cleanup.sh --dry-run    # print the plan, do nothing
#   ./script/cleanup.sh -h | --help  # show help
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

DRY_RUN=0
YES=0
CACHES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes | -y] [--dry-run | -n] [--work-caches] [-h | --help]

Prune stale runner artifacts left behind by GitHub's auto-update cycle:
older bin.X / externals.X version dirs, older cached tarballs in
\${RUNNER_HOME}/.bin/, _work/_update remnants, and _diag/*.log older than
RUNNER_DIAG_KEEP_DAYS (default 14). Reports RUNNER_HOME disk usage and warns
at/above RUNNER_DISK_WARN_PCT (default 90).

Options:
  -y, --yes        Skip the destructive-confirmation prompt. REQUIRED for
                   non-interactive runs (stdin is not a TTY).
  -n, --dry-run    Print the plan; do not touch anything.
      --work-caches  ALSO prune old entries under each idle runner's
                   _work/_tool and _work/_actions download caches (older than
                   RUNNER_WORK_CACHE_KEEP_DAYS, default 7). Skips any runner
                   that is currently running a job. Opt-in: the default /
                   scheduled run never touches _work. Requires \`pgrep\`.
  -h, --help       Show this help.

Environment:
  RUNNER_DIAG_KEEP_DAYS        Age (days) beyond which _diag/*.log are pruned (14).
  RUNNER_DISK_WARN_PCT         Disk-usage %% at/above which a warning prints (90).
  RUNNER_WORK_CACHE_KEEP_DAYS  Age (days) for --work-caches pruning (7).

Exit code:
  0  Success (or dry-run / no-op).
  1  At least one rm failed, or non-interactive run was attempted
     without --yes.
EOF
}

# A runner is "busy" iff a Runner.Worker process is running under its bin/
# (only the idle Runner.Listener runs between jobs). Fail safe: if pgrep is
# unavailable we cannot tell, so report busy and let the caller skip it -- we
# must never prune a cache a live job might be using. #58.
runner_busy() {
  local dir=${1%/}
  command -v pgrep >/dev/null 2>&1 || return 0
  pgrep -af 'Runner\.Worker' 2>/dev/null | grep -qF "${dir}/bin/Runner.Worker"
}

# Emit one TAB-separated item per prunable path:
#   <path>\t<short-label>
# `<short-label>` is a human one-liner used in the plan output.
enumerate_items() {
  shopt -s nullglob
  local scope org runner_dir scope_label ver variant cand sub
  local work_update work_update_sh diag_log cache_sub cache_ent
  local keep_days=${RUNNER_DIAG_KEEP_DAYS:-14}
  local cache_keep=${RUNNER_WORK_CACHE_KEEP_DAYS:-7}

  while IFS=$'\t' read -r scope org _ runner_dir _; do
    # Re-derive the on-disk label (_org for org-scoped, repo name for
    # repo-scoped) so prune messages stay identical to the previous form.
    scope_label=$(basename "${runner_dir}")
    ver=$(runner_active_version "${runner_dir}")
    # #50: an empty active version means the `bin` symlink is missing (e.g. a
    # half-extracted runner). We CANNOT tell which variant dir is live, so
    # pruning here would mark the in-use bin.X/externals.X as stale and delete
    # it. Skip variant pruning entirely for such a runner; the _work/_update
    # remnant pruning below is safe regardless and still runs.
    if [[ -n ${ver} ]]; then
      for variant in bin externals; do
        for cand in "${runner_dir}/${variant}".*; do
          [[ -d "${cand}" ]] || continue
          sub=$(basename "${cand}" | sed -n "s/^${variant}\\.\\(.*\\)$/\\1/p")
          [[ -z ${sub} ]] && continue
          if [[ ${sub} == "${ver}" ]]; then
            continue
          fi
          printf '%s\t%s %s/%s -> %s.%s\n' \
            "${cand%/}" "stale" "${org}" "${scope_label}" \
            "${variant}" "${sub}"
        done
      done
    fi
    work_update="${runner_dir}/_work/_update"
    work_update_sh="${runner_dir}/_work/_update.sh"
    if [[ -d ${work_update} ]]; then
      printf '%s\t%s\n' "${work_update}" \
        "self-update remnant ${org}/${scope_label}/_work/_update/"
    fi
    if [[ -f ${work_update_sh} ]]; then
      printf '%s\t%s\n' "${work_update_sh}" \
        "self-update remnant ${org}/${scope_label}/_work/_update.sh"
    fi
    # #55: rotate _diag logs older than the retention window. find prints
    # nothing (and the 2>/dev/null swallows the error) when _diag is absent.
    while IFS= read -r diag_log; do
      [[ -n ${diag_log} ]] || continue
      printf '%s\t%s\n' "${diag_log}" \
        "old _diag log ${org}/${scope_label}/$(basename "${diag_log}")"
    done < <(find "${runner_dir}/_diag" -maxdepth 1 -type f -name '*.log' \
               -mtime +"${keep_days}" 2>/dev/null)
    # #58: opt-in (--work-caches) pruning of the reused _work download caches,
    # but only for an idle runner -- a busy one may be reading/writing them.
    if (( CACHES )); then
      if runner_busy "${runner_dir}"; then
        echo "note: ${org}/${scope_label} is running a job; skipping its _work caches" >&2
      else
        for cache_sub in _tool _actions; do
          while IFS= read -r cache_ent; do
            [[ -n ${cache_ent} ]] || continue
            printf '%s\t%s\n' "${cache_ent}" \
              "stale _work/${cache_sub} ${org}/${scope_label}/$(basename "${cache_ent}")"
          done < <(find "${runner_dir}/_work/${cache_sub}" -mindepth 1 -maxdepth 1 \
                     -mtime +"${cache_keep}" 2>/dev/null)
        done
      fi
    fi
  done < <(list_runners)
  # Silence shellcheck: scope is consumed positionally by `read`.
  : "${scope:-}"

  # Tarball cache: keep the highest-version, drop the rest. runner_release_
  # cached_list owns the .bin/ glob (ascending by version) and is empty-safe
  # when .bin/ does not exist, so no -d guard is needed here.
  local -a tarballs=()
  while IFS= read -r line; do tarballs+=("${line}"); done < <(runner_release_cached_list)
  if (( ${#tarballs[@]} > 1 )); then
    local last_index=$(( ${#tarballs[@]} - 1 ))
    local i
    for (( i=0; i<last_index; i++ )); do
      printf '%s\t%s\n' "${tarballs[i]}" \
        "old cached tarball $(basename "${tarballs[i]}")"
    done
  fi
}

# Print one path's size, falling back gracefully on missing files / no du.
human_size() {
  du -sh "$1" 2>/dev/null | cut -f1 || echo "?"
}

# Report RUNNER_HOME filesystem usage and warn at/above the threshold
# (RUNNER_DISK_WARN_PCT, default 90). cleanup reclaims update leftovers + old
# _diag logs but NOT _work/<job-id> job dirs (#58), so disk can stay high even
# after a clean run -- this surfaces that so a time-driven schedule doesn't
# mask a pressure problem. #55.
report_disk_pressure() {
  local pct threshold=${RUNNER_DISK_WARN_PCT:-90}
  pct=$(disk_usage_percent "${RUNNER_HOME}")
  [[ -n ${pct} ]] || return 0
  echo "disk: ${pct}% used on the filesystem holding ${RUNNER_HOME}."
  if (( pct >= threshold )); then
    echo "WARN: at/above ${threshold}% -- the default run does not reclaim _work; try" >&2
    echo "      --work-caches (prunes idle runners' _tool/_actions caches), and inspect" >&2
    echo "      _work/<repo> build trees (e.g. du -sh ${RUNNER_HOME}/*/*/_work/*) if low." >&2
  fi
}

main() {
  # Pull our cleanup-specific --work-caches out, then hand the rest to the
  # shared destructive-flag parser (which only knows -y / -n / -h).
  local -a rest=()
  local arg
  for arg in "$@"; do
    case ${arg} in
      --work-caches) CACHES=1 ;;
      *) rest+=("${arg}") ;;
    esac
  done
  parse_destructive_flags ${rest[@]+"${rest[@]}"}

  if [[ ! -d ${RUNNER_HOME} ]]; then
    echo "Nothing to clean (no ${RUNNER_HOME})."
    exit 0
  fi

  report_disk_pressure

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

  confirm_or_abort "Proceed with ${item_count} item(s)? [y/N] "

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

  print_summary "${removed}" "${failed}" ${fail_lines[@]+"${fail_lines[@]}"}
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
