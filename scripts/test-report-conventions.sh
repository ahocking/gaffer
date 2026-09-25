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

# A `sed`-range extraction whose END anchor stops matching is the failure a non-empty
# guard cannot see: the range runs on to end of file, and every prose pin below it then
# passes on text from outside the span it claims to read. Measured on this file's own
# extractions: one changed character on an end-anchor line yields an 864-line span with
# every assertion still green. A ceiling well above the live span (a few dozen lines)
# and well below the whole file turns that vacuous pass into a red bar.
SPAN_CEILING=60
under_ceiling() { # label, span -- refuse a span that ran past its end anchor
  local n
  n=$(printf '%s\n' "$2" | wc -l); n="${n//[^0-9]/}"
  if [ "${n:-0}" -le "$SPAN_CEILING" ]; then ok "$1"
  else bad "$1" \
    "span is $n lines, over the $SPAN_CEILING-line ceiling -- the end anchor no longer matches, so the range ran on past the end of the bullet"
  fi
}

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
# output-contract comments must say so. The three rule-prose clauses that branch
# on SOURCE (one under each skill's output block, one in shape C's `▶ Session`
# note) name only `unknown` as the no-value-in-effect case, corrected to this
# enumeration (loop-prose-consistency-gaps T1); the occurrence-count case that
# once froze them naming gaffer-default is retired, and no absence case replaces
# it -- one would pass forever from the moment the removal landed. Extraction is
# anchored on the invocation line, not a line number, so a moved or renamed
# fenced block fails loud rather than silently checking an empty span.
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

printf '\n== the run entry point routes on the checkpoint status, not its existence (loop-entry-routing T1) ==\n'
# §2's first decision used to be a test on `.agents/run-state.yaml` EXISTING, which
# sent a session opening after a completed run into the resume skill -- a skill whose
# decision table has no branch for `done`, and whose every branch assumes work
# remains. The condition now names its redirect set POSITIVELY, so a value outside
# that set falls to the stop below rather than into a resume that cannot resolve it.
#
# Extracted by its own content anchor -- deliberately NOT `_extract_ct_block`, which
# matches a different, fenced span in the same file -- and guarded non-empty before
# anything is scanned over it, as the extractions above are: a range matching nothing
# yields an empty span that satisfies every scan. Reverting the condition to an
# existence test is exactly what empties this range, which is what makes the guard the
# mutation check rather than ceremony. Asserted on what the condition must NAME, never
# on the absence of the removed phrase -- an absence assertion passes forever from the
# moment the removal lands. No assertion here for the unrecognised-status stop: the
# PRD defers that coverage, with the reviewer as its gate.
#
# BOTH anchors must be phrases that sit on ONE wrapped line of the bullet. An end
# anchor spanning a line wrap matches nothing, so the range runs on to the next line
# that does contain it and the span silently swallows the rest of the file -- every
# assertion below then passes on text from outside the bullet. That is the vacuous
# pass the non-empty guard cannot catch: it only sees that the span is non-empty, and
# an overrun span is the least empty thing there is. The ceiling below is what catches
# it -- a span that ran on to end of file is far over it, while the live span sits well
# under, so a dead end anchor turns this section red instead of green on foreign text.
_extract_entry_routing() { # file -> §2's status-routing bullet
  sed -n '/route on its status, not on the file/,/leaves the session unable to edit/p' "$1"
}
routing_bullet="$(_extract_entry_routing "$ROOT/skills/run-loop/SKILL.md")"
[ -n "$routing_bullet" ] && ok 'run-loop entry-routing bullet extracted (anchor holds)' \
  || bad 'run-loop entry-routing bullet extracted (anchor holds)' \
      'empty -- anchor moved, or the condition is back to a test on the file existing'
under_ceiling 'the entry-routing span stays inside its ceiling (end anchor still matches)' \
  "$routing_bullet"

has 'the status is read through the state reader, not parsed by eye' \
  'runstate.sh get .agents/run-state.yaml status' "$routing_bullet"
has 'the redirect set names a clean pause' \
  '`paused`' "$routing_bullet"
has 'the redirect set names a stop on a blocking question' \
  '`blocked`' "$routing_bullet"
has 'the redirect set names a session left mid-flight' \
  '`running`' "$routing_bullet"
has 'the redirect set points at the resume entry point' \
  'skills/resume/SKILL.md' "$routing_bullet"
has 'a completed run is named in the condition' \
  '`done`' "$routing_bullet"
has 'and takes the fresh-run branch in this same section, with no redirect' \
  'fresh-run bullet directly below' "$routing_bullet"

printf '\n== the fresh-run write carries the findings index and nothing else (loop-entry-routing T2) ==\n'
# The `done` branch above routes a session opening over a completed run into §2's
# fresh-run write, so that write now replaces a checkpoint belonging to a DIFFERENT
# run. `runstate.sh write` REPLACES the file, so an index entry the new content omits
# is unlinked -- the finding body stays on disk with nothing pointing at it. The
# clause states the carry-through, and states that nothing else crosses: the run's own
# identity in particular, or `begin-run` would inherit the finished run's directory.
#
# Extracted by its own content anchor and guarded non-empty before anything is scanned
# over it, as the extractions above are: a range matching nothing yields an empty span
# that satisfies every scan. Removing the clause is exactly what empties this range --
# the mutation check, verified by making that removal. Both anchors sit on ONE wrapped
# line of the paragraph; an end anchor spanning a line wrap matches nothing and the
# range runs on to swallow the rest of the file. That is the vacuous pass the non-empty
# guard cannot catch: it only sees that the span is non-empty, and an overrun span is
# the least empty thing there is. The ceiling below is what catches it -- a span that
# ran on to end of file is far over it, while the live span sits well under, so a dead
# end anchor turns this section red instead of green on text from outside the clause.
_extract_fresh_run_write() { # file -> §2's fresh-run findings carry-through clause
  sed -n "/When this write replaces a/,/inheriting the finished run's directory and records/p" "$1"
}
fresh_run_write="$(_extract_fresh_run_write "$ROOT/skills/run-loop/SKILL.md")"
[ -n "$fresh_run_write" ] && ok 'run-loop fresh-run carry-through clause extracted (anchor holds)' \
  || bad 'run-loop fresh-run carry-through clause extracted (anchor holds)' \
      'empty -- anchor moved, or the carry-through clause is gone'
under_ceiling 'the fresh-run span stays inside its ceiling (end anchor still matches)' \
  "$fresh_run_write"

has 'the clause fires on a write that replaces a completed checkpoint' \
  '`done` checkpoint' "$fresh_run_write"
has 'what crosses is the findings index' \
  '`findings:`' "$fresh_run_write"
has 'and it crosses verbatim' \
  'verbatim' "$fresh_run_write"
# Needles stay short enough to sit on ONE wrapped line of the paragraph: `has` is a
# plain substring match over the multi-line span, so a phrase broken by a wrap (and
# its two leading indent spaces) matches nothing and fails a clause that is present.
has 'the write is stated to replace, not edit' \
  'REPLACES' "$fresh_run_write"
has 'so an omitted entry is a loss, not a removal' \
  'unlinked, not edited out' "$fresh_run_write"
has 'the carry happens inside the write, not as a follow-up repair' \
  'add-finding' "$fresh_run_write"
has "the run's own identity is explicitly not carried" \
  'no `run_id` line' "$fresh_run_write"
has 'so the run beginning mints its own id rather than inheriting one' \
  'begin-run' "$fresh_run_write"

# The clause says WHERE the index is read from, not only what crosses (loop-entry-
# routing-gaps T1). At this point the driver holds only the checkpoint's status, so
# "carry it verbatim" is satisfied equally by the file's own lines and by the one
# subcommand named `findings` -- which prints a projection that STRIPS the single-
# quoting the durable-state writer applies (ADR 0027, probed: a summary stored as
# `'x: y'` prints bare). Re-emitting that as index lines re-opens the `": "`
# corruption in the one file whose parse failure is unrecoverable, so the source is
# pinned from both ends: the file and block that ARE the source, and the projection
# that is not. Each needle sits on ONE wrapped line of the paragraph for the reason
# the note above gives; the refusal is pinned on a phrase distinctive to its own
# sentence (a positive substring match cannot see a negation, so the phrase has to
# be one that only the refusal carries).
has 'the source is the checkpoint file itself' \
  '.agents/run-state.yaml' "$fresh_run_write"
has 'read from disk and copied line-for-line, so the quoting survives' \
  'line-for-line into the new content' "$fresh_run_write"
has 'and the durable-state projection is refused as a source' \
  '`runstate.sh findings` is not a source' "$fresh_run_write"

printf '\n== the packet-close write enumerates every key it must carry, not just two (loop-driver-run-gaps T4) ==\n'
# §3.6's close used to name `status: running` and the `findings:` index as what
# survives the whole-file `write`, and nothing else -- while §2's fresh-run write
# deliberately omits `run_id`, which made the silence read as intended rather than
# incomplete. A driver following §3.6 literally dropped `run_id` and the `driver_*`
# claim on a real run (`20260919T224810-6fc6`, packet 1, repaired by hand): nothing
# fails at the write, then `run-digest` refuses for the rest of the run and the next
# `begin-run` mints a second id over a second run directory. So the clause now
# ENUMERATES, and this section asserts every name in that enumeration is present --
# a partial list is the whole defect, and a list missing one key looks exactly like a
# complete one to a reader who does not already know the set.
#
# The needle list is the set of column-0 keys `templates/run-state.yaml` documents,
# split by who produces them: the carried ones are asserted as carried, and the three
# the close itself writes plus the writer's own stamp are asserted as named in their
# own role -- otherwise a clause could satisfy every needle by listing all thirteen
# keys as carry-through, which would tell the driver to preserve the very fields the
# close exists to update.
#
# Extracted by its own content anchor and guarded non-empty before anything is scanned
# over it, as the extractions above are: a range matching nothing yields an empty span
# that satisfies every scan, and reverting the clause to its two-key form is exactly
# what empties this range -- the mutation check, verified by making that reversion.
# Both anchors sit on ONE wrapped line of the clause; an end anchor spanning a line
# wrap matches nothing and the range runs on to swallow the rest of the file. That is
# the vacuous pass the non-empty guard cannot catch: it only sees that the span is
# non-empty, and an overrun span is the least empty thing there is. The ceiling below
# is what catches it, and the margin is measured, not assumed: the live span is 36
# lines, while a span run on to end of file is 396.
_extract_close_carry() { # file -> §3.6's packet-close carry-through clause
  sed -n '/every column-0 key below survives only/,/never a key you carry/p' "$1"
}
close_carry="$(_extract_close_carry "$ROOT/skills/run-loop/SKILL.md")"
[ -n "$close_carry" ] && ok 'run-loop §3.6 packet-close carry clause extracted (anchor holds)' \
  || bad 'run-loop §3.6 packet-close carry clause extracted (anchor holds)' \
      'empty -- anchor moved, or the clause is back to naming only status and findings'
under_ceiling 'the packet-close span stays inside its ceiling (end anchor still matches)' \
  "$close_carry"

# Needles stay short enough to sit on ONE wrapped line of the clause: `has` is a plain
# substring match over the multi-line span, so a phrase broken by a wrap matches nothing
# and fails a clause that is present. No pipe into the loop -- a `while read` on the
# right of one runs in a subshell and every ok/bad it counted would be discarded.
while IFS='|' read -r cc_label cc_needle; do
  [ -n "$cc_label" ] || continue
  has "run-loop §3.6 carries: $cc_label" "$cc_needle" "$close_carry"
done <<'CLOSE_CARRY_NEEDLES'
the schema line|- `schema`
the run's own identity|- `run_id`
the feature branch|- `branch`
the driver claim's host|`driver_host`
its since/heartbeat stamps, and the pid when one was recorded|`driver_since`, `driver_heartbeat`, and `driver_pid`
the crash signal, by value|`status: running`
the questions awaiting the operator|`pending_questions`
the findings index|the `findings:` block
CLOSE_CARRY_NEEDLES

has 'the write is stated to replace, so a dropped key is a loss' \
  'REPLACES' "$close_carry"
has 'and an omitted findings entry is named as unlinked, not edited out' \
  'unlinked, not edited out' "$close_carry"
has 'losing the id is tied to the refusal it causes' \
  'run-state has no run_id' "$close_carry"
has 'and to the second run directory the next begin-run would mint' \
  'creates a second run directory' "$close_carry"

# The same source rule the fresh-run clause carries, at the write where the file being
# replaced belongs to THIS run: read from disk, copied, and never re-emitted from the
# projection that strips the durable writer's quoting (ADR 0027).
has 'the source is the checkpoint file itself' \
  '.agents/run-state.yaml' "$close_carry"
has 'copied line-for-line, so the quoting survives' \
  'copied line-for-line' "$close_carry"
has 'and the durable-state projection is refused as a source here too' \
  '`runstate.sh findings` is not a source' "$close_carry"

# The close's OWN output is named as such, so the enumeration cannot be satisfied by
# listing every key as carry-through.
has "the close's own output names the green SHA" \
  '`last_green_commit`' "$close_carry"
has 'and the cursor/pending block it advances' \
  '`backlog` (the `cursor` and `pending` above)' "$close_carry"
has 'and the one-line note it overwrites' \
  '`note` (below)' "$close_carry"
has "and updated_at is the writer's own stamp, not a carried key" \
  "is the writer's own stamp" "$close_carry"

printf '\n== the status-line refusal rule is stated in the same words on both driver surfaces (loop-driver-run-gaps T3) ==\n'
# `runstate.sh check-status` (T1) and the refusals `route`/`write-result` run through it
# (T2) are mechanism; what the driver DOES with a refusal is prose, and it lives on two
# surfaces a session reads at different moments -- `skills/run-loop/SKILL.md` §3.4 when
# it runs the loop, `agents/loop-driver.md` when it takes the role. Stating the rule in
# one and paraphrasing it in the other is the failure this section exists to catch: a
# paraphrase is where "re-dispatch once" quietly becomes "re-dispatch until it parses",
# and where "never substitute a line of its own" is dropped as obvious -- which is the
# one repair that looks free and reports on work the driver did not do.
#
# So the SAME needle list is asserted over BOTH spans. A clause reworded on one surface
# fails there while passing on the other, naming which file drifted.
#
# Extracted by content anchors and guarded non-empty before anything is scanned over it,
# as the extractions above are: a range matching nothing yields an empty span that
# satisfies every scan, and deleting the clause is exactly what empties this range --
# the mutation check, verified by making that deletion. Both anchors sit on ONE wrapped
# line of the clause in both files; an end anchor spanning a line wrap matches nothing
# and the range runs on to swallow the rest of the file. That is the vacuous pass the
# non-empty guard cannot catch: it only sees that the span is non-empty, and an overrun
# span is the least empty thing there is. The ceiling below is what catches it, and the
# margin is measured, not assumed: the live span is 17 lines in each file, while a span
# run on to end of file is 579 in the skill and 103 in the agent. Measured with the end
# anchor broken by one word, all eight needles below still passed on the skill's 579-line
# span -- the ceiling was the only assertion that turned red.
_extract_refusal_rule() { # file -> the check-status refusal clause
  sed -n '/Check every status line before you act on it/,/well-formed line that is wrong/p' "$1"
}
refusal_skill="$(_extract_refusal_rule "$ROOT/skills/run-loop/SKILL.md")"
refusal_agent="$(_extract_refusal_rule "$ROOT/agents/loop-driver.md")"
[ -n "$refusal_skill" ] && ok 'run-loop §3.4 refusal clause extracted (anchor holds)' \
  || bad 'run-loop §3.4 refusal clause extracted (anchor holds)' \
      'empty -- anchor moved, or the refusal rule is gone from the routing step'
[ -n "$refusal_agent" ] && ok 'loop-driver Routing refusal clause extracted (anchor holds)' \
  || bad 'loop-driver Routing refusal clause extracted (anchor holds)' \
      'empty -- anchor moved, or the refusal rule is gone from the Routing section'
under_ceiling 'the run-loop §3.4 span stays inside its ceiling (end anchor still matches)' \
  "$refusal_skill"
under_ceiling 'the loop-driver Routing span stays inside its ceiling (end anchor still matches)' \
  "$refusal_agent"

# Needles stay short enough to sit on ONE wrapped line in BOTH files: `has` is a plain
# substring match over the multi-line span, so a phrase broken by a wrap matches nothing
# and fails a clause that is present. The two files wrap at different widths (the skill's
# clause is indented inside a numbered step), which is exactly why the list is short
# phrases rather than whole sentences. No pipe into the loop -- a `while read` on the
# right of one runs in a subshell and every ok/bad it counted would be discarded.
while IFS='|' read -r rr_label rr_needle; do
  [ -n "$rr_label" ] || continue
  has "run-loop §3.4: $rr_label"        "$rr_needle" "$refusal_skill"
  has "loop-driver Routing: $rr_label"  "$rr_needle" "$refusal_agent"
done <<'REFUSAL_NEEDLES'
the check is the named subcommand, not a judgement of the driver's own|check-status --status
it runs on every line read, including one nothing routes on|on **every** status line you read
the re-dispatch is limited to once|the same agent **once**
and carries the printed reason and nothing else|passing the printed reason and nothing else
second refusal, unrouted line: on to the reviewer dispatch as today|proceeds to the reviewer dispatch
second refusal, routed line: escalated to the operator|escalated as a blocking question
the routed set includes the implementer's own line (implementer-continuation T7)|and the implementer's own line,
and that line is never handed on to the reviewer instead|never passed to the reviewer,
the driver never substitutes a line of its own|never substitutes a line of its own
and the reviewer stays the content gate|reviewer's content gate is unchanged
REFUSAL_NEEDLES

printf '\n== the continuation contract reads the same on both driver surfaces (implementer-continuation T7) ==\n'
# `route` grew a ninth token, `continue`, but a token the driver is never told to
# produce is a token nothing ever routes on. Two surfaces have to state it -- the skill
# the operator invokes (`skills/run-loop/SKILL.md` §3 steps 4-5) and the agent file the
# driver is dispatched with (`agents/loop-driver.md` §Routing) -- and, as with the
# refusal clause above, stating it on one and paraphrasing it on the other is the
# failure this section exists to catch.
#
# Four clauses in it are each the whole point, and each is a needle below:
#
#   - the implementer's line is read and `check-status`ed BEFORE any reviewer dispatch.
#     Read after the reviewer has already been dispatched, a `continue` arrives with a
#     verdict beside it on work that was never finished.
#   - the three-step order on `ACTION=continue`: `record-start --continue`, then
#     `refresh-handoff`, then the dispatch. `refresh-handoff` is what puts the partial
#     work into the handoff, so a driver that dispatches first briefs the continuation
#     with the handoff the FIRST dispatch got -- no partial-work block -- and the fresh
#     implementer starts the packet over, which is the one failure the whole feature
#     exists to prevent. Asserted twice over: the clause states the order, and the three
#     calls physically appear in that order within the span.
#   - no review path, no reviewer, no verdict. A continuation is not an attempt and has
#     no review to answer; dispatching the reviewer on one records a verdict against
#     half-finished work.
#   - `refresh-handoff` runs before EVERY `attempt` re-dispatch too, not only before a
#     continuation -- a fix/retry re-dispatch is briefed from the same partial work.
#
# The widened twice-refused rule (the implementer's line joins the routed set) is pinned
# in the refusal-clause needles above, where that rule is written, rather than restated
# here.
#
# Extracted by content anchors and guarded non-empty before anything is scanned over it,
# as the extractions above are: a range matching nothing yields an empty span that
# satisfies every scan, and deleting the clause is exactly what empties this range.
# Both anchors of both ranges sit on ONE wrapped line in BOTH files; an end anchor
# spanning a line wrap matches nothing and the range runs on to swallow the rest of the
# file. That is the vacuous pass the non-empty guard cannot catch: it only sees that the
# span is non-empty, and an overrun span is the least empty thing there is. The ceiling
# is what catches it, and the margin is measured, not assumed: the live spans are 7 and
# 26 lines in the skill and 6 and 26 in the agent, while the same ranges with one
# character changed on the end anchor run to 730/706 lines in the skill and 206/189 in
# the agent.
#
# The needles are asserted over the two spans CONCATENATED, per file: the branch sits in
# the dispatch step and the `continue` arm in the routing step, with unrelated prose
# between them, so two tight ranges beat one wide one that the ceiling could not police.
_extract_cont_branch() { # file -> the "read the implementer's line first" branch
  sed -n '/before any reviewer dispatch/,/reviewer exactly as today/p' "$1"
}
_extract_cont_arm() { # file -> the attempt-refresh + ACTION=continue arms
  sed -n '/refresh the handoff first, then re-dispatch/,/no verdict is recorded for it/p' "$1"
}
cont_branch_skill="$(_extract_cont_branch "$ROOT/skills/run-loop/SKILL.md")"
cont_arm_skill="$(_extract_cont_arm "$ROOT/skills/run-loop/SKILL.md")"
cont_branch_agent="$(_extract_cont_branch "$ROOT/agents/loop-driver.md")"
cont_arm_agent="$(_extract_cont_arm "$ROOT/agents/loop-driver.md")"

[ -n "$cont_branch_skill" ] && ok 'run-loop §3.4 continuation branch extracted (anchor holds)' \
  || bad 'run-loop §3.4 continuation branch extracted (anchor holds)' \
      'empty -- anchor moved, or the implementer-line branch is gone from the dispatch step'
[ -n "$cont_arm_skill" ] && ok 'run-loop §3.5 continue arm extracted (anchor holds)' \
  || bad 'run-loop §3.5 continue arm extracted (anchor holds)' \
      'empty -- anchor moved, or the continue arm is gone from the routing step'
[ -n "$cont_branch_agent" ] && ok 'loop-driver Routing continuation branch extracted (anchor holds)' \
  || bad 'loop-driver Routing continuation branch extracted (anchor holds)' \
      'empty -- anchor moved, or the implementer-line branch is gone from the Routing section'
[ -n "$cont_arm_agent" ] && ok 'loop-driver ACTION=continue arm extracted (anchor holds)' \
  || bad 'loop-driver ACTION=continue arm extracted (anchor holds)' \
      'empty -- anchor moved, or the ACTION=continue arm is gone from the Routing section'

under_ceiling 'the run-loop §3.4 continuation-branch span stays inside its ceiling' "$cont_branch_skill"
under_ceiling 'the run-loop §3.5 continue-arm span stays inside its ceiling'        "$cont_arm_skill"
under_ceiling 'the loop-driver continuation-branch span stays inside its ceiling'   "$cont_branch_agent"
under_ceiling 'the loop-driver ACTION=continue span stays inside its ceiling'       "$cont_arm_agent"

cont_skill="$cont_branch_skill
$cont_arm_skill"
cont_agent="$cont_branch_agent
$cont_arm_agent"

# Needles stay short enough to sit on ONE wrapped line in BOTH files: `has` is a plain
# substring match over the multi-line span, so a phrase broken by a wrap matches nothing
# and fails a clause that is present. No pipe into the loop -- a `while read` on the
# right of one runs in a subshell and every ok/bad it counted would be discarded.
while IFS='|' read -r ct_label ct_needle; do
  [ -n "$ct_label" ] || continue
  has "run-loop §3 steps 4-5: $ct_label"   "$ct_needle" "$cont_skill"
  has "loop-driver Routing: $ct_label"     "$ct_needle" "$cont_agent"
done <<'CONTINUE_NEEDLES'
the implementer's line is read before any reviewer is dispatched|before any reviewer dispatch
and the branch is on that line's first token|branch on its first token
a continue goes to route with the line itself as --status|with that same line as `--status`
any other first token proceeds to the reviewer unchanged|reviewer exactly as today
step 1: a continuation record per member|record-start "$MEMBERS" --continue
step 2: the handoff is refreshed in place|`runstate.sh refresh-handoff <run-state-from-handoff-header>
step 3: a fresh implementer is dispatched|resolve implementer
with no review path, because there is no review to answer|and no review path
the order rules out dispatching before the handoff is refreshed|dispatching before `refresh-handoff` runs
a fix/retry re-dispatch is refreshed too|before **every** `attempt`
no reviewer is dispatched and no verdict recorded|no verdict is recorded for it
CONTINUE_NEEDLES

# The stated order above is prose; this is the same rule read off the span's own
# structure, so a clause that says "in this order" while listing the dispatch above
# `refresh-handoff` fails here even with every needle green. Line numbers are taken
# WITHIN the span -- `record-start "$MEMBERS" --continue` also appears in §3.2's resume
# prose, far above, and a whole-file grep would read that one.
_cont_order() { # label, span
  local sp="$2" l_rec l_ref l_disp
  l_rec="$(printf '%s\n' "$sp"  | grep -n 'record-start "\$MEMBERS" --continue' | head -1 | cut -d: -f1)"
  l_ref="$(printf '%s\n' "$sp"  | grep -n '`runstate.sh refresh-handoff <run-state-from-handoff-header>' | head -1 | cut -d: -f1)"
  l_disp="$(printf '%s\n' "$sp" | grep -n 'resolve implementer' | head -1 | cut -d: -f1)"
  if [ -n "$l_rec" ] && [ -n "$l_ref" ] && [ -n "$l_disp" ] \
     && [ "$l_rec" -lt "$l_ref" ] && [ "$l_ref" -lt "$l_disp" ]; then
    ok "$1"
  else
    bad "$1" \
      "record-start=${l_rec:-none}, refresh-handoff=${l_ref:-none}, dispatch=${l_disp:-none} -- expected that order; a dispatch above refresh-handoff briefs the continuation without the partial work"
  fi
}
_cont_order 'run-loop §3.5: record-start, then refresh-handoff, then the dispatch' "$cont_arm_skill"
_cont_order 'loop-driver: record-start, then refresh-handoff, then the dispatch'   "$cont_arm_agent"

printf '\n== the whole-branch review survives its routing step, and its notes become findings ==\n'
# The end-of-run ADR 0026 routing step is RETIRED (ADR 0026 amendment 2026-09-22): §4
# no longer dispatches an architect over the review file, and writes no
# `end-of-run-review` routing record. Arm 1 needed an incomplete feature with an
# unchecked task AND an unchecked capability, and by §4 every task and capability of
# the feature just finished is already checked (§3.6 flips them at each land) -- so
# arm 1 was structurally unreachable there and arm 2 could only ever propose.
#
# Two failure modes, and this section pins against both. (1) The subtraction takes
# the REVIEW with it: §4 stops reviewing the branch at all, and nothing notices
# because the routing prose it was tangled with is gone. (2) The note goes nowhere:
# the driver relays a line and the note dies with the run directory, which
# `begin-run` prunes after two runs, leaving the findings index -- the only thing
# §2's fresh-run write carries forward -- with no record of it.
#
# So: the reviewer dispatch and its bounded diff must still be there, the reviewer's
# own line must be relayed with the review file's path (the driver never opens that
# file -- that rule is now absolute, with no exception to explain), and each note the
# line reports must become one `add-finding` entry with mandatory `--packets`.
#
# Extracted by its own content anchor and guarded non-empty before anything is
# scanned over it, as the extractions above are: a range matching nothing yields an
# empty span that satisfies every scan, and deleting the clause is exactly what
# empties this range. Both anchors sit on ONE wrapped line; an end anchor spanning a
# line wrap matches nothing and the range runs on to swallow the rest of the file --
# the vacuous pass the non-empty guard cannot catch, which the ceiling is for.
_extract_review_record() { # file -> §4's relay-and-record clause
  sed -n '/You do not open that review file/,/no call, no finding, and no figure changes/p' "$1"
}
rev_record="$(_extract_review_record "$ROOT/skills/run-loop/SKILL.md")"
[ -n "$rev_record" ] && ok 'run-loop §4 relay-and-record clause extracted (anchor holds)' \
  || bad 'run-loop §4 relay-and-record clause extracted (anchor holds)' \
      'empty -- anchor moved, or the review notes are again recorded nowhere'
under_ceiling 'the relay-and-record span stays inside its ceiling (end anchor still matches)' \
  "$rev_record"

# Needles stay short enough to sit on ONE wrapped line of the clause: `has` is a
# plain substring match over the multi-line span, so a phrase broken by a wrap
# matches nothing and fails a clause that is present. No pipe into the loop -- a
# `while read` on the right of one runs in a subshell and every ok/bad it counted
# would be discarded.
while IFS='|' read -r rv_label rv_needle; do
  [ -n "$rv_label" ] || continue
  has "run-loop §4 relay-and-record: $rv_label" "$rv_needle" "$rev_record"
done <<'REVIEW_RECORD_NEEDLES'
the driver still never opens the review file|never open a result file
the reviewer's own line is what the stop report carries|relay **that line**, verbatim
and the review file's path is named for the operator|review file's path beside it
one finding per note the line reports|Record one finding per note that status line reports
through the existing subcommand, with the mandatory packets flag|runstate.sh add-finding .agents/run-state.yaml <id> '<summary>' --packets
the flag is stated to be mandatory|`--packets` is mandatory
the summary comes from the line, never from an unread file|never a finding you invent
expiry is the existing rule, with nothing new added|expiry stays the positive-evidence rule
a review with no notes records nothing|reports no notes records nothing at
the retired step is named as retired|retired (ADR 0026 amendment 2026-09-22)
and nothing here writes into the spec record|appends a task, or
REVIEW_RECORD_NEEDLES

# The review itself is the half that must NOT have been subtracted, and it lives
# above the clause extracted here -- so it is read off §4 as a whole.
_extract_s4() { # file -> everything from the §4 heading to the end of the skill
  sed -n '/^## 4\. Termination/,$p' "$1"
}
s4="$(_extract_s4 "$ROOT/skills/run-loop/SKILL.md")"
[ -n "$s4" ] && ok 'run-loop §4 extracted (heading holds)' \
  || bad 'run-loop §4 extracted (heading holds)' 'empty -- the §4 heading moved'
while IFS='|' read -r s4_label s4_needle; do
  [ -n "$s4_label" ] || continue
  has "run-loop §4 still reviews the branch: $s4_label" "$s4_needle" "$s4"
done <<'S4_REVIEW_NEEDLES'
the reviewer's model is resolved at the dispatch site|routing.sh resolve reviewer
one broad whole-branch review is dispatched|**one broad whole-branch review** (the `reviewer`)
over this run's own work, not the whole branch|not everything the branch has accumulated since its
the review writes through the read-only agent's one write|through `write-result` to that path
and returns one status line|returns one
S4_REVIEW_NEEDLES

# The retired step, read as an ABSENCE over the same span. Scoped to §4 on purpose:
# `arm-1 append-task` is still the escalation decider's own mid-run mechanism and is
# named in §3.5, so a file-wide absence check would fail on live prose.
while IFS='|' read -r s4x_label s4x_needle; do
  [ -n "$s4x_label" ] || continue
  case "$s4" in
    *"$s4x_needle"*) bad "run-loop §4 no longer routes by ADR 0026's arms: $s4x_label" \
                       "still present: $s4x_needle" ;;
    *) ok "run-loop §4 no longer routes by ADR 0026's arms: $s4x_label" ;;
  esac
done <<'S4_ABSENT_NEEDLES'
no architect is dispatched at termination|routing.sh resolve architect
no routing record under the fixed termination id|end-of-run-review
no arm-1 routing|arm 1
no arm-2 routing|arm 2
no hyphenated arm-2 routing|arm-2
S4_ABSENT_NEEDLES

# The other two sites that carried a duty for the retired step.
case "$(cat "$ROOT/agents/architect.md")" in
  *'backlog termination'*) bad 'architect.md carries no termination-routing duty' \
                             'still dispatched at backlog termination to route findings' ;;
  *) ok 'architect.md carries no termination-routing duty' ;;
esac
blob_ld="$(_squeeze "$ROOT/agents/loop-driver.md")"
case "$blob_ld" in
  *'you dispatch the `architect` with that review file'*)
    bad 'loop-driver.md: never-open-a-result-file has no termination exception' \
      'still explains the rule by dispatching the architect over the review file' ;;
  *) ok 'loop-driver.md: never-open-a-result-file has no termination exception' ;;
esac
case "$blob_ld" in
  *'record one finding per note that line reports'*)
    ok 'loop-driver.md: the termination review is relayed and its notes recorded' ;;
  *) bad 'loop-driver.md: the termination review is relayed and its notes recorded' \
      'expected the per-note finding rule beside the never-open rule' ;;
esac

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

printf '\n== shape B tally sentence names exactly the figures run-tally emits (report-render-conformance T3) ==\n'
# Shape B reads its digest-derived figures from `runstate.sh run-tally` rather than
# counting the digest itself, so the two sides are one contract: a figure the sentence
# names and the core does not emit is a number the renderer has to invent, and a figure
# the core emits and the sentence does not name is a count nobody renders. Both
# directions are asserted. The sentence side is the backticked all-caps keys inside the
# same anchor range the enum case above uses; the core side is the key of each KEY=value
# line run-tally prints over a minimal synthetic run (a run-state with a run_id and
# nothing else -- the keys do not depend on the counts). Both sets are guarded
# non-empty, so a moved anchor or a dead subcommand fails here instead of comparing two
# empty sets and passing.
tally_sentence="$(sed -n '/The tally counts `packet` lines by outcome/,/rather than guessing a number/p' "$SHAPES")"
RT="$TMP/run-tally"; mkdir -p "$RT/.agents"; git -C "$RT" init -q
printf 'schema: 3\nstatus: paused\nrun_id: 20260101T000000-0001\n' > "$RT/.agents/run-state.yaml"
rt_out="$(cd "$RT" && "$ROOT/scripts/runstate.sh" run-tally .agents/run-state.yaml 2>&1)"; rt_rc=$?
shape_keys="$(printf '%s\n' "$tally_sentence" | grep -o '`[A-Z][A-Z_]*`' | tr -d '`' | LC_ALL=C sort -u)"
core_keys="$(printf '%s\n' "$rt_out" | sed -n 's/^\([A-Z][A-Z_]*\)=.*/\1/p' | LC_ALL=C sort -u)"
[ -n "$tally_sentence" ] && ok "shape B's tally sentence anchor range is found" \
  || bad "shape B's tally sentence anchor range is found" 'anchor moved or renamed -- the range is empty'
[ -n "$shape_keys" ] && ok "shape B's tally sentence names at least one run-tally figure" \
  || bad "shape B's tally sentence names at least one run-tally figure" 'no backticked KEY found in the range'
[ "$rt_rc" = 0 ] && [ -n "$core_keys" ] && ok 'run-tally over a minimal synthetic run emits figure keys' \
  || bad 'run-tally over a minimal synthetic run emits figure keys' "rc=$rt_rc out=$rt_out"
only_shape="$(LC_ALL=C comm -23 <(printf '%s\n' "$shape_keys") <(printf '%s\n' "$core_keys") | tr '\n' ' ')"
only_core="$(LC_ALL=C comm -13 <(printf '%s\n' "$shape_keys") <(printf '%s\n' "$core_keys") | tr '\n' ' ')"
[ -z "$only_shape" ] && ok 'every figure the tally sentence names is one run-tally emits' \
  || bad 'every figure the tally sentence names is one run-tally emits' "named but not emitted: $only_shape"
[ -z "$only_core" ] && ok 'every figure run-tally emits is named by the tally sentence' \
  || bad 'every figure run-tally emits is named by the tally sentence' "emitted but not named: $only_core"

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

printf '\n== shape B worked example section order matches the conventions fixed tally order (loop-prose-consistency-gaps T2) ==\n'
# The worked example is the half an agent copies, so it is pinned by the same
# authority as the shape: compared to the order DERIVED from $CONV's fixed-tally line
# above, never to shape B's own body -- a shape and an example that drift together
# still fail. The conventions omit zero buckets and the example renders no ⛔ section,
# so the expected order is restricted to the sections the example renders; what is
# asserted is their relative order.
# Anchored on the example's comment-prefixed lines (`#   ⏸️ **PAUSED**` ...
# `#   ▶ **Next**`), which no other text in the file carries.
BODY_B_EX="$(sed -n '/^#   ⏸️ \*\*PAUSED\*\*/,/^#   ▶ \*\*Next\*\*/p' "$SHAPES")"
if [ -n "$BODY_B_EX" ]; then
  ok 'shape B worked-example block extracted (anchor holds)'
  under_ceiling 'shape B worked-example block ends at its ▶ Next anchor' "$BODY_B_EX"

  EX_ACTUAL_ORDER=""
  while IFS=$'\t' read -r _ g; do
    EX_ACTUAL_ORDER="$EX_ACTUAL_ORDER $g"
  done < <(
    for g in $CANDIDATE_GLYPHS; do
      heading="#   $(_heading_text "$g")"
      ln="$(printf '%s\n' "$BODY_B_EX" | grep -n -F -- "$heading" | head -1 | cut -d: -f1)"
      [ -n "$ln" ] && printf '%s\t%s\n' "$ln" "$g"
    done | sort -n
  )
  EX_ACTUAL_ORDER="${EX_ACTUAL_ORDER# }"

  # The authority's order, restricted to the glyphs whose section the example renders.
  EX_EXPECTED_ORDER=""
  for g in $EXPECTED_ORDER; do
    case " $EX_ACTUAL_ORDER " in *" $g "*) EX_EXPECTED_ORDER="$EX_EXPECTED_ORDER $g" ;; esac
  done
  EX_EXPECTED_ORDER="${EX_EXPECTED_ORDER# }"

  [ -n "$EX_ACTUAL_ORDER" ] && ok "a section order was derived from the worked example's headings" \
    || bad "a section order was derived from the worked example's headings" 'derived nothing -- no section heading found in the extracted block'

  if [ -n "$EXPECTED_ORDER" ] && [ -n "$EX_ACTUAL_ORDER" ] && [ "$EX_ACTUAL_ORDER" = "$EX_EXPECTED_ORDER" ]; then
    ok "shape B's worked example section headings appear in the conventions' fixed tally order ($EX_ACTUAL_ORDER)"
  else
    bad "shape B's worked example section headings appear in the conventions' fixed tally order" \
        "expected: $EX_EXPECTED_ORDER -- got: $EX_ACTUAL_ORDER"
  fi
else
  bad 'shape B worked-example block extracted (anchor holds)' 'empty -- anchor moved or renamed'
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

# A conforming shape C: phase lines, `▶ Session`/`▶ Stops at` headings, and a
# `Will need you` section whose "nothing expected" value is real information.
cat > "$LD/c-ok.md" <<'EOF'
▶ **STARTING** · Transaction import: make it survive real bank files · ⬚ **5 packets** · 2 phases

> **Phase 1 — speed** · ⬚ Stream large imports · ⬚ Paginate the list · ⬚ Cache totals
> **Phase 2 — correctness** · ⬚ Duplicate detection · ⬚ Import audit log

⚠️ **Assuming** — every bank in the sample set sends a stable per-transaction id.

🔀 **Will need you** — none

> **Won't touch:** the transactions table schema, so no migration.

▶ **Session** claude-opus-5[1m] · effort unknown

▶ **Stops at** `orch/txn-import` ready for review
EOF

out="$(_lint B "$LD/b-ok.md" "$LD/digest")"
[ "$out" = 'REPORT_LINT=clean' ] && ok 'a conforming shape B (tally line, ▶ Next, branch+sha state line) is clean' \
  || bad 'a conforming shape B (tally line, ▶ Next, branch+sha state line) is clean' "$out"
out="$(_lint C "$LD/c-ok.md" "$LD/digest-empty")"
[ "$out" = 'REPORT_LINT=clean' ] && ok 'a conforming kickoff with an EMPTY digest is judged, and clean (phase lines, ▶ Session/Stops at, Will need you)' \
  || bad 'a conforming kickoff with an EMPTY digest is judged, and clean' "$out"
out="$(_lint C "$LD/c-ok.md" "$LD/digest")"
[ "$out" = 'REPORT_LINT=clean' ] && ok 'the same kickoff against a populated digest is clean too' \
  || bad 'the same kickoff against a populated digest is clean too' "$out"

# retire-autonomy-levels T4: the kickoff no longer states an autonomy level, so its
# final line is `▶ **Stops at** …` alone. The ▶-heading exemption is generic over the
# heading's words, and these two pin that from both ends — a rendered kickoff carrying
# no autonomy segment lints clean, and the shipped shape does not grow the line back.
cat > "$LD/c-no-autonomy.md" <<'EOF'
▶ **STARTING** · Transaction import: make it survive real bank files · ⬚ **5 packets** · 2 phases

> **Phase 1 — speed** · ⬚ Stream large imports · ⬚ Paginate the list · ⬚ Cache totals

⚠️ **Assuming** — every bank in the sample set sends a stable per-transaction id.

🔀 **Will need you** — none

▶ **Session** claude-opus-5[1m] · effort unknown

▶ **Stops at** `orch/txn-import` ready for review
EOF
out="$(_lint C "$LD/c-no-autonomy.md" "$LD/digest-empty")"
[ "$out" = 'REPORT_LINT=clean' ] && ok 'a kickoff whose last line is ▶ Stops at, with no autonomy segment before it, is clean' \
  || bad 'a kickoff whose last line is ▶ Stops at, with no autonomy segment before it, is clean' "$out"
case "$(cat "$ROOT/templates/report-templates.md")" in
  *'**Autonomy**'*) bad "shape C's kickoff ships no ▶ Autonomy line" 'templates/report-templates.md still renders an autonomy segment';;
  *'▶ **Stops at** <branch ready for review'*) ok "shape C's kickoff ships no ▶ Autonomy line — ▶ Stops at is that line's whole content";;
  *) bad "shape C's kickoff ships no ▶ Autonomy line" 'no ▶ Stops at line found in templates/report-templates.md';;
esac

# The kickoff's two optional routing lines (per-agent-model-routing T4): the
# `⚠️ Routing config` line after `⚠️ Assuming`, and the `▶ Routing` line after
# `▶ Session`, rendered from `routing.sh validate`/`table`. Both are conformant.
cat > "$LD/c-routing.md" <<'EOF'
▶ **STARTING** · Transaction import: make it survive real bank files · ⬚ **5 packets** · 2 phases

> **Phase 1 — speed** · ⬚ Stream large imports · ⬚ Paginate the list · ⬚ Cache totals
> **Phase 2 — correctness** · ⬚ Duplicate detection · ⬚ Import audit log

⚠️ **Assuming** — every bank in the sample set sends a stable per-transaction id.

⚠️ **Routing config** — 1 entry ignored: loop-driver (loop-driver)

🔀 **Will need you** — none

> **Won't touch:** the transactions table schema, so no migration.

▶ **Session** claude-opus-5[1m] · effort unknown

▶ **Routing** implementer sonnet → opus · researcher sonnet → haiku

▶ **Stops at** `orch/txn-import` ready for review
EOF
out="$(_lint C "$LD/c-routing.md" "$LD/digest-empty")"
[ "$out" = 'REPORT_LINT=clean' ] && ok 'a kickoff carrying ⚠️ Routing config and ▶ Routing is clean against an EMPTY digest' \
  || bad 'a kickoff carrying ⚠️ Routing config and ▶ Routing is clean against an EMPTY digest' "$out"
out="$(_lint C "$LD/c-routing.md" "$LD/digest")"
[ "$out" = 'REPORT_LINT=clean' ] && ok 'the same routing kickoff is clean against a populated digest' \
  || bad 'the same routing kickoff is clean against a populated digest' "$out"
# Control: the `▶ Routing` line is a one-glyph line like any other; a second glyph fires.
sed 's/^▶ \*\*Routing\*\* implementer/▶ ✅ **Routing** implementer/' "$LD/c-routing.md" > "$LD/v-routing-two.md"
fires 'two-glyphs: a ▶ Routing line carrying a second glyph is named' two-glyphs "$(_lint C "$LD/v-routing-two.md" "$LD/digest-empty")"

# session-effort-reporting T2: the kickoff's `▶ Session` line says every dispatched
# agent inherits the session's effort, as far as its model accepts one, and an
# optional `⚠️ Effort override` line follows `⚠️ Routing config` when
# `runstate.sh session-effort` printed `EFFORT_ENV=set`. The template is pinned from
# its literal lines (not the prose, which names the same words), and rendered
# kickoffs carrying each form lint clean against an empty and a populated digest.
SE_INHERIT='inherited by every dispatched agent as far as its model accepts one'
se_line="$(grep '^▶ \*\*Session\*\* <model>' "$ROOT/templates/report-templates.md")"
case "$se_line" in
  *"effort <effort>, $SE_INHERIT"*) ok "shape C's ▶ Session line says every dispatched agent inherits the session's effort" ;;
  *) bad "shape C's ▶ Session line says every dispatched agent inherits the session's effort" "got: [$se_line]" ;;
esac
se_rule_raw="$(sed -n '/^# - \*\*`▶ Session` states model and effort/,/^# - /p' "$ROOT/templates/report-templates.md")"
under_ceiling "the ▶ Session rule span stops at its end anchor" "$se_rule_raw"
se_rule="$(printf '%s\n' "$se_rule_raw" | sed 's/^# *//' | tr '\n' ' ' | tr -s ' ')"
has "shape C's Session rule keeps the words 'effort unknown' for unknown, with the inheritance clause" \
  "*effort unknown, $SE_INHERIT*" "$se_rule"
has "shape C's Session rule says every dispatched agent inherits the session's effort" \
  "every agent the run dispatches inherits the session's effort" "$se_rule"
ex_session="$(sed -n '/^#   ▶ \*\*Session\*\* claude-opus-5/,/^#$/p' "$ROOT/templates/report-templates.md" | sed 's/^# *//' | tr '\n' ' ' | tr -s ' ')"
has "shape C's worked example renders the Session line with a recorded level and the inheritance clause" \
  "effort xhigh, $SE_INHERIT" "$ex_session"
eo_line="$(grep '^⚠️ \*\*Effort override\*\*' "$ROOT/templates/report-templates.md")"
case "$eo_line" in
  *'`CLAUDE_CODE_EFFORT_LEVEL` is set'*'overrides the session effort for the driver and every dispatched agent this run'*)
    ok "shape C carries a ⚠️ Effort override line naming CLAUDE_CODE_EFFORT_LEVEL and what it overrides" ;;
  *) bad "shape C carries a ⚠️ Effort override line naming CLAUDE_CODE_EFFORT_LEVEL and what it overrides" "got: [$eo_line]" ;;
esac
# Placement: directly after `⚠️ Routing config` among shape C's literal lines.
se_after="$(grep -v '^#' "$ROOT/templates/report-templates.md" | grep -v '^$' \
  | grep -A1 '^⚠️ \*\*Routing config\*\*' | sed -n 2p)"
case "$se_after" in
  '⚠️ **Effort override**'*) ok "shape C's ⚠️ Effort override line comes right after ⚠️ Routing config" ;;
  *) bad "shape C's ⚠️ Effort override line comes right after ⚠️ Routing config" "line after Routing config: [$se_after]" ;;
esac
# Its rule comment: rendered only on EFFORT_ENV=set, absent on unset, asks nothing, never stops.
eo_rule_raw="$(sed -n '/^# - \*\*`⚠️ Effort override` is rendered only when/,/^# - /p' "$ROOT/templates/report-templates.md")"
# The bullet sits closer to the end of the file than SPAN_CEILING, so a span that ran
# on to EOF would still pass under_ceiling; the end anchor is checked directly instead.
eo_rule_end="$(printf '%s\n' "$eo_rule_raw" | tail -n 1)"
if [ -z "$eo_rule_raw" ]; then
  bad "the ⚠️ Effort override rule span is found and stops at its end anchor" 'no rule bullet found'
else
  case "$eo_rule_end" in
    '# - '*) under_ceiling "the ⚠️ Effort override rule span is found and stops at its end anchor" "$eo_rule_raw" ;;
    *) bad "the ⚠️ Effort override rule span is found and stops at its end anchor" \
         "the span ran on to [$eo_rule_end], not to the next rule bullet" ;;
  esac
fi
eo_rule="$(printf '%s\n' "$eo_rule_raw" | sed 's/^# *//' | tr '\n' ' ' | tr -s ' ')"
has "the Effort override rule renders it only when session-effort printed EFFORT_ENV=set" \
  'printed `EFFORT_ENV=set`**' "$eo_rule"
has "the Effort override rule leaves the line absent on EFFORT_ENV=unset (unset or empty)" \
  'printed `EFFORT_ENV=unset` (the variable unset or empty) the line is absent' "$eo_rule"
has "the Effort override rule says it asks nothing and never stops the run" \
  'It asks nothing and never stops the run' "$eo_rule"

# Rendered kickoffs: a recorded level, `unknown`, and one carrying the override line.
_se_kickoff() {  # $1 = the ▶ Session line, $2 = an optional ⚠️ line after Routing config
  printf '%s\n' \
    '▶ **STARTING** · Transaction import: make it survive real bank files · ⬚ **5 packets** · 2 phases' '' \
    '> **Phase 1 — speed** · ⬚ Stream large imports · ⬚ Paginate the list · ⬚ Cache totals' '' \
    '⚠️ **Assuming** — every bank in the sample set sends a stable per-transaction id.' '' \
    '⚠️ **Routing config** — 1 entry ignored: loop-driver (loop-driver)' ''
  [ -n "$2" ] && printf '%s\n' "$2" ''
  printf '%s\n' \
    '🔀 **Will need you** — none' '' \
    '> **Won'"'"'t touch:** the transactions table schema, so no migration.' '' \
    "$1" '' \
    '▶ **Stops at** `orch/txn-import` ready for review'
}
SE_EO='⚠️ **Effort override** — `CLAUDE_CODE_EFFORT_LEVEL` is set, and overrides the session effort for the driver and every dispatched agent this run'
_se_kickoff "▶ **Session** claude-opus-5[1m] · effort xhigh, $SE_INHERIT · compaction 400000" '' > "$LD/c-effort-xhigh.md"
_se_kickoff "▶ **Session** claude-opus-5[1m] · effort unknown, $SE_INHERIT · compaction 400000" '' > "$LD/c-effort-unknown.md"
_se_kickoff "▶ **Session** claude-opus-5[1m] · effort xhigh, $SE_INHERIT · compaction 400000" "$SE_EO" > "$LD/c-effort-override.md"
for se_case in xhigh unknown override; do
  for se_dg in digest-empty digest; do
    out="$(_lint C "$LD/c-effort-$se_case.md" "$LD/$se_dg")"
    [ "$out" = 'REPORT_LINT=clean' ] && ok "a kickoff with the effort-$se_case Session form is clean against $se_dg" \
      || bad "a kickoff with the effort-$se_case Session form is clean against $se_dg" "$out"
  done
done
grep -qF "effort xhigh, $SE_INHERIT" "$LD/c-effort-xhigh.md" \
  && grep -qF "effort unknown, $SE_INHERIT" "$LD/c-effort-unknown.md" \
  && grep -qF '⚠️ **Effort override**' "$LD/c-effort-override.md" \
  && ok 'the three effort kickoff fixtures carry the forms they are named for' \
  || bad 'the three effort kickoff fixtures carry the forms they are named for' "$(cat "$LD/c-effort-override.md")"
# Control: the lint judges the override line -- a second glyph on it fires.
sed 's/^⚠️ \*\*Effort override\*\*/⚠️ ✅ **Effort override**/' "$LD/c-effort-override.md" > "$LD/v-effort-two.md"
fires 'two-glyphs: a ⚠️ Effort override line carrying a second glyph is named' two-glyphs "$(_lint C "$LD/v-effort-two.md" "$LD/digest-empty")"

# session-effort-reporting T5: both loop entry points read the session's effort with
# `runstate.sh session-effort` just before `driver-mode enter` and pass its EFFORT
# through, instead of a hard-coded `--effort unknown` justified by "nothing records it
# automatically". Each file is guarded non-empty before the absence checks run over
# it, and the entry block is the same fenced span `_extract_ct_block` pins above, so a
# moved block fails the ordering check rather than passing an empty scan.
for se_skill in run-loop resume; do
  se_file="$ROOT/skills/$se_skill/SKILL.md"
  se_body="$(cat "$se_file" 2>/dev/null)"
  if [ -z "$se_body" ]; then
    bad "$se_skill SKILL.md is readable for the session-effort checks" "empty or missing: $se_file"
    continue
  fi
  has "$se_skill SKILL.md names runstate.sh session-effort" 'runstate.sh session-effort' "$se_body"
  if grep -qF 'nothing records it automatically' "$se_file"; then
    bad "$se_skill SKILL.md no longer says the effort is recorded by nothing" \
      "found: $(grep -nF 'nothing records it automatically' "$se_file" | head -1)"
  else
    ok "$se_skill SKILL.md no longer says the effort is recorded by nothing"
  fi
  if grep -qF -- '--effort unknown' "$se_file"; then
    bad "$se_skill SKILL.md passes no literal --effort unknown" \
      "found: $(grep -nF -- '--effort unknown' "$se_file" | head -1)"
  else
    ok "$se_skill SKILL.md passes no literal --effort unknown"
  fi
  # In the entry block: session-effort is invoked, then driver-mode enter, and
  # --effort takes the printed EFFORT.
  se_block="$(_extract_ct_block "$se_file")"
  se_order="$(printf '%s\n' "$se_block" | tr -d '\r' | awk '/^runstate\.sh /{printf "%s ", $2}')"
  case "$se_order" in
    *'session-effort driver-mode '*) \
      ok "$se_skill entry block runs session-effort just before driver-mode enter" ;;
    *) bad "$se_skill entry block runs session-effort just before driver-mode enter" "invocation order: [$se_order]" ;;
  esac
  has "$se_skill entry block passes the printed EFFORT to --effort" \
    '--effort <EFFORT, exactly as printed>' "$se_block"
  # skill-prompt-trim T5: resume states these three rules by reference -- run-loop §2
  # is their one statement -- so over resume the phrases are read from run-loop and
  # resume must name that section as where they live.
  se_prose="$(_squeeze "$se_file")"
  if [ "$se_skill" = resume ]; then
    has "resume SKILL.md refers the entry-block rules to run-loop's ## 2 heading" \
      "The rule for each of these three calls is the one run-loop's \`## 2. Enter driver mode\` states" "$se_prose"
    se_prose="$(_squeeze "$ROOT/skills/run-loop/SKILL.md")"
  fi
  has "$se_skill SKILL.md says the effort is read, never inferred from the model" \
    'The effort is read, never inferred from the model' "$se_prose"
  has "$se_skill SKILL.md never asks the operator to change the effort" \
    'Never ask the operator to change the effort' "$se_prose"
  has "$se_skill SKILL.md renders ⚠️ Effort override only on EFFORT_ENV=set" \
    'printed `EFFORT_ENV=set`' "$se_prose"
done

# The shape-defined constructs, one assertion each, against the rule each would
# otherwise trip -- so an exemption that silently widens or vanishes shows here.
b_ok="$(_lint B "$LD/b-ok.md" "$LD/digest")"
c_ok="$(_lint C "$LD/c-ok.md" "$LD/digest-empty")"
not_fires 'the tally line may carry many glyphs (shape-defined)' two-glyphs "$b_ok"
not_fires "▶ Next is outside the tally's order (shape-defined)" section-order "$b_ok"
not_fires 'a branch naming an id, and a bare sha, in the state line never fire (shape-defined)' untitled-id "$b_ok"
not_fires "the kickoff's phase lines may carry many glyphs (shape-defined)" two-glyphs "$c_ok"
not_fires "the kickoff's ▶ Session and ▶ Stops at headings are not out of order (shape-defined)" section-order "$c_ok"
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

printf '\n== an honest body on a resumed run lints clean (stop-report-decision-liveness T3) ==\n'
# A synthetic run whose ask-operator question was answered by a later session's
# start record. The run is built with the real scripts -- begin-run, record-start,
# route, record-outcome -- and ONE hand-written record: the answering start, which
# needs a timestamp guaranteed strictly after the real question's. A second real
# record-start would lean on wall-clock ordering, and a tie does not answer; the
# fixed far-future stamp cannot tie. It lives in its own session's log (the resume),
# so the control drops exactly that record by removing that one file.
#
# What makes this case worth having: the digest KEEPS the answered `decision` line
# (its line kinds are frozen and carry no timestamp), so a body with no decision
# block lints clean only because run-tally applies the liveness rule. The control
# proves it -- same run minus the answer, same body, same header recipe, and the
# decision-count finding appears. Every header 🔀 figure is built from the
# DECISIONS= value run-tally just printed, bucket omitted at 0, never a literal.
RS="$ROOT/scripts/runstate.sh"
RR="$TMP/resumed-run"; mkdir -p "$RR/.agents/metrics/outcomes"; git -C "$RR" init -q
printf 'schema: 3\nstatus: running\n' > "$RR/.agents/run-state.yaml"
rr_id="$(cd "$RR" && "$RS" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
[ -n "$rr_id" ] && ok 'resumed-run fixture: begin-run minted a run id' \
  || bad 'resumed-run fixture: begin-run minted a run id' 'no RUN_ID'
mkdir -p "$RR/.agents/loop/$rr_id/rr-t1"
printf '# rr-t1: Reconcile imported balances\n' > "$RR/.agents/loop/$rr_id/rr-t1/handoff.md"
(cd "$RR" && "$RS" record-start rr-t1 RR1 \
  && "$RS" route .agents/run-state.yaml rr-t1 ask-operator \
  && "$RS" record-outcome rr-t1 blocked RR1) >/dev/null 2>&1 \
  && ok 'resumed-run fixture: start, ask-operator question and blocked stop recorded by the real scripts' \
  || bad 'resumed-run fixture: start, ask-operator question and blocked stop recorded by the real scripts' 'a runstate.sh call failed'
# The resume: a later session starts the same packet again, answering the question.
printf '{"ts":"2099-01-01T00:00:00.000Z","packet":"rr-t1","session":"RR2","kind":"start"}\n' \
  > "$RR/.agents/metrics/outcomes/RR2.jsonl"

# $1 = DECISIONS figure, $2 = UNFINISHED figure, $3 = output file. The body carries
# no decision blocks; only the header figures vary, and each bucket is omitted at 0.
_rr_report() {
  local hdr='⏸️ **PAUSED** · Balance reconciliation'
  [ "${2:-0}" -gt 0 ] && hdr="$hdr · ⚠️ **$2 unfinished**"
  if [ "${1:-0}" -gt 0 ]; then
    if [ "$1" = 1 ]; then hdr="$hdr · 🔀 **1 decision**"; else hdr="$hdr · 🔀 **$1 decisions**"; fi
  fi
  {
    printf '%s\n\n' "$hdr"
    printf 'Stopped after 1 packet. Nothing at risk, nothing half-written.\n\n'
    printf '⚠️ **Unfinished**\n\n'
    printf '> ⚠️ **Reconcile imported balances** (`rr-t1`) — resumed after your answer, not yet landed\n'
  } > "$3"
}
_rr_fig() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

(cd "$RR" && "$RS" run-digest .agents/run-state.yaml) > "$TMP/rr-digest" 2>/dev/null
rr_digest="$(cat "$TMP/rr-digest")"
has "resumed-run: the digest file carries the answered question's decision line" \
  "$(printf 'decision\trr-t1\task-operator')" "$rr_digest"
rr_tally="$(cd "$RR" && "$RS" run-tally .agents/run-state.yaml 2>&1)"
rr_dec="$(_rr_fig DECISIONS "$rr_tally")"; rr_unf="$(_rr_fig UNFINISHED "$rr_tally")"
[ "$rr_dec" = 0 ] && ok 'resumed-run: run-tally over the run prints DECISIONS=0' \
  || bad 'resumed-run: run-tally over the run prints DECISIONS=0' "$rr_tally"
case "$rr_unf" in ''|*[!0-9]*) rr_unf=0 ;; esac
case "$rr_dec" in
  ''|*[!0-9]*) bad 'resumed-run: the honest report lints with no decision-count finding' "no numeric DECISIONS: $rr_tally" ;;
  *)
    _rr_report "$rr_dec" "$rr_unf" "$TMP/rr-report.md"
    not_fires 'resumed-run: a report headed from the printed DECISIONS figure, with no decision blocks, yields no decision-count finding' \
      decision-count "$(_lint B "$TMP/rr-report.md" "$TMP/rr-digest")"
    ;;
esac

# Control: the same run with the answering record dropped.
rm -f "$RR/.agents/metrics/outcomes/RR2.jsonl"
(cd "$RR" && "$RS" run-digest .agents/run-state.yaml) > "$TMP/rr-digest-ctl" 2>/dev/null
ctl_tally="$(cd "$RR" && "$RS" run-tally .agents/run-state.yaml 2>&1)"
ctl_dec="$(_rr_fig DECISIONS "$ctl_tally")"; ctl_unf="$(_rr_fig UNFINISHED "$ctl_tally")"
[ "$ctl_dec" = 1 ] && ok 'resumed-run control: with the answering record dropped, run-tally prints DECISIONS=1' \
  || bad 'resumed-run control: with the answering record dropped, run-tally prints DECISIONS=1' "$ctl_tally"
case "$ctl_unf" in ''|*[!0-9]*) ctl_unf=0 ;; esac
case "$ctl_dec" in
  ''|*[!0-9]*) bad 'resumed-run control: the same body yields a decision-count finding' "no numeric DECISIONS: $ctl_tally" ;;
  *)
    _rr_report "$ctl_dec" "$ctl_unf" "$TMP/rr-report-ctl.md"
    fires 'resumed-run control: the same body under a header built from the printed figure yields a decision-count finding' \
      decision-count "$(_lint B "$TMP/rr-report-ctl.md" "$TMP/rr-digest-ctl")"
    ;;
esac

printf '\n== a report after a second stop lints clean once answered questions are pruned (answered-question-expiry T5) ==\n'
# A run that stops on a question, resumes (the resume's start answers it), and stops
# on a second question for the same packet. Before prune-questions existed, the
# run-state's pending_questions list kept BOTH entries, so a body rendered one
# decision block per entry (two) under a header whose 🔀 figure run-tally correctly
# ages down to one -- the header/body mismatch decision-count exists to catch.
#
# Session 1 is hand-written at fixed year-2000 stamps (start, the ask-operator
# routing record, the blocked stop), so every later real record is strictly after
# it and the real resume start is guaranteed to answer question 1. Session 2 is
# real scripts: record-start (the answer), route ask-operator (question 2), and
# record-outcome blocked. Question 2 is raised AFTER the answering start, so that
# start can at most tie it -- and a tie never answers -- so question 2 stays live.
# asked_at for question 2 is read from the routing record the real route wrote,
# the same source /gaffer:pause stamps from.
SQ="$TMP/second-stop"; mkdir -p "$SQ/.agents/metrics/outcomes"; git -C "$SQ" init -q
printf 'schema: 3\nstatus: running\n' > "$SQ/.agents/run-state.yaml"
sq_id="$(cd "$SQ" && "$RS" begin-run .agents/run-state.yaml | sed -n 's/^RUN_ID=//p')"
[ -n "$sq_id" ] && ok 'second-stop fixture: begin-run minted a run id' \
  || bad 'second-stop fixture: begin-run minted a run id' 'no RUN_ID'
sq_dir="$SQ/.agents/loop/$sq_id"
mkdir -p "$sq_dir/sq-t1"
printf '# sq-t1: Settle split payments\n' > "$sq_dir/sq-t1/handoff.md"
sq_q1_ts='2000-01-01T00:00:01Z'
{
  printf '{"ts":"2000-01-01T00:00:00Z","packet":"sq-t1","session":"SQ1","kind":"start"}\n'
  printf '{"ts":"2000-01-01T00:00:02Z","packet":"sq-t1","session":"SQ1","outcome":"blocked"}\n'
} > "$SQ/.agents/metrics/outcomes/SQ1.jsonl"
printf '{"ts":"%s","packet":"sq-t1","token":"ask-operator","action":"stop","status":""}\n' "$sq_q1_ts" \
  > "$sq_dir/routing.jsonl"
(cd "$SQ" && "$RS" record-start sq-t1 SQ2 \
  && "$RS" route .agents/run-state.yaml sq-t1 ask-operator \
  && "$RS" record-outcome sq-t1 blocked SQ2) >/dev/null 2>&1 \
  && ok 'second-stop fixture: the resume start, the second question and the second stop recorded by the real scripts' \
  || bad 'second-stop fixture: the resume start, the second question and the second stop recorded by the real scripts' 'a runstate.sh call failed'
sq_q2_ts="$(tail -n 1 "$sq_dir/routing.jsonl" | sed -n 's/^{"ts":"\([^"]*\)".*/\1/p')"
[ -n "$sq_q2_ts" ] && [ "$sq_q2_ts" != "$sq_q1_ts" ] && ok 'second-stop fixture: the second question has its own routing timestamp' \
  || bad 'second-stop fixture: the second question has its own routing timestamp' "q2 ts=[$sq_q2_ts]"

# The run-state the second stop persists, before any prune: both questions, in the
# block-entry shape templates/run-state.yaml documents, with a findings index after
# them that the prune must carry through.
cat > "$SQ/.agents/run-state.yaml.new" <<EOF
schema: 3
status: paused
run_id: '$sq_id'
pending_questions:
  - id: q-001
    severity: normal
    packet: 'sq-t1'
    asked_at: '$sq_q1_ts'
    question: 'Should a split payment settle each leg on its own date?'
  - id: q-002
    severity: normal
    packet: 'sq-t1'
    asked_at: '$sq_q2_ts'
    question: 'Should a refunded leg reopen the whole split?'
findings:
EOF
mv "$SQ/.agents/run-state.yaml.new" "$SQ/.agents/run-state.yaml"
cp "$SQ/.agents/run-state.yaml" "$TMP/sq-run-state-unpruned.yaml"

sq_prune="$(cd "$SQ" && "$RS" prune-questions .agents/run-state.yaml 2>&1)"
case "$sq_prune" in
  *'PRUNED=yes'*'DROPPED=1'*) ok 'second-stop: prune-questions drops exactly the answered first question' ;;
  *) bad 'second-stop: prune-questions drops exactly the answered first question' "$sq_prune" ;;
esac

# One decision block per surviving pending_questions entry, numbered in list order.
# $1 = run-state to read the list from, $2 = DECISIONS figure, $3 = UNFINISHED
# figure, $4 = output file. Each bucket is omitted at 0.
_sq_report() {
  local hdr='⏸️ **PAUSED** · Split payments' questions n=0 q
  [ "${3:-0}" -gt 0 ] && hdr="$hdr · ⚠️ **$3 unfinished**"
  if [ "${2:-0}" -gt 0 ]; then
    if [ "$2" = 1 ]; then hdr="$hdr · 🔀 **1 decision**"; else hdr="$hdr · 🔀 **$2 decisions**"; fi
  fi
  questions="$(awk '
    /^pending_questions:[[:space:]]*$/ { inq = 1; next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inq = 0 }
    inq && /^[[:space:]]*question:/ {
      line = $0; sub(/^[[:space:]]*question:[[:space:]]*/, "", line)
      gsub(/^'"'"'|'"'"'$/, "", line); print line
    }' "$1")"
  {
    printf '%s\n\n' "$hdr"
    printf 'Stopped after 1 packet. Nothing at risk, nothing half-written.\n\n'
    printf '⚠️ **Unfinished**\n\n'
    printf '> ⚠️ **Settle split payments** (`sq-t1`) — stopped on your question, not yet landed\n\n'
    printf '🔀 **Decisions** — reply `1A`\n'
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      n=$((n + 1))
      printf '\n> **%d · %s**\n>\n' "$n" "$q"
      printf '> - **A ›** Yes\n>   → each leg reconciles independently\n'
      printf '> - **B ›** No\n>   → the split stays one unit\n>\n'
      printf '> **→ Pick A** — matches how the bank reports legs.\n'
    done <<<"$questions"
  } > "$4"
}

(cd "$SQ" && "$RS" run-digest .agents/run-state.yaml) > "$TMP/sq-digest" 2>/dev/null
sq_tally="$(cd "$SQ" && "$RS" run-tally .agents/run-state.yaml 2>&1)"
sq_dec="$(_rr_fig DECISIONS "$sq_tally")"; sq_unf="$(_rr_fig UNFINISHED "$sq_tally")"
[ "$sq_dec" = 1 ] && ok 'second-stop: run-tally ages the answered question out and prints DECISIONS=1' \
  || bad 'second-stop: run-tally ages the answered question out and prints DECISIONS=1' "$sq_tally"
case "$sq_unf" in ''|*[!0-9]*) sq_unf=0 ;; esac
case "$sq_dec" in
  ''|*[!0-9]*)
    bad 'second-stop: the body rendered from the pruned list yields no decision-count finding' "no numeric DECISIONS: $sq_tally"
    bad 'second-stop control: the body rendered from the unpruned list yields a decision-count finding' "no numeric DECISIONS: $sq_tally"
    ;;
  *)
    _sq_report "$SQ/.agents/run-state.yaml" "$sq_dec" "$sq_unf" "$TMP/sq-report.md"
    sq_blocks="$(grep -c '^> \*\*[0-9][0-9]* · ' "$TMP/sq-report.md")"
    [ "$sq_blocks" = 1 ] && ok 'second-stop: the pruned body carries one decision block, for the surviving entry' \
      || bad 'second-stop: the pruned body carries one decision block, for the surviving entry' "blocks=$sq_blocks"
    not_fires 'second-stop: the body rendered from the pruned list under a header built from the printed DECISIONS figure yields no decision-count finding' \
      decision-count "$(_lint B "$TMP/sq-report.md" "$TMP/sq-digest")"

    # Control: skip the prune -- the same run, the same header recipe, but the body
    # rendered from the unpruned list still carries the answered first question.
    _sq_report "$TMP/sq-run-state-unpruned.yaml" "$sq_dec" "$sq_unf" "$TMP/sq-report-ctl.md"
    sq_ctl_blocks="$(grep -c '^> \*\*[0-9][0-9]* · ' "$TMP/sq-report-ctl.md")"
    [ "$sq_ctl_blocks" = 2 ] && ok 'second-stop control: the unpruned body carries both decision blocks' \
      || bad 'second-stop control: the unpruned body carries both decision blocks' "blocks=$sq_ctl_blocks"
    fires 'second-stop control: the body rendered from the unpruned list yields a decision-count finding' \
      decision-count "$(_lint B "$TMP/sq-report-ctl.md" "$TMP/sq-digest")"
    ;;
esac

printf '\n== the four landing and scan sites call record-completion, each naming its restore source (skill-prompt-trim T4) ==\n'
# `gspec-backlog.sh record-completion` (skill-prompt-trim T2) holds the landing and scan
# decisions: which exit code of `check-task` / `complete-capabilities` means what, which
# slug to complete, the FEATURE= fallback, the staging test, and the per-slug loop. Four
# sites used to spell those out in prose -- run-loop §1's drifted-capability bullet,
# §3.6's Land step, §4's end-of-run scan, and resume's adopt path. Each must now CALL the
# subcommand with its own restore source stated (§3.6 the index; §1, §4 and adopt HEAD),
# keep what it does with the output (stage STAGE=, the halt/escalate on HALT=, its
# commit and restore rules, its report lines), and carry no copy of the table it gave
# up -- a copy left behind is a second statement of the rule that can drift from the
# one the adapter enforces.
#
# Each span is extracted by its own content anchors, guarded non-empty and under the
# ceiling (an end anchor that stops matching runs the range on and would let every
# presence pin pass on text outside the site). The adopt path is two spans because the
# whole of it sits at the ceiling. Needles are read over the whitespace-squeezed span,
# so a markdown wrap inside one does not fail a clause that is present.
_rc_site() { # file, start-regex, end-regex -> the raw span
  sed -n "/$2/,/$3/p" "$1"
}
_rc_sq() { printf '%s' "$1" | tr -d '\r' | tr '\n' ' ' | tr -s ' '; }
rc_s1="$(_rc_site "$ROOT/skills/run-loop/SKILL.md" \
  '^- \*\*Drifted capability checkboxes' 'silent no-op, same as the check above\.')"
rc_land="$(_rc_site "$ROOT/skills/run-loop/SKILL.md" \
  '^6\. \*\*Land (the `land` action)\.\*\*' 'does today: nothing staged, nothing to report\.')"
rc_s4="$(_rc_site "$ROOT/skills/run-loop/SKILL.md" \
  'Also before declaring done, re-run the same capability-drift scan' 'whatever the rest of the scan flips\.')"
rc_adopt="$(_rc_site "$ROOT/skills/resume/SKILL.md" \
  '\*\*Record whatever' '^  \*\*Commit the flips\.\*\*')"
rc_adopt_commit="$(_rc_site "$ROOT/skills/resume/SKILL.md" \
  '^  \*\*Commit the flips\.\*\*' 'so run metrics count no packet for it\.')"
for rc_pair in "§1 preflight scan|$rc_s1" "§3.6 Land|$rc_land" "§4 end-of-run scan|$rc_s4" \
               "resume adopt|$rc_adopt" "resume adopt commit|$rc_adopt_commit"; do
  rc_name="${rc_pair%%|*}"; rc_span="${rc_pair#*|}"
  [ -n "$rc_span" ] && ok "$rc_name span extracted (anchor holds)" \
    || bad "$rc_name span extracted (anchor holds)" 'empty -- the site moved or was rewritten'
  under_ceiling "$rc_name span stays inside its ceiling (end anchor still matches)" "$rc_span"
done
rc_s1="$(_rc_sq "$rc_s1")"; rc_land="$(_rc_sq "$rc_land")"; rc_s4="$(_rc_sq "$rc_s4")"
rc_adopt="$(_rc_sq "$rc_adopt")"; rc_adopt_commit="$(_rc_sq "$rc_adopt_commit")"

# Present: the call with its restore source, and what the site keeps.
while IFS='|' read -r rc_site rc_label rc_needle; do
  [ -n "$rc_site" ] || continue
  case "$rc_site" in
    s1) rc_span="$rc_s1" ;; land) rc_span="$rc_land" ;; s4) rc_span="$rc_s4" ;;
    adopt) rc_span="$rc_adopt" ;; commit) rc_span="$rc_adopt_commit" ;;
  esac
  has "$rc_site: $rc_label" "$rc_needle" "$rc_span"
done <<'RC_NEEDLES'
s1|the scan pipes capability-drift into the subcommand, restoring from HEAD|capability-drift \ | ${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh record-completion --drift --restore head
s1|every STAGE= path is staged|Stage each `STAGE=` path
s1|one reconcile commit, preflight site|spec: reconcile capability record (preflight)
s1|off the integration branch it restores instead of committing|when the checkout is off the integration branch
s1|a failed call anywhere in the scan restores every STAGE= path|when the last line reads `failed=` above 0
s1|so does a failed commit|when the commit itself fails
s1|the restore is the HEAD form|git checkout HEAD -- <path>
s1|flips are reported from COMPLETED= lines|`COMPLETED=<slug>\t<capability text>`
s1|held features are reported from HELD= lines|`HELD=<slug>\t<reason>`
s1|failed calls are reported|`CAPABILITIES=<slug>\tfailed`
s1|the unjudgeable count is still stated|State the trailing `unjudgeable=<n>` count
land|the call names the members, the FEATURE= fallback, and the index restore|--tasks "$MEMBERS" --feature <the handoff's FEATURE= value> --restore index
land|every STAGE= path is staged with the packet's files|Stage every `STAGE=` path** alongside the packet's own files
land|a drifted member is reported by name, never a halt|`TASK_DRIFT=<member>\t<reason>`
land|a halted call ends the bundle|`HALT=<member>\t<reason>`
land|as failed, for every member|runstate.sh record-outcome "$MEMBERS" failed
land|and leaves driver mode after the stop report|runstate.sh driver-mode exit
land|a held feature commits as normal|`HELD=<slug>\t<reason>`
land|a failed capability call is reported on the landing report|`CAPABILITIES=<slug>\tfailed`
land|and its restore is stated to be from the index|from the index, not from `HEAD`
s4|the same scan call, restoring from HEAD|`capability-drift | record-completion --drift --restore head`
s4|every STAGE= path is staged|Stage each `STAGE=` path
s4|one reconcile commit, end-of-run site|spec: reconcile capability record (end-of-run)
s4|a failed call anywhere in the scan restores every STAGE= path|last line reads `failed=` above 0
s4|so does a failed commit|or the commit fails
s4|the restore is the HEAD form|git checkout HEAD -- <path>
s4|flips are reported from COMPLETED= lines|`COMPLETED=<slug>\t<capability text>`
s4|held features are reported from HELD= lines|`HELD=<slug>\t<reason>`
s4|failed calls are reported|`CAPABILITIES=<slug>\tfailed`
s4|the unjudgeable count is still stated|State the trailing `unjudgeable=<n>` count
adopt|the call names the members and restores from HEAD|--tasks "$MEMBERS" --feature <the handoff's FEATURE= value> --restore head
adopt|--feature is passed only when the handoff exists|**only when that file exists**
adopt|a drifted member is noted by name|`TASK_DRIFT=<member>\t<reason>`
adopt|a halted call escalates|**escalate to the human** naming the member
adopt|the no-slug-no-handoff skip|`RECORD_COMPLETION=skipped`
adopt|is stated in the kickoff|say so in the kickoff
adopt|a held feature is named|`HELD=<slug>\t<reason>`
adopt|a failed call is reported, never escalated|`CAPABILITIES=<slug>\tfailed`** — report it by name — never escalate
adopt|the restore is at the path the handoff's PRD= line names|the path the handoff's `PRD=` line names
commit|every STAGE= path is staged|Stage every `STAGE=` path
commit|it commits only when staging changed something|git diff --cached --quiet
commit|the adopt reconcile commit|spec: reconcile capability record (adopt)
commit|never an amend|**never an amend of the orphan commit**
RC_NEEDLES

# Absent: the table and the decisions the subcommand now owns, over every site's span.
# `exit 1` is safe to pin absent: the sites say the CALL "exits 1" on a halt, which is
# record-completion's own exit, and "exits 1" does not contain "exit 1".
for rc_pair in "§1 preflight scan|$rc_s1" "§3.6 Land|$rc_land" "§4 end-of-run scan|$rc_s4" \
               "resume adopt|$rc_adopt $rc_adopt_commit"; do
  rc_name="${rc_pair%%|*}"; rc_span="${rc_pair#*|}"
  while IFS='|' read -r rc_label rc_needle; do
    [ -n "$rc_label" ] || continue
    case "$rc_span" in
      *"$rc_needle"*) bad "$rc_name carries no copy of: $rc_label" "still present: $rc_needle" ;;
      *) ok "$rc_name carries no copy of: $rc_label" ;;
    esac
  done <<'RC_ABSENT'
the exit-0 reading|exit 0
the exit-1 reading|exit 1
the exit-4 reading|exit 4
the complete-capabilities summary-line reading|COMPLETE_CAPABILITIES=
the FILE= staging test|FILE=
the completed=<n> staging test|completed=<n>
the CHECKED=none skip rule|CHECKED=none
the FEATURE= fallback wording|fall back to
the per-slug loop|one call per slug
RC_ABSENT
done

printf '\n== resume states only what is unique to resuming; run-loop is the one statement of the rest (skill-prompt-trim T5) ==\n'
# Resume used to restate four rules run-loop also carries -- bundle-membership recovery,
# the sweep before start, the handoff checks, the capability flip's shared rules -- and
# pointed at run-loop by line number (`:69-72`, `:84–87`) and bare section number. Two
# statements of one rule drift apart, and a line-number reference goes stale on the
# next edit above it. So: run-loop carries the moved rules (membership recovery in the
# Form step, the recovered bundle's non-cursor HANDOFF=unknown in the Write step, and a
# resumed session's first-packet continuation rule in the sweep); resume carries no copy
# of them; and every reference resume makes to run-loop names a heading or a §3 step
# title that exists there, never a line or a bare number. Spans are content-anchored,
# guarded non-empty and under the ceiling, as above.
t5_rl="$ROOT/skills/run-loop/SKILL.md"
t5_rs="$ROOT/skills/resume/SKILL.md"
t5_recover="$(_rc_site "$t5_rl" 'Recover the membership instead of forming it' 'Then go straight to the sweep below\.')"
t5_first="$(_rc_site "$t5_rl" 'The first packet a resumed session runs is the one' 'like any other open packet\.')"
t5_unknown="$(_rc_site "$t5_rl" 'When it was \*\*recovered\*\* from an existing handoff' 'never as the single-member case\.')"
for t5_pair in "run-loop membership recovery|$t5_recover" "run-loop first-packet exception|$t5_first" \
               "run-loop recovered HANDOFF=unknown|$t5_unknown"; do
  t5_name="${t5_pair%%|*}"; t5_span="${t5_pair#*|}"
  [ -n "$t5_span" ] && ok "$t5_name span extracted (anchor holds)" \
    || bad "$t5_name span extracted (anchor holds)" 'empty -- the rule moved out of run-loop or was rewritten'
  under_ceiling "$t5_name span stays inside its ceiling (end anchor still matches)" "$t5_span"
done
t5_recover="$(_rc_sq "$t5_recover")"; t5_first="$(_rc_sq "$t5_first")"; t5_unknown="$(_rc_sq "$t5_unknown")"

# The recovery sits in §3's Form step, before `group` is read, and the recovered-bundle
# check sits in the Write step: a rule stated in the wrong step is a rule a session
# reaches at the wrong time.
t5_form_line="$(grep -n "^2\. \*\*Form this packet's members" "$t5_rl" | head -1 | cut -d: -f1)"
t5_write_line="$(grep -n '^3\. \*\*Write the handoff' "$t5_rl" | head -1 | cut -d: -f1)"
t5_rec_line="$(grep -n 'Recover the membership instead of forming it' "$t5_rl" | head -1 | cut -d: -f1)"
t5_grp_line="$(grep -n 'gspec-backlog.sh group' "$t5_rl" | head -1 | cut -d: -f1)"
t5_unk_line="$(grep -n 'When it was \*\*recovered\*\* from an existing handoff' "$t5_rl" | head -1 | cut -d: -f1)"
t5_dsp_line="$(grep -n '^4\. \*\*Dispatch, then route' "$t5_rl" | head -1 | cut -d: -f1)"
if [ -n "$t5_form_line" ] && [ -n "$t5_rec_line" ] && [ -n "$t5_grp_line" ] && [ -n "$t5_write_line" ] \
   && [ "$t5_form_line" -lt "$t5_rec_line" ] && [ "$t5_rec_line" -lt "$t5_grp_line" ] \
   && [ "$t5_grp_line" -lt "$t5_write_line" ]; then
  ok "run-loop: membership recovery sits in the Form step, before group is read"
else
  bad "run-loop: membership recovery sits in the Form step, before group is read" \
    "form=${t5_form_line:-none} recover=${t5_rec_line:-none} group=${t5_grp_line:-none} write=${t5_write_line:-none}"
fi
if [ -n "$t5_write_line" ] && [ -n "$t5_unk_line" ] && [ -n "$t5_dsp_line" ] \
   && [ "$t5_write_line" -lt "$t5_unk_line" ] && [ "$t5_unk_line" -lt "$t5_dsp_line" ]; then
  ok "run-loop: the recovered bundle's non-cursor HANDOFF=unknown sits in the Write step"
else
  bad "run-loop: the recovered bundle's non-cursor HANDOFF=unknown sits in the Write step" \
    "write=${t5_write_line:-none} unknown=${t5_unk_line:-none} dispatch=${t5_dsp_line:-none}"
fi

while IFS='|' read -r t5_site t5_label t5_needle; do
  [ -n "$t5_site" ] || continue
  case "$t5_site" in
    recover) t5_span="$t5_recover" ;; first) t5_span="$t5_first" ;; unknown) t5_span="$t5_unknown" ;;
  esac
  has "run-loop $t5_site: $t5_label" "$t5_needle" "$t5_span"
done <<'T5_NEEDLES'
recover|recovery is keyed on the cursor's own handoff existing|`<RUN_DIR>/<cursor>/handoff.md`
recover|group is never re-run on recovery|**Never re-run `group` here**
recover|tier and agent come off the handoff header|`grep '^tier:\|^agent:' <path>`
recover|membership comes off the BUNDLE= line|`grep -m1 '^BUNDLE=' <path>`
recover|an absent BUNDLE= line is the cursor alone|Its absence means a single-member bundle: `MEMBERS=<cursor>` alone.
recover|only the mechanical refusals are re-run|re-run only the **mechanical refusals**
recover|through task-status over the recovered members|`gspec-backlog.sh task-status "$MEMBERS"`
recover|finished and gone members drop out|reads `finished`
recover|but never the cursor|**never the cursor itself**
recover|the hand-off-feature refusal is left to the handoff check|`HANDOFF=refused` check catches it
first|resume decides the first packet from the status it loaded|decides it from the `status` it read when it loaded the checkpoint
first|paused or blocked is a continuation|`paused` or `blocked` is a continuation
first|a crash is a fresh start|`running` (a crash) is a fresh start
first|so the crashed bundle's open starts close interrupted|closes as `interrupted`
unknown|a non-cursor HANDOFF=unknown truncates like a refusal|treat a non-cursor `HANDOFF=unknown` exactly as a non-cursor `HANDOFF=refused`
unknown|because task-status is conservative|reads several genuinely-gone shapes as `unknown`
unknown|and is never the single-member case|never as the single-member case
T5_NEEDLES

# Resume carries no copy of the moved rules. Every needle below is a mechanism only the
# moved text used; resume reaches all of it through run-loop §3's Form and Write steps.
t5_body="$(_squeeze "$t5_rs")"
[ -n "$t5_body" ] && ok 'resume SKILL.md is readable for the no-copy checks' \
  || bad 'resume SKILL.md is readable for the no-copy checks' "empty or missing: $t5_rs"
while IFS='|' read -r t5_label t5_needle; do
  [ -n "$t5_label" ] || continue
  case "$t5_body" in
    *"$t5_needle"*) bad "resume carries no copy of: $t5_label" "still present: $t5_needle" ;;
    *) ok "resume carries no copy of: $t5_label" ;;
  esac
done <<'T5_ABSENT'
forming a bundle fresh (group)|gspec-backlog.sh group
reading the bundle cap|bundle-cap
the sweep's own calls|sweep-open
the handoff checks|HANDOFF=unknown
the refused-member truncation|HANDOFF=refused
membership recovery off the handoff header|^tier:
the start record|record-start
writing the handoff|runstate.sh handoff
the held-feature definition|`covers:` quote matches no capability
T5_ABSENT

# Resume refers to run-loop by heading, never by line or bare number.
t5_linerefs="$(grep -nE 'SKILL\.md[)]?[[:space:]]*:[0-9]|:[0-9]+[-–][0-9]+' "$t5_rs")"
[ -z "$t5_linerefs" ] && ok 'resume names no run-loop line numbers' \
  || bad 'resume names no run-loop line numbers' "found: $(printf '%s' "$t5_linerefs" | head -1)"
t5_subsec="$(grep -nE '§[0-9]+\.[0-9]' "$t5_rs")"
[ -z "$t5_subsec" ] && ok 'resume names no run-loop §N.N subsection by number' \
  || bad 'resume names no run-loop §N.N subsection by number' "found: $(printf '%s' "$t5_subsec" | head -1)"
t5_bare="$(printf '%s' "$t5_body" | grep -oE "run-loop(/SKILL\.md|'s)? §[0-9]+('s \*\*)?" | grep -v "'s \*\*\$")"
[ -z "$t5_bare" ] && ok "resume's every run-loop § reference is a §3 step named by its bold title" \
  || bad "resume's every run-loop § reference is a §3 step named by its bold title" "bare: $(printf '%s' "$t5_bare" | head -1)"

# ...and every heading and step title it names exists in run-loop, so a renamed heading
# fails here instead of leaving resume pointing at nothing. A heading reference is
# `## <prefix>` in backticks, a step reference `§3's **<prefix>**`; each must be the
# prefix of a run-loop `## ` heading or a numbered §3 step's bold title.
t5_heads="$(printf '%s' "$t5_body" | grep -oE '`## [^`]+`' | sed -E 's/^`## //; s/`$//' | sort -u)"
t5_steps="$(printf '%s' "$t5_body" | grep -oE "§3's \*\*[^*]+\*\*" | sed -E "s/^§3's \*\*//; s/\*\*\$//" | sort -u)"
[ -n "$t5_heads" ] && ok 'resume names run-loop sections by heading (at least one found)' \
  || bad 'resume names run-loop sections by heading (at least one found)' 'no `## ...` reference in resume'
[ -n "$t5_steps" ] && ok 'resume names run-loop §3 steps by bold title (at least one found)' \
  || bad 'resume names run-loop §3 steps by bold title (at least one found)' "no §3's **...** reference in resume"
t5_missing=""
while IFS= read -r t5_h; do
  [ -n "$t5_h" ] || continue
  grep -qF -- "## $t5_h" "$t5_rl" || t5_missing="$t5_missing [## $t5_h]"
done <<EOF
$t5_heads
EOF
while IFS= read -r t5_s; do
  [ -n "$t5_s" ] || continue
  grep -qE "^[0-9]+\. \*\*$(printf '%s' "$t5_s" | sed 's/[][\.*^$()+?{}|]/\\&/g')" "$t5_rl" \
    || t5_missing="$t5_missing [§3 **$t5_s**]"
done <<EOF
$t5_steps
EOF
[ -z "$t5_missing" ] && ok 'every heading and §3 step resume names exists in run-loop' \
  || bad 'every heading and §3 step resume names exists in run-loop' "not found:$t5_missing"

# Resume still carries its own four things, and the routing resolve beside its dispatch.
while IFS='|' read -r t5_label t5_needle; do
  [ -n "$t5_label" ] || continue
  has "resume keeps: $t5_label" "$t5_needle" "$t5_body"
done <<'T5_KEEP'
the mode: parallel stop|runstate.sh lanes .agents/run-state.yaml
reconstructing the checkpoint from git|runstate.sh reconstruct .
reconciling the working tree|runstate.sh reconcile .agents/run-state.yaml .
the adopt path's own commit|spec: reconcile capability record (adopt)
surfacing pending questions as decisions|**Decisions for you** block
the model resolved immediately before each dispatch|routing.sh resolve <agent>` immediately before each dispatch
T5_KEEP

printf '\n== run-loop top through §2: values by key only, reasons one clause with the rest in their ADRs (skill-prompt-trim T6) ==\n'
# Capability 4: a loop skill names a setting by its key and the file holding its value,
# never the value or a fallback. §1's Branch bullet stated the integration branch's
# default in parentheses; it now names `integration_branch` in
# `.agents/project-overrides.yaml` and points at the template comment for the fallback.
# Capability 3: each rule keeps at most one clause of reason, and the rest moves to a
# dated `Relocated from skills (<date>)` section of the ADR that owns the rule. Each row
# below pins all three sides of one move -- the clause the skill kept, the moved wording
# gone from the skill's range, and that wording present in the run-loop relocation
# section of its ADR -- so a reason pasted back into the skill, or a move that dropped
# the wording instead of relocating it, turns this red.
#
# The range runs from the top of the file to the `## 3. Loop` heading; the guard below
# requires its last line to BE that heading, so a renamed heading -- which runs the range
# on to end of file, over text outside the range -- fails loud. Needles are read over the
# whitespace-squeezed span, so a markdown wrap does not fail a clause that is present;
# each ADR needle sits on one blockquote line, since `> ` prefixes survive the squeeze.
t6_rl="$ROOT/skills/run-loop/SKILL.md"
t6_raw="$(sed -n '1,/^## 3\. Loop/p' "$t6_rl")"
t6_last="$(printf '%s\n' "$t6_raw" | tail -1)"
case "$t6_last" in
  '## 3. Loop'*) ok 'run-loop top-through-§2 range extracted (ends at the ## 3. Loop heading)' ;;
  *) bad 'run-loop top-through-§2 range extracted (ends at the ## 3. Loop heading)' "last line: $t6_last" ;;
esac
t6_range="$(_rc_sq "$t6_raw")"

t6_branch="$(_rc_site "$t6_rl" '^- \*\*Branch\.\*\*' "header comment states\.")"
[ -n "$t6_branch" ] && ok 'run-loop §1 Branch bullet extracted (anchor holds)' \
  || bad 'run-loop §1 Branch bullet extracted (anchor holds)' 'empty -- the bullet moved or was rewritten'
under_ceiling 'run-loop §1 Branch span stays inside its ceiling (end anchor still matches)' "$t6_branch"
t6_branch="$(_rc_sq "$t6_branch")"
has 'Branch: the integration base is named by its key' '`integration_branch`' "$t6_branch"
has 'Branch: and by the file that holds its value' '.agents/project-overrides.yaml' "$t6_branch"
has 'Branch: the absent-key fallback is pointed at, not stated' "\`templates/task-packet.yaml\`'s header comment states" "$t6_branch"
t6_vals="$(printf '%s\n' "$t6_raw" | grep -nE '\(default |default `|else `main`')"
[ -z "$t6_vals" ] && ok 'run-loop top through §2 states no default value' \
  || bad 'run-loop top through §2 states no default value' "found: $(printf '%s' "$t6_vals" | head -1)"

while IFS='|' read -r t6_label t6_kept t6_moved t6_adr; do
  [ -n "$t6_label" ] || continue
  has "run-loop keeps one clause: $t6_label" "$t6_kept" "$t6_range"
  case "$t6_range" in
    *"$t6_moved"*) bad "run-loop carries no copy of the moved reason: $t6_label" "still present: $t6_moved" ;;
    *) ok "run-loop carries no copy of the moved reason: $t6_label" ;;
  esac
  t6_adr_file="$(ls "$ROOT"/docs/adr/"$t6_adr"-*.md 2>/dev/null | head -1)"
  t6_sect="$(sed -n "/^## Relocated from skills ([0-9-]*) — the run-loop skill's/,\$p" "$t6_adr_file" 2>/dev/null)"
  has "ADR $t6_adr's run-loop relocation section holds it: $t6_label" "$t6_moved" "$(_rc_sq "$t6_sect")"
done <<'T6_MOVES'
why the report contract is Read|unread, you render from memory.|the exact failure these files exist to prevent|0023
why the drift scan reads every ref|usually lives in already-merged history|almost never fires|0025
why an unknown threshold is never a number|and never a number, so the run reads as unmeasured|silence would read as a measured run|0028
why the loop never runs unmarked|without a mark the guard's edit block has nothing to block|driver mode's whole safety property|0028
why the lint paths are literal|which driver mode refuses:|cannot prove where the write lands|0028
why entry routes on status|a completed run leaves its checkpoint on disk too|existence alone cannot tell|0005
why an unrecognised status writes nothing|the checkpoint is untracked, so a guess at it cannot be undone|the least recoverable move|0005
why the findings carry is inside the one write|a crash in between loses it|exists for any interval without the index|0022
why runstate.sh findings is not a source|it strips the single-quoting the durable-state writer applies|tab-separated projection for one caller|0022
T6_MOVES

printf '\n== run-loop §3 steps 1-5: values by key only, reasons one clause with the rest in their ADRs (skill-prompt-trim T7) ==\n'
# Same three rules as the T6 section above, over the next range: from the `## 3. Loop`
# heading to the end of step 5 (**Act on `route`'s action**), i.e. up to the step-6
# **Land** line. Capability 4: the Branch step named the integration branch's fallback
# chain and the Form step stated `bundle-cap`'s default; both now name the key and the
# file (or the printed `CAP=`) instead. Capability 3: each row below pins the clause
# the skill kept, the moved wording gone from the range, and that wording present in the
# owning ADR's run-loop relocation section. The range also carries no task-id history
# and no "as today" comparison, except the two pinned phrases the refusal and
# continuation sections above read on both driver surfaces, and every dispatch in it
# keeps its `routing.sh resolve`.
#
# The guard below requires the range's last line to BE the step-6 line, so a renamed
# step -- which runs the range on to end of file, over text outside it -- fails loud.
t7_rl="$ROOT/skills/run-loop/SKILL.md"
t7_raw="$(sed -n '/^## 3\. Loop/,/^6\. \*\*Land/p' "$t7_rl")"
t7_first="$(printf '%s\n' "$t7_raw" | head -1)"
t7_last="$(printf '%s\n' "$t7_raw" | tail -1)"
case "$t7_first|$t7_last" in
  '## 3. Loop'*'|6. **Land'*) ok 'run-loop §3 steps 1-5 range extracted (## 3. Loop heading to the step-6 Land line)' ;;
  *) bad 'run-loop §3 steps 1-5 range extracted (## 3. Loop heading to the step-6 Land line)' "first: $t7_first / last: $t7_last" ;;
esac
t7_range="$(_rc_sq "$t7_raw")"

t7_branch="$(_rc_site "$t7_rl" '^1\. \*\*Branch\.\*\*' 'if it already exists\.')"
[ -n "$t7_branch" ] && ok 'run-loop §3 Branch step extracted (anchor holds)' \
  || bad 'run-loop §3 Branch step extracted (anchor holds)' 'empty -- the step moved or was rewritten'
under_ceiling 'run-loop §3 Branch span stays inside its ceiling (end anchor still matches)' "$t7_branch"
t7_branch="$(_rc_sq "$t7_branch")"
has 'Branch step: the integration base is named by its key' '`integration_branch`' "$t7_branch"
has 'Branch step: and by the file that holds its value' '`.agents/project-overrides.yaml`' "$t7_branch"
has "Branch step: the fallback is pointed at §1's Branch bullet, not stated" "its absent-key fallback as §1's **Branch** bullet states" "$t7_branch"
has 'Form step: the bundle cap is read from bundle-cap, named by its key and file' \
  '`runstate.sh bundle-cap` prints `CAP=<n>`, the cap in effect, from `bundle_max_tasks` in `.agents/project-overrides.yaml`' "$t7_range"
t7_vals="$(printf '%s\n' "$t7_raw" | grep -nE '\(default |default `|else `develop`|else `main`|inert until')"
[ -z "$t7_vals" ] && ok 'run-loop §3 steps 1-5 state no default value' \
  || bad 'run-loop §3 steps 1-5 state no default value' "found: $(printf '%s' "$t7_vals" | head -1)"

# History: no task id in parentheses, and no "today" beyond the two pinned phrases.
t7_ids="$(printf '%s\n' "$t7_raw" | grep -nE '\(T[0-9]+[;)]')"
[ -z "$t7_ids" ] && ok 'run-loop §3 steps 1-5 carry no task-id history' \
  || bad 'run-loop §3 steps 1-5 carry no task-id history' "found: $(printf '%s' "$t7_ids" | head -1)"
t7_today="${t7_range//proceeds to the reviewer dispatch exactly as today/}"
t7_today="${t7_today//reviewer exactly as today/}"
case "$t7_today" in
  *today*) bad 'run-loop §3 steps 1-5 carry no "as today" history outside the two pinned phrases' \
             "found: $(printf '%s' "$t7_today" | grep -oE '.{40}today.{0,10}' | head -1)" ;;
  *) ok 'run-loop §3 steps 1-5 carry no "as today" history outside the two pinned phrases' ;;
esac

# Every dispatch in the range keeps its model resolution beside it.
while IFS='|' read -r t7_label t7_needle; do
  [ -n "$t7_label" ] || continue
  has "run-loop §3 keeps routing.sh resolve beside: $t7_label" "$t7_needle" "$t7_range"
done <<'T7_RESOLVE'
the packet's first dispatch|routing.sh resolve <agent>` for the `--agent` from §3.3
the reviewer dispatch|routing.sh resolve reviewer`
the attempt re-dispatch|routing.sh resolve <agent>` for the packet's `--agent`
the continuation dispatch|routing.sh resolve implementer`
the decider dispatch|routing.sh resolve chief-engineer`
T7_RESOLVE

while IFS='|' read -r t7_label t7_kept t7_moved t7_adr; do
  [ -n "$t7_label" ] || continue
  has "run-loop keeps one clause: $t7_label" "$t7_kept" "$t7_range"
  case "$t7_range" in
    *"$t7_moved"*) bad "run-loop carries no copy of the moved reason: $t7_label" "still present: $t7_moved" ;;
    *) ok "run-loop carries no copy of the moved reason: $t7_label" ;;
  esac
  t7_adr_file="$(ls "$ROOT"/docs/adr/"$t7_adr"-*.md 2>/dev/null | head -1)"
  t7_sect="$(sed -n "/^## Relocated from skills ([0-9-]*) — the run-loop skill's/,\$p" "$t7_adr_file" 2>/dev/null)"
  has "ADR $t7_adr's run-loop relocation section holds it: $t7_label" "$t7_moved" "$(_rc_sq "$t7_sect")"
done <<'T7_MOVES'
why the membership is formed first|the sweep below exempts every member of a paused bundle, not just the cursor|before it decides what stays exempt|0005
when the membership is recovered|(a session picking this packet back up, after a compaction or through `/gaffer:resume`)|`record-start` already covers the membership an earlier session|0005
why an empty --list skips the real sweep|skip `task-status` entirely when `--list` printed nothing|nothing for the real sweep to close either|0005
what a non-zero group exit means|(stderr only, no `HANDOFF=`/`GROUP=` line) leaves no group to read|`group`'s own `die` paths|0020
why a HANDOFF=unknown tier is judged as for any single packet|decide its `tier`/`--agent` as for any single packet|non-gspec packet never had it|0020
why a bundle is never design-heavy|a multi-member `MEMBERS` is never `design-heavy`.|by construction, so this can only|0020
why a non-zero group exit is reported|since a silent fallback reads as "nothing to bundle"|rather than "the check itself failed."|0023
why $SWEEP is carried to the report|this sweep is the only point that knows which packets are newly closed|never filtered by `--since`|0023
why SINCE is captured before the start|to this packet's own decisions|never one already reported for an earlier packet|0023
why the driver appends no contract line|which `runstate.sh handoff` adds itself|a driver that forgets this step entirely|0029
why discard-advance stashes|which the guard hard-denies; one stash covers the whole bundle's uncommitted work|nothing was ever committed member-by-member|0028
why append-task merges at once|so it is runnable in this run only once that branch is merged|reads the plan from the integration branch|0028
why the merged branch is deleted|left in place, it lacks the appended task's work and the re-run fails the same way|still points at the decider commit|0028
why hand-off-feature assumes no prefix|a resume, a decider `reorder`, or an `append-task` can move one or leave it out|the loop's own chosen order|0028
T7_MOVES

printf '\n== run-loop §3 step 6 to the end: values by key only, reasons one clause with the rest in their ADRs (skill-prompt-trim T8) ==\n'
# Same three rules as the T6 and T7 sections above, over the last range: from the
# step-6 **Land** line to end of file (steps 7-8, `## 4. Termination` and `## Never`).
# Capability 4: the Advance step stated `periodic-pause`'s fallback for an unset key;
# it now names `pause_every_packets` and its file, and `EVERY=` is where the value is
# read. Capability 3: each row below pins the clause the skill kept, the moved wording
# gone from the range, and that wording present in the owning ADR's run-loop relocation
# section. The range carries no task-id history and no "today" comparison except the
# `rc_land` end anchor the T4 section above reads, and both dispatches keep their
# `routing.sh resolve`.
#
# The guard requires the range to START at the step-6 line and to hold both later
# headings, so a renamed step -- which empties the range -- or a renamed heading fails
# loud rather than scanning nothing.
t8_rl="$ROOT/skills/run-loop/SKILL.md"
t8_raw="$(sed -n '/^6\. \*\*Land/,$p' "$t8_rl")"
t8_first="$(printf '%s\n' "$t8_raw" | head -1)"
case "$t8_first" in
  '6. **Land'*) ok 'run-loop step 6 to end range extracted (starts at the step-6 Land line)' ;;
  *) bad 'run-loop step 6 to end range extracted (starts at the step-6 Land line)' "first: $t8_first" ;;
esac
case "$t8_raw" in
  *'## 4. Termination'*'## Never'*) ok 'run-loop step 6 to end range holds ## 4. Termination and ## Never' ;;
  *) bad 'run-loop step 6 to end range holds ## 4. Termination and ## Never' 'a heading moved or was renamed' ;;
esac
t8_range="$(_rc_sq "$t8_raw")"

has 'Advance step: the periodic pause is named by its key and file, read through EVERY=' \
  '`EVERY=` read from `pause_every_packets` in `.agents/project-overrides.yaml`' "$t8_range"
t8_vals="$(printf '%s\n' "$t8_raw" | grep -nE '\(default |default `|and the default|missing/invalid/0|after two runs|211 files')"
[ -z "$t8_vals" ] && ok 'run-loop step 6 to end states no default value and no measurement' \
  || bad 'run-loop step 6 to end states no default value and no measurement' "found: $(printf '%s' "$t8_vals" | head -1)"

# History: no task id, and no "today" beyond the rc_land end anchor.
t8_ids="$(printf '%s\n' "$t8_raw" | grep -nE '\(T[0-9]+[;)]|T[0-9]+'"'"'s |read T[0-9]+ ')"
[ -z "$t8_ids" ] && ok 'run-loop step 6 to end carries no task-id history' \
  || bad 'run-loop step 6 to end carries no task-id history' "found: $(printf '%s' "$t8_ids" | head -1)"
t8_today="${t8_range//reads exactly as it does today: nothing staged/}"
case "$t8_today" in
  *today*) bad 'run-loop step 6 to end carries no "today" history outside the rc_land anchor' \
             "found: $(printf '%s' "$t8_today" | grep -oE '.{40}today.{0,10}' | head -1)" ;;
  *) ok 'run-loop step 6 to end carries no "today" history outside the rc_land anchor' ;;
esac

# Every dispatch in the range keeps its model resolution beside it.
while IFS='|' read -r t8_label t8_needle; do
  [ -n "$t8_label" ] || continue
  has "run-loop step 6 to end keeps routing.sh resolve beside: $t8_label" "$t8_needle" "$t8_range"
done <<'T8_RESOLVE'
the periodic-review decider dispatch|routing.sh resolve chief-engineer`
the whole-branch review dispatch|routing.sh resolve reviewer`
T8_RESOLVE

while IFS='|' read -r t8_label t8_kept t8_moved t8_adr; do
  [ -n "$t8_label" ] || continue
  has "run-loop keeps one clause: $t8_label" "$t8_kept" "$t8_range"
  case "$t8_range" in
    *"$t8_moved"*) bad "run-loop carries no copy of the moved reason: $t8_label" "still present: $t8_moved" ;;
    *) ok "run-loop carries no copy of the moved reason: $t8_label" ;;
  esac
  t8_adr_file="$(ls "$ROOT"/docs/adr/"$t8_adr"-*.md 2>/dev/null | head -1)"
  t8_sect="$(sed -n "/^## Relocated from skills ([0-9-]*) — the run-loop skill's/,\$p" "$t8_adr_file" 2>/dev/null)"
  has "ADR $t8_adr's run-loop relocation section holds it: $t8_label" "$t8_moved" "$(_rc_sq "$t8_sect")"
done <<'T8_MOVES'
why cursor leads the trailer block|a resume adopts by the FIRST `[orch packet:]` trailer|block is load-bearing, not cosmetic|0005
what dropping schema does|`write` refuses content without it.|fails loudly rather than quietly|0005
what dropping run_id costs|losing it fails nothing at the write|the most expensive of these to lose|0005
why a periodic pause never fires on its own|so a periodic pause never fires on its own|halts an unattended run until a human resumes it|0017
why the cursor skips every member|never assume the members are a consecutive prefix of `pending`, whose order is not the plan's|the same rule §3.5's `discard-advance` uses|0020
why every driver_* key is carried|which `claim-driver` makes once at §2 and never re-makes|what tells a crashed run apart|0020
what an omitted findings entry leaves|An omitted entry is unlinked, not edited out|the body stays on disk with nothing left pointing at it|0022
why carried keys are copied from disk|so the file's quoting survives|a value restated from memory of an earlier read|0022
why each swept packet gets a warning line|since that sweep's record is the only thing marking these as new|record of what it just closed is the only thing marking these as new|0023
why a failed capability call is an alert|as an alert alongside the ✅/🔁 line|the packet still landed, so this is an alert|0023
why a capability flip carries no warning glyph|since a capability flip is not a packet|the conventions reserve that glyph|0023
why the stop report reads the whole-run digest|whether or not this session was the one that ran it|a compaction or a resumed session reads the same report|0023
why a landed bundle's line names every member|A bundle is ONE packet|would read a four-task bundle as one task|0023
why membership is confirmed from the branch|the commit's own trailers record what landed|before the packet even started|0023
why both branches are searched|§3.7 has already merged each earlier bundle's commit into the integration branch|happens to have run|0023
why the trailers are read in commit order|`<cursor>` first (§3.6 writes it first)|load-bearing there for orphan-adopt|0023
why the stale-finding drop passes $MEMBERS|FINISHED="${FINISHED:+${FINISHED},}$MEMBERS"|already accept a comma list|0024
why a termination finding adds no expiry rule|expiry stays the positive-evidence rule (ADR 0024)|which is truthful|0024
what record-completion does at the land|It flips each member's task in plan order|a bundle is always one feature|0025
what a HALT= leaves uncommitted|do not commit, so no part of the bundle lands on its own|stays an uncommitted edit on the branch|0025
why the landing restore is from the index|so the packet's own staged PRD edit survives|for the mirror of this reason|0025
why the reconcile commit follows the merge|so a flip never reaches the integration branch ahead of the work it records|leaves the checkout on that branch|0025
why the end-of-run restore is the HEAD form|restore every `STAGE=` path with `git checkout HEAD -- <path>`|resets the index as well as the working tree|0025
why a feature is held|one unglyphed line per `HELD=<slug>\t<reason>` line|matches no capability, so every flip|0025
why the review diff is bounded to this run|since a branch-vs-base diff re-presents earlier runs' already-reviewed commits|211 files and about 30,000|0026
when the branch-vs-base fallback applies|such a run has no narrower boundary to offer|no run-owned trailer to anchor a parent on|0026
why each review note becomes a finding|since the findings index, not the review file, is what the next run can see|a note left only in that file|0026
why the driver records nothing after a periodic review|and record nothing yourself, since the review writes its own `record-review` record|is already on disk when the line returns|0024
why a second check-status refusal still carries on|On a second `check-status` refusal, carry on to the next packet|the record, not the line, decides whether the review counted|0024
T8_MOVES

# The Advance step's periodic-review paragraph, read on its own: its rules survive the
# trim (the dispatch's model resolution, an `unmeasured` count read as due, the driver
# recording nothing), and its pointer at `agents/loop-driver.md` claims the same rule,
# not the same words -- the loop-driver copy is untrimmed. The guard fails loud on an
# empty extraction, so a renamed opening line cannot pass by scanning nothing.
t8_pr_raw="$(sed -n '/\*\*With neither pause taking the run, check the periodic review/,/^## 4\. Termination/p' "$t8_rl")"
case "$t8_pr_raw" in
  *'**With neither pause taking the run'*'## 4. Termination'*) ok 'run-loop Advance periodic-review paragraph extracted' ;;
  *) bad 'run-loop Advance periodic-review paragraph extracted' 'opening line or ## 4. Termination not found' ;;
esac
t8_pr="$(_rc_sq "$t8_pr_raw")"
while IFS='|' read -r t8_label t8_needle; do
  [ -n "$t8_label" ] || continue
  has "run-loop periodic-review paragraph keeps: $t8_label" "$t8_needle" "$t8_pr"
done <<'T8_PR_KEPT'
the decider dispatch's model resolution|routing.sh resolve chief-engineer`
an unmeasured count is due|On `DUE=yes` — **including when any of the four reads `unmeasured`**
the driver records nothing|and record nothing yourself
a second refusal carries on|On a second `check-status` refusal, carry on to the next packet
unmeasured is never rendered as 0|with `unmeasured` rendered as the word `unmeasured` and never as `0`
the review's counts come through run-digest|through `run-digest`'s `review` line, never from its status line or its result file
the loop-driver pointer claims the same rule|(`agents/loop-driver.md` §The periodic review carries the same rule)
T8_PR_KEPT
case "$t8_pr" in
  *'in the same words'*|*'states it in the'*) bad 'run-loop periodic-review paragraph claims no identical wording with loop-driver' 'still claims the same words' ;;
  *) ok 'run-loop periodic-review paragraph claims no identical wording with loop-driver' ;;
esac

printf '\n----------------------------------------\n'
printf 'report-conventions: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
