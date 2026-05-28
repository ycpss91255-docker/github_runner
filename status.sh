#!/usr/bin/env bash
# List local runner directories and their GitHub-side online status.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

main() {
  if [[ ! -d ${RUNNER_HOME} ]]; then
    echo "no ${RUNNER_HOME} directory. run ./init.sh first."
    exit 0
  fi

  printf "%-40s %-10s %-10s %-10s\n" "NAME" "SCOPE" "LOCAL-SVC" "GITHUB"
  printf "%-40s %-10s %-10s %-10s\n" "----" "-----" "---------" "------"

  shopt -s nullglob
  local org_dir scope_dir runner_dir
  for org_dir in "${RUNNER_HOME}"/*/; do
    local org
    org=$(basename "${org_dir}")
    [[ ${org} == ".bin" ]] && continue

    for scope_dir in "${org_dir}"*/; do
      local scope
      scope=$(basename "${scope_dir}")
      runner_dir="${scope_dir}"
      [[ -f "${runner_dir}/.runner" ]] || continue

      local name
      name=$(jq -r .agentName "${runner_dir}/.runner" 2>/dev/null || echo "?")

      local svc_state="unknown"
      if systemctl list-units --type=service --no-legend 2>/dev/null \
           | grep -q "actions.runner.*${name}"; then
        svc_state="running"
      else
        svc_state="stopped"
      fi

      local gh_state="?"
      if [[ ${scope} == "_org" ]]; then
        gh_state=$(gh api "/orgs/${org}/actions/runners" \
          --jq ".runners[] | select(.name==\"${name}\") | .status" 2>/dev/null \
          || echo "n/a")
      else
        gh_state=$(gh api "/repos/${org}/${scope}/actions/runners" \
          --jq ".runners[] | select(.name==\"${name}\") | .status" 2>/dev/null \
          || echo "n/a")
      fi
      [[ -z ${gh_state} ]] && gh_state="not-found"

      local scope_label="${scope}"
      [[ ${scope} == "_org" ]] && scope_label="org"

      printf "%-40s %-10s %-10s %-10s\n" "${name}" "${scope_label}" "${svc_state}" "${gh_state}"
    done
  done
}

main "$@"
