# Shared constants and helpers for github_runner scripts.
# This file is sourced by every script under script/ (init, add-runner,
# remove-runner, status, update, uninstall, cleanup, schedule-cleanup)
# -- variables that look unused here are consumed in those scripts.
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

# Static fallback used when dynamic resolution fails (offline, gh missing /
# unauthenticated, GitHub rate-limited). Bump opportunistically when fresh
# installs in those degraded states should not start months behind. GitHub
# self-hosted runners always self-update on connect, so this is only the
# bootstrap version, not the runtime one. Refs #10.
readonly RUNNER_VERSION_FALLBACK="2.334.0"

# Resolve the actions/runner version to download:
#   1. If $RUNNER_VERSION is set, honour it verbatim (caller knows best).
#   2. Otherwise ask GitHub for the latest released tag.
#   3. If gh is missing / unauthenticated / network-unreachable / the
#      response is empty for any other reason, fall back to
#      $RUNNER_VERSION_FALLBACK.
#
# Output: bare version string (no leading 'v'), e.g. "2.334.0".
resolve_runner_version() {
  if [[ -n "${RUNNER_VERSION:-}" ]]; then
    echo "${RUNNER_VERSION}"
    return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "${RUNNER_VERSION_FALLBACK}"
    return
  fi
  local resolved
  resolved=$(gh api /repos/actions/runner/releases/latest --jq .tag_name 2>/dev/null \
             | sed 's/^v//' || true)
  if [[ -z ${resolved} ]]; then
    echo "${RUNNER_VERSION_FALLBACK}"
    return
  fi
  echo "${resolved}"
}

# Return the path to the highest-version cached tarball under
# ${RUNNER_HOME}/.bin/, or empty if none. Multiple tarballs may coexist
# (e.g. after an update.sh bump that kept the prior one); add-runner.sh
# uses the highest so newly-registered runners do not start behind.
find_cached_tarball() {
  shopt -s nullglob
  local candidates=("${RUNNER_HOME}/.bin/"actions-runner-linux-x64-*.tar.gz)
  shopt -u nullglob
  if (( ${#candidates[@]} == 0 )); then
    return
  fi
  printf '%s\n' "${candidates[@]}" | sort -V | tail -1
}

# Flip the Default runner group's allows_public_repositories flag on, so
# workflows in public repos within the org can actually dispatch to the
# newly-registered self-hosted runner. GitHub's 2024+ default is false,
# which silently strands public-repo jobs in queued state (the runner is
# online and idle, but never receives JobRequest). We rely on the
# org-level "Require approval for all outside collaborators" gate (set per
# ADR-0011 Public repo security) for the security boundary the GitHub
# default would otherwise enforce.
#
# Idempotent: PATCH succeeds whether the flag is already true or not.
# Safe to call after every add-runner.sh invocation.
enable_public_repos_dispatch() {
  local org=$1
  gh api -X PATCH \
    "/orgs/${org}/actions/runner-groups/1" \
    -F allows_public_repositories=true \
    --jq '.allows_public_repositories' >/dev/null
}

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
