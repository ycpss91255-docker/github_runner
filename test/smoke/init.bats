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

@test "init.sh fails when PATH has no docker / nvidia-smi / gh" {
  # /bin + /usr/bin keeps bash (alpine) and groups / grep (both alpine and
  # ubuntu) reachable so the script starts and runs the prereq checks.
  # docker / nvidia-smi / gh / jq are absent in the test-tools alpine
  # container so command -v fails and FAIL lines print.
  PATH=/bin:/usr/bin run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"FAIL:"* ]]
}
