#!/usr/bin/env bash
# Runner History -- the job-history / audit-trail store (ADR-0002). Ephemeral
# runners (ADR-0001) destroy the container and runner after EVERY job (zero
# residue) -- but forensics needs evidence: which host / runner / image / digest
# / device ran a job, its outcome, and its logs. GitHub keeps the job console
# log (~90 days) but NOT the self-hosted execution context, and ephemeral
# teardown destroys it unless it is captured FIRST.
#
# This seam captures that evidence OUT-OF-BAND, BEFORE teardown, into a durable
# local store under RUNNER_HOME/history/ (the SEC-3 rm-root chokepoint). It is
# sourced by the per-job provisioner (listener/provision-job.sh) for the
# capture-before-teardown hook, and by script/history.sh for query + retention.
#
#   Ledger  (append-only, one line per job; NEVER any secret/JIT config) -- #124
#   Archive (container stdout/stderr + runner _diag, keyed by job id)     -- #125
#   Capture hook (runs after the job exits, before --rm / temp-dir rm)    -- #123
#   Retention (bounded by BOTH size GB + age days, oldest-first)          -- #127
#   External-push seam (pluggable, no-op default, config-driven)          -- #128
# shellcheck shell=bash

# The history store root. Lives under RUNNER_HOME so it ports with the runner
# state (gitignored) and inherits the SEC-3 normalization/refusal that guards
# every rm rooted at RUNNER_HOME. Overridable for tests / alternate stores.
# This lib is sourced both by scripts that already set RUNNER_HOME (via
# common.sh) and directly by listener/provision-job.sh (which does not), so the
# default is taken from RUNNER_HOME only when it is set -- avoiding an unbound-
# variable failure under `set -u` in the direct-source path.
: "${RUNNER_HISTORY_DIR:=${RUNNER_HOME:-}/history}"

# The append-only ledger file: one TAB-separated record per job (#124).
: "${RUNNER_HISTORY_LEDGER:=${RUNNER_HISTORY_DIR}/ledger.tsv}"

# journald mirror toggle (#124): when systemd-cat is on PATH, ledger lines are
# also emitted to journald under this tag. Empty / missing systemd-cat = the
# local file is the only sink (best-effort mirror, never fatal).
: "${RUNNER_HISTORY_JOURNAL_TAG:=github-runner-history}"

# Retention caps (#127): history is bounded by BOTH a size cap (GB) and an age
# cap (days); oldest job archives are evicted first until BOTH hold. Defaults
# per ADR-0002 (20 GB / 30 days); override via the environment / setup.conf.
: "${RUNNER_HISTORY_MAX_GB:=20}"
: "${RUNNER_HISTORY_MAX_DAYS:=30}"

# External-push seam (#128): the name of a shell function invoked once per
# captured job to ship its record/archive to an external store (Loki / ELK /
# object storage). Empty (the default) = local store only, a pure no-op. Set it
# to an operator-provided function name to enable shipping -- config-driven, not
# hardcoded.
: "${RUNNER_HISTORY_PUSH_HOOK:=}"

# Sanitise a job id into a filesystem-safe DIRECTORY key. Unlike a container
# NAME (runner_container_name), a directory key must never be a path-reserved
# token: '.', '..', or empty would let the per-job archive escape jobs/<id>/
# (e.g. job_id='..' resolves jobs/.. back to the store root -- #139). So '.' is
# DROPPED from the allowlist (no dot-only token can form, neutralising any
# future multi-segment dot trick) and any residual empty result is mapped to a
# safe sentinel.
runner_history_safe_id() {
  local safe
  safe=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '-')
  # Belt-and-braces: a bare '.'/'..' can no longer form once '.' is dropped, but
  # an empty input still yields empty -- map it (and any reserved token) to a
  # sentinel so the dir is always a real child of jobs/.
  case "${safe}" in
    ''|.|..) safe=_invalid ;;
  esac
  printf '%s' "${safe}"
}

# The per-job archive dir, keyed by the sanitised job id (#125). Created lazily
# by the archive/capture functions; never removed by teardown (that is the whole
# point -- it outlives the container).
runner_history_job_dir() {
  printf '%s/jobs/%s' "${RUNNER_HISTORY_DIR}" "$(runner_history_safe_id "$1")"
}

# Append one job record to the ledger (#124). Fields are passed as KEY=VALUE
# pairs and written as a single TAB-separated line, so the ledger stays grep-
# and cut-friendly. The record carries job id, scale set / labels, image +
# digest, host, runner type, devices, start / end, duration, exit status, and
# trigger (repo / workflow / commit / actor) -- but NEVER the JIT config or any
# secret. Redaction is enforced here: any field whose KEY matches a secret-ish
# name (jit / token / secret / credential / password) is DROPPED rather than
# written, so a careless caller cannot leak a credential into the audit trail.
#   runner_history_record <job_id> KEY=VALUE [KEY=VALUE ...]
runner_history_record() {
  local job_id=$1; shift
  mkdir -p "${RUNNER_HISTORY_DIR}"
  local ts line kv k v
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # The leading, fixed columns: a write timestamp + the job id, so every line is
  # self-describing even before the KEY=VALUE pairs.
  line=$(printf 'ts=%s\tjob_id=%s' "${ts}" "${job_id}")
  for kv in "$@"; do
    k=${kv%%=*}
    v=${kv#*=}
    # SECRET REDACTION (ADR-0002): never persist the JIT config or any secret,
    # whatever the caller passed. Drop the whole field, fail closed.
    case "${k,,}" in
      *jit*|*token*|*secret*|*credential*|*password*|*passwd*)
        continue ;;
    esac
    # TABs/newlines in a value would corrupt the TSV record; flatten them.
    v=${v//$'\t'/ }
    v=${v//$'\n'/ }
    line+=$(printf '\t%s=%s' "${k}" "${v}")
  done
  printf '%s\n' "${line}" >> "${RUNNER_HISTORY_LEDGER}"
  runner_history_journal "${line}"
}

# Mirror one ledger line to journald (#124), best-effort. Uses systemd-cat when
# present; otherwise a silent no-op (the local ledger remains the source of
# truth). Never fatal -- a missing journal must not block capture/teardown.
runner_history_journal() {
  command -v systemd-cat >/dev/null 2>&1 || return 0
  printf '%s\n' "$1" | systemd-cat -t "${RUNNER_HISTORY_JOURNAL_TAG}" 2>/dev/null || true
}

# Secret-pattern scrubber for archived file CONTENTS (#140). The _diag subtree
# is copied from the per-job runner dir, which is bind-mounted READ-WRITE into
# the job container at /runner -- so _diag is ATTACKER-WRITABLE job output, NOT
# trusted runner diagnostics. A hostile job can copy the single-use JIT
# credential (or any harvested secret) into /runner/_diag and have it land
# verbatim in the durable, never-torn-down history store. The ledger redaction
# (#124) is KEY-name matching on TSV fields and never inspects file contents, so
# it does not stop this. This filter redacts any line that looks like it carries
# a secret value (JITCONFIG / token / secret / credential / password / api[-_]key
# in KEY=VALUE or KEY: VALUE form), replacing the value with a fixed marker so
# the forensic line is retained but the secret is not. Benign diagnostic lines
# pass through untouched. Reads stdin, writes scrubbed stdout.
runner_history_scrub_secrets() {
  # ERE, case-insensitive: a secret-ish key token immediately followed by a
  # '=' or ':' delimiter, then the (greedy) value to end-of-line -> redacted.
  sed -E 's/((jitconfig|token|secret|credential|password|passwd|api[_-]?key)[^=:[:space:]]*[[:space:]]*[=:])[[:space:]]*.*$/\1 [REDACTED]/I'
}

# Archive a job's container stdout/stderr and runner _diag logs into its per-job
# history dir, keyed by job id (#125), BEFORE the container/temp dir is removed.
#   runner_history_archive <job_id> <job_log> <runner_dir>
# <job_log>    a file holding the captured container stdout+stderr (may be absent)
# <runner_dir> the per-job runner dir mounted into the container; its _diag/
#              subtree (if any) is archived -- but as UNTRUSTED job output: it is
#              copied through a secret scrubber (#140), never `cp -a` verbatim,
#              so secrets a hostile job planted there never reach the durable
#              store. Symlinks are NOT followed (the source is job-controlled).
# Best-effort: a missing source is skipped, an individual copy failure is logged
# and swallowed, so archiving never blocks teardown.
runner_history_archive() {
  local job_id=$1 job_log=${2:-} runner_dir=${3:-} dest
  dest=$(runner_history_job_dir "${job_id}")
  mkdir -p "${dest}" || { echo "history: cannot create ${dest}" >&2; return 0; }
  if [[ -n "${job_log}" && -f "${job_log}" ]]; then
    cp -f -- "${job_log}" "${dest}/job.log" 2>/dev/null \
      || echo "history: failed to archive job log for ${job_id}" >&2
  fi
  if [[ -n "${runner_dir}" && -d "${runner_dir}/_diag" ]]; then
    runner_history_archive_diag "${runner_dir}/_diag" "${dest}/_diag" \
      || echo "history: failed to archive _diag for ${job_id}" >&2
  fi
  return 0
}

# Copy the (attacker-writable) _diag subtree into the durable store, scrubbing
# secret content from every regular file as it lands (#140). The tree is walked
# with `find` so the directory structure is recreated, each REGULAR file is
# piped through the secret scrubber, and symlinks/special files are skipped (a
# job-controlled symlink must never make us read or copy outside the tree).
#   runner_history_archive_diag <src_diag> <dest_diag>
runner_history_archive_diag() {
  local src=$1 dest=$2 rel out
  mkdir -p "${dest}" || return 1
  # -P: never follow symlinks; we only ever descend real directories and only
  # ever scrub real files, so a planted symlink cannot redirect the copy.
  while IFS= read -r -d '' path; do
    rel=${path#"${src}"/}
    if [[ -d "${path}" ]]; then
      mkdir -p "${dest}/${rel}" || return 1
    elif [[ -f "${path}" ]]; then
      out="${dest}/${rel}"
      mkdir -p "$(dirname -- "${out}")" || return 1
      # Scrub on the way in; failure of an individual file is non-fatal.
      runner_history_scrub_secrets <"${path}" >"${out}" 2>/dev/null || true
    fi
    # Anything else (symlink, socket, device) is intentionally not archived.
  done < <(find -P "${src}" -mindepth 1 \( -type d -o -type f \) -print0 2>/dev/null)
  return 0
}

# The external-push seam (#128): invoke the configured push hook (if any) for a
# captured job, handing it the job id and its archive dir. The DEFAULT is a pure
# NO-OP (RUNNER_HISTORY_PUSH_HOOK empty) -- local store only. Enabling it is
# config-driven: set RUNNER_HISTORY_PUSH_HOOK to the name of a function that
# ships the record/archive elsewhere. Best-effort: a hook failure is logged and
# swallowed so a flaky external store never blocks capture/teardown.
#   runner_history_push <job_id>
runner_history_push() {
  local job_id=$1 dest
  [[ -n "${RUNNER_HISTORY_PUSH_HOOK}" ]] || return 0
  if ! declare -F "${RUNNER_HISTORY_PUSH_HOOK}" >/dev/null 2>&1; then
    echo "history: push hook '${RUNNER_HISTORY_PUSH_HOOK}' is not a defined function; skipping" >&2
    return 0
  fi
  dest=$(runner_history_job_dir "${job_id}")
  "${RUNNER_HISTORY_PUSH_HOOK}" "${job_id}" "${dest}" \
    || echo "history: push hook failed for ${job_id} (local copy retained)" >&2
  return 0
}

# --- Retention (#127) -----------------------------------------------------
# History is bounded by BOTH a size cap (GB) and an age cap (days); the prune
# evicts whole per-job archives OLDEST-FIRST until both caps hold, so the store
# can never fill the disk (a new "residue" failure mode ADR-0002 must avoid).
# This logic lives here so it is reusable by both script/history.sh (operator)
# and the scheduled cleanup harness (script/cleanup.sh, #127).

# Emit every per-job archive dir as "<mtime-epoch>\t<path>", sorted OLDEST FIRST
# -- the eviction order. Empty (no jobs/ dir) prints nothing.
runner_history_archives_by_age() {
  local jobs_dir="${RUNNER_HISTORY_DIR}/jobs"
  [[ -d "${jobs_dir}" ]] || return 0
  local d
  for d in "${jobs_dir}"/*/; do
    [[ -d "${d}" ]] || continue
    printf '%s\t%s\n' "$(stat -c '%Y' "${d}")" "${d%/}"
  done | sort -n
}

# Total bytes used by all per-job archives (the size the GB cap bounds).
runner_history_total_bytes() {
  local jobs_dir="${RUNNER_HISTORY_DIR}/jobs"
  [[ -d "${jobs_dir}" ]] || { printf '0'; return 0; }
  du -sb "${jobs_dir}" 2>/dev/null | awk '{print $1; found=1} END{if(!found) print 0}'
}

# Plan the retention eviction (#127): print the per-job archive dirs that should
# be removed, oldest-first, to satisfy BOTH caps -- WITHOUT removing anything (so
# a dry-run / the operator can preview). Args (default to the configured caps):
#   runner_history_prune_plan [max_gb] [max_days]
# A dir is evicted if it is older than max_days OR if it still sits above the
# size budget after older dirs are accounted for. max_gb=0 means "evict to
# (nearly) empty"; max_days<=0 disables the age cap.
runner_history_prune_plan() {
  local max_gb=${1:-${RUNNER_HISTORY_MAX_GB}} max_days=${2:-${RUNNER_HISTORY_MAX_DAYS}}
  local budget now cutoff
  # Size budget in bytes (GB * 1024^3). Integer math; 0 -> 0 budget.
  budget=$(( max_gb * 1024 * 1024 * 1024 ))
  now=$(date +%s)
  cutoff=$(( now - max_days * 86400 ))

  local total mtime path
  total=$(runner_history_total_bytes)

  # Walk oldest-first: evict on age, OR while still over the size budget. Each
  # eviction reduces the running total so we stop once under budget.
  while IFS=$'\t' read -r mtime path; do
    [[ -n "${path}" ]] || continue
    local evict=0
    if (( max_days > 0 )) && (( mtime < cutoff )); then
      evict=1
    elif (( total > budget )); then
      evict=1
    fi
    if (( evict )); then
      printf '%s\n' "${path}"
      local sz
      sz=$(du -sb "${path}" 2>/dev/null | awk '{print $1}')
      total=$(( total - ${sz:-0} ))
    fi
  done < <(runner_history_archives_by_age)
}

# Enforce retention (#127): remove the planned per-job archives oldest-first.
# Every rm is anchored under RUNNER_HISTORY_DIR (which is itself under
# RUNNER_HOME, the SEC-3 chokepoint) -- a defensive guard so a bug can never turn
# this into an out-of-tree delete. Prints one line per eviction. Returns 0.
#   runner_history_prune [max_gb] [max_days]
runner_history_prune() {
  local path
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    case "${path}/" in
      "${RUNNER_HISTORY_DIR}/jobs/"*) ;;
      *) echo "history: refusing to prune outside the store: ${path}" >&2; continue ;;
    esac
    rm -rf -- "${path}" && echo "pruned ${path}"
  done < <(runner_history_prune_plan "$@")
  return 0
}

# The capture-before-teardown HOOK (#123): the single lifecycle step the
# provisioner calls AFTER a job exits but BEFORE the container/temp dir is
# removed, on EVERY job (success and failure). It writes the ledger record (#124,
# secrets redacted), archives the logs (#125), and runs the external-push seam
# (#128) -- in that order. The whole thing is BEST-EFFORT: it is wrapped so a
# capture failure is logged and never propagates, so it can NEVER block teardown
# (a failed capture must not strand a container or leave a temp dir).
#   runner_history_capture <job_id> <exit_status> <job_log> <runner_dir> \
#                          [KEY=VALUE ...]
# The trailing KEY=VALUE pairs are extra ledger fields (image, digest, host,
# runner type, devices, trigger, ...). exit_status is recorded as a field too.
runner_history_capture() {
  local job_id=$1 exit_status=$2 job_log=$3 runner_dir=$4
  shift 4
  {
    runner_history_record "${job_id}" "exit_status=${exit_status}" "$@"
    runner_history_archive "${job_id}" "${job_log}" "${runner_dir}"
    runner_history_push "${job_id}"
  } || echo "history: capture failed for ${job_id} (teardown continues)" >&2
  return 0
}
