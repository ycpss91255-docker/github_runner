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
  # The engine reads the credential from an --env-file that the RETURN trap
  # shreds before the function returns, so a test cannot read it afterwards.
  # The stub therefore copies any --env-file content into ENVCAP WHILE the file
  # still exists (the stub runs during the `<cli> run`, before the RETURN trap),
  # so a test can assert HOW the credential is delivered to the container env.
  ENVCAP="${FAKE_RH}/envfile.content"
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
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--env-file" ]; then cat "\$a" >> "${ENVCAP}" 2>/dev/null; fi
  prev="\$a"
done
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

@test "runner_container_run delivers the JIT config to the in-container run via the container env (#136/#155)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENCODEDxJITxCONFIGx== my/image:tag
  [ "${status}" -eq 0 ]
  # The credential is delivered through the container ENV (the --env-file sets
  # the env var the official runner consumes natively), NOT spliced onto any
  # process argv. The env-file the engine reads must set the runner's native
  # ACTIONS_RUNNER_INPUT_JITCONFIG to the encoded credential.
  grep -qxF -- 'ACTIONS_RUNNER_INPUT_JITCONFIG=ENCODEDxJITxCONFIGx==' "${ENVCAP}"
}

# --- #155 the JIT credential must NEVER land on the in-container run.sh argv ---
# (world-readable host /proc/<pid>/cmdline; defeats the off-argv invariant)

@test "runner_container_run keeps the JIT config OFF the in-container run.sh argv (#155)" {
  # For rootless/rootful engines the container's run.sh is an ordinary HOST
  # process; /proc/<pid>/cmdline is mode 0444 (world-readable, no ptrace check),
  # unlike /proc/<pid>/environ. So the in-container command the engine runs must
  # NOT splice the credential onto run.sh's argv: it must neither pass
  # --jitconfig nor expand $JITCONFIG onto argv. The shell command string passed
  # to `sh -c` is the last captured token.
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENCODEDxJITxSECRETx== my/image:tag
  [ "${status}" -eq 0 ]
  # Grab the in-container command (the argument to `sh -c`).
  incmd=$(grep -A1 -xF -- '-c' "${CAP}" | tail -n1)
  [ -n "${incmd}" ]
  # No --jitconfig flag on the in-container run.sh argv.
  case "${incmd}" in *--jitconfig*) echo "in-container argv: ${incmd}"; return 1 ;; esac
  # And no JITCONFIG env expansion spliced onto argv either (the bug spliced
  # `"${JITCONFIG}"`, which the container shell expands onto run.sh's cmdline).
  case "${incmd}" in *JITCONFIG*) echo "in-container argv: ${incmd}"; return 1 ;; esac
  # The literal encoded value must not appear on the in-container argv at all.
  case "${incmd}" in *ENCODEDxJITxSECRETx==*) echo "in-container argv: ${incmd}"; return 1 ;; esac
}

# --- #136 the JIT credential must NEVER land on the HOST podman/docker argv ---

@test "runner_container_run keeps the JIT config OFF the host container CLI argv (#136)" {
  # ADR-0003 invariant: the single-use credential must not be visible in the
  # host process table. The captured argv of the host podman/docker process must
  # NOT contain the encoded credential anywhere.
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENCODEDxJITxSECRETx== my/image:tag
  [ "${status}" -eq 0 ]
  ! grep -qF -- 'ENCODEDxJITxSECRETx==' "${CAP}"
}

@test "runner_container_run delivers the JIT config to the container via --env-file off argv (#136)" {
  # The credential is handed to the engine through an --env-file (which reads
  # KEY=VALUE from a file and does NOT place the value on argv), so the host CLI
  # argv carries only the file PATH, never the secret.
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENCODEDxJITxSECRETx== my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- '--env-file' "${CAP}"
  # The env-file path is on argv (a path, not the secret); the secret is not.
  ! grep -qF -- 'ENCODEDxJITxSECRETx==' "${CAP}"
}

# --- #140 the JIT credential file must NOT live inside the job-writable mount ---

@test "runner_container_run keeps the JIT env-file OUTSIDE the bind-mounted /runner tree (#140)" {
  # The credential file must not be visible at /runner/.jitconfig.env inside the
  # container: the bind-mounted dir is read-write and IS the job's workdir, so a
  # hostile job could copy the credential into /runner/_diag and have it durably
  # archived. The --env-file path the engine reads must be a SIBLING of the
  # mounted dir, never a child of it.
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENCODEDxJITxSECRETx== my/image:tag
  [ "${status}" -eq 0 ]
  # Grab the --env-file path that was passed to the CLI (the token after it).
  envfile=$(grep -A1 -xF -- '--env-file' "${CAP}" | tail -n1)
  [ -n "${envfile}" ]
  # It must NOT be inside the bind-mounted runner dir (which mounts at /runner).
  case "${envfile}" in
    "${RUNNER_DIR}"/*) echo "env-file inside the job-writable mount: ${envfile}"; return 1 ;;
  esac
  # And no .jitconfig.env file may exist under the bind-mounted dir at all.
  [ ! -e "${RUNNER_DIR}/.jitconfig.env" ]
}

# --- #142 the RETURN credential-cleanup trap must not execute injected commands ---

@test "runner_container_run does NOT execute injected commands from a quote-bearing dir via the RETURN trap (#142)" {
  # The per-job dir name embeds the (only-control-char-stripped) scale-set JobID
  # verbatim (mktemp -d jit-<job_id>.XXXXXX). A no-slash payload bearing a single
  # quote survives canonicalJobID + os.MkdirTemp and lands here as `dir`. The
  # credential-cleanup RETURN trap derives env_file from `dir`; if it splices the
  # value into a code string, the embedded quote breaks out and the trailing
  # `; <cmd> #` runs ON THE HOST when the function returns. Assert it does not.
  make_cli docker
  local marker="${FAKE_RH}/pwned_host_marker"
  [ ! -e "${marker}" ]
  # A real per-job dir whose name carries the single-quote breakout payload, just
  # as mktemp would create it from a hostile JobID. Its parent (FAKE_RH) exists,
  # so the sibling env-file write succeeds exactly as in the real flow.
  local evil_dir="${FAKE_RH}/jit-x'; touch ${marker} #.AbCdEf"
  mkdir -p "${evil_dir}"
  run runner_container_run "${evil_dir}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  # The RETURN trap fired on return; the injected `touch` must NOT have run.
  [ ! -e "${marker}" ]
}

@test "runner_container_run still shreds the JIT env-file on return for a quote-bearing dir (#142/#136)" {
  # The fix must keep the #136/#140 invariant: the single-use credential file is
  # removed when the function returns, even for an unusual (quote-bearing) dir.
  make_cli docker
  local evil_dir="${FAKE_RH}/jit-y'; :  #.GhIjKl"
  mkdir -p "${evil_dir}"
  run runner_container_run "${evil_dir}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  # The sibling env-file (dir + .jitconfig.env) must not survive the return.
  [ ! -e "${evil_dir}.jitconfig.env" ]
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

@test "job-id label strips control chars so it cannot forge a reaper row (#137)" {
  # The scale-set JobID flows into the job-id label unsanitized. A NEWLINE in
  # that label is what let the reaper's listing be split into a phantom row
  # naming an arbitrary victim. The label value must carry NO control char, so
  # the hostile newline collapses and the whole label stays ONE argv token.
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag $'A\nrt-victim sparetoken'
  [ "${status}" -eq 0 ]
  # The sanitised label is a single line (newline stripped): "Art-victim ...".
  grep -qxF -- 'job-id=Art-victim sparetoken' "${CAP}"
  # The raw victim name never appears on its own captured line (no forged row).
  ! grep -qxF -- 'rt-victim sparetoken' "${CAP}"
}

@test "runner_job_id_label removes newline and carriage-return (#137)" {
  [ "$(runner_job_id_label $'a\nb')" = 'ab' ]
  [ "$(runner_job_id_label $'a\r\nb')" = 'ab' ]
  [ "$(runner_job_id_label 'plain-id')" = 'plain-id' ]
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

# --- #117 precise --device passthrough driven by the per-type config ---

@test "runner_container_run passes NO --device by default (#117)" {
  make_cli docker
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  # A plain CPU type declares no devices: nothing should be passed through.
  ! grep -qxF -- '--device' "${CAP}"
}

@test "runner_container_run passes exactly the configured devices as --device (#117)" {
  make_cli docker
  RUNNER_DEVICES=$'/dev/nvidia0\n/dev/nvidiactl' \
    run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  # Only the declared devices, each as a precise --device <node> pair.
  grep -qxF -- '--device' "${CAP}"
  grep -qxF -- '/dev/nvidia0' "${CAP}"
  grep -qxF -- '/dev/nvidiactl' "${CAP}"
  # Exactly two --device flags -- no broad/extra passthrough.
  [ "$(grep -cxF -- '--device' "${CAP}")" -eq 2 ]
  # And never --privileged for device access.
  ! grep -qxF -- '--privileged' "${CAP}"
}

@test "runner_container_run accepts space-separated devices too (#117)" {
  make_cli docker
  RUNNER_DEVICES='/dev/kvm /dev/dri/card0' \
    run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- '/dev/kvm' "${CAP}"
  grep -qxF -- '/dev/dri/card0' "${CAP}"
  [ "$(grep -cxF -- '--device' "${CAP}")" -eq 2 ]
}
