#!/usr/bin/env bash
# =============================================================================
# test-compare.sh — regression sweep for scripts/compare.sh (model-comparison-harness)
# =============================================================================
# Pins the model-comparison harness WITHOUT a live agent. `settings`: the
# defaults, the shipped template, each role refusal, model validation through
# routing.sh (built-in aliases, the routing reason passed through, `extra_models`
# read from the source repository), the other refusals, the id's invariance
# under reordering, and that no refusal reads git. `candidates`: a fixture
# source repository with a code, a prose, a checkbox-flip-only, a neither and a
# multi-commit packet, original and rebuilt handoffs, and excluded packets.
#
# Run:  scripts/test-compare.sh   (exit 0 = all passed, 1 = a case failed)
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
COMPARE="$HERE/compare.sh"
ROUTING="$HERE/routing.sh"
REPO="$(cd "$HERE/.." && pwd -P)"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '     %s\n' "$2"; fi; fail=$((fail + 1)); }
# Capture-then-compare throughout: no assertion here is a pipe-fed `grep -q`
# (see test-runstate.sh's assert_true for the SIGPIPE-under-pipefail flake).
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "both were [$2]"; fi
}
assert_has() {  # assert_has <label> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$2] not in [$3]" ;; esac
}

WORK="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- a git shim on PATH: every call is logged, so "before any git read" is ----
# checked by the log staying empty, not assumed.
mkdir -p "$WORK/bin"
GITLOG="$WORK/git.log"
: > "$GITLOG"
printf '#!/bin/sh\necho "git $*" >> "%s"\nexit 1\n' "$GITLOG" > "$WORK/bin/git"
chmod +x "$WORK/bin/git"

# --- fixture source repositories ------------------------------------------------
# mksrc <overrides-yaml-or-__MISSING__> -> prints a fresh source root.
mksrc() {
  local r
  r="$(mktemp -d "$WORK/src.XXXXXX")"
  mkdir -p "$r/.agents"
  if [ "$1" != "__MISSING__" ]; then printf '%s' "$1" > "$r/.agents/project-overrides.yaml"; fi
  printf '%s' "$r"
}
# mkset <yaml> -> prints a fresh settings file path.
mkset() {
  local f
  f="$(mktemp "$WORK/set.XXXXXX")"
  printf '%s' "$1" > "$f"
  printf '%s' "$f"
}

# cs <settings-file>: run `compare.sh settings` with the git shim first on PATH.
# OUT = stdout, ERR = stderr, RC = exit status.
OUT=""; ERR=""; RC=0
cs() {
  : > "$GITLOG"
  OUT="$(PATH="$WORK/bin:$PATH" "$COMPARE" settings "$1" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
no_git() { assert_eq "$1: no git call" "" "$(cat "$GITLOG")"; }
line() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

SRC_ROUTED="$(mksrc 'model_routing:
  reviewer: haiku
')"
SRC_BARE="$(mksrc __MISSING__)"
SRC_EXTRA_FLOW="$(mksrc 'model_routing:
  reviewer: opus
extra_models: [gpt9, other-model]
')"
SRC_EXTRA_BLOCK="$(mksrc 'extra_models:
  - gpt9
model_routing:
  reviewer: opus
')"

printf '\n== settings: defaults ==\n'
f="$(mkset "source_repo: $SRC_ROUTED
")"
cs "$f"
assert_eq "defaults: exit 0" "0" "$RC"
assert_eq "defaults: no stderr" "" "$ERR"
no_git "defaults"
EXPECTED="ROLE=implementer
MODELS=fable,opus,sonnet
REVIEWER_MODEL=haiku
SOURCE_REPO=$SRC_ROUTED
PER_CLASS=8
CODE_FILES=hooks/,scripts/
PROSE_FILES=CLAUDE.md,agents/,docs/,skills/,templates/"
assert_eq "defaults: the seven normalized lines" "$EXPECTED" "$(printf '%s\n' "$OUT" | sed '$d')"
ID="$(line EXPERIMENT)"
case "$ID" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok "defaults: EXPERIMENT is 12 hex" ;;
  *) bad "defaults: EXPERIMENT is 12 hex" "got [$ID]" ;;
esac
assert_eq "defaults: EXPERIMENT is the last line" "EXPERIMENT=$ID" "$(printf '%s\n' "$OUT" | sed -n '$p')"

# The reviewer default is what the source repository's reviewer runs on today:
# routing.sh's own answer when it routes one ...
assert_eq "defaults: reviewer default = routing.sh resolve reviewer" \
  "$("$ROUTING" --root "$SRC_ROUTED" resolve reviewer)" "$(line REVIEWER_MODEL)"
# ... else the reviewer agent's frontmatter model.
f="$(mkset "source_repo: $SRC_BARE
")"
cs "$f"
assert_eq "defaults, no routing: exit 0" "0" "$RC"
FM="$(sed -n '2,/^---$/s/^model:[[:space:]]*//p' "$REPO/agents/reviewer.md" | head -1)"
assert_eq "defaults, no routing: reviewer = frontmatter model" "$FM" "$(line REVIEWER_MODEL)"

# An empty file takes every default, the source being this checkout.
f="$(mkset '')"
cs "$f"
assert_eq "empty file: exit 0" "0" "$RC"
assert_eq "empty file: source is this checkout" "$REPO" "$(line SOURCE_REPO)"
no_git "empty file"
EMPTY_ID="$(line EXPERIMENT)"

printf '\n== settings: the shipped template ==\n'
cs "$REPO/templates/model-comparison.yaml"
assert_eq "template: exit 0" "0" "$RC"
assert_eq "template: no stderr" "" "$ERR"
assert_eq "template: role" "implementer" "$(line ROLE)"
assert_eq "template: models" "fable,opus,sonnet" "$(line MODELS)"
assert_eq "template: per_class" "8" "$(line PER_CLASS)"
assert_eq "template: same experiment as the defaults" "$EMPTY_ID" "$(line EXPERIMENT)"

printf '\n== settings: role refusals ==\n'
for r in reviewer loop-driver chief-engineer researcher nobody; do
  f="$(mkset "role: $r
source_repo: $SRC_ROUTED
")"
  cs "$f"
  assert_eq "role $r: exit 1" "1" "$RC"
  assert_eq "role $r: nothing on stdout" "" "$OUT"
  assert_has "role $r: refusal names role" "REFUSED setting=role value=$r reason=" "$ERR"
  no_git "role $r"
done
f="$(mkset "role: reviewer
")"; cs "$f"
assert_has "role reviewer: reason" "reason=reviewer-is-the-fixed-judge" "$ERR"
f="$(mkset "role: loop-driver
")"; cs "$f"
assert_has "role loop-driver: reason" "reason=loop-driver-is-the-session" "$ERR"
f="$(mkset "role: chief-engineer
")"; cs "$f"
assert_has "role chief-engineer: outside the replayable set" "reason=not-replay-dispatchable(" "$ERR"
# Every role a §3.2 handoff dispatches is accepted.
for r in implementer architect ux-designer doc-writer; do
  f="$(mkset "role: $r
source_repo: $SRC_ROUTED
")"
  cs "$f"
  assert_eq "role $r: accepted" "0:ROLE=$r" "$RC:$(printf '%s\n' "$OUT" | sed -n 1p)"
done

printf '\n== settings: model validation through routing.sh ==\n'
# The routing reason, read from routing.sh itself rather than restated here.
RR="$(mksrc 'model_routing:
  implementer: gpt9
')"
ROUTING_REASON="$("$ROUTING" --root "$RR" validate | sed -n 's/^ROUTING-INVALID key=implementer value=gpt9 reason=//p')"
assert_ne "routing.sh itself rejects gpt9" "" "$ROUTING_REASON"
f="$(mkset "source_repo: $SRC_ROUTED
models: [opus, gpt9]
")"
cs "$f"
assert_eq "unknown model: exit 1" "1" "$RC"
assert_eq "unknown model: nothing on stdout" "" "$OUT"
assert_eq "unknown model: refusal names models with the routing reason" \
  "REFUSED setting=models value=gpt9 reason=$ROUTING_REASON" "$ERR"
no_git "unknown model"

f="$(mkset "source_repo: $SRC_ROUTED
reviewer_model: gpt9
")"
cs "$f"
assert_eq "unknown reviewer model: refusal names reviewer_model" \
  "1:REFUSED setting=reviewer_model value=gpt9 reason=$ROUTING_REASON" "$RC:$ERR"
no_git "unknown reviewer model"

# Case-sensitive, exactly as routing.sh compares.
f="$(mkset "source_repo: $SRC_ROUTED
models: [Opus]
")"
cs "$f"
assert_has "capitalized alias refused" "REFUSED setting=models value=Opus reason=" "$ERR"

# extra_models in the SOURCE repository admits a model, flow and block form.
for s in "$SRC_EXTRA_FLOW" "$SRC_EXTRA_BLOCK"; do
  f="$(mkset "source_repo: $s
models: [opus, gpt9]
reviewer_model: gpt9
")"
  cs "$f"
  assert_eq "extra_models ($(basename "$s")): exit 0" "0" "$RC"
  assert_eq "extra_models ($(basename "$s")): models admitted" "gpt9,opus" "$(line MODELS)"
  assert_eq "extra_models ($(basename "$s")): reviewer admitted" "gpt9" "$(line REVIEWER_MODEL)"
  no_git "extra_models ($(basename "$s"))"
done
# ... and only the source's: the harness checkout's own file plays no part. A
# harness copy whose OWN checkout admits other-model must still refuse it when
# the source repository does not.
HARNESS="$WORK/harness"
mkdir -p "$HARNESS/scripts" "$HARNESS/.agents"
cp "$COMPARE" "$ROUTING" "$HARNESS/scripts/"
printf 'extra_models: [other-model]\n' > "$HARNESS/.agents/project-overrides.yaml"
f="$(mkset "source_repo: $SRC_ROUTED
models: [other-model]
")"
: > "$GITLOG"
OUT="$(PATH="$WORK/bin:$PATH" ORCH_ROUTING_AGENTS_DIR="$REPO/agents" "$HARNESS/scripts/compare.sh" settings "$f" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
assert_eq "extra_models of the harness checkout does not leak: exit 1" "1" "$RC"
assert_has "extra_models of the harness checkout does not leak: refused" "REFUSED setting=models value=other-model" "$ERR"
no_git "extra_models of the harness checkout"
# ... while that same harness copy admits it for a source that lists it.
f="$(mkset "source_repo: $SRC_EXTRA_FLOW
models: [other-model]
")"
OUT="$(PATH="$WORK/bin:$PATH" ORCH_ROUTING_AGENTS_DIR="$REPO/agents" "$HARNESS/scripts/compare.sh" settings "$f" 2>/dev/null)"; RC=$?
assert_eq "harness copy runs: source's extra_models admitted" "0:other-model" "$RC:$(line MODELS)"

printf '\n== settings: other refusals ==\n'
refused() {  # refused <label> <yaml> <expected-stderr-fragment>
  local f
  f="$(mkset "$2")"
  cs "$f"
  assert_eq "$1: exit 1" "1" "$RC"
  assert_eq "$1: nothing on stdout" "" "$OUT"
  assert_has "$1: refusal" "$3" "$ERR"
  no_git "$1"
}
refused "unknown key" "source_repo: $SRC_ROUTED
model: opus
" "REFUSED setting=model value=- reason=unknown-setting"
refused "duplicate key" "role: implementer
role: architect
" "REFUSED setting=role value=- reason=duplicate-setting"
refused "per_class 0" "per_class: 0
" "REFUSED setting=per_class value=0 reason=not-a-positive-integer"
refused "per_class word" "per_class: many
" "REFUSED setting=per_class value=many"
refused "empty models" "models: []
" "REFUSED setting=models value=- reason=empty-list"
refused "bare models key" "models:
role: implementer
" "REFUSED setting=models value=- reason=empty-list"
refused "absolute file-set entry" "code_files: [/etc]
" "REFUSED setting=code_files value=/etc reason=not-a-repo-relative-path"
refused "dot-dot file-set entry" "prose_files: [docs/../x]
" "REFUSED setting=prose_files value=docs/../x"
refused "missing source" "source_repo: $WORK/nope
" "REFUSED setting=source_repo value=$WORK/nope reason=not-a-directory"
refused "flow map value" "role: {a: b}
" "REFUSED setting=role value=- reason=unparseable-list"
# A list item is one token. YAML reads `[opus sonnet]` as ONE item, which
# routing.sh rejects whole; split on the space, each half would pass alone.
refused "spaced flow models item" "source_repo: $SRC_ROUTED
models: [opus sonnet]
" "REFUSED setting=models value=opus sonnet reason=whitespace-in-item"
refused "spaced block models item" "source_repo: $SRC_ROUTED
models:
  - \"opus sonnet\"
" "REFUSED setting=models value=opus sonnet reason=whitespace-in-item"
refused "spaced code_files item" "source_repo: $SRC_ROUTED
code_files: [\"scripts/ hooks/\"]
" "REFUSED setting=code_files value=scripts/ hooks/ reason=whitespace-in-item"

f="$(mkset "source_repo: $SRC_ROUTED
per_class: 08
")"
cs "$f"
assert_eq "per_class 08 normalizes to 8" "8" "$(line PER_CLASS)"

printf '\n== settings: reordered-but-equal settings share one id ==\n'
A="$(mkset "role: implementer
models: [sonnet, opus, fable]
reviewer_model: opus
source_repo: $SRC_ROUTED
per_class: 8
code_files:
  - scripts/
  - hooks/
prose_files: [agents/, skills/, templates/, docs/, CLAUDE.md]
")"
B="$(mkset "# same settings, keys and items in another order, one repeat
prose_files:
  - CLAUDE.md
  - ./docs/
  - templates/
  - skills/
  - agents/
code_files: [hooks/, scripts/, hooks/]
per_class: 8
source_repo: \"$SRC_ROUTED\"
reviewer_model: 'opus'
models:
  - fable
  - opus
  - sonnet
role: implementer
")"
cs "$A"; ID_A="$(line EXPERIMENT)"; OUT_A="$OUT"; RC_A="$RC"
cs "$B"; ID_B="$(line EXPERIMENT)"; OUT_B="$OUT"; RC_B="$RC"
assert_eq "reordered: both accepted" "0:0" "$RC_A:$RC_B"
assert_eq "reordered: identical normalized output" "$OUT_A" "$OUT_B"
assert_eq "reordered: same EXPERIMENT id" "$ID_A" "$ID_B"
# A changed value is a different experiment (the id is not a constant).
C="$(mkset "role: implementer
models: [sonnet, opus]
reviewer_model: opus
source_repo: $SRC_ROUTED
")"
cs "$C"
assert_ne "changed model set: different EXPERIMENT id" "$ID_A" "$(line EXPERIMENT)"
C="$(mkset "role: architect
models: [sonnet, opus, fable]
reviewer_model: opus
source_repo: $SRC_ROUTED
")"
cs "$C"
assert_ne "changed role: different EXPERIMENT id" "$ID_A" "$(line EXPERIMENT)"

printf '\n== settings: the id is produced, or nothing is printed ==\n'
# A PATH holding only the tools compare.sh and routing.sh use, never a sha256
# tool unless one is added: no id can be computed, so no settings are printed.
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for t in bash awk sed tr sort paste cut cat mktemp mkdir rm dirname basename; do
  p="$(command -v "$t")" && ln -s "$p" "$TOOLS/$t"
done
f="$(mkset "source_repo: $SRC_ROUTED
")"
OUT="$(PATH="$TOOLS" "$COMPARE" settings "$f" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
assert_eq "no sha256 tool: exit 1" "1" "$RC"
assert_eq "no sha256 tool: nothing on stdout" "" "$OUT"
assert_has "no sha256 tool: reason on stderr" "no sha256 tool" "$ERR"
# The shasum fallback gives the same id as the primary path.
cs "$f"; PRIMARY_ID="$(line EXPERIMENT)"
if SHASUM="$(command -v shasum)" && printf x | shasum -a 256 >/dev/null 2>&1; then
  ln -s "$SHASUM" "$TOOLS/shasum"
  OUT="$(PATH="$TOOLS" "$COMPARE" settings "$f" 2>"$WORK/err")"; RC=$?
  assert_eq "shasum fallback: same id as the primary path" "0:$PRIMARY_ID" "$RC:$(line EXPERIMENT)"
else
  printf 'SKIP shasum fallback: no working shasum on this host\n'
fi

# routing.sh prints nothing for a clean config, so compare.sh without it would
# otherwise admit every model: it must refuse to run instead.
# reviewer_model is pinned so that nothing else in the lone copy (it has no
# agents/ beside it) could refuse in routing.sh's place.
mkdir -p "$WORK/lone"
cp "$COMPARE" "$WORK/lone/compare.sh"
f="$(mkset "source_repo: $SRC_ROUTED
reviewer_model: opus
")"
OUT="$("$WORK/lone/compare.sh" settings "$f" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
assert_eq "no routing.sh: exit 2" "2" "$RC"
assert_eq "no routing.sh: nothing on stdout" "" "$OUT"
assert_has "no routing.sh: named on stderr" "routing.sh is missing" "$ERR"

printf '\n== candidates: a fixture source repository ==\n'
# One commit per step, dated a minute apart so --author-date-order is fixed.
# The feature's plan is the gspec 3.x layout; gspec-backlog.sh (beside
# compare.sh) is what resolves a task, so the fixture only has to be a plan the
# adapter reads.
FX="$WORK/fixture"
mkdir -p "$FX/scripts" "$FX/agents" "$FX/gspec/features/feat" "$FX/.agents/loop/run1/feat-t1"
FX_N=0
fx_commit() {  # fx_commit <message> -> prints the new commit's sha
  FX_N=$((FX_N + 1))
  local d; d="2026-01-01T00:$(printf '%02d' "$FX_N"):00Z"
  git -C "$FX" add -A >/dev/null
  GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git -C "$FX" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "$1" >/dev/null
  git -C "$FX" rev-parse HEAD
}
fx_edit() { printf '%s\n' "$2" >> "$FX/$1"; }          # a real change to <file>
fx_flip() {                                            # tick task <Tn>'s checkbox
  sed "s/^- \[ \] \*\*$1\*\*/- [x] **$1**/" "$FX/gspec/features/feat/tasks.md" > "$FX/t.new"
  mv "$FX/t.new" "$FX/gspec/features/feat/tasks.md"
}
fx_task() {
  printf -- '- [ ] **%s** **P0** Task %s.\n  - deps: —\n  - covers: The capability\n  - arch: —\n' "$1" "$1"
}
git -C "$FX" init -q
printf '.agents/loop/\nt.new\n' > "$FX/.gitignore"
printf 'echo a\n' > "$FX/scripts/a.sh"
printf 'echo b\n' > "$FX/scripts/b.sh"
printf '# x\n' > "$FX/agents/x.md"
printf 'readme\n' > "$FX/README"
printf -- '---\nspec-version: v2\nfeature: feat\n---\n\n# Feat\n\n## Capabilities\n\n- [ ] **The capability**\n' \
  > "$FX/gspec/features/feat/prd.md"
{ printf -- '---\nspec-version: v2\nfeature: feat\n---\n\n# Plan: feat\n\n## Plan\n\n'
  for t in T1 T2 T3 T4 T5 T6; do fx_task "$t"; done; } > "$FX/gspec/features/feat/tasks.md"
C0="$(fx_commit 'base')"
# feat-t1: code (scripts/), with its original handoff still on disk.
fx_edit scripts/a.sh 'echo t1'; fx_flip T1
C1="$(fx_commit "$(printf 't1\n\n[orch packet:feat-t1]\n[orch tier:integration]')")"
printf 'the original handoff\n' > "$FX/.agents/loop/run1/feat-t1/handoff.md"
# feat-t2: prose (agents/), no original: rebuilt from the plan at its parent.
fx_edit agents/x.md 't2'; fx_flip T2
C2="$(fx_commit "$(printf 't2\n\n[orch packet:feat-t2]')")"
# feat-t3: prose plus a checkbox-only gspec/ change. gspec/ is in this
# experiment's code set, so only dropping the checkbox flip keeps it prose.
fx_edit agents/x.md 't3'; fx_flip T3
C3="$(fx_commit "$(printf 't3\n\n[orch packet:feat-t3]')")"
# feat-t4: the control, prose plus a REAL gspec/ change: code.
fx_edit agents/x.md 't4'
sed 's/^\(- \[ \] \*\*T4\*\* \*\*P0\*\*\) Task T4\./\1 Task T4, reworded./' "$FX/gspec/features/feat/tasks.md" > "$FX/t.new"
mv "$FX/t.new" "$FX/gspec/features/feat/tasks.md"
C4="$(fx_commit "$(printf 't4\n\n[orch packet:feat-t4]')")"
# feat-t5: neither set (README) plus a checkbox flip: dropped.
fx_edit README 't5'; fx_flip T5
C5="$(fx_commit "$(printf 't5\n\n[orch packet:feat-t5]')")"
# feat-t6: two trailer commits, prose then code, a commit between them.
fx_edit agents/x.md 't6 part 1'
C6="$(fx_commit "$(printf 't6 part 1\n\n[orch packet:feat-t6]')")"
fx_edit README 'between'
C7="$(fx_commit 'between: this mentions [orch packet:feat-t8] inline, which is no trailer')"
fx_edit scripts/b.sh 'echo t6'; fx_flip T6
C8="$(fx_commit "$(printf 't6 part 2\n\n[orch packet:feat-t6]')")"
# feat-t9: its task is only added to the plan AFTER it lands, so the plan at
# its parent does not have it: no suppliable handoff.
fx_edit agents/x.md 't9'
C9="$(fx_commit "$(printf 't9\n\n[orch packet:feat-t9]')")"
fx_task T9 >> "$FX/gspec/features/feat/tasks.md"
C10="$(fx_commit 'plan: add T9')"
# ghost-1: not a gspec task id at all.
fx_edit agents/x.md 'ghost'
C11="$(fx_commit "$(printf 'ghost\n\n[orch packet:ghost-1]')")"

CSET="$(mkset "source_repo: $FX
reviewer_model: opus
code_files: [scripts/, gspec/]
")"
cand() {  # cand <settings-file>: OUT/ERR/RC as cs sets them
  OUT="$("$COMPARE" candidates "$1" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
pk() { printf '%s\n' "$OUT" | awk -v p="packet=$1" '$2 == p'; }
cand "$CSET"
assert_eq "candidates: exit 0" "0" "$RC"
assert_eq "candidates: no stderr" "" "$ERR"
assert_eq "candidates: every trailer packet once, oldest first; an inline mention is no trailer" \
  "feat-t1 feat-t2 feat-t3 feat-t4 feat-t5 feat-t6 feat-t9 ghost-1" \
  "$(printf '%s\n' "$OUT" | sed -n 's/^[A-Z]* packet=\([^ ]*\).*/\1/p' | paste -sd' ' -)"
assert_eq "candidates: a code packet, its original handoff" \
  "CANDIDATE packet=feat-t1 class=code handoff=original start=$C0 commits=$C1" "$(pk feat-t1)"
assert_eq "candidates: a prose packet, a rebuilt handoff" \
  "CANDIDATE packet=feat-t2 class=prose handoff=rebuilt start=$C1 commits=$C2" "$(pk feat-t2)"
assert_eq "candidates: a checkbox-only gspec/ change does not make a packet code" \
  "CANDIDATE packet=feat-t3 class=prose handoff=rebuilt start=$C2 commits=$C3" "$(pk feat-t3)"
assert_eq "candidates: a real gspec/ change in the code set does (control)" \
  "CANDIDATE packet=feat-t4 class=code handoff=rebuilt start=$C3 commits=$C4" "$(pk feat-t4)"
assert_eq "candidates: a packet in neither set is dropped, not a candidate" \
  "DROPPED packet=feat-t5 class=neither" "$(pk feat-t5)"
assert_eq "candidates: multi-commit packet classed from the union, started at the earliest commit's parent" \
  "CANDIDATE packet=feat-t6 class=code handoff=rebuilt start=$C5 commits=$C6,$C8" "$(pk feat-t6)"
assert_eq "candidates: a task absent from the plan at the parent is excluded, named with the adapter's reason" \
  "EXCLUDED packet=feat-t9 reason=no original handoff, and gspec-backlog.sh does not resolve the task at the start commit: feat has no task t9 in gspec/features/feat/tasks.md" \
  "$(pk feat-t9)"
assert_has "candidates: a non-gspec id with no original is excluded, named with the reason" \
  "EXCLUDED packet=ghost-1 reason=no original handoff, and gspec-backlog.sh does not resolve the task at the start commit: not a gspec task id" \
  "$(pk ghost-1)"
# The original handoff wins over a rebuild, and only its own packet's counts.
mkdir -p "$FX/.agents/loop/run2/ghost-1"
printf 'original\n' > "$FX/.agents/loop/run2/ghost-1/handoff.md"
cand "$CSET"
assert_eq "candidates: an original handoff supplies a packet no plan resolves" \
  "CANDIDATE packet=ghost-1 class=prose handoff=original start=$C10 commits=$C11" "$(pk ghost-1)"
assert_eq "candidates: another packet's original handoff is not borrowed" \
  "EXCLUDED" "$(pk feat-t9 | cut -d' ' -f1)"
# The source repository is left as it was: nothing staged, nothing written.
assert_eq "candidates: the fixture's tree is untouched" "" "$(git -C "$FX" status --porcelain)"
assert_eq "candidates: the fixture's HEAD is untouched" "$C11" "$(git -C "$FX" rev-parse HEAD)"

# A refused setting refuses before any git read, exactly as `settings` does.
: > "$GITLOG"
OUT="$(PATH="$WORK/bin:$PATH" "$COMPARE" candidates "$(mkset "role: reviewer
source_repo: $FX
")" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
assert_eq "candidates, refused setting: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "candidates, refused setting: the refusal" "REFUSED setting=role value=reviewer" "$ERR"
no_git "candidates, refused setting"
# A source that is not a git repository is an error, not an empty list.
cand "$(mkset "source_repo: $SRC_ROUTED
")"
assert_eq "candidates, no git repository: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "candidates, no git repository: named" "not a git repository" "$ERR"

printf '\n== usage ==\n'
"$COMPARE" >/dev/null 2>&1; assert_eq "no subcommand: exit 2" "2" "$?"
"$COMPARE" bogus >/dev/null 2>&1; assert_eq "unknown subcommand: exit 2" "2" "$?"
"$COMPARE" settings >/dev/null 2>&1; assert_eq "settings without a file: exit 2" "2" "$?"
"$COMPARE" settings "$WORK/absent.yaml" >/dev/null 2>&1; assert_eq "settings on a missing file: exit 2" "2" "$?"
"$COMPARE" candidates >/dev/null 2>&1; assert_eq "candidates without a file: exit 2" "2" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
