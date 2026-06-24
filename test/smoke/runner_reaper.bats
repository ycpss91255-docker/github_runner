#!/usr/bin/env bats
# Smoke tests for lib/runner-reaper.sh -- the orphan-container reaper (ADR-0001
# lifecycle, #105). On startup and periodically the listener sweeps containers
# carrying our managed-by label (#104) that are no longer tracked -- orphans
# left by a crash or a partial provision -- and removes them, so the ephemeral
# "zero residue" guarantee holds even when provision-job.sh's --rm never ran.
#
# The container CLI (docker) is shadowed by a PATH stub that, for `ps`, prints a
# scripted inventory of labelled containers and, for `rm`, records what it was
# asked to remove. NO real container engine is touched. Mirrors the
# runner_container.bats PATH-stub + argv-capture style.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
  source "${LIB}"
  source "${BATS_TEST_DIRNAME}/../../lib/runner-reaper.sh"

  STUB=$(mktemp -d)
  RM_CAP="${FAKE_RH}/rm.args"   # container ids passed to `docker rm`
  PS_OUT="${FAKE_RH}/ps.out"    # scripted `docker ps` inventory (one "id job-id" per line)
  : >"${PS_OUT}"

  # A docker stub: `ps` echoes the scripted inventory (the reaper asks for
  # "{{.Names}} {{.Label \"job-id\"}}" per labelled container); `rm` records the
  # ids it was told to remove. Any other subcommand is a no-op success.
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

teardown() { rm -rf "${FAKE_RH}" "${STUB}"; }

# Helper: write a scripted inventory line "<container-name> <job-id>".
inv() { printf '%s %s\n' "$1" "$2" >> "${PS_OUT}"; }

@test "reaper removes a labelled container that is no longer tracked" {
  inv gha-jit-orphan orphan
  run runner_reap_orphans   # no tracked ids -> everything labelled is an orphan
  [ "${status}" -eq 0 ]
  grep -qxF -- 'gha-jit-orphan' "${RM_CAP}"
}

@test "reaper does NOT remove a container that is still tracked" {
  inv gha-jit-live live
  run runner_reap_orphans live   # 'live' is tracked -> must be spared
  [ "${status}" -eq 0 ]
  [ ! -f "${RM_CAP}" ]
}

@test "reaper removes orphans but spares tracked containers in one sweep" {
  inv gha-jit-keep keep
  inv gha-jit-gone gone
  run runner_reap_orphans keep
  [ "${status}" -eq 0 ]
  grep -qxF -- 'gha-jit-gone' "${RM_CAP}"
  ! grep -qxF -- 'gha-jit-keep' "${RM_CAP}"
}

@test "reaper is a no-op (exit 0) when no labelled containers exist" {
  run runner_reap_orphans
  [ "${status}" -eq 0 ]
  [ ! -f "${RM_CAP}" ]
}

@test "reaper filters on our managed-by label" {
  inv gha-jit-x x
  # The ps invocation must scope to our label so we never touch foreign
  # containers. Capture the ps argv to assert the filter.
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
if [ "\$1" = ps ]; then printf '%s\n' "\$@" >> "${FAKE_RH}/ps.args"; fi
exit 0
EOF
  chmod +x "${STUB}/docker"
  run runner_reap_orphans
  [ "${status}" -eq 0 ]
  grep -qF -- "label=managed-by=${RUNNER_MANAGED_BY}" "${FAKE_RH}/ps.args"
}
