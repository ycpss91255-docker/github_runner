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

@test "add-runner.sh with bogus scope prints the rich usage and exits 1 (M4)" {
  # The up-front scope check must reject anything that is not org|repo BEFORE
  # forwarding "$@" into resolve_target, emitting this script's own usage()
  # (not resolve_target's terse one-liner).
  run "${SCRIPT}" bogus whatever
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Usage:"* ]]
  [[ "${output}" == *"Register a new self-hosted runner"* ]]
}

@test "add-runner.sh org without org name exits non-zero" {
  run "${SCRIPT}" org
  [ "${status}" -ne 0 ]
}

@test "add-runner.sh idempotent: existing .runner + active service -> exit 0 with already-configured message" {
  mkdir -p "${RUNNER_HOME}/testorg/_org"
  touch "${RUNNER_HOME}/testorg/_org/.runner"

  # Stub systemctl so runner_service_running reports the runner's unit active;
  # only then is "already configured" the correct outcome. The unit name is
  # actions.runner.<url-slug>.<TARGET_NAME>.service, TARGET_NAME being
  # "$(hostname)-testorg-org".
  STUB=$(mktemp -d)
  cat > "${STUB}/systemctl" <<'EOF'
#!/bin/sh
echo "  actions.runner.testorg.$(hostname)-testorg-org.service loaded active running"
EOF
  chmod +x "${STUB}/systemctl"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" org testorg
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already configured"* ]]
}

@test "add-runner.sh registered but no service -> (re)installs instead of false already-configured (ERR-trap/state gap)" {
  # .runner exists (registered) but the systemd service is absent: a prior
  # run's `sudo ./svc.sh install/start` failed after config.sh wrote .runner.
  # The guard must NOT report "already configured"; it must (re)run the
  # service-install/start steps to converge.
  mkdir -p "${RUNNER_HOME}/testorg/_org"
  touch "${RUNNER_HOME}/testorg/_org/.runner"
  # Stub svc.sh inside TARGET_DIR so the (re)install steps are observable.
  cat > "${RUNNER_HOME}/testorg/_org/svc.sh" <<'EOF'
#!/bin/sh
echo "SVC: $*"
EOF
  chmod +x "${RUNNER_HOME}/testorg/_org/svc.sh"

  # PATH stubs: systemctl reports an unrelated unit (runner_service_running
  # -> not running), sudo passes through to its args so svc.sh actually runs.
  STUB=$(mktemp -d)
  cat > "${STUB}/systemctl" <<'EOF'
#!/bin/sh
echo "  ssh.service loaded active running"
EOF
  cat > "${STUB}/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
  chmod +x "${STUB}/systemctl" "${STUB}/sudo"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" org testorg
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"already configured"* ]]
  [[ "${output}" == *"registered but its service is missing"* ]]
  [[ "${output}" == *"SVC: install"* ]]
  [[ "${output}" == *"SVC: start"* ]]
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
