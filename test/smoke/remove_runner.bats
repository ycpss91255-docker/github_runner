#!/usr/bin/env bats
# Smoke tests for remove-runner.sh.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/remove-runner.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
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

@test "remove-runner.sh --help prints Usage and exits 0" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

# M4: a bogus scope must hit the script's own validation and print the rich
# usage() (not resolve_target's terse one-line arity error) before exiting 1.
@test "remove-runner.sh with a bogus scope prints the rich usage and exits 1" {
  run "${SCRIPT}" bogus foo
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Usage:"* ]]
}
