# Changelog

## 2.7.0 — 2026-08-23

gspec 3.1.1: the adapter learns gspec's new feature-folder layout, the pin moves
from 2.7.0, and `/gaffer:migrate` gains the detection and verification for taking
a consumer repo across. Backward compatible, and — unusually for a layout change
— **nothing is required of an existing repo** (see Upgrading).

### Upgrading — nothing required, and that is the design

Upgrade gaffer and keep working. The adapter reads **all three** gspec layouts,
so a repo still on gspec 2.x drives the loop exactly as it did before. There is
no flag day and no manual step.

Migrating your specs to gspec 3.1.1 is a **separate, optional** decision, and the
reason to make it is not breakage: `/gspec-plan` at 3.x *writes* to the new
location, so the next replan of any feature quietly leaves a second plan beside
the old one. The full sequence, its hazards, and the two checks that tell a
broken migration from a finished backlog are in
[docs/gspec-3.1.1-migration.md](docs/gspec-3.1.1-migration.md).

`/gaffer:migrate detect` reports an unmigrated repo as `FINDING=gspec-v2-layout`.
That is informational. `apply` does **not** relocate anything — the move belongs
to gspec's own `/gspec-migrate` (see below).

One thing to know before you migrate, because the order is not recoverable for
free: **install gspec 3.1.1 before running `/gspec-migrate`.** A repo still on the
old gspec has the *old* `/gspec-migrate` in `.claude/commands/`, and that version
migrates *toward* `gspec/tasks/` — the layout you are leaving — reporting success
as it does.

New repos from `/gaffer:new-project` get gspec 3.1.1.

### The adapter reads three layouts, behind one seam (ADR 0020 D3)

gspec 3.0 moved everything about a feature into one folder. The adapter now
resolves all three shapes it has ever shipped:

| layout | PRD | plan |
| --- | --- | --- |
| 3.x (`spec-version: v2`) | `gspec/features/<slug>/prd.md` | `gspec/features/<slug>/tasks.md` |
| 2.x (`v1`) | `gspec/features/<slug>.md` | `gspec/tasks/<slug>.md` |
| pre-2.0 | `gspec/features/<slug>.md` | `gspec/features/<slug>.plan.md` |

- Every gspec path is now built in **one of four functions** —
  `_prd_paths` / `_plan_paths` / `_resolve_prd_path` / `_resolve_plan_path` —
  rather than in nine inline expressions. A fourth layout is an edit to those.
- The newer layout **shadows** the older for a given slug: `/gspec-migrate` moves
  rather than copies, so a slug present in both is a half-finished migration and
  the destination is the truth.
- `arch.md` and `design.html` are **outside the consumed contract**. They say what
  to build, which is gspec's half of the seam, so `next` surfaces their paths
  (`ARCH=` / `DESIGN=`) for an implementer's brief and the adapter never parses
  them.
- New `gspec-backlog.sh plans` prints the layout census —
  `<slug> <path> <layout> <task-lines-read> <unchecked>`.

**The artifact pin accepts `v1` and `v2`, not `v2` alone.** Narrowing it would make
`check` return rc=3 — stopping the loop — on a repo whose backlog the adapter
reads perfectly well. The pin exists to catch a format the code *cannot parse*; it
is not a lever for nagging a repo into migrating.

### `/gaffer:migrate` detects and sequences the relocation; it does not perform it

The move stays gspec's (ADR 0020: gspec owns spec format and layout, this plugin
owns execution), for three reasons each sufficient on its own — it must repair the
relative links the relocation breaks in *both* directions, it must reformat each
file through gspec's own `spec-migrator`, and it edits files gspec's
`task-immutability` floor is watching, so a shell `mv` racing that floor loses
intermittently.

What this plugin owns is the half gspec cannot do:

- **`FINDING=gspec-v2-layout`** — deliberately *not* worded as breakage.
- **`FINDING=plan-without-prd`** and **`FINDING=half-moved`**, split apart after a
  false positive on a live repo. A folder with `tasks.md` and no `prd.md` is
  equally an interrupted migration *and* a deliberate infra plan that was never a
  product capability; the finding states the observable fact and offers both
  readings rather than asserting a cause it cannot see.
- **`verify` reports the layout** and stays green through a mixed repo — a
  half-migrated repo is a normal intermediate state, not a fault.

### `verify` can tell a finished backlog from an unreadable one

The old check was `plans > 0 && packets == 0`, which cannot separate "nothing can
parse this" from "everything here is done". Both yield zero packets, so the alarm
fired hardest on the repos that had done the most work — and it fired on this
one, over five correctly-relocated plans holding 66 checked task lines.

`verify` now reports **task lines read**, counted with the same pattern the node
builder uses, and reserves the failure for `read == 0`:

```
· 24 plan file(s), 514 task line(s) read -> 28 unchecked packet(s)
```

### Also

- **`migrate.sh apply` stamped the wrong `spec-version`.** It took the *first*
  entry of the supported set, which became `v1` the moment the pin widened to
  `v1 v2` — producing files gspec's own `spec-integrity` floor immediately flags.
  It now takes the newest. Widening a *read* set is not the same as changing what
  to *write*.
- **`test-runstate.sh`'s SIGPIPE flake is closed at the class.** Assertions are
  evaluated with `pipefail` off, so a producer's `rc=141` — taken when `grep -q`
  exits on first match and closes the pipe — can no longer be reported as the
  pipeline's status. 43 assertions had that shape; fixing only the one that fired
  would have left 42 loaded, and CI runs the loaded condition.
- **The consumer overlay describes the new layout.** `templates/spec-driven-base/`
  is what `/gaffer:new-project` lays down, and it still named `gspec/tasks/` — a
  repo bootstrapped on 3.1.1 would have received an operating brief pointing at a
  directory gspec no longer writes.
- Loop prompts now take the plan path from the adapter's own `PLAN=` / `FILE=`
  output instead of hardcoding one. A prompt that hardcodes a path is a ninth call
  site by another name.

### Verification

Three repos migrated end to end on clones — this plugin's own backlog plus two
real consumer repos, 43 PRDs and 37 plans. All three produced **byte-identical
packet nodes and feature tables** before and after, and introduced **zero** broken
links. Sweeps: `gspec-backlog` 257, `migrate` 246, ten suites green.

Two paths are **not** yet exercised and are recorded as such rather than omitted:
`/gspec-migrate` itself (all three relocations were scripted, following its
documented flow) and the `deployable:` → `module:` rename (no repo to hand had a
Deployables section).

## 2.6.0 — 2026-08-11

Two features: the run-state cleanup (ADR 0024 + ADR 0025) and the write-path
hardening that followed from it. Backward compatible, with **one manual step for
existing repos** (see Upgrading).

### Upgrading — one step, and skipping it is not silent

Add this line to your repo's `.gitignore`:

```
.agents/run-state-prev.yaml
```

`runstate.sh write` now keeps a last-known-good copy of run-state beside it.
Without the ignore line that copy lands **untracked**, and `reconcile` reads
untracked files in `git status --porcelain` as scratch sitting on the green
checkpoint — so it discards the backup, and the pause path's
`git stash --include-untracked` sweeps it. The backup would be destroyed by the
very recovery path it exists to serve, and your tree would read dirty every run.

`/gaffer:migrate detect` reports this as `FINDING=writebackup-ignore`. `apply`
does **not** fix it: this plugin never edits a consumer's `.gitignore`, the same
rule that already applies to the `.agents/pause` entry.

New repos from `/gaffer:new-project` get the line automatically.

### The gspec task checkbox is the completion record (ADR 0025)

- At packet close a gspec-sourced packet's checkbox flips **inside the packet
  commit**, so the work and the record that it happened land atomically instead of
  in a follow-up commit that can be lost or reverted independently.
- Under `--parallel` the **scheduler** flips at green-lane merge, not the lane —
  the task file sits outside every packet's `allowed_files`, so lanes sharing a
  feature would otherwise contend on it.
- `run-loop` preflight reports any `[orch packet:<id>]` trailer naming a still-
  unchecked task. It reports only: a box may be unset because the work was
  reverted, so reconciling is a human decision.
- **`backlog.done` is deleted**, with no counter, tail or replacement. It stored
  exactly what the capability checkboxes derive, and because `write` replaces the
  whole file an agent re-emitted the entire list from memory every packet
  (measured: 95 entries, 16% of a 27,400-byte run-state, no checksum). `pending`
  survives deliberately — it carries the *chosen order*, which is a decision, not
  derivable state.
- Schema stays 3. A run-state still carrying `done:` parses and the field is
  ignored; there is no flag day.

### Findings expire (ADR 0024)

- `add-finding` requires `--packets` and there is no run-wide escape hatch: an
  entry that can never expire is the thing being removed.
- Expiry demands **positive evidence** — the gspec checkbox, or an
  `[orch packet:<id>]` trailer. Absence from `pending` reads as *unknown*, and
  unknown blocks expiry.
- Capture precedes drop, always: filing a backlog task **is** the capture; a spent
  sign-off is not.
- Finding bodies are opt-in (`--body`). Most findings are carried by their summary.
- `/gaffer:migrate` gained a one-entry-at-a-time findings triage. `apply` still
  never deletes a finding.

### The tally's ✅ is this session

Report conventions and both loop shapes now state that ✅ counts what **this
session** landed, from check-ins already rendered, with nothing read from disk.
The "buckets account for the whole backlog" rule applies to the forward buckets
only — a growing backlog is not a fixed set to partition, so *2 landed, 25 to go*
reads honestly.

### `runstate.sh` can no longer corrupt or lose run-state

run-state is the loop's only state that survives a session, and it is gitignored —
so a bad write had no `git restore`. Two paths could destroy it and both had fired
in production.

- **Every value is quoted on write**, with `'` doubled, and every reader strips
  symmetrically. `set` and `add-finding` share one encoder, so hardening one cannot
  leave the other behind — the split that caused the original bug. A value
  containing `: ` used to open a sibling key and break the file.
- There is deliberately **no plain-scalar allowlist**. One was built and removed
  the same day after producing two classes of silent wrongness: values ending in
  `:` wrote an unparseable file with `rc=0`, and `no`/`00`/`0755` parsed cleanly
  but returned `False`/`0`/`493`.
- **`write` validates structurally** — empty, whitespace-only, no `schema:` key, a
  malformed column-0 line — refusing with a nonzero exit and leaving the target
  byte-untouched. The bound is stated in the refusal message: this catches
  truncation and gross malformation, not a well-formed document that is
  semantically wrong.
- **`write` keeps a last-known-good copy**, because the checks cannot see a
  transform that dies *between* lines: `schema: 3` + `status: running` is exactly
  the 26 bytes the live truncation left.
- **`set` no longer strands a block scalar's body.** `trim-note` re-emits `note:`
  as a `|-` block by design, and a subsequent `set … note` used to orphan the body
  and break the parse.
- Run-state files now show `status: 'running'` rather than `status: running`.
  Functionally invisible — nothing greps those values and the readers strip — but
  visible if you read the file directly. Legacy unquoted files read correctly:
  verified across 408 values written by the old writer, 401 byte-identical and the
  7 differences all moving toward what a YAML parser returns.

### The sweeps no longer report green without checking

- `test-runstate.sh` and `test-migrate.sh` guarded their YAML-parse assertions
  behind a parser probe that returned success when PyYAML was absent. On a stock
  host — python3 present, PyYAML is not stdlib — **21 assertions passed while
  checking nothing** and the sweep reported 213/0 green. They now skip **loudly**,
  counted and named in the summary line.
- **CI declares PyYAML** rather than relying on the runner image. If you forked the
  workflow, take this: without it CI can report green while verifying nothing.
- A ~1-in-20 intermittent failure in the `trim-note` assertions is fixed. Piping
  into `grep -q` under `pipefail` races — `grep -q` exits on its first match and
  closes the pipe, the producer takes SIGPIPE, and `pipefail` reports rc 141
  instead of the successful match. Confirmed over 73 consecutive clean runs.
- `scripts/test-runstate.sh` 213 → 390 assertions; `test-migrate.sh` 207 → 208.

### Corrected documentation

- **The relay crossover is 40 packets, not 20.** The change landed in the skills
  on 2026-08-10 but never reached `README.md` or the plugin description, which
  additionally claimed relay was *cheaper* past the crossover — the opposite of the
  measurement that moved the number (relay costs **1.84x** inline per packet).
  Relay is retained rather than deleted because that figure is contaminated by
  busy-wait polling in the coordinator's own context; a clean two-arm A/B is the
  open question, and deleting relay is a legitimate outcome of it.
- `loop-cost-controls` is deferred. Both its P0s fix relay-mode behaviour, and
  relay has never engaged in production.
