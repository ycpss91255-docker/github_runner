#!/usr/bin/env bash
# Seams behind the one interactive deploy command (script/deploy-listener.sh)
# and its teardown counterpart (script/teardown-listener.sh).
# shellcheck shell=bash
# The paths listener_deploy_paths derives are consumed by the two entry scripts
# that source this file, so shellcheck cannot see their use from here -- the
# same reason lib/common.sh carries this waiver.
# shellcheck disable=SC2034
#
# WHY THIS EXISTS. Standing a listener up was a multi-step manual runbook --
# build, install, create a service user, write a 0600 environment file, install
# a systemd unit, enable it, start it -- and a runbook is a thing people mean to
# follow. Nothing had ever been deployed. Each step is a function here, and each
# function reports what it did or why it skipped, so the entry script reads as a
# sequence of announcements rather than a wall of inline commands, and a re-run
# can say "already in place" instead of failing.
#
# THE ADAPTER SEAM. Every external command reaches the host through a single
# leading-underscore wrapper, the same idiom lib/common.sh uses for _gh: tests
# redefine the wrapper and never touch real systemd, real users, a real install
# prefix, or GitHub. The TTY check is a seam for the same reason -- all three
# branches of the confirmation must be reachable in a container that cannot
# allocate a pty.
#
# THIS FILE NEVER PARSES THE RUNNER-TYPE CONFIG. ADR-0003 makes the Go loader
# the authoritative parser. A second parser written in shell would be a copy
# that drifts, and it would drift on exactly the field (labels) that decides
# whether any job ever runs. So the labels are ASKED for, via
# `scaleset-admin show`. Writing a type entry (listener_write_type_config) is
# generation, not parsing, and stays here.

# --- external adapters (shadowed wholesale by the tests) -------------------
_systemctl()      { command systemctl "$@"; }
_journalctl()     { command journalctl "$@"; }
_id()             { command id "$@"; }
_useradd()        { command useradd "$@"; }
_just()           { command just "$@"; }
_scaleset_admin() { command "${SCALESET_ADMIN_BIN:-scaleset-admin}" "$@"; }
# Whether an operator is there to answer a prompt.
_stdin_is_tty()   { [[ -t 0 ]]; }

# --- paths ------------------------------------------------------------------

# Derive every install path from the prefix and the config dir.
#
# It is a FUNCTION, not a block of assignments at source time, because the entry
# script parses --prefix / --etc AFTER sourcing this file. A path frozen at
# source time would silently ignore those flags and install to the default,
# which is the kind of failure that only shows up on someone else's machine.
listener_deploy_paths() {
  LISTENER_PREFIX="${LISTENER_PREFIX:-/opt/github-runner-listener}"
  LISTENER_ETC="${LISTENER_ETC:-/etc/github-runner-listener}"
  LISTENER_ENV_FILE="${LISTENER_ETC}/scaleset-listener.env"
  LISTENER_UNIT_NAME="${LISTENER_UNIT_NAME:-scaleset-listener.service}"
  # Overridable so a test can place the unit somewhere throwaway instead of the
  # host's real systemd directory.
  LISTENER_UNIT_DIR="${LISTENER_UNIT_DIR:-/etc/systemd/system}"
  LISTENER_UNIT_PATH="${LISTENER_UNIT_DIR}/${LISTENER_UNIT_NAME}"
  LISTENER_BIN="${LISTENER_PREFIX}/bin/scaleset-listener"
  LISTENER_ADMIN_BIN="${LISTENER_PREFIX}/bin/scaleset-admin"
}

# --- interaction ------------------------------------------------------------

# Gate an action behind the operator's consent, with the same contract every
# destructive script in this repo carries:
#   --yes            -> proceed silently;
#   not a TTY, no -y -> refuse (exit 1), so nothing happens unattended;
#   otherwise        -> prompt; anything but y/yes aborts (exit 0).
listener_confirm() {
  local prompt=$1 ans
  (( ${LISTENER_YES:-0} )) && return 0
  if ! _stdin_is_tty; then
    echo "FAIL: non-interactive run requires --yes (stdin is not a TTY)" >&2
    exit 1
  fi
  read -r -p "${prompt}" ans
  case ${ans} in
    y|Y|yes|YES) return 0 ;;
    *) echo "Aborted."; exit 0 ;;
  esac
}

# Read the admin token into LISTENER_TOKEN without echoing it.
#
# Prompted, never a flag: a token in a flag is a token in the host process table
# (/proc/<pid>/cmdline is world-readable) and in the operator's shell history.
# The prompt goes to stderr so stdout stays consumable.
listener_prompt_secret() {
  printf '%s' "$1" >&2
  read -rs LISTENER_TOKEN
  printf '\n' >&2
}

# --- service user -----------------------------------------------------------

listener_service_user_exists() { _id -u "$1" >/dev/null 2>&1; }

# Create the unprivileged service user the unit runs as, or report that it is
# already there. The account is a system account with no login shell: it exists
# to own a process, not to be logged into.
listener_ensure_service_user() {
  local user=$1
  if listener_service_user_exists "${user}"; then
    echo "  service user:     ${user} already exists, skipped"
    return 0
  fi
  _useradd --system --create-home --shell /usr/sbin/nologin "${user}"
  echo "  service user:     created ${user}"
}

# --- the environment file (the secret) --------------------------------------

# True when the environment file is present AND root-only (0600). A file that
# exists at a looser mode is a finding, not a step to skip: it holds a
# scale-set admin token.
listener_env_file_ready() {
  local file=$1
  [[ -f ${file} ]] || return 1
  [[ "$(stat -c '%a' "${file}" 2>/dev/null)" == 600 ]]
}

# Write the unit's EnvironmentFile, containing the token.
#
# The file is CREATED at 0600 and only then written to, so its contents never
# exist at a permissive mode -- a file created 0644 and chmodded afterwards is
# world-readable for the window in between, and a window is all a local attacker
# needs. Everything is written with shell redirection and the printf builtin, so
# the token is never an argument to an exec'd process.
listener_write_env_file() {
  local file=$1 config_url=$2 types_config=$3 type_name=$4
  if [[ -z ${LISTENER_TOKEN:-} ]]; then
    echo "FAIL: no token was provided; refusing to write ${file}" >&2
    return 1
  fi
  install -d -m 0755 "$(dirname "${file}")"
  install -m 0600 /dev/null "${file}"
  {
    printf '# Written by script/deploy-listener.sh. Mode 0600, root-only.\n'
    printf '# The listener reads the token from this environment; it is never\n'
    printf '# passed on a command line and never logged.\n'
    printf 'GITHUB_CONFIG_URL=%s\n' "${config_url}"
    printf 'GITHUB_TOKEN=%s\n' "${LISTENER_TOKEN}"
    printf 'RUNNER_TYPES_CONFIG=%s\n' "${types_config}"
    printf 'RUNNER_TYPE=%s\n' "${type_name}"
  } >> "${file}"
  echo "  environment file: wrote ${file} (0600)"
}

# --- the systemd unit -------------------------------------------------------

# True when the installed unit exists and matches the one in the repo, so an
# unchanged unit is not reinstalled and a DRIFTED one is not left in place.
listener_unit_current() {
  local src=$1 dst=$2
  [[ -f ${dst} ]] || return 1
  cmp -s "${src}" "${dst}"
}

listener_install_unit() {
  local src=$1 dst=$2
  install -d -m 0755 "$(dirname "${dst}")"
  install -m 0644 "${src}" "${dst}"
  _systemctl daemon-reload
  echo "  systemd unit:     installed ${dst}"
}

listener_unit_enabled() { _systemctl is-enabled "$1" >/dev/null 2>&1; }
listener_unit_active()  { _systemctl is-active  "$1" >/dev/null 2>&1; }

listener_enable_unit() {
  local unit=$1
  if listener_unit_enabled "${unit}"; then
    echo "  enable:           ${unit} already enabled, skipped"
    return 0
  fi
  _systemctl enable "${unit}"
  echo "  enable:           enabled ${unit}"
}

# Start the unit, or RESTART it when it is already running.
#
# The restart is the point: a re-run that only 'start's an already-active unit
# leaves the process on the old binary and the old environment file, and the
# deploy would report success having changed nothing about what is running.
listener_start_unit() {
  local unit=$1
  if listener_unit_active "${unit}"; then
    _systemctl restart "${unit}"
    echo "  start:            restarted ${unit} (it was already running)"
    return 0
  fi
  _systemctl start "${unit}"
  echo "  start:            started ${unit}"
}

# --- verification -----------------------------------------------------------

# Confirm the listener actually came up: the unit is active, it connected to its
# scale set, and it is reporting capacity.
#
# "systemctl is-active" alone is not enough, and that is the whole reason this
# function exists. A listener that cannot find its scale set exits, systemd
# restarts it (Restart=always), and the unit sits there looking activating/
# active while nothing works. Requiring evidence from the journal that it
# CONNECTED turns that into a failed deploy instead of a green one.
#
# The journal is inspected, never echoed: it is the one place a token could
# plausibly surface, and the deploy's output gets pasted into issues.
listener_verify() {
  local unit=$1
  local tries=${2:-${LISTENER_VERIFY_TRIES:-15}}
  local interval=${LISTENER_VERIFY_INTERVAL:-2}
  local i out

  if ! listener_unit_active "${unit}"; then
    echo "  unit:             NOT active" >&2
    echo "FAIL: ${unit} is not active. Inspect: journalctl -u ${unit} -n 100" >&2
    return 1
  fi
  echo "  unit:             active"

  for (( i = 0; i < tries; i++ )); do
    out=$(_journalctl -u "${unit}" -n 200 --no-pager 2>/dev/null || true)
    if grep -q 'listener up' <<< "${out}"; then
      echo "  scale set:        connected"
      if grep -qE 'capacity_report|capacity report' <<< "${out}"; then
        echo "  capacity:         reporting"
      else
        echo "  capacity:         not reported yet (the first snapshot is on an interval)"
      fi
      return 0
    fi
    (( i + 1 < tries )) && sleep "${interval}"
  done

  echo "FAIL: ${unit} is running but never reported connecting to a scale set." >&2
  echo "      Inspect: journalctl -u ${unit} -n 100" >&2
  return 1
}

# --- the runner-type config -------------------------------------------------

# Mode 1 / mode 2, in one line. Given labels are used verbatim (mode 2); no
# labels means exactly the scale set name (mode 1), so name and routing key
# coincide and a workflow writes `runs-on: <name>`.
#
# The default is resolved HERE and written down, rather than being left to an
# implicit fallback further down the stack. The scale-set client fills labels
# from the name only when the field arrives empty, and relying on that is what
# leaves the routing key recorded nowhere.
listener_default_labels() {
  local labels=$1 scale_set=$2
  printf '%s\n' "${labels:-${scale_set}}"
}

# Ask the Go command what the config says about a runner type. See the header:
# bash does not parse this file.
listener_show_type() {
  local config=$1 type_name=$2
  if [[ -n ${type_name} ]]; then
    _scaleset_admin show --config "${config}" --type "${type_name}"
  else
    _scaleset_admin show --config "${config}"
  fi
}

# One field out of that report.
listener_show_field() {
  local config=$1 type_name=$2 key=$3
  listener_show_type "${config}" "${type_name}" \
    | sed -n "s/^${key}=//p" | head -1
}

listener_config_labels()  { listener_show_field "$1" "$2" labels; }
listener_config_scaleset(){ listener_show_field "$1" "$2" scale_set; }
listener_config_image()   { listener_show_field "$1" "$2" image; }
listener_runs_on_line()   { listener_show_field "$1" "$2" runs_on; }

# Write a complete one-type runner-type config.
#
# This is GENERATION, not parsing: every value is one the caller already holds.
# It is how the interaction records what it settled on, so the config stays the
# single source of truth for routing instead of the answers living only in the
# operator's terminal scrollback.
listener_write_type_config() {
  local file=$1 name=$2 scale_set=$3 labels_csv=$4 image=$5
  local labels_yaml
  # [a, b, c] -- the flow-sequence form the sample uses.
  labels_yaml="[${labels_csv//,/, }]"
  install -d -m 0755 "$(dirname "${file}")"
  {
    printf '# Runner-type configuration for the scale-set listener.\n'
    printf '# Written by script/deploy-listener.sh.\n'
    printf '#\n'
    printf '# labels is THE ROUTING KEY: a workflow runs-on is matched against the\n'
    printf '# scale set LABELS. scale_set only NAMES the scale set.\n'
    printf 'runner_types:\n'
    printf '  - name: %s\n' "${name}"
    printf '    scale_set: %s\n' "${scale_set}"
    printf '    labels: %s\n' "${labels_yaml}"
    printf '    image: %s\n' "${image}"
  } > "${file}"
}
