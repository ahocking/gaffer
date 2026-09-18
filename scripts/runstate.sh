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
#   lanes    <file>                  READ-ONLY projection kept after parallel
#                                    mode's retirement (retire-unused-loop-modes
#                                    T1): print one TSV row per lane still
#                                    recorded in a legacy `lanes:` block — id,
#                                    branch, worktree, packet, last_green_commit,
#                                    status. Nothing writes new lane rows any
#                                    more; `resume`'s stop path on a legacy
#                                    `mode: parallel` run-state reads this only
#                                    to name lane branches/worktrees for the
#                                    operator.
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
# with the driver's single-writer run-state. run-state records the OUTCOME
# (status: paused); the sentinel records the REQUEST. It lives in the MAIN
# checkout's `.agents/` and is resolvable from the working tree via
# `git rev-parse --git-common-dir` (see hooks/pause-check.sh). The busy loop
# POLLS it at safe checkpoints and wraps up to a green commit — never mid-edit.
# Whole-run only (retire-unused-loop-modes T1 removed the per-lane sentinel that
# parallel mode used): there is exactly one sentinel path, no per-task variant.
#   request-pause <pause-file> [reason]   touch the sentinel (atomic) with a
#                                    reason + UTC timestamp. Human/frontend/driver.
#   clear-pause   <pause-file>       remove the sentinel, at run start and on
#                                    resume, so a stale request cannot re-halt a
#                                    fresh run.
#   pause-status  <pause-file>       print PAUSE=1 (+ reason) when <pause-file>
#                                    exists, else PAUSE=0. Always exit 0 — it is
#                                    a query.
#
# Loop driver mode (thin-loop-driver T3/T7/T8/T9, ADR 0028). New record formats
# that must NOT go into the outcomes log above (`_rs_open_packets` reads any
# record carrying `kind` there as a start):
#   driver-mode <enter|exit|status> [session-id]
#                                    session defaults to $CLAUDE_CODE_SESSION_ID.
#                                    `enter --model <m> --effort <e|unknown>
#                                    --threshold <n|unknown>` writes the mark
#                                    .agents/driver-mode/<session> that
#                                    hooks/guard.sh (T5) refuses a main-thread
#                                    write against, and appends an enter record
#                                    to .agents/metrics/driver-mode/<session>.jsonl.
#                                    `exit` removes the mark (idempotent) and
#                                    appends an exit record. `status` prints
#                                    DRIVER_MODE=on|off.
#   begin-run <run-state>            mints a sortable `run_id` into run-state
#                                    ONLY when absent (a resume keeps the
#                                    existing one — a run spans sessions),
#                                    creates .agents/loop/<run_id>/, and removes
#                                    every OTHER run directory except the
#                                    newest previous one. Prints RUN_ID=,
#                                    RUN_DIR=, and one REMOVED= per directory
#                                    deleted.
#   handoff <run-state> <packet-id> --tier <tier> --agent <agent>
#                                    writes stdin atomically to
#                                    .agents/loop/<run_id>/<packet-id>/handoff.md,
#                                    headed by the packet id, a title, the
#                                    tier and the agent, plus three ABSOLUTE-
#                                    path header lines (`run-state:`,
#                                    `result:`, `review:`) so a dispatched
#                                    agent's own `write-result`/`route` calls
#                                    resolve correctly regardless of its cwd
#                                    (review fix #8 -- a relative path, or a
#                                    /tmp-vs-/private/tmp alias, would
#                                    silently resolve elsewhere). `result:` is
#                                    `<pktdir>/<agent>.md`; `review:` is
#                                    always `<pktdir>/review.md`, the same
#                                    path across every agent dispatched for
#                                    the packet. The title is the
#                                    piped body's `TEXT=` line when one
#                                    exists (gspec-backlog.sh handoff's own
#                                    shape), else its first line that is not
#                                    a bare `KEY=value` line, else the packet
#                                    id itself. Refuses (HANDOFF=refused) a
#                                    packet whose latest routing record in
#                                    this run's routing.jsonl is
#                                    `hand-off-feature` (T9).
#   write-result <run-state> <path> --status "<line>"
#                                    atomically writes the (newline-collapsed)
#                                    status line followed by stdin to <path>.
#                                    Refuses any <path> resolving outside the
#                                    CURRENT run directory, checked lexically
#                                    (no filesystem access before the
#                                    containment decision, so a refused write
#                                    never touches disk outside the run dir).
#   route <run-state> <packet-id> <token> [--status "<line>"]
#                                    appends a routing record to
#                                    .agents/loop/<run_id>/routing.jsonl (never
#                                    the outcomes log) and prints one
#                                    ACTION=land|attempt|decider|discard-advance|stop
#                                    with ATTEMPTS=/LIMIT=. `fix` and `retry`
#                                    share ONE attempt pool, counted since the
#                                    packet's latest kind=start record (a
#                                    kind=continue record does NOT reset it);
#                                    the limit is `packet_attempts` in
#                                    .agents/project-overrides.yaml (1 when
#                                    missing/invalid/0). A `retry` past the
#                                    limit refuses as `stop` with a blocking
#                                    question, rather than dispatching the
#                                    decider again — `retry` IS the decider's
#                                    own return value, so looping on it could
#                                    never terminate.
#   compact-threshold                prints THRESHOLD=<n|unknown>,
#                                    SOURCE=repo|operator|unknown
#                                    and APPLIED=no ALWAYS (thin-loop-driver
#                                    T4, ADR 0028 result 3). Pure reader, no
#                                    side effect: it never writes a settings
#                                    file. T1 verified exactly ONE carrier —
#                                    `autoCompactWindow` (a number, tokens) in
#                                    a Claude Code settings JSON file, same
#                                    value as the
#                                    `CLAUDE_CODE_AUTO_COMPACT_WINDOW` env var
#                                    — and explicitly did NOT probe precedence
#                                    between them, the user
#                                    (~/.claude/settings.json) and committed-
#                                    project (.claude/settings.json) scopes
#                                    specifically, or whether a plugin default
#                                    can coexist with a repo/operator value
#                                    without overriding it. "operator" here
#                                    means, in order: the env var, then
#                                    .claude/settings.local.json (uncommitted,
#                                    personal), then ~/.claude/settings.json
#                                    (user, every repo) — a DOCUMENTED,
#                                    UNVERIFIED precedence (operator over
#                                    repo). PROBE THIS FOR REAL before
#                                    anything relies on it for more than
#                                    display. When neither repo nor operator
#                                    has one set, this reports
#                                    THRESHOLD=unknown, SOURCE=unknown: ADR
#                                    0028 result 3 records `1m tokens` as the
#                                    default on Opus 5 (1M) specifically, a
#                                    model-conditional reading rather than a
#                                    harness-wide one, so this reader states
#                                    no number rather than inventing one.
#                                    APPLIED therefore never varies here; the
#                                    field survives so a later carrier (once
#                                    the ADR's plugin-default probe lands) can
#                                    report APPLIED=yes without a format
#                                    change. NO SESSION BOUNDARY TO CONFIRM:
#                                    because nothing is ever written, there is
#                                    no cross-session effect to check for —
#                                    this command's output is a snapshot of
#                                    what the harness will read at its OWN
#                                    next session start (T1's probe launched
#                                    three FRESH sessions to see each scope;
#                                    it never re-read a value mid-session),
#                                    not a report on anything this command
#                                    changed. Reads are parser-free (a
#                                    shallow regex scan, matching this file's
#                                    no-parser-dependency rule below) and can
#                                    therefore misread a malformed settings
#                                    file as "not set" rather than erroring —
#                                    acceptable for a display-only reader.
#   periodic-pause [session-id]      thin-loop-driver T10 (ADR 0028 result 2):
#                                    prints ENDED=<n>, EVERY=<n|off>,
#                                    DUE=yes|no. Pure reader, no side effect —
#                                    the CALLER (run-loop) is what actually
#                                    invokes request-pause when DUE=yes. EVERY
#                                    comes from `pause_every_packets` in
#                                    .agents/project-overrides.yaml: off when
#                                    the key is missing, invalid, or 0 — off
#                                    by default and at 0 on purpose, since a
#                                    periodic pause halts an unattended run
#                                    until a human resumes it, and neither an
#                                    absent key nor an explicit 0 should do
#                                    that silently. ENDED counts TERMINAL
#                                    outcome records (any record carrying an
#                                    `outcome` field, in
#                                    .agents/metrics/outcomes/*.jsonl across
#                                    every session — the same log
#                                    record-outcome/sweep-open already write)
#                                    whose `ts` is at or after the given
#                                    session's LATEST driver-mode `enter`
#                                    record (.agents/metrics/driver-mode/
#                                    <session>.jsonl) — so a restart (a fresh
#                                    `enter`) resets the count to zero, matching
#                                    "since the loop last started or resumed"
#                                    in the PRD. Session defaults to
#                                    $CLAUDE_CODE_SESSION_ID (adhoc if unset),
#                                    the same fallback record-outcome/
#                                    record-start use. Comparison is by
#                                    PARSED time (_rs_ts_key), never a raw
#                                    string compare — the same sub-second-vs-
#                                    whole-second trap sweep-open guards
#                                    against. A SWEPT interruption/
#                                    abandonment (sweep-open) carries its
#                                    ORIGINAL start's ts, not the sweep's own
#                                    time — so a record swept AFTER entering
#                                    driver mode but started BEFORE it sorts
#                                    below the enter and is excluded, with no
#                                    special-case code beyond that timestamp
#                                    comparison. No enter record for the
#                                    session, or not a git repo, reads as
#                                    ENDED=0/EVERY=off/DUE=no.
#   bundle-cap                       packet-bundling T2: prints CAP=<n> the
#                                    way periodic-pause prints EVERY=. Pure
#                                    reader, no side effect. Comes from
#                                    `bundle_max_tasks` in
#                                    .agents/project-overrides.yaml: 1 when
#                                    the key is missing, invalid, zero or
#                                    negative -- bundling is off until a
#                                    repository raises it. Same token-scan
#                                    shape as packet_attempts (see
#                                    _rs_bundle_max_tasks/
#                                    _rs_packet_attempts_limit): skips
#                                    non-digit tokens after the key (so a
#                                    trailing comment cannot defeat it) and
#                                    strips one matching pair of quotes per
#                                    token before testing digit-ness, so
#                                    `bundle_max_tasks: '4'` is honoured
#                                    rather than read as missing. Not a git
#                                    repo reads as CAP=1.
#   run-digest <run-state> [--since <ts>]
#                                    thin-loop-driver T11 (ADR 0028 result 4):
#                                    assembles a report from FILES ALONE --
#                                    the run's handoff files, routing.jsonl
#                                    (including the routed status recorded for
#                                    a hand-off, written by that routing
#                                    call's own --status argument -- an
#                                    omitted one leaves the hand-off line's
#                                    status empty), the outcomes log and the
#                                    driver-mode logs -- never from the
#                                    driver's memory of the run, and never a
#                                    result file, which it does not open.
#                                    Prints ONLY these, one line per item,
#                                    tab-separated, and nothing else:
#                                      packet\t<id>\t<title>\t<outcome>
#                                        one per packet with a handoff.md in
#                                        THIS run (the run's own definition
#                                        of "begun"). <title> is parsed from
#                                        the handoff's own header line.
#                                        <outcome> is the terminal outcome
#                                        (green/failed/rolled-back/blocked/
#                                        abandoned/interrupted) recorded at
#                                        or after the packet's LATEST start
#                                        or continuation record (same
#                                        boundary rule as
#                                        _rs_open_packets/sweep-open --
#                                        both kinds count); `paused` when
#                                        run-state's status is `paused` and
#                                        its cursor names this packet (a
#                                        paused cursor is deliberately never
#                                        swept, so it carries no terminal
#                                        record of its own); else `open`.
#                                      decision\t<id>\t<token>
#                                        one per routing.jsonl record whose
#                                        token is one the escalation decider
#                                        (today's chief-engineer stand-in,
#                                        thin-loop-driver T15) returns --
#                                        retry/reorder/append-task/hand-off-
#                                        feature/ask-operator -- never a bare
#                                        reviewer verdict (pass/fix/escalate
#                                        are not decider decisions; escalate
#                                        only ROUTES to the decider) -- with
#                                        a parsed ts at or after --since (all
#                                        of them when --since is omitted).
#                                      handoff-feature\t<id>\t<status>
#                                        one per hand-off-feature routing
#                                        record for the WHOLE run, regardless
#                                        of --since -- a stop report must
#                                        list every open question the run
#                                        recorded, not only recent ones --
#                                        carrying its own routed --status
#                                        line verbatim (JSON-escaping
#                                        reversed).
#                                      enter\t<model>\t<effort>\t<threshold>
#                                        the model/effort/threshold stated at
#                                        the MOST RECENT driver-mode `enter`
#                                        record across EVERY session's log --
#                                        a run can span sessions, and each
#                                        one entering driver mode wrote its
#                                        own record, so this is not the one
#                                        session periodic-pause is told
#                                        about. Omitted entirely when no
#                                        session ever entered driver mode in
#                                        this checkout.
#                                    A missing run directory, routing.jsonl or
#                                    driver-mode log reads as "nothing to
#                                    report" for that section, never a die --
#                                    same fail-soft contract as periodic-
#                                    pause/compact-threshold. Dies only when
#                                    run-state has no run_id (begin-run has
#                                    not been called) or this is not a git
#                                    repo, same as handoff/write-result/route.
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

# --- shared: sub-second UTC timestamp, portably (loop-measurement T1) --------
# GNU date supports %N (nanoseconds); modern BSD/macOS date supports plain %N
# too but NOT GNU's field-width form (`%3N` comes back as the literal text
# "3N" on macOS — probed by hand, not assumed), so this truncates to
# milliseconds itself with a plain bash substring instead of relying on that
# GNU-only syntax. A date with no %N support at all (old BSD) emits the
# literal string "%N", non-digits, which the probe below catches. Probed by
# EXECUTION, not `command -v` (this repo's standing rule, see guard.sh — a
# `date` binary existing says nothing
# about which variant it is). Cached per-process (`_RS_HAS_NANO`) so the probe
# only runs once no matter how many records a single invocation writes.
# Falls back to a literal ".000" suffix on a platform that cannot produce
# sub-second resolution, so the field is always present and always the same
# shape — callers must not assume the fraction is meaningful on every host.
_RS_HAS_NANO=""
_rs_now_ts() {
  if [ -z "$_RS_HAS_NANO" ]; then
    case "$(date -u +%N 2>/dev/null || true)" in
      ''|*[!0-9]*) _RS_HAS_NANO=no ;;
      *)           _RS_HAS_NANO=yes ;;
    esac
  fi
  if [ "$_RS_HAS_NANO" = yes ]; then
    # One date call (no race between a separate whole-second call and a
    # separate %N call straddling a second boundary), then slice: %N is
    # always 9 digits on every date that supports it, so this is a plain
    # substring, never a numeric truncation.
    local raw frac
    raw="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    frac="${raw#*.}"
    frac="${frac%%[!0-9]*}"
    printf '%s.%sZ' "${raw%%.*}" "${frac:0:3}"
  else
    printf '%s.000Z' "$(date -u +%Y-%m-%dT%H:%M:%S)"
  fi
}

# --- shared: packet-id charset guard (ADR 0019 v3.4, reused by T1) -----------
# Same rule as a finding id: this value is interpolated into a JSON line, and a
# `"` or `\` in it emits invalid JSON that makes the collector's `jq -s` drop
# EVERY attestation in the file at once, silently, with no diagnostic.
_rs_check_pkt_id() {
  case "$1" in
    *[!a-zA-Z0-9._-]*) die "packet id must be [a-zA-Z0-9._-]" ;;
  esac
  # `.`/`..`/anything containing `..` are otherwise legal under the charset
  # above (both `.` and `-` are allowed, for real ids like
  # "self-host-hardening-gaps") but become a path-traversal segment the
  # moment a packet id is used to build a directory name -- `handoff … ..`
  # wrote straight into .agents/loop/<run_id>/handoff.md, one level up from
  # where it belongs, before this check existed.
  case "$1" in
    .|..|*..*) die "packet id must not be '.', '..', or contain '..'" ;;
  esac
}

# --- shared: resolve the MAIN checkout root from any lane worktree -----------
# --git-common-dir points at the main repo even from a lane worktree, so every
# lane resolves to the same one log directory. Prints the root and returns 0,
# or returns 1 with nothing printed (not a git repo at all). Factored out of
# _rs_append_outcomes_line (loop-measurement T3) so sweep-open can enumerate
# every session's outcomes log with the exact same resolution its writer uses,
# rather than re-deriving it and risking the two falling out of step.
_rs_main_checkout_root() {
  local gcd rel
  gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$gcd" ]; then
    # Older git without --path-format=absolute: fall back to the plain (possibly
    # relative) form and resolve it ourselves. Only `cd` into it when git actually
    # produced a path — `cd "."` on a FAILED git call would silently resolve to
    # the current directory and misreport a non-git directory as a valid repo.
    rel="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    [ -n "$rel" ] && gcd="$(cd "$rel" 2>/dev/null && pwd || true)"
  fi
  [ -n "$gcd" ] || return 1
  printf '%s\n' "$(dirname "$gcd")"
}

# --- shared: append one line to the ATTESTED-outcomes log --------------------
# Append-only, one line per packet boundary, to .agents/metrics/outcomes/<session>.jsonl.
# The collector reconstructs packets from green-commit trailers, so it structurally
# cannot see a packet that failed or was rolled back — those never produce a commit.
# Only the loop knows, and only at the boundary, so it has to say so here.
#
# NOT written into run-state: run-state has a single writer (the driver) and this must
# be callable from a lane without contending for it — the same reason packet boundaries
# were left on commit trailers instead of migrating run-state's schema (ADR 0019).
# Append-only + last-wins means a retried packet correctly ends up at its final state.
#
# Resolves the MAIN checkout the same way the hooks do (_rs_main_checkout_root), so
# every lane records into one log. On any failure (not a git repo, cannot create the
# dir, cannot append) this prints RECORDED=no + REASON=... and returns 1 — non-fatal
# by design, callers must not die.
#
# CALLERS MUST INVOKE THIS IN AN `||` OR `if` CONTEXT, NEVER BARE. This file runs
# under `set -euo pipefail`, which does not apply inside a condition — `foo || bar`
# and `if foo; then` both suspend it for the call. A bare call would instead let
# `return 1` exit the whole script, turning the non-fatal RECORDED=no contract into
# a hard die. Both current callers already do this correctly (`|| return 0`); keep
# it that way in any new caller.
_rs_append_outcomes_line() {
  local sess="$1" line="$2"
  local main_root dir
  main_root="$(_rs_main_checkout_root)" || { printf 'RECORDED=no\nREASON=not-a-git-repo\n'; return 1; }
  dir="${main_root}/.agents/metrics/outcomes"
  mkdir -p "$dir" 2>/dev/null || { printf 'RECORDED=no\nREASON=cannot-create-dir\n'; return 1; }
  # Same atomicity argument as the metrics hook: a single short line, O_APPEND, well
  # under PIPE_BUF, so concurrent lanes sharing a session id cannot tear each other.
  printf '%s\n' "$line" >> "${dir}/${sess}.jsonl" 2>/dev/null \
    || { printf 'RECORDED=no\nREASON=cannot-append\n'; return 1; }
  return 0
}

# --- record an ATTESTED packet outcome (ADR 0019 v3.4) -----------------------
# SESSION ID: `CLAUDE_CODE_SESSION_ID`, which is the variable Claude Code actually
# exports to a Bash tool call. The first cut read `CLAUDE_SESSION_ID`, which does not
# exist — so every attestation from every run fell through to the `adhoc` default and
# landed in ONE file, and the collector then joined a packet id to whichever run last
# used that name. Verified rather than assumed: this env var is byte-identical to the
# `.session_id` in the PostToolUse payload that names `.agents/metrics/events/<id>.jsonl`,
# so `outcomes/<id>.jsonl` and `events/<id>.jsonl` share a key and the collector can
# scope outcomes with the same `--session` selection it already applies to events.
#
# `session` is carried IN the record (loop-measurement T1), not just the filename,
# for the same reason record-start carries it: `metrics.sh` concatenates every
# selected session's log into one stream BEFORE joining, which destroys the
# filename as a source of the session id. A terminal record written before this
# change has no `session` field — readers must treat it as absent, not as an
# error, and must not assume every line in an old log carries it.
cmd_record_outcome() {
  local pkt="${1:-}" outcome="${2:-}" sess="${3:-${CLAUDE_CODE_SESSION_ID:-adhoc}}"
  [ -n "$pkt" ] && [ -n "$outcome" ] || die "usage: record-outcome <packet-id> <green|failed|rolled-back|blocked|abandoned> [session-id]"
  _rs_check_pkt_id "$pkt"
  case "$outcome" in
    green|failed|rolled-back|blocked|abandoned) ;;
    *) die "outcome must be one of: green failed rolled-back blocked abandoned" ;;
  esac
  local line
  line="$(printf '{"ts":"%s","packet":"%s","session":"%s","outcome":"%s"}' "$(_rs_now_ts)" "$pkt" "$sess" "$outcome")"
  _rs_append_outcomes_line "$sess" "$line" || return 0
  printf 'RECORDED=yes\nPACKET=%s\nOUTCOME=%s\n' "$pkt" "$outcome"
}

# --- record a packet START or CONTINUATION (loop-measurement T1) -------------
# Same append-only log as record-outcome, same main-checkout resolution, same id
# charset rule, same sub-second stamp. This is the OTHER end of the boundary
# record-outcome writes: T3 (sweep-open) reads a packet's latest start/continue
# with no terminal outcome at or after it as an interrupted packet, so the shape
# here is load-bearing for that later feature and must not be reshaped there.
#
# Record shape (defined ONCE, here — T3/T4 consume it verbatim):
#   {"ts":"<sub-second UTC>","packet":"<id>","session":"<session-id>","kind":"start"|"continue"}
# `kind` is deliberately its own field (not folded into `outcome`, which stays
# exactly the five terminal values) so a reader can tell a boundary record from
# a terminal one by field shape alone: an outcome record has "outcome", a
# start/continuation record has "kind". `session` is carried IN the record (not
# just the filename) because T3's sweep can write a closing record into a LATER
# session's log file while still needing to name the start it closes.
#
# A terminal record (record-outcome) now carries the same `session` field, so
# both kinds are self-describing once concatenated across sessions — except a
# terminal record written before that change, which has no `session` (readers
# must treat it as absent, not malformed).
#
# TWO PROPERTIES THE TS FIELD HAS THAT T3/T4 MUST NOT ASSUME AWAY:
# (a) a sub-second stamp and a whole-second stamp landing in the SAME second do
#     NOT sort correctly as strings — "...:08.311Z" sorts before "...:08Z" because
#     "." (0x2E) sorts before "Z" (0x5A) — so a reader ordering boundary/terminal
#     records must compare PARSED times, never raw string comparison. FIXED in
#     scripts/metrics.sh: the outcomes-log join (T4) and the per-packet window
#     join (I1) both compare via the shared `$JQ_TS_MS`/`ts_ms` fragment now —
#     do not reintroduce a raw `.ts >=`/`.ts <=`/`.ts >`/`.ts <` comparison
#     against a value that can be sub-second.
# (b) neither jq's `fromdateiso8601` nor this file's own sibling `metrics.sh`
#     `epoch()` helper accepts the fractional form this function writes
#     (verified: `epoch()` returns 0 on macOS for a "...NNN Z" timestamp, while
#     working fine on a GNU runner) — strip the fraction before handing a
#     timestamp to either.
#
# SESSION ID default: same variable, same rationale, as record-outcome above
# (`CLAUDE_CODE_SESSION_ID`, not `CLAUDE_SESSION_ID` — see that comment block).
cmd_record_start() {
  # `--continue` may appear anywhere among the args, so scan rather than assume
  # a fixed position: `record-start <pkt> --continue [sess]` and
  # `record-start <pkt> [sess] --continue` must both work.
  local cont=no args=() a
  for a in "$@"; do
    if [ "$a" = "--continue" ]; then cont=yes; else args+=("$a"); fi
  done
  local pkt="${args[0]:-}" sess="${args[1]:-${CLAUDE_CODE_SESSION_ID:-adhoc}}"
  [ -n "$pkt" ] || die "usage: record-start <packet-id> [--continue] [session-id]"
  _rs_check_pkt_id "$pkt"
  local kind=start
  [ "$cont" = yes ] && kind=continue
  local line
  line="$(printf '{"ts":"%s","packet":"%s","session":"%s","kind":"%s"}' \
    "$(_rs_now_ts)" "$pkt" "$sess" "$kind")"
  _rs_append_outcomes_line "$sess" "$line" || return 0
  printf 'RECORDED=yes\nPACKET=%s\nKIND=%s\n' "$pkt" "$kind"
}

# --- shared: portable ISO-8601(Z) [+ optional .fff] -> whole-second epoch ----
# Strips an optional fractional-seconds component before handing the timestamp
# to `date`: GNU `date -u -d` would accept the fraction fine, but the BSD/macOS
# `-j -f "%Y-%m-%dT%H:%M:%SZ"` arm REJECTS it outright (same finding recorded
# against metrics.sh's own `epoch()`, which returns 0 for this file's own
# sub-second stamp on macOS) — so both arms are given the identical bare form.
# A deliberately SEPARATE copy from metrics.sh's `epoch()`, not a shared call:
# metrics.sh is outside this packet's allowed_files, and its helper is the one
# already known to mishandle this exact shape. Returns 0 on anything
# unparseable (same fail-soft contract as that sibling).
_rs_epoch_secs() {
  local t="${1:-}" bare
  [ -n "$t" ] || { echo 0; return; }
  bare="$(printf '%s' "$t" | sed -E 's/\.[0-9]+Z$/Z/')"
  date -u -d "$bare" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$bare" +%s 2>/dev/null \
    || echo 0
}

# --- shared: the millisecond fraction of a T1-shaped sub-second stamp --------
# Pure string slicing, no date parsing involved — the fraction is always
# exactly 3 digits when present (see _rs_now_ts's own comment) and simply
# absent on a pre-T1 whole-second record, which reads as "000".
_rs_frac_ms() {
  local t="${1:-}" frac
  case "$t" in
    *.*Z)
      frac="${t#*.}"; frac="${frac%Z}"
      frac="${frac}000"
      printf '%s' "${frac:0:3}"
      ;;
    *) printf '000' ;;
  esac
}

# --- shared: a COMPARABLE sort key for a T1-shaped timestamp -----------------
# epoch seconds * 1000 + the millisecond fraction, as a plain integer key.
# sweep-open compares THIS, never the raw ts string: "...:08.311Z" sorts BELOW
# "...:08Z" as a string ("." is 0x2E, "Z" is 0x5A), inverting the ordering
# between a sub-second record and a whole-second one landing in the same
# second (see the trap documented on cmd_record_start above). `10#` on the
# fraction guards against octal interpretation of a leading-zero fraction
# like "007".
_rs_ts_key() {
  local secs frac
  secs="$(_rs_epoch_secs "$1")"
  frac="$(_rs_frac_ms "$1")"
  printf '%d' $(( secs * 1000 + 10#$frac ))
}

# --- shared: is $1 one of the comma-separated ids in $2? ---------------------
_rs_in_csv() {
  case ",$2," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- internal: every OPEN packet across every outcomes log -------------------
# "Open" = the packet's LATEST start/continuation (by parsed time, across every
# session's log — a packet can start in one session and continue in another)
# has no terminal record at or after it. Prints one TSV row per open packet:
#   <packet>\t<session of that latest start/continuation>\t<its raw ts>
# so the caller (cmd_sweep_open) can write a closing record that names them,
# per the format T3 defines (see cmd_sweep_open below). Two-stage on purpose:
# an awk pass extracts fields with plain `index`/`substr` (no regex escaping,
# portable to a POSIX awk — this repo has no gawk-only features anywhere), a
# bash pass attaches the parsed-time sort key `_rs_ts_key` needs `date` for
# (which awk cannot do portably), and a final awk pass does the two aggregation
# passes (max boundary per packet, then "any terminal at/after it?") as plain
# integer/string ops.
_rs_open_packets() {
  local dir="$1"
  local parsed
  parsed="$(awk '
    function field(line, name,    pat, pos, rest, q) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      rest = substr(line, pos + length(pat))
      q = index(rest, "\"")
      if (q == 0) return ""
      return substr(rest, 1, q - 1)
    }
    {
      ts = field($0, "ts"); pkt = field($0, "packet")
      if (ts == "" || pkt == "") next
      kind = field($0, "kind")
      if (kind != "") { print "B\t" pkt "\t" field($0, "session") "\t" ts; next }
      outc = field($0, "outcome")
      # "-" is a PLACEHOLDER, not real data: a terminal record session field is
      # never read downstream (only a boundary session names the start that a
      # closing record must carry). But a genuinely EMPTY field here would sit
      # between two tabs, and bash read collapses a tab-adjacent empty field
      # even with IFS set to a lone tab -- tab is always "IFS whitespace" for
      # splitting purposes, regardless of what IFS is set to (a real bash
      # gotcha, hit and fixed while building this). That silently shifted the
      # ts value into sess on the next parse stage and read every terminal
      # record as dated at epoch 0, so an already-closed packet never closed.
      if (outc != "") { print "T\t" pkt "\t-\t" ts }
    }
  ' "$dir"/*.jsonl 2>/dev/null || true)"
  [ -n "$parsed" ] || return 0

  local keyed_lines=() type pkt sess ts key
  while IFS="$(printf '\t')" read -r type pkt sess ts; do
    [ -n "$type" ] || continue
    key="$(_rs_ts_key "$ts")"
    keyed_lines+=("$(printf '%s\t%s\t%s\t%s\t%s' "$key" "$type" "$pkt" "$sess" "$ts")")
  done <<EOF
$parsed
EOF
  [ "${#keyed_lines[@]}" -gt 0 ] || return 0

  printf '%s\n' "${keyed_lines[@]}" | awk -F'\t' '
    { n++; key[n]=$1+0; type[n]=$2; pkt[n]=$3; sess[n]=$4; ts[n]=$5 }
    END {
      for (i = 1; i <= n; i++) {
        if (type[i] != "B") continue
        p = pkt[i]
        if (!(p in bkey) || key[i] > bkey[p]) { bkey[p] = key[i]; bsess[p] = sess[i]; bts[p] = ts[i] }
      }
      for (i = 1; i <= n; i++) {
        if (type[i] != "T") continue
        p = pkt[i]
        if ((p in bkey) && key[i] >= bkey[p]) closed[p] = 1
      }
      for (i = 1; i <= n; i++) {
        if (type[i] != "B") continue
        p = pkt[i]
        if (p in emitted) continue
        emitted[p] = 1
        if (!(p in closed)) print p "\t" bsess[p] "\t" bts[p]
      }
    }'
}

# --- close out packets started but never ended (loop-measurement T3) ---------
# sweep-open [--list] [--paused-cursor <id>] [--gone <id,...>]
#
# For each OPEN packet (see _rs_open_packets) except the paused cursor, appends
# a TERMINAL record — outcome=interrupted, or =abandoned for an id in --gone —
# using the SAME terminal shape record-outcome writes (T1/T3 fix this format;
# nothing downstream reshapes it): {"ts":...,"packet":...,"session":...,"outcome":...}.
#
# The record is written into the SWEEPING session's own log file (same
# resolution/session default as every other writer here), but its `ts` and
# `session` FIELDS are copied verbatim from the start/continuation it closes —
# that is what "names the session and time of the start it closes" means: a
# reader (T4) attributes the interruption to the run those fields name, not to
# the run whose sweep physically wrote it (a later, unrelated session). Copying
# them verbatim also makes a second sweep-open a true no-op: the closing
# record's own key exactly equals the boundary's key it closes, so the very
# next scan reads that packet as already closed.
#
# --list prints one OPEN=<id> line per open packet and appends NOTHING, so a
# caller can resolve --gone (via the gspec adapter) before writing anything.
cmd_sweep_open() {
  local do_list=no cursor="" gone_csv=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --list)
        do_list=yes; shift ;;
      --paused-cursor)
        [ $# -ge 2 ] || die "usage: sweep-open [--list] [--paused-cursor <id>] [--gone <id,...>]"
        cursor="$2"; shift 2 ;;
      --gone)
        [ $# -ge 2 ] || die "usage: sweep-open [--list] [--paused-cursor <id>] [--gone <id,...>]"
        gone_csv="$2"; shift 2 ;;
      *)
        die "usage: sweep-open [--list] [--paused-cursor <id>] [--gone <id,...>]" ;;
    esac
  done

  local main_root
  main_root="$(_rs_main_checkout_root)" || die "sweep-open: not a git repo"
  local dir="${main_root}/.agents/metrics/outcomes"
  [ -d "$dir" ] || return 0

  local open_rows
  open_rows="$(_rs_open_packets "$dir")"
  [ -n "$open_rows" ] || return 0

  local write_sess="${CLAUDE_CODE_SESSION_ID:-adhoc}"
  local pkt sess ts
  while IFS="$(printf '\t')" read -r pkt sess ts; do
    [ -n "$pkt" ] || continue
    [ "$pkt" = "$cursor" ] && continue

    if [ "$do_list" = yes ]; then
      printf 'OPEN=%s\n' "$pkt"
      continue
    fi

    local outcome=interrupted
    if [ -n "$gone_csv" ] && _rs_in_csv "$pkt" "$gone_csv"; then
      outcome=abandoned
    fi

    local line
    line="$(printf '{"ts":"%s","packet":"%s","session":"%s","outcome":"%s"}' "$ts" "$pkt" "$sess" "$outcome")"
    _rs_append_outcomes_line "$write_sess" "$line" || true
    printf 'SWEPT=%s\nOUTCOME=%s\n' "$pkt" "$outcome"
  done <<EOF
$open_rows
EOF
}

# =============================================================================
# Loop driver mode (thin-loop-driver T3/T7/T8/T9, ADR 0028)
# =============================================================================

# Same filename-safety rule as _rs_check_pkt_id, applied to a session id: it
# becomes a path segment under .agents/driver-mode/ and .agents/metrics/
# driver-mode/, so a `/` or a `..` segment must never reach a filesystem call.
# The charset alone (no `/`) already blocks a traversal via separators; `..`
# is checked separately because both `.` and `-` are otherwise legal here.
_rs_check_session_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) die "session id must be [A-Za-z0-9._-]" ;;
  esac
  case "$1" in
    *..*) die "session id must not contain '..'" ;;
  esac
}

# run_id becomes a path segment under .agents/loop/, so a value READ BACK
# from run-state (a hand-crafted or corrupted `run_id: ../../../esc`) must be
# rejected before it reaches any of the four commands that build a path from
# it -- not only where it is minted. The charset excludes `.` outright, so a
# `..` segment is already unreachable; nothing further to check.
_rs_check_run_id() {
  case "$1" in
    ''|*[!A-Za-z0-9-]*) die "run_id must be [A-Za-z0-9-]" ;;
  esac
}

# Escape a value for embedding as a JSON string (no surrounding quotes). Used
# for fields this file did not previously write (model/effort/threshold/status)
# that are NOT charset-restricted the way an id is, so they need real escaping
# rather than a refusal. Beyond backslash/quote/CR/LF, a tab or any other
# control byte in --status/model/effort/threshold would otherwise reach
# routing.jsonl or the driver-mode log unescaped and produce invalid JSON,
# which makes the collector's `jq -s` drop every record in the file at once.
_rs_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# --- append one line to the driver-mode log (mirrors _rs_append_outcomes_line,
# --- deliberately a SEPARATE file: a new record kind must never reach the
# --- outcomes log, since _rs_open_packets there treats any record carrying
# --- `kind` as a packet start) --------------------------------------------
_rs_append_driver_mode_line() {
  local sess="$1" line="$2"
  local main_root dir
  main_root="$(_rs_main_checkout_root)" || { printf 'RECORDED=no\nREASON=not-a-git-repo\n'; return 1; }
  dir="${main_root}/.agents/metrics/driver-mode"
  mkdir -p "$dir" 2>/dev/null || { printf 'RECORDED=no\nREASON=cannot-create-dir\n'; return 1; }
  printf '%s\n' "$line" >> "${dir}/${sess}.jsonl" 2>/dev/null \
    || { printf 'RECORDED=no\nREASON=cannot-append\n'; return 1; }
  return 0
}

# --- driver-mode: enter/exit/status -----------------------------------------
cmd_driver_mode() {
  local sub="${1:-}"
  [ -n "$sub" ] || die "usage: driver-mode <enter|exit|status> [session-id]"
  shift
  case "$sub" in
    enter)  cmd_driver_mode_enter  "$@" ;;
    exit)   cmd_driver_mode_exit   "$@" ;;
    status) cmd_driver_mode_status "$@" ;;
    *) die "usage: driver-mode <enter|exit|status> [session-id]" ;;
  esac
}

cmd_driver_mode_enter() {
  local model="unknown" effort="unknown" threshold="unknown" args=() sess
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)       model="${2:-}"; shift 2 ;;
      --model=*)     model="${1#--model=}"; shift ;;
      --effort)      effort="${2:-}"; shift 2 ;;
      --effort=*)    effort="${1#--effort=}"; shift ;;
      --threshold)   threshold="${2:-}"; shift 2 ;;
      --threshold=*) threshold="${1#--threshold=}"; shift ;;
      --*) die "usage: driver-mode enter --model <m> --effort <e|unknown> --threshold <n|unknown> [session-id] (unknown option: $1)" ;;
      *) args+=("$1"); shift ;;
    esac
  done
  sess="${args[0]:-${CLAUDE_CODE_SESSION_ID:-}}"
  # An "adhoc" fallback here would enforce nothing -- every main-thread write
  # would read as belonging to a session named "adhoc" that nobody actually
  # entered. exit/status keep the adhoc fallback (a query against a mark that
  # was never entered is harmless), but entering driver mode requires a real
  # session id.
  [ -n "$sess" ] || die "driver-mode enter: no session id given and CLAUDE_CODE_SESSION_ID is unset -- refusing to mark an 'adhoc' session as the driver"
  _rs_check_session_id "$sess"

  local main_root
  main_root="$(_rs_main_checkout_root)" || die "driver-mode: not a git repo"
  local dir="${main_root}/.agents/driver-mode"
  mkdir -p "$dir" 2>/dev/null || die "cannot create ${dir}"
  # The mark's own content is informational only — hooks/guard.sh (T5) and
  # `driver-mode status` below both check EXISTENCE, never content.
  printf 'entered_at: %s\nmodel: %s\neffort: %s\nthreshold: %s\n' \
    "$(_rs_now_ts)" "$model" "$effort" "$threshold" > "${dir}/${sess}" 2>/dev/null \
    || die "cannot write ${dir}/${sess}"

  local line
  line="$(printf '{"ts":"%s","session":"%s","kind":"enter","model":"%s","effort":"%s","threshold":"%s"}' \
    "$(_rs_now_ts)" "$sess" "$(_rs_json_escape "$model")" "$(_rs_json_escape "$effort")" "$(_rs_json_escape "$threshold")")"
  _rs_append_driver_mode_line "$sess" "$line" || true
  printf 'DRIVER_MODE=on\nSESSION=%s\n' "$sess"
}

cmd_driver_mode_exit() {
  local sess="${1:-${CLAUDE_CODE_SESSION_ID:-adhoc}}"
  _rs_check_session_id "$sess"

  local main_root
  main_root="$(_rs_main_checkout_root)" || die "driver-mode: not a git repo"
  # rm -f swallows the no-mark case -- a repeated `exit` is a no-op, not an error.
  rm -f "${main_root}/.agents/driver-mode/${sess}" 2>/dev/null || true

  local line
  line="$(printf '{"ts":"%s","session":"%s","kind":"exit"}' "$(_rs_now_ts)" "$sess")"
  _rs_append_driver_mode_line "$sess" "$line" || true
  printf 'DRIVER_MODE=off\nSESSION=%s\n' "$sess"
}

# Always exits 0 -- a query, same contract as pause-status. A session with no
# mark, or one this cannot resolve to a git repo, both read off.
cmd_driver_mode_status() {
  local sess="${1:-${CLAUDE_CODE_SESSION_ID:-adhoc}}"
  _rs_check_session_id "$sess"
  local main_root
  main_root="$(_rs_main_checkout_root)" || { printf 'DRIVER_MODE=off\n'; return 0; }
  if [ -f "${main_root}/.agents/driver-mode/${sess}" ]; then
    printf 'DRIVER_MODE=on\n'
  else
    printf 'DRIVER_MODE=off\n'
  fi
  return 0
}

# --- compact-threshold (thin-loop-driver T4, ADR 0028 result 3; T6 removed
# the invented gaffer-default branch) ---------------------------------------
# The one carrier T1 verified: a flat top-level NUMERIC key, `autoCompactWindow`
# (tokens), in a Claude Code settings JSON file -- same value, same unit, as
# the CLAUDE_CODE_AUTO_COMPACT_WINDOW env var. Pure reader: ADR 0028 left
# "can a plugin default coexist with a repo/operator value without
# overriding it" unprobed, so this never writes -- see the header comment.

# Parser-free by design (see test-runstate.sh's no-tools T8 sweep and its
# comment on this file): a shallow regex scan for one flat top-level numeric
# key, same trade-off guard.sh's own regex JSON fallback makes for its string
# fields. An absent file or an absent key both read as "not set" -- this is
# a best-effort scan, not a JSON parser, so it cannot distinguish "not set"
# from "malformed file". That is an acceptable trade for a display-only
# reader with no write path to protect.
_rs_json_num_field() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" "$file" 2>/dev/null \
    | head -n1 | grep -oE '[0-9]+$' || true
  return 0
}

# Always exits 0 -- a query, same contract as pause-status/driver-mode
# status. Never writes anything. See the header comment above for the full
# precedence rationale and why there is no session-boundary effect to
# confirm.
cmd_compact_threshold() {
  local main_root
  if ! main_root="$(_rs_main_checkout_root)"; then
    printf 'THRESHOLD=unknown\nSOURCE=unknown\nAPPLIED=no\n'
    return 0
  fi

  local repo_file="${main_root}/.claude/settings.json"
  local local_file="${main_root}/.claude/settings.local.json"
  local user_file="${HOME:-}/.claude/settings.json"

  local env_val="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
  case "$env_val" in ''|*[!0-9]*) env_val="" ;; esac

  local local_val user_val repo_val
  local_val="$(_rs_json_num_field "$local_file" autoCompactWindow)"
  user_val="$(_rs_json_num_field "$user_file" autoCompactWindow)"
  repo_val="$(_rs_json_num_field "$repo_file" autoCompactWindow)"

  # Operator scope, in order: env var, then the local (uncommitted, personal)
  # settings file, then the user-wide settings file. UNVERIFIED precedence —
  # see the header comment.
  if [ -n "$env_val" ]; then
    printf 'THRESHOLD=%s\nSOURCE=operator\nAPPLIED=no\n' "$env_val"
    return 0
  fi
  if [ -n "$local_val" ]; then
    printf 'THRESHOLD=%s\nSOURCE=operator\nAPPLIED=no\n' "$local_val"
    return 0
  fi
  if [ -n "${user_val:-}" ]; then
    printf 'THRESHOLD=%s\nSOURCE=operator\nAPPLIED=no\n' "$user_val"
    return 0
  fi

  # Repo scope: committed, team-shared settings.
  if [ -n "$repo_val" ]; then
    printf 'THRESHOLD=%s\nSOURCE=repo\nAPPLIED=no\n' "$repo_val"
    return 0
  fi

  # Neither is set -- no threshold is in effect. ADR 0028 result 3 records
  # `1m tokens` as the default on Opus 5 (1M) specifically, model-conditional
  # rather than harness-wide, so this reader states no number rather than
  # inventing one.
  printf 'THRESHOLD=unknown\nSOURCE=unknown\nAPPLIED=no\n'
  return 0
}

# --- periodic-pause (thin-loop-driver T10, ADR 0028 result 2) --------------
# Same shape as _rs_packet_attempts_limit above: token-scan the remainder
# after `pause_every_packets:`, skipping non-digit tokens (a trailing
# comment must not defeat this) and stripping one matching pair of quotes
# per token before testing digit-ness, so `pause_every_packets: '3'` is
# honoured rather than silently read as invalid.
#
# "off" (a string, not 0) is the return value for missing/invalid/0 -- unlike
# _rs_packet_attempts_limit, there is no numeric fallback here: a periodic
# pause is a feature that must default to NOT firing, not to firing on some
# arbitrary cadence nobody asked for.
_rs_pause_every_packets() {
  local main_root="$1" ov v
  ov="${main_root}/.agents/project-overrides.yaml"
  v=""
  if [ -f "$ov" ]; then
    v="$(awk '
      /^pause_every_packets:[[:space:]]*/ {
        line = $0
        sub(/^pause_every_packets:[[:space:]]*/, "", line)
        n = split(line, a, " ")
        for (i = 1; i <= n; i++) {
          tok = a[i]
          gsub(/^"/, "", tok); gsub(/"$/, "", tok)
          gsub(/^'"'"'/, "", tok); gsub(/'"'"'$/, "", tok)
          if (tok ~ /^[0-9]+$/) { print tok; exit }
        }
      }
    ' "$ov" 2>/dev/null)"
  fi
  case "$v" in ''|0|*[!0-9]*) echo off ;; *) echo "$v" ;; esac
}

# --- the given session's LATEST driver-mode `enter` record's ts, or empty ---
# Same field-extraction idiom as _rs_open_packets/_rs_route_attempts (plain
# `index`/`substr`, no regex escaping, portable to a POSIX awk). Only `enter`
# records are considered -- an `exit` carries no information this needs.
_rs_latest_driver_mode_enter_ts() {
  local main_root="$1" sess="$2" file
  file="${main_root}/.agents/metrics/driver-mode/${sess}.jsonl"
  [ -f "$file" ] || return 0
  local best_ts="" best_key=-1 ts key
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    key="$(_rs_ts_key "$ts")"
    if [ "$key" -gt "$best_key" ]; then best_key="$key"; best_ts="$ts"; fi
  done <<EOF
$(awk '
    function field(line, name,    pat, pos, rest, q) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      rest = substr(line, pos + length(pat))
      q = index(rest, "\"")
      if (q == 0) return ""
      return substr(rest, 1, q - 1)
    }
    { k = field($0, "kind"); if (k != "enter") next
      ts = field($0, "ts"); if (ts != "") print ts }
  ' "$file" 2>/dev/null)
EOF
  printf '%s' "$best_ts"
}

# --- count TERMINAL outcome records (any record carrying an `outcome`
# --- field, across EVERY session's log) with a PARSED ts >= $since_ts -------
# A swept interruption/abandonment (sweep-open) carries its ORIGINAL start's
# ts, not the sweep's own time -- so a record swept after entering driver
# mode but started before it naturally sorts below $since_ts and is excluded
# here, with no special-case code beyond this timestamp comparison (see the
# header comment above cmd_periodic_pause's dispatch entry for the full
# reasoning).
_rs_count_terminal_since() {
  local main_root="$1" since_ts="$2" dir since_key count=0 ts key
  dir="${main_root}/.agents/metrics/outcomes"
  [ -d "$dir" ] || { printf '0'; return 0; }
  since_key="$(_rs_ts_key "$since_ts")"
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    key="$(_rs_ts_key "$ts")"
    [ "$key" -ge "$since_key" ] && count=$((count + 1))
  done <<EOF
$(awk '
    function field(line, name,    pat, pos, rest, q) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      rest = substr(line, pos + length(pat))
      q = index(rest, "\"")
      if (q == 0) return ""
      return substr(rest, 1, q - 1)
    }
    { o = field($0, "outcome"); if (o == "") next
      ts = field($0, "ts"); if (ts != "") print ts }
  ' "$dir"/*.jsonl 2>/dev/null)
EOF
  printf '%s' "$count"
}

# Always exits 0 -- a query, same contract as compact-threshold/driver-mode
# status. Never writes anything; the CALLER decides whether to act on
# DUE=yes (request-pause is a separate, explicit call). See the header
# comment above for the full field/exclusion reasoning.
cmd_periodic_pause() {
  local sess="${1:-${CLAUDE_CODE_SESSION_ID:-adhoc}}"
  _rs_check_session_id "$sess"

  local main_root
  if ! main_root="$(_rs_main_checkout_root)"; then
    printf 'ENDED=0\nEVERY=off\nDUE=no\n'
    return 0
  fi

  local every; every="$(_rs_pause_every_packets "$main_root")"

  local enter_ts
  enter_ts="$(_rs_latest_driver_mode_enter_ts "$main_root" "$sess")"

  local ended=0
  [ -n "$enter_ts" ] && ended="$(_rs_count_terminal_since "$main_root" "$enter_ts")"

  if [ "$every" = off ]; then
    printf 'ENDED=%s\nEVERY=off\nDUE=no\n' "$ended"
    return 0
  fi

  local due=no
  [ "$ended" -ge "$every" ] && due=yes
  printf 'ENDED=%s\nEVERY=%s\nDUE=%s\n' "$ended" "$every" "$due"
}

# --- mint a sortable run id: UTC timestamp + a short random suffix so two
# --- begin-run calls in the same second cannot collide. Charset is
# --- [A-Za-z0-9-] by construction -- safe as a directory name on every
# --- platform this file already targets, and safe to embed unquoted in JSON.
_rs_mint_run_id() {
  local ts rand
  ts="$(date -u +%Y%m%dT%H%M%S)"
  rand="$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$rand" ] || rand="$$"
  printf '%s-%s' "$ts" "$rand"
}

# Matches exactly what _rs_mint_run_id produces (YYYYMMDDTHHMMSS-<hex>) --
# the shape begin-run's pruning below is allowed to delete. A directory whose
# name does NOT match is left alone unconditionally, since it might be
# operator scratch this command does not own.
_rs_is_run_id_shape() {
  case "$1" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- resolve THIS run's directory the SAME way for every command that
# --- touches it (begin-run/handoff/write-result/route). Previously the first
# --- three derived it from dirname(run-state) while route derived it from the
# --- MAIN checkout (_rs_main_checkout_root) -- so a run-state that is not
# --- exactly at <main-checkout>/.agents/run-state.yaml made handoff's
# --- hand-off-feature refusal check a DIFFERENT routing.jsonl than route
# --- itself wrote, silently bypassing the refusal. All four now resolve via
# --- the main checkout, exactly like .agents/metrics/outcomes/ and
# --- .agents/driver-mode/ already do. Validates run_id as a side effect, so
# --- every reader of run_id goes through the same check (see
# --- _rs_check_run_id above) rather than each caller remembering to call it.
_rs_run_dir() {
  local run_id="$1" label="$2" main_root
  _rs_check_run_id "$run_id"
  main_root="$(_rs_main_checkout_root)" || die "${label}: not a git repo"
  printf '%s/.agents/loop/%s' "$main_root" "$run_id"
}

# --- begin-run: mint run_id once, create + prune .agents/loop/ -------------
# thin-loop-driver T7. `run_id` is minted into run-state ONLY when absent, so
# a resume (which reads the same run-state, run_id already set) keeps it — a
# run spans sessions. Cleanup keeps the CURRENT run's directory plus the
# single newest OTHER shape-matching one, and removes the rest: a bounded
# amount of history survives a crash/inspection without accumulating forever.
cmd_begin_run() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: begin-run <run-state-file>"
  need_file "$f"

  local run_id
  run_id="$(cmd_get "$f" run_id)"
  if [ -z "$run_id" ]; then
    run_id="$(_rs_mint_run_id)"
    cmd_set "$f" run_id "$run_id" >/dev/null
  fi

  local rundir; rundir="$(_rs_run_dir "$run_id" begin-run)"
  local loopdir; loopdir="$(dirname "$rundir")"
  mkdir -p "$rundir" 2>/dev/null || die "cannot create ${rundir}"
  printf 'RUN_ID=%s\nRUN_DIR=%s\n' "$run_id" "$rundir"

  # Prune: among OTHER directories whose name matches the run_id SHAPE (see
  # _rs_is_run_id_shape) -- timestamp-prefixed, so LEXICAL order already
  # equals chronological order and no stat() is needed at all -- keep only the
  # greatest (the newest previous run) and remove the rest.
  #
  # Previously this compared mtimes via `stat -f %m` first, falling back to
  # `stat -c %Y`. On GNU coreutils, `-f %m` is NOT a time format at all -- it
  # is the FILE MODE -- so it prints an octal-looking number, exits 0 (not the
  # failure this code assumed), and the GNU/Linux/Git-Bash fallback branch
  # never ran. `newest` silently latched onto the wrong directory (mode
  # strings, not timestamps, compared numerically), and on the very next
  # begin-run call the ACTUAL newest previous run got deleted instead of kept.
  # A sortable id needs no stat() at all, which is also why it was minted
  # sortable in the first place.
  [ -d "$loopdir" ] || return 0
  local d base others="" newest=""
  for d in "$loopdir"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; base="$(basename "$d")"
    [ "$base" = "$run_id" ] && continue
    _rs_is_run_id_shape "$base" || continue
    others="${others}${base}
"
  done
  [ -n "$others" ] && newest="$(printf '%s' "$others" | sort | tail -1)"
  for d in "$loopdir"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; base="$(basename "$d")"
    [ "$base" = "$run_id" ] && continue
    _rs_is_run_id_shape "$base" || continue
    [ "$base" = "$newest" ] && continue
    rm -rf "$d"
    printf 'REMOVED=%s\n' "$base"
  done
}

# --- resolve a path to an absolute, LEXICALLY normalized form --------------
# Pure string normalization (`.`/`..` segments collapsed), no filesystem
# access and no symlink resolution -- this file has no realpath/readlink -f
# dependency on every platform it targets, and write-result's containment
# check must be able to REFUSE a path without touching disk first (a refusal
# must never require write access outside the run directory to even decide).
# Relative paths resolve against $PWD unless a base is given.
_rs_lexical_abspath() {
  local p="$1" base="${2:-$PWD}"
  case "$p" in
    /*) ;;
    *) p="${base%/}/${p}" ;;
  esac
  printf '%s' "$p" | awk -F'/' '
    {
      n = 0
      for (i = 1; i <= NF; i++) {
        part = $i
        if (part == "" || part == ".") continue
        if (part == "..") { if (n > 0) n--; continue }
        stack[n++] = part
      }
      out = "/"
      for (i = 0; i < n; i++) { out = out stack[i]; if (i < n - 1) out = out "/" }
      print out
    }'
}

# --- extract a handoff title from the piped body, in ONE awk pass over the
# --- WHOLE body -- never `| head -1` on a live pipe, which is the exact
# --- SIGPIPE shape this repo has been bitten by before under
# --- `set -euo pipefail` (a still-writing producer gets killed the instant
# --- `head` finds its first newline and closes the pipe; see CLAUDE.md's
# --- trim-note flake for the same mechanism in a different function).
#
# Precedence: a `TEXT=` line wins outright, prefix stripped -- the real
# producer, `scripts/gspec-backlog.sh handoff`, always emits one as its FIFTH
# line (after PACKET=/FEATURE=/ID=/CHECKED=; see that function's own header
# comment), so blindly taking the first line would take `PACKET=<id>` instead,
# and for a non-gspec id its very first line is `HANDOFF=unknown`. Otherwise
# the first non-empty line that does NOT look like a `KEY=value` header line
# (every other line gspec-backlog.sh's handoff emits matches `^[A-Z_]+=`, so
# this correctly skips them all and would also skip straight past a
# `HANDOFF=unknown`/`REASON=...` refusal with nothing usable behind it).
# Otherwise the packet id itself.
_rs_handoff_title() {
  local body="$1" fallback="$2" title
  title="$(awk '
    !text_seen && /^TEXT=/ { text = substr($0, 6); text_seen = 1 }
    first == "" && $0 != "" && $0 !~ /^[A-Z_]+=/ { first = $0 }
    END {
      if (text_seen) print text
      else if (first != "") print first
      else print ""
    }
  ' <<< "$body")"
  printf '%s' "${title:-$fallback}"
}

# --- handoff: write the packet's brief into its run directory --------------
# thin-loop-driver T8. Refuses (rather than dies) a packet whose LATEST
# routing record (T9) in this run is `hand-off-feature` — the packet has been
# handed to the main context as a question, and dispatching another agent on
# it would race that. The refusal reports rather than dying so the caller
# (the loop) can skip the packet with no record, per the plan.
_rs_latest_routing_token() {
  local pkt="$1" routing_file="$2" line
  [ -f "$routing_file" ] || return 0
  line="$(grep -F "\"packet\":\"${pkt}\"" "$routing_file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 0
  printf '%s' "$line" | sed -E 's/.*"token":"([^"]*)".*/\1/'
}

cmd_handoff() {
  local f="" pkt="" tier="" agent="" pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier)    tier="${2:-}"; shift 2 ;;
      --tier=*)  tier="${1#--tier=}"; shift ;;
      --agent)   agent="${2:-}"; shift 2 ;;
      --agent=*) agent="${1#--agent=}"; shift ;;
      --*) die "usage: handoff <run-state> <packet-id> --tier <tier> --agent <agent> (unknown option: $1)" ;;
      *)
        case "$pos" in
          0) f="$1" ;;
          1) pkt="$1" ;;
          *) die "usage: handoff <run-state> <packet-id> --tier <tier> --agent <agent> (too many arguments)" ;;
        esac
        pos=$((pos + 1)); shift ;;
    esac
  done
  [ -n "$f" ] && [ -n "$pkt" ] && [ -n "$tier" ] && [ -n "$agent" ] \
    || die "usage: handoff <run-state> <packet-id> --tier <tier> --agent <agent>"
  need_file "$f"
  _rs_check_pkt_id "$pkt"
  # Restricted to [a-z-]+ (tighter than a packet id) so neither value can
  # inject a header line -- both are written raw into handoff.md's own
  # header, and a newline in either would open a sibling `key: value` line
  # (or worse, an extra markdown heading) that a careless reader could
  # mistake for part of the contract.
  case "$tier" in
    *[!a-z-]*) die "handoff: --tier must be [a-z-]+" ;;
  esac
  case "$agent" in
    *[!a-z-]*) die "handoff: --agent must be [a-z-]+" ;;
  esac

  local run_id
  run_id="$(cmd_get "$f" run_id)"
  [ -n "$run_id" ] || die "handoff: run-state has no run_id (begin-run has not been called)"
  local rundir; rundir="$(_rs_run_dir "$run_id" handoff)"

  local latest_token
  latest_token="$(_rs_latest_routing_token "$pkt" "${rundir}/routing.jsonl")"
  if [ "$latest_token" = "hand-off-feature" ]; then
    printf 'HANDOFF=refused\nREASON=hand-off-feature\nPACKET=%s\n' "$pkt"
    return 0
  fi

  local pktdir="${rundir}/${pkt}"
  mkdir -p "$pktdir" 2>/dev/null || die "cannot create ${pktdir}"

  # Absolute paths, so a dispatched agent's `write-result`/`route` calls work
  # regardless of its own cwd -- a subagent is not guaranteed the driver's
  # cwd, and a relative path (or a /tmp-vs-/private/tmp alias on macOS) would
  # silently resolve somewhere else (thin-loop-driver review fix #8).
  local abs_f abs_pktdir
  abs_f="$(_rs_lexical_abspath "$f")"
  abs_pktdir="$(_rs_lexical_abspath "$pktdir")"

  local body title target
  body="$(cat)"
  title="$(_rs_handoff_title "$body" "$pkt")"
  target="${pktdir}/handoff.md"
  # GLOBAL, not local -- an EXIT trap referencing a function-LOCAL is
  # bash-version-dependent while the shell unwinds under `set -e` (see
  # gspec-backlog.sh's cmd_check_task for the same fix and its measured
  # macOS-3.2-vs-Linux-5.2 divergence). Scoped to this one write and
  # disarmed right after the mv succeeds, so a failure building or moving
  # the temp file (disk full, permissions, an aborted transform) cannot
  # strand it beside the run directory.
  _rs_tmp=""
  trap '[ -n "${_rs_tmp:-}" ] && rm -f "$_rs_tmp"; :' EXIT
  _rs_tmp="$(mktemp "${pktdir}/.handoff.XXXXXX")" || die "cannot create temp file in ${pktdir}"
  { printf '# %s: %s\n\n' "$pkt" "$title"
    printf 'tier: %s\n' "$tier"
    printf 'agent: %s\n' "$agent"
    printf 'run-state: %s\n' "$abs_f"
    printf 'result: %s\n' "${abs_pktdir}/${agent}.md"
    printf 'review: %s\n\n' "${abs_pktdir}/review.md"
    printf '%s\n' "$body"
  } > "$_rs_tmp"
  mv -f "$_rs_tmp" "$target"
  trap - EXIT
  printf 'HANDOFF=%s\n' "$target"
}

# --- write-result: the ONE write a read-only-tooled agent gets, via a script -
# thin-loop-driver T8. Refuses any <path> that resolves OUTSIDE the current
# run directory (lexically, before touching disk — see _rs_lexical_abspath).
# Writes the status line first (collapsed, same rule as run-state's own
# freeform text — see _yaml_collapse), then stdin verbatim.
cmd_write_result() {
  local f="" path="" status="" pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status)   status="${2:-}"; shift 2 ;;
      --status=*) status="${1#--status=}"; shift ;;
      --*) die "usage: write-result <run-state> <path> --status \"<line>\" (unknown option: $1)" ;;
      *)
        case "$pos" in
          0) f="$1" ;;
          1) path="$1" ;;
          *) die "usage: write-result <run-state> <path> --status \"<line>\" (too many arguments)" ;;
        esac
        pos=$((pos + 1)); shift ;;
    esac
  done
  [ -n "$f" ] && [ -n "$path" ] && [ -n "$status" ] \
    || die "usage: write-result <run-state> <path> --status \"<line>\""
  need_file "$f"

  local run_id
  run_id="$(cmd_get "$f" run_id)"
  [ -n "$run_id" ] || die "write-result: run-state has no run_id (begin-run has not been called)"
  local rundir; rundir="$(_rs_run_dir "$run_id" write-result)"

  local abs_rundir abs_path
  abs_rundir="$(_rs_lexical_abspath "$rundir")"
  abs_path="$(_rs_lexical_abspath "$path")"
  case "$abs_path" in
    "${abs_rundir}/"*) ;;
    *) die "write-result: '${path}' resolves outside the current run directory (${abs_rundir})" ;;
  esac

  local out_dir
  out_dir="$(dirname "$abs_path")"
  mkdir -p "$abs_rundir" 2>/dev/null || true   # in case the run dir was removed since begin-run
  mkdir -p "$out_dir" 2>/dev/null || die "cannot create ${out_dir}"

  # SYMLINK-SAFE containment check. The lexical check above is pure string
  # normalization (deliberately, so an obviously-outside path can be refused
  # WITHOUT touching disk at all) and cannot see a symlinked directory
  # somewhere under the run dir that resolves elsewhere on disk. Now that
  # both directories exist, re-check with their REAL (symlink-resolved) paths.
  local real_rundir real_outdir
  real_rundir="$(cd "$abs_rundir" 2>/dev/null && pwd -P)" || die "write-result: cannot resolve the run directory"
  real_outdir="$(cd "$out_dir" 2>/dev/null && pwd -P)" || die "write-result: cannot resolve the target directory"
  case "$real_outdir" in
    "$real_rundir"|"$real_rundir"/*) ;;
    *) die "write-result: '${path}' escapes the run directory via a symlink" ;;
  esac

  # GLOBAL, not local -- see cmd_handoff's identical comment on the same
  # pattern: an EXIT trap referencing a function-LOCAL is bash-version-
  # dependent while the shell unwinds under `set -e`.
  _rs_tmp=""
  trap '[ -n "${_rs_tmp:-}" ] && rm -f "$_rs_tmp"; :' EXIT
  _rs_tmp="$(mktemp "${out_dir}/.write-result.XXXXXX")" || die "cannot create temp file in ${out_dir}"
  { printf '%s\n' "$(_yaml_collapse "$status")"
    cat
  } > "$_rs_tmp"
  mv -f "$_rs_tmp" "$abs_path"
  trap - EXIT
  printf 'RESULT=%s\n' "$abs_path"
}

# --- packet_attempts: the fix/retry limit before routing to the decider ----
# Token-scans the remainder after `packet_attempts:` (skipping over anything
# that isn't purely digits, so a trailing comment does not defeat this) and,
# for EACH token, strips one matching pair of quotes before testing digit-
# ness -- `packet_attempts: '3'` is legal YAML and must not silently read as
# missing/invalid just because the raw token is `'3'`, not `3`.
_rs_packet_attempts_limit() {
  local main_root="$1" ov v
  ov="${main_root}/.agents/project-overrides.yaml"
  v=""
  if [ -f "$ov" ]; then
    v="$(awk '
      /^packet_attempts:[[:space:]]*/ {
        line = $0
        sub(/^packet_attempts:[[:space:]]*/, "", line)
        n = split(line, a, " ")
        for (i = 1; i <= n; i++) {
          tok = a[i]
          gsub(/^"/, "", tok); gsub(/"$/, "", tok)
          gsub(/^'"'"'/, "", tok); gsub(/'"'"'$/, "", tok)
          if (tok ~ /^[0-9]+$/) { print tok; exit }
        }
      }
    ' "$ov" 2>/dev/null)"
  fi
  case "$v" in ''|0|*[!0-9]*) echo 1 ;; *) echo "$v" ;; esac
}

# --- bundle_max_tasks: the largest number of tasks a bundle may hold -------
# Same token-scanning shape as _rs_packet_attempts_limit directly above:
# token-scan the remainder after `bundle_max_tasks:`, skipping over anything
# that isn't purely digits (so a trailing comment cannot defeat this) and,
# for EACH token, stripping one matching pair of quotes before testing digit-
# ness -- `bundle_max_tasks: '4'` is legal YAML and must not silently read as
# missing/invalid just because the raw token is `'4'`, not `4`.
#
# Missing, invalid, zero AND negative all read as 1 -- unlike
# _rs_pause_every_packets's "off" sentinel, this has a numeric floor: a
# bundle of 1 task is just a packet, so "1" already means bundling is off,
# with no separate off/on distinction needed. Negative values never reach
# the case statement as candidates in the first place: the awk token match
# `^[0-9]+$` has no sign class, so a token like `-4` is skipped as non-digit
# by the same rule that skips a trailing comment, and the scan falls through
# to empty (missing) just as if the key had not matched at all.
_rs_bundle_max_tasks() {
  local main_root="$1" ov v
  ov="${main_root}/.agents/project-overrides.yaml"
  v=""
  if [ -f "$ov" ]; then
    v="$(awk '
      /^bundle_max_tasks:[[:space:]]*/ {
        line = $0
        sub(/^bundle_max_tasks:[[:space:]]*/, "", line)
        n = split(line, a, " ")
        for (i = 1; i <= n; i++) {
          tok = a[i]
          gsub(/^"/, "", tok); gsub(/"$/, "", tok)
          gsub(/^'"'"'/, "", tok); gsub(/'"'"'$/, "", tok)
          if (tok ~ /^[0-9]+$/) { print tok; exit }
        }
      }
    ' "$ov" 2>/dev/null)"
  fi
  case "$v" in ''|0|*[!0-9]*) echo 1 ;; *) echo "$v" ;; esac
}

# Always exits 0 -- a pure reader, same contract as periodic-pause/compact-
# threshold. Never writes anything.
cmd_bundle_cap() {
  local main_root
  if ! main_root="$(_rs_main_checkout_root)"; then
    printf 'CAP=1\n'
    return 0
  fi
  printf 'CAP=%s\n' "$(_rs_bundle_max_tasks "$main_root")"
}

# --- attempts already spent on $pkt since its latest kind=start record -----
# A kind=continue record deliberately does NOT move this boundary (the plan's
# own rule: "a continuation does not reset the count") — only a genuine new
# `start` does. fix and retry share ONE pool, since the PRD counts attempts
# from either route.
_rs_route_attempts() {
  local pkt="$1" main_root="$2" routing_file="$3"
  local outcomes_dir="${main_root}/.agents/metrics/outcomes"
  local extract='
    function field(line, name,    pat, pos, rest, q) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      rest = substr(line, pos + length(pat))
      q = index(rest, "\"")
      if (q == 0) return ""
      return substr(rest, 1, q - 1)
    }'

  local latest_start_ts="" latest_key=0
  if [ -d "$outcomes_dir" ]; then
    local ts key best=-1
    while IFS= read -r ts; do
      [ -n "$ts" ] || continue
      key="$(_rs_ts_key "$ts")"
      if [ "$key" -gt "$best" ]; then best="$key"; latest_start_ts="$ts"; fi
    done <<EOF
$(awk -v pkt="$pkt" "$extract"'
      { p = field($0, "packet"); if (p != pkt) next
        k = field($0, "kind");   if (k != "start") next
        ts = field($0, "ts");    if (ts != "") print ts }
    ' "$outcomes_dir"/*.jsonl 2>/dev/null)
EOF
  fi
  [ -n "$latest_start_ts" ] && latest_key="$(_rs_ts_key "$latest_start_ts")"

  local count=0
  if [ -f "$routing_file" ]; then
    local ts key
    while IFS= read -r ts; do
      [ -n "$ts" ] || continue
      key="$(_rs_ts_key "$ts")"
      [ "$key" -ge "$latest_key" ] && count=$((count + 1))
    done <<EOF
$(awk -v pkt="$pkt" "$extract"'
      { p = field($0, "packet"); if (p != pkt) next
        t = field($0, "token");  if (t != "fix" && t != "retry") next
        ts = field($0, "ts");    if (ts != "") print ts }
    ' "$routing_file" 2>/dev/null)
EOF
  fi
  printf '%s' "$count"
}

# --- route: the mechanical verdict -> action mapping (thin-loop-driver T9) --
# Appends a record to THIS RUN's routing.jsonl (never the outcomes log — see
# the header note) and prints ACTION=/ATTEMPTS=/LIMIT=. The record is written
# even for a `stop`/`decider` action, so a later run-digest (T11) can see
# every decision made, and so a repeated `handoff` call for a `hand-off-feature`
# packet can be refused.
cmd_route() {
  local f="" pkt="" token="" status="" pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status)   status="${2:-}"; shift 2 ;;
      --status=*) status="${1#--status=}"; shift ;;
      --*) die "usage: route <run-state> <packet-id> <token> [--status \"<line>\"] (unknown option: $1)" ;;
      *)
        case "$pos" in
          0) f="$1" ;;
          1) pkt="$1" ;;
          2) token="$1" ;;
          *) die "usage: route <run-state> <packet-id> <token> [--status \"<line>\"] (too many arguments)" ;;
        esac
        pos=$((pos + 1)); shift ;;
    esac
  done
  [ -n "$f" ] && [ -n "$pkt" ] && [ -n "$token" ] \
    || die "usage: route <run-state> <packet-id> <token> [--status \"<line>\"]"
  need_file "$f"
  _rs_check_pkt_id "$pkt"
  case "$token" in
    pass|fix|retry|escalate|reorder|append-task|hand-off-feature|ask-operator) ;;
    *) die "route: token must be one of: pass fix retry escalate reorder append-task hand-off-feature ask-operator" ;;
  esac

  local run_id
  run_id="$(cmd_get "$f" run_id)"
  [ -n "$run_id" ] || die "route: run-state has no run_id (begin-run has not been called)"
  local rundir; rundir="$(_rs_run_dir "$run_id" route)"
  local main_root
  main_root="$(_rs_main_checkout_root)" || die "route: not a git repo"
  local routing_file="${rundir}/routing.jsonl"

  local limit; limit="$(_rs_packet_attempts_limit "$main_root")"

  local attempts_before=0
  case "$token" in
    fix|retry) attempts_before="$(_rs_route_attempts "$pkt" "$main_root" "$routing_file")" ;;
  esac

  local action attempts=$attempts_before
  case "$token" in
    pass) action=land ;;
    fix)
      attempts=$((attempts_before + 1))
      if [ "$attempts" -le "$limit" ]; then action=attempt; else action=decider; fi
      ;;
    retry)
      attempts=$((attempts_before + 1))
      if [ "$attempts" -le "$limit" ]; then action=attempt; else action=stop; fi
      ;;
    escalate) action=decider ;;
    reorder|append-task|hand-off-feature) action=discard-advance ;;
    ask-operator) action=stop ;;
  esac

  mkdir -p "$(dirname "$routing_file")" 2>/dev/null || true
  local line
  line="$(printf '{"ts":"%s","packet":"%s","token":"%s","action":"%s","status":"%s"}' \
    "$(_rs_now_ts)" "$pkt" "$token" "$action" "$(_rs_json_escape "$status")")"
  printf '%s\n' "$line" >> "$routing_file" 2>/dev/null || true

  if [ "$token" = retry ] && [ "$action" = stop ]; then
    printf 'ACTION=stop\nATTEMPTS=%s\nLIMIT=%s\nquestion: retry was returned for packet %s past its attempt limit (%s) -- refusing to loop; a human must decide how to proceed\n' \
      "$attempts" "$limit" "$pkt" "$limit"
    return 0
  fi
  printf 'ACTION=%s\nATTEMPTS=%s\nLIMIT=%s\n' "$action" "$attempts" "$limit"
}

# =============================================================================
# run-digest (thin-loop-driver T11, ADR 0028 result 4)
# =============================================================================

# --- run-digest: a packet's title, parsed from its OWN handoff header ------
# cmd_handoff always writes the first line as exactly `# <pkt>: <title>` --
# this strips that literal prefix with plain string ops (index/substr), never
# a regex: a packet id containing `.` (legal and common -- e.g.
# "self-host-hardening-gaps") is a regex metacharacter, and pkt is not
# escaped for use as one anywhere in this file. Falls back to the packet id
# itself when the file is missing, empty, or its first line does not carry
# that exact prefix -- this reads a file it did not itself write, so it
# never assumes that file is well-formed.
_rs_digest_title() {
  local pktdir="$1" pkt="$2" line1
  local file="${pktdir}/handoff.md"
  [ -f "$file" ] || { printf '%s' "$pkt"; return 0; }
  line1="$(head -1 "$file" 2>/dev/null || true)"
  # LINE is interpolated through ENVIRON, never `-v` -- `-v` expands `\n`
  # (and other backslash escapes) IN THE VALUE, so a title carrying a
  # literal `\n` or a Windows path would inject a stray newline into the
  # digest, splitting one packet into two lines (or worse, a fragment
  # lacking its leading type field). pkt is charset-validated (no
  # backslash reaches it) and stays on `-v`.
  LINE="$line1" awk -v pkt="$pkt" '
    BEGIN {
      line = ENVIRON["LINE"]
      prefix = "# " pkt ": "
      if (index(line, prefix) == 1) print substr(line, length(prefix) + 1)
      else print pkt
    }'
}

# --- run-digest: the terminal outcome recorded AT OR AFTER a packet's LATEST
# --- start-or-continuation boundary, or empty for "still open" --------------
# Same boundary rule as _rs_open_packets (kind=start OR kind=continue both
# count -- matching the PRD's own "after its latest start or continuation"),
# but returns the OUTCOME VALUE rather than a closed/open boolean, and scans
# across EVERY session's outcomes log the same way _rs_route_attempts and
# _rs_count_terminal_since do (a packet can start in one session and finish
# in another). Uses field_esc (a walk that honours `\"`/`\\`), not the
# simpler index-based `field()` used elsewhere in this file, purely so this
# function stays correct if any of these fields is ever run through
# _rs_json_escape -- none of ts/packet/kind/outcome are today.
_rs_digest_outcome() {
  local pkt="$1" outcomes_dir="$2"
  [ -d "$outcomes_dir" ] || { printf ''; return 0; }
  local extract='
    function field_esc(line, name,    pat, pos, i, n, c, out, esc) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      i = pos + length(pat); n = length(line); out = ""; esc = 0
      while (i <= n) {
        c = substr(line, i, 1)
        if (esc) { out = out c; esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == "\"") { return out }
        else { out = out c }
        i++
      }
      return out
    }'

  local boundary_key=-1 ts key
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    key="$(_rs_ts_key "$ts")"
    [ "$key" -gt "$boundary_key" ] && boundary_key="$key"
  done <<EOF
$(awk -v pkt="$pkt" "$extract"'
    { p = field_esc($0, "packet"); if (p != pkt) next
      k = field_esc($0, "kind");   if (k != "start" && k != "continue") next
      ts = field_esc($0, "ts");    if (ts != "") print ts }
  ' "$outcomes_dir"/*.jsonl 2>/dev/null)
EOF
  [ "$boundary_key" -ge 0 ] || { printf ''; return 0; }

  local best_key=-1 best_outcome="" outc
  while IFS="$(printf '\t')" read -r ts outc; do
    [ -n "$ts" ] || continue
    key="$(_rs_ts_key "$ts")"
    [ "$key" -ge "$boundary_key" ] || continue
    [ "$key" -gt "$best_key" ] || continue
    best_key="$key"; best_outcome="$outc"
  done <<EOF
$(awk -v pkt="$pkt" "$extract"'
    { p = field_esc($0, "packet"); if (p != pkt) next
      o = field_esc($0, "outcome"); if (o == "") next
      ts = field_esc($0, "ts");     if (ts != "") print ts "\t" o }
  ' "$outcomes_dir"/*.jsonl 2>/dev/null)
EOF
  printf '%s' "$best_outcome"
}

# --- run-digest: model/effort/threshold at the MOST RECENT driver-mode
# --- `enter`, across EVERY session's log --------------------------------
# A run spans sessions (begin-run keeps run_id across a resume), and each
# session that drove it entered driver mode separately -- so "what's in
# effect" is whichever entered LAST, not one session named up front (unlike
# periodic-pause, which is deliberately scoped to ONE session because its
# count resets per restart). Prints ts\tmodel\teffort\tthreshold for the
# winning record, or nothing at all when no session has ever entered driver
# mode in this checkout.
_rs_digest_latest_enter() {
  local main_root="$1"
  local dir="${main_root}/.agents/metrics/driver-mode"
  [ -d "$dir" ] || return 0
  local extract='
    function field_esc(line, name,    pat, pos, i, n, c, out, esc) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      i = pos + length(pat); n = length(line); out = ""; esc = 0
      while (i <= n) {
        c = substr(line, i, 1)
        if (esc) { out = out c; esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == "\"") { return out }
        else { out = out c }
        i++
      }
      return out
    }'
  local best_key=-1 best_line="" line ts key
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ts="${line%%$(printf '\t')*}"
    key="$(_rs_ts_key "$ts")"
    if [ "$key" -gt "$best_key" ]; then best_key="$key"; best_line="$line"; fi
  done <<EOF
$(awk "$extract"'
    { k = field_esc($0, "kind"); if (k != "enter") next
      ts = field_esc($0, "ts");  if (ts == "") next
      m = field_esc($0, "model"); e = field_esc($0, "effort"); t = field_esc($0, "threshold")
      print ts "\t" m "\t" e "\t" t }
  ' "$dir"/*.jsonl 2>/dev/null)
EOF
  printf '%s' "$best_line"
}

# --- run-digest: assemble the run's report from files alone, nothing from
# --- memory (thin-loop-driver T11) ------------------------------------------
# See the header comment above for the exact line shapes this prints -- one
# line per packet/decision/hand-off-feature record, plus at most one `enter`
# line, tab-separated, and NOTHING else: no headers, no blank lines, no
# summary counts -- a caller renders those from what it counts here.
cmd_run_digest() {
  local f="" since="" pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)   since="${2:-}"; shift 2 ;;
      --since=*) since="${1#--since=}"; shift ;;
      --*) die "usage: run-digest <run-state> [--since <ts>] (unknown option: $1)" ;;
      *)
        case "$pos" in
          0) f="$1" ;;
          *) die "usage: run-digest <run-state> [--since <ts>] (too many arguments)" ;;
        esac
        pos=$((pos + 1)); shift ;;
    esac
  done
  [ -n "$f" ] || die "usage: run-digest <run-state> [--since <ts>]"
  need_file "$f"

  local run_id
  run_id="$(cmd_get "$f" run_id)"
  [ -n "$run_id" ] || die "run-digest: run-state has no run_id (begin-run has not been called)"
  local rundir; rundir="$(_rs_run_dir "$run_id" run-digest)"
  local main_root
  main_root="$(_rs_main_checkout_root)" || die "run-digest: not a git repo"
  local outcomes_dir="${main_root}/.agents/metrics/outcomes"
  local routing_file="${rundir}/routing.jsonl"

  local status cursor
  status="$(cmd_get "$f" status)"
  cursor="$(cmd_cursor "$f")"

  # --- one line per packet begun in the run (a handoff.md exists) -----------
  if [ -d "$rundir" ]; then
    local d pkt title outcome
    for d in "$rundir"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"; pkt="$(basename "$d")"
      [ -f "$d/handoff.md" ] || continue
      title="$(_rs_digest_title "$d" "$pkt")"
      if [ "$status" = paused ] && [ -n "$cursor" ] && [ "$pkt" = "$cursor" ]; then
        outcome=paused
      else
        outcome="$(_rs_digest_outcome "$pkt" "$outcomes_dir")"
        [ -n "$outcome" ] || outcome=open
      fi
      printf 'packet\t%s\t%s\t%s\n' "$pkt" "$title" "$outcome"
    done
  fi

  if [ -f "$routing_file" ]; then
    local since_key=-1
    [ -n "$since" ] && since_key="$(_rs_ts_key "$since")"

    # --- one line per decider decision since --since (all of them when
    # --- --since is omitted) --------------------------------------------
    local line rline_ts rline_token rline_pkt rline_key
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rline_token="$(printf '%s' "$line" | sed -E 's/.*"token":"([^"]*)".*/\1/')"
      case "$rline_token" in
        retry|reorder|append-task|hand-off-feature|ask-operator) ;;
        *) continue ;;
      esac
      if [ -n "$since" ]; then
        rline_ts="$(printf '%s' "$line" | sed -E 's/.*"ts":"([^"]*)".*/\1/')"
        rline_key="$(_rs_ts_key "$rline_ts")"
        [ "$rline_key" -ge "$since_key" ] || continue
      fi
      rline_pkt="$(printf '%s' "$line" | sed -E 's/.*"packet":"([^"]*)".*/\1/')"
      printf 'decision\t%s\t%s\n' "$rline_pkt" "$rline_token"
    done < "$routing_file"

    # --- one line per hand-off-feature record, for the WHOLE run -- never
    # --- scoped to --since: a stop report must list every open question
    # --- the run recorded, not only recent ones -------------------------
    local hstatus
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        *'"token":"hand-off-feature"'*) ;;
        *) continue ;;
      esac
      rline_pkt="$(printf '%s' "$line" | sed -E 's/.*"packet":"([^"]*)".*/\1/')"
      hstatus="$(printf '%s' "$line" | awk '
        function field_esc(line, name,    pat, pos, i, n, c, out, esc) {
          pat = "\"" name "\":\""
          pos = index(line, pat)
          if (pos == 0) return ""
          i = pos + length(pat); n = length(line); out = ""; esc = 0
          while (i <= n) {
            c = substr(line, i, 1)
            if (esc) { out = out c; esc = 0 }
            else if (c == "\\") { esc = 1 }
            else if (c == "\"") { return out }
            else { out = out c }
            i++
          }
          return out
        }
        { print field_esc($0, "status") }')"
      printf 'handoff-feature\t%s\t%s\n' "$rline_pkt" "$hstatus"
    done < "$routing_file"
  fi

  # --- model/effort/threshold at the latest driver-mode enter, any session --
  # Fields are pulled with `cut -f`, NOT `IFS=<tab> read`: bash always treats
  # tab as "IFS whitespace" for splitting purposes regardless of what IFS is
  # set to, so adjacent tabs collapse and an empty field (e.g. `--model ""`,
  # which the enter command writes verbatim rather than defaulting -- the
  # default only applies when the flag is ABSENT) silently shifts every later
  # field left. `cut` has no such collapsing behaviour, so a field that is
  # empty stays a positionally-stable empty field rather than eating its
  # neighbour. Same trap already documented and fixed the same way at
  # _rs_open_packets above.
  local enter_line
  enter_line="$(_rs_digest_latest_enter "$main_root")"
  if [ -n "$enter_line" ]; then
    local e_model e_effort e_threshold
    e_model="$(printf '%s' "$enter_line" | cut -f2)"
    e_effort="$(printf '%s' "$enter_line" | cut -f3)"
    e_threshold="$(printf '%s' "$enter_line" | cut -f4)"
    printf 'enter\t%s\t%s\t%s\n' "$e_model" "$e_effort" "$e_threshold"
  fi
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

# ISO-8601 UTC -> epoch seconds, on both BSD and GNU date. Empty on failure.
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

# --- clear-pause: remove the whole-run sentinel ------------------------------
# rm -f swallows the no-match case. retire-unused-loop-modes T1 removed the
# per-lane `<pause-file>.<id>` variant this used to also sweep — there is now
# exactly one sentinel path.
cmd_clear_pause() {
  local f="${1:-}"; [ -n "$f" ] || die "usage: clear-pause <pause-file>"
  rm -f "$f" 2>/dev/null || true
  printf 'pause cleared: %s\n' "$f"
}

# --- pause-status: is a pause requested for the whole run? -------------------
# Prints PAUSE=1/0 on stdout; ALWAYS exits 0 (a query never fails the caller).
# Whole-run only — retire-unused-loop-modes T1 removed the lane-scoped variant.
cmd_pause_status() {
  local f="${1:-}" r
  [ -n "$f" ] || die "usage: pause-status <pause-file>"
  if [ -f "$f" ]; then
    r="$(grep -E '^reason:' "$f" 2>/dev/null | head -1 | sed -E 's/^reason:[[:space:]]*//')"
    printf 'PAUSE=1 reason=%s\n' "${r:-<none>}"; return 0
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

# Paths under which untracked files are DELIBERATE OUTPUT some other tool
# produced for a human to review, not the loop's own crash-recovery scratch
# (thin-loop-driver-gaps T3). `.gspec/memory/pending/` is the memorizer's queue
# (`.claude/commands/gspec-memorize.md`) -- agent-recorded memories awaiting
# `/gspec-memorize` review, one directory per agent, never written by the loop
# itself. A tree whose dirt includes any of these must ESCALATE rather than
# `discard`: the non-destructive stash discard performs would still sweep
# unreviewed work out of the tree without asking. Extend via
# ORCH_RECONCILE_REVIEWED_OUTPUT_PATTERNS (colon-separated `grep -E` patterns,
# appended to the built-in list) rather than editing this array for a
# project-local addition.
RECONCILE_REVIEWED_OUTPUT_PATTERNS=(
  '(^|/)\.gspec/memory/pending/'
)

# True (rc 0) when at least one path in `git status --porcelain` for $1 falls
# under a reviewed-output root. A rename's "old -> new" form is matched on the
# new path. Deliberately ANY, not ALL: a tree mixing ordinary scratch with
# reviewed output must still escalate, since a stash would sweep both together.
_dirty_has_reviewed_output() {
  local wt="$1" combined="" pat extra
  for pat in "${RECONCILE_REVIEWED_OUTPUT_PATTERNS[@]}"; do
    [ -n "$pat" ] || continue
    combined="${combined:+$combined|}($pat)"
  done
  if [ -n "${ORCH_RECONCILE_REVIEWED_OUTPUT_PATTERNS:-}" ]; then
    local IFS=':'
    for extra in $ORCH_RECONCILE_REVIEWED_OUTPUT_PATTERNS; do
      [ -n "$extra" ] || continue
      combined="${combined:+$combined|}($extra)"
    done
  fi
  [ -n "$combined" ] || return 1
  # --untracked-files=all: the default `status --porcelain` collapses a whole
  # untracked DIRECTORY to one line (`?? .gspec/`), which can never match a
  # pattern anchored on a file under it -- this must see every leaf path.
  #
  # -z (NUL-delimited, never quoted) instead of the default porcelain form,
  # and NO `-q` on grep (thin-loop-driver-gaps T3 review): under
  # `set -euo pipefail`, `grep -q` exits the instant it finds a match and
  # closes the pipe, so `git status`/`sed` -- still writing on a large dirty
  # tree -- take SIGPIPE and the whole pipeline reports 141, which this
  # function then read as "no match" and silently fell back to `discard`. This
  # is the exact SIGPIPE-under-pipefail shape already fixed at three other call
  # sites in this file (see the `trim-note` history). Draining grep's input
  # (no `-q`, redirect stdout instead) lets the producers finish writing.
  # `-z` also sidesteps `git status --porcelain`'s C-quoting of paths with a
  # space or a non-ASCII byte -- quoted, the leading `"` would never match a
  # pattern anchored on `^` or `/` -- at the cost of losing the `old -> new`
  # rename separator, which `-z` never emits anyway (a rename is two separate
  # NUL-terminated fields, old path then new path; the old path's first three
  # bytes get stripped by the same `^.{3}` rule, which is harmless since
  # matching is ANY and the new path is judged correctly).
  git -C "$wt" status --porcelain --untracked-files=all -z \
    | tr '\0' '\n' \
    | sed -E 's/^.{3}//' \
    | grep -E "$combined" >/dev/null
}

# The crash-recovery decision table for ONE tree/branch, factored out from
# cmd_reconcile (ADR 0005) as its own function. It formerly also served
# cmd_reconcile_parallel, once per lane (ADR 0016); that caller was removed by
# retire-unused-loop-modes T1 along with parallel mode itself, leaving
# cmd_reconcile as the one caller — the per-lane parameter shape below is kept
# as-is rather than narrowed, since narrowing it now would just be churn for no
# behavior change. Sets globals RC_DECISION / RC_REASON; never prints, never
# exits. Args:
#   $1 inspect-tree   git work-tree to read state from (the live checkout)
#   $2 head-ref       what to treat as HEAD (`HEAD`)
#   $3 check-dirty    1 = a dirty tree means scratch (discard); 0 = ignore dirt
#                     (no live worktree, e.g. inspecting a branch by ref)
#   $4 green          recorded last_green_commit (may be short; may be empty)
#   $5 cursor         the packet id the tree is expected to be on
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
    elif [ "$check_dirty" = 1 ] && _dirty_has_reviewed_output "$wt"; then
      _rc escalate "the tree holds deliberate output the loop did not create (a reviewed-output path, e.g. .gspec/memory/pending/) — a human should review it before anything is set aside"
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
# Lane listing (schema 3). Parallel mode itself (ADR 0016) was retired by
# retire-unused-loop-modes T1 — this file no longer writes packets[]/lanes[] and
# no longer has an id/status-based packet query or a per-lane reconcile. `lanes`
# survives as a READ-ONLY projection: a run-state written before the retirement
# can still carry a `lanes:` block, and `resume`'s stop path on such a run-state
# reads it to name lane branches/worktrees for the operator (it merges none of
# them and leaves every branch untouched). Nothing here writes a new lane row.
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

cmd_lanes() {
  local f="${1:-}"; [ -n "$f" ] || die "usage: lanes <file>"
  need_file "$f"
  _list_records "$f" lanes id branch worktree packet last_green_commit status
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
  record-start)   cmd_record_start   "$@" ;;
  sweep-open)     cmd_sweep_open     "$@" ;;
  add-finding)   cmd_add_finding   "$@" ;;
  drop-finding)  cmd_drop_finding  "$@" ;;
  findings)      cmd_findings      "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
  reconstruct) cmd_reconstruct "$@" ;;
  lanes)              cmd_lanes             "$@" ;;
  request-pause)      cmd_request_pause     "$@" ;;
  clear-pause)        cmd_clear_pause       "$@" ;;
  pause-status)       cmd_pause_status      "$@" ;;
  driver-mode)   cmd_driver_mode   "$@" ;;
  begin-run)     cmd_begin_run     "$@" ;;
  handoff)       cmd_handoff       "$@" ;;
  write-result)  cmd_write_result  "$@" ;;
  route)         cmd_route         "$@" ;;
  compact-threshold) cmd_compact_threshold "$@" ;;
  periodic-pause)    cmd_periodic_pause    "$@" ;;
  run-digest)        cmd_run_digest        "$@" ;;
  bundle-cap)        cmd_bundle_cap        "$@" ;;
  -h|--help|help|"") sed -n '2,419p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '${cmd}' (try --help)" ;;
esac
