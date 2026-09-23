#!/usr/bin/env bash
# =============================================================================
# test-metrics.sh — regression sweep for the run-metrics core (ADR 0019 Tier 1)
# =============================================================================
# Exercises scripts/metrics.sh (the JOIN/ASSEMBLE core) and hooks/metrics-log.sh
# (the event logger) against SYNTHETIC fixtures — a throwaway git repo with
# `[orch packet:<id>]` trailers, a per-session event log, and fake Claude Code
# transcripts. No live agent, no real ~/.claude. Exit 0 = all passed (CI runs it on
# push). A behavior worth having is a behavior worth a test.
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

# --- .agents fixtures: event log, run-state ------------------------------------
mkdir -p "$REPO/.agents/metrics/events"
EV="$REPO/.agents/metrics/events/S1.jsonl"
cat > "$EV" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"S1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"cmd_class":"git status"}
{"ts":"2026-07-21T10:00:02Z","session_id":"S1","agent_id":"a1","agent_type":"implementer","tool":"Edit","duration_ms":20}
{"ts":"2026-07-21T10:00:03Z","session_id":"S1","agent_id":"a1","agent_type":"implementer","tool":"Bash","duration_ms":30,"cmd_class":"dotnet test"}
{"ts":"2026-07-21T10:00:04Z","session_id":"S1","agent_id":"a2","agent_type":"reviewer","tool":"Bash","duration_ms":40,"cmd_class":"git diff"}
{"ts":"2026-07-21T10:00:05Z","session_id":"S1","agent_id":"a1","agent_type":"implementer","tool":"Edit","duration_ms":50}
JSON

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

# --- packet-shape: pin $OUT's top-level key set (schema, run_id, mode, totals,
# packets, ...) so a future additive field is a deliberate one-line edit here, not a
# silent pass. self_host is excluded because it is ITSELF an additive field (see the
# self_host section below, which extends this same list rather than duplicating it) —
# append the new key here, in sorted order, when a legitimate new top-level field is
# added; do not delete this check just because it has "self_host" nowhere in its name.
PRE_SELFHOST_KEYS="audit autonomy by_agent_role generated_at mode notes packets run_id schema sessions token_diagnostics token_source totals window"
check "packet-shape: top-level key set unchanged" "$PRE_SELFHOST_KEYS" \
  "$(jq -r 'del(.self_host)|keys|sort|join(" ")' "$OUT")"

# --- dispatch-progress-metrics pin (T1): today's `collect` output for THIS fixture,
# captured before that feature added any field. Every later task in the feature deletes
# its own new fields (append each jq path to DPM_NEW_FIELDS) and this check proves what
# is left is byte-identical: packets[].edits, dispatched, by_agent_role, outcome and
# audit.review_dispatches keep their meaning. Never re-capture DPM_GOLDEN to make it
# pass — a difference here is a changed existing field, not a stale golden.
DPM_NEW_FIELDS=('.packets[].dispatches')   # jq paths added by dispatch-progress-metrics (T2: dispatches)
dpm_filter() {
  local f='del(.generated_at)' p
  for p in ${DPM_NEW_FIELDS[@]+"${DPM_NEW_FIELDS[@]}"}; do f="$f | del($p)"; done
  printf '%s' "$f"
}
dpm_view() { jq -S -c "$(dpm_filter)" "$1"; }
DPM_GOLDEN="$(cat <<'GOLDEN'
{"audit":{"by_dispatch_model_override":null,"by_tier":{},"configured_routing":null,"dispatches_total":0,"dispatches_with_model_override":null,"flagged_packets":[],"implementer_dispatches":0,"labels_present":false,"orchestrator_impl_edits":0,"packets_missing_impl":2,"packets_missing_tier":2,"packets_total":2,"unlabelled_packet_ids":["feat-001","feat-002"]},"autonomy":"unknown","by_agent_role":{"implementer":{"cc_shape":{"cc_over_50k":0,"max":100,"median":100,"p90":100,"turns":1,"turns_over_50k":0},"models":{"claude-sonnet-5":{"cache_creation":100,"cache_read":1000,"input":300,"output":150}},"tokens":{"cache_creation":100,"cache_read":1000,"input":300,"output":150}},"main":{"cc_shape":{"cc_over_50k":0,"max":200,"median":200,"p90":200,"turns":2,"turns_over_50k":0},"models":{"claude-opus-4-8":{"cache_creation":200,"cache_read":1200,"input":200,"output":100}},"tokens":{"cache_creation":200,"cache_read":1200,"input":200,"output":100}},"reviewer":{"cc_shape":{"cc_over_50k":0,"max":0,"median":0,"p90":0,"turns":1,"turns_over_50k":0},"models":{"claude-opus-4-8":{"cache_creation":0,"cache_read":600,"input":40,"output":20}},"tokens":{"cache_creation":0,"cache_read":600,"input":40,"output":20}}},"mode":"parallel","notes":["token_source=transcript: version-fragile on-disk parse (ADR 0019 Open Q1).","Per-packet token split needs per-turn transcript timestamps; packets[].tokens is null when absent.","Token turns are bounded to the run window (ADR 0019 window-bleed fix); ts==null turns are kept unwindowed.","Guard ASK-tier prompt frequency is not captured in v1 (PostToolUse hook sees allowed calls only).","Packet rows come from [orch packet:<id>] commit trailers AND runstate.sh record-start/record-outcome/sweep-open attestations (loop-measurement T4): a packet the loop started now appears even if it never committed (failed, rolled-back) or was interrupted mid-run. totals.outcome_coverage says whether that instrumentation is present for THIS run: `unmeasured` with no record-start boundary at all (pre-feature or a non-loop run — never infer completeness from packet count), `incomplete` when a started packet still lacks a terminal outcome, `complete` otherwise.","Trailer scan is bounded at BOTH ends: [win_start, last-event + grace] (grace=ORCH_METRICS_TRAILER_GRACE, default 3600s), or --until verbatim. Before this the upper bound was open, so a retrospective collect absorbed packets committed by every later run.","Trailer times are AUTHOR dates, not committer dates (v3.2): committer date is rewritten by rebase/cherry-pick/squash-merge, which moved packets into whichever run last replayed the branch and dropped in-window work whose merge landed later.","The trailer grace is CAPPED at the earliest event of any other session after win_end (v3.2), so commits made by a concurrent or back-to-back session cannot be claimed by this run; the full grace applies only when nothing else was running.","by_skill is STICKY: set by the most recent slash-command/Skill invocation and never cleared, so it is an UPPER BOUND on the spend of that skill, not an exact span.","totals.context_invalidations counts turns where `effort` or the model CHANGED within one agent context — each re-writes the whole cached prefix, so its cost scales with how deep in the context the change happened, not with which direction it went. An empty by_effort means the transcripts predate the per-turn `effort` field (unmeasured), not that effort never changed.","by_tool is the tool-SELECTION mix (Bash/Read/Edit/Grep/...); shell `grep`/`find`/`sed` showing up in by_command_class while Grep/Glob sit at zero here is context waste, not search volume.","active/idle from inter-event gaps (idle_gap_seconds); unattributed_tool_calls = events outside all packet windows.","totals.same_file_overlaps counts (main session, subagent) pairs that edited the SAME file: the span of a subagent is its first-to-last event, the main session pairs with it only through its own edit events falling inside that span, and a pair counts once no matter how many files it shares. This replaces the mechanical file-disjointness guarantee parallel mode used to provide, now that the guarantee is gone; it never logs a path, only opaque file hashes.","same_file_overlaps=unmeasured: 2 of 2 edit event(s) in this run carry no file_hash (pre-instrumentation hook, or a hash the hook could not compute).","audit.* cross-checks the executor [orch tier:/impl:] self-label against who actually edited (impl_edits_by_role) and what was dispatched; leak = opus orchestrator wrote code without dispatching the implementer.","audit.dispatches_with_model_override counts dispatches whose passed model DIFFERS from the routing resolved at dispatch (the routing.sh resolve value the hook stamped: the model_routing map value when the agent is mapped, no model when it is not). A dispatch passing its resolved value is policy, not an override; a mapped agent dispatched with no model is keyed \"(none)\" in by_dispatch_model_override. audit.configured_routing is the routing table of the latest stamped dispatch (null = unmeasured). Read by_agent_role.<role>.models for what each role actually ran on.","labels: NO packet in this run carries a [orch tier:]/[orch impl:] trailer — routing is entirely UNMEASURED for this run (legacy or convention off), not clean; per-packet unlabelled flags are suppressed (run-loop §3.2/§3.4).","instrumentation: no event carries `ok` — this run PREDATES the ok/model hook capture, so failed_tool_calls and dispatches_with_model_override are null (unmeasured), NOT zero."],"packets":[{"active_seconds":1,"audit":{"flags":[],"implementer_dispatched":false,"orchestrator_impl_edits":0,"review_dispatches":0},"by_agent":{"implementer":2},"by_command_class":{"dotnet test":1},"by_tool":{"Bash":1,"Edit":1},"dispatched":{},"duration_ms":50,"edits":null,"end":"2026-07-21T10:00:03Z","failed_tool_calls":0,"human_interactions":0,"id":"feat-001","impl":null,"impl_edits_by_role":{"implementer":1},"outcome":null,"start":"2026-07-21T10:00:01Z","swept":false,"tier":null,"tokens":{"cache_creation":300,"cache_read":1800,"input":400,"output":200},"tool_calls":2},{"active_seconds":1,"audit":{"flags":[],"implementer_dispatched":false,"orchestrator_impl_edits":0,"review_dispatches":0},"by_agent":{"implementer":1,"reviewer":1},"by_command_class":{"git diff":1},"by_tool":{"Bash":1,"Edit":1},"dispatched":{},"duration_ms":90,"edits":null,"end":"2026-07-21T10:00:06Z","failed_tool_calls":0,"human_interactions":0,"id":"feat-002","impl":null,"impl_edits_by_role":{"implementer":1},"outcome":null,"start":"2026-07-21T10:00:03Z","swept":false,"tier":null,"tokens":{"cache_creation":0,"cache_read":1000,"input":140,"output":70},"tool_calls":2}],"run_id":"feat-001","schema":2,"self_host":false,"sessions":["S1"],"token_diagnostics":{"duplicate_turns_dropped":0,"transcript_dir":"present","transcript_files_matched":3,"transcript_files_present":3,"usage_turns":4,"usage_turns_in_window":4},"token_source":"transcript","totals":{"by_command_class":{"dotnet test":{"calls":1,"duration_ms":30},"git diff":{"calls":1,"duration_ms":40},"git status":{"calls":1,"duration_ms":10}},"by_effort":{},"by_model":{"claude-opus-4-8":{"cache_creation":200,"cache_read":1800,"input":240,"output":120},"claude-sonnet-5":{"cache_creation":100,"cache_read":1000,"input":300,"output":150}},"by_role_duration_ms":{"implementer":100,"main":10,"reviewer":40},"by_skill":{"none":{"duration_ms":150,"tool_calls":5}},"by_tool":{"Bash":{"calls":3,"duration_ms":80},"Edit":{"calls":2,"duration_ms":70}},"cache_hit_ratio":0.903,"context_invalidations":{"cache_creation":0,"count":0,"events":[]},"driver_mode_context":{"max_context":null,"threshold":null},"driver_mode_context_diagnostics":{"turns_in_window":0,"windows":0},"driver_mode_edit_diagnostics":{"edit_events":2,"edit_events_missing_agents_dir":2},"driver_mode_edits_outside_agents":null,"duration_ms":150,"failed_tool_calls":null,"human_interactions":0,"outcome_counts":{},"outcome_coverage":"unmeasured","packets":2,"same_file_overlap_diagnostics":{"edit_events":2,"edit_events_missing_hash":2},"same_file_overlaps":null,"started_without_outcome":2,"tokens":{"cache_creation":300,"cache_read":2800,"input":540,"output":270},"tool_calls":5,"unattributed_by_agent":{"main":1},"unattributed_tool_calls":1},"window":{"active_seconds":4,"end":"2026-07-21T10:00:05Z","idle_seconds":0,"start":"2026-07-21T10:00:01Z","wall_seconds":4}}
GOLDEN
)"
if [ "$(dpm_view "$OUT")" = "$DPM_GOLDEN" ]; then
  ok "dpm pin: collect output minus new fields byte-identical to pre-feature"
else
  bad "dpm pin: collect output minus new fields byte-identical to pre-feature" \
      "differing fields (< pre-feature, > now):"
  diff <(printf '%s\n' "$DPM_GOLDEN" | jq -S .) <(dpm_view "$OUT" | jq -S .) \
    | head -40 | sed 's/^/       /'
fi
# The pin must go red when an existing field it guards is altered — one mutation each.
dpm_mutant() { # dpm_mutant <label> <jq mutation>
  local m="$ROOT/dpm-mutant.json"
  jq "$2" "$OUT" > "$m"
  if [ "$(dpm_view "$m")" != "$DPM_GOLDEN" ]; then ok "dpm pin red under mutation: $1"
  else bad "dpm pin red under mutation: $1" "altered output still matched the golden"; fi
}
dpm_mutant "packets[].edits"         '.packets[0].edits = 3'
dpm_mutant "dispatched[]"            '.packets[1].dispatched = {"implementer": 1}'
dpm_mutant "audit.review_dispatches" '.packets[0].audit.review_dispatches = 1'

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
check "pkt feat-001 tool_calls"  "2" "$(jq -r '.packets[]|select(.id=="feat-001").tool_calls' "$OUT")"
check "pkt feat-001 implementer" "2" "$(jq -r '.packets[]|select(.id=="feat-001").by_agent.implementer' "$OUT")"
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

echo "== ADR 0019 v3.1: a CRLF-emitting jq (native Windows build) must not break the join =="
# The native Windows jq opens stdout in TEXT mode, so EVERY line ends \r\n — on pipes
# too, not just consoles. `$(jq …)` hides it (MSYS bash strips a trailing \r\n) but
# `read` keeps the \r, so the session-id list handed the transcript globs a value one
# byte too long: `<uuid>\r.jsonl` matched nothing and collect stamped token_source=none
# on EVERY Windows run while every structural number stayed correct.
#
# Reproduce that build on ANY platform with a shim that CRLF-ifies jq's stdout. It uses
# awk, NOT `sed 's/$/\r/'` — BSD/macOS sed does not interpret \r in the RHS and would
# insert a literal 'r', so the sed form would silently test nothing on macOS. On a
# machine whose real jq ALREADY emits CRLF the shim doubles it (\r\r\n), which the
# `tr -d '\r'` fix also handles — a strictly harsher test, so the case is meaningful
# on Windows and POSIX alike.
SHIM="$ROOT/shim"; mkdir -p "$SHIM"
REAL_JQ="$(command -v jq)"                      # resolve BEFORE the shim is on PATH
cat > "$SHIM/jq" <<SHIMEOF
#!/usr/bin/env bash
"$REAL_JQ" "\$@" | awk '{ printf "%s\r\n", \$0 }'
exit "\${PIPESTATUS[0]}"
SHIMEOF
chmod +x "$SHIM/jq"
# Sanity: the shim must actually emit a CR, else everything below proves nothing.
# 'ab' + CR + LF = 4 bytes (5 if the real jq already CRLFs and the shim doubled it).
crlf_probe="$(PATH="$SHIM:$PATH" jq -rn '"ab","cd"' 2>/dev/null | head -1 | wc -c | tr -d ' ')"
if [ "${crlf_probe:-0}" -gt 3 ]; then ok "shim emits CR (${crlf_probe} bytes for 'ab')"
else bad "shim emits CR" "got ${crlf_probe} bytes; shim is not simulating Windows jq"; fi

CRLFOUT="$ROOT/crlf.json"
PATH="$SHIM:$PATH" "$METRICS" collect --main-root "$REPO" --projects-dir "$PROJ" --out "$CRLFOUT" >/dev/null 2>&1
jq -e . "$CRLFOUT" >/dev/null 2>&1 && ok "CRLF-jq packet valid JSON" || bad "CRLF-jq packet valid JSON"
check "CRLF-jq: token_source"          "transcript" "$(jq -r '.token_source' "$CRLFOUT")"
check "CRLF-jq: tokens.input"          "540"        "$(jq -r '.totals.tokens.input' "$CRLFOUT")"
check "CRLF-jq: tokens.output"         "270"        "$(jq -r '.totals.tokens.output' "$CRLFOUT")"
check "CRLF-jq: transcripts matched"   "3"          "$(jq -r '.token_diagnostics.transcript_files_matched' "$CRLFOUT")"
check "CRLF-jq: structural unchanged"  "2"          "$(jq -r '.totals.packets' "$CRLFOUT")"
# Strongest form: a CRLF jq must produce a BYTE-IDENTICAL packet (bar the timestamp).
# On failure PRINT THE DIFF — "expected [same] got [differs]" names nothing, and this
# check is the one most likely to trip on a platform the author cannot run locally.
if [ "$(jq -S 'del(.generated_at)' "$CRLFOUT")" = "$(jq -S 'del(.generated_at)' "$OUT")" ]; then
  ok "CRLF-jq: packet identical to clean run"
else
  bad "CRLF-jq: packet identical to clean run" "differing fields (< clean, > CRLF-jq):"
  diff <(jq -S 'del(.generated_at)' "$OUT") <(jq -S 'del(.generated_at)' "$CRLFOUT") \
    | head -40 | sed 's/^/       /'
fi

echo "== ADR 0019 v3.1: token_source=none says WHICH failure it was =="
# `none` used to conflate "nothing on disk" with "files exist but none opened", and the
# note asserted "no transcript found" in both — the wording that made the CRLF bug cost
# a half-hour bisect while 29 transcripts sat on disk.
check "diag: dir absent"        "absent" "$(jq -r '.token_diagnostics.transcript_dir' "$OUT2")"
check "diag: nothing matched"   "0"      "$(jq -r '.token_diagnostics.transcript_files_matched' "$OUT2")"
# The CRLF signature exactly: transcripts present, none matching this run's session ids.
PROJ2="$ROOT/projects2"; mkdir -p "$PROJ2/proj"
cp "$PROJ/proj/S1.jsonl" "$PROJ2/proj/OTHERSESSION.jsonl"
LKOUT="$ROOT/lookup.json"
"$METRICS" collect --main-root "$REPO" --projects-dir "$PROJ2" --out "$LKOUT" >/dev/null 2>&1
check "diag: files present"     "1"    "$(jq -r '.token_diagnostics.transcript_files_present' "$LKOUT")"
check "diag: files matched"     "0"    "$(jq -r '.token_diagnostics.transcript_files_matched' "$LKOUT")"
check "diag: token_source"      "none" "$(jq -r '.token_source' "$LKOUT")"
check "diag: note names the LOOKUP failure" "1" \
  "$(jq -r '[.notes[]|select(contains("LOOKUP FAILURE"))]|length' "$LKOUT")"
check "diag: note does NOT claim an empty disk" "0" \
  "$(jq -r '[.notes[]|select(contains("no transcript files on disk"))]|length' "$LKOUT")"

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

echo "== hook routing stamp: routing_resolved + routing_table on Agent events (per-agent-model-routing T2) =="
# Run from inside a throwaway checkout (no ORCH_METRICS_DIR) so the hook resolves
# main_root and passes `--root` to routing.sh; the real agents/ dir supplies the
# frontmatter (implementer: sonnet), so `implementer: opus` is a table entry.
RTREPO="$ROOT/rtrepo"; mkdir -p "$RTREPO/.agents"; git -C "$RTREPO" init -q
printf 'model_routing:\n  implementer: opus\n' > "$RTREPO/.agents/project-overrides.yaml"
rt() { ( cd "$RTREPO" && printf '%s' "$1" | "$HOOK" >/dev/null 2>&1 ); }
rt '{"session_id":"RT1","tool_name":"Agent","agent_id":"","agent_type":"main","tool_use_id":"rt-mapped","tool_input":{"subagent_type":"gaffer:implementer"}}'
rt '{"session_id":"RT1","tool_name":"Agent","agent_id":"","agent_type":"main","tool_use_id":"rt-unmapped","tool_input":{"subagent_type":"reviewer"}}'
rt '{"session_id":"RT1","tool_name":"Bash","agent_id":"","agent_type":"main","tool_use_id":"rt-bash","tool_input":{"command":"git status"}}'
RTL="$RTREPO/.agents/metrics/events/RT1.jsonl"
check "routing stamp: mapped agent resolves to the alias" "opus" \
  "$(jq -r 'select(.tool_use_id=="rt-mapped").routing_resolved' "$RTL")"
check "routing stamp: mapped agent carries the table" '{"implementer":"opus"}' \
  "$(jq -c 'select(.tool_use_id=="rt-mapped").routing_table' "$RTL")"
check "routing stamp: unmapped agent resolves to explicit \"\"" '""' \
  "$(jq -c 'select(.tool_use_id=="rt-unmapped").routing_resolved' "$RTL")"
check "routing stamp: unmapped agent still carries the table" '{"implementer":"opus"}' \
  "$(jq -c 'select(.tool_use_id=="rt-unmapped").routing_table' "$RTL")"
check "routing stamp: non-Agent event carries neither field" "false false" \
  "$(jq -r 'select(.tool_use_id=="rt-bash") | "\(has("routing_resolved")) \(has("routing_table"))"' "$RTL")"
# routing.sh unavailable: CLAUDE_PLUGIN_ROOT at an empty dir -> both fields absent,
# stdout empty, exit 0.
RTEMPTY="$ROOT/rt-empty-plugin-root"; mkdir -p "$RTEMPTY"
RTOUT="$( cd "$RTREPO" && printf '%s' '{"session_id":"RT2","tool_name":"Agent","agent_id":"","agent_type":"main","tool_input":{"subagent_type":"implementer"}}' \
  | CLAUDE_PLUGIN_ROOT="$RTEMPTY" "$HOOK" 2>/dev/null )"; RTRC=$?
check "routing stamp: script missing -> hook exits 0" "0" "$RTRC"
check "routing stamp: script missing -> hook stdout empty" "" "$RTOUT"
check "routing stamp: script missing -> both fields absent (event still logged)" "Agent false false" \
  "$(jq -r '"\(.tool) \(has("routing_resolved")) \(has("routing_table"))"' "$RTREPO/.agents/metrics/events/RT2.jsonl" 2>/dev/null)"

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
# ...including the fixed-rules marker (retire-autonomy-levels T6): "writes nothing"
# means nothing, so a disabled hook must not leave a session looking post-install.
[ ! -f "$HREPO/.agents/metrics/events/_state/H1.fixed-rules" ] \
  && ok "disabled hook writes no fixed-rules marker" \
  || bad "disabled hook writes no fixed-rules marker" "marker should not exist"

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
# retire-autonomy-levels T6: the same call leaves a ZERO-BYTE `_state/<sid>.fixed-rules`
# marker — the only thing metrics.sh now reads for the run's level. It must add no field
# to the event line (asserted by the base-key check above), no growth to the log, and
# nothing to stdout; a second call must not grow it either (`:>>`, never a rewrite).
MARK="$HREPO/.agents/metrics/events/_state/H1.fixed-rules"
[ -f "$MARK" ] && ok "hook wrote the fixed-rules marker" || bad "hook wrote the fixed-rules marker"
check "fixed-rules marker is zero-byte" "0" "$(wc -c < "$MARK" 2>/dev/null | tr -d ' ')"
STDOUT2="$(printf '%s' "$payload" | ORCH_METRICS_DIR="$HREPO/.agents/metrics/events" "$HOOK" 2>/dev/null)"
HRC2=$?
check "hook stdout still empty on the marker path" "" "$STDOUT2"
check "hook exits 0 on the marker path"            "0" "$HRC2"
check "fixed-rules marker stays zero-byte on re-fire" "0" "$(wc -c < "$MARK" 2>/dev/null | tr -d ' ')"
# an UNWRITABLE _state dir must not change any of that (fail-silent, exit 0)
RO="$ROOT/ro-hook"; mkdir -p "$RO/_state"; chmod 500 "$RO/_state"
ROOUT="$(printf '%s' '{"session_id":"RO1","tool_name":"Bash","agent_id":"","agent_type":"main"}' \
  | ORCH_METRICS_DIR="$RO" "$HOOK" 2>/dev/null)"; RORC=$?
check "hook stdout empty when _state is unwritable" "" "$ROOUT"
check "hook exits 0 when _state is unwritable"      "0" "$RORC"
chmod 700 "$RO/_state"

echo "== widened matcher: non-mutating tools (Task, Read) are logged too =="
WREPO="$ROOT/wrepo"; mkdir -p "$WREPO"; git -C "$WREPO" init -q
WEV="$WREPO/.agents/metrics/events"
for tp in Task Read; do
  printf '%s' "{\"session_id\":\"W1\",\"tool_name\":\"$tp\",\"agent_id\":\"\",\"agent_type\":\"main\"}" \
    | ORCH_METRICS_DIR="$WEV" "$HOOK" >/dev/null 2>&1
done
# `tr -d '\r'`: jq emits multi-line raw output, and the native Windows build CRLFs it.
# Command substitution strips only the LAST \r, so the joined value would carry an
# interior CR ("Read\r Task") — the harness-side twin of the collector bug fixed above.
check "Task + Read both logged" "Read Task" \
  "$(jq -r '.tool' "$WEV/W1.jsonl" 2>/dev/null | tr -d '\r' | sort | paste -sd' ' - | sed 's/ *$//')"

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

echo "== ADR 0019: ok/model/interactivity instrumentation =="
DREPO="$ROOT/drepo"; mkdir -p "$DREPO"
git -C "$DREPO" init -q
git -C "$DREPO" config user.email t@t; git -C "$DREPO" config user.name t
echo a > "$DREPO/f"; git -C "$DREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T14:00:05Z" GIT_COMMITTER_DATE="2026-07-21T14:00:05Z" \
  git -C "$DREPO" commit -q -m "work

[orch packet:d-one]"
mkdir -p "$DREPO/.agents/metrics/events"
# d-one window (:01,:05]: 3 `dotnet test` runs of which 2 FAILED (ok:false) = rework;
# one dispatch passing a model, one plain — both UNSTAMPED (no routing_resolved),
# so the override count is unmeasured here; one human question.
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
check "run failed_tool_calls"      "2"          "$(jq -r '.totals.failed_tool_calls' "$DOUT")"
check "run human_interactions"     "1"          "$(jq -r '.totals.human_interactions' "$DOUT")"
check "pkt failed_tool_calls"      "2"          "$(jq -r '.packets[]|select(.id=="d-one").failed_tool_calls' "$DOUT")"
check "pkt human_interactions"     "1"          "$(jq -r '.packets[]|select(.id=="d-one").human_interactions' "$DOUT")"
# rework proxy: 3 dotnet test invocations inside one packet
check "pkt rework proxy (test x3)" "3"          "$(jq -r '.packets[]|select(.id=="d-one").by_command_class["dotnet test"]' "$DOUT")"
# dispatch-model OVERRIDES (per-agent-model-routing). These D1 Agent events carry
# NO routing stamp (pre-routing hook), so the override count is UNMEASURED: judging
# them would need the routing resolved at dispatch, which was never recorded.
check "dispatches_total"           "2"          "$(jq -r '.audit.dispatches_total' "$DOUT")"
check "dispatch model overrides null (Agent events unstamped, pre-routing)" "null" "$(jq -r '.audit.dispatches_with_model_override' "$DOUT")"
check "by_dispatch_model_override null (Agent events unstamped, pre-routing)" "null" "$(jq -r '.audit.by_dispatch_model_override' "$DOUT")"
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
# absent ok/model fields must read as UNMEASURED (null), never as "zero failures"
check "S1 failed_tool_calls null"  "null"       "$(jq -r '.totals.failed_tool_calls' "$OUT")"
check "S1 model-override null"     "null"       "$(jq -r '.audit.dispatches_with_model_override' "$OUT")"
check "S1 dispatches 0"            "0"          "$(jq -r '.audit.dispatches_total' "$OUT")"
check "S1 pre-instrumentation note" "1" \
  "$(jq -r '[.notes[]|select(startswith("instrumentation:"))]|length' "$OUT")"
# ...and the instrumented run must NOT carry that note
check "D1 no pre-instr note"       "0" \
  "$(jq -r '[.notes[]|select(startswith("instrumentation:"))]|length' "$DOUT")"

echo "== retire-autonomy-levels: the level comes from the hook's marker, not env or a level file =="
# Autonomy levels are retired, so `autonomy` is no longer "what is configured now" but
# "did every session in this window run under the one fixed rule set" — answered solely
# by the `_state/<sid>.fixed-rules` markers hooks/metrics-log.sh writes. Two sessions in
# one repo let a window be all-marked, part-marked or unmarked without rebuilding it.
# NOTE the fixture name: `$ROOT/arepo` is already taken TWICE in this sweep (the adhoc
# run_id case and the author-date case both build one), and sharing a repo means sharing
# its events dir — a stray third session log made `--all-sessions` here read a window we
# never wrote. Fixtures whose selection rule is "every session" need their OWN repo.
FXREPO="$ROOT/fxrepo"; mkdir -p "$FXREPO/.agents/metrics/events/_state"
FXST="$FXREPO/.agents/metrics/events/_state"
git -C "$FXREPO" init -q
git -C "$FXREPO" config user.email t@t; git -C "$FXREPO" config user.name t
echo a > "$FXREPO/f"; git -C "$FXREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T15:00:05Z" GIT_COMMITTER_DATE="2026-07-21T15:00:05Z" \
  git -C "$FXREPO" commit -q -m "work

[orch packet:fx-one]"
printf '{"ts":"2026-07-21T15:00:01Z","session_id":"F1","agent_id":"","agent_type":"main","tool":"Bash","cmd_class":"git status","ok":true}\n' \
  > "$FXREPO/.agents/metrics/events/F1.jsonl"
printf '{"ts":"2026-07-21T15:00:02Z","session_id":"F2","agent_id":"","agent_type":"main","tool":"Bash","cmd_class":"git status","ok":true}\n' \
  > "$FXREPO/.agents/metrics/events/F2.jsonl"
acollect() { # acollect <out-name> <collect args...> -> prints .autonomy
  local o="$ROOT/$1.json"; shift
  "$METRICS" collect --main-root "$FXREPO" --projects-dir "$ROOT/none" --out "$o" "$@" >/dev/null 2>&1
  jq -r '.autonomy' "$o" 2>/dev/null
}
# a pre-install window — no session left a marker — re-collects as UNKNOWN, which
# means UNMEASURED, never some other level.
check "autonomy: no marker -> unknown" "unknown" "$(acollect fx-none --session F1)"
: > "$FXST/F1.fixed-rules"
check "autonomy: marker present -> full-autonomy" "full-autonomy" "$(acollect fx-marked --session F1)"
# a window MIXING a marked and an unmarked session cannot claim the marked one's
# answer — the rule is EVERY selected session, not the newest or the majority.
check "autonomy: mixed window -> unknown" "unknown" "$(acollect fx-mixed --all-sessions)"
: > "$FXST/F2.fixed-rules"
check "autonomy: every session marked -> full-autonomy" "full-autonomy" "$(acollect fx-both --all-sessions)"
# no sessions selected at all is not vacuously full-autonomy
check "autonomy: no sessions -> unknown" "unknown" "$(acollect fx-nosess --session NOPE)"
# the two retired inputs are DEAD, not merely deprioritised: both present, both ignored.
printf '# Default autonomy level for this repo.\n#   interactive | supervised | autonomous\n\nautonomous\n' \
  > "$FXREPO/.agents/autonomy"
check "autonomy: ORCH_AUTONOMY + .agents/autonomy ignored when marked" "full-autonomy" \
  "$(ORCH_AUTONOMY=interactive acollect fx-env --all-sessions)"
rm -f "$FXST/F1.fixed-rules" "$FXST/F2.fixed-rules"
check "autonomy: ORCH_AUTONOMY + .agents/autonomy ignored when unmarked" "unknown" \
  "$(ORCH_AUTONOMY=interactive acollect fx-env2 --all-sessions)"
# the field keeps its name and place: `show` still renders it the same way.
: > "$FXST/F1.fixed-rules"; : > "$FXST/F2.fixed-rules"
acollect fx-show --all-sessions >/dev/null
check "autonomy: show still renders the field" "1" \
  "$("$METRICS" show "$ROOT/fx-show.json" | grep -c 'autonomy: full-autonomy')"

echo "== routing audit: override = passed model differs from the stamped routing (per-agent-model-routing T5) =="
# Each case is its own throwaway repo + one session so a count isolates ONE dispatch
# shape. Fixture routing: implementer (frontmatter sonnet) mapped to opus; reviewer
# (frontmatter opus) unmapped. routing_resolved "" = the dispatch should pass nothing.
rcollect() { # rcollect <name> <events-jsonl> -> prints the run-metrics.json path
  local r="$ROOT/route-$1"; mkdir -p "$r/.agents/metrics/events"
  git -C "$r" init -q; git -C "$r" config user.email t@t; git -C "$r" config user.name t
  echo a > "$r/f"; git -C "$r" add -A
  GIT_AUTHOR_DATE="2026-07-22T09:00:05Z" GIT_COMMITTER_DATE="2026-07-22T09:00:05Z" \
    git -C "$r" commit -q -m "work

[orch packet:$1-p]"
  printf '%s\n' "$2" > "$r/.agents/metrics/events/R$1.jsonl"
  "$METRICS" collect --main-root "$r" --projects-dir "$ROOT/none" --out "$r/out.json" >/dev/null 2>&1 \
    || bad "routing $1: collect exits 0" "collect returned nonzero"
  printf '%s\n' "$r/out.json"
}
RT_MAP='"routing_table":{"implementer":"opus"}'
RB='"ts":"2026-07-22T09:00:01Z","session_id":"R","agent_id":"","agent_type":"main","ok":true'
R0="$(rcollect maprouted "{$RB,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:implementer\",\"model\":\"opus\",\"routing_resolved\":\"opus\",$RT_MAP}")"
check "routing: map-routed dispatch counts 0" "0" "$(jq -r '.audit.dispatches_with_model_override' "$R0")"
check "routing: map-routed by_dispatch_model_override empty" "{}" "$(jq -c '.audit.by_dispatch_model_override' "$R0")"
R1="$(rcollect offmap "{$RB,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:reviewer\",\"model\":\"haiku\",\"routing_resolved\":\"\",$RT_MAP}")"
check "routing: off-map model counts 1" "1" "$(jq -r '.audit.dispatches_with_model_override' "$R1")"
check "routing: off-map keyed by passed model" "1" "$(jq -r '.audit.by_dispatch_model_override.haiku' "$R1")"
R2="$(rcollect backtofm "{$RB,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:implementer\",\"model\":\"sonnet\",\"routing_resolved\":\"opus\",$RT_MAP}")"
check "routing: mapped agent sent back to its frontmatter model counts 1" "1" "$(jq -r '.audit.dispatches_with_model_override' "$R2")"
R3="$(rcollect ownfm "{$RB,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:reviewer\",\"model\":\"opus\",\"routing_resolved\":\"\",$RT_MAP}")"
check "routing: unmapped agent passed its own frontmatter model counts 1" "1" "$(jq -r '.audit.dispatches_with_model_override' "$R3")"
check "routing: unmapped own-frontmatter keyed by passed model" "1" "$(jq -r '.audit.by_dispatch_model_override.opus' "$R3")"
R4="$(rcollect nomodel "{$RB,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:implementer\",\"routing_resolved\":\"opus\",$RT_MAP}")"
check "routing: mapped agent passed nothing counts 1" "1" "$(jq -r '.audit.dispatches_with_model_override' "$R4")"
check "routing: passed-nothing override keyed (none)" "1" "$(jq -r '.audit.by_dispatch_model_override["(none)"]' "$R4")"
R5="$(rcollect unmappedplain "{$RB,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:reviewer\",\"routing_resolved\":\"\",\"routing_table\":{}}")"
check "routing: unmapped agent passing nothing counts 0" "0" "$(jq -r '.audit.dispatches_with_model_override' "$R5")"
check "routing: empty table records as {}" "{}" "$(jq -c '.audit.configured_routing' "$R5")"
# configured_routing = the LATEST stamped table by PARSED ts. 09:00:02.500Z is later
# than 09:00:02Z but sorts BEFORE it as a string ("." < "Z"), so a string sort would
# pick the reviewer-less first table; the parse must pick the later one.
RCFG="$(rcollect latest "{\"ts\":\"2026-07-22T09:00:02.500Z\",\"session_id\":\"R\",\"agent_id\":\"\",\"agent_type\":\"main\",\"ok\":true,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:reviewer\",\"model\":\"fable\",\"routing_resolved\":\"fable\",\"routing_table\":{\"implementer\":\"opus\",\"reviewer\":\"fable\"}}
{\"ts\":\"2026-07-22T09:00:02Z\",\"session_id\":\"R\",\"agent_id\":\"\",\"agent_type\":\"main\",\"ok\":true,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:implementer\",\"model\":\"opus\",\"routing_resolved\":\"opus\",$RT_MAP}")"
check "routing: configured_routing equals the latest stamped table" '{"implementer":"opus","reviewer":"fable"}' "$(jq -c '.audit.configured_routing' "$RCFG")"
check "routing: both dispatches map-routed across a mid-run change" "0" "$(jq -r '.audit.dispatches_with_model_override' "$RCFG")"
check "routing: mid-run change note names 2 distinct tables" "1" \
  "$(jq -r '[.notes[]|select(startswith("routing: model routing CHANGED mid-run") and contains("2 distinct routing tables"))]|length' "$RCFG")"
check "routing: single-table run has no mid-run note" "0" \
  "$(jq -r '[.notes[]|select(startswith("routing: model routing CHANGED"))]|length' "$R0")"
# legacy: instrumented (ok present) but the hook predates the routing stamp
RLEG="$(rcollect legacy "{$RB,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:implementer\",\"model\":\"sonnet\"}")"
check "routing: legacy unstamped configured_routing null" "null" "$(jq -r '.audit.configured_routing' "$RLEG")"
check "routing: legacy unstamped override count null" "null" "$(jq -r '.audit.dispatches_with_model_override' "$RLEG")"
RMIX="$(rcollect mixed "{$RB,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:implementer\",\"model\":\"opus\",\"routing_resolved\":\"opus\",$RT_MAP}
{$RB,\"tool\":\"Agent\",\"subagent_type\":\"gaffer:reviewer\",\"model\":\"sonnet\"}")"
check "routing: mixed-stamp run override count null" "null" "$(jq -r '.audit.dispatches_with_model_override' "$RMIX")"
check "routing: mixed-stamp run note (1 of 2 unstamped)" "1" \
  "$(jq -r '[.notes[]|select(contains("1 of 2 dispatches carry no routing stamp"))]|length' "$RMIX")"
check "routing: mixed-stamp configured_routing from the stamped event" '{"implementer":"opus"}' "$(jq -c '.audit.configured_routing' "$RMIX")"
RNONE="$(rcollect nodispatch "{$RB,\"tool\":\"Bash\",\"cmd_class\":\"git status\"}")"
check "routing: no dispatches counts 0" "0" "$(jq -r '.audit.dispatches_with_model_override' "$RNONE")"
check "routing: no dispatches configured_routing null" "null" "$(jq -r '.audit.configured_routing' "$RNONE")"
check "routing: fully-stamped run carries no unstamped note" "0" \
  "$(jq -r '[.notes[]|select(contains("carry no routing stamp"))]|length' "$R0")"
# show: null must render as unmeasured, {} as none, a table as "<agent> <alias>"
check "show routing: null renders unmeasured — pre-routing run" "1" \
  "$("$METRICS" show "$RLEG" 2>/dev/null | grep -c 'configured routing: unmeasured — pre-routing run')"
check "show routing: {} renders none" "1" \
  "$("$METRICS" show "$R5" 2>/dev/null | grep -c 'configured routing: none$')"
check "show routing: table renders agent alias" "1" \
  "$("$METRICS" show "$RCFG" 2>/dev/null | grep -c 'configured routing: implementer opus, reviewer fable')"
check "show routing: null override count not rendered as 0" "1" \
  "$("$METRICS" show "$RMIX" 2>/dev/null | grep -c 'model overrides vs routing resolved at dispatch: unmeasured')"
check "show routing: no // {} or // 0 fallback on routing fields" "0" \
  "$(grep -cE '(configured_routing|dispatches_with_model_override|by_dispatch_model_override) // (\{\}|0)' "$METRICS")"

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
echo "== v3.2: trailer times are AUTHOR dates, not committer dates =="
# Committer date is rewritten by rebase/cherry-pick/squash-merge; author date is not.
# Both real failure modes, observed in a production repo:
#   (a) work AUTHORED in-window whose merge/rebase moved its COMMITTER date after the
#       window -> was silently DROPPED from the run that actually did it.
#   (b) work AUTHORED before the window (a prior run) whose merge landed INSIDE this
#       window -> was silently ABSORBED into a run that never touched it.
AREPO="$ROOT/arepo"; mkdir -p "$AREPO/.agents/metrics/events"
git -C "$AREPO" init -q; git -C "$AREPO" config user.email t@t; git -C "$AREPO" config user.name t
acommit() { # acommit <author-iso> <committer-iso> <packet-id>
  echo "$3" >> "$AREPO/l.txt"; git -C "$AREPO" add -A
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$2" git -C "$AREPO" commit -q -m "w

[orch packet:$3]"; }
# (a) authored in-window, replayed (committed) 11 days later
acommit "2026-07-21T10:00:04Z" "2026-08-01T10:00:00Z" "authored-in-window"
# (b) authored 11 days BEFORE, merged into this window
acommit "2026-07-10T09:00:00Z" "2026-07-21T10:00:05Z" "authored-earlier-run"
cat > "$AREPO/.agents/metrics/events/A1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"A1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"ok":true}
{"ts":"2026-07-21T10:00:06Z","session_id":"A1","agent_id":"a1","agent_type":"implementer","tool":"Edit","duration_ms":20,"ok":true}
JSON
AOUT="$ROOT/arun.json"
"$METRICS" collect --main-root "$AREPO" --projects-dir "$ROOT/none" --out "$AOUT" >/dev/null 2>&1
check "authordate: in-window KEPT"    "1" "$(jq -r '[.packets[]|select(.id=="authored-in-window")]|length' "$AOUT")"
check "authordate: earlier run DROP"  "0" "$(jq -r '[.packets[]|select(.id=="authored-earlier-run")]|length' "$AOUT")"
check "authordate: total packets"     "1" "$(jq -r '.totals.packets' "$AOUT")"
check "authordate: note"              "1" "$(jq -r '[.notes[]|select(startswith("Trailer times are AUTHOR"))]|length' "$AOUT")"

echo
echo "== v3.2: the trailer grace is capped at the next session's first event =="
# A flat grace reaches into whatever ran next. Session N1 ends 10:00:02; a commit at
# 10:00:30 sits inside the default 3600s grace, but session N2 is already running and
# owns it. Measured in a real repo as 7 phantom rows / 6 duplicated packet ids.
NREPO="$ROOT/nrepo"; mkdir -p "$NREPO/.agents/metrics/events"
git -C "$NREPO" init -q; git -C "$NREPO" config user.email t@t; git -C "$NREPO" config user.name t
ncommit() { echo "$2" >> "$NREPO/l.txt"; git -C "$NREPO" add -A
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$NREPO" commit -q -m "w

[orch packet:$2]"; }
ncommit "2026-07-21T10:00:02Z" "n1-own"
ncommit "2026-07-21T10:00:30Z" "n2-owns-this"
cat > "$NREPO/.agents/metrics/events/N1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"N1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"ok":true}
{"ts":"2026-07-21T10:00:02Z","session_id":"N1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"ok":true}
JSON
# N2 starts at :10 — before the :30 commit, so the grace must collapse to :10
cat > "$NREPO/.agents/metrics/events/N2.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:10Z","session_id":"N2","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"ok":true}
{"ts":"2026-07-21T10:00:40Z","session_id":"N2","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"ok":true}
JSON
NOUT="$ROOT/nrun.json"
"$METRICS" collect --main-root "$NREPO" --projects-dir "$ROOT/none" --session N1 --out "$NOUT" >/dev/null 2>&1
check "nextcap: own packet kept"      "1" "$(jq -r '[.packets[]|select(.id=="n1-own")]|length' "$NOUT")"
check "nextcap: next session NOT claimed" "0" "$(jq -r '[.packets[]|select(.id=="n2-owns-this")]|length' "$NOUT")"
check "nextcap: note"                 "1" "$(jq -r '[.notes[]|select(startswith("The trailer grace is CAPPED"))]|length' "$NOUT")"
# with nothing else running, the SAME commit is legitimately inside the grace
rm -f "$NREPO/.agents/metrics/events/N2.jsonl"
NOUT2="$ROOT/nrun2.json"
"$METRICS" collect --main-root "$NREPO" --projects-dir "$ROOT/none" --session N1 --out "$NOUT2" >/dev/null 2>&1
check "nextcap: grace still applies"  "1" "$(jq -r '[.packets[]|select(.id=="n2-owns-this")]|length' "$NOUT2")"

echo
echo "== v3.2: by_effort and context_invalidations =="
# Effort is a per-turn request parameter the user can change mid-session. Changing it
# (or the model) invalidates the cached prefix, so the whole context is re-written to
# cache. Production: three flips cost 372,588 / 380,005 / 115,509 cacheC against
# session medians of 1,380 / 856 / ~1,700.
EREPO="$ROOT/erepo"; mkdir -p "$EREPO/.agents/metrics/events"
git -C "$EREPO" init -q; git -C "$EREPO" config user.email t@t; git -C "$EREPO" config user.name t
echo a > "$EREPO/f.txt"; git -C "$EREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:05Z" GIT_COMMITTER_DATE="2026-07-21T10:00:05Z" \
  git -C "$EREPO" commit -q -m "w

[orch packet:eff-one]"
cat > "$EREPO/.agents/metrics/events/E1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"E1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"ok":true}
{"ts":"2026-07-21T10:00:06Z","session_id":"E1","agent_id":"b1","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":20,"ok":true}
{"ts":"2026-07-21T10:00:07Z","session_id":"E1","agent_id":"b2","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":20,"ok":true}
JSON
EPROJ="$ROOT/eproj"; mkdir -p "$EPROJ/proj/E1/subagents"
# main: high, high, then a flip to xhigh -> ONE invalidation carrying 9000 cacheC
cat > "$EPROJ/proj/E1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T10:00:02Z","effort":"high","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":10}}}
{"type":"assistant","timestamp":"2026-07-21T10:00:03Z","effort":"high","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":10}}}
{"type":"assistant","timestamp":"2026-07-21T10:00:04Z","effort":"xhigh","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":9000,"cache_read_input_tokens":10}}}
JSON
# two SEPARATE implementer dispatches on different models: normal tier routing across
# two contexts, NOT a mid-context switch -> must not register as an invalidation.
cat > "$EPROJ/proj/E1/subagents/agent-b1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T10:00:06Z","effort":"high","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":50,"cache_read_input_tokens":10}}}
JSON
cat > "$EPROJ/proj/E1/subagents/agent-b2.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T10:00:07Z","effort":"high","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":50,"cache_read_input_tokens":10}}}
JSON
EOUT="$ROOT/erun.json"
"$METRICS" collect --main-root "$EREPO" --projects-dir "$EPROJ" --out "$EOUT" >/dev/null 2>&1
check "effort: token_source"        "transcript" "$(jq -r '.token_source' "$EOUT")"
check "effort: high turns"          "4"    "$(jq -r '.totals.by_effort.high.turns' "$EOUT")"
check "effort: xhigh turns"         "1"    "$(jq -r '.totals.by_effort.xhigh.turns' "$EOUT")"
check "effort: xhigh cacheC"        "9000" "$(jq -r '.totals.by_effort.xhigh.cache_creation' "$EOUT")"
check "ctxinval: one change"        "1"    "$(jq -r '.totals.context_invalidations.count' "$EOUT")"
check "ctxinval: cost attributed"   "9000" "$(jq -r '.totals.context_invalidations.cache_creation' "$EOUT")"
check "ctxinval: from effort"       "high" "$(jq -r '.totals.context_invalidations.events[0].from.effort' "$EOUT")"
check "ctxinval: to effort"         "xhigh" "$(jq -r '.totals.context_invalidations.events[0].to.effort' "$EOUT")"
check "ctxinval: role"              "main" "$(jq -r '.totals.context_invalidations.events[0].role' "$EOUT")"
check "ctxinval: note"              "1"    "$(jq -r '[.notes[]|select(startswith("totals.context_invalidations"))]|length' "$EOUT")"
# separate dispatches of one role on different models are NOT a mid-context switch
check "ctxinval: no cross-dispatch FP" "0" \
  "$(jq -r '[.totals.context_invalidations.events[]|select(.role|test("implementer"))]|length' "$EOUT")"
# transcripts predating the `effort` field must leave the bucket ABSENT, never zeroed
check "effort: absent on legacy"    "0"    "$(jq -r '.totals.by_effort|length' "$OUT")"
check "ctxinval: legacy model-only" "0"    "$(jq -r '.totals.context_invalidations.count' "$OUT")"

echo "== v3.3: transcript turns are deduplicated by message.id =="
# A transcript records the SAME assistant message more than once (production: 3x for
# one id, at +2ms and +26s), each row carrying the full usage block. Summing rows
# inflated cacheCreation 2.3x-3.2x and output 3.3x-6.3x — at DIFFERENT rates, so it
# did not cancel in CC:out. Rows with no message.id must be kept verbatim: .uuid is
# per-ROW, so keying on it would dedupe nothing while appearing to work.
DREPO="$ROOT/drepo"; mkdir -p "$DREPO/.agents/metrics/events"
git -C "$DREPO" init -q; git -C "$DREPO" config user.email t@t; git -C "$DREPO" config user.name t
echo a > "$DREPO/f.txt"; git -C "$DREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:05Z" GIT_COMMITTER_DATE="2026-07-21T10:00:05Z" \
  git -C "$DREPO" commit -q -m "w

[orch packet:dup-one]"
cat > "$DREPO/.agents/metrics/events/D1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"D1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"ok":true}
{"ts":"2026-07-21T10:00:06Z","session_id":"D1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"ok":true}
JSON
DPROJ="$ROOT/dproj"; mkdir -p "$DPROJ/proj"
# msg_A appears 3x (the production shape). msg_B once. Two rows carry NO id at all.
# Deduped truth: 1000 (A) + 200 (B) + 70 + 70 (idless) = 1340 cacheC over 4 turns.
cat > "$DPROJ/proj/D1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T10:00:02.100Z","effort":"high","message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":40,"cache_creation_input_tokens":1000,"cache_read_input_tokens":10}}}
{"type":"assistant","timestamp":"2026-07-21T10:00:02.102Z","effort":"high","message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":40,"cache_creation_input_tokens":1000,"cache_read_input_tokens":10}}}
{"type":"assistant","timestamp":"2026-07-21T10:00:28.700Z","effort":"high","message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":40,"cache_creation_input_tokens":1000,"cache_read_input_tokens":10}}}
{"type":"assistant","timestamp":"2026-07-21T10:00:03Z","effort":"high","message":{"id":"msg_B","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":20,"cache_creation_input_tokens":200,"cache_read_input_tokens":10}}}
{"type":"assistant","timestamp":"2026-07-21T10:00:04Z","effort":"high","message":{"model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":70,"cache_read_input_tokens":10}}}
{"type":"assistant","timestamp":"2026-07-21T10:00:05Z","effort":"high","message":{"model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":70,"cache_read_input_tokens":10}}}
JSON
DOUT="$ROOT/drun.json"
"$METRICS" collect --main-root "$DREPO" --projects-dir "$DPROJ" --out "$DOUT" >/dev/null 2>&1
check "dedup: token_source"        "transcript" "$(jq -r '.token_source' "$DOUT")"
check "dedup: cacheC counted once" "1340" "$(jq -r '.totals.tokens.cache_creation' "$DOUT")"
check "dedup: output counted once" "74"   "$(jq -r '.totals.tokens.output' "$DOUT")"
check "dedup: rows dropped"        "2"    "$(jq -r '.token_diagnostics.duplicate_turns_dropped' "$DOUT")"
check "dedup: turns kept"          "4"    "$(jq -r '.token_diagnostics.usage_turns' "$DOUT")"
# idless rows must NOT collapse into one — under-dedupe is the safe direction.
# If they had collapsed, this would read 1270 over 3 turns instead of 1340 over 4.
check "dedup: idless rows kept"    "1340" "$(jq -r '.totals.by_model["claude-opus-5"].cache_creation' "$DOUT")"
# The EARLIEST duplicate must win. msg_A's latest row is at 10:00:28.7Z, PAST the
# window end (10:00:06Z) — so if the last row won instead, msg_A would be filtered
# out and this would read 3 turns / 340 cacheC. Keeping 4/1340 proves earliest won.
check "dedup: earliest row wins"   "4"    "$(jq -r '.token_diagnostics.usage_turns_in_window' "$DOUT")"

echo "== v3.3: show reports unmeasured counters as unmeasured, not as clean zeros =="
# The audit block already existed; what it did wrong was render null (a legacy run
# that predates the counter) as 0, which reads as "checked, nothing found".
SHOW_OUT="$("$METRICS" show "$EOUT" 2>/dev/null)"
check "show: audit present"        "1" "$(printf '%s\n' "$SHOW_OUT" | grep -c '^routing audit')"
check "show: override printed once" "1" "$(printf '%s\n' "$SHOW_OUT" | grep -c 'model overrides vs routing resolved at dispatch')"
# audit must come BEFORE the packets table, not be buried under it
check "show: audit above packets"  "before" \
  "$(printf '%s\n' "$SHOW_OUT" | awk '/^routing audit/{a=NR} /^packets \(id/{p=NR} END{print (a>0 && a<p) ? "before" : "after"}')"
# a legacy run must read as UNMEASURED, never as a clean zero
SHOW_LEG="$("$METRICS" show "$OUT" 2>/dev/null)"
check "show: legacy unmeasured"    "1" "$(printf '%s\n' "$SHOW_LEG" | grep -c 'model overrides vs routing resolved at dispatch: unmeasured')"
# the retracted cost claim must not come back in the by_tool heading
check "show: no waste claim"       "0" "$(printf '%s\n' "$SHOW_OUT" | grep -c 'is waste')"
# ...nor the retracted DENOMINATOR. 279M was the pre-dedup inflated figure (v3.3);
# quoting it anywhere makes shell search look 2.6x cheaper than it is.
check "show: no retracted 279M"    "0" "$(grep -c '279M lifetime' "$METRICS")"

# v3.4 outputs must be VISIBLE, not merely present in the JSON. ADR 0022 names
# cc_shape.max as the detector for whether the findings discipline is working, so a
# detector reachable only via `analyze` is one nobody reads on the run that matters —
# the same "real signal placed where nobody looks" failure v3.3 recorded once already.
# Assert the MEASURED branch, not just a heading — both branches start with "cc_shape",
# so grepping the heading alone would pass while printing "unmeasured".
check "show: cc_shape rendered"    "1" "$(printf '%s\n' "$SHOW_OUT" | grep -c 'median=.*p90=.*max=9000')"
check "show: cc_shape not unmeasured" "0" "$(printf '%s\n' "$SHOW_OUT" | grep -c '^cc_shape: unmeasured')"
# outcome must appear in the packets table, and render as ? (not green) when unattested
check "show: outcome column"       "1" "$(printf '%s\n' "$SHOW_OUT" | grep -c '^packets (id | outcome')"
check "show: null outcome is not green" "0" \
  "$(printf '%s\n' "$SHOW_OUT" | awk '/^packets \(id/{p=1;next} p&&/^  /{print}' | grep -c '| green |')"

echo "== v3.4: cc_shape separates standing-context size from per-turn cost =="
# Totals are too noisy to steer by (1.76x across untouched same-regime runs). The
# shape is not: median is flat everywhere while max tracks the payload being
# re-cached. Turns here: 100, 100, 9000 -> median 100, max 9000, one 50k+ spike absent.
check "cc_shape: turns"        "3"    "$(jq -r '.by_agent_role.main.cc_shape.turns' "$EOUT")"
check "cc_shape: median"       "100"  "$(jq -r '.by_agent_role.main.cc_shape.median' "$EOUT")"
check "cc_shape: max"          "9000" "$(jq -r '.by_agent_role.main.cc_shape.max' "$EOUT")"
check "cc_shape: no false spike" "0"  "$(jq -r '.by_agent_role.main.cc_shape.turns_over_50k' "$EOUT")"
# a real spike must be counted AND its cost attributed
SPIKE="$ROOT/spike.json"
mkdir -p "$ROOT/sproj/proj"
cat > "$ROOT/sproj/proj/E1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-21T10:00:02Z","effort":"high","message":{"id":"s1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":900,"cache_read_input_tokens":1}}}
{"type":"assistant","timestamp":"2026-07-21T10:00:03Z","effort":"high","message":{"id":"s2","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":120000,"cache_read_input_tokens":1}}}
JSON
"$METRICS" collect --main-root "$EREPO" --projects-dir "$ROOT/sproj" --out "$SPIKE" >/dev/null 2>&1
check "cc_shape: spike counted" "1"      "$(jq -r '.by_agent_role.main.cc_shape.turns_over_50k' "$SPIKE")"
check "cc_shape: spike cost"    "120000" "$(jq -r '.by_agent_role.main.cc_shape.cc_over_50k' "$SPIKE")"

echo "== v3.4: outcome is attested, never assumed green =="
# A packet exists only because a green-commit trailer was found, so inferring "green"
# from its presence is survivorship. Absent attestation must read null, not green.
check "outcome: null without log" "null" "$(jq -r '.packets[0].outcome' "$EOUT")"
mkdir -p "$EREPO/.agents/metrics/outcomes"
cat > "$EREPO/.agents/metrics/outcomes/E1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:08Z","packet":"eff-one","outcome":"failed"}
{"ts":"2026-07-21T10:00:09Z","packet":"eff-one","outcome":"green"}
JSON
OOUT="$ROOT/orun.json"
"$METRICS" collect --main-root "$EREPO" --projects-dir "$EPROJ" --out "$OOUT" >/dev/null 2>&1
# last record wins: failed-then-fixed is green now
check "outcome: attested wins"   "green" "$(jq -r '.packets[0].outcome' "$OOUT")"

# The outcomes join is scoped by SESSION and by the run WINDOW, like every other join
# here. Unscoped it globbed every outcome ever written and took a global last-wins, so
# a later run's verdict for a same-named packet overwrote this one's — the identical
# cross-run bleed v3/v3.2 fixed twice for commit trailers.
cat > "$EREPO/.agents/metrics/outcomes/E2-foreign.jsonl" <<'JSON'
{"ts":"2026-08-14T10:00:00Z","packet":"eff-one","outcome":"rolled-back"}
JSON
"$METRICS" collect --main-root "$EREPO" --projects-dir "$EPROJ" --out "$OOUT" >/dev/null 2>&1
check "outcome: a foreign session's file is not joined" "green" "$(jq -r '.packets[0].outcome' "$OOUT")"

# Same session, but stamped far outside the run window: the ts filter must drop it.
cat >> "$EREPO/.agents/metrics/outcomes/E1.jsonl" <<'JSON'
{"ts":"2026-09-01T10:00:00Z","packet":"eff-one","outcome":"abandoned"}
JSON
"$METRICS" collect --main-root "$EREPO" --projects-dir "$EPROJ" --out "$OOUT" >/dev/null 2>&1
check "outcome: an out-of-window record is not joined" "green" "$(jq -r '.packets[0].outcome' "$OOUT")"
rm -f "$EREPO/.agents/metrics/outcomes/E2-foreign.jsonl"

echo "== v3.4: edit overlap separates correction from division of labour =="
# Per-role edit COUNTS cannot tell "orchestrator fixed the implementer" from "they
# worked on different files". Overlap on the same file hash can. Values are opaque
# hashes from the hook — never paths — so this reports shape only.
XREPO="$ROOT/xrepo"; mkdir -p "$XREPO/.agents/metrics/events"
git -C "$XREPO" init -q; git -C "$XREPO" config user.email t@t; git -C "$XREPO" config user.name t
echo a > "$XREPO/f.txt"; git -C "$XREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:09Z" GIT_COMMITTER_DATE="2026-07-21T10:00:09Z" \
  git -C "$XREPO" commit -q -m "w

[orch packet:x-one]"
# fileA touched by implementer AND main (contended); fileB by implementer only.
cat > "$XREPO/.agents/metrics/events/X1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"X1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:02Z","session_id":"X1","agent_id":"i1","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":5,"ok":true,"file_hash":"aaaaaaaaaaaa"}
{"ts":"2026-07-21T10:00:03Z","session_id":"X1","agent_id":"i1","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":5,"ok":true,"file_hash":"bbbbbbbbbbbb"}
{"ts":"2026-07-21T10:00:04Z","session_id":"X1","agent_id":"","agent_type":"main","tool":"Edit","duration_ms":5,"ok":true,"file_hash":"aaaaaaaaaaaa"}
JSON
XOUT="$ROOT/xrun.json"
"$METRICS" collect --main-root "$XREPO" --projects-dir "$ROOT/none" --out "$XOUT" >/dev/null 2>&1
check "edits: total"            "3" "$(jq -r '.packets[0].edits.edits' "$XOUT")"
check "edits: distinct files"   "2" "$(jq -r '.packets[0].edits.files_touched' "$XOUT")"
check "edits: contended"        "1" "$(jq -r '.packets[0].edits.contended_files' "$XOUT")"
check "edits: contended by"     "1" "$(jq -r '.packets[0].edits.contended_by["gaffer:implementer+main"]' "$XOUT")"
# a run with no hashes at all is UNMEASURED, not zero-overlap
check "edits: null when absent" "null" "$(jq -r '.packets[0].edits' "$EOUT")"

# MultiEdit is on guard.sh's registered write surface, so it must be on this one too.
# It was missing from BOTH the hook's file_hash case and this filter, so multi-edit
# work read as zero edits — silently, since an absent hash looks like no edit at all.
cat >> "$XREPO/.agents/metrics/events/X1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:05Z","session_id":"X1","agent_id":"i1","agent_type":"gaffer:implementer","tool":"MultiEdit","duration_ms":5,"ok":true,"file_hash":"cccccccccccc"}
{"ts":"2026-07-21T10:00:06Z","session_id":"X1","agent_id":"","agent_type":"main","tool":"MultiEdit","duration_ms":5,"ok":true,"file_hash":"dddddddddddd"}
JSON
"$METRICS" collect --main-root "$XREPO" --projects-dir "$ROOT/none" --out "$XOUT" >/dev/null 2>&1
# `edits` keys off file_hash PRESENCE, so this pair guards the HOOK stamping a hash for
# MultiEdit at all (without it there is no hash and the edit is invisible)...
check "edits: MultiEdit counted"      "5" "$(jq -r '.packets[0].edits.edits' "$XOUT")"
check "edits: MultiEdit file counted" "4" "$(jq -r '.packets[0].edits.files_touched' "$XOUT")"
# ...and THIS guards the collector's own tool-name filter, which is a separate list.
# The routing audit counts orchestrator edits by tool name, so a missing MultiEdit
# there under-reports exactly the leak the audit exists to catch: the opus orchestrator
# writing code instead of dispatching the implementer. Two main-role edits now.
check "audit: MultiEdit counts as an orchestrator edit" "2" \
  "$(jq -r '.audit.orchestrator_impl_edits' "$XOUT")"
# and `show` must render the contention, using the real contended_by object shape —
# a `join` against the wrong shape errors and takes the whole jq program down with it.
XSHOW="$("$METRICS" show "$XOUT" 2>/dev/null)"
check "show: edits rendered"          "1" "$(printf '%s\n' "$XSHOW" | grep -c '^edits per packet')"
check "show: contention named"        "1" "$(printf '%s\n' "$XSHOW" | grep -c 'same file touched by gaffer:implementer+main')"
# and the hook must stamp a hash for it in the first place
check "hook: MultiEdit on write surface" "1" \
  "$(grep -c 'Edit|Write|MultiEdit|NotebookEdit)' "${HERE}/../hooks/metrics-log.sh")"

echo
echo "== retire-unused-loop-modes T3: same-file overlap between file-editing agents =="
# Parallel mode's mechanical file-disjointness guarantee is gone; this is the
# observability that replaces it. A subagent's span is its first-to-last event; the
# main session pairs with it only through the main session's OWN edit events falling
# INSIDE that span; a pair counts once no matter how many hashes it shares.
#
# i1 shares TWO files with main while main's edits sit inside i1's span -> ONE pair,
# not two (the "counts once" rule). i2 shares NO file with main even though main also
# edits inside i2's span -> must not add a pair. Expected total: 1.
OVREPO="$ROOT/ovrepo"; mkdir -p "$OVREPO"; git -C "$OVREPO" init -q
OVEV="$OVREPO/.agents/metrics/events"; mkdir -p "$OVEV"
cat > "$OVEV/OV1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"OV1","agent_id":"i1","agent_type":"gaffer:implementer","tool":"Edit","file_hash":"aaaaaaaaaaaa"}
{"ts":"2026-07-21T10:00:02Z","session_id":"OV1","agent_id":"","agent_type":"main","tool":"Edit","file_hash":"aaaaaaaaaaaa"}
{"ts":"2026-07-21T10:00:03Z","session_id":"OV1","agent_id":"","agent_type":"main","tool":"Edit","file_hash":"cccccccccccc"}
{"ts":"2026-07-21T10:00:04Z","session_id":"OV1","agent_id":"i1","agent_type":"gaffer:implementer","tool":"Edit","file_hash":"cccccccccccc"}
{"ts":"2026-07-21T10:00:05Z","session_id":"OV1","agent_id":"i2","agent_type":"gaffer:reviewer","tool":"Edit","file_hash":"dddddddddddd"}
{"ts":"2026-07-21T10:00:06Z","session_id":"OV1","agent_id":"","agent_type":"main","tool":"Edit","file_hash":"eeeeeeeeeeee"}
{"ts":"2026-07-21T10:00:07Z","session_id":"OV1","agent_id":"i2","agent_type":"gaffer:reviewer","tool":"Edit","file_hash":"ffffffffffff"}
JSON
OVOUT="$ROOT/ovrun.json"
"$METRICS" collect --main-root "$OVREPO" --projects-dir "$ROOT/none" --out "$OVOUT" >/dev/null 2>&1 \
  || bad "overlap collect exits 0" "collect returned nonzero"
check "overlap: measured (every edit carries a hash)" "1" \
  "$(jq -r '.totals.same_file_overlaps' "$OVOUT")"
check "overlap: main-subagent pair sharing two files counts ONCE" "1" \
  "$(jq -r '.totals.same_file_overlaps' "$OVOUT")"
check "overlap: no-shared-file subagent does not add a pair" "1" \
  "$(jq -r '.totals.same_file_overlaps' "$OVOUT")"
check "overlap: diagnostics count every edit event" "7" \
  "$(jq -r '.totals.same_file_overlap_diagnostics.edit_events' "$OVOUT")"
check "overlap: diagnostics report 0 missing hashes when measured" "0" \
  "$(jq -r '.totals.same_file_overlap_diagnostics.edit_events_missing_hash' "$OVOUT")"
check "overlap: show renders the measured count" "1" \
  "$(printf '%s\n' "$("$METRICS" show "$OVOUT" 2>/dev/null)" | grep -c '^same-file overlaps.*: 1$')"

echo "== retire-unused-loop-modes T3: a run with a hash-less edit event reads unmeasured =="
# $OUT (the S1 scenario at the top of this file) predates file_hash: its implementer
# Edit events carry no hash at all. 0 and unmeasured must never be conflated — this
# repo has already shipped a bug where `show` rendered a null as 0.
check "overlap: unmeasured (hash-less edit event) is null, not 0" "null" \
  "$(jq -r '.totals.same_file_overlaps' "$OUT")"
check "overlap: hash-less diagnostics name the missing count" "2" \
  "$(jq -r '.totals.same_file_overlap_diagnostics.edit_events_missing_hash' "$OUT")"
check "overlap: hash-less note explains why" "1" \
  "$(jq -r '[.notes[]|select(startswith("same_file_overlaps=unmeasured") and contains("carry no file_hash"))]|length' "$OUT")"
check "overlap: show renders unmeasured, not a bare 0" "1" \
  "$(printf '%s\n' "$("$METRICS" show "$OUT" 2>/dev/null)" | grep -c '^same-file overlaps.*: unmeasured')"

echo "== retire-unused-loop-modes T3: an event-less run reads unmeasured, not 0 =="
# $OUT3 (the BARE repo above) has no .agents/metrics/events directory at all.
check "overlap: unmeasured (no events) is null, not 0" "null" \
  "$(jq -r '.totals.same_file_overlaps' "$OUT3")"
check "overlap: event-less diagnostics are zeroed" "0" \
  "$(jq -r '.totals.same_file_overlap_diagnostics.edit_events' "$OUT3")"
check "overlap: event-less note explains why" "1" \
  "$(jq -r '[.notes[]|select(startswith("same_file_overlaps=unmeasured") and contains("no events"))]|length' "$OUT3")"

# --- packet-graph.yaml / wave map / by_lane are gone: metrics.sh must not depend on
# scripts/packet-graph.sh (a later task deletes it). A stray packet-graph.yaml must
# be silently ignored, not read.
GONEREPO="$ROOT/gonerepo"; mkdir -p "$GONEREPO/.agents"; git -C "$GONEREPO" init -q
echo 'waves:
  - wave: 1
    packets:
      - id: x' > "$GONEREPO/.agents/packet-graph.yaml"
GONEOUT="$ROOT/gonerun.json"
"$METRICS" collect --main-root "$GONEREPO" --projects-dir "$ROOT/none" --out "$GONEOUT" >/dev/null 2>&1 \
  || bad "packet-graph-ignored collect exits 0" "collect returned nonzero"
check "packet-graph.yaml present but unread: no wave key anywhere" "0" \
  "$(jq -r '[.. | objects | keys[]? | select(. == "wave")] | length' "$GONEOUT")"
check "packet-graph.yaml present but unread: no by_lane key" "0" \
  "$(jq -r '(.totals | has("by_lane")) | if . then 1 else 0 end' "$GONEOUT")"

echo
echo "== loop-measurement T4: packet rows come from records too, not just trailers =="
# Two packets in ONE run: "never-committed" started and failed with no commit at all
# (the collector must build a row for it from record-start/record-outcome alone), and
# "paused-one" started AND got a commit trailer (a pause committing unfinished work)
# but no terminal outcome — proving a trailer never implies green, and that a started
# record-only packet and a trailer-carrying one can coexist and order correctly.
# Fresh directory/session names (FC* = "failed, never-committed"): this repo's own
# fixture directories are reused by earlier sections under NREPO/NOUT/IREPO/IOUT, and
# reusing those paths here would additively pile these commits onto their git history.
FCREPO="$ROOT/fc-repo"; mkdir -p "$FCREPO/.agents/metrics/events" "$FCREPO/.agents/metrics/outcomes"
git -C "$FCREPO" init -q; git -C "$FCREPO" config user.email t@t; git -C "$FCREPO" config user.name t
echo a > "$FCREPO/f.txt"; git -C "$FCREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:05Z" GIT_COMMITTER_DATE="2026-07-21T10:00:05Z" \
  git -C "$FCREPO" commit -q -m "pause: unfinished work

[orch packet:paused-one]"
cat > "$FCREPO/.agents/metrics/events/FC1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"FC1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:06Z","session_id":"FC1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
JSON
cat > "$FCREPO/.agents/metrics/outcomes/FC1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:02.000Z","packet":"never-committed","session":"FC1","kind":"start"}
{"ts":"2026-07-21T10:00:03.000Z","packet":"never-committed","session":"FC1","outcome":"failed"}
{"ts":"2026-07-21T10:00:04.000Z","packet":"paused-one","session":"FC1","kind":"start"}
JSON
FCOUT="$ROOT/fc-run.json"
"$METRICS" collect --main-root "$FCREPO" --projects-dir "$ROOT/none" --out "$FCOUT" >/dev/null 2>&1
check "T4: never-committed packet appears"   "1"      "$(jq -r '[.packets[]|select(.id=="never-committed")]|length' "$FCOUT")"
check "T4: never-committed outcome=failed"   "failed" "$(jq -r '.packets[]|select(.id=="never-committed")|.outcome' "$FCOUT")"
check "T4: paused-one packet appears (trailer)" "1"   "$(jq -r '[.packets[]|select(.id=="paused-one")]|length' "$FCOUT")"
# the whole point: a pause commit's trailer must NOT read as green — it stays null,
# same as any unattested packet.
check "T4: paused commit trailer is not green" "null" "$(jq -r '.packets[]|select(.id=="paused-one")|.outcome' "$FCOUT")"
check "T4: totals.packets counts both"       "2"      "$(jq -r '.totals.packets' "$FCOUT")"

echo "== loop-measurement T4: an interruption swept by a LATER session is still joined =="
# sweep-open writes the closing record into the SWEEPING session's own log file, but
# copies ts/session VERBATIM from the start it closes. A collector that selects files
# by NAME (the pre-T4 shape) would miss this, because the closing record physically
# lives in a session (SW-B) this run never selects. Attribution must be by the
# record's OWN session/ts fields, not by which file it is sitting in.
SWREPO="$ROOT/sw-repo"; mkdir -p "$SWREPO/.agents/metrics/events" "$SWREPO/.agents/metrics/outcomes"
git -C "$SWREPO" init -q; git -C "$SWREPO" config user.email t@t; git -C "$SWREPO" config user.name t
cat > "$SWREPO/.agents/metrics/events/SW-A.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"SW-A","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:02Z","session_id":"SW-A","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
JSON
# session SW-A's own start record...
cat > "$SWREPO/.agents/metrics/outcomes/SW-A.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01.500Z","packet":"int-one","session":"SW-A","kind":"start"}
JSON
# ...closed by a LATER session SW-B's sweep-open, into SW-B's OWN file, naming SW-A's start.
cat > "$SWREPO/.agents/metrics/outcomes/SW-B.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01.500Z","packet":"int-one","session":"SW-A","outcome":"interrupted"}
JSON
SWOUT="$ROOT/sw-run.json"
"$METRICS" collect --main-root "$SWREPO" --projects-dir "$ROOT/none" --out "$SWOUT" >/dev/null 2>&1
check "T4: interrupted record joined despite living in a foreign file" "interrupted" \
  "$(jq -r '.packets[]|select(.id=="int-one")|.outcome' "$SWOUT")"
check "T4: interrupted packet counted once"  "1" "$(jq -r '.totals.packets' "$SWOUT")"

echo "== loop-measurement C1: a SWEPT packet's derived metrics are null, not a lying zero =="
# sweep-open closes an open packet by copying the boundary's ts VERBATIM into the
# terminal record (SW-B above closes int-one with the SAME ts SW-A's start carries:
# 10:00:01.500Z on both sides). That collapses the packet's window to zero width, so
# tool_calls/active_seconds/edits/etc must read null (unmeasured), never 0 (which
# would read as "this packet genuinely did nothing" -- the opposite of true for a
# packet the loop was mid-way through when its session died).
check "C1: swept packet is flagged"           "true" "$(jq -r '.packets[]|select(.id=="int-one")|.swept' "$SWOUT")"
check "C1: swept packet end is null"          "null" "$(jq -r '.packets[]|select(.id=="int-one")|.end' "$SWOUT")"
check "C1: swept packet tool_calls is null, not 0"    "null" "$(jq -r '.packets[]|select(.id=="int-one")|.tool_calls' "$SWOUT")"
check "C1: swept packet active_seconds is null, not 0" "null" "$(jq -r '.packets[]|select(.id=="int-one")|.active_seconds' "$SWOUT")"
check "C1: swept packet edits is null"        "null" "$(jq -r '.packets[]|select(.id=="int-one")|.edits' "$SWOUT")"
check "C1: swept packet dispatched is null"   "null" "$(jq -r '.packets[]|select(.id=="int-one")|.dispatched' "$SWOUT")"
check "C1: swept packet tokens is null"       "null" "$(jq -r '.packets[]|select(.id=="int-one")|.tokens' "$SWOUT")"
check "DPM T2: swept packet dispatches is null, not []" "null" "$(jq -c '.packets[]|select(.id=="int-one")|.dispatches' "$SWOUT")"
check "C1: notes name the swept packet"       "1" \
  "$(jq -r '[.notes[]|select(test("swept") and test("int-one"))]|length' "$SWOUT")"
SWSHOW="$("$METRICS" show "$SWOUT" 2>/dev/null)"
check "C1: show marks the swept packet"       "1" \
  "$(printf '%s\n' "$SWSHOW" | grep -c 'swept by a later session')"
check "C1: show does not print a bare null for tool_calls" "0" \
  "$(printf '%s\n' "$SWSHOW" | grep -c 'int-one .*null calls')"

# NEGATIVE case: a DIRECTLY recorded outcome (record-outcome, not sweep-open) with its
# own distinct/later ts is NOT swept -- it must keep its real measured fields, proving
# the detector keys on ts equality (the sweep signature), not on outcome value alone
# (both "interrupted" and "abandoned" can also be written directly).
DAREPO="$ROOT/da-repo"; mkdir -p "$DAREPO/.agents/metrics/events" "$DAREPO/.agents/metrics/outcomes"
git -C "$DAREPO" init -q; git -C "$DAREPO" config user.email t@t; git -C "$DAREPO" config user.name t
cat > "$DAREPO/.agents/metrics/events/DA1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"DA1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:02Z","session_id":"DA1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
JSON
cat > "$DAREPO/.agents/metrics/outcomes/DA1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00.500Z","packet":"abandoned-direct","session":"DA1","kind":"start"}
{"ts":"2026-07-21T10:00:03.000Z","packet":"abandoned-direct","session":"DA1","outcome":"abandoned"}
JSON
DAOUT="$ROOT/da-run.json"
"$METRICS" collect --main-root "$DAREPO" --projects-dir "$ROOT/none" --out "$DAOUT" >/dev/null 2>&1
check "C1: a directly-recorded (non-swept) abandoned is not flagged swept" "false" \
  "$(jq -r '.packets[]|select(.id=="abandoned-direct")|.swept' "$DAOUT")"
check "C1: its tool_calls stay measured, not nulled" "1" \
  "$(jq -r '.packets[]|select(.id=="abandoned-direct")|.tool_calls' "$DAOUT")"

echo "== packet-bundling T1: a commit with exactly ONE trailer is byte-identical to today =="
# Baseline for the bundled case below: a single trailer, plus the tier/impl
# routing trailers, on its own commit -- must read exactly as it did before the
# trailer scan learned to accumulate ids[] instead of overwriting a scalar.
PBSREPO="$ROOT/pbs-repo"; mkdir -p "$PBSREPO/.agents/metrics/events"
git -C "$PBSREPO" init -q; git -C "$PBSREPO" config user.email t@t; git -C "$PBSREPO" config user.name t
cat > "$PBSREPO/.agents/metrics/events/S1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"S1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"cmd_class":"git status"}
{"ts":"2026-07-21T10:00:02Z","session_id":"S1","agent_id":"a1","agent_type":"implementer","tool":"Edit","duration_ms":20}
JSON
echo x >> "$PBSREPO/log.txt"; git -C "$PBSREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:03Z" GIT_COMMITTER_DATE="2026-07-21T10:00:03Z" \
  git -C "$PBSREPO" commit -q -m "work

[orch packet:solo-001]
[orch tier:mechanical]
[orch impl:inline]"
PBSOUT="$ROOT/pbs-run.json"
"$METRICS" collect --main-root "$PBSREPO" --projects-dir "$ROOT/none" --out "$PBSOUT" >/dev/null 2>&1
check "PBS: exactly one packet row"           "1"          "$(jq -r '.packets|length' "$PBSOUT")"
check "PBS: id"                               "solo-001"   "$(jq -r '.packets[0].id' "$PBSOUT")"
check "PBS: tier"                             "mechanical" "$(jq -r '.packets[0].tier' "$PBSOUT")"
check "PBS: impl"                             "inline"     "$(jq -r '.packets[0].impl' "$PBSOUT")"
check "PBS: end is the commit's own author date" "2026-07-21T10:00:03Z" \
  "$(jq -r '.packets[0].end' "$PBSOUT")"
check "PBS: tool_calls stays measured (window (start,end])" "1" \
  "$(jq -r '.packets[0].tool_calls' "$PBSOUT")"
check "PBS: not flagged as a shared boundary" "0" \
  "$(jq -r '[.packets[0].audit.flags[]|select(.=="unmeasured:shared-packet-boundary")]|length' "$PBSOUT")"
check "PBS: not flagged swept"                "false" "$(jq -r '.packets[0].swept' "$PBSOUT")"

echo "== packet-bundling T1: a commit with MULTIPLE [orch packet:] trailers emits one row per trailer =="
# Same events/transcripts as the top-of-file single-trailer fixture (S1,
# feat-001/feat-002 -- see "collect (full: ...)" above, whose totals are pinned
# there: totals.tool_calls=5, totals.packets=2, tokens 540/270/300/2800,
# duration_ms=150, unattributed_tool_calls=1), but landed as ONE commit
# carrying BOTH trailers plus one shared [orch tier:]/[orch impl:] pair -- a
# bundled landing of two tasks in one commit. Proves a bundled commit now
# reads as N packet rows (message order), each labelled, with the derived
# per-packet fields carried on the first and nulled (not zeroed) on every
# sibling, while the RUN-LEVEL totals -- which sum over the whole event
# window, not over packet rows -- are unaffected by how the work was split
# into commits.
PBREPO="$ROOT/pb-repo"; mkdir -p "$PBREPO/.agents/metrics/events"
git -C "$PBREPO" init -q; git -C "$PBREPO" config user.email t@t; git -C "$PBREPO" config user.name t
cp "$EV" "$PBREPO/.agents/metrics/events/S1.jsonl"
echo bundled >> "$PBREPO/log.txt"; git -C "$PBREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:06Z" GIT_COMMITTER_DATE="2026-07-21T10:00:06Z" \
  git -C "$PBREPO" commit -q -m "work

[orch packet:feat-001]
[orch packet:feat-002]
[orch tier:integration]
[orch impl:delegated]"
PBOUT="$ROOT/pb-run.json"
"$METRICS" collect --main-root "$PBREPO" --projects-dir "$PROJ" --out "$PBOUT" >/dev/null 2>&1
check "PB: exactly one row per trailer"      "2" "$(jq -r '.packets|length' "$PBOUT")"
check "PB: row order is message order"       "feat-001 feat-002" \
  "$(jq -r '[.packets[].id]|join(" ")' "$PBOUT")"
check "PB: first row tier labelled"          "integration" "$(jq -r '.packets[0].tier' "$PBOUT")"
check "PB: first row impl labelled"          "delegated"   "$(jq -r '.packets[0].impl' "$PBOUT")"
check "PB: sibling row tier ALSO labelled"   "integration" "$(jq -r '.packets[1].tier' "$PBOUT")"
check "PB: sibling row impl ALSO labelled"   "delegated"   "$(jq -r '.packets[1].impl' "$PBOUT")"
check "PB: sibling end carries the commit's own author date, not null" \
  "2026-07-21T10:00:06Z" "$(jq -r '.packets[1].end' "$PBOUT")"
check "PB: first row's window is measured (real tool_calls)" "4" \
  "$(jq -r '.packets[0].tool_calls' "$PBOUT")"
check "PB: sibling tool_calls is null, not 0"     "null" "$(jq -r '.packets[1].tool_calls' "$PBOUT")"
check "PB: sibling active_seconds is null, not 0" "null" "$(jq -r '.packets[1].active_seconds' "$PBOUT")"
check "PB: sibling duration_ms is null, not 0"    "null" "$(jq -r '.packets[1].duration_ms' "$PBOUT")"
check "PB: sibling by_agent is null"              "null" "$(jq -r '.packets[1].by_agent' "$PBOUT")"
check "PB: sibling by_tool is null"               "null" "$(jq -r '.packets[1].by_tool' "$PBOUT")"
check "PB: sibling edits is null"                 "null" "$(jq -r '.packets[1].edits' "$PBOUT")"
check "PB: sibling by_command_class is null"      "null" "$(jq -r '.packets[1].by_command_class' "$PBOUT")"
check "PB: sibling failed_tool_calls is null"     "null" "$(jq -r '.packets[1].failed_tool_calls' "$PBOUT")"
check "PB: sibling human_interactions is null"    "null" "$(jq -r '.packets[1].human_interactions' "$PBOUT")"
check "PB: sibling dispatched is null"            "null" "$(jq -r '.packets[1].dispatched' "$PBOUT")"
check "PB: sibling tokens is null"                "null" "$(jq -r '.packets[1].tokens' "$PBOUT")"
check "DPM T2: sibling dispatches is null, not []" "null" "$(jq -c '.packets[1].dispatches' "$PBOUT")"
check "DPM T2: first bundle row dispatches is an array" "array" "$(jq -r '.packets[0].dispatches|type' "$PBOUT")"
check "PB: sibling audit.orchestrator_impl_edits is null too" "null" \
  "$(jq -r '.packets[1].audit.orchestrator_impl_edits' "$PBOUT")"
check "PB: sibling carries the shared-boundary audit flag" "1" \
  "$(jq -r '[.packets[1].audit.flags[]|select(.=="unmeasured:shared-packet-boundary")]|length' "$PBOUT")"
check "PB: first row does NOT carry the shared-boundary flag" "0" \
  "$(jq -r '[.packets[0].audit.flags[]|select(.=="unmeasured:shared-packet-boundary")]|length' "$PBOUT")"
# This fixture carries impl:delegated -- a sibling's window is always zero-width
# ($impl_dispatched derives from that window, so it reads false), which without
# the null-scoped flag filter would falsely accuse every delegated sibling of
# contradicting its own label. The label itself is not window-derived (it is the
# commit's trailer), so it must not be flagged from an interval this row already
# declares unmeasured.
check "PB: sibling does NOT carry a false label-contradiction flag" "0" \
  "$(jq -r '[.packets[1].audit.flags[]|select(startswith("label-contradiction:"))]|length' "$PBOUT")"
check "PB: sibling is not also flagged swept (a different unmeasured cause)" "false" \
  "$(jq -r '.packets[1].swept' "$PBOUT")"
check "PB: totals.packets matches the single-trailer fixture's"      "2"   "$(jq -r '.totals.packets' "$PBOUT")"
check "PB: totals.tool_calls matches the single-trailer fixture's"   "5"   "$(jq -r '.totals.tool_calls' "$PBOUT")"
check "PB: totals.tokens.input matches the single-trailer fixture's" "540" "$(jq -r '.totals.tokens.input' "$PBOUT")"
check "PB: totals.tokens.output matches the single-trailer fixture's" "270" "$(jq -r '.totals.tokens.output' "$PBOUT")"
check "PB: totals.tokens.cache_creation matches the single-trailer fixture's" "300" \
  "$(jq -r '.totals.tokens.cache_creation' "$PBOUT")"
check "PB: totals.tokens.cache_read matches the single-trailer fixture's" "2800" \
  "$(jq -r '.totals.tokens.cache_read' "$PBOUT")"
check "PB: totals.duration_ms matches the single-trailer fixture's"  "150" "$(jq -r '.totals.duration_ms' "$PBOUT")"
check "PB: totals.unattributed_tool_calls matches the single-trailer fixture's" "1" \
  "$(jq -r '.totals.unattributed_tool_calls' "$PBOUT")"

echo "== packet-bundling T1: same-second single-trailer commits sort deterministically =="
# Two UNRELATED single-trailer commits (both seq==1, so they tie on [end, seq])
# landing in the same author-date second must not depend on the awk dedup's
# hash-order iteration for their final order -- that is exactly the
# byte-identical-for-a-single-trailer-commit guarantee this feature promises.
# Landed id "same-sec-z" BEFORE "same-sec-a" so a hash-order regression would
# be free to put z first; the .id tie-break must put a first regardless.
TOREPO="$ROOT/to-repo"; mkdir -p "$TOREPO/.agents/metrics/events"
git -C "$TOREPO" init -q; git -C "$TOREPO" config user.email t@t; git -C "$TOREPO" config user.name t
# An events log is required to bound the trailer scan window (win_start/win_end):
# with no events, collection falls back to `<integration_branch>..HEAD`, which is
# empty here (this repo has only one branch), so the commits below would never be
# seen at all.
cat > "$TOREPO/.agents/metrics/events/S1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:08Z","session_id":"S1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":10,"cmd_class":"git status"}
JSON
echo z >> "$TOREPO/log.txt"; git -C "$TOREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:09Z" GIT_COMMITTER_DATE="2026-07-21T10:00:09Z" \
  git -C "$TOREPO" commit -q -m "work z

[orch packet:same-sec-z]"
echo a >> "$TOREPO/log.txt"; git -C "$TOREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:09Z" GIT_COMMITTER_DATE="2026-07-21T10:00:09Z" \
  git -C "$TOREPO" commit -q -m "work a

[orch packet:same-sec-a]"
TOOUT="$ROOT/to-run.json"
"$METRICS" collect --main-root "$TOREPO" --projects-dir "$ROOT/none" --out "$TOOUT" >/dev/null 2>&1
check "TO: same-second single-trailer commits sort by id, not hash order" "same-sec-a same-sec-z" \
  "$(jq -r '[.packets[].id]|join(" ")' "$TOOUT")"
check "TO: neither same-second row is flagged as a shared boundary" "0" \
  "$(jq -r '[.packets[]|.audit.flags[]|select(.=="unmeasured:shared-packet-boundary")]|length' "$TOOUT")"

echo "== packet-bundling T8: a bundle that did NOT land green nulls its later members =="
# A rolled-back bundle has no commit and so no [orch packet:] trailers -- its three
# members reach the collector ONLY through the record-only (recordjoin) join.
# record-start/record-outcome write one line per member per call, in ONE call, cursor
# id first (packet-bundling T3), all sharing one timestamp and one session -- so
# before this fix every member got the fixed `seq: 1` the trailer-FIRST value uses,
# which made $is_sibling false for members 2/3 too: they fell into the ordinary
# per-packet branch, whose $start collapses to the row before it (identical shared
# end), producing a REAL, honest-looking 0 for a window that never existed. The fix
# groups record-only ids by (session, ts) of their winning terminal record and gives
# each a seq ordinal from write order, so members 2/3 take the same null+flag path a
# trailer sibling already gets.
PB8REPO="$ROOT/pb8-repo"; mkdir -p "$PB8REPO/.agents/metrics/events" "$PB8REPO/.agents/metrics/outcomes"
git -C "$PB8REPO" init -q; git -C "$PB8REPO" config user.email t@t; git -C "$PB8REPO" config user.name t
cat > "$PB8REPO/.agents/metrics/events/BT8.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"BT8","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:02Z","session_id":"BT8","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:03Z","session_id":"BT8","agent_id":"a1","agent_type":"implementer","tool":"Edit","duration_ms":10}
JSON
# One record-start call and one record-outcome call, each writing the whole bundle in
# ONE go -- cursor id (bt8-a) first, then bt8-b, bt8-c -- all three lines per call
# sharing a single timestamp and session, exactly as runstate.sh's `record-start`/
# `record-outcome` write a bundle (packet-bundling T3).
cat > "$PB8REPO/.agents/metrics/outcomes/BT8.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00.500Z","packet":"bt8-a","session":"BT8","kind":"start"}
{"ts":"2026-07-21T10:00:00.500Z","packet":"bt8-b","session":"BT8","kind":"start"}
{"ts":"2026-07-21T10:00:00.500Z","packet":"bt8-c","session":"BT8","kind":"start"}
{"ts":"2026-07-21T10:00:06.000Z","packet":"bt8-a","session":"BT8","outcome":"rolled-back"}
{"ts":"2026-07-21T10:00:06.000Z","packet":"bt8-b","session":"BT8","outcome":"rolled-back"}
{"ts":"2026-07-21T10:00:06.000Z","packet":"bt8-c","session":"BT8","outcome":"rolled-back"}
JSON
PB8OUT="$ROOT/pb8-run.json"
"$METRICS" collect --main-root "$PB8REPO" --projects-dir "$ROOT/none" --out "$PB8OUT" >/dev/null 2>&1
check "PB8: three rows, no commit -- all record-only" "3" "$(jq -r '.packets|length' "$PB8OUT")"
check "PB8: row order is write order, cursor first" "bt8-a bt8-b bt8-c" \
  "$(jq -r '[.packets[].id]|join(" ")' "$PB8OUT")"
check "PB8: every row shares the same outcome"      "rolled-back rolled-back rolled-back" \
  "$(jq -r '[.packets[].outcome]|join(" ")' "$PB8OUT")"
check "PB8: cursor row (seq 1) is measured, not nulled" "2" \
  "$(jq -r '.packets[0].tool_calls' "$PB8OUT")"
check "PB8: cursor row is not flagged as a shared boundary" "0" \
  "$(jq -r '[.packets[0].audit.flags[]|select(.=="unmeasured:shared-packet-boundary")]|length' "$PB8OUT")"
check "PB8: cursor row is not swept"                 "false" "$(jq -r '.packets[0].swept' "$PB8OUT")"
check "PB8: sibling row 2 tool_calls is null, not 0" "null" "$(jq -r '.packets[1].tool_calls' "$PB8OUT")"
check "PB8: sibling row 3 tool_calls is null, not 0" "null" "$(jq -r '.packets[2].tool_calls' "$PB8OUT")"
check "PB8: sibling row 2 active_seconds is null, not 0" "null" "$(jq -r '.packets[1].active_seconds' "$PB8OUT")"
check "PB8: sibling row 3 active_seconds is null, not 0" "null" "$(jq -r '.packets[2].active_seconds' "$PB8OUT")"
check "PB8: sibling row 2 tokens is null"            "null" "$(jq -r '.packets[1].tokens' "$PB8OUT")"
check "PB8: sibling row 3 tokens is null"            "null" "$(jq -r '.packets[2].tokens' "$PB8OUT")"
check "PB8: sibling row 2 carries the shared-boundary flag" "1" \
  "$(jq -r '[.packets[1].audit.flags[]|select(.=="unmeasured:shared-packet-boundary")]|length' "$PB8OUT")"
check "PB8: sibling row 3 carries the shared-boundary flag" "1" \
  "$(jq -r '[.packets[2].audit.flags[]|select(.=="unmeasured:shared-packet-boundary")]|length' "$PB8OUT")"
check "PB8: sibling row 2 is not ALSO flagged swept"  "false" "$(jq -r '.packets[1].swept' "$PB8OUT")"
check "PB8: sibling row 3 is not ALSO flagged swept"  "false" "$(jq -r '.packets[2].swept' "$PB8OUT")"
check "PB8: sibling row 2 end still carries its own outcome ts, not null" \
  "2026-07-21T10:00:06.000Z" "$(jq -r '.packets[1].end' "$PB8OUT")"
check "PB8: totals.packets counts all three rows"    "3" "$(jq -r '.totals.packets' "$PB8OUT")"

echo "== packet-bundling T8: a LONE record-only packet (no sibling) is byte-identical to today =="
# Same shape as above but n=1 -- must NOT be treated as a bundle: seq stays 1 (the
# group-of-one case), so it is measured exactly like the never-committed/abandoned-
# direct fixtures above and carries no shared-boundary flag.
PB8LREPO="$ROOT/pb8l-repo"; mkdir -p "$PB8LREPO/.agents/metrics/events" "$PB8LREPO/.agents/metrics/outcomes"
git -C "$PB8LREPO" init -q; git -C "$PB8LREPO" config user.email t@t; git -C "$PB8LREPO" config user.name t
cat > "$PB8LREPO/.agents/metrics/events/BT8L.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"BT8L","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:02Z","session_id":"BT8L","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
JSON
cat > "$PB8LREPO/.agents/metrics/outcomes/BT8L.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00.500Z","packet":"bt8l-only","session":"BT8L","kind":"start"}
{"ts":"2026-07-21T10:00:03.000Z","packet":"bt8l-only","session":"BT8L","outcome":"failed"}
JSON
PB8LOUT="$ROOT/pb8l-run.json"
"$METRICS" collect --main-root "$PB8LREPO" --projects-dir "$ROOT/none" --out "$PB8LOUT" >/dev/null 2>&1
check "PB8L: one row"                       "1"      "$(jq -r '.packets|length' "$PB8LOUT")"
check "PB8L: outcome"                       "failed" "$(jq -r '.packets[0].outcome' "$PB8LOUT")"
check "PB8L: measured, not nulled"          "1"      "$(jq -r '.packets[0].tool_calls' "$PB8LOUT")"
check "PB8L: not flagged as a shared boundary" "0" \
  "$(jq -r '[.packets[0].audit.flags[]|select(.=="unmeasured:shared-packet-boundary")]|length' "$PB8LOUT")"
check "PB8L: not swept"                     "false"  "$(jq -r '.packets[0].swept' "$PB8LOUT")"

echo "== loop-measurement M1: one malformed ts anywhere does not zero every outcome =="
# ts_ms runs unconditionally over EVERY record in the outcomes log before any
# window filter narrows it; fromdateiso8601 THROWS on an unparseable value, and
# the caller-side `2>/dev/null || echo [] ` fallback used to turn that one bad
# record into an empty attributed.json for the WHOLE run -- every packet's
# outcome and record_end disappearing, not just the bad one's.
M1REPO="$ROOT/m1-repo"; mkdir -p "$M1REPO/.agents/metrics/events" "$M1REPO/.agents/metrics/outcomes"
git -C "$M1REPO" init -q; git -C "$M1REPO" config user.email t@t; git -C "$M1REPO" config user.name t
cat > "$M1REPO/.agents/metrics/events/M1S.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"M1S","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
JSON
cat > "$M1REPO/.agents/metrics/outcomes/M1S.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00.100Z","packet":"good-one","session":"M1S","kind":"start"}
{"ts":"2026-07-21T10:00:01.500Z","packet":"good-one","session":"M1S","outcome":"green"}
{"ts":"garbage","packet":"bad-one","session":"M1S","kind":"start"}
JSON
M1OUT="$ROOT/m1-run.json"
"$METRICS" collect --main-root "$M1REPO" --projects-dir "$ROOT/none" --out "$M1OUT" >/dev/null 2>&1
check "M1: collect exits 0 despite a malformed ts elsewhere in the log" "0" "$?"
check "M1: the unrelated packet's outcome survives the bad record" "green" \
  "$(jq -r '.packets[]|select(.id=="good-one")|.outcome' "$M1OUT")"

echo "== loop-measurement I1: packet windows compare by PARSED time, not string, at the event/turn join =="
# The bug this pins: a record-only packet's sub-second end ("...:05.500Z") sorts BELOW
# a whole-second event landing in the SAME second ("...:05Z") as a raw string, because
# "." (0x2E) < "Z" (0x5A) -- so the old `.ts > $start and .ts <= $p.end` string compare
# excluded a same-second event from the packet it belongs to and shifted it into the
# NEXT packet's window instead. p1-record ends sub-second (05.500Z, record-only, no
# trailer); p2-trailer ends whole-second (08Z, trailer commit). Events land at :01
# (before either window), :05 (same second as p1-record's end -- belongs to p1-record),
# :07 (belongs to p2-trailer) and :09 (after p2-trailer's end -- unattributed).
WIREPO="$ROOT/wi-repo"; mkdir -p "$WIREPO/.agents/metrics/events" "$WIREPO/.agents/metrics/outcomes"
git -C "$WIREPO" init -q; git -C "$WIREPO" config user.email t@t; git -C "$WIREPO" config user.name t
echo a > "$WIREPO/f.txt"; git -C "$WIREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:08Z" GIT_COMMITTER_DATE="2026-07-21T10:00:08Z" \
  git -C "$WIREPO" commit -q -m "packet: p2-trailer

[orch packet:p2-trailer]"
cat > "$WIREPO/.agents/metrics/events/WI1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"WI1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:05Z","session_id":"WI1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:07Z","session_id":"WI1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:09Z","session_id":"WI1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
JSON
cat > "$WIREPO/.agents/metrics/outcomes/WI1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00.100Z","packet":"p1-record","session":"WI1","kind":"start"}
{"ts":"2026-07-21T10:00:05.500Z","packet":"p1-record","session":"WI1","outcome":"green"}
JSON
WIOUT="$ROOT/wi-run.json"
"$METRICS" collect --main-root "$WIREPO" --projects-dir "$ROOT/none" --out "$WIOUT" >/dev/null 2>&1
check "I1: same-second event lands in the record-only packet it belongs to" "1" \
  "$(jq -r '.packets[]|select(.id=="p1-record")|.tool_calls' "$WIOUT")"
check "I1: same-second event does NOT also leak into the next packet" "1" \
  "$(jq -r '.packets[]|select(.id=="p2-trailer")|.tool_calls' "$WIOUT")"

echo "== loop-measurement T4: same-second records compare by PARSED time, not string =="
# The bug this regression pins directly: "...:01.500Z" (a T1-shaped sub-second stamp)
# sorts BELOW "...:01Z" (win_start, always whole-second) as a raw string, because "."
# (0x2E) sorts before "Z" (0x5A) — so a record landing in the SAME wall-clock second
# as win_start, logically at-or-after it, was silently dropped by a string compare
# (`(.ts // "") >= $ws`). win_start here is exactly "...:01Z" (the first event's ts)
# and the boundary/terminal records both land at "...:01.5xxZ"/"...:01.9xxZ" — the
# same second, sub-second. Under the pre-T4 string compare this run reports outcome
# `null` (both records dropped); with parsed-time comparison it reports `green`.
SSREPO="$ROOT/ss-repo"; mkdir -p "$SSREPO/.agents/metrics/events" "$SSREPO/.agents/metrics/outcomes"
git -C "$SSREPO" init -q; git -C "$SSREPO" config user.email t@t; git -C "$SSREPO" config user.name t
cat > "$SSREPO/.agents/metrics/events/SS1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"SS1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
{"ts":"2026-07-21T10:00:02Z","session_id":"SS1","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":5,"ok":true}
JSON
cat > "$SSREPO/.agents/metrics/outcomes/SS1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01.500Z","packet":"same-second","session":"SS1","kind":"start"}
{"ts":"2026-07-21T10:00:01.900Z","packet":"same-second","session":"SS1","outcome":"green"}
JSON
SSOUT="$ROOT/ss-run.json"
"$METRICS" collect --main-root "$SSREPO" --projects-dir "$ROOT/none" --out "$SSOUT" >/dev/null 2>&1
check "T4: same-second sub-second record is not dropped" "1" \
  "$(jq -r '[.packets[]|select(.id=="same-second")]|length' "$SSOUT")"
check "T4: same-second record's outcome is joined" "green" \
  "$(jq -r '.packets[]|select(.id=="same-second")|.outcome' "$SSOUT")"

echo "== loop-measurement T5: outcome_counts, started_without_outcome, outcome_coverage =="
# never-committed(failed) + paused-one(no outcome, open): failed tallied once,
# started_without_outcome=1 (paused-one), coverage=incomplete (NOT unmeasured — this
# run DOES carry record-start boundaries, it just has one still open).
check "T5: outcome_counts.failed"          "1"          "$(jq -r '.totals.outcome_counts.failed' "$FCOUT")"
check "T5: started_without_outcome"        "1"          "$(jq -r '.totals.started_without_outcome' "$FCOUT")"
check "T5: outcome_coverage=incomplete"    "incomplete" "$(jq -r '.totals.outcome_coverage' "$FCOUT")"
# int-one has both a start AND a terminal record -> fully covered. "complete" must
# NOT be read as "all green" — its only outcome is "interrupted".
check "T5: outcome_coverage=complete when every started packet is closed" "complete" \
  "$(jq -r '.totals.outcome_coverage' "$SWOUT")"
check "T5: started_without_outcome=0 when every started packet is closed" "0" \
  "$(jq -r '.totals.started_without_outcome' "$SWOUT")"
# a pre-feature run (no record-start boundary anywhere) must read UNMEASURED, never
# "complete" (which would silently claim 0 open packets) and never "incomplete"
# (which would silently claim every trailer packet is a known failure).
check "T5: pre-feature run reads outcome_coverage=unmeasured" "unmeasured" \
  "$(jq -r '.totals.outcome_coverage' "$OUT")"
# the replaced notes[] line must no longer claim failed/uncommitted packets are absent
check "T5: notes no longer claim uncommitted packets are absent" "0" \
  "$(jq -r '[.notes[]|select(test("failed/uncommitted packets do not appear"))]|length' "$FCOUT")"
check "T5: notes mention outcome_coverage" "1" \
  "$(jq -r '[.notes[]|select(test("outcome_coverage"))]|length' "$FCOUT")"

echo "== loop-measurement T6: show labels never render an unmeasured/incomplete run as clean =="
FCSHOW="$("$METRICS" show "$FCOUT" 2>/dev/null)"
check "T6: show renders incomplete coverage" "1" \
  "$(printf '%s\n' "$FCSHOW" | grep -c '^outcome coverage: incomplete')"
check "T6: show names the open-packet count" "1" \
  "$(printf '%s\n' "$FCSHOW" | grep -c 'outcome coverage: incomplete — 1 started packet')"
check "T6: show renders by-outcome breakdown" "1" \
  "$(printf '%s\n' "$FCSHOW" | grep -c '^  failed: 1')"

SWSHOW="$("$METRICS" show "$SWOUT" 2>/dev/null)"
check "T6: show renders complete coverage, not as all-green" "1" \
  "$(printf '%s\n' "$SWSHOW" | grep -c '^outcome coverage: complete')"
check "T6: show complete label does not claim green" "1" \
  "$(printf '%s\n' "$SWSHOW" | grep -c 'not all necessarily green')"

LEGSHOW="$("$METRICS" show "$OUT" 2>/dev/null)"
check "T6: a pre-feature run renders unmeasured, never as clean" "1" \
  "$(printf '%s\n' "$LEGSHOW" | grep -c '^outcome coverage: unmeasured')"
check "T6: unmeasured label never says complete or incomplete" "0" \
  "$(printf '%s\n' "$LEGSHOW" | grep -cE '^outcome coverage: (complete|incomplete)')"

echo
echo "== self_host: marker present only when driving THIS repo, never touches other fields =="
# self_host is true only when (a) the script's own git root and the DRIVEN repo's git
# root are the same directory, worktree-normalised, and (b) that directory carries
# .claude-plugin/plugin.json. $OUT (the S1 scenario at the top of this file) drives a
# throwaway $REPO with no manifest, so it is the "plain consumer run" case: false.
check "self_host: false by default (no manifest, different repo)" "false" \
  "$(jq -r '.self_host' "$OUT")"
# type, not truthiness: --argjson wires this as a JSON boolean. A regression to --arg
# would still read "false" under `jq -r` but fail a `type` check.
check "self_host: is a JSON boolean, not a string" "boolean" \
  "$(jq -r '.self_host|type' "$OUT")"
# The emitted note begins "self_host:" (UNDERSCORE) — matching "self-host" (hyphen)
# is vacuous, since that substring never appears anywhere in the note and this check
# would pass whether or not the note were present. startswith() matches the string
# the collector actually emits (see the `self_host: note present when true` case
# below, which asserts the identical prefix on the positive side).
check "self_host: no self-host note when false" "0" \
  "$(jq -r '[.notes[]|select(startswith("self_host:"))]|length' "$OUT")"
check "self_host: schema unchanged"    "2" "$(jq -r '.schema' "$OUT")"

# --- a real self-driven collector, so a positive out of the DETECTOR is exercised ---
# Every check above only pins the RENDERER: $OUT is always driven with a real,
# non-plugin repo, so metrics.sh could hardcode self_host="false", invert its
# comparison, or check a wrong manifest path and every check above would still pass.
# Build a SYNTHETIC repo that carries a manifest AND a copy of metrics.sh at the same
# relative path (scripts/metrics.sh) a real self-host checkout would have, so
# BASH_SOURCE[0] resolves the self side to that repo when the copy runs. metrics.sh
# sources nothing else, so the copy is a complete, hermetic collector.
HSSELFREPO="$ROOT/hs-self-repo"; mkdir -p "$HSSELFREPO/scripts" "$HSSELFREPO/.claude-plugin"
git -C "$HSSELFREPO" init -q
echo '{}' > "$HSSELFREPO/.claude-plugin/plugin.json"
cp "$METRICS" "$HSSELFREPO/scripts/metrics.sh"
chmod +x "$HSSELFREPO/scripts/metrics.sh"
HSSELFOUT="$ROOT/hs-self.json"
"$HSSELFREPO/scripts/metrics.sh" collect --main-root "$HSSELFREPO" --projects-dir "$ROOT/none" --out "$HSSELFOUT" >/dev/null 2>&1
check "self_host: TRUE from a real self-driven collector" "true" \
  "$(jq -r '.self_host' "$HSSELFOUT")"
check "self_host: note present when true" "1" \
  "$(jq -r '[.notes[]|select(startswith("self_host:"))]|length' "$HSSELFOUT")"

# manifest present but NOT the same repo: the real same-repo discriminator, now that
# the fixture above exists to build it with. Drives the SAME self-host copy used for
# the positive case above against a DIFFERENT repo that also carries a manifest — this
# is what actually isolates the same-repo comparison from mere manifest presence. (The
# original version of this case drove $METRICS — the real gaffer checkout — against a
# different manifest repo; that only re-proved the "false by default" case above,
# since $METRICS's own self-side root already differs from any throwaway repo, and it
# never exercised the driven repo's manifest at all.)
HSMREPO="$ROOT/hs-manifest-repo"; mkdir -p "$HSMREPO/.claude-plugin"
git -C "$HSMREPO" init -q
echo '{}' > "$HSMREPO/.claude-plugin/plugin.json"
HSMOUT="$ROOT/hs-manifest.json"
"$HSSELFREPO/scripts/metrics.sh" collect --main-root "$HSMREPO" --projects-dir "$ROOT/none" --out "$HSMOUT" >/dev/null 2>&1
check "self_host: same-repo copy driven against a DIFFERENT manifest repo -> false" "false" \
  "$(jq -r '.self_host' "$HSMOUT")"

# `show` renders three distinct states off three synthetic packets derived from $OUT:
# true -> "self-host: yes"; the key DELETED (a pre-feature packet) -> "self-host:
# unknown" (must NOT read as a consumer run); explicit false -> no segment at all.
HSTRUE="$ROOT/hs-true.json"; jq '.self_host = true' "$OUT" > "$HSTRUE"
HSNULL="$ROOT/hs-null.json"; jq 'del(.self_host)' "$OUT" > "$HSNULL"
check "show: self_host=true renders 'self-host: yes'" "1" \
  "$(printf '%s\n' "$("$METRICS" show "$HSTRUE" 2>/dev/null)" | grep -c 'self-host: yes')"
check "show: self_host key absent renders 'self-host: unknown'" "1" \
  "$(printf '%s\n' "$("$METRICS" show "$HSNULL" 2>/dev/null)" | grep -c 'self-host: unknown')"
check "show: self_host=false renders no self-host segment" "0" \
  "$(printf '%s\n' "$("$METRICS" show "$OUT" 2>/dev/null)" | grep -c 'self-host')"

# no-git fallback: with a non-git --main-root, self_host must read false REGARDLESS of
# the collector's own working directory ("on any doubt, false"). EITHER side's git
# resolution can fail — the self side (BASH_SOURCE[0] resolves to a non-git script
# copy) or the driven side (--main-root is not a git repo, or is one git cannot
# resolve) — and an unresolved side must now yield NO root at all, never a root
# synthesized from self_script_dir or main_root, so the comparison cannot succeed
# either way. The two fixtures immediately below cover the reachable space between
# them: Fixture A fails BOTH sides at once (a non-git plugin copy driven at a
# non-git root under it), Fixture B fails the driven side ALONE while the self side
# resolves. Self-alone is not a reachable false positive — a self-side failure means
# the collector has no ancestor repo, so any driven root that DOES resolve is
# necessarily a different directory. The case the two HSNOGIT checks just below
# guard is narrower but still real: the
# driven-side `|| echo .` substitution, which `cd`d to the COLLECTOR's process cwd
# instead of failing, and so silently invented a root. That bug was
# directory-dependent, not a plain failure to resolve — reproduced here: launched
# from $HERE (this repo's own scripts/ dir) it read self_host=true (the launch
# directory happened to be a real self-host checkout with a manifest); launched from an
# unrelated tmp dir it read false. Asserting both from fixed working directories is
# what turns this from a case the old bug could still pass into a real regression
# guard. These fixtures (and Fixture A below) assume $ROOT -- mktemp -d, i.e. TMPDIR
# -- has NO ancestor git repository; sited inside a checkout, the "non-git" roots
# would resolve after all and test something else. That fails loudly rather than
# silently (the checks read true and fail), so it is a note, not a guard.
HSNOGIT="$ROOT/hs-nogit"; mkdir -p "$HSNOGIT"
HSNOGITOUT_HERE="$ROOT/hs-nogit-here.json"
( cd "$HERE" && "$METRICS" collect --main-root "$HSNOGIT" --projects-dir "$ROOT/none" --out "$HSNOGITOUT_HERE" >/dev/null 2>&1 )
check "self_host: --main-root not a git repo -> false, launched from \$HERE" "false" \
  "$(jq -r '.self_host' "$HSNOGITOUT_HERE" 2>/dev/null)"
HSCWD="$ROOT/hs-cwd"; mkdir -p "$HSCWD"
HSNOGITOUT_CWD="$ROOT/hs-nogit-cwd.json"
( cd "$HSCWD" && "$METRICS" collect --main-root "$HSNOGIT" --projects-dir "$ROOT/none" --out "$HSNOGITOUT_CWD" >/dev/null 2>&1 )
check "self_host: --main-root not a git repo -> false, launched from an unrelated tmp dir" "false" \
  "$(jq -r '.self_host' "$HSNOGITOUT_CWD" 2>/dev/null)"

# --- Fixture A: a non-git PLUGIN COPY (the finding's exact case) -------------
# An archive/tarball install of the plugin — a copy of metrics.sh plus the manifest,
# but no .git at all — means the SELF side's rev-parse fails. Driven with
# --main-root pointing at a non-git directory under that same plugin root, the
# DRIVEN side's rev-parse fails too. Before the fix, both sides fell back to
# self_script_dir / main_root respectively, which happen to share a parent here, so
# this read self_host=true PLUS the dogfooding note — a consumer/archive run
# labelled self-host. Follows the HSSELFREPO construction above (a manifest plus a
# copy of metrics.sh at scripts/metrics.sh) but omits `git init`. Canonicalized via
# `pwd -P` up front: self_script_dir is always resolved through `pwd -P`
# (physical/symlink-free) regardless of invocation path, so on a host where the tmp
# root sits behind a symlink (e.g. macOS /var -> /private/var) an uncanonicalized
# fixture root would make the two sides' paths differ by that symlink alone and the
# check would pass FALSE for the wrong reason, before the fix and after it alike.
HSNOGITSELF="$ROOT/hs-nogit-self-repo"
mkdir -p "$HSNOGITSELF/scripts" "$HSNOGITSELF/.claude-plugin" "$HSNOGITSELF/sub"
HSNOGITSELF="$(cd "$HSNOGITSELF" && pwd -P)"
echo '{}' > "$HSNOGITSELF/.claude-plugin/plugin.json"
cp "$METRICS" "$HSNOGITSELF/scripts/metrics.sh"
chmod +x "$HSNOGITSELF/scripts/metrics.sh"
HSNOGITSELFOUT="$ROOT/hs-nogit-self.json"
( cd "$HERE" && "$HSNOGITSELF/scripts/metrics.sh" collect --main-root "$HSNOGITSELF/sub" \
  --projects-dir "$ROOT/none" --out "$HSNOGITSELFOUT" >/dev/null 2>&1 )
check "self_host: non-git plugin copy (finding's exact case) -> false" "false" \
  "$(jq -r '.self_host' "$HSNOGITSELFOUT" 2>/dev/null)"
check "self_host: non-git plugin copy -> no self_host note" "0" \
  "$(jq -r '[.notes[]|select(startswith("self_host:"))]|length' "$HSNOGITSELFOUT" 2>/dev/null)"

# --- Fixture B: a non-git --main-root sited UNDER a real plugin root --------
# Mirror of Fixture A from the other side. The SELF side resolves normally (reuses
# the real git-initialised HSSELFREPO collector copy built above), but --main-root
# points at a directory git cannot resolve: a `.git` FILE containing a gitdir
# pointer to a path that does not exist (the shape left behind by a submodule whose
# superproject's .git/modules was discarded, or a linked worktree copied away from
# the main repo it pointed at -- NOT an uninitialised submodule, which has no .git
# entry at all). `git rev-parse` there exits 128 rather than
# walking up to a parent .git, so the DRIVEN side fails to resolve while sitting
# directly under a real plugin root — before the fix this fell back to $main_root
# itself, which of course carries the manifest, so it also read self_host=true.
# Canonicalized for the same reason as Fixture A: git's own rev-parse output for the
# self side is always physical/symlink-free, so the driven side's literal fallback
# path must be built from an equally canonicalized root or the two would differ by
# a symlink component alone rather than by the thing under test.
HSSELFREPO_REAL="$(cd "$HSSELFREPO" && pwd -P)"
HSBROKENSUB="$HSSELFREPO_REAL/broken-submodule"; mkdir -p "$HSBROKENSUB"
printf 'gitdir: /nonexistent/nowhere\n' > "$HSBROKENSUB/.git"
HSBROKENOUT="$ROOT/hs-broken-submodule.json"
( cd "$HERE" && "$HSSELFREPO/scripts/metrics.sh" collect --main-root "$HSBROKENSUB" \
  --projects-dir "$ROOT/none" --out "$HSBROKENOUT" >/dev/null 2>&1 )
check "self_host: non-git --main-root under a real plugin root -> false" "false" \
  "$(jq -r '.self_host' "$HSBROKENOUT" 2>/dev/null)"

echo "== thin-loop-driver T20: main-session-edits success metric (agents_dir/driver_mode) =="
# --- hook: agents_dir/driver_mode are stamped only for Edit/Write/MultiEdit/NotebookEdit,
# from a REAL main checkout so the driver-mode marker file can be resolved (the
# ORCH_METRICS_DIR fast-path other hook tests use has no main checkout to check against,
# so this exercises the hook the way a live session would: cd into the repo, no override).
DMREPO="$ROOT/dm-hookrepo"; mkdir -p "$DMREPO/.agents/driver-mode" "$DMREPO/.agents/metrics/events"
git -C "$DMREPO" init -q
touch "$DMREPO/.agents/driver-mode/DMSESS"
dmhook() { # dmhook <payload>
  ( cd "$DMREPO" && printf '%s' "$1" | "$HOOK" >/dev/null 2>&1 )
}
dmhook '{"session_id":"DMSESS","tool_name":"Edit","agent_id":"","agent_type":"main","tool_input":{"file_path":"src/foo.cs"},"tool_response":{"filePath":"src/foo.cs"}}'
dmhook '{"session_id":"DMSESS","tool_name":"Edit","agent_id":"","agent_type":"main","tool_input":{"file_path":".agents/run-state.yaml"},"tool_response":{"filePath":".agents/run-state.yaml"}}'
dmhook '{"session_id":"DMSESS","tool_name":"Edit","agent_id":"i1","agent_type":"implementer","tool_input":{"file_path":"src/bar.cs"},"tool_response":{"filePath":"src/bar.cs"}}'
DML="$DMREPO/.agents/metrics/events/DMSESS.jsonl"
check "hook: agents_dir=false outside .agents/" "false" \
  "$(jq -r 'select(.file_hash=="c3f180a9db6f").agents_dir' "$DML" 2>/dev/null)"
check "hook: agents_dir=true under .agents/" "true" \
  "$(jq -rs '[.[]|select(.tool=="Edit")][1].agents_dir' "$DML" 2>/dev/null)"
check "hook: driver_mode=true, marked session + no agent_id" "true" \
  "$(jq -rs '[.[]|select(.tool=="Edit")][0].driver_mode' "$DML" 2>/dev/null)"
check "hook: driver_mode=false when agent_id is present" "false" \
  "$(jq -rs '[.[]|select(.tool=="Edit")][2].driver_mode' "$DML" 2>/dev/null)"
# a session with NO mark, but a resolvable main checkout -> driver_mode is a definite
# `false` (present, not omitted): the mark's absence IS knowable here, so reporting
# it is a real claim, not an unmeasured gap. `jq -r '.driver_mode // "null"'` would
# read this the SAME as a genuinely absent key (jq's `//` treats `false` as falsy
# too) -- caught by mutation-testing this very case -- so the check below asserts
# presence and value separately instead.
mkdir -p "$ROOT/dm-unmarked/.agents/metrics/events"; git -C "$ROOT/dm-unmarked" init -q
( cd "$ROOT/dm-unmarked" && printf '%s' '{"session_id":"NOMARK","tool_name":"Edit","agent_id":"","agent_type":"main","tool_input":{"file_path":"src/x.cs"}}' | "$HOOK" >/dev/null 2>&1 )
NOMARKLINE="$ROOT/dm-unmarked/.agents/metrics/events/NOMARK.jsonl"
check "hook: driver_mode key present for an unmarked (but resolvable) session" "true" \
  "$(jq -r 'has("driver_mode")' "$NOMARKLINE" 2>/dev/null)"
check "hook: driver_mode=false for an unmarked (but resolvable) session" "false" \
  "$(jq -r '.driver_mode' "$NOMARKLINE" 2>/dev/null)"
# main_root genuinely UNRESOLVABLE (the ORCH_METRICS_DIR fast-path other hook tests use
# has no main checkout to check the mark against) -> driver_mode is OMITTED, not a
# guessed false -- an unknown must never be stamped as a definite non-leak.
DMNOROOT="$ROOT/dm-noroot-events"; mkdir -p "$DMNOROOT"
printf '%s' '{"session_id":"NOROOT","tool_name":"Edit","agent_id":"","agent_type":"main","tool_input":{"file_path":"src/y.cs"}}' \
  | ORCH_METRICS_DIR="$DMNOROOT" "$HOOK" >/dev/null 2>&1
check "hook: driver_mode omitted when main_root cannot be resolved" "false" \
  "$(jq -r 'has("driver_mode")' "$DMNOROOT/NOROOT.jsonl" 2>/dev/null)"
check "hook: agents_dir still stamped when main_root cannot be resolved" "false" \
  "$(jq -r '.agents_dir' "$DMNOROOT/NOROOT.jsonl" 2>/dev/null)"

# --- collect: the count itself, and the four discriminators a wrong implementation
# would blur (driver_mode, agents_dir, ok, and whether the metric is even scoped to
# edit-type tools) -- one run carrying all four shapes at once so a filter dropped
# from ANY of them changes the count, not just one isolated case.
#  1. leak (Edit):        driver_mode=true,  ok=true,  agents_dir=false -> COUNTS
#  2. .agents/ edit:      driver_mode=true,  ok=true,  agents_dir=true  -> excluded (agents_dir)
#  3. subagent edit:      driver_mode=false, ok=true,  agents_dir=false -> excluded (driver_mode)
#  4. failed leak:        driver_mode=true,  ok=false, agents_dir=false -> excluded (ok)
#  5. leak (Write):       driver_mode=true,  ok=true,  agents_dir=false -> COUNTS
#  6. leak (MultiEdit):   driver_mode=true,  ok=true,  agents_dir=false -> COUNTS
#  7. leak (NotebookEdit):driver_mode=true,  ok=true,  agents_dir=false -> COUNTS
# 5-7 pin the metric to the FULL registered write surface: a filter that quietly
# narrowed $edit_events to "Edit" only (a plausible one-tool oversight, the same
# under-count guard.sh's own history warns about for MultiEdit) passes 1-4 unchanged
# but silently drops these three leaks and their diagnostics contribution.
DMEREPO="$ROOT/dme-mixed"; mkdir -p "$DMEREPO/.agents/metrics/events"; git -C "$DMEREPO" init -q
cat > "$DMEREPO/.agents/metrics/events/DME1.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"DME1","agent_id":"","agent_type":"main","tool":"Edit","ok":true,"agents_dir":false,"driver_mode":true,"file_hash":"aaaaaaaaaaaa"}
{"ts":"2026-07-21T10:00:02Z","session_id":"DME1","agent_id":"","agent_type":"main","tool":"Edit","ok":true,"agents_dir":true,"driver_mode":true,"file_hash":"bbbbbbbbbbbb"}
{"ts":"2026-07-21T10:00:03Z","session_id":"DME1","agent_id":"i1","agent_type":"implementer","tool":"Edit","ok":true,"agents_dir":false,"driver_mode":false,"file_hash":"cccccccccccc"}
{"ts":"2026-07-21T10:00:04Z","session_id":"DME1","agent_id":"","agent_type":"main","tool":"Edit","ok":false,"agents_dir":false,"driver_mode":true,"file_hash":"dddddddddddd"}
{"ts":"2026-07-21T10:00:05Z","session_id":"DME1","agent_id":"","agent_type":"main","tool":"Write","ok":true,"agents_dir":false,"driver_mode":true,"file_hash":"eeeeeeeeeeee"}
{"ts":"2026-07-21T10:00:06Z","session_id":"DME1","agent_id":"","agent_type":"main","tool":"MultiEdit","ok":true,"agents_dir":false,"driver_mode":true,"file_hash":"ffffffffffff"}
{"ts":"2026-07-21T10:00:07Z","session_id":"DME1","agent_id":"","agent_type":"main","tool":"NotebookEdit","ok":true,"agents_dir":false,"driver_mode":true,"file_hash":"111111111111"}
JSON
DMEOUT="$ROOT/dme-mixed.json"
"$METRICS" collect --main-root "$DMEREPO" --projects-dir "$ROOT/none" --out "$DMEOUT" >/dev/null 2>&1
check "collect: leaks counted across all 4 write tools, others excluded" "4" \
  "$(jq -r '.totals.driver_mode_edits_outside_agents' "$DMEOUT")"
check "collect: diagnostics edit_events=7"                            "7" \
  "$(jq -r '.totals.driver_mode_edit_diagnostics.edit_events' "$DMEOUT")"
check "collect: diagnostics edit_events_missing_agents_dir=0 (all tagged)" "0" \
  "$(jq -r '.totals.driver_mode_edit_diagnostics.edit_events_missing_agents_dir' "$DMEOUT")"
check "show: renders the measured count" "main-session edits outside .agents/ in driver mode: 4" \
  "$("$METRICS" show "$DMEOUT" | grep -F 'main-session edits outside .agents/')"

# --- pre-feature event: one edit event predating this feature (no agents_dir/driver_mode
# at all) taints the WHOLE run to null, even though a second, fully-tagged event in the
# same run would otherwise have counted a leak. Absence of the field, not absence of a
# match, is what must force unmeasured.
DMPREREPO="$ROOT/dme-prefeature"; mkdir -p "$DMPREREPO/.agents/metrics/events"; git -C "$DMPREREPO" init -q
cat > "$DMPREREPO/.agents/metrics/events/DME2.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01Z","session_id":"DME2","agent_id":"","agent_type":"main","tool":"Edit","ok":true,"file_hash":"eeeeeeeeeeee"}
{"ts":"2026-07-21T10:00:02Z","session_id":"DME2","agent_id":"","agent_type":"main","tool":"Edit","ok":true,"agents_dir":false,"driver_mode":true,"file_hash":"ffffffffffff"}
JSON
DMPREOUT="$ROOT/dme-prefeature.json"
"$METRICS" collect --main-root "$DMPREREPO" --projects-dir "$ROOT/none" --out "$DMPREOUT" >/dev/null 2>&1
check "collect: pre-feature edit event forces null (not the 1 it would otherwise read)" "null" \
  "$(jq -r '.totals.driver_mode_edits_outside_agents' "$DMPREOUT")"
check "collect: diagnostics edit_events=2 despite null count" "2" \
  "$(jq -r '.totals.driver_mode_edit_diagnostics.edit_events' "$DMPREOUT")"
check "collect: diagnostics names the 1 missing-agents_dir event" "1" \
  "$(jq -r '.totals.driver_mode_edit_diagnostics.edit_events_missing_agents_dir' "$DMPREOUT")"
check "show: pre-feature run renders unmeasured, not a lying 0 or 1" \
  "main-session edits outside .agents/ in driver mode: unmeasured (2 edit event(s), 1 missing agents_dir)" \
  "$("$METRICS" show "$DMPREOUT" | grep -F 'main-session edits outside .agents/')"

# --- event-less run: no event records at all -> null, distinct from "no edit-type events"
# (a run with only Bash events and zero edits is measured 0, a real claim -- only the
# literal absence of ANY event must read as unmeasured).
DMEMPTYREPO="$ROOT/dme-eventless"; mkdir -p "$DMEMPTYREPO"; git -C "$DMEMPTYREPO" init -q
DMEMPTYOUT="$ROOT/dme-eventless.json"
"$METRICS" collect --main-root "$DMEMPTYREPO" --projects-dir "$ROOT/none" --out "$DMEMPTYOUT" >/dev/null 2>&1
check "collect: event-less run -> null" "null" \
  "$(jq -r '.totals.driver_mode_edits_outside_agents' "$DMEMPTYOUT")"
check "collect: event-less run diagnostics edit_events=0" "0" \
  "$(jq -r '.totals.driver_mode_edit_diagnostics.edit_events' "$DMEMPTYOUT")"

echo "== thin-loop-driver T21: main-session-context success metric (driver-mode enter/exit windows) =="
# --- shared fixture builder: one session with one enter/exit driver-mode window,
# one main-thread transcript turn (or two), and matching events so win_start/win_end
# resolve. `dmc_repo <name> <threshold>` sets up the repo/events/driver-mode log;
# the caller then drops turns into <name>/proj/<sid>.jsonl before collecting.
dmc_repo() { # dmc_repo <dirname> <sid> <threshold>
  local dir="$ROOT/$1" sid="$2" thr="$3"
  mkdir -p "$dir/.agents/metrics/events" "$dir/.agents/metrics/driver-mode"
  git -C "$dir" init -q
  cat > "$dir/.agents/metrics/events/$sid.jsonl" <<EVJSON
{"ts":"2026-07-22T10:00:00Z","session_id":"$sid","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":1}
{"ts":"2026-07-22T10:00:10Z","session_id":"$sid","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":1}
EVJSON
  cat > "$dir/.agents/metrics/driver-mode/$sid.jsonl" <<DMJSON
{"ts":"2026-07-22T10:00:00Z","session":"$sid","kind":"enter","model":"claude-opus-5","effort":"high","threshold":"$thr"}
{"ts":"2026-07-22T10:00:10Z","session":"$sid","kind":"exit"}
DMJSON
}

# --- case 1: a turn UNDER a stated threshold. Two turns (3000, 4000) discriminate
# MAX from a plausible SUM bug (7000 != 4000) -- the field is "the LARGEST turn
# context", not a total, so a wrong implementation that reused this file's own
# sumtok() pattern would read a different, wrong number here, not merely a
# differently-labelled one.
dmc_repo "dmc-under" "DCU1" "10000"
mkdir -p "$ROOT/dmc-under-proj/proj"
cat > "$ROOT/dmc-under-proj/proj/DCU1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-22T10:00:02Z","message":{"id":"u1","model":"claude-opus-5","usage":{"input_tokens":1000,"output_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":1000}}}
{"type":"assistant","timestamp":"2026-07-22T10:00:04Z","message":{"id":"u2","model":"claude-opus-5","usage":{"input_tokens":1500,"output_tokens":10,"cache_creation_input_tokens":1500,"cache_read_input_tokens":1000}}}
JSON
DCUOUT="$ROOT/dmc-under.json"
"$METRICS" collect --main-root "$ROOT/dmc-under" --projects-dir "$ROOT/dmc-under-proj" --out "$DCUOUT" >/dev/null 2>&1
check "collect: under threshold -- max_context is the MAX turn (4000), not the sum (7000)" "4000" \
  "$(jq -r '.totals.driver_mode_context.max_context' "$DCUOUT")"
check "collect: under threshold -- threshold reported beside it" "10000" \
  "$(jq -r '.totals.driver_mode_context.threshold' "$DCUOUT")"
check "collect: under threshold -- diagnostics windows=1" "1" \
  "$(jq -r '.totals.driver_mode_context_diagnostics.windows' "$DCUOUT")"
check "collect: under threshold -- diagnostics turns_in_window=2" "2" \
  "$(jq -r '.totals.driver_mode_context_diagnostics.turns_in_window' "$DCUOUT")"
check "show: renders under threshold, no OVER flag" "main-session context (driver mode): 4000 tokens vs threshold 10000  under threshold" \
  "$("$METRICS" show "$DCUOUT" | grep -F 'main-session context')"

# --- case 2: a turn OVER a stated threshold. input=100, cache_creation=200,
# cache_read=800, output=9999 -- correct context (in+ccC+ccR=1100) is OVER the
# threshold (500); a plausible bug that forgets cache_read (100+200=300) reads
# UNDER instead, flipping the very relationship this case exists to prove. output
# is excluded on purpose (huge here, at 9999) -- a bug that summed output in would
# also read "over" but at the wrong number, so the exact value is what is checked.
dmc_repo "dmc-over" "DCO1" "500"
mkdir -p "$ROOT/dmc-over-proj/proj"
cat > "$ROOT/dmc-over-proj/proj/DCO1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-22T10:00:02Z","message":{"id":"o1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":9999,"cache_creation_input_tokens":200,"cache_read_input_tokens":800}}}
JSON
DCOOUT="$ROOT/dmc-over.json"
"$METRICS" collect --main-root "$ROOT/dmc-over" --projects-dir "$ROOT/dmc-over-proj" --out "$DCOOUT" >/dev/null 2>&1
check "collect: over threshold -- max_context excludes output, includes cache_read (1100)" "1100" \
  "$(jq -r '.totals.driver_mode_context.max_context' "$DCOOUT")"
check "collect: over threshold -- threshold reported beside it" "500" \
  "$(jq -r '.totals.driver_mode_context.threshold' "$DCOOUT")"
check "show: renders the OVER threshold flag" "main-session context (driver mode): 1100 tokens vs threshold 500  ⚠ OVER threshold" \
  "$("$METRICS" show "$DCOOUT" | grep -F 'main-session context')"

# --- case 3: NO threshold stated (enter recorded "unknown", the literal default
# `compact-threshold`/cmd_driver_mode_enter write when neither repo nor operator
# has one set -- thin-loop-driver T6 removed the invented gaffer-default constant
# that used to fill this gap). A plausible bug invents a number here instead of
# null -- both fields must read null together (PRD: "a run lacking usage data or
# a stated threshold reports unmeasured"), even though real usage data (a
# 50000-token turn) exists for this window. scripts/metrics.sh needed no edit for
# T6 -- it already nulls a non-numeric threshold and forces max_context null with
# it -- so this case pins that third consumer's behaviour rather than assuming it.
dmc_repo "dmc-none" "DCN1" "unknown"
mkdir -p "$ROOT/dmc-none-proj/proj"
cat > "$ROOT/dmc-none-proj/proj/DCN1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-22T10:00:02Z","message":{"id":"n1","model":"claude-opus-5","usage":{"input_tokens":10000,"output_tokens":10,"cache_creation_input_tokens":20000,"cache_read_input_tokens":20000}}}
JSON
DCNOUT="$ROOT/dmc-none.json"
"$METRICS" collect --main-root "$ROOT/dmc-none" --projects-dir "$ROOT/dmc-none-proj" --out "$DCNOUT" >/dev/null 2>&1
check "collect: no threshold stated -- threshold is null, no invented number" "null" \
  "$(jq -r '.totals.driver_mode_context.threshold' "$DCNOUT")"
check "collect: no threshold stated -- max_context is null too, despite real usage data" "null" \
  "$(jq -r '.totals.driver_mode_context.max_context' "$DCNOUT")"
check "collect: no threshold stated -- diagnostics still show the window and turn were seen" "1 1" \
  "$(jq -r '"\(.totals.driver_mode_context_diagnostics.windows) \(.totals.driver_mode_context_diagnostics.turns_in_window)"' "$DCNOUT")"
check "show: renders unmeasured, not a lying number" \
  "main-session context (driver mode): unmeasured — no compaction threshold was set here, not a quantity that cannot be measured; the settings key autoCompactWindow supplies one (1 window(s), 1 turn(s))" \
  "$("$METRICS" show "$DCNOUT" | grep -F 'main-session context')"
# driver-context-window-default T2: the unmeasured line names the settings key
# that would supply a threshold, and carries NO number other than the two
# diagnostics counts -- a remedy clause suggesting a value (e.g. "set
# autoCompactWindow to 200000") would reinstate in prose the invented default
# thin-loop-driver T6 removed. Strip the "(N window(s), M turn(s))" tail and
# require no digit to remain.
DCN_LINE="$("$METRICS" show "$DCNOUT" | grep -F 'main-session context')"
check "show: null-threshold line names the settings key autoCompactWindow" "yes" \
  "$([[ "$DCN_LINE" == *autoCompactWindow* ]] && echo yes || echo no)"
check "show: null-threshold line carries no number but the two diagnostics counts" "none" \
  "$(printf '%s' "$DCN_LINE" | sed -E 's/\([0-9]+ window\(s\), [0-9]+ turn\(s\)\)$//' | grep -oE '[0-9]+' | tr '\n' ' ' | sed 's/ $//' | grep . || echo none)"

# --- case 4: a threshold IS stated but no main-thread turn with usage data falls
# inside the window (no transcript at all here). This is the state the two-fields-
# null-together phrasing in SKILL.md/metrics.sh wrongly claimed was impossible --
# threshold and max_context are null INDEPENDENTLY, and a stated threshold must
# survive on its own when only usage is missing (never fall back to null-both, and
# never invent a 0 for max_context).
dmc_repo "dmc-nousage" "DCX1" "10000"
mkdir -p "$ROOT/dmc-nousage-proj/proj"
DCXOUT="$ROOT/dmc-nousage.json"
"$METRICS" collect --main-root "$ROOT/dmc-nousage" --projects-dir "$ROOT/dmc-nousage-proj" --out "$DCXOUT" >/dev/null 2>&1
check "collect: threshold stated, no usage -- threshold survives on its own" "10000" \
  "$(jq -r '.totals.driver_mode_context.threshold' "$DCXOUT")"
check "collect: threshold stated, no usage -- max_context is null, not 0" "null" \
  "$(jq -r '.totals.driver_mode_context.max_context' "$DCXOUT")"
check "collect: threshold stated, no usage -- diagnostics show the window, zero turns" "1 0" \
  "$(jq -r '"\(.totals.driver_mode_context_diagnostics.windows) \(.totals.driver_mode_context_diagnostics.turns_in_window)"' "$DCXOUT")"
check "show: renders unmeasured for missing usage, names the stated threshold" \
  "main-session context (driver mode): unmeasured — no main-thread usage data in 1 window(s) (threshold 10000)" \
  "$("$METRICS" show "$DCXOUT" | grep -F 'main-session context')"

echo "== dispatch-progress-metrics T2: packets[].dispatches[] -- one row per implementer dispatch =="
# Events are in REAL PostToolUse order: a subagent own tool calls are logged as they
# return, and the main thread Agent event is logged only when the dispatch itself
# returns, so it comes AFTER every event of the subagent it dispatched. The dispatch
# span is back-dated from the Agent event: [ts - duration_ms, ts], each bound widened
# by 1 s, inclusive. One packet (dp-001) holds five implementer dispatches and one
# reviewer dispatch (not a row):
#   d1  i1 (:02-:04)      Agent :05 dur 4000 -> span [:00,:06]      -> 3 calls, 60 ms, 2 edits
#   d2  i2 (:07-:08)      Agent :09 dur 2500 -> span [:05.5,:10]    -> 2 calls, 10 ms, 1 edit
#   d3  none              Agent :20 dur 1000 -> span [:18,:21]      -> unresolved (null)
#       ...though two main-thread events with agent_type and NO agent_id sit at :19/:20
#   d4  i4 (:23)          Agent :24 NO duration_ms                  -> unresolved (null)
#   d5  i5a (:31,:33) and i5b (:32) both first-seen in span [:28,:35] -> the earliest, i5a
DPREPO="$ROOT/dp-repo"; mkdir -p "$DPREPO/.agents/metrics/events"
git -C "$DPREPO" init -q; git -C "$DPREPO" config user.email t@t; git -C "$DPREPO" config user.name t
echo dp > "$DPREPO/log.txt"; git -C "$DPREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:50Z" GIT_COMMITTER_DATE="2026-07-21T10:00:50Z" \
  git -C "$DPREPO" commit -q -m "work

[orch packet:dp-001]"
cat > "$DPREPO/.agents/metrics/events/DP.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00Z","session_id":"DP","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":1}
{"ts":"2026-07-21T10:00:02Z","session_id":"DP","agent_id":"i1","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":10}
{"ts":"2026-07-21T10:00:03Z","session_id":"DP","agent_id":"i1","agent_type":"gaffer:implementer","tool":"Write","duration_ms":20}
{"ts":"2026-07-21T10:00:04Z","session_id":"DP","agent_id":"i1","agent_type":"gaffer:implementer","tool":"Bash","duration_ms":30}
{"ts":"2026-07-21T10:00:05Z","session_id":"DP","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":4000}
{"ts":"2026-07-21T10:00:07Z","session_id":"DP","agent_id":"i2","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":5}
{"ts":"2026-07-21T10:00:08Z","session_id":"DP","agent_id":"i2","agent_type":"gaffer:implementer","tool":"Read","duration_ms":5}
{"ts":"2026-07-21T10:00:09Z","session_id":"DP","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":2500}
{"ts":"2026-07-21T10:00:11Z","session_id":"DP","agent_id":"r1","agent_type":"gaffer:reviewer","tool":"Bash","duration_ms":9}
{"ts":"2026-07-21T10:00:12Z","session_id":"DP","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:reviewer","duration_ms":2000}
{"ts":"2026-07-21T10:00:19Z","session_id":"DP","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":11}
{"ts":"2026-07-21T10:00:20Z","session_id":"DP","agent_id":"","agent_type":"gaffer:loop-driver","tool":"Write","duration_ms":12}
{"ts":"2026-07-21T10:00:20Z","session_id":"DP","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":1000}
{"ts":"2026-07-21T10:00:23Z","session_id":"DP","agent_id":"i4","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":7}
{"ts":"2026-07-21T10:00:24Z","session_id":"DP","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer"}
{"ts":"2026-07-21T10:00:31Z","session_id":"DP","agent_id":"i5a","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":3}
{"ts":"2026-07-21T10:00:32Z","session_id":"DP","agent_id":"i5b","agent_type":"gaffer:implementer","tool":"Write","duration_ms":100}
{"ts":"2026-07-21T10:00:33Z","session_id":"DP","agent_id":"i5a","agent_type":"gaffer:implementer","tool":"Bash","duration_ms":4}
{"ts":"2026-07-21T10:00:34Z","session_id":"DP","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":5000}
JSON
DPOUT="$ROOT/dp-run.json"
"$METRICS" collect --main-root "$DPREPO" --projects-dir "$ROOT/none" --out "$DPOUT" >/dev/null 2>&1 \
  || bad "DPM T2: collect exits 0" "collect returned nonzero"
# `kind` (T3) is checked in its own section below; these cases pin T2's cost fields.
dp_row() { jq -c --argjson n "$1" '.packets[]|select(.id=="dp-001")|.dispatches[$n]|del(.kind)' "$DPOUT"; }
check "DPM T2: one row per implementer-role Agent event (reviewer dispatch is not a row)" "5" \
  "$(jq -r '.packets[]|select(.id=="dp-001")|.dispatches|length' "$DPOUT")"
check "DPM T2: first of two sequential dispatches credits the agent BEFORE its Agent event" \
  '{"tool_calls":3,"duration_ms":60,"edits":2}' "$(dp_row 0)"
check "DPM T2: second sequential dispatch credits its own agent, not the first" \
  '{"tool_calls":2,"duration_ms":10,"edits":1}' "$(dp_row 1)"
check "DPM T2: a dispatch with no agent_id in its span is a row with null cost fields" \
  '{"tool_calls":null,"duration_ms":null,"edits":null}' "$(dp_row 2)"
check "DPM T2: an Agent event with no duration_ms is a row, unresolved" \
  '{"tool_calls":null,"duration_ms":null,"edits":null}' "$(dp_row 3)"
check "DPM T2: two qualifying agent_ids -- the earliest first event wins" \
  '{"tool_calls":2,"duration_ms":7,"edits":1}' "$(dp_row 4)"
check "DPM T2: packet-level dispatched[] still counts the reviewer too (meaning unchanged)" \
  '{"gaffer:implementer":5,"gaffer:reviewer":1}' \
  "$(jq -c '.packets[]|select(.id=="dp-001")|.dispatched' "$DPOUT")"

echo "== dispatch-progress-metrics T3: dispatches[].kind from start + routing records =="
# kind = the latest start or routing record for the packet strictly before the
# dispatch Agent event: start (with or without --continue) -> initial, a `continue`
# routing record -> continuation, fix/retry -> that verdict; a routing record wins
# over a start written at the same boundary (no Agent event between them). Records
# are read from the outcomes log and EVERY .agents/loop/*/routing.jsonl — never via
# a run_id: the decoy run-state below names a run directory that holds none of them.
#   k-001  start :01.1 -> d1 (Agent :04)                          -> initial
#          fix (RUN-OLD) :07.2 -> d2 (Agent :09)                   -> fix
#          continue (RUN-NEW) :10.1 + start --continue :10.6 -> d3 -> continuation
#   k-002  d4 (Agent :53) with no k-002 record before it           -> null
#          fix :56, decider Agent :58, resume start --continue :60.5 -> d5 -> initial
#   k-003  start :91.1 -> d6 (Agent :94)                          -> initial
#          fix :100.2, then resume start --continue :101.5 with NO Agent event of
#          any role between them -> d7 (Agent :104)               -> initial
#          (only a `continue` routing record pairs with a following start; a
#          fix/retry arm records no start, so that start is a resume's)
KDREPO="$ROOT/kd-repo"
mkdir -p "$KDREPO/.agents/metrics/events" "$KDREPO/.agents/metrics/outcomes" \
         "$KDREPO/.agents/loop/RUN-OLD" "$KDREPO/.agents/loop/RUN-NEW" "$KDREPO/.agents/loop/RUN-DECOY"
git -C "$KDREPO" init -q; git -C "$KDREPO" config user.email t@t; git -C "$KDREPO" config user.name t
echo a > "$KDREPO/a.txt"; git -C "$KDREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:50Z" GIT_COMMITTER_DATE="2026-07-21T10:00:50Z" \
  git -C "$KDREPO" commit -q -m "k1

[orch packet:k-001]"
echo b > "$KDREPO/b.txt"; git -C "$KDREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:01:30Z" GIT_COMMITTER_DATE="2026-07-21T10:01:30Z" \
  git -C "$KDREPO" commit -q -m "k2

[orch packet:k-002]"
echo c > "$KDREPO/c.txt"; git -C "$KDREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:02:30Z" GIT_COMMITTER_DATE="2026-07-21T10:02:30Z" \
  git -C "$KDREPO" commit -q -m "k3

[orch packet:k-003]"
printf 'schema: "4"\nrun_id: "RUN-DECOY"\nstatus: "running"\n' > "$KDREPO/.agents/run-state.yaml"
cat > "$KDREPO/.agents/metrics/events/KD.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":1}
{"ts":"2026-07-21T10:00:02Z","session_id":"KD","agent_id":"k1","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":1}
{"ts":"2026-07-21T10:00:04Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":3000}
{"ts":"2026-07-21T10:00:05Z","session_id":"KD","agent_id":"kr","agent_type":"gaffer:reviewer","tool":"Bash","duration_ms":1}
{"ts":"2026-07-21T10:00:06Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:reviewer","duration_ms":1500}
{"ts":"2026-07-21T10:00:08Z","session_id":"KD","agent_id":"k2","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":1}
{"ts":"2026-07-21T10:00:09Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":1500}
{"ts":"2026-07-21T10:00:11Z","session_id":"KD","agent_id":"k3","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":1}
{"ts":"2026-07-21T10:00:12Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":1500}
{"ts":"2026-07-21T10:00:52Z","session_id":"KD","agent_id":"k4","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":1}
{"ts":"2026-07-21T10:00:53Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":1500}
{"ts":"2026-07-21T10:00:57Z","session_id":"KD","agent_id":"kc","agent_type":"gaffer:chief-engineer","tool":"Read","duration_ms":1}
{"ts":"2026-07-21T10:00:58Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:chief-engineer","duration_ms":1500}
{"ts":"2026-07-21T10:01:02Z","session_id":"KD","agent_id":"k5","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":1}
{"ts":"2026-07-21T10:01:03Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":1500}
{"ts":"2026-07-21T10:01:33Z","session_id":"KD","agent_id":"k6","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":1}
{"ts":"2026-07-21T10:01:34Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":1500}
{"ts":"2026-07-21T10:01:36Z","session_id":"KD","agent_id":"kr3","agent_type":"gaffer:reviewer","tool":"Bash","duration_ms":1}
{"ts":"2026-07-21T10:01:37Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:reviewer","duration_ms":1500}
{"ts":"2026-07-21T10:01:43Z","session_id":"KD","agent_id":"k7","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":1}
{"ts":"2026-07-21T10:01:44Z","session_id":"KD","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":1500}
JSON
cat > "$KDREPO/.agents/metrics/outcomes/KD.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01.100Z","packet":"k-001","session":"KD","kind":"start"}
{"ts":"2026-07-21T10:00:10.600Z","packet":"k-001","session":"KD","kind":"continue"}
{"ts":"2026-07-21T10:01:00.500Z","packet":"k-002","session":"KD","kind":"continue"}
{"ts":"2026-07-21T10:01:31.100Z","packet":"k-003","session":"KD","kind":"start"}
{"ts":"2026-07-21T10:01:41.500Z","packet":"k-003","session":"KD","kind":"continue"}
JSON
cat > "$KDREPO/.agents/loop/RUN-OLD/routing.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:07.200Z","packet":"k-001","token":"fix","action":"attempt","status":"fix · x · result: needs-reading · /r.md"}
{"ts":"2026-07-21T10:00:56.000Z","packet":"k-002","token":"fix","action":"attempt","status":"fix · x · result: needs-reading · /r.md"}
{"ts":"2026-07-21T10:01:40.200Z","packet":"k-003","token":"fix","action":"attempt","status":"fix · x · result: needs-reading · /r.md"}
JSON
cat > "$KDREPO/.agents/loop/RUN-NEW/routing.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:10.100Z","packet":"k-001","token":"continue","action":"continue","status":"continue · budget reached · result: needs-reading · /i.md"}
JSON
KDOUT="$ROOT/kd-run.json"
"$METRICS" collect --main-root "$KDREPO" --projects-dir "$ROOT/none" --out "$KDOUT" >/dev/null 2>&1 \
  || bad "DPM T3: collect exits 0" "collect returned nonzero"
kd_kinds() { jq -c --arg id "$1" '[.packets[]|select(.id==$id)|.dispatches[].kind]' "$KDOUT"; }
check "DPM T3: initial -> fix -> continuation (routing continue wins over the start at one boundary)" \
  '["initial","fix","continuation"]' "$(kd_kinds k-001)"
check "DPM T3: no prior record -> null; a resume --continue start reads initial, not the earlier fix" \
  '[null,"initial"]' "$(kd_kinds k-002)"
check "DPM T3: a fix route then a resume start with no Agent event between reads initial (only continue pairs with a start)" \
  '["initial","initial"]' "$(kd_kinds k-003)"
check "DPM T3: a measured run carries no routing-unmeasured note" "0" \
  "$(jq -r '[.notes[]|select(startswith("dispatch kind: routing-unmeasured"))]|length' "$KDOUT")"

# Pruned routing log: start records survive, no routing.jsonl holds a record for any
# of the run packets (only a foreign packet in the current run directory), so the
# fix dispatch reads null — never the `initial` the start record alone would give.
PRREPO="$ROOT/pr-repo"
mkdir -p "$PRREPO/.agents/metrics/events" "$PRREPO/.agents/metrics/outcomes" "$PRREPO/.agents/loop/RUN-CUR"
git -C "$PRREPO" init -q; git -C "$PRREPO" config user.email t@t; git -C "$PRREPO" config user.name t
echo a > "$PRREPO/a.txt"; git -C "$PRREPO" add -A
GIT_AUTHOR_DATE="2026-07-21T10:00:50Z" GIT_COMMITTER_DATE="2026-07-21T10:00:50Z" \
  git -C "$PRREPO" commit -q -m "p1

[orch packet:p-001]"
cat > "$PRREPO/.agents/metrics/events/PR.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:00Z","session_id":"PR","agent_id":"","agent_type":"main","tool":"Bash","duration_ms":1}
{"ts":"2026-07-21T10:00:02Z","session_id":"PR","agent_id":"p1","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":1}
{"ts":"2026-07-21T10:00:04Z","session_id":"PR","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":3000}
{"ts":"2026-07-21T10:00:08Z","session_id":"PR","agent_id":"p2","agent_type":"gaffer:implementer","tool":"Edit","duration_ms":1}
{"ts":"2026-07-21T10:00:09Z","session_id":"PR","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:implementer","duration_ms":1500}
JSON
cat > "$PRREPO/.agents/metrics/outcomes/PR.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:01.100Z","packet":"p-001","session":"PR","kind":"start"}
JSON
cat > "$PRREPO/.agents/loop/RUN-CUR/routing.jsonl" <<'JSON'
{"ts":"2026-07-21T10:00:07.200Z","packet":"zz-999","token":"fix","action":"attempt","status":"fix · x · result: needs-reading · /r.md"}
JSON
PROUT="$ROOT/pr-run.json"
"$METRICS" collect --main-root "$PRREPO" --projects-dir "$ROOT/none" --out "$PROUT" >/dev/null 2>&1 \
  || bad "DPM T3: pruned-routing collect exits 0" "collect returned nonzero"
check "DPM T3: pruned routing log -> every kind null (the fix dispatch is not read as initial)" \
  '[null,null]' "$(jq -c '[.packets[]|select(.id=="p-001")|.dispatches[].kind]' "$PROUT")"
check "DPM T3: pruned routing log names the reason in notes[]" "1" \
  "$(jq -r '[.notes[]|select(startswith("dispatch kind: routing-unmeasured — 1 start record(s)"))]|length' "$PROUT")"

# Legacy run (the T2 fixture: no start record, no routing log): every kind null, no
# routing-unmeasured note, and re-collecting it yields identical output.
check "DPM T3: legacy run -> every kind null" '[null,null,null,null,null]' \
  "$(jq -c '[.packets[]|select(.id=="dp-001")|.dispatches[].kind]' "$DPOUT")"
check "DPM T3: legacy run carries no routing-unmeasured note" "0" \
  "$(jq -r '[.notes[]|select(startswith("dispatch kind:"))]|length' "$DPOUT")"
DPOUT2="$ROOT/dp-run-2.json"
"$METRICS" collect --main-root "$DPREPO" --projects-dir "$ROOT/none" --out "$DPOUT2" >/dev/null 2>&1 \
  || bad "DPM T3: legacy re-collect exits 0" "collect returned nonzero"
if [ "$(jq -S -c 'del(.generated_at)' "$DPOUT")" = "$(jq -S -c 'del(.generated_at)' "$DPOUT2")" ]; then
  ok "DPM T3: legacy run re-collects identically"
else bad "DPM T3: legacy run re-collects identically" "second collect differs from the first"; fi

echo
if [ "$fail" -eq 0 ]; then
  printf 'test-metrics.sh: ALL %d checks passed\n' "$pass"; exit 0
else
  printf 'test-metrics.sh: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1
fi
