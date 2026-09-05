# Test levels

The bash suite is layered. This file defines the layers, says what belongs in
each, and records which layers deliberately do not exist yet.

It is the mechanism layer beneath PRD.md invariant 4 ("keep a strict,
industry-aligned test bar"), which fixes the promise that a bar exists and
leaves the choice of layering to a replaceable spec. See PRD.md §0.4 for the
full list of checks the gate runs.

## Why layer at all

Every bash test used to sit flat in one directory named after a single level.
The contents had already outgrown the name: some cases source one library and
call one function with stubs on `PATH`, while others assemble a whole container
argv out of several libraries at once, or run an operator-facing script that
sources half the tree. A red check on that flat directory said only "something
in bash broke".

Layering makes the failure legible before anyone opens a log: a red unit level
means a single function's contract moved, and a red integration level means the
pieces stopped fitting together. It also states the cost of each level up
front, which is what stops the cheap level from quietly filling with expensive
tests.

## The levels in use

### unit

**Exercises one function, or one file, in isolation.**

Belongs here:

- sourcing a single library and calling one of its functions, with fakes on
  `PATH` for anything it shells out to;
- an executable spec over a single artifact — a script's argv and usage
  contract, a `justfile`'s recipes, a `Dockerfile`'s structure, a document's
  required shape.

Lives in `test/bats/unit/`. Run with `just test-unit`.

### integration

**Exercises several scripts, libraries or components working together.**

Belongs here:

- a case that sources more than one library because the behaviour under test is
  the composition — the container argv assembled from layout, config and
  hardening pieces is the canonical example;
- running an operator-facing script end to end, letting it source the libraries
  it really sources, and asserting the side effects and the argv it produced;
- a drift check that compares two real artifacts against each other.

Lives in `test/bats/integration/`. Run with `just test-integration`.

`just test` runs both, and is what the CI bats job runs.

## Choosing a level

The question is not "how big is the file" but **what would have to change for
this test to go red**. If the answer names one function or one file, it is a
unit test. If the answer is "the way two or more parts fit together", it is an
integration test. A test whose subject is a single file's structure stays at the
unit level even when the file it inspects is large.

## Naming

A test file is named after its subject: the production file's basename with
`.sh` dropped and every `-` replaced by `_`, plus `.bats`. The level a test
lives at is not part of its name, so moving a test between levels is a `git mv`
and nothing else.

The TDD hook that refuses a production edit without a matching test searches the
whole test tree for that name, so it is indifferent to the level — it asks
whether a test exists, not where.

## Deliberately not created yet

Two further levels are named here so that nobody invents a third name for them,
and are **not** created:

- **system** — exercising a deployed runner through its own status surface,
  rather than through stubs. This waits for the status endpoint: without one,
  a "system" test could only re-assert what the integration level already
  covers through fakes, which would add a directory and no signal.
- **acceptance** — exercising the operator's actual path, from a clean host to a
  runner picking up a job. This waits for the quick-deploy path, for the same
  reason: the level is defined by the entry point it drives, and that entry
  point does not exist yet.

Creating an empty directory for either would be a claim the suite cannot back.
They get created when the thing they would drive exists.
