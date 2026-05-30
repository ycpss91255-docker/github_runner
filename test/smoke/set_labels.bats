#!/usr/bin/env bats
# Smoke tests for set-labels.sh argument / state validation. Like
# add_runner.bats, these exercise the early-exit branches that run before
# any gh API call; the live PUT is not exercised here.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/set-labels.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

@test "set-labels.sh with no args exits non-zero" {
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
}

@test "set-labels.sh with unknown scope exits non-zero" {
  run "${SCRIPT}" foo bar gpu
  [ "${status}" -ne 0 ]
}

@test "set-labels.sh org without a labels arg exits non-zero" {
  run "${SCRIPT}" org myorg
  [ "${status}" -ne 0 ]
}

@test "set-labels.sh repo with missing args exits non-zero" {
  run "${SCRIPT}" repo owner
  [ "${status}" -ne 0 ]
}

@test "set-labels.sh with invalid labels exits non-zero" {
  run "${SCRIPT}" org myorg 'bad label'
  [ "${status}" -ne 0 ]
}

@test "set-labels.sh on an unregistered runner exits non-zero with a message" {
  # No .runner under RUNNER_HOME -> bails before any gh call.
  run "${SCRIPT}" org myorg gpu,cuda12
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no runner"* ]]
}
