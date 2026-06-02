#!/usr/bin/env bats
# Smoke tests for the lib/common.sh tarball integrity helpers (SEC-5).
# verify_sha256 is pure (sha256sum, present on alpine + ubuntu);
# runner_asset_digest reaches GitHub through _gh, so it is shadowed in tests.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
}

@test "verify_sha256 succeeds when the file matches the expected hash" {
  TMP=$(mktemp -d); F="${TMP}/blob"
  printf 'hello runner\n' > "${F}"
  want=$(sha256sum "${F}" | cut -d' ' -f1)
  run bash -c "source '${LIB}'; verify_sha256 '${F}' '${want}'"
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
}

@test "verify_sha256 fails on a hash mismatch" {
  TMP=$(mktemp -d); F="${TMP}/blob"; printf 'hello\n' > "${F}"
  run bash -c "source '${LIB}'; verify_sha256 '${F}' 'deadbeef'"
  rm -rf "${TMP}"
  [ "${status}" -ne 0 ]
}

@test "runner_asset_digest strips the sha256: prefix from the asset digest" {
  run bash -c "
    source '${LIB}'
    _gh() { printf 'sha256:abc123\n'; }
    runner_asset_digest 2.334.0 actions-runner-linux-x64-2.334.0.tar.gz
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "abc123" ]
}

@test "runner_asset_digest yields nothing when gh cannot provide it" {
  run bash -c "
    source '${LIB}'
    _gh() { return 1; }
    runner_asset_digest 2.334.0 actions-runner-linux-x64-2.334.0.tar.gz
  "
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "verify_runner_tarball proceeds (0) when the downloaded file matches" {
  TMP=$(mktemp -d); F="${TMP}/t.tgz"; printf 'payload\n' > "${F}"
  want=$(sha256sum "${F}" | cut -d' ' -f1)
  run bash -c "
    source '${LIB}'
    _gh() { printf 'sha256:${want}\n'; }
    verify_runner_tarball '${F}' 2.334.0 t.tgz strict
  "
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"sha256 ok"* ]]
}

@test "verify_runner_tarball aborts (1) on a mismatch regardless of mode" {
  TMP=$(mktemp -d); F="${TMP}/t.tgz"; printf 'payload\n' > "${F}"
  run bash -c "
    source '${LIB}'
    _gh() { printf 'sha256:0000000000000000000000000000000000000000000000000000000000000000\n'; }
    verify_runner_tarball '${F}' 2.334.0 t.tgz best-effort
  "
  rm -rf "${TMP}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"mismatch"* ]]
}

@test "verify_runner_tarball strict aborts (1) when the digest is unavailable" {
  TMP=$(mktemp -d); F="${TMP}/t.tgz"; printf 'payload\n' > "${F}"
  run bash -c "
    source '${LIB}'
    _gh() { return 1; }
    verify_runner_tarball '${F}' 2.334.0 t.tgz strict
  "
  rm -rf "${TMP}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not obtain"* ]]
}

@test "verify_runner_tarball best-effort proceeds (0) with a warning when digest unavailable" {
  TMP=$(mktemp -d); F="${TMP}/t.tgz"; printf 'payload\n' > "${F}"
  run bash -c "
    source '${LIB}'
    _gh() { return 1; }
    verify_runner_tarball '${F}' 2.334.0 t.tgz best-effort
  "
  rm -rf "${TMP}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipping integrity check"* ]]
}
