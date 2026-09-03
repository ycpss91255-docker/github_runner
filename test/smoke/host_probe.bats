#!/usr/bin/env bats
# Smoke test for listener/host-probe.sh, the reactive live-admission host reader
# (ADR-0005, #163). It must emit the four keys the Go CommandHostProbe requires,
# each with a numeric value, from the real /proc on the test host.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../listener/host-probe.sh"
}

@test "host-probe emits the four required keys with numeric values" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]

  for key in loadavg1 nproc mem_total_kb mem_available_kb; do
    line="$(printf '%s\n' "${output}" | grep -E "^${key} ")"
    [ -n "${line}" ]
    value="${line#"${key} "}"
    # integer (nproc/mem) or decimal (loadavg) -- never empty or non-numeric,
    # which is exactly what the Go side rejects.
    [[ "${value}" =~ ^[0-9]+(\.[0-9]+)?$ ]]
  done
}

@test "host-probe reports a positive cpu count and total memory" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]

  nproc_line="$(printf '%s\n' "${output}" | grep -E '^nproc ')"
  [ "${nproc_line#nproc }" -ge 1 ]

  mem_line="$(printf '%s\n' "${output}" | grep -E '^mem_total_kb ')"
  [ "${mem_line#mem_total_kb }" -ge 1 ]
}
