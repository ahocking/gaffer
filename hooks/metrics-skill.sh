#!/usr/bin/env bash
# =============================================================================
# metrics-skill.sh — slash-command skill tracker (UserPromptSubmit, ADR 0019 v3)
# =============================================================================
# WHY THIS EXISTS. `metrics-log.sh` stamps a `skill` field only when the tool call
# IS the `Skill` tool, and `metrics.sh` carries that forward per (session, agent).
# That machinery was correct but nearly always fed nothing: the orchestration
# skills are invoked as SLASH COMMANDS (`/gaffer:run-loop`), which the
# harness expands into a prompt WITHOUT ever calling the `Skill` tool. Measured
# across two consumer repos: 3 `Skill` tool events in ~6,000 tool calls, so
# `by_skill` read `{"none": <everything>}` in 18 of 22 captured runs — the whole
# process dimension was dark while looking merely empty.
#
# This hook closes that gap at the only place the information exists: the raw user
# prompt. On UserPromptSubmit it looks for a leading `/<name>` or `/<plugin>:<name>`
# and records it as the session's current skill. `metrics-log.sh` then stamps every
# subsequent event with it.
#
# ATTRIBUTION SEMANTICS (deliberate, and stated in the packet's notes[]): the skill
# is STICKY — set on a slash command, never cleared. It therefore means "the most
# recent skill invoked in this session", which is an UPPER BOUND on that skill's
# spend: work done after the skill actually finished still counts toward it. That
# is the right failure direction here (the alternative, clearing on every plain
# prompt, would silently drop a whole `/run-loop` the moment the user nudged it
# mid-run — under-attribution that looks identical to the bug we just fixed).
# Read `by_skill` as "compute spent at or after this skill's invocation", not as a
# precise span, and prefer the packet table when you need exact boundaries.
#
# ADVISORY-SAFE, exactly like metrics-log.sh and pause-check.sh:
#   - prints NOTHING on stdout. This matters more here than elsewhere: a
#     UserPromptSubmit hook's stdout is INJECTED INTO THE MODEL'S CONTEXT, so any
#     stray output would be both a token cost and a prompt-injection surface in a
#     metrics collector that must never influence the run it measures;
#   - FAILS SILENT (no jq, no git, unwritable dir, malformed payload);
#   - exit is ALWAYS 0.
#
# PRIVACY: records the skill NAME only — never the prompt text or its arguments.
# =============================================================================

set -uo pipefail

input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

# --- resolve the events dir the same way metrics-log.sh does -----------------
if [ -n "${ORCH_METRICS_DIR:-}" ]; then
  evdir="$ORCH_METRICS_DIR"
else
  gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gcd" ] || gcd="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd || true)"
  [ -n "$gcd" ] || exit 0
  evdir="$(dirname "$gcd")/.agents/metrics/events"
fi

sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] || exit 0
prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)"
[ -n "$prompt" ] || exit 0

# Leading `/name` or `/plugin:name` on the FIRST line only — a slash mid-prompt is
# prose or a path, not an invocation. Args after the name are ignored (privacy).
skill="$(printf '%s' "$prompt" | awk '
  NR==1 {
    if (match($0, /^[[:space:]]*\/[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?/)) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^[[:space:]]*\//, "", s)
      print substr(s, 1, 64)
    }
    exit
  }' 2>/dev/null)"
[ -n "$skill" ] || exit 0

mkdir -p "${evdir}/_state" 2>/dev/null || exit 0
printf '%s\n' "$skill" > "${evdir}/_state/${sid}.skill" 2>/dev/null || true
exit 0
