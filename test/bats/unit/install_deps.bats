#!/usr/bin/env bats
# Smoke tests for install-deps.sh (#33). The apt-get install + `gh auth login`
# paths need a real apt host + network + a human, so they are NOT exercised
# here (same testing boundary as init.sh's install path); the hermetic parts
# are arg parsing, the --dry-run report, and the apt-guard. The test-tools
# alpine image has none of gh/jq/curl/sudo/apt-get, so --dry-run reports all
# four missing and the real path hits the apt-guard.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../script/install-deps.sh"
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
  # Hermetic: drive the apt-guard by overriding have() so apt-get reads as
  # absent, instead of relying on the ambient image lacking apt-get (the
  # alpine test-tools image has none, but the Debian kcov coverage image
  # does -- which made this assertion image-dependent).
  #
  # Source in the test body (not a `bash -c` sub-shell) + `run main`: under
  # kcov, a sub-shell that runs a set -u script aborts on kcov's BASH_ENV
  # instrumentation referencing an unbound BASH_SOURCE; sourcing here runs
  # the function in the bats process where BASH_SOURCE is set, so the helper
  # stays instrumented and the assertion is image-independent.
  source "${SCRIPT}"
  have() { return 1; }
  run main
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"supports apt"* ]]
}

@test "install-deps.sh -y --dry-run still only reports (no install)" {
  run "${SCRIPT}" -y --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"missing CLI deps"* ]]
}

@test "install-deps.sh fails when apt-get is present but sudo is absent and not root" {
  # Make apt-get appear present so the guard reaches the root/sudo check, while
  # sudo stays absent and id reports a non-root uid -> "need root or sudo".
  source "${SCRIPT}"
  have() { [ "$1" = apt-get ]; }
  id() { echo 1000; }
  run main
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"need root or sudo"* ]]
}

@test "confirm() defaults to yes on empty input (apt-style)" {
  source "${SCRIPT}"
  YES=0
  run confirm 'Install foo?' <<< ''
  [ "${status}" -eq 0 ]
}

@test "confirm() returns 1 when the user answers no" {
  source "${SCRIPT}"
  YES=0
  run confirm 'Install foo?' <<< 'n'
  [ "${status}" -eq 1 ]
}

@test "confirm() returns 0 without prompting when YES=1" {
  source "${SCRIPT}"
  YES=1
  run confirm 'Install foo?' < /dev/null
  [ "${status}" -eq 0 ]
}

@test "run_root runs the command directly when already root" {
  # id -u == 0 -> no sudo; the command runs verbatim.
  source "${SCRIPT}"
  id() { echo 0; }
  sudo() { echo 'SUDO-CALLED'; }
  run run_root echo RAN
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RAN"* ]]
  [[ "${output}" != *"SUDO-CALLED"* ]]
}

@test "run_root prefixes sudo when not root" {
  source "${SCRIPT}"
  id() { echo 1000; }
  sudo() { echo "SUDO: $*"; }
  run run_root echo RAN
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SUDO: echo RAN"* ]]
}
