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

# --- the same two, in gspec 3.x's feature-folder layout ----------------------
# Deliberately SEPARATE builders rather than a flag on the ones above: nearly
# every case in this file asserts the flat layout, and a shared builder with a
# mode switch would let a future edit flip all of them at once. Two builders
# means a case says which layout it is testing by which one it calls.

mk_prd_v2() { # mk_prd_v2 <root> <slug> <checked-count> <unchecked-count> [depends_on]
  local root="$1" slug="$2" c="$3" u="$4" deps="${5:-}"
  mkdir -p "$root/gspec/features/$slug"
  { printf -- '---\nspec-version: v2\n'
    [ -z "$deps" ] || printf 'depends_on: [%s]\n' "$deps"
    printf -- '---\n\n# Feature: %s\n\n## Capabilities\n\n' "$slug"
    local i
    for ((i=1;i<=c;i++));  do printf -- '- [x] **P0**: done capability %s\n  - criterion\n' "$i"; done
    for ((i=1;i<=u;i++));  do printf -- '- [ ] **P1**: open capability %s\n  - criterion\n' "$i"; done
  } > "$root/gspec/features/$slug/prd.md"
}

mk_plan_v2() { # mk_plan_v2 <root> <slug> <<<body
  local root="$1" slug="$2"
  mkdir -p "$root/gspec/features/$slug"
  { printf -- '---\nspec-version: v2\nfeature: %s\n---\n\n# Plan: %s\n\n## Plan\n\n' "$slug" "$slug"
    cat
  } > "$root/gspec/features/$slug/tasks.md"
}

# =============================================================================
printf '\n== pin ==\n'
out="$("$ADAPTER" pin)"
check 'pin reports the pinned gspec version' 'GSPEC_PINNED_VERSION=3.1.1' "$out"
check 'pin reports the install command'      'npx gspec@3.1.1' "$out"
# BOTH artifact versions, deliberately: v2 is what gspec 3.x writes, v1 is what
# every unmigrated consumer repo still has on disk, and the adapter reads both.
check 'pin supports both artifact versions'  'GSPEC_SPEC_VERSIONS=v1 v2' "$out"

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

# v2 is gspec 3.x's artifact version and must PASS. This case used to assert the
# opposite -- it stamped v2 precisely because v2 was the unknown future version --
# so it is the one that proves the 3.1.1 bump actually widened the pin rather than
# just moving the number in the banner.
sed -i.bak 's/spec-version: v1/spec-version: v2/' "$R/gspec/tasks/alpha.md" && rm -f "$R/gspec/tasks/alpha.md.bak"
out="$("$ADAPTER" check "$R" 2>&1)"; rc=$?
check 'v2 specs pass the pin'  'CHECK=ok' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a v2 project' || bad 'exit 0 on a v2 project' "rc=$rc"

# A spec-version this plugin has never heard of must still FAIL LOUD, not be
# silently consumed -- that is the whole point of the artifact pin, and widening
# the supported set must not have turned the check into a rubber stamp.
sed -i.bak 's/spec-version: v2/spec-version: v9/' "$R/gspec/tasks/alpha.md" && rm -f "$R/gspec/tasks/alpha.md.bak"
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
sed -i.bak 's/spec-version: v1/spec-version: v9/' "$R/gspec/tasks/alpha.md" && rm -f "$R/gspec/tasks/alpha.md.bak"
out="$(ORCH_GSPEC_SPEC_VERSIONS='v1 v9' "$ADAPTER" check "$R" 2>&1)"; rc=$?
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
printf '\n== roadmap: deferred is a human "not now", never a derived status ==\n'
R="$TMPROOT/defer"; mkdir -p "$R/.agents"
mk_prd "$R" live 0 1
mk_prd "$R" later 0 1
mk_plan "$R" later <<'EOF'
- [ ] **T1** **P0** deferred work that must not be scheduled
  - deps: —
EOF
cat > "$R/.agents/roadmap.yaml" <<'EOF'
schema: 1
features:
  - slug: later
    order: 10
    why: waiting on evidence
    deferred: true
  - slug: live
    order: 20
    why: actually queued
EOF
out="$("$ADAPTER" features "$R")"
dfl="$(printf '%s\n' "$out" | awk -F'\t' '$1=="later"{print $7}')"
dfv="$(printf '%s\n' "$out" | awk -F'\t' '$1=="live"{print $7}')"
[ "$dfl" = "1" ] && ok 'deferred feature reports deferred=1' || bad 'deferred=1' "got=$dfl"
[ "$dfv" = "0" ] && ok 'non-deferred reports deferred=0'    || bad 'deferred=0' "got=$dfv"
check 'a deferred feature is still LISTED, not hidden' 'later' "$out"

out="$("$ADAPTER" next "$R")"
check 'next skips the deferred feature despite its lower order' 'NEXT=live' "$out"

# nodes-all must not schedule deferred work, or build-packet-dependency-tree
# plans waves of packets the human explicitly decided not to start.
out="$("$ADAPTER" nodes-all "$R" 2>/dev/null)"
refute 'nodes-all emits nothing for a deferred feature' 'later-t1' "$out"
# ...but an EXPLICIT single-feature request is still honoured: naming a slug is a
# human asking for it, which is the same authority that set `deferred` in the first place.
out="$("$ADAPTER" nodes later "$R" 2>/dev/null)"
check 'an explicit nodes <slug> still works on a deferred feature' 'later-t1' "$out"

printf '\n== deferred: blocks dependents, and never reads as complete ==\n'
R="$TMPROOT/defdep"; mkdir -p "$R/.agents"
mk_prd "$R" base 0 1
mk_prd "$R" dependent 0 1 base
cat > "$R/.agents/roadmap.yaml" <<'EOF'
schema: 1
features:
  - slug: base
    order: 10
    why: deferred prerequisite
    deferred: true
  - slug: dependent
    order: 20
    why: needs base
EOF
blk="$("$ADAPTER" features "$R" | awk -F'\t' '$1=="dependent"{print $4}')"
[ "$blk" = "1" ] && ok 'a deferred prerequisite still BLOCKS its dependent' \
  || bad 'deferred still blocks' "blocked=$blk (deferring is not completion)"
out="$("$ADAPTER" next "$R")"
check 'all-deferred/blocked does not masquerade as complete' 'REASON=every' "$out"
refute 'and specifically never says all features complete' 'all features complete' "$out"

# Everything remaining deferred is its OWN reported state — collapsing it into
# "blocked" or "complete" is how a stopped loop gets misread as a finished one.
R="$TMPROOT/alldef"; mkdir -p "$R/.agents"
mk_prd "$R" only 0 1
cat > "$R/.agents/roadmap.yaml" <<'EOF'
schema: 1
features:
  - slug: only
    order: 10
    why: parked pending a decision
    deferred: true
EOF
out="$("$ADAPTER" next "$R")"
check 'all-deferred reports the deferred reason' 'REASON=every remaining feature is deferred' "$out"
check 'and names which one, with its why'        'DEFERRED=only why=parked pending a decision' "$out"
check 'and says how to undo it'                  'HINT=remove' "$out"

# A gating field must fail VISIBLE, not silent: a typo cannot vanish work.
R="$TMPROOT/deftypo"; mkdir -p "$R/.agents"
mk_prd "$R" typo 0 1
cat > "$R/.agents/roadmap.yaml" <<'EOF'
schema: 1
features:
  - slug: typo
    order: 10
    why: t
    deferred: ture
EOF
out="$("$ADAPTER" next "$R")"
check 'a malformed deferred value does NOT defer (wrong-visible beats wrong-invisible)' 'NEXT=typo' "$out"
out="$("$ADAPTER" features "$R" | awk -F'\t' '$1=="typo"{print $7}')"
[ "$out" = "0" ] && ok 'malformed deferred reports 0' || bad 'malformed deferred reports 0' "got=$out"

# An EMPTY depends_on must not shift the trailing fields. TAB is IFS-whitespace,
# so `while IFS=$'\t' read -r a b c ...` collapses consecutive tabs into one
# delimiter and every field after the first empty one shifts left. That silently
# broke `deferred` (field 7) for exactly the rows with no dependency, while
# leaving done/blocked correct because they sit before the collapse point.
R="$TMPROOT/defempty"; mkdir -p "$R/.agents"
mk_prd "$R" nodeps 0 1            # no depends_on at all => field 5 is empty
mk_plan "$R" nodeps <<'EOF'
- [ ] **T1** **P0** must not be scheduled
  - deps: —
EOF
cat > "$R/.agents/roadmap.yaml" <<'EOF'
schema: 1
features:
  - slug: nodeps
    order: 10
    why: deferred and dependency-free
    deferred: true
EOF
df="$("$ADAPTER" features "$R" | awk -F'\t' '$1=="nodeps"{print $7}')"
[ "$df" = "1" ] && ok 'deferred survives an EMPTY depends_on field' \
  || bad 'deferred survives an empty depends_on' "got=[$df] — trailing fields shifted"
out="$("$ADAPTER" nodes-all "$R" 2>/dev/null)"
refute 'nodes-all still skips it with no dependency present' 'nodeps-t1' "$out"
out="$("$ADAPTER" next "$R")"
refute 'next still skips it with no dependency present' 'NEXT=nodeps' "$out"

# Absent `deferred` must behave exactly as before it existed — the field is
# additive, and every roadmap written before it stays correct.
R="$TMPROOT/defabsent"; mkdir -p "$R/.agents"
mk_prd "$R" plain 0 1
cat > "$R/.agents/roadmap.yaml" <<'EOF'
schema: 1
features:
  - slug: plain
    order: 10
    why: no deferred key at all
EOF
out="$("$ADAPTER" next "$R")"
check 'a roadmap with no deferred key is unaffected' 'NEXT=plain' "$out"

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
check 'legacy location warns'         'pre-3.x plan location' "$out"
check 'and names the remedy'          '/gspec-migrate' "$out"
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
printf '\n== check-task: the adapter'"'"'s one write (ADR 0025 D1 / ADR 0020 D2) ==\n'
R="$TMPROOT/checktask"; mkdir -p "$R/gspec/tasks"
# A deliberately hostile plan file: a literal `[ ]` inside a description, markdown
# noise (backticks, nested bold, an em dash, trailing whitespace), an
# already-checked task, a legacy shape-A task line, and a `- deps:` sub-bullet.
{
  printf -- '---\nspec-version: v1\nfeature: widget\n---\n\n# Plan: widget\n\n## Plan\n\n'
  printf -- '- [ ] **T1** **P0** a task whose description mentions [ ] a literal checkbox later\n'
  printf -- '  - deps: \342\200\224\n'
  printf -- '- [ ] **T2** **P0** backticks `code`, **nested bold**, an em dash \342\200\224 and trailing whitespace  \n'
  printf -- '  - deps: T1\n'
  printf -- '- [x] **T3** **P0** already checked, must stay byte-identical\n'
  printf -- '  - deps: \342\200\224\n'
  printf -- '- [ ] **T003 legacy shape with id and description sharing one bold span.**\n'
  printf -- '  - deps: \342\200\224\n'
  printf -- '- [ ] **T5** **P0** has a deps sub-bullet\n'
  printf -- '  - deps: T1, T2\n'
} > "$R/gspec/tasks/widget.md"
cp "$R/gspec/tasks/widget.md" "$TMPROOT/widget.before.md"

out="$("$ADAPTER" check-task 'widget#T1' "$R")"; rc=$?
check 'flip reports the canonical token' 'CHECKED=widget#T1' "$out"
check 'flip reports the relative file'   'FILE=gspec/tasks/widget.md' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a successful flip' || bad 'exit 0 on a successful flip' "rc=$rc"

# --- byte-level preservation: not a line count, an actual byte diff -----------
d="$(diff "$TMPROOT/widget.before.md" "$R/gspec/tasks/widget.md")"
lt="$(printf '%s\n' "$d" | grep -c '^<' || true)"
gt="$(printf '%s\n' "$d" | grep -c '^>' || true)"
[ "$lt" = "1" ] && [ "$gt" = "1" ] && ok 'exactly one line changed' \
  || bad 'exactly one line changed' "diff:
$d"
before_line="$(printf '%s\n' "$d" | grep '^<' | sed 's/^< //')"
after_line="$(printf '%s\n' "$d" | grep '^>' | sed 's/^> //')"
reverted="$(printf '%s' "$after_line" | sed 's/\[x\]/[ ]/')"
[ "$reverted" = "$before_line" ] && ok 'the changed line differs ONLY by the checkbox character' \
  || bad 'the changed line differs only by the checkbox character' "before: $before_line
after:  $after_line"

# The inline `[ ]` inside T1's own description must survive untouched.
grep -qF 'mentions [ ] a literal checkbox later' "$R/gspec/tasks/widget.md" \
  && ok 'a [ ] inside the description is NOT flipped' \
  || bad 'a [ ] inside the description is NOT flipped' "$(cat "$R/gspec/tasks/widget.md")"

# Every other task line -- including the hostile-text and already-checked ones --
# is byte-identical. diff already proved this (exactly one changed pair); assert
# the specific hostile lines directly too.
grep -qF 'backticks `code`, **nested bold**, an em dash — and trailing whitespace  ' \
  "$R/gspec/tasks/widget.md" \
  && ok 'hostile markdown/whitespace line is untouched' \
  || bad 'hostile markdown/whitespace line is untouched' "$(cat "$R/gspec/tasks/widget.md")"
grep -qF -- '- [x] **T3** **P0** already checked, must stay byte-identical' \
  "$R/gspec/tasks/widget.md" \
  && ok 'already-checked task text is untouched' \
  || bad 'already-checked task text is untouched' "$(cat "$R/gspec/tasks/widget.md")"

cp "$R/gspec/tasks/widget.md" "$TMPROOT/widget.after1.md"

# --- idempotence ---------------------------------------------------------------
out="$("$ADAPTER" check-task 'widget#T1' "$R")"; rc=$?
check 'a second flip reports already' 'CHECKED=already' "$out"
check 'and still reports the file'    'FILE=gspec/tasks/widget.md' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on an idempotent re-flip' || bad 'exit 0 on an idempotent re-flip' "rc=$rc"
cmp -s "$TMPROOT/widget.after1.md" "$R/gspec/tasks/widget.md" \
  && ok 'idempotent re-flip changes no bytes' \
  || bad 'idempotent re-flip changes no bytes' "$(diff "$TMPROOT/widget.after1.md" "$R/gspec/tasks/widget.md")"

# --- packet-id form resolves to the same task -----------------------------------
out="$("$ADAPTER" check-task 'widget-t2' "$R")"; rc=$?
check 'the packet-id form (<feature>-t<n>) flips the same task' 'CHECKED=widget#T2' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on the packet-id form' || bad 'exit 0 on the packet-id form' "rc=$rc"
grep -qF -- '- [x] **T2** **P0** backticks `code`, **nested bold**, an em dash — and trailing whitespace  ' \
  "$R/gspec/tasks/widget.md" \
  && ok 'packet-id flip preserves the hostile text' \
  || bad 'packet-id flip preserves the hostile text' "$(cat "$R/gspec/tasks/widget.md")"

# --- legacy shape-A task line ----------------------------------------------------
out="$("$ADAPTER" check-task 'widget#T003' "$R")"; rc=$?
check 'a legacy shape-A task line can be flipped' 'CHECKED=widget#T003' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a legacy-shape flip' || bad 'exit 0 on a legacy-shape flip' "rc=$rc"
grep -qF -- '- [x] **T003 legacy shape with id and description sharing one bold span.**' \
  "$R/gspec/tasks/widget.md" \
  && ok 'legacy-shape text is preserved' \
  || bad 'legacy-shape text is preserved' "$(cat "$R/gspec/tasks/widget.md")"

# --- gspec is optional: every "skip" case is exit 0, never a failure -----------
R2="$TMPROOT/checktask-nogspec"; mkdir -p "$R2"
out="$("$ADAPTER" check-task 'widget#T1' "$R2")"; rc=$?
check 'no gspec/ directory => CHECKED=none' 'CHECKED=none' "$out"
check 'and explains why'                    'gspec is optional' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 with no gspec/ directory' || bad 'exit 0 with no gspec/ directory' "rc=$rc"

# The gspec-is-optional early return must win over the path-containment guard --
# a canonical slug with a path separator, against a root with NO gspec/ project,
# must still report CHECKED=none/exit 0 (D4), not die(1). Containment refusal is
# proven separately below, once a gspec project actually exists.
out="$("$ADAPTER" check-task 'a/b#T1' "$R2")"; rc=$?
check 'gspec-is-optional wins over the containment guard: still CHECKED=none' 'CHECKED=none' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a path-separator slug when gspec is absent (D4 short-circuits first)' \
  || bad 'exit 0 on a path-separator slug when gspec is absent (D4 short-circuits first)' "rc=$rc, out=$out"

out="$("$ADAPTER" check-task 'fix-login-bug' "$R")"; rc=$?
check 'an id that does not parse as a gspec task id => CHECKED=none' 'CHECKED=none' "$out"
check 'and says so, skipped not failed'                               'not a gspec task id' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on an unparseable task id' || bad 'exit 0 on an unparseable task id' "rc=$rc"

out="$("$ADAPTER" check-task 'other#T1' "$R")"; rc=$?
check 'no plan file for that feature slug => CHECKED=none' 'CHECKED=none' "$out"
check 'and names the missing plan'                          'no plan file for feature other' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 with no plan file' || bad 'exit 0 with no plan file' "rc=$rc"

# --- genuine drift is loud: exit 4 -----------------------------------------------
out="$("$ADAPTER" check-task 'widget#T99' "$R")"; rc=$?
check 'a task id absent from an EXISTING plan => CHECKED=none' 'CHECKED=none' "$out"
check 'and names the slug and the plan'                         'widget' "$out"
[ "$rc" -eq 4 ] && ok 'exit 4 on genuine drift (task id not found in an existing plan)' \
  || bad 'exit 4 on genuine drift' "rc=$rc"

# --- end to end: the flipped task disappears from nodes output ------------------
out="$("$ADAPTER" nodes widget "$R" 2>/dev/null)"
refute 'a flipped task is no longer a backlog node' 'widget-t1' "$out"
refute 'a flipped task (packet-id form) is no longer a backlog node' 'widget-t2' "$out"
check 'an unflipped task is still a backlog node'   'widget-t5' "$out"

# --- finding 1: a legacy shape-B id that itself contains a hyphen -------------
# _nodes_for emits `<feature>-<id>`. Before the fix, peeling a trailing
# `-t<digits>` off the packet-id token read `ser-ser-t1` as slug `ser-ser` /
# id `t1` and silently matched nothing (CHECKED=none, exit 0 -- the loop then
# re-runs the packet forever with no error explaining why).
mk_plan "$R" ser <<'EOF'
- [ ] **ser-t1** **P0** a legacy shape-B id that itself contains a hyphen
  - deps: —
EOF
out="$("$ADAPTER" nodes ser "$R" 2>/dev/null)"
check 'a shape-B id with a hyphen in it emits the expected node id' 'ser-ser-t1' "$out"

cp "$R/gspec/tasks/ser.md" "$TMPROOT/ser.before.md"
out="$("$ADAPTER" check-task 'ser-ser-t1' "$R")"; rc=$?
check 'the packet-id form resolves a hyphenated id via filename, not surgery' 'CHECKED=ser#ser-t1' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 flipping a hyphenated shape-B id' || bad 'exit 0 flipping a hyphenated shape-B id' "rc=$rc"
d="$(diff "$TMPROOT/ser.before.md" "$R/gspec/tasks/ser.md")"
lt="$(printf '%s\n' "$d" | grep -c '^<' || true)"
gt="$(printf '%s\n' "$d" | grep -c '^>' || true)"
[ "$lt" = "1" ] && [ "$gt" = "1" ] && ok 'ser.md text is byte-identical apart from the checkbox' \
  || bad 'ser.md text is byte-identical apart from the checkbox' "diff:
$d"
out="$("$ADAPTER" nodes ser "$R" 2>/dev/null)"
refute 'the flipped hyphenated task disappears from nodes' 'ser-ser-t1' "$out"

# --- finding 1: prefer the LONGEST matching slug -------------------------------
# A feature whose own slug ends in -t<digits> (phase-t2) must not be shadowed
# by a shorter decoy slug (phase) that also happens to match as a prefix.
mk_plan "$R" phase <<'EOF'
- [ ] **t2-t1** **P0** decoy in the shorter-slug plan — must NOT be the one flipped
  - deps: —
EOF
mk_plan "$R" phase-t2 <<'EOF'
- [ ] **T1** **P0** the longer-slug plan — this is the one that must be flipped
  - deps: —
EOF
out="$("$ADAPTER" check-task 'phase-t2-t1' "$R")"; rc=$?
check 'the longest matching slug wins over a shorter decoy' 'CHECKED=phase-t2#T1' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 preferring the longest matching slug' || bad 'exit 0 preferring the longest matching slug' "rc=$rc"
grep -qF -- '- [ ] **t2-t1** **P0** decoy in the shorter-slug plan — must NOT be the one flipped' \
  "$R/gspec/tasks/phase.md" \
  && ok 'the shorter-slug decoy plan is untouched' \
  || bad 'the shorter-slug decoy plan is untouched' "$(cat "$R/gspec/tasks/phase.md")"

# --- finding 2: the write is confined to gspec/, never a path escape ----------
mkdir -p "$R/outside"
printf -- '- [ ] **T1** victim line — must never be touched by check-task\n' > "$R/outside/victim.md"
cp "$R/outside/victim.md" "$TMPROOT/victim.before.md"
out="$("$ADAPTER" check-task '../../outside/victim#T1' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a slug containing a path separator/.. is refused, not resolved' \
  || bad 'a slug containing a path separator/.. is refused, not resolved' "rc=$rc, out=$out"
check 'and explains why' 'path separator' "$out"
cmp -s "$TMPROOT/victim.before.md" "$R/outside/victim.md" \
  && ok 'the file outside gspec/ is byte-identical afterward' \
  || bad 'the file outside gspec/ is byte-identical afterward' "$(diff "$TMPROOT/victim.before.md" "$R/outside/victim.md")"

out="$("$ADAPTER" check-task 'foo/bar#T1' "$R")"; rc=$?
[ "$rc" -ne 0 ] && ok 'a plain slug containing / is likewise refused' \
  || bad 'a plain slug containing / is likewise refused' "rc=$rc, out=$out"

# --- finding 3: no byte is added to a plan with no final newline --------------
mkdir -p "$R/gspec/tasks"
printf -- '---\nspec-version: v1\nfeature: nonl\n---\n\n# Plan: nonl\n\n## Plan\n\n- [ ] **T1** a task in a plan with no trailing newline' \
  > "$R/gspec/tasks/nonl.md"
before_size="$(wc -c < "$R/gspec/tasks/nonl.md")"
out="$("$ADAPTER" check-task 'nonl#T1' "$R")"; rc=$?
check 'flips a plan that has no trailing newline' 'CHECKED=nonl#T1' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 flipping a plan with no trailing newline' || bad 'exit 0 flipping a plan with no trailing newline' "rc=$rc"
after_size="$(wc -c < "$R/gspec/tasks/nonl.md")"
[ "$before_size" -eq "$after_size" ] && ok 'the byte count is unchanged apart from the flip' \
  || bad 'the byte count is unchanged apart from the flip' "before=$before_size after=$after_size"
if [ -n "$(tail -c1 "$R/gspec/tasks/nonl.md")" ]; then
  ok 'the file still lacks a trailing newline'
else
  bad 'the file still lacks a trailing newline' 'a trailing newline was added'
fi
grep -qF -- '[x] **T1** a task in a plan with no trailing newline' "$R/gspec/tasks/nonl.md" \
  && ok 'the flip itself landed correctly' \
  || bad 'the flip itself landed correctly' "$(cat "$R/gspec/tasks/nonl.md")"

# --- finding 4: the plan file's mode survives the flip (not narrowed to 0600) -
mk_plan "$R" modetest <<'EOF'
- [ ] **T1** a task used only to verify the plan's file mode survives the flip
  - deps: —
EOF
chmod 644 "$R/gspec/tasks/modetest.md"
before_mode="$(ls -l "$R/gspec/tasks/modetest.md" | awk '{print $1}')"
out="$("$ADAPTER" check-task 'modetest#T1' "$R")"; rc=$?
[ "$rc" -eq 0 ] && ok 'exit 0 flipping the mode-check fixture' || bad 'exit 0 flipping the mode-check fixture' "rc=$rc"
after_mode="$(ls -l "$R/gspec/tasks/modetest.md" | awk '{print $1}')"
[ "$before_mode" = "$after_mode" ] && ok 'the plan file mode survives the flip (not narrowed to mktemp 0600)' \
  || bad 'the plan file mode survives the flip' "before=$before_mode after=$after_mode"

# --- finding 5: no stray temp files are left behind after a run ---------------
leftover="$(find "$R/gspec" -name '.gspec-check-task.*' 2>/dev/null)"
[ -z "$leftover" ] && ok 'no stray check-task temp files remain after a run' \
  || bad 'no stray check-task temp files remain after a run' "$leftover"

# --- finding 5, real trap coverage: the case above only exercises the SUCCESS
# path, where a bare `mv` would remove the temp file with no trap involved at
# all. Shim a failing `mv`/`cp` onto PATH -- each in its own directory,
# prepended for a single invocation only, so the rest of the sweep is
# unaffected -- and prove the trap itself fires: the call fails, the plan file
# is untouched, and no temp file survives. -------------------------------------
mk_plan "$R" trapmv <<'EOF'
- [ ] **T1** **P0** a task used to prove the write-side trap cleans up when mv fails
  - deps: —
EOF
cp "$R/gspec/tasks/trapmv.md" "$TMPROOT/trapmv.before.md"
SHIMDIR_MV="$TMPROOT/shim-mv"; mkdir -p "$SHIMDIR_MV"
printf '#!/bin/sh\nexit 1\n' > "$SHIMDIR_MV/mv"
chmod +x "$SHIMDIR_MV/mv"
out="$(PATH="$SHIMDIR_MV:$PATH" "$ADAPTER" check-task 'trapmv#T1' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a failing mv makes check-task fail loudly, not silently succeed' \
  || bad 'a failing mv makes check-task fail loudly, not silently succeed' "rc=$rc, out=$out"
cmp -s "$TMPROOT/trapmv.before.md" "$R/gspec/tasks/trapmv.md" \
  && ok 'the plan file is byte-identical when mv fails' \
  || bad 'the plan file is byte-identical when mv fails' "$(diff "$TMPROOT/trapmv.before.md" "$R/gspec/tasks/trapmv.md")"
leftover="$(find "$R/gspec" -name '.gspec-check-task.*' 2>/dev/null)"
[ -z "$leftover" ] && ok 'the trap removes the temp file even when mv fails' \
  || bad 'the trap removes the temp file even when mv fails' "$leftover"

mk_plan "$R" trapcp <<'EOF'
- [ ] **T1** **P0** a task used to prove the write-side trap cleans up when cp fails
  - deps: —
EOF
cp "$R/gspec/tasks/trapcp.md" "$TMPROOT/trapcp.before.md"
SHIMDIR_CP="$TMPROOT/shim-cp"; mkdir -p "$SHIMDIR_CP"
printf '#!/bin/sh\nexit 1\n' > "$SHIMDIR_CP/cp"
chmod +x "$SHIMDIR_CP/cp"
out="$(PATH="$SHIMDIR_CP:$PATH" "$ADAPTER" check-task 'trapcp#T1' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a failing cp -p makes check-task fail loudly, not silently succeed' \
  || bad 'a failing cp -p makes check-task fail loudly, not silently succeed' "rc=$rc, out=$out"
cmp -s "$TMPROOT/trapcp.before.md" "$R/gspec/tasks/trapcp.md" \
  && ok 'the plan file is byte-identical when cp -p fails' \
  || bad 'the plan file is byte-identical when cp -p fails' "$(diff "$TMPROOT/trapcp.before.md" "$R/gspec/tasks/trapcp.md")"
leftover="$(find "$R/gspec" -name '.gspec-check-task.*' 2>/dev/null)"
[ -z "$leftover" ] && ok 'the trap removes the temp file even when cp -p fails' \
  || bad 'the trap removes the temp file even when cp -p fails' "$leftover"

# --- finding 6: a duplicate id whose CHECKED copy sorts before the unchecked one
mk_plan "$R" dup <<'EOF'
- [x] **T1** **P0** a checked copy that sorts BEFORE the real, unchecked task
  - deps: —
- [ ] **T1** **P0** the real, unchecked task — this is the one that must flip
  - deps: —
EOF
cp "$R/gspec/tasks/dup.md" "$TMPROOT/dup.before.md"
out="$("$ADAPTER" check-task 'dup#T1' "$R")"; rc=$?
check 'a duplicate id prefers the first UNCHECKED match, not "already"' 'CHECKED=dup#T1' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 flipping the unchecked duplicate' || bad 'exit 0 flipping the unchecked duplicate' "rc=$rc"
grep -qF -- '- [x] **T1** **P0** a checked copy that sorts BEFORE the real, unchecked task' \
  "$R/gspec/tasks/dup.md" \
  && ok 'the earlier already-checked duplicate line is untouched' \
  || bad 'the earlier already-checked duplicate line is untouched' "$(cat "$R/gspec/tasks/dup.md")"
grep -qF -- '- [x] **T1** **P0** the real, unchecked task — this is the one that must flip' \
  "$R/gspec/tasks/dup.md" \
  && ok 'the later, previously-unchecked duplicate line is now flipped' \
  || bad 'the later, previously-unchecked duplicate line is now flipped' "$(cat "$R/gspec/tasks/dup.md")"
d="$(diff "$TMPROOT/dup.before.md" "$R/gspec/tasks/dup.md")"
lt="$(printf '%s\n' "$d" | grep -c '^<' || true)"
gt="$(printf '%s\n' "$d" | grep -c '^>' || true)"
[ "$lt" = "1" ] && [ "$gt" = "1" ] && ok 'exactly one line changed on the duplicate-id plan' \
  || bad 'exactly one line changed on the duplicate-id plan' "diff:
$d"

# --- two UNCHECKED duplicates of the same id: recorded behaviour, not a bug ---
# Malformed gspec (a duplicated id), same as finding 6 above, but both copies
# start unchecked. One invocation flips one of them, so `nodes` still emits the
# node and the loop re-runs the packet once per duplicate. It converges after
# exactly as many invocations as there are duplicates -- unlike the infinite
# no-op bug that was already fixed -- so this is intentional, not a regression.
mk_plan "$R" dupunchecked <<'EOF'
- [ ] **T1** **P0** first unchecked copy of a duplicate id
  - deps: —
- [ ] **T1** **P0** second unchecked copy of a duplicate id
  - deps: —
EOF
out="$("$ADAPTER" nodes dupunchecked "$R" 2>/dev/null)"
count_before="$(printf '%s\n' "$out" | grep -c 'dupunchecked-t1' || true)"
[ "$count_before" = "2" ] && ok 'both unchecked duplicates appear as backlog nodes before any flip' \
  || bad 'both unchecked duplicates appear as backlog nodes before any flip' "count=$count_before
$out"

out="$("$ADAPTER" check-task 'dupunchecked#T1' "$R")"; rc=$?
check 'the first invocation flips one of the two unchecked duplicates' 'CHECKED=dupunchecked#T1' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 flipping the first unchecked duplicate' || bad 'exit 0 flipping the first unchecked duplicate' "rc=$rc"
out="$("$ADAPTER" nodes dupunchecked "$R" 2>/dev/null)"
check 'the node is STILL emitted -- one unchecked duplicate remains (re-run, not skipped)' 'dupunchecked-t1' "$out"

out="$("$ADAPTER" check-task 'dupunchecked#T1' "$R")"; rc=$?
check 'a second invocation flips the remaining duplicate, converging' 'CHECKED=dupunchecked#T1' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 flipping the second unchecked duplicate' || bad 'exit 0 flipping the second unchecked duplicate' "rc=$rc"
out="$("$ADAPTER" nodes dupunchecked "$R" 2>/dev/null)"
refute 'once both duplicates are checked the node no longer appears -- it converges' 'dupunchecked-t1' "$out"

# =============================================================================
printf '\n== task-status: read-only completion status (T2) ==\n'
R="$TMPROOT/taskstatus"; mkdir -p "$R/gspec/tasks"
{
  printf -- '---\nspec-version: v1\nfeature: ts\n---\n\n# Plan: ts\n\n## Plan\n\n'
  printf -- '- [x] **T1** **P0** already finished\n'
  printf -- '  - deps: \342\200\224\n'
  printf -- '- [ ] **T2** **P0** still open\n'
  printf -- '  - deps: T1\n'
} > "$R/gspec/tasks/ts.md"

out="$("$ADAPTER" task-status 'ts#T1' "$R")"; rc=$?
check 'a finished task reads state finished'  "$(printf 'ts#T1\tfinished')" "$out"
check 'the FINISHED= trailer names it'        'FINISHED=ts#T1' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a finished task' || bad 'exit 0 on a finished task' "rc=$rc"

out="$("$ADAPTER" task-status 'ts#T2' "$R")"; rc=$?
check 'an unchecked task reads state unchecked' "$(printf 'ts#T2\tunchecked')" "$out"
check 'the FINISHED= trailer is empty'          'FINISHED=' "$out"
refute 'and does not name the unchecked task'   'FINISHED=ts#T2' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on an unchecked task' || bad 'exit 0 on an unchecked task' "rc=$rc"

# both accepted id forms resolve identically (reuses check-task's resolution)
out="$("$ADAPTER" task-status 'ts-t1' "$R")"; rc=$?
check 'the packet-id form resolves the same finished task' "$(printf 'ts-t1\tfinished')" "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on the packet-id form' || bad 'exit 0 on the packet-id form' "rc=$rc"

# every "gspec is optional" case -> state unknown, exit 0, and the reason says which
R2="$TMPROOT/taskstatus-nogspec"; mkdir -p "$R2"
out="$("$ADAPTER" task-status 'ts#T1' "$R2")"; rc=$?
check 'no gspec/ directory -> unknown'   "$(printf 'ts#T1\tunknown')" "$out"
check 'and says gspec is optional'       'gspec is optional' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 with no gspec/ directory' || bad 'exit 0 with no gspec/ directory' "rc=$rc"

out="$("$ADAPTER" task-status 'fix-login-bug' "$R")"; rc=$?
check 'an id that does not parse as a gspec task id -> unknown' "$(printf 'fix-login-bug\tunknown')" "$out"
check 'and says so'                                              'not a gspec task id' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on an unparseable task id' || bad 'exit 0 on an unparseable task id' "rc=$rc"

out="$("$ADAPTER" task-status 'other#T1' "$R")"; rc=$?
check 'no plan file for that feature slug -> unknown' "$(printf 'other#T1\tunknown')" "$out"
check 'and names the missing plan'                     'no plan file for feature other' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 with no plan file' || bad 'exit 0 with no plan file' "rc=$rc"

out="$("$ADAPTER" task-status 'ts#T99' "$R")"; rc=$?
check 'a task id absent from an EXISTING plan -> unknown' "$(printf 'ts#T99\tunknown')" "$out"
check 'and names the plan it looked in'                    'ts.md' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a task id absent from an existing plan (READ-ONLY: never the exit-4 drift signal check-task uses)' \
  || bad 'exit 0 on drift for task-status' "rc=$rc"

# a mixed set: the exact FINISHED= line, comma-separated, no spaces
out="$("$ADAPTER" task-status 'ts#T1,ts#T2,fix-login-bug' "$R")"; rc=$?
check 'finished line'   "$(printf 'ts#T1\tfinished')" "$out"
check 'unchecked line'  "$(printf 'ts#T2\tunchecked')" "$out"
check 'unknown line'    "$(printf 'fix-login-bug\tunknown')" "$out"
check 'the FINISHED= trailer names only the finished id, comma-separated, no spaces' 'FINISHED=ts#T1' "$out"
refute 'and never includes the unchecked or unknown ids'                             'FINISHED=ts#T1,ts#T2' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a mixed set, including unknown members' || bad 'exit 0 on a mixed set' "rc=$rc"

# task-status is READ-ONLY: never touches gspec/ (check-task stays the one write)
cp "$R/gspec/tasks/ts.md" "$TMPROOT/ts.before.md"
"$ADAPTER" task-status 'ts#T2' "$R" >/dev/null
cmp -s "$TMPROOT/ts.before.md" "$R/gspec/tasks/ts.md" \
  && ok 'task-status never writes to the plan file' \
  || bad 'task-status never writes to the plan file' "$(diff "$TMPROOT/ts.before.md" "$R/gspec/tasks/ts.md")"

# usage errors are the only non-zero exits
out="$("$ADAPTER" task-status '' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'no ids given is a genuine usage error' || bad 'no ids given is a genuine usage error' "rc=$rc"

out="$("$ADAPTER" task-status 'ts#T1' "$TMPROOT/does-not-exist-at-all")"; rc=$?
[ "$rc" -ne 0 ] && ok 'an unreadable root is a genuine usage error' || bad 'an unreadable root is a genuine usage error' "rc=$rc, out=$out"

# the shared resolution rejects a path-escaping slug exactly like check-task does,
# even though task-status itself never writes -- a second copy that drifted would
# be the defect this criterion exists to catch.
out="$("$ADAPTER" task-status 'a/b#T1' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a slug containing a path separator is refused, matching check-task' \
  || bad 'a slug containing a path separator is refused' "rc=$rc, out=$out"
check 'and explains why' 'path separator' "$out"


# =============================================================================
printf '\n== gspec 3.x: the feature-folder layout (ADR 0020 D3) ==\n'
# gspec 3.0 moved a feature's PRD and plan into gspec/features/<slug>/. The
# adapter reads it alongside the two older layouts, so this section walks the
# WHOLE surface -- every subcommand that touches a path -- on a folder-layout
# project. A subcommand that silently reads nothing is the failure mode ADR 0020
# exists to prevent, and it looks exactly like an empty backlog.
R="$TMPROOT/v2layout"; mkdir -p "$R"
mk_prd_v2 "$R" folded 1 1
mk_plan_v2 "$R" folded <<'EOF'
- [ ] **T1** **P1** first folder-layout task
  - deps: —
  - covers: "open capability 1"
- [ ] **T2** **P1** second folder-layout task
  - deps: T1
EOF

out="$("$ADAPTER" check "$R" 2>&1)"; rc=$?
check 'check reads a folder-layout project'   'CHECK=ok' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a folder-layout project' || bad 'exit 0 on a folder-layout project' "rc=$rc"

out="$("$ADAPTER" features "$R")"
check 'features sees the folded feature'      'folded' "$out"
# The slug comes from the DIRECTORY name here. `basename <path> .md` -- what
# every call site did before the layout seam -- yields the literal "prd"/"tasks"
# for every feature in this layout, which reads as one feature named "tasks"
# rather than as N features. Assert the real slug, and assert those two never
# appear as slugs.
refute 'never reads the basename as the slug (prd)'   'prd	' "$out"
refute 'never reads the basename as the slug (tasks)' 'tasks	' "$out"
# One unchecked capability => not done.
check 'completion still DERIVED from prd.md'  'folded	9999	0' "$out"

out="$("$ADAPTER" next "$R")"
check 'next picks the folded feature'         'NEXT=folded' "$out"
check 'and resolves the folder plan'          'PLAN=gspec/features/folded/tasks.md' "$out"
refute 'no legacy-location warning on 3.x'    'pre-3.x plan location' "$out"
# arch.md / design.html are gspec's to write and absent is NORMAL -- a feature
# with no UI never gets a design. Absence must never read as an error.
refute 'no ARCH line when arch.md is absent'    'ARCH=' "$out"
refute 'no DESIGN line when design.html absent' 'DESIGN=' "$out"

printf -- '---\nspec-version: v2\n---\n\n## Data\nNot applicable.\n' > "$R/gspec/features/folded/arch.md"
printf -- '<!-- spec-version: v2 -->\n<html></html>\n' > "$R/gspec/features/folded/design.html"
out="$("$ADAPTER" next "$R")"
check 'ARCH is surfaced when present'         'ARCH=gspec/features/folded/arch.md' "$out"
check 'DESIGN is surfaced when present'       'DESIGN=gspec/features/folded/design.html' "$out"
# They are surfaced as PATHS and never parsed: they say what to build, which is
# gspec's half of the seam (ADR 0020). `check` asserts the version pin only over
# the consumed contract, so a design.html carrying an HTML-comment marker rather
# than YAML frontmatter must not fail it.
out="$("$ADAPTER" check "$R" 2>&1)"
check 'enriched siblings are outside the asserted contract' 'CHECK=ok' "$out"

out="$("$ADAPTER" nodes folded "$R")"
check 'nodes emits the folder plans tasks'    'folded-t1' "$out"
check 'and the second one'                    'folded-t2' "$out"
out="$("$ADAPTER" nodes-all "$R")"
check 'nodes-all reaches the folder layout'   'folded-t1' "$out"

# check-task: the adapter's one write, in the folder layout, via the packet-id
# form the loop actually holds at packet close. This is the case the old code
# could not pass -- it resolved candidate slugs with `basename <plan> .md`, so
# every folder-layout plan offered the slug "tasks" and `folded-t1` matched
# nothing.
out="$("$ADAPTER" check-task folded-t1 "$R" 2>&1)"; rc=$?
check 'check-task resolves a packet id in the folder layout' 'CHECKED=' "$out"
check 'and names the folder plan'             'gspec/features/folded/tasks.md' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a folder-layout flip' || bad 'exit 0 on a folder-layout flip' "rc=$rc"
grep -q '^- \[x\] \*\*T1\*\*' "$R/gspec/features/folded/tasks.md" \
  && ok 'the checkbox actually flipped on disk' \
  || bad 'the checkbox actually flipped on disk' "$(cat "$R/gspec/features/folded/tasks.md")"
grep -q '^- \[ \] \*\*T2\*\*' "$R/gspec/features/folded/tasks.md" \
  && ok 'and no other task line was touched' \
  || bad 'and no other task line was touched' "$(cat "$R/gspec/features/folded/tasks.md")"
# No scratch left beside the plan (the temp file lands in the feature folder now).
[ -z "$(ls "$R/gspec/features/folded"/.gspec-check-task.* 2>/dev/null)" ] \
  && ok 'no temp file stranded in the feature folder' \
  || bad 'no temp file stranded in the feature folder' "$(ls -a "$R/gspec/features/folded")"

out="$("$ADAPTER" check-task 'folded#T2' "$R" 2>&1)"
check 'the canonical id form works too'       'gspec/features/folded/tasks.md' "$out"

out="$("$ADAPTER" task-status 'folded-t1,folded-t2' "$R" 2>&1)"
check 'task-status reads the folder plan'     'folded-t1	finished' "$out"
check 'and the second, now also flipped'      'folded-t2	finished' "$out"

# The path-escape refusal is LOAD-BEARING in this layout, not belt-and-braces:
# the slug is interpolated into a DIRECTORY name, so `../../etc` would resolve a
# plan path outside gspec/ entirely -- and check-task WRITES.
out="$("$ADAPTER" check-task 'a/b#T1' "$R" 2>&1)"; rc=$?
check 'a path-separator slug is still refused' 'path separator' "$out"
# A refusal is a genuine USAGE error, not one of the "gspec is optional" exit-0
# outcomes: the caller passed something the adapter must never resolve, and both
# check-task and task-status `die` on it. Silently exiting 0 here would let a
# loop treat an escaped write as a no-op flip.
[ "$rc" -ne 0 ] && ok 'and refusing is a non-zero usage error, matching task-status' \
  || bad 'refusal exit code' "rc=$rc"
out="$("$ADAPTER" check-task '../../etc#T1' "$R" 2>&1)"
check 'a .. component is refused too'          "'..'" "$out"

# files-status keys the sidecar by <feature>#<id>. With the slug taken from the
# basename this produced `tasks#T1` for every feature at once, so a correct
# sidecar entry read as `orphan` -- silent, and it costs parallelism.
mkdir -p "$R/.agents"
cat > "$R/.agents/task-files.yaml" <<'EOF'
tasks:
  - task: folded#T3
    files: [src/a.ts]
    fingerprint: third folder-layout task
EOF
cat >> "$R/gspec/features/folded/tasks.md" <<'EOF'
- [ ] **T3** **P1** third folder-layout task
  - deps: —
EOF
out="$("$ADAPTER" files-status "$R")"
check 'files-status matches a folder-layout task' 'ok              folded#T3' "$out"
refute 'and does not read it as an orphan'        'orphan          folded#T3' "$out"

# =============================================================================
printf '\n== gspec 3.x: mixed and half-migrated repos ==\n'
# A consumer repo migrates on ITS schedule, and /gspec-migrate moves feature by
# feature -- so both layouts coexisting is a normal intermediate state, not a
# corrupt one.
R="$TMPROOT/mixed"; mkdir -p "$R"
mk_prd_v2 "$R" migrated 0 1
mk_plan_v2 "$R" migrated <<'EOF'
- [ ] **T1** **P1** task in the new layout
  - deps: —
EOF
mk_prd "$R" untouched 0 1
mk_plan "$R" untouched <<'EOF'
- [ ] **T1** **P1** task in the old layout
  - deps: —
EOF
out="$("$ADAPTER" features "$R")"
check 'the migrated feature is listed'    'migrated' "$out"
check 'and the unmigrated one too'        'untouched' "$out"
n="$(printf '%s\n' "$out" | grep -c .)"
[ "$n" = "2" ] && ok 'exactly two features, one per layout' || bad 'exactly two features' "got $n rows: $out"
out="$("$ADAPTER" check "$R" 2>&1)"
check 'a mixed-version repo passes the pin' 'CHECK=ok' "$out"
out="$("$ADAPTER" nodes-all "$R")"
check 'nodes-all reaches the new layout'  'migrated-t1' "$out"
check 'and the old one, in the same run'  'untouched-t1' "$out"

# A slug present in BOTH layouts is a half-finished /gspec-migrate: the mover
# copies nothing, so the newer path is the destination and must win. Two rows
# here would be two features disagreeing about how done one feature is.
R="$TMPROOT/halfmoved"; mkdir -p "$R"
mk_prd "$R" both 0 1          # flat: one capability OPEN
mk_plan "$R" both <<'EOF'
- [ ] **T1** **P1** the stale flat copy
  - deps: —
EOF
mk_prd_v2 "$R" both 1 0       # folder: fully done -- the migrated truth
mk_plan_v2 "$R" both <<'EOF'
- [x] **T1** **P1** the migrated copy
  - deps: —
EOF
out="$("$ADAPTER" features "$R")"
n="$(printf '%s\n' "$out" | grep -c .)"
[ "$n" = "1" ] && ok 'a slug in both layouts yields ONE feature row' || bad 'one feature row' "got $n rows: $out"
check 'and the folder PRD is the one read (done=1)' 'both	9999	1' "$out"
out="$("$ADAPTER" nodes both "$R")"
[ -z "$out" ] && ok 'the folder plan wins, so its checked task yields no packet' \
  || bad 'the folder plan wins' "got: $out"
out="$("$ADAPTER" check-task 'both#T1' "$R" 2>&1)"
check 'check-task writes to the folder plan, never the stale flat one' 'gspec/features/both/tasks.md' "$out"
grep -q 'the stale flat copy' "$R/gspec/tasks/both.md" \
  && ok 'the shadowed flat plan is left byte-untouched' \
  || bad 'the shadowed flat plan is left untouched' "$(cat "$R/gspec/tasks/both.md")"

# =============================================================================
printf '\n----------------------------------------\n'
printf 'gspec-backlog: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
