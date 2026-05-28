# Shared constants and helpers for github_runner scripts.
# This file is sourced by init.sh / add-runner.sh / remove-runner.sh / status.sh
# / update.sh -- variables that look unused here are consumed in those scripts.
# shellcheck shell=bash
# shellcheck disable=SC2034

# RUNNER_HOME holds the tarball cache (.bin/) and per-target runner install
# dirs (<org>/_org/, <owner>/<repo>/). It defaults to <repo_root>/runners/
# (i.e. alongside this checkout) so a single clone owns all runner state
# without polluting $HOME. Override with RUNNER_HOME=... before invoking
# any script to install runners elsewhere.
if [[ -z "${RUNNER_HOME:-}" ]]; then
  RUNNER_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/runners"
fi
readonly RUNNER_HOME

readonly RUNNER_VERSION="${RUNNER_VERSION:-2.319.1}"
readonly RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

# Populates TARGET_URL, TARGET_DIR, TARGET_NAME, TARGET_API_TOKEN_PATH,
# TARGET_API_REMOVE_PATH from positional args.
# Usage:
#   resolve_target org <org>
#   resolve_target repo <owner> <repo>
resolve_target() {
  local scope=$1; shift
  case ${scope} in
    org)
      [[ $# -eq 1 ]] || { echo "usage: ... org <org>" >&2; exit 1; }
      local org=$1
      TARGET_URL="https://github.com/${org}"
      TARGET_DIR="${RUNNER_HOME}/${org}/_org"
      TARGET_NAME="$(hostname)-${org}-org"
      TARGET_API_TOKEN_PATH="/orgs/${org}/actions/runners/registration-token"
      TARGET_API_REMOVE_PATH="/orgs/${org}/actions/runners/remove-token"
      ;;
    repo)
      [[ $# -eq 2 ]] || { echo "usage: ... repo <owner> <repo>" >&2; exit 1; }
      local owner=$1 repo=$2
      TARGET_URL="https://github.com/${owner}/${repo}"
      TARGET_DIR="${RUNNER_HOME}/${owner}/${repo}"
      TARGET_NAME="$(hostname)-${owner}-${repo}"
      TARGET_API_TOKEN_PATH="/repos/${owner}/${repo}/actions/runners/registration-token"
      TARGET_API_REMOVE_PATH="/repos/${owner}/${repo}/actions/runners/remove-token"
      ;;
    *)
      echo "usage: {org <org> | repo <owner> <repo>}" >&2
      exit 1
      ;;
  esac
}
