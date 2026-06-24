#!/usr/bin/env bats
# Smoke tests for add-runner.sh argument parsing and the LEGACY persistent
# (config.sh-once + svc.sh-install) path. Since ADR-0001 Phase 5 the persistent
# flow is reached only via the explicit --persistent opt-in (the default is now
# the ephemeral / JIT scale-set path, covered in add_runner_ephemeral.bats), so
# every test that exercises register / service behavior passes --persistent.

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
  [[ "${output}" == *"Provision a self-hosted runner"* ]]
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

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --persistent org testorg
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

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --persistent org testorg
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"already configured"* ]]
  [[ "${output}" == *"registered but its service is missing"* ]]
  [[ "${output}" == *"SVC: install"* ]]
  [[ "${output}" == *"SVC: start"* ]]
}

@test "add-runner.sh --persistent fresh run without tarball cache exits non-zero" {
  # No .runner exists -> proceeds to tarball check -> fails because no cache
  run "${SCRIPT}" --persistent org someorg
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
  # require_gh_auth + the token fetch (which run 'command gh') pass first, and
  # reports a safe fork-PR gate so the #48 pre-flight does not short-circuit
  # before extraction.
  mkdir -p "${RUNNER_HOME}/.bin"
  printf 'not-a-real-gzip' > "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"
  STUB=$(mktemp -d)
  cat > "${STUB}/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *fork-pr-contributor-approval*) echo "all_external_contributors" ;;
  *) printf 'TOKEN\n' ;;
esac
EOF
  chmod +x "${STUB}/gh"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --persistent org myorg
  rm -rf "${STUB}"
  [ "${status}" -ne 0 ]
  [ ! -e "${RUNNER_HOME}/myorg/_org" ]
}

@test "add-runner.sh org refuses to register when the fork-PR approval gate is weak (#48)" {
  # The org path would enable public-repo dispatch (lowering GitHub's safe
  # default). When the complementary fork-PR approval gate is NOT
  # 'all_external_contributors', add-runner must refuse BEFORE registering --
  # never lowering one knob without the other.
  mkdir -p "${RUNNER_HOME}/.bin"
  printf 'cached' > "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"
  STUB=$(mktemp -d)
  cat > "${STUB}/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *"auth status"*)                exit 0 ;;
  *fork-pr-contributor-approval*) echo "none" ;;
  *)                              echo "TOKEN" ;;
esac
EOF
  chmod +x "${STUB}/gh"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --persistent org myorg
  rm -rf "${STUB}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"refusing to register"* ]]
  [[ "${output}" == *"all_external_contributors"* ]]
  # Refused before registering -> no runner dir created.
  [ ! -e "${RUNNER_HOME}/myorg/_org" ]
}

@test "add-runner.sh --force registers despite a weak gate and warns on dispatch-enable failure (#48/#51)" {
  # --force bypasses the #48 refusal. The runner registers + the service comes
  # up; the public-repo dispatch PATCH then fails, which #51 must downgrade to
  # a warning (not abort) since the runner is already online. We also expect
  # the --force exposure warning.
  mkdir -p "${RUNNER_HOME}/.bin"
  printf 'cached' > "${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"
  STUB=$(mktemp -d)
  # gh: auth ok; weak gate; token ok; the runner-groups PATCH fails (#51 path).
  cat > "${STUB}/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *"auth status"*)                exit 0 ;;
  *fork-pr-contributor-approval*) echo "first_time_contributors" ;;
  *registration-token*)           echo "TOKEN" ;;
  *runner-groups*)                exit 1 ;;
  *)                              exit 0 ;;
esac
EOF
  # sudo passes through to its args so the bundled svc.sh runs.
  printf '#!/bin/sh\nexec "$@"\n' > "${STUB}/sudo"
  # tar is stubbed (busybox lacks GNU options): drop a config.sh that writes
  # the .runner marker and a no-op svc.sh into the extraction target.
  cat > "${STUB}/tar" <<'EOF'
#!/bin/sh
d=""
while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { shift; d="$1"; }; shift; done
if [ -n "$d" ]; then
  printf '#!/bin/sh\ntouch .runner\nexit 0\n' > "$d/config.sh"
  printf '#!/bin/sh\nexit 0\n' > "$d/svc.sh"
  chmod +x "$d/config.sh" "$d/svc.sh"
fi
exit 0
EOF
  chmod +x "${STUB}/gh" "${STUB}/sudo" "${STUB}/tar"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --persistent --force org myorg
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"registered:"* ]]
  [[ "${output}" == *"any fork PR can dispatch"* ]]
  [[ "${output}" == *"enabling org public-repo dispatch failed"* ]]
  [ -f "${RUNNER_HOME}/myorg/_org/.runner" ]
}
