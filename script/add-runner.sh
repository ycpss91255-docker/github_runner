#!/usr/bin/env bash
# Register a new self-hosted runner (org or repo level). Idempotent.
# Usage:
#   ./script/add-runner.sh org <org>
#   ./script/add-runner.sh repo <owner> <repo>
set -euo pipefail

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") org <org>
  $(basename "$0") repo <owner> <repo>

Register a new self-hosted runner (org- or repo-level). Idempotent.
EOF
}

main() {
  case "${1:-}" in -h|--help) usage; exit 0 ;; esac
  case "${1:-}" in
    org|repo) ;;
    *) usage >&2; exit 1 ;;
  esac
  resolve_target "$@"

  if [[ -f "${TARGET_DIR}/.runner" ]]; then
    # The runner is registered. Only treat it as "already configured" if its
    # systemd service is actually active: a prior run whose `sudo ./svc.sh
    # install/start` failed after config.sh wrote .runner leaves the runner
    # registered with its service missing/stopped. In that case converge by
    # (re)running the service-install/start steps instead of falsely reporting
    # success.
    if runner_service_running "${TARGET_NAME}"; then
      echo "runner at ${TARGET_DIR} already configured."
      echo "use ./script/remove-runner.sh first if you want to re-register."
      exit 0
    fi
    echo "runner at ${TARGET_DIR} is registered but its service is missing/stopped; (re)installing it." >&2
    pushd "${TARGET_DIR}" >/dev/null
    sudo ./svc.sh install "$(whoami)"
    sudo ./svc.sh start
    popd >/dev/null
    echo "service (re)installed for ${TARGET_NAME} at ${TARGET_DIR}"
    exit 0
  fi

  local tarball_path
  tarball_path=$(find_cached_tarball)
  if [[ -z ${tarball_path} ]]; then
    echo "tarball missing. run ./script/init.sh first." >&2
    exit 1
  fi

  # Resolve registration labels from setup.conf (default gpu when absent).
  load_config

  require_gh_auth
  local token
  token=$(github_runner_token "${TARGET_API_TOKEN_PATH}")

  mkdir -p "${TARGET_DIR}"
  # B1 idempotency: if extraction or registration fails before .runner is
  # written, remove the partial dir so a retry starts clean (the re-run guard
  # keys on .runner, which a crashed run would leave absent over a half-
  # populated tree). Cleared once config.sh has persisted .runner.
  trap 'rm -rf "${TARGET_DIR}"' ERR
  tar -xzf "${tarball_path}" -C "${TARGET_DIR}"

  pushd "${TARGET_DIR}" >/dev/null
  ./config.sh --unattended \
    --url    "${TARGET_URL}" \
    --token  "${token}" \
    --labels "${LABELS}" \
    --name   "${TARGET_NAME}" \
    --work   _work
  trap - ERR   # registration persisted (.runner written); keep the dir
  sudo ./svc.sh install "$(whoami)"
  sudo ./svc.sh start
  popd >/dev/null

  # Unstick public-repo workflow dispatch (see lib/common.sh comment + #6).
  # Only meaningful for org-scoped runners; repo-scoped runners do not have
  # a runner-group flag.
  if [[ ${1:-} == "org" ]]; then
    enable_public_repos_dispatch "$2"
  fi

  echo "registered: ${TARGET_NAME} at ${TARGET_DIR}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
