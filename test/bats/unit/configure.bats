#!/usr/bin/env bats
# Smoke tests for configure.sh -- generates/updates the registration
# setup.conf consumed by add-runner.sh / init.sh. Fully hermetic: only
# touches a temp RUNNER_HOME, no gh / sudo / config.sh.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../script/configure.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

@test "configure.sh --labels writes setup.conf with the labels" {
  run "${SCRIPT}" --labels gpu,cuda12
  [ "${status}" -eq 0 ]
  [ -f "${RUNNER_HOME}/setup.conf" ]
  grep -qx 'LABELS=gpu,cuda12' "${RUNNER_HOME}/setup.conf"
}

@test "configure.sh --labels rewrites the LABELS key idempotently (no duplicate)" {
  "${SCRIPT}" --labels gpu >/dev/null
  run "${SCRIPT}" --labels gpu,cuda12
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^LABELS=' "${RUNNER_HOME}/setup.conf")" -eq 1 ]
  grep -qx 'LABELS=gpu,cuda12' "${RUNNER_HOME}/setup.conf"
}

@test "configure.sh with no args prints exactly the gpu default (scrubbed env)" {
  # D4: scrub the env so an ambient LABELS can't satisfy the assertion, and
  # match the whole output line exactly rather than a loose substring.
  run env -i HOME="${HOME}" PATH="${PATH}" RUNNER_HOME="${RUNNER_HOME}" "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "LABELS=gpu" ]
}

@test "configure.sh with no args reflects a written setup.conf" {
  "${SCRIPT}" --labels fast,gpu >/dev/null
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"LABELS=fast,gpu"* ]]
}

@test "configure.sh --labels with an invalid value exits non-zero" {
  run "${SCRIPT}" --labels 'bad label'
  [ "${status}" -ne 0 ]
}

@test "configure.sh --labels without a value exits non-zero" {
  run "${SCRIPT}" --labels
  [ "${status}" -ne 0 ]
}

@test "configure.sh with an unknown option exits non-zero" {
  run "${SCRIPT}" --frobnicate
  [ "${status}" -ne 0 ]
}
