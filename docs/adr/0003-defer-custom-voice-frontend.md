# ADR 0003 — Defer the custom voice layer; use Claude Desktop + Claude Dispatch as the frontend

- Status: Accepted
- Date: 2026-07-04
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0001](0001-phase2-scope-new-apps-first.md), [ADR 0002](0002-spec-driven-bootstrap-via-live-installers.md)

## Context

The roadmap's original **Phase 3 = "Voice control"**
was a **build** task: speech-to-text, spoken-command→orchestrator-action
translation, text-to-speech summaries, and confirmation/approval commands. It sat
early in the sequence because voice is the design's ergonomic north star — the
whole system exists to let the user drive development with minimal mouse and
keyboard (ergonomic/accessibility constraints).

Two things make building a bespoke voice stack now the wrong order:

1. **It answers an open question the hard way.** The design's own open question
   *"What voice stack provides the best reliability with the least friction?"*
   is best answered "use Anthropic's product surface," not "hand-roll an
   STT/TTS/command pipeline and maintain it."

2. **A frontend with no engine behind it is premature.** Phases 4–5 (worktree
   delegation, API specialists, graduated autonomy) are the execution muscle a
   voice frontend would drive. Building the steering wheel before the engine
   inverts the natural dependency order.

Meanwhile two mature product surfaces already cover the human-facing frontend:

- **Claude Desktop** — built-in dictation, so the bulk of interaction needs no
  keyboard/mouse.
- **Claude Dispatch** — task hand-off surface for firing orchestration work at
  Claude Code.

Using them keeps the orchestration layer a **pure, frontend-agnostic Claude Code
plugin** (agents, skills, guardrail, templates, chains), mirroring the
IDE-agnostic stance of Decision #1 and Design Principle 10 ("start simple; add
frameworks only when they solve a real bottleneck").

## Decision

1. **Defer the custom voice layer to the end of the roadmap** (now **Phase 6**,
   "Custom voice layer — deferred; contingent"). It is not dropped — it is
   parked behind an explicit trigger.

2. **Adopt Claude Desktop + Claude Dispatch as the primary frontend for now.**
   The framework stays frontend-agnostic; the human-facing surface is a swappable
   product, not something welded into the plugin.

3. **Reorder the remaining phases so the execution muscle comes next:**
   - Phase 3: Worktree-based delegation (was Phase 4)
   - Phase 4: API-backed specialists + graduated-autonomy revisit (was Phase 5)
   - Phase 5: Persistent control plane (was Phase 6)
   - Phase 6: Custom voice layer (was Phase 3, deferred)

   The graduated-autonomy revisit's cross-references move with it: it now targets
   Phase 4 and depends on Phase 3 worktree isolation.

4. **The confirmation/approval piece of the old Phase 3 is absorbed, not lost.**
   Approvals are handled by the product frontend's own approve/deny UX on top of
   the existing `guard.sh` hard gates; no bespoke confirmation-command layer is
   needed to keep risky actions gated.

## Consequences

- **Accepted gap:** Claude Desktop dictation is push-to-talk, not wake-word, so
  this covers "no keyboard/mouse for the bulk of interaction" but **not fully
  hands-free approval loops.** That specific gap is the trigger to revive Phase 6.
- **Trigger to build the custom voice layer (Phase 6):** hands-free approval
  loops (or continuous wake/command operation) become a real friction point that
  Claude Desktop + Claude Dispatch cannot close.
- The framework incurs **zero voice-stack maintenance** in the meantime and
  inherits whatever reliability/latency improvements the product surfaces ship.
- Roadmap ordering now matches the dependency reality: worktrees and specialists
  precede any frontend investment.
