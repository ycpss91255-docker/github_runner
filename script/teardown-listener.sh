#!/usr/bin/env bash
# Take a scale-set listener back off this machine -- the reversal of the LOCAL
# half of script/deploy-listener.sh.
#
# The project requires destructive operations to be reversible, so the command
# that stands a machine up has a counterpart that takes it down. This carries
# the same preview/confirm contract as the other destructive scripts
# (uninstall.sh, cleanup.sh, remove-runner.sh): print the plan, prompt, and
# refuse a non-interactive run that did not pass --yes.
#
# IT DOES NOT DELETE THE SCALE SET, and there is no flag that makes it.
# The scale set lives on GitHub and is shared by every machine serving that
# runner type: deleting it while decommissioning ONE host would stop serving
# all of them, which is not what "take this machine down" can be allowed to
# mean. Deleting it is a separate, explicit act:
#
#     scaleset-admin delete --config <path> --type <name> --yes
#
# Usage:
#   sudo ./script/teardown-listener.sh                 # prompt first
#   sudo ./script/teardown-listener.sh --dry-run       # print the plan
#   sudo ./script/teardown-listener.sh --yes           # unattended
#   ./script/teardown-listener.sh -h | --help
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=SCRIPTDIR/../lib/listener-deploy.sh
source "${SCRIPT_DIR}/../lib/listener-deploy.sh"

LISTENER_YES=0
DRY_RUN=0
KEEP_USER=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Remove the scale-set listener from THIS machine: stop and disable the unit,
remove it, remove the environment file (which holds the token) and the install
prefix. Idempotent -- anything already gone is skipped.

It does NOT delete the scale set on GitHub. That is shared by every machine
serving the runner type, so removing one host must not stop serving the rest.
Delete it deliberately, when you actually mean to retire the runner type:

    scaleset-admin delete --config <path> --type <name> --yes

Options:
  --prefix <path>   install prefix to remove (default: /opt/github-runner-listener)
  --etc <path>      config dir holding the environment file
                    (default: /etc/github-runner-listener)
  --unit-dir <path> where the systemd unit lives
                    (default: /etc/systemd/system)
  --remove-user <name>
                    also remove the service user (not done by default: the
                    account may own other things on this host)
  -n, --dry-run     print the plan; remove nothing
  -y, --yes         skip the confirmation. REQUIRED for non-interactive runs.
  -h, --help        show this help

Exit code:
  0  Removed (or dry-run / nothing to remove / aborted at the prompt).
  1  Bad usage, or a non-interactive run was attempted without --yes.
EOF
}

SERVICE_USER=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --prefix)      LISTENER_PREFIX=${2:?--prefix needs a value}; shift 2 ;;
      --etc)         LISTENER_ETC=${2:?--etc needs a value}; shift 2 ;;
      --unit-dir)    LISTENER_UNIT_DIR=${2:?--unit-dir needs a value}; shift 2 ;;
      --remove-user) SERVICE_USER=${2:?--remove-user needs a value}; KEEP_USER=0; shift 2 ;;
      -n|--dry-run)  DRY_RUN=1; shift ;;
      -y|--yes)      LISTENER_YES=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

# Refuse to rm a prefix that is not a plausible install root. The prefix is an
# rm -rf target, so it is checked lexically here -- the same defence
# lib/common.sh applies to RUNNER_HOME -- rather than trusted because it came
# from a flag.
assert_removable_prefix() {
  local dir=$1
  [[ ${dir} = /* ]] || { echo "FAIL: --prefix must be absolute: '${dir}'" >&2; exit 1; }
  case "${dir%/}" in
    ""|/|/etc|/usr|/var|/home|/opt|/root|"${HOME:-}")
      echo "FAIL: refusing to remove '${dir}'" >&2; exit 1 ;;
  esac
  case "/${dir}/" in
    */../*) echo "FAIL: --prefix must be normalized (no '..'): '${dir}'" >&2; exit 1 ;;
  esac
}

main() {
  parse_args "$@"
  listener_deploy_paths
  assert_removable_prefix "${LISTENER_PREFIX}"

  echo "Plan:"
  echo "  Stop + disable:   ${LISTENER_UNIT_NAME}"
  echo "  Remove unit:      ${LISTENER_UNIT_PATH}"
  echo "  Remove env file:  ${LISTENER_ENV_FILE}   (holds the admin token)"
  echo "  Remove prefix:    ${LISTENER_PREFIX}"
  if (( KEEP_USER )); then
    echo "  Service user:     left in place"
  else
    echo "  Remove user:      ${SERVICE_USER}"
  fi
  echo "  NOT touched:      the scale set on GitHub (shared by every machine"
  echo "                    serving this runner type). Delete it deliberately:"
  echo "                      scaleset-admin delete --config <path> --type <name> --yes"
  echo

  if (( DRY_RUN )); then
    echo "Dry run; nothing was removed."
    exit 0
  fi

  listener_confirm "Proceed? [y/N] "

  if listener_unit_active "${LISTENER_UNIT_NAME}"; then
    _systemctl stop "${LISTENER_UNIT_NAME}"
    echo "  stopped:          ${LISTENER_UNIT_NAME}"
  else
    echo "  stop:             ${LISTENER_UNIT_NAME} was not running, skipped"
  fi

  if listener_unit_enabled "${LISTENER_UNIT_NAME}"; then
    _systemctl disable "${LISTENER_UNIT_NAME}" >/dev/null 2>&1 || true
    echo "  disabled:         ${LISTENER_UNIT_NAME}"
  else
    echo "  disable:          ${LISTENER_UNIT_NAME} was not enabled, skipped"
  fi

  if [[ -f ${LISTENER_UNIT_PATH} ]]; then
    rm -f "${LISTENER_UNIT_PATH}"
    _systemctl daemon-reload
    echo "  removed unit:     ${LISTENER_UNIT_PATH}"
  else
    echo "  unit:             already absent, skipped"
  fi

  if [[ -f ${LISTENER_ENV_FILE} ]]; then
    rm -f "${LISTENER_ENV_FILE}"
    echo "  removed env file: ${LISTENER_ENV_FILE}"
  else
    echo "  env file:         already absent, skipped"
  fi

  if [[ -d ${LISTENER_PREFIX} ]]; then
    rm -rf "${LISTENER_PREFIX}"
    echo "  removed prefix:   ${LISTENER_PREFIX}"
  else
    echo "  prefix:           already absent, skipped"
  fi

  if (( ! KEEP_USER )) && listener_service_user_exists "${SERVICE_USER}"; then
    userdel -r "${SERVICE_USER}" >/dev/null 2>&1 || true
    echo "  removed user:     ${SERVICE_USER}"
  fi

  echo
  echo "This machine no longer serves the runner type."
  echo "The scale set on GitHub is untouched."
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
