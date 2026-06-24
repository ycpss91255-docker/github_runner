#!/usr/bin/env bats
# Smoke tests for listener/provision-job.sh -- the scale-set listener's per-job
# container entrypoint (ADR-0001 Phase 4). The Go scale-set listener
# (cmd/scaleset-listener) shells out to this script for every ASSIGNED job; the
# script is the thin bridge from the Go loop to the Phase 3 container seam
# (lib/runner-container.sh's runner_container_run). These tests stub the
# container CLI (docker) on a clean PATH and capture its argv, asserting the
# script runs ONE single-use container (--rm) with the JIT config passed
# through -- NO real image pulled, NO real container run. Mirrors the
# runner_container.bats PATH-stub + argv-capture style; the listener's Go
# provisioning loop is unit-tested separately under listener/ (go test).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  SCRIPT="${ROOT}/listener/provision-job.sh"

  WORK=$(mktemp -d)
  # Provisioned per-job runner dirs land here, not in the real RUNNER_HOME.
  export RUNNER_WORK_ROOT="${WORK}/work"
  mkdir -p "${RUNNER_WORK_ROOT}"

  STUB=$(mktemp -d)
  CAP="${WORK}/cli.args"
  # A docker stub records the cli name + full argv (one token per line so --rm /
  # the image / the passed-through run command can be grepped exactly), then
  # exits CLI_RC (default 0) so teardown / failure propagation can be asserted.
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
echo "name=docker" >> "${CAP}"
printf '%s\n' "\$@" >> "${CAP}"
exit \${CLI_RC:-0}
EOF
  chmod +x "${STUB}/docker"
  # Clean PATH: only our stub plus system bins, so the seam's container-CLI
  # detection sees exactly the stub (no host docker/podman leaking in).
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${WORK}" "${STUB}"; }

@test "provision-job.sh exists and is executable" {
  [ -x "${SCRIPT}" ]
}

@test "provision-job.sh shells out to a single-use container (--rm) with the JIT config" {
  run "${SCRIPT}" job-abc ENCODEDxJITxCONFIGx== ghcr.io/acme/runner:latest
  [ "${status}" -eq 0 ]
  grep -qxF -- '--rm' "${CAP}"
  grep -qxF -- '--jitconfig' "${CAP}"
  grep -qxF -- 'ENCODEDxJITxCONFIGx==' "${CAP}"
  grep -qxF -- 'ghcr.io/acme/runner:latest' "${CAP}"
}

@test "provision-job.sh issues a container 'run' (it provisions, not exec)" {
  run "${SCRIPT}" job-abc ENC img
  [ "${status}" -eq 0 ]
  grep -qxF -- 'run' "${CAP}"
}

@test "provision-job.sh names + labels the container by job id (#104)" {
  run "${SCRIPT}" job-abc ENC img
  [ "${status}" -eq 0 ]
  grep -qxF -- '--name' "${CAP}"
  grep -qxF -- 'gha-jit-job-abc' "${CAP}"
  grep -qxF -- '--label' "${CAP}"
  grep -qxF -- 'managed-by=github-runner-listener' "${CAP}"
  grep -qxF -- 'job-id=job-abc' "${CAP}"
}

@test "provision-job.sh passes the listener's RUNNER_DEVICES through as --device (#117)" {
  # The widened shell-out contract: the listener sets RUNNER_DEVICES in the
  # provisioner's environment; the entrypoint must carry it into the container
  # seam so each declared node lands as a precise --device (no --privileged).
  RUNNER_DEVICES=$'/dev/nvidia0\n/dev/nvidiactl' run "${SCRIPT}" job-gpu ENC img
  [ "${status}" -eq 0 ]
  grep -qxF -- '--device' "${CAP}"
  grep -qxF -- '/dev/nvidia0' "${CAP}"
  grep -qxF -- '/dev/nvidiactl' "${CAP}"
  [ "$(grep -cxF -- '--device' "${CAP}")" -eq 2 ]
  ! grep -qxF -- '--privileged' "${CAP}"
}

@test "provision-job.sh passes NO --device when the type declares none (#117)" {
  run "${SCRIPT}" job-cpu ENC img
  [ "${status}" -eq 0 ]
  ! grep -qxF -- '--device' "${CAP}"
}

@test "provision-job.sh propagates the container's exit status (the job's result)" {
  export CLI_RC=7
  run "${SCRIPT}" job-abc ENC img
  [ "${status}" -eq 7 ]
}

@test "provision-job.sh rejects an empty JIT config" {
  run "${SCRIPT}" job-abc "" img
  [ "${status}" -ne 0 ]
  # Never reached the container CLI for an empty config.
  [ ! -f "${CAP}" ]
}

@test "provision-job.sh requires exactly three args" {
  run "${SCRIPT}" only-one
  [ "${status}" -ne 0 ]
}

@test "provision-job.sh removes the per-job runner dir after the job (no residue)" {
  run "${SCRIPT}" job-abc ENC img
  [ "${status}" -eq 0 ]
  # The throwaway jit-<job> dir must not survive the run.
  run bash -c "ls -d '${RUNNER_WORK_ROOT}'/jit-job-abc.* 2>/dev/null | wc -l"
  [ "${output}" = "0" ]
}
