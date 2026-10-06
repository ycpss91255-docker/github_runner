#!/usr/bin/env bats
# Executable spec for the operator recipes on the root `justfile`.
#
# WHY these exist. `just --list` is where an operator looks first, and until now
# it listed only lint / test / coverage / build work: the three things people
# actually need on a runner host -- stand one up, inspect its token, take one
# down -- were reachable only by knowing a script path. The recipes are thin
# passthroughs on purpose; the scripts keep owning the behaviour (preview,
# confirmation, --dry-run, --yes), so wrapping them must not hide a flag.
#
# Static invariants, asserted without invoking docker, just, sudo or GitHub.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  JUSTFILE="${ROOT}/justfile"
  TOKEN_SH="${ROOT}/script/check-token.sh"
}

# --- the recipes exist and are discoverable ---------------------------------

@test "justfile defines the operator recipes: deploy / teardown / remove-runner / token" {
  for r in deploy teardown remove-runner token; do
    run grep -E "^${r}( .*)?:" "${JUSTFILE}"
    [ "${status}" -eq 0 ] || { echo "missing recipe: ${r}"; return 1; }
  done
}

@test "each operator recipe forwards arguments rather than fixing them" {
  # A recipe that cannot pass --dry-run / --yes through is a worse entry point
  # than the script path it replaces, so every one takes variadic args and
  # expands them.
  for r in deploy teardown remove-runner token; do
    run grep -E "^${r} \*[A-Z]+:" "${JUSTFILE}"
    [ "${status}" -eq 0 ] || { echo "recipe ${r} takes no variadic args"; return 1; }
  done
  run grep -cE '\{\{ARGS\}\}' "${JUSTFILE}"
  [ "${status}" -eq 0 ]
  [ "${output}" -ge 4 ]
}

@test "each operator recipe delegates to its script, with no logic of its own" {
  run grep -A2 -E '^deploy \*' "${JUSTFILE}"
  [[ "${output}" == *"script/deploy-listener.sh"* ]]
  run grep -A2 -E '^teardown \*' "${JUSTFILE}"
  [[ "${output}" == *"script/teardown-listener.sh"* ]]
  run grep -A2 -E '^remove-runner \*' "${JUSTFILE}"
  [[ "${output}" == *"script/remove-runner.sh"* ]]
  run grep -A2 -E '^token \*' "${JUSTFILE}"
  [[ "${output}" == *"script/check-token.sh"* ]]
}

@test "operator recipes carry a single-line description just --list can show" {
  # `just` takes only the comment line immediately above a recipe as its
  # description. A multi-line block therefore surfaces its LAST line, which is
  # how the existing recipes ended up listed as mid-sentence fragments. The line
  # above each operator recipe must read as a whole sentence on its own.
  for r in deploy teardown remove-runner token; do
    line=$(grep -B1 -E "^${r} \*[A-Z]+:" "${JUSTFILE}" | head -1)
    [[ "${line}" == "#"* ]] || { echo "${r}: no comment directly above"; return 1; }
    # Starts with a capital and ends with a period: a sentence, not a fragment.
    [[ "${line}" =~ ^\#\ [A-Z].*\.$ ]] || { echo "${r}: not a standalone sentence: ${line}"; return 1; }
  done
}

# --- the token-inspection script -------------------------------------------

@test "check-token.sh exists and is executable" {
  [ -x "${TOKEN_SH}" ]
}

@test "SCRIPTS enumerates script/check-token.sh so shellcheck covers it" {
  # Adding a script without adding it here ships it unlinted: the recipe would
  # run it, the gate would never look at it.
  run bash -c "grep -E '^SCRIPTS :=' '${JUSTFILE}' | grep -F 'script/check-token.sh'"
  [ "${status}" -eq 0 ]
}

@test "check-token.sh --help exits 0 and documents that it never prints the token" {
  run "${TOKEN_SH}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"never"* ]]
}

@test "check-token.sh rejects an unknown option" {
  run "${TOKEN_SH}" --nope
  [ "${status}" -ne 0 ]
}

@test "check-token.sh reports a missing env file without failing hard" {
  # A host that has never been deployed is a legitimate state to ask about, not
  # an error: the answer is "no token here yet", which must be distinguishable
  # from "the token is broken".
  run "${TOKEN_SH}" --etc "${BATS_TEST_TMPDIR}/absent"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no environment file"* ]]
}

@test "check-token.sh flags a too-permissive env file" {
  local etc="${BATS_TEST_TMPDIR}/etc-loose"
  mkdir -p "${etc}"
  printf 'GITHUB_CONFIG_URL=https://github.com/acme\nGITHUB_TOKEN=ghp_example\n' \
    > "${etc}/scaleset-listener.env"
  chmod 0644 "${etc}/scaleset-listener.env"
  run "${TOKEN_SH}" --etc "${etc}" --no-verify
  [[ "${output}" == *"0644"* ]]
  [[ "${output}" == *"expected 0600"* ]]
}

@test "check-token.sh never echoes the token value" {
  local etc="${BATS_TEST_TMPDIR}/etc-secret"
  mkdir -p "${etc}"
  printf 'GITHUB_CONFIG_URL=https://github.com/acme\nGITHUB_TOKEN=ghp_SUPERSECRETVALUE\n' \
    > "${etc}/scaleset-listener.env"
  chmod 0600 "${etc}/scaleset-listener.env"
  run "${TOKEN_SH}" --etc "${etc}" --no-verify
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"SUPERSECRETVALUE"* ]]
  # It must still confirm a token is PRESENT -- a check that cannot tell you
  # that has not answered the question.
  [[ "${output}" == *"present"* ]]
}

@test "check-token.sh distinguishes a placeholder token from a real one" {
  local etc="${BATS_TEST_TMPDIR}/etc-placeholder"
  mkdir -p "${etc}"
  # What the shipped sample contains: deploying without editing it leaves this.
  printf 'GITHUB_CONFIG_URL=https://github.com/<org>\nGITHUB_TOKEN=<scale-set-admin-token>\n' \
    > "${etc}/scaleset-listener.env"
  chmod 0600 "${etc}/scaleset-listener.env"
  run "${TOKEN_SH}" --etc "${etc}" --no-verify
  [[ "${output}" == *"placeholder"* ]]
}

@test "check-token.sh does not reach the network with --no-verify" {
  # The flag exists so the file-level checks stay usable offline and in tests.
  local etc="${BATS_TEST_TMPDIR}/etc-offline"
  mkdir -p "${etc}"
  printf 'GITHUB_TOKEN=ghp_example\n' > "${etc}/scaleset-listener.env"
  chmod 0600 "${etc}/scaleset-listener.env"
  # A stub `gh` that fails loudly proves it was never consulted.
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${bin}"
  printf '#!/usr/bin/env bash\necho "gh was called" >&2\nexit 42\n' > "${bin}/gh"
  chmod +x "${bin}/gh"
  PATH="${bin}:${PATH}" run "${TOKEN_SH}" --etc "${etc}" --no-verify
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"gh was called"* ]]
}
