#!/usr/bin/env bats
# Smoke tests for install-deps.sh (#33). The apt-get install + `gh auth login`
# paths need a real apt host + network + a human, so they are NOT exercised
# here (same testing boundary as init.sh's install path); the hermetic parts
# are arg parsing, the --dry-run report, and the apt-guard. The test-tools
# alpine image has none of gh/jq/curl/sudo/apt-get, so --dry-run reports all
# four missing and the real path hits the apt-guard.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/install-deps.sh"
}

@test "install-deps.sh --dry-run reports the missing CLI deps and installs nothing" {
  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"gh"* ]]
  [[ "${output}" == *"jq"* ]]
  [[ "${output}" == *"curl"* ]]
  [[ "${output}" == *"sudo"* ]]
}

@test "install-deps.sh --help prints Usage and exits 0" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "install-deps.sh rejects an unknown option" {
  run "${SCRIPT}" --bogus
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown option: --bogus"* ]]
}

@test "install-deps.sh real run on a non-apt host fails with clear guidance" {
  # No apt-get in the alpine test image -> the apt-guard fires before any install.
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"supports apt"* ]]
}

@test "install-deps.sh -y --dry-run still only reports (no install)" {
  run "${SCRIPT}" -y --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"missing CLI deps"* ]]
}
