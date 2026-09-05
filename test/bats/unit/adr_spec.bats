#!/usr/bin/env bats
# Executable spec for the ADR structure lint (script/lint-adr.sh) that PRD.md
# §0.5 requires ("a structural lint must exist -- discipline does not count").
# Two halves:
#   1. the repo's real doc/adr/ passes the lint (the spec holds today);
#   2. a deliberately broken fixture fails it, rule by rule (the lint has teeth).
# Pure file assertions -- no repo state, no gh, no docker.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LINT="${ROOT}/script/lint-adr.sh"
  FIXTURE="${BATS_TEST_TMPDIR}/adr"
  ADR="${FIXTURE}/0009-a-conforming-record.md"
  mkdir -p "${FIXTURE}"
}

# A minimal, fully conforming ADR. Tests copy it and break exactly one rule, so
# a failure names the rule under test rather than "the fixture is malformed".
# The back-pointer names a real PRD §0.2 invariant, because the lint checks the
# title against those headings.
write_valid_adr() {
  local path="${1:-${ADR}}"
  cat >"${path}" <<'EOF'
# 0009 — A conforming record

> Serves: Invariant 3 — One source of truth; no copies maintained in parallel

- **Status**: Accepted
- **Date**: 2026-09-05

## Context

Why.

## Decision

What.

## Alternatives

- Something else. Rejected because of a stated reason.

## Consequences

So what, including the bad parts.
EOF
}

# Drop one line from the fixture, keeping it the only record in the dir.
drop_line() {
  local pattern="$1" renamed="${FIXTURE}/0010-broken.md"
  grep -v -- "${pattern}" "${ADR}" >"${renamed}"
  rm "${ADR}"
}

@test "the ADR lint script exists and is executable" {
  [ -x "${LINT}" ]
}

@test "every ADR in doc/adr/ conforms to the ADR spec (PRD.md §0.5)" {
  run "${LINT}" "${ROOT}/doc/adr"
  [ "${status}" -eq 0 ]
}

@test "a conforming ADR passes" {
  write_valid_adr
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 0 ]
}

@test "a missing '> Serves:' back-pointer fails" {
  write_valid_adr
  drop_line '^> Serves:'
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Serves"* ]]
}

@test "the mechanism form of the back-pointer is accepted verbatim" {
  write_valid_adr
  sed -i 's/^> Serves: .*$/> Serves: mechanism, no corresponding invariant/' "${ADR}"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 0 ]
}

@test "a back-pointer outside the two permitted forms fails" {
  write_valid_adr
  sed -i 's/^> Serves: .*$/> Serves: the general good/' "${ADR}"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"permitted back-pointer"* ]]
}

@test "a back-pointer naming an invariant title that is not in PRD.md §0.2 fails" {
  write_valid_adr
  sed -i 's/^> Serves: .*$/> Serves: Invariant 3 — One source of truth, roughly/' "${ADR}"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"is not an invariant heading"* ]]
}

@test "a back-pointer buried below the first section heading does not count" {
  write_valid_adr
  drop_line '^> Serves:'
  printf '\n> Serves: Invariant 1 — Never fail silently\n' >>"${FIXTURE}/0010-broken.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Serves"* ]]
}

@test "each of the four required sections is required" {
  local section
  for section in '## Context' '## Decision' '## Alternatives' '## Consequences'; do
    rm -f "${FIXTURE}"/*.md
    write_valid_adr
    drop_line "^${section}\$"
    run "${LINT}" "${FIXTURE}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${section}"* ]]
  done
}

@test "a duplicated required section fails" {
  write_valid_adr
  printf '\n## Decision\n\nAgain.\n' >>"${ADR}"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"## Decision"* ]]
}

@test "a free-text Status fails" {
  write_valid_adr
  sed -i 's/^- \*\*Status\*\*: Accepted$/- **Status**: accepted — mostly/' "${ADR}"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Status"* ]]
}

@test "the five permitted Status values are accepted" {
  local value
  for value in "Proposed" "Accepted" "Amended (2026-06-29, #154)" \
    "Superseded by ADR-0009" "Rejected"; do
    rm -f "${FIXTURE}"/*.md
    write_valid_adr
    sed -i "s/^- \*\*Status\*\*: Accepted\$/- **Status**: ${value}/" "${ADR}"
    run "${LINT}" "${FIXTURE}"
    [ "${status}" -eq 0 ]
  done
}

@test "a 'Superseded by' pointing at a record that does not exist fails" {
  write_valid_adr
  sed -i 's/^- \*\*Status\*\*: Accepted$/- **Status**: Superseded by ADR-0042/' "${ADR}"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ADR-0042"* ]]
}

@test "a filename off the 4-digit numbering pattern fails" {
  write_valid_adr "${FIXTURE}/not-an-adr.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"filename"* ]]
}

@test "two records sharing one ADR number fails (numbers are never reused)" {
  write_valid_adr
  write_valid_adr "${FIXTURE}/0009-a-second-claim-on-the-number.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"already used"* ]]
}

@test "README.md in doc/adr is exempt from the record rules" {
  write_valid_adr
  printf '# ADR index\n\nJust a listing.\n' >"${FIXTURE}/README.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"README.md"* ]]
}
