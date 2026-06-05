#!/usr/bin/env bats
# Smoke tests for lib/runner-config.sh -- the config.sh registration seam. A
# stub config.sh in a fake runner dir records the verb+args it was asked to
# run. Pure lib (no main), sourced via common.sh; config.sh needs no sudo.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
  source "${LIB}"

  RUNNER_DIR="${FAKE_RH}/acme/_org"
  mkdir -p "${RUNNER_DIR}"
  cat >"${RUNNER_DIR}/config.sh" <<EOF
#!/usr/bin/env bash
echo "CFG \$*" >> "${FAKE_RH}/config.log"
exit \${CFG_RC:-0}
EOF
  chmod +x "${RUNNER_DIR}/config.sh"
}

teardown() { rm -rf "${FAKE_RH}"; }

@test "runner_config_register runs config.sh --unattended with all args from the dir" {
  run runner_config_register "${RUNNER_DIR}" https://github.com/acme tok123 gpu,cuda host-acme-org
  [ "${status}" -eq 0 ]
  grep -qx 'CFG --unattended --url https://github.com/acme --token tok123 --labels gpu,cuda --name host-acme-org --work _work' \
    "${FAKE_RH}/config.log"
}

@test "runner_config_deregister runs config.sh remove --token from the dir" {
  run runner_config_deregister "${RUNNER_DIR}" tok456
  [ "${status}" -eq 0 ]
  grep -qx 'CFG remove --token tok456' "${FAKE_RH}/config.log"
}

@test "runner_config_register propagates a config.sh failure (for add-runner's ERR trap)" {
  export CFG_RC=4
  run runner_config_register "${RUNNER_DIR}" u t l n
  [ "${status}" -ne 0 ]
}

@test "config.sh runs from the runner dir, restoring the caller's cwd" {
  local before; before=$(pwd)
  run runner_config_deregister "${RUNNER_DIR}" tok
  [ "${status}" -eq 0 ]
  [ "$(pwd)" = "${before}" ]
}
