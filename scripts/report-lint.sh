#!/usr/bin/env bash
# =============================================================================
# report-lint.sh — check a RENDERED loop report against the digest it came from
# =============================================================================
# report-render-conformance T2. Usage:
#
#   report-lint.sh --shape <B|C> <report-file> <digest-file>
#
# The caller names the shape; this script never infers it. It is handed one
# report and the `runstate.sh run-digest` output that report was rendered from,
# and it reads nothing else but `templates/report-conventions.md`. It never
# inspects a turn or a transcript, so no judgement of the form "is this a
# report?" exists anywhere in it — the reason a Stop-hook validator was
# rejected (ADR 0023) does not apply.
#
# Output, on stdout, exactly one of:
#   REPORT_LINT=clean
#   REPORT_LINT=findings n=<k>      then one  FINDING=<rule>\t<line>\t<detail>
#                                   per finding (<line> is 1-based in the report)
#   REPORT_LINT=unjudged            then one  REASON=<why>
#
# Exit status is 0 on EVERY path, usage errors included: a finding changes
# nothing about the run, and a non-zero status reaching the renderer would.
# `unjudged` is not `clean` — it means the check could not look.
#
# Rules (the <rule> field):
#   unknown-glyph   a glyph outside the conventions' glyph vocabulary
#   two-glyphs      two or more glyphs on one line
#   section-order   section headings out of the fixed tally order (and, in
#                   shape B, a heading glyph the header tally does not carry)
#   decision-count  shape B: header 🔀 figure != decision blocks + "N more"
#   untitled-id     a digest id whose first appearance has no bold title before
#                   it. Ids come ONLY from the digest's packet / decision /
#                   handoff-feature lines, so a sha or branch never fires.
#   empty-section   a section written as "none" rather than omitted (except
#                   shape C's `Will need you`, where "nothing expected" is real)
#
# Constructs the shapes themselves define are conformant, not findings: the
# tally line (the report's first non-blank line) may carry many glyphs; shape
# C's `> **Phase N — …**` lines may too; ▶ headings (`▶ Next`, C's `▶ Session`
# and `▶ Stops at`) are outside the tally's order; and the state line
# (`` `<branch>` @ `<sha>` ``) is never searched for ids.
#
# DERIVED, NOT FROZEN: the glyph vocabulary is read from the conventions' glyph
# table and the section order from its fixed-tally line (the line after
# "# Fixed order, omitting any bucket that is zero:"), each scanned for glyph
# tokens in order. Reorder the authority and this re-derives from it.
# ORCH_REPORT_LINT_CONVENTIONS overrides the conventions path (tests only).
#
# WRITES NOTHING. No temp files, no run-state, no outcome records: the whole
# check is two pipes and one awk over files it only reads. Glyphs are matched
# as UTF-8 byte sequences under LC_ALL=C, so it needs no python3/perl and
# behaves the same under BSD awk, gawk and mawk.
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONV="${ORCH_REPORT_LINT_CONVENTIONS:-$HERE/../templates/report-conventions.md}"

# One glyph token: a codepoint in U+2300–23FF, U+2500–27BF, U+2B00–2BFF or
# U+1F000–1FAFF, plus an optional VS16. Arrows (U+2190–21FF: `→`), `·`, `—`
# and `›` fall outside, so the decision block's punctuation is never a glyph.
GLYPH_RE=$'(\xe2[\x8c-\x8f\x94-\x9e\xac-\xaf][\x80-\xbf]|\xf0\x9f[\x80-\xab][\x80-\xbf])(\xef\xb8\x8f)?'

unjudged() { printf 'REPORT_LINT=unjudged\nREASON=%s\n' "$1"; exit 0; }

# --- arguments ---------------------------------------------------------------
shape=""; report=""; digest=""; pos=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shape)   [ $# -ge 2 ] || unjudged usage; shape="$2"; shift 2 ;;
    --shape=*) shape="${1#--shape=}"; shift ;;
    --*)       unjudged usage ;;
    *)
      case "$pos" in
        0) report="$1" ;;
        1) digest="$1" ;;
        *) unjudged usage ;;
      esac
      pos=$((pos + 1)); shift ;;
  esac
done
[ -n "$report" ] && [ -n "$digest" ] || unjudged usage
case "$shape" in
  B|C) ;;
  *) unjudged unknown-shape ;;
esac

# --- fail soft: every direction the inputs can be wrong ------------------------
# An EMPTY digest is valid (a fresh run's kickoff has no ids) and is judged.
[ -e "$digest" ] || unjudged digest-missing
{ [ -f "$digest" ] && [ -r "$digest" ]; } || unjudged digest-unreadable
{ [ -f "$report" ] && [ -r "$report" ]; } || unjudged report-unreadable
grep -q '[^[:space:]]' "$report" 2>/dev/null || unjudged report-empty
{ [ -f "$CONV" ] && [ -r "$CONV" ]; } || unjudged conventions-unreadable

export LC_ALL=C

# --- derive the vocabulary and the order from the conventions ------------------
_first_glyphs() { # scan stdin lines -> every glyph token, in order, VS16 dropped
  G="$GLYPH_RE" awk '{
    s = $0
    while (match(s, ENVIRON["G"])) {
      t = substr(s, RSTART, RLENGTH); gsub(/\357\270\217/, "", t); print t
      s = substr(s, RSTART + RLENGTH)
    }
  }'
}

vocab="$(G="$GLYPH_RE" awk '
  /^# --- THE GLYPH VOCABULARY/ { inb = 1; next }
  inb && /^# ---/ { exit }
  inb && seen && /^#[ ]*$/ { exit }
  inb {
    if (match($0, "^#[ ]+" ENVIRON["G"])) {
      t = substr($0, RSTART, RLENGTH); sub(/^#[ ]+/, "", t)
      gsub(/\357\270\217/, "", t); print t; seen = 1
    }
  }' "$CONV" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
order="$(awk '/# Fixed order, omitting any bucket that is zero:/ { getline; print; exit }' \
           "$CONV" 2>/dev/null | tr -d '\r' | _first_glyphs | tr '\n' ' ')"
case "$vocab" in *[![:space:]]*) ;; *) unjudged conventions-no-vocabulary ;; esac
case "$order" in *[![:space:]]*) ;; *) unjudged conventions-no-tally-order ;; esac

# --- ids: ONLY from the digest's own packet / decision / handoff-feature lines -
ids="$(tr -d '\r' < "$digest" | awk -F'\t' '
  ($1 == "packet" || $1 == "decision" || $1 == "handoff-feature") && $2 != "" && !seen[$2]++ { print $2 }')"

# --- the rules ----------------------------------------------------------------
out="$(LINT_G="$GLYPH_RE" LINT_VOCAB="$vocab" LINT_ORDER="$order" LINT_IDS="$ids" \
       LINT_SHAPE="$shape" awk '
function norm(t) { gsub(/\357\270\217/, "", t); return t }
function glyphs(s, arr,   n, t) {
  n = 0
  while (match(s, G)) {
    t = substr(s, RSTART, RLENGTH); arr[++n] = norm(t)
    s = substr(s, RSTART + RLENGTH)
  }
  return n
}
function find(rule, ln, detail) {
  gsub(/\t/, " ", detail)
  nf++; F[nf] = "FINDING=" rule "\t" ln "\t" detail
}
function idchar(c) { return c ~ /[A-Za-z0-9._\/-]/ }
# 1-based position of id as a whole token in s, else 0. A trailing "." counts
# as punctuation, not part of the id, when nothing id-like follows it.
function idpos(s, id,   start, p, at, b, a, a2, L) {
  L = length(id); start = 1
  while ((p = index(substr(s, start), id)) > 0) {
    at = start + p - 1
    b  = (at > 1) ? substr(s, at - 1, 1) : ""
    a  = substr(s, at + L, 1); a2 = substr(s, at + L + 1, 1)
    if ((b == "" || !idchar(b)) && (a == "" || !idchar(a) || (a == "." && (a2 == "" || !idchar(a2)))))
      return at
    start = at + 1
  }
  return 0
}
BEGIN {
  G = ENVIRON["LINT_G"]; shape = ENVIRON["LINT_SHAPE"]
  n = split(ENVIRON["LINT_VOCAB"], v, " "); for (i = 1; i <= n; i++) vocab[v[i]] = 1
  n = split(ENVIRON["LINT_ORDER"], o, " "); for (i = 1; i <= n; i++) ord[o[i]] = i
  orderstr = ENVIRON["LINT_ORDER"]; sub(/[ ]+$/, "", orderstr)
  nids = split(ENVIRON["LINT_IDS"], ids, "\n")
  DOT = "\302\267"; DASH = "\342\200\224"; NDASH = "\342\200\223"
}
{ sub(/\r$/, ""); L[NR] = $0 }
END {
  T = 0
  for (i = 1; i <= NR; i++) if (L[i] ~ /[^ \t]/) { T = i; break }
  ntal = glyphs(L[T], tg); for (k = 1; k <= ntal; k++) intally[tg[k]] = 1

  lastord = 0; lastg = ""; sec = ""; seclabel = ""; blocks = 0; deferred = 0
  for (i = 1; i <= NR; i++) {
    s = L[i]
    if (s !~ /[^ \t]/) continue
    isquote = (s ~ /^[ ]*>/); isheading = 0
    delete g; ng = glyphs(s, g)

    # unknown-glyph
    for (k = 1; k <= ng; k++)
      if (!(g[k] in vocab)) find("unknown-glyph", i, "glyph " g[k] " is not in the conventions vocabulary")

    # two-glyphs (the tally line and shape C phase lines are shape-defined)
    isphase = (shape == "C" && s ~ /^[ ]*>[ ]*\*\*Phase[ ]/)
    if (ng >= 2 && i != T && !isphase)
      find("two-glyphs", i, ng " glyphs on one line; one glyph, one meaning, never two on a line")

    # headings: flush-left, after the tally, opening with a glyph
    if (i != T && !isquote && match(s, "^" G)) {
      hg = norm(substr(s, RSTART, RLENGTH)); isheading = 1
      seclabel = ""
      if (match(s, /\*\*[^*]+\*\*/)) seclabel = substr(s, RSTART + 2, RLENGTH - 4)
      sec = hg
      if (hg in ord) {
        if (ord[hg] < lastord)
          find("section-order", i, "heading " hg " after " lastg "; the fixed tally order is " orderstr)
        else { lastord = ord[hg]; lastg = hg }
        if (shape == "B" && !(hg in intally))
          find("section-order", i, "heading " hg " has no figure in the header tally")
      }
    }

    # decision blocks (shape B counts them against the header figure)
    if (isquote && s ~ ("^[ ]*>[ ]*\\*\\*[0-9]+[ ]*" DOT)) blocks++
    # Only the closing italic deferral line the conventions define counts
    # (`*<N> more, lower stakes ...*`) -- never an "N more" inside a question,
    # option or consequence line.
    if (sec == "\360\237\224\200" && match(s, /^[ ]*>[ ]*[*_][0-9]+ more/)) {
      t = substr(s, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); deferred += t + 0
    }

    # empty-section: what is left after the glyph, the bold label and a separator
    r = s
    sub(/^[ ]*>?[ ]*/, "", r)
    if (match(r, "^" G)) r = substr(r, RLENGTH + 1)
    sub(/^[ ]*/, "", r)
    ownlabel = 0
    if (match(r, /^\*\*[^*]*\*\*/)) { r = substr(r, RLENGTH + 1); ownlabel = 1 }
    while (1) {
      if (match(r, "^([ ]|:|-|" DASH "|" NDASH ")+")) { r = substr(r, RLENGTH + 1); continue }
      break
    }
    gsub(/[ .*_]+$/, "", r); gsub(/^[*_]+/, "", r); r = tolower(r)
    if (r ~ /^\(?(none|nothing|n\/a)\)?$/) {
      # Shape C exception covers the `Will need you` heading and its unlabelled
      # continuation -- not a sibling construct like the Wont-touch line that
      # merely follows it with a bold label of its own.
      willneed = (shape == "C" && index(seclabel, "Will need you") > 0 && (isheading || !ownlabel))
      if (!willneed) find("empty-section", i, "a section written as \"" r "\"; omit an empty section instead")
    }

    # untitled-id: first appearance of each digest id, never in the state line
    isstate = (isquote && s ~ /`[^`]+`[ ]*@[ ]*`[^`]+`/)
    if (!isstate) {
      for (k = 1; k <= nids; k++) {
        id = ids[k]
        if (id == "" || (id in seenid)) continue
        p = idpos(s, id)
        if (p == 0) continue
        seenid[id] = 1
        pre = substr(s, 1, p - 1)
        if (!match(pre, /\*\*[^*]*[A-Za-z][^*]*\*\*/))
          find("untitled-id", i, "id " id " first appears with no bold title before it")
      }
    }
  }

  # decision-count (shape B): header 🔀 figure vs blocks + deferral
  if (shape == "B") {
    fig = 0
    if (match(L[T], "\360\237\224\200(\357\270\217)?[ ]*\\*\\*[0-9]+")) {
      t = substr(L[T], RSTART, RLENGTH); gsub(/[^0-9]/, "", t)
      # the glyph bytes carry no ASCII digits, so t is the figure alone
      fig = t + 0
    }
    if (fig != blocks + deferred)
      find("decision-count", T, "header figure " fig " but the body has " blocks " decision blocks + " deferred " deferred")
  }

  if (nf == 0) print "REPORT_LINT=clean"
  else { print "REPORT_LINT=findings n=" nf; for (k = 1; k <= nf; k++) print F[k] }
}' "$report" 2>/dev/null)"
rc=$?

[ "$rc" -eq 0 ] && [ -n "$out" ] || unjudged lint-error
printf '%s\n' "$out"
exit 0
