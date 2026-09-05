#!/usr/bin/env bats
# Executable spec for script/lint-doc-citations.sh -- the documentation
# citation gate.
#
# A `path/file.ext:NN` citation is a manually-maintained duplicate of something
# the tree already states. It goes stale the moment anyone inserts a line, and
# it had begun to work backwards: a comment in the justfile explained that a
# recipe sat where it did so that the line numbers cited in PRD.md would keep
# pointing at the right lines. A convention that dictates code layout has
# stopped being a documentation aid. Every such citation was removed; this gate
# is what stops them coming back.
#
# The same reasoning covers a hardcoded count of something the tree can
# enumerate -- "the five jobs above" is a second copy of the job list, and it is
# wrong the moment a job is added.
#
# The gate is deliberately conservative. Prose that merely contains a number is
# not a violation, sample tool output inside a fenced code block is not a
# violation, and an unavoidable exception takes an explicit inline marker
# rather than a weakened pattern.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LINT="${ROOT}/script/lint-doc-citations.sh"
  FAKE="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${FAKE}/doc"
  DOC="${FAKE}/doc/example.md"
}

@test "the repository's own documentation is clean" {
  run bash "${LINT}" "${ROOT}"
  [ "${status}" -eq 0 ]
}

@test "a file:line citation in prose fails, naming the document and the line" {
  printf 'See the guard in lib/common.sh:142 for the detail.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"doc/example.md"* ]]
  [[ "${output}" == *"lib/common.sh:142"* ]]
}

@test "an extensionless file gets no free pass" {
  printf 'The recipe at justfile:44 does this.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"justfile:44"* ]]
}

@test "a line-range citation fails too" {
  printf 'The block at doc/PRD.md:611-624 explains it.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
}

@test "sample tool output inside a fenced code block is not a citation" {
  # `go tool cover -func` and shellcheck both print file:line. A document that
  # shows what a tool prints is not citing a line, and failing it would make the
  # gate unusable in exactly the documents that most need examples.
  {
    printf 'Coverage prints:\n\n'
    printf '```\n'
    printf 'listener/config.go:31:\tvalidate\t100.0%%\n'
    printf '```\n'
  } >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "a URL with a port is not a citation" {
  printf 'The listener answers on http://localhost:8080 by default.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "citing a document by name and section is exactly what should be allowed" {
  printf 'See PRD.md section 0.4 and ADR-0004 for the trade-off.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "a hardcoded count of a repo artifact fails" {
  printf 'The merge gate is the five jobs above.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"five jobs"* ]]
}

@test "prose that merely contains a number is not a violation" {
  # A runner takes one job and exits; two runner classes coexist; an ADR is
  # referred to by its number. None of these is a count of something the tree
  # enumerates, and a gate that fires on them is a gate people route around.
  {
    printf 'Each ephemeral runner takes one job and exits.\n'
    printf 'ADR-0004 records the decision; PRD.md 0.4 lists the checks.\n'
    printf 'Two runner classes coexist with no code change.\n'
    printf 'The 2 verification modes are strict and best-effort.\n'
  } >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "an explicit inline marker is the escape hatch, on the same line" {
  printf 'Whether you run 5 jobs or 500. <!-- doc-lint-allow -->\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "the marker also works on the line before, for prose that must stay clean" {
  printf '<!-- doc-lint-allow -->\nWhether you run 5 jobs or 500.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "the marker does not disable the whole document" {
  printf '<!-- doc-lint-allow -->\nWhether you run 5 jobs or 500.\n\nAnd see lib/common.sh:9 too.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"lib/common.sh:9"* ]]
}

@test "the changelog is exempt from counts but not from citations" {
  # A changelog entry is a snapshot that was correct when it was written;
  # rewriting past entries to keep a count current would be inventing history.
  # A stale file:line citation in one is still a pointer that resolves nowhere.
  mkdir -p "${FAKE}/doc/changelog"
  printf 'Fixed the prereq paths for all five scripts.\n' \
    >"${FAKE}/doc/changelog/CHANGELOG.md"
  rm -f "${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]

  printf 'Fixed it in lib/common.sh:12.\n' >"${FAKE}/doc/changelog/CHANGELOG.md"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
}

@test "finding no documents at all fails instead of passing on nothing" {
  run bash "${LINT}" "${BATS_TEST_TMPDIR}/empty"
  [ "${status}" -ne 0 ]
}

@test "an unknown option is refused rather than silently doing nothing" {
  run bash "${LINT}" --wat
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"usage"* || "${output}" == *"unknown"* ]]
}
