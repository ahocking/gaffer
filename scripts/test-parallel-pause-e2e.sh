#!/usr/bin/env bash
# =============================================================================
# test-parallel-pause-e2e.sh — parallel cooperative-pause choreography (ADR 0017)
# =============================================================================
# End-to-end regression for a PARALLEL pause (ADR 0017 on top of ADR 0016 lanes),
# exercising the REAL scripts/worktree.sh + scripts/runstate.sh through the exact
# state sequence a mid-flight pause produces — no live agent, no mocks.
#
# It proves the mechanism the skill/agent PROMPTS drive composes correctly:
#   1. the pause signal reaches lanes at the right SCOPE (all-run vs one lane);
#   2. on pause each lane lands on a SAFE state — a lane with green work commits it
#      with the [orch packet:<id>] trailer (never mid-edit); a lane with only
#      uncommitted scratch rolls back to its green base cleanly (worktree.sh discard);
#   3. the driver writes each lane's status + last_green_commit into schema-3
#      run-state (writeback) and clears the sentinel, so the run stays RESUMABLE;
#   4. reconcile-parallel over the paused run-state returns the right per-lane
#      decision, including the resumability corners: a lane with no green -> restart,
#      and a lane whose worktree is gone but whose branch survives -> inspect branch.
#
# NOTE on determinism: the original Level A harness ran
# the lanes as background jobs for concurrency realism. A CI regression must be
# race-free, so this runs the identical choreography SEQUENTIALLY over the same real
# scripts — the file-disjoint SCHEDULING that makes concurrency safe is covered
# separately by scripts/test-packet-graph.sh; here we pin the per-lane pause OUTCOME.
#
# Run:  scripts/test-parallel-pause-e2e.sh   (exit 0 = all passed, 1 = a case failed)
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WT="${HERE}/worktree.sh"
RUNSTATE="${HERE}/runstate.sh"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
assert_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }
assert_has()  { if has "$2" "$3"; then ok "$1"; else bad "$1 (got: ${2:-<empty>})"; fi; }
assert_not()  { if has "$2" "$3"; then bad "$1 (unexpected: $3)"; else ok "$1"; fi; }
assert_true() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# --- throwaway main checkout with a `develop` integration branch --------------
REPO="$(cd "$(mktemp -d)" && pwd -P)"
WTROOT="$(dirname "$REPO")/$(basename "$REPO")-worktrees"
cleanup() {
  git -C "$REPO" worktree prune 2>/dev/null || true
  chmod -R u+w "$REPO" "$WTROOT" 2>/dev/null || true
  rm -rf "$REPO" "$WTROOT" 2>/dev/null || true
}
trap cleanup EXIT

git -c init.defaultBranch=main init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
mkdir -p "$REPO/.agents"
printf 'integration_branch: develop\n' > "$REPO/.agents/project-overrides.yaml"
printf '.agents/pause*\n.agents/run-state.yaml\n' > "$REPO/.gitignore"
printf 'hello\n' > "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"
git -C "$REPO" branch develop
git -C "$REPO" switch -q develop
BASE_SHA="$(git -C "$REPO" rev-parse develop)"

PF="${REPO}/.agents/pause"
RS="${REPO}/.agents/run-state.yaml"

# worktree.sh, always from inside the repo, lanes in our sibling root.
wt() { ( cd "$REPO" && env ORCH_WORKTREES_ROOT="$WTROOT" "$WT" "$@" ); }

# --- the two behaviours a well-behaved lane takes when it sees PAUSE=1 ---------
# land_green: the lane has completable work -> write a COMPLETE file, commit it on
# its branch with the packet trailer (never mid-edit). Echoes the new commit sha.
lane_land_green() {
  local id="$1" p="${WTROOT}/$1" f="$2" body="$3"
  printf '%s\n' "$body" > "${p}/${f}"          # a whole file, not a half-edit
  git -C "$p" add -A
  git -C "$p" commit -qm "feat(${id}): land on pause

[orch packet:${id}]"
  git -C "$p" rev-parse HEAD
}
# rollback: the lane only had uncommitted scratch -> drop it, reset to the green base.
lane_rollback() { wt discard "$1" "$2" >/dev/null; }

echo "== setup: two file-disjoint lanes off develop =="
wt create feat-a >/dev/null 2>&1
wt create feat-b >/dev/null 2>&1
assert_true "lane feat-a worktree exists" "[ -d '$WTROOT/feat-a' ]"
assert_true "lane feat-b worktree exists" "[ -d '$WTROOT/feat-b' ]"
assert_eq   "feat-a cut from develop tip" "$(git -C "$WTROOT/feat-a" rev-parse HEAD)" "$BASE_SHA"

echo "== pause scope: an all-run request is visible to every lane =="
"$RUNSTATE" request-pause "$PF" "closing the laptop" >/dev/null
assert_has "feat-a sees all-run pause" "$("$RUNSTATE" pause-status "$PF" feat-a)" "PAUSE=1 scope=all"
assert_has "feat-b sees all-run pause" "$("$RUNSTATE" pause-status "$PF" feat-b)" "PAUSE=1 scope=all"
"$RUNSTATE" clear-pause "$PF" >/dev/null

echo "== pause scope: a lane-scoped request reaches ONLY that lane =="
"$RUNSTATE" request-pause "${PF}.feat-a" "just this lane" >/dev/null
assert_has "feat-a reacts to its lane-scoped request" "$("$RUNSTATE" pause-status "$PF" feat-a)" "PAUSE=1 scope=lane:feat-a"
assert_eq  "feat-b ignores feat-a's lane-scoped request" "$("$RUNSTATE" pause-status "$PF" feat-b)" "PAUSE=0"
"$RUNSTATE" clear-pause "$PF" >/dev/null

echo "== mid-flight all-run pause: A lands green (trailer), B rolls back clean =="
# Both lanes are working: A has a completable change; B has only uncommitted scratch.
printf 'scratch-in-progress' > "$WTROOT/feat-b/wip.txt"       # B is mid-scratch
"$RUNSTATE" request-pause "$PF" "drain now" >/dev/null
# Each lane polls at its safe checkpoint and drains:
GREEN_A="$(lane_land_green feat-a src_a.txt 'final content')" # A: green -> commit
lane_rollback feat-b "$BASE_SHA"                              # B: scratch -> rollback

assert_true "A: exactly one commit ahead of base"   "[ \"\$(git -C '$WTROOT/feat-a' rev-list --count ${BASE_SHA}..HEAD)\" = 1 ]"
assert_has  "A: landed commit carries the packet trailer" "$(git -C "$WTROOT/feat-a" log -1 --format=%B)" "[orch packet:feat-a]"
assert_eq   "A: worktree clean after landing"       "$(git -C "$WTROOT/feat-a" status --porcelain)" ""
assert_eq   "B: rolled back to the green base"       "$(git -C "$WTROOT/feat-b" rev-parse HEAD)" "$BASE_SHA"
assert_eq   "B: worktree clean after rollback"       "$(git -C "$WTROOT/feat-b" status --porcelain)" ""
assert_true "B: scratch file is gone"                "[ ! -f '$WTROOT/feat-b/wip.txt' ]"

echo "== driver reflects the OUTCOME into schema-3 run-state + clears the sentinel =="
"$RUNSTATE" write "$RS" <<YAML
schema: 3
status: paused
branch: develop
updated_at: 2026-07-19T00:00:00Z
backlog:
  cursor: feat-a
packets:
  - id: feat-a
    status: done
  - id: feat-b
    status: pending
lanes:
  - id: feat-a
    branch: orch/feat-a
    worktree: ${WTROOT}/feat-a
    packet: feat-a
    last_green_commit: ${GREEN_A}
    status: paused
  - id: feat-b
    branch: orch/feat-b
    worktree: ${WTROOT}/feat-b
    packet: feat-b
    last_green_commit: ${BASE_SHA}
    status: paused
YAML
"$RUNSTATE" clear-pause "$PF" >/dev/null

assert_eq  "run-state status is paused"           "$("$RUNSTATE" get "$RS" status)" "paused"
assert_eq  "sentinel cleared -> fresh run won't re-halt" "$("$RUNSTATE" pause-status "$PF" feat-a)" "PAUSE=0"
LANES_OUT="$("$RUNSTATE" lanes "$RS")"
assert_has "lane A writeback: green = its landed commit" "$LANES_OUT" "$GREEN_A"
assert_has "lane A writeback: status paused"             "$LANES_OUT" "feat-a	orch/feat-a"

echo "== reconcile-parallel: both drained lanes are at their green checkpoint =="
REC="$("$RUNSTATE" reconcile-parallel "$RS" "$REPO")"
assert_has "feat-a reconciles clean" "$REC" "LANE=feat-a DECISION=clean"
assert_has "feat-b reconciles clean" "$REC" "LANE=feat-b DECISION=clean"
assert_has "aggregate is clean"      "$REC" "AGGREGATE=clean"

echo "== resumability corners: no-green -> restart; worktree gone, branch survives -> inspect branch =="
# feat-c: a lane killed BEFORE any commit — no last_green_commit recorded.
# feat-a2: a lane that landed green, but whose worktree was already removed (only
# the branch remains in the shared .git) — reconcile must inspect the BRANCH.
git -C "$REPO" branch orch/feat-a2 "$GREEN_A"    # branch carries feat-a's green commit
"$RUNSTATE" write "$RS" <<YAML
schema: 3
status: paused
lanes:
  - id: feat-c
    branch: orch/feat-c
    worktree: ${WTROOT}/feat-c
    packet: feat-c
    last_green_commit:
    status: paused
  - id: feat-a2
    branch: orch/feat-a2
    worktree: ${WTROOT}/gone-a2
    packet: feat-a2
    last_green_commit: ${GREEN_A}
    status: paused
YAML
REC2="$("$RUNSTATE" reconcile-parallel "$RS" "$REPO")"
assert_has "no-green lane -> restart"                 "$REC2" "LANE=feat-c DECISION=restart"
assert_has "worktree-gone-but-branch-at-green -> clean" "$REC2" "LANE=feat-a2 DECISION=clean"
assert_has "aggregate flags action (a lane needs restart)" "$REC2" "AGGREGATE=action"

echo
printf 'parallel-pause e2e: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
