#!/usr/bin/env bats
# Smoke tests for init.sh prereq checking.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/init.sh"
  FAKE_HOME=$(mktemp -d)
  export HOME="${FAKE_HOME}"
}

teardown() {
  rm -rf "${FAKE_HOME}"
  [ -n "${FAKE_RH:-}" ] && rm -rf "${FAKE_RH}"
  [ -n "${STUB:-}" ] && rm -rf "${STUB}"
  return 0
}

# Build a PATH stub dir that lets check_prereqs pass to completion on a
# non-GPU host: docker is real in the alpine test-tools image, so we only
# shadow the prereqs it lacks (gh/curl/jq), make `groups` report membership,
# and -- deliberately -- supply NO nvidia-smi so the non-GPU branch is taken.
# The `gh` stub answers the three gh shapes init reaches:
#   - `gh auth status`                       -> exit 0 (authenticated)
#   - releases/latest --jq .tag_name         -> a fixed tag (resolve_runner_version)
#   - releases/tags/v<ver> (digest lookup)   -> EMPTY, so a strict verify fails
# A non-empty TARBALL_VERSION export is the version the tag resolves to.
make_prereq_stub() {
  STUB=$(mktemp -d)
  TARBALL_VERSION="2.334.0"
  cat >"${STUB}/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "auth status") exit 0 ;;
esac
for a in "$@"; do
  case "$a" in
    */releases/latest) printf 'v2.334.0\n'; exit 0 ;;
    */releases/tags/*) exit 0 ;;   # digest lookup -> empty output
  esac
done
exit 0
EOF
  # curl records that it ran and creates the partial download so a later
  # rm -f on a verify failure is observable.
  cat >"${STUB}/curl" <<'EOF'
#!/bin/sh
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && printf 'partial-bytes\n' > "$out"
echo "CURL-RAN" >&2
exit 0
EOF
  printf '#!/bin/sh\nexit 0\n' > "${STUB}/jq"
  printf '#!/bin/sh\necho docker\n' > "${STUB}/groups"
  chmod +x "${STUB}/gh" "${STUB}/curl" "${STUB}/jq" "${STUB}/groups"
}

@test "init.sh reports every missing prereq individually and the aggregate gate fires" {
  # /bin + /usr/bin keeps bash (alpine) and groups / grep reachable so the
  # script starts and runs the prereq checks. docker / nvidia-smi / gh / jq
  # are absent in the test-tools alpine container so each command -v fails.
  # This is the B1 regression test: a set -e short-circuit on the first
  # failure would print only ONE FAIL line and never reach the summary.
  # Assert prereqs reliably ABSENT in the alpine test-tools image (docker
  # CLI happens to be present there, so don't assert on it).
  PATH=/bin:/usr/bin run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"FAIL: gh CLI not installed"* ]]
  [[ "${output}" == *"FAIL: curl not installed"* ]]
  [[ "${output}" == *"FAIL: jq not installed"* ]]
  [[ "${output}" == *"prereq check failed"* ]]
  [ "$(printf '%s\n' "${output}" | grep -c '^FAIL:')" -ge 4 ]
}

@test "init.sh skips the GPU checks when nvidia-smi is absent (non-GPU host)" {
  # #34: a host without a GPU is auto-detected (no nvidia-smi) -> the two GPU
  # gates are skipped (a note, not a FAIL), so a non-GPU host can bootstrap.
  PATH=/bin:/usr/bin run "${SCRIPT}"
  [[ "${output}" != *"FAIL: nvidia-smi"* ]]
  [[ "${output}" != *"FAIL: docker --gpus all"* ]]
  [[ "${output}" == *"non-GPU"* ]]
}

@test "init.sh prereq failures and the summary go to stderr, not stdout" {
  run bash -c "PATH=/bin:/usr/bin '${SCRIPT}' 2>'${BATS_TEST_TMPDIR}/err' >'${BATS_TEST_TMPDIR}/out'"
  [ "${status}" -ne 0 ]
  grep -q '^FAIL:' "${BATS_TEST_TMPDIR}/err"
  grep -q 'prereq check failed' "${BATS_TEST_TMPDIR}/err"
  ! grep -q '^FAIL:' "${BATS_TEST_TMPDIR}/out"
}

@test "init.sh --help prints Usage and does not bootstrap a runner" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
  [[ "${output}" != *"bootstrapping first runner"* ]]
}

@test "init.sh cache_tarball early-returns 'tarball cached' for an already-cached tarball (no download)" {
  # cache_tarball builds actions-runner-linux-x64-<version>.tar.gz under
  # ${RUNNER_HOME}/.bin; when it already exists the function prints
  # "tarball cached: <path>" and returns BEFORE curl/verify ever run.
  FAKE_RH=$(mktemp -d); export RUNNER_HOME="${FAKE_RH}"
  make_prereq_stub
  local cached="${RUNNER_HOME}/.bin/actions-runner-linux-x64-${TARBALL_VERSION}.tar.gz"
  mkdir -p "${RUNNER_HOME}/.bin"
  printf 'already-here\n' > "${cached}"

  run env PATH="${STUB}:/bin:/usr/bin" "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tarball cached: ${cached}"* ]]
  [[ "${output}" != *"downloading"* ]]
  [[ "${output}" != *"CURL-RAN"* ]]
  # the early return must not touch the pre-existing file
  [ -f "${cached}" ]
  [ "$(cat "${cached}")" = "already-here" ]
}

@test "init.sh cache_tarball removes the partial download and exits 1 on a STRICT verify failure" {
  # No cached tarball -> curl writes the partial file -> verify_runner_tarball
  # runs in strict mode; the gh digest lookup returns empty, so strict aborts.
  # cache_tarball must `rm -f` the partial download and exit 1 so a later run
  # can't trust an unverified cached copy.
  FAKE_RH=$(mktemp -d); export RUNNER_HOME="${FAKE_RH}"
  make_prereq_stub
  local partial="${RUNNER_HOME}/.bin/actions-runner-linux-x64-${TARBALL_VERSION}.tar.gz"

  run env PATH="${STUB}:/bin:/usr/bin" "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"downloading"* ]]                 # got past the cache check
  [[ "${output}" == *"could not obtain the expected sha256"* ]]
  [ ! -e "${partial}" ]                                # partial removed (rm -f)
}

@test "init.sh emits the configure.sh --labels gpu-label note on a non-GPU host (post cache_tarball)" {
  # #34: after a clean bootstrap on a non-GPU host (nvidia-smi absent), the
  # default 'gpu' registration label is wrong, so init flags it pointing at
  # configure.sh --labels. This note fires only after check_prereqs AND
  # cache_tarball succeed, so it exercises the full happy path.
  FAKE_RH=$(mktemp -d); export RUNNER_HOME="${FAKE_RH}"
  make_prereq_stub
  local cached="${RUNNER_HOME}/.bin/actions-runner-linux-x64-${TARBALL_VERSION}.tar.gz"
  mkdir -p "${RUNNER_HOME}/.bin"
  printf 'already-here\n' > "${cached}"   # cached -> skip download/verify

  run env PATH="${STUB}:/bin:/usr/bin" "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"the 'gpu' label"* ]]
  [[ "${output}" == *"./script/configure.sh --labels"* ]]
  [[ "${output}" == *"init complete"* ]]   # no org arg -> no runner registered
}
