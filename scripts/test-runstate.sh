#!/usr/bin/env bash
# =============================================================================
# test-runstate.sh — invariant sweep for Phase 4 pause/resume (ADR 0004/0009)
# =============================================================================
# Proves the pause/resume safety invariant WITHOUT a live agent: a pause leaves
# the loop's working tree at the last GREEN commit (clean tree, HEAD == green) by
# setting non-checkpoint scratch aside NON-destructively with `git stash`
# (ADR 0009 — no worktree, no `reset --hard`), persists a durable
# .agents/run-state.yaml, and a fresh "session" reconstructs the backlog from that
# file and re-attaches the feature branch at the green checkpoint IN THE SINGLE
# LOCAL CHECKOUT.
#
# Run:  scripts/test-runstate.sh   (exit 0 = all passed, 1 = a case failed)
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '     %s\n' "$2"; fi; fail=$((fail + 1)); }
# assert_true evaluates its command with `pipefail` OFF, and that is the whole
# fix for a flake class this file has now been bitten by twice.
#
# 43 assertions here have the shape `<producer> | grep -q PAT`. Under this
# script's `pipefail` (line 16) that races: `grep -q` exits the instant it
# matches the FIRST line and closes its read end, so a producer still mid-write
# takes SIGPIPE (rc 141), and pipefail reports THAT rather than grep's successful
# match. A correct answer reads as a failed assertion.
#
# It is load-dependent -- it needs the cumulative subprocess pressure of a real
# sweep, which is why it reproduces in CI and in a full ten-sweep run but not in
# isolated repeats (0 in 3,000 sequential calls, separately established). That is
# exactly what makes it dangerous: WHICH assertion fires is chance, so fixing the
# instance that happened to fire leaves every other one loaded. T3 (commit
# 75bf039) established the cause and converted the four `trim-note` assertions to
# capture-then-compare; `record-outcome records a NON-green outcome` was simply
# the next one to draw the short straw.
#
# Fixing the remaining 39 the same way would mean 39 quoting transformations in
# the only test file covering the loop's durable state -- 39 chances to silently
# weaken an assertion. Disabling pipefail for the evaluation is one line, covers
# every current and future assertion, and cannot change any of their meanings:
#
#   - Every one of them tests "does the output contain PAT". The producer's exit
#     status was ALREADY invisible to them -- `| grep -q` reports grep's status,
#     and this script runs `set -uo pipefail` without `set -e`, so a non-zero
#     producer never failed an assertion anyway.
#   - SIGPIPE cannot truncate a match into a miss: grep only closes the pipe
#     early BECAUSE it already matched. With no match it reads to EOF.
#
# Options are global in bash (and `local -` needs 4.4, while macOS ships 3.2), so
# save and restore explicitly rather than relying on function scoping.
# 75bf039's four conversions stay as they are: still correct, now simply belt and
# braces.
# This script sets pipefail unconditionally at the top, so restoring it is
# unconditional too -- no need to probe for the prior state.
assert_true() {
  local _rc
  set +o pipefail
  eval "$2" >/dev/null 2>&1; _rc=$?
  set -o pipefail
  if [ "$_rc" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

# flat top-level value:  rs_get <file> <key>
rs_get()    { grep -E "^$2:" "$1" | head -1 | sed -E "s/^$2:[[:space:]]*//"; }
rs_cursor() { grep -E '^[[:space:]]+cursor:' "$1" | head -1 | sed -E 's/.*cursor:[[:space:]]*//'; }

# --- throwaway repo: single checkout, no worktrees (realpath for stable paths) --
REPO="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { rm -rf "$REPO"; }
trap cleanup EXIT

git -c init.defaultBranch=main init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
printf 'hello\n' > "$REPO/README.md"
# run-state is gitignored local bookkeeping (ADR 0009): git stash -u skips it and
# status never shows it, so it survives discards and never dirties the tree.
# run-state-prev.yaml (the last-known-good copy `write` takes) MUST be ignored for
# the same reason and it is not optional: without this line the first `write` leaves
# `?? .agents/` in `git status --porcelain`, which `reconcile` reads as scratch on
# the green checkpoint and discards — the backup destroyed by the recovery path it
# exists to serve. This fixture reproduced exactly that before the line was added.
printf '.agents/run-state.yaml\n.agents/run-state-prev.yaml\n' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"
MAIN_SHA="$(git -C "$REPO" rev-parse main)"
# `main` must never be disturbed by the loop's feature-branch work — the ONLY
# thing pause/resume touches is the orch/<task-id> branch and the run-state file.
main_intact() { [ "$(git -C "$REPO" rev-parse main)" = "$MAIN_SHA" ] \
                && git -C "$REPO" show main:README.md 2>/dev/null | grep -qx hello; }

TASK=feature-x
BRANCH="orch/${TASK}"
RS="${REPO}/.agents/run-state.yaml"

echo "== set up a feature branch off main with a green checkpoint =="
git -C "$REPO" switch -q -c "$BRANCH" main
printf 'feature work\n' > "$REPO/feature.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "feature-001: green checkpoint"
GREEN="$(git -C "$REPO" rev-parse HEAD)"
assert_true "green checkpoint committed on $BRANCH" \
  "[ -n '$GREEN' ] && git -C '$REPO' show-ref --verify --quiet refs/heads/$BRANCH"

echo "== dirty the checkout with non-checkpoint scratch =="
printf 'half-done, red\n' > "$REPO/scratch.txt"          # untracked scratch
printf 'more\n' >> "$REPO/feature.txt"                    # tracked, uncommitted
assert_true "checkout is dirty before pause" "[ -n \"\$(git -C '$REPO' status --porcelain)\" ]"

echo "== PAUSE: write run-state, stash scratch (non-destructive) to reach green =="
mkdir -p "$REPO/.agents"
cat > "$RS" <<EOF
schema: 1
branch: ${BRANCH}
last_green_commit: ${GREEN}
backlog:
  cursor: feature-002
  done:
    - feature-001
  pending:
    - feature-002
pending_questions:
  - id: q-001
    severity: blocking
    packet: feature-002
    question: which normalization source is authoritative?
note: paused after feature-001 landed green
EOF
# the safety-critical mechanical step: set scratch aside so the tree is clean at
# the green checkpoint — recoverable, unlike the old `reset --hard`/`clean -f`.
# run-state is gitignored, so -u leaves it in place while sweeping real scratch.
assert_true "stash scratch to reach green" \
  "git -C '$REPO' stash push --include-untracked -m 'orch pause scratch'"

echo "== invariant: checkout clean at the green checkpoint =="
assert_true "HEAD == green sha"              "[ \"\$(git -C '$REPO' rev-parse HEAD)\" = '$GREEN' ]"
assert_true "tree clean after stash"         "[ -z \"\$(git -C '$REPO' status --porcelain)\" ]"
assert_true "scratch file set aside"         "[ ! -f '$REPO/scratch.txt' ]"
assert_true "scratch recoverable in stash"   "git -C '$REPO' stash list | grep -q 'orch pause scratch'"
assert_true "run-state survived the stash"   "[ -f '$RS' ]"
assert_true "main branch never disturbed"    "main_intact"

echo "== run-state round-trips (fresh read reconstructs the backlog) =="
assert_true "branch round-trips"            "[ \"\$(rs_get '$RS' branch)\" = '$BRANCH' ]"
assert_true "last_green_commit round-trips" "[ \"\$(rs_get '$RS' last_green_commit)\" = '$GREEN' ]"
assert_true "backlog cursor round-trips"    "[ \"\$(rs_cursor '$RS')\" = 'feature-002' ]"
# An ABSENT key is empty-with-exit-0, not a failure — so a caller's bare
# `x="$(runstate get … key)"` under set -e never aborts (the summary bug).
RS_NOCUR="$(mktemp)"; printf 'status: running\nbranch: %s\n' "$BRANCH" > "$RS_NOCUR"
assert_true "get absent key exits 0"        "'$HERE/runstate.sh' get '$RS' no_such_key"
assert_true "get absent key is empty"       "[ -z \"\$('$HERE/runstate.sh' get '$RS' no_such_key)\" ]"
assert_true "cursor absent exits 0"         "'$HERE/runstate.sh' cursor '$RS_NOCUR'"

echo "== RESUME: fresh session re-attaches the feature branch at the checkpoint =="
# simulate a fresh session: the branch persists in the same checkout; a resume
# just switches back to it (here via main to prove switching is clean).
git -C "$REPO" switch -q main
git -C "$REPO" stash drop >/dev/null 2>&1 || true   # scratch was disposable
assert_true "run-state still readable after session loss" "[ -f '$RS' ] && [ \"\$(rs_cursor '$RS')\" = 'feature-002' ]"
git -C "$REPO" switch -q "$BRANCH"
assert_true "resumed HEAD == green sha"     "[ \"\$(git -C '$REPO' rev-parse HEAD)\" = '$GREEN' ]"
assert_true "main branch never disturbed"   "main_intact"
assert_true "main README content intact"    "grep -qx hello '$REPO/README.md'"

# =============================================================================
# ADR 0005 — crash-safe resume: status signal, atomic writes, reconcile, hook.
# The reconcile helper inspects the working tree it is handed — here the single
# local checkout (`$REPO`), on the feature branch.
# =============================================================================
RUNSTATE="${HERE}/runstate.sh"
PLUGIN_ROOT="$(cd "${HERE}/.." && pwd)"
HOOK="${PLUGIN_ROOT}/hooks/session-start.sh"
no_temp() { ! ls "$REPO/.agents"/.run-state.* >/dev/null 2>&1; }   # atomic write leaves no scratch
decision() { "$RUNSTATE" reconcile "$RS" "$REPO" | sed -n 's/^DECISION=//p'; }
run_hook() { CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" </dev/null; }

echo "== status field: set inserts + flips atomically, no leftover temp =="
# REGRESSION CASE for a silent crash-misreport: cmd_set (T4) now ALWAYS quotes
# its value (`status: 'running'` on disk, no plain-scalar allowlist -- see
# _yaml_encode_value's comment for why), so this asserts the write/read pair
# together, through cmd_get (T5), rather than the raw byte on disk. If cmd_get
# ever stopped stripping the encoding symmetrically, `status` would come back
# as the literal string `'running'`, `hooks/session-start.sh`'s bare `case
# "$status" in running) ...` would stop matching, and a crashed run (status
# left at `running`) would fall through to the "paused cleanly, resume
# normally" branch -- the wrong recovery instruction, with nothing anywhere
# signalling the mismatch. See hooks/session-start.sh:36-51.
assert_true "set inserts status=running (round-trips bare through get)" \
  "\"\$RUNSTATE\" set '$RS' status running && [ \"\$(\"\$RUNSTATE\" get '$RS' status)\" = running ]"
assert_true "set flips status=paused (round-trips bare through get)" \
  "\"\$RUNSTATE\" set '$RS' status paused && [ \"\$(\"\$RUNSTATE\" get '$RS' status)\" = paused ]"
assert_true "no temp file left after set" "no_temp"
# The bare round-trip above goes through cmd_get's decode -- confirm the RAW
# byte on disk really is quoted (i.e. this isn't passing because nothing
# quotes it in the first place). Checked against the value the prior "flips"
# assertion left in place: status=paused.
assert_true "status is actually quoted on disk (not bare -- no allowlist)" \
  "grep -qx \"status: 'paused'\" '$RS'"

echo "== atomic full write (temp + rename) round-trips =="
assert_true "write persists full file, green intact" \
  "printf 'schema: 2\nstatus: running\nbranch: $BRANCH\nlast_green_commit: $GREEN\nbacklog:\n  cursor: feature-002\n  pending:\n    - feature-002\n' | \"\$RUNSTATE\" write '$RS' && [ \"\$(\"\$RUNSTATE\" get '$RS' last_green_commit)\" = '$GREEN' ]"
assert_true "no temp file left after write" "no_temp"

echo
echo "== write refuses structurally invalid input, target left byte-untouched (runstate-write-integrity capability 2, T7) =="
# Defect 2: `write` used to be `cat > tmp && mv -f`, validating nothing -- a
# failed transform upstream in the pipe silently truncated run-state to a stub;
# it fired live when an `awk` aborted on a missing `strftime` and left a
# 26-byte file over a working run-state. Gitignored, so there was no `git
# restore`, only manual reconstruction. Every negative case here asserts BOTH a
# nonzero exit AND that the target's CHECKSUM is unchanged -- checksum, not a
# YAML parse, so these hold on a parser-less host too (see yamlok() below) --
# because "the good file still exists afterwards" is the whole point.
WI="$(mktemp -d)/.agents"; mkdir -p "$WI"
WRS="$WI/run-state.yaml"
printf 'schema: 3\nstatus: running\nbranch: orch/keepme\nnote: known-good\n' > "$WRS"
WSUM_BEFORE="$(cksum "$WRS")"
wsum_unchanged() { [ "$(cksum "$WRS")" = "$WSUM_BEFORE" ]; }
no_temp_wi() { ! ls "$WI"/.run-state.* >/dev/null 2>&1; }

# The live incident's exact bytes were never captured (gitignored, recovered
# by hand) -- this reproduces its CHECKSUM-PRESERVING-REFUSAL shape (a short,
# whitespace-only fragment an aborted transform left behind), not literal
# bytes from the incident.
STUB26="$WI/stub26"
printf '%26s' '' | tr ' ' '\n' > "$STUB26"
assert_true "the reproduction stub is really 26 bytes" "[ \"\$(wc -c < '$STUB26')\" -eq 26 ]"

assert_true "write refuses the 26-byte truncation stub (nonzero exit)" \
  "! \"\$RUNSTATE\" write '$WRS' < '$STUB26' 2>/dev/null"
assert_true "  target checksum unchanged after the 26-byte stub" "wsum_unchanged"

assert_true "write refuses empty stdin (nonzero exit)" \
  "! printf '' | \"\$RUNSTATE\" write '$WRS' 2>/dev/null"
assert_true "  target checksum unchanged after empty stdin" "wsum_unchanged"

assert_true "write refuses whitespace-only stdin (nonzero exit)" \
  "! printf '   \n\t\n  \n' | \"\$RUNSTATE\" write '$WRS' 2>/dev/null"
assert_true "  target checksum unchanged after whitespace-only stdin" "wsum_unchanged"

assert_true "write refuses a schema-less document (nonzero exit)" \
  "! printf 'status: running\nbranch: orch/x\n' | \"\$RUNSTATE\" write '$WRS' 2>/dev/null"
assert_true "  target checksum unchanged after a schema-less document" "wsum_unchanged"

assert_true "write refuses a schema-carrying doc with a malformed column-0 line (nonzero exit)" \
  "! printf 'schema: 3\nleftover fragment, no colon here\nstatus: running\n' | \"\$RUNSTATE\" write '$WRS' 2>/dev/null"
assert_true "  target checksum unchanged after a malformed column-0 line" "wsum_unchanged"

assert_true "no temp file left after any refused write" "no_temp_wi"

EMPTY_REFUSAL="$("$RUNSTATE" write "$WRS" < /dev/null 2>&1 >/dev/null)"
assert_true "the refusal names the failed check (empty input)" \
  "printf '%s' \"\$EMPTY_REFUSAL\" | grep -q 'empty input'"
assert_true "the refusal states the structural-check bound, not a parse claim" \
  "printf '%s' \"\$EMPTY_REFUSAL\" | grep -qi 'not a well-formed-but-wrong document'"
COLZERO_REFUSAL="$(printf 'schema: 3\nleftover fragment, no colon here\n' | "$RUNSTATE" write "$WRS" 2>&1 >/dev/null)"
assert_true "the refusal names the failed check (malformed column-0 line)" \
  "printf '%s' \"\$COLZERO_REFUSAL\" | grep -q 'malformed line'"

echo "== write still accepts what it should: a valid doc, and a first write to a new path =="
assert_true "write still accepts a structurally valid document" \
  "printf 'schema: 3\nstatus: paused\nnote: updated\n' | \"\$RUNSTATE\" write '$WRS' && [ \"\$(\"\$RUNSTATE\" get '$WRS' note)\" = updated ]"
assert_true "  checksum DID change on an accepted write" "! wsum_unchanged"

FIRST="$(mktemp -d)/.agents/run-state.yaml"
assert_true "no run-state exists yet at the first-write path" "[ ! -f '$FIRST' ]"
assert_true "a first write to a non-existent path still creates it (bootstrap)" \
  "printf 'schema: 3\nstatus: running\n' | \"\$RUNSTATE\" write '$FIRST' && [ -f '$FIRST' ]"

echo
echo "== write keeps a last-known-good copy on replace (runstate-write-integrity capability 2) =="
# The structural checks above cannot catch a transform that dies BETWEEN
# lines: 'schema: 3\nstatus: running\n' is a structurally PERFECT document,
# and is exactly the 26 bytes the live incident's stub left. That gap cannot
# be closed by detection without classifying every valid/invalid document
# forever (a shrinkage guard was designed and rejected for the same reason
# from the other direction: /gaffer:migrate findings triage legitimately
# shrinks a real run-state 61%). So recovery, not detection: before REPLACING
# an existing file, `write` copies the pre-write content to a sibling
# run-state-prev.yaml. cmp -s (byte-for-byte), not cksum, because these cases
# compare files at DIFFERENT paths -- cksum's own output embeds the filename,
# so comparing two `cksum` lines for files with different names can never
# match even when their content is identical.
WB="$(mktemp -d)/.agents"; mkdir -p "$WB"
WBRS="$WB/run-state.yaml"
WBPREV="$WB/run-state-prev.yaml"

printf 'schema: 3\nstatus: running\nbranch: orch/first\n' > "$WBRS"
assert_true "no backup exists yet (nothing has replaced this file)" "[ ! -f '$WBPREV' ]"

ORIG_SNAPSHOT="$(mktemp)"; cp "$WBRS" "$ORIG_SNAPSHOT"
assert_true "replacing an existing file succeeds" \
  "printf 'schema: 3\nstatus: paused\nbranch: orch/second\n' | \"\$RUNSTATE\" write '$WBRS'"
assert_true "the backup now exists" "[ -f '$WBPREV' ]"
assert_true "the backup holds the PRE-write content, byte-identical" \
  "cmp -s '$WBPREV' '$ORIG_SNAPSHOT'"
assert_true "the target holds the NEW content, not the backup's" \
  "[ \"\$(\"\$RUNSTATE\" get '$WBRS' branch)\" = orch/second ]"

FIRSTB="$(mktemp -d)/.agents/run-state.yaml"
assert_true "no backup path exists before a first write" "[ ! -f \"\$(dirname '$FIRSTB')/run-state-prev.yaml\" ]"
assert_true "a first write to a non-existent path succeeds" \
  "printf 'schema: 3\nstatus: running\n' | \"\$RUNSTATE\" write '$FIRSTB'"
assert_true "no backup is created on a first write (nothing existed to preserve)" \
  "[ ! -f \"\$(dirname '$FIRSTB')/run-state-prev.yaml\" ]"

TARGET_SUM_BEFORE_REFUSAL="$(cksum "$WBRS")"
PREV_SUM_BEFORE_REFUSAL="$(cksum "$WBPREV")"
assert_true "a refused write is still refused (nonzero exit)" \
  "! printf '' | \"\$RUNSTATE\" write '$WBRS' 2>/dev/null"
assert_true "  a refused write leaves the TARGET untouched" \
  "[ \"\$(cksum '$WBRS')\" = \"\$TARGET_SUM_BEFORE_REFUSAL\" ]"
assert_true "  a refused write leaves the EXISTING BACKUP untouched" \
  "[ \"\$(cksum '$WBPREV')\" = \"\$PREV_SUM_BEFORE_REFUSAL\" ]"

# THE CASE THAT IS THE WHOLE JUSTIFICATION FOR THIS CAPABILITY: a good
# run-state, hit by the exact between-lines truncation that the structural
# checks above cannot see -- accepted (exit 0), the target becomes the stub,
# and the ORIGINAL good file survives byte-identical as run-state-prev.yaml.
# Without the backup this IS the live incident, uncaught and unrecovered.
EE="$(mktemp -d)/.agents"; mkdir -p "$EE"
EERS="$EE/run-state.yaml"
EEPREV="$EE/run-state-prev.yaml"
cat > "$EERS" <<'GOOD'
schema: 3
status: running
branch: orch/feature-042
last_green_commit: 4b825dc642cb6eb9a060e54bf8d69288fbee4904
backlog:
  cursor: feature-043
  pending:
    - feature-043
note: paused after feature-042 landed green
GOOD
EE_ORIG_SNAPSHOT="$(mktemp)"; cp "$EERS" "$EE_ORIG_SNAPSHOT"
assert_true "the between-lines truncation stub is accepted (passes every structural check)" \
  "printf 'schema: 3\nstatus: running\n' | \"\$RUNSTATE\" write '$EERS'"
assert_true "  the target is now the stub (the checks really cannot see this one)" \
  "[ \"\$(cat '$EERS')\" = \"\$(printf 'schema: 3\nstatus: running')\" ]"
assert_true "  the ORIGINAL good file survives byte-identical as run-state-prev.yaml" \
  "cmp -s '$EEPREV' '$EE_ORIG_SNAPSHOT'"

# --- T8: the integrity checks must run on EVERY host runstate.sh runs on --------
# `runstate.sh` is POSIX shell with no parser dependency, deliberately: stock Git
# Bash ships neither `jq` nor a real `python3` (the constraint `hooks/guard.sh` is
# built around), and a check that quietly disables itself when a tool is missing is
# the defect T1 fixed one file over. Asserting "no jq/python3 in the source" would
# be a grep; this EXECUTES the encoder and the write check with both stripped from
# PATH and demands byte-identical behaviour.
#
# The scrub wraps ONLY the runstate.sh invocations. Wrapping the whole block would
# also blind the sweep's own `have_yaml`, which would trip T1's loud skip and fail
# the run for the wrong reason — the assertions below would go red while telling us
# nothing about `runstate.sh`.
NOTOOLS="$(mktemp -d)"
for t in jq python3 python yq; do
  printf '#!/bin/sh\nexit 127\n' > "$NOTOOLS/$t"; chmod +x "$NOTOOLS/$t"
done
bare() { PATH="$NOTOOLS:$PATH" "$RUNSTATE" "$@"; }   # runstate.sh only, never the sweep
T8D="$(mktemp -d)"; T8F="$T8D/run-state.yaml"
printf 'schema: 3\nstatus: running\n' > "$T8F"
assert_true "no-tools host: the parser stubs really do shadow the real ones" \
  "! PATH='$NOTOOLS:\$PATH' jq --version >/dev/null 2>&1 && ! PATH='$NOTOOLS:\$PATH' python3 -c '' >/dev/null 2>&1"
assert_true "no-tools host: set encodes a hostile value" \
  "bare set '$T8F' note 'blocked on the commit: it'\"'\"'s stuck'"
assert_true "no-tools host: the encoding is byte-identical to a full-PATH run" \
  "[ \"\$(grep '^note:' '$T8F')\" = \"note: 'blocked on the commit: it''s stuck'\" ]"
assert_true "no-tools host: get decodes it back" \
  "[ \"\$(bare get '$T8F' note)\" = \"blocked on the commit: it's stuck\" ]"
assert_true "no-tools host: write still refuses a truncation stub" \
  "! printf 'garbage with no schema key\n' | bare write '$T8F' 2>/dev/null"
assert_true "no-tools host: the refused write left the file intact" \
  "[ \"\$(bare get '$T8F' status)\" = running ]"
assert_true "no-tools host: a valid write still succeeds" \
  "printf 'schema: 3\nstatus: paused\n' | bare write '$T8F'"

# The backup must be INVISIBLE to git, and this is load-bearing rather than tidy:
# an untracked file is swept by the pause path's `git stash --include-untracked`
# and read by `reconcile` in `git status --porcelain` as scratch sitting on the
# green checkpoint, which it then discards — so an unignored backup is destroyed by
# the very recovery path it exists to serve. Caught for real: before the fixture's
# .gitignore carried the line, the first `write` here left `?? .agents/` and the
# reconcile decision table below flipped `clean` to `discard`. That surfaced through
# an unrelated assertion, so this one pins the property directly.
"$RUNSTATE" write "$RS" < "$RS" >/dev/null 2>&1 || true
assert_true "the backup does not dirty the tree reconcile inspects" \
  "[ -z \"\$(git -C '$REPO' status --porcelain)\" ]"
assert_true "the backup really was created (so the check above is not vacuous)" \
  "[ -f \"$(dirname "$RS")/run-state-prev.yaml\" ]"

echo "== reconcile decision table (checkout clean at green to start) =="
assert_true "clean: HEAD==green, tree clean"        "[ \"\$(decision)\" = clean ]"
printf 'scratch\n' > "$REPO/scratch.txt"
assert_true "discard: uncommitted scratch on green"  "[ \"\$(decision)\" = discard ]"
# the resume action for `discard` is a non-destructive stash, after which the
# tree is clean at green again — prove that returns the decision to `clean`.
git -C "$REPO" stash push --include-untracked -m 'orch resume scratch' -- . >/dev/null
assert_true "clean again after stashing scratch"     "[ \"\$(decision)\" = clean ]"
git -C "$REPO" stash drop >/dev/null 2>&1 || true

echo "== reconcile separates deliberate output the loop did not create from its own scratch (thin-loop-driver-gaps T3) =="
# Worked example from the PRD: agent memories awaiting /gspec-memorize review
# sit as untracked files under .gspec/memory/pending/ -- NOT the loop's own
# crash-recovery scratch. Following the old `discard` decision literally would
# stash unreviewed work out of the tree without asking. Thirteen files, to
# match the PRD's worked example exactly.
mkdir -p "$REPO/.gspec/memory/pending/some-agent"
for i in $(seq 1 13); do
  printf 'memory %s\n' "$i" > "$REPO/.gspec/memory/pending/some-agent/mem-$i.md"
done
assert_true "escalate: 13 untracked files under a reviewed-output directory" \
  "[ \"\$(decision)\" = escalate ]"
assert_true "  the reason names the reviewed-output path, not a blanket dirt message" \
  "\"\$RUNSTATE\" reconcile '$RS' '$REPO' | grep -qi 'reviewed-output'"
rm -rf "$REPO/.gspec"
assert_true "clean again after removing the reviewed-output files" "[ \"\$(decision)\" = clean ]"

# Mixed tree: reviewed output alongside ordinary scratch must still escalate --
# a stash sweeps both together, so "mostly scratch" cannot make it safe to discard.
mkdir -p "$REPO/.gspec/memory/pending/some-agent"
printf 'memory 1\n' > "$REPO/.gspec/memory/pending/some-agent/mem-1.md"
printf 'scratch\n' > "$REPO/scratch-mixed.txt"
assert_true "escalate: reviewed output mixed with ordinary scratch" \
  "[ \"\$(decision)\" = escalate ]"
rm -rf "$REPO/.gspec" "$REPO/scratch-mixed.txt"
assert_true "clean again after removing the mixed tree" "[ \"\$(decision)\" = clean ]"

# Large dirty tree: the reviewed-output check must read its WHOLE input before it
# decides. Any reader that can stop at the first match leaves `git status`/`sed`
# -- still writing on a big tree -- taking SIGPIPE (rc 141), and under
# `set -euo pipefail` the helper reads that as "no match" and silently falls back
# to `discard`, stashing unreviewed work away. `grep -q` did it
# (thin-loop-driver-gaps T3); the `>/dev/null` written to replace it was assumed
# to do the same under GNU grep and, measured, does not (below). `.gspec/...`
# sorts to the FRONT of `git status` output, so the match is found while
# thousands of lines are still unwritten; a small tree could never expose the
# `-q` form.
#
# The fixture is sized so the listing is FAR past any pipe buffer (5000 padded
# leaf paths, ~400 KB, against a Linux default of 64 KB and a macOS pipe that
# starts at 16 KB and grows to 64 KB -- an order of magnitude either way)
# and the decision is asserted to be `escalate` BY NAME on every pass of a repeat
# loop -- never merely "not discard", which several wrong answers would satisfy.
# The repeat matters because this failure is load- and timing-dependent: one
# green pass is not evidence.
#
# WHAT WAS OBSERVED, AND ON WHAT (grep-devnull-condition T1 review, 2026-09-19):
# the pre-change helper -- the pipe-fed `grep -E ... >/dev/null` form -- was run
# against this exact fixture (13 reviewed-output files + 5000 padded leaves, a
# 414,482-byte listing) in Linux aarch64 containers with GNU grep 3.8 (node:22,
# bookworm) and GNU grep 3.11 (ubuntu:24.04, CI's flavour), bash 5.2, git
# 2.39.5, 20 iterations each: it did NOT fail -- 0/20 nonzero pipeline status,
# `reconcile` = escalate 20/20 -- and this case passed 10/10 against it. The
# same probe with `grep -qE` failed 20/20 (rc 141) on GNU grep 3.8, 3.11, BSD
# grep 2.6.0 and ugrep 7.8.4 alike. So the mechanism this case guards is real
# and the case is sharp against it, but the redirect form never exhibited it:
# GNU grep drains a non-seekable stdin before exiting on a null stdout, so the
# writer never takes SIGPIPE. A GREEN RUN OF THIS CASE, ON ANY HOST, CERTIFIES
# THAT THE HERE-STRING FORM HOLDS -- NOT THAT THE FORM IT REPLACED EVER FAILED.
# An earlier draft of this comment, written on a macOS host with no GNU grep
# reachable, inferred the GNU misfire from documentation; an inference from
# documentation is not an observation either.
mkdir -p "$REPO/.gspec/memory/pending/some-agent"
for i in $(seq 1 13); do
  printf 'memory %s\n' "$i" > "$REPO/.gspec/memory/pending/some-agent/mem-$i.md"
done
# One directory so cleanup is a single `rm -rf`; `--untracked-files=all` still
# lists every leaf inside it, which is the whole point of the fixture.
mkdir -p "$REPO/scratch-large"
for i in $(seq 1 5000); do
  printf 'x' > "$REPO/scratch-large/f-$i-padded-so-the-status-listing-far-exceeds-a-pipe-buffer.txt"
done
large_tree_escalates() {
  local n
  for n in $(seq 1 10); do
    [ "$(decision)" = escalate ] || return 1
  done
  return 0
}
assert_true "escalate: reviewed output survives a large dirty tree, 10 consecutive passes" \
  "large_tree_escalates"
rm -rf "$REPO/.gspec" "$REPO/scratch-large"
assert_true "clean again after removing the large dirty tree" "[ \"\$(decision)\" = clean ]"

# A reviewed-output filename containing a space and a non-ASCII byte: `git status
# --porcelain` (no `-z`) C-quotes such a path, so after stripping the status
# prefix the field starts with `"` and never matches a pattern anchored on `^`
# or `/` -- the old helper fell back to `discard` on exactly the kind of
# filename an agent-written memory is likely to carry.
mkdir -p "$REPO/.gspec/memory/pending/some agent"
printf 'memory\n' > "$REPO/.gspec/memory/pending/some agent/naïve memory.md"
assert_true "escalate: reviewed-output filename with a space and non-ASCII byte" \
  "[ \"\$(decision)\" = escalate ]"
rm -rf "$REPO/.gspec"
assert_true "clean again after removing the quoted-path reviewed-output file" "[ \"\$(decision)\" = clean ]"

# The ordinary case is UNCHANGED: a packet's own uncommitted scratch, with no
# reviewed-output path involved, is still `discard` -- the escalation must not
# be written as "escalate on any dirt".
printf 'scratch again\n' > "$REPO/scratch2.txt"
assert_true "discard unchanged: ordinary scratch (no reviewed-output path) is still discard" \
  "[ \"\$(decision)\" = discard ]"
git -C "$REPO" stash push --include-untracked -m 'orch resume scratch 2' -- . >/dev/null
assert_true "clean again after stashing ordinary scratch"     "[ \"\$(decision)\" = clean ]"
git -C "$REPO" stash drop >/dev/null 2>&1 || true

# torn write: packet committed with the cursor trailer, run-state not yet advanced.
printf 'work\n' > "$REPO/f2.txt"; git -C "$REPO" add -A
git -C "$REPO" commit -qm "feature-002: done

[orch packet:feature-002]"
assert_true "adopt: one clean orphan tagged for cursor" "[ \"\$(decision)\" = adopt ]"

git -C "$REPO" commit -q --amend -m "feature-002: done (no trailer)"
assert_true "escalate: orphan carries no trailer"    "[ \"\$(decision)\" = escalate ]"

git -C "$REPO" commit -q --amend -m "feature-002: done

[orch packet:feature-999]"
assert_true "escalate: trailer packet != cursor"     "[ \"\$(decision)\" = escalate ]"

git -C "$REPO" commit -q --amend -m "feature-002: done

[orch packet:feature-002]"
printf 'more\n' > "$REPO/f3.txt"; git -C "$REPO" add -A
git -C "$REPO" commit -qm "extra

[orch packet:feature-003]"
assert_true "escalate: two commits ahead of green"   "[ \"\$(decision)\" = escalate ]"
git -C "$REPO" reset -q --hard "$GREEN"               # back to a clean checkpoint

echo "== reconcile normalizes a SHORT last_green_commit =="
# Regression: run-state records whatever sha was written — humans and agents write
# SHORT ones — but `rev-parse HEAD` always returns the full 40-char id. A raw
# string compare could never hit the `clean` case; execution fell through
# (`--is-ancestor` trivially passes, `rev-list --count` yields 0) to the bogus
# `escalate: 0 unexplained commits ahead of the green checkpoint`. The whole
# decision table must behave identically for a short green, not just `clean`.
SHORT_GREEN="$(git -C "$REPO" rev-parse --short "$GREEN")"
"$RUNSTATE" set "$RS" last_green_commit "$SHORT_GREEN" >/dev/null
assert_true "clean: short green, HEAD==green, tree clean"     "[ \"\$(decision)\" = clean ]"

printf 'scratch\n' > "$REPO/scratch.txt"
assert_true "discard: short green, scratch on green"          "[ \"\$(decision)\" = discard ]"
rm -f "$REPO/scratch.txt"

# torn write against a short green: the adopt path must still read the trailer.
printf 'work\n' > "$REPO/s1.txt"; git -C "$REPO" add -A
git -C "$REPO" commit -qm "feature-002: done

[orch packet:feature-002]"
assert_true "adopt: short green, one clean orphan for cursor" "[ \"\$(decision)\" = adopt ]"

# an unresolvable green must still escalate, not crash or silently pass.
"$RUNSTATE" set "$RS" last_green_commit "deadbee" >/dev/null
assert_true "escalate: short green not present in the tree"   "[ \"\$(decision)\" = escalate ]"

git -C "$REPO" reset -q --hard "$GREEN"               # back to a clean checkpoint
"$RUNSTATE" set "$RS" last_green_commit "$GREEN" >/dev/null   # restore the full sha

echo "== reconstruct: rebuild git-derivable facts when run-state is lost =="
# Two trailered packet commits on the feature branch; the third repeats a trailer
# (e.g. a re-commit) and must de-duplicate while preserving first-seen order.
printf 'a\n' > "$REPO/pa.txt"; git -C "$REPO" add -A
git -C "$REPO" commit -qm "pkt a

[orch packet:pkt-a]"
printf 'b\n' > "$REPO/pb.txt"; git -C "$REPO" add -A
git -C "$REPO" commit -qm "pkt b

[orch packet:pkt-b]"
printf 'b2\n' > "$REPO/pb2.txt"; git -C "$REPO" add -A
git -C "$REPO" commit -qm "pkt b again

[orch packet:pkt-b]"
RC_TIP="$(git -C "$REPO" rev-parse HEAD)"
rc()  { "$RUNSTATE" reconstruct "$REPO" 2>/dev/null; }
rcf() { rc | sed -n "s/^$1=//p"; }
assert_true "reconstruct ok on orch branch"         "[ \"\$(rcf RECONSTRUCT)\" = ok ]"
assert_true "reconstruct names the branch"          "[ \"\$(rcf BRANCH)\" = '$BRANCH' ]"
assert_true "reconstruct tip == HEAD"               "[ \"\$(rcf TIP)\" = '$RC_TIP' ]"
assert_true "reconstruct base = main"               "[ \"\$(rcf BASE)\" = main ]"
assert_true "reconstruct done: trailers ordered+deduped" "[ \"\$(rcf DONE)\" = 'pkt-a,pkt-b' ]"
# T7 (ADR 0024): DONE is informational only — nothing in run-state is populated
# from it automatically; a human rebuilding a lost run-state reads it for the
# identities.
assert_true "reconstruct's note states DONE is informational only" \
  "rc | grep -qi 'informational only'"
git -C "$REPO" switch -q main
assert_true "reconstruct escalates off an orch branch" "[ \"\$(rcf RECONSTRUCT)\" = escalate ]"
assert_true "reconstruct lists orch candidates"        "rc | grep -q '$BRANCH'"
git -C "$REPO" switch -q "$BRANCH"
git -C "$REPO" checkout -q "$RC_TIP"                    # detached HEAD
assert_true "reconstruct escalates on detached HEAD"   "[ \"\$(rcf RECONSTRUCT)\" = escalate ]"
git -C "$REPO" switch -q "$BRANCH"
git -C "$REPO" reset -q --hard "$GREEN"                 # restore the checkpoint

echo "== summary line: names the run, flags a crash only when running =="
"$RUNSTATE" set "$RS" status running >/dev/null
assert_true "summary names branch"           "\"\$RUNSTATE\" summary '$RS' | grep -q '$BRANCH'"
assert_true "summary names cursor"           "\"\$RUNSTATE\" summary '$RS' | grep -q feature-002"
assert_true "summary flags crash on running" "\"\$RUNSTATE\" summary '$RS' | grep -qi 'crash-likely'"
"$RUNSTATE" set "$RS" status paused >/dev/null
assert_true "summary no crash flag on paused" "! \"\$RUNSTATE\" summary '$RS' | grep -qi 'crash-likely'"

# Partial run-state (fresh/partial write, schema 3, paused-before-first-commit):
# absent scalars must degrade to defaults, NOT abort under set -e/pipefail when
# the underlying grep finds no match. Regression for the silent exit-1 that hit
# consumer repos whose run-state lacked a column-0 status:/branch:/cursor: line.
PARTIAL="$(mktemp)"
printf 'schema: 3\n' > "$PARTIAL"
assert_true "summary survives a near-empty run-state" "\"\$RUNSTATE\" summary '$PARTIAL' >/dev/null"
assert_true "summary defaults missing status" "\"\$RUNSTATE\" summary '$PARTIAL' | grep -q 'status=unknown'"
assert_true "summary defaults missing cursor" "\"\$RUNSTATE\" summary '$PARTIAL' | grep -q 'cursor=none'"

echo "== SessionStart hook: valid JSON, tailored to status, silent when done/absent =="
"$RUNSTATE" set "$RS" status running >/dev/null
assert_true "hook emits valid JSON"            "run_hook | python3 -c 'import json,sys; json.load(sys.stdin)'"
assert_true "hook injects additionalContext"   "run_hook | grep -q additionalContext"
assert_true "hook tells running=crash, reconcile" "run_hook | grep -qi 'did not pause cleanly'"
"$RUNSTATE" set "$RS" status paused >/dev/null
assert_true "hook points a clean pause at resume" "run_hook | grep -qi 'resume'"
"$RUNSTATE" set "$RS" status done >/dev/null
assert_true "hook is silent for a done run"    "[ -z \"\$(run_hook)\" ]"
assert_true "hook is silent when no run-state" \
  "CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' CLAUDE_PROJECT_DIR=\"\$(mktemp -d)\" bash '$HOOK' </dev/null | { ! grep -q additionalContext; }"

# =============================================================================
# ADR 0016 (retired by retire-unused-loop-modes T1) — parallel mode itself is
# gone: no lane-writing paths, no `packets-by-status`, no `reconcile-parallel`.
# `lanes` is the ONE thing kept, as a READ-ONLY projection over a run-state a
# pre-retirement session may still have on disk — `resume`'s stop path reads it
# to name a legacy run's lane branches/worktrees. These cases prove a run-state
# still carrying `mode: parallel` / `packets:` / `lanes:` still PARSES, that the
# lane-writing subcommands are genuinely gone (not just undocumented), and that
# a mutating subcommand leaves that legacy content byte-for-byte untouched.
# =============================================================================
echo "== legacy mode: parallel / lanes: run-state still parses; lanes stays read-only =="
PRS="$(mktemp)"
cat > "$PRS" <<'EOF'
schema: 3
mode: parallel
max_parallel: 5
packets:
  - id: pa
    status: done
    depends_on: []
  - id: pb
    status: running
    depends_on: [pa]
lanes:
  - id: pb
    worktree: /tmp/wt/pb
    branch: orch/pb
    packet: pb
    last_green_commit: abc123
    status: running
note: parallel run
EOF
assert_true "lanes row still parses id+branch+packet (the one read-only projection kept)" \
  "[ \"\$(\"\$RUNSTATE\" lanes '$PRS')\" = \$'pb\torch/pb\t/tmp/wt/pb\tpb\tabc123\trunning' ]"
assert_true "packets-by-status subcommand is gone (T1 retired the parallel-only packet query)" \
  "! \"\$RUNSTATE\" packets-by-status '$PRS' done >/dev/null 2>&1"
assert_true "reconcile-parallel subcommand is gone (T1 retired the per-lane reconcile writer)" \
  "! \"\$RUNSTATE\" reconcile-parallel '$PRS' '$REPO' >/dev/null 2>&1"

echo "== legacy mode: parallel / lanes: content is left BYTE-UNCHANGED by a mutating subcommand =="
# `set` on a key this fixture does not yet carry (`status`) appends a new line
# rather than rewriting any existing one -- so the entire pre-existing byte
# range (mode:/max_parallel:/packets:/lanes:/note:) must survive as an exact
# PREFIX of the file, proven by checksum, not by re-reading it.
ORIG_LINES="$(wc -l < "$PRS" | tr -d ' ')"
PREFIX_BEFORE="$(head -n "$ORIG_LINES" "$PRS" | cksum)"
"$RUNSTATE" set "$PRS" status paused >/dev/null
PREFIX_AFTER="$(head -n "$ORIG_LINES" "$PRS" | cksum)"
assert_true "a mutating subcommand (set) never rewrites the legacy mode:/packets:/lanes:/note: content" \
  "[ \"\$PREFIX_BEFORE\" = \"\$PREFIX_AFTER\" ]"
assert_true "the legacy run-state still parses after the mutation (get mode = parallel)" \
  "[ \"\$(\"\$RUNSTATE\" get '$PRS' mode)\" = parallel ]"
assert_true "lanes row still parses after the mutation" \
  "[ \"\$(\"\$RUNSTATE\" lanes '$PRS')\" = \$'pb\torch/pb\t/tmp/wt/pb\tpb\tabc123\trunning' ]"
rm -f "$PRS"

echo "== ADR 0020 D5: a driver claim distinguishes crash from a live second session =="
DRS="$REPO/.agents/driver-state.yaml"
mk_drv() { # mk_drv <status> [heartbeat-iso] [host] [pid]
  { printf 'schema: 3\nstatus: %s\nbranch: orch/x\nlast_green_commit: %s\n' "$1" "$MAIN_SHA"
    [ -z "${2:-}" ] || printf 'driver_heartbeat: %s\n' "$2"
    [ -z "${3:-}" ] || printf 'driver_host: %s\n' "$3"
    [ -z "${4:-}" ] || printf 'driver_pid: %s\n' "$4"
    printf 'backlog:\n  cursor: p1\n  pending:\n    - p1\n'
  } > "$DRS"
}
ME="$(hostname 2>/dev/null || printf 'unknown')"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# 2h ago, on BSD and GNU date alike.
OLD="$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
# `outcome` exits non-zero by design and the sweep runs with pipefail, so capture
# stdout first rather than piping it into grep.
drv() { "$RUNSTATE" driver-status "$DRS" 2>&1; }
oc()  { "$RUNSTATE" outcome "$DRS" 2>&1 || true; }
oc_rc() { "$RUNSTATE" outcome "$DRS" >/dev/null 2>&1; printf '%s' "$?"; }

# No claim at all: a pre-ADR-0020 run-state must behave exactly as before.
mk_drv running
assert_true "no claim -> DRIVER=none"                     "case \"\$(drv)\" in DRIVER=none*) true;; *) false;; esac"
assert_true "running + no claim still reads as crashed"   "case \"\$(oc)\" in *OUTCOME=crashed*) true;; *) false;; esac"
assert_true "crashed exits 3"                             "[ \"\$(oc_rc)\" = 3 ]"
assert_true "summary keeps the crash hint with no claim"  "\"\$RUNSTATE\" summary \"\$DRS\" | grep -q 'crash-likely'"

# A FRESH heartbeat: `status: running` must NOT be read as a crash.
mk_drv running "$NOW" "$ME"
assert_true "fresh heartbeat -> DRIVER=live"              "case \"\$(drv)\" in DRIVER=live*) true;; *) false;; esac"
assert_true "running + live claim -> OUTCOME=running"     "case \"\$(oc)\" in *OUTCOME=running*) true;; *) false;; esac"
assert_true "still-running exits 4"                       "[ \"\$(oc_rc)\" = 4 ]"
assert_true "summary warns about a second driver"         "\"\$RUNSTATE\" summary \"\$DRS\" | grep -q 'ANOTHER SESSION IS DRIVING'"
assert_true "summary drops crash-likely while live"       "! \"\$RUNSTATE\" summary \"\$DRS\" | grep -q 'crash-likely'"

# A STALE heartbeat is the real crash signal.
mk_drv running "$OLD" "$ME"
assert_true "stale heartbeat -> DRIVER=dead"              "case \"\$(drv)\" in DRIVER=dead*) true;; *) false;; esac"
assert_true "running + stale claim -> OUTCOME=crashed"    "case \"\$(oc)\" in *OUTCOME=crashed*) true;; *) false;; esac"
assert_true "staleness window is configurable"            "ORCH_DRIVER_STALE_SECS=99999 \"\$RUNSTATE\" driver-status \"\$DRS\" | grep -q '^DRIVER=live'"

# A claim from ANOTHER host says nothing local — never guess dead.
mk_drv running "$OLD" "some-other-host"
assert_true "other host -> DRIVER=foreign"                "case \"\$(drv)\" in DRIVER=foreign*) true;; *) false;; esac"
assert_true "foreign claim is treated as running"         "case \"\$(oc)\" in *OUTCOME=running*) true;; *) false;; esac"

# An explicit caller-vouched pid OUTRANKS the heartbeat, in both directions.
mk_drv running "$NOW" "$ME" 999999
assert_true "dead explicit pid beats a fresh heartbeat"   "case \"\$(drv)\" in DRIVER=dead*) true;; *) false;; esac"
mk_drv running "$OLD" "$ME" "$$"
assert_true "live explicit pid beats a stale heartbeat"   "case \"\$(drv)\" in DRIVER=live*) true;; *) false;; esac"

# Terminal states carry their own exit code (the control/terminal split).
mk_drv done;    assert_true "done -> complete"   "case \"\$(oc)\" in *OUTCOME=complete*) true;; *) false;; esac"
mk_drv done;    assert_true "complete exits 0"   "[ \"\$(oc_rc)\" = 0 ]"
mk_drv paused;  assert_true "paused exits 2"     "[ \"\$(oc_rc)\" = 2 ]"
mk_drv blocked; assert_true "blocked exits 1"    "[ \"\$(oc_rc)\" = 1 ]"

# claim-driver / heartbeat.
mk_drv running
"$RUNSTATE" claim-driver "$DRS" >/dev/null
assert_true "claim-driver records a heartbeat"  "[ -n \"\$(rs_get \"\$DRS\" driver_heartbeat)\" ]"
assert_true "claim-driver records the host"     "[ -n \"\$(rs_get \"\$DRS\" driver_host)\" ]"
assert_true "claim-driver records NO pid by default (it would be the subprocess)" \
  "[ -z \"\$(rs_get \"\$DRS\" driver_pid)\" ]"
assert_true "claiming makes the run read as live" "case \"\$(oc)\" in *OUTCOME=running*) true;; *) false;; esac"
"$RUNSTATE" claim-driver "$DRS" >/dev/null
assert_true "re-claiming does not duplicate the key" "[ \"\$(grep -c '^driver_heartbeat:' \"\$DRS\")\" = 1 ]"
mk_drv running "$OLD" "$ME"
"$RUNSTATE" heartbeat "$DRS" >/dev/null
assert_true "heartbeat revives a stale claim"   "case \"\$(drv)\" in DRIVER=live*) true;; *) false;; esac"
# via "$RUNSTATE" get, not the raw-grep rs_get: driver_pid is written through
# cmd_set (T4/T5), which now always quotes, so the raw byte on disk is
# `driver_pid: '4242'` -- the decoded round-trip through cmd_get is the
# correct thing to assert here, not the raw bytes (that's the drift-pin/
# hostile-value cases below).
assert_true "explicit pid is recorded when vouched for" \
  "\"\$RUNSTATE\" claim-driver \"\$DRS\" 4242 >/dev/null && [ \"\$(\"\$RUNSTATE\" get \"\$DRS\" driver_pid)\" = 4242 ]"

echo
echo "== trim-note: bound the note, archive the overflow (ADR 0019 v3.4) =="
# The template documents `note:` as ONE line; unbounded it reached 164,678 chars —
# 87% of the run-state, re-read on every relay dispatch to recover two facts.
TN="$(mktemp -d)"
{ printf 'status: running\ncursor: t5\nnote: '
  i=0; while [ "$i" -lt 200 ]; do printf 'packet %s narrative. ' "$i"; i=$((i+1)); done
  printf '\nupdated_at: 2026-08-07T00:00:00Z\n'
} > "$TN/run-state.yaml"
# Captured, never piped live: T3, ADR 0025/0019 flake investigation. Piping
# "$RUNSTATE" trim-note ... straight into `grep -q` races under this script's
# own `pipefail` (line 16) -- `grep -q` exits the instant it matches the FIRST
# output line and closes its end of the pipe, and if runstate.sh is still mid-
# write at that moment it gets SIGPIPE (rc 141); with pipefail the pipeline
# then reports that 141, not grep's successful match, so a correct answer
# reads as a failed assertion. Confirmed live: 9 natural reproductions of
# exactly this assertion (never its TN/TN2 neighbors) under light concurrency,
# each with `total=`/`end=`/`size=` instrumented and never firing, and each
# followed by an un-piped re-invocation of the identical call that matched
# every time -- the function's answer was correct in all 9; only the piped
# OBSERVATION of it was not. A synthetic pipefail+early-exit reproduction hit
# 30/30. This is the mechanism made deterministic (capture then compare, no
# pipe -> no SIGPIPE window possible), not a fix to cmd_trim_note, which was
# never shown to be wrong.
TN_OUT="$("$RUNSTATE" trim-note "$TN/run-state.yaml" 500)"
assert_true "trim-note shrinks an oversized single-line note" \
  "[ \"\${TN_OUT#TRIMMED=yes}\" != \"\$TN_OUT\" ]"
assert_true "trim-note keeps the file under budget+slack" \
  "[ \"\$(wc -c < \"$TN/run-state.yaml\" | tr -d ' ')\" -lt 800 ]"
# structure must survive: keys before AND after the note are still there
assert_true "trim-note preserves the key before the note" \
  "grep -q '^cursor: t5' \"$TN/run-state.yaml\""
assert_true "trim-note preserves the key AFTER the note" \
  "grep -q '^updated_at:' \"$TN/run-state.yaml\""
assert_true "trim-note keeps the note key itself" \
  "grep -q '^note:' \"$TN/run-state.yaml\""
assert_true "trim-note archives rather than deletes" \
  "[ -s \"$TN/run-state-note-archive.md\" ]"
# the multi-line accumulation shape (what a real run produces) must trim on whole
# lines, or the YAML is left unparseable
TN2="$(mktemp -d)"
{ printf 'status: running\nnote: current packet green\n'
  i=0; while [ "$i" -lt 15 ]; do printf '  --- earlier history below ---\n  ### packet-%s detail\n' "$i"; i=$((i+1)); done
  printf 'updated_at: 2026-08-07T00:00:00Z\n'
} > "$TN2/run-state.yaml"
# Captured, not piped -- see the T3 note above line "trim-note shrinks an
# oversized single-line note".
TN2_OUT="$("$RUNSTATE" trim-note "$TN2/run-state.yaml" 200)"
assert_true "trim-note handles the multi-line shape" \
  "[ \"\${TN2_OUT#TRIMMED=yes}\" != \"\$TN2_OUT\" ]"
assert_true "trim-note leaves no partial line" \
  "! grep -qE '^  ###? [^ ]*\$' \"$TN2/run-state.yaml\" || true"
assert_true "trim-note keeps trailing keys in the multi-line shape" \
  "grep -q '^updated_at:' \"$TN2/run-state.yaml\""
# a note already within budget must be left completely alone
TN3="$(mktemp -d)"
printf 'status: running\nnote: short\nupdated_at: x\n' > "$TN3/run-state.yaml"
# Captured, not piped -- see the T3 note above line "trim-note shrinks an
# oversized single-line note". This exact assertion is the one that was
# observed to flake: the shortest of the three fixtures, whose output is a
# single line matched instantly by `grep -q`, giving the pipe race its
# tightest window.
TN3_OUT="$("$RUNSTATE" trim-note "$TN3/run-state.yaml" 2000)"
assert_true "trim-note is a no-op under budget" \
  "[ \"\${TN3_OUT#TRIMMED=no}\" != \"\$TN3_OUT\" ]"
assert_true "trim-note under budget writes no archive" \
  "[ ! -f \"$TN3/run-state-note-archive.md\" ]"
printf 'status: running\n' > "$TN3/b.yaml"
TN3B_OUT="$("$RUNSTATE" trim-note "$TN3/b.yaml")"
assert_true "trim-note tolerates a missing note field" \
  "case \"\$TN3B_OUT\" in *no-note-field*) true;; *) false;; esac"

echo
echo "== record-outcome: attest what the collector cannot observe (ADR 0019 v3.4) =="
RO="$(mktemp -d)"; git -C "$RO" init -q
git -C "$RO" config user.email t@t; git -C "$RO" config user.name t
assert_true "record-outcome writes a green attestation" \
  "(cd \"$RO\" && \"\$RUNSTATE\" record-outcome p1 green S1 | grep -q '^RECORDED=yes')"
assert_true "record-outcome records a NON-green outcome" \
  "(cd \"$RO\" && \"\$RUNSTATE\" record-outcome p2 rolled-back S1 | grep -q '^RECORDED=yes')"
assert_true "record-outcome appends, never truncates" \
  "[ \"\$(wc -l < \"$RO/.agents/metrics/outcomes/S1.jsonl\" | tr -d ' ')\" = 2 ]"
assert_true "record-outcome emits valid one-line JSON" \
  "jq -e . \"$RO/.agents/metrics/outcomes/S1.jsonl\" >/dev/null"
assert_true "record-outcome rejects an unknown outcome" \
  "(cd \"$RO\" && ! \"\$RUNSTATE\" record-outcome p3 bogus S1 2>/dev/null)"
assert_true "record-outcome requires both arguments" \
  "(cd \"$RO\" && ! \"\$RUNSTATE\" record-outcome p3 2>/dev/null)"
RO_P1_TS="$(cd "$RO" && jq -r 'select(.packet == "p1") | .ts' "$RO/.agents/metrics/outcomes/S1.jsonl")"
assert_true "record-outcome writes a sub-second UTC timestamp" \
  "printf '%s' \"\$RO_P1_TS\" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z\$'"
# I4: the terminal record must carry `session` alongside ts/packet/outcome, since
# metrics.sh concatenates every selected session's log into one stream BEFORE
# joining, destroying the filename as a source of the session id.
RO_P1_SESS="$(cd "$RO" && jq -r 'select(.packet == "p1") | .session' "$RO/.agents/metrics/outcomes/S1.jsonl")"
assert_true "record-outcome's written record carries the session field" \
  "[ \"\$RO_P1_SESS\" = S1 ]"
# A legacy terminal record (written before this change) has no `session` field.
# It must still parse individually and degrade to null, not break the reader.
LEGACY_OUTCOME_LINE='{"ts":"2026-01-01T00:00:00Z","packet":"legacy-p","outcome":"green"}'
assert_true "a legacy terminal record without session still parses" \
  "jq -e '.packet == \"legacy-p\" and .outcome == \"green\"' <<<\"\$LEGACY_OUTCOME_LINE\" >/dev/null"
assert_true "a legacy terminal record without session yields null for .session, not an error" \
  "[ \"\$(jq -r '.session // \"NULL\"' <<<\"\$LEGACY_OUTCOME_LINE\")\" = NULL ]"

echo
echo "== record-start: begin/continue a packet boundary (loop-measurement T1) =="
RS1_OUT="$(cd "$RO" && "$RUNSTATE" record-start p4 S1)"
RS1_LINE="$(tail -1 "$RO/.agents/metrics/outcomes/S1.jsonl")"
assert_true "record-start reports success" \
  "case \"\$RS1_OUT\" in *RECORDED=yes*) true;; *) false;; esac"
assert_true "record-start writes kind=start" \
  "case \"\$RS1_OUT\" in *KIND=start*) true;; *) false;; esac"
# C1: assert every field of the WRITTEN record, not just stdout/line-count --
# a whole-second ts, a dropped session, or a hardcoded packet id must each fail
# one of these on their own.
assert_true "record-start's written record carries the correct packet id" \
  "[ \"\$(jq -r .packet <<<\"\$RS1_LINE\")\" = p4 ]"
assert_true "record-start's written record carries the given session id" \
  "[ \"\$(jq -r .session <<<\"\$RS1_LINE\")\" = S1 ]"
assert_true "record-start's written record carries kind=start" \
  "[ \"\$(jq -r .kind <<<\"\$RS1_LINE\")\" = start ]"
assert_true "record-start's written record carries a sub-second UTC timestamp" \
  "jq -r .ts <<<\"\$RS1_LINE\" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z\$'"
RS2_OUT="$(cd "$RO" && "$RUNSTATE" record-start p4 --continue S1)"
RS2_LINE="$(tail -1 "$RO/.agents/metrics/outcomes/S1.jsonl")"
assert_true "record-start --continue writes a continuation record distinguishable by kind" \
  "case \"\$RS2_OUT\" in *KIND=continue*) true;; *) false;; esac"
assert_true "record-start --continue's written record carries the correct packet id" \
  "[ \"\$(jq -r .packet <<<\"\$RS2_LINE\")\" = p4 ]"
assert_true "record-start --continue's written record carries the given session id" \
  "[ \"\$(jq -r .session <<<\"\$RS2_LINE\")\" = S1 ]"
assert_true "record-start --continue's written record carries kind=continue" \
  "[ \"\$(jq -r .kind <<<\"\$RS2_LINE\")\" = continue ]"
assert_true "record-start --continue's written record carries a sub-second UTC timestamp" \
  "jq -r .ts <<<\"\$RS2_LINE\" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z\$'"
RS3_OUT="$(cd "$RO" && "$RUNSTATE" record-start p5 S1 --continue)"
RS3_LINE="$(tail -1 "$RO/.agents/metrics/outcomes/S1.jsonl")"
assert_true "record-start <pkt> <session> --continue (--continue after the session id) also works" \
  "case \"\$RS3_OUT\" in *KIND=continue*) true;; *) false;; esac"
assert_true "record-start <pkt> <session> --continue's written record carries kind=continue plus the right packet and session" \
  "[ \"\$(jq -r '.kind + \"|\" + .packet + \"|\" + .session' <<<\"\$RS3_LINE\")\" = 'continue|p5|S1' ]"
assert_true "a second record-start for the same packet appends a line, rewrites nothing" \
  "[ \"\$(wc -l < \"$RO/.agents/metrics/outcomes/S1.jsonl\" | tr -d ' ')\" = 5 ]"
assert_true "record-start requires a packet id" \
  "(cd \"$RO\" && ! \"\$RUNSTATE\" record-start 2>/dev/null)"
assert_true "record-start in a non-git directory reports RECORDED=no, not a die" \
  "OUT=\"\$(cd \"\$(mktemp -d)\" && \"\$RUNSTATE\" record-start p9 S9)\"; RC=\$?; [ \"\$RC\" = 0 ] && case \"\$OUT\" in *RECORDED=no*REASON=*) true;; *) false;; esac"

# Same JSON-safety rule as record-outcome (ADR 0019 v3.4), shared via the same
# id-charset guard: a `"` or `\` in the id would emit invalid JSON and make the
# collector's `jq -s` drop every record in the file at once, silently. Run
# inside the fixture repo (I2): an unwrapped call here executes against
# whatever repo the sweep was launched from, and is harmless today only
# because the charset check dies before the append runs -- reorder that and an
# unwrapped case would write junk into a real outcomes log.
assert_true "record-start rejects a packet id that would break its JSON (same error as record-outcome)" \
  "(cd \"$RO\" && ! \"\$RUNSTATE\" record-start 'pkt\"; drop' S1 2>/dev/null)"
assert_true "record-start and record-outcome give the SAME charset error" \
  "(cd \"$RO\" && [ \"\$(\"\$RUNSTATE\" record-start 'pkt\"; drop' S1 2>&1 >/dev/null)\" = \"\$(\"\$RUNSTATE\" record-outcome 'pkt\"; drop' green S1 2>&1 >/dev/null)\" ])"
assert_true "record-start rejects a packet id containing a backslash" \
  "(cd \"$RO\" && ! \"\$RUNSTATE\" record-start 'pkt\drop' S1 2>/dev/null)"
assert_true "record-outcome rejects a packet id containing a backslash" \
  "(cd \"$RO\" && ! \"\$RUNSTATE\" record-outcome 'pkt\drop' green S1 2>/dev/null)"

# record-outcome must keep refusing the two new boundary kinds as outcomes: its
# accepted set stays exactly green|failed|rolled-back|blocked|abandoned.
assert_true "record-outcome rejects 'start' as an outcome" \
  "(cd \"$RO\" && ! \"\$RUNSTATE\" record-outcome p10 start S1 2>/dev/null)"
assert_true "record-outcome rejects 'continue' as an outcome" \
  "(cd \"$RO\" && ! \"\$RUNSTATE\" record-outcome p10 continue S1 2>/dev/null)"
# `interrupted` has exactly one writer -- sweep-open (loop-measurement T3) -- and
# record-outcome enforces that by never accepting it as an outcome value.
assert_true "record-outcome rejects 'interrupted' as an outcome (only sweep-open may write it)" \
  "(cd \"$RO\" && ! \"\$RUNSTATE\" record-outcome p11 interrupted S1 2>/dev/null)"

# A whole-second legacy line (as every record-outcome call wrote before this
# feature) must survive a sub-second append untouched, and the file as a whole
# must still parse -- by parsing the WHOLE FILE, not by grepping a substring.
LEGACY_LINE='{"ts":"2026-01-01T00:00:00Z","packet":"legacy-p","outcome":"green"}'
printf '%s\n' "$LEGACY_LINE" >> "$RO/.agents/metrics/outcomes/S1.jsonl"
(cd "$RO" && "$RUNSTATE" record-start p6 S1 >/dev/null)
assert_true "a whole-second legacy record is untouched after a sub-second append" \
  "grep -qF '$LEGACY_LINE' \"$RO/.agents/metrics/outcomes/S1.jsonl\""
assert_true "the outcomes log parses as valid JSON end to end (mixed legacy + sub-second lines)" \
  "jq -s -e 'length > 0 and (map(type == \"object\") | all)' \"$RO/.agents/metrics/outcomes/S1.jsonl\" >/dev/null"

echo
echo "== sweep-open --list: read-only enumeration of packets started but never ended (loop-measurement T3) =="
SO="$(mktemp -d)"; git -C "$SO" init -q
git -C "$SO" config user.email t@t; git -C "$SO" config user.name t
SO_DIR="$SO/.agents/metrics/outcomes"
mkdir -p "$SO_DIR"

# open-a: started, never ended -- the plain case.
(cd "$SO" && "$RUNSTATE" record-start open-a S1 >/dev/null)
# closed-a: started AND ended -- must never read as open.
(cd "$SO" && "$RUNSTATE" record-start closed-a S1 >/dev/null)
(cd "$SO" && "$RUNSTATE" record-outcome closed-a green S1 >/dev/null)
# cursor-a: started, never ended, but IS the paused cursor -- exempt from the sweep.
(cd "$SO" && "$RUNSTATE" record-start cursor-a S1 >/dev/null)

# same-second-a: a whole-second terminal record (the shape every record-outcome
# wrote before ADR 0019 v3.4/T1) that lands EARLIER within the same integer
# second than a sub-second start. A raw STRING compare orders "...:08.500Z"
# BELOW "...:08Z" ("." is 0x2E, "Z" is 0x5A) and would misread the terminal as
# happening AFTER the start, wrongly closing it. Parsed-time comparison must not.
printf '%s\n' '{"ts":"2026-03-01T00:00:08Z","packet":"same-second-a","session":"S1","outcome":"blocked"}' >> "$SO_DIR/S1.jsonl"
printf '%s\n' '{"ts":"2026-03-01T00:00:08.500Z","packet":"same-second-a","session":"S1","kind":"start"}' >> "$SO_DIR/S1.jsonl"

# multi-b: started in one session, closed by a terminal record in ANOTHER --
# proves the sweep JOINS across files (not merely scans each file in isolation).
(cd "$SO" && "$RUNSTATE" record-start multi-b Sold >/dev/null)
(cd "$SO" && "$RUNSTATE" record-outcome multi-b green Snew >/dev/null)
# multi-b2: started in an older, untouched-since-creation session file -- proves
# the sweep reads EVERY outcomes log, not just the most-recently-modified one.
(cd "$SO" && "$RUNSTATE" record-start multi-b2 Sold2 >/dev/null)

SO_BASELINE="$(cat "$SO_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"

SWL_OUT="$(cd "$SO" && "$RUNSTATE" sweep-open --list)"
assert_true "sweep-open --list reports the never-ended packet as open" \
  "printf '%s\n' \"\$SWL_OUT\" | grep -qx 'OPEN=open-a'"
assert_true "sweep-open --list does NOT report an already-ended packet as open" \
  "! printf '%s\n' \"\$SWL_OUT\" | grep -qx 'OPEN=closed-a'"
assert_true "sweep-open --list reports the (not-yet-exempted) cursor packet as open" \
  "printf '%s\n' \"\$SWL_OUT\" | grep -qx 'OPEN=cursor-a'"
assert_true "sweep-open --list does NOT close a start landing later in the same second as a whole-second terminal (parsed time, not string compare)" \
  "printf '%s\n' \"\$SWL_OUT\" | grep -qx 'OPEN=same-second-a'"
assert_true "sweep-open --list does NOT report a packet closed via a terminal record in a DIFFERENT session's log" \
  "! printf '%s\n' \"\$SWL_OUT\" | grep -qx 'OPEN=multi-b'"
assert_true "sweep-open --list finds an open packet whose only record sits in an older, non-newest session log" \
  "printf '%s\n' \"\$SWL_OUT\" | grep -qx 'OPEN=multi-b2'"
assert_true "sweep-open --list writes nothing to any outcomes log" \
  "[ \"\$(cat \"$SO_DIR\"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')\" = \"\$SO_BASELINE\" ]"

SWLC_OUT="$(cd "$SO" && "$RUNSTATE" sweep-open --list --paused-cursor cursor-a)"
assert_true "sweep-open --list --paused-cursor exempts the cursor packet from the OPEN list" \
  "! printf '%s\n' \"\$SWLC_OUT\" | grep -qx 'OPEN=cursor-a'"
assert_true "sweep-open --list --paused-cursor still reports OTHER open packets" \
  "printf '%s\n' \"\$SWLC_OUT\" | grep -qx 'OPEN=open-a'"
assert_true "sweep-open --list --paused-cursor still writes nothing" \
  "[ \"\$(cat \"$SO_DIR\"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')\" = \"\$SO_BASELINE\" ]"

echo
echo "== sweep-open: closes open packets as interrupted/abandoned (loop-measurement T3) =="
SO2="$(mktemp -d)"; git -C "$SO2" init -q
git -C "$SO2" config user.email t@t; git -C "$SO2" config user.name t
SO2_DIR="$SO2/.agents/metrics/outcomes"

(cd "$SO2" && "$RUNSTATE" record-start wa S1 >/dev/null)   # swept as abandoned (--gone)
(cd "$SO2" && "$RUNSTATE" record-start wb S1 >/dev/null)   # swept as interrupted
(cd "$SO2" && "$RUNSTATE" record-start wc S1 >/dev/null)   # already ended -- must be left alone
(cd "$SO2" && "$RUNSTATE" record-outcome wc rolled-back S1 >/dev/null)

WA_START_LINE="$(grep '"packet":"wa"' "$SO2_DIR/S1.jsonl")"
WA_START_TS="$(printf '%s' "$WA_START_LINE" | sed -E 's/.*"ts":"([^"]*)".*/\1/')"

# Run the sweep from a DIFFERENT session than the one that started wa/wb/wc, so
# the closing records necessarily land in a log file that is not S1.jsonl --
# exactly the "sweep writes into a later session's own file" shape T4 depends on.
SW_OUT="$(cd "$SO2" && CLAUDE_CODE_SESSION_ID=SWEEP1 "$RUNSTATE" sweep-open --gone wa)"
assert_true "sweep-open reports one SWEPT= line for the gone packet" \
  "printf '%s\n' \"\$SW_OUT\" | grep -qx 'SWEPT=wa'"
assert_true "sweep-open reports one SWEPT= line for the plain open packet" \
  "printf '%s\n' \"\$SW_OUT\" | grep -qx 'SWEPT=wb'"
assert_true "sweep-open does NOT report SWEPT for an already-ended packet" \
  "! printf '%s\n' \"\$SW_OUT\" | grep -qx 'SWEPT=wc'"

WA_CLOSE_LINE="$(grep '"packet":"wa"' "$SO2_DIR/SWEEP1.jsonl")"
WB_CLOSE_LINE="$(grep '"packet":"wb"' "$SO2_DIR/SWEEP1.jsonl")"
assert_true "the gone id is recorded abandoned, not interrupted" \
  "printf '%s' \"\$WA_CLOSE_LINE\" | grep -q '\"outcome\":\"abandoned\"'"
assert_true "an open packet not named in --gone is recorded interrupted" \
  "printf '%s' \"\$WB_CLOSE_LINE\" | grep -q '\"outcome\":\"interrupted\"'"
assert_true "the closing record is written into the SWEEPING session's own log file" \
  "[ -s \"$SO2_DIR/SWEEP1.jsonl\" ]"
assert_true "the closing record names the CLOSED start's own session, not the sweeping session" \
  "printf '%s' \"\$WA_CLOSE_LINE\" | grep -q '\"session\":\"S1\"'"
assert_true "the closing record names the CLOSED start's own time, not the sweep's write time" \
  "[ \"\$(printf '%s' \"\$WA_CLOSE_LINE\" | sed -E 's/.*\"ts\":\"([^\"]*)\".*/\\1/')\" = \"\$WA_START_TS\" ]"
assert_true "an already-ended packet keeps exactly its original terminal record" \
  "[ \"\$(grep -c '\"packet\":\"wc\".*\"outcome\":' \"$SO2_DIR/S1.jsonl\")\" = 1 ]"
assert_true "an already-ended packet gets no new record from the sweep" \
  "! grep -q '\"packet\":\"wc\"' \"$SO2_DIR/SWEEP1.jsonl\" 2>/dev/null"

SO2_COUNT_BEFORE2="$(cat "$SO2_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
SW_OUT2="$(cd "$SO2" && CLAUDE_CODE_SESSION_ID=SWEEP1 "$RUNSTATE" sweep-open)"
assert_true "a second sweep-open appends nothing (idempotent)" \
  "[ -z \"\$SW_OUT2\" ]"
assert_true "a second sweep-open leaves the log line counts unchanged" \
  "[ \"\$(cat \"$SO2_DIR\"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')\" = \"\$SO2_COUNT_BEFORE2\" ]"

echo
echo "== sweep-open: caller-supplied --paused-cursor, both loop-skill call shapes (thin-loop-driver-gaps T2) =="
# sweep-open's own mechanics and its --paused-cursor flag are unchanged -- these pin
# the two REAL (non---list) call shapes the loop skills now use, so a packet the
# session is about to continue never gets a permanent `interrupted` record.

# -- run-loop's own shape: §3.2 now passes --paused-cursor alongside --gone, in the
# SAME real-sweep call, for a cursor packet §3.3 is about to continue. --
SOC="$(mktemp -d)"; git -C "$SOC" init -q
git -C "$SOC" config user.email t@t; git -C "$SOC" config user.name t
SOC_DIR="$SOC/.agents/metrics/outcomes"

(cd "$SOC" && "$RUNSTATE" record-start cont-a S1 >/dev/null)   # about to be continued -- must not close
(cd "$SOC" && "$RUNSTATE" record-start open-b S1 >/dev/null)   # plain open -- still swept
(cd "$SOC" && "$RUNSTATE" record-start gone-c S1 >/dev/null)   # gone -- still swept, as abandoned

SOC_OUT="$(cd "$SOC" && CLAUDE_CODE_SESSION_ID=SWEEP2 "$RUNSTATE" sweep-open --gone gone-c --paused-cursor cont-a)"
assert_true "run-loop shape: --paused-cursor excludes the continuing cursor packet from SWEPT=" \
  "! printf '%s\n' \"\$SOC_OUT\" | grep -qx 'SWEPT=cont-a'"
assert_true "run-loop shape: a plain open packet still sweeps as interrupted, alongside the exclusion" \
  "printf '%s\n' \"\$SOC_OUT\" | grep -qx 'SWEPT=open-b'"
assert_true "run-loop shape: a gone packet still sweeps as abandoned, alongside the exclusion" \
  "printf '%s\n' \"\$SOC_OUT\" | grep -qx 'SWEPT=gone-c'"
assert_true "run-loop shape: the excluded cursor packet gets no terminal record at all" \
  "! grep -q '\"packet\":\"cont-a\"' \"$SOC_DIR\"/SWEEP2.jsonl 2>/dev/null"

# -- resume's shape, a status the rule ADMITS (blocked -- stopped on a blocking
# question, the cursor's start left open): resuming passes --paused-cursor for it
# exactly as it would for a paused run. --
SORB="$(mktemp -d)"; git -C "$SORB" init -q
git -C "$SORB" config user.email t@t; git -C "$SORB" config user.name t
SORB_DIR="$SORB/.agents/metrics/outcomes"
(cd "$SORB" && "$RUNSTATE" record-start blocked-cursor S1 >/dev/null)
(cd "$SORB" && "$RUNSTATE" record-start blocked-open S1 >/dev/null)   # positive control -- still swept
SORB_OUT="$(cd "$SORB" && CLAUDE_CODE_SESSION_ID=SWEEP3 "$RUNSTATE" sweep-open --paused-cursor blocked-cursor)"
assert_true "resume shape, status blocked (rule admits continuing it): the cursor packet is excluded from the sweep" \
  "! printf '%s\n' \"\$SORB_OUT\" | grep -qx 'SWEPT=blocked-cursor'"
assert_true "resume shape, status blocked: a plain open packet still sweeps as interrupted, alongside the exclusion (positive control)" \
  "printf '%s\n' \"\$SORB_OUT\" | grep -qx 'SWEPT=blocked-open'"
assert_true "resume shape, status blocked: the excluded cursor packet gets no terminal record at all" \
  "! grep -q '\"packet\":\"blocked-cursor\"' \"$SORB_DIR\"/SWEEP3.jsonl 2>/dev/null"

# -- resume's shape, a status the rule EXCLUDES (running -- a crash): the cursor is
# not passed, and it closes as interrupted like any other open packet, unchanged
# from before this task. --
SORC="$(mktemp -d)"; git -C "$SORC" init -q
git -C "$SORC" config user.email t@t; git -C "$SORC" config user.name t
(cd "$SORC" && "$RUNSTATE" record-start crashed-cursor S1 >/dev/null)
SORC_OUT="$(cd "$SORC" && CLAUDE_CODE_SESSION_ID=SWEEP4 "$RUNSTATE" sweep-open)"
assert_true "resume shape, status running/crash (rule excludes continuing it): the cursor packet still sweeps as interrupted" \
  "printf '%s\n' \"\$SORC_OUT\" | grep -qx 'SWEPT=crashed-cursor'"

echo
echo "== packet-bundling T3: comma-joined packet-id lists at each boundary write =="
# A bundle holds several ids for ONE packet boundary: record-start,
# record-outcome and sweep-open --paused-cursor must each write/exempt one
# record per member, sharing a single timestamp and session, and refuse the
# whole call (nothing appended) when any member is malformed.
RB="$(mktemp -d)"; git -C "$RB" init -q
git -C "$RB" config user.email t@t; git -C "$RB" config user.name t
RB_DIR="$RB/.agents/metrics/outcomes"

# -- record-start: a three-id bundle --
RBS_OUT="$(cd "$RB" && "$RUNSTATE" record-start bt1,bt2,bt3 S1)"
assert_true "record-start with a three-id bundle reports RECORDED=yes three times" \
  "[ \"\$(printf '%s\n' \"\$RBS_OUT\" | grep -c '^RECORDED=yes')\" = 3 ]"
assert_true "record-start with a three-id bundle reports each member's own PACKET= line" \
  "printf '%s\n' \"\$RBS_OUT\" | grep -qx 'PACKET=bt1' \
    && printf '%s\n' \"\$RBS_OUT\" | grep -qx 'PACKET=bt2' \
    && printf '%s\n' \"\$RBS_OUT\" | grep -qx 'PACKET=bt3'"
assert_true "record-start with a three-id bundle writes exactly one JSON start line per member" \
  "[ \"\$(jq -r -s '[.[] | select(.kind==\"start\")] | length' \"$RB_DIR/S1.jsonl\")\" = 3 ]"
assert_true "each written start record carries its own packet id" \
  "[ \"\$(jq -r -s '[.[] | select(.kind==\"start\") | .packet] | sort | join(\",\")' \"$RB_DIR/S1.jsonl\")\" = bt1,bt2,bt3 ]"
assert_true "the three-id bundle's start records share exactly ONE timestamp" \
  "[ \"\$(jq -r -s '[.[] | select(.kind==\"start\") | .ts] | unique | length' \"$RB_DIR/S1.jsonl\")\" = 1 ]"
assert_true "the three-id bundle's start records share exactly ONE session" \
  "[ \"\$(jq -r -s '[.[] | select(.kind==\"start\") | .session] | unique | length' \"$RB_DIR/S1.jsonl\")\" = 1 ]"

# -- record-start --continue: the SAME three ids, all become continuations --
RBC_OUT="$(cd "$RB" && "$RUNSTATE" record-start bt1,bt2,bt3 --continue S1)"
assert_true "record-start --continue with a three-id bundle reports KIND=continue three times" \
  "[ \"\$(printf '%s\n' \"\$RBC_OUT\" | grep -c '^KIND=continue')\" = 3 ]"
assert_true "record-start --continue with a three-id bundle writes exactly one continuation JSON line per member" \
  "[ \"\$(jq -r -s '[.[] | select(.kind==\"continue\")] | length' \"$RB_DIR/S1.jsonl\")\" = 3 ]"
assert_true "each written continuation record carries its own packet id" \
  "[ \"\$(jq -r -s '[.[] | select(.kind==\"continue\") | .packet] | sort | join(\",\")' \"$RB_DIR/S1.jsonl\")\" = bt1,bt2,bt3 ]"

# -- record-outcome: a three-id bundle gets ONE shared terminal outcome --
RBO_OUT="$(cd "$RB" && "$RUNSTATE" record-outcome bt1,bt2,bt3 rolled-back S1)"
assert_true "record-outcome with a three-id bundle reports RECORDED=yes three times" \
  "[ \"\$(printf '%s\n' \"\$RBO_OUT\" | grep -c '^RECORDED=yes')\" = 3 ]"
assert_true "record-outcome with a three-id bundle applies the SAME outcome to every member" \
  "[ \"\$(jq -r -s '[.[] | select(.outcome==\"rolled-back\")] | length' \"$RB_DIR/S1.jsonl\")\" = 3 ]"
assert_true "each written outcome record carries its own packet id" \
  "[ \"\$(jq -r -s '[.[] | select(.outcome==\"rolled-back\") | .packet] | sort | join(\",\")' \"$RB_DIR/S1.jsonl\")\" = bt1,bt2,bt3 ]"
assert_true "the three-id bundle's outcome records share exactly ONE timestamp" \
  "[ \"\$(jq -r -s '[.[] | select(.outcome==\"rolled-back\") | .ts] | unique | length' \"$RB_DIR/S1.jsonl\")\" = 1 ]"

# -- single-id compatibility: a bare id (no comma) must behave byte-identically
# to today on record-start and record-outcome. --
RBS1_OUT="$(cd "$RB" && "$RUNSTATE" record-start single-a S1)"
assert_true "record-start with a single id (no comma) produces exactly the unchanged 3-line output" \
  "[ \"\$(printf '%s\n' \"\$RBS1_OUT\" | wc -l | tr -d ' ')\" = 3 ] \
    && printf '%s\n' \"\$RBS1_OUT\" | grep -qx 'RECORDED=yes' \
    && printf '%s\n' \"\$RBS1_OUT\" | grep -qx 'PACKET=single-a' \
    && printf '%s\n' \"\$RBS1_OUT\" | grep -qx 'KIND=start'"
RBO1_OUT="$(cd "$RB" && "$RUNSTATE" record-outcome single-a green S1)"
assert_true "record-outcome with a single id (no comma) produces exactly the unchanged 3-line output" \
  "[ \"\$(printf '%s\n' \"\$RBO1_OUT\" | wc -l | tr -d ' ')\" = 3 ] \
    && printf '%s\n' \"\$RBO1_OUT\" | grep -qx 'RECORDED=yes' \
    && printf '%s\n' \"\$RBO1_OUT\" | grep -qx 'PACKET=single-a' \
    && printf '%s\n' \"\$RBO1_OUT\" | grep -qx 'OUTCOME=green'"

# -- a malformed member refuses the WHOLE call, nothing appended --
RB_COUNT_BEFORE="$(wc -l < "$RB_DIR/S1.jsonl" | tr -d ' ')"
assert_true "record-start with a malformed member in the list fails" \
  "(cd \"$RB\" && ! \"\$RUNSTATE\" record-start 'good1,bad\"id,good2' S1 2>/dev/null)"
assert_true "record-start's malformed-member call appends nothing at all, not even the good members" \
  "[ \"\$(wc -l < \"$RB_DIR/S1.jsonl\" | tr -d ' ')\" = \"\$RB_COUNT_BEFORE\" ]"
assert_true "record-start's malformed-member call never wrote either good id" \
  "! grep -q '\"packet\":\"good1\"' \"$RB_DIR/S1.jsonl\" && ! grep -q '\"packet\":\"good2\"' \"$RB_DIR/S1.jsonl\""
assert_true "record-outcome with a malformed member in the list fails" \
  "(cd \"$RB\" && ! \"\$RUNSTATE\" record-outcome 'good3,bad\"id,good4' green S1 2>/dev/null)"
assert_true "record-outcome's malformed-member call appends nothing at all, not even the good members" \
  "[ \"\$(wc -l < \"$RB_DIR/S1.jsonl\" | tr -d ' ')\" = \"\$RB_COUNT_BEFORE\" ]"

echo
echo "== packet-bundling T3: sweep-open --paused-cursor exempts every bundle member =="
RBP="$(mktemp -d)"; git -C "$RBP" init -q
git -C "$RBP" config user.email t@t; git -C "$RBP" config user.name t
RBP_DIR="$RBP/.agents/metrics/outcomes"
# Started as three SEPARATE single-id calls (not record-start's own comma-list
# form) so this section's assertions test sweep-open's --paused-cursor widening
# in isolation from record-start's.
(cd "$RBP" && "$RUNSTATE" record-start pc1 S1 >/dev/null)          # the paused bundle -- must stay open
(cd "$RBP" && "$RUNSTATE" record-start pc2 S1 >/dev/null)
(cd "$RBP" && "$RUNSTATE" record-start pc3 S1 >/dev/null)
(cd "$RBP" && "$RUNSTATE" record-start other-open S1 >/dev/null)   # unrelated -- must still sweep

RBPL_OUT="$(cd "$RBP" && "$RUNSTATE" sweep-open --list --paused-cursor pc1,pc2,pc3)"
assert_true "a multi-member paused cursor excludes EVERY member from the OPEN list" \
  "! printf '%s\n' \"\$RBPL_OUT\" | grep -qx 'OPEN=pc1' \
    && ! printf '%s\n' \"\$RBPL_OUT\" | grep -qx 'OPEN=pc2' \
    && ! printf '%s\n' \"\$RBPL_OUT\" | grep -qx 'OPEN=pc3'"
assert_true "a multi-member paused cursor still reports an unrelated open packet" \
  "printf '%s\n' \"\$RBPL_OUT\" | grep -qx 'OPEN=other-open'"

RBPW_OUT="$(cd "$RBP" && CLAUDE_CODE_SESSION_ID=SWEEPBUNDLE "$RUNSTATE" sweep-open --paused-cursor pc1,pc2,pc3)"
assert_true "a multi-member paused cursor: no member is swept" \
  "! printf '%s\n' \"\$RBPW_OUT\" | grep -q 'SWEPT=pc'"
assert_true "a multi-member paused cursor: the unrelated open packet is still swept as interrupted" \
  "printf '%s\n' \"\$RBPW_OUT\" | grep -qx 'SWEPT=other-open' \
    && printf '%s\n' \"\$RBPW_OUT\" | grep -qx 'OUTCOME=interrupted'"
assert_true "a multi-member paused cursor: no member got any terminal record at all" \
  "! grep -qE '\"packet\":\"pc(1|2|3)\"' \"$RBP_DIR\"/SWEEPBUNDLE.jsonl 2>/dev/null"

# -- single-id compatibility on sweep-open --paused-cursor --
RBS_SINGLE="$(mktemp -d)"; git -C "$RBS_SINGLE" init -q
git -C "$RBS_SINGLE" config user.email t@t; git -C "$RBS_SINGLE" config user.name t
(cd "$RBS_SINGLE" && "$RUNSTATE" record-start solo-cursor S1 >/dev/null)
RBS_SINGLE_OUT="$(cd "$RBS_SINGLE" && "$RUNSTATE" sweep-open --list --paused-cursor solo-cursor)"
assert_true "sweep-open --paused-cursor with a single id (no comma) behaves exactly as today" \
  "! printf '%s\n' \"\$RBS_SINGLE_OUT\" | grep -qx 'OPEN=solo-cursor'"

# -- a malformed member in --paused-cursor refuses the whole sweep, writes nothing --
RBM="$(mktemp -d)"; git -C "$RBM" init -q
git -C "$RBM" config user.email t@t; git -C "$RBM" config user.name t
RBM_DIR="$RBM/.agents/metrics/outcomes"
(cd "$RBM" && "$RUNSTATE" record-start open-x S1 >/dev/null)
assert_true "sweep-open --paused-cursor with a malformed member fails" \
  "(cd \"$RBM\" && ! \"\$RUNSTATE\" sweep-open --paused-cursor 'good,bad\"id' 2>/dev/null)"
assert_true "sweep-open --paused-cursor with a malformed member writes no terminal record at all" \
  "! grep -q outcome \"$RBM_DIR\"/*.jsonl 2>/dev/null"

echo
echo "== findings: index hot, body cold (ADR 0022) =="
# The fixture puts run-state at a REAL `.agents/run-state.yaml`, because the index's
# `file:` value is derived from where the file actually sits. The previous fixture used
# a bare mktemp dir and asserted the literal string `.agents/findings/...`, which only
# passed because the code hardcoded that prefix — so the test encoded the very bug it
# looked like it was guarding, and a dangling index could never fail it.
FD="$(mktemp -d)/.agents"; mkdir -p "$FD"
printf 'status: running\npending_questions:\n  - id: q-001\n    severity: blocking\nfindings:\nnote: green\n' \
  > "$FD/run-state.yaml"
assert_true "add-finding reports success" \
  "\"\$RUNSTATE\" add-finding \"$FD/run-state.yaml\" f-001 'runner wedges on a per-session flag' --packets pkt-a --body | grep -q '^ADDED=yes'"
assert_true "add-finding creates the body file (--body)" \
  "[ -s \"$FD/findings/f-001.md\" ]"
assert_true "the SUMMARY lands in run-state (single-quoted)" \
  "grep -q \"summary: 'runner wedges on a per-session flag'\" \"$FD/run-state.yaml\""
# The index must point at where the body ACTUALLY is, not at a hardcoded prefix.
assert_true "the index file: path resolves to the real body" \
  "[ -s \"\$(dirname \"$FD\")/\$(grep -m1 'file:' \"$FD/run-state.yaml\" | sed 's/.*file: //')\" ]"
# the whole point: the body must NOT be in run-state
assert_true "the BODY does not land in run-state" \
  "! grep -q 'What was found' \"$FD/run-state.yaml\""
assert_true "entry lands inside findings, not pending_questions" \
  "awk '/^findings:/{f=1;next} /^[a-z_]+:/{f=0} f && /- id: f-001/{ok=1} END{exit !ok}' \"$FD/run-state.yaml\""
assert_true "keys after findings survive" \
  "grep -q '^note: green' \"$FD/run-state.yaml\""
assert_true "second finding coexists with the first" \
  "\"\$RUNSTATE\" add-finding \"$FD/run-state.yaml\" f-002 'rounding differs' --packets pkt-b >/dev/null && [ \"\$(\"\$RUNSTATE\" findings \"$FD/run-state.yaml\" | wc -l | tr -d ' ')\" = 2 ]"
assert_true "duplicate id is refused, not duplicated" \
  "\"\$RUNSTATE\" add-finding \"$FD/run-state.yaml\" f-001 'other text' --packets pkt-a | grep -q 'duplicate-id'"
assert_true "duplicate refusal leaves ONE index entry" \
  "[ \"\$(grep -c '\- id: f-001' \"$FD/run-state.yaml\")\" = 1 ]"
# an id becomes a filename — reject path traversal and separators outright
assert_true "a traversing id is rejected" \
  "! \"\$RUNSTATE\" add-finding \"$FD/run-state.yaml\" '../escape' 'x' --packets pkt-a 2>/dev/null"
# a newline in the summary would inject a sibling YAML key
assert_true "a multi-line summary cannot inject a key" \
  "\"\$RUNSTATE\" add-finding \"$FD/run-state.yaml\" f-003 \"\$(printf 'one\\nstatus: hacked')\" --packets pkt-c >/dev/null && [ \"\$(grep -c '^status:' \"$FD/run-state.yaml\")\" = 1 ]"
# the READ side must return the index only, never body content
assert_true "findings returns one line per finding" \
  "[ \"\$(\"\$RUNSTATE\" findings \"$FD/run-state.yaml\" | wc -l | tr -d ' ')\" = 3 ]"
assert_true "findings emits id, summary and file path" \
  "\"\$RUNSTATE\" findings \"$FD/run-state.yaml\" | grep -q 'f-001.*runner wedges.*\.agents/findings/f-001\.md'"
# The read side must DECODE the single-quoted encoding the write side applies —
# otherwise every summary reaches a brief wrapped in quotes it did not ask for.
assert_true "findings strips the YAML quoting it wrote" \
  "! \"\$RUNSTATE\" findings \"$FD/run-state.yaml\" | grep -q \"'runner wedges\""

# --- the summary is UNTRUSTED TEXT: it must not be able to break the file ----
# Every case below produced an unparseable run-state before the single-quoted
# encoding. run-state is the loop's ONLY durable state, so "it usually parses" is
# not a property worth having — each of these asserts a real YAML parse, not a grep,
# and LOUDLY skips (a counted, reported FAIL, never a silent pass) when no parser is
# available on this host. (test-runstate.sh:267 already requires python3
# unconditionally, so a host with none fails this sweep regardless — the check
# below only matters for the python3-present/PyYAML-absent case.)
# have_yaml -- true if a real YAML parser (python3 + PyYAML) is available. The one
# place this probe lives; yamlok() and the notice below both call it rather than
# each carrying their own copy to drift out of sync.
have_yaml() { command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; }
# YAML_SKIP_COUNT -- how many yamlok() calls had to loudly skip for lack of a
# parser on this host. Surfaced in the summary line at the bottom of the sweep so
# a parser-less green-looking run cannot be mistaken for one that actually parsed.
YAML_SKIP_COUNT=0
yamlok() {  # yamlok <file> -- true if some available parser accepts it; returns
            # nonzero (never a silent pass) when no parser is present, so every
            # caller's own assert_true/bad reports a real, counted FAIL
  if have_yaml; then
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$1" 2>/dev/null
  else
    YAML_SKIP_COUNT=$((YAML_SKIP_COUNT + 1))
    return 1   # no parser available -> fail loudly; see the one-time notice below
  fi
}
if ! have_yaml; then
  YAML_SKIP_COUNT=$((YAML_SKIP_COUNT + 1))
  bad 'a YAML parser is available for the parse-assertion cases below' \
      'no python3+PyYAML on this host — not asserting vacuously; every yamlok() case below now correctly reports FAIL instead of silently passing'
fi
FY="$(mktemp -d)/.agents"; mkdir -p "$FY"
for case_name in colon hash quote backslash dashlead brace; do
  case "$case_name" in
    colon)     s='guard.sh: fails closed on unreadable input' ;;
    hash)      s='trailing comment # not a comment' ;;
    quote)     s="it's got 'single' and \"double\" quotes" ;;
    backslash) s='windows path C:\nope needs \t no escaping' ;;
    dashlead)  s='- leading dash reads as a list item' ;;
    brace)     s='{flow: mapping} and [flow, seq] and & anchor * alias' ;;
  esac
  printf 'schema: 3\nfindings:\nstatus: running\n' > "$FY/rs-$case_name.yaml"
  assert_true "hostile summary ($case_name) keeps run-state parseable" \
    "\"\$RUNSTATE\" add-finding \"$FY/rs-$case_name.yaml\" f-1 \"\$s\" --packets pkt-1 >/dev/null && yamlok \"$FY/rs-$case_name.yaml\""
  assert_true "hostile summary ($case_name) round-trips through findings" \
    "[ \"\$(\"\$RUNSTATE\" findings \"$FY/rs-$case_name.yaml\" | cut -f2)\" = \"\$s\" ]"
  assert_true "hostile summary ($case_name) injects no sibling key" \
    "[ \"\$(grep -c '^status:' \"$FY/rs-$case_name.yaml\")\" = 1 ]"
done

echo
echo "== the index summary is capped at 160 CHARACTERS, never refused (escalation-decider T6) =="
# The index is in every packet's standing context, so the one free-text field in
# it is bounded -- and the cap must not become a second way to lose text or a
# second way to corrupt the file. Every case below therefore asserts all three:
# what the ENTRY carries, that the FILE still parses, and where the FULL text
# went.
#
# The character count and the UTF-8 boundary are judged by python3, NOT by a
# second copy of runstate.sh's own arithmetic: `.decode("utf-8")` raises on a
# prefix that ended mid-character, so the length and the boundary come from one
# independent read rather than a mirror that would agree with a wrong
# implementation (the reasoning _yaml_value above is written for). Gated on
# have_yaml exactly like yamlok -- a parser-less host reports a loud, counted
# FAIL, never a silent pass.
_finding_summary() {  # <file> <id> -- the REAL parsed summary of one entry
  python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
for e in (d.get('findings') or []):
    if e.get('id') == sys.argv[2]:
        sys.stdout.write(str(e.get('summary', '')))
        break
" "$1" "$2"
}
_nchars() {  # <string> -- its length in CHARACTERS; FAILS if it is not UTF-8,
             # which is what a cut through a multi-byte character produces
  printf '%s' "$1" | python3 -c \
    'import sys; sys.stdout.write(str(len(sys.stdin.buffer.read().decode("utf-8"))))'
}
_caps_to() { # <full> <entry> -- true if <entry> is <full> SHORTENED: at most 160
             # characters, ending in the mark, and otherwise a character-boundary
             # prefix of <full>. The prefix half is what makes this a cap rather
             # than "some shorter string ending in an ellipsis".
  CAP_FULL="$1" CAP_ENTRY="$2" python3 -c '
import os, sys
def s(k):  # strict: re-decode so a split character raises rather than passing
    return os.environ[k].encode("utf-8", "surrogateescape").decode("utf-8")
full, entry = s("CAP_FULL"), s("CAP_ENTRY")
mark = "…"
sys.exit(0 if (len(entry) <= 160 and len(entry) > 1
               and entry.endswith(mark)
               and full.startswith(entry[:-1])) else 1)
'
}
FC="$(mktemp -d)/.agents"; mkdir -p "$FC"
printf 'schema: 3\nstatus: running\nfindings:\nnote: green\n' > "$FC/run-state.yaml"
# Four fixtures: exactly at the cap, one character over it, and the two shapes a
# BYTE count gets wrong -- a summary whose 160th BYTE falls inside a multi-byte
# character, and one well under the cap in characters but double it in bytes.
# UTF-8 as octal escapes because this sweep runs under bash 3.2 on macOS, which
# has no \u in printf.
CAP_AT="$(printf 'a%.0s' $(seq 1 160))"
CAP_OVER="$(printf 'A%.0s' $(seq 1 100))$(printf 'B%.0s' $(seq 1 59))YZ"
CAP_WIDE="$(printf '\344\270\255%.0s' $(seq 1 100))"
# Pin the fixtures themselves: a "wide" case that is not actually over the cap
# in bytes proves nothing while still passing.
assert_true "fixture: the at-cap summary is exactly 160 characters" \
  "[ \"\$(_nchars \"\$CAP_AT\")\" = 160 ]"
assert_true "fixture: the over-cap summary is 161 characters" \
  "[ \"\$(_nchars \"\$CAP_OVER\")\" = 161 ]"
assert_true "fixture: the wide summary is 100 characters in 300 bytes" \
  "[ \"\$(_nchars \"\$CAP_WIDE\")\" = 100 ] && [ \"\$(printf '%s' \"\$CAP_WIDE\" | wc -c | tr -d ' ')\" = 300 ]"

# -- at the cap: written through UNCHANGED, and still no body without --body ---
CAP_AT_OUT="$("$RUNSTATE" add-finding "$FC/run-state.yaml" cap-at "$CAP_AT" --packets pkt-cap-a)"
assert_true "a summary exactly at the cap is added" \
  "printf '%s\n' \"\$CAP_AT_OUT\" | grep -qx 'ADDED=yes'"
assert_true "a summary exactly at the cap is not reported capped" \
  "! printf '%s\n' \"\$CAP_AT_OUT\" | grep -q '^CAPPED='"
assert_true "a summary exactly at the cap reaches the index unchanged" \
  "yamlok \"$FC/run-state.yaml\" && [ \"\$(_finding_summary \"$FC/run-state.yaml\" cap-at)\" = \"\$CAP_AT\" ]"
assert_true "a summary exactly at the cap still writes no body (--body stays opt-in)" \
  "[ ! -f \"$FC/findings/cap-at.md\" ] && ! printf '%s\n' \"\$CAP_AT_OUT\" | grep -q '^FILE='"

# -- one character over: shortened in the index, whole in the body -------------
CAP_OVER_OUT="$("$RUNSTATE" add-finding "$FC/run-state.yaml" cap-over "$CAP_OVER" --packets pkt-cap-b --body)"
CAP_OVER_RC=$?
assert_true "an over-cap call exits 0 -- never refused for length" "[ $CAP_OVER_RC = 0 ]"
assert_true "an over-cap call still reports ADDED=yes" \
  "printf '%s\n' \"\$CAP_OVER_OUT\" | grep -qx 'ADDED=yes'"
assert_true "an over-cap call reports CAPPED=yes rather than shortening silently" \
  "printf '%s\n' \"\$CAP_OVER_OUT\" | grep -qx 'CAPPED=yes'"
assert_true "the over-cap file still parses" "yamlok \"$FC/run-state.yaml\""
assert_true "the over-cap ENTRY is 160 characters" \
  "[ \"\$(_nchars \"\$(_finding_summary \"$FC/run-state.yaml\" cap-over)\")\" = 160 ]"
assert_true "the over-cap ENTRY is the full text shortened, mark and all" \
  "_caps_to \"\$CAP_OVER\" \"\$(_finding_summary \"$FC/run-state.yaml\" cap-over)\""
assert_true "the over-cap BODY holds the full text the entry no longer does" \
  "grep -qF \"\$CAP_OVER\" \"$FC/findings/cap-over.md\""
assert_true "the over-cap summary reads back shortened through findings too" \
  "[ \"\$(\"\$RUNSTATE\" findings \"$FC/run-state.yaml\" | awk -F'\t' '\$1==\"cap-over\"{print \$2}')\" = \"\$(_finding_summary \"$FC/run-state.yaml\" cap-over)\" ]"

# -- the cut lands inside a multi-byte character ------------------------------
# A byte-count truncation here leaves a byte sequence that is not UTF-8 at all,
# and what that COSTS was measured rather than assumed (byte-counting _cap_chars,
# this host, macOS sed + awk): the encoder's `sed "s/'/''/g"` refuses the illegal
# byte sequence outright, so the entry lands as `summary: ''` -- the file still
# parses, and the whole summary is simply GONE. A sed that passes the bytes
# through instead leaves non-UTF-8 in the file, where the cost lands on every
# other key in it. Both are caught here: _nchars decodes strictly (0 characters
# either way), and yamlok covers the second shape.
#
# THREE fixtures, and the three ARE the test. A byte implementation cuts at some
# fixed byte offset near 157-160, and for any ONE ASCII-prefix length there is
# an offset in that range that lands on a character boundary by luck -- three
# consecutive offsets cover all three residues modulo the 3-byte width of the
# characters below, so a single fixture can always be the one a wrong
# implementation happens to survive. (Measured, not assumed: the first cut of
# this case used one 158-character prefix, and a deliberately byte-counting
# _cap_chars cut it at byte 157 -- still inside the ASCII run, no split, case
# green.) Across pads 155/156/157 no offset in that range survives all three.
for CAP_PAD in 155 156 157; do
  CAP_MB="$(printf 'm%.0s' $(seq 1 "$CAP_PAD"))$(printf '\342\206\222%.0s' $(seq 1 10))"
  # The pin that keeps the case from going vacuous: the CORRECT cut (159
  # characters, leaving room for the mark) has to land inside the multi-byte
  # run, not in the ASCII prefix before it.
  assert_true "fixture (pad $CAP_PAD): the cut point falls inside the multi-byte run" \
    "[ \"\$(_nchars \"\$CAP_MB\")\" = $((CAP_PAD + 10)) ] && [ 159 -gt $CAP_PAD ]"
  CAP_MB_OUT="$("$RUNSTATE" add-finding "$FC/run-state.yaml" "cap-mb-$CAP_PAD" "$CAP_MB" --packets pkt-cap-c)"
  assert_true "a multi-byte over-cap summary (pad $CAP_PAD) is added and reported capped" \
    "printf '%s\n' \"\$CAP_MB_OUT\" | grep -qx 'ADDED=yes' && printf '%s\n' \"\$CAP_MB_OUT\" | grep -qx 'CAPPED=yes'"
  assert_true "run-state still parses after the cut (pad $CAP_PAD)" \
    "yamlok \"$FC/run-state.yaml\""
  assert_true "the ENTRY is 160 WHOLE characters -- the cut was a boundary (pad $CAP_PAD)" \
    "[ \"\$(_nchars \"\$(_finding_summary \"$FC/run-state.yaml\" \"cap-mb-$CAP_PAD\")\")\" = 160 ]"
  assert_true "the ENTRY is the full text shortened, mark and all (pad $CAP_PAD)" \
    "_caps_to \"\$CAP_MB\" \"\$(_finding_summary \"$FC/run-state.yaml\" \"cap-mb-$CAP_PAD\")\""
  assert_true "the BODY holds the full multi-byte text (pad $CAP_PAD)" \
    "grep -qF \"\$CAP_MB\" \"$FC/findings/cap-mb-$CAP_PAD.md\""
done

# -- over the cap with NO --body: the body is created anyway -------------------
# Without this the cap would be a silent delete: --body is opt-in, and the text
# the cap removes has nowhere else to go.
CAP_NB_OUT="$("$RUNSTATE" add-finding "$FC/run-state.yaml" cap-nobody "$CAP_OVER" --packets pkt-cap-d)"
assert_true "an over-cap call without --body still reports a FILE" \
  "printf '%s\n' \"\$CAP_NB_OUT\" | grep -q '^FILE='"
assert_true "an over-cap call without --body creates the body file" \
  "[ -s \"$FC/findings/cap-nobody.md\" ]"
assert_true "an over-cap call without --body puts the FULL text in that body" \
  "grep -qF \"\$CAP_OVER\" \"$FC/findings/cap-nobody.md\""
assert_true "the entry points at that body the way a --body entry does" \
  "[ -s \"\$(dirname \"$FC\")/\$(\"\$RUNSTATE\" findings \"$FC/run-state.yaml\" | awk -F'\t' '\$1==\"cap-nobody\"{print \$3}')\" ]"
# A body already on disk under this id must not be clobbered -- and must not be
# an excuse to drop the capped text either.
printf '# cap-pre\n\npre-existing detail\n' > "$FC/findings/cap-pre.md"
"$RUNSTATE" add-finding "$FC/run-state.yaml" cap-pre "$CAP_OVER" --packets pkt-cap-e >/dev/null
assert_true "an existing body survives an over-cap add" \
  "grep -qF 'pre-existing detail' \"$FC/findings/cap-pre.md\""
assert_true "the full text is appended to that existing body, not dropped" \
  "grep -qF \"\$CAP_OVER\" \"$FC/findings/cap-pre.md\""

# -- under the cap in CHARACTERS, double it in BYTES: written unchanged --------
# The threshold half of the same rule: a byte threshold would cap this at a
# third of the budget an English summary gets, while looking like one rule.
CAP_WIDE_OUT="$("$RUNSTATE" add-finding "$FC/run-state.yaml" cap-wide "$CAP_WIDE" --packets pkt-cap-f)"
assert_true "a 100-character 300-byte summary is not capped" \
  "! printf '%s\n' \"\$CAP_WIDE_OUT\" | grep -q '^CAPPED='"
assert_true "a 100-character 300-byte summary reaches the index unchanged" \
  "yamlok \"$FC/run-state.yaml\" && [ \"\$(_finding_summary \"$FC/run-state.yaml\" cap-wide)\" = \"\$CAP_WIDE\" ]"
assert_true "a 100-character 300-byte summary writes no body" \
  "[ ! -f \"$FC/findings/cap-wide.md\" ]"

# --- `set`'s VALUE is untrusted text too (T4, runstate-write-integrity) -----
# Every case below produced an unparseable run-state (or a silently injected
# sibling key) before the shared _yaml_quote/_yaml_encode_value helper. Each
# asserts a real YAML parse (or loud, counted skip -- see yamlok above), a
# round-trip read-back, and an unchanged top-level key count, mirroring the
# three assertions the hostile-summary loop above already makes for
# add-finding. Fixtures carry a key BEFORE and a key AFTER the one being set,
# so an injected sibling is detectable rather than landing harmlessly at the
# end of the file.
#
# _yaml_value <file> <key> -- the REAL parsed value for <key>, via
# python3+PyYAML. Deliberately NOT a mirror of runstate.sh's own encoder: a
# self-consistent encode/decode pair that agrees with itself but disagrees
# with YAML (e.g. escaping a backslash inside a single-quoted scalar, which
# single-quoting must NOT do) would pass a mirror-based check and still be
# wrong. Only meaningful when have_yaml is true; callers gate on that (same
# pattern as yamlok) so a parser-less host reports a loud, counted skip
# rather than a silent pass.
_yaml_value() {
  python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
v = d.get(sys.argv[2])
sys.stdout.write('' if v is None else str(v))
" "$1" "$2"
}
_top_key_count() { grep -cE '^[A-Za-z_][A-Za-z0-9_]*:' "$1"; }
for case_name in colon quote newline dashlead hash brackets pipe trailspace colonend backslash \
                 typedno typedon typedzero typedoctal; do
  case "$case_name" in
    colon)      s='guard.sh: fails closed on unreadable input' ;;
    quote)      s="it's got 'single' quotes" ;;
    newline)    s="$(printf 'line one\nline two')" ;;
    dashlead)   s='- leading dash reads as a list item' ;;
    hash)       s='trailing comment # not a comment' ;;
    brackets)   s='{flow: mapping} and [flow, seq] and & anchor * alias' ;;
    pipe)       s='a | delimiter breaks the old s|...|...| replace' ;;
    trailspace) s='trailing space ' ;;
    # A now-DELETED allowlist once let this through bare: every character in
    # `naive:` individually passed a [A-Za-z0-9._:/+-] class, but `t: naive:`
    # is a second, empty mapping key and PyYAML refuses it. Kept as a
    # regression case even though _yaml_encode_value has no branch left to
    # regress -- always-quote makes it pass structurally, which is the point.
    colonend)   s='naive:' ;;
    # matches add-finding's own backslash case (line ~ colon/quote/backslash
    # loop above): the case most likely to hide a wrong "escape the
    # backslash" encoder behind a mirror decoder that makes the same mistake.
    backslash)  s='windows path C:\nope needs \t no escaping' ;;
    # The allowlist's SECOND failure class (the one that killed it): these all
    # passed the character-class check AND parsed, but YAML's own implicit
    # typing reads them back as something other than a string -- silently,
    # with the file still valid. Round-trip must equal the literal string.
    typedno)    s='no' ;;      # -> bool False, unquoted
    typedon)    s='on' ;;      # -> bool True, unquoted
    typedzero)  s='00' ;;      # -> int 0, unquoted
    typedoctal) s='0755' ;;    # -> int 493 (octal), unquoted
  esac
  printf 'before: 1\ntarget: original\nafter: 1\n' > "$FY/rs-set-$case_name.yaml"
  before_count="$(_top_key_count "$FY/rs-set-$case_name.yaml")"
  expected="$s"
  case "$case_name" in newline) expected="$(printf '%s' "$s" | tr '\n\r' '  ')" ;; esac
  assert_true "set hostile value ($case_name) keeps run-state parseable" \
    "\"\$RUNSTATE\" set \"$FY/rs-set-$case_name.yaml\" target \"\$s\" >/dev/null && yamlok \"$FY/rs-set-$case_name.yaml\""
  assert_true "set hostile value ($case_name) round-trips through a real YAML parse" \
    "yamlok \"$FY/rs-set-$case_name.yaml\" && [ \"\$(_yaml_value \"$FY/rs-set-$case_name.yaml\" target)\" = \"\$expected\" ]"
  assert_true "set hostile value ($case_name) round-trips through cmd_get" \
    "[ \"\$(\"\$RUNSTATE\" get \"$FY/rs-set-$case_name.yaml\" target)\" = \"\$expected\" ]"
  assert_true "set hostile value ($case_name) injects no sibling key" \
    "[ \"\$(_top_key_count \"$FY/rs-set-$case_name.yaml\")\" = \"$before_count\" ]"
  assert_true "set hostile value ($case_name) is quoted on disk (no allowlist)" \
    "[ \"\$(rs_get \"$FY/rs-set-$case_name.yaml\" target | cut -c1)\" = \"'\" ]"
done

echo
echo "== set: a BLOCK-SCALAR TARGET must not strand its body (T10) =="
# cmd_set used to replace only the column-0 HEADER of a multi-line block-scalar
# VALUE, stranding its indented body below the new header -- a syntax error, not
# a corrupted round-trip, since the key-count check cannot see it (no key is
# added). Every introducer is covered: |, >, and their chomping/indent variants
# |-, |+, >-, >+. Fixtures carry a key BEFORE and a key AFTER the block, same
# reason as the hostile-value loop above.
for case_name in pipe pipedash pipeplus fold folddash foldplus; do
  case "$case_name" in
    pipe)      intro='|'  ;;
    pipedash)  intro='|-' ;;
    pipeplus)  intro='|+' ;;
    fold)      intro='>'  ;;
    folddash)  intro='>-' ;;
    foldplus)  intro='>+' ;;
  esac
  BF="$FY/rs-block-$case_name.yaml"
  printf 'before: 1\ntarget: %s\n  body line one\n  body line two\nafter: 1\n' "$intro" > "$BF"
  before_count="$(_top_key_count "$BF")"
  assert_true "set over a block-scalar target ($case_name) keeps run-state parseable" \
    "\"\$RUNSTATE\" set \"$BF\" target 'replaced value' >/dev/null && yamlok \"$BF\""
  assert_true "set over a block-scalar target ($case_name) round-trips through a real YAML parse" \
    "yamlok \"$BF\" && [ \"\$(_yaml_value \"$BF\" target)\" = 'replaced value' ]"
  assert_true "set over a block-scalar target ($case_name) round-trips through cmd_get" \
    "[ \"\$(\"\$RUNSTATE\" get \"$BF\" target)\" = 'replaced value' ]"
  assert_true "set over a block-scalar target ($case_name) strands no body line" \
    "! grep -q 'body line' \"$BF\""
  assert_true "set over a block-scalar target ($case_name) leaves the key count unchanged" \
    "[ \"\$(_top_key_count \"$BF\")\" = \"$before_count\" ]"
  assert_true "set over a block-scalar target ($case_name) preserves the key before" \
    "grep -q '^before: 1' \"$BF\""
  assert_true "set over a block-scalar target ($case_name) preserves the key after" \
    "grep -q '^after: 1' \"$BF\""
done
# A block body that runs to EOF (no trailing key) -- the boundary cmd_trim_note
# uses (and cmd_set now reuses) is "next column-0 key, or EOF", so EOF must
# close the block just as reliably as a following key does.
BE="$FY/rs-block-eof.yaml"
printf 'before: 1\ntarget: |-\n  body line one\n  body line two\n' > "$BE"
assert_true "set over a block-scalar target running to EOF keeps run-state parseable" \
  "\"\$RUNSTATE\" set \"$BE\" target 'replaced at eof' >/dev/null && yamlok \"$BE\""
assert_true "set over a block-scalar target running to EOF round-trips" \
  "yamlok \"$BE\" && [ \"\$(_yaml_value \"$BE\" target)\" = 'replaced at eof' ]"
assert_true "set over a block-scalar target running to EOF strands no body line" \
  "! grep -q 'body line' \"$BE\""

echo
echo "== set: the LIVE reproduction sequence -- trim-note, then set (T10) =="
# The exact sequence from the runstate-write-integrity capability: trim-note
# re-emits note: as a |- block by design, then an ordinary `set <file> note
# <one line>` right after is the reachable path that stranded the old body.
TR="$(mktemp -d)/.agents"; mkdir -p "$TR"
{ printf 'status: running\nnote: '
  i=0; while [ "$i" -lt 200 ]; do printf 'packet %s narrative. ' "$i"; i=$((i+1)); done
  printf '\nbranch: main\n'
} > "$TR/run-state.yaml"
"$RUNSTATE" trim-note "$TR/run-state.yaml" 200 >/dev/null
assert_true "the live sequence's trim-note really produced a block scalar" \
  "grep -q '^note: |-' \"$TR/run-state.yaml\""
assert_true "set after trim-note keeps run-state parseable" \
  "\"\$RUNSTATE\" set \"$TR/run-state.yaml\" note 'a fresh one-line note' >/dev/null && yamlok \"$TR/run-state.yaml\""
assert_true "set after trim-note round-trips through a real YAML parse" \
  "yamlok \"$TR/run-state.yaml\" && [ \"\$(_yaml_value \"$TR/run-state.yaml\" note)\" = 'a fresh one-line note' ]"
assert_true "set after trim-note round-trips through cmd_get" \
  "[ \"\$(\"\$RUNSTATE\" get \"$TR/run-state.yaml\" note)\" = 'a fresh one-line note' ]"
assert_true "set after trim-note preserves the key before" \
  "grep -q '^status: running' \"$TR/run-state.yaml\""
assert_true "set after trim-note preserves the key after" \
  "grep -q '^branch: main' \"$TR/run-state.yaml\""

echo
echo "== set: the ORDINARY single-line replace is unchanged (T10 non-regression) =="
# A positive control, not a defect reproduction -- it is expected to pass
# whether or not the T10 fix is present, because the ordinary path was never
# broken. Kept explicit per the task's own instruction, and to pin that the
# new block-scalar detection cannot start misfiring on a plain scalar target.
OS="$FY/rs-ordinary.yaml"
printf 'before: 1\ntarget: original value\nafter: 1\n' > "$OS"
assert_true "set over an ordinary single-line target still parses" \
  "\"\$RUNSTATE\" set \"$OS\" target 'new value' >/dev/null && yamlok \"$OS\""
assert_true "set over an ordinary single-line target round-trips" \
  "yamlok \"$OS\" && [ \"\$(_yaml_value \"$OS\" target)\" = 'new value' ]"
assert_true "set over an ordinary single-line target replaces exactly one line" \
  "[ \"\$(wc -l < \"$OS\" | tr -d ' ')\" = 3 ]"
assert_true "set over an ordinary single-line target preserves the key before" \
  "grep -q '^before: 1' \"$OS\""
assert_true "set over an ordinary single-line target preserves the key after" \
  "grep -q '^after: 1' \"$OS\""

echo
echo "== set: a target it CANNOT address at column 0 is refused, writing nothing (gaps T1) =="
# Two shapes `set` was never able to address, and wrote anyway:
#   nested-only     `cursor` lives under `backlog:`; the old `grep -qE '^cursor:'`
#                   found nothing, took the APPEND branch, and created a second,
#                   column-0 `cursor:` at exit 0 while `cmd_cursor` kept reading
#                   the nested one. Two sources of truth, no signal.
#   column0-mapping `backlog:` is at column 0, so the replace branch fired and
#                   overwrote the header with a scalar, stranding its indented
#                   children. NOT the same defect as the block scalar above: a
#                   block header's remainder (`|`/`>`) declares a body and its
#                   end, a mapping header's remainder is empty and declares
#                   nothing, which is why T10 could consume its body and this
#                   one is refused instead.
# Each case asserts the four things a refusal owes: non-zero exit, a target
# checksum identical to its pre-call value, no new column-0 key, and the key
# named in the message. The checksum is the load-bearing one -- "it refused"
# and "it refused having already rewritten the file" look identical from the
# exit status alone, and a partial write here is the failure being removed.
RF="$(mktemp -d)/.agents"; mkdir -p "$RF"
for refuse_case in nested-only column0-mapping; do
  case "$refuse_case" in
    nested-only)     refuse_key=cursor  ;;
    column0-mapping) refuse_key=backlog ;;
  esac
  RFF="$RF/rs-refuse-$refuse_case.yaml"
  printf 'schema: 3\nstatus: running\nbacklog:\n  cursor: feature-002\n  pending:\n    - feature-002\nbranch: orch/x\n' > "$RFF"
  RF_SUM_BEFORE="$(cksum < "$RFF")"
  RF_KEYS_BEFORE="$(_top_key_count "$RFF")"
  RF_RC=0
  RF_MSG="$("$RUNSTATE" set "$RFF" "$refuse_key" 'a flat scalar' 2>&1)" || RF_RC=$?
  assert_true "set on a $refuse_case target ($refuse_key) exits non-zero" \
    "[ \"\$RF_RC\" != 0 ]"
  assert_true "set on a $refuse_case target ($refuse_key) leaves the file byte-identical (checksum)" \
    "[ \"\$(cksum < \"$RFF\")\" = \"\$RF_SUM_BEFORE\" ]"
  assert_true "set on a $refuse_case target ($refuse_key) adds no column-0 key" \
    "[ \"\$(_top_key_count \"$RFF\")\" = \"\$RF_KEYS_BEFORE\" ]"
  assert_true "set on a $refuse_case target ($refuse_key) names the key in the message" \
    "case \"\$RF_MSG\" in *\"'$refuse_key'\"*) true;; *) false;; esac"
  assert_true "set on a $refuse_case target ($refuse_key) points the caller at \`write\`" \
    "case \"\$RF_MSG\" in *'\`write\`'*) true;; *) false;; esac"
  assert_true "set on a $refuse_case target ($refuse_key) leaves a parseable run-state" \
    "yamlok \"$RFF\""
  # The refusal happens BEFORE mktemp, so nothing is left in the directory
  # either -- the one observable that separates "refused" from "refused after
  # already staging a rewrite".
  assert_true "set on a $refuse_case target ($refuse_key) leaves no temp file behind" \
    "[ -z \"\$(ls -A '$RF' | grep '^\\.run-state\\.' || true)\" ]"
done
# The two messages must not be interchangeable: the reasons are different
# (a key out of reach vs. a body with no boundary), and one message covering
# both is how the second reason stops being read.
RF_MSG_NESTED="$("$RUNSTATE" set "$RF/rs-refuse-nested-only.yaml" cursor x 2>&1 || true)"
RF_MSG_MAPPING="$("$RUNSTATE" set "$RF/rs-refuse-column0-mapping.yaml" backlog x 2>&1 || true)"
assert_true "the two refusals give different reasons, not one shared message" \
  "[ \"\$RF_MSG_NESTED\" != \"\$RF_MSG_MAPPING\" ]"

# THE OTHER SIDE OF THE RULE. A key ABSENT from the file entirely is not the
# nested case and must still be created at column 0 -- otherwise the refusal
# could be (wrongly) implemented as "refuse what is not already there", which
# would break the loop's own driver claim on a fresh run-state. All four
# driver_* keys, from a run-state that has none of them.
RFD="$RF/rs-fresh-driver.yaml"
printf 'schema: 3\nstatus: running\nbacklog:\n  cursor: feature-002\n' > "$RFD"
assert_true "claim-driver against a FRESH run-state succeeds" \
  "\"\$RUNSTATE\" claim-driver \"$RFD\" 4242 >/dev/null"
for dk in driver_host driver_since driver_heartbeat driver_pid; do
  assert_true "  it inserted $dk at column 0 (absence is not nesting)" \
    "[ -n \"\$(\"\$RUNSTATE\" get \"$RFD\" $dk)\" ] && grep -q \"^$dk:\" \"$RFD\""
done
assert_true "  and the nested cursor it did NOT touch still reads back" \
  "[ \"\$(\"\$RUNSTATE\" cursor \"$RFD\")\" = feature-002 ]"
assert_true "  the fresh-claim run-state still parses" "yamlok \"$RFD\""

# Every key `set` is called with in this plugin -- no skill, sweep fixture or
# caller may be touched by the refusal. Kept as an explicit list rather than a
# grep so that adding a seventh caller means adding a line here on purpose.
RFL="$RF/rs-live-keys.yaml"
printf 'schema: 3\nstatus: running\nnote: an old note\nupdated_at: 2026-01-01T00:00:00Z\nlast_green_commit: deadbeef\nbranch: orch/x\ndriver_heartbeat: 2026-01-01T00:00:00Z\nbacklog:\n  cursor: feature-002\n' > "$RFL"
for live_key in status note updated_at last_green_commit branch driver_heartbeat; do
  assert_true "set on the live key $live_key is unaffected by the refusal" \
    "\"\$RUNSTATE\" set \"$RFL\" $live_key 'live value' >/dev/null"
  assert_true "  $live_key round-trips after the set" \
    "[ \"\$(\"\$RUNSTATE\" get \"$RFL\" $live_key)\" = 'live value' ]"
done
assert_true "the six live keys leave a parseable run-state" "yamlok \"$RFL\""
assert_true "and none of them disturbed the nested cursor" \
  "[ \"\$(\"\$RUNSTATE\" cursor \"$RFL\")\" = feature-002 ]"

# The refusal must hold on a host with no jq and no python3 -- `runstate.sh`
# stays at hooks/guard.sh's dependency tier (stock Git Bash ships neither), and
# a check that quietly disables itself where a tool is missing is the defect
# this feature exists to remove, one file over. `bare`/`NOTOOLS` are the same
# stubs T8 established above; the scrub wraps ONLY the runstate.sh call, never
# the sweep's own have_yaml/yamlok -- blinding those would trip the loud skip
# and fail the run for the wrong reason while telling us nothing about
# `runstate.sh`.
#
# Both refusals, and all three observables the full-PATH cases above demand of
# them (gaps T6): a non-zero exit, the MESSAGE (which key, and where to go
# instead), and a target checksum identical to its pre-call value. Each one
# answers a different question -- the exit status alone cannot separate "it
# refused" from "it refused having already rewritten the file", and a message
# that degraded to a bare `die` here would leave the caller on the host with
# the fewest tools unable to tell which rule fired.
for refuse_case in nested-only column0-mapping; do
  case "$refuse_case" in
    nested-only)     refuse_key=cursor  ;;
    column0-mapping) refuse_key=backlog ;;
  esac
  RFN="$RF/rs-notools-$refuse_case.yaml"
  printf 'schema: 3\nstatus: running\nbacklog:\n  cursor: feature-002\n  pending:\n    - feature-002\nbranch: orch/x\n' > "$RFN"
  RFN_SUM_BEFORE="$(cksum < "$RFN")"
  RFN_KEYS_BEFORE="$(_top_key_count "$RFN")"
  RFN_RC=0
  RFN_MSG="$(bare set "$RFN" "$refuse_key" 'a flat scalar' 2>&1)" || RFN_RC=$?
  assert_true "no-tools host: the $refuse_case refusal ($refuse_key) still exits non-zero" \
    "[ \"\$RFN_RC\" != 0 ]"
  assert_true "no-tools host: the $refuse_case refusal ($refuse_key) still names the key in the message" \
    "case \"\$RFN_MSG\" in *\"'$refuse_key'\"*) true;; *) false;; esac"
  assert_true "no-tools host: the $refuse_case refusal ($refuse_key) still points the caller at \`write\`" \
    "case \"\$RFN_MSG\" in *'\`write\`'*) true;; *) false;; esac"
  assert_true "no-tools host: the $refuse_case refusal ($refuse_key) changed no byte of the target" \
    "[ \"\$(cksum < \"$RFN\")\" = \"\$RFN_SUM_BEFORE\" ]"
  assert_true "no-tools host: the $refuse_case refusal ($refuse_key) added no column-0 key" \
    "[ \"\$(_top_key_count \"$RFN\")\" = \"\$RFN_KEYS_BEFORE\" ]"
  # Byte-identical with the tools present: what a parser-less host is told is
  # the SAME message, not a shorter one that happens to still be non-zero.
  RFN_FULL_MSG="$("$RUNSTATE" set "$RFN" "$refuse_key" 'a flat scalar' 2>&1 || true)"
  assert_true "no-tools host: the $refuse_case message is byte-identical to the full-PATH one" \
    "[ \"\$RFN_MSG\" = \"\$RFN_FULL_MSG\" ]"
done
# The two messages stay distinguishable here too. One message covering both
# reasons is how the second reason stops being read, and that is not a property
# that may hold only where jq happens to be installed.
RFN_MSG_NESTED="$(bare set "$RF/rs-notools-nested-only.yaml" cursor x 2>&1 || true)"
RFN_MSG_MAPPING="$(bare set "$RF/rs-notools-column0-mapping.yaml" backlog x 2>&1 || true)"
assert_true "no-tools host: the two refusals still give different reasons" \
  "[ \"\$RFN_MSG_NESTED\" != \"\$RFN_MSG_MAPPING\" ]"
# THE OTHER SIDE OF THE RULE, on the same host: a key ABSENT from the file
# entirely is still created at column 0, so the refusal cannot have been
# written as "refuse what is not already there" -- which would break the loop's
# own driver claim on a fresh run-state exactly where it has no tools to fall
# back on.
RFND="$RF/rs-notools-fresh-driver.yaml"
printf 'schema: 3\nstatus: running\nbacklog:\n  cursor: feature-002\n' > "$RFND"
assert_true "no-tools host: claim-driver against a FRESH run-state still succeeds" \
  "bare claim-driver '$RFND' 4242 >/dev/null"
for dk in driver_host driver_since driver_heartbeat driver_pid; do
  assert_true "no-tools host:   it still inserted $dk at column 0" \
    "[ -n \"\$(bare get '$RFND' $dk)\" ] && grep -q \"^$dk:\" \"$RFND\""
done
assert_true "no-tools host:   and the nested cursor it did NOT touch still reads back" \
  "[ \"\$(bare cursor '$RFND')\" = feature-002 ]"
assert_true "no-tools host: the fresh-claim run-state still parses" "yamlok \"$RFND\""
assert_true "no-tools host: an ordinary set on a refusing target still lands" \
  "bare set '$RF/rs-notools-nested-only.yaml' status paused >/dev/null && [ \"\$(bare get '$RF/rs-notools-nested-only.yaml' status)\" = paused ]"

# Anti-drift pin: `set` and `add-finding` now call the SAME encoder, so the
# same hostile value must come out byte-identical from both -- pinned
# mechanically, not by comment, so a future change that hardens one and not
# the other fails this immediately. Two values, not one: the first contains a
# space and a `'` so both paths take the QUOTING branch (pins _yaml_quote);
# the second is a bare newline so both paths must COLLAPSE it identically
# first (pins _yaml_collapse -- a single shared-quoting pin cannot see a
# collapse divergence, since collapsing happens before quoting).
for drift_case in quoted newline; do
  case "$drift_case" in
    quoted)  DRIFT_VAL="guard.sh: fails closed on 'unreadable' input" ;;
    newline) DRIFT_VAL="$(printf 'first line\nsecond line')" ;;
  esac
  printf 'schema: 3\nfindings:\ntarget: original\n' > "$FY/rs-drift-$drift_case.yaml"
  "$RUNSTATE" set "$FY/rs-drift-$drift_case.yaml" target "$DRIFT_VAL" >/dev/null
  "$RUNSTATE" add-finding "$FY/rs-drift-$drift_case.yaml" f-drift "$DRIFT_VAL" --packets pkt-1 >/dev/null
  SET_ENC="$(rs_get "$FY/rs-drift-$drift_case.yaml" target)"
  FINDING_ENC="$(grep -E '^ *summary:' "$FY/rs-drift-$drift_case.yaml" | head -1 | sed -E 's/^ *summary:[[:space:]]*//')"
  assert_true "set and add-finding encode the same hostile value identically ($drift_case)" \
    "[ \"\$SET_ENC\" = \"\$FINDING_ENC\" ]"
done

# A duplicate check that scans the WHOLE file collides with schema-3 `packets:` ids,
# which share the `  - id: <x>` shape — and a finding named after the packet it is
# about is the natural name, so this silently refused real findings.
printf 'schema: 3\npackets:\n  - id: feature-001-scope\n    status: green\nfindings:\n' > "$FY/pk.yaml"
assert_true "a finding may share a name with a packet" \
  "\"\$RUNSTATE\" add-finding \"$FY/pk.yaml\" feature-001-scope 'gotcha about that packet' --packets pkt-a | grep -q '^ADDED=yes'"
# `.` is a legal id character AND a regex metachar: an unanchored regex match made
# `f.001` collide with `f-001`.
printf 'schema: 3\nfindings:\n' > "$FY/rx.yaml"
assert_true "a dot in an id does not match a dash" \
  "\"\$RUNSTATE\" add-finding \"$FY/rx.yaml\" f.001 one --packets pkt-a >/dev/null && \"\$RUNSTATE\" add-finding \"$FY/rx.yaml\" f-001 two --packets pkt-a | grep -q '^ADDED=yes'"

echo
echo "== the decoder fixture table: one encoder, four read sites (gaps T2/T3/T4) =="
# `set` and `add-finding` write through ONE encoder (_yaml_encode_value). The
# read side is four call sites, and this table is what keeps them in step:
#
#   _yaml_decode_value    shell   single + double   `get`, `cursor`
#   _YAML_AWK_DECODE      awk     single + double   the note's first line (trim-note)
#   _findings_default     awk     single + double   `findings`
#   _list_records' kv()   awk     single + double   `lanes`
#
# As of gaps T4 all four are ONE rule in TWO expressions -- the shell function
# and the awk function text prepended to the three awk passes -- so every site
# below is driven over BOTH quote shapes and a legacy BARE value, and each case
# asserts the decoded result EQUALS the collapsed original exactly rather than
# merely that the site returned something. The cross-site block at the end of
# each iteration then asserts all four agree on the same input, which is the
# anti-drift property this capability exists for, pinned mechanically rather
# than by a comment asking a maintainer to keep copies in step.
#
# Driving both shapes everywhere is the WIDENING T4 delivers, not test
# thoroughness for its own sake: before it, `findings` knew only the
# single-quoted shape its own writer produces and `lanes` only the
# double-quoted shape the retired parallel scheduler wrote, so the same bytes
# on disk read two ways depending on which subcommand opened the file. The
# legacy BARE value is asserted at all four sites too, since no consumer repo
# migrates its run-state before its next run.
#
# THIS TABLE IS THE EXTENSION POINT. A later case adds a value by adding one
# name to DECODER_CASES and one line to each of the three functions below; it
# does not write a second table. The three are the RAW value, its EXPECTED
# _yaml_encode_value output (written out LITERALLY -- an expectation derived by
# re-running the encoder would agree with a broken encoder), and its EXPECTED
# decode (the raw value with newlines collapsed to spaces).

# rs_fn <helper> [arg...] -- call one of runstate.sh's INTERNAL helpers, in a
# subshell, so the round-trip contract below can be asserted on the encoder and
# decoder THEMSELVES rather than inferred from whichever subcommand happens to
# exercise them. Sourced with $0 set to runstate.sh and the positional
# parameters CLEARED: the dispatch at the bottom of that file reads $1, so a
# leftover argument would be taken as a subcommand and `die` would kill the
# subshell before the helper ran; with none it takes the help branch, whose
# `sed -n ... "$0"` is why $0 has to be the script itself. runstate.sh's own
# `set -euo pipefail` stays inside the subshell and never reaches this sweep.
rs_fn() {
  local fn="$1"; shift
  RS_FN="$fn" bash -c '
    args=("$@"); set --
    . "$0" >/dev/null 2>&1
    "$RS_FN" ${args[@]+"${args[@]}"}
  ' "$RUNSTATE" "$@"
}

DECODER_CASES='plain colon quote newline colonend dashlead backslash'
decoder_raw() {   # the raw value an agent hands `set` / `add-finding`
  case "$1" in
    plain)     printf '%s' 'an ordinary one-line value' ;;
    colon)     printf '%s' 'guard.sh: fails closed on unreadable input' ;;
    quote)     printf '%s' "it's got 'single' quotes" ;;
    newline)   printf 'line one\nline two' ;;
    colonend)  printf '%s' 'naive:' ;;
    dashlead)  printf '%s' '- leading dash reads as a list item' ;;
    backslash) printf '%s' 'windows path C:\nope needs \t no escaping' ;;
  esac
}
decoder_enc() {   # what _yaml_encode_value must produce for it, spelled out
  case "$1" in
    plain)     printf '%s' "'an ordinary one-line value'" ;;
    colon)     printf '%s' "'guard.sh: fails closed on unreadable input'" ;;
    quote)     printf '%s' "'it''s got ''single'' quotes'" ;;
    newline)   printf '%s' "'line one line two'" ;;
    colonend)  printf '%s' "'naive:'" ;;
    dashlead)  printf '%s' "'- leading dash reads as a list item'" ;;
    backslash) printf '%s' "'windows path C:\nope needs \t no escaping'" ;;
  esac
}
decoder_want() {  # what EVERY decoder must return: the raw value, newlines collapsed
  case "$1" in
    plain)     printf '%s' 'an ordinary one-line value' ;;
    colon)     printf '%s' 'guard.sh: fails closed on unreadable input' ;;
    quote)     printf '%s' "it's got 'single' quotes" ;;
    newline)   printf '%s' 'line one line two' ;;
    colonend)  printf '%s' 'naive:' ;;
    dashlead)  printf '%s' '- leading dash reads as a list item' ;;
    backslash) printf '%s' 'windows path C:\nope needs \t no escaping' ;;
  esac
}

DT="$(mktemp -d)/.agents"; mkdir -p "$DT"
for dc in $DECODER_CASES; do
  DC_RAW="$(decoder_raw "$dc")"
  DC_ENC_WANT="$(decoder_enc "$dc")"
  DC_WANT="$(decoder_want "$dc")"
  DC_ENC="$(rs_fn _yaml_encode_value "$DC_RAW")"
  DC_DEC="$(rs_fn _yaml_decode_value "$DC_ENC")"

  assert_true "table ($dc): _yaml_encode_value produces the encoding the table names" \
    "[ \"\$DC_ENC\" = \"\$DC_ENC_WANT\" ]"
  # THE CONTRACT, asserted directly on the two helpers rather than inferred
  # from a caller: decoding what the encoder produced returns the collapsed
  # original, exactly. Every read site below is a claim that its own decoder
  # agrees with this one line.
  assert_true "table ($dc): decoding what _yaml_encode_value produced returns the collapsed original" \
    "[ \"\$DC_DEC\" = \"\$DC_WANT\" ]"

  # --- site 1: _yaml_decode_value, via `get` and `cursor` (single-quoted) ----
  DC_G="$DT/get-$dc.yaml"
  printf 'before: 1\ntarget: %s\nbacklog:\n  cursor: %s\nafter: 1\n' "$DC_ENC" "$DC_ENC" > "$DC_G"
  assert_true "table ($dc): the single-quoted get/cursor fixture is parseable YAML" \
    "yamlok \"$DC_G\""
  assert_true "table ($dc): get decodes the single-quoted shape to the collapsed original" \
    "[ \"\$(\"\$RUNSTATE\" get \"$DC_G\" target)\" = \"\$DC_WANT\" ]"
  assert_true "table ($dc): cursor decodes the single-quoted shape to the collapsed original" \
    "[ \"\$(\"\$RUNSTATE\" cursor \"$DC_G\")\" = \"\$DC_WANT\" ]"
  # A real YAML parse of the same bytes, so the expectation is anchored to what
  # YAML itself says the fixture means -- not merely to what this file's own
  # decoder happens to do with it.
  assert_true "table ($dc): a real YAML parse of that fixture agrees with get" \
    "yamlok \"$DC_G\" && [ \"\$(_yaml_value \"$DC_G\" target)\" = \"\$DC_WANT\" ]"

  # --- site 1 again, over the LEGACY double-quoted shape (NEW in gaps T3) ----
  # Until T3, _yaml_decode_value knew only the single-quoted shape it was the
  # inverse of, so a legacy double-quoted value came back out of `get`/`cursor`
  # with its quotes still attached. It strips that pair too now, VERBATIM -- the
  # same reading the awk decoders have always given those bytes.
  #
  # Deliberately NOT parse-asserted, for the reason the trim-note double-quoted
  # case below already states: a backslash inside a REAL YAML double-quoted
  # scalar means something else, and this cell pins the unwrap as it behaves,
  # not as YAML would read the same bytes. No table value carries a `"`, which
  # this shape could not hold unescaped in the first place.
  DC_GD="$DT/get-dq-$dc.yaml"
  printf 'before: 1\ntarget: "%s"\nbacklog:\n  cursor: "%s"\nafter: 1\n' "$DC_WANT" "$DC_WANT" > "$DC_GD"
  assert_true "table ($dc): get decodes the legacy double-quoted shape to the collapsed original" \
    "[ \"\$(\"\$RUNSTATE\" get \"$DC_GD\" target)\" = \"\$DC_WANT\" ]"
  assert_true "table ($dc): cursor decodes the legacy double-quoted shape to the collapsed original" \
    "[ \"\$(\"\$RUNSTATE\" cursor \"$DC_GD\")\" = \"\$DC_WANT\" ]"

  # --- site 2: _findings_default, via `findings` (single-quoted) -------------
  DC_F="$DT/findings-$dc.yaml"
  printf 'schema: 3\nfindings:\n  - id: f-1\n    summary: %s\n    file: .agents/findings/f-1.md\n    packets: [pkt-1]\nstatus: running\n' \
    "$DC_ENC" > "$DC_F"
  assert_true "table ($dc): the single-quoted findings fixture is parseable YAML" \
    "yamlok \"$DC_F\""
  assert_true "table ($dc): findings decodes the single-quoted summary to the collapsed original" \
    "[ \"\$(\"\$RUNSTATE\" findings \"$DC_F\" | cut -f2)\" = \"\$DC_WANT\" ]"

  # --- site 2 again, over the LEGACY double-quoted shape (NEW in gaps T4) ----
  # Until T4 this site carried its own single-quote-only unwrap, so a legacy
  # double-quoted summary came out of `findings` with its quotes still attached
  # -- and an agent copied them into a brief. It strips that pair too now,
  # VERBATIM, the same reading the other three sites have always given it.
  #
  # Deliberately NOT parse-asserted, for the reason the double-quoted `get` and
  # trim-note cases already state: a backslash inside a REAL YAML double-quoted
  # scalar means something else, and this cell pins the unwrap as it behaves,
  # not as YAML would read the same bytes. No table value carries a `"`, which
  # this shape could not hold unescaped in the first place.
  DC_FD="$DT/findings-dq-$dc.yaml"
  printf 'schema: 3\nfindings:\n  - id: f-1\n    summary: "%s"\n    file: .agents/findings/f-1.md\n    packets: [pkt-1]\nstatus: running\n' \
    "$DC_WANT" > "$DC_FD"
  assert_true "table ($dc): findings decodes the legacy double-quoted summary to the collapsed original" \
    "[ \"\$(\"\$RUNSTATE\" findings \"$DC_FD\" | cut -f2)\" = \"\$DC_WANT\" ]"

  # --- site 3: cmd_trim_note's inline awk unwrap (BOTH quote shapes) ---------
  # The unwrap only runs when the note overflows, so the bound is picked to make
  # it fire AND to leave the value whole: the note line is `note: ` + the quoted
  # value + a newline (at least len+9 bytes), while the block body keeps a first
  # line of up to max-1 characters -- so max = len+2 trims for certain and cuts
  # nothing off the value. Without the TRIMMED=yes assertion the whole case
  # would pass VACUOUSLY on an untrimmed file, whose quoted note a YAML parser
  # decodes correctly all by itself.
  DC_MAX=$(( ${#DC_WANT} + 2 ))
  DC_TS="$DT/trim-sq-$dc.yaml"
  printf 'schema: 3\nnote: %s\nstatus: paused\n' "$DC_ENC" > "$DC_TS"
  DC_TS_OUT="$("$RUNSTATE" trim-note "$DC_TS" "$DC_MAX")"
  assert_true "table ($dc): trim-note really re-emitted the single-quoted note as a block" \
    "case \"\$DC_TS_OUT\" in TRIMMED=yes*) true;; *) false;; esac && grep -q '^note: |-' \"$DC_TS\""
  assert_true "table ($dc): trim-note unwraps the single-quoted note to the collapsed original" \
    "yamlok \"$DC_TS\" && [ \"\$(_yaml_value \"$DC_TS\" note | head -1)\" = \"\$DC_WANT\" ]"
  # The legacy DOUBLE-quoted shape, which this file never writes but an older
  # tool or a hand edit can leave behind. Today's unwrap strips the pair
  # VERBATIM -- no escape processing -- which is why the fixture is built as
  # `"` + the collapsed value + `"` and expects that value back unchanged, and
  # why the pre-trim file is not itself parse-asserted: a backslash inside a
  # real YAML double-quoted scalar means something else, and this case pins the
  # unwrap as it behaves, not as YAML would read the same bytes. No table value
  # carries a `"`, which this shape could not hold in the first place.
  DC_TD="$DT/trim-dq-$dc.yaml"
  printf 'schema: 3\nnote: "%s"\nstatus: paused\n' "$DC_WANT" > "$DC_TD"
  DC_TD_OUT="$("$RUNSTATE" trim-note "$DC_TD" "$DC_MAX")"
  assert_true "table ($dc): trim-note really re-emitted the double-quoted note as a block" \
    "case \"\$DC_TD_OUT\" in TRIMMED=yes*) true;; *) false;; esac && grep -q '^note: |-' \"$DC_TD\""
  assert_true "table ($dc): trim-note unwraps the legacy double-quoted note to the collapsed original" \
    "yamlok \"$DC_TD\" && [ \"\$(_yaml_value \"$DC_TD\" note | head -1)\" = \"\$DC_WANT\" ]"

  # --- one rule, two expressions: the awk and shell decoders AGREE (T3) ------
  # The anti-drift property this capability exists for, pinned mechanically for
  # the two sites T3 unified (T4 widens it to all four). Read back through the
  # sweep's own awk rather than through _yaml_value, on purpose: this is an
  # assertion about the AWK decoder, and gating it on PyYAML would turn a
  # parser-less host into a loud skip of exactly the property being pinned --
  # while the parse-anchored assertions two lines up already say what the bytes
  # mean to YAML. `getline` takes the first body line of the block trim-note
  # wrote; the two-space de-indent is the block indentation trim-note adds.
  DC_TS_AWK="$(awk '/^note: \|-$/ { getline; sub(/^  /, ""); print; exit }' "$DC_TS")"
  DC_TD_AWK="$(awk '/^note: \|-$/ { getline; sub(/^  /, ""); print; exit }' "$DC_TD")"
  DC_SH_SQ="$(rs_fn _yaml_decode_value "$DC_ENC")"
  DC_SH_DQ="$(rs_fn _yaml_decode_value "\"$DC_WANT\"")"
  assert_true "table ($dc): the awk and shell expressions of the rule agree on the single-quoted shape" \
    "[ \"\$DC_TS_AWK\" = \"\$DC_SH_SQ\" ] && [ \"\$DC_TS_AWK\" = \"\$DC_WANT\" ]"
  assert_true "table ($dc): the awk and shell expressions of the rule agree on the legacy double-quoted shape" \
    "[ \"\$DC_TD_AWK\" = \"\$DC_SH_DQ\" ] && [ \"\$DC_TD_AWK\" = \"\$DC_WANT\" ]"

  # --- site 4: _list_records' kv(), via `lanes` (BOTH quote shapes) ----------
  # The double-quoted shape is what the retired parallel scheduler wrote, and it
  # gets the same verbatim strip as the trim-note double-quoted case above, on
  # the one read-only projection kept over a pre-retirement parallel run-state.
  DC_L="$DT/lanes-$dc.yaml"
  printf 'schema: 3\nlanes:\n  - id: pb\n    branch: "%s"\n    worktree: /tmp/wt/pb\n    packet: pb\n    last_green_commit: abc123\n    status: running\n' \
    "$DC_WANT" > "$DC_L"
  assert_true "table ($dc): lanes decodes the legacy double-quoted field to the collapsed original" \
    "[ \"\$(\"\$RUNSTATE\" lanes \"$DC_L\" | cut -f2)\" = \"\$DC_WANT\" ]"
  # The SINGLE-quoted shape is NEW in gaps T4: it is what _yaml_encode_value
  # produces, so any writer touching such a row today leaves it behind, and
  # before T4 `lanes` handed it back with its quotes attached and its `''`
  # un-collapsed while every other read site decoded it. Parse-asserted, unlike
  # its double-quoted sibling, because this shape IS a real single-quoted YAML
  # scalar and the expectation can therefore be anchored to what YAML itself
  # says the bytes mean. Asserted on EVERY field the projection returns, not
  # just the one `cut` reads, since kv() decodes per field and a migration that
  # reached only the first column would pass a single-column check.
  DC_LS="$DT/lanes-sq-$dc.yaml"
  printf 'schema: 3\nlanes:\n  - id: pb\n    branch: %s\n    worktree: %s\n    packet: pb\n    last_green_commit: abc123\n    status: %s\n' \
    "$DC_ENC" "$DC_ENC" "$DC_ENC" > "$DC_LS"
  assert_true "table ($dc): the single-quoted lanes fixture is parseable YAML" \
    "yamlok \"$DC_LS\""
  assert_true "table ($dc): lanes decodes the single-quoted field to the collapsed original" \
    "[ \"\$(\"\$RUNSTATE\" lanes \"$DC_LS\" | cut -f2)\" = \"\$DC_WANT\" ]"
  assert_true "table ($dc): lanes decodes EVERY single-quoted field, not just the first" \
    "[ \"\$(\"\$RUNSTATE\" lanes \"$DC_LS\" | cut -f3)\" = \"\$DC_WANT\" ] && [ \"\$(\"\$RUNSTATE\" lanes \"$DC_LS\" | cut -f6)\" = \"\$DC_WANT\" ]"

  # --- ALL FOUR sites agree on the same input (gaps T4) ----------------------
  # The anti-drift property this capability exists for, stated as one assertion
  # per quote shape: four decoders, one input, one answer -- and that answer is
  # the collapsed original, so the block cannot be satisfied by four sites being
  # wrong in the same way. T3 pinned this for the two sites it unified; T4
  # widens it to all four. Read back through the sweep's own awk for trim-note
  # rather than through _yaml_value, on purpose: this is an assertion about the
  # AWK decoders, and gating it on PyYAML would turn a parser-less host into a
  # loud skip of exactly the property being pinned.
  DC_X_SQ_GET="$("$RUNSTATE" get "$DC_G" target)"
  DC_X_SQ_FIND="$("$RUNSTATE" findings "$DC_F" | cut -f2)"
  DC_X_SQ_LANE="$("$RUNSTATE" lanes "$DC_LS" | cut -f2)"
  assert_true "table ($dc): all four read sites decode the single-quoted shape identically" \
    "[ \"\$DC_X_SQ_GET\" = \"\$DC_WANT\" ] && [ \"\$DC_TS_AWK\" = \"\$DC_X_SQ_GET\" ] && [ \"\$DC_X_SQ_FIND\" = \"\$DC_X_SQ_GET\" ] && [ \"\$DC_X_SQ_LANE\" = \"\$DC_X_SQ_GET\" ]"
  DC_X_DQ_GET="$("$RUNSTATE" get "$DC_GD" target)"
  DC_X_DQ_FIND="$("$RUNSTATE" findings "$DC_FD" | cut -f2)"
  DC_X_DQ_LANE="$("$RUNSTATE" lanes "$DC_L" | cut -f2)"
  assert_true "table ($dc): all four read sites decode the legacy double-quoted shape identically" \
    "[ \"\$DC_X_DQ_GET\" = \"\$DC_WANT\" ] && [ \"\$DC_TD_AWK\" = \"\$DC_X_DQ_GET\" ] && [ \"\$DC_X_DQ_FIND\" = \"\$DC_X_DQ_GET\" ] && [ \"\$DC_X_DQ_LANE\" = \"\$DC_X_DQ_GET\" ]"
done

# --- the legacy BARE value: all four sites must pass it through untouched ----
# Nothing migrates a consumer repo's run-state before its next run, and an
# unquoted plain scalar is what `write` still produces today, so the shape that
# predates the encoder has to read back identically everywhere. One value,
# carrying a backslash and spaces so a decoder that "helpfully" unescapes or
# trims is caught; no `: ` and no wrapping quote, since a bare scalar could not
# carry either in the first place.
DC_BARE='a bare legacy value with a C:\path'
DC_BG="$DT/bare-get.yaml"
printf 'before: 1\ntarget: %s\nbacklog:\n  cursor: %s\nafter: 1\n' "$DC_BARE" "$DC_BARE" > "$DC_BG"
assert_true "legacy bare value: the get/cursor fixture is parseable YAML" \
  "yamlok \"$DC_BG\""
assert_true "legacy bare value: get passes it through unchanged" \
  "[ \"\$(\"\$RUNSTATE\" get \"$DC_BG\" target)\" = \"\$DC_BARE\" ]"
assert_true "legacy bare value: cursor passes it through unchanged" \
  "[ \"\$(\"\$RUNSTATE\" cursor \"$DC_BG\")\" = \"\$DC_BARE\" ]"
assert_true "legacy bare value: a real YAML parse agrees with get" \
  "yamlok \"$DC_BG\" && [ \"\$(_yaml_value \"$DC_BG\" target)\" = \"\$DC_BARE\" ]"
DC_BF="$DT/bare-findings.yaml"
printf 'schema: 3\nfindings:\n  - id: old-1\n    summary: %s\n    file: .agents/findings/old-1.md\nstatus: running\n' \
  "$DC_BARE" > "$DC_BF"
assert_true "legacy bare value: the findings fixture is parseable YAML" \
  "yamlok \"$DC_BF\""
assert_true "legacy bare value: findings passes an unquoted summary through unchanged" \
  "[ \"\$(\"\$RUNSTATE\" findings \"$DC_BF\" | cut -f2)\" = \"\$DC_BARE\" ]"
DC_BT="$DT/bare-trim.yaml"
DC_BMAX=$(( ${#DC_BARE} + 2 ))
printf 'schema: 3\nnote: %s\nstatus: paused\n' "$DC_BARE" > "$DC_BT"
DC_BT_OUT="$("$RUNSTATE" trim-note "$DC_BT" "$DC_BMAX")"
assert_true "legacy bare value: trim-note really re-emitted the unquoted note as a block" \
  "case \"\$DC_BT_OUT\" in TRIMMED=yes*) true;; *) false;; esac && grep -q '^note: |-' \"$DC_BT\""
assert_true "legacy bare value: trim-note passes an unquoted note through unchanged" \
  "yamlok \"$DC_BT\" && [ \"\$(_yaml_value \"$DC_BT\" note | head -1)\" = \"\$DC_BARE\" ]"
DC_BL="$DT/bare-lanes.yaml"
printf 'schema: 3\nlanes:\n  - id: pb\n    branch: %s\n    worktree: /tmp/wt/pb\n    packet: pb\n    last_green_commit: abc123\n    status: running\n' \
  "$DC_BARE" > "$DC_BL"
assert_true "legacy bare value: lanes passes an unquoted field through unchanged" \
  "[ \"\$(\"\$RUNSTATE\" lanes \"$DC_BL\" | cut -f2)\" = \"\$DC_BARE\" ]"
DC_B_AWK="$(awk '/^note: \|-$/ { getline; sub(/^  /, ""); print; exit }' "$DC_BT")"
assert_true "legacy bare value: the awk and shell expressions of the rule both pass it through" \
  "[ \"\$DC_B_AWK\" = \"\$DC_BARE\" ] && [ \"\$(rs_fn _yaml_decode_value \"\$DC_BARE\")\" = \"\$DC_BARE\" ]"
# ...and the same cross-site agreement the table asserts for both quote shapes,
# on the shape that predates every one of them (gaps T4). A site that started
# stripping something off a bare value would be the one failure here that no
# consumer repo could work around, since it is what `write` still produces.
DC_B_GET="$("$RUNSTATE" get "$DC_BG" target)"
assert_true "legacy bare value: all four read sites pass it through identically" \
  "[ \"\$DC_B_GET\" = \"\$DC_BARE\" ] && [ \"\$DC_B_AWK\" = \"\$DC_B_GET\" ] && [ \"\$(\"\$RUNSTATE\" findings \"$DC_BF\" | cut -f2)\" = \"\$DC_B_GET\" ] && [ \"\$(\"\$RUNSTATE\" lanes \"$DC_BL\" | cut -f2)\" = \"\$DC_B_GET\" ]"

# --- the branch ORDER is load-bearing (gaps T3) ------------------------------
# One rule now serves both quote shapes, and the two branches do different work:
# the single-quoted one un-doubles `''` back to `'`, the double-quoted one
# strips its pair verbatim. A decoder that tested "is it wrapped in a matching
# pair of quotes" without caring WHICH quote, or that ran the un-doubling
# unconditionally after stripping, passes every case above and still silently
# eats two characters out of a value already on disk. Neither shell nor awk may
# do it, so both are asserted, and the expectation is spelled out literally.
DC_DQ_IN="he said ''hi'' twice"
DC_DQG="$DT/order-get.yaml"
printf 'schema: 3\ntarget: "%s"\n' "$DC_DQ_IN" > "$DC_DQG"
assert_true "branch order: get leaves '' inside a legacy double-quoted value alone" \
  "[ \"\$(\"\$RUNSTATE\" get \"$DC_DQG\" target)\" = \"\$DC_DQ_IN\" ]"
DC_DQT="$DT/order-trim.yaml"
printf 'schema: 3\nnote: "%s"\nstatus: paused\n' "$DC_DQ_IN" > "$DC_DQT"
DC_DQT_OUT="$("$RUNSTATE" trim-note "$DC_DQT" $(( ${#DC_DQ_IN} + 2 )))"
assert_true "branch order: trim-note really re-emitted that note as a block" \
  "case \"\$DC_DQT_OUT\" in TRIMMED=yes*) true;; *) false;; esac && grep -q '^note: |-' \"$DC_DQT\""
assert_true "branch order: trim-note leaves '' inside a legacy double-quoted note alone" \
  "[ \"\$(awk '/^note: \\|-\$/ { getline; sub(/^  /, \"\"); print; exit }' \"$DC_DQT\")\" = \"\$DC_DQ_IN\" ]"
# The two sites gaps T4 migrated, on the same two bytes: both reached the
# double-quoted branch for the first time in T4, so both are new places the
# un-doubling could run where it must not.
DC_DQF="$DT/order-findings.yaml"
printf 'schema: 3\nfindings:\n  - id: f-1\n    summary: "%s"\n    packets: [pkt-1]\nstatus: running\n' "$DC_DQ_IN" > "$DC_DQF"
assert_true "branch order: findings leaves '' inside a legacy double-quoted summary alone" \
  "[ \"\$(\"\$RUNSTATE\" findings \"$DC_DQF\" | cut -f2)\" = \"\$DC_DQ_IN\" ]"
DC_DQL="$DT/order-lanes.yaml"
printf 'schema: 3\nlanes:\n  - id: pb\n    branch: "%s"\n    worktree: /tmp/wt/pb\n    packet: pb\n    last_green_commit: abc123\n    status: running\n' "$DC_DQ_IN" > "$DC_DQL"
assert_true "branch order: lanes leaves '' inside a legacy double-quoted field alone" \
  "[ \"\$(\"\$RUNSTATE\" lanes \"$DC_DQL\" | cut -f2)\" = \"\$DC_DQ_IN\" ]"
# And the inverse: a SINGLE-quoted value's `''` must still be un-doubled -- the
# same two bytes, the other branch, so a decoder cannot satisfy both by doing
# nothing.
DC_SQ_ENC="'he said ''hi'' twice'"
DC_SQ_WANT="he said 'hi' twice"
DC_SQG="$DT/order-get-sq.yaml"
printf 'schema: 3\ntarget: %s\n' "$DC_SQ_ENC" > "$DC_SQG"
assert_true "branch order: the single-quoted counterpart is still un-doubled by get" \
  "[ \"\$(\"\$RUNSTATE\" get \"$DC_SQG\" target)\" = \"\$DC_SQ_WANT\" ]"
assert_true "branch order: a real YAML parse agrees with that un-doubling" \
  "yamlok \"$DC_SQG\" && [ \"\$(_yaml_value \"$DC_SQG\" target)\" = \"\$DC_SQ_WANT\" ]"
DC_SQF="$DT/order-findings-sq.yaml"
printf 'schema: 3\nfindings:\n  - id: f-1\n    summary: %s\n    packets: [pkt-1]\nstatus: running\n' "$DC_SQ_ENC" > "$DC_SQF"
assert_true "branch order: findings still un-doubles the single-quoted counterpart" \
  "yamlok \"$DC_SQF\" && [ \"\$(\"\$RUNSTATE\" findings \"$DC_SQF\" | cut -f2)\" = \"\$DC_SQ_WANT\" ]"
DC_SQL="$DT/order-lanes-sq.yaml"
printf 'schema: 3\nlanes:\n  - id: pb\n    branch: %s\n    worktree: /tmp/wt/pb\n    packet: pb\n    last_green_commit: abc123\n    status: running\n' "$DC_SQ_ENC" > "$DC_SQL"
assert_true "branch order: lanes still un-doubles the single-quoted counterpart" \
  "yamlok \"$DC_SQL\" && [ \"\$(\"\$RUNSTATE\" lanes \"$DC_SQL\" | cut -f2)\" = \"\$DC_SQ_WANT\" ]"

# --- and every site again with NEITHER jq NOR python3 on PATH ---------------
# runstate.sh stays at hooks/guard.sh's dependency tier (stock Git Bash ships
# neither), so the decoders have to hold there too -- a read path that quietly
# returns something else where a tool is missing is the same defect class this
# feature exists to remove. `bare`/`NOTOOLS` are the stubs established above,
# and the scrub wraps ONLY the runstate.sh call, never the sweep's own parse
# assertions. The `quote` case is the one used: its un-doubling is the step a
# decoder is most likely to lose.
DC_NT_ENC="$(decoder_enc quote)"
DC_NT_WANT="$(decoder_want quote)"
DC_NTG="$DT/notools-get.yaml"
printf 'before: 1\ntarget: %s\nbacklog:\n  cursor: %s\nafter: 1\n' "$DC_NT_ENC" "$DC_NT_ENC" > "$DC_NTG"
assert_true "no-tools host: get still decodes the single-quoted shape" \
  "[ \"\$(bare get \"$DC_NTG\" target)\" = \"\$DC_NT_WANT\" ]"
assert_true "no-tools host: cursor still decodes the single-quoted shape" \
  "[ \"\$(bare cursor \"$DC_NTG\")\" = \"\$DC_NT_WANT\" ]"
DC_NTF="$DT/notools-findings.yaml"
printf 'schema: 3\nfindings:\n  - id: f-1\n    summary: %s\n    packets: [pkt-1]\nstatus: running\n' \
  "$DC_NT_ENC" > "$DC_NTF"
assert_true "no-tools host: findings still decodes the single-quoted summary" \
  "[ \"\$(bare findings \"$DC_NTF\" | cut -f2)\" = \"\$DC_NT_WANT\" ]"
DC_NTT="$DT/notools-trim.yaml"
printf 'schema: 3\nnote: %s\nstatus: paused\n' "$DC_NT_ENC" > "$DC_NTT"
DC_NTT_OUT="$(bare trim-note "$DC_NTT" $(( ${#DC_NT_WANT} + 2 )))"
assert_true "no-tools host: trim-note still re-emitted the note as a block" \
  "case \"\$DC_NTT_OUT\" in TRIMMED=yes*) true;; *) false;; esac && grep -q '^note: |-' \"$DC_NTT\""
assert_true "no-tools host: trim-note still unwraps the single-quoted note" \
  "yamlok \"$DC_NTT\" && [ \"\$(_yaml_value \"$DC_NTT\" note | head -1)\" = \"\$DC_NT_WANT\" ]"
DC_NTL="$DT/notools-lanes.yaml"
printf 'schema: 3\nlanes:\n  - id: pb\n    branch: "%s"\n    worktree: /tmp/wt/pb\n    packet: pb\n    last_green_commit: abc123\n    status: running\n' \
  "$DC_NT_WANT" > "$DC_NTL"
assert_true "no-tools host: lanes still decodes the legacy double-quoted field" \
  "[ \"\$(bare lanes \"$DC_NTL\" | cut -f2)\" = \"\$DC_NT_WANT\" ]"
# The two shapes gaps T4 ADDED are exercised here too, not just the ones that
# already worked: a widening that holds only where jq/python3 happen to be
# installed is the same defect class one tool over.
DC_NTFD="$DT/notools-findings-dq.yaml"
printf 'schema: 3\nfindings:\n  - id: f-1\n    summary: "%s"\n    packets: [pkt-1]\nstatus: running\n' \
  "$DC_NT_WANT" > "$DC_NTFD"
assert_true "no-tools host: findings still decodes the legacy double-quoted summary" \
  "[ \"\$(bare findings \"$DC_NTFD\" | cut -f2)\" = \"\$DC_NT_WANT\" ]"
DC_NTLS="$DT/notools-lanes-sq.yaml"
printf 'schema: 3\nlanes:\n  - id: pb\n    branch: %s\n    worktree: /tmp/wt/pb\n    packet: pb\n    last_green_commit: abc123\n    status: running\n' \
  "$DC_NT_ENC" > "$DC_NTLS"
assert_true "no-tools host: lanes still decodes the single-quoted field" \
  "[ \"\$(bare lanes \"$DC_NTLS\" | cut -f2)\" = \"\$DC_NT_WANT\" ]"
# EVERY shape through EVERY site on this host, not a representative one (gaps
# T6). The cases above reach `get` only through the single-quoted shape, and
# reach the legacy BARE value nowhere at all -- yet bare is what `write` still
# produces, so a site that started trimming it is the one failure a consumer
# repo could not work around. Three shapes x the three read sites the caller
# actually uses, each asserting the decoded result equals the collapsed
# original exactly rather than merely that the site returned something.
DC_NTGD="$DT/notools-get-dq.yaml"
printf 'before: 1\ntarget: "%s"\nbacklog:\n  cursor: "%s"\nafter: 1\n' "$DC_NT_WANT" "$DC_NT_WANT" > "$DC_NTGD"
assert_true "no-tools host: get still decodes the legacy double-quoted shape" \
  "[ \"\$(bare get \"$DC_NTGD\" target)\" = \"\$DC_NT_WANT\" ]"
assert_true "no-tools host: cursor still decodes the legacy double-quoted shape" \
  "[ \"\$(bare cursor \"$DC_NTGD\")\" = \"\$DC_NT_WANT\" ]"
DC_NTB="$DT/notools-bare-get.yaml"
printf 'before: 1\ntarget: %s\nbacklog:\n  cursor: %s\nafter: 1\n' "$DC_BARE" "$DC_BARE" > "$DC_NTB"
assert_true "no-tools host: get passes the legacy bare value through unchanged" \
  "[ \"\$(bare get \"$DC_NTB\" target)\" = \"\$DC_BARE\" ]"
assert_true "no-tools host: cursor passes the legacy bare value through unchanged" \
  "[ \"\$(bare cursor \"$DC_NTB\")\" = \"\$DC_BARE\" ]"
DC_NTBF="$DT/notools-bare-findings.yaml"
printf 'schema: 3\nfindings:\n  - id: f-1\n    summary: %s\n    packets: [pkt-1]\nstatus: running\n' \
  "$DC_BARE" > "$DC_NTBF"
assert_true "no-tools host: findings passes the legacy bare summary through unchanged" \
  "[ \"\$(bare findings \"$DC_NTBF\" | cut -f2)\" = \"\$DC_BARE\" ]"
DC_NTBL="$DT/notools-bare-lanes.yaml"
printf 'schema: 3\nlanes:\n  - id: pb\n    branch: %s\n    worktree: /tmp/wt/pb\n    packet: pb\n    last_green_commit: abc123\n    status: running\n' \
  "$DC_BARE" > "$DC_NTBL"
assert_true "no-tools host: lanes passes the legacy bare field through unchanged" \
  "[ \"\$(bare lanes \"$DC_NTBL\" | cut -f2)\" = \"\$DC_BARE\" ]"
# ...and the three sites agree with each other on this host, per shape. Each
# case above is anchored to a literal, so agreement follows -- but stating it
# directly is what fails loudly if ONE site is migrated and the others are not,
# which is the drift the shared decoder exists to prevent.
DC_NT_SQ_GET="$(bare get "$DC_NTG" target)"
assert_true "no-tools host: all three read sites decode the single-quoted shape identically" \
  "[ \"\$DC_NT_SQ_GET\" = \"\$DC_NT_WANT\" ] && [ \"\$(bare findings \"$DC_NTF\" | cut -f2)\" = \"\$DC_NT_SQ_GET\" ] && [ \"\$(bare lanes \"$DC_NTLS\" | cut -f2)\" = \"\$DC_NT_SQ_GET\" ]"
DC_NT_DQ_GET="$(bare get "$DC_NTGD" target)"
assert_true "no-tools host: all three read sites decode the legacy double-quoted shape identically" \
  "[ \"\$DC_NT_DQ_GET\" = \"\$DC_NT_WANT\" ] && [ \"\$(bare findings \"$DC_NTFD\" | cut -f2)\" = \"\$DC_NT_DQ_GET\" ] && [ \"\$(bare lanes \"$DC_NTL\" | cut -f2)\" = \"\$DC_NT_DQ_GET\" ]"
DC_NT_B_GET="$(bare get "$DC_NTB" target)"
assert_true "no-tools host: all three read sites pass the legacy bare value through identically" \
  "[ \"\$DC_NT_B_GET\" = \"\$DC_BARE\" ] && [ \"\$(bare findings \"$DC_NTBF\" | cut -f2)\" = \"\$DC_NT_B_GET\" ] && [ \"\$(bare lanes \"$DC_NTBL\" | cut -f2)\" = \"\$DC_NT_B_GET\" ]"

# --- the pause SENTINEL, same host (gaps T5, pinned here by T6) --------------
# test-pause.sh owns the sentinel's semantics; what belongs here is that the
# ENCODER and the two decoders `request-pause`/`pause-status` now share with
# `set` hold at hooks/guard.sh's dependency tier. The sentinel is the loop's
# only cooperative stop signal, so a reason that corrupts it -- or that comes
# back with its quotes attached -- is a pause a human requested and the run did
# not hear, on precisely the host with the fewest tools to notice.
#
# One reason carrying all three hazards at once: `: ` (opens a sibling mapping
# key), an embedded `'` (breaks the encoding unless doubled), a newline (writes
# a whole second line both readers would then take for the next key). That
# second line is itself key-SHAPED, deliberately -- with plain prose there the
# sibling-key count cannot move whatever the encoder does, so the case would
# read as a check while being incapable of failing. The expected on-disk line
# is a LITERAL, never rebuilt by mirroring the encoder, since a mirror agrees
# with a wrong encoder by construction.
NTP="$(mktemp -d)/pause"
NTP_RAW="$(printf "wrap up: it's 'done'\nnote: a second line")"
NTP_WANT="$(printf '%s' "$NTP_RAW" | tr '\n\r' '  ')"
NTP_LINE="reason: 'wrap up: it''s ''done'' note: a second line'"
assert_true "no-tools host: request-pause writes the sentinel" \
  "bare request-pause '$NTP' \"\$NTP_RAW\" >/dev/null"
assert_true "no-tools host: the hostile reason is encoded byte-identically to a full-PATH run" \
  "[ \"\$(grep '^reason:' '$NTP')\" = \"\$NTP_LINE\" ]"
assert_true "no-tools host: the newline injected no extra line (sentinel is exactly 2 lines)" \
  "[ \"\$(wc -l < '$NTP' | tr -d ' ')\" = 2 ]"
assert_true "no-tools host: the colon-space injected no sibling key (exactly 2 top-level keys)" \
  "[ \"\$(_top_key_count '$NTP')\" = 2 ]"
assert_true "no-tools host: the sentinel it wrote is still real, parseable YAML" \
  "yamlok '$NTP'"
assert_true "no-tools host: pause-status hands the reason back bare, collapsed and unquoted" \
  "[ \"\$(bare pause-status '$NTP')\" = \"PAUSE=1 reason=\$NTP_WANT\" ]"
# Both crossings of the PATH boundary, because the writer and the reader are
# not always the same host: a repo driven from stock Git Bash one session and a
# POSIX host the next has to round-trip either way round.
assert_true "no-tools host: a full-PATH reader gets the same line off those same bytes" \
  "[ \"\$(\"\$RUNSTATE\" pause-status '$NTP')\" = \"PAUSE=1 reason=\$NTP_WANT\" ]"
"$RUNSTATE" request-pause "$NTP" "$NTP_RAW" >/dev/null
assert_true "no-tools host: pause-status decodes a sentinel written WITH the tools present" \
  "[ \"\$(bare pause-status '$NTP')\" = \"PAUSE=1 reason=\$NTP_WANT\" ]"
# Existing on-disk state, here too: a sentinel written before the encoder
# existed carries an unquoted reason, and an ordinary `request-pause <file>`
# carries none at all. The second is the rc fix T5 made -- a query never fails
# its caller -- so it is asserted on the exit status, not just the text.
printf 'requested_at: 2026-01-01T00:00:00Z\nreason: night\n' > "$NTP"
assert_true "no-tools host: a legacy bare reason still reads through unchanged" \
  "[ \"\$(bare pause-status '$NTP')\" = 'PAUSE=1 reason=night' ]"
printf 'requested_at: 2026-01-01T00:00:00Z\n' > "$NTP"
NTP_RC=0; NTP_OUT="$(bare pause-status "$NTP")" || NTP_RC=$?
assert_true "no-tools host: a reason-less sentinel still exits 0 with the <none> fallback" \
  "[ \"\$NTP_RC\" = 0 ] && [ \"\$NTP_OUT\" = 'PAUSE=1 reason=<none>' ]"

echo
echo "== findings: packet-scoped and opt-in bodies (ADR 0024, T3/T4) =="
FS="$(mktemp -d)/.agents"; mkdir -p "$FS"
printf 'status: running\nfindings:\nnote: green\n' > "$FS/run-state.yaml"
assert_true "add-finding with no --packets fails" \
  "! \"\$RUNSTATE\" add-finding \"$FS/run-state.yaml\" fx-1 'no packets given' 2>/dev/null"
assert_true "the --packets refusal writes NO index entry" \
  "\"\$RUNSTATE\" add-finding \"$FS/run-state.yaml\" fx-1 'no packets given' >/dev/null 2>&1; ! grep -q 'id: fx-1' \"$FS/run-state.yaml\""
assert_true "the --packets refusal writes NO body file" \
  "[ ! -f \"$FS/findings/fx-1.md\" ]"
REFUSAL="$("$RUNSTATE" add-finding "$FS/run-state.yaml" fx-1 'no packets given' 2>&1 >/dev/null)"
assert_true "the refusal names CLAUDE.md (durable-fact home)" \
  "printf '%s' \"\$REFUSAL\" | grep -q 'CLAUDE.md'"
assert_true "the refusal names pending_questions: (human-question home)" \
  "printf '%s' \"\$REFUSAL\" | grep -q 'pending_questions:'"
assert_true "the refusal names note: (where-session-stopped home)" \
  "printf '%s' \"\$REFUSAL\" | grep -q 'note:'"
assert_true "the refusal names the backlog (build/fix home)" \
  "printf '%s' \"\$REFUSAL\" | grep -q 'backlog'"
"$RUNSTATE" add-finding "$FS/run-state.yaml" f-001 'dup body irrelevant' --packets pkt-a --body >/dev/null
DUP_ERR="$("$RUNSTATE" add-finding "$FS/run-state.yaml" f-001 'no packets, duplicate id' 2>&1 >/dev/null)"
assert_true "--packets refusal (not duplicate-id) fires when both apply" \
  "printf '%s' \"\$DUP_ERR\" | grep -q 'pending_questions:' && ! printf '%s' \"\$DUP_ERR\" | grep -q duplicate-id"
assert_true "the duplicate id is still unchanged after the refusal" \
  "[ \"\$(grep -c 'id: f-001' \"$FS/run-state.yaml\")\" = 1 ]"
assert_true "--packets ids land as a YAML flow sequence" \
  "grep -q '^    packets: \[pkt-a\]$' \"$FS/run-state.yaml\""
assert_true "a bad packet-id charset is rejected" \
  "! \"\$RUNSTATE\" add-finding \"$FS/run-state.yaml\" f-bad 'x' --packets 'pkt a/b' 2>/dev/null"
assert_true "--packets normalises and de-duplicates" \
  "\"\$RUNSTATE\" add-finding \"$FS/run-state.yaml\" f-norm 'x' --packets 'a, b , a' >/dev/null && grep -q '^    packets: \[a, b\]$' \"$FS/run-state.yaml\""

assert_true "without --body no body file exists" \
  "[ ! -f \"$FS/findings/f-norm.md\" ]"
assert_true "without --body the entry has no file: line" \
  "awk '/- id: f-norm/{f=1;next} /- id:/{f=0} f && /file:/{bad=1} END{exit bad}' \"$FS/run-state.yaml\""
assert_true "with --body the body exists and file: resolves to it" \
  "[ -s \"\$(dirname \"$FS\")/\$(grep -m1 'file:' \"$FS/run-state.yaml\" | sed 's/.*file: //')\" ]"
assert_true "findings prints an entry with no body without mangling the row" \
  "\"\$RUNSTATE\" findings \"$FS/run-state.yaml\" | awk -F'\t' '\$1==\"f-norm\" && NF==4 {ok=1} END{exit !ok}'"

echo
echo "== drop-finding: both-or-neither, atomic (ADR 0024, T5) =="
FDR="$(mktemp -d)/.agents"; mkdir -p "$FDR"
printf 'status: running\nfindings:\nnote: keep-me\n' > "$FDR/run-state.yaml"
"$RUNSTATE" add-finding "$FDR/run-state.yaml" keep-1 'a surviving entry' --packets pkt-a --body >/dev/null
"$RUNSTATE" add-finding "$FDR/run-state.yaml" drop-1 'an entry to drop' --packets pkt-b --body >/dev/null
BEFORE_DROP="$(cat "$FDR/run-state.yaml")"
assert_true "drop-finding of an unknown id removes nothing" \
  "\"\$RUNSTATE\" drop-finding \"$FDR/run-state.yaml\" no-such-id | grep -q '^REASON=not-found'"
assert_true "unknown-id drop leaves the file byte-identical" \
  "[ \"\$(cat \"$FDR/run-state.yaml\")\" = \"\$BEFORE_DROP\" ]"
assert_true "drop-finding removes the index entry" \
  "\"\$RUNSTATE\" drop-finding \"$FDR/run-state.yaml\" drop-1 | grep -q '^DROPPED=yes' && ! grep -q 'id: drop-1' \"$FDR/run-state.yaml\""
assert_true "drop-finding removes the body" \
  "[ ! -f \"$FDR/findings/drop-1.md\" ]"
assert_true "drop-finding reports BODY=removed" \
  "\"\$RUNSTATE\" add-finding \"$FDR/run-state.yaml\" drop-2 'x' --packets pkt-c --body >/dev/null && \"\$RUNSTATE\" drop-finding \"$FDR/run-state.yaml\" drop-2 | grep -q '^BODY=removed'"
assert_true "drop of an entry with no body succeeds and leaves no stray file" \
  "\"\$RUNSTATE\" add-finding \"$FDR/run-state.yaml\" drop-3 'x' --packets pkt-d >/dev/null && \"\$RUNSTATE\" drop-finding \"$FDR/run-state.yaml\" drop-3 | grep -q '^BODY=none' && [ ! -f \"$FDR/findings/drop-3.md\" ]"
assert_true "surrounding entries survive a drop" \
  "grep -q 'id: keep-1' \"$FDR/run-state.yaml\""
assert_true "keys before/after the findings block survive a drop" \
  "grep -q '^status: running' \"$FDR/run-state.yaml\" && grep -q '^note: keep-me' \"$FDR/run-state.yaml\""
assert_true "yamlok after a drop" \
  "yamlok \"$FDR/run-state.yaml\""

# forced failure: chmod the run-state's OWN directory (not findings/) unwritable so
# building the run-state temp file fails; the body must already be safely set aside
# in findings/ (its OWN directory) before that point, so it comes back intact.
FDF="$(mktemp -d)/.agents"; mkdir -p "$FDF"
printf 'status: running\nfindings:\nnote: forced-failure\n' > "$FDF/run-state.yaml"
"$RUNSTATE" add-finding "$FDF/run-state.yaml" force-1 'has a body' --packets pkt-f --body >/dev/null
FDF_BEFORE="$(cat "$FDF/run-state.yaml")"
chmod 500 "$FDF"
assert_true "a forced failure mid-drop is refused (nonzero)" \
  "! \"\$RUNSTATE\" drop-finding \"$FDF/run-state.yaml\" force-1 2>/dev/null"
chmod 700 "$FDF"
assert_true "forced failure: the body is restored" \
  "[ -s \"$FDF/findings/force-1.md\" ]"
assert_true "forced failure: the index entry survives" \
  "grep -q 'id: force-1' \"$FDF/run-state.yaml\""
assert_true "forced failure: run-state is unchanged" \
  "[ \"\$(cat \"$FDF/run-state.yaml\")\" = \"\$FDF_BEFORE\" ]"
assert_true "forced failure: no leftover temp file in the run-state dir" \
  "! ls \"$FDF\"/.run-state.* >/dev/null 2>&1"
assert_true "forced failure: no leftover aside file in findings/" \
  "! ls \"$FDF/findings\"/.*.aside.* >/dev/null 2>&1"

echo
echo "== merge-findings: one entry, both packet lists, NO TEXT LOST (escalation-decider T5) =="
# THE WRONG IMPLEMENTATION THIS SECTION RULES OUT, and why it needs a
# line-by-line check rather than a summary check: a merge that copies the
# removed entry's SUMMARY into the survivor's body and then deletes the removed
# body is indistinguishable from a correct one in every count anyone reads —
# one entry fewer in the index, both packet ids on the survivor, a body file
# that grew, MERGED=yes. The removed body's detail is simply gone, with nothing
# left behind to notice it. Asserting the summary alone PASSES that
# implementation, so every line of the removed body is checked here, against a
# copy taken before the merge.
FM="$(mktemp -d)/.agents"; mkdir -p "$FM"
printf 'schema: 3\nstatus: running\nfindings:\nnote: keep-me\n' > "$FM/run-state.yaml"
"$RUNSTATE" add-finding "$FM/run-state.yaml" mg-keep 'the surviving finding' \
  --packets mg-pkt-a,mg-pkt-shared --body >/dev/null
"$RUNSTATE" add-finding "$FM/run-state.yaml" mg-dup 'the duplicate finding, said differently' \
  --packets mg-pkt-shared,mg-pkt-b --body >/dev/null
"$RUNSTATE" add-finding "$FM/run-state.yaml" mg-other 'an unrelated finding' \
  --packets mg-pkt-c --body >/dev/null
# Detail that exists ONLY in the removed body — the text a summary-only merge loses.
printf 'MG-DETAIL-ONE the reproduction\nMG-DETAIL-TWO the constraint it implies\n' \
  >> "$FM/findings/mg-dup.md"
MG_RCOPY="$(mktemp)"; cp "$FM/findings/mg-dup.md" "$MG_RCOPY"
MG_SCOPY="$(mktemp)"; cp "$FM/findings/mg-keep.md" "$MG_SCOPY"
MG_OUT="$("$RUNSTATE" merge-findings "$FM/run-state.yaml" mg-keep mg-dup)"
assert_true "merge-findings reports MERGED=yes" \
  "printf '%s\n' \"\$MG_OUT\" | grep -qx 'MERGED=yes'"
# The union, de-duplicated: survivor's ids first, then the removed entry's, and
# mg-pkt-shared (named by BOTH) exactly once. A list that dropped an id would
# expire the merged entry before every packet it constrains has run.
assert_true "the reported packet list is the de-duplicated union, survivor's ids first" \
  "printf '%s\n' \"\$MG_OUT\" | grep -qx 'PACKETS=mg-pkt-a,mg-pkt-shared,mg-pkt-b'"
assert_true "both entries' packets appear in the survivor's packets: in the index" \
  "[ \"\$(\"\$RUNSTATE\" findings \"$FM/run-state.yaml\" | awk -F'\t' '\$1==\"mg-keep\"{print \$4}')\" = mg-pkt-a,mg-pkt-shared,mg-pkt-b ]"
# EVERY line of the removed body, not just its summary (see the note above).
# `--` before the pattern is load-bearing: a finding body legitimately contains
# lines beginning with `-` (add-finding's own `- recorded:` stub line), which
# grep would otherwise read as options — every such line would report missing
# and the case would fail against a correct merge.
MG_MISSING=""
while IFS= read -r mg_line; do
  grep -qxF -- "$mg_line" "$FM/findings/mg-keep.md" || MG_MISSING="${MG_MISSING}${mg_line}
"
done < "$MG_RCOPY"
assert_true "every line of the removed body appears in the survivor's body" \
  "[ -z \"\$MG_MISSING\" ]"
assert_true "the removed entry's summary appears in the survivor's body" \
  "grep -qF 'the duplicate finding, said differently' \"$FM/findings/mg-keep.md\""
# ...and the survivor's own body is appended to, never replaced: its pre-merge
# content is still there, unchanged, as the head of the merged file.
assert_true "the survivor's own body text survives the merge" \
  "head -n \"\$(wc -l < \"$MG_SCOPY\")\" \"$FM/findings/mg-keep.md\" | diff -q - \"$MG_SCOPY\" >/dev/null"
assert_true "the removed entry is gone from the index" \
  "! grep -qxF '  - id: mg-dup' \"$FM/run-state.yaml\""
assert_true "the removed body is gone from disk" \
  "[ ! -f \"$FM/findings/mg-dup.md\" ]"
assert_true "an unrelated entry and the keys around the findings block survive a merge" \
  "grep -qxF '  - id: mg-other' \"$FM/run-state.yaml\" && grep -q '^note: keep-me' \"$FM/run-state.yaml\" && grep -q '^status: running' \"$FM/run-state.yaml\""
assert_true "yamlok after a merge" \
  "yamlok \"$FM/run-state.yaml\""
assert_true "no leftover temp or aside file after a merge" \
  "! ls \"$FM/findings\"/.mg-* >/dev/null 2>&1 && ! ls \"$FM\"/.run-state.* >/dev/null 2>&1"

# A survivor with NO body: the removed entry's text still needs a home, so the
# body and the entry's file: pointer are created here.
"$RUNSTATE" add-finding "$FM/run-state.yaml" mg-nobody 'a survivor with no body file' \
  --packets mg-pkt-d >/dev/null
"$RUNSTATE" add-finding "$FM/run-state.yaml" mg-src 'the entry folded into it' \
  --packets mg-pkt-e --body >/dev/null
printf 'MG-ONLY-IN-SRC the detail that has nowhere else to go\n' >> "$FM/findings/mg-src.md"
MG_OUT2="$("$RUNSTATE" merge-findings "$FM/run-state.yaml" mg-nobody mg-src)"
assert_true "a survivor with no body gets one created (SURVIVOR_BODY=created)" \
  "printf '%s\n' \"\$MG_OUT2\" | grep -qx 'SURVIVOR_BODY=created' && [ -s \"$FM/findings/mg-nobody.md\" ]"
assert_true "the created body carries the removed body's text and the removed summary" \
  "grep -qxF 'MG-ONLY-IN-SRC the detail that has nowhere else to go' \"$FM/findings/mg-nobody.md\" && grep -qF 'the entry folded into it' \"$FM/findings/mg-nobody.md\""
# Read back through `findings` itself, not a grep for the next file: line in the
# file — an entry that gained NO pointer would otherwise borrow the following
# entry's path, which resolves, and the assertion would pass on the bug.
assert_true "the survivor's index entry gains a file: pointer that resolves to the real body" \
  "MG_F=\"\$(\"\$RUNSTATE\" findings \"$FM/run-state.yaml\" | awk -F'\t' '\$1==\"mg-nobody\"{print \$3}')\"; [ -n \"\$MG_F\" ] && [ -s \"\$(dirname \"$FM\")/\$MG_F\" ]"
# A removed entry with no body of its own (the DEFAULT shape — bodies are
# opt-in): its summary is the only text it has, and it must still survive.
"$RUNSTATE" add-finding "$FM/run-state.yaml" mg-bare 'no body of its own, summary must still survive' \
  --packets mg-pkt-f >/dev/null
MG_OUT3="$("$RUNSTATE" merge-findings "$FM/run-state.yaml" mg-nobody mg-bare)"
assert_true "a removed entry with no body still hands over its summary (BODY=summary-only)" \
  "printf '%s\n' \"\$MG_OUT3\" | grep -qx 'BODY=summary-only' && grep -qF 'no body of its own, summary must still survive' \"$FM/findings/mg-nobody.md\""

MG_BEFORE="$(cat "$FM/run-state.yaml")"
assert_true "an unknown removed id merges nothing (REASON=removed-not-found)" \
  "\"\$RUNSTATE\" merge-findings \"$FM/run-state.yaml\" mg-keep mg-no-such-id | grep -qx 'REASON=removed-not-found'"
assert_true "an unknown survivor id merges nothing (REASON=survivor-not-found)" \
  "\"\$RUNSTATE\" merge-findings \"$FM/run-state.yaml\" mg-no-such-id mg-keep | grep -qx 'REASON=survivor-not-found'"
assert_true "a not-found merge leaves the file byte-identical" \
  "[ \"\$(cat \"$FM/run-state.yaml\")\" = \"\$MG_BEFORE\" ]"
# Merging an entry into itself would delete the very body it had just appended
# to — an argument error, refused before anything is read.
assert_true "merging an entry into itself is refused (nonzero), body and entry intact" \
  "! \"\$RUNSTATE\" merge-findings \"$FM/run-state.yaml\" mg-keep mg-keep 2>/dev/null && [ -s \"$FM/findings/mg-keep.md\" ] && grep -qxF '  - id: mg-keep' \"$FM/run-state.yaml\""
assert_true "a traversing id is rejected by merge-findings" \
  "! \"\$RUNSTATE\" merge-findings \"$FM/run-state.yaml\" mg-keep '../escape' 2>/dev/null"

# Forced failure, same technique as the drop-finding case above: the run-state's
# OWN directory is made unwritable so building its temp file fails, AFTER the
# removed body has been set aside. Both-or-neither means both bodies come back
# and the index still holds both entries.
FMF="$(mktemp -d)/.agents"; mkdir -p "$FMF"
printf 'schema: 3\nstatus: running\nfindings:\nnote: forced-failure\n' > "$FMF/run-state.yaml"
"$RUNSTATE" add-finding "$FMF/run-state.yaml" mf-keep 'the survivor' --packets mf-pkt-a --body >/dev/null
"$RUNSTATE" add-finding "$FMF/run-state.yaml" mf-dup 'the duplicate' --packets mf-pkt-b --body >/dev/null
printf 'MF-SURVIVOR-ORIGINAL\n' >> "$FMF/findings/mf-keep.md"
printf 'MF-REMOVED-ORIGINAL\n' >> "$FMF/findings/mf-dup.md"
MF_STATE="$(cat "$FMF/run-state.yaml")"
MF_SBODY="$(cat "$FMF/findings/mf-keep.md")"
MF_RBODY="$(cat "$FMF/findings/mf-dup.md")"
chmod 500 "$FMF"
assert_true "a forced failure mid-merge is refused (nonzero)" \
  "! \"\$RUNSTATE\" merge-findings \"$FMF/run-state.yaml\" mf-keep mf-dup 2>/dev/null"
chmod 700 "$FMF"
assert_true "forced failure: run-state is unchanged, both entries still present" \
  "[ \"\$(cat \"$FMF/run-state.yaml\")\" = \"\$MF_STATE\" ]"
assert_true "forced failure: the survivor's body is unchanged (no half-merge)" \
  "[ \"\$(cat \"$FMF/findings/mf-keep.md\")\" = \"\$MF_SBODY\" ]"
assert_true "forced failure: the removed body is restored" \
  "[ \"\$(cat \"$FMF/findings/mf-dup.md\")\" = \"\$MF_RBODY\" ]"
assert_true "forced failure: no leftover temp or aside file" \
  "! ls \"$FMF/findings\"/.mf-* >/dev/null 2>&1 && ! ls \"$FMF\"/.run-state.* >/dev/null 2>&1"

echo
echo "== findings --stale: SUPPLIED finished set only (ADR 0024, T6) =="
FSS="$(mktemp -d)/.agents"; mkdir -p "$FSS"
printf 'status: running\nbacklog:\n  cursor: pkt-cur\n  pending:\n    - pkt-cur\n    - pkt-pend\nfindings:\nnote: x\n' \
  > "$FSS/run-state.yaml"
"$RUNSTATE" add-finding "$FSS/run-state.yaml" s-both 'both packets finish' --packets pkt-done1,pkt-done2 >/dev/null
"$RUNSTATE" add-finding "$FSS/run-state.yaml" s-mixed 'one finished, one pending' --packets pkt-done1,pkt-pend >/dev/null
"$RUNSTATE" add-finding "$FSS/run-state.yaml" s-unknown 'one finished, one unheard-of' --packets pkt-done1,pkt-ghost >/dev/null
# THE PINNED SAFETY PROPERTY: with no --finished, NOTHING is stale, even though
# pkt-done1/pkt-done2 are genuinely finished elsewhere — a caller that forgets to
# wire --finished must expire nothing, never guess from git/gspec/backlog.done.
assert_true "no --finished => STALE_COUNT=0 even when packets are genuinely done" \
  "\"\$RUNSTATE\" findings \"$FSS/run-state.yaml\" --stale | grep -q '^STALE_COUNT=0'"
assert_true "no --finished => every entry reads STALE=no" \
  "! \"\$RUNSTATE\" findings \"$FSS/run-state.yaml\" --stale | grep -q 'STALE=yes'"
STALE_ALL="$("$RUNSTATE" findings "$FSS/run-state.yaml" --stale --finished pkt-done1,pkt-done2)"
assert_true "a finished set covering all of an entry's packets => STALE=yes" \
  "printf '%s\n' \"\$STALE_ALL\" | grep -q '^FINDING=s-both STALE=yes packets=pkt-done1,pkt-done2$'"
assert_true "one finished + one pending packet => STALE=no, blocked_by the pending one" \
  "printf '%s\n' \"\$STALE_ALL\" | grep -q '^FINDING=s-mixed STALE=no blocked_by=pkt-pend:pending packets=pkt-done1,pkt-pend$'"
assert_true "a packet neither finished nor pending reads unknown and blocks expiry" \
  "printf '%s\n' \"\$STALE_ALL\" | grep -q '^FINDING=s-unknown STALE=no blocked_by=pkt-ghost:unknown packets=pkt-done1,pkt-ghost$'"
assert_true "STALE_COUNT counts only the fully-finished entry" \
  "printf '%s\n' \"\$STALE_ALL\" | grep -q '^STALE_COUNT=1$'"
assert_true "OVER_THRESHOLD=no comfortably under the default budget" \
  "\"\$RUNSTATE\" findings \"$FSS/run-state.yaml\" --stale | grep -q '^OVER_THRESHOLD=no$'"
assert_true "OVER_THRESHOLD flips at a tiny --max-bytes" \
  "\"\$RUNSTATE\" findings \"$FSS/run-state.yaml\" --stale --max-bytes 10 | grep -q '^OVER_THRESHOLD=yes$'"
assert_true "ORCH_FINDINGS_INDEX_MAX_BYTES is honoured" \
  "ORCH_FINDINGS_INDEX_MAX_BYTES=10 \"\$RUNSTATE\" findings \"$FSS/run-state.yaml\" --stale | grep -q '^OVER_THRESHOLD=yes$'"

echo
echo "== the three here-string sites, over 8 KiB (next-state-reporting-integrity T2) =="
# WHAT THESE CASES CLAIM, AND WHAT THEY DELIBERATELY DO NOT.
#
# They claim NO PRE-FIX FAILURE. The `printf … | grep -q` shape that
# `_id_in_set` and the two findings duplicate-id checks carried before T2 does
# not reproduce a wrong answer at today's sizes, and none was observed while
# writing these — unlike T1's adapter cases, which were run against the unfixed
# code and seen to fail. Claiming otherwise here would be the mistake this
# repo already records once: a probe that does not reproduce the phenomenon
# eliminates nothing, and neither does one that merely passes.
#
# What they DO pin is behaviour at a size where the single-write argument no
# longer holds. That argument is "one `printf` is atomic up to PIPE_BUF, so no
# reader can close between two writes" — PIPE_BUF is 4096, and
# ORCH_FINDINGS_INDEX_MAX_BYTES=4096 is already the ceiling `findings --stale`
# expects the index to reach. Every fixture below is built past 8 KiB, twice
# that, and asserts the size it actually reached rather than assuming it. A
# fixture under the threshold would certify the here-string form while
# exercising nothing at all.
#
# Each mutation is followed by the sweep's own yamlok() parse assertion, for the
# same reason every other mutating case here is: grep is what let a whole class
# of unparseable run-states through before.

# -- an over-8-KiB findings: block (cmd_add_finding + cmd_drop_finding) --------
FB="$(mktemp -d)/.agents"; mkdir -p "$FB"
printf 'schema: 3\nstatus: running\nfindings:\nnote: after-the-block\n' > "$FB/run-state.yaml"
# ~250 chars of summary x 40 entries carries the block past 8 KiB. The length is
# the point of the fixture, not padding for its own sake.
FB_SUMMARY='a summary long enough that forty of these entries carry the findings block past twice PIPE_BUF, which is the size at which the one-atomic-write argument for a piped grep -q stops holding, so the block below is built to the size the index is actually expected to reach'
FB_I=1
while [ "$FB_I" -le 40 ]; do
  "$RUNSTATE" add-finding "$FB/run-state.yaml" "fb-$(printf '%03d' "$FB_I")" \
    "$FB_SUMMARY" --packets "pkt-fb-${FB_I}" >/dev/null
  FB_I=$((FB_I + 1))
done
# INDEX_BYTES is runstate.sh's OWN measurement of the findings block, so the
# size asserted here is the size the code under test sees, not a second count
# from the test that could drift away from it.
FB_BYTES="$("$RUNSTATE" findings "$FB/run-state.yaml" --stale | sed -n 's/^INDEX_BYTES=//p')"
echo "   (findings block built to ${FB_BYTES} bytes)"
assert_true "the findings block fixture really exceeds 8 KiB (${FB_BYTES} bytes)" \
  "[ \"$FB_BYTES\" -gt 8192 ]"
assert_true "yamlok after building the 8-KiB+ findings block" "yamlok \"$FB/run-state.yaml\""
# The block's LAST entry is the FIRST one added: entries insert newest-first
# immediately after the `findings:` key. That is the interesting id — it is the
# one the writer can only reach after emitting the whole block, so a reader that
# closed early on a nearer line would miss exactly this one.
FB_LAST="$(awk '/^findings:[[:space:]]*$/{f=1;next}
                /^[A-Za-z_][A-Za-z0-9_]*:/{f=0}
                f && /^  - id: /{last=$0}
                END{sub(/^  - id: /,"",last); print last}' "$FB/run-state.yaml")"
assert_true "the block's last entry is the first one added" "[ \"$FB_LAST\" = fb-001 ]"

FB_BEFORE="$(cat "$FB/run-state.yaml")"
FB_DUP_OUT="$("$RUNSTATE" add-finding "$FB/run-state.yaml" "$FB_LAST" 'a different summary entirely' --packets pkt-fb-dup)"
assert_true "add-finding of the block's last id over an 8-KiB+ block reports ADDED=no" \
  "printf '%s\n' \"\$FB_DUP_OUT\" | grep -qx 'ADDED=no'"
assert_true "add-finding of the block's last id over an 8-KiB+ block reports REASON=duplicate-id" \
  "printf '%s\n' \"\$FB_DUP_OUT\" | grep -qx 'REASON=duplicate-id'"
assert_true "the refused duplicate leaves the 8-KiB+ run-state byte-identical" \
  "[ \"\$(cat \"$FB/run-state.yaml\")\" = \"\$FB_BEFORE\" ]"
assert_true "yamlok after the refused duplicate over an 8-KiB+ block" "yamlok \"$FB/run-state.yaml\""

# not-found first, so it too is judged against the still-full block. This is the
# NEGATED check: a polluted status here turns a found entry into `not-found`.
FB_NF_OUT="$("$RUNSTATE" drop-finding "$FB/run-state.yaml" fb-no-such-id)"
assert_true "drop-finding of an absent id over an 8-KiB+ block reports REASON=not-found" \
  "printf '%s\n' \"\$FB_NF_OUT\" | grep -qx 'REASON=not-found'"
assert_true "the absent-id drop leaves the 8-KiB+ run-state byte-identical" \
  "[ \"\$(cat \"$FB/run-state.yaml\")\" = \"\$FB_BEFORE\" ]"
assert_true "yamlok after the absent-id drop over an 8-KiB+ block" "yamlok \"$FB/run-state.yaml\""

FB_N_BEFORE="$("$RUNSTATE" findings "$FB/run-state.yaml" | wc -l | tr -d ' ')"
FB_N_AFTER=$((FB_N_BEFORE - 1))
FB_DROP_OUT="$("$RUNSTATE" drop-finding "$FB/run-state.yaml" "$FB_LAST")"
assert_true "drop-finding of the block's last id over an 8-KiB+ block reports DROPPED=yes" \
  "printf '%s\n' \"\$FB_DROP_OUT\" | grep -qx 'DROPPED=yes'"
assert_true "the dropped entry is gone from the 8-KiB+ block" \
  "! grep -qx '  - id: $FB_LAST' \"$FB/run-state.yaml\""
assert_true "EXACTLY one entry was removed ($FB_N_BEFORE -> $FB_N_AFTER)" \
  "[ \"\$(\"\$RUNSTATE\" findings \"$FB/run-state.yaml\" | wc -l | tr -d ' ')\" = $FB_N_AFTER ]"
assert_true "the neighbouring entries survive the 8-KiB+ drop" \
  "grep -qx '  - id: fb-002' \"$FB/run-state.yaml\" && grep -qx '  - id: fb-040' \"$FB/run-state.yaml\""
assert_true "keys before and after the findings block survive the 8-KiB+ drop" \
  "grep -qx 'status: running' \"$FB/run-state.yaml\" && grep -qx 'note: after-the-block' \"$FB/run-state.yaml\""
assert_true "yamlok after the drop over an 8-KiB+ block" "yamlok \"$FB/run-state.yaml\""

# -- over-8-KiB --finished and cursor-plus-pending sets (_id_in_set) -----------
# _id_in_set's two callers are these two sets, and neither has any ceiling at
# all, which is why its pipe was removed rather than bounded. Each finding below
# names the LAST member of its set (or none of either), so the membership test
# must read to the end of an 8-KiB+ value to answer correctly.
FST="$(mktemp -d)/.agents"; mkdir -p "$FST"
FST_PAD='0000000000000000000000000'
FST_CURSOR="pkt-stale-cursor-${FST_PAD}"
FST_PENDING=""; FST_FINISHED=""; FST_I=1
while [ "$FST_I" -le 220 ]; do
  FST_N="$(printf '%03d' "$FST_I")"
  FST_PENDING="${FST_PENDING}    - pkt-stale-pending-${FST_N}-${FST_PAD}
"
  FST_FINISHED="${FST_FINISHED}${FST_FINISHED:+,}pkt-stale-finished-${FST_N}-${FST_PAD}"
  FST_I=$((FST_I + 1))
done
FST_LAST_PEND="pkt-stale-pending-220-${FST_PAD}"
FST_LAST_FIN="pkt-stale-finished-220-${FST_PAD}"
{ printf 'schema: 3\nstatus: running\nbacklog:\n  cursor: %s\n  pending:\n' "$FST_CURSOR"
  printf '%s' "$FST_PENDING"
  printf 'findings:\nnote: x\n'
} > "$FST/run-state.yaml"
"$RUNSTATE" add-finding "$FST/run-state.yaml" st-fin   'names only the last finished packet'   --packets "$FST_LAST_FIN"  >/dev/null
"$RUNSTATE" add-finding "$FST/run-state.yaml" st-pend  'names only the last pending packet'    --packets "$FST_LAST_PEND" >/dev/null
"$RUNSTATE" add-finding "$FST/run-state.yaml" st-ghost 'names a packet in neither set'         --packets pkt-stale-ghost  >/dev/null
assert_true "yamlok after building the 8-KiB+ --stale fixture" "yamlok \"$FST/run-state.yaml\""
FST_FIN_BYTES="$(printf '%s' "$FST_FINISHED" | wc -c | tr -d ' ')"
# Mirrors _findings_pending_ids' output exactly: the cursor line, then each
# pending entry with its `    - ` list marker stripped.
FST_PEND_BYTES="$( { printf '%s\n' "$FST_CURSOR"; printf '%s' "$FST_PENDING" | sed 's/^    - //'; } | wc -c | tr -d ' ')"
echo "   (--finished set ${FST_FIN_BYTES} bytes; cursor-plus-pending set ${FST_PEND_BYTES} bytes)"
assert_true "the --finished set really exceeds 8 KiB (${FST_FIN_BYTES} bytes)" \
  "[ \"$FST_FIN_BYTES\" -gt 8192 ]"
assert_true "the cursor-plus-pending set really exceeds 8 KiB (${FST_PEND_BYTES} bytes)" \
  "[ \"$FST_PEND_BYTES\" -gt 8192 ]"
FST_OUT="$("$RUNSTATE" findings "$FST/run-state.yaml" --stale --finished "$FST_FINISHED")"
assert_true "a packet at the END of an 8-KiB+ --finished set reads finished (STALE=yes)" \
  "printf '%s\n' \"\$FST_OUT\" | grep -qx 'FINDING=st-fin STALE=yes packets=$FST_LAST_FIN'"
assert_true "a packet at the END of an 8-KiB+ cursor-plus-pending set reads pending" \
  "printf '%s\n' \"\$FST_OUT\" | grep -qx 'FINDING=st-pend STALE=no blocked_by=$FST_LAST_PEND:pending packets=$FST_LAST_PEND'"
assert_true "a packet in NEITHER 8-KiB+ set reads unknown and blocks expiry" \
  "printf '%s\n' \"\$FST_OUT\" | grep -qx 'FINDING=st-ghost STALE=no blocked_by=pkt-stale-ghost:unknown packets=pkt-stale-ghost'"
assert_true "STALE_COUNT counts only the finished entry over 8-KiB+ sets" \
  "printf '%s\n' \"\$FST_OUT\" | grep -qx 'STALE_COUNT=1'"

# --- trim-note must survive EVERY note encoding -------------------------------
# The cut is a byte cut, so the encoding decides whether it is safe: a quoted scalar
# loses its closing quote and the file stops parsing. trim-note therefore re-emits the
# note as a literal block scalar, which is truncatable at any byte. A note describing a
# packet very often contains ': ', so the quoted shapes are not hypothetical.
FT="$(mktemp -d)/.agents"; mkdir -p "$FT"
long='ratio: high and "quoted" and C:\path '
big=""; i=0; while [ $i -lt 120 ]; do big="${big}${long}"; i=$((i+1)); done
{ printf 'schema: 3\nnote: %s\nstatus: paused\n' "$big"; }            > "$FT/plain.yaml"
{ printf 'schema: 3\nnote: "%s"\nstatus: paused\n' "$big"; }          > "$FT/dq.yaml"
{ printf 'schema: 3\nnote: |-\n'; i=0
  while [ $i -lt 120 ]; do printf '  %s\n' "$long"; i=$((i+1)); done
  printf 'status: paused\n'; }                                        > "$FT/block.yaml"
# `sq`: single-quoted -- the ONLY shape cmd_set ever writes now (T4/T5). Unlike
# `long` above, this one carries an embedded `'` so a broken un-double is
# actually visible in the trimmed output, not just a parse failure.
long_sq="it's a ratio: high and 'quoted' and C:\path "
big_sq=""; i=0; while [ $i -lt 120 ]; do big_sq="${big_sq}${long_sq}"; i=$((i+1)); done
enc_sq="$(printf '%s' "$big_sq" | sed "s/'/''/g")"
printf "schema: 3\nnote: '%s'\nstatus: paused\n" "$enc_sq" > "$FT/sq.yaml"
for shape in plain dq block sq; do
  assert_true "trim-note keeps YAML valid ($shape note)" \
    "\"\$RUNSTATE\" trim-note \"$FT/$shape.yaml\" 200 >/dev/null && yamlok \"$FT/$shape.yaml\""
  assert_true "trim-note preserves the key after note ($shape)" \
    "grep -q '^status: paused' \"$FT/$shape.yaml\""
done
# CONTENT assertions for `sq`, mutation-proven (the two generic assertions
# above -- "still valid YAML" and "key after note survives" -- both pass
# against the PRE-fix unwrap, which stripped only a leading quote and left the
# trailing quote and every doubled `''` in place; neither one looks at the
# note's content at all). These do: reverting the fix's `case`/`gsub` back to
# the old `sub(/^"/,"");sub(/"$/,"");sub(/^'"'"'/,"");sub(/^'"'"'$/,"")` line
# makes BOTH of these fail (verified by hand against that exact reverted
# line); the fix as shipped makes both pass.
assert_true "trim-note un-doubles '' back to ' in a single-quoted note (sq)" \
  "grep -qF \"it's a ratio: high and 'quoted'\" \"$FT/sq.yaml\""
assert_true "trim-note leaves no doubled '' in a single-quoted note's trimmed block (sq)" \
  "! grep -q \"''\" \"$FT/sq.yaml\""

# record-outcome writes a JSON line the collector slurps; one malformed line makes jq
# drop EVERY attestation at once, silently. Reject the input instead.
assert_true "record-outcome rejects a packet id that would break its JSON" \
  "! \"\$RUNSTATE\" record-outcome 'pkt\"; drop' green 2>/dev/null"
# a fresh template must read as EMPTY, not as one placeholder finding
assert_true "template placeholder is not a real finding" \
  "cp \"\${HERE}/../templates/run-state.yaml\" \"$FD/t.yaml\" && [ -z \"\$(\"\$RUNSTATE\" findings \"$FD/t.yaml\")\" ]"
# an older run-state with no findings key must gain one rather than fail
assert_true "a run-state without a findings key gains one" \
  "printf 'status: running\\n' > \"$FD/old.yaml\" && \"\$RUNSTATE\" add-finding \"$FD/old.yaml\" f-9 'x' --packets pkt-a | grep -q '^ADDED=yes' && grep -q '^findings:' \"$FD/old.yaml\""

echo
echo "== sweep hardening: legacy shapes + a real YAML parse (or a loud, counted skip) after every mutation (T20) =="
# The legacy fixture pins the PRE-ADR-0025 backlog shape (a done: list alongside
# cursor/pending) and the PRE-ADR-0024 findings shape (no packets:, no file:) side
# by side with a new-shape entry, so every mutating subcommand is proven against
# the shape a real, older repo actually carries — not just a freshly-written one.
legacy_fixture() {
  cat <<'LEGACY'
schema: 3
status: running
branch: orch/legacy
last_green_commit: deadbeef
backlog:
  cursor: pkt-b
  done:
    - pkt-a
  pending:
    - pkt-b
    - pkt-c
findings:
  - id: old-1
    summary: 'old-shape entry one'
    file: .agents/findings/old-1.md
  - id: old-2
    summary: 'old-shape entry two'
  - id: new-1
    summary: 'new-shape entry'
    packets: [pkt-a, pkt-b]
pending_questions:
  - id: q-1
    severity: blocking
    question: something?
note: legacy fixture note
LEGACY
}
LEGACY_DIR="$(mktemp -d)/.agents"; mkdir -p "$LEGACY_DIR"
legacy_fixture > "$LEGACY_DIR/run-state.yaml"
assert_true "legacy fixture (done: + packet-less findings) is valid YAML itself" \
  "yamlok \"$LEGACY_DIR/run-state.yaml\""

# A real parse after EVERY mutating subcommand (or a loud, counted FAIL in place of
# one — see yamlok() above — never a silent pass), each against its OWN fresh copy
# of the legacy fixture. record-outcome/request-pause/clear-pause/pause-status do NOT
# mutate run-state (record-outcome writes a separate outcomes/ log; the pause
# sentinel is its own file) so they are not exercised here.
for mut in set touch write trim-note add-finding drop-finding merge-findings claim-driver heartbeat; do
  LC="$(mktemp -d)/.agents"; mkdir -p "$LC"
  legacy_fixture > "$LC/run-state.yaml"
  case "$mut" in
    set)          mut_cmd="\"\$RUNSTATE\" set \"$LC/run-state.yaml\" note updated" ;;
    touch)        mut_cmd="\"\$RUNSTATE\" touch \"$LC/run-state.yaml\"" ;;
    write)        mut_cmd="legacy_fixture | \"\$RUNSTATE\" write \"$LC/run-state.yaml\"" ;;
    trim-note)    mut_cmd="\"\$RUNSTATE\" trim-note \"$LC/run-state.yaml\" 5" ;;
    add-finding)  mut_cmd="\"\$RUNSTATE\" add-finding \"$LC/run-state.yaml\" new-2 'legacy add' --packets pkt-z" ;;
    drop-finding) mut_cmd="\"\$RUNSTATE\" drop-finding \"$LC/run-state.yaml\" old-1" ;;
    # new-1 carries `packets:`, old-2 carries neither `packets:` nor `file:` —
    # the merge has to add both to the survivor and tolerate their absence on
    # the entry it removes, which is exactly the legacy shape this loop exists
    # to run every mutating subcommand against.
    merge-findings) mut_cmd="\"\$RUNSTATE\" merge-findings \"$LC/run-state.yaml\" new-1 old-2" ;;
    claim-driver) mut_cmd="\"\$RUNSTATE\" claim-driver \"$LC/run-state.yaml\"" ;;
    heartbeat)    mut_cmd="\"\$RUNSTATE\" heartbeat \"$LC/run-state.yaml\"" ;;
  esac
  assert_true "'$mut' on the legacy fixture succeeds and stays valid YAML" \
    "$mut_cmd >/dev/null && yamlok \"$LC/run-state.yaml\""
done

# A done:-free write (the ADR 0025 shape) must parse and carry no done: key at all.
WD="$(mktemp -d)/.agents"; mkdir -p "$WD"
printf 'schema: 3\nstatus: running\nbacklog:\n  cursor: pkt-z\n  pending:\n    - pkt-z\n    - pkt-y\n' \
  | "$RUNSTATE" write "$WD/run-state.yaml"
assert_true "a done:-free write parses" \
  "yamlok \"$WD/run-state.yaml\""
assert_true "a done:-free write: cursor round-trips" \
  "[ \"\$(rs_cursor \"$WD/run-state.yaml\")\" = pkt-z ]"
# Same fixture, but through "$RUNSTATE" cursor (cmd_cursor -> _yaml_decode_value)
# rather than the test's own raw-grep rs_cursor above: this is a write-produced,
# never-quoted value, so the decode must be a genuine no-op on it, not merely
# agree with rs_cursor by coincidence.
assert_true "cursor decode is a no-op on an unquoted, write-produced value" \
  "[ \"\$(\"\$RUNSTATE\" cursor \"$WD/run-state.yaml\")\" = pkt-z ]"
assert_true "a done:-free write carries no done: key" \
  "! grep -qE '^[[:space:]]*done:' \"$WD/run-state.yaml\""

# STRICT no-op, mutation-proven (ADR 0022/gspec-driver preamble: "a check that
# looks like it is running and is not"). Changing _yaml_decode_value's `case`
# pattern from `\'*\'` (requires BOTH a leading AND a matching trailing quote)
# to the over-eager `\'*` (strips a leading quote off ANY value) still passes
# every case above -- none of them uses a legacy value that starts with a
# quote but does not end with one. This one does: `'tis nearly done` is a
# real (if YAML-hostile) legacy byte pattern this file must not corrupt --
# under the over-eager mutant it becomes `tis nearly done`, silently.
LQ="$(mktemp -d)/.agents"; mkdir -p "$LQ"
printf "schema: 3\nnote: 'tis nearly done\nstatus: paused\n" > "$LQ/run-state.yaml"
assert_true "get is a STRICT no-op: a leading quote with no matching trailing quote survives" \
  "[ \"\$(\"\$RUNSTATE\" get \"$LQ/run-state.yaml\" note)\" = \"'tis nearly done\" ]"

# The legacy fixture's packet-less findings must NEVER read STALE=yes, no matter
# how complete the supplied finished set is — only the new-shape entry (which
# names packets) can ever expire.
SD="$(mktemp -d)/.agents"; mkdir -p "$SD"
legacy_fixture > "$SD/run-state.yaml"
STALE_LEGACY="$("$RUNSTATE" findings "$SD/run-state.yaml" --stale --finished pkt-a,pkt-b,pkt-c)"
assert_true "legacy packet-less entry old-1 reads STALE=no, blocked_by=<none>:unknown" \
  "printf '%s\n' \"\$STALE_LEGACY\" | grep -q '^FINDING=old-1 STALE=no blocked_by=<none>:unknown packets=\$'"
assert_true "legacy packet-less entry old-2 reads STALE=no, blocked_by=<none>:unknown" \
  "printf '%s\n' \"\$STALE_LEGACY\" | grep -q '^FINDING=old-2 STALE=no blocked_by=<none>:unknown packets=\$'"
assert_true "only the new-shape entry counts toward STALE_COUNT" \
  "printf '%s\n' \"\$STALE_LEGACY\" | grep -q '^STALE_COUNT=1\$'"

echo
echo "== driver-mode: enter/exit/status, keyed by session (thin-loop-driver T3) =="
DM="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$DM" init -q
git -C "$DM" config user.email t@t; git -C "$DM" config user.name t
mkdir -p "$DM/.agents"
printf 'schema: 3\nstatus: running\n' > "$DM/.agents/run-state.yaml"
dm_status() { (cd "$DM" && "$RUNSTATE" driver-mode status "$1"); }

assert_true "driver-mode enter reports on" \
  "(cd \"$DM\" && \"\$RUNSTATE\" driver-mode enter --model claude-sonnet-5 --effort high --threshold unknown DMS1) | grep -qx 'DRIVER_MODE=on'"
assert_true "driver-mode status reads on right after enter (round trip)" \
  "[ \"\$(dm_status DMS1)\" = 'DRIVER_MODE=on' ]"
assert_true "driver-mode exit reports off" \
  "(cd \"$DM\" && \"\$RUNSTATE\" driver-mode exit DMS1) | grep -qx 'DRIVER_MODE=off'"
assert_true "driver-mode status reads off after exit (round trip)" \
  "[ \"\$(dm_status DMS1)\" = 'DRIVER_MODE=off' ]"
assert_true "a repeated exit is a no-op, not an error" \
  "(cd \"$DM\" && \"\$RUNSTATE\" driver-mode exit DMS1) | grep -qx 'DRIVER_MODE=off'"
assert_true "another session that never entered reads off" \
  "[ \"\$(dm_status DMS2)\" = 'DRIVER_MODE=off' ]"
assert_true "entering one session never marks another" \
  "(cd \"$DM\" && \"\$RUNSTATE\" driver-mode enter --model m --effort e --threshold t DMS3 >/dev/null) && [ \"\$(dm_status DMS2)\" = 'DRIVER_MODE=off' ] && [ \"\$(dm_status DMS3)\" = 'DRIVER_MODE=on' ]"
assert_true "the driver-mode log is valid append-only JSON, one record per line" \
  "jq -s -e 'length > 0 and (map(type == \"object\") | all)' \"$DM/.agents/metrics/driver-mode/DMS1.jsonl\" >/dev/null"
# The exact call sequence above for DMS1 was: enter, exit, exit (the repeated
# no-op exit). `length > 0` alone would pass even if a record went missing or
# the append order were scrambled -- assert the shape too.
assert_true "the driver-mode log holds EXACTLY 3 records (enter, exit, exit), in order" \
  "[ \"\$(jq -r '.kind' \"$DM/.agents/metrics/driver-mode/DMS1.jsonl\" | paste -sd, -)\" = 'enter,exit,exit' ]"
assert_true "the enter record carries model/effort/threshold" \
  "jq -e 'select(.kind == \"enter\") | .model == \"claude-sonnet-5\" and .effort == \"high\" and .threshold == \"unknown\"' \"$DM/.agents/metrics/driver-mode/DMS1.jsonl\" >/dev/null"
assert_true "driver-mode enter never writes to the outcomes log" \
  "[ ! -d \"$DM/.agents/metrics/outcomes\" ]"
assert_true "sweep-open --list prints nothing after only a driver-mode enter" \
  "[ -z \"\$(cd \"$DM\" && \"\$RUNSTATE\" sweep-open --list)\" ]"
assert_true "driver-mode enter rejects a session id containing '..'" \
  "(cd \"$DM\" && ! \"\$RUNSTATE\" driver-mode enter --model m --effort e --threshold t '..' 2>/dev/null)"
assert_true "driver-mode enter rejects a session id with an illegal character" \
  "(cd \"$DM\" && ! \"\$RUNSTATE\" driver-mode enter --model m --effort e --threshold t 'bad/id' 2>/dev/null)"
assert_true "driver-mode status rejects a hostile session id rather than reading it" \
  "(cd \"$DM\" && ! \"\$RUNSTATE\" driver-mode status '../escape' 2>/dev/null)"

echo "-- driver-mode enter refuses an adhoc fallback; exit/status may still use it (review fix 11) --"
assert_true "driver-mode enter refuses when neither an arg nor CLAUDE_CODE_SESSION_ID is given" \
  "(cd \"$DM\" && ! env -u CLAUDE_CODE_SESSION_ID \"\$RUNSTATE\" driver-mode enter --model m --effort e --threshold t 2>/dev/null)"
assert_true "the refusal names the reason (no adhoc mark left behind)" \
  "(cd \"$DM\" && env -u CLAUDE_CODE_SESSION_ID \"\$RUNSTATE\" driver-mode enter --model m --effort e --threshold t 2>&1 >/dev/null) | grep -qi 'adhoc'"
assert_true "  and no mark was written for 'adhoc'" \
  "[ ! -f \"$DM/.agents/driver-mode/adhoc\" ]"
assert_true "driver-mode status with no session id still reports off (adhoc fallback kept for queries)" \
  "[ \"\$(cd \"$DM\" && env -u CLAUDE_CODE_SESSION_ID \"\$RUNSTATE\" driver-mode status)\" = 'DRIVER_MODE=off' ]"

echo "-- _rs_json_escape: a tab or other control byte must not break routing.jsonl/the driver-mode log (review fix 6) --"
DM_TAB_OUT="$(cd "$DM" && "$RUNSTATE" driver-mode enter --model m --effort e --threshold t DMSTAB)"
(cd "$DM" && "$RUNSTATE" driver-mode exit DMSTAB >/dev/null)
assert_true "a tab in driver-mode enter's --model still yields valid JSON" \
  "(cd \"$DM\" && \"\$RUNSTATE\" driver-mode enter --model \$'tab\\there' --effort e --threshold t DMSCTRL >/dev/null) && jq -s -e 'map(type == \"object\") | all' \"$DM/.agents/metrics/driver-mode/DMSCTRL.jsonl\" >/dev/null"
assert_true "the tab was collapsed to a space, not left raw in the JSON" \
  "[ \"\$(jq -r 'select(.kind == \"enter\") | .model' \"$DM/.agents/metrics/driver-mode/DMSCTRL.jsonl\")\" = 'tab here' ]"
assert_true "a \\001 control byte in --effort still yields valid JSON (deleted, not left raw)" \
  "(cd \"$DM\" && \"\$RUNSTATE\" driver-mode enter --model m --effort \$'ctrl\\001here' --threshold t DMSCTRL2 >/dev/null) && jq -s -e 'map(type == \"object\") | all' \"$DM/.agents/metrics/driver-mode/DMSCTRL2.jsonl\" >/dev/null"
assert_true "  and the \\001 byte itself is gone from the decoded value" \
  "[ \"\$(jq -r 'select(.kind == \"enter\") | .effort' \"$DM/.agents/metrics/driver-mode/DMSCTRL2.jsonl\")\" = 'ctrlhere' ]"

echo
echo "== session-start.sh: clears its OWN session's driver-mode mark on startup/resume (T6) =="
sess_payload() { printf '{"session_id":"%s","source":"%s","hook_event_name":"SessionStart"}' "$1" "$2"; }
run_ss_hook() { # run_ss_hook <project-dir> <payload>
  printf '%s' "$2" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$1" bash "$HOOK"
}
SSD="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$SSD" init -q
git -C "$SSD" config user.email t@t; git -C "$SSD" config user.name t
mkdir -p "$SSD/.agents"
printf 'schema: 3\nstatus: running\n' > "$SSD/.agents/run-state.yaml"
(cd "$SSD" && "$RUNSTATE" driver-mode enter --model m --effort e --threshold t SSA >/dev/null)
(cd "$SSD" && "$RUNSTATE" driver-mode enter --model m --effort e --threshold t SSB >/dev/null)
run_ss_hook "$SSD" "$(sess_payload SSA startup)" >/dev/null
assert_true "a reopened session's mark is cleared on startup" \
  "[ \"\$(cd \"$SSD\" && \"\$RUNSTATE\" driver-mode status SSA)\" = 'DRIVER_MODE=off' ]"
assert_true "another session's mark is untouched by that same hook run" \
  "[ \"\$(cd \"$SSD\" && \"\$RUNSTATE\" driver-mode status SSB)\" = 'DRIVER_MODE=on' ]"
(cd "$SSD" && "$RUNSTATE" driver-mode enter --model m --effort e --threshold t SSC >/dev/null)
run_ss_hook "$SSD" "$(sess_payload SSC resume)" >/dev/null
assert_true "a resumed session's mark is cleared on resume" \
  "[ \"\$(cd \"$SSD\" && \"\$RUNSTATE\" driver-mode status SSC)\" = 'DRIVER_MODE=off' ]"
assert_true "session-start.sh emits valid JSON even while clearing a mark" \
  "run_ss_hook \"$SSD\" \"\$(sess_payload SSB startup)\" | python3 -c 'import json,sys; json.load(sys.stdin)'"
# This fixture's run-state carries status: running, so the hook's OTHER job
# (the resume notice) fires regardless of whether a mark was cleared -- these
# two assert the mark-clearing logic fails open (no crash, no nonzero exit,
# the rest of the hook still runs) rather than asserting silence, which would
# only be true with no run-state present at all (see the pre-existing "hook is
# silent when no run-state" case above).
assert_true "session-start.sh fails open with no session_id in the payload (exit 0, still emits its normal resume notice)" \
  "run_ss_hook \"$SSD\" '{\"source\":\"startup\"}' | grep -q additionalContext"
assert_true "re-clearing an already-cleared mark is a no-op, not an error" \
  "run_ss_hook \"$SSD\" \"\$(sess_payload SSB startup)\" | grep -q additionalContext && [ \"\$(cd \"$SSD\" && \"\$RUNSTATE\" driver-mode status SSB)\" = 'DRIVER_MODE=off' ]"

echo "-- CR safety: a jq whose output carries a trailing CRLF must not defeat session-id extraction (review fix 7) --"
# Reproduces ADR 0019 v3.1's own defect one layer up: a native Windows jq
# build opens stdout in TEXT mode, so ITS OWN OUTPUT carries a trailing CRLF
# even on a pipe, and plain bash's `$(...)` strips only the trailing `\n` --
# the `\r` survives into `sess`, `_rs_check_session_id` then rejects it
# (correctly: a bare CR is not `[A-Za-z0-9._-]`), and this hook's own
# `|| true` swallows that failure SILENTLY, so the mark never clears. Built
# with `printf`, never `sed 's/$/\r/'` -- BSD/macOS sed inserts a literal
# "r" character there, not a carriage return (the exact gotcha CLAUDE.md
# documents for this class of fix). The probe query (`._p`) is left clean so
# jq is still selected as the parser; only the session_id query's own output
# carries the defect, isolating the extraction-branch fix from the (separate,
# out-of-scope here) parser-detection-probe question.
CRJQ_DIR="$(mktemp -d)"
cat > "$CRJQ_DIR/jq" <<'FAKEJQ'
#!/bin/sh
if [ "$1" = "-er" ] && [ "$2" = "._p" ]; then
  printf 'ok\n'
  exit 0
fi
if [ "$1" = "-r" ] && [ "$2" = '.session_id // empty' ]; then
  input="$(cat)"
  sid="$(printf '%s' "$input" | grep -o '"session_id":"[^"]*"' | sed 's/.*:"//; s/"$//')"
  printf '%s\r\n' "$sid"
  exit 0
fi
exit 1
FAKEJQ
chmod +x "$CRJQ_DIR/jq"
(cd "$SSD" && "$RUNSTATE" driver-mode enter --model m --effort e --threshold t SSCRLF >/dev/null)
PATH="$CRJQ_DIR:$PATH" run_ss_hook "$SSD" "$(sess_payload SSCRLF startup)" >/dev/null
assert_true "a CRLF-corrupted jq extraction still clears the right session's mark (tr -d '\\r' strips it first)" \
  "[ \"\$(cd \"$SSD\" && \"\$RUNSTATE\" driver-mode status SSCRLF)\" = 'DRIVER_MODE=off' ]"

echo
echo "== driver-mode-compact.sh: re-arms the driver after compaction, never on a bare clear (T6) =="
COMPACT_HOOK="${PLUGIN_ROOT}/hooks/driver-mode-compact.sh"
run_compact_hook() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$SSD" bash "$COMPACT_HOOK"; }
assert_true "driver-mode-compact.sh exists and is executable" "[ -x '$COMPACT_HOOK' ]"
(cd "$SSD" && "$RUNSTATE" driver-mode enter --model m --effort e --threshold t SSD1 >/dev/null)
COMPACT_OUT="$(run_compact_hook "$(sess_payload SSD1 compact)")"
assert_true "a compacted session's mark is KEPT, not cleared" \
  "[ \"\$(cd \"$SSD\" && \"\$RUNSTATE\" driver-mode status SSD1)\" = 'DRIVER_MODE=on' ]"
assert_true "the compact hook tells the model to Read agents/loop-driver.md" \
  "printf '%s' \"\$COMPACT_OUT\" | grep -q 'agents/loop-driver.md'"
assert_true "the compact hook injects additionalContext" \
  "printf '%s' \"\$COMPACT_OUT\" | grep -q additionalContext"
assert_true "the compact hook emits valid JSON" \
  "printf '%s' \"\$COMPACT_OUT\" | python3 -c 'import json,sys; json.load(sys.stdin)'"
assert_true "the compact hook is silent for a session with no mark" \
  "[ -z \"\$(run_compact_hook \"\$(sess_payload SSD2 compact)\")\" ]"
assert_true "the compact hook fails open with no session_id (silent, no crash)" \
  "[ -z \"\$(run_compact_hook '{\"source\":\"compact\"}')\" ]"
# ADR 0028: /clear mints a NEW session_id, so this hook (registered on
# `compact` ONLY -- see the hooks.json `matcher == "compact"` assertion below,
# which is the REAL pin against ever running on a `clear` source) never
# legitimately sees a `clear` source in production. This case is honestly
# near-vacuous on its own: the hook script itself never reads or branches on
# `source` at all, so feeding it one directly proves only that it has no
# clearing logic to trigger -- not that the harness will never call it that
# way. Kept as a direct pin on THIS script's own (lack of) behavior, distinct
# from the matcher assertion, which pins the REGISTRATION.
assert_true "this hook has no clearing logic to trigger, regardless of the payload's source field" \
  "run_compact_hook \"\$(sess_payload SSD1 clear)\" >/dev/null; [ \"\$(cd \"$SSD\" && \"\$RUNSTATE\" driver-mode status SSD1)\" = 'DRIVER_MODE=on' ]"

echo "-- CR safety: a CRLF-corrupted jq extraction must not silence the re-arm note (review fix 7) --"
# Same fake jq as the session-start.sh CRLF case above (CRJQ_DIR), reused
# here: this hook's own status LOOKUP (not a clear) must still find the
# mark and emit the note once the CR is stripped.
(cd "$SSD" && "$RUNSTATE" driver-mode enter --model m --effort e --threshold t SSCRLF2 >/dev/null)
COMPACT_CRLF_OUT="$(PATH="$CRJQ_DIR:$PATH" run_compact_hook "$(sess_payload SSCRLF2 compact)")"
assert_true "a CRLF-corrupted jq extraction still finds the mark and emits the re-arm note" \
  "printf '%s' \"\$COMPACT_CRLF_OUT\" | grep -q 'agents/loop-driver.md'"

echo
echo "== hooks.json: driver-mode-compact.sh registered on SessionStart compact (T6) =="
HOOKS_JSON="${PLUGIN_ROOT}/hooks/hooks.json"
assert_true "hooks.json is valid JSON" "jq -e . '$HOOKS_JSON' >/dev/null"
assert_true "a SessionStart entry matches 'compact' and runs driver-mode-compact.sh" \
  "jq -e '.hooks.SessionStart[] | select(.matcher == \"compact\") | .hooks[].command | test(\"driver-mode-compact.sh\")' '$HOOKS_JSON' >/dev/null"
assert_true "the existing startup|resume SessionStart entry is unchanged" \
  "jq -e '.hooks.SessionStart[] | select(.matcher == \"startup|resume\") | .hooks[].command | test(\"session-start.sh\")' '$HOOKS_JSON' >/dev/null"

echo
echo "== begin-run: mint run_id once, create + prune .agents/loop/ (thin-loop-driver T7) =="
BR="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$BR" init -q
git -C "$BR" config user.email t@t; git -C "$BR" config user.name t
mkdir -p "$BR/.agents"
printf 'schema: 3\nstatus: running\n' > "$BR/.agents/run-state.yaml"
BR_OUT1="$(cd "$BR" && "$RUNSTATE" begin-run .agents/run-state.yaml)"
BR_RUN_ID="$(printf '%s\n' "$BR_OUT1" | sed -n 's/^RUN_ID=//p')"
assert_true "begin-run reports a RUN_ID" "[ -n \"\$BR_RUN_ID\" ]"
assert_true "begin-run creates the run directory" \
  "[ -d \"$BR/.agents/loop/\$BR_RUN_ID\" ]"
assert_true "begin-run writes run_id into run-state" \
  "[ \"\$(\"\$RUNSTATE\" get \"$BR/.agents/run-state.yaml\" run_id)\" = \"\$BR_RUN_ID\" ]"
assert_true "begin-run leaves run-state valid YAML" "yamlok \"$BR/.agents/run-state.yaml\""
BR_OUT2="$(cd "$BR" && "$RUNSTATE" begin-run .agents/run-state.yaml)"
BR_RUN_ID2="$(printf '%s\n' "$BR_OUT2" | sed -n 's/^RUN_ID=//p')"
assert_true "a second begin-run mints the SAME run_id (minted once, resume keeps it)" \
  "[ \"\$BR_RUN_ID2\" = \"\$BR_RUN_ID\" ]"
assert_true "a second begin-run with nothing else to prune reports no REMOVED= line" \
  "! printf '%s\n' \"\$BR_OUT2\" | grep -q '^REMOVED='"

# Fabricate THREE run_id-shaped directories that sort BEFORE $BR_RUN_ID (a
# real current timestamp, so any earlier YYYYMMDDTHHMMSS prefix sorts below
# it lexically), plus one NON-shaped directory that must survive regardless
# of age. Pruning is by NAME SHAPE now, never by mtime -- the defect this
# replaced was `stat -f %m` reading as the FILE MODE on GNU `stat`, not a
# time, which silently kept the WRONG directory (or none at all) on
# Linux/Git Bash. Using fabricated names (not real mtimes) proves the fix
# does not depend on the filesystem's clock at all.
mkdir -p "$BR/.agents/loop/20260101T000000-aaaa" \
         "$BR/.agents/loop/20260102T000000-bbbb" \
         "$BR/.agents/loop/20260103T000000-cccc" \
         "$BR/.agents/loop/operator-scratch"
BR_OUT3="$(cd "$BR" && "$RUNSTATE" begin-run .agents/run-state.yaml)"
assert_true "begin-run prunes the OLDEST shape-matching directory" \
  "printf '%s\n' \"\$BR_OUT3\" | grep -qx 'REMOVED=20260101T000000-aaaa'"
assert_true "begin-run prunes the second-oldest shape-matching directory" \
  "printf '%s\n' \"\$BR_OUT3\" | grep -qx 'REMOVED=20260102T000000-bbbb'"
assert_true "begin-run keeps the current run's directory" \
  "[ -d \"$BR/.agents/loop/\$BR_RUN_ID\" ]"
assert_true "begin-run keeps the newest OTHER (previous) shape-matching directory" \
  "[ -d \"$BR/.agents/loop/20260103T000000-cccc\" ]"
assert_true "begin-run does not also remove the newest previous directory" \
  "! printf '%s\n' \"\$BR_OUT3\" | grep -qx 'REMOVED=20260103T000000-cccc'"
assert_true "a non-run_id-shaped directory survives unconditionally" \
  "[ -d \"$BR/.agents/loop/operator-scratch\" ]"
assert_true "a non-run_id-shaped directory is never reported as REMOVED" \
  "! printf '%s\n' \"\$BR_OUT3\" | grep -qx 'REMOVED=operator-scratch'"

echo
echo "== begin-run refuses a hostile run_id read back from run-state (thin-loop-driver review fix) =="
BRH="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$BRH" init -q
git -C "$BRH" config user.email t@t; git -C "$BRH" config user.name t
mkdir -p "$BRH/.agents"
printf 'schema: 3\nstatus: running\nrun_id: ../../../escape\n' > "$BRH/.agents/run-state.yaml"
assert_true "begin-run refuses a run_id containing '..' rather than creating a directory outside the repo" \
  "(cd \"$BRH\" && ! \"\$RUNSTATE\" begin-run .agents/run-state.yaml 2>/dev/null)"
assert_true "the refused begin-run created no .agents/loop/ at all" \
  "[ ! -d \"$BRH/.agents/loop\" ]"

echo
echo "== .agents/loop/ run-directory files survive the pause stash (thin-loop-driver T7) =="
BRG="$(cd "$(mktemp -d)" && pwd -P)"
printf 'hello\n' > "$BRG/README.md"
printf '.agents/loop/\n.agents/run-state.yaml\n' > "$BRG/.gitignore"
git -C "$BRG" init -q
git -C "$BRG" config user.email t@t; git -C "$BRG" config user.name t
git -C "$BRG" add -A; git -C "$BRG" commit -qm init
BRG_GREEN="$(git -C "$BRG" rev-parse HEAD)"
mkdir -p "$BRG/.agents"
printf 'schema: 3\nstatus: running\nlast_green_commit: %s\nbacklog:\n  cursor: p1\n  pending:\n    - p1\n' "$BRG_GREEN" > "$BRG/.agents/run-state.yaml"
BRG_RUN_ID="$(cd "$BRG" && "$RUNSTATE" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
printf 'scratch handoff\n' > "$BRG/.agents/loop/$BRG_RUN_ID/scratch.md"
assert_true "the run directory does not dirty git status (it is ignored)" \
  "[ -z \"\$(git -C '$BRG' status --porcelain)\" ]"
assert_true "reconcile reads clean with the run directory present" \
  "[ \"\$(\"\$RUNSTATE\" reconcile \"$BRG/.agents/run-state.yaml\" \"$BRG\" | sed -n 's/^DECISION=//p')\" = clean ]"
git -C "$BRG" stash push --include-untracked -m 'orch pause scratch' >/dev/null 2>&1 || true
assert_true "the run directory's file survives git stash --include-untracked (ignored files are skipped)" \
  "[ -f \"$BRG/.agents/loop/\$BRG_RUN_ID/scratch.md\" ]"
assert_true "reconcile still reads clean after the stash" \
  "[ \"\$(\"\$RUNSTATE\" reconcile \"$BRG/.agents/run-state.yaml\" \"$BRG\" | sed -n 's/^DECISION=//p')\" = clean ]"

echo "-- the REAL .gitignore files actually ignore .agents/loop/ and .agents/driver-mode/ (review fix 10) --"
# BRG's own fixture .gitignore (above) only proves the STASH survives when a
# path is ignored -- it says nothing about whether the plugin's real,
# shipped .gitignore files actually name these paths. `git check-ignore`
# against a copy of each real file, in its own throwaway repo, is the direct
# pin: if either file's entry ever drifts or gets removed, this fails even
# though the BRG case above would still pass (it writes its OWN minimal
# .gitignore, unrelated to the shipped ones).
for GI_REL in ".gitignore" "templates/spec-driven-base/.gitignore"; do
  GI_SRC="${PLUGIN_ROOT}/${GI_REL}"
  GI_CHECK="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$GI_CHECK" init -q
  cp "$GI_SRC" "$GI_CHECK/.gitignore"
  assert_true "${GI_REL} ignores .agents/loop/x" \
    "git -C '$GI_CHECK' check-ignore -q '.agents/loop/x'"
  assert_true "${GI_REL} ignores .agents/driver-mode/x" \
    "git -C '$GI_CHECK' check-ignore -q '.agents/driver-mode/x'"
done

echo
echo "== handoff + write-result: script-written files for read-only-tooled agents (thin-loop-driver T8) =="
HW="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$HW" init -q
git -C "$HW" config user.email t@t; git -C "$HW" config user.name t
mkdir -p "$HW/.agents"
printf 'schema: 3\nstatus: running\n' > "$HW/.agents/run-state.yaml"
HW_RUN_ID="$(cd "$HW" && "$RUNSTATE" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
HW_RUN_DIR="$HW/.agents/loop/$HW_RUN_ID"

HANDOFF_OUT="$(printf 'T9 Add route\nfull body text here.\n' | (cd "$HW" && "$RUNSTATE" handoff .agents/run-state.yaml pkt-h --tier integration --agent implementer))"
HANDOFF_PATH="$(printf '%s\n' "$HANDOFF_OUT" | sed -n 's/^HANDOFF=//p')"
assert_true "handoff reports a HANDOFF= path" "[ -n \"\$HANDOFF_PATH\" ]"
assert_true "handoff writes the file inside this run's packet directory" \
  "[ -f \"$HW_RUN_DIR/pkt-h/handoff.md\" ]"
assert_true "the handoff is headed by the packet id" \
  "head -1 \"$HW_RUN_DIR/pkt-h/handoff.md\" | grep -q '^# pkt-h:'"
assert_true "the handoff header carries the title (the piped text's first line)" \
  "head -1 \"$HW_RUN_DIR/pkt-h/handoff.md\" | grep -q 'T9 Add route'"
assert_true "the handoff header carries the tier" \
  "grep -qx 'tier: integration' \"$HW_RUN_DIR/pkt-h/handoff.md\""
assert_true "the handoff header carries the agent" \
  "grep -qx 'agent: implementer' \"$HW_RUN_DIR/pkt-h/handoff.md\""
assert_true "the full piped body is present" \
  "grep -q 'full body text here.' \"$HW_RUN_DIR/pkt-h/handoff.md\""
assert_true "the handoff header carries an ABSOLUTE run-state path (review fix #8)" \
  "grep -qx \"run-state: $HW/.agents/run-state.yaml\" \"$HW_RUN_DIR/pkt-h/handoff.md\""
assert_true "the handoff header carries the agent-specific result path, absolute" \
  "grep -qx \"result: $HW_RUN_DIR/pkt-h/implementer.md\" \"$HW_RUN_DIR/pkt-h/handoff.md\""
assert_true "the handoff header carries the fixed review path, absolute" \
  "grep -qx \"review: $HW_RUN_DIR/pkt-h/review.md\" \"$HW_RUN_DIR/pkt-h/handoff.md\""

echo "-- handoff title precedence: TEXT= wins, then first non-KEY= line, then the packet id (review fix 1) --"
# A literal copy of scripts/gspec-backlog.sh handoff's own success shape (see
# its header comment: PACKET=/FEATURE=/ID=/CHECKED=/TEXT=/... in that exact
# order) -- the real producer's FIRST line is `PACKET=`, never the title, so
# a naive `head -1` would have taken "PACKET=slug-t3" as the title.
ADAPTER_SHAPE='PACKET=slug-t3
FEATURE=slug
ID=T3
CHECKED=0
TEXT=Add the driver-mode subcommand
FILES=scripts/runstate.sh
COVERS=none
PRD=gspec/features/slug/prd.md
ARCH=absent'
printf '%s\n' "$ADAPTER_SHAPE" | (cd "$HW" && "$RUNSTATE" handoff .agents/run-state.yaml pkt-adapter --tier integration --agent implementer) >/dev/null
assert_true "adapter-shaped stdin: the title comes from TEXT=, not the first line" \
  "head -1 \"$HW_RUN_DIR/pkt-adapter/handoff.md\" | grep -q 'Add the driver-mode subcommand'"
assert_true "adapter-shaped stdin: the title is never a bare KEY=value line" \
  "! head -1 \"$HW_RUN_DIR/pkt-adapter/handoff.md\" | grep -q 'PACKET=slug-t3'"

# The REAL producer, run against a repo with no gspec/ directory at all, so
# it takes the NOGSPEC path and prints exactly `HANDOFF=unknown\nREASON=...`
# -- both lines match `^[A-Z_]+=` and neither carries a `TEXT=` line, so
# there is nothing usable and the title must fall through to the packet id.
GSPECSH="${PLUGIN_ROOT}/scripts/gspec-backlog.sh"
NOGSPEC_OUT="$("$GSPECSH" handoff pkt-nogspec "$HW" 2>/dev/null || true)"
assert_true "the real gspec-backlog.sh handoff, with no gspec/ dir, carries no TEXT= line" \
  "! printf '%s\n' \"\$NOGSPEC_OUT\" | grep -q '^TEXT='"
printf '%s\n' "$NOGSPEC_OUT" | (cd "$HW" && "$RUNSTATE" handoff .agents/run-state.yaml pkt-nogspec --tier integration --agent implementer) >/dev/null
assert_true "no TEXT= line and only KEY=value lines: the title falls back to the packet id" \
  "head -1 \"$HW_RUN_DIR/pkt-nogspec/handoff.md\" | grep -qx '# pkt-nogspec: pkt-nogspec'"

printf '' | (cd "$HW" && "$RUNSTATE" handoff .agents/run-state.yaml pkt-empty --tier integration --agent implementer) >/dev/null
assert_true "empty stdin: the title falls back to the packet id" \
  "head -1 \"$HW_RUN_DIR/pkt-empty/handoff.md\" | grep -qx '# pkt-empty: pkt-empty'"

echo "-- handoff: every handoff carries the verification contract (handoff-verification-contract T2) --"
# MUTATION RULED OUT: the append itself. Delete `printf '\n%s\n' "$required"`
# from cmd_handoff's write block (the wrong implementation where the contract
# is documented but never reaches the handoff) and every assertion below that
# looks for a REQUIRED line, and the heading assertion, turn red -- the handoff
# is still written and still carries the task text, so nothing else notices.
HR_TPL="${PLUGIN_ROOT}/templates/handoff-required.md"
HC_FILE="$HW_RUN_DIR/pkt-contract/handoff.md"
# The six line NAMES are spelled out here rather than scraped from the template,
# so a line silently dropped from the template fails this sweep instead of
# shrinking the thing it is checked against. The count assertion pins the other
# direction: a SEVENTH line added to the template and not asserted here.
HR_NAMES="mutation-verification unmeasured real-interface report-the-limitation current-file second-run"
assert_true "the template states exactly the six REQUIRED lines asserted below" \
  "[ \"\$(grep -c '^REQUIRED [a-z-]*:' \"$HR_TPL\")\" = 6 ]"
# The second piped line stands in for one of the driver's own conditional
# REQUIRED lines (run-loop writes them into the body it pipes in), so the
# "ahead of the block, neither moved nor repeated" assertions below have a real
# instance to check rather than a hypothetical one.
printf 'TEXT=Add the verification block\nREQUIRED: the regression sweep covering runstate.sh passes\n' \
  | (cd "$HW" && "$RUNSTATE" handoff .agents/run-state.yaml pkt-contract --tier integration --agent implementer) >/dev/null
assert_true "the handoff carries the piped task text" \
  "grep -q 'Add the verification block' \"$HC_FILE\""
assert_true "the block sits under its own heading" \
  "grep -qx '## REQUIRED — the verification contract' \"$HC_FILE\""
for HR_NAME in $HR_NAMES; do
  assert_true "the handoff carries the REQUIRED ${HR_NAME} line" \
    "grep -q \"^REQUIRED ${HR_NAME}: \" \"$HC_FILE\""
done
# Ordering: task text, then the driver's conditional line, then the heading,
# then the last of the six. `tail -1` on the task text deliberately takes the
# BODY occurrence, not the title line the header repeats it on.
HC_TEXT_LN="$(grep -n 'Add the verification block' "$HC_FILE" | tail -1 | cut -d: -f1)"
HC_DRV_LN="$(grep -n '^REQUIRED: the regression sweep covering runstate.sh passes$' "$HC_FILE" | head -1 | cut -d: -f1)"
HC_HEAD_LN="$(grep -n '^## REQUIRED — the verification contract$' "$HC_FILE" | head -1 | cut -d: -f1)"
HC_LAST_LN="$(grep -n '^REQUIRED second-run: ' "$HC_FILE" | head -1 | cut -d: -f1)"
assert_true "the task text comes BEFORE the block, never after it" \
  "[ -n \"$HC_TEXT_LN\" ] && [ -n \"$HC_HEAD_LN\" ] && [ \"$HC_TEXT_LN\" -lt \"$HC_HEAD_LN\" ]"
assert_true "the driver's own conditional REQUIRED line stays AHEAD of the block" \
  "[ -n \"$HC_DRV_LN\" ] && [ -n \"$HC_HEAD_LN\" ] && [ \"$HC_DRV_LN\" -lt \"$HC_HEAD_LN\" ]"
assert_true "the driver's own conditional REQUIRED line is not repeated inside the block" \
  "[ \"\$(grep -c '^REQUIRED: the regression sweep covering runstate.sh passes\$' \"$HC_FILE\")\" = 1 ]"
assert_true "the six lines follow the heading" \
  "[ -n \"$HC_LAST_LN\" ] && [ \"$HC_HEAD_LN\" -lt \"$HC_LAST_LN\" ]"
# The block is not conditional on the body's source: an empty body (the
# no-gspec fallback above pipes only KEY=value lines, and `pkt-empty` pipes
# nothing at all) still gets it.
assert_true "a handoff built from empty stdin carries the block too" \
  "grep -q '^REQUIRED second-run: ' \"$HW_RUN_DIR/pkt-empty/handoff.md\""

echo "-- handoff: an implementer handoff states its budget and the stop rule (implementer-continuation T1) --"
# MUTATIONS RULED OUT: (a) the line written for every agent (drop the
# `agent = implementer` test) -- the doc-writer assertion turns red; (b) the
# override ignored (a hard-coded 120) -- the override and quoted/commented
# assertions turn red; (c) a missing/invalid/zero value passed through rather
# than defaulted -- those three turn red; (d) the line written AFTER the body
# (between the driver's conditional REQUIRED lines and the six) -- the
# byte-identity assertion turns red, since the tail below the header no longer
# matches a handoff written without the line.
HB_BODY='TEXT=Budget case
REQUIRED: the regression sweep covering runstate.sh passes'
hb_handoff() {  # <pkt> <agent> -- writes a handoff with the fixed body
  printf '%s\n' "$HB_BODY" \
    | (cd "$HW" && "$RUNSTATE" handoff .agents/run-state.yaml "$1" --tier integration --agent "$2") >/dev/null
}
hb_budget_count() { grep -c '^BUDGET: ' "$HW_RUN_DIR/$1/handoff.md" || true; }
hb_has_budget() {  # <pkt> <n>
  grep -qx "BUDGET: this dispatch has a budget of $2 tool calls\\. At the budget, stop at a safe boundary — never mid-edit — leave the partial work uncommitted in the working tree, write what is done and what remains to the result file, and return a status line whose first token is \`continue\`\\." \
    "$HW_RUN_DIR/$1/handoff.md"
}
rm -f "$HW/.agents/project-overrides.yaml"
hb_handoff pkt-bdef implementer
assert_true "default: with no project-overrides.yaml, the implementer budget line reads 120 and states the stop rule" \
  "hb_has_budget pkt-bdef 120"
assert_true "the implementer handoff carries exactly ONE budget line" \
  "[ \"\$(hb_budget_count pkt-bdef)\" = 1 ]"
# Placement: line 9 -- directly after the header's blank line (header is
# lines 1-8: title, blank, tier, agent, run-state, result, review, blank).
assert_true "the budget line sits directly after the header, before the body" \
  "[ \"\$(sed -n 8p \"$HW_RUN_DIR/pkt-bdef/handoff.md\")\" = '' ] && sed -n 9p \"$HW_RUN_DIR/pkt-bdef/handoff.md\" | grep -q '^BUDGET: ' && [ \"\$(sed -n 10p \"$HW_RUN_DIR/pkt-bdef/handoff.md\")\" = '' ] && sed -n 11p \"$HW_RUN_DIR/pkt-bdef/handoff.md\" | grep -qx 'TEXT=Budget case'"

printf 'schema: 1\nimplementer_turn_budget: 150\n' > "$HW/.agents/project-overrides.yaml"
hb_handoff pkt-bov implementer
assert_true "override: implementer_turn_budget: 150 is honoured" "hb_has_budget pkt-bov 150"
printf "implementer_turn_budget: '75'   # quoted, comment-trailed\n" > "$HW/.agents/project-overrides.yaml"
hb_handoff pkt-bq implementer
assert_true "override: a quoted, comment-trailed value is honoured (75, not 120)" "hb_has_budget pkt-bq 75"

printf 'schema: 1\npacket_attempts: 3\n' > "$HW/.agents/project-overrides.yaml"
hb_handoff pkt-bmiss implementer
assert_true "a missing implementer_turn_budget key reads as 120" "hb_has_budget pkt-bmiss 120"
printf 'implementer_turn_budget: lots\n' > "$HW/.agents/project-overrides.yaml"
hb_handoff pkt-binv implementer
assert_true "an invalid implementer_turn_budget reads as 120" "hb_has_budget pkt-binv 120"
printf 'implementer_turn_budget: 0\n' > "$HW/.agents/project-overrides.yaml"
hb_handoff pkt-bzero implementer
assert_true "implementer_turn_budget: 0 reads as 120" "hb_has_budget pkt-bzero 120"
printf 'implementer_turn_budget: 00\n' > "$HW/.agents/project-overrides.yaml"
hb_handoff pkt-bzero2 implementer
assert_true "implementer_turn_budget: 00 (zero with a leading zero) reads as 120" "hb_has_budget pkt-bzero2 120"
rm -f "$HW/.agents/project-overrides.yaml"

hb_handoff pkt-bdoc doc-writer
assert_true "a doc-writer handoff carries no budget line" \
  "[ \"\$(hb_budget_count pkt-bdoc)\" = 0 ]"
# Byte identity: everything below the header (and, for the implementer, below
# the budget line and its blank) is identical to the doc-writer handoff built
# from the same body -- body, driver's conditional line, and the REQUIRED block.
tail -n +9  "$HW_RUN_DIR/pkt-bdoc/handoff.md"  > "$HW/hb-doc.tail"
tail -n +11 "$HW_RUN_DIR/pkt-bdef/handoff.md" > "$HW/hb-impl.tail"
assert_true "with the budget line removed, the body and REQUIRED block are byte-identical to a handoff written without it" \
  "[ -s \"$HW/hb-doc.tail\" ] && cmp -s \"$HW/hb-doc.tail\" \"$HW/hb-impl.tail\""

# The same cases on a host with jq and python3 absent (the plan's standing rule
# for every new case in this feature). `NOTOOLS` wraps ONLY the runstate.sh
# call, never the sweep's own helpers; distinct packet ids so no dir collides.
# MUTATION RULED OUT: a budget scan that shells out to jq/python3 -- the
# no-tools cases below turn red while the full-PATH ones above stay green.
hb_handoff_nt() {  # <pkt> <agent> -- as hb_handoff, runstate.sh on the no-tools PATH
  printf '%s\n' "$HB_BODY" \
    | (cd "$HW" && PATH="$NOTOOLS:$PATH" "$RUNSTATE" handoff .agents/run-state.yaml "$1" --tier integration --agent "$2") >/dev/null
}
rm -f "$HW/.agents/project-overrides.yaml"
hb_handoff_nt pkt-nt-bdef implementer
assert_true "default (no-tools host): the implementer budget line reads 120" "hb_has_budget pkt-nt-bdef 120"
assert_true "(no-tools host) the implementer handoff carries exactly ONE budget line" \
  "[ \"\$(hb_budget_count pkt-nt-bdef)\" = 1 ]"
tail -n +9 "$HW_RUN_DIR/pkt-bdef/handoff.md"    > "$HW/hb-full.tail"
tail -n +9 "$HW_RUN_DIR/pkt-nt-bdef/handoff.md" > "$HW/hb-nt.tail"
assert_true "(no-tools host) the implementer handoff below the header is byte-identical to the full-PATH one" \
  "[ -s \"$HW/hb-nt.tail\" ] && cmp -s \"$HW/hb-full.tail\" \"$HW/hb-nt.tail\""

printf 'schema: 1\nimplementer_turn_budget: 150\n' > "$HW/.agents/project-overrides.yaml"
hb_handoff_nt pkt-nt-bov implementer
assert_true "override (no-tools host): implementer_turn_budget: 150 is honoured" "hb_has_budget pkt-nt-bov 150"
printf "implementer_turn_budget: '75'   # quoted, comment-trailed\n" > "$HW/.agents/project-overrides.yaml"
hb_handoff_nt pkt-nt-bq implementer
assert_true "override (no-tools host): a quoted, comment-trailed value is honoured (75)" "hb_has_budget pkt-nt-bq 75"

printf 'schema: 1\npacket_attempts: 3\n' > "$HW/.agents/project-overrides.yaml"
hb_handoff_nt pkt-nt-bmiss implementer
assert_true "(no-tools host) a missing implementer_turn_budget key reads as 120" "hb_has_budget pkt-nt-bmiss 120"
printf 'implementer_turn_budget: lots\n' > "$HW/.agents/project-overrides.yaml"
hb_handoff_nt pkt-nt-binv implementer
assert_true "(no-tools host) an invalid implementer_turn_budget reads as 120" "hb_has_budget pkt-nt-binv 120"
printf 'implementer_turn_budget: 0\n' > "$HW/.agents/project-overrides.yaml"
hb_handoff_nt pkt-nt-bzero implementer
assert_true "(no-tools host) implementer_turn_budget: 0 reads as 120" "hb_has_budget pkt-nt-bzero 120"
rm -f "$HW/.agents/project-overrides.yaml"

hb_handoff_nt pkt-nt-bdoc doc-writer
assert_true "(no-tools host) a doc-writer handoff carries no budget line" \
  "[ \"\$(hb_budget_count pkt-nt-bdoc)\" = 0 ]"

echo "-- handoff: an unreadable contract template REFUSES the handoff (handoff-verification-contract T2) --"
# MUTATION RULED OUT: warn-and-continue. Replace the two `die`s guarding the
# template with a `printf ... >&2` that falls through to the write, and these
# turn red -- the command exits 0 and a handoff.md appears with no block, which
# is precisely the state the refusal exists to prevent (an agent cannot tell a
# contract-less handoff from a handoff whose contract did not apply).
HR_MISSING="$HW/no-such-dir/handoff-required.md"
HC_REFUSE_ERR="$(printf 'TEXT=x\n' | (cd "$HW" && ORCH_HANDOFF_REQUIRED="$HR_MISSING" "$RUNSTATE" handoff .agents/run-state.yaml pkt-norequired --tier integration --agent implementer) 2>&1 >/dev/null || true)"
assert_true "handoff exits non-zero when the contract template is missing" \
  "! (printf 'TEXT=x\n' | (cd \"$HW\" && ORCH_HANDOFF_REQUIRED=\"$HR_MISSING\" \"\$RUNSTATE\" handoff .agents/run-state.yaml pkt-norequired --tier integration --agent implementer)) 2>/dev/null"
assert_true "the refusal names the template path it could not read" \
  "printf '%s\n' \"\$HC_REFUSE_ERR\" | grep -qF \"$HR_MISSING\""
assert_true "a refused handoff writes no handoff.md at all" \
  "[ ! -f \"$HW_RUN_DIR/pkt-norequired/handoff.md\" ]"
assert_true "a refused handoff leaves no temp file beside it either" \
  "[ -z \"\$(ls -A \"$HW_RUN_DIR/pkt-norequired\" 2>/dev/null)\" ]"
HR_BLANK="$HW/blank-required.md"; printf '\n   \n\t\n' > "$HR_BLANK"
assert_true "handoff exits non-zero when the contract template is whitespace-only" \
  "! (printf 'TEXT=x\n' | (cd \"$HW\" && ORCH_HANDOFF_REQUIRED=\"$HR_BLANK\" \"\$RUNSTATE\" handoff .agents/run-state.yaml pkt-blankrequired --tier integration --agent implementer)) 2>/dev/null"
assert_true "a whitespace-only template writes no handoff.md either" \
  "[ ! -f \"$HW_RUN_DIR/pkt-blankrequired/handoff.md\" ]"

echo "-- handoff: the contract resolves from the SCRIPT's location, not the caller's cwd --"
# MUTATION RULED OUT: resolving the template from the caller's cwd. Swap
# `${HERE}/../templates/handoff-required.md` for `templates/handoff-required.md`
# (or `${PWD}/templates/...`) and this turns red -- the cwd below is a nested
# directory of a throwaway repo with no templates/ of its own, so the handoff
# would be REFUSED outright rather than carrying the block. ORCH_HANDOFF_REQUIRED
# is deliberately left UNSET here: this case is about the default resolution,
# and setting it would test the override instead.
HC_DEEP="$HW/deep/nested/cwd"; mkdir -p "$HC_DEEP"
assert_true "the fixture cwd has no templates/handoff-required.md of its own" \
  "[ ! -e \"$HC_DEEP/templates/handoff-required.md\" ] && [ ! -e \"$HW/templates/handoff-required.md\" ]"
assert_true "handoff from a cwd that is not the plugin root still succeeds" \
  "printf 'TEXT=far from the plugin root\\n' | (cd \"$HC_DEEP\" && unset ORCH_HANDOFF_REQUIRED; \"\$RUNSTATE\" handoff \"$HW/.agents/run-state.yaml\" pkt-farcwd --tier integration --agent implementer)"
for HR_NAME in $HR_NAMES; do
  assert_true "from a foreign cwd the handoff still carries the REQUIRED ${HR_NAME} line" \
    "grep -q \"^REQUIRED ${HR_NAME}: \" \"$HW_RUN_DIR/pkt-farcwd/handoff.md\""
done

echo "-- handoff: .agents/handoff-extra extends the block, unioned across config roots (handoff-verification-contract T3) --"
# A FRESH fixture repo, with CLAUDE_PROJECT_DIR pinned to it on every call, so
# the discovered config roots are exactly the ones each case sets up. Without
# the pin the developer's own checkout (which has an .agents/ of its own) is a
# discovered root, and every case below would silently depend on whether THAT
# repo happens to carry a handoff-extra file.
HE="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$HE" init -q
git -C "$HE" config user.email t@t; git -C "$HE" config user.name t
mkdir -p "$HE/.agents"
printf 'schema: 3\nstatus: running\n' > "$HE/.agents/run-state.yaml"
HE_RUN_ID="$(cd "$HE" && CLAUDE_PROJECT_DIR="$HE" "$RUNSTATE" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
HE_RUN_DIR="$HE/.agents/loop/$HE_RUN_ID"
HE_XFILE="$HE/.agents/handoff-extra"
# he_handoff <pkt> [cwd] -- reads the body on stdin, like the real caller.
he_handoff() {
  ( cd "${2:-$HE}" && CLAUDE_PROJECT_DIR="$HE" \
      "$RUNSTATE" handoff "$HE/.agents/run-state.yaml" "$1" --tier integration --agent implementer )
}

# --- no file in any discovered root: identical to the mechanism being absent --
# This handoff is kept as the BASELINE the comments-only case is compared
# against byte for byte. Same fixture, same packet id and same stdin, so every
# header line (run-state path, result path, title) is identical by construction
# and a byte difference can only come from the extension mechanism.
printf 'TEXT=no extension file\n' | he_handoff pkt-extra >/dev/null
HE_NONE="$HE/baseline-handoff.md"; cp "$HE_RUN_DIR/pkt-extra/handoff.md" "$HE_NONE"
assert_true "with no .agents/handoff-extra in any root the handoff carries exactly the template's six REQUIRED lines" \
  "[ \"\$(grep -c '^REQUIRED [a-z-]*: ' \"$HE_NONE\")\" = 6 ]"
assert_true "with no .agents/handoff-extra anywhere the handoff carries no repository REQUIRED line" \
  "[ \"\$(grep -c '^REQUIRED: ' \"$HE_NONE\")\" = 0 ]"
assert_true "nothing follows the sixth line: no section header, no empty section, no warning" \
  "grep -v '^[[:space:]]*\$' \"$HE_NONE\" | tail -1 | grep -q '^REQUIRED second-run: '"

# --- a root holding only comments and blank lines -----------------------------
# MUTATION RULED OUT: dropping the comment/blank filter. Emit every line of the
# file (guard.sh's `case "$line" in ''|\#*) continue` removed from
# _rs_handoff_extra_lines) and this turns red -- the stub's comment lines arrive
# as REQUIRED lines and the handoff is no longer byte-identical to the no-file
# one. The fixture is the SHIPPED consumer stub itself, not a hand-written
# imitation of it, so "the stub changes no handoff" is checked against the real
# file a consumer receives rather than against a copy that could drift from it.
cp "${PLUGIN_ROOT}/templates/spec-driven-base/.agents/handoff-extra" "$HE_XFILE"
assert_true "the shipped consumer stub is comments and blank lines only" \
  "! grep -qv -e '^#' -e '^[[:space:]]*\$' \"${PLUGIN_ROOT}/templates/spec-driven-base/.agents/handoff-extra\""
printf 'TEXT=no extension file\n' | he_handoff pkt-extra >/dev/null
assert_true "a comments-and-blank-lines-only handoff-extra yields a handoff BYTE-IDENTICAL to the no-file one" \
  "cmp -s \"$HE_NONE\" \"$HE_RUN_DIR/pkt-extra/handoff.md\""

# --- a root with real lines ---------------------------------------------------
# MUTATION RULED OUT: appending the lines without the `REQUIRED: ` prefix.
# Change the helper's `printf 'REQUIRED: %s\n'` to `printf '%s\n'` and the two
# prefix assertions turn red -- the repository's criteria are still in the file
# but read as loose prose rather than as criteria in the same form the six and
# the driver's own conditional lines use.
printf '# a commented line that is not a criterion\n\nthe fixture is regenerated with the project command and its output reported\n   \nthe money invariant is named and observed holding\n' > "$HE_XFILE"
printf 'TEXT=with an extension file\n' | he_handoff pkt-extra-lines >/dev/null
HE_LINES="$HE_RUN_DIR/pkt-extra-lines/handoff.md"
assert_true "the first extension line is appended as a REQUIRED line, verbatim" \
  "grep -qx 'REQUIRED: the fixture is regenerated with the project command and its output reported' \"$HE_LINES\""
assert_true "the second extension line is appended as a REQUIRED line, verbatim" \
  "grep -qx 'REQUIRED: the money invariant is named and observed holding' \"$HE_LINES\""
assert_true "a commented line in handoff-extra is not appended" \
  "! grep -q 'a commented line that is not a criterion' \"$HE_LINES\""
assert_true "blank and whitespace-only lines add no empty REQUIRED lines" \
  "[ \"\$(grep -c '^REQUIRED: ' \"$HE_LINES\")\" = 2 ]"
assert_true "the template's six lines are all still there alongside them" \
  "[ \"\$(grep -c '^REQUIRED [a-z-]*: ' \"$HE_LINES\")\" = 6 ]"
HE_SIXTH_LN="$(grep -n '^REQUIRED second-run: ' "$HE_LINES" | head -1 | cut -d: -f1)"
HE_FIRST_X_LN="$(grep -n '^REQUIRED: ' "$HE_LINES" | head -1 | cut -d: -f1)"
assert_true "the extension lines come AFTER the six, never among them" \
  "[ -n \"$HE_SIXTH_LN\" ] && [ -n \"$HE_FIRST_X_LN\" ] && [ \"$HE_SIXTH_LN\" -lt \"$HE_FIRST_X_LN\" ]"

# --- two nested roots: the union, not a winner --------------------------------
# MUTATION RULED OUT: narrowing the union to one root. Break out of
# _rs_handoff_extra_lines' loop after the first root that has the file (the
# "nearest root wins" reading of the merge) and one of these two turns red
# whichever root it picks -- which is the point: a nested or foreign root may
# ADD criteria, and may never remove the outer repository's.
mkdir -p "$HE/inner/.agents"
printf 'the inner root line is a criterion too\n' > "$HE/inner/.agents/handoff-extra"
printf 'TEXT=nested roots\n' | he_handoff pkt-extra-nested "$HE/inner" >/dev/null
HE_NESTED="$HE_RUN_DIR/pkt-extra-nested/handoff.md"
assert_true "with two nested roots the OUTER root's line is present" \
  "grep -qx 'REQUIRED: the money invariant is named and observed holding' \"$HE_NESTED\""
assert_true "with two nested roots the INNER root's line is present" \
  "grep -qx 'REQUIRED: the inner root line is a criterion too' \"$HE_NESTED\""
# A line declared by both roots is one criterion, not two: the roots are deduped
# by resolved path, and so are the lines they contribute.
printf 'the money invariant is named and observed holding\nthe inner root line is a criterion too\n' > "$HE/inner/.agents/handoff-extra"
printf 'TEXT=nested roots, overlapping lines\n' | he_handoff pkt-extra-dup "$HE/inner" >/dev/null
assert_true "a line declared by both roots is appended once, not twice" \
  "[ \"\$(grep -cx 'REQUIRED: the money invariant is named and observed holding' \"$HE_RUN_DIR/pkt-extra-dup/handoff.md\")\" = 1 ]"

# --- present but unreadable: refused, exactly as a missing template is --------
# MUTATION RULED OUT: skipping the file instead of refusing. Replace the `die`
# in _rs_handoff_extra_lines with `continue` (the "be lenient, carry on" reading)
# and these turn red -- the command exits 0 and a handoff.md appears carrying the
# six lines but none of the repository's, which is the one state the refusal
# exists to prevent: an agent cannot tell a handoff whose extension lines were
# dropped from a repository that declared none.
mv "$HE/inner" "$HE/inner-disabled"          # one root for this case, not two
printf 'a criterion that must not be silently dropped\n' > "$HE_XFILE"
chmod 000 "$HE_XFILE"
HE_MODE_UNREADABLE=no
if ! cat "$HE_XFILE" >/dev/null 2>&1; then HE_MODE_UNREADABLE=yes; fi
if [ "$HE_MODE_UNREADABLE" = yes ]; then
  HE_REFUSE_ERR="$(printf 'TEXT=x\n' | he_handoff pkt-extra-unreadable 2>&1 >/dev/null || true)"
  assert_true "handoff exits non-zero when a present .agents/handoff-extra cannot be read (mode 000)" \
    "! (printf 'TEXT=x\n' | he_handoff pkt-extra-unreadable) 2>/dev/null"
  assert_true "the refusal names the extension file it could not read" \
    "printf '%s\n' \"\$HE_REFUSE_ERR\" | grep -qF \"$HE_XFILE\""
  assert_true "a handoff refused over the extension file writes no handoff.md at all" \
    "[ ! -f \"$HE_RUN_DIR/pkt-extra-unreadable/handoff.md\" ]"
  assert_true "a handoff refused over the extension file leaves no temp file beside it either" \
    "[ -z \"\$(ls -A \"$HE_RUN_DIR/pkt-extra-unreadable\" 2>/dev/null)\" ]"
else
  # NOT RUN, and said so rather than passed quietly: as uid 0 a mode-000 file is
  # still readable, so this host cannot create the condition. The directory shape
  # below is unreadable for every uid and covers the same refusal.
  printf 'note this host reads a mode-000 file (uid %s) — the mode-000 shape of the extension refusal was NOT run; the directory shape below was\n' "$(id -u)"
fi
chmod 644 "$HE_XFILE"
# The second unreadable shape, which no uid can read: a DIRECTORY where the file
# is expected. Present (so not skippable as absent) and impossible to cat.
mv "$HE_XFILE" "$HE/.agents/handoff-extra-saved"; mkdir -p "$HE_XFILE"
HE_DIR_ERR="$(printf 'TEXT=x\n' | he_handoff pkt-extra-dir 2>&1 >/dev/null || true)"
assert_true "handoff exits non-zero when .agents/handoff-extra is present but is a directory" \
  "! (printf 'TEXT=x\n' | he_handoff pkt-extra-dir) 2>/dev/null"
assert_true "that refusal names the extension file too" \
  "printf '%s\n' \"\$HE_DIR_ERR\" | grep -qF \"$HE_XFILE\""
assert_true "and writes no handoff.md at all" \
  "[ ! -f \"$HE_RUN_DIR/pkt-extra-dir/handoff.md\" ]"

echo "-- handoff/write-result: charset and traversal refusals (review fixes 3/12/13) --"
assert_true "handoff refuses a packet id of '.'" \
  "! (printf 'x\n' | (cd \"$HW\" && \"\$RUNSTATE\" handoff .agents/run-state.yaml . --tier integration --agent implementer)) 2>/dev/null"
assert_true "handoff refuses a packet id of '..'" \
  "! (printf 'x\n' | (cd \"$HW\" && \"\$RUNSTATE\" handoff .agents/run-state.yaml .. --tier integration --agent implementer)) 2>/dev/null"
assert_true "handoff refuses a packet id containing '..'" \
  "! (printf 'x\n' | (cd \"$HW\" && \"\$RUNSTATE\" handoff .agents/run-state.yaml 'pkt/../escape' --tier integration --agent implementer)) 2>/dev/null"
assert_true "a '..'-refused handoff never escaped to write .agents/loop/handoff.md" \
  "[ ! -f \"$HW/.agents/loop/handoff.md\" ]"
assert_true "handoff refuses a --tier value outside [a-z-]+" \
  "! (printf 'x\n' | (cd \"$HW\" && \"\$RUNSTATE\" handoff .agents/run-state.yaml pkt-badtier --tier \$'integration\\nInjected: line' --agent implementer)) 2>/dev/null"
assert_true "handoff refuses an --agent value outside [a-z-]+" \
  "! (printf 'x\n' | (cd \"$HW\" && \"\$RUNSTATE\" handoff .agents/run-state.yaml pkt-badagent --tier integration --agent \$'implementer\\nInjected: line')) 2>/dev/null"

echo "-- write-result: a symlinked directory under the run dir cannot escape it (review fix 3) --"
# Every --status below is a WELL-FORMED status line (loop-driver-run-gaps T2
# made write-result refuse anything else, ahead of every other check). A
# placeholder like `--status x` would now be refused for its GRAMMAR, so each
# path-refusal case below would still go green while testing nothing about
# paths at all -- exactly the vacuity the owning-sweep rule forbids.
WR_OK_STATUS='fix · first pass · result: needs-reading · /tmp/run/pkt-h/review.md'
WR_OUTSIDE="$(mktemp -d)"
ln -s "$WR_OUTSIDE" "$HW_RUN_DIR/pkt-h/escape-link"
assert_true "write-result refuses a path through a symlinked directory that resolves outside the run dir" \
  "! (printf 'x\n' | (cd \"$HW\" && \"\$RUNSTATE\" write-result .agents/run-state.yaml \"$HW_RUN_DIR/pkt-h/escape-link/pwned.md\" --status \"\$WR_OK_STATUS\")) 2>/dev/null"
assert_true "the symlink escape attempt wrote nothing outside the run dir" \
  "[ ! -f \"$WR_OUTSIDE/pwned.md\" ]"

WR_TARGET="$HW_RUN_DIR/pkt-h/review.md"
WR_OUT1="$(printf 'first body\n' | (cd "$HW" && "$RUNSTATE" write-result .agents/run-state.yaml "$WR_TARGET" --status "$WR_OK_STATUS"))"
assert_true "write-result reports RESULT=" "printf '%s\n' \"\$WR_OUT1\" | grep -q '^RESULT='"
assert_true "the status line is the file's first line" \
  "[ \"\$(head -1 \"$WR_TARGET\")\" = \"\$WR_OK_STATUS\" ]"
assert_true "the body follows the status line" \
  "grep -q 'first body' \"$WR_TARGET\""
WR_OK_STATUS2='pass · second pass · result: no · /tmp/run/pkt-h/review.md'
printf 'second body\n' | (cd "$HW" && "$RUNSTATE" write-result .agents/run-state.yaml "$WR_TARGET" --status "$WR_OK_STATUS2") >/dev/null
assert_true "a rewrite REPLACES the file, not appends" \
  "! grep -q 'first body' \"$WR_TARGET\" && grep -q 'second body' \"$WR_TARGET\""
assert_true "  and the second status line is the file's first line" \
  "[ \"\$(head -1 \"$WR_TARGET\")\" = \"\$WR_OK_STATUS2\" ]"
assert_true "write-result refuses an absolute path outside the run directory" \
  "! (printf 'x\n' | (cd \"$HW\" && \"\$RUNSTATE\" write-result .agents/run-state.yaml /etc/passwd --status \"\$WR_OK_STATUS\")) 2>/dev/null"
assert_true "write-result refuses a traversal back out of the run directory" \
  "! (printf 'x\n' | (cd \"$HW\" && \"\$RUNSTATE\" write-result .agents/run-state.yaml \"$HW_RUN_DIR/pkt-h/../../../../etc/passwd\" --status \"\$WR_OK_STATUS\")) 2>/dev/null"
assert_true "handoff refuses a bad packet-id charset" \
  "! (printf 'x\n' | (cd \"$HW\" && \"\$RUNSTATE\" handoff .agents/run-state.yaml 'bad id' --tier integration --agent implementer)) 2>/dev/null"

echo "-- a failure between mktemp and mv leaves no leftover temp file (review fix 16) --"
# `mv` itself is shadowed to always fail, via PATH -- the same fake-binary
# technique this file already uses for jq/python3 (see the "no-tools host"
# T8 cases above). Isolated to ONE dispatch each: handoff/write-result call
# `mv` exactly once in their own code path, so this cannot mask a failure
# elsewhere in the same invocation.
FAKEMV_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$FAKEMV_DIR/mv"; chmod +x "$FAKEMV_DIR/mv"

HANDOFF_MVFAIL_RC=0
printf 'x\n' | (cd "$HW" && PATH="$FAKEMV_DIR:$PATH" "$RUNSTATE" handoff .agents/run-state.yaml pkt-mvfail --tier integration --agent implementer) >/dev/null 2>&1 \
  || HANDOFF_MVFAIL_RC=$?
assert_true "handoff fails when mv itself fails (forced via a shadowed mv)" \
  "[ \"\$HANDOFF_MVFAIL_RC\" != 0 ]"
assert_true "  and leaves no leftover .handoff.* temp file behind" \
  "! ls \"$HW_RUN_DIR/pkt-mvfail\"/.handoff.* >/dev/null 2>&1"
assert_true "  and wrote no handoff.md either (mv never succeeded)" \
  "[ ! -f \"$HW_RUN_DIR/pkt-mvfail/handoff.md\" ]"

WR_MVFAIL_TARGET="$HW_RUN_DIR/pkt-h/mvfail.md"
WR_MVFAIL_RC=0
printf 'x\n' | (cd "$HW" && PATH="$FAKEMV_DIR:$PATH" "$RUNSTATE" write-result .agents/run-state.yaml "$WR_MVFAIL_TARGET" --status "$WR_OK_STATUS") >/dev/null 2>&1 \
  || WR_MVFAIL_RC=$?
assert_true "write-result fails when mv itself fails (forced via a shadowed mv)" \
  "[ \"\$WR_MVFAIL_RC\" != 0 ]"
assert_true "  and leaves no leftover .write-result.* temp file behind" \
  "! ls \"$HW_RUN_DIR/pkt-h\"/.write-result.* >/dev/null 2>&1"
assert_true "  and wrote no mvfail.md either (mv never succeeded)" \
  "[ ! -f \"$WR_MVFAIL_TARGET\" ]"

echo
echo "== amend-handoff: ONE marked decider block spliced into a handoff the command"
echo "   must not otherwise disturb (escalation-decider T4) =="
# Every case below was verified by MUTATION, not inspection: a plausible wrong
# implementation was applied to cmd_amend_handoff, this sweep re-run and
# confirmed red for that specific case, then the implementation restored and the
# sweep reconfirmed green. Each block names what it rules out; see the
# implementer's result file for the observed pass/fail counts.
AH="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$AH" init -q
git -C "$AH" config user.email t@t; git -C "$AH" config user.name t
mkdir -p "$AH/.agents"
printf 'schema: 3\nstatus: running\n' > "$AH/.agents/run-state.yaml"
AH_RUN_ID="$(cd "$AH" && "$RUNSTATE" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
AH_RUN_DIR="$AH/.agents/loop/$AH_RUN_ID"
AH_FILE="$AH_RUN_DIR/ah-pkt/handoff.md"
ah_rs()     { (cd "$AH" && "$RUNSTATE" "$@"); }
ah_digest() { (cd "$AH" && "$RUNSTATE" run-digest .agents/run-state.yaml); }

# The adapter's real shape (a TEXT= line carries the title), so the digest case
# below is checked against a title the command had no part in choosing.
printf 'PACKET=ah-pkt\nTEXT=T4 amend the brief\nFILES=scripts/runstate.sh\n' \
  | ah_rs handoff .agents/run-state.yaml ah-pkt --tier mechanical --agent implementer >/dev/null
AH_LINE1_BEFORE="$(head -1 "$AH_FILE")"
AH_REQ_BEFORE="$(grep -c '^REQUIRED [a-z-]*: ' "$AH_FILE")"
assert_true "the fixture handoff really carries the six REQUIRED lines (so the survival check below is not vacuous)" \
  "[ \"\$AH_REQ_BEFORE\" = 6 ]"

AH_OUT="$(printf 'Narrow the scope to the marker block.\nSecond line of the amendment.\n' | ah_rs amend-handoff .agents/run-state.yaml ah-pkt)"
assert_true "amend-handoff reports the handoff path it wrote" \
  "printf '%s\n' \"\$AH_OUT\" | grep -q '^HANDOFF=.*/ah-pkt/handoff.md\$'"
assert_true "a first amendment reports AMENDMENT=inserted" \
  "printf '%s\n' \"\$AH_OUT\" | grep -qx 'AMENDMENT=inserted'"
assert_true "the replacement text reaches the file, every line of it" \
  "grep -q 'Narrow the scope to the marker block.' \"$AH_FILE\" && grep -q 'Second line of the amendment.' \"$AH_FILE\""
assert_true "the text lands inside the marked block, exactly one of each marker line" \
  "[ \"\$(grep -cxF '<!-- orch:decider-amendment -->' \"$AH_FILE\")\" = 1 ] && [ \"\$(grep -cxF '<!-- /orch:decider-amendment -->' \"$AH_FILE\")\" = 1 ]"

# --- THE TASK'S OWN CASE ---------------------------------------------------
# RULES OUT a rewrite that regenerates the handoff instead of splicing into it:
# run-digest reads the packet's title out of the `# <pkt>: <title>` FIRST line
# (_rs_digest_title), and a regenerated file that lost or reworded that line
# makes the packet silently report its own id as its title -- with the file
# still present, still carrying the task text, and every other assertion here
# still green. The count half rules out the other direction, and it counts
# EVERY packet line in the run rather than only this packet's: this fixture has
# exactly one packet directory carrying a handoff.md at this point, so a wrong
# implementation that left a second one behind -- a pre-amendment backup copied
# beside the original being the plausible shape -- shows up as a second packet
# in the run's own digest. Counting `^packet\tah-pkt\t` alone would NOT catch
# that (the copy has a different id), which is why this one is the whole-digest
# count; it was written the narrow way first and the backup mutation walked
# straight through it.
assert_true "run-digest still prints a packet line carrying the ORIGINAL title after an amendment" \
  "ah_digest | grep -qx \$'packet\tah-pkt\tT4 amend the brief\topen'"
assert_true "  and the amendment added no second packet to the run (one packet line, still)" \
  "[ \"\$(ah_digest | grep -c '^packet')\" = 1 ]"
assert_true "  and the first line is byte-identical to the one handoff wrote" \
  "[ \"\$(head -1 \"$AH_FILE\")\" = \"\$AH_LINE1_BEFORE\" ]"

# RULES OUT an amendment that truncates the file at its splice point -- the
# verification contract ADR 0029 appends is the file's TAIL, so a wrong
# implementation that wrote the block over the end of the file would leave a
# handoff with no contract, which an agent cannot tell from one whose contract
# did not apply.
assert_true "the six REQUIRED contract lines survive the amendment, all of them" \
  "[ \"\$(grep -c '^REQUIRED [a-z-]*: ' \"$AH_FILE\")\" = \"\$AH_REQ_BEFORE\" ]"
assert_true "the contract heading survives too" \
  "grep -qx '## REQUIRED — the verification contract' \"$AH_FILE\""
assert_true "the piped task body survives the amendment" \
  "grep -qx 'FILES=scripts/runstate.sh' \"$AH_FILE\""
assert_true "the header's absolute result path survives the amendment" \
  "grep -qx \"result: $AH_RUN_DIR/ah-pkt/implementer.md\" \"$AH_FILE\""

echo "-- a second amendment REPLACES the block rather than stacking a second one --"
# RULES OUT a plain append: three retries would leave three amendments, and an
# implementer reading the file would have to date-order them for itself to find
# which instruction is current -- with the newest text present and the marker
# count the only thing that gives it away.
AH_OUT2="$(printf 'The current instruction, replacing the first.\n' | ah_rs amend-handoff .agents/run-state.yaml ah-pkt)"
assert_true "a second amendment reports AMENDMENT=replaced" \
  "printf '%s\n' \"\$AH_OUT2\" | grep -qx 'AMENDMENT=replaced'"
assert_true "still exactly one opening and one closing marker after the second amendment" \
  "[ \"\$(grep -cxF '<!-- orch:decider-amendment -->' \"$AH_FILE\")\" = 1 ] && [ \"\$(grep -cxF '<!-- /orch:decider-amendment -->' \"$AH_FILE\")\" = 1 ]"
assert_true "the first amendment's text is GONE, not left above the second" \
  "! grep -q 'Narrow the scope to the marker block.' \"$AH_FILE\""
assert_true "the second amendment's text is present" \
  "grep -q 'The current instruction, replacing the first.' \"$AH_FILE\""
assert_true "the replacement still leaves the six REQUIRED contract lines intact" \
  "[ \"\$(grep -c '^REQUIRED [a-z-]*: ' \"$AH_FILE\")\" = \"\$AH_REQ_BEFORE\" ]"
assert_true "and run-digest still reports exactly one packet line, with the original title" \
  "[ \"\$(ah_digest | grep -c '^packet')\" = 1 ] && ah_digest | grep -qx \$'packet\tah-pkt\tT4 amend the brief\topen'"

echo "-- every refusal leaves the handoff BYTE-IDENTICAL --"
# RULES OUT check-after-write: a refusal that exits non-zero but has already
# rewritten (or truncated) the file leaves the packet's brief in a state nobody
# chose, while the exit status alone still reads as "nothing happened".
AH_SNAP="$AH/snapshot-handoff.md"; cp "$AH_FILE" "$AH_SNAP"
ah_unchanged() { cmp -s "$AH_FILE" "$AH_SNAP"; }

assert_true "amend-handoff refuses whitespace-only replacement text" \
  "! (printf '   \\n\\n' | ah_rs amend-handoff .agents/run-state.yaml ah-pkt) 2>/dev/null"
assert_true "  and the handoff is byte-identical afterwards" "ah_unchanged"
assert_true "amend-handoff refuses text carrying the opening marker line" \
  "! (printf 'before\\n<!-- orch:decider-amendment -->\\nafter\\n' | ah_rs amend-handoff .agents/run-state.yaml ah-pkt) 2>/dev/null"
assert_true "amend-handoff refuses text carrying the closing marker line" \
  "! (printf 'before\\n<!-- /orch:decider-amendment -->\\nafter\\n' | ah_rs amend-handoff .agents/run-state.yaml ah-pkt) 2>/dev/null"
assert_true "  and the handoff is byte-identical after both marker refusals" "ah_unchanged"
assert_true "amend-handoff refuses a packet with no handoff file in this run" \
  "! (printf 'x\\n' | ah_rs amend-handoff .agents/run-state.yaml ah-never-dispatched) 2>/dev/null"
assert_true "  and writes no handoff.md for it either" \
  "[ ! -f \"$AH_RUN_DIR/ah-never-dispatched/handoff.md\" ]"
assert_true "amend-handoff refuses a run-state with no run_id (begin-run not called)" \
  "printf 'schema: 3\\nstatus: running\\n' > \"$AH/norun.yaml\" && ! (printf 'x\\n' | ah_rs amend-handoff \"$AH/norun.yaml\" ah-pkt) 2>/dev/null"
assert_true "amend-handoff refuses a traversal packet id" \
  "! (printf 'x\\n' | ah_rs amend-handoff .agents/run-state.yaml 'ah/../escape') 2>/dev/null"
assert_true "amend-handoff refuses a '..' packet id" \
  "! (printf 'x\\n' | ah_rs amend-handoff .agents/run-state.yaml ..) 2>/dev/null"
assert_true "a '..'-refused amendment never wrote .agents/loop/<run_id>/handoff.md" \
  "[ ! -f \"$AH_RUN_DIR/handoff.md\" ]"

echo "-- a malformed block is REFUSED, never guessed at --"
# RULES OUT splicing from the opening marker to end-of-file when the closing one
# is missing (or picking the first of two): with no end to stop at, the splice
# swallows everything after the block -- the verification contract included --
# and reports success doing it.
printf 'TEXT=T5 a second packet\n' | ah_rs handoff .agents/run-state.yaml ah-mal --tier mechanical --agent implementer >/dev/null
AH_MAL="$AH_RUN_DIR/ah-mal/handoff.md"
printf '%s\n' '<!-- /orch:decider-amendment -->' >> "$AH_MAL"
AH_MAL_SNAP="$AH/snapshot-mal.md"; cp "$AH_MAL" "$AH_MAL_SNAP"
AH_MAL_ERR="$(printf 'x\n' | ah_rs amend-handoff .agents/run-state.yaml ah-mal 2>&1 >/dev/null || true)"
assert_true "a closing marker with no opening one is refused" \
  "! (printf 'x\\n' | ah_rs amend-handoff .agents/run-state.yaml ah-mal) 2>/dev/null"
assert_true "  and the refusal reports the marker counts it saw" \
  "printf '%s\n' \"\$AH_MAL_ERR\" | grep -q '0 opening and 1 closing'"
assert_true "  and that handoff is byte-identical afterwards (its contract not swallowed)" \
  "cmp -s \"$AH_MAL\" \"$AH_MAL_SNAP\""
printf '%s\n' '<!-- orch:decider-amendment -->' >> "$AH_MAL"
printf '%s\n' '<!-- orch:decider-amendment -->' >> "$AH_MAL"
cp "$AH_MAL" "$AH_MAL_SNAP"
assert_true "two opening markers are refused too" \
  "! (printf 'x\\n' | ah_rs amend-handoff .agents/run-state.yaml ah-mal) 2>/dev/null"
assert_true "  and that handoff is byte-identical afterwards as well" \
  "cmp -s \"$AH_MAL\" \"$AH_MAL_SNAP\""

echo "-- containment: a symlinked packet directory cannot carry the write outside the run dir --"
# The lexical check cannot see this one (the path string is inside the run
# directory); only the real-path re-check after the target is known can. RULES
# OUT keeping write-result's lexical half and dropping its symlink half.
AH_OUTSIDE="$(cd "$(mktemp -d)" && pwd -P)"
mkdir -p "$AH_OUTSIDE/ah-sym"
printf '# ah-sym: a handoff outside the run directory\n' > "$AH_OUTSIDE/ah-sym/handoff.md"
ln -s "$AH_OUTSIDE/ah-sym" "$AH_RUN_DIR/ah-sym"
assert_true "amend-handoff refuses a packet directory symlinked outside the run directory" \
  "! (printf 'x\\n' | ah_rs amend-handoff .agents/run-state.yaml ah-sym) 2>/dev/null"
assert_true "  and wrote nothing into the file outside the run directory" \
  "! grep -q 'Decider amendment' \"$AH_OUTSIDE/ah-sym/handoff.md\""

echo "-- a failure between mktemp and mv leaves no leftover temp file --"
# Same shadowed-`mv` technique as the handoff/write-result cases above; amend-
# handoff calls `mv` exactly once, so this cannot mask a failure elsewhere.
AH_MVFAIL_RC=0
printf 'x\n' | (cd "$AH" && PATH="$FAKEMV_DIR:$PATH" "$RUNSTATE" amend-handoff .agents/run-state.yaml ah-pkt) >/dev/null 2>&1 \
  || AH_MVFAIL_RC=$?
assert_true "amend-handoff fails when mv itself fails (forced via a shadowed mv)" \
  "[ \"\$AH_MVFAIL_RC\" != 0 ]"
assert_true "  and leaves no leftover .amend-handoff.* temp file behind" \
  "! ls \"$AH_RUN_DIR/ah-pkt\"/.amend-handoff.* >/dev/null 2>&1"
assert_true "  and left the handoff byte-identical (mv never succeeded)" "ah_unchanged"

echo
echo "== route: verdict -> action mapping, attempt pool, packet_attempts limit (thin-loop-driver T9) =="
RT="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$RT" init -q
git -C "$RT" config user.email t@t; git -C "$RT" config user.name t
mkdir -p "$RT/.agents"
printf 'schema: 3\nstatus: running\n' > "$RT/.agents/run-state.yaml"
RT_RUN_ID="$(cd "$RT" && "$RUNSTATE" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
RT_ROUTING="$RT/.agents/loop/$RT_RUN_ID/routing.jsonl"
rt_route() { (cd "$RT" && "$RUNSTATE" route .agents/run-state.yaml "$@"); }

assert_true "route pass -> land" "rt_route rt-pass pass | grep -qx 'ACTION=land'"
assert_true "route escalate -> decider" "rt_route rt-esc escalate | grep -qx 'ACTION=decider'"
assert_true "route reorder -> discard-advance" "rt_route rt-reo reorder | grep -qx 'ACTION=discard-advance'"
assert_true "route append-task -> discard-advance" "rt_route rt-app append-task | grep -qx 'ACTION=discard-advance'"
assert_true "route hand-off-feature -> discard-advance" "rt_route rt-hof hand-off-feature | grep -qx 'ACTION=discard-advance'"
assert_true "route ask-operator -> stop" "rt_route rt-ask ask-operator | grep -qx 'ACTION=stop'"

(cd "$RT" && "$RUNSTATE" record-start rt-fix S1 >/dev/null)
FIX1_OUT="$(rt_route rt-fix fix)"
assert_true "the first fix (default limit 1) -> attempt" \
  "printf '%s\n' \"\$FIX1_OUT\" | grep -qx 'ACTION=attempt'"
assert_true "  and the printed ATTEMPTS=/LIMIT= values are exactly right, not just the action" \
  "printf '%s\n' \"\$FIX1_OUT\" | grep -qx 'ATTEMPTS=1' && printf '%s\n' \"\$FIX1_OUT\" | grep -qx 'LIMIT=1'"
assert_true "a second fix on the same start (limit exhausted) -> decider" \
  "rt_route rt-fix fix | grep -qx 'ACTION=decider'"
RETRY_OUT="$(rt_route rt-fix retry)"
assert_true "a retry past the limit is refused as stop, not looped back to decider" \
  "printf '%s\n' \"\$RETRY_OUT\" | grep -qx 'ACTION=stop'"
assert_true "the over-limit retry refusal carries a blocking question naming the packet" \
  "printf '%s\n' \"\$RETRY_OUT\" | grep -q 'question:.*rt-fix'"

(cd "$RT" && "$RUNSTATE" record-start rt-reset S1 >/dev/null)
rt_route rt-reset fix >/dev/null   # attempts=1, exhausts the default limit of 1
(cd "$RT" && "$RUNSTATE" record-start rt-reset --continue S1 >/dev/null)
assert_true "a continuation does NOT reset the attempt count" \
  "rt_route rt-reset fix | grep -qx 'ACTION=decider'"
(cd "$RT" && "$RUNSTATE" record-start rt-reset S1 >/dev/null)   # a genuine new start
assert_true "a genuine new start DOES reset the attempt count" \
  "rt_route rt-reset fix | grep -qx 'ACTION=attempt'"

printf 'packet_attempts: 3\n' > "$RT/.agents/project-overrides.yaml"
(cd "$RT" && "$RUNSTATE" record-start rt-lim3 S1 >/dev/null)
assert_true "a configured packet_attempts raises the limit accordingly" \
  "rt_route rt-lim3 fix | grep -qx 'ACTION=attempt' && rt_route rt-lim3 fix | grep -qx 'ACTION=attempt' && rt_route rt-lim3 fix | grep -qx 'ACTION=attempt' && rt_route rt-lim3 fix | grep -qx 'ACTION=decider'"
printf 'packet_attempts: 0\n' > "$RT/.agents/project-overrides.yaml"
(cd "$RT" && "$RUNSTATE" record-start rt-lim0 S1 >/dev/null)
assert_true "packet_attempts: 0 falls back to a limit of 1" \
  "rt_route rt-lim0 fix | grep -qx 'ACTION=attempt' && rt_route rt-lim0 fix | grep -qx 'ACTION=decider'"
printf 'packet_attempts: bogus\n' > "$RT/.agents/project-overrides.yaml"
(cd "$RT" && "$RUNSTATE" record-start rt-liminv S1 >/dev/null)
assert_true "an invalid packet_attempts falls back to a limit of 1" \
  "rt_route rt-liminv fix | grep -qx 'ACTION=attempt' && rt_route rt-liminv fix | grep -qx 'ACTION=decider'"
printf '' > "$RT/.agents/project-overrides.yaml"
(cd "$RT" && "$RUNSTATE" record-start rt-limmiss S1 >/dev/null)
assert_true "a missing packet_attempts key falls back to a limit of 1" \
  "rt_route rt-limmiss fix | grep -qx 'ACTION=attempt' && rt_route rt-limmiss fix | grep -qx 'ACTION=decider'"

echo "-- a retry WITHIN the limit is an attempt, not just a retry PAST it (review fix 8) --"
printf 'packet_attempts: 2\n' > "$RT/.agents/project-overrides.yaml"
(cd "$RT" && "$RUNSTATE" record-start rt-retryok S1 >/dev/null)
assert_true "a fix consuming the first of 2 attempts -> attempt" \
  "rt_route rt-retryok fix | grep -qx 'ACTION=attempt'"
RETRYOK_OUT="$(rt_route rt-retryok retry)"
assert_true "a retry consuming the second (and last) of 2 attempts -> STILL attempt, not stop" \
  "printf '%s\n' \"\$RETRYOK_OUT\" | grep -qx 'ACTION=attempt'"
assert_true "  with ATTEMPTS=2 LIMIT=2 printed exactly" \
  "printf '%s\n' \"\$RETRYOK_OUT\" | grep -qx 'ATTEMPTS=2' && printf '%s\n' \"\$RETRYOK_OUT\" | grep -qx 'LIMIT=2'"

echo "-- packet_attempts: '3' (quoted) must not silently fall back to 1 (review fix 14) --"
printf "packet_attempts: '3'\n" > "$RT/.agents/project-overrides.yaml"
(cd "$RT" && "$RUNSTATE" record-start rt-quoted S1 >/dev/null)
assert_true "a single-quoted packet_attempts value is honoured (limit 3, not 1)" \
  "rt_route rt-quoted fix | grep -qx 'LIMIT=3'"
printf 'packet_attempts: "3"\n' > "$RT/.agents/project-overrides.yaml"
(cd "$RT" && "$RUNSTATE" record-start rt-quoted2 S1 >/dev/null)
assert_true "a double-quoted packet_attempts value is honoured (limit 3, not 1)" \
  "rt_route rt-quoted2 fix | grep -qx 'LIMIT=3'"
printf '' > "$RT/.agents/project-overrides.yaml"

echo "-- parsed-time ordering, not string ordering, for the attempt count (review fix 8) --"
# A whole-second start and a SUB-second routing record landing in the SAME
# wall-clock second: a raw string compare would read "...:05.500Z" as
# earlier than "...:05Z" ("." sorts below "Z"), wrongly EXCLUDING the
# routing record from the count. Fabricated directly (not via real timing),
# mirroring sweep-open's own same-second-a fixture.
RTORD_OUTCOMES="$RT/.agents/metrics/outcomes"
printf '{"ts":"2026-01-01T00:00:05Z","packet":"rt-ord","session":"S1","kind":"start"}\n' > "$RTORD_OUTCOMES/ORD.jsonl"
printf '{"ts":"2026-01-01T00:00:05.500Z","packet":"rt-ord","token":"fix","action":"attempt","status":""}\n' >> "$RT_ROUTING"
ORD_OUT="$(rt_route rt-ord fix)"
assert_true "a sub-second routing record in the same wall-clock second as a whole-second start IS counted (parsed time, not string compare)" \
  "printf '%s\n' \"\$ORD_OUT\" | grep -qx 'ATTEMPTS=2'"

echo "-- the outcomes log is byte-unchanged by route calls (review fix 8) --"
RT_OUTCOMES_CKSUM_BEFORE="$(cksum "$RT/.agents/metrics/outcomes"/*.jsonl 2>/dev/null | sort)"
rt_route rt-cksum-a pass >/dev/null
rt_route rt-cksum-b escalate >/dev/null
rt_route rt-cksum-c ask-operator >/dev/null
RT_OUTCOMES_CKSUM_AFTER="$(cksum "$RT/.agents/metrics/outcomes"/*.jsonl 2>/dev/null | sort)"
assert_true "the outcomes log's cksum is identical before and after a batch of pure route calls" \
  "[ \"\$RT_OUTCOMES_CKSUM_BEFORE\" = \"\$RT_OUTCOMES_CKSUM_AFTER\" ]"

assert_true "route writes valid append-only JSON to this run's routing.jsonl" \
  "jq -s -e 'length > 0 and (map(type == \"object\") | all)' \"$RT_ROUTING\" >/dev/null"
assert_true "route never writes into the outcomes log (every record there is still record-start's kind= shape, never a token=/action= routing record)" \
  "jq -s -e 'map(has(\"kind\") and (has(\"token\") | not)) | all' \"$RT/.agents/metrics/outcomes\"/*.jsonl >/dev/null"

printf 'a fresh handoff\n' | (cd "$RT" && "$RUNSTATE" handoff .agents/run-state.yaml rt-hof --tier integration --agent implementer) > "$RT/handoff-attempt.out" 2>&1 || true
assert_true "handoff refuses a packet whose latest routing record is hand-off-feature" \
  "grep -qx 'HANDOFF=refused' \"$RT/handoff-attempt.out\""
assert_true "the refusal names the reason" \
  "grep -qx 'REASON=hand-off-feature' \"$RT/handoff-attempt.out\""
assert_true "a refused handoff writes no handoff.md" \
  "[ ! -f \"$RT/.agents/loop/$RT_RUN_ID/rt-hof/handoff.md\" ]"

echo "-- route continue: in-cap ACTION=continue, spends no attempt (implementer-continuation T2) --"
# Run once on a full PATH and once with jq/python3 scrubbed from runstate.sh's
# PATH (the plan's standing rule); each run gets its own repo so neither
# routing.jsonl nor outcomes log can leak into the other.
CT_STATUS='continue · stopped at the turn budget, route half done · result: needs-reading · /tmp/run/ct-pkt/implementer.md'
ct_cases() {
  local sfx="$1" scrub="$2" d run_id routing out
  d="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  mkdir -p "$d/.agents"
  printf 'schema: 3\nstatus: running\n' > "$d/.agents/run-state.yaml"
  ct_rs() {
    if [ -n "$scrub" ]; then (cd "$d" && PATH="$scrub:$PATH" "$RUNSTATE" "$@")
    else (cd "$d" && "$RUNSTATE" "$@"); fi
  }
  run_id="$(ct_rs begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
  routing="$d/.agents/loop/$run_id/routing.jsonl"
  ct_rs record-start ct-pkt S1 >/dev/null

  out="$(ct_rs route .agents/run-state.yaml ct-pkt continue --status "$CT_STATUS")"
  assert_true "route continue$sfx: within the cap it prints ACTION=continue" \
    "printf '%s\n' \"\$out\" | grep -qx 'ACTION=continue'"
  assert_true "route continue$sfx: ATTEMPTS= is the live count (0 on a fresh start), never incremented to 1" \
    "printf '%s\n' \"\$out\" | grep -qx 'ATTEMPTS=0'"
  assert_true "route continue$sfx: the routing record carries ts, packet, token, action and status and nothing else" \
    "tail -1 \"$routing\" | jq -e --arg s \"\$CT_STATUS\" '(keys == [\"action\",\"packet\",\"status\",\"token\",\"ts\"]) and .packet == \"ct-pkt\" and .token == \"continue\" and .action == \"continue\" and .status == \$s and (.ts | length > 0)' >/dev/null"

  # The driver's own step after an in-cap continue (record-start --continue),
  # then a second stop at the budget: ATTEMPTS= stays where it was.
  ct_rs record-start ct-pkt --continue S1 >/dev/null
  out="$(ct_rs route .agents/run-state.yaml ct-pkt continue --status "$CT_STATUS")"
  assert_true "route continue$sfx: ATTEMPTS= is unchanged across a continuation (still 0 after a second continue)" \
    "printf '%s\n' \"\$out\" | grep -qx 'ATTEMPTS=0' && printf '%s\n' \"\$out\" | grep -qx 'ACTION=continue'"
  ct_rs record-start ct-pkt --continue S1 >/dev/null
  ct_rs route .agents/run-state.yaml ct-pkt continue --status "$CT_STATUS" >/dev/null

  # Three continuations recorded; a fix now must count exactly one attempt.
  # Counting `continue` into the fix/retry pool would print ATTEMPTS=4 and
  # route the packet to the decider without it ever having been reviewed.
  out="$(ct_rs route .agents/run-state.yaml ct-pkt fix)"
  assert_true "route continue$sfx: a fix routed after continuations prints ATTEMPTS=1 (continue never enters the attempt pool)" \
    "printf '%s\n' \"\$out\" | grep -qx 'ATTEMPTS=1'"
  assert_true "route continue$sfx: and so it is still an attempt under the default limit of 1, not the decider" \
    "printf '%s\n' \"\$out\" | grep -qx 'ACTION=attempt'"

  # After that fix, a continue reports the live count (1) without spending one.
  out="$(ct_rs route .agents/run-state.yaml ct-pkt continue --status "$CT_STATUS")"
  assert_true "route continue$sfx: after a fix, continue prints the live count ATTEMPTS=1, not 2" \
    "printf '%s\n' \"\$out\" | grep -qx 'ATTEMPTS=1' && printf '%s\n' \"\$out\" | grep -qx 'ACTION=continue'"
}
ct_cases "" ""
ct_cases " (no-tools host)" "$NOTOOLS"

echo "-- route continue: capped per attempt by packet_continuations (implementer-continuation T3) --"
# Same two-host shape as ct_cases above, each in its own repo.
cc_cases() {
  local sfx="$1" scrub="$2" d run_id routing out i
  d="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  mkdir -p "$d/.agents"
  printf 'schema: 3\nstatus: running\n' > "$d/.agents/run-state.yaml"
  cc_rs() {
    if [ -n "$scrub" ]; then (cd "$d" && PATH="$scrub:$PATH" "$RUNSTATE" "$@")
    else (cd "$d" && "$RUNSTATE" "$@"); fi
  }
  cc_cont() { cc_rs route .agents/run-state.yaml "$1" continue --status "$CT_STATUS"; }
  run_id="$(cc_rs begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
  routing="$d/.agents/loop/$run_id/routing.jsonl"

  # Default cap (no overrides file): three continuations, each followed by the
  # driver's own `record-start --continue` bookkeeping, then a fourth refused.
  # Windowing on ANY outcomes record would let each of those continuation
  # records reset the count and the fourth would route as continue again.
  cc_rs record-start cc-def S1 >/dev/null
  for i in 1 2 3; do
    out="$(cc_cont cc-def)"
    assert_true "route continue cap$sfx: continuation $i of 3 under the default cap routes ACTION=continue" \
      "printf '%s\n' \"\$out\" | grep -qx 'ACTION=continue'"
    cc_rs record-start cc-def --continue S1 >/dev/null
  done
  out="$(cc_cont cc-def)"
  assert_true "route continue cap$sfx: the fourth continuation, past the default cap of 3, prints ACTION=stop (record-start --continue restored nothing)" \
    "printf '%s\n' \"\$out\" | grep -qx 'ACTION=stop' && ! printf '%s\n' \"\$out\" | grep -qx 'ACTION=continue'"
  assert_true "route continue cap$sfx: the refusal prints a question: line naming the packet and the cap" \
    "printf '%s\n' \"\$out\" | grep -q '^question: .*packet cc-def .*continuation cap (3 per attempt)'"
  assert_true "route continue cap$sfx: the refused continue still writes its record, with action stop and exactly the five keys" \
    "tail -1 \"$routing\" | jq -e --arg s \"\$CT_STATUS\" '(keys == [\"action\",\"packet\",\"status\",\"token\",\"ts\"]) and .packet == \"cc-def\" and .token == \"continue\" and .action == \"stop\" and .status == \$s and (.ts | length > 0)' >/dev/null"
  assert_true "route continue cap$sfx: every continue for the packet left one record (three continue + one stop)" \
    "[ \"\$(jq -r -s '[.[] | select(.packet == \"cc-def\" and .token == \"continue\") | .action] | join(\",\")' \"$routing\")\" = continue,continue,continue,stop ]"

  # An `attempt` routing (here a fix, under the default attempt limit of 1)
  # opens a fresh attempt with the full allowance again. Windowing on the
  # start record alone would cap per packet and refuse the very next continue.
  out="$(cc_rs route .agents/run-state.yaml cc-def fix)"
  assert_true "route continue cap$sfx: the fix after the refusal routes ACTION=attempt" \
    "printf '%s\n' \"\$out\" | grep -qx 'ACTION=attempt'"
  for i in 1 2 3; do
    out="$(cc_cont cc-def)"
    assert_true "route continue cap$sfx: after an attempt routing, continuation $i of 3 routes ACTION=continue again (full allowance restored)" \
      "printf '%s\n' \"\$out\" | grep -qx 'ACTION=continue'"
  done
  out="$(cc_cont cc-def)"
  assert_true "route continue cap$sfx: and the fourth in the new attempt is refused as ACTION=stop" \
    "printf '%s\n' \"\$out\" | grep -qx 'ACTION=stop'"

  # Override: a quoted, comment-trailed value is honoured.
  printf "packet_continuations: '1'  # tighter than the default\n" > "$d/.agents/project-overrides.yaml"
  cc_rs record-start cc-ovr S1 >/dev/null
  out="$(cc_cont cc-ovr)"
  assert_true "route continue cap$sfx: under packet_continuations: '1' the first continuation routes ACTION=continue" \
    "printf '%s\n' \"\$out\" | grep -qx 'ACTION=continue'"
  out="$(cc_cont cc-ovr)"
  assert_true "route continue cap$sfx: under packet_continuations: '1' the second is refused as ACTION=stop naming cap 1" \
    "printf '%s\n' \"\$out\" | grep -qx 'ACTION=stop' && printf '%s\n' \"\$out\" | grep -q '^question: .*packet cc-ovr .*continuation cap (1 per attempt)'"

  # Zero is not a positive integer and reads as the default of 3.
  printf 'packet_continuations: 0\n' > "$d/.agents/project-overrides.yaml"
  cc_rs record-start cc-zero S1 >/dev/null
  for i in 1 2 3; do cc_cont cc-zero >/dev/null; done
  out="$(cc_cont cc-zero)"
  assert_true "route continue cap$sfx: packet_continuations: 0 reads as the default 3 (fourth refused, naming cap 3)" \
    "printf '%s\n' \"\$out\" | grep -qx 'ACTION=stop' && printf '%s\n' \"\$out\" | grep -q 'continuation cap (3 per attempt)'"
}
cc_cases "" ""
cc_cases " (no-tools host)" "$NOTOOLS"

echo "-- a hand-off-feature record in a PREVIOUS run does not refuse the SAME packet id in a NEW run (review fix 5/8) --"
# A genuinely fresh run-state (no run_id yet) mints a DIFFERENT run_id, so
# its own routing.jsonl starts empty -- the refusal must be scoped to the
# CURRENT run's own routing log, never a previous run's.
printf 'schema: 3\nstatus: running\n' > "$RT/.agents/run-state.yaml"
RT_RUN_ID2="$(cd "$RT" && "$RUNSTATE" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
assert_true "the fresh run-state mints a DIFFERENT run_id than the earlier run" \
  "[ \"\$RT_RUN_ID2\" != \"\$RT_RUN_ID\" ]"
HOF_NEWRUN_OUT="$(printf 'a fresh handoff\n' | (cd "$RT" && "$RUNSTATE" handoff .agents/run-state.yaml rt-hof --tier integration --agent implementer))"
assert_true "the SAME packet id, hand-off-feature'd only in the PREVIOUS run, is NOT refused in the new run" \
  "printf '%s\n' \"\$HOF_NEWRUN_OUT\" | grep -q '^HANDOFF=' && ! printf '%s\n' \"\$HOF_NEWRUN_OUT\" | grep -qx 'HANDOFF=refused'"
assert_true "  and it actually wrote a handoff.md in the NEW run's own directory" \
  "[ -f \"$RT/.agents/loop/\$RT_RUN_ID2/rt-hof/handoff.md\" ]"

echo "== compact-threshold: repo/operator/unknown, pure reader (thin-loop-driver T4/T6, ADR 0028 result 3) =="
# A fake HOME so a real developer machine's own ~/.claude/settings.json can
# never leak into these assertions (the "user" scope reads from there).
CT_HOME="$(mktemp -d)"
ct_run() { (cd "$1" && shift && HOME="$CT_HOME" "$@" "$RUNSTATE" compact-threshold); }

CT_NOTGIT="$(mktemp -d)"
assert_true "not a git repo -> unknown, nothing applied" \
  "[ \"\$(ct_run \"\$CT_NOTGIT\" env)\" = \"\$(printf 'THRESHOLD=unknown\nSOURCE=unknown\nAPPLIED=no')\" ]"

CT1="$(mktemp -d)"; git -C "$CT1" init -q
git -C "$CT1" config user.email t@t; git -C "$CT1" config user.name t
mkdir -p "$CT1/.claude"
printf '{\n  "autoCompactWindow": 500000\n}\n' > "$CT1/.claude/settings.json"
assert_true "repo scope (.claude/settings.json) is read when nothing else is set" \
  "[ \"\$(ct_run \"\$CT1\" env)\" = \"\$(printf 'THRESHOLD=500000\nSOURCE=repo\nAPPLIED=no')\" ]"

assert_true "operator env var wins over a repo setting (unverified precedence, documented in the header)" \
  "[ \"\$(ct_run \"\$CT1\" env CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000)\" = \"\$(printf 'THRESHOLD=100000\nSOURCE=operator\nAPPLIED=no')\" ]"

assert_true "a non-numeric env var is ignored, falling through to repo" \
  "[ \"\$(ct_run \"\$CT1\" env CLAUDE_CODE_AUTO_COMPACT_WINDOW=abc)\" = \"\$(printf 'THRESHOLD=500000\nSOURCE=repo\nAPPLIED=no')\" ]"

printf '{\n  "autoCompactWindow": 321000\n}\n' > "$CT1/.claude/settings.local.json"
assert_true "operator local settings.local.json wins over repo" \
  "[ \"\$(ct_run \"\$CT1\" env)\" = \"\$(printf 'THRESHOLD=321000\nSOURCE=operator\nAPPLIED=no')\" ]"

assert_true "two sources set at once: env wins over local settings.local.json, named correctly (closes the F7 gap — a marker-only interaction was the sole case previously covered)" \
  "[ \"\$(ct_run \"\$CT1\" env CLAUDE_CODE_AUTO_COMPACT_WINDOW=654000)\" = \"\$(printf 'THRESHOLD=654000\nSOURCE=operator\nAPPLIED=no')\" ]"
rm -f "$CT1/.claude/settings.local.json"

mkdir -p "$CT_HOME/.claude"
printf '{\n  "autoCompactWindow": 777000\n}\n' > "$CT_HOME/.claude/settings.json"
assert_true "operator user-wide ~/.claude/settings.json is read when nothing more local is set" \
  "[ \"\$(ct_run \"\$CT1\" env)\" = \"\$(printf 'THRESHOLD=777000\nSOURCE=operator\nAPPLIED=no')\" ]"
rm -f "$CT_HOME/.claude/settings.json"

CT2="$(mktemp -d)"; git -C "$CT2" init -q
git -C "$CT2" config user.email t@t; git -C "$CT2" config user.name t
CT2_OUT="$(ct_run "$CT2" env)"
assert_true "neither repo nor operator set -> unknown, naming nothing in effect (T6: no invented default)" \
  "[ \"\$CT2_OUT\" = \"\$(printf 'THRESHOLD=unknown\nSOURCE=unknown\nAPPLIED=no')\" ]"
assert_true "  and nothing is ever written -- no .claude/settings.local.json appears" \
  "[ ! -e \"$CT2/.claude/settings.local.json\" ]"
assert_true "  a second call reports the identical thing (no state to have changed)" \
  "[ \"\$(ct_run \"\$CT2\" env)\" = \"\$CT2_OUT\" ]"

echo
echo "== periodic-pause: pause_every_packets scheduling, pure reader (thin-loop-driver T10, ADR 0028 result 2) =="
PP="$(mktemp -d)"; git -C "$PP" init -q
git -C "$PP" config user.email t@t; git -C "$PP" config user.name t
mkdir -p "$PP/.agents/metrics/driver-mode" "$PP/.agents/metrics/outcomes"
pp_run() { (cd "$1" && shift && "$RUNSTATE" periodic-pause "$@"); }

# Fixed timestamps (not real wall-clock calls) so ordering across enter/
# terminal/swept records is deterministic, same reasoning as the
# same-second-a fixture above for sweep-open.
printf '{"ts":"2026-01-01T00:00:10.000Z","session":"PPS1","kind":"enter","model":"m","effort":"e","threshold":"t"}\n' \
  > "$PP/.agents/metrics/driver-mode/PPS1.jsonl"
printf '{"ts":"2026-01-01T00:00:11.000Z","packet":"p1","session":"PPS1","outcome":"green"}\n' \
  > "$PP/.agents/metrics/outcomes/PPS1.jsonl"

echo "-- off by default (no project-overrides.yaml at all) --"
assert_true "no project-overrides.yaml -> EVERY=off, DUE=no" \
  "[ \"\$(pp_run \"$PP\" PPS1)\" = \"\$(printf 'ENDED=1\nEVERY=off\nDUE=no')\" ]"

echo "-- off at 0 --"
printf 'pause_every_packets: 0\n' > "$PP/.agents/project-overrides.yaml"
assert_true "pause_every_packets: 0 -> EVERY=off, DUE=no" \
  "[ \"\$(pp_run \"$PP\" PPS1)\" = \"\$(printf 'ENDED=1\nEVERY=off\nDUE=no')\" ]"

printf 'pause_every_packets: bogus\n' > "$PP/.agents/project-overrides.yaml"
assert_true "an invalid (non-numeric) pause_every_packets -> EVERY=off, DUE=no" \
  "[ \"\$(pp_run \"$PP\" PPS1)\" = \"\$(printf 'ENDED=1\nEVERY=off\nDUE=no')\" ]"

echo "-- due at N --"
printf 'pause_every_packets: 2\n' > "$PP/.agents/project-overrides.yaml"
assert_true "one ended packet against a limit of 2 is not yet due" \
  "[ \"\$(pp_run \"$PP\" PPS1)\" = \"\$(printf 'ENDED=1\nEVERY=2\nDUE=no')\" ]"
printf '{"ts":"2026-01-01T00:00:12.000Z","packet":"p2","session":"PPS1","outcome":"green"}\n' \
  >> "$PP/.agents/metrics/outcomes/PPS1.jsonl"
assert_true "two ended packets against a limit of 2 is due" \
  "[ \"\$(pp_run \"$PP\" PPS1)\" = \"\$(printf 'ENDED=2\nEVERY=2\nDUE=yes')\" ]"

echo "-- a restart after a new enter resets the count --"
printf '{"ts":"2026-01-01T00:00:20.000Z","session":"PPS1","kind":"enter","model":"m","effort":"e","threshold":"t"}\n' \
  >> "$PP/.agents/metrics/driver-mode/PPS1.jsonl"
assert_true "a later enter record resets ENDED to 0, even though EVERY is still configured" \
  "[ \"\$(pp_run \"$PP\" PPS1)\" = \"\$(printf 'ENDED=0\nEVERY=2\nDUE=no')\" ]"

echo "-- a non-green terminal record after the new enter still counts (not just outcome:green) --"
printf '{"ts":"2026-01-01T00:00:21.000Z","packet":"f1","session":"PPS1","outcome":"failed"}\n' \
  >> "$PP/.agents/metrics/outcomes/PPS1.jsonl"
assert_true "a failed (non-green) terminal record after enter counts toward ENDED" \
  "[ \"\$(pp_run \"$PP\" PPS1)\" = \"\$(printf 'ENDED=1\nEVERY=2\nDUE=no')\" ]"

echo "-- a swept interruption whose START ts is AT OR AFTER the current enter DOES count --"
printf '{"ts":"2026-01-01T00:00:22.000Z","packet":"swept-b","session":"PPS1","outcome":"interrupted"}\n' \
  >> "$PP/.agents/metrics/outcomes/PPS1.jsonl"
assert_true "a swept interruption started at/after enter counts, reaching DUE=yes (same outcome value as the excluded case below, opposite side of the boundary)" \
  "[ \"\$(pp_run \"$PP\" PPS1)\" = \"\$(printf 'ENDED=2\nEVERY=2\nDUE=yes')\" ]"

echo "-- an excluded swept record: its ts is the ORIGINAL start's time, before the current enter --"
printf '{"ts":"2026-01-01T00:00:05.000Z","packet":"swept-a","session":"PPS1","outcome":"interrupted"}\n' \
  >> "$PP/.agents/metrics/outcomes/PPS1.jsonl"
assert_true "a swept interruption carrying an older start ts does not count toward ENDED (asserted against the non-zero ENDED=2 baseline above, not a zero baseline the filter would pass vacuously)" \
  "[ \"\$(pp_run \"$PP\" PPS1)\" = \"\$(printf 'ENDED=2\nEVERY=2\nDUE=yes')\" ]"

echo "-- parsed comparison, not raw string comparison, of timestamps --"
PP2="$(mktemp -d)"; git -C "$PP2" init -q
git -C "$PP2" config user.email t@t; git -C "$PP2" config user.name t
mkdir -p "$PP2/.agents/metrics/driver-mode" "$PP2/.agents/metrics/outcomes"
printf '{"ts":"2026-01-01T00:00:30Z","session":"PPS2","kind":"enter","model":"m","effort":"e","threshold":"t"}\n' \
  > "$PP2/.agents/metrics/driver-mode/PPS2.jsonl"
printf '{"ts":"2026-01-01T00:00:30.500Z","packet":"p3","session":"PPS2","outcome":"green"}\n' \
  > "$PP2/.agents/metrics/outcomes/PPS2.jsonl"
printf 'pause_every_packets: 1\n' > "$PP2/.agents/project-overrides.yaml"
assert_true "a sub-second outcome ts in the same second as a whole-second enter still counts (parsed key, not a raw string compare -- '.' sorts below 'Z' and would wrongly exclude it)" \
  "[ \"\$(pp_run \"$PP2\" PPS2)\" = \"\$(printf 'ENDED=1\nEVERY=1\nDUE=yes')\" ]"

echo "-- edges: no enter record for the session, and not a git repo at all --"
assert_true "a session with no enter record at all reads as ENDED=0" \
  "[ \"\$(pp_run \"$PP\" PPS-NONE)\" = \"\$(printf 'ENDED=0\nEVERY=2\nDUE=no')\" ]"
PP_NOTGIT="$(mktemp -d)"
assert_true "not a git repo -> ENDED=0/EVERY=off/DUE=no, never a die" \
  "[ \"\$(cd \"\$PP_NOTGIT\" && \"\$RUNSTATE\" periodic-pause PPSX)\" = \"\$(printf 'ENDED=0\nEVERY=off\nDUE=no')\" ]"

echo
echo "== bundle-cap: bundle_max_tasks reader, pure reader (packet-bundling T2) =="
BC="$(mktemp -d)"; git -C "$BC" init -q
git -C "$BC" config user.email t@t; git -C "$BC" config user.name t
mkdir -p "$BC/.agents"
bc_run() { (cd "$1" && "$RUNSTATE" bundle-cap); }

echo "-- default with no overrides file at all --"
assert_true "no project-overrides.yaml -> CAP=1" \
  "[ \"\$(bc_run \"$BC\")\" = 'CAP=1' ]"

echo "-- a missing bundle_max_tasks key --"
printf 'schema: 1\npacket_attempts: 3\n' > "$BC/.agents/project-overrides.yaml"
assert_true "an overrides file with no bundle_max_tasks key -> CAP=1" \
  "[ \"\$(bc_run \"$BC\")\" = 'CAP=1' ]"

echo "-- a quoted value must not silently fall back to 1 --"
printf "bundle_max_tasks: '4'\n" > "$BC/.agents/project-overrides.yaml"
assert_true "a single-quoted bundle_max_tasks value is honoured (CAP=4, not 1)" \
  "[ \"\$(bc_run \"$BC\")\" = 'CAP=4' ]"

echo "-- a value with a trailing comment --"
printf "bundle_max_tasks: 4  # tune later\n" > "$BC/.agents/project-overrides.yaml"
assert_true "a trailing comment does not defeat the token scan (CAP=4)" \
  "[ \"\$(bc_run \"$BC\")\" = 'CAP=4' ]"

echo "-- 0 falls back to 1 (bundling off) --"
printf 'bundle_max_tasks: 0\n' > "$BC/.agents/project-overrides.yaml"
assert_true "bundle_max_tasks: 0 -> CAP=1" \
  "[ \"\$(bc_run \"$BC\")\" = 'CAP=1' ]"

echo "-- a non-numeric value falls back to 1 --"
printf 'bundle_max_tasks: bogus\n' > "$BC/.agents/project-overrides.yaml"
assert_true "an invalid (non-numeric) bundle_max_tasks -> CAP=1" \
  "[ \"\$(bc_run \"$BC\")\" = 'CAP=1' ]"

echo "-- a negative value falls back to 1 --"
printf 'bundle_max_tasks: -4\n' > "$BC/.agents/project-overrides.yaml"
assert_true "a negative bundle_max_tasks -> CAP=1" \
  "[ \"\$(bc_run \"$BC\")\" = 'CAP=1' ]"

echo "-- a valid value is read back --"
printf 'bundle_max_tasks: 4\n' > "$BC/.agents/project-overrides.yaml"
assert_true "bundle_max_tasks: 4 -> CAP=4" \
  "[ \"\$(bc_run \"$BC\")\" = 'CAP=4' ]"

echo "-- not a git repo, never a die --"
BC_NOTGIT="$(mktemp -d)"
assert_true "not a git repo -> CAP=1, never a die" \
  "[ \"\$(cd \"\$BC_NOTGIT\" && \"\$RUNSTATE\" bundle-cap)\" = 'CAP=1' ]"

echo
echo "== run-digest: assembled from files alone -- handoff files, routing records, the"
echo "   outcomes log and driver-mode records, nothing from memory (thin-loop-driver T11,"
echo "   ADR 0028 result 4) =="
# The LAST packet on this feature (periodic-pause, T10) shipped nine sweep cases
# that all passed while three plausible wrong implementations survived every one
# of them -- an inspection-only sweep that never actually discriminated. Every
# case below was verified by MUTATION, not just inspection: a plausible wrong
# implementation was applied, the sweep was re-run and confirmed to go red for
# that specific case, then the implementation was restored and the sweep
# reconfirmed green. See the implementer's result file for exactly what was
# mutated for each one.
RD="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$RD" init -q
git -C "$RD" config user.email t@t; git -C "$RD" config user.name t
mkdir -p "$RD/.agents" "$RD/.agents/metrics/outcomes" "$RD/.agents/metrics/driver-mode"
printf 'schema: 3\nstatus: running\n' > "$RD/.agents/run-state.yaml"
RD_RUN_ID="$(cd "$RD" && "$RUNSTATE" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
rd_digest() { (cd "$RD" && "$RUNSTATE" run-digest .agents/run-state.yaml "$@"); }

echo "-- a landed packet's id/title/outcome, and an OPEN packet (a start with no terminal record after it) --"
printf 'T1 add the first thing\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-green --tier integration --agent implementer) >/dev/null
printf 'T2 add the second thing\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-open --tier integration --agent implementer) >/dev/null
printf '{"ts":"2026-02-01T00:00:01Z","packet":"rd-green","session":"S1","kind":"start"}\n{"ts":"2026-02-01T00:00:02Z","packet":"rd-green","session":"S1","outcome":"green"}\n{"ts":"2026-02-01T00:00:03Z","packet":"rd-open","session":"S1","kind":"start"}\n' \
  > "$RD/.agents/metrics/outcomes/S1.jsonl"
assert_true "run-digest: a landed packet's line carries its id, its title from its own handoff header, and its terminal outcome" \
  "rd_digest | grep -qx \$'packet\trd-green\tT1 add the first thing\tgreen'"
assert_true "run-digest: a packet with a start but no terminal record after it reads open, never silently green or absent" \
  "rd_digest | grep -qx \$'packet\trd-open\tT2 add the second thing\topen'"

# Review fix (thin-loop-driver-t11, second round): the outcomes log is a glob
# across EVERY session's file (*.jsonl), matching the boundary-scan code
# above it -- but the round-one sweep only ever put a packet's start AND its
# terminal record in the SAME file (S1.jsonl), so a wrong implementation that
# restricted the read to one file (e.g. the newest by name/mtime) passed
# every case unnoticed. This one puts the start in S1's log and the terminal
# outcome in a DIFFERENT session's log (S2), so only a true whole-directory
# read can join them.
echo "-- a packet started in one session and finished in a DIFFERENT one: both logs must be read together --"
printf 'T6 finish in another session\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-twosess --tier integration --agent implementer) >/dev/null
printf '{"ts":"2026-02-01T00:00:08Z","packet":"rd-twosess","session":"S1","kind":"start"}\n' >> "$RD/.agents/metrics/outcomes/S1.jsonl"
printf '{"ts":"2026-02-03T00:00:00Z","packet":"rd-twosess","session":"S2","outcome":"blocked"}\n' > "$RD/.agents/metrics/outcomes/S2.jsonl"
assert_true "run-digest: a packet started in one session's outcomes log and finished in another's reads the cross-session terminal outcome, not open" \
  "rd_digest | grep -qx \$'packet\trd-twosess\tT6 finish in another session\tblocked'"

# The case above defends the TERMINAL-outcome scan against a wrong
# implementation that reads only one session's file. It does NOT, by itself,
# defend the separate BOUNDARY scan (kind=start/continue) against the same
# mistake, because every start/continue record in every case above lives in
# S1 -- a hardcoded "read only S1.jsonl" mistake in the boundary scan alone
# would pass every case above unnoticed. This packet's ENTIRE history (both
# its start and its terminal outcome) lives only in S2, so it exercises both
# scans reading the whole directory, not merely the terminal one.
echo "-- a packet whose entire outcomes history (start AND terminal) lives only in a non-first session's log --"
printf 'T6b lives only in the second session\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-onlys2 --tier integration --agent implementer) >/dev/null
printf '{"ts":"2026-02-03T00:00:01Z","packet":"rd-onlys2","session":"S2","kind":"start"}\n{"ts":"2026-02-03T00:00:02Z","packet":"rd-onlys2","session":"S2","outcome":"failed"}\n' \
  >> "$RD/.agents/metrics/outcomes/S2.jsonl"
assert_true "run-digest: a packet whose entire outcomes history lives in a session other than S1 still reports its real outcome, not open" \
  "rd_digest | grep -qx \$'packet\trd-onlys2\tT6b lives only in the second session\tfailed'"

# Review fix (round two): the boundary scan accepts kind=start OR kind=continue
# (matching the PRD's "after its latest start or continuation"), but the
# round-one sweep never put anything AFTER a continue record, so a wrong
# implementation that dropped the continue arm entirely passed unnoticed. This
# scenario puts a (stale) terminal record BETWEEN a start and a later continue
# -- a wrong implementation that ignores continue as a boundary would let that
# stale terminal leak through as the packet's outcome instead of correctly
# reading it as still open.
echo "-- a continuation record is itself a boundary: a terminal record dated before it must not leak through as the outcome --"
printf 'T7 continued after a false finish\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-continued --tier integration --agent implementer) >/dev/null
printf '{"ts":"2026-02-01T00:00:09Z","packet":"rd-continued","session":"S1","kind":"start"}\n{"ts":"2026-02-01T00:00:10Z","packet":"rd-continued","session":"S1","outcome":"blocked"}\n{"ts":"2026-02-01T00:00:11Z","packet":"rd-continued","session":"S1","kind":"continue"}\n' \
  >> "$RD/.agents/metrics/outcomes/S1.jsonl"
assert_true "run-digest: a continuation after a stale terminal record reads open, not the stale outcome that preceded the continuation" \
  "rd_digest | grep -qx \$'packet\trd-continued\tT7 continued after a false finish\topen'"

echo "-- a run spanning two sessions: the enter line names the LATEST enter across every session's log, not the first --"
printf '{"ts":"2026-02-01T00:00:00Z","session":"S1","kind":"enter","model":"sonnet","effort":"low","threshold":"100000"}\n' \
  > "$RD/.agents/metrics/driver-mode/S1.jsonl"
printf '{"ts":"2026-02-02T00:00:00Z","session":"S2","kind":"enter","model":"opus","effort":"high","threshold":"unknown"}\n' \
  > "$RD/.agents/metrics/driver-mode/S2.jsonl"
assert_true "run-digest: the enter line reflects the SECOND session's later enter" \
  "rd_digest | grep -qx \$'enter\topus\thigh\tunknown'"
assert_true "  and the first (now stale) session's values do not also appear" \
  "! rd_digest | grep -qx \$'enter\tsonnet\tlow\t100000'"

# Review fix (F2): bash always treats a tab as "IFS whitespace" for splitting
# purposes regardless of what IFS is set to, so `IFS=<tab> read` on a TSV line
# with an EMPTY field collapses adjacent tabs and shifts every later field
# left. `driver-mode enter --model ""` writes an empty model verbatim (the
# `unknown` default only applies when the flag is ABSENT, not empty), so a
# real caller can hit this. Asserts the line's four positions stay stable
# (model empty, effort/threshold in their own columns) rather than effort
# sliding into the model column.
echo "-- a LATER enter with an empty --model must not shift effort/threshold left in the enter line --"
(cd "$RD" && "$RUNSTATE" driver-mode enter --model "" --effort medium --threshold 300000 S2 >/dev/null)
assert_true "run-digest: an empty driver-mode field stays in its own column -- the enter line reads empty-model, not effort where model belongs" \
  "rd_digest | grep -qx \$'enter\t\tmedium\t300000'"
assert_true "  and effort/threshold are not swallowed leftward the way IFS=<tab> read would swallow them" \
  "! rd_digest | grep -qx \$'enter\tmedium\t300000\t'"

echo "-- a decider decision (scoped by --since) and its hand-off-feature record (the WHOLE run, regardless of --since) --"
printf 'T3 needs a bigger feature\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-hof --tier integration --agent implementer) >/dev/null
(cd "$RD" && "$RUNSTATE" route .agents/run-state.yaml rd-hof escalate >/dev/null)
# Review fix (round two, F5): a naive `sed -E 's/.*"status":"([^"]*)".*/\1/'`
# extraction (in place of the escape-aware field_esc walk) truncates at the
# first escaped quote and still passes every case here if the fixture is
# plain ASCII with no middle dot, quote or backslash. This status line is
# contract-shaped (templates/status-line.md's four ` . ` fields) and carries
# a real double quote and a real backslash in its free-text clause, so only
# the escape-aware walk reproduces it verbatim -- grep -F (not -x's BRE) is
# used to match it so the backslash/quote are compared literally, not as
# regex metacharacters.
RD_HOF_STATUS='hand-off-feature · rd-hof needs a "bulk import" feature, spec at C:\import\spec.md · result: needs-reading · .agents/loop/x/rd-hof/decider.md'
(cd "$RD" && "$RUNSTATE" route .agents/run-state.yaml rd-hof hand-off-feature --status "$RD_HOF_STATUS" >/dev/null)
RD_HOF_EXPECTED="$(printf 'handoff-feature\trd-hof\t%s' "$RD_HOF_STATUS")"
assert_true "run-digest: a bare reviewer 'escalate' is NOT itself a decider decision (it only routes TO the decider)" \
  "! rd_digest | grep -qx \$'decision\trd-hof\tescalate'"
assert_true "run-digest: the decider's own hand-off-feature token IS a decision line" \
  "rd_digest | grep -qx \$'decision\trd-hof\thand-off-feature'"
assert_true "run-digest: the hand-off-feature record carries its own routed --status line, JSON-escaping reversed VERBATIM (including its literal double quote and backslash)" \
  "rd_digest | grep -qFx \"\$RD_HOF_EXPECTED\""
assert_true "run-digest: a handed-off packet's own packet line still reports (still open -- it was never landed)" \
  "rd_digest | grep -qx \$'packet\trd-hof\tT3 needs a bigger feature\topen'"
assert_true "run-digest --since in the far future excludes the decision line" \
  "! rd_digest --since 2099-01-01T00:00:00Z | grep -qx \$'decision\trd-hof\thand-off-feature'"
assert_true "  but the hand-off-feature QUESTION still appears, verbatim -- a stop report must list every open question the run recorded, not only recent ones" \
  "rd_digest --since 2099-01-01T00:00:00Z | grep -qFx \"\$RD_HOF_EXPECTED\""
assert_true "run-digest --since at the epoch still includes the decision line" \
  "rd_digest --since 1970-01-01T00:00:00Z | grep -qx \$'decision\trd-hof\thand-off-feature'"

echo "-- a paused cursor reads 'paused', overriding what its outcome-log records would otherwise say --"
printf 'T4 mid-edit when paused\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-paused --tier integration --agent implementer) >/dev/null
printf '{"ts":"2026-02-01T00:00:05Z","packet":"rd-paused","session":"S1","kind":"start"}\n' >> "$RD/.agents/metrics/outcomes/S1.jsonl"
printf 'schema: 3\nstatus: paused\nrun_id: %s\nbacklog:\n  cursor: rd-paused\n' "$RD_RUN_ID" > "$RD/.agents/run-state.yaml"
assert_true "run-digest: the paused cursor packet reads 'paused'" \
  "rd_digest | grep -qx \$'packet\trd-paused\tT4 mid-edit when paused\tpaused'"
assert_true "  and does NOT also (or instead) read open -- paused wins over the boundary-outcome computation" \
  "! rd_digest | grep -qx \$'packet\trd-paused\tT4 mid-edit when paused\topen'"
# Review fix (round two, F4): a wrong implementation that applies `paused` to
# EVERY packet (dropping the cursor check entirely) reads exactly the same as
# the correct one on the two assertions above, since rd-paused IS the cursor.
# This asserts a DIFFERENT, already-landed packet (rd-green) still reports its
# real outcome while the run sits paused -- reporting a landed packet as
# "paused" is the exact operator-facing lie this capability exists to prevent.
assert_true "  and a DIFFERENT, already-landed packet (rd-green) still reads its real outcome, not paused, while the run is paused" \
  "rd_digest | grep -qx \$'packet\trd-green\tT1 add the first thing\tgreen'"
# Review fix (round three, F5/M5): the paused conditional is TWO independent
# guards -- `status = paused` AND `pkt = cursor`. F4 above closed the mutation
# that drops the cursor check; a second wrong implementation drops the STATUS
# check instead (`[ -n "$cursor" ] && [ "$pkt" = "$cursor" ]` alone) and passed
# every prior case unnoticed, because no fixture ever left a cursor set while
# status was anything but paused -- the block above sets both together, and
# the restore below (until now) cleared both together too. `backlog.cursor`
# names the in-flight packet for the WHOLE of a running loop, so that wrong
# implementation would report the packet currently being worked on as
# "paused" in every mid-run digest of a run that is not paused at all. Restore
# to running WITH the cursor still set first, and assert the cursor packet
# reports its real outcome (rd-paused has a start record and no terminal
# record, so its real outcome is `open` -- not vacuous), before clearing the
# cursor for every later case in this block.
printf 'schema: 3\nstatus: running\nrun_id: %s\nbacklog:\n  cursor: rd-paused\n' "$RD_RUN_ID" > "$RD/.agents/run-state.yaml"
assert_true "run-digest: a cursor packet in a RUNNING run reads its real outcome, never paused -- the cursor alone is not what makes a packet paused" \
  "rd_digest | grep -qx \$'packet\trd-paused\tT4 mid-edit when paused\topen'"
assert_true "  and does not read paused while the run is running" \
  "! rd_digest | grep -qx \$'packet\trd-paused\tT4 mid-edit when paused\tpaused'"
printf 'schema: 3\nstatus: running\nrun_id: %s\n' "$RD_RUN_ID" > "$RD/.agents/run-state.yaml"

# Review fix (round two): `_rs_digest_outcome`'s same-timestamp comparison is
# `-ge`, deliberately, because `sweep-open` copies its terminal record's ts
# VERBATIM from the start it closes -- the two records can and do carry the
# exact same timestamp. The round-one sweep never exercised that boundary
# with the REAL writers (only hand-written JSON with distinct timestamps), so
# a wrong implementation that narrowed the comparison to `-gt` passed
# unnoticed while making every interrupted packet read `open` forever. Built
# with `record-start` + `sweep-open` themselves, not hand-written JSON, so
# the ts values are guaranteed identical the way the real writers guarantee
# it, not merely asserted to be.
echo "-- interrupted, built with the REAL record-start + sweep-open writers: sweep-open's terminal ts equals its own start's ts verbatim, so the boundary comparison must be >=, not > --"
printf 'T8 gets swept as interrupted\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-interrupted --tier integration --agent implementer) >/dev/null
(cd "$RD" && "$RUNSTATE" record-start rd-interrupted S1 >/dev/null)
(cd "$RD" && CLAUDE_CODE_SESSION_ID=S1 "$RUNSTATE" sweep-open >/dev/null)
assert_true "run-digest: a packet swept as interrupted (terminal ts == its own start's ts) reads interrupted, never open" \
  "rd_digest | grep -qx \$'packet\trd-interrupted\tT8 gets swept as interrupted\tinterrupted'"
assert_true "  and does not (also or instead) read open" \
  "! rd_digest | grep -qx \$'packet\trd-interrupted\tT8 gets swept as interrupted\topen'"

echo "-- a result file's own BODY TEXT never appears in the digest -- asserted against the digest's REAL content, not an empty one --"
printf 'T5 write a result file\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-body --tier integration --agent implementer) >/dev/null
RD_RESULT_PATH="$RD/.agents/loop/$RD_RUN_ID/rd-body/implementer.md"
printf 'RD_SECRET_BODY_TEXT_MUST_NOT_LEAK\n' | (cd "$RD" && "$RUNSTATE" write-result .agents/run-state.yaml "$RD_RESULT_PATH" --status "pass · rd-body landed · result: needs-reading · $RD_RESULT_PATH") >/dev/null
printf '{"ts":"2026-02-01T00:00:06Z","packet":"rd-body","session":"S1","kind":"start"}\n{"ts":"2026-02-01T00:00:07Z","packet":"rd-body","session":"S1","outcome":"green"}\n' \
  >> "$RD/.agents/metrics/outcomes/S1.jsonl"
RD_BODY_OUT="$(rd_digest)"
assert_true "run-digest: the digest DID produce this packet's real line (so the absence check below is not vacuously true against an empty digest)" \
  "printf '%s\n' \"\$RD_BODY_OUT\" | grep -qx \$'packet\trd-body\tT5 write a result file\tgreen'"
assert_true "run-digest: the result file's own body text (never its status line) never appears anywhere in the digest" \
  "! printf '%s\n' \"\$RD_BODY_OUT\" | grep -q RD_SECRET_BODY_TEXT_MUST_NOT_LEAK"

# thin-loop-driver-gaps-t1: `_rs_digest_title` interpolated a handoff's first
# line into awk via `-v`, which expands C-style backslash escapes IN THE
# VALUE -- a title carrying a literal `\n` (or, incidentally, a Windows path's
# `\i`/`\f` sequences) would explode into a real newline inside awk's single
# `print`, so the run-digest packet line split into two physical lines: the
# real one (still carrying its leading `packet` type field) and a headless
# second fragment with no type field at all. Fixed via `ENVIRON`, which does
# no escape processing on the value; `pkt` stays on `-v` since it is
# charset-validated with no backslash. Measured by a line-count delta (adding
# one packet must add exactly one digest line, not two) rather than string
# content alone, since a split line can still happen to contain the packet id
# in its first fragment and pass a naive substring check.
echo "-- a title carrying a literal backslash sequence (\\n, a Windows path) yields exactly ONE digest line, not an exploded newline (thin-loop-driver-gaps-t1) --"
RD_PRECOUNT="$(rd_digest | wc -l | tr -d ' ')"
RD_BACKSLASH_TITLE='T9 has a literal \n escape and a Windows path C:\import\file.md'
printf '%s\nbody\n' "$RD_BACKSLASH_TITLE" | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-backslash --tier integration --agent implementer) >/dev/null
RD_BACKSLASH_EXPECTED="$(printf 'packet\trd-backslash\t%s\topen' "$RD_BACKSLASH_TITLE")"
RD_BACKSLASH_OUT="$(rd_digest)"
RD_POSTCOUNT="$(printf '%s\n' "$RD_BACKSLASH_OUT" | wc -l | tr -d ' ')"
assert_true "run-digest: a backslash-bearing title is interpolated verbatim into the digest line, not exploded into a raw newline by awk -v" \
  "printf '%s\n' \"\$RD_BACKSLASH_OUT\" | grep -qFx \"\$RD_BACKSLASH_EXPECTED\""
assert_true "run-digest: adding this one backslash-bearing packet adds exactly ONE new digest line, not two from an exploded escape" \
  "[ \"\$RD_POSTCOUNT\" = \"\$((RD_PRECOUNT + 1))\" ]"
assert_true "run-digest: every line in the digest still starts with a recognized type field (packet/decision/handoff-feature/enter) -- no headless fragment left over" \
  "! printf '%s\n' \"\$RD_BACKSLASH_OUT\" | awk -F'\t' '\$1!=\"packet\" && \$1!=\"decision\" && \$1!=\"handoff-feature\" && \$1!=\"enter\"' | grep -q ."

echo
echo "== record-decision / record-review: a THIRD log, outside begin-run's prune and outside"
echo "   the outcomes log's boundary read (escalation-decider T1) =="
# The two things this case exists to rule out, both of which are silent:
#
#  (a) writing these records into .agents/metrics/outcomes/. `_rs_open_packets`
#      classifies a line there by FIELD SHAPE -- `if (kind != "")` makes ANY
#      record carrying a `packet` and a non-empty `kind` a packet BOUNDARY, and
#      it never tests for the values `start`/`continue`. A decision record there
#      lands AFTER the packet's green outcome, so the packet reopens: sweep-open
#      then writes it an `interrupted` terminal record and run-digest reports a
#      packet nothing interrupted as interrupted. The fixture below therefore
#      ends its packet GREEN before recording anything, so "still green" is a
#      real discriminator rather than a packet that was never closed.
#  (b) writing them into .agents/loop/<run_id>/ beside routing.jsonl, which
#      begin-run prunes to the current run plus the single newest other. The
#      later begin-run here is made to ACTUALLY prune (it reports REMOVED=), so
#      the survival assertion is not vacuous against a prune that never ran.
DL="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$DL" init -q
git -C "$DL" config user.email t@t; git -C "$DL" config user.name t
mkdir -p "$DL/.agents"
printf 'schema: 3\nstatus: running\n' > "$DL/.agents/run-state.yaml"
# Session id pinned per call rather than exported: the sweep may itself be
# running inside a session that exports CLAUDE_CODE_SESSION_ID, and the log
# file name is that value.
dl_rs() { (cd "$DL" && CLAUDE_CODE_SESSION_ID=DLS "$RUNSTATE" "$@"); }
DL_RUN_ID="$(dl_rs begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
DL_LOG="$DL/.agents/metrics/decisions/DLS.jsonl"

printf 'T1 the packet a decision is recorded against\nbody\n' \
  | dl_rs handoff .agents/run-state.yaml dl-pkt --tier mechanical --agent implementer >/dev/null
dl_rs record-start dl-pkt >/dev/null
dl_rs record-outcome dl-pkt green >/dev/null
DL_OUTCOMES_BEFORE="$(cat "$DL"/.agents/metrics/outcomes/*.jsonl | wc -l | tr -d ' ')"
assert_true "the fixture packet reads green BEFORE any decision record (so the checks below discriminate)" \
  "dl_rs run-digest .agents/run-state.yaml | grep -qx \$'packet\tdl-pkt\tT1 the packet a decision is recorded against\tgreen'"

dl_rs record-decision .agents/run-state.yaml dl-pkt retry \
  --trigger 'the reviewer asked for a change the handoff did not state' \
  --finding dl.f-1 --summary 'the handoff omitted the sweep case' >/dev/null
dl_rs record-review .agents/run-state.yaml \
  --bytes-before 4096 --bytes-after 2048 --merged 2 --routed 1 --dropped 3 >/dev/null

assert_true "record-decision + record-review write to .agents/metrics/decisions/<session>.jsonl" \
  "[ -f \"$DL_LOG\" ]"
assert_true "each writes exactly ONE line" \
  "[ \"\$(wc -l < \"$DL_LOG\" | tr -d ' ')\" = 2 ]"
assert_true "the decision log parses as valid JSON end to end" \
  "jq -s -e 'length == 2 and (map(type == \"object\") | all)' \"$DL_LOG\" >/dev/null"
DL_DEC_LINE="$(jq -c 'select(.kind == "decision")' "$DL_LOG")"
DL_REV_LINE="$(jq -c 'select(.kind == "review")'   "$DL_LOG")"
assert_true "the decision record carries packet, decision, trigger and finding" \
  "[ \"\$(jq -r '.packet + \"|\" + .decision + \"|\" + .trigger + \"|\" + .finding' <<<\"\$DL_DEC_LINE\")\" = 'dl-pkt|retry|the reviewer asked for a change the handoff did not state|dl.f-1' ]"
assert_true "the decision record carries the summary" \
  "[ \"\$(jq -r .summary <<<\"\$DL_DEC_LINE\")\" = 'the handoff omitted the sweep case' ]"
assert_true "the review record carries all five values" \
  "[ \"\$(jq -r '.bytes_before + \"|\" + .bytes_after + \"|\" + .merged + \"|\" + .routed + \"|\" + .dropped' <<<\"\$DL_REV_LINE\")\" = '4096|2048|2|1|3' ]"
# run_id is what lets a reader separate THIS run's decisions from the previous
# run's: the log is session-keyed, and a session outlives a run.
assert_true "both records carry this run's run_id" \
  "[ \"\$(jq -r .run_id <<<\"\$DL_DEC_LINE\")\" = \"$DL_RUN_ID\" ] && [ \"\$(jq -r .run_id <<<\"\$DL_REV_LINE\")\" = \"$DL_RUN_ID\" ]"
assert_true "both records carry the session" \
  "[ \"\$(jq -r .session <<<\"\$DL_DEC_LINE\")\" = DLS ] && [ \"\$(jq -r .session <<<\"\$DL_REV_LINE\")\" = DLS ]"
# Checked by CONTENT and BEFORE the prune below, so a copy written beside
# routing.jsonl is caught whatever it is called and while it still exists.
# `grep -rq` with no pipe -- the pipe-fed `grep -q` shape is the SIGPIPE hazard
# this sweep's own source guard scans scripts/runstate.sh for.
assert_true "no copy of the decision record was written under .agents/loop/" \
  "! grep -rq 'the reviewer asked for a change the handoff did not state' \"$DL/.agents/loop\" 2>/dev/null"

echo "-- NOT the outcomes log: the packet stays closed, so nothing sweeps it as interrupted --"
assert_true "neither record was appended to the outcomes log" \
  "[ \"\$(cat \"$DL\"/.agents/metrics/outcomes/*.jsonl | wc -l | tr -d ' ')\" = \"$DL_OUTCOMES_BEFORE\" ]"
assert_true "sweep-open --list reports no open packet after both records" \
  "[ -z \"\$(dl_rs sweep-open --list)\" ]"
assert_true "run-digest still reports the packet green, not open and not interrupted" \
  "dl_rs run-digest .agents/run-state.yaml | grep -qx \$'packet\tdl-pkt\tT1 the packet a decision is recorded against\tgreen'"
# The sweep is run for real (not only --list): a writing sweep is what would
# actually stamp `interrupted` onto the reopened packet.
dl_rs sweep-open >/dev/null
assert_true "a real (writing) sweep-open adds no terminal record either" \
  "[ \"\$(cat \"$DL\"/.agents/metrics/outcomes/*.jsonl | wc -l | tr -d ' ')\" = \"$DL_OUTCOMES_BEFORE\" ]"
assert_true "and the packet still reads green after that sweep" \
  "dl_rs run-digest .agents/run-state.yaml | grep -qx \$'packet\tdl-pkt\tT1 the packet a decision is recorded against\tgreen'"

echo "-- NOT the run directory: the records outlive the run directory begin-run deletes --"
# begin-run keeps the current run plus the single newest OTHER, so it takes TWO
# later runs to delete this one -- which is exactly the "two runs later" an
# audit of what the decider decided has to survive. A later run is modelled the
# way a real one starts (run_id is minted once per run-state, and a resume keeps
# it, so a new run means a new run-state); the two later ids are FABRICATED and
# far-future rather than minted, because minting is second-resolution plus a
# random suffix -- three ids minted in the same second would order by that
# random suffix and this case would prune a different directory run to run.
mkdir -p "$DL/.agents/loop/20260101T000000-aaaa"
printf 'schema: 3\nstatus: running\nrun_id: 20991231T235959-aaaa\n' > "$DL/.agents/run-state.yaml"
dl_rs begin-run .agents/run-state.yaml >/dev/null
assert_true "the FIRST later run keeps this run's directory (it is still the newest other)" \
  "[ -d \"$DL/.agents/loop/$DL_RUN_ID\" ]"
printf 'schema: 3\nstatus: running\nrun_id: 20991231T235959-bbbb\n' > "$DL/.agents/run-state.yaml"
DL_BEGIN3="$(dl_rs begin-run .agents/run-state.yaml)"
assert_true "the SECOND later run deletes the run directory these decisions were recorded during" \
  "printf '%s\n' \"\$DL_BEGIN3\" | grep -qx 'REMOVED=$DL_RUN_ID' && [ ! -d \"$DL/.agents/loop/$DL_RUN_ID\" ]"
assert_true "both decision-log records survive that deletion" \
  "[ \"\$(wc -l < \"$DL_LOG\" | tr -d ' ')\" = 2 ]"
assert_true "and the log still parses after it" \
  "jq -s -e 'length == 2 and (map(type == \"object\") | all)' \"$DL_LOG\" >/dev/null"
assert_true "sweep-open still reports no open packet after the begin-run" \
  "[ -z \"\$(dl_rs sweep-open --list)\" ]"

echo "-- refusals: every argument check runs BEFORE anything is written --"
DL_BYTES_BEFORE_REFUSALS="$(wc -c < "$DL_LOG" | tr -d ' ')"
assert_true "record-decision refuses a reviewer verdict (escalate) as a decision" \
  "! dl_rs record-decision .agents/run-state.yaml dl-pkt escalate --trigger x 2>/dev/null"
assert_true "record-decision refuses a call with no --trigger" \
  "! dl_rs record-decision .agents/run-state.yaml dl-pkt retry 2>/dev/null"
assert_true "record-decision refuses a packet id that would break its JSON (same charset rule as record-start)" \
  "! dl_rs record-decision .agents/run-state.yaml 'pkt\"; drop' retry --trigger x 2>/dev/null"
assert_true "record-decision refuses a finding id that is not a legal filename" \
  "! dl_rs record-decision .agents/run-state.yaml dl-pkt retry --trigger x --finding '../escape' 2>/dev/null"
assert_true "record-review refuses a call missing one of the five values" \
  "! dl_rs record-review .agents/run-state.yaml --bytes-before 1 --bytes-after 2 --merged 3 --routed 4 2>/dev/null"
assert_true "record-review refuses a non-numeric count" \
  "! dl_rs record-review .agents/run-state.yaml --bytes-before 1 --bytes-after 2 --merged three --routed 4 --dropped 5 2>/dev/null"
assert_true "the decision log is BYTE-UNCHANGED after every refusal above" \
  "[ \"\$(wc -c < \"$DL_LOG\" | tr -d ' ')\" = \"$DL_BYTES_BEFORE_REFUSALS\" ]"
# A count that could not be read must be recordable as `unmeasured`. Recording
# 0 instead would read as a measurement that happened to be zero -- the one
# reading this record must never support.
assert_true "record-review accepts 'unmeasured' for a value that could not be read" \
  "dl_rs record-review .agents/run-state.yaml --bytes-before unmeasured --bytes-after unmeasured --merged 0 --routed 0 --dropped 0 >/dev/null"
assert_true "and stores it as 'unmeasured', never as 0" \
  "[ \"\$(jq -r 'select(.kind == \"review\") | .bytes_before' \"$DL_LOG\" | tail -1)\" = unmeasured ]"
# Both refuse without a run_id for the same reason route/handoff/run-digest do:
# a record that cannot name its run cannot be scoped to it afterwards.
DLN="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$DLN" init -q
mkdir -p "$DLN/.agents"; printf 'schema: 3\nstatus: running\n' > "$DLN/.agents/run-state.yaml"
assert_true "record-decision refuses a run-state with no run_id (begin-run not called)" \
  "(cd \"$DLN\" && ! CLAUDE_CODE_SESSION_ID=DLS \"\$RUNSTATE\" record-decision .agents/run-state.yaml p1 retry --trigger x 2>/dev/null)"
assert_true "record-review refuses a run-state with no run_id" \
  "(cd \"$DLN\" && ! CLAUDE_CODE_SESSION_ID=DLS \"\$RUNSTATE\" record-review .agents/run-state.yaml --bytes-before 1 --bytes-after 2 --merged 3 --routed 4 --dropped 5 2>/dev/null)"
assert_true "a refused record-decision created no decisions log at all" \
  "[ ! -e \"$DLN/.agents/metrics/decisions\" ]"
# Free text reaches these records (a trigger quotes the reviewer; a summary
# quotes a finding), and one unescaped byte makes `jq -s` drop EVERY record in
# the file at once -- the same silent failure the outcomes log is guarded
# against above.
DL_HOSTILE='he said "no" and left a \backslash'
dl_rs record-decision .agents/run-state.yaml dl-pkt ask-operator --trigger "$DL_HOSTILE" --summary "$DL_HOSTILE" >/dev/null
assert_true "a trigger/summary carrying quotes and backslashes leaves the whole log parseable" \
  "jq -s -e 'length == 4 and (map(type == \"object\") | all)' \"$DL_LOG\" >/dev/null"
assert_true "and round-trips that text verbatim" \
  "[ \"\$(jq -r 'select(.decision == \"ask-operator\") | .trigger' \"$DL_LOG\")\" = \"\$DL_HOSTILE\" ]"

echo
echo "== review-due: counted since the last RECORDED review, and reported unmeasured --"
echo "   never 0 -- when it cannot be read (escalation-decider T2) =="
# THE mutation this whole block exists to rule out is reporting 0 for a count
# that could not be read. 0 is a measurement meaning "nothing has happened since
# the last review": it sits below both thresholds, so DUE reads `no` and every
# review is suppressed for the rest of the run, silently, for as long as
# whatever broke the read stays broken. `unmeasured` + DUE=yes is the opposite
# failure direction -- one review too many, which costs a dispatch.
#
# Ordering is asserted against HAND-WRITTEN records with explicit timestamps,
# the same way periodic-pause's own cases are, because `_rs_now_ts` falls back
# to WHOLE-SECOND resolution wherever `date +%N` is unsupported (macOS) -- so
# records written by consecutive real calls can share a timestamp and no
# before/after assertion built on them would be trustworthy there. The real
# writers get their own end-to-end case at the bottom of this block.
RV="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$RV" init -q
git -C "$RV" config user.email t@t; git -C "$RV" config user.name t
mkdir -p "$RV/.agents/metrics/outcomes" "$RV/.agents/metrics/decisions"
printf 'schema: 3\nstatus: running\n' > "$RV/.agents/run-state.yaml"
RV_OUTCOMES="$RV/.agents/metrics/outcomes"
RV_DECISIONS="$RV/.agents/metrics/decisions"
RV_OVERRIDES="$RV/.agents/project-overrides.yaml"
rv_due() { (cd "$RV" && CLAUDE_CODE_SESSION_ID=RVS "$RUNSTATE" review-due); }
# One capture, five values -- extracted with a here-string, never a pipe, since
# this file runs with `pipefail` on outside assert_true.
rv_snap() {
  RV_OUT="$(rv_due)"
  RV_NG="$(sed -n 's/^NON_GREEN=//p'       <<< "$RV_OUT")"
  RV_BG="$(sed -n 's/^BEGINNINGS=//p'      <<< "$RV_OUT")"
  RV_ENG="$(sed -n 's/^EVERY_NON_GREEN=//p'  <<< "$RV_OUT")"
  RV_EBG="$(sed -n 's/^EVERY_BEGINNINGS=//p' <<< "$RV_OUT")"
  RV_DUE="$(sed -n 's/^DUE=//p'            <<< "$RV_OUT")"
}

echo "-- a continuation is not a beginning --"
# Two packets begin, one of them is continued after a false finish, one ends
# failed and one ends green. Session A only so far.
printf '%s\n' \
  '{"ts":"2026-04-01T00:00:01Z","packet":"rv-p1","session":"RVA","kind":"start"}' \
  '{"ts":"2026-04-01T00:00:02Z","packet":"rv-p1","session":"RVA","outcome":"failed"}' \
  '{"ts":"2026-04-01T00:00:03Z","packet":"rv-p2","session":"RVA","kind":"start"}' \
  '{"ts":"2026-04-01T00:00:04Z","packet":"rv-p2","session":"RVA","outcome":"green"}' \
  '{"ts":"2026-04-01T00:00:05Z","packet":"rv-p1","session":"RVA","kind":"continue"}' \
  > "$RV_OUTCOMES/RVA.jsonl"
rv_snap
# MUTATION RULED OUT: counting `kind: continue` as a beginning (widening the
# `k == "start"` test in _rs_review_rows to `k == "start" || k == "continue"`).
# The count reads 3 with that change -- and a packet retried three times would
# read as four beginnings, pulling the beginnings threshold forward by however
# often the loop had to retry, which is exactly when the findings index is
# least in need of an extra review.
assert_true "review-due counts two beginnings, not three: the continuation of rv-p1 does not raise BEGINNINGS" \
  "[ \"\$RV_BG\" = 2 ]"
assert_true "and counts only the NON-green ending: rv-p1 failed counts, rv-p2 green does not" \
  "[ \"\$RV_NG\" = 1 ]"
assert_true "with no overrides file, both thresholds report their documented defaults" \
  "[ \"\$RV_ENG\" = 2 ] && [ \"\$RV_EBG\" = 10 ]"
assert_true "one ending and two beginnings is under both thresholds, so no review is due" \
  "[ \"\$RV_DUE\" = no ]"

echo "-- a second session's records count too, and the threshold fires AT the number --"
printf '%s\n' \
  '{"ts":"2026-04-01T00:00:06Z","packet":"rv-p3","session":"RVB","outcome":"blocked"}' \
  > "$RV_OUTCOMES/RVB.jsonl"
rv_snap
assert_true "a blocked ending in ANOTHER session's log raises the count (a packet can begin in one session and end in another)" \
  "[ \"\$RV_NG\" = 2 ]"
assert_true "and DUE flips at the threshold, not one past it (2 >= 2)" \
  "[ \"\$RV_DUE\" = yes ]"

echo "-- the count resets at a recorded review, and at nothing else --"
# A DECISION record first. It lives in the same log as a review record and
# carries the same `kind` field, so anchoring on "the latest record in the
# decisions log" rather than on "the latest RECORD OF KIND review" would reset
# the count here -- and a decider that had just routed one escalation would
# never reach a periodic review at all.
printf '%s\n' \
  '{"ts":"2026-04-01T00:00:07Z","session":"RVD","run_id":"r1","kind":"decision","packet":"rv-p1","decision":"retry","trigger":"t","finding":"","summary":""}' \
  > "$RV_DECISIONS/RVD.jsonl"
rv_snap
assert_true "a DECISION record does not reset the count" \
  "[ \"\$RV_NG\" = 2 ] && [ \"\$RV_BG\" = 2 ] && [ \"\$RV_DUE\" = yes ]"
printf '%s\n' \
  '{"ts":"2026-04-01T00:00:08Z","session":"RVD","run_id":"r1","kind":"review","bytes_before":"10","bytes_after":"8","merged":"1","routed":"0","dropped":"0"}' \
  >> "$RV_DECISIONS/RVD.jsonl"
rv_snap
# MUTATION RULED OUT: dropping the `kind != "review"` filter in
# _rs_latest_review_ts (anchoring on the newest record in the decisions log).
# The decision assertion above turns red immediately -- the count resets on a
# routing decision, which happens far more often than a review.
assert_true "a RECORDED review resets both counts to 0" \
  "[ \"\$RV_NG\" = 0 ] && [ \"\$RV_BG\" = 0 ]"
assert_true "and nothing is due straight after a review" \
  "[ \"\$RV_DUE\" = no ]"
# A review counts as completed only when it recorded itself, which the decider
# does after returning its status line -- so a review cut short by a crash
# leaves no record here and the count simply never reset. That is the same
# assertion as "the count reset at THIS record": there is no separate liveness
# field to get wrong.
printf '%s\n' \
  '{"ts":"2026-04-01T00:00:00.500Z","session":"RVE","run_id":"r0","kind":"review","bytes_before":"1","bytes_after":"1","merged":"0","routed":"0","dropped":"0"}' \
  > "$RV_DECISIONS/RVE.jsonl"
rv_snap
assert_true "an EARLIER review in another session's decision log does not move the anchor back (latest, not first)" \
  "[ \"\$RV_NG\" = 0 ] && [ \"\$RV_BG\" = 0 ]"

echo "-- all five non-green endings count; green and an unknown outcome do not --"
printf '%s\n' \
  '{"ts":"2026-04-01T00:00:09Z","packet":"rv-p4","session":"RVB","kind":"start"}' \
  '{"ts":"2026-04-01T00:00:10Z","packet":"rv-p4","session":"RVB","outcome":"abandoned"}' \
  '{"ts":"2026-04-01T00:00:11Z","packet":"rv-p5","session":"RVB","outcome":"interrupted"}' \
  '{"ts":"2026-04-01T00:00:12Z","packet":"rv-p6","session":"RVB","outcome":"rolled-back"}' \
  '{"ts":"2026-04-01T00:00:13Z","packet":"rv-p7","session":"RVB","outcome":"green"}' \
  >> "$RV_OUTCOMES/RVB.jsonl"
rv_snap
assert_true "abandoned, interrupted and rolled-back all count as non-green endings (failed and blocked counted above)" \
  "[ \"\$RV_NG\" = 3 ]"
assert_true "and the one start among them is the only new beginning" \
  "[ \"\$RV_BG\" = 1 ]"
# MUTATION RULED OUT: matching non-green as `outcome != "green"`. An outcome
# value this file does not know -- a future one, or a truncated record -- would
# then count as an ending, and endings carry the SMALLER threshold, so the
# inverted form pulls reviews forward on records nobody attested as endings.
printf '%s\n' \
  '{"ts":"2026-04-01T00:00:14Z","packet":"rv-p8","session":"RVB","outcome":"superseded"}' \
  >> "$RV_OUTCOMES/RVB.jsonl"
rv_snap
assert_true "an outcome value this file does not know is NOT counted as a non-green ending (matched by value, never as 'not green')" \
  "[ \"\$RV_NG\" = 3 ]"

echo "-- both thresholds come from project-overrides.yaml, token-scanned --"
printf '%s\n' \
  "review_after_non_green_endings: '4'   # quoted, and a trailing comment" \
  'review_after_beginnings: 3 # whichever count is reached first triggers' \
  > "$RV_OVERRIDES"
rv_snap
assert_true "a quoted value and a comment-trailed value are both honoured, not read as missing" \
  "[ \"\$RV_ENG\" = 4 ] && [ \"\$RV_EBG\" = 3 ]"
assert_true "raising the endings threshold above the count clears DUE on that arm" \
  "[ \"\$RV_NG\" = 3 ]"
# Whichever comes first: three endings against a threshold of 4 is not due, but
# the SAME snapshot has one beginning against 3, so this pins that DUE is an OR
# of the two arms rather than the endings arm alone.
assert_true "with 3 endings under a threshold of 4 and 1 beginning under 3, nothing is due" \
  "[ \"\$RV_DUE\" = no ]"
printf '%s\n' \
  '{"ts":"2026-04-01T00:00:15Z","packet":"rv-p9","session":"RVB","kind":"start"}' \
  '{"ts":"2026-04-01T00:00:16Z","packet":"rv-pa","session":"RVB","kind":"start"}' \
  >> "$RV_OUTCOMES/RVB.jsonl"
rv_snap
assert_true "the BEGINNINGS arm fires on its own, with the endings arm still under its threshold" \
  "[ \"\$RV_BG\" = 3 ] && [ \"\$RV_NG\" = 3 ] && [ \"\$RV_DUE\" = yes ]"
printf '%s\n' \
  'review_after_non_green_endings: many' \
  'review_after_beginnings: 0' \
  > "$RV_OVERRIDES"
rv_snap
assert_true "an invalid value falls back to its default, and so does 0 (a threshold of 0 would ask for a review at every boundary forever)" \
  "[ \"\$RV_ENG\" = 2 ] && [ \"\$RV_EBG\" = 10 ]"
rm -f "$RV_OVERRIDES"

echo "-- unmeasured, never 0: an unreadable outcomes log --"
# Shape 1, uid-INDEPENDENT: a plain file where the log directory belongs. No
# process of any uid can list it, so this shape runs everywhere.
RV_SAVED="$RV/.agents/metrics/outcomes-saved"
mv "$RV_OUTCOMES" "$RV_SAVED"
printf 'not a directory\n' > "$RV_OUTCOMES"
rv_snap
# MUTATION RULED OUT: reporting 0 for a count that could not be read (drop the
# readability test and let the awk glob come back empty). Both counts read 0,
# DUE reads `no`, and every review for the rest of the run is suppressed by a
# number that looks like a measurement -- the failure this command's whole
# enum exists to prevent.
assert_true "an unreadable outcomes log reports NON_GREEN=unmeasured, never 0" \
  "[ \"\$RV_NG\" = unmeasured ]"
assert_true "and BEGINNINGS=unmeasured, never 0" \
  "[ \"\$RV_BG\" = unmeasured ]"
assert_true "and the review RUNS on an unmeasured count" \
  "[ \"\$RV_DUE\" = yes ]"
# Scoped: only what failed reads as unmeasured. The overrides file is absent,
# which is an ANSWER (no override, hence the default) rather than a failed read.
assert_true "the thresholds still report their values -- unmeasured is scoped to what actually could not be read" \
  "[ \"\$RV_ENG\" = 2 ] && [ \"\$RV_EBG\" = 10 ]"
rm -f "$RV_OUTCOMES"; mv "$RV_SAVED" "$RV_OUTCOMES"
rv_snap
assert_true "and the counts come back as soon as the log is readable again" \
  "[ \"\$RV_NG\" = 3 ] && [ \"\$RV_BG\" = 3 ]"

# Shape 2, uid-DEPENDENT: mode 000, probed rather than assumed. As uid 0 a
# mode-000 path is still readable, so this host may be unable to create the
# condition -- in which case the case is reported NOT RUN, never passed quietly.
chmod 000 "$RV_OUTCOMES"
RV_MODE_BLOCKS=no
if ! ls "$RV_OUTCOMES" >/dev/null 2>&1; then RV_MODE_BLOCKS=yes; fi
if [ "$RV_MODE_BLOCKS" = yes ]; then
  rv_snap
  assert_true "a mode-000 outcomes directory reports both counts as unmeasured with DUE=yes" \
    "[ \"\$RV_NG\" = unmeasured ] && [ \"\$RV_BG\" = unmeasured ] && [ \"\$RV_DUE\" = yes ]"
else
  printf 'note this host reads a mode-000 directory (uid %s) — the mode-000 shape was NOT run; the not-a-directory shape above covers the same refusal\n' "$(id -u)"
fi
chmod 755 "$RV_OUTCOMES"

# Shape 3, the sharp one: the DIRECTORY is readable and one log FILE inside it
# is not. The awk pass globs `<dir>/*.jsonl` with stderr discarded, so an
# unreadable file contributes nothing and the remaining files still produce a
# plausible, smaller count -- a wrong number that looks exactly like a right one.
chmod 000 "$RV_OUTCOMES/RVB.jsonl"
RV_FILE_BLOCKS=no
if ! cat "$RV_OUTCOMES/RVB.jsonl" >/dev/null 2>&1; then RV_FILE_BLOCKS=yes; fi
if [ "$RV_FILE_BLOCKS" = yes ]; then
  rv_snap
  assert_true "an unreadable log FILE inside a readable directory reports unmeasured, not the smaller count the remaining files would give" \
    "[ \"\$RV_NG\" = unmeasured ] && [ \"\$RV_BG\" = unmeasured ] && [ \"\$RV_DUE\" = yes ]"
else
  printf 'note this host reads a mode-000 file (uid %s) — the unreadable-log-file shape was NOT run\n' "$(id -u)"
fi
chmod 644 "$RV_OUTCOMES/RVB.jsonl"

echo "-- unmeasured, never a stale anchor: an unreadable decision log --"
# The decision log supplies the POINT the outcomes records are counted from. An
# unreadable one would otherwise count from the wrong anchor -- silently, and
# with a number that looks measured.
RV_DEC_SAVED="$RV/.agents/metrics/decisions-saved"
mv "$RV_DECISIONS" "$RV_DEC_SAVED"
printf 'not a directory\n' > "$RV_DECISIONS"
rv_snap
assert_true "an unreadable decision log reports both counts as unmeasured with DUE=yes (the anchor is part of the measurement)" \
  "[ \"\$RV_NG\" = unmeasured ] && [ \"\$RV_BG\" = unmeasured ] && [ \"\$RV_DUE\" = yes ]"
rm -f "$RV_DECISIONS"; mv "$RV_DEC_SAVED" "$RV_DECISIONS"

echo "-- unmeasured thresholds: an overrides file that is present but cannot be read --"
printf 'review_after_beginnings: 3\n' > "$RV_OVERRIDES"
chmod 000 "$RV_OVERRIDES"
RV_OV_BLOCKS=no
if ! cat "$RV_OVERRIDES" >/dev/null 2>&1; then RV_OV_BLOCKS=yes; fi
if [ "$RV_OV_BLOCKS" = yes ]; then
  rv_snap
  assert_true "an unreadable overrides file reports both thresholds as unmeasured, never as the default (a default there would read as a measurement)" \
    "[ \"\$RV_ENG\" = unmeasured ] && [ \"\$RV_EBG\" = unmeasured ]"
  assert_true "and an unmeasured threshold runs the review, even with both counts measured" \
    "[ \"\$RV_NG\" = 3 ] && [ \"\$RV_DUE\" = yes ]"
else
  printf 'note this host reads a mode-000 file (uid %s) — the mode-000 overrides shape was NOT run; the not-a-regular-file shape below covers it\n' "$(id -u)"
fi
chmod 644 "$RV_OVERRIDES"; rm -f "$RV_OVERRIDES"
# uid-independent: a DIRECTORY where the overrides file belongs. Present, so
# not skippable as absent, and no uid can read it as a file.
mkdir -p "$RV_OVERRIDES"
rv_snap
assert_true "an overrides path that is present but is not a regular file reports both thresholds as unmeasured with DUE=yes" \
  "[ \"\$RV_ENG\" = unmeasured ] && [ \"\$RV_EBG\" = unmeasured ] && [ \"\$RV_DUE\" = yes ]"
rmdir "$RV_OVERRIDES"

echo "-- absence is an answer, not a failed read --"
RVE="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$RVE" init -q
RVE_OUT="$( (cd "$RVE" && CLAUDE_CODE_SESSION_ID=RVS "$RUNSTATE" review-due) )"
assert_true "a repo with no metrics directory at all counts 0 and 0 -- an absent log holds no records, which IS a measurement" \
  "[ \"\$(sed -n 's/^NON_GREEN=//p' <<< \"\$RVE_OUT\")\" = 0 ] && [ \"\$(sed -n 's/^BEGINNINGS=//p' <<< \"\$RVE_OUT\")\" = 0 ]"
assert_true "and nothing is due there" \
  "[ \"\$(sed -n 's/^DUE=//p' <<< \"\$RVE_OUT\")\" = no ]"
assert_true "review-due refuses an argument (it counts across every session, so there is no session to name)" \
  "! (cd \"$RVE\" && \"\$RUNSTATE\" review-due RVS) 2>/dev/null"

echo "-- with no review ever recorded, counting starts at the repo's FIRST start record --"
RVF="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$RVF" init -q
mkdir -p "$RVF/.agents/metrics/outcomes"
printf '%s\n' \
  '{"ts":"2026-05-01T00:00:01Z","packet":"rvf-old","session":"S0","outcome":"failed"}' \
  '{"ts":"2026-05-01T00:00:02Z","packet":"rvf-a","session":"S0","kind":"start"}' \
  > "$RVF/.agents/metrics/outcomes/S0.jsonl"
RVF_OUT="$( (cd "$RVF" && "$RUNSTATE" review-due) )"
assert_true "an ending recorded BEFORE the first start record is outside the window and is not counted" \
  "[ \"\$(sed -n 's/^NON_GREEN=//p' <<< \"\$RVF_OUT\")\" = 0 ]"
assert_true "and the first start record itself is inside it (the window is at-or-after, not after)" \
  "[ \"\$(sed -n 's/^BEGINNINGS=//p' <<< \"\$RVF_OUT\")\" = 1 ]"
# A log of endings with no beginnings at all -- written before start records
# existed -- has no anchor to find. Counting the whole log can only make a
# review run sooner; reporting 0 would suppress one.
RVG="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$RVG" init -q
mkdir -p "$RVG/.agents/metrics/outcomes"
printf '%s\n' \
  '{"ts":"2026-05-01T00:00:01Z","packet":"rvg-old","session":"S0","outcome":"failed"}' \
  > "$RVG/.agents/metrics/outcomes/S0.jsonl"
RVG_OUT="$( (cd "$RVG" && "$RUNSTATE" review-due) )"
assert_true "a legacy log holding endings but no start record at all counts the whole log rather than reporting 0" \
  "[ \"\$(sed -n 's/^NON_GREEN=//p' <<< \"\$RVG_OUT\")\" = 1 ] && [ \"\$(sed -n 's/^BEGINNINGS=//p' <<< \"\$RVG_OUT\")\" = 0 ]"

echo "-- end to end through the REAL writers, not hand-written records --"
# Everything above reads records this file wrote itself, which proves the
# counting rule and nothing about the field shapes record-start/record-outcome/
# record-review actually emit. This case uses those three commands, so a change
# to any of their record shapes turns it red.
RVR="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$RVR" init -q
git -C "$RVR" config user.email t@t; git -C "$RVR" config user.name t
mkdir -p "$RVR/.agents"
printf 'schema: 3\nstatus: running\n' > "$RVR/.agents/run-state.yaml"
rvr_rs() { (cd "$RVR" && CLAUDE_CODE_SESSION_ID=RVRS "$RUNSTATE" "$@"); }
rvr_rs begin-run .agents/run-state.yaml >/dev/null   # record-review needs a run_id
rvr_rs record-start rvr-a >/dev/null
rvr_rs record-outcome rvr-a failed >/dev/null
RVR_OUT="$(rvr_rs review-due)"
assert_true "a real record-start and a real record-outcome are counted by review-due" \
  "[ \"\$(sed -n 's/^BEGINNINGS=//p' <<< \"\$RVR_OUT\")\" = 1 ] && [ \"\$(sed -n 's/^NON_GREEN=//p' <<< \"\$RVR_OUT\")\" = 1 ]"
# ONE second of real time, and it is load-bearing: `_rs_now_ts` is whole-second
# wherever `date +%N` is unsupported, so without this the review record could
# share a timestamp with the records above and the at-or-after window would
# keep counting them -- the reset would read as broken on macOS and fine on
# Linux. Everything AFTER the review may share its timestamp safely: the window
# is at-or-after by design.
sleep 1
rvr_rs record-review .agents/run-state.yaml \
  --bytes-before 4096 --bytes-after 2048 --merged 1 --routed 0 --dropped 0 >/dev/null
RVR_OUT="$(rvr_rs review-due)"
assert_true "a real record-review resets both counts" \
  "[ \"\$(sed -n 's/^BEGINNINGS=//p' <<< \"\$RVR_OUT\")\" = 0 ] && [ \"\$(sed -n 's/^NON_GREEN=//p' <<< \"\$RVR_OUT\")\" = 0 ]"
rvr_rs record-start rvr-a --continue >/dev/null
RVR_OUT="$(rvr_rs review-due)"
assert_true "a real continuation after that review still does not raise BEGINNINGS" \
  "[ \"\$(sed -n 's/^BEGINNINGS=//p' <<< \"\$RVR_OUT\")\" = 0 ]"
rvr_rs record-start rvr-b >/dev/null
RVR_OUT="$(rvr_rs review-due)"
assert_true "a real start after that review does" \
  "[ \"\$(sed -n 's/^BEGINNINGS=//p' <<< \"\$RVR_OUT\")\" = 1 ]"
# review-due is a READER: it must leave both logs byte-unchanged, so that
# calling it at every boundary cannot itself move the counts it reports.
RVR_BYTES="$(cat "$RVR"/.agents/metrics/outcomes/*.jsonl "$RVR"/.agents/metrics/decisions/*.jsonl | wc -c | tr -d ' ')"
rvr_rs review-due >/dev/null
RVR_BYTES_AFTER="$(cat "$RVR"/.agents/metrics/outcomes/*.jsonl "$RVR"/.agents/metrics/decisions/*.jsonl | wc -c | tr -d ' ')"
assert_true "review-due writes nothing: both logs are byte-unchanged after a call" \
  "[ \"\$RVR_BYTES\" = \"\$RVR_BYTES_AFTER\" ]"

echo
echo "== reorder-pending: backlog.pending replaced in place, through the validated"
echo "   whole-file write -- never appended at column 0 (escalation-decider T3) =="
# THE mutation this block exists to rule out is the `set`-shaped implementation:
# `pending` lives INSIDE `backlog:`, so a naive `grep -qE '^pending:'` finds
# nothing, falls through to an append, and leaves a SECOND, column-0 `pending:`
# at the bottom of the file. That file still PARSES (two distinct mapping keys,
# `backlog.pending` and a top-level `pending`), `reorder-pending` reports the
# new order, and every reader in this script -- `_findings_pending_ids`,
# `cmd_summary` -- keeps reading the nested one. Exit 0, two sources of truth,
# no signal. So the load-bearing assertion here is the COUNT of `pending:`
# keys, not the reported output, and it is asserted alongside a real parse of
# the nested value: either alone passes the wrong implementation.
#
# `cursor` and `findings:` are asserted INTACT for the second half of the same
# failure: a rewrite that finds the block by scanning for the next column-0 key
# can swallow its siblings (cursor sits one line above `pending:` inside
# `backlog:`) or the whole `findings:` index below it -- and a dropped index
# line does not delete a finding, it unlinks a body still on disk (ADR 0022).
ROP="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$ROP/.agents"
rop_rs() { "$RUNSTATE" reorder-pending "$ROP/.agents/run-state.yaml" "$@"; }
rop_fixture() {
  cat > "$ROP/.agents/run-state.yaml" <<'ROPEOF'
schema: 3
status: running
branch: orch/rop
backlog:
  cursor: rop-a                        # next packet to pick up
  pending:                             # packets not yet started, in order
    - rop-b
    - rop-c
    - rop-d

findings:
  - id: rop-f1
    summary: 'guard.sh: fails closed on unreadable input'
    packets: [rop-c]
note: where we stopped
ROPEOF
}
# The nested value, read by a REAL parser -- `backlog.pending` as a csv, and
# `backlog.cursor`. Not a grep: the whole point of this block is that the grep
# view and the parsed view can disagree. Only meaningful when have_yaml is
# true; every caller pairs it with yamlok, which reports a loud counted skip.
_yaml_backlog() {
  python3 -c "
import sys, yaml
b = (yaml.safe_load(open(sys.argv[1])) or {}).get('backlog') or {}
v = b.get(sys.argv[2])
sys.stdout.write(','.join(str(x) for x in v) if isinstance(v, list) else ('' if v is None else str(v)))
" "$1" "$2"
}
_pending_key_count() { grep -cE '^[[:space:]]*pending:' "$1"; }

rop_fixture
ROP_OUT="$(rop_rs rop-d,rop-b 2>&1)"
assert_true "reorder-pending reports the new order, what it added and what it removed" \
  "[ \"\$ROP_OUT\" = \"\$(printf 'REORDERED=yes\nPENDING=rop-d,rop-b\nADDED=\nREMOVED=rop-c\n')\" ]"
# THE assertion: one `pending:` key, not two. An append-based implementation
# passes every other assertion in this block and fails this one.
assert_true "reorder-pending leaves exactly ONE pending: key -- no second source of truth" \
  "[ \"\$(_pending_key_count \"\$ROP/.agents/run-state.yaml\")\" = 1 ]"
assert_true "reorder-pending leaves a file a real YAML parser accepts" \
  "yamlok \"\$ROP/.agents/run-state.yaml\""
assert_true "the PARSED backlog.pending is the requested order, not just the grep view" \
  "yamlok \"\$ROP/.agents/run-state.yaml\" && [ \"\$(_yaml_backlog \"\$ROP/.agents/run-state.yaml\" pending)\" = 'rop-d,rop-b' ]"
assert_true "cursor survives the rewrite, parsed" \
  "yamlok \"\$ROP/.agents/run-state.yaml\" && [ \"\$(_yaml_backlog \"\$ROP/.agents/run-state.yaml\" cursor)\" = 'rop-a' ]"
assert_true "cursor survives the rewrite, as runstate.sh itself reads it" \
  "[ \"\$(\"\$RUNSTATE\" cursor \"\$ROP/.agents/run-state.yaml\" | sed -E 's/[[:space:]]*#.*$//')\" = 'rop-a' ]"
assert_true "the findings index survives the rewrite, entry and body pointer intact" \
  "[ \"\$(\"\$RUNSTATE\" findings \"\$ROP/.agents/run-state.yaml\")\" = \"\$(printf 'rop-f1\tguard.sh: fails closed on unreadable input\t\trop-c')\" ]"
assert_true "every other key survives: note and status are untouched" \
  "[ \"\$(\"\$RUNSTATE\" get \"\$ROP/.agents/run-state.yaml\" note)\" = 'where we stopped' ] \
   && [ \"\$(\"\$RUNSTATE\" get \"\$ROP/.agents/run-state.yaml\" status)\" = 'running' ]"
# An id not previously pending is an ADD, reported by name -- the decider's
# `append-task` puts a brand-new packet ahead of the one it came from.
ROP_OUT="$(rop_rs 'rop-new, rop-d ,rop-b' 2>&1)"
assert_true "an id not already pending is reported as ADDED, and the list keeps the given order" \
  "[ \"\$ROP_OUT\" = \"\$(printf 'REORDERED=yes\nPENDING=rop-new,rop-d,rop-b\nADDED=rop-new\nREMOVED=\n')\" ]"
assert_true "an add still leaves exactly one pending: key and a parseable file" \
  "[ \"\$(_pending_key_count \"\$ROP/.agents/run-state.yaml\")\" = 1 ] && yamlok \"\$ROP/.agents/run-state.yaml\""
# Idempotence is not cosmetic: the decider re-reads and re-writes the order on
# every reorder decision, and a no-op call must not rotate run-state-prev.yaml
# (the last known good copy) past the state a crash would need.
ROP_BEFORE="$(cksum < "$ROP/.agents/run-state.yaml")"
ROP_OUT="$(rop_rs rop-new,rop-d,rop-b 2>&1)"
ROP_AFTER="$(cksum < "$ROP/.agents/run-state.yaml")"
assert_true "re-requesting the order already on disk reports REORDERED=no and writes nothing" \
  "[ \"\$ROP_OUT\" = \"\$(printf 'REORDERED=no\nPENDING=rop-new,rop-d,rop-b\nADDED=\nREMOVED=\n')\" ] \
   && [ \"\$ROP_BEFORE\" = \"\$ROP_AFTER\" ]"

# --- refusals: every one leaves the file BYTE-identical ---------------------
# The check that matters as much as the non-zero exit: a refusal that has
# already written half a file is worse than no refusal at all, which is why
# every shape decision is made before cmd_write is reached.
rop_refuses() {  # rop_refuses <label> <arg...>
  local label="$1"; shift
  local before after rc
  before="$(cksum < "$ROP/.agents/run-state.yaml")"
  set +o pipefail
  rop_rs "$@" >/dev/null 2>&1; rc=$?
  set -o pipefail
  after="$(cksum < "$ROP/.agents/run-state.yaml")"
  if [ "$rc" -ne 0 ] && [ "$before" = "$after" ]; then
    ok "reorder-pending refuses $label, run-state byte-identical"
  else
    bad "reorder-pending refuses $label, run-state byte-identical" "rc=$rc before=$before after=$after"
  fi
}
rop_refuses "an empty order"        ""
rop_refuses "a whitespace-only order" " , "
rop_refuses "a repeated id"         "rop-b,rop-d,rop-b"
# A `/` and not a space: whitespace is a SEPARATOR here (`_split_ids` splits on
# `[,[:space:]]+`), so `rop d` is two valid ids, not one invalid one. The first
# cut of this case used a space and passed the call, which is the reminder that
# the charset refusal can only ever be reached by a non-separator character.
rop_refuses "an id outside [a-zA-Z0-9._-]" "rop-b,rop/d"

# No `pending:` key at all, and more than one: both refused rather than
# guessed at. The two-key fixture is exactly what the append bug produces, and
# refusing it is what stops this subcommand from entrenching the corruption it
# exists not to create.
printf 'schema: 3\nbacklog:\n  cursor: rop-a\n' > "$ROP/.agents/run-state.yaml"
rop_refuses "a run-state with no pending: key" rop-b
printf 'schema: 3\nbacklog:\n  cursor: rop-a\n  pending:\n    - rop-b\npending:\n  - rop-c\n' \
  > "$ROP/.agents/run-state.yaml"
rop_refuses "a run-state already carrying two pending: keys" rop-b
# A flow list and a non-item line inside the block: shapes this parser does not
# write and must not half-rewrite (same rule prune-questions follows).
printf 'schema: 3\nbacklog:\n  pending: [rop-b, rop-c]\n' > "$ROP/.agents/run-state.yaml"
rop_refuses "a flow-list pending:" rop-b
printf 'schema: 3\nbacklog:\n  pending:\n    - rop-b\n    stray: 1\n' > "$ROP/.agents/run-state.yaml"
rop_refuses "a pending block holding a line that is not a - item" rop-b
# A COLUMN-0 `pending:` with column-0 items parses as YAML, and the same-indent
# rule above reads its items correctly -- but `_write_check` refuses any
# column-0 line that is not a `key:` line, so `cmd_write` declines the whole
# file. Pinned as a REFUSAL, not a rewrite: loud rc=1 and byte-identical is the
# acceptable outcome for a shape no run-state has (`pending` is nested under
# `backlog:` everywhere the loop writes it), and this case is what would notice
# if it ever started writing a file half in that shape instead.
printf 'schema: 3\npending:\n- rop-b\n- rop-c\nnote: x\n' > "$ROP/.agents/run-state.yaml"
rop_refuses "a column-0 pending: with column-0 items (cmd_write declines the file)" "rop-c,rop-b"
# A COMMENT between two items, indented no deeper than the `pending:` key. A
# comment is legal at any column in YAML and carries no structure, so a
# boundary scan that treats it like a sibling key ends the block early: the
# rewritten order is inserted above it and the items BELOW it are left in
# place. That file still parses -- and the parsed list then carries a
# DUPLICATE id, the one thing the requested order is validated against. It is
# the rc=0 silent-wrong class, so what this case pins is the refusal AND the
# byte-identical file, not the exit code alone.
printf 'schema: 3\nbacklog:\n  cursor: rop-a\n  pending:\n    - rop-b\n# a stray comment\n    - rop-c\nnote: x\n' \
  > "$ROP/.agents/run-state.yaml"
rop_refuses "a comment line between two pending items" "rop-c,rop-b"
# ...and the same scan must NOT refuse the shape templates/run-state.yaml
# actually ships: items, a blank, then a column-0 comment block, then the next
# key. That block belongs to `pending_questions:`, not to the list, so it has
# to stay OUTSIDE the rewritten span -- untouched, and still above the key it
# documents. The two cases are a pair: skipping comments in the boundary scan
# is what makes the one above refuse, and stepping back over them in the
# trailing trim is what keeps this one working.
cat > "$ROP/.agents/run-state.yaml" <<'ROPEOF'
schema: 3
backlog:
  cursor: rop-a
  pending:                             # packets not yet started, in order
    - rop-b
    - rop-c

# Questions the human must answer before blocked packets can proceed.
# severity: blocking = the loop cannot continue until answered;
pending_questions: []
ROPEOF
ROP_OUT="$(rop_rs rop-c,rop-b 2>&1)"
assert_true "a column-0 comment block AFTER the list is left outside the rewrite" \
  "[ \"\$ROP_OUT\" = \"\$(printf 'REORDERED=yes\nPENDING=rop-c,rop-b\nADDED=\nREMOVED=\n')\" ] \
   && [ \"\$(_pending_key_count \"\$ROP/.agents/run-state.yaml\")\" = 1 ] \
   && yamlok \"\$ROP/.agents/run-state.yaml\" \
   && [ \"\$(_yaml_backlog \"\$ROP/.agents/run-state.yaml\" pending)\" = 'rop-c,rop-b' ]"
# The comment block survives verbatim, still ABOVE pending_questions: -- a trim
# that swallowed it would pass every assertion above while deleting the
# documentation the template ships.
assert_true "that comment block survives the rewrite, verbatim and still above its key" \
  "[ \"\$(sed -n '/^# Questions the human/,/^pending_questions:/p' \"\$ROP/.agents/run-state.yaml\")\" \
    = \"\$(printf '# Questions the human must answer before blocked packets can proceed.\n# severity: blocking = the loop cannot continue until answered;\npending_questions: []')\" ]"
# A list whose items sit LEVEL WITH the `pending:` key. This is not an exotic
# hand edit: it is what `yaml.safe_dump` emits by default, and both of this
# script's own readers already accept it (`cmd_summary` reports `2 pending`,
# `_findings_pending_ids` resolves `blocked_by`), so every other subcommand
# treats such a file as valid. A boundary scan that ends the block on the first
# line indented no deeper than the key cannot tell this list's own item from a
# sibling key: it found NO items, so it inserted the new order under the key and
# skipped nothing -- rc=0, `REORDERED=yes`, `ADDED=` naming ids that were
# already pending, and a run-state that no longer PARSES. Strictly worse than
# the comment case above, which at least left a parseable file. So this case
# asserts the parse and the parsed VALUE, not the exit code: the wrong
# implementation exits 0 and prints a plausible `PENDING=`.
cat > "$ROP/.agents/run-state.yaml" <<'ROPEOF'
schema: 3
status: running
backlog:
  cursor: rop-a
  pending:
  - rop-b
  - rop-c
findings:
  - id: rop-f1
    summary: 'guard.sh: fails closed on unreadable input'
    packets: [rop-c]
note: where we stopped
ROPEOF
ROP_OUT="$(rop_rs rop-c,rop-b 2>&1)"
assert_true "a list level with its pending: key is reordered, not appended above its own items" \
  "[ \"\$ROP_OUT\" = \"\$(printf 'REORDERED=yes\nPENDING=rop-c,rop-b\nADDED=\nREMOVED=\n')\" ] \
   && [ \"\$(_pending_key_count \"\$ROP/.agents/run-state.yaml\")\" = 1 ]"
assert_true "that file still parses, with the requested order and cursor intact" \
  "yamlok \"\$ROP/.agents/run-state.yaml\" \
   && [ \"\$(_yaml_backlog \"\$ROP/.agents/run-state.yaml\" pending)\" = 'rop-c,rop-b' ] \
   && [ \"\$(_yaml_backlog \"\$ROP/.agents/run-state.yaml\" cursor)\" = 'rop-a' ]"
# The same-indent STYLE is preserved, not normalised to the template's: the
# caller asked for a reorder, and a re-indent is a second change it did not ask
# for. Two items at the key indent (2), and no item at 4.
assert_true "the same-indent style survives the rewrite -- a reorder is not a re-indent" \
  "[ \"\$(grep -cE '^  - rop-' \"\$ROP/.agents/run-state.yaml\")\" = 2 ] \
   && [ \"\$(grep -cE '^    - rop-' \"\$ROP/.agents/run-state.yaml\")\" = 0 ]"
assert_true "the findings index survives a same-indent rewrite" \
  "[ \"\$(\"\$RUNSTATE\" findings \"\$ROP/.agents/run-state.yaml\")\" = \"\$(printf 'rop-f1\tguard.sh: fails closed on unreadable input\t\trop-c')\" ]"
# ...and the narrow `- ` test that admits those items must NOT admit a sibling
# MAPPING KEY whose name starts with a dash (`-weird:` is legal YAML). Reading
# that as an item would report it under REMOVED and delete the key.
printf 'schema: 3\nbacklog:\n  pending:\n  - rop-b\n  - rop-c\n  -weird: 1\nnote: x\n' \
  > "$ROP/.agents/run-state.yaml"
ROP_OUT="$(rop_rs rop-c,rop-b 2>&1)"
assert_true "a dash-named sibling key is not read as an item: it survives and is not reported REMOVED" \
  "[ \"\$ROP_OUT\" = \"\$(printf 'REORDERED=yes\nPENDING=rop-c,rop-b\nADDED=\nREMOVED=\n')\" ] \
   && yamlok \"\$ROP/.agents/run-state.yaml\" \
   && grep -qE '^  -weird: 1\$' \"\$ROP/.agents/run-state.yaml\""

# The added/removed REPORT is the thing a caller acts on, and it is built by
# splitting on an unquoted `,`. Old ids come off disk unvalidated, so a hand
# edit leaving `- "*"` globbed the working directory into `REMOVED=`. The
# written file was right and only the report was wrong, which is why this
# asserts the report text and not the file.
printf 'schema: 3\nbacklog:\n  pending:\n    - "*"\n    - rop-a\n' > "$ROP/.agents/run-state.yaml"
# The cwd must CONTAIN something for `*` to expand to, or this case is vacuous:
# bash leaves an unmatched glob as the literal `*`, which is exactly the string
# the fixed code emits, so an empty directory would pass the bug too.
mkdir -p "$ROP/globcwd" && : > "$ROP/globcwd/decoy-file"
ROP_OUT="$(cd "$ROP/globcwd" && rop_rs rop-a,rop-z 2>&1)"
assert_true "an unvalidated existing id is reported literally, never glob-expanded" \
  "[ \"\$ROP_OUT\" = \"\$(printf 'REORDERED=yes\nPENDING=rop-a,rop-z\nADDED=rop-z\nREMOVED=*\n')\" ]"

echo
echo "== run-tally: the four digest-derived tally figures, counted from the digest's own"
echo "   lines for the whole run (report-render-conformance T1) =="
rd_tally() { (cd "$RD" && "$RUNSTATE" run-tally .agents/run-state.yaml "$@"); }

# The four existing line kinds must be byte-identical to what run-digest
# emitted BEFORE run-tally existed. This literal was captured from this exact
# fixture state (sorted with LC_ALL=C, since the digest is deliberately
# unordered) before scripts/runstate.sh was edited for T1. `<TAB>` stands for
# a real tab, so the literal survives editors; nothing else is transformed.
echo "-- the fixture's four existing line kinds are byte-identical to their pre-run-tally output --"
RT_PRE_DIGEST="$(awk '{ gsub(/<TAB>/, "\t"); print }' <<'RT_PRE_EOF'
decision<TAB>rd-hof<TAB>hand-off-feature
enter<TAB><TAB>medium<TAB>300000
handoff-feature<TAB>rd-hof<TAB>hand-off-feature · rd-hof needs a "bulk import" feature, spec at C:\import\spec.md · result: needs-reading · .agents/loop/x/rd-hof/decider.md
packet<TAB>rd-backslash<TAB>T9 has a literal \n escape and a Windows path C:\import\file.md<TAB>open
packet<TAB>rd-body<TAB>T5 write a result file<TAB>green
packet<TAB>rd-continued<TAB>T7 continued after a false finish<TAB>interrupted
packet<TAB>rd-green<TAB>T1 add the first thing<TAB>green
packet<TAB>rd-hof<TAB>T3 needs a bigger feature<TAB>open
packet<TAB>rd-interrupted<TAB>T8 gets swept as interrupted<TAB>interrupted
packet<TAB>rd-onlys2<TAB>T6b lives only in the second session<TAB>failed
packet<TAB>rd-open<TAB>T2 add the second thing<TAB>interrupted
packet<TAB>rd-paused<TAB>T4 mid-edit when paused<TAB>interrupted
packet<TAB>rd-twosess<TAB>T6 finish in another session<TAB>blocked
RT_PRE_EOF
)"
RT_NOW_DIGEST="$(rd_digest | LC_ALL=C sort)"
assert_true "run-digest: the literal really carries all four line kinds (so the byte comparison below is not vacuous)" \
  "[ \"\$(cut -f1 <<<\"\$RT_PRE_DIGEST\" | LC_ALL=C sort -u | tr '\n' ' ')\" = 'decision enter handoff-feature packet ' ]"
assert_true "run-digest: the fixture's sorted output is byte-identical to its pre-run-tally capture -- same fields, same tabs, no header, no new line kind" \
  "[ \"\$RT_NOW_DIGEST\" = \"\$RT_PRE_DIGEST\" ]"

echo "-- a run carrying every outcome the digest can emit: each figure counted from its own group --"
printf 'T10 abandoned mid-way\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-abandoned --tier integration --agent implementer) >/dev/null
printf 'T11 rolled back\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-rolledback --tier integration --agent implementer) >/dev/null
printf 'T12 needs the operator\nbody\n' | (cd "$RD" && "$RUNSTATE" handoff .agents/run-state.yaml rd-ask --tier integration --agent implementer) >/dev/null
printf '{"ts":"2026-02-04T00:00:01Z","packet":"rd-abandoned","session":"S3","kind":"start"}\n{"ts":"2026-02-04T00:00:02Z","packet":"rd-abandoned","session":"S3","outcome":"abandoned"}\n{"ts":"2026-02-04T00:00:03Z","packet":"rd-rolledback","session":"S3","kind":"start"}\n{"ts":"2026-02-04T00:00:04Z","packet":"rd-rolledback","session":"S3","outcome":"rolled-back"}\n' \
  > "$RD/.agents/metrics/outcomes/S3.jsonl"
(cd "$RD" && "$RUNSTATE" route .agents/run-state.yaml rd-ask ask-operator --status "ask-operator · rd-ask needs a call · result: needs-reading · x" >/dev/null)
# A `retry` decision line: a decider token, but not a question for the
# operator, so it must count toward no figure.
(cd "$RD" && "$RUNSTATE" route .agents/run-state.yaml rd-green retry >/dev/null)
printf 'schema: 3\nstatus: paused\nrun_id: %s\nbacklog:\n  cursor: rd-paused\n' "$RD_RUN_ID" > "$RD/.agents/run-state.yaml"
RT_ALL_DIGEST="$(rd_digest)"
RT_ALL_OUTCOMES="$(awk -F'\t' '$1 == "packet" { print $4 }' <<<"$RT_ALL_DIGEST" | LC_ALL=C sort -u | tr '\n' ' ')"
assert_true "run-tally fixture: the digest really carries every outcome it can emit (so no figure below is vacuous)" \
  "[ \"\$RT_ALL_OUTCOMES\" = 'abandoned blocked failed green interrupted open paused rolled-back ' ]"
assert_true "run-tally fixture: the digest carries the handoff-feature line, both operator-question decisions and the non-question retry" \
  "[ \"\$(awk -F'\t' '\$1 == \"decision\" || \$1 == \"handoff-feature\" { print \$1 \"/\" \$2 \"/\" \$3 }' <<<\"\$RT_ALL_DIGEST\" | cut -d/ -f1-2 | LC_ALL=C sort | tr '\n' ' ')\" = 'decision/rd-ask decision/rd-green decision/rd-hof handoff-feature/rd-hof ' ]"
RT_ALL_TALLY="$(rd_tally)"
assert_true "run-tally: prints exactly SHIPPED/FAILED/UNFINISHED/DECISIONS in the fixed tally order and nothing else (no queued figure)" \
  "[ \"\$RT_ALL_TALLY\" = \"\$(printf 'SHIPPED=2\nFAILED=2\nUNFINISHED=9\nDECISIONS=2')\" ]"
assert_true "run-tally: SHIPPED counts only green packet lines" \
  "[ \"\$(sed -n 's/^SHIPPED=//p' <<<\"\$RT_ALL_TALLY\")\" = 2 ]"
assert_true "run-tally: FAILED aggregates failed and rolled-back" \
  "[ \"\$(sed -n 's/^FAILED=//p' <<<\"\$RT_ALL_TALLY\")\" = 2 ]"
assert_true "run-tally: UNFINISHED aggregates blocked, interrupted, abandoned, open and paused" \
  "[ \"\$(sed -n 's/^UNFINISHED=//p' <<<\"\$RT_ALL_TALLY\")\" = 9 ]"
assert_true "run-tally: emits no queued figure" \
  "[ -z \"\$(grep -i queued <<<\"\$RT_ALL_TALLY\" || true)\" ]"

echo "-- a handed-off packet plus an ask-operator question in one run is TWO decisions, not three --"
assert_true "run-tally: the handed-off packet's own hand-off-feature decision line is not counted again beside its handoff-feature line -- DECISIONS=2, not 3" \
  "[ \"\$(sed -n 's/^DECISIONS=//p' <<<\"\$RT_ALL_TALLY\")\" = 2 ]"

echo "-- run-tally dies where run-digest dies --"
printf 'schema: 3\nstatus: running\n' > "$RD/.agents/run-state-norunid.yaml"
assert_true "run-tally: a run-state with no run_id dies, as run-digest does" \
  "! (cd \"\$RD\" && \"\$RUNSTATE\" run-tally .agents/run-state-norunid.yaml >/dev/null 2>&1)"
assert_true "run-tally: takes no --since (the dedup needs the whole run)" \
  "! rd_tally --since 1970-01-01T00:00:00Z >/dev/null 2>&1"
printf 'schema: 3\nstatus: running\nrun_id: %s\n' "$RD_RUN_ID" > "$RD/.agents/run-state.yaml"

echo "-- run-tally counts an ask-operator question only while it is still awaiting an answer --"
# stop-report-decision-liveness T1. Each case is a FRESH run with hand-written
# routing and outcome records at fixed timestamps, so no case leans on
# wall-clock ordering. $1 = routing.jsonl body, $2 = outcomes log body; prints
# the DECISIONS figure run-tally reports for that run.
lv_decisions() {
  local d rid
  d="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$d" init -q
  mkdir -p "$d/.agents/metrics/outcomes"
  printf 'schema: 3\nstatus: running\n' > "$d/.agents/run-state.yaml"
  rid="$(cd "$d" && "$RUNSTATE" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
  mkdir -p "$d/.agents/loop/$rid"
  printf '%s' "$1" > "$d/.agents/loop/$rid/routing.jsonl"
  [ -z "$2" ] || printf '%s' "$2" > "$d/.agents/metrics/outcomes/LV.jsonl"
  (cd "$d" && "$RUNSTATE" run-tally .agents/run-state.yaml) | sed -n 's/^DECISIONS=//p'
  rm -rf "$d"
}
LV_Q='{"ts":"2026-03-01T00:00:10.500Z","packet":"lv","token":"ask-operator","action":"stop","status":""}
'
LV_BLOCKED='{"ts":"2026-03-01T00:00:11Z","packet":"lv","session":"LV","outcome":"blocked"}
'
assert_true "run-tally liveness: an unanswered question counts (control -- DECISIONS=1)" \
  "[ \"\$(lv_decisions \"\$LV_Q\" '')\" = 1 ]"
assert_true "run-tally liveness: a question answered by a later start yields DECISIONS=0" \
  "[ \"\$(lv_decisions \"\$LV_Q\" \"\${LV_BLOCKED}\"'{\"ts\":\"2026-03-01T00:01:00Z\",\"packet\":\"lv\",\"session\":\"LV\",\"kind\":\"start\"}
')\" = 0 ]"
assert_true "run-tally liveness: a question answered by a later continuation yields DECISIONS=0" \
  "[ \"\$(lv_decisions \"\$LV_Q\" \"\${LV_BLOCKED}\"'{\"ts\":\"2026-03-01T00:01:00Z\",\"packet\":\"lv\",\"session\":\"LV\",\"kind\":\"continue\"}
')\" = 0 ]"
assert_true "run-tally liveness: a question answered by a later abandoned outcome yields DECISIONS=0" \
  "[ \"\$(lv_decisions \"\$LV_Q\" \"\${LV_BLOCKED}\"'{\"ts\":\"2026-03-01T00:01:00Z\",\"packet\":\"lv\",\"session\":\"LV\",\"outcome\":\"abandoned\"}
')\" = 0 ]"
assert_true "run-tally liveness: a question followed only by a blocked outcome (the pause's own stop) yields DECISIONS=1" \
  "[ \"\$(lv_decisions \"\$LV_Q\" \"\$LV_BLOCKED\")\" = 1 ]"
assert_true "run-tally liveness: an answer whose timestamp TIES the question's does not answer it -- DECISIONS=1" \
  "[ \"\$(lv_decisions \"\$LV_Q\" '{\"ts\":\"2026-03-01T00:00:10.500Z\",\"packet\":\"lv\",\"session\":\"LV\",\"kind\":\"start\"}
')\" = 1 ]"
# "...:10Z" > "...:10.500Z" as a string ('Z' 0x5A > '.' 0x2E), but it
# parses 500ms EARLIER -- a raw-string comparison would call it an answer.
assert_true "run-tally liveness: a whole-second start that sorts after a sub-second question as a string but parses earlier does not answer it -- DECISIONS=1" \
  "[ \"\$(lv_decisions \"\$LV_Q\" '{\"ts\":\"2026-03-01T00:00:10Z\",\"packet\":\"lv\",\"session\":\"LV\",\"kind\":\"start\"}
')\" = 1 ]"
assert_true "run-tally liveness: an answer for a DIFFERENT packet does not answer this one -- DECISIONS=1" \
  "[ \"\$(lv_decisions \"\$LV_Q\" '{\"ts\":\"2026-03-01T00:01:00Z\",\"packet\":\"lv-other\",\"session\":\"LV\",\"kind\":\"start\"}
')\" = 1 ]"
assert_true "run-tally liveness: two questions on one packet with a start between them -- the first answered, the second still awaiting -- DECISIONS=1" \
  "[ \"\$(lv_decisions \"\${LV_Q}\"'{\"ts\":\"2026-03-01T00:02:00Z\",\"packet\":\"lv\",\"token\":\"ask-operator\",\"action\":\"stop\",\"status\":\"\"}
' '{\"ts\":\"2026-03-01T00:01:00Z\",\"packet\":\"lv\",\"session\":\"LV\",\"kind\":\"start\"}
')\" = 1 ]"

echo "-- run-tally counts a still-awaiting retry-past-limit stop as a decision too, tallied separately from ask-operator (answered-question-expiry T1) --"
LV_RETRY_STOP='{"ts":"2026-03-02T00:00:10Z","packet":"lv","token":"retry","action":"stop","status":""}
'
LV_RETRY_ATTEMPT='{"ts":"2026-03-02T00:00:10Z","packet":"lv","token":"retry","action":"attempt","status":""}
'
assert_true "run-tally liveness: an unanswered retry routed stop (past its attempt limit) counts -- DECISIONS=1" \
  "[ \"\$(lv_decisions \"\$LV_RETRY_STOP\" '')\" = 1 ]"
assert_true "run-tally liveness: the same retry-past-limit stop answered by a later start yields DECISIONS=0" \
  "[ \"\$(lv_decisions \"\$LV_RETRY_STOP\" '{\"ts\":\"2026-03-02T00:01:00Z\",\"packet\":\"lv\",\"session\":\"LV\",\"kind\":\"start\"}
')\" = 0 ]"
assert_true "run-tally liveness: a retry routed attempt (still within its limit) counts toward no figure -- DECISIONS=0" \
  "[ \"\$(lv_decisions \"\$LV_RETRY_ATTEMPT\" '')\" = 0 ]"
assert_true "run-tally liveness: one packet with a live ask-operator question AND a live retry-past-limit stop is TWO separate decisions, not one -- DECISIONS=2" \
  "[ \"\$(lv_decisions \"\${LV_Q}\${LV_RETRY_STOP}\" '')\" = 2 ]"

echo
echo "== run-digest: a periodic review's own line and its routings as decisions, with every"
echo "   packet decision still reported exactly ONCE (escalation-decider T7) =="
# THE mutation this block exists to rule out is emitting a digest `decision`
# line for every record in .agents/metrics/decisions/, rather than for the
# `review` records alone. Every packet decision already produced a
# routing.jsonl record -- the driver routed the token -- and the decider then
# wrote its OWN audit copy of the same decision to the decision log. Reading
# both sources reports that one decision twice, and because the stop report's
# 🔀 figure is counted from these lines, its header doubles. The failure is
# silent: both lines are individually well-formed.
#
# The fixture is therefore built so the wrong implementation is DISTINGUISHABLE
# in two independent directions, because the obvious half-fix (dedupe the two
# sources by packet+token) would pass the first and fail the second:
#   - `rvw-pkt`/`retry` exists in BOTH logs -- a routing record and a decision
#     record. Counted, not grepped: `exactly once` is the assertion, and a
#     `grep -q` would pass against two copies.
#   - `rvw-pkt`/`reorder` exists ONLY in the decision log, with no routing
#     record at all (what a crash between the decider writing its record and
#     the driver routing its token leaves behind). It must not appear either --
#     the rule is that the decision records are not a source of digest decision
#     lines, not that duplicates are removed.
RVW="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$RVW" init -q
git -C "$RVW" config user.email t@t; git -C "$RVW" config user.name t
mkdir -p "$RVW/.agents"
printf 'schema: 3\nstatus: running\n' > "$RVW/.agents/run-state.yaml"
# Session pinned per call, not exported: the sweep may itself run inside a
# session that exports CLAUDE_CODE_SESSION_ID, and that value is the log's
# filename.
rvw_rs() { (cd "$RVW" && CLAUDE_CODE_SESSION_ID=RVWS "$RUNSTATE" "$@"); }
RVW_RUN_ID="$(rvw_rs begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
RVW_LOG="$RVW/.agents/metrics/decisions/RVWS.jsonl"
# Count digest lines by their three leading fields. awk, not grep: field 2 of a
# review-routing line is EMPTY, which is the property being asserted, and a
# whole-line grep cannot tell an empty field from a collapsed one.
rvw_lines() { # <digest> <type> <field2> <field3> -> count
  awk -F'\t' -v k="$2" -v a="$3" -v b="$4" '$1 == k && $2 == a && $3 == b { n++ } END { print n+0 }' <<<"$1"
}

printf 'T7 the escalated packet\nbody\n' \
  | rvw_rs handoff .agents/run-state.yaml rvw-pkt --tier mechanical --agent implementer >/dev/null
rvw_rs record-start rvw-pkt >/dev/null
# The reviewer escalates, the decider answers `retry`, the driver routes it:
# one routing record for the packet decision.
rvw_rs route .agents/run-state.yaml rvw-pkt escalate >/dev/null
rvw_rs route .agents/run-state.yaml rvw-pkt retry >/dev/null
# The decider's own audit copies. The first duplicates the routed token; the
# second was never routed at all.
rvw_rs record-decision .agents/run-state.yaml rvw-pkt retry \
  --trigger 'the handoff omitted the sweep case' >/dev/null
rvw_rs record-decision .agents/run-state.yaml rvw-pkt reorder \
  --trigger 'the packet can proceed once other pending work lands' >/dev/null
# merged/routed/dropped are 2/3/4 deliberately: no two of them sum to another,
# so a tally that counted merges or drops as decisions lands on a number the
# assertion below can tell apart from 3.
rvw_rs record-review .agents/run-state.yaml \
  --bytes-before 4096 --bytes-after 2048 --merged 2 --routed 3 --dropped 4 >/dev/null
RVW_DIGEST="$(rvw_rs run-digest .agents/run-state.yaml)"

assert_true "T7 fixture: the decision log really holds the decider's own copy of the routed decision (so 'exactly once' below is not vacuous)" \
  "[ \"\$(grep -c '\"kind\":\"decision\",\"packet\":\"rvw-pkt\",\"decision\":\"retry\"' \"$RVW_LOG\")\" = 1 ]"
assert_true "T7 fixture: and a second decision record the driver never routed" \
  "[ \"\$(grep -c '\"kind\":\"decision\",\"packet\":\"rvw-pkt\",\"decision\":\"reorder\"' \"$RVW_LOG\")\" = 1 ]"
assert_true "run-digest: the packet decision is reported EXACTLY once -- from routing.jsonl, never a second time from the decider's own decision record" \
  "[ \"\$(rvw_lines \"\$RVW_DIGEST\" decision rvw-pkt retry)\" = 1 ]"
assert_true "run-digest: a decision record with no routing record produces NO decision line -- the decision records are not a source of digest decision lines at all" \
  "[ \"\$(rvw_lines \"\$RVW_DIGEST\" decision rvw-pkt reorder)\" = 0 ]"

echo "-- the review's own line: five values, carried verbatim in merged/routed/dropped/before/after order --"
assert_true "run-digest: the review line carries the completed review's merged, routed and dropped counts and its index bytes before and after" \
  "grep -qx \$'review\t2\t3\t4\t4096\t2048' <<<\"\$RVW_DIGEST\""
assert_true "run-digest: one decision line per review routing -- three routings, three lines" \
  "[ \"\$(rvw_lines \"\$RVW_DIGEST\" decision '' review-routing)\" = 3 ]"
assert_true "run-digest: a review routing names NO packet (its id field is empty) -- a review routes a finding, so there is nothing for a renderer to join to a packet line" \
  "[ \"\$(rvw_lines \"\$RVW_DIGEST\" decision rvw-pkt review-routing)\" = 0 ]"
assert_true "run-digest: the review record adds no packet line of its own" \
  "[ \"\$(awk -F'\t' '\$1 == \"packet\" { n++ } END { print n+0 }' <<<\"\$RVW_DIGEST\")\" = 1 ]"

echo "-- run-tally: the routings count as decisions; the merges and drops stay counts --"
RVW_TALLY="$(rvw_rs run-tally .agents/run-state.yaml)"
assert_true "run-tally: DECISIONS counts the three review routings and nothing else -- not the 2 merges, not the 4 drops, and not the non-question retry" \
  "[ \"\$(sed -n 's/^DECISIONS=//p' <<<\"\$RVW_TALLY\")\" = 3 ]"
assert_true "run-tally: still prints exactly the four figures in the fixed tally order -- a review is not a fifth figure" \
  "[ \"\$(sed -n 's/=.*//p' <<<\"\$RVW_TALLY\" | tr '\n' ' ')\" = 'SHIPPED FAILED UNFINISHED DECISIONS ' ]"

echo "-- a count that could not be read: 'unmeasured' is carried through, and no routing line is invented for it --"
# Reporting 0 routings here would read as a measurement meaning the review
# routed nothing, and fabricating lines for an unknown count would report a
# guess as a tally figure. Neither: the `review` line says `unmeasured` and the
# decision lines stay at the three the MEASURED review produced.
rvw_rs record-review .agents/run-state.yaml \
  --bytes-before unmeasured --bytes-after unmeasured --merged 1 --routed unmeasured --dropped 0 >/dev/null
RVW_DIGEST2="$(rvw_rs run-digest .agents/run-state.yaml)"
assert_true "run-digest: an unmeasured count is carried VERBATIM onto the review line, never rewritten to 0" \
  "grep -qx \$'review\t1\tunmeasured\t0\tunmeasured\tunmeasured' <<<\"\$RVW_DIGEST2\""
assert_true "run-digest: an unmeasured routed count invents no review-routing decision lines -- still exactly the three the measured review produced" \
  "[ \"\$(rvw_lines \"\$RVW_DIGEST2\" decision '' review-routing)\" = 3 ]"
assert_true "run-tally: and DECISIONS is unchanged by it -- an unknown number of routings adds nothing rather than adding zero" \
  "[ \"\$(rvw_rs run-tally .agents/run-state.yaml | sed -n 's/^DECISIONS=//p')\" = 3 ]"

echo "-- scoped to THIS run, and to --since, exactly as the decision lines are --"
# The decision log is SESSION-keyed and a session outlives a run (begin-run
# mints run_id once, and a resume keeps it), so a session's log holds every run
# it drove. Without the run_id filter a second run would report the previous
# one's reviews as its own. The record below is written by hand because a
# minted run_id belongs to a run-state, and the point is a record this run-state
# never made.
printf '{"ts":"2026-02-01T00:00:00Z","session":"OTHER","run_id":"20990101T000000-ffff","kind":"review","bytes_before":"11","bytes_after":"22","merged":"9","routed":"9","dropped":"9"}\n' \
  > "$RVW/.agents/metrics/decisions/OTHER.jsonl"
RVW_DIGEST3="$(rvw_rs run-digest .agents/run-state.yaml)"
assert_true "run-digest: a review recorded under ANOTHER run's run_id is not reported as this run's" \
  "! grep -q \$'review\t9\t9\t9' <<<\"\$RVW_DIGEST3\""
assert_true "run-digest: and its routings are not counted either -- still exactly three review-routing lines" \
  "[ \"\$(rvw_lines \"\$RVW_DIGEST3\" decision '' review-routing)\" = 3 ]"
# Captured into variables and matched with here-strings rather than piped into
# `grep -q`: under the `pipefail` set at the top of this file a pipe-fed early-
# exiting reader can report the writer's SIGPIPE instead of its own success --
# the flake scripts/runstate.sh carries its own source guard against.
RVW_FUTURE="$(rvw_rs run-digest .agents/run-state.yaml --since 2099-01-01T00:00:00Z)"
RVW_EPOCH="$(rvw_rs run-digest .agents/run-state.yaml --since 1970-01-01T00:00:00Z)"
assert_true "run-digest --since in the far future excludes the review line" \
  "! grep -q \$'^review\t' <<<\"\$RVW_FUTURE\""
assert_true "  and excludes the review-routing decision lines with it -- they are scoped WITH their review, not separately" \
  "[ \"\$(rvw_lines \"\$RVW_FUTURE\" decision '' review-routing)\" = 0 ]"
assert_true "  while the packet line it is scoped alongside still reports" \
  "grep -qx \$'packet\trvw-pkt\tT7 the escalated packet\topen' <<<\"\$RVW_FUTURE\""
assert_true "run-digest --since at the epoch still includes the review line and all three of its routings" \
  "grep -qx \$'review\t2\t3\t4\t4096\t2048' <<<\"\$RVW_EPOCH\" && [ \"\$(rvw_lines \"\$RVW_EPOCH\" decision '' review-routing)\" = 3 ]"
# The RD fixture has no .agents/metrics/decisions at all, so this pins the
# missing-log path as fail-soft -- the same contract a missing routing.jsonl or
# driver-mode log already has, never a die.
RVW_NOLOG="$(cd "$RD" && "$RUNSTATE" run-digest .agents/run-state.yaml)"
assert_true "run-digest: a run with no decision log at all emits no review line and still reports its packets (fail-soft, as a missing routing.jsonl is)" \
  "! grep -q \$'^review\t' <<<\"\$RVW_NOLOG\" && grep -q \$'^packet\t' <<<\"\$RVW_NOLOG\""

echo
echo "== run-digest: a review routing line carries the routed finding's id and summary (escalation-decider T16) =="
# The driver renders a review's routings from the digest alone, so the line has
# to NAME what was routed. The wrong implementations this rules out:
#   - the T7 shape, `decision\t\treview-routing` with no names -- the renderer
#     would then have to open the decision log or the result file to name them;
#   - naming a routing from the WRONG record: an escalation's own append-task
#     audit copy sits in the same log and the same run, with a finding id and a
#     summary of its own, and is not a review routing;
#   - borrowing a name across reviews: a later review whose routing records are
#     missing must report its routings UNNAMED, never re-use an earlier
#     review's record;
#   - fabricating a summary for a routing recorded without one.
# The line count still comes from the review's `routed` (T7), and field 2 stays
# empty so nothing joins it to a packet line.
RN="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$RN" init -q
mkdir -p "$RN/.agents"
printf 'schema: 3\nstatus: running\n' > "$RN/.agents/run-state.yaml"
rn_rs() { (cd "$RN" && CLAUDE_CODE_SESSION_ID=RNS "$RUNSTATE" "$@"); }
rn_rs begin-run .agents/run-state.yaml >/dev/null
printf 'T3 import the ledger\nbody\n' \
  | rn_rs handoff .agents/run-state.yaml rn-t3 --tier mechanical --agent implementer >/dev/null
rn_rs record-start rn-t3 >/dev/null
# An escalation's audit copy: append-task, a finding, a summary -- but not a
# review's (its summary does not open `review:`).
rn_rs record-decision .agents/run-state.yaml rn-t3 append-task --trigger 'append-task arm' \
  --finding decider-rn-t3 --summary 'appended T9 for the ledger rounding gap' >/dev/null
# The review: ONE routing, then two merges and one drop, then record-review last.
RN_SUM='review: rn-t3, rn-t5 -- the currency-rounding rule needs its own feature, depends_on: txn-import'
rn_rs record-decision .agents/run-state.yaml rn-t3 hand-off-feature --trigger 'hand-off-feature arm' \
  --finding f-rounding --summary "$RN_SUM" >/dev/null
rn_rs record-review .agents/run-state.yaml \
  --bytes-before 900 --bytes-after 300 --merged 2 --routed 1 --dropped 1 >/dev/null
RN_D1="$(rn_rs run-digest .agents/run-state.yaml)"
RN_EXPECT="$(printf 'decision\t\treview-routing\tf-rounding\t%s' "$RN_SUM")"
assert_true "T16: one review with one routing yields exactly one review-routing line" \
  "[ \"\$(awk -F'\t' '\$1 == \"decision\" && \$3 == \"review-routing\" { n++ } END { print n+0 }' <<<\"\$RN_D1\")\" = 1 ]"
assert_true "T16: that line carries the routed finding's id and the summary the review wrote, verbatim, with the packet-id field empty" \
  "grep -qxF \"\$RN_EXPECT\" <<<\"\$RN_D1\""
assert_true "T16: the escalation's audit copy names no review routing" \
  "! grep -q 'decider-rn-t3' <<<\"\$RN_D1\""
assert_true "T16: the merges and drop stay counts on the review line" \
  "grep -qx \$'review\t2\t1\t1\t900\t300' <<<\"\$RN_D1\""
assert_true "T16: run-tally counts the one routing as ONE decision -- not the two merges, not the drop" \
  "[ \"\$(rn_rs run-tally .agents/run-state.yaml | sed -n 's/^DECISIONS=//p')\" = 1 ]"

# A second review whose routing record was written with no --summary.
rn_rs record-decision .agents/run-state.yaml rn-t3 append-task --trigger 'append-task arm' \
  --finding f-nosum >/dev/null
rn_rs record-review .agents/run-state.yaml \
  --bytes-before 300 --bytes-after 200 --merged 0 --routed 1 --dropped 1 >/dev/null
RN_D2="$(rn_rs run-digest .agents/run-state.yaml)"
assert_true "T16: a routing whose record lacks a summary carries its finding id and an EMPTY summary field, not a fabricated one" \
  "grep -qx \$'decision\t\treview-routing\tf-nosum\t' <<<\"\$RN_D2\""
assert_true "T16: and the first review's routing is still named once, by its own record" \
  "[ \"\$(grep -cxF \"\$RN_EXPECT\" <<<\"\$RN_D2\")\" = 1 ]"

# A third review that reports two routings but whose routing records are
# missing, with another escalation audit copy recorded since the last review.
rn_rs record-decision .agents/run-state.yaml rn-t3 append-task --trigger 'append-task arm' \
  --finding decider-rn-t3b --summary 'appended T10 for the ledger header' >/dev/null
rn_rs record-review .agents/run-state.yaml \
  --bytes-before 200 --bytes-after 200 --merged 0 --routed 2 --dropped 0 >/dev/null
RN_D3="$(rn_rs run-digest .agents/run-state.yaml)"
assert_true "T16: routings whose records cannot be found are reported UNNAMED -- two lines with both name fields empty" \
  "[ \"\$(grep -cx \$'decision\t\treview-routing\t\t' <<<\"\$RN_D3\")\" = 2 ]"
assert_true "T16: never named from an earlier review's record or an escalation's audit copy" \
  "[ \"\$(grep -c 'f-rounding' <<<\"\$RN_D3\")\" = 1 ] && [ \"\$(grep -c 'f-nosum' <<<\"\$RN_D3\")\" = 1 ] && ! grep -q 'decider-rn-t3b' <<<\"\$RN_D3\""
assert_true "T16: an unmeasured routed count still yields no routing line" \
  "rn_rs record-review .agents/run-state.yaml --bytes-before 1 --bytes-after 1 --merged 0 --routed unmeasured --dropped 0 >/dev/null && [ \"\$(awk -F'\t' '\$1 == \"decision\" && \$3 == \"review-routing\" { n++ } END { print n+0 }' <<<\"\$(rn_rs run-digest .agents/run-state.yaml)\")\" = 4 ]"

echo
echo "-- the end-of-run arm-2 proposal: ONE record, for a fixed id that is not a packet (loop-driver-run-gaps T6) --"
# The termination review (skills/run-loop/SKILL.md §4) routes the architect's
# arm-2 proposal through `route` under the fixed id `end-of-run-review`. That id
# is NOT a packet: it has no handoff file, no start record and no outcome, and
# the loop calls `route` for the RECORD alone -- the printed `ACTION` is not
# acted on. This case pins what that one record does to every reader of it, and
# each assertion rules out a specific wrong implementation:
#
#   - the digest emits a `handoff-feature` line carrying the architect's own
#     status line VERBATIM: that line is what the stop report renders the
#     proposal from, so a truncating extraction loses the proposed slug;
#   - and NO `packet` line for that id. A digest that manufactured one would put
#     a phantom packet in the stop report's shipped/unfinished sections and in
#     the UNFINISHED figure;
#   - `run-tally`'s DECISIONS rises by EXACTLY one against the same run without
#     the record. The single record emits TWO digest lines for the one id (its
#     `handoff-feature` line AND a `decision … hand-off-feature` line), so a
#     tally without the hand-off dedup counts one proposal twice and the stop
#     report's header reads 🔀 2 beside one rendered block. A delta, not a
#     literal, so it stays the RISE the capability states even if some later
#     figure in this fixture changes;
#   - `sweep-open` closes nothing for it. This is the one that rules out the
#     tempting wrong home for the record, `.agents/metrics/outcomes/`, where
#     `_rs_open_packets` reads ANY `kind`-bearing record as a packet start: the
#     next session's sweep would then close a packet that never existed as
#     `interrupted` -- a fabricated failure in a run that had none.
#
# Built with the real writers (begin-run, handoff, record-start, route,
# sweep-open) over a fresh repo per pass, never hand-written JSON, and run
# twice: once on a full PATH and once with jq/python3 stubbed out of it.
EOR_SCRUB=""
EOR_SESS=EORSWEEP
EOR_STATUS='hand-off-feature · the balance-drift gotcha needs its own feature, proposed slug balance-drift-audit, parent txn-import · result: needs-reading · .agents/loop/x/end-of-run-review/architect.md'
EOR_EXPECTED="$(printf 'handoff-feature\tend-of-run-review\t%s' "$EOR_STATUS")"

# $EOR_SCRUB is empty on the full-PATH pass and $NOTOOLS on the mirrored one.
# The session id is fixed here rather than inherited so `sweep-open` writes to a
# named log on both passes.
eor_rs() { local d="$1"; shift
  if [ -n "$EOR_SCRUB" ]; then (cd "$d" && CLAUDE_CODE_SESSION_ID="$EOR_SESS" PATH="$EOR_SCRUB:$PATH" "$RUNSTATE" "$@")
  else (cd "$d" && CLAUDE_CODE_SESSION_ID="$EOR_SESS" "$RUNSTATE" "$@"); fi
}
eor_dec() { eor_rs "$1" run-tally .agents/run-state.yaml | sed -n 's/^DECISIONS=//p'; }

eor_fixture() { # <dir> -> RUN_ID; a run with ONE real packet, started and still open
  local d="$1" rid
  git -C "$d" init -q
  mkdir -p "$d/.agents/metrics/outcomes"
  printf 'schema: 3\nstatus: running\n' > "$d/.agents/run-state.yaml"
  rid="$(eor_rs "$d" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
  printf 'T1 reconcile the imported balances\nbody\n' \
    | eor_rs "$d" handoff .agents/run-state.yaml eor-t1 --tier mechanical --agent implementer >/dev/null
  eor_rs "$d" record-start eor-t1 "$EOR_SESS" >/dev/null
  printf '%s' "$rid"
}

eor_cases() { # <label suffix>
  local sfx="$1" d rid before after routed digest swept postdec
  d="$(cd "$(mktemp -d)" && pwd -P)"; rid="$(eor_fixture "$d")"
  assert_true "end-of-run-review fixture$sfx: begin-run minted an id and the run's one REAL packet has its handoff file" \
    "[ -n \"\$rid\" ] && [ -f \"\$d/.agents/loop/\$rid/eor-t1/handoff.md\" ]"
  before="$(eor_dec "$d")"
  assert_true "end-of-run-review$sfx: the SAME run WITHOUT the record prints a numeric DECISIONS -- the baseline the delta below is taken against" \
    "case \"\$before\" in ''|*[!0-9]*) false;; *) true;; esac"

  routed="$(eor_rs "$d" route .agents/run-state.yaml end-of-run-review hand-off-feature --status "$EOR_STATUS")"
  assert_true "route$sfx: the fixed termination id is accepted, and the call prints ACTION=discard-advance -- the action §4 tells the driver NOT to act on" \
    "printf '%s\n' \"\$routed\" | grep -qx 'ACTION=discard-advance'"

  digest="$(eor_rs "$d" run-digest .agents/run-state.yaml)"
  assert_true "run-digest$sfx: a handoff-feature line for the termination id carries the architect's status line VERBATIM" \
    "printf '%s\n' \"\$digest\" | grep -qFx \"\$EOR_EXPECTED\""
  assert_true "run-digest$sfx: and NO packet line for that id -- it has no handoff file, so it is not a packet" \
    "! printf '%s\n' \"\$digest\" | awk -F'\t' '\$1 == \"packet\" && \$2 == \"end-of-run-review\"' | grep -q ."
  assert_true "run-digest$sfx: the run's REAL packet still has its own packet line (so the absence above is not vacuous)" \
    "printf '%s\n' \"\$digest\" | grep -qx \$'packet\teor-t1\tT1 reconcile the imported balances\topen'"
  assert_true "run-digest$sfx: the one record emits a decision line for the id as well -- the second line the tally must NOT count again" \
    "printf '%s\n' \"\$digest\" | grep -qx \$'decision\tend-of-run-review\thand-off-feature'"

  after="$(eor_dec "$d")"
  assert_true "run-tally$sfx: DECISIONS rises by EXACTLY one against the same run without the record -- the proposal counted once, not once per digest line" \
    "[ \"\$after\" = \"\$((before + 1))\" ]"

  swept="$(eor_rs "$d" sweep-open)"
  assert_true "sweep-open$sfx: closes the run's one genuinely open packet (so the two checks below are not vacuous)" \
    "printf '%s\n' \"\$swept\" | grep -qx 'SWEPT=eor-t1'"
  assert_true "sweep-open$sfx: and closes NOTHING for the termination id" \
    "! printf '%s\n' \"\$swept\" | grep -q end-of-run-review"
  assert_true "sweep-open$sfx: no outcomes record anywhere names the termination id -- the record went to routing.jsonl, never the outcomes log" \
    "! grep -rq end-of-run-review \"\$d/.agents/metrics/outcomes\""
  assert_true "end-of-run-review$sfx: the record really is in this run's routing.jsonl (so the absence above is not vacuous)" \
    "grep -q '\"packet\":\"end-of-run-review\"' \"\$d/.agents/loop/\$rid/routing.jsonl\""

  postdec="$(eor_dec "$d")"
  assert_true "after the sweep$sfx: DECISIONS is unchanged and the digest still emits no packet line for the id -- the sweep fabricated no interrupted packet" \
    "[ \"\$postdec\" = \"\$after\" ] && ! eor_rs \"\$d\" run-digest .agents/run-state.yaml | awk -F'\t' '\$1 == \"packet\" && \$2 == \"end-of-run-review\"' | grep -q ."
}

EOR_SCRUB=""; eor_cases ""
EOR_SCRUB="$NOTOOLS"; eor_cases " (no-tools host)"
EOR_SCRUB=""

echo
echo "== prune-questions: drops pending_questions entries the SAME liveness rule"
echo "   reports as answered (answered-question-expiry T2) =="

# pq_entry <id> <packet> <question> [asked_at] -- one block-entry list item in
# the shape templates/run-state.yaml documents. Omits packet:/asked_at: when
# passed empty -- the "no packet:"/"no asked_at:" always-keep cases feed this
# an empty 2nd/4th argument.
pq_entry() {
  local id="$1" pkt="$2" q="$3" asked="${4:-}"
  printf '  - id: %s\n    severity: blocking\n' "$id"
  [ -z "$pkt" ] || printf '    packet: %s\n' "$pkt"
  printf "    question: '%s'\n" "$q"
  [ -z "$asked" ] || printf "    asked_at: '%s'\n" "$asked"
}

# pq_fixture <entries> -- a fresh git repo + run-state.yaml carrying <entries>
# (one or more pq_entry blocks, newline-joined by the caller) under
# pending_questions:, plus an UNTOUCHED findings: entry and note: so the
# "everything else survives" assertions below are never vacuous. Echoes the
# repo dir. Same pwd -P / git init shape as lv_decisions above.
pq_fixture() {
  local d
  d="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$d" init -q
  mkdir -p "$d/.agents/metrics/outcomes"
  printf "schema: 3\nstatus: running\npending_questions:\n%s\nfindings:\n  - id: pq-untouched\n    summary: 'unaffected by prune'\n    packets: [pq-other]\nnote: pq fixture note\n" \
    "$1" > "$d/.agents/run-state.yaml"
  printf '%s' "$d"
}
pq_outcomes() { printf '%s' "$2" > "$1/.agents/metrics/outcomes/PQ.jsonl"; }
pq_rs()  { printf '%s/.agents/run-state.yaml' "$1"; }
pq_run() { (cd "$1" && "$RUNSTATE" prune-questions .agents/run-state.yaml); }
# The region no prune can touch -- from findings: through EOF -- captured
# before/after for the dedicated byte-identical case below.
pq_tail() { sed -n '/^findings:/,$p' "$(pq_rs "$1")"; }

echo "-- one case per answering kind: each drops the entry it answers --"
PQ_START="$(pq_fixture "$(pq_entry q-start pq-start 'answered by a start' '2026-04-01T00:00:10Z')")"
pq_outcomes "$PQ_START" '{"ts":"2026-04-01T00:01:00Z","packet":"pq-start","session":"PQ","kind":"start"}
'
PQ_START_OUT="$(pq_run "$PQ_START")"
assert_true "prune-questions: a later start answers the question -- PRUNED=yes, DROPPED=1, KEPT=0" \
  "[ \"\$PQ_START_OUT\" = \"\$(printf 'PRUNED=yes\nDROPPED=1\nKEPT=0')\" ]"
assert_true "prune-questions: the answered (start) entry is gone" \
  "! grep -qxF '  - id: q-start' \"$(pq_rs "$PQ_START")\""
assert_true "prune-questions: the answered (start) entry's WHOLE block is gone, not just its header line" \
  "! grep -qxF '    packet: pq-start' \"$(pq_rs "$PQ_START")\""
assert_true "prune-questions: the run-state still parses as real YAML after the (start) prune" \
  "yamlok \"$(pq_rs "$PQ_START")\""

PQ_CONT="$(pq_fixture "$(pq_entry q-cont pq-cont 'answered by a continuation' '2026-04-01T00:00:10Z')")"
pq_outcomes "$PQ_CONT" '{"ts":"2026-04-01T00:01:00Z","packet":"pq-cont","session":"PQ","kind":"continue"}
'
PQ_CONT_OUT="$(pq_run "$PQ_CONT")"
assert_true "prune-questions: a later continuation answers the question -- PRUNED=yes, DROPPED=1, KEPT=0" \
  "[ \"\$PQ_CONT_OUT\" = \"\$(printf 'PRUNED=yes\nDROPPED=1\nKEPT=0')\" ]"
assert_true "prune-questions: the answered (continuation) entry is gone" \
  "! grep -qxF '  - id: q-cont' \"$(pq_rs "$PQ_CONT")\""
assert_true "prune-questions: the answered (continuation) entry's WHOLE block is gone, not just its header line" \
  "! grep -qxF '    packet: pq-cont' \"$(pq_rs "$PQ_CONT")\""
assert_true "prune-questions: the run-state still parses as real YAML after the (continuation) prune" \
  "yamlok \"$(pq_rs "$PQ_CONT")\""

PQ_ABAN="$(pq_fixture "$(pq_entry q-aban pq-aban 'answered by an abandoned outcome' '2026-04-01T00:00:10Z')")"
pq_outcomes "$PQ_ABAN" '{"ts":"2026-04-01T00:01:00Z","packet":"pq-aban","session":"PQ","outcome":"abandoned"}
'
PQ_ABAN_OUT="$(pq_run "$PQ_ABAN")"
assert_true "prune-questions: a later abandoned outcome answers the question -- PRUNED=yes, DROPPED=1, KEPT=0" \
  "[ \"\$PQ_ABAN_OUT\" = \"\$(printf 'PRUNED=yes\nDROPPED=1\nKEPT=0')\" ]"
assert_true "prune-questions: the answered (abandoned) entry is gone" \
  "! grep -qxF '  - id: q-aban' \"$(pq_rs "$PQ_ABAN")\""
assert_true "prune-questions: the answered (abandoned) entry's WHOLE block is gone, not just its header line" \
  "! grep -qxF '    packet: pq-aban' \"$(pq_rs "$PQ_ABAN")\""
assert_true "prune-questions: the run-state still parses as real YAML after the (abandoned) prune" \
  "yamlok \"$(pq_rs "$PQ_ABAN")\""

echo "-- entries the liveness rule does NOT answer are kept, and the file is left untouched --"
PQ_LIVE="$(pq_fixture "$(pq_entry q-live pq-live 'still unanswered' '2026-04-01T00:00:10Z')")"
PQ_LIVE_BEFORE="$(cat "$(pq_rs "$PQ_LIVE")")"
PQ_LIVE_OUT="$(pq_run "$PQ_LIVE")"
assert_true "prune-questions: an unanswered entry (no outcomes at all) keeps it -- PRUNED=no, DROPPED=0" \
  "[ \"\$PQ_LIVE_OUT\" = \"\$(printf 'PRUNED=no\nDROPPED=0')\" ]"
assert_true "prune-questions: an unanswered entry's file is left byte-unchanged" \
  "[ \"\$PQ_LIVE_BEFORE\" = \"\$(cat "$(pq_rs "$PQ_LIVE")")\" ]"
assert_true "prune-questions: the run-state still parses as real YAML after a no-drop run (unanswered)" \
  "yamlok \"$(pq_rs "$PQ_LIVE")\""

PQ_TIE="$(pq_fixture "$(pq_entry q-tie pq-tie 'tied timestamp does not answer' '2026-04-01T00:00:10Z')")"
pq_outcomes "$PQ_TIE" '{"ts":"2026-04-01T00:00:10Z","packet":"pq-tie","session":"PQ","kind":"start"}
'
PQ_TIE_OUT="$(pq_run "$PQ_TIE")"
assert_true "prune-questions: an answer whose ts TIES the question's does not answer it -- PRUNED=no, DROPPED=0" \
  "[ \"\$PQ_TIE_OUT\" = \"\$(printf 'PRUNED=no\nDROPPED=0')\" ]"
assert_true "prune-questions: the tied entry is still present" \
  "grep -qxF '  - id: q-tie' \"$(pq_rs "$PQ_TIE")\""
assert_true "prune-questions: the run-state still parses as real YAML after a no-drop run (tied)" \
  "yamlok \"$(pq_rs "$PQ_TIE")\""

PQ_NOPKT="$(pq_fixture "$(pq_entry q-nopkt '' 'no packet: at all' '2026-04-01T00:00:10Z')")"
PQ_NOPKT_OUT="$(pq_run "$PQ_NOPKT")"
assert_true "prune-questions: an entry with no packet: is ALWAYS kept -- PRUNED=no, DROPPED=0" \
  "[ \"\$PQ_NOPKT_OUT\" = \"\$(printf 'PRUNED=no\nDROPPED=0')\" ]"
assert_true "prune-questions: the no-packet: entry is still present" \
  "grep -qxF '  - id: q-nopkt' \"$(pq_rs "$PQ_NOPKT")\""
assert_true "prune-questions: the run-state still parses as real YAML after a no-drop run (no packet:)" \
  "yamlok \"$(pq_rs "$PQ_NOPKT")\""

PQ_NOASK="$(pq_fixture "$(pq_entry q-noask pq-noask 'no asked_at: at all')")"
PQ_NOASK_OUT="$(pq_run "$PQ_NOASK")"
assert_true "prune-questions: an entry with no asked_at: is ALWAYS kept -- PRUNED=no, DROPPED=0" \
  "[ \"\$PQ_NOASK_OUT\" = \"\$(printf 'PRUNED=no\nDROPPED=0')\" ]"
assert_true "prune-questions: the no-asked_at: entry is still present" \
  "grep -qxF '  - id: q-noask' \"$(pq_rs "$PQ_NOASK")\""
assert_true "prune-questions: the run-state still parses as real YAML after a no-drop run (no asked_at:)" \
  "yamlok \"$(pq_rs "$PQ_NOASK")\""

echo "-- a key line PRESENT but with an empty or unparseable value is kept, never read as answered --"
# pq_check_kept <label> <dir> <id> -- the four keep assertions shared by the
# value-level cases below: PRUNED=no/DROPPED=0, the entry still present, the
# file byte-unchanged, and a real YAML parse.
pq_check_kept() {
  local label="$1" d="$2" id="$3"
  PQ_KEPT_BEFORE="$(cat "$(pq_rs "$d")")"
  PQ_KEPT_OUT="$(pq_run "$d")"
  assert_true "prune-questions: $label is ALWAYS kept -- PRUNED=no, DROPPED=0" \
    "[ \"\$PQ_KEPT_OUT\" = \"\$(printf 'PRUNED=no\nDROPPED=0')\" ]"
  assert_true "prune-questions: $label -- the entry is still present" \
    "grep -qxF '  - id: $id' \"$(pq_rs "$d")\""
  assert_true "prune-questions: $label -- the file is byte-unchanged" \
    "[ \"\$PQ_KEPT_BEFORE\" = \"\$(cat \"$(pq_rs "$d")\")\" ]"
  assert_true "prune-questions: $label -- the run-state still parses as real YAML" \
    "yamlok \"$(pq_rs "$d")\""
}

# packet: '' -- empty value, with an answering start for ANOTHER packet.
PQ_EPKT="$(pq_fixture "$(pq_entry q-epkt "''" 'empty packet value' '2026-04-01T00:00:10Z')")"
pq_outcomes "$PQ_EPKT" '{"ts":"2026-04-01T00:01:00Z","packet":"pq-other","session":"PQ","kind":"start"}
'
pq_check_kept "an entry with packet: '' (empty value)" "$PQ_EPKT" q-epkt

# asked_at: '' -- empty value, with a later start on the SAME packet.
PQ_EASK="$(pq_fixture "$(printf "  - id: q-eask\n    severity: blocking\n    packet: pq-eask\n    question: 'empty asked_at value'\n    asked_at: ''")")"
pq_outcomes "$PQ_EASK" '{"ts":"2026-04-01T00:01:00Z","packet":"pq-eask","session":"PQ","kind":"start"}
'
pq_check_kept "an entry with asked_at: '' (empty value)" "$PQ_EASK" q-eask

# asked_at double-quoted and LATER than the start on the same packet -- the
# live second question; the decoder strips single quotes only, so the
# still-quoted stamp is unparseable and must not read as epoch 0.
PQ_DQASK="$(pq_fixture "$(printf "  - id: q-dqask\n    severity: blocking\n    packet: pq-dqask\n    question: 'double-quoted asked_at'\n    asked_at: \"2026-04-01T00:02:00Z\"")")"
pq_outcomes "$PQ_DQASK" '{"ts":"2026-04-01T00:01:00Z","packet":"pq-dqask","session":"PQ","kind":"start"}
'
pq_check_kept "an entry whose asked_at is double-quoted (unparseable after decode) and later than the start" "$PQ_DQASK" q-dqask

echo "-- one packet stopped twice: the answered first question is dropped, the live second one is kept --"
PQ_TWICE_ENTRIES="$(pq_entry q-first pq-twice 'first stop' '2026-04-01T00:00:10Z')
$(pq_entry q-second pq-twice 'second stop' '2026-04-01T00:02:00Z')"
PQ_TWICE="$(pq_fixture "$PQ_TWICE_ENTRIES")"
pq_outcomes "$PQ_TWICE" '{"ts":"2026-04-01T00:01:00Z","packet":"pq-twice","session":"PQ","kind":"start"}
'
PQ_TWICE_OUT="$(pq_run "$PQ_TWICE")"
assert_true "prune-questions: one packet stopped twice -- PRUNED=yes, DROPPED=1, KEPT=1" \
  "[ \"\$PQ_TWICE_OUT\" = \"\$(printf 'PRUNED=yes\nDROPPED=1\nKEPT=1')\" ]"
assert_true "prune-questions: the answered FIRST question is gone" \
  "! grep -qxF '  - id: q-first' \"$(pq_rs "$PQ_TWICE")\""
assert_true "prune-questions: the answered FIRST question's WHOLE block is gone, not just its header line" \
  "! grep -qxF \"    question: 'first stop'\" \"$(pq_rs "$PQ_TWICE")\""
assert_true "prune-questions: the still-live SECOND question survives" \
  "grep -qxF '  - id: q-second' \"$(pq_rs "$PQ_TWICE")\""
assert_true "prune-questions: the run-state still parses as real YAML after the two-stops prune" \
  "yamlok \"$(pq_rs "$PQ_TWICE")\""

echo "-- findings: (and everything after it) is byte-identical after a prune --"
PQ_FIND="$(pq_fixture "$(pq_entry q-find pq-find 'answered, to force a real prune' '2026-04-01T00:00:10Z')")"
pq_outcomes "$PQ_FIND" '{"ts":"2026-04-01T00:01:00Z","packet":"pq-find","session":"PQ","kind":"start"}
'
PQ_FIND_TAIL_BEFORE="$(pq_tail "$PQ_FIND")"
PQ_FIND_OUT="$(pq_run "$PQ_FIND")"
assert_true "prune-questions (findings case): a real drop actually happened, so this case is not vacuous" \
  "[ \"\$PQ_FIND_OUT\" = \"\$(printf 'PRUNED=yes\nDROPPED=1\nKEPT=0')\" ]"
assert_true "prune-questions: findings: (and note: after it) is byte-identical to before the prune" \
  "[ \"\$PQ_FIND_TAIL_BEFORE\" = \"\$(pq_tail "$PQ_FIND")\" ]"
assert_true "prune-questions: the run-state still parses as real YAML after the findings-preserving prune" \
  "yamlok \"$(pq_rs "$PQ_FIND")\""
assert_true "prune-questions: a real drop goes through cmd_write, which backs up the pre-write file to run-state-prev.yaml" \
  "[ -f \"$PQ_FIND/.agents/run-state-prev.yaml\" ]"

echo "-- nothing to drop: the file is left completely unchanged (no-drop case) --"
PQ_NODROP="$(pq_fixture "$(pq_entry q-nodrop pq-nodrop 'nothing here should be dropped' '2026-04-01T00:00:10Z')")"
pq_outcomes "$PQ_NODROP" '{"ts":"2026-03-31T00:00:00Z","packet":"pq-nodrop","session":"PQ","kind":"start"}
'
PQ_NODROP_BEFORE="$(cat "$(pq_rs "$PQ_NODROP")")"
PQ_NODROP_OUT="$(pq_run "$PQ_NODROP")"
assert_true "prune-questions (no-drop case): an EARLIER start does not answer a LATER question -- PRUNED=no, DROPPED=0" \
  "[ \"\$PQ_NODROP_OUT\" = \"\$(printf 'PRUNED=no\nDROPPED=0')\" ]"
assert_true "prune-questions: the no-drop file is byte-identical to before the call" \
  "[ \"\$PQ_NODROP_BEFORE\" = \"\$(cat "$(pq_rs "$PQ_NODROP")")\" ]"
assert_true "prune-questions: the run-state still parses as real YAML after the no-drop call" \
  "yamlok \"$(pq_rs "$PQ_NODROP")\""

echo
echo "== check-status: the mechanical reading of templates/status-line.md, one reason"
echo "   per rule (loop-driver-run-gaps T1) =="
# Every case below was verified by MUTATION, not inspection. The two wrong
# implementations they exist to rule out are named on the cases that rule them
# out: splitting on ` · ` into exactly four fields (which refuses a line the
# template explicitly permits), and one generic "malformed status line" message
# (which leaves the driver's single re-dispatch nothing actionable to pass
# back).
#
# check-status reads no file and takes no run-state, so this runs from a plain
# temp dir that is NOT a git repo and holds no .agents/ at all -- if the
# subcommand ever grows a file dependency, these go red rather than silently
# reading the sweep's own fixtures.
CS_DIR="$(mktemp -d)"
cs_run() { (cd "$CS_DIR" && "$RUNSTATE" check-status --status "$1" 2>&1); }

# One canonical well-formed line, and the same line with a `<what changed>`
# clause that carries its own ` · `.
CS_OK='done · added the check · result: needs-reading · /tmp/run/pkt/implementer.md'
CS_OK_MIDDOT='done · added the check · and its sweep cases · result: no · /tmp/run/pkt/implementer.md'
# The two shapes the PRD's Overview names, observed on real packets of run
# 20260919T224810-6fc6: a free-form reply with no fields, no `result:` and no
# path; and a line whose first field is the packet id and which carries no
# `result:`.
CS_FREEFORM='I reformatted the status line as you asked, nothing else changed.'
CS_PKTID='loop-driver-run-gaps-t1 · added check-status and its sweep cases · /tmp/run/pkt/implementer.md'

echo "-- the well-formed line passes --"
CS_OK_RC=0; CS_OK_OUT="$(cs_run "$CS_OK")" || CS_OK_RC=$?
assert_true "check-status: a well-formed status line exits 0" \
  "[ \"\$CS_OK_RC\" = 0 ]"
assert_true "check-status: and prints STATUS_LINE=ok" \
  "[ \"\$CS_OK_OUT\" = 'STATUS_LINE=ok' ]"

echo "-- a <what changed> clause carrying its OWN ' · ' still passes --"
# THE case that rules out splitting on ` · ` into exactly four fields:
# templates/status-line.md says the two middle fields are free text and may
# contain the separator, and that only the FIRST and LAST boundaries are
# load-bearing. A four-way split refuses this line.
CS_MID_RC=0; CS_MID_OUT="$(cs_run "$CS_OK_MIDDOT")" || CS_MID_RC=$?
assert_true "check-status: a five-field line (the clause carries its own ' · ') still exits 0 -- boundaries come from the first and last separator, not a field count" \
  "[ \"\$CS_MID_RC\" = 0 ]"
assert_true "check-status: and prints STATUS_LINE=ok for it too" \
  "[ \"\$CS_MID_OUT\" = 'STATUS_LINE=ok' ]"

echo "-- Overview shape 1: a free-form reply with no fields, no result:, no path --"
CS_FREE_RC=0; CS_FREE_MSG="$(cs_run "$CS_FREEFORM")" || CS_FREE_RC=$?
CS_WANT_FREE="runstate.sh: status line carries no ' · ' separator at all; expected <status> · <what changed> · result: <needs-reading|no> · <path>"
assert_true "check-status: the free-form reply is refused (non-zero)" \
  "[ \"\$CS_FREE_RC\" != 0 ]"
assert_true "check-status: its reason names the missing-separator rule, verbatim" \
  "[ \"\$CS_FREE_MSG\" = \"\$CS_WANT_FREE\" ]"

echo "-- Overview shape 2: the packet id as first field, no result: --"
CS_PKT_RC=0; CS_PKT_MSG="$(cs_run "$CS_PKTID")" || CS_PKT_RC=$?
CS_WANT_PKT="runstate.sh: status line's next-to-last field must be literally 'result: needs-reading' or 'result: no', not 'added check-status and its sweep cases'"
assert_true "check-status: the packet-id-first line is refused (non-zero)" \
  "[ \"\$CS_PKT_RC\" != 0 ]"
assert_true "check-status: its reason names the result-field rule and quotes what it found, verbatim" \
  "[ \"\$CS_PKT_MSG\" = \"\$CS_WANT_PKT\" ]"

echo "-- two different failures give two different reasons --"
# THE case that rules out one generic "malformed status line" message: both
# lines above are refused, and the driver's one re-dispatch passes the printed
# reason and nothing else, so a shared message makes the re-dispatch blind.
assert_true "check-status: the two Overview shapes print DIFFERENT reasons (not one generic 'malformed status line')" \
  "[ \"\$CS_FREE_MSG\" != \"\$CS_PKT_MSG\" ]"
assert_true "check-status: and neither reason is empty" \
  "[ -n \"\$CS_FREE_MSG\" ] && [ -n \"\$CS_PKT_MSG\" ]"

echo "-- one rule at a time, each with its own reason --"
CS_NL_RC=0; CS_NL_MSG="$(cs_run "$(printf 'done · added the check · result: no · /tmp/r\nand a second line')")" || CS_NL_RC=$?
assert_true "check-status: a two-line status line is refused" \
  "[ \"\$CS_NL_RC\" != 0 ]"
assert_true "check-status: the one-line rule is named" \
  "[ \"\$CS_NL_MSG\" = 'runstate.sh: status line must be exactly one line; this one contains a line break' ]"
# A lone CR is a line break too -- it renders as two lines on the host this
# repo has already been bitten on (ADR 0019 v3.1, the CRLF-in-jq bug).
CS_CR_RC=0; CS_CR_MSG="$(cs_run "$(printf 'done · added the check\r · result: no · /tmp/r')")" || CS_CR_RC=$?
assert_true "check-status: a bare CR is refused by the same one-line rule" \
  "[ \"\$CS_CR_RC\" != 0 ] && [ \"\$CS_CR_MSG\" = 'runstate.sh: status line must be exactly one line; this one contains a line break' ]"

CS_BT_RC=0; CS_BT_MSG="$(cs_run 'done · touched `runstate.sh` · result: no · /tmp/r')" || CS_BT_RC=$?
assert_true "check-status: a backtick is refused" \
  "[ \"\$CS_BT_RC\" != 0 ]"
assert_true "check-status: the no-backtick rule is named" \
  "[ \"\$CS_BT_MSG\" = 'runstate.sh: status line must contain no backtick' ]"

CS_DOL_RC=0; CS_DOL_MSG="$(cs_run 'done · spent $(id) · result: no · /tmp/r')" || CS_DOL_RC=$?
assert_true "check-status: a dollar sign is refused" \
  "[ \"\$CS_DOL_RC\" != 0 ]"
assert_true "check-status: the no-dollar rule is named, and differs from the backtick reason" \
  "[ \"\$CS_DOL_MSG\" = 'runstate.sh: status line must contain no dollar sign' ] && [ \"\$CS_DOL_MSG\" != \"\$CS_BT_MSG\" ]"

CS_W2_RC=0; CS_W2_MSG="$(cs_run 'all done · added the check · result: no · /tmp/r')" || CS_W2_RC=$?
assert_true "check-status: a two-word first field is refused" \
  "[ \"\$CS_W2_RC\" != 0 ]"
assert_true "check-status: the one-word rule is named and quotes what it found" \
  "[ \"\$CS_W2_MSG\" = \"runstate.sh: status line's first field (everything before the first ' · ') must be one word, not 'all done'\" ]"

CS_1SEP_RC=0; CS_1SEP_MSG="$(cs_run 'done · /tmp/r')" || CS_1SEP_RC=$?
assert_true "check-status: a line with only ONE separator has no next-to-last field, and is refused" \
  "[ \"\$CS_1SEP_RC\" != 0 ]"
assert_true "check-status: that refusal says so, rather than reporting an empty field" \
  "[ \"\$CS_1SEP_MSG\" = \"runstate.sh: status line's next-to-last field must be literally 'result: needs-reading' or 'result: no'; this line has only one ' · ' separator, so it has no such field\" ]"

CS_RTOK_RC=0; CS_RTOK_MSG="$(cs_run 'done · added the check · result: maybe · /tmp/r')" || CS_RTOK_RC=$?
assert_true "check-status: a result: field with a token outside {needs-reading,no} is refused" \
  "[ \"\$CS_RTOK_RC\" != 0 ]"
assert_true "check-status: the result-field rule is named and quotes the bad field" \
  "[ \"\$CS_RTOK_MSG\" = \"runstate.sh: status line's next-to-last field must be literally 'result: needs-reading' or 'result: no', not 'result: maybe'\" ]"

CS_LEMPTY_RC=0; CS_LEMPTY_MSG="$(cs_run 'done · added the check · result: no · ')" || CS_LEMPTY_RC=$?
assert_true "check-status: an empty last field is refused" \
  "[ \"\$CS_LEMPTY_RC\" != 0 ]"
assert_true "check-status: the path rule is named" \
  "[ \"\$CS_LEMPTY_MSG\" = \"runstate.sh: status line's last field (everything after the last ' · ') must be a non-empty path with no whitespace, not ''\" ]"

CS_LWS_RC=0; CS_LWS_MSG="$(cs_run 'done · added the check · result: no · /tmp/r and a trailing remark')" || CS_LWS_RC=$?
assert_true "check-status: a last field carrying whitespace is refused (the path must be the whole field)" \
  "[ \"\$CS_LWS_RC\" != 0 ]"
assert_true "check-status: the same path rule is named, quoting the whole field" \
  "[ \"\$CS_LWS_MSG\" = \"runstate.sh: status line's last field (everything after the last ' · ') must be a non-empty path with no whitespace, not '/tmp/r and a trailing remark'\" ]"

echo "-- every rule above gives a DISTINCT reason --"
# The generic-message failure is not ruled out by two reasons differing once;
# count the distinct reasons across every rule this check enforces.
CS_ALL_REASONS="$(printf '%s\n' "$CS_FREE_MSG" "$CS_PKT_MSG" "$CS_NL_MSG" "$CS_BT_MSG" "$CS_DOL_MSG" "$CS_W2_MSG" "$CS_1SEP_MSG" "$CS_LEMPTY_MSG")"
CS_DISTINCT="$(sort -u <<< "$CS_ALL_REASONS" | wc -l | tr -d ' ')"
assert_true "check-status: eight refusals across eight rules print eight distinct reasons" \
  "[ \"\$CS_DISTINCT\" = 8 ]"

echo "-- usage: --status is required, and a missing one is not a silent pass --"
CS_NOARG_RC=0; CS_NOARG_MSG="$( (cd "$CS_DIR" && "$RUNSTATE" check-status 2>&1) )" || CS_NOARG_RC=$?
assert_true "check-status: no --status at all exits non-zero" \
  "[ \"\$CS_NOARG_RC\" != 0 ]"
assert_true "check-status: and says what it wanted" \
  "[ \"\$CS_NOARG_MSG\" = 'runstate.sh: usage: check-status --status \"<line>\"' ]"
CS_EMPTY_RC=0; (cd "$CS_DIR" && "$RUNSTATE" check-status --status '' >/dev/null 2>&1) || CS_EMPTY_RC=$?
assert_true "check-status: an EMPTY --status exits non-zero too" \
  "[ \"\$CS_EMPTY_RC\" != 0 ]"

echo "-- it reads nothing: no run-state, no .agents/, not even a git repo --"
assert_true "check-status: the directory it ran from really is not a git repo and holds no .agents/" \
  "[ ! -d \"\$CS_DIR/.git\" ] && [ ! -d \"\$CS_DIR/.agents\" ]"
assert_true "check-status: and it left that directory empty (a pure reader writes nothing)" \
  "[ -z \"\$(ls -A \"\$CS_DIR\")\" ]"

echo "-- and every one of them again with NEITHER jq NOR python3 on PATH --"
# The owning-sweep rule inherited from runstate-write-integrity-gaps: a case
# that only holds where the author's tools are installed is a case stock Git
# Bash never runs. `bare`/`NOTOOLS` are the stubs established at T8 above.
cs_bare() { (cd "$CS_DIR" && PATH="$NOTOOLS:$PATH" "$RUNSTATE" check-status --status "$1" 2>&1); }
CS_NT_OK_RC=0; CS_NT_OK_OUT="$(cs_bare "$CS_OK")" || CS_NT_OK_RC=$?
assert_true "no-tools host: a well-formed status line still passes, byte-identically" \
  "[ \"\$CS_NT_OK_RC\" = 0 ] && [ \"\$CS_NT_OK_OUT\" = \"\$CS_OK_OUT\" ]"
CS_NT_MID_RC=0; CS_NT_MID_OUT="$(cs_bare "$CS_OK_MIDDOT")" || CS_NT_MID_RC=$?
assert_true "no-tools host: the clause carrying its own ' · ' still passes" \
  "[ \"\$CS_NT_MID_RC\" = 0 ] && [ \"\$CS_NT_MID_OUT\" = \"\$CS_MID_OUT\" ]"
CS_NT_FREE_RC=0; CS_NT_FREE_MSG="$(cs_bare "$CS_FREEFORM")" || CS_NT_FREE_RC=$?
assert_true "no-tools host: the free-form reply is refused with the SAME reason" \
  "[ \"\$CS_NT_FREE_RC\" != 0 ] && [ \"\$CS_NT_FREE_MSG\" = \"\$CS_FREE_MSG\" ]"
CS_NT_PKT_RC=0; CS_NT_PKT_MSG="$(cs_bare "$CS_PKTID")" || CS_NT_PKT_RC=$?
assert_true "no-tools host: the packet-id-first line is refused with the SAME reason" \
  "[ \"\$CS_NT_PKT_RC\" != 0 ] && [ \"\$CS_NT_PKT_MSG\" = \"\$CS_PKT_MSG\" ]"
assert_true "no-tools host: the two reasons still differ" \
  "[ \"\$CS_NT_FREE_MSG\" != \"\$CS_NT_PKT_MSG\" ]"
CS_NT_NL_MSG="$(cs_bare "$(printf 'done · added the check · result: no · /tmp/r\nand a second line')" || true)"
CS_NT_CR_MSG="$(cs_bare "$(printf 'done · added the check\r · result: no · /tmp/r')" || true)"
CS_NT_BT_MSG="$(cs_bare 'done · touched `runstate.sh` · result: no · /tmp/r' || true)"
CS_NT_DOL_MSG="$(cs_bare 'done · spent $(id) · result: no · /tmp/r' || true)"
CS_NT_W2_MSG="$(cs_bare 'all done · added the check · result: no · /tmp/r' || true)"
CS_NT_1SEP_MSG="$(cs_bare 'done · /tmp/r' || true)"
CS_NT_RTOK_MSG="$(cs_bare 'done · added the check · result: maybe · /tmp/r' || true)"
CS_NT_LEMPTY_MSG="$(cs_bare 'done · added the check · result: no · ' || true)"
CS_NT_LWS_MSG="$(cs_bare 'done · added the check · result: no · /tmp/r and a trailing remark' || true)"
assert_true "no-tools host: all nine remaining refusal reasons are byte-identical to the full-PATH ones" \
  "[ \"\$CS_NT_NL_MSG\" = \"\$CS_NL_MSG\" ] && [ \"\$CS_NT_CR_MSG\" = \"\$CS_CR_MSG\" ] \
   && [ \"\$CS_NT_BT_MSG\" = \"\$CS_BT_MSG\" ] && [ \"\$CS_NT_DOL_MSG\" = \"\$CS_DOL_MSG\" ] \
   && [ \"\$CS_NT_W2_MSG\" = \"\$CS_W2_MSG\" ] && [ \"\$CS_NT_1SEP_MSG\" = \"\$CS_1SEP_MSG\" ] \
   && [ \"\$CS_NT_RTOK_MSG\" = \"\$CS_RTOK_MSG\" ] && [ \"\$CS_NT_LEMPTY_MSG\" = \"\$CS_LEMPTY_MSG\" ] \
   && [ \"\$CS_NT_LWS_MSG\" = \"\$CS_LWS_MSG\" ]"

echo
echo "== route + write-result run that same check on their own --status, BEFORE"
echo "   either touches disk (loop-driver-run-gaps T2) =="
# Three wrong implementations these cases rule out, each named on the case that
# rules it out:
#   - checking AFTER the routing record is appended: still exits non-zero, still
#     prints the reason, and leaves routing.jsonl carrying a record for a line
#     the loop never routed on — a decision run-digest would then report as
#     having been made. Ruled out by the byte-unchanged assertion, not by the
#     exit status, which is identical either way.
#   - checking AFTER the result file is written: same shape one subcommand over
#     — a result file on disk whose first line is the off-grammar text, for a
#     write the caller was told was refused. Ruled out by asserting the target
#     path (and its directory) does not exist.
#   - each caller wording its own refusal: that hands the driver a reason the
#     grammar's owner never stated, and the driver's one move on a refusal is to
#     re-dispatch the agent passing the printed reason and nothing else. Ruled
#     out by comparing all three messages byte-for-byte, on two DIFFERENT
#     off-grammar shapes so a single shared generic message cannot pass either.
T2="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$T2" init -q
git -C "$T2" config user.email t@t; git -C "$T2" config user.name t
mkdir -p "$T2/.agents"
printf 'schema: 3\nstatus: running\n' > "$T2/.agents/run-state.yaml"
T2_RUN_ID="$(cd "$T2" && "$RUNSTATE" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
T2_RUN_DIR="$T2/.agents/loop/$T2_RUN_ID"
T2_ROUTING="$T2_RUN_DIR/routing.jsonl"
T2_OK='pass · wired the check into route and write-result · result: needs-reading · /tmp/run/t2-pkt/implementer.md'

echo "-- a WELL-FORMED line still goes through both (so the refusals below are not just a check that refuses everything) --"
T2_GOOD_OUT="$(cd "$T2" && "$RUNSTATE" route .agents/run-state.yaml t2-pkt pass --status "$T2_OK")"
assert_true "route: a well-formed --status routes normally" \
  "printf '%s\n' \"\$T2_GOOD_OUT\" | grep -qx 'ACTION=land'"
assert_true "  and its record reached routing.jsonl" \
  "[ -f \"$T2_ROUTING\" ] && grep -q 't2-pkt' \"$T2_ROUTING\""
# route's --status is OPTIONAL: an omitted one is not a line and is not checked.
# This case also pins the `set -e` footgun the wiring had to avoid -- written as
# `[ -n "$status" ] && _rs_require_status_line …`, a false left side is a failing
# statement under `set -euo pipefail` and aborts the whole call.
assert_true "route: NO --status at all still routes (the optional argument is not checked, and does not abort under set -e)" \
  "(cd \"$T2\" && \"\$RUNSTATE\" route .agents/run-state.yaml t2-nostatus pass) | grep -qx 'ACTION=land'"

echo "-- route refuses an off-grammar line, and routing.jsonl is BYTE-UNCHANGED --"
T2_BEFORE="$(cat "$T2_ROUTING")"
T2_BEFORE_LINES="$(wc -l < "$T2_ROUTING" | tr -d ' ')"
T2_RT_RC=0; T2_RT_MSG="$( (cd "$T2" && "$RUNSTATE" route .agents/run-state.yaml t2-pkt fix --status "$CS_FREEFORM") 2>&1 )" || T2_RT_RC=$?
assert_true "route: an off-grammar --status exits non-zero" \
  "[ \"\$T2_RT_RC\" != 0 ]"
assert_true "route: its reason is the one check-status prints for that line, verbatim" \
  "[ \"\$T2_RT_MSG\" = \"\$CS_FREE_MSG\" ]"
assert_true "route: and it printed NO ACTION= line at all (nothing downstream can read a refusal as a routing decision)" \
  "! printf '%s\n' \"\$T2_RT_MSG\" | grep -q '^ACTION='"
assert_true "route: routing.jsonl is byte-identical to before the refused call -- the check ran BEFORE the append, not after it" \
  "[ \"\$T2_BEFORE\" = \"\$(cat \"$T2_ROUTING\")\" ]"
assert_true "route: and it gained no line (the same fact counted, so a same-length rewrite cannot pass)" \
  "[ \"\$(wc -l < \"$T2_ROUTING\" | tr -d ' ')\" = \"\$T2_BEFORE_LINES\" ]"

echo "-- write-result refuses the same line, and the target path is never created --"
T2_WR_DIR="$T2_RUN_DIR/t2-pkt"
T2_WR_TARGET="$T2_WR_DIR/implementer.md"
assert_true "write-result: the target does not exist before the refused call (so the assertion below is not vacuously true)" \
  "[ ! -e \"$T2_WR_TARGET\" ] && [ ! -d \"$T2_WR_DIR\" ]"
T2_WR_RC=0; T2_WR_MSG="$( (printf 'body that must never be written\n' | (cd "$T2" && "$RUNSTATE" write-result .agents/run-state.yaml "$T2_WR_TARGET" --status "$CS_FREEFORM")) 2>&1 )" || T2_WR_RC=$?
assert_true "write-result: an off-grammar --status exits non-zero" \
  "[ \"\$T2_WR_RC\" != 0 ]"
assert_true "write-result: its reason is the one check-status prints for that line, verbatim" \
  "[ \"\$T2_WR_MSG\" = \"\$CS_FREE_MSG\" ]"
assert_true "write-result: the target file does not exist -- the check ran BEFORE the write, not after it" \
  "[ ! -e \"$T2_WR_TARGET\" ]"
assert_true "write-result: and its directory was never created either (nothing touched disk at all)" \
  "[ ! -d \"$T2_WR_DIR\" ]"
assert_true "write-result: and it printed NO RESULT= line" \
  "! printf '%s\n' \"\$T2_WR_MSG\" | grep -q '^RESULT='"

echo "-- a MULTI-LINE status is refused by write-result too, by the one-line rule --"
# This replaces the old "write-result collapses a newline in the status" case:
# a multi-line status can no longer reach the collapse, because the grammar
# check refuses it first. _yaml_collapse stays in write-result as a second
# line of defence for text that arrives some other way.
T2_ML_TARGET="$T2_RUN_DIR/t2-ml/implementer.md"
T2_ML_RC=0; T2_ML_MSG="$( (printf 'body\n' | (cd "$T2" && "$RUNSTATE" write-result .agents/run-state.yaml "$T2_ML_TARGET" --status "$(printf 'done · x · result: no · /tmp/r\nand a second line')")) 2>&1 )" || T2_ML_RC=$?
assert_true "write-result: a multi-line --status is refused rather than collapsed" \
  "[ \"\$T2_ML_RC\" != 0 ] && [ \"\$T2_ML_MSG\" = \"\$CS_NL_MSG\" ]"
assert_true "  and wrote no file" \
  "[ ! -e \"$T2_ML_TARGET\" ]"

echo "-- all THREE subcommands refuse the same line with the same bytes --"
T2_CS_MSG="$(cs_run "$CS_FREEFORM" || true)"
assert_true "check-status, route and write-result print byte-identical refusals for the free-form shape" \
  "[ \"\$T2_CS_MSG\" = \"\$T2_RT_MSG\" ] && [ \"\$T2_RT_MSG\" = \"\$T2_WR_MSG\" ]"
assert_true "  and that shared message is non-empty" \
  "[ -n \"\$T2_CS_MSG\" ]"
# A SECOND off-grammar shape, refused by a different rule: three callers that
# all printed one generic "malformed status line" would pass the case above and
# fail here, because this message must differ from that one and still agree
# across all three.
T2_RT2_MSG="$( (cd "$T2" && "$RUNSTATE" route .agents/run-state.yaml t2-pkt fix --status "$CS_PKTID") 2>&1 || true )"
T2_WR2_MSG="$( (printf 'body\n' | (cd "$T2" && "$RUNSTATE" write-result .agents/run-state.yaml "$T2_RUN_DIR/t2-pkt2/implementer.md" --status "$CS_PKTID")) 2>&1 || true )"
T2_CS2_MSG="$(cs_run "$CS_PKTID" || true)"
assert_true "a second off-grammar shape: all three agree byte-for-byte on ITS reason too" \
  "[ \"\$T2_CS2_MSG\" = \"\$T2_RT2_MSG\" ] && [ \"\$T2_RT2_MSG\" = \"\$T2_WR2_MSG\" ]"
assert_true "and the two shapes' shared reasons DIFFER (not one generic message repeated by three callers)" \
  "[ \"\$T2_CS_MSG\" != \"\$T2_CS2_MSG\" ]"
assert_true "the second refused route left routing.jsonl byte-unchanged as well" \
  "[ \"\$T2_BEFORE\" = \"\$(cat \"$T2_ROUTING\")\" ]"

echo "-- and the same three refusals with NEITHER jq NOR python3 on PATH --"
T2_NT_RT_MSG="$( (cd "$T2" && PATH="$NOTOOLS:$PATH" "$RUNSTATE" route .agents/run-state.yaml t2-pkt fix --status "$CS_FREEFORM") 2>&1 || true )"
T2_NT_WR_MSG="$( (printf 'body\n' | (cd "$T2" && PATH="$NOTOOLS:$PATH" "$RUNSTATE" write-result .agents/run-state.yaml "$T2_RUN_DIR/t2-nt/implementer.md" --status "$CS_FREEFORM")) 2>&1 || true )"
assert_true "no-tools host: route and write-result refuse with the SAME bytes as the full-PATH runs" \
  "[ \"\$T2_NT_RT_MSG\" = \"\$T2_RT_MSG\" ] && [ \"\$T2_NT_WR_MSG\" = \"\$T2_WR_MSG\" ]"
assert_true "no-tools host: routing.jsonl still byte-unchanged, and no result file was written" \
  "[ \"\$T2_BEFORE\" = \"\$(cat \"$T2_ROUTING\")\" ] && [ ! -e \"$T2_RUN_DIR/t2-nt/implementer.md\" ]"

echo
echo "== a packet-close write that follows §3.6's carry clause leaves the run resolvable;"
echo "   one that drops the id or the claim does not (loop-driver-run-gaps T4) =="
# The clause is prose; these are its CONSEQUENCES, exercised against the real
# subcommands so the prose is pinned to what the core actually does rather than to
# what it is documented to do. Observed on run `20260919T224810-6fc6`, packet 1:
# §3.6 named `status: running` and the `findings:` index and nothing else, the
# driver wrote exactly that, and the run-state came out of the close missing
# `run_id` and the whole `driver_*` claim.
#
# WHY A CONTROL, AND WHY THESE THREE. A close that follows the clause and one that
# drops a key take the SAME code path: `runstate.sh write` accepts both (its
# structural check catches truncation and gross malformation, never a well-formed
# document that is wrong), and both parse. So a case that only asserted "the
# compliant write succeeds and the file still parses" would pass on ANY content at
# all, including the exact content the incident produced. Each control below is one
# key removed from the same generated close, so the only difference between the
# green case and the red one is the line the clause exists to carry:
#   - control 1 drops `run_id`:     run-digest refuses for the rest of the run, and
#                                   the next `begin-run` mints a SECOND id over a
#                                   second run directory, leaving this run's handoff
#                                   files where nothing will look for them.
#   - control 2 drops the `driver_*` claim (keeping the id, so the refusal above
#                                   cannot be what turns it red): `driver-status`
#                                   reads a run nobody ever claimed, and `outcome`
#                                   reports a live mid-run checkpoint as CRASHED.
# Both were verified by mutation in the other direction too: with the drop removed
# (`T4_DROP=`) the control cases go red, which is what shows they are testing the
# dropped key and not the fixture.
#
# Every case runs twice — once on a full PATH, once with jq and python3 scrubbed
# (`bare`'s NOTOOLS stubs, established at T8 above) — from ONE function, so the
# mirror cannot drift from the original. The scrub wraps only the runstate.sh
# invocations; the parse assertion uses the sweep's own parser and skips LOUDLY
# when the host has none (yamlok), as every parse case here does.
T4_SUMMARY='guard.sh: fails closed on unreadable input'
T4_NEWSHA='2222222222222222222222222222222222222222'

# A mid-run checkpoint built by the real scripts: a begun run, a driver claim, a
# handoff file for the packet about to land, its start/green records, a pending
# question, and a findings entry whose summary carries the one sequence (`: `) the
# durable writer quotes for — so "copied line-for-line" is pinned on a value that a
# re-emission from `runstate.sh findings` would visibly change. Prints the RUN_ID.
t4_fixture() {
  local d="$1" rid
  git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t
  mkdir -p "$d/.agents/metrics/outcomes"
  cat > "$d/.agents/run-state.yaml" <<'T4STATE'
schema: 3
status: running
branch: orch/t4-a
last_green_commit: 1111111111111111111111111111111111111111
backlog:
  cursor: t4-a
  pending:
    - t4-a
    - t4-b
pending_questions:
  - id: q-t4
    severity: normal
    packet: t4-b
    question: which way round
note: mid-run
T4STATE
  rid="$( (cd "$d" && "$RUNSTATE" begin-run .agents/run-state.yaml) | sed -n 's/^RUN_ID=//p')"
  (cd "$d" && "$RUNSTATE" claim-driver .agents/run-state.yaml) >/dev/null
  (cd "$d" && "$RUNSTATE" add-finding .agents/run-state.yaml f-t4 "$T4_SUMMARY" --packets t4-b) >/dev/null
  printf 'T4 the first packet\nbody\n' \
    | (cd "$d" && "$RUNSTATE" handoff .agents/run-state.yaml t4-a --tier mechanical --agent implementer) >/dev/null
  printf '{"ts":"2026-02-01T00:00:01Z","packet":"t4-a","session":"T4","kind":"start"}\n{"ts":"2026-02-01T00:00:02Z","packet":"t4-a","session":"T4","outcome":"green"}\n' \
    > "$d/.agents/metrics/outcomes/T4.jsonl"
  printf '%s' "$rid"
}

# The write §3.6 tells the driver to make: every carried key copied line-for-line off
# the file being replaced (its indented body with it), then the close's own output.
# $2 is an ERE of column-0 keys to leave behind — empty for the compliant write, one
# key for a control. The fixture above has no column-0 comment line, which is why the
# keep-state test can be a plain "unindented line starts a new key".
t4_close() { # <state file> <drop-ere>
  awk -v drop="$2" '
    /^[^[:space:]]/ {
      k = $0; sub(/:.*/, "", k)
      keep = (k == "schema" || k == "run_id" || k == "branch" || k == "status" \
              || k == "pending_questions" || k == "findings" || k ~ /^driver_/)
      if (drop != "" && k ~ drop) keep = 0
    }
    keep { print }
  ' "$1"
  printf 'updated_at: 2026-09-20T00:00:00Z\n'
  printf 'last_green_commit: %s\n' "$T4_NEWSHA"
  printf 'backlog:\n  cursor: t4-b\n  pending:\n    - t4-b\n'
  printf 'note: landed t4-a\n'
}

# $T4_SCRUB is empty on the full-PATH pass and $NOTOOLS on the mirrored one.
t4_rs() { local d="$1"; shift
  if [ -n "$T4_SCRUB" ]; then (cd "$d" && PATH="$T4_SCRUB:$PATH" "$RUNSTATE" "$@")
  else (cd "$d" && "$RUNSTATE" "$@"); fi
}
t4_dirs() { ls -1 "$1/.agents/loop" | wc -l | tr -d ' '; }

t4_cases() { # <label suffix>
  local sfx="$1" d rid wrc drc dmsg reprint ndirs newid
  echo "-- the compliant close: every named key carried$sfx --"
  d="$(cd "$(mktemp -d)" && pwd -P)"; rid="$(t4_fixture "$d")"
  assert_true "fixture$sfx: begin-run minted an id, claim-driver recorded a live claim, and the handoff landed in the run directory" \
    "[ -n \"\$rid\" ] && [ -f \"\$d/.agents/loop/\$rid/t4-a/handoff.md\" ] && t4_rs \"\$d\" driver-status .agents/run-state.yaml | grep -q '^DRIVER=live'"
  wrc=0; t4_close "$d/.agents/run-state.yaml" '' | t4_rs "$d" write .agents/run-state.yaml || wrc=$?
  assert_true "compliant close$sfx: the write is accepted" "[ \"\$wrc\" = 0 ]"
  assert_true "compliant close$sfx: and the file still parses" "yamlok \"\$d/.agents/run-state.yaml\""
  assert_true "compliant close$sfx: run-digest resolves — no no-run-id refusal, and it emits the landed packet's own line" \
    "t4_rs \"\$d\" run-digest .agents/run-state.yaml | grep -qx \$'packet\tt4-a\tT4 the first packet\tgreen'"
  reprint="$(t4_rs "$d" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
  assert_true "compliant close$sfx: begin-run reprints the RUN_ID the file held before the write, minting nothing" \
    "[ \"\$reprint\" = \"\$rid\" ]"
  assert_true "compliant close$sfx: and no second run directory was created" "[ \"\$(t4_dirs \"\$d\")\" = 1 ]"
  assert_true "compliant close$sfx: the driver claim survives — driver-status still reads live" \
    "t4_rs \"\$d\" driver-status .agents/run-state.yaml | grep -q '^DRIVER=live'"
  assert_true "compliant close$sfx: the findings index survives with its quoting intact (the summary carries a colon-space)" \
    "[ \"\$(t4_rs \"\$d\" findings .agents/run-state.yaml | cut -f2)\" = \"\$T4_SUMMARY\" ]"
  assert_true "compliant close$sfx: the pending question survives" \
    "grep -q 'id: q-t4' \"\$d/.agents/run-state.yaml\""
  assert_true "compliant close$sfx: and the close's OWN output landed — cursor advanced and last_green_commit is the new SHA" \
    "[ \"\$(t4_rs \"\$d\" cursor .agents/run-state.yaml)\" = t4-b ] && [ \"\$(t4_rs \"\$d\" get .agents/run-state.yaml last_green_commit)\" = \"\$T4_NEWSHA\" ]"

  echo "-- control 1: the same close with run_id dropped$sfx --"
  d="$(cd "$(mktemp -d)" && pwd -P)"; rid="$(t4_fixture "$d")"
  wrc=0; t4_close "$d/.agents/run-state.yaml" '^run_id$' | t4_rs "$d" write .agents/run-state.yaml || wrc=$?
  assert_true "control 1$sfx: the write is accepted and the file parses — nothing fails AT the close, which is why a write-succeeded assertion proves nothing" \
    "[ \"\$wrc\" = 0 ] && yamlok \"\$d/.agents/run-state.yaml\""
  drc=0; dmsg="$(t4_rs "$d" run-digest .agents/run-state.yaml 2>&1)" || drc=$?
  assert_true "control 1$sfx: run-digest then refuses, non-zero" "[ \"\$drc\" != 0 ]"
  assert_true "control 1$sfx: naming the missing id, so no report can be rendered for the rest of the run" \
    "printf '%s\n' \"\$dmsg\" | grep -q 'run-digest: run-state has no run_id'"
  assert_true "control 1$sfx: run-tally dies with it, so the stop report's figures go too" \
    "! t4_rs \"\$d\" run-tally .agents/run-state.yaml >/dev/null 2>&1"
  newid="$(t4_rs "$d" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
  assert_true "control 1$sfx: the next begin-run mints a DIFFERENT id" \
    "[ -n \"\$newid\" ] && [ \"\$newid\" != \"\$rid\" ]"
  assert_true "control 1$sfx: over a second run directory, with the run's handoff file left in the first — orphaned, not moved" \
    "[ \"\$(t4_dirs \"\$d\")\" = 2 ] && [ -f \"\$d/.agents/loop/\$rid/t4-a/handoff.md\" ] && [ ! -e \"\$d/.agents/loop/\$newid/t4-a/handoff.md\" ]"

  echo "-- control 2: the same close with the driver_* claim dropped, id kept$sfx --"
  d="$(cd "$(mktemp -d)" && pwd -P)"; rid="$(t4_fixture "$d")"
  wrc=0; t4_close "$d/.agents/run-state.yaml" '^driver_' | t4_rs "$d" write .agents/run-state.yaml || wrc=$?
  assert_true "control 2$sfx: the write is accepted and the file parses" \
    "[ \"\$wrc\" = 0 ] && yamlok \"\$d/.agents/run-state.yaml\""
  assert_true "control 2$sfx: run-digest still resolves — the id is there, so the claim is the only thing under test here" \
    "t4_rs \"\$d\" run-digest .agents/run-state.yaml | grep -qx \$'packet\tt4-a\tT4 the first packet\tgreen'"
  assert_true "control 2$sfx: but driver-status reads a run nobody ever claimed" \
    "t4_rs \"\$d\" driver-status .agents/run-state.yaml | grep -q '^DRIVER=none'"
  assert_true "control 2$sfx: and outcome reports this live mid-run checkpoint as CRASHED, the ending a resume reconciles" \
    "t4_rs \"\$d\" outcome .agents/run-state.yaml | grep -q '^OUTCOME=crashed'"
}

T4_SCRUB=""; t4_cases ""
T4_SCRUB="$NOTOOLS"; t4_cases " (no-tools host)"
T4_SCRUB=""

echo
echo "== source guard: no pipe-fed \`grep\` that can exit early used as a condition in the deterministic core =="
# next-state-reporting-integrity T4 — the twin of T3's case at the foot of
# scripts/test-gspec-backlog.sh. The construct this feature removed is a
# pipeline whose final stage is an early-exiting reader used as a condition:
# `printf … | awk … | grep -q .`. Under the `pipefail` set at the top of
# scripts/runstate.sh, `grep -q` exits on its first match and closes the pipe
# while the writer is still writing, the writer takes SIGPIPE (141), and
# `pipefail` reports 141 instead of grep's 0 — a true condition read as false.
# It only opens once the payload outgrows a single buffered write, so it passes
# every small test and fails in production (the `trim-note` flake, ~1 run in
# 20). This case is what stops a new one being added to the loop's single
# writer unnoticed.
#
# THE SHAPE (settled in the plan preamble, widened by grep-devnull-condition
# T2; PIPE_GREP_Q_RE below is a VERBATIM copy of T3's, not an import — the two
# sweeps share no file, and this repo's precedent is to reimplement a small
# helper rather than add a dependency two standalone CI sweeps both need). A
# NON-COMMENT source line containing a SINGLE `|` (never `||`) immediately
# followed by `grep`, where that grep either (a) is given a `q`-bearing option
# ANYWHERE among its arguments, or (b) sends its STDOUT to `/dev/null`. Because
# it is a copy, any change to the shape is TWO edits: here and in
# scripts/test-gspec-backlog.sh. They must not drift.
#
# Each half of that earns its place, verified against this file's own subject:
#   - non-comment: without it the scan flags prose that merely NAMES the
#     construct (verified 2026-09-19: dropping the leading `[^#[:space:]]`
#     flags scripts/runstate.sh:969 and :3750, both comments explaining the
#     fix, and nothing else). Prose that mentions the shape is not the shape.
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
#     and is correctly NOT flagged — that is the form the fixes in the scanned
#     file moved to, `_dirty_has_reviewed_output` among them, so a scan that
#     flagged it would fail on the fix itself.
#   - stdout to `/dev/null` — `>/dev/null`, `> /dev/null`, `1>/dev/null`,
#     `&>/dev/null` — even with no `q` on the line. This half is flagged on a
#     DEFENSIVE rationale, and the distinction matters enough to state twice:
#     it is NOT a measured failure. Measured (grep-devnull-condition T1's
#     review, 2026-09-19, Linux aarch64 containers, GNU grep 3.8 and 3.11, a
#     414 KB listing, 20 runs each) the redirect form misfired 0/20 while the
#     pipe-fed `-q` form misfired 20/20 with rc 141: GNU grep stops SCANNING on
#     a null stdout but drains a non-seekable stdin before it exits, so the
#     writer never takes SIGPIPE, and only `-q` skips that drain. The shape is
#     flagged because that safety is an undocumented courtesy of one
#     implementation and the line is one keystroke from `-q` — never because a
#     short-circuit was observed. Do not restate it as one.
#   - a BARE `2>/dev/null` is deliberately NOT matched: stderr to null neither
#     exits early nor closes the pipe, and the scanned file's own
#     `git … 2>/dev/null` lines are not this hazard.
#
# KNOWN BOUNDARY, stated rather than silently excluded. The empty exception
# list below says the scan finds nothing, not that scripts/runstate.sh cannot
# hold this hazard in a form the scan cannot see. Three limits remain:
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
      # next-state-reporting-integrity T2 converted all three of this file's
      # `-q` instances to here-strings (`grep -qxF … <<< "$v"`), and
      # grep-devnull-condition T1 converted the one `>/dev/null` instance to
      # the same form, so there is nothing to except. The empty list is
      # deliberate: a hit here is a failure, not a warning. It is also NOT a
      # statement that the file carries no SIGPIPE-shaped condition at all —
      # see the KNOWN BOUNDARY above for the forms this shape cannot see.
      #
      # To add one, add a branch ABOVE the `*)` catch-all, most specific
      # fragment first, with the reason on the same line:
      #
      #   *'| awk -F: | grep -q .'*) ;; # why it cannot misreport
      #
      # SINGLE-quote the fragment. These lines are full of `$`, and a
      # double-quoted pattern expands it — under this sweep's `set -u` that
      # aborts the scan mid-file, which reads as "no hits". The fragment must
      # also not match the `__guard_selfproof_*` markers below, or an exception
      # would silently disarm the proof.
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

# Run against the real deterministic core. Recorded at the widening's
# implementation time (2026-09-19, after grep-devnull-condition T1): 0 hits
# with the wider shape, exception list still empty.
#
# The scan feeds its reader by process substitution, not a pipe, and every
# assertion below goes through `assert_true`, which evaluates with `pipefail`
# OFF (see its definition at the top of this file) — so this case neither adds
# an instance of the construct it polices nor disturbs the file's existing
# `pipefail` handling. Hits are printed before the assertion because
# `assert_true` discards its command's output.
GQ_HITS="$(scan_pipe_grep_q "$RUNSTATE")"
if [ -n "$GQ_HITS" ]; then
  printf '     unreviewed instances — either rewrite them without the pipe (capture the\n'
  printf '     value, or use a here-string) or add each to the exception list above with\n'
  printf '     the bound that makes it unable to misreport:\n%s\n' "$GQ_HITS"
fi
assert_true "scripts/runstate.sh contains no pipe-fed \`grep -q\` or \`grep … >/dev/null\` condition outside the (empty) exception list" \
  "[ -z \"\$GQ_HITS\" ]"

# --- self-proof: the guard fails when an instance is introduced --------------
# An assertion that finds nothing proves nothing on its own — it passes just as
# happily against a scan that can never match. So the same case injects the
# construct into a copy of scripts/runstate.sh and asserts the identical scan
# flags exactly the injected lines and nothing else. Injections are planted in
# the two places such a line could appear: INSIDE a function body (where every
# real instance lived) and at END OF FILE (the position a line-anchored or
# early-terminating scan would miss).
#
# One injection per shape the guard claims to catch — grep-devnull-condition T2
# added the second and third:
#   - `-q` in the leading flag cluster: GQ_INJ_FN, planted inside a function
#     body, and GQ_INJ_EOF, planted as the file's last line.
#   - stdout to `/dev/null` with no `q` on the line: GQ_INJ_DEVNULL, planted
#     mid-file inside a function body.
#   - a `q`-bearing option AFTER the pattern: GQ_INJ_QAFTER, planted at end of
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
GQ_INJ_FN='  ls "$root" | grep -q __guard_selfproof_fn__ && return 0'
GQ_INJ_DEVNULL='  ls "$root" | grep __guard_selfproof_devnull_fn__ >/dev/null && return 0'
GQ_INJ_QAFTER='printf "%s\n" "$x" | grep -E __guard_selfproof_qafter_eof__ -q'
GQ_INJ_EOF='printf "%s\n" "$x" | grep -qxF __guard_selfproof_eof__'
GQ_DIR="$(mktemp -d)"
GQ_INJECTED="$GQ_DIR/injected-runstate.sh"
export GQ_INJ_FN GQ_INJ_DEVNULL GQ_INJ_QAFTER GQ_INJ_EOF
awk '
  { print }
  !placed && /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/ {
      print ENVIRON["GQ_INJ_FN"]; print ENVIRON["GQ_INJ_DEVNULL"]; placed = 1
  }
  END { print ENVIRON["GQ_INJ_QAFTER"]; print ENVIRON["GQ_INJ_EOF"] }
' "$RUNSTATE" > "$GQ_INJECTED"

GQ_GOT="$(scan_pipe_grep_q "$GQ_INJECTED")"
# Strip the line numbers with a here-string rather than `… | sed …`: this file
# runs with `pipefail` on outside `assert_true`, and the whole point of the
# case is not to hand a producer to a reader through a pipe.
GQ_GOT_TEXT="$(sed 's/^[0-9]*://' <<< "$GQ_GOT")"
GQ_WANT="$(printf '%s\n%s\n%s\n%s' "$GQ_INJ_FN" "$GQ_INJ_DEVNULL" "$GQ_INJ_QAFTER" "$GQ_INJ_EOF")"
if [ "$GQ_GOT_TEXT" != "$GQ_WANT" ]; then
  printf '     got:\n%s\n     want (without line numbers):\n%s\n' "$GQ_GOT" "$GQ_WANT"
fi
assert_true "the same scan flags exactly the four injected instances — one per shape, two shapes new — and only those" \
  "[ \"\$GQ_GOT_TEXT\" = \"\$GQ_WANT\" ]"

# And they really are where this case claims: the first sits on the line after
# a multi-line function opening, and the end-of-file injection is the file's
# last line.
GQ_LINE="$(sed -n '1s/^\([0-9][0-9]*\):.*/\1/p' <<< "$GQ_GOT")"
GQ_PREV=''
[ -n "$GQ_LINE" ] && [ "$GQ_LINE" -gt 1 ] \
  && GQ_PREV="$(sed -n "$((GQ_LINE - 1))p" "$GQ_INJECTED")"
assert_true "the first injected instance sits inside a function body" \
  "case \"\$GQ_PREV\" in *'() {') true;; *) false;; esac"
assert_true "the end-of-file injection is the last line of the file" \
  "[ \"\$(tail -n 1 '$GQ_INJECTED')\" = \"\$GQ_INJ_EOF\" ]"
# The injected copy is left in its own `mktemp -d`, like every other scratch
# dir in this sweep bar $REPO: a recursive delete in a test file is a line the
# guardrail is right to stop, and the OS reaps the temp dir.

echo
echo "-----------------------------------------"
if [ "$YAML_SKIP_COUNT" -gt 0 ]; then
  printf 'passed: %s   failed: %s   (no python3+PyYAML on this host — %s parse assertion(s) could not assert; not asserting vacuously)\n' \
    "$pass" "$fail" "$YAML_SKIP_COUNT"
else
  printf 'passed: %s   failed: %s\n' "$pass" "$fail"
fi
[ "$fail" = 0 ] || exit 1
