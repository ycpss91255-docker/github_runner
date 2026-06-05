#!/usr/bin/env bats
# Smoke tests for the lib/common.sh GitHub API adapter (C1).
#
# Every verb reaches GitHub through the single private _gh() wrapper, so
# tests source common.sh and shadow _gh with a fake that returns canned
# output / exit codes. No live gh, no network -- the verb's own behavior
# (exit-code mapping, one call, value passthrough) is what gets exercised.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
}

@test "github_runner_status returns status<TAB>labels on a found runner (exit 0)" {
  run bash -c "
    source '${LIB}'
    _gh() { printf 'online\tgpu,cuda12\n'; }
    github_runner_status /orgs/myorg/actions/runners runner-A
  "
  [ "${status}" -eq 0 ]
  IFS=$'\t' read -r state labels <<<"${output}"
  [ "${state}" = "online" ]
  [ "${labels}" = "gpu,cuda12" ]
}

@test "github_runner_status exits 2 when the call succeeds but no runner matches" {
  run bash -c "
    source '${LIB}'
    _gh() { printf ''; }
    github_runner_status /orgs/myorg/actions/runners ghost
  "
  [ "${status}" -eq 2 ]
}

@test "github_runner_status exits 1 when the gh call itself fails" {
  run bash -c "
    source '${LIB}'
    _gh() { return 1; }
    github_runner_status /orgs/myorg/actions/runners runner-A
  "
  [ "${status}" -eq 1 ]
}

@test "runner_api_base builds the org-scoped runners collection path" {
  run bash -c "source '${LIB}'; runner_api_base org myorg"
  [ "${status}" -eq 0 ]
  [ "${output}" = "/orgs/myorg/actions/runners" ]
}

@test "runner_api_base builds the repo-scoped runners collection path" {
  run bash -c "source '${LIB}'; runner_api_base repo owner myrepo"
  [ "${status}" -eq 0 ]
  [ "${output}" = "/repos/owner/myrepo/actions/runners" ]
}

@test "runner_api_base returns non-zero and prints nothing on an unknown scope" {
  run bash -c "source '${LIB}'; runner_api_base bogus foo"
  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
}

@test "github_runner_token returns the token from the POST response" {
  run bash -c "
    source '${LIB}'
    _gh() { printf 'AABBCC\n'; }
    github_runner_token /orgs/myorg/actions/runners/registration-token
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "AABBCC" ]
}

@test "github_runner_token propagates a gh failure as a non-zero exit" {
  run bash -c "
    source '${LIB}'
    _gh() { return 1; }
    github_runner_token /orgs/myorg/actions/runners/registration-token
  "
  [ "${status}" -ne 0 ]
}

@test "github_set_labels joins the PUT RESPONSE labels (not its input) into one CSV line" {
  # D3: the canned response order/content deliberately differs from the input
  # csv, so an "echo the input back" regression cannot pass this.
  run bash -c "
    source '${LIB}'
    _gh() { printf 'cuda12\ngpu\nfast\n'; }   # server-canonicalised, != input
    github_set_labels /orgs/myorg/actions/runners 42 gpu,cuda12
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "cuda12,gpu,fast" ]
}

@test "github_set_labels sends one labels[] field per token via PUT" {
  CAP=$(mktemp)
  run bash -c "
    source '${LIB}'
    _gh() { printf '%s\n' \"\$@\" > '${CAP}'; printf 'gpu\n'; }
    github_set_labels /orgs/myorg/actions/runners 42 gpu,cuda12
  "
  [ "${status}" -eq 0 ]
  grep -qxF -- '--method' "${CAP}"
  grep -qxF -- 'PUT' "${CAP}"
  grep -qxF -- '/orgs/myorg/actions/runners/42/labels' "${CAP}"
  grep -qxF -- 'labels[]=gpu' "${CAP}"
  grep -qxF -- 'labels[]=cuda12' "${CAP}"
  rm -f "${CAP}"
}

@test "enable_public_repos_dispatch PATCHes runner-group 1 with allows_public_repositories=true" {
  CAP=$(mktemp)
  run bash -c "
    source '${LIB}'
    _gh() { printf '%s\n' \"\$@\" > '${CAP}'; printf 'true\n'; }
    enable_public_repos_dispatch myorg
  "
  [ "${status}" -eq 0 ]
  grep -qxF -- 'PATCH' "${CAP}"
  grep -qxF -- '/orgs/myorg/actions/runner-groups/1' "${CAP}"
  grep -qxF -- 'allows_public_repositories=true' "${CAP}"
  rm -f "${CAP}"
}

@test "github_public_dispatch_status echoes the runner-group flag via _gh" {
  run bash -c "source '${LIB}'; _gh() { printf 'true\n'; }; github_public_dispatch_status myorg"
  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]
}

@test "github_public_dispatch_status yields empty string when the API errors" {
  run bash -c "source '${LIB}'; _gh() { return 1; }; github_public_dispatch_status myorg"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}
