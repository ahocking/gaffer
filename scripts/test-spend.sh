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

# =============================================================================
# FIXTURE SET D — per-role cache-read shape (loop-measurement T12). Values are
# chosen so median, p90 and max are three DIFFERENT numbers, a turn sits EXACTLY
# on the stated threshold (must not count as "over"), a duplicated message id
# must not add a turn, and a turn with no cache_read_input_tokens field must be
# excluded from the shape rather than read as a 0-token turn.
# =============================================================================
PROJ_D_ROOT="$ROOT/projects-d"
mkdir -p "$PROJ_D_ROOT/proj-d/SD/subagents" "$PROJ_D_ROOT/proj-d/SD2/subagents"
# drow <minute> <id> <attribution-json-fragment> <usage-cache-read-fragment>
drow() {
  printf '{"type":"assistant","timestamp":"2026-09-13T10:%02d:00Z","effort":"high"%s,"message":{"id":"%s","model":"model-a","usage":{"input_tokens":1,"output_tokens":1%s,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}\n' \
    "$1" "$3" "$2" "$4"
}
# main: 11 distinct turns; sorted [1,2,3,4,5,6,7,8,50000,50001,200000]
# -> median = element floor(11*0.5)=5 -> 6; p90 = element floor(11*0.9)=9 -> 50001;
#    max 200000; strictly over 50000: 50001 and 200000 -> 2 (50000 itself is not).
# Plus a duplicate row of the 200000 turn (same id, 2s later): dedup keeps 11 turns.
{
  m=0
  for v in 7 3 50000 1 200000 5 8 50001 2 6 4; do
    m=$((m+1)); drow "$m" "msg_d_main$m" "" ",\"cache_read_input_tokens\":$v"
  done
  drow 5 "msg_d_main5" "" ',"cache_read_input_tokens":200000'
} > "$PROJ_D_ROOT/proj-d/SD.jsonl"
# reviewer: [30, 10] measured + one turn with the field ABSENT.
#   Correct: turns 2, turns_unmeasured 1, median element 1 of [10,30] -> 30.
#   If the absent turn were read as 0: [0,10,30] -> median 10, turns 3.
{
  drow 20 msg_d_rev1 ',"attributionAgent":"reviewer"' ',"cache_read_input_tokens":30'
  drow 21 msg_d_rev2 ',"attributionAgent":"reviewer"' ',"cache_read_input_tokens":10'
  drow 22 msg_d_rev3 ',"attributionAgent":"reviewer"' ''
} > "$PROJ_D_ROOT/proj-d/SD/subagents/agent-ADREV.jsonl"
# researcher: its ONLY turn lacks the field -> the whole shape is unmeasured (null).
drow 30 msg_d_res1 ',"attributionAgent":"researcher"' '' \
  > "$PROJ_D_ROOT/proj-d/SD2/subagents/agent-ADRES.jsonl"

echo "== Fixture Set D: per-role cache-read shape (median / p90 / max / over-threshold) =="
OUT_D="$ROOT/out-d.json"
"$SPEND" --projects-dir "$PROJ_D_ROOT" --price-table "$PRICES_MIXED" \
  --since "2026-09-13T00:00:00Z" --until "2026-09-13T23:59:59Z" > "$OUT_D" 2>"$ROOT/out-d.err"
check "set D: exit 0" "0" "$?"
check "report states the threshold size (50000 tokens)" "50000" \
  "$(jq -r '.cache_read_shape_method.threshold_tokens' "$OUT_D")"
check "report states 'over' means strictly greater" "1" \
  "$(jq -r '[.cache_read_shape_method.over_threshold | select(test("strictly greater"))] | length' "$OUT_D")"
check "main: turns = 11 (duplicate message id not counted twice)" "11" \
  "$(jq -r '.by_role.main.cache_read_shape.turns' "$OUT_D")"
check "main: median = 6" "6" "$(jq -r '.by_role.main.cache_read_shape.median' "$OUT_D")"
check "main: p90 = 50001 (distinct from max)" "50001" "$(jq -r '.by_role.main.cache_read_shape.p90' "$OUT_D")"
check "main: max = 200000" "200000" "$(jq -r '.by_role.main.cache_read_shape.max' "$OUT_D")"
check "main: turns_over_threshold = 2 (a turn AT 50000 is not over)" "2" \
  "$(jq -r '.by_role.main.cache_read_shape.turns_over_threshold' "$OUT_D")"
check "main: turns_unmeasured = 0" "0" "$(jq -r '.by_role.main.cache_read_shape.turns_unmeasured' "$OUT_D")"
check "reviewer: absent cache-read field excluded -> turns 2" "2" \
  "$(jq -r '.by_role.reviewer.cache_read_shape.turns' "$OUT_D")"
check "reviewer: turns_unmeasured = 1" "1" "$(jq -r '.by_role.reviewer.cache_read_shape.turns_unmeasured' "$OUT_D")"
check "reviewer: median = 30 (not 10, which reading the absent turn as 0 would give)" "30" \
  "$(jq -r '.by_role.reviewer.cache_read_shape.median' "$OUT_D")"
check "researcher: no measured turn -> median/p90/max/turns_over_threshold all null, never 0" \
  "null null null null" \
  "$(jq -r '.by_role.researcher.cache_read_shape | "\(.median) \(.p90) \(.max) \(.turns_over_threshold)"' "$OUT_D")"
check "unmeasured[] names the missing cache-read field (2 messages)" "1" \
  "$(jq -r '[.unmeasured[] | select(test("^2 message\\(s\\) carried no cache_read_input_tokens"))] | length' "$OUT_D")"
check "set A: every role in by_role carries a cache_read_shape" "true" \
  "$(jq -r '[.by_role[] | has("cache_read_shape")] | all' "$OUT_A")"

# =============================================================================
# FIXTURE SET E — large cache writes by cause (loop-measurement T13). Every
# write below is > 50000 cache-write tokens unless stated. Each context's
# "prev ctx" is the previous turn's cache_read + cache writes: a write whose
# cache_read reaches it re-read the whole previous context (prefix reused).
#   main SE (model-a, effort high, 1h writes):
#     t1 10:00  first turn                         -> new_session_or_subagent
#     t2 10:01  small write (not large)
#     t3 10:02  cr = prev ctx (reused)             -> new_content
#     t3 dup at +2s (same message id)              -> must not count again
#     compact_boundary row at 10:02:30
#     t4 10:03  cr dropped, after the marker       -> compaction_or_prefix_change
#     t5 12:00  model-z AND a ~2h gap, not reused  -> TWO causes fit (model_changed,
#               idle_gap_past_cache_lifetime): model_changed wins, counted once
#     t6 12:01  effort high -> xhigh, not reused   -> effort_changed
#     t7 14:00  ~2h gap past the 1h lifetime       -> idle_gap_past_cache_lifetime
#     t8 14:01  short gap, same model/effort, cr dropped, no marker
#               -> no test fits                    -> unknown_cause (never guessed)
#     t9 14:02  write EXACTLY 50000                -> not large, not counted
#   subagent (implementer, NO effort field on any row, 5m writes):
#     s1 11:00  first turn of the subagent         -> new_session_or_subagent
#     s2 11:10  10-min gap past the 5m lifetime; effort unrecorded on both
#               turns is no change                 -> idle_gap_past_cache_lifetime
#     s3 11:11  no cache_read_input_tokens field: reuse cannot be judged
#                                                  -> unknown_cause
#   main SE2: p1 at 23:59 the day BEFORE the window (small), p2 in the window
#     re-reads it                                  -> new_content, NOT new_session
#     (the previous turn is found even though it predates the window)
# =============================================================================
PROJ_E_ROOT="$ROOT/projects-e"
mkdir -p "$PROJ_E_ROOT/proj-e/SE/subagents"
PRICES_E="$ROOT/prices-e.json"
cat > "$PRICES_E" <<'JSON'
{"table_date":"2026-09-01","prices":{"model-a":{"input":10,"cache_write_5m":12,"cache_write_1h":20,"cache_read":1,"output":30},"model-z":{"input":10,"cache_write_5m":12,"cache_write_1h":20,"cache_read":1,"output":30}}}
JSON
# erow <ts> <id> <model> <extra-json-fragment> <cache-read-fragment> <w5m> <w1h>
erow() {
  printf '{"type":"assistant","timestamp":"%s"%s,"message":{"id":"%s","model":"%s","usage":{"input_tokens":1,"output_tokens":1%s,"cache_creation_input_tokens":%d,"cache_creation":{"ephemeral_5m_input_tokens":%d,"ephemeral_1h_input_tokens":%d}}}}\n' \
    "$1" "$4" "$2" "$3" "$5" "$(( $6 + $7 ))" "$6" "$7"
}
HI=',"effort":"high"'; XH=',"effort":"xhigh"'
{
  erow 2026-09-14T10:00:00Z e_t1 model-a "$HI" ',"cache_read_input_tokens":0'      0 60000
  erow 2026-09-14T10:01:00Z e_t2 model-a "$HI" ',"cache_read_input_tokens":60000'  0 100
  erow 2026-09-14T10:02:00Z e_t3 model-a "$HI" ',"cache_read_input_tokens":60100'  0 70000
  erow 2026-09-14T10:02:02Z e_t3 model-a "$HI" ',"cache_read_input_tokens":60100'  0 70000
  printf '{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-14T10:02:30.000Z"}\n'
  erow 2026-09-14T10:03:00Z e_t4 model-a "$HI" ',"cache_read_input_tokens":5000'   0 80000
  erow 2026-09-14T12:00:00Z e_t5 model-z "$HI" ',"cache_read_input_tokens":0'      0 90000
  erow 2026-09-14T12:01:00Z e_t6 model-z "$XH" ',"cache_read_input_tokens":1000'   0 55000
  erow 2026-09-14T14:00:00Z e_t7 model-z "$XH" ',"cache_read_input_tokens":0'      0 65000
  erow 2026-09-14T14:01:00Z e_t8 model-z "$XH" ',"cache_read_input_tokens":100'    0 75000
  erow 2026-09-14T14:02:00Z e_t9 model-z "$XH" ',"cache_read_input_tokens":75100'  0 50000
} > "$PROJ_E_ROOT/proj-e/SE.jsonl"
SUBA=',"attributionAgent":"implementer"'
{
  erow 2026-09-14T11:00:00Z e_s1 model-a "$SUBA" ',"cache_read_input_tokens":0' 52000 0
  erow 2026-09-14T11:10:00Z e_s2 model-a "$SUBA" ',"cache_read_input_tokens":0' 53000 0
  erow 2026-09-14T11:11:00Z e_s3 model-a "$SUBA" ''                             54000 0
} > "$PROJ_E_ROOT/proj-e/SE/subagents/agent-AESUB.jsonl"
{
  erow 2026-09-13T23:59:00Z e_p1 model-a "$HI" ',"cache_read_input_tokens":0'  0 10
  erow 2026-09-14T00:00:30Z e_p2 model-a "$HI" ',"cache_read_input_tokens":10' 0 51000
} > "$PROJ_E_ROOT/proj-e/SE2.jsonl"

echo "== Fixture Set E: large cache writes grouped by cause =="
OUT_E="$ROOT/out-e.json"
"$SPEND" --projects-dir "$PROJ_E_ROOT" --price-table "$PRICES_E" \
  --since "2026-09-14T00:00:00Z" --until "2026-09-14T23:59:59Z" > "$OUT_E" 2>"$ROOT/out-e.err"
check "set E: exit 0" "0" "$?"
cwc() { jq -r ".cache_write_causes.by_cause.$1 | \"\(.count) \(.tokens) \(.dollars)\"" "$OUT_E"; }
check "report states the large-write size (50000 tokens)" "50000" \
  "$(jq -r '.cache_write_causes.method.threshold_tokens' "$OUT_E")"
check "report states the order causes are tried in" \
  "new_session_or_subagent,compaction_or_prefix_change,model_changed,effort_changed,idle_gap_past_cache_lifetime,new_content" \
  "$(jq -r '.cache_write_causes.method.cause_order | join(",")' "$OUT_E")"
check "new session or subagent: t1 + s1 (60000 1h + 52000 5m), \$1.2 + \$0.624" "2 112000 1.824" \
  "$(cwc new_session_or_subagent)"
check "compaction: t4 after the compact_boundary row" "1 80000 1.6" "$(cwc compaction_or_prefix_change)"
check "model changed: t5 (also fits idle) counted ONCE, under model_changed" "1 90000 1.8" "$(cwc model_changed)"
check "effort changed: t6 high -> xhigh" "1 55000 1.1" "$(cwc effort_changed)"
check "idle gap: t7 past 1h + s2 past 5m (effort unrecorded on both = no change)" "2 118000 1.936" \
  "$(cwc idle_gap_past_cache_lifetime)"
check "new content: t3 + p2 (p2's previous turn predates the window)" "2 121000 2.42" "$(cwc new_content)"
check "unknown cause: t8 (nothing fits) + s3 (reuse unjudgeable)" "2 129000 2.148" "$(cwc unknown_cause)"
check "total: 11 large writes (dup of t3 not recounted; t9 at exactly 50000 not large)" "11" \
  "$(jq -r '.cache_write_causes.total.count' "$OUT_E")"
check "every write counted once: by_cause counts sum to total" "true" \
  "$(jq -r '.cache_write_causes | ([.by_cause[].count] | add) == .total.count' "$OUT_E")"
check "unmeasured[] names the 2 unknown-cause writes" "1" \
  "$(jq -r '[.unmeasured[] | select(test("^2 large cache write\\(s\\) could not be given a cause"))] | length' "$OUT_E")"
check "set A: every cause bucket is listed even when zero" "7" \
  "$(jq -r '.cache_write_causes.by_cause | length' "$OUT_A")"

echo
if [ "$fail" -eq 0 ]; then
  printf 'test-spend.sh: ALL %d checks passed\n' "$pass"; exit 0
else
  printf 'test-spend.sh: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1
fi
