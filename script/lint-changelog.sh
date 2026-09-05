#!/usr/bin/env bash
# Changelog gate -- a change that users can see must carry a CHANGELOG entry.
#
# PRD.md §0.7 gives doc/changelog/CHANGELOG.md one job: answering "what changed
# that users can see", updated on every user-visible change. That rule was
# enforced only by a local hook, which means it was enforced only for whoever
# happened to be running the hook: a push from anywhere else was never checked.
# The one general rule of §0.4 is that a spec which cannot be checked
# automatically is equivalent to no spec at all, and a spec checked on one
# machine is the same rule half-applied. So it is a gate now.
#
# WHAT COUNTS AS A CHANGE THAT WARRANTS AN ENTRY. Everything except three
# classes, listed in EXEMPT_PATTERNS below: documentation, tests, and repo
# metadata. The exemptions are not politeness -- a gate that fires on a
# typo fix in a document, or on a pure test addition, is a gate people learn to
# work around, and a rule people work around is worse than no rule because it
# still produces red that everyone has been trained to ignore. What is left is
# exactly the surface an operator can observe: the scripts, the libraries, the
# listener, the images, the shipped samples, the recipes and the workflow.
#
# Exits non-zero when the range warrants an entry and has none, AND when the
# range itself cannot be determined: a gate that reads "I could not tell what
# changed" as "nothing to complain about" reports success while measuring
# nothing, which is the silent failure invariant 1 forbids.
#
# Usage:
#   script/lint-changelog.sh [--base <ref>]
#   script/lint-changelog.sh --files-from <file>
set -euo pipefail

readonly CHANGELOG='doc/changelog/CHANGELOG.md'
readonly DEFAULT_BASE='origin/main'

# Paths that never warrant an entry, as glob patterns matched against the
# repository-relative path. The changelog itself is deliberately absent: it is
# what satisfies the gate, not what triggers it.
readonly EXEMPT_PATTERNS=(
  'doc/*'          # documentation, including the ADRs and the PRD
  '*.md'           # any markdown anywhere (READMEs, SECURITY, CONTEXT)
  'test/*'         # the test suite
  '.gitignore'
  '.gitattributes'
  'LICENSE*'
  '*.lock'
  '*-lock.json'
  '.env*'
)

usage() {
  cat >&2 <<EOF
usage:
  script/lint-changelog.sh [--base <ref>]        check <ref>..HEAD (default ${DEFAULT_BASE})
  script/lint-changelog.sh --files-from <file>   check a changed-file list instead

Fails when the change warrants a ${CHANGELOG} entry and does not have one.
Documentation, tests and repo metadata never warrant one.
EOF
}

# True when the path is in one of the exempt classes.
is_exempt() {
  local path=$1 pattern
  for pattern in "${EXEMPT_PATTERNS[@]}"; do
    # shellcheck disable=SC2053  # glob match is the point
    [[ ${path} == ${pattern} ]] && return 0
  done
  return 1
}

# The changed paths of <base>..HEAD, one per line. Fails loudly when the base
# cannot be resolved -- an unresolvable base means the lint has no idea what
# changed, and saying nothing about that would be reporting success on nothing.
changed_from_git() {
  local base=$1 merge_base
  if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
    echo "FAIL: cannot resolve base ref '${base}' -- fetch it, or pass --base <ref>" >&2
    return 1
  fi
  # The merge base, not the branch tip: what this branch changed, not what main
  # gained while the branch was open.
  merge_base=$(git merge-base "${base}" HEAD)
  git diff --name-only "${merge_base}" HEAD
}

# Report and decide. Both outcomes name what was inspected, so a red gate is
# actionable from the log alone.
enforce() {
  local list=$1 path
  local has_entry=0
  local -a warrants=()

  while IFS= read -r path; do
    [[ -z ${path} ]] && continue
    if [[ ${path} == "${CHANGELOG}" ]]; then
      has_entry=1
      continue
    fi
    is_exempt "${path}" || warrants+=("${path}")
  done <"${list}"

  if (( ${#warrants[@]} == 0 )); then
    echo "ok: changelog gate -- nothing in this change warrants an entry"
    return 0
  fi
  if (( has_entry == 1 )); then
    echo "ok: changelog gate -- ${#warrants[@]} change(s) warrant an entry, and ${CHANGELOG} carries one"
    return 0
  fi

  echo "FAIL: this change warrants a ${CHANGELOG} entry and has none." >&2
  echo "      Add a bullet under [Unreleased]. Changed here:" >&2
  for path in "${warrants[@]}"; do
    echo "        ${path}" >&2
  done
  return 1
}

main() {
  local base="${DEFAULT_BASE}" files_from="" list

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --base) [[ $# -ge 2 ]] || { echo "--base needs a ref" >&2; usage; return 2; }
              base=$2; shift 2 ;;
      --files-from) [[ $# -ge 2 ]] || { echo "--files-from needs a file" >&2; usage; return 2; }
                    files_from=$2; shift 2 ;;
      *) echo "unknown option: $1" >&2; usage; return 2 ;;
    esac
  done

  if [[ -n ${files_from} ]]; then
    [[ -r ${files_from} ]] || { echo "FAIL: no such changed-file list: '${files_from}'" >&2; return 1; }
    list=${files_from}
  else
    list=$(mktemp)
    # shellcheck disable=SC2064  # expand the path now, not at trap time
    trap "rm -f '${list}'" EXIT
    changed_from_git "${base}" >"${list}"
  fi

  enforce "${list}"
}

main "$@"
