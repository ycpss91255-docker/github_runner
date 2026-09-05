#!/usr/bin/env bash
# Documentation citation gate -- no `file:line` citations, no hardcoded counts
# of things the tree can enumerate.
#
# WHY. Invariant 3 is "one source of truth; no copies maintained in parallel".
# A `path/file.ext:NN` citation is a copy: it restates a location the tree
# already knows, it goes stale the moment anyone inserts a line above it, and
# nothing produces a signal when it does. It had also begun to work backwards
# -- a comment in the justfile explained that a recipe was placed where it was
# so that the line numbers cited in PRD.md would keep pointing at the lines they
# named. At that point the convention had stopped being a documentation aid and
# started dictating code layout. Every such citation was removed from the docs;
# this is what stops them coming back.
#
# A hardcoded count is the same defect in a different shape. "The five jobs
# above" is a second copy of the job list, and it is wrong the moment a job is
# added -- silently, because prose does not fail a build.
#
# WHAT IT DELIBERATELY DOES NOT FLAG. False positives are the failure mode that
# matters here: a lint that fires on ordinary prose is one people route around,
# and a rule people route around still produces red that everyone has been
# trained to ignore. So:
#
#   * fenced code blocks are skipped entirely -- the static analyser and
#     `go tool cover -func` both print `file:line`, and a document that shows
#     what a tool prints is not citing a line;
#   * a URL is not a citation, so a scheme-qualified host:port is skipped;
#   * a number is only a hardcoded count when it stands immediately before one
#     of a short, explicit list of repo artifacts in the plural. "One job per
#     runner" and "ADR-0004 records" are prose and stay prose;
#   * doc/changelog/CHANGELOG.md is exempt from the count rule. Its entries are
#     snapshots that were correct when written, and rewriting past entries to
#     keep a count current would be inventing history. It is NOT exempt from the
#     citation rule: a stale pointer resolves nowhere no matter how old it is.
#
# THE ESCAPE HATCH. A genuine exception carries MARKER (below) on the offending
# line or the line immediately above it. That is deliberately per-line: an
# exception should be visible where it applies, and must not silence the rest of
# the document.
#
# Exits non-zero on any violation, and when it finds no documents at all -- a
# lint that checks nothing must not report success (invariant 1).
#
# Usage:
#   script/lint-doc-citations.sh [<repo-root>]     # default: the repo root
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly DEFAULT_ROOT="${SCRIPT_DIR}/.."

readonly MARKER='<!-- doc-lint-allow -->'
readonly COUNT_EXEMPT_PATH='doc/changelog/CHANGELOG.md'

# A citation is a path ending in a source extension, or one of the
# extensionless build files, followed by ':' and a line number (optionally a
# range). The leading guard rejects a match that continues a longer token, and
# the '://' guard in the awk body rejects URLs.
# The doubled backslash is for awk: the value is passed with -v, which
# processes escape sequences once before the regex engine ever sees it.
readonly CITATION_RE='(^|[^A-Za-z0-9_/.:-])([A-Za-z0-9_./-]+\\.(md|sh|bats|go|ya?ml|json|conf|service|toml)|justfile|Makefile[A-Za-z.]*|Dockerfile[A-Za-z.]*):[0-9]+(-[0-9]+)?'

# A hardcoded count is a number immediately before one of these, in the plural.
# The list is short on purpose: every entry is something the tree enumerates, so
# a number in front of it is a second copy of a list that already exists.
readonly COUNT_RE='(^|[^A-Za-z0-9_.-])([2-9][0-9]*|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)[ -](ADRs|bats files|tests|test cases|jobs|recipes|invariants|lints|levels|scripts)([^A-Za-z]|$)'

usage() {
  cat >&2 <<'EOF'
usage:
  script/lint-doc-citations.sh [<repo-root>]

Fails when the project's own markdown documentation contains a `file.ext:NN`
citation, or a hardcoded count of something the tree enumerates. Fenced code
blocks, URLs, and lines carrying the `<!-- doc-lint-allow -->` marker (on the
line itself or the one above) are not checked.
EOF
}

# The markdown documents this project owns. Not every .md in the tree: vendored
# or generated markdown is not ours to hold to this rule.
doc_files() {
  local root=$1 rel
  for rel in README.md SECURITY.md CONTEXT.md listener/README.md; do
    [[ -f "${root}/${rel}" ]] && printf '%s\n' "${root}/${rel}"
  done
  [[ -d "${root}/doc" ]] && find "${root}/doc" -type f -name '*.md' | sort
  return 0
}

# Scan one file. Prints one line per violation and exits 1 if there were any.
scan_file() {
  local file=$1 label=$2 counts_apply=$3
  awk -v FILE="${label}" -v MARKER="${MARKER}" -v COUNTS="${counts_apply}" \
      -v CITE_RE="${CITATION_RE}" -v COUNT_RE="${COUNT_RE}" '
    function excerpt(line, s) {
      s = substr(line, RSTART, RLENGTH)
      gsub(/^[^A-Za-z0-9]+/, "", s)
      return s
    }
    # A marker on this line or the previous one exempts this line.
    function exempted(line) {
      return (index(line, MARKER) > 0) || (index(prev, MARKER) > 0)
    }
    /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; prev = $0; next }
    in_fence { prev = $0; next }
    {
      line = $0
      # URLs are not citations. Strip them before looking for one.
      probe = line
      gsub(/[A-Za-z][A-Za-z0-9+.-]*:\/\/[^[:space:])"]*/, " ", probe)

      if (!exempted(line) && match(probe, CITE_RE)) {
        printf "%s:%d: file:line citation: %s\n", FILE, NR, excerpt(probe)
        bad++
      }
      if (COUNTS == "1" && !exempted(line) && match(line, COUNT_RE)) {
        printf "%s:%d: hardcoded count: %s\n", FILE, NR, excerpt(line)
        bad++
      }
      prev = line
    }
    END { exit (bad > 0) ? 1 : 0 }
  ' "${file}"
}

main() {
  local root="${DEFAULT_ROOT}"

  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    -*) echo "unknown option: $1" >&2; usage; return 2 ;;
    "") ;;
    *) root="$1"; shift ;;
  esac
  [[ $# -eq 0 ]] || { echo "unexpected extra arguments: $*" >&2; usage; return 2; }

  local files=() file
  while IFS= read -r file; do
    [[ -n "${file}" ]] && files+=("${file}")
  done < <(doc_files "${root}")

  if (( ${#files[@]} == 0 )); then
    echo "FATAL: no project documentation found under '${root}'" >&2
    return 1
  fi

  local failures=0 label counts_apply
  for file in "${files[@]}"; do
    # Report the repo-relative path, so the message is the same everywhere.
    label="${file#"${root}"/}"
    counts_apply=1
    [[ "${label}" == "${COUNT_EXEMPT_PATH}" ]] && counts_apply=0
    scan_file "${file}" "${label}" "${counts_apply}" >&2 || failures=$((failures + 1))
  done

  if (( failures > 0 )); then
    echo "doc citation lint: ${failures} of ${#files[@]} document(s) carry a violation" >&2
    echo "      Refer to things by name, not by line. Let the tree state its own counts." >&2
    echo "      A genuine exception carries ${MARKER} on that line or the one above." >&2
    return 1
  fi
  echo "doc citation lint: ${#files[@]} document(s) checked, 0 violations"
}

main "$@"
