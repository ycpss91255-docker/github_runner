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

# Sanitise a job id to the filesystem-safe [a-zA-Z0-9_.-] set (anything else
# becomes '-'), matching runner_container_name's rule so the history dir and the
# container name correlate by the same key.
runner_history_safe_id() {
  printf '%s' "$1" | tr -c 'a-zA-Z0-9_.-' '-'
}

# The per-job archive dir, keyed by the sanitised job id. Created lazily by the
# archive/capture functions; never removed by teardown (that is the whole point
# -- it outlives the container).
runner_history_job_dir() {
  printf '%s/jobs/%s' "${RUNNER_HISTORY_DIR}" "$(runner_history_safe_id "$1")"
}

# Append one job record to the ledger (#124). Fields are passed as KEY=VALUE
# pairs and written as a single TAB-separated line, so the ledger stays grep-
# and cut-friendly. The record carries job id, scale set / labels, image +
# digest, host, runner type, device(s), start / end, duration, exit status, and
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

# Archive a job's container stdout/stderr and runner _diag logs into its per-job
# history dir, keyed by job id (#125), BEFORE the container/temp dir is removed.
#   runner_history_archive <job_id> <job_log> <runner_dir>
# <job_log>    a file holding the captured container stdout+stderr (may be absent)
# <runner_dir> the per-job runner dir mounted into the container; its _diag/
#              subtree (if any) is copied verbatim.
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
    cp -a -- "${runner_dir}/_diag" "${dest}/_diag" 2>/dev/null \
      || echo "history: failed to archive _diag for ${job_id}" >&2
  fi
  return 0
}
