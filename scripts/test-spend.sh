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

# --- the bundled table prices claude-opus-5-5 (model-comparison-harness T20) --
# One claude-opus-5-5 row with a DIFFERENT count in each of the five parts, run
# against the bundled table (no --price-table), so every one of its five rates
# is pinned by the one dollar total. Expected rates are the pricing page's own
# cells for Claude Opus 5.5: input 4, 5m write 5, 1h write 8, cache hit 0.20,
# output 20 ($/MTok). The page prices its cache hit at 0.05x input, so a
# cache_read re-derived with the usual 0.1x rule (0.40) would read 44, and a
# swapped 5m/1h pair would read 39 — both caught here.
PROJ_O55_ROOT="$ROOT/projects-opus55"
mkdir -p "$PROJ_O55_ROOT/proj-o55"
cat > "$PROJ_O55_ROOT/proj-o55/SO55.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-11T10:00:00Z","effort":"high","message":{"id":"msg_opus55","model":"claude-opus-5-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":10000000,"cache_creation_input_tokens":5000000,"cache_creation":{"ephemeral_5m_input_tokens":2000000,"ephemeral_1h_input_tokens":3000000}}}}
JSON
OUT_O55="$ROOT/out-opus55.json"
"$SPEND" --projects-dir "$PROJ_O55_ROOT" \
  --since "2026-09-11T00:00:00Z" --until "2026-09-11T23:59:59Z" > "$OUT_O55"
check "bundled table: claude-opus-5-5 is priced" "true" \
  "$(jq -r '.by_model["claude-opus-5-5"].priced' "$OUT_O55")"
check "bundled table: claude-opus-5-5 row leaves no unpriced tokens" "0" \
  "$(jq -r '.totals.unpriced_tokens' "$OUT_O55")"
check "bundled table: claude-opus-5-5 dollars = (1e6*4 + 1e5*20 + 1e7*0.20 + 2e6*5 + 3e6*8)/1e6 = 42" "42" \
  "$(jq -r '.totals.dollars' "$OUT_O55")"

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

# =============================================================================
# FIXTURE SET F — spend --save (loop-measurement T14). A fake HOME whose user
# name ("fixture-zq-user") must not survive into the saved file. Three project
# folders, named the way Claude Code names them (every non-alphanumeric
# character of the absolute path replaced by '-'):
#   -Users-fixture-zq-user-workspace-app   under home      -> "~-workspace-app"
#   -Users-fixture-zq-user                 home itself     -> "~"
#   -opt-shared-repo                       outside home    -> kept as-is
# =============================================================================
FAKE_HOME="/Users/fixture-zq-user"
PROJ_F_ROOT="$ROOT/projects-f"
mkdir -p "$PROJ_F_ROOT/-Users-fixture-zq-user-workspace-app/SF1/subagents" \
         "$PROJ_F_ROOT/-Users-fixture-zq-user" "$PROJ_F_ROOT/-opt-shared-repo"
cat > "$PROJ_F_ROOT/-Users-fixture-zq-user-workspace-app/SF1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-15T10:00:00Z","effort":"high","message":{"id":"msg_f1","model":"model-a","content":[{"type":"text","text":"SECRET_PROMPT_MARKER_fff"}],"usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-09-15T10:02:00Z","message":{"id":"msg_f1b","model":"model-b","usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":5,"cache_creation_input_tokens":7}}}
JSON
cat > "$PROJ_F_ROOT/-Users-fixture-zq-user-workspace-app/SF1/subagents/agent-AF1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-15T10:01:00Z","effort":"xhigh","attributionAgent":"reviewer","message":{"id":"msg_f2","model":"model-a","usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":2,"cache_creation_input_tokens":8,"cache_creation":{"ephemeral_5m_input_tokens":8,"ephemeral_1h_input_tokens":0}}}}
JSON
cat > "$PROJ_F_ROOT/-Users-fixture-zq-user/SF2.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-15T11:00:00Z","effort":"high","message":{"id":"msg_f3","model":"model-a","usage":{"input_tokens":30,"output_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON
cat > "$PROJ_F_ROOT/-opt-shared-repo/SF3.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-15T12:00:00Z","effort":"high","message":{"id":"msg_f4","model":"model-a","usage":{"input_tokens":4,"output_tokens":4,"cache_read_input_tokens":4,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON

F_WIN=(--since "2026-09-15T00:00:00Z" --until "2026-09-15T23:59:59Z")
SAVE_F="$ROOT/saved-f.json"
echo "== Fixture Set F: spend --save writes only the allowed fields, home prefix stripped =="
HOME="$FAKE_HOME" "$SPEND" --projects-dir "$PROJ_F_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}" \
  --save "$SAVE_F" --machine laptop-2 > "$ROOT/out-f.json" 2>"$ROOT/out-f.err"
check "save: exit 0" "0" "$?"
check "save: file written" "1" "$( [ -f "$SAVE_F" ] && echo 1 || echo 0 )"
check "save: stderr names the saved file" "1" "$(grep -c "^SAVED=$SAVE_F\$" "$ROOT/out-f.err")"
HOME="$FAKE_HOME" "$SPEND" --projects-dir "$PROJ_F_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}" \
  > "$ROOT/out-f-nosave.json" 2>/dev/null
check "save: stdout report is byte-identical to a run without --save" "0" \
  "$(cmp -s "$ROOT/out-f.json" "$ROOT/out-f-nosave.json"; echo $?)"
check "save: top-level fields are exactly the allowed set" \
  "by_effort,by_model,by_project,by_role,counts,machine,price_table_date,saved_at,totals,window" \
  "$(jq -r 'keys | join(",")' "$SAVE_F")"
# Every LEAF path must be one of the allowed shapes; the check prints any that
# is not, so an extra nested field (a label, a shape, a note, a path) fails by
# name. Expected: no disallowed path, and a non-trivial number of leaves.
check "save: no leaf field outside counts/tokens/dollars/labels/window/date/time/machine" "[]" \
  "$(jq -c '
    ["input","cache_write_5m","cache_write_1h","cache_read","output"] as $parts
    | ["dollars","unpriced_tokens","cache_write_unmeasured_tokens"] as $money
    | ["files_scanned","messages_counted","messages_no_id","messages_deduped_dropped",
       "messages_excluded_no_usage_or_ts","messages_excluded_synthetic"] as $counts
    | [ paths(scalars) | select(
          ( . == ["machine"] or . == ["saved_at"] or . == ["price_table_date"]
            or . == ["window","since"] or . == ["window","until"]
            or (length == 2 and .[0] == "counts" and (.[1] as $k | $counts | index($k)))
            or (length == 2 and .[0] == "totals" and (.[1] as $k | $money | index($k)))
            or (length == 3 and .[0] == "totals" and .[1] == "tokens" and (.[2] as $k | $parts | index($k)))
            or (length == 3 and (.[0] | IN("by_project","by_model","by_role","by_effort")) and (.[2] as $k | $money | index($k)))
            or (length == 4 and (.[0] | IN("by_project","by_model","by_role","by_effort")) and .[2] == "tokens" and (.[3] as $k | $parts | index($k)))
          ) | not ) ]' "$SAVE_F")"
check "save: leaf count is non-trivial (the allowlist check had something to check)" "true" \
  "$(jq '[paths(scalars)] | length > 50' "$SAVE_F")"
check "save: by_project keys have the home prefix stripped" "-opt-shared-repo,~,~-workspace-app" \
  "$(jq -r '.by_project | keys | join(",")' "$SAVE_F")"
check "save: no home-directory segment (user name) survives anywhere" "0" "$(grep -c 'fixture-zq-user' "$SAVE_F")"
check "save: no 'Users' path segment survives anywhere" "0" "$(grep -c 'Users' "$SAVE_F")"
check "save: no fixture filesystem path survives" "0" "$(grep -c "$ROOT" "$SAVE_F")"
check "save: no prompt text, session id or .jsonl name" "0" "$(grep -cE 'SECRET_PROMPT|SF1|AF1|\.jsonl' "$SAVE_F")"
check "save: machine label" "laptop-2" "$(jq -r '.machine' "$SAVE_F")"
check "save: window and price-table date match the report" "true" \
  "$(jq -n --slurpfile s "$SAVE_F" --slurpfile r "$ROOT/out-f.json" \
      '$s[0].window == $r[0].window and $s[0].price_table_date == $r[0].price_table.date')"
check "save: saved_at is a UTC ISO time" "1" \
  "$(jq -r '.saved_at' "$SAVE_F" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')"
check "save: totals equal the report's totals (tokens, dollars, unpriced, unsplit)" "true" \
  "$(jq -n --slurpfile s "$SAVE_F" --slurpfile r "$ROOT/out-f.json" '$s[0].totals == $r[0].totals')"
check "save: project values sum to the totals (nothing lost in the key rewrite)" "true" \
  "$(jq '([.by_project[].tokens.input] | add) == .totals.tokens.input
         and ([.by_project[].unpriced_tokens] | add) == .totals.unpriced_tokens' "$SAVE_F")"
check "save: unpriced and unsplit tokens carried, not zeroed (model-b 5+5+5+7; unsplit 7)" "22 7" \
  "$(jq -r '"\(.totals.unpriced_tokens) \(.totals.cache_write_unmeasured_tokens)"' "$SAVE_F")"
check "save: model, role and effort labels present" "model-a,model-b|main,reviewer|high,unrecorded,xhigh" \
  "$(jq -r '"\(.by_model|keys|join(","))|\(.by_role|keys|join(","))|\(.by_effort|keys|join(","))"' "$SAVE_F")"

echo "-- --save refusals write nothing --"
refused() { # refused <label> <save-path> <spend args...>
  local lbl="$1" f="$2"; shift 2
  HOME="$FAKE_HOME" "$SPEND" "$@" --save "$f" >/dev/null 2>"$ROOT/refuse.err"; local rc=$?
  check "$lbl: non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
  check "$lbl: no file written" "0" "$( [ -e "$f" ] && echo 1 || echo 0 )"
}
refused "no --machine" "$ROOT/r1.json" --projects-dir "$PROJ_F_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}"
refused "bad --machine label" "$ROOT/r2.json" --projects-dir "$PROJ_F_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}" --machine 'a/b'
refused "with --project" "$ROOT/r3.json" --projects-dir "$PROJ_F_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}" --machine m --project -opt-shared-repo
refused "projects dir absent (unmeasured, not zero)" "$ROOT/r4.json" --projects-dir "$ROOT/no-such-dir" --price-table "$PRICES_MIXED" "${F_WIN[@]}" --machine m
# A label read from a transcript that carries the raw home path (here, an
# attributionAgent) must trip the backstop rather than be saved.
PROJ_G_ROOT="$ROOT/projects-g"; mkdir -p "$PROJ_G_ROOT/-opt-x/SG/subagents"
cat > "$PROJ_G_ROOT/-opt-x/SG/subagents/agent-AG.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-15T10:00:00Z","attributionAgent":"/Users/fixture-zq-user/agents/x","message":{"id":"msg_g1","model":"model-a","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON
refused "home path in a label (backstop)" "$ROOT/r5.json" --projects-dir "$PROJ_G_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}" --machine m
check "backstop: refusal names the surviving home segment" "1" "$(grep -c 'home-directory segment would survive' "$ROOT/refuse.err")"

echo "-- --save on a Windows (Git Bash) home: native drive-letter folders --"
# Git Bash sets HOME=/c/Users/<name>, but Claude Code names the folder from the
# native path C:\Users\<name> -> C--Users-<name>-..., which the POSIX encoding
# (-c-Users-<name>) never matches. Two folders, the drive letter in both cases,
# must strip; USERPROFILE is unset so the drive-letter rewrite is what is tested.
PROJ_W_ROOT="$ROOT/projects-w"
mkdir -p "$PROJ_W_ROOT/C--Users-fixture-zq-win-workspace-app" "$PROJ_W_ROOT/c--users-fixture-zq-win-workspace-lib"
cat > "$PROJ_W_ROOT/C--Users-fixture-zq-win-workspace-app/SW1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-15T10:00:00Z","message":{"id":"msg_w1","model":"model-a","usage":{"input_tokens":3,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON
cat > "$PROJ_W_ROOT/c--users-fixture-zq-win-workspace-lib/SW2.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-15T10:05:00Z","message":{"id":"msg_w2","model":"model-a","usage":{"input_tokens":4,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
JSON
SAVE_W="$ROOT/saved-w.json"
env -u USERPROFILE HOME="/c/Users/fixture-zq-win" "$SPEND" --projects-dir "$PROJ_W_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}" \
  --save "$SAVE_W" --machine win >/dev/null 2>"$ROOT/w.err"
check "windows home: exit 0" "0" "$?"
check "windows home: drive-letter folders stripped (either case)" "~-workspace-app,~-workspace-lib" \
  "$(jq -r '.by_project | keys | join(",")' "$SAVE_W" 2>/dev/null)"
check "windows home: user name never in the file" "0" "$(grep -ci 'fixture-zq-win' "$SAVE_W" 2>/dev/null || true)"
# USERPROFILE names the home when HOME does not look like one (HOME unrelated).
SAVE_W2="$ROOT/saved-w2.json"
USERPROFILE='C:\Users\fixture-zq-win' HOME="/home/fixture-other" "$SPEND" --projects-dir "$PROJ_W_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}" \
  --save "$SAVE_W2" --machine win >/dev/null 2>/dev/null
check "USERPROFILE home: folders stripped" "~-workspace-app,~-workspace-lib" \
  "$(jq -r '.by_project | keys | join(",")' "$SAVE_W2" 2>/dev/null)"
# Encoding-independent backstop: a folder carrying the user name under a home
# form nothing strips (another drive, another root) must refuse, not save.
PROJ_W3_ROOT="$ROOT/projects-w3"; mkdir -p "$PROJ_W3_ROOT/D--home-FIXTURE-ZQ-WIN-x"
cp "$PROJ_W_ROOT/C--Users-fixture-zq-win-workspace-app/SW1.jsonl" "$PROJ_W3_ROOT/D--home-FIXTURE-ZQ-WIN-x/SW3.jsonl"
env -u USERPROFILE HOME="/c/Users/fixture-zq-win" "$SPEND" --projects-dir "$PROJ_W3_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}" \
  --save "$ROOT/r7.json" --machine win >/dev/null 2>"$ROOT/r7.err"; RC7=$?
check "user-name segment backstop: non-zero exit" "1" "$( [ "$RC7" -ne 0 ] && echo 1 || echo 0 )"
check "user-name segment backstop: no file written" "0" "$( [ -e "$ROOT/r7.json" ] && echo 1 || echo 0 )"
check "user-name segment backstop: refusal names the segment" "1" "$(grep -c 'home-directory segment would survive' "$ROOT/r7.err")"

"$SPEND" --projects-dir "$PROJ_F_ROOT" --price-table "$PRICES_MIXED" "${F_WIN[@]}" --machine m >/dev/null 2>"$ROOT/r6.err"; RC6=$?
check "--machine without --save: non-zero exit" "1" "$( [ "$RC6" -ne 0 ] && echo 1 || echo 0 )"

# =============================================================================
# FIXTURE SET H — spend --combine (loop-measurement T15). SAVE_F (Set F,
# machine "laptop-2") is combined with a second machine's real --save output
# ("desk-1"), whose home differs but whose "workspace-app" folder strips to the
# same key, so the by-key sum across machines is exercised end to end. The
# supersede / mismatch cases derive variants of those two files with jq.
# Hand-verified figures: laptop-2 input 1000+5+200+30+4 = 1239, of which
# ~-workspace-app is 1000+5+200 = 1205; desk-1 input 500.
# =============================================================================
PROJ_H_ROOT="$ROOT/projects-h"; mkdir -p "$PROJ_H_ROOT/-Users-fixture-zq-desk-workspace-app"
cat > "$PROJ_H_ROOT/-Users-fixture-zq-desk-workspace-app/SH1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-09-15T09:00:00Z","effort":"max","message":{"id":"msg_h1","model":"model-c","usage":{"input_tokens":500,"output_tokens":50,"cache_read_input_tokens":40,"cache_creation_input_tokens":6,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":6}}}}
JSON
PRICES_H="$ROOT/prices-h.json"
cat > "$PRICES_H" <<'JSON'
{"table_date":"2026-09-01","prices":{"model-c":{"input":2,"cache_write_5m":3,"cache_write_1h":4,"cache_read":1,"output":8}}}
JSON
SAVE_H="$ROOT/saved-h.json"
HOME="/Users/fixture-zq-desk" "$SPEND" --projects-dir "$PROJ_H_ROOT" --price-table "$PRICES_H" "${F_WIN[@]}" \
  --save "$SAVE_H" --machine desk-1 >/dev/null 2>/dev/null
echo "== Fixture Set H: spend --combine sums saved totals across machines =="
check "combine fixture: desk-1 save written" "1" "$( [ -f "$SAVE_H" ] && echo 1 || echo 0 )"

C1="$ROOT/comb-1.json"
"$SPEND" --combine "$SAVE_F" "$SAVE_H" > "$C1" 2>"$ROOT/comb-1.err"
check "combine: exit 0" "0" "$?"
check "combine: names each machine included" "desk-1,laptop-2" "$(jq -r '[.machines[].machine] | join(",")' "$C1")"
check "combine: machines carry file, window, date and save time" "true" \
  "$(jq '[.machines[] | has("file") and has("window") and has("price_table_date") and has("saved_at")] | all' "$C1")"
check "combine: total input tokens summed (1239 + 500)" "1739" "$(jq -r '.totals.tokens.input' "$C1")"
check "combine: every cost part summed" "true" \
  "$(jq -n --slurpfile c "$C1" --slurpfile a "$SAVE_F" --slurpfile b "$SAVE_H" \
      '$c[0].totals.tokens == ($a[0].totals.tokens | with_entries(.value += $b[0].totals.tokens[.key]))')"
check "combine: dollars summed" "true" \
  "$(jq -n --slurpfile c "$C1" --slurpfile a "$SAVE_F" --slurpfile b "$SAVE_H" \
      '$c[0].totals.dollars == ((($a[0].totals.dollars + $b[0].totals.dollars) * 1000000 | round) / 1000000)')"
check "combine: unpriced tokens carried, not priced (laptop-2's model-b)" "22" "$(jq -r '.totals.unpriced_tokens' "$C1")"
check "combine: same project key across machines sums (1205 + 500)" "1705" \
  "$(jq -r '.by_project["~-workspace-app"].tokens.input' "$C1")"
check "combine: project keys are the union" "-opt-shared-repo,~,~-workspace-app" "$(jq -r '.by_project | keys | join(",")' "$C1")"
check "combine: model, role and effort breakdowns are the union" "model-a,model-b,model-c|main,reviewer|high,max,unrecorded,xhigh" \
  "$(jq -r '"\(.by_model|keys|join(","))|\(.by_role|keys|join(","))|\(.by_effort|keys|join(","))"' "$C1")"
check "combine: role main sums across machines" "true" \
  "$(jq -n --slurpfile c "$C1" --slurpfile a "$SAVE_F" --slurpfile b "$SAVE_H" \
      '$c[0].by_role.main.tokens.input == ($a[0].by_role.main.tokens.input + $b[0].by_role.main.tokens.input)')"
check "combine: every breakdown value carries the five cost parts" "true" \
  "$(jq '[.by_project, .by_model, .by_role, .by_effort | .[] | .tokens | keys == ["cache_read","cache_write_1h","cache_write_5m","input","output"]] | all' "$C1")"
check "combine: breakdowns sum to the totals" "true" \
  "$(jq '([.by_project[].tokens.input] | add) == .totals.tokens.input and ([.by_model[].tokens.output] | add) == .totals.tokens.output' "$C1")"
check "combine: counts summed" "true" \
  "$(jq -n --slurpfile c "$C1" --slurpfile a "$SAVE_F" --slurpfile b "$SAVE_H" \
      '$c[0].counts.messages_counted == ($a[0].counts.messages_counted + $b[0].counts.messages_counted)')"
check "combine: shared window and date reported" "2026-09-15T00:00:00Z..2026-09-15T23:59:59Z|2026-09-01" \
  "$(jq -r '"\(.window.since)..\(.window.until)|\(.price_table_date)"' "$C1")"
check "combine: matching files raise no warning" "0|0" \
  "$(jq -r '.warnings | length' "$C1")|$(grep -c 'WARNING' "$ROOT/comb-1.err")"
check "combine: nothing superseded" "0" "$(jq -r '.superseded | length' "$C1")"
check "combine: cache-read shape and causes stated as not measured, not zero" "1" \
  "$(jq '[.unmeasured[] | select(test("not measured in a combined report"))] | length' "$C1")"

echo "-- later-saved wins for one machine label and window --"
# An OLDER save from laptop-2 for the same window, with different (doubled)
# numbers: it must not be counted, whichever order the files are given.
OLD_F="$ROOT/saved-f-older.json"
jq '.saved_at = "2026-09-01T00:00:00Z" | .totals.tokens.input *= 2 | .totals.dollars *= 2
    | .by_project["~-workspace-app"].tokens.input *= 2' "$SAVE_F" > "$OLD_F"
C2="$ROOT/comb-2.json"; C2R="$ROOT/comb-2r.json"
"$SPEND" --combine "$OLD_F" "$SAVE_F" "$SAVE_H" > "$C2" 2>"$ROOT/comb-2.err"
check "supersede: exit 0" "0" "$?"
"$SPEND" --combine "$SAVE_F" "$SAVE_H" "$OLD_F" > "$C2R" 2>/dev/null
check "supersede: only the later-saved is counted (totals as without the older file)" "1739|true" \
  "$(jq -r '.totals.tokens.input' "$C2")|$(jq -n --slurpfile x "$C2" --slurpfile y "$C1" '$x[0].totals == $y[0].totals and $x[0].by_project == $y[0].by_project')"
check "supersede: order of arguments does not change what is counted" "true" \
  "$(jq -n --slurpfile x "$C2" --slurpfile y "$C2R" '$x[0].totals == $y[0].totals')"
check "supersede: the older file is listed as superseded" "saved-f-older.json|laptop-2|saved-f.json" \
  "$(jq -r '.superseded[] | "\(.file)|\(.machine)|\(.superseded_by.file)"' "$C2")"
check "supersede: machine counted once" "desk-1,laptop-2" "$(jq -r '[.machines[].machine] | join(",")' "$C2")"
check "supersede: warning names the superseded file" "1" \
  "$(jq '[.warnings[] | select(test("superseded: saved-f-older.json"))] | length' "$C2")"
check "supersede: warning reaches stderr" "1" "$(grep -c '^WARNING: superseded: saved-f-older.json' "$ROOT/comb-2.err")"
C3="$ROOT/comb-3.json"
"$SPEND" --combine "$SAVE_F" "$SAVE_F" > "$C3" 2>/dev/null
check "tie: the same file twice is counted once" "true" \
  "$(jq -n --slurpfile x "$C3" --slurpfile s "$SAVE_F" '$x[0].totals == $s[0].totals')"
check "tie: warning says it was saved at the same time" "1" \
  "$(jq '[.warnings[] | select(test("saved at the same time"))] | length' "$C3")"
# A tie between DIFFERENT contents: the file given later on the command line
# is the one counted, and the choice is stated.
TIE_F="$ROOT/saved-f-tie.json"
jq '.totals.tokens.input = 9999' "$SAVE_F" > "$TIE_F"
check "tie: the file given later is counted" "9999|1239" \
  "$("$SPEND" --combine "$SAVE_F" "$TIE_F" 2>/dev/null | jq -r '.totals.tokens.input')|$("$SPEND" --combine "$TIE_F" "$SAVE_F" 2>/dev/null | jq -r '.totals.tokens.input')"

echo "-- window and price-table-date mismatches combine with a named warning --"
WIN_H="$ROOT/saved-h-otherwin.json"
jq '.window.since = "2026-09-14T00:00:00Z"' "$SAVE_H" > "$WIN_H"
C4="$ROOT/comb-4.json"
"$SPEND" --combine "$SAVE_F" "$WIN_H" > "$C4" 2>"$ROOT/comb-4.err"
check "window mismatch: exit 0, both counted" "0|1739" "$?|$(jq -r '.totals.tokens.input' "$C4")"
check "window mismatch: warning names each machine's window" "1" \
  "$(jq '[.warnings[] | select(test("^window mismatch: ") and test("desk-1 2026-09-14T00:00:00Z..2026-09-15T23:59:59Z") and test("laptop-2 2026-09-15T00:00:00Z..2026-09-15T23:59:59Z"))] | length' "$C4")"
check "window mismatch: warning reaches stderr" "1" "$(grep -c '^WARNING: window mismatch' "$ROOT/comb-4.err")"
check "window mismatch: top-level window is null, not one machine's" "null" "$(jq -c '.window' "$C4")"
check "window mismatch: no price-table warning when dates agree" "0" \
  "$(jq '[.warnings[] | select(test("price-table"))] | length' "$C4")"
DATE_H="$ROOT/saved-h-otherdate.json"
jq '.price_table_date = "2026-09-14"' "$SAVE_H" > "$DATE_H"
C5="$ROOT/comb-5.json"
"$SPEND" --combine "$SAVE_F" "$DATE_H" > "$C5" 2>"$ROOT/comb-5.err"
check "date mismatch: exit 0, both counted" "0|1739" "$?|$(jq -r '.totals.tokens.input' "$C5")"
check "date mismatch: warning names each machine's date" "1" \
  "$(jq '[.warnings[] | select(test("^price-table date mismatch: ") and test("desk-1 2026-09-14") and test("laptop-2 2026-09-01"))] | length' "$C5")"
check "date mismatch: warning reaches stderr" "1" "$(grep -c '^WARNING: price-table date mismatch' "$ROOT/comb-5.err")"
check "date mismatch: top-level date is null; window still shared" "null|false" \
  "$(jq -c '.price_table_date' "$C5")|$(jq -c '.window == null' "$C5")"
# Same machine label, DIFFERENT windows: not a supersede (both counted), but
# the overlap is warned about by name.
WIN_F="$ROOT/saved-f-otherwin.json"
jq '.window.since = "2026-09-14T00:00:00Z"' "$SAVE_F" > "$WIN_F"
C6="$ROOT/comb-6.json"
"$SPEND" --combine "$SAVE_F" "$WIN_F" > "$C6" 2>/dev/null
check "same label, other window: both counted, nothing superseded" "2478|0" \
  "$(jq -r '.totals.tokens.input' "$C6")|$(jq -r '.superseded | length' "$C6")"
check "same label, other window: overlap warned by machine name" "1" \
  "$(jq '[.warnings[] | select(test("^machine laptop-2 is counted from 2 files"))] | length' "$C6")"

echo "-- --combine refusals --"
comb_refused() { # comb_refused <label> <expected stderr fragment> <spend args...>
  local lbl="$1" frag="$2"; shift 2
  "$SPEND" "$@" >"$ROOT/cr.out" 2>"$ROOT/cr.err"; local rc=$?
  check "$lbl: non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
  check "$lbl: stderr names the problem" "1" "$(grep -c -- "$frag" "$ROOT/cr.err")"
  check "$lbl: no report on stdout" "0" "$(wc -c < "$ROOT/cr.out" | tr -d ' ')"
}
BAD_SAVE="$ROOT/saved-bad.json"
jq 'del(.totals.dollars)' "$SAVE_F" > "$BAD_SAVE"
comb_refused "not a saved-totals file" "saved-bad.json' is not a saved-totals file" --combine "$SAVE_F" "$BAD_SAVE"
BAD_SAVE2="$ROOT/saved-bad2.json"
jq '.by_model["model-a"].tokens.output = "12"' "$SAVE_F" > "$BAD_SAVE2"
comb_refused "a breakdown value of the wrong type" "saved-bad2.json' is not a saved-totals file" --combine "$BAD_SAVE2"
comb_refused "missing file" "cannot read" --combine "$ROOT/no-such-save.json"
comb_refused "no files" "needs at least one" --combine
comb_refused "mixed with a scan option" "cannot be mixed with: --since" --combine "$SAVE_F" --since 2026-09-15T00:00:00Z

echo
if [ "$fail" -eq 0 ]; then
  printf 'test-spend.sh: ALL %d checks passed\n' "$pass"; exit 0
else
  printf 'test-spend.sh: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1
fi
