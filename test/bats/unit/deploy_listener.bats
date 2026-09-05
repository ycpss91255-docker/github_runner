#!/usr/bin/env bats
# Unit spec for script/deploy-listener.sh -- flag handling, the help surface,
# the dry-run plan and the non-TTY refusal.
#
# Deployment used to be a multi-step manual runbook, which is why nothing had
# ever been deployed. This is the one interactive command that replaces it. At
# this level nothing external is touched at all: the tests exercise argument
# parsing and the preview, which is the part that must be right before any of
# it is allowed to run. The end-to-end run with stubbed externals lives at the
# integration level (doc/test-levels.md).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${ROOT}/script/deploy-listener.sh"
  WORK=$(mktemp -d)
  CONFIG="${WORK}/runner-types.yaml"
  cat > "${CONFIG}" <<'YAML'
runner_types:
  - name: gpu
    scale_set: gpu-runners
    labels: [self-hosted, linux, gpu]
    image: ghcr.io/acme/r@sha256:abc
YAML

  # The Go loader is the authoritative parser of the runner-type config
  # (ADR-0003), so the deploy command ASKS `scaleset-admin show` for the type's
  # scale set and labels rather than reading the YAML in bash. Here that command
  # is a scripted stub: it answers for the fixture above and never builds a
  # client or reaches GitHub.
  export SCALESET_ADMIN_BIN="${WORK}/scaleset-admin"
  cat > "${SCALESET_ADMIN_BIN}" <<'STUB'
#!/usr/bin/env bash
# Scripted stub: only `show` is answered; anything else is a test bug.
[ "${1:-}" = show ] || { echo "stub: unexpected verb ${1:-}" >&2; exit 64; }
for a in "$@"; do
  case "${prev:-}" in --config) cfg=$a ;; esac
  prev=$a
done
# Fail the way the real command does when the config is unreadable, so the
# script's error path is exercised rather than bypassed.
[ -f "${cfg:-}" ] || { echo "scaleset-admin: read runner-type config ${cfg:-}: no such file" >&2; exit 1; }
echo 'name=gpu'
echo 'scale_set=gpu-runners'
echo 'labels=self-hosted,linux,gpu'
echo 'image=ghcr.io/acme/r@sha256:abc'
echo 'runs_on=runs-on: [self-hosted, linux, gpu]'
STUB
  chmod +x "${SCALESET_ADMIN_BIN}"
}

teardown() { rm -rf "${WORK}"; }

@test "deploy-listener.sh exists and is executable" {
  [ -x "${SCRIPT}" ]
}

@test "deploy-listener.sh --help exits 0 and documents both halves" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage"* ]]
  # The command covers a GitHub side and a local side, and must say which is
  # which -- one of them changes something outside this machine.
  [[ "${output}" == *"GitHub"* ]]
  [[ "${output}" == *"local"* ]]
}

@test "deploy-listener.sh --help documents --dry-run and --yes" {
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--dry-run"* ]]
  [[ "${output}" == *"--yes"* ]]
}

@test "deploy-listener.sh rejects an unknown option with usage (exit 1)" {
  run "${SCRIPT}" --frobnicate
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unknown option: --frobnicate"* ]]
}

@test "deploy-listener.sh has NO --token flag: the token never reaches argv" {
  # A token passed as a flag is a token in the host process table and in shell
  # history. It is prompted for instead, so there is deliberately no way to
  # supply it on the command line.
  run "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"--token"* ]]
  run grep -F -- '--token)' "${SCRIPT}"
  [ "${status}" -ne 0 ]
}

@test "deploy-listener.sh --dry-run prints the plan and changes nothing" {
  run "${SCRIPT}" --dry-run --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme --prefix "${WORK}/opt" --etc "${WORK}/etc"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Dry run"* ]]
  # Nothing may have been created.
  [ ! -d "${WORK}/opt" ]
  [ ! -d "${WORK}/etc" ]
}

@test "deploy-listener.sh --dry-run plan names both halves separately" {
  run "${SCRIPT}" --dry-run --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme --prefix "${WORK}/opt" --etc "${WORK}/etc"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GitHub side"* ]]
  [[ "${output}" == *"Local side"* ]]
}

@test "deploy-listener.sh --dry-run states exactly what would be created on GitHub" {
  # The outward action is announced before it is taken -- naming the scale set
  # and the routing labels, because those are what an operator has to check.
  run "${SCRIPT}" --dry-run --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme --prefix "${WORK}/opt" --etc "${WORK}/etc"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"gpu-runners"* ]]
  [[ "${output}" == *"self-hosted"* ]]
}

@test "deploy-listener.sh --dry-run lists every local step it would perform" {
  run "${SCRIPT}" --dry-run --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme --prefix "${WORK}/opt" --etc "${WORK}/etc"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"service user"* ]]
  [[ "${output}" == *"environment file"* ]]
  [[ "${output}" == *"systemd"* ]]
}

@test "deploy-listener.sh refuses a non-interactive run without --yes" {
  # Same contract the destructive scripts carry: stdin is not a TTY, so it
  # cannot prompt, and it must refuse rather than proceed unattended.
  run bash -c "'${SCRIPT}' --config '${CONFIG}' --type gpu \
    --org-url https://github.com/acme --prefix '${WORK}/opt' --etc '${WORK}/etc'" </dev/null
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a TTY"* ]] || [[ "${output}" == *"requires --yes"* ]]
}

@test "deploy-listener.sh --dry-run works in a non-TTY without --yes (it changes nothing)" {
  # A preview is not a destructive action, so it must not be gated behind the
  # confirmation that exists to protect against unattended changes.
  run bash -c "'${SCRIPT}' --dry-run --config '${CONFIG}' --type gpu \
    --org-url https://github.com/acme --prefix '${WORK}/opt' --etc '${WORK}/etc'" </dev/null
  [ "${status}" -eq 0 ]
}

@test "deploy-listener.sh fails clearly when the runner-type config is missing" {
  run bash -c "'${SCRIPT}' --dry-run --config '${WORK}/nope.yaml' --type gpu \
    --org-url https://github.com/acme" </dev/null
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nope.yaml"* ]]
}

@test "deploy-listener.sh --skip-github makes the second machine a local-only run" {
  # Standing up machine two must not need the GitHub half at all: the scale set
  # already exists, and nothing outward should happen again.
  run "${SCRIPT}" --dry-run --skip-github --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme --prefix "${WORK}/opt" --etc "${WORK}/etc"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skip"* ]]
  [[ "${output}" == *"Local side"* ]]
}

@test "deploy-listener.sh prints the literal runs-on line the operator must use" {
  # Given that targeting the name instead of the labels is the mistake this
  # project already paid for, the exact line is printed, not described.
  run "${SCRIPT}" --dry-run --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme --prefix "${WORK}/opt" --etc "${WORK}/etc"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"runs-on:"* ]]
}
