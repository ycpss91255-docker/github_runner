#!/usr/bin/env bash
# Report the state of the scale-set admin token WITHOUT ever printing it.
#
# "Is the token there, and is it still good?" had no answer short of opening a
# root-only file and pasting the secret into a curl command -- which is how a
# token ends up in shell history and in the host process table. This reports
# what an operator needs (present / absent / placeholder, file mode, and what
# scopes GitHub says it carries) and never emits the value itself.
#
# The token reaches `gh` through the ENVIRONMENT, never argv: /proc/<pid>/cmdline
# is world-readable, so a token in an argument is a token any local user can
# read.
#
# Reading the environment file needs root, because it is 0600 and root-owned by
# design. Without root this still answers everything observable from outside the
# file (does it exist, what mode is it) and says what it could not read.
#
# Usage:
#   ./script/check-token.sh                 # inspect + verify against GitHub
#   ./script/check-token.sh --no-verify     # file-level checks only, offline
#   ./script/check-token.sh --etc <dir>     # look in a different config dir
#   ./script/check-token.sh -h | --help
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=SCRIPTDIR/../lib/listener-deploy.sh
source "${SCRIPT_DIR}/../lib/listener-deploy.sh"

VERIFY=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [--etc <dir>] [--no-verify] [-h | --help]

Report whether the scale-set admin token is in place and still valid. The token
value is never printed, never passed on a command line, and never written
anywhere by this script.

Options:
  --etc <dir>    Config dir holding the environment file
                 (default: ${LISTENER_ETC:-/etc/github-runner-listener})
  --no-verify    Skip the GitHub check; report only what the file itself shows.
                 Use offline, or when you only want the mode / presence answer.
  -h, --help     Show this help.

Exit code:
  0  Reported successfully (including "nothing deployed here yet").
  1  Bad usage, or the token was rejected by GitHub.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --etc)        LISTENER_ETC=${2:?--etc needs a value}; shift 2 ;;
      --no-verify)  VERIFY=0; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

# A token that is still the shipped sample's placeholder is a specific,
# common failure: the deploy ran, the file exists at the right mode, and
# nothing works. Worth naming rather than reporting as "present".
is_placeholder() {
  case $1 in
    "<scale-set-admin-token>"|"<token>"|""|"<"*">") return 0 ;;
    *) return 1 ;;
  esac
}

# Read one KEY=value out of the env file without sourcing it: the file lives
# under a root-owned directory but is written by an operator, and sourcing would
# execute whatever is in it.
env_value() {
  local file=$1 key=$2
  sed -n "s/^[[:space:]]*${key}=//p" "${file}" | tail -1
}

main() {
  parse_args "$@"
  listener_deploy_paths

  local file="${LISTENER_ENV_FILE}"
  echo "Environment file: ${file}"

  if [[ ! -f ${file} ]]; then
    echo "  no environment file -- nothing is deployed on this host yet."
    echo "  Stand one up with: sudo ./script/deploy-listener.sh --org-url https://github.com/<org>"
    exit 0
  fi

  # --- what the filesystem says (no root needed) ---------------------------
  local mode owner
  mode=$(stat -c '%a' "${file}" 2>/dev/null || echo '?')
  owner=$(stat -c '%U' "${file}" 2>/dev/null || echo '?')
  # Zero-pad so the reported mode lines up with the 0600 it is compared against;
  # stat prints 644, and "mode: 644 -- expected 0600" makes the reader do the
  # padding in their head.
  [[ ${mode} =~ ^[0-7]+$ ]] && mode=$(printf '%04d' "${mode}")
  if [[ ${mode} == 0600 ]]; then
    echo "  mode:  ${mode} (${owner})"
  else
    echo "  mode:  ${mode} (${owner})  -- expected 0600; it holds a credential"
  fi

  # --- what the file contains (needs read access) --------------------------
  if [[ ! -r ${file} ]]; then
    echo "  contents: not readable as $(id -un) -- re-run with sudo to check the token itself"
    exit 0
  fi

  local url token
  url=$(env_value "${file}" GITHUB_CONFIG_URL)
  token=$(env_value "${file}" GITHUB_TOKEN)

  [[ -n ${url} ]] && echo "  org URL: ${url}" || echo "  org URL: not set"

  if [[ -z ${token} ]]; then
    echo "  token:   absent -- GITHUB_TOKEN is not set in the file"
    exit 0
  fi
  if is_placeholder "${token}"; then
    echo "  token:   placeholder -- still the shipped sample value, never edited"
    echo "           Re-run deploy-listener.sh, or edit the file, to set a real token."
    exit 0
  fi
  # Length and shape only. Never the value.
  echo "  token:   present (${#token} chars)"

  if (( ! VERIFY )); then
    echo "  GitHub:  not checked (--no-verify)"
    exit 0
  fi

  # --- what GitHub says (token via env, never argv) ------------------------
  if ! command -v gh >/dev/null 2>&1; then
    echo "  GitHub:  gh not installed -- cannot verify; file-level checks above still hold"
    exit 0
  fi

  local headers rc=0
  headers=$(GH_TOKEN="${token}" gh api -i user 2>&1) || rc=$?
  if (( rc != 0 )); then
    echo "  GitHub:  REJECTED -- the token did not authenticate"
    # Surface gh's reason without risking the token appearing in it.
    printf '%s\n' "${headers}" | grep -iE '^(HTTP/|message)' | head -2 | sed 's/^/           /'
    exit 1
  fi

  local login scopes
  login=$(printf '%s\n' "${headers}" | sed -n 's/^[[:space:]]*"login": "\([^"]*\)".*/\1/p' | head -1)
  scopes=$(printf '%s\n' "${headers}" | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' | head -1)
  echo "  GitHub:  accepted${login:+ (authenticates as ${login})}"
  if [[ -n ${scopes} ]]; then
    echo "  scopes:  ${scopes}"
    # The scale-set API needs org admin. Say so rather than leaving the
    # operator to compare scope lists by eye.
    case ",${scopes//[[:space:]]/}," in
      *,admin:org,*) : ;;
      *) echo "           NOTE: admin:org is not among them -- scale-set admin calls will fail" ;;
    esac
  else
    echo "  scopes:  not reported (a fine-grained token does not list classic scopes)"
  fi
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
