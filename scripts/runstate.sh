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
#                                    never need one). A summary over 160
#                                    CHARACTERS (counted after the newline
#                                    collapse) is shortened in the index, with a
#                                    trailing … mark, and its full text written
#                                    to the body — created, and pointed at by
#                                    file:, even without --body. Never refused
#                                    for length; reports CAPPED=yes when it
#                                    happened.
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
#   merge-findings <file> <survivor-id> <removed-id>
#                                    fold two duplicate findings into one,
#                                    LOSSLESSLY: the survivor's `packets:`
#                                    becomes the union of both lists, the
#                                    removed entry's summary AND the whole of
#                                    its body are appended to the survivor's
#                                    body file (created here, with the entry's
#                                    `file:` pointer, when the survivor had
#                                    none), and only THEN is the removed entry
#                                    dropped with its body — both-or-neither on
#                                    drop-finding's own sequence, so a failure
#                                    anywhere leaves both entries and both
#                                    bodies untouched. Whether two findings
#                                    really are duplicates is a judgment
#                                    nothing here checks; losslessness is what
#                                    makes being wrong about it recoverable.
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
#                                    ALWAYS appends templates/handoff-required.md
#                                    verbatim after the body, resolved from this
#                                    SCRIPT's location (never the caller's cwd;
#                                    $ORCH_HANDOFF_REQUIRED redirects it for
#                                    fixtures). No option omits it: a missing,
#                                    unreadable or whitespace-only template
#                                    exits non-zero naming that path and writes
#                                    no handoff file at all. After those six
#                                    lines it appends one `REQUIRED: <line>` per
#                                    non-blank, non-`#` line of
#                                    `.agents/handoff-extra` in EVERY discovered
#                                    config root (ADR 0011's bounded upward
#                                    walk, reimplemented here — see
#                                    _rs_handoff_extra_lines), unioned so a
#                                    nested or foreign root can only add lines.
#                                    No such file anywhere ⇒ nothing is emitted
#                                    and the handoff is byte-identical to one
#                                    written before the mechanism existed; a
#                                    file that is PRESENT but unreadable is
#                                    refused exactly as a missing template is.
#   amend-handoff <run-state> <packet-id>
#                                    escalation-decider T4: splices stdin into
#                                    ONE marked decider block at the end of that
#                                    packet's handoff.md — appended when the
#                                    block is absent, replaced in place when it
#                                    is present, so repeated `retry` decisions
#                                    leave ONE amendment rather than a stack.
#                                    The decider's only write into a handoff
#                                    file, and the reason it needs no Edit tool.
#                                    The file is SPLICED, never regenerated:
#                                    the `# <pkt>: <title>` first line
#                                    run-digest parses and the verification
#                                    contract at the tail are both left exactly
#                                    as handoff wrote them. Refuses, writing
#                                    nothing: a packet-id resolving outside the
#                                    CURRENT run directory (lexically first,
#                                    then by REAL path against a symlinked
#                                    packet directory, exactly as write-result
#                                    decides it), a packet with no handoff.md,
#                                    empty/whitespace-only stdin, replacement
#                                    text carrying either marker line, and a
#                                    file whose existing block is malformed
#                                    (unpaired or duplicated markers — there is
#                                    no end for the splice to stop at, and
#                                    guessing would swallow the contract).
#                                    Prints HANDOFF=<path> and
#                                    AMENDMENT=inserted|replaced.
#   check-status --status "<line>"   loop-driver-run-gaps T1: the ONE mechanical
#                                    reading of templates/status-line.md, run by
#                                    the driver on every returned line. Prints
#                                    STATUS_LINE=ok and exits 0 when <line> is
#                                    ONE line carrying no backtick and no `$`,
#                                    its first field (everything before the
#                                    first ` · `) is one word, the field between
#                                    its second-to-last and last ` · ` is
#                                    literally `result: needs-reading` or
#                                    `result: no`, and its last field
#                                    (everything after the last ` · `) is
#                                    non-empty and whitespace-free. Otherwise
#                                    exits non-zero with ONE reason naming the
#                                    RULE that failed — never a generic
#                                    "malformed status line", which would leave
#                                    the driver's single re-dispatch nothing
#                                    actionable to pass back. Boundaries come
#                                    from the FIRST and LAST separator, NOT a
#                                    field count: the two middle fields are free
#                                    text and may carry their own ` · `, so a
#                                    four-way split would refuse a line the
#                                    template explicitly permits. Reads no file
#                                    and needs no run-state.
#   write-result <run-state> <path> --status "<line>"
#                                    atomically writes the (newline-collapsed)
#                                    status line followed by stdin to <path>.
#                                    Refuses any <path> resolving outside the
#                                    CURRENT run directory, checked lexically
#                                    (no filesystem access before the
#                                    containment decision, so a refused write
#                                    never touches disk outside the run dir).
#                                    Runs `check-status` on <line> FIRST, before
#                                    anything touches disk, and refuses an
#                                    off-grammar line with the byte-identical
#                                    reason `check-status` prints — no result
#                                    file is created at all (T2).
#   route <run-state> <packet-id> <token> [--status "<line>"]
#                                    appends a routing record to
#                                    .agents/loop/<run_id>/routing.jsonl (never
#                                    the outcomes log) and prints one
#                                    ACTION=land|attempt|decider|discard-advance|continue|stop
#                                    with ATTEMPTS=/LIMIT=. `continue` (the
#                                    implementer's own token, stopped at its
#                                    turn budget) maps to ACTION=continue and
#                                    prints ATTEMPTS= as the packet's live
#                                    attempt count, never incremented: a
#                                    continuation spends no attempt, and its
#                                    record never enters the fix/retry pool
#                                    (implementer-continuation T2). Continuations
#                                    are capped PER ATTEMPT (T3): `continue`
#                                    records since the later of the latest
#                                    kind=start record and the latest routing
#                                    record with action `attempt`, against
#                                    `packet_continuations` in
#                                    .agents/project-overrides.yaml (3 when
#                                    missing/invalid/0); past it `continue`
#                                    refuses as ACTION=stop with a `question:`
#                                    line, its record carrying action `stop`.
#                                    `fix` and `retry`
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
#                                    never terminate. A non-empty --status is
#                                    run through `check-status` FIRST, before
#                                    the record is appended and before anything
#                                    else touches disk: an off-grammar line is
#                                    refused with the byte-identical reason
#                                    `check-status` prints and routing.jsonl is
#                                    left byte-unchanged (T2).
#   record-decision <run-state> <packet-id> <decision> --trigger <name>
#                   [--finding <id>] [--summary <text>]
#   record-review <run-state> --bytes-before <n> --bytes-after <n>
#                 --merged <n> --routed <n> --dropped <n>
#                                    escalation-decider T1: each appends ONE
#                                    JSONL record to a THIRD log,
#                                    .agents/metrics/decisions/<session>.jsonl
#                                    — a new sibling of the driver-mode log,
#                                    and BOTH halves of that placement are
#                                    load-bearing. Not
#                                    .agents/loop/<run_id>/, which begin-run
#                                    prunes to the current run plus one, so a
#                                    decision would stop being auditable two
#                                    runs later. Not
#                                    .agents/metrics/outcomes/, where
#                                    _rs_open_packets reads ANY record that
#                                    carries a `packet` and a non-empty `kind`
#                                    as a packet START (see its own `if (kind
#                                    != "")` branch): a decision record there
#                                    would REOPEN a packet that had already
#                                    ended, sweep-open would then close it as
#                                    `interrupted`, and run-digest would
#                                    report that outcome for a packet nothing
#                                    interrupted. Both records DO carry
#                                    `kind` — `decision`/`review` — which is
#                                    safe only because of where they are
#                                    written; that is the whole reason the log
#                                    is separate rather than a new field shape
#                                    in an existing one.
#                                    <decision> is one of the five the
#                                    escalation decider returns —
#                                    reorder append-task retry ask-operator
#                                    hand-off-feature — never a reviewer
#                                    verdict (pass/fix/escalate are what ROUTE
#                                    to the decider, not what it decides), and
#                                    anything else is refused.
#                                    Record shapes (fixed field set, absent
#                                    optional values written as empty strings
#                                    so a reader using the same plain
#                                    index()/substr() extraction as every
#                                    other log here sees one shape):
#                                      {"ts":…,"session":…,"run_id":…,
#                                       "kind":"decision","packet":…,
#                                       "decision":…,"trigger":…,
#                                       "finding":…,"summary":…}
#                                      {"ts":…,"session":…,"run_id":…,
#                                       "kind":"review","bytes_before":…,
#                                       "bytes_after":…,"merged":…,
#                                       "routed":…,"dropped":…}
#                                    `run_id` is stamped from run-state (which
#                                    is why both take it) because this log is
#                                    SESSION-keyed and a session outlives a
#                                    run: without it a reader could not tell
#                                    this run's decisions from the previous
#                                    run's. Both die when run-state has no
#                                    run_id, same as route/handoff/run-digest.
#                                    record-review's five values are each a
#                                    non-negative integer or the literal
#                                    `unmeasured`, written as JSON STRINGS
#                                    (the same `<n|unknown>`-as-a-string shape
#                                    driver-mode's `threshold` already uses):
#                                    a count that could not be read must be
#                                    reportable as unmeasured rather than as
#                                    0, which would read as a measurement.
#                                    Argument validation dies BEFORE anything
#                                    is written; a write failure is NON-fatal
#                                    and prints RECORDED=no + REASON=, exactly
#                                    as record-outcome/record-start do.
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
#                                    specifically. (Whether a plugin can
#                                    supply a default without overriding a
#                                    repo/operator value was since answered
#                                    NO on 2.1.278 — ADR 0028's 2026-09-21
#                                    amendment — so this reader reads no
#                                    plugin carrier.) "operator" here
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
#                                    field survives so a later carrier, if one
#                                    is ever adopted, can report APPLIED=yes
#                                    without a format change. NO SESSION BOUNDARY TO CONFIRM:
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
#   review-due                       escalation-decider T2: prints
#                                    NON_GREEN=<n|unmeasured>,
#                                    BEGINNINGS=<n|unmeasured>,
#                                    EVERY_NON_GREEN=<n|unmeasured>,
#                                    EVERY_BEGINNINGS=<n|unmeasured> and
#                                    DUE=yes|no. Pure reader, no side effect,
#                                    always exits 0 — the CALLER (run-loop,
#                                    between packets and never while one is
#                                    open) is what dispatches the decider for
#                                    a periodic review when DUE=yes. Takes no
#                                    arguments: unlike periodic-pause it
#                                    counts across EVERY session's log, so
#                                    there is no session to name, and an
#                                    argument is refused rather than ignored.
#                                    NON_GREEN counts outcome records whose
#                                    `outcome` is one of the five NON-green
#                                    endings (failed, rolled-back, blocked,
#                                    abandoned, interrupted — matched by
#                                    value, never as "not green", so an
#                                    outcome this file does not know cannot
#                                    silently become an ending). BEGINNINGS
#                                    counts `kind: start` records ONLY — a
#                                    `kind: continue` is a continuation of a
#                                    packet that already began and must not
#                                    raise the count, or a packet retried
#                                    three times would read as four
#                                    beginnings. Both are counted in
#                                    .agents/metrics/outcomes/*.jsonl across
#                                    every session (a packet can begin in one
#                                    session and end in another), at or after
#                                    the LATEST `kind: review` record in
#                                    .agents/metrics/decisions/*.jsonl — so
#                                    the count resets at a RECORDED review and
#                                    at nothing else. record-review is written
#                                    by the decider after it returns its
#                                    status line, so a review cut short by a
#                                    crash leaves no record, the count does
#                                    not reset, and the review runs again at
#                                    the next boundary — exactly what the PRD
#                                    asks for, with no separate liveness
#                                    field. With no review record anywhere,
#                                    counting starts at the repo's FIRST
#                                    `kind: start` record (and, when the log
#                                    holds no start record at all, at the
#                                    whole log — a legacy log of endings with
#                                    no beginnings errs toward running a
#                                    review, never toward suppressing one).
#                                    Comparison is by PARSED time
#                                    (_rs_ts_key), never a raw string compare
#                                    — the same sub-second-vs-whole-second
#                                    trap sweep-open guards against.
#                                    EVERY_NON_GREEN/EVERY_BEGINNINGS come
#                                    from `review_after_non_green_endings`
#                                    (2) and `review_after_beginnings` (10) in
#                                    .agents/project-overrides.yaml, token-
#                                    scanned in the _rs_packet_attempts_limit
#                                    shape (a trailing comment cannot defeat
#                                    the scan and `'2'` is honoured rather
#                                    than read as missing), each falling back
#                                    to its default when the key is missing,
#                                    invalid or 0 — 0 would fire a review at
#                                    every boundary forever, which is a typo,
#                                    not a policy.
#                                    UNMEASURED IS NOT 0, and that is the
#                                    whole point of the enum: 0 reads as
#                                    "nothing has happened since the last
#                                    review" and would suppress every review
#                                    for the rest of the run. So a count that
#                                    could not be READ (not a git repo, or
#                                    either log directory present but
#                                    unreadable) prints `unmeasured`, a
#                                    threshold that could not be read (not a
#                                    git repo, or an overrides file present
#                                    but unreadable) prints `unmeasured`, and
#                                    any `unmeasured` at all forces DUE=yes —
#                                    a review that cannot be scheduled from
#                                    evidence is run. An ABSENT log directory
#                                    or an absent overrides file is not
#                                    unmeasured: absence is an answer (no
#                                    records, hence 0; no override, hence the
#                                    default).
#   reorder-pending <run-state> <id[,id...]>
#                                    escalation-decider T3: replaces
#                                    backlog.pending with exactly the given
#                                    order, through the same validated
#                                    whole-file `write` every other block
#                                    rewrite here goes through. NEVER `set`:
#                                    `pending` is nested under `backlog:`,
#                                    which `set` refuses (_set_target_shape's
#                                    `nested-only`) precisely because appending
#                                    it at column 0 creates a second `pending:`
#                                    no reader uses — two sources of truth at
#                                    exit 0.
#                                    Prints REORDERED=yes|no, PENDING=<the new
#                                    order>, ADDED=<ids not previously pending>
#                                    and REMOVED=<ids dropped from it> — a
#                                    fixed field set, so a reader sees one
#                                    shape whether or not the order changed.
#                                    REORDERED=no means the requested order was
#                                    already on disk and nothing was written.
#                                    Refuses (leaving the file byte-identical,
#                                    since every check runs before the write):
#                                    an empty list, a repeated id — refused,
#                                    not de-duplicated, or the surviving order
#                                    is not the one asked for — an id outside
#                                    [a-zA-Z0-9._-], a file with no `pending:`
#                                    key or with more than one, a `pending:`
#                                    carrying a value on its own line (a flow
#                                    list), and any line inside the block that
#                                    is not a `- <id>` item. The cursor, the
#                                    findings index and every other key are
#                                    outside the rewritten span and are copied
#                                    through byte-for-byte.
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
#                                        PLUS, since escalation-decider T7,
#                                        one `decision\t\treview-routing` per
#                                        routing a periodic review made (see
#                                        the `review` line below). Its id
#                                        field is EMPTY, and deliberately: a
#                                        review routes a FINDING, not a
#                                        packet, so there is no packet id to
#                                        name and a renderer joining decision
#                                        lines to packet lines by id must not
#                                        mis-join one.
#                                        Since T16 that line is
#                                        `decision\t\treview-routing\t<finding>
#                                        \t<summary>`: the routed finding's id
#                                        and the summary the review wrote
#                                        (it opens `review:` and names every
#                                        packet the finding names), from the
#                                        review's own record-decision records
#                                        -- this run's append-task/hand-off-
#                                        feature decision records whose
#                                        summary is empty or opens `review:`,
#                                        timed after the previous review and
#                                        at or before this one, the latest
#                                        <routed> of them. A record with no
#                                        summary gives an empty summary field;
#                                        a routing with no record found gives
#                                        both fields empty. Neither is ever
#                                        filled from another record. The
#                                        line COUNT still comes from the
#                                        review's `routed`, never from the
#                                        records.
#                                      review\t<merged>\t<routed>\t<dropped>
#                                            \t<bytes_before>\t<bytes_after>
#                                        escalation-decider T7: one per
#                                        `"kind":"review"` record in
#                                        .agents/metrics/decisions/*.jsonl
#                                        (EVERY session's log -- a run spans
#                                        sessions) whose `run_id` is THIS
#                                        run's. The run_id filter is what that
#                                        log's run_id field exists for: it is
#                                        session-keyed and a session outlives
#                                        a run, so without it a resumed run
#                                        would report the previous run's
#                                        reviews. --since-scoped exactly as
#                                        the decision lines above are, and the
#                                        review-routing decision lines a
#                                        review produces are scoped WITH it
#                                        (they come from the same record).
#                                        Each value is carried VERBATIM from
#                                        the record, including the literal
#                                        `unmeasured` a count that could not
#                                        be read is written as -- never
#                                        rewritten to 0, which would read as a
#                                        measurement.
#                                        ONLY the review records are read from
#                                        that log; the decision records in it
#                                        are NOT a source of digest `decision`
#                                        lines. Every packet decision already
#                                        produced a routing.jsonl record --
#                                        the driver routed the token -- so
#                                        reading both would report each packet
#                                        decision TWICE and double the stop
#                                        report's 🔀 tally. The decider's own
#                                        records are for the audit and the
#                                        success metric, which read the log
#                                        directly. (T16 reads them for ONE
#                                        thing only: the names on a
#                                        review-routing line. They still
#                                        produce no line of their own.)
#                                        A `routed` value that is not a run of
#                                        digits (`unmeasured`, or anything a
#                                        hand-edit left behind) yields NO
#                                        review-routing decision lines and so
#                                        adds nothing to run-tally's
#                                        DECISIONS: the number of routings is
#                                        unknown, and inventing lines for it
#                                        would report a guess. The `review`
#                                        line still carries `unmeasured`, so
#                                        the renderer states it rather than
#                                        the tally implying zero.
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
#   run-tally <run-state>            report-render-conformance T1: the four
#                                    digest-derived stop-report tally figures,
#                                    counted from cmd_run_digest's OWN lines
#                                    for the WHOLE run (no --since -- the
#                                    dedup needs every decision the run
#                                    recorded). Prints exactly, in the fixed
#                                    tally order (templates/report-
#                                    templates.md):
#                                      SHIPPED=<n>     packet lines reading
#                                                      green
#                                      FAILED=<n>      packet lines reading
#                                                      failed or rolled-back
#                                      UNFINISHED=<n>  packet lines reading
#                                                      blocked, interrupted,
#                                                      abandoned, open or
#                                                      paused
#                                      DECISIONS=<n>   one per handoff-feature
#                                                      line, plus one per
#                                                      decision line whose
#                                                      token is hand-off-
#                                                      feature, plus one per
#                                                      ask-operator decision
#                                                      STILL AWAITING an
#                                                      answer, EXCEPT one
#                                                      whose id already
#                                                      carries a handoff-
#                                                      feature line (one
#                                                      question, never
#                                                      tallied twice), plus
#                                                      one per routing.jsonl
#                                                      record whose token is
#                                                      retry and whose action
#                                                      is stop (past its
#                                                      attempt limit) that is
#                                                      STILL AWAITING an
#                                                      answer, never hand-off-
#                                                      excluded (a distinct
#                                                      question).
#                                                      Awaiting: no record
#                                                      for the same packet
#                                                      in any session's
#                                                      outcomes log that is
#                                                      a start, a continue
#                                                      or an abandoned
#                                                      outcome with a
#                                                      _rs_ts_key STRICTLY
#                                                      greater than the
#                                                      question's routing.
#                                                      jsonl ts (a tie does
#                                                      not answer; a blocked
#                                                      outcome -- the stop
#                                                      /gaffer:pause records
#                                                      -- never answers),
#                                                      plus one per review-
#                                                      routing decision line
#                                                      (escalation-decider
#                                                      T7): a periodic
#                                                      review's routings
#                                                      count as decisions,
#                                                      while its merges and
#                                                      drops stay counts on
#                                                      the `review` line and
#                                                      are counted toward no
#                                                      figure here. A review
#                                                      routing is never
#                                                      liveness-filtered or
#                                                      hand-off-excluded: it
#                                                      names no packet, so
#                                                      there is nothing for
#                                                      either rule to join on.
#                                    No queued figure: that is the pending
#                                    count `summary` reports, not a digest
#                                    fact. Dies exactly where run-digest dies.
#   prune-questions <run-state>     answered-question-expiry T2: drop entries
#                                    from `pending_questions:` that the same
#                                    liveness rule above (_rs_unanswered_
#                                    questions) reports as answered. Parses
#                                    ONLY the block-entry shape templates/run-
#                                    state.yaml documents (`  - id: ...` plus
#                                    indented `packet:`/`asked_at:` siblings,
#                                    quotes stripped symmetrically as `cmd_get`
#                                    does); a list in any other shape, or no
#                                    `pending_questions:` block at all, is left
#                                    byte-untouched. An entry with no `packet:`
#                                    or no `asked_at:`, or an empty or
#                                    unparseable value in either, is ALWAYS
#                                    kept (fails toward over-reporting). Writes through
#                                    `cmd_write`, carrying every other key
#                                    (including `findings:`) through byte-
#                                    identical; when nothing is dropped, the
#                                    file is not written at all. Prints
#                                    PRUNED=yes|no, DROPPED=<n> and, when
#                                    PRUNED=yes, KEPT=<n>.
#
# Exit codes: 0 = success (reconcile always 0 when it can decide), non-zero =
# usage / unreadable-file / unreadable-work-tree error (stderr explains).
# =============================================================================

set -euo pipefail

# Commit-message trailer that ties a packet commit to its packet id. Kept here so
# the writer (run-loop / pause) and the reader (reconcile) agree on one string.
PACKET_TRAILER_PREFIX="[orch packet:"

# --- where the plugin's OWN files live, relative to THIS script ---------------
# Derived the same way scripts/routing.sh derives its agents/ lookup. It must be
# script-relative and not cwd-relative: `handoff` is run from wherever the
# driving session happens to be (the consumer repo's checkout, a subdirectory of
# it), and resolving a plugin template against the CALLER's cwd would find
# nothing there and refuse every handoff outside the plugin root.
HERE="$(cd "$(dirname "$0")" && pwd)"

# The verification contract appended to EVERY handoff (handoff-verification-
# contract T2). ORCH_HANDOFF_REQUIRED redirects WHERE the block is read from,
# for fixtures; it is an override, never an omission path — an unreadable or
# whitespace-only template refuses the handoff rather than writing one without
# the block.
HANDOFF_REQUIRED_TEMPLATE="${ORCH_HANDOFF_REQUIRED:-${HERE}/../templates/handoff-required.md}"

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
  # single-quoted encoding `set` writes, and also strips the legacy
  # double-quoted shape an older tool or a hand edit can leave behind -- a
  # no-op on a bare value, so a legacy unquoted value round-trips exactly as
  # before and no run-state has to be migrated first. The trailing
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
#   THE one decode rule, in its shell expression (_YAML_AWK_DECODE below is the
#   same rule in awk, for the read sites that run inside an awk pass and cannot
#   shell out per record). Three branches, tried in this order:
#
#     '...'   the inverse of _yaml_quote: strip the wrapping pair and un-double
#             `''` back to `'`. This is what cmd_set and cmd_add_finding write.
#     "..."   LEGACY only -- never written by this file, but left behind by an
#             older tool or a hand edit, and stripped VERBATIM (no escape
#             processing) because that is what the awk readers this rule
#             replaces have always done with it. Decoding `\n`/`\"` the way a
#             real YAML double-quoted scalar defines them would change what
#             those on-disk bytes mean today, which is a different decision
#             than unifying the rule; it is not made here.
#     bare    everything else passes through UNCHANGED -- everything cmd_write
#             produces (it validates structure, not per-value encoding), and
#             every value that happened to round-trip bare before the encoder
#             existed. That direction matters more than the forward one: every
#             consumer repo already has a run-state on disk and must keep
#             reading correctly, with no flag day.
#
#   A value that is only one character long cannot be a wrapped pair: the two
#   quotes would have to be the same byte. Both shell patterns below already
#   require two, and _YAML_AWK_DECODE's `n >= 2` says it explicitly.
_yaml_decode_value() {
  local body="$1"
  case "$1" in
    \'*\')
      body="${body#\'}"; body="${body%\'}"
      printf '%s' "$body" | sed "s/''/'/g"
      ;;
    \"*\")
      body="${body#\"}"; body="${body%\"}"
      printf '%s' "$body"
      ;;
    *)
      printf '%s' "$1" ;;
  esac
}

# _YAML_AWK_DECODE -- the SAME rule as _yaml_decode_value, expressed once as awk
# source text and PREPENDED to each awk program that needs it:
#
#   awk -v s=... "$_YAML_AWK_DECODE"'
#     ... { $0 = rs_decode($0) }
#   ' "$f"
#
# Shared TEXT rather than a shared process, deliberately: the readers that need
# it (cmd_trim_note's first-line unwrap, and the findings/lanes parsers) run
# inside a single awk pass over the file, and a shell-out per record to
# _yaml_decode_value would put a fork on every line of the loop's own state file
# on every read. Two expressions of one rule are what remain after this -- shell
# and awk -- and the decoder fixture table in scripts/test-runstate.sh is what
# keeps them honest, by driving both over the same values and demanding the same
# answer. That table, not a comment, is the anti-drift mechanism.
#
# `\047` is a single quote: the text below is itself a single-quoted shell
# string, so a literal `'` cannot appear in it, and an octal escape in an awk
# string literal is POSIX. gsub's first argument is a STRING here, converted to
# a regex by awk -- `''` carries no metacharacter, so there is nothing to quote.
_YAML_AWK_DECODE='
function rs_decode(v,   n) {
  n = length(v)
  if (n >= 2 && substr(v, 1, 1) == "\047" && substr(v, n, 1) == "\047") {
    v = substr(v, 2, n - 2)
    gsub("\047\047", "\047", v)
    return v
  }
  if (n >= 2 && substr(v, 1, 1) == "\"" && substr(v, n, 1) == "\"")
    return substr(v, 2, n - 2)
  return v
}
'

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
#
# --- what shape is the TARGET in? (runstate-write-integrity-gaps T1) ---------
# `set` addresses ONE thing: a flat scalar on a column-0 `key:` line. Two target
# shapes are outside that reach and, until this task, both were written anyway:
#
#   nested-only     the key exists but ONLY at an indentation greater than zero
#                   -- `cursor` under `backlog:` is the live example. The old
#                   `grep -qE "^key:"` found nothing, fell through to the append
#                   branch, and created a SECOND, column-0 `cursor:` while
#                   `cmd_cursor` kept reading the nested one. Exit 0, two
#                   sources of truth, no signal.
#   column0-mapping the key IS at column 0 but heads a nested mapping or list
#                   (`backlog:`, `findings:`, `pending_questions:`). Replacing
#                   that header with a scalar strands its children as orphaned
#                   indentation -- and unlike the block-scalar case above there
#                   is NO body boundary to reuse: a block header's remainder is
#                   `|`/`>`, which says "a body follows and here is where it
#                   ends"; a mapping header's remainder is EMPTY and says
#                   nothing at all. That is why T10 could handle its case and
#                   this one is refused rather than folded into it.
#
# REFUSAL, NOT ADDRESSING, and deliberately so: writing YAML path addressing in
# POSIX shell -- no jq, no parser, against the loop's only durable state -- is a
# large new correctness surface bought to remove a trap that a loud non-zero exit
# closes just as well. This file already has the cautionary precedent one
# function up: the plain-scalar allowlist in _yaml_encode_value was built and
# deleted the same day, because it made a claim about every FUTURE value and was
# wrong twice in one afternoon. A refusal makes a claim about none.
#
# The third shape, ABSENT, is explicitly NOT refused: `claim-driver` creates all
# four of its `driver_*` keys by appending them at column 0 against a fresh
# run-state, and `begin-run` mints `run_id` the same way. "Refuse what is not
# already there" would break both -- absence and nesting are different answers.
#
# _set_target_shape <file> <key> -- prints exactly one of:
#   absent | column0-scalar | column0-mapping | nested-only
# Literal prefix matching via index() throughout, never a regex built from the
# key, so a key carrying a regex metacharacter cannot widen its own match. A
# `- ` list-item key (`  - id: x`) is NOT nested-only for key `id`: it is an
# element of a sequence, not a child mapping key, and `set` was never going to
# address it either way.
_set_target_shape() {
  KEY="$2" awk '
    BEGIN { k = ENVIRON["KEY"] ":"; shape = "absent"; nested = 0; want = 0 }
    # Looking for the first non-blank line AFTER a column-0 header whose
    # remainder was empty: indented => that header owns a nested body.
    want == 1 {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]/) shape = "column0-mapping"
      exit
    }
    shape == "absent" && index($0, k) == 1 {
      rest = substr($0, length(k) + 1)
      sub(/^[[:space:]]+/, "", rest)
      shape = "column0-scalar"
      if (rest == "") { want = 1; next }     # empty remainder: look below
      exit                                   # a value (incl. a block indicator)
    }
    {
      if ($0 ~ /^[[:space:]]/) {
        t = $0; sub(/^[[:space:]]+/, "", t)
        if (index(t, k) == 1) nested = 1
      }
    }
    END { if (shape == "absent" && nested == 1) shape = "nested-only"; print shape }
  ' "$1"
}

cmd_set() {
  local f="${1:-}" key="${2:-}" val="${3:-}"
  [ -n "$f" ] && [ -n "$key" ] || die "usage: set <file> <key> <value>"
  need_file "$f"
  # Decided BEFORE the temp file exists, so a refusal leaves the target (and
  # this directory) byte-identical -- the whole point of refusing rather than
  # discovering the problem halfway through a rewrite.
  local shape; shape="$(_set_target_shape "$f" "$key")"
  case "$shape" in
    nested-only)
      die "set refused: '${key}' exists only INSIDE a nested block in '${f}', not as a column-0 key -- \`set\` writes flat top-level scalars only, and appending it at column 0 would create a second '${key}' that readers do not use. Edit the nested value with \`write\` (whole file on stdin) instead." ;;
    column0-mapping)
      die "set refused: '${key}' is a column-0 key whose value is a nested mapping or list in '${f}' -- replacing its header with a scalar would strand the indented lines below it. Unlike a block scalar, a mapping header carries no body boundary to consume. Rewrite the whole file with \`write\` (contents on stdin) instead." ;;
  esac
  local dir tmp enc; dir="$(dirname "$f")"
  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" || die "cannot create temp file in ${dir}"
  enc="$(_yaml_encode_value "$val")"
  if [ "$shape" = column0-scalar ]; then
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
    # The unwrap is rs_decode from _YAML_AWK_DECODE (defined with
    # _yaml_decode_value, above cmd_set) -- the one decode rule, not a copy of
    # it maintained here. It runs AFTER the block-indicator test, so a note that
    # is already a block scalar is skipped before any unwrap is attempted: its
    # first line is `|-`, not a value, and rs_decode has no business seeing it.
    awk -v s="$start" -v e="$end" -v m="$max" "$_YAML_AWK_DECODE"'
      NR<s || NR>e { next }
      NR==s { sub(/^note:[[:space:]]*/, "")
              if ($0 ~ /^[|>][-+]?[0-9]*[[:space:]]*$/) next   # was already a block
              $0 = rs_decode($0) }
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
# NO PIPE, BY HERE-STRING (next-state-reporting-integrity T2): no bound can be
# written down for this writer, so the pipe is removed rather than recorded.
# The reading behind that one line: the only caller is `findings --stale`, over
# the `--finished` set (every finished packet the caller knows of) and the
# cursor-plus-`pending` set (the remaining backlog) — neither has any ceiling, so
# there is no maximum output size at which a piped `grep -q` could be argued
# unable to misreport. Under `pipefail` a `printf … | grep -q` here would return
# the printf's SIGPIPE (141) instead of grep's successful match, and the wrong
# answer reaches a caller: `--stale` reads a finished packet as `unknown` and
# withholds an expiry. A here-string is not a pipeline in the shell's sense —
# bash finishes supplying the value before grep can act on it — so `pipefail`
# has no second status to report and grep's answer is the only one.
_id_in_set() { grep -qxF "$1" <<< "$2"; }

# Restore a set-aside finding body on a failed drop-finding — best-effort, never
# fails the caller (the caller is already mid-`die`).
_restore_aside() {
  [ -n "${1:-}" ] && [ -f "${1:-}" ] && mv -f "$1" "$2" 2>/dev/null
  return 0
}

# The `findings:` block — its key line's contents through the line before the
# next column-0 key (or EOF). ONE copy of that bound: cmd_add_finding's
# duplicate-id check, cmd_drop_finding's not-found check and cmd_merge_findings'
# two existence checks all read it, so a change to how the block is delimited
# reaches every one of them rather than three of four. Always exits 0 (a
# run-state with no findings block is an empty block, not an error), which also
# keeps a caller's `x="$(_findings_block …)"` from tripping `set -e`.
_findings_block() {
  awk '
    /^findings:[[:space:]]*$/ { inf=1; next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inf=0 }
    inf { print }' "$1" 2>/dev/null || true
}

# `[a, b]` -> `a, b` — the inverse of the YAML flow sequence add-finding writes
# for `packets:`. Only the brackets come off; splitting, validating and
# de-duplicating stay _normalize_id_list's job, which is where every other
# packet list in this file is normalized.
_strip_flow() { printf '%s' "$1" | sed 's/^\[//; s/\]$//'; }

# _finding_field <file> <id> <key> — the RAW (still-encoded) value of <key>
# inside the findings entry whose `  - id:` line matches <id> exactly, or
# nothing when the entry or the key is absent. Raw, not decoded: `packets:` and
# `file:` are written bare and are wanted verbatim, while `summary:` is
# single-quoted and its caller runs it through _yaml_decode_value — the one
# decode rule (runstate-write-integrity-gaps T4), never a second one here.
#
# Field-at-a-time rather than a TSV row from _findings_default because a
# summary may legitimately contain a tab (nothing collapses one — only newlines
# are collapsed), and one tab inside a value shifts every later TSV field by
# one, silently returning another entry's `file:` path as its `packets:`.
_finding_field() {
  local f="$1" id="$2" key="$3"
  ID="$id" KEY="$key" awk '
    BEGIN { target = "  - id: " ENVIRON["ID"]; pfx = ENVIRON["KEY"] ":" }
    /^findings:[[:space:]]*$/ { inf = 1; next }
    inf && /^[A-Za-z_][A-Za-z0-9_]*:/ { inf = 0; inentry = 0 }
    inf && /^[[:space:]]*- id:/ { inentry = ($0 == target) ? 1 : 0; next }
    inentry {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      # LITERAL prefix match (index), not a regex: every key passed in is a
      # literal from this file, but the same rule that made the duplicate-id
      # check use grep -F applies — a metacharacter must never widen a match.
      if (index(line, pfx) == 1) {
        v = substr(line, length(pfx) + 1)
        sub(/^[[:space:]]+/, "", v)
        print v
        exit
      }
    }
  ' "$f" 2>/dev/null || true
}

# --- cap the index summary at a CHARACTER count (escalation-decider T6) -------
# The index sits in the standing context of every packet (ADR 0022), so its size
# is the whole reason the body/index split exists — and nothing bounded the one
# free-text field in it. The cap is on the ENTRY only: the full text still goes
# to the body file, and the call is NEVER refused for length, because refusing an
# agent that has something to record mid-loop is how that text ends up nowhere.
#
# CHARACTERS, NOT BYTES, on BOTH halves of the decision, and that is the whole
# subtlety here:
#   - the threshold: 160 characters of 3-byte characters is 480 bytes, and a
#     byte threshold would cap a non-English summary at a third of the budget an
#     English one gets while looking like one rule;
#   - the cut: severing a multi-byte character mid-sequence leaves a byte
#     sequence that is not UTF-8 at all, headed for the loop's only durable
#     state. What that costs was measured, not assumed (a deliberately
#     byte-counting version of this function, run under the sweep): on macOS the
#     `sed "s/'/''/g"` in _yaml_quote below refuses the illegal byte sequence
#     outright, so the entry lands as `summary: ''` — the file parses and the
#     WHOLE summary is gone. Where sed passes those bytes through instead, the
#     non-UTF-8 reaches the file and the cost lands on every OTHER key in it.
# So this counts UTF-8 character STARTS (every byte outside the 0x80-0xBF
# continuation range) and cuts only at one. LC_ALL=C is what makes that
# well-defined rather than host-dependent: awk's length()/substr() are
# byte-oriented in the C locale everywhere, while under a UTF-8 locale gawk
# would already be counting characters and the awk macOS ships would not — the
# same summary would then cut in two different places on two machines. Forcing
# the byte view and doing the character arithmetic here is the one reading that
# is the same on all of them.
#
# 160 is the PRD's stated STARTING value, with tuning deferred until a review's
# recorded index size says what it should be — so it is a named constant, not an
# option nothing sets and nothing tests.
FINDING_SUMMARY_MAX_CHARS=160
# One character, so the cap spends 159 of its 160 on the summary itself.
FINDING_SUMMARY_MARK='…'

# _cap_chars <already-collapsed value> <max chars> <mark>
#   Prints <value> unchanged when it is at most <max> CHARACTERS; otherwise the
#   longest whole-character prefix that leaves room for <mark>, with <mark>
#   appended, so the result is at most <max> characters. Never fails and never
#   refuses — the caller detects "it was shortened" by comparing the result with
#   what it passed in, which is also the only definition that cannot drift from
#   what was actually written.
_cap_chars() {
  V="$1" MAXC="$2" MARK="$3" LC_ALL=C awk '
    function nchars(t,   i, ln, c) {
      ln = length(t); c = 0
      for (i = 1; i <= ln; i++) if (index(CONT, substr(t, i, 1)) == 0) c++
      return c
    }
    BEGIN {
      # Every UTF-8 continuation byte, built BY VALUE: no literal high byte has
      # to survive this file being read, edited, diffed or re-encoded elsewhere.
      CONT = ""
      for (j = 128; j <= 191; j++) CONT = CONT sprintf("%c", j)
      s = ENVIRON["V"]; max = ENVIRON["MAXC"] + 0; mark = ENVIRON["MARK"]
      if (nchars(s) <= max) { printf "%s", s; exit }
      keep = max - nchars(mark)
      if (keep < 0) keep = 0
      n = length(s); c = 0; cut = n
      for (i = 1; i <= n; i++) {
        if (index(CONT, substr(s, i, 1)) != 0) continue   # mid-character byte
        if (c == keep) { cut = i - 1; break }             # the cut is a BOUNDARY
        c++
      }
      printf "%s%s", substr(s, 1, cut), mark
    }
  '
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

  # Cap what goes in the INDEX (escalation-decider T6), counted AFTER the
  # collapse above -- a newline that became a space is a character the reader
  # pays for like any other. The full text is kept and written to the body
  # below, so nothing the cap removes is discarded; $summary from here on is
  # what the entry carries, $full_summary is what the body carries. Compared
  # rather than flagged from inside _cap_chars: "the entry differs from what
  # the caller passed" is the same fact the reader would derive, so the two
  # cannot disagree.
  local full_summary="$summary" capped=0
  summary="$(_cap_chars "$summary" "$FINDING_SUMMARY_MAX_CHARS" "$FINDING_SUMMARY_MARK")"
  [ "$summary" = "$full_summary" ] || capped=1

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
  in_findings="$(_findings_block "$f")"
  # NO PIPE, BY HERE-STRING (next-state-reporting-integrity T2): no bound can be
  # written down for this writer, so the pipe is removed rather than recorded.
  # The reading behind that one line: the writer emits the ENTIRE `findings:`
  # block in one go, and `findings --stale` already treats
  # ORCH_FINDINGS_INDEX_MAX_BYTES=4096 — exactly PIPE_BUF, the size up to which a
  # single write is atomic — as the index's EXPECTED ceiling, so the block is
  # designed to reach the size at which the single-write argument stops holding.
  # Piped under `pipefail`, a `grep -q` that matched early would close the read
  # end, the writer would take SIGPIPE, and the 141 would be reported instead of
  # the match — admitting a SECOND entry under an existing id.
  if grep -qxF "  - id: ${id}" <<< "$in_findings"; then
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
  #
  # A CAPPED summary forces a body whether or not --body was passed, and it is
  # the same body, in the same place, pointed at the same way — the cap's whole
  # licence is that the removed text went somewhere, and "opt-in" cannot apply
  # to the only copy of it. The `> ` line carries $full_summary in BOTH cases:
  # an uncapped body repeating the entry verbatim is what it has always done,
  # and a capped one has to hold what the entry no longer does.
  local has_body=0
  if [ "$want_body" = 1 ] || [ "$capped" = 1 ]; then
    mkdir -p "${dir}/findings" 2>/dev/null || die "cannot create ${dir}/findings"
    if [ ! -f "$body" ]; then
      { printf '# %s\n\n' "$id"
        printf '> %s\n\n' "$full_summary"
        printf -- '- recorded: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '## What was found\n\n<the detail that did NOT belong in run-state>\n\n'
        printf '## Why it matters / what to do about it\n\n<so a later packet can act on it>\n\n'
        printf '## Scope\n\n<the evidence tying this finding to the packet(s) already recorded in the index entry above>\n'
      } > "$body" || die "cannot write ${body}"
    elif [ "$capped" = 1 ]; then
      # A body already on disk under this id (a hand-written one, or one left by
      # a `write` that replaced run-state without its findings block) is never
      # clobbered — but it is also not an excuse to drop the capped text, which
      # would be the one case where the cap silently loses what it removed. So
      # append, the way merge-findings appends, leading newline and all, since a
      # body not ending in one would run its last line into the heading.
      { if [ -n "$(tail -c 1 "$body")" ]; then printf '\n'; fi
        printf '\n## full summary (%s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '> %s\n' "$full_summary"
      } >> "$body" || die "cannot append to ${body}"
    fi
    has_body=1
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
    if [ "$has_body" = 1 ]; then printf '    file: %s' "$rel"; fi
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
  # Reported, not silent: a caller whose text was shortened has to be able to
  # tell that from one whose text was not, and an optional key (like FILE below,
  # and REASON above) is how this command already says "and this happened too".
  [ "$capped" = 1 ] && out="${out}
CAPPED=yes"
  [ "$has_body" = 1 ] && out="${out}
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
  in_findings="$(_findings_block "$f")"
  # NO PIPE, BY HERE-STRING (next-state-reporting-integrity T2): no bound can be
  # written down for this writer, so the pipe is removed rather than recorded.
  # Same reading as cmd_add_finding's duplicate check above — the writer emits the
  # whole `findings:` block, whose own expected ceiling (4096 = PIPE_BUF) is the
  # size at which the single-write argument stops holding. The NEGATION makes the
  # wrong answer worse here: a SIGPIPE 141 reported instead of grep's match turns
  # a found entry into `not-found` on an entry that exists.
  if ! grep -qxF "  - id: ${id}" <<< "$in_findings"; then
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

# --- merge two findings: one entry, both packet lists, NO TEXT LOST -----------
# ADR 0024 as amended by escalation-decider: a periodic review may merge two
# entries that say the same thing, and the whole licence for doing that inside
# the loop is that the merge is LOSSLESS. Whether two findings really are
# duplicates is a judgment nothing here can check (the PRD says so outright);
# what this command guarantees is that being wrong costs a reader some noise in
# one body file, never a sentence that no longer exists anywhere.
#
# So "merge" is three things, in this order, and the order is the contract:
#   1. the surviving entry's `packets:` becomes the UNION of both lists, so the
#      merged entry expires only once every packet EITHER finding named has run
#      (`findings --stale` reads that list; a union that dropped ids would
#      expire the survivor early, which is the failure ADR 0024 exists to stop),
#   2. the removed entry's SUMMARY and the WHOLE of its body are appended to the
#      survivor's body file — created here, with the entry's `file:` pointer,
#      when the survivor had none, because a summary with nowhere to go is text
#      lost just as surely as a deleted body,
#   3. and ONLY THEN is the removed entry dropped, with its body, both-or-
#      neither on exactly drop-finding's sequence: set aside -> build -> swap ->
#      delete the set-aside. Any failure in the middle restores both bodies and
#      dies, leaving the two entries and both bodies exactly as they were.
#
# The step that matters most is 2-before-3. Copying only the summary and then
# deleting the body reads as a complete merge from every count anyone looks at
# — one entry fewer in the index, both packet ids present, a body file that
# grew — while the removed body's detail is simply gone. That is the one
# failure a merge can have that nothing downstream can notice, which is why the
# sweep case asserts EVERY LINE of the removed body, not just its summary.
cmd_merge_findings() {
  local f="${1:-}" sid="${2:-}" rid="${3:-}"
  [ "$#" -eq 3 ] && [ -n "$f" ] && [ -n "$sid" ] && [ -n "$rid" ] \
    || die "usage: merge-findings <run-state-file> <survivor-id> <removed-id>"
  need_file "$f"
  case "$sid" in *[!a-zA-Z0-9._-]*) die "finding id must be [a-zA-Z0-9._-] (it is a filename)" ;; esac
  case "$rid" in *[!a-zA-Z0-9._-]*) die "finding id must be [a-zA-Z0-9._-] (it is a filename)" ;; esac
  # Merging an entry into itself is an argument error, not a no-op: step 3 would
  # delete the very body step 2 had just appended to. Refused before anything is
  # read, like every other argument error here.
  [ "$sid" != "$rid" ] \
    || die "survivor and removed must differ (merging '${sid}' into itself would delete the body it just appended to)"

  local in_findings
  in_findings="$(_findings_block "$f")"
  # NO PIPE, BY HERE-STRING (next-state-reporting-integrity T2) — the same
  # reading as cmd_add_finding's and cmd_drop_finding's checks above: the whole
  # findings block is written in one go and is EXPECTED to reach 4096 bytes
  # (PIPE_BUF), so a piped `grep -q` matching early could report the writer's
  # SIGPIPE 141 instead of the match. Negated here as in drop-finding, where the
  # wrong answer is the worse direction: an existing entry read as not-found.
  if ! grep -qxF "  - id: ${sid}" <<< "$in_findings"; then
    printf 'MERGED=no\nREASON=survivor-not-found\nSURVIVOR=%s\nREMOVED=%s\n' "$sid" "$rid"; return 0
  fi
  if ! grep -qxF "  - id: ${rid}" <<< "$in_findings"; then
    printf 'MERGED=no\nREASON=removed-not-found\nSURVIVOR=%s\nREMOVED=%s\n' "$sid" "$rid"; return 0
  fi

  # --- everything the merge needs, read BEFORE anything is written ------------
  local s_pkts r_pkts s_file r_summary s_summary merged_csv packets_flow
  s_pkts="$(_strip_flow "$(_finding_field "$f" "$sid" packets)")"
  r_pkts="$(_strip_flow "$(_finding_field "$f" "$rid" packets)")"
  s_file="$(_finding_field "$f" "$sid" file)"
  r_summary="$(_yaml_decode_value "$(_finding_field "$f" "$rid" summary)")"
  s_summary="$(_yaml_decode_value "$(_finding_field "$f" "$sid" summary)")"
  # Survivor's ids first, then the removed entry's, de-duplicated in first-seen
  # order by the SAME normalizer `--packets` goes through — so a merged list is
  # indistinguishable from one `add-finding` wrote, including its id charset
  # refusal. An entry with no `packets:` at all (a hand-written legacy one;
  # add-finding has always required the flag) contributes nothing and does not
  # fail the merge.
  merged_csv="$(_normalize_id_list "$(printf '%s %s' "$s_pkts" "$r_pkts")")"
  packets_flow="$(printf '%s' "$merged_csv" | sed 's/,/, /g')"

  local dir findingsdir sbody rbody rel add_file="" s_had_body=0 r_had_body=0
  dir="$(dirname "$f")"
  findingsdir="${dir}/findings"
  sbody="${findingsdir}/${sid}.md"
  rbody="${findingsdir}/${rid}.md"
  # Derived from the same `dir` as the body itself, for the reason cmd_add_finding
  # records: a hardcoded `.agents/…` prefix is a dangling index everywhere the
  # run-state does not sit at exactly `.agents/run-state.yaml`.
  rel="$(basename "$dir")/findings/${sid}.md"
  [ -n "$s_file" ] || add_file="$rel"
  [ -f "$sbody" ] && s_had_body=1
  [ -f "$rbody" ] && r_had_body=1
  mkdir -p "$findingsdir" 2>/dev/null || die "cannot create ${findingsdir}"

  # --- 1. set the removed body aside (same-directory rename, atomic) ----------
  local aside_r="" aside_s="" tmpbody="" tmp="" stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$r_had_body" = 1 ]; then
    aside_r="$(mktemp "${findingsdir}/.${rid}.aside.XXXXXX")" || die "cannot create temp file in ${findingsdir}"
    mv -f "$rbody" "$aside_r" || die "cannot set aside ${rbody}"
  fi

  # --- 2. build the merged survivor body ------------------------------------
  tmpbody="$(mktemp "${findingsdir}/.${sid}.merge.XXXXXX")" \
    || { _restore_aside "$aside_r" "$rbody"; die "cannot create temp file in ${findingsdir}"; }
  { if [ "$s_had_body" = 1 ]; then
      cat "$sbody"
      # A body that does not end in a newline would otherwise run its last line
      # into the appended heading.
      if [ -n "$(tail -c 1 "$sbody")" ]; then printf '\n'; fi
    else
      printf '# %s\n\n' "$sid"
      printf '> %s\n\n' "$s_summary"
      printf -- '- recorded: %s\n' "$stamp"
    fi
    printf '\n## merged from %s (%s)\n\n' "$rid" "$stamp"
    printf '> %s\n\n' "$r_summary"
    if [ -n "$aside_r" ]; then cat "$aside_r"; fi
    :
  } > "$tmpbody" \
    || { rm -f "$tmpbody"; _restore_aside "$aside_r" "$rbody"; die "cannot write ${sbody}"; }

  # --- 3. build the updated run-state ---------------------------------------
  # One pass: rewrite the survivor's `packets:` (and add its `file:` when the
  # body was created here), drop the removed entry entirely. A key the survivor
  # does not carry is emitted when the entry ENDS rather than guessed at a
  # position inside it — the same reason cmd_add_finding inserts at the
  # `findings:` key and nowhere else: locating a line that is not there means
  # guessing, and guessing wrong writes into the next entry.
  tmp="$(mktemp "${dir}/.run-state.XXXXXX")" \
    || { rm -f "$tmpbody"; _restore_aside "$aside_r" "$rbody"; die "cannot create temp file in ${dir}"; }
  SID="$sid" RID="$rid" PFLOW="$packets_flow" ADDFILE="$add_file" awk '
    BEGIN {
      starget = "  - id: " ENVIRON["SID"]
      rtarget = "  - id: " ENVIRON["RID"]
      pline   = "    packets: [" ENVIRON["PFLOW"] "]"
      fline   = (ENVIRON["ADDFILE"] == "") ? "" : "    file: " ENVIRON["ADDFILE"]
    }
    function close_survivor() {
      if (!seen_packets) print pline
      if (fline != "" && !seen_file) print fline
      insurv = 0; seen_packets = 0; seen_file = 0
    }
    /^findings:[[:space:]]*$/ { print; inf = 1; next }
    inf && /^[A-Za-z_][A-Za-z0-9_]*:/ { if (insurv) close_survivor(); inf = 0; skip = 0; print; next }
    inf && /^[[:space:]]*- id:/ {
      if (insurv) close_survivor()
      insurv = ($0 == starget) ? 1 : 0
      skip   = ($0 == rtarget) ? 1 : 0
      if (!skip) print
      next
    }
    inf && skip { next }
    inf && insurv && /^[[:space:]]*packets:/ { print pline; seen_packets = 1; next }
    inf && insurv && /^[[:space:]]*file:/ {
      if (fline != "") { print fline; seen_file = 1 } else print
      next
    }
    { print }
    END { if (insurv) close_survivor() }
  ' "$f" > "$tmp" \
    || { rm -f "$tmp" "$tmpbody"; _restore_aside "$aside_r" "$rbody"; die "failed to build updated run-state"; }

  # --- 4. swap the body in, then the run-state ------------------------------
  if [ "$s_had_body" = 1 ]; then
    aside_s="$(mktemp "${findingsdir}/.${sid}.aside.XXXXXX")" \
      || { rm -f "$tmp" "$tmpbody"; _restore_aside "$aside_r" "$rbody"; die "cannot create temp file in ${findingsdir}"; }
    mv -f "$sbody" "$aside_s" \
      || { rm -f "$tmp" "$tmpbody" "$aside_s"; _restore_aside "$aside_r" "$rbody"; die "cannot set aside ${sbody}"; }
  fi
  mv -f "$tmpbody" "$sbody" || {
    rm -f "$tmp" "$tmpbody"
    _restore_aside "$aside_s" "$sbody"; _restore_aside "$aside_r" "$rbody"
    die "cannot write ${sbody}"
  }
  mv -f "$tmp" "$f" || {
    rm -f "$tmp"
    # The merged body is already in place; put back what was there before it —
    # or remove it outright when this merge is what created it — so a failed
    # merge leaves BOTH entries and BOTH bodies, never a survivor carrying the
    # removed entry's text while the removed entry is still in the index.
    if [ "$s_had_body" = 1 ]; then _restore_aside "$aside_s" "$sbody"; else rm -f "$sbody"; fi
    _restore_aside "$aside_r" "$rbody"
    die "cannot replace run-state"
  }
  rm -f "$aside_s" "$aside_r"

  # ONE write, for the reason cmd_add_finding records: a caller piping this into
  # `grep -q` can close the pipe on the first line, and a second printf into a
  # closed pipe is a SIGPIPE that `pipefail` reports as a failure even though
  # the match succeeded.
  printf 'MERGED=yes\nSURVIVOR=%s\nREMOVED=%s\nPACKETS=%s\nFILE=%s\nBODY=%s\nSURVIVOR_BODY=%s\n' \
    "$sid" "$rid" "$merged_csv" "$sbody" \
    "$([ "$r_had_body" = 1 ] && printf 'merged' || printf 'summary-only')" \
    "$([ "$s_had_body" = 1 ] && printf 'appended' || printf 'created')"
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
#
# The summary unwrap is rs_decode from _YAML_AWK_DECODE (defined with
# _yaml_decode_value, above cmd_set) — the one decode rule, not a copy of it
# maintained here (runstate-write-integrity-gaps T4). Left undecoded, every
# summary would print wrapped in the quotes cmd_add_finding wrote and an agent
# would copy them into a brief. Migrating widens this site to the LEGACY
# double-quoted shape as well: never written by this file, but left behind by an
# older tool or a hand edit, and stripped verbatim exactly as the other three
# read sites strip it. That widening is the point of the unification, not a side
# effect of it — four sites that disagree about a shape on disk are four answers
# to one question.
_findings_default() {
  awk "$_YAML_AWK_DECODE"'
    /^findings:[[:space:]]*$/ { inf=1; next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inf=0 }
    inf && /^[[:space:]]*- id:/    { if (id != "") print id "\t" sum "\t" file "\t" pkts; sum=""; file=""; pkts="";
                                     sub(/^[[:space:]]*- id:[[:space:]]*/, ""); id=$0; next }
    inf && /^[[:space:]]*summary:/ { line=$0; sub(/^[[:space:]]*summary:[[:space:]]*/, "", line);
                                     sum=rs_decode(line); next }
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

# --- shared: split + validate a comma-joined packet-id list (packet-bundling T3) -
# `record-start`, `record-outcome` and `sweep-open --paused-cursor` all take
# `<id[,id...]>` now, because a bundled packet holds several ids for the ONE
# boundary it writes/exempts. Prints one validated id per line, in the given
# order, duplicates kept (a caller that wants dedup does that itself -- none of
# the three do, a bundle's members are already distinct by construction). Dies
# via `_rs_check_pkt_id` on the FIRST malformed member, before printing
# anything -- callers that capture this via `x="$(...)"` (not `local x="$(...)"`,
# which would swallow the exit status) get that die's exit code propagated by
# `set -e`, so a boundary is never half-recorded. Splits on a bare comma only
# (no whitespace form, unlike `_split_ids`/ADR 0024's `--packets`) and the three
# malformed shapes a comma list can take -- empty, a leading/trailing comma, a
# doubled comma -- are rejected up front, because `read -a` with IFS=','
# silently drops a genuinely empty trailing field rather than surfacing it as
# an empty id.
_rs_split_pkt_ids() {
  local raw="$1" id
  case "$raw" in
    '') die "packet id list must not be empty" ;;
    ,*|*,|*,,*) die "packet id list must not contain an empty member" ;;
  esac
  local -a parts
  IFS=',' read -r -a parts <<<"$raw"
  for id in "${parts[@]}"; do
    _rs_check_pkt_id "$id"
    printf '%s\n' "$id"
  done
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
#
# BUNDLING (packet-bundling T3): <packet-id> is a comma-joined list. Every
# member of a bundle that ends non-green gets the SAME outcome, so there is
# exactly one `outcome` argument for the whole call, applied to every id — one
# JSON record per id, all sharing one timestamp and one session, so the
# members of one boundary can never be ordered apart from each other by
# accident. `_rs_split_pkt_ids` validates every id and dies on the first
# malformed one BEFORE any record is written (`pkts="$(...)"` below, not
# `local pkts="$(...)"`, so that die's exit propagates under `set -e`) — a
# boundary is never half-recorded. A single id is the n=1 case and its output
# is byte-identical to today.
cmd_record_outcome() {
  local pkt_list="${1:-}" outcome="${2:-}" sess="${3:-${CLAUDE_CODE_SESSION_ID:-adhoc}}"
  [ -n "$pkt_list" ] && [ -n "$outcome" ] || die "usage: record-outcome <packet-id[,id...]> <green|failed|rolled-back|blocked|abandoned> [session-id]"
  local pkts
  pkts="$(_rs_split_pkt_ids "$pkt_list")"
  case "$outcome" in
    green|failed|rolled-back|blocked|abandoned) ;;
    *) die "outcome must be one of: green failed rolled-back blocked abandoned" ;;
  esac
  local ts
  ts="$(_rs_now_ts)"
  local pkt line
  while IFS= read -r pkt; do
    [ -n "$pkt" ] || continue
    line="$(printf '{"ts":"%s","packet":"%s","session":"%s","outcome":"%s"}' "$ts" "$pkt" "$sess" "$outcome")"
    _rs_append_outcomes_line "$sess" "$line" || return 0
    printf 'RECORDED=yes\nPACKET=%s\nOUTCOME=%s\n' "$pkt" "$outcome"
  done <<EOF
$pkts
EOF
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
#
# BUNDLING (packet-bundling T3): <packet-id> is a comma-joined list, and one
# start (or, with --continue, one continuation) record is written per member,
# all sharing a single timestamp and session — the same rule and the same
# validate-before-write ordering as record-outcome above (see that comment
# block for why `pkts="$(...)"`, not `local pkts="$(...)"`, is load-bearing).
# A single id is the n=1 case and its output is byte-identical to today.
cmd_record_start() {
  # `--continue` may appear anywhere among the args, so scan rather than assume
  # a fixed position: `record-start <pkt> --continue [sess]` and
  # `record-start <pkt> [sess] --continue` must both work.
  local cont=no args=() a
  for a in "$@"; do
    if [ "$a" = "--continue" ]; then cont=yes; else args+=("$a"); fi
  done
  local pkt_list="${args[0]:-}" sess="${args[1]:-${CLAUDE_CODE_SESSION_ID:-adhoc}}"
  [ -n "$pkt_list" ] || die "usage: record-start <packet-id[,id...]> [--continue] [session-id]"
  local pkts
  pkts="$(_rs_split_pkt_ids "$pkt_list")"
  local kind=start
  [ "$cont" = yes ] && kind=continue
  local ts
  ts="$(_rs_now_ts)"
  local pkt line
  while IFS= read -r pkt; do
    [ -n "$pkt" ] || continue
    line="$(printf '{"ts":"%s","packet":"%s","session":"%s","kind":"%s"}' "$ts" "$pkt" "$sess" "$kind")"
    _rs_append_outcomes_line "$sess" "$line" || return 0
    printf 'RECORDED=yes\nPACKET=%s\nKIND=%s\n' "$pkt" "$kind"
  done <<EOF
$pkts
EOF
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
# sweep-open [--list] [--paused-cursor <id[,id...]>] [--gone <id,...>]
#
# For each OPEN packet (see _rs_open_packets) except a paused-cursor member,
# appends a TERMINAL record — outcome=interrupted, or =abandoned for an id in
# --gone — using the SAME terminal shape record-outcome writes (T1/T3 fix this
# format; nothing downstream reshapes it): {"ts":...,"packet":...,"session":...,"outcome":...}.
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
#
# BUNDLING (packet-bundling T3): --paused-cursor takes a comma-joined list, so
# a paused BUNDLE's whole membership stays exempt — before this, only the
# first member (an exact-string match) was spared, and every other live member
# would have been swept as `interrupted`, the one outcome reserved for
# sweep-open alone. Every member is validated with `_rs_check_pkt_id` (via
# `_rs_split_pkt_ids`, called directly rather than through `$(...)` so its
# `die` exits the whole process rather than only a subshell) before any row is
# read, so a malformed cursor member refuses the whole call rather than
# silently exempting nothing. Membership is `_rs_in_csv`, not `=` — a single
# id is the n=1 case and behaves exactly as the old exact match did.
cmd_sweep_open() {
  local do_list=no cursor="" gone_csv=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --list)
        do_list=yes; shift ;;
      --paused-cursor)
        [ $# -ge 2 ] || die "usage: sweep-open [--list] [--paused-cursor <id[,id...]>] [--gone <id,...>]"
        cursor="$2"; shift 2 ;;
      --gone)
        [ $# -ge 2 ] || die "usage: sweep-open [--list] [--paused-cursor <id[,id...]>] [--gone <id,...>]"
        gone_csv="$2"; shift 2 ;;
      *)
        die "usage: sweep-open [--list] [--paused-cursor <id[,id...]>] [--gone <id,...>]" ;;
    esac
  done
  [ -n "$cursor" ] && _rs_split_pkt_ids "$cursor" >/dev/null

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
    [ -n "$cursor" ] && _rs_in_csv "$pkt" "$cursor" && continue

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
# the CLAUDE_CODE_AUTO_COMPACT_WINDOW env var. Pure reader: it reads no
# plugin carrier (ADR 0028's 2026-09-21 amendment found none on 2.1.278)
# and never writes -- see the header comment.

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

# =============================================================================
# review-due (escalation-decider T2)
# =============================================================================
# The periodic review's trigger, as a pure reader. See the header entry above
# for the full contract; what follows is why each piece is shaped this way.
#
# The one invariant everything here serves: a count that could not be read is
# `unmeasured`, never 0. 0 is a MEASUREMENT meaning "nothing has happened since
# the last review", so a failed read reported as 0 would sit below both
# thresholds and suppress every review for the rest of the run -- silently, and
# for exactly as long as whatever broke the read stays broken.

_RS_REVIEW_DEFAULT_NON_GREEN=2
_RS_REVIEW_DEFAULT_BEGINNINGS=10

# --- one review threshold from .agents/project-overrides.yaml ---------------
# Same token-scan shape as _rs_packet_attempts_limit/_rs_bundle_max_tasks:
# scan the remainder after `<key>:`, skipping any token that is not purely
# digits (so a trailing comment cannot defeat the scan) and stripping one
# matching pair of quotes per token first, so `review_after_beginnings: '10'`
# -- legal YAML -- is honoured rather than read as missing.
#
# Two deliberate differences from those two siblings:
#
#  - the key is a PARAMETER, passed through ENVIRON rather than `awk -v`
#    (which expands escapes in the value) and matched with a literal
#    index()==1 rather than a regex, so no character in a key could ever widen
#    its own match. Both callers pass a constant, so neither risk is live
#    today; the point is that neither becomes live if a third key is added.
#  - an overrides path that EXISTS but cannot be read as a regular file
#    returns `unmeasured`, not the default. Absence is an answer -- no
#    override, hence the default -- but an unreadable file, or a directory
#    where the file belongs, is a failed read, and reporting the default there
#    is precisely "a default that reads like a measurement". Both shapes are
#    tested because only the second is uid-independent: as uid 0, a mode-000
#    file is still readable.
#
# Missing, invalid and 0 all fall back to the default. 0 is invalid rather than
# "review at every boundary": a threshold of 0 fires forever and is a typo, not
# a policy anyone would set.
_rs_review_threshold() {
  local main_root="$1" key="$2" default="$3" ov v
  ov="${main_root}/.agents/project-overrides.yaml"
  if [ -e "$ov" ] && { [ ! -f "$ov" ] || [ ! -r "$ov" ]; }; then printf 'unmeasured'; return 0; fi
  v=""
  if [ -f "$ov" ]; then
    v="$(RS_REVIEW_KEY="$key" awk '
      BEGIN { key = ENVIRON["RS_REVIEW_KEY"] ":"; klen = length(key) }
      index($0, key) == 1 {
        line = substr($0, klen + 1)
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
  case "$v" in ''|0|*[!0-9]*) printf '%s' "$default" ;; *) printf '%s' "$v" ;; esac
}

# --- can this log directory actually be read? -------------------------------
# Returns 0 for "yes, and what I read is the truth", 1 for "no -- report
# unmeasured". ABSENT is 0 on purpose: a directory that does not exist holds no
# records, so 0 records is a measurement, not a failed read. Every other
# failure mode is 1 -- a directory that cannot be opened or listed, a plain
# file sitting where the log directory belongs, or a log file the process
# cannot read. That last check matters because the awk pass below globs
# `<dir>/*.jsonl` with stderr discarded: an unreadable FILE inside a readable
# directory would otherwise contribute nothing and read as an honest zero.
_rs_review_dir_readable() {
  local dir="$1" f
  [ -e "$dir" ] || return 0
  [ -d "$dir" ] || return 1
  { [ -r "$dir" ] && [ -x "$dir" ]; } || return 1
  for f in "$dir"/*.jsonl; do
    [ -e "$f" ] || continue
    [ -r "$f" ] || return 1
  done
  return 0
}

# --- the ts of the LATEST recorded review, or empty -------------------------
# Scans EVERY session's decision log, not one named session: the count this
# anchors is itself cross-session, and a review recorded by a session that has
# since ended still reset the count. Same plain index/substr field extraction
# as _rs_open_packets (no regex escaping, portable to a POSIX awk), and the
# same "max by PARSED time" comparison as _rs_latest_driver_mode_enter_ts --
# a raw string compare would sort a sub-second stamp below a whole-second one
# in the same second ("." is 0x2E, "Z" is 0x5A).
_rs_latest_review_ts() {
  local main_root="$1" dir
  dir="${main_root}/.agents/metrics/decisions"
  [ -d "$dir" ] || return 0
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
    { k = field($0, "kind"); if (k != "review") next
      ts = field($0, "ts"); if (ts != "") print ts }
  ' "$dir"/*.jsonl 2>/dev/null)
EOF
  printf '%s' "$best_ts"
}

# --- every outcomes record that could count, as <tag>\t<parsed-time key> ----
# Two stages for the same reason _rs_open_packets is two stages: awk extracts
# fields with plain index/substr, and bash attaches the parsed-time key that
# needs `date` (which awk cannot do portably). Only CANDIDATE records reach the
# bash stage, so the per-record `date` cost is paid for beginnings and non-green
# endings and for nothing else.
#
#   S = a beginning: `kind` is exactly `start`. A `kind: continue` is skipped
#       HERE rather than filtered later, so there is one place to look for the
#       rule that a continuation is not a beginning.
#   N = a non-green ending: `outcome` is one of the five the PRD names. Matched
#       by VALUE, never as `outcome != "green"` -- that inverted form would
#       turn any outcome this file does not yet know (a future value, a
#       truncated record) into an ending, and endings are the count with the
#       smaller threshold.
_rs_review_rows() {
  local dir="$1" parsed
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
      ts = field($0, "ts"); if (ts == "") next
      k = field($0, "kind")
      if (k != "") { if (k == "start") print "S\t" ts; next }
      o = field($0, "outcome")
      if (o == "failed" || o == "rolled-back" || o == "blocked" || o == "abandoned" || o == "interrupted")
        print "N\t" ts
    }
  ' "$dir"/*.jsonl 2>/dev/null || true)"
  [ -n "$parsed" ] || return 0
  local tag ts
  while IFS="$(printf '\t')" read -r tag ts; do
    [ -n "$tag" ] || continue
    printf '%s\t%s\n' "$tag" "$(_rs_ts_key "$ts")"
  done <<EOF
$parsed
EOF
}

# Always exits 0 -- a query, same contract as periodic-pause/bundle-cap/
# compact-threshold. Never writes anything: the CALLER decides what to do with
# DUE=yes, and record-review (the thing that resets the count) is a separate,
# explicit call made by the review itself.
cmd_review_due() {
  [ $# -eq 0 ] || die "usage: review-due (takes no arguments -- it counts across EVERY session's log, so there is no session to name)"

  local main_root
  if ! main_root="$(_rs_main_checkout_root)"; then
    # Nothing at all could be read -- not the logs, not the overrides file. All
    # four values are unmeasured and the review runs.
    printf 'NON_GREEN=unmeasured\nBEGINNINGS=unmeasured\nEVERY_NON_GREEN=unmeasured\nEVERY_BEGINNINGS=unmeasured\nDUE=yes\n'
    return 0
  fi

  local every_ng every_b
  every_ng="$(_rs_review_threshold "$main_root" review_after_non_green_endings "$_RS_REVIEW_DEFAULT_NON_GREEN")"
  every_b="$(_rs_review_threshold "$main_root" review_after_beginnings "$_RS_REVIEW_DEFAULT_BEGINNINGS")"

  local outcomes_dir="${main_root}/.agents/metrics/outcomes"
  local decisions_dir="${main_root}/.agents/metrics/decisions"
  local non_green=unmeasured beginnings=unmeasured

  # BOTH logs have to be readable for the counts to mean anything: the outcomes
  # log supplies the records and the decision log supplies the point they are
  # counted from, so an unreadable decision log would silently count from the
  # wrong anchor rather than fail.
  if _rs_review_dir_readable "$outcomes_dir" && _rs_review_dir_readable "$decisions_dir"; then
    local rows anchor_key=-1 review_ts first_start
    review_ts="$(_rs_latest_review_ts "$main_root")"
    rows="$(_rs_review_rows "$outcomes_dir")"
    if [ -n "$review_ts" ]; then
      anchor_key="$(_rs_ts_key "$review_ts")"
    elif [ -n "$rows" ]; then
      # No review has ever completed, so counting starts at the repo's first
      # beginning. When the log holds endings but no beginnings at all (a log
      # written before start records existed), the anchor stays -1 and the
      # whole log counts -- which can only make a review run sooner, and
      # running one review too many is the recoverable direction.
      first_start="$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "S" { if (m == "" || $2 + 0 < m) m = $2 + 0 } END { if (m != "") printf "%d\n", m }')"
      [ -n "$first_start" ] && anchor_key="$first_start"
    fi
    non_green=0; beginnings=0
    if [ -n "$rows" ]; then
      local counts
      # `>=`, not `>`: a record stamped at the review's own millisecond counts
      # toward the NEXT review. Over-counting runs a review sooner; under-
      # counting suppresses one, which is the failure this whole command is
      # shaped to avoid.
      counts="$(printf '%s\n' "$rows" | RS_REVIEW_ANCHOR="$anchor_key" awk -F'\t' '
        BEGIN { a = ENVIRON["RS_REVIEW_ANCHOR"] + 0 }
        $2 + 0 >= a { if ($1 == "S") b++; else if ($1 == "N") n++ }
        END { printf "%d\t%d\n", n + 0, b + 0 }')"
      non_green="${counts%%$(printf '\t')*}"
      beginnings="${counts##*$(printf '\t')}"
    fi
  fi

  local due=no
  if [ "$non_green" = unmeasured ] || [ "$beginnings" = unmeasured ] \
     || [ "$every_ng" = unmeasured ] || [ "$every_b" = unmeasured ]; then
    due=yes
  else
    [ "$non_green" -ge "$every_ng" ] && due=yes
    [ "$beginnings" -ge "$every_b" ] && due=yes
  fi
  printf 'NON_GREEN=%s\nBEGINNINGS=%s\nEVERY_NON_GREEN=%s\nEVERY_BEGINNINGS=%s\nDUE=%s\n' \
    "$non_green" "$beginnings" "$every_ng" "$every_b" "$due"
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

# --- config roots: ADR 0011's bounded upward walk, reimplemented here -------
# `hooks/guard.sh` performs exactly this discovery for its `.agents/guard-extra-*`
# files, and this is a REIMPLEMENTATION rather than a shared helper because the
# guard is a hook BODY: it reads a JSON payload on stdin, decides, and exits —
# it has no callable form this script could source without also running its
# policy. The rules are the guard's, and a change to them belongs in both
# places:
#   - candidates are $CLAUDE_PROJECT_DIR (the harness's project root, when set)
#     and the cwd, plus every ancestor of either that declares a `.agents/`
#     directory. The upward walk — not `git rev-parse --show-toplevel` — is what
#     finds the root: it works in a git-free repo and does not stop at a NESTED
#     checkout's boundary.
#   - bounded by $HOME and `/` (and capped at 40 levels) so a stray dotfile
#     above the workspace can never be picked up.
#   - deduped by RESOLVED path, because the two walks routinely meet at the same
#     root (the driver's cwd is usually the project root itself).
_RS_CONFIG_ROOTS=()
_rs_add_config_root() {
  local d="${1:-}" r e
  [ -n "$d" ] && [ -d "${d}/.agents" ] || return 0
  r="$(cd "$d" 2>/dev/null && pwd -P)" || return 0
  # `if` rather than `[ … ] && return 0`: this script runs under `set -e`, and a
  # bare test as the loop body's last command makes the whole `for` return
  # non-zero on the common no-match path.
  for e in ${_RS_CONFIG_ROOTS[@]+"${_RS_CONFIG_ROOTS[@]}"}; do
    if [ "$e" = "$r" ]; then return 0; fi
  done
  _RS_CONFIG_ROOTS+=("$r")
}
_rs_walk_up_for_config() {
  local d n=0
  d="$(cd "${1:-/nonexistent}" 2>/dev/null && pwd -P)" || return 0
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "${HOME:-}" ] && [ "$n" -lt 40 ]; do
    _rs_add_config_root "$d"
    d="$(dirname "$d")"
    n=$((n + 1))
  done
}

# --- .agents/handoff-extra: the repository's OWN REQUIRED lines -------------
# handoff-verification-contract T3. Prints one `REQUIRED: <line>` per non-blank,
# non-`#` line of `.agents/handoff-extra` in EVERY discovered config root, in
# discovery order. The merge is a restrictive UNION, the same shape the guard
# applies to `guard-extra-*`: a nested or foreign root can only ADD lines, never
# remove or override another root's — so ambiguity can never yield a weaker
# contract than the real project's. Identical lines from two roots collapse to
# one, since a line repeated verbatim reads as two criteria rather than one.
#
# Absent in every root ⇒ prints nothing, and the caller emits nothing: a
# repository without the file gets a handoff byte-identical to one written with
# this mechanism absent — no header, no empty section, no warning.
#
# PRESENT but unreadable ⇒ refuses the handoff, exactly as an unreadable
# verification-contract template does: the repository declared extra criteria
# and an agent cannot tell a handoff that dropped them from one that never had
# any. Presence is `-e` OR `-L`, so a dangling symlink counts as present-and-
# unreadable rather than absent, and readability is probed by EXECUTION (`cat`)
# rather than by `[ -r ]`, which answers `true` for root on a mode-000 file.
_rs_handoff_extra_lines() {
  _RS_CONFIG_ROOTS=()
  _rs_walk_up_for_config "${CLAUDE_PROJECT_DIR:-}"
  _rs_walk_up_for_config "$PWD"

  local root file body line seen
  seen=$'\n'
  for root in ${_RS_CONFIG_ROOTS[@]+"${_RS_CONFIG_ROOTS[@]}"}; do
    file="${root}/.agents/handoff-extra"
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then continue; fi
    if ! body="$(cat "$file" 2>/dev/null)"; then
      die "handoff: cannot read the extension file '${file}' — a present-but-unreadable .agents/handoff-extra refuses the handoff rather than dropping the lines it declares"
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      # The comment/blank filter is the WHOLE syntax of this file (the feature's
      # own risk note): everything else is repository prose appended verbatim.
      case "$line" in \#*) continue ;; esac
      case "$line" in *[![:space:]]*) ;; *) continue ;; esac
      case "$seen" in *$'\n'"$line"$'\n'*) continue ;; esac
      seen="${seen}${line}"$'\n'
      printf 'REQUIRED: %s\n' "$line"
    done <<< "$body"
  done
  return 0
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

# --- implementer_turn_budget: the implementer's budget, in tool calls ---------
# implementer-continuation T1. Same token-scanning shape as
# _rs_packet_attempts_limit: token-scan the remainder after
# `implementer_turn_budget:`, skipping anything that is not purely digits (so
# a trailing comment cannot defeat this) and stripping one matching pair of
# quotes from EACH token before testing digit-ness (`'150'` is legal YAML and
# must not read as invalid). Missing, invalid and zero all read as 120; leading
# zeros are stripped in awk, so `00` reads as zero (120) rather than slipping
# past the `0` case as a "positive" value.
_rs_implementer_turn_budget() {
  local main_root="$1" ov v
  ov="${main_root}/.agents/project-overrides.yaml"
  v=""
  if [ -f "$ov" ]; then
    v="$(awk '
      /^implementer_turn_budget:[[:space:]]*/ {
        line = $0
        sub(/^implementer_turn_budget:[[:space:]]*/, "", line)
        n = split(line, a, " ")
        for (i = 1; i <= n; i++) {
          tok = a[i]
          gsub(/^"/, "", tok); gsub(/"$/, "", tok)
          gsub(/^'"'"'/, "", tok); gsub(/'"'"'$/, "", tok)
          if (tok ~ /^[0-9]+$/) { sub(/^0+/, "", tok); print tok; exit }
        }
      }
    ' "$ov" 2>/dev/null)"
  fi
  case "$v" in ''|0|*[!0-9]*) echo 120 ;; *) echo "$v" ;; esac
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

  # --- the verification contract, read and validated at THIS point ------------
  # Every handoff carries it, whatever the body's source (gspec-sourced,
  # run-state-sourced, or a bundle) — there is no flag, no env var and no code
  # path that omits it. Placement is deliberate at both ends:
  #   - AFTER `cat` has drained stdin, so the producer on the other side of the
  #     pipe (gspec-backlog.sh handoff, run through a pipeline by the driver)
  #     completes its write and gets this message, rather than taking SIGPIPE
  #     mid-write and reporting rc=141 in place of the real reason; and
  #   - BEFORE mktemp, so a refusal leaves nothing on disk at all — not a temp
  #     file, and above all not a handoff.md missing the block, which an agent
  #     would read as a handoff with no contract rather than as a failure.
  local req_tpl="$HANDOFF_REQUIRED_TEMPLATE" required=""
  if ! required="$(cat "$req_tpl" 2>/dev/null)"; then
    die "handoff: cannot read the verification contract template at '${req_tpl}' — every handoff carries it and there is no option to omit it"
  fi
  case "$required" in
    *[![:space:]]*) ;;
    *) die "handoff: the verification contract template at '${req_tpl}' is empty — every handoff carries it and there is no option to omit it" ;;
  esac

  # --- the repository's own extension lines, read at the SAME point ----------
  # Same two reasons as the template above: after stdin is drained, and before
  # mktemp, so a refusal leaves nothing on disk. Empty is the normal case and
  # emits nothing at all (see _rs_handoff_extra_lines).
  local extra="" _rs_x=""
  if ! extra="$(_rs_handoff_extra_lines)"; then
    # The helper runs in a command substitution, so its `die` exits only THAT
    # subshell — the message naming the file it could not read is already on
    # stderr, but the refusal has to be re-raised here or the handoff would be
    # written without the lines the repository declared.
    exit 1
  fi

  # --- the implementer's budget line (implementer-continuation T1) -----------
  # Written for `--agent implementer` and for no other agent, on every
  # implementer handoff (first dispatch, continuation, fix/retry re-dispatch
  # alike -- each is a fresh `handoff` call). It goes directly after the
  # header and BEFORE the body: placed after the body it would sit between the
  # driver's own conditional REQUIRED lines and the six, separating the two.
  # With it removed, the rest of the file is byte-identical to a handoff
  # written without it (test-runstate.sh pins that).
  local budget_line=""
  if [ "$agent" = "implementer" ]; then
    local budget_root budget
    budget_root="$(_rs_main_checkout_root)" || die "handoff: not a git repo"
    budget="$(_rs_implementer_turn_budget "$budget_root")"
    budget_line="BUDGET: this dispatch has a budget of ${budget} tool calls. At the budget, stop at a safe boundary — never mid-edit — leave the partial work uncommitted in the working tree, write what is done and what remains to the result file, and return a status line whose first token is \`continue\`."
  fi

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
    if [ -n "$budget_line" ]; then printf '%s\n\n' "$budget_line"; fi
    printf '%s\n' "$body"
    # Verbatim, and LAST: the body carries the driver's own conditional
    # REQUIRED lines, which stay ahead of the block exactly as the driver wrote
    # them — neither moved into it nor repeated by it. Emitted from the value
    # already read and validated above rather than re-`cat`ing the file, so
    # there is no window in which the template changes between the check and
    # the write.
    printf '\n%s\n' "$required"
    # The repository's own lines, AFTER the six and in the same shape, each
    # separated by a blank line exactly as the template separates its own. When
    # there are none this emits nothing — not a heading, not a blank section —
    # so the file is byte-identical to one written before this existed.
    if [ -n "$extra" ]; then
      while IFS= read -r _rs_x; do printf '\n%s\n' "$_rs_x"; done <<< "$extra"
    fi
  } > "$_rs_tmp"
  mv -f "$_rs_tmp" "$target"
  trap - EXIT
  printf 'HANDOFF=%s\n' "$target"
}

# --- amend-handoff: the decider's ONE write into a handoff file -------------
# escalation-decider T4. `retry` is the only decision that changes what the
# implementer is asked to do, and that change has to reach the agent through
# the one file it is handed. The decider holds no `Edit`/`Write` — ADR 0028
# kept the read-only agents read-only by routing every write they need through
# this script, exactly as `write-result` did — so this subcommand IS that
# write, and it is deliberately the only one into a handoff file.
#
# ONE marked block, replaced in place on every later call. Three retries leave
# one amendment carrying the current instruction, not three stacked ones an
# implementer has to date-order for itself. The markers are HTML comments (a
# markdown reader renders them invisibly) matched as WHOLE lines, never as a
# substring, and replacement text carrying either marker is refused outright
# rather than spliced in — text that could open or close the block is the one
# input that could make a later call replace the wrong span.
#
# SPLICED, never regenerated, and that is the point of the whole function:
#   - `run-digest` reads the packet's title out of the handoff's FIRST line
#     (`# <pkt>: <title>` — see _rs_digest_title), so a rewrite that rebuilt
#     the file would have to reproduce that line exactly or the packet would
#     silently start reporting its own id as its title; and
#   - the verification contract ADR 0029 appends is the file's tail, and there
#     is no option anywhere that writes a handoff without it.
# Splicing one block into the file already on disk reproduces neither, so
# neither can drift.
#
# PLACEMENT is the end of the file. The alternative — between the header and
# the body — was rejected: a `##` heading has no closing form in markdown, so
# the whole task body below it would read as part of the amendment, and an
# implementer could no longer tell what actually changed. At the end the only
# thing "inside" the section is the amendment itself.
_RS_AMEND_BEGIN='<!-- orch:decider-amendment -->'
_RS_AMEND_END='<!-- /orch:decider-amendment -->'

_rs_amend_block() {
  printf '%s\n' "$_RS_AMEND_BEGIN"
  printf '## Decider amendment\n\n'
  printf 'The escalation decider changed this packet'"'"'s brief after an earlier attempt.\n'
  printf 'It adds to the task above; nothing above it has been removed.\n\n'
  printf '%s\n' "$1"
  printf '%s\n' "$_RS_AMEND_END"
}

cmd_amend_handoff() {
  local f="" pkt="" pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --*) die "usage: amend-handoff <run-state> <packet-id> (unknown option: $1)" ;;
      *)
        case "$pos" in
          0) f="$1" ;;
          1) pkt="$1" ;;
          *) die "usage: amend-handoff <run-state> <packet-id> (too many arguments)" ;;
        esac
        pos=$((pos + 1)); shift ;;
    esac
  done
  [ -n "$f" ] && [ -n "$pkt" ] || die "usage: amend-handoff <run-state> <packet-id>"
  need_file "$f"
  _rs_check_pkt_id "$pkt"

  local run_id
  run_id="$(cmd_get "$f" run_id)"
  [ -n "$run_id" ] || die "amend-handoff: run-state has no run_id (begin-run has not been called)"
  local rundir; rundir="$(_rs_run_dir "$run_id" amend-handoff)"

  # LEXICAL containment first, exactly as write-result decides it: pure string
  # normalization, no filesystem access at all, so a path that resolves outside
  # the run directory is refused before anything is read or written. The packet
  # id is charset-validated above, so this is belt-and-braces today — and it
  # stays, because the day a caller builds the id from somewhere else is
  # precisely the day nobody re-derives this check.
  local abs_rundir abs_target pktdir
  abs_rundir="$(_rs_lexical_abspath "$rundir")"
  abs_target="$(_rs_lexical_abspath "${rundir}/${pkt}/handoff.md")"
  case "$abs_target" in
    "${abs_rundir}/"*) ;;
    *) die "amend-handoff: packet '${pkt}' resolves outside the current run directory (${abs_rundir})" ;;
  esac
  pktdir="$(dirname "$abs_target")"

  # stdin drained HERE, before any refusal that can still fire: the caller pipes
  # the replacement text in, and a die ahead of this leaves that producer taking
  # SIGPIPE mid-write and reporting rc=141 in place of the real reason (the same
  # placement, for the same reason, as cmd_handoff's contract read).
  local text
  text="$(cat)"
  case "$text" in
    *[![:space:]]*) ;;
    *) die "amend-handoff: the replacement text is empty — an empty amendment says nothing and would replace one that did" ;;
  esac
  case "$text" in
    *"$_RS_AMEND_BEGIN"*|*"$_RS_AMEND_END"*)
      die "amend-handoff: the replacement text carries a decider-block marker — refused rather than written, because the next call would then replace the wrong span" ;;
  esac

  [ -f "$abs_target" ] \
    || die "amend-handoff: no handoff file for packet '${pkt}' at ${abs_target} — handoff has not been called for it in this run"

  # SYMLINK-SAFE containment, the second half of write-result's pair: the
  # lexical check above cannot see a symlinked packet directory under the run
  # directory that resolves elsewhere on disk. Now that the target exists, its
  # directory is re-checked by REAL path.
  local real_rundir real_pktdir
  real_rundir="$(cd "$abs_rundir" 2>/dev/null && pwd -P)" || die "amend-handoff: cannot resolve the run directory"
  real_pktdir="$(cd "$pktdir" 2>/dev/null && pwd -P)" || die "amend-handoff: cannot resolve the packet directory"
  case "$real_pktdir" in
    "$real_rundir"|"$real_rundir"/*) ;;
    *) die "amend-handoff: packet '${pkt}' escapes the run directory via a symlink" ;;
  esac

  # ONE scan of the file on disk: how many of each marker line it carries and
  # where the first of each sits. Counting BOTH (rather than looking for the
  # opening marker alone) is what makes the malformed cases refusable instead
  # of guessable — an unterminated block has no end for the splice to stop at,
  # and guessing would swallow everything after it, the verification contract
  # included.
  local scan sm_count em_count sm_line em_line
  scan="$(awk -v sm="$_RS_AMEND_BEGIN" -v em="$_RS_AMEND_END" '
    $0 == sm { smc++; if (!sml) sml = FNR }
    $0 == em { emc++; if (!eml) eml = FNR }
    END { printf "%d %d %d %d\n", smc + 0, emc + 0, sml + 0, eml + 0 }
  ' "$abs_target")"
  read -r sm_count em_count sm_line em_line <<< "$scan"

  local mode
  if [ "$sm_count" = 0 ] && [ "$em_count" = 0 ]; then
    mode=inserted
  elif [ "$sm_count" = 1 ] && [ "$em_count" = 1 ] && [ "$em_line" -gt "$sm_line" ]; then
    mode=replaced
  else
    die "amend-handoff: ${abs_target} carries a malformed decider block (${sm_count} opening and ${em_count} closing marker lines) — refusing rather than guessing where the block ends"
  fi

  # GLOBAL, not local -- see cmd_handoff's identical comment on the same
  # pattern: an EXIT trap referencing a function-LOCAL is bash-version-
  # dependent while the shell unwinds under `set -e`.
  _rs_tmp=""
  trap '[ -n "${_rs_tmp:-}" ] && rm -f "$_rs_tmp"; :' EXIT
  _rs_tmp="$(mktemp "${pktdir}/.amend-handoff.XXXXXX")" || die "cannot create temp file in ${pktdir}"
  # `head`/`tail` read a REGULAR FILE here, not a pipe: there is no producer to
  # take SIGPIPE when head stops, so this is not the early-exit-reader shape the
  # source guard at the foot of test-runstate.sh scans for.
  { if [ "$mode" = replaced ]; then
      head -n "$((sm_line - 1))" "$abs_target"
      _rs_amend_block "$text"
      tail -n "+$((em_line + 1))" "$abs_target"
    else
      cat "$abs_target"
      printf '\n'
      _rs_amend_block "$text"
    fi
  } > "$_rs_tmp"
  mv -f "$_rs_tmp" "$abs_target"
  trap - EXIT
  printf 'HANDOFF=%s\nAMENDMENT=%s\n' "$abs_target" "$mode"
}

# =============================================================================
# check-status (loop-driver-run-gaps T1)
# =============================================================================

# --- the ONE mechanical reading of templates/status-line.md ------------------
# Prints ONE reason and returns 1 when <line> is off-grammar; prints nothing
# and returns 0 when it is well-formed. The reason names the RULE that failed,
# never a generic "malformed status line": the driver's only move on a refusal
# is to re-dispatch the same agent once passing the reason back, and a generic
# message leaves that re-dispatch nothing actionable.
#
# The boundaries come from the FIRST and LAST separator, never from a field
# count. Splitting on ` · ` into exactly four fields would refuse a line
# templates/status-line.md explicitly permits: the two middle fields are free
# text and may carry their own ` · `. Only `<status>` (before the first
# separator), the next-to-last field (between the last two) and `<path>`
# (after the last) are load-bearing.
#
# Pure string operations -- `case` and parameter expansion, no pipe, no
# subshell per rule -- so this stays callable from any refusal path (T2 wires
# `route`/`write-result` to the same reasons) without a fork per call, and so
# it does not add an instance of the pipe-fed-`grep` construct the sweep's
# source guard polices.
_rs_status_line_reason() {
  local line="$1"
  local sep=' · '
  local nl='
'
  local cr; cr="$(printf '\r')"
  local first last pre mid
  local want="must be literally 'result: needs-reading' or 'result: no'"

  # One line. A CR counts as a break too: a status line that renders as two
  # lines breaks the contract the same way regardless of which byte did it,
  # and this file has been bitten by an invisible CR before (ADR 0019 v3.1).
  case "$line" in
    *"$nl"*|*"$cr"*)
      printf '%s' 'status line must be exactly one line; this one contains a line break'
      return 1 ;;
  esac
  # No backtick, no `$` -- the line is passed to a shell as `--status '<line>'`
  # and nothing legitimate in a one-clause status report needs either.
  case "$line" in
    *'`'*)
      printf '%s' 'status line must contain no backtick'
      return 1 ;;
  esac
  case "$line" in
    *'$'*)
      printf '%s' 'status line must contain no dollar sign'
      return 1 ;;
  esac

  first="${line%%"$sep"*}"
  if [ "$first" = "$line" ]; then
    printf '%s' "status line carries no ' · ' separator at all; expected <status> · <what changed> · result: <needs-reading|no> · <path>"
    return 1
  fi
  case "$first" in
    ''|*[[:space:]]*)
      printf '%s' "status line's first field (everything before the first ' · ') must be one word, not '${first}'"
      return 1 ;;
  esac

  # The next-to-last field: between the second-to-last separator and the last.
  # With only ONE separator there is no such field -- same rule, reported as
  # what it is rather than as an empty value.
  pre="${line%"$sep"*}"
  if [ "${pre%%"$sep"*}" = "$pre" ]; then
    printf '%s' "status line's next-to-last field ${want}; this line has only one ' · ' separator, so it has no such field"
    return 1
  fi
  mid="${pre##*"$sep"}"
  case "$mid" in
    'result: needs-reading'|'result: no') ;;
    *)
      printf '%s' "status line's next-to-last field ${want}, not '${mid}'"
      return 1 ;;
  esac

  last="${line##*"$sep"}"
  case "$last" in
    ''|*[[:space:]]*)
      printf '%s' "status line's last field (everything after the last ' · ') must be a non-empty path with no whitespace, not '${last}'"
      return 1 ;;
  esac
  return 0
}

# --- the ONE refusal path for an off-grammar line (loop-driver-run-gaps T2) --
# `die`s with the BARE reason `_rs_status_line_reason` printed and no command-
# specific prefix, so `check-status`, `route` and `write-result` all refuse the
# same line with byte-identical output. Each caller wording its own refusal
# would hand the driver a reason the grammar's owner never stated, and the
# driver's one move on a refusal is to re-dispatch the agent passing that
# reason and nothing else.
#
# Called by `route`/`write-result` BEFORE either touches disk — before the
# routing record is appended, before the run directory is created and before
# the result file is written — so a refused line leaves no routing record for
# a line the loop never routed on, and no half-written result file.
#
# `reason="$(...)" && return 0` rather than an `if`: under `set -e` an
# assignment whose command substitution exits non-zero aborts the shell, and
# the `&&` is what makes the failure a value here instead of an exit.
_rs_require_status_line() {
  local reason=""
  reason="$(_rs_status_line_reason "$1")" && return 0
  die "$reason"
}

# Refuses via `die` with the bare reason and NO command-specific prefix, so
# every caller that refuses a line refuses it with a byte-identical message.
cmd_check_status() {
  local status="" seen=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status)   status="${2:-}"; seen=1; shift 2 ;;
      --status=*) status="${1#--status=}"; seen=1; shift ;;
      --*) die "usage: check-status --status \"<line>\" (unknown option: $1)" ;;
      *)   die "usage: check-status --status \"<line>\" (unexpected argument: $1)" ;;
    esac
  done
  [ "$seen" = 1 ] && [ -n "$status" ] || die "usage: check-status --status \"<line>\""

  _rs_require_status_line "$status"
  printf 'STATUS_LINE=ok\n'
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
  # BEFORE anything reads or writes disk (T2): a refused line must leave no
  # result file at all -- not an empty one, not one carrying an off-grammar
  # first line a later reader would parse. Checking after the write would
  # still exit non-zero and still print the reason while leaving the file
  # behind, which is the wrong implementation this placement rules out.
  _rs_require_status_line "$status"
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

# --- the parsed-time key of $pkt's latest kind=start outcomes record --------
# Prints 0 when there is none, so every routing record counts. A kind=continue
# record is NOT a start and never moves this boundary: the driver's own
# continuation bookkeeping (`record-start --continue`) must reset neither the
# attempt count nor the continuation count it is subject to.
_rs_latest_start_key() {
  local pkt="$1" main_root="$2"
  local outcomes_dir="${main_root}/.agents/metrics/outcomes"
  local ts key best=0
  if [ -d "$outcomes_dir" ]; then
    while IFS= read -r ts; do
      [ -n "$ts" ] || continue
      key="$(_rs_ts_key "$ts")"
      if [ "$key" -gt "$best" ]; then best="$key"; fi
    done <<EOF
$(awk -v pkt="$pkt" "$_RS_ROUTE_FIELD_AWK"'
      { p = field($0, "packet"); if (p != pkt) next
        k = field($0, "kind");   if (k != "start") next
        ts = field($0, "ts");    if (ts != "") print ts }
    ' "$outcomes_dir"/*.jsonl 2>/dev/null)
EOF
  fi
  printf '%s' "$best"
}

# One JSON string-field extractor shared by the route counters below.
_RS_ROUTE_FIELD_AWK='
    function field(line, name,    pat, pos, rest, q) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      rest = substr(line, pos + length(pat))
      q = index(rest, "\"")
      if (q == 0) return ""
      return substr(rest, 1, q - 1)
    }'

# --- packet_continuations: the continuation cap per attempt -----------------
# implementer-continuation T3. Same token-scanning shape as
# _rs_implementer_turn_budget (T1): skip anything that is not purely digits,
# strip one matching pair of quotes from EACH token, and strip leading zeros so
# `00` reads as zero. Missing, invalid and zero all read as 3.
_rs_packet_continuations_limit() {
  local main_root="$1" ov v
  ov="${main_root}/.agents/project-overrides.yaml"
  v=""
  if [ -f "$ov" ]; then
    v="$(awk '
      /^packet_continuations:[[:space:]]*/ {
        line = $0
        sub(/^packet_continuations:[[:space:]]*/, "", line)
        n = split(line, a, " ")
        for (i = 1; i <= n; i++) {
          tok = a[i]
          gsub(/^"/, "", tok); gsub(/"$/, "", tok)
          gsub(/^'"'"'/, "", tok); gsub(/'"'"'$/, "", tok)
          if (tok ~ /^[0-9]+$/) { sub(/^0+/, "", tok); print tok; exit }
        }
      }
    ' "$ov" 2>/dev/null)"
  fi
  case "$v" in ''|0|*[!0-9]*) echo 3 ;; *) echo "$v" ;; esac
}

# --- continuations already routed for $pkt in its CURRENT attempt -----------
# Counts `continue` routing records for $pkt since the LATER of its latest
# kind=start outcomes record and its latest routing record whose action was
# `attempt`. Walking routing.jsonl in append order, a record before the start
# (parsed time, _rs_ts_key) is ignored and an `attempt` record resets the
# count, so each fresh attempt gets the full allowance. Windowing on the start
# alone would cap continuations per packet, not per attempt; windowing on any
# outcomes record would let `record-start --continue` reset the cap.
_rs_route_continuations() {
  local pkt="$1" main_root="$2" routing_file="$3"
  local start_key count=0 ts token action key
  start_key="$(_rs_latest_start_key "$pkt" "$main_root")"
  if [ -f "$routing_file" ]; then
    while IFS='|' read -r ts token action; do
      [ -n "$ts" ] || continue
      key="$(_rs_ts_key "$ts")"
      [ "$key" -ge "$start_key" ] || continue
      if [ "$action" = attempt ]; then count=0
      elif [ "$token" = continue ]; then count=$((count + 1)); fi
    done <<EOF
$(awk -v pkt="$pkt" "$_RS_ROUTE_FIELD_AWK"'
      { p = field($0, "packet"); if (p != pkt) next
        ts = field($0, "ts");    if (ts == "") next
        print ts "|" field($0, "token") "|" field($0, "action") }
    ' "$routing_file" 2>/dev/null)
EOF
  fi
  printf '%s' "$count"
}

# --- attempts already spent on $pkt since its latest kind=start record -----
# A kind=continue record deliberately does NOT move this boundary (the plan's
# own rule: "a continuation does not reset the count") — only a genuine new
# `start` does. fix and retry share ONE pool, since the PRD counts attempts
# from either route.
_rs_route_attempts() {
  local pkt="$1" main_root="$2" routing_file="$3"
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

  local latest_key
  latest_key="$(_rs_latest_start_key "$pkt" "$main_root")"

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
  # BEFORE the routing record is appended, and before anything else reads or
  # writes disk (T2). A check after the append still exits non-zero and still
  # prints the reason, but leaves routing.jsonl carrying a record for a line
  # the loop never routed on -- which run-digest would then report as a
  # decision that was made. `--status` is OPTIONAL here (every caller that
  # routes without a line omits it), so an absent/empty one is not a line and
  # is not checked; anything non-empty is.
  #
  # An `if`, never `[ -n "$status" ] && _rs_require_status_line …`: under the
  # `set -e` this file runs with, an `&&` list whose left side is false is a
  # failing statement, so the empty-status case would abort the whole call.
  if [ -n "$status" ]; then _rs_require_status_line "$status"; fi
  need_file "$f"
  _rs_check_pkt_id "$pkt"
  case "$token" in
    pass|fix|retry|escalate|reorder|append-task|hand-off-feature|ask-operator|continue) ;;
    *) die "route: token must be one of: pass fix retry escalate reorder append-task hand-off-feature ask-operator continue" ;;
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
    fix|retry|continue) attempts_before="$(_rs_route_attempts "$pkt" "$main_root" "$routing_file")" ;;
  esac

  # implementer-continuation T3: continuations are capped PER ATTEMPT, counted
  # before this call's own record is appended.
  local cont_cap="" conts_before=0
  if [ "$token" = continue ]; then
    cont_cap="$(_rs_packet_continuations_limit "$main_root")"
    conts_before="$(_rs_route_continuations "$pkt" "$main_root" "$routing_file")"
  fi

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
    # implementer-continuation T2: a continuation spends no attempt. ATTEMPTS=
    # is the LIVE count read above, printed as-is and never incremented, and
    # _rs_route_attempts counts only fix/retry tokens, so this record never
    # enters the shared attempt pool either -- otherwise three stops at the
    # turn budget would exhaust the packet's attempts without any review.
    # T3: past the per-attempt cap it refuses as `stop` -- never `attempt`,
    # never looped -- and the record below still carries action `stop`.
    continue)
      if [ $((conts_before + 1)) -le "$cont_cap" ]; then action=continue; else action=stop; fi
      ;;
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
  if [ "$token" = continue ] && [ "$action" = stop ]; then
    printf 'ACTION=stop\nATTEMPTS=%s\nLIMIT=%s\nquestion: continue was returned for packet %s past its continuation cap (%s per attempt) -- refusing to loop; a human must decide how to proceed\n' \
      "$attempts" "$limit" "$pkt" "$cont_cap"
    return 0
  fi
  printf 'ACTION=%s\nATTEMPTS=%s\nLIMIT=%s\n' "$action" "$attempts" "$limit"
}

# =============================================================================
# The decision log (escalation-decider T1)
# =============================================================================
# A THIRD append-only JSONL log, .agents/metrics/decisions/<session>.jsonl,
# holding what the escalation decider decided and what a periodic review did.
# It is deliberately neither of the two that already exist:
#
#   - NOT .agents/loop/<run_id>/ (where routing.jsonl lives). `begin-run`
#     prunes that directory to the current run plus the single newest other,
#     so a decision recorded there stops being readable two runs later — and
#     the audit these records exist for is exactly the question asked after
#     the fact.
#   - NOT .agents/metrics/outcomes/. `_rs_open_packets` classifies a record
#     there by FIELD SHAPE: any line carrying a `packet` and a NON-EMPTY
#     `kind` is a packet BOUNDARY (its `if (kind != "")` branch — it does not
#     test for the values `start`/`continue`). A decision record carrying both
#     would reopen a packet whose green outcome was already recorded;
#     `sweep-open` would then write it an `interrupted` terminal record, and
#     `run-digest` would report a packet nothing interrupted as interrupted.
#     ADR 0028 names that same trap for the driver-mode records.
#
# Both records here DO carry `kind` (`decision`/`review`), which is safe only
# because of where they are written. That is the point: the placement is the
# mechanism, not a filing preference.
#
# `run_id` is stamped into every record. This log is SESSION-keyed and a
# session outlives a run (begin-run mints `run_id` once and a resume keeps
# it), so without that field a reader could not separate this run's decisions
# from the previous run's — which is precisely what the routing.jsonl records
# get for free by living in the run directory, and what these give up by
# living outside it.

# --- append one line to the decision log ------------------------------------
# Mirrors _rs_append_outcomes_line/_rs_append_driver_mode_line rather than
# sharing with them: those two are called by shipped writers this task does not
# touch, and the only difference is the directory each bakes in. Same
# atomicity argument as both (one short line, O_APPEND, well under PIPE_BUF).
#
# CALLERS MUST INVOKE THIS IN AN `||` OR `if` CONTEXT, NEVER BARE — this file
# runs under `set -e`, which a bare `return 1` would turn into a hard exit,
# destroying the non-fatal RECORDED=no contract (the same warning
# _rs_append_outcomes_line carries, for the same reason).
_rs_append_decisions_line() {
  local sess="$1" line="$2"
  local main_root dir
  main_root="$(_rs_main_checkout_root)" || { printf 'RECORDED=no\nREASON=not-a-git-repo\n'; return 1; }
  dir="${main_root}/.agents/metrics/decisions"
  mkdir -p "$dir" 2>/dev/null || { printf 'RECORDED=no\nREASON=cannot-create-dir\n'; return 1; }
  printf '%s\n' "$line" >> "${dir}/${sess}.jsonl" 2>/dev/null \
    || { printf 'RECORDED=no\nREASON=cannot-append\n'; return 1; }
  return 0
}

# --- the run_id both commands stamp, validated the same way every other
# --- reader of run_id validates it (_rs_check_run_id) -----------------------
# Callers assign with `local x; x="$(...)"` on two lines, never
# `local x="$(...)"`, so a `die` in here propagates under `set -e` instead of
# being swallowed by the assignment's exit status (the trap documented on
# _rs_split_pkt_ids).
_rs_decision_run_id() {
  local f="$1" label="$2" run_id
  run_id="$(cmd_get "$f" run_id)"
  [ -n "$run_id" ] || die "${label}: run-state has no run_id (begin-run has not been called)"
  _rs_check_run_id "$run_id"
  printf '%s' "$run_id"
}

# --- a review count: a non-negative integer, or `unmeasured` ----------------
# `unmeasured` is accepted, and 0 is NOT its substitute: a review whose index
# bytes or counts could not be read must be able to say so, because 0 reads as
# a measurement that happens to be zero. Same `<n|unknown>` shape driver-mode
# `enter` already takes for --threshold.
_rs_check_review_count() {
  local opt="$1" v="$2"
  case "$v" in
    unmeasured) return 0 ;;
    ''|*[!0-9]*) die "record-review: ${opt} must be a non-negative integer or the literal 'unmeasured'" ;;
  esac
  return 0
}

_RS_RECORD_DECISION_USAGE="usage: record-decision <run-state> <packet-id> <reorder|append-task|retry|ask-operator|hand-off-feature> --trigger <name> [--finding <id>] [--summary <text>]"

cmd_record_decision() {
  local f="" pkt="" decision="" trigger="" finding="" summary="" pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --trigger)   [ $# -ge 2 ] || die "$_RS_RECORD_DECISION_USAGE"; trigger="$2"; shift 2 ;;
      --trigger=*) trigger="${1#--trigger=}"; shift ;;
      --finding)   [ $# -ge 2 ] || die "$_RS_RECORD_DECISION_USAGE"; finding="$2"; shift 2 ;;
      --finding=*) finding="${1#--finding=}"; shift ;;
      --summary)   [ $# -ge 2 ] || die "$_RS_RECORD_DECISION_USAGE"; summary="$2"; shift 2 ;;
      --summary=*) summary="${1#--summary=}"; shift ;;
      --*) die "$_RS_RECORD_DECISION_USAGE (unknown option: $1)" ;;
      *)
        case "$pos" in
          0) f="$1" ;;
          1) pkt="$1" ;;
          2) decision="$1" ;;
          *) die "$_RS_RECORD_DECISION_USAGE (too many arguments)" ;;
        esac
        pos=$((pos + 1)); shift ;;
    esac
  done
  # EVERY argument check runs before the record is built and before anything
  # touches disk -- the same ordering rule record-outcome/route follow, so a
  # refused call leaves the log byte-unchanged rather than recording a decision
  # that was never made.
  [ -n "$f" ] && [ -n "$pkt" ] && [ -n "$decision" ] || die "$_RS_RECORD_DECISION_USAGE"
  [ -n "$trigger" ] || die "$_RS_RECORD_DECISION_USAGE (--trigger is required: a decision with no trigger cannot be audited against the decider's trigger list)"
  need_file "$f"
  _rs_check_pkt_id "$pkt"
  case "$decision" in
    reorder|append-task|retry|ask-operator|hand-off-feature) ;;
    *) die "record-decision: decision must be one of: reorder append-task retry ask-operator hand-off-feature (pass/fix/escalate are reviewer verdicts that route TO the decider, not decisions it returns)" ;;
  esac
  # Same charset as cmd_add_finding's own check -- this names an entry in the
  # findings index whose body is <id>.md, so an id this file would refuse
  # there must not become readable here.
  if [ -n "$finding" ]; then
    case "$finding" in
      *[!a-zA-Z0-9._-]*) die "record-decision: finding id must be [a-zA-Z0-9._-] (it is a filename)" ;;
    esac
  fi

  local run_id; run_id="$(_rs_decision_run_id "$f" record-decision)"
  local sess="${CLAUDE_CODE_SESSION_ID:-adhoc}"
  _rs_check_session_id "$sess"

  # Escape once, then use the SAME escaped value for the JSON record and for
  # the printed KEY=value lines: an un-escaped newline in a trigger would both
  # produce invalid JSON (making `jq -s` drop every record in the file) and
  # split this command's own output into lines a caller would misread. The
  # consequence, deliberately accepted: what `TRIGGER=`/`FINDING=` print is the
  # record's OWN stored form (a `"` shows as `\"`), not the raw argument -- one
  # value, echoed exactly as recorded, rather than two that could disagree.
  local trigger_esc finding_esc summary_esc
  trigger_esc="$(_rs_json_escape "$trigger")"
  finding_esc="$(_rs_json_escape "$finding")"
  summary_esc="$(_rs_json_escape "$summary")"

  local line
  line="$(printf '{"ts":"%s","session":"%s","run_id":"%s","kind":"decision","packet":"%s","decision":"%s","trigger":"%s","finding":"%s","summary":"%s"}' \
    "$(_rs_now_ts)" "$sess" "$run_id" "$pkt" "$decision" "$trigger_esc" "$finding_esc" "$summary_esc")"
  _rs_append_decisions_line "$sess" "$line" || return 0
  printf 'RECORDED=yes\nPACKET=%s\nDECISION=%s\nTRIGGER=%s\nFINDING=%s\n' \
    "$pkt" "$decision" "$trigger_esc" "$finding_esc"
}

_RS_RECORD_REVIEW_USAGE="usage: record-review <run-state> --bytes-before <n|unmeasured> --bytes-after <n|unmeasured> --merged <n|unmeasured> --routed <n|unmeasured> --dropped <n|unmeasured>"

cmd_record_review() {
  local f="" before="" after="" merged="" routed="" dropped="" pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --bytes-before)   [ $# -ge 2 ] || die "$_RS_RECORD_REVIEW_USAGE"; before="$2"; shift 2 ;;
      --bytes-before=*) before="${1#--bytes-before=}"; shift ;;
      --bytes-after)    [ $# -ge 2 ] || die "$_RS_RECORD_REVIEW_USAGE"; after="$2"; shift 2 ;;
      --bytes-after=*)  after="${1#--bytes-after=}"; shift ;;
      --merged)         [ $# -ge 2 ] || die "$_RS_RECORD_REVIEW_USAGE"; merged="$2"; shift 2 ;;
      --merged=*)       merged="${1#--merged=}"; shift ;;
      --routed)         [ $# -ge 2 ] || die "$_RS_RECORD_REVIEW_USAGE"; routed="$2"; shift 2 ;;
      --routed=*)       routed="${1#--routed=}"; shift ;;
      --dropped)        [ $# -ge 2 ] || die "$_RS_RECORD_REVIEW_USAGE"; dropped="$2"; shift 2 ;;
      --dropped=*)      dropped="${1#--dropped=}"; shift ;;
      --*) die "$_RS_RECORD_REVIEW_USAGE (unknown option: $1)" ;;
      *)
        case "$pos" in
          0) f="$1" ;;
          *) die "$_RS_RECORD_REVIEW_USAGE (too many arguments)" ;;
        esac
        pos=$((pos + 1)); shift ;;
    esac
  done
  [ -n "$f" ] || die "$_RS_RECORD_REVIEW_USAGE"
  # All five are REQUIRED rather than defaulted: a review that omits a count
  # would otherwise record a 0 nobody measured, which is the one reading this
  # record must never support.
  [ -n "$before" ] && [ -n "$after" ] && [ -n "$merged" ] && [ -n "$routed" ] && [ -n "$dropped" ] \
    || die "$_RS_RECORD_REVIEW_USAGE (all five values are required -- an omitted count must not be recorded as 0)"
  need_file "$f"
  _rs_check_review_count --bytes-before "$before"
  _rs_check_review_count --bytes-after  "$after"
  _rs_check_review_count --merged       "$merged"
  _rs_check_review_count --routed       "$routed"
  _rs_check_review_count --dropped      "$dropped"

  local run_id; run_id="$(_rs_decision_run_id "$f" record-review)"
  local sess="${CLAUDE_CODE_SESSION_ID:-adhoc}"
  _rs_check_session_id "$sess"

  # No _rs_json_escape here and none needed: every one of the five has already
  # been reduced by _rs_check_review_count to digits or the literal
  # `unmeasured`, so there is nothing left that could escape the string.
  local line
  line="$(printf '{"ts":"%s","session":"%s","run_id":"%s","kind":"review","bytes_before":"%s","bytes_after":"%s","merged":"%s","routed":"%s","dropped":"%s"}' \
    "$(_rs_now_ts)" "$sess" "$run_id" "$before" "$after" "$merged" "$routed" "$dropped")"
  _rs_append_decisions_line "$sess" "$line" || return 0
  printf 'RECORDED=yes\nMERGED=%s\nROUTED=%s\nDROPPED=%s\nBYTES_BEFORE=%s\nBYTES_AFTER=%s\n' \
    "$merged" "$routed" "$dropped" "$before" "$after"
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

# --- run-digest: this run's completed periodic reviews, from the decision log
# --- (escalation-decider T7) ------------------------------------------------
# Prints one TSV row per `kind":"review"` record carrying THIS run's run_id,
# across EVERY session's log (a run spans sessions, so the glob is the whole
# directory -- the same whole-directory read _rs_digest_outcome makes, and for
# the same reason):
#   <ts>\t<merged>\t<routed>\t<dropped>\t<bytes_before>\t<bytes_after>
# The ts leads so the caller can apply --since with _rs_ts_key, which needs
# `date` and so cannot live in awk.
#
# The run_id filter is not optional bookkeeping. This log is SESSION-keyed and
# `begin-run` mints run_id once per run-state, so one session's log holds every
# run it drove; without the filter a resumed or second run would report the
# previous run's reviews as its own.
#
# The field_esc walk is a fourth verbatim copy of the one in
# _rs_digest_outcome/_rs_digest_latest_enter/cmd_run_digest rather than a
# shared constant: those three are shipped readers this task does not touch,
# and hoisting them into one global would rewrite three working functions to
# save a paste. Copying is this file's existing convention for it.
_rs_digest_reviews() {
  local main_root="$1" run_id="$2"
  local dir="${main_root}/.agents/metrics/decisions"
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
  awk -v want="$run_id" "$extract"'
    { k = field_esc($0, "kind");   if (k != "review") next
      r = field_esc($0, "run_id"); if (r != want) next
      ts = field_esc($0, "ts");    if (ts == "") next
      print ts "\t" field_esc($0, "merged") "\t" field_esc($0, "routed") \
        "\t" field_esc($0, "dropped") "\t" field_esc($0, "bytes_before") \
        "\t" field_esc($0, "bytes_after") }
  ' "$dir"/*.jsonl 2>/dev/null
}

# --- run-digest: the decision records a periodic review's routings COULD be
# --- (escalation-decider T16) -----------------------------------------------
# A review routes each finding with one `record-decision` call and then writes
# `record-review` as its LAST write (agents/chief-engineer.md §Periodic review,
# steps 3 and 6), so a review's routing records are the `decision` records of
# this run that precede its `review` record. This prints the candidates, one
# TSV row each, in read order:
#   <ts>\t<seq>\t<finding>\t<summary>
# <seq> is the record's position in the read (files in glob order, lines in
# file order) -- the tie-break when two records share a parsed time.
#
# A candidate is a `kind: decision` record carrying THIS run's run_id whose
# decision is `append-task` or `hand-off-feature` (the only two a review ever
# returns) and whose summary is EMPTY or opens with `review:`. The summary
# test is a narrowing, not the definition: a review's summary always opens
# with `review:`, so a non-empty summary that does not is an escalation's audit
# copy and can never be a review routing -- but an EMPTY one is kept, because a
# routing record written without --summary is still that routing's record and
# must still carry its finding id. The caller pairs candidates to reviews by
# time window.
#
# Tabs and newlines are already folded to spaces by _rs_json_escape on write;
# the gsub below only guards a hand-edited record, since a raw tab here would
# shift every later digest field.
_rs_digest_review_routing_candidates() {
  local main_root="$1" run_id="$2"
  local dir="${main_root}/.agents/metrics/decisions"
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
  awk -v want="$run_id" "$extract"'
    { k = field_esc($0, "kind");     if (k != "decision") next
      r = field_esc($0, "run_id");   if (r != want) next
      d = field_esc($0, "decision"); if (d != "append-task" && d != "hand-off-feature") next
      ts = field_esc($0, "ts");      if (ts == "") next
      s = field_esc($0, "summary")
      if (s != "" && index(s, "review:") != 1) next
      fid = field_esc($0, "finding")
      gsub(/[\t\r\n]/, " ", s); gsub(/[\t\r\n]/, " ", fid)
      seq++
      print ts "\t" seq "\t" fid "\t" s }
  ' "$dir"/*.jsonl 2>/dev/null
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

  # --- one line per completed periodic review recorded for THIS run, plus one
  # --- decision line per routing that review made (escalation-decider T7) ----
  # Read from .agents/metrics/decisions/, NOT from routing.jsonl: a periodic
  # review is not a packet escalation, so the driver never routes a token for
  # it and it leaves no routing record. The converse is what the `decision`
  # lines above rest on and is stated here because getting it wrong is silent:
  # only the `review` records in that log are a source of lines (T16 reads its
  # `decision` records solely to NAME a review's routing lines, below, and
  # never emits a line for one). Its `decision` records are
  # the decider's own audit copy of decisions the driver ALREADY routed, so
  # emitting a digest line from them too would report every packet decision
  # twice -- once from routing.jsonl and once from here -- and double the stop
  # report's 🔀 tally.
  #
  # Fields come off the row with `cut -f`, never `IFS=<tab> read`: bash treats
  # tab as IFS whitespace whatever IFS is set to, so adjacent tabs collapse and
  # one empty field shifts every later one left. A hand-edited record missing a
  # count produces exactly that empty field, and the same trap is already
  # documented at _rs_open_packets and at the enter line below.
  local rev_since_key=-1
  [ -n "$since" ] && rev_since_key="$(_rs_ts_key "$since")"
  local rev_row rev_ts rev_key rev_merged rev_routed rev_dropped rev_before rev_after rev_n
  # T16: every review's parsed time (ALL of this run's reviews, never
  # --since-scoped -- a review's window opens at the PREVIOUS review even when
  # that one is outside --since), and every candidate routing record keyed the
  # same way. Both are computed once, before the loop, since _rs_ts_key forks.
  local rev_all rev_keys="" rtg_rows="" c_row c_ts
  rev_all="$(_rs_digest_reviews "$main_root" "$run_id")"
  while IFS= read -r rev_row; do
    [ -n "$rev_row" ] || continue
    # Comma-joined, not newline-joined: BSD awk refuses a newline inside a
    # `-v` value ("newline in string").
    rev_keys="${rev_keys}$(_rs_ts_key "$(printf '%s' "$rev_row" | cut -f1)"),"
  done <<EOF
$rev_all
EOF
  while IFS= read -r c_row; do
    [ -n "$c_row" ] || continue
    c_ts="$(printf '%s' "$c_row" | cut -f1)"
    rtg_rows="${rtg_rows}$(_rs_ts_key "$c_ts")	${c_row#*	}
"
  done <<EOF
$(_rs_digest_review_routing_candidates "$main_root" "$run_id")
EOF
  while IFS= read -r rev_row; do
    [ -n "$rev_row" ] || continue
    rev_ts="$(printf '%s' "$rev_row" | cut -f1)"
    rev_key="$(_rs_ts_key "$rev_ts")"
    if [ -n "$since" ]; then
      [ "$rev_key" -ge "$rev_since_key" ] || continue
    fi
    rev_merged="$(printf '%s' "$rev_row" | cut -f2)"
    rev_routed="$(printf '%s' "$rev_row" | cut -f3)"
    rev_dropped="$(printf '%s' "$rev_row" | cut -f4)"
    rev_before="$(printf '%s' "$rev_row" | cut -f5)"
    rev_after="$(printf '%s' "$rev_row" | cut -f6)"
    printf 'review\t%s\t%s\t%s\t%s\t%s\n' \
      "$rev_merged" "$rev_routed" "$rev_dropped" "$rev_before" "$rev_after"
    # `routed` is re-validated HERE and not trusted from the record:
    # record-review only ever writes digits or `unmeasured`, but this reads a
    # file it did not write, and the value drives a loop. Anything that is not
    # a run of digits -- `unmeasured` above all -- yields NO decision lines,
    # because the number of routings is then unknown and a fabricated line is a
    # guess reported as a count. The `review` line above still carries the word
    # `unmeasured`, which is where a reader learns the count was not read.
    case "$rev_routed" in
      ''|*[!0-9]*) continue ;;
    esac
    # 10# so a leading zero is read as decimal, never octal; an absurdly long
    # digit run overflows to <= 0 and prints nothing rather than looping.
    rev_n=$((10#$rev_routed))
    [ "$rev_n" -gt 0 ] || continue
    # One line per routing, as before, and the COUNT still comes from the
    # review record, never from how many routing records were found (T7). What
    # T16 adds is the NAMES: the routed finding's id and the summary the review
    # wrote, taken from this review's routing records -- the candidates whose
    # parsed time is after the PREVIOUS review of this run and at or before
    # this one, the latest `routed` of them in (time, read order). Latest,
    # because the review writes its routings immediately before record-review,
    # so an escalation's append-task/hand-off-feature audit copy with an empty
    # summary, recorded earlier in the same window, is the one left out.
    # Fewer records than `routed` (a hand-edit, a record-decision that failed
    # to append) leaves the remaining lines with BOTH fields empty -- a routing
    # whose record could not be found is reported as unnamed, never given a
    # name borrowed from another record. A record with no --summary likewise
    # yields an empty summary field, never a fabricated one.
    #
    # Field 2 stays EMPTY: a review routes a FINDING, not a packet. See the
    # header -- there is no packet id to name here, and leaving the field empty
    # is what stops a renderer joining this line to a packet line. The finding
    # id and summary are fields 4 and 5, after the token, so every reader
    # keying on fields 1-3 (run-tally among them) reads the line unchanged.
    printf '%s' "$rtg_rows" | awk -F'\t' -v keys="$rev_keys" -v me="$rev_key" -v n="$rev_n" '
      BEGIN {
        lo = -1
        m = split(keys, ks, ",")
        for (i = 1; i <= m; i++) {
          if (ks[i] == "") continue
          k = ks[i] + 0
          if (k < me + 0 && k > lo) lo = k
        }
      }
      $1 != "" && ($1 + 0) > lo && ($1 + 0) <= (me + 0) { c++; kk[c] = $1 + 0; sq[c] = $2 + 0; fid[c] = $3; sm[c] = $4 }
      END {
        # insertion sort by (key, read order): a handful of rows per review
        for (i = 2; i <= c; i++) {
          j = i
          while (j > 1 && (kk[j-1] > kk[j] || (kk[j-1] == kk[j] && sq[j-1] > sq[j]))) {
            t = kk[j]; kk[j] = kk[j-1]; kk[j-1] = t
            t = sq[j]; sq[j] = sq[j-1]; sq[j-1] = t
            t = fid[j]; fid[j] = fid[j-1]; fid[j-1] = t
            t = sm[j]; sm[j] = sm[j-1]; sm[j-1] = t
            j--
          }
        }
        first = c - n + 1; if (first < 1) first = 1
        for (i = c + 1 - first + 1; i <= n; i++) printf "decision\t\treview-routing\t\t\n"
        for (i = first; i <= c; i++) printf "decision\t\treview-routing\t%s\t%s\n", fid[i], sm[i]
      }'
  done <<EOF
$rev_all
EOF

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

# --- run-tally: the four digest-derived tally figures, counted from the
# --- digest's own lines (report-render-conformance T1) ---------------------
# A separate subcommand, not a fifth digest line kind: every per-packet
# `run-digest --since` read would otherwise carry a count it has no use for,
# and a count beside --since-scoped decision lines would be ambiguous -- the
# dedup rule needs the WHOLE run's decisions. So this runs cmd_run_digest with
# no --since and counts in one awk pass. The digest is captured into a
# variable first (a failed assignment propagates run-digest's own die under
# `set -e`, so this dies exactly where it dies) and fed to awk by here-string,
# never a pipe. The 🔀 dedup is resolved in END, after every line is read, so
# it does not depend on the digest's (deliberately unordered) line order.
cmd_run_tally() {
  local f=""
  case $# in
    1) f="$1" ;;
    *) die "usage: run-tally <run-state>" ;;
  esac
  case "$f" in
    -*) die "usage: run-tally <run-state> (takes no options: $f)" ;;
  esac
  local digest
  digest="$(cmd_run_digest "$f")"
  # run-digest succeeded, so run_id, the run dir and the main checkout all
  # resolve here.
  local run_id rundir main_root live
  run_id="$(cmd_get "$f" run_id)"
  rundir="$(_rs_run_dir "$run_id" run-tally)"
  main_root="$(_rs_main_checkout_root)"
  live="$(_rs_tally_live_questions "${rundir}/routing.jsonl" "${main_root}/.agents/metrics/outcomes")"
  awk -F'\t' '
    $1 == "live" {
      if ($2 == "ask-operator") alive[$3]++
      else if ($2 == "retry") retry_live++
      next
    }
    $1 == "packet" {
      o = $4
      if (o == "green") shipped++
      else if (o == "failed" || o == "rolled-back") failed++
      else if (o == "blocked" || o == "interrupted" || o == "abandoned" || o == "open" || o == "paused") unfinished++
      next
    }
    $1 == "handoff-feature" { decisions++; hof[$2] = 1; next }
    # The routings of a periodic review count as decisions (escalation-decider
    # T7), counted directly: the line names no packet, so neither the hand-off
    # exclusion nor the liveness cap below has anything to join it on. Merges
    # and drops stay counts -- they arrive on the `review` line, which falls
    # through every rule here and is counted toward no figure.
    # (No apostrophes in this comment: the whole program is one single-quoted
    # shell word, and one would end it.)
    $1 == "decision" && $3 == "review-routing" { decisions++; next }
    $1 == "decision" && $3 == "hand-off-feature" { dec[++nd] = $2; next }
    $1 == "decision" && $3 == "ask-operator" { ask[$2]++; next }
    END {
      for (i = 1; i <= nd; i++) if (!(dec[i] in hof)) decisions++
      # One per ask-operator decision line still awaiting an answer: the
      # digest carries every question for the packet, the live lines say how
      # many of them are unanswered, so the smaller of the two counts.
      for (p in ask) {
        if (p in hof) continue
        n = (p in alive) ? alive[p] : 0
        decisions += (n < ask[p]) ? n : ask[p]
      }
      # One per still-live retry-past-limit stop, counted directly -- it is a
      # distinct question from any ask-operator/hand-off-feature line for the
      # same packet, so it is never hand-off-excluded or capped against a
      # digest count the way the ask-operator tally above is.
      decisions += retry_live
      printf "SHIPPED=%d\nFAILED=%d\nUNFINISHED=%d\nDECISIONS=%d\n", shipped, failed, unfinished, decisions
    }
  ' <<<"$(printf '%s\n%s' "$live" "$digest")"
}

# --- unanswered: filter (packet, ts, tag) question entries down to those
# --- with no later answering outcomes record (answered-question-expiry T1) --
# Reads `packet\tts\ttag` lines from stdin -- one caller's own questions,
# tagged however it likes -- and prints `live\t<tag>\t<packet>` for each still
# unanswered. Split out of the run-tally liveness rule below so a second
# caller (the pending_questions prune) can reuse the same answer rule against
# its own entries, tagged with a fixed tag, instead of duplicating the
# matching logic.
#
# An answer is, for the same packet, a `start` or `continue` record or an
# `abandoned` outcome whose _rs_ts_key is STRICTLY greater than the
# question's. A tie does not answer (fails toward over-reporting). A
# `blocked` outcome never answers: it is what /gaffer:pause records for the
# stop the question itself caused. Keys come from _rs_ts_key, never the raw
# string -- "...:08.311Z" sorts below "...:08Z". Liveness lives here and not
# in run-digest because a digest decision line carries no timestamp, and the
# digest's four line kinds are frozen.
_rs_unanswered_questions() {
  local outcomes_dir="$1"
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
  local keyed=() pkt ts tag
  while IFS="$(printf '\t')" read -r pkt ts tag; do
    [ -n "$pkt" ] || continue
    keyed+=("$(printf 'Q\t%s\t%s\t%s' "$pkt" "$(_rs_ts_key "$ts")" "$tag")")
  done
  local aline apkt ats
  while IFS="$(printf '\t')" read -r aline apkt ats; do
    [ -n "$aline" ] || continue
    keyed+=("$(printf '%s\t%s\t%s\t' "$aline" "$apkt" "$(_rs_ts_key "$ats")")")
  done <<EOF
$(awk "$extract"'
    { p = field_esc($0, "packet"); ts = field_esc($0, "ts")
      if (p == "" || ts == "") next
      k = field_esc($0, "kind"); o = field_esc($0, "outcome")
      if (k == "start" || k == "continue" || o == "abandoned") print "A\t" p "\t" ts }
  ' "$outcomes_dir"/*.jsonl 2>/dev/null)
EOF
  [ "${#keyed[@]}" -gt 0 ] || return 0
  printf '%s\n' "${keyed[@]}" | awk -F'\t' '
    { n++; type[n] = $1; pkt[n] = $2; key[n] = $3 + 0; tag[n] = $4 }
    END {
      for (i = 1; i <= n; i++) {
        if (type[i] != "Q") continue
        answered = 0
        for (j = 1; j <= n; j++)
          if (type[j] == "A" && pkt[j] == pkt[i] && key[j] > key[i]) { answered = 1; break }
        if (!answered) print "live\t" tag[i] "\t" pkt[i]
      }
    }'
}

# --- run-tally: which questions are still awaiting an answer
# --- (stop-report-decision-liveness T1, extended by answered-question-expiry
# --- T1) ---------------------------------------------------------------------
# Feeds `_rs_unanswered_questions` from `routing.jsonl`: every `ask-operator`
# record, tagged `ask-operator`, plus every `retry` record routed `stop` (past
# its attempt limit), tagged `retry` -- the record's own token, so a caller
# splits the two counts apart by tag. Prints `live\t<tag>\t<packet>` for each
# still-unanswered one; see `_rs_unanswered_questions` for the answer rule.
_rs_tally_live_questions() {
  local routing_file="$1" outcomes_dir="$2"
  [ -f "$routing_file" ] || return 0
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
  awk "$extract"'
    { t = field_esc($0, "token"); a = field_esc($0, "action")
      if (t == "ask-operator") tag = "ask-operator"
      else if (t == "retry" && a == "stop") tag = "retry"
      else next
      p = field_esc($0, "packet"); ts = field_esc($0, "ts")
      if (p != "" && ts != "") print p "\t" ts "\t" tag }
  ' "$routing_file" 2>/dev/null | _rs_unanswered_questions "$outcomes_dir"
}

# --- prune-questions: drop answered entries from pending_questions: ---------
# --- (answered-question-expiry T2) -------------------------------------------
# Same liveness rule as run-tally's header 🔀 figure (_rs_unanswered_questions),
# applied to the OTHER source that renders a decision block: run-state's
# `pending_questions:` list. Without this, a run that resumes, answers a
# question and stops a second time keeps rendering a block for the answered
# question forever -- the header/body mismatch report-lint's decision-count
# rule exists to catch.
#
# Parses ONLY the documented block-entry shape (`  - id: ...` followed by
# indented sibling keys, one of them `packet:`, one `asked_at:`). A list in
# any other shape -- a legacy plain-scalar list, a flow list, anything mixing
# non-`- id:` items in -- is left byte-untouched: guessing at an unrecognized
# shape risks silently dropping a question a human still needs to answer,
# which is the one thing this subcommand must never do.
#
# An entry with no `packet:` line or no `asked_at:` line at all (legacy,
# crash-recovered, or hand-supplied) is ALWAYS kept -- it never reaches the
# liveness helper, so it fails toward over-reporting exactly like an unknown
# packet does in `findings --stale`.
_rs_pending_extract() {
  awk '
    BEGIN { inq = 0; block = 0; other = 0; n = 0; hp = 0; ha = 0; pkt = ""; asked = "" }
    /^pending_questions:[[:space:]]*$/ { inq = 1; block = 1; next }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { inq = 0 }
    inq && /^[[:space:]]*-/ && $0 !~ /^[[:space:]]*- id:/ { other = 1 }
    inq && /^[[:space:]]*- id:/ {
      if (n > 0) print "E\t" n "\t" hp "\t" ha "\t" pkt "\t" asked
      n++; hp = 0; ha = 0; pkt = ""; asked = ""
      next
    }
    inq && /^[[:space:]]*packet:/ {
      line = $0; sub(/^[[:space:]]*packet:[[:space:]]*/, "", line); pkt = line; hp = 1; next
    }
    inq && /^[[:space:]]*asked_at:/ {
      line = $0; sub(/^[[:space:]]*asked_at:[[:space:]]*/, "", line); asked = line; ha = 1; next
    }
    END {
      if (n > 0) print "E\t" n "\t" hp "\t" ha "\t" pkt "\t" asked
      print "S\t" block "\t" other "\t" n
    }
  ' "$1"
}

cmd_prune_questions() {
  local f="${1:-}"
  [ -n "$f" ] && [ "$#" -eq 1 ] || die "usage: prune-questions <run-state>"
  need_file "$f"

  local raw
  raw="$(_rs_pending_extract "$f")"

  local block other total
  block="$(awk -F'\t' '$1 == "S" { print $2 }' <<<"$raw")"
  other="$(awk -F'\t' '$1 == "S" { print $3 }' <<<"$raw")"
  total="$(awk -F'\t' '$1 == "S" { print $4 }' <<<"$raw")"

  # No block at all, an unrecognized shape, or a recognized-but-empty list:
  # nothing this subcommand can safely act on. Untouched, not even opened for
  # write.
  if [ "$block" != 1 ] || [ "$other" = 1 ] || [ "${total:-0}" = 0 ]; then
    printf 'PRUNED=no\nDROPPED=0\n'
    return 0
  fi

  local main_root outcomes_dir
  main_root="$(_rs_main_checkout_root)" || die "prune-questions: not a git repo"
  outcomes_dir="${main_root}/.agents/metrics/outcomes"

  # keep_always/feed_idx are comma-bounded sets (",1,3,"), same convention as
  # _normalize_id_list above -- membership is a literal `*",$idx,"*` match,
  # never a regex, since an idx is a plain integer with no metacharacters at
  # stake, but consistency with the rest of this file's id-set handling still
  # matters here.
  local keep_always="," feed_idx="," feed=""
  local tag idx hp ha pkt_raw asked_raw pkt asked
  while IFS="$(printf '\t')" read -r tag idx hp ha pkt_raw asked_raw; do
    [ "$tag" = "E" ] || continue
    if [ "$hp" != 1 ] || [ "$ha" != 1 ]; then
      keep_always="${keep_always}${idx},"
      continue
    fi
    pkt="$(_yaml_decode_value "$pkt_raw")"
    asked="$(_yaml_decode_value "$asked_raw")"
    # Keep-always is decided on the decoded VALUES too, not just the key lines:
    # the helper skips an empty-packet row (never echoed live) and _rs_ts_key
    # reads an empty or unparseable stamp as 0 (so ANY later record answers
    # it) -- either way "not reported live" would read as "answered" and drop
    # a question a human may still owe an answer to.
    if [ -z "$pkt" ] || [ -z "$asked" ] || [ "$(_rs_ts_key "$asked")" = 0 ]; then
      keep_always="${keep_always}${idx},"
      continue
    fi
    feed_idx="${feed_idx}${idx},"
    # NOT `feed="${feed}$(printf ...)"` -- command substitution strips ALL
    # trailing newlines, so successive appends would run two entries
    # together onto one line and corrupt the packet/ts/tag split downstream.
    # ANSI-C quoting embeds a literal tab/newline with no subshell involved.
    feed="${feed}${pkt}"$'\t'"${asked}"$'\t'"${idx}"$'\n'
  done <<<"$raw"

  local live="" live_csv="," tagf pktf
  if [ -n "$feed" ]; then
    live="$(printf '%s' "$feed" | _rs_unanswered_questions "$outcomes_dir")"
    while IFS="$(printf '\t')" read -r _ tagf pktf; do
      [ -n "$tagf" ] || continue
      live_csv="${live_csv}${tagf},"
    done <<<"$live"
  fi

  # Dropped = fed (had both packet: and asked_at:) but NOT reported live --
  # i.e. answered. Everything else (keep_always, or fed-and-still-live) is
  # kept, in original order, by simply never being named in dropped_csv.
  local dropped_csv="," dropped_count=0 i=1
  while [ "$i" -le "$total" ]; do
    case "$feed_idx" in
      *",${i},"*)
        case "$live_csv" in
          *",${i},"*) : ;;
          *) dropped_csv="${dropped_csv}${i},"; dropped_count=$((dropped_count + 1)) ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done

  if [ "$dropped_count" -eq 0 ]; then
    printf 'PRUNED=no\nDROPPED=0\n'
    return 0
  fi

  # Same skip-while-inside-the-entry technique as cmd_drop_finding's rebuild
  # awk above, generalized from one target id to a whole dropped-index set.
  # `skip` persists across every indented sibling line of a dropped entry
  # (severity:/question:/asked_at:/anything else) until the next `- id:` line
  # or the block's end resets it -- so a dropped entry's WHOLE block goes,
  # never just its header line.
  local new_content
  new_content="$(DROP="$dropped_csv" awk '
    /^pending_questions:[[:space:]]*$/ { print; inq = 1; n = 0; next }
    inq && /^[A-Za-z_][A-Za-z0-9_]*:/ { inq = 0; skip = 0; print; next }
    inq && /^[[:space:]]*- id:/ {
      n++
      skip = (index(ENVIRON["DROP"], "," n ",") > 0) ? 1 : 0
      if (!skip) print
      next
    }
    inq && skip { next }
    { print }
  ' "$f")"

  printf '%s\n' "$new_content" | cmd_write "$f"
  printf 'PRUNED=yes\nDROPPED=%d\nKEPT=%d\n' "$dropped_count" "$((total - dropped_count))"
}

# --- reorder-pending: replace backlog.pending with a given order ------------
# --- (escalation-decider T3) --------------------------------------------------
# `reorder` is the one decider decision that is a WRITE rather than a question,
# and `backlog.pending` is where it lands. It cannot go through `set`:
# `pending` lives INSIDE `backlog:`, which is exactly the `nested-only` shape
# `_set_target_shape` refuses (and refuses for a reason -- before that refusal
# existed, `set` appended a SECOND, column-0 key while every reader kept reading
# the nested one: exit 0, two sources of truth, no signal). So this subcommand
# rewrites the block in place and hands the WHOLE file to `cmd_write`, which is
# the only validated write path in this file (structural check + the
# last-known-good `run-state-prev.yaml` copy).
#
# WHAT IT REFUSES, and each refusal leaves the file byte-identical because the
# decision is made before anything is written:
#   - an empty id list (a reorder to nothing is a `pending` delete, not a
#     reorder -- if that is ever wanted it is a different subcommand)
#   - a repeated id (silently de-duplicating, as `_normalize_id_list` does for
#     `--packets` membership tests, would accept an order the caller did not
#     ask for and report a `REMOVED=` that never happened)
#   - an id outside [a-zA-Z0-9._-] (written bare into the list; see below)
#   - no `pending:` key at all, or MORE THAN ONE -- two of them is the
#     two-sources-of-truth corruption this subcommand exists not to create, and
#     guessing which one the readers use would entrench it
#   - a `pending:` carrying a value on its own line (a flow list `[a, b]`), or a
#     block holding any line that is not `- <id>` -- the same rule
#     `prune-questions` follows for an unrecognized shape: refuse to act rather
#     than rewrite something this parser does not actually understand
#
# BOTH INDENT STYLES of the block list are rewritten in place, and in their own
# style: items indented under the key (what `templates/run-state.yaml` ships)
# and items LEVEL WITH the key (what `yaml.safe_dump` emits by default, and what
# `cmd_summary` and `_findings_pending_ids` have always read). A run-state whose
# `pending:` sits at COLUMN 0 with column-0 items parses as YAML but is refused
# on write, by `_write_check`: a column-0 `- b` is not a `key:` line, so the
# whole FILE is a shape `cmd_write` declines wherever it came from. That is a
# loud rc=1 leaving the file byte-identical, not a silent rewrite, and it is not
# a run-state shape -- `pending` is nested under `backlog:` in every file this
# loop writes.
#
# IDS ARE WRITTEN BARE, deliberately, and this is NOT a reintroduction of the
# plain-scalar allowlist `_yaml_encode_value` documents and rejects. That
# allowlist was a claim about arbitrary future VALUES; these are ids already
# constrained to [a-zA-Z0-9._-] (no `:`, no leading `-`, no quote), the shape
# `templates/run-state.yaml` writes and the shape `_findings_pending_ids` and
# `cmd_summary` read RAW -- quoting them here would make `findings --stale`
# compare `'pkt-1'` against `pkt-1` and read every pending packet as unknown.
# Existing entries are DECODED on read, so a quoted entry left by a hand edit
# is recognized rather than reported as removed-and-re-added.
#
# An existing item's TRAILING `# comment` is read as part of its id, so
# `- b   # why` reports `REMOVED=b   # why` against an `ADDED=b`. That is the
# same raw read `_findings_pending_ids` and `cmd_summary` already do -- a
# pre-existing convention of this list, not a rule this subcommand introduces --
# and it costs only report noise: the rewritten list carries the validated ids
# and the comment does not survive, which is the same thing a hand reorder does.
#
# _rs_pending_block <file> -- one TSV record per line, for the shell below:
#   KEYS  <n>                  lines matching ^\s*pending: (any indent)
#   START <line> <indent> <rest-after-the-colon>
#   ITEM  <line> <indent-width> <raw value>   width as a COUNT, never the
#                                    leading whitespace itself: the shell below
#                                    reads these with tab as IFS, and tab is IFS
#                                    WHITESPACE, so an EMPTY indent field (an
#                                    item at column 0, reachable now that an
#                                    item level with its key is admitted) is
#                                    collapsed with its neighbour and the id
#                                    lands in the indent variable. A count is
#                                    never empty. Same reason `_rs_pending_block`
#                                    reconstructs it with `printf '%*s'`, which
#                                    is what the no-item fallback already did.
#   BAD   <line> <line text>   a line inside the block this parser cannot read
#   END   <line>               last line of the block (after trailing blanks)
# Emits KEYS alone when there is not exactly one `pending:` key.
_rs_pending_block() {
  awk '
    { lines[NR] = $0 }
    /^[[:space:]]*pending:/ { keys++; if (keys == 1) start = NR }
    END {
      print "KEYS\t" keys + 0
      if (keys != 1) exit 0
      line = lines[start]
      ki = match(line, /[^[:space:]]/) - 1
      rest = line; sub(/^[[:space:]]*pending:/, "", rest)
      print "START\t" start "\t" ki "\t" rest
      # The block runs to the first non-blank line indented no deeper than the
      # key (a sibling key, or any column-0 key), or to EOF. A COMMENT-ONLY line
      # is skipped like a blank one whatever its indent, and that is load-bearing
      # rather than tidy: a comment is legal at ANY column in YAML and carries no
      # structure, so ending the block on a column-0 one left every item after it
      # in place while the rewritten order was inserted above -- rc=0,
      # `REORDERED=yes`, and a `pending` that parses with a DUPLICATE id, which is
      # the one thing the `seen` check below refuses to write. Skipping it instead
      # sends that item into the BAD branch, so the shape is refused and the file
      # is left byte-identical.
      # A `- ` line AT THE INDENT OF THE KEY ITSELF is an item of this list, not
      # a sibling key, and it is the same silent-wrong class as the comment
      # above: YAML permits a block sequence level with its parent mapping key,
      # a mapping cannot have sequence entries as children, and this is the
      # shape `yaml.safe_dump` emits BY DEFAULT -- so it is what a hand edit
      # through a YAML library leaves behind. `cmd_summary` and
      # `_findings_pending_ids` already read it (neither tests indent), so every
      # other subcommand treats such a file as valid. Ending the block on it
      # left `end` at `start`: no ITEM records, an empty `old_csv`, the new
      # order inserted under the key and no old item skipped -- rc=0,
      # `REORDERED=yes`, `ADDED=` naming ids that were already pending, and a
      # file that no longer PARSES AT ALL, written by the one subcommand whose
      # reason for existing is to avoid a silent-wrong write.
      #
      # `-` followed by a space or end-of-line, deliberately not a bare `-`
      # prefix: `- b` is unambiguously a sequence entry, while `-foo: bar` is a
      # legal mapping key that merely starts with a dash, and continuing past
      # THAT would read a sibling key as an item and delete it. The cost of the
      # narrow test is that `-b` (no space, not a sequence entry in YAML, so
      # only reachable in a file that already does not parse) still ends the
      # block early; a file no parser accepts cannot be rewritten safely either
      # way, and that shape is reported as unchanged rather than claimed fixed.
      end = NR
      for (i = start + 1; i <= NR; i++) {
        if (lines[i] ~ /^[[:space:]]*$/) continue
        if (lines[i] ~ /^[[:space:]]*#/) continue
        ind = match(lines[i], /[^[:space:]]/) - 1
        if (ind == ki && lines[i] ~ /^[[:space:]]*-([[:space:]]|$)/) continue
        if (ind <= ki) { end = i - 1; break }
      }
      # Trailing blank AND comment lines belong to whatever follows, not to the
      # list: leave them in place so a blank separator, or the column-0 comment
      # block `templates/run-state.yaml` ships between `pending` and
      # `pending_questions:`, survives the rewrite untouched.
      while (end > start && lines[end] ~ /^[[:space:]]*(#.*)?$/) end--
      for (i = start + 1; i <= end; i++) {
        l = lines[i]
        if (l ~ /^[[:space:]]*-[[:space:]]*[^[:space:]]/) {
          v = l; sub(/^[[:space:]]*-[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
          print "ITEM\t" i "\t" (index(l, "-") - 1) "\t" v
        } else {
          print "BAD\t" i "\t" l
        }
      }
      print "END\t" end
    }
  ' "$1"
}

cmd_reorder_pending() {
  local f="${1:-}" raw="${2:-}"
  # `$# -eq 2` rather than `-n "$raw"`: an explicitly empty order is a real
  # call with a bad argument, and it earns the empty-list refusal below by name
  # rather than a usage line that says the argument was missing.
  [ -n "$f" ] && [ "$#" -eq 2 ] \
    || die "usage: reorder-pending <run-state> <id[,id...]>"
  need_file "$f"

  # --- the requested order: validated, never de-duplicated silently ----------
  local new_csv="" seen="," id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!a-zA-Z0-9._-]*)
        die "reorder-pending: packet id '${id}' must be [a-zA-Z0-9._-] (it is written bare into the pending list)" ;;
    esac
    case "$seen" in
      *",${id},"*)
        die "reorder-pending: '${id}' appears more than once in the requested order -- refusing rather than de-duplicating, since the surviving order would not be the one asked for; run-state is left unchanged" ;;
    esac
    seen="${seen}${id},"
    new_csv="${new_csv:+${new_csv},}${id}"
  done <<EOF
$(_split_ids "$raw")
EOF
  [ -n "$new_csv" ] || die "reorder-pending: the requested order is empty -- a reorder to nothing would delete the backlog, not reorder it; run-state is left unchanged"

  # --- locate the block ------------------------------------------------------
  local blk keys start key_ind key_rest end
  blk="$(_rs_pending_block "$f")"
  keys="$(awk -F'\t' '$1 == "KEYS" { print $2 }' <<<"$blk")"
  if [ "${keys:-0}" = 0 ]; then
    die "reorder-pending: no 'pending:' key in '${f}' -- this subcommand replaces an existing backlog.pending list and will not create one; write the whole file with \`write\` instead"
  fi
  if [ "${keys:-0}" != 1 ]; then
    die "reorder-pending: '${f}' carries ${keys} 'pending:' keys -- that is already two sources of truth, and rewriting one of them would entrench it; repair the file with \`write\` first"
  fi
  start="$(awk -F'\t' '$1 == "START" { print $2 }' <<<"$blk")"
  key_ind="$(awk -F'\t' '$1 == "START" { print $3 }' <<<"$blk")"
  key_rest="$(awk -F'\t' '$1 == "START" { print $4 }' <<<"$blk")"
  end="$(awk -F'\t' '$1 == "END" { print $2 }' <<<"$blk")"

  # A value on the key line is a flow list (or a scalar) -- a shape this
  # parser does not write and must not half-rewrite. A trailing comment is
  # fine: templates/run-state.yaml ships one on this very line.
  local rest_stripped
  rest_stripped="$(printf '%s' "$key_rest" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$rest_stripped" in
    ''|'#'*) : ;;
    *) die "reorder-pending: 'pending:' carries a value on its own line ('${rest_stripped}') -- only an indented '- <id>' list is rewritten here; run-state is left unchanged" ;;
  esac

  local bad
  bad="$(awk -F'\t' '$1 == "BAD" { print $2 ": " $3; exit }' <<<"$blk")"
  [ -z "$bad" ] || die "reorder-pending: line ${bad%%:*} inside the pending block is not a '- <id>' item -- refusing to rewrite a list shape this parser does not understand; run-state is left unchanged"

  # --- what was there before, decoded ----------------------------------------
  # `item_ind_seen` and not `[ -n "$item_ind" ]`: an item at column 0 has a
  # width of 0, whose reconstructed indent is the empty string, so testing the
  # indent itself would read "column 0" as "no items at all" and fall through to
  # the key+2 default -- re-indenting a list the caller only asked to reorder.
  local old_csv="" item_ind="" item_ind_seen="" ind v
  while IFS="$(printf '\t')" read -r _ _ ind v; do
    [ -n "$ind$v" ] || continue
    [ -n "$item_ind_seen" ] || { item_ind_seen=y; item_ind="$(printf '%*s' "$ind" '')"; }
    v="$(_yaml_decode_value "$v")"
    old_csv="${old_csv:+${old_csv},}${v}"
  done <<<"$(awk -F'\t' '$1 == "ITEM"' <<<"$blk")"
  # No existing item to copy an indentation from: one level in from the key,
  # which is what templates/run-state.yaml uses.
  [ -n "$item_ind_seen" ] || item_ind="$(printf '%*s' "$((key_ind + 2))" '')"

  # --- added / removed, reported in the requested order then the old order ---
  local added="" removed="" old_set="," new_set=","
  local IFS_SAVE="$IFS"
  # `set -f` for the duration: these loops word-split on `,` UNQUOTED, which is
  # how the split is done at all, and that leaves globbing on. `new_csv` is
  # charset-validated above, but the OLD ids come off disk unvalidated -- an
  # entry a hand edit left as `- "*"` expanded to the working directory's
  # listing, so `REMOVED=` reported thirteen filenames instead of the one id.
  # The written file was still right (only `new_csv` reaches the rebuild); the
  # REPORT was wrong, and the report is what a caller acts on.
  set -f
  IFS=','
  for id in $old_csv; do [ -n "$id" ] && old_set="${old_set}${id},"; done
  for id in $new_csv; do new_set="${new_set}${id},"; done
  for id in $new_csv; do
    case "$old_set" in *",${id},"*) : ;; *) added="${added:+${added},}${id}" ;; esac
  done
  for id in $old_csv; do
    [ -n "$id" ] || continue
    case "$new_set" in *",${id},"*) : ;; *) removed="${removed:+${removed},}${id}" ;; esac
  done
  IFS="$IFS_SAVE"
  set +f

  if [ "$new_csv" = "$old_csv" ]; then
    printf 'REORDERED=no\nPENDING=%s\nADDED=\nREMOVED=\n' "$new_csv"
    return 0
  fi

  # --- rebuild: everything outside the block byte-for-byte ------------------
  local items="" new_content
  IFS=','
  for id in $new_csv; do items="${items}${item_ind}- ${id}"$'\n'; done
  IFS="$IFS_SAVE"

  new_content="$(ITEMS="$items" awk -v s="$start" -v e="$end" '
    NR == s { print; printf "%s", ENVIRON["ITEMS"]; next }
    NR > s && NR <= e { next }
    { print }
  ' "$f")"

  printf '%s\n' "$new_content" | cmd_write "$f"
  printf 'REORDERED=yes\nPENDING=%s\nADDED=%s\nREMOVED=%s\n' "$new_csv" "$added" "$removed"
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
# The reason is an arbitrary human/agent string arriving as an argument -- the
# same class of value cmd_set and cmd_add_finding take -- so it goes through the
# SAME _yaml_encode_value (runstate-write-integrity-gaps T5). Before this, it was
# the last write path in the file that composed a YAML line by hand: a reason
# reading `blocked on the commit: the harness denied it` wrote a second mapping
# key into the sentinel, and one carrying a newline wrote a whole second line
# that the readers below would then treat as the file's next key. The sentinel is
# smaller and more disposable than run-state, but it is read by two independent
# parsers (cmd_pause_status here, hooks/pause-check.sh's own grep), and "the
# value is usually harmless" is exactly the reasoning the parent feature removed.
# Both readers strip the encoding symmetrically, so `PAUSE=1 reason=<bare>` and
# the hook's advisory are unchanged in shape for every existing caller.
cmd_request_pause() {
  local f="${1:-}" reason="${2:-}"
  [ -n "$f" ] || die "usage: request-pause <pause-file> [reason]"
  local dir tmp; dir="$(dirname "$f")"
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.pause.XXXXXX")" || die "cannot create temp file in ${dir}"
  {
    printf 'requested_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -n "$reason" ] && printf 'reason: %s\n' "$(_yaml_encode_value "$reason")"
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
#
# The reason is unwrapped with _yaml_decode_value -- THE shared decode rule, the
# same one cmd_get and cmd_cursor use (runstate-write-integrity-gaps T5), so the
# encoding cmd_request_pause now writes is invisible here and the output shape
# stays exactly `PAUSE=1 reason=<bare>` for every existing caller. Its bare
# branch is what keeps a sentinel written by an OLDER version -- `reason: night`,
# unquoted -- reading correctly with no flag day, the same reader's-job
# compatibility the parent feature chose for run-state.
#
# `|| true` on the extraction: grep exits 1 when the sentinel carries no
# `reason:` line at all (an ordinary `request-pause <file>` with no reason), and
# under this file's `set -euo pipefail` that non-zero pipeline status aborted the
# whole command substitution -- so pause-status printed NOTHING and exited 1 on a
# perfectly legitimate sentinel, contradicting both the "always exits 0" contract
# above and the `<none>` fallback below, which was unreachable until now.
cmd_pause_status() {
  local f="${1:-}" r
  [ -n "$f" ] || die "usage: pause-status <pause-file>"
  if [ -f "$f" ]; then
    r="$(grep -E '^reason:' "$f" 2>/dev/null | head -1 | sed -E 's/^reason:[[:space:]]*//' || true)"
    r="$(_yaml_decode_value "$r")"
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
  local wt="$1" combined="" pat extra listing
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
  # -z (NUL-delimited, never quoted) instead of the default porcelain form, to
  # sidestep `git status --porcelain`'s C-quoting of paths with a space or a
  # non-ASCII byte -- quoted, the leading `"` would never match a pattern
  # anchored on `^` or `/` -- at the cost of losing the `old -> new` rename
  # separator, which `-z` never emits anyway (a rename is two separate
  # NUL-terminated fields, old path then new path; the old path's first three
  # bytes get stripped by the same `^.{3}` rule, which is harmless since
  # matching is ANY and the new path is judged correctly).
  #
  # THE LISTING IS CAPTURED FIRST, AND grep READS IT FROM A HERE-STRING -- grep
  # is deliberately NOT the reader of a pipe (grep-devnull-condition T1). Under
  # `set -euo pipefail`, a reader that stops early closes the pipe, `git
  # status`/`sed` -- still writing on a large dirty tree -- take SIGPIPE, the
  # pipeline reports 141, and this function reads that as "no match" and falls
  # back to `discard`, stashing unreviewed work away. `grep -q` did exactly
  # that (thin-loop-driver-gaps T3), and the `grep -E ... >/dev/null` written
  # to replace it was assumed to do the same under GNU grep. MEASURED, IT DOES
  # NOT (grep-devnull-condition T1 review, 2026-09-19; Linux aarch64
  # containers, GNU grep 3.8 and 3.11, bash 5.2, a 414 KB listing, 20 runs
  # each): the redirect form misfired 0/20 and the pre-change function
  # escalated 20/20, while the pipe-fed `-q` form misfired 20/20 with rc 141.
  # GNU grep stops SCANNING on a null stdout but drains a non-seekable stdin
  # before it exits, so the writer never takes SIGPIPE; only `-q` skips that
  # drain. The redirect is replaced anyway: its safety rests on an
  # undocumented courtesy of one implementation, and it is one keystroke from
  # `-q`. Same SIGPIPE-under-pipefail shape as the `trim-note` history
  # elsewhere in this file.
  #
  # With no pipe feeding grep there is nothing left to take SIGPIPE, so `-q` is
  # correct again here and is the right thing to write: the producers have
  # already finished (the command substitution waits for them, and pipefail
  # still reports a `git status` failure through `|| return 1`, which keeps the
  # never-fails, reads-false contract), and grep's only input is a here-string
  # the shell has already materialised. So DO NOT restore the `>/dev/null`
  # redirect, and DO NOT "simplify" this back into `git status | ... | grep`:
  # the pipe-fed form is the hazard, and `-q` on it re-arms the bug on every
  # grep tested.
  #
  # Holding the whole listing in one variable is the deliberate cost of that.
  # A dirty tree big enough to matter here is a few hundred KB of paths (the
  # sweep's fixture is ~400 KB), which is nothing against correctness on the
  # one decision that can sweep away work a human has not reviewed.
  listing="$(git -C "$wt" status --porcelain --untracked-files=all -z \
    | tr '\0' '\n' \
    | sed -E 's/^.{3}//')" || return 1
  grep -qE "$combined" <<<"$listing"
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
#
# RECORDED, NOT CLOSED (next-state-reporting-integrity T2). This is the one
# pipe-fed `grep` in this file that is deliberately left as a pipeline, and the
# two facts that make that safe are both stated here so a later reader auditing
# the `printf … | grep -q` shape does not convert a working value-producing
# pipeline into something else:
#   1. Its VALUE still reaches standard output correctly. This pipeline is not
#      condition-shaped — the answer is the text `head -1 | sed` prints, not an
#      exit status — and `grep -oE` has no `-q`, so nothing here exits before its
#      writer finishes for the reason the rest of this feature is about.
#   2. Its EXIT STATUS is already discarded by the trailing `|| true`. So even a
#      `pipefail`-polluted status (a no-match grep returning 1, or `head -1`
#      closing early on a multi-trailer body) cannot reach the caller, which is
#      exactly what the "never fails" contract above depends on.
# Rewriting it as a here-string would change neither fact and would lose the
# streaming `head -1`; leave it alone.
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
#
# Every field it returns is unwrapped by rs_decode from _YAML_AWK_DECODE
# (defined with _yaml_decode_value, above cmd_set) — the one decode rule, not a
# copy of it maintained here (runstate-write-integrity-gaps T4). This site used
# to strip a double-quoted pair only, because that is the shape the retired
# parallel scheduler wrote; migrating widens it to the SINGLE-quoted shape the
# encoder produces today, so a lane row touched by any current writer reads the
# same way `get`, `cursor`, `trim-note` and `findings` read it. A flow list
# (`depends_on: [a, b]`) carries no wrapping quote pair and so still passes
# through verbatim, as this function's contract above promises.
_list_records() {
  local f="$1" section="$2"; shift 2
  local fields="$*"
  awk -v section="$section" -v fields="$fields" "$_YAML_AWK_DECODE"'
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
      rec[k]=rs_decode(v) }
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
  merge-findings) cmd_merge_findings "$@" ;;
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
  amend-handoff) cmd_amend_handoff "$@" ;;
  check-status)  cmd_check_status  "$@" ;;
  write-result)  cmd_write_result  "$@" ;;
  route)         cmd_route         "$@" ;;
  record-decision) cmd_record_decision "$@" ;;
  record-review)   cmd_record_review   "$@" ;;
  compact-threshold) cmd_compact_threshold "$@" ;;
  periodic-pause)    cmd_periodic_pause    "$@" ;;
  review-due)        cmd_review_due        "$@" ;;
  run-digest)        cmd_run_digest        "$@" ;;
  run-tally)         cmd_run_tally         "$@" ;;
  prune-questions)   cmd_prune_questions   "$@" ;;
  reorder-pending)   cmd_reorder_pending   "$@" ;;
  bundle-cap)        cmd_bundle_cap        "$@" ;;
  # The header block, printed to its OWN end rather than to a hardcoded line
  # number. The number was `498` while the header actually ran to 553, so help
  # had been silently truncating its last 55 lines mid-sentence -- a range
  # goes stale the moment anything is inserted above it, and this file's
  # header grows with every subcommand added (this one added two).
  -h|--help|help|"") awk 'NR<2 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0" ;;
  *) die "unknown subcommand '${cmd}' (try --help)" ;;
esac
