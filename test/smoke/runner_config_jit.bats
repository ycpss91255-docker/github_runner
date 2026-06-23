#!/usr/bin/env bats
# Smoke tests for the JIT config generation seam (ADR-0001, issue #80): the
# server-side single-use runner config that replaces the config.sh-once
# registration + persistent .runner marker (no long-lived token on the host).
#
# Two layers, both shadowing the single _gh() wrapper so no live gh / network
# is touched (the runner_config.bats / github_api.bats pattern):
#   - github_jit_config_generate -- the lib/common.sh GitHub adapter that POSTs
#     the JSON body to .../generate-jitconfig and extracts .encoded_jit_config.
#   - runner_config_jit_generate -- the lib/runner-config.sh seam that composes
#     scope/owner[/repo] + name/labels into that adapter call.
#
# _gh is shadowed with a fake that records its argv to a CAP file (so the
# endpoint + JSON body fields can be asserted) and echoes a canned JSON
# response (so .encoded_jit_config extraction can be asserted).

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
  source "${LIB}"

  CAP="${FAKE_RH}/gh.args"
  # Canned generate-jitconfig response: only .encoded_jit_config is consumed;
  # the surrounding object proves the verb selects that field, not the whole
  # body. _gh records its argv one-per-line so the endpoint + -f/-F fields can
  # be grepped exactly.
  _gh() {
    printf '%s\n' "$@" > "${CAP}"
    printf 'ENCODEDxJITxCONFIGx==\n'
  }
}

teardown() { rm -rf "${FAKE_RH}"; }

# --- github_jit_config_generate (lib/common.sh adapter) -----------------

@test "github_jit_config_generate POSTs the org-scoped generate-jitconfig endpoint" {
  run github_jit_config_generate \
    /orgs/acme/actions/runners/generate-jitconfig host-acme-org 1 gpu,cuda _work
  [ "${status}" -eq 0 ]
  grep -qxF -- 'POST' "${CAP}"
  grep -qxF -- '/orgs/acme/actions/runners/generate-jitconfig' "${CAP}"
}

@test "github_jit_config_generate POSTs the repo-scoped generate-jitconfig endpoint" {
  run github_jit_config_generate \
    /repos/acme/widgets/actions/runners/generate-jitconfig host-acme-widgets 1 gpu _work
  [ "${status}" -eq 0 ]
  grep -qxF -- '/repos/acme/widgets/actions/runners/generate-jitconfig' "${CAP}"
}

@test "github_jit_config_generate sends name, runner_group_id, work_folder and one labels[] per token" {
  run github_jit_config_generate \
    /orgs/acme/actions/runners/generate-jitconfig host-acme-org 1 gpu,cuda12 _work
  [ "${status}" -eq 0 ]
  grep -qxF -- 'name=host-acme-org' "${CAP}"
  grep -qxF -- 'runner_group_id=1' "${CAP}"
  grep -qxF -- 'work_folder=_work' "${CAP}"
  grep -qxF -- 'labels[]=gpu' "${CAP}"
  grep -qxF -- 'labels[]=cuda12' "${CAP}"
}

@test "github_jit_config_generate extracts the .encoded_jit_config field" {
  run github_jit_config_generate \
    /orgs/acme/actions/runners/generate-jitconfig host-acme-org 1 gpu _work
  [ "${status}" -eq 0 ]
  [ "${output}" = "ENCODEDxJITxCONFIGx==" ]
}

@test "github_jit_config_generate propagates a gh failure as a non-zero exit" {
  _gh() { return 1; }
  run github_jit_config_generate \
    /orgs/acme/actions/runners/generate-jitconfig host-acme-org 1 gpu _work
  [ "${status}" -ne 0 ]
}

# --- runner_config_jit_generate (lib/runner-config.sh seam) -------------

@test "runner_config_jit_generate composes the org-scoped endpoint and returns the encoded config" {
  run runner_config_jit_generate org acme "" gpu,cuda host-acme-org
  [ "${status}" -eq 0 ]
  [ "${output}" = "ENCODEDxJITxCONFIGx==" ]
  grep -qxF -- '/orgs/acme/actions/runners/generate-jitconfig' "${CAP}"
  grep -qxF -- 'name=host-acme-org' "${CAP}"
  grep -qxF -- 'labels[]=gpu' "${CAP}"
  grep -qxF -- 'labels[]=cuda' "${CAP}"
}

@test "runner_config_jit_generate composes the repo-scoped endpoint from owner + repo" {
  run runner_config_jit_generate repo acme widgets gpu host-acme-widgets
  [ "${status}" -eq 0 ]
  [ "${output}" = "ENCODEDxJITxCONFIGx==" ]
  grep -qxF -- '/repos/acme/widgets/actions/runners/generate-jitconfig' "${CAP}"
  grep -qxF -- 'name=host-acme-widgets' "${CAP}"
}

@test "runner_config_jit_generate requests _work and runner group 1 by default" {
  run runner_config_jit_generate org acme "" gpu host-acme-org
  [ "${status}" -eq 0 ]
  grep -qxF -- 'work_folder=_work' "${CAP}"
  grep -qxF -- 'runner_group_id=1' "${CAP}"
}

@test "runner_config_jit_generate returns non-zero on an unknown scope" {
  run runner_config_jit_generate bogus acme "" gpu host
  [ "${status}" -ne 0 ]
}
