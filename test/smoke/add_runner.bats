#!/usr/bin/env bats
# Smoke tests for add-runner.sh argument parsing and idempotency.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/add-runner.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

@test "add-runner.sh with no args exits non-zero" {
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
}

@test "add-runner.sh with unknown scope exits non-zero" {
  run "${SCRIPT}" foo bar
  [ "${status}" -ne 0 ]
}

@test "add-runner.sh org without org name exits non-zero" {
  run "${SCRIPT}" org
  [ "${status}" -ne 0 ]
}

@test "add-runner.sh idempotent: existing .runner file -> exit 0 with already-configured message" {
  mkdir -p "${RUNNER_HOME}/testorg/_org"
  touch "${RUNNER_HOME}/testorg/_org/.runner"

  run "${SCRIPT}" org testorg
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already configured"* ]]
}

@test "add-runner.sh fresh run without tarball cache exits non-zero" {
  # No .runner exists -> proceeds to tarball check -> fails because no cache
  run "${SCRIPT}" org someorg
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"tarball missing"* ]]
}

@test "add-runner.sh --help prints Usage and exits 0" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "add-runner.sh removes the partial dir when extraction fails (B1 idempotency)" {
  # A corrupt tarball makes tar fail after mkdir; the ERR trap must remove the
  # half-created TARGET_DIR so a retry starts clean. A gh stub on PATH lets
  # require_gh_auth + the token fetch (which run 'command gh') pass first.
  mkdir -p "${RUNNER_HOME}/.bin"
  printf 'not-a-real-gzip' > "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"
  STUB=$(mktemp -d)
  printf '#!/bin/sh\nprintf "TOKEN\\n"\n' > "${STUB}/gh"   # any args -> succeeds, prints a token
  chmod +x "${STUB}/gh"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" org myorg
  rm -rf "${STUB}"
  [ "${status}" -ne 0 ]
  [ ! -e "${RUNNER_HOME}/myorg/_org" ]
}
