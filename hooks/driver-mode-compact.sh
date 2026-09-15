#!/usr/bin/env bash
# =============================================================================
# driver-mode-compact.sh — re-arm the loop driver after compaction
# =============================================================================
# Wired as a SessionStart hook (see hooks/hooks.json), matcher `compact` ONLY.
#
# thin-loop-driver T6 (ADR 0028, probe results 2/3): `/compact` fires
# SessionStart source=compact with the SAME session_id, so a driver-mode mark
# keyed by session_id survives it — but the model's own standing instructions
# do not, since compaction is a context reset. This hook's one job is to put
# them back: when THIS session has a driver-mode mark, print a context-only
# note telling the model to Read agents/loop-driver.md and continue as the
# driver; otherwise print nothing.
#
# `/clear` mints a BRAND-NEW session_id (ADR 0028 result 2), so it is a
# DIFFERENT session as far as the mark is concerned and this hook — registered
# on `compact` only — correctly never sees it in normal operation. The old
# session's mark is left orphaned under its old id: inert unless that old
# session is later resumed, at which point hooks/session-start.sh's own
# startup|resume clearing removes it. This hook never clears a mark itself —
# only hooks/session-start.sh (T6) and `runstate.sh driver-mode exit` do.
#
# Contract (Claude Code hooks): stdin is a JSON envelope; we read `session_id`
# from it. To add context we print ONE JSON object with
# hookSpecificOutput.additionalContext and exit 0; to stay silent we print
# nothing and exit 0. This hook never blocks: no permissionDecision, and it
# fails open on any error (missing runstate.sh, unreadable payload, no
# session_id, no mark) by printing nothing and exiting 0.
# =============================================================================

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RUNSTATE="${CLAUDE_PLUGIN_ROOT:-}/scripts/runstate.sh"
[ -x "$RUNSTATE" ] || exit 0

# --- extract "session_id" from the SessionStart JSON envelope ---------------
# Same dependency ladder as guard.sh's json_field and hooks/session-start.sh's
# own copy of this helper: probe by EXECUTION, never `command -v` (a Windows
# python3 App Execution Alias stub is on PATH and exits 49). A session id
# carries no JSON-special characters in practice, so the regex fallback needs
# no escape decoding.
#
# EVERY branch pipes its result through `tr -d '\r'` -- see
# hooks/session-start.sh's identical comment on its own copy of this helper:
# a native Windows jq build's stdout carries a trailing CRLF even on a pipe,
# plain bash's `$(...)` strips only the `\n`, and the surviving `\r` makes
# `_rs_check_session_id` reject the id -- silently, via this hook's own
# `|| true`, so a marked session's compaction note never re-fires.
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

sess="$(_session_id_from_json "$INPUT")"
[ -n "$sess" ] || exit 0

# See hooks/session-start.sh's own copy of this note: `runstate.sh
# driver-mode` resolves the mark relative to the cwd it runs FROM (git-
# common-dir based), so this must run with PROJECT_DIR as its cwd.
dm_state="$(cd "$PROJECT_DIR" 2>/dev/null && "$RUNSTATE" driver-mode status "$sess" 2>/dev/null || true)"
case "$dm_state" in
  *DRIVER_MODE=on*) ;;
  *) exit 0 ;;
esac

# CLAUDE_PLUGIN_ROOT is a real, already-resolved env var here -- inlining its
# value gives the model an absolute path to Read, rather than a literal
# `${CLAUDE_PLUGIN_ROOT}` string it cannot expand itself.
msg="Driver mode was active for this session before compaction. Read ${CLAUDE_PLUGIN_ROOT}/agents/loop-driver.md and continue following it as the loop driver."

# JSON-encode without a jq dependency (mirrors hooks/session-start.sh's own
# escaping): escape backslash, double-quote, and collapse newlines.
esc="${msg//\\/\\\\}"
esc="${esc//\"/\\\"}"
esc="${esc//$'\n'/\\n}"

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
exit 0
