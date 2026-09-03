#!/usr/bin/env bats
# Static invariants of the self-built runner-image Dockerfiles (#120 base, #121
# GPU). These guard the supply-chain + reproducibility promises WITHOUT building
# a real image (the actual `docker build` is exercised by the just/CI gate):
#   * the base bakes in the SEC-5-verified tarball from the build context and
#     NEVER downloads a runner tarball itself,
#   * every FROM is pinned by digest (no floating :latest baked in),
#   * the GPU image LAYERS on the SEC-5 base (so it inherits the verified
#     runner) and is NOT --privileged.

setup() {
  IMAGES="${BATS_TEST_DIRNAME}/../../images"
  BASE="${IMAGES}/runner-base.Dockerfile"
  GPU="${IMAGES}/runner-gpu.Dockerfile"
}

@test "base Dockerfile pins its base image by sha256 digest (#120)" {
  [ -f "${BASE}" ]
  run grep -E 'BASE_IMAGE=.*@sha256:[0-9a-f]{64}' "${BASE}"
  [ "${status}" -eq 0 ]
}

@test "base Dockerfile COPYs the verified tarball and never downloads one (#120)" {
  run grep -E 'COPY .*actions-runner\.tar\.gz' "${BASE}"
  [ "${status}" -eq 0 ]
  # The image build must NEVER fetch the runner tarball itself (that would
  # bypass the SEC-5 gate, which is the wrapper's job on the host). curl is a
  # legitimate runtime dep, so assert specifically that no runner release is
  # downloaded in the build.
  ! grep -Eiq 'github\.com/actions/runner|actions-runner-linux.*\.tar\.gz.*http' "${BASE}"
  ! grep -Eiq '(curl|wget)[^#]*actions-runner' "${BASE}"
}

@test "base Dockerfile runs the runner as a non-root user (#120)" {
  run grep -E '^USER runner' "${BASE}"
  [ "${status}" -eq 0 ]
}

@test "GPU Dockerfile layers on the SEC-5 base image (#121)" {
  [ -f "${GPU}" ]
  run grep -E 'FROM \$\{RUNNER_BASE_IMAGE\}' "${GPU}"
  [ "${status}" -eq 0 ]
}

@test "GPU Dockerfile pins the CUDA source image by sha256 digest (#121)" {
  run grep -E 'CUDA_IMAGE=.*@sha256:[0-9a-f]{64}' "${GPU}"
  [ "${status}" -eq 0 ]
}

@test "GPU Dockerfile never bakes in --privileged (#121, ADR-0001)" {
  # Ignore comment lines (the rationale text mentions the word); assert no
  # actual instruction bakes in --privileged.
  ! grep -vE '^[[:space:]]*#' "${GPU}" | grep -qF -- '--privileged'
}
