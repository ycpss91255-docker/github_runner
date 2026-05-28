#!/usr/bin/env bats
# Smoke tests for status.sh.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../status.sh"
  FAKE_HOME=$(mktemp -d)
  export HOME="${FAKE_HOME}"
}

teardown() {
  rm -rf "${FAKE_HOME}"
}

@test "status.sh missing RUNNER_HOME directory -> exits 0 with message" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"./init.sh"* ]]
}

@test "status.sh empty RUNNER_HOME -> headers only" {
  mkdir -p "${FAKE_HOME}/github_runner"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"NAME"* ]]
  [[ "${output}" == *"SCOPE"* ]]
  [[ "${output}" == *"LOCAL-SVC"* ]]
  [[ "${output}" == *"GITHUB"* ]]
}
