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
