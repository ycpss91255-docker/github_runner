#!/usr/bin/env bats
# Smoke tests for the --runner-home <path> CLI option (#76).
#
# common.sh is sourced at the top of every script while the script's raw CLI
# args ($@) are still its positional parameters -- BEFORE the per-script arg
# parser runs in main(). common.sh scans "$@" there for --runner-home <path>,
# lets it override RUNNER_HOME (precedence: option > env > default), strips the
# consumed flag from the positional params so each script's own parser never
# sees it, and keeps the SEC-3 lexical checks below as the single validation
# chokepoint (a bad path from the flag is refused exactly like a bad env value).
#
# The `bash -c "<cmds>" bash <args...>` form makes <args...> the sourced
# positional parameters ($@), mirroring how a real script is invoked.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
  # Each test controls precedence explicitly, so start from a clean slate.
  unset RUNNER_HOME
}

@test "--runner-home <path> sets RUNNER_HOME" {
  run bash -c "source '${LIB}'; printf '%s' \"\${RUNNER_HOME}\"" \
    bash --runner-home /tmp/opt-home
  [ "${status}" -eq 0 ]
  [ "${output}" = "/tmp/opt-home" ]
}

@test "--runner-home takes precedence over the RUNNER_HOME env var" {
  export RUNNER_HOME=/tmp/env-home
  run bash -c "source '${LIB}'; printf '%s' \"\${RUNNER_HOME}\"" \
    bash --runner-home /tmp/opt-home
  [ "${status}" -eq 0 ]
  [ "${output}" = "/tmp/opt-home" ]
}

@test "--runner-home takes precedence over the default when no env is set" {
  run bash -c "source '${LIB}'; printf '%s' \"\${RUNNER_HOME}\"" \
    bash --runner-home /tmp/opt-home
  [ "${status}" -eq 0 ]
  [ "${output}" = "/tmp/opt-home" ]
}

@test "RUNNER_HOME env var is still honored when no option is given" {
  export RUNNER_HOME=/tmp/env-home
  run bash -c "source '${LIB}'; printf '%s' \"\${RUNNER_HOME}\"" bash
  [ "${status}" -eq 0 ]
  [ "${output}" = "/tmp/env-home" ]
}

@test "RUNNER_HOME falls back to <repo>/runners when neither option nor env is set" {
  run bash -c "source '${LIB}'; printf '%s' \"\${RUNNER_HOME}\"" bash
  [ "${status}" -eq 0 ]
  [[ "${output}" == */runners ]]
}

# SEC-3: the lexical safety checks in common.sh stay the single chokepoint --
# a dangerous path supplied via --runner-home is refused exactly like a
# dangerous RUNNER_HOME env value.

@test "--runner-home / is refused by SEC-3" {
  run bash -c "source '${LIB}'" bash --runner-home /
  [ "${status}" -ne 0 ]
  [[ "${output}" == *refusing* ]]
}

@test "--runner-home with a relative path is refused by SEC-3" {
  run bash -c "source '${LIB}'" bash --runner-home runners
  [ "${status}" -ne 0 ]
  [[ "${output}" == *absolute* ]]
}

@test "--runner-home containing .. is refused by SEC-3" {
  run bash -c "source '${LIB}'" bash --runner-home /tmp/x/../y
  [ "${status}" -ne 0 ]
  [[ "${output}" == *normalized* ]]
}

@test "--runner-home without a value fails" {
  run bash -c "source '${LIB}'" bash --runner-home
  [ "${status}" -ne 0 ]
}

@test "the consumed --runner-home flag is stripped from the positional params" {
  # A non-existent absolute path is accepted (first install), so SEC-3 passes
  # and we can observe the remaining args the script's own parser would see.
  run bash -c "source '${LIB}'; printf '%s' \"\$*\"" \
    bash --runner-home /tmp/opt-home -w -c
  [ "${status}" -eq 0 ]
  [ "${output}" = "-w -c" ]
}
