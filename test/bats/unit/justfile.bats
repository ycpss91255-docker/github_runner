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
  ROOT="${BATS_TEST_DIRNAME}/../../.."
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

@test "coverage installs no packages at run time -- it must be reproducible offline" {
  # The recipe used to `apt-get install bats` inside the kcov container on every
  # run, so coverage needed the Debian archive to be reachable and picked up
  # whatever bats version the archive carried that day. A check that cannot be
  # reproduced on a restricted network is not a check.
  run grep -F 'apt-get' "${JUSTFILE}"
  [ "${status}" -ne 0 ]
}

@test "coverage runs the pinned, cached bats and is denied the network entirely" {
  # script/fetch-bats.sh caches a sha256-verified bats-core release on the host;
  # the recipe mounts it read-only into the container. --network none is what
  # turns "needs no network" from a claim into a property of the run.
  run grep -F 'script/fetch-bats.sh' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -F -- '--network none' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -F '/opt/bats/bin/bats' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}

@test "coverage writes the report as the invoking user, so it can be re-run" {
  # kcov runs as root in the container, so without --user the report lands
  # root-owned on the host and the recipe's own `rm -rf coverage` fails on the
  # NEXT run -- i.e. `just coverage` would be reproducible exactly once.
  run grep -F -- '--user "$(id -u):$(id -g)"' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}

@test "pull warms the bats cache, so pull remains the whole first-fetch step" {
  # `just pull` is the documented "fetch everything you need" recipe; if it only
  # pulled images, the first `just coverage` on a restricted network would still
  # fail.
  run bash -c "sed -n '/^pull:/,/^\$/p' '${JUSTFILE}' | grep -F 'script/fetch-bats.sh'"
  [ "${status}" -eq 0 ]
}

@test "SCRIPTS enumerates script/fetch-bats.sh so shellcheck covers it" {
  run bash -c "grep -E '^SCRIPTS :=' '${JUSTFILE}' | grep -F 'script/fetch-bats.sh'"
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

@test "test recipe runs both levels of the layered bats suite (#78)" {
  # The suite is layered (doc/test-levels.md). `just test` runs every level, so
  # the default check stays "the whole bash suite" -- the levels exist to make a
  # red check legible, not to let one of them be skipped by default.
  run grep -E '^test:.*[[:space:]]test-unit([[:space:]]|$)' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -E '^test:.*[[:space:]]test-integration([[:space:]]|$)' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}

@test "each level is runnable on its own, so a red check names the level" {
  # The whole point of layering: a maintainer who sees the integration level go
  # red must be able to re-run just that level without the other. Each level
  # recipe must also run its own directory -- two recipe names pointing at the
  # same directory would be layering in the listing only.
  run bash -c "sed -n '/^test-unit:/,/^\$/p' '${JUSTFILE}' | grep -F 'test/bats/unit/'"
  [ "${status}" -eq 0 ]
  run bash -c "sed -n '/^test-integration:/,/^\$/p' '${JUSTFILE}' | grep -F 'test/bats/integration/'"
  [ "${status}" -eq 0 ]
}

@test "no recipe still points at the pre-layering flat directory" {
  # A stale test/smoke/ path in a recipe would run nothing and still pass, which
  # is the silent-failure mode invariant 1 forbids.
  run grep -F 'test/smoke' "${JUSTFILE}"
  [ "${status}" -ne 0 ]
}

@test "the bats suite is laid out by level, with nothing left flat" {
  [ -d "${ROOT}/test/bats/unit" ]
  [ -d "${ROOT}/test/bats/integration" ]
  [ ! -d "${ROOT}/test/smoke" ]
  # A level directory that exists must actually hold tests -- an empty one is a
  # claim the suite cannot back (doc/test-levels.md).
  run bash -c "ls '${ROOT}'/test/bats/unit/*.bats >/dev/null 2>&1"
  [ "${status}" -eq 0 ]
  run bash -c "ls '${ROOT}'/test/bats/integration/*.bats >/dev/null 2>&1"
  [ "${status}" -eq 0 ]
}

@test "the levels are defined in a document, not just in directory names" {
  [ -f "${ROOT}/doc/test-levels.md" ]
}

@test "the coverage floors are on the recipe path, not just a standalone script" {
  # Same rule as the ADR lint above: a check nobody runs is not a gate. There
  # must be a recipe that measures AND enforces, for both languages, and
  # SCRIPTS must list the gate so shellcheck covers it.
  run grep -E '^coverage-gate: coverage' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -E '^coverage-go( .*)?:' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run bash -c "grep -E '^SCRIPTS :=' '${JUSTFILE}' | grep -F 'script/coverage-gate.sh'"
  [ "${status}" -eq 0 ]
}

@test "go coverage excludes the cmd/ entrypoint from the line-coverage floor" {
  # cmd/scaleset-listener only reads environment variables and wires the pieces
  # together; it is covered at the integration and system level, per PRD.md
  # §0.4's layered coverage strategy. Measuring it as line coverage would just
  # invite assertion-free tests, so it is excluded deliberately -- and the
  # exclusion has to be visible here, not discovered from a low number.
  run bash -c "grep -A6 -E '^coverage-go( .*)?:' '${JUSTFILE}' | grep -F '/cmd/'"
  [ "${status}" -eq 0 ]
}

@test "coverage is a merge gate: it blocks a PR instead of only reporting" {
  # Coverage used to be advisory -- `continue-on-error: true`, restricted to
  # pushes to main, and deliberately kept out of the ci-rollup `needs:` list.
  # A floor that cannot fail a PR is not a floor.
  local ci="${ROOT}/.github/workflows/ci.yaml"
  run grep -F 'continue-on-error: true' "${ci}"
  [ "${status}" -ne 0 ]
  run grep -E '^\s+needs: \[.*coverage.*\]' "${ci}"
  [ "${status}" -eq 0 ]
}

@test "build-listener passes -buildvcs=false so the container build is not broken by dubious git ownership" {
  run grep -E 'build-listener' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  run grep -F -- '-buildvcs=false' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
}
