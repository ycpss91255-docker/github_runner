#!/usr/bin/env bats
# Smoke tests for update.sh. The real upgrade path needs registered runners +
# network + sudo, so only the --help short-circuit and the pre-extraction
# integrity gate (H1) are exercised here. RUNNER_VERSION is pinned so the
# cached tarball name is deterministic (resolve_runner_version echoes it
# verbatim, no gh needed).

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/update.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
  export RUNNER_VERSION="2.334.0"
  TARBALL="${RUNNER_HOME}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

@test "update.sh --help prints Usage and exits 0 without downloading" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
  [[ "${output}" != *"downloading"* ]]
}

@test "update.sh cache-hit with no registered runners: verifies, exits 0, never touches svc.sh" {
  # Pre-seed the cached tarball and leave RUNNER_HOME without any .runner dirs.
  # No gh on PATH -> runner_asset_digest is empty -> best-effort verify warns
  # and proceeds. list_runners emits nothing, so the per-runner loop (and its
  # svc.sh calls) never runs. Putting a failing svc.sh on PATH proves it is
  # never invoked: if it were, the script would error out.
  mkdir -p "${RUNNER_HOME}/.bin"
  printf 'cached-tarball-bytes' > "${TARBALL}"
  STUB=$(mktemp -d)
  printf '#!/bin/sh\necho "svc.sh should never run" >&2\nexit 7\n' > "${STUB}/svc.sh"
  chmod +x "${STUB}/svc.sh"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}"
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"update complete"* ]]
  [[ "${output}" != *"svc.sh should never run"* ]]
  # The cache hit means no download happened.
  [[ "${output}" != *"downloading"* ]]
}

@test "update.sh removes the cached tarball and exits non-zero when verification fails" {
  # Cache hit with a gh stub that returns a digest the file cannot match, so
  # verify_runner_tarball (via runner_asset_digest -> verify_sha256) fails. H1
  # routes that through `rm -f tarball; exit 1` BEFORE the extraction loop.
  mkdir -p "${RUNNER_HOME}/.bin"
  printf 'cached-tarball-bytes' > "${TARBALL}"
  STUB=$(mktemp -d)
  # Any gh api call prints a digest for an unrelated payload; sha256 won't match.
  cat > "${STUB}/gh" <<'EOF'
#!/bin/sh
echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
EOF
  chmod +x "${STUB}/gh"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}"
  rm -rf "${STUB}"
  [ "${status}" -ne 0 ]
  [ ! -e "${TARBALL}" ]
}
