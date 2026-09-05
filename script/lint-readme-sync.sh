#!/usr/bin/env bash
# Four-language README structure gate.
#
# PRD.md §0.7 gives README.md and its three translations one job -- "what is
# this, how do I install and use it" -- and requires the four-language
# structure to stay aligned. A reader who picks a language must not get a
# different document: a section that exists in one language and not the others
# is not a translation gap, it is three readers being told less.
#
# That rule was enforced only by a local hook that watched what was staged. A
# hook sees a partial update only on the machine running it, and a partial
# update that arrives across two commits is invisible to it entirely. This
# reads the tree instead, so it judges the state the repository is actually in.
#
# WHAT IS COMPARED, AND WHY NOT MORE. Two structural signatures per file:
#
#   * the sequence of heading levels, outside fenced code blocks;
#   * the number of fenced code blocks.
#
# Not the heading text: the headings are translated, so comparing text would
# fail on every file by design. Not the prose: translations are not required to
# be line-for-line, and demanding that would produce red that says nothing.
# Heading LEVELS plus code-block count is the part that carries the document's
# shape, which is the part a partial update breaks.
#
# Fenced blocks are excluded from the heading scan because every one of these
# READMEs shows shell snippets whose comments begin with '#'. Counting those as
# headings would turn a translated comment into a structural divergence -- a
# red gate on a file nobody touched, which is the fastest way to teach people
# to ignore it.
#
# Exits non-zero on any divergence and on a missing file: a gate that skips
# what it cannot find reports success while checking less than it claims
# (invariant 1).
#
# Usage:
#   script/lint-readme-sync.sh [<repo-root>]     # default: the repo root
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly DEFAULT_ROOT="${SCRIPT_DIR}/.."

# README.md is the reference; the others are compared against it. It is first
# in the list for that reason, not because it is more authoritative as prose.
readonly READMES=(
  'README.md'
  'doc/readme/README.zh-TW.md'
  'doc/readme/README.zh-CN.md'
  'doc/readme/README.ja.md'
)

usage() {
  cat >&2 <<'EOF'
usage:
  script/lint-readme-sync.sh [<repo-root>]

Fails when README.md and the three translations under doc/readme/ diverge in
structure: the sequence of heading levels outside fenced code blocks, or the
number of fenced code blocks. Heading TEXT is not compared -- it is translated.
EOF
}

# The structure signature of a markdown file, one token per line:
#   h<N>    a heading at level N, outside any fenced code block
#   fence   a fenced code block
# Emitted in document order, so a diff of two signatures points at the first
# place the documents stop having the same shape.
#
# The heading test is spelled out rather than written as /^#{1,6}[[:space:]]/
# because the coverage run uses a different awk, and an interval expression
# there matches nothing at all -- which would make every signature empty, every
# file "aligned", and the gate silently useless in exactly the run that is
# supposed to be the strictest.
signature() {
  awk '
    /^[[:space:]]*(```|~~~)/ {
      if (in_fence) { in_fence = 0 } else { in_fence = 1; print "fence" }
      next
    }
    in_fence { next }
    /^#/ {
      match($0, /^#+/)
      if (RLENGTH <= 6 && substr($0, RLENGTH + 1, 1) ~ /[ \t]/) print "h" RLENGTH
    }
  ' "$1"
}

# Report the first structural difference in terms a reader can act on: the
# heading each side has at that point, not an opaque token index.
report_divergence() {
  local root=$1 reference=$2 other=$3
  echo "FAIL: ${other} is structurally out of sync with ${reference}" >&2
  echo "      headings (outside code fences), reference first:" >&2
  diff -u \
    <(grep -nE '^#{1,6}[[:space:]]' "${root}/${reference}" || true) \
    <(grep -nE '^#{1,6}[[:space:]]' "${root}/${other}" || true) \
    | sed 's/^/        /' >&2 || true
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

  local failures=0 rel
  for rel in "${READMES[@]}"; do
    if [[ ! -f "${root}/${rel}" ]]; then
      echo "FAIL: missing ${rel} -- the four-language set is incomplete" >&2
      failures=$((failures + 1))
    fi
  done
  (( failures == 0 )) || return 1

  local reference="${READMES[0]}" reference_sig other_sig
  reference_sig=$(signature "${root}/${reference}")

  for rel in "${READMES[@]:1}"; do
    other_sig=$(signature "${root}/${rel}")
    if [[ "${other_sig}" != "${reference_sig}" ]]; then
      report_divergence "${root}" "${reference}" "${rel}"
      failures=$((failures + 1))
    fi
  done

  if (( failures > 0 )); then
    echo "README sync: ${failures} of ${#READMES[@]} language(s) out of sync with ${reference}" >&2
    return 1
  fi
  echo "README sync: ${#READMES[@]} languages structurally aligned"
}

main "$@"
