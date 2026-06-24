#!/usr/bin/env bats
# Smoke tests for images/build-runner-image.sh -- the SEC-5 base runner image
# build wrapper (#120). A self-built runner image must obtain the actions/runner
# tarball through the SAME supply-chain check the rest of the repo uses
# (verify_runner_tarball / verify_sha256 from lib/runner-release.sh) BEFORE the
# tarball is baked into the image. The security-critical promise: the image
# build never bakes in an unverified tarball.
#
# Idiom mirrors runner_build.bats / tarball_verify.bats: PATH-stub the external
# commands (curl, docker, sha256sum where needed) to capture argv into a CAP
# file and to drive ordering, and shadow _gh so the expected digest is
# deterministic -- NO real download and NO real image build happen here.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  SCRIPT="${ROOT}/images/build-runner-image.sh"

  WORK=$(mktemp -d)
  export RUNNER_HOME="${WORK}/runners"   # release-lib cache root (absolute)
  CAP="${WORK}/cli.args"
  ORDER="${WORK}/order.log"

  STUB=$(mktemp -d)
  # curl stub: "download" by writing a fixed payload to the -o target, and log
  # the call ordering so we can assert verify happens before docker build.
  cat >"${STUB}/curl" <<EOF
#!/usr/bin/env bash
echo "curl" >> "${ORDER}"
out=
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2;; *) shift;; esac; done
[ -n "\${out}" ] && printf 'runner-tarball-payload\n' > "\${out}"
exit 0
EOF
  # docker stub: log argv + ordering; never builds anything.
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
echo "docker" >> "${ORDER}"
printf '%s\n' "\$@" >> "${CAP}"
exit \${DOCKER_RC:-0}
EOF
  # gh stub: runner_asset_digest reaches GitHub via _gh() { command gh ...; }
  # with the jq filter applied inside gh, so the stub emits the bare digest
  # value GitHub would return for the asset (or nothing). Driven by GH_DIGEST.
  cat >"${STUB}/gh" <<EOF
#!/usr/bin/env bash
printf '%s' "\${GH_DIGEST:-}"
EOF
  chmod +x "${STUB}/curl" "${STUB}/docker" "${STUB}/gh"
  PATH="${STUB}:${PATH}"
}

teardown() { rm -rf "${WORK}" "${STUB}"; }

# Digest of the stubbed curl payload -- what the build will compute and compare
# the GitHub-published digest against.
expected_payload_digest() {
  local f="${WORK}/p"; printf 'runner-tarball-payload\n' >"${f}"
  sha256sum "${f}" | cut -d' ' -f1
}

@test "build script downloads, SEC-5 verifies, THEN builds the image (#120)" {
  want=$(expected_payload_digest)
  GH_DIGEST="sha256:${want}" RUNNER_VERSION=2.334.0 \
    run "${SCRIPT}" --tag my/runner:test
  [ "${status}" -eq 0 ]
  # docker build was invoked.
  grep -qxF -- 'build' "${CAP}"
  # verify (the curl download) happened before the docker build.
  run cat "${ORDER}"
  [ "${status}" -eq 0 ]
  first=$(grep -n docker "${ORDER}" | head -1 | cut -d: -f1)
  curlline=$(grep -n curl "${ORDER}" | head -1 | cut -d: -f1)
  [ "${curlline}" -lt "${first}" ]
}

@test "build script ABORTS before building when the SEC-5 digest mismatches (#120)" {
  GH_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000" \
    RUNNER_VERSION=2.334.0 \
    run "${SCRIPT}" --tag my/runner:test
  [ "${status}" -ne 0 ]
  # The image build must NEVER run when verification fails.
  [ ! -f "${CAP}" ] || ! grep -qxF -- 'build' "${CAP}"
}

@test "build script ABORTS in strict mode when no digest is available (#120)" {
  # No GH_DIGEST -> _gh yields nothing -> strict verify aborts.
  RUNNER_VERSION=2.334.0 \
    run "${SCRIPT}" --tag my/runner:test
  [ "${status}" -ne 0 ]
  [ ! -f "${CAP}" ] || ! grep -qxF -- 'build' "${CAP}"
}

@test "build script passes the resolved runner version to the image build (#120)" {
  want=$(expected_payload_digest)
  GH_DIGEST="sha256:${want}" RUNNER_VERSION=2.334.0 \
    run "${SCRIPT}" --tag my/runner:test
  [ "${status}" -eq 0 ]
  # The version is pinned into the build (build-arg) for reproducibility.
  grep -qF -- '2.334.0' "${CAP}"
}

@test "build script tags the image as requested (#120)" {
  want=$(expected_payload_digest)
  GH_DIGEST="sha256:${want}" RUNNER_VERSION=2.334.0 \
    run "${SCRIPT}" --tag my/runner:test
  [ "${status}" -eq 0 ]
  grep -qxF -- 'my/runner:test' "${CAP}"
}
