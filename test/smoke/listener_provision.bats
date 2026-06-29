#!/usr/bin/env bats
# Smoke tests for listener/provision-job.sh -- the scale-set listener's per-job
# container entrypoint (ADR-0001 Phase 4). The Go scale-set listener
# (cmd/scaleset-listener) shells out to this script for every ASSIGNED job; the
# script is the thin bridge from the Go loop to the Phase 3 container seam
# (lib/runner-container.sh's runner_container_run). These tests stub the
# container CLI (docker) on a clean PATH and capture its argv, asserting the
# script runs ONE single-use container (--rm) with the JIT config passed
# through -- NO real image pulled, NO real container run. Mirrors the
# runner_container.bats PATH-stub + argv-capture style; the listener's Go
# provisioning loop is unit-tested separately under listener/ (go test).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  SCRIPT="${ROOT}/listener/provision-job.sh"

  WORK=$(mktemp -d)
  # Provisioned per-job runner dirs land here, not in the real RUNNER_HOME.
  export RUNNER_WORK_ROOT="${WORK}/work"
  mkdir -p "${RUNNER_WORK_ROOT}"

  # The job-history store (ADR-0002) lands in a throwaway dir, never the real
  # RUNNER_HOME, so the capture-before-teardown hook (#123) is exercised here.
  export RUNNER_HISTORY_DIR="${WORK}/history"
  export RUNNER_HISTORY_LEDGER="${RUNNER_HISTORY_DIR}/ledger.tsv"

  # The JIT config crosses the boundary as a FILE, never on argv (#133). The Go
  # listener writes it; here a helper drops the encoded value in a 0600 file and
  # echoes its path, so each test passes a PATH where the old contract passed the
  # encoded value directly.
  jit_file() {
    local f
    f=$(mktemp "${WORK}/jit.XXXXXX")
    chmod 600 "${f}"
    printf '%s' "$1" > "${f}"
    printf '%s' "${f}"
  }

  STUB=$(mktemp -d)
  CAP="${WORK}/cli.args"
  # A docker stub records the cli name + full argv (one token per line so --rm /
  # the image / the passed-through run command can be grepped exactly), then
  # exits CLI_RC (default 0) so teardown / failure propagation can be asserted.
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
echo "name=docker" >> "${CAP}"
printf '%s\n' "\$@" >> "${CAP}"
# Emit a recognisable line on stdout so the captured job log (#125) is non-empty.
echo "JOB-CONTAINER-OUTPUT"
exit \${CLI_RC:-0}
EOF
  chmod +x "${STUB}/docker"
  # Clean PATH: only our stub plus system bins, so the seam's container-CLI
  # detection sees exactly the stub (no host docker/podman leaking in).
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${WORK}" "${STUB}"; }

@test "provision-job.sh exists and is executable" {
  [ -x "${SCRIPT}" ]
}

@test "provision-job.sh reads the JIT config from a FILE and never puts it on argv (#133/#136)" {
  # The encoded config arrives as a file PATH; the script reads the file and
  # hands the value to the container seam -- but the encoded value must NOT
  # appear anywhere on the HOST container CLI argv (the process table). The
  # credential reaches the container off-argv via --env-file (#136).
  jf=$(jit_file 'ENCODEDxJITxCONFIGx==')
  run "${SCRIPT}" job-abc "${jf}" ghcr.io/acme/runner:latest
  [ "${status}" -eq 0 ]
  grep -qxF -- '--rm' "${CAP}"
  # run.sh still receives --jitconfig inside the container (the flag is carried
  # in the in-container `sh -c` invocation, not as a host argv token).
  grep -qF -- '--jitconfig' "${CAP}"
  grep -qxF -- 'ghcr.io/acme/runner:latest' "${CAP}"
  # The single-use credential must NOT be on the host podman/docker argv (#136).
  ! grep -qF -- 'ENCODEDxJITxCONFIGx==' "${CAP}"
  grep -qxF -- '--env-file' "${CAP}"
}

@test "provision-job.sh rejects a JIT config passed inline (no encoded value on argv, #133)" {
  # An encoded-looking value that is NOT a readable file path must be rejected,
  # proving the script no longer accepts the JIT config directly on argv.
  run "${SCRIPT}" job-abc ENCODEDxJITxCONFIGx== img
  [ "${status}" -ne 0 ]
  [ ! -f "${CAP}" ]
}

@test "provision-job.sh issues a container 'run' (it provisions, not exec)" {
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-abc "${jf}" img
  [ "${status}" -eq 0 ]
  grep -qxF -- 'run' "${CAP}"
}

@test "provision-job.sh names + labels the container by job id (#104)" {
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-abc "${jf}" img
  [ "${status}" -eq 0 ]
  grep -qxF -- '--name' "${CAP}"
  grep -qxF -- 'gha-jit-job-abc' "${CAP}"
  grep -qxF -- '--label' "${CAP}"
  grep -qxF -- 'managed-by=github-runner-listener' "${CAP}"
  grep -qxF -- 'job-id=job-abc' "${CAP}"
}

@test "provision-job.sh passes the listener's RUNNER_DEVICES through as --device (#117)" {
  # The widened shell-out contract: the listener sets RUNNER_DEVICES in the
  # provisioner's environment; the entrypoint must carry it into the container
  # seam so each declared node lands as a precise --device (no --privileged).
  jf=$(jit_file ENC)
  RUNNER_DEVICES=$'/dev/nvidia0\n/dev/nvidiactl' run "${SCRIPT}" job-gpu "${jf}" img
  [ "${status}" -eq 0 ]
  grep -qxF -- '--device' "${CAP}"
  grep -qxF -- '/dev/nvidia0' "${CAP}"
  grep -qxF -- '/dev/nvidiactl' "${CAP}"
  [ "$(grep -cxF -- '--device' "${CAP}")" -eq 2 ]
  ! grep -qxF -- '--privileged' "${CAP}"
}

@test "provision-job.sh passes NO --device when the type declares none (#117)" {
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-cpu "${jf}" img
  [ "${status}" -eq 0 ]
  ! grep -qxF -- '--device' "${CAP}"
}

@test "provision-job.sh propagates the container's exit status (the job's result)" {
  export CLI_RC=7
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-abc "${jf}" img
  [ "${status}" -eq 7 ]
}

@test "provision-job.sh rejects an empty JIT config file" {
  jf=$(jit_file "")
  run "${SCRIPT}" job-abc "${jf}" img
  [ "${status}" -ne 0 ]
  # Never reached the container CLI for an empty config.
  [ ! -f "${CAP}" ]
}

@test "provision-job.sh rejects a missing JIT config file" {
  run "${SCRIPT}" job-abc "${WORK}/does-not-exist" img
  [ "${status}" -ne 0 ]
  [ ! -f "${CAP}" ]
}

@test "provision-job.sh requires exactly three args" {
  run "${SCRIPT}" only-one
  [ "${status}" -ne 0 ]
}

# --- per-job work root defaults under RUNNER_HOME (SEC-3 chokepoint, #130) ---

@test "provision-job.sh defaults the per-job work root under RUNNER_HOME, not /tmp (#130)" {
  # With RUNNER_WORK_ROOT unset, the per-job runner dir must be created under
  # RUNNER_HOME/work (the SEC-3 rm-root chokepoint) rather than scattered in
  # /tmp. A stub container records the bind-mount source so we can prove where
  # the runner dir actually lived.
  unset RUNNER_WORK_ROOT
  export RUNNER_HOME="${WORK}/home"
  mkdir -p "${RUNNER_HOME}"
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-home "${jf}" img
  [ "${status}" -eq 0 ]
  # The runner dir bound into the container (-v <dir>:/runner:Z) was under
  # RUNNER_HOME/work -- captured argv carries the source path before the ':'.
  grep -qE "^${RUNNER_HOME}/work/jit-job-home\." "${CAP}"
}

@test "provision-job.sh per-job work root stays within the SEC-3 chokepoint (#130)" {
  # The mounted runner dir -- and therefore the rm -rf teardown target -- must
  # be lexically anchored under RUNNER_HOME/work, never outside it.
  unset RUNNER_WORK_ROOT
  export RUNNER_HOME="${WORK}/home"
  mkdir -p "${RUNNER_HOME}"
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-choke "${jf}" img
  [ "${status}" -eq 0 ]
  # No bound source path escaped the chokepoint (every -v source line for our
  # runner dir is prefixed by RUNNER_HOME/).
  ! grep -qE '^/tmp/jit-job-choke\.' "${CAP}"
  grep -qE "^${RUNNER_HOME}/" "${CAP}"
}

@test "provision-job.sh removes the per-job runner dir after the job (no residue)" {
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-abc "${jf}" img
  [ "${status}" -eq 0 ]
  # The throwaway jit-<job> dir must not survive the run.
  run bash -c "ls -d '${RUNNER_WORK_ROOT}'/jit-job-abc.* 2>/dev/null | wc -l"
  [ "${output}" = "0" ]
}

# --- capture-before-teardown (ADR-0002, #123/#124/#125) -------------------

@test "provision-job.sh captures a ledger record BEFORE teardown, on success (#123/#124)" {
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-hist "${jf}" ghcr.io/acme/runner:1.2
  [ "${status}" -eq 0 ]
  # A ledger line was written for this job, with its exit status and image --
  # the capture ran (and, since the runner dir is gone below, it ran BEFORE the
  # teardown that removed it).
  [ -f "${RUNNER_HISTORY_LEDGER}" ]
  grep -q 'job_id=job-hist' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=0' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'image=ghcr.io/acme/runner:1.2' "${RUNNER_HISTORY_LEDGER}"
  # Teardown still happened: no per-job runner dir residue.
  run bash -c "ls -d '${RUNNER_WORK_ROOT}'/jit-job-hist.* 2>/dev/null | wc -l"
  [ "${output}" = "0" ]
}

@test "provision-job.sh captures a ledger record on FAILURE too (#123)" {
  export CLI_RC=7
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-bad "${jf}" img
  [ "${status}" -eq 7 ]
  grep -q 'job_id=job-bad' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=7' "${RUNNER_HISTORY_LEDGER}"
}

@test "provision-job.sh archives the container log + survives into the store (#125)" {
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-log "${jf}" img
  [ "${status}" -eq 0 ]
  # The container's stdout was teed into the durable per-job archive, keyed by id.
  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-log/job.log" ]
  grep -q 'JOB-CONTAINER-OUTPUT' "${RUNNER_HISTORY_DIR}/jobs/job-log/job.log"
}

@test "provision-job.sh keeps job_log OUTSIDE the /runner mount so a hostile symlink-swap cannot exfiltrate host files (#145)" {
  # A hostile job has RW access to /runner (the bind-mounted runner dir). If the
  # captured job_log lived INSIDE that mount, a step could `ln -sf /etc/shadow
  # /runner/job.log`; the host re-opens job_log BY PATH after the container exits
  # (cat -> journald, history scrub -> durable store), following the symlink in
  # the HOST namespace and exfiltrating an arbitrary host file. job_log must live
  # on a host-only sibling path the job can never reach at /runner.
  secret="${WORK}/host-secret"
  printf 'TOPSECRETHOSTFILE\n' > "${secret}"
  # The stub plays the hostile job: it finds the bind-mounted runner dir from its
  # argv (-v <dir>:/runner:Z) and symlink-swaps <dir>/job.log -> the host secret,
  # exactly as a step inside the container could.
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
echo "name=docker" >> "${CAP}"
printf '%s\n' "\$@" >> "${CAP}"
for a in "\$@"; do
  case "\$a" in
    *:/runner:Z) d="\${a%%:/runner:Z}"; ln -sf "${secret}" "\${d}/job.log" ;;
  esac
done
echo "JOB-CONTAINER-OUTPUT"
exit \${CLI_RC:-0}
EOF
  chmod +x "${STUB}/docker"
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-swap "${jf}" img
  prov_out="${output}"
  [ "${status}" -eq 0 ]
  # provision-job's own stdout (which the listener mirrors to journald) must NOT
  # carry the host file the hostile symlink pointed at. Asserted with [[ ]] so a
  # violation aborts the test (a bare `! grep` is exempt from set -e mid-body).
  [[ "${prov_out}" != *TOPSECRETHOSTFILE* ]]
  # The durable archive holds the REAL container output, never the host file the
  # symlink redirected to.
  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-swap/job.log" ]
  run cat "${RUNNER_HISTORY_DIR}/jobs/job-swap/job.log"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *JOB-CONTAINER-OUTPUT* ]]
  [[ "${output}" != *TOPSECRETHOSTFILE* ]]
}

@test "provision-job.sh scrubs the JIT credential from its own stdout/journald, at parity with the history store (#151)" {
  # A hostile job step prints the single-use JIT credential to stdout (`echo
  # "$JITCONFIG"`). provision-job cats the captured container log to its OWN
  # stdout, which the Go provisioner mirrors to the listener's systemd journal
  # -- a durable, never-torn-down host sink. That stdout MUST be scrubbed with
  # the same value-redaction the durable history-store copy gets, so the
  # credential never survives verbatim in journald while the sibling archive is
  # redacted (#141/#143). Regression for the journald-vs-history scrub gap.
  secret='ENCODEDxJITxCREDENTIALxSURVIVESxJOURNALD=='
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
echo "name=docker" >> "${CAP}"
printf '%s\n' "\$@" >> "${CAP}"
# Hostile step prints the single-use JIT credential straight to stdout.
echo "${secret}"
exit \${CLI_RC:-0}
EOF
  chmod +x "${STUB}/docker"
  jf=$(jit_file "${secret}")
  run "${SCRIPT}" job-jitcred "${jf}" img
  [ "${status}" -eq 0 ]
  # provision-job's own stdout (journald) must NOT carry the raw credential.
  # Asserted with [[ ]] so a violation aborts (a bare `! grep` is exempt from
  # set -e mid-body).
  [[ "${output}" != *"${secret}"* ]]
  # The redaction marker proves the line was passed through the scrubber, not
  # merely dropped.
  [[ "${output}" == *REDACTED* ]]
  # Parity: the durable history-store copy is redacted too.
  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-jitcred/job.log" ]
  run cat "${RUNNER_HISTORY_DIR}/jobs/job-jitcred/job.log"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"${secret}"* ]]
}

@test "provision-job.sh never writes the JIT config into the history store (#124 redaction)" {
  jf=$(jit_file 'ENCODEDxJITxSECRETx==')
  run "${SCRIPT}" job-red "${jf}" img
  [ "${status}" -eq 0 ]
  ! grep -rqi 'ENCODEDxJITxSECRET' "${RUNNER_HISTORY_DIR}"
}

@test "provision-job.sh forwards the listener's forensic env as ledger fields (#124)" {
  jf=$(jit_file ENC)
  RUNNER_TYPE=gpu RUNNER_TRIGGER_REPO=octo/repo RUNNER_TRIGGER_ACTOR=octocat \
    RUNNER_IMAGE_DIGEST=sha256:beef \
    run "${SCRIPT}" job-env "${jf}" img
  [ "${status}" -eq 0 ]
  grep -q 'runner_type=gpu' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'trigger_repo=octo/repo' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'trigger_actor=octocat' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'image_digest=sha256:beef' "${RUNNER_HISTORY_LEDGER}"
}

@test "provision-job.sh capture failure does not block teardown or the job result (#123)" {
  # An unwritable history store makes capture fail; the job's exit status must
  # still propagate and the runner dir must still be torn down.
  export RUNNER_HISTORY_DIR=/proc/nonexistent/history
  export RUNNER_HISTORY_LEDGER=/proc/nonexistent/history/ledger.tsv
  jf=$(jit_file ENC)
  run "${SCRIPT}" job-bestffort "${jf}" img
  [ "${status}" -eq 0 ]
  run bash -c "ls -d '${RUNNER_WORK_ROOT}'/jit-job-bestffort.* 2>/dev/null | wc -l"
  [ "${output}" = "0" ]
}
