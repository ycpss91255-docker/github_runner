#!/usr/bin/env bats
# Integration spec for script/deploy-listener.sh -- the whole command driving
# lib/listener-deploy.sh, with every external it touches replaced by a scripted
# stub executable on a clean PATH.
#
# This is the level where the thing that matters is checked: a real run does
# each step, a SECOND run detects what is already in place and skips it, the
# confirmation gates the outward action, and the token never reaches an
# external command's argv. Nothing here starts a service, creates a user, or
# talks to GitHub: systemctl / journalctl / useradd / id / just and
# scaleset-admin are all stubs that record their argv.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${ROOT}/script/deploy-listener.sh"
  WORK=$(mktemp -d)
  STUB="${WORK}/stub"
  mkdir -p "${STUB}"
  # Every stubbed command appends its own name plus full argv here, one token
  # per line, so an exact argument can be grepped -- and so the token's ABSENCE
  # from every external argv can be asserted.
  CAP="${WORK}/argv.log"
  : > "${CAP}"

  PREFIX="${WORK}/opt"
  ETC="${WORK}/etc"
  CONFIG="${WORK}/runner-types.yaml"
  cat > "${CONFIG}" <<'YAML'
runner_types:
  - name: gpu
    scale_set: gpu-runners
    labels: [self-hosted, linux, gpu]
    image: ghcr.io/acme/r@sha256:abc
YAML

  # --- scripted stubs -----------------------------------------------------
  # State the stubs read so a test can say "the user already exists" or "the
  # unit is already active" and get the idempotent branch.
  export STUB_USER_EXISTS="${STUB_USER_EXISTS:-0}"
  export STUB_UNIT_ACTIVE="${STUB_UNIT_ACTIVE:-0}"
  export STUB_UNIT_ENABLED="${STUB_UNIT_ENABLED:-0}"
  # The stubbed journal is deterministic, so the verification retry loop has
  # nothing to wait for.
  export LISTENER_VERIFY_TRIES=2 LISTENER_VERIFY_INTERVAL=0

  _mkstub() {
    local name=$1 body=$2
    { printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s\\n" "name=%s" "$@" >> "%s"\n' "${name}" "${CAP}"
      printf '%s\n' "${body}"
    } > "${STUB}/${name}"
    chmod +x "${STUB}/${name}"
  }

  _mkstub id 'if [ "${STUB_USER_EXISTS}" = 1 ]; then echo 999; exit 0; fi; exit 1'
  _mkstub useradd 'exit 0'
  # A started unit becomes active, the way a real one does -- otherwise the
  # verification step could never pass and the test would be asserting against
  # a systemd that behaves like nothing else.
  _mkstub systemctl '
case "$1" in
  is-active)
    { [ "${STUB_UNIT_ACTIVE}" = 1 ] || [ -e "${STUB_STATE}/started" ]; } \
      && { echo active; exit 0; }
    echo inactive; exit 3 ;;
  is-enabled) [ "${STUB_UNIT_ENABLED}" = 1 ] && { echo enabled; exit 0; }; echo disabled; exit 1 ;;
  start|restart) : > "${STUB_STATE}/started"; exit 0 ;;
  stop) rm -f "${STUB_STATE}/started"; exit 0 ;;
  *) exit 0 ;;
esac'
  # A journal that shows a listener which came up and is reporting capacity --
  # the success case; a test that wants the failure path overrides this.
  _mkstub journalctl '
echo "listener up: scale set \"gpu-runners\" (id=42), image=ghcr.io/acme/r@sha256:abc"
echo "level=INFO msg=\"capacity report\" event=capacity_report bound=4 in_flight=0 capacity=4"
exit 0'
  # `just` builds and installs; here it only records that it was asked to, and
  # lays down the files the verification step looks for.
  _mkstub just '
for a in "$@"; do
  case "$a" in
    install-listener)
      mkdir -p "${STUB_PREFIX}/bin"
      : > "${STUB_PREFIX}/bin/scaleset-listener"
      : > "${STUB_PREFIX}/bin/scaleset-admin"
      chmod +x "${STUB_PREFIX}/bin/scaleset-listener" "${STUB_PREFIX}/bin/scaleset-admin"
      ;;
    build-admin)
      # What the real recipe leaves behind: a scaleset-admin in the build
      # output directory. It is the same scripted stub the tests use elsewhere,
      # so a run that had to build one behaves like a run that found one.
      mkdir -p "${STUB_BIN_DIR}"
      cp "${STUB_ADMIN_SRC}" "${STUB_BIN_DIR}/scaleset-admin"
      chmod +x "${STUB_BIN_DIR}/scaleset-admin"
      ;;
  esac
done
exit 0'
  export STUB_PREFIX="${PREFIX}"
  # Where a build would land, kept out of the checkout's own bin/.
  export STUB_BIN_DIR="${WORK}/build"
  export STUB_STATE="${WORK}/state"
  mkdir -p "${STUB_STATE}"
  # Keep the unit out of the host's real systemd directory.
  export LISTENER_UNIT_DIR="${WORK}/systemd"

  # scaleset-admin: answers `show` from the fixture and records a `create`.
  export SCALESET_ADMIN_BIN="${STUB}/scaleset-admin-cmd"
  # The same file, under a name the `just` stub can copy from when a test drops
  # SCALESET_ADMIN_BIN to play a clean checkout.
  export STUB_ADMIN_SRC="${SCALESET_ADMIN_BIN}"
  cat > "${SCALESET_ADMIN_BIN}" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "name=scaleset-admin" "\$@" >> "${CAP}"
case "\${1:-}" in
  show)
    echo 'name=gpu'
    echo 'scale_set=gpu-runners'
    echo 'labels=self-hosted,linux,gpu'
    echo 'image=ghcr.io/acme/r@sha256:abc'
    echo 'runs_on=runs-on: [self-hosted, linux, gpu]'
    ;;
  create)
    # The real command reads GITHUB_TOKEN from the environment and refuses
    # without it. Enforcing that here is what makes the ordering of the prompt
    # relative to the GitHub half observable.
    [ -n "\${GITHUB_TOKEN:-}" ] || { echo 'scaleset-admin: set GITHUB_CONFIG_URL and GITHUB_TOKEN' >&2; exit 1; }
    [ -n "\${GITHUB_CONFIG_URL:-}" ] || { echo 'scaleset-admin: set GITHUB_CONFIG_URL and GITHUB_TOKEN' >&2; exit 1; }
    if [ "\${STUB_SCALE_SET_EXISTS:-0}" = 1 ]; then
      echo 'scale set "gpu-runners" (id=42) already exists for runner type "gpu"; nothing changed'
    else
      echo 'created scale set "gpu-runners" (id=42) for runner type "gpu"'
    fi
    echo ''
    echo 'Paste into your workflow job:'
    echo ''
    echo '    runs-on: [self-hosted, linux, gpu]'
    ;;
  *) echo "stub: unexpected verb \${1:-}" >&2; exit 64 ;;
esac
STUBEOF
  chmod +x "${SCALESET_ADMIN_BIN}"

  # Clean PATH: only the stubs plus system bins, so no host systemctl / just
  # can leak into the run.
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${WORK}"; }

# Run the deploy non-interactively with --yes, feeding the token on stdin the
# way the interactive prompt reads it.
_deploy() {
  printf 'tok-abc123\n' | "${SCRIPT}" --yes \
    --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme \
    --prefix "${PREFIX}" --etc "${ETC}" "$@"
}

# The same run on a CLEAN CHECKOUT: no SCALESET_ADMIN_BIN pointing at a
# prebuilt stub and nothing named scaleset-admin on PATH, which is the state a
# freshly cloned repository is actually in. The command has to end up with an
# admin tool by itself.
_deploy_clean_checkout() {
  printf 'tok-abc123\n' | env -u SCALESET_ADMIN_BIN -u GITHUB_TOKEN \
    LISTENER_BIN_DIR="${STUB_BIN_DIR}" "${SCRIPT}" --yes \
    --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme \
    --prefix "${PREFIX}" --etc "${ETC}" "$@"
}

# The same run, but guaranteed to have no ambient GITHUB_TOKEN: the token must
# come from the prompt alone.
_deploy_env_free() {
  printf 'tok-abc123\n' | env -u GITHUB_TOKEN "${SCRIPT}" --yes \
    --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme \
    --prefix "${PREFIX}" --etc "${ETC}" "$@"
}

@test "a full run performs both halves and reports success" {
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GitHub side"* ]]
  [[ "${output}" == *"Local side"* ]]
  # The GitHub half went through scaleset-admin create.
  grep -qxF 'create' "${CAP}"
  # The local half built/installed, made the user, and enabled + started.
  grep -qxF 'install-listener' "${CAP}"
  grep -qxF 'name=useradd' "${CAP}"
  grep -qxF 'enable' "${CAP}"
}

@test "a full run writes the environment file 0600 with the prompted token" {
  run _deploy
  [ "${status}" -eq 0 ]
  [ -f "${ETC}/scaleset-listener.env" ]
  [ "$(stat -c '%a' "${ETC}/scaleset-listener.env")" = "600" ]
  grep -qx 'GITHUB_TOKEN=tok-abc123' "${ETC}/scaleset-listener.env"
}

@test "the token never appears on any external command's argv" {
  # The whole point of prompting: /proc/<pid>/cmdline is world-readable, so a
  # token that reaches any exec'd command is a token any local user can read.
  run _deploy
  [ "${status}" -eq 0 ]
  ! grep -qF 'tok-abc123' "${CAP}"
}

@test "the token is never echoed to the terminal" {
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"tok-abc123"* ]]
}

@test "the run ends by printing the literal runs-on line for a test job" {
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"runs-on: [self-hosted, linux, gpu]"* ]]
  # And says the labels are what a workflow targets, not the scale set name.
  [[ "${output}" == *"label"* ]]
}

@test "the run verifies the listener actually came up and reports capacity" {
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"capacity"* ]]
  grep -qxF 'name=journalctl' "${CAP}"
}

@test "a listener that is active but never connected fails the run" {
  # Running-but-not-connected is the failure that a naive `systemctl is-active`
  # check reports as success.
  cat > "${STUB}/journalctl" <<'EOF'
#!/usr/bin/env bash
echo 'get scale set "gpu-runners": no scale set named "gpu-runners" exists'
exit 0
EOF
  chmod +x "${STUB}/journalctl"
  export STUB_UNIT_ACTIVE=1
  run _deploy
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"never reported"* ]] || [[ "${output}" == *"did not connect"* ]]
}

# --- idempotence -----------------------------------------------------------

@test "a second run skips the service user that already exists" {
  export STUB_USER_EXISTS=1
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already exists"* ]]
  ! grep -qxF 'name=useradd' "${CAP}"
}

@test "a second run skips the environment file that is already in place" {
  install -d -m 0755 "${ETC}"
  printf 'GITHUB_TOKEN=already\n' > "${ETC}/scaleset-listener.env"
  chmod 600 "${ETC}/scaleset-listener.env"
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"environment file"* ]]
  # The existing token is left untouched -- a re-run must not clobber it.
  grep -qx 'GITHUB_TOKEN=already' "${ETC}/scaleset-listener.env"
}

@test "a second run skips enabling a unit that is already enabled" {
  export STUB_UNIT_ENABLED=1
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already enabled"* ]]
}

@test "a second run restarts an already-active unit rather than leaving it stale" {
  export STUB_UNIT_ACTIVE=1
  run _deploy
  [ "${status}" -eq 0 ]
  grep -qxF 'restart' "${CAP}"
}

@test "running it twice in a row succeeds both times and changes nothing the second time" {
  run _deploy
  [ "${status}" -eq 0 ]
  export STUB_USER_EXISTS=1 STUB_UNIT_ENABLED=1 STUB_UNIT_ACTIVE=1 STUB_SCALE_SET_EXISTS=1
  : > "${CAP}"
  run _deploy
  [ "${status}" -eq 0 ]
  ! grep -qxF 'name=useradd' "${CAP}"
  [[ "${output}" == *"already exists"* ]]
}

# --- one command means one command -----------------------------------------
# The command reads the runner-type config THROUGH scaleset-admin, so the tool
# is needed before every other step -- earlier than the local half that builds
# and installs it. On a clean checkout there is nothing built and nothing on
# PATH, and the command used to be unable to run at all.

@test "a run from a clean checkout builds the admin tool it needs, then deploys" {
  run _deploy_clean_checkout
  [ "${status}" -eq 0 ]
  # It asked for the build itself...
  grep -qxF 'build-admin' "${CAP}"
  [ -x "${STUB_BIN_DIR}/scaleset-admin" ]
  # ...and the rest of the run then happened as usual.
  grep -qxF 'create' "${CAP}"
  grep -qxF 'install-listener' "${CAP}"
  [[ "${output}" == *"Deployed."* ]]
}

@test "a dry run from a clean checkout writes only the build output: no token, no install, no GitHub" {
  # --dry-run keeps its promise even when it has to produce the tool first:
  # the build output directory is the ONE thing it may write, it never asks for
  # a token, and it reaches neither /etc nor GitHub.
  run bash -c "env -u SCALESET_ADMIN_BIN -u GITHUB_TOKEN \
    LISTENER_BIN_DIR='${STUB_BIN_DIR}' '${SCRIPT}' --dry-run \
    --config '${CONFIG}' --type gpu --org-url https://github.com/acme \
    --prefix '${PREFIX}' --etc '${ETC}'" </dev/null
  [ "${status}" -eq 0 ]
  grep -qxF 'build-admin' "${CAP}"
  [ -x "${STUB_BIN_DIR}/scaleset-admin" ]
  ! grep -qxF 'create' "${CAP}"
  ! grep -qxF 'install-listener' "${CAP}"
  ! grep -qxF 'name=useradd' "${CAP}"
  [ ! -d "${ETC}" ]
  [ ! -d "${PREFIX}" ]
}

# --- the GitHub half is announced and skippable ----------------------------

@test "an existing scale set is reported as a skip, not created again" {
  export STUB_SCALE_SET_EXISTS=1
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already exists"* ]]
  [[ "${output}" == *"nothing changed"* ]]
}

@test "--skip-github does the local half only and never invokes scaleset-admin create" {
  run _deploy --skip-github
  [ "${status}" -eq 0 ]
  ! grep -qxF 'create' "${CAP}"
  [[ "${output}" == *"Local side"* ]]
  # It still installs and starts the listener.
  grep -qxF 'install-listener' "${CAP}"
}

@test "the run announces what it will create on GitHub before creating it" {
  run _deploy
  [ "${status}" -eq 0 ]
  # The announcement names the scale set and the routing labels, and appears
  # before the create is reported.
  plan_line=$(printf '%s\n' "${output}" | grep -n 'gpu-runners' | head -1 | cut -d: -f1)
  made_line=$(printf '%s\n' "${output}" | grep -n 'created scale set' | head -1 | cut -d: -f1)
  [ -n "${plan_line}" ]
  [ -n "${made_line}" ]
  [ "${plan_line}" -lt "${made_line}" ]
}

# --- confirmation ----------------------------------------------------------
# The three branches of the confirmation itself (assumed-yes, refuse-unattended,
# and the interactive prompt's yes/no) are exercised against listener_confirm in
# test/bats/unit/listener_deploy.bats, where the TTY check is a seam and no pty
# is needed. What belongs here is that the whole command honours them.

@test "a non-interactive run without --yes refuses before touching anything" {
  run bash -c "'${SCRIPT}' --config '${CONFIG}' --type gpu \
    --org-url https://github.com/acme --prefix '${PREFIX}' --etc '${ETC}'" </dev/null
  [ "${status}" -eq 1 ]
  ! grep -qxF 'create' "${CAP}"
  ! grep -qxF 'name=useradd' "${CAP}"
  ! grep -qxF 'install-listener' "${CAP}"
  [ ! -f "${ETC}/scaleset-listener.env" ]
}

@test "a dry run touches nothing at all, even with every stub available" {
  run bash -c "'${SCRIPT}' --dry-run --config '${CONFIG}' --type gpu \
    --org-url https://github.com/acme --prefix '${PREFIX}' --etc '${ETC}'" </dev/null
  [ "${status}" -eq 0 ]
  ! grep -qxF 'create' "${CAP}"
  ! grep -qxF 'name=useradd' "${CAP}"
  ! grep -qxF 'install-listener' "${CAP}"
  [ ! -d "${ETC}" ]
}

@test "the token is available to the GitHub half, which runs before the env file is written" {
  # The GitHub half needs the admin token, and it happens BEFORE the local half
  # writes the environment file -- so prompting for the token only at the env
  # file step would leave the create with nothing and fail every first-time
  # deploy on a host that had not already exported GITHUB_TOKEN.
  run _deploy_env_free
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"set GITHUB_CONFIG_URL and GITHUB_TOKEN"* ]]
  grep -qxF 'create' "${CAP}"
  # ...and it still never reached the child's argv.
  ! grep -qF 'tok-abc123' "${CAP}"
}

@test "one prompt serves both halves: the same token lands in the env file" {
  run _deploy_env_free
  [ "${status}" -eq 0 ]
  grep -qx 'GITHUB_TOKEN=tok-abc123' "${ETC}/scaleset-listener.env"
}
