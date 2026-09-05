#!/usr/bin/env bats
# Smoke tests for the lib/common.sh destructive-action policy helpers (C2):
# parse_destructive_flags / confirm_or_abort / print_summary. These own the
# byte-identical flag/confirm/summary policy shared by cleanup.sh and
# uninstall.sh; the per-item loop + plan rendering stay in each script.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../../lib/common.sh"
}

@test "parse_destructive_flags --yes sets YES=1, DRY_RUN=0" {
  run bash -c "
    source '${LIB}'
    parse_destructive_flags --yes
    echo \"\${YES} \${DRY_RUN}\"
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "1 0" ]
}

@test "parse_destructive_flags --dry-run sets DRY_RUN=1, YES=0" {
  run bash -c "
    source '${LIB}'
    parse_destructive_flags --dry-run
    echo \"\${YES} \${DRY_RUN}\"
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "0 1" ]
}

@test "parse_destructive_flags rejects an unknown option via usage (exit 1)" {
  run bash -c "
    source '${LIB}'
    usage() { echo 'USAGE-TEXT'; }
    parse_destructive_flags --bogus
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unknown option: --bogus"* ]]
  [[ "${output}" == *"USAGE-TEXT"* ]]
}

@test "parse_destructive_flags --help prints usage and exits 0" {
  run bash -c "
    source '${LIB}'
    usage() { echo 'USAGE-TEXT'; }
    parse_destructive_flags --help
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"USAGE-TEXT"* ]]
}

@test "confirm_or_abort returns 0 without prompting when YES=1 (and actually ran)" {
  # D1: set -e + a command -v guard kill the spurious-green where a missing /
  # no-op confirm_or_abort would still let the trailing echo pass. The non-TTY
  # companion below covers the no-op-returns-success regression.
  #
  # Run the set -e sequence as a function in the bats process (not a `bash -c`
  # sub-shell): under kcov a set -u sub-shell aborts on kcov's BASH_ENV
  # instrumentation referencing an unbound BASH_SOURCE. The set -e + exit-3
  # spurious-green guard is preserved inside the function.
  _probe() {
    set -euo pipefail
    source "${LIB}"
    YES=1
    command -v confirm_or_abort >/dev/null || { echo MISSING; exit 3; }
    confirm_or_abort 'Proceed? ' < /dev/null
    echo CONTINUED
  }
  run _probe
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CONTINUED"* ]]
  [[ "${output}" != *"MISSING"* ]]
  [[ "${output}" != *"Proceed?"* ]]
  [[ "${output}" != *"non-interactive run requires --yes"* ]]
}

@test "confirm_or_abort fails non-TTY without --yes (exit 1, pinned message)" {
  # stdin redirected from /dev/null -> not a TTY -> must refuse.
  run bash -c "
    source '${LIB}'
    YES=0
    confirm_or_abort 'Proceed? '
  " </dev/null
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"non-interactive run requires --yes"* ]]
}

@test "print_summary reports an all-clean run and exits 0" {
  run bash -c "source '${LIB}'; print_summary 3 0"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Summary: 3 removed, 0 failed."* ]]
}

@test "print_summary lists failures and exits 1" {
  run bash -c "source '${LIB}'; print_summary 2 1 'org myorg'"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Summary: 2 removed, 1 failed."* ]]
  [[ "${output}" == *"org myorg"* ]]
}
