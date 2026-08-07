---
name: run-loop
description: Drive the guided autonomy loop across a backlog of task packets. For each packet — branch off the integration base in the local checkout, implement → test → review, commit on branch if green, update run-state, emit a check-in — then pull the next. Honors the session autonomy level and the hard/soft gate split; pauses at a safe checkpoint on any hard gate or ambiguity. Produces check-ins; it integrates onto a non-`main` branch at full-autonomy but never merges/pushes to `main`, opens a PR, or crosses a hard gate. Use to run a semi-attended engineering session over the gspec backlog (gspec/tasks/<slug>.md) or a run-state backlog.
argument-hint: (optional — a backlog source or a starting packet; else reads .agents/run-state.yaml, then the gspec backlog)
---

# Run the guided loop $ARGUMENTS

Drive the implement → test → review → commit-on-branch loop across a backlog,
one **commit-sized, resumable** packet at a time. The **Chief Engineer** executes
this loop — either here in this session, or one packet at a time in a dispatched
subagent, **decided by backlog size in §0**. Its safety rests on the layers below
it, whichever mode runs — the autonomy-aware
commit gate in `hooks/guard.sh`, per-packet `orch/<task-id>` feature branches in
the single local checkout, and the durable checkpoint in
`.agents/run-state.yaml` — so honor them, do not route around them. See
[ADR 0004](../../docs/adr/0004-graduated-autonomy-and-pausable-loop.md),
[ADR 0009](../../docs/adr/0009-single-directory-feature-branch-workflow.md), and
[ADR 0012](../../docs/adr/0012-delegated-loop-driver.md).

## Parallel or sequential — the `--parallel` flag

**If `$ARGUMENTS` contains `--parallel`, `Read`
`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/parallel.md` and follow it instead — ignore
§0–§4 here.** (Parallel mode is split into its own file so this common sequential path
never loads it.) Parallel mode runs the maximum number of dependency-independent
packets at once, each isolated in its own git worktree lane; it requires a packet
dependency graph and reintroduces worktrees for isolation — **opt-in and never the
default**. Otherwise run the sequential loop below (§0 decides relay vs inline).

## 0. Relay or inline — decided by backlog size (ADR 0012)

**Decide this first, before touching the repo, and say which you chose.** The loop
runs two ways and the choice is measured, not stylistic:

- **Inline** — you run §1–§4 yourself. Cheaper per packet, but your context grows
  ~6.7k/packet and hits a forced, lossy compaction around packet **~28**.
- **Relay** — you dispatch a fresh Chief Engineer per packet and relay its
  check-in. Your context stays ~6 lines/packet forever, at a flat ~40.7k/packet.

Pick, in this order:

1. **`--inline` or `--relay` in `$ARGUMENTS` wins.** (`--inline` also covers
   debugging the loop itself, or a harness without subagent nesting.)
2. **Otherwise count the backlog** — `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh
   summary .agents/run-state.yaml` (pending + the cursor), else the node count from
   `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh nodes-all`:
   - **< 20 packets → INLINE.** Below the measured crossover the relay costs ~29%
     more tokens and ~40% more wall clock and buys nothing: the context never gets
     near the window.
   - **≥ 20 packets → RELAY.** Past the crossover the relay is *both* cheaper
     (~27% at 33 packets, ~50% at 52) and the only mode that finishes without
     compaction. Real backlogs reach this often — 33 and 52 packets observed.
3. **State the mode and the packet count in one line** before you start, so the
   human can override with the flag.

**If inline: stop reading §0 and run §1–§4 yourself.** The rest of §0 is the relay
contract.

### The relay contract

Per packet, do exactly this:

1. **Read the run's shape from disk, not from the repo:**
   `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh summary .agents/run-state.yaml`
   (skip if there is no run-state yet — the first dispatch establishes it per §2).

   **Findings are an index, and the index is the only part that is free** (ADR 0022).
   `runstate.sh findings .agents/run-state.yaml` prints one line per finding. Put
   **only the lines relevant to this packet** in the brief, and pass the `file:` path
   so the coordinator can open the body **if it decides it needs it**. Do not paste
   finding bodies into the brief, and do not tell it to read them all — that
   reconstructs the 41k-token run-state this design removed, in a different file.
   Conversely, never drop the index: a finding nobody sees causes the rework it
   existed to prevent, which costs more than reading it would have.
2. **Dispatch a fresh `gaffer:chief-engineer`** with a brief containing
   **only**: the repo root, the resolved autonomy level, the run-state path, the
   cursor packet id, and this instruction —
   > Read `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` and follow §1–§3 for
   > **exactly one packet** (the one at `backlog.cursor`), then stop. Return
   > **only** the check-in from `${CLAUDE_PLUGIN_ROOT}/templates/check-in.md` —
   > no transcript, no diff, no commentary.

   **Give it the skill's file path, as above — it has no `Skill` tool** and cannot
   invoke `/gaffer:run-loop`; without the path it will improvise the loop
   from memory (ADR 0012, finding 4). Do **not** pour this session's conversation
   into the brief: run-state and the packet are the context it needs.

   **Name the governing documents; do not let it go looking.** Add to the brief the
   specific ADR ids and the single `gspec/tasks/<slug>.md` this packet is governed by,
   and say that reading beyond them is out of scope for the packet. Unscoped, a fresh
   coordinator sweeps the whole corpus — measured at ~111k tokens (17 ADRs ≈ 48k,
   7 task plans ≈ 30k, gspec core ≈ 22k) for a packet that governs about one of each.
   That payload is not read once: it becomes the standing context re-cached on every
   large turn, which is why coordinator `cc_shape.max` reads 148k–240k on runs that
   skip this and 24k on one that did not.

   Where a document is genuinely large and only one section applies, say so — a
   bounded `Read` (`offset`/`limit`) is the intended tool. Across 30 sessions the top
   **10%** of `Read` calls carried **50%** of all read volume, and `Read` totalled
   **7.6x** every shell search combined; whole-file reads of long ADRs are that tail.
3. **Relay the returned check-in verbatim.** Do not summarize it, re-derive it,
   comment on it, or verify it by reading the repo yourself — that is how this
   context refills.
4. **Decide from disk, not from the transcript:** re-read `status` and
   `backlog.cursor` (`runstate.sh get`). Then:
   - `status: running` and **cursor advanced** → dispatch the next packet (§0, relay contract step 2).
   - `status: paused` / `blocked` / `done` → relay the final check-in and **stop**.
   - **cursor unchanged** → the packet did not land. **Stop and report** — never
     re-dispatch the same cursor. A dispatch loop that never advances burns tokens
     and looks like progress.
5. **A blocking question is the human's.** Surface it and wait. Do not answer it
   on their behalf; carry their answer into the next brief.

Everything below §0 is written for **whoever executes the loop** — you, at
`--inline`/small backlogs, or the dispatched Chief Engineer under the relay.

## 1. Preflight (stop here if unmet)

- **gspec contract + interlock (ADR 0020).** If the repo has a `gspec/` directory,
  run `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh check` and
  `… interlock`. A `CHECK=fail` means the specs are a gspec version this plugin
  does not support — **stop and say so** (the remedy is `/gspec-migrate`, or
  raising the pin); do not read the backlog anyway. An `INTERLOCK=busy` means a
  `gspec build` is driving this repo right now — **stop**: two drivers fanning
  implementers into one checkout will collide. Both are no-ops when there is no
  gspec project — gspec is optional (ADR 0020 D4).
- **Autonomy level.** Resolve it (env `ORCH_AUTONOMY` > `.agents/autonomy` >
  `interactive`, clamped by `autonomy_ceiling`). The loop is meant for
  **`supervised`**, **`autonomous`**, or **`full-autonomy`**. At **`interactive`** it
  cannot commit unattended — either say so and stop, or run a single packet and halt
  at the commit for human approval. `autonomous` and `full-autonomy` drive *across*
  packets without checking in between green landings; **`full-autonomy`
  additionally integrates** (merge/rebase/push onto non-`main` branches — see step
  3.4).
- **Branch.** Never run on `main`/`master`. Work happens on `orch/<task-id>`
  feature branches **in the single local checkout**; `git commit`/`merge`/`push` to
  a protected branch is denied by the guard at every level anyway. The integration
  base the loop branches from and (at `full-autonomy`) merges back into is the
  **non-`main`** `integration_branch` from `.agents/project-overrides.yaml`
  (default `develop`, else `main`/`master`).

## 2. Establish the backlog

- If **`.agents/run-state.yaml` exists**, you are resuming — follow
  `/gaffer:resume`: switch to the feature branch at `last_green_commit`,
  surface any `blocking` questions, and start from `backlog.cursor`.
- Otherwise build the backlog **through the adapter** — the single place this
  plugin reads gspec (ADR 0020 D2). Never parse `gspec/` yourself:
  - `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh next` picks the feature —
    lowest `order` among incomplete-and-unblocked, where **completion is derived**
    from the PRD's capability checkboxes and never stored. It prints `NEXT=<slug>`
    and the `PLAN=` file. With no `.agents/roadmap.yaml` it falls back to
    dependency-then-slug order and says so — the roadmap is an override, not a
    prerequisite.
  - `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh nodes <slug>` turns that
    feature's `gspec/tasks/<slug>.md` into packet nodes (one per **unchecked**
    task). Each node becomes one packet.
  - Or take `$ARGUMENTS` / an existing run-state backlog instead — gspec is one of
    three backlog sources, not a requirement.

  Then write an initial `.agents/run-state.yaml` from
  `${CLAUDE_PLUGIN_ROOT}/templates/run-state.yaml` (cursor = first packet, everything
  else pending). Write it atomically via
  `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh write .agents/run-state.yaml`.

**Mark the run live, and claim the driver.** Set `status: running`
(`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh set .agents/run-state.yaml status
running`) as soon as you begin driving, then
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh claim-driver .agents/run-state.yaml`.
`status: running` is the crash signal; the **driver claim** is what tells a crashed
run apart from *another session driving right now* (ADR 0020 D5) — without it a
second session reads `running` as a crash and starts driving too, breaking the
single-writer invariant parallel mode rests on. Keep the status truthful — only
`/gaffer:pause` (→ `paused`/`blocked`) and completion (→ `done`) clear it.
**Clear any stale pause sentinel** left by a prior run so it cannot immediately
re-halt this one: `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh clear-pause
.agents/pause` (ADR 0017).

## 3. Loop — for the packet at `backlog.cursor`

1. **Branch.** Create (or switch to) the packet's feature branch in the local
   checkout: `git switch -c orch/<task-id> <base>` — where `<base>` is the
   integration branch (`.agents/project-overrides.yaml` → `integration_branch`,
   else `develop`, else `main`/`master`). If `orch/<task-id>` already exists
   (resuming), just `git switch orch/<task-id>`. No worktree, no separate
   directory — all work happens here.
2. **Scope.** Fill a task packet from
   `${CLAUDE_PLUGIN_ROOT}/templates/task-packet.yaml` — narrow `allowed_files`,
   acceptance criteria, `forbidden`, build/test commands, and the packet
   `autonomy`. **Set `tier` here** — `mechanical` (fully-specified, one file),
   `integration` (multi-file/wiring, design settled), `design-heavy` (the design
   emerges while editing), or `docs` (prose only). This is the routing decision
   for the packet and it is **required**: it selects the agent in §3.3, and it is
   copied verbatim into the commit trailer in §3.4. Decide it now, while you have
   the packet in front of you — deciding it at commit time is how it ends up
   unset, and an unset tier makes the packet unmeasurable. `design-heavy` also
   requires a one-sentence `tier_reason`.
3. **Implement → test → review (fresh subagent per packet).** Dispatch a
   **fresh** `implementer` whose brief is built *only* from the packet (goal,
   `allowed_files`, `interfaces`, `acceptance_criteria`, `commands`, `method`) —
   do **not** pour this loop's accumulated context into it. Isolated context keeps
   it focused and keeps *your* coordinator context clean.
   **The packet's `tier` (§3.2) picks the agent, and the agent's frontmatter picks
   the model:** `mechanical`/`integration` → `implementer` (sonnet); `design-heavy`
   → `architect` for the design, then `implementer` for the code; `docs` →
   `doc-writer` (haiku). **Do not pass `model` at dispatch.** Every agent declares
   its own `model:` in frontmatter and a dispatch that omits `model` resolves to
   that frontmatter value — the frontmatter *is* the routing policy, so restating
   it per-call adds nothing and drifts. Pass `model` **only** to deliberately
   deviate from an agent's declared tier, and record why in `tier_reason`; such an
   override is an escalation and the audit surfaces it.
   **Dispatching is the default, not the optimization.** Implementing inline means
   the code is written in the opus coordinator context, which is the single most
   expensive place in the run to write it — it is legitimate only for a
   `design-heavy` packet where the design genuinely emerges as you edit, and it
   needs a `tier_reason`. Everything else gets dispatched.
   When `method: tdd`, the implementer writes the test first and **sees it fail**
   before writing implementation code. Testing method and standards are the
   project's to declare, not this plugin's — follow `gspec/practices.md` when it
   exists (ADR 0020 D7). Then run the packet's build+tests and **read the real
   output before claiming anything** — evidence, never "should pass"; a claim of
   green without the command output behind it is the failure this gate exists to
   catch. Then have the `reviewer` check the branch change set
   (`git diff <base>...HEAD`) against every acceptance criterion. Re-dispatch a
   scoped fix subagent for any Critical/Important finding and re-review before the
   gate.
4. **Decide (the soft/hard gate split):**
   - **Green and in policy** — build+tests pass, branch is not `main`/`master`,
     the diff touches **no** hard-gate path: **you commit on the branch.** You are
     responsible for having verified green build+tests first — the hook cannot.
     Put the write-ahead trailer `[orch packet:<cursor>]` on its own line in the
     commit message — this is what lets a resume *adopt* the commit if a crash
     lands between it and the run-state write below, instead of escalating (ADR
     0005). **Both routing trailers below are REQUIRED**, on their own lines (ADR
     0019 self-label) — a *factual* record of the decision, not a grade. A commit
     missing them makes the packet unmeasurable and the audit flags it as
     `unlabelled`:
     - `[orch tier:mechanical|integration|design-heavy|docs]` — **copy the packet's
       `tier` field verbatim** (§3.2). You are not re-deriving it here; the
       decision was already made at scope time. If the work turned out to be a
       different tier than you scoped, record what it *actually* was and say so in
       the check-in — a tier that changed mid-packet is a scoping signal worth
       seeing, not something to paper over.
     - `[orch impl:inline|delegated]` — `delegated` if you dispatched the
       `implementer` for the code, `inline` if you (the opus orchestrator) wrote
       it yourself.
     State what you actually did; the collector cross-checks the label against who
     really edited and what was dispatched (`metrics.sh` → `audit.*`), so an
     inaccurate label only makes the audit flag *you*. A `design-heavy`/`inline`
     packet is a legitimate opus edit; a `mechanical`/`inline` one is the leak this
     measures. Then update run-state **atomically** (`runstate.sh write`): append the
     packet to `done`, set `last_green_commit` to the new SHA, advance `cursor`,
     keep `status: running`. Emit a **status** check-in
     (`${CLAUDE_PLUGIN_ROOT}/templates/check-in.md`).

     Then close the packet out — both of these, every time:

     - **Attest the outcome:** `runstate.sh record-outcome <cursor> green`. Do this
       on **every** boundary, not just green ones — see the failure branches below.
     - **Keep `note:` to the CURRENT packet.** It is one line for the resuming
       session, not a log. Overwrite it; never append to what is there, and never
       add an "earlier history" section — the archive is
       `runstate.sh trim-note .agents/run-state.yaml`, which moves the overflow to
       `run-state-note-archive.md`. Left to accumulate it reached **164,678 chars —
       87% of the whole run-state, ~41k tokens, 15 stacked histories** — and a relay
       dispatch re-reads all of it to recover two facts ADR 0012 states plainly:
       did it land, what is next.
     - **Anything worth keeping past this packet is a FINDING, not note content**
       (ADR 0022): `runstate.sh add-finding .agents/run-state.yaml <id> "<one line>"`,
       then write the detail into the `.agents/findings/<id>.md` it creates. Route it
       first — this is the ADR 0020 seam and getting it wrong builds a shadow backlog:
       - **"this should be built/fixed"** → **not a finding.** That is backlog: a
         gspec task/feature, sequenced via `.agents/roadmap.yaml`.
       - **"this is a gotcha, a constraint, or a decision and why"** → a finding.
       A resolved question is a finding (the decision plus its rationale) — do **not**
       grow a `resolved_questions:` list in run-state; a real run grew one to 21,664
       chars precisely because there was nowhere else to put it.
   - **Hard gate touched, genuine ambiguity, conflicting specs, or still red
     after honest diagnosis** — do **not** force it: record a severity-tagged
     **blocking question** in `run-state.pending_questions`, then **pause** via
     `/gaffer:pause` (roll to the last green commit, discard non-checkpoint
     scratch, never leave the tree dirty) and **stop**. Emit the blocking-question
     check-in.

     **Attest this outcome too** — `runstate.sh record-outcome <cursor> blocked`
     (or `rolled-back` / `failed` / `abandoned`, whichever actually happened).
     This is the branch that makes the metric honest. A packet only becomes visible
     to the collector by way of its green-commit trailer, so work that failed or was
     rolled back leaves **no trace at all** and the run reads "42 of 42 green" —
     survivorship restated as quality, looking *better* the more work was thrown
     away. Recording it here is the only place the truth exists.
   - **Integrate (only at `full-autonomy`).** After the packet lands green on its
     `orch/<task-id>` branch, you may take the day-to-day integration steps the guard
     now delegates at this level: **merge** the branch into the **non-`main`**
     integration branch (`.agents/project-overrides.yaml` → `integration_branch`,
     else a non-`main` branch such as `develop`), **rebase** a branch to keep it
     current, and **push** feature/integration branches for CI. Never target `main`:
     a merge whose incoming diff hits a hard-gate path re-escalates, and
     merge-to-`main`/release/PR/deploy stay the human's gate (see below). At
     `supervised`/`autonomous` you stop at the green commit — leave integration to
     the human.
5. **Advance.** With no blocker, pull the next packet and repeat. Under
   `supervised`, check in (and optionally hand back) between packets; under
   `autonomous`/`full-autonomy`, continue automatically. **First check for a pause
   request** (below) — a granted pause takes effect here, at the packet boundary.

### Pause checkpoint (ADR 0017)

A human/frontend can request a graceful pause at any time by touching the
sentinel: `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh request-pause .agents/pause
"<reason>"`. You honor it **cooperatively at safe boundaries** — never mid-edit:

- **Poll at each packet boundary** (before pulling the next packet, and after a
  green landing): `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh pause-status
  .agents/pause`. If a `Read`/`Bash` tool advisory surfaces the request sooner
  (the `pause-check.sh` hook), treat it the same way.
- **Beat the driver heartbeat at the same boundary:**
  `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh heartbeat .agents/run-state.yaml`
  (ADR 0020 D5). A stale heartbeat is what lets the *next* session tell a crash
  from a live driver; the checkpoint you already stop at is the natural place for
  it, and a run that stops beating simply reads as crashed — which is correct.
- **On `PAUSE=1`:** finish the current packet to a green commit if it is already
  green and in policy (commit with the `[orch packet:<cursor>]` trailer); otherwise
  leave the last green commit untouched. Then hand to **`/gaffer:pause`**,
  which verifies the clean checkpoint, persists `status: paused`, clears the
  sentinel, and emits the check-in. **Stop.** Do not start the next packet.

## 4. Termination

- **Backlog complete** → before declaring done, dispatch **one broad whole-branch
  review** (opus) over the *integrated* diff — the whole feature vs its base
  (`git diff <base>...HEAD`, or the integration branch vs its base at
  `full-autonomy`). Per-packet reviews are scoped to one packet each and miss
  cross-packet integration issues; this final pass is the net for them. File any
  Critical/Important finding as a new packet (append to the backlog, cursor back)
  rather than shipping over it. Once the whole-branch review is clean, set
  `status: done` (`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh set
  .agents/run-state.yaml status done`) so a later session does not try to resume a
  finished run. Then **snapshot run-metrics (best-effort, ADR 0019):**
  `${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect || true` — assembles
  `.agents/metrics/<run-id>/run-metrics.json` from the run's event spine + commit
  trailers + transcripts. **Non-critical bookkeeping**: if it errors or `jq` is
  absent, ignore it — it must never affect termination. Then emit a final **status**
  check-in: all packets landed green, whole-branch review clean,
  `branch <orch/task-id>` is **ready for review** (optionally fold in a
  `metrics.sh show` one-liner). **Stop there.**
- **Blocked** → you are already paused with a blocking question; stop.

## Never, at any autonomy level

Commit/merge/**push to `main`/`master`** (or remote `main`), open a PR, run a
migration or schema change, install/upgrade dependencies, edit a sensitive/hard-gate
path, deploy, or rewrite history (`--amend`, interactive rebase, force-push,
`reset --hard`). **Merging to `main`, releasing, and opening a PR are the human's
hard gate at every level, including `full-autonomy`** — the loop stops at "ready for
the human to release" (a green commit on the feature branch at `supervised`/
`autonomous`; integrated onto the non-`main` integration branch at `full-autonomy`).
Every iteration is a green commit on a branch, so a crash or shutdown mid-loop
resumes cleanly from the last checkpoint.

At **`full-autonomy` only**, the merge/rebase/push onto **non-`main`** branches
described in step 3.4 are delegated — that is the *sole* addition; everything in the
paragraph above still stops for the human.
