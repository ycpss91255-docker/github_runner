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

# --- #140 _diag is attacker-controlled job output: scrub secrets on archive ---

@test "runner_history_archive scrubs secret content a hostile job planted in _diag (#140)" {
  # The runner dir is bind-mounted READ-WRITE into the job container at /runner,
  # and /runner/_diag is therefore attacker-writable. A hostile job can copy the
  # single-use JIT credential (or any harvested secret) into _diag, which the
  # archive would otherwise persist VERBATIM into the durable, never-torn-down
  # history store. The archive must treat _diag as untrusted and scrub secret
  # patterns from the archived contents.
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag"
  # An attacker-planted file dumping the JIT credential + other secrets.
  cat > "${rdir}/_diag/leak.log" <<'LEAK'
JITCONFIG=ENCODEDxJITxSECRETxPLANTED==
github_token=ghp_supersecretvalue
runner_secret: hunter2value
benign worker diagnostic line
LEAK

  runner_history_archive job-leak "" "${rdir}"

  archived="${RUNNER_HISTORY_DIR}/jobs/job-leak/_diag/leak.log"
  [ -f "${archived}" ]
  # The benign diagnostic line survives (we keep real forensics).
  grep -q 'benign worker diagnostic line' "${archived}"
  # But none of the planted secret VALUES may land in the durable store.
  ! grep -q 'ENCODEDxJITxSECRETxPLANTED==' "${archived}"
  ! grep -q 'ghp_supersecretvalue'         "${archived}"
  ! grep -q 'hunter2value'                 "${archived}"
}

# --- #141 job_log is attacker-controlled console output: scrub on archive ---

@test "runner_history_archive scrubs secret content a hostile job printed to job_log (#141)" {
  # The container's combined stdout/stderr is captured into job_log
  # (provision-job.sh: runner_container_run_bounded ... > job_log 2>&1), so its
  # contents are FULLY attacker-controlled. A hostile job step can dump the JIT
  # credential from its own container env (e.g. `cat /proc/1/environ` / `env`,
  # printing JITCONFIG=<encoded single-use credential>) -- or any harvested
  # secret -- straight to stdout. The archive must treat job_log as untrusted and
  # scrub secret patterns, exactly like the #140 _diag path, so a credential
  # printed to job stdout never reaches the durable, never-torn-down history
  # store (or the external push hook).
  cat > "${STORE}/captured.log" <<'LEAK'
JITCONFIG=ENCODEDxJITxSECRETxPLANTED==
github_token=ghp_supersecretvalue
runner_secret: hunter2value
benign console output line
LEAK

  runner_history_archive job-stdout-leak "${STORE}/captured.log" ""

  archived="${RUNNER_HISTORY_DIR}/jobs/job-stdout-leak/job.log"
  [ -f "${archived}" ]
  # The benign console line survives (we keep real forensics).
  grep -q 'benign console output line' "${archived}"
  # But none of the printed secret VALUES may land in the durable store.
  ! grep -q 'ENCODEDxJITxSECRETxPLANTED==' "${archived}"
  ! grep -q 'ghp_supersecretvalue'         "${archived}"
  ! grep -q 'hunter2value'                 "${archived}"
}

# --- #139 path-reserved job id must not escape the jobs/ subtree ----------

@test "runner_history_safe_id never yields a path-reserved token (#139)" {
  # A directory key (unlike a container name) must never resolve to '.', '..',
  # or empty -- any of those would let the archive escape jobs/<id>/.
  [ "$(runner_history_safe_id '..')" != '..' ]
  [ "$(runner_history_safe_id '.')"  != '.' ]
  [ -n "$(runner_history_safe_id '')" ]
  [ -n "$(runner_history_safe_id '..')" ]
  # A benign id is still preserved verbatim.
  [ "$(runner_history_safe_id 'job-1')" = 'job-1' ]
}

@test "runner_history_archive with job_id '..' stays under jobs/ and never writes the store root (#139)" {
  printf 'attacker output\n' > "${STORE}/captured.log"

  runner_history_archive '..' "${STORE}/captured.log" ""

  # The job.log must NOT land in the store root (the escape this fixes).
  [ ! -f "${RUNNER_HISTORY_DIR}/job.log" ]
  # And it must land somewhere strictly under jobs/.
  found=$(find "${RUNNER_HISTORY_DIR}/jobs" -name job.log -type f)
  [ -n "${found}" ]
  case "${found}/" in
    "${RUNNER_HISTORY_DIR}/jobs/"*) ;;
    *) echo "archive escaped jobs/: ${found}"; return 1 ;;
  esac
}

@test "runner_history_archive with job_id '.' stays under a real per-job dir (#139)" {
  printf 'attacker output\n' > "${STORE}/captured.log"

  runner_history_archive '.' "${STORE}/captured.log" ""

  # '.' must not collapse the dest onto jobs/ itself.
  [ ! -f "${RUNNER_HISTORY_DIR}/jobs/job.log" ]
  found=$(find "${RUNNER_HISTORY_DIR}/jobs" -mindepth 2 -name job.log -type f)
  [ -n "${found}" ]
}

# --- #123 capture hook ----------------------------------------------------

@test "runner_history_capture records, archives, and is best-effort (#123)" {
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag"
  echo "d" > "${rdir}/_diag/x.log"
  echo "out" > "${STORE}/job.log"

  run runner_history_capture job-cap 0 "${STORE}/job.log" "${rdir}" image=img runner_type=gpu
  [ "${status}" -eq 0 ]
  grep -q 'job_id=job-cap' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=0' "${RUNNER_HISTORY_LEDGER}"
  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-cap/job.log" ]
  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-cap/_diag/x.log" ]
}

@test "runner_history_capture records the job's exit status on failure too (#123)" {
  run runner_history_capture job-fail 7 "" "" image=img
  [ "${status}" -eq 0 ]
  grep -q 'job_id=job-fail' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=7' "${RUNNER_HISTORY_LEDGER}"
}

@test "runner_history_capture never propagates a capture failure (#123 best-effort)" {
  # Point the ledger at an unwritable location: the record write fails, but
  # capture must still return 0 so it can never block teardown.
  export RUNNER_HISTORY_DIR=/proc/nonexistent/history
  export RUNNER_HISTORY_LEDGER=/proc/nonexistent/history/ledger.tsv
  run runner_history_capture job-x 0 "" "" image=img
  [ "${status}" -eq 0 ]
}

# --- #128 external-push seam ---------------------------------------------

@test "runner_history_push is a no-op by default (#128)" {
  run runner_history_push job-np
  [ "${status}" -eq 0 ]
}

@test "runner_history_push invokes a config-driven hook with id + archive dir (#128)" {
  export RUNNER_HISTORY_PUSH_HOOK=_test_push
  CAP="${STORE}/push.args"
  _test_push() { printf '%s\n' "$@" > "${CAP}"; }
  runner_history_push job-push
  [ -f "${CAP}" ]
  grep -qxF 'job-push' "${CAP}"
  grep -qxF "${RUNNER_HISTORY_DIR}/jobs/job-push" "${CAP}"
}

@test "runner_history_push swallows a failing hook (#128 best-effort)" {
  export RUNNER_HISTORY_PUSH_HOOK=_boom
  _boom() { return 1; }
  run runner_history_push job-boom
  [ "${status}" -eq 0 ]
}

@test "runner_history_push tolerates an enabled-but-undefined hook (#128)" {
  export RUNNER_HISTORY_PUSH_HOOK=no_such_function
  run runner_history_push job-undef
  [ "${status}" -eq 0 ]
}
