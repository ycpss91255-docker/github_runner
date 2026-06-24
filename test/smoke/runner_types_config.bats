#!/usr/bin/env bats
# Drift guard for the runner-type config sample (ADR-0001, #110/#113).
#
# The operator-facing example lives at deploy/runner-types.sample.yaml. The Go
# loader's tests need it inside the module sandbox, so a byte-identical copy
# lives at listener/testdata/runner-types.sample.yaml. These tests keep the two
# in sync (so the documented example and the one the loader is tested against
# can never diverge) and assert the sample carries the concrete GPU type (#113).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  DEPLOY="${ROOT}/deploy/runner-types.sample.yaml"
  TESTDATA="${ROOT}/listener/testdata/runner-types.sample.yaml"
}

@test "the operator-facing and testdata runner-type samples are byte-identical" {
  [ -f "${DEPLOY}" ]
  [ -f "${TESTDATA}" ]
  run diff -u "${DEPLOY}" "${TESTDATA}"
  [ "${status}" -eq 0 ]
}

@test "the runner-type sample defines the concrete GPU type with auto concurrency (#113)" {
  run grep -E '^[[:space:]]*-[[:space:]]*name:[[:space:]]*gpu' "${DEPLOY}"
  [ "${status}" -eq 0 ]
  run grep -E 'scale_set:[[:space:]]*gpu-runners' "${DEPLOY}"
  [ "${status}" -eq 0 ]
  run grep -E 'mode:[[:space:]]*auto' "${DEPLOY}"
  [ "${status}" -eq 0 ]
}

@test "the runner-type sample defines a second type (#112) so two types run without code change" {
  run grep -E '^[[:space:]]*-[[:space:]]*name:[[:space:]]*cpu' "${DEPLOY}"
  [ "${status}" -eq 0 ]
}
