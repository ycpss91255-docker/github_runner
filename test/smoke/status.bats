#!/usr/bin/env bats
# Smoke tests for status.sh.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../status.sh"
  FAKE_RH=$(mktemp -d)
  # Point RUNNER_HOME at a non-existent subdir so the "missing dir" branch
  # fires; tests that want an empty dir create RUNNER_HOME explicitly.
  export RUNNER_HOME="${FAKE_RH}/runners"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

@test "status.sh missing RUNNER_HOME directory -> exits 0 with message" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"./init.sh"* ]]
}

@test "status.sh empty RUNNER_HOME -> headers only" {
  mkdir -p "${RUNNER_HOME}"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"NAME"* ]]
  [[ "${output}" == *"SCOPE"* ]]
  [[ "${output}" == *"LOCAL-SVC"* ]]
  [[ "${output}" == *"GITHUB"* ]]
  [[ "${output}" == *"PUBLIC-DISPATCH"* ]]
}
