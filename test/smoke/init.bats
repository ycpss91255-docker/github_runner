#!/usr/bin/env bats
# Smoke tests for init.sh prereq checking.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../init.sh"
  FAKE_HOME=$(mktemp -d)
  export HOME="${FAKE_HOME}"
}

teardown() {
  rm -rf "${FAKE_HOME}"
}

@test "init.sh fails when PATH has no docker / nvidia-smi / gh" {
  # Stripped PATH -> none of docker/nvidia-smi/gh found -> prereq check should fail
  PATH=/usr/bin run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  # At least one FAIL line printed
  [[ "${output}" == *"FAIL:"* ]]
}

@test "init.sh prints FAIL when docker missing" {
  EMPTY_PATH=$(mktemp -d)
  PATH="${EMPTY_PATH}" run "${SCRIPT}"
  rm -rf "${EMPTY_PATH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"docker not installed"* ]]
}
