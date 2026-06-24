#!/usr/bin/env bats
# Smoke tests for lib/runner-container.sh -- the per-job container provisioner
# (ADR-0001 Phase 3, advances #82). This is the isolation core: each ephemeral
# job runs inside a THROWAWAY, rootless container that is torn down on exit, so
# no state (workspace residue, secrets) survives the job. The seam detects the
# container CLI (podman preferred over docker), runs the image with --rm (and
# rootless-appropriate flags) so the container is single-use, and passes the
# Phase 2 ephemeral run (run.sh --jitconfig <encoded>) through to it.
#
# Both `docker` and `podman` are shadowed by PATH stubs that record their argv
# to a CAP file (so the flags + the run-the-runner command can be grepped
# exactly) -- NO real image is pulled and NO real container is run. Mirrors the
# runner_service.bats / runner_run.bats PATH-stub + argv-capture style.

setup() {
  LIB="${BATS_TEST_DIRNAME}/../../lib/common.sh"
  FAKE_RH=$(mktemp -d)
  export RUNNER_HOME="${FAKE_RH}"
  source "${LIB}"

  RUNNER_DIR="${FAKE_RH}/acme/_org"
  mkdir -p "${RUNNER_DIR}"

  STUB=$(mktemp -d)
  CAP="${FAKE_RH}/cli.args"
  # A container-CLI stub records WHICH cli was chosen (its argv[0] name) and
  # the full argv it was handed, one token per line so --rm / the image / the
  # passed-through run command can be grepped exactly. Exits CLI_RC (default 0)
  # so teardown / failure propagation can be asserted. The name= prefix lets a
  # test prove podman-over-docker preference without running anything real.
  make_cli() {
    cat >"${STUB}/$1" <<EOF
#!/usr/bin/env bash
echo "name=$1" >> "${CAP}"
printf '%s\n' "\$@" >> "${CAP}"
exit \${CLI_RC:-0}
EOF
    chmod +x "${STUB}/$1"
  }
  # Drop a clean PATH that holds ONLY our stubs plus the system bins, so the
  # seam's `command -v podman/docker` detection sees exactly what each test set
  # up (no host docker/podman leaking in).
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${FAKE_RH}" "${STUB}"; }

@test "runner_container_run runs the container with --rm (single-use, torn down on exit)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENCODEDxJITxCONFIGx== my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- '--rm' "${CAP}"
}

@test "runner_container_run passes the JIT config through to the in-container run" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENCODEDxJITxCONFIGx== my/image:tag
  [ "${status}" -eq 0 ]
  grep -qF -- '--jitconfig' "${CAP}"
  grep -qF -- 'ENCODEDxJITxCONFIGx==' "${CAP}"
}

@test "runner_container_run runs the requested image" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- 'my/image:tag' "${CAP}"
}

@test "runner_container_run prefers podman over docker when both are present" {
  make_cli docker
  make_cli podman
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- 'name=podman' "${CAP}"
  ! grep -qxF -- 'name=docker' "${CAP}"
}

@test "runner_container_run falls back to docker when podman is absent" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- 'name=docker' "${CAP}"
}

@test "runner_container_run issues a 'run' subcommand (it provisions, not exec)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- 'run' "${CAP}"
}

@test "runner_container_run propagates the job's exit status from the container" {
  make_cli docker
  export CLI_RC=7
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 7 ]
}

@test "runner_container_run names the container deterministically by job id (#104)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag job-abc
  [ "${status}" -eq 0 ]
  # --name and its value land as adjacent argv tokens; the name is deterministic
  # and carries the job id so the reaper can correlate it.
  grep -qxF -- '--name' "${CAP}"
  grep -qxF -- "$(runner_container_name job-abc)" "${CAP}"
}

@test "runner_container_run labels the container managed-by + job id (#104)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag job-abc
  [ "${status}" -eq 0 ]
  grep -qxF -- '--label' "${CAP}"
  grep -qxF -- "managed-by=${RUNNER_MANAGED_BY}" "${CAP}"
  grep -qxF -- 'job-id=job-abc' "${CAP}"
}

@test "runner_container_name is deterministic for a given job id (#104)" {
  [ "$(runner_container_name job-abc)" = "$(runner_container_name job-abc)" ]
  [ "$(runner_container_name job-abc)" != "$(runner_container_name job-xyz)" ]
}

@test "runner_container_run fails clearly when no container CLI is available" {
  # Neither stub created: PATH holds only system bins, no docker/podman.
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -ne 0 ]
}

# --- #114 baseline hardening: cap-drop, no-new-privileges, pids-limit, keep seccomp ---

@test "runner_container_run drops all capabilities (#114)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- '--cap-drop=ALL' "${CAP}"
}

@test "runner_container_run sets no-new-privileges (#114)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- 'no-new-privileges' "${CAP}"
}

@test "runner_container_run bounds the pid count (#114)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- '--pids-limit' "${CAP}"
}

@test "runner_container_run does NOT disable the default seccomp profile (#114)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  # seccomp must stay at the engine default -- never seccomp=unconfined.
  ! grep -qF -- 'seccomp=unconfined' "${CAP}"
}

@test "runner_container_run never runs privileged (#114/#117)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  ! grep -qxF -- '--privileged' "${CAP}"
}

# --- #115 keep MAC enforced: no label=disable, relabel bind mounts with :Z ---

@test "runner_container_run does NOT disable MAC labelling (#115)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  # SELinux/AppArmor must stay enforced -- never --security-opt label=disable.
  ! grep -qF -- 'label=disable' "${CAP}"
}

@test "runner_container_run relabels the runner bind mount with :Z (#115)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  # The mount value carries the :Z private-relabel suffix so the kernel
  # relabels the bind mount for this container instead of disabling MAC.
  grep -qxF -- "${RUNNER_DIR}:/runner:Z" "${CAP}"
}

# --- #116 never mount the docker socket by default; explicit opt-in only ---

@test "runner_container_run mounts NO docker socket by default (#116)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  # Job code must not be able to reach the host daemon: no socket mount at all.
  ! grep -qF -- 'docker.sock' "${CAP}"
  ! grep -qF -- '/var/run/docker.sock' "${CAP}"
}

@test "runner_container_run mounts the docker socket only when explicitly opted in (#116)" {
  make_cli docker
  export RUNNER_DOCKER_SOCKET=/var/run/docker.sock
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  # Opt-in path: the configured socket is bind-mounted (relabelled :Z) so a
  # runner type that genuinely needs the daemon can ask for it explicitly.
  grep -qF -- '/var/run/docker.sock:/var/run/docker.sock' "${CAP}"
}
