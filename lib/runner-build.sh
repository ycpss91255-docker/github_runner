#!/usr/bin/env bash
# Runner Build -- the DAEMONLESS image-build seam (ADR-0001 "Build path without
# privilege", #118). Build-type runners that need to build container images do so
# WITHOUT the host docker socket and WITHOUT --privileged: the host daemon is
# never reachable from a job (root-equivalence), and no privileged mode is used.
# Instead the build runs inside a throwaway, rootless container using a daemonless
# builder -- Kaniko or rootless BuildKit -- selected per runner type by the Go
# config (build_tool; wired in #119). This is the SINGLE place a job's image build
# is invoked, mirroring runner-container.sh's single-place-per-job-run discipline.
# shellcheck shell=bash

# Reuse the per-job container seam's rootless CLI picker (podman over docker) and
# the same baseline-hardening posture. Sourcing it keeps one source of truth for
# "which container CLI" and lets runner-build.sh be sourced on its own in tests.
# shellcheck source=lib/runner-container.sh
source "$(dirname "${BASH_SOURCE[0]}")/runner-container.sh"

# The daemonless builder images. Pin by digest in production; overridable so an
# operator can mirror them or bump versions without a code change.
: "${RUNNER_KANIKO_IMAGE:=gcr.io/kaniko-project/executor:latest}"
: "${RUNNER_BUILDKIT_IMAGE:=moby/buildkit:rootless}"

# runner_build_image <build_tool> <context_dir> <dockerfile> <destination>
# Build the image at <destination> from <context_dir>/<dockerfile> using the
# daemonless <build_tool> (kaniko | buildkit), inside a throwaway rootless
# container with --rm + the baseline hardening flags (#114) and the build context
# bind-mounted :Z (MAC kept enforced, #115). NEVER mounts the docker socket and
# NEVER uses --privileged. PROPAGATES the builder's exit status. "none"/unknown
# tools are rejected (a non-build type must not reach this seam).
runner_build_image() {
  local tool=$1 context=$2 dockerfile=$3 destination=$4 cli line
  cli=$(runner_container_cli) || {
    echo "FAIL: no rootless container CLI found (need podman or docker)" >&2
    return 1
  }

  # Baseline hardening (#114) shared with the per-job container seam: cap-drop,
  # no-new-privileges, pids-limit, default seccomp kept.
  local -a hardening_args=()
  while IFS= read -r line; do hardening_args+=("${line}"); done < <(runner_container_hardening_args)

  # Per-tool argv. Both run the daemonless builder image with --rm; the build
  # context is mounted :Z (MAC enforced). NO -v on docker.sock, NO --privileged.
  case "${tool}" in
    kaniko)
      # Kaniko's executor reads the Dockerfile + context from /workspace and
      # pushes to the destination -- no daemon, no socket, no privilege.
      "${cli}" run --rm \
        "${hardening_args[@]}" \
        -v "${context}:/workspace:Z" \
        "${RUNNER_KANIKO_IMAGE}" \
        --dockerfile "${dockerfile}" \
        --context /workspace \
        --destination "${destination}"
      ;;
    buildkit)
      # Rootless BuildKit (buildctl-daemonless) builds from the mounted context
      # and exports the image -- daemonless, socketless, unprivileged.
      "${cli}" run --rm \
        "${hardening_args[@]}" \
        -v "${context}:/workspace:Z" \
        "${RUNNER_BUILDKIT_IMAGE}" \
        build \
        --frontend dockerfile.v0 \
        --local context=/workspace \
        --local dockerfile=/workspace \
        --opt filename="$(basename -- "${dockerfile}")" \
        --output "type=image,name=${destination}"
      ;;
    none|"")
      echo "FAIL: build tool 'none' has nothing to build" >&2
      return 2
      ;;
    *)
      echo "FAIL: unknown build tool '${tool}' (want kaniko or buildkit)" >&2
      return 2
      ;;
  esac
}
