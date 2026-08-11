#!/usr/bin/env bash
# =============================================================================
# migrate.sh — retrofit a consumer repo to the current plugin layout (v2.0.0)
# =============================================================================
# The deterministic half of `/gaffer:migrate`. It DETECTS what shape a
# repo is in, PLANS the moves, APPLIES the mechanical ones, and VERIFIES the
# result through the adapter. Judgment — reconciling a hand-written roadmap's
# prose, deciding whether to regenerate a legacy plan — lives in the skill.
#
# WHY VERIFY IS NOT OPTIONAL. The v2.0.0 move renames
# `gspec/features/<slug>.plan.md` to `gspec/tasks/<slug>.md`. Renaming is easy
# and the result LOOKS right — but a plan whose task lines the adapter cannot
# parse yields an EMPTY backlog, which reads as "nothing to do" rather than as
# "unreadable". Both production repos this was built against hit exactly that
# (0 packets from a pure rename) before the adapter learned their legacy task
# shapes. So `apply` always ends by counting real packets, and says so.
#
# Subcommands:
#   detect  [root]   what version/shape is this repo in? Prints FROM=<state> plus
#                    one FINDING= line per thing that needs doing. Read-only.
#   plan    [root]   the ordered move list, as human-readable steps. Read-only.
#   apply   [root]   perform the MECHANICAL moves (git mv where the repo is a git
#                    repo, else mv), then verify. Refuses on a dirty tree unless
#                    --force: a migration you cannot `git diff` is not reviewable.
#   verify  [root]   post-migration checks: paths, adapter parse, packet counts.
#   findings-audit [root]   READ-ONLY (run-state-cleanup T18): per findings-index
#                    entry, without ever opening a body — whether it names
#                    packets, a live|dead|unknown verdict, summary/body byte
#                    counts, plus index and body totals for the run.
#                    Finished-ness for a named packet reads ONLY the gspec
#                    checkbox (via $ADAPTER's task-status) or an
#                    `[orch packet:<id>]` commit trailer — NEVER the legacy
#                    `done:` block, so this and the backlog.done drain below
#                    are order-independent within one pass.
#
# WHAT IT WILL NOT DO (the skill's job, with a human):
#   - convert legacy task lines to canonical form. That edits CHECKED tasks,
#     which gspec's task-immutability floor blocks and which destroys the record
#     of what was built. Regeneration via /gspec-plan is the supported path.
#   - translate a roadmap's prose (`## Notes`, `## Unsequenced`) — only the
#     structured `features:` entries convert; prose is reported for a human.
#   - delete anything, including a finding: `apply` drops the legacy
#     `backlog.done` block (run-state-cleanup T17 — completion is derived from
#     the gspec checkbox now) but deletes NO finding, ever — the triage of a
#     dead/unknown entry is one entry at a time, the migrate skill's job (T19),
#     never this script's.
#
# Exit codes: 0 = ok / nothing to do; 1 = usage; 2 = migration needed (detect);
#             3 = applied but verification found a problem.
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$HERE/gspec-backlog.sh"

die() { printf 'migrate.sh: %s\n' "$1" >&2; exit "${2:-1}"; }
_root() { printf '%s' "${1:-.}"; }

# --- backlog.done: legacy completion list (run-state-cleanup T17) ------------
# ADR 0025: completion is now derived from the gspec checkbox, so `backlog.done`
# in .agents/run-state.yaml is drained on apply, never migrated anywhere. Every
# read here goes through $ADAPTER's task-status (T2) -- migrate.sh never parses
# gspec/ directly.

# _backlog_done_scan: the ONE classifier every caller below reads from -- the
# reader (_backlog_done_ids), the dropper (_drop_backlog_done), detect, and
# verify all agree with each other by construction, because they all agree
# with this.
#
# Three review rounds each found a NEW valid YAML shape this code mis-parsed
# and silently corrupted (Important 1/2 round 2, Minor 3-7 round 3). Patching
# shape N+1 does not converge -- a gitignored file that is the loop's only
# durable state does not get a fourth chance. So round 4 replaces "best-effort
# parse, then patch the next counterexample" with a CLASSIFIER: every done:
# block is either
#   RECOGNIZED    -- a block sequence of plain scalar items (`- some-id`), at
#                    an indent >= done:'s own indent (both the "indented under
#                    the key" and the "indentless, at the key's own indent"
#                    styles are valid YAML and both count), with interior
#                    blank/comment lines allowed. This is what runstate.sh
#                    would emit if it ever wrote a done: key (it doesn't --
#                    every done: block met here is legacy) and it is the
#                    overwhelmingly common shape in practice.
#   UNRECOGNIZED  -- anything else: a nested-mapping item (`- id: x` with a
#                    continuation line), a folded/literal scalar item (`- >`),
#                    the inline flow form (`done: [a, b]`), a trailing comment
#                    on the key line itself (`done:   # legacy`), a
#                    mapping-valued or scalar-valued `done:` with no sequence
#                    items at all (round 5), an anchored/aliased/tagged item
#                    (`- &a x`, `- *a`, `- !!str x` -- round 5, since dropping
#                    an anchor definition referenced elsewhere corrupts the
#                    reference, not just the dropped block), or any structure
#                    the classifier is not certain of.
# UNRECOGNIZED is reported and NEVER dropped or mutated -- refusing to act
# beats acting wrongly, every time; a block left in place is a human's
# five-minute edit, a silently corrupted run-state is not recoverable.
#
# Prints one line:
#   RECOGNIZED\t<start>\t<end>\t<item_count>\t<had_body>
#   UNRECOGNIZED\t<start>\t<end>\t<reason>
# or nothing if there is no `done:` key directly under `backlog:` at all.
# <start>/<end> are both inclusive, <start> is the `done:` key line itself.
# <had_body> distinguishes a truly bare `done:` (no items, no interior
# blank/comment lines either) from a block that has content but it parsed to
# zero items (Minor 7 round 3 asked detect to tell these apart, not print an
# unqualified "0 id(s)" for both).
#
# The state machine, and the round-4 defect each piece of it closes:
#
# `dindent` is anchored to the indentation of `backlog:`'s own FIRST content
# line (`bindent`), and `done:` is matched only when it sits AT bindent -- a
# `done:` nested deeper, e.g. under `backlog.packets[].done`, is not this
# repo's legacy shape and must not be claimed (Minor 4 round 3).
#
# A block sequence item is accepted at `ind >= dindent`, not `ind > dindent`
# (Minor 5... no: round 4 Defect 1) -- YAML allows list items at the SAME
# indent as their key (the default emission of PyYAML/js-yaml), and the old
# `>` rejected that shape outright, corrupting it (see the classifier's own
# item test below).
#
# The block terminates at the first line AT OR BELOW done:'s own indentation
# that is not a list item, a blank line, or a comment (round 4 Defect 2 --
# the old code's comment already said this at the time, the code did not).
# Blank and comment lines never terminate and never by themselves extend
# `dend` either: `dend` only advances when a real item (recognized or not)
# confirms it, so a comment BANNER that comes after the last item but before
# the block's real terminator is never swept into the deleted range (round 4
# Defect 6) -- while a comment or blank line BETWEEN two items still ends up
# inside the kept range, because the item that follows it extends `dend` past
# it.
#
# A column-0 line that is not blank, `#`, or `-` ends the whole backlog: scan
# outright, whatever its spelling (round 4 Defect 3: the old
# `^[A-Za-z_][A-Za-z0-9_]*:` test did not match a hyphenated key like
# `my-checklist:`, so `inb` never cleared and a later, unrelated `done:` under
# it got claimed and deleted).
_backlog_done_scan() {
  awk '
    function lead(l,    t) { t=l; sub(/[^ ].*/,"",t); return length(t) }
    BEGIN {
      inb=0; found_bindent=0; bindent=-1; state="search"
      dstart=0; dend=0; dindent=0; item_count=0; had_body=0; seen_item=0
      unrec=0; ureason=""; ustart=0; uend=0
    }
    {
      if (state=="done") next
      ind = lead($0)

      if (!inb) {
        if ($0 ~ /^backlog:[[:space:]]*$/) inb=1
        next
      }

      if (state=="search") {
        if (ind==0) {
          if ($0 ~ /^[[:space:]]*$/) next
          inb=0; state="done"; next   # a new top-level key -- Defect 3
        }
        if (!found_bindent) {
          if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
          bindent=ind; found_bindent=1   # Defect 4: anchor to the FIRST content line
        }
        if (ind != bindent) next   # nested content under some other sibling key
        if ($0 ~ /^[[:space:]]*done:[[:space:]]*$/) {
          state="in_done"; dstart=NR; dend=NR; dindent=ind
          item_count=0; had_body=0; seen_item=0
          next
        }
        if ($0 ~ /^[[:space:]]*done:[[:space:]]*#/) {
          unrec=1; ureason="the done: key line carries a trailing comment"
          ustart=NR; uend=NR; inb=0; state="done"; next
        }
        if ($0 ~ /^[[:space:]]*done:[[:space:]]*\[/) {
          unrec=1; ureason="inline flow form (done: [a, b])"
          ustart=NR; uend=NR; inb=0; state="done"; next
        }
        if ($0 ~ /^[[:space:]]*done:[[:space:]]*[^[:space:]]/) {
          unrec=1; ureason="done: carries an inline scalar value"
          ustart=NR; uend=NR; inb=0; state="done"; next
        }
        next   # some other sibling key at bindent (cursor:, pending:, ...)
      }

      # state=="in_done": scanning the interior of the done: block for extent and shape.
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) { had_body=1; next }   # buffered, not committed (Defect 6)
      if (ind >= dindent && $0 ~ /^[[:space:]]*-/) {
        had_body=1; seen_item=1
        rest=$0
        sub(/^[[:space:]]*-[[:space:]]?/,"",rest)
        if (rest ~ /^[[:space:]]*[>|]/) {
          unrec=1; ureason="folded/literal block scalar list item (- >)"; ustart=dstart; uend=NR
        } else if (rest ~ /^[[:space:]]*$/) {
          unrec=1; ureason="list item with no inline value (nested content on the following lines)"; ustart=dstart; uend=NR
        } else if (rest ~ /^[[:space:]]*[A-Za-z0-9_.-]+:([[:space:]]|$)/) {
          unrec=1; ureason="nested mapping list item (- key: value)"; ustart=dstart; uend=NR
        } else if (rest ~ /^[[:space:]]*[][{]/) {
          unrec=1; ureason="flow collection list item"; ustart=dstart; uend=NR
        } else if (rest ~ /^[[:space:]]*[&*!]/) {
          unrec=1; ureason="anchored, aliased or tagged item"; ustart=dstart; uend=NR
        } else {
          item_count++
        }
        dend=NR
        next
      }
      if (ind <= dindent) { state="done"; inb=0; next }   # Defect 2: <=, not "any non-dash line"
      # ind>dindent but not a dash item, and no dash item has been seen yet in
      # this block: this is not a continuation of anything -- it is the done:
      # block own content, and a `done:` block with no sequence items at all
      # is not the "block sequence of plain scalar items" the classifier is
      # certain of (a mapping-valued or scalar-valued `done:`, round 5). Flag
      # it UNRECOGNIZED rather than silently walking past it with item_count
      # staying at 0 -- the old behavior here read as "0 ids parsed, only
      # blank/comment lines", which is false when the block has real content.
      if (!seen_item) {
        unrec=1; ureason="non-sequence content under done: (mapping or scalar value)"
        ustart=dstart; uend=NR
        had_body=1; dend=NR
        next
      }
      # ind>dindent but not a dash item, and at least one dash item HAS been
      # seen: a continuation line of an item already flagged unrecognized
      # above (a folded scalars body, or a nested mappings extra keys), OR a
      # legitimate multi-line plain-scalar continuation of a RECOGNIZED item
      # (`- alpha` / `      t1`) -- extend the range so it is reported
      # accurately, but do not itself flip a recognized block to unrecognized.
      had_body=1
      if (unrec) uend=NR
      dend=NR
      next
    }
    END {
      if (unrec) {
        printf "UNRECOGNIZED\t%d\t%d\t%s\n", ustart, uend, ureason
      } else if (dstart>0) {
        printf "RECOGNIZED\t%d\t%d\t%d\t%d\n", dstart, dend, item_count, had_body
      }
    }
  ' "$1"
}

# The line-number range of a RECOGNIZED `backlog: done:` block, printed as
# "START END" (both inclusive; START is the `done:` key line itself) -- or
# nothing if there is no such block, OR the block exists but is UNRECOGNIZED.
# The dropper (_drop_backlog_done) reads only this, so an unrecognized shape
# is safe by construction: there is nothing here for it to act on.
_backlog_done_range() {
  local out; out="$(_backlog_done_scan "$1")"
  case "$out" in
    RECOGNIZED*) printf '%s %s\n' "$(printf '%s' "$out" | cut -f2)" "$(printf '%s' "$out" | cut -f3)" ;;
  esac
}

# "1" for a RECOGNIZED block whose interior had SOME content (items and/or
# blank/comment lines) before it terminated, "0" for a truly bare `done:`
# (nothing at all before the terminator) or for no block/an unrecognized one.
# Lets detect say "the key is empty" vs "0 ids parsed, only blank/comment
# lines were found" instead of a single ambiguous "0 id(s)" (round 4 Defect 7).
_backlog_done_had_body() {
  local out; out="$(_backlog_done_scan "$1")"
  case "$out" in
    RECOGNIZED*) printf '%s' "$(printf '%s' "$out" | cut -f5)" ;;
    *) printf '0' ;;
  esac
}

# "<start>\t<end>\t<reason>" for an UNRECOGNIZED `backlog: done:` block, or
# nothing if there is no block or it IS recognized. Every caller that reports
# to a human (detect/apply/verify) reads this so all three describe the same
# shape the same way.
_backlog_done_unrecognized() {
  local out; out="$(_backlog_done_scan "$1")"
  case "$out" in
    UNRECOGNIZED*) printf '%s\t%s\t%s\n' "$(printf '%s' "$out" | cut -f2)" "$(printf '%s' "$out" | cut -f3)" "$(printf '%s' "$out" | cut -f4)" ;;
  esac
}

# The ids listed under a RECOGNIZED `backlog: done:`, one per line. Blank and
# comment lines inside the block are simply not `-` items, so they drop out
# here for free -- the reader and the dropper share _backlog_done_range, so
# they agree on exactly where the block is (Minor 5 round 3).
#
# `tr -d '\r'`: on a CRLF run-state every id would otherwise come out
# `alpha-t1\r`, so `_backlog_done_report`'s `$1==i` match against the
# adapter's plain id never fires and the "still unchecked" warning -- the
# entire reason the report runs before the block is dropped -- silently does
# not print, while the drop itself still happens (round 4 Defect 5; the same
# CR class the metrics collector already paid for).
_backlog_done_ids() {
  local f="$1" range start end
  range="$(_backlog_done_range "$f")"
  [ -n "$range" ] || return 0
  start="${range%% *}"; end="${range##* }"
  awk -v s="$start" -v e="$end" '
    NR>s && NR<=e && /^[[:space:]]*-[[:space:]]*/ {
      line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line); print line
    }
  ' "$f" | tr -d '\r'
}

# A RECOGNIZED backlog.done block present -- true even for a bare, empty
# `done:` key (an empty droppable block is still droppable; use
# _backlog_done_had_body to tell "empty key" from "0 ids parsed" when
# reporting to a human, round 4 Defect 7). False for no block at all AND for
# an UNRECOGNIZED one -- callers must not drop or count as "handled" a shape
# this classifier is not certain of; use _backlog_done_unrecognized for that
# case. Scoping through the same classifier the drop uses is what keeps
# detect/apply/verify from disagreeing with each other (Important 2 round 2).
_has_backlog_done() {
  local range; range="$(_backlog_done_range "$1")"
  [ -n "$range" ]
}

# Report, via $ADAPTER task-status, every backlog.done id whose gspec task is
# STILL UNCHECKED -- the actionable case. A `finished` id needs no report (the
# record and the work agree); an `unknown` id (no gspec, or the id was never a
# gspec task at all) is not evidence of anything and is silently skipped too --
# only "gspec says this is still open" is worth a human's attention here.
_backlog_done_report() {
  local root="$1" rsf="$root/.agents/run-state.yaml" ids id state
  ids="$(_backlog_done_ids "$rsf")"
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    state="$("$ADAPTER" task-status "$id" "$root" 2>/dev/null | awk -F'\t' -v i="$id" '$1==i && !seen {print $2; seen=1}')"
    if [ "$state" = "unchecked" ]; then
      printf 'UNCHECKED=%s\tgspec task is still unchecked -- the work may have been reverted; reconciling is a human decision, apply will not flip it\n' "$id"
    fi
  done <<EOF
$ids
EOF
}

# Drop the `done:` key and its list items from .agents/run-state.yaml, touching
# nothing else -- `cursor:`/`pending:` (siblings under `backlog:`) survive
# byte-identical. Uses the SAME range _backlog_done_ids reads, so the two can
# never disagree about which lines the block is (Minor 5). No-op if there is
# no block (callers already gate on _has_backlog_done, but stay safe alone).
#
# Atomic: temp file in the same directory, then `mv`. `cp -p` (not a bare
# empty `mktemp` file) carries the run-state's own mode onto the temp file so
# the later `mv` doesn't narrow it to mktemp's 0600 -- same discipline as
# gspec-backlog.sh's cmd_check_task (see its comment ~line 823), and for the
# same reason: git tracks only the exec bit, so a silent 0644->0600 would be
# invisible to `git diff` and to review (Minor 3). The `trap` is scoped to
# this write only -- armed once the temp file exists, disarmed right after the
# `mv` succeeds -- so an awk/mv failure under `set -euo pipefail` can't strand
# it as untracked scratch beside .agents/run-state.yaml (Minor 4).
_drop_backlog_done() {
  local f="$1" tmp range start end
  range="$(_backlog_done_range "$f")"
  [ -n "$range" ] || return 0
  start="${range%% *}"; end="${range##* }"
  tmp="$(mktemp "$(dirname "$f")/.migrate-backlog-done.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  cp -p "$f" "$tmp"
  awk -v s="$start" -v e="$end" 'NR<s || NR>e' "$f" > "$tmp"
  mv "$tmp" "$f"
  trap - EXIT
}

# --- findings-audit: read-only, per-entry, without opening a body (T18) ------
# ADR 0024/PRD "Migration is detection plus interactive triage". Finished-ness
# for a named packet reads ONLY the gspec checkbox (via $ADAPTER task-status)
# or an `[orch packet:<id>]` commit trailer -- NEVER the legacy `done:` block --
# so this drain and the backlog.done drain above are order-independent within
# one migrate pass. "Without opening a body" means never reading its CONTENT; a
# byte count (`wc -c`) is not that.

# Has a commit anywhere in this repo's history carried `[orch packet:<id>]` ON
# ITS OWN LINE? A bare substring --grep also fires on prose that merely
# MENTIONS the trailer format, e.g. a doc commit saying "...explain that a
# commit carries [orch packet:<id>] as a trailer" -- the exact bug this repo
# already fixed once, in the metrics collector (see scripts/metrics.sh's
# trailer scan, comment ~line 524: "Only a trailer on its own line counts...
# This excludes prose that merely mentions the trailer format"). Reusing that
# anchoring here: git's extended-regexp engine anchors `^`/`$` per LINE within
# a multi-line commit message (verified against a real repo), so an anchored
# --grep rejects the prose case while still matching a real trailer.
# Not fully equivalent to metrics.sh, though (Minor 7): metrics.sh:542 trims
# whitespace INSIDE the brackets before comparing ids, so a padded trailer
# `[orch packet:  p-pad  ]` records there as `p-pad`; this anchor requires the
# id adjacent to `packet:` and `]` with no internal whitespace, so the same
# padded trailer reads as not-landed here. Nothing in this codebase emits a
# padded trailer, so this is a documented divergence, not a bug to fix.
# No escaping of $id: packet ids are, everywhere else in this codebase,
# constrained to alnum/hyphen/underscore (the _resolve_task_id / _task_lookup
# id shape), which carries no ERE metacharacters.
# --max-count=1: stop git after the first matching commit instead of relying
# on the downstream `grep -q .` to stop it early -- under `set -euo
# pipefail`, `git … | grep -q .` can false-negative when more than one commit
# matches, because `grep -q` exits on its first match and SIGPIPEs the
# still-writing git process.
_trailer_landed() {
  local root="$1" id="$2"
  _is_git "$root" || return 1
  git -C "$root" log --all --max-count=1 --extended-regexp \
      --grep="^[[:space:]]*\\[orch packet:${id}\\][[:space:]]*\$" \
      --oneline 2>/dev/null | grep -q .
}

# One named packet's finished-ness: the gspec checkbox via the adapter first;
# only when the adapter itself has nothing to say (state=unknown -- no gspec
# task ever existed for this id) does a commit trailer get consulted. A packet
# whose backlog was never gspec still lands with a trailer, and that must read
# finished too, not unknown forever.
_packet_finished_state() {
  local root="$1" id="$2" state
  state="$("$ADAPTER" task-status "$id" "$root" 2>/dev/null | awk -F'\t' -v i="$id" '$1==i && !seen {print $2; seen=1}')"
  case "$state" in
    finished|unchecked) printf '%s\n' "$state" ;;
    *)
      if _trailer_landed "$root" "$id"; then printf 'finished\n'; else printf 'unknown\n'; fi
      ;;
  esac
}

# Byte size of the whole `findings:` block: its key line through the last line
# before the next column-0 key (or EOF). Same technique as runstate.sh's own
# _findings_index_bytes, reimplemented here rather than shared across files --
# it is a generic YAML-block byte counter, not a gspec/ parse.
_findings_index_block_bytes() {
  local f="$1" start end total
  start="$(grep -n '^findings:' "$f" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  [ -n "$start" ] || { printf 0; return 0; }
  total="$(wc -l < "$f" | tr -d ' ')"
  end="$(awk -v s="$start" 'NR>s && /^[A-Za-z_][A-Za-z0-9_]*:/ {print NR-1; exit}' "$f")"
  [ -n "$end" ] || end="$total"
  awk -v s="$start" -v e="$end" 'NR>=s && NR<=e' "$f" | wc -c | tr -d ' '
}

cmd_findings_audit() {
  local root; root="$(_root "${1:-}")"
  local rsf="$root/.agents/run-state.yaml"
  if [ ! -f "$rsf" ]; then
    printf 'AUDIT=none\nNOTE=no .agents/run-state.yaml -- nothing to audit\n'
    return 0
  fi
  local entries; entries="$("$HERE/runstate.sh" findings "$rsf" 2>/dev/null || true)"
  local n=0 body_total=0 row id summary file pkts
  # `cut`, not `read` with a tab IFS: TAB is an IFS-*whitespace* character, so
  # `read` collapses a run of them into ONE delimiter even when IFS is set to
  # tab alone -- an entry with no `file:` (a missing MIDDLE field) shifts
  # `pkts` left into `file` and silently reads as packet-less. Same bug and
  # same fix as `_nodes_for`'s TSV reader in gspec-backlog.sh.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id="$(printf '%s' "$row" | cut -f1)"
    summary="$(printf '%s' "$row" | cut -f2)"
    file="$(printf '%s' "$row" | cut -f3)"
    pkts="$(printf '%s' "$row" | cut -f4)"
    n=$((n+1))
    local has_packets="no" verdict="unknown" any_unchecked=0 all_finished=1 p pstate
    if [ -n "$pkts" ]; then
      has_packets="yes"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        pstate="$(_packet_finished_state "$root" "$p")"
        case "$pstate" in
          unchecked) any_unchecked=1; all_finished=0 ;;
          unknown)   all_finished=0 ;;
        esac
      done <<EOF
$(printf '%s' "$pkts" | tr ',' '\n')
EOF
      if [ "$any_unchecked" = 1 ]; then verdict="live"
      elif [ "$all_finished" = 1 ]; then verdict="dead"
      else verdict="unknown"
      fi
    fi
    local sumbytes bodybytes=0 hasbody="no"
    sumbytes="$(printf '%s' "$summary" | wc -c | tr -d ' ')"
    if [ -n "$file" ] && [ -f "$root/$file" ]; then
      hasbody="yes"
      bodybytes="$(wc -c < "$root/$file" | tr -d ' ')"
      body_total=$((body_total + bodybytes))
    fi
    printf 'ENTRY=%s PACKETS=%s VERDICT=%s SUMMARY_BYTES=%s BODY=%s BODY_BYTES=%s\n' \
      "$id" "$has_packets" "$verdict" "$sumbytes" "$hasbody" "$bodybytes"
  done <<EOF
$entries
EOF
  printf 'ENTRIES=%s\nINDEX_BYTES=%s\nBODY_BYTES_TOTAL=%s\n' \
    "$n" "$(_findings_index_block_bytes "$rsf")" "$body_total"
}

# --- detection ---------------------------------------------------------------

# Each finding is `FINDING=<id>\t<what>\t<why it matters>`.
_findings() {
  local root="$1" n=0

  # 1. Plans still beside the PRD (pre-2.0 / gspec v1 location).
  local plans; plans="$(ls "$root"/gspec/features/*.plan.md 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$plans" != "0" ]; then
    printf 'FINDING=plans\t%s plan file(s) at gspec/features/*.plan.md\tgspec 2.x writes gspec/tasks/<slug>.md; the loop reads that path\n' "$plans"
    n=$((n+1))
  fi

  # 2. Roadmap inside gspec/ (trips gspec's own spec-integrity floor).
  if [ -f "$root/gspec/roadmap.md" ]; then
    printf 'FINDING=roadmap\tgspec/roadmap.md exists\tit is plugin-owned, and every .md under gspec/ is governed by gspec spec-integrity (flags on write; blocks every turn on Codex)\n'
    n=$((n+1))
  fi

  # 3. project-overrides pointing at the old paths.
  if [ -f "$root/.agents/project-overrides.yaml" ] \
     && grep -q 'gspec/roadmap\.md\|features/\*\*\.plan\.md' "$root/.agents/project-overrides.yaml" 2>/dev/null; then
    printf 'FINDING=overrides\t.agents/project-overrides.yaml references old spec paths\tallowed_paths must cover gspec/tasks/** and .agents/roadmap.yaml\n'
    n=$((n+1))
  fi

  # 4. Consumer CLAUDE.md narrating the old layout.
  if [ -f "$root/CLAUDE.md" ] && grep -q 'gspec/roadmap\.md\|\.plan\.md' "$root/CLAUDE.md" 2>/dev/null; then
    printf 'FINDING=claudemd\tCLAUDE.md describes the old backlog layout\tit is the operating brief agents read every session; stale paths there outlive the file move\n'
    n=$((n+1))
  fi

  # 5. Legacy task-line shapes — the one that silently empties a backlog.
  local legacy=0 f
  for f in "$root"/gspec/features/*.plan.md "$root"/gspec/tasks/*.md; do
    [ -f "$f" ] || continue
    grep -qE '^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*T[0-9]+\*\*' "$f" && continue
    grep -qE '^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*[A-Za-z]' "$f" && legacy=$((legacy+1))
  done
  if [ "$legacy" != "0" ]; then
    printf 'FINDING=legacy-tasks\t%s plan file(s) use a pre-2.0 task-line shape\tthe adapter reads them, but ids/deps/covers are non-canonical; regenerate with /gspec-plan when convenient\n' "$legacy"
    n=$((n+1))
  fi

  # 6. Missing pause sentinel ignores (ADR 0017).
  if [ -f "$root/.gitignore" ] && ! grep -q 'agents/pause' "$root/.gitignore" 2>/dev/null; then
    printf 'FINDING=gitignore\t.gitignore does not ignore .agents/pause\ta pause request would dirty the tree and could be committed\n'
    n=$((n+1))
  fi

  # 6b. Missing run-state-prev ignore. `runstate.sh write` now keeps a last-known-good
  # copy beside run-state before replacing it, so a repo whose .gitignore predates that
  # gets `?? .agents/` on the first write — which reconcile reads as scratch on the green
  # checkpoint and DISCARDS, and the pause path's `git stash -u` sweeps. That destroys
  # the backup via the exact recovery path it exists to serve, and dirties every run
  # until the line is added. Reported, not auto-fixed: `apply` never edits a consumer's
  # .gitignore (same rule as the pause finding above).
  if [ -f "$root/.gitignore" ] && ! grep -q 'run-state-prev' "$root/.gitignore" 2>/dev/null; then
    # Token is deliberately NOT `gitignore-prev`: `has`/`grep` matching is substring-
    # based, so that name would also satisfy an assertion looking for `FINDING=gitignore`
    # and the pause finding could pass on this one alone.
    printf 'FINDING=writebackup-ignore\t.gitignore does not ignore .agents/run-state-prev.yaml\tthe write backup would dirty the tree every run, and reconcile would discard it as scratch -- add the line by hand\n'
    n=$((n+1))
  fi

  # 7. CLAUDE.md missing the report conventions — why reports come out as free prose.
  if [ -f "$root/CLAUDE.md" ] && ! grep -q 'gaffer:report-conventions' "$root/CLAUDE.md" 2>/dev/null; then
    printf 'FINDING=report-conventions\tCLAUDE.md does not carry the report conventions\twithout them every turn outside a gaffer skill reports in free prose; the skills read the full contract, but nothing else does\n'
    n=$((n+1))
  fi

  # 8. Spec-version drift against the pinned gspec.
  if [ -d "$root/gspec" ] && ! "$ADAPTER" check "$root" >/dev/null 2>&1; then
    printf 'FINDING=spec-version\tgspec specs fail the version pin\trun `gspec-backlog.sh check` for the offenders; /gspec-migrate or a plugin pin bump resolves it\n'
    n=$((n+1))
  fi

  # 9. A legacy `backlog.done` block in .agents/run-state.yaml (run-state-cleanup
  #    T17). Completion is derived from the gspec checkbox now, so the block is
  #    DROPPED on apply, never migrated anywhere. Report, per id, whether its
  #    gspec task is STILL UNCHECKED -- via the adapter, never by parsing
  #    gspec/ here -- BEFORE the block is gone: the work may have been
  #    reverted, so reconciling which ids to re-flip is a human decision, and
  #    `apply` itself never makes it.
  if [ -f "$root/.agents/run-state.yaml" ]; then
    local rsf9="$root/.agents/run-state.yaml"
    if _has_backlog_done "$rsf9"; then
      local dcount msg9 hadbody9
      dcount="$(_backlog_done_ids "$rsf9" | grep -c . || true)"; dcount="${dcount:-0}"
      if [ "$dcount" = "0" ]; then
        hadbody9="$(_backlog_done_had_body "$rsf9")"
        if [ "$hadbody9" = "0" ]; then
          msg9='the done: key is empty (no items at all)'
        else
          msg9='0 ids parsed -- the block has only blank/comment lines, no actual items'
        fi
      else
        msg9="$dcount id(s) in the legacy backlog.done block"
      fi
      printf 'FINDING=backlog-done\t%s\tcompletion is derived from the gspec checkbox now (ADR 0025); the block is dropped on apply, never migrated\n' "$msg9"
      n=$((n+1))
      _backlog_done_report "$root"
    fi
    # 9b. Same key, an UNRECOGNIZED shape (round 4): reported distinctly from
    #     the droppable case above, and the two never both fire for one file
    #     -- the classifier returns exactly one verdict per scan.
    local unrec9; unrec9="$(_backlog_done_unrecognized "$rsf9")"
    if [ -n "$unrec9" ]; then
      local ureason9; ureason9="$(printf '%s' "$unrec9" | cut -f3)"
      printf 'FINDING=backlog-done-unrecognized\t.agents/run-state.yaml has a backlog.done block in an unrecognized shape (%s)\tthis needs a human to review and drop it by hand -- apply will not touch it\n' "$ureason9"
      n=$((n+1))
    fi
  fi

  # 10. The findings index situation (run-state-cleanup T18). Only reported
  #     when there is at least one entry, so an index-free run-state stays
  #     silent -- there is nothing for `findings-audit` to say.
  if [ -f "$root/.agents/run-state.yaml" ] \
     && grep -q '^findings:[[:space:]]*$' "$root/.agents/run-state.yaml" 2>/dev/null; then
    local fcount; fcount="$("$HERE/migrate.sh" findings-audit "$root" 2>/dev/null | sed -n 's/^ENTRIES=//p')"
    if [ -n "$fcount" ] && [ "$fcount" != "0" ]; then
      printf 'FINDING=findings\t%s finding index entry(ies)\trun `migrate.sh findings-audit` for the per-entry live/dead/unknown detail; apply deletes none of them -- triage is one entry at a time, the migrate skill'"'"'s job\n' "$fcount"
      n=$((n+1))
    fi
  fi

  printf 'FINDINGS=%s\n' "$n"
}

cmd_detect() {
  local root; root="$(_root "${1:-}")"
  [ -d "$root" ] || die "no such directory: $root"
  local state='current'
  [ -f "$root/gspec/roadmap.md" ] && state='pre-2.0'
  ls "$root"/gspec/features/*.plan.md >/dev/null 2>&1 && state='pre-2.0'
  [ -d "$root/gspec" ] || state='no-gspec'
  printf 'ROOT=%s\nFROM=%s\n' "$root" "$state"
  local out; out="$(_findings "$root")"
  printf '%s\n' "$out"
  local n; n="$(printf '%s\n' "$out" | sed -n 's/^FINDINGS=//p')"
  [ "${n:-0}" = "0" ] || return 2
}

cmd_plan() {
  local root; root="$(_root "${1:-}")"
  printf 'Migration plan for %s\n\n' "$root"
  local i=1
  while IFS=$'\t' read -r id what why; do
    case "$id" in FINDING=*) ;; *) continue ;; esac
    printf '%d. [%s] %s\n     why: %s\n' "$i" "${id#FINDING=}" "$what" "$why"
    i=$((i+1))
  done < <(_findings "$root")
  [ "$i" -gt 1 ] || printf '  Nothing to do — this repo is already on the current layout.\n'
}

# --- apply -------------------------------------------------------------------

_is_git() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
_mv() { # history-preserving where possible
  local root="$1" from="$2" to="$3"
  if _is_git "$root"; then git -C "$root" mv "$from" "$to" 2>/dev/null && return 0; fi
  mv "$root/$from" "$root/$to"
}

# A migrated plan needs gspec frontmatter: the version pin asserts `spec-version`,
# and `feature:` ties the plan to its PRD. Architect-authored pre-2.0 plans have
# neither (they open straight into `# Plan - <Name>`). PREPENDING frontmatter is
# safe in a way that rewriting task lines is not: it cannot touch a checked task,
# so the historical record and gspec's immutability floor are both untouched.
_ensure_frontmatter() {
  local file="$1" slug="$2" ver="$3"
  head -1 "$file" | grep -qE '^-{3}[[:space:]]*$' && return 1   # already has some
  local tmp; tmp="$(mktemp)"
  { printf -- '---\nspec-version: %s\nfeature: %s\n---\n\n' "$ver" "$slug"; cat "$file"; } > "$tmp"
  mv "$tmp" "$file"
  return 0
}

# gspec/roadmap.md -> .agents/roadmap.yaml, keeping ONLY the four fields the new
# schema has. `status` and `parallel_group` are dropped on purpose: completion is
# derived from PRD checkboxes and concurrency is computed per run, so storing
# either is a drift source (ADR 0020 D2). Prose sections are NOT translated.
# Stamp the report-conventions card into a consumer CLAUDE.md.
#
# This is mechanical on purpose. The card is inserted BYTE-VERBATIM, marker comment
# included: the marker (`gaffer:report-conventions`) is what stops
# hooks/report-conventions.sh injecting the same text again at every session start,
# and a paraphrase would drift from the plugin's own contract. Left to an agent, the
# stamp is exactly the kind of step that gets summarized instead of copied.
#
# Placement: immediately before the routing section when there is one (that is where
# the overlay keeps it), else appended. Appending is safe even after gspec's own
# usage guide — nothing in CLAUDE.md is order-dependent.
#
# Returns 0 if it stamped, 1 if there was nothing to do.
_stamp_report_conventions() {
  local root="$1" card="$HERE/../templates/report-conventions-card.md" md="$root/CLAUDE.md" tmp
  [ -f "$md" ] || return 1
  [ -f "$card" ] || return 1
  grep -q 'gaffer:report-conventions' "$md" 2>/dev/null && return 1

  tmp="$md.migrate.$$"
  if grep -qE '^## Routing' "$md"; then
    awk -v card="$card" '
      /^## Routing/ && !done {
        while ((getline line < card) > 0) print line
        close(card); print ""; done = 1
      }
      { print }
    ' "$md" > "$tmp"
  else
    cat "$md" > "$tmp"
    printf '\n' >> "$tmp"
    cat "$card" >> "$tmp"
  fi

  # Never leave a half-written operating brief behind.
  if [ ! -s "$tmp" ] || ! grep -q 'gaffer:report-conventions' "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$md"
  return 0
}

_convert_roadmap() {
  local src="$1" dest="$2"
  {
    printf '# Feature sequencing (plugin ADR 0020 D2) — migrated from gspec/roadmap.md\n'
    printf '#\n'
    printf '# Converted automatically: slug/order/why/depends_on are carried over.\n'
    printf '# `status` and `parallel_group` were DROPPED on purpose — completion is derived\n'
    printf '# from each PRD s capability checkboxes, and concurrency is computed per run by\n'
    printf '# packet-graph.sh. Storing either is how they drift.\n'
    printf '#\n'
    printf '# REVIEW THIS FILE: any prose in the old roadmap (## Notes, ## Unsequenced,\n'
    printf '# rationale in comments) was NOT translated. It is still in the original file.\n'
    printf 'schema: 1\n'
    printf 'features:\n'
    awk '
      function flush() {
        if (slug == "") return
        printf "  - slug: %s\n", slug
        if (order != "") printf "    order: %s\n", order
        printf "    why: %s\n", (why != "" ? why : "\"(carry the rationale over from the old roadmap)\"")
        printf "    depends_on: %s\n", (deps != "" ? deps : "[]")
        slug=""; order=""; why=""; deps=""
      }
      function val(l){ sub(/^[^:]*:[[:space:]]*/,"",l); sub(/[[:space:]]+$/,"",l); return l }
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*-[[:space:]]+slug[[:space:]]*:/ { flush(); l=$0; sub(/^[[:space:]]*-[[:space:]]+/,"",l); slug=val(l); next }
      /^[[:space:]]+order[[:space:]]*:/       { order=val($0); next }
      /^[[:space:]]+why[[:space:]]*:/         { why=val($0);   next }
      /^[[:space:]]+depends_on[[:space:]]*:/  { deps=val($0);  next }
      END { flush() }
    ' "$src"
  } > "$dest"
}

cmd_apply() {
  local root force=0 a
  root="$(_root "${1:-}")"
  for a in "$@"; do [ "$a" = "--force" ] && force=1; done
  [ -d "$root" ] || die "no such directory: $root"

  # A migration you cannot `git diff` is not a migration you can review.
  if _is_git "$root" && [ "$force" -eq 0 ] && [ -n "$(git -C "$root" status --porcelain)" ]; then
    die "working tree is dirty — commit or stash first so the migration is reviewable as one diff (or pass --force)" 1
  fi

  local did=0

  # 1. plan files -> gspec/tasks/
  if ls "$root"/gspec/features/*.plan.md >/dev/null 2>&1; then
    mkdir -p "$root/gspec/tasks"
    local f base slug
    for f in "$root"/gspec/features/*.plan.md; do
      base="$(basename "$f")"; slug="${base%.plan.md}"
      if [ -e "$root/gspec/tasks/$slug.md" ]; then
        printf 'SKIP=gspec/tasks/%s.md already exists — left gspec/features/%s in place for you to reconcile\n' "$slug" "$base"
        continue
      fi
      _mv "$root" "gspec/features/$base" "gspec/tasks/$slug.md"
      printf 'MOVED=gspec/features/%s -> gspec/tasks/%s.md\n' "$base" "$slug"
      did=1
    done
  fi

  # 1b. give migrated plans the frontmatter the version pin requires
  if ls "$root"/gspec/tasks/*.md >/dev/null 2>&1; then
    local ver stamped=0 g base slug
    ver="$("$ADAPTER" pin | sed -n 's/^GSPEC_SPEC_VERSIONS=//p' | awk '{print $1}')"
    for g in "$root"/gspec/tasks/*.md; do
      base="$(basename "$g")"; slug="${base%.md}"
      if _ensure_frontmatter "$g" "$slug" "${ver:-v1}"; then
        stamped=$((stamped+1))
      fi
    done
    if [ "$stamped" != "0" ]; then
      printf 'STAMPED=%s plan file(s) given spec-version %s + feature frontmatter\n' "$stamped" "${ver:-v1}"
      did=1
    fi
  fi

  # 2. roadmap -> .agents/roadmap.yaml
  if [ -f "$root/gspec/roadmap.md" ]; then
    mkdir -p "$root/.agents"
    if [ -e "$root/.agents/roadmap.yaml" ]; then
      printf 'SKIP=.agents/roadmap.yaml already exists — gspec/roadmap.md left in place\n'
    else
      _convert_roadmap "$root/gspec/roadmap.md" "$root/.agents/roadmap.yaml"
      printf 'CONVERTED=gspec/roadmap.md -> .agents/roadmap.yaml (%s feature entries)\n' \
        "$(grep -c '^  - slug:' "$root/.agents/roadmap.yaml" || printf 0)"
      printf 'KEPT=gspec/roadmap.md left in place — it still holds prose the converter does not translate. Delete it yourself once reviewed.\n'
      did=1
    fi
  fi

  # 3. report conventions -> consumer CLAUDE.md (the always-on report format layer)
  if _stamp_report_conventions "$root"; then
    printf 'STAMPED_CONVENTIONS=report conventions added to CLAUDE.md — reports now follow the house format outside gaffer skills too\n'
    did=1
  fi

  # 4. backlog.done -> derived from the gspec checkbox now (T17). Report BEFORE
  #    the block is dropped: an id still unchecked in gspec may mean the work
  #    was reverted, and reconciling that is a human call `apply` never makes
  #    -- it reports, and drops the block, and flips nothing.
  if [ -f "$root/.agents/run-state.yaml" ]; then
    local rsf4="$root/.agents/run-state.yaml"
    if _has_backlog_done "$rsf4"; then
      _backlog_done_report "$root"
      _drop_backlog_done "$rsf4"
      printf 'DROPPED=backlog.done block removed from .agents/run-state.yaml — completion is derived from the gspec checkbox now (ADR 0025)\n'
      did=1
    fi
    # 4b. An UNRECOGNIZED shape (round 4): never dropped, never mutated --
    #     reported so a human can act, bytes left exactly as they were.
    local unrec4; unrec4="$(_backlog_done_unrecognized "$rsf4")"
    if [ -n "$unrec4" ]; then
      local ustart4 uend4 ureason4
      ustart4="$(printf '%s' "$unrec4" | cut -f1)"
      uend4="$(printf '%s' "$unrec4" | cut -f2)"
      ureason4="$(printf '%s' "$unrec4" | cut -f3)"
      printf 'UNRECOGNIZED_BACKLOG_DONE=.agents/run-state.yaml lines %s-%s: %s -- left untouched, needs a human (apply will not drop this)\n' \
        "$ustart4" "$uend4" "$ureason4"
    fi
  fi

  [ "$did" = "1" ] || printf 'NOCHANGE=nothing mechanical left to move\n'
  printf '\n'
  cmd_verify "$root"
}

# --- verify ------------------------------------------------------------------

cmd_verify() {
  local root; root="$(_root "${1:-}")"
  local problems=0

  printf 'VERIFY %s\n' "$root"
  if ls "$root"/gspec/features/*.plan.md >/dev/null 2>&1; then
    printf '  ✗ plan files still at gspec/features/*.plan.md\n'; problems=$((problems+1))
  else
    printf '  ✓ no plan files left beside the PRDs\n'
  fi
  if [ -f "$root/gspec/roadmap.md" ] && [ ! -f "$root/.agents/roadmap.yaml" ]; then
    printf '  ✗ gspec/roadmap.md present with no .agents/roadmap.yaml\n'; problems=$((problems+1))
  fi

  if [ -f "$root/.agents/run-state.yaml" ]; then
    local rsfv="$root/.agents/run-state.yaml"
    if _has_backlog_done "$rsfv"; then
      printf '  ✗ .agents/run-state.yaml still carries a legacy backlog.done block\n'; problems=$((problems+1))
    else
      # round 4: the classifier now recognizes the inline flow form
      # (`done: [a, b]`) too -- as UNRECOGNIZED, not silently ✓. A block left
      # behind that this script is not certain how to touch is a problem, not
      # a clean state: never print VERIFY=ok for a file still carrying one.
      local unrecv; unrecv="$(_backlog_done_unrecognized "$rsfv")"
      if [ -n "$unrecv" ]; then
        local ureasonv; ureasonv="$(printf '%s' "$unrecv" | cut -f3)"
        printf '  ⚠ .agents/run-state.yaml still carries an UNRECOGNIZED backlog.done block (%s) -- left in place for a human, not counted as clean\n' "$ureasonv"
        problems=$((problems+1))
      else
        printf '  ✓ no legacy backlog.done block in .agents/run-state.yaml\n'
      fi
    fi
  fi

  if [ -d "$root/gspec" ]; then
    if "$ADAPTER" check "$root" >/dev/null 2>&1; then
      printf '  ✓ specs pass the gspec version pin\n'
    else
      printf '  ✗ specs fail the version pin (run: gspec-backlog.sh check)\n'; problems=$((problems+1))
    fi

    # THE check that matters: does the backlog actually parse to packets?
    local plans packets
    plans="$(ls "$root"/gspec/tasks/*.md 2>/dev/null | wc -l | tr -d ' ')"
    packets="$("$ADAPTER" nodes-all "$root" 2>/dev/null | grep -c . || true)"; packets="${packets:-0}"
    printf '  · %s plan file(s) -> %s unchecked packet(s)\n' "$plans" "$packets"
    if [ "$plans" != "0" ] && [ "$packets" = "0" ]; then
      printf '  ✗ plans exist but produce ZERO packets — the backlog would read as "nothing to do".\n'
      printf '    This is the failure the migration exists to catch. Inspect a plan file: its task\n'
      printf '    lines are in a shape the adapter cannot read, and it needs /gspec-plan.\n'
      problems=$((problems+1))
    fi
    local nx; nx="$("$ADAPTER" next "$root" 2>/dev/null | sed -n 's/^NEXT=//p')"
    printf '  · next feature: %s\n' "${nx:-none}"
  fi

  if [ "$problems" = "0" ]; then printf 'VERIFY=ok\n'; return 0; fi
  printf 'VERIFY=problems (%s)\n' "$problems"; return 3
}

case "${1:-}" in
  detect)         shift; cmd_detect         "$@" ;;
  plan)           shift; cmd_plan           "$@" ;;
  apply)          shift; cmd_apply          "$@" ;;
  verify)         shift; cmd_verify         "$@" ;;
  findings-audit) shift; cmd_findings_audit "$@" ;;
  *) die "usage: migrate.sh {detect|plan|apply [--force]|verify|findings-audit} [root]" ;;
esac
