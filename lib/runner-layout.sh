#!/usr/bin/env bash
# Runner Layout -- the single source of truth for WHERE a runner's files live
# on disk and WHAT they are named. Before this module the knowledge below was
# re-derived independently in resolve_target (path + agent name), list_runners
# (the inverse walk + the _org sentinel), runner_service_running (the systemd
# unit name) and cleanup.sh (the active-version symlink), so a layout change in
# actions/runner would break each of them separately. They now all route here.
#
# Sourced by lib/common.sh AFTER RUNNER_HOME is validated; every function that
# touches RUNNER_HOME only reads it at call time.
# shellcheck shell=bash
# shellcheck disable=SC2034

# On-disk sentinel that distinguishes an org-scoped runner dir
# (<owner>/_org) from a repo-scoped one (<owner>/<repo>). Shared by the path
# constructor (runner_dir) and the inverse classifier (runner_scope_of), so the
# two can never drift apart.
readonly RUNNER_ORG_MARKER="_org"

# Absolute on-disk dir for a runner.
#   org  <owner>          -> ${RUNNER_HOME}/<owner>/_org
#   repo <owner> <repo>   -> ${RUNNER_HOME}/<owner>/<repo>
runner_dir() {
  local scope=$1 owner=$2 repo=${3:-}
  case ${scope} in
    org)  printf '%s\n' "${RUNNER_HOME}/${owner}/${RUNNER_ORG_MARKER}" ;;
    repo) printf '%s\n' "${RUNNER_HOME}/${owner}/${repo}" ;;
  esac
}

# GitHub agent (runner) name.
#   org  <owner>          -> <hostname>-<owner>-org
#   repo <owner> <repo>   -> <hostname>-<owner>-<repo>
runner_agent_name() {
  local scope=$1 owner=$2 repo=${3:-}
  case ${scope} in
    org)  printf '%s\n' "$(hostname)-${owner}-org" ;;
    repo) printf '%s\n' "$(hostname)-${owner}-${repo}" ;;
  esac
}

# The registration marker inside a runner dir; its presence is the definition
# of "configured". Tolerates a trailing slash on the dir.
runner_marker_file() { printf '%s\n' "${1%/}/.runner"; }

# Classify a runner dir back to its scope from the on-disk sentinel -- the
# inverse of runner_dir's org/repo branch.
runner_scope_of() {
  if [[ "$(basename "${1%/}")" == "${RUNNER_ORG_MARKER}" ]]; then
    printf 'org\n'
  else
    printf 'repo\n'
  fi
}

# ERE that matches the systemd unit actions/runner installs for a runner:
# actions.runner.<url-slug>.<agent-name>.service. Used with `grep -qE`.
runner_service_unit_pattern() { printf '%s\n' "actions\.runner\..*\.$1\.service"; }

# Active runner version (e.g. "2.334.0") read from a runner dir's `bin`
# symlink target; empty string when the symlink is missing (unconfigured
# runner) or points somewhere unparseable.
runner_active_version() {
  local dir=$1 target
  [[ -L "${dir}/bin" ]] || return 0
  target=$(readlink "${dir}/bin")
  basename "${target}" | sed -n 's/^bin\.\(.*\)$/\1/p'
}
