#!/usr/bin/env bats
# Smoke tests for init.sh prereq checking.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/init.sh"
  FAKE_HOME=$(mktemp -d)
  export HOME="${FAKE_HOME}"
}

teardown() {
  rm -rf "${FAKE_HOME}"
}

@test "init.sh reports every missing prereq individually and the aggregate gate fires" {
  # /bin + /usr/bin keeps bash (alpine) and groups / grep reachable so the
  # script starts and runs the prereq checks. docker / nvidia-smi / gh / jq
  # are absent in the test-tools alpine container so each command -v fails.
  # This is the B1 regression test: a set -e short-circuit on the first
  # failure would print only ONE FAIL line and never reach the summary.
  # Assert prereqs reliably ABSENT in the alpine test-tools image (docker
  # CLI happens to be present there, so don't assert on it).
  PATH=/bin:/usr/bin run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"FAIL: nvidia-smi not found"* ]]
  [[ "${output}" == *"FAIL: gh CLI not installed"* ]]
  [[ "${output}" == *"FAIL: jq not installed"* ]]
  [[ "${output}" == *"prereq check failed"* ]]
  [ "$(printf '%s\n' "${output}" | grep -c '^FAIL:')" -ge 4 ]
}

@test "init.sh prereq failures and the summary go to stderr, not stdout" {
  run bash -c "PATH=/bin:/usr/bin '${SCRIPT}' 2>'${BATS_TEST_TMPDIR}/err' >'${BATS_TEST_TMPDIR}/out'"
  [ "${status}" -ne 0 ]
  grep -q '^FAIL:' "${BATS_TEST_TMPDIR}/err"
  grep -q 'prereq check failed' "${BATS_TEST_TMPDIR}/err"
  ! grep -q '^FAIL:' "${BATS_TEST_TMPDIR}/out"
}

@test "init.sh --help prints Usage and does not bootstrap a runner" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
  [[ "${output}" != *"bootstrapping first runner"* ]]
}
