#!/usr/bin/env bats
# Smoke tests for remove-runner.sh.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../script/remove-runner.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

@test "remove-runner.sh with no args exits non-zero" {
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
}

@test "remove-runner.sh org without org name exits non-zero" {
  run "${SCRIPT}" org
  [ "${status}" -ne 0 ]
}

@test "remove-runner.sh no-op when no runner exists" {
  run "${SCRIPT}" org nonexistent
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"nothing to remove"* ]]
}

@test "remove-runner.sh --help prints Usage and exits 0" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

# --- preview + confirmation gate ----------------------------------------
# remove-runner.sh is destructive on its own (deregister + service uninstall
# + rm -rf the runner dir), so it carries the same preview/confirm contract
# as uninstall.sh and cleanup.sh instead of relying on the aggregate path.

# Lay down a fake org runner with the bundled scripts remove-runner.sh drives.
# Echoes the runner dir.
_fake_org_runner() {
  local dir="${FAKE_RH}/$1/_org"
  mkdir -p "${dir}"
  touch "${dir}/.runner"
  printf '#!/bin/sh\nexit 0\n' >"${dir}/svc.sh"
  printf '#!/bin/sh\nexit 0\n' >"${dir}/config.sh"
  chmod +x "${dir}/svc.sh" "${dir}/config.sh"
  printf '%s\n' "${dir}"
}

# PATH stubs: gh never reaches the network (auth ok, remove-token canned),
# sudo passes through to its args so the bundled svc.sh actually runs.
# Echoes the stub dir.
_stub_bin() {
  local stub
  stub=$(mktemp -d)
  cat >"${stub}/gh" <<'EOF'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)  echo faketoken ;;
esac
EOF
  printf '#!/bin/sh\nexec "$@"\n' >"${stub}/sudo"
  chmod +x "${stub}/gh" "${stub}/sudo"
  printf '%s\n' "${stub}"
}

@test "remove-runner.sh --help documents --dry-run and --yes" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--dry-run"* ]]
  [[ "${output}" == *"--yes"* ]]
}

@test "remove-runner.sh --dry-run prints the plan and removes nothing" {
  local dir
  dir=$(_fake_org_runner myorg)

  run "${SCRIPT}" --dry-run org myorg
  [ "${status}" -eq 0 ]
  # Names the target, the deregistration, the service uninstall, and the dir.
  [[ "${output}" == *"myorg"* ]]
  [[ "${output}" == *"eregister"* ]]
  [[ "${output}" == *"ervice"* ]]
  [[ "${output}" == *"${dir}"* ]]
  [[ "${output}" == *"Dry-run; nothing removed."* ]]

  # Untouched.
  [ -f "${dir}/.runner" ]
}

@test "remove-runner.sh -n is the short form of --dry-run" {
  local dir
  dir=$(_fake_org_runner myorg)

  run "${SCRIPT}" -n org myorg
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Dry-run; nothing removed."* ]]
  [ -f "${dir}/.runner" ]
}

@test "remove-runner.sh without --yes in non-TTY context exits 1 and removes nothing" {
  local dir
  dir=$(_fake_org_runner myorg)

  # bats's run inherits a non-TTY stdin, which is exactly the path under test.
  run "${SCRIPT}" org myorg
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"non-interactive run requires --yes"* ]]

  # Untouched.
  [ -f "${dir}/.runner" ]
}

@test "remove-runner.sh --yes proceeds without prompting and removes the dir" {
  local dir stub
  dir=$(_fake_org_runner myorg)
  stub=$(_stub_bin)

  run env PATH="${stub}:${PATH}" "${SCRIPT}" --yes org myorg
  rm -rf "${stub}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"removed:"* ]]
  [[ "${output}" != *"non-interactive run requires --yes"* ]]
  [ ! -e "${dir}" ]
}

@test "remove-runner.sh -y is the short form of --yes" {
  local dir stub
  dir=$(_fake_org_runner myorg)
  stub=$(_stub_bin)

  run env PATH="${stub}:${PATH}" "${SCRIPT}" -y org myorg
  rm -rf "${stub}"
  [ "${status}" -eq 0 ]
  [ ! -e "${dir}" ]
}

@test "remove-runner.sh --dry-run on a missing runner is still the no-op path" {
  run "${SCRIPT}" --dry-run org nonexistent
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"nothing to remove"* ]]
}

@test "remove-runner.sh --runner-home still wins over the env var with the new flags" {
  local alt dir
  alt=$(mktemp -d)
  mkdir -p "${alt}/myorg/_org"
  touch "${alt}/myorg/_org/.runner"
  dir=$(_fake_org_runner myorg)

  run "${SCRIPT}" --dry-run --runner-home "${alt}" org myorg
  rm -rf "${alt}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${alt}/myorg/_org"* ]]
  [[ "${output}" != *"${dir}"* ]]
}

# M4: a bogus scope must hit the script's own validation and print the rich
# usage() (not resolve_target's terse one-line arity error) before exiting 1.
@test "remove-runner.sh with a bogus scope prints the rich usage and exits 1" {
  run "${SCRIPT}" bogus foo
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Usage:"* ]]
}
