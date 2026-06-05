#!/usr/bin/env bash
# Runner Service -- the single seam over a runner's systemd service. Before
# this module, add-runner / remove-runner / update each open-coded the same
# `pushd "${dir}"; sudo ./svc.sh <verb>; popd` dance (cwd-is-the-runner-dir +
# sudo + the bundled svc.sh, all assumed independently), and the unit-name
# convention lived apart in runner_service_running. They now route here.
#
# Sourced by lib/common.sh AFTER runner-layout.sh (runner_service_running uses
# runner_service_unit_pattern). svc.sh ships inside each runner dir from the
# actions/runner tarball, so each verb runs from that dir (a subshell `cd`,
# which restores cwd even on failure) as root.
# shellcheck shell=bash

# Run a runner's bundled svc.sh verb from inside its dir, as root.
_runner_svc() {
  local dir=$1; shift
  ( cd "${dir}" && sudo ./svc.sh "$@" )
}

# install / start propagate failure -- the caller (add-runner) cares whether
# the service actually came up.
runner_service_install() { _runner_svc "$1" install "$2"; }
runner_service_start()   { _runner_svc "$1" start; }

# stop / uninstall are best-effort: teardown (remove-runner / update) must not
# abort just because the service was already gone.
runner_service_stop()      { _runner_svc "$1" stop      || true; }
runner_service_uninstall() { _runner_svc "$1" uninstall || true; }

# Is the runner's systemd service currently active? Matches the unit
# actions/runner installs (see runner_service_unit_pattern in runner-layout).
runner_service_running() {
  local name=$1
  systemctl list-units --type=service --no-legend 2>/dev/null \
    | grep -qE "$(runner_service_unit_pattern "${name}")"
}
