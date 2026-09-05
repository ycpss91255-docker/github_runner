#!/usr/bin/env bats
# Executable spec for script/lint-readme-sync.sh -- the four-language README
# structure gate.
#
# PRD.md §0.7 requires the four-language README structure to stay aligned: a
# reader who picks a language must not get a different document. That rule was
# enforced only by a local hook watching what was staged, so it could see a
# partial update only on the machine that happened to run it, and could not see
# a partial update that arrived in two commits at all.
#
# The gate here reads the tree instead of the index, so it judges the state the
# repository is actually in. What it compares is STRUCTURE -- the sequence of
# heading levels and the number of fenced code blocks -- because the headings
# themselves are translated and comparing their text would fail on every file by
# design.
#
# Fixtures are written per test, so nothing here depends on the real READMEs
# except the one case that deliberately checks them.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LINT="${ROOT}/script/lint-readme-sync.sh"
  FAKE="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${FAKE}/doc/readme"
}

# Write one README with the given body. Callers pass a here-doc through stdin.
write_readme() {
  cat >"${FAKE}/$1"
}

# A structurally identical set of four, differing only in prose, so a test can
# then perturb exactly one of them.
write_aligned_set() {
  local rel
  for rel in README.md doc/readme/README.zh-TW.md doc/readme/README.zh-CN.md \
             doc/readme/README.ja.md; do
    cat >"${FAKE}/${rel}" <<'EOF'
# Title

## Install

```bash
# this comment is not a heading
just pull
```

## Usage

### Details

## License
EOF
  done
}

@test "the repository's own four READMEs are structurally aligned" {
  run bash "${LINT}" "${ROOT}"
  [ "${status}" -eq 0 ]
}

@test "an aligned fixture set passes" {
  write_aligned_set
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "translated heading text is not a divergence -- only structure is" {
  write_aligned_set
  sed -i 's/^## Install$/## 安裝/; s/^## Usage$/## 使用方式/' \
    "${FAKE}/doc/readme/README.zh-TW.md"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "a section added to only one language fails, naming that file" {
  write_aligned_set
  printf '\n## Extra section\n' >>"${FAKE}/README.md"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md"* ]]
}

@test "a section removed from only one language fails, naming that file" {
  write_aligned_set
  sed -i '/^### Details$/d' "${FAKE}/doc/readme/README.ja.md"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.ja.md"* ]]
}

@test "a heading demoted in only one language fails" {
  # Same number of headings, different shape -- a count alone would miss this.
  write_aligned_set
  sed -i 's/^## Usage$/### Usage/' "${FAKE}/doc/readme/README.zh-CN.md"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.zh-CN.md"* ]]
}

@test "a code example added to only one language fails" {
  write_aligned_set
  printf '\n```bash\njust test\n```\n' >>"${FAKE}/doc/readme/README.zh-TW.md"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.zh-TW.md"* ]]
}

@test "a hash line inside a fenced code block is not counted as a heading" {
  # Every one of these READMEs shows shell snippets whose comments start with
  # '#'. Counting those as headings would make the gate red on a file nobody
  # touched, which is the fastest way to teach people to ignore it.
  write_aligned_set
  printf '\n```bash\n# not a heading\n# nor this one\njust lint\n```\n' \
    >>"${FAKE}/README.md"
  printf '\n```bash\n# translated comment\n# another\njust lint\n```\n' \
    >>"${FAKE}/doc/readme/README.zh-TW.md"
  printf '\n```bash\n# translated comment\n# another\njust lint\n```\n' \
    >>"${FAKE}/doc/readme/README.zh-CN.md"
  printf '\n```bash\n# translated comment\n# another\njust lint\n```\n' \
    >>"${FAKE}/doc/readme/README.ja.md"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -eq 0 ]
}

@test "a missing translation fails loudly instead of being skipped" {
  write_aligned_set
  rm "${FAKE}/doc/readme/README.ja.md"
  run bash "${LINT}" "${FAKE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.ja.md"* ]]
}

@test "an unknown option is refused rather than silently doing nothing" {
  run bash "${LINT}" --wat
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"usage"* || "${output}" == *"unknown"* ]]
}
