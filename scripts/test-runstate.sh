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
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
assert_true() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

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
printf '.agents/run-state.yaml\n' > "$REPO/.gitignore"
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
assert_true "set inserts status=running" \
  "\"\$RUNSTATE\" set '$RS' status running && [ \"\$(\"\$RUNSTATE\" get '$RS' status)\" = running ]"
assert_true "set flips status=paused" \
  "\"\$RUNSTATE\" set '$RS' status paused && [ \"\$(\"\$RUNSTATE\" get '$RS' status)\" = paused ]"
assert_true "no temp file left after set" "no_temp"

echo "== atomic full write (temp + rename) round-trips =="
assert_true "write persists full file, green intact" \
  "printf 'schema: 2\nstatus: running\nbranch: $BRANCH\nlast_green_commit: $GREEN\nbacklog:\n  cursor: feature-002\n  pending:\n    - feature-002\n' | \"\$RUNSTATE\" write '$RS' && [ \"\$(\"\$RUNSTATE\" get '$RS' last_green_commit)\" = '$GREEN' ]"
assert_true "no temp file left after write" "no_temp"

echo "== reconcile decision table (checkout clean at green to start) =="
assert_true "clean: HEAD==green, tree clean"        "[ \"\$(decision)\" = clean ]"
printf 'scratch\n' > "$REPO/scratch.txt"
assert_true "discard: uncommitted scratch on green"  "[ \"\$(decision)\" = discard ]"
# the resume action for `discard` is a non-destructive stash, after which the
# tree is clean at green again — prove that returns the decision to `clean`.
git -C "$REPO" stash push --include-untracked -m 'orch resume scratch' -- . >/dev/null
assert_true "clean again after stashing scratch"     "[ \"\$(decision)\" = clean ]"
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
# ADR 0016 — parallel mode: packets-by-status / lanes projections + per-lane
# reconcile. The driver is the single writer; these are read-only projections.
# =============================================================================
echo "== parallel: packets-by-status + lanes projections (no git needed) =="
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
  - id: pc
    status: pending
    depends_on: [pa]
  - id: pd
    status: done
    depends_on: []
lanes:
  - id: pb
    worktree: /tmp/wt/pb
    branch: orch/pb
    packet: pb
    last_green_commit: abc123
    status: running
note: parallel run
EOF
assert_true "packets-by-status done = pa,pd" \
  "[ \"\$(\"\$RUNSTATE\" packets-by-status '$PRS' done | paste -sd, -)\" = 'pa,pd' ]"
assert_true "packets-by-status running = pb" \
  "[ \"\$(\"\$RUNSTATE\" packets-by-status '$PRS' running | paste -sd, -)\" = 'pb' ]"
assert_true "packets-by-status pending = pc" \
  "[ \"\$(\"\$RUNSTATE\" packets-by-status '$PRS' pending | paste -sd, -)\" = 'pc' ]"
assert_true "lanes row parses id+branch+packet" \
  "[ \"\$(\"\$RUNSTATE\" lanes '$PRS')\" = \$'pb\torch/pb\t/tmp/wt/pb\tpb\tabc123\trunning' ]"
rm -f "$PRS"

echo "== parallel: reconcile-parallel applies the decision table per lane =="
PREPO="$(cd "$(mktemp -d)" && pwd -P)"
PWT="$(dirname "$PREPO")/$(basename "$PREPO")-lanes"
trap 'rm -rf "$REPO" "$PREPO" "$PWT"' EXIT
git -c init.defaultBranch=main init -q "$PREPO"
git -C "$PREPO" config user.email t@example.com
git -C "$PREPO" config user.name tester
printf 'root\n' > "$PREPO/README.md"; git -C "$PREPO" add -A; git -C "$PREPO" commit -qm init
git -C "$PREPO" branch develop
mkdir -p "$PWT"
add_lane() { git -C "$PREPO" worktree add -q -b "orch/$1" "$PWT/$1" develop; }

# lane la: green, HEAD==green, clean  -> clean
add_lane la; printf 'a\n' > "$PWT/la/a.txt"; git -C "$PWT/la" add -A; git -C "$PWT/la" commit -qm "pa green"
G_LA="$(git -C "$PWT/la" rev-parse HEAD)"
# lane lb: green + one packet-tagged orphan on top (torn write) -> adopt
add_lane lb; printf 'b\n' > "$PWT/lb/b.txt"; git -C "$PWT/lb" add -A; git -C "$PWT/lb" commit -qm "pb green"
G_LB="$(git -C "$PWT/lb" rev-parse HEAD)"
printf 'b2\n' >> "$PWT/lb/b.txt"; git -C "$PWT/lb" commit -qam "lb: done

[orch packet:lb]"
# lane lc: green, HEAD==green, uncommitted scratch -> discard
add_lane lc; printf 'c\n' > "$PWT/lc/c.txt"; git -C "$PWT/lc" add -A; git -C "$PWT/lc" commit -qm "pc green"
G_LC="$(git -C "$PWT/lc" rev-parse HEAD)"
printf 'scratch\n' > "$PWT/lc/scratch.txt"
# lane ld: dispatched, never committed green -> restart
add_lane ld

PRS="${PREPO}/.agents/run-state.yaml"; mkdir -p "${PREPO}/.agents"
cat > "$PRS" <<EOF
schema: 3
mode: parallel
lanes:
  - id: la
    worktree: ${PWT}/la
    branch: orch/la
    packet: la
    last_green_commit: ${G_LA}
    status: green
  - id: lb
    worktree: ${PWT}/lb
    branch: orch/lb
    packet: lb
    last_green_commit: ${G_LB}
    status: running
  - id: lc
    worktree: ${PWT}/lc
    branch: orch/lc
    packet: lc
    last_green_commit: ${G_LC}
    status: running
  - id: ld
    worktree: ${PWT}/ld
    branch: orch/ld
    packet: ld
    last_green_commit:
    status: running
EOF
lane_dec() { "$RUNSTATE" reconcile-parallel "$PRS" "$PREPO" | sed -n "s/^LANE=$1 DECISION=\\([a-z]*\\).*/\\1/p"; }
agg()      { "$RUNSTATE" reconcile-parallel "$PRS" "$PREPO" | sed -n 's/^AGGREGATE=\([a-z]*\).*/\1/p'; }
assert_true "lane la (HEAD==green, clean) -> clean"        "[ \"\$(lane_dec la)\" = clean ]"
assert_true "lane lb (packet-tagged orphan) -> adopt"      "[ \"\$(lane_dec lb)\" = adopt ]"
assert_true "lane lc (scratch on green) -> discard"        "[ \"\$(lane_dec lc)\" = discard ]"
assert_true "lane ld (no green) -> restart"                "[ \"\$(lane_dec ld)\" = restart ]"
assert_true "aggregate = action (adopt/discard/restart present)" "[ \"\$(agg)\" = action ]"

echo "== parallel: a vanished lane worktree is reconciled via its branch =="
git -C "$PREPO" worktree remove --force "$PWT/la" 2>/dev/null || rm -rf "$PWT/la"
assert_true "lane la still clean when inspected via its branch" "[ \"\$(lane_dec la)\" = clean ]"

echo "== parallel: a diverged lane escalates the aggregate =="
# rewrite lb's tip so its recorded green is no longer an ancestor -> diverged.
git -C "$PWT/lb" commit -q --amend -m "lb: rewritten (green orphaned)"
assert_true "lane lb (diverged) -> escalate"               "[ \"\$(lane_dec lb)\" = escalate ]"
assert_true "aggregate = escalate when any lane escalates"  "[ \"\$(agg)\" = escalate ]"

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
assert_true "explicit pid is recorded when vouched for" \
  "\"\$RUNSTATE\" claim-driver \"\$DRS\" 4242 >/dev/null && [ \"\$(rs_get \"\$DRS\" driver_pid)\" = 4242 ]"

echo
echo "== trim-note: bound the note, archive the overflow (ADR 0019 v3.4) =="
# The template documents `note:` as ONE line; unbounded it reached 164,678 chars —
# 87% of the run-state, re-read on every relay dispatch to recover two facts.
TN="$(mktemp -d)"
{ printf 'status: running\ncursor: t5\nnote: '
  i=0; while [ "$i" -lt 200 ]; do printf 'packet %s narrative. ' "$i"; i=$((i+1)); done
  printf '\nupdated_at: 2026-08-07T00:00:00Z\n'
} > "$TN/run-state.yaml"
assert_true "trim-note shrinks an oversized single-line note" \
  "\"\$RUNSTATE\" trim-note \"$TN/run-state.yaml\" 500 | grep -q '^TRIMMED=yes'"
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
assert_true "trim-note handles the multi-line shape" \
  "\"\$RUNSTATE\" trim-note \"$TN2/run-state.yaml\" 200 | grep -q '^TRIMMED=yes'"
assert_true "trim-note leaves no partial line" \
  "! grep -qE '^  ###? [^ ]*\$' \"$TN2/run-state.yaml\" || true"
assert_true "trim-note keeps trailing keys in the multi-line shape" \
  "grep -q '^updated_at:' \"$TN2/run-state.yaml\""
# a note already within budget must be left completely alone
TN3="$(mktemp -d)"
printf 'status: running\nnote: short\nupdated_at: x\n' > "$TN3/run-state.yaml"
assert_true "trim-note is a no-op under budget" \
  "\"\$RUNSTATE\" trim-note \"$TN3/run-state.yaml\" 2000 | grep -q '^TRIMMED=no'"
assert_true "trim-note under budget writes no archive" \
  "[ ! -f \"$TN3/run-state-note-archive.md\" ]"
assert_true "trim-note tolerates a missing note field" \
  "printf 'status: running\\n' > \"$TN3/b.yaml\" && \"\$RUNSTATE\" trim-note \"$TN3/b.yaml\" | grep -q 'no-note-field'"

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
# not a property worth having — each of these asserts a real YAML parse, not a grep.
yamlok() {  # yamlok <file> -- true if some available parser accepts it
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$1" 2>/dev/null
  else return 0; fi   # no parser available -> do not fail the sweep on this host
}
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
for shape in plain dq block; do
  assert_true "trim-note keeps YAML valid ($shape note)" \
    "\"\$RUNSTATE\" trim-note \"$FT/$shape.yaml\" 200 >/dev/null && yamlok \"$FT/$shape.yaml\""
  assert_true "trim-note preserves the key after note ($shape)" \
    "grep -q '^status: paused' \"$FT/$shape.yaml\""
done

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
echo "== sweep hardening: legacy shapes + a real YAML parse after every mutation (T20) =="
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

# A real parse after EVERY mutating subcommand, each against its OWN fresh copy of
# the legacy fixture. record-outcome/request-pause/clear-pause/pause-status do NOT
# mutate run-state (record-outcome writes a separate outcomes/ log; the pause
# sentinel is its own file) so they are not exercised here.
for mut in set touch write trim-note add-finding drop-finding claim-driver heartbeat; do
  LC="$(mktemp -d)/.agents"; mkdir -p "$LC"
  legacy_fixture > "$LC/run-state.yaml"
  case "$mut" in
    set)          mut_cmd="\"\$RUNSTATE\" set \"$LC/run-state.yaml\" note updated" ;;
    touch)        mut_cmd="\"\$RUNSTATE\" touch \"$LC/run-state.yaml\"" ;;
    write)        mut_cmd="legacy_fixture | \"\$RUNSTATE\" write \"$LC/run-state.yaml\"" ;;
    trim-note)    mut_cmd="\"\$RUNSTATE\" trim-note \"$LC/run-state.yaml\" 5" ;;
    add-finding)  mut_cmd="\"\$RUNSTATE\" add-finding \"$LC/run-state.yaml\" new-2 'legacy add' --packets pkt-z" ;;
    drop-finding) mut_cmd="\"\$RUNSTATE\" drop-finding \"$LC/run-state.yaml\" old-1" ;;
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
assert_true "a done:-free write carries no done: key" \
  "! grep -qE '^[[:space:]]*done:' \"$WD/run-state.yaml\""

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
echo "-----------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
