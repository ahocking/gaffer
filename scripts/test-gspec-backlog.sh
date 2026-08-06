#!/usr/bin/env bash
# =============================================================================
# test-gspec-backlog.sh — regression sweep for the gspec adapter (ADR 0020 D2)
# =============================================================================
# Builds synthetic gspec projects on disk and asserts the adapter's behaviour.
# No live agent, no network, no real gspec install. Exit 0 = all passed.
#
# House rule (CLAUDE.md): a behaviour worth having is a behaviour worth a case
# here. In particular every ADR 0020 claim the adapter is responsible for —
# derived completion, the PRD-wins dependency precedence, the no-roadmap
# fallback, conservative empty file scope, fail-soft interlock — has a case.
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$HERE/gspec-backlog.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ # check <name> <expected-substring> <actual>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain: $2
     got: $3" ;; esac
}
refute(){ # refute <name> <forbidden-substring> <actual>
  case "$3" in *"$2"*) bad "$1" "should NOT contain: $2
     got: $3" ;; *) ok "$1" ;; esac
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# --- fixture builders --------------------------------------------------------

mk_prd() { # mk_prd <root> <slug> <checked-count> <unchecked-count> [depends_on]
  local root="$1" slug="$2" c="$3" u="$4" deps="${5:-}"
  mkdir -p "$root/gspec/features"
  { printf -- '---\nspec-version: v1\n'
    [ -z "$deps" ] || printf 'depends_on: [%s]\n' "$deps"
    printf -- '---\n\n# Feature: %s\n\n## Capabilities\n\n' "$slug"
    local i
    for ((i=1;i<=c;i++));  do printf -- '- [x] **P0**: done capability %s\n  - criterion\n' "$i"; done
    for ((i=1;i<=u;i++));  do printf -- '- [ ] **P1**: open capability %s\n  - criterion\n' "$i"; done
  } > "$root/gspec/features/$slug.md"
}

mk_plan() { # mk_plan <root> <slug> <<<body
  local root="$1" slug="$2"
  mkdir -p "$root/gspec/tasks"
  { printf -- '---\nspec-version: v1\nfeature: %s\n---\n\n# Plan: %s\n\n## Plan\n\n' "$slug" "$slug"
    cat
  } > "$root/gspec/tasks/$slug.md"
}

# =============================================================================
printf '\n== pin ==\n'
out="$("$ADAPTER" pin)"
check 'pin reports the pinned gspec version' 'GSPEC_PINNED_VERSION=2.7.0' "$out"
check 'pin reports the install command'      'npx gspec@2.7.0' "$out"

# =============================================================================
printf '\n== check: the artifact pin (D3) ==\n'
R="$TMPROOT/pin"; mkdir -p "$R"
out="$("$ADAPTER" check "$R" 2>&1)"; rc=$?
check 'no gspec dir is OK — gspec is optional (D4)' 'CHECK=ok' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 with no gspec project' || bad 'exit 0 with no gspec project' "rc=$rc"

mk_prd "$R" alpha 1 1
mk_plan "$R" alpha <<'EOF'
- [ ] **T1** **P1** do the thing
  - deps: —
EOF
out="$("$ADAPTER" check "$R" 2>&1)"; rc=$?
check 'v1 specs pass the pin' 'CHECK=ok' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a clean project' || bad 'exit 0 on a clean project' "rc=$rc"

# A future spec-version must FAIL LOUD, not be silently consumed — this is the
# whole point of the artifact pin (the 2026-08 breakage was silent).
sed -i.bak 's/spec-version: v1/spec-version: v2/' "$R/gspec/tasks/alpha.md" && rm -f "$R/gspec/tasks/alpha.md.bak"
out="$("$ADAPTER" check "$R" 2>&1)"; rc=$?
check 'unknown spec-version fails'      'CHECK=fail' "$out"
check 'names the offending file'        'gspec/tasks/alpha.md' "$out"
check 'points at the remedy'            '/gspec-migrate' "$out"
[ "$rc" -eq 3 ] && ok 'exit 3 on a pin mismatch' || bad 'exit 3 on a pin mismatch' "rc=$rc"

# Missing frontmatter entirely is also a mismatch, not a pass-through.
mk_plan "$R" alpha <<'EOF'
- [ ] **T1** **P1** do the thing
EOF
sed -i.bak '1,4d' "$R/gspec/tasks/alpha.md" && rm -f "$R/gspec/tasks/alpha.md.bak"
out="$("$ADAPTER" check "$R" 2>&1)"; rc=$?
check 'absent spec-version fails' 'has no spec-version' "$out"
[ "$rc" -eq 3 ] && ok 'exit 3 on absent spec-version' || bad 'exit 3 on absent spec-version' "rc=$rc"

# Env override lets a consumer repo move ahead deliberately.
mk_plan "$R" alpha <<'EOF'
- [ ] **T1** **P1** do the thing
EOF
sed -i.bak 's/spec-version: v1/spec-version: v2/' "$R/gspec/tasks/alpha.md" && rm -f "$R/gspec/tasks/alpha.md.bak"
out="$(ORCH_GSPEC_SPEC_VERSIONS='v1 v2' "$ADAPTER" check "$R" 2>&1)"; rc=$?
check 'env override widens the supported set' 'CHECK=ok' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 under an override' || bad 'exit 0 under an override' "rc=$rc"

# =============================================================================
printf '\n== features: completion is DERIVED (D2) ==\n'
R="$TMPROOT/feat"; mkdir -p "$R"
mk_prd "$R" done-feature 2 0
mk_prd "$R" open-feature 1 1
mk_prd "$R" empty-feature 0 0
out="$("$ADAPTER" features "$R")"
check 'all-checked PRD reads done'    "$(printf 'done-feature\t9999\t1')" "$out"
check 'partly-checked PRD reads open' "$(printf 'open-feature\t9999\t0')" "$out"
check 'zero-checkbox PRD is NOT done' "$(printf 'empty-feature\t9999\t0')" "$out"

# =============================================================================
printf '\n== features: blocking from depends_on ==\n'
R="$TMPROOT/deps"; mkdir -p "$R"
mk_prd "$R" base 1 1
mk_prd "$R" dependent 0 1 base
out="$("$ADAPTER" features "$R")"
check 'dependent is blocked by an unfinished dep' "$(printf 'dependent\t9999\t0\t1')" "$out"
check 'base is not blocked'                       "$(printf 'base\t9999\t0\t0')" "$out"

mk_prd "$R" base 2 0   # finish the dependency
out="$("$ADAPTER" features "$R")"
check 'dependent unblocks when its dep completes' "$(printf 'dependent\t9999\t0\t0')" "$out"

# =============================================================================
printf '\n== roadmap: order/why override, PRD wins on depends_on ==\n'
R="$TMPROOT/rm"; mkdir -p "$R/.agents"
mk_prd "$R" zeta 0 1
mk_prd "$R" alpha 0 1
cat > "$R/.agents/roadmap.yaml" <<'EOF'
schema: 1
features:
  - slug: zeta
    order: 10
    why: pilot needs it first
  - slug: alpha
    order: 20
    why: can wait
EOF
out="$("$ADAPTER" features "$R")"
first="$(printf '%s\n' "$out" | head -1 | cut -f1)"
[ "$first" = "zeta" ] && ok 'roadmap order beats alphabetical' || bad 'roadmap order beats alphabetical' "first=$first"
check 'why is carried through' 'pilot needs it first' "$out"
out="$("$ADAPTER" next "$R")"
check 'next picks the lowest order' 'NEXT=zeta' "$out"

# PRD frontmatter depends_on WINS over a stale roadmap entry, never merged
# (ADR 0020 Consequences, watch item e).
R="$TMPROOT/prec"; mkdir -p "$R/.agents"
mk_prd "$R" gate 0 1
mk_prd "$R" thing 0 1 ""          # PRD declares NO dependency
cat > "$R/.agents/roadmap.yaml" <<'EOF'
schema: 1
features:
  - slug: thing
    order: 10
    why: t
    depends_on: [gate]
EOF
out="$("$ADAPTER" features "$R" | awk -F'\t' '$1=="thing"')"
check 'stale roadmap dep applies when the PRD declares none' "$(printf 'thing\t10\t0\t1')" "$out"
mk_prd "$R" thing 0 1 ""
# now give the PRD an explicit (empty) precedence signal via a real dep elsewhere
mk_prd "$R" other 0 1
mk_prd "$R" thing2 0 1 other
cat >> "$R/.agents/roadmap.yaml" <<'EOF'
  - slug: thing2
    order: 20
    why: t2
    depends_on: [gate]
EOF
out="$("$ADAPTER" features "$R" | awk -F'\t' '$1=="thing2"')"
check 'PRD depends_on wins over the roadmap entry' 'other' "$out"
refute 'roadmap dep is not merged in'              'gate|other' "$out"

# =============================================================================
printf '\n== next: the no-roadmap fallback keeps D4 honest ==\n'
R="$TMPROOT/norm"; mkdir -p "$R"
mk_prd "$R" bbb 0 1
mk_prd "$R" aaa 0 1
mk_plan "$R" aaa <<'EOF'
- [ ] **T1** **P0** first
EOF
out="$("$ADAPTER" next "$R")"
check 'no roadmap falls back to slug order' 'NEXT=aaa' "$out"
check 'and says so'                         'no .agents/roadmap.yaml' "$out"
check 'reports the plan file'               'PLAN=gspec/tasks/aaa.md' "$out"

R="$TMPROOT/noplan"; mkdir -p "$R"
mk_prd "$R" solo 0 1
out="$("$ADAPTER" next "$R")"
check 'missing plan file is reported, not fatal' 'PLAN=none' "$out"
check 'and points at /gspec-plan'                '/gspec-plan solo' "$out"

R="$TMPROOT/legacy"; mkdir -p "$R/gspec/features"
mk_prd "$R" old 0 1
cat > "$R/gspec/features/old.plan.md" <<'EOF'
---
spec-version: v1
feature: old
---
## Plan
- [ ] **T1** **P0** legacy-located task
EOF
out="$("$ADAPTER" next "$R")"
check 'legacy .plan.md is found'      'PLAN=gspec/features/old.plan.md' "$out"
check 'legacy location warns'         'run /gspec-migrate' "$out"
out="$("$ADAPTER" features "$R")"
refute 'a .plan.md is never a feature' 'old.plan' "$out"

R="$TMPROOT/alldone"; mkdir -p "$R"
mk_prd "$R" finished 2 0
out="$("$ADAPTER" next "$R")"
check 'all-complete reports none' 'REASON=all features complete' "$out"

R="$TMPROOT/allblocked"; mkdir -p "$R"
mk_prd "$R" pre 0 1
mk_prd "$R" post 0 1 pre
out="$("$ADAPTER" next "$R" | grep -c 'NEXT=pre')"
[ "$out" = "1" ] && ok 'blocked feature is skipped for its dependency' || bad 'blocked feature skipped' "got=$out"

# =============================================================================
printf '\n== nodes: task deps become graph edges ==\n'
R="$TMPROOT/nodes"; mkdir -p "$R"
mk_prd "$R" api 0 1
mk_plan "$R" api <<'EOF'
- [x] **T1** **P0** already built
  - deps: —
- [ ] **T2** [P] **P0** build the handler
  - deps: T1
  - covers: "something"
- [ ] **T3** **P0** wire it up
  - deps: T2
  - covers: "something else"
EOF
out="$("$ADAPTER" nodes api "$R")"
refute 'checked tasks are not backlog nodes' 'api-t1' "$out"
check 'unchecked task becomes a node'        'api-t2' "$out"
check 'produces is feature-scoped'           'api#T2' "$out"
check 'intra-feature dep becomes consumes'   "$(printf 'api#T2\tapi#T3')" "$out"
t2line="$(printf '%s\n' "$out" | awk -F'\t' '$1=="api-t2"')"
[ "$(printf '%s' "$t2line" | cut -f3)" = "" ] && ok 'no files: line => empty scope (conservative)' \
  || bad 'empty scope' "files=$(printf '%s' "$t2line" | cut -f3)"
# T2 depends on the CHECKED T1. The consumes token IS emitted — the invariant is
# not "no token" but "no EDGE": nothing produces api#T1 because a checked task is
# not a node, so done work cannot block T2. Asserted on the graph, not the TSV.
check 'consumes token is still emitted for a checked dep' 'api#T1' "$t2line"
"$ADAPTER" nodes api "$R" > "$TMPROOT/checkeddep.tsv"
gdep="$("$HERE/packet-graph.sh" build "$TMPROOT/checkeddep.tsv" 2>&1)"
t2dep="$(printf '%s\n' "$gdep" | awk '/id: api-t2$/{f=1} f&&/depends_on:/{print;exit}')"
refute 'a dep on a checked task produces NO edge' 'api-t1' "$t2dep"

printf '\n== nodes: optional files: (forward-compat with U1) ==\n'
mk_plan "$R" api <<'EOF'
- [ ] **T1** **P0** build it
  - deps: —
  - files: [src/a.ts, src/b.ts]
EOF
out="$("$ADAPTER" nodes api "$R")"
check 'files: is parsed when present' 'src/a.ts|src/b.ts' "$out"

printf '\n== sidecar: .agents/task-files.yaml (ADR 0020 U1-local) ==\n'
R="$TMPROOT/sidecar"; mkdir -p "$R/.agents"
mk_prd "$R" svc 0 1
mk_plan "$R" svc <<'EOF'
- [ ] **T1** **P0** create the schema migration
  - deps: —
- [ ] **T2** [P] **P0** add the repository layer
  - deps: T1
- [ ] **T3** **P0** wire the handler
  - deps: T2
EOF
cat > "$R/.agents/task-files.yaml" <<'EOF'
schema: 1
tasks:
  - task: svc#T1
    files: [db/migrations/**, src/models/user.ts]
    fingerprint: create the schema migration
  - task: svc#T2
    files: [src/repo/**]
    fingerprint: THIS NO LONGER MATCHES THE TASK
  - task: svc#T3
    files: [src/api/**]
EOF
out="$("$ADAPTER" nodes svc "$R" 2>/dev/null)"
t1="$(printf '%s\n' "$out" | awk -F'\t' '$1=="svc-t1"{print $3}')"
t2="$(printf '%s\n' "$out" | awk -F'\t' '$1=="svc-t2"{print $3}')"
t3="$(printf '%s\n' "$out" | awk -F'\t' '$1=="svc-t3"{print $3}')"
[ "$t1" = 'db/migrations/**|src/models/user.ts' ] && ok 'matching fingerprint supplies file scope' \
  || bad 'matching fingerprint supplies file scope' "got=$t1"
[ "$t2" = "" ] && ok 'STALE fingerprint is ignored -> empty scope (never wrong-narrow)' \
  || bad 'stale fingerprint ignored' "got=$t2"
[ "$t3" = "" ] && ok 'MISSING fingerprint is ignored -> empty scope' \
  || bad 'missing fingerprint ignored' "got=$t3"
err="$("$ADAPTER" nodes svc "$R" 2>&1 >/dev/null)"
check 'stale entry warns on stderr'   'svc#T2 sidecar fingerprint no longer matches' "$err"
check 'unfingerprinted entry warns'   'svc#T3 sidecar entry has no fingerprint' "$err"
refute 'warnings never pollute stdout' 'sidecar' "$out"

printf '\n== sidecar: fingerprint normalization ==\n'
cat > "$R/.agents/task-files.yaml" <<'EOF'
schema: 1
tasks:
  - task: svc#T1
    files: [db/migrations/**]
    fingerprint: "  CREATE   the **schema** migration  "
EOF
out="$("$ADAPTER" nodes svc "$R" 2>/dev/null | awk -F'\t' '$1=="svc-t1"{print $3}')"
[ "$out" = 'db/migrations/**' ] && ok 'case/emphasis/whitespace differences still match' \
  || bad 'fingerprint normalization' "got=$out"

printf '\n== sidecar: a plan-authored files: line still wins (U1-up precedence) ==\n'
mk_plan "$R" svc <<'EOF'
- [ ] **T1** **P0** create the schema migration
  - deps: —
  - files: [authoritative/from-plan.sql]
EOF
out="$("$ADAPTER" nodes svc "$R" 2>/dev/null | awk -F'\t' '$1=="svc-t1"{print $3}')"
[ "$out" = 'authoritative/from-plan.sql' ] && ok 'plan-authored files: beats the sidecar' \
  || bad 'plan files: precedence' "got=$out"

printf '\n== sidecar: end-to-end, scope actually unlocks a wave ==\n'
R="$TMPROOT/sidecar-e2e"; mkdir -p "$R/.agents"
mk_prd "$R" par 0 1
mk_plan "$R" par <<'EOF'
- [ ] **T1** **P0** build the left side
  - deps: —
- [ ] **T2** **P0** build the right side
  - deps: —
EOF
"$ADAPTER" nodes par "$R" > "$TMPROOT/par-noscope.tsv" 2>/dev/null
g="$("$HERE/packet-graph.sh" build "$TMPROOT/par-noscope.tsv")"
printf '%s\n' "$g" > "$TMPROOT/par-noscope.yaml"
v="$("$HERE/packet-graph.sh" validate "$TMPROOT/par-noscope.yaml" 2>&1)"
check 'with no scope both packets are conservatively serialized' 'conservatively_serialized: 2' "$v"
cat > "$R/.agents/task-files.yaml" <<'EOF'
schema: 1
tasks:
  - task: par#T1
    files: [src/left/**]
    fingerprint: build the left side
  - task: par#T2
    files: [src/right/**]
    fingerprint: build the right side
EOF
"$ADAPTER" nodes par "$R" > "$TMPROOT/par-scoped.tsv" 2>/dev/null
printf '%s\n' "$("$HERE/packet-graph.sh" build "$TMPROOT/par-scoped.tsv")" > "$TMPROOT/par-scoped.yaml"
v="$("$HERE/packet-graph.sh" validate "$TMPROOT/par-scoped.yaml" 2>&1)"
check 'scoping removes the conservative serialization' 'conservatively_serialized: 0' "$v"
rdy="$("$HERE/packet-graph.sh" ready "$TMPROOT/par-scoped.yaml" --max 5 2>&1)"
[ "$(printf '%s\n' "$rdy" | grep -c .)" = 2 ] && ok 'both disjoint packets become concurrently dispatchable' \
  || bad 'disjoint packets dispatchable' "ready=$rdy"

printf '\n== files-status: the sidecar audit ==\n'
R="$TMPROOT/fstat"; mkdir -p "$R/.agents"
mk_prd "$R" a 0 1
mk_plan "$R" a <<'EOF'
- [x] **T1** **P0** already done
- [ ] **T2** **P0** live task
- [ ] **T3** **P0** reworded task
EOF
out="$("$ADAPTER" files-status "$R")"
check 'no sidecar is reported plainly' 'FILES=none' "$out"
cat > "$R/.agents/task-files.yaml" <<'EOF'
schema: 1
tasks:
  - task: a#T1
    files: [x]
    fingerprint: already done
  - task: a#T2
    files: [src/live/**]
    fingerprint: live task
  - task: a#T3
    files: [src/old/**]
    fingerprint: the ORIGINAL wording
  - task: a#T9
    files: [src/gone/**]
    fingerprint: vanished
EOF
out="$("$ADAPTER" files-status "$R")"
check 'matching entry reads ok'        'ok              a#T2' "$out"
check 'checked task reads done'        'done            a#T1' "$out"
check 'reworded task reads stale'      'stale           a#T3' "$out"
check 'missing task reads orphan'      'orphan          a#T9' "$out"
check 'summary counts them'            'ok=1 stale=1 unfingerprinted=0 done=1 orphan=1' "$out"
check 'summary flags attention'        'FILES=attention' "$out"
check 'and says ignoring is safe'      'wrong-wide, never wrong-narrow' "$out"

printf '\n== nodes: feature deps ride along ==\n'
R="$TMPROOT/fdeps"; mkdir -p "$R"
mk_prd "$R" core 0 1
mk_prd "$R" ui 0 1 core
mk_plan "$R" ui <<'EOF'
- [ ] **T1** **P0** render
  - deps: —
EOF
out="$("$ADAPTER" nodes ui "$R")"
[ "$(printf '%s' "$out" | cut -f6)" = "core" ] && ok 'feature_depends_on is emitted' \
  || bad 'feature_depends_on is emitted' "got=$(printf '%s' "$out" | cut -f6)"

printf '\n== nodes-all: only incomplete AND unblocked features ==\n'
R="$TMPROOT/all"; mkdir -p "$R"
mk_prd "$R" ready 0 1
mk_prd "$R" finished 1 0
mk_prd "$R" waiting 0 1 ready
for s in ready finished waiting; do mk_plan "$R" "$s" <<EOF
- [ ] **T1** **P0** task for $s
EOF
done
out="$("$ADAPTER" nodes-all "$R")"
check 'ready feature is included'     'ready-t1' "$out"
refute 'completed feature is skipped' 'finished-t1' "$out"
refute 'blocked feature is skipped'   'waiting-t1' "$out"

# =============================================================================
printf '\n== nodes feed packet-graph.sh end to end ==\n'
R="$TMPROOT/e2e"; mkdir -p "$R"
mk_prd "$R" svc 0 1
mk_plan "$R" svc <<'EOF'
- [ ] **T1** **P0** schema
  - deps: —
  - files: [db/schema.sql]
- [ ] **T2** **P0** api
  - deps: T1
  - files: [src/api.ts]
- [ ] **T3** [P] **P0** docs
  - deps: T1
  - files: [docs/api.md]
EOF
nodes="$TMPROOT/e2e-nodes.tsv"
"$ADAPTER" nodes svc "$R" > "$nodes"
if graph="$("$HERE/packet-graph.sh" build "$nodes" 2>&1)"; then
  ok 'packet-graph.sh accepts adapter output'
  check 'T1 lands in the first wave' 'svc-t1' "$graph"
  printf '%s\n' "$graph" > "$TMPROOT/e2e-graph.yaml"   # validate needs a real file
  v="$("$HERE/packet-graph.sh" validate "$TMPROOT/e2e-graph.yaml" 2>&1 || true)"
  check 'the emitted graph validates' 'VALIDATE=ok' "$v"
else
  bad 'packet-graph.sh accepts adapter output' "$graph"
fi

# A dangling consumes (dep on a checked task) must not crash the graph.
R="$TMPROOT/dangle"; mkdir -p "$R"
mk_prd "$R" d 0 1
mk_plan "$R" d <<'EOF'
- [x] **T1** **P0** done
- [ ] **T2** **P0** depends on done work
  - deps: T1
EOF
"$ADAPTER" nodes d "$R" > "$TMPROOT/dangle.tsv"
if g2="$("$HERE/packet-graph.sh" build "$TMPROOT/dangle.tsv" 2>&1)"; then
  ok 'dangling dep does not break graph build'
else
  bad 'dangling dep does not break graph build' "$g2"
fi

# =============================================================================
printf '\n== interlock: fail-soft outside the pinned contract (D5) ==\n'
R="$TMPROOT/lock"; mkdir -p "$R/.gspec/build"
out="$("$ADAPTER" interlock "$R")"
check 'no status.json => clear' 'INTERLOCK=clear' "$out"

printf '{"state":"complete","pid":1}\n' > "$R/.gspec/build/status.json"
out="$("$ADAPTER" interlock "$R")"
check 'a finished build => clear' 'INTERLOCK=clear' "$out"

printf '{"state":"running","pid":%s}\n' "$$" > "$R/.gspec/build/status.json"
out="$("$ADAPTER" interlock "$R")"
check 'a LIVE build => busy' 'INTERLOCK=busy' "$out"
check 'and explains why'     'two drivers' "$out"

printf '{"state":"running","pid":999999}\n' > "$R/.gspec/build/status.json"
out="$("$ADAPTER" interlock "$R")"
check 'running with a dead pid is a crash, not a live driver' 'INTERLOCK=clear' "$out"

printf 'not json at all\n' > "$R/.gspec/build/status.json"
out="$("$ADAPTER" interlock "$R")"
check 'unparseable status.json => unknown, never a block' 'INTERLOCK=unknown' "$out"

# =============================================================================
printf '\n----------------------------------------\n'
printf 'gspec-backlog: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
