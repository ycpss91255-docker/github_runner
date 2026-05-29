#!/usr/bin/env bats
# Smoke tests for uninstall.sh argument parsing and the dry-run / no-op
# / non-TTY paths. Mutating paths that would actually call remove-runner.sh
# are exercised manually (see issue #11 for the design + acceptance
# criteria); here we cover the deterministic safe surface.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../uninstall.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

@test "uninstall.sh --help exits 0 with usage" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "uninstall.sh unknown option exits non-zero" {
  run "${SCRIPT}" --bogus
  [ "${status}" -ne 0 ]
}

@test "uninstall.sh empty RUNNER_HOME exits 0 with no-op message" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to remove"* ]]
}

@test "uninstall.sh --dry-run on empty RUNNER_HOME exits 0" {
  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to remove"* ]]
}

@test "uninstall.sh --dry-run with two fake org runners lists them but does not touch them" {
  mkdir -p "${FAKE_RH}/myorg-a/_org" "${FAKE_RH}/myorg-b/_org" "${FAKE_RH}/.bin"
  touch "${FAKE_RH}/myorg-a/_org/.runner" "${FAKE_RH}/myorg-b/_org/.runner"
  touch "${FAKE_RH}/.bin/fake-tarball.tar.gz"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Runners to deregister: 2"* ]]
  [[ "${output}" == *"org myorg-a"* ]]
  [[ "${output}" == *"org myorg-b"* ]]
  [[ "${output}" == *"Dry-run; nothing removed."* ]]

  # Files still in place after dry-run.
  [ -f "${FAKE_RH}/myorg-a/_org/.runner" ]
  [ -f "${FAKE_RH}/myorg-b/_org/.runner" ]
  [ -f "${FAKE_RH}/.bin/fake-tarball.tar.gz" ]
}

@test "uninstall.sh --dry-run lists repo-scoped runners with the repo format" {
  mkdir -p "${FAKE_RH}/owner-a/repo-x" "${FAKE_RH}/owner-b/repo-y"
  touch "${FAKE_RH}/owner-a/repo-x/.runner" "${FAKE_RH}/owner-b/repo-y/.runner"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"repo owner-a/repo-x"* ]]
  [[ "${output}" == *"repo owner-b/repo-y"* ]]
}

@test "uninstall.sh without --yes in non-TTY context exits 1" {
  mkdir -p "${FAKE_RH}/somewhere/_org"
  touch "${FAKE_RH}/somewhere/_org/.runner"

  # bats's run inherits a non-TTY stdin, which is exactly the path we
  # want to exercise here.
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"non-interactive run requires --yes"* ]]
}
