#!/usr/bin/env bats
# Smoke tests for lib/runner-history.sh -- the job-history / audit-trail store
# (ADR-0002): the append-only ledger with secret redaction + journald mirror
# (#124). Each test sources the lib with RUNNER_HISTORY_DIR pointed at a
# throwaway dir (never the real RUNNER_HOME) and asserts on the files it writes.
# journald is absent in CI, so its mirror is a silent no-op here (asserted not to
# break the ledger write).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  STORE=$(mktemp -d)
  export RUNNER_HISTORY_DIR="${STORE}/history"
  export RUNNER_HISTORY_LEDGER="${RUNNER_HISTORY_DIR}/ledger.tsv"
  # shellcheck source=../../lib/runner-history.sh
  source "${ROOT}/lib/runner-history.sh"
}

teardown() { rm -rf "${STORE}"; }

# --- #124 ledger ----------------------------------------------------------

@test "runner_history_record appends one TAB-separated line per job" {
  runner_history_record job-1 image=img:1 exit_status=0
  runner_history_record job-2 image=img:2 exit_status=7
  [ "$(grep -c '^' "${RUNNER_HISTORY_LEDGER}")" -eq 2 ]
  grep -q $'\tjob_id=job-1\t' "${RUNNER_HISTORY_LEDGER}"
  grep -q $'\tjob_id=job-2\t' "${RUNNER_HISTORY_LEDGER}"
  # The fields the caller passed are present.
  grep -q 'image=img:1' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=7' "${RUNNER_HISTORY_LEDGER}"
}

@test "runner_history_record records the full ADR-0002 field set" {
  runner_history_record job-x \
    scale_set=gpu labels=gpu,linux image=img digest=sha256:abc host=h1 \
    runner_type=gpu devices=/dev/nvidia0 start=t0 end=t1 duration=42 \
    exit_status=0 trigger_repo=o/r trigger_workflow=ci trigger_commit=deadbeef \
    trigger_actor=octocat
  local line; line=$(cat "${RUNNER_HISTORY_LEDGER}")
  for f in scale_set=gpu image=img digest=sha256:abc host=h1 runner_type=gpu \
           devices=/dev/nvidia0 duration=42 trigger_repo=o/r \
           trigger_workflow=ci trigger_commit=deadbeef trigger_actor=octocat; do
    [[ "${line}" == *"${f}"* ]] || { echo "missing field ${f} in: ${line}"; return 1; }
  done
}

@test "runner_history_record NEVER writes the JIT config or any secret (#124 redaction)" {
  runner_history_record job-sec \
    image=img \
    jit_config=ENCODEDxJITxSECRET \
    jitconfig=ENCODEDxJITxSECRET \
    github_token=ghp_supersecret \
    runner_secret=hunter2 \
    db_credential=topsecret \
    user_password=letmein \
    exit_status=0
  # The benign field survives; every secret-ish field (and its value) is gone.
  grep -q 'image=img' "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'ENCODEDxJITxSECRET' "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'ghp_supersecret'    "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'hunter2'            "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'topsecret'          "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'letmein'            "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'jit'                "${RUNNER_HISTORY_LEDGER}"
  ! grep -qi 'token'              "${RUNNER_HISTORY_LEDGER}"
}

# --- #125 archive ---------------------------------------------------------

@test "runner_history_archive stores the job log + _diag keyed by job id (#125)" {
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag"
  echo "diag line" > "${rdir}/_diag/Worker_1.log"
  printf 'job output here\n' > "${STORE}/captured.log"

  runner_history_archive job-arc "${STORE}/captured.log" "${rdir}"

  jdir="${RUNNER_HISTORY_DIR}/jobs/job-arc"
  [ -f "${jdir}/job.log" ]
  grep -q 'job output here' "${jdir}/job.log"
  [ -f "${jdir}/_diag/Worker_1.log" ]
  grep -q 'diag line' "${jdir}/_diag/Worker_1.log"
}

@test "runner_history_archive is best-effort when sources are missing (#125)" {
  # No job log, no _diag: it must still create the per-job dir and return 0.
  run runner_history_archive job-empty "" "${STORE}/nope"
  [ "${status}" -eq 0 ]
  [ -d "${RUNNER_HISTORY_DIR}/jobs/job-empty" ]
}

# --- #140 _diag is attacker-controlled job output: scrub secrets on archive ---

@test "runner_history_archive scrubs secret content a hostile job planted in _diag (#140)" {
  # The runner dir is bind-mounted READ-WRITE into the job container at /runner,
  # and /runner/_diag is therefore attacker-writable. A hostile job can copy the
  # single-use JIT credential (or any harvested secret) into _diag, which the
  # archive would otherwise persist VERBATIM into the durable, never-torn-down
  # history store. The archive must treat _diag as untrusted and scrub secret
  # patterns from the archived contents.
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag"
  # An attacker-planted file dumping the JIT credential + other secrets.
  cat > "${rdir}/_diag/leak.log" <<'LEAK'
JITCONFIG=ENCODEDxJITxSECRETxPLANTED==
github_token=ghp_supersecretvalue
runner_secret: hunter2value
benign worker diagnostic line
LEAK

  runner_history_archive job-leak "" "${rdir}"

  archived="${RUNNER_HISTORY_DIR}/jobs/job-leak/_diag/leak.log"
  [ -f "${archived}" ]
  # The benign diagnostic line survives (we keep real forensics).
  grep -q 'benign worker diagnostic line' "${archived}"
  # But none of the planted secret VALUES may land in the durable store.
  ! grep -q 'ENCODEDxJITxSECRETxPLANTED==' "${archived}"
  ! grep -q 'ghp_supersecretvalue'         "${archived}"
  ! grep -q 'hunter2value'                 "${archived}"
}

# --- #141 job_log is attacker-controlled console output: scrub on archive ---

@test "runner_history_archive scrubs secret content a hostile job printed to job_log (#141)" {
  # The container's combined stdout/stderr is captured into job_log
  # (provision-job.sh: runner_container_run_bounded ... > job_log 2>&1), so its
  # contents are FULLY attacker-controlled. A hostile job step can dump the JIT
  # credential from its own container env (e.g. `cat /proc/1/environ` / `env`,
  # printing JITCONFIG=<encoded single-use credential>) -- or any harvested
  # secret -- straight to stdout. The archive must treat job_log as untrusted and
  # scrub secret patterns, exactly like the #140 _diag path, so a credential
  # printed to job stdout never reaches the durable, never-torn-down history
  # store (or the external push hook).
  cat > "${STORE}/captured.log" <<'LEAK'
JITCONFIG=ENCODEDxJITxSECRETxPLANTED==
github_token=ghp_supersecretvalue
runner_secret: hunter2value
benign console output line
LEAK

  runner_history_archive job-stdout-leak "${STORE}/captured.log" ""

  archived="${RUNNER_HISTORY_DIR}/jobs/job-stdout-leak/job.log"
  [ -f "${archived}" ]
  # The benign console line survives (we keep real forensics).
  grep -q 'benign console output line' "${archived}"
  # But none of the printed secret VALUES may land in the durable store.
  ! grep -q 'ENCODEDxJITxSECRETxPLANTED==' "${archived}"
  ! grep -q 'ghp_supersecretvalue'         "${archived}"
  ! grep -q 'hunter2value'                 "${archived}"
}

# --- #145 job_log is re-opened by path: never follow a symlink into the host ---

@test "runner_history_archive refuses a symlinked job_log (no symlink-follow into the host, #145)" {
  # job_log is re-opened BY PATH on archive. A hostile job has RW access to the
  # bind-mounted /runner tree, so if job_log lived there it could `ln -sf
  # /etc/shadow <job_log>` and have the archive dereference the symlink in the
  # HOST namespace, reading an arbitrary host file VERBATIM into the durable,
  # never-torn-down store. The archive must NOT follow a symlinked job_log -- the
  # belt-and-braces guard mirroring the `find -P` discipline used for _diag.
  printf 'TOPSECRETHOSTFILE\n' > "${STORE}/host-secret"
  ln -s "${STORE}/host-secret" "${STORE}/job.log"

  runner_history_archive job-symlink "${STORE}/job.log" ""

  # The host file's contents must never be read+written into the durable store.
  ! grep -rq 'TOPSECRETHOSTFILE' "${RUNNER_HISTORY_DIR}"
}

# --- #143 bare-value JIT credential leak: redact known secret VALUES too ---

@test "runner_history_scrub_secrets redacts a known secret VALUE with no KEY= prefix (#143)" {
  # The key-anchored scrubber (#140/#141) only matches KEY=VALUE / KEY:VALUE
  # forms. A hostile step can print the single-use JIT credential as a BARE
  # value with NO key (`printenv JITCONFIG` / `echo "$JITCONFIG"` emit only the
  # encoded string), which that rule cannot catch. The runner hands the LIVE
  # secret value(s) it injected to the scrubber via RUNNER_HISTORY_SCRUB_VALUES
  # (newline-separated); each is redacted LITERALLY wherever it appears -- even
  # if it embeds regex metacharacters or the sed delimiter '/'.
  # The value deliberately carries regex metacharacters and the sed delimiter
  # '/' but NO secret-ish key token, so ONLY value-based redaction can catch it
  # (the key-anchored rule must not match it by coincidence).
  export RUNNER_HISTORY_SCRUB_VALUES='a.b*c[d]+e/f-XYZ987=='
  out=$(printf 'bare a.b*c[d]+e/f-XYZ987== here\nfield=a.b*c[d]+e/f-XYZ987==\nbenign line\n' \
        | runner_history_scrub_secrets)
  # The literal secret value must be gone from BOTH the bare and key-prefixed
  # occurrences, and the benign line must survive.
  [[ "${out}" != *'a.b*c[d]+e/f-XYZ987=='* ]] || { echo "secret value survived: ${out}"; return 1; }
  [[ "${out}" == *'benign line'* ]]
}

@test "runner_history_archive redacts a bare JIT credential printed to job_log (#143)" {
  # `printenv JITCONFIG` prints ONLY the encoded credential, no KEY= prefix --
  # the most direct leak of the single-use JIT config. With the live value
  # exported, the archive must redact it before job.log lands in the durable,
  # never-torn-down history store.
  export RUNNER_HISTORY_SCRUB_VALUES='ENCODEDxJITxBAREVALUE/+=='
  cat > "${STORE}/captured.log" <<'LEAK'
ENCODEDxJITxBAREVALUE/+==
benign console output line
LEAK

  runner_history_archive job-bare "${STORE}/captured.log" ""

  archived="${RUNNER_HISTORY_DIR}/jobs/job-bare/job.log"
  [ -f "${archived}" ]
  grep -q 'benign console output line' "${archived}"
  ! grep -qF 'ENCODEDxJITxBAREVALUE/+==' "${archived}"
}

# --- #150 value scrub must survive a credential split across a line boundary ---

@test "runner_history_scrub_secrets redacts a secret VALUE emitted split across a newline (#150)" {
  # The value-literal arm (#143) is the ONLY defense for a BARE credential (the
  # key rule cannot match a key-less base64 blob). It does
  # `${line//"${val}"/[REDACTED]}` PER INPUT LINE, so a hostile step that prints
  # the live JIT credential VERBATIM but split across a newline
  # (`echo "${JITCONFIG:0:30}"; echo "${JITCONFIG:30}"`, or `fold -w64`) defeats
  # it: no single line equals the literal value, so each fragment passes through
  # untouched and the full credential is reassembled with `tr -d '\n'`. Each
  # emitted fragment is itself a contiguous substring of the credential, so the
  # scrubber must redact any line that is a long-enough substring of a secret.
  local secret='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwx=='
  export RUNNER_HISTORY_SCRUB_VALUES="${secret}"
  # Split the credential across a real newline (two halves, neither equal to the
  # whole value), bracketed by benign lines that must survive.
  out=$(printf '%s\n%s\n%s\nbenign line\n' \
        "${secret:0:30}" "${secret:30}" "tail" | runner_history_scrub_secrets)

  # Neither fragment may survive, and the credential must not be reconstructable
  # by stripping newlines from the scrubbed output.
  [[ "${out}" != *"${secret:0:30}"* ]] || { echo "first fragment survived: ${out}"; return 1; }
  [[ "${out}" != *"${secret:30}"* ]] || { echo "second fragment survived: ${out}"; return 1; }
  reassembled=$(printf '%s' "${out}" | tr -d '\n')
  [[ "${reassembled}" != *"${secret}"* ]] || { echo "credential reconstructable: ${reassembled}"; return 1; }
  # Benign content must still survive (the scrub is not gutting the log).
  [[ "${out}" == *'benign line'* ]]
}

@test "runner_history_scrub_secrets keeps benign short lines when a secret is set (#150)" {
  # The substring-of-secret guard must not over-redact ordinary short diagnostic
  # lines that merely happen to be short -- only lines that are an actual
  # contiguous substring of an injected secret are redacted.
  export RUNNER_HISTORY_SCRUB_VALUES='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwx=='
  out=$(printf 'ok\nWorker_1 started\nexit 0\n' | runner_history_scrub_secrets)
  [[ "${out}" == *'Worker_1 started'* ]] || { echo "benign line over-redacted: ${out}"; return 1; }
  [[ "${out}" == *'exit 0'* ]]
  [[ "${out}" != *'[REDACTED]'* ]] || { echo "benign content was redacted: ${out}"; return 1; }
}

# --- #153 fragment pass must survive credential split into SUB-16-char chunks ---

@test "runner_history_scrub_secrets redacts a credential emitted in sub-16-char chunks (#153)" {
  # The #150 fragment pass `[[ ${#line} -ge 16 && val == *line* ]]` has a 16-char
  # FLOOR: a line shorter than 16 chars is never substring-tested, so a hostile
  # step defeats it by splitting the live JIT credential into lines of <=15 chars
  # (`printenv JITCONFIG | fold -w 15`). Each 15-char slice: has no secret-ish
  # KEY=, is not the whole multi-KB value, and is <16 chars -- so all three passes
  # miss and every slice lands VERBATIM in job.log, reassembled with `tr -d '\n'`.
  # A fixed per-line floor is fundamentally defeatable (any floor N is beaten with
  # width N-1), so a cross-line reassembly pass must catch the credential
  # regardless of chunk width.
  local secret='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwx=='
  export RUNNER_HISTORY_SCRUB_VALUES="${secret}"

  # Width 15 (one below the #150 floor): the exact bypass.
  out=$(printf '%s' "${secret}" | fold -w 15 | runner_history_scrub_secrets)
  reassembled=$(printf '%s' "${out}" | tr -d '\n')
  [[ "${reassembled}" != *"${secret}"* ]] \
    || { echo "w15: credential reconstructable: ${reassembled}"; return 1; }

  # Width 1 (each char on its own line): an adaptive splitter at the extreme.
  out=$(printf '%s' "${secret}" | fold -w 1 | runner_history_scrub_secrets)
  reassembled=$(printf '%s' "${out}" | tr -d '\n')
  [[ "${reassembled}" != *"${secret}"* ]] \
    || { echo "w1: credential reconstructable: ${reassembled}"; return 1; }

  # Width 7 (an in-between, odd width that does not divide the secret evenly).
  out=$(printf '%s' "${secret}" | fold -w 7 | runner_history_scrub_secrets)
  reassembled=$(printf '%s' "${out}" | tr -d '\n')
  [[ "${reassembled}" != *"${secret}"* ]] \
    || { echo "w7: credential reconstructable: ${reassembled}"; return 1; }
}

@test "runner_history_scrub_secrets cross-line pass keeps benign multi-line content (#153)" {
  # The cross-line reassembly pass must only redact lines whose concatenation
  # actually reconstructs an injected secret -- ordinary multi-line diagnostics
  # whose joined text never contains the credential must survive verbatim.
  export RUNNER_HISTORY_SCRUB_VALUES='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwx=='
  out=$(printf 'ok\nWorker_1 started\nstep 2\nexit 0\n' | runner_history_scrub_secrets)
  [[ "${out}" == *'Worker_1 started'* ]] || { echo "benign over-redacted: ${out}"; return 1; }
  [[ "${out}" == *'step 2'* ]]
  [[ "${out}" == *'exit 0'* ]]
  [[ "${out}" != *'[REDACTED]'* ]] || { echo "benign content was redacted: ${out}"; return 1; }
}

# --- #146 value redaction must never put the secret on an external proc argv ---

@test "runner_history_scrub_secrets never places a secret VALUE on an external sed argv (#146)" {
  # #143's value-literal redaction builds `sed -e "s/<value>/[REDACTED]/g"` and
  # runs sed as an EXTERNAL process -- carrying the credential VERBATIM on the
  # sed command line (/proc/<pid>/cmdline, world-readable 0444). That re-creates
  # the exact host-process-table exposure #133/#136 closed by moving the JIT
  # credential off the host argv. The redaction must happen WITHOUT placing the
  # secret value on any subprocess's argv (pure-bash literal substitution, or an
  # external tool fed via a 0600 file / stdin -- never argv).
  #
  # Stub-and-capture: override `sed` to record every argv it is invoked with,
  # then delegate to the real sed so the function still scrubs. A purely
  # alphanumeric value is matched verbatim (the #143 escaper only backslash-
  # escapes non-alnum bytes), so it would appear on argv unchanged if leaked.
  CAP="${STORE}/sed.argv"
  : > "${CAP}"
  sed() { printf '%s\0' "$@" >> "${CAP}"; command sed "$@"; }

  local secret='LIVEJITCREDENTIAL0123456789abcdefXYZ'
  export RUNNER_HISTORY_SCRUB_VALUES="${secret}"
  out=$(printf 'bare %s here\nbenign line\n' "${secret}" | runner_history_scrub_secrets)

  # Functional: the secret is redacted from the OUTPUT, benign content survives.
  [[ "${out}" != *"${secret}"* ]] || { echo "secret value survived in output: ${out}"; return 1; }
  [[ "${out}" == *'benign line'* ]]

  # Security: the secret value must NEVER appear on any sed argv -- i.e. never on
  # /proc/<pid>/cmdline. This is the regression #146 locks.
  if grep -aqF "${secret}" "${CAP}"; then
    echo "secret value leaked onto an external sed argv: $(tr '\0' ' ' < "${CAP}")"
    return 1
  fi
}

# --- #149 _diag FILENAMES are attacker-controlled job output: scrub names too ---

@test "runner_history_archive scrubs a secret a hostile job encoded into _diag FILENAMES (#149)" {
  # _diag is bind-mounted READ-WRITE into the job container at /runner, so a
  # hostile job can encode the single-use JIT credential into _diag *filenames*
  # (and dirnames) with EMPTY/benign bodies -- the content scrubber (#140) never
  # sees the secret because it lives in the path component, not the file content.
  # The archive recreates the tree as `rel=${path#src/}` -> `${dest}/${rel}`, so
  # without name scrubbing the credential survives VERBATIM as a path component
  # in the durable, never-torn-down store, reassembled by any local user via
  # `ls -R` long after the container was --rm'd. The runner injected the live
  # credential, so it can redact that value from names exactly as it does from
  # content.
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag"
  local secret='ENCODEDxJITxBAREVALUE0123456789=='
  export RUNNER_HISTORY_SCRUB_VALUES="${secret}"
  # The secret smuggled as a filename AND as a dirname (empty/benign bodies).
  : > "${rdir}/_diag/leak-${secret}.log"
  mkdir -p "${rdir}/_diag/d-${secret}"
  : > "${rdir}/_diag/d-${secret}/x.log"

  runner_history_archive job-fname "" "${rdir}"

  # The live JIT credential must not survive anywhere under the store -- neither
  # in file CONTENTS nor as a path component (filename / dirname).
  ! grep -rqF "${secret}" "${RUNNER_HISTORY_DIR}"
  found=$(find "${RUNNER_HISTORY_DIR}" -path "*${secret}*")
  [ -z "${found}" ] || { echo "secret survived as a path component: ${found}"; return 1; }
  # Benign forensics still land (the archive is not gutted).
  [ -d "${RUNNER_HISTORY_DIR}/jobs/job-fname/_diag" ]
}

@test "runner_history_archive preserves benign _diag filenames verbatim (#149)" {
  # Name scrubbing must only redact the injected secret value -- ordinary
  # diagnostic names survive so real forensics are kept.
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag/sub"
  echo "diag" > "${rdir}/_diag/Worker_1.log"
  echo "more" > "${rdir}/_diag/sub/Runner_2.log"

  runner_history_archive job-benign "" "${rdir}"

  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-benign/_diag/Worker_1.log" ]
  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-benign/_diag/sub/Runner_2.log" ]
}

# --- #152 _diag filename scrubber must have a fragment pass like content -----

@test "runner_history_archive scrubs a secret a hostile job CHUNKED across _diag path components (#152)" {
  # The single-use JIT config the runner injects into RUNNER_HISTORY_SCRUB_VALUES
  # is a base64 blob of ~1-2 KB -- far larger than NAME_MAX (255). A hostile job
  # cannot encode it in a single filename, so it splits it into < NAME_MAX chunks
  # and nests them as empty dirs/files:
  #   mkdir -p /runner/_diag/<chunk1>/<chunk2>/...; : > /runner/_diag/.../<chunkN>
  # The whole-value substitution in runner_history_scrub_name operates on the FULL
  # rel path (chunk1/chunk2/...): because the secret has no '/' and the inserted
  # separators break contiguity across components, the whole value never appears
  # as a substring of rel and the substitution never fires. The credential then
  # survives VERBATIM as durable path components, reassembled by stripping '/'
  # (`ls -R`/`find`) long after the container was --rm'd. The name scrubber needs
  # the same per-component FRAGMENT pass the content scrubber got in #150.
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag"
  # A credential larger than NAME_MAX so it MUST be chunked to land on disk.
  local secret; secret=$(head -c 600 /dev/zero | tr '\0' 'A')
  secret="${secret}JITxTAILx0123456789=="
  export RUNNER_HISTORY_SCRUB_VALUES="${secret}"
  # Encode the secret as nested 200-char path components (each < NAME_MAX).
  local s="${secret}" rel="" comp
  while [[ -n "${s}" ]]; do
    comp="${s:0:200}"
    rel="${rel}${rel:+/}${comp}"
    s="${s:200}"
  done
  mkdir -p "${rdir}/_diag/${rel}"
  : > "${rdir}/_diag/${rel}/x.log"

  runner_history_archive job-chunk "" "${rdir}"

  # The live JIT credential must not be reconstructable from the durable store.
  # Reassemble every archived path with its '/' separators stripped (exactly what
  # an attacker does post-teardown) and assert the contiguous secret is gone.
  local p joined
  while IFS= read -r p; do
    joined=${p//\//}
    [[ "${joined}" != *"${secret}"* ]] || {
      echo "secret reconstructable from path: ${p}"; return 1;
    }
  done < <(find "${RUNNER_HISTORY_DIR}/jobs/job-chunk" -mindepth 1)
  # The benign archive root still exists (the fix does not gut the store).
  [ -d "${RUNNER_HISTORY_DIR}/jobs/job-chunk/_diag" ]
}

@test "runner_history_scrub_name leaks no IFS/parts into the calling shell (#152)" {
  # The fix splits rel on '/'; that local IFS/read -a state must not escape into
  # the surrounding shell or it would corrupt later word splitting.
  local before_ifs="${IFS:-unset}"
  export RUNNER_HISTORY_SCRUB_VALUES="someverylongsecretvalue0123456789"
  runner_history_scrub_name "a/b/c" >/dev/null
  [ "${IFS:-unset}" = "${before_ifs}" ]
  # Word splitting still uses the default IFS after the call.
  set -- $(printf 'one two three')
  [ "$#" -eq 3 ]
}

# --- #139 path-reserved job id must not escape the jobs/ subtree ----------

@test "runner_history_safe_id never yields a path-reserved token (#139)" {
  # A directory key (unlike a container name) must never resolve to '.', '..',
  # or empty -- any of those would let the archive escape jobs/<id>/.
  [ "$(runner_history_safe_id '..')" != '..' ]
  [ "$(runner_history_safe_id '.')"  != '.' ]
  [ -n "$(runner_history_safe_id '')" ]
  [ -n "$(runner_history_safe_id '..')" ]
  # A benign id is still preserved verbatim.
  [ "$(runner_history_safe_id 'job-1')" = 'job-1' ]
}

@test "runner_history_archive with job_id '..' stays under jobs/ and never writes the store root (#139)" {
  printf 'attacker output\n' > "${STORE}/captured.log"

  runner_history_archive '..' "${STORE}/captured.log" ""

  # The job.log must NOT land in the store root (the escape this fixes).
  [ ! -f "${RUNNER_HISTORY_DIR}/job.log" ]
  # And it must land somewhere strictly under jobs/.
  found=$(find "${RUNNER_HISTORY_DIR}/jobs" -name job.log -type f)
  [ -n "${found}" ]
  case "${found}/" in
    "${RUNNER_HISTORY_DIR}/jobs/"*) ;;
    *) echo "archive escaped jobs/: ${found}"; return 1 ;;
  esac
}

@test "runner_history_archive with job_id '.' stays under a real per-job dir (#139)" {
  printf 'attacker output\n' > "${STORE}/captured.log"

  runner_history_archive '.' "${STORE}/captured.log" ""

  # '.' must not collapse the dest onto jobs/ itself.
  [ ! -f "${RUNNER_HISTORY_DIR}/jobs/job.log" ]
  found=$(find "${RUNNER_HISTORY_DIR}/jobs" -mindepth 2 -name job.log -type f)
  [ -n "${found}" ]
}

# --- #123 capture hook ----------------------------------------------------

@test "runner_history_capture records, archives, and is best-effort (#123)" {
  rdir=$(mktemp -d)
  mkdir -p "${rdir}/_diag"
  echo "d" > "${rdir}/_diag/x.log"
  echo "out" > "${STORE}/job.log"

  run runner_history_capture job-cap 0 "${STORE}/job.log" "${rdir}" image=img runner_type=gpu
  [ "${status}" -eq 0 ]
  grep -q 'job_id=job-cap' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=0' "${RUNNER_HISTORY_LEDGER}"
  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-cap/job.log" ]
  [ -f "${RUNNER_HISTORY_DIR}/jobs/job-cap/_diag/x.log" ]
}

@test "runner_history_capture records the job's exit status on failure too (#123)" {
  run runner_history_capture job-fail 7 "" "" image=img
  [ "${status}" -eq 0 ]
  grep -q 'job_id=job-fail' "${RUNNER_HISTORY_LEDGER}"
  grep -q 'exit_status=7' "${RUNNER_HISTORY_LEDGER}"
}

@test "runner_history_capture never propagates a capture failure (#123 best-effort)" {
  # Point the ledger at an unwritable location: the record write fails, but
  # capture must still return 0 so it can never block teardown.
  export RUNNER_HISTORY_DIR=/proc/nonexistent/history
  export RUNNER_HISTORY_LEDGER=/proc/nonexistent/history/ledger.tsv
  run runner_history_capture job-x 0 "" "" image=img
  [ "${status}" -eq 0 ]
}

# --- #128 external-push seam ---------------------------------------------

@test "runner_history_push is a no-op by default (#128)" {
  run runner_history_push job-np
  [ "${status}" -eq 0 ]
}

@test "runner_history_push invokes a config-driven hook with id + archive dir (#128)" {
  export RUNNER_HISTORY_PUSH_HOOK=_test_push
  CAP="${STORE}/push.args"
  _test_push() { printf '%s\n' "$@" > "${CAP}"; }
  runner_history_push job-push
  [ -f "${CAP}" ]
  grep -qxF 'job-push' "${CAP}"
  grep -qxF "${RUNNER_HISTORY_DIR}/jobs/job-push" "${CAP}"
}

@test "runner_history_push swallows a failing hook (#128 best-effort)" {
  export RUNNER_HISTORY_PUSH_HOOK=_boom
  _boom() { return 1; }
  run runner_history_push job-boom
  [ "${status}" -eq 0 ]
}

@test "runner_history_push tolerates an enabled-but-undefined hook (#128)" {
  export RUNNER_HISTORY_PUSH_HOOK=no_such_function
  run runner_history_push job-undef
  [ "${status}" -eq 0 ]
}
