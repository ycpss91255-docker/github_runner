#!/usr/bin/env bats
# Executable spec for script/lint-changelog.sh -- the changelog gate.
#
# The rule "a user-visible change carries a CHANGELOG entry" was enforced only
# by a local hook, which means a push that never ran the hook was never checked.
# PRD.md §0.4's one general rule is that a spec which cannot be checked
# automatically is equivalent to no spec at all; a spec checked only on one
# machine is the same rule half-applied.
#
# Every case is asserted from both sides -- a change that warrants an entry and
# does not have one must fail, and the same change with the entry must pass --
# because a gate that cannot say no is decoration. The lint is also asserted to
# fail LOUDLY when it cannot determine what changed, rather than reporting
# success while measuring nothing (invariant 1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LINT="${ROOT}/script/lint-changelog.sh"
  FILES="${BATS_TEST_TMPDIR}/changed"
}

# A changed-file list, one path per line, as the lint reads it.
write_files() {
  printf '%s\n' "$@" >"${FILES}"
}

@test "a change under script/ without a changelog entry fails, naming the file" {
  write_files "script/add-runner.sh" "lib/common.sh"
  run bash "${LINT}" --files-from "${FILES}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/add-runner.sh"* ]]
  [[ "${output}" == *"CHANGELOG"* ]]
}

@test "the same change passes once the changelog entry is part of it" {
  write_files "script/add-runner.sh" "lib/common.sh" "doc/changelog/CHANGELOG.md"
  run bash "${LINT}" --files-from "${FILES}"
  [ "${status}" -eq 0 ]
}

@test "a documentation-only change needs no entry" {
  # The changelog answers "what changed that users can see". Rewording a
  # document is not that, and a gate that fires on it teaches people to bypass
  # the gate.
  write_files "doc/PRD.md" "README.md" "doc/adr/0001-ephemeral-jit-runners.md"
  run bash "${LINT}" --files-from "${FILES}"
  [ "${status}" -eq 0 ]
}

@test "a test-only change needs no entry" {
  write_files "test/bats/unit/common.bats" "test/bats/integration/status.bats"
  run bash "${LINT}" --files-from "${FILES}"
  [ "${status}" -eq 0 ]
}

@test "repo metadata alone needs no entry" {
  write_files ".gitignore" "LICENSE" "skills-lock.json"
  run bash "${LINT}" --files-from "${FILES}"
  [ "${status}" -eq 0 ]
}

@test "an empty change set passes rather than erroring" {
  : >"${FILES}"
  run bash "${LINT}" --files-from "${FILES}"
  [ "${status}" -eq 0 ]
}

@test "the workflow and the recipes count as changes that warrant an entry" {
  # How the project is built and gated is user-visible for anyone running it.
  write_files "justfile"
  run bash "${LINT}" --files-from "${FILES}"
  [ "${status}" -ne 0 ]
  write_files ".github/workflows/ci.yaml"
  run bash "${LINT}" --files-from "${FILES}"
  [ "${status}" -ne 0 ]
}

@test "a base ref that cannot be resolved fails loudly instead of passing on nothing" {
  run bash "${LINT}" --base no/such/ref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no/such/ref"* ]]
}

@test "an unknown option is refused rather than silently doing nothing" {
  run bash "${LINT}" --wat
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"usage"* || "${output}" == *"unknown"* ]]
}

@test "over a real branch it reads the range, and both sides hold" {
  # The --files-from cases above pin the classification; this one pins that the
  # default path actually derives the same list from git, so the two cannot
  # drift apart.
  local repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${repo}/script" "${repo}/doc/changelog"
  git -C "${repo}" init -q -b main
  git -C "${repo}" config user.email t@example.com
  git -C "${repo}" config user.name t
  echo base >"${repo}/script/a.sh"
  echo "# Changelog" >"${repo}/doc/changelog/CHANGELOG.md"
  git -C "${repo}" add -A
  git -C "${repo}" commit -q -m base

  git -C "${repo}" checkout -q -b feature
  echo changed >>"${repo}/script/a.sh"
  git -C "${repo}" commit -q -am "change a script"
  run bash -c "cd '${repo}' && bash '${LINT}' --base main"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/a.sh"* ]]

  echo "- something" >>"${repo}/doc/changelog/CHANGELOG.md"
  git -C "${repo}" commit -q -am "note it"
  run bash -c "cd '${repo}' && bash '${LINT}' --base main"
  [ "${status}" -eq 0 ]
}
