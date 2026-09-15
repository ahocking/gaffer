# ADR 0028 — Loop driver mode: what the harness actually carries (probe results)

- Status: Accepted (probe record; the design decisions it feeds land with `thin-loop-driver` T3–T24)
- Date: 2026-09-15
- Deciders: user (tech lead), orchestration plugin
- Relates to: `gspec/features/thin-loop-driver/prd.md` and its plan T1;
  [ADR 0017](0017-graceful-cooperative-pause.md) (the earlier payload probe that established
  `agent_id` inside subagents); [ADR 0019](0019-run-metrics-observability.md) (metrics
  attribute roles by `agent_type`, which this probe shows is not a main-thread test).

## Context

Driver mode rests on four harness facts nobody had checked, and the plan forbids taking
them from documentation:

1. Can a hook tell a session's main thread from its subagents, including in a session
   launched with `claude --agent`?
2. Does `session_id` survive compaction, `/clear` and `claude --resume`, and which
   SessionStart `source` does each fire?
3. Does a per-repo auto-compaction threshold exist, in what unit, and can a running
   session read the value in effect?
4. Can a session read its own effort level?

## Method

A scratch hook (`scratch/log-payload.sh`, gitignored, now removed) was registered in
`.claude/settings.local.json` on `PreToolUse` (matcher `.*`) and `SessionStart`
(`startup|resume|clear|compact`). It appended each raw payload as one line and printed
nothing. Four fresh sessions were run by the operator with effort set to `high`:

- **A** plain: a Bash call, `/compact`, a Bash call, `/clear`, a prompt.
- **B** `claude --resume` of A's post-clear session, a prompt.
- **C** `claude --agent probe-agent` (a throwaway `model: inherit` user agent): a Bash
  call, then a dispatched general-purpose subagent running Bash.
- **D** `/context` three times: plain; with `CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000`
  (plus a Bash `echo` of it); with `"autoCompactWindow": 100000` in
  `.claude/settings.local.json`.

19 payloads were logged. Session transcripts supplied the `/context` output and the
command results. The raw log stays local and uncommitted.

## Results

### 1. Main thread vs subagent: the discriminator is `agent_id`, and only `agent_id`

- A plain session's main-thread PreToolUse payload carries `session_id` and **no**
  `agent_id` and no `agent_type` (A, D).
- A session launched with `claude --agent probe-agent` carries **`agent_type:
  "probe-agent"` on its main thread, still with no `agent_id`**. The Bash call and the
  `Agent` dispatch both show it, and so does its `SessionStart startup` payload (C).
- A dispatched subagent's calls carry `agent_id` and `agent_type` (C: general-purpose,
  including its `SubagentHandback` call).
- Harness-spawned agents the operator never dispatched, with no transcript on disk, also
  carry `agent_id`. One in A had no `agent_type`, and two in C had `agent_type:
  "probe-agent"`, inherited from the launch. The guard treats them as subagents, which
  the PRD allows.

**The PRD assumption holds** ("hooks carry an agent id only inside subagents"), so the plan
continues. **`agent_type` is NOT a main-thread test.** Anything that treats "has
`agent_type`" as "is a subagent" misreads a `--agent` main thread: the guard (T5), the
metrics main-thread counts (T20, T21), and the existing role attribution in
`metrics-log.sh`, which will file a `claude --agent gaffer:loop-driver` main thread under
the role `loop-driver`.

### 2. Session identity: compaction and resume keep it; `/clear` does not

- `/compact` fires `SessionStart source=compact` with the **same** `session_id`, and
  carries `model`.
- `/clear` fires `SessionStart source=clear` with a **new** `session_id`. The payload
  names no previous id and carries no `model`.
- `claude --resume` fires `SessionStart source=resume` with the resumed session's **own**
  id (B; this planning session's own resume showed the same). It also carries
  `context_tokens`, `prompt_cache_likely_expired`, `seconds_since_last_response` and
  `estimated_cache_write_usd`, and no `model`.

**Consequences.**
- A driver-mode mark keyed by `session_id` survives compaction, which the PRD requires.
- A reopened session can clear its own mark on `resume`, as T6 plans.
- `/clear` mid-run ends driver mode for the new session with no stop report and orphans
  the old mark. The orphan is inert, because it is keyed to an id nothing will use again
  unless that session is resumed, in which case `resume` clears it. The PRD does not
  require surviving `/clear`, and the `clear` payload offers nothing to link the two
  sessions, so T6 registers its compact hook on **`compact` only** and does not guess.

### 3. Auto-compaction threshold: exists per repo, in tokens

- The default on Opus 5 (1M) read `Auto-compact window: 1m tokens`.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000` read `100k tokens` (`59.2k/100k`), and a Bash
  call in that session printed `100000`, so the variable is visible to tools.
- `"autoCompactWindow": 100000` in `.claude/settings.local.json` read `100k tokens`. That
  is a **per-repo setting**, and the unit is **tokens**.
- The `Autocompact buffer` stayed 33k in absolute terms either way.

**Not probed, and left to T4 to probe before relying on it:**
- precedence when both the variable and a settings key are set;
- the user and committed-project (`.claude/settings.json`) scopes;
- whether a **plugin** can supply a default without overriding a repo or operator value;
- whether a session can read a settings-file value in effect other than by reading the
  settings files. No hook payload carries the window.

The PRD's "the auto-compaction threshold can be set per repo" is achievable. "gaffer's
default" has no verified carrier yet.

### 4. Effort: readable from PreToolUse payloads, not SessionStart

- Every PreToolUse payload, main thread and subagent alike, carries `effort: {"level":
  "high"}`.
- SessionStart payloads carry no effort.
- `model` appears on SessionStart `startup` and `compact` only, and on no PreToolUse
  payload.
- PostToolUse was not registered in this probe, so whether it carries `effort` is
  unverified.

The model cannot read a hook payload itself, so the kickoff's effort must come from a
value a PreToolUse hook records for the session. With one, "effort unknown" is the
fallback, not the norm.

## Consequences for the plan

- **T3/T16:** `driver-mode enter --effort` reads a hook-recorded PreToolUse `effort.level`
  for the session, and falls back to `unknown` only when none has been recorded. `--model`
  comes from SessionStart `startup`/`compact` or the transcript.
- **T5:** refuse only when `agent_id` is absent. Never branch on `agent_type`.
- **T6:** the compact hook matches `compact` only (result 2).
- **T4:** the per-repo carrier is verified (`autoCompactWindow`, tokens). Probe precedence
  and a non-overriding plugin default first, and report `unknown` rather than invent one.
- **T20/T21:** main-thread means no `agent_id`. A `--agent` main thread must not be counted
  as a subagent role.
