#!/usr/bin/env bats
# Executable spec for the ADR structure lint (script/lint-adr.sh): the adopted
# ADR spec says self-discipline does not count, so every rule it states has to
# be machine-checked. Two halves:
#   1. the repo's real doc/adr/ passes the lint (the spec holds today);
#   2. a deliberately broken fixture fails it, rule by rule (the lint has teeth).
# Pure file assertions -- no repo state, no gh, no docker.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  LINT="${ROOT}/script/lint-adr.sh"
  FIXTURE="${BATS_TEST_TMPDIR}/adr"
  mkdir -p "${FIXTURE}"
}

# A minimal, fully conforming ADR. Tests copy it and break exactly one rule, so
# a failure names the rule under test rather than "the fixture is malformed".
write_valid_adr() {
  local path="$1"
  cat >"${path}" <<'EOF'
# 0009 — A conforming record

> Serves: Invariant 3 (One source of truth, no parallel copies) — the fixture.

- **Status**: Accepted
- **Date**: 2026-09-05

## Context

Why.

## Decision

What.

## Alternatives

- Something else. Rejected.

## Consequences

So what.
EOF
}

@test "the ADR lint script exists and is executable" {
  [ -x "${LINT}" ]
}

@test "every ADR in doc/adr/ conforms to the ADR spec" {
  run "${LINT}" "${ROOT}/doc/adr"
  [ "${status}" -eq 0 ]
}

@test "a conforming ADR passes" {
  write_valid_adr "${FIXTURE}/0009-a-conforming-record.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 0 ]
}

@test "a missing '> Serves:' back-pointer fails" {
  write_valid_adr "${FIXTURE}/0009-a-conforming-record.md"
  grep -v '^> Serves:' "${FIXTURE}/0009-a-conforming-record.md" \
    >"${FIXTURE}/0010-no-back-pointer.md"
  rm "${FIXTURE}/0009-a-conforming-record.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Serves"* ]]
}

@test "a missing required section fails" {
  write_valid_adr "${FIXTURE}/0009-a-conforming-record.md"
  grep -v '^## Consequences$' "${FIXTURE}/0009-a-conforming-record.md" \
    >"${FIXTURE}/0010-no-consequences.md"
  rm "${FIXTURE}/0009-a-conforming-record.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"## Consequences"* ]]
}

@test "a duplicated required section fails" {
  write_valid_adr "${FIXTURE}/0009-a-conforming-record.md"
  printf '\n## Decision\n\nAgain.\n' >>"${FIXTURE}/0009-a-conforming-record.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"## Decision"* ]]
}

@test "a missing '## Alternatives' warns but does not fail" {
  write_valid_adr "${FIXTURE}/0009-a-conforming-record.md"
  grep -v '^## Alternatives$' "${FIXTURE}/0009-a-conforming-record.md" \
    >"${FIXTURE}/0010-no-alternatives.md"
  rm "${FIXTURE}/0009-a-conforming-record.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"WARN"* ]]
  [[ "${output}" == *"## Alternatives"* ]]
}

@test "a free-text Status fails" {
  write_valid_adr "${FIXTURE}/0009-a-conforming-record.md"
  sed -i 's/^- \*\*Status\*\*: Accepted$/- **Status**: accepted — mostly/' \
    "${FIXTURE}/0009-a-conforming-record.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Status"* ]]
}

@test "the allowed Status vocabulary is Accepted / Rejected / Superseded by ADR-NNNN" {
  local status_value
  for status_value in "Accepted" "Rejected" "Superseded by ADR-0042"; do
    write_valid_adr "${FIXTURE}/0009-a-conforming-record.md"
    sed -i "s/^- \*\*Status\*\*: Accepted\$/- **Status**: ${status_value}/" \
      "${FIXTURE}/0009-a-conforming-record.md"
    run "${LINT}" "${FIXTURE}"
    [ "${status}" -eq 0 ]
  done
}

@test "a filename off the 4-digit numbering pattern fails" {
  write_valid_adr "${FIXTURE}/not-an-adr.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"filename"* ]]
}

@test "README.md in doc/adr is exempt from the record rules" {
  write_valid_adr "${FIXTURE}/0009-a-conforming-record.md"
  printf '# ADR index\n\nJust a listing.\n' >"${FIXTURE}/README.md"
  run "${LINT}" "${FIXTURE}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"README.md"* ]]
}
