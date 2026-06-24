#!/usr/bin/env bats
# Smoke tests for lib/runner-build.sh -- the DAEMONLESS image-build seam (#118,
# ADR-0001 "Build path without privilege"). Build-type runners build images with
# NO docker socket and NO --privileged, via Kaniko or rootless BuildKit. This is
# the security-critical promise: a job that builds an image must never touch the
# host daemon (root-equivalence) nor run privileged.
#
# The container CLI (docker/podman) is shadowed by a PATH stub that records its
# argv to a CAP file, so the build container's flags can be grepped exactly --
# NO real image is built and NO real container is run. Mirrors the
# runner_container.bats PATH-stub + argv-capture style.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/runner-build.sh"
  source "${LIB}"

  WORK=$(mktemp -d)
  CTX="${WORK}/ctx"
  mkdir -p "${CTX}"
  printf 'FROM scratch\n' >"${CTX}/Dockerfile"

  STUB=$(mktemp -d)
  CAP="${WORK}/cli.args"
  make_cli() {
    cat >"${STUB}/$1" <<EOF
#!/usr/bin/env bash
echo "name=$1" >> "${CAP}"
printf '%s\n' "\$@" >> "${CAP}"
exit \${CLI_RC:-0}
EOF
    chmod +x "${STUB}/$1"
  }
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${WORK}" "${STUB}"; }

@test "runner_build_image with kaniko runs a build container (#118)" {
  make_cli docker
  run runner_build_image kaniko "${CTX}" "${CTX}/Dockerfile" my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- 'run' "${CAP}"
  # The Kaniko executor image is what does the daemonless build.
  grep -qiF -- 'kaniko' "${CAP}"
}

@test "runner_build_image with kaniko mounts NO docker socket (#118)" {
  make_cli docker
  run runner_build_image kaniko "${CTX}" "${CTX}/Dockerfile" my/image:tag
  [ "${status}" -eq 0 ]
  ! grep -qF -- 'docker.sock' "${CAP}"
}

@test "runner_build_image with kaniko is NOT privileged (#118)" {
  make_cli docker
  run runner_build_image kaniko "${CTX}" "${CTX}/Dockerfile" my/image:tag
  [ "${status}" -eq 0 ]
  ! grep -qxF -- '--privileged' "${CAP}"
}

@test "runner_build_image with buildkit runs a rootless build container (#118)" {
  make_cli docker
  run runner_build_image buildkit "${CTX}" "${CTX}/Dockerfile" my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- 'run' "${CAP}"
  grep -qiF -- 'buildkit' "${CAP}"
}

@test "runner_build_image with buildkit mounts NO docker socket and is NOT privileged (#118)" {
  make_cli docker
  run runner_build_image buildkit "${CTX}" "${CTX}/Dockerfile" my/image:tag
  [ "${status}" -eq 0 ]
  ! grep -qF -- 'docker.sock' "${CAP}"
  ! grep -qxF -- '--privileged' "${CAP}"
}

@test "runner_build_image propagates the builder's exit status (#118)" {
  make_cli docker
  export CLI_RC=5
  run runner_build_image kaniko "${CTX}" "${CTX}/Dockerfile" my/image:tag
  [ "${status}" -eq 5 ]
}

@test "runner_build_image rejects an unknown build tool (#118)" {
  make_cli docker
  run runner_build_image frobnicate "${CTX}" "${CTX}/Dockerfile" my/image:tag
  [ "${status}" -ne 0 ]
  # Never reached the container CLI for an unknown tool.
  [ ! -f "${CAP}" ]
}

@test "runner_build_image rejects the 'none' build tool (nothing to build) (#118)" {
  make_cli docker
  run runner_build_image none "${CTX}" "${CTX}/Dockerfile" my/image:tag
  [ "${status}" -ne 0 ]
  [ ! -f "${CAP}" ]
}

@test "runner_build_image fails clearly when no container CLI is available (#118)" {
  # No stub: PATH holds only system bins.
  run runner_build_image kaniko "${CTX}" "${CTX}/Dockerfile" my/image:tag
  [ "${status}" -ne 0 ]
}
