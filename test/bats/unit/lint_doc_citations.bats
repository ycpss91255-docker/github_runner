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

# doc/arch/ is an HTML directory by convention (it mirrors the base repo's
# `overview.html`), and the collector took `doc/**/*.md` only -- so the one
# document class most prone to this defect was the class the rule did not see.
# An architecture overview describes module layouts, flow steps and category
# lists, all of which drift as code changes, silently, because prose does not
# fail a build.
#
# The HTML analogue of a fenced block is the non-prose element: <style>,
# <script>, <svg> (full of coordinate digits), and <pre>. Inline <code> is
# stripped the way URLs already are, rather than skipping the whole line.

@test "an HTML document under doc/ is scanned at all" {
  printf '<p>See the guard in lib/common.sh:142 for the detail.</p>\n' \
    >"${FAKE}/doc/arch.html"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"doc/arch.html"* ]]
  [[ "${output}" == *"lib/common.sh:142"* ]]
}

@test "the HTML document count is reported, not silently zero" {
  printf '<p>Nothing wrong here.</p>\n' >"${FAKE}/doc/arch.html"
  printf 'Nothing wrong here either.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2 document"* ]]
}

@test "digits inside an inline SVG are not read as citations" {
  cat >"${FAKE}/doc/arch.html" <<'HTML'
<figure>
<svg viewBox="0 0 880 320">
  <rect x="20" y="8" width="840" height="68"/>
  <text x="50" y="30">four layers</text>
</svg>
<figcaption>The topology.</figcaption>
</figure>
HTML
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "a <style> block is not scanned" {
  cat >"${FAKE}/doc/arch.html" <<'HTML'
<style>
body { margin: 0 0 0 0; }
.x { padding: 0.45rem 0.7rem; }
</style>
<p>Plain prose.</p>
HTML
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "a <pre> block is not scanned, the way a fenced block is not" {
  cat >"${FAKE}/doc/arch.html" <<'HTML'
<pre>
  go tool cover reports listener/listener.go:374
</pre>
<p>Plain prose.</p>
HTML
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "a citation in a figcaption still fails -- that is prose" {
  cat >"${FAKE}/doc/arch.html" <<'HTML'
<figure>
<svg viewBox="0 0 880 100"><rect x="1" y="2"/></svg>
<figcaption>The gate lives in lib/common.sh:138.</figcaption>
</figure>
HTML
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"lib/common.sh:138"* ]]
}

@test "inline <code> is stripped, so a path inside it is not a citation" {
  printf '<p>The gate is <code>assert_under_runner_home</code> in common.sh:138.</p>\n' \
    >"${FAKE}/doc/arch.html"
  run bash "${LINT}" "${FAKE}"
  # The bare citation outside the code span must still be caught.
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"common.sh:138"* ]]
}

# The COUNT rule's reach over HTML is narrow, and saying so here keeps the next
# reader from assuming this lint guards more than it does. COUNT_RE matches a
# number before a short, deliberately fixed list of English plural nouns, so it
# fires on "four jobs" but not on "23 hooks" and not on any zh-TW counting
# phrase -- and doc/arch/ prose is zh-TW. Widening it was considered and
# rejected: a rule cannot tell "four boundary layers", which describes the
# figure directly above it and changes with that figure, from "five categories
# of leftovers", which restates a list the code owns. That judgement stays with
# the reviewer; extending the collector buys the CITATION half mechanically.
@test "the count rule does not reach zh-TW counting phrases, by design" {
  printf '<p>Cleanup 清理五類殘留。</p>\n' >"${FAKE}/doc/arch.html"
  printf 'Nothing wrong here.\n' >"${DOC}"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "the count rule still fires on the English nouns it names" {
  printf '<p>There are four jobs in the gate.</p>\n' >"${FAKE}/doc/arch.html"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"hardcoded count"* ]]
}
