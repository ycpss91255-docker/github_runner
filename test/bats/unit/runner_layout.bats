#!/usr/bin/env bats
# Smoke tests for lib/runner-layout.sh -- the on-disk layout module. It is a
# pure lib (no main), sourced here via common.sh (the production entry) with
# RUNNER_HOME set, so every function is unit-testable directly.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../../lib/common.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
  source "${LIB}"
}

teardown() { rm -rf "${FAKE_RH}"; }

@test "runner_dir builds the org path under <owner>/_org" {
  [ "$(runner_dir org acme)" = "${RUNNER_HOME}/acme/_org" ]
}

@test "runner_dir builds the repo path under <owner>/<repo>" {
  [ "$(runner_dir repo acme widgets)" = "${RUNNER_HOME}/acme/widgets" ]
}

@test "runner_agent_name: org form is <host>-<owner>-org" {
  [ "$(runner_agent_name org acme)" = "$(hostname)-acme-org" ]
}

@test "runner_agent_name: repo form is <host>-<owner>-<repo>" {
  [ "$(runner_agent_name repo acme widgets)" = "$(hostname)-acme-widgets" ]
}

@test "runner_marker_file appends .runner (tolerates a trailing slash)" {
  [ "$(runner_marker_file /x/y)"  = "/x/y/.runner" ]
  [ "$(runner_marker_file /x/y/)" = "/x/y/.runner" ]
}

@test "runner_scope_of reads the _org sentinel back to a scope" {
  [ "$(runner_scope_of "${RUNNER_HOME}/acme/_org")"    = "org" ]
  [ "$(runner_scope_of "${RUNNER_HOME}/acme/widgets")" = "repo" ]
}

@test "runner_dir and runner_scope_of round-trip" {
  [ "$(runner_scope_of "$(runner_dir org acme)")" = "org" ]
  [ "$(runner_scope_of "$(runner_dir repo acme widgets)")" = "repo" ]
}

@test "runner_service_unit_pattern matches the installed systemd unit name" {
  pat="$(runner_service_unit_pattern host-acme-org)"
  echo "actions.runner.acme-org.host-acme-org.service" | grep -qE "${pat}"
  run bash -c "echo 'actions.runner.acme-org.other.service' | grep -qE '${pat}'"
  [ "${status}" -ne 0 ]
}

@test "runner_active_version reads the version from the bin symlink" {
  d="${RUNNER_HOME}/acme/_org"; mkdir -p "${d}/bin.2.334.0"
  ln -s bin.2.334.0 "${d}/bin"
  [ "$(runner_active_version "${d}")" = "2.334.0" ]
}

@test "runner_active_version is empty when bin is not a symlink" {
  d="${RUNNER_HOME}/acme/widgets"; mkdir -p "${d}"
  [ -z "$(runner_active_version "${d}")" ]
}
