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

# --- dispatching-file sweep (arch Rule: DispatchSiteRouting) --------------------
# A dispatching file is a skills/*/SKILL.md or agents/*.md that (a) lists `Task`
# on its frontmatter `tools:` line, or (b) matches the dispatch/delegate regex
# over the agent set DERIVED from <root>/agents/*.md. Every one must contain the
# literal `routing.sh resolve`. File-reading greps only — no pipe-fed `grep -q`.

# dispatch_files <root>: print every dispatching file under <root>, repo-relative.
dispatch_files() {
  local root="$1" f n agents="" re
  for f in "$root"/agents/*.md; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .md)"
    agents="${agents:+$agents|}$n"
  done
  [ -n "$agents" ] || return 0
  re="(dispatch(es|ed|ing)?|delegat(e|es|ed|ing) to)[[:space:]]+([[:alnum:]-]+[[:space:]]+){0,2}(\\*\\*|\`)(gaffer:)?($agents)(\\*\\*|\`)"
  for f in "$root"/skills/*/SKILL.md "$root"/agents/*.md; do
    [ -f "$f" ] || continue
    if awk 'NR == 1 && $0 != "---" { exit 1 }
            NR > 1 && $0 == "---" { exit 1 }
            /^tools:/ && /(^|[^[:alnum:]_])Task([^[:alnum:]_]|$)/ { found = 1; exit 0 }
            END { exit !found }' "$f"; then
      printf '%s\n' "${f#"$root"/}"
    elif grep -Eiq -- "$re" "$f"; then
      printf '%s\n' "${f#"$root"/}"
    fi
  done
}

# missing_resolve <root> <file-list>: print each listed file lacking the literal.
missing_resolve() {
  local root="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -Fq 'routing.sh resolve' "$root/$f" || printf '%s\n' "$f"
  done <<EOF
$2
EOF
}

REPO="$(cd "$HERE/.." && pwd -P)"
DSET="$(dispatch_files "$REPO")"
for want in skills/run-loop/SKILL.md skills/review-change/SKILL.md agents/chief-engineer.md; do
  case "$NL$DSET$NL" in
    *"$NL$want$NL"*) ok "dispatching set includes $want" ;;
    *) bad "dispatching set includes $want" "set: $(printf '%s' "$DSET" | tr '\n' ' ')" ;;
  esac
done
MISS="$(missing_resolve "$REPO" "$DSET")"
assert_eq "every dispatching file names routing.sh resolve" "" "$MISS"

# negative control: a fixture dispatching file lacking the literal fails the check
FX="$WORK/fixture-repo"
mkdir -p "$FX/agents" "$FX/skills/lacks" "$FX/skills/has" "$FX/skills/inert"
printf -- '---\nname: implementer\nmodel: sonnet\n---\nbody\n' > "$FX/agents/implementer.md"
printf -- '---\nname: lacks\n---\nThen dispatch a fresh `implementer` with the path.\n' > "$FX/skills/lacks/SKILL.md"
printf -- '---\nname: has\n---\nRun `routing.sh resolve implementer`, then dispatch the **implementer**.\n' > "$FX/skills/has/SKILL.md"
printf -- '---\nname: inert\n---\nNo delegation here.\n' > "$FX/skills/inert/SKILL.md"
FSET="$(dispatch_files "$FX")"
assert_eq "fixture: dispatching set is exactly the two dispatching skills" \
  "skills/has/SKILL.md${NL}skills/lacks/SKILL.md" "$FSET"
FMISS="$(missing_resolve "$FX" "$FSET")"
assert_eq "fixture: file lacking routing.sh resolve fails the check" "skills/lacks/SKILL.md" "$FMISS"

# --- the one-shot skills: reasons one clause, the rest in their ADRs (skill-prompt-trim T11) ---
# Capability 3: each rule in skills/metrics, skills/new-project and skills/review-change
# keeps at most one clause of reason; the rest moved to a dated `Relocated from skills
# (<date>)` section of the ADR that owns the rule. Each row pins all three sides of one
# move -- the clause the skill kept, the moved wording gone from the skill, and that
# wording present in the named relocation section -- so a reason pasted back, or a move
# that dropped the wording instead of relocating it, turns this red. Text is compared
# whitespace-squeezed, so a markdown wrap does not fail a clause that is present; each
# ADR needle sits on one blockquote line, since `> ` prefixes survive the squeeze.
t11_sq() { printf '%s' "$1" | tr -d '\r' | tr '\n' ' ' | tr -s ' '; }
while IFS='|' read -r t11_skill t11_label t11_kept t11_moved t11_adr t11_frag; do
  [ -n "$t11_skill" ] || continue
  t11_txt="$(t11_sq "$(cat "$REPO/skills/$t11_skill/SKILL.md")")"
  case "$t11_txt" in
    *"$t11_kept"*) ok "$t11_skill keeps one clause: $t11_label" ;;
    *) bad "$t11_skill keeps one clause: $t11_label" "missing: $t11_kept" ;;
  esac
  case "$t11_txt" in
    *"$t11_moved"*) bad "$t11_skill carries no copy of the moved reason: $t11_label" "still present: $t11_moved" ;;
    *) ok "$t11_skill carries no copy of the moved reason: $t11_label" ;;
  esac
  t11_adr_file="$(ls "$REPO"/docs/adr/"$t11_adr"-*.md 2>/dev/null | head -1)"
  t11_sect="$(sed -n "/^## Relocated from skills ([0-9-]*) — $t11_frag/,\$p" "$t11_adr_file" 2>/dev/null)"
  case "$(t11_sq "$t11_sect")" in
    *"$t11_moved"*) ok "ADR $t11_adr's $t11_skill relocation section holds it: $t11_label" ;;
    *) bad "ADR $t11_adr's $t11_skill relocation section holds it: $t11_label" "no '$t11_moved' under '$t11_frag' in ${t11_adr_file:-docs/adr/$t11_adr-*.md}" ;;
  esac
done <<'T11_MOVES'
metrics|window-bounded boundaries|so a prior run's committed packets are not folded in|(zero-migration; run-state is left untouched|0019|the metrics skill's collection
metrics|main-session context|**Main-session context.**|is the "Long runs compact" success metric|0019|the metrics skill's collection
metrics|kickoff baseline vs run-digest|This run-KICKOFF baseline is expected to disagree with `run-digest`|answers what setting is in effect *now*|0019|the metrics skill's collection
metrics|threshold is the operator's call|whether and what to set is the operator's call|not this report's to open|0019|the metrics skill's collection
metrics|low cache ratio|re-loading context instead of reusing it|the loop's biggest suspected hidden cost|0019|the metrics skill's collection
metrics|same-file overlap|It tells the operator whether concurrent editing guidance is holding|It replaces parallel mode's mechanical file-disjointness guarantee|0019|the metrics skill's collection
metrics|cc_shape over totals|which are too noisy to steer by|1.76x spread across untouched same-regime runs|0019|the metrics skill's collection
metrics|context invalidations|which re-caches the whole prefix|Measured at 16 events / 3.35M cacheC|0019|the metrics skill's collection
metrics|self-host never averaged|since the populations are incomparable|feeds the measurement corpus that benchmarks the plugin|0019|the metrics skill's collection
metrics|conventions are Read|naming the path is not reading it|and unread they produce free prose|0023|the metrics, new-project and review-change skills'
metrics|conventions file described|so those conventions *are* its format|the decision block that every human-facing report|0023|the metrics, new-project and review-change skills'
metrics|show takes no tally|since there is nothing to count here|the tally means "this is a run and here is its state"|0023|the metrics, new-project and review-change skills'
metrics|trade-off is a decision block|A bullet that hides a cost reads as free|the same form every other ask in this plugin takes|0023|the metrics, new-project and review-change skills'
new-project|conventions are Read|naming the path is not reading it|and unread they produce free prose|0023|the metrics, new-project and review-change skills'
new-project|conventions file described|so those conventions *are* its format|the decision block that every human-facing report|0023|the metrics, new-project and review-change skills'
new-project|gspec is pinned|since it changes rapidly|each upstream change is adapted to deliberately|0020|the new-project skill's pin
new-project|empty PIN stops|an unpinned install is the failure mode ADR 0020 D3 exists to prevent|and it will not announce itself|0020|the new-project skill's pin
new-project|pin recorded in the repo|so a human can see it without reading the plugin|this is the only durable local record of which gspec produced the specs|0020|the new-project skill's pin
new-project|roadmap outside gspec/|floor flags a file under `gspec/` that gspec does not own|anything under `gspec/` is governed by gspec's|0020|the new-project skill's pin
new-project|no status or parallel_group|storing either is a drift source|named a scheduling mechanism (ADR 0016) that is now retired|0020|the new-project skill's pin
new-project|task-files not seeded|already means "no scope known"|which serializes conservatively, so leaving it unseeded costs nothing|0020|the new-project skill's pin
review-change|conventions are Read|naming the path is not reading it|and unread they produce free prose|0023|the metrics, new-project and review-change skills'
review-change|conventions file described|so those conventions *are* its format|the decision block that every human-facing report|0023|the metrics, new-project and review-change skills'
review-change|risk is a decision block|A risk worth reporting is a choice|is the shape that gets skimmed and forgotten|0023|the metrics, new-project and review-change skills'
review-change|verdict takes no tally|a review is not a run and has nothing to count|decoration is what teaches a reader to stop trusting the glyphs|0023|the metrics, new-project and review-change skills'
T11_MOVES

# Capability 4 and the history rule: none of the three states a setting's value or a
# script's fallback, and none carries a task id or a fix-history story.
for t11_skill in metrics new-project review-change; do
  t11_hist="$(grep -nE '\(default |default on|default the last|7 days|^ +[a-z_]+: (true|false|[0-9]+) +#|ORCH_METRICS=|\bT[0-9]+\b|v3\.3 already|raised from 20' "$REPO/skills/$t11_skill/SKILL.md" || true)"
  [ -z "$t11_hist" ] && ok "$t11_skill states no setting value, fallback, task id or fix history" \
    || bad "$t11_skill states no setting value, fallback, task id or fix history" "found: $(printf '%s' "$t11_hist" | head -1)"
done

# Every instruction, prohibition and trap beside a moved reason keeps its rule wording.
while IFS='|' read -r t11_skill t11_rule; do
  [ -n "$t11_skill" ] || continue
  case "$(t11_sq "$(cat "$REPO/skills/$t11_skill/SKILL.md")")" in
    *"$t11_rule"*) ok "$t11_skill keeps the rule: $t11_rule" ;;
    *) bad "$t11_skill keeps the rule: $t11_rule" "missing from skills/$t11_skill/SKILL.md" ;;
  esac
done <<'T11_RULES'
metrics|a pause commit's trailer never implies green
metrics|**Outcome coverage is a label, never a green count.**
metrics|A real `max_context` is never paired against an invented threshold.
metrics|A later re-entry is ASSUMED, not verified
metrics|never rewrite it into an instruction to set that key or a recommended value for it
metrics|This takes **no header tally and no glyph gutter**
metrics|say so in words, since a `0` reads to the human as "clean"
metrics|change effort/model at a **packet boundary**
metrics|Read `totals.outcome_coverage` first
metrics|Self-host and consumer runs must NOT be averaged together
metrics|never rank a null row as a zero
metrics|**A recommendation that is really a trade-off is a decision block**
metrics|archive a run by **copying its `run-metrics.json` out**, not by committing the live directory
new-project|Read the pin from the adapter, never hardcode it here
new-project|If `PIN` resolves empty, **stop**
new-project|**Do not add `status` or `parallel_group`**
new-project|Confirm it landed; do not hand-write it.
new-project|which is **not** seeded
new-project|Do not install `.specify/` / `speckit-*`.
new-project|Then **stop** and ask the human to approve
review-change|Read-only pre-merge review: do not fix, commit, or merge anything
review-change|**🔀 Risks — as decision blocks, not observations.**
review-change|No header tally here
review-change|Stop there. Any commit or merge is the human's call.
T11_RULES

# Each dispatch keeps its `routing.sh resolve` beside it: within the same `## ` section
# of the skill, every agent a "delegate to"/"dispatch" phrase names (the agent set
# derived from agents/*.md, as dispatch_files derives it) has `routing.sh resolve
# <agent>`. Section-scoped, so a resolve moved to another step -- or naming another
# agent -- fails where the file-level literal check above would still pass.
# t11_unresolved <file> <agents-alternation>: print "<section-index> <agent>" per
# dispatch lacking its resolve in the same section.
t11_unresolved() {
  local f="$1" agents="$2" re n i sect hit agent
  re="(dispatch(es|ed|ing)?|delegat(e|es|ed|ing) to)[[:space:]]+([[:alnum:]-]+[[:space:]]+){0,2}(\\*\\*|\`)(gaffer:)?($agents)(\\*\\*|\`)"
  n="$(awk '/^## / { c++ } END { print c + 0 }' "$f")"
  i=0
  while [ "$i" -le "$n" ]; do
    sect="$(t11_sq "$(awk -v n="$i" '/^## / { c++ } c == n' "$f")")"
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      agent="$(printf '%s' "$hit" | sed -E 's/.*(\*\*|`)(gaffer:)?([[:alnum:]-]+)(\*\*|`)$/\3/' | tr 'A-Z' 'a-z')"
      case "$sect" in
        *"routing.sh resolve $agent"*) : ;;
        *) printf '%s %s\n' "$i" "$agent" ;;
      esac
    done <<EOF
$(printf '%s' "$sect" | grep -Eio -- "$re" || true)
EOF
    i=$((i + 1))
  done
}
t11_agents=""
for f in "$REPO"/agents/*.md; do
  [ -f "$f" ] || continue
  t11_agents="${t11_agents:+$t11_agents|}$(basename "$f" .md)"
done
t11_want='metrics:1 new-project:1 review-change:3'
for t11_skill in metrics new-project review-change; do
  t11_f="$REPO/skills/$t11_skill/SKILL.md"
  assert_eq "$t11_skill: every dispatch has routing.sh resolve in its own section" "" \
    "$(t11_unresolved "$t11_f" "$t11_agents")"
  t11_n="$(t11_sq "$(cat "$t11_f")" | grep -Eio -- "(dispatch(es|ed|ing)?|delegat(e|es|ed|ing) to)[[:space:]]+([[:alnum:]-]+[[:space:]]+){0,2}(\\*\\*|\`)(gaffer:)?($t11_agents)(\\*\\*|\`)" | wc -l | tr -d ' ')"
  case " $t11_want " in
    *" $t11_skill:$t11_n "*) ok "$t11_skill: dispatch count is what the check covers ($t11_n)" ;;
    *) bad "$t11_skill: dispatch count is what the check covers" "got $t11_n; want per $t11_want" ;;
  esac
done
# negative control: a dispatch whose resolve sits in another section is caught
mkdir -p "$FX/skills/split"
printf -- '---\nname: split\n---\n## 1. A\nRun `routing.sh resolve implementer`.\n## 2. B\nDelegate to the **implementer** now.\n' > "$FX/skills/split/SKILL.md"
assert_eq "fixture: a resolve in another section does not cover the dispatch" "2 implementer" \
  "$(t11_unresolved "$FX/skills/split/SKILL.md" "implementer")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
