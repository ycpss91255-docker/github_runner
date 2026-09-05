#!/usr/bin/env bats
# Smoke tests for uninstall.sh argument parsing and the dry-run / no-op
# / non-TTY paths. Mutating paths that would actually call remove-runner.sh
# are exercised manually (see issue #11 for the design + acceptance
# criteria); here we cover the deterministic safe surface.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../script/uninstall.sh"
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

@test "uninstall.sh --yes with only the cache (zero runners) removes .bin and exits 0" {
  # No registered runners; the tarball cache is the sole target. The
  # per-runner loop never runs, so remove-runner.sh is not involved at all.
  mkdir -p "${FAKE_RH}/.bin"
  touch "${FAKE_RH}/.bin/fake-tarball.tar.gz"

  run "${SCRIPT}" --yes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Runners to deregister: 0"* ]]
  [[ "${output}" == *"[cache] ${FAKE_RH}/.bin  removed"* ]]
  [[ "${output}" == *"Summary: 0 removed, 0 failed."* ]]

  # The cache is actually gone.
  [ ! -e "${FAKE_RH}/.bin" ]
}

@test "uninstall.sh --yes forwards --yes to remove-runner.sh" {
  # remove-runner.sh now has its own confirmation gate, and uninstall.sh drives
  # it from a loop whose stdin is a here-string (never a TTY). Without an
  # explicit --yes the child would refuse, so the aggregate path must forward
  # the consent the operator already gave to uninstall.sh.
  local fake_root fake_script_dir
  fake_root=$(mktemp -d)
  fake_script_dir="${fake_root}/script"
  mkdir -p "${fake_script_dir}" "${fake_root}/lib"
  cp "${SCRIPT}" "${fake_script_dir}/uninstall.sh"
  cp "${BATS_TEST_DIRNAME}/../../../lib/"*.sh "${fake_root}/lib/"

  cat >"${fake_script_dir}/remove-runner.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"${fake_root}/args"
STUB
  chmod +x "${fake_script_dir}/remove-runner.sh"

  mkdir -p "${FAKE_RH}/myorg/_org"
  touch "${FAKE_RH}/myorg/_org/.runner"

  run "${fake_script_dir}/uninstall.sh" --yes
  [ "${status}" -eq 0 ]
  grep -qx -- '--yes' "${fake_root}/args"

  rm -rf "${fake_root}"
}

@test "uninstall.sh --yes reports a failing remove-runner.sh and exits 1" {
  # uninstall.sh resolves remove-runner.sh via its own SCRIPT_DIR
  # (readlink -f "$0"), so to inject a stub we mirror the script/ + lib/
  # layout under a temp dir and run the copy from there.
  local fake_root fake_script_dir
  fake_root=$(mktemp -d)
  fake_script_dir="${fake_root}/script"
  mkdir -p "${fake_script_dir}" "${fake_root}/lib"
  cp "${SCRIPT}" "${fake_script_dir}/uninstall.sh"
  # Mirror the whole lib/ so common.sh's `source`d siblings (runner-layout,
  # runner-service, ...) resolve under the fake root without per-file upkeep.
  cp "${BATS_TEST_DIRNAME}/../../../lib/"*.sh "${fake_root}/lib/"

  # Stub remove-runner.sh that always fails with a known exit code.
  cat >"${fake_script_dir}/remove-runner.sh" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
  chmod +x "${fake_script_dir}/remove-runner.sh"

  mkdir -p "${FAKE_RH}/myorg/_org"
  touch "${FAKE_RH}/myorg/_org/.runner"

  run "${fake_script_dir}/uninstall.sh" --yes
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"org myorg  FAILED (exit 7)"* ]]
  [[ "${output}" == *"Summary: 0 removed, 1 failed."* ]]

  rm -rf "${fake_root}"
}
