#!/usr/bin/env bats
# Static invariants of the self-hosted smoke workflow. This is the only workflow
# in the repo that executes on a self-hosted runner, which makes its trigger set
# a security boundary rather than a preference: `pull_request` fires for forks,
# so a push to someone else's fork would run their code on the runner host --
# and docker-group membership there is root-equivalent (#81).
#
# These are tripwires, not formalities. Each must fail the moment the property
# it guards is removed, so that widening the trigger set or unpinning an action
# is a deliberate reviewed act instead of an edit nobody noticed.

setup() {
  WF="${BATS_TEST_DIRNAME}/../../../.github/workflows/selfhosted-smoke.yaml"
}

@test "the self-hosted smoke workflow exists" {
  [ -f "${WF}" ]
}

@test "self-hosted smoke is dispatch-only: no push or pull_request trigger" {
  [ -f "${WF}" ]
  # Read the trigger block only (`on:` up to the next top-level key), so the
  # word "push" appearing in a step's prose or script cannot mask a real
  # trigger, nor fake one.
  run bash -c "sed -n '/^on:/,/^[a-z]/p' '${WF}' | grep -E '^[[:space:]]+(push|pull_request|pull_request_target):'"
  [ "${status}" -ne 0 ]
}

@test "self-hosted smoke declares workflow_dispatch" {
  run bash -c "sed -n '/^on:/,/^[a-z]/p' '${WF}' | grep -E '^[[:space:]]+workflow_dispatch:'"
  [ "${status}" -eq 0 ]
}

@test "self-hosted smoke runs on a self-hosted label set" {
  run grep -E '^[[:space:]]+runs-on:' "${WF}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"runs_on"* || "${output}" == *"self-hosted"* ]]
}

@test "self-hosted smoke pins every action by commit sha, never a tag" {
  [ -f "${WF}" ]
  # Every `uses:` must name a 40-hex commit. A floating tag on the one workflow
  # that runs on our own hardware is a supply-chain hole, and the rest of the
  # repo's workflows already pin by sha.
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ @[0-9a-f]{40}([[:space:]]|$) ]] || {
      echo "unpinned action: ${line}"
      return 1
    }
  done < <(grep -E '^[[:space:]]+(-[[:space:]]+)?uses:' "${WF}" || true)
}

@test "self-hosted smoke requests no more than read permission" {
  run grep -E '^[[:space:]]*contents:[[:space:]]*read' "${WF}"
  [ "${status}" -eq 0 ]
  # And nothing grants write anywhere in the file.
  run grep -E ':[[:space:]]*write' "${WF}"
  [ "${status}" -ne 0 ]
}

@test "self-hosted smoke bounds its runtime so a hung job cannot hold the runner" {
  run grep -E '^[[:space:]]+timeout-minutes:[[:space:]]*[0-9]+' "${WF}"
  [ "${status}" -eq 0 ]
}
