#!/usr/bin/env bats
# Smoke tests for lib/common.sh runner_service_running (C3). The systemd
# unit-name convention lives here once; tests shadow `systemctl` to feed
# canned `list-units` output, so the check runs without a live systemd.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
}

@test "runner_service_running is true when the unit for that runner is loaded" {
  run bash -c "
    source '${LIB}'
    systemctl() { printf '  actions.runner.acme.host-acme-org.service loaded active running\n'; }
    runner_service_running host-acme-org
  "
  [ "${status}" -eq 0 ]
}

@test "runner_service_running is false when no unit matches the runner" {
  run bash -c "
    source '${LIB}'
    systemctl() { printf '  ssh.service loaded active running\n'; }
    runner_service_running host-acme-org
  "
  [ "${status}" -ne 0 ]
}

@test "runner_service_running does not false-positive on a name that is a prefix of another" {
  # Only host-acme-org-2 is loaded; querying host-acme-org must NOT match.
  run bash -c "
    source '${LIB}'
    systemctl() { printf '  actions.runner.acme.host-acme-org-2.service loaded active running\n'; }
    runner_service_running host-acme-org
  "
  [ "${status}" -ne 0 ]
}
