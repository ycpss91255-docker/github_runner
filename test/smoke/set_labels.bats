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

@test "set-labels.sh rejects invalid labels with the validate_labels reason" {
  # D7: assert the SPECIFIC rejection reason, not just a non-zero exit (which
  # an unconditional early exit would also satisfy).
  run "${SCRIPT}" org myorg 'bad label'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid labels: 'bad label'"* ]]
}

@test "set-labels.sh on an unregistered runner exits non-zero with a message" {
  # No .runner under RUNNER_HOME -> bails before any gh call.
  run "${SCRIPT}" org myorg gpu,cuda12
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no runner"* ]]
}

@test "set-labels.sh org happy path resolves the agentId, sets labels, and confirms" {
  # D7: the first real happy-path coverage of set-labels. _gh runs 'command gh'
  # (bypassing shell functions), so the GitHub call is faked with a real gh
  # stub on PATH that echoes the server's resulting label set.
  mkdir -p "${RUNNER_HOME}/myorg/_org"
  printf '\xef\xbb\xbf{\n  "agentId": 142,\n  "agentName": "r"\n}\n' \
    > "${RUNNER_HOME}/myorg/_org/.runner"
  STUB=$(mktemp -d)
  printf '#!/bin/sh\nprintf "gpu\\ncuda12\\n"\n' > "${STUB}/gh"
  chmod +x "${STUB}/gh"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" org myorg gpu,cuda12
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"gpu,cuda12"* ]]
  [[ "${output}" == *"-myorg-org (id 142): gpu,cuda12"* ]]
}
