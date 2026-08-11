#!/usr/bin/env bash
# =============================================================================
# runstate.sh — durable run-state I/O + crash-recovery decision (ADR 0004/0005)
# =============================================================================
# Owns the ONE file that survives a session: .agents/run-state.yaml (the local
# checkout's durable checkpoint). This owns the checkpoint file and the reconcile
# decision a resuming session makes after an UNCLEAN exit (crash / reboot /
# sleep-death / hard close). The loop works in the single local checkout on
# `orch/<task-id>` feature branches (ADR 0009) — there is no separate worktree.
#
# Why a script and not raw sed in the skills:
#   - writes are ATOMIC (temp + rename) so a crash mid-write cannot corrupt the
#     only memory the loop has, and
#   - the reconcile decision is deterministic and unit-testable WITHOUT a live
#     agent (see scripts/test-runstate.sh), instead of living only in a prompt.
#
# Subcommands:
#   get      <file> <key>            print a flat top-level scalar (status,
#                                    branch, last_green_commit, updated_at, ...).
#   cursor   <file>                  print backlog.cursor (nested).
#   set      <file> <key> <value>    atomically set/insert a flat top-level key.
#   touch    <file>                  atomically stamp updated_at = now (UTC).
#   write    <file>                  atomically write full contents from stdin,
#                                    refusing structurally invalid input (empty,
#                                    whitespace-only, no `schema:` key, or a
#                                    malformed column-0 line) with the target
#                                    left byte-untouched. STRUCTURAL, not a
#                                    parse: catches truncation and gross
#                                    malformation, not a well-formed-but-wrong
#                                    document (runstate-write-integrity cap. 2).
#                                    Before REPLACING an existing file, copies
#                                    it to a sibling run-state-prev.yaml (last
#                                    known good) -- the recovery path for a
#                                    structurally-perfect-but-truncated write
#                                    the checks above cannot catch.
#   add-finding <file> <id> <summary> --packets <id[,id...]> [--body]
#                                    record a PACKET-SCOPED finding (ADR 0024): a
#                                    constraint on a packet that has not executed
#                                    yet, recorded because there is nowhere
#                                    permanent to put it until that packet runs.
#                                    --packets is REQUIRED — there is no run-wide
#                                    finding, because an entry that cannot expire
#                                    is the thing this rule removes. If it is not
#                                    that: a durable fact about the environment/
#                                    tools/agents/policy -> the repo's own
#                                    committed files or agent memory; a question
#                                    only the human can answer -> pending_questions:;
#                                    where this session stopped -> note: (one
#                                    line); "this should be built/fixed" -> the
#                                    backlog (a gspec task). --body also writes
#                                    the .agents/findings/<id>.md stub (default:
#                                    index entry only, no body — most findings
#                                    never need one).
#   findings <file> [--stale] [--finished <id[,id...]>] [--max-bytes <n>]
#                                    list the finding index: id/summary/file/
#                                    packets, tab-separated, one per line. --stale
#                                    reports which entries are expired against a
#                                    SUPPLIED finished-packet set (unsupplied ->
#                                    every named packet reads unknown -> nothing
#                                    expires) plus INDEX_BYTES/OVER_THRESHOLD
#                                    against a budget (default 4096, override via
#                                    --max-bytes or $ORCH_FINDINGS_INDEX_MAX_BYTES)
#                                    — a BACKSTOP for when the drop-at-packet-close
#                                    discipline slips, not the intended path.
#   drop-finding <file> <id>        remove a finding's index entry AND its body,
#                                    both or neither (same-directory atomic
#                                    rename + temp-file swap). A forced failure
#                                    mid-drop restores the set-aside body and
#                                    leaves the index entry in place.
#   claim-driver <file> [pid]        mark the run as actively driven (host +
#                                    since + heartbeat). Pass a pid ONLY if you
#                                    have a genuinely long-lived one.
#   heartbeat <file>                 restamp "still driving" — call at every safe
#                                    checkpoint (where the pause poll already is).
#   driver-status <file>             DRIVER=none|live|dead|foreign — is anyone
#                                    still driving?
#   outcome  <file>                  the TERMINAL-state answer + a distinct exit
#                                    code per ending (see below).
#   summary  <file>                  one-line human summary for the SessionStart
#                                    hook / check-ins (adds a crash hint if the
#                                    status is `running`).
#   reconstruct <work-tree> [base]   READ-ONLY. When run-state.yaml is LOST (it is
#                                    gitignored local bookkeeping, ADR 0009), print
#                                    the git-derivable facts to rebuild it: the
#                                    current `orch/<task-id>` feature branch, its tip
#                                    SHA (a CANDIDATE last_green_commit — the caller
#                                    must verify build+tests are green), and the
#                                    ordered packet ids already committed on it (from
#                                    the `[orch packet:<id>]` trailers). Prints
#                                    RECONSTRUCT=ok with BRANCH=/TIP=/BASE=/DONE=
#                                    lines, or RECONSTRUCT=escalate + reason when it
#                                    cannot (HEAD not on an orch/* branch, no commits).
#                                    cursor/pending come from the committed task
#                                    backlog and pending_questions cannot be
#                                    recovered from git — the CALLER supplies those.
#                                    DONE is informational only — no run-state
#                                    field is populated from it automatically; it
#                                    is what a human rebuilding a lost run-state
#                                    reads to see the packet identities already
#                                    landed.
#   reconcile <file> <work-tree>     READ-ONLY. Compare the durable checkpoint to
#                                    the working tree's real git state (pass the
#                                    local checkout, e.g. `.`) and print the
#                                    recovery decision on stdout:
#                                      DECISION=clean     HEAD==green, tree clean
#                                                         -> resume from cursor.
#                                      DECISION=adopt     one clean orphan commit
#                                                         tagged for the cursor
#                                                         packet -> torn-write
#                                                         recovery: adopt it.
#                                      DECISION=discard   scratch on top of green
#                                                         -> reset to green, then
#                                                         resume from cursor.
#                                      DECISION=escalate   ambiguous (diverged /
#                                                         multiple / untagged /
#                                                         mixed) -> stop, ask.
#                                    A `reason:` line explains on stdout too. It
#                                    NEVER mutates anything — the caller acts.
#   packets-by-status <file> <status>   (parallel mode, schema 3) print the ids of
#                                    packets in packets[] whose status == <status>,
#                                    one per line — feed done/running to
#                                    packet-graph.sh ready.
#   lanes    <file>                  (parallel mode) print one TSV row per lane:
#                                    id, branch, worktree, packet, last_green_commit,
#                                    status.
#   reconcile-parallel <file> <main-checkout>   READ-ONLY. Apply the reconcile
#                                    decision table to EACH lane (its worktree if
#                                    still live, else its branch in the main
#                                    checkout) and print `LANE=<id> DECISION=...`
#                                    per lane plus a final `AGGREGATE=`.
#
# CONTROL STATE vs TERMINAL STATE (ADR 0020 D5). `status:` is the CONTROL state a
# resuming session steers by; `outcome` is the ANSWER to "how did this run end?".
# They were the same field, which is exactly the ambiguity gspec hit (a completed
# build and a build paused for review both exited 0). `outcome` maps status +
# driver liveness to one ending with its own exit code:
#   0 complete (done) · 1 blocked · 2 paused · 3 crashed · 4 still running
#
# WHY A DRIVER CLAIM (ADR 0020 D5, as-built). `status: running` alone cannot
# distinguish a CRASHED session from ANOTHER SESSION DRIVING RIGHT NOW — and
# parallel mode's safety rests on the driver being the single writer of this
# file, which nothing previously enforced. The claim makes that checkable. It is
# a HEARTBEAT, not a pid: see the note above cmd_claim_driver for why gspec's
# pid check does not transfer to a session-driven loop. Host is recorded because
# resume is same-machine (the file is gitignored, ADR 0009): a claim from a
# different host says nothing local, so it is reported `foreign`, never guessed.
#
# These keys are OPTIONAL and additive — a schema-3 file written before they
# existed reads as DRIVER=none and behaves exactly as it always did.
#
# Pause signal (ADR 0017). A cooperative pause REQUEST is a write-once SENTINEL
# file — kept SEPARATE from run-state so a human/frontend setting it never contends
# with the driver's single-writer run-state (ADR 0016 #6). run-state records the
# OUTCOME (status: paused); the sentinel records the REQUEST. It lives in the MAIN
# checkout's `.agents/` and is resolvable from any lane worktree via
# `git rev-parse --git-common-dir` (see hooks/pause-check.sh). The busy loop and
# lanes POLL it at safe checkpoints and wrap up to a green commit — never mid-edit.
#   request-pause <pause-file> [reason]   touch the sentinel (atomic) with a
#                                    reason + UTC timestamp. Human/frontend/driver.
#   clear-pause   <pause-file>       remove the sentinel + its per-lane variants,
#                                    at run start and on resume, so a stale request
#                                    cannot re-halt a fresh run.
#   pause-status  <pause-file> [id]  print PAUSE=1 (+ scope=all|lane:<id>, reason)
#                                    when <pause-file> (or <pause-file>.<id>) exists,
#                                    else PAUSE=0. Always exit 0 — it is a query.
#
# Exit codes: 0 = success (reconcile always 0 when it can decide), non-zero =
# usage / unreadable-file / unreadable-work-tree error (stderr explains).
# =============================================================================

set -euo pipefail

# Commit-message trailer that ties a packet commit to its packet id. Kept here so
# the writer (run-loop / pause) and the reader (reconcile) agree on one string.
PACKET_TRAILER_PREFIX="[orch packet:"

die() { printf 'runstate.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

need_file() { [ -f "$1" ] || die "no run-state file at '$1'"; }

# --- flat top-level scalar: `key: value` at column 0 -------------------------
# An ABSENT key is a legitimate outcome (optional scalar), not an error: emit
# empty and exit 0. Without the trailing `|| true` the no-match `grep` exits 1,
# and under `set -e`/pipefail a caller's bare `x="$(cmd_get …)"` would abort the
# whole script BEFORE any `:-default` fallback — the trap that silently killed
# `summary` on a partial run-state. Fix it once here, not in every caller.
cmd_get() {
  local f="${1:-}" key="${2:-}" raw
  [ -n "$f" ] && [ -n "$key" ] || die "usage: get <file> <key>"
  need_file "$f"
  # An ABSENT key must stay ZERO bytes (not even a trailing newline) -- the
  # historical contract this whole function's opening comment documents.
  # Checked separately from extraction below because `raw="$(...)"` strips
  # ALL trailing newlines regardless of whether the key existed, so it alone
  # cannot tell "absent" from "present with an empty value" apart.
  grep -qE "^${key}:" "$f" || return 0
  raw="$({ grep -E "^${key}:" "$f" || true; } | head -1 | sed -E "s/^${key}:[[:space:]]*//")"
  # _yaml_decode_value (defined below, with cmd_set) is the inverse of the
  # single-quoted encoding `set` writes -- a no-op on anything it didn't
  # write, so a bare/legacy value round-trips exactly as before. The trailing
  # `\n` restores the one-line-of-output shape every caller here (and every
  # internal cmd_get/cmd_cursor consumer below) already expects.
  printf '%s\n' "$(_yaml_decode_value "$raw")"
}

# --- nested backlog.cursor ---------------------------------------------------
# Same contract as cmd_get: an absent cursor is empty-with-exit-0, not a failure.
cmd_cursor() {
  local f="${1:-}" raw
  [ -n "$f" ] || die "usage: cursor <file>"
  need_file "$f"
  grep -qE '^[[:space:]]+cursor:' "$f" || return 0
  raw="$({ grep -E '^[[:space:]]+cursor:' "$f" || true; } | head -1 | sed -E 's/.*cursor:[[:space:]]*//')"
  printf '%s\n' "$(_yaml_decode_value "$raw")"
}

# --- structural validation for `write` (runstate-write-integrity capability 2,
# --- defect 2) ----------------------------------------------------------------
# `write` used to be `cat > "$tmp"` followed by `mv -f`, replacing the file with
# WHATEVER reached stdin and validating nothing. A failed transform upstream in
# the pipe silently truncated run-state to a stub; it fired live when an `awk`
# aborted on a missing `strftime` and left a 26-byte file over a working
# run-state -- gitignored, so there was no `git restore`, only manual
# reconstruction.
#
# THE BOUND, STATED HONESTLY (do not let this comment or the refusal message
# below overclaim): this is a STRUCTURAL check, not a parse. It catches
# TRUNCATION and GROSS MALFORMATION -- the two failure modes that have fired
# live -- nothing more. A document that is well-formed but WRONG (a stale
# `cursor`, a `: `-injected sibling key that is itself valid YAML) passes this
# check by design and is out of this feature's reach. Overclaiming here would
# be the exact defect this feature exists to remove, one file over (defect 3:
# a check that looks like it is running and is not).
#
# POSIX shell only -- grep/sed, no jq/python3/yq, nothing gated on
# `command -v`. runstate.sh stays at the same dependency tier as
# hooks/guard.sh: a check that disables itself when a tool is missing is
# defect 3 in a different file.
#
# Checks the INPUT, never the TARGET -- `write` is how a run-state comes into
# existence, so a first write to a path that does not yet exist must still
# succeed; validating the target would break bootstrap.
#
# Refused:
#   - empty input
#   - whitespace-only input
#   - input carrying no `schema:` key at column 0
#   - any column-0 line that is not a well-formed `key:` line, a comment
#     (`#...`), or a document marker (`---`/`...`) -- blank/whitespace-only
#     lines and every INDENTED (nested) line are untouched by this check, only
#     column 0 is structural in this format
#
# Prints the name of the failed check on stdout and returns 1; prints nothing
# and returns 0 when the input passes.
_write_check() {
  local tmp="$1" bad
  [ -s "$tmp" ] || { printf 'empty input'; return 1; }
  grep -qE '[^[:space:]]' "$tmp" || { printf 'whitespace-only input'; return 1; }
  grep -qE '^schema:' "$tmp" || { printf 'no schema: key'; return 1; }
  # Column-0 candidates (no leading whitespace -- blank/indented lines never
  # reach this filter) that are NOT a comment, a document marker, or a
  # `key:`-shaped line. `|| true` keeps a clean file (no bad lines -> grep -v
  # finds nothing -> exit 1) from tripping `set -e`/pipefail here.
  bad="$(grep -nE '^[^[:space:]]' "$tmp" \
    | grep -vE '^[0-9]+:(#.*|---[[:space:]]*|\.\.\.[[:space:]]*|[A-Za-z_][A-Za-z0-9_-]*:.*)$' \
    | head -1 || true)"
  if [ -n "$bad" ]; then
    printf 'malformed line at %s' "${bad%%:*}"
    return 1
  fi
  return 0
}

# --- atomic write of the whole file from stdin -------------------------------
# LAST-KNOWN-GOOD COPY (runstate-write-integrity capability 2, added once the
# structural checks above were shown NOT to close the incident they exist for):
# a transform that dies BETWEEN lines -- not mid-line -- yields a structurally
# PERFECT document, and `schema: 3\nstatus: running\n` is exactly the 26 bytes
# the live incident's stub left. `_write_check` cannot catch that without
# correctly classifying every valid and invalid document forever; a copy needs
# no classification. A shrinkage guard was designed and rejected for the same
# reason from the other direction: `/gaffer:migrate` findings triage shrinks a
# real run-state 61% (the findings index alone is 87% of the file) doing
# legitimate, shipped work, so any threshold that catches the stub also
# refuses that -- wrong in both directions.
#
# So: on REPLACE only (an existing file at $f), AFTER the input has already
# passed `_write_check`, copy the pre-write target to a sibling
# run-state-prev.yaml BEFORE the atomic rename. A first write (no existing
# file) makes no copy -- `write` is how a run-state comes into existence, and
# there is nothing prior to preserve. A refused write never reaches this line
# at all, so both the target and any existing backup are left untouched.
#
# `run-state-prev.yaml` is gitignored in BOTH .gitignore files, and that is
# load-bearing, not tidiness: an UNignored backup would be untracked scratch
# on the pause path's `git stash --include-untracked`, and `reconcile` reads
# untracked scratch on the green checkpoint as discardable -- so an unignored
# backup would be destroyed by the very recovery path it exists to serve.
# Same-machine, same reasons as run-state.yaml itself (ADR 0009).
cmd_write() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: write <file>   (contents on stdin)"
  local dir tmp reason prev; dir="$(dirname "$f")"
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" || die "cannot create temp file in ${dir}"
  cat > "$tmp"
  if ! reason="$(_write_check "$tmp")"; then
    rm -f "$tmp"
    die "write refused: ${reason} -- structural check only (catches truncation/gross malformation, not a well-formed-but-wrong document); existing file left untouched"
  fi
  if [ -f "$f" ]; then
    prev="${dir}/run-state-prev.yaml"
    cp "$f" "$prev"
  fi
  mv -f "$tmp" "$f"          # rename is atomic on the same filesystem
}

# --- shared value encoder/decoder (T4/T5; extracted so cmd_set, cmd_add_finding
# --- and every reader below call ONE implementation rather than several that
# --- happen to agree today) --------------------------------------------------
# ADR 0022 hardened cmd_add_finding's summary against `: `-injection with a
# single-quoted YAML scalar, `'` doubled, interpolated via `awk ENVIRON`. That
# hardening never reached cmd_set two hundred lines above it in this same file
# — the class of write, not just the one function, needed it. These helpers
# are that one implementation, on both the write side and the read side.
#
# _yaml_collapse <raw value>
#   Collapses newlines (and \r) to spaces -- not rejected, since the caller is
#   an agent mid-loop, and a literal newline in a flat scalar breaks the line
#   and can inject a sibling key. The ONE place this happens: cmd_set (via
#   _yaml_encode_value, below) and cmd_add_finding both call it, so a future
#   hardening (e.g. against \f, \v, a Unicode line separator) reaches both
#   instead of being applied to one and silently skipping the other -- which
#   is exactly how the original defect (encoding hardened in add-finding, not
#   in cmd_set) was created.
_yaml_collapse() {
  printf '%s' "$1" | tr '\n\r' '  '
}

# _yaml_quote <already-collapsed value>
#   Wraps <value> as a SINGLE-quoted YAML scalar with `'` doubled -- the ONLY
#   escaping rule a single-quoted scalar needs, since it performs NO other
#   escape processing (a backslash is already literal; double-quoting would
#   need `\`/`"` escaped and would then re-interpret `\n`). Prints WITH the
#   surrounding quotes. Takes an ALREADY-collapsed value (see _yaml_collapse):
#   cmd_add_finding's collapsed $summary is also reused for the finding body
#   and the duplicate-id check text, not only for this encoding, so collapsing
#   lives at the call site rather than inside this function.
_yaml_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# _yaml_encode_value <raw value>
#   The one entry point cmd_set uses: _yaml_quote(_yaml_collapse(value)),
#   always. There is NO plain-scalar allowlist here, on purpose, and none
#   should be reintroduced as a "cosmetic" optimization to keep simple values
#   bare -- an allowlist was tried and tried twice, and both attempts failed
#   SILENTLY (rc=0, no error anywhere) rather than loudly:
#     - a value ending in `:` (e.g. `naive:`) passed a character-class
#       allowlist restricted to [A-Za-z0-9._:/+-], because every character in
#       it is individually allowed -- but `key: naive:` is a second, empty
#       mapping key, and PyYAML refuses to parse it.
#     - `no`, `on`, `00`, `0755` all passed the same allowlist AND parsed
#       fine -- but YAML's own implicit typing reads them back as the boolean
#       `false`, the boolean `true`, the integer `0`, and the integer `493`
#       (octal) respectively. The file parses; the round-trip is just wrong,
#       silently, which is worse than a parse failure because nothing signals
#       it. `hooks/session-start.sh` reading a misread `status` back is the
#       live version of exactly this failure shape.
#   Both classes were found by fuzzing a small, careful character-class rule
#   -- and a rule built the same way could always have a third class waiting.
#   A single-quoted YAML scalar is correct for EVERY string by construction
#   (see _yaml_quote): there is nothing left to re-verify, which is what an
#   allowlist can never offer. The one cost is that every value written by
#   `set` now round-trips through a quoted encoding rather than staying
#   bare on disk -- see cmd_get/cmd_cursor/cmd_trim_note below, which strip
#   it back off symmetrically, so nothing downstream has to know.
_yaml_encode_value() {
  _yaml_quote "$(_yaml_collapse "$1")"
}

# _yaml_decode_value <value already stripped of its "key:" prefix and leading
#                      whitespace, as cmd_get/cmd_cursor already do>
#   The exact inverse of _yaml_quote: if <value> is wrapped in a single pair
#   of matching single quotes, strip them and un-double `''` back to `'`.
#   A NO-OP on anything else, EXCEPT a legacy value that already happened to
#   be wrapped in single quotes on its own (never written by this file, but
#   possible by hand or by an older tool) -- that is decoded exactly as YAML
#   would read it, same as anything cmd_set now writes. Every other bare/
#   legacy value -- everything cmd_write ever produces (it validates
#   structure, not per-value encoding), and every value that happened to
#   round-trip bare before this task existed -- passes through unchanged.
#   That direction matters more than the forward one: every consumer repo
#   already has a run-state on disk, and it must keep reading correctly.
_yaml_decode_value() {
  case "$1" in
    \'*\')
      local body="$1"
      body="${body#\'}"; body="${body%\'}"
      printf '%s' "$body" | sed "s/''/'/g"
      ;;
    *)
      printf '%s' "$1" ;;
  esac
}

# --- atomic set/insert of a flat top-level key -------------------------------
# The only write path that takes an arbitrary agent-supplied VALUE as an
# argument -- and until this task, the only one that wrote it as an unquoted
# plain scalar. `: ` in the value opened a sibling mapping key and broke the
# file; it fired live at a packet close whose note read "... blocked on the
# commit: the harness denied it" (runstate-write-integrity capability 1).
#
# T10: the hazard on the TARGET's side, not the value's. A single column-0
# line replacement strands the indented body when the CURRENT value is a
# multi-line block scalar (`|`, `>`, and their chomping/indent variants --
# `|-`, `|+`, `>-`, `>+`) -- exactly what cmd_trim_note emits for `note:` by
# design, so `set <file> note <one line>` right after a trim is the ORDINARY
# path that reproduces it, not an edge case. HANDLED here, not refused: a
# block scalar's body boundary is well-defined by YAML itself -- its lines
# are indented, and the first column-0 line ends it -- and this file already
# relies on exactly that rule to find a block's end in cmd_trim_note above,
# so reusing it here is not a new heuristic. Refusing would turn the single
# most reachable `set` call (overwriting `note:` right after a trim) into a
# hard stop for every caller, forcing a full `write` reassembly for what is
# otherwise an ordinary one-line update.
cmd_set() {
  local f="${1:-}" key="${2:-}" val="${3:-}"
  [ -n "$f" ] && [ -n "$key" ] || die "usage: set <file> <key> <value>"
  need_file "$f"
  local dir tmp enc; dir="$(dirname "$f")"
  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" || die "cannot create temp file in ${dir}"
  enc="$(_yaml_encode_value "$val")"
  if grep -qE "^${key}:" "$f"; then
    # Literal-prefix match in awk, interpolated through ENVIRON -- never `-v`,
    # which expands `\n` IN THE VALUE (the exact hazard ADR 0022 names), and
    # never sed replacement text, which expands `&` to the whole match and
    # `\1` to a capture group and (via the old `s|...|...|` delimiter) broke
    # outright on a value containing `|`.
    #
    # inblock tracks whether the line under the cursor is part of the OLD
    # value's block-scalar body: it is set the moment the matched header's
    # remainder looks like a block indicator, and cleared the moment a
    # column-0 "key:" line reappears -- the same boundary cmd_trim_note uses
    # to find a block's end, above. Every line consumed while inblock is
    # skipped (never printed), so the new header line replaces the ENTIRE
    # old value, header and stranded body alike, not just its first line.
    KEY="$key" ENC="$enc" awk '
      BEGIN { k = ENVIRON["KEY"] ":"; inblock = 0 }
      inblock {
        if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*:/) { inblock = 0 } else next
      }
      !inblock && index($0, k) == 1 {
        rest = substr($0, length(k) + 1)
        sub(/^[[:space:]]+/, "", rest)
        print ENVIRON["KEY"] ": " ENVIRON["ENC"]
        if (rest ~ /^[|>][-+]?[0-9]*[[:space:]]*$/) inblock = 1
        next
      }
      { print }
    ' "$f" > "$tmp"
  else
    # printf is safe here without any of the above: $enc is passed as an
    # ARGUMENT to `%s`, never as (or into) the format string, so printf never
    # reinterprets its contents.
    cp "$f" "$tmp"; printf '%s: %s\n' "$key" "$enc" >> "$tmp"
  fi
  mv -f "$tmp" "$f"
}

# --- bound the freeform `note:` field, archiving the overflow ----------------
# The template documents `note:` as ONE line the resuming session reads first. In a
# real run it reached 164,678 chars — 87% of the whole run-state file, ~41k tokens,
# carrying 15 stacked "earlier history" sections. Nothing appended it on purpose:
# each packet added its narrative and nothing ever removed one, because nothing here
# enforced the documented contract and the prompts never named a budget.
#
# That cost is paid on EVERY relay dispatch, where a fresh coordinator reads run-state
# to answer only "did it land, what is next" (ADR 0012) — so ~41k tokens are re-read
# to recover two facts, and they land in the standing context that gets re-cached.
#
# Trimming, not deleting: the overflow is appended to run-state-note-archive.md next
# to the run-state, so the narrative survives for a human while leaving the hot path.
#
# THE TRIMMED NOTE IS ALWAYS RE-EMITTED AS A LITERAL BLOCK SCALAR (`note: |-`),
# whatever shape it had before. This is the whole reason the function is safe, and it
# is a property of block scalars rather than care taken here: block content is verbatim
# lines, so ANY byte-prefix of it is still well-formed. Cutting a quoted scalar is not —
# the earlier version truncated `note: "…"` mid-string, severed the closing quote and
# produced a run-state that no longer parsed. Since a note describing a packet very
# often contains `: `, it MUST be quoted or block; and of those two only block can be
# truncated. So the cut and the encoding are one decision, not two.
#
# Everything after the cut is indented two spaces to sit inside the block, and the
# marker line is indented with it — an unindented line would close the scalar early and
# be read as a sibling key.
cmd_trim_note() {
  local f="${1:-}" max="${2:-}"
  [ -n "$f" ] || die "usage: trim-note <file> [max-bytes]"
  need_file "$f"
  max="${max:-${ORCH_NOTE_MAX_BYTES:-2000}}"
  case "$max" in ''|*[!0-9]*) die "max-bytes must be a number" ;; esac

  # `|| true`: no-match makes grep exit 1, which under `set -euo pipefail` kills the
  # script before the emptiness check below ever runs — the same fail-by-absence trap
  # documented for guard.sh. An absent note is a legitimate state, not an error.
  local start
  start="$(grep -n '^note:' "$f" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  if [ -z "$start" ]; then printf 'TRIMMED=no\nREASON=no-note-field\n'; return 0; fi

  # The note runs to the next TOP-LEVEL key (column 0), else to EOF — which covers
  # both the one-line shape and the block/multi-line shape a run actually produces.
  local total end
  total="$(wc -l < "$f" | tr -d ' ')"
  end="$(awk -v s="$start" 'NR>s && /^[A-Za-z_][A-Za-z0-9_]*:/ {print NR-1; exit}' "$f")"
  [ -n "$end" ] || end="$total"

  local size
  size="$(awk -v s="$start" -v e="$end" 'NR>=s && NR<=e' "$f" | wc -c | tr -d ' ')"
  if [ "$size" -le "$max" ]; then
    printf 'TRIMMED=no\nBYTES=%s\nMAX=%s\n' "$size" "$max"; return 0
  fi

  local dir arch tmp stamp
  dir="$(dirname "$f")"; arch="${dir}/run-state-note-archive.md"
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  { printf '\n<!-- archived %s — %s bytes trimmed from run-state note -->\n\n' "$stamp" "$size"
    awk -v s="$start" -v e="$end" 'NR>=s && NR<=e' "$f"
  } >> "$arch" || die "cannot write ${arch}"

  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" || die "cannot create temp file in ${dir}"
  { [ "$start" -gt 1 ] && awk -v s="$start" 'NR < s' "$f"
    printf 'note: |-\n'
    # Strip the old encoding down to raw text, then re-emit it as block content:
    # drop the `note:` key from the first line, drop a `|`/`|-`/`>`/`>-` block header,
    # and unwrap a surrounding quote pair. What is left is verbatim text that cannot
    # carry YAML meaning once it is indented inside the block.
    #
    # This is the SAME encoding _yaml_decode_value (above cmd_set) undoes, kept
    # as its own awk implementation rather than shelling out per-line, since it
    # runs inline inside this one larger awk pass. It must stay in step by hand:
    # a double-quoted wrap strips its surrounding quotes (legacy shape, never
    # written by this file); a SINGLE-quoted wrap -- what cmd_set now always
    # writes -- must ALSO un-double `''` back to `'`, which the previous version
    # did not do (it stripped only a leading quote, via a `sub(/^'"'"'$/, "")`
    # that could only ever match a string consisting of nothing but one quote
    # character, so a trailing quote and any doubled `''` survived straight
    # into the trimmed note).
    awk -v s="$start" -v e="$end" -v m="$max" '
      NR<s || NR>e { next }
      NR==s { sub(/^note:[[:space:]]*/, "")
              if ($0 ~ /^[|>][-+]?[0-9]*[[:space:]]*$/) next   # was already a block
              if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") }
              else if ($0 ~ /^'"'"'.*'"'"'$/) {
                $0 = substr($0, 2, length($0) - 2)
                gsub(/'"''"'/, "'"'"'")
              } }
      { line = $0
        sub(/^[[:space:]][[:space:]]/, "", line)               # de-indent old block body
        if (n + length(line) + 1 > m) {                        # cut INSIDE the block
          room = m - n - 1
          if (room > 0) print "  " substr(line, 1, room)
          exit }
        n += length(line) + 1
        print "  " line }' "$f"
    printf '  [note trimmed to %s bytes at %s; full history in %s]\n' "$max" "$stamp" "$(basename "$arch")"
    [ "$end" -lt "$total" ] && awk -v e="$end" 'NR > e' "$f"
    :
  } > "$tmp" || die "cannot write temp file"
  mv -f "$tmp" "$f"
  printf 'TRIMMED=yes\nBYTES_BEFORE=%s\nMAX=%s\nARCHIVE=%s\n' "$size" "$max" "$arch"
}

# --- shared id-set helpers (ADR 0024) -----------------------------------------
# `--packets`/`--finished` both take a comma- and/or-whitespace-separated id list;
# these are the ONE place that splits/validates/dedupes them, used by add-finding,
# drop-finding and findings --stale alike.

# Print the full usage + finding-definition text (ADR 0024). Used BOTH as the
# add-finding usage-error message AND as the refusal when --packets is missing —
# they are the same message because the refusal IS the usage rule. A heredoc with
# an unquoted-but-inert delimiter avoids any shell-quoting trouble from the
# apostrophes/quotes the definition text itself contains.
_finding_usage() {
  cat <<'USAGE'
usage: add-finding <run-state-file> <id> <one-line summary> --packets <id[,id...]> [--body]

a finding is a constraint on a packet that has not executed yet, recorded because
there is nowhere permanent to put it until that packet runs. --packets <id[,id...]>
is required; there is no run-wide finding, because an entry that cannot expire is
the thing this rule removes. If it is not that, it goes somewhere else:
  - a durable fact about the environment, tools, agents or standing policy -> the
    repo's own committed files (CLAUDE.md, a comment at the site it constrains) or
    agent memory
  - a question only the human can answer -> pending_questions:
  - where this session stopped -> note: (one line)
  - "this should be built/fixed" -> the backlog (a gspec task)
USAGE
}

# Split a comma-and/or-whitespace-separated string into one id per line. No
# validation here — callers that need charset enforcement (add-finding's
# --packets) layer it on; callers that are just testing membership (findings
# --stale's --finished) don't need it, since an invalid value simply never
# matches a real packet id.
_split_ids() {
  printf '%s\n' "$1" | awk '{
    n = split($0, a, /[,[:space:]]+/)
    for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
  }'
}

# Split + validate + de-duplicate (first-seen order preserved) a --packets value.
# Dies on any id outside [a-zA-Z0-9._-] — these ids are written unquoted into a
# YAML flow sequence and are also used as filenames elsewhere in this file.
_normalize_id_list() {
  local raw="$1" out="" seen="," id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!a-zA-Z0-9._-]*) die "packet id '${id}' must be [a-zA-Z0-9._-] (it is written into a YAML flow sequence)" ;;
    esac
    case "$seen" in *",${id},"*) continue ;; esac
    seen="${seen}${id},"
    out="${out:+${out},}${id}"
  done <<EOF
$(_split_ids "$raw")
EOF
  printf '%s' "$out"
}

# Is $1 present (exact match) in the newline-separated set $2?
_id_in_set() { printf '%s\n' "$2" | grep -qxF "$1"; }

# Restore a set-aside finding body on a failed drop-finding — best-effort, never
# fails the caller (the caller is already mid-`die`).
_restore_aside() {
  [ -n "${1:-}" ] && [ -f "${1:-}" ] && mv -f "$1" "$2" 2>/dev/null
  return 0
}

# --- add a finding: one-line index entry here, body in .agents/findings/ ------
# ADR 0022/0024. Run-state is read by EVERY packet and sits in the standing context
# for a whole dispatch, so content useful to one packet is paid for by all of them.
# The summary stays hot so an agent can decide whether it needs the body; the body
# (opt-in, --body) goes cold in .agents/findings/<id>.md.
#
# PACKET-SCOPED, NOT RUN-WIDE (ADR 0024). A finding is a constraint on a packet
# that has not executed yet — see _finding_usage for the full definition and the
# four non-finding homes. --packets is mandatory so every entry can expire once
# the packets it names have all run; an entry that names nothing could never be
# recognized as stale by `findings --stale` and would accumulate forever, which is
# exactly the failure this rule removes.
#
# A script rather than "the agent edits the YAML": appending to a list is the one
# edit that reliably produces malformed run-state (wrong indent, a second `findings:`
# key, a list item merged into the previous one), and this file is the loop's only
# durable state. Placement is deliberate — inserted directly after the `findings:`
# key so the entry cannot land inside `pending_questions` or after `note:`.
#
# Idempotent on id: re-adding an existing id updates nothing and reports it, so a
# retried packet cannot produce duplicate index entries pointing at one body.
#
# NEWEST FIRST. The entry goes immediately after the `findings:` key, which is the
# only placement that cannot land in the wrong section — locating the end of the list
# means guessing where the block stops, and guessing wrong writes the entry into
# `note:` or `pending_questions:`. Newest-first also happens to be the right read
# order for an index that gets scanned rather than paged through.
cmd_add_finding() {
  local f="" id="" summary="" packets_raw="" want_body=0 pos=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --packets)   packets_raw="${2:-}"; shift 2 ;;
      --packets=*) packets_raw="${1#--packets=}"; shift ;;
      --body)      want_body=1; shift ;;
      # Only a `--`-prefixed (long-option) token is treated as a flag: the
      # summary is free text and legitimately may start with a single `-`
      # (e.g. "- leading dash reads as a list item"), which must land as the
      # positional summary, not be rejected as an unrecognized option.
      --*)         die "$(_finding_usage) (unknown option: $1)" ;;
      *)
        case "$pos" in
          0) f="$1" ;;
          1) id="$1" ;;
          2) summary="$1" ;;
          *) die "$(_finding_usage) (too many arguments)" ;;
        esac
        pos=$((pos + 1))
        shift ;;
    esac
  done
  [ -n "$f" ] && [ -n "$id" ] && [ -n "$summary" ] || die "$(_finding_usage)"
  need_file "$f"
  case "$id" in
    *[!a-zA-Z0-9._-]*|'') die "finding id must be [a-zA-Z0-9._-] (it becomes a filename)" ;;
  esac

  # --packets is validated (including the "missing" refusal) BEFORE the
  # duplicate-id check and before anything is written — an argument error must
  # never write a partial entry.
  [ -n "$packets_raw" ] || die "$(_finding_usage)"
  local packets_csv
  packets_csv="$(_normalize_id_list "$packets_raw")"
  [ -n "$packets_csv" ] || die "$(_finding_usage)"

  # A newline in the summary would break the single-line YAML scalar and, worse, could
  # inject a sibling key. Collapse rather than reject: the caller is an agent mid-loop.
  # _yaml_collapse (shared with cmd_set, above) is the ONE place this happens.
  summary="$(_yaml_collapse "$summary")"

  # SINGLE-QUOTED YAML scalar, with `'` doubled -- via the shared _yaml_quote
  # helper (defined above cmd_set), which cmd_set now also calls, so a future
  # hardening of one cannot leave the other behind. $summary is already
  # collapsed above; _yaml_quote takes an already-collapsed value. The reason
  # it is single- and not double-quoted: a single-quoted YAML scalar performs
  # NO escape processing, so `'' -> '` is the ONLY rule and a backslash is
  # already literal. Double-quoting would need `\` and `"` escaped and would
  # then re-interpret `\n`; plain (unquoted) was the original shape and could
  # not survive a `: ` in the summary at all, which is the single most likely
  # character sequence in a finding about code.
  #
  # This is also why nothing here needs `jq`. Making the summary safe is one
  # substitution in any POSIX shell, so `add-finding` keeps working on stock
  # Git Bash, which ships neither jq nor a real python3 (the same constraint
  # guard.sh is built around).
  local q_summary
  q_summary="$(_yaml_quote "$summary")"

  # Duplicate check, scoped to the findings BLOCK and matched LITERALLY.
  #   - scoped: schema 3 carries `packets:` entries in the same `  - id: <x>` shape, so a
  #     whole-file scan silently refuses a finding named after a packet — which is a
  #     natural name for a finding ABOUT that packet.
  #   - literal (`grep -F` on an exact line): `.` is a legal id character and a live regex
  #     metachar, so `f.001` matched `f-001` and reported a duplicate that did not exist.
  local in_findings
  in_findings="$(awk '
    /^findings:[[:space:]]*$/ { inf=1; next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inf=0 }
    inf { print }' "$f" 2>/dev/null || true)"
  if printf '%s\n' "$in_findings" | grep -qxF "  - id: ${id}"; then
    printf 'ADDED=no\nREASON=duplicate-id\nID=%s\n' "$id"; return 0
  fi

  # The index entry must point at where the body ACTUALLY went. Deriving both from the
  # same `dir` is what keeps them in step; the previously hardcoded `.agents/…` was
  # correct only when run-state sat at exactly `.agents/run-state.yaml` and produced a
  # dangling index everywhere else — including in its own tests, which asserted the
  # hardcoded string and so could never catch it.
  local dir body rel
  dir="$(dirname "$f")"
  body="${dir}/findings/${id}.md"
  rel="$(basename "$dir")/findings/${id}.md"

  # The body is OPT-IN (--body, ADR 0024): measured, a real body ran ~6,789 bytes
  # against a ~362-byte summary — hand an agent three empty headings and it fills
  # them, whether the finding needed the detail or not. Most findings need only
  # the index entry; `file:` appears in the entry ONLY when a body was actually
  # written, so `findings` never points at a file that doesn't exist.
  if [ "$want_body" = 1 ]; then
    mkdir -p "${dir}/findings" 2>/dev/null || die "cannot create ${dir}/findings"
    if [ ! -f "$body" ]; then
      { printf '# %s\n\n' "$id"
        printf '> %s\n\n' "$summary"
        printf -- '- recorded: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '## What was found\n\n<the detail that did NOT belong in run-state>\n\n'
        printf '## Why it matters / what to do about it\n\n<so a later packet can act on it>\n\n'
        printf '## Scope\n\n<the evidence tying this finding to the packet(s) already recorded in the index entry above>\n'
      } > "$body" || die "cannot write ${body}"
    fi
  fi

  # Build the new index entry as one string (real newlines, command substitution
  # strips only the trailing one) so it can be injected through ENVIRON as a single
  # value — never `awk -v`, which processes backslash escapes in the VALUE and would
  # re-open the exact injection the `tr` collapse above exists to close.
  # The trailing `:` below always exits 0. Under `set -e`, `var=$(...)` propagates
  # the subshell's exit status, and the conditional printf above returns 1
  # (skipped) when --body was not given, which would silently kill the whole
  # script right here. (No comment inside the $(...) itself: an apostrophe in a
  # comment nested inside a command substitution confuses bash's lexer for the
  # matching close-paren — a real, reproducible bash quirk, not a style choice.)
  local packets_flow entry
  packets_flow="$(printf '%s' "$packets_csv" | sed 's/,/, /g')"
  entry="$(
    printf '  - id: %s\n' "$id"
    printf '    summary: %s\n' "$q_summary"   # already quoted by _yaml_quote
    printf '    packets: [%s]\n' "$packets_flow"
    if [ "$want_body" = 1 ]; then printf '    file: %s' "$rel"; fi
    :
  )"

  local tmp
  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" || die "cannot create temp file in ${dir}"
  if grep -qE '^findings:' "$f"; then
    ENTRY="$entry" awk '
      { print }
      /^findings:[[:space:]]*$/ && !done { printf "%s\n", ENVIRON["ENTRY"]; done=1 }
    ' "$f" > "$tmp"
  else
    # No findings key yet (a run-state from an older template): create the section at
    # the end rather than guessing an insertion point mid-file.
    { cat "$f"
      printf 'findings:\n'
      printf '%s\n' "$entry"
    } > "$tmp"
  fi
  mv -f "$tmp" "$f"
  # ONE write, not two: a caller piping this into `grep -q` (common in the test
  # sweep) can close its end the instant it matches the first line, and a SECOND
  # printf attempting to write into that already-closed pipe gets killed by
  # SIGPIPE — under `pipefail` that reports a false failure even though the
  # match succeeded. A single call is atomic up to PIPE_BUF, so there is no
  # window for a reader to close between two writes that never happen.
  local out="ADDED=yes
ID=${id}
PACKETS=${packets_csv}"
  [ "$want_body" = 1 ] && out="${out}
FILE=${body}"
  printf '%s\n' "$out"
  return 0
}

# --- drop a finding: remove the index entry AND the body, both or neither -----
# ADR 0024. Mechanics: locate the entry by a LITERAL match on the exact line
# `  - id: <id>`, scoped to the findings block (same reasoning as the add-finding
# duplicate check — `.` is a legal id char and a regex metachar, and schema-3
# `packets:` entries share the `- id:` shape). If a body exists, set it aside to a
# SIBLING temp name in ITS OWN directory (.agents/findings/) — same-directory
# rename is atomic, and keeping it out of the run-state's own directory means a
# forced failure building the run-state's temp file (step 3) or replacing
# run-state (step 4) can restore the body from a location the failure never
# touched. Order: set aside -> build new run-state -> swap it in -> delete the
# set-aside body. Any failure in the middle restores the body and dies, leaving
# BOTH the index entry and the body present — never one without the other.
cmd_drop_finding() {
  local f="${1:-}" id="${2:-}"
  [ -n "$f" ] && [ -n "$id" ] || die "usage: drop-finding <run-state-file> <id>"
  need_file "$f"
  case "$id" in
    *[!a-zA-Z0-9._-]*|'') die "finding id must be [a-zA-Z0-9._-] (it is a filename)" ;;
  esac

  local in_findings
  in_findings="$(awk '
    /^findings:[[:space:]]*$/ { inf=1; next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inf=0 }
    inf { print }' "$f" 2>/dev/null || true)"
  if ! printf '%s\n' "$in_findings" | grep -qxF "  - id: ${id}"; then
    printf 'DROPPED=no\nREASON=not-found\nID=%s\n' "$id"; return 0
  fi

  local dir findingsdir body aside=""
  dir="$(dirname "$f")"
  findingsdir="${dir}/findings"
  body="${findingsdir}/${id}.md"
  if [ -f "$body" ]; then
    aside="$(mktemp "${findingsdir}/.${id}.aside.XXXXXX")" || die "cannot create temp file in ${findingsdir}"
    mv -f "$body" "$aside" || die "cannot set aside ${body}"
  fi

  local tmp
  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" \
    || { _restore_aside "$aside" "$body"; die "cannot create temp file in ${dir}"; }
  ID="$id" awk '
    BEGIN { target = "  - id: " ENVIRON["ID"] }
    /^findings:[[:space:]]*$/ { print; inf = 1; next }
    inf && /^[A-Za-z_][A-Za-z0-9_]*:/ { inf = 0; skip = 0; print; next }
    inf && /^[[:space:]]*- id:/ {
      skip = ($0 == target) ? 1 : 0
      if (!skip) print
      next
    }
    inf && skip { next }
    { print }
  ' "$f" > "$tmp" || { rm -f "$tmp"; _restore_aside "$aside" "$body"; die "failed to build updated run-state"; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; _restore_aside "$aside" "$body"; die "cannot replace run-state"; }
  [ -n "$aside" ] && rm -f "$aside"

  if [ -n "$aside" ]; then
    printf 'DROPPED=yes\nID=%s\nBODY=removed\n' "$id"
  else
    printf 'DROPPED=yes\nID=%s\nBODY=none\n' "$id"
  fi
}

# --- list the finding index (ids + summaries only, never the bodies) ----------
# The read side of the same contract: an agent checks THIS, then opens only the
# bodies it needs. Printing summaries here — and nothing else — is what keeps the
# "index hot, body cold" split from silently collapsing back into "read everything".
#
# `--stale` is a BACKSTOP for when the drop-at-packet-close discipline slips, not
# the intended path — the intended path is `drop-finding` right after the packet(s)
# a finding names have landed. It answers "which entries could be dropped" against
# a caller-SUPPLIED finished-packet set; unsupplied, every named packet reads
# `unknown` and nothing expires (ADR 0024's safety property: a caller that skips
# the wiring expires nothing rather than expiring the wrong thing).
cmd_findings() {
  local f="" stale=0 finished_raw="" max_bytes=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stale)          stale=1; shift ;;
      --finished)       finished_raw="${2:-}"; shift 2 ;;
      --finished=*)     finished_raw="${1#--finished=}"; shift ;;
      --max-bytes)      max_bytes="${2:-}"; shift 2 ;;
      --max-bytes=*)    max_bytes="${1#--max-bytes=}"; shift ;;
      --*) die "usage: findings <run-state-file> [--stale] [--finished <id[,id...]>] [--max-bytes <n>] (unknown option: $1)" ;;
      *)
        [ -z "$f" ] || die "usage: findings <run-state-file> [--stale] [--finished <id[,id...]>] [--max-bytes <n>] (too many arguments)"
        f="$1"; shift ;;
    esac
  done
  [ -n "$f" ] || die "usage: findings <run-state-file> [--stale] [--finished <id[,id...]>] [--max-bytes <n>]"
  need_file "$f"
  if [ "$stale" = 1 ]; then
    _findings_stale "$f" "$finished_raw" "$max_bytes"
  else
    _findings_default "$f"
  fi
}

# id / summary(decoded) / file / packets(csv) — one TSV row per entry, index order.
_findings_default() {
  awk '
    /^findings:[[:space:]]*$/ { inf=1; next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inf=0 }
    inf && /^[[:space:]]*- id:/    { if (id != "") print id "\t" sum "\t" file "\t" pkts; sum=""; file=""; pkts="";
                                     sub(/^[[:space:]]*- id:[[:space:]]*/, ""); id=$0; next }
    inf && /^[[:space:]]*summary:/ { line=$0; sub(/^[[:space:]]*summary:[[:space:]]*/, "", line);
                                     # Undo the single-quoted encoding the write side
                                     # applies: strip the wrapping quotes, then `'"''"'` -> `'"'"'`.
                                     # Left alone, every summary would print wrapped in
                                     # quotes and an agent would copy them into a brief.
                                     if (line ~ /^'"'"'.*'"'"'$/) {
                                       line = substr(line, 2, length(line) - 2)
                                       gsub(/'"''"'/, "'"'"'", line) }
                                     sum=line; next }
    inf && /^[[:space:]]*packets:/ { line=$0; sub(/^[[:space:]]*packets:[[:space:]]*/, "", line);
                                     sub(/^\[/, "", line); sub(/\]$/, "", line);
                                     gsub(/, */, ",", line); pkts=line; next }
    inf && /^[[:space:]]*file:/    { line=$0; sub(/^[[:space:]]*file:[[:space:]]*/, "", line); file=line; next }
    END { if (id != "") print id "\t" sum "\t" file "\t" pkts }
  ' "$1" | grep -v '^<' || true
}

# id \t packets(csv, "" when absent) — one row per entry, index order. Feeds the
# three-state (finished/pending/unknown) scan in _findings_stale.
_findings_entries() {
  awk '
    /^findings:[[:space:]]*$/ { inf=1; next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inf=0 }
    inf && /^[[:space:]]*- id:/    { if (id != "") print id "\t" pkts; pkts="";
                                     sub(/^[[:space:]]*- id:[[:space:]]*/, ""); id=$0; next }
    inf && /^[[:space:]]*packets:/ { line=$0; sub(/^[[:space:]]*packets:[[:space:]]*/, "", line);
                                     sub(/^\[/, "", line); sub(/\]$/, "", line);
                                     gsub(/, */, ",", line); pkts=line; next }
    END { if (id != "") print id "\t" pkts }
  ' "$1"
}

# The ids named by `backlog: cursor:` + `backlog: pending:` in THIS run-state —
# runstate.sh reads no other file and shells out to nothing, so this is the whole
# "pending" universe it can see.
_findings_pending_ids() {
  local f="$1" cursor
  cursor="$(cmd_cursor "$f")"
  { [ -n "$cursor" ] && printf '%s\n' "$cursor"
    awk '/^[[:space:]]*pending:/{f=1;next} /^[^[:space:]]/{f=0}
         f && /^[[:space:]]*-[[:space:]]*/ { line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line); print line }' "$f"
  } | awk 'NF'
}

# Byte size of the whole `findings:` block: its key line through the last line
# before the next column-0 key (or EOF). Same start/end technique as trim-note's
# note-block bound, applied to a different key.
_findings_index_bytes() {
  local f="$1" start end total
  start="$(grep -n '^findings:' "$f" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  [ -n "$start" ] || { printf 0; return 0; }
  total="$(wc -l < "$f" | tr -d ' ')"
  end="$(awk -v s="$start" 'NR>s && /^[A-Za-z_][A-Za-z0-9_]*:/ {print NR-1; exit}' "$f")"
  [ -n "$end" ] || end="$total"
  awk -v s="$start" -v e="$end" 'NR>=s && NR<=e' "$f" | wc -c | tr -d ' '
}

# --- findings --stale: which entries are expired against a SUPPLIED finished set --
# THE SAFETY PROPERTY: the finished set comes ONLY from --finished. There is no
# fallback to gspec, git, or `backlog.done` — runstate.sh calls no other script and
# never reads gspec/, so a caller that forgets to wire --finished gets STALE_COUNT=0
# for every run, never a false expiry. "Absence is never finished": a packet named
# by an entry but not in the finished set, not in this file's own backlog cursor/
# pending either, reads `unknown` and blocks expiry exactly like a pending one.
_findings_stale() {
  local f="$1" finished_raw="$2" max_bytes="$3"
  max_bytes="${max_bytes:-${ORCH_FINDINGS_INDEX_MAX_BYTES:-4096}}"
  case "$max_bytes" in ''|*[!0-9]*) die "max-bytes must be a number" ;; esac

  local finished_set pending_set
  finished_set="$(_split_ids "$finished_raw")"
  pending_set="$(_findings_pending_ids "$f")"

  # Accumulate every line and print ONCE at the end (see the same note on
  # cmd_add_finding's final printf): a caller piping this into `grep -q` on an
  # EARLY line (e.g. one FINDING= row) can close the pipe before the later rows
  # and the STALE_COUNT trailer are written, killing this function with SIGPIPE
  # and reporting a false failure under `pipefail` even though the match hit.
  local stale_count=0 entries id pkts_csv out=""
  entries="$(_findings_entries "$f")"
  while IFS="$(printf '\t')" read -r id pkts_csv; do
    [ -n "$id" ] || continue
    if [ -z "$pkts_csv" ]; then
      out="${out}FINDING=${id} STALE=no blocked_by=<none>:unknown packets=
"
      continue
    fi
    local is_stale=1 blocked_pkt="" blocked_state="" p state
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if _id_in_set "$p" "$finished_set"; then state=finished
      elif _id_in_set "$p" "$pending_set"; then state=pending
      else state=unknown
      fi
      if [ "$state" != finished ]; then
        is_stale=0
        [ -n "$blocked_pkt" ] || { blocked_pkt="$p"; blocked_state="$state"; }
      fi
    done <<EOF
$(printf '%s' "$pkts_csv" | tr ',' '\n')
EOF
    if [ "$is_stale" = 1 ]; then
      out="${out}FINDING=${id} STALE=yes packets=${pkts_csv}
"
      stale_count=$((stale_count + 1))
    else
      out="${out}FINDING=${id} STALE=no blocked_by=${blocked_pkt}:${blocked_state} packets=${pkts_csv}
"
    fi
  done <<EOF
$entries
EOF

  local ibytes over
  ibytes="$(_findings_index_bytes "$f")"
  over=no
  [ "$ibytes" -gt "$max_bytes" ] && over=yes
  out="${out}STALE_COUNT=${stale_count}
INDEX_BYTES=${ibytes}
MAX_BYTES=${max_bytes}
OVER_THRESHOLD=${over}"
  printf '%s\n' "$out"
}

# --- record an ATTESTED packet outcome (ADR 0019 v3.4) -----------------------
# Append-only, one line per packet boundary, to .agents/metrics/outcomes/<session>.jsonl.
# The collector reconstructs packets from green-commit trailers, so it structurally
# cannot see a packet that failed or was rolled back — those never produce a commit.
# Only the loop knows, and only at the boundary, so it has to say so here.
#
# NOT written into run-state: run-state has a single writer (the driver) and this must
# be callable from a lane without contending for it — the same reason packet boundaries
# were left on commit trailers instead of migrating run-state's schema (ADR 0019).
# Append-only + last-wins means a retried packet correctly ends up at its final state.
# SESSION ID: `CLAUDE_CODE_SESSION_ID`, which is the variable Claude Code actually
# exports to a Bash tool call. The first cut read `CLAUDE_SESSION_ID`, which does not
# exist — so every attestation from every run fell through to the `adhoc` default and
# landed in ONE file, and the collector then joined a packet id to whichever run last
# used that name. Verified rather than assumed: this env var is byte-identical to the
# `.session_id` in the PostToolUse payload that names `.agents/metrics/events/<id>.jsonl`,
# so `outcomes/<id>.jsonl` and `events/<id>.jsonl` share a key and the collector can
# scope outcomes with the same `--session` selection it already applies to events.
cmd_record_outcome() {
  local pkt="${1:-}" outcome="${2:-}" sess="${3:-${CLAUDE_CODE_SESSION_ID:-adhoc}}"
  [ -n "$pkt" ] && [ -n "$outcome" ] || die "usage: record-outcome <packet-id> <green|failed|rolled-back|blocked|abandoned> [session-id]"
  # Same charset rule as a finding id: this value is interpolated into a JSON line, and
  # a `"` or `\` in it emits invalid JSON that makes the collector's `jq -s` drop EVERY
  # attestation at once, silently, with no diagnostic.
  case "$pkt" in
    *[!a-zA-Z0-9._-]*) die "packet id must be [a-zA-Z0-9._-]" ;;
  esac
  case "$outcome" in
    green|failed|rolled-back|blocked|abandoned) ;;
    *) die "outcome must be one of: green failed rolled-back blocked abandoned" ;;
  esac
  # Resolve the MAIN checkout the same way the hooks do: --git-common-dir points at
  # the main repo even from a lane worktree, so every lane records into one log.
  local gcd main_root dir
  gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gcd" ] || gcd="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd || true)"
  [ -n "$gcd" ] || { printf 'RECORDED=no\nREASON=not-a-git-repo\n'; return 0; }
  main_root="$(dirname "$gcd")"
  dir="${main_root}/.agents/metrics/outcomes"
  mkdir -p "$dir" 2>/dev/null || { printf 'RECORDED=no\nREASON=cannot-create-dir\n'; return 0; }
  # Same atomicity argument as the metrics hook: a single short line, O_APPEND, well
  # under PIPE_BUF, so concurrent lanes sharing a session id cannot tear each other.
  printf '{"ts":"%s","packet":"%s","outcome":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pkt" "$outcome" >> "${dir}/${sess}.jsonl" 2>/dev/null \
    || { printf 'RECORDED=no\nREASON=cannot-append\n'; return 0; }
  printf 'RECORDED=yes\nPACKET=%s\nOUTCOME=%s\n' "$pkt" "$outcome"
}

# --- stamp updated_at = now (UTC), atomically -------------------------------
cmd_touch() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: touch <file>"
  cmd_set "$f" updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# =============================================================================
# Driver identity + terminal state (ADR 0020 D5)
# =============================================================================

# WHY A HEARTBEAT AND NOT A PID. ADR 0020 D5 borrowed gspec's pid-liveness check
# verbatim. It does not transfer, and implementing it proved so: gspec's driver IS
# one long-lived node process (`lib/build.js` runs for the whole build), so its pid
# means something. THIS driver is a Claude Code session issuing discrete tool
# calls — `runstate.sh` is a short-lived subprocess, so `$$` is dead the instant
# the command returns and every later check reports `dead`. There is no
# long-lived process to point at. Staleness is the transferable idea: the driver
# restamps `driver_heartbeat` at each safe checkpoint (where it already polls the
# pause sentinel), and a heartbeat older than the window means nobody is driving.
# An explicit pid is still accepted from a caller that genuinely has a long-lived
# one (a CI wrapper, a background runner) and then OUTRANKS the heartbeat.

DRIVER_STALE_SECS="${ORCH_DRIVER_STALE_SECS:-900}"   # 15 min

# ISO-8601 UTC -> epoch seconds, on both BSD and GNU date (same dual-dialect
# problem statusline-pause-sensor.sh solves, ADR 0018). Empty on failure.
_iso_epoch() {
  [ -n "${1:-}" ] || return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null || true
}

# --- claim-driver: mark this run as actively driven --------------------------
cmd_claim_driver() {
  local f="${1:-}" pid="${2:-}"
  [ -n "$f" ] || die "usage: claim-driver <file> [pid]"
  need_file "$f"
  local host; host="$(hostname 2>/dev/null || printf 'unknown')"
  cmd_set "$f" driver_host      "$host"
  cmd_set "$f" driver_since     "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cmd_set "$f" driver_heartbeat "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Only record a pid the CALLER vouches for as long-lived. Never `$$`.
  [ -z "$pid" ] || cmd_set "$f" driver_pid "$pid"
  cmd_touch "$f"
  printf 'DRIVER=claimed HOST=%s%s\n' "$host" "${pid:+ PID=$pid}"
}

# --- heartbeat: "still driving" — call at every safe checkpoint ---------------
cmd_heartbeat() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: heartbeat <file>"
  need_file "$f"
  cmd_set "$f" driver_heartbeat "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cmd_touch "$f"
  printf 'HEARTBEAT=%s\n' "$(cmd_get "$f" driver_heartbeat)"
}

# --- driver-status: is anyone still driving this run? ------------------------
# Sets DS_STATE as a side effect so callers (summary, outcome) branch without
# re-parsing. `foreign` is deliberately NOT treated as dead: a driver recorded on
# a different machine tells us nothing about a local process, and guessing "dead"
# there would invite two drivers on a shared checkout.
DS_STATE=""; DS_AGE=""
_driver_state() {
  local f="$1" pid host me hb hb_e now
  pid="$(cmd_get "$f" driver_pid)"
  host="$(cmd_get "$f" driver_host)"
  hb="$(cmd_get "$f" driver_heartbeat)"
  me="$(hostname 2>/dev/null || printf 'unknown')"
  DS_AGE=""
  if [ -z "$hb" ] && [ -z "$pid" ]; then DS_STATE=none; return 0; fi
  if [ -n "$host" ] && [ "$host" != "$me" ]; then DS_STATE=foreign; return 0; fi
  # An explicit, caller-vouched pid outranks the heartbeat in both directions.
  if [ -n "$pid" ]; then
    if kill -0 "$pid" 2>/dev/null; then DS_STATE=live; else DS_STATE=dead; fi
    return 0
  fi
  hb_e="$(_iso_epoch "$hb")"; now="$(date -u +%s)"
  if [ -z "$hb_e" ]; then DS_STATE=none; return 0; fi   # unparseable => no claim
  DS_AGE=$(( now - hb_e ))
  if [ "$DS_AGE" -le "$DRIVER_STALE_SECS" ]; then DS_STATE=live; else DS_STATE=dead; fi
}

cmd_driver_status() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: driver-status <file>"
  need_file "$f"
  _driver_state "$f"
  printf 'DRIVER=%s' "$DS_STATE"
  [ -z "$DS_AGE" ] || printf ' AGE=%ss STALE_AFTER=%ss' "$DS_AGE" "$DRIVER_STALE_SECS"
  case "$DS_STATE" in
    none) printf '\nreason: no driver claim recorded (pre-ADR-0020 run-state, or never claimed)\n' ;;
    live) printf '\nreason: a session is driving this run right now — do NOT start a second driver\n' ;;
    dead) printf '\nreason: the driver claim is stale/gone — this run ended without pausing cleanly\n' ;;
    foreign) printf ' HOST=%s\nreason: driver was claimed on another host; resume is same-machine (ADR 0009) — cannot judge liveness\n' \
            "$(cmd_get "$f" driver_host)" ;;
  esac
}

# --- outcome: the terminal-state answer, one exit code per ending ------------
cmd_outcome() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: outcome <file>"
  need_file "$f"
  local status; status="$(cmd_get "$f" status)"; status="${status:-unknown}"
  _driver_state "$f"
  case "$status" in
    done)    printf 'OUTCOME=complete\nEXIT=0\nreason: backlog complete\n'; return 0 ;;
    paused)  printf 'OUTCOME=paused\nEXIT=2\nreason: paused cleanly at a green checkpoint — resume with /gaffer:resume\n'; return 2 ;;
    blocked) printf 'OUTCOME=blocked\nEXIT=1\nreason: paused with a blocking question the human must answer\n'; return 1 ;;
    running)
      case "$DS_STATE" in
        live)    printf 'OUTCOME=running\nEXIT=4\nDRIVER=live\nreason: a session is actively driving this loop\n'; return 4 ;;
        foreign) printf 'OUTCOME=running\nEXIT=4\nDRIVER=foreign\nreason: driver recorded on another host — cannot judge; treat as live and do not start a second driver\n'; return 4 ;;
        *)       printf 'OUTCOME=crashed\nEXIT=3\nDRIVER=%s\nreason: status is running but no live driver claim — the session died without pausing; reconcile before continuing (ADR 0005)\n' "$DS_STATE"; return 3 ;;
      esac ;;
    *) printf 'OUTCOME=unknown\nEXIT=1\nreason: unrecognized status %s\n' "$status"; return 1 ;;
  esac
}

# =============================================================================
# Pause sentinel (ADR 0017) — the cooperative-pause REQUEST channel. Write-once,
# separate from run-state, resolvable from any lane worktree. The busy loop/lanes
# poll `pause-status` at safe checkpoints; the driver reflects the OUTCOME into
# run-state (status: paused). A per-lane request is `<pause-file>.<task-id>`.
# =============================================================================

# --- request-pause: touch the sentinel atomically with a reason + timestamp ---
cmd_request_pause() {
  local f="${1:-}" reason="${2:-}"
  [ -n "$f" ] || die "usage: request-pause <pause-file> [reason]"
  local dir tmp; dir="$(dirname "$f")"
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.pause.XXXXXX")" || die "cannot create temp file in ${dir}"
  {
    printf 'requested_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -n "$reason" ] && printf 'reason: %s\n' "$reason"
  } > "$tmp"
  mv -f "$tmp" "$f"          # rename is atomic on the same filesystem
  printf 'pause requested: %s\n' "$f"
}

# --- clear-pause: remove the sentinel + any per-lane `<pause-file>.<id>` --------
# rm -f swallows the no-match case, so an unglobbed `<pause-file>.*` is harmless.
cmd_clear_pause() {
  local f="${1:-}"; [ -n "$f" ] || die "usage: clear-pause <pause-file>"
  rm -f "$f" "$f".* 2>/dev/null || true
  printf 'pause cleared: %s (+ per-lane sentinels)\n' "$f"
}

# --- pause-status: is a pause requested for the whole run or this lane? --------
# Prints PAUSE=1/0 on stdout; ALWAYS exits 0 (a query never fails the caller).
# All-scope (<pause-file>) wins over lane-scope (<pause-file>.<id>) when both exist.
cmd_pause_status() {
  local f="${1:-}" id="${2:-}" r
  [ -n "$f" ] || die "usage: pause-status <pause-file> [task-id]"
  if [ -f "$f" ]; then
    r="$(grep -E '^reason:' "$f" 2>/dev/null | head -1 | sed -E 's/^reason:[[:space:]]*//')"
    printf 'PAUSE=1 scope=all reason=%s\n' "${r:-<none>}"; return 0
  fi
  if [ -n "$id" ] && [ -f "${f}.${id}" ]; then
    r="$(grep -E '^reason:' "${f}.${id}" 2>/dev/null | head -1 | sed -E 's/^reason:[[:space:]]*//')"
    printf 'PAUSE=1 scope=lane:%s reason=%s\n' "$id" "${r:-<none>}"; return 0
  fi
  printf 'PAUSE=0\n'
}

# --- one-line human summary (SessionStart hook / check-ins) ------------------
cmd_summary() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: summary <file>"
  need_file "$f"
  local status branch cursor pending blocking
  # Best-effort hints: a run-state legitimately may not carry every scalar
  # (fresh/partial write, paused-before-first-commit, schema 3). cmd_get/cmd_cursor
  # return empty-with-exit-0 for an absent key, so these degrade to the defaults
  # below instead of aborting under set -e.
  status="$(cmd_get "$f" status)"; status="${status:-unknown}"
  branch="$(cmd_get "$f" branch)"; branch="${branch:-?}"
  cursor="$(cmd_cursor "$f")";     cursor="${cursor:-none}"
  # counts are best-effort hints, not load-bearing.
  pending="$(awk '/^[[:space:]]*pending:/{f=1;next} /^[^[:space:]]/{f=0} f&&/^[[:space:]]*-[[:space:]]/{n++} END{print n+0}' "$f")"
  blocking="$(grep -cE '^[[:space:]]*severity:[[:space:]]*blocking' "$f" || true)"
  printf 'in-flight run on %s — status=%s, cursor=%s, %s pending, %s blocking question(s)' \
    "$branch" "$status" "$cursor" "$pending" "$blocking"
  # `status: running` alone is ambiguous — it means BOTH "crashed" and "a second
  # session is driving right now". The recorded driver pid tells them apart
  # (ADR 0020 D5); with no pid recorded we keep the original crash-likely hint.
  if [ "$status" = running ]; then
    _driver_state "$f"
    case "$DS_STATE" in
      live)    printf '  [ANOTHER SESSION IS DRIVING (heartbeat %ss ago) — do not start a second driver]' "${DS_AGE:-?}" ;;
      foreign) printf '  [driver recorded on another host — cannot judge liveness; do not start a second driver]' ;;
      *)       printf '  [crash-likely: previous session did not pause cleanly — reconcile before continuing]' ;;
    esac
  fi
  printf '\n'
}

# --- reconcile: durable checkpoint vs the working tree's real git state -------
# Read-only. Prints DECISION=<clean|adopt|discard|escalate> and a reason.
cmd_reconcile() {
  local f="${1:-}" wt="${2:-}"
  [ -n "$f" ] && [ -n "$wt" ] || die "usage: reconcile <file> <work-tree>"
  need_file "$f"
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "'$wt' is not a git working tree"
  local green cursor
  green="$(cmd_get "$f" last_green_commit)"
  cursor="$(cmd_cursor "$f")"
  # Inspect the live checkout at HEAD, checking for uncommitted scratch.
  _reconcile_tree "$wt" HEAD 1 "$green" "$cursor"
  printf 'DECISION=%s\nreason: %s\n' "$RC_DECISION" "$RC_REASON"
}

# The crash-recovery decision table for ONE tree/branch, factored out so the
# sequential loop (cmd_reconcile) and the parallel loop (cmd_reconcile_parallel,
# once per lane) share EXACTLY one implementation (ADR 0005/0016). Sets globals
# RC_DECISION / RC_REASON; never prints, never exits. Args:
#   $1 inspect-tree   git work-tree to read state from (the live checkout, or a
#                     lane's worktree, or the main checkout when a lane's worktree
#                     is already gone but its branch still lives in the shared .git)
#   $2 head-ref       what to treat as HEAD (`HEAD`, or a lane branch `orch/<id>`)
#   $3 check-dirty    1 = a dirty tree means scratch (discard); 0 = ignore dirt
#                     (no live worktree, e.g. inspecting a branch by ref)
#   $4 green          recorded last_green_commit (may be short; may be empty)
#   $5 cursor         the packet id the tree/lane is expected to be on
RC_DECISION=""; RC_REASON=""
_rc() { RC_DECISION="$1"; RC_REASON="$2"; }
_reconcile_tree() {
  local wt="$1" headref="$2" check_dirty="$3" green="$4" cursor="$5"
  local head dirty ahead tag
  [ -n "$green" ] || { _rc escalate "run-state has no last_green_commit"; return 0; }
  git -C "$wt" cat-file -e "${green}^{commit}" 2>/dev/null \
    || { _rc escalate "last_green_commit ${green:0:12} is not present in this working tree"; return 0; }
  # run-state may record a SHORT sha (humans and agents write them), but a resolved
  # ref is always the canonical 40-char id. Resolve both to the same form: a raw
  # short-vs-full compare can never hit `clean`, and the fallthrough then reports
  # the self-contradictory "0 unexplained commits".
  green="$(git -C "$wt" rev-parse --verify "${green}^{commit}" 2>/dev/null)" \
    || { _rc escalate "last_green_commit could not be resolved to a commit id"; return 0; }
  head="$(git -C "$wt" rev-parse --verify "${headref}^{commit}" 2>/dev/null)" \
    || { _rc escalate "cannot resolve ${headref} to a commit"; return 0; }
  if [ "$check_dirty" = 1 ] && [ -n "$(git -C "$wt" status --porcelain)" ]; then dirty=1; else dirty=0; fi

  if [ "$head" = "$green" ]; then
    if [ "$dirty" = 0 ]; then
      _rc clean "HEAD is the green checkpoint and the tree is clean"
    else
      _rc discard "uncommitted scratch sits on top of the green checkpoint — reset to ${green:0:12}"
    fi
    return 0
  fi

  # HEAD has moved off the recorded green commit.
  if ! git -C "$wt" merge-base --is-ancestor "$green" "$head" 2>/dev/null; then
    _rc escalate "HEAD has diverged from the green checkpoint (not a fast-forward) — do not discard commits blindly"
    return 0
  fi
  ahead="$(git -C "$wt" rev-list --count "${green}..${head}")"
  if [ "$ahead" != 1 ]; then
    _rc escalate "${ahead} unexplained commits ahead of the green checkpoint — a human should look"
    return 0
  fi
  # Exactly one commit ahead: the torn-write window. Adopt it ONLY if it is a
  # clean, packet-tagged commit for the very packet the cursor is on.
  if [ "$dirty" != 0 ]; then
    _rc escalate "one orphan commit ahead AND uncommitted scratch — mixed state, a human should look"
    return 0
  fi
  tag="$(orphan_packet_tag "$wt" "$head")"
  if [ -z "$tag" ]; then
    _rc escalate "the orphan commit carries no ${PACKET_TRAILER_PREFIX}...] trailer — cannot prove it is a completed packet"
  elif [ "$tag" != "$cursor" ]; then
    _rc escalate "orphan commit is tagged for packet '${tag}' but the cursor is '${cursor}' — mismatch"
  else
    _rc adopt "one clean orphan commit tagged for the cursor packet '${cursor}' — a torn write; adopt it as the new green checkpoint"
  fi
  return 0
}

# Extract the packet id from the `[orch packet:<id>]` trailer of a commit, if any.
# Prints empty (never fails) when there is no trailer — under `set -e`/`pipefail`
# a no-match grep must not abort reconcile before it can decide `escalate`.
orphan_packet_tag() {
  local wt="$1" ref="$2" body
  body="$(git -C "$wt" log -1 --format=%B "$ref")"
  printf '%s\n' "$body" | grep -oE '\[orch packet:[a-z0-9][a-z0-9-]*\]' | head -1 \
    | sed -E 's/^\[orch packet:(.*)\]$/\1/' || true
}

# --- reconstruct: rebuild the git-derivable facts when run-state.yaml is lost ----
# Read-only. Prints RECONSTRUCT=ok + BRANCH=/TIP=/BASE=/DONE=, or RECONSTRUCT=
# escalate + a reason. The caller VERIFIES green, rebuilds the backlog from the
# committed task breakdown, and writes the run-state; this only surfaces what git
# alone can prove (branch, tip, completed-packet trailers).
cmd_reconstruct() {
  local wt="${1:-}" base="${2:-}"
  [ -n "$wt" ] || die "usage: reconstruct <work-tree> [base]"
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "'$wt' is not a git working tree"

  local branch
  branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  case "$branch" in
    orch/*) ;;
    "")
      printf 'RECONSTRUCT=escalate\nreason: %s\n' \
        "HEAD is detached — switch to the run's orch/<task-id> feature branch first"
      return ;;
    *)
      local cands
      cands="$(git -C "$wt" for-each-ref --format='%(refname:short)' 'refs/heads/orch/*' 2>/dev/null | paste -sd, - || true)"
      printf 'RECONSTRUCT=escalate\nreason: %s. Candidates: %s\n' \
        "HEAD is on '${branch}', not an orch/<task-id> branch — switch to the run's feature branch first" \
        "${cands:-<none found>}"
      return ;;
  esac

  local tip; tip="$(git -C "$wt" rev-parse HEAD)"

  # Resolve a base to bound the packet-trailer scan (integration branch first).
  if [ -z "$base" ]; then
    local b
    for b in develop main master; do
      if git -C "$wt" show-ref --verify --quiet "refs/heads/${b}"; then base="$b"; break; fi
    done
  fi
  local range="HEAD"
  if [ -n "$base" ] && git -C "$wt" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
    range="${base}..HEAD"
  fi

  # Ordered, de-duplicated packet ids from the [orch packet:<id>] trailers, oldest
  # -> newest. Same charset as orphan_packet_tag. Empty is fine (fresh branch).
  local done_csv
  done_csv="$(git -C "$wt" log --reverse --format=%B "$range" 2>/dev/null \
    | grep -oE '\[orch packet:[a-z0-9][a-z0-9-]*\]' \
    | sed -E 's/^\[orch packet:(.*)\]$/\1/' \
    | awk '!seen[$0]++' | paste -sd, - || true)"

  printf 'RECONSTRUCT=ok\nBRANCH=%s\nTIP=%s\nBASE=%s\nDONE=%s\n' \
    "$branch" "$tip" "${base:-<none>}" "$done_csv"
  printf 'note: %s %s\n' \
    "TIP is a CANDIDATE last_green_commit — verify build+tests are green before trusting it; cursor/pending come from the committed task backlog; pending_questions cannot be recovered from git." \
    "DONE is informational only — no run-state field is populated from it automatically; it is the fallback a human rebuilding a lost run-state reads to see the packet identities already committed."
}

# =============================================================================
# Parallel mode (schema 3, ADR 0016). The driver is the SINGLE writer of the
# multi-lane run-state; the helpers below are read-only projections over its
# packets[] / lanes[] lists plus the per-lane crash reconcile.
# =============================================================================

# --- parse a YAML list-of-maps section into TSV records ----------------------
# _list_records <file> <section> <field...> -> one TSV row per list item, fields
# in the requested order (missing field => empty). Understands `- key: v` (inline
# first key) + indented `key: v` continuations, over OUR OWN emitted structure
# (scalar values; a flow list like `depends_on: [a, b]` passes through verbatim as
# one value). No YAML dependency — grep/awk only, like the rest of this file.
_list_records() {
  local f="$1" section="$2"; shift 2
  local fields="$*"
  awk -v section="$section" -v fields="$fields" '
    BEGIN{ nf=split(fields,F," ") }
    $0 ~ "^"section":[ \t]*$" { insec=1; next }
    insec && /^[^ \t]/ { flush(); insec=0 }
    !insec { next }
    /^[ \t]*-[ \t]/ { flush(); reset(); have=1; s=$0; sub(/^[ \t]*-[ \t]*/,"",s); kv(s); next }
    /^[ \t]+[A-Za-z_][A-Za-z0-9_]*:/ { if(have){ s=$0; sub(/^[ \t]+/,"",s); kv(s) } }
    END{ flush() }
    function reset(   i){ for(i=1;i<=nf;i++) rec[F[i]]="" }
    function kv(s,   p,k,v){ p=index(s,":"); if(p==0) return; k=substr(s,1,p-1);
      v=substr(s,p+1); sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v);
      if(length(v)>=2 && substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") v=substr(v,2,length(v)-2);
      rec[k]=v }
    function flush(   i,out){ if(!have) return; out="";
      for(i=1;i<=nf;i++){ out=(i==1?rec[F[i]]:out "\t" rec[F[i]]) } print out; have=0 }
  ' "$f"
}

cmd_packets_by_status() {
  local f="${1:-}" st="${2:-}"
  [ -n "$f" ] && [ -n "$st" ] || die "usage: packets-by-status <file> <status>"
  need_file "$f"
  _list_records "$f" packets id status | awk -F'\t' -v s="$st" '$2==s && $1!=""{print $1}'
}

cmd_lanes() {
  local f="${1:-}"; [ -n "$f" ] || die "usage: lanes <file>"
  need_file "$f"
  _list_records "$f" lanes id branch worktree packet last_green_commit status
}

# reconcile-parallel: run the reconcile decision table once per lane. Read-only.
cmd_reconcile_parallel() {
  local f="${1:-}" main="${2:-}"
  [ -n "$f" ] && [ -n "$main" ] || die "usage: reconcile-parallel <file> <main-checkout>"
  need_file "$f"
  git -C "$main" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "'$main' is not a git working tree"
  local id branch worktree packet green status inspect headref checkdirty
  local any_escalate=0 any_action=0 nlanes=0
  # Heredoc (NOT a pipe) so the while loop runs in THIS shell: _reconcile_tree's
  # RC_* globals and the aggregate counters must survive each iteration.
  # Read on '|' (a NON-whitespace IFS), not tab: whitespace-IFS collapses the
  # empty `green` field of an un-checkpointed lane and shifts every later column.
  # Lane worktree paths / branches / shas never contain '|'.
  while IFS='|' read -r id branch worktree packet green status; do
    [ -n "$id" ] || continue
    nlanes=$((nlanes + 1))
    if [ -z "$green" ]; then
      printf 'LANE=%s DECISION=restart reason: no last_green_commit — re-dispatch the packet fresh\n' "$id"
      any_action=1; continue
    fi
    if [ -n "$worktree" ] && git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      inspect="$worktree"; headref="HEAD"; checkdirty=1     # live lane worktree: can see scratch
    else
      inspect="$main"; headref="${branch:-orch/$id}"; checkdirty=0   # worktree gone: inspect the branch
    fi
    _reconcile_tree "$inspect" "$headref" "$checkdirty" "$green" "${packet:-$id}"
    printf 'LANE=%s DECISION=%s reason: %s\n' "$id" "$RC_DECISION" "$RC_REASON"
    case "$RC_DECISION" in
      escalate)       any_escalate=1 ;;
      adopt|discard)  any_action=1 ;;
    esac
  done <<EOF
$(cmd_lanes "$f" | tr '\t' '|')
EOF
  if [ "$any_escalate" = 1 ]; then
    printf 'AGGREGATE=escalate  (%d lane(s); resolve the escalated lane(s) before continuing)\n' "$nlanes"
  elif [ "$any_action" = 1 ]; then
    printf 'AGGREGATE=action  (%d lane(s) need adopt/discard/restart; apply per lane, then continue)\n' "$nlanes"
  else
    printf 'AGGREGATE=clean  (%d lane(s) all at their green checkpoint)\n' "$nlanes"
  fi
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
cmd="${1:-}"; [ "$#" -gt 0 ] && shift || true
case "$cmd" in
  get)       cmd_get       "$@" ;;
  cursor)    cmd_cursor    "$@" ;;
  set)       cmd_set       "$@" ;;
  touch)     cmd_touch     "$@" ;;
  write)     cmd_write     "$@" ;;
  summary)   cmd_summary   "$@" ;;
  claim-driver)  cmd_claim_driver  "$@" ;;
  heartbeat)     cmd_heartbeat     "$@" ;;
  driver-status) cmd_driver_status "$@" ;;
  outcome)       cmd_outcome       "$@" ;;
  trim-note)     cmd_trim_note     "$@" ;;
  record-outcome) cmd_record_outcome "$@" ;;
  add-finding)   cmd_add_finding   "$@" ;;
  drop-finding)  cmd_drop_finding  "$@" ;;
  findings)      cmd_findings      "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
  reconstruct) cmd_reconstruct "$@" ;;
  packets-by-status)  cmd_packets_by_status "$@" ;;
  lanes)              cmd_lanes             "$@" ;;
  reconcile-parallel) cmd_reconcile_parallel "$@" ;;
  request-pause)      cmd_request_pause     "$@" ;;
  clear-pause)        cmd_clear_pause       "$@" ;;
  pause-status)       cmd_pause_status      "$@" ;;
  -h|--help|help|"") sed -n '2,157p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '${cmd}' (try --help)" ;;
esac
