#!/usr/bin/env bash
# Bring the lightweight CLI prerequisites up to ready on an apt/Ubuntu host,
# then drive `gh auth login` -- the manual step before ./script/init.sh works.
# Scope: gh, jq, curl, sudo. Docker engine + the NVIDIA Container Toolkit are
# assumed already installed (see README Requirements); this script never
# touches them. Idempotent: present deps are skipped, auth is skipped when
# already authenticated.
#
# Usage:
#   ./script/install-deps.sh            # prompt before each install, then auth
#   ./script/install-deps.sh -y         # accept every install prompt (apt -y)
#   ./script/install-deps.sh --dry-run  # report what's missing; install nothing
#   ./script/install-deps.sh -h         # help
#
# Prompts are apt-style (Enter = proceed/install), the opposite of the
# destructive scripts' [y/N] (Enter = abort) -- this script only adds packages.
set -euo pipefail

# CLI prerequisites this script manages. gh needs GitHub's apt repo; the rest
# are plain apt packages.
DEPS=(gh jq curl sudo)
YES=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [-y | --yes] [-n | --dry-run] [-h | --help]

Install the CLI prerequisites (gh, jq, curl, sudo) on an apt/Ubuntu host and
run \`gh auth login --scopes admin:org\`. Docker + the NVIDIA Container Toolkit
are assumed already installed.

Options:
  -y, --yes        Accept every install prompt (like apt-get install -y). The
                   final \`gh auth login\` is still interactive.
  -n, --dry-run    Report which deps are missing + gh auth status; install nothing.
  -h, --help       Show this help.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -y|--yes)     YES=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command as root: directly when already root, else via sudo.
run_root() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Ask before a destructive/system change; -y skips. Default is yes (apt-style).
confirm() {
  (( YES )) && return 0
  local ans
  read -r -p "$1 [Y/n] " ans
  case ${ans} in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

# Install GitHub CLI from its official apt repository (only when gh is absent).
install_gh() {
  run_root mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | run_root tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  run_root chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | run_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  run_root apt-get update
  run_root apt-get install -y gh
}

# --dry-run report: what's missing + gh auth status. Installs nothing, so it
# works on any host (even without apt).
report() {
  local d missing=()
  for d in "${DEPS[@]}"; do have "$d" || missing+=("$d"); done
  if (( ${#missing[@]} )); then
    echo "missing CLI deps: ${missing[*]}"
  else
    echo "all CLI deps present: ${DEPS[*]}"
  fi
  if have gh; then
    if gh auth status >/dev/null 2>&1; then
      echo "gh: authenticated"
    else
      echo "gh: not authenticated (would run: gh auth login --scopes admin:org)"
    fi
  else
    echo "gh: not installed"
  fi
}

main() {
  parse_args "$@"

  if (( DRY_RUN )); then
    report
    exit 0
  fi

  have apt-get || {
    echo "FAIL: install-deps.sh supports apt (Ubuntu/Debian) hosts only." >&2
    echo "      Install gh / jq / curl / sudo with your package manager, then run gh auth login." >&2
    exit 1
  }
  if [[ $(id -u) -ne 0 ]] && ! have sudo; then
    echo "FAIL: need root or sudo to install packages (run as root, or install sudo first)." >&2
    exit 1
  fi

  # Plain apt packages first (curl is needed to add the gh repo).
  local d plain=()
  for d in jq curl sudo; do have "$d" || plain+=("$d"); done
  if (( ${#plain[@]} )); then
    if confirm "Install ${plain[*]} via apt?"; then
      run_root apt-get update
      run_root apt-get install -y "${plain[@]}"
    fi
  fi

  if ! have gh; then
    if confirm "Install gh (GitHub CLI) from GitHub's apt repo?"; then
      install_gh
    fi
  fi

  if have gh; then
    if gh auth status >/dev/null 2>&1; then
      echo "gh already authenticated."
    else
      echo "==> launching gh auth login (interactive)..."
      gh auth login --scopes admin:org
    fi
  fi

  echo "deps ready. Next: ./script/init.sh <org>"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
