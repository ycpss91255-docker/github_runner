#!/usr/bin/env bats
# Smoke tests for lib/runner-run.sh -- the ephemeral single-job run seam
# (ADR-0001, advances #80). A stub run.sh in a fake runner dir records the
# args it was asked to run (and its cwd); the seam runs the runner ONCE from
# its dir via `./run.sh --jitconfig <encoded>` -- no svc.sh / systemd, one job
# then the process exits and the ephemeral runner auto-deregisters. Pure lib
# (no main), sourced via common.sh; run.sh needs no sudo. Mirrors the
# runner_config.bats / runner_service.bats stub style.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
  source "${LIB}"

  RUNNER_DIR="${FAKE_RH}/acme/_org"
  mkdir -p "${RUNNER_DIR}"
  # Records its argv (one per line so --jitconfig + the encoded value can be
  # grepped exactly) and the cwd it ran in, then exits RUN_RC (default 0).
  cat >"${RUNNER_DIR}/run.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${FAKE_RH}/run.args"
pwd >> "${FAKE_RH}/run.cwd"
exit \${RUN_RC:-0}
EOF
  chmod +x "${RUNNER_DIR}/run.sh"
}

teardown() { rm -rf "${FAKE_RH}"; }

@test "runner_run_jit runs run.sh --jitconfig <encoded> from the runner dir" {
  run runner_run_jit "${RUNNER_DIR}" ENCODEDxJITxCONFIGx==
  [ "${status}" -eq 0 ]
  grep -qxF -- '--jitconfig' "${FAKE_RH}/run.args"
  grep -qxF -- 'ENCODEDxJITxCONFIGx==' "${FAKE_RH}/run.args"
}

@test "runner_run_jit invokes run.sh with the runner dir as cwd" {
  run runner_run_jit "${RUNNER_DIR}" ENC
  [ "${status}" -eq 0 ]
  grep -qxF -- "${RUNNER_DIR}" "${FAKE_RH}/run.cwd"
}

@test "runner_run_jit does NOT use svc.sh / systemd (no service verbs)" {
  run runner_run_jit "${RUNNER_DIR}" ENC
  [ "${status}" -eq 0 ]
  ! grep -qE 'install|start|svc' "${FAKE_RH}/run.args"
}

@test "runner_run_jit propagates run.sh's exit status (the single job's result)" {
  export RUN_RC=7
  run runner_run_jit "${RUNNER_DIR}" ENC
  [ "${status}" -eq 7 ]
}

@test "runner_run_jit restores the caller's cwd" {
  local before; before=$(pwd)
  run runner_run_jit "${RUNNER_DIR}" ENC
  [ "${status}" -eq 0 ]
  [ "$(pwd)" = "${before}" ]
}
