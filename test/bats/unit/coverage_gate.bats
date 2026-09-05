#!/usr/bin/env bats
# Executable spec for script/coverage-gate.sh -- the coverage floors that block
# a merge (PRD.md §0.4).
#
# The point of a gate is that it says no. So every rule here is asserted from
# both sides: a report just below the floor must fail, and a report exactly at
# the floor must pass. The gate is also asserted to fail LOUDLY on a missing or
# malformed report -- a gate that treats "no report" as "nothing to complain
# about" is worse than no gate, because it reports success while measuring
# nothing (invariant 1).
#
# Everything runs off fixture reports written here, so no kcov run, no Go
# toolchain and no docker are involved.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  GATE="${ROOT}/script/coverage-gate.sh"
  COVDIR="${BATS_TEST_TMPDIR}/coverage"
  mkdir -p "${COVDIR}/bats.deadbeef"
  COBERTURA="${COVDIR}/bats.deadbeef/cobertura.xml"
  GOFUNC="${BATS_TEST_TMPDIR}/listener.func"
}

# A cobertura report shaped like the one kcov writes, with the given line rate
# (a fraction, as kcov emits it).
write_cobertura() {
  cat >"${COBERTURA}" <<EOF
<?xml version="1.0" ?>
<coverage line-rate="$1" lines-covered="1314" lines-valid="1470" branch-rate="1.0" version="1.9" timestamp="1788590109">
	<sources>
		<source>/source/</source>
	</sources>
	<packages>
		<package name="bats" line-rate="$1" lines-covered="1314" lines-valid="1470">
			<classes/>
		</package>
	</packages>
</coverage>
EOF
}

# A report shaped like `go tool cover -func` output, with the given total.
write_gofunc() {
  printf 'listener/config.go:31:\tvalidate\t\t100.0%%\n' >"${GOFUNC}"
  printf 'listener/wiring.go:43:\tInstance\t\t100.0%%\n' >>"${GOFUNC}"
  printf 'total:\t\t\t\t\t(statements)\t\t%s%%\n' "$1" >>"${GOFUNC}"
}

@test "the two floors are pinned in the gate itself, in exactly one place each" {
  run grep -cE '^readonly BASH_COVERAGE_FLOOR=' "${GATE}"
  [ "${output}" = "1" ]
  run grep -cE '^readonly GO_COVERAGE_FLOOR=' "${GATE}"
  [ "${output}" = "1" ]
}

@test "bash: a report below the floor fails, naming the measurement and the floor" {
  write_cobertura "0.849"
  run bash "${GATE}" bash "${COVDIR}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"84.9"* ]]
  [[ "${output}" == *"85"* ]]
}

@test "bash: a report exactly at the floor passes" {
  write_cobertura "0.850"
  run bash "${GATE}" bash "${COVDIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"85.0"* ]]
}

@test "bash: a report above the floor passes" {
  write_cobertura "0.894"
  run bash "${GATE}" bash "${COVDIR}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"89.4"* ]]
}

@test "bash: a missing report fails loudly instead of passing on nothing" {
  run bash "${GATE}" bash "${BATS_TEST_TMPDIR}/nowhere"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no cobertura report"* ]]
}

@test "bash: a report with no line rate fails loudly" {
  printf '<?xml version="1.0" ?>\n<coverage/>\n' >"${COBERTURA}"
  run bash "${GATE}" bash "${COVDIR}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"line-rate"* ]]
}

@test "go: a total below the floor fails, naming the measurement and the floor" {
  write_gofunc "84.9"
  run bash "${GATE}" go "${GOFUNC}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"84.9"* ]]
  [[ "${output}" == *"85"* ]]
}

@test "go: a total exactly at the floor passes" {
  write_gofunc "85.0"
  run bash "${GATE}" go "${GOFUNC}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"85.0"* ]]
}

@test "go: a total above the floor passes" {
  write_gofunc "88.0"
  run bash "${GATE}" go "${GOFUNC}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"88.0"* ]]
}

@test "go: a missing report fails loudly instead of passing on nothing" {
  run bash "${GATE}" go "${BATS_TEST_TMPDIR}/nowhere.func"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no such"* || "${output}" == *"not readable"* ]]
}

@test "go: a report with no total line fails loudly" {
  printf 'listener/config.go:31:\tvalidate\t\t100.0%%\n' >"${GOFUNC}"
  run bash "${GATE}" go "${GOFUNC}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"total"* ]]
}

@test "an unknown subject is refused rather than silently doing nothing" {
  run bash "${GATE}" python "${GOFUNC}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"usage"* ]]
}
