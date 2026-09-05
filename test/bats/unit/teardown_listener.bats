#!/usr/bin/env bats
# Unit spec for script/teardown-listener.sh -- the reversal of the local half
# of the deploy.
#
# The project requires destructive operations to be reversible, so the one
# command that stands a machine up has a counterpart that takes it back down.
# It carries the same preview/confirm contract as the other destructive scripts
# (uninstall.sh, cleanup.sh, remove-runner.sh): print the plan, prompt, and
# refuse a non-interactive run that did not pass --yes.
#
# It deliberately does NOT delete the scale set. That lives on GitHub, is shared
# by every machine serving the runner type, and deleting it while tearing down
# ONE host would stop serving all of them.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${ROOT}/script/teardown-listener.sh"
  WORK=$(mktemp -d)
}

teardown() { rm -rf "${WORK}"; }

@test "teardown-listener.sh exists and is executable" {
  [ -x "${SCRIPT}" ]
}

@test "teardown-listener.sh --help exits 0 with usage" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage"* ]]
}

@test "teardown-listener.sh rejects an unknown option (exit 1)" {
  run "${SCRIPT}" --frobnicate
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unknown option: --frobnicate"* ]]
}

@test "teardown-listener.sh --dry-run prints the plan and removes nothing" {
  mkdir -p "${WORK}/opt/bin" "${WORK}/etc"
  : > "${WORK}/opt/bin/scaleset-listener"
  : > "${WORK}/etc/scaleset-listener.env"
  run "${SCRIPT}" --dry-run --prefix "${WORK}/opt" --etc "${WORK}/etc"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Dry run"* ]] || [[ "${output}" == *"dry-run"* ]]
  [ -f "${WORK}/opt/bin/scaleset-listener" ]
  [ -f "${WORK}/etc/scaleset-listener.env" ]
}

@test "teardown-listener.sh refuses a non-interactive run without --yes" {
  run bash -c "'${SCRIPT}' --prefix '${WORK}/opt' --etc '${WORK}/etc'" </dev/null
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a TTY"* ]] || [[ "${output}" == *"requires --yes"* ]]
}

@test "teardown-listener.sh states that it does NOT delete the scale set" {
  # The single most important thing about this teardown is what it leaves
  # alone. Deleting the scale set is a separate, explicit act.
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"scale set"* ]]
  [[ "${output}" == *"scaleset-admin delete"* ]]
}

@test "teardown-listener.sh --dry-run says the scale set is left alone" {
  run "${SCRIPT}" --dry-run --prefix "${WORK}/opt" --etc "${WORK}/etc"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"scale set"* ]]
}

@test "teardown-listener.sh has no flag that deletes the scale set" {
  # Not a default, not an opt-in: the teardown has no path to it at all, so it
  # cannot be reached by a mistyped flag on a bad day.
  run grep -F -- '--delete-scale-set' "${SCRIPT}"
  [ "${status}" -ne 0 ]
}
