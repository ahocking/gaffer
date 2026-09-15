#!/usr/bin/env bash
# =============================================================================
# test-pause.sh — cooperative-pause signal sweep (ADR 0017)
# =============================================================================
# Proves, WITHOUT a live agent, that the whole-run pause signal works:
#   - runstate.sh request-pause / clear-pause / pause-status (whole-run only —
#     retire-unused-loop-modes T1 removed the per-lane sentinel parallel mode
#     used; there is exactly one sentinel path now);
#   - hooks/pause-check.sh resolves the MAIN checkout's sentinel FROM A LINKED
#     WORKTREE via git-common-dir with NO env (a worktree can still exist for
#     self-contained work such as a spike, per the loop's worktree guidance —
#     this is not parallel-mode-specific);
#   - the $ORCH_PAUSE_FILE env fast-path;
#   - the hook is context-ONLY — it never emits a permissionDecision, so it can
#     never weaken guard.sh or a soft gate.
#
# The rate-limit status-line sensor (ADR 0018) that used to arm this same
# sentinel is retired along with parallel mode (retire-unused-loop-modes T2);
# see docs/adr/0018-rate-limit-aware-cooperative-pause.md for the superseding
# note. Its cases are removed from this file.
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

# --- throwaway main checkout + a linked worktree -----------------------------
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

# a linked worktree (not a parallel lane -- that mode is retired; this proves
# the hook's git-common-dir resolution works from ANY worktree, not just the
# main checkout), a SIBLING dir of the main checkout.
WT="${MAIN}-wt-feat-1"
git -C "$MAIN" worktree add -q -b orch/feat-1 "$WT" main

PF="${MAIN}/.agents/pause"

echo "== runstate verbs: whole-run pause =="
assert_eq "absent -> PAUSE=0" "$("$RUNSTATE" pause-status "$PF")" "PAUSE=0"
"$RUNSTATE" request-pause "$PF" "night" >/dev/null
assert_has "requested -> PAUSE=1" "$("$RUNSTATE" pause-status "$PF")" "PAUSE=1"
assert_has "reason recorded" "$("$RUNSTATE" pause-status "$PF")" "reason=night"
"$RUNSTATE" clear-pause "$PF" >/dev/null
assert_eq "cleared -> PAUSE=0" "$("$RUNSTATE" pause-status "$PF")" "PAUSE=0"

echo "== hook from the MAIN checkout (no env) =="
assert_eq  "no sentinel -> silent" "$(run_hook "$MAIN")" ""
"$RUNSTATE" request-pause "$PF" "wrap up" >/dev/null
out="$(run_hook "$MAIN")"
assert_has "sentinel -> advisory injected" "$out" "additionalContext"
assert_has "advisory names the pause"      "$out" "PAUSE REQUESTED"
assert_has "advisory carries the reason"   "$out" "wrap up"
assert_not "advisory is context-ONLY (no permissionDecision)" "$out" "permissionDecision"

echo "== hook from the LINKED WORKTREE resolves the MAIN sentinel via git-common-dir (no env) =="
# The whole-run sentinel set above lives in MAIN/.agents; the worktree must find it.
assert_has "worktree sees the whole-run sentinel" "$(run_hook "$WT")" "additionalContext"
"$RUNSTATE" clear-pause "$PF" >/dev/null
assert_eq  "worktree: cleared -> silent" "$(run_hook "$WT")" ""

echo "== hook \$ORCH_PAUSE_FILE env fast-path (no git resolution) =="
ALT="${MAIN}/.agents/altpause"
"$RUNSTATE" request-pause "$ALT" "via env" >/dev/null
assert_has "env fast-path honored" "$(run_hook "$MAIN" ORCH_PAUSE_FILE="$ALT")" "via env"
assert_eq  "default path silent while only env sentinel set" "$(run_hook "$MAIN")" ""

echo
printf 'pause sweep: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
