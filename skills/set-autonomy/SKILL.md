---
name: set-autonomy
description: Show or set the orchestration autonomy level (interactive / supervised / autonomous / full-autonomy) by writing the consumer repo's .agents/autonomy file. This is the Desktop-native equivalent of launching with `ORCH_AUTONOMY=<level> claude` — use it to change how much the guided loop may do on its own from inside a running session (e.g. Claude Desktop), where you cannot prepend an env var. Use when the user asks to raise, lower, check, or change autonomy, or says the commit/merge/push gate blocked routine work.
argument-hint: interactive | supervised | autonomous | full-autonomy (omit to just show the current level)
---

# Set autonomy → $ARGUMENTS

Change (or report) the graduated-autonomy level for this repo without a terminal
or an env var, by writing **`.agents/autonomy`** in the consumer repo. This is
the in-session, Claude-Desktop-friendly equivalent of `ORCH_AUTONOMY=<level>
claude`. See [ADR 0004](../../docs/adr/0004-graduated-autonomy-and-pausable-loop.md).

The **Chief Engineer** runs this. It is a governance change, not a hard gate:
writing `.agents/autonomy` is permitted, but raising autonomy **never** relaxes a
hard gate (see the reminder in step 4). Do not cross any hard gate to perform it.

## 1. Resolve intent

Read `$ARGUMENTS` (trim/lowercase). Then:

- **Empty or `show`/`status`** → do not write anything. Skip to step 3 and just
  **report** the current state.
- **One of `interactive` / `supervised` / `autonomous` / `full-autonomy`** → that is
  the requested persistent level; continue to step 2.
- **Anything else** → do not write. Tell the user the only valid values are
  `interactive`, `supervised`, `autonomous`, `full-autonomy`, and report the current
  state (step 3).

Levels, lowest → highest privilege (from ADR 0004 / ADR 0006):

| Level | What it grants the loop |
| --- | --- |
| `interactive` | Human approves every mutation gate (most restrictive). |
| `supervised` | Chief Engineer auto-commits routine **green** work on a **feature branch**; checks in between packets. |
| `autonomous` | Same, and drives across the whole backlog without stopping between green landings. |
| `full-autonomy` | Same, **plus** merge/rebase/push onto **non-`main`** branches (integrate feature branches into the integration branch, push them for CI). `main`, releases, deploys, and the whole danger floor stay human. |

## 2. Write `.agents/autonomy` (only when a valid level was requested)

Find the consumer repo root (the current project directory). Write the file with
its explanatory header preserved, then the bare level on the last line, so the
guard's `resolve_autonomy()` reads it cleanly. `.agents/autonomy` is **not** a
sensitive path, so this write is allowed; if a consumer repo has marked it
sensitive in `guard-extra-paths` and the write is blocked, tell the user to edit
the one-word level themselves.

```bash
mkdir -p .agents
cat > .agents/autonomy <<'EOF'
# Default orchestration autonomy level for this repo (ADR 0004 / 0006 in the plugin).
# Resolution order: env ORCH_AUTONOMY  ->  this file  ->  plugin default (interactive),
# then clamped down to autonomy_ceiling in .agents/project-overrides.yaml if set.
#
#   interactive   — human approves every commit / mutation gate
#   supervised    — Chief Engineer auto-commits routine GREEN work on a feature
#                   branch and checks in between packets
#   autonomous    — CE drives across the backlog without stopping between landings
#   full-autonomy — same, plus merge/rebase/push onto NON-main branches (integrate
#                   feature branches, push for CI). main/releases/deploys stay human.
#
# Hard gates (commit/merge/push to MAIN, migrations, secrets, deploys, dependency
# installs, sensitive paths, history rewrite) always require a human, at EVERY level
# including full-autonomy. Set this in-session with
# `/gaffer:set-autonomy <level>`, or per single session with
# `ORCH_AUTONOMY=<level> claude` (env wins over this file).
<LEVEL>
EOF
```

Replace `<LEVEL>` with the requested value. Keep it the **last non-empty line**.

## 3. Compute the *effective* level (clamp to the ceiling)

The persistent file value is not necessarily what the guard enforces. Read any
`autonomy_ceiling:` from `.agents/project-overrides.yaml`; the **effective** level
is `min(rank(file level), rank(ceiling))`. Also note that a live env
`ORCH_AUTONOMY` (a terminal launch, or `.claude/settings.json` → `env`) **overrides
the file** for that session — if one is set, the file you just wrote will not take
effect until that override is removed.

```bash
grep -Ei '^[[:space:]]*autonomy_ceiling[[:space:]]*:' .agents/project-overrides.yaml 2>/dev/null || echo "(no ceiling — file value governs)"
```

## 4. Report clearly, then stop

State, concisely:

- **Persistent level now:** the value written to `.agents/autonomy` (or unchanged,
  if you only reported).
- **Ceiling:** the `autonomy_ceiling`, if any, and therefore the **effective**
  level the guard will enforce (call out any clamp explicitly — e.g. "wrote
  `autonomous`, but `autonomy_ceiling: supervised` clamps it to **supervised**").
- **Session override:** if `ORCH_AUTONOMY` is set in the environment, warn that it
  wins over the file this session.
- **Reminder (always):** hard gates — commit/merge/push to **main**/master (and
  remote main), DB migrations, secret/auth/money/sensitive-path edits, dependency
  installs, deploys, history rewrite — **always** require the human, at every level
  **including `full-autonomy`**. `supervised`/`autonomous` let the Chief Engineer
  auto-commit routine green work on a **feature branch**; `full-autonomy`
  additionally lets it merge/rebase/push onto **non-`main`** branches. Neither ever
  unlocks `main` or any hard gate.

Then stop. Do not resume or start a loop as a side effect — if the user wants to
run the backlog, that is a separate `/gaffer:run-loop`.
