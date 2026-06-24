#!/usr/bin/env bats
# Smoke tests for script/history.sh -- the job-history query tool (ADR-0002,
# #126). It reads the append-only ledger under RUNNER_HISTORY_DIR and lets an
# operator look up jobs by id / time / repo / outcome (human-readable + --json).
# Tests point RUNNER_HISTORY_DIR at a throwaway store (never the real
# RUNNER_HOME) and seed ledger lines directly, asserting on the script's output.

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

@test "history.sh -h prints usage and exits 0" {
  run "${SCRIPT}" -h
  [ "${status}" -eq 0 ]
  [[ "${output}" == *Usage* ]]
}
