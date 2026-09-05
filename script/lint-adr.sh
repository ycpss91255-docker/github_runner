#!/usr/bin/env bash
# ADR structure lint -- the machine check behind the adopted ADR spec.
#
# The spec says self-discipline does not count: an ADR that silently drifts out
# of shape (no invariant back-pointer, a free-text Status, a missing Decision)
# is exactly the kind of quiet rot a review pass keeps missing. So every record
# under doc/adr/ is checked mechanically here, and the check runs in the gate
# (`just lint` / the `adr-lint` CI job) rather than in a reviewer's head.
#
# What is enforced, per file:
#   * filename matches the 4-digit ADR pattern (NNNN-kebab-title.md);
#     `README.md` is the one exempt file (an index, not a record)
#   * the required sections `## Context`, `## Decision`, `## Consequences`
#     appear EXACTLY once each, at column 0                        -> FAIL
#   * the recommended section `## Alternatives`                    -> WARN
#   * `- **Status**:` is exactly one of Accepted / Rejected /
#     `Superseded by ADR-NNNN`                                     -> FAIL
#   * a `> Serves:` back-pointer at line start, naming the product invariant
#     the ADR serves (or saying explicitly that it is a mechanism with no
#     corresponding invariant)                                     -> FAIL
#
# Amendments are made in place (an `**Amendment (#issue, YYYY-MM-DD):**`
# paragraph); a new ADR is opened only when a decision is overturned. That is a
# human judgement, so it is documented rather than linted.
#
# Usage:
#   script/lint-adr.sh [<adr-dir>]     # default: <repo_root>/doc/adr
#
# Exits 1 if any file fails; warnings alone keep the exit status 0.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
DEFAULT_ADR_DIR="${SCRIPT_DIR}/../doc/adr"

# The ADR spec's fixed vocabulary. Numbering is already 4-digit and compliant --
# this pattern guards it, it does not renumber anything.
ADR_FILENAME_RE='^[0-9]{4}-[a-z0-9]+(-[a-z0-9]+)*\.md$'
ADR_STATUS_RE='^(Accepted|Rejected|Superseded by ADR-[0-9]{4})$'
REQUIRED_SECTIONS=('## Context' '## Decision' '## Consequences')
RECOMMENDED_SECTION='## Alternatives'
EXEMPT_BASENAME='README.md'

failures=0
warnings=0

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [<adr-dir>]

Lints every ADR in <adr-dir> (default: doc/adr) against the ADR spec:
required sections, the Status vocabulary, and the '> Serves:' invariant
back-pointer. Exits 1 on any failure; a missing '## Alternatives' only warns.
EOF
}

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

warn() {
  echo "WARN: $*" >&2
  warnings=$((warnings + 1))
}

# Occurrences of a heading at column 0 (trailing whitespace tolerated).
heading_count() {
  local file="$1" heading="$2"
  grep -c -E "^${heading}[[:space:]]*$" "${file}" || true
}

# The Status value as written, from the first '- **Status**:' line.
adr_status() {
  local file="$1"
  sed -n 's/^- \*\*Status\*\*:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' \
    "${file}" | head -n 1
}

lint_file() {
  local file="$1"
  local base count status section
  base="$(basename "${file}")"

  if [[ ! "${base}" =~ ${ADR_FILENAME_RE} ]]; then
    fail "${file}: filename does not match the ADR pattern NNNN-kebab-title.md"
    return
  fi

  for section in "${REQUIRED_SECTIONS[@]}"; do
    count="$(heading_count "${file}" "${section}")"
    case "${count}" in
      1) ;;
      0) fail "${file}: missing required section '${section}'" ;;
      *) fail "${file}: required section '${section}' appears ${count} times (expected exactly once)" ;;
    esac
  done

  count="$(heading_count "${file}" "${RECOMMENDED_SECTION}")"
  case "${count}" in
    1) ;;
    0) warn "${file}: missing recommended section '${RECOMMENDED_SECTION}'" ;;
    *) warn "${file}: recommended section '${RECOMMENDED_SECTION}' appears ${count} times (expected at most once)" ;;
  esac

  status="$(adr_status "${file}")"
  if [[ -z "${status}" ]]; then
    fail "${file}: no '- **Status**: <value>' line"
  elif [[ ! "${status}" =~ ${ADR_STATUS_RE} ]]; then
    fail "${file}: Status '${status}' is not one of Accepted / Rejected / 'Superseded by ADR-NNNN'"
  fi

  # The back-pointer must name something: an empty '> Serves:' is not a pointer.
  if ! grep -q -E '^> Serves:[[:space:]]*[^[:space:]]' "${file}"; then
    fail "${file}: missing the '> Serves:' invariant back-pointer at line start"
  fi
}

main() {
  local adr_dir="${DEFAULT_ADR_DIR}"

  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    "") ;;
    *) adr_dir="$1"; shift ;;
  esac
  [[ $# -eq 0 ]] || { echo "unexpected extra arguments: $*" >&2; usage >&2; exit 1; }

  [[ -d "${adr_dir}" ]] || { echo "FATAL: no such ADR directory: '${adr_dir}'" >&2; exit 1; }

  local files=() file linted=0
  # Sorted, so the report reads in ADR order regardless of the shell's glob.
  while IFS= read -r file; do
    files+=("${file}")
  done < <(find "${adr_dir}" -maxdepth 1 -type f -name '*.md' | sort)

  [[ ${#files[@]} -gt 0 ]] || { echo "FATAL: no ADR files found in '${adr_dir}'" >&2; exit 1; }

  for file in "${files[@]}"; do
    if [[ "$(basename "${file}")" == "${EXEMPT_BASENAME}" ]]; then
      continue
    fi
    lint_file "${file}"
    linted=$((linted + 1))
  done

  echo "ADR lint: ${linted} file(s) checked, ${failures} failure(s), ${warnings} warning(s)"
  [[ "${failures}" -eq 0 ]] || exit 1
}

main "$@"
