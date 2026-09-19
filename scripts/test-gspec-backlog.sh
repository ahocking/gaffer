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

# The third nothing-to-do state, and it is asserted over SEVERAL complete
# features rather than one: the other two states are corrected by making their
# branches reachable again, and a correction must not be evidenced by a branch
# that has simply stopped being reached. So this case pins that a backlog whose
# every feature reads as complete still answers NEXT=none with that reason, and
# carries neither of the other two states' per-feature lines.
R="$TMPROOT/alldone"; mkdir -p "$R"
mk_prd "$R" finished 2 0
mk_prd "$R" also-finished 1 0
mk_prd "$R" finished-too 3 0
out="$("$ADAPTER" next "$R")"
check 'all-complete reports none'          'NEXT=none' "$out"
check 'all-complete names the reason'      'REASON=all features complete' "$out"
refute 'all-complete is not reported as blocked'  'BLOCKED=' "$out"
refute 'all-complete is not reported as deferred' 'DEFERRED=' "$out"

R="$TMPROOT/allblocked"; mkdir -p "$R"
mk_prd "$R" pre 0 1
mk_prd "$R" post 0 1 pre
out="$("$ADAPTER" next "$R" | grep -c 'NEXT=pre')"
[ "$out" = "1" ] && ok 'blocked feature is skipped for its dependency' || bad 'blocked feature skipped' "got=$out"

# =============================================================================
printf '\n== next: the nothing-to-do branches at a size that reproduces the pipe race ==\n'
# Both of these fixtures are LARGE on purpose, and the size is the whole point.
# `cmd_next` used to test each nothing-to-do condition with
# `printf '%s\n' "$rows" | awk -F'\t' '…' | grep -q .`: `grep -q` exits on its
# first match and closes the pipe, the awk still writing takes the signal, and
# the file-wide `pipefail` reports that signal in place of grep's success — so a
# TRUE condition reads as false and control falls through to the last branch,
# which reports the backlog finished. The window only opens once the filtered
# payload outgrows a single buffered write, so a small fixture certifies the fix
# while exercising nothing: the same construct showed 0 failures in 400
# iterations at 733 bytes. Each fixture below therefore builds a filtered
# payload of at least 40 KiB (twice the 18,756-byte reproduction recorded in the
# PRD), asserted rather than assumed, and each assertion runs over a repeat loop
# because the failure is a race and a single draw proves nothing.
#
# Both assert the branch's own REASON= text AND its per-feature lines by feature
# name — the full set, compared as a sorted block. An assertion that the output
# merely differs from `all features complete` passes on several wrong answers.
BIGWHY="$(awk 'BEGIN{ while (length(s) < 2200) s = s "roadmap rationale text that makes every feature row long "; print substr(s, 1, 2200) }')"
BIGN=20
BIGITER=50

# --- every incomplete feature blocked ---------------------------------------
# OBSERVED PRE-FIX: run against the unfixed `cmd_next` (the `printf | awk |
# grep -q .` condition) this case failed 40 of 50 and 45 of 50 invocations over
# two sweep runs — each failure reporting `REASON=all features complete` over a
# backlog in which nothing was complete and every feature was blocked.
#
# Every feature depends on its successor and the last on the first: with no
# deferred entries and no dependency on a finished feature, that cycle is the
# shape in which every incomplete feature is genuinely blocked, so the blocked
# branch is the one under test and the deferred capture is empty.
R="$TMPROOT/bigblocked"; mkdir -p "$R/.agents"
exp=""
{ printf 'schema: 1\nfeatures:\n'
  for ((i=0;i<BIGN;i++)); do
    s="$(printf 'bigblk-%02d' "$i")"
    nxt="$(printf 'bigblk-%02d' $(( (i+1) % BIGN )))"
    mk_prd "$R" "$s" 0 1 "$nxt"
    printf '  - slug: %s\n    order: %d\n    why: %s %d\n' "$s" "$((10+i))" "$BIGWHY" "$i"
    exp="$exp$(printf 'BLOCKED=%s depends_on=%s' "$s" "$nxt")"$'\n'
  done
} > "$R/.agents/roadmap.yaml"
exp_blocked="$(printf '%s' "$exp" | sort)"
bytes="$("$ADAPTER" features "$R" | awk -F'\t' '$3=="0" && $7!="1"' | wc -c | tr -d ' ')"
# 44,700 bytes over 20 filtered rows when this comment was written.
[ "$bytes" -ge 40960 ] \
  && ok "the blocked fixture's filtered payload is at least 40 KiB ($bytes bytes)" \
  || bad 'blocked fixture is large enough to reproduce the race' "filtered payload is only $bytes bytes — below the buffer threshold, so this case would certify the fix while exercising nothing"

misreason=0; misline=0
for ((i=0;i<BIGITER;i++)); do
  out="$("$ADAPTER" next "$R")"
  case "$out" in
    *'REASON=every incomplete feature is blocked by an unfinished dependency'*) ;;
    *) misreason=$((misreason+1)) ;;
  esac
  got="$(printf '%s\n' "$out" | grep '^BLOCKED=' | sort)"
  [ "$got" = "$exp_blocked" ] || misline=$((misline+1))
done
[ "$misreason" -eq 0 ] \
  && ok "an all-blocked backlog reports the blocked reason on every one of $BIGITER runs" \
  || bad 'all-blocked reports the blocked reason every time' "wrong reason in $misreason of $BIGITER runs"
[ "$misline" -eq 0 ] \
  && ok "and one BLOCKED= line per feature, by name, on every one of $BIGITER runs" \
  || bad 'all-blocked names every blocked feature every time' "per-feature lines wrong in $misline of $BIGITER runs
     last run: $out"
refute 'and never says the backlog is finished' 'all features complete' "$out"

# --- every remaining feature deferred ---------------------------------------
# OBSERVED PRE-FIX: run against the unfixed `cmd_next` this case failed 45 of 50
# and 48 of 50 invocations over two sweep runs, each reporting `REASON=all
# features complete` over a backlog whose every feature was deferred — a human
# decision, reversible by editing one line, reported as finished work. The same
# construct at this site showed 0 failures in 400 iterations against the
# repository's real 733-byte payload; the size is what opens the window.
R="$TMPROOT/bigdeferred"; mkdir -p "$R/.agents"
exp=""
{ printf 'schema: 1\nfeatures:\n'
  for ((i=0;i<BIGN;i++)); do
    s="$(printf 'bigdef-%02d' "$i")"
    mk_prd "$R" "$s" 0 1
    printf '  - slug: %s\n    order: %d\n    why: %s %d\n    deferred: true\n' "$s" "$((10+i))" "$BIGWHY" "$i"
    exp="$exp$(printf 'DEFERRED=%s why=%s %d' "$s" "$BIGWHY" "$i")"$'\n'
  done
} > "$R/.agents/roadmap.yaml"
exp_deferred="$(printf '%s' "$exp" | sort)"
bytes="$("$ADAPTER" features "$R" | awk -F'\t' '$3=="0" && $7=="1"' | wc -c | tr -d ' ')"
# 44,500 bytes over 20 filtered rows when this comment was written.
[ "$bytes" -ge 40960 ] \
  && ok "the deferred fixture's filtered payload is at least 40 KiB ($bytes bytes)" \
  || bad 'deferred fixture is large enough to reproduce the race' "filtered payload is only $bytes bytes — below the buffer threshold, so this case would certify the fix while exercising nothing"

misreason=0; misline=0; mishint=0
for ((i=0;i<BIGITER;i++)); do
  out="$("$ADAPTER" next "$R")"
  case "$out" in
    *'REASON=every remaining feature is deferred in .agents/roadmap.yaml'*) ;;
    *) misreason=$((misreason+1)) ;;
  esac
  case "$out" in
    *'HINT=remove `deferred: true` from an entry to bring it back into the backlog'*) ;;
    *) mishint=$((mishint+1)) ;;
  esac
  got="$(printf '%s\n' "$out" | grep '^DEFERRED=' | sort)"
  [ "$got" = "$exp_deferred" ] || misline=$((misline+1))
done
[ "$misreason" -eq 0 ] \
  && ok "an all-deferred backlog reports the deferred reason on every one of $BIGITER runs" \
  || bad 'all-deferred reports the deferred reason every time' "wrong reason in $misreason of $BIGITER runs"
[ "$misline" -eq 0 ] \
  && ok "and one DEFERRED= line per feature, with its why, on every one of $BIGITER runs" \
  || bad 'all-deferred names every deferred feature every time' "per-feature lines wrong in $misline of $BIGITER runs"
[ "$mishint" -eq 0 ] \
  && ok "and the HINT= line saying how to undo it, on every one of $BIGITER runs" \
  || bad 'all-deferred always says how to undo it' "HINT missing in $mishint of $BIGITER runs"
refute 'and never says the backlog is finished' 'all features complete' "$out"

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
# packet-graph.sh (retired) used to derive "no edge" from this by finding no
# producer for the consumed token; asserted directly on the TSV now — a
# checked task never becomes a node, so nothing can produce api#T1.
"$ADAPTER" nodes api "$R" > "$TMPROOT/checkeddep.tsv"
prod1="$(awk -F'\t' '$5=="api#T1"' "$TMPROOT/checkeddep.tsv")"
[ -z "$prod1" ] && ok 'a dep on a checked task has no producer row (no edge for a scheduler to find)' \
  || bad 'a dep on a checked task has no producer row (no edge for a scheduler to find)' "$prod1"

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

printf '\n== sidecar: end-to-end, scope resolves as expected (was: unlocks a wave in packet-graph.sh, retired in retire-unused-loop-modes T2 — asserted directly on file scope now) ==\n'
R="$TMPROOT/sidecar-e2e"; mkdir -p "$R/.agents"
mk_prd "$R" par 0 1
mk_plan "$R" par <<'EOF'
- [ ] **T1** **P0** build the left side
  - deps: —
- [ ] **T2** **P0** build the right side
  - deps: —
EOF
out="$("$ADAPTER" nodes par "$R" 2>/dev/null)"
t1f="$(printf '%s\n' "$out" | awk -F'\t' '$1=="par-t1"{print $3}')"
t2f="$(printf '%s\n' "$out" | awk -F'\t' '$1=="par-t2"{print $3}')"
[ -z "$t1f" ] && [ -z "$t2f" ] && ok 'with no files: line and no sidecar entry, both packets carry empty scope' \
  || bad 'with no files: line and no sidecar entry, both packets carry empty scope' "t1=$t1f t2=$t2f"
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
out="$("$ADAPTER" nodes par "$R" 2>/dev/null)"
t1f="$(printf '%s\n' "$out" | awk -F'\t' '$1=="par-t1"{print $3}')"
t2f="$(printf '%s\n' "$out" | awk -F'\t' '$1=="par-t2"{print $3}')"
[ "$t1f" = 'src/left/**' ] && [ "$t2f" = 'src/right/**' ] && ok 'sidecar scoping resolves each task to its own disjoint file scope' \
  || bad 'sidecar scoping resolves each task to its own disjoint file scope' "t1=$t1f t2=$t2f"

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
# retire-unused-loop-modes T2 deleted packet-graph.sh, the former end-to-end
# consumer of `nodes` output; the loop now reads the TSV directly. That T2
# packet's own requirement is that `nodes` and file-scope resolution are
# UNCHANGED, so this case asserts the exact TSV bytes rather than piping
# through a scheduler that no longer exists.
printf '\n== nodes: TSV is byte-identical (id/feature/files/consumes/produces/fdeps) ==\n'
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
out="$("$ADAPTER" nodes svc "$R")"
expected="$(printf 'svc-t1\tsvc\tdb/schema.sql\t\tsvc#T1\t\nsvc-t2\tsvc\tsrc/api.ts\tsvc#T1\tsvc#T2\t\nsvc-t3\tsvc\tdocs/api.md\tsvc#T1\tsvc#T3\t')"
[ "$out" = "$expected" ] && ok 'nodes TSV bytes unchanged (file scope carried through as before)' \
  || bad 'nodes TSV bytes unchanged (file scope carried through as before)' "got:
$out
want:
$expected"

# A dangling consumes (dep on a checked task) must not crash the adapter, and
# the raw dep text still lands in the consumes column with no producer for it.
R="$TMPROOT/dangle"; mkdir -p "$R"
mk_prd "$R" d 0 1
mk_plan "$R" d <<'EOF'
- [x] **T1** **P0** done
- [ ] **T2** **P0** depends on done work
  - deps: T1
EOF
out2="$("$ADAPTER" nodes d "$R")"
expected2="$(printf 'd-t2\td\t\td#T1\td#T2\t')"
[ "$out2" = "$expected2" ] && ok 'dangling dep (checked producer) still emits a clean, unchanged TSV row' \
  || bad 'dangling dep (checked producer) still emits a clean, unchanged TSV row' "got:
$out2
want:
$expected2"

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

# `$R` is a real git repo from here on: `gone` (loop-measurement T2) now
# requires positive evidence from the plan's OWN git history, so the fixtures
# below that exercise it need genuine commits, not just files on disk.
git -C "$R" init -q
git -C "$R" config user.email t@t
git -C "$R" config user.name t
git -C "$R" add -A
git -C "$R" commit -q -m 'initial: ts T1 T2'

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

# `gone` now requires POSITIVE EVIDENCE from the plan's own git history
# (loop-measurement T2 "gone must require positive evidence"), so give T99 a
# real history: add it as a real task line, commit, then remove it again and
# commit -- restoring ts.md to the exact T1/T2 content every other case in
# this section still relies on.
{
  printf -- '---\nspec-version: v1\nfeature: ts\n---\n\n# Plan: ts\n\n## Plan\n\n'
  printf -- '- [x] **T1** **P0** already finished\n'
  printf -- '  - deps: \342\200\224\n'
  printf -- '- [ ] **T2** **P0** still open\n'
  printf -- '  - deps: T1\n'
  printf -- '- [ ] **T99** **P0** a task later re-decomposed away\n'
  printf -- '  - deps: \342\200\224\n'
} > "$R/gspec/tasks/ts.md"
git -C "$R" add -A
git -C "$R" commit -q -m 'ts: add T99'
{
  printf -- '---\nspec-version: v1\nfeature: ts\n---\n\n# Plan: ts\n\n## Plan\n\n'
  printf -- '- [x] **T1** **P0** already finished\n'
  printf -- '  - deps: \342\200\224\n'
  printf -- '- [ ] **T2** **P0** still open\n'
  printf -- '  - deps: T1\n'
} > "$R/gspec/tasks/ts.md"
git -C "$R" add -A
git -C "$R" commit -q -m 'ts: re-decompose away T99'

out="$("$ADAPTER" task-status 'ts#T99' "$R")"; rc=$?
check 'a task id absent from an EXISTING plan, WITH history evidence -> gone (loop-measurement T2)' "$(printf 'ts#T99\tgone')" "$out"
refute 'and is NOT reported as unknown'                    "$(printf 'ts#T99\tunknown')" "$out"
check 'and names the plan it looked in'                    'ts.md' "$out"
check 'and the reason cites the history evidence'          'git history' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a task id absent from an existing plan (READ-ONLY: never the exit-4 drift signal check-task uses)' \
  || bad 'exit 0 on drift for task-status' "rc=$rc"

# --- loop-measurement T2: gone requires POSITIVE EVIDENCE, not just absence -
# The reviewer's remaining hole: a non-gspec packet id that merely happens to
# prefix-match a live feature's slug (`ts-fix-login-bug` against feature
# `ts`) must NOT read `gone` just because `ts` has a plan and the id is
# absent from it -- it was never a gspec task here, so it must read `unknown`
# (which `sweep-open` then sweeps as `interrupted`, the safe direction per
# the plan preamble).
out="$("$ADAPTER" task-status 'ts-fix-login-bug' "$R")"; rc=$?
check 'a non-gspec id that prefix-collides with a live feature slug -> unknown, not gone' \
  "$(printf 'ts-fix-login-bug\tunknown')" "$out"
refute 'and must not be misreported as gone -- absence alone is not evidence' \
  "$(printf 'ts-fix-login-bug\tgone')" "$out"
check 'and the reason says the id never appears in that plan history' 'never appears' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a prefix-colliding non-gspec id' || bad 'exit 0 on a prefix-colliding non-gspec id' "rc=$rc"

# the false-positive guard: an id mentioned only in PROSE in a historical
# version of the plan (never as its own task line) must not read as evidence
# either -- a bare substring search over history would get this wrong; the
# structural task-line regex must not.
RP="$TMPROOT/taskstatus-prose"; mkdir -p "$RP/gspec/tasks"
git -C "$RP" init -q; git -C "$RP" config user.email t@t; git -C "$RP" config user.name t
{
  printf -- '---\nspec-version: v1\nfeature: pr\n---\n\n# Plan: pr\n\n## Plan\n\n'
  printf -- '- [ ] **T5** **P0** something; note: replaces the old T77 approach\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RP/gspec/tasks/pr.md"
git -C "$RP" add -A
git -C "$RP" commit -q -m 'T77 mentioned only in prose, never as a task line'
out="$("$ADAPTER" task-status 'pr#T77' "$RP")"; rc=$?
check 'an id mentioned only in PROSE in plan history -> unknown, not gone' "$(printf 'pr#T77\tunknown')" "$out"
refute 'a prose mention must not be misread as a historical task line' "$(printf 'pr#T77\tgone')" "$out"
check 'and the reason says it never appears as a task line' 'never appears' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on an id that only ever appeared in prose' || bad 'exit 0 on an id that only ever appeared in prose' "rc=$rc"

# fail-soft: the plan file exists and parses, but there is no git history to
# consult at all -- must read unknown (history unavailable), never gone.
RNG="$TMPROOT/taskstatus-nogit"; mkdir -p "$RNG/gspec/tasks"
{
  printf -- '---\nspec-version: v1\nfeature: ng\n---\n\n# Plan: ng\n\n## Plan\n\n'
  printf -- '- [ ] **T1** **P0** a task in a plan with no git repo at all\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RNG/gspec/tasks/ng.md"
out="$("$ADAPTER" task-status 'ng#T99' "$RNG")"; rc=$?
check 'no git repo at all -> unknown (history unavailable), not gone' "$(printf 'ng#T99\tunknown')" "$out"
refute 'and must not be misreported as gone'                          "$(printf 'ng#T99\tgone')" "$out"
check 'and the reason says history is unavailable, not that the task never existed' 'unavailable' "$out"
refute 'and must not claim positive evidence it does not have'                       'never appears' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 with no git repo at all' || bad 'exit 0 with no git repo at all' "rc=$rc"

# fail-soft: a real git repo, but the plan file itself was never committed --
# same "cannot confirm" reason, not "never existed".
RUT="$TMPROOT/taskstatus-untracked"; mkdir -p "$RUT/gspec/tasks"
git -C "$RUT" init -q; git -C "$RUT" config user.email t@t; git -C "$RUT" config user.name t
{
  printf -- '---\nspec-version: v1\nfeature: ut\n---\n\n# Plan: ut\n\n## Plan\n\n'
  printf -- '- [ ] **T1** **P0** a task in an untracked plan file\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RUT/gspec/tasks/ut.md"
out="$("$ADAPTER" task-status 'ut#T99' "$RUT")"; rc=$?
check 'plan file untracked in a real git repo -> unknown (history unavailable), not gone' \
  "$(printf 'ut#T99\tunknown')" "$out"
refute 'and must not be misreported as gone'                          "$(printf 'ut#T99\tgone')" "$out"
check 'and the reason says history is unavailable' 'unavailable' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 with an untracked plan file' || bad 'exit 0 with an untracked plan file' "rc=$rc"

# --- Critical 1 (loop-measurement T2 reviewer finding): an empty or ---------
# unparseable plan must read unknown for EVERY id, never gone -- absence of
# ANY parseable task line in the whole file is not positive evidence that one
# specific id was removed. Pre-fix, `_task_lookup` prints nothing for both "no
# such id" and "no ids at all here", and both fell into the gone catch-all.
: > "$R/gspec/tasks/empty.md"
out="$("$ADAPTER" task-status 'empty#T1' "$R")"; rc=$?
check 'plan file EXISTS but is EMPTY -> unknown, not gone' "$(printf 'empty#T1\tunknown')" "$out"
refute 'and must not be misreported as gone'                "$(printf 'empty#T1\tgone')" "$out"
check 'and the reason names the real cause'                 'no task lines this adapter can parse' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on an empty plan file' || bad 'exit 0 on an empty plan file' "rc=$rc"

{
  printf -- '---\nspec-version: v1\nfeature: noparse\n---\n\n# Plan: noparse\n\n'
  printf -- 'This plan has content, but no line this adapter recognizes as a task.\n'
} > "$R/gspec/tasks/noparse.md"
out="$("$ADAPTER" task-status 'noparse#T1' "$R")"; rc=$?
check 'plan EXISTS with content, NO parseable task lines -> unknown, not gone' "$(printf 'noparse#T1\tunknown')" "$out"
refute 'and must not be misreported as gone'                                    "$(printf 'noparse#T1\tgone')" "$out"
check 'and the reason names the real cause'                                     'no task lines this adapter can parse' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a plan with no parseable task lines' || bad 'exit 0 on a plan with no parseable task lines' "rc=$rc"

# --- Critical 2 (loop-measurement T2 reviewer finding): the documented ------
# `phase` / `phase-t2` packet-id collision (see `_resolve_task_id`) must not
# silently read `gone` -- the longest-slug-wins guess that is safe for
# check-task (a wrong guess there is a loud rc=4 "no such task") is not safe
# here, because task-status has a silent-success state check-task lacks.
RC="$TMPROOT/collision"; mkdir -p "$RC/gspec/tasks"
{
  printf -- '---\nspec-version: v1\nfeature: phase\n---\n\n# Plan: phase\n\n## Plan\n\n'
  printf -- '- [ ] **T2-T1** **P0** live unchecked task, in the SHORTER-slug feature\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RC/gspec/tasks/phase.md"
{
  printf -- '---\nspec-version: v1\nfeature: phase-t2\n---\n\n# Plan: phase-t2\n\n## Plan\n\n'
  printf -- '- [ ] **T5** **P0** an unrelated task, in the colliding SIBLING feature\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RC/gspec/tasks/phase-t2.md"

out="$("$ADAPTER" nodes phase "$RC" 2>/dev/null)"
check 'nodes phase reproduces the collision: it emits the ambiguous packet id' 'phase-t2-t1' "$out"

out="$("$ADAPTER" task-status 'phase-t2-t1' "$RC")"; rc=$?
check 'an ambiguous packet-id resolution -> unknown, not gone' "$(printf 'phase-t2-t1\tunknown')" "$out"
refute 'and must not silently claim the live task in the OTHER feature was abandoned' \
  "$(printf 'phase-t2-t1\tgone')" "$out"
check 'and the reason names the collision'  'ambiguous' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on an ambiguous packet-id resolution' || bad 'exit 0 on an ambiguous packet-id resolution' "rc=$rc"

# a mixed set: the exact FINISHED= line, comma-separated, no spaces. This
# fixture carries all four states (finished, unchecked, unknown, gone) and is
# the regression guard for `skills/run-loop/SKILL.md`, which feeds FINISHED=
# VERBATIM to `runstate.sh findings --stale --finished` -- the line's format
# and content for every already-supported state must stay byte-identical to
# what it was before `gone` existed.
out="$("$ADAPTER" task-status 'ts#T1,ts#T2,fix-login-bug' "$R")"; rc=$?
check 'finished line'   "$(printf 'ts#T1\tfinished')" "$out"
check 'unchecked line'  "$(printf 'ts#T2\tunchecked')" "$out"
check 'unknown line'    "$(printf 'fix-login-bug\tunknown')" "$out"
check 'the FINISHED= trailer names only the finished id, comma-separated, no spaces' 'FINISHED=ts#T1' "$out"
refute 'and never includes the unchecked or unknown ids'                             'FINISHED=ts#T1,ts#T2' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a mixed set, including unknown members' || bad 'exit 0 on a mixed set' "rc=$rc"

out="$("$ADAPTER" task-status 'ts#T1,ts#T2,fix-login-bug,ts#T99' "$R")"; rc=$?
check 'same fixture plus a gone id: finished line unchanged'  "$(printf 'ts#T1\tfinished')" "$out"
check 'unchecked line unchanged'                                "$(printf 'ts#T2\tunchecked')" "$out"
check 'unknown line unchanged'                                  "$(printf 'fix-login-bug\tunknown')" "$out"
check 'the new gone line'                                       "$(printf 'ts#T99\tgone')" "$out"
# exact-match, not substring: `check` would pass this even if `gone` leaked
# into the trailer (FINISHED=ts#T1 is a substring of FINISHED=ts#T1,ts#T99),
# which is exactly what the refute below is for -- and pinning it against the
# line as a whole, not a fixed member order, is what actually proves gone
# never joins the list.
finished_line="$(printf '%s\n' "$out" | grep '^FINISHED=')"
[ "$finished_line" = 'FINISHED=ts#T1' ] \
  && ok 'FINISHED= still names the finished id, and only it -- gone does not change it' \
  || bad 'FINISHED= still names the finished id, and only it -- gone does not change it' "$finished_line"
refute 'gone is excluded from FINISHED= same as unchecked and unknown' 'FINISHED=ts#T1,ts#T99' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a mixed set including a gone member' || bad 'exit 0 on a mixed set including gone' "rc=$rc"

# --- loop-measurement T2 round 2: cases the first sweep missed -------------
# (reviewer finding: forcing each of these to break produced ZERO or only
# vacuous failures). Each fixture below is built so the assertion genuinely
# depends on the thing it names, not on an incidental fixture property.

# Case 1 (Important 2, #1): the parseable-line-count gate (Critical 1) must
# win over a FOUND -- a plan that is EMPTY right now, but was COMMITTED with
# real content earlier (so the history probe ALONE would say FOUND), must
# still read unknown. Without the tcount==0 short-circuit, `_task_lookup` on
# an empty file returns nothing (indistinguishable from "no such id"), falls
# through to the history probe, and the probe genuinely finds the earlier
# commit. This needs REAL git history behind an empty file -- an untracked
# empty file (as the earlier Critical-1 cases use) reads UNAVAILABLE and
# never reaches this gate at all.
REH="$TMPROOT/taskstatus-emptyhist"; mkdir -p "$REH/gspec/tasks"
git -C "$REH" init -q; git -C "$REH" config user.email t@t; git -C "$REH" config user.name t
{
  printf -- '---\nspec-version: v1\nfeature: em\n---\n\n# Plan: em\n\n## Plan\n\n'
  printf -- '- [ ] **T1** **P0** a task that will be truncated away with the whole file\n'
  printf -- '  - deps: \342\200\224\n'
} > "$REH/gspec/tasks/em.md"
git -C "$REH" add -A; git -C "$REH" commit -q -m 'em: T1 present'
: > "$REH/gspec/tasks/em.md"
git -C "$REH" add -A; git -C "$REH" commit -q -m 'em: truncate the whole plan to empty'
out="$("$ADAPTER" task-status 'em#T1' "$REH")"; rc=$?
check 'a plan EMPTY now but with real committed history for the id -> unknown, not gone (parseable-line count wins over history)' \
  "$(printf 'em#T1\tunknown')" "$out"
refute 'and must not be misreported as gone even though the history probe alone would say FOUND' \
  "$(printf 'em#T1\tgone')" "$out"
check 'and the reason names the real cause (no parseable lines), not history' 'no task lines this adapter can parse' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on an empty-with-history plan' || bad 'exit 0 on an empty-with-history plan' "rc=$rc"

# Case 2 (Important 2, #2): the ambiguity gate (Critical 2) must sit AHEAD of
# the history probe -- an ambiguous packet id whose longest-slug guess
# genuinely has history evidence for that id (a real task there once, later
# removed) must still read unknown, not gone, because the guess itself is
# unconfirmed. Both plan files stay present on disk so the collision itself
# still fires; only the guessed slug's plan needs the history.
RCH="$TMPROOT/collision-history"; mkdir -p "$RCH/gspec/tasks"
git -C "$RCH" init -q; git -C "$RCH" config user.email t@t; git -C "$RCH" config user.name t
{
  printf -- '---\nspec-version: v1\nfeature: phase\n---\n\n# Plan: phase\n\n## Plan\n\n'
  printf -- '- [ ] **T9** **P0** an unrelated live task, in the SHORTER-slug feature\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RCH/gspec/tasks/phase.md"
{
  printf -- '---\nspec-version: v1\nfeature: phase-t2\n---\n\n# Plan: phase-t2\n\n## Plan\n\n'
  printf -- '- [ ] **T1** **P0** live for now, in the LONGER-slug feature (the longest-slug guess)\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RCH/gspec/tasks/phase-t2.md"
git -C "$RCH" add -A; git -C "$RCH" commit -q -m 'initial: T1 live in phase-t2'
{
  printf -- '---\nspec-version: v1\nfeature: phase-t2\n---\n\n# Plan: phase-t2\n\n## Plan\n\n'
  printf -- '- [ ] **T5** **P0** replaces T1 after re-decomposition\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RCH/gspec/tasks/phase-t2.md"
git -C "$RCH" add -A; git -C "$RCH" commit -q -m 'phase-t2: re-decompose away T1'
out="$("$ADAPTER" task-status 'phase-t2-t1' "$RCH")"; rc=$?
check 'an ambiguous id whose longest-slug guess genuinely has history evidence -> unknown, not gone' \
  "$(printf 'phase-t2-t1\tunknown')" "$out"
refute "the ambiguity gate must block gone even though the history probe alone would say FOUND for the guessed slug" \
  "$(printf 'phase-t2-t1\tgone')" "$out"
check 'and the reason still names the collision' 'ambiguous' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on an ambiguous id with genuine history for the guessed slug' \
  || bad 'exit 0 on an ambiguous id with genuine history for the guessed slug' "rc=$rc"

# Case 3 (Important 2, #3): the shallow-clone demotion must be load-bearing
# -- a FULL clone of $R already reads gone for ts#T99 (asserted above); a
# `--depth 1` SHALLOW clone of the exact same data, where the commit that
# added T99 has fallen outside the shallow boundary, must read unknown.
RSH="$TMPROOT/taskstatus-shallow"
git clone -q --depth 1 "file://$R" "$RSH" 2>/dev/null
out="$("$ADAPTER" task-status 'ts#T99' "$RSH")"; rc=$?
check 'the same gone-worthy id, from a shallow clone of the same repo -> unknown (shallow demotion is load-bearing)' \
  "$(printf 'ts#T99\tunknown')" "$out"
refute 'and must not be misreported as gone from a shallow clone' "$(printf 'ts#T99\tgone')" "$out"
check 'and the reason says history is unavailable' 'unavailable' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on a shallow clone' || bad 'exit 0 on a shallow clone' "rc=$rc"

# Case 4 (Important 2, #4): a REAL git mv across the 3.x relocation (2.x
# gspec/tasks/<slug>.md -> 3.x gspec/features/<slug>/tasks.md), with the
# target id removed BEFORE the move -- so only the old, pre-relocation
# path's history carries the evidence -- proves multi-path probing still
# finds it now that `--follow` is gone.
RMV="$TMPROOT/taskstatus-relocated"; mkdir -p "$RMV/gspec/tasks"
git -C "$RMV" init -q; git -C "$RMV" config user.email t@t; git -C "$RMV" config user.name t
{
  printf -- '---\nspec-version: v1\nfeature: mv\n---\n\n# Plan: mv\n\n## Plan\n\n'
  printf -- '- [ ] **T77** **P0** a task removed before the relocation\n'
  printf -- '  - deps: \342\200\224\n'
  printf -- '- [ ] **T1** **P0** a task that survives the relocation\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RMV/gspec/tasks/mv.md"
git -C "$RMV" add -A; git -C "$RMV" commit -q -m 'mv: T77 present under the 2.x layout'
{
  printf -- '---\nspec-version: v1\nfeature: mv\n---\n\n# Plan: mv\n\n## Plan\n\n'
  printf -- '- [ ] **T1** **P0** a task that survives the relocation\n'
  printf -- '  - deps: \342\200\224\n'
} > "$RMV/gspec/tasks/mv.md"
git -C "$RMV" add -A; git -C "$RMV" commit -q -m 'mv: re-decompose away T77, still under the 2.x layout'
mkdir -p "$RMV/gspec/features/mv"
git -C "$RMV" mv gspec/tasks/mv.md gspec/features/mv/tasks.md
git -C "$RMV" commit -q -m 'mv: relocate to the 3.x feature-folder layout (pure rename, no content change)'
out="$("$ADAPTER" task-status 'mv#T77' "$RMV")"; rc=$?
check 'an id removed BEFORE a real 3.x relocation -> gone, found via the pre-relocation path (multi-path probing, no --follow)' \
  "$(printf 'mv#T77\tgone')" "$out"
check 'and names the CURRENT (3.x) plan path' 'gspec/features/mv/tasks.md' "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 across a genuine 3.x relocation' || bad 'exit 0 across a genuine 3.x relocation' "rc=$rc"

# The Critical's own regression guard: the cross-feature bait. One commit
# deletes ONE feature's plan and adds a DIFFERENT feature's plan with heavily
# overlapping boilerplate (gspec plan files are boilerplate-heavy by
# construction), which is exactly the shape `git log --follow`'s similarity
# heuristic mis-paired as one file's continuous history. `beta#T99` must read
# unknown: T99 was only ever alpha's task, and alpha's path is never one of
# beta's candidate paths under any layout.
RBAIT="$TMPROOT/taskstatus-bait"; mkdir -p "$RBAIT/gspec/tasks"
git -C "$RBAIT" init -q; git -C "$RBAIT" config user.email t@t; git -C "$RBAIT" config user.name t
{
  printf -- '---\nspec-version: v1\nfeature: alpha\n---\n\n# Plan: alpha\n\n## Plan\n\n'
  printf -- '- [ ] **T99** **P0** alpha'"'"'s own task, later abandoned when alpha itself was retired\n'
  printf -- '  - deps: \342\200\224\n'
  printf -- '- [ ] **T1** **P0** filler task A\n  - deps: \342\200\224\n'
  printf -- '- [ ] **T2** **P0** filler task B\n  - deps: \342\200\224\n'
  printf -- '- [ ] **T3** **P0** filler task C\n  - deps: \342\200\224\n'
} > "$RBAIT/gspec/tasks/alpha.md"
git -C "$RBAIT" add -A; git -C "$RBAIT" commit -q -m 'alpha: T99 present'
rm "$RBAIT/gspec/tasks/alpha.md"
{
  printf -- '---\nspec-version: v1\nfeature: beta\n---\n\n# Plan: beta\n\n## Plan\n\n'
  printf -- '- [ ] **T1** **P0** filler task A\n  - deps: \342\200\224\n'
  printf -- '- [ ] **T2** **P0** filler task B\n  - deps: \342\200\224\n'
  printf -- '- [ ] **T3** **P0** filler task C\n  - deps: \342\200\224\n'
  printf -- '- [ ] **T4** **P0** filler task D, new to beta\n  - deps: \342\200\224\n'
} > "$RBAIT/gspec/tasks/beta.md"
git -C "$RBAIT" add -A; git -C "$RBAIT" commit -q -m 'retire alpha, introduce beta (unrelated feature, similar boilerplate)'
out="$("$ADAPTER" task-status 'beta#T99' "$RBAIT")"; rc=$?
check 'the cross-feature bait: an id that only ever belonged to the RETIRED feature, asked about under the NEW one -> unknown' \
  "$(printf 'beta#T99\tunknown')" "$out"
refute "and must not read gone from the OTHER feature's history via similarity-based rename pairing" \
  "$(printf 'beta#T99\tgone')" "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 on the cross-feature bait' || bad 'exit 0 on the cross-feature bait' "rc=$rc"

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
printf '\n== plans: the layout census /gaffer:migrate reads ==\n'
# migrate.sh must never glob gspec/ itself -- every gspec read goes through this
# adapter, which is the rule that kept the 3.x layout to one seam instead of a
# sweep. `plans` is what makes that rule affordable for a layout report.
R="$TMPROOT/census"; mkdir -p "$R"
mk_prd_v2 "$R" newone 0 1
mk_plan_v2 "$R" newone <<'EOF'
- [ ] **T1** **P1** x
EOF
mk_prd "$R" oldone 0 1
mk_plan "$R" oldone <<'EOF'
- [ ] **T1** **P1** x
EOF
mk_prd "$R" ancient 0 1
mkdir -p "$R/gspec/features"
cat > "$R/gspec/features/ancient.plan.md" <<'EOF'
---
spec-version: v1
feature: ancient
---
- [ ] **T1** **P1** x
EOF
out="$("$ADAPTER" plans "$R")"
check 'the 3.x layout is labelled'      'newone	gspec/features/newone/tasks.md	3.x' "$out"
check 'the 2.x layout is labelled'      'oldone	gspec/tasks/oldone.md	2.x' "$out"
check 'the pre-2.0 layout is labelled'  'ancient	gspec/features/ancient.plan.md	pre-2.0' "$out"
n="$(printf '%s\n' "$out" | grep -c .)"
[ "$n" = "3" ] && ok 'one row per plan file' || bad 'one row per plan file' "got $n: $out"
# Sorted by slug, so a report reads stably run to run rather than in glob order.
[ "$(printf '%s\n' "$out" | head -1 | cut -f1)" = "ancient" ] \
  && ok 'sorted by slug' || bad 'sorted by slug' "$out"

# The task-line counts are the columns that separate a FINISHED plan from an
# UNREADABLE one. Both yield zero packets, and conflating them made `verify`
# report a failed migration over this plugin's OWN fully-checked backlog --
# 5 relocated plans, 66 task lines, every one checked, called a parse failure.
check 'recognised + unchecked counts' 'newone	gspec/features/newone/tasks.md	3.x	1	1' "$out"

# A plan whose "tasks" are prose bullets parses to nothing: tasks=0 is the real
# unreadable signal.
mkdir -p "$R/gspec/features/prosey"
printf -- '---\nspec-version: v2\n---\n- [ ] **P0**: x\n' > "$R/gspec/features/prosey/prd.md"
printf -- '---\nspec-version: v2\nfeature: prosey\n---\n## Plan\n- do a thing\n- do another\n' > "$R/gspec/features/prosey/tasks.md"
# ...against one where every task IS recognised and every one is checked.
mkdir -p "$R/gspec/features/donefeat"
printf -- '---\nspec-version: v2\n---\n- [x] **P0**: x\n' > "$R/gspec/features/donefeat/prd.md"
printf -- '---\nspec-version: v2\nfeature: donefeat\n---\n## Plan\n- [x] **T1** **P0** a\n- [x] **T2** **P0** b\n' > "$R/gspec/features/donefeat/tasks.md"
out="$("$ADAPTER" plans "$R")"
check 'an unreadable plan reads 0 task lines' 'prosey	gspec/features/prosey/tasks.md	3.x	0	0' "$out"
check 'a finished plan reads them, 0 unchecked' 'donefeat	gspec/features/donefeat/tasks.md	3.x	2	0' "$out"
# The legacy shapes must be COUNTED, not just resolved -- the count has to use
# the same pattern `nodes` does or it lies about what the backlog can read.
check 'a pre-2.0 shape-A plan is counted too' 'ancient	gspec/features/ancient.plan.md	pre-2.0	1	1' "$out"

# gspec is OPTIONAL (D4): no gspec project means no output and a clean exit, not
# an error -- migrate.sh calls this unconditionally on any repo.
R="$TMPROOT/census-none"; mkdir -p "$R"
out="$("$ADAPTER" plans "$R")"; rc=$?
[ -z "$out" ] && ok 'no gspec project prints nothing' || bad 'no gspec project prints nothing' "got: $out"
[ "$rc" -eq 0 ] && ok 'and exits 0 (gspec is optional)' || bad 'plans exit 0 without gspec' "rc=$rc"

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
printf '\n== handoff: task text, file scope shared with nodes, covers capabilities ==\n'
# (thin-loop-driver T2 / ADR 0020 D2 amendment)
R="$TMPROOT/handoff"; mkdir -p "$R/gspec/features/hoff"
cat > "$R/gspec/features/hoff/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: hoff

## Capabilities

- [ ] **P0**: First capability text
  - first criterion, one line
  - second criterion wraps
    onto a second physical
    line, verbatim
- [ ] **P1**: Second capability text
  - only criterion here

## Dependencies

- none
EOF
mk_plan_v2 "$R" hoff <<'EOF'
- [ ] **T1** **P0** do the first thing
  - deps: —
  - covers: First capability text · Second capability text
  - files: [src/a.ts, src/b.ts]
- [x] **T2** **P1** already done thing
  - deps: T1
  - covers: A quote nothing matches
  - files: [should/not/appear.ts]
EOF

out="$("$ADAPTER" handoff hoff-t1 "$R")"
check 'handoff prints the task text'                'TEXT=do the first thing' "$out"
check 'handoff resolves file scope via nodes (plan files: wins)' 'FILES=src/a.ts|src/b.ts' "$out"
check 'handoff prints the first covers capability'  'COVERS=First capability text' "$out"
check 'a multi-capability covers is split on the middle dot' 'COVERS=Second capability text' "$out"
check 'a single-line criterion prints verbatim'     'first criterion, one line' "$out"
check 'a multi-line wrapped criterion stays whole (line 1)' 'second criterion wraps' "$out"
check 'a multi-line wrapped criterion stays whole (line 2)' 'onto a second physical'  "$out"
check 'a multi-line wrapped criterion stays whole (line 3)' 'line, verbatim'          "$out"
check 'handoff prints the PRD path'                 'PRD=gspec/features/hoff/prd.md' "$out"
check 'ARCH= is printed even when arch.md is absent' 'ARCH=absent'                    "$out"

# The capability-block boundary: this is exactly what removing `if (found)
# exit` in `_prd_capability` would break (`found` is sticky, so without that
# `exit`, `inblock` would stay set across the non-matching "Second capability
# text" header and its own criterion would bleed into the first block).
block1="$(printf '%s\n' "$out" | awk '/^COVERS=First capability text$/{f=1; next} /^COVERS=Second capability text$/{exit} f')"
refute 'the first COVERS block does not leak the second capability'"'"'s criterion' \
  'only criterion here' "$block1"

out="$("$ADAPTER" handoff 'hoff#T1' "$R")"
check 'the canonical <feature>#T<n> form resolves identically' 'PACKET=hoff-t1' "$out"

touch "$R/gspec/features/hoff/arch.md"
out="$("$ADAPTER" handoff hoff-t1 "$R")"
check 'ARCH= carries the real path once arch.md exists' 'ARCH=gspec/features/hoff/arch.md' "$out"

printf '\n== handoff: a checked task still prints, and a bad covers quote is reported ==\n'
out="$("$ADAPTER" handoff hoff-t2 "$R")"
check 'a checked task still prints (handoff is a read)'   'CHECKED=1' "$out"
check 'and its task text too'                             'TEXT=already done thing' "$out"
filesline="$(printf '%s\n' "$out" | grep '^FILES=')"
# T2 DOES declare a files: line (should/not/appear.ts) -- this is the point:
# a checked task's FILES is forced empty regardless, never merely "empty
# because nothing was configured" (which the earlier fixture, with no files:
# line at all on T2, could not tell apart from this).
[ "$filesline" = 'FILES=' ] && ok 'a checked task always carries empty FILES even when the plan has a files: line for it' \
  || bad 'checked task FILES should be empty' "got: $filesline"
refute 'the checked task'"'"'s own files: line never leaks into FILES=' 'should/not/appear.ts' "$out"
check 'and says why, so empty does not read as "forgot to scope it"' 'NOTE=' "$out"
check 'a covers quote matching no capability is reported, never guessed' \
  'UNMATCHED=A quote nothing matches' "$out"
refute 'an unmatched quote never becomes a COVERS= block' 'COVERS=A quote nothing matches' "$out"

printf '\n== handoff: a multi-line task body is captured whole, metadata excluded ==\n'
# The real trigger (thin-loop-driver T8/T9/T11/T14/T15): nested nubblets, a
# wrapped continuation line, a blank separator and a trailing paragraph, with
# deps:/covers:/arch:/files: metadata lines that must NOT appear as body text.
R5="$TMPROOT/handoff-multiline"; mkdir -p "$R5/gspec/features/multi"
cat > "$R5/gspec/features/multi/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: multi

## Capabilities

- [ ] **P0**: Multi-line tasks keep their whole body
  - the body survives

## Dependencies
EOF
mk_plan_v2 "$R5" multi <<'EOF'
- [ ] **T1** **P0** Add two writers, first line only:
  - first nested bullet wraps
    onto a second physical line as continuation
  - second nested bullet, one line

  A trailing paragraph after a blank separator, at the same indent as the bullets.
  - deps: —
  - covers: Multi-line tasks keep their whole body
  - arch: —
  - files: src/a.ts, src/b.ts
EOF
out="$("$ADAPTER" handoff multi-t1 "$R5")"
check 'TEXT= carries only the header'"'"'s own inline text'          'TEXT=Add two writers, first line only:' "$out"
check 'a nested bullet is captured'                             'first nested bullet wraps'                "$out"
check 'its wrapped continuation line is captured too'           'onto a second physical line as continuation' "$out"
check 'a second nested bullet is captured'                      'second nested bullet, one line'             "$out"
check 'a trailing paragraph after a blank line is captured'     'A trailing paragraph after a blank separator' "$out"
refute 'the deps: metadata line never leaks into the body'      '- deps:'    "$out"
refute 'the covers: metadata line never leaks into the body'    '- covers:'  "$out"
refute 'the arch: metadata line never leaks into the body'      '- arch:'    "$out"
refute 'the files: metadata line never leaks into the body'     '- files:'   "$out"
check 'the files: line is still consumed for FILES='            'FILES=src/a.ts|src/b.ts' "$out"

printf '\n== handoff: a markdown heading ends a task body (phase sections, trailing notes) ==\n'
R5h="$TMPROOT/handoff-headings"; mkdir -p "$R5h/gspec/features/multi"
cp "$R5/gspec/features/multi/prd.md" "$R5h/gspec/features/multi/prd.md"
mk_plan_v2 "$R5h" multi <<'EOF'
- [ ] **T1** **P0** First phase task
  - deps: —
  - covers: Multi-line tasks keep their whole body

## Phase 2

Phase two prose that belongs to no task.

- [ ] **T2** **P0** Second phase task
  body line of the second task
  - deps: T1
  - covers: Multi-line tasks keep their whole body

## Notes

Trailing notes prose after the last task.
EOF
out="$("$ADAPTER" handoff multi-t1 "$R5h")"
check  'a task before a heading still resolves'                 'TEXT=First phase task'   "$out"
refute 'the heading after a task is not captured as its body'   'Phase 2'                  "$out"
refute 'prose under that heading is not captured either'        'Phase two prose'          "$out"
out="$("$ADAPTER" handoff multi-t2 "$R5h")"
check  'a task after a heading still resolves'                  'TEXT=Second phase task'   "$out"
check  'its own body line is kept'                              'body line of the second task' "$out"
refute 'a trailing notes section is not captured as the last task body' 'Trailing notes prose' "$out"

printf '\n== handoff: a literal backslash in a covers quote is not corrupted (awk ENVIRON, not -v) ==\n'
R6="$TMPROOT/handoff-backslash"; mkdir -p "$R6/gspec/features/bs"
cat > "$R6/gspec/features/bs/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: bs

## Capabilities

- [ ] **P0**: Match \d literally, not a digit class
  - one criterion

## Dependencies
EOF
mk_plan_v2 "$R6" bs <<'EOF'
- [ ] **T1** **P0** backslash task
  - deps: —
  - covers: Match \d literally, not a digit class
EOF
out="$("$ADAPTER" handoff bs-t1 "$R6")"
check 'a literal backslash-d in a covers quote still matches verbatim' \
  'COVERS=Match \d literally, not a digit class' "$out"
refute 'and is never reported as unmatched' 'UNMATCHED=Match \d' "$out"
check 'its criterion still prints' 'one criterion' "$out"

printf '\n== handoff: a tab embedded in free text never shifts a field (no cut on a joined row) ==\n'
R7="$TMPROOT/handoff-tab"; mkdir -p "$R7/gspec/features/tabby"
{
  printf -- '---\nspec-version: v2\n---\n\n# Feature: tabby\n\n## Capabilities\n\n'
  printf -- '- [ ] **P0**: Cap\twith an embedded tab\n  - one criterion\n\n## Dependencies\n'
} > "$R7/gspec/features/tabby/prd.md"
{
  printf -- '---\nspec-version: v2\nfeature: tabby\n---\n\n# Plan: tabby\n\n## Plan\n\n'
  printf -- '- [ ] **T1** **P0** task text with a\ttab inside it\n'
  printf -- '  - deps: -\n'
  printf -- '  - covers: Cap\twith an embedded tab\n'
} > "$R7/gspec/features/tabby/tasks.md"
out="$("$ADAPTER" handoff tabby-t1 "$R7")"
expect_text="$(printf 'TEXT=task text with a\ttab inside it')"
expect_covers="$(printf 'COVERS=Cap\twith an embedded tab')"
check 'a tab inside the task text is preserved, not truncated' "$expect_text" "$out"
check 'a tab inside a covers quote still matches its capability' "$expect_covers" "$out"
check 'the criterion after the tabbed capability still prints' 'one criterion' "$out"

printf '\n== handoff: a task with no covers: prints COVERS=none, never silence ==\n'
cat > "$R5/gspec/features/multi/tasks.md" <<'EOF'
---
spec-version: v2
feature: multi
---

# Plan: multi

## Plan

- [ ] **T1** **P0** Add two writers, first line only:
  - first nested bullet wraps
    onto a second physical line as continuation
  - second nested bullet, one line

  A trailing paragraph after a blank separator, at the same indent as the bullets.
  - deps: —
  - covers: Multi-line tasks keep their whole body
  - arch: —
  - files: src/a.ts, src/b.ts
- [ ] **T2** **P1** a task that declares no covers at all
  - deps: —
EOF
out="$("$ADAPTER" handoff multi-t2 "$R5")"
check 'a task with no covers: prints COVERS=none' 'COVERS=none' "$out"
refute 'and never a bare UNMATCHED= with nothing to unmatch' 'UNMATCHED=' "$out"

printf '\n== handoff: a blank line inside a capability block does not end it early, and a stray top-level bullet is never absorbed ==\n'
cat > "$R5/gspec/features/multi/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: multi

## Capabilities

- [ ] **P0**: Multi-line tasks keep their whole body
  - the body survives

- [ ] **P1**: Cap with an interior blank line
  - first bullet

  - second bullet, after a blank line, still part of this capability

- [ ] **P2**: Cap with trailing garbage after it
  - only real bullet

- a stray top-level bullet that must never be absorbed
## Dependencies
EOF
cat >> "$R5/gspec/features/multi/tasks.md" <<'EOF'
- [ ] **T3** **P1** blank-line-continuation task
  - deps: —
  - covers: Cap with an interior blank line
- [ ] **T4** **P2** trailing-garbage task
  - deps: —
  - covers: Cap with trailing garbage after it
EOF
out="$("$ADAPTER" handoff multi-t3 "$R5")"
check 'a bullet before an interior blank line prints'  'first bullet' "$out"
check 'a bullet after an interior blank line still prints (blank does not end the block when more indented content follows)' \
  'second bullet, after a blank line, still part of this capability' "$out"

out="$("$ADAPTER" handoff multi-t4 "$R5")"
check 'the real bullet of a trailing-garbage capability prints' 'only real bullet' "$out"
refute 'a stray top-level bullet after the block is never pulled in' \
  'a stray top-level bullet that must never be absorbed' "$out"

printf '\n== handoff: the 2.x and pre-2.0 plan layouts ==\n'
# (3.x is covered above; this rounds out AC5's "all three layouts".)
R2="$TMPROOT/handoff-2x"; mkdir -p "$R2"
mk_prd "$R2" htwo 0 1              # generates "- [ ] **P1**: open capability 1\n  - criterion\n"
mk_plan "$R2" htwo <<'EOF'
- [ ] **T1** **P0** a 2.x task
  - deps: —
  - covers: open capability 1
EOF
out="$("$ADAPTER" handoff htwo-t1 "$R2")"
check '2.x layout: handoff resolves the flat PRD' 'PRD=gspec/features/htwo.md' "$out"
check '2.x layout: covers matches the capability'  'COVERS=open capability 1'   "$out"
check '2.x layout: its criterion prints'           'criterion'                 "$out"

R3="$TMPROOT/handoff-pre20"; mkdir -p "$R3/gspec/features"
mk_prd "$R3" hpre 0 1
cat > "$R3/gspec/features/hpre.plan.md" <<'EOF'
---
spec-version: v1
feature: hpre
---

# Plan: hpre

## Plan

- [ ] **T1** **P0** a pre-2.0 task
  - deps: —
  - covers: open capability 1
EOF
out="$("$ADAPTER" handoff hpre-t1 "$R3")"
check 'pre-2.0 layout: handoff resolves the flat PRD' 'PRD=gspec/features/hpre.md'   "$out"
check 'pre-2.0 layout: handoff reads the .plan.md file' 'COVERS=open capability 1'   "$out"

printf '\n== handoff: a non-gspec id prints unknown and never crashes ==\n'
R4="$TMPROOT/handoff-none"; mkdir -p "$R4"
out="$("$ADAPTER" handoff not-a-real-packet-t9 "$R4" 2>&1)"; rc=$?
check 'no gspec/ at all reads HANDOFF=unknown' 'HANDOFF=unknown' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0 (mirrors task-status, gspec is optional)' \
  || bad 'exit 0 with no gspec/' "rc=$rc"

out="$("$ADAPTER" handoff zzz-t1 "$R" 2>&1)"; rc=$?
check 'an id matching no feature slug also reads unknown' 'HANDOFF=unknown' "$out"
[ "$rc" -eq 0 ] && ok 'and also exits 0' || bad 'exit 0 on an unresolved id' "rc=$rc"

out="$("$ADAPTER" handoff hoff-t99 "$R" 2>&1)"; rc=$?
check 'a resolvable feature with no such task also reads unknown' 'HANDOFF=unknown' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0 too' || bad 'exit 0 on no-such-task' "rc=$rc"

out="$("$ADAPTER" handoff 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a missing packet id is a genuine usage error (non-zero)' \
  || bad 'missing packet id should be non-zero' "rc=$rc, out=$out"

out="$("$ADAPTER" handoff 'a/b#T1' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a slug with a path separator is refused, matching check-task/task-status' \
  || bad 'path separator refused' "rc=$rc, out=$out"
check 'and explains why' 'path separator' "$out"

# =============================================================================
# group (packet-bundling-t4). Every scenario below is run in BOTH layouts:
# mk_prd_v2/mk_plan_v2 (the 3.x feature-folder layout) first, then
# mk_prd/mk_plan (the flat 2.x layout) as a second, independent fixture --
# `group` shares `_nodes_for`'s layout resolution, but a case here is the
# only thing that actually exercises `group` itself against both.

printf '\n== group: a cap of 1 yields exactly the cursor; cap raised groups whole; cap truncates mid-run; a non-overlapping neighbour ends the group (feature-folder layout) ==\n'
R="$TMPROOT/group-a-v2"; mkdir -p "$R"
mk_prd_v2 "$R" grp-a 0 1
mk_plan_v2 "$R" grp-a <<'EOF'
- [ ] **T1** **P1** first task
  - deps: —
  - files: [src/a.ts]
- [ ] **T2** **P1** second task
  - deps: —
  - files: [src/a.ts]
- [ ] **T3** **P1** third task
  - deps: —
  - files: [src/a.ts]
- [ ] **T4** **P1** fourth task, different scope
  - deps: —
  - files: [src/z.ts]
EOF

out="$("$ADAPTER" group grp-a-t1 "$R")"
check 'default cap (1) is inert: GROUP names the cursor' 'GROUP=grp-a-t1' "$out"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'default cap: exactly one member' || bad 'default cap: exactly one member' "got $n: $out"
check 'default cap: the one member is the cursor, with its title'  "$(printf 'MEMBER=grp-a-t1\tfirst task')" "$out"
check 'default cap: FILES is the cursor'"'"'s own scope'           'FILES=src/a.ts' "$out"
check 'default cap: STOP=cap — the command arrives inert'          'STOP=cap' "$out"

out="$("$ADAPTER" group grp-a-t1 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "3" ] && ok 'cap raised above the run: the three same-scope tasks group whole' \
  || bad 'three overlapping tasks should group whole' "got $n members: $out"
check 'member 1' "$(printf 'MEMBER=grp-a-t1\tfirst task')"  "$out"
check 'member 2' "$(printf 'MEMBER=grp-a-t2\tsecond task')" "$out"
check 'member 3' "$(printf 'MEMBER=grp-a-t3\tthird task')"  "$out"
refute 'the fourth (non-overlapping) task never joins' 'MEMBER=grp-a-t4' "$out"
check 'FILES is still just the shared file — no duplicate entries from three members' 'FILES=src/a.ts' "$out"
check 'a non-overlapping neighbour ends the group: STOP=scope' 'STOP=scope' "$out"

out="$("$ADAPTER" group grp-a-t1 --cap 2 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "2" ] && ok 'a cap of 2 truncates mid-run at exactly two members' \
  || bad 'cap should truncate at 2' "got $n members: $out"
refute 'the third task, which would otherwise still qualify, is excluded by the cap' 'MEMBER=grp-a-t3' "$out"
check 'a cap truncating mid-run reports STOP=cap, not STOP=scope' 'STOP=cap' "$out"

out2="$("$ADAPTER" group 'grp-a#T1' "$R")"
check 'the canonical <feature>#T<n> form resolves identically to the packet-id form' \
  'GROUP=grp-a-t1' "$out2"

printf '\n== group: an empty-scope cursor and an empty-scope neighbour each run alone (feature-folder layout) ==\n'
R="$TMPROOT/group-b-v2"; mkdir -p "$R"
mk_prd_v2 "$R" grp-b 0 1
mk_plan_v2 "$R" grp-b <<'EOF'
- [ ] **T1** **P1** cursor with scope
  - deps: —
  - files: [src/x.ts]
- [ ] **T2** **P1** empty-scope neighbour
  - deps: —
- [ ] **T3** **P1** another task with scope
  - deps: —
  - files: [src/x.ts]
EOF

out="$("$ADAPTER" group grp-b-t1 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'an empty-scope neighbour cannot join: the group stops at just the cursor' \
  || bad 'empty-scope neighbour should end the group' "got $n members: $out"
check 'the excluded neighbour never appears as a member' 'MEMBER=grp-b-t1' "$out"
refute 'and T2 (empty scope) is not silently absorbed' 'MEMBER=grp-b-t2' "$out"
check 'STOP=scope: an empty scope overlaps nothing' 'STOP=scope' "$out"

out="$("$ADAPTER" group grp-b-t2 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'the SAME empty-scope task, run as its own cursor, also groups alone' \
  || bad 'empty-scope cursor should run alone' "got $n members: $out"
check 'the lone member is the empty-scope cursor itself' 'MEMBER=grp-b-t2' "$out"
filesline="$(printf '%s\n' "$out" | grep '^FILES=')"
[ "$filesline" = 'FILES=' ] && ok 'FILES is empty — the cursor itself declared no scope' \
  || bad 'FILES should be empty for an empty-scope cursor' "got: $filesline"
check 'STOP=scope: the empty union can never admit the next candidate either' 'STOP=scope' "$out"

printf '\n== group: a deps: dependency on an unchecked task outside the group excludes it (feature-folder layout) ==\n'
R="$TMPROOT/group-c-v2"; mkdir -p "$R"
mk_prd_v2 "$R" grp-c 0 1
mk_plan_v2 "$R" grp-c <<'EOF'
- [ ] **T1** **P1** cursor
  - deps: —
  - files: [src/c.ts]
- [ ] **T2** **P1** depends on an outside unchecked task
  - deps: T5
  - files: [src/c.ts]
- [ ] **T5** **P1** the outside dependency, still unchecked
  - deps: —
  - files: [src/c.ts]
EOF
out="$("$ADAPTER" group grp-c-t1 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'T2 is excluded: its dep T5 is neither in the group nor checked' \
  || bad 'unmet deps should exclude the candidate' "got $n members: $out"
refute 'T2 never joins' 'MEMBER=grp-c-t2' "$out"
refute 'T5 (never reached) never joins either' 'MEMBER=grp-c-t5' "$out"
check 'STOP=deps names the reason' 'STOP=deps' "$out"

printf '\n== group: a checked task between two members does not break consecutiveness (feature-folder layout) ==\n'
R="$TMPROOT/group-e-v2"; mkdir -p "$R"
mk_prd_v2 "$R" grp-e 0 1
mk_plan_v2 "$R" grp-e <<'EOF'
- [x] **T0** **P1** already done, before the cursor
  - deps: —
- [ ] **T1** **P1** cursor
  - deps: —
  - files: [src/e.ts]
- [x] **T2** **P1** checked task sitting between two members
  - deps: —
  - files: [src/should-not-appear.ts]
- [ ] **T3** **P1** third member, depends on the checked T2 and the earlier T1
  - deps: T1, T2
  - files: [src/e.ts]
EOF
out="$("$ADAPTER" group grp-e-t1 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "2" ] && ok 'the checked T2 between T1 and T3 does not break the run: both T1 and T3 join' \
  || bad 'a checked task between two members should not break consecutiveness' "got $n members: $out"
check 'member 1 is the cursor' 'MEMBER=grp-e-t1' "$out"
check 'member 2 is the task on the far side of the checked one' 'MEMBER=grp-e-t3' "$out"
refute 'the checked task itself never appears as a member' 'MEMBER=grp-e-t2' "$out"
refute 'and its files: line never leaks into the union' 'should-not-appear' "$out"
check 'FILES is only the shared scope T1 and T3 actually declare' 'FILES=src/e.ts' "$out"
check 'T3'"'"'s dep on the already-checked T2 is satisfied, and its dep on T1 by T1 being earlier in the group -- STOP=end, ran out of tasks' \
  'STOP=end' "$out"

printf '\n== group: never crosses into the next feature (feature-folder layout) ==\n'
R="$TMPROOT/group-f-v2"; mkdir -p "$R"
mk_prd_v2 "$R" grp-f1 0 1
mk_plan_v2 "$R" grp-f1 <<'EOF'
- [ ] **T1** **P1** only task in f1
  - deps: —
  - files: [shared/scope.ts]
EOF
mk_prd_v2 "$R" grp-f2 0 1
mk_plan_v2 "$R" grp-f2 <<'EOF'
- [ ] **T1** **P1** only task in f2, deliberately the SAME file scope
  - deps: —
  - files: [shared/scope.ts]
EOF
out="$("$ADAPTER" group grp-f1-t1 --cap 10 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'a high cap and a matching scope in another feature still never pulls it in' \
  || bad 'group must never cross a feature boundary' "got $n members: $out"
refute 'the other feature'"'"'s task is never named as a member' 'MEMBER=grp-f2-t1' "$out"
check 'STOP=end: f1 has no more tasks of its own, cap or not' 'STOP=end' "$out"

printf '\n== group: HANDOFF=unknown refusal shape, and the one genuine usage errors (feature-folder layout) ==\n'
out="$("$ADAPTER" group not-a-real-packet-t9 "$TMPROOT/group-none" 2>&1)"; rc=$?
check 'no gspec/ at all reads HANDOFF=unknown, reusing handoff'"'"'s shape' 'HANDOFF=unknown' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0' || bad 'exit 0 with no gspec/' "rc=$rc"

out="$("$ADAPTER" group zzz-t1 "$R" 2>&1)"; rc=$?
check 'an id matching no feature slug also reads unknown' 'HANDOFF=unknown' "$out"
[ "$rc" -eq 0 ] && ok 'and also exits 0' || bad 'exit 0 on an unresolved id' "rc=$rc"

out="$("$ADAPTER" group grp-e-t0 "$R" 2>&1)"; rc=$?
check 'an already-checked cursor also reads unknown, never a lone/empty group' 'HANDOFF=unknown' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0 too' || bad 'exit 0 on a checked cursor' "rc=$rc"

out="$("$ADAPTER" group grp-e-t99 "$R" 2>&1)"; rc=$?
check 'a resolvable feature with no such task also reads unknown' 'HANDOFF=unknown' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0' || bad 'exit 0 on no-such-task' "rc=$rc"

out="$("$ADAPTER" group 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a missing packet id is a genuine usage error (non-zero)' \
  || bad 'missing packet id should be non-zero' "rc=$rc, out=$out"

out="$("$ADAPTER" group 'a/b#T1' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a slug with a path separator is refused, matching handoff/check-task/task-status' \
  || bad 'path separator refused' "rc=$rc, out=$out"
check 'and explains why' 'path separator' "$out"

out="$("$ADAPTER" group grp-e-t1 --cap abc "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a non-numeric --cap is a usage error' \
  || bad 'non-numeric --cap should be non-zero' "rc=$rc, out=$out"

out="$("$ADAPTER" group grp-e-t1 --cap 0 "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a --cap of 0 is a usage error' \
  || bad '--cap 0 should be non-zero' "rc=$rc, out=$out"

# --- the same eight scenarios, in the flat 2.x layout (mk_prd/mk_plan) -------

printf '\n== group: a cap of 1 yields exactly the cursor; cap raised groups whole; cap truncates mid-run; a non-overlapping neighbour ends the group (flat layout) ==\n'
R="$TMPROOT/group-a-flat"; mkdir -p "$R"
mk_prd "$R" grp-a-flat 0 1
mk_plan "$R" grp-a-flat <<'EOF'
- [ ] **T1** **P1** first task
  - deps: —
  - files: [src/a.ts]
- [ ] **T2** **P1** second task
  - deps: —
  - files: [src/a.ts]
- [ ] **T3** **P1** third task
  - deps: —
  - files: [src/a.ts]
- [ ] **T4** **P1** fourth task, different scope
  - deps: —
  - files: [src/z.ts]
EOF

out="$("$ADAPTER" group grp-a-flat-t1 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'flat layout: default cap (1) is inert — exactly one member' \
  || bad 'flat layout: default cap should yield one member' "got $n: $out"
check 'flat layout: STOP=cap' 'STOP=cap' "$out"

out="$("$ADAPTER" group grp-a-flat-t1 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "3" ] && ok 'flat layout: three overlapping tasks group whole' \
  || bad 'flat layout: three overlapping tasks should group whole' "got $n members: $out"
refute 'flat layout: the fourth, non-overlapping task never joins' 'MEMBER=grp-a-flat-t4' "$out"
check 'flat layout: a non-overlapping neighbour ends the group with STOP=scope' 'STOP=scope' "$out"

out="$("$ADAPTER" group grp-a-flat-t1 --cap 2 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "2" ] && ok 'flat layout: a cap of 2 truncates mid-run' \
  || bad 'flat layout: cap should truncate at 2' "got $n members: $out"
check 'flat layout: a cap truncating mid-run reports STOP=cap' 'STOP=cap' "$out"

printf '\n== group: an empty-scope cursor and an empty-scope neighbour each run alone (flat layout) ==\n'
R="$TMPROOT/group-b-flat"; mkdir -p "$R"
mk_prd "$R" grp-b-flat 0 1
mk_plan "$R" grp-b-flat <<'EOF'
- [ ] **T1** **P1** cursor with scope
  - deps: —
  - files: [src/x.ts]
- [ ] **T2** **P1** empty-scope neighbour
  - deps: —
- [ ] **T3** **P1** another task with scope
  - deps: —
  - files: [src/x.ts]
EOF
out="$("$ADAPTER" group grp-b-flat-t1 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'flat layout: an empty-scope neighbour ends the group' \
  || bad 'flat layout: empty-scope neighbour should end the group' "got $n members: $out"
check 'flat layout: STOP=scope' 'STOP=scope' "$out"

out="$("$ADAPTER" group grp-b-flat-t2 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'flat layout: the same empty-scope task, as its own cursor, also runs alone' \
  || bad 'flat layout: empty-scope cursor should run alone' "got $n members: $out"
filesline="$(printf '%s\n' "$out" | grep '^FILES=')"
[ "$filesline" = 'FILES=' ] && ok 'flat layout: FILES is empty for the empty-scope cursor' \
  || bad 'flat layout: FILES should be empty' "got: $filesline"

printf '\n== group: a deps: dependency on an unchecked task outside the group excludes it (flat layout) ==\n'
R="$TMPROOT/group-c-flat"; mkdir -p "$R"
mk_prd "$R" grp-c-flat 0 1
mk_plan "$R" grp-c-flat <<'EOF'
- [ ] **T1** **P1** cursor
  - deps: —
  - files: [src/c.ts]
- [ ] **T2** **P1** depends on an outside unchecked task
  - deps: T5
  - files: [src/c.ts]
- [ ] **T5** **P1** the outside dependency, still unchecked
  - deps: —
  - files: [src/c.ts]
EOF
out="$("$ADAPTER" group grp-c-flat-t1 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'flat layout: an unmet dep excludes the candidate' \
  || bad 'flat layout: unmet deps should exclude the candidate' "got $n members: $out"
check 'flat layout: STOP=deps' 'STOP=deps' "$out"

printf '\n== group: a checked task between two members does not break consecutiveness (flat layout) ==\n'
R="$TMPROOT/group-e-flat"; mkdir -p "$R"
mk_prd "$R" grp-e-flat 0 1
mk_plan "$R" grp-e-flat <<'EOF'
- [x] **T0** **P1** already done, before the cursor
  - deps: —
- [ ] **T1** **P1** cursor
  - deps: —
  - files: [src/e.ts]
- [x] **T2** **P1** checked task sitting between two members
  - deps: —
  - files: [src/should-not-appear.ts]
- [ ] **T3** **P1** third member, depends on the checked T2 and the earlier T1
  - deps: T1, T2
  - files: [src/e.ts]
EOF
out="$("$ADAPTER" group grp-e-flat-t1 --cap 5 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "2" ] && ok 'flat layout: a checked task between two members does not break the run' \
  || bad 'flat layout: checked task should not break consecutiveness' "got $n members: $out"
refute 'flat layout: the checked task itself never appears as a member' 'MEMBER=grp-e-flat-t2' "$out"
check 'flat layout: STOP=end' 'STOP=end' "$out"

printf '\n== group: never crosses into the next feature (flat layout) ==\n'
R="$TMPROOT/group-f-flat"; mkdir -p "$R"
mk_prd "$R" grp-f1-flat 0 1
mk_plan "$R" grp-f1-flat <<'EOF'
- [ ] **T1** **P1** only task in f1
  - deps: —
  - files: [shared/scope.ts]
EOF
mk_prd "$R" grp-f2-flat 0 1
mk_plan "$R" grp-f2-flat <<'EOF'
- [ ] **T1** **P1** only task in f2, deliberately the SAME file scope
  - deps: —
  - files: [shared/scope.ts]
EOF
out="$("$ADAPTER" group grp-f1-flat-t1 --cap 10 "$R")"
n="$(printf '%s\n' "$out" | grep -c '^MEMBER=')"
[ "$n" = "1" ] && ok 'flat layout: a high cap never pulls in the matching-scope task of another feature' \
  || bad 'flat layout: group must never cross a feature boundary' "got $n members: $out"
refute 'flat layout: the other feature'"'"'s task is never a member' 'MEMBER=grp-f2-flat-t1' "$out"
check 'flat layout: STOP=end' 'STOP=end' "$out"

# =============================================================================
# handoff bundling (packet-bundling-t5). `handoff` accepts a comma-joined
# packet-id list on top of the single-id path exercised above.

printf '\n== handoff bundle: three ids, in PLAN order, blocks delimited, criteria intact, union scope correct ==\n'
R="$TMPROOT/handoff-bundle"; mkdir -p "$R/gspec/features/bun"
cat > "$R/gspec/features/bun/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: bun

## Capabilities

- [ ] **P0**: First capability
  - first criterion
- [ ] **P1**: Second capability
  - second criterion
- [ ] **P2**: Third capability
  - third criterion

## Dependencies
EOF
mk_plan_v2 "$R" bun <<'EOF'
- [ ] **T1** **P0** first bundle task
  - deps: —
  - covers: First capability
  - files: [src/a.ts]
- [ ] **T2** **P1** second bundle task
  - deps: —
  - covers: Second capability
  - files: [src/a.ts, src/b.ts]
- [ ] **T3** **P2** third bundle task
  - deps: —
  - covers: Third capability
  - files: [src/c.ts]
EOF

# Given SCRAMBLED (not plan order) so the test actually exercises reordering,
# not just an input list that happened to already be sorted.
out="$("$ADAPTER" handoff bun-t3,bun-t1,bun-t2 "$R")"
check 'BUNDLE= lists every member' 'BUNDLE=bun-t1,bun-t2,bun-t3' "$out"
check 'BUNDLE_FILES= is the union, first-seen order, through the same precedence group uses' \
  'BUNDLE_FILES=src/a.ts|src/b.ts|src/c.ts' "$out"

pkts="$(printf '%s\n' "$out" | grep '^PACKET=')"
expected_pkts="$(printf 'PACKET=bun-t1\nPACKET=bun-t2\nPACKET=bun-t3')"
[ "$pkts" = "$expected_pkts" ] && ok 'every member'"'"'s block is present, in PLAN order regardless of the order given' \
  || bad 'blocks should appear in plan order bun-t1, bun-t2, bun-t3' "got: $pkts"

filelines="$(printf '%s\n' "$out" | grep '^FILES=')"
expected_filelines="$(printf 'FILES=src/a.ts\nFILES=src/a.ts|src/b.ts\nFILES=src/c.ts')"
[ "$filelines" = "$expected_filelines" ] && ok 'each member'"'"'s own FILES= is correct and in plan order' \
  || bad 'per-member FILES=' "expected:
$expected_filelines
got:
$filelines"

check "member 1's text"  'TEXT=first bundle task'  "$out"
check "member 2's text"  'TEXT=second bundle task' "$out"
check "member 3's text"  'TEXT=third bundle task'  "$out"

# Block delimiting: one member's criterion must never bleed into another's.
block1="$(printf '%s\n' "$out" | awk '/^PACKET=bun-t1$/{f=1} /^PACKET=bun-t2$/{exit} f')"
check  'block 1 carries its own criterion'                 'first criterion'  "$block1"
refute 'block 1 does not leak block 2'"'"'s criterion'     'second criterion' "$block1"
refute 'block 1 does not leak block 3'"'"'s criterion'     'third criterion'  "$block1"

block2="$(printf '%s\n' "$out" | awk '/^PACKET=bun-t2$/{f=1} /^PACKET=bun-t3$/{exit} f')"
check  'block 2 carries its own criterion'                 'second criterion' "$block2"
refute 'block 2 does not leak block 1'"'"'s criterion'     'first criterion'  "$block2"
refute 'block 2 does not leak block 3'"'"'s criterion'     'third criterion'  "$block2"

block3="$(printf '%s\n' "$out" | awk '/^PACKET=bun-t3$/{f=1} f')"
check  'block 3 carries its own criterion'                 'third criterion'  "$block3"
refute 'block 3 does not leak block 1'"'"'s criterion'     'first criterion'  "$block3"
refute 'block 3 does not leak block 2'"'"'s criterion'     'second criterion' "$block3"

n="$(printf '%s\n' "$out" | grep -c '^PACKET=')"
[ "$n" = "3" ] && ok 'exactly three blocks, one per member' || bad 'exactly three blocks' "got $n: $out"

# The canonical <feature>#T<n> form resolves identically inside a bundle too.
out2="$("$ADAPTER" handoff 'bun#T1,bun-t2' "$R")"
check 'a mixed canonical/packet-id member list still resolves' 'BUNDLE=bun-t1,bun-t2' "$out2"

printf '\n== handoff bundle: a single id (no comma) is byte-identical to today, with no BUNDLE= header ==\n'
R="$TMPROOT/handoff-bundle-solo"; mkdir -p "$R/gspec/features/solo"
cat > "$R/gspec/features/solo/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: solo

## Capabilities

- [ ] **P0**: Only capability
  - the only criterion

## Dependencies
EOF
mk_plan_v2 "$R" solo <<'EOF'
- [ ] **T1** **P0** the only task
  - deps: —
  - covers: Only capability
  - files: [src/solo.ts]
EOF
expected="$(printf 'PACKET=solo-t1\nFEATURE=solo\nID=T1\nCHECKED=0\nTEXT=the only task\nFILES=src/solo.ts\nCOVERS=Only capability\n    - the only criterion\nPRD=gspec/features/solo/prd.md\nARCH=absent')"
out="$("$ADAPTER" handoff solo-t1 "$R")"
[ "$out" = "$expected" ] && ok 'a single id'"'"'s output is byte-identical to the pre-bundling shape' \
  || bad 'single id output changed' "expected:
$expected
got:
$out"
refute 'no BUNDLE= header for a single id' 'BUNDLE=' "$out"
refute 'no BUNDLE_FILES= header for a single id' 'BUNDLE_FILES=' "$out"

printf '\n== handoff bundle: an unresolvable member refuses the WHOLE call, with no partial output ==\n'
Rbun="$TMPROOT/handoff-bundle"
out="$("$ADAPTER" handoff bun-t1,zzz-t1,bun-t2 "$Rbun" 2>&1)"; rc=$?
check 'names the offending member' 'zzz-t1' "$out"
check 'reuses the existing HANDOFF=unknown shape' 'HANDOFF=unknown' "$out"
refute 'no PACKET= line leaks from either resolvable member' 'PACKET=' "$out"
refute 'the good members never partially print either' 'bun-t1' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0, mirroring the single-id unresolved case' \
  || bad 'exit 0 on an unresolvable member' "rc=$rc"

printf '\n== handoff bundle: a two-feature list refuses -- grouping across features is out of scope ==\n'
R="$TMPROOT/handoff-bundle-2feat"; mkdir -p "$R/gspec/features/bunA" "$R/gspec/features/bunB"
cat > "$R/gspec/features/bunA/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: bunA

## Capabilities

- [ ] **P0**: A capability
  - a criterion

## Dependencies
EOF
mk_plan_v2 "$R" bunA <<'EOF'
- [ ] **T1** **P0** feature A task
  - deps: —
  - covers: A capability
EOF
cat > "$R/gspec/features/bunB/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: bunB

## Capabilities

- [ ] **P0**: B capability
  - b criterion

## Dependencies
EOF
mk_plan_v2 "$R" bunB <<'EOF'
- [ ] **T1** **P0** feature B task
  - deps: —
  - covers: B capability
EOF
out="$("$ADAPTER" handoff bunA-t1,bunB-t1 "$R" 2>&1)"; rc=$?
check 'reuses HANDOFF=unknown, naming the cross-feature member' 'HANDOFF=unknown' "$out"
check 'and explains why' 'grouping across features is out of scope' "$out"
refute 'no partial output from the first, resolvable member' 'PACKET=' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0' || bad 'exit 0 on a two-feature list' "rc=$rc"

printf '\n== handoff bundle: a member already routed hand-off-feature this run refuses the whole call ==\n'
R="$TMPROOT/handoff-bundle-hof"; mkdir -p "$R/gspec/features/hof"
cat > "$R/gspec/features/hof/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: hof

## Capabilities

- [ ] **P0**: First hof capability
  - one criterion
- [ ] **P1**: Second hof capability
  - another criterion

## Dependencies
EOF
mk_plan_v2 "$R" hof <<'EOF'
- [ ] **T1** **P0** first hof task
  - deps: —
  - covers: First hof capability
- [ ] **T2** **P1** second hof task, already handed to the operator
  - deps: —
  - covers: Second hof capability
EOF
mkdir -p "$R/.agents/loop/test-run-1"
printf "run_id: 'test-run-1'\n" > "$R/.agents/run-state.yaml"
printf '{"ts":"2026-09-18T01:00:00.000Z","packet":"hof-t2","token":"hand-off-feature","action":"discard-advance","status":"handed to operator"}\n' \
  > "$R/.agents/loop/test-run-1/routing.jsonl"
out="$("$ADAPTER" handoff hof-t1,hof-t2 "$R" 2>&1)"; rc=$?
check 'reuses runstate.sh'"'"'s own HANDOFF=refused shape' 'HANDOFF=refused' "$out"
check 'names the routing reason' 'REASON=hand-off-feature' "$out"
check 'names the offending member' 'PACKET=hof-t2' "$out"
refute 'no partial output from the earlier, unrouted member' 'PACKET=hof-t1' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0, gspec is still optional' || bad 'exit 0 on a hand-off-feature member' "rc=$rc"

# The clean member alone is unaffected -- the routing record is per packet id,
# never a blanket refusal of the whole feature.
out="$("$ADAPTER" handoff hof-t1 "$R")"
check 'the unrouted member alone still hands off normally' 'PACKET=hof-t1' "$out"

printf '\n== handoff bundle: no run-state, no run_id, or no routing.jsonl all fail SOFT -- never a reason to refuse ==\n'
R="$TMPROOT/handoff-bundle-nohof"; mkdir -p "$R/gspec/features/nohof"
cat > "$R/gspec/features/nohof/prd.md" <<'EOF'
---
spec-version: v2
---

# Feature: nohof

## Capabilities

- [ ] **P0**: A nohof capability
  - a criterion
- [ ] **P1**: Another nohof capability
  - another criterion

## Dependencies
EOF
mk_plan_v2 "$R" nohof <<'EOF'
- [ ] **T1** **P0** first nohof task
  - deps: —
  - covers: A nohof capability
- [ ] **T2** **P1** second nohof task
  - deps: —
  - covers: Another nohof capability
EOF
out="$("$ADAPTER" handoff nohof-t1,nohof-t2 "$R")"
check 'no .agents/run-state.yaml at all still bundles normally' 'BUNDLE=nohof-t1,nohof-t2' "$out"

mkdir -p "$R/.agents"
printf "schema: 3\n" > "$R/.agents/run-state.yaml"
out="$("$ADAPTER" handoff nohof-t1,nohof-t2 "$R")"
check 'a run-state.yaml with no run_id: line still bundles normally' 'BUNDLE=nohof-t1,nohof-t2' "$out"

printf "run_id: 'no-such-run'\n" > "$R/.agents/run-state.yaml"
out="$("$ADAPTER" handoff nohof-t1,nohof-t2 "$R")"
check 'a run_id with no matching .agents/loop/ directory still bundles normally' 'BUNDLE=nohof-t1,nohof-t2' "$out"

printf '\n== handoff bundle: a malformed comma list is a genuine usage error ==\n'
out="$("$ADAPTER" handoff ',bun-t1' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a leading comma is refused' || bad 'leading comma should be non-zero' "rc=$rc, out=$out"
out="$("$ADAPTER" handoff 'bun-t1,' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a trailing comma is refused' || bad 'trailing comma should be non-zero' "rc=$rc, out=$out"
out="$("$ADAPTER" handoff 'bun-t1,,bun-t2' "$R" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok 'a doubled comma is refused' || bad 'doubled comma should be non-zero' "rc=$rc, out=$out"

# =============================================================================
# capability-drift (completion-record-drift-t1). Output contract, fixed by
# gspec/features/completion-record-drift/tasks.md and binding on all five
# tasks in that plan:
#   DRIFT=<slug>\t<capability text>
#   UNJUDGEABLE=<class>\t<slug>\t<detail>
#   CAPABILITY_DRIFT=ok|attention drift=<n> unjudgeable=<n>
# T1's own scope for this file is exactly the two cases below (the
# two-capability fixture in the flat layout, plus the no-gspec/ exit-0 case)
# -- the three UNJUDGEABLE classes and the feature-folder layout are T2's,
# and the byte-identical detect-never-flip pin is T3's; adding those here
# too would duplicate work those tasks are chartered to do.
printf '\n== capability-drift: no gspec/ at all exits 0 with CAPABILITY_DRIFT=none ==\n'
R="$TMPROOT/capdrift-none"; mkdir -p "$R"
out="$("$ADAPTER" capability-drift "$R" 2>&1)"; rc=$?
check 'reads CAPABILITY_DRIFT=none' 'CAPABILITY_DRIFT=none' "$out"
check 'and explains why' 'NOTE=' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0' || bad 'exit 0 with no gspec/' "rc=$rc"

# =============================================================================
printf '\n== capability-drift: the two-capability fixture, flat layout (mk_prd/mk_plan) ==\n'
# One capability whose covering task is fully checked (DRIFT); one with an
# unchecked covering task (mid-flight, reported as neither drift nor
# unjudgeable). A per-feature test -- no unchecked task lines and no checked
# capabilities -- reports neither here, because the feature still has an
# unchecked task line (T3); this case fails if the detector is widened back
# to that per-feature shape.
R="$TMPROOT/capdrift-main"; mkdir -p "$R"
mk_prd "$R" capdrift-main 0 2   # "- [ ] **P1**: open capability 1/2\n  - criterion\n"
mk_plan "$R" capdrift-main <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'the fully-checked-covered capability is named present' \
  "$(printf 'DRIFT=capdrift-main\topen capability 1')" "$out"
refute 'the mid-flight capability is named absent' \
  'open capability 2' "$out"
check 'the run summary counts the one drift and nothing unjudgeable' \
  'CAPABILITY_DRIFT=attention drift=1 unjudgeable=0' "$out"

# =============================================================================
printf '\n== capability-drift: a feature with no plan is out of scope, not unjudgeable ==\n'
R="$TMPROOT/capdrift-noplan"; mkdir -p "$R"
mk_prd "$R" capdrift-noplan 0 1
out="$("$ADAPTER" capability-drift "$R" 2>&1)"; rc=$?
refute 'no drift for an undecomposed feature' 'capdrift-noplan' "$out"
check 'the run summary still prints a clean count' 'CAPABILITY_DRIFT=ok drift=0 unjudgeable=0' "$out"
[ "$rc" -eq 0 ] && ok 'and exits 0' || bad 'exit 0 with no plan file' "rc=$rc"

# =============================================================================
# completion-record-drift-t2: the three UNJUDGEABLE classes, plus running T1's
# two-capability drift fixture in the feature-folder layout too. Every case
# below asserts BOTH halves -- the expected UNJUDGEABLE= line, with its class
# and feature name, present, AND that feature absent from every DRIFT= line
# -- since either half alone would pass for the wrong reason: a detector that
# never emits UNJUDGEABLE= at all would still pass a check() for the line's
# absence-of-drift half, and a detector that reports everything unjudgeable
# would still pass a check() for the UNJUDGEABLE= half alone.
printf '\n== capability-drift: the two-capability fixture, feature-folder layout (mk_prd_v2/mk_plan_v2) ==\n'
# Identical to T1's flat-layout fixture above, run again through the v2
# builders -- a detector that reads only the pre-3.x flat layout would fail
# here rather than silently passing on the newer layout it never reads.
R="$TMPROOT/capdrift-main-v2"; mkdir -p "$R"
mk_prd_v2 "$R" capdrift-main-v2 0 2
mk_plan_v2 "$R" capdrift-main-v2 <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'feature-folder layout: the fully-checked-covered capability is named present' \
  "$(printf 'DRIFT=capdrift-main-v2\topen capability 1')" "$out"
refute 'feature-folder layout: the mid-flight capability is named absent' \
  'open capability 2' "$out"
check 'feature-folder layout: the run summary counts the one drift and nothing unjudgeable' \
  'CAPABILITY_DRIFT=attention drift=1 unjudgeable=0' "$out"

# =============================================================================
printf '\n== capability-drift: unmatched-quote reads unjudgeable, never drift (flat layout) ==\n'
# A checked task whose covers: quote matches no PRD capability at all. The
# adapter already refuses to guess at the nearest capability for an unmatched
# quote elsewhere (cmd_handoff's UNMATCHED=); reading one as drift here would
# turn that same guess back on.
R="$TMPROOT/cd-unmatched-flat"; mkdir -p "$R"
mk_prd "$R" cd-unmatched-flat 0 1
mk_plan "$R" cd-unmatched-flat <<'EOF'
- [x] **T1** a checked task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'flat layout: the unmatched quote is reported unjudgeable, with its feature name' \
  "$(printf 'UNJUDGEABLE=unmatched-quote\tcd-unmatched-flat\tdoes not match any capability')" "$out"
refute 'flat layout: the feature never appears in a DRIFT= line' 'DRIFT=cd-unmatched-flat' "$out"
check 'flat layout: nothing here reads as drift' 'CAPABILITY_DRIFT=attention drift=0 unjudgeable=2' "$out"

printf '\n== capability-drift: unmatched-quote reads unjudgeable, never drift (feature-folder layout) ==\n'
R="$TMPROOT/cd-unmatched-v2"; mkdir -p "$R"
mk_prd_v2 "$R" cd-unmatched-v2 0 1
mk_plan_v2 "$R" cd-unmatched-v2 <<'EOF'
- [x] **T1** a checked task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'feature-folder layout: the unmatched quote is reported unjudgeable, with its feature name' \
  "$(printf 'UNJUDGEABLE=unmatched-quote\tcd-unmatched-v2\tdoes not match any capability')" "$out"
refute 'feature-folder layout: the feature never appears in a DRIFT= line' 'DRIFT=cd-unmatched-v2' "$out"
check 'feature-folder layout: nothing here reads as drift' 'CAPABILITY_DRIFT=attention drift=0 unjudgeable=2' "$out"

# =============================================================================
printf '\n== capability-drift: uncovered-capability reads unjudgeable, never drift (flat layout) ==\n'
# A resolved plan exists, but no task's covers: references this capability at
# all -- no covering task means no positive evidence of delivery, and
# absence of evidence must never be read as drift.
R="$TMPROOT/cd-uncovered-flat"; mkdir -p "$R"
mk_prd "$R" cd-uncovered-flat 0 1
mk_plan "$R" cd-uncovered-flat <<'EOF'
- [ ] **T1** a task that covers nothing
  - deps: —
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'flat layout: the uncovered capability is reported unjudgeable, with its feature name' \
  "$(printf 'UNJUDGEABLE=uncovered-capability\tcd-uncovered-flat\topen capability 1')" "$out"
refute 'flat layout: the feature never appears in a DRIFT= line' 'DRIFT=cd-uncovered-flat' "$out"
check 'flat layout: nothing here reads as drift' 'CAPABILITY_DRIFT=attention drift=0 unjudgeable=1' "$out"

printf '\n== capability-drift: uncovered-capability reads unjudgeable, never drift (feature-folder layout) ==\n'
R="$TMPROOT/cd-uncovered-v2"; mkdir -p "$R"
mk_prd_v2 "$R" cd-uncovered-v2 0 1
mk_plan_v2 "$R" cd-uncovered-v2 <<'EOF'
- [ ] **T1** a task that covers nothing
  - deps: —
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'feature-folder layout: the uncovered capability is reported unjudgeable, with its feature name' \
  "$(printf 'UNJUDGEABLE=uncovered-capability\tcd-uncovered-v2\topen capability 1')" "$out"
refute 'feature-folder layout: the feature never appears in a DRIFT= line' 'DRIFT=cd-uncovered-v2' "$out"
check 'feature-folder layout: nothing here reads as drift' 'CAPABILITY_DRIFT=attention drift=0 unjudgeable=1' "$out"

# =============================================================================
# completion-record-drift-gaps-t6: the anchoring divergence between
# `_CAPABILITY_LINE_RE` (admits leading whitespace) and `_prd_capability`'s
# `^-`-anchored quote matcher (column 0 only), recorded rather than aligned
# (see both patterns' comments in gspec-backlog.sh). An indented but
# otherwise canonical capability line is enumerated by `_prd_capabilities`
# (which drives this walk) and declined by `_prd_capability` (which every
# `covers:` quote is checked against): the quote never registers a MATCH, so
# the capability reads `uncovered-capability` and its covering task's quote
# reads `unmatched-quote` -- never `DRIFT=`, whichever way the covering task
# is checked. Two variations of the SAME indented PRD line pin the safe
# direction both ways: covering task checked (would be DRIFT if the anchors
# agreed) and unchecked (would be neither drift nor unjudgeable if the
# anchors agreed) -- both read identically here, because the quote never
# matches regardless of the task's checked state.
printf '\n== capability-drift: an indented capability line never drifts -- the anchor divergence stands (covering task checked) ==\n'
R="$TMPROOT/cd-indented-checked-flat"; mkdir -p "$R/gspec/features"
{ printf -- '---\nspec-version: v1\n---\n\n# Feature: cd-indented-checked-flat\n\n## Capabilities\n\n'
  printf -- '  - [ ] **P1**: indented capability\n    - criterion\n'
} > "$R/gspec/features/cd-indented-checked-flat.md"
mk_plan "$R" cd-indented-checked-flat <<'EOF'
- [x] **T1** finish the indented capability
  - deps: —
  - covers: indented capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'checked: the indented capability is reported uncovered, never matched' \
  "$(printf 'UNJUDGEABLE=uncovered-capability\tcd-indented-checked-flat\tindented capability')" "$out"
check 'checked: the covering quote is reported unmatched, never matched' \
  "$(printf 'UNJUDGEABLE=unmatched-quote\tcd-indented-checked-flat\tindented capability')" "$out"
refute 'checked: never a DRIFT= line, even though the covering task is checked' \
  'DRIFT=cd-indented-checked-flat' "$out"
check 'checked: the run summary counts both unjudgeable rows and no drift' \
  'CAPABILITY_DRIFT=attention drift=0 unjudgeable=2' "$out"

printf '\n== capability-drift: an indented capability line never drifts -- the anchor divergence stands (covering task unchecked) ==\n'
R="$TMPROOT/cd-indented-unchecked-flat"; mkdir -p "$R/gspec/features"
{ printf -- '---\nspec-version: v1\n---\n\n# Feature: cd-indented-unchecked-flat\n\n## Capabilities\n\n'
  printf -- '  - [ ] **P1**: indented capability\n    - criterion\n'
} > "$R/gspec/features/cd-indented-unchecked-flat.md"
mk_plan "$R" cd-indented-unchecked-flat <<'EOF'
- [ ] **T1** finish the indented capability
  - deps: —
  - covers: indented capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'unchecked: the indented capability is reported uncovered, never matched' \
  "$(printf 'UNJUDGEABLE=uncovered-capability\tcd-indented-unchecked-flat\tindented capability')" "$out"
check 'unchecked: the covering quote is reported unmatched, never matched' \
  "$(printf 'UNJUDGEABLE=unmatched-quote\tcd-indented-unchecked-flat\tindented capability')" "$out"
refute 'unchecked: never a DRIFT= line' 'DRIFT=cd-indented-unchecked-flat' "$out"
check 'unchecked: the run summary counts both unjudgeable rows and no drift' \
  'CAPABILITY_DRIFT=attention drift=0 unjudgeable=2' "$out"

# =============================================================================
printf '\n== capability-drift: unrecognized-capability reads unjudgeable, never drift (flat layout) ==\n'
# A legacy **P0 — text** capability line, appended by hand to a
# builder-written PRD -- the same shape _feature_done still counts toward
# completion, but _prd_capability's stricter **P<n>**: matcher declines it
# (it has no reliable verbatim text of its own to reproduce). It must read
# unjudgeable rather than resolve to either answer.
R="$TMPROOT/cd-legacy-flat"; mkdir -p "$R"
mk_prd "$R" cd-legacy-flat 0 0
cat >> "$R/gspec/features/cd-legacy-flat.md" <<'EOF'
- [ ] **P0 — legacy capability text**
  - criterion
EOF
mk_plan "$R" cd-legacy-flat <<'EOF'
- [ ] **T1** a task unrelated to the legacy capability
  - deps: —
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'flat layout: the legacy-shape capability is reported unjudgeable, with its feature name' \
  "$(printf 'UNJUDGEABLE=unrecognized-capability\t%s\t' "cd-legacy-flat")" "$out"
refute 'flat layout: the feature never appears in a DRIFT= line' 'DRIFT=cd-legacy-flat' "$out"
check 'flat layout: nothing here reads as drift' 'CAPABILITY_DRIFT=attention drift=0 unjudgeable=1' "$out"

printf '\n== capability-drift: unrecognized-capability reads unjudgeable, never drift (feature-folder layout) ==\n'
R="$TMPROOT/cd-legacy-v2"; mkdir -p "$R"
mk_prd_v2 "$R" cd-legacy-v2 0 0
cat >> "$R/gspec/features/cd-legacy-v2/prd.md" <<'EOF'
- [ ] **P0 — legacy capability text**
  - criterion
EOF
mk_plan_v2 "$R" cd-legacy-v2 <<'EOF'
- [ ] **T1** a task unrelated to the legacy capability
  - deps: —
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'feature-folder layout: the legacy-shape capability is reported unjudgeable, with its feature name' \
  "$(printf 'UNJUDGEABLE=unrecognized-capability\t%s\t' "cd-legacy-v2")" "$out"
refute 'feature-folder layout: the feature never appears in a DRIFT= line' 'DRIFT=cd-legacy-v2' "$out"
check 'feature-folder layout: nothing here reads as drift' 'CAPABILITY_DRIFT=attention drift=0 unjudgeable=1' "$out"

# =============================================================================
# completion-record-drift-t3: pin detect-never-flip mechanically. A `cksum`
# manifest of every PRD and plan file under this fixture's gspec/, taken
# before and compared byte-identical after running capability-drift over a
# drifted fixture -- so an auto-flip regression (the detector "fixing" the
# drift it finds) fails a checksum comparison rather than needing a reviewer
# to notice the write. Paired, in the same case, with the assertion that the
# run still reported the drift it was given: a no-op scan also leaves the
# manifest unchanged, so the checksum half alone would pass for a detector
# that does nothing at all. Both fixtures reuse T1's two-capability
# drift shape through the sweep's existing builders, run in both layouts it
# already exercises (T1's flat layout, T2's feature-folder layout) rather
# than a third builder that could drift from the ones every other case here
# uses.
printf '\n== capability-drift: detect-never-flip is pinned by checksum, flat layout ==\n'
R="$TMPROOT/cd-noflip-flat"; mkdir -p "$R"
mk_prd "$R" cd-noflip-flat 0 2
mk_plan "$R" cd-noflip-flat <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
MANIFEST_BEFORE="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
MANIFEST_AFTER="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
check 'flat layout: the drift it was given is still reported' \
  "$(printf 'DRIFT=cd-noflip-flat\topen capability 1')" "$out"
[ "$MANIFEST_BEFORE" = "$MANIFEST_AFTER" ] \
  && ok 'flat layout: every PRD and plan file under gspec/ is byte-identical after the scan' \
  || bad 'flat layout: every PRD and plan file under gspec/ is byte-identical after the scan' \
      "before: $MANIFEST_BEFORE
after:  $MANIFEST_AFTER"

printf '\n== capability-drift: detect-never-flip is pinned by checksum, feature-folder layout ==\n'
R="$TMPROOT/cd-noflip-v2"; mkdir -p "$R"
mk_prd_v2 "$R" cd-noflip-v2 0 2
mk_plan_v2 "$R" cd-noflip-v2 <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
MANIFEST_BEFORE="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
MANIFEST_AFTER="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
check 'feature-folder layout: the drift it was given is still reported' \
  "$(printf 'DRIFT=cd-noflip-v2\topen capability 1')" "$out"
[ "$MANIFEST_BEFORE" = "$MANIFEST_AFTER" ] \
  && ok 'feature-folder layout: every PRD and plan file under gspec/ is byte-identical after the scan' \
  || bad 'feature-folder layout: every PRD and plan file under gspec/ is byte-identical after the scan' \
      "before: $MANIFEST_BEFORE
after:  $MANIFEST_AFTER"

# =============================================================================
# completion-record-drift-gaps-t2: this feature's own pin for the corrected
# all-covering-tasks-checked construct in `_capability_drift_for` (T1,
# e4f68b2 -- `elif ! grep -qx '0' <<< "$bits"`, replacing a negated
# `printf | grep -qx` pipeline whose reader could exit before its writer
# finished under `set -euo pipefail`). Independent of `completion-record-
# drift`'s own two-capability fixture above: that fixture already carries
# this exact shape, but the defect it guards is rare enough by construction
# that a green run of either fixture is weak evidence on its own -- this
# case is `-gaps`'s own record, not a substitute for reading the construct.
# Both capabilities sit in the SAME run so the case cannot pass by the
# detector reporting nothing at all: one capability is covered by both a
# checked and an unchecked task (mid-flight -- must never read as drift),
# the other by only checked tasks (must read as drift).
printf '\n== capability-drift: a mid-flight capability never reads as drift alongside a genuinely finished one (flat layout) ==\n'
R="$TMPROOT/cd-gaps-t2-flat"; mkdir -p "$R"
mk_prd "$R" cd-gaps-t2-flat 0 2   # "- [ ] **P1**: open capability 1/2\n  - criterion\n"
mk_plan "$R" cd-gaps-t2-flat <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
refute 'flat layout: the mid-flight capability is absent by name from every DRIFT= (and every other) line' \
  'open capability 2' "$out"
check 'flat layout: the genuinely finished capability is named present in a DRIFT= line' \
  "$(printf 'DRIFT=cd-gaps-t2-flat\topen capability 1')" "$out"
check 'flat layout: the run summary counts exactly the one drift and no unjudgeable row for either capability' \
  'CAPABILITY_DRIFT=attention drift=1 unjudgeable=0' "$out"

printf '\n== capability-drift: a mid-flight capability never reads as drift alongside a genuinely finished one (feature-folder layout) ==\n'
R="$TMPROOT/cd-gaps-t2-v2"; mkdir -p "$R"
mk_prd_v2 "$R" cd-gaps-t2-v2 0 2
mk_plan_v2 "$R" cd-gaps-t2-v2 <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
refute 'feature-folder layout: the mid-flight capability is absent by name from every DRIFT= (and every other) line' \
  'open capability 2' "$out"
check 'feature-folder layout: the genuinely finished capability is named present in a DRIFT= line' \
  "$(printf 'DRIFT=cd-gaps-t2-v2\topen capability 1')" "$out"
check 'feature-folder layout: the run summary counts exactly the one drift and no unjudgeable row for either capability' \
  'CAPABILITY_DRIFT=attention drift=1 unjudgeable=0' "$out"

# =============================================================================
# completion-record-drift-gaps-t4: pin the completion-skip (T3's `continue` on
# `_feature_done`) against the SAME fixture in three variations, so the skip
# is shown to be pinned to the completion DERIVATION `_feature_done` computes
# rather than to the shorthand `covers:` labels that motivated it. All three
# share one plan: a single checked task whose `covers:` quote matches no
# capability at all -- the unmatched-quote shape from earlier in this file --
# and only the PRD's capability line varies:
#   done        the capability is checked -> _feature_done=1 -> the feature
#               is skipped entirely: no DRIFT=, no UNJUDGEABLE= of any class,
#               and the run's unjudgeable count is NOT raised by it.
#   unchecked   the capability is unchecked -> _feature_done=0 -> the feature
#               is scanned, and the unmatched-quote row reappears (alongside
#               uncovered-capability, since nothing covers the still-open
#               capability either).
#   unrecognized  the capability line is written in a shape
#               `_CAPABILITY_LINE_RE` does not match at all (no `- [ ]`/`- [x]`
#               checkbox) -> `_prd_capabilities` sees zero capability lines,
#               `_feature_done` totals 0 and reads NOT done (total>0 required)
#               -> the feature is scanned, and the unmatched-quote row
#               reappears with no capability-side row at all, since the
#               second loop in `_capability_drift_for` has nothing to iterate.
# If the skip were keyed to the plan's `covers:` labels rather than
# `_feature_done`'s own derivation, the "unrecognized" case would still be
# skipped (its plan's shorthand `covers:` label is identical to the "done"
# case's) -- it is not, because the PRD, not the plan, is what changed.
printf '\n== capability-drift: the completion-skip is pinned to the completion derivation, not the covers: labels (flat layout) ==\n'

R="$TMPROOT/cd-skip-done-flat"; mkdir -p "$R"
mk_prd "$R" cd-skip-done-flat 1 0   # "- [x] **P0**: done capability 1\n  - criterion\n"
mk_plan "$R" cd-skip-done-flat <<'EOF'
- [x] **T1** a checked task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
refute 'flat/done: a fully-checked feature never appears in a DRIFT= line' 'DRIFT=cd-skip-done-flat' "$out"
refute 'flat/done: a fully-checked feature never appears in an UNJUDGEABLE= line' 'cd-skip-done-flat' "$out"
check 'flat/done: skipped entirely -- the run summary counts nothing at all' \
  'CAPABILITY_DRIFT=ok drift=0 unjudgeable=0' "$out"

R="$TMPROOT/cd-skip-unchecked-flat"; mkdir -p "$R"
mk_prd "$R" cd-skip-unchecked-flat 0 1   # "- [ ] **P1**: open capability 1\n  - criterion\n"
mk_plan "$R" cd-skip-unchecked-flat <<'EOF'
- [x] **T1** a checked task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'flat/unchecked: the SAME plan yields the unmatched-quote row again once the capability is unchecked' \
  "$(printf 'UNJUDGEABLE=unmatched-quote\tcd-skip-unchecked-flat\tdoes not match any capability')" "$out"
refute 'flat/unchecked: still never a DRIFT= line' 'DRIFT=cd-skip-unchecked-flat' "$out"
check 'flat/unchecked: the run summary counts both unjudgeable rows -- the quote and the now-uncovered capability' \
  'CAPABILITY_DRIFT=attention drift=0 unjudgeable=2' "$out"

R="$TMPROOT/cd-skip-unrecognized-flat"; mkdir -p "$R"
mk_prd "$R" cd-skip-unrecognized-flat 0 0
cat >> "$R/gspec/features/cd-skip-unrecognized-flat.md" <<'EOF'
- capability one, written with no checkbox at all
  - criterion
EOF
mk_plan "$R" cd-skip-unrecognized-flat <<'EOF'
- [x] **T1** a checked task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'flat/unrecognized: the SAME unmatched-quote row reappears when the capability line is a shape the derivation never recognizes' \
  "$(printf 'UNJUDGEABLE=unmatched-quote\tcd-skip-unrecognized-flat\tdoes not match any capability')" "$out"
refute 'flat/unrecognized: still never a DRIFT= line' 'DRIFT=cd-skip-unrecognized-flat' "$out"
check 'flat/unrecognized: the run summary counts only the quote -- no capability-side row exists to count' \
  'CAPABILITY_DRIFT=attention drift=0 unjudgeable=1' "$out"

printf '\n== capability-drift: the completion-skip is pinned to the completion derivation, not the covers: labels (feature-folder layout) ==\n'

R="$TMPROOT/cd-skip-done-v2"; mkdir -p "$R"
mk_prd_v2 "$R" cd-skip-done-v2 1 0
mk_plan_v2 "$R" cd-skip-done-v2 <<'EOF'
- [x] **T1** a checked task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
refute 'feature-folder/done: a fully-checked feature never appears in a DRIFT= line' 'DRIFT=cd-skip-done-v2' "$out"
refute 'feature-folder/done: a fully-checked feature never appears in an UNJUDGEABLE= line' 'cd-skip-done-v2' "$out"
check 'feature-folder/done: skipped entirely -- the run summary counts nothing at all' \
  'CAPABILITY_DRIFT=ok drift=0 unjudgeable=0' "$out"

R="$TMPROOT/cd-skip-unchecked-v2"; mkdir -p "$R"
mk_prd_v2 "$R" cd-skip-unchecked-v2 0 1
mk_plan_v2 "$R" cd-skip-unchecked-v2 <<'EOF'
- [x] **T1** a checked task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'feature-folder/unchecked: the SAME plan yields the unmatched-quote row again once the capability is unchecked' \
  "$(printf 'UNJUDGEABLE=unmatched-quote\tcd-skip-unchecked-v2\tdoes not match any capability')" "$out"
refute 'feature-folder/unchecked: still never a DRIFT= line' 'DRIFT=cd-skip-unchecked-v2' "$out"
check 'feature-folder/unchecked: the run summary counts both unjudgeable rows -- the quote and the now-uncovered capability' \
  'CAPABILITY_DRIFT=attention drift=0 unjudgeable=2' "$out"

R="$TMPROOT/cd-skip-unrecognized-v2"; mkdir -p "$R"
mk_prd_v2 "$R" cd-skip-unrecognized-v2 0 0
cat >> "$R/gspec/features/cd-skip-unrecognized-v2/prd.md" <<'EOF'
- capability one, written with no checkbox at all
  - criterion
EOF
mk_plan_v2 "$R" cd-skip-unrecognized-v2 <<'EOF'
- [x] **T1** a checked task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
check 'feature-folder/unrecognized: the SAME unmatched-quote row reappears when the capability line is a shape the derivation never recognizes' \
  "$(printf 'UNJUDGEABLE=unmatched-quote\tcd-skip-unrecognized-v2\tdoes not match any capability')" "$out"
refute 'feature-folder/unrecognized: still never a DRIFT= line' 'DRIFT=cd-skip-unrecognized-v2' "$out"
check 'feature-folder/unrecognized: the run summary counts only the quote -- no capability-side row exists to count' \
  'CAPABILITY_DRIFT=attention drift=0 unjudgeable=1' "$out"

# =============================================================================
# complete-capabilities (capability-auto-complete-t1). WRITE. Output contract:
#   COMPLETE_CAPABILITIES=<ok|blocked|none> completed=<n>
#   COMPLETED=<slug>\t<capability text>   (n lines, PRD order)
#   FILE=<relprd>
#   REASON=...                            (blocked / none / unresolved)
# Flips a capability iff capability-drift would have printed DRIFT= for it;
# never an uncovered-capability or unrecognized-capability row; never unflips
# a checked one; an UNCHECKED task with an unmatched covers: quote holds
# EVERY flip in the feature, while the same quote on an already-CHECKED task
# holds nothing. `_capability_drift_for`/`cmd_capability_drift` are untouched
# by this -- verified below by re-running capability-drift over one of these
# same fixtures and checking its output against what its own sweep above
# already expects.
printf '\n== complete-capabilities: no gspec/ at all exits 0 with COMPLETE_CAPABILITIES=none (skip, D4) ==\n'
R="$TMPROOT/cc-none"; mkdir -p "$R"
out="$("$ADAPTER" complete-capabilities anything "$R" 2>&1)"; rc=$?
check 'reads COMPLETE_CAPABILITIES=none' 'COMPLETE_CAPABILITIES=none' "$out"
check 'and explains why' 'REASON=' "$out"
[ "$rc" -eq 0 ] && ok 'exits 0 with no gspec/' || bad 'exits 0 with no gspec/' "rc=$rc"

printf '\n== complete-capabilities: a malformed slug is a usage error, distinct from the skip (flat layout present) ==\n'
R="$TMPROOT/cc-malformed-flat"; mkdir -p "$R/gspec/features"
out="$("$ADAPTER" complete-capabilities '../evil' "$R" 2>&1)"; rc=$?
check 'refuses with a named reason' 'refusing a feature slug' "$out"
[ "$rc" -eq 1 ] && ok 'exits 1 on a malformed slug' || bad 'exits 1 on a malformed slug' "rc=$rc"

printf '\n== complete-capabilities: a malformed slug is a usage error, distinct from the skip (feature-folder layout present) ==\n'
R="$TMPROOT/cc-malformed-v2"; mkdir -p "$R/gspec/features"
out="$("$ADAPTER" complete-capabilities 'foo/bar' "$R" 2>&1)"; rc=$?
check 'refuses with a named reason' 'refusing a feature slug' "$out"
[ "$rc" -eq 1 ] && ok 'exits 1 on a malformed slug' || bad 'exits 1 on a malformed slug' "rc=$rc"

printf '\n== complete-capabilities: a malformed slug in a NON-gspec repo still reads as the skip, not the usage error ==\n'
R="$TMPROOT/cc-malformed-nogspec"; mkdir -p "$R"
out="$("$ADAPTER" complete-capabilities '../evil' "$R" 2>&1)"; rc=$?
check 'reads COMPLETE_CAPABILITIES=none, same as any other gspec-optional case' \
  'COMPLETE_CAPABILITIES=none' "$out"
[ "$rc" -eq 0 ] && ok 'exits 0 -- gspec-optional wins over the slug guard' \
  || bad 'exits 0 -- gspec-optional wins over the slug guard' "rc=$rc"

printf '\n== complete-capabilities: an unresolvable slug fails distinguishably from the skip (flat layout present) ==\n'
R="$TMPROOT/cc-unresolvable-flat"; mkdir -p "$R"
mk_prd "$R" someother-flat 0 1
out="$("$ADAPTER" complete-capabilities nosuchfeature "$R" 2>&1)"; rc=$?
check 'reads COMPLETE_CAPABILITIES=none' 'COMPLETE_CAPABILITIES=none' "$out"
check 'and explains why' 'REASON=' "$out"
[ "$rc" -eq 4 ] && ok 'exits 4, distinct from the skip exit 0' \
  || bad 'exits 4 on an unresolvable slug' "rc=$rc"

printf '\n== complete-capabilities: an unresolvable slug fails distinguishably from the skip (feature-folder layout present) ==\n'
R="$TMPROOT/cc-unresolvable-v2"; mkdir -p "$R"
mk_prd_v2 "$R" someother-v2 0 1
out="$("$ADAPTER" complete-capabilities nosuchfeature "$R" 2>&1)"; rc=$?
check 'reads COMPLETE_CAPABILITIES=none' 'COMPLETE_CAPABILITIES=none' "$out"
[ "$rc" -eq 4 ] && ok 'exits 4, distinct from the skip exit 0' \
  || bad 'exits 4 on an unresolvable slug' "rc=$rc"

# =============================================================================
printf '\n== complete-capabilities: the two-capability fixture, flat layout (mk_prd/mk_plan) ==\n'
# Same shape as capability-drift's own two-capability fixture: the capability
# whose covering tasks are all checked is flipped and named; the one with an
# unchecked covering task is untouched and absent.
R="$TMPROOT/cc-main-flat"; mkdir -p "$R"
mk_prd "$R" cc-main-flat 0 2   # "- [ ] **P1**: open capability 1/2\n  - criterion\n"
mk_plan "$R" cc-main-flat <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
out="$("$ADAPTER" complete-capabilities cc-main-flat "$R" 2>&1)"; rc=$?
check 'the fully-checked-covered capability is flipped and named' \
  "$(printf 'COMPLETED=cc-main-flat\topen capability 1')" "$out"
refute 'the mid-flight capability is never named' 'open capability 2' "$out"
check 'the run summary counts the one completion' \
  'COMPLETE_CAPABILITIES=ok completed=1' "$out"
[ "$rc" -eq 0 ] && ok 'exits 0' || bad 'exits 0' "rc=$rc"
prd_after="$(cat "$R/gspec/features/cc-main-flat.md")"
check 'the flipped capability now reads checked in the PRD' \
  '- [x] **P1**: open capability 1' "$prd_after"
check 'the mid-flight capability is still unchecked in the PRD' \
  '- [ ] **P1**: open capability 2' "$prd_after"

printf '\n== complete-capabilities: the two-capability fixture, feature-folder layout (mk_prd_v2/mk_plan_v2) ==\n'
R="$TMPROOT/cc-main-v2"; mkdir -p "$R"
mk_prd_v2 "$R" cc-main-v2 0 2
mk_plan_v2 "$R" cc-main-v2 <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
out="$("$ADAPTER" complete-capabilities cc-main-v2 "$R" 2>&1)"; rc=$?
check 'feature-folder layout: the fully-checked-covered capability is flipped and named' \
  "$(printf 'COMPLETED=cc-main-v2\topen capability 1')" "$out"
refute 'feature-folder layout: the mid-flight capability is never named' 'open capability 2' "$out"
check 'feature-folder layout: the run summary counts the one completion' \
  'COMPLETE_CAPABILITIES=ok completed=1' "$out"
[ "$rc" -eq 0 ] && ok 'feature-folder layout: exits 0' || bad 'feature-folder layout: exits 0' "rc=$rc"
prd_after="$(cat "$R/gspec/features/cc-main-v2/prd.md")"
check 'feature-folder layout: the flipped capability now reads checked in the PRD' \
  '- [x] **P1**: open capability 1' "$prd_after"
check 'feature-folder layout: the mid-flight capability is still unchecked in the PRD' \
  '- [ ] **P1**: open capability 2' "$prd_after"

# =============================================================================
printf '\n== complete-capabilities: an uncovered capability never flips ==\n'
R="$TMPROOT/cc-uncovered"; mkdir -p "$R"
mk_prd "$R" cc-uncovered 0 1
mk_plan "$R" cc-uncovered <<'EOF'
- [ ] **T1** a task that covers nothing
  - deps: —
EOF
MANIFEST_BEFORE="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
out="$("$ADAPTER" complete-capabilities cc-uncovered "$R" 2>&1)"; rc=$?
MANIFEST_AFTER="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
check 'flips nothing' 'COMPLETE_CAPABILITIES=ok completed=0' "$out"
refute 'names no completion' 'COMPLETED=' "$out"
[ "$rc" -eq 0 ] && ok 'exits 0' || bad 'exits 0' "rc=$rc"
[ "$MANIFEST_BEFORE" = "$MANIFEST_AFTER" ] \
  && ok 'the PRD is untouched' \
  || bad 'the PRD is untouched' "before: $MANIFEST_BEFORE
after:  $MANIFEST_AFTER"

printf '\n== complete-capabilities: an unrecognized-capability line never flips ==\n'
R="$TMPROOT/cc-unrecognized"; mkdir -p "$R"
mk_prd "$R" cc-unrecognized 0 0
cat >> "$R/gspec/features/cc-unrecognized.md" <<'EOF'
- [ ] **P0 — legacy capability text**
  - criterion
EOF
mk_plan "$R" cc-unrecognized <<'EOF'
- [x] **T1** a task unrelated to the legacy capability
  - deps: —
EOF
MANIFEST_BEFORE="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
out="$("$ADAPTER" complete-capabilities cc-unrecognized "$R" 2>&1)"; rc=$?
MANIFEST_AFTER="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
check 'flips nothing' 'COMPLETE_CAPABILITIES=ok completed=0' "$out"
refute 'names no completion' 'COMPLETED=' "$out"
[ "$rc" -eq 0 ] && ok 'exits 0' || bad 'exits 0' "rc=$rc"
[ "$MANIFEST_BEFORE" = "$MANIFEST_AFTER" ] \
  && ok 'the PRD is untouched' \
  || bad 'the PRD is untouched' "before: $MANIFEST_BEFORE
after:  $MANIFEST_AFTER"

# =============================================================================
printf '\n== complete-capabilities: an UNCHECKED task with an unmatched covers quote holds an otherwise-eligible flip ==\n'
# Capability A ("open capability 1") is fully covered by a checked task, which
# alone would flip it -- but a SECOND, unchecked task in the same feature has
# a covers: quote matching no capability at all. The flip rule holds every
# flip in the feature until that is fixed.
R="$TMPROOT/cc-hold"; mkdir -p "$R"
mk_prd "$R" cc-hold 0 1   # "- [ ] **P1**: open capability 1\n  - criterion\n"
mk_plan "$R" cc-hold <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [ ] **T2** an unchecked task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
MANIFEST_BEFORE="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
out="$("$ADAPTER" complete-capabilities cc-hold "$R" 2>&1)"; rc=$?
MANIFEST_AFTER="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
check 'flips nothing -- holds the whole feature' \
  'COMPLETE_CAPABILITIES=blocked completed=0' "$out"
refute 'names no completion' 'COMPLETED=' "$out"
[ "$rc" -eq 0 ] && ok 'still exits 0 -- a hold is reported, not a failure' \
  || bad 'exits 0 when held' "rc=$rc"
[ "$MANIFEST_BEFORE" = "$MANIFEST_AFTER" ] \
  && ok 'the PRD is untouched while the hold is in effect' \
  || bad 'the PRD is untouched while the hold is in effect' "before: $MANIFEST_BEFORE
after:  $MANIFEST_AFTER"

printf '\n== complete-capabilities: the SAME unmatched quote on an already-CHECKED task does not hold the flip (converse) ==\n'
R="$TMPROOT/cc-hold-converse"; mkdir -p "$R"
mk_prd "$R" cc-hold-converse 0 1
mk_plan "$R" cc-hold-converse <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** a CHECKED task whose covers quote matches nothing
  - deps: —
  - covers: does not match any capability
EOF
out="$("$ADAPTER" complete-capabilities cc-hold-converse "$R" 2>&1)"; rc=$?
check 'flips the capability normally -- a checked task with a bad quote holds nothing' \
  "$(printf 'COMPLETED=cc-hold-converse\topen capability 1')" "$out"
check 'the run summary counts the one completion' \
  'COMPLETE_CAPABILITIES=ok completed=1' "$out"
[ "$rc" -eq 0 ] && ok 'exits 0' || bad 'exits 0' "rc=$rc"

# =============================================================================
printf '\n== complete-capabilities: a checked capability with an unchecked covering task stays checked ==\n'
R="$TMPROOT/cc-stays-checked"; mkdir -p "$R"
mk_prd "$R" cc-stays-checked 1 0   # "- [x] **P0**: done capability 1\n  - criterion\n"
mk_plan "$R" cc-stays-checked <<'EOF'
- [ ] **T1** an unchecked task covering an already-done capability
  - deps: —
  - covers: done capability 1
EOF
MANIFEST_BEFORE="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
out="$("$ADAPTER" complete-capabilities cc-stays-checked "$R" 2>&1)"; rc=$?
MANIFEST_AFTER="$(find "$R/gspec" -type f -name '*.md' | sort | xargs cksum)"
check 'never unflips it, and never reports it' 'COMPLETE_CAPABILITIES=ok completed=0' "$out"
refute 'names no completion' 'COMPLETED=' "$out"
[ "$rc" -eq 0 ] && ok 'exits 0' || bad 'exits 0' "rc=$rc"
[ "$MANIFEST_BEFORE" = "$MANIFEST_AFTER" ] \
  && ok 'the PRD is untouched -- the checked box never moves' \
  || bad 'the PRD is untouched -- the checked box never moves' "before: $MANIFEST_BEFORE
after:  $MANIFEST_AFTER"

# =============================================================================
printf '\n== complete-capabilities: reverting the flipped line yields a PRD byte-identical to the original ==\n'
R="$TMPROOT/cc-revert"; mkdir -p "$R"
mk_prd "$R" cc-revert 0 2
mk_plan "$R" cc-revert <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
ORIGINAL_SUM="$(cksum < "$R/gspec/features/cc-revert.md")"
out="$("$ADAPTER" complete-capabilities cc-revert "$R" 2>&1)"
check 'flips the one eligible capability' 'COMPLETE_CAPABILITIES=ok completed=1' "$out"
sed -i.bak 's/- \[x\] \*\*P1\*\*: open capability 1/- [ ] **P1**: open capability 1/' \
  "$R/gspec/features/cc-revert.md" && rm -f "$R/gspec/features/cc-revert.md.bak"
REVERTED_SUM="$(cksum < "$R/gspec/features/cc-revert.md")"
[ "$ORIGINAL_SUM" = "$REVERTED_SUM" ] \
  && ok 'reverting the flipped checkbox restores the original file byte-for-byte' \
  || bad 'reverting the flipped checkbox restores the original file byte-for-byte' \
      "original: $ORIGINAL_SUM
reverted: $REVERTED_SUM"

# =============================================================================
# capability-auto-complete-t6: the same no-trailing-newline guard check-task
# carries (finding 3 above), on the capability write side. A PRD whose FINAL
# line is the flippable capability is the only shape that can gain a byte:
# awk's print always terminates the record it writes, so without the guard a
# one-character flip would silently append a newline to a file that had none —
# a whole-file diff on the next reader, and a revert that no longer restores
# the original bytes.
printf '\n== complete-capabilities: a PRD with no trailing newline gains no byte ==\n'
R="$TMPROOT/cc-nonl"; mkdir -p "$R/gspec/features"
# Hand-built rather than mk_prd: that builder ends every capability with a
# criterion sub-bullet AND a final newline, and this case needs the flippable
# capability to be the last line with nothing after it.
printf -- '---\nspec-version: v1\n---\n\n# Feature: cc-nonl\n\n## Capabilities\n\n- [x] **P0**: done capability 1\n  - criterion\n- [ ] **P1**: open capability 1' \
  > "$R/gspec/features/cc-nonl.md"
mk_plan "$R" cc-nonl <<'EOF'
- [x] **T1** finish the capability on the unterminated final line
  - deps: —
  - covers: open capability 1
EOF
ORIGINAL_SUM="$(cksum < "$R/gspec/features/cc-nonl.md")"
before_size="$(wc -c < "$R/gspec/features/cc-nonl.md")"
out="$("$ADAPTER" complete-capabilities cc-nonl "$R" 2>&1)"; rc=$?
check 'flips the capability on the unterminated final line' \
  'COMPLETE_CAPABILITIES=ok completed=1' "$out"
check 'and names it' "$(printf 'COMPLETED=cc-nonl\topen capability 1')" "$out"
[ "$rc" -eq 0 ] && ok 'exit 0 flipping a PRD with no trailing newline' \
  || bad 'exit 0 flipping a PRD with no trailing newline' "rc=$rc"
grep -qF -- '- [x] **P1**: open capability 1' "$R/gspec/features/cc-nonl.md" \
  && ok 'the flip itself landed on the final line' \
  || bad 'the flip itself landed on the final line' "$(cat "$R/gspec/features/cc-nonl.md")"
after_size="$(wc -c < "$R/gspec/features/cc-nonl.md")"
[ "$before_size" -eq "$after_size" ] \
  && ok 'the PRD byte count is unchanged apart from the flip' \
  || bad 'the PRD byte count is unchanged apart from the flip' "before=$before_size after=$after_size"
if [ -n "$(tail -c1 "$R/gspec/features/cc-nonl.md")" ]; then
  ok 'the PRD still lacks a trailing newline'
else
  bad 'the PRD still lacks a trailing newline' 'a trailing newline was added'
fi
# Reverted WITHOUT `sed -i`, unlike the case above: BSD/macOS sed appends a
# final newline to a file that had none, which would fail the checksum below
# for a reason that has nothing to do with the subcommand.
#
# The revert must change the checkbox character and NOTHING else, which means
# it has to reproduce whatever trailing state the subcommand actually left —
# NOT the state the fixture was written in. Measuring it here rather than
# assuming it is what keeps the checksum load-bearing: written the other way
# (strip every trailing newline unconditionally) the revert silently undoes a
# newline the subcommand wrongly added, and the comparison passes against a
# subcommand with no guard at all. Verified by deleting the guard: this form
# fails, the stripping form did not. Safe because the fixture has no trailing
# blank line, so the post-flip file ends in at most one newline.
had_nl=0; [ -z "$(tail -c1 "$R/gspec/features/cc-nonl.md")" ] && had_nl=1
reverted="$(sed 's/- \[x\] \*\*P1\*\*: open capability 1/- [ ] **P1**: open capability 1/' \
  "$R/gspec/features/cc-nonl.md")"
{ printf '%s' "$reverted"; if [ "$had_nl" -eq 1 ]; then printf '\n'; fi; } \
  > "$R/gspec/features/cc-nonl.md"
REVERTED_SUM="$(cksum < "$R/gspec/features/cc-nonl.md")"
[ "$ORIGINAL_SUM" = "$REVERTED_SUM" ] \
  && ok 'reverting the flipped checkbox restores the unterminated PRD byte-for-byte' \
  || bad 'reverting the flipped checkbox restores the unterminated PRD byte-for-byte' \
      "original: $ORIGINAL_SUM
reverted: $REVERTED_SUM"

# =============================================================================
printf '\n== complete-capabilities: a second run names nothing and is byte-identical to the first run result ==\n'
R="$TMPROOT/cc-noop-second"; mkdir -p "$R"
mk_prd "$R" cc-noop-second 0 2
mk_plan "$R" cc-noop-second <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
out1="$("$ADAPTER" complete-capabilities cc-noop-second "$R" 2>&1)"
check 'the first run flips the one eligible capability' \
  'COMPLETE_CAPABILITIES=ok completed=1' "$out1"
FIRST_SUM="$(cksum < "$R/gspec/features/cc-noop-second.md")"
out2="$("$ADAPTER" complete-capabilities cc-noop-second "$R" 2>&1)"
SECOND_SUM="$(cksum < "$R/gspec/features/cc-noop-second.md")"
check 'the second run names nothing' 'COMPLETE_CAPABILITIES=ok completed=0' "$out2"
refute 'the second run names no completion' 'COMPLETED=' "$out2"
[ "$FIRST_SUM" = "$SECOND_SUM" ] \
  && ok 'the file is byte-identical to the first run result' \
  || bad 'the file is byte-identical to the first run result' \
      "after first run:  $FIRST_SUM
after second run: $SECOND_SUM"

# =============================================================================
printf '\n== complete-capabilities: capability-drift over the same fixture is unaffected by the write subcommand existing ==\n'
R="$TMPROOT/cc-drift-unaffected"; mkdir -p "$R"
mk_prd "$R" cc-drift-unaffected 0 2
mk_plan "$R" cc-drift-unaffected <<'EOF'
- [x] **T1** finish capability one
  - deps: —
  - covers: open capability 1
- [x] **T2** start capability two
  - deps: —
  - covers: open capability 2
- [ ] **T3** finish capability two
  - deps: T2
  - covers: open capability 2
EOF
out="$("$ADAPTER" capability-drift "$R" 2>&1)"
expected="$(printf 'DRIFT=cc-drift-unaffected\topen capability 1\nCAPABILITY_DRIFT=attention drift=1 unjudgeable=0')"
[ "$out" = "$expected" ] && ok 'capability-drift output is byte-identical to the pre-subcommand shape' \
  || bad 'capability-drift output is byte-identical to the pre-subcommand shape' "got:
$out
want:
$expected"

# =============================================================================
printf '\n== source guard: no pipe-fed `grep` that can exit early used as a condition in the adapter ==\n'
# next-state-reporting-integrity T3. The construct this feature removed is a
# pipeline whose final stage is an early-exiting reader used as a condition:
# `printf … | awk … | grep -q .`. Under the `pipefail` set at the top of
# scripts/gspec-backlog.sh, `grep -q` exits on its first match and closes the
# pipe while the writer is still writing, the writer takes SIGPIPE (141), and
# `pipefail` reports 141 instead of grep's 0 — a true condition read as false.
# It only opens once the payload outgrows a single buffered write, so it passes
# every small test and fails in production. This case is what stops a new one
# being added to the adapter unnoticed.
#
# THE SHAPE (settled in the plan preamble, copied verbatim into
# scripts/test-runstate.sh by T4, and widened in both by grep-devnull-condition
# T2 — the two sweeps share no file, and this repo's precedent is to
# reimplement a small helper rather than add a dependency two standalone CI
# sweeps both need): a NON-COMMENT source line containing a SINGLE `|` (never
# `||`) immediately followed by `grep`, where that grep either (a) is given a
# `q`-bearing option ANYWHERE among its arguments, or (b) sends its STDOUT to
# `/dev/null`. Because it is a copy, any change to the shape is TWO edits: here
# and in scripts/test-runstate.sh. They must not drift.
#
# Each half of that earns its place:
#   - non-comment: without it the scan flags the comment in `cmd_next` that
#     NAMES the construct it removed (verified 2026-09-19: dropping the leading
#     `[^#[:space:]]` flags scripts/gspec-backlog.sh:839, a comment, and
#     nothing else). Prose that merely mentions the shape is not the shape.
#   - single `|`, not `||`: `cmd || grep -q x` is a branch, not a pipeline.
#   - `grep` immediately after the pipe: the construct is about the FINAL stage
#     being the condition. A value-producing `… | head -1 | … || true` has a
#     different final stage and is outside the shape by the PRD's definition,
#     which is why `orphan_packet_tag` in scripts/runstate.sh is documented by
#     next-state-reporting-integrity T2 rather than listed as an exception here.
#   - `q` ANYWHERE in the arguments, not just in the leading flag cluster:
#     catches `-q`, `-qx`, `-qxF`, `-n -q` and `--quiet`, and — T2's widening —
#     a `q`-bearing option placed AFTER the pattern (`… | grep -E "$pat" -q`),
#     which GNU option permutation makes exactly as early-exiting as the same
#     option in front. A here-string test (`grep -qxF … <<< "$v"`) has no pipe
#     and is correctly NOT flagged — that is the form this file's subject moved
#     to, so a scan that flagged it would fail on the fix.
#   - stdout to `/dev/null` — `>/dev/null`, `> /dev/null`, `1>/dev/null`,
#     `&>/dev/null` — even with no `q` on the line. This half is flagged on a
#     DEFENSIVE rationale, and the distinction matters enough to state twice:
#     it is NOT a measured failure. Measured (grep-devnull-condition T1's
#     review, 2026-09-19, Linux aarch64 containers, GNU grep 3.8 and 3.11, a
#     414 KB listing, 20 runs each, against the sibling instance in
#     scripts/runstate.sh) the redirect form misfired 0/20 while the pipe-fed
#     `-q` form misfired 20/20 with rc 141: GNU grep stops SCANNING on a null
#     stdout but drains a non-seekable stdin before it exits, so the writer
#     never takes SIGPIPE, and only `-q` skips that drain. The shape is flagged
#     because that safety is an undocumented courtesy of one implementation and
#     the line is one keystroke from `-q` — never because a short-circuit was
#     observed. Do not restate it as one.
#   - a BARE `2>/dev/null` is deliberately NOT matched: stderr to null neither
#     exits early nor closes the pipe, and this file's three `grep … 2>/dev/null`
#     lines are stderr redirects, not this hazard.
#
# KNOWN BOUNDARY, stated rather than silently excluded. The empty exception
# list below says the scan finds nothing, not that scripts/gspec-backlog.sh
# cannot hold this hazard in a form the scan cannot see. Three limits remain:
#   - a line whose TRAILING COMMENT contains the construct is flagged: the scan
#     reads whole lines, not shell tokens. That is a false positive rather than
#     a miss, and the exception list is where it would be absorbed.
#   - a pipeline split across a `\`-continuation is NOT flagged: the `|` and
#     the `grep` land on two different lines, and neither half alone is the
#     shape. This one is a genuine miss.
#   - a stdout redirect to a path OTHER than `/dev/null` is NOT flagged. That
#     is the plan's settled Deferred Decision, not an oversight: output to a
#     regular file has no association with early exit at all, so matching it
#     would be a false positive the exception list would then have to carry.
# All three are caught by review rather than here.
PIPE_GREP_Q_RE='^[[:space:]]*[^#[:space:]].*[^|]\|[[:space:]]*grep([^|]*[[:space:]]-[^[:space:]]*q|[^|]*([^|0-9&]|[[:space:]][1&])>[[:space:]]*/dev/null)'

scan_pipe_grep_q() { # scan_pipe_grep_q <file> -> one `<lineno>:<text>` per unexcepted hit
  local line
  while IFS= read -r line; do
    case "$line" in
      # --- REVIEWED EXCEPTIONS: EMPTY, and that is the record ---------------
      # next-state-reporting-integrity T1 removed both adapter instances, and
      # the wider shape grep-devnull-condition T2 added finds nothing new, so
      # there is nothing to except. The empty list is deliberate: a hit here is
      # a failure, not a warning.
      #
      # To add one, add a branch ABOVE the `*)` catch-all, most specific
      # fragment first, with the reason on the same line:
      #
      #   *'| awk -F: | grep -q .'*) ;; # why it cannot misreport
      #
      # SINGLE-quote the fragment. These lines are full of `$`, and a
      # double-quoted pattern expands it — under this sweep's `set -u` that
      # aborts the scan mid-file, which reads as "no hits" (verified). The
      # fragment must also not match the `__guard_selfproof_*` markers below,
      # or an exception would silently disarm the proof.
      #
      # The reason must be a BOUND on the writer's maximum output — the size at
      # which a single atomic write stops holding is 4096 bytes (PIPE_BUF) —
      # never an observed pass. A probe that does not reproduce the phenomenon
      # eliminates nothing (CLAUDE.md). Adding a branch is a deliberate edit
      # that shows up in review; that is the whole point of the literal list.
      *) printf '%s\n' "$line" ;;
    esac
  done < <(grep -nE "$PIPE_GREP_Q_RE" "$1" || true)
}

# Run against the real adapter. Recorded at the widening's implementation time
# (2026-09-19): 0 hits with the wider shape, exception list still empty.
hits="$(scan_pipe_grep_q "$ADAPTER")"
[ -z "$hits" ] \
  && ok 'scripts/gspec-backlog.sh contains no pipe-fed `grep -q` or `grep … >/dev/null` condition outside the (empty) exception list' \
  || bad 'scripts/gspec-backlog.sh contains no pipe-fed `grep -q` or `grep … >/dev/null` condition' \
      "unreviewed instances — either rewrite them without the pipe (capture the
     value, or use a here-string) or add each to the exception list above with
     the bound that makes it unable to misreport:
$hits"

# --- self-proof: the guard fails when an instance is introduced --------------
# An assertion that finds nothing proves nothing on its own — it passes just as
# happily against a scan that can never match. So the same case injects the
# construct into a copy of the adapter and asserts the identical scan flags
# exactly the injected lines and nothing else. Injections are planted in the
# two places such a line could appear: INSIDE a function body (where every real
# instance lived) and at END OF FILE (the position a line-anchored or
# early-terminating scan would miss).
#
# One injection per shape the guard claims to catch — grep-devnull-condition T2
# added the second and third:
#   - `-q` in the leading flag cluster: INJ_FN, planted inside a function body,
#     and INJ_EOF, planted as the file's last line.
#   - stdout to `/dev/null` with no `q` on the line: INJ_DEVNULL, planted
#     mid-file inside a function body.
#   - a `q`-bearing option AFTER the pattern: INJ_QAFTER, planted at end of
#     file.
# The two new shapes take one position each so that between them both positions
# are exercised, and the `want` comparison below is what shows each one turns
# the guard red where it lands. Run at the widening's implementation time
# (2026-09-19): all four flagged, nothing else — and re-run against the
# pre-widening regex, which flagged only the two `-q` lines, so the widening is
# load-bearing rather than decorative.
#
# All four carry a `__guard_selfproof_*` marker so that no future exception
# fragment, however broadly written, can accidentally except a proof itself.
INJ_FN='  ls "$root" | grep -q __guard_selfproof_fn__ && return 0'
INJ_DEVNULL='  ls "$root" | grep __guard_selfproof_devnull_fn__ >/dev/null && return 0'
INJ_QAFTER='printf "%s\n" "$x" | grep -E __guard_selfproof_qafter_eof__ -q'
INJ_EOF='printf "%s\n" "$x" | grep -qxF __guard_selfproof_eof__'
INJECTED="$TMPROOT/injected-gspec-backlog.sh"
export INJ_FN INJ_DEVNULL INJ_QAFTER INJ_EOF
awk '
  { print }
  !placed && /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/ {
      print ENVIRON["INJ_FN"]; print ENVIRON["INJ_DEVNULL"]; placed = 1
  }
  END { print ENVIRON["INJ_QAFTER"]; print ENVIRON["INJ_EOF"] }
' "$ADAPTER" > "$INJECTED"

got="$(scan_pipe_grep_q "$INJECTED")"
want="$(printf '%s\n%s\n%s\n%s\n' "$INJ_FN" "$INJ_DEVNULL" "$INJ_QAFTER" "$INJ_EOF")"
[ "$(printf '%s\n' "$got" | sed 's/^[0-9]*://')" = "$want" ] \
  && ok 'the same scan flags exactly the four injected instances — one per shape, two shapes new — and only those' \
  || bad 'the same scan flags exactly the four injected instances — one per shape, two shapes new — and only those' \
      "got:
$got
want (without line numbers):
$want"

# And they really are where this case claims: the first sits on the line after
# a multi-line function opening, and the end-of-file injection is the file's
# last line.
inj_line="$(printf '%s\n' "$got" | sed -n '1s/^\([0-9][0-9]*\):.*/\1/p')"
prev=''
[ -n "$inj_line" ] && [ "$inj_line" -gt 1 ] \
  && prev="$(sed -n "$((inj_line - 1))p" "$INJECTED")"
case "$prev" in
  *'() {') ok 'the first injected instance sits inside a function body' ;;
  *) bad 'the first injected instance sits inside a function body' \
       "first hit was at line ${inj_line:-<none>}; the line above it is: $prev" ;;
esac
[ "$(tail -n 1 "$INJECTED")" = "$INJ_EOF" ] \
  && ok 'the end-of-file injection is the last line of the file' \
  || bad 'the end-of-file injection is the last line of the file' \
      "last line is: $(tail -n 1 "$INJECTED")"

# =============================================================================
printf '\n----------------------------------------\n'
printf 'gspec-backlog: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
