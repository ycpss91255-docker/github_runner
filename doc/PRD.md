# PRD §0 — Principles layer (github_runner)

This chapter is the **principles layer** of `github_runner`: it describes no
single feature. It describes the properties every feature must satisfy, and the
criteria used when trading features off against each other.

Every rule in this chapter is **written out in full**. A reader does not have to
read an ADR, the README or `CONTEXT.md` first in order to understand and follow
it; where another document is referenced, the reference points at evidence — it
never carries the rule itself.

Everything written here is **already-established reality**, or a commitment that
has been decided explicitly and merely awaits implementation. Matters still
under discussion are not written into this chapter.

---

## §0.1 Glossary

This section lists only the terms needed to read §0. The full domain
vocabulary (runner, scope, JIT config, scale set, RUNNER_HOME, the `_gh` seam,
the destructive harness, and so on) lives in `CONTEXT.md` and is not repeated
here.

- **Invariant** — a property that must hold at all times. It is not a goal and
  not a default: an implementation that violates it is a defect, not a
  trade-off. **No ADR may violate an invariant.**
- **Design principle** — a criterion that the invariants do not cover but that
  still needs to be judged consistently. Principles can pull against each
  other; when they do, §0.6 decides the priority. Every principle must declare
  **which invariant it serves**; a criterion that serves no invariant is not a
  principle, it is a preference.
- **Implementation spec** — the **concrete mechanism** chosen so that an
  invariant can be checked (a particular linter, a particular test command, a
  particular threshold). Mechanisms are **replaceable**: swapping one linter for
  another does not shake an invariant, but removing the check itself does.
- **Seam** — a boundary deliberately extracted so it can be substituted in
  tests. This project's seams take two forms: Go interfaces (`Session`,
  `Provisioner`, `JITConfigMinter`, `Reaper`, `DeviceDetector`, `HostProbe` in
  `listener/listener.go`, and `JobLogger` in `listener/joblog.go`), and a
  single-function bash wrapper (`_gh()` at `lib/common.sh:375`, the one and only
  exit for every GitHub call).
- **Fail-closed** — when an input or a state cannot be determined, abort with an
  error rather than guessing a value and continuing. The opposite is fail-open
  (guess a value and keep running).
- **Chokepoint** — the single place in the program where a dangerous piece of
  semantics appears. The most important example in this project is
  `lib/common.sh:25-61`: `RUNNER_HOME`, the root of every `rm -rf`, is resolved,
  validated and frozen `readonly` exactly once there, whether it came from the
  `--runner-home` flag, from the environment, or from the default.

---

## §0.2 Product invariants

The following properties must hold at all times.

> **No ADR may violate these invariants. A violation is a defect, not a
> trade-off.**
>
> If a proposal appears to require violating one of them, the correct response
> is to **redesign the proposal**, or to **first amend this chapter and explain
> why the original invariant was wrong** — not to record it in an ADR as a
> "known trade-off".

---

### Invariant 1 — Never fail silently

**Rule:** Any input, configuration or state whose meaning cannot be determined
aborts with an **explicit non-zero error** that names which item it was and what
was expected. Do not substitute a default and continue, do not apply the change
partially, do not merely log it and keep running.

**Why it is fixed:** What this tooling produces is "an execution environment
that carries someone else's code". A misguessed setting does not break on the
spot; it quietly produces a runner whose isolation differs from what was
expected, and the problem surfaces much later in a form that is hard to
attribute. Errors are only cheap **at the moment they happen**.

**Designs that already serve this invariant:**

| Mechanism | Location | Behaviour |
| --- | --- | --- |
| Fail-closed config loading | `listener/config.go:94-107` `LoadConfig` | An unreadable file, a YAML parse failure or a failed validation all return an error; a partial or default-filled config is never returned |
| Required-field checks | `listener/config.go:111-150` `validate` | An empty list, a missing `name`/`scale_set`/`labels`/`image`, a duplicate `name`, a duplicate `scale_set` all error out directly, naming the offending entry in the message |
| Misspelled build tool refused | `listener/config.go:164-171` `validateBuildTool` | Only `kaniko`/`buildkit`/`none`/empty are accepted; anything else returns `unknown build_tool %q` instead of silently routing to no builder at all |
| Removed modes fail closed | `listener/config.go:177-185` `validateConcurrency` | The deleted `mode: fixed` now returns an explicit error, so an old config shows a migration message at startup instead of being treated as the default mode |
| Reserve can only go up | Same as above, `minReservePercent = 10` (`config.go:80`) | An explicit 1..9 is refused; it is almost certainly a misreading of the semantics rather than a deliberate lowering |
| Host probe validated item by item | `listener/hostprobe.go:68-93` | A malformed line, a non-numeric value, a missing required key (`loadavg1`/`nproc`/`mem_available_kb`/`mem_total_kb`), or a non-positive `nproc` or `mem_total_kb` (division by zero) all return an error |
| Lexical RUNNER_HOME validation | `lib/common.sh:53-61` | A non-absolute path, `/`, `/.`, `/..`, `$HOME`, or any path containing `..` exits `FATAL`; no attempt is made to repair it |
| Label validation | `lib/common.sh:122-124`, `:162-165` | If `LABELS` in `setup.conf` does not match the character set, `FAIL` and exit — no falling back to a default |
| owner/repo validation | `lib/common.sh:130-131`, `:458`, `:468` | Anything invalid exits, because these values flow into `rm -rf` target paths and GitHub API paths |
| Strict mode in entry scripts | `script/*.sh`, `listener/provision-job.sh`, `listener/host-probe.sh`, `images/build-runner-image.sh` (15 files in total) | All use `set -euo pipefail`; `lib/*.sh` are sourced libraries and deliberately do not set `-e` (it would pollute the caller) |

**The one permitted exception, which must state its reason in writing:** the
teardown path may be best-effort — a single failed removal must be logged but
must not abort the whole sweep, otherwise one leftover blocks every remaining
cleanup. Exactly one place takes this exception today and states it in the file
header: `listener/reap.sh:13-14` (`set -uo pipefail`, no `-e`, with the comment
"Best-effort: a failure of any single removal is logged, not fatal"). Anyone
taking this exception **must write the reason in the header of the same file**;
best-effort without a stated reason is a defect.

**Known gaps (defects, not trade-offs):**

- `listener/config.go:100` uses `yaml.Unmarshal` rather than a decoder with
  `KnownFields(true)` enabled, so **a misspelled key in the config file is
  silently ignored** (spelling `reserve` as `reserv`, for instance, applies the
  default instead of reporting an error).
- `hardening_profile` has a field (`listener/config.go:42-44`) and is carried
  all the way through to the `RUNNER_HARDENING_PROFILE` environment variable at
  `listener/provisioner.go:87`, but `validate` (`config.go:111-150`) does not
  validate it, and nothing on the bash side reads it
  (`listener/provision-job.sh:22` has only a comment). Any string — including a
  misspelled one — is therefore accepted and has no effect. The `runtime` field
  is in the same position.

---

### Invariant 2 — Defaults fall towards safety

**Rule:** For every security-relevant switch, the **unset state must be the more
restrictive side**. Loosening must be an explicit, named operator action. There
must be no path that is "more permissive because it was not configured".

**Why it is fixed:** This tooling is installed **on other people's hosts** by
**operators who are not yet familiar with it**. The most common deployment state
is not "carefully tuned settings" but "untouched defaults". If the defaults lean
permissive, then the isolation of the overwhelming majority of real deployments
is equivalent to no isolation at all.

**Designs that already serve this invariant:**

| Switch | Default | Location | How it is loosened |
| --- | --- | --- | --- |
| Host docker socket | **Empty; no job container gets the socket** | `lib/runner-container.sh:49` `: "${RUNNER_DOCKER_SOCKET:=}"`; the mount branch at `:179-185` | The operator explicitly sets that environment variable to a socket path; the mount still keeps `:Z` relabelling and does not turn MAC off |
| Device passthrough | **Empty; no `--device` is passed** | `lib/runner-container.sh:56`; expanded item by item at `:186-192` | Name the device nodes explicitly in the runner type config |
| Extra capabilities | **Empty** | `lib/runner-container.sh:41` `RUNNER_CAP_ADD:=` | Add a single capability by name |
| Baseline hardening | `--cap-drop=ALL`, `--security-opt no-new-privileges` and `--pids-limit` (default 4096) always applied | `lib/runner-container.sh:87-98`, `:40` | There is no "turn hardening off" flag |
| Privileged containers | **The path does not exist** | The run assembly at `lib/runner-container.sh:269-277`; `lib/runner-build.sh:48-68` | There is no `--privileged` anywhere in the repo, negatively asserted by `test/smoke/runner_container.bats:270-306` and `runner_build.bats:54-58` |
| seccomp / MAC | The engine default profile is kept; no `seccomp=unconfined`, no `label=disable` | The explanation at `lib/runner-container.sh:84-85` and the assembly at `:269-277` | None |
| RUNNER_HOME | Defaults to `<repo>/runners`, and is validated and frozen in that same place | `lib/common.sh:45-61` | Only `--runner-home` or the environment variable can change it, and only to another absolute path that **passes the same validation** |
| Reading setup.conf | `LABELS=` is extracted with `sed`; the file is **never sourced** | `lib/common.sh:157-167` (SEC-6) | None; this file is writable by the runner user, and sourcing it would be executing a shell that a job can write into |
| Non-interactive destructive operations | **Refused** | `lib/common.sh:333-336` | `--yes` must be passed explicitly |

Every one of the above is pinned by a negative-assertion test rather than upheld
by convention: `test/smoke/runner_container.bats:270-380` (hardening flags, no
socket, no `--privileged`, no `seccomp=unconfined`, no `label=disable`, exact
device count), `test/smoke/runner_build.bats:54-74,114`, and
`test/smoke/destructive.bats:77-86`.

---

### Invariant 3 — One source of truth; no copies maintained in parallel

**Rule:** Every fact has exactly **one** authoritative source in the system. If
a second copy must exist for reasons of performance, test sandboxing or a
language boundary, then **an automated check must guarantee the two agree**; a
copy without a drift check is never allowed to exist.

**Why it is fixed:** Copies maintained in parallel do not break at the same
time; they **diverge gradually**, and the divergence is discovered at the least
convenient moment (usually when someone follows the documentation and gets a
different result). Human discipline is no substitute for a check: a lapse in
discipline produces no signal.

**Designs that already serve this invariant:**

| Fact | Authoritative source | Copy and its drift check |
| --- | --- | --- |
| Structure and semantics of the runner type config | Go: `LoadConfig` in `listener/config.go` (ADR-0003 states that Go is the authoritative parser) | Bash **does not parse this file at all**; Go shells out only the fields a single provision needs (`listener/provisioner.go:79-89`) |
| Operator-facing sample config | `deploy/runner-types.sample.yaml` | `listener/testdata/runner-types.sample.yaml` is a byte-identical copy, pinned by the `diff -u` in `test/smoke/runner_types_config.bats:16-21` |
| Sample config agrees with the real schema | Same as above | `listener/sample_config_test.go:23,52,79` loads the shipped sample with the **real parser**, so a documented example cannot diverge from the schema |
| Runner file locations and naming | `lib/runner-layout.sh` | Consumers (`resolve_target`, `list_runners`, `runner_service_running`, `cleanup.sh`) all derive through this module rather than re-encoding it each |
| GitHub calls | `_gh()` at `lib/common.sh:375` | Every higher-level adapter is layered on top of it; tests only need to override this one function |
| Release tarball version / path / URL / integrity | `lib/runner-release.sh` | `init.sh` / `update.sh` keep only their own verify **policy** and share the same primitives |
| The set of self-test entry recipes | `justfile` | `test/smoke/justfile.bats:27-63` pins the recipe names and the image pins |

---

### Invariant 4 — Keep a strict, industry-aligned test bar

**Rule:** Every behaviour must have **an automated check that fails when that
behaviour changes**. What is promised is that "the bar exists and is strict";
**the mechanism that achieves the bar (which linter, which test layering, which
metric) is a replaceable implementation spec**, see §0.4.

**Why it is fixed:** This is the **enforcement mechanism** for invariants 1, 2
and 3. An invariant without a check is just a sentence in a document. The
promise sits in the invariant layer and the mechanism in the spec layer because
tools go out of date and promises do not: replacing kcov or replacing shellcheck
should never require editing this chapter.

**Current shape (as of writing):**

- Bash: 30 `.bats` files under `test/smoke/`, 396 `@test` cases in total. The
  technique is uniformly **stub-and-capture** (place fake `docker`/`podman`/`run.sh`
  on `PATH`, capture the actual argv and assert on it), asserting externally
  observable behaviour rather than implementation details.
- Go: 9 `_test.go` files under `listener/`, 58 `func Test` in total. The core
  loop is tested in isolation with a fake `Session`, a mock minter, a recording
  provisioner and a stub detector.
- End-to-end tests that need real credentials are **explicitly isolated** and
  not mixed into the default test run: `listener/integration_test.go:1` (the
  `//go:build integration` build tag) plus the skip on missing environment
  variables at `:31-33`, so the default `go test ./...` never touches them.

---

### Invariant 5 — Extension is configuration, not code changes

**Rule:** Adding an isomorphic runner class (new hardware, a new image, a new
label set, a new concurrency policy) must be **one more entry in a config file**
and must not require modifying code. Code must contain no logic that branches on
a class name.

**Why it is fixed:** This fleet is deliberately heterogeneous — the situation
recorded in ADR-0004 is a mix of Raspberry Pi, Jetson, IPC, server, laptop and
desktop machines, across ARM and x86, some of them intermittently online, with
the proportion expected to keep tilting towards a general-purpose compute pool.
If every new kind of hardware required a code change, the speed of extension
would be bound to the maintainer, while the heterogeneity only increases.

**Designs that already serve this invariant:**

| Mechanism | Location |
| --- | --- |
| One runner type maps to one scale set maps to one listener instance, as a pure data transformation | `listener/wiring.go` `RunnerType.Instance` / `Instances`; the file header states outright that "adding a second type is a config entry, not a code change" |
| Concurrency policy is decided by config; code does not branch on class names | `listener/wiring.go` attaches either the detector or the host probe based on `Concurrency.DeviceSized()`; both are seams |
| The shipped sample is the proof: two classes coexist with no code change | `deploy/runner-types.sample.yaml:50-90` (`gpu` and `cpu`), pinned by `test/smoke/runner_types_config.bats:23-35` and `listener/wiring_test.go:82` `TestInstancesFromTypes` |
| One class per scale set uniqueness is validated | `listener/config.go:138-141` |

**The boundary of this invariant (already decided by ADR-0004):** the unit of
extension is **one independent listener per host**, each self-adjusting to its
own local capacity, with work routed by labels. **No cross-host scheduler is
built** — ADR-0004 records explicitly that if globally resource-aware scheduling
is genuinely needed, that is the trigger condition for migrating to Kubernetes,
and building one ourselves would be work that gets thrown away. The scope of
"extension is configuration" is therefore **class extension within a single
host** and **horizontal growth in the number of hosts**; it does not include
unified cross-host scheduling.

---

### Invariant 6 — Each container is responsible for exactly one thing

**Rule:** One job maps to one brand-new, single-use container, destroyed as soon
as the job ends. A container must not carry a second job, and no writable state
may be retained between jobs.

**Why it is fixed:** This is the project's **reason to exist**. The problem
recorded in ADR-0001 is precisely the two intrinsic defects of persistent
runners: state residue between jobs (root-owned residue left by a previous job
poisons the next checkout) and **credentials surviving across jobs**. Neither
can be eliminated by cleanup; they are the direct consequence of "one runner
serving many jobs". Cleanup is a convergent effort; destruction is a structural
guarantee. Any proposal to "reuse containers for speed" is trading that
guarantee for speed.

**Designs that already serve this invariant:**

| Mechanism | Location |
| --- | --- |
| One `--rm` single-use container per job | `lib/runner-container.sh:269-277` (`run --rm --init`) |
| Single-use JIT config generated server-side, with no long-lived registration token left on the host | `listener/minter.go`; `runner_config_jit_generate` in `lib/runner-config.sh` |
| JIT credentials passed by **file** rather than argv, mode 0600, deleted at teardown | `listener/provisioner.go`; pinned by `listener/provisioner_test.go:91` `TestContainerProvisionerJITFileIs0600AndRemovedAtTeardown` and `test/smoke/runner_container.bats:105` |
| Orphan container sweeping | `lib/runner-reaper.sh` + `listener/reap.sh`, swept once at startup and again periodically (`listener/listener_test.go:446,463`) |
| Forensic data captured before teardown, rather than keeping the container | ADR-0002's capture-before-teardown; `lib/runner-history.sh`, pinned from `test/smoke/listener_provision.bats:200` onward |

---

### Invariant 7 — Documentation is self-contained and derived from code

**Rule:** Two things hold simultaneously.
(a) **Self-contained**: operator-facing documentation must be readable on its
own and must not outsource its explanation to another document. In particular
the README must not reference ADRs — an ADR records "why it was decided this
way", whereas an operator needs "what this is and how to use it"; the two cannot
substitute for each other.
(b) **Derived from code**: anything that can be derived from code or a config
file itself (recipe lists, flag lists, schemas, sample configs) must not be
maintained as a second hand-copied version alongside it; where such a copy is
unavoidable, the drift-check requirement of invariant 3 applies.

**Why it is fixed:** Hand-copied documentation is an asset that is **certain to
go stale**, and it emits no signal when it does. READMEs in four languages then
multiply that cost by four. As for "self-contained": an installation guide that
requires reading three prerequisite documents before it can be executed is, in
practice, no installation guide at all.

**Designs that already serve this invariant:**

| Mechanism | Location |
| --- | --- |
| README must not reference ADRs (an executable spec) | `test/smoke/readme_no_adr_refs.bats:17-20`, covering all four language READMEs |
| Two critical GitHub switches must be explained **in the body** of every language README | Same file, `:23-31`, checking respectively that `Require approval for all outside collaborators` and `allows_public_repositories` appear in all four files |
| Sample config validated by the real parser | `listener/sample_config_test.go` (as in invariant 3) |
| The self-test entry recipe list is pinned by a test | `test/smoke/justfile.bats` |
| Four-language README structure kept aligned | `.claude/hooks/check_4lang_readme_sync.sh` (compares section-heading structure, not body text) |
| CHANGELOG drift reminder | `.claude/hooks/check_changelog_drift.sh` |

---

### Invariant 8 — Each named concept has exactly one producing function

**Rule:** Every naming or path derivation rule is implemented exactly once in
the program; where the inverse is needed, the inverse function must share the
same constant as the producing function. Consumers always call that function and
never assemble the string in place.

**Why it is fixed:** Names and paths are facts that **cross every module**. When
something upstream changes (the actions/runner directory layout, say, or the
systemd unit naming), a naming rule scattered across ten consumers means ten
separate edits, one of which is missed — and the symptom of the missed one is
"one runner cannot be found", the hardest class of error to diagnose.

**Designs that already serve this invariant (`lib/runner-layout.sh`):**

| Named concept | The single function/constant | Location |
| --- | --- | --- |
| Org directory sentinel | `RUNNER_ORG_MARKER` (`_org`) | `lib/runner-layout.sh:18` |
| Runner directory | `runner_dir` | `:23-29` |
| Agent name on the GitHub side | `runner_agent_name` | `:34-40` |
| Registration marker file | `runner_marker_file` | `:44` |
| Scope inferred back from a directory | `runner_scope_of` (reads back the same `RUNNER_ORG_MARKER`) | `:48-54` |
| systemd unit pattern | `runner_service_unit_pattern` | `:58` |
| Active version | `runner_active_version` | `:63-68` |

This module is sourced exactly once at `lib/common.sh:75`, after `RUNNER_HOME`
has been validated and frozen; every consumer (`resolve_target`,
`list_runners`, `runner_service_running`, `cleanup.sh`) derives from it, and
`test/smoke/runner_layout.bats:15-61` pins each item.

---

## §0.3 Design principles

The following are criteria the invariants do not cover but which still need to
be judged consistently. **Every principle declares which invariant it serves**;
if a criterion serves no invariant, it does not belong in this layer.

---

### N-1 Core logic does not depend on I/O

> **Serves: Invariant 4 (test bar), Invariant 1 (never fail silently)**

**Rule:** The dependency direction is fixed as **api -> core -> io**. Logic that
makes decisions must be pure functions: data in, data out — no file reads, no
external command execution, no looking at the clock, no network. Everything that
interacts with the outside world is compressed into a **seam** injected from the
outer layer. The core must not depend backwards on the io layer.

**Why:** Decision logic that can only be tested with a real GPU, a real GitHub
scale set or real load is, in practice, logic that **cannot be tested**; and
logic that cannot be tested is logic that will not be checked, which makes
invariant 4 hollow. Conversely, once I/O is pushed to the boundary, every edge
condition of the decision logic can be enumerated with pure data.

**Concrete instance (the clearest example in this project):** the reactive
admission decision logic is pure —

- `admits(h HostResources, inFlight int, reserve float64) bool` at
  `listener/hostprobe.go:122-126` and `admitCount(...) int` at `:131-137` take
  only structs and numbers, with no I/O at all.
- `clamp01` at `:141-150` is the same.
- `HostProbe` (`listener/listener.go:141`) is the only io seam;
  `CommandHostProbe` (`listener/hostprobe.go:43-101`) is the only implementation
  that shells out, and it only "executes, parses line by line, validates,
  converts" — it makes no admission decision.
- The result is that these decisions are enumerated by pure-data tests:
  `listener/hostprobe_test.go:78` `TestAdmitsGatesEachResource`, `:103`
  `TestAdmitCountStopsAtReserveAndCeiling`, `:118`
  `TestBindingNamesScarcestResource`, and `listener/reactive_test.go:75`
  `TestReactiveBurstNeverBreachesReserve`.

The same shape appears at the other seams: `Session`, `Provisioner`,
`JITConfigMinter`, `Reaper`, `DeviceDetector` (`listener/listener.go:51-145`)
take real implementations in production and fakes in tests;
`var _ Session = (*scaleset.MessageSessionClient)(nil)` in
`listener/listener.go` uses a compile-time assertion to guarantee the real
client and the fake remain interchangeable.

---

### N-2 Every interface operation has a CLI equivalent

> **Serves: Invariant 5 (extension is configuration)**

**Rule:** Every capability of the system must be achievable from the command
line. **No feature exists that can only be reached through one particular
interface.** Any new interface (a GUI, a status page, an API) can only be a
**presentation layer** over existing CLI capability; if an interface needs a new
capability, that capability must exist in CLI form first, and the interface then
calls it.

**Why:** An operation that can only be performed through some interface cannot
be scripted, cannot be scheduled, cannot run unattended, and cannot be covered
by automated tests. Once a single capability exists only inside an interface,
automation is permanently missing a piece — and the missing piece spreads: the
next feature will just as naturally be built only in that interface too.

**Concrete instance (currently fully satisfied):** this project has **no non-CLI
interface at all** today — no Go code anywhere in the repo imports `net/http`;
there is no `ListenAndServe`, no `net.Listen`, no listening port of any kind;
the dependencies in `listener/go.mod` are outbound clients only. Every
capability lives on the argv interface of `script/*.sh`, the recipes in the
`justfile`, and the environment-variable interface of the listener binary.
Status querying is CLI too: `script/status.sh` offers `--json` (machine
readable) and `--check` (exit code for alerting), and `script/history.sh` offers
`--id/--repo/--outcome/--since/--until/--json` queries. The cost of this
principle right now is therefore zero, and its entire value lies in **not
breaking it when an interface is added in future**.

---

### N-3 Guarantees come from the backend; the entry point is only an entry point

> **Serves: Invariant 1 (never fail silently), Invariant 2 (defaults fall
> towards safety)**

**Rule:** Validation, authorisation and auditing are always implemented in **the
layer being called**, never in the entry point that calls it. The same guarantee
does not differ based on which entry point the input came through. Interfaces
(flags, environment variables, config files, any future UI) are only responsible
for delivering values; they provide no guarantees.

**Why:** Entry points multiply, and guarantees should not be copied along with
them. Every copy of validation logic is one more copy that can diverge from the
others (violating invariant 3) and one more path that "bypasses the check by
coming in through a particular entry point" (violating invariant 1). A guarantee
provided by an interface is essentially a hint, not a guarantee: anyone can go
around the interface.

**Concrete instances:**

- `RUNNER_HOME` can come from the `--runner-home` flag, from the `RUNNER_HOME`
  environment variable, or from the default. All three paths converge on **the
  same** validation and freezing point at `lib/common.sh:25-61`, after which it
  is `readonly`. The file header at `:15-20` states explicitly why this is not
  done in each script's own argument parser — that is too late, `RUNNER_HOME` is
  already frozen and the layout constants have already been derived from it. As
  a result, "a bad path passed via the flag" and "a bad path passed via the
  environment" are refused in exactly the same way.
- Whoever supplies the runner type config, it goes through the same `LoadConfig`
  + `validate` in `listener/config.go`; bash does not parse this file at all, so
  there is no second, looser validation.
- The confirmation policy for destructive operations is centralised at
  `lib/common.sh:312-360` (`parse_destructive_flags` / `confirm_or_abort` /
  `print_summary`) and shared **verbatim** by `cleanup.sh` and `uninstall.sh`
  rather than reimplemented in each.

---

### N-4 Detect and report; do not auto-repair

> **Serves: Invariant 1 (never fail silently)**

**Rule:** A tool that inspects state only **reports**; it does not modify the
state it inspects. Modification is a separate, named action the operator invokes
explicitly. On finding an inconsistency, the correct output is a clear message
and an exit code usable for alerting — not "I already fixed it for you".

**Why:** Auto-repair makes "what state the system is actually in" unknowable,
because the state may change at any moment as a result of a query. It also makes
wrong repairs silent: something was fixed incorrectly and nobody knows anything
ever happened. Reporting preserves the operator's judgement, and preserves the
problem itself as evidence.

**Concrete instances:**

- `script/status.sh` is entirely read-only: it reads the local runner
  directories, asks GitHub, and renders. Its vocabulary is deliberately
  **diagnostic vocabulary rather than action vocabulary** — `running`/`stopped`,
  `not-found`/`n/a`, `public-ok`/`public-BLOCKED`, `gate-ok`/`gate-WEAK` — and
  `--check` expresses "N of them are unhealthy" as exit code 1 for alerting
  pipelines, rather than going and fixing them.
- The ability to modify state lives in **separate, named commands**:
  `script/set-labels.sh` (change labels), `script/configure.sh` (write
  `setup.conf`), `script/cleanup.sh` (clean up).
- Documentation alignment checks likewise only warn and never edit files:
  `.claude/hooks/check_changelog_drift.sh` and
  `remind_readme_on_core_script.sh` both warn without touching the working tree.

---

### N-5 Reversibility first

> **Serves: Invariant 2 (defaults fall towards safety)**

**Rule:** A destructive operation must offer three things: (a) a **preview**
mode that shows what would happen without doing it; (b) an **explicit
confirmation**, where non-interactive execution must state its intent
explicitly; and (c) a **way out**, so the operator can decline after seeing the
plan. The default state is "do nothing".

**Why:** What this tooling deletes is **directories on other people's hosts**.
The cost of one wrong deletion is asymmetrically higher than the cost of typing
a few more characters. In addition, automation (cron) performs destructive
operations while nobody is watching, so "non-interactive" must be a state that
has to be declared actively, not one that can be slid into silently.

**Concrete instances:**

| Mechanism | Location | Behaviour |
| --- | --- | --- |
| Shared flag parsing | `lib/common.sh:312-323` | `-y/--yes`, `-n/--dry-run`, `-h/--help`; an unknown flag prints usage and exits 1 |
| Confirmation gate | `lib/common.sh:331-343` | `--yes` passes straight through; **a non-TTY stdin without `--yes` always exits 1** and prints the reason; interactively, only `y/Y/yes/YES` passes, and anything else prints `Aborted.` and exits 0 |
| Result summary | `lib/common.sh:349-360` | Success/failure counts plus a per-item failure label, expressed through the exit code |
| Preview | `script/cleanup.sh:224-231,285-288`, `script/uninstall.sh:107-110`, `script/history.sh:136,142-147` | Prints the list of items that would be removed, then prints `Dry-run; nothing removed.` and exits 0 |
| Re-anchoring before deletion | `script/cleanup.sh:293-303` | Normalises with `readlink -f` and then calls `assert_under_runner_home` again; refused items are counted as failures and named |
| Lexical anchoring | `lib/common.sh:138-144` `assert_under_runner_home` | Every rm target must be prefixed with `${RUNNER_HOME}/` or it is refused (defence in depth on top of SEC-3) |
| Stated intent for scheduled execution | `script/schedule-cleanup.sh:157` | The line written into the crontab **carries `--yes` explicitly**, so "unattended" is something seen and agreed to at configuration time rather than inferred at execution time |

Pinned by `test/smoke/destructive.bats` (8 cases, including that a non-TTY
without `--yes` must exit 1, and that `--yes` must actually execute rather than
no-op), `test/smoke/cleanup.bats:150-157`, `test/smoke/uninstall.bats:68-76`,
and `test/smoke/history.bats:140-147`.

**Known gap (a defect, not a trade-off):** `script/remove-runner.sh` performs
deregistration, service removal and `rm -rf "${TARGET_DIR}"` (`:50`), but
**offers no `--dry-run` and no confirmation gate**; its only protection is the
anchoring of `assert_under_runner_home` (`:49`). It is called one runner at a
time by `script/uninstall.sh:124,126` after that script has done its own
confirmation, so the gate exists only on the aggregate path; calling
`remove-runner.sh` directly is ungated.

---

### N-6 Language boundary: new logic defaults to bash

> **Serves: Invariant 3 (single source of truth), Invariant 5 (extension is
> configuration)**

**Rule:** Two languages coexist, but the line is fixed: **new logic is written
in bash by default; it only goes into Go when it cannot be done without the
scale-set client.** Go does not reimplement container, host or cleanup logic;
bash does not talk to the scale-set API.

**Why:** When two languages coexist without an explicit line, logic **drifts
with whatever is convenient for whoever is writing at the time**, and eventually
half of it lives on each side, both sides need maintaining, and any given fact
may have a copy on each side (violating invariant 3). Every existing interface
in this project — `add-runner`, `cleanup`, `status`, `lib/runner-*.sh`, the
`_gh` seam, SEC-3, scheduled cleanup — is bash with bats coverage; the only
thing that genuinely needs Go is the scale-set session protocol, because it has
no bash counterpart.

**Concrete instance:** ADR-0003 already records this sentence as a standing
principle ("new logic defaults to bash; it only goes into Go if it cannot be
done without the scale-set client"). The realised shape is: the Go side has only
the long-poll session, JIT generation, ack, the concurrency pool and the
**authoritative config parsing**; the container provisioner, the reaper, the
build seam and job history are all in bash (`lib/runner-container.sh`,
`lib/runner-reaper.sh`, `lib/runner-build.sh`, `lib/runner-history.sh`).

---

### N-7 Cross the boundary with explicit parameters, never with parsing responsibility

> **Serves: Invariant 3 (single source of truth), Invariant 1 (never fail
> silently)**

**Rule:** When crossing a language boundary, pass only **already-parsed,
already-validated** named values. The same raw data must never be handed to both
sides of the boundary to parse independently. The parameter set at the boundary
is itself an interface: it must be explicit, and changing it is a cross-language
change to be handled as an interface change.

**Why:** "Both sides parse the same file" is the easiest way for invariant 3 to
be violated, and a particularly nasty one: a disagreement between two parsers
over the same input is **silent**, with each side believing it read the input
correctly. Fixing parsing responsibility on one side makes divergence
impossible, rather than merely unlikely.

**Concrete instances:**

- Go reads the entire runner type config and passes bash only the fields a
  single provision needs: argv is `script, jobID, jitFile, image`
  (`listener/provisioner.go:79`), and the rest goes through the named
  environment variables `RUNNER_DEVICES`, `RUNNER_HARDENING_PROFILE` and
  `RUNNER_BUILD_TOOL` (`:85-89`). The bash side never opens that YAML.
- Single-use JIT credentials are **passed by file rather than argv**, mode 0600,
  deleted at teardown — because argv is visible to every process on the same
  host (`listener/provisioner_test.go:91`; `test/smoke/runner_container.bats:105`
  asserts that the credential must not appear in argv).
- The reverse direction holds too: `listener/host-probe.sh` emits only raw
  `key value` numbers, and all conversion and judgement happens on the Go side
  (`listener/hostprobe.go:94-100`); the shell makes no decisions.

---

## §0.4 Implementation specs

This section is the **replaceable-mechanism layer** beneath invariant 4. Every
item here can be replaced by a better tool without shaking any invariant.

> **Every spec must be checkable by a tool. A spec that cannot be checked
> automatically is equivalent to no spec at all.**
>
> That sentence is the one general rule of this section. A spec written in a
> document and upheld because people remember to follow it has exactly the same
> practical effect as not having the spec, because its failure produces no
> signal. Therefore: when proposing a new spec, propose the tool that checks it
> at the same time; anything for which no check can be proposed is not listed
> here.

### Checks currently enforced in practice

Every item below is actually executed by the `justfile` or by
`.github/workflows/ci.yaml`.

| Check | Subject | Tool / command | Where enforced | Rationale |
| --- | --- | --- | --- | --- |
| Shell static analysis | 25 shell files (`script/`, `lib/`, `listener/*.sh`, `images/`) | `shellcheck -x` | `justfile:45` (`just lint`); the CI `shellcheck` job | Bash failures are mostly quoting, undefined variables and exit-code propagation — all statically visible classes |
| Dockerfile linting | `images/runner-base.Dockerfile`, `images/runner-gpu.Dockerfile` | `hadolint` | `justfile:46`; the same job | The execution environment's image is part of the isolation boundary |
| Bash behaviour tests | `test/smoke/` (30 files, 396 `@test`) | `bats` | `justfile:50` (`just test`); the CI `bats` job | Asserts externally observable behaviour (actual argv, actual file effects), not implementation |
| Go compilation | The `listener/` module | `go build ./...` | The CI `go` job (`ci.yaml:57`) | — |
| Go static analysis | Same as above | `go vet ./...` | Same as above | — |
| Go behaviour tests (with race detection) | Same as above (9 files, 58 `func Test`) | `go test -race ./...` | Same as above | The listener's listen/provision loop is concurrent, and `-race` is the only mechanism that catches a data race in CI |
| Toolchain version consistency | The Go toolchain | Pinned to the `golang:1.25.3` container | `justfile:76`, `ci.yaml:11` | Local and CI use the same image, ruling out "it passes on my machine" |
| Sample config drift | `deploy/runner-types.sample.yaml` <-> `listener/testdata/...` | `diff -u` | `test/smoke/runner_types_config.bats:16-21` | See invariant 3 |
| Shipped sample conforms to the schema | `deploy/runner-types.sample.yaml` | Loaded by the real parser | `listener/sample_config_test.go:23,52,79` | The documented example and the code are validated by **the same** parser |
| Self-test entry stability | `justfile` recipes and image pins | `grep` assertions | `test/smoke/justfile.bats:27-63` | — |
| README self-containment | The four-language READMEs | Negative `grep` | `test/smoke/readme_no_adr_refs.bats:17-31` | See invariant 7 |
| Hardening flags do not regress | Container argv | Negative assertions | `test/smoke/runner_container.bats:270-380`, `runner_build.bats:54-74` | See invariant 2 |
| Destructive policy does not regress | Confirmation gate behaviour | Behavioural assertions | `test/smoke/destructive.bats` | See N-5 |
| Merge gate | The three jobs above: shellcheck / bats / go | `ci-rollup` | `ci.yaml:91-117` | Branch protection only needs to track **one** stable check name, leaving sub-jobs free to be renamed or split |

### Layered coverage strategy (an important division of labour)

Coverage **requires line coverage only of the core layer**; the io and api
layers are covered by integration- and system-level tests.

Rationale: chasing line coverage on a thin io wrapper forces out tests of the
"call it once, assert it was called" kind, which prove only that the code exists
and not that the behaviour is correct. Such tests raise the number and lower the
signal. This project's layering is explicit:

- **core (line coverage required)** — pure decision logic with no I/O:
  `admits`/`admitCount`/`clamp01`/`Binding` in `listener/hostprobe.go`,
  `validate`/`validateConcurrency`/`validateBuildTool` in `listener/config.go`,
  and `Instance`/`Instances` in `listener/wiring.go`. Enumerating edge
  conditions here with pure data is cheap, so there is no reason not to do it
  fully.
- **io (covered by integration)** — the thin layer that really interacts with
  the outside world: `CommandHostProbe`, `CommandDeviceDetector`,
  `ContainerProvisioner`, `ClientJITMinter`, `lib/runner-container.sh`,
  `lib/runner-reaper.sh`. This layer is verified by stub-and-capture bats tests
  and Go fake-seam tests that check **the actual commands and side effects it
  produces**, not its line count.
- **api (covered at the system level)** — the operator-facing entry points: the
  argv interface of `script/*.sh` and the environment-variable interface of the
  listener. Covered by end-to-end script-level bats tests.

### Coverage as a metric, not a gate

`just coverage` produces bash coverage with kcov and uploads it to Codecov. It
is **not a merge gate**, and deliberately so:

- The CI `coverage` job sets `continue-on-error: true` (`ci.yaml:72`) and runs
  only on pushes to `main` (`ci.yaml:73`).
- The `needs` of `ci-rollup` contains only `shellcheck`, `bats` and `go`, and
  **deliberately excludes `coverage`** (`ci.yaml:99`, explained at `:96-98`).
- The technical reason is written at `ci.yaml:66-71`: coverage runs in a
  Debian-based kcov image, different from the alpine image used by the bats job,
  and a small group of source-the-script tests is known to misbehave under
  kcov's ptrace (they pass under `just test` and when run individually). Using a
  signal with known environmental noise as a gate manufactures false red, and
  false red trains people to ignore red.

### Recorded facts about the current check surface

- `just check` = `just lint` + `just test`, and **covers bash only**. Go's
  `go vet` and `go test -race` exist only in CI (`ci.yaml:57`); the only
  Go-related recipe in the `justfile` is `build-listener`
  (`justfile:94-97`, which only does `go build`). A local `just check` passing
  therefore does not mean the CI `go` job will pass.
- Coverage currently measures bash only (kcov); Go coverage is not measured.
- The repo contains no `.shellcheckrc`, no `.golangci.yml` and no `codecov.yml`
  — every check runs on its tool's default configuration.

---

## §0.5 ADR spec

An ADR (Architecture Decision Record) records **one decision, its alternatives,
and its consequences**. It is not a tutorial and not an operations manual.

### Filenames and numbering

- Location: `doc/adr/`.
- Filename: `NNNN-kebab-case-title.md`, where `NNNN` is **four digits,
  consecutive, and never reused**.
- Once a number is assigned it is fixed. When a decision is overturned, the file
  is **neither deleted nor renumbered**: the original is marked
  `Superseded by ADR-NNNN` and the new decision takes a new number. History must
  remain readable, because "what we used to think and why we later changed"
  is itself the most valuable part.

### The mandatory serves pointer

Every ADR must carry **one line** of back-pointer after the title and before
`## Context`:

```
> Serves: Invariant N — <invariant title>
```

If the decision is pure mechanism and serves no invariant, that must be stated
explicitly:

```
> Serves: mechanism, no corresponding invariant
```

**Why it is mandatory:** this line is the only structure binding §0.2 to
`doc/adr/`. Without it, the principles layer gradually becomes a manifesto
nobody reads, and the ADRs gradually become a stack of unrelated decisions. With
it, anyone can look up "which decisions support invariant 3" and can immediately
see whether an ADR is in fact merely a preference. **"Mechanism, no
corresponding invariant" is an entirely legitimate answer** — what is mandatory
is that the line be filled in consciously, not that every decision attach itself
to an invariant.

### Required sections

The following four sections are all required, in a fixed order:

1. **`## Context`** — the **facts** that triggered this decision. What the
   situation was, what the constraints were, what the pressure was. No solution
   here.
2. **`## Decision`** — what was decided, written down definitively in imperative
   or declarative form. A reader must be able to read only this section and know
   what the rule is now.
3. **`## Alternatives`** — the other options that were seriously considered and
   rejected, **each with the reason it was rejected**. Listing options without
   reasons is the same as not writing the section. The value of this section is
   that future readers need not walk a dead end that has already been walked.
4. **`## Consequences`** — the consequences of this decision, **including the
   bad ones**. A Consequences section that lists only benefits is marketing
   copy, not a decision record.

Optional sections (as needed): `## Amendment`, `## References`, and any sections
specific to the decision itself.

### Permitted Status values

`Status` goes in the metadata block after the title. The permitted values are
exactly these five:

- `Proposed` — written down, not yet adopted.
- `Accepted` — currently in force.
- `Amended (YYYY-MM-DD, #NNN)` — currently in force, but the body has been
  revised in place; the revision is in the `## Amendment` section.
- `Superseded by ADR-NNNN` — replaced by another ADR, retained for historical
  reference.
- `Rejected` — proposed, evaluated, and not adopted. Retained, because "we
  considered it and rejected it" and "we never thought of it" are entirely
  different pieces of information.

### Amendment in place vs superseding

The criterion is **whether the decision itself changed**:

- **Amendment** — the decision is unchanged, but its scope, details or rationale
  need updating. Method: keep the original text and append a
  `## Amendment (YYYY-MM-DD, #NNN)` section at the end of the file stating what
  changed and why; set `Status` to `Amended`. **Do not rewrite the original
  paragraphs** — reasoning that has been rewritten away cannot be recovered.
- **Superseding** — the decision itself is overturned. Method: write a new ADR
  with a new number; set the old file's `Status` to `Superseded by ADR-NNNN` and
  leave the old file's content untouched.

### A structural lint must exist (discipline does not count)

All of the rules above — filename format, numbering uniqueness, the presence of
the `> Serves:` line, the presence of the four required sections, `Status` being
within the permitted set, and `Superseded by` pointing at a file that actually
exists — must be enforced by an automated check, running under the same CI gate
as the other checks in §0.4.

**Rationale:** this is the same rule as the general rule of §0.4: a spec upheld
by people remembering it does not exist. That applies especially to the ADR
spec, because writing an ADR is a low-frequency action, low-frequency actions
are the easiest place to forget the format, and the symptom of a format failure
(one ADR missing its `> Serves:` line) is something nobody will notice.

### The migration surface for existing ADRs

The current state is **not yet consistent** with the spec above; adopting this
section means a migration:

- The five existing ADRs (`doc/adr/0001-ephemeral-jit-runners.md` through
  `0005-reactive-live-admission.md`) already use four-digit numbers, so **the
  numbering rule needs no migration**.
- **All five lack the `> Serves:` back-pointer** and need it added one by one.
- Section names are inconsistent: they currently use `## Considered options`,
  while the spec fixes `## Alternatives`; all five need to be unified.
  `## Context`, `## Decision` and `## Consequences` already conform.
- `Status` is currently free text, and three different forms have appeared in
  practice: `accepted — supersedes the persistent systemd-service runner model;
  ...` (0001), `accepted (amended 2026-06-29, #154)` (0002), and `accepted`
  (0003/0004/0005). These need normalising to the permitted set.
- **Amendment in place is already established practice**: the
  `## Amendment (#154)` in `doc/adr/0002-job-history-audit-trail.md` is exactly
  the form this section describes and can serve as the template for the
  migration.
- **The structural lint does not currently exist.** There is no test under
  `test/smoke/` that checks ADR file structure (the only one that mentions ADRs,
  `readme_no_adr_refs.bats`, checks that the README **must not** reference ADRs
  — the opposite direction). This lint has to be built.

This section only delimits the migration surface; it does not perform the
migration.

---

## §0.6 Priority order when principles conflict

When two principles point in different directions, decide in the following
order. **The lower number wins.**

1. **Security and isolation boundaries** — invariants 1, 2, 6. Isolation between
   jobs, jobs not obtaining root-equivalent power over the host, closing rather
   than opening on failure.
2. **Correctness and auditability** — invariants 1, 4. Behaviour must be
   correct, and there must be a check that fails when it changes; it must be
   possible to trace afterwards what happened.
3. **Reversibility and operational safety** — N-5. Destructive operations can be
   previewed, refused, and backed out of.
4. **Single source of truth and consistency** — invariants 3, 7, 8; N-6, N-7.
   One copy of each fact, naming derived exactly once, no drift across the
   language boundary.
5. **Extensibility** — invariant 5; N-1, N-2. A new class is configuration, not
   code; capabilities are reachable from the command line.
6. **Convenience** — a few less characters to type, one less confirmation step,
   one less line of explanation to read.

### How to use this order

**This order exists to veto unreasonable trade-offs, not to justify something
being hard to use.**

"Security ranks above convenience" does not mean it can be used as an excuse for
shipping something unusable. The overwhelming majority of design conflicts are
not real conflicts at all but a sign of not having thought long enough — the
first option that satisfies both sides almost always exists and is better. This
order is an adjudication rule that engages only when both **genuinely cannot be
had**; it is not the starting point of design.

**If a decision sacrifices a lower-ranked principle, that decision must record
in its ADR's `## Consequences` which one it sacrificed and which higher-ranked
principle it did so to serve.** An unrecorded sacrifice is indistinguishable
from a defect — six months later nobody can tell whether that awkward part was
deliberate or simply forgotten.

An existing example: ADR-0001 records that device (GPU/USB) runners remain
rootful with precise `--device` passthrough, which sacrifices the completeness
of rootless in order to serve the "isolation boundary" (rank 1: not using
`--privileged`), and states it plainly in the ADR as a conscious trade-off.

---

## §0.7 The standing of this document, and the division of labour between documents

### The standing of this document

This chapter (§0) is the **principles layer**. Its jurisdiction is "what must
always hold" and "how to judge".

- It sits **above the ADRs**: no ADR may violate the invariants of §0.2. If an
  ADR conflicts with an invariant, it is the ADR that is in conflict, unless
  this chapter is amended first.
- It **does not govern features**: any content about "what to build" does not
  belong here.
- It **does not govern the details of mechanisms**: §0.4 lists the mechanisms
  currently chosen, and replacing a mechanism requires no change to §0.2 or
  §0.3.
- **Amending this chapter requires the same seriousness as amending an
  invariant.** Adding or removing an invariant is a decision in its own right
  and should be recorded in an ADR explaining why the original judgement was
  wrong. Adding a design principle requires naming the invariant it serves;
  anything that cannot name one is a personal preference and does not enter this
  chapter.

### Division of labour between documents

Each document answers a different question. **The same thing is explained fully
in exactly one place**; everywhere else points at it, at most.

| Document | Question it answers | When it is updated |
| --- | --- | --- |
| **This chapter §0 (principles layer)** | What must always hold? How do we judge when things conflict? | Only when an invariant or a principle itself changes. The frequency should be very low; if it changes often, something that does not belong in this layer has crept in |
| **`doc/adr/`** | Why did we make **this one** decision? What did we consider? What did it cost? | At the moment an architectural decision with consequences and alternatives is made. When a decision is revised, add `## Amendment` in place; when it is overturned, write a new number and mark the old file `Superseded by` |
| **`doc/prd/`** | What problem does **this group of features** solve? What are the user stories and scope boundaries? | Written before starting a group of features; updated when scope changes. It references ADRs for the "why" and does not restate decision reasoning |
| **`CONTEXT.md`** | What does each term in this domain mean **precisely**? | When a domain concept is introduced or changed. Naming in code, tests and documentation must match this file verbatim |
| **`README.md` and `doc/readme/README.{zh-TW,zh-CN,ja}.md`** | What is this? How do I install and use it? | When an operator-visible interface changes (flags, commands, prerequisites). **Must not reference ADRs** — whatever needs explaining must be explained fully in the body (invariant 7, enforced by `test/smoke/readme_no_adr_refs.bats`). The four-language structure must stay aligned |
| **`doc/changelog/CHANGELOG.md`** | What changed that users can see? | On every user-visible change. The format follows Keep a Changelog and versioning follows SemVer; breaking changes must be marked |
| **`doc/runbook/`** | What do I do when something goes wrong? How should the host be hardened? | When a new failure mode or a new hardening step appears |
| **`SECURITY.md`** | What is the threat model? How do I report a vulnerability? | When the threat model or the reporting process changes |
| **Comments in code** | **Why** is this piece of code written this way? | Together with the code. Comments explain non-obvious reasons; they do not restate what the code does |

### Write each thing exactly once

If you find that the same fact needs to be written into two documents, that is a
signal: either you picked the wrong layer for it, or it should be derived from
code rather than hand-written (invariant 7), or it needs a drift check
(invariant 3). It is one of those three; copy-paste is not among the options.
