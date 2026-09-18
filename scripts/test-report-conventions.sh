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

printf '\n== shape B section order matches the conventions fixed tally order (loop-prose-consistency T2) ==\n'
# The order is DERIVED from the conventions' own fixed-tally line, not hardcoded here
# -- so this case tracks the AUTHORITY, and a future reordering of the tally is what
# it re-derives from, not a frozen copy of today's order. What it must catch: a shape
# B internally consistent with itself (its own headings agree with its own tally) but
# diverged from report-conventions.md's fixed order.
TALLY_LINE="$(awk '/# Fixed order, omitting any bucket that is zero:/{getline; print; exit}' "$CONV")"
[ -n "$TALLY_LINE" ] || bad 'the conventions fixed-tally line is found' 'anchor moved or renamed'

_glyph_pos() { # tally-line glyph -> byte offset of its first occurrence, else empty
  local hay="$1" needle="$2" pre
  case "$hay" in
    *"$needle"*) pre="${hay%%"$needle"*}"; printf '%s' "${#pre}" ;;
  esac
}

_heading_text() { # glyph -> shape B's own section-heading text for it
  case "$1" in
    '✅') printf '✅ **Shipped**' ;;
    '⛔') printf '⛔ **Failed**' ;;
    '⚠️') printf '⚠️ **Unfinished**' ;;
    '🔀') printf '🔀 **Decisions**' ;;
    '⬚') printf '⬚ **Queued**' ;;
  esac
}

CANDIDATE_GLYPHS='✅ ⛔ ⚠️ 🔀 ⬚'

EXPECTED_ORDER=""
while IFS=$'\t' read -r _ g; do
  EXPECTED_ORDER="$EXPECTED_ORDER $g"
done < <(
  for g in $CANDIDATE_GLYPHS; do
    pos="$(_glyph_pos "$TALLY_LINE" "$g")"
    [ -n "$pos" ] && printf '%s\t%s\n' "$pos" "$g"
  done | sort -n
)
EXPECTED_ORDER="${EXPECTED_ORDER# }"
[ -n "$EXPECTED_ORDER" ] || bad 'a glyph order was derived from the tally line' 'derived nothing -- glyphs not found in the tally line'

# Shape B's own rendered body: from its header tally line to its `▶ Next` line.
# Anchored on text unique to shape B (shape C opens with `▶ **STARTING**`, not
# `⏸️ **PAUSED**`), so a moved or renamed anchor fails loud via the empty-block check
# below rather than silently scanning the wrong text.
BODY_B="$(sed -n '/^⏸️ \*\*PAUSED\*\*/,/^▶ \*\*Next\*\*/p' "$SHAPES")"
[ -n "$BODY_B" ] || bad 'shape B rendered-body block extracted (anchor holds)' 'empty -- anchor moved or renamed'

ACTUAL_ORDER=""
while IFS=$'\t' read -r _ g; do
  ACTUAL_ORDER="$ACTUAL_ORDER $g"
done < <(
  for g in $CANDIDATE_GLYPHS; do
    heading="$(_heading_text "$g")"
    ln="$(printf '%s\n' "$BODY_B" | grep -n -F -- "$heading" | head -1 | cut -d: -f1)"
    [ -n "$ln" ] && printf '%s\t%s\n' "$ln" "$g"
  done | sort -n
)
ACTUAL_ORDER="${ACTUAL_ORDER# }"

if [ -n "$EXPECTED_ORDER" ] && [ "$ACTUAL_ORDER" = "$EXPECTED_ORDER" ]; then
  ok "shape B's section headings appear in the conventions' fixed tally order ($ACTUAL_ORDER)"
else
  bad "shape B's section headings appear in the conventions' fixed tally order" \
      "expected: $EXPECTED_ORDER -- got: $ACTUAL_ORDER"
fi

printf '\n== report-lint checks a rendered report against its digest (report-render-conformance T2) ==\n'
# Every rule gets a CONFORMING fixture that yields no finding of that rule and a
# VIOLATING fixture that yields it BY NAME -- so no rule can pass by the lint
# reporting nothing at all. The fixtures are small and written here; nothing is
# read from a real run.
LINT="$ROOT/scripts/report-lint.sh"
LD="$TMP/lint"; mkdir -p "$LD"

[ -x "$LINT" ] && ok 'report-lint.sh exists and is executable' \
  || bad 'report-lint.sh exists and is executable' "$LINT"

_lint() { "$LINT" --shape "$1" "$2" "$3" 2>/dev/null; }
_fires()    { case "$2" in *"FINDING=$1"$'\t'*) return 0;; esac; return 1; }
fires()     { if _fires "$2" "$3"; then ok "$1"; else bad "$1" "expected FINDING=$2 -- got: $(printf '%s' "$3" | head -3 | tr '\n' ' ')"; fi; }
not_fires() { if _fires "$2" "$3"; then bad "$1" "unexpected: $(printf '%s\n' "$3" | grep "FINDING=$2" | head -2 | tr '\n' ' ')"; else ok "$1"; fi; }

# The digest a conforming shape B was rendered from, and an empty one.
printf 'packet\ttxn-t1\tStream large imports\tgreen\npacket\ttxn-t2\tPaginate the list\tgreen\npacket\ttxn-t4\tDuplicate detection\tpaused\ndecision\ttxn-t4\task-operator\nenter\tclaude-opus-5\thigh\tunknown\n' > "$LD/digest"
: > "$LD/digest-empty"

# A conforming shape B, carrying every construct the shape itself defines: the
# multi-glyph tally line, the `▶ Next` section, and a state line whose branch
# CONTAINS a digest id (`orch/txn-t4`) next to a bare sha.
cat > "$LD/b-ok.md" <<'EOF'
⏸️ **PAUSED** · Transaction import · ✅ **2 shipped** · ⚠️ **1 unfinished** · 🔀 **2 decisions** · ⬚ **2 queued**

Paused after 3 packets. Nothing at risk, nothing half-written.

✅ **Shipped**

> ✅ **Large imports don't time out** (`txn-t1`) — 50k rows in one pass
> ✅ **Transaction list paginates** (`txn-t2`) — 200 a page, not the whole table

⚠️ **Unfinished**

> ⚠️ **Duplicate detection** (`txn-t4`) — paused here; the run stopped on this one

🔀 **Decisions** — reply `1A`

> **1 · How do we decide two imports are the same transaction?**
>
> - **A ›** Match on amount + date + description
>   → duplicates vanish silently; ~1 in 500 genuine repeats swallowed
> - **B ›** Flag for the user to confirm
>   → nothing is ever lost; ~1,000 prompts on a first big import
>
> **→ Pick A** — recoverable, and confirm-flows are the ones users abandon.
> *Silence = A, matches logged.*
>
> *1 more, lower stakes — ask and I'll lay them out.*

⬚ **Queued**

> ⬚ **2 more** — the date filter and the audit log, neither blocked

▶ **Next** — answer decision 1, then `/gaffer:resume`.

> `orch/txn-t4` @ `c40aa11` · tree clean · `/gaffer:resume`
EOF

# A conforming shape C: phase lines, `▶ Session`/`▶ Autonomy` headings, and a
# `Will need you` section whose "nothing expected" value is real information.
cat > "$LD/c-ok.md" <<'EOF'
▶ **STARTING** · Transaction import: make it survive real bank files · ⬚ **5 packets** · 2 phases

> **Phase 1 — speed** · ⬚ Stream large imports · ⬚ Paginate the list · ⬚ Cache totals
> **Phase 2 — correctness** · ⬚ Duplicate detection · ⬚ Import audit log

⚠️ **Assuming** — every bank in the sample set sends a stable per-transaction id.

🔀 **Will need you** — none

> **Won't touch:** the transactions table schema, so no migration.

▶ **Session** claude-opus-5[1m] · effort unknown

▶ **Autonomy** autonomous · **Stops at** `orch/txn-import` ready for review
EOF

out="$(_lint B "$LD/b-ok.md" "$LD/digest")"
[ "$out" = 'REPORT_LINT=clean' ] && ok 'a conforming shape B (tally line, ▶ Next, branch+sha state line) is clean' \
  || bad 'a conforming shape B (tally line, ▶ Next, branch+sha state line) is clean' "$out"
out="$(_lint C "$LD/c-ok.md" "$LD/digest-empty")"
[ "$out" = 'REPORT_LINT=clean' ] && ok 'a conforming kickoff with an EMPTY digest is judged, and clean (phase lines, ▶ Session/Autonomy, Will need you)' \
  || bad 'a conforming kickoff with an EMPTY digest is judged, and clean' "$out"
out="$(_lint C "$LD/c-ok.md" "$LD/digest")"
[ "$out" = 'REPORT_LINT=clean' ] && ok 'the same kickoff against a populated digest is clean too' \
  || bad 'the same kickoff against a populated digest is clean too' "$out"

# The shape-defined constructs, one assertion each, against the rule each would
# otherwise trip -- so an exemption that silently widens or vanishes shows here.
b_ok="$(_lint B "$LD/b-ok.md" "$LD/digest")"
c_ok="$(_lint C "$LD/c-ok.md" "$LD/digest-empty")"
not_fires 'the tally line may carry many glyphs (shape-defined)' two-glyphs "$b_ok"
not_fires "▶ Next is outside the tally's order (shape-defined)" section-order "$b_ok"
not_fires 'a branch naming an id, and a bare sha, in the state line never fire (shape-defined)' untitled-id "$b_ok"
not_fires "the kickoff's phase lines may carry many glyphs (shape-defined)" two-glyphs "$c_ok"
not_fires "the kickoff's ▶ Session and ▶ Autonomy headings are not out of order (shape-defined)" section-order "$c_ok"
not_fires "the kickoff's Will need you may say none (rule 3's exception)" empty-section "$c_ok"
# ...and the phase-line exemption belongs to shape C: the same line in a B is two glyphs.
{ head -1 "$LD/b-ok.md"; printf '\n> **Phase 1 — speed** · ⬚ Stream · ⬚ Page\n'; } > "$LD/b-phase.md"
fires 'a phase line is only exempt in the shape that defines it' two-glyphs "$(_lint B "$LD/b-phase.md" "$LD/digest")"

# --- rule: unknown-glyph --------------------------------------------------------
not_fires 'unknown-glyph: every glyph in the vocabulary is conformant' unknown-glyph "$b_ok"
sed 's/^> ⬚ \*\*2 more\*\*/> 📦 **2 more**/' "$LD/b-ok.md" > "$LD/v-unknown.md"
fires 'unknown-glyph: a glyph outside the vocabulary is named' unknown-glyph "$(_lint B "$LD/v-unknown.md" "$LD/digest")"

# --- rule: two-glyphs -------------------------------------------------------------
sed 's/^> ✅ \*\*Large imports/> ✅ 🔁 **Large imports/' "$LD/b-ok.md" > "$LD/v-two.md"
fires 'two-glyphs: two glyphs on one line is named' two-glyphs "$(_lint B "$LD/v-two.md" "$LD/digest")"

# --- rule: section-order -----------------------------------------------------------
# Move the ✅ Shipped section below ⚠️ Unfinished.
awk 'NR==5||NR==6||NR==7||NR==8||NR==9{held=held $0 "\n"; next} {print} /paused here; the run stopped/{printf "\n%s", held}' \
  "$LD/b-ok.md" > "$LD/v-order.md"
fires 'section-order: headings out of the tally order are named' section-order "$(_lint B "$LD/v-order.md" "$LD/digest")"
# Shape B: a section the header tally does not count breaks the table of contents.
sed 's/ · ⬚ \*\*2 queued\*\*//' "$LD/b-ok.md" > "$LD/v-toc.md"
fires 'section-order: a shape-B heading with no figure in the tally is named' section-order "$(_lint B "$LD/v-toc.md" "$LD/digest")"

# The order is DERIVED from the conventions' fixed-tally line, not frozen: reorder
# the authority (🔀 before ✅) in a copy, and the conforming report now fails.
CONV_RE="$LD/conv-reordered.md"
awk '/# Fixed order, omitting any bucket that is zero:/{print; getline; print "#   🔀 N decisions · ✅ N shipped · ⛔ N failed · ⚠️ N blocked · ⬚ N queued"; next} {print}' \
  "$CONV" > "$CONV_RE"
out="$(ORCH_REPORT_LINT_CONVENTIONS="$CONV_RE" "$LINT" --shape B "$LD/b-ok.md" "$LD/digest" 2>/dev/null)"
fires 'section-order re-derives from a reordered fixed-tally line (not a frozen copy)' section-order "$out"
# Same for the vocabulary: add 📦 to a copy's glyph table and it stops being unknown.
CONV_VOC="$LD/conv-vocab.md"
awk '{print} /^#   ▶  the next action/{print "#   📦  a package                          line"}' "$CONV" > "$CONV_VOC"
out="$(ORCH_REPORT_LINT_CONVENTIONS="$CONV_VOC" "$LINT" --shape B "$LD/v-unknown.md" "$LD/digest" 2>/dev/null)"
not_fires 'unknown-glyph re-derives from the glyph table (not a frozen copy)' unknown-glyph "$out"

# --- rule: decision-count ------------------------------------------------------------
not_fires 'decision-count: the 🔀 figure equals blocks + the "N more" deferral' decision-count "$b_ok"
sed 's/🔀 \*\*2 decisions\*\*/🔀 **3 decisions**/' "$LD/b-ok.md" > "$LD/v-count.md"
fires 'decision-count: a 🔀 figure unequal to the body is named' decision-count "$(_lint B "$LD/v-count.md" "$LD/digest")"
# The ⬚ Queued "2 more" is not a decision deferral, and must not be counted as one.
grep -v 'lower stakes' "$LD/b-ok.md" > "$LD/v-defer.md"
fires 'decision-count: a dropped deferral is caught (the queued "N more" is not counted)' decision-count "$(_lint B "$LD/v-defer.md" "$LD/digest")"
# Only the italic deferral line counts: an "N more" inside a question is not one.
grep -v 'lower stakes' "$LD/b-ok.md" \
  | sed -e 's/🔀 \*\*2 decisions\*\*/🔀 **1 decision**/' \
        -e 's/^> \*\*1 · How do we decide two imports are the same transaction?\*\*/> **1 · Import 2 more banks?**/' \
  > "$LD/c-inq.md"
not_fires 'decision-count: an "N more" inside a question is not a deferral' decision-count "$(_lint B "$LD/c-inq.md" "$LD/digest")"

# --- rule: untitled-id ------------------------------------------------------------------
not_fires 'untitled-id: every digest id first appears after a bold title' untitled-id "$b_ok"
sed 's/^> ✅ \*\*Transaction list paginates\*\* (`txn-t2`)/> ✅ `txn-t2` paginates/' "$LD/b-ok.md" > "$LD/v-id.md"
out="$(_lint B "$LD/v-id.md" "$LD/digest")"
fires 'untitled-id: a digest id with no title on first appearance is named' untitled-id "$out"
case "$out" in *'txn-t2'*) ok 'untitled-id names the id it found';; *) bad 'untitled-id names the id it found' "$out";; esac
# Ids come ONLY from the digest: a sha and a branch not in it never fire, even bare.
printf '%s\n\n> bare `deadbeef` and `feature/other-t9` in prose\n' "$(head -1 "$LD/b-ok.md")" > "$LD/c-shas.md"
not_fires 'untitled-id: a sha or branch not in the digest never fires' untitled-id "$(_lint B "$LD/c-shas.md" "$LD/digest")"

# --- rule: empty-section ----------------------------------------------------------------
not_fires 'empty-section: a report that omits empty sections is conformant' empty-section "$b_ok"
awk '{print} /^✅ \*\*Shipped\*\*/{hold=1} hold && /^$/ && ++n==2 {print "⛔ **Failed** — none\n"; hold=0}' \
  "$LD/b-ok.md" > "$LD/v-none.md"
fires 'empty-section: a section written as "none" is named' empty-section "$(_lint B "$LD/v-none.md" "$LD/digest")"
# The kickoff exception is only for `Will need you`: another kickoff section saying none fires.
sed 's/^> \*\*Won.t touch:\*\* .*/> **Won'"'"'t touch:** none/' "$LD/c-ok.md" > "$LD/v-none-c.md"
fires "empty-section: the kickoff's exception covers only Will need you" empty-section "$(_lint C "$LD/v-none-c.md" "$LD/digest-empty")"

# --- a finding changes nothing about the run ---------------------------------------------
# An all-violations report, linted from inside a synthetic repo carrying a run-state,
# an outcomes log and a plan file: exit 0, every rule fires, and every one of those
# files -- and the directory listing -- is byte-identical afterwards.
AV="$TMP/allviol"; mkdir -p "$AV/.agents/metrics/outcomes" "$AV/gspec/features/x"
printf 'schema: 3\nstatus: running\nrun_id: 20260918T000000-0000\n' > "$AV/.agents/run-state.yaml"
printf '{"packet":"txn-t1","kind":"start"}\n{"packet":"txn-t1","outcome":"green"}\n' > "$AV/.agents/metrics/outcomes/s.jsonl"
printf -- '- [ ] **T1** Stream large imports\n  - covers: speed\n' > "$AV/gspec/features/x/tasks.md"
cp "$LD/digest" "$AV/.agents/digest"
cat > "$AV/.agents/report.md" <<'EOF'
⏸️ **PAUSED** · Everything wrong · ✅ **1 shipped** · 🔀 **4 decisions**

🔀 **Decisions**

> **1 · Which one?**

✅ **Shipped** 📦

> ✅ `txn-t1` landed

⛔ **Failed** — none
EOF
_snap() { (cd "$AV" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done); }
before="$(_snap)"
out="$(cd "$AV" && "$LINT" --shape B .agents/report.md .agents/digest 2>/dev/null)"; rc=$?
after="$(_snap)"
[ "$rc" = 0 ] && ok 'an all-violations report exits 0' || bad 'an all-violations report exits 0' "rc=$rc"
missing=""
for r in unknown-glyph two-glyphs section-order decision-count untitled-id empty-section; do
  _fires "$r" "$out" || missing="$missing $r"
done
[ -z "$missing" ] && ok 'the all-violations report yields every rule by name' \
  || bad 'the all-violations report yields every rule by name' "missing:$missing"
for f in .agents/run-state.yaml .agents/metrics/outcomes/s.jsonl gspec/features/x/tasks.md; do
  b="$(printf '%s\n' "$before" | grep -F " ./$f")"
  a="$(printf '%s\n' "$after"  | grep -F " ./$f")"
  [ -n "$b" ] && [ "$a" = "$b" ] && ok "the lint left $f byte-identical" \
    || bad "the lint left $f byte-identical" "before=[$b] after=[$a]"
done
[ "$before" = "$after" ] && ok 'the lint wrote nothing: the whole tree is unchanged' \
  || bad 'the lint wrote nothing: the whole tree is unchanged' "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5)"

# --- fail soft: each direction is distinguishable from clean ------------------------------
mkdir -p "$LD/a-dir"
: > "$LD/empty.md"; printf '  \n\n' > "$LD/blank.md"
reasons=""
_soft() { # label, expected reason, args...
  local label="$1" want="$2"; shift 2
  local o r; o="$("$LINT" "$@" 2>/dev/null)"; r=$?
  if [ "$r" = 0 ] && [ "$o" != 'REPORT_LINT=clean' ] \
     && [ "$o" = "$(printf 'REPORT_LINT=unjudged\nREASON=%s' "$want")" ]; then
    ok "fail-soft: $label -> unjudged, REASON=$want, exit 0"
  else
    bad "fail-soft: $label -> unjudged, REASON=$want, exit 0" "rc=$r out=$(printf '%s' "$o" | tr '\n' ' ')"
  fi
  reasons="$reasons $want"
}
_soft 'a missing digest'       digest-missing     --shape B "$LD/b-ok.md" "$LD/no-such-digest"
_soft 'an unreadable digest'   digest-unreadable  --shape B "$LD/b-ok.md" "$LD/a-dir"
_soft 'an unreadable report'   report-unreadable  --shape B "$LD/a-dir" "$LD/digest"
_soft 'a missing report'       report-unreadable  --shape B "$LD/no-such-report" "$LD/digest"
_soft 'an empty report'        report-empty       --shape B "$LD/empty.md" "$LD/digest"
_soft 'a whitespace-only report' report-empty     --shape B "$LD/blank.md" "$LD/digest"
_soft 'no arguments (usage)'   usage
_soft 'an unknown shape'       unknown-shape      --shape A "$LD/b-ok.md" "$LD/digest"
dist="$(printf '%s\n' digest-missing digest-unreadable report-unreadable report-empty | sort -u | wc -l | tr -d ' ')"
[ "$dist" = 4 ] && ok 'the digest and report directions carry distinct reasons' \
  || bad 'the digest and report directions carry distinct reasons' "$dist distinct"

printf '\n----------------------------------------\n'
printf 'report-conventions: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
