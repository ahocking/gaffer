#!/usr/bin/env bash
# =============================================================================
# test-packet-graph.sh — regression sweep for scripts/packet-graph.sh (ADR 0016)
# =============================================================================
# The parallel scheduler and the /build-packet-dependency-tree skill trust this
# graph math, so its behavior is pinned here rather than by a live agent. Each
# case feeds a NODES tsv (or a built graph) and asserts the derived DAG / ready-set.
#
# Run:  scripts/test-packet-graph.sh   (exit 0 = all passed, 1 = a case failed)
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PG="${HERE}/packet-graph.sh"
TMP="$(mktemp -d)"
cd "$TMP"

pass=0; fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

# assert a build produces a field for a packet. field_is <graph> <id> <key> <expected>
field_is() {
  local g="$1" id="$2" key="$3" want="$4" got
  got="$(awk -v id="$id" -v key="$key" '
    $0 ~ "^  - id: "id"$" {f=1; next}
    f && $0 ~ "^  - id: " {f=0}
    f && $0 ~ "^    "key":" { sub(/^[^:]*:[ \t]*/,""); print; exit }' "$g")"
  if [ "$got" = "$want" ]; then ok "[$id].$key = $want"; else bad "[$id].$key: want '$want' got '$got'"; fi
}

# --- fixtures ----------------------------------------------------------------
# feat1: a (produces TokenA) -> b (consumes TokenA); c independent, disjoint files.
nodes_basic() {
  printf 'a\tfeat1\tsrc/a/**\t\tTokenA\t\n'
  printf 'b\tfeat1\tsrc/b/**\tTokenA\t\t\n'
  printf 'c\tfeat2\tweb/c/**\t\t\t\n'
}
# two packets writing the SAME area -> mutual exclusion, both wave 0.
nodes_overlap() {
  printf 'x\tfeat1\tsrc/shared/**\t\t\t\n'
  printf 'y\tfeat1\tsrc/shared/svc.cs\t\t\t\n'
}
# feature edge: feat2 depends_on feat1 -> every feat2 packet depends on feat1 packets.
nodes_featdep() {
  printf 'p1\tfeat1\tsrc/one/**\t\t\t\n'
  printf 'p2\tfeat2\tsrc/two/**\t\t\t feat1\n'
}
# cycle: m consumes TokenN (from n), n consumes TokenM (from m).
nodes_cycle() {
  printf 'm\tfeat1\tsrc/m/**\tTokenN\tTokenM\t\n'
  printf 'n\tfeat1\tsrc/n/**\tTokenM\tTokenN\t\n'
}

echo "== build: interface + wave assignment =="
nodes_basic | "$PG" build > g_basic.yaml 2>err.txt && ok "build basic (exit 0)" || bad "build basic exited $?"
field_is g_basic.yaml a wave 0
field_is g_basic.yaml b wave 1
field_is g_basic.yaml c wave 0
field_is g_basic.yaml b depends_on '[a]'
field_is g_basic.yaml a depends_on '[]'
# disjoint files => no excludes anywhere
if grep -q 'excludes: \[.\+\]' g_basic.yaml; then bad "disjoint files should yield no excludes"; else ok "disjoint files => excludes: []"; fi

echo "== build: allowed_files overlap => mutual exclusion, same wave =="
nodes_overlap | "$PG" build > g_overlap.yaml
field_is g_overlap.yaml x excludes '[y]'
field_is g_overlap.yaml y excludes '[x]'
field_is g_overlap.yaml x wave 0
field_is g_overlap.yaml y wave 0

echo "== build: feature dependency edge =="
nodes_featdep | "$PG" build > g_featdep.yaml
field_is g_featdep.yaml p2 depends_on '[p1]'
field_is g_featdep.yaml p2 wave 1

echo "== build: dependency cycle => exit 2 =="
nodes_cycle | "$PG" build > g_cycle.yaml 2>cyc.txt; rc=$?
if [ "$rc" = 2 ]; then ok "cycle build exits 2"; else bad "cycle build exited $rc (want 2)"; fi
grep -q 'CYCLE' cyc.txt && ok "cycle reason printed" || bad "no cycle reason"

echo "== build: empty allowed_files => conservatively excludes everything =="
{ printf 'u\tfeat1\t\t\t\t\n'; printf 'v\tfeat1\tsrc/v/**\t\t\t\n'; } | "$PG" build > g_cons.yaml
field_is g_cons.yaml u excludes '[v]'
field_is g_cons.yaml v excludes '[u]'

echo "== validate =="
"$PG" validate g_basic.yaml | grep -q 'VALIDATE=ok' && ok "validate ok on basic" || bad "validate basic not ok"
"$PG" validate g_cons.yaml | grep -q 'conservatively_serialized: 1' && ok "validate reports 1 conservatively-serialized" || bad "validate cons count wrong"
# build refuses to EMIT a cycle, so hand-craft a cyclic graph to exercise validate.
cat > g_handcycle.yaml <<'EOF'
schema: 1
packets:
  - id: m
    feature: f
    wave: 0
    depends_on: [n]
    excludes: []
    allowed_files: [src/m/**]
  - id: n
    feature: f
    wave: 0
    depends_on: [m]
    excludes: []
    allowed_files: [src/n/**]
EOF
"$PG" validate g_handcycle.yaml >/dev/null 2>&1; [ "$?" = 2 ] && ok "validate detects a hand-edited cycle (exit 2)" || bad "validate cycle not 2"

echo "== ready: dependency gating =="
# nothing done yet: b (needs a) is NOT ready; a and c are (disjoint) up to cap.
got="$("$PG" ready g_basic.yaml --max 5 | sort | paste -sd, -)"
[ "$got" = "a,c" ] && ok "ready(nothing done) = a,c" || bad "ready(nothing done) = '$got' (want a,c)"
# a done: now b becomes ready; c still ready.
got="$("$PG" ready g_basic.yaml --max 5 --done a | sort | paste -sd, -)"
[ "$got" = "b,c" ] && ok "ready(done=a) = b,c" || bad "ready(done=a) = '$got' (want b,c)"

echo "== ready: cap limits concurrency =="
got="$("$PG" ready g_basic.yaml --max 1 | wc -l | tr -d ' ')"
[ "$got" = 1 ] && ok "ready(--max 1) yields 1" || bad "ready(--max 1) yielded $got"
# one already running consumes a slot: --max 2, running=c -> only 1 more slot.
got="$("$PG" ready g_basic.yaml --max 2 --running c | wc -l | tr -d ' ')"
[ "$got" = 1 ] && ok "ready(max2,running=c) yields 1 (slot math)" || bad "ready slot math = $got"

echo "== ready: excludes are not co-dispatched, and not started against a running excluder =="
# overlap graph: x,y exclude each other. Fresh: only ONE may be picked.
got="$("$PG" ready g_overlap.yaml --max 5 | wc -l | tr -d ' ')"
[ "$got" = 1 ] && ok "mutually-excluding pair => at most 1 dispatched" || bad "excluding pair dispatched $got"
# if x is running, y must NOT be offered.
got="$("$PG" ready g_overlap.yaml --max 5 --running x)"
[ -z "$got" ] && ok "excluded-by-running is withheld" || bad "offered '$got' while its excluder runs"

echo "== overlap prefix logic =="
# src/a/** vs src/a/b/** overlap; src/a/** vs src/b/** disjoint; leading ** matches all.
{ printf 'p\tf\tsrc/a/**\t\t\t\n'; printf 'q\tf\tsrc/a/b/**\t\t\t\n'; printf 'r\tf\tsrc/b/**\t\t\t\n'; printf 's\tf\t**/gen.cs\t\t\t\n'; } | "$PG" build > g_ovl.yaml
field_is g_ovl.yaml p excludes '[q, s]'
field_is g_ovl.yaml r excludes '[s]'
field_is g_ovl.yaml s excludes '[p, q, r]'

echo
echo "-----------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
