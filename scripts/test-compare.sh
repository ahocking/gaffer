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
# `select`: the tier and fix-round mix chosen over newer packets, `unrecorded`
# and `unmeasured` (a pruned routing log), count and missing-mix shortfalls
# with no cross-class fill, the selection written once and read back
# byte-identical, and the default store in the harness's main checkout.
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

printf '\n== select: a fixture source repository ==\n'
# Five code and two prose packets, interleaved, every one with its original
# handoff on disk (so no plan is needed). Oldest to newest:
#   sel-c1 code integration  routing: fix, pass   -> fix rounds 1
#   sel-c2 code mechanical   routing: pass        -> 0
#   sel-p1 prose docs        no routing record    -> unmeasured
#   sel-c3 code integration  routing: pass        -> 0
#   sel-p2 prose (no tier)   routing in run2: fix, pass -> 1, until run2 is pruned
#   sel-c4 code integration  routing: pass        -> 0
#   sel-c5 code integration  routing: pass        -> 0
# Newest-first alone would take c5, c4, c3 (one tier, no fix round); the mix
# rule must take c1 (the fix round) and c2 (the second tier) over c4 and c3.
FS="$WORK/selfix"
mkdir -p "$FS/scripts" "$FS/agents" "$FS/.agents/loop/run1" "$FS/.agents/loop/run2"
FS_N=0
fs_commit() {  # fs_commit <file> <message> -> prints the new commit's sha
  FS_N=$((FS_N + 1))
  local d; d="2026-02-01T00:$(printf '%02d' "$FS_N"):00Z"
  printf '%s\n' "$FS_N" >> "$FS/$1"
  git -C "$FS" add -A >/dev/null
  GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git -C "$FS" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "$2" >/dev/null
  git -C "$FS" rev-parse HEAD
}
fs_packet() {  # fs_packet <id> <file> <tier-or-empty> -> a landed packet with its original handoff
  local msg
  if [ -n "$3" ]; then msg="$(printf 'land %s\n\n[orch packet:%s]\n[orch tier:%s]' "$1" "$1" "$3")"
  else msg="$(printf 'land %s\n\n[orch packet:%s]' "$1" "$1")"; fi
  mkdir -p "$FS/.agents/loop/run1/$1"
  printf 'original handoff for %s\n' "$1" > "$FS/.agents/loop/run1/$1/handoff.md"
  fs_commit "$2" "$msg" >/dev/null
}
fs_route() {  # fs_route <run> <packet> <token>
  printf '{"ts":"2026-02-01T01:00:00.000Z","packet":"%s","token":"%s","action":"x","status":"s"}\n' "$2" "$3" \
    >> "$FS/.agents/loop/$1/routing.jsonl"
}
git -C "$FS" init -q
printf '.agents/loop/\n' > "$FS/.gitignore"
fs_commit scripts/s.sh base >/dev/null
fs_packet sel-c1 scripts/s.sh integration
fs_packet sel-c2 scripts/s.sh mechanical
fs_packet sel-p1 agents/a.md docs
fs_packet sel-c3 scripts/s.sh integration
fs_packet sel-p2 agents/a.md ''
fs_packet sel-c4 scripts/s.sh integration
fs_packet sel-c5 scripts/s.sh integration
fs_route run1 sel-c1 fix; fs_route run1 sel-c1 pass
for p in sel-c2 sel-c3 sel-c4 sel-c5; do fs_route run1 "$p" pass; done
fs_route run2 sel-p2 fix; fs_route run2 sel-p2 pass

SSET="$(mkset "source_repo: $FS
reviewer_model: opus
per_class: 3
code_files: [scripts/]
prose_files: [agents/]
")"
SEL_ID="$(cs "$SSET"; line EXPERIMENT)"
sel() {  # sel <store> <settings-file>: OUT/ERR/RC
  OUT="$(ORCH_COMPARE_STORE="$1" "$COMPARE" select "$2" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
# chosen <class>: the selected packets of a class, in listed order.
chosen() {
  printf '%s\n' "$OUT" | awk -v c="$1" '
    /^    \{"packet": "[^"]*", "class": "/ {
      split($0, q, "\""); if (q[8] == c) printf "%s%s", (n++ ? " " : ""), q[4] }
    END { print "" }'
}
# row <packet>: that packet's selected line.
row() { printf '%s\n' "$OUT" | awk -v p="    {\"packet\": \"$1\", \"class\": " 'index($0, p) == 1'; }
# shortfall <class> <kind>: that shortfall's line, or nothing.
# (a trailing comma, present on all but the list's last line, is dropped.)
shortfall() { printf '%s\n' "$OUT" | awk -v p="    {\"class\": \"$1\", \"kind\": \"$2\"," 'index($0, p) == 1 { sub(/,$/, ""); print }'; }

STORE1="$WORK/store1"
sel "$STORE1" "$SSET"
assert_eq "select: exit 0" "0" "$RC"
assert_eq "select: the selection is written to <store>/<experiment>/selection.json" \
  "compare.sh: selection written: $STORE1/$SEL_ID/selection.json" "$ERR"
assert_eq "select: stdout is the stored selection" "$(cat "$STORE1/$SEL_ID/selection.json")" "$OUT"
assert_has "select: the selection names its experiment" "\"experiment\": \"$SEL_ID\"" "$OUT"
# The mix is preferred over newer packets: c1 (the only fix round) and c2 (the
# only second tier) are chosen over the newer c4 and c3.
assert_eq "select: the fix-round and tier mix beats newest-first (code)" "sel-c5 sel-c2 sel-c1" "$(chosen code)"
assert_eq "select: a chosen packet lists title, class, tier and measured fix rounds" \
  "    {\"packet\": \"sel-c1\", \"class\": \"code\", \"tier\": \"integration\", \"fix_rounds\": 1, \"title\": \"land sel-c1\", \"handoff\": \"original\"," \
  "$(row sel-c1 | sed 's/ "start".*//')"
assert_has "select: a pass-only routing record is a measured 0" '"packet": "sel-c5", "class": "code", "tier": "integration", "fix_rounds": 0,' "$(row sel-c5)"
assert_has "select: no tier trailer reads unrecorded" '"packet": "sel-p2", "class": "prose", "tier": "unrecorded", "fix_rounds": 1,' "$(row sel-p2)"
assert_has "select: no routing record reads unmeasured, never 0" '"packet": "sel-p1", "class": "prose", "tier": "docs", "fix_rounds": "unmeasured",' "$(row sel-p1)"
assert_eq "select: code has its mix, so no code shortfall" "" "$(printf '%s\n' "$OUT" | awk 'index($0, "    {\"class\": \"code\", \"kind\": ") == 1')"
# Count shortfall: prose asks for 3 and has 2. It is reported and NOT filled
# from the code class, which has two unchosen candidates (c3, c4) to spare.
assert_eq "select: a count shortfall is reported" \
  '    {"class": "prose", "kind": "count", "wanted": 3, "found": 2, "available": 2}' "$(shortfall prose count)"
assert_eq "select: the short class keeps only its own packets (no cross-class fill)" "sel-p2 sel-p1" "$(chosen prose)"
assert_eq "select: the other class keeps exactly its count" "3" "$(chosen code | wc -w | tr -d ' ')"
# Missing-mix shortfall: prose's only recorded tier is docs (unrecorded is an
# absence, not a tier), so the tier mix is short; its fix round is present.
assert_eq "select: a missing tier mix is reported" \
  '    {"class": "prose", "kind": "tiers", "wanted": 2, "found": 1, "available": 1}' "$(shortfall prose tiers)"
assert_eq "select: a satisfied fix-round mix is not reported" "" "$(shortfall prose fix-rounds)"

printf '\n== select: a pruned routing log reads unmeasured ==\n'
# begin-run prunes old run directories: run2's routing log (sel-p2's only
# records) goes. A fresh store, the same settings.
rm -rf "$FS/.agents/loop/run2"
STORE2="$WORK/store2"
sel "$STORE2" "$SSET"
assert_eq "pruned: exit 0" "0" "$RC"
assert_has "pruned: fix rounds read unmeasured, never 0" '"packet": "sel-p2", "class": "prose", "tier": "unrecorded", "fix_rounds": "unmeasured",' "$(row sel-p2)"
# Now prose has no measured fix round: a missing-mix shortfall, naming how many
# of its candidates are unmeasured, and still no code packet (c1 has a fix
# round) borrowed to fill it.
assert_eq "pruned: a missing fix-round mix is reported with the unmeasured count" \
  '    {"class": "prose", "kind": "fix-rounds", "wanted": 1, "found": 0, "available": 0, "unmeasured": 2}' \
  "$(shortfall prose fix-rounds)"
assert_eq "pruned: the missing mix is not filled from the other class" "sel-p2 sel-p1" "$(chosen prose)"
assert_eq "pruned: the code selection is unchanged" "sel-c5 sel-c2 sel-c1" "$(chosen code)"

printf '\n== select: written once, read back unchanged ==\n'
H1="$(cat "$STORE1/$SEL_ID/selection.json")"
FIRST_OUT="$(ORCH_COMPARE_STORE="$STORE1" "$COMPARE" select "$SSET" 2>/dev/null)"
# The source moves on: a newer code packet with a fix round lands, and run2 is
# gone. A recomputed selection would differ; the stored one must not.
fs_packet sel-c6 scripts/s.sh design-heavy
fs_route run1 sel-c6 fix
sel "$STORE1" "$SSET"
assert_eq "second select: exit 0" "0" "$RC"
assert_eq "second select: stdout byte-identical to the first" "$FIRST_OUT" "$OUT"
assert_eq "second select: the stored file is unchanged" "$H1" "$(cat "$STORE1/$SEL_ID/selection.json")"
assert_eq "second select: says it read the selection back" \
  "compare.sh: selection read back unchanged: $STORE1/$SEL_ID/selection.json" "$ERR"
# ... while a fresh store does see the new packet (the fixture change is real).
sel "$WORK/store3" "$SSET"
assert_has "a fresh store recomputes (control)" '"packet": "sel-c6"' "$OUT"
# The stored selection's bytes, not just the printed text (a trailing newline
# a command substitution would strip).
if cmp -s "$STORE1/$SEL_ID/selection.json" <(ORCH_COMPARE_STORE="$STORE1" "$COMPARE" select "$SSET" 2>/dev/null); then
  ok "second select: stdout bytes equal the file's bytes"
else
  bad "second select: stdout bytes equal the file's bytes"
fi

printf '\n== select: the default store is the harness main checkout ==\n'
# A harness copy that is its own git checkout, run from a worktree of it: the
# selection lands in the MAIN checkout's .agents/metrics/comparisons.
HS="$WORK/harness-sel"
mkdir -p "$HS/scripts"
cp "$COMPARE" "$ROUTING" "$HERE/gspec-backlog.sh" "$HS/scripts/"
git -C "$HS" init -q
git -C "$HS" add -A >/dev/null
git -C "$HS" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null commit -q -m harness >/dev/null
git -C "$HS" worktree add -q "$WORK/harness-sel-wt" >/dev/null 2>&1
OUT="$(ORCH_ROUTING_AGENTS_DIR="$REPO/agents" "$WORK/harness-sel-wt/scripts/compare.sh" select "$SSET" 2>/dev/null)"; RC=$?
assert_eq "default store: exit 0" "0" "$RC"
assert_eq "default store: written under the main checkout" "$OUT" \
  "$(cat "$HS/.agents/metrics/comparisons/$SEL_ID/selection.json" 2>/dev/null)"
assert_eq "default store: nothing written under the worktree" "no" \
  "$(if [ -e "$WORK/harness-sel-wt/.agents" ]; then echo yes; else echo no; fi)"

# A refused setting refuses before any git read and writes no selection.
: > "$GITLOG"
OUT="$(PATH="$WORK/bin:$PATH" ORCH_COMPARE_STORE="$WORK/store-refused" "$COMPARE" select "$(mkset "role: reviewer
source_repo: $FS
")" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
assert_eq "select, refused setting: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "select, refused setting: the refusal" "REFUSED setting=role value=reviewer" "$ERR"
no_git "select, refused setting"
assert_eq "select, refused setting: no store written" "no" "$(if [ -e "$WORK/store-refused" ]; then echo yes; else echo no; fi)"

printf '\n== usage ==\n'
"$COMPARE" >/dev/null 2>&1; assert_eq "no subcommand: exit 2" "2" "$?"
"$COMPARE" bogus >/dev/null 2>&1; assert_eq "unknown subcommand: exit 2" "2" "$?"
"$COMPARE" settings >/dev/null 2>&1; assert_eq "settings without a file: exit 2" "2" "$?"
"$COMPARE" settings "$WORK/absent.yaml" >/dev/null 2>&1; assert_eq "settings on a missing file: exit 2" "2" "$?"
"$COMPARE" candidates >/dev/null 2>&1; assert_eq "candidates without a file: exit 2" "2" "$?"
"$COMPARE" select >/dev/null 2>&1; assert_eq "select without a file: exit 2" "2" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
