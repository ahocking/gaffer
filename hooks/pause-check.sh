#!/usr/bin/env bash
# =============================================================================
# pause-check.sh — cooperative-pause advisory (PreToolUse hook, ADR 0017)
# =============================================================================
# Runs before every Bash / Edit / Write tool call, in the main session. If a
# pause SENTINEL exists, it injects an advisory telling the agent to land at a
# green checkpoint and stop. It NEVER blocks and NEVER emits a
# permissionDecision, so it cannot weaken guard.sh or any soft gate: its only
# effect is to add context. Exit is always 0.
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
# Sentinel resolution:
#   1. $ORCH_PAUSE_FILE if the driver exported it (fast-path, no git).
#   2. else <main-checkout>/.agents/pause, where <main-checkout> is derived from
#      `git rev-parse --git-common-dir`.
# Whole-run only (retire-unused-loop-modes T1 removed the per-lane sentinel that
# parallel mode used): there is exactly one sentinel path to check.
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

# --- is a pause requested? ----------------------------------------------------
# unwrap_yaml_scalar <value already stripped of its "reason:" prefix>
#   THE SAME decode rule as runstate.sh's _yaml_decode_value / rs_decode, in a
#   third expression (runstate-write-integrity-gaps T5). Deliberately a copy and
#   not a source of runstate.sh: this hook runs per tool call, must stay
#   self-contained and dependency-free, and sourcing a 4k-line script on every
#   Bash/Edit/Write call to strip two quote characters is the wrong trade.
#   `request-pause` now writes the reason as a single-quoted YAML scalar, so
#   without this the advisory below would read (reason: 'wrap up') -- quote
#   characters the human never typed, injected into every agent's context. The
#   three branches, in order:
#     '...'  strip the wrapping pair, un-double `''` back to `'` (what
#            request-pause writes today);
#     "..."  LEGACY, stripped verbatim with no escape processing, matching the
#            runstate.sh rule exactly;
#     bare   everything else UNCHANGED -- including every sentinel written by a
#            version of request-pause older than this one, which is the only
#            reason no consumer repo has to clear a pause before upgrading.
#   Pinned against drift by scripts/test-pause.sh, which drives this hook and
#   `pause-status` over the same hostile reasons and demands the same answer.
unwrap_yaml_scalar() {
  local body
  case "$1" in
    \'*\') body="${1#\'}"; body="${body%\'}"; printf '%s' "$body" | sed "s/''/'/g" ;;
    \"*\") body="${1#\"}"; body="${body%\"}"; printf '%s' "$body" ;;
    *)     printf '%s' "$1" ;;
  esac
}

reason=""
if [ -f "$base" ]; then
  reason="$(grep -E '^reason:' "$base" 2>/dev/null | head -1 | sed -E 's/^reason:[[:space:]]*//')"
  reason="$(unwrap_yaml_scalar "$reason")"
else
  exit 0                                        # no pause requested -> silent allow
fi

# --- emit a context-only advisory (no permissionDecision) --------------------
msg="ORCHESTRATION PAUSE REQUESTED for the whole run"
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
