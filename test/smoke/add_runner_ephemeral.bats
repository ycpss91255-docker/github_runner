#!/usr/bin/env bats
# Smoke tests for add-runner.sh's NEW DEFAULT: the ephemeral / JIT scale-set
# path (ADR-0001 Phase 5, advances #77 -- closes the migration). The persistent
# config.sh-once + svc.sh-install systemd path is now LEGACY, reachable only via
# the explicit --persistent opt-in; without it, add-runner directs the operator
# to the scale-set listener (the ephemeral orchestrator) instead of registering
# a long-lived service. These tests assert the default no longer touches the
# persistent path (no .runner marker written, no svc.sh install) and points at
# the ephemeral path + ADR-0001. They mirror add_runner.bats's RUNNER_HOME +
# PATH-stub style; the persistent path's own behavior stays covered there
# (now under --persistent).

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/add-runner.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

@test "add-runner.sh org default (no --persistent) points at the ephemeral scale-set path and exits 0" {
  run "${SCRIPT}" org acme
  [ "${status}" -eq 0 ]
  # The default is now ephemeral / JIT: it must name the scale-set listener and
  # the ADR, not register a persistent runner.
  [[ "${output}" == *"ephemeral"* ]]
  [[ "${output}" == *"scale set"* ]]
  [[ "${output}" == *"ADR-0001"* ]]
}

@test "add-runner.sh repo default (no --persistent) points at the ephemeral scale-set path and exits 0" {
  run "${SCRIPT}" repo acme widget
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ephemeral"* ]]
  [[ "${output}" == *"scale set"* ]]
}

@test "add-runner.sh default never registers a persistent runner (no .runner marker, no gh/tarball needed)" {
  # No tarball cache, no gh stub: the default ephemeral path must short-circuit
  # BEFORE the persistent tarball / registration steps, so it neither errors on
  # the missing tarball nor writes a .runner marker.
  run "${SCRIPT}" org acme
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"tarball missing"* ]]
  [ ! -e "${RUNNER_HOME}/acme/_org/.runner" ]
}

@test "add-runner.sh default does not invoke svc.sh / systemd (no persistent service)" {
  # Stub systemctl + sudo so that IF the script wrongly took the persistent
  # path it would be observable; the default must not call them at all.
  STUB=$(mktemp -d)
  printf '#!/bin/sh\necho "SYSTEMCTL: $*"\n' > "${STUB}/systemctl"
  printf '#!/bin/sh\necho "SUDO: $*"; exec "$@"\n' > "${STUB}/sudo"
  chmod +x "${STUB}/systemctl" "${STUB}/sudo"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" org acme
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"SUDO: install"* ]]
  [[ "${output}" != *"already configured"* ]]
}

@test "add-runner.sh --help documents both the ephemeral default and the --persistent legacy opt-in" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--persistent"* ]]
  [[ "${output}" == *"ephemeral"* ]]
}

@test "add-runner.sh --persistent still reaches the legacy persistent path (tarball pre-flight)" {
  # The opt-in must reach the persistent flow: with no tarball cache it fails
  # with the legacy "tarball missing" message (proving it did NOT take the
  # ephemeral short-circuit).
  run "${SCRIPT}" --persistent org acme
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"tarball missing"* ]]
}

@test "add-runner.sh --persistent keeps the idempotent already-configured guard" {
  # The legacy idempotency guard (.runner + active service -> already configured)
  # must still hold under the opt-in, unchanged from add_runner.bats.
  mkdir -p "${RUNNER_HOME}/testorg/_org"
  touch "${RUNNER_HOME}/testorg/_org/.runner"
  STUB=$(mktemp -d)
  cat > "${STUB}/systemctl" <<'EOF'
#!/bin/sh
echo "  actions.runner.testorg.$(hostname)-testorg-org.service loaded active running"
EOF
  chmod +x "${STUB}/systemctl"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --persistent org testorg
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already configured"* ]]
}
