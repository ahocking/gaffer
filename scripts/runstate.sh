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
#   write    <file>                  atomically write full contents from stdin.
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
  local f="${1:-}" key="${2:-}"
  [ -n "$f" ] && [ -n "$key" ] || die "usage: get <file> <key>"
  need_file "$f"
  { grep -E "^${key}:" "$f" || true; } | head -1 | sed -E "s/^${key}:[[:space:]]*//"
}

# --- nested backlog.cursor ---------------------------------------------------
# Same contract as cmd_get: an absent cursor is empty-with-exit-0, not a failure.
cmd_cursor() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: cursor <file>"
  need_file "$f"
  { grep -E '^[[:space:]]+cursor:' "$f" || true; } | head -1 | sed -E 's/.*cursor:[[:space:]]*//'
}

# --- atomic write of the whole file from stdin -------------------------------
cmd_write() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: write <file>   (contents on stdin)"
  local dir tmp; dir="$(dirname "$f")"
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" || die "cannot create temp file in ${dir}"
  cat > "$tmp"
  mv -f "$tmp" "$f"          # rename is atomic on the same filesystem
}

# --- atomic set/insert of a flat top-level key -------------------------------
cmd_set() {
  local f="${1:-}" key="${2:-}" val="${3:-}"
  [ -n "$f" ] && [ -n "$key" ] || die "usage: set <file> <key> <value>"
  need_file "$f"
  local dir tmp; dir="$(dirname "$f")"
  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" || die "cannot create temp file in ${dir}"
  if grep -qE "^${key}:" "$f"; then
    # '|' delimiter: keys/values here (sha, status, ISO date, branch) never contain it.
    sed -E "s|^${key}:.*|${key}: ${val}|" "$f" > "$tmp"
  else
    cp "$f" "$tmp"; printf '%s: %s\n' "$key" "$val" >> "$tmp"
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
# Whole lines are kept so the YAML stays parseable; a single over-long line (the
# note-as-one-giant-line shape) is cut with an explicit marker rather than silently.
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
    awk -v s="$start" -v e="$end" -v m="$max" '
      NR<s || NR>e { next }
      NR==s { if (length($0) > m) { print substr($0, 1, m) " …[trimmed]"; cut=1 }
              else { print; n = length($0) + 1 } ; next }
      cut  { exit }
      { n += length($0) + 1; if (n > m) exit; print }' "$f"
    printf '  [note trimmed to %s bytes at %s; full history in %s]\n' "$max" "$stamp" "$(basename "$arch")"
    [ "$end" -lt "$total" ] && awk -v e="$end" 'NR > e' "$f"
    :
  } > "$tmp" || die "cannot write temp file"
  mv -f "$tmp" "$f"
  printf 'TRIMMED=yes\nBYTES_BEFORE=%s\nMAX=%s\nARCHIVE=%s\n' "$size" "$max" "$arch"
}

# --- add a finding: one-line index entry here, body in .agents/findings/ ------
# ADR 0022. Run-state is read by EVERY packet and sits in the standing context for a
# whole dispatch, so content useful to one packet is paid for by all of them. The
# summary stays hot so an agent can decide whether it needs the body; the body goes
# cold in .agents/findings/<id>.md.
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
  local f="${1:-}" id="${2:-}" summary="${3:-}"
  [ -n "$f" ] && [ -n "$id" ] && [ -n "$summary" ] \
    || die "usage: add-finding <run-state-file> <id> <one-line summary>"
  need_file "$f"
  case "$id" in
    *[!a-zA-Z0-9._-]*|'') die "finding id must be [a-zA-Z0-9._-] (it becomes a filename)" ;;
  esac
  # A newline in the summary would break the single-line YAML scalar and, worse, could
  # inject a sibling key. Collapse rather than reject: the caller is an agent mid-loop.
  summary="$(printf '%s' "$summary" | tr '\n\r' '  ')"

  if grep -qE "^[[:space:]]+- id: ${id}[[:space:]]*$" "$f" 2>/dev/null; then
    printf 'ADDED=no\nREASON=duplicate-id\nID=%s\n' "$id"; return 0
  fi

  local dir body rel
  dir="$(dirname "$f")"
  body="${dir}/findings/${id}.md"
  rel=".agents/findings/${id}.md"
  mkdir -p "${dir}/findings" 2>/dev/null || die "cannot create ${dir}/findings"
  if [ ! -f "$body" ]; then
    { printf '# %s\n\n' "$id"
      printf '> %s\n\n' "$summary"
      printf -- '- recorded: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '## What was found\n\n<the detail that did NOT belong in run-state>\n\n'
      printf '## Why it matters / what to do about it\n\n<so a later packet can act on it>\n\n'
      printf '## Scope\n\n<which packets or areas this applies to; "run-wide" if general>\n'
    } > "$body" || die "cannot write ${body}"
  fi

  local tmp
  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" || die "cannot create temp file in ${dir}"
  if grep -qE '^findings:' "$f"; then
    awk -v id="$id" -v s="$summary" -v rel="$rel" '
      { print }
      /^findings:[[:space:]]*$/ && !done { printf "  - id: %s\n    summary: %s\n    file: %s\n", id, s, rel; done=1 }
    ' "$f" > "$tmp"
  else
    # No findings key yet (a run-state from an older template): create the section at
    # the end rather than guessing an insertion point mid-file.
    { cat "$f"; printf 'findings:\n  - id: %s\n    summary: %s\n    file: %s\n' "$id" "$summary" "$rel"; } > "$tmp"
  fi
  mv -f "$tmp" "$f"
  printf 'ADDED=yes\nID=%s\nFILE=%s\n' "$id" "$body"
}

# --- list the finding index (ids + summaries only, never the bodies) ----------
# The read side of the same contract: an agent checks THIS, then opens only the
# bodies it needs. Printing summaries here — and nothing else — is what keeps the
# "index hot, body cold" split from silently collapsing back into "read everything".
cmd_findings() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: findings <run-state-file>"
  need_file "$f"
  awk '
    /^findings:[[:space:]]*$/ { inf=1; next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inf=0 }
    inf && /^[[:space:]]*- id:/    { if (id != "") print id "\t" sum "\t" file; sum=""; file="";
                                     sub(/^[[:space:]]*- id:[[:space:]]*/, ""); id=$0; next }
    inf && /^[[:space:]]*summary:/ { line=$0; sub(/^[[:space:]]*summary:[[:space:]]*/, "", line); sum=line; next }
    inf && /^[[:space:]]*file:/    { line=$0; sub(/^[[:space:]]*file:[[:space:]]*/, "", line); file=line; next }
    END { if (id != "") print id "\t" sum "\t" file }
  ' "$f" | grep -v '^<' || true
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
cmd_record_outcome() {
  local pkt="${1:-}" outcome="${2:-}" sess="${3:-${CLAUDE_SESSION_ID:-adhoc}}"
  [ -n "$pkt" ] && [ -n "$outcome" ] || die "usage: record-outcome <packet-id> <green|failed|rolled-back|blocked|abandoned> [session-id]"
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
  printf 'note: %s\n' \
    "TIP is a CANDIDATE last_green_commit — verify build+tests are green before trusting it; cursor/pending come from the committed task backlog; pending_questions cannot be recovered from git."
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
  findings)      cmd_findings      "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
  reconstruct) cmd_reconstruct "$@" ;;
  packets-by-status)  cmd_packets_by_status "$@" ;;
  lanes)              cmd_lanes             "$@" ;;
  reconcile-parallel) cmd_reconcile_parallel "$@" ;;
  request-pause)      cmd_request_pause     "$@" ;;
  clear-pause)        cmd_clear_pause       "$@" ;;
  pause-status)       cmd_pause_status      "$@" ;;
  -h|--help|help|"") sed -n '2,114p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '${cmd}' (try --help)" ;;
esac
