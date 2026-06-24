# SEC-5 base runner image (#120, ADR-0001 "Runner images").
#
# A self-built actions/runner image whose runner tarball is obtained through the
# repo's SEC-5 supply-chain check (verify_runner_tarball / verify_sha256 from
# lib/runner-release.sh) BEFORE it is baked in. This Dockerfile NEVER downloads
# the tarball itself: images/build-runner-image.sh downloads + verifies it on
# the host first, then hands the already-verified file in as the build context.
# That keeps the image build offline/hermetic and the integrity gate in exactly
# one place (the same gate init.sh / update.sh use), so the image supply chain
# matches the rest of the repo.
#
# Reproducibility:
#   * base image pinned by sha256 DIGEST (no :latest) -- bump via build-arg.
#   * runner version pinned by build-arg, and the tarball SHA-256 is verified
#     by the wrapper before this build is even invoked.
#   * the build context carries ONLY the verified tarball (no network here).

# Pinned base (Ubuntu 22.04). Bump the digest with:
#   docker buildx imagetools inspect ubuntu:22.04   # copy the index Digest
# BASE_IMAGE's default IS digest-pinned; hadolint can't see ARG defaults (DL3006).
ARG BASE_IMAGE=ubuntu@sha256:4f838adc7181d9039ac795a7d0aba05a9bd9ecd480d294483169c5def983b64d
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

# The actions/runner version this image bakes in (pinned by the wrapper, which
# also verifies the matching tarball's SHA-256). Surfaced as a label for audit.
ARG RUNNER_VERSION=unknown

# Runtime deps the actions/runner needs (its bin/installdependencies.sh set,
# kept minimal). hadolint ignore: pinning every apt version is not maintainable
# against a moving Ubuntu archive; the base image digest is the reproducibility
# anchor.
# hadolint ignore=DL3008,DL3009
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl jq git libicu70 \
    && rm -rf /var/lib/apt/lists/*

# Non-root runner user (the job runs unprivileged in-container, ADR-0001).
RUN useradd --create-home --shell /bin/bash --uid 1001 runner
WORKDIR /home/runner
USER runner

# The SEC-5-verified tarball, copied from the build context the wrapper built.
# It was integrity-checked on the host; this only unpacks it -- no download.
COPY --chown=runner:runner actions-runner.tar.gz /tmp/actions-runner.tar.gz
RUN tar xzf /tmp/actions-runner.tar.gz -C /home/runner \
    && rm -f /tmp/actions-runner.tar.gz

LABEL org.opencontainers.image.title="github-runner (SEC-5 base)" \
      org.opencontainers.image.description="actions/runner baked from a SEC-5-verified tarball" \
      io.github.github-runner.runner-version="${RUNNER_VERSION}"

# The Go scale-set client mints the JIT config and the per-job container seam
# (lib/runner-container.sh) invokes run.sh --jitconfig; no ENTRYPOINT baked here
# so the provisioner stays the single place that launches the runner.
