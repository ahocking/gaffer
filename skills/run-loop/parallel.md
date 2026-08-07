# run-loop — parallel worktree lanes (`--parallel`, ADR 0016)

> Parallel-mode extension of `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md`, split into
> its own file so the common **sequential** path never loads it (~1.9k tokens). The driver
> reaches this from SKILL.md's "Parallel or sequential" section when `$ARGUMENTS` contains
> `--parallel`. `§0`/`§1`/`§3`/`§4` references point at run-loop/SKILL.md — which the driver
> and each dispatched lane still read. Content below is unchanged from the former SKILL.md §P.

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
   the lane in run-state `lanes` with `status: running` (you are the single writer).
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
   - **green** → record its packet `status: done` + `last_green_commit` in run-state,
     then **integrate** (P2, `full-autonomy` only).
   - **blocking question / red / escalate** → surface it (the human's); that lane's
     packet stays unfinished. Keep the other lanes going.
   - **any lane's `Findings:` lines** → you record them, in the main checkout, one
     `runstate.sh add-finding .agents/run-state.yaml <id> "<line>"` per line, then
     write the detail into the `.agents/findings/<id>.md` each call creates. Do this
     as you collect each check-in, while you still hold the lane's context — a finding
     you postpone to the end of the wave is one you will summarize from memory.
     Prefix ids with the lane's task-id (`<task-id>-<n>`) so two lanes cannot collide
     on a name; `add-finding` refuses a duplicate id rather than merging into it.
5. **Recompute** the ready-set (step 1) and dispatch the next batch — newly-unblocked
   dependents appear once their deps are `done` (and, at `full-autonomy`, integrated).

### P2. Integrate green lanes — serialized (`full-autonomy` only)
Merge green lanes back **one at a time, never concurrently:** in the main checkout,
`git switch <integration_branch>` then `git merge --no-ff orch/<task-id>`. Concurrent
lanes are **file-disjoint by construction** (the graph's overlap edges), so these
merges do not textually conflict. After each, mark the packet `integrated: true` and
`worktree.sh remove <task-id>` (it refuses on unmerged work — a safety net). **A merge
that conflicts means the disjointness analysis missed a shared file: STOP, do not
auto-resolve** — resolving unreviewed conflicts is a hard gate (and the guard
hard-denies the `reset --hard`/`--force` escapes anyway). Pause and escalate, naming
the two packets and the file. Below `full-autonomy`, skip P2 and stop at "N green
`orch/*` branches ready for review."

### P3. Terminate / pause
- **DAG exhausted** (`full-autonomy`): after the last lane integrates, run **one broad
  whole-DAG review** over the integration branch vs its base (§4's net); file any
  Critical/Important finding as a new packet; then `status: done`, **snapshot
  run-metrics** (`${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect || true` — best-effort,
  ADR 0019; the parallel run is exactly where the packet is most worth having, since it
  captures every lane's per-agent spend and wave concurrency), and a final check-in.
  Below `full-autonomy`: stop at branches-ready with a check-in listing the branches.
- **Any hard gate, merge conflict, blocking question, or a granted pause (ADR 0017)**
  → pause at a safe multi-lane checkpoint. For **every lane that was in flight**,
  record its outcome so the whole run is resumable (you are the single writer):
  1. Leave each green lane at its committed tip; `worktree.sh discard` only a lane's
     throwaway *scratch* (never a committed green tip). **Leave the lane's worktree in
     place** — a green-but-unintegrated lane is "ahead" of base, so `worktree.sh
     remove` would (correctly) refuse it anyway; resume re-attaches it.
  2. Write each lane's packet `status` (`done` if it committed green and finished,
     else `pending`) and its `last_green_commit`, and keep the lane's `lanes[]` entry
     (branch + worktree path) — this is what `reconcile-parallel` reads on resume.
  3. Persist run-state `status: paused` (or `blocked`), then **clear the sentinel**
     (`runstate.sh clear-pause .agents/pause`) so resume starts clean. **Snapshot
     run-metrics** (`${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect || true` —
     best-effort, ADR 0019; never let it affect the pause). Emit the multi-lane
     check-in listing each lane's landing (green SHA or rolled-back), and stop.

### P4. Resume (`/gaffer:resume --parallel`)
Read run-state v3, run `runstate.sh reconcile-parallel .agents/run-state.yaml .`
(per-lane `clean`/`adopt`/`discard`/`restart`/`escalate` — apply each per its lane;
`escalate` is the human's), resurface blocking questions, **clear the pause sentinel**
(`runstate.sh clear-pause .agents/pause` — the earlier request is consumed), then
re-enter P1 from the surviving packet/lane state.
