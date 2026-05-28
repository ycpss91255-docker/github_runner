#!/usr/bin/env bats
# Smoke tests for remove-runner.sh.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../remove-runner.sh"
  FAKE_HOME=$(mktemp -d)
  export HOME="${FAKE_HOME}"
}

teardown() {
  rm -rf "${FAKE_HOME}"
}

@test "remove-runner.sh with no args exits non-zero" {
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
}

@test "remove-runner.sh org without org name exits non-zero" {
  run "${SCRIPT}" org
  [ "${status}" -ne 0 ]
}

@test "remove-runner.sh no-op when no runner exists" {
  run "${SCRIPT}" org nonexistent
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"nothing to remove"* ]]
}
