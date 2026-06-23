#!/usr/bin/env bash
# Runner Run -- the ephemeral single-job run seam (ADR-0001, advances #80).
# The sibling of runner-service.sh for the JIT model: where runner-service.sh
# installs a long-lived systemd service (svc.sh) that processes an unbounded
# sequence of jobs, this runs a runner ONCE from its dir against a server-side
# JIT config and lets the process exit. One job -> exit -> the ephemeral runner
# auto-deregisters. No svc.sh, no systemd, no sudo: run.sh ships inside each
# runner dir (from the actions/runner tarball) and is invoked directly.
#
# Sourced by lib/common.sh. The verb runs from the runner dir via a subshell
# `cd` (restores cwd even on failure) and PROPAGATES run.sh's exit status --
# the caller cares whether the single job ran cleanly (it is the whole
# lifecycle, unlike svc.sh start which only reports the service came up).
# shellcheck shell=bash

# Serve exactly one job from a runner dir using its single-use JIT config
# (runner_config_jit_generate's encoded output), then return run.sh's status.
#   runner_run_jit <dir> <encoded_jit_config>
runner_run_jit() {
  local dir=$1 encoded=$2
  ( cd "${dir}" && ./run.sh --jitconfig "${encoded}" )
}
