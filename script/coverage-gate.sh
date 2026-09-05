#!/usr/bin/env bash
# Coverage gate -- the machine check behind the coverage floors in PRD.md §0.4.
#
# Coverage used to be a metric that could not fail anything: the CI job carried
# `continue-on-error`, ran only on pushes to main, and was deliberately outside
# the ci-rollup `needs:` list. The stated reason was that the measurement itself
# was not reproducible. It is now (`just coverage` runs a pinned bats in an
# offline container), so the number is trustworthy enough to hold a line, and a
# number nobody can fail is not a line.
#
# Two subjects, one floor each:
#
#   coverage-gate.sh bash <coverage-dir>   the kcov cobertura report's line rate
#   coverage-gate.sh go   <func-report>    the total from `go tool cover -func`
#
# Both floors live below, each in exactly one place. Raising one is a
# deliberate edit here, not a side effect of a good week.
#
# WHAT IS DELIBERATELY NOT MEASURED. The Go floor is applied to the `listener`
# package only; `listener/cmd/scaleset-listener` is excluded (the caller
# excludes it when it builds the profile -- see the `coverage-go` recipe in the
# justfile). That entrypoint reads environment variables and wires the pieces
# together; it makes no decisions. PRD.md §0.4's layered coverage strategy
# requires line coverage of the core layer and covers the io and api layers with
# integration- and system-level tests instead, precisely because chasing line
# coverage through a wiring layer produces "call it once, assert it was called"
# tests -- which raise the number and lower the signal. Excluding it keeps the
# floor a statement about the decision logic.
#
# Exits non-zero when a floor is missed AND when the report is missing or
# unparseable: a gate that reads "no report" as "nothing to complain about"
# reports success while measuring nothing, which is exactly the silent failure
# invariant 1 forbids.
set -euo pipefail

# The floors, as percentages. One line each; bump deliberately.
readonly BASH_COVERAGE_FLOOR=85.0
readonly GO_COVERAGE_FLOOR=85.0

usage() {
  cat >&2 <<'EOF'
usage:
  script/coverage-gate.sh bash <coverage-dir>   enforce the bash line-coverage floor
  script/coverage-gate.sh go   <func-report>    enforce the Go coverage floor

  <coverage-dir>  the directory `just coverage` wrote (kcov's cobertura report
                  lives one level below it, in a per-binary subdirectory)
  <func-report>   a file holding `go tool cover -func` output
EOF
}

# The single cobertura report kcov wrote under a coverage dir. kcov names the
# subdirectory after the traced binary, so the name is not stable -- but there
# is exactly one report, and "exactly one" is the thing worth asserting.
cobertura_report_path() {
  local dir=$1 found
  shopt -s nullglob
  local candidates=("${dir}"/*/cobertura.xml)
  shopt -u nullglob
  if (( ${#candidates[@]} != 1 )); then
    echo "FAIL: no cobertura report (or more than one) under '${dir}' -- did \`just coverage\` run?" >&2
    return 1
  fi
  found=${candidates[0]}
  printf '%s\n' "${found}"
}

# The overall line rate of a cobertura report, as a percentage with one decimal.
# kcov writes it as a fraction on the root <coverage> element, which is the
# first line-rate attribute in the file.
cobertura_line_percent() {
  local file=$1 rate
  rate=$(grep -o 'line-rate="[0-9.]*"' "${file}" | head -1 | sed 's/.*"\(.*\)"/\1/')
  if [[ -z ${rate} ]]; then
    echo "FAIL: no line-rate attribute in '${file}' -- the report is not a cobertura report" >&2
    return 1
  fi
  awk -v r="${rate}" 'BEGIN { printf "%.1f\n", r * 100 }'
}

# The total from `go tool cover -func` output, as a percentage. The last field
# of the `total:` line, minus the % sign.
gofunc_total_percent() {
  local file=$1 total
  if [[ ! -r ${file} ]]; then
    echo "FAIL: no such Go coverage report: '${file}' -- did \`just coverage-go\` run?" >&2
    return 1
  fi
  total=$(awk '/^total:/ { gsub("%", "", $NF); print $NF }' "${file}" | tail -1)
  if [[ -z ${total} ]]; then
    echo "FAIL: no total line in '${file}' -- it is not \`go tool cover -func\` output" >&2
    return 1
  fi
  printf '%s\n' "${total}"
}

# Compare and report. At the floor passes; below it fails. Both outcomes name
# the measurement, the floor and the report, so a red gate is actionable from
# the log alone.
enforce_floor() {
  local label=$1 actual=$2 floor=$3 report=$4
  if awk -v a="${actual}" -v f="${floor}" 'BEGIN { exit !(a + 0 >= f + 0) }'; then
    echo "ok: ${label} ${actual}% (floor ${floor}%, report ${report})"
    return 0
  fi
  echo "FAIL: ${label} ${actual}% is below the ${floor}% floor (report ${report})" >&2
  return 1
}

main() {
  local subject=${1:-} target=${2:-} report percent
  case "${subject}" in
    bash)
      [[ -n ${target} ]] || { usage; return 2; }
      report=$(cobertura_report_path "${target}")
      percent=$(cobertura_line_percent "${report}")
      enforce_floor "bash line coverage" "${percent}" "${BASH_COVERAGE_FLOOR}" "${report}"
      ;;
    go)
      [[ -n ${target} ]] || { usage; return 2; }
      report=${target}
      percent=$(gofunc_total_percent "${report}")
      enforce_floor "go coverage (listener core)" "${percent}" "${GO_COVERAGE_FLOOR}" "${report}"
      ;;
    *)
      usage
      return 2
      ;;
  esac
}

main "$@"
