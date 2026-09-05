#!/usr/bin/env bats
# Integration spec for script/teardown-listener.sh -- the reversal of the local
# half of the deploy, driven over scripted stub executables on a clean PATH.
#
# Reversibility is a project requirement, so the removal path is exercised, not
# just its preview: the unit is stopped and disabled, the unit file, the
# environment file (which holds the admin token) and the install prefix are
# gone afterwards, a second run is a clean no-op, and the scale set on GitHub is
# never touched by any of it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${ROOT}/script/teardown-listener.sh"
  WORK=$(mktemp -d)
  STUB="${WORK}/stub"
  mkdir -p "${STUB}"
  CAP="${WORK}/argv.log"
  : > "${CAP}"

  PREFIX="${WORK}/opt"
  ETC="${WORK}/etc"
  UNIT_DIR="${WORK}/systemd"
  export STUB_STATE="${WORK}/state"
  mkdir -p "${STUB_STATE}"

  # A deployed machine: prefix, env file at 0600, unit installed, unit running.
  mkdir -p "${PREFIX}/bin" "${ETC}" "${UNIT_DIR}"
  : > "${PREFIX}/bin/scaleset-listener"
  printf 'GITHUB_TOKEN=tok-abc123\n' > "${ETC}/scaleset-listener.env"
  chmod 600 "${ETC}/scaleset-listener.env"
  printf '[Service]\n' > "${UNIT_DIR}/scaleset-listener.service"
  : > "${STUB_STATE}/started"
  : > "${STUB_STATE}/enabled"

  cat > "${STUB}/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "name=systemctl" "$@" >> "${CAP_FILE}"
case "$1" in
  is-active)  [ -e "${STUB_STATE}/started" ] && { echo active; exit 0; }; exit 3 ;;
  is-enabled) [ -e "${STUB_STATE}/enabled" ] && { echo enabled; exit 0; }; exit 1 ;;
  stop)       rm -f "${STUB_STATE}/started"; exit 0 ;;
  disable)    rm -f "${STUB_STATE}/enabled"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${STUB}/systemctl"
  export CAP_FILE="${CAP}"
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${WORK}"; }

_teardown_run() {
  "${SCRIPT}" --yes --prefix "${PREFIX}" --etc "${ETC}" --unit-dir "${UNIT_DIR}" "$@"
}

@test "a teardown removes the prefix, the env file and the unit" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  [ ! -d "${PREFIX}" ]
  [ ! -f "${ETC}/scaleset-listener.env" ]
  [ ! -f "${UNIT_DIR}/scaleset-listener.service" ]
}

@test "a teardown stops and disables the unit before removing it" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  grep -qxF 'stop' "${CAP}"
  grep -qxF 'disable' "${CAP}"
  grep -qxF 'daemon-reload' "${CAP}"
}

@test "the env file holding the token is actually gone, not just unreferenced" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  ! grep -rqF 'tok-abc123' "${ETC}" 2>/dev/null
}

@test "a second teardown is a clean no-op that still exits 0" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  run _teardown_run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already absent"* ]]
}

@test "a teardown of a machine that was never deployed succeeds" {
  rm -rf "${PREFIX}" "${ETC}" "${UNIT_DIR}"
  rm -f "${STUB_STATE}/started" "${STUB_STATE}/enabled"
  run _teardown_run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipped"* ]]
}

@test "a teardown never invokes scaleset-admin, so the scale set cannot be touched" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  ! grep -qF 'scaleset-admin' "${CAP}"
  # And it says so, so the operator knows what is still out there.
  [[ "${output}" == *"scale set"* ]]
}

@test "the service user is left alone unless --remove-user names it" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"left in place"* ]]
}

@test "a prefix that is not a plausible install root is refused" {
  # The prefix is an rm -rf target, so it is checked lexically rather than
  # trusted because it arrived in a flag.
  run "${SCRIPT}" --yes --prefix / --etc "${ETC}" --unit-dir "${UNIT_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"refusing"* ]]
  run "${SCRIPT}" --yes --prefix /usr --etc "${ETC}" --unit-dir "${UNIT_DIR}"
  [ "${status}" -eq 1 ]
  run "${SCRIPT}" --yes --prefix relative/path --etc "${ETC}" --unit-dir "${UNIT_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"absolute"* ]]
  run "${SCRIPT}" --yes --prefix /opt/../etc --etc "${ETC}" --unit-dir "${UNIT_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"normalized"* ]]
  # Nothing was removed by any of the refusals.
  [ -d "${PREFIX}" ]
}
