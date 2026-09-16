#!/usr/bin/env bash
# =============================================================================
# test-spend.sh — regression sweep for scripts/spend.sh (loop-measurement T9/T10)
# =============================================================================
# Exercises spend.sh against SYNTHETIC transcript fixtures under a throwaway
# projects dir. No live agent, no real ~/.claude. Exit 0 = all passed (CI runs
# it on push). Fixture files are written fresh by this script, so their mtime
# is always "now" — always newer than any --since window used below — which is
# what keeps spend.sh's mtime pre-filter (see spend.sh's `to_findmt` comment)
# from ever interfering with these assertions.
# =============================================================================

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SPEND="${HERE}/spend.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (spend.sh requires it)"; exit 0; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
PROJ="$ROOT/projects"
mkdir -p "$PROJ"

# =============================================================================
# FIXTURE SET A — dedup, exclusions, unrecorded buckets, cost parts, mixed
# pricing, cache-write-split degradation, no-content-leak. One project "proj1"
# carries a main session + two subagent contexts; a second project "proj2"
# exercises the by_project split.
# =============================================================================
mkdir -p "$PROJ/proj1/SESSIONID-SECRET-9999/subagents" "$PROJ/proj2"

# --- main session file: rows 1-10 (see the case-by-case comments) -----------
cat > "$PROJ/proj1/SESSIONID-SECRET-9999.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-10T10:00:00.100Z","effort":"high","message":{"id":"msg_dup1","model":"model-a","content":[{"type":"text","text":"SECRET_PROMPT_MARKER_zzz should never leak"}],"usage":{"input_tokens":100000,"output_tokens":20000,"cache_read_input_tokens":300000,"cache_creation_input_tokens":5000,"cache_creation":{"ephemeral_5m_input_tokens":5000,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-09-10T10:00:01.000Z","effort":"high","message":{"id":"msg_dup1","model":"model-a","usage":{"input_tokens":100000,"output_tokens":20000,"cache_read_input_tokens":300000,"cache_creation_input_tokens":5000,"cache_creation":{"ephemeral_5m_input_tokens":5000,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-09-10T10:00:05.000Z","effort":"high","message":{"id":"msg_dup1","model":"model-a","usage":{"input_tokens":100000,"output_tokens":20000,"cache_read_input_tokens":300000,"cache_creation_input_tokens":5000,"cache_creation":{"ephemeral_5m_input_tokens":5000,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-09-10T10:01:00Z","effort":"high","message":{"id":null,"model":"model-a","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":1,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-09-10T10:01:30Z","effort":"high","message":{"id":"msg_nousage","model":"model-a"}}
{"type":"assistant","effort":"high","message":{"id":"msg_nots","model":"model-a","usage":{"input_tokens":9,"output_tokens":9,"cache_read_input_tokens":9,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-09-10T10:01:45Z","message":{"id":"msg_synth","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-09-10T10:02:00Z","message":{"id":"msg_noeffort","model":"model-b","usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":2,"cache_creation_input_tokens":2,"cache_creation":{"ephemeral_5m_input_tokens":1,"ephemeral_1h_input_tokens":1}}}}
{"type":"assistant","timestamp":"2026-08-01T00:00:00Z","effort":"high","message":{"id":"msg_outwindow","model":"model-a","usage":{"input_tokens":555555,"output_tokens":555555,"cache_read_input_tokens":555555,"cache_creation_input_tokens":555555,"cache_creation":{"ephemeral_5m_input_tokens":555555,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-09-10T10:03:00Z","effort":"high","message":{"id":"msg_unsplit","model":"model-a","usage":{"input_tokens":50,"output_tokens":20,"cache_read_input_tokens":10,"cache_creation_input_tokens":999}}}
JSON

# --- subagent A: attributionAgent present ("reviewer") — row 11 -------------
cat > "$PROJ/proj1/SESSIONID-SECRET-9999/subagents/agent-AIDSECRET8888.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-10T10:04:00Z","effort":"xhigh","attributionAgent":"reviewer","message":{"id":"msg_sub1","model":"model-a","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":8,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":8}}}}
JSON

# --- subagent B: attributionAgent ABSENT entirely -> agent role "unrecorded" (row 12)
cat > "$PROJ/proj1/SESSIONID-SECRET-9999/subagents/agent-AIDUNRECORDED.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-10T10:05:00Z","effort":"high","message":{"id":"msg_sub2","model":"model-a","usage":{"input_tokens":3,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":1,"ephemeral_1h_input_tokens":0}}}}
JSON

# --- second project: one in-window row, exercises by_project split (row 13) -
cat > "$PROJ/proj2/S2.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-10T10:06:00Z","effort":"high","message":{"id":"msg_proj2","model":"model-a","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":50,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON

PRICES_MIXED="$ROOT/prices-mixed.json"
cat > "$PRICES_MIXED" <<'JSON'
{"table_date":"2026-09-01","prices":{"model-a":{"input":10,"cache_write_5m":12,"cache_write_1h":20,"cache_read":1,"output":30}}}
JSON

OUT_A="$ROOT/out-a.json"
"$SPEND" --projects-dir "$PROJ" --price-table "$PRICES_MIXED" \
  --since "2026-09-10T00:00:00Z" --until "2026-09-10T23:59:59Z" > "$OUT_A" 2>"$ROOT/out-a.err"
RC_A=$?

echo "== Fixture Set A: dedup / exclusions / unrecorded / cost parts / mixed pricing =="
check "exit 0" "0" "$RC_A"
check "dedup by message id: 3x-repeat collapses, 2 dropped" "2" "$(jq -r '.counts.messages_deduped_dropped' "$OUT_A")"
check "id-less message counted separately" "1" "$(jq -r '.counts.messages_no_id' "$OUT_A")"
check "messages_counted (6 proj1 + 1 proj2, out-of-window excluded)" "7" "$(jq -r '.counts.messages_counted' "$OUT_A")"
check "excluded: missing usage OR ts (2: msg_nousage, msg_nots)" "2" "$(jq -r '.counts.messages_excluded_no_usage_or_ts' "$OUT_A")"
check "excluded: <synthetic> model" "1" "$(jq -r '.counts.messages_excluded_synthetic' "$OUT_A")"

echo "-- five cost parts, summed across in-window rows --"
check "totals.tokens.input"          "101071" "$(jq -r '.totals.tokens.input' "$OUT_A")"
check "totals.tokens.output"         "20230"  "$(jq -r '.totals.tokens.output' "$OUT_A")"
check "totals.tokens.cache_read"     "300066" "$(jq -r '.totals.tokens.cache_read' "$OUT_A")"
check "totals.tokens.cache_write_5m" "5003"   "$(jq -r '.totals.tokens.cache_write_5m' "$OUT_A")"
check "totals.tokens.cache_write_1h" "9"      "$(jq -r '.totals.tokens.cache_write_1h' "$OUT_A")"

echo "-- mixed window: model-a priced, model-b absent from table --"
check "totals.dollars (model-b excluded, rounded)" "1.977698" "$(jq -r '.totals.dollars' "$OUT_A")"
check "totals.unpriced_tokens (model-b's 5-part sum: 7+3+2+1+1)" "14" "$(jq -r '.totals.unpriced_tokens' "$OUT_A")"
check "by_model.model-b.priced" "false" "$(jq -r '.by_model["model-b"].priced' "$OUT_A")"
check "by_model.model-a.priced" "true"  "$(jq -r '.by_model["model-a"].priced' "$OUT_A")"

echo "-- cache-write 5m/1h split unmeasured (no cache_creation breakdown object) --"
check "totals.cache_write_unmeasured_tokens (msg_unsplit's 999)" "999" "$(jq -r '.totals.cache_write_unmeasured_tokens' "$OUT_A")"
check "unmeasured[] names the split gap" "1" \
  "$(jq -r '[.unmeasured[] | select(test("cache-write 5m/1h split"))] | length' "$OUT_A")"

echo "-- unrecorded buckets: never guessed --"
check "by_effort.unrecorded exists (msg_noeffort has no effort field)" "true" \
  "$(jq -r 'has("unrecorded")' <(jq '.by_effort' "$OUT_A"))"
check "by_effort.unrecorded.unpriced_tokens" "14" "$(jq -r '.by_effort.unrecorded.unpriced_tokens' "$OUT_A")"
check "by_role.unrecorded exists (subagent B has no attributionAgent)" "true" \
  "$(jq -r 'has("unrecorded")' <(jq '.by_role' "$OUT_A"))"
check "by_role.unrecorded.tokens.input (msg_sub2)" "3" "$(jq -r '.by_role.unrecorded.tokens.input' "$OUT_A")"
check "by_role.reviewer.tokens.cache_write_1h (msg_sub1, attributionAgent read)" "8" \
  "$(jq -r '.by_role.reviewer.tokens.cache_write_1h' "$OUT_A")"
check "unmeasured[] names the unrecorded agent role" "1" \
  "$(jq -r '[.unmeasured[] | select(test("agent role"))] | length' "$OUT_A")"

echo "-- by_project split --"
check "by_project.proj1 message share (6 of 7)" "100071" "$(jq -r '.by_project["proj1"].tokens.input' "$OUT_A")"
check "by_project.proj2 message share (1 of 7)" "1000"   "$(jq -r '.by_project["proj2"].tokens.input' "$OUT_A")"

# (msg_outwindow, dated 2026-08-01, is proven excluded by totals.tokens.input
# == 101071 above: it carries 555555 in every part, so its inclusion would
# have failed that check already — no separate assertion needed.)

echo "-- no message content, prompt text, session id or aid leaks into the report --"
check "no prompt/content text" "0" "$(grep -c 'SECRET_PROMPT_MARKER' "$OUT_A")"
check "no raw session id"      "0" "$(grep -c 'SESSIONID-SECRET-9999' "$OUT_A")"
check "no raw subagent aid"    "0" "$(grep -c 'AIDSECRET8888' "$OUT_A")"
# price_table.path / projects_dir.path do NOT exist (I4, loop-measurement T9 P0):
# neither is needed for the report to be useful, and both carried an absolute
# filesystem path (username included, on a default run) that the report's own
# notes[] claimed did not appear. What must never appear, path or no path, is a
# PER-MESSAGE transcript file path, i.e. any individual ".jsonl" filename.
check "no individual transcript file path (.jsonl) leaks" "0" "$(grep -c '\.jsonl' "$OUT_A")"
check "price_table has no path field" "0" "$(jq -r '.price_table | has("path")' "$OUT_A" | grep -c true)"
check "projects_dir has no path field" "0" "$(jq -r '.projects_dir | has("path")' "$OUT_A" | grep -c true)"
check "no absolute filesystem path (ROOT) leaks anywhere in the report" "0" \
  "$(grep -c "$ROOT" "$OUT_A")"

# =============================================================================
# FIXTURE SET B — a single, hand-verifiable row for the priced-window and
# unpriced-window cases in isolation (kept separate from Set A so the dollar
# math for these two cases stays a one-line check, not an N-row sum).
# =============================================================================
# --projects-dir must be a ROOT whose immediate subdirectories are projects
# (spend.sh globs "$projects_dir"/*/*.jsonl) — kept as its own root, separate
# from $PROJ, so this fixture never mixes with Set A's rows.
PROJ_B_ROOT="$ROOT/projects-b"
mkdir -p "$PROJ_B_ROOT/proj-b"
cat > "$PROJ_B_ROOT/proj-b/SB.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-11T10:00:00Z","effort":"high","message":{"id":"msg_priced","model":"model-a","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON

PRICES_UNPRICED="$ROOT/prices-empty.json"
cat > "$PRICES_UNPRICED" <<'JSON'
{"table_date":"2026-09-01","prices":{}}
JSON

echo "== Fixture Set B: priced window / unpriced window (isolated, hand-verified) =="
OUT_B_PRICED="$ROOT/out-b-priced.json"
"$SPEND" --projects-dir "$PROJ_B_ROOT" --price-table "$PRICES_MIXED" \
  --since "2026-09-11T00:00:00Z" --until "2026-09-11T23:59:59Z" > "$OUT_B_PRICED"
check "priced window: dollars = (1e6*10 + 1e5*30 + 1e6*1)/1e6 = 14.0" "14" \
  "$(jq -r '.totals.dollars' "$OUT_B_PRICED")"
check "priced window: unpriced_tokens = 0" "0" "$(jq -r '.totals.unpriced_tokens' "$OUT_B_PRICED")"

OUT_B_UNPRICED="$ROOT/out-b-unpriced.json"
"$SPEND" --projects-dir "$PROJ_B_ROOT" --price-table "$PRICES_UNPRICED" \
  --since "2026-09-11T00:00:00Z" --until "2026-09-11T23:59:59Z" > "$OUT_B_UNPRICED"
check "unpriced window: dollars = 0 (model-a not in this table)" "0" \
  "$(jq -r '.totals.dollars' "$OUT_B_UNPRICED")"
check "unpriced window: unpriced_tokens = 1e6+1e5+1e6" "2100000" \
  "$(jq -r '.totals.unpriced_tokens' "$OUT_B_UNPRICED")"
check "unpriced window: by_model.model-a.priced" "false" \
  "$(jq -r '.["by_model"]["model-a"].priced' "$OUT_B_UNPRICED")"

echo "== M3: notes[] states messages_deduped_dropped and messages_counted are not comparable =="
check "notes[] names the scan-vs-window scope mismatch" "1" \
  "$(jq -r '[.notes[]|select(test("messages_deduped_dropped") and test("SCAN") and test("WINDOW"))]|length' "$OUT_A")"

echo "== --price-table override is reflected and labelled =="
check "price_table.overridden true for a non-default file" "true" \
  "$(jq -r '.price_table.overridden' "$OUT_B_PRICED")"
check "price_table.date matches the override file, not the bundled one" "2026-09-01" \
  "$(jq -r '.price_table.date' "$OUT_B_PRICED")"

echo "== bundled default price table is used and NOT flagged as overridden =="
OUT_DEFAULT="$ROOT/out-default.json"
"$SPEND" --projects-dir "$PROJ_B_ROOT" \
  --since "2026-09-11T00:00:00Z" --until "2026-09-11T23:59:59Z" > "$OUT_DEFAULT"
check "default price table not overridden" "false" "$(jq -r '.price_table.overridden' "$OUT_DEFAULT")"
check "default price table date is the bundled one's" "$(jq -r '.table_date' "${HERE}/spend-prices.json")" \
  "$(jq -r '.price_table.date' "$OUT_DEFAULT")"

# =============================================================================
# Error paths and defaults
# =============================================================================
echo "== error paths =="
"$SPEND" --projects-dir "$PROJ" --price-table "$ROOT/does-not-exist.json" >/dev/null 2>"$ROOT/err1"; RC1=$?
check "missing --price-table file: non-zero exit" "1" "$( [ "$RC1" -ne 0 ] && echo 1 || echo 0 )"
check "missing --price-table file: error names the path" "1" \
  "$(grep -c 'does-not-exist.json' "$ROOT/err1")"

BAD_TABLE="$ROOT/bad-table.json"
echo '{"just":"wrong shape"}' > "$BAD_TABLE"
"$SPEND" --projects-dir "$PROJ" --price-table "$BAD_TABLE" >/dev/null 2>"$ROOT/err2"; RC2=$?
check "malformed price table: non-zero exit" "1" "$( [ "$RC2" -ne 0 ] && echo 1 || echo 0 )"

echo "== jq is a stated requirement =="
check "spend.sh documents jq as required" "1" "$(grep -c 'jq is required' "$SPEND")"

# =============================================================================
# FIXTURE SET C — --project (loop-measurement / thin-loop-driver T22): one
# repo's role breakdown. Two projects, "proj-c1" and "proj-c10", chosen so
# proj-c1's exact name is a PREFIX of proj-c10's — a substring/prefix-match
# bug would silently merge them in either direction. Each project carries a
# main-session row ("main" role, no attributionAgent) and a subagent row
# ("reviewer" role) so the by_role breakdown is provably scoped, not just the
# totals.
# =============================================================================
PROJ_C_ROOT="$ROOT/projects-c"
mkdir -p "$PROJ_C_ROOT/proj-c1/SC1/subagents" "$PROJ_C_ROOT/proj-c10/SC10/subagents"
cat > "$PROJ_C_ROOT/proj-c1/SC1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-12T10:00:00Z","effort":"high","message":{"id":"msg_c1_main","model":"model-a","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON
cat > "$PROJ_C_ROOT/proj-c1/SC1/subagents/agent-AC1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-12T10:01:00Z","effort":"high","attributionAgent":"reviewer","message":{"id":"msg_c1_sub","model":"model-a","usage":{"input_tokens":50,"output_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON
cat > "$PROJ_C_ROOT/proj-c10/SC10.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-12T10:00:00Z","effort":"high","message":{"id":"msg_c10_main","model":"model-a","usage":{"input_tokens":99999,"output_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON
cat > "$PROJ_C_ROOT/proj-c10/SC10/subagents/agent-AC10.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-12T10:01:00Z","effort":"high","attributionAgent":"reviewer","message":{"id":"msg_c10_sub","model":"model-a","usage":{"input_tokens":77777,"output_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON

echo "== Fixture Set C: --project scopes the whole report to one repo =="

OUT_C_UNFILTERED="$ROOT/out-c-unfiltered.json"
"$SPEND" --projects-dir "$PROJ_C_ROOT" --price-table "$PRICES_MIXED" \
  --since "2026-09-12T00:00:00Z" --until "2026-09-12T23:59:59Z" > "$OUT_C_UNFILTERED"
check "no --project: totals combine both repos (100+50+99999+77777)" "177926" \
  "$(jq -r '.totals.tokens.input' "$OUT_C_UNFILTERED")"
check "no --project: by_role.main combines both repos (100+99999)" "100099" \
  "$(jq -r '.by_role.main.tokens.input' "$OUT_C_UNFILTERED")"
check "no --project: project.filter is null" "null" "$(jq -r '.project.filter' "$OUT_C_UNFILTERED")"
check "no --project: project.status is not_filtered" "not_filtered" \
  "$(jq -r '.project.status' "$OUT_C_UNFILTERED")"

OUT_C1="$ROOT/out-c1.json"
"$SPEND" --projects-dir "$PROJ_C_ROOT" --price-table "$PRICES_MIXED" --project proj-c1 \
  --since "2026-09-12T00:00:00Z" --until "2026-09-12T23:59:59Z" > "$OUT_C1"
check "--project proj-c1: project.filter echoes the name" "proj-c1" "$(jq -r '.project.filter' "$OUT_C1")"
check "--project proj-c1: project.status is present" "present" "$(jq -r '.project.status' "$OUT_C1")"
check "--project proj-c1: totals scoped to proj-c1 only (100+50), NOT proj-c10's 99999+77777" "150" \
  "$(jq -r '.totals.tokens.input' "$OUT_C1")"
check "--project proj-c1: by_role.main scoped (100, not 100099)" "100" \
  "$(jq -r '.by_role.main.tokens.input' "$OUT_C1")"
check "--project proj-c1: by_role.reviewer scoped (50, not 77827)" "50" \
  "$(jq -r '.by_role.reviewer.tokens.input' "$OUT_C1")"
check "--project proj-c1: by_project has ONLY proj-c1 (prefix collision safe)" "true" \
  "$(jq -r '(.by_project|keys) == ["proj-c1"]' "$OUT_C1")"

OUT_C10="$ROOT/out-c10.json"
"$SPEND" --projects-dir "$PROJ_C_ROOT" --price-table "$PRICES_MIXED" --project proj-c10 \
  --since "2026-09-12T00:00:00Z" --until "2026-09-12T23:59:59Z" > "$OUT_C10"
check "--project proj-c10: totals scoped to proj-c10 only (99999+77777), NOT proj-c1's 100+50" "177776" \
  "$(jq -r '.totals.tokens.input' "$OUT_C10")"
check "--project proj-c10: by_role.reviewer scoped (77777, not 77827)" "77777" \
  "$(jq -r '.by_role.reviewer.tokens.input' "$OUT_C10")"

OUT_C_TYPO="$ROOT/out-c-typo.json"
"$SPEND" --projects-dir "$PROJ_C_ROOT" --price-table "$PRICES_MIXED" --project proj-c-does-not-exist \
  --since "2026-09-12T00:00:00Z" --until "2026-09-12T23:59:59Z" > "$OUT_C_TYPO"; RC_C_TYPO=$?
check "--project unknown folder: exit 0 (not an error)" "0" "$RC_C_TYPO"
check "--project unknown folder: project.status is absent" "absent" "$(jq -r '.project.status' "$OUT_C_TYPO")"
check "--project unknown folder: project.filter echoes the requested name" "proj-c-does-not-exist" \
  "$(jq -r '.project.filter' "$OUT_C_TYPO")"
check "--project unknown folder: messages_counted is 0" "0" "$(jq -r '.counts.messages_counted' "$OUT_C_TYPO")"
check "--project unknown folder: totals.dollars is 0" "0" "$(jq -r '.totals.dollars' "$OUT_C_TYPO")"
check "--project unknown folder: unmeasured names the mismatch (not a silent zero)" "true" \
  "$(jq -r '(.unmeasured|length) > 0 and ((.unmeasured|join(" ")) | contains("proj-c-does-not-exist"))' "$OUT_C_TYPO")"

echo "== default window (--days, no --since/--until) does not error =="
NOW_ROOT="$ROOT/projects-now"; mkdir -p "$NOW_ROOT/proj-now"
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$NOW_ROOT/proj-now/SNOW.jsonl" <<JSON
{"type":"assistant","timestamp":"$NOW_TS","effort":"high","message":{"id":"msg_now","model":"model-a","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON
OUT_DEFWIN="$ROOT/out-defwin.json"
"$SPEND" --projects-dir "$NOW_ROOT" --price-table "$PRICES_MIXED" > "$OUT_DEFWIN" 2>"$ROOT/defwin.err"; RC_DW=$?
check "default 7-day window: exit 0" "0" "$RC_DW"
check "default 7-day window: today's message is counted" "1" "$(jq -r '.counts.messages_counted' "$OUT_DEFWIN")"
check "default 7-day window: window.since is ~7 days before window.until" "true" \
  "$(jq -r '(.window.since < .window.until)' "$OUT_DEFWIN")"

echo
if [ "$fail" -eq 0 ]; then
  printf 'test-spend.sh: ALL %d checks passed\n' "$pass"; exit 0
else
  printf 'test-spend.sh: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1
fi
