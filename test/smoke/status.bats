#!/usr/bin/env bats
# Smoke tests for status.sh.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/status.sh"
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
  [[ "${output}" == *"./script/init.sh"* ]]
}

@test "status.sh on empty RUNNER_HOME prints the no-runners notice and zero data rows" {
  # D6: assert the behavior (no-runners notice + no per-runner state cells)
  # rather than just the header vocabulary, which can't tell empty from
  # populated.
  mkdir -p "${RUNNER_HOME}"
  run "${SCRIPT}" --no-color
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"(no runners found in ${RUNNER_HOME})"* ]]
  [ "$(printf '%s\n' "${output}" | grep -cE 'public-ok|public-BLOCKED|online|offline|not-found')" -eq 0 ]
}
