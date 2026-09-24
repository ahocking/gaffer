#!/usr/bin/env bash
# =============================================================================
# test-compare.sh — regression sweep for scripts/compare.sh (model-comparison-harness)
# =============================================================================
# Pins the model-comparison harness WITHOUT a live agent. `settings`: the
# defaults, the shipped template, each role refusal, model validation through
# routing.sh (built-in aliases, the routing reason passed through, `extra_models`
# read from the source repository), the other refusals, the id's invariance
# under reordering, `model_ids` (printed, part of the id, every model and the
# reviewer pinned to a non-empty id or refused naming it), and that no refusal
# reads git. `candidates`: a fixture
# source repository with a code, a prose, a checkbox-flip-only, a neither and a
# multi-commit packet, original and rebuilt handoffs, and excluded packets.
# `select`: the tier and fix-round mix chosen over newer packets, `unrecorded`
# and `unmeasured` (a pruned routing log), count and missing-mix shortfalls
# with no cross-class fill, the selection written once and read back
# byte-identical, and the default store in the harness's main checkout.
# `estimate`: the replay count, per-model and total dollars from a fixture price
# table (a directly keyed model, an agreeing family, a disagreeing family left
# unpriced), an unmeasured packet named and excluded, the newest measured
# run-metrics row used, `--remaining` after some records exist, and two
# estimates issuing different pending tokens bound to their sets. `prepare`:
# six clones (two packets x three models) leaving the source's `git status`,
# `.agents/` tree and `for-each-ref` byte-identical, each clone on its start
# commit and one opaque branch with no remote, `routing.sh --root <clone>`
# resolving the model and the reviewer model with every other config line
# kept, each packet's three handoffs byte-identical from the per-packet cache
# (an original copied verbatim, a rebuilt one carrying the verification
# contract), no directory or branch name containing a model identifier, and
# the refusals leaving no clone behind. A spliced original, built by the real
# `runstate.sh refresh-handoff` and `amend-handoff`, installed as the plain
# first-dispatch handoff for all three models from the earliest run, with the
# store inside the source's `.agents/metrics/comparisons` leaving everything
# outside the experiment's own store unchanged. `review-view`: two replays (two
# subject models, a third as reviewer) doing identical work, each work clone
# left byte-identical; the view on one opaque branch with two fixed, neutral,
# trailer-free commits; the reviewed change holding the committed, unstaged and
# untracked work and the packet's own config edit but no routing, metrics or
# run-state path (those un-ignored in the fixture, so the exclusion is what
# keeps them out); `routing.sh --root <view>` resolving only the reviewer; a
# search of files, log, refs and paths for every model identifier finding
# nothing the start did not hold; the result file and handoff redacted in every
# form, header paths pointed into the view; the two models' views identical;
# and refusals (unknown replay, a scratch root naming a model) leaving no view.
# `replay`: every agent step through a scripted stub session (ORCH_COMPARE_CLAUDE)
# for pass first time, fix then pass, continue then pass, escalate, fix past the
# limit, a crashed and a timed-out step, and check-status's one re-dispatch; each
# leaving the clone with at most one new commit, on the start, touching no
# gspec/ or .agents/roadmap.yaml path and carrying no routing change (a packet's
# own edit to project-overrides.yaml kept); no chief-engineer session ever; the
# harness checkout as every session's plugin dir and routing.sh, never the
# clone's own agents/ or scripts/; a fresh view per review; and a second replay
# of the same id refused. `routing-check`: the real metrics.sh collecting
# fixture event logs and transcripts in a replay's work clone and review view
# (aliases stamped at dispatch, full ids in transcripts, the experiment's
# model_ids pinning one to the other): a clean replay passing, an override
# count of 1, a null override count, a same-family different-version subject
# model, a wrong reviewer model and an unpinned resolved alias each failing on a
# line naming its check, an empty stamp read as unresolved, the packets written
# outside the view, and a replay whose step log has no END or whose selection
# pins no id for its model refused.
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
# mkset <yaml> -> prints a fresh settings file path. A file that names no
# `model_ids` gets PINS appended: the shipped template's own map plus a pin for
# every other alias these cases name, so a case about another setting is never
# refused for a missing pin. An entry for an alias the experiment does not run
# on is left out of the settings, so the extra pins never move an id.
# mkset_raw <yaml> writes the yaml alone.
TEMPLATE_PINS="$(awk '/^model_ids:/ { on = 1; print; next } on && /^[[:space:]]/ { print; next } { on = 0 }' "$REPO/templates/model-comparison.yaml")"
PINS="$TEMPLATE_PINS
  haiku: claude-haiku-test
  gpt9: gpt9-test
  other-model: other-model-test
  Opus: opus-capital-test"
# pins_for <alias>... -> the MODEL_IDS value PINS gives those aliases (sorted).
pins_for() {
  local a out=""
  for a in $(printf '%s\n' "$@" | LC_ALL=C sort -u); do
    out="${out:+$out,}$a:$(printf '%s\n' "$PINS" | A="$a" awk '{ k = $1; sub(/:$/, "", k) } k == ENVIRON["A"] { print $2; exit }')"
  done
  printf '%s' "$out"
}
mkset_raw() {
  local f
  f="$(mktemp "$WORK/set.XXXXXX")"
  printf '%s' "$1" > "$f"
  printf '%s' "$f"
}
mkset() {
  case "$1" in
    *model_ids*) mkset_raw "$1" ;;
    *) mkset_raw "$1${1:+
}$PINS
" ;;
  esac
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
MODEL_IDS=$(pins_for fable haiku opus sonnet)
SOURCE_REPO=$SRC_ROUTED
PER_CLASS=8
CODE_FILES=hooks/,scripts/
PROSE_FILES=CLAUDE.md,agents/,docs/,skills/,templates/"
assert_eq "defaults: the eight normalized lines (only the run's aliases pinned)" "$EXPECTED" "$(printf '%s\n' "$OUT" | sed '$d')"
case "$(line MODEL_IDS)" in
  *:,*|*:) bad "defaults: every printed pin is non-empty" "got [$(line MODEL_IDS)]" ;;
  *) ok "defaults: every printed pin is non-empty" ;;
esac
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

# A file of pins alone takes every other default, the source being this checkout.
f="$(mkset '')"
cs "$f"
assert_eq "pins only: exit 0" "0" "$RC"
assert_eq "pins only: source is this checkout" "$REPO" "$(line SOURCE_REPO)"
no_git "pins only"
EMPTY_ID="$(line EXPERIMENT)"

printf '\n== settings: the shipped template ==\n'
cs "$REPO/templates/model-comparison.yaml"
assert_eq "template: exit 0" "0" "$RC"
assert_eq "template: no stderr" "" "$ERR"
assert_eq "template: role" "implementer" "$(line ROLE)"
assert_eq "template: models" "fable,opus,sonnet" "$(line MODELS)"
assert_eq "template: per_class" "8" "$(line PER_CLASS)"
case "$(line MODEL_IDS)" in
  fable:?*,opus:?*,sonnet:?*) ok "template: model_ids pins each of its models" ;;
  *) bad "template: model_ids pins each of its models" "got [$(line MODEL_IDS)]" ;;
esac
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

printf '\n== settings: model_ids pins each alias to one id ==\n'
# Two settings differing only in one pinned id are two experiments.
P1="$(mkset_raw "models: [opus, sonnet]
reviewer_model: opus
source_repo: $SRC_ROUTED
model_ids:
  opus: claude-opus-5-5
  sonnet: claude-sonnet-5
")"
P2="$(mkset_raw "models: [opus, sonnet]
reviewer_model: opus
source_repo: $SRC_ROUTED
model_ids:
  opus: claude-opus-5
  sonnet: claude-sonnet-5
")"
cs "$P1"; ID_P1="$(line EXPERIMENT)"; RC_P1="$RC"; IDS_P1="$(line MODEL_IDS)"
cs "$P2"; ID_P2="$(line EXPERIMENT)"; RC_P2="$RC"
assert_eq "model_ids: both accepted" "0:0" "$RC_P1:$RC_P2"
assert_eq "model_ids: printed as alias:id items, sorted" "opus:claude-opus-5-5,sonnet:claude-sonnet-5" "$IDS_P1"
assert_ne "model_ids: settings differing only in one pinned id get different EXPERIMENT ids" "$ID_P1" "$ID_P2"
# A pin for an alias the experiment does not run on is left out, id unmoved.
P3="$(mkset_raw "models: [opus, sonnet]
reviewer_model: opus
source_repo: $SRC_ROUTED
model_ids:
  sonnet: 'claude-sonnet-5'   # quoted, with a comment
  haiku: claude-haiku-4-5
  opus: \"claude-opus-5-5\"
")"
cs "$P3"
assert_eq "model_ids: an unused pin, quoting and entry order leave the id unmoved" "0:$ID_P1" "$RC:$(line EXPERIMENT)"
# A model or the reviewer with no pin, or an empty pin, is refused naming model_ids,
# before any git read.
refused_raw() {  # refused_raw <label> <yaml> <expected-stderr-fragment>
  local f
  f="$(mkset_raw "$2")"
  cs "$f"
  assert_eq "$1: exit 1" "1" "$RC"
  assert_eq "$1: nothing on stdout" "" "$OUT"
  assert_has "$1: refusal" "$3" "$ERR"
  no_git "$1"
}
refused_raw "model_ids: a model with no pinned id" "models: [opus, sonnet]
reviewer_model: opus
source_repo: $SRC_ROUTED
model_ids:
  opus: claude-opus-5-5
" "REFUSED setting=model_ids value=sonnet reason=no-pinned-id(named by models)"
refused_raw "model_ids: an explicit reviewer model with no pinned id" "models: [opus]
reviewer_model: haiku
source_repo: $SRC_ROUTED
model_ids:
  opus: claude-opus-5-5
" "REFUSED setting=model_ids value=haiku reason=no-pinned-id(named by reviewer_model)"
refused_raw "model_ids: the defaulted reviewer model with no pinned id" "models: [opus]
source_repo: $SRC_ROUTED
model_ids:
  opus: claude-opus-5-5
" "REFUSED setting=model_ids value=haiku reason=no-pinned-id(the reviewer_model default"
refused_raw "model_ids: an empty pinned id" "models: [opus]
reviewer_model: opus
source_repo: $SRC_ROUTED
model_ids:
  opus: ''
" "REFUSED setting=model_ids value=opus reason=empty-id"
refused_raw "model_ids: a bare alias with no id" "models: [opus]
reviewer_model: opus
source_repo: $SRC_ROUTED
model_ids:
  opus:
" "REFUSED setting=model_ids value=opus reason=empty-id"
refused_raw "model_ids: absent altogether" "models: [opus]
reviewer_model: opus
source_repo: $SRC_ROUTED
" "REFUSED setting=model_ids value=opus reason=no-pinned-id(named by models)"
refused_raw "model_ids: an empty file (no pins by default)" "" \
  "REFUSED setting=model_ids value=fable reason=no-pinned-id(named by models)"
refused_raw "model_ids: a list, not a map" "models: [opus]
reviewer_model: opus
model_ids: [claude-opus-5-5]
" "REFUSED setting=model_ids value=- reason=expected-a-map("
refused_raw "model_ids: a duplicate alias" "models: [opus]
reviewer_model: opus
model_ids:
  opus: claude-opus-5-5
  opus: claude-opus-5
" "REFUSED setting=model_ids value=opus reason=duplicate-alias"
refused_raw "model_ids: an id with a space" "models: [opus]
reviewer_model: opus
model_ids:
  opus: claude opus
" "REFUSED setting=model_ids value=opus reason=invalid-model-id(claude opus)"
refused_raw "model_ids: a block mixing entries and items" "models: [opus]
reviewer_model: opus
model_ids:
  opus: claude-opus-5-5
  - claude-opus-5
" "REFUSED setting=model_ids value=- reason=unparseable-list"
# A value holding a literal tab keeps it: the settings records are tab-separated,
# so a reader splitting every record into one field more than a scalar or list
# item has would drop everything after the tab and accept the truncated value.
TAB="$(printf '\t')"
refused_raw "a scalar with an embedded tab (role)" "role: \"implementer${TAB}junk\"
models: [opus]
reviewer_model: opus
source_repo: $SRC_ROUTED
model_ids:
  opus: claude-opus-5-5
" "REFUSED setting=role value=implementer${TAB}junk reason=not-replay-dispatchable"
refused_raw "a list item with an embedded tab (models)" "models: [opus, \"sonnet${TAB}haiku\"]
reviewer_model: opus
source_repo: $SRC_ROUTED
model_ids:
  opus: claude-opus-5-5
  sonnet: claude-sonnet-5
" "REFUSED setting=models value=sonnet${TAB}haiku reason=whitespace-in-item"
refused_raw "model_ids: an id with an embedded tab" "models: [opus]
reviewer_model: opus
source_repo: $SRC_ROUTED
model_ids:
  opus: \"claude-opus-5-5${TAB}claude-opus-5\"
" "REFUSED setting=model_ids value=opus reason=invalid-model-id(claude-opus-5-5${TAB}claude-opus-5)"
refused_raw "a map under a list key" "models:
  opus: claude-opus-5-5
model_ids:
  opus: claude-opus-5-5
" "REFUSED setting=models value=- reason=expected-a-list"

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
SEL_PINS="$(printf '%s\n' "$OUT" | jq -r '.settings.model_ids | to_entries | map("\(.key):\(.value)") | join(",")')"
assert_eq "select: the stored settings carry model_ids, as settings printed them" \
  "$(cs "$SSET"; line MODEL_IDS)" "$SEL_PINS"
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

printf '\n== estimate: a fixture store, source and price table ==\n'
# The estimate reads only the stored selection (experiment, settings.models,
# settings.source_repo, selected[].packet), the source's run-metrics and the
# price table, so the selections here are written directly.
#   est-e1  measured twice: run-a (older, decoy figures) and run-b (newer, used)
#   est-e2  measured once, in run-a
#   est-e3  tokens null in run-b, no other row: unmeasured
#   est-e4  all-zero in run-b (newer), measured in run-a (older): run-a is used
ES="$WORK/estsrc"
mkdir -p "$ES/.agents/metrics/run-a" "$ES/.agents/metrics/run-b"
# rm_row <id> <input> <output> <cache_creation> <cache_read> | rm_row <id> null
# Each measured row also carries a dispatch row with decoy tokens, which the
# estimate must not read as the packet's.
rm_row() {
  if [ "$2" = null ]; then
    printf '    {\n      "id": "%s",\n      "tokens": null,\n      "dispatches": null\n    }' "$1"
  else
    printf '    {\n      "id": "%s",\n      "tokens": {\n        "input": %s,\n        "output": %s,\n        "cache_creation": %s,\n        "cache_read": %s\n      },\n      "dispatches": [\n        {\n          "tokens": {\n            "input": 777777777,\n            "output": 777777777,\n            "cache_creation": 777777777,\n            "cache_read": 777777777\n          }\n        }\n      ]\n    }' "$1" "$2" "$3" "$4" "$5"
  fi
}
mkrm() {  # mkrm <run> <generated_at> <row>...
  local run="$1" gen="$2" sep="" r; shift 2
  {
    printf '{\n  "schema": 2,\n  "run_id": "%s",\n  "generated_at": "%s",\n  "token_source": "transcript",\n  "packets": [\n' "$run" "$gen"
    for r in "$@"; do printf '%s' "$sep"; eval "rm_row $r"; sep=",
"; done
    printf '\n  ]\n}\n'
  } > "$ES/.agents/metrics/$run/run-metrics.json"
}
mkrm run-a 2026-03-01T00:00:00Z "est-e1 5 5 5 5" "est-e2 0 200000 0 1000000" "est-e4 0 100000 0 0"
mkrm run-b 2026-03-02T00:00:00Z "est-e1 1000000 100000 200000 2000000" "est-e3 null" "est-e4 0 0 0 0"

# USD per million tokens. alpha is keyed directly; beta only through a
# claude-beta-* family whose entries agree; gamma's family entries disagree.
EPRICES="$WORK/prices.json"
cat > "$EPRICES" <<'EOF'
{
  "table_date": "2026-03-15",
  "prices": {
    "alpha":          { "input": 2, "cache_write_5m": 2.50, "cache_write_1h": 4, "cache_read": 0.20, "output": 10 },
    "claude-beta-1":  { "input": 1, "cache_write_5m": 1.25, "cache_write_1h": 2, "cache_read": 0.10, "output": 5 },
    "claude-beta-2":  { "input": 1, "cache_write_5m": 1.25, "cache_write_1h": 2, "cache_read": 0.10, "output": 5 },
    "claude-gamma-1": { "input": 1, "cache_write_5m": 1.25, "cache_write_1h": 2, "cache_read": 0.10, "output": 5 },
    "claude-gamma-2": { "input": 1, "cache_write_5m": 1.25, "cache_write_1h": 2, "cache_read": 0.20, "output": 5 }
  }
}
EOF
ESTORE="$WORK/eststore"
mksel() {  # mksel <experiment> <models-csv> <packet>...
  local exp="$1" models="$2" ms="" m p sep=""; shift 2
  for m in $(printf '%s' "$models" | tr ',' ' '); do ms="$ms${ms:+, }\"$m\""; done
  mkdir -p "$ESTORE/$exp"
  {
    printf '{\n  "experiment": "%s",\n' "$exp"
    printf '  "settings": {"role": "implementer", "models": [%s], "reviewer_model": "opus", "source_repo": "%s", "per_class": 2, "code_files": ["scripts/"], "prose_files": ["agents/"]},\n' "$ms" "$ES"
    printf '  "selected": [\n'
    for p in "$@"; do
      printf '%s    {"packet": "%s", "class": "code", "tier": "integration", "fix_rounds": 0, "title": "land %s", "handoff": "original", "start": "0000000", "commits": ["1111111"]}' "$sep" "$p" "$p"
      sep=",
"
    done
    printf '\n  ],\n  "shortfalls": [],\n  "excluded": [],\n  "dropped": []\n}\n'
  } > "$ESTORE/$exp/selection.json"
}
est() {  # est <args...>: OUT/ERR/RC
  OUT="$(ORCH_COMPARE_STORE="$ESTORE" ORCH_COMPARE_PRICES="$EPRICES" "$COMPARE" estimate "$@" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
eline() { printf '%s\n' "$OUT" | awk -v p="$1 " 'index($0, p) == 1'; }
lines_of() { printf '%s\n' "$OUT" | awk -v p="$1 " 'index($0, p) == 1'; }

EA=aaaaaaaaaaa1
mksel "$EA" alpha,beta est-e1 est-e2 est-e3
est "$EA"
assert_eq "estimate: exit 0" "0" "$RC"
assert_eq "estimate: no stderr" "" "$ERR"
assert_eq "estimate: the replay count is packets x models (3 x 2)" "6" "$(line REPLAYS)"
assert_eq "estimate: scope all, nothing recorded" "all:0" "$(line SCOPE):$(line RECORDED)"
assert_eq "estimate: every replay listed, packet then model, stored order" \
"REPLAY packet=est-e1 model=alpha
REPLAY packet=est-e1 model=beta
REPLAY packet=est-e2 model=alpha
REPLAY packet=est-e2 model=beta
REPLAY packet=est-e3 model=alpha
REPLAY packet=est-e3 model=beta" "$(lines_of REPLAY)"
assert_eq "estimate: the price table's date is stated" "2026-03-15" "$(line PRICE_TABLE_DATE)"
# Per-model dollars, worked by hand from the fixture table (est-e1 from run-b,
# est-e2 from run-a; cache writes at the 5-minute rate for min, 1-hour for max):
#   alpha e1 2.00+1.00+0.40+0.50=3.90 (max +0.30=4.20), e2 2.00+0.20=2.20 -> 6.10 / 6.40
#   beta  e1 1.00+0.50+0.20+0.25=1.95 (max +0.15=2.10), e2 1.00+0.10=1.10 -> 3.05 / 3.20
assert_eq "estimate: alpha priced from its own table entry" \
  "ESTIMATE model=alpha replays=3 estimated=2 tokens=4500000 input=1000000 output=300000 cache_creation=200000 cache_read=3000000 dollars_min=6.10 dollars_max=6.40 price=alpha" \
  "$(eline "ESTIMATE model=alpha")"
assert_eq "estimate: beta priced through its agreeing claude-beta-* family" \
  "ESTIMATE model=beta replays=3 estimated=2 tokens=4500000 input=1000000 output=300000 cache_creation=200000 cache_read=3000000 dollars_min=3.05 dollars_max=3.20 price=family:claude-beta-1,claude-beta-2" \
  "$(eline "ESTIMATE model=beta")"
assert_eq "estimate: the total across models" \
  "ESTIMATE model=total replays=6 estimated=4 tokens=9000000 input=2000000 output=600000 cache_creation=400000 cache_read=6000000 dollars_min=9.15 dollars_max=9.60" \
  "$(eline "ESTIMATE model=total")"
# est-e3's cost is unmeasured: named, excluded, and never counted as 0 (the
# replays still run, so they stay in the count; only the estimate omits them).
assert_eq "estimate: an unmeasured packet is named and excluded" \
  "EXCLUDED packet=est-e3 reason=original cost unmeasured, excluded from the estimate: no measured row among 1 run-metrics row(s) (tokens null: 1, all zero: 0, no transcript token source: 0)" \
  "$(lines_of EXCLUDED)"
assert_eq "estimate: no model is unpriced" "" "$(lines_of UNPRICED)"
APPROVAL1="$(line APPROVAL)"
case "$APPROVAL1" in
  ''|none|*[!0-9a-f]*) bad "estimate: an APPROVAL token is printed" "got [$APPROVAL1]" ;;
  *) ok "estimate: an APPROVAL token is printed" ;;
esac
assert_eq "estimate: APPROVAL is the last line" "APPROVAL=$APPROVAL1" "$(printf '%s\n' "$OUT" | sed -n '$p')"
APPR_LAST="$(tail -1 "$ESTORE/$EA/approvals.jsonl" 2>/dev/null)"
assert_has "estimate: the token is stored as pending" "{\"token\":\"$APPROVAL1\",\"state\":\"pending\",\"experiment\":\"$EA\",\"scope\":\"all\"," "$APPR_LAST"
assert_has "estimate: the stored token is bound to exactly the printed set" \
  '"replays":[{"packet":"est-e1","model":"alpha"},{"packet":"est-e1","model":"beta"},{"packet":"est-e2","model":"alpha"},{"packet":"est-e2","model":"beta"},{"packet":"est-e3","model":"alpha"},{"packet":"est-e3","model":"beta"}]}' \
  "$APPR_LAST"

printf '\n== estimate: two estimates issue different tokens ==\n'
est "$EA"
APPROVAL2="$(line APPROVAL)"
assert_eq "second estimate: exit 0" "0" "$RC"
assert_ne "second estimate: a different token" "$APPROVAL1" "$APPROVAL2"
assert_eq "second estimate: both stored pending, newest last" \
  "$APPROVAL1 pending
$APPROVAL2 pending" \
  "$(sed 's/^{"token":"\([0-9a-f]*\)","state":"\([a-z]*\)".*/\1 \2/' "$ESTORE/$EA/approvals.jsonl")"

printf '\n== estimate: unpriced model and zero rows ==\n'
EB=aaaaaaaaaaa2
mksel "$EB" alpha,gamma est-e2 est-e4
est "$EB"
assert_eq "unpriced: exit 0" "0" "$RC"
assert_eq "unpriced: a family with differing rates is named, not guessed" \
  "UNPRICED model=gamma reason=the claude-gamma-* entries carry different rates, and which one gamma resolves to is not recorded (claude-gamma-1,claude-gamma-2)" \
  "$(lines_of UNPRICED)"
# est-e4's newer run-b row is all zero, so the older measured run-a row is used.
assert_eq "unpriced: its dollars read unmeasured, its tokens stand" \
  "ESTIMATE model=gamma replays=2 estimated=2 tokens=1300000 input=0 output=300000 cache_creation=0 cache_read=1000000 dollars_min=unmeasured dollars_max=unmeasured price=unpriced" \
  "$(eline "ESTIMATE model=gamma")"
assert_eq "unpriced: the total's dollars read unmeasured, never a partial sum" \
  "ESTIMATE model=total replays=4 estimated=4 tokens=2600000 input=0 output=600000 cache_creation=0 cache_read=2000000 dollars_min=unmeasured dollars_max=unmeasured" \
  "$(eline "ESTIMATE model=total")"
assert_eq "zero row: an all-zero newer row does not replace a measured one" "" "$(lines_of EXCLUDED)"

EC=aaaaaaaaaaa3
mksel "$EC" alpha est-e3
est "$EC"
assert_eq "all unmeasured: tokens and dollars read unmeasured, never 0" \
  "ESTIMATE model=alpha replays=1 estimated=0 tokens=unmeasured input=unmeasured output=unmeasured cache_creation=unmeasured cache_read=unmeasured dollars_min=unmeasured dollars_max=unmeasured price=alpha" \
  "$(eline "ESTIMATE model=alpha")"

printf '\n== estimate: --remaining after some records exist ==\n'
# Two records of this experiment (one invalid: any record counts) and one of
# another experiment on a replay this one has not recorded.
{
  printf '{"experiment":"%s","packet":"est-e1","model":"alpha","outcome":"passed"}\n' "$EA"
  printf '{"experiment": "%s", "packet": "est-e3", "model": "beta", "outcome": "invalid"}\n' "$EA"
  printf '{"experiment":"%s","packet":"est-e2","model":"alpha","outcome":"passed"}\n' "$EB"
} > "$ESTORE/records.jsonl"
est "$EA" --remaining
assert_eq "remaining: exit 0" "0" "$RC"
assert_eq "remaining: scope, recorded and remaining counts" "remaining:2:4" "$(line SCOPE):$(line RECORDED):$(line REPLAYS)"
assert_eq "remaining: only the unrecorded replays are listed" \
"REPLAY packet=est-e1 model=beta
REPLAY packet=est-e2 model=alpha
REPLAY packet=est-e2 model=beta
REPLAY packet=est-e3 model=alpha" "$(lines_of REPLAY)"
assert_eq "remaining: alpha's estimate covers only e2 (e1 recorded, e3 unmeasured)" \
  "ESTIMATE model=alpha replays=2 estimated=1 tokens=1200000 input=0 output=200000 cache_creation=0 cache_read=1000000 dollars_min=2.20 dollars_max=2.20 price=alpha" \
  "$(eline "ESTIMATE model=alpha")"
assert_eq "remaining: beta's estimate covers e1 and e2" \
  "ESTIMATE model=beta replays=2 estimated=2 tokens=4500000 input=1000000 output=300000 cache_creation=200000 cache_read=3000000 dollars_min=3.05 dollars_max=3.20 price=family:claude-beta-1,claude-beta-2" \
  "$(eline "ESTIMATE model=beta")"
assert_has "remaining: the unmeasured packet still in the set is still named" "EXCLUDED packet=est-e3 " "$(lines_of EXCLUDED)"
APPROVAL3="$(line APPROVAL)"
APPR_LAST="$(tail -1 "$ESTORE/$EA/approvals.jsonl" 2>/dev/null)"
assert_has "remaining: its token is bound to the remaining set only" \
  "{\"token\":\"$APPROVAL3\",\"state\":\"pending\",\"experiment\":\"$EA\",\"scope\":\"remaining\"," "$APPR_LAST"
assert_has "remaining: the stored set is the four remaining replays" \
  '"replays":[{"packet":"est-e1","model":"beta"},{"packet":"est-e2","model":"alpha"},{"packet":"est-e2","model":"beta"},{"packet":"est-e3","model":"alpha"}]}' \
  "$APPR_LAST"
est "$EA"
assert_eq "remaining: without the flag every replay is counted" "all:0:6" "$(line SCOPE):$(line RECORDED):$(line REPLAYS)"

# Everything recorded: nothing to run, so no token is issued.
{
  for p in est-e2 est-e4; do printf '{"experiment":"%s","packet":"%s","model":"alpha"}\n' "$EB" "$p"; printf '{"experiment":"%s","packet":"%s","model":"gamma"}\n' "$EB" "$p"; done
} >> "$ESTORE/records.jsonl"
EB_BEFORE="$(cat "$ESTORE/$EB/approvals.jsonl")"
est "$EB" --remaining
assert_eq "nothing remaining: no replay, no token" "0:none" "$(line REPLAYS):$(line APPROVAL)"
assert_eq "nothing remaining: no pending token stored" "$EB_BEFORE" "$(cat "$ESTORE/$EB/approvals.jsonl")"

printf '\n== estimate: refusals ==\n'
est bbbbbbbbbbbb
assert_eq "no stored selection: exit 1" "1" "$RC"
assert_has "no stored selection: says to run select" "run \`compare.sh select\` first" "$ERR"
est ../etc
assert_eq "not an experiment id: exit 1" "1" "$RC"
cp "$ESTORE/records.jsonl" "$WORK/records.good"
printf '{"experiment": "%s", "packet": est-e2, "model": "beta"}\n' "$EA" >> "$ESTORE/records.jsonl"
est "$EA" --remaining
assert_eq "records with a bare word: refused, not guessed" "1:" "$RC:$OUT"
cp "$WORK/records.good" "$ESTORE/records.jsonl"
printf 'not json\n' >> "$ESTORE/records.jsonl"
est "$EA" --remaining
assert_eq "unreadable records: refused, not guessed" "1:" "$RC:$OUT"
assert_has "unreadable records: names the file" "records file is not readable JSONL" "$ERR"

printf '\n== prepare: a fixture source repository and store ==\n'
# prep-t1 has its original handoff on disk; prep-t2 has none, so it is rebuilt
# from the plan at its parent. The source's tracked project-overrides.yaml
# carries other keys, a comment and other model_routing entries, which the
# clone must keep. Its main checkout holds untracked .agents/ state (a run-state
# and the original handoff) whose bytes must not change.
PR="$WORK/prepsrc"
mkdir -p "$PR/scripts" "$PR/gspec/features/prep" "$PR/.agents"
PR_N=0
pr_commit() {  # pr_commit <message> -> prints the new commit's sha
  PR_N=$((PR_N + 1))
  local d; d="2026-04-01T00:$(printf '%02d' "$PR_N"):00Z"
  git -C "$PR" add -A >/dev/null
  GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git -C "$PR" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "$1" >/dev/null
  git -C "$PR" rev-parse HEAD
}
git -C "$PR" init -q
printf '.agents/loop/\n.agents/run-state.yaml\n' > "$PR/.gitignore"
printf 'echo a\n' > "$PR/scripts/a.sh"
printf 'project:\n  name: fixture\nmodel_routing:\n    architect: haiku   # kept\n    implementer: haiku\n# a comment after the map\nimplementer_turn_budget: 77\n' \
  > "$PR/.agents/project-overrides.yaml"
printf -- '---\nspec-version: v2\nfeature: prep\n---\n\n# Prep\n\n## Capabilities\n\n- [ ] **The capability**\n' \
  > "$PR/gspec/features/prep/prd.md"
{ printf -- '---\nspec-version: v2\nfeature: prep\n---\n\n# Plan: prep\n\n## Plan\n\n'
  printf -- '- [ ] **T1** **P0** Task T1.\n  - deps: —\n  - covers: The capability\n  - arch: —\n'
  printf -- '- [ ] **T2** **P0** Task T2.\n  - deps: —\n  - covers: The capability\n  - arch: —\n'; } > "$PR/gspec/features/prep/tasks.md"
P0="$(pr_commit base)"
printf 'echo t1\n' >> "$PR/scripts/a.sh"
P1="$(pr_commit "$(printf 't1\n\n[orch packet:prep-t1]')")"
printf 'echo t2\n' >> "$PR/scripts/a.sh"
P2="$(pr_commit "$(printf 't2\n\n[orch packet:prep-t2]')")"
git -C "$PR" branch -q other-branch "$P1"
mkdir -p "$PR/.agents/loop/20260401T000000-aa/prep-t1"
printf '# prep-t1: the original\n\nrun-state: /elsewhere/run-state.yaml\n\nno trailing newline' \
  > "$PR/.agents/loop/20260401T000000-aa/prep-t1/handoff.md"
printf "schema: 3\nstatus: 'paused'\n" > "$PR/.agents/run-state.yaml"

PEXP=ccccccccccc1
PSTORE="$WORK/prepstore"
PSCRATCH="$WORK/prepscratch"
mkdir -p "$PSTORE/$PEXP"
cat > "$PSTORE/$PEXP/selection.json" <<EOF
{
  "experiment": "$PEXP",
  "settings": {"role": "implementer", "models": ["fable", "opus", "sonnet"], "reviewer_model": "opus", "source_repo": "$PR", "per_class": 2, "code_files": ["scripts/"], "prose_files": ["agents/"]},
  "selected": [
    {"packet": "prep-t2", "class": "code", "tier": "unrecorded", "fix_rounds": "unmeasured", "title": "t2", "handoff": "rebuilt", "start": "$P1", "commits": ["$P2"]},
    {"packet": "prep-t1", "class": "code", "tier": "integration", "fix_rounds": 0, "title": "t1", "handoff": "original", "start": "$P0", "commits": ["$P1"]}
  ],
  "shortfalls": [],
  "excluded": [],
  "dropped": []
}
EOF
prep() {  # prep <args...>: OUT/ERR/RC, with the fixture store and scratch root
  OUT="$(ORCH_COMPARE_STORE="$PSTORE" ORCH_COMPARE_SCRATCH="$PSCRATCH" "$COMPARE" prepare "$@" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
# agents_tree <root>: every path under <root>/.agents with each file's checksum.
agents_tree() {
  (cd "$1" && find .agents -print | LC_ALL=C sort | while IFS= read -r p; do
     if [ -f "$p" ]; then printf '%s %s\n' "$p" "$(cksum < "$p")"; else printf '%s\n' "$p"; fi
   done)
}
BEFORE_STATUS="$(git -C "$PR" status --porcelain=v1 --untracked-files=all --ignored)"
BEFORE_AGENTS="$(agents_tree "$PR")"
BEFORE_REFS="$(git -C "$PR" for-each-ref)"

# Every model, both packets: six replays.
PREP_CLONES=""
for pk in prep-t1 prep-t2; do
  for m in fable opus sonnet; do
    prep "$PEXP" "$pk" "$m"
    assert_eq "prepare $pk $m: exit 0" "0" "$RC"
    C="$(line CLONE)"; B="$(line BRANCH)"; H="$(line HANDOFF)"; R="$(line REPLAY)"
    PREP_CLONES="$PREP_CLONES $C"
    eval "PH_${pk#prep-}_$m=\$H"
    assert_eq "prepare $pk $m: the clone is under the scratch root" "$PSCRATCH" "$(dirname "$C")"
    assert_eq "prepare $pk $m: the clone's HEAD is the packet's start" \
      "$(if [ "$pk" = prep-t1 ]; then echo "$P0"; else echo "$P1"; fi)" "$(git -C "$C" rev-parse HEAD 2>/dev/null)"
    assert_eq "prepare $pk $m: the clone is on its opaque branch, its only branch" \
      "refs/heads/$B:refs/heads/$B" "$(git -C "$C" symbolic-ref HEAD 2>/dev/null):$(git -C "$C" for-each-ref --format='%(refname)' refs/heads/ | paste -sd' ' -)"
    assert_eq "prepare $pk $m: the clone has no remote back to the source" "" "$(git -C "$C" remote)"
    assert_eq "prepare $pk $m: routing.sh --root <clone> resolve implementer prints the model" \
      "$m" "$("$ROUTING" --root "$C" resolve implementer)"
    assert_eq "prepare $pk $m: routing.sh --root <clone> resolve reviewer prints the reviewer model" \
      "opus" "$("$ROUTING" --root "$C" resolve reviewer)"
    assert_eq "prepare $pk $m: the clone's routing config validates clean" "" "$("$ROUTING" --root "$C" validate)"
    assert_eq "prepare $pk $m: the replay record in the store is stdout" "$OUT" "$(cat "$PSTORE/$PEXP/replays/$R.env" 2>/dev/null)"
    assert_eq "prepare $pk $m: the handoff is installed in the clone's run directory" \
      "$C/.agents/loop/$(line RUN_ID)/$pk/handoff.md" "$H"
    assert_eq "prepare $pk $m: begin-run minted the clone's run_id" \
      "$(line RUN_ID)" "$("$HERE/runstate.sh" get "$C/.agents/run-state.yaml" run_id)"
  done
done
assert_eq "prepare: the source's git status is byte-identical after six prepares" \
  "$BEFORE_STATUS" "$(git -C "$PR" status --porcelain=v1 --untracked-files=all --ignored)"
assert_eq "prepare: the source's .agents/ tree hash is byte-identical" "$BEFORE_AGENTS" "$(agents_tree "$PR")"
assert_eq "prepare: the source's for-each-ref output is byte-identical" "$BEFORE_REFS" "$(git -C "$PR" for-each-ref)"

# The other keys, the comment and the other entry are kept; the two set ones
# are not duplicated.
C="${PREP_CLONES##* }"
assert_eq "prepare: every other key and line of project-overrides.yaml is kept" \
"project:
  name: fixture
model_routing:
    implementer: sonnet
    reviewer: opus
    architect: haiku   # kept
# a comment after the map
implementer_turn_budget: 77" "$(cat "$C/.agents/project-overrides.yaml")"
assert_eq "prepare: an entry other than the role's and the reviewer's still resolves" "haiku" "$("$ROUTING" --root "$C" resolve architect)"

# Byte-identical handoffs across the three models, from the per-packet cache.
for pk in t1 t2; do
  eval "HF=\$PH_${pk}_fable; HO=\$PH_${pk}_opus; HS=\$PH_${pk}_sonnet"
  if cmp -s "$HF" "$HO" && cmp -s "$HF" "$HS"; then ok "prepare prep-$pk: three models' handoffs are byte-identical"
  else bad "prepare prep-$pk: three models' handoffs are byte-identical"; fi
  if cmp -s "$HF" "$PSTORE/$PEXP/handoffs/prep-$pk.md"; then ok "prepare prep-$pk: the handoff is the experiment's cached copy"
  else bad "prepare prep-$pk: the handoff is the experiment's cached copy"; fi
done
if cmp -s "$PH_t1_fable" "$PR/.agents/loop/20260401T000000-aa/prep-t1/handoff.md"; then
  ok "prepare: an original handoff with no splice block is copied byte-for-byte"
else bad "prepare: an original handoff with no splice block is copied byte-for-byte"; fi
# The rebuilt handoff went through runstate.sh handoff: the adapter's lines,
# the stored tier as it stands (never a guessed one), and the verification
# contract appended verbatim at the end.
RB="$(cat "$PH_t2_fable")"
assert_has "prepare: a rebuilt handoff carries the adapter's packet" "PACKET=prep-t2" "$RB"
assert_has "prepare: a rebuilt handoff states the stored tier, unrecorded included" "tier: unrecorded" "$RB"
assert_has "prepare: a rebuilt handoff names the varied role as its agent" "agent: implementer" "$RB"
assert_has "prepare: a rebuilt handoff carries the required-verification block" \
  "$(cat "$REPO/templates/handoff-required.md")" "$RB"
REQ_HEAD="$(sed -n '1p' "$REPO/templates/handoff-required.md")"
assert_eq "prepare: the verification block ends the rebuilt handoff" \
  "$(cat "$REPO/templates/handoff-required.md")" "$(awk -v h="$REQ_HEAD" '$0 == h { on = 1 } on' "$PH_t2_fable")"
# A second prepare reuses the cache rather than rebuilding.
prep "$PEXP" prep-t2 opus
assert_eq "prepare again: the cache is reused, not rewritten" "0:reused" "$RC:$(line HANDOFF_CACHED)"
PREP_CLONES="$PREP_CLONES $(line CLONE)"

# No directory or branch name contains any model identifier (or the reviewer's).
leak=""
for C in $PREP_CLONES; do
  for n in "$(basename "$C")" $(git -C "$C" for-each-ref --format='%(refname)'); do
    for m in fable opus sonnet; do
      case "$(printf '%s' "$n" | tr 'A-Z' 'a-z')" in *"$m"*) leak="$leak $n" ;; esac
    done
  done
done
assert_eq "prepare: no clone directory or branch name contains a model identifier" "" "$leak"
assert_eq "prepare: the clones' directory names are distinct" "7" \
  "$(for C in $PREP_CLONES; do basename "$C"; done | sort -u | wc -l | tr -d ' ')"

printf '\n== prepare: refusals ==\n'
N_CLONES="$(ls "$PSCRATCH" | wc -l | tr -d ' ')"
prep "$PEXP" prep-t1 haiku
assert_eq "prepare, a model outside the settings: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "prepare, a model outside the settings: named" "haiku is not one of experiment $PEXP's models" "$ERR"
prep "$PEXP" prep-t9 opus
assert_eq "prepare, a packet outside the selection: exit 1" "1" "$RC"
assert_has "prepare, a packet outside the selection: named" "packet prep-t9 is not in experiment $PEXP's selection" "$ERR"
prep dddddddddddd prep-t1 opus
assert_eq "prepare, no stored selection: exit 1" "1" "$RC"
assert_has "prepare, no stored selection: says to run select" "run \`compare.sh select\` first" "$ERR"
prep ../etc prep-t1 opus
assert_eq "prepare, not an experiment id: exit 1" "1" "$RC"
OUT="$(ORCH_COMPARE_STORE="$PSTORE" ORCH_COMPARE_SCRATCH="$PR/scratch" "$COMPARE" prepare "$PEXP" prep-t1 opus 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
assert_eq "prepare, a scratch root inside the source: exit 1" "1" "$RC"
assert_has "prepare, a scratch root inside the source: named" "lies inside the source repository's working tree" "$ERR"
rmdir "$PR/scratch" 2>/dev/null
# A routing config the clone cannot set is refused, and the half-built clone removed.
printf 'model_routing: [not, a, map]\n' > "$PR/.agents/project-overrides.yaml"
P3="$(pr_commit 'break the routing map')"
mkdir -p "$PSTORE/ccccccccccc2"
sed "s/$PEXP/ccccccccccc2/; s/\"start\": \"$P0\"/\"start\": \"$P3\"/" \
  "$PSTORE/$PEXP/selection.json" > "$PSTORE/ccccccccccc2/selection.json"
prep ccccccccccc2 prep-t1 opus
assert_eq "prepare, an unreadable model_routing: exit 1" "1" "$RC"
assert_has "prepare, an unreadable model_routing: named" "model_routing cannot be read" "$ERR"
assert_eq "prepare: no refused prepare leaves a clone behind" "$N_CLONES" "$(ls "$PSCRATCH" | wc -l | tr -d ' ')"

printf '\n== prepare: a spliced original, and the store inside the source ==\n'
# The original handoff is produced the way the loop produces one: `runstate.sh
# handoff` writes the first-dispatch file (kept aside as the expected bytes),
# then the REAL `refresh-handoff` (a dirty in-scope file) and `amend-handoff`
# splice their blocks into it. A later run's handoff for the same packet must
# not be the one used. The store is the source's own .agents/metrics/comparisons,
# as the default store is when the source is the harness's own checkout.
SP="$WORK/splicesrc"
mkdir -p "$SP/scripts" "$SP/.agents"
git -C "$SP" init -q
printf '.agents/loop/\n.agents/run-state.yaml\n.agents/metrics/\n' > "$SP/.gitignore"
printf 'echo a\n' > "$SP/scripts/a.sh"
printf 'model_routing:\n  architect: haiku\n' > "$SP/.agents/project-overrides.yaml"
sp_commit() {
  git -C "$SP" add -A >/dev/null
  GIT_AUTHOR_DATE=2026-04-02T00:00:00Z GIT_COMMITTER_DATE=2026-04-02T00:00:00Z git -C "$SP" -c user.name=fixture \
    -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "$1" >/dev/null
  git -C "$SP" rev-parse HEAD
}
S0="$(sp_commit base)"
printf 'echo s1\n' >> "$SP/scripts/a.sh"
S1="$(sp_commit "$(printf 's1\n\n[orch packet:splice-t1]')")"
SRS="$SP/.agents/run-state.yaml"
printf "schema: 3\nstatus: 'running'\nbranch: 'orch/splice-t1'\nlast_green_commit: '%s'\n" "$S1" \
  | (cd "$SP" && CLAUDE_PROJECT_DIR="$SP" "$HERE/runstate.sh" write "$SRS") >/dev/null 2>&1
SRUN="$(cd "$SP" && CLAUDE_PROJECT_DIR="$SP" "$HERE/runstate.sh" begin-run "$SRS" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
SH="$(printf 'PACKET=splice-t1\nFILES=scripts/a.sh\n\nDo the task.\nREQUIRED: a driver-appended line\n' \
  | (cd "$SP" && CLAUDE_PROJECT_DIR="$SP" "$HERE/runstate.sh" handoff "$SRS" splice-t1 --tier integration --agent implementer) 2>/dev/null \
  | sed -n 's/^HANDOFF=//p')"
cp "$SH" "$WORK/splice-plain.md" 2>/dev/null
printf 'echo dirty\n' >> "$SP/scripts/a.sh"
SREF="$(cd "$SP" && CLAUDE_PROJECT_DIR="$SP" "$HERE/runstate.sh" refresh-handoff "$SRS" splice-t1 2>&1)"
SAMD="$(printf 'Change one thing.\n' | (cd "$SP" && CLAUDE_PROJECT_DIR="$SP" "$HERE/runstate.sh" amend-handoff "$SRS" splice-t1) 2>&1)"
# The fixture's own preconditions: both splices happened, and the plain file
# has the budget block the first dispatch carries.
assert_has "splice fixture: refresh-handoff inserted its block" "PARTIAL_WORK=inserted" "$SREF"
assert_has "splice fixture: amend-handoff inserted its block" "AMENDMENT=inserted" "$SAMD"
SPLICED="$(cat "$SH" 2>/dev/null)"
assert_has "splice fixture: the original carries the partial-work block" "<!-- orch:partial-work -->" "$SPLICED"
assert_has "splice fixture: the original carries the decider-amendment block" "<!-- orch:decider-amendment -->" "$SPLICED"
assert_has "splice fixture: the first-dispatch handoff carries the budget block" "<!-- orch:budget -->" "$(cat "$WORK/splice-plain.md" 2>/dev/null)"
cp "$SH" "$WORK/splice-spliced.md" 2>/dev/null
mkdir -p "$SP/.agents/loop/99991231T235959-zz/splice-t1"
printf 'a later run'"'"'s handoff\n' > "$SP/.agents/loop/99991231T235959-zz/splice-t1/handoff.md"

SEXP=ccccccccccc3
SSTORE="$SP/.agents/metrics/comparisons"
SSCRATCH="$WORK/splicescratch"
mkdir -p "$SSTORE/$SEXP"
cat > "$SSTORE/$SEXP/selection.json" <<EOF
{
  "experiment": "$SEXP",
  "settings": {"role": "implementer", "models": ["fable", "opus", "sonnet"], "reviewer_model": "opus", "source_repo": "$SP", "per_class": 2, "code_files": ["scripts/"], "prose_files": ["agents/"]},
  "selected": [
    {"packet": "splice-t1", "class": "code", "tier": "integration", "fix_rounds": 1, "title": "s1", "handoff": "original", "start": "$S0", "commits": ["$S1"]}
  ],
  "shortfalls": [],
  "excluded": [],
  "dropped": []
}
EOF
# Everything under .agents/ except the experiment's own store.
agents_tree_outside_store() { agents_tree "$1" | awk -v s=".agents/metrics/comparisons/$SEXP" 'index($0, s) != 1'; }
S_BEFORE_STATUS="$(git -C "$SP" status --porcelain=v1 --untracked-files=all)"
S_BEFORE_IGN="$(git -C "$SP" status --porcelain=v1 --untracked-files=all --ignored | awk -v s=".agents/metrics/comparisons/$SEXP/" 'index($0, "!! " s) != 1')"
S_BEFORE_AGENTS="$(agents_tree_outside_store "$SP")"
S_BEFORE_REFS="$(git -C "$SP" for-each-ref)"
for m in fable opus sonnet; do
  OUT="$(ORCH_COMPARE_STORE="$SSTORE" ORCH_COMPARE_SCRATCH="$SSCRATCH" "$COMPARE" prepare "$SEXP" splice-t1 "$m" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
  assert_eq "prepare splice-t1 $m: exit 0" "0" "$RC"
  H="$(line HANDOFF)"
  if cmp -s "$WORK/splice-plain.md" "$H"; then
    ok "prepare splice-t1 $m: the installed handoff is the first-dispatch handoff, splice blocks removed"
  else bad "prepare splice-t1 $m: the installed handoff is the first-dispatch handoff, splice blocks removed" "$(diff "$WORK/splice-plain.md" "$H" 2>&1 | head -5)"; fi
done
if cmp -s "$WORK/splice-plain.md" "$SSTORE/$SEXP/handoffs/splice-t1.md"; then
  ok "prepare splice-t1: the cached handoff is the first-dispatch handoff"
else bad "prepare splice-t1: the cached handoff is the first-dispatch handoff"; fi
if cmp -s "$WORK/splice-spliced.md" "$SH"; then ok "prepare splice-t1: the source handoff itself is not modified"
else bad "prepare splice-t1: the source handoff itself is not modified"; fi
assert_eq "prepare, store inside the source: git status is byte-identical" \
  "$S_BEFORE_STATUS" "$(git -C "$SP" status --porcelain=v1 --untracked-files=all)"
assert_eq "prepare, store inside the source: git status --ignored is byte-identical outside the experiment's store" \
  "$S_BEFORE_IGN" "$(git -C "$SP" status --porcelain=v1 --untracked-files=all --ignored | awk -v s=".agents/metrics/comparisons/$SEXP/" 'index($0, "!! " s) != 1')"
assert_eq "prepare, store inside the source: the .agents/ tree hash is byte-identical outside the experiment's store" \
  "$S_BEFORE_AGENTS" "$(agents_tree_outside_store "$SP")"
assert_eq "prepare, store inside the source: for-each-ref output is byte-identical" "$S_BEFORE_REFS" "$(git -C "$SP" for-each-ref)"
assert_ne "prepare, store inside the source: the experiment's store did receive the cache" "" \
  "$(ls "$SSTORE/$SEXP/handoffs" 2>/dev/null)"
# A marker the loop could not have placed is refused, not guessed around.
mkdir -p "$SSTORE/ccccccccccc4"
sed "s/$SEXP/ccccccccccc4/" "$SSTORE/$SEXP/selection.json" > "$SSTORE/ccccccccccc4/selection.json"
cp "$SH" "$WORK/splice-keep.md"
printf '<!-- orch:partial-work -->\nunterminated\n' >> "$SH"
OUT="$(ORCH_COMPARE_STORE="$SSTORE" ORCH_COMPARE_SCRATCH="$SSCRATCH" "$COMPARE" prepare ccccccccccc4 splice-t1 opus 2>"$WORK/err")"; RC=$?
ERR="$(cat "$WORK/err")"
assert_eq "prepare, an unterminated splice block: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "prepare, an unterminated splice block: named" "first-dispatch bytes are unknown" "$ERR"
cp "$WORK/splice-keep.md" "$SH"
# A closing marker with no opening one is no span either command wrote.
printf '<!-- /orch:decider-amendment -->\n' >> "$SH"
OUT="$(ORCH_COMPARE_STORE="$SSTORE" ORCH_COMPARE_SCRATCH="$SSCRATCH" "$COMPARE" prepare ccccccccccc4 splice-t1 opus 2>"$WORK/err")"; RC=$?
ERR="$(cat "$WORK/err")"
assert_eq "prepare, a stray closing splice marker: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "prepare, a stray closing splice marker: named" "first-dispatch bytes are unknown" "$ERR"
cp "$WORK/splice-keep.md" "$SH"

printf '\n== review-view: a fixture source, two replays doing identical work ==\n'
# The subject models are fable and sonnet; the reviewer is haiku, a third model,
# so every subject identifier the view holds is one it must not. The start
# commit already names sonnet twice (a doc line and its own model_routing
# entry), which the search must not count against the view. Each work clone
# gets the same change, done the way an implementer leaves it: one commit on
# the opaque branch whose message and trailer name the model, further unstaged
# and untracked edits, a real edit to project-overrides.yaml beside the
# replay's routing, metrics and routing-log files naming the model, and a
# result file naming it in every form (display name with version, resolved id,
# alias).
RV="$WORK/rvsrc"
mkdir -p "$RV/scripts" "$RV/docs" "$RV/.agents"
git -C "$RV" init -q
# .agents/metrics/ and the previous run-state are deliberately NOT ignored, as in
# a repository that never listed them: `git add -A` would pick them up, so only
# the review view's own exclusion keeps them out of the reviewed change.
printf '.agents/loop/\n.agents/run-state.yaml\n' > "$RV/.gitignore"
printf 'echo a\n' > "$RV/scripts/a.sh"
printf 'Tuned on sonnet once.\n' > "$RV/docs/notes.md"
printf 'project:\n  name: rv\nmodel_routing:\n  implementer: sonnet\n  architect: haiku\nimplementer_turn_budget: 77\n' \
  > "$RV/.agents/project-overrides.yaml"
rv_commit() {
  git -C "$RV" add -A >/dev/null
  GIT_AUTHOR_DATE=2026-05-01T00:00:00Z GIT_COMMITTER_DATE=2026-05-01T00:00:00Z git -C "$RV" -c user.name=fixture \
    -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "$1" >/dev/null
  git -C "$RV" rev-parse HEAD
}
R0="$(rv_commit base)"
printf 'echo landed\n' >> "$RV/scripts/a.sh"
R1="$(rv_commit "$(printf 'rv\n\n[orch packet:rv-t1]')")"
mkdir -p "$RV/.agents/loop/20260501T000000-aa/rv-t1"
printf '# rv-t1: the original\n\ntier: integration\nagent: implementer\nrun-state: /elsewhere/run-state.yaml\nresult: /elsewhere/implementer.md\nreview: /elsewhere/review.md\n\nPACKET=rv-t1\nPrefer Sonnet 4.6 wording; FABLE is fine.\nresult: not a header line\n' \
  > "$RV/.agents/loop/20260501T000000-aa/rv-t1/handoff.md"
RVEXP=ccccccccccc5
RVSTORE="$WORK/rvstore"
RVSCRATCH="$WORK/rvscratch"
mkdir -p "$RVSTORE/$RVEXP"
cat > "$RVSTORE/$RVEXP/selection.json" <<EOF
{
  "experiment": "$RVEXP",
  "settings": {"role": "implementer", "models": ["fable", "sonnet"], "reviewer_model": "haiku", "source_repo": "$RV", "per_class": 1, "code_files": ["scripts/"], "prose_files": ["docs/"]},
  "selected": [
    {"packet": "rv-t1", "class": "code", "tier": "integration", "fix_rounds": 0, "title": "rv", "handoff": "original", "start": "$R0", "commits": ["$R1"]}
  ],
  "shortfalls": [],
  "excluded": [],
  "dropped": []
}
EOF
rvv() {  # rvv <args...>: OUT/ERR/RC for `compare.sh review-view`
  OUT="$(ORCH_COMPARE_STORE="$RVSTORE" ORCH_COMPARE_SCRATCH="$RVSCRATCH" "$COMPARE" review-view "$@" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
# rv_work <clone> <run_id> <model>: the implementer's change, identical for every model
# except where it names the model itself.
rv_work() {
  local c="$1" run="$2" m="$3"
  printf 'echo t1\n' >> "$c/scripts/a.sh"
  # A file only the commit touches, so a change built from the uncommitted
  # edits alone would miss it.
  printf 'echo committed\n' > "$c/scripts/committed.sh"
  git -C "$c" add scripts/a.sh scripts/committed.sh
  GIT_AUTHOR_DATE=2026-05-02T00:00:00Z GIT_COMMITTER_DATE=2026-05-02T00:00:00Z git -C "$c" -c user.name="$m-bot" \
    -c user.email="$m@example.invalid" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q -m "$(printf 'work by claude-%s-5\n\n[orch packet:rv-t1]\nCo-Authored-By: Claude %s <noreply@example.invalid>' "$m" "$m")" >/dev/null
  printf 'echo t1 again\n' >> "$c/scripts/a.sh"
  printf 'echo new\n' > "$c/scripts/new.sh"
  sed 's/^implementer_turn_budget: 77$/implementer_turn_budget: 88/' "$c/.agents/project-overrides.yaml" > "$c/ov.tmp" \
    && mv "$c/ov.tmp" "$c/.agents/project-overrides.yaml"
  mkdir -p "$c/.agents/metrics/x"
  printf '{"model":"claude-%s-5"}\n' "$m" > "$c/.agents/metrics/x/events.jsonl"
  printf '{"model":"%s"}\n' "$m" > "$c/.agents/loop/$run/routing.jsonl"
  printf "schema: 3\nnote: 'ran on %s'\n" "$m" > "$c/.agents/run-state-prev.yaml"
  printf "continue model=%s\n\nDone by Claude %s 5 (claude-%s-5-1), model=%s.\nThe diff is in scripts/.\n" "$m" "$m" "$m" "$m" \
    > "$c/.agents/loop/$run/rv-t1/implementer.md"
}
for m in fable sonnet; do
  prep_out="$(ORCH_COMPARE_STORE="$RVSTORE" ORCH_COMPARE_SCRATCH="$RVSCRATCH" "$COMPARE" prepare "$RVEXP" rv-t1 "$m" 2>/dev/null)"
  OUT="$prep_out"
  eval "RVC_$m=\$(line CLONE); RVR_$m=\$(line REPLAY); RVRUN_$m=\$(line RUN_ID)"
done
assert_ne "review-view fixture: both replays prepared" "" "$RVC_fable$RVC_sonnet"
rv_work "$RVC_fable" "$RVRUN_fable" fable
rv_work "$RVC_sonnet" "$RVRUN_sonnet" sonnet
RVST="$(git -C "$RVC_fable" status --porcelain=v1 --untracked-files=all)"
assert_has "review-view fixture: the work clone's metrics file is untracked, not ignored" "?? .agents/metrics/x/events.jsonl" "$RVST"
assert_has "review-view fixture: the work clone's previous run-state is untracked, not ignored" "?? .agents/run-state-prev.yaml" "$RVST"
# The work clone is only read: its status, refs, index and object store.
clone_state() {
  printf '%s\n' "$(git -C "$1" status --porcelain=v1 --untracked-files=all --ignored)" \
    "$(git -C "$1" for-each-ref)" "$(cksum < "$1/.git/index")" "$(cd "$1/.git/objects" && find . | LC_ALL=C sort | cksum)"
}
RVC_BEFORE="$(clone_state "$RVC_fable")"
rvv "$RVR_fable"
assert_eq "review-view fable: exit 0" "0" "$RC"
V="$(line VIEW)"; VB="$(line BASE)"; VH="$(line HEAD)"; VBR="$(line BRANCH)"
RVOUT_fable="$OUT"
assert_eq "review-view: the work clone's status, refs, index and objects are byte-identical" "$RVC_BEFORE" "$(clone_state "$RVC_fable")"
assert_eq "review-view: the view is under the scratch root, not the work clone" "$RVSCRATCH:no" \
  "$(dirname "$V"):$(if [ "$V" = "$RVC_fable" ]; then echo yes; else echo no; fi)"
assert_eq "review-view: the view is on its one opaque branch, at the change under review" \
  "refs/heads/$VBR:refs/heads/$VBR:$VH" \
  "$(git -C "$V" symbolic-ref HEAD 2>/dev/null):$(git -C "$V" for-each-ref --format='%(refname)' refs/heads/ | paste -sd' ' -):$(git -C "$V" rev-parse HEAD 2>/dev/null)"
assert_eq "review-view: the view has no remote" "" "$(git -C "$V" remote)"
assert_eq "review-view: the view's commits are the configuration then the change, on the start" \
  "$VH $VB|$VB $R0" "$(git -C "$V" rev-list --parents -n1 "$VH")|$(git -C "$V" rev-list --parents -n1 "$VB")"
assert_eq "review-view: the view's working tree is clean at the change" "" \
  "$(git -C "$V" status --porcelain=v1 --untracked-files=no)"
assert_eq "review-view: the view's run-state reviews from BASE" "$VB" \
  "$("$HERE/runstate.sh" get "$(line RUN_STATE)" last_green_commit)"
assert_eq "review-view: the view is recorded for the replay" "VIEW=$V" \
  "$(cat "$RVSTORE/$RVEXP/replays/$RVR_fable.views" 2>/dev/null)"

# routing.sh in the view resolves the reviewer and nothing else.
assert_eq "review-view: routing.sh --root <view> resolve reviewer prints the reviewer model" \
  "haiku" "$("$ROUTING" --root "$V" resolve reviewer)"
assert_eq "review-view: the view's routing names no other agent (implementer, architect unresolved)" \
  ":" "$("$ROUTING" --root "$V" resolve implementer):$("$ROUTING" --root "$V" resolve architect)"

# The reviewed change: the work, committed and not, with no routing, metrics,
# run-state or run-directory path in it.
assert_eq "review-view: the reviewed change's paths are the packet's own" \
  ".agents/project-overrides.yaml scripts/a.sh scripts/committed.sh scripts/new.sh" \
  "$(git -C "$V" diff --name-only "$VB" "$VH" | paste -sd' ' -)"
VDIFF="$(git -C "$V" diff "$VB" "$VH")"
# Changed lines only: the reduced routing map may sit in a hunk's context.
VCHG="$(printf '%s\n' "$VDIFF" | awk '/^[+-]/ && !/^(\+\+\+|---) /')"
assert_has "review-view: the committed edit is in the change" "+echo committed" "$VDIFF"
assert_has "review-view: the unstaged edit is in the change" "+echo t1 again" "$VDIFF"
assert_has "review-view: the untracked file is in the change" "+echo new" "$VDIFF"
assert_has "review-view: the packet's own edit to project-overrides.yaml is kept" "+implementer_turn_budget: 88" "$VDIFF"
case "$VCHG" in
  *model_routing*|*"reviewer:"*|*"implementer:"*|*fable*) bad "review-view: the routing change is absent from the view's diff" "$VCHG" ;;
  *) ok "review-view: the routing change is absent from the view's diff" ;;
esac
case "$(git -C "$V" diff "$R0" "$VH" -- .agents/project-overrides.yaml)" in
  *fable*) bad "review-view: the replay's model is in no routing change since the start" ;;
  *) ok "review-view: the replay's model is in no routing change since the start" ;;
esac

# The search: every identifier of the settings' models (alias, which is also
# the settings label, and every resolved id the price table lists for it) in
# the view's files (every file, .git included except packed objects), git log,
# refs and paths, beyond what the start commit already held.
RV_IDS="fable sonnet $(grep -o '"claude-[A-Za-z0-9._-]*"' "$HERE/spend-prices.json" | tr -d '"' | grep -iE 'fable|sonnet' | LC_ALL=C sort -u | paste -sd' ' -)"
assert_has "review-view fixture: the resolved ids come from the price table" "claude-sonnet-5" "$RV_IDS"
view_leaks() {  # view_leaks <view> <start>: one line per identifier the view holds beyond <start>
  local v="$1" s="$2" p id nv ns
  (cd "$v" && find . -type f ! -path './.git/objects/*' | sed 's|^\./||' | LC_ALL=C sort) > "$WORK/vfiles"
  while IFS= read -r p; do
    for id in $RV_IDS; do
      nv="$(grep -ic -- "$id" "$v/$p" 2>/dev/null)"; nv="${nv:-0}"
      [ "$nv" -gt 0 ] || continue
      ns="$(git -C "$v" show "$s:$p" 2>/dev/null | grep -ic -- "$id")"; ns="${ns:-0}"
      [ "$nv" -le "$ns" ] || printf 'file %s: %s\n' "$p" "$id"
    done
  done < "$WORK/vfiles"
  for id in $RV_IDS; do
    case "$(git -C "$v" log --format='%an%n%ae%n%cn%n%ce%n%B' "$s..HEAD" | tr 'A-Z' 'a-z')" in *"$id"*) printf 'log: %s\n' "$id" ;; esac
    case "$(git -C "$v" for-each-ref --format='%(refname) %(symref)' | tr 'A-Z' 'a-z')" in *"$id"*) printf 'ref: %s\n' "$id" ;; esac
    case "$(cd "$v" && find . ! -path './.git/objects/*' | tr 'A-Z' 'a-z')" in *"$id"*) printf 'path: %s\n' "$id" ;; esac
    case "$(printf '%s' "$v" | tr 'A-Z' 'a-z')" in *"$id"*) printf 'view path: %s\n' "$id" ;; esac
  done
}
assert_eq "review-view: no model identifier in the view's files, git log, refs or paths beyond the start's" \
  "" "$(view_leaks "$V" "$R0")"
# The search itself finds what the start holds (so an empty result is not a blind search).
assert_eq "review-view fixture: the search reads the start's own mention as held, not missed" "1" \
  "$(grep -ic sonnet "$V/docs/notes.md")"
assert_eq "review-view: the view's commits carry the fixed author and messages, no trailer" \
  "compare <compare@example.invalid> 2000-01-01T00:00:00Z|Changes under review||compare <compare@example.invalid> 2000-01-01T00:00:00Z|Review configuration|" \
  "$(TZ=UTC git -C "$V" log --format='%an <%ae> %cd|%B' --date=format-local:%Y-%m-%dT%H:%M:%SZ "$R0..$VH" | paste -sd'|' -)"
case "$(git -C "$V" log --format=%B "$R0..$VH")" in
  *Co-Authored-By*|*"[orch "*) bad "review-view: no trailer or Co-Authored-By in the view's commits" ;;
  *) ok "review-view: no trailer or Co-Authored-By in the view's commits" ;;
esac

# The result file naming its model is redacted, every form of it; the handoff too.
assert_eq "review-view: a result file naming its model is redacted in every form" \
"continue model=[model]

Done by Claude [model] ([model]), model=[model].
The diff is in scripts/." "$(cat "$(line RESULT)" 2>/dev/null)"
assert_eq "review-view: the result copy sits in the view's run directory" \
  "$V/.agents/loop/$(line RUN_ID)/rv-t1/implementer.md" "$(line RESULT)"
VHO="$(cat "$(line HANDOFF)" 2>/dev/null)"
assert_has "review-view: the handoff's model mentions are redacted" "Prefer [model] wording; [model] is fine." "$VHO"
assert_has "review-view: the handoff's header result path points into the view" "result: $(line RESULT)" "$VHO"
assert_has "review-view: the handoff's header review path points into the view" "review: $(line REVIEW)" "$VHO"
assert_has "review-view: the handoff's header run-state path points into the view" "run-state: $(line RUN_STATE)" "$VHO"
assert_has "review-view: a body line shaped like a header is left alone" "result: not a header line" "$VHO"

# Blindness across models: the sonnet replay's view of the same work is the
# fable one's, byte for byte, wherever the reviewer reads.
rvv "$RVR_sonnet"
assert_eq "review-view sonnet: exit 0" "0" "$RC"
V2="$(line VIEW)"
assert_eq "review-view: two models' views of identical work have the same commits" "$VB $VH" "$(line BASE) $(line HEAD)"
if cmp -s "$(line RESULT)" "$V/.agents/loop/$(printf '%s\n' "$RVOUT_fable" | sed -n 's/^RUN_ID=//p')/rv-t1/implementer.md"; then
  ok "review-view: two models' redacted result files are byte-identical"
else bad "review-view: two models' redacted result files are byte-identical"; fi
assert_eq "review-view sonnet: no model identifier in the view beyond the start's" "" "$(view_leaks "$V2" "$R0")"
assert_ne "review-view: each view is its own clone" "$V" "$V2"

printf '\n== review-view: refusals ==\n'
N_VIEWS="$(ls "$RVSCRATCH" | wc -l | tr -d ' ')"
rvv abcdefabcdef
assert_eq "review-view, an unknown replay: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "review-view, an unknown replay: says to run prepare" "run \`compare.sh prepare\` first" "$ERR"
rvv ../etc
assert_eq "review-view, not a replay id: exit 1" "1" "$RC"
OUT="$(ORCH_COMPARE_STORE="$RVSTORE" ORCH_COMPARE_SCRATCH="$WORK/Fable-scratch" "$COMPARE" review-view "$RVR_fable" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
assert_eq "review-view, a scratch root naming a model: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "review-view, a scratch root naming a model: named" "scratch root's path names a model" "$ERR"
assert_eq "review-view, a scratch root naming a model: no view left behind" "" "$(ls "$WORK/Fable-scratch" 2>/dev/null)"
# A refusal after the view is cloned and committed: the replay's handoff is
# moved aside, so the build fails at its copy step with the view already on disk.
RVHO="$(sed -n 's/^HANDOFF=//p' "$RVSTORE/$RVEXP/replays/$RVR_fable.env" | head -1)"
RVVIEWS_BEFORE="$(cat "$RVSTORE/$RVEXP/replays/$RVR_fable.views" 2>/dev/null)"
mv "$RVHO" "$RVHO.aside"
rvv "$RVR_fable"
mv "$RVHO.aside" "$RVHO"
assert_eq "review-view, the replay's handoff missing: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "review-view, the replay's handoff missing: named" "handoff is missing" "$ERR"
assert_eq "review-view, a refusal after the view is built: the half-built view is removed" \
  "$N_VIEWS" "$(ls "$RVSCRATCH" | wc -l | tr -d ' ')"
assert_eq "review-view, a refusal after the view is built: no view is recorded" \
  "$RVVIEWS_BEFORE" "$(cat "$RVSTORE/$RVEXP/replays/$RVR_fable.views" 2>/dev/null)"
assert_eq "review-view: no refused review-view leaves a view behind" "$N_VIEWS" "$(ls "$RVSCRATCH" | wc -l | tr -d ' ')"

printf '\n== replay: stub-scripted sessions through the run-loop path ==\n'
# Every agent step runs through a stub named by ORCH_COMPARE_CLAUDE. The stub logs
# its arguments and working directory, answers with the next line of its script
# (or crashes, or hangs), and does what the step's agent would do to the tree: an
# implementer-like step edits scripts/a.sh and also flips a plan checkbox and
# edits .agents/roadmap.yaml (which no replay commit may carry); a reviewer-like
# step writes the review file its view's handoff names. The fixture start holds
# its own agents/ and scripts/ copies, so a session pointed at the clone's copies
# would be seen.
RP="$WORK/rpsrc"
mkdir -p "$RP/scripts" "$RP/agents" "$RP/.agents" "$RP/gspec/features/rp"
git -C "$RP" init -q
printf '.agents/loop/\n.agents/run-state.yaml\n' > "$RP/.gitignore"
printf 'echo a\n' > "$RP/scripts/a.sh"
printf -- '---\nname: implementer\nmodel: inherit\n---\nthe start commit'"'"'s own copy\n' > "$RP/agents/implementer.md"
printf -- '- [ ] **T1** rp work\n' > "$RP/gspec/features/rp/tasks.md"
printf 'order: []\n' > "$RP/.agents/roadmap.yaml"
printf 'project:\n  name: rp\npacket_attempts: 1\n' > "$RP/.agents/project-overrides.yaml"
git -C "$RP" add -A >/dev/null
GIT_AUTHOR_DATE=2026-05-01T00:00:00Z GIT_COMMITTER_DATE=2026-05-01T00:00:00Z git -C "$RP" -c user.name=fixture \
  -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m base >/dev/null
RP0="$(git -C "$RP" rev-parse HEAD)"
printf 'echo landed\n' >> "$RP/scripts/a.sh"
git -C "$RP" add -A >/dev/null
GIT_AUTHOR_DATE=2026-05-01T00:00:00Z GIT_COMMITTER_DATE=2026-05-01T00:00:00Z git -C "$RP" -c user.name=fixture \
  -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  commit -q -m "$(printf 'rp\n\n[orch packet:rp-t1]')" >/dev/null
RP1="$(git -C "$RP" rev-parse HEAD)"
mkdir -p "$RP/.agents/loop/20260501T000000-aa/rp-t1"
printf '# rp-t1: the original\n\ntier: integration\nagent: implementer\nrun-state: /elsewhere/run-state.yaml\nresult: /elsewhere/implementer.md\nreview: /elsewhere/review.md\n\nPACKET=rp-t1\nFILES=scripts/a.sh\n' \
  > "$RP/.agents/loop/20260501T000000-aa/rp-t1/handoff.md"
RPEXP=ccccccccccc6
RPSTORE="$WORK/rpstore"
RPSCRATCH="$WORK/rpscratch"
mkdir -p "$RPSTORE/$RPEXP"
cat > "$RPSTORE/$RPEXP/selection.json" <<EOF
{
  "experiment": "$RPEXP",
  "settings": {"role": "implementer", "models": ["fable", "sonnet"], "reviewer_model": "haiku", "source_repo": "$RP", "per_class": 1, "code_files": ["scripts/"], "prose_files": ["docs/"]},
  "selected": [
    {"packet": "rp-t1", "class": "code", "tier": "integration", "fix_rounds": 0, "title": "rp", "handoff": "original", "start": "$RP0", "commits": ["$RP1"]}
  ],
  "shortfalls": [],
  "excluded": [],
  "dropped": []
}
EOF
cat > "$WORK/stub-claude" <<'STUB'
#!/usr/bin/env bash
d="$STUB_DIR"
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/count"
prompt=""; plugin=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --plugin-dir) plugin="$2"; shift 2 ;;
    *) shift ;;
  esac
done
agent="$(printf '%s\n' "$prompt" | sed -n 's/^Dispatch the `\([a-z-]*\)` agent.*/\1/p' | head -1)"
printf 'call=%s agent=%s cwd=%s plugin=%s\n' "$n" "$agent" "$(pwd -P)" "$plugin" >> "$d/log"
printf '%s\n' "$prompt" > "$d/prompt.$n"
line="$(sed -n "${n}p" "$d/script")"
case "$line" in
  crash) echo boom >&2; exit 3 ;;
  hang) exec sleep 30 ;;
esac
if [ "$agent" = reviewer ]; then
  rv="$(printf '%s\n' "$prompt" | sed -n 's/^review: //p' | head -1)"
  if [ -n "$rv" ]; then cat "$rv" > "$d/seen.$n" 2>/dev/null; fi
  h="$(printf '%s\n' "$prompt" | sed -n 's/^Handoff: //p' | head -1)"
  r="$(sed -n 's/^review: //p' "$h" | head -1)"
  case "$line" in
    norev+*) line="${line#norev+}" ;;
    *) if [ -n "$r" ]; then printf 'review from call %s\n' "$n" > "$r"; fi ;;
  esac
else
  rv="$(printf '%s\n' "$prompt" | sed -n 's/^review: //p' | head -1)"
  if [ -n "$rv" ]; then cat "$rv" > "$d/seen.$n" 2>/dev/null; fi
  printf 'echo step %s\n' "$n" >> scripts/a.sh
  sed 's/- \[ \]/- [x]/' gspec/features/rp/tasks.md > .stub.tmp && mv .stub.tmp gspec/features/rp/tasks.md
  printf '# edited by call %s\n' "$n" >> .agents/roadmap.yaml
  case "$line" in
    ov+*)
      line="${line#ov+}"
      printf 'implementer_turn_budget: 5\n' >> .agents/project-overrides.yaml ;;
    rorev+*)
      line="${line#rorev+}"
      res="$(printf '%s\n' "$prompt" | sed -n 's/^result: //p' | head -1)"
      : > "$(dirname "$res")/review.md" && chmod 444 "$(dirname "$res")/review.md" ;;
    att+*)
      line="${line#att+}"
      sed 's/^packet_attempts: 1$/packet_attempts: 3/' .agents/project-overrides.yaml > .stub.tmp \
        && mv .stub.tmp .agents/project-overrides.yaml ;;
    commit+*)
      line="${line#commit+}"
      git add -A >/dev/null 2>&1
      git -c user.name=agent -c user.email=agent@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
        commit -q -m "the agent's own commit" >/dev/null 2>&1 ;;
  esac
fi
printf 'working on it\n%s\n' "$line"
STUB
chmod +x "$WORK/stub-claude"
IMPL_DONE='done · did the work · result: no · /r/implementer.md'
IMPL_CONT='continue · stopped at the budget · result: needs-reading · /r/implementer.md'
REV_PASS='pass · looks right · result: no · /r/review.md'
REV_FIX='fix · needs a test · result: needs-reading · /r/review.md'
REV_ESC='escalate · a design question · result: needs-reading · /r/review.md'
NOT_A_LINE='all finished, nothing more to say'
RPN=0
# rp_run <script lines...>: a fresh replay (prepared on fable) run through the stub.
# Sets OUT/RC/ERR, RPC (clone), RPR (replay), RPB (branch), RPH (handoff), SD
# (the stub's directory) and RPAGENTS (the agents the stub was asked for, in order).
rp_run() {
  RPN=$((RPN + 1)); SD="$WORK/stub$RPN"; mkdir -p "$SD"; : > "$SD/log"
  printf '%s\n' "$@" > "$SD/script"
  OUT="$(ORCH_COMPARE_STORE="$RPSTORE" ORCH_COMPARE_SCRATCH="$RPSCRATCH" "$COMPARE" prepare "$RPEXP" rp-t1 fable 2>/dev/null)"
  RPC="$(line CLONE)"; RPR="$(line REPLAY)"; RPB="$(line BRANCH)"; RPH="$(line HANDOFF)"
  OUT="$(STUB_DIR="$SD" ORCH_COMPARE_CLAUDE="$WORK/stub-claude" ORCH_COMPARE_STEP_TIMEOUT="${RP_TIMEOUT:-60}" \
    ORCH_COMPARE_STORE="$RPSTORE" ORCH_COMPARE_SCRATCH="$RPSCRATCH" "$COMPARE" replay "$RPR" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
  RPAGENTS="$(sed -n 's/^call=[0-9]* agent=\([^ ]*\) .*/\1/p' "$SD/log" | paste -sd' ' -)"
}
# rp_commits <label> <expected new commits>: every ref of the clone holds at
# most that many commits beyond the start, touching no plan or roadmap path.
rp_commits() {
  local n paths
  n="$(git -C "$RPC" rev-list --all --not "$RP0" | wc -l | tr -d ' ')"
  assert_eq "$1: the clone holds $2 new commit(s) on any ref" "$2" "$n"
  paths="$(git -C "$RPC" diff --name-only "$RP0" "refs/heads/$RPB" | paste -sd' ' -)"
  case " $paths " in
    *" gspec/"*|*" .agents/roadmap.yaml "*) bad "$1: the new commit touches no gspec/ or .agents/roadmap.yaml path" "$paths" ;;
    *) ok "$1: the new commit touches no gspec/ or .agents/roadmap.yaml path" ;;
  esac
}

rp_run "$IMPL_DONE" "$REV_PASS"
assert_eq "replay, pass first time: exit 0" "0" "$RC"
assert_eq "replay, pass first time: ends landed" "land" "$(line END)"
assert_eq "replay, pass first time: implementer, then reviewer" "implementer reviewer" "$RPAGENTS"
assert_has "replay, pass first time: the verdict is routed in the clone" "ROUTE agent=reviewer token=pass action=land" "$OUT"
rp_commits "replay, pass first time" 1
assert_eq "replay, pass first time: the commit is the packet's diff alone, on the start" \
  "$RP0|scripts/a.sh" "$(git -C "$RPC" rev-parse "refs/heads/$RPB^")|$(git -C "$RPC" diff --name-only "$RP0" "refs/heads/$RPB" | paste -sd' ' -)"
assert_eq "replay, pass first time: COMMIT= names the branch head" \
  "$(git -C "$RPC" rev-parse "refs/heads/$RPB")" "$(line COMMIT)"
assert_has "replay, pass first time: the commit carries the packet trailer" "[orch packet:rp-t1]" \
  "$(git -C "$RPC" log -1 --format=%B "refs/heads/$RPB")"
assert_eq "replay, pass first time: the plan checkbox stays unflipped in the commit" "- [ ] **T1** rp work" \
  "$(git -C "$RPC" show "refs/heads/$RPB:gspec/features/rp/tasks.md")"
assert_eq "replay, pass first time: the replay's routing is not in the commit" "" \
  "$(git -C "$RPC" diff "$RP0" "refs/heads/$RPB" -- .agents/project-overrides.yaml)"
assert_eq "replay, pass first time: the step log holds the printed lines" "$OUT" \
  "$(cat "$RPSTORE/$RPEXP/replays/$RPR.steps")"
RP_VIEW="$(line VIEW)"
assert_eq "replay, pass first time: the reviewer ran in the review view, the implementer in the clone" \
  "$RPC|$RP_VIEW" "$(sed -n 's/^call=1 .* cwd=\([^ ]*\) .*/\1/p' "$SD/log")|$(sed -n 's/^call=2 .* cwd=\([^ ]*\) .*/\1/p' "$SD/log")"
assert_eq "replay, pass first time: the view resolves the reviewer model" "haiku" "$("$ROUTING" --root "$RP_VIEW" resolve reviewer)"
RP_PASS_SD="$SD"; RP_PASS_C="$RPC"
# Once per replay.
OUT="$(STUB_DIR="$SD" ORCH_COMPARE_CLAUDE="$WORK/stub-claude" ORCH_COMPARE_STORE="$RPSTORE" \
  ORCH_COMPARE_SCRATCH="$RPSCRATCH" "$COMPARE" replay "$RPR" 2>"$WORK/err")"; RC=$?
assert_eq "replay, run a second time: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "replay, run a second time: named" "has already been run" "$(cat "$WORK/err")"

printf '\n== replay: the plugin dir is the harness checkout ==\n'
RPL="$(cat "$RP_PASS_SD/log")"
assert_eq "replay: every session is given the harness checkout as its plugin dir" "$REPO $REPO" \
  "$(sed -n 's/.* plugin=\(.*\)$/\1/p' "$RP_PASS_SD/log" | paste -sd' ' -)"
case "$RPL" in
  *"plugin=$RP_PASS_C"*) bad "replay: no session is given the clone as its plugin dir" "$RPL" ;;
  *) ok "replay: no session is given the clone as its plugin dir" ;;
esac
RPP="$(cat "$RP_PASS_SD/prompt.1" "$RP_PASS_SD/prompt.2")"
assert_has "replay: the implementer is dispatched through the harness's routing.sh against the clone" \
  "$REPO/scripts/routing.sh --root $RP_PASS_C resolve implementer" "$RPP"
assert_has "replay: the reviewer is dispatched through the harness's routing.sh against the view" \
  "$REPO/scripts/routing.sh --root $RP_VIEW resolve reviewer" "$RPP"
case "$RPP" in
  *"$RP_PASS_C/agents"*|*"$RP_PASS_C/scripts"*|*"$RP_VIEW/agents"*|*"$RP_VIEW/scripts"*)
    bad "replay: no prompt points at the clone's or view's own agents/ or scripts/" "$RPP" ;;
  *) ok "replay: no prompt points at the clone's or view's own agents/ or scripts/" ;;
esac
assert_eq "replay fixture: the clone does hold its own agents/ copy" "yes" \
  "$(if [ -f "$RP_PASS_C/agents/implementer.md" ]; then echo yes; else echo no; fi)"
case "$RPP" in
  *fable*|*haiku*|*sonnet*) bad "replay: no prompt names a model" "$RPP" ;;
  *) ok "replay: no prompt names a model" ;;
esac

printf '\n== replay: fix then pass ==\n'
# The second attempt commits on its own (after refresh-handoff has seen the
# first attempt's uncommitted work), so the land has an agent commit to replace.
rp_run "$IMPL_DONE" "$REV_FIX" "commit+$IMPL_DONE" "$REV_PASS"
assert_eq "replay, fix then pass: exit 0, ends landed" "0:land" "$RC:$(line END)"
assert_eq "replay, fix then pass: implementer, reviewer, implementer, reviewer" \
  "implementer reviewer implementer reviewer" "$RPAGENTS"
assert_has "replay, fix then pass: the fix is routed as an attempt" "ROUTE agent=reviewer token=fix action=attempt attempts=1 limit=1" "$OUT"
assert_has "replay, fix then pass: refresh-handoff runs before the re-dispatch" "REFRESH partial_work=inserted paths=1" "$OUT"
assert_eq "replay, fix then pass: each review gets a fresh view" "2" "$(printf '%s\n' "$OUT" | grep -c '^VIEW=')"
RPREV="$(dirname "$RPH")/review.md"
assert_has "replay, fix then pass: the second attempt's brief names the review" "review: $RPREV" "$(cat "$SD/prompt.3")"
assert_eq "replay, fix then pass: the second attempt reads the first review, copied into the clone" \
  "review from call 2" "$(cat "$SD/seen.3" 2>/dev/null)"
assert_eq "replay, fix then pass: the first attempt's brief names no review" "0" "$(grep -c '^review: ' "$SD/prompt.1")"
assert_eq "replay, fix then pass: the first reviewer's brief names no review" "0" "$(grep -c '^review: ' "$SD/prompt.2")"
RPVREV="$(sed -n 's/^review: //p' "$SD/prompt.4" | head -1)"
RPV4="$(sed -n 's/^call=4 .* cwd=\([^ ]*\) .*/\1/p' "$SD/log")"
case "$RPVREV" in
  "$RPV4"/?*) ok "replay, fix then pass: the second reviewer's brief names a review path in its own view" ;;
  *) bad "replay, fix then pass: the second reviewer's brief names a review path in its own view" "[$RPVREV] not under [$RPV4]" ;;
esac
assert_eq "replay, fix then pass: the second reviewer reads the first review there (run-loop §3.4)" \
  "review from call 2" "$(cat "$SD/seen.4" 2>/dev/null)"
rp_commits "replay, fix then pass (the agent committed on its own)" 1
assert_eq "replay, fix then pass: the one commit's parent is the start" "$RP0" "$(git -C "$RPC" rev-parse "refs/heads/$RPB^")"
assert_eq "replay, fix then pass: the commit is the packet's diff alone" "scripts/a.sh" \
  "$(git -C "$RPC" diff --name-only "$RP0" "refs/heads/$RPB" | paste -sd' ' -)"

printf '\n== replay: continue then pass ==\n'
# The second step also edits project-overrides.yaml itself, beside the replay's routing.
rp_run "$IMPL_CONT" "ov+$IMPL_DONE" "$REV_PASS"
assert_eq "replay, continue then pass: exit 0, ends landed" "0:land" "$RC:$(line END)"
RPOVD="$(git -C "$RPC" diff "$RP0" "refs/heads/$RPB" -- .agents/project-overrides.yaml | awk '/^[+-]/ && !/^(\+\+\+|---) /')"
assert_eq "replay, a packet's own edit to project-overrides.yaml: kept, and the routing is not" \
  "+implementer_turn_budget: 5" "$RPOVD"
assert_eq "replay, continue then pass: implementer twice, then one review" "implementer implementer reviewer" "$RPAGENTS"
assert_has "replay, continue then pass: continue is routed, spending no attempt" \
  "ROUTE agent=implementer token=continue action=continue attempts=0 limit=1" "$OUT"
assert_has "replay, continue then pass: refresh-handoff runs before the continuation" "REFRESH partial_work=inserted paths=1" "$OUT"
assert_has "replay, continue then pass: the continuation's handoff carries the partial-work block" \
  "<!-- orch:partial-work -->" "$(cat "$RPH")"
assert_eq "replay, continue then pass: a continuation start is recorded in the clone" "start continue" \
  "$(cat "$RPC"/.agents/metrics/outcomes/*.jsonl 2>/dev/null | sed -n 's/.*"kind":"\([a-z]*\)".*/\1/p' | paste -sd' ' -)"
rp_commits "replay, continue then pass" 1

printf '\n== replay: escalate ==\n'
rp_run "$IMPL_DONE" "$REV_ESC"
assert_eq "replay, escalate: exit 0, ends at the decider" "0:decider" "$RC:$(line END)"
assert_has "replay, escalate: routed to the decider" "ROUTE agent=reviewer token=escalate action=decider" "$OUT"
assert_eq "replay, escalate: the stub log shows no chief-engineer dispatch" "implementer reviewer" "$RPAGENTS"
case "$(cat "$SD/log")" in
  *chief-engineer*) bad "replay, escalate: no session names the chief-engineer" ;;
  *) ok "replay, escalate: no session names the chief-engineer" ;;
esac
assert_eq "replay, escalate: COMMIT=none" "none" "$(line COMMIT)"
rp_commits "replay, escalate" 0

printf '\n== replay: fix past the limit ==\n'
rp_run "$IMPL_DONE" "$REV_FIX" "$IMPL_DONE" "$REV_FIX" "$IMPL_DONE" "$REV_PASS"
assert_eq "replay, fix past the limit: exit 0, ends at the decider" "0:decider" "$RC:$(line END)"
assert_has "replay, fix past the limit: the second fix is past packet_attempts" \
  "ROUTE agent=reviewer token=fix action=decider attempts=2 limit=1" "$OUT"
assert_eq "replay, fix past the limit: no dispatch after the limit, no chief-engineer" \
  "implementer reviewer implementer reviewer" "$RPAGENTS"
rp_commits "replay, fix past the limit" 0

printf '\n== replay: a reviewer that leaves the seeded review as it was ==\n'
# The first step raises packet_attempts to 3, so a third attempt runs; the
# second reviewer writes no review of its own, so the seeded copy of the first
# is not this round's review and the third attempt is briefed with none.
rp_run "att+$IMPL_DONE" "$REV_FIX" "$IMPL_DONE" "norev+$REV_FIX" "$IMPL_DONE" "$REV_PASS"
assert_eq "replay, an unwritten review: ends landed after three attempts" \
  "0:land:implementer reviewer implementer reviewer implementer reviewer" "$RC:$(line END):$RPAGENTS"
assert_eq "replay, an unwritten review: the second reviewer was given the first review" \
  "review from call 2" "$(cat "$SD/seen.4" 2>/dev/null)"
assert_eq "replay, an unwritten review: the third attempt is not briefed with the previous round's review" \
  "0" "$(grep -c '^review: ' "$SD/prompt.5")"
assert_eq "replay, an unwritten review: nor is the third reviewer" "0" "$(grep -c '^review: ' "$SD/prompt.6")"
rp_commits "replay, an unwritten review" 1

printf '\n== replay: the review cannot be copied into the work clone ==\n'
# The first step leaves a read-only file where the clone's review copy goes.
rp_run "rorev+$IMPL_DONE" "$REV_FIX" "$IMPL_DONE"
assert_eq "replay, an uncopyable review: exit 1, ends in error, no further attempt" \
  "1:error:implementer reviewer" "$RC:$(line END):$RPAGENTS"
assert_has "replay, an uncopyable review: named" "cannot copy the review into the work clone" "$ERR"
rp_commits "replay, an uncopyable review" 0

printf '\n== replay: a crashed step, a timed-out step ==\n'
rp_run "$IMPL_DONE" crash
assert_eq "replay, a crashed step: exit 0, ends crashed" "0:crashed" "$RC:$(line END)"
assert_has "replay, a crashed step: the exit code is recorded" "STEP n=2 agent=reviewer try=1 exit=3 status=none" "$OUT"
assert_eq "replay, a crashed step: no step after it" "implementer reviewer" "$RPAGENTS"
rp_commits "replay, a crashed step" 0
T0=$SECONDS
RP_TIMEOUT=1 rp_run hang
assert_eq "replay, a timed-out step: exit 0, ends timed out" "0:timed-out" "$RC:$(line END)"
assert_has "replay, a timed-out step: recorded as a timeout" "STEP n=1 agent=implementer try=1 exit=timeout status=none" "$OUT"
assert_eq "replay, a timed-out step: killed at the limit, not left to finish" "yes" \
  "$(if [ $((SECONDS - T0)) -lt 20 ]; then echo yes; else echo no; fi)"
rp_commits "replay, a timed-out step" 0

printf '\n== replay: check-status and its one re-dispatch ==\n'
rp_run "$NOT_A_LINE" "$IMPL_DONE" "$REV_PASS"
assert_eq "replay, a refused line then a good one: ends landed" "0:land" "$RC:$(line END)"
assert_has "replay, a refused line: recorded as refused" "STEP n=1 agent=implementer try=1 exit=0 status=refused" "$OUT"
assert_has "replay, the re-dispatch carries check-status's reason" "check-status\` refused" "$(cat "$SD/prompt.2")"
rp_commits "replay, a refused line then a good one" 1
rp_run "$NOT_A_LINE" "$NOT_A_LINE" "$IMPL_DONE"
assert_eq "replay, a line refused twice: ends refused after two dispatches" "0:refused:implementer implementer" \
  "$RC:$(line END):$RPAGENTS"
rp_commits "replay, a line refused twice" 0

printf '\n== routing-check: run metrics from the work clone and each review view ==\n'
# A replay prepared on model aliases, as the first experiment names them, each
# pinned by the experiment's model_ids to one full id, run through the stub (implementer done, reviewer pass), then given fixture event
# logs and transcripts in the work clone and its one review view: what the
# metrics hook and the harness would have left there: the routing stamp an
# alias, the transcript a full id. The real metrics.sh collects them; each case
# rewrites the fixtures and runs the check again.
RC="$WORK/rcsrc"
mkdir -p "$RC/scripts" "$RC/.agents" "$RC/gspec/features/rp"
git -C "$RC" init -q
printf '.agents/loop/\n.agents/run-state.yaml\n.agents/metrics/\n' > "$RC/.gitignore"
printf 'echo a\n' > "$RC/scripts/a.sh"
printf -- '- [ ] **T1** rc work\n' > "$RC/gspec/features/rp/tasks.md"
printf 'packet_attempts: 1\n' > "$RC/.agents/project-overrides.yaml"
git -C "$RC" add -A >/dev/null
GIT_AUTHOR_DATE=2026-05-01T00:00:00Z GIT_COMMITTER_DATE=2026-05-01T00:00:00Z git -C "$RC" -c user.name=fixture \
  -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m base >/dev/null
RC0="$(git -C "$RC" rev-parse HEAD)"
printf 'echo landed\n' >> "$RC/scripts/a.sh"
git -C "$RC" add -A >/dev/null
GIT_AUTHOR_DATE=2026-05-01T00:00:00Z GIT_COMMITTER_DATE=2026-05-01T00:00:00Z git -C "$RC" -c user.name=fixture \
  -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  commit -q -m "$(printf 'rc\n\n[orch packet:rc-t1]')" >/dev/null
RC1="$(git -C "$RC" rev-parse HEAD)"
mkdir -p "$RC/.agents/loop/20260501T000000-bb/rc-t1"
printf '# rc-t1: the original\n\ntier: integration\nagent: implementer\nrun-state: /elsewhere/run-state.yaml\nresult: /elsewhere/implementer.md\nreview: /elsewhere/review.md\n\nPACKET=rc-t1\nFILES=scripts/a.sh\n' \
  > "$RC/.agents/loop/20260501T000000-bb/rc-t1/handoff.md"
RCEXP=ddddddddddd7
RCSTORE="$WORK/rcstore"
mkdir -p "$RCSTORE/$RCEXP"
cat > "$RCSTORE/$RCEXP/selection.json" <<EOF
{
  "experiment": "$RCEXP",
  "settings": {"role": "implementer", "models": ["fable"], "reviewer_model": "haiku", "model_ids": {"fable": "claude-fable-5-1", "haiku": "claude-haiku-4-5"}, "source_repo": "$RC", "per_class": 1, "code_files": ["scripts/"], "prose_files": ["docs/"]},
  "selected": [
    {"packet": "rc-t1", "class": "code", "tier": "integration", "fix_rounds": 0, "title": "rc", "handoff": "original", "start": "$RC0", "commits": ["$RC1"]}
  ],
  "shortfalls": [],
  "excluded": [],
  "dropped": []
}
EOF
SD="$WORK/stubrc"; mkdir -p "$SD"; : > "$SD/log"
printf '%s\n' "$IMPL_DONE" "$REV_PASS" > "$SD/script"
OUT="$(ORCH_COMPARE_STORE="$RCSTORE" ORCH_COMPARE_SCRATCH="$RPSCRATCH" "$COMPARE" prepare "$RCEXP" rc-t1 fable 2>"$WORK/err")"
assert_eq "routing-check fixture: prepared on an alias" "fable" "$(line MODEL)"
RCC="$(line CLONE)"; RCR="$(line REPLAY)"
OUT="$(STUB_DIR="$SD" ORCH_COMPARE_CLAUDE="$WORK/stub-claude" ORCH_COMPARE_STEP_TIMEOUT=60 \
  ORCH_COMPARE_STORE="$RCSTORE" ORCH_COMPARE_SCRATCH="$RPSCRATCH" "$COMPARE" replay "$RCR" 2>"$WORK/err")"
assert_eq "routing-check fixture: the replay landed" "land" "$(line END)"
RCV="$(line VIEW)"
RCPROJ="$WORK/rcproj"
RCREPLAYS="$RCSTORE/$RCEXP/replays"

# rc_seed <dir> <sid> <agent> <passed-model|-> <stamp|-> <transcript-model> [nook]:
# one dispatch of gaffer:<agent> from a session's main thread, the subagent's own
# tool event, and its transcript turn. `-` leaves the field off the Agent event;
# `nook` leaves `ok` off every event (a run before the ok capture).
rc_seed() {
  local ev="$1/.agents/metrics/events/$2.jsonl" ok=',"ok":true' mf="" st=""
  [ "${7:-}" = nook ] && ok=""
  [ "$4" = - ] || mf=",\"model\":\"$4\""
  [ "$5" = - ] || st=",\"routing_resolved\":\"$5\",\"routing_table\":{\"$3\":\"$5\"}"
  mkdir -p "$(dirname "$ev")" "$RCPROJ/p/$2/subagents"
  printf '{"ts":"2026-05-02T00:00:02Z","session_id":"%s","agent_id":"%sa","agent_type":"gaffer:%s","tool":"Edit"%s}\n' "$2" "$2" "$3" "$ok" > "$ev"
  printf '{"ts":"2026-05-02T00:00:03Z","session_id":"%s","agent_id":"","agent_type":"main","tool":"Agent","subagent_type":"gaffer:%s"%s%s%s}\n' \
    "$2" "$3" "$mf" "$st" "$ok" >> "$ev"
  printf '{"type":"assistant","timestamp":"2026-05-02T00:00:02Z","message":{"id":"%s-m1","model":"%s","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' \
    "$2" "$6" > "$RCPROJ/p/$2/subagents/agent-$2a.jsonl"
}
rc_reset() { rm -rf "$RCC/.agents/metrics/events" "$RCV/.agents/metrics/events" "$RCPROJ"; }
rc_run() {  # rc_run: OUT/ERR/RC for `compare.sh routing-check` on the fixture replay
  OUT="$(ORCH_METRICS_PROJECTS_DIR="$RCPROJ" ORCH_COMPARE_STORE="$RCSTORE" "$COMPARE" routing-check "$RCR" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}
chk() { printf '%s\n' "$OUT" | awk -v p="CHECK scope=$1 check=$2 " 'index($0, p) == 1'; }

# A clean replay.
rc_reset
rc_seed "$RCC" W1 implementer fable fable claude-fable-5-1
rc_seed "$RCV" V1 reviewer haiku haiku claude-haiku-4-5
RCVFILES="$(find "$RCV" -type f | LC_ALL=C sort)"
rc_run
assert_eq "routing-check, a clean replay: exit 0, passes" "0:pass" "$RC:$(line ROUTING_CHECK)"
assert_eq "routing-check, a clean replay: override count 0" "CHECK scope=work check=override-count result=pass value=0" "$(chk work override-count)"
assert_eq "routing-check, a clean replay: the implementer's resolved id" \
  "CHECK scope=work check=implementer-resolved-id result=pass value=fable" "$(chk work implementer-resolved-id)"
assert_eq "routing-check, a clean replay: the implementer ran on it" \
  "CHECK scope=work check=implementer-models result=pass value=claude-fable-5-1" "$(chk work implementer-models)"
assert_eq "routing-check, a clean replay: the reviewer's resolved id" \
  "CHECK scope=view-1 check=reviewer-resolved-id result=pass value=haiku" "$(chk view-1 reviewer-resolved-id)"
assert_eq "routing-check, a clean replay: the reviewer ran on it" \
  "CHECK scope=view-1 check=reviewer-models result=pass value=claude-haiku-4-5" "$(chk view-1 reviewer-models)"
assert_eq "routing-check, a clean replay: no line fails" "0" "$(printf '%s\n' "$OUT" | grep -c 'result=fail')"
assert_eq "routing-check: the packets are written beside the replay's record" \
  "$RCREPLAYS/$RCR.metrics/work.json|$RCREPLAYS/$RCR.metrics/view-1.json" \
  "$(printf '%s\n' "$OUT" | sed -n 's/^METRICS scope=work .* packet=//p')|$(printf '%s\n' "$OUT" | sed -n 's/^METRICS scope=view-1 .* packet=//p')"
assert_eq "routing-check: the collect in the view was the view's own" "$RCV" \
  "$(printf '%s\n' "$OUT" | sed -n 's/^METRICS scope=view-1 dir=\([^ ]*\) .*/\1/p')"
assert_eq "routing-check: nothing is written inside the review view" "$RCVFILES" "$(find "$RCV" -type f | LC_ALL=C sort)"
assert_eq "routing-check: the lines are stored as <replay>.routing" "$OUT" "$(cat "$RCREPLAYS/$RCR.routing")"

# An override count of 1: the implementer was passed a model routing did not resolve.
rc_reset
rc_seed "$RCC" W1 implementer opus fable claude-fable-5-1
rc_seed "$RCV" V1 reviewer haiku haiku claude-haiku-4-5
rc_run
assert_eq "routing-check, an override count of 1: the packet's own count is 1" "1" \
  "$(jq -r '.audit.dispatches_with_model_override' "$RCREPLAYS/$RCR.metrics/work.json")"
assert_eq "routing-check, an override count of 1: exit 0, fails" "0:fail" "$RC:$(line ROUTING_CHECK)"
assert_has "routing-check, an override count of 1: the failing line names override-count" \
  "CHECK scope=work check=override-count result=fail value=1 " "$(chk work override-count)"

# A null override count: no event carries `ok`, so the collector cannot count.
rc_reset
rc_seed "$RCC" W1 implementer fable fable claude-fable-5-1 nook
rc_seed "$RCV" V1 reviewer haiku haiku claude-haiku-4-5
rc_run
assert_eq "routing-check, a null override count: the packet's own count is null" "null" \
  "$(jq -r '.audit.dispatches_with_model_override' "$RCREPLAYS/$RCR.metrics/work.json")"
assert_eq "routing-check, a null override count: exit 0, fails" "0:fail" "$RC:$(line ROUTING_CHECK)"
assert_has "routing-check, a null override count: the failing line names override-count, unmeasured, never 0" \
  "CHECK scope=work check=override-count result=fail value=unmeasured " "$(chk work override-count)"

# A same-family, different-version subject model: claude-fable-5 where fable is
# pinned to claude-fable-5-1.
rc_reset
rc_seed "$RCC" W1 implementer fable fable claude-fable-5
rc_seed "$RCV" V1 reviewer haiku haiku claude-haiku-4-5
rc_run
assert_eq "routing-check, a same-family different-version model: exit 0, fails" "0:fail" "$RC:$(line ROUTING_CHECK)"
assert_eq "routing-check, a same-family different-version model: override count still 0" \
  "CHECK scope=work check=override-count result=pass value=0" "$(chk work override-count)"
assert_has "routing-check, a same-family different-version model: the failing line names implementer-models" \
  "CHECK scope=work check=implementer-models result=fail value=claude-fable-5 " "$(chk work implementer-models)"

# A wrong reviewer model in the view.
rc_reset
rc_seed "$RCC" W1 implementer fable fable claude-fable-5-1
rc_seed "$RCV" V1 reviewer haiku haiku claude-sonnet-5
rc_run
assert_eq "routing-check, a wrong reviewer model: exit 0, fails" "0:fail" "$RC:$(line ROUTING_CHECK)"
assert_eq "routing-check, a wrong reviewer model: the work clone passes" "0" \
  "$(printf '%s\n' "$OUT" | grep '^CHECK scope=work ' | grep -c 'result=fail')"
assert_has "routing-check, a wrong reviewer model: the failing line names reviewer-models" \
  "CHECK scope=view-1 check=reviewer-models result=fail value=claude-sonnet-5 " "$(chk view-1 reviewer-models)"

# Routing resolved an alias the experiment does not pin: its transcript id has
# nothing to be checked against, so the models check fails too.
rc_reset
rc_seed "$RCC" W1 implementer opus opus claude-opus-5-5
rc_seed "$RCV" V1 reviewer haiku haiku claude-haiku-4-5
rc_run
assert_eq "routing-check, an unpinned resolved alias: exit 0, fails" "0:fail" "$RC:$(line ROUTING_CHECK)"
assert_has "routing-check, an unpinned resolved alias: the resolved-id line names opus" \
  "CHECK scope=work check=implementer-resolved-id result=fail value=opus " "$(chk work implementer-resolved-id)"
assert_has "routing-check, an unpinned resolved alias: the models line says it has no pin" \
  "reason=routing resolved [opus], which the experiment's model_ids pins to no id" "$(chk work implementer-models)"

# An empty routing stamp reads as unresolved, never as an empty value.
rc_reset
rc_seed "$RCC" W1 implementer - "" claude-fable-5-1
rc_seed "$RCV" V1 reviewer haiku haiku claude-haiku-4-5
rc_run
assert_has "routing-check, an empty stamp: the resolved-id line reads unresolved" \
  "CHECK scope=work check=implementer-resolved-id result=fail value=unresolved " "$(chk work implementer-resolved-id)"

# A stored selection that pins no id for the replay's model is refused before any check.
cp "$RCSTORE/$RCEXP/selection.json" "$WORK/rc.sel"
sed 's/"fable": "claude-fable-5-1", //' "$WORK/rc.sel" > "$RCSTORE/$RCEXP/selection.json"
rm -f "$RCREPLAYS/$RCR.routing"
rc_run
cp "$WORK/rc.sel" "$RCSTORE/$RCEXP/selection.json"
assert_eq "routing-check, a selection with no pin for the model: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "routing-check, a selection with no pin for the model: names model_ids and the alias" \
  "model_ids pins no id for fable" "$ERR"

# Only after the review session has ended: a step log with no END is refused.
cp "$RCREPLAYS/$RCR.steps" "$WORK/rc.steps"
grep -v '^END=' "$WORK/rc.steps" > "$RCREPLAYS/$RCR.steps"
rm -f "$RCREPLAYS/$RCR.routing"
rc_run
cp "$WORK/rc.steps" "$RCREPLAYS/$RCR.steps"
assert_eq "routing-check, a replay that has not ended: exit 1, nothing on stdout" "1:" "$RC:$OUT"
assert_has "routing-check, a replay that has not ended: named" "has not ended" "$ERR"
assert_eq "routing-check, a replay that has not ended: nothing is recorded" "no" \
  "$(if [ -e "$RCREPLAYS/$RCR.routing" ]; then echo yes; else echo no; fi)"

printf '\n== usage ==\n'
"$COMPARE" >/dev/null 2>&1; assert_eq "no subcommand: exit 2" "2" "$?"
"$COMPARE" bogus >/dev/null 2>&1; assert_eq "unknown subcommand: exit 2" "2" "$?"
"$COMPARE" settings >/dev/null 2>&1; assert_eq "settings without a file: exit 2" "2" "$?"
"$COMPARE" settings "$WORK/absent.yaml" >/dev/null 2>&1; assert_eq "settings on a missing file: exit 2" "2" "$?"
"$COMPARE" candidates >/dev/null 2>&1; assert_eq "candidates without a file: exit 2" "2" "$?"
"$COMPARE" select >/dev/null 2>&1; assert_eq "select without a file: exit 2" "2" "$?"
"$COMPARE" estimate >/dev/null 2>&1; assert_eq "estimate without an experiment: exit 2" "2" "$?"
"$COMPARE" estimate aaaaaaaaaaa1 --bogus >/dev/null 2>&1; assert_eq "estimate with an unknown flag: exit 2" "2" "$?"
"$COMPARE" prepare aaaaaaaaaaa1 est-e1 >/dev/null 2>&1; assert_eq "prepare without a model: exit 2" "2" "$?"
"$COMPARE" review-view >/dev/null 2>&1; assert_eq "review-view without a replay: exit 2" "2" "$?"
"$COMPARE" replay >/dev/null 2>&1; assert_eq "replay without a replay id: exit 2" "2" "$?"
"$COMPARE" routing-check >/dev/null 2>&1; assert_eq "routing-check without a replay id: exit 2" "2" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
