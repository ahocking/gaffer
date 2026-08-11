# ADR 0017 — Graceful cooperative pause via a sentinel + advisory hook

- Status: Accepted
- Date: 2026-07-18
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md) (pausable loop),
  [ADR 0005](0005-crash-safe-resume.md) (crash reconcile / write-ahead trailer),
  [ADR 0009](0009-single-directory-feature-branch-workflow.md) (single checkout),
  [ADR 0012](0012-delegated-loop-driver.md) (relay driver),
  [ADR 0016](0016-parallel-worktree-lanes.md) (parallel worktree lanes).
- **Amends [ADR 0016](0016-parallel-worktree-lanes.md).** ADR 0016 could only pause
  *between* scheduler dispatches. This adds a way to request a pause *while lanes are
  in flight* and have them wrap up to a safe state on their own.

## Context

`/gaffer:pause` already brings a run to a clean, resumable rest — but only
when the driver holds control. Under the plugin's synchronous `Task` dispatch the
driver is **blocked** while a chief-engineer/implementer/lane runs, so:

- in **relay** mode the human cannot ask the in-flight packet to stop early;
- in **parallel** mode the scheduler cannot signal lanes it already dispatched;
- a genuinely **long-running** packet (a slow build/test) extends the wait with no
  way to say "wrap up at the earliest safe point."

Two hard facts constrain the design. **(1)** A synchronous subagent cannot be
preempted from outside — the parent is blocked and cannot run code until the child
returns; nothing can interrupt a single long Bash mid-execution. **(2)** The only
safe rest state is a **green commit** — a mid-edit tree is never resumable, and a
dispatched subagent's *conversation context* is unrecoverable by design (run-state +
git are the only durable memory, ADR 0009). So a pause must be **cooperative**
(agents stop at their own safe boundaries), not preemptive, and it must land on a
green commit or roll back to one — it can never "save" a half-finished edit.

## Decision

**Add a cooperative pause driven by a write-once sentinel file that busy agents poll
at safe boundaries, reinforced by a context-only advisory hook. No change to the
synchronous dispatch model.**

1. **The request is a sentinel; the outcome is run-state.** A pause is requested by
   touching `.agents/pause` (all-run) or `.agents/pause.<task-id>` (one lane) via
   `runstate.sh request-pause`. This is kept **separate from run-state** so a
   human/frontend setting it never contends with the driver's single-writer run-state
   (ADR 0016 #6). run-state still records only the *outcome* (`status: paused`),
   written by the driver/`pause` skill. No run-state schema change (stays v3).

2. **The sentinel is canonical in the main checkout and resolvable from any lane.**
   It lives in the *main* checkout's `.agents/`. A lane worktree finds it with
   `git rev-parse --git-common-dir` (a worktree's common git dir points at the main
   `.git`), so the same request reaches every lane with **zero env-propagation
   dependency**. The driver also passes the absolute path in each lane brief and may
   export `ORCH_PAUSE_FILE` as a fast-path.

3. **The guaranteed mechanism is the prompt-poll.** The loop, the chief-engineer, and
   the implementer poll `runstate.sh pause-status` at safe boundaries (before a
   packet; between implement/test/review/commit). On `PAUSE=1` they bring the current
   step to a green commit (with the `[orch packet:<id>]` trailer) or leave the last
   green commit and set aside scratch — **never mid-edit** — then stop.

4. **The hook is best-effort reinforcement, and safe by construction.**
   `hooks/pause-check.sh` (PreToolUse, alongside `guard.sh`) injects a context-only
   advisory when the sentinel exists. It emits **no `permissionDecision`** — only
   `additionalContext` — so it can never weaken the guard or a soft gate, and it
   cannot interrupt a running command; it fires between tool calls only.
   **Delivery to subagents is now VERIFIED (probe 2026-07-19); it stays advisory, not
   enforcement.** A probe run in a session that loaded the hooks at startup confirmed
   that PreToolUse `additionalContext` — the field this hook already uses — reaches a
   dispatched subagent's model: the hook fired *inside* the subagent (ground-truth log
   with `agent_id`/`agent_type` populated) and the subagent quoted the injected token
   verbatim. PostToolUse `additionalContext` delivers identically; PostToolUse
   `updatedToolOutput` fired but never surfaced to either model. This retires the
   earlier worry that the hook was on the wrong event/field — it is not; the previous
   "dead" behavior was purely the mid-session-load confounder (hooks bind at session
   start; a mid-session-added hook never fires). **But the advisory is heeded only as
   far as the agent chooses to.** A correctly-behaving agent treats injected
   tool-channel content as untrusted data (prompt-injection hygiene) — in the probe the
   generic subagents read the advisory and *declined* its embedded "stop" instruction.
   So the hook remains best-effort reinforcement: the prompt-poll (#3), whose result is
   a tool output the agent itself requested, is the authoritative channel, and
   **correctness must never depend on the hook.** Hard, agent-choice-proof enforcement
   would require a *coercive* channel — a PreToolUse `deny` gated on `agent_id`
   (subagent-only, to spare the orchestrator's own `clear-pause`) — which freezes the
   lane at a clean tool boundary for the driver's `reconcile-parallel` to clean up;
   deferred until a parallel run shows lanes overshooting poll checkpoints.

5. **Every lane reports status and stays resumable.** On a granted pause the scheduler
   (single writer) records each in-flight lane's packet status + `last_green_commit`
   and keeps its `lanes[]` entry, leaves green-but-unintegrated lane worktrees in
   place (they are "ahead" of base; `worktree.sh remove` refuses them anyway), then
   writes `status: paused` and **clears the sentinel**. Resume runs the existing
   `reconcile-parallel` per lane (`clean`/`adopt`/`discard`/`restart`/`escalate`),
   clears the sentinel, and re-enters the P1 scheduler. A lane killed mid-packet
   reconciles to `restart` — at most one packet's uncommitted work is lost, never a
   committed checkpoint (that is why packets are commit-sized).

6. **Sentinel lifecycle: cleared at run start, on pause completion, and on resume.**
   A stale request must never re-halt a fresh or resumed run.

7. **No grace timer.** Under synchronous dispatch the scheduler regains control only
   when a dispatched batch returns, so pause latency is bounded by the slowest
   in-flight packet — there is nothing to time out against and no way to hard-kill a
   lane from the driver. A grace/kill deadline is only meaningful under background
   dispatch (see Rejected), so none is added now.

## Consequences

- **Works identically in relay and parallel**, with no dispatch-model change and no
  new run-state schema. Pause latency = the slowest in-flight packet; each agent
  lands green or rolls back independently.
- **Safety is not weakened.** The advisory hook is context-only; all guard hard-deny
  floors, soft gates, and the crash-reconcile table are untouched and still bind.
- **A new tested core.** `runstate.sh request-pause`/`clear-pause`/`pause-status` and
  the worktree-resolving hook are unit-tested without a live agent
  (`scripts/test-pause.sh`, incl. resolution *from a lane worktree*), and the
  parallel-pause choreography — land-green-with-trailer / roll-back-clean / status
  writeback / `reconcile-parallel` resumability corners — is an end-to-end regression
  over the real `worktree.sh` + `runstate.sh` (`scripts/test-parallel-pause-e2e.sh`);
  CI runs both beside the guard/runstate/graph/worktree sweeps.
- **Hook delivery to subagents is CONFIRMED (probe 2026-07-19); it is still advisory,
  not enforcement.** A probe in a session that loaded the hooks at startup showed both
  PreToolUse and PostToolUse `additionalContext` reach a dispatched subagent's model
  (hook fired inside the subagent with `agent_id`/`agent_type` set — arriving as a
  `<system-reminder>` appended to the tool result — and the token was quoted back);
  PostToolUse `updatedToolOutput` fired but did not surface. The shipped
  `pause-check.sh` (PreToolUse `additionalContext`) therefore needs **no rebuild**. But
  agents correctly treat the injected advisory as untrusted data, so it does not
  *force* a stop — the prompt-poll remains authoritative and correctness never depends
  on the hook. Do not describe pause as "automatic via the hook." A coercive
  `permissionDecision: deny` gated on `agent_id` remains the only channel that would
  hard-stop a lane regardless of agent choice; it is deferred (the "No grace timer" /
  Rejected reasoning still holds under synchronous dispatch).

## Rejected for now — background-task dispatch (true preemption)

Running lanes as background tasks (or a Workflow) would keep the orchestrator live to
message mid-run and `TaskStop` a running process. Rejected for this iteration because
it: **(a)** risks the two-deep nesting the relay/parallel model needs (a background
task may not spawn its own); **(b)** forces the scheduler to poll, refilling exactly
the context ADR 0012 relay keeps flat; **(c)** adds no crash-safety (background tasks
die with the session — git reconcile is still the floor); and **(d)** adds task-id
bookkeeping and correlation failure modes. It is the *only* path to interrupting a
long-running command mid-execution — revisit it if drain-to-checkpoint latency proves
too coarse; until then the cooperative pause above is sufficient and far cheaper.
