#!/usr/bin/env bats
# Smoke tests for update.sh. The real upgrade path needs registered runners +
# network + sudo, so only the --help short-circuit is exercised here.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/update.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

@test "update.sh --help prints Usage and exits 0 without downloading" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
  [[ "${output}" != *"downloading"* ]]
}
