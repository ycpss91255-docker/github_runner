#!/usr/bin/env bats
# Smoke tests for lib/runner-history.sh -- the job-history / audit-trail store
# (ADR-0002): the append-only ledger with secret redaction + journald mirror
# (#124). Each test sources the lib with RUNNER_HISTORY_DIR pointed at a
# throwaway dir (never the real RUNNER_HOME) and asserts on the files it writes.
# journald is absent in CI, so its mirror is a silent no-op here (asserted not to
# break the ledger write).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  STORE=$(mktemp -d)
  export RUNNER_HISTORY_DIR="${STORE}/history"
  export RUNNER_HISTORY_LEDGER="${RUNNER_HISTORY_DIR}/ledger.tsv"
  # shellcheck source=../../lib/runner-history.sh
  source "${ROOT}/lib/runner-history.sh"
}

teardown() { rm -rf "${STORE}"; }

# --- #124 ledger ----------------------------------------------------------

@test "runner_history_record appends one TAB-separated line per job" {
  runner_history_record job-1 image=img:1 exit_status=0
  runner_history_record job-2 image=img:2 exit_status=7
  [ "$(grep -c '^' "${RUNNER_HISTORY_LEDGER}")" -eq 2 ]
  grep -q $'\tjob_id=job-1\t' "${RUNNER_HISTORY_LEDGER}"
  grep -q $'\tjob_id=job-2\t' "${RUNNER_HISTORY_LEDGER}"
  # The fields the caller passed are present.
  grep -q 'image=img:1' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=7' "${RUNNER_HISTORY_LEDGER}"
}

@test "runner_history_record records the full ADR-0002 field set" {
  runner_history_record job-x \
    scale_set=gpu labels=gpu,linux image=img digest=sha256:abc host=h1 \
    runner_type=gpu devices=/dev/nvidia0 start=t0 end=t1 duration=42 \
    exit_status=0 trigger_repo=o/r trigger_workflow=ci trigger_commit=deadbeef \
    trigger_actor=octocat
  local line; line=$(cat "${RUNNER_HISTORY_LEDGER}")
  for f in scale_set=gpu image=img digest=sha256:abc host=h1 runner_type=gpu \
           devices=/dev/nvidia0 duration=42 trigger_repo=o/r \
           trigger_workflow=ci trigger_commit=deadbeef trigger_actor=octocat; do
    [[ "${line}" == *"${f}"* ]] || { echo "missing field ${f} in: ${line}"; return 1; }
  done
}

@test "runner_history_record NEVER writes the JIT config or any secret (#124 redaction)" {
  runner_history_record job-sec \
    image=img \
    jit_config=ENCODEDxJITxSECRET \
    jitconfig=ENCODEDxJITxSECRET \
    github_token=ghp_supersecret \
    runner_secret=hunter2 \
    db_credential=topsecret \
    user_password=letmein \
    exit_status=0
  # The benign field survives; every secret-ish field (and its value) is gone.
  grep -q 'image=img' "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'ENCODEDxJITxSECRET' "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'ghp_supersecret'    "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'hunter2'            "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'topsecret'          "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'letmein'            "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'jit'                "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'token'              "${RUNNER_HISTORY_LEDGER}"
}

# --- #125 archive ---------------------------------------------------------

@test "runner_history_archive stores the job log + _diag keyed by job id (#125)" {
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag"
  echo "diag line" > "${rdir}/_diag/Worker_1.log"
  printf 'job output here\n' > "${STORE}/captured.log"

  runner_history_archive job-arc "${STORE}/captured.log" "${rdir}"

  jdir="${RUNNER_HISTORY_DIR}/jobs/job-arc"
  [ -f "${jdir}/job.log" ]
  grep -q 'job output here' "${jdir}/job.log"
  [ -f "${jdir}/_diag/Worker_1.log" ]
  grep -q 'diag line' "${jdir}/_diag/Worker_1.log"
}

@test "runner_history_archive is best-effort when sources are missing (#125)" {
  # No job log, no _diag: it must still create the per-job dir and return 0.
  run runner_history_archive job-empty "" "${STORE}/nope"
  [ "${status}" -eq 0 ]
  [ -d "${RUNNER_HISTORY_DIR}/jobs/job-empty" ]
}
