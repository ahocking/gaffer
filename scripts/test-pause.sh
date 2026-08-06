#!/usr/bin/env bash
# =============================================================================
# test-pause.sh — cooperative-pause signal sweep (ADR 0017)
# =============================================================================
# Proves, WITHOUT a live agent, that the pause signal works uniformly across the
# main checkout and parallel lane worktrees:
#   - runstate.sh request-pause / clear-pause / pause-status (all + lane scope);
#   - hooks/pause-check.sh resolves the MAIN checkout's sentinel FROM A WORKTREE
#     via git-common-dir with NO env (the parallel-mode requirement);
#   - the $ORCH_PAUSE_FILE env fast-path;
#   - the hook is context-ONLY — it never emits a permissionDecision, so it can
#     never weaken guard.sh or a soft gate.
#
# Run:  scripts/test-pause.sh   (exit 0 = all passed, 1 = a case failed)
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNSTATE="${HERE}/runstate.sh"
HOOK="${HERE}/../hooks/pause-check.sh"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
# assert stdout of a command CONTAINS / does-NOT-contain a fixed string.
has()    { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
assert_has()  { if has "$2" "$3"; then ok "$1"; else bad "$1 (got: ${2:-<empty>})"; fi; }
assert_not()  { if has "$2" "$3"; then bad "$1 (unexpected: $3)"; else ok "$1"; fi; }
assert_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

# The hook reads a tool envelope on stdin; feed it a minimal Bash one every time.
ENVELOPE='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
run_hook() { ( cd "$1" && shift && env "$@" bash "$HOOK" <<<"$ENVELOPE" ); }

# --- throwaway main checkout + a linked worktree lane ------------------------
MAIN="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { git -C "$MAIN" worktree prune 2>/dev/null || true; chmod -R u+w "$MAIN" "$WT" 2>/dev/null || true; rm -rf "$MAIN" "$WT" 2>/dev/null || true; }
trap cleanup EXIT

git -c init.defaultBranch=main init -q "$MAIN"
git -C "$MAIN" config user.email t@example.com
git -C "$MAIN" config user.name  tester
printf 'hello\n' > "$MAIN/README.md"
printf '.agents/pause*\n.agents/run-state.yaml\n' > "$MAIN/.gitignore"
git -C "$MAIN" add -A
git -C "$MAIN" commit -qm "init"

# a parallel lane: worktree on orch/feat-1, a SIBLING dir of the main checkout.
WT="${MAIN}-wt-feat-1"
git -C "$MAIN" worktree add -q -b orch/feat-1 "$WT" main

PF="${MAIN}/.agents/pause"

echo "== runstate verbs: all-scope =="
assert_eq "absent -> PAUSE=0" "$("$RUNSTATE" pause-status "$PF")" "PAUSE=0"
"$RUNSTATE" request-pause "$PF" "night" >/dev/null
assert_has "requested -> PAUSE=1 all" "$("$RUNSTATE" pause-status "$PF")" "PAUSE=1 scope=all"
assert_has "reason recorded" "$("$RUNSTATE" pause-status "$PF")" "reason=night"
"$RUNSTATE" clear-pause "$PF" >/dev/null
assert_eq "cleared -> PAUSE=0" "$("$RUNSTATE" pause-status "$PF")" "PAUSE=0"

echo "== runstate verbs: lane-scope =="
"$RUNSTATE" request-pause "${PF}.feat-1" "one lane" >/dev/null
assert_has "lane match" "$("$RUNSTATE" pause-status "$PF" feat-1)" "PAUSE=1 scope=lane:feat-1"
assert_eq  "other lane unaffected" "$("$RUNSTATE" pause-status "$PF" feat-2)" "PAUSE=0"
"$RUNSTATE" clear-pause "$PF" >/dev/null
assert_eq  "clear sweeps per-lane too" "$("$RUNSTATE" pause-status "$PF" feat-1)" "PAUSE=0"

echo "== hook from the MAIN checkout (no env) =="
assert_eq  "no sentinel -> silent" "$(run_hook "$MAIN")" ""
"$RUNSTATE" request-pause "$PF" "wrap up" >/dev/null
out="$(run_hook "$MAIN")"
assert_has "sentinel -> advisory injected" "$out" "additionalContext"
assert_has "advisory names the pause"      "$out" "PAUSE REQUESTED"
assert_has "advisory carries the reason"   "$out" "wrap up"
assert_not "advisory is context-ONLY (no permissionDecision)" "$out" "permissionDecision"

echo "== hook from the LANE WORKTREE resolves the MAIN sentinel via git-common-dir (no env) =="
# The all-scope sentinel set above lives in MAIN/.agents; the worktree must find it.
assert_has "worktree sees all-scope sentinel" "$(run_hook "$WT")" "additionalContext"
"$RUNSTATE" clear-pause "$PF" >/dev/null
assert_eq  "worktree: cleared -> silent" "$(run_hook "$WT")" ""

echo "== hook lane-scope: only the matching lane's worktree reacts =="
"$RUNSTATE" request-pause "${PF}.feat-1" "just feat-1" >/dev/null
out="$(run_hook "$WT")"                       # worktree is on orch/feat-1
assert_has "matching lane worktree reacts" "$out" "this lane (feat-1)"
# the MAIN checkout is not on orch/feat-1, so a lane-scoped request must NOT fire there.
assert_eq  "main checkout ignores a lane-scoped request" "$(run_hook "$MAIN")" ""
"$RUNSTATE" clear-pause "$PF" >/dev/null

echo "== hook \$ORCH_PAUSE_FILE env fast-path (no git resolution) =="
ALT="${MAIN}/.agents/altpause"
"$RUNSTATE" request-pause "$ALT" "via env" >/dev/null
assert_has "env fast-path honored" "$(run_hook "$MAIN" ORCH_PAUSE_FILE="$ALT")" "via env"
assert_eq  "default path silent while only env sentinel set" "$(run_hook "$MAIN")" ""

# =============================================================================
# ADR 0018 — the status-line sensor arms the SAME sentinel when a rolling usage
# window crosses its threshold. It reads session JSON on stdin, prints a one-line
# status, and (side effect) writes the sentinel. We feed crafted JSON blobs and
# assert the sentinel appears / does not and carries the expected window's reason.
# =============================================================================
SENSOR="${HERE}/statusline-pause-sensor.sh"
SPF="${MAIN}/.agents/sensorpause"          # isolated from the ADR 0017 cases above
SJSON=''                                    # the session JSON each case feeds on stdin
run_sensor() { ( cd "$1" && shift && env "$@" bash "$SENSOR" <<<"$SJSON" ); }
"$RUNSTATE" clear-pause "$PF" >/dev/null    # ensure the git-resolved sentinel starts clear

echo "== sensor: no rate_limits block -> bare label, nothing armed (API-key / pre-first-response) =="
SJSON='{"session_id":"x"}'
assert_eq  "no rate_limits -> 'orch'"        "$(run_sensor "$MAIN" ORCH_PAUSE_FILE="$SPF")" "orch"
assert_eq  "no rate_limits -> no sentinel"   "$("$RUNSTATE" pause-status "$SPF")" "PAUSE=0"

echo "== sensor: the 5-hour window crosses its default threshold (90) =="
SJSON='{"rate_limits":{"five_hour":{"used_percentage":95,"resets_at":1721480000},"seven_day":{"used_percentage":40,"resets_at":1721880000}}}'
run_sensor "$MAIN" ORCH_PAUSE_FILE="$SPF" >/dev/null
assert_has "5h over -> sentinel armed"       "$("$RUNSTATE" pause-status "$SPF")" "PAUSE=1 scope=all"
assert_has "reason names the 5h window"      "$("$RUNSTATE" pause-status "$SPF")" "5h-limit at 95%"
assert_not "reason omits the untripped weekly window" "$("$RUNSTATE" pause-status "$SPF")" "weekly-limit"
# a later response must NOT rewrite the reason/timestamp (idempotent, ! -f guard)
SJSON='{"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1}}}'
run_sensor "$MAIN" ORCH_PAUSE_FILE="$SPF" >/dev/null
assert_has "idempotent -> original reason preserved" "$("$RUNSTATE" pause-status "$SPF")" "5h-limit at 95%"
"$RUNSTATE" clear-pause "$SPF" >/dev/null

echo "== sensor: only the weekly window crosses (its default 85 sits below the 5h 90) =="
SJSON='{"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1721480000},"seven_day":{"used_percentage":90,"resets_at":1721880000}}}'
run_sensor "$MAIN" ORCH_PAUSE_FILE="$SPF" >/dev/null
assert_has "7d over -> sentinel armed"       "$("$RUNSTATE" pause-status "$SPF")" "PAUSE=1"
assert_has "reason names the weekly window"  "$("$RUNSTATE" pause-status "$SPF")" "weekly-limit at 90%"
assert_not "reason omits the untripped 5h window" "$("$RUNSTATE" pause-status "$SPF")" "5h-limit"
"$RUNSTATE" clear-pause "$SPF" >/dev/null

echo "== sensor: BOTH windows cross -> one sentinel names both =="
SJSON='{"rate_limits":{"five_hour":{"used_percentage":96,"resets_at":1721480000},"seven_day":{"used_percentage":88,"resets_at":1721880000}}}'
run_sensor "$MAIN" ORCH_PAUSE_FILE="$SPF" >/dev/null
out="$("$RUNSTATE" pause-status "$SPF")"
assert_has "both -> 5h in reason"            "$out" "5h-limit at 96%"
assert_has "both -> weekly in reason"        "$out" "weekly-limit at 88%"
"$RUNSTATE" clear-pause "$SPF" >/dev/null

echo "== sensor: under BOTH thresholds -> nothing armed =="
SJSON='{"rate_limits":{"five_hour":{"used_percentage":50},"seven_day":{"used_percentage":50}}}'
run_sensor "$MAIN" ORCH_PAUSE_FILE="$SPF" >/dev/null
assert_eq  "under both -> no sentinel"       "$("$RUNSTATE" pause-status "$SPF")" "PAUSE=0"

echo "== sensor: ORCH_RATE_PAUSE=off disables both checks; ORCH_RATE_PAUSE_PCT lowers the 5h bar =="
SJSON='{"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1721480000}}}'
run_sensor "$MAIN" ORCH_PAUSE_FILE="$SPF" ORCH_RATE_PAUSE=off >/dev/null
assert_eq  "disabled -> no sentinel"         "$("$RUNSTATE" pause-status "$SPF")" "PAUSE=0"
SJSON='{"rate_limits":{"five_hour":{"used_percentage":60,"resets_at":1721480000}}}'
run_sensor "$MAIN" ORCH_PAUSE_FILE="$SPF" ORCH_RATE_PAUSE_PCT=50 >/dev/null
assert_has "env threshold override honored"  "$("$RUNSTATE" pause-status "$SPF")" "5h-limit at 60%"
"$RUNSTATE" clear-pause "$SPF" >/dev/null

echo "== sensor: reads .agents/project-overrides.yaml AND resolves the sentinel via git-common-dir (no env) =="
# The status line is harness-invoked — nothing exports ORCH_RATE_PAUSE* into it —
# so the YAML layer is the PRIMARY config surface (ADR 0018 open question #1). Here
# we set NO env at all: the threshold comes from YAML and the sentinel is the
# git-resolved MAIN-checkout one (the parallel-lane requirement, inherited from 0017).
OVR="${MAIN}/.agents/project-overrides.yaml"
printf 'project:\n  name: demo\nrate_limit_pause:\n  enabled: true\n  five_hour_threshold_pct: 50\nintegration_branch: develop\n' > "$OVR"
SJSON='{"rate_limits":{"five_hour":{"used_percentage":60,"resets_at":1721480000}}}'
run_sensor "$MAIN" >/dev/null
assert_has "YAML threshold honored via git-resolved sentinel" "$("$RUNSTATE" pause-status "$PF")" "5h-limit at 60%"
"$RUNSTATE" clear-pause "$PF" >/dev/null
printf 'rate_limit_pause:\n  enabled: false\n  five_hour_threshold_pct: 50\n' > "$OVR"
SJSON='{"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1721480000}}}'
run_sensor "$MAIN" >/dev/null
assert_eq  "YAML enabled:false disables the sensor" "$("$RUNSTATE" pause-status "$PF")" "PAUSE=0"

echo
printf 'pause sweep: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
