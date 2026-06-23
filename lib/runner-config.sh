#!/usr/bin/env bash
# Runner Config -- the seam over a runner's bundled config.sh (registration).
# The sibling of runner-service.sh: config.sh, like svc.sh, ships inside each
# runner dir (from the actions/runner tarball) and runs from that dir. Before
# this module add-runner / remove-runner each open-coded the
# `pushd "${dir}"; ./config.sh ...; popd` dance.
#
# Sourced by lib/common.sh. Both verbs run from the runner dir via a subshell
# `cd` (restores cwd even on failure) and PROPAGATE failure: register runs
# under add-runner's ERR trap (a failure must rm the partial dir); deregister's
# failure must abort before the local dir is removed. config.sh needs no sudo.
# shellcheck shell=bash

# Register a runner with GitHub (writes the .runner marker in the dir).
runner_config_register() {
  local dir=$1 url=$2 token=$3 labels=$4 name=$5
  ( cd "${dir}" && ./config.sh --unattended \
      --url    "${url}" \
      --token  "${token}" \
      --labels "${labels}" \
      --name   "${name}" \
      --work   _work )
}

# Deregister a runner from GitHub (removes its .runner marker).
runner_config_deregister() {
  local dir=$1 token=$2
  ( cd "${dir}" && ./config.sh remove --token "${token}" )
}

# Generate a single-use JIT config for an ephemeral runner (ADR-0001, #80) --
# the server-side counterpart of runner_config_register. Unlike register, this
# does NOT touch a runner dir, write a .runner marker, or fetch a long-lived
# registration token: GitHub mints the encoded config server-side and the
# runner consumes it once (`run.sh --jitconfig <encoded>`), then de-registers.
#   runner_config_jit_generate <scope> <owner> [<repo>] <labels> <name>
# Composes the scope/owner[/repo] into the generate-jitconfig endpoint
# (runner_api_base + /generate-jitconfig) and forwards name + labels through
# the github_jit_config_generate adapter, printing its .encoded_jit_config.
# Runner group 1 (Default) and the _work work folder match the register path's
# defaults. Returns non-zero on an unknown scope or a failing gh call.
runner_config_jit_generate() {
  local scope=$1 owner=$2 repo=$3 labels=$4 name=$5
  local base
  case ${scope} in
    org)  base=$(runner_api_base org "${owner}") ;;
    repo) base=$(runner_api_base repo "${owner}" "${repo}") ;;
    *)    return 1 ;;
  esac
  github_jit_config_generate \
    "${base}/generate-jitconfig" "${name}" 1 "${labels}" _work
}
