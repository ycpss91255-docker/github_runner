#!/usr/bin/env bash
# ADR structure lint -- the machine check PRD.md §0.5 requires ("a structural
# lint must exist (discipline does not count)").
#
# Writing an ADR is a low-frequency action, low-frequency actions are the
# easiest place to forget the format, and the symptom of a format failure -- one
# ADR missing its `> Serves:` line -- is exactly what nobody notices. So every
# record under doc/adr/ is checked mechanically here, and the check runs in the
# gate (`just lint` / the `adr-lint` CI job) rather than in a reviewer's head.
#
# The rules are PRD.md §0.5's own list of what this lint must enforce:
#
#   * filename format -- `NNNN-kebab-case-title.md`, four digits. `README.md`
#     is the one exempt file (an index, not a record).
#   * numbering uniqueness -- no two records share an NNNN.
#   * the `> Serves:` back-pointer, one line, after the title and before
#     `## Context`, in exactly one of the two permitted forms:
#         > Serves: Invariant N — <invariant title>
#         > Serves: mechanism, no corresponding invariant
#     The invariant title is matched against the §0.2 headings in doc/PRD.md, so
#     a renamed or mistyped invariant cannot drift out of the ADRs unnoticed.
#   * the four required sections -- `## Context`, `## Decision`,
#     `## Alternatives`, `## Consequences` -- each exactly once at column 0.
#   * `Status` within the permitted set: Proposed / Accepted /
#     `Amended (YYYY-MM-DD, #NNN)` / `Superseded by ADR-NNNN` / Rejected.
#   * a `Superseded by ADR-NNNN` that points at a record which actually exists.
#
# Amend-vs-supersede (§0.5) is a human judgement about whether the decision
# itself changed, so it is documented rather than linted.
#
# Usage:
#   script/lint-adr.sh [<adr-dir>]     # default: <repo_root>/doc/adr
#
# Exits 1 if any file fails.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
DEFAULT_ADR_DIR="${SCRIPT_DIR}/../doc/adr"
# The invariant titles the `> Serves:` back-pointer must name (PRD.md §0.2).
PRD="${SCRIPT_DIR}/../doc/PRD.md"

ADR_FILENAME_RE='^([0-9]{4})-[a-z0-9]+(-[a-z0-9]+)*\.md$'
# Status, per §0.5. `Amended` carries the revision's date and issue; the
# amendment text itself lives in the file's `## Amendment` section.
ADR_STATUS_RE='^(Proposed|Accepted|Amended \([0-9]{4}-[0-9]{2}-[0-9]{2}, #[0-9]+\)|Superseded by ADR-[0-9]{4}|Rejected)$'
SERVES_INVARIANT_RE='^> Serves: (Invariant [0-9]+ — .*[^[:space:]])[[:space:]]*$'
SERVES_MECHANISM='> Serves: mechanism, no corresponding invariant'
REQUIRED_SECTIONS=('## Context' '## Decision' '## Alternatives' '## Consequences')
EXEMPT_BASENAME='README.md'

failures=0

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [<adr-dir>]

Lints every ADR in <adr-dir> (default: doc/adr) against the ADR spec in
PRD.md §0.5: the '> Serves:' back-pointer, the four required sections, the
permitted Status values, the filename / numbering rules, and that a
'Superseded by' target exists. Exits 1 on any failure.
EOF
}

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
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

# The back-pointer must sit between the title and the first section heading --
# a `> Serves:` line buried in the body is not a header back-pointer.
serves_line() {
  local file="$1"
  sed -n '/^## /q; /^> Serves:/p' "${file}"
}

check_serves() {
  local file="$1" line count invariant
  line="$(serves_line "${file}")"
  count="$(printf '%s' "${line}" | grep -c . || true)"

  if [[ "${count}" -eq 0 ]]; then
    fail "${file}: no '> Serves:' back-pointer between the title and the first section"
    return
  fi
  if [[ "${count}" -gt 1 ]]; then
    fail "${file}: ${count} '> Serves:' lines (the spec allows exactly one)"
    return
  fi

  if [[ "${line}" == "${SERVES_MECHANISM}" ]]; then
    return
  fi
  if [[ ! "${line}" =~ ${SERVES_INVARIANT_RE} ]]; then
    fail "${file}: '${line}' is not a permitted back-pointer" \
      "(expected '> Serves: Invariant N — <invariant title>' or '${SERVES_MECHANISM}')"
    return
  fi

  # One source of truth: the title must be a §0.2 heading, not a paraphrase.
  invariant="${BASH_REMATCH[1]}"
  if [[ -f "${PRD}" ]] && ! grep -q -F -x "### ${invariant}" "${PRD}"; then
    fail "${file}: '${invariant}' is not an invariant heading in $(basename "${PRD}") §0.2"
  fi
}

check_status() {
  local file="$1" adr_dir="$2" status target
  status="$(adr_status "${file}")"

  if [[ -z "${status}" ]]; then
    fail "${file}: no '- **Status**: <value>' line"
    return
  fi
  if [[ ! "${status}" =~ ${ADR_STATUS_RE} ]]; then
    fail "${file}: Status '${status}' is outside the permitted set (Proposed / Accepted /" \
      "'Amended (YYYY-MM-DD, #NNN)' / 'Superseded by ADR-NNNN' / Rejected)"
    return
  fi
  # A supersession that points nowhere loses the history it exists to preserve.
  if [[ "${status}" == "Superseded by ADR-"* ]]; then
    target="${status#Superseded by ADR-}"
    if ! compgen -G "${adr_dir}/${target}-*.md" >/dev/null; then
      fail "${file}: Status names ADR-${target}, but no such record exists in ${adr_dir}"
    fi
  fi
}

lint_file() {
  local file="$1" adr_dir="$2"
  local base count section
  base="$(basename "${file}")"

  if [[ ! "${base}" =~ ${ADR_FILENAME_RE} ]]; then
    fail "${file}: filename does not match the ADR pattern NNNN-kebab-case-title.md"
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

  check_status "${file}" "${adr_dir}"
  check_serves "${file}"
}

# Numbers are fixed and never reused, so two records sharing one is a defect
# even when both files are otherwise well-formed.
check_unique_numbers() {
  local files=("$@")
  local file base number seen=""
  for file in "${files[@]}"; do
    base="$(basename "${file}")"
    [[ "${base}" =~ ${ADR_FILENAME_RE} ]] || continue
    number="${BASH_REMATCH[1]}"
    if [[ "${seen}" == *" ${number} "* ]]; then
      fail "${file}: ADR number ${number} is already used by another record"
    fi
    seen="${seen} ${number} "
  done
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

  local records=() file
  # Sorted, so the report reads in ADR order regardless of the shell's glob.
  while IFS= read -r file; do
    [[ "$(basename "${file}")" == "${EXEMPT_BASENAME}" ]] || records+=("${file}")
  done < <(find "${adr_dir}" -maxdepth 1 -type f -name '*.md' | sort)

  [[ ${#records[@]} -gt 0 ]] || { echo "FATAL: no ADR files found in '${adr_dir}'" >&2; exit 1; }

  for file in "${records[@]}"; do
    lint_file "${file}" "${adr_dir}"
  done
  check_unique_numbers "${records[@]}"

  echo "ADR lint: ${#records[@]} record(s) checked, ${failures} failure(s)"
  [[ "${failures}" -eq 0 ]] || exit 1
}

main "$@"
