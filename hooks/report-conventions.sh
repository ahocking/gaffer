#!/usr/bin/env bash
# =============================================================================
# report-conventions.sh — deliver the report format contract to every session
# =============================================================================
# Wired as a SessionStart hook (see hooks/hooks.json). It injects
# `templates/report-conventions-card.md` into the session's context so reports
# come out in the house format WITHOUT the human having to say so each session.
#
# WHY THIS EXISTS. The plugin's report contract lived only in
# `templates/report-templates.md`, referenced BY PATH from the skills. Two gaps
# followed: a skill that names a path but never `Read`s it delivers nothing, and
# a turn outside a skill was never told about the contract at all (a plugin's own
# root CLAUDE.md does not propagate to consumer repos). Result: free prose unless
# the human re-stated the format every session. The fix is three layers —
#   L1  the skills now `Read` the contract at their first emission point
#   L2  /gaffer:new-project and /gaffer:migrate write the card into the repo's
#       own CLAUDE.md (the strongest channel: user-owned standing instruction)
#   L3  THIS hook, for repos that never re-run migrate — it upgrades with the
#       plugin, where a stamped CLAUDE.md does not.
#
# L2 AND L3 ARE MUTUALLY EXCLUSIVE, BY DESIGN. If the repo's CLAUDE.md already
# carries the `gaffer:report-conventions` marker, this hook stays SILENT: the
# card is already standing context and injecting it again would pay for it twice
# in every session, for nothing.
#
# IT IS ADVISORY, NOT ENFORCEMENT — same standing as hooks/pause-check.sh. Hook
# `additionalContext` reaches the model (verified for PreToolUse in the ADR 0017
# probe), but a correct agent treats injected context as untrusted DATA, not as
# instruction. That is precisely why L2 outranks it: a repo's own CLAUDE.md is
# the human's standing instruction and is obeyed as such. Never describe this
# hook as guaranteeing the format.
#
# Contract (Claude Code hooks):
#   - stdin is a JSON envelope; we do NOT parse it (no jq dependency — stock Git
#     Bash ships neither jq nor a real python3). The repo root comes from
#     $CLAUDE_PROJECT_DIR, falling back to CWD.
#   - To add context, print ONE JSON object with
#     hookSpecificOutput.additionalContext and exit 0. To stay silent, print
#     nothing and exit 0.
#   - Purely additive and MUST fail open: any error, a missing card, an existing
#     marker, or an explicit opt-out -> exit 0 with no output. It never blocks a
#     session and it carries no permissionDecision, so it can never weaken the
#     guard.
#
# Opt out per session with ORCH_REPORT_CONVENTIONS=off, or permanently by
# stamping the card into the repo's CLAUDE.md (which is the better answer).
#
# WHY THIS IS A SEPARATE hooks.json ENTRY from session-start.sh, rather than more
# lines inside it: the two want different matchers. Context is lost on `clear` and
# can be dropped by `compact`, so the card must re-fire on both. session-start.sh
# must NOT — it reads `status: running` as "the previous session died", so firing
# it after a mid-run compact would announce a crash that never happened and push
# a live run into reconcile. Same event, different triggers, so: two entries.
#
# This only PRODUCES context; delivery/action stays the session's job (ADR 0003).
# =============================================================================

set -uo pipefail

# Consume stdin so the writer never blocks on a full pipe.
cat >/dev/null 2>&1 || true

case "${ORCH_REPORT_CONVENTIONS:-}" in
  off|0|false) exit 0 ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
CARD="$HERE/../templates/report-conventions-card.md"
MARKER='gaffer:report-conventions'

[ -f "$CARD" ] || exit 0

# Already standing context via the repo's own CLAUDE.md -> nothing to add.
if [ -f "$PROJECT_DIR/CLAUDE.md" ] && grep -q "$MARKER" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
  exit 0
fi

# `tr -d '\r'` so a CRLF checkout cannot emit raw CRs into the JSON string.
body="$(tr -d '\r' < "$CARD" 2>/dev/null || true)"
[ -n "$body" ] || exit 0

context="The gaffer plugin's report conventions for this session follow. They govern every REPORT you give the human; ordinary conversational answers are not reports and are unaffected.

${body}"

# Emit as a JSON string without needing jq: escape backslash, double-quote, tab
# and newline. Order matters — backslash MUST be first or it re-escapes the rest.
esc="${context//\\/\\\\}"
esc="${esc//\"/\\\"}"
esc="${esc//$'\t'/\\t}"
esc="${esc//$'\n'/\\n}"

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
exit 0
