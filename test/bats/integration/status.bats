#!/usr/bin/env bats
# Smoke tests for status.sh.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../script/status.sh"
  FAKE_RH=$(mktemp -d)
  # Point RUNNER_HOME at a non-existent subdir so the "missing dir" branch
  # fires; tests that want an empty dir create RUNNER_HOME explicitly.
  export RUNNER_HOME="${FAKE_RH}/runners"
}

teardown() {
  rm -rf "${FAKE_RH}"
}

# The rendering helpers (collect_rows / setup_colors / state_color) are unit-
# tested by sourcing status.sh directly: its `main "$@"` is guarded by
# `[[ "${BASH_SOURCE[0]:-}" == "${0}" ]]` so sourcing defines the functions
# without bootstrapping, and it resolves common.sh via ${BASH_SOURCE[0]} so
# the source works whether the script is run or sourced. The shadows
# (systemctl, _gh) are then in scope for collect_rows exactly as
# service.bats / github_api.bats shadow the same names.

@test "status.sh missing RUNNER_HOME directory -> exits 0 with message" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"./script/init.sh"* ]]
}

@test "status.sh on empty RUNNER_HOME prints the no-runners notice and zero data rows" {
  # D6: assert the behavior (no-runners notice + no per-runner state cells)
  # rather than just the header vocabulary, which can't tell empty from
  # populated.
  mkdir -p "${RUNNER_HOME}"
  run "${SCRIPT}" --no-color
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"(no runners found in ${RUNNER_HOME})"* ]]
  [ "$(printf '%s\n' "${output}" | grep -cE 'public-ok|public-BLOCKED|online|offline|not-found')" -eq 0 ]
}

@test "status.sh accepts -i as the interval flag" {
  # U1: -i replaced -n for --interval. Missing RUNNER_HOME -> exits 0 cleanly.
  run "${SCRIPT}" -i 5
  [ "${status}" -eq 0 ]
}

@test "status.sh no longer accepts -n (frees it from the cross-script collision)" {
  run "${SCRIPT}" -n 5
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown option: -n"* ]]
}

@test "collect_rows renders an online org runner: running/online/public-ok/gate-ok/labels" {
  mkdir -p "${RUNNER_HOME}/acme/_org"
  printf '{\n"agentName": "host-acme-org"\n}\n' > "${RUNNER_HOME}/acme/_org/.runner"
  source "${SCRIPT}"
  # service loaded for this exact unit name -> svc 'running'
  systemctl() { printf '  actions.runner.acme.host-acme-org.service loaded active running\n'; }
  # status verb sees a matching runner (rc 0); runner-group dispatch enabled;
  # fork-PR approval gate set to the safe policy -> gate-ok.
  _gh() {
    case " $* " in
      *runner-groups*)                 printf 'true\n' ;;
      *fork-pr-contributor-approval*)  printf 'all_external_contributors\n' ;;
      *)                               printf 'online\tgpu,cuda12\n' ;;
    esac
  }
  setup_colors
  run collect_rows
  [ "${status}" -eq 0 ]
  [ "${output}" = $'host-acme-org\torg\trunning\tonline\tpublic-ok\tgate-ok\tgpu,cuda12' ]
}

@test "collect_rows maps github_runner_status rc=2 to 'not-found'" {
  mkdir -p "${RUNNER_HOME}/acme/_org"
  printf '{\n"agentName": "host-acme-org"\n}\n' > "${RUNNER_HOME}/acme/_org/.runner"
  source "${SCRIPT}"
  systemctl() { printf '  ssh.service loaded active running\n'; }   # not running
  # status verb: call succeeds but empty (no match) -> github_runner_status rc 2.
  # fork-PR gate is a weak (non-safe) policy -> gate-WEAK.
  _gh() {
    case " $* " in
      *runner-groups*)                 printf 'false\n' ;;
      *fork-pr-contributor-approval*)  printf 'first_time_contributors\n' ;;
      *)                               printf '' ;;
    esac
  }
  setup_colors
  run collect_rows
  [ "${status}" -eq 0 ]
  [ "${output}" = $'host-acme-org\torg\tstopped\tnot-found\tpublic-BLOCKED\tgate-WEAK\t-' ]
}

@test "collect_rows maps github_runner_status rc=1/other to 'n/a'" {
  mkdir -p "${RUNNER_HOME}/acme/_org"
  printf '{\n"agentName": "host-acme-org"\n}\n' > "${RUNNER_HOME}/acme/_org/.runner"
  source "${SCRIPT}"
  systemctl() { printf '  ssh.service loaded active running\n'; }
  # status verb: the gh call itself fails -> github_runner_status rc 1.
  # runner-group + fork-PR lookups also fail -> public_state / gate 'n/a'.
  _gh() { return 1; }
  setup_colors
  run collect_rows
  [ "${status}" -eq 0 ]
  [ "${output}" = $'host-acme-org\torg\tstopped\tn/a\tn/a\tn/a\t-' ]
}

@test "collect_rows gives a repo-scoped runner public-dispatch '-' and approval-gate '-' (no runner-group flag)" {
  mkdir -p "${RUNNER_HOME}/acme/myrepo"
  printf '{\n"agentName": "host-acme-repo"\n}\n' > "${RUNNER_HOME}/acme/myrepo/.runner"
  source "${SCRIPT}"
  systemctl() { printf '  actions.runner.acme.host-acme-repo.service loaded active running\n'; }
  # Neither the runner-group flag nor the org fork-PR gate must be consulted
  # for repo scope; return values that would surface as public-ok / gate-ok so
  # a regression that queried them is caught.
  _gh() {
    case " $* " in
      *runner-groups*)                 printf 'true\n' ;;
      *fork-pr-contributor-approval*)  printf 'all_external_contributors\n' ;;
      *)                               printf 'online\tgpu\n' ;;
    esac
  }
  setup_colors
  run collect_rows
  [ "${status}" -eq 0 ]
  [ "${output}" = $'host-acme-repo\trepo\trunning\tonline\t-\t-\tgpu' ]
}

@test "setup_colors/state_color emit empty codes under --no-color and real SGR under COLOR=always" {
  source "${SCRIPT}"
  _probe() {
    COLOR=never;  setup_colors; local nocolor=$(state_color online); local ansi_off=${USE_ANSI}
    COLOR=always; setup_colors; local color=$(state_color online);   local ansi_on=${USE_ANSI}
    printf 'no=[%s] ansi_off=%s ansi_on=%s\n' "${nocolor}" "${ansi_off}" "${ansi_on}"
    # render the always-on code as visible bytes so the escape is assertable.
    printf 'always=' ; printf '%s' "${color}" | od -An -tx1 | tr -d ' \n'; printf '\n'
  }
  run _probe
  [ "${status}" -eq 0 ]
  # --no-color: no SGR bytes, and USE_ANSI is 0 (the clear-screen gate is off);
  # COLOR=always flips the same gate to 1.
  [[ "${output}" == *"no=[] ansi_off=0 ansi_on=1"* ]]
  # COLOR=always: green SGR is ESC [ 3 2 m == 1b 5b 33 32 6d.
  [[ "${output}" == *"always=1b5b33326d"* ]]
}

# --- #52: health-check (--check) + machine-readable output (--json) ---------

@test "count_unhealthy counts a stopped/offline runner (#52)" {
  source "${SCRIPT}"
  # rows: one healthy, one with a stopped service, one offline on GitHub.
  local rows
  rows=$'r1\torg\trunning\tonline\tpublic-ok\tgate-ok\tgpu'
  rows+=$'\nr2\torg\tstopped\tonline\tpublic-ok\tgate-ok\tgpu'
  rows+=$'\nr3\trepo\trunning\toffline\t-\t-\tgpu'
  run count_unhealthy "${rows}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "2" ]
}

@test "emit_json renders one object per runner with the expected fields (#52)" {
  source "${SCRIPT}"
  local rows=$'host-acme-org\torg\trunning\tonline\tpublic-ok\tgate-ok\tgpu,cuda12'
  run emit_json "${rows}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == '['*']' ]]
  [[ "${output}" == *'"name":"host-acme-org"'* ]]
  [[ "${output}" == *'"github":"online"'* ]]
  [[ "${output}" == *'"approval_gate":"gate-ok"'* ]]
  [[ "${output}" == *'"labels":"gpu,cuda12"'* ]]
}

@test "status.sh --json on empty RUNNER_HOME emits [] and exits 0 (#52)" {
  mkdir -p "${RUNNER_HOME}"
  run "${SCRIPT}" --json
  [ "${status}" -eq 0 ]
  [ "${output}" = "[]" ]
}

@test "status.sh --check exits non-zero when a runner is unhealthy (#52)" {
  mkdir -p "${RUNNER_HOME}/acme/_org"
  printf '{\n"agentName": "host-acme-org"\n}\n' > "${RUNNER_HOME}/acme/_org/.runner"
  STUB=$(mktemp -d)
  # systemctl reports an unrelated unit -> the runner's service is NOT running.
  printf '#!/bin/sh\necho "  ssh.service loaded active running"\n' > "${STUB}/systemctl"
  cat > "${STUB}/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *runner-groups*)                printf 'true\n' ;;
  *fork-pr-contributor-approval*) printf 'all_external_contributors\n' ;;
  *)                              printf 'online\tgpu\n' ;;
esac
EOF
  chmod +x "${STUB}/systemctl" "${STUB}/gh"
  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --check --no-color
  rm -rf "${STUB}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unhealthy"* ]]
}

@test "status.sh --check exits 0 when every runner is healthy (#52)" {
  mkdir -p "${RUNNER_HOME}/acme/_org"
  printf '{\n"agentName": "host-acme-org"\n}\n' > "${RUNNER_HOME}/acme/_org/.runner"
  STUB=$(mktemp -d)
  # systemctl reports the runner's own unit active -> service running.
  printf '#!/bin/sh\necho "  actions.runner.acme.host-acme-org.service loaded active running"\n' > "${STUB}/systemctl"
  cat > "${STUB}/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *runner-groups*)                printf 'true\n' ;;
  *fork-pr-contributor-approval*) printf 'all_external_contributors\n' ;;
  *)                              printf 'online\tgpu\n' ;;
esac
EOF
  chmod +x "${STUB}/systemctl" "${STUB}/gh"
  run env PATH="${STUB}:${PATH}" "${SCRIPT}" --check --no-color
  rm -rf "${STUB}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"all runners healthy"* ]]
}
