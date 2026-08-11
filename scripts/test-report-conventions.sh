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

printf '\n----------------------------------------\n'
printf 'report-conventions: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
