#!/usr/bin/env bats
# Smoke tests for lib/runner-history.sh -- the job-history / audit-trail store
# (ADR-0002, hardened by #154). The durable store keeps ONLY trusted ledger
# metadata (job id, image, digest, host, runner type, devices, outcome,
# trigger) -- it NEVER ingests attacker-controlled raw job output (the
# container's stdout/stderr, or the job-writable _diag subtree). That is the
# root-cause end of the #140-#153 scrub cascade: an attacker-controlled stream
# cannot be safely scrubbed, so it is simply not durably persisted (its
# authoritative copy already lives in GitHub's job console log).
#
# Each test sources the lib with RUNNER_HISTORY_DIR pointed at a throwaway dir
# (never the real RUNNER_HOME) and asserts on the files it writes. journald is
# absent in CI, so its mirror is a silent no-op here.

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
  # The benign field survives; every secret-ish field (and its value) is gone --
  # from BOTH the ledger and the per-job record mirror (#154).
  grep -q 'image=img' "${RUNNER_HISTORY_LEDGER}"
  ! grep -rqi 'ENCODEDxJITxSECRET' "${RUNNER_HISTORY_DIR}"
  ! grep -rqi 'ghp_supersecret'    "${RUNNER_HISTORY_DIR}"
  ! grep -rqi 'hunter2'            "${RUNNER_HISTORY_DIR}"
  ! grep -rqi 'topsecret'          "${RUNNER_HISTORY_DIR}"
  ! grep -rqi 'letmein'            "${RUNNER_HISTORY_DIR}"
  ! grep -rqi 'jit'                "${RUNNER_HISTORY_DIR}"
  ! grep -rqi 'token'              "${RUNNER_HISTORY_DIR}"
}

# --- #154 durable store keeps ONLY trusted metadata, never raw job output ----

@test "runner_history_record mirrors a trusted, redacted record into the per-job dir (#154)" {
  # The per-job dir is the only per-job artifact the durable store keeps, and it
  # holds ONLY the trusted, redacted ledger line -- the metadata the push seam
  # (#128) ships and retention (#127) prunes. NEVER any raw job output.
  runner_history_record job-meta image=img:1 exit_status=0 trigger_repo=o/r
  local rec="${RUNNER_HISTORY_DIR}/jobs/job-meta/record.tsv"
  [ -f "${rec}" ]
  grep -q 'job_id=job-meta' "${rec}"
  grep -q 'image=img:1' "${rec}"
  grep -q 'trigger_repo=o/r' "${rec}"
}

@test "the scrub-then-trust machinery is gone -- no content/name scrubbers, no raw archiver (#154)" {
  # The whole #140-#153 cascade lived in functions whose job was to scrub
  # attacker-controlled streams before durably persisting them. The root-cause
  # fix DELETES them: the untrusted stream is simply never durably kept, so
  # there is nothing left to scrub. Their continued existence would mean the
  # fragile "scrub then trust" design is still present.
  ! declare -F runner_history_scrub_secrets
  ! declare -F runner_history_scrub_name
  ! declare -F runner_history_archive_diag
  ! declare -F runner_history_archive
}

@test "runner_history_capture persists ONLY the trusted record, never raw job output or _diag (#154)" {
  # Even handed a (hypothetical) runner dir full of attacker-planted _diag
  # secrets, capture must not copy ANY of it into the durable store: the new
  # signature does not take a job log or a runner dir at all, so there is no
  # path by which job-controlled bytes reach the store.
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag"
  echo "JITCONFIG=ENCODEDxJITxPLANTED==" > "${rdir}/_diag/leak.log"

  run runner_history_capture job-cap 0 image=img runner_type=gpu
  [ "${status}" -eq 0 ]

  # The trusted record landed.
  grep -q 'job_id=job-cap' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=0' "${RUNNER_HISTORY_LEDGER}"
  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-cap/record.tsv" ]

  # No raw job artifact exists anywhere under the store, and the planted secret
  # never reached it.
  [ -z "$(find "${RUNNER_HISTORY_DIR}" -name job.log)" ]
  [ -z "$(find "${RUNNER_HISTORY_DIR}" -type d -name _diag)" ]
  ! grep -rq 'ENCODEDxJITxPLANTED==' "${RUNNER_HISTORY_DIR}"
}

# --- #123 capture hook ----------------------------------------------------

@test "runner_history_capture records and is best-effort (#123)" {
  run runner_history_capture job-cap2 0 image=img runner_type=gpu
  [ "${status}" -eq 0 ]
  grep -q 'job_id=job-cap2' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=0' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'runner_type=gpu' "${RUNNER_HISTORY_LEDGER}"
}

@test "runner_history_capture records the job's exit status on failure too (#123)" {
  run runner_history_capture job-fail 7 image=img
  [ "${status}" -eq 0 ]
  grep -q 'job_id=job-fail' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=7' "${RUNNER_HISTORY_LEDGER}"
}

@test "runner_history_capture never propagates a capture failure (#123 best-effort)" {
  # Point the ledger at an unwritable location: the record write fails, but
  # capture must still return 0 so it can never block teardown.
  export RUNNER_HISTORY_DIR=/proc/nonexistent/history
  export RUNNER_HISTORY_LEDGER=/proc/nonexistent/history/ledger.tsv
  run runner_history_capture job-x 0 image=img
  [ "${status}" -eq 0 ]
}

# --- #139 path-reserved job id must not escape the jobs/ subtree ----------

@test "runner_history_safe_id never yields a path-reserved token (#139)" {
  # A directory key (unlike a container name) must never resolve to '.', '..',
  # or empty -- any of those would let the per-job dir escape jobs/<id>/.
  [ "$(runner_history_safe_id '..')" != '..' ]
  [ "$(runner_history_safe_id '.')"  != '.' ]
  [ -n "$(runner_history_safe_id '')" ]
  [ -n "$(runner_history_safe_id '..')" ]
  # A benign id is still preserved verbatim.
  [ "$(runner_history_safe_id 'job-1')" = 'job-1' ]
}

@test "runner_history_record with a path-reserved job id stays under jobs/ (#139)" {
  runner_history_record '..' image=img exit_status=0
  # The per-job record must NOT land in the store root (the escape this fixes);
  # it lands strictly under jobs/ via the sanitised key.
  [ ! -f "${RUNNER_HISTORY_DIR}/record.tsv" ]
  found=$(find "${RUNNER_HISTORY_DIR}/jobs" -name record.tsv -type f)
  [ -n "${found}" ]
  case "${found}/" in
    "${RUNNER_HISTORY_DIR}/jobs/"*) ;;
    *) echo "record escaped jobs/: ${found}"; return 1 ;;
  esac
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
