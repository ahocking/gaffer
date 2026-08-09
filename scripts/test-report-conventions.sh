#!/usr/bin/env bash
# =============================================================================
# test-report-conventions.sh — the report-format delivery layers (L2/L3)
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

printf '\n----------------------------------------\n'
printf 'report-conventions: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
