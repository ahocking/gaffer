#!/usr/bin/env bash
# =============================================================================
# prompt-audit.sh — static prompt-size × invocation-frequency audit (ADR 0019 v2 / N)
# =============================================================================
# Ranks the plugin's own PROMPT surface — agent personas (`agents/*.md`) and skill
# instructions (`skills/*/SKILL.md`) — by IMPACT = prompt_tokens × times_loaded, to
# answer two optimization questions directly: "which skills should we compact?" and
# "which agents need tighter instructions?" (CLAUDE.md levers 1-2).
#
# `prompt_tokens` is a static chars/4 estimate. `times_loaded` is dynamic: how often
# each skill was invoked / each agent dispatched, read from the run-metrics EVENT LOG
# (the `skill` and `Agent`/`subagent_type` fields the v2 hook records). A big prompt
# invoked once matters far less than a small one invoked 50× — impact captures that.
# With no event log it FALLS BACK to size-only ranking and says so (a big prompt is a
# candidate regardless; frequency just sharpens the order).
#
# Read-only. Crosses no gate. `jq` optional (only the frequency join needs it).
#
# Usage:
#   prompt-audit.sh [--plugin-root DIR] [--main-root DIR] [--tsv]
#     --plugin-root  where agents/ and skills/ live (default: this script's repo)
#     --main-root    where .agents/metrics/events/*.jsonl live (default: git-common-dir)
#     --tsv          machine-readable: `kind<TAB>name<TAB>tokens<TAB>loads<TAB>impact`
# =============================================================================
set -uo pipefail

plugin_root="" main_root="" tsv=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-root) plugin_root="$2"; shift 2 ;;
    --main-root)   main_root="$2"; shift 2 ;;
    --tsv)         tsv=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) printf 'prompt-audit.sh: unknown option %s\n' "$1" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -n "$plugin_root" ] || plugin_root="$(dirname "$HERE")"       # repo root = scripts/..
if [ -z "$main_root" ]; then
  gcd="$(git -C "$plugin_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gcd" ] && main_root="$(dirname "$gcd")" || main_root="$plugin_root"
fi
evdir="${main_root}/.agents/metrics/events"

est() { awk '{c+=length($0)+1} END{printf "%d", (c+3)/4}' "$1" 2>/dev/null; }   # ~tokens

# --- frequency map from the event log (skill invocations + agent dispatches) ---
# key = last colon-segment of the skill/subagent_type ("gaffer:metrics" -> metrics)
have_freq=0; FREQ=""
if command -v jq >/dev/null 2>&1 && ls "$evdir"/*.jsonl >/dev/null 2>&1; then
  FREQ="$(cat "$evdir"/*.jsonl 2>/dev/null | jq -rs '
    ( (map(select(.skill)) | group_by(.skill|split(":")|last)
         | map({k:"skill", n:(.[0].skill|split(":")|last), c:length}))
    + (map(select(.tool=="Agent" and .subagent_type)) | group_by(.subagent_type|split(":")|last)
         | map({k:"agent", n:(.[0].subagent_type|split(":")|last), c:length}))
    ) | .[] | "\(.k)\t\(.n)\t\(.c)"' 2>/dev/null)"
  [ -n "$FREQ" ] && have_freq=1
fi
freq_of() {  # freq_of <kind> <name>
  [ "$have_freq" -eq 1 ] || { echo 0; return; }
  printf '%s\n' "$FREQ" | awk -F'\t' -v k="$1" -v n="$2" '$1==k && $2==n {print $3; f=1} END{if(!f)print 0}' | head -1
}

# --- collect rows: kind, name, tokens, loads, impact --------------------------
rows=""
for f in "$plugin_root"/agents/*.md; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .md)"; t="$(est "$f")"; l="$(freq_of agent "$n")"
  rows="${rows}agent	${n}	${t}	${l}	$((t*l))
"
done
for d in "$plugin_root"/skills/*/; do
  f="${d}SKILL.md"; [ -f "$f" ] || continue
  n="$(basename "$d")"; t="$(est "$f")"; l="$(freq_of skill "$n")"
  rows="${rows}skill	${n}	${t}	${l}	$((t*l))
"
done

# rank: by impact when we have frequency, else by raw tokens (col 3)
sort_col=5; [ "$have_freq" -eq 1 ] || sort_col=3
ranked="$(printf '%s' "$rows" | awk 'NF' | sort -t'	' -k${sort_col},${sort_col}nr)"

if [ "$tsv" -eq 1 ]; then
  printf 'kind\tname\ttokens\tloads\timpact\n'
  printf '%s\n' "$ranked"
  exit 0
fi

# --- human report -------------------------------------------------------------
printf '── Prompt-size audit ──  (impact = ~tokens × times-loaded; tokens = chars/4)\n'
if [ "$have_freq" -eq 1 ]; then
  printf 'frequency from %s\n\n' "$evdir"
else
  printf 'NO event log found — ranking by SIZE only (frequency unknown; a big prompt is\n'
  printf 'still a candidate, but size×frequency would sharpen this). Run some sessions first.\n\n'
fi
printf '%-7s %-32s %8s %7s %10s\n' KIND NAME '~TOKENS' LOADS IMPACT
printf '%s\n' "$ranked" | awk -F'\t' '{printf "%-7s %-32s %8s %7s %10s\n",$1,$2,$3,$4,$5}'
printf '\nTop of this list = biggest compaction/tightening payoff. Compact skills / tighten\n'
printf 'agents structurally (relocate, do not reword — no test guards prompt fidelity), then\n'
printf 're-run the test sweeps and re-measure. See ADR 0019 v2 and CLAUDE.md levers 1-2.\n'
