#!/usr/bin/env bash
# =============================================================================
# test-report-conventions.sh — contract delivery: the report format (L2/L3) and
#                               the packet contract
# =============================================================================
# Synthetic repos on disk, no live agent. Exit 0 = all passed.
#
# What is under test, and why each assertion earns its place:
#
#   1. hooks/report-conventions.sh emits VALID JSON. It hand-escapes without jq
#      (stock Git Bash ships neither jq nor a real python3), and the card is full
#      of the characters that break hand-escaping: double quotes, backticks, `→`,
#      emoji. A malformed envelope is dropped silently by the harness — the exact
#      failure mode that leaves you thinking the hook is wired when it is dead.
#   2. L2 SUPPRESSES L3. If the repo's CLAUDE.md already carries the marker, the
#      hook must stay silent or every session pays for the same text twice.
#   3. It fails OPEN in every direction — no card, no CLAUDE.md, opt-out. It is
#      additive context; it must never block a session, and it carries no
#      permissionDecision, so it can never weaken the guard.
#   4. The card, the CLAUDE.md overlay copy and the full contract do not DRIFT.
#      Three copies of one contract is the standing risk of this design; the
#      byte-comparison is what keeps it a single source in practice.
#   5. CONTRACT DELIVERY BY `Read`, for `templates/task-packet.yaml`. Same failure
#      as 1-4, one layer down: both packet-scoping sites named the template's path
#      without saying `Read`, so an agent filling a packet had never seen the two
#      REQUIRED rules the file carries. Observed cost: packet `self-host-hardening-t6`
#      edited `scripts/metrics.sh` and landed with no case in `scripts/test-metrics.sh`
#      — under the very rule this delivery exists to apply. Asserted from BOTH ends:
#      the scoping sites carry an imperative `Read`, and the template still carries
#      the two REQUIRED rules that `Read` exists to deliver.
# =============================================================================

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
HOOK="$ROOT/hooks/report-conventions.sh"
CARD="$ROOT/templates/report-conventions-card.md"
OVERLAY="$ROOT/templates/spec-driven-base/CLAUDE.md"
MARKER='gaffer:report-conventions'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected: $2";; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A JSON reader that does not depend on the parser the HOOK avoids. Prefer python3,
# fall back to jq, and if neither is real, say so rather than passing vacuously.
JSON_TOOL=""
if printf '{}' | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
  JSON_TOOL=python3
elif printf '{}' | jq . >/dev/null 2>&1; then
  JSON_TOOL=jq
fi

_ctx() { # print additionalContext from a hook envelope on stdin
  case "$JSON_TOOL" in
    python3) python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' ;;
    jq)      jq -r '.hookSpecificOutput.additionalContext' ;;
  esac
}

printf '\n== the hook emits a valid, complete envelope ==\n'
R="$TMP/plain"; mkdir -p "$R"
printf '# CLAUDE.md\n\nA brief with nothing about reports in it.\n' > "$R/CLAUDE.md"
out="$(CLAUDE_PROJECT_DIR="$R" "$HOOK" </dev/null 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok 'exits 0' || bad 'exits 0' "rc=$rc"
[ -n "$out" ] && ok 'it emits something' || bad 'it emits something' 'no output'

if [ -z "$JSON_TOOL" ]; then
  bad 'JSON is parseable' 'no python3 or jq available to verify — not asserting vacuously'
else
  ctx="$(printf '%s' "$out" | _ctx 2>/dev/null || true)"
  [ -n "$ctx" ] && ok 'the envelope parses as JSON' || bad 'the envelope parses as JSON' "$out"
  has 'it declares the right event' 'SessionStart' "$out"
  # The characters that break hand-escaping must survive intact.
  has 'double quotes survive'   'something for you to pick' "$ctx"
  has 'the arrow survives'      '→ what follows if you pick it' "$ctx"
  has 'the glyphs survive'      '✅ landed' "$ctx"
  has 'backticks survive'       '`> ` quote bar' "$ctx"
  has 'the decision block survives' '**→ Pick A**' "$ctx"
  has 'the scope caveat leads'  'ordinary conversational answers are not reports' "$ctx"
  case "$ctx" in *$'\r'*) bad 'no raw CR in the payload' 'found CR';; *) ok 'no raw CR in the payload';; esac
fi

printf '\n== L2 suppresses L3 (no paying for the same text twice) ==\n'
R="$TMP/marked"; mkdir -p "$R"
printf '# CLAUDE.md\n\n<!-- %s v1 -->\n\n## Report conventions\n\nalready here.\n' "$MARKER" > "$R/CLAUDE.md"
out="$(CLAUDE_PROJECT_DIR="$R" "$HOOK" </dev/null 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok 'still exits 0' || bad 'still exits 0' "rc=$rc"
[ -z "$out" ] && ok 'and emits nothing when CLAUDE.md already carries it' \
  || bad 'suppression' "emitted ${#out} bytes"

printf '\n== it fails open in every direction ==\n'
R="$TMP/nomd"; mkdir -p "$R"
out="$(CLAUDE_PROJECT_DIR="$R" "$HOOK" </dev/null 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -n "$out" ] && ok 'no CLAUDE.md at all -> still injects' \
  || bad 'no CLAUDE.md' "rc=$rc bytes=${#out}"

out="$(ORCH_REPORT_CONVENTIONS=off CLAUDE_PROJECT_DIR="$TMP/plain" "$HOOK" </dev/null 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok 'ORCH_REPORT_CONVENTIONS=off silences it' \
  || bad 'opt-out' "rc=$rc bytes=${#out}"

# A missing card must be silent, not a broken envelope. Copy the hook somewhere with
# no templates/ beside it rather than moving the real one.
mkdir -p "$TMP/nocard/hooks"
cp "$HOOK" "$TMP/nocard/hooks/report-conventions.sh"
out="$(CLAUDE_PROJECT_DIR="$TMP/plain" "$TMP/nocard/hooks/report-conventions.sh" </dev/null 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok 'a missing card is silent, not malformed' \
  || bad 'missing card' "rc=$rc bytes=${#out}"

# Hooks are advisory here: never a permissionDecision, or it could weaken the guard.
out="$(CLAUDE_PROJECT_DIR="$TMP/plain" "$HOOK" </dev/null 2>/dev/null)"
case "$out" in
  *permissionDecision*) bad 'it never carries a permissionDecision' 'found one' ;;
  *) ok 'it never carries a permissionDecision' ;;
esac

printf '\n== the three copies of the contract do not drift ==\n'
# The overlay's copy must be the card, byte for byte, or a bootstrapped repo and a
# migrated one end up under different rules.
# Compared line-for-line ignoring blank lines and the overlay's own `---` rules:
# those are the host document's punctuation, not the card's content. Any wording
# difference — the real drift risk — still fails.
_content() { grep -v '^[[:space:]]*$' | grep -v '^---$'; }
if diff <(tail -n +2 "$CARD" | _content) \
        <(awk "/$MARKER/{f=1;next} f&&/^## Routing/{exit} f" "$OVERLAY" | _content) \
        >/dev/null 2>&1; then
  ok 'the CLAUDE.md overlay carries the card verbatim'
else
  bad 'the CLAUDE.md overlay carries the card verbatim' \
      "$(diff <(tail -n +2 "$CARD" | _content) \
              <(awk "/$MARKER/{f=1;next} f&&/^## Routing/{exit} f" "$OVERLAY" | _content) | head -10)"
fi

# The card is a DISTILLATION, so it must not contradict the full contract: every
# glyph it names has to still mean the same thing there.
for g in '✅' '⛔' '⚠️' '🔀' '⬚' '🔁' '⏸️' '▶'; do
  if grep -q -- "$g" "$ROOT/templates/report-conventions.md"; then :; else
    bad "glyph $g exists in the full contract" 'card names a glyph the contract does not'
  fi
done
ok 'every glyph the card names exists in the full contract'

# The card must stay SHORT — it is paid for in every session of every repo.
chars="$(wc -c < "$CARD" | tr -d ' ')"
[ "$chars" -lt 4000 ] && ok "the card stays small (${chars} chars)" \
  || bad 'the card has grown' "${chars} chars — detail belongs in templates/report-conventions.md"

printf '\n== the packet contract is delivered, not just referenced ==\n'
PACKET_TMPL="$ROOT/templates/task-packet.yaml"
# The exact two-span adjacency below is deliberate: it is what makes a bare
# path mention fail, and a benign rewording like "`Read` the packet template
# at `<path>`" will also fail it — accepted, because it fails loud with a
# self-describing message rather than passing on a paraphrase. Do not loosen
# this to a looser/fuzzier match.
IMPERATIVE='Read` `${CLAUDE_PLUGIN_ROOT}/templates/task-packet.yaml'

# Whitespace-squeeze each file so a markdown line break between the two
# backticked spans does not cause a false failure. CR is stripped FIRST, or a
# CRLF checkout (core.autocrlf=true, no .gitattributes here) leaves a
# trailing \r glued to the first span and the token sequence never matches —
# see the CRLF regression case below (ADR 0019 v3.1 paid for this class once
# already).
_squeeze() { tr -d '\r' < "$1" | tr '\n' ' ' | tr -s ' '; }

blob_runloop="$(_squeeze "$ROOT/skills/run-loop/SKILL.md")"
case "$blob_runloop" in
  *"$IMPERATIVE"*) ok 'run-loop SKILL.md Reads the packet template before scoping' ;;
  *) bad 'run-loop SKILL.md Reads the packet template before scoping' \
      "expected token sequence: $IMPERATIVE" ;;
esac

blob_ce="$(_squeeze "$ROOT/agents/chief-engineer.md")"
case "$blob_ce" in
  *"$IMPERATIVE"*) ok 'chief-engineer.md Reads the packet template before scoping' ;;
  *) bad 'chief-engineer.md Reads the packet template before scoping' \
      "expected token sequence: $IMPERATIVE" ;;
esac

has 'the template still carries the REQUIRED sweep-as-acceptance-criterion rule' \
  'REQUIRED: if `allowed_files` touches enforcement or automation code' \
  "$(cat "$PACKET_TMPL")"

has 'the template still carries the REQUIRED session_boundary rule' \
  'REQUIRED for a packet whose `allowed_files` touches a surface loaded at session' \
  "$(cat "$PACKET_TMPL")"

has 'the template still declares the session_boundary key' \
  'session_boundary:' \
  "$(cat "$PACKET_TMPL")"

# Cost invariant (ADR 0023 by-role scoping): agents that RECEIVE a filled packet
# must not carry the imperative Read — only whoever FILLS a packet does. A bare
# descriptive mention of the path is fine and must stay passing.
recv_fail=""
for f in "$ROOT/agents/implementer.md" "$ROOT/agents/reviewer.md" "$ROOT/agents/doc-writer.md"; do
  blob="$(_squeeze "$f")"
  case "$blob" in
    *"$IMPERATIVE"*) recv_fail="$recv_fail $(basename "$f")" ;;
  esac
done
[ -z "$recv_fail" ] && ok 'packet-receiving agents (implementer/reviewer/doc-writer) do not carry the Read' \
  || bad 'packet-receiving agents (implementer/reviewer/doc-writer) do not carry the Read' \
      "found the imperative in:$recv_fail"

# Anchor for the assertion above: its discriminating power depends on
# implementer.md still carrying the BARE descriptive path mention. Without
# this, deleting that sentence upstream would leave the negative assertion
# passing while testing nothing.
has 'the anchor for the negative assertion above still holds (implementer.md still mentions the bare path)' \
  '${CLAUDE_PLUGIN_ROOT}/templates/task-packet.yaml' \
  "$(cat "$ROOT/agents/implementer.md")"

printf '\n== compact-threshold output blocks name only the values the reader emits (loop-prose-consistency T1) ==\n'
# cmd_compact_threshold emits SOURCE=repo|operator|unknown, never gaffer-default --
# there is no settings-derived default branch in the reader. The two loop skills'
# output-contract comments must say so; the three rule-prose clauses that
# deliberately still name gaffer-default (the omission rule covers a value the
# reader could plausibly have emitted, and is not itself an output block) must
# stay byte-unchanged. Extraction is anchored on the invocation line, not a line
# number, so a moved or renamed fenced block fails loud rather than silently
# checking an empty span.
REPORT_SHAPES="$ROOT/templates/report-templates.md"
_extract_ct_block() { # file -> the fenced block containing `runstate.sh compact-threshold`
  sed -n '/runstate\.sh compact-threshold/,/^```$/p' "$1"
}
block_runloop="$(_extract_ct_block "$ROOT/skills/run-loop/SKILL.md")"
block_resume="$(_extract_ct_block "$ROOT/skills/resume/SKILL.md")"

[ -n "$block_runloop" ] && ok 'run-loop compact-threshold block extracted (anchor holds)' \
  || bad 'run-loop compact-threshold block extracted (anchor holds)' 'empty -- anchor moved or renamed'
[ -n "$block_resume" ] && ok 'resume compact-threshold block extracted (anchor holds)' \
  || bad 'resume compact-threshold block extracted (anchor holds)' 'empty -- anchor moved or renamed'

case "$block_runloop" in
  *gaffer-default*) bad 'run-loop output block names only repo|operator|unknown' 'found gaffer-default inside the output block' ;;
  *) ok 'run-loop output block names only repo|operator|unknown' ;;
esac
case "$block_resume" in
  *gaffer-default*) bad 'resume output block names only repo|operator|unknown' 'found gaffer-default inside the output block' ;;
  *) ok 'resume output block names only repo|operator|unknown' ;;
esac

has 'run-loop output block still names the SOURCE enum the reader actually emits' \
  'SOURCE=repo|operator|unknown' "$block_runloop"
has 'resume output block still names the SOURCE enum the reader actually emits' \
  'SOURCE=repo|operator|unknown' "$block_resume"

# The rule-prose clauses that deliberately keep naming gaffer-default must survive
# untouched: exactly one occurrence per file, three total across the two skills
# and the report shapes, and none of them inside a compact-threshold output block
# (checked immediately above).
count_runloop="$(grep -c -- 'gaffer-default' "$ROOT/skills/run-loop/SKILL.md")"
count_resume="$(grep -c -- 'gaffer-default' "$ROOT/skills/resume/SKILL.md")"
count_shapes="$(grep -c -- 'gaffer-default' "$REPORT_SHAPES")"
if [ "$count_runloop" = 1 ] && [ "$count_resume" = 1 ] && [ "$count_shapes" = 1 ]; then
  ok 'gaffer-default appears exactly once per file, in the three rule-prose clauses'
else
  bad 'gaffer-default appears exactly once per file, in the three rule-prose clauses' \
      "run-loop=$count_runloop resume=$count_resume shapes=$count_shapes"
fi

printf '\n== CRLF checkout does not break site-delivery detection ==\n'
# core.autocrlf=true + no .gitattributes here means a Windows checkout can
# hand _squeeze CRLF line endings. Reproduce that on copies in $TMP (never
# touch the real files) and assert the same two site-delivery checks still
# pass. The shim is written in awk, not `sed 's/$/\r/'` — BSD/macOS sed
# inserts a literal `r` there, which would make this case pass vacuously on
# exactly the machine where it matters.
CRLF_DIR="$TMP/crlf"; mkdir -p "$CRLF_DIR"
_to_crlf() { awk '{printf "%s\r\n", $0}' "$1" > "$2"; }
_to_crlf "$ROOT/skills/run-loop/SKILL.md" "$CRLF_DIR/run-loop-SKILL.md"
_to_crlf "$ROOT/agents/chief-engineer.md" "$CRLF_DIR/chief-engineer.md"

blob_runloop_crlf="$(_squeeze "$CRLF_DIR/run-loop-SKILL.md")"
case "$blob_runloop_crlf" in
  *"$IMPERATIVE"*) ok 'run-loop SKILL.md still Reads the packet template under CRLF' ;;
  *) bad 'run-loop SKILL.md still Reads the packet template under CRLF' \
      "expected token sequence: $IMPERATIVE" ;;
esac

blob_ce_crlf="$(_squeeze "$CRLF_DIR/chief-engineer.md")"
case "$blob_ce_crlf" in
  *"$IMPERATIVE"*) ok 'chief-engineer.md still Reads the packet template under CRLF' ;;
  *) bad 'chief-engineer.md still Reads the packet template under CRLF' \
      "expected token sequence: $IMPERATIVE" ;;
esac

printf '\n== the loop shapes are built from run-digest, not from memory (ADR 0028) ==\n'
# thin-loop-driver T18. The driver returns/receives STATUS LINES and never opens a
# result file, so shapes B and C have to be assembled from `runstate.sh run-digest`
# — otherwise a stop report rendered after a compaction, or by a session that resumed
# another session's run, silently drops packets it was not present for. These
# assertions pin the contract as WRITTEN; nothing can check that a rendered report
# actually obeyed it (see the amendment's "Known gap"), which is the reviewer's job.
SHAPES="$ROOT/templates/report-templates.md"
CONV="$ROOT/templates/report-conventions.md"
WIRE="$ROOT/templates/check-in.md"
ADR23="$ROOT/docs/adr/0023-report-conventions-delivered-not-referenced.md"

shapes_blob="$(cat "$SHAPES")"
has 'the shapes name run-digest as the source for B and C' \
  'runstate.sh run-digest' "$shapes_blob"
has 'the shapes say B is assembled from it with no --since' \
  'run-digest <run-state>` with no `--since`' "$shapes_blob"
has "the shapes say C's session facts come from the enter line" \
  "comes from \`run-digest\`'s \`enter\` line" "$shapes_blob"
has 'the shapes forbid asking the operator to change model/effort/threshold' \
  'Never ask the operator to raise the effort' "$shapes_blob"
has 'shape A is one line per ended packet with no tally' \
  'No header tally' "$shapes_blob"
has 'shape B names a periodic pause by its setting' \
  'pause_every_packets' "$shapes_blob"
has 'shape B names the paused packet with the word paused' \
  'paused here; the run stopped on this one' "$shapes_blob"

# Bind the shapes to the digest's OWN outcome enum. If run-digest grows or renames an
# outcome, a shape with no glyph for it renders nothing at all for that packet — the
# exact "silently drops a packet" failure this feature exists to remove. Asserted in
# BOTH files so a rename has to be made in both or fail here.
#
# The shapes side is matched against the two blocks that actually ENUMERATE outcomes --
# shape A's glyph map and shape B's tally sentence -- not the whole file. Against the
# whole file `open` matches "opens shapes B and C" and "the operator", and `paused`
# matches the digest-contract prose, so the assertion would pass for those two with no
# rendering rule existing at all. This repo has twice shipped assertions that passed
# while checking nothing (test-runstate.sh's PyYAML fallback, the sed-vs-awk CRLF shim),
# which is why the anchoring is worth the two sed ranges. Both anchors are unique, and a
# renamed heading breaks the range and fails here rather than silently emptying it --
# hence the non-empty guard below.
DIGEST_SRC="$ROOT/scripts/runstate.sh"
enum_blob="$(sed -n "/Glyph by the digest's/,/blocked · interrupted · abandoned/p" "$SHAPES"
             sed -n '/The tally counts `packet` lines by outcome/,/rather than guessing a number/p' "$SHAPES")"
missing=""
[ -n "$enum_blob" ] || missing="$missing shapes:ENUM-BLOCKS-NOT-FOUND"
for o in green failed rolled-back blocked abandoned interrupted paused open; do
  printf '%s' "$enum_blob" | grep -q -- "$o" || missing="$missing shapes:$o"
  grep -q -- "$o" "$DIGEST_SRC" || missing="$missing runstate:$o"
done
[ -z "$missing" ] && ok 'every run-digest outcome has a rendering in the shapes' \
  || bad 'every run-digest outcome has a rendering in the shapes' "missing:$missing"

printf '\n== the shapes and the conventions agree where they overlap ==\n'
# The shapes file opens by saying it ASSUMES the conventions file, so the two
# disagreeing is not a cosmetic nit -- in a change whose only product is the wording of
# a formatting contract it is the defect itself. Two overlaps exist after ADR 0028's
# rework, and each is pinned on BOTH sides so drift in either fails here: the ⚠️
# bucket's shape-B label, and shape A's two-line exception to the one-line 🔀 rule.
conv_blob="$(cat "$CONV")"
has 'the conventions define the shape B wording of the warning bucket' \
  'worded *blocked* in general and *unfinished* in the loop' "$conv_blob"
has "shape B's tally uses that wording" \
  '⚠️ **N unfinished**' "$shapes_blob"
has "shape B's section heading moves with it" \
  '⚠️ **Unfinished**' "$shapes_blob"
has 'the conventions carry the shape A exception to the one-line rule' \
  'exactly one exception, and it is the loop' "$conv_blob"
has 'the shapes claim the same exception, in the same direction' \
  'documented exception to `report-conventions.md`' "$shapes_blob"
has "shape A's decision rule enumerates rather than conditioning on ending a packet" \
  'including when the decision is what ended the packet it names' "$shapes_blob"

printf '\n== loop agents return status lines, not check-ins ==\n'
has 'the wire format says the loop no longer uses it' \
  'The LOOP no longer uses this file' "$(cat "$WIRE")"
has 'the wire format points at status-line.md' \
  'status-line.md' "$(cat "$WIRE")"
has 'the conventions list status-line.md as a layer' \
  'status-line.md' "$(cat "$CONV")"
has 'the conventions say loop agents return status lines, not check-ins' \
  'status lines, NOT check-ins' "$(cat "$CONV")"
has 'the conventions scope the header tally to B and C' \
  'THE HEADER TALLY (opens shapes B and C' "$(cat "$CONV")"

printf '\n== ADR 0023 was AMENDED, not rewritten ==\n'
# Rewriting an accepted ADR is an operator escalation in this repo
# (.agents/project-overrides.yaml escalate_to_human_on). The amendment must be an
# APPENDED section: the original decision text has to survive verbatim, and the
# amendment has to come after it.
adr_blob="$(cat "$ADR23")"
has 'the original L2 decision text survives' \
  'the consumer repo'"'"'s own `CLAUDE.md` carries a distilled card' "$adr_blob"
has 'the original rejected-validator consequence survives' \
  'What was rejected: a `Stop`-hook format validator' "$adr_blob"
has 'the original known gap survives' \
  'L2 lands in existing repos only when `/gaffer:migrate` is re-run' "$adr_blob"
has 'an amendment section exists' '## Amendment' "$adr_blob"
has 'the amendment states it retracts nothing' 'Nothing above is retracted' "$adr_blob"
# Order: the amendment must come AFTER the original Consequences, never in place of it.
orig_ln="$(grep -n '^## Consequences' "$ADR23" | head -1 | cut -d: -f1)"
amend_ln="$(grep -n '^## Amendment' "$ADR23" | head -1 | cut -d: -f1)"
if [ -n "$orig_ln" ] && [ -n "$amend_ln" ] && [ "$amend_ln" -gt "$orig_ln" ]; then
  ok 'the amendment is appended after the original decision, not spliced into it'
else
  bad 'the amendment is appended after the original decision, not spliced into it' \
      "Consequences@${orig_ln:-none} Amendment@${amend_ln:-none}"
fi
# The card is NOT part of this change: the amendment must say so, and the byte
# comparison above is what proves it.
has 'the amendment states the card is untouched' \
  'stay byte-identical' "$adr_blob"

printf '\n----------------------------------------\n'
printf 'report-conventions: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
