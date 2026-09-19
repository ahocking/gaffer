#!/usr/bin/env bash
# =============================================================================
# test-routing.sh — regression sweep for scripts/routing.sh (per-agent-model-routing)
# =============================================================================
# Pins the model-routing lookup WITHOUT a live agent: `resolve`, `validate` and
# `table` against throwaway config roots (`--root`) and a fixture agent set
# (`ORCH_ROUTING_AGENTS_DIR`), covering every fallback, every report reason,
# both YAML forms, the exit-status contract (0 in every config state, 2 only
# for a usage error) and the VALID_MODELS pin.
#
# Run:  scripts/test-routing.sh   (exit 0 = all passed, 1 = a case failed)
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROUTING="$HERE/routing.sh"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '     %s\n' "$2"; fi; fail=$((fail + 1)); }
# Capture-then-compare throughout: no assertion here is a pipe-fed `grep -q`
# (see test-runstate.sh's assert_true for the SIGPIPE-under-pipefail flake).
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

WORK="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture agent set --------------------------------------------------------
AGENTS="$WORK/agents"
mkdir -p "$AGENTS"
mk_agent() {  # mk_agent <name> [model]
  {
    printf -- '---\nname: %s\ndescription: fixture\n' "$1"
    if [ -n "${2:-}" ]; then printf 'model: %s\n' "$2"; fi
    printf -- '---\n\nbody\nmodel: not-frontmatter\n'
  } > "$AGENTS/$1.md"
}
mk_agent implementer sonnet
mk_agent reviewer    opus
mk_agent architect   opus
mk_agent doc-writer  haiku
mk_agent loop-driver inherit
mk_agent nomodel
export ORCH_ROUTING_AGENTS_DIR="$AGENTS"

NL='
'
# mkroot <yaml-or-__MISSING__>  -> prints a fresh root dir. mktemp, not a
# counter: mkroot runs in a command substitution, so a counter would not persist.
mkroot() {
  local r
  r="$(mktemp -d "$WORK/root.XXXXXX")"
  mkdir -p "$r/.agents"
  if [ "$1" != "__MISSING__" ]; then printf '%s' "$1" > "$r/.agents/project-overrides.yaml"; fi
  printf '%s' "$r"
}

# rt <root> <args...>: run routing.sh, capture stdout into OUT and rc into RC.
OUT=""; RC=0
rt() {
  local r="$1"; shift
  OUT="$("$ROUTING" --root "$r" "$@" 2>/dev/null)"; RC=$?
}

# check <label> <root> <agent> <expected-resolve> <expected-validate>
check() {
  rt "$2" resolve "$3"
  assert_eq "$1: resolve $3" "$4" "$OUT"
  assert_eq "$1: resolve exits 0" "0" "$RC"
  rt "$2" table
  assert_eq "$1: table exits 0" "0" "$RC"
  # validate last, so OUT holds the report for any follow-up assertion.
  rt "$2" validate
  assert_eq "$1: validate report" "$5" "$OUT"
  assert_eq "$1: validate exits 0" "0" "$RC"
}

UM='unknown-model(add it to extra_models if the harness accepts it)'

# --- the eight required cases: resolve output AND validate line -----------------
R="$(mkroot "model_routing:${NL}  implementer: opus${NL}")"
check "mapped agent" "$R" implementer opus ""

check "unmapped agent" "$R" reviewer "" ""

R="$(mkroot __MISSING__)"
check "missing file" "$R" implementer "" ""

R="$(mkroot "model_routing: {}${NL}")"
check "empty map {}" "$R" implementer "" ""

R="$(mkroot "model_routing:${NL}  ghost: opus${NL}  implementer: opus${NL}")"
check "unknown agent key" "$R" ghost "" "ROUTING-INVALID key=ghost value=opus reason=unknown-agent"
rt "$R" resolve implementer
assert_eq "unknown agent key: other entries still apply" "opus" "$OUT"

R="$(mkroot "model_routing:${NL}  loop-driver: opus${NL}")"
check "loop-driver key" "$R" loop-driver "" "ROUTING-INVALID key=loop-driver value=opus reason=loop-driver"

R="$(mkroot "model_routing:${NL}  implementer: gpt-9${NL}  reviewer: fable${NL}")"
check "unrecognized model" "$R" implementer "" "ROUTING-INVALID key=implementer value=gpt-9 reason=$UM"
case "$OUT" in *extra_models*) ok "unrecognized model: reason names extra_models" ;;
  *) bad "unrecognized model: reason names extra_models" "$OUT" ;; esac
rt "$R" resolve reviewer
assert_eq "unrecognized model: other entries still apply" "fable" "$OUT"

R="$(mkroot "model_routing:${NL}  implementer: opus${NL}  - bogus${NL}")"
check "unparseable block" "$R" implementer "" "ROUTING-INVALID key=model_routing value=- reason=unparseable"

# --- forms, quoting, comments --------------------------------------------------
RB="$(mkroot "model_routing:${NL}  implementer: opus${NL}  reviewer: fable${NL}other: 1${NL}")"
RF="$(mkroot "model_routing: {implementer: opus, reviewer: fable}${NL}other: 1${NL}")"
for sub in validate table; do
  rt "$RB" "$sub"; ob="$OUT"; rt "$RF" "$sub"; of="$OUT"
  assert_eq "block and flow forms: identical $sub" "$ob" "$of"
done
for a in implementer reviewer architect; do
  rt "$RB" resolve "$a"; ob="$OUT"; rt "$RF" resolve "$a"; of="$OUT"
  assert_eq "block and flow forms: identical resolve $a" "$ob" "$of"
done
rt "$RB" table
assert_eq "block form: table" "implementer sonnet opus${NL}reviewer opus fable" "$OUT"

R="$(mkroot "model_routing:  # routing${NL}  \"implementer\": 'opus'  # trailing${NL}  'reviewer': \"fable\"${NL}")"
check "quoted keys and values, trailing comment" "$R" implementer opus ""
rt "$R" resolve reviewer
assert_eq "quoted key and value: reviewer" "fable" "$OUT"

R="$(mkroot "model_routing: {\"implementer\": 'opus'} # trailing${NL}")"
check "flow form: quoted, trailing comment" "$R" implementer opus ""

R="$(mkroot "model_routing: {}${NL}  # implementer: opus${NL}  # reviewer: fable${NL}${NL}other: 1${NL}")"
check "indented comment lines after {}" "$R" implementer "" ""

R="$(mkroot "model_routing: {}${NL}  implementer: opus${NL}")"
check "indented entry after flow map" "$R" implementer "" "ROUTING-INVALID key=model_routing value=- reason=unparseable"

R="$(mkroot "model_routing: {implementer: opus${NL}")"
check "unclosed flow brace" "$R" implementer "" "ROUTING-INVALID key=model_routing value=- reason=unparseable"

R="$(mkroot "model_routing:${NL}  implementer: opus${NL}  implementer: haiku${NL}  reviewer: fable${NL}")"
check "duplicate key is unparseable" "$R" implementer "" "ROUTING-INVALID key=model_routing value=- reason=unparseable"
rt "$R" resolve reviewer
assert_eq "unparseable block: every agent takes its default" "" "$OUT"

R="$(mkroot "model_routing: {implementer: opus, implementer: haiku}${NL}")"
check "duplicate key in flow form is unparseable" "$R" implementer "" "ROUTING-INVALID key=model_routing value=- reason=unparseable"

R="$(mkroot "model_routing:${NL}  implementer:${NL}    model: opus${NL}")"
check "deeper nesting is unparseable" "$R" implementer "" "ROUTING-INVALID key=model_routing value=- reason=unparseable"

R2="$(mkroot "$(printf 'model_routing:\r\n  implementer: opus\r\n')")"
check "CRLF config" "$R2" implementer opus ""

# --- prefix, case, extra_models -------------------------------------------------
R="$(mkroot "model_routing:${NL}  implementer: opus${NL}")"
rt "$R" resolve gaffer:implementer
assert_eq "gaffer:implementer resolves like implementer" "opus" "$OUT"

R="$(mkroot "model_routing:${NL}  implementer: Opus${NL}")"
check "Opus is unknown-model" "$R" implementer "" "ROUTING-INVALID key=implementer value=Opus reason=$UM"

R="$(mkroot "extra_models: [foo-1]${NL}model_routing:${NL}  implementer: foo-1${NL}")"
check "extra_models value accepted (flow)" "$R" implementer foo-1 ""

R="$(mkroot "model_routing: {implementer: bar.2}${NL}extra_models:${NL}  - foo-1${NL}  - 'bar.2'  # c${NL}")"
check "extra_models value accepted (block)" "$R" implementer bar.2 ""

R="$(mkroot "extra_models:${NL}- foo-1${NL}model_routing: {implementer: foo-1}${NL}")"
check "extra_models block at column 0" "$R" implementer foo-1 ""

R="$(mkroot "extra_models: [ok-1, \"b@d\"]${NL}model_routing: {implementer: ok-1}${NL}")"
check "bad extra_models item reported" "$R" implementer ok-1 "ROUTING-INVALID key=extra_models value=b@d reason=invalid-item"

R="$(mkroot "extra_models: [ok-1${NL}model_routing: {implementer: opus, reviewer: ok-1}${NL}")"
check "unparseable extra_models reported once, model_routing still applies" "$R" implementer opus \
  "ROUTING-INVALID key=reviewer value=ok-1 reason=$UM${NL}ROUTING-INVALID key=extra_models value=- reason=unparseable"
lines="$(printf '%s\n' "$OUT" | awk '/key=extra_models/ { c++ } END { print c + 0 }')"
assert_eq "unparseable extra_models: exactly one extra_models line" "1" "$lines"

# --- table ------------------------------------------------------------------
R="$(mkroot "model_routing:${NL}  reviewer: opus${NL}  nomodel: fable${NL}  implementer: haiku${NL}")"
rt "$R" table
assert_eq "table: omits entry equal to frontmatter, '-' for no model:, sorted" \
  "implementer sonnet haiku${NL}nomodel - fable" "$OUT"
assert_eq "table: exits 0" "0" "$RC"
rt "$R" resolve reviewer
assert_eq "entry equal to frontmatter still resolves" "opus" "$OUT"

R="$(mkroot "model_routing: {}${NL}")"
rt "$R" table
assert_eq "table: empty map prints nothing" "" "$OUT"

# --- non-plugin types, usage errors -------------------------------------------
R="$(mkroot "model_routing: {implementer: opus}${NL}")"
OUT="$("$ROUTING" --root "$R" resolve Explore 2>/dev/null; printf x)"; RC=$?
assert_eq "resolve Explore prints an empty line" "${NL}x" "$OUT"
rt "$R" resolve Explore
assert_eq "resolve Explore exits 0" "0" "$RC"

rt "$R" resolve
assert_eq "resolve with no argument exits 2" "2" "$RC"
rt "$R" bogus
assert_eq "unknown subcommand exits 2" "2" "$RC"
OUT="$("$ROUTING" 2>/dev/null)"; RC=$?
assert_eq "no subcommand exits 2" "2" "$RC"

# no --root, outside any git repo: defaults, exit 0
OUT="$(cd "$WORK" && GIT_CEILING_DIRECTORIES="$WORK" "$ROUTING" resolve implementer 2>/dev/null)"; RC=$?
assert_eq "no --root outside a git repo: resolves to default" "" "$OUT"
assert_eq "no --root outside a git repo: exits 0" "0" "$RC"

# no --root inside a worktree: reads the MAIN checkout's config
G="$WORK/repo"
git -c init.defaultBranch=main init -q "$G"
git -C "$G" config user.email t@example.com
git -C "$G" config user.name tester
printf 'x\n' > "$G/README"
git -C "$G" add README && git -C "$G" commit -qm init
mkdir -p "$G/.agents"
printf 'model_routing: {implementer: opus}\n' > "$G/.agents/project-overrides.yaml"
git -C "$G" worktree add -q "$WORK/wt" -b side >/dev/null 2>&1
OUT="$(cd "$WORK/wt" && "$ROUTING" resolve implementer 2>/dev/null)"; RC=$?
assert_eq "no --root from a worktree: reads main checkout config" "opus" "$OUT"

# --- VALID_MODELS pin -----------------------------------------------------------
pin="$(awk '/^VALID_MODELS=\(/ { print; exit }' "$ROUTING")"
assert_eq "VALID_MODELS pinned to exactly sonnet opus haiku fable" \
  "VALID_MODELS=(sonnet opus haiku fable)" "$pin"
cnt="$(awk '/^VALID_MODELS=/ { c++ } END { print c + 0 }' "$ROUTING")"
assert_eq "VALID_MODELS assigned exactly once" "1" "$cnt"

# --- the real agent set: loop-driver excluded ---------------------------------
R="$(mkroot "model_routing: {implementer: opus, loop-driver: opus}${NL}")"
OUT="$(ORCH_ROUTING_AGENTS_DIR= "$ROUTING" --root "$R" validate 2>/dev/null)"; RC=$?
assert_eq "real agents dir: implementer valid, loop-driver reported" \
  "ROUTING-INVALID key=loop-driver value=opus reason=loop-driver" "$OUT"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
