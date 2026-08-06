#!/usr/bin/env bash
# =============================================================================
# statusline-pause-sensor.sh — rate-limit-aware cooperative pause (ADR 0018)
# =============================================================================
# A normal Claude Code `statusLine` command: it reads the session JSON on stdin,
# PRINTS a one-line status to stdout (what the status line renders), and — as a
# SIDE EFFECT — arms the EXISTING ADR 0017 pause sentinel when EITHER rolling
# usage window (the 5-hour OR the 7-day/weekly limit) crosses its own threshold.
# From that write on, everything is ADR 0017, unchanged: the prompt-poll
# (`runstate.sh pause-status`) is the authoritative stop; this sensor only adds a
# CAUSE for the sentinel, none of its consequences.
#
# STATUS-LINE FACTS this design rests on (ADR 0018, all verified):
#   1. The rolling-usage percentages arrive in EXACTLY ONE place — this command's
#      stdin JSON, under `.rate_limits.{five_hour,seven_day}` — only AFTER the
#      first API response, only for Claude.ai Pro/Max (absent under API-key auth),
#      and refreshed only ONCE PER API RESPONSE. Each field (each window
#      independently) can be ABSENT, so every read is guarded with `// empty`.
#   2. No hook payload carries rate-limit data and nothing persists it to disk, so
#      the status line is the SOLE sensor. The actuator stays in ADR 0017.
#   3. This is a harness-invoked callback, not a daemon. There is no monitoring
#      process; this design adds none.
#
# BEST-EFFORT, never a guarantee — the same contract as the ADR 0017 hook. Both
# cutoffs are enforced SERVER-SIDE and cannot be overridden here; this only arms
# the cooperative pause EARLIER than a human would. Correctness must never depend
# on it. If it is disabled, the auth mode is API-key (no `rate_limits`), the
# account is not Pro/Max, or the cutoff simply outruns the drain, the run degrades
# to today's behavior: a lane hits the wall and reconcile `restart`s it, losing at
# most one packet's uncommitted work.
#
# Config (ADR 0018 #6) — resolved by THIS script, env fast-path first, then the
# repo's `.agents/project-overrides.yaml` `rate_limit_pause:` block, then default:
#   ORCH_RATE_PAUSE=off       -> disable BOTH window checks (default on)
#   ORCH_RATE_PAUSE_PCT       -> 5-hour threshold  (default 90)
#   ORCH_RATE_PAUSE_7D_PCT    -> 7-day  threshold  (default 85, lower on purpose:
#                                the weekly ceiling is slower-moving and far more
#                                costly to exhaust — days stranded, not hours).
# The status line is HARNESS-invoked, not launched by the loop driver, so nothing
# exports ORCH_RATE_PAUSE* into it — the YAML layer is the PRIMARY surface and is
# read directly here (ADR 0018 open question #1).
# =============================================================================

set -uo pipefail

# Resolve our sibling runstate.sh from THIS script's own location — NOT from
# ${CLAUDE_PLUGIN_ROOT}, which is NOT expanded in the statusLine command context
# (ADR 0018). The installed absolute path is what settings.json carries.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

input="$(cat)"                                   # the harness feeds session JSON on stdin

# --- read BOTH windows; each field is independently optional -> guard each -----
jq_get() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null || true; }
p5="$(jq_get '.rate_limits.five_hour.used_percentage')"
r5="$(jq_get '.rate_limits.five_hour.resets_at')"
p7="$(jq_get '.rate_limits.seven_day.used_percentage')"
r7="$(jq_get '.rate_limits.seven_day.resets_at')"

# No rate_limits at all (API-key auth, pre-first-response, or no jq): stay off the
# hot path entirely — render a bare label and exit before any git/config work.
[ -n "${p5}${p7}" ] || { printf 'orch\n'; exit 0; }

# --- resolve the main-checkout root (for both the sentinel and the config) -----
# A lane worktree's common git dir points at the MAIN repo's .git, so the canonical
# sentinel + project-overrides.yaml are found from any lane with zero env
# dependency (ADR 0017 #2). Mirror hooks/pause-check.sh exactly.
main_root=""
gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[ -n "$gcd" ] || gcd="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd || true)"
[ -n "$gcd" ] && main_root="$(dirname "$gcd")"
ovr="${main_root:+${main_root}/.agents/project-overrides.yaml}"

# --- read a scalar leaf under the `rate_limit_pause:` block of the overrides ----
# Same "no YAML dependency, grep/awk only" style as guard.sh (autonomy_ceiling)
# and worktree.sh (integration_branch), but scoped to the block so a leaf like
# `enabled:` can never be confused with an `enabled:` under some other key.
yaml_rlp() {   # $1 = leaf key
  [ -n "${ovr:-}" ] && [ -f "$ovr" ] || return 0
  awk -v key="$1" '
    $0 ~ /^rate_limit_pause:[[:space:]]*$/ { inb=1; next }
    inb && /^[^[:space:]#]/               { inb=0 }
    inb && $0 ~ ("^[[:space:]]+" key "[[:space:]]*:") {
      line=$0
      sub(/^[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*/, "", line)  # strip `  key:`
      sub(/[[:space:]]*#.*$/, "", line)                                     # strip trailing comment
      gsub(/["\047]/, "", line)                                             # strip quotes ("/'\'')
      gsub(/[[:space:]]+$/, "", line)                                       # strip trailing space
      print line; exit
    }
  ' "$ovr" 2>/dev/null || true
}

# --- resolve the three knobs: env -> project-overrides.yaml -> default ---------
enabled="on"
if [ -n "${ORCH_RATE_PAUSE:-}" ]; then
  [ "$ORCH_RATE_PAUSE" = off ] && enabled=off
else
  case "$(yaml_rlp enabled)" in false|no|off|0) enabled=off ;; esac
fi

t5="${ORCH_RATE_PAUSE_PCT:-}"
[ -n "$t5" ] || t5="$(yaml_rlp five_hour_threshold_pct)"
case "$t5" in ''|*[!0-9]*) t5=90 ;; esac       # junk/absent -> 5-hour default

t7="${ORCH_RATE_PAUSE_7D_PCT:-}"
[ -n "$t7" ] || t7="$(yaml_rlp seven_day_threshold_pct)"
case "$t7" in ''|*[!0-9]*) t7=85 ;; esac       # junk/absent -> 7-day default (lower)

# --- format an epoch as UTC, portably (ADR 0018 open question #3) --------------
# BSD/macOS: `date -u -r <epoch>`; GNU/coreutils: `date -u -d @<epoch>`. Try one,
# fall back to the other, then to "soon" if the field was absent/unparseable.
fmt_epoch() {   # $1 = epoch, $2 = strftime format
  [ -n "$1" ] || { printf 'soon'; return; }
  date -u -r "$1" +"$2" 2>/dev/null || date -u -d "@$1" +"$2" 2>/dev/null || printf 'soon'
}

# --- render the informational status line regardless of thresholds ------------
# Integer display; percentages may be fractional, so drop any `.frac`.
line="orch"
[ -n "$p5" ] && line="${line} 5h ${p5%.*}%"
[ -n "$p7" ] && line="${line} 7d ${p7%.*}%"

# --- decide: does EITHER window cross its own threshold? -----------------------
# Accumulate into ONE reason so a single sentinel write covers whichever tripped.
reason=""
if [ "$enabled" != off ]; then
  if [ -n "$p5" ] && [ "${p5%.*}" -ge "$t5" ] 2>/dev/null; then
    reason="5h-limit at ${p5%.*}% (resets $(fmt_epoch "$r5" '%H:%MZ'))"
  fi
  if [ -n "$p7" ] && [ "${p7%.*}" -ge "$t7" ] 2>/dev/null; then
    w="weekly-limit at ${p7%.*}% (resets $(fmt_epoch "$r7" '%a %H:%MZ'))"
    reason="${reason:+$reason + }$w"
  fi
fi

# --- arm the EXISTING ADR 0017 sentinel, ONCE, when either crossed ------------
# Resolve the sentinel exactly like hooks/pause-check.sh (env fast-path, else the
# main checkout). Idempotent: skip if it already exists, so we never rewrite the
# reason/timestamp on every subsequent API response, and never clobber a human- or
# frontend-requested pause. Reuse `runstate.sh request-pause` for the atomic write
# in the canonical format — don't hand-roll the sentinel.
if [ -n "$reason" ]; then
  pausefile="${ORCH_PAUSE_FILE:-}"
  [ -n "$pausefile" ] || pausefile="${main_root:+${main_root}/.agents/pause}"
  if [ -n "${pausefile:-}" ] && [ ! -f "$pausefile" ]; then
    "${here}/runstate.sh" request-pause "$pausefile" "$reason" >/dev/null 2>&1 || true
    line="${line} ⏸"
  fi
fi

printf '%s\n' "$line"
exit 0
