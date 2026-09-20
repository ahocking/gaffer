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
#     never weaken guard.sh or a soft gate;
#   - the pause REASON is untrusted text: written through runstate.sh's shared
#     _yaml_encode_value and stripped back off by BOTH readers, so a reason
#     carrying `: `, an embedded `'` or a newline round-trips bare and a
#     sentinel written before the encoder existed still reads correctly
#     (runstate-write-integrity-gaps T5).
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
assert_true() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

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

# =============================================================================
# The pause REASON is untrusted text (runstate-write-integrity-gaps T5)
# =============================================================================
# `request-pause` now writes the reason through runstate.sh's shared
# _yaml_encode_value -- the same encoder `set` and `add-finding` use -- and BOTH
# readers strip it back off: cmd_pause_status via the shared _yaml_decode_value,
# and hooks/pause-check.sh via its own copy of that rule (it keeps its own grep
# and must stay dependency-free). Three expressions of one rule is exactly the
# shape that drifts, so every case below drives the SAME hostile value through
# every one of them and demands the same answer -- the on-disk bytes, the
# `pause-status` line, a real YAML parse, and the hook's advisory.
#
# The hazards, each with a case: `: ` (opens a second mapping key), an embedded
# `'` (breaks the encoding itself unless doubled), and a newline (writes a whole
# second line that both readers would then treat as the file's next key).
# Collapsed, never rejected -- the caller is a human or an agent mid-loop, and
# request-pause's job is to stop the run, not to validate prose.
"$RUNSTATE" clear-pause "$PF" >/dev/null

# have_yaml / yamlok / YAML_SKIP_COUNT -- same contract as test-runstate.sh: a
# parse assertion is a REAL parse, and on a host with no parser it FAILS LOUDLY
# (counted, and named in the summary line below) rather than passing vacuously.
# The parent feature's capability 5 exists because assertions of exactly this
# kind silently no-op'd on a host without PyYAML; a case added here that can
# quietly return success re-opens it.
have_yaml() { command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; }
YAML_SKIP_COUNT=0
yamlok() {
  if have_yaml; then
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$1" 2>/dev/null
  else
    YAML_SKIP_COUNT=$((YAML_SKIP_COUNT + 1)); return 1
  fi
}
if ! have_yaml; then
  YAML_SKIP_COUNT=$((YAML_SKIP_COUNT + 1))
  bad 'a YAML parser is available for the parse-assertion cases below' \
      'no python3+PyYAML on this host — not asserting vacuously'
fi
# The REAL parsed `reason`, never a mirror of runstate.sh's own decoder: an
# encode/decode pair that agrees with itself and disagrees with YAML (escaping a
# backslash inside a single-quoted scalar, say) would pass a mirror-based check
# and still be wrong. Callers gate on have_yaml, so a parser-less host reports
# the loud skip above rather than a silent pass.
parsed_reason() {
  python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
v = d.get('reason')
sys.stdout.write('' if v is None else str(v))
" "$1"
}

echo "== the pause reason is untrusted text: encoded on write, bare on BOTH read paths =="
# One value carrying all three hazards at once. The expected on-disk line is a
# LITERAL below, never rebuilt by mirroring the encoder here: a mirror agrees
# with a wrong encoder by construction, which is the one thing this case exists
# to catch.
HOSTILE="$(printf "wrap up: it's 'done'\nand a second line")"
COLLAPSED="$(printf '%s' "$HOSTILE" | tr '\n\r' '  ')"
ENCODED_LINE="reason: 'wrap up: it''s ''done'' and a second line'"
"$RUNSTATE" request-pause "$PF" "$HOSTILE" >/dev/null
assert_eq "hostile reason is stored single-quoted with each quote doubled" \
  "$(grep '^reason:' "$PF")" "$ENCODED_LINE"
assert_eq "the newline injected no extra line (sentinel is exactly 2 lines)" \
  "$(wc -l < "$PF" | tr -d ' ')" "2"
assert_eq "the colon-space injected no sibling key (exactly 2 top-level keys)" \
  "$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*:' "$PF" | tr -d ' ')" "2"
assert_true "the sentinel is still real, parseable YAML" "yamlok '$PF'"
assert_true "a real YAML parse returns the collapsed original, byte-exact" \
  "yamlok '$PF' && [ \"\$(parsed_reason '$PF')\" = \"\$COLLAPSED\" ]"
# The output SHAPE is the contract every existing caller reads: `PAUSE=1
# reason=<bare>`, with no quote characters the human never typed.
assert_eq "pause-status returns the bare reason, unchanged in shape" \
  "$("$RUNSTATE" pause-status "$PF")" "PAUSE=1 reason=${COLLAPSED}"
out="$(run_hook "$MAIN")"
assert_has "the hook's advisory carries the reason BARE" "$out" "(reason: ${COLLAPSED})"
assert_not "the hook's advisory leaks no encoding quotes" "$out" "reason: '"
assert_not "hostile reason: still context-ONLY (no permissionDecision)" "$out" "permissionDecision"

echo "== a sentinel written BEFORE the encoder (bare reason) still reads correctly =="
# No flag day: compatibility is the reader's job, exactly as the parent decided.
# This is the on-disk shape every older request-pause produced, hand-written here
# because the current one can no longer emit it.
printf 'requested_at: 2026-01-01T00:00:00Z\nreason: night shift\n' > "$PF"
assert_eq "legacy bare reason reads through pause-status unchanged" \
  "$("$RUNSTATE" pause-status "$PF")" "PAUSE=1 reason=night shift"
out="$(run_hook "$MAIN")"
assert_has "legacy bare reason reaches the hook's advisory unchanged" "$out" "(reason: night shift)"
assert_not "legacy bare reason: still context-ONLY (no permissionDecision)" "$out" "permissionDecision"
# A sentinel with NO reason line at all: `request-pause <file>` with no argument.
# grep finds nothing, and under runstate.sh's `set -euo pipefail` that used to
# abort the whole command substitution -- pause-status printed NOTHING and exited
# 1 on a legitimate sentinel, so its documented "always exits 0" contract and its
# own `<none>` fallback were both unreachable.
"$RUNSTATE" clear-pause "$PF" >/dev/null
"$RUNSTATE" request-pause "$PF" >/dev/null
assert_eq "a sentinel with no reason still answers PAUSE=1 reason=<none>" \
  "$("$RUNSTATE" pause-status "$PF")" "PAUSE=1 reason=<none>"
assert_eq "  ...and exits 0, as a query always must" \
  "$("$RUNSTATE" pause-status "$PF" >/dev/null 2>&1; echo $?)" "0"
assert_not "no-reason sentinel: still context-ONLY (no permissionDecision)" "$(run_hook "$MAIN")" "permissionDecision"

echo "== the same round-trip on a host with NEITHER jq NOR python3 =="
# runstate.sh sits at the same dependency tier as the guard: stock Git Bash ships
# neither, and checkpointing (pause included) must keep working there. The hook
# uses jq/python3 only to JSON-encode its message and has its own fallback, so
# both halves are exercised with the real tools shadowed by stubs that exit 127.
NOTOOLS="$(mktemp -d)"
for t in jq python3 python yq; do
  printf '#!/bin/sh\nexit 127\n' > "$NOTOOLS/$t"; chmod +x "$NOTOOLS/$t"
done
assert_true "no-tools host: the parser stubs really do shadow the real ones" \
  "! PATH='$NOTOOLS:\$PATH' jq --version >/dev/null 2>&1 && ! PATH='$NOTOOLS:\$PATH' python3 -c '' >/dev/null 2>&1"
"$RUNSTATE" clear-pause "$PF" >/dev/null
PATH="$NOTOOLS:$PATH" "$RUNSTATE" request-pause "$PF" "$HOSTILE" >/dev/null
assert_eq "no-tools host: the encoding is byte-identical to a full-PATH run" \
  "$(grep '^reason:' "$PF")" "$ENCODED_LINE"
assert_eq "no-tools host: pause-status still returns the bare reason" \
  "$(PATH="$NOTOOLS:$PATH" "$RUNSTATE" pause-status "$PF")" "PAUSE=1 reason=${COLLAPSED}"
out="$(run_hook "$MAIN" PATH="$NOTOOLS:$PATH")"
assert_has "no-tools host: the hook's advisory still carries the reason bare" "$out" "(reason: ${COLLAPSED})"
assert_not "no-tools host: and leaks no encoding quotes" "$out" "reason: '"
assert_not "no-tools host: still context-ONLY (no permissionDecision)" "$out" "permissionDecision"
"$RUNSTATE" clear-pause "$PF" >/dev/null

echo
if [ "$YAML_SKIP_COUNT" -gt 0 ]; then
  printf 'pause sweep: %d passed, %d failed   (no python3+PyYAML on this host — %d parse assertion(s) could not assert; not asserting vacuously)\n' \
    "$pass" "$fail" "$YAML_SKIP_COUNT"
else
  printf 'pause sweep: %d passed, %d failed\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
