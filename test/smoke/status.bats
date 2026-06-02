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

@test "status.sh accepts -i as the interval flag" {
  # U1: -i replaced -n for --interval. Missing RUNNER_HOME -> exits 0 cleanly.
  run "${SCRIPT}" -i 5
  [ "${status}" -eq 0 ]
}

@test "status.sh no longer accepts -n (frees it from the cross-script collision)" {
  run "${SCRIPT}" -n 5
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown option: -n"* ]]
}
