#!/usr/bin/env bats
# Smoke tests for script/history.sh -- the job-history query + retention tool
# (ADR-0002, #126/#127). It reads the append-only ledger and per-job archives
# under RUNNER_HISTORY_DIR and lets an operator look up jobs by id / time / repo
# / outcome (human-readable + --json), and prune the store by BOTH a size cap
# (GB) and an age cap (days), oldest-first. Tests point RUNNER_HISTORY_DIR at a
# throwaway store (never the real RUNNER_HOME) and seed ledger lines / archives
# directly, asserting on the script's output and on what it evicts.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  SCRIPT="${ROOT}/script/history.sh"
  STORE=$(mktemp -d)
  # history.sh sources common.sh, which fixes RUNNER_HOME; point it at the
  # throwaway store so nothing touches a real install.
  export RUNNER_HOME="${STORE}/home"
  export RUNNER_HISTORY_DIR="${RUNNER_HOME}/history"
  export RUNNER_HISTORY_LEDGER="${RUNNER_HISTORY_DIR}/ledger.tsv"
  mkdir -p "${RUNNER_HISTORY_DIR}/jobs"

  # Seed three ledger records (TAB-separated KEY=VALUE, matching the writer).
  seed() { printf '%s\n' "$*" >> "${RUNNER_HISTORY_LEDGER}"; }
  seed "ts=2026-06-01T10:00:00Z	job_id=job-aaa	exit_status=0	image=img:1	runner_type=gpu	trigger_repo=octo/alpha"
  seed "ts=2026-06-02T11:00:00Z	job_id=job-bbb	exit_status=7	image=img:2	runner_type=cpu	trigger_repo=octo/beta"
  seed "ts=2026-06-03T12:00:00Z	job_id=job-ccc	exit_status=0	image=img:3	runner_type=gpu	trigger_repo=octo/alpha"
}

teardown() { rm -rf "${STORE}"; }

@test "history.sh exists and is executable" {
  [ -x "${SCRIPT}" ]
}

@test "history.sh with no filter lists every job (human-readable) (#126)" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *job-aaa* ]]
  [[ "${output}" == *job-bbb* ]]
  [[ "${output}" == *job-ccc* ]]
}

@test "history.sh --id looks up a single job (#126)" {
  run "${SCRIPT}" --id job-bbb
  [ "${status}" -eq 0 ]
  [[ "${output}" == *job-bbb* ]]
  [[ "${output}" != *job-aaa* ]]
  [[ "${output}" != *job-ccc* ]]
}

@test "history.sh --repo filters by trigger repo (#126)" {
  run "${SCRIPT}" --repo octo/alpha
  [ "${status}" -eq 0 ]
  [[ "${output}" == *job-aaa* ]]
  [[ "${output}" == *job-ccc* ]]
  [[ "${output}" != *job-bbb* ]]
}

@test "history.sh --outcome failure filters by non-zero exit (#126)" {
  run "${SCRIPT}" --outcome failure
  [ "${status}" -eq 0 ]
  [[ "${output}" == *job-bbb* ]]
  [[ "${output}" != *job-aaa* ]]
}

@test "history.sh --outcome success filters by zero exit (#126)" {
  run "${SCRIPT}" --outcome success
  [ "${status}" -eq 0 ]
  [[ "${output}" == *job-aaa* ]]
  [[ "${output}" == *job-ccc* ]]
  [[ "${output}" != *job-bbb* ]]
}

@test "history.sh --since filters by time (#126)" {
  run "${SCRIPT}" --since 2026-06-02T00:00:00Z
  [ "${status}" -eq 0 ]
  [[ "${output}" != *job-aaa* ]]
  [[ "${output}" == *job-bbb* ]]
  [[ "${output}" == *job-ccc* ]]
}

@test "history.sh --until filters by time (#126)" {
  run "${SCRIPT}" --until 2026-06-02T00:00:00Z
  [ "${status}" -eq 0 ]
  [[ "${output}" == *job-aaa* ]]
  [[ "${output}" != *job-bbb* ]]
}

@test "history.sh --json emits scriptable JSON objects (#126)" {
  run "${SCRIPT}" --id job-aaa --json
  [ "${status}" -eq 0 ]
  # One JSON object per matched record, with the ledger fields as keys.
  [[ "${output}" == *'"job_id"'* ]]
  [[ "${output}" == *'"job-aaa"'* ]]
  [[ "${output}" == *'"trigger_repo"'* ]]
  # Valid JSON: pipe through a parser if available.
  if command -v jq >/dev/null 2>&1; then
    echo "${output}" | jq -e '.job_id == "job-aaa"' >/dev/null
  fi
}

@test "history.sh --id for an unknown job is empty + exit 0 (#126)" {
  run "${SCRIPT}" --id no-such-job
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

# --- retention (#127) -----------------------------------------------------

@test "history.sh prune --max-days evicts archives older than the age cap, oldest-first (#127)" {
  # Three per-job archive dirs with controlled mtimes (old -> new).
  for j in job-aaa job-bbb job-ccc; do mkdir -p "${RUNNER_HISTORY_DIR}/jobs/${j}"; done
  touch -d '2026-01-01' "${RUNNER_HISTORY_DIR}/jobs/job-aaa"
  touch -d '2026-06-01' "${RUNNER_HISTORY_DIR}/jobs/job-bbb"
  touch -d "$(date +%Y-%m-%d)" "${RUNNER_HISTORY_DIR}/jobs/job-ccc"

  RUNNER_HISTORY_MAX_DAYS=30 RUNNER_HISTORY_MAX_GB=1000 \
    run "${SCRIPT}" prune --yes
  [ "${status}" -eq 0 ]
  # The very old archive is gone; the recent ones survive.
  [ ! -d "${RUNNER_HISTORY_DIR}/jobs/job-aaa" ]
  [ -d "${RUNNER_HISTORY_DIR}/jobs/job-ccc" ]
}

@test "history.sh prune --max-gb evicts oldest archives until under the size cap (#127)" {
  # Two ~1 MB archives; a sub-MB cap (in GB) must evict the older one first.
  for j in job-old job-new; do mkdir -p "${RUNNER_HISTORY_DIR}/jobs/${j}"; done
  dd if=/dev/zero of="${RUNNER_HISTORY_DIR}/jobs/job-old/blob" bs=1M count=1 status=none
  dd if=/dev/zero of="${RUNNER_HISTORY_DIR}/jobs/job-new/blob" bs=1M count=1 status=none
  touch -d '2026-01-01' "${RUNNER_HISTORY_DIR}/jobs/job-old"
  touch -d "$(date +%Y-%m-%d)" "${RUNNER_HISTORY_DIR}/jobs/job-new"

  # Cap of 0 GB rounds to a tiny byte budget -- everything over it is evicted
  # oldest-first; with both over budget, both go, but the OLDEST goes first.
  RUNNER_HISTORY_MAX_GB=0 RUNNER_HISTORY_MAX_DAYS=99999 \
    run "${SCRIPT}" prune --yes --max-gb 0
  [ "${status}" -eq 0 ]
  [ ! -d "${RUNNER_HISTORY_DIR}/jobs/job-old" ]
}

@test "history.sh prune is a dry-run safe no-op without --yes (#127)" {
  mkdir -p "${RUNNER_HISTORY_DIR}/jobs/job-aaa"
  touch -d '2020-01-01' "${RUNNER_HISTORY_DIR}/jobs/job-aaa"
  RUNNER_HISTORY_MAX_DAYS=1 run "${SCRIPT}" prune --dry-run
  [ "${status}" -eq 0 ]
  # Dry-run must not remove anything.
  [ -d "${RUNNER_HISTORY_DIR}/jobs/job-aaa" ]
}

@test "history.sh -h prints usage and exits 0" {
  run "${SCRIPT}" -h
  [ "${status}" -eq 0 ]
  [[ "${output}" == *Usage* ]]
}
