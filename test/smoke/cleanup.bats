#!/usr/bin/env bats
# Smoke tests for cleanup.sh argument parsing and the dry-run / no-op /
# non-TTY paths, plus enumeration of the three prunable categories.
# Mutating paths that actually rm are exercised via --dry-run; we assert
# the files stay in place.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/cleanup.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

# Build a fake configured runner dir for $1=org, with active version $2.
# Drops a `.runner` marker, `bin -> bin.$2`, `externals -> externals.$2`,
# and matching version dirs.
fake_runner() {
  local org=$1 ver=$2
  local d="${FAKE_RH}/${org}/_org"
  mkdir -p "${d}/bin.${ver}" "${d}/externals.${ver}" "${d}/_work"
  touch "${d}/.runner"
  ln -s "bin.${ver}" "${d}/bin"
  ln -s "externals.${ver}" "${d}/externals"
}

@test "cleanup.sh --help exits 0 with usage" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "cleanup.sh unknown option exits non-zero" {
  run "${SCRIPT}" --bogus
  [ "${status}" -ne 0 ]
}

@test "cleanup.sh missing RUNNER_HOME exits 0 with no-op message" {
  rm -rf "${FAKE_RH}"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
}

@test "cleanup.sh empty RUNNER_HOME exits 0 with no-op message" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
}

@test "cleanup.sh ignores the active bin.X / externals.X dirs" {
  fake_runner myorg 2.334.0
  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
  [ -d "${FAKE_RH}/myorg/_org/bin.2.334.0" ]
}

@test "cleanup.sh lists stale bin.X / externals.X under --dry-run and leaves them" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/bin.2.319.1" "${FAKE_RH}/myorg/_org/externals.2.319.1"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"stale myorg/_org -> bin.2.319.1"* ]]
  [[ "${output}" == *"stale myorg/_org -> externals.2.319.1"* ]]
  [[ "${output}" == *"Dry-run; nothing removed."* ]]
  [ -d "${FAKE_RH}/myorg/_org/bin.2.319.1" ]
  [ -d "${FAKE_RH}/myorg/_org/externals.2.319.1" ]
}

@test "cleanup.sh lists _work/_update remnants under --dry-run and leaves them" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/_work/_update"
  touch "${FAKE_RH}/myorg/_org/_work/_update.sh"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"self-update remnant myorg/_org/_work/_update/"* ]]
  [[ "${output}" == *"self-update remnant myorg/_org/_work/_update.sh"* ]]
  [ -d "${FAKE_RH}/myorg/_org/_work/_update" ]
  [ -f "${FAKE_RH}/myorg/_org/_work/_update.sh" ]
}

@test "cleanup.sh keeps highest cached tarball and drops older ones (dry-run)" {
  mkdir -p "${FAKE_RH}/.bin"
  touch "${FAKE_RH}/.bin/actions-runner-linux-x64-2.319.1.tar.gz"
  touch "${FAKE_RH}/.bin/actions-runner-linux-x64-2.330.0.tar.gz"
  touch "${FAKE_RH}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"old cached tarball actions-runner-linux-x64-2.319.1.tar.gz"* ]]
  [[ "${output}" == *"old cached tarball actions-runner-linux-x64-2.330.0.tar.gz"* ]]
  [[ "${output}" != *"old cached tarball actions-runner-linux-x64-2.334.0.tar.gz"* ]]
}

@test "cleanup.sh with a single cached tarball reports no-op" {
  mkdir -p "${FAKE_RH}/.bin"
  touch "${FAKE_RH}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
}

@test "cleanup.sh without --yes in non-TTY context exits 1" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/bin.2.319.1"

  # bats's run inherits a non-TTY stdin -- the path we want to exercise.
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"non-interactive run requires --yes"* ]]
}

@test "cleanup.sh --yes actually removes the stale items" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/bin.2.319.1" \
           "${FAKE_RH}/myorg/_org/externals.2.319.1" \
           "${FAKE_RH}/myorg/_org/_work/_update" \
           "${FAKE_RH}/.bin"
  touch "${FAKE_RH}/myorg/_org/_work/_update.sh" \
        "${FAKE_RH}/.bin/actions-runner-linux-x64-2.319.1.tar.gz" \
        "${FAKE_RH}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"

  run "${SCRIPT}" --yes
  [ "${status}" -eq 0 ]
  # D8: exact summary (5 prunable items: stale bin + externals + _update dir +
  # _update.sh + old tarball). A loose "0 failed" substring also matches
  # "10 failed"; the precise count catches an over/under-prune regression.
  [[ "${output}" == *"Summary: 5 removed, 0 failed."* ]]

  [ ! -e "${FAKE_RH}/myorg/_org/bin.2.319.1" ]
  [ ! -e "${FAKE_RH}/myorg/_org/externals.2.319.1" ]
  [ ! -e "${FAKE_RH}/myorg/_org/_work/_update" ]
  [ ! -e "${FAKE_RH}/myorg/_org/_work/_update.sh" ]
  [ ! -e "${FAKE_RH}/.bin/actions-runner-linux-x64-2.319.1.tar.gz" ]

  # The active version dirs / symlinks and the highest cached tarball
  # must survive.
  [ -d "${FAKE_RH}/myorg/_org/bin.2.334.0" ]
  [ -d "${FAKE_RH}/myorg/_org/externals.2.334.0" ]
  [ -L "${FAKE_RH}/myorg/_org/bin" ]
  [ -L "${FAKE_RH}/myorg/_org/externals" ]
  [ -f "${FAKE_RH}/.bin/actions-runner-linux-x64-2.334.0.tar.gz" ]
}

@test "cleanup.sh --yes a second time finds nothing to clean (idempotent)" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/bin.2.319.1"
  "${SCRIPT}" --yes >/dev/null
  run "${SCRIPT}" --yes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
}
