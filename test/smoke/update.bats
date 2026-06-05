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

@test "update.sh continues past a failing runner and reports a summary (#49)" {
  # Two org runners; the first (a-org, visited first) fails on svc.sh start,
  # the second (z-org) succeeds. The loop must NOT abort at the first failure:
  # z-org still gets upgraded, and the run exits non-zero with a summary
  # naming the failed runner. No gh on PATH (container) -> best-effort verify
  # warns + proceeds. `tar` is stubbed because production extraction uses GNU
  # `tar --skip-old-files`, unsupported by busybox tar (alpine test image) --
  # the same reason the real extraction path is out of smoke scope. Failure is
  # injected purely via svc.sh start, which is the regression #49 covers.
  mkdir -p "${RUNNER_HOME}/.bin" \
           "${RUNNER_HOME}/a-org/_org" "${RUNNER_HOME}/z-org/_org"
  printf '{ "agentName": "a-runner" }' > "${RUNNER_HOME}/a-org/_org/.runner"
  printf '{ "agentName": "z-runner" }' > "${RUNNER_HOME}/z-org/_org/.runner"
  printf 'cached-tarball-bytes' > "${TARBALL}"

  # Per-dir svc.sh: a-org fails `start`; z-org succeeds for every verb.
  cat > "${RUNNER_HOME}/a-org/_org/svc.sh" <<'EOF'
#!/bin/sh
[ "$1" = "start" ] && exit 1
exit 0
EOF
  printf '#!/bin/sh\nexit 0\n' > "${RUNNER_HOME}/z-org/_org/svc.sh"
  chmod +x "${RUNNER_HOME}/a-org/_org/svc.sh" "${RUNNER_HOME}/z-org/_org/svc.sh"

  STUB=$(mktemp -d)
  # _runner_svc runs `sudo ./svc.sh <verb>`; stub sudo to just exec its args.
  printf '#!/bin/sh\nexec "$@"\n' > "${STUB}/sudo"
  # Stub tar: succeed and drop a marker into the `-C <dir>` target so we can
  # assert the surviving runner was actually extracted into.
  cat > "${STUB}/tar" <<'EOF'
#!/bin/sh
d=""
while [ $# -gt 0 ]; do
  [ "$1" = "-C" ] && { shift; d="$1"; }
  shift
done
[ -n "$d" ] && : > "${d}/runner-bin"
exit 0
EOF
  chmod +x "${STUB}/sudo" "${STUB}/tar"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}"
  rm -rf "${STUB}"

  [ "${status}" -ne 0 ]
  # Both runners were visited -- the loop did not abort at the first failure.
  [[ "${output}" == *"updating ${RUNNER_HOME}/a-org/_org"* ]]
  [[ "${output}" == *"updating ${RUNNER_HOME}/z-org/_org"* ]]
  [[ "${output}" == *"Summary: 1 updated, 1 failed."* ]]
  [[ "${output}" == *"${RUNNER_HOME}/a-org/_org"* ]]
  # The surviving runner actually received the new binary.
  [ -f "${RUNNER_HOME}/z-org/_org/runner-bin" ]
}
