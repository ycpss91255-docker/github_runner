#!/usr/bin/env bats
# Executable spec for the CI self-test entry (#78): the root `justfile` that
# replaces `Makefile.ci`. github_runner is a flat repo (no `.base/` subtree),
# so its self-test entry is a single flat `justfile` at the repo root that
# reproduces the old `make -f Makefile.ci <target>` surface verbatim:
#   * recipes: pull / lint / test / check / coverage (+ lint-host / test-host)
#   * TEST_TOOLS_IMAGE / COVERAGE_IMAGE pins, still overridable
#   * the kcov `--security-opt seccomp=unconfined` (ptrace) flag, verbatim
# These are static invariants of the file, guarded WITHOUT invoking docker /
# just (the recipes themselves are exercised by the CI gate). Aligns
# recipe-for-recipe with ycpss91255-docker/base's self-test `just` entry.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  JUSTFILE="${ROOT}/justfile"
}

@test "root justfile exists (#78)" {
  [ -f "${JUSTFILE}" ]
}

@test "Makefile.ci is removed -- the justfile is the sole entry (#78)" {
  [ ! -f "${ROOT}/Makefile.ci" ]
  [ ! -f "${ROOT}/Makefile" ]
}

@test "justfile defines the pull / lint / test / check / coverage recipes (#78)" {
  for r in pull lint test check coverage; do
    run grep -E "^${r}( .*)?:" "${JUSTFILE}"
    [ "${status}" -eq 0 ]
  done
}

@test "justfile defines the lint-host / test-host recipes (#78)" {
  run grep -E '^lint-host( .*)?:' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -E '^test-host( .*)?:' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}

@test "TEST_TOOLS_IMAGE pins the test-tools image and stays overridable (#78)" {
  # env_var_or_default keeps the caller's TEST_TOOLS_IM=... override winning,
  # mirroring Makefile.ci's `?=`.
  run grep -E "TEST_TOOLS_IMAGE.*env_var_or_default\('TEST_TOOLS_IMAGE'" "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -F 'ghcr.io/ycpss91255-docker/test-tools:latest' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}

@test "COVERAGE_IMAGE pins the kcov image and stays overridable (#78)" {
  run grep -E "COVERAGE_IMAGE.*env_var_or_default\('COVERAGE_IMAGE'" "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -F 'kcov/kcov:latest' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}

@test "coverage recipe carries the kcov seccomp=unconfined ptrace flag verbatim (#78)" {
  run grep -F -- '--security-opt seccomp=unconfined' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  # kcov instrumentation over the bats smoke suite, output into ./coverage.
  run grep -E 'kcov .*--include-path=\. .*coverage' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}

@test "lint recipe runs shellcheck -x and hadolint in the test-tools container (#78)" {
  run grep -E 'shellcheck -x' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -E 'hadolint' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}

@test "the ADR structure lint is on the lint path, not just a standalone script" {
  # A check nobody runs is not a gate: `lint` (and its host twin) must depend on
  # `lint-adr`, and the CI rollup must require the adr-lint job.
  run grep -E '^lint-adr( .*)?:' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -E '^lint: .*lint-adr' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -E '^lint-host: .*lint-adr' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -E '^\s+needs: \[.*adr-lint.*\]' "${ROOT}/.github/workflows/ci.yaml"
  [ "${status}" -eq 0 ]
}

@test "test recipe runs the bats smoke suite (#78)" {
  run grep -E 'bats .*test/smoke/' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}

@test "build-listener passes -buildvcs=false so the container build is not broken by dubious git ownership" {
  run grep -E 'build-listener' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -F -- '-buildvcs=false' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}
