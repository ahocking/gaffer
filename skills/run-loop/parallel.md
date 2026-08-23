# run-loop — parallel worktree lanes (`--parallel`, ADR 0016)

> Parallel-mode extension of `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md`, split into
> its own file so the common **sequential** path never loads it (~1.9k tokens). The driver
> reaches this from SKILL.md's "Parallel or sequential" section when `$ARGUMENTS` contains
> `--parallel`. `§0`/`§1`/`§3`/`§4` references point at run-loop/SKILL.md — which the driver
> and each dispatched lane still read. Content below is unchanged from the former SKILL.md §P.
>
> **You are the scheduler, so you write to the human** — SKILL.md's "report contract"
> section still binds you: `Read` `templates/report-conventions.md` and
> `templates/report-templates.md` once, before the kickoff below. Your **lanes** do not;
> they return the wire format and you render it.

## P. Parallel worktree lanes (`--parallel`, ADR 0016)

Runs the **maximum number of dependency-independent packets at once**, each isolated
in its own git worktree lane, then integrates green lanes back to the integration
branch. Worktrees exist ONLY in this mode (ADR 0009 stays the default). You are the
**scheduler**: the SINGLE writer of run-state; the lanes are stateless workers you
dispatch. All the safety layers still bind each lane — the guard, per-lane
`orch/<task-id>` branches, the durable checkpoint — so honor them, do not route around
them. Uses `${CLAUDE_PLUGIN_ROOT}/scripts/{packet-graph,worktree,runstate}.sh`.

### P0. Preconditions
- **Preflight** as in §1 (resolve autonomy; never run on `main`/`master`). Resolve
  `max_parallel` = `.agents/project-overrides.yaml` → `max_parallel_packets`
  (default **5**).
- **Wave-chaining needs `full-autonomy`.** A dependent packet's lane must be cut from
  the integration branch AFTER its dependencies are merged in — which needs
  auto-integration. So at `full-autonomy` run the whole DAG; **below `full-autonomy`,
  run only the first ready wave** (packets with no unfinished deps), yield their
  branches, and stop at "N branches ready for review" — never chain waves the human
  has not integrated.
- **Graph.** Ensure `.agents/packet-graph.yaml` is current for the scope; if not, run
  `/gaffer:build-packet-dependency-tree [<feature>]` first (as a dispatched
  subagent, `Read` its `SKILL.md` path — you have no `Skill` tool), then
  `packet-graph.sh validate .agents/packet-graph.yaml` (a cycle → stop and surface it).
- **Kickoff before the first wave.** Once the graph validates and autonomy resolves,
  emit shape C from `${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`. Parallel mode
  is where this matters most: the human is about to have `max_parallel` lanes running
  against their repo at once, so the plan states **how many waves and how wide**, and
  `Won't touch:` earns its place — file-disjointness is the invariant the whole mode
  rests on, and saying which areas the wave spans is how a human catches a lane
  aimed somewhere they did not expect. Below `full-autonomy`, say plainly that only
  the first wave runs.
- **Init run-state v3** (`mode: parallel`) from the template: every graph packet
  `status: pending`; set `max_parallel`, `graph`, `integration_branch`, empty `lanes`.
  Write atomically (`runstate.sh write`), then `status: running`, then **claim the
  driver**: `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh claim-driver
  .agents/run-state.yaml` (ADR 0020 D5). This matters MORE here than in sequential
  mode: you are the single writer of run-state and the lanes are stateless workers,
  and `status: running` alone cannot tell a crashed scheduler from a live one — so
  without the claim a second session reads your in-flight run as a crash and starts
  scheduling lanes beside yours, against the same worktrees. **Clear any stale
  pause sentinel** so a leftover request cannot halt the new run:
  `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh clear-pause .agents/pause` (ADR 0017).

### P1. Schedule — repeat until the DAG is exhausted or a gate halts
0. **Beat the driver heartbeat, then pause-check, before opening any new lanes.**
   `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh heartbeat .agents/run-state.yaml`
   (ADR 0020 D5) — a scheduling pass is the safe boundary here, exactly as a packet
   boundary is in sequential mode. A scheduler that stops beating reads as crashed,
   which is what you want. **Pause check (ADR 0017).** Poll
   `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh pause-status .agents/pause`. On
   `PAUSE=1`, **stop scheduling**: open no new lanes, let the lanes already in
   flight drain to their check-ins (they see the request via their own poll and the
   hook, and land green or roll back — see step 3), record each returned lane per
   step 4, then go to **P3 pause**. A pause is a run-wide gate here; a lane-scoped
   request (`.agents/pause.<task-id>`) instead just prevents *that* packet from being
   re-dispatched — surface it and skip that lane, keep the rest scheduling.
1. **Compute the ready-set from disk, not memory:**
   ```
   DONE=$(runstate.sh packets-by-status .agents/run-state.yaml done    | paste -sd, -)
   RUN=$( runstate.sh packets-by-status .agents/run-state.yaml running | paste -sd, -)
   packet-graph.sh ready .agents/packet-graph.yaml --max <max_parallel> --done "$DONE" --running "$RUN"
   ```
   `ready` returns only packets whose deps are all `done`, that do **not**
   file-overlap any running lane, greedily de-conflicted, capped to the free slots
   (`max_parallel − running`). (Below `full-autonomy`, take only the first wave.)
2. **Open a lane per ready packet:** `worktree.sh create <task-id>` (cut from the
   integration base — at `full-autonomy` it already carries integrated deps). Record
   the lane in run-state `lanes` with `status: running`, via `runstate.sh write`
   (a new `lanes[]` entry is nested, same reason as everywhere else in this
   file — `set` cannot reach it) — you are the single writer.
3. **Dispatch the lanes CONCURRENTLY** — a **fresh `gaffer:chief-engineer` per
   lane, all in ONE message (multiple `Task` calls) so they run in parallel.** Each
   brief contains ONLY: the repo root, the **lane's worktree path** (its working
   directory), the resolved autonomy **exported as `ORCH_AUTONOMY`** (the worktree has
   no `.agents/autonomy` — env is how the lane can commit), the packet id, the
   **absolute pause-sentinel path** (the *main* checkout's `.agents/pause` — the lane
   polls it to pause gracefully; ADR 0017), and:
   > Read `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` and run §3 for **exactly
   > this one packet, entirely inside the given worktree path** (implement → test →
   > review → commit on `orch/<task-id>` with the `[orch packet:<id>]` trailer), then
   > stop. Return **only** the check-in. Do **not** merge and do **not** touch
   > run-state — the scheduler owns both. That includes findings: if you learn
   > something worth keeping past this packet (a gotcha, a constraint, a decision and
   > why), do **not** run `add-finding` — put it in the check-in under **`Findings:`**,
   > one line each, and the scheduler will record it. Your worktree has no
   > `.agents/run-state.yaml` to append to, and two lanes appending at once is exactly
   > the contention the single-writer rule exists to prevent. **If a pause is
   > requested** (poll
   > `runstate.sh pause-status <pause-file> <task-id>`, or a tool advisory surfaces
   > it), bring this packet to a SAFE rest — commit green with the trailer if it is
   > green and in policy, else leave the last green commit and set aside scratch
   > (never mid-edit) — and return a check-in stating whether you landed green or
   > rolled back, and the resulting SHA.
4. **Collect check-ins; decide each lane from disk:**
   - **green** → record its packet `status: done` + `last_green_commit` in
     run-state **with `runstate.sh write`, carrying the whole `findings:` index
     through verbatim** — both fields are nested in `packets[]`, so
     `runstate.sh set` is the wrong tool here: `set` matches the top-level
     `status:`/`last_green_commit:` keys (anchored at column 0) and would
     overwrite the *run's own* status/checkpoint instead, not the packet's; and
     `write` REPLACES the whole file, so a write here that drops an entry
     silently unlinks whatever an earlier lane's `Findings:` line (below) just
     recorded, orphaning its body. Then **integrate** (P2, `full-autonomy`
     only).
   - **blocking question / red / escalate** → surface it (the human's); that lane's
     packet stays unfinished. Keep the other lanes going.
   - **any lane's `Findings:` lines** → you record them, in the main checkout, one
     `runstate.sh add-finding .agents/run-state.yaml <id> "<line>" --packets
     <id[,id...]>` per line. **`--packets` must name the packet(s) the finding
     actually constrains — never the reporting lane's own `<task-id>`**, for the
     same reason `SKILL.md` §3.4 gives: that packet just landed, so naming it
     makes the entry born stale before anything can act on it. `--packets` stays
     **mandatory** regardless (ADR 0024, there is no run-wide finding). Then
     write the detail into the `.agents/findings/<id>.md` each call creates if
     you also pass `--body`. Do this as you collect each check-in, while you
     still hold the lane's context — a finding you postpone to the end of the
     wave is one you will summarize from memory. Prefix ids with the lane's
     task-id (`<task-id>-<n>`) so two lanes cannot collide on a name;
     `add-finding` refuses a duplicate id rather than merging into it.
   Then **report the wave to the human as ONE check-in**, not N relayed lane reports:
   the human check-in shape in `${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`
   (shape A) is built for exactly this — one line per lane, marker first, every packet
   id carrying a plain-English title, and the lanes that need a decision visible
   without scrolling. A wave of five verbatim lane check-ins is five times the reading
   for the same three facts: what landed, what needs them, what is next. If any lane
   integrated this wave (P2 ran), fold in `${CLAUDE_PLUGIN_ROOT}/templates/check-in.md`'s
   `stale-findings:` line using the `STALE_COUNT`/`OVER_THRESHOLD` P2 captured — P2 runs
   once per green lane, so take the values from the **last** lane it integrated, which is
   the only pair describing the index after the whole wave's drops. Emit only when
   `OVER_THRESHOLD=yes`, `<N>` = `STALE_COUNT` (may legitimately be 0); omit it otherwise,
   same as when no lane integrated this wave and the scan never ran.
5. **Recompute** the ready-set (step 1) and dispatch the next batch — newly-unblocked
   dependents appear once their deps are `done` (and, at `full-autonomy`, integrated).

### P2. Integrate green lanes — serialized (`full-autonomy` only)
Merge green lanes back **one at a time, never concurrently:** in the main checkout,
`git switch <integration_branch>` then `git merge --no-ff orch/<task-id>`. Concurrent
lanes are **file-disjoint by construction** (the graph's overlap edges), so these
merges do not textually conflict.

**Flip the gspec checkbox here, not in the lane** — a feature's plan file sits
outside every packet's `allowed_files`, so flipping it inside a lane would make
two lanes sharing one feature's task file contend on the same write; the
scheduler, as the single writer, is the only safe place to do it. Right after
the merge, run `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh check-task
<task-id>` and act on its exit code the same way `SKILL.md` §3.4 does: on
`CHECKED=<ref>`/`already`, stage and commit the touched task file on
`<integration_branch>` — **with no `[orch packet:]` trailer on this commit**
(unlike §3.4's own flip, which is the packet's one and only commit). The lane's
trailer already reached `<integration_branch>` via the `merge --no-ff` above;
duplicating it onto this flip commit would give the collector two commits
carrying the same packet id, and it keeps the **latest** one — which has
neither `[orch tier:]` nor `[orch impl:]`, so the packet would read
`unlabelled:no-tier-trailer`/`unlabelled:no-impl-trailer` and its token
bucketing would shift to this commit instead. Same rule `resume/SKILL.md`
already follows for its own separate flip commit. Skip cleanly on
`CHECKED=none`, or note drift and carry on — never halt the merge over it — on
exit 4.

Then mark the packet `integrated: true` in run-state. That field is nested in
`packets[]`, and `runstate.sh set` only rewrites a flat top-level `key:` — so
this needs `runstate.sh write`, carrying the whole `findings:` index through
verbatim (same reason as §3.4's write: `write` REPLACES the file).

**Only after that write**, apply §3.4's capture-then-drop test to this lane's
findings, the same way and bounded the same way: entries naming `<task-id>`,
staleness read from evidence — `gspec-backlog.sh task-status` → its `FINISHED=`
fed verbatim to `findings --stale --finished`, unioned with `<task-id>` itself
(its own commit trailer, just landed, is the second admissible evidence source)
— never from `<task-id>`'s own say-so alone. §3.4 has the exact commands and
the reasoning; this is the same sequence run from the main checkout instead of
inside a lane. That same `findings --stale` call reports `STALE_COUNT`/
`OVER_THRESHOLD` for the whole index as a byproduct — hold onto them, they feed
the wave report's `stale-findings:` line (P1.4).

After each, `worktree.sh remove <task-id>` (it refuses on unmerged work — a
safety net). **A merge
that conflicts means the disjointness analysis missed a shared file: STOP, do not
auto-resolve** — resolving unreviewed conflicts is a hard gate (and the guard
hard-denies the `reset --hard`/`--force` escapes anyway). Pause and escalate, naming
the two packets and the file. Below `full-autonomy`, skip P2 and stop at "N green
`orch/*` branches ready for review."

### P3. Terminate / pause
- **DAG exhausted** (`full-autonomy`): after the last lane integrates, run **one broad
  whole-DAG review** over the integration branch vs its base (§4's net); route any
  Critical/Important finding by scope per §4 (ADR 0026); never edit the completed
  record. The **scheduler** does this routing — a lane reports the finding in its
  check-in and never writes to `gspec/` itself — and surfaces an arm-2 proposal (a new
  feature: slug, scope, parent) in the **stop report's decision block**, not the wire
  question block, because at P3 nothing downstream parses its output. Then `status:
  done`, **snapshot run-metrics** (`${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect ||
  true` — best-effort, ADR 0019; the parallel run is exactly where the packet is most
  worth having, since it captures every lane's per-agent spend and wave concurrency),
  and a final **stop report** (`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`,
  shape B). Below `full-autonomy`: stop at branches-ready, with the same stop report —
  each branch named by what it *does*, not just by its `orch/<task-id>`.
- **Any hard gate, merge conflict, blocking question, or a granted pause (ADR 0017)**
  → pause at a safe multi-lane checkpoint. For **every lane that was in flight**,
  record its outcome so the whole run is resumable (you are the single writer):
  1. Leave each green lane at its committed tip; `worktree.sh discard` only a lane's
     throwaway *scratch* (never a committed green tip). **Leave the lane's worktree in
     place** — a green-but-unintegrated lane is "ahead" of base, so `worktree.sh
     remove` would (correctly) refuse it anyway; resume re-attaches it.
  2. With `runstate.sh write` (both fields are nested in `packets[]`, same
     hazard as P1.2/P1.4/P2 above — `set` would overwrite the run's own
     top-level `status`/`last_green_commit` instead), set each lane's packet
     `status` (`done` if it committed green and finished, else `pending`) and
     its `last_green_commit`, and keep the lane's `lanes[]` entry (branch +
     worktree path) — this is what `reconcile-parallel` reads on resume.
  3. Persist run-state `status: paused` (or `blocked`), then **clear the sentinel**
     (`runstate.sh clear-pause .agents/pause`) so resume starts clean. **Snapshot
     run-metrics** (`${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect || true` —
     best-effort, ADR 0019; never let it affect the pause). Emit the **stop report**
     (`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, shape B) — every lane's
     landing (green SHA or rolled-back) as one line each under *Shipped* / *Not done*,
     the reason for the pause in the opening sentence, and whatever forced it written
     as an answerable decision. Then stop.

### P4. Resume (`/gaffer:resume --parallel`)
Read run-state v3, run `runstate.sh reconcile-parallel .agents/run-state.yaml .`
(per-lane `clean`/`adopt`/`discard`/`restart`/`escalate` — apply each per its lane;
`escalate` is the human's), resurface blocking questions, **clear the pause sentinel**
(`runstate.sh clear-pause .agents/pause` — the earlier request is consumed), then
re-enter P1 from the surviving packet/lane state.
