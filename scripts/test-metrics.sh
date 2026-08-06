#!/usr/bin/env bash
# =============================================================================
# test-metrics.sh — regression sweep for the run-metrics core (ADR 0019 Tier 1)
# =============================================================================
# Exercises scripts/metrics.sh (the JOIN/ASSEMBLE core) and hooks/metrics-log.sh
# (the event logger) against SYNTHETIC fixtures — a throwaway git repo with
# `[orch packet:<id>]` trailers, a per-session event log, a packet-graph wave map,
# and fake Claude Code transcripts. No live agent, no real ~/.claude. Exit 0 = all
# passed (CI runs it on push). A behavior worth having is a behavior worth a test.
# =============================================================================

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
METRICS="${HERE}/metrics.sh"
HOOK="${HERE}/../hooks/metrics-log.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (metrics.sh requires it)"; exit 0; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT/repo"; PROJ="$ROOT/projects"
mkdir -p "$REPO" "$PROJ"

# --- build a throwaway git repo with packet-trailer commits at fixed times ----
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
commit_at() { # commit_at <iso-Z> <packet-id>
  echo "$2" >> "$REPO/log.txt"; git -C "$REPO" add -A
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" \
    git -C "$REPO" commit -q -m "work

[orch packet:$2]"
}
commit_at "2026-07-21T10:00:03Z" "feat-001"
commit_at "2026-07-21T10:00:06Z" "feat-002"

# --- .agents fixtures: event log, packet-graph waves, run-state ---------------
mkdir -p "$REPO/.agents/metrics/events"
EV="$REPO/.agents/metrics/events/S1.jsonl"
cat > "$EV" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"S1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"cmd_class":"git status"}
{"ts":"2026-07-21T10:00:02Z","session_id":"S1","agent_id":"a1","agent_type":"implementer","tool":"Edit","duration_ms":20}
{"ts":"2026-07-21T10:00:03Z","session_id":"S1","agent_id":"a1","agent_type":"implementer","tool":"Bash","duration_ms":30,"cmd_class":"dotnet test"}
{"ts":"2026-07-21T10:00:04Z","session_id":"S1","agent_id":"a2","agent_type":"reviewer","tool":"Bash","duration_ms":40,"cmd_class":"git diff"}
{"ts":"2026-07-21T10:00:05Z","session_id":"S1","agent_id":"a1","agent_type":"implementer","tool":"Edit","duration_ms":50}
JSON

cat > "$REPO/.agents/packet-graph.yaml" <<'YAML'
waves:
  - wave: 1
    packets:
      - id: feat-001
  - wave: 2
    packets:
      - id: feat-002
YAML

cat > "$REPO/.agents/run-state.yaml" <<'YAML'
schema: 3
status: running
mode: parallel
branch: orch/feat-001
YAML

# --- fake Claude Code transcripts (documented usage shape) --------------------
# Per-turn `timestamp` lets metrics bucket tokens into packet windows (ADR 0019 v2).
# feat-001 window (:01,:03] ; feat-002 window (:03,:06].
mkdir -p "$PROJ/proj/S1/subagents"
# main transcript: turn1 in feat-001 (:02), turn2 in feat-002 (:04)
cat > "$PROJ/proj/S1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T10:00:02Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":800}}}
{"type":"assistant","timestamp":"2026-07-21T10:00:04Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":400}}}
JSON
# subagent a1 (implementer) — turn in feat-001 (:03)
cat > "$PROJ/proj/S1/subagents/agent-a1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T10:00:03Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":300,"output_tokens":150,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000}}}
JSON
# subagent a2 (reviewer) — turn in feat-002 (:04)
cat > "$PROJ/proj/S1/subagents/agent-a2.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T10:00:04Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":40,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":600}}}
JSON

echo "== collect (full: events + trailers + waves + transcripts) =="
OUT="$ROOT/run-metrics.json"
"$METRICS" collect --main-root "$REPO" --projects-dir "$PROJ" --out "$OUT" >/dev/null 2>&1 \
  || bad "collect exits 0" "collect returned nonzero"
[ -f "$OUT" ] && jq -e . "$OUT" >/dev/null 2>&1 && ok "packet is valid JSON" || bad "packet is valid JSON"

check "run_id"              "feat-001"    "$(jq -r '.run_id' "$OUT")"
check "mode"                "parallel"    "$(jq -r '.mode' "$OUT")"
check "token_source"        "transcript"  "$(jq -r '.token_source' "$OUT")"
check "totals.tool_calls"   "5"           "$(jq -r '.totals.tool_calls' "$OUT")"
check "totals.packets"      "2"           "$(jq -r '.totals.packets' "$OUT")"

# tokens: main(200/100/200/1200) + a1(300/150/100/1000) + a2(40/20/0/600)
check "tokens.input"          "540"  "$(jq -r '.totals.tokens.input' "$OUT")"
check "tokens.output"         "270"  "$(jq -r '.totals.tokens.output' "$OUT")"
check "tokens.cache_creation" "300"  "$(jq -r '.totals.tokens.cache_creation' "$OUT")"
check "tokens.cache_read"     "2800" "$(jq -r '.totals.tokens.cache_read' "$OUT")"
# cache_hit_ratio = 2800/(2800+300) = 0.903
check "cache_hit_ratio"     "0.903"       "$(jq -r '.totals.cache_hit_ratio' "$OUT")"

# per-role breakdown present
check "role implementer in"  "300" "$(jq -r '.by_agent_role.implementer.tokens.input' "$OUT")"
check "role reviewer read"   "600" "$(jq -r '.by_agent_role.reviewer.tokens.cache_read' "$OUT")"
check "role main read"       "1200" "$(jq -r '.by_agent_role.main.tokens.cache_read' "$OUT")"

# per-packet windows: feat-001 (:01,:03] -> :02,:03 = 2 (both implementer);
#                     feat-002 (:03,:06] -> :04(reviewer),:05(implementer) = 2
check "pkt feat-001 wave"        "1" "$(jq -r '.packets[]|select(.id=="feat-001").wave' "$OUT")"
check "pkt feat-001 tool_calls"  "2" "$(jq -r '.packets[]|select(.id=="feat-001").tool_calls' "$OUT")"
check "pkt feat-001 implementer" "2" "$(jq -r '.packets[]|select(.id=="feat-001").by_agent.implementer' "$OUT")"
check "pkt feat-002 wave"        "2" "$(jq -r '.packets[]|select(.id=="feat-002").wave' "$OUT")"
check "pkt feat-002 tool_calls"  "2" "$(jq -r '.packets[]|select(.id=="feat-002").tool_calls' "$OUT")"
check "pkt feat-002 reviewer"    "1" "$(jq -r '.packets[]|select(.id=="feat-002").by_agent.reviewer' "$OUT")"

# --- ADR 0019 v2: schema bump, model split, per-packet tokens, active/idle, unattributed
check "schema is 2"          "2" "$(jq -r '.schema' "$OUT")"

# D. model-per-agent (by role + run-wide by_model)
check "role implementer model out" "150" "$(jq -r '.by_agent_role.implementer.models["claude-sonnet-5"].output' "$OUT")"
check "role main model out"        "100" "$(jq -r '.by_agent_role.main.models["claude-opus-4-8"].output' "$OUT")"
check "by_model opus out (main+reviewer)" "120" "$(jq -r '.totals.by_model["claude-opus-4-8"].output' "$OUT")"
check "by_model sonnet out"         "150" "$(jq -r '.totals.by_model["claude-sonnet-5"].output' "$OUT")"

# C. per-packet token split (bucketed by turn timestamp)
check "pkt feat-001 tokens.output"     "200"  "$(jq -r '.packets[]|select(.id=="feat-001").tokens.output' "$OUT")"
check "pkt feat-001 tokens.cache_read" "1800" "$(jq -r '.packets[]|select(.id=="feat-001").tokens.cache_read' "$OUT")"
check "pkt feat-002 tokens.output"     "70"   "$(jq -r '.packets[]|select(.id=="feat-002").tokens.output' "$OUT")"
check "pkt feat-002 tokens.cache_read" "1000" "$(jq -r '.packets[]|select(.id=="feat-002").tokens.cache_read' "$OUT")"

# A. active/idle (all gaps 1s < idle_gap -> idle 0, active 4)
check "window active_seconds" "4" "$(jq -r '.window.active_seconds' "$OUT")"
check "window idle_seconds"   "0" "$(jq -r '.window.idle_seconds' "$OUT")"

# B. unattributed: the :01 boundary event falls outside both packet windows
check "unattributed_tool_calls" "1" "$(jq -r '.totals.unattributed_tool_calls' "$OUT")"
check "unattributed by main"    "1" "$(jq -r '.totals.unattributed_by_agent.main' "$OUT")"

# P3-G. duration (native duration_ms field; no pairing)
check "totals.duration_ms"      "150" "$(jq -r '.totals.duration_ms' "$OUT")"
check "role duration implementer" "100" "$(jq -r '.totals.by_role_duration_ms.implementer' "$OUT")"
check "role duration reviewer"    "40"  "$(jq -r '.totals.by_role_duration_ms.reviewer' "$OUT")"
check "pkt feat-001 duration_ms" "50"  "$(jq -r '.packets[]|select(.id=="feat-001").duration_ms' "$OUT")"
check "pkt feat-002 duration_ms" "90"  "$(jq -r '.packets[]|select(.id=="feat-002").duration_ms' "$OUT")"

# P5-L. command-class map (rtk targeting)
check "cmd class dotnet test dur"  "30" "$(jq -r '.totals.by_command_class["dotnet test"].duration_ms' "$OUT")"
check "cmd class git diff calls"   "1"  "$(jq -r '.totals.by_command_class["git diff"].calls' "$OUT")"
check "cmd class git status seen"  "1"  "$(jq -r '.totals.by_command_class["git status"].calls' "$OUT")"

# P5-K. skill attribution — no Skill event here, so all attribute to "none"
check "by_skill none tool_calls"   "5"  "$(jq -r '.totals.by_skill.none.tool_calls' "$OUT")"

echo "== fail-soft: no transcripts -> token_source=none, still assembles =="
OUT2="$ROOT/rm2.json"
"$METRICS" collect --main-root "$REPO" --projects-dir "$ROOT/nonexistent" --out "$OUT2" >/dev/null 2>&1
jq -e . "$OUT2" >/dev/null 2>&1 && ok "packet still valid JSON" || bad "packet still valid JSON"
check "token_source=none"       "none" "$(jq -r '.token_source' "$OUT2")"
check "structural still present" "2"    "$(jq -r '.totals.packets' "$OUT2")"
check "tokens zeroed"            "0"    "$(jq -r '.totals.tokens.input' "$OUT2")"
# fail-soft: no transcript timestamps -> per-packet tokens null, by_model empty
check "no-transcript per-packet tokens null" "null" "$(jq -r '.packets[0].tokens' "$OUT2")"
check "no-transcript by_model empty"         "{}"   "$(jq -c '.totals.by_model' "$OUT2")"

echo "== active/idle: an inter-event gap > idle_gap counts as IDLE, not active =="
IREPO="$ROOT/irepo"; mkdir -p "$IREPO"; git -C "$IREPO" init -q
IEV="$IREPO/.agents/metrics/events"; mkdir -p "$IEV"
cat > "$IEV/I1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00Z","session_id":"I1","agent_id":"","agent_type":"main","tool":"Bash"}
{"ts":"2026-07-21T10:00:02Z","session_id":"I1","agent_id":"","agent_type":"main","tool":"Bash"}
{"ts":"2026-07-21T10:10:02Z","session_id":"I1","agent_id":"","agent_type":"main","tool":"Bash"}
JSON
IOUT="$ROOT/irm.json"
"$METRICS" collect --main-root "$IREPO" --projects-dir "$ROOT/none" --out "$IOUT" >/dev/null 2>&1
# gaps: 2s (active) then 600s (> default 300 idle_gap -> idle)
check "idle gap counted as idle" "600" "$(jq -r '.window.idle_seconds' "$IOUT")"
check "active excludes the gap"  "2"   "$(jq -r '.window.active_seconds' "$IOUT")"
# override via env: raise threshold above the gap -> the whole span is active
IOUT2="$ROOT/irm2.json"
ORCH_METRICS_IDLE_GAP=700 "$METRICS" collect --main-root "$IREPO" --projects-dir "$ROOT/none" --out "$IOUT2" >/dev/null 2>&1
check "idle_gap env override -> idle 0" "0"   "$(jq -r '.window.idle_seconds' "$IOUT2")"
check "idle_gap env override -> active" "602" "$(jq -r '.window.active_seconds' "$IOUT2")"

echo "== skill attribution: events roll up under the skill in effect (P5-K) =="
SKREPO="$ROOT/skrepo"; mkdir -p "$SKREPO"; git -C "$SKREPO" init -q
SKEV="$SKREPO/.agents/metrics/events"; mkdir -p "$SKEV"
cat > "$SKEV/K1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00Z","session_id":"K1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5}
{"ts":"2026-07-21T10:00:01Z","session_id":"K1","agent_id":"","agent_type":"main","tool":"Skill","skill":"run-loop"}
{"ts":"2026-07-21T10:00:02Z","session_id":"K1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5}
{"ts":"2026-07-21T10:00:03Z","session_id":"K1","agent_id":"","agent_type":"main","tool":"Skill","skill":"metrics"}
{"ts":"2026-07-21T10:00:04Z","session_id":"K1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5}
JSON
KOUT="$ROOT/krm.json"
"$METRICS" collect --main-root "$SKREPO" --projects-dir "$ROOT/none" --out "$KOUT" >/dev/null 2>&1
check "skill run-loop tool_calls" "2" "$(jq -r '.totals.by_skill["run-loop"].tool_calls' "$KOUT")"
check "skill metrics tool_calls"  "2" "$(jq -r '.totals.by_skill.metrics.tool_calls' "$KOUT")"
check "skill none (pre-skill)"    "1" "$(jq -r '.totals.by_skill.none.tool_calls' "$KOUT")"

echo "== hook enrichment: duration/tool_use_id/skill/subagent_type/cmd_class (head-only) =="
HREPO2="$ROOT/hrepo2"; HEV2="$HREPO2/.agents/metrics/events"; mkdir -p "$HREPO2"; git -C "$HREPO2" init -q
he() { printf '%s' "$1" | ORCH_METRICS_DIR="$HEV2" "$HOOK" >/dev/null 2>&1; }
he '{"session_id":"E1","tool_name":"Bash","agent_id":"","agent_type":"main","duration_ms":206,"tool_use_id":"toolu_9","tool_input":{"command":"API_KEY=xyz git status --porcelain"}}'
he '{"session_id":"E1","tool_name":"Bash","agent_id":"","agent_type":"main","duration_ms":7,"tool_input":{"command":"cd /Users/x/proj && git diff HEAD"}}'
he '{"session_id":"E1","tool_name":"Bash","agent_id":"","agent_type":"main","duration_ms":8,"tool_input":{"command":"cd /Users/x/proj\ngit log --oneline"}}'
he '{"session_id":"E1","tool_name":"Bash","agent_id":"","agent_type":"main","duration_ms":9,"tool_input":{"command":"cd /Users/x/proj"}}'
he '{"session_id":"E1","tool_name":"Bash","agent_id":"","agent_type":"main","duration_ms":11,"tool_input":{"command":"[ -f x ] && git status"}}'
he '{"session_id":"E1","tool_name":"Skill","agent_id":"","agent_type":"main","tool_input":{"skill":"gaffer:metrics","args":"status"}}'
he '{"session_id":"E1","tool_name":"Agent","agent_id":"","agent_type":"main","tool_input":{"subagent_type":"general-purpose"}}'
HL="$HEV2/E1.jsonl"
check "hook cmd_class head-only"   "git status"          "$(jq -r 'select(.tool=="Bash" and .duration_ms==206).cmd_class' "$HL")"
check "hook cmd_class skips cd &&" "git diff"            "$(jq -r 'select(.tool=="Bash" and .duration_ms==7).cmd_class' "$HL")"
check "hook cmd_class newline cd"  "git log"             "$(jq -r 'select(.tool=="Bash" and .duration_ms==8).cmd_class' "$HL")"
check "hook cmd_class bare cd"     "cd"                  "$(jq -r 'select(.tool=="Bash" and .duration_ms==9).cmd_class' "$HL")"
check "hook cmd_class skips [ test" "git status"         "$(jq -r 'select(.tool=="Bash" and .duration_ms==11).cmd_class' "$HL")"
check "hook duration_ms"           "206"                 "$(jq -r 'select(.tool=="Bash" and .duration_ms==206).duration_ms' "$HL")"
check "hook tool_use_id"           "toolu_9"             "$(jq -r 'select(.tool=="Bash" and .duration_ms==206).tool_use_id' "$HL")"
check "hook skill name"            "gaffer:metrics" "$(jq -r 'select(.tool=="Skill").skill' "$HL")"
check "hook subagent_type"         "general-purpose"     "$(jq -r 'select(.tool=="Agent").subagent_type' "$HL")"
# privacy: NO args / env / paths / secret leak into the log (head-only classifier)
if grep -qiE 'API_KEY|xyz|porcelain|/Users/|HEAD' "$HL"; then bad "hook cmd_class leaks args/paths/secret"; else ok "hook cmd_class leaks nothing (no args/env/paths/secret)"; fi

echo "== no events + no repo trailers -> empty-but-valid packet =="
BARE="$ROOT/bare"; mkdir -p "$BARE"; git -C "$BARE" init -q
OUT3="$ROOT/rm3.json"
"$METRICS" collect --main-root "$BARE" --projects-dir "$ROOT/none" --out "$OUT3" >/dev/null 2>&1
jq -e . "$OUT3" >/dev/null 2>&1 && ok "bare packet valid JSON" || bad "bare packet valid JSON"
check "bare packets=0"    "0" "$(jq -r '.totals.packets' "$OUT3")"
check "bare tool_calls=0" "0" "$(jq -r '.totals.tool_calls' "$OUT3")"

echo "== enabled gate: ORCH_METRICS=off -> hook writes nothing =="
HREPO="$ROOT/hrepo"; mkdir -p "$HREPO"; git -C "$HREPO" init -q
payload='{"session_id":"H1","tool_name":"Bash","agent_id":"","agent_type":"main"}'
ORCH_METRICS=off ORCH_METRICS_DIR="$HREPO/.agents/metrics/events" \
  bash -c "printf '%s' '$payload' | '$HOOK'" >/dev/null 2>&1
[ ! -f "$HREPO/.agents/metrics/events/H1.jsonl" ] && ok "disabled hook writes nothing" \
  || bad "disabled hook writes nothing" "file should not exist"

echo "== hook appends a metadata line and prints NOTHING on stdout =="
STDOUT="$(printf '%s' "$payload" | ORCH_METRICS_DIR="$HREPO/.agents/metrics/events" "$HOOK" 2>/dev/null)"
check "hook stdout empty (no permissionDecision)" "" "$STDOUT"
LINE="$HREPO/.agents/metrics/events/H1.jsonl"
[ -f "$LINE" ] && jq -e . "$LINE" >/dev/null 2>&1 && ok "hook wrote a valid JSON line" || bad "hook wrote a valid JSON line"
check "hook line: tool"       "Bash" "$(jq -r '.tool' "$LINE" 2>/dev/null)"
check "hook line: agent_type" "main" "$(jq -r '.agent_type' "$LINE" 2>/dev/null)"
# v2: with NO tool_input/duration in the payload, all enrichment fields are OMITTED —
# only the 5 base keys appear (no spurious keys, and never full command text / paths).
check "hook line: base keys only when enrichment absent" "agent_id agent_type session_id tool ts" \
  "$(jq -r 'keys|join(" ")' "$LINE" 2>/dev/null)"

echo "== widened matcher: non-mutating tools (Task, Read) are logged too =="
WREPO="$ROOT/wrepo"; mkdir -p "$WREPO"; git -C "$WREPO" init -q
WEV="$WREPO/.agents/metrics/events"
for tp in Task Read; do
  printf '%s' "{\"session_id\":\"W1\",\"tool_name\":\"$tp\",\"agent_id\":\"\",\"agent_type\":\"main\"}" \
    | ORCH_METRICS_DIR="$WEV" "$HOOK" >/dev/null 2>&1
done
check "Task + Read both logged" "Read Task" \
  "$(jq -r '.tool' "$WEV/W1.jsonl" 2>/dev/null | sort | paste -sd' ' - | sed 's/ *$//')"

echo "== PARALLEL: a lane event resolves to the MAIN checkout's metrics dir =="
# The hook must resolve <main>/.agents/metrics via git-common-dir even when it fires
# from INSIDE a worktree lane (the same trick pause-check uses). No ORCH_METRICS_DIR.
MREPO="$ROOT/mrepo"; mkdir -p "$MREPO"; git -C "$MREPO" init -q
git -C "$MREPO" config user.email t@t; git -C "$MREPO" config user.name t
echo x > "$MREPO/f"; git -C "$MREPO" add -A; git -C "$MREPO" commit -q -m init
WT="$ROOT/mrepo-wt"
git -C "$MREPO" worktree add -q -b orch/lane-a "$WT" >/dev/null 2>&1
( cd "$WT" && printf '%s' '{"session_id":"L1","tool_name":"Bash","agent_id":"laneA","agent_type":"implementer"}' | "$HOOK" >/dev/null 2>&1 )
MAINEV="$MREPO/.agents/metrics/events/L1.jsonl"
[ -f "$MAINEV" ] && ok "lane event landed in MAIN checkout dir" || bad "lane event landed in MAIN checkout dir" "expected $MAINEV"
check "lane event agent_id preserved" "laneA" "$(jq -r '.agent_id' "$MAINEV" 2>/dev/null)"
# P5-M: the event is stamped with the worktree basename as lane_id (parallel attribution)
check "lane event lane_id = worktree basename" "mrepo-wt" "$(jq -r '.lane_id' "$MAINEV" 2>/dev/null)"
[ ! -e "$WT/.agents/metrics/events/L1.jsonl" ] && ok "lane did NOT write inside the worktree" || bad "lane did NOT write inside the worktree"

echo "== PARALLEL: concurrent lanes appending to one session file stay intact =="
# Subagent lanes can SHARE the parent session id -> same file, concurrent appends.
# O_APPEND + sub-PIPE_BUF lines must yield no torn/interleaved lines.
CREPO="$ROOT/crepo"; CEV="$CREPO/.agents/metrics/events"; mkdir -p "$CREPO"; git -C "$CREPO" init -q
emit() { printf '%s' "{\"session_id\":\"C1\",\"tool_name\":\"Bash\",\"agent_id\":\"$1\",\"agent_type\":\"$1\"}" | ORCH_METRICS_DIR="$CEV" "$HOOK" >/dev/null 2>&1; }
for _ in $(seq 1 15); do emit laneX & emit laneY & done; wait
check "concurrent: all 30 appends present" "30" "$(wc -l < "$CEV/C1.jsonl" 2>/dev/null | tr -d ' ')"
corrupt=0; while IFS= read -r ln; do printf '%s' "$ln" | jq -e . >/dev/null 2>&1 || corrupt=$((corrupt+1)); done < "$CEV/C1.jsonl"
check "concurrent: 0 torn/corrupt lines" "0" "$corrupt"

echo "== P5-M: by_lane rollup attributes spend per worktree lane =="
LREPO="$ROOT/lrepo"; mkdir -p "$LREPO"; git -C "$LREPO" init -q
LEV="$LREPO/.agents/metrics/events"; mkdir -p "$LEV"
cat > "$LEV/LN.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00Z","session_id":"LN","agent_id":"a","agent_type":"implementer","tool":"Bash","duration_ms":100,"lane_id":"repo-wt-t1"}
{"ts":"2026-07-21T10:00:01Z","session_id":"LN","agent_id":"a","agent_type":"implementer","tool":"Bash","duration_ms":200,"lane_id":"repo-wt-t1"}
{"ts":"2026-07-21T10:00:02Z","session_id":"LN","agent_id":"b","agent_type":"implementer","tool":"Bash","duration_ms":50,"lane_id":"repo-wt-t2"}
JSON
LOUT="$ROOT/lrm.json"
"$METRICS" collect --main-root "$LREPO" --projects-dir "$ROOT/none" --out "$LOUT" >/dev/null 2>&1
check "by_lane t1 tool_calls"  "2"   "$(jq -r '.totals.by_lane["repo-wt-t1"].tool_calls' "$LOUT")"
check "by_lane t1 duration_ms" "300" "$(jq -r '.totals.by_lane["repo-wt-t1"].duration_ms' "$LOUT")"
check "by_lane t2 tool_calls"  "1"   "$(jq -r '.totals.by_lane["repo-wt-t2"].tool_calls' "$LOUT")"

echo "== scope: commit trailers OUTSIDE the run window are excluded =="
# A prior run's packet (committed before this run's first event) must NOT be folded
# into this run. This is the 156-phantom-packets bug (the first production capture).
SREPO="$ROOT/srepo"; mkdir -p "$SREPO"; git -C "$SREPO" init -q
git -C "$SREPO" config user.email t@t; git -C "$SREPO" config user.name t
scommit() { echo "$2" >> "$SREPO/l"; git -C "$SREPO" add -A
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$SREPO" commit -q -m "w

[orch packet:$2]"; }
scommit "2026-07-20T09:00:00Z" "old-prior-run"   # BEFORE the window -> excluded
scommit "2026-07-21T10:00:03Z" "in-run"          # inside the window -> kept
mkdir -p "$SREPO/.agents/metrics/events"
cat > "$SREPO/.agents/metrics/events/S1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"S1","agent_id":"","agent_type":"main","tool":"Bash"}
{"ts":"2026-07-21T10:00:05Z","session_id":"S1","agent_id":"","agent_type":"main","tool":"Bash"}
JSON
SOUT="$ROOT/srm.json"
"$METRICS" collect --main-root "$SREPO" --projects-dir "$ROOT/none" --out "$SOUT" >/dev/null 2>&1
check "window scope: only in-window packet" "1"       "$(jq -r '.totals.packets' "$SOUT")"
check "window scope: kept the in-run id"    "in-run"  "$(jq -r '.packets[0].id' "$SOUT")"
check "window scope: prior-run excluded"    ""        "$(jq -r '.packets[]|select(.id=="old-prior-run").id' "$SOUT")"

echo "== scope: newest session by default; --all-sessions includes all =="
MSREPO="$ROOT/msrepo"; mkdir -p "$MSREPO"; git -C "$MSREPO" init -q
MSEV="$MSREPO/.agents/metrics/events"; mkdir -p "$MSEV"
cat > "$MSEV/OLD.jsonl" <<'JSON'
{"ts":"2026-07-01T00:00:00Z","session_id":"OLD","agent_id":"","agent_type":"main","tool":"Bash"}
{"ts":"2026-07-01T00:00:01Z","session_id":"OLD","agent_id":"","agent_type":"main","tool":"Bash"}
{"ts":"2026-07-01T00:00:02Z","session_id":"OLD","agent_id":"","agent_type":"main","tool":"Bash"}
JSON
cat > "$MSEV/NEW.jsonl" <<'JSON'
{"ts":"2026-07-21T00:00:00Z","session_id":"NEW","agent_id":"","agent_type":"main","tool":"Bash"}
{"ts":"2026-07-21T00:00:01Z","session_id":"NEW","agent_id":"","agent_type":"main","tool":"Bash"}
JSON
touch -t 202607010000 "$MSEV/OLD.jsonl"   # force OLD to be the older file by mtime
touch -t 202607210000 "$MSEV/NEW.jsonl"
MSOUT="$ROOT/msrm.json"
"$METRICS" collect --main-root "$MSREPO" --projects-dir "$ROOT/none" --out "$MSOUT" >/dev/null 2>&1
check "default picks newest session"    "NEW"     "$(jq -r '.sessions|join(",")' "$MSOUT")"
check "default tool_calls (NEW only)"   "2"       "$(jq -r '.totals.tool_calls' "$MSOUT")"
MSOUT2="$ROOT/msrm2.json"
"$METRICS" collect --main-root "$MSREPO" --projects-dir "$ROOT/none" --all-sessions --out "$MSOUT2" >/dev/null 2>&1
check "--all-sessions includes both"    "NEW,OLD" "$(jq -r '.sessions|join(",")' "$MSOUT2")"
check "--all-sessions tool_calls sum"   "5"       "$(jq -r '.totals.tool_calls' "$MSOUT2")"

echo "== adhoc run_id + output path are disambiguated by session id =="
AREPO="$ROOT/arepo"; mkdir -p "$AREPO"; git -C "$AREPO" init -q
AEV="$AREPO/.agents/metrics/events"; mkdir -p "$AEV"
cat > "$AEV/sess1234abcd.jsonl" <<'JSON'
{"ts":"2026-07-21T00:00:00Z","session_id":"sess1234abcd","agent_id":"","agent_type":"main","tool":"Bash"}
JSON
# no run-state + HEAD not on orch/* -> run_id falls back to adhoc-<sid8> (not bare "adhoc")
APATH="$("$METRICS" collect --main-root "$AREPO" --projects-dir "$ROOT/none" 2>/dev/null)"
check "adhoc run_id carries session8" "adhoc-sess1234" "$(jq -r '.run_id' "$APATH" 2>/dev/null)"
case "$APATH" in
  */metrics/adhoc-sess1234/run-metrics.json) ok "adhoc output path disambiguated by session" ;;
  *) bad "adhoc output path disambiguated by session" "got $APATH" ;;
esac

echo "== N: prompt-audit ranks by impact = tokens × invocation-frequency =="
PA="${HERE}/prompt-audit.sh"
PROOT="$ROOT/plug"; mkdir -p "$PROOT/skills/big" "$PROOT/skills/small" "$PROOT/agents"
printf 'x%.0s' $(seq 1 1600) > "$PROOT/skills/big/SKILL.md"      # ~400 tok
printf 'y%.0s' $(seq 1 400)  > "$PROOT/skills/small/SKILL.md"    # ~100 tok
printf 'z%.0s' $(seq 1 200)  > "$PROOT/agents/tiny.md"
MROOT="$ROOT/plugmain"; mkdir -p "$MROOT/.agents/metrics/events"
{ for _ in $(seq 1 10); do echo '{"ts":"2026-07-21T10:00:00Z","session_id":"P","tool":"Skill","skill":"proj:small"}'; done
  echo '{"ts":"2026-07-21T10:00:00Z","session_id":"P","tool":"Skill","skill":"proj:big"}'; } > "$MROOT/.agents/metrics/events/P.jsonl"
# small (100 tok × 10 loads = 1000) must outrank big (400 tok × 1 = 400): frequency flips size order
check "prompt-audit: frequency flips ranking (small on top)" "small" \
  "$(bash "$PA" --plugin-root "$PROOT" --main-root "$MROOT" --tsv 2>/dev/null | sed -n '2p' | cut -f2)"
check "prompt-audit: big skill still listed" "1" \
  "$(bash "$PA" --plugin-root "$PROOT" --main-root "$MROOT" --tsv 2>/dev/null | grep -c "	big	")"
# no event log -> size-only fallback still ranks (big on top by size)
check "prompt-audit: size-only fallback (no events)" "big" \
  "$(bash "$PA" --plugin-root "$PROOT" --main-root "$ROOT/none" --tsv 2>/dev/null | sed -n '2p' | cut -f2)"

echo "== ADR 0019: window-bleed + <synthetic> drop + unknown-share degrade =="
# Regression for the "501k phantom output on a 122s no-op" bug: token turns must be
# bounded to the SAME run window as the event spine, `<synthetic>` turns dropped, and
# a large role='unknown' share must downgrade the stamp to transcript-degraded.
BREPO="$ROOT/brepo"; PROJB="$ROOT/projb"; mkdir -p "$BREPO" "$PROJB/proj/B1/subagents"
git -C "$BREPO" init -q
git -C "$BREPO" config user.email t@t; git -C "$BREPO" config user.name t
echo work > "$BREPO/log.txt"; git -C "$BREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T12:00:03Z" GIT_COMMITTER_DATE="2026-07-21T12:00:03Z" \
  git -C "$BREPO" commit -q -m "work

[orch packet:bfeat]"
mkdir -p "$BREPO/.agents/metrics/events"
cat > "$BREPO/.agents/metrics/events/B1.jsonl" <<'JSON'
{"ts":"2026-07-21T12:00:01Z","session_id":"B1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"cmd_class":"git status"}
{"ts":"2026-07-21T12:00:03Z","session_id":"B1","agent_id":"","agent_type":"main","tool":"Edit","duration_ms":20}
JSON
# main transcript: one in-window turn (:02), one OUT-of-window turn a day earlier
# (the bleed — must be excluded), one <synthetic> turn carrying tokens (must be dropped).
cat > "$PROJB/proj/B1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T12:00:02Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":200}}}
{"type":"assistant","timestamp":"2026-07-20T09:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":5000,"output_tokens":999999,"cache_creation_input_tokens":5000,"cache_read_input_tokens":9999999}}}
{"type":"assistant","timestamp":"2026-07-21T12:00:02Z","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JSON
# subagent zz: agent_id absent from the event spine -> role 'unknown'
cat > "$PROJB/proj/B1/subagents/agent-zz.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T12:00:02Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":3,"output_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":60}}}
JSON
BOUT="$ROOT/brun.json"
"$METRICS" collect --main-root "$BREPO" --projects-dir "$PROJB" --out "$BOUT" >/dev/null 2>&1 \
  || bad "bleed collect exits 0" "collect returned nonzero"
# window bleed excluded: totals are in-window/non-synthetic only, NOT 999999 or +500
check "bleed: tokens.output (100 main + 30 unknown)" "130"  "$(jq -r '.totals.tokens.output' "$BOUT")"
check "bleed: tokens.cache_read (200+60)"            "260"  "$(jq -r '.totals.tokens.cache_read' "$BOUT")"
check "bleed: tokens.input (10+3)"                   "13"   "$(jq -r '.totals.tokens.input' "$BOUT")"
# <synthetic> dropped from by_model
check "synthetic model absent from by_model" "absent" "$(jq -r '.totals.by_model["<synthetic>"] // "absent"' "$BOUT")"
check "opus out is in-window only (100)"     "100"    "$(jq -r '.totals.by_model["claude-opus-4-8"].output' "$BOUT")"
# unknown role quantified + stamp degraded (30/130 = 23% >= 10%)
check "unknown role output"          "30"                    "$(jq -r '.by_agent_role.unknown.tokens.output' "$BOUT")"
check "token_source degraded"        "transcript-degraded"   "$(jq -r '.token_source' "$BOUT")"
check "attribution note present"     "1" "$(jq -r '[.notes[]|select(startswith("attribution:"))]|length' "$BOUT")"

# control: when everything attributes cleanly and is in-window, stamp stays "transcript"
# (the earlier full-collect scenario S1 already asserts token_source == "transcript").

# backward-compat on S1: it has NO tier/impl trailers, and main did no Edits.
check "S1 audit labels absent"          "false" "$(jq -r '.audit.labels_present' "$OUT")"
check "S1 no orchestrator impl edits"   "0"     "$(jq -r '.audit.orchestrator_impl_edits' "$OUT")"
check "S1 packet tier null (no label)"  "null"  "$(jq -r '.packets[0].tier' "$OUT")"
check "S1 no flagged packets"           "0"     "$(jq -r '.audit.flagged_packets|length' "$OUT")"

echo "== ADR 0019: routing self-label ([orch tier:/impl:]) + audit cross-check =="
CREPO="$ROOT/crepo"; mkdir -p "$CREPO"
git -C "$CREPO" init -q
git -C "$CREPO" config user.email t@t; git -C "$CREPO" config user.name t
echo a > "$CREPO/f"; git -C "$CREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T13:00:03Z" GIT_COMMITTER_DATE="2026-07-21T13:00:03Z" \
  git -C "$CREPO" commit -q -m "mechanical work

[orch packet:c-mech]
[orch tier:mechanical]
[orch impl:inline]"
echo b > "$CREPO/g"; git -C "$CREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T13:00:06Z" GIT_COMMITTER_DATE="2026-07-21T13:00:06Z" \
  git -C "$CREPO" commit -q -m "integration work

[orch packet:c-deleg]
[orch tier:integration]
[orch impl:delegated]"
echo c > "$CREPO/h"; git -C "$CREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T13:00:09Z" GIT_COMMITTER_DATE="2026-07-21T13:00:09Z" \
  git -C "$CREPO" commit -q -m "doc work

[orch packet:c-docs]
[orch tier:docs]
[orch impl:inline]"
# a straggler: this run DOES use the convention, but this packet was committed
# without the trailers -> it must be flagged unlabelled (the mixed-run case)
echo d > "$CREPO/i"; git -C "$CREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T13:00:12Z" GIT_COMMITTER_DATE="2026-07-21T13:00:12Z" \
  git -C "$CREPO" commit -q -m "unlabelled work

[orch packet:c-nolabel]"
mkdir -p "$CREPO/.agents/metrics/events"
# c-mech window (:01,:03]: main (opus orchestrator) EDITS inline, no implementer dispatch -> leak+waste.
# c-deleg window (:03,:06]: main dispatches implementer, implementer does the Edit -> clean.
cat > "$CREPO/.agents/metrics/events/C1.jsonl" <<'JSON'
{"ts":"2026-07-21T13:00:01Z","session_id":"C1","agent_id":"","agent_type":"main","tool":"Bash","cmd_class":"git status"}
{"ts":"2026-07-21T13:00:02Z","session_id":"C1","agent_id":"","agent_type":"main","tool":"Edit"}
{"ts":"2026-07-21T13:00:04Z","session_id":"C1","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer"}
{"ts":"2026-07-21T13:00:05Z","session_id":"C1","agent_id":"i1","agent_type":"gaffer:implementer","tool":"Edit"}
{"ts":"2026-07-21T13:00:08Z","session_id":"C1","agent_id":"","agent_type":"main","tool":"Edit"}
JSON
COUT="$ROOT/crun.json"
"$METRICS" collect --main-root "$CREPO" --projects-dir "$ROOT/none" --out "$COUT" >/dev/null 2>&1 \
  || bad "label collect exits 0" "collect returned nonzero"
# labels parsed off the trailers
check "c-mech tier"   "mechanical"  "$(jq -r '.packets[]|select(.id=="c-mech").tier' "$COUT")"
check "c-mech impl"   "inline"      "$(jq -r '.packets[]|select(.id=="c-mech").impl' "$COUT")"
check "c-deleg tier"  "integration" "$(jq -r '.packets[]|select(.id=="c-deleg").tier' "$COUT")"
check "c-deleg impl"  "delegated"   "$(jq -r '.packets[]|select(.id=="c-deleg").impl' "$COUT")"
# audit: c-mech is the leak (opus orchestrator edited a mechanical packet inline, 0 implementer dispatch)
check "c-mech orch edits"        "1"     "$(jq -r '.packets[]|select(.id=="c-mech").audit.orchestrator_impl_edits' "$COUT")"
check "c-mech impl_dispatched"   "false" "$(jq -r '.packets[]|select(.id=="c-mech").audit.implementer_dispatched' "$COUT")"
check "c-mech has leak flag"     "1"     "$(jq -r '[.packets[]|select(.id=="c-mech").audit.flags[]|select(startswith("leak:"))]|length' "$COUT")"
check "c-mech has waste flag"    "1"     "$(jq -r '[.packets[]|select(.id=="c-mech").audit.flags[]|select(startswith("waste:"))]|length' "$COUT")"
check "c-mech edits by main"     "1"     "$(jq -r '.packets[]|select(.id=="c-mech").impl_edits_by_role.main' "$COUT")"
# audit: c-deleg is clean (delegated, implementer did the edit, orchestrator wrote nothing)
check "c-deleg orch edits"       "0"     "$(jq -r '.packets[]|select(.id=="c-deleg").audit.orchestrator_impl_edits' "$COUT")"
check "c-deleg impl_dispatched"  "true"  "$(jq -r '.packets[]|select(.id=="c-deleg").audit.implementer_dispatched' "$COUT")"
check "c-deleg no flags"         "0"     "$(jq -r '.packets[]|select(.id=="c-deleg").audit.flags|length' "$COUT")"
# run-level rollup
check "run labels_present"       "true"  "$(jq -r '.audit.labels_present' "$COUT")"
check "run orchestrator edits"   "2"     "$(jq -r '.audit.orchestrator_impl_edits' "$COUT")"
check "run implementer dispatch" "1"     "$(jq -r '.audit.implementer_dispatches' "$COUT")"
check "run by_tier mechanical"   "1"     "$(jq -r '.audit.by_tier.mechanical' "$COUT")"
check "run by_tier integration"  "1"     "$(jq -r '.audit.by_tier.integration' "$COUT")"
check "run by_tier docs"         "1"     "$(jq -r '.audit.by_tier.docs' "$COUT")"
# a `docs` packet written inline by the opus orchestrator instead of the haiku
# doc-writer is its own waste class, distinct from the mechanical/integration leak
check "c-docs docs waste flag"   "1"     "$(jq -r '[.packets[]|select(.id=="c-docs").audit.flags[]|select(startswith("waste:docs-tier"))]|length' "$COUT")"
# mixed run: 3 labelled + 1 straggler -> the straggler is flagged, not read as clean
check "run packets_total"        "4"     "$(jq -r '.audit.packets_total' "$COUT")"
check "run missing tier"         "1"     "$(jq -r '.audit.packets_missing_tier' "$COUT")"
check "run missing impl"         "1"     "$(jq -r '.audit.packets_missing_impl' "$COUT")"
check "run unlabelled ids"       "c-nolabel" "$(jq -r '.audit.unlabelled_packet_ids[]' "$COUT")"
check "c-nolabel unlabelled x2"  "2"     "$(jq -r '[.packets[]|select(.id=="c-nolabel").audit.flags[]|select(startswith("unlabelled:"))]|length' "$COUT")"
check "run mixed label note"     "1"     "$(jq -r '[.notes[]|select(startswith("labels: 1 of 4"))]|length' "$COUT")"
check "run flagged ids"          "c-mech c-docs c-nolabel" "$(jq -r '[.audit.flagged_packets[].id]|join(" ")' "$COUT")"

echo "== ADR 0019: ok/model/autonomy/interactivity instrumentation =="
DREPO="$ROOT/drepo"; mkdir -p "$DREPO"
git -C "$DREPO" init -q
git -C "$DREPO" config user.email t@t; git -C "$DREPO" config user.name t
echo a > "$DREPO/f"; git -C "$DREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T14:00:05Z" GIT_COMMITTER_DATE="2026-07-21T14:00:05Z" \
  git -C "$DREPO" commit -q -m "work

[orch packet:d-one]"
mkdir -p "$DREPO/.agents/metrics/events"
# the real .agents/autonomy is a COMMENTED template — the parse must skip comments
# and blank lines and take only the level (regression: slurping yielded the manual).
printf '# Default autonomy level for this repo (ADR 0004).\n#   interactive | supervised | autonomous\n\nautonomous\n' > "$DREPO/.agents/autonomy"
# d-one window (:01,:05]: 3 `dotnet test` runs of which 2 FAILED (ok:false) = rework;
# one dispatch WITH an explicit model OVERRIDE, one plain (which correctly resolves
# to the agent's frontmatter model — NOT a violation); one human question.
cat > "$DREPO/.agents/metrics/events/D1.jsonl" <<'JSON'
{"ts":"2026-07-21T14:00:01Z","session_id":"D1","agent_id":"","agent_type":"main","tool":"Bash","cmd_class":"git status","ok":true}
{"ts":"2026-07-21T14:00:02Z","session_id":"D1","agent_id":"","agent_type":"main","tool":"Bash","cmd_class":"dotnet test","ok":false}
{"ts":"2026-07-21T14:00:03Z","session_id":"D1","agent_id":"","agent_type":"main","tool":"Bash","cmd_class":"dotnet test","ok":false}
{"ts":"2026-07-21T14:00:03Z","session_id":"D1","agent_id":"","agent_type":"main","tool":"Bash","cmd_class":"dotnet test","ok":true}
{"ts":"2026-07-21T14:00:04Z","session_id":"D1","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","model":"sonnet"}
{"ts":"2026-07-21T14:00:04Z","session_id":"D1","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:reviewer"}
{"ts":"2026-07-21T14:00:05Z","session_id":"D1","agent_id":"","agent_type":"main","tool":"AskUserQuestion"}
JSON
DOUT="$ROOT/drun.json"
"$METRICS" collect --main-root "$DREPO" --projects-dir "$ROOT/none" --out "$DOUT" >/dev/null 2>&1 \
  || bad "instrumentation collect exits 0" "collect returned nonzero"
check "autonomy recorded"          "autonomous" "$(jq -r '.autonomy' "$DOUT")"
check "run failed_tool_calls"      "2"          "$(jq -r '.totals.failed_tool_calls' "$DOUT")"
check "run human_interactions"     "1"          "$(jq -r '.totals.human_interactions' "$DOUT")"
check "pkt failed_tool_calls"      "2"          "$(jq -r '.packets[]|select(.id=="d-one").failed_tool_calls' "$DOUT")"
check "pkt human_interactions"     "1"          "$(jq -r '.packets[]|select(.id=="d-one").human_interactions' "$DOUT")"
# rework proxy: 3 dotnet test invocations inside one packet
check "pkt rework proxy (test x3)" "3"          "$(jq -r '.packets[]|select(.id=="d-one").by_command_class["dotnet test"]' "$DOUT")"
# dispatch-model OVERRIDES (§3.3). An omitted model is correct (frontmatter
# resolution), so only the explicit override counts here — the reviewer dispatch
# with no `model` must NOT be counted.
check "dispatches_total"           "2"          "$(jq -r '.audit.dispatches_total' "$DOUT")"
check "dispatch model overrides"   "1"          "$(jq -r '.audit.dispatches_with_model_override' "$DOUT")"
check "by_dispatch_model_override" "1"          "$(jq -r '.audit.by_dispatch_model_override.sonnet' "$DOUT")"
check "no stale unnamed-model key" "null"       "$(jq -r '.audit.dispatches_without_named_model' "$DOUT")"
# d-one carries NO tier/impl trailer and NO packet in the run does -> a wholesale
# unlabelled run. The counts still report it as UNMEASURED, but the per-packet
# flags are SUPPRESSED (a legacy run is not a discipline failure) and the note
# says so. The mixed case (some labelled, some not) is tested in the C scenario.
check "d-one missing tier"         "1"          "$(jq -r '.audit.packets_missing_tier' "$DOUT")"
check "d-one missing impl"         "1"          "$(jq -r '.audit.packets_missing_impl' "$DOUT")"
check "d-one in unlabelled ids"    "d-one"      "$(jq -r '.audit.unlabelled_packet_ids[]' "$DOUT")"
check "d-one flags suppressed"     "0"          "$(jq -r '[.packets[]|select(.id=="d-one").audit.flags[]|select(startswith("unlabelled:"))]|length' "$DOUT")"
check "d-one wholesale note"       "1"          "$(jq -r '[.notes[]|select(startswith("labels: NO packet"))]|length' "$DOUT")"
# env override wins over the .agents/autonomy file
check "autonomy env override" "full-autonomy" \
  "$(ORCH_AUTONOMY=full-autonomy "$METRICS" collect --main-root "$DREPO" --projects-dir "$ROOT/none" --out "$ROOT/drun2.json" >/dev/null 2>&1; jq -r '.autonomy' "$ROOT/drun2.json")"
# absent ok/model fields must read as UNMEASURED (null), never as "zero failures"
check "S1 failed_tool_calls null"  "null"       "$(jq -r '.totals.failed_tool_calls' "$OUT")"
check "S1 model-override null"     "null"       "$(jq -r '.audit.dispatches_with_model_override' "$OUT")"
check "S1 dispatches 0"            "0"          "$(jq -r '.audit.dispatches_total' "$OUT")"
check "S1 pre-instrumentation note" "1" \
  "$(jq -r '[.notes[]|select(startswith("instrumentation:"))]|length' "$OUT")"
# ...and the instrumented run must NOT carry that note
check "D1 no pre-instr note"       "0" \
  "$(jq -r '[.notes[]|select(startswith("instrumentation:"))]|length' "$DOUT")"

# =============================================================================
# ADR 0019 v3 — phantom-packet window bound, by_tool, sticky by_skill
# =============================================================================
echo
echo "== v3: trailer-scan upper bound (phantom-packet fix) =="
# One session with events at 10:00:01..10:00:05 and THREE packet commits:
#   in-window   (10:00:04) -> counted
#   just after  (10:00:30) -> counted. The grace exists because a run's LAST packet
#                             commits just AFTER its last tool event.
#   long after  (11 days)  -> PHANTOM, must NOT be counted. This is the bug that had
#                             an 11-minute session reporting 45 packets, and 12 of 19
#                             captured runs inflated 2x-45x.
PREPO="$ROOT/prepo"; mkdir -p "$PREPO/.agents/metrics/events"
git -C "$PREPO" init -q; git -C "$PREPO" config user.email t@t; git -C "$PREPO" config user.name t
pcommit() { echo "$2" >> "$PREPO/l.txt"; git -C "$PREPO" add -A
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$PREPO" commit -q -m "w

[orch packet:$2]"; }
pcommit "2026-07-21T10:00:04Z" "in-window"
pcommit "2026-07-21T10:00:30Z" "just-after"
pcommit "2026-08-01T10:00:00Z" "phantom-11-days-later"
cat > "$PREPO/.agents/metrics/events/P1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"P1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"cmd_class":"git status","ok":true}
{"ts":"2026-07-21T10:00:05Z","session_id":"P1","agent_id":"a1","agent_type":"implementer","tool":"Edit","duration_ms":20,"ok":true}
JSON
POUT="$ROOT/prun.json"
"$METRICS" collect --main-root "$PREPO" --projects-dir "$ROOT/none" --out "$POUT" >/dev/null 2>&1
check "phantom: packets counted"    "2"    "$(jq -r '.totals.packets' "$POUT")"
check "phantom: in-window kept"     "1"    "$(jq -r '[.packets[]|select(.id=="in-window")]|length' "$POUT")"
check "phantom: grace kept"         "1"    "$(jq -r '[.packets[]|select(.id=="just-after")]|length' "$POUT")"
check "phantom: 11-days-later DROP" "0"    "$(jq -r '[.packets[]|select(.id=="phantom-11-days-later")]|length' "$POUT")"
check "phantom: bound note"         "1"    "$(jq -r '[.notes[]|select(startswith("Trailer scan is bounded"))]|length' "$POUT")"
# the grace is a real knob, not a hardcoded constant
POUT2="$ROOT/prun2.json"
ORCH_METRICS_TRAILER_GRACE=5 "$METRICS" collect --main-root "$PREPO" \
  --projects-dir "$ROOT/none" --out "$POUT2" >/dev/null 2>&1
check "phantom: grace=5s tightens"  "1"    "$(jq -r '.totals.packets' "$POUT2")"
# an explicit --until is honored verbatim (no grace added on top of it)
POUT3="$ROOT/prun3.json"
"$METRICS" collect --main-root "$PREPO" --projects-dir "$ROOT/none" \
  --until "2026-07-21T10:00:10Z" --out "$POUT3" >/dev/null 2>&1
check "phantom: --until verbatim"   "1"    "$(jq -r '.totals.packets' "$POUT3")"

echo
echo "== v3: by_tool (the tool-SELECTION mix) =="
check "by_tool Bash calls"     "1"    "$(jq -r '.totals.by_tool.Bash.calls' "$POUT")"
check "by_tool Edit calls"     "1"    "$(jq -r '.totals.by_tool.Edit.calls' "$POUT")"
check "by_tool Bash duration"  "10"   "$(jq -r '.totals.by_tool.Bash.duration_ms' "$POUT")"
check "by_tool Grep absent"    "null" "$(jq -r '.totals.by_tool.Grep // "null"' "$POUT")"
check "by_tool note"           "1"    "$(jq -r '[.notes[]|select(startswith("by_tool is"))]|length' "$POUT")"
# per-packet by_tool: the Edit at 10:00:05 lands in the "just-after" packet window
check "pkt by_tool Edit"       "1"    "$(jq -r '.packets[]|select(.id=="just-after").by_tool.Edit' "$POUT")"

echo
echo "== v3: by_skill is populated and sticky =="
# The Skill TOOL is almost never called (a slash command emits no Skill event), so
# metrics-log.sh now stamps every event from a per-session state file. Events must
# attribute to the running skill, not pile up in "none".
SKREPO2="$ROOT/skrepo2"; mkdir -p "$SKREPO2/.agents/metrics/events"
git -C "$SKREPO2" init -q; git -C "$SKREPO2" config user.email t@t; git -C "$SKREPO2" config user.name t
echo a > "$SKREPO2/f.txt"; git -C "$SKREPO2" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:04Z" GIT_COMMITTER_DATE="2026-07-21T10:00:04Z" \
  git -C "$SKREPO2" commit -q -m "w

[orch packet:sk-one]"
cat > "$SKREPO2/.agents/metrics/events/K1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"K1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"skill":"gaffer:run-loop","ok":true}
{"ts":"2026-07-21T10:00:02Z","session_id":"K1","agent_id":"a1","agent_type":"implementer","tool":"Edit","duration_ms":20,"skill":"gaffer:run-loop","ok":true}
{"ts":"2026-07-21T10:00:03Z","session_id":"K1","agent_id":"a1","agent_type":"implementer","tool":"Bash","duration_ms":30,"skill":"gaffer:run-loop","ok":true}
JSON
KOUT2="$ROOT/skrun2.json"
"$METRICS" collect --main-root "$SKREPO2" --projects-dir "$ROOT/none" --out "$KOUT2" >/dev/null 2>&1
check "by_skill run-loop calls" "3"    "$(jq -r '.totals.by_skill["gaffer:run-loop"].tool_calls' "$KOUT2")"
check "by_skill no none bucket" "null" "$(jq -r '.totals.by_skill.none // "null"' "$KOUT2")"
check "by_skill sticky note"    "1"    "$(jq -r '[.notes[]|select(startswith("by_skill is STICKY"))]|length' "$KOUT2")"

echo
echo "== v3: metrics-skill.sh (UserPromptSubmit slash-command tracker) =="
SKHOOK="${HERE}/../hooks/metrics-skill.sh"
SH_EV="$ROOT/shrepo/.agents/metrics/events"
emit_prompt() { printf '{"session_id":"%s","prompt":%s}' "$1" "$2" \
  | ORCH_METRICS_DIR="$SH_EV" bash "$SKHOOK"; }
# stdout MUST stay empty — a UserPromptSubmit hook's stdout is injected into context
hout="$(emit_prompt "H1" '"/gaffer:run-loop --parallel"')"
check "skill hook prints nothing" ""                       "$hout"
check "skill hook records plugin" "gaffer:run-loop" "$(cat "$SH_EV/_state/H1.skill" 2>/dev/null)"
emit_prompt "H2" '"/metrics analyze"' >/dev/null
check "skill hook records bare"   "metrics"                "$(cat "$SH_EV/_state/H2.skill" 2>/dev/null)"
# prose that merely contains a slash is not an invocation
emit_prompt "H3" '"look at src/a/b.ts, the /usr path is not a command"' >/dev/null
check "skill hook ignores prose"  "0" "$([ -f "$SH_EV/_state/H3.skill" ] && echo 1 || echo 0)"
# a slash on a LATER line is not an invocation either
emit_prompt "H4" '"do the thing\nthen /gaffer:pause"' >/dev/null
check "skill hook first-line only" "0" "$([ -f "$SH_EV/_state/H4.skill" ] && echo 1 || echo 0)"
# malformed payload -> silent no-op, exit 0 (never break the run it observes)
printf 'not json' | ORCH_METRICS_DIR="$SH_EV" bash "$SKHOOK" >/dev/null 2>&1
check "skill hook survives garbage" "0" "$?"
# only the NAME is recorded — arguments are never persisted (privacy)
emit_prompt "H5" '"/gaffer:metrics collect --session abc123 --until now"' >/dev/null
check "skill hook drops args"     "gaffer:metrics"  "$(cat "$SH_EV/_state/H5.skill" 2>/dev/null)"

echo
if [ "$fail" -eq 0 ]; then
  printf 'test-metrics.sh: ALL %d checks passed\n' "$pass"; exit 0
else
  printf 'test-metrics.sh: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1
fi
