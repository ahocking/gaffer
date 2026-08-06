#!/usr/bin/env bash
# =============================================================================
# pause-check.sh — cooperative-pause advisory (PreToolUse hook, ADR 0017)
# =============================================================================
# Runs before every Bash / Edit / Write tool call, in the main session AND inside
# every dispatched lane (the guard already proves PreToolUse fires inside lane
# worktrees — ADR 0016 #8). If a pause SENTINEL exists, it injects an advisory
# telling the agent to land at a green checkpoint and stop. It NEVER blocks and
# NEVER emits a permissionDecision, so it cannot weaken guard.sh or any soft gate:
# its only effect is to add context. Exit is always 0.
#
# BEST-EFFORT, by design. The GUARANTEED pause is the prompt-poll checkpoint the
# skills/agents run (`runstate.sh pause-status …`); this hook is reinforcement.
# Delivery to subagents is VERIFIED (probe 2026-07-19, ADR 0017): in a session that
# loaded the hooks at startup, this PreToolUse `additionalContext` reached a dispatched
# subagent's model (hook fired inside the subagent — ground-truth log with agent_id —
# and the injected token was quoted back). The earlier "dead" reading was purely the
# mid-session-load confounder, NOT a wrong event/field. BUT a correct agent treats the
# injected advisory as untrusted data (prompt-injection hygiene) and may decline it, so
# this hook cannot FORCE a stop — it only reinforces. The prompt-poll is authoritative;
# correctness must NEVER depend on this hook. Kept because it is zero-cost when no
# sentinel exists and safe by construction (no permissionDecision, cannot weaken guard).
# It CANNOT interrupt a single long-running command — only the boundary between
# tool calls — so a pause is seen at the next checkpoint, never mid-process.
#
# Sentinel resolution (works uniformly from the main checkout and any lane):
#   1. $ORCH_PAUSE_FILE if the driver exported it (fast-path, no git).
#   2. else <main-checkout>/.agents/pause, where <main-checkout> is derived from
#      `git rev-parse --git-common-dir` — a lane worktree's common git dir points
#      at the MAIN repo's .git, so the canonical sentinel is found without any env.
# Scope: an all-run sentinel (<base>) OR this lane's own (<base>.<task-id>, where
# <task-id> comes from the orch/<task-id> branch).
# =============================================================================

set -uo pipefail

cat >/dev/null 2>&1 || true   # drain the tool envelope on stdin; we don't need it

# --- resolve the pause sentinel base path ------------------------------------
base="${ORCH_PAUSE_FILE:-}"
if [ -z "$base" ]; then
  gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  # older git without --path-format: resolve the common dir to an absolute path.
  [ -n "$gcd" ] || gcd="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd || true)"
  [ -n "$gcd" ] || exit 0                       # not in a git repo -> nothing to do
  main_root="$(dirname "$gcd")"                 # <main>/.git -> <main>
  base="${main_root}/.agents/pause"
fi

# --- this lane's task id, if we are on an orch/<task-id> branch ---------------
id=""
br="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
case "$br" in orch/*) id="${br#orch/}" ;; esac

# --- is a pause requested (all-scope wins over lane-scope)? -------------------
scope=""; reason=""
if [ -f "$base" ]; then
  scope="the whole run"
  reason="$(grep -E '^reason:' "$base" 2>/dev/null | head -1 | sed -E 's/^reason:[[:space:]]*//')"
elif [ -n "$id" ] && [ -f "${base}.${id}" ]; then
  scope="this lane (${id})"
  reason="$(grep -E '^reason:' "${base}.${id}" 2>/dev/null | head -1 | sed -E 's/^reason:[[:space:]]*//')"
else
  exit 0                                        # no pause requested -> silent allow
fi

# --- emit a context-only advisory (no permissionDecision) --------------------
msg="ORCHESTRATION PAUSE REQUESTED for ${scope}"
[ -n "$reason" ] && msg="${msg} (reason: ${reason})"
msg="${msg}. Bring the current step to a SAFE rest at the earliest opportunity: finish it to a green commit with the [orch packet:<id>] trailer if you can, otherwise leave the last green commit untouched and set aside uncommitted scratch — never stop mid-edit. Then write your check-in noting the pause and STOP; do not start new work."

# JSON-encode the message (jq -> python3 -> minimal fallback), mirroring guard.sh.
json_string() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then printf '%s' "$s" | jq -Rs . && return 0; fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$s" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' && return 0
  fi
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; printf '"%s"' "$s"
}

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' \
  "$(json_string "$msg")"
exit 0
