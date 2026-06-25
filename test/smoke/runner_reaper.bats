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
  RM_CAP="${FAKE_RH}/rm.args"   # targets passed to `docker rm`
  PS_OUT="${FAKE_RH}/ps.out"    # scripted `docker ps` inventory (one container ID per line)
  INSPECT_DIR="${FAKE_RH}/inspect"  # per-id "<format>\t<value>" inspect answers
  mkdir -p "${INSPECT_DIR}"
  : >"${PS_OUT}"

  # A docker stub modelling the real engine. The reaper now reaps by an
  # injection-proof container ID: `ps` echoes one container ID per line (the
  # scripted inventory) and `inspect` answers a per-id, per-format query (so the
  # reaper can read the job-id / managed-by labels keyed on the ID it is about to
  # remove). `rm` records the targets it was told to remove. Critically, the
  # job-id LABEL value is only ever returned by `inspect` -- never parsed as a
  # control field -- so a newline in the label can no longer forge a row.
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps) cat "${PS_OUT}" ;;
  inspect)
    # docker inspect --format '<fmt>' <id>: answer from INSPECT_DIR/<id>.<key>.
    fmt=""; id=""
    shift
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --format|-f) fmt="\$2"; shift 2 ;;
        --format=*) fmt="\${1#--format=}"; shift ;;
        *) id="\$1"; shift ;;
      esac
    done
    case "\$fmt" in
      *job-id*)     key=jobid ;;
      *managed-by*) key=managedby ;;
      *)            key=other ;;
    esac
    f="${INSPECT_DIR}/\${id}.\${key}"
    if [ -f "\$f" ]; then cat "\$f"; else exit 1; fi
    ;;
  rm) shift; printf '%s\n' "\$@" >> "${RM_CAP}" ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "${STUB}/docker"
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${FAKE_RH}" "${STUB}"; }

# Helper: register a container in the scripted inventory.
#   inv <container-id> <job-id> [managed-by]
# Records the ID in the `ps` output and writes its inspect answers so the
# reaper can resolve the job-id (and managed-by, defaulting to ours) by ID.
inv() {
  local id=$1 job_id=$2 managed_by=${3:-${RUNNER_MANAGED_BY}}
  printf '%s\n' "${id}" >> "${PS_OUT}"
  printf '%s' "${job_id}"    > "${INSPECT_DIR}/${id}.jobid"
  printf '%s' "${managed_by}" > "${INSPECT_DIR}/${id}.managedby"
}

@test "reaper removes a labelled container that is no longer tracked" {
  inv c0ffee orphan
  run runner_reap_orphans   # no tracked ids -> everything labelled is an orphan
  [ "${status}" -eq 0 ]
  grep -qxF -- 'c0ffee' "${RM_CAP}"
}

@test "reaper does NOT remove a container that is still tracked" {
  inv 1ive11 live
  run runner_reap_orphans live   # 'live' is tracked -> must be spared
  [ "${status}" -eq 0 ]
  [ ! -f "${RM_CAP}" ]
}

@test "reaper removes orphans but spares tracked containers in one sweep" {
  inv keepid keep
  inv goneid gone
  run runner_reap_orphans keep
  [ "${status}" -eq 0 ]
  grep -qxF -- 'goneid' "${RM_CAP}"
  ! grep -qxF -- 'keepid' "${RM_CAP}"
}

@test "reaper is a no-op (exit 0) when no labelled containers exist" {
  run runner_reap_orphans
  [ "${status}" -eq 0 ]
  [ ! -f "${RM_CAP}" ]
}

# --- #107 per-job max lifetime / watchdog -------------------------------------

@test "kill stops then removes the named container and logs it (#107)" {
  # The docker stub records each subcommand it is handed.
  KILL_CAP="${FAKE_RH}/kill.args"
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1 \$2" >> "${KILL_CAP}"
exit 0
EOF
  chmod +x "${STUB}/docker"
  run runner_container_kill gha-jit-hung
  [ "${status}" -eq 0 ]
  # logged the timeout
  [[ "${output}" == *gha-jit-hung* ]]
  grep -qxF -- 'stop gha-jit-hung' "${KILL_CAP}"
  grep -qxF -- 'rm gha-jit-hung'   "${KILL_CAP}"
}

@test "watchdog fires after the timeout and kills the container (#107)" {
  KILL_CAP="${FAKE_RH}/kill.args"
  # docker stub: record stop/rm; report the container as existing for `ps -q`.
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps) echo "gha-jit-hung" ;;             # container still present
  stop|rm) printf '%s\n' "\$1 \$2" >> "${KILL_CAP}" ;;
esac
exit 0
EOF
  chmod +x "${STUB}/docker"
  # Stub sleep so the watchdog's wait is instant (no real delay in the test).
  cat >"${STUB}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${STUB}/sleep"

  run runner_container_watchdog gha-jit-hung 1
  [ "${status}" -eq 0 ]
  # The watchdog saw the container still alive after the timeout -> killed it.
  grep -qxF -- 'stop gha-jit-hung' "${KILL_CAP}"
  grep -qxF -- 'rm gha-jit-hung'   "${KILL_CAP}"
}

@test "watchdog is a no-op when the container already exited (#107)" {
  KILL_CAP="${FAKE_RH}/kill.args"
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps) : ;;                                # container gone (no output)
  stop|rm) printf '%s\n' "\$1 \$2" >> "${KILL_CAP}" ;;
esac
exit 0
EOF
  chmod +x "${STUB}/docker"
  cat >"${STUB}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${STUB}/sleep"

  run runner_container_watchdog gha-jit-done 1
  [ "${status}" -eq 0 ]
  # Container already gone by the deadline -> nothing killed.
  [ ! -f "${KILL_CAP}" ]
}

# --- #106 stale per-job temp-dir pruning --------------------------------------

@test "prune removes a stale jit-* temp dir not tracked (#106)" {
  WR=$(mktemp -d)
  mkdir -p "${WR}/jit-orphan.AAA"
  run runner_prune_temp_dirs "${WR}"   # nothing tracked -> all jit-* are stale
  [ "${status}" -eq 0 ]
  [ ! -d "${WR}/jit-orphan.AAA" ]
  rm -rf "${WR}"
}

@test "prune spares a tracked job's temp dir (#106)" {
  WR=$(mktemp -d)
  mkdir -p "${WR}/jit-live.BBB"
  run runner_prune_temp_dirs "${WR}" live
  [ "${status}" -eq 0 ]
  [ -d "${WR}/jit-live.BBB" ]
  rm -rf "${WR}"
}

@test "prune only touches jit-* dirs, never other entries (#106)" {
  WR=$(mktemp -d)
  mkdir -p "${WR}/jit-gone.CCC" "${WR}/keepme" "${WR}/.bin"
  run runner_prune_temp_dirs "${WR}"
  [ "${status}" -eq 0 ]
  [ ! -d "${WR}/jit-gone.CCC" ]
  [ -d "${WR}/keepme" ]
  [ -d "${WR}/.bin" ]
  rm -rf "${WR}"
}

@test "prune is scoped to the work root: refuses a non-absolute root (#106)" {
  run runner_prune_temp_dirs "relative/path"
  [ "${status}" -ne 0 ]
}

@test "prune refuses a dangerous work root (no rm at /) (#106)" {
  run runner_prune_temp_dirs "/"
  [ "${status}" -ne 0 ]
}

@test "prune never escapes the work root via a job id (#106)" {
  WR=$(mktemp -d)
  # A crafted "tracked" id with traversal must not cause anything outside WR to
  # be touched; the prune only ever globs '<root>/jit-*'.
  OUTSIDE=$(mktemp -d)
  mkdir -p "${OUTSIDE}/jit-evil.DDD"
  run runner_prune_temp_dirs "${WR}" "../$(basename "${OUTSIDE}")/jit-evil"
  [ "${status}" -eq 0 ]
  [ -d "${OUTSIDE}/jit-evil.DDD" ]   # untouched -- prune stayed inside WR
  rm -rf "${WR}" "${OUTSIDE}"
}

@test "reaper filters on our managed-by label" {
  inv idx x
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

# --- SEC: newline-in-job-id-label phantom-row reaper spoof (#137) --------------
#
# An attacker-controlled JobID flows UNSANITIZED into the container's job-id
# label (only the --name is sanitized). With the OLD `ps --format '{{.Names}}
# {{.Label "job-id"}}'` listing, a newline in the label split one attacker
# container into TWO rows, the second naming a victim the reaper would then
# `rm -f` -- bypassing the managed-by/prefix scoping entirely. These tests lock
# the regression: a malicious label can never become a removal target.

@test "reaper reaps by container ID, never by a parsed/streamed name (#137)" {
  # The inventory is container IDs; the removal target the reaper hands `rm`
  # must be exactly that ID -- not any name/label-derived string.
  inv deadbeef orphan
  run runner_reap_orphans
  [ "${status}" -eq 0 ]
  grep -qxF -- 'deadbeef' "${RM_CAP}"
}

@test "reaper does NOT remove a victim forged via a newline in the job-id label (#137)" {
  # One real, managed attacker container (id 'attacker') whose job-id label
  # carries a newline + a victim container name. Under the old code the reaper
  # listed names+labels and the raw newline produced a phantom row naming
  # 'rt-victim'. Model that hostile label exactly: the engine returns it RAW
  # from inspect. The reaper must remove ONLY the real attacker container ID and
  # must NEVER hand 'rt-victim' (an unmanaged, untracked name) to `rm`.
  printf '%s\n' attacker >> "${PS_OUT}"
  printf '%s' $'A\nrt-victim sparetoken'      > "${INSPECT_DIR}/attacker.jobid"
  printf '%s' "${RUNNER_MANAGED_BY}"          > "${INSPECT_DIR}/attacker.managedby"

  run runner_reap_orphans
  [ "${status}" -eq 0 ]
  # The unmanaged victim named inside the label is NEVER removed.
  ! grep -qF -- 'rt-victim' "${RM_CAP}"
}

@test "reaper cannot be made to SPARE an orphan via a newline forging a tracked id (#137)" {
  # Conversely, an attacker container whose label embeds a newline + a TRACKED
  # job id must not let the attacker's own container escape reaping: the
  # tracked-check keys on the real, inspected label value of THIS container, not
  # on a forged second token.
  printf '%s\n' orphanid >> "${PS_OUT}"
  printf '%s' $'untracked\nsomeorphan trackedjob' > "${INSPECT_DIR}/orphanid.jobid"
  printf '%s' "${RUNNER_MANAGED_BY}"              > "${INSPECT_DIR}/orphanid.managedby"

  run runner_reap_orphans trackedjob   # 'trackedjob' is the only spared id
  [ "${status}" -eq 0 ]
  # The orphan's real job-id is 'untracked\n...' != 'trackedjob' -> it is reaped.
  grep -qxF -- 'orphanid' "${RM_CAP}"
}
