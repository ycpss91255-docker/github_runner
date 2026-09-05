#!/usr/bin/env bats
# Executable spec for #83: the READMEs must be self-contained and MUST NOT
# cite ADRs. The two GitHub knobs (outside-collaborator approval gate +
# allows_public_repositories) have to be explained inline instead, in every
# locale. No repo state / gh / docker -- pure file assertions on the docs.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  READMES=(
    "${ROOT}/README.md"
    "${ROOT}/doc/readme/README.zh-TW.md"
    "${ROOT}/doc/readme/README.zh-CN.md"
    "${ROOT}/doc/readme/README.ja.md"
  )
}

@test "no README cites an ADR-00xx (self-contained docs)" {
  run grep -rn "ADR-00" "${READMES[@]}"
  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
}

@test "every README explains the outside-collaborator approval gate inline" {
  for readme in "${READMES[@]}"; do
    grep -q "Require approval for all outside collaborators" "${readme}"
  done
}

@test "every README explains the allows_public_repositories knob inline" {
  for readme in "${READMES[@]}"; do
    grep -q "allows_public_repositories" "${readme}"
  done
}
