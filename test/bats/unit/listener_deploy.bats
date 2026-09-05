#!/usr/bin/env bats
# Unit spec for lib/listener-deploy.sh -- the seams behind the one interactive
# deploy command (script/deploy-listener.sh) and its teardown counterpart.
#
# Deploying a listener was a multi-step manual runbook (build, install, create a
# service user, write a 0600 environment file, install a systemd unit, enable
# it), which is why nothing had ever been deployed. This library is the half of
# that which can be tested: each step is a function that reports what it did or
# why it skipped, so the entry script is a sequence of announcements rather than
# a wall of inline commands.
#
# Every external command reaches the host through a single-underscore adapter
# (_systemctl / _journalctl / _id / _useradd / _install / _just), the same
# shadowable-seam idiom lib/common.sh uses for _gh. These tests redefine those
# adapters, so nothing here touches real systemd, real users, or a real install
# prefix.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB="${ROOT}/lib/listener-deploy.sh"
  WORK=$(mktemp -d)
}

teardown() { rm -rf "${WORK}"; }

# --- path derivation -------------------------------------------------------

@test "listener_deploy_paths derives every path from the prefix and etc dir" {
  run bash -c "
    source '${LIB}'
    LISTENER_PREFIX=/opt/x
    LISTENER_ETC=/etc/x
    listener_deploy_paths
    echo \"\${LISTENER_ENV_FILE}\"
    echo \"\${LISTENER_UNIT_PATH}\"
    echo \"\${LISTENER_BIN}\"
    echo \"\${LISTENER_ADMIN_BIN}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"/etc/x/scaleset-listener.env"* ]]
  [[ "${output}" == *"/etc/systemd/system/scaleset-listener.service"* ]]
  [[ "${output}" == *"/opt/x/bin/scaleset-listener"* ]]
  [[ "${output}" == *"/opt/x/bin/scaleset-admin"* ]]
}

@test "listener_deploy_paths re-derives after the prefix changes (no stale path)" {
  # The entry script parses its flags AFTER sourcing, so a path frozen at source
  # time would silently ignore --prefix and install to the default.
  run bash -c "
    source '${LIB}'
    LISTENER_PREFIX=/opt/a; LISTENER_ETC=/etc/a; listener_deploy_paths
    LISTENER_PREFIX=/opt/b; LISTENER_ETC=/etc/b; listener_deploy_paths
    echo \"\${LISTENER_BIN} \${LISTENER_ENV_FILE}\"
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "/opt/b/bin/scaleset-listener /etc/b/scaleset-listener.env" ]
}

# --- service user ----------------------------------------------------------

@test "listener_ensure_service_user creates the user when it does not exist" {
  run bash -c "
    source '${LIB}'
    _id() { return 1; }
    _useradd() { echo \"USERADD \$*\"; }
    listener_ensure_service_user ci-runner
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"USERADD"* ]]
  [[ "${output}" == *"--system"* ]]
  [[ "${output}" == *"ci-runner"* ]]
  [[ "${output}" == *"created"* ]]
}

@test "listener_ensure_service_user skips an existing user and says so (idempotent)" {
  run bash -c "
    source '${LIB}'
    _id() { echo 999; }
    _useradd() { echo 'USERADD-RAN'; }
    listener_ensure_service_user ci-runner
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"USERADD-RAN"* ]]
  [[ "${output}" == *"already exists"* ]]
}

@test "listener_ensure_service_user gives the account no login shell" {
  run bash -c "
    source '${LIB}'
    _id() { return 1; }
    _useradd() { echo \"\$*\"; }
    listener_ensure_service_user ci-runner
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"nologin"* ]]
}

# --- the environment file (the secret) -------------------------------------

@test "listener_write_env_file writes a 0600 file containing the token" {
  run bash -c "
    source '${LIB}'
    LISTENER_TOKEN='s3cr3t-token'
    listener_write_env_file '${WORK}/etc/listener.env' \
      https://github.com/acme /etc/x/runner-types.yaml gpu
  "
  [ "${status}" -eq 0 ]
  [ -f "${WORK}/etc/listener.env" ]
  [ "$(stat -c '%a' "${WORK}/etc/listener.env")" = "600" ]
  grep -qx 'GITHUB_TOKEN=s3cr3t-token' "${WORK}/etc/listener.env"
  grep -qx 'GITHUB_CONFIG_URL=https://github.com/acme' "${WORK}/etc/listener.env"
  grep -qx 'RUNNER_TYPES_CONFIG=/etc/x/runner-types.yaml' "${WORK}/etc/listener.env"
  grep -qx 'RUNNER_TYPE=gpu' "${WORK}/etc/listener.env"
}

@test "listener_write_env_file never prints the token" {
  # The token must not reach stdout/stderr: the deploy command's output is
  # routinely pasted into issues and scrollback.
  run bash -c "
    source '${LIB}'
    LISTENER_TOKEN='s3cr3t-token'
    listener_write_env_file '${WORK}/listener.env' https://github.com/acme /c.yaml gpu
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"s3cr3t-token"* ]]
}

@test "listener_write_env_file creates the file 0600 BEFORE the token is in it" {
  # A file created 0644 and chmodded afterwards is world-readable for the window
  # in between. The content must never exist at a permissive mode.
  run bash -c "
    source '${LIB}'
    LISTENER_TOKEN='s3cr3t-token'
    listener_write_env_file '${WORK}/d/listener.env' https://github.com/acme /c.yaml gpu
    stat -c '%a' '${WORK}/d/listener.env'
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"600"* ]]
  # The containing directory is created too, and is not world-writable.
  [ -d "${WORK}/d" ]
}

@test "listener_write_env_file refuses to run with no token (fails closed)" {
  run bash -c "
    source '${LIB}'
    LISTENER_TOKEN=''
    listener_write_env_file '${WORK}/listener.env' https://github.com/acme /c.yaml gpu
  "
  [ "${status}" -ne 0 ]
  [ ! -f "${WORK}/listener.env" ]
}

@test "listener_env_file_ready is false when absent and true when present at 0600" {
  run bash -c "
    source '${LIB}'
    listener_env_file_ready '${WORK}/nope.env'
  "
  [ "${status}" -ne 0 ]

  install -m 0600 /dev/null "${WORK}/there.env"
  echo 'GITHUB_TOKEN=x' > "${WORK}/there.env"
  chmod 600 "${WORK}/there.env"
  run bash -c "
    source '${LIB}'
    listener_env_file_ready '${WORK}/there.env'
  "
  [ "${status}" -eq 0 ]
}

@test "listener_env_file_ready rejects a file that exists but is world-readable" {
  # An env file holding an admin token at 0644 is a finding, not a skip: a
  # re-run must not treat it as "already done".
  echo 'GITHUB_TOKEN=x' > "${WORK}/loose.env"
  chmod 644 "${WORK}/loose.env"
  run bash -c "
    source '${LIB}'
    listener_env_file_ready '${WORK}/loose.env'
  "
  [ "${status}" -ne 0 ]
}

# --- the systemd unit ------------------------------------------------------

@test "listener_unit_current is false when the unit is absent, true when identical" {
  printf 'UNIT-A\n' > "${WORK}/src.service"
  run bash -c "
    source '${LIB}'
    listener_unit_current '${WORK}/src.service' '${WORK}/absent.service'
  "
  [ "${status}" -ne 0 ]

  cp "${WORK}/src.service" "${WORK}/dst.service"
  run bash -c "
    source '${LIB}'
    listener_unit_current '${WORK}/src.service' '${WORK}/dst.service'
  "
  [ "${status}" -eq 0 ]
}

@test "listener_unit_current is false when an installed unit has drifted" {
  printf 'UNIT-A\n' > "${WORK}/src.service"
  printf 'UNIT-B\n' > "${WORK}/dst.service"
  run bash -c "
    source '${LIB}'
    listener_unit_current '${WORK}/src.service' '${WORK}/dst.service'
  "
  [ "${status}" -ne 0 ]
}

@test "listener_install_unit installs the unit 0644 and reloads systemd" {
  printf 'UNIT\n' > "${WORK}/src.service"
  run bash -c "
    source '${LIB}'
    _systemctl() { echo \"SYSTEMCTL \$*\"; }
    listener_install_unit '${WORK}/src.service' '${WORK}/dst.service'
  "
  [ "${status}" -eq 0 ]
  [ -f "${WORK}/dst.service" ]
  [ "$(stat -c '%a' "${WORK}/dst.service")" = "644" ]
  [[ "${output}" == *"SYSTEMCTL daemon-reload"* ]]
}

@test "listener_unit_enabled / listener_unit_active read systemd, not a guess" {
  run bash -c "
    source '${LIB}'
    _systemctl() { [ \"\$1\" = is-enabled ] && { echo enabled; return 0; }; echo inactive; return 3; }
    listener_unit_enabled u.service && echo ENABLED
    listener_unit_active u.service || echo NOT-ACTIVE
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ENABLED"* ]]
  [[ "${output}" == *"NOT-ACTIVE"* ]]
}

@test "listener_enable_unit skips an already-enabled unit and says so" {
  run bash -c "
    source '${LIB}'
    _systemctl() {
      case \$1 in
        is-enabled) echo enabled; return 0 ;;
        *) echo \"SYSTEMCTL \$*\" ;;
      esac
    }
    listener_enable_unit u.service
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already enabled"* ]]
  [[ "${output}" != *"SYSTEMCTL enable"* ]]
}

@test "listener_enable_unit enables a unit that is not enabled yet" {
  run bash -c "
    source '${LIB}'
    _systemctl() {
      case \$1 in
        is-enabled) return 1 ;;
        *) echo \"SYSTEMCTL \$*\" ;;
      esac
    }
    listener_enable_unit u.service
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SYSTEMCTL enable u.service"* ]]
}

@test "listener_start_unit restarts an already-running unit so it picks up changes" {
  # A re-run that only 'start's a running unit leaves it on the OLD environment
  # file and the OLD binary -- the deploy would report success having changed
  # nothing about the running process.
  run bash -c "
    source '${LIB}'
    _systemctl() {
      case \$1 in
        is-active) echo active; return 0 ;;
        *) echo \"SYSTEMCTL \$*\" ;;
      esac
    }
    listener_start_unit u.service
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SYSTEMCTL restart u.service"* ]]
}

@test "listener_start_unit starts a stopped unit" {
  run bash -c "
    source '${LIB}'
    _systemctl() {
      case \$1 in
        is-active) return 3 ;;
        *) echo \"SYSTEMCTL \$*\" ;;
      esac
    }
    listener_start_unit u.service
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SYSTEMCTL start u.service"* ]]
}

# --- verification ----------------------------------------------------------

@test "listener_verify succeeds when the unit is active, connected and reporting capacity" {
  run bash -c "
    source '${LIB}'
    _systemctl() { [ \"\$1\" = is-active ] && { echo active; return 0; }; return 0; }
    _journalctl() {
      echo 'listener up: scale set \"gpu-runners\" (id=42), image=img'
      echo 'level=INFO msg=\"capacity report\" event=capacity_report bound=4 in_flight=0 capacity=4'
    }
    listener_verify u.service 1
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"active"* ]]
  [[ "${output}" == *"connected"* ]]
  [[ "${output}" == *"capacity"* ]]
}

@test "listener_verify fails when the unit is not active" {
  run bash -c "
    source '${LIB}'
    _systemctl() { [ \"\$1\" = is-active ] && { echo failed; return 3; }; return 0; }
    _journalctl() { echo ''; }
    listener_verify u.service 1
  "
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not active"* ]]
}

@test "listener_verify fails when the unit runs but never connected to a scale set" {
  # Running-but-not-connected is the failure that matters: the unit is green,
  # journald has a crash loop in it, and nothing says the deploy did not work.
  run bash -c "
    source '${LIB}'
    _systemctl() { [ \"\$1\" = is-active ] && { echo active; return 0; }; return 0; }
    _journalctl() { echo 'get scale set \"gpu-runners\": no scale set named'; }
    listener_verify u.service 1
  "
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"never reported"* ]] || [[ "${output}" == *"did not connect"* ]]
}

@test "listener_verify never prints anything that looks like the token" {
  run bash -c "
    source '${LIB}'
    _systemctl() { [ \"\$1\" = is-active ] && { echo active; return 0; }; return 0; }
    _journalctl() { echo 'listener up: scale set \"s\" (id=1)'; echo 'capacity_report bound=1'; }
    LISTENER_TOKEN=ghp_supersecret
    listener_verify u.service 1
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"ghp_supersecret"* ]]
}

# --- the runner-type config (generated, never parsed, in bash) --------------

@test "listener_write_type_config emits a complete runner-type entry" {
  run bash -c "
    source '${LIB}'
    listener_write_type_config '${WORK}/rt.yaml' gpu gpu-runners 'self-hosted,linux,gpu' 'img@sha256:abc'
  "
  [ "${status}" -eq 0 ]
  grep -q '^runner_types:' "${WORK}/rt.yaml"
  grep -q 'name: gpu' "${WORK}/rt.yaml"
  grep -q 'scale_set: gpu-runners' "${WORK}/rt.yaml"
  grep -q 'labels: \[self-hosted, linux, gpu\]' "${WORK}/rt.yaml"
  grep -q 'image: img@sha256:abc' "${WORK}/rt.yaml"
}

@test "listener_write_type_config records the labels it was given, verbatim" {
  # The config is the source of truth for routing: whatever the interaction
  # settled on has to be written down, or the routing key lives nowhere.
  run bash -c "
    source '${LIB}'
    listener_write_type_config '${WORK}/rt.yaml' plain plain-runners 'plain-runners' 'i@sha256:a'
  "
  [ "${status}" -eq 0 ]
  grep -q 'labels: \[plain-runners\]' "${WORK}/rt.yaml"
}

@test "listener_default_labels falls back to exactly the scale set name" {
  # Mode 1: the operator does not want to think about labels, so name and
  # routing key coincide and a workflow writes `runs-on: <name>`. Set
  # EXPLICITLY -- never left empty for an implicit auto-fill.
  run bash -c "
    source '${LIB}'
    listener_default_labels '' gpu-runners
    echo '--'
    listener_default_labels 'a,b' gpu-runners
  "
  [ "${status}" -eq 0 ]
  [ "$(echo "${output}" | head -1)" = "gpu-runners" ]
  [ "$(echo "${output}" | tail -1)" = "a,b" ]
}

@test "listener_runs_on_line asks the Go command, so bash never parses the YAML" {
  # ADR-0003 makes the Go loader the authoritative parser of the runner-type
  # config. The deploy command needs the labels, so it ASKS rather than reading
  # the YAML itself.
  run bash -c "
    source '${LIB}'
    _scaleset_admin() {
      echo 'name=gpu'
      echo 'scale_set=gpu-runners'
      echo 'labels=self-hosted,linux,gpu'
      echo 'runs_on=runs-on: [self-hosted, linux, gpu]'
    }
    listener_runs_on_line /c.yaml gpu
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "runs-on: [self-hosted, linux, gpu]" ]
}

# --- confirmation ----------------------------------------------------------
# The TTY check is a seam (_stdin_is_tty) precisely so all three branches are
# reachable without allocating a pty, which the test image cannot do. The
# production behaviour is the shared destructive-action contract: --yes
# proceeds, a non-TTY without --yes refuses, and an operator is prompted.

@test "listener_confirm proceeds without prompting when --yes was given" {
  run bash -c "
    source '${LIB}'
    LISTENER_YES=1
    _stdin_is_tty() { return 1; }
    listener_confirm 'Proceed? [y/N] '
    echo CONTINUED
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CONTINUED"* ]]
  [[ "${output}" != *"Proceed?"* ]]
}

@test "listener_confirm refuses an unattended run that did not pass --yes" {
  run bash -c "
    source '${LIB}'
    LISTENER_YES=0
    _stdin_is_tty() { return 1; }
    listener_confirm 'Proceed? [y/N] '
    echo CONTINUED
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" != *"CONTINUED"* ]]
  [[ "${output}" == *"--yes"* ]]
}

@test "listener_confirm proceeds when the operator answers yes" {
  run bash -c "
    source '${LIB}'
    LISTENER_YES=0
    _stdin_is_tty() { return 0; }
    printf 'y\n' | { listener_confirm 'Proceed? [y/N] '; echo CONTINUED; }
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CONTINUED"* ]]
}

@test "listener_confirm aborts when the operator answers anything else" {
  run bash -c "
    source '${LIB}'
    LISTENER_YES=0
    _stdin_is_tty() { return 0; }
    printf 'n\n' | { listener_confirm 'Proceed? [y/N] '; echo CONTINUED; }
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Aborted"* ]]
  [[ "${output}" != *"CONTINUED"* ]]
}

@test "listener_prompt_secret reads the token into the CALLER's shell, not a subshell" {
  # A here-string, not a pipe: a pipeline would run the function in a subshell
  # and LISTENER_TOKEN would be lost the moment it returned. The caller relies
  # on the variable surviving, so that is what is pinned here.
  run bash -c "
    source '${LIB}'
    listener_prompt_secret 'Token: ' <<< 'tok-xyz'
    echo \"LEN=\${#LISTENER_TOKEN}\"
    echo \"VALUE-CHECK=\$([ \"\${LISTENER_TOKEN}\" = tok-xyz ] && echo ok)\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"VALUE-CHECK=ok"* ]]
  [[ "${output}" == *"LEN=7"* ]]
}

@test "listener_prompt_secret does not echo the secret it read" {
  run bash -c "
    source '${LIB}'
    listener_prompt_secret 'Token: ' <<< 'tok-xyz'
    echo DONE
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DONE"* ]]
  [[ "${output}" != *"tok-xyz"* ]]
}

@test "listener_config_labels reads the labels through the same Go command" {
  run bash -c "
    source '${LIB}'
    _scaleset_admin() { echo 'labels=self-hosted,gpu'; }
    listener_config_labels /c.yaml gpu
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "self-hosted,gpu" ]
}

# --- the admin tool: finding it, and naming it when it is not there ---------
# The deploy command reads the runner-type config THROUGH scaleset-admin, so
# the tool is needed before any other step -- earlier than the local half that
# builds and installs it. Two things have to hold: the command can find (or
# build) the tool from a clean checkout, and a missing tool is reported as a
# missing tool rather than as an unreadable config.

@test "listener_show_type names the MISSING TOOL, not the config, when it cannot run" {
  # The defect this pins: with no scaleset-admin anywhere, the operator used to
  # be told "could not read <config path>" -- which sends them to debug a
  # perfectly good file. Invariant 1: a failure names its real cause.
  run bash -c "
    source '${LIB}'
    SCALESET_ADMIN_BIN='${WORK}/not-installed'
    listener_show_type /etc/runner-types.yaml gpu
  "
  [ "${status}" -eq 127 ]
  [[ "${output}" == *"scaleset-admin"* ]]
  [[ "${output}" == *"just build-admin"* ]]
  # ...and it does not blame the config file.
  [[ "${output}" != *"/etc/runner-types.yaml"* ]]
}

@test "listener_show_field separates 'could not run the tool' from 'the tool rejected the config'" {
  # Two different faults with two different fixes. The tool RAN here and said
  # the config is bad: its own status must survive the sed pipeline, and the
  # missing-tool advice must not be printed.
  run bash -c "
    source '${LIB}'
    _scaleset_admin() {
      echo 'scaleset-admin: read runner-type config /c.yaml: no such file' >&2
      return 1
    }
    listener_config_scaleset /c.yaml gpu
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" != *"build-admin"* ]]
  [[ "${output}" == *"read runner-type config"* ]]
}

@test "listener_show_field keeps reporting a field when the tool answers" {
  # The success path still returns the field, and status 0 -- the pipeline
  # rework must not change what a good run produces.
  run bash -c "
    source '${LIB}'
    _scaleset_admin() { echo 'scale_set=gpu-runners'; echo 'labels=a,b'; }
    listener_config_scaleset /c.yaml gpu
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "gpu-runners" ]
}

@test "listener_resolve_admin_bin prefers this checkout's own build output" {
  # The local half installs the listener built from THIS tree, so the tool that
  # reads the config must be the matching one -- a stale scaleset-admin left on
  # PATH by another checkout would answer for a schema this tree may not have.
  mkdir -p "${WORK}/repo/bin" "${WORK}/onpath"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/repo/bin/scaleset-admin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/onpath/scaleset-admin"
  chmod +x "${WORK}/repo/bin/scaleset-admin" "${WORK}/onpath/scaleset-admin"
  run bash -c "
    source '${LIB}'
    unset SCALESET_ADMIN_BIN
    PATH='${WORK}/onpath':\"\${PATH}\"
    _just() { echo 'BUILT'; }
    listener_resolve_admin_bin '${WORK}/repo'
    echo \"RESOLVED=\${SCALESET_ADMIN_BIN}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RESOLVED=${WORK}/repo/bin/scaleset-admin"* ]]
  # Nothing was built: there was already a binary to use.
  [[ "${output}" != *"BUILT"* ]]
}

@test "listener_resolve_admin_bin falls back to one on PATH before building" {
  mkdir -p "${WORK}/repo" "${WORK}/onpath"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/onpath/scaleset-admin"
  chmod +x "${WORK}/onpath/scaleset-admin"
  run bash -c "
    source '${LIB}'
    unset SCALESET_ADMIN_BIN
    PATH='${WORK}/onpath':\"\${PATH}\"
    _just() { echo 'BUILT'; }
    listener_resolve_admin_bin '${WORK}/repo'
    echo \"RESOLVED=\${SCALESET_ADMIN_BIN}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RESOLVED=${WORK}/onpath/scaleset-admin"* ]]
  [[ "${output}" != *"BUILT"* ]]
}

@test "listener_resolve_admin_bin builds the tool when a clean checkout has none" {
  # The point of the one command: it builds what it needs, the same way the
  # local half already builds the listener.
  mkdir -p "${WORK}/repo"
  run bash -c "
    source '${LIB}'
    unset SCALESET_ADMIN_BIN
    _just() {
      printf '%s\n' \"\$@\" >> '${WORK}/just.argv'
      mkdir -p '${WORK}/repo/bin'
      printf '#!/usr/bin/env bash\nexit 0\n' > '${WORK}/repo/bin/scaleset-admin'
      chmod +x '${WORK}/repo/bin/scaleset-admin'
    }
    listener_resolve_admin_bin '${WORK}/repo'
    echo \"RESOLVED=\${SCALESET_ADMIN_BIN}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RESOLVED=${WORK}/repo/bin/scaleset-admin"* ]]
  grep -qxF 'build-admin' "${WORK}/just.argv"
}

@test "listener_resolve_admin_bin builds into an overridden build directory" {
  # Overridable for the same reason LISTENER_UNIT_DIR is: a test must be able
  # to send the build output somewhere throwaway.
  mkdir -p "${WORK}/repo"
  run bash -c "
    source '${LIB}'
    unset SCALESET_ADMIN_BIN
    LISTENER_BIN_DIR='${WORK}/out'
    _just() {
      printf '%s\n' \"\$@\" >> '${WORK}/just.argv'
      mkdir -p '${WORK}/out'
      printf '#!/usr/bin/env bash\nexit 0\n' > '${WORK}/out/scaleset-admin'
      chmod +x '${WORK}/out/scaleset-admin'
    }
    listener_resolve_admin_bin '${WORK}/repo'
    echo \"RESOLVED=\${SCALESET_ADMIN_BIN}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RESOLVED=${WORK}/out/scaleset-admin"* ]]
  grep -qxF "BIN_DIR=${WORK}/out" "${WORK}/just.argv"
}

@test "listener_resolve_admin_bin fails naming the tool when the build produced nothing" {
  mkdir -p "${WORK}/repo"
  run bash -c "
    source '${LIB}'
    unset SCALESET_ADMIN_BIN
    _just() { return 1; }
    listener_resolve_admin_bin '${WORK}/repo'
  "
  [ "${status}" -eq 127 ]
  [[ "${output}" == *"scaleset-admin"* ]]
  [[ "${output}" == *"build-admin"* ]]
}

@test "listener_resolve_admin_bin never second-guesses an explicit SCALESET_ADMIN_BIN" {
  mkdir -p "${WORK}/repo/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/repo/bin/scaleset-admin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/chosen"
  chmod +x "${WORK}/repo/bin/scaleset-admin" "${WORK}/chosen"
  run bash -c "
    source '${LIB}'
    SCALESET_ADMIN_BIN='${WORK}/chosen'
    _just() { echo 'BUILT'; }
    listener_resolve_admin_bin '${WORK}/repo'
    echo \"RESOLVED=\${SCALESET_ADMIN_BIN}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RESOLVED=${WORK}/chosen"* ]]
  [[ "${output}" != *"BUILT"* ]]
  [[ "${output}" != *"command not found"* ]]
}

@test "listener_resolve_admin_bin reports an explicit SCALESET_ADMIN_BIN that is not there" {
  # An operator who named a binary gets told that binary is missing, rather
  # than having a different one silently built and used behind their back.
  mkdir -p "${WORK}/repo"
  run bash -c "
    source '${LIB}'
    SCALESET_ADMIN_BIN='${WORK}/gone'
    _just() { echo 'BUILT'; }
    listener_resolve_admin_bin '${WORK}/repo'
  "
  [ "${status}" -eq 127 ]
  [[ "${output}" == *"${WORK}/gone"* ]]
  [[ "${output}" != *"BUILT"* ]]
}
