#!/usr/bin/env bash
# Stand a scale-set listener up on this machine, interactively, in one command.
#
# This replaces the multi-step manual runbook in deploy/README.md -- build,
# install, create a service user, write a 0600 environment file, install a
# systemd unit, enable it, start it -- which is why nothing had ever actually
# been deployed. A runbook is a thing people mean to follow; this is a thing
# people run.
#
# It covers TWO HALVES and says which is which:
#
#   GitHub side -- creating the runner type's scale set, if it does not already
#                  exist. This changes something OUTSIDE this machine, so it is
#                  announced in full and confirmed before anything happens.
#   Local side  -- build, install under the prefix, service user, environment
#                  file, systemd unit, enable, start, verify.
#
# Standing up the SECOND machine needs no GitHub half at all: the scale set is
# already there. Pass --skip-github, or let the idempotent create report it.
#
# IDEMPOTENT: every step detects what is already in place and skips it rather
# than failing, so re-running after a partial run (or after a config change) is
# the normal way to use it.
#
# THE TOKEN IS PROMPTED FOR, NEVER A FLAG. /proc/<pid>/cmdline is world-readable,
# so a token in an argument is a token any local user can read, and it would sit
# in the operator's shell history besides. There is deliberately no --token.
#
# Usage:
#   sudo ./script/deploy-listener.sh --org-url https://github.com/<org>
#   sudo ./script/deploy-listener.sh --dry-run ...        # print the plan
#   sudo ./script/deploy-listener.sh --yes ...            # unattended
#   ./script/deploy-listener.sh -h | --help
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=SCRIPTDIR/../lib/listener-deploy.sh
source "${SCRIPT_DIR}/../lib/listener-deploy.sh"

LISTENER_YES=0
DRY_RUN=0
SKIP_GITHUB=0
ORG_URL=""
TYPE_NAME="${RUNNER_TYPE:-}"
TYPES_CONFIG="${RUNNER_TYPES_CONFIG:-}"
LABELS_OPT=""
GROUP_OPT=""
SERVICE_USER="ci-runner"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Stand a scale-set listener up on this machine in one command: the GitHub side
(create the runner type's scale set if it is not there yet) and the local side
(build, install, service user, environment file, systemd unit, enable, start,
verify). Idempotent -- re-running skips whatever is already in place.

The runner-type config is read through the scale-set admin tool, which is taken
from this checkout's build output, else from PATH, and BUILT (just build-admin)
when there is neither -- so a clean checkout needs no preparation. Set
SCALESET_ADMIN_BIN to name a particular binary instead.

Options:
  --org-url <url>     https://github.com/<org> (required unless --skip-github
                      and an environment file already exists)
  --config <path>     runner-type config (default: the installed one, else
                      deploy/runner-types.sample.yaml)
  --type <name>       which runner type to deploy (may be omitted when the
                      config holds exactly one)
  --labels <csv>      routing labels for the type. Omit to keep what the config
                      says; a type with no labels routes on its scale set name.
                      THIS IS WHAT WORKFLOWS TARGET, not the scale set name.
  --group <name>      runner group to create the scale set in (default: Default)
  --prefix <path>     install prefix (default: /opt/github-runner-listener)
  --etc <path>        config dir (default: /etc/github-runner-listener)
  --unit-dir <path>   where the systemd unit is installed
                      (default: /etc/systemd/system)
  --user <name>       service user the unit runs as (default: ci-runner)
  --skip-github       do the local half only -- for the second and later
                      machines, where the scale set already exists
  -n, --dry-run       print the plan; install nothing and change nothing on
                      GitHub. It may still build the admin tool it has to read
                      the config with, and it says so when it does
  -y, --yes           skip the confirmation. REQUIRED for non-interactive runs
                      (stdin is not a TTY); the token is then read from stdin.
  -h, --help          show this help

The admin token is PROMPTED for. There is no --token flag: an argument is
visible in the host process table and in shell history.

Exit code:
  0  Deployed (or dry-run / aborted at the prompt).
  1  Bad usage, a step failed, verification failed, or a non-interactive run
     was attempted without --yes.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --org-url)   ORG_URL=${2:?--org-url needs a value}; shift 2 ;;
      --config)    TYPES_CONFIG=${2:?--config needs a value}; shift 2 ;;
      --type)      TYPE_NAME=${2:?--type needs a value}; shift 2 ;;
      --labels)    LABELS_OPT=${2:?--labels needs a value}; shift 2 ;;
      --group)     GROUP_OPT=${2:?--group needs a value}; shift 2 ;;
      --prefix)    LISTENER_PREFIX=${2:?--prefix needs a value}; shift 2 ;;
      --etc)       LISTENER_ETC=${2:?--etc needs a value}; shift 2 ;;
      --unit-dir)  LISTENER_UNIT_DIR=${2:?--unit-dir needs a value}; shift 2 ;;
      --user)      SERVICE_USER=${2:?--user needs a value}; shift 2 ;;
      --skip-github) SKIP_GITHUB=1; shift ;;
      -n|--dry-run)  DRY_RUN=1; shift ;;
      -y|--yes)      LISTENER_YES=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

# The runner-type config to read: an explicit --config, else the one already
# installed on this host, else the shipped sample.
resolve_config() {
  if [[ -z ${TYPES_CONFIG} ]]; then
    if [[ -f "${LISTENER_ETC}/runner-types.yaml" ]]; then
      TYPES_CONFIG="${LISTENER_ETC}/runner-types.yaml"
    else
      TYPES_CONFIG="${REPO_ROOT}/deploy/runner-types.sample.yaml"
    fi
  fi
  if [[ ! -f ${TYPES_CONFIG} ]]; then
    echo "FAIL: no runner-type config at ${TYPES_CONFIG}" >&2
    exit 1
  fi
}

main() {
  parse_args "$@"
  listener_deploy_paths
  resolve_config

  # The admin tool, before anything else needs it: everything below reads the
  # runner-type config THROUGH it, so a run without one cannot even produce a
  # plan. That is why it is found -- or built -- here, rather than assumed to
  # be on PATH. (resolve_config runs first only because it is a local file
  # check that costs nothing; building a Go binary and only then announcing
  # that the named config does not exist would be a strange way to spend a
  # minute.)
  local admin_rc=0
  listener_resolve_admin_bin "${REPO_ROOT}" || admin_rc=$?
  (( admin_rc == 0 )) || exit 1

  # Ask the Go loader what the config says (ADR-0003: it is the only parser).
  # A failure here is a bad config, and it must stop the run rather than be
  # papered over with empty strings.
  local scale_set labels runs_on image
  local read_rc=0
  scale_set=$(listener_config_scaleset "${TYPES_CONFIG}" "${TYPE_NAME}") || read_rc=$?
  if (( read_rc != 0 )); then
    # A tool that could not be RUN has already named itself; adding "could not
    # read <config>" on top of that would point at a file that is perfectly
    # fine, which is exactly the wrong-fault message this replaces.
    (( read_rc == LISTENER_ADMIN_NOT_FOUND )) \
      || echo "FAIL: could not read ${TYPES_CONFIG} (${SCALESET_ADMIN_BIN} rejected it)" >&2
    exit 1
  fi
  if [[ -z ${scale_set} ]]; then
    echo "FAIL: could not read a runner type from ${TYPES_CONFIG}" >&2
    echo "      (name one with --type when the config holds more than one)" >&2
    exit 1
  fi
  labels=$(listener_config_labels "${TYPES_CONFIG}" "${TYPE_NAME}")
  image=$(listener_config_image "${TYPES_CONFIG}" "${TYPE_NAME}")

  # The interaction is what settles the labels, and whatever it settles on is
  # written back into the config -- the config does not become a second source
  # of truth, it stays the only one. --labels overrides what is recorded; with
  # nothing recorded and nothing given, the labels become exactly the scale set
  # name (mode 1), stated explicitly rather than left to an implicit fallback.
  local chosen_labels
  chosen_labels=$(listener_default_labels "${LABELS_OPT:-${labels}}" "${scale_set}")
  runs_on=$(listener_runs_on_line "${TYPES_CONFIG}" "${TYPE_NAME}")
  if [[ -n ${LABELS_OPT} && ${LABELS_OPT} != "${labels}" ]]; then
    runs_on="runs-on: [${LABELS_OPT//,/, }]"
  fi

  # --- the plan ------------------------------------------------------------
  echo "Plan"
  echo
  if (( SKIP_GITHUB )); then
    echo "  GitHub side:      skipped (--skip-github); the scale set is assumed to exist"
  else
    echo "  GitHub side:"
    echo "    Scale set:      ${scale_set}   (an identifier)"
    echo "    Routing labels: ${chosen_labels}   (what a workflow's runs-on matches)"
    echo "    Runner group:   ${GROUP_OPT:-Default}"
    echo "    Action:         create it if it does not already exist"
  fi
  echo
  echo "  Local side:"
  echo "    runner type:      ${TYPE_NAME:-(the only one configured)}"
  echo "    config:           ${TYPES_CONFIG}"
  echo "    admin tool:       ${SCALESET_ADMIN_BIN} (the config was read through it)"
  echo "    image:            ${image}"
  echo "    install prefix:   ${LISTENER_PREFIX}"
  echo "    service user:     ${SERVICE_USER}"
  echo "    environment file: ${LISTENER_ENV_FILE} (0600, holds the token)"
  echo "    systemd unit:     ${LISTENER_UNIT_PATH} (enable + start)"
  echo
  echo "  Workflows will target this runner type with:"
  echo "      ${runs_on}"
  echo

  if (( DRY_RUN )); then
    echo "Dry run; nothing was changed, here or on GitHub."
    # Said out loud rather than glossed over: a first dry run may have had to
    # build the admin tool to read the config at all, and a claim that nothing
    # changed has to be true of the build output too.
    (( ${LISTENER_ADMIN_BUILT:-0} )) \
      && echo "  (the scale-set admin tool was built into ${SCALESET_ADMIN_BIN}; that is all this run wrote.)"
    exit 0
  fi

  if (( EUID != 0 )); then
    echo "NOTE: the local half installs under ${LISTENER_PREFIX} and writes to" >&2
    echo "      /etc and /etc/systemd/system; run this with sudo if it fails." >&2
    echo
  fi

  listener_confirm "Proceed? [y/N] "
  echo

  # --- the token, ONCE, before anything needs it ---------------------------
  # Both halves want it: the GitHub side authenticates the create with it, and
  # the local side writes it into the EnvironmentFile. The GitHub side runs
  # first, so prompting at the env-file step would leave the create with nothing
  # and fail every first-time deploy on a host that had not already exported
  # GITHUB_TOKEN. One prompt, asked up front, serves both.
  #
  # It is only asked for when it is actually needed: a --skip-github re-run
  # whose environment file is already in place needs no token at all.
  local need_token=0
  (( SKIP_GITHUB )) || need_token=1
  listener_env_file_ready "${LISTENER_ENV_FILE}" || need_token=1
  if (( need_token )) && [[ -z ${LISTENER_TOKEN:-} ]]; then
    if [[ -n ${GITHUB_TOKEN:-} ]]; then
      # Already in the environment (an unattended run); do not ask again.
      LISTENER_TOKEN="${GITHUB_TOKEN}"
    else
      listener_prompt_secret "GitHub admin token (scale-set admin scope, input hidden): "
    fi
    [[ -n ${LISTENER_TOKEN:-} ]] || { echo "FAIL: no token provided" >&2; exit 1; }
  fi

  # --- record the labels ---------------------------------------------------
  # Whatever the interaction settled on goes into the config, so the routing key
  # is written down and not just in this terminal's scrollback.
  if [[ -n ${LABELS_OPT} && ${LABELS_OPT} != "${labels}" ]]; then
    local target_config="${LISTENER_ETC}/runner-types.yaml"
    listener_write_type_config "${target_config}" \
      "${TYPE_NAME:-default}" "${scale_set}" "${chosen_labels}" "${image}"
    echo "  config:           recorded labels [${chosen_labels//,/, }] in ${target_config}"
    TYPES_CONFIG="${target_config}"
  fi

  # --- GitHub side ---------------------------------------------------------
  if (( SKIP_GITHUB )); then
    echo "GitHub side: skipped."
  else
    echo "GitHub side:"
    local admin_args=(create --config "${TYPES_CONFIG}")
    [[ -n ${TYPE_NAME} ]] && admin_args+=(--type "${TYPE_NAME}")
    [[ -n ${GROUP_OPT} ]] && admin_args+=(--group "${GROUP_OPT}")
    # The token reaches the child through the ENVIRONMENT, never its argv.
    GITHUB_CONFIG_URL="${ORG_URL}" GITHUB_TOKEN="${LISTENER_TOKEN:-}" \
      _scaleset_admin "${admin_args[@]}"
  fi
  echo

  # --- Local side ----------------------------------------------------------
  echo "Local side:"
  _just --justfile "${REPO_ROOT}/justfile" --working-directory "${REPO_ROOT}" \
    "PREFIX=${LISTENER_PREFIX}" install-listener >/dev/null
  echo "  build+install:    ${LISTENER_PREFIX}"

  listener_ensure_service_user "${SERVICE_USER}"

  if listener_env_file_ready "${LISTENER_ENV_FILE}"; then
    echo "  environment file: ${LISTENER_ENV_FILE} already in place (0600), skipped"
  else
    listener_write_env_file "${LISTENER_ENV_FILE}" "${ORG_URL}" \
      "${TYPES_CONFIG}" "${TYPE_NAME}"
  fi

  local unit_src="${REPO_ROOT}/deploy/scaleset-listener.service"
  if listener_unit_current "${unit_src}" "${LISTENER_UNIT_PATH}"; then
    echo "  systemd unit:     ${LISTENER_UNIT_PATH} already current, skipped"
  else
    listener_install_unit "${unit_src}" "${LISTENER_UNIT_PATH}"
  fi

  listener_enable_unit "${LISTENER_UNIT_NAME}"
  listener_start_unit "${LISTENER_UNIT_NAME}"
  echo

  # --- verify --------------------------------------------------------------
  echo "Verifying:"
  listener_verify "${LISTENER_UNIT_NAME}"
  echo

  # --- what to do next -----------------------------------------------------
  cat <<EOF
Deployed.

Run your first job. Workflows target this runner type by its LABELS -- the
scale set name is only an identifier -- so the job must ask for exactly:

    ${runs_on}

A whole workflow that will land here:

    on: workflow_dispatch
    jobs:
      smoke:
        ${runs_on}
        steps:
          - run: echo "ran on \$(hostname)"

Dispatch it, then watch this host pick it up:

    journalctl -u ${LISTENER_UNIT_NAME} -f

The job's REST status stays "queued" even after it has been assigned to the
scale set, so watch the journal rather than the queued/in-progress field.

To take this machine back down: ./script/teardown-listener.sh
EOF
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
