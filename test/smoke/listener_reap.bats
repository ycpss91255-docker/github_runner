#!/usr/bin/env bats
# Smoke tests for listener/reap.sh -- the listener's orphan-sweep entrypoint
# (ADR-0001 lifecycle, #105/#106). The Go listener shells out to this script on
# startup and on its reap interval; it bridges the Go loop to the bash reaper
# seam (lib/runner-reaper.sh), removing labelled containers (#104) no longer
# tracked and pruning leaked per-job temp dirs under the work root. The
# container CLI (docker) is shadowed by a PATH stub; NO real engine is touched.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  SCRIPT="${ROOT}/listener/reap.sh"

  WORK=$(mktemp -d)
  export RUNNER_HOME="${WORK}/home"
  mkdir -p "${RUNNER_HOME}"
  export RUNNER_WORK_ROOT="${WORK}/work"
  mkdir -p "${RUNNER_WORK_ROOT}"

  STUB=$(mktemp -d)
  RM_CAP="${WORK}/rm.args"
  PS_OUT="${WORK}/ps.out"
  : >"${PS_OUT}"
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps) cat "${PS_OUT}" ;;
  rm) shift; printf '%s\n' "\$@" >> "${RM_CAP}" ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "${STUB}/docker"
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${WORK}" "${STUB}"; }

@test "reap.sh exists and is executable" {
  [ -x "${SCRIPT}" ]
}

@test "reap.sh removes an orphan container and prunes its stale temp dir (#105/#106)" {
  printf 'gha-jit-orphan orphan\n' >> "${PS_OUT}"
  mkdir -p "${RUNNER_WORK_ROOT}/jit-orphan.XYZ"
  run "${SCRIPT}"   # no tracked ids -> everything is an orphan
  [ "${status}" -eq 0 ]
  grep -qxF -- 'gha-jit-orphan' "${RM_CAP}"
  [ ! -d "${RUNNER_WORK_ROOT}/jit-orphan.XYZ" ]
}

@test "reap.sh spares a tracked job's container and temp dir (#105/#106)" {
  printf 'gha-jit-live live\n' >> "${PS_OUT}"
  mkdir -p "${RUNNER_WORK_ROOT}/jit-live.XYZ"
  run "${SCRIPT}" live
  [ "${status}" -eq 0 ]
  [ ! -f "${RM_CAP}" ]
  [ -d "${RUNNER_WORK_ROOT}/jit-live.XYZ" ]
}
