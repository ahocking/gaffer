#!/usr/bin/env bash
# =============================================================================
# session-start.sh — surface an in-flight guided run when a session (re)opens
# =============================================================================
# Wired as a SessionStart hook (see hooks/hooks.json). When you reopen Claude
# Code after a crash / reboot / sleep / hard close, this notices a paused-or-
# crashed run on disk and injects it into the new session's context so the Chief
# Engineer immediately offers (or, under `autonomous`, runs) /gaffer:resume
# — instead of the run being forgotten until you remember to ask. See ADR 0005.
#
# Contract (Claude Code hooks):
#   - stdin is a JSON envelope; we do NOT need to parse it (no jq dependency).
#     The consumer repo root is provided as $CLAUDE_PROJECT_DIR; fall back to CWD.
#   - To add context we print ONE JSON object with hookSpecificOutput.additional
#     Context and exit 0. To stay silent we print nothing and exit 0.
#   - This hook is purely additive and MUST fail open: any error, or no in-flight
#     run, or a completed run -> exit 0 with no output. It never blocks a session.
#
# This only PRODUCES context; delivery/action stays the session's job.
# =============================================================================

set -uo pipefail

# Consume stdin so the writer never blocks on a full pipe; we read the repo root
# from the env instead of parsing the envelope (keeps this jq-free and robust).
cat >/dev/null 2>&1 || true

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RS="${PROJECT_DIR}/.agents/run-state.yaml"
RUNSTATE="${CLAUDE_PLUGIN_ROOT:-}/scripts/runstate.sh"

# Nothing to resume -> stay silent.
[ -f "$RS" ] || exit 0
[ -x "$RUNSTATE" ] || exit 0

status="$("$RUNSTATE" get "$RS" status 2>/dev/null || true)"
case "$status" in
  ""|done) exit 0 ;;               # no lifecycle / already complete -> silent
esac

summary="$("$RUNSTATE" summary "$RS" 2>/dev/null || true)"
[ -n "$summary" ] || exit 0

# Tailor the recommended action to how the previous session ended.
case "$status" in
  running)
    action="The previous session ended WITHOUT a clean pause (status=running), so treat this as a crash/reboot. Run /gaffer:resume: it will reconcile the working tree to last_green_commit (discard scratch, or adopt a torn-write orphan commit via scripts/runstate.sh reconcile) BEFORE continuing from the backlog cursor. Do not start unrelated work on top of this run first." ;;
  blocked)
    action="This run is paused on a BLOCKING question the human must answer. Surface the pending question(s) from .agents/run-state.yaml as a check-in and wait for the answer before resuming with /gaffer:resume." ;;
  paused|*)
    action="This run was paused cleanly. Resume it with /gaffer:resume, which switches to the feature branch at last_green_commit and continues from the backlog cursor." ;;
esac

context="Orchestration: ${summary}. ${action}"

# Emit as a JSON string without needing jq: escape backslash, double-quote, and
# newlines so arbitrary run-state text stays valid JSON.
esc="${context//\\/\\\\}"
esc="${esc//\"/\\\"}"
esc="${esc//$'\n'/\\n}"

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
exit 0
