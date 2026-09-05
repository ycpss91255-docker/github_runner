#!/usr/bin/env bats
# Smoke tests for lib/runner-service.sh -- the svc.sh lifecycle seam. A stub
# svc.sh in a fake runner dir records the verb it was asked to run; a
# transparent PATH `sudo` lets the helper's `sudo ./svc.sh` reach it. Pure lib
# (no main), sourced via common.sh, so the helpers are unit-testable directly.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../../lib/common.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
  source "${LIB}"

  RUNNER_DIR="${FAKE_RH}/acme/_org"
  mkdir -p "${RUNNER_DIR}"
  cat >"${RUNNER_DIR}/svc.sh" <<EOF
#!/usr/bin/env bash
echo "SVC \$*" >> "${FAKE_RH}/svc.log"
exit \${SVC_RC:-0}
EOF
  chmod +x "${RUNNER_DIR}/svc.sh"

  STUB=$(mktemp -d)
  printf '#!/usr/bin/env bash\nexec "$@"\n' > "${STUB}/sudo"   # transparent sudo
  chmod +x "${STUB}/sudo"
  PATH="${STUB}:${PATH}"
}

teardown() { rm -rf "${FAKE_RH}" "${STUB}"; }

@test "runner_service_install runs svc.sh install <user> from the runner dir" {
  run runner_service_install "${RUNNER_DIR}" alice
  [ "${status}" -eq 0 ]
  grep -qx "SVC install alice" "${FAKE_RH}/svc.log"
}

@test "runner_service_start runs svc.sh start" {
  run runner_service_start "${RUNNER_DIR}"
  [ "${status}" -eq 0 ]
  grep -qx "SVC start" "${FAKE_RH}/svc.log"
}

@test "runner_service_install propagates a svc.sh failure" {
  export SVC_RC=3
  run runner_service_install "${RUNNER_DIR}" alice
  [ "${status}" -ne 0 ]
}

@test "runner_service_stop is best-effort: swallows a svc.sh failure" {
  export SVC_RC=5
  run runner_service_stop "${RUNNER_DIR}"
  [ "${status}" -eq 0 ]
  grep -qx "SVC stop" "${FAKE_RH}/svc.log"
}

@test "runner_service_uninstall is best-effort" {
  export SVC_RC=5
  run runner_service_uninstall "${RUNNER_DIR}"
  [ "${status}" -eq 0 ]
}

@test "the verb runs with the runner dir as cwd, restoring the caller's cwd" {
  local before; before=$(pwd)
  run runner_service_start "${RUNNER_DIR}"
  [ "${status}" -eq 0 ]
  [ "$(pwd)" = "${before}" ]
}
