#!/usr/bin/env bash
# =============================================================================
# session-start.sh — surface an in-flight guided run when a session (re)opens
# =============================================================================
# Wired as a SessionStart hook (see hooks/hooks.json), matcher `startup|resume`.
# When you reopen Claude Code after a crash / reboot / sleep / hard close, this
# notices a paused-or-crashed run on disk and injects it into the new session's
# context so the Chief Engineer immediately offers (or, under `autonomous`,
# runs) /gaffer:resume — instead of the run being forgotten until you remember
# to ask. See ADR 0005.
#
# thin-loop-driver T6 (ADR 0028): this matcher (`startup|resume`) is exactly
# the two SessionStart sources under which a reopened session KEEPS its own
# session_id (a fresh `/clear` mints a NEW one and never reaches this hook at
# all; `/compact` keeps the id too but is handled separately, by
# hooks/driver-mode-compact.sh, which re-injects the loop-driver instructions
# instead of clearing anything). So on every firing of THIS hook, clear this
# session's own driver-mode mark (`runstate.sh driver-mode exit`) — a
# reopened session's loop, if any, must re-enter driver mode rather than
# assume it is still in it.
#
# Contract (Claude Code hooks):
#   - stdin is a JSON envelope. We now read `session_id` from it (to know
#     WHICH session's mark to clear); everything else about the envelope is
#     still unparsed. The consumer repo root is $CLAUDE_PROJECT_DIR; fall back
#     to CWD.
#   - To add context we print ONE JSON object with hookSpecificOutput.additional
#     Context and exit 0. To stay silent we print nothing and exit 0.
#   - This hook is purely additive and MUST fail open: any error, no session_id,
#     no in-flight run, or a completed run -> exit 0 (clearing the mark, if a
#     session_id was readable, is attempted regardless, but its own failure is
#     swallowed too). It never blocks a session.
#
# This only PRODUCES context; delivery/action stays the session's job.
# =============================================================================

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RS="${PROJECT_DIR}/.agents/run-state.yaml"
RUNSTATE="${CLAUDE_PLUGIN_ROOT:-}/scripts/runstate.sh"

# --- extract "session_id" from the SessionStart JSON envelope ---------------
# Same dependency ladder as guard.sh's json_field: probe by EXECUTION, never
# `command -v` (a Windows python3 App Execution Alias stub is on PATH and
# exits 49 -- guard.sh's own finding). A session id carries no JSON-special
# characters in practice (an opaque token), so the regex fallback needs no
# escape decoding, unlike guard.sh's path-bearing fields.
#
# EVERY branch pipes its result through `tr -d '\r'` (ADR 0019 v3.1's own
# fix, applied here): a native Windows jq build opens stdout in TEXT mode, so
# jq's own output carries a trailing CRLF even on a pipe, and plain bash's
# `$(...)` strips only the trailing `\n` -- the `\r` survives into `sess`.
# `_rs_check_session_id` in runstate.sh then rejects the CR-suffixed id
# (correctly, since a bare CR is not `[A-Za-z0-9._-]`), and this hook's own
# `|| true` swallows that failure silently -- the mark is never cleared, and
# a mark that never clears blocks every later main-thread write via
# hooks/guard.sh. `tr` is a no-op on any host where the CR was never there.
_session_id_from_json() {
  local raw="$1"
  if printf '{"_p":"ok"}' | jq -er '._p' 2>/dev/null | grep -q '^ok$'; then
    printf '%s' "$raw" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r'
    return 0
  fi
  if printf '{"_p":"ok"}' | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["_p"])' 2>/dev/null | grep -q '^ok$'; then
    printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
v = d.get("session_id")
if isinstance(v, str):
    sys.stdout.write(v)
' 2>/dev/null | tr -d '\r'
    return 0
  fi
  printf '%s' "$raw" \
    | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n1 \
    | sed -E 's/^"session_id"[[:space:]]*:[[:space:]]*"//; s/"$//' \
    | tr -d '\r' \
    || true
}

# --- clear THIS session's own driver-mode mark, if one exists ---------------
# Best-effort: any failure here (no runstate.sh, no session_id, not a git
# repo, driver-mode never entered) is swallowed -- this hook's other job (the
# resume notice below) must never be blocked by it. `runstate.sh driver-mode`
# resolves the mark relative to the MAIN checkout it is run FROM (git-common-
# dir based, like every other run-directory path in this file), never from an
# explicit path argument -- so these calls must run with PROJECT_DIR as their
# cwd, not this hook script's own cwd (which the harness does not guarantee
# equals the consumer repo at all).
if [ -x "$RUNSTATE" ]; then
  sess="$(_session_id_from_json "$INPUT")"
  if [ -n "$sess" ]; then
    dm_state="$(cd "$PROJECT_DIR" 2>/dev/null && "$RUNSTATE" driver-mode status "$sess" 2>/dev/null || true)"
    case "$dm_state" in
      *DRIVER_MODE=on*) (cd "$PROJECT_DIR" 2>/dev/null && "$RUNSTATE" driver-mode exit "$sess" >/dev/null 2>&1) || true ;;
    esac
  fi
fi

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
