#!/usr/bin/env bats
# Smoke tests for cleanup.sh argument parsing and the dry-run / no-op /
# non-TTY paths, plus enumeration of the three prunable categories.
# Mutating paths that actually rm are exercised via --dry-run; we assert
# the files stay in place.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../script/cleanup.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

# Build a fake configured runner dir for $1=org, with active version $2.
# Drops a `.runner` marker, `bin -> bin.$2`, `externals -> externals.$2`,
# and matching version dirs.
fake_runner() {
  local org=$1 ver=$2
  local d="${FAKE_RH}/${org}/_org"
  mkdir -p "${d}/bin.${ver}" "${d}/externals.${ver}" "${d}/_work"
  touch "${d}/.runner"
  ln -s "bin.${ver}" "${d}/bin"
  ln -s "externals.${ver}" "${d}/externals"
}

@test "cleanup.sh --help exits 0 with usage" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "cleanup.sh unknown option exits non-zero" {
  run "${SCRIPT}" --bogus
  [ "${status}" -ne 0 ]
}

@test "cleanup.sh missing RUNNER_HOME exits 0 with no-op message" {
  rm -rf "${FAKE_RH}"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
}

@test "cleanup.sh empty RUNNER_HOME exits 0 with no-op message" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
}

@test "cleanup.sh prunes the history store by the age cap (#127 wired into scheduled cleanup)" {
  # A per-job archive far past the age cap must be evicted by a scheduled run,
  # even when there are NO runner artifacts to clean (history prune runs first,
  # independent of the runner-artifact prune).
  mkdir -p "${RUNNER_HOME}/history/jobs/job-old"
  touch -d '2020-01-01' "${RUNNER_HOME}/history/jobs/job-old"
  RUNNER_HISTORY_MAX_DAYS=1 RUNNER_HISTORY_MAX_GB=1000 run "${SCRIPT}" --yes
  [ "${status}" -eq 0 ]
  [ ! -d "${RUNNER_HOME}/history/jobs/job-old" ]
}

@test "cleanup.sh --dry-run previews history eviction but removes nothing (#127)" {
  mkdir -p "${RUNNER_HOME}/history/jobs/job-old"
  touch -d '2020-01-01' "${RUNNER_HOME}/history/jobs/job-old"
  RUNNER_HISTORY_MAX_DAYS=1 run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [ -d "${RUNNER_HOME}/history/jobs/job-old" ]
}

@test "cleanup.sh ignores the active bin.X / externals.X dirs" {
  fake_runner myorg 2.334.0
  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
  [ -d "${FAKE_RH}/myorg/_org/bin.2.334.0" ]
}

@test "cleanup.sh lists stale bin.X / externals.X under --dry-run and leaves them" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/bin.2.319.1" "${FAKE_RH}/myorg/_org/externals.2.319.1"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"stale myorg/_org -> bin.2.319.1"* ]]
  [[ "${output}" == *"stale myorg/_org -> externals.2.319.1"* ]]
  [[ "${output}" == *"Dry-run; nothing removed."* ]]
  [ -d "${FAKE_RH}/myorg/_org/bin.2.319.1" ]
  [ -d "${FAKE_RH}/myorg/_org/externals.2.319.1" ]
}

@test "cleanup.sh with a missing bin symlink keeps version dirs but still prunes _update remnants (#50)" {
  # Half-extracted runner: .runner + version dirs present, but NO `bin`
  # symlink, so runner_active_version is empty. cleanup must NOT treat the
  # only bin.X / externals.X as stale (that would delete the in-use version);
  # the safe _work/_update remnant pruning still runs.
  local d="${FAKE_RH}/myorg/_org"
  mkdir -p "${d}/bin.2.334.0" "${d}/externals.2.334.0" "${d}/_work/_update"
  touch "${d}/.runner" "${d}/_work/_update.sh"
  # deliberately no `ln -s bin.2.334.0 "${d}/bin"`

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  # The in-use version dirs must NOT be listed as stale.
  [[ "${output}" != *"stale myorg/_org -> bin.2.334.0"* ]]
  [[ "${output}" != *"stale myorg/_org -> externals.2.334.0"* ]]
  # But the safe _work/_update remnants are still pruned.
  [[ "${output}" == *"self-update remnant myorg/_org/_work/_update/"* ]]
  [[ "${output}" == *"self-update remnant myorg/_org/_work/_update.sh"* ]]
  [ -d "${d}/bin.2.334.0" ]
  [ -d "${d}/externals.2.334.0" ]
}

@test "cleanup.sh lists _work/_update remnants under --dry-run and leaves them" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/_work/_update"
  touch "${FAKE_RH}/myorg/_org/_work/_update.sh"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"self-update remnant myorg/_org/_work/_update/"* ]]
  [[ "${output}" == *"self-update remnant myorg/_org/_work/_update.sh"* ]]
  [ -d "${FAKE_RH}/myorg/_org/_work/_update" ]
  [ -f "${FAKE_RH}/myorg/_org/_work/_update.sh" ]
}

@test "cleanup.sh keeps highest cached tarball and drops older ones (dry-run)" {
  mkdir -p "${FAKE_RH}/.bin"
  touch "${FAKE_RH}/.bin/actions-runner-linux-x64-2.319.1.tar.gz"
  touch "${FAKE_RH}/.bin/actions-runner-linux-x64-2.330.0.tar.gz"
  touch "${FAKE_RH}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"old cached tarball actions-runner-linux-x64-2.319.1.tar.gz"* ]]
  [[ "${output}" == *"old cached tarball actions-runner-linux-x64-2.330.0.tar.gz"* ]]
  [[ "${output}" != *"old cached tarball actions-runner-linux-x64-2.334.0.tar.gz"* ]]
}

@test "cleanup.sh with a single cached tarball reports no-op" {
  mkdir -p "${FAKE_RH}/.bin"
  touch "${FAKE_RH}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
}

@test "cleanup.sh without --yes in non-TTY context exits 1" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/bin.2.319.1"

  # bats's run inherits a non-TTY stdin -- the path we want to exercise.
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"non-interactive run requires --yes"* ]]
}

@test "cleanup.sh --yes actually removes the stale items" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/bin.2.319.1" \
           "${FAKE_RH}/myorg/_org/externals.2.319.1" \
           "${FAKE_RH}/myorg/_org/_work/_update" \
           "${FAKE_RH}/.bin"
  touch "${FAKE_RH}/myorg/_org/_work/_update.sh" \
        "${FAKE_RH}/.bin/actions-runner-linux-x64-2.319.1.tar.gz" \
        "${FAKE_RH}/.bin/actions-runner-linux-x64-2.334.0.tar.gz"

  run "${SCRIPT}" --yes
  [ "${status}" -eq 0 ]
  # D8: exact summary (5 prunable items: stale bin + externals + _update dir +
  # _update.sh + old tarball). A loose "0 failed" substring also matches
  # "10 failed"; the precise count catches an over/under-prune regression.
  [[ "${output}" == *"Summary: 5 removed, 0 failed."* ]]

  [ ! -e "${FAKE_RH}/myorg/_org/bin.2.319.1" ]
  [ ! -e "${FAKE_RH}/myorg/_org/externals.2.319.1" ]
  [ ! -e "${FAKE_RH}/myorg/_org/_work/_update" ]
  [ ! -e "${FAKE_RH}/myorg/_org/_work/_update.sh" ]
  [ ! -e "${FAKE_RH}/.bin/actions-runner-linux-x64-2.319.1.tar.gz" ]

  # The active version dirs / symlinks and the highest cached tarball
  # must survive.
  [ -d "${FAKE_RH}/myorg/_org/bin.2.334.0" ]
  [ -d "${FAKE_RH}/myorg/_org/externals.2.334.0" ]
  [ -L "${FAKE_RH}/myorg/_org/bin" ]
  [ -L "${FAKE_RH}/myorg/_org/externals" ]
  [ -f "${FAKE_RH}/.bin/actions-runner-linux-x64-2.334.0.tar.gz" ]
}

@test "cleanup.sh --work-caches prunes old _tool/_actions on an idle runner, keeps recent (#58)" {
  fake_runner myorg 2.334.0
  local d="${FAKE_RH}/myorg/_org"
  mkdir -p "${d}/_work/_tool/node_old" "${d}/_work/_tool/node_new" \
           "${d}/_work/_actions/act_old"
  touch -t 202001010000 "${d}/_work/_tool/node_old" "${d}/_work/_actions/act_old"
  # idle: pgrep finds no Runner.Worker -> runner_busy returns false.
  local STUB; STUB=$(mktemp -d)
  printf '#!/bin/sh\nexit 1\n' > "${STUB}/pgrep"
  chmod +x "${STUB}/pgrep"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --work-caches --dry-run
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"stale _work/_tool myorg/_org/node_old"* ]]
  [[ "${output}" == *"stale _work/_actions myorg/_org/act_old"* ]]
  [[ "${output}" != *"node_new"* ]]
  [ -d "${d}/_work/_tool/node_old" ]   # dry-run leaves it
}

@test "cleanup.sh --work-caches skips a busy runner and leaves its caches (#58)" {
  fake_runner myorg 2.334.0
  local d="${FAKE_RH}/myorg/_org"
  mkdir -p "${d}/_work/_tool/node_old"
  touch -t 202001010000 "${d}/_work/_tool/node_old"
  # busy: pgrep reports a Runner.Worker running under this runner's bin/.
  local STUB; STUB=$(mktemp -d)
  cat > "${STUB}/pgrep" <<EOF
#!/bin/sh
echo "4242 ${d}/bin/Runner.Worker spawnclient 1 2"
EOF
  chmod +x "${STUB}/pgrep"

  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --work-caches --dry-run
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"running a job; skipping its _work caches"* ]]
  [[ "${output}" != *"stale _work/_tool"* ]]
}

@test "cleanup.sh without --work-caches never enumerates _work caches (#58)" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/_work/_tool/node_old"
  touch -t 202001010000 "${FAKE_RH}/myorg/_org/_work/_tool/node_old"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"_work/_tool"* ]]
  [[ "${output}" == *"Nothing to clean"* ]]
}

@test "cleanup.sh rotates _diag logs older than the retention window, keeps recent ones (#55)" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/_diag"
  # An old log (Jan 2020) is well past the 14-day window; a fresh one is not.
  touch -t 202001010000 "${FAKE_RH}/myorg/_org/_diag/Worker_old.log"
  touch "${FAKE_RH}/myorg/_org/_diag/Worker_recent.log"

  run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"old _diag log myorg/_org/Worker_old.log"* ]]
  [[ "${output}" != *"Worker_recent.log"* ]]
  # Dry-run leaves both in place.
  [ -f "${FAKE_RH}/myorg/_org/_diag/Worker_old.log" ]
  [ -f "${FAKE_RH}/myorg/_org/_diag/Worker_recent.log" ]
}

@test "cleanup.sh reports disk usage and warns at/above the threshold (#55)" {
  mkdir -p "${FAKE_RH}"
  # Force the warning deterministically regardless of the host's real usage.
  RUNNER_DISK_WARN_PCT=0 run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"disk: "* ]]
  [[ "${output}" == *"WARN: at/above 0%"* ]]
  [[ "${output}" == *"--work-caches"* ]]
}

@test "cleanup.sh disk report stays quiet below the threshold (#55)" {
  mkdir -p "${FAKE_RH}"
  RUNNER_DISK_WARN_PCT=101 run "${SCRIPT}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"disk: "* ]]
  [[ "${output}" != *"WARN: at/above"* ]]
}

@test "disk_usage_percent returns an integer for an existing path (#55)" {
  source "${SCRIPT}"
  run disk_usage_percent /tmp
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ ^[0-9]+$ ]]
}

@test "cleanup.sh does not rm through an interior _work symlink under the ephemeral work/ tree (#144 rm-safety)" {
  # Hostile-job vector: the per-job container bind-mounts RUNNER_HOME/work/jit-*
  # RW, so a job plants a fake .runner marker there and replaces _work with a
  # symlink that escapes RUNNER_HOME. The scheduled `cleanup.sh --yes` must NOT
  # follow that interior symlink and delete a victim outside RUNNER_HOME.
  local victim; victim=$(mktemp -d)
  mkdir -p "${victim}/_update"
  touch "${victim}/_update.sh"

  local jit="${FAKE_RH}/work/jit-evil.AbCdef"
  mkdir -p "${jit}"
  touch "${jit}/.runner"
  ln -s "${victim}" "${jit}/_work"

  run "${SCRIPT}" --yes
  # The victim outside RUNNER_HOME must survive untouched.
  [ -d "${victim}/_update" ]
  [ -f "${victim}/_update.sh" ]
  rm -rf "${victim}"
}

@test "cleanup.sh refuses an interior _work symlink on an enumerated runner (#144 rm-safety)" {
  # Even a normally-enumerated runner dir (not under work/) whose _work was
  # turned into a host-absolute symlink must not steer rm outside RUNNER_HOME:
  # the rm site canonicalizes + anchors under RUNNER_HOME before deleting.
  local victim; victim=$(mktemp -d)
  mkdir -p "${victim}/_update"
  local d="${FAKE_RH}/myorg/_org"
  mkdir -p "${d}"
  touch "${d}/.runner"
  ln -s "${victim}" "${d}/_work"

  run "${SCRIPT}" --yes
  [ -d "${victim}/_update" ]
  rm -rf "${victim}"
}

@test "cleanup.sh --yes a second time finds nothing to clean (idempotent)" {
  fake_runner myorg 2.334.0
  mkdir -p "${FAKE_RH}/myorg/_org/bin.2.319.1"
  "${SCRIPT}" --yes >/dev/null
  run "${SCRIPT}" --yes
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to clean"* ]]
}
