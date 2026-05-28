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
  # /usr/bin keeps bash + groups + grep reachable so the script starts and
  # runs the prereq checks; docker / nvidia-smi / gh / jq are absent there
  # on github-hosted ubuntu-latest, so command -v fails and FAIL lines print.
  PATH=/usr/bin run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"FAIL:"* ]]
}
