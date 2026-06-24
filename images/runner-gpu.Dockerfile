# GPU / device runner image (#121, ADR-0001 "Runner images").
#
# Stock actions-runner images cannot run GPU jobs, so device runners need a
# self-built image carrying the CUDA/device stack. This image LAYERS that stack
# on the SEC-5 base (images/runner-base.Dockerfile) -- so the runner binary it
# runs is still the SEC-5-verified one (its tarball passed verify_runner_tarball
# before being baked into the base). The device stack is added on top.
#
# The CUDA runtime libraries are COPYed from a DIGEST-pinned nvidia/cuda image
# rather than apt-installed from the NVIDIA network repo, which keeps the build
# hermetic and reproducible (two pinned digests, no network) and lets CI build
# it AFK. Host GPU access is via precise --device passthrough + the nvidia
# runtime at run time (lib/runner-container.sh / provisioner), NOT --privileged
# (ADR-0001 "Hardware-runner residual").
#
# Pinned by digest:
#   * RUNNER_BASE_IMAGE -- the SEC-5 base (build it first; pin its digest).
#   * CUDA_IMAGE        -- the nvidia/cuda runtime the device libs come from.
#
# AFK vs HITL: this image BUILDS and is wired into the gpu runner-type config
# AFK. A GPU job ACTUALLY EXECUTING needs a real NVIDIA host (driver + nvidia
# container runtime) -- an operator (HITL) step, not reproducible in CI.

# The SEC-5 base, built by images/build-runner-image.sh and pinned by digest.
# Bump by rebuilding the base and copying its new image id / digest.
ARG RUNNER_BASE_IMAGE=gh-runner-base:latest

# DIGEST-pinned CUDA image the device libraries are copied from. Matches the
# CUDA version init.sh probes (12.2.0-base-ubuntu22.04). Bump via:
#   docker buildx imagetools inspect nvidia/cuda:12.2.0-base-ubuntu22.04
ARG CUDA_IMAGE=nvidia/cuda@sha256:ecdf8549dd5f12609e365217a64dedde26ecda26da8f3ff3f82def6749f53051

# hadolint ignore=DL3006
FROM ${CUDA_IMAGE} AS cuda

# hadolint ignore=DL3006
FROM ${RUNNER_BASE_IMAGE}

ARG RUNNER_VERSION=unknown

# Device stack: the CUDA runtime libraries + the toolkit metadata, copied from
# the pinned nvidia/cuda image (hermetic; no NVIDIA apt repo at build time). The
# kernel driver is NOT in the image -- it is provided by the host and exposed at
# run time via --device + the nvidia container runtime.
USER root
COPY --from=cuda /usr/local/cuda /usr/local/cuda
ENV PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64

# Let the nvidia container runtime know what to expose (consumed by the runtime
# at run time on a real GPU host; inert otherwise).
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

USER runner

LABEL org.opencontainers.image.title="github-runner (GPU/device)" \
      org.opencontainers.image.description="SEC-5 base + CUDA device stack for GPU jobs" \
      io.github.github-runner.runner-version="${RUNNER_VERSION}"
