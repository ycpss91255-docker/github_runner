#!/usr/bin/env bats
# Smoke tests for schedule-cleanup.sh. We swap out the real `crontab`
# binary with a stub via the CRONTAB_CMD env override so tests stay
# hermetic and do not touch the running user's crontab.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../script/schedule-cleanup.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"

  # Stub crontab. `crontab -l` reads from $FAKE_CRON, `crontab -` writes
  # stdin into it, `crontab -r` deletes it. Matches the subset of
  # behaviour the script uses.
  FAKE_BIN=$(mktemp -d)
  FAKE_CRON="${FAKE_BIN}/crontab.state"
  cat >"${FAKE_BIN}/crontab" <<EOF
#!/usr/bin/env bash
case \${1:-} in
  -l) [[ -f "${FAKE_CRON}" ]] && cat "${FAKE_CRON}" || exit 1 ;;
  -r) rm -f "${FAKE_CRON}" ;;
  -)  cat >"${FAKE_CRON}" ;;
  *)  exit 99 ;;
esac
EOF
  chmod +x "${FAKE_BIN}/crontab"
  export CRONTAB_CMD="${FAKE_BIN}/crontab"
}

teardown() {
  rm -rf "${FAKE_RH}" "${FAKE_BIN}"
}

@test "schedule-cleanup.sh --help exits 0 with usage" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "schedule-cleanup.sh unknown option exits non-zero" {
  run "${SCRIPT}" --bogus
  [ "${status}" -ne 0 ]
}

@test "schedule-cleanup.sh --status with no installed entry prints (none)" {
  run "${SCRIPT}" --status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"(none)"* ]]
}

@test "schedule-cleanup.sh --install weekly Sun 03:30 writes the expected entry" {
  run "${SCRIPT}" --install --every weekly --at 03:30 --day Sun
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Installed"* ]]
  [ -f "${FAKE_CRON}" ]

  # Sat is 6, Sun is 0 -- the prefix encodes that as DOW 0.
  grep -q '^30 3 \* \* 0 ' "${FAKE_CRON}"
  grep -q 'flock -n .*\.cleanup\.lock' "${FAKE_CRON}"
  grep -q 'script/cleanup\.sh --yes' "${FAKE_CRON}"
  grep -q '# github_runner cleanup' "${FAKE_CRON}"
}

@test "schedule-cleanup.sh --install daily ignores --day" {
  run "${SCRIPT}" --install --every daily --at 04:00
  [ "${status}" -eq 0 ]
  # `daily` schedule uses '* * *' for dom/mon/dow.
  grep -q '^0 4 \* \* \* ' "${FAKE_CRON}"
}

@test "schedule-cleanup.sh --install monthly fires on day-of-month 1" {
  run "${SCRIPT}" --install --every monthly --at 05:30
  [ "${status}" -eq 0 ]
  grep -q '^30 5 1 \* \* ' "${FAKE_CRON}"
}

@test "schedule-cleanup.sh --install replaces a previous entry instead of stacking" {
  cat >"${FAKE_CRON}" <<'EOF'
0 7 * * * unrelated-job
0 4 * * 0 old-cleanup # github_runner cleanup
EOF

  run "${SCRIPT}" --install --every weekly --at 03:30 --day Sun
  [ "${status}" -eq 0 ]

  # Only one cleanup entry, and the unrelated line survives.
  [ "$(grep -c '# github_runner cleanup' "${FAKE_CRON}")" -eq 1 ]
  grep -q 'unrelated-job' "${FAKE_CRON}"
  grep -q '^30 3 \* \* 0 ' "${FAKE_CRON}"
}

@test "schedule-cleanup.sh --install rejects bad --at" {
  run "${SCRIPT}" --install --every daily --at 25:00
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid --at"* ]]
}

@test "schedule-cleanup.sh --install rejects bad --every" {
  run "${SCRIPT}" --install --every yearly --at 03:30
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid --every"* ]]
}

@test "schedule-cleanup.sh --install rejects bad --day" {
  run "${SCRIPT}" --install --every weekly --at 03:30 --day funday
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid --day"* ]]
}

@test "schedule-cleanup.sh --status echoes the installed entry" {
  "${SCRIPT}" --install --every weekly --at 03:30 --day Sun >/dev/null

  run "${SCRIPT}" --status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"github_runner cleanup"* ]]
}

@test "schedule-cleanup.sh --uninstall removes only the marked entry" {
  cat >"${FAKE_CRON}" <<'EOF'
0 7 * * * unrelated-job
30 3 * * 0 flock -n /tmp/.cleanup.lock -c '/tmp/cleanup.sh --yes' # github_runner cleanup
EOF

  run "${SCRIPT}" --uninstall
  [ "${status}" -eq 0 ]
  [ -f "${FAKE_CRON}" ]
  ! grep -q '# github_runner cleanup' "${FAKE_CRON}"
  grep -q 'unrelated-job' "${FAKE_CRON}"
}

@test "schedule-cleanup.sh --uninstall with no entry is a no-op" {
  cat >"${FAKE_CRON}" <<'EOF'
0 7 * * * unrelated-job
EOF

  run "${SCRIPT}" --uninstall
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Nothing to do"* ]]
  # Unrelated content untouched.
  grep -q 'unrelated-job' "${FAKE_CRON}"
}

@test "schedule-cleanup.sh --uninstall when only entry was ours wipes the crontab" {
  cat >"${FAKE_CRON}" <<'EOF'
30 3 * * 0 flock -n /tmp/.cleanup.lock -c '/tmp/cleanup.sh --yes' # github_runner cleanup
EOF

  run "${SCRIPT}" --uninstall
  [ "${status}" -eq 0 ]
  # `crontab -r` removed the file.
  [ ! -f "${FAKE_CRON}" ]
}

@test "schedule-cleanup.sh requires cleanup.sh to be executable" {
  # Point CLEANUP_BIN at a non-executable file by temporarily neutering
  # the real cleanup.sh script's permission bit inside a scratch checkout.
  STAGE=$(mktemp -d)
  cp -r "${BATS_TEST_DIRNAME}/../../script" "${STAGE}/"
  cp -r "${BATS_TEST_DIRNAME}/../../lib" "${STAGE}/"
  chmod -x "${STAGE}/script/cleanup.sh"

  run "${STAGE}/script/schedule-cleanup.sh" --install --every daily --at 03:30
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"not executable"* ]]

  rm -rf "${STAGE}"
}

@test "schedule-cleanup --install produces no leading blank line in a fresh crontab" {
  # B3: a here-string of an empty crontab used to persist a stray first line.
  run "${SCRIPT}" --install --every daily --at 04:00
  [ "${status}" -eq 0 ]
  head -1 "${FAKE_CRON}" | grep -q '^0 4 \* \* \* '
}

@test "schedule-cleanup parse_time zero-pads single-digit hours" {
  # schedule-cleanup.sh guards `main "$@"` and resolves common.sh via
  # ${BASH_SOURCE[0]}, so it sources cleanly here to unit-test parse_time --
  # no copy-and-strip probe needed.
  source "${SCRIPT}"
  run parse_time "3:05"
  [ "${status}" -eq 0 ]
  [ "${output}" = '03:05' ]
}

@test "schedule-cleanup --install --dry-run does not mutate the crontab" {
  run "${SCRIPT}" --install --every daily --at 04:00 --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Dry-run"* ]]
  [[ "${output}" == *"0 4 * * *"* ]]
  # No crontab written: the stub only creates the state file on `crontab -`.
  [ ! -f "${FAKE_CRON}" ]
}

@test "schedule-cleanup --uninstall --dry-run leaves the marked entry in place" {
  cat >"${FAKE_CRON}" <<'EOF'
0 7 * * * unrelated-job
30 3 * * 0 flock -n /tmp/.cleanup.lock -c '/tmp/cleanup.sh --yes' # github_runner cleanup
EOF

  run "${SCRIPT}" --uninstall --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Dry-run"* ]]
  # Crontab untouched: the marked entry is still present.
  grep -q '# github_runner cleanup' "${FAKE_CRON}"
  grep -q 'unrelated-job' "${FAKE_CRON}"
}
