#!/usr/bin/env bash
# =============================================================================
# compare.sh — the model-comparison harness (model-comparison-harness)
# =============================================================================
# Replays packets that already landed, varying one role's model through
# `model_routing` and holding a blinded reviewer fixed as the judge. This file
# grows one subcommand per plan task; see gspec/features/model-comparison-harness.
#
# Usage:  compare.sh <subcommand> [args]
#
#   settings <file>   read an experiment settings file (annotated reference:
#                     templates/model-comparison.yaml), apply the defaults and
#                     print the normalized settings, one `KEY=value` line each,
#                     in this fixed order:
#                       ROLE= MODELS= REVIEWER_MODEL= MODEL_IDS= EFFORT=
#                       SOURCE_REPO= PER_CLASS= CODE_FILES= PROSE_FILES=
#                     then `EXPERIMENT=<12 hex>`, a digest of exactly those
#                     nine lines. List values are sorted (LC_ALL=C), de-duped
#                     and comma-joined, so settings that differ only in key
#                     order, item order or repeats get the same id.
#                     MODEL_IDS is the `model_ids:` map (a block of indented
#                     `<alias>: <id>` lines) narrowed to the models and the
#                     reviewer model, as `<alias>:<id>` items: each alias
#                     pinned to the one concrete model id its transcripts must
#                     show. A pinned id is part of the id, so changing one
#                     starts a new experiment. Every model and the reviewer
#                     model needs a non-empty pin, else it is refused naming
#                     `model_ids` (reason `no-pinned-id(...)`, or `empty-id`),
#                     and each of those pins needs a complete entry (all five
#                     rates) in the price table
#                     (${ORCH_COMPARE_PRICES:-spend-prices.json beside this
#                     script}), else it is refused naming `model_ids` (reason
#                     `unpriced(...)`), so no arm's cost can read unpriced.
#                     EFFORT is the required `effort:` scalar, one of
#                     EFFORT_LEVELS below: the one reasoning effort every
#                     session the experiment starts runs at. Absent, or any
#                     other value, is refused naming `effort`; it has no
#                     default, since a session given none runs at its model's
#                     own default, which differs between models.
#
#                     A setting that cannot be used is REFUSED: one line per
#                     refusal on stderr,
#                       REFUSED setting=<key> value=<value> reason=<reason>
#                     and exit 1, with nothing on stdout. Refusals come in two
#                     phases. Phase 1 (the file itself, every scalar and the
#                     role) reads nothing but the settings file. Phase 2 (each
#                     `models` / `reviewer_model` entry) additionally reads the
#                     source repository's `.agents/project-overrides.yaml` and
#                     the price table, and runs routing.sh against a temp root.
#                     Neither phase runs git: every refusal happens before any
#                     git read.
#
#   candidates <file> read the settings exactly as `settings` does (the same
#                     refusals, before any git read), then list every packet
#                     with an `[orch packet:<id>]` trailer on its own line in
#                     any commit of the source repository (`git log --all`).
#                     One line per packet, oldest first (the order of each
#                     packet's earliest trailer commit):
#                       CANDIDATE packet=<id> class=<code|prose> handoff=<original|rebuilt> start=<sha> commits=<sha,...>
#                       DROPPED packet=<id> class=neither
#                       EXCLUDED packet=<id> reason=<why>
#                     `commits` lists every trailer commit of the packet,
#                     earliest first (--author-date-order: ancestry first,
#                     then author date); `start`, the replay start, is the
#                     earliest one's first parent. Class is decided from the
#                     union of those commits' changed files, each commit's
#                     `gspec/` files dropped when that commit changed only
#                     checkbox characters in them: code when a file is in
#                     CODE_FILES, prose when none is and one is in
#                     PROSE_FILES, neither otherwise (not a candidate). A set
#                     item ending in `/` matches by prefix; any other item
#                     matches that file or anything beneath it. The handoff is
#                     `original` when `.agents/loop/*/<id>/handoff.md` exists
#                     in the source repository, else `rebuilt` when
#                     gspec-backlog.sh (beside this script) resolves the task
#                     against the start commit's `gspec/` tree; a packet with
#                     neither is EXCLUDED with the reason. This script never
#                     parses a gspec file: resolution is the adapter's.
#
#   select <file>     choose the experiment's packets from `candidates`, per
#                     class, and store the choice ONCE as
#                       <store>/<EXPERIMENT>/selection.json
#                     where <store> is `.agents/metrics/comparisons` in the
#                     main checkout of the repository this script runs from
#                     (ORCH_COMPARE_STORE overrides it). When that file already
#                     exists it is printed back unchanged and nothing is
#                     recomputed; otherwise it is computed, written and
#                     printed. Stdout is always the stored file's bytes; one
#                     line on stderr says which happened.
#                     Per class, from that class's candidates only, taken
#                     newest first (the reverse of the `candidates` order):
#                       1. the newest packet whose fix rounds are 1 or more;
#                       2. while fewer than two distinct recorded tiers are
#                          chosen, the newest packet with a recorded tier not
#                          yet chosen;
#                       3. the rest newest first, up to PER_CLASS.
#                     Tier is the own-line `[orch tier:<tier>]` trailer of the
#                     latest of the packet's trailer commits carrying one, else
#                     `unrecorded`, which is an absence and never counts toward
#                     the tier mix. Fix rounds are the `fix` routing records for
#                     the packet across the source's `.agents/loop/*/routing.jsonl`;
#                     a packet with no routing record there at all (pruned, or
#                     run before routing records existed) reads `unmeasured`,
#                     never 0. Title is the earliest trailer commit's subject.
#                     A class short of its count, of two recorded tiers or of a
#                     measured fix round gets a `shortfalls` entry; a gap is
#                     never filled from the other class. EXCLUDED and DROPPED
#                     packets from `candidates` are named in the selection.
#
#   estimate <experiment> [--remaining]
#                     state the spend of the experiment's stored selection
#                     (`select` first) and issue the approval token for it.
#                     The replay set is every selected packet × every model,
#                     in stored order (packet, then model); under --remaining,
#                     only the replays with no stored record. A record counts
#                     for a replay when a line of <store>/records.jsonl has
#                     top-level `experiment`, `packet` and `model` fields equal
#                     to it (any outcome, `invalid` included). Output, in order:
#                       EXPERIMENT= SCOPE=<all|remaining> MODELS= PACKETS=
#                       RECORDED=<replays already recorded> REPLAYS=<count>
#                       REPLAY packet=<id> model=<m>        one per replay
#                       PRICE_TABLE_DATE=<the table's table_date>
#                       EXCLUDED packet=<id> reason=<why>   unmeasured cost
#                       UNPRICED model=<m> reason=<why>
#                       ESTIMATE model=<m|total> replays= estimated= tokens=
#                         input= output= cache_creation= cache_read=
#                         dollars_min= dollars_max= [price=<basis>]
#                       NOTE ...
#                       APPROVAL=<token>   (`none` when no replay is in the set)
#                     THE ESTIMATE RULE (the plan's decision 3): tokens are
#                     held constant and priced per model. A packet's forecast
#                     is its original recorded `packets[].tokens` from the
#                     source repository's `.agents/metrics/*/run-metrics.json`
#                     (the newest `generated_at` row whose four token fields
#                     are numbers, whose file's token_source is a transcript
#                     one, and whose sum is not 0), identical for every model;
#                     fix rounds are not modelled. A packet with no such row is
#                     EXCLUDED and named: its cost is unmeasured, never 0.
#                     `estimated` counts the replays the figures cover. Prices
#                     come from ${ORCH_COMPARE_PRICES:-spend-prices.json beside
#                     this script}: the entry keyed by the model itself, else
#                     the `claude-<model>-*` entries when all of them carry the
#                     same five rates (`price=family:<ids>`); otherwise the
#                     model is UNPRICED and its dollars read `unmeasured`, as
#                     does the total's. Packet tokens do not split cache writes
#                     by lifetime, so dollars_min prices them all at the
#                     5-minute rate and dollars_max at the 1-hour rate.
#                     The token is single-use and bound to exactly the printed
#                     set: one line appended to <store>/<experiment>/approvals.jsonl
#                       {"token", "state": "pending", "scope", "issued_at",
#                        "set": <digest of the REPLAY lines>, "replays": [...]}
#                     before it is printed. Append-only: the newest pending
#                     line supersedes every earlier one; `run` consumes it.
#
#   prepare <experiment> <packet> <model>
#                     build one replay's isolated work clone from the stored
#                     selection (`select` first). <packet> must be selected and
#                     <model> one of the settings' models. Steps, in order:
#                       1. `git clone --shared --no-checkout` of the source
#                          repository into <scratch>/<16 hex>, where <scratch> is
#                          ${ORCH_COMPARE_SCRATCH:-${TMPDIR:-/tmp}} and must lie
#                          outside the source's working tree; check out the
#                          packet's stored `start` (the earliest trailer
#                          commit's first parent) on a new branch
#                          `replay-<16 hex>`, then delete every other local
#                          branch and the `origin` remote, so the clone's refs
#                          are that one branch (and any tags) and nothing it does
#                          can reach the source. Neither name contains any of
#                          the settings' model identifiers (checked,
#                          case-insensitive, and redrawn when one does).
#                       2. rewrite the clone's `.agents/project-overrides.yaml`
#                          so `model_routing` maps the settings' role to <model>
#                          and `reviewer` to the settings' reviewer model. Every
#                          other entry, key, comment and line is kept as it was
#                          (a flow-form map becomes a block; an absent key is
#                          appended). Then `routing.sh --root <clone> resolve`
#                          must print exactly those two models, or it is refused.
#                       3. write a minimal run-state and run `runstate.sh
#                          begin-run` in the clone.
#                       4. install the packet's handoff at
#                          <clone>/.agents/loop/<run_id>/<packet>/handoff.md
#                          from the experiment's handoff cache,
#                            <store>/<experiment>/handoffs/<packet>.md
#                          written ONCE per packet (never replaced), so every
#                          model's replay receives identical bytes. On a miss the
#                          cache is filled from the `original` handoff (the
#                          source's earliest `.agents/loop/*/<packet>/handoff.md`,
#                          the one `candidates` finds first) as first
#                          dispatched, loop splice blocks removed: every
#                          `orch:decider-amendment` and `orch:partial-work`
#                          span the loop added after that dispatch is dropped
#                          as `amend-handoff`/`refresh-handoff` placed it, and
#                          every other byte is kept, the budget block included
#                          (a marker it cannot place that way is refused); or,
#                          for a `rebuilt` one, from
#                          `gspec-backlog.sh handoff <packet> <clone>` piped into
#                          `runstate.sh handoff <run-state> <packet> --tier
#                          <stored tier> --agent <role>` in the clone, which
#                          appends the verification contract exactly as a live
#                          handoff gets it. The stored tier is passed as it
#                          stands, `unrecorded` included: never a guessed tier.
#                     Output (and <store>/<experiment>/replays/<replay>.env,
#                     the same lines, where <replay> is a fresh 12 hex id):
#                       REPLAY= EXPERIMENT= PACKET= MODEL= ROLE=
#                       REVIEWER_MODEL= SOURCE_REPO= START= CLONE= BRANCH=
#                       RUN_STATE= RUN_ID= HANDOFF= HANDOFF_SOURCE=<original|rebuilt>
#                       HANDOFF_CACHE= HANDOFF_CACHED=<written|reused>
#                     Nothing is written in the source repository outside
#                     the experiment's own store, <store>/<experiment>/: its
#                     tree, `.agents/` and refs are otherwise unchanged (the
#                     default store lies inside the harness's main checkout,
#                     so when that is the source the handoff cache and
#                     replay records land under its `.agents/metrics/`,
#                     which this repository's .gitignore ignores). The source
#                     handoff is only read, never modified. On any failure the
#                     half-built clone is removed. The scripts used are the
#                     ones beside this file, never the clone's own copies.
#                     A cached handoff's header names the run-state, result
#                     and review paths of wherever it was written (the source
#                     run for an original, the first clone for a rebuild):
#                     identical bytes mean those paths are not this clone's.
#
#   review-view <replay>
#                     build the checkout a reviewer is given for a prepared
#                     replay (its record, <store>/*/replays/<replay>.env, must
#                     exist in exactly one experiment): a second opaque clone
#                     that names none of the settings' models. Steps, in order:
#                       1. the work clone's current diff against the start
#                          (committed on its branch, staged, unstaged and
#                          untracked-but-not-ignored alike) is taken as a tree,
#                          through a temp index and a temp object directory, so
#                          the work clone itself is only read. Everything under
#                          `.agents/metrics/` and `.agents/loop/`, and the
#                          run-state (`.agents/run-state.yaml`,
#                          `.agents/run-state-prev.yaml`), stays as the start
#                          holds it. `.agents/project-overrides.yaml` keeps the
#                          packet's own edits but its `model_routing` is reduced
#                          to the one `reviewer: <reviewer model>` entry (every
#                          other entry dropped, the start's included), so the
#                          replay's routing change is not in the view.
#                       2. `git clone --shared --no-checkout` of the source at
#                          the start into <scratch>/<16 hex>, on the one branch
#                          `review-<16 hex>`, with no remote, as `prepare` does.
#                          Refused when the scratch root's path names a model.
#                       3. commit A (only when the start's own `model_routing`
#                          is not already reviewer-only): the start with that
#                          reduced configuration; commit B: A plus the change.
#                          Both are made by `git commit-tree` (no hook, no
#                          template, no trailer) with a fixed author, committer,
#                          date and message: "Review configuration" and
#                          "Changes under review", by compare
#                          <compare@example.invalid> at 2000-01-01T00:00:00Z.
#                          B's tree must equal the tree built in step 1, and
#                          `routing.sh --root <view> resolve reviewer` must print
#                          the reviewer model, or it is refused. The change under
#                          review is BASE..HEAD.
#                       4. a run-state (`last_green_commit` = BASE) and
#                          `runstate.sh begin-run` in the view.
#                       5. under <view>/.agents/loop/<run_id>/<packet>/: the work
#                          clone's current handoff as `handoff.md`, and its result
#                          file (<clone>/.agents/loop/<run_id>/<packet>/<role>.md)
#                          as `<role>.md`, each with every word containing an
#                          identifier of the settings' models (each model and
#                          the reviewer's, as the settings name them, which is
#                          also the routing alias; a resolved id such as
#                          `claude-<alias>-5` contains its alias), matched
#                          case-insensitively, replaced by `[model]` together
#                          with a directly following version number. The
#                          handoff header's `run-state:`, `result:` and
#                          `review:` lines are pointed at the view's own paths.
#                     Output (the view's path is also appended as a `VIEW=`
#                     line to <store>/<experiment>/replays/<replay>.views):
#                       REPLAY= VIEW= BRANCH= START= BASE= HEAD= RUN_STATE=
#                       RUN_ID= HANDOFF= RESULT=<path|none> REVIEW=<path>
#                     The reviewed change's own content is carried as it is:
#                     a diff that itself names a model is not redacted, since
#                     redacting it would change the work under review. On any
#                     failure the half-built view is removed.
#
#   replay <replay>   run a prepared replay (its record, as for review-view)
#                     through the `run-loop` §3 attempt, fix and review path,
#                     with this script as the driver. Once per replay: a second
#                     `replay` of the same id is refused (<replay>.steps exists).
#                     Every agent step is one non-interactive session,
#                       ${ORCH_COMPARE_CLAUDE:-claude} --plugin-dir <harness> --effort <effort>
#                         --permission-mode bypassPermissions --settings <confinement>
#                         --session-id <uuid> -p <prompt>
#                     (the bypass mode because nobody can answer a prompt in a
#                     headless session, where one refuses the call or stalls
#                     the step; the harness's hooks/guard.sh, loaded through
#                     --plugin-dir, is meant to keep hard-denying; <uuid> is a fresh
#                     id per session, named on its STEP line so `record` can
#                     find its transcript). A working directory confines
#                     nothing, so <confinement> is a settings JSON with <dir>
#                     the session's clone or view, physical, adding: Claude
#                     Code's OS-level Bash sandbox (`sandbox.enabled`,
#                     `failIfUnavailable`, no unsandboxed retry, filesystem
#                     writes allowed in <dir> and <tmp>, the `allowWrite`
#                     list), which confines a shell write however it is
#                     made; `disableAllHooks: false`; and one `PreToolUse`
#                     hook on Edit, MultiEdit, Write, NotebookEdit and Bash:
#                     `<harness>/scripts/compare-confine.sh <dir> <tmp>`. <tmp>
#                     is the session's own temp directory: a fresh `mktemp -d`
#                     under /tmp, physical, made before launch, outside the
#                     clone or view, the source checkout and the harness's
#                     main checkout (else the session is not started, and
#                     reads as a crash), set as the session's TMPDIR and
#                     CLAUDE_CODE_TMPDIR, and removed when it ends. The hook
#                     and the sandbox are given the same two strings, so a
#                     scratch write one allows the other allows too; any other
#                     temp directory (another session's, a bare /tmp path) is
#                     outside both. The hook
#                     refuses a write whose target does not resolve inside
#                     <dir> or <tmp>, and one whose target it cannot resolve, failing
#                     closed (compare-confine.sh's header states what it
#                     recognises). A refusal by the hook is a denied call like
#                     any other, so `record` scores the replay `invalid`; a
#                     write the sandbox blocks fails inside its command, and
#                     its transcript records no denied call (ADR 0030 §2,
#                     the live probe).
#                     Refused (exit 2) before any session when
#                     compare-confine.sh is missing or not executable.
#                     where <effort> is the stored selection's settings
#                     `effort` (a selection naming none, or one outside
#                     EFFORT_LEVELS, is refused before any session starts),
#                     with CLAUDE_CODE_EFFORT_LEVEL removed from the session's
#                     environment, since that variable outranks `--effort`,
#                     with stdin from /dev/null, whose working directory is the
#                     work clone (the varied role) or a review view (the
#                     reviewer), and which is killed when it outlives
#                     ${ORCH_COMPARE_STEP_TIMEOUT} seconds (the default is
#                     _CMP_STEP_TIMEOUT_DEFAULT below). <harness> is the
#                     checkout this script runs from: every agent, hook and
#                     script a session uses is the harness's, never the
#                     clone's own copy. The prompt tells the session to
#                     dispatch the step's agent once, with the model
#                     `<harness>/scripts/routing.sh --root <dir> resolve <agent>`
#                     prints (omitted when it prints nothing), and to end its
#                     output with the agent's status line, which is read as
#                     the last non-empty line of the session's stdout. The
#                     brief names the handoff, the run-state and the result
#                     path in that directory (a cached handoff's own header
#                     names another checkout's) and, on a fix round, the
#                     latest review. The sequence:
#                       1. `runstate.sh record-start <packet> <replay>` in the
#                          clone.
#                       2. the varied role's step. Its line goes through
#                          `check-status`; a refused line (or none) gets ONE
#                          re-dispatch carrying the reason, and a second
#                          refusal ends the replay. A first token `continue` goes
#                          through `route`: ACTION=continue runs `record-start
#                          --continue` and `refresh-handoff`, then step 2 again;
#                          ACTION=stop ends the replay. Any other token goes to
#                          review.
#                       3. a fresh `review-view` for every review, and a reviewer
#                          session in it (same check-status rule). On a review
#                          after a fix round, the previous review is copied to
#                          the view's review path first and that path is in
#                          the reviewer's brief, as §3.4 gives it. Its verdict
#                          (pass, fix or escalate; anything else ends the
#                          replay as refused) goes through `route` in the work
#                          clone's run-state, and the view's review file is
#                          copied to the clone's run directory for the next
#                          attempt, unless the session left it as seeded (the
#                          next attempt then gets no review; a failed copy is
#                          an error). ACTION=attempt runs `refresh-handoff`,
#                          then step 2 with that review; `packet_attempts` in
#                          the clone's configuration bounds it through `route`.
#                          ACTION=decider or stop ends the replay: the
#                          escalation decider is never dispatched.
#                       4. ACTION=land commits the packet's diff, and only it,
#                          as ONE commit on the start, and moves the replay's
#                          branch to it (a commit the agent made itself is
#                          left unreachable): the work tree against the start,
#                          with `.agents/metrics/`, `.agents/loop/`, the
#                          run-state files, `.agents/roadmap.yaml` and `gspec/`
#                          kept as the start holds them, and the replay's
#                          `model_routing` change taken back out of
#                          `.agents/project-overrides.yaml`: its
#                          `model_routing` block is the start's again, and the
#                          packet's own edits elsewhere in it are kept. No `check-task`, no
#                          `complete-capabilities`, no roadmap edit. The message
#                          carries the `[orch packet:<id>]` trailer; an empty
#                          change makes no commit.
#                     Output, each line also appended to
#                     <store>/<experiment>/replays/<replay>.steps:
#                       STEP n=<k> agent=<a> try=<1|2> exit=<code|timeout>
#                            status=<ok|refused|none> [token=<first token>]
#                            session=<the session's id>
#                       ROUTE agent=<a> token= action= attempts= limit=
#                       REFRESH partial_work=<...> paths=<n>
#                       VIEW=<review view path>
#                       END=<land|decider|stop|refused|crashed|timed-out|error>
#                       COMMIT=<sha|none>
#                     `error` is a harness step that failed (exit 1).
#                     `crashed` is a session exiting non-zero, `timed-out` one
#                     killed at the limit; either ends the replay at once.
#
#   routing-check <replay>
#                     show from run metrics that the replay ran on the
#                     configured models (its record, as for review-view).
#                     Refused until the replay has ended: its <replay>.steps
#                     log must carry an END= line, written after the last
#                     session it launched has returned or been killed, so no
#                     review session is still running in any view. Then
#                     `metrics.sh collect --all-sessions` (the one beside this
#                     script) runs in the work clone and in each review view the
#                     step log names (VIEW= lines, in order: view-1, view-2, ...)
#                     whose reviewer session ran (a reviewer STEP line after its
#                     VIEW= line). Every packet is written beside the replay's
#                     record, <store>/<experiment>/replays/<replay>.metrics/
#                     work.json and view-<k>.json, never inside a view, where a
#                     reviewer could read it. The checks, each one line:
#                       CHECK scope=<work|view-k> check=<name> result=<pass|fail|not-run>
#                             value=<...> [reason=<why>]
#                     scope=work, with <role> the replay's role and <model> its
#                     model:
#                       override-count      audit.dispatches_with_model_override
#                                           is 0; above 0, null or absent fails
#                                           (null is unmeasured, never clean).
#                       <role>-resolved-id  every `Agent` dispatch of <role> (or
#                                           `gaffer:<role>`) in the clone's event
#                                           logs carries a `routing_resolved`
#                                           stamp, all stamps are one value, and
#                                           it is <model>; no dispatch, an
#                                           unstamped one or an unreadable log
#                                           fails as unmeasured.
#                       <role>-models       by_agent_role.<role>.models (and
#                                           `gaffer:<role>`'s) names the id the
#                                           experiment's `model_ids` pins the
#                                           resolved alias to (the stamp, else
#                                           <model> when the stamps are
#                                           unmeasured) and nothing else,
#                                           compared exactly: a same-family model
#                                           of another version fails, and so does
#                                           a resolved alias with no pin. No
#                                           model named fails as unmeasured.
#                       effort              totals.by_effort names no level but
#                                           the experiment's `effort` setting
#                                           (value= the levels it names,
#                                           comma-joined). A level other than the
#                                           setting fails. None named passes
#                                           (value=none): a model that takes no
#                                           effort carries none.
#                     scope=view-k: `reviewer-resolved-id`, `reviewer-models`
#                     and `effort`, the same three checks for the reviewer
#                     against the reviewer model, its pinned id and the
#                     setting. The pins and the setting are read from the
#                     experiment's stored selection.json; a selection that pins
#                     no id for the replay's model or reviewer model, or names
#                     no effort in EFFORT_LEVELS, is refused (exit 1) before
#                     any check runs. The line after REPLAY= is
#                     EFFORT=<the setting>. A view with no reviewer session reads
#                     `check=reviewer-models result=not-run`; a collect that
#                     leaves no readable packet reads `check=collect
#                     result=not-run` and its scope's checks not-run. Each
#                     scope's packet path is a `METRICS scope= dir= packet=`
#                     line. The last line is
#                       ROUTING_CHECK=<fail|not-run|pass>
#                     fail when any check failed, else not-run when any did not
#                     run, else pass. The first line is REPLAY=<replay>; every
#                     line is also written to
#                     <store>/<experiment>/replays/<replay>.routing, replaced on
#                     each run.
#
#   sweeps <replay>   run the sweeps the replay's handoff requires on its final
#                     diff (its record, as for review-view). Refused until the
#                     replay has ended (an END= line in its step log, as for
#                     routing-check). THE REQUIRED-SWEEPS READING: every
#                     `scripts/test-<name>.sh` path the handoff names is a
#                     required sweep, read from the experiment's handoff cache
#                     (HANDOFF_CACHE=, the bytes every model's replay of the
#                     packet was first given), never from the work clone's
#                     handoff, which a continuation or fix round may since
#                     have spliced a partial-work block into. A path may be
#                     absolute (it names that checkout's sweep); a pattern such
#                     as `scripts/test-*.sh` names none. No path named reads
#                       REPLAY= REQUIRED=none SWEEPS=none-required
#                     and nothing is built. Otherwise:
#                       1. the final diff is the tree `replay`'s land commit
#                          holds (its _CMP_LAND_EXCLUDED paths as the start
#                          holds them, the replay's `model_routing` taken back
#                          out), built from the work clone as it now stands, so a
#                          replay that ended without landing is tested on the
#                          work it left. It is built through a temp index and a
#                          temp object directory: the work clone is only read.
#                       2. for each sweep, in sorted order, a fresh `git clone
#                          --shared` of the source at the start under the scratch
#                          root (as `prepare`), the final diff applied and
#                          committed there (its tree checked against step 1's),
#                          then `bash <sweep>` run in it with stdin from
#                          /dev/null, no ORCH_* or GIT_* variable, and
#                          CLAUDE_PROJECT_DIR set to that clone, killed with
#                          every process it started when it outlives
#                          ${ORCH_COMPARE_SWEEP_TIMEOUT} seconds (the default is
#                          _CMP_SWEEP_TIMEOUT_DEFAULT below). The clone is then
#                          removed; its output is kept as a log.
#                     Output (each line also written to
#                     <store>/<experiment>/replays/<replay>.sweeps, replaced on
#                     each run; logs under <replay>.sweep-logs/<name>.log):
#                       REPLAY=<replay>
#                       REQUIRED=<path,...|none>
#                       TREE=<the final diff's tree>
#                       SWEEP path=<p> result=<pass|fail> exit=<code|timeout|not-run>
#                             [seconds=<n> log=<path>] [reason=absent-from-final-diff]
#                       FAILED=<path,...>            only when one failed
#                       SWEEPS=<pass|fail|none-required>
#                     A required sweep the final diff does not hold fails,
#                     `exit=not-run`: it was not run, and the requirement is
#                     not met.
#
#   record <replay>   decide an ended replay's outcome and append its one record
#                     to <store>/records.jsonl (its record, as for review-view).
#                     Refused, with nothing appended, until the outcome can be
#                     decided: the step log must carry an END= line and the
#                     routing check must have printed its ROUTING_CHECK= line
#                     (<replay>.routing), and the work clone's
#                     <clone>/.agents/loop/<run_id>/routing.jsonl records for
#                     the packet must be, in order, the (token, action) pairs of
#                     the step log's ROUTE lines. A replay that already has a
#                     line in records.jsonl is refused: a rerun is a new replay.
#                     THE OUTCOME, tested in this order (the PRD's):
#                       invalid          ROUTING_CHECK is not `pass`, or the
#                                        replay ended without a verdict it
#                                        could route (END=crashed, timed-out
#                                        or error), or it ended refused on a
#                                        fixed role's line: the agent of the
#                                        step log's last STEP line is not the
#                                        replay's role (the reviewer's line
#                                        refused twice, or its token outside
#                                        the review vocabulary), or a tool call
#                                        was denied in any of its sessions (by
#                                        the guard, its ask tier included, or by
#                                        the permission system; rd_denials
#                                        below says how it is read). A harness
#                                        fault, not the model's: left out of
#                                        the pass rate, and rerun, unless a
#                                        call was denied in it (`denials`
#                                        above 0, whatever the cause): the same
#                                        rule would deny the rerun again until
#                                        the harness configuration changes.
#                       escalated        a routing record's token is `escalate`
#                                        (the reviewer returned it), or the
#                                        replay ended at the decider or a stop,
#                                        or refused on the varied role's own
#                                        line, while an attempt remained: the
#                                        last ROUTE line's attempts below its
#                                        limit, or no ROUTE line yet (0 used
#                                        of a limit runstate.sh never reads
#                                        below 1).
#                       failed-at-limit  it ended at the decider or a stop, or
#                                        refused on the varied role's own line,
#                                        with no attempt left (attempts at or
#                                        past the limit): a `fix` or `retry`
#                                        routed past `packet_attempts` included.
#                       passed           END=land on a `pass` routed to land.
#                     The first verdict is the first routing record's token
#                     among `pass`, `fix`, `retry` and `escalate` (null when no
#                     review returned one). Fix rounds are the `fix` records
#                     routed to `attempt`: each started one more round, and a
#                     `fix` past the limit started none; for a passed replay
#                     these are all before its `pass`. Sweeps are T9's SWEEPS=
#                     value from <replay>.sweeps, null when `sweeps` has not
#                     been run (not run, never a pass).
#                     COST is the varied role's tokens, read from the work
#                     clone's packet routing-check wrote (<replay>.metrics/
#                     work.json): for `implementer`, the sum of the packet's
#                     `packets[].dispatches[].tokens` rows; for any other role,
#                     `by_agent_role.<role>.tokens` (and `gaffer:<role>`'s).
#                     A missing packet, no dispatch row, or any row or field
#                     that is null or not a count makes every token figure
#                     null: never a partial sum, never 0. Dollars are priced
#                     at the price table's entry for the id the experiment's
#                     `model_ids` pins the replay's model to
#                     (${ORCH_COMPARE_PRICES:-spend-prices.json beside this
#                     script}); cache writes do not split by lifetime, so
#                     dollars_min prices them at the 5-minute rate and
#                     dollars_max at the 1-hour rate. Dollars are null when the
#                     tokens are, when the pin has no complete price entry, and
#                     when the routing check did not pass (the tokens are then
#                     not shown to have been spent on the pinned model).
#                     `cost_note` says why a figure is null (null when none is).
#                     The record, one compact JSON line, has exactly the keys
#                       experiment replay packet model role reviewer_model
#                       effort handoff_source settings outcome outcome_reason
#                       invalid_cause first_verdict fix_rounds sweeps
#                       routing_check end denials denial_kinds denial_tools
#                       denial_note tokens dollars_min dollars_max price price_table_date
#                       cost_source cost_note recorded_at
#                     where `invalid_cause` is an `invalid` outcome's reason as
#                     one token, by the test that decided it: `routing`,
#                     `crashed`, `timed-out` or `error` (the END=),
#                     `fixed-role-refused` or `denial`, and null for every
#                     other outcome; `denial_kinds` is the denied calls' kinds
#                     (each a `toolDenialKind`, sorted, [] when none was
#                     denied, null when the denials are unmeasured);
#                     `denial_tools` the tool names those calls asked for,
#                     likewise (`unrecorded` among them for a denial whose call
#                     its transcript does not name);
#                     `denials` is the count of tool calls denied in the
#                     replay's sessions, read from their transcripts, or null
#                     when a session's transcript cannot be found or is not in
#                     the recognised form rd_transcript_denials reads
#                     (unmeasured, never 0; `denial_note` says why, and is null
#                     otherwise),
#                     `settings` is the stored selection's settings
#                     object as it stands, `effort` its `effort` setting (null
#                     when the selection names none) and `tokens` is {input, output,
#                     cache_creation, cache_read} or null. Output:
#                       REPLAY= OUTCOME= REASON= FIRST_VERDICT=<v|none>
#                       FIX_ROUNDS= SWEEPS=<v|not-run> DENIALS=<n|unmeasured>
#                       TOKENS=<n|unmeasured>
#                       DOLLARS_MIN=<x|unmeasured> DOLLARS_MAX=<x|unmeasured>
#                       RECORDS=<path>
#                     THE LATEST-RECORD RULE: records.jsonl is append-only, and
#                     for one experiment, packet and model the record every
#                     later reader uses is the LAST line naming all three. A
#                     rerun (`run --rerun`) is a new replay whose record is
#                     appended after the `invalid` one, so it takes its place;
#                     the `invalid` line is kept, never rewritten.
#
#   run <experiment> --approve <token> [--rerun <replay>]
#                     run the replays an `estimate` token approved. The token is
#                     read from <store>/<experiment>/approvals.jsonl and REFUSED
#                     (exit 1, nothing run, nothing written) when it is
#                       missing     no line of that file carries it;
#                       spent       a `consumed` line for it exists;
#                       superseded  a `pending` line for another token comes
#                                   after its own (the newest estimate wins);
#                     or when its stored `replays` do not digest to its stored
#                     `set`. A pause requested before the token is consumed
#                     stops the run there (RUN=paused) and leaves the token
#                     pending. Otherwise the token is CONSUMED, one line
#                       {"token", "state": "consumed", "experiment",
#                        "consumed_at", "rerun": <replay|null>}
#                     appended under a lock directory (approvals.lock beside it)
#                     BEFORE any replay starts, so it is single-use even when
#                     the run stops early. Then, for each replay of the token's
#                     set, in its stored order (the selection's packet order,
#                     then the settings' model order, as `estimate` wrote it):
#                       a replay that already has a record for this experiment,
#                       packet and model is skipped (`SKIP`), so a resumed
#                       experiment runs only the replays with no stored record;
#                       before every replay but the first one started, the
#                       pause sentinel is read through `runstate.sh
#                       pause-status` (the sentinel is ${ORCH_PAUSE_FILE}, else
#                       `.agents/pause` in the main checkout of the repository
#                       this script runs from, never the source repository's or
#                       a clone's); a pause stops the run there, cleanly: the
#                       replays not yet started are not prepared, and have no
#                       record;
#                       otherwise `prepare` -> `replay` -> `routing-check` ->
#                       `sweeps` -> `record`, each this script's own subcommand,
#                       its output appended to <store>/<experiment>/runs/<token>.log.
#                     Once a replay starts it runs to its record: the pause is
#                     honoured only between replays, since stopping inside one
#                     would leave an ended replay with no record. A `prepare`
#                     that fails, a `replay` that leaves no END= line, or a
#                     `routing-check` or `record` that fails stops the run
#                     (RUN=error, exit 1) with that replay unrecorded. A `sweeps`
#                     that fails does not: the record then stores `sweeps` null
#                     (not run), as it does for any replay never swept.
#                     --rerun <replay> runs that one replay's packet and model
#                     again as a new replay, and nothing else of the token's set.
#                     It is admitted only when <replay> belongs to <experiment>,
#                     has a record, that record is the latest for its packet
#                     and model (THE LATEST-RECORD RULE), its outcome is
#                     `invalid`, and the token's set holds its packet and model
#                     (the spend was approved for it). The new record is
#                     appended after the `invalid` one and takes its place.
#                     Output:
#                       RUN experiment= token= scope= replays=<in the set> [rerun=<replay>]
#                       APPROVED token=<t> state=consumed
#                       SKIP packet= model= reason=recorded
#                       START packet= model=
#                       STEP packet= model= replay=<id|none> step=<name> exit=<code>
#                            [end=|routing_check=|sweeps=|outcome=]
#                       DONE packet= model= replay= outcome=
#                       PAUSED packet= model= reason=<the pause's reason>
#                                               (the replay not started)
#                       RAN=<n> SKIPPED=<n> REMAINING=<n not started>
#                       LOG=<path>
#                       RUN=<complete|paused|error>
#
#   rank-prepare <experiment> <packet>
#                     build the blinded ranking clone for one selected packet.
#                     Refused (exit 1, nothing built, nothing written) unless
#                     every one of the settings' models has a latest record for
#                     the packet (THE LATEST-RECORD RULE) whose outcome is
#                     `passed`, `escalated` or `failed-at-limit`; each model
#                     that does not is named on stderr, one line each:
#                       UNRANKABLE packet=<id> model=<m> reason=missing
#                       UNRANKABLE packet=<id> model=<m> reason=invalid cause=<c> replay=<r>
#                       UNRANKABLE packet=<id> model=<m> reason=invalid cause=<c> denials=<n> kinds=<k,...> tools=<t,...> replay=<r>
#                       UNRANKABLE packet=<id> model=<m> reason=invalid cause=denial kinds=<k,...> tools=<t,...> replay=<r>
#                       UNRANKABLE packet=<id> model=<m> reason=outcome(<o>) replay=<r>
#                     where <c> is the record's `invalid_cause` (`routing`,
#                     `crashed`, `timed-out`, `error`, `fixed-role-refused`),
#                     `unrecorded` for a record that stores none, <k> the
#                     denied calls' kinds and <t> the tools they asked for
#                     (each `unrecorded` when the record stores none). The
#                     second form is an earlier cause whose record also counts
#                     denials above 0 (<n>, its `denials`): `record` tests the
#                     cause first, so the denial is not the cause it stored,
#                     but it happened all the same.
#                     An `invalid` replay is re-run (`run --rerun`) first, unless
#                     a call was denied in it (its cause is a denial, or it
#                     carries `denials=`): the same rule stops a rerun again
#                     until the harness configuration changes. Then:
#                       1. each model's final diff: the tree `sweeps` tests
#                          (land_tree: metrics, run directory, run-state,
#                          roadmap and plan paths as the start holds them, the
#                          replay's model_routing taken back out), built from
#                          the replay's work clone through a temp index and a
#                          temp object directory (the work clone only read),
#                          as `git diff` text against the start. Each replay's
#                          record must name the packet's stored start and the
#                          selection's reviewer model.
#                       2. an order drawn for this packet alone: one fresh
#                          random key per diff on every call, sorted. No order
#                          is shared between packets or taken from the
#                          settings' model order.
#                       3. `git clone --shared --no-checkout` of the source at
#                          the start into <scratch>/<16 hex>, on the one branch
#                          `rank-<16 hex>`, with no remote, as `review-view`
#                          builds its view (the same scratch-root refusals).
#                          Its `.agents/project-overrides.yaml` carries the
#                          view's reviewer-only `model_routing` (every entry
#                          dropped, `reviewer: <reviewer model>` alone),
#                          committed as the view's "Review configuration"
#                          commit when that changes the start's tree; then
#                          `routing.sh --root <clone> resolve reviewer` must
#                          print the reviewer model, or it is refused.
#                       4. the diffs, in the drawn order, as
#                          <clone>/.agents/ranking/A.diff, B.diff, ... (letters
#                          only; untracked). A start that already holds
#                          `.agents/ranking` is refused.
#                       5. the label-to-model map, one line appended to
#                          <store>/labels.jsonl and written nowhere in the clone:
#                            {"experiment", "packet", "ranking": <12 hex>,
#                             "dir": <clone>, "start", "reviewer_model",
#                             "labels": [{"label", "model", "replay"}, ...],
#                             "prepared_at"}
#                          Append-only; every call draws a new ranking.
#                     Output (no model is named on it):
#                       EXPERIMENT= PACKET= RANKING= DIR= BRANCH= START= BASE=
#                       DIFF label=<L> path=<file>        one per label, A first
#                       LABELS=<A,B,...> LABELS_FILE=<path>
#                     A diff that itself names a model is carried as it is, as
#                     `review-view` carries the reviewed change. On any failure
#                     the half-built clone is removed.
#
#   rank <experiment> <packet>
#                     rank the packet's latest prepared ranking (the last
#                     <store>/labels.jsonl line naming the experiment and
#                     packet, `rank-prepare` first) with one reviewer session
#                     in its ranking clone, and record the ranking. Refused
#                     (exit 1, nothing appended, no label resolved) when that
#                     ranking is already recorded in rankings.jsonl (a new
#                     ranking is `rank-prepare` again), its clone is gone or
#                     no longer resolves the reviewer to the selection's
#                     reviewer model, a label has no diff file there, or the
#                     stored selection pins no id for the reviewer model or
#                     names no effort in EFFORT_LEVELS. Before the session
#                     only the map's labels are read, never its models.
#                     THE SESSION: one, started as `replay` starts every
#                     session (`--plugin-dir <harness> --effort <the
#                     selection's effort> --permission-mode bypassPermissions
#                     --settings <confinement to the ranking clone>
#                     --session-id <uuid>`, CLAUDE_CODE_EFFORT_LEVEL removed,
#                     stdin /dev/null, killed at ${ORCH_COMPARE_STEP_TIMEOUT}),
#                     in the ranking clone, dispatching the `reviewer` agent
#                     once on what `routing.sh --root <clone> resolve reviewer`
#                     prints. Its brief names the diff files by label and
#                     nothing else of the packet or the models. THE RESULT is
#                     the lines after the last line of the session's stdout
#                     that reads `RANKING`, blank lines skipped, each
#                       RANK <position> <label> <one-line reason>
#                     and it must be a strict best-to-worst order: every label
#                     exactly once, positions 1..N in that order, no ties, a
#                     non-empty reason per label. Otherwise it is REFUSED,
#                     one line per broken rule on stderr,
#                       REFUSED rule=<rule> [position=<n>] [label=<L>] [line=<n>]
#                     where <rule> is no-ranking, malformed-line,
#                     unknown-label, missing-reason, duplicate-label, tie,
#                     missing-label or not-strict-order (the order is judged
#                     only when no other rule is broken), or session-crashed
#                     / session-timed-out when the session ends without one.
#                     THE DENIALS: before the result is read, the session's
#                     transcripts are read for denied tool calls as `record`
#                     reads a replay's (rd_session_denials, below). A denied
#                     call refuses the ranking, naming it,
#                       REFUSED rule=denied count=<n> kinds=<kinds> tools=<tools>
#                     and so do denials that cannot be read (`REFUSED
#                     rule=denials-unmeasured`, the reason on stderr): the
#                     ranking is not shown to be free of a harness fault.
#                     THE MODEL AND EFFORT CHECK: then routing-check's reviewer
#                     checks, the same three (`reviewer-resolved-id`,
#                     `reviewer-models` against the pinned id, and `effort`),
#                     run on the ranking clone through `metrics.sh collect
#                     --all-sessions` (its packet in a temp directory removed on
#                     exit, never in the clone), as `CHECK scope=rank ...`
#                     lines; any line
#                     not `pass` refuses the ranking (`REFUSED rule=model-or-
#                     effort`, the CHECK lines on stderr). Every session that
#                     ever ran in the clone is checked, so a clone a ranking
#                     on the wrong model ran in cannot be ranked again: run
#                     `rank-prepare` for a new one.
#                     Only then is one line appended to
#                     <store>/rankings.jsonl:
#                       {"experiment", "packet", "ranking", "dir", "start",
#                        "reviewer_model", "effort", "routing_check": "pass",
#                        "order": [{"position", "label", "reason"}, ...],
#                        "ranked_at"}
#                     naming no compared model; and only after that append are
#                     the map's models read and each label resolved.
#                     Output (stdout empty on a refusal):
#                       EXPERIMENT= PACKET= RANKING= DIR= EFFORT= REVIEWER_MODEL=
#                       CHECK scope=rank check=<name> result=pass value=<...>
#                       RANK position=<n> label=<L> reason=<reason>   best first
#                       RECORDED=<rankings.jsonl path>
#                       RESOLVED position=<n> label=<L> model=<m> replay=<r>
#                       RANKED=<ranking>
#
#   report <experiment>
#                     render the experiment's stored results for the human, in
#                     the report-conventions layout (templates/report-conventions.md:
#                     flush-left headings, facts behind a `> ` bar, one line per
#                     thing, no table). It reads only the store: the stored
#                     selection (`select` first), records.jsonl, rankings.jsonl
#                     and labels.jsonl; it runs nothing, writes nothing, and
#                     prints no timestamp, so two renders of the same store
#                     are byte-identical.
#                     THE GROUP: the experiment is reported together with
#                     every other stored experiment (<store>/<id>/selection.json)
#                     whose settings name the same varied role, reviewer model
#                     and source repository, the named experiment first, the
#                     rest in id order; an experiment missing any of the three
#                     is a group alone. Every figure is over the group's
#                     records and never pools anything outside it: a later
#                     experiment on another role, reviewer model or source
#                     repository is its own group, reported by naming one of
#                     its experiments. Every stored selection is read, and an
#                     unreadable one refuses the report. Sections, in order:
#                       the header   the varied role and the group's models, the
#                                    reviewer and effort(s), the source
#                                    repository, the group's experiments (each
#                                    with its models and effort), and one line
#                                    saying what each figure is over.
#                       Cells        one line per model x class (the group's
#                                    model order: the settings' order, then
#                                    each later experiment's new models; code,
#                                    then prose). A cell is every selected
#                                    packet of the class in each group
#                                    experiment whose models include the model
#                                    (a packet two experiments selected counts
#                                    once per experiment), each read through
#                                    THE LATEST-RECORD RULE per experiment. A
#                                    replay is SCORED when its latest record is
#                                    not `invalid`; `invalid` is a harness
#                                    fault and is left out of every figure
#                                    (and counted as excluded). Per cell:
#                                      pass rate   `passed` over scored replays,
#                                                  so `escalated` and
#                                                  `failed-at-limit` count as
#                                                  not passed;
#                                      fix rounds  the mean of `fix_rounds`
#                                                  over the passed replays;
#                                      rank        the mean position (1 best)
#                                                  over the class's ranked
#                                                  packets, within one
#                                                  RANKING SET: the models a
#                                                  ranking ranked together.
#                                                  Ranks from different sets
#                                                  are never averaged: when
#                                                  the group holds more than
#                                                  one set, the cell gives one
#                                                  rank per set that ranked
#                                                  the model, each naming its
#                                                  set;
#                                      tokens      the mean of the four token
#                                                  fields' sum, and dollars the
#                                                  mean dollars_min-dollars_max,
#                                                  each over the scored replays
#                                                  whose figure is not null (a
#                                                  null is left out of the mean
#                                                  and its n, never read as 0);
#                                    each with its n. A figure with n=0 reads
#                                    `unmeasured`, and a cell with no scored
#                                    replay reads `unmeasured` whole, naming how
#                                    many of its packets are recorded and how
#                                    many of those are invalid. After the
#                                    cells, one line per model whose latest
#                                    records (over both classes) hold a replay
#                                    whose `invalid_cause` is `denial`: how
#                                    many, the denied calls' kinds (the
#                                    records' `denial_kinds`, or `kinds
#                                    unrecorded for <n>`) and the tools they
#                                    asked for (`denial_tools`, or `tools
#                                    unrecorded for <n>`). It is a count beside
#                                    the cells, which already exclude those
#                                    replays, so no figure changes; a model
#                                    with none prints no line. Then one line
#                                    per model whose latest records hold a
#                                    replay invalid for another cause whose
#                                    `denials` is above 0: how many, those
#                                    causes, the kinds and the tools, and that
#                                    a rerun would meet the same denial (the
#                                    cause is tested first, so the denial did
#                                    not decide it, but it happened).
#                       Packets      one line per selected packet: its title,
#                                    class, handoff source (`original` or
#                                    `rebuilt`, as the selection stored it and
#                                    `prepare` installed it), and ranked or
#                                    unranked with why; in a group of more than
#                                    one experiment, also the experiment.
#                       Ranking      the count of selected packets left
#                                    unranked. A packet is ranked by its last
#                                    rankings.jsonl line for its experiment,
#                                    resolved to models through the labels.jsonl
#                                    line carrying the same ranking id; one with
#                                    no ranking, or whose labels do not resolve
#                                    to the group's models, is unranked. A group
#                                    holding more than one ranking set names
#                                    them.
#                       Proposal     computed by THE PROPOSAL RULE, never
#                                    written by a model: the highest pass rate
#                                    over both classes (pooled: passed over
#                                    scored, not a mean of the two rates), then
#                                    the lowest mean rank, then the lowest mean
#                                    dollars (the midpoint of the mean range),
#                                    each deciding only among the models tied
#                                    on every figure before it. The mean rank is
#                                    read from the one ranking set that ranked
#                                    every tied model together: none leaves it
#                                    unmeasured, and more than one stops the
#                                    rule, naming the sets, since ranks from
#                                    different sets are never averaged. It prints one
#                                    `<role>: <model>` entry, the
#                                    one-model-per-agent shape of
#                                    `model_routing`, and the deciding figure
#                                    for every model compared, citing each cell
#                                    it pools. A class favours a model by the
#                                    same rule inside that class: when both
#                                    classes favour the proposed model it says
#                                    they agree. When they favour different
#                                    ones it says so, and when both favour one
#                                    model the pooled rule did not pick (the
#                                    classes' n differ) it says that instead,
#                                    never claiming agreement. Either way it
#                                    states a per-tier split (each class
#                                    routed to the model it favours) against
#                                    the single value, over both classes: its
#                                    pass rate, mean dollars and mean tokens
#                                    per replay and their difference. A cost
#                                    figure unmeasured in any cell the split
#                                    needs reads unmeasured, naming the cells.
#                                    No change is proposed, and the reason
#                                    named, when any model has an unmeasured
#                                    cell (every one is named), when the rule
#                                    reaches a figure that is unmeasured for a
#                                    tied model (never read as 0), or when the
#                                    models tie on all three figures. The
#                                    proposal is text: nothing writes routing
#                                    configuration.
#
# Exit status: 0 printed settings / candidates / a selection / an estimate / a
# prepared replay / a review view / a replay that reached an END / a routing
# check that printed its ROUTING_CHECK= line (pass, fail or not-run) / a sweeps
# run that printed its SWEEPS= line (pass, fail or none-required) / a record
# appended / a ranking clone built / a ranking recorded / a report rendered; 1 refused, no experiment id could be computed, the source
# repository is not a git repository, the selection could not be written, or
# (estimate) no stored selection, an unreadable selection, records file or
# price table, or the token could not be stored, or (prepare) no stored
# selection, a packet or model outside it, a scratch root inside the source,
# or a clone, routing, run-state or handoff step that failed, or (review-view)
# no single replay record, a work clone, source or selection that cannot be
# read, a scratch root inside the source or naming a model, or a diff, clone,
# commit, routing, run-state or redaction step that failed, or (replay) no
# single replay record, a replay already run, no stored selection or one naming
# no effort in EFFORT_LEVELS, a review view, route,
# refresh-handoff or land commit that failed (an `END=error` line says which),
# or (routing-check) no single replay record, a work clone that is not a git
# repository, a replay not run or not ended, no stored selection or one pinning
# no id for the replay's models in `model_ids` or naming no effort in
# EFFORT_LEVELS, or an output path that cannot be
# written or lies inside a review view, or (sweeps) no single replay record, a
# work clone or source that is not a git repository, a replay not run or not
# ended, a missing handoff cache, a scratch root inside the source, or a tree,
# diff, clone, apply or commit step that failed, or (record) no single replay
# record, a replay not run or not ended, no ROUTING_CHECK= line, routing records
# that disagree with the step log, an END or ROUTE line it cannot read, a
# replay already recorded, no stored selection, a price table that cannot be
# read, or a record that cannot be appended, or (run) a missing, spent,
# superseded or malformed token, an approvals file that cannot be read, a lock
# already held, a --rerun replay not admitted, or a step that stopped the run
# (RUN=error); a run that completed or paused exits 0, or (rank-prepare) no
# stored selection, a packet outside it, a model with no rankable latest record,
# an unreadable records file, a replay record or work clone that cannot be read
# or disagrees with the selection, a scratch root inside the source or naming a
# model, or a diff, clone, commit, routing or label-map step that failed, or
# (rank) no stored selection or prepared ranking, a ranking already recorded, a
# ranking clone gone or re-routed, a selection pinning no reviewer id or naming
# no effort, a session that crashed or timed out, a ranking that breaks a rule,
# a model or effort check not passing, or a record that cannot be appended, or
# (report) no stored selection, or a selection, records, rankings or labels
# file that cannot be read; 2 usage error, routing.sh / gspec-backlog.sh / runstate.sh / metrics.sh missing beside
# this script, or (replay, rank) no session command, or (replay, sweeps, rank) a
# malformed timeout.
#
# Portability: awk + bash 3.2 (no associative arrays), no jq, no python3.
# =============================================================================

set -uo pipefail
set -f   # no globbing: list items are split on `,` and must never expand

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROUTING="$HERE/routing.sh"
BACKLOG="$HERE/gspec-backlog.sh"
RUNSTATE="$HERE/runstate.sh"
AGENTS_DIR="${ORCH_ROUTING_AGENTS_DIR:-$HERE/../agents}"

# --- REPLAYABLE_ROLES: the roles an experiment may vary ------------------------
# Stated once, here. These are the agents a `run-loop` §3.2 handoff may name as
# `--agent` (implementer for mechanical/integration, architect or ux-designer
# for design-heavy, doc-writer for docs) — the only dispatches a replay drives
# from a handoff. Deliberately absent:
#   reviewer        the fixed judge of every experiment, never a subject.
#   loop-driver     the session itself; routing never sets its model.
#   chief-engineer  the escalation decider, which never runs inside a replay,
#                   so varying its model would measure nothing.
REPLAYABLE_ROLES=(implementer architect ux-designer doc-writer)

# --- EFFORT_LEVELS: the reasoning efforts an experiment may hold fixed ---------
# Stated once, here: the levels `claude --effort` accepts. Every session an
# experiment starts is given one of them, so no arm runs at its model's own
# default effort.
EFFORT_LEVELS=(low medium high xhigh max)

# --- the defaults (model-comparison-harness PRD, first experiment) ------------
# SOURCE_REPO defaults to the checkout this script runs from ("this
# repository"), found without git. REVIEWER_MODEL defaults to what the loop's
# reviewer runs on in the source repository today: its `model_routing` entry
# through routing.sh, else the reviewer agent's frontmatter model.
DEFAULT_ROLE="implementer"
DEFAULT_MODELS="fable,opus,sonnet"
DEFAULT_PER_CLASS="8"
DEFAULT_CODE_FILES="scripts/,hooks/"
DEFAULT_PROSE_FILES="agents/,skills/,templates/,docs/,CLAUDE.md"

die()   { printf 'compare.sh: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { printf 'usage: compare.sh {settings|candidates|select} <file> | estimate <experiment> [--remaining] | prepare <experiment> <packet> <model> | review-view <replay> | replay <replay> | routing-check <replay> | sweeps <replay> | record <replay> | run <experiment> --approve <token> [--rerun <replay>] | rank-prepare <experiment> <packet> | rank <experiment> <packet> | report <experiment>\n' >&2; exit 2; }

# --- digest: 12 hex of sha256 over stdin, probed by execution ------------------
digest() {
  local data out
  data="$(cat)"
  out="$(printf '%s' "$data" | sha256sum 2>/dev/null)"
  if [ -z "$out" ]; then out="$(printf '%s' "$data" | shasum -a 256 2>/dev/null)"; fi
  [ -n "$out" ] || die "no sha256 tool (sha256sum or shasum) available"
  printf '%s' "${out%% *}" | cut -c1-12
}

# --- settings-file parse (awk token-scan) --------------------------------------
# Emits tab-separated records, in file order:
#   S <key> <value>     a scalar `key: value`
#   L <key> <item>      one list item (flow `[a, b]` or block `- a`)
#   P <key> <sub> <val> one block map entry (an indented `sub: val`; val may be empty)
#   E <key>             a list key given no items (`key: []` or a bare `key:`)
#   D <key>             a key seen a second time (its value is ignored)
#   X <line-no>         a line that is not `key: value`, a list item or comment
#   U <key>             a list or map the parser could not read (a flow map
#                       `{...}` included, or a block mixing items and entries)
parse_settings() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function uncomment(s) {
      if (s ~ /^#/) return ""
      sub(/[[:space:]]+#.*$/, "", s)
      return s
    }
    function unquote(s) {
      if (length(s) >= 2 && (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/)) s = substr(s, 2, length(s) - 2)
      return s
    }
    function close_block() {
      if (mode == "block" && nitems == 0) print "E\t" cur
      mode = ""
    }
    BEGIN { mode = ""; cur = ""; nitems = 0; bkind = "" }
    { sub(/\r$/, "") }
    {
      line = $0
      t = trim(line)
      if (t == "" || t ~ /^#/) next
      if (line ~ /^[[:space:]]/ || line ~ /^-([[:space:]]|$)/) {
        if (mode == "skip") next
        if (mode != "block") { print "X\t" NR; next }
        body = trim(uncomment(t))
        if (body !~ /^-([[:space:]]|$)/) {
          # A block map entry, `sub: value`; a block is all list items or all
          # map entries, never a mix.
          if (bkind == "list") { print "U\t" cur; mode = "skip"; next }
          q = match(body, /:([[:space:]]|$)/)
          if (q == 0) { print "U\t" cur; mode = "skip"; next }
          sk = unquote(trim(substr(body, 1, q - 1)))
          if (sk == "") { print "U\t" cur; mode = "skip"; next }
          bkind = "map"
          print "P\t" cur "\t" sk "\t" unquote(trim(substr(body, q + 1)))
          nitems++
          next
        }
        if (bkind == "map") { print "U\t" cur; mode = "skip"; next }
        bkind = "list"
        sub(/^-[[:space:]]*/, "", body)
        item = unquote(trim(body))
        if (item == "") { print "U\t" cur; mode = "skip"; next }
        print "L\t" cur "\t" item
        nitems++
        next
      }
      close_block()
      p = match(line, /:([[:space:]]|$)/)
      if (p == 0) { print "X\t" NR; next }
      k = trim(substr(line, 1, p - 1))
      rest = trim(uncomment(trim(substr(line, p + 1))))
      if (k in seen) { print "D\t" k; mode = "skip"; next }
      seen[k] = 1
      cur = k
      if (rest == "") { mode = "block"; nitems = 0; bkind = ""; next }
      if (rest ~ /^\[/) {
        if (rest !~ /\]$/) { print "U\t" k; next }
        inner = trim(substr(rest, 2, length(rest) - 2))
        if (inner == "") { print "E\t" k; next }
        if (inner ~ /[\[\]{}]/) { print "U\t" k; next }
        n = split(inner, pcs, ",")
        for (i = 1; i <= n; i++) {
          it = unquote(trim(pcs[i]))
          if (it == "") { if (i == n && n > 1) continue; print "U\t" k; break }
          print "L\t" k "\t" it
        }
        next
      }
      if (rest ~ /^\{/) { print "U\t" k; next }
      print "S\t" k "\t" unquote(rest)
    }
    END { close_block() }
  ' "$1" 2>/dev/null
}

# --- refusal collection ----------------------------------------------------------
REFUSALS=()
refuse() { REFUSALS+=("REFUSED setting=$1 value=$2 reason=$3"); }
flush_refusals() {
  if [ "${#REFUSALS[@]}" -gt 0 ]; then
    printf '%s\n' "${REFUSALS[@]}" >&2
    exit 1
  fi
}

# norm_list <csv> -> sorted, de-duped, comma-joined (LC_ALL=C).
norm_list() {
  printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

# role_is_replayable <role>
role_is_replayable() {
  local r
  for r in "${REPLAYABLE_ROLES[@]}"; do
    [ "$r" = "$1" ] && return 0
  done
  return 1
}

# effort_is_level <effort>
effort_is_level() {
  local e
  for e in "${EFFORT_LEVELS[@]}"; do
    [ "$e" = "$1" ] && return 0
  done
  return 1
}

# sel_effort: the `effort` setting of a stored selection flattened by json_flat
# on stdin (empty when it names none). Reads all of stdin, so no writer upstream
# is cut off mid-pipe.
sel_effort() {
  awk -F'\t' '!f && $2 == ".settings.effort" && $3 == "s" { v = $4; f = 1 } END { print v }'
}

# price_rates <flat-price-table> <id>: the id's five rates, `input output
# cache_read cache_write_5m cache_write_1h`, when its entry holds all five as
# numbers; nothing otherwise. A complete entry is what `record` prices at.
price_rates() {
  K=".prices.$2." awk -F'\t' '
    index($2, ENVIRON["K"]) == 1 && $3 == "n" && $4 ~ /^[0-9.]+$/ { r[substr($2, length(ENVIRON["K"]) + 1)] = $4 }
    END { if (("input" in r) && ("output" in r) && ("cache_read" in r) && ("cache_write_5m" in r) && ("cache_write_1h" in r))
            print r["input"], r["output"], r["cache_read"], r["cache_write_5m"], r["cache_write_1h"] }' "$1"
}

# frontmatter_model <agent> -> the `model:` inside the leading `---` block.
frontmatter_model() {
  local f="$AGENTS_DIR/$1.md"
  [ -f "$f" ] || return 0
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^model:/ {
      v = $0
      sub(/^model:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      print v
      exit
    }
  ' "$f" 2>/dev/null
}

# extra_models_block <overrides-file> -> the top-level `extra_models:` key and
# every line belonging to it, verbatim, so routing.sh parses it exactly as it
# parses the source repository's own file.
extra_models_block() {
  [ -f "$1" ] || return 0
  awk '
    { sub(/\r$/, "") }
    on && ($0 ~ /^[[:space:]]/ || $0 ~ /^-([[:space:]]|$)/ || $0 ~ /^[[:space:]]*$/ || $0 ~ /^#/) { print; next }
    { on = 0 }
    /^extra_models:/ { on = 1; print }
  ' "$1" 2>/dev/null
}

cmd_settings() {
  [ $# -eq 1 ] || usage
  local file="$1"
  [ -f "$file" ] || die "settings: no such file: $file" 2
  local file_dir
  file_dir="$(cd "$(dirname "$file")" && pwd -P)"

  # --- phase 1: the file, the scalars and the role (no git, no source read) ---
  local role="" role_set=0 models="" models_set=0 reviewer="" reviewer_set=0
  local source="" source_set=0 per_class="" per_class_set=0
  local code="" code_set=0 prose="" prose_set=0 effort="" effort_set=0
  # model_ids: one `<alias>\t<id>` line per entry, in file order.
  local pins=""
  pin_of() { printf '%s' "$pins" | A="$1" awk -F'\t' '$1 == ENVIRON["A"] { print $2; exit }'; }
  local parsed kind k v w
  parsed="$(parse_settings "$file" | tr -d '\r')"
  # Three fields for every record, so a scalar or list value keeps any tab it
  # holds (and is refused for it below); a `P` record splits its own value.
  while IFS="$(printf '\t')" read -r kind k v; do
    [ -n "$kind" ] || continue
    case "$kind" in
      X) refuse "-" "line-$k" "unparseable(not a key: value line or list item)"; continue ;;
      D) refuse "$k" "-" "duplicate-setting"; continue ;;
      U) refuse "$k" "-" "unparseable-list"; continue ;;
    esac
    case "$k" in
      role|reviewer_model|source_repo|per_class|effort)
        case "$kind" in
          S) case "$k" in
               role)           role="$v";      role_set=1 ;;
               reviewer_model) reviewer="$v";  reviewer_set=1 ;;
               source_repo)    source="$v";    source_set=1 ;;
               per_class)      per_class="$v"; per_class_set=1 ;;
               effort)         effort="$v";    effort_set=1 ;;
             esac ;;
          *) refuse "$k" "-" "expected-a-single-value" ;;
        esac ;;
      models|code_files|prose_files)
        case "$kind" in
          S|L)
            # An item is one token: a comma or whitespace inside it would be
            # split apart below, so each half would be judged (and printed)
            # as if it were a separate item.
            case "$v" in *,*) refuse "$k" "$v" "comma-in-item"; continue ;; esac
            case "$v" in *[[:space:]]*) refuse "$k" "$v" "whitespace-in-item"; continue ;; esac
            case "$k" in
              models)      models="${models:+$models,}$v"; models_set=1 ;;
              code_files)  code="${code:+$code,}$v";       code_set=1 ;;
              prose_files) prose="${prose:+$prose,}$v";    prose_set=1 ;;
            esac ;;
          E) case "$k" in
               models)      models_set=1 ;;
               code_files)  code_set=1 ;;
               prose_files) prose_set=1 ;;
             esac ;;
          P) refuse "$k" "-" "expected-a-list" ;;
        esac ;;
      model_ids)
        # A map from model alias to the one concrete model id it is pinned to.
        case "$kind" in
          P)
            # `<alias>\t<id>`, split at the first tab; a trailing empty id was
            # stripped with the line's trailing tab by read, leaving no tab.
            case "$v" in
              *"	"*) w="${v#*	}"; v="${v%%	*}" ;;
              *) w="" ;;
            esac
            case "$v" in ''|*[!A-Za-z0-9._-]*) refuse model_ids "$v" "invalid-model-token"; continue ;; esac
            if [ -n "$(pin_of "$v")" ]; then
              refuse model_ids "$v" "duplicate-alias"; continue
            fi
            case "$w" in
              '') refuse model_ids "$v" "empty-id" ;;
              *[!A-Za-z0-9._-]*) refuse model_ids "$v" "invalid-model-id($w)" ;;
              *) pins="$pins$v	$w
" ;;
            esac ;;
          E) ;;
          *) refuse model_ids "-" "expected-a-map(one indented alias: id line per model)" ;;
        esac ;;
      *) refuse "$k" "-" "unknown-setting(known: role models reviewer_model model_ids effort source_repo per_class code_files prose_files)" ;;
    esac
  done <<EOF
$parsed
EOF

  [ "$role_set" -eq 1 ] || role="$DEFAULT_ROLE"
  [ "$models_set" -eq 1 ] || models="$DEFAULT_MODELS"
  [ "$per_class_set" -eq 1 ] || per_class="$DEFAULT_PER_CLASS"
  [ "$code_set" -eq 1 ] || code="$DEFAULT_CODE_FILES"
  [ "$prose_set" -eq 1 ] || prose="$DEFAULT_PROSE_FILES"

  # role: the reviewer, the loop-driver session, or anything outside the set.
  case "$role" in
    reviewer)    refuse role "$role" "reviewer-is-the-fixed-judge" ;;
    loop-driver) refuse role "$role" "loop-driver-is-the-session" ;;
    *) if ! role_is_replayable "$role"; then
         refuse role "$role" "not-replay-dispatchable(replayable: ${REPLAYABLE_ROLES[*]})"
       fi ;;
  esac

  # effort: required, and one of EFFORT_LEVELS. No default: a session given no
  # effort runs at its model's own default, which differs between models.
  if [ "$effort_set" -eq 0 ]; then
    refuse effort "-" "required(one of: ${EFFORT_LEVELS[*]})"
  elif ! effort_is_level "$effort"; then
    refuse effort "$effort" "not-an-effort-level(one of: ${EFFORT_LEVELS[*]})"
  fi

  # per_class: a positive integer, normalized (08 -> 8).
  case "$per_class" in
    ''|*[!0-9]*) refuse per_class "$per_class" "not-a-positive-integer" ;;
    *) per_class="$(printf '%s' "$per_class" | sed 's/^0*//')"
       [ -n "$per_class" ] || refuse per_class "0" "not-a-positive-integer" ;;
  esac

  # models / reviewer_model: an alias token routing.sh can be handed safely.
  local m
  [ -n "$models" ] || refuse models "-" "empty-list"
  for m in $(printf '%s' "$models" | tr ',' ' '); do
    case "$m" in *[!A-Za-z0-9._-]*) refuse models "$m" "invalid-model-token" ;; esac
  done
  if [ "$reviewer_set" -eq 1 ]; then
    case "$reviewer" in
      ''|*[!A-Za-z0-9._-]*) refuse reviewer_model "$reviewer" "invalid-model-token" ;;
    esac
  fi

  # model_ids: every model the experiment runs on is pinned to one concrete id
  # (an entry refused above as empty or invalid pins nothing). The reviewer
  # left to its default is checked once phase 2 has resolved it.
  for m in $(norm_list "$models" | tr ',' ' '); do
    case "$m" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ -n "$(pin_of "$m")" ] || refuse model_ids "$m" "no-pinned-id(named by models)"
  done
  if [ "$reviewer_set" -eq 1 ] && [ -n "$reviewer" ]; then
    case "$reviewer" in
      *[!A-Za-z0-9._-]*) ;;
      *) [ -n "$(pin_of "$reviewer")" ] || refuse model_ids "$reviewer" "no-pinned-id(named by reviewer_model)" ;;
    esac
  fi

  # code_files / prose_files: repo-relative path prefixes, a leading ./ dropped.
  local set_name set_val item out_list
  for set_name in code_files prose_files; do
    if [ "$set_name" = code_files ]; then set_val="$code"; else set_val="$prose"; fi
    [ -n "$set_val" ] || { refuse "$set_name" "-" "empty-list"; continue; }
    out_list=""
    for item in $(printf '%s' "$set_val" | tr ',' ' '); do
      item="${item#./}"
      case "$item" in
        ''|/*|*[!A-Za-z0-9._/@+-]*) refuse "$set_name" "$item" "not-a-repo-relative-path" ; continue ;;
      esac
      case "/$item/" in
        */../*|*/./*) refuse "$set_name" "$item" "not-a-repo-relative-path"; continue ;;
      esac
      out_list="${out_list:+$out_list,}$item"
    done
    if [ "$set_name" = code_files ]; then code="$out_list"; else prose="$out_list"; fi
  done

  # source_repo: a directory, relative paths resolved against the settings file.
  if [ "$source_set" -eq 1 ]; then
    case "$source" in /*) ;; *) source="$file_dir/$source" ;; esac
    if [ -d "$source" ]; then
      source="$(cd "$source" && pwd -P)"
    else
      refuse source_repo "$source" "not-a-directory"
    fi
  else
    source="$(cd "$HERE/.." && pwd -P)"
  fi

  flush_refusals

  # --- phase 2: each model through routing.sh's own validation ---------------
  # A temp root carries the source repository's `extra_models` verbatim plus one
  # `model_routing` entry, so routing.sh judges the model exactly as it judges a
  # live `model_routing` value in that repository.
  local tmp ex out line
  # routing.sh prints nothing for a clean config, so a routing.sh that could
  # not run would read as "every model accepted": require it up front.
  [ -x "$ROUTING" ] || die "settings: routing.sh is missing or not executable: $ROUTING" 2
  tmp="$(mktemp -d 2>/dev/null)" || die "settings: cannot create a temp root"
  mkdir -p "$tmp/.agents"
  ex="$(extra_models_block "$source/.agents/project-overrides.yaml")"

  # validate_model <setting> <routing-key> <model>: refuse on any report line
  # naming <routing-key>; carry the source's own extra_models report alongside.
  validate_model() {
    {
      printf 'model_routing:\n  %s: %s\n' "$2" "$3"
      if [ -n "$ex" ]; then printf '%s\n' "$ex"; fi
    } > "$tmp/.agents/project-overrides.yaml"
    out="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$tmp" validate 2>/dev/null | tr -d '\r')"
    local refused=0 exnote=""
    while IFS= read -r line; do
      case "$line" in
        "ROUTING-INVALID key=$2 value=$3 reason="*)
          refuse "$1" "$3" "${line#"ROUTING-INVALID key=$2 value=$3 reason="}"; refused=1 ;;
        "ROUTING-INVALID key=extra_models "*)
          exnote="$line" ;;
      esac
    done <<EOF2
$out
EOF2
    if [ "$refused" -eq 1 ] && [ -n "$exnote" ]; then
      REFUSALS+=("NOTE source extra_models: $exnote")
    fi
  }

  models="$(norm_list "$models")"
  for m in $(printf '%s' "$models" | tr ',' ' '); do
    validate_model models "$role" "$m"
  done

  if [ "$reviewer_set" -eq 0 ]; then
    reviewer="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$source" resolve reviewer 2>/dev/null | tr -d '\r')"
    [ -n "$reviewer" ] || reviewer="$(frontmatter_model reviewer)"
    if [ -z "$reviewer" ]; then
      refuse reviewer_model "-" "no-default(the source repository routes no reviewer model and the reviewer agent names none; set reviewer_model)"
    else
      case "$reviewer" in
        *[!A-Za-z0-9._-]*) ;;
        *) [ -n "$(pin_of "$reviewer")" ] \
             || refuse model_ids "$reviewer" "no-pinned-id(the reviewer_model default, resolved from the source repository)" ;;
      esac
    fi
  fi
  if [ -n "$reviewer" ]; then
    case "$reviewer" in
      *[!A-Za-z0-9._-]*) refuse reviewer_model "$reviewer" "invalid-model-token" ;;
      *) validate_model reviewer_model reviewer "$reviewer" ;;
    esac
  fi

  # model_ids: every pin the experiment runs on has a complete price entry, so
  # no arm's cost can read unpriced. A model with no pin was refused above.
  local prices="${ORCH_COMPARE_PRICES:-$HERE/spend-prices.json}" pin
  if json_flat "$prices" > "$tmp/prices" 2>/dev/null; then
    for m in $(norm_list "$models,$reviewer" | tr ',' ' '); do
      case "$m" in *[!A-Za-z0-9._-]*) continue ;; esac
      pin="$(pin_of "$m")"
      [ -n "$pin" ] || continue
      [ -n "$(price_rates "$tmp/prices" "$pin")" ] \
        || refuse model_ids "$m" "unpriced(the price table has no complete entry for $pin: $prices)"
    done
  else
    refuse model_ids "-" "price-table-unreadable($prices)"
  fi
  rm -rf "$tmp"

  flush_refusals

  # --- normalized output -----------------------------------------------------
  # MODEL_IDS: `<alias>:<id>` for each model and the reviewer, sorted. An entry
  # for any other alias pins nothing the experiment runs on, so it is left out
  # and never moves the id.
  local body ids=""
  for m in $(norm_list "$models,$reviewer" | tr ',' ' '); do
    ids="${ids:+$ids,}$m:$(pin_of "$m")"
  done
  body="ROLE=$role
MODELS=$models
REVIEWER_MODEL=$reviewer
MODEL_IDS=$ids
EFFORT=$effort
SOURCE_REPO=$source
PER_CLASS=$per_class
CODE_FILES=$(norm_list "$code")
PROSE_FILES=$(norm_list "$prose")"
  # The id is produced before anything is printed: an id that could not be
  # computed is a failure with nothing on stdout, never an empty EXPERIMENT=.
  local id
  id="$(printf '%s\n' "$body" | digest)" || exit 1
  [ -n "$id" ] || die "settings: the experiment id could not be computed"
  printf '%s\n' "$body"
  printf 'EXPERIMENT=%s\n' "$id"
}

# --- candidates ------------------------------------------------------------------

# in_set <file> <comma-list>: is <file> in the set? An item ending in `/` is a
# prefix; any other item is that file or a directory holding it.
in_set() {
  local item
  for item in $(printf '%s' "$2" | tr ',' ' '); do
    case "$item" in
      */) case "$1" in "$item"*) return 0 ;; esac ;;
      *)  [ "$1" = "$item" ] && return 0
          case "$1" in "$item"/*) return 0 ;; esac ;;
    esac
  done
  return 1
}

# trailer_rows <src>: one `<id>\t<commit>\t<first-parent>` row per own-line
# `[orch packet:<id>]` trailer (the line shape metrics.sh counts), commits
# earliest first. A root commit's parent column is empty.
trailer_rows() {
  git -C "$1" log --all --author-date-order --reverse \
      --format='===ORCHCOMMIT===%x09%H%x09%P%n%B' 2>/dev/null | tr -d '\r' \
    | awk -F'\t' '
        /^===ORCHCOMMIT===\t/ { c = $2; p = $3; sub(/ .*/, "", p); next }
        /^[[:space:]]*\[orch packet:[^]]+\][[:space:]]*$/ {
          if (c != "" && match($0, /\[orch packet:[^]]+\]/)) {
            v = substr($0, RSTART + 13, RLENGTH - 14)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (v != "" && !((c SUBSEP v) in seen)) { seen[c SUBSEP v] = 1; print v "\t" c "\t" p }
          }
        }'
}

# changed_files <src> <commit> <parent-or-empty>: the commit's changed paths.
changed_files() {
  if [ -n "$3" ]; then
    git -C "$1" -c core.quotePath=false diff-tree -r --name-only --no-renames "$3" "$2" 2>/dev/null
  else
    git -C "$1" -c core.quotePath=false diff-tree -r --root --no-commit-id --name-only --no-renames "$2" 2>/dev/null
  fi
}

# checkbox_only_files <src> <commit> <parent>: the `gspec/` files this commit
# changed in nothing but checkbox characters. Judged hunk by hunk on the diff's
# characters (a list item's leading `[ ]`/`[x]`/`[X]` is the only position
# allowed to differ); no gspec file is parsed. A moved line, an added or
# deleted file, a binary or mode-only change is never checkbox-only.
checkbox_only_files() {
  [ -n "$3" ] || return 0
  git -C "$1" -c core.quotePath=false diff -U0 --no-renames --no-color --no-ext-diff \
      --no-textconv --src-prefix=a/ --dst-prefix=b/ "$3" "$2" -- gspec/ 2>/dev/null \
    | awk '
        function norm(s) {
          if (match(s, /^[[:space:]]*[-*+][[:space:]]+\[[ xX]\]/))
            s = substr(s, 1, RLENGTH - 2) " " substr(s, RLENGTH)
          return s
        }
        function endhunk(   i) {
          if (nr != na) ok = 0
          else for (i = 1; i <= nr; i++) if (norm(r[i]) != norm(a[i])) { ok = 0; break }
          nr = 0; na = 0; last = ""
        }
        function endfile() {
          if (inh) endhunk()
          if (f != "" && ok && hunks > 0) print f
          f = ""; ok = 1; hunks = 0; inh = 0; nr = 0; na = 0; last = ""
        }
        BEGIN { ok = 1 }
        /^diff --git / { endfile(); next }
        !inh && /^\+\+\+ / { n = substr($0, 5); if (n ~ /^b\//) f = substr(n, 3); else ok = 0; next }
        !inh && /^--- / { if ($0 == "--- /dev/null") ok = 0; next }
        !inh && /^Binary files / { ok = 0; next }
        /^@@/ { if (inh) endhunk(); inh = 1; hunks++; next }
        inh && /^-/ { r[++nr] = substr($0, 2); last = "r"; next }
        inh && /^\+/ { a[++na] = substr($0, 2); last = "a"; next }
        inh && /^\\/ { if (last == "r") r[nr] = r[nr] "\n\\"; else if (last == "a") a[na] = a[na] "\n\\"; next }
        END { endfile() }
      '
}

cmd_candidates() {
  [ $# -eq 1 ] || usage
  local sout
  sout="$(cmd_settings "$1")" || exit $?
  [ -x "$BACKLOG" ] || die "candidates: gspec-backlog.sh is missing or not executable: $BACKLOG" 2
  local src code prose
  src="$(printf '%s\n' "$sout" | sed -n 's/^SOURCE_REPO=//p')"
  code="$(printf '%s\n' "$sout" | sed -n 's/^CODE_FILES=//p')"
  prose="$(printf '%s\n' "$sout" | sed -n 's/^PROSE_FILES=//p')"
  git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
    || die "candidates: the source repository is not a git repository: $src"

  local tmp
  tmp="$(mktemp -d 2>/dev/null)" || die "candidates: cannot create a temp root"
  # shellcheck disable=SC2064  # expand $tmp now: it is local to this function
  trap "rm -rf '$tmp'" EXIT
  trailer_rows "$src" > "$tmp/rows"

  local loop_dirs
  set +f; loop_dirs=( "$src"/.agents/loop/*/ ); set -f

  local id rows start commits c p f class d tree reason out rc
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9._-]*)
        printf 'EXCLUDED packet=%s reason=packet id outside [A-Za-z0-9._-]\n' "$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '?')"
        continue ;;
    esac
    rows="$(ID="$id" awk -F'\t' '$1 == ENVIRON["ID"]' "$tmp/rows")"
    start="$(printf '%s\n' "$rows" | sed -n '1p' | cut -f3)"
    commits="$(printf '%s\n' "$rows" | cut -f2 | paste -sd, -)"
    if [ -z "$start" ]; then
      printf 'EXCLUDED packet=%s reason=its earliest trailer commit is a root commit, so there is no replay start\n' "$id"
      continue
    fi

    # Class: the union of every trailer commit's changed files, each commit's
    # checkbox-only gspec/ files dropped.
    : > "$tmp/files"
    while IFS="$(printf '\t')" read -r _ c p; do
      changed_files "$src" "$c" "$p" | LC_ALL=C sort -u > "$tmp/changed"
      checkbox_only_files "$src" "$c" "$p" | LC_ALL=C sort -u > "$tmp/cbx"
      LC_ALL=C comm -23 "$tmp/changed" "$tmp/cbx" >> "$tmp/files"
    done <<EOF
$rows
EOF
    class="neither"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if in_set "$f" "$code"; then class="code"; break; fi
      if in_set "$f" "$prose"; then class="prose"; fi
    done < "$tmp/files"
    if [ "$class" = neither ]; then
      printf 'DROPPED packet=%s class=neither\n' "$id"
      continue
    fi

    # Handoff: the original file, else one the adapter rebuilds at the start.
    reason=""
    for d in "${loop_dirs[@]}"; do
      if [ -f "${d}${id}/handoff.md" ]; then reason="original"; break; fi
    done
    if [ -z "$reason" ]; then
      # `<rev>:gspec^{tree}` would read `^{tree}` as part of the path, so the
      # object is resolved first and its type checked apart.
      tree="$(git -C "$src" rev-parse --verify -q "${start}:gspec" 2>/dev/null)"
      if [ -n "$tree" ] && [ "$(git -C "$src" cat-file -t "$tree" 2>/dev/null)" != tree ]; then tree=""; fi
      if [ -z "$tree" ]; then
        reason="no original handoff, and the start commit has no gspec/ tree to rebuild one from"
      else
        if [ ! -d "$tmp/g-$tree" ]; then
          mkdir -p "$tmp/g-$tree/gspec"
          git -C "$src" archive --format=tar "$tree" 2>/dev/null | tar -x -f - -C "$tmp/g-$tree/gspec" 2>/dev/null \
            || rm -rf "$tmp/g-$tree"
        fi
        if [ ! -d "$tmp/g-$tree" ]; then
          reason="no original handoff, and the start commit's gspec/ tree could not be extracted"
        else
          out="$("$BACKLOG" handoff "$id" "$tmp/g-$tree" 2>"$tmp/bl.err" </dev/null | tr -d '\r')"; rc=$?
          case "$rc:$out" in
            0:PACKET=*) reason="rebuilt" ;;
            0:*) reason="no original handoff, and gspec-backlog.sh does not resolve the task at the start commit: $(printf '%s\n' "$out" | sed -n 's/^REASON=//p' | head -1)" ;;
            *)   reason="no original handoff, and gspec-backlog.sh handoff failed at the start commit: $(head -1 "$tmp/bl.err")" ;;
          esac
        fi
      fi
    fi
    case "$reason" in
      original|rebuilt)
        printf 'CANDIDATE packet=%s class=%s handoff=%s start=%s commits=%s\n' "$id" "$class" "$reason" "$start" "$commits" ;;
      *)
        printf 'EXCLUDED packet=%s reason=%s\n' "$id" "$(printf '%s' "$reason" | tr '\n\t' '  ')" ;;
    esac
  done <<EOF
$(awk -F'\t' '!seen[$1]++ { print $1 }' "$tmp/rows")
EOF
}

# --- select ------------------------------------------------------------------------

# store_root: where experiment results live. ORCH_COMPARE_STORE when set (the
# sweep's fixture store); otherwise `.agents/metrics/comparisons` in the main
# checkout of the harness repository (the checkout this script runs from, a
# worktree resolved to its main checkout through the common git dir), and the
# script's own parent directory when that is not a git checkout.
store_root() {
  if [ -n "${ORCH_COMPARE_STORE:-}" ]; then printf '%s' "$ORCH_COMPARE_STORE"; return 0; fi
  printf '%s/.agents/metrics/comparisons' "$(main_checkout)"
}

# main_checkout: the main checkout of the repository this script runs from (the
# harness's), through `git rev-parse --git-common-dir`, as the pause sentinel
# and the store find it; the checkout above this script when git cannot say.
main_checkout() {
  local top common
  top="$(cd "$HERE/.." && pwd -P)"
  common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null | tr -d '\r')"
  if [ -n "$common" ]; then
    case "$common" in /*) ;; *) common="$top/$common" ;; esac
    if [ -d "$common" ]; then top="$(cd "$common/.." && pwd -P)"; fi
  fi
  printf '%s' "$top"
}

# fix_round_rows <src>: one `<packet>\t<fix-count>` row for every packet that
# has at least one routing record in any `.agents/loop/*/routing.jsonl` of the
# source repository. The count is the records whose token is `fix` (each is
# one review that sent the packet back for a fix round). A packet with no row
# has no routing record left to read (pruned, or run before routing records
# existed): its fix rounds are unmeasured, never 0.
fix_round_rows() {
  local logs=() l
  set +f
  for l in "$1"/.agents/loop/*/routing.jsonl; do [ -f "$l" ] && logs+=("$l"); done
  set -f
  [ "${#logs[@]}" -gt 0 ] || return 0
  awk '
    function field(line, name,    pat, pos, rest, q) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      rest = substr(line, pos + length(pat))
      q = index(rest, "\"")
      if (q == 0) return ""
      return substr(rest, 1, q - 1)
    }
    { sub(/\r$/, ""); p = field($0, "packet"); if (p == "") next
      if (!(p in n)) { n[p] = 0; order[++k] = p }
      if (field($0, "token") == "fix") n[p]++ }
    END { for (i = 1; i <= k; i++) print order[i] "\t" n[order[i]] }
  ' "${logs[@]}" 2>/dev/null
}

# commit_tier <src> <commit>: the value of the commit's own-line
# `[orch tier:<tier>]` trailer (the line shape metrics.sh reads; the last one
# when a message carries several), or nothing.
commit_tier() {
  git -C "$1" log -1 --format=%B "$2" 2>/dev/null | tr -d '\r' | awk '
    /^[[:space:]]*\[orch tier:[^]]+\][[:space:]]*$/ {
      if (match($0, /\[orch tier:[^]]+\]/)) {
        v = substr($0, RSTART + 11, RLENGTH - 12); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v != "") t = v
      }
    }
    END { if (t != "") print t }'
}

cmd_select() {
  [ $# -eq 1 ] || usage
  local sout
  sout="$(cmd_settings "$1")" || exit $?
  local exp store dir sel
  exp="$(printf '%s\n' "$sout" | sed -n 's/^EXPERIMENT=//p')"
  store="$(store_root)"
  dir="$store/$exp"
  sel="$dir/selection.json"

  # Written once: a stored selection is read back unchanged, never recomputed.
  if [ -f "$sel" ]; then
    cat "$sel"
    printf 'compare.sh: selection read back unchanged: %s\n' "$sel" >&2
    return 0
  fi

  local cout rc
  cout="$(cmd_candidates "$1")"; rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  local src per
  src="$(printf '%s\n' "$sout" | sed -n 's/^SOURCE_REPO=//p')"
  per="$(printf '%s\n' "$sout" | sed -n 's/^PER_CLASS=//p')"

  local tmp
  tmp="$(mktemp -d 2>/dev/null)" || die "select: cannot create a temp root"
  # shellcheck disable=SC2064  # expand $tmp now: it is local to this function
  trap "rm -rf '$tmp'" EXIT
  fix_round_rows "$src" > "$tmp/fix"

  # One TSV row per candidate, NEWEST first (the reverse of the candidates
  # order, which is each packet's earliest trailer commit, oldest first):
  #   class tier fix packet handoff start commits title
  local ln id class handoff start commits c tier fix title first
  : > "$tmp/rows"
  while IFS= read -r ln; do
    case "$ln" in CANDIDATE\ *) ;; *) continue ;; esac
    id="$(printf '%s\n' "$ln" | sed -n 's/.* packet=\([^ ]*\).*/\1/p')"
    class="$(printf '%s\n' "$ln" | sed -n 's/.* class=\([^ ]*\).*/\1/p')"
    handoff="$(printf '%s\n' "$ln" | sed -n 's/.* handoff=\([^ ]*\).*/\1/p')"
    start="$(printf '%s\n' "$ln" | sed -n 's/.* start=\([^ ]*\).*/\1/p')"
    commits="$(printf '%s\n' "$ln" | sed -n 's/.* commits=\([^ ]*\).*/\1/p')"
    # Tier: the latest of the packet's trailer commits that carries one.
    tier=""
    for c in $(printf '%s' "$commits" | tr ',' '\n' | sed -n '1!G;h;$p'); do
      tier="$(commit_tier "$src" "$c")"
      [ -z "$tier" ] || break
    done
    tier="$(printf '%s' "${tier:-unrecorded}" | tr '\t' ' ')"
    fix="$(ID="$id" awk -F'\t' '$1 == ENVIRON["ID"] { print $2; exit }' "$tmp/fix")"
    [ -n "$fix" ] || fix="unmeasured"
    # Title: the subject line of the packet's earliest trailer commit.
    first="${commits%%,*}"
    title="$(git -C "$src" log -1 --format=%s "$first" 2>/dev/null | tr -d '\r' | tr '\t' ' ')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$class" "$tier" "$fix" "$id" "$handoff" "$start" "$commits" "$title" >> "$tmp/rows"
  done <<EOF
$cout
EOF
  sed -n '1!G;h;$p' "$tmp/rows" > "$tmp/newest"

  # Per class, within that class's own candidates only (never the other's):
  #   1. the newest packet with measured fix rounds of 1 or more, if any;
  #   2. while fewer than two distinct RECORDED tiers are chosen, the newest
  #      packet with a recorded tier not yet chosen (`unrecorded` is the
  #      absence of a trailer, so it never counts toward the tier mix);
  #   3. fill the rest newest-first.
  # Selected rows keep newest-first order. A shortfall is one `F` row:
  #   F class kind wanted found available [unmeasured]
  awk -F'\t' -v N="$per" '
    { cls = $1; i = ++cnt[cls]; row[cls, i] = $0; tr[cls, i] = $2; fx[cls, i] = $3 }
    function pick(c, i) {
      sel[c, i] = 1; picked[c]++
      if (tr[c, i] != "unrecorded" && !((c, tr[c, i]) in tiers)) { tiers[c, tr[c, i]] = 1; ntiers[c]++ }
    }
    function fixed(c, i) { return fx[c, i] ~ /^[0-9]+$/ && fx[c, i] + 0 >= 1 }
    END {
      split("code prose", classes, " ")
      for (k = 1; k <= 2; k++) {
        c = classes[k]; n = cnt[c] + 0; picked[c] = 0; ntiers[c] = 0
        for (i = 1; i <= n; i++) if (picked[c] < N && fixed(c, i)) { pick(c, i); break }
        while (picked[c] < N && ntiers[c] < 2) {
          got = 0
          for (i = 1; i <= n; i++)
            if (!((c, i) in sel) && tr[c, i] != "unrecorded" && !((c, tr[c, i]) in tiers)) { pick(c, i); got = 1; break }
          if (!got) break
        }
        for (i = 1; i <= n; i++) if (picked[c] < N && !((c, i) in sel)) pick(c, i)
        for (i = 1; i <= n; i++) if ((c, i) in sel) print "S\t" row[c, i]

        avt = 0; avf = 0; unm = 0; delete seen
        for (i = 1; i <= n; i++) {
          if (tr[c, i] != "unrecorded" && !(tr[c, i] in seen)) { seen[tr[c, i]] = 1; avt++ }
          if (fixed(c, i)) avf++
          if (fx[c, i] == "unmeasured") unm++
        }
        sf = 0
        for (i = 1; i <= n; i++) if (((c, i) in sel) && fixed(c, i)) sf++
        if (n < N) print "F\t" c "\tcount\t" N "\t" n "\t" n
        if (ntiers[c] < 2) print "F\t" c "\ttiers\t2\t" ntiers[c] "\t" avt
        if (sf < 1) print "F\t" c "\tfix-rounds\t1\t" sf "\t" avf "\t" unm
      }
    }' "$tmp/newest" > "$tmp/picked"

  printf '%s\n' "$cout" | awk '
    /^EXCLUDED / { p = $2; sub(/^packet=/, "", p); r = $0; sub(/^EXCLUDED packet=[^ ]* reason=/, "", r); print "X\t" p "\t" r }
    /^DROPPED /  { p = $2; sub(/^packet=/, "", p); print "D\t" p }' > "$tmp/other"

  # The selection document: one packet, shortfall or exclusion per line, so it
  # reads as the listing it is. `fix_rounds` is a number only when measured.
  printf '%s\n' "$sout" > "$tmp/settings"
  SRC="$src" SETTINGS="$tmp/settings" PICKED="$tmp/picked" OTHER="$tmp/other" awk -F'\t' '
    function esc(s) {
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s)
      gsub(/[[:cntrl:]]/, " ", s)
      return "\"" s "\""
    }
    function arr(csv,    n, a, i, o) {
      n = split(csv, a, ","); o = ""
      for (i = 1; i <= n; i++) o = o (i > 1 ? ", " : "") esc(a[i])
      return "[" o "]"
    }
    function pinmap(csv,    n, a, i, o, q) {
      n = split(csv, a, ","); o = ""
      for (i = 1; i <= n; i++) {
        q = index(a[i], ":")
        o = o (i > 1 ? ", " : "") esc(substr(a[i], 1, q - 1)) ": " esc(substr(a[i], q + 1))
      }
      return "{" o "}"
    }
    FILENAME == ENVIRON["SETTINGS"] {
      p = index($0, "="); if (p) kv[substr($0, 1, p - 1)] = substr($0, p + 1); next
    }
    FILENAME == ENVIRON["PICKED"] && $1 == "S" {
      ns++
      S[ns] = "    {\"packet\": " esc($5) ", \"class\": " esc($2) ", \"tier\": " esc($3) \
              ", \"fix_rounds\": " ($4 ~ /^[0-9]+$/ ? $4 : esc($4)) ", \"title\": " esc($9) \
              ", \"handoff\": " esc($6) ", \"start\": " esc($7) ", \"commits\": " arr($8) "}"
      next
    }
    FILENAME == ENVIRON["PICKED"] && $1 == "F" {
      nf++
      F[nf] = "    {\"class\": " esc($2) ", \"kind\": " esc($3) ", \"wanted\": " $4 ", \"found\": " $5 \
              ", \"available\": " $6 ($3 == "fix-rounds" ? ", \"unmeasured\": " $7 : "") "}"
      next
    }
    FILENAME == ENVIRON["OTHER"] && $1 == "X" { nx++; X[nx] = "    {\"packet\": " esc($2) ", \"reason\": " esc($3) "}"; next }
    FILENAME == ENVIRON["OTHER"] && $1 == "D" { nd++; D[nd] = "    " esc($2); next }
    function block(name, A, n, last,    i) {
      printf "  \"%s\": [", name
      if (n == 0) { printf "]%s\n", (last ? "" : ","); return }
      printf "\n"
      for (i = 1; i <= n; i++) printf "%s%s\n", A[i], (i < n ? "," : "")
      printf "  ]%s\n", (last ? "" : ",")
    }
    END {
      printf "{\n"
      printf "  \"experiment\": %s,\n", esc(kv["EXPERIMENT"])
      printf "  \"settings\": {\"role\": %s, \"models\": %s, \"reviewer_model\": %s, \"model_ids\": %s, \"effort\": %s, \"source_repo\": %s, \"per_class\": %s, \"code_files\": %s, \"prose_files\": %s},\n", \
        esc(kv["ROLE"]), arr(kv["MODELS"]), esc(kv["REVIEWER_MODEL"]), pinmap(kv["MODEL_IDS"]), esc(kv["EFFORT"]), esc(ENVIRON["SRC"]), kv["PER_CLASS"] + 0, arr(kv["CODE_FILES"]), arr(kv["PROSE_FILES"])
      block("selected", S, ns, 0)
      block("shortfalls", F, nf, 0)
      block("excluded", X, nx, 0)
      block("dropped", D, nd, 1)
      printf "}\n"
    }' "$tmp/settings" "$tmp/picked" "$tmp/other" > "$tmp/selection.json" \
    || die "select: the selection could not be rendered"

  mkdir -p "$dir" || die "select: cannot create the experiment store: $dir"
  cp "$tmp/selection.json" "$dir/.selection.json.$$" && mv "$dir/.selection.json.$$" "$sel" \
    || die "select: cannot write the selection: $sel"
  cat "$sel"
  printf 'compare.sh: selection written: %s\n' "$sel" >&2
}

# --- estimate ----------------------------------------------------------------------

# json_flat <file>: one `<doc>\t<path>\t<type>\t<value>` row per scalar leaf of
# the JSON in <file>, where <doc> numbers the top-level values (1 for a plain
# JSON file, one per line of a JSONL file), <path> is jq-style (`.a.b[0].c`),
# <type> is `s` for a string and `n` for any other literal (number, true,
# false, null), and <value> is the string unescaped (a tab or newline in it
# becomes a space). An empty container emits nothing. Exit 1 on a token it
# cannot read, so a damaged file is refused rather than half-read.
json_flat() {
  awk '
    function here(   p) {
      if (d == 0) { doc++; return "" }
      if (ty[d] == "o") return pre[d] "." ky[d]
      return pre[d] "[" ix[d] "]"
    }
    function emit(t, v) { if (d == 0) { bad = 1; exit } p = here(); print doc "\t" p "\t" t "\t" v }
    function open(kind,   p) { p = here(); d++; ty[d] = kind; pre[d] = p; ix[d] = 0; wk[d] = (kind == "o"); ky[d] = "" }
    function unesc(s) {
      gsub(/\\\\/, "\001", s); gsub(/\\"/, "\"", s); gsub(/\\\//, "/", s)
      gsub(/\\[tnr]/, " ", s); gsub(/\t/, " ", s); gsub(/\001/, "\\", s)
      return s
    }
    BEGIN { d = 0; doc = 0; bad = 0 }
    { sub(/\r$/, "") }
    {
      line = $0
      while (length(line) > 0) {
        if (match(line, /^[ \t]+/)) { line = substr(line, RLENGTH + 1); continue }
        c = substr(line, 1, 1)
        if (c == "\"") {
          if (!match(line, /^"([^"\\]|\\.)*"/)) { bad = 1; exit }
          tok = unesc(substr(line, 2, RLENGTH - 2)); line = substr(line, RLENGTH + 1)
          if (d > 0 && ty[d] == "o" && wk[d]) { ky[d] = tok; wk[d] = 0 } else emit("s", tok)
          continue
        }
        if (c == "{") { open("o"); line = substr(line, 2); continue }
        if (c == "[") { open("a"); line = substr(line, 2); continue }
        if (c == "}" || c == "]") {
          if (d == 0 || (c == "}") != (ty[d] == "o")) { bad = 1; exit }
          d--; line = substr(line, 2); continue
        }
        if (c == ",") {
          if (d == 0) { bad = 1; exit }
          if (ty[d] == "a") ix[d]++; else wk[d] = 1
          line = substr(line, 2); continue
        }
        if (c == ":") { if (d == 0 || ty[d] != "o") { bad = 1; exit } line = substr(line, 2); continue }
        if (match(line, /^[-+.0-9A-Za-z]+/)) {
          tok = substr(line, 1, RLENGTH); line = substr(line, RLENGTH + 1)
          # A bare word must be a JSON literal, and only inside a container:
          # every file read here is an object (or one object per line).
          if (d == 0 || tok !~ /^(true|false|null|-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?)$/) { bad = 1; exit }
          emit("n", tok); continue
        }
        bad = 1; exit
      }
    }
    END { if (bad || d != 0) exit 1 }
  ' "$1"
}

# cost_rows <run-metrics.json>: one `<packet>\t<generated_at>\t<run_id>\t<state>\t
# <input>\t<output>\t<cache_creation>\t<cache_read>` row per packets[] entry.
# <state> is `measured`, `null` (a token field is null, absent or not a
# number), `zero` (all four are 0: the packet window caught no usage, and a
# landed packet cost something), or `source` (the file's token_source is not a
# transcript one, so its token figures were never read from a transcript).
cost_rows() {
  local flat
  flat="$(json_flat "$1")" || return 1
  printf '%s\n' "$flat" | awk -F'\t' '
    $2 == ".generated_at" { gen = $4; next }
    $2 == ".token_source" { ts = $4; next }
    $2 == ".run_id"       { rid = $4; next }
    $2 ~ /^\.packets\[[0-9]+\]\./ {
      i = $2; sub(/^\.packets\[/, "", i); sub(/\].*$/, "", i); i += 0; if (i + 1 > n) n = i + 1
      rest = substr($2, index($2, "].") + 2)
      if (rest == "id" && $3 == "s") id[i] = $4
      else if (rest ~ /^tokens\.(input|output|cache_creation|cache_read)$/ && $3 == "n" && $4 ~ /^[0-9]+$/)
        tok[i, substr(rest, 8)] = $4
    }
    END {
      for (i = 0; i < n; i++) {
        if (!(i in id)) continue
        st = "measured"; sum = 0
        split("input output cache_creation cache_read", f, " ")
        for (k = 1; k <= 4; k++) { if (!((i, f[k]) in tok)) st = "null"; else sum += tok[i, f[k]] }
        if (ts !~ /^transcript/) st = "source"
        else if (st == "measured" && sum == 0) st = "zero"
        printf "%s\t%s\t%s\t%s", id[i], gen, rid, st
        for (k = 1; k <= 4; k++) printf "\t%s", ((i, f[k]) in tok) ? tok[i, f[k]] : ""
        printf "\n"
      }
    }'
}

# new_token: 32 hex of /dev/urandom, else a digest of the time, pid and $RANDOM.
new_token() {
  local t
  t="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  case "$t" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) t="$( { date -u +%Y%m%dT%H%M%S; printf '%s %s %s %s\n' "$$" "$RANDOM" "$RANDOM" "$RANDOM"; } | digest)$( printf '%s %s\n' "$RANDOM" "$$" | digest)" ;;
  esac
  printf '%s' "$t"
}

cmd_estimate() {
  local exp="" remaining=0 a
  for a in "$@"; do
    case "$a" in
      --remaining) remaining=1 ;;
      -*) usage ;;
      *) [ -z "$exp" ] || usage; exp="$a" ;;
    esac
  done
  [ -n "$exp" ] || usage
  case "$exp" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "estimate: not an experiment id (12 hex, as \`settings\` prints it): $exp" ;;
  esac
  local store dir sel prices
  store="$(store_root)"
  dir="$store/$exp"
  sel="$dir/selection.json"
  prices="${ORCH_COMPARE_PRICES:-$HERE/spend-prices.json}"
  [ -f "$sel" ] || die "estimate: no stored selection for experiment $exp (run \`compare.sh select\` first): $sel"

  local tmp
  tmp="$(mktemp -d 2>/dev/null)" || die "estimate: cannot create a temp root"
  # shellcheck disable=SC2064  # expand $tmp now: it is local to this function
  trap "rm -rf '$tmp'" EXIT

  # --- the stored selection: its experiment, models, source and packets -------
  json_flat "$sel" > "$tmp/sel" || die "estimate: the stored selection is not readable JSON: $sel"
  local sexp src
  sexp="$(awk -F'\t' '$2 == ".experiment" { print $4; exit }' "$tmp/sel")"
  [ "$sexp" = "$exp" ] || die "estimate: the stored selection names experiment [$sexp], not $exp: $sel"
  src="$(awk -F'\t' '$2 == ".settings.source_repo" { print $4; exit }' "$tmp/sel")"
  awk -F'\t' '$2 ~ /^\.settings\.models\[[0-9]+\]$/ { print $4 }' "$tmp/sel" > "$tmp/models"
  awk -F'\t' '$2 ~ /^\.selected\[[0-9]+\]\.packet$/ { print $4 }' "$tmp/sel" > "$tmp/packets"
  # Every id goes into output lines and the approvals JSON: only safe tokens.
  if LC_ALL=C grep -q '[^A-Za-z0-9._-]' "$tmp/models" "$tmp/packets" 2>/dev/null \
     || [ ! -s "$tmp/models" ]; then
    die "estimate: the stored selection's models or packets are malformed: $sel"
  fi

  # --- the replay set: packet x model, stored order; recorded ones set apart ---
  : > "$tmp/recorded"
  if [ "$remaining" -eq 1 ] && [ -f "$store/records.jsonl" ]; then
    json_flat "$store/records.jsonl" > "$tmp/records.flat" \
      || die "estimate: the records file is not readable JSONL, so the remaining replays cannot be counted: $store/records.jsonl"
    EXP="$exp" awk -F'\t' '
      $2 == ".experiment" && $3 == "s" { e[$1] = $4 }
      $2 == ".packet"     && $3 == "s" { p[$1] = $4 }
      $2 == ".model"      && $3 == "s" { m[$1] = $4 }
      END { for (d in e) if (e[d] == ENVIRON["EXP"] && (d in p) && (d in m)) print p[d] "\t" m[d] }
    ' "$tmp/records.flat" | LC_ALL=C sort -u > "$tmp/recorded"
  fi
  local p m nrec=0
  : > "$tmp/set"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      if [ "$remaining" -eq 1 ] && P="$p" M="$m" awk -F'\t' '$1 == ENVIRON["P"] && $2 == ENVIRON["M"] { f = 1 } END { exit !f }' "$tmp/recorded"; then
        nrec=$((nrec + 1)); continue
      fi
      printf '%s\t%s\n' "$p" "$m" >> "$tmp/set"
    done < "$tmp/models"
  done < "$tmp/packets"

  # --- each packet's original cost from the source's stored run-metrics --------
  local f nbad=0
  : > "$tmp/costs"
  if [ -n "$src" ] && [ -d "$src/.agents/metrics" ]; then
    set +f
    for f in "$src"/.agents/metrics/*/run-metrics.json; do
      [ -f "$f" ] || continue
      cost_rows "$f" >> "$tmp/costs" 2>/dev/null || nbad=$((nbad + 1))
    done
    set -f
  fi

  # --- the price table ------------------------------------------------------
  [ -f "$prices" ] || die "estimate: no price table: $prices"
  json_flat "$prices" > "$tmp/prices" || die "estimate: the price table is not readable JSON: $prices"
  local tdate
  tdate="$(awk -F'\t' '$2 == ".table_date" && $3 == "s" { print $4; exit }' "$tmp/prices")"
  [ -n "$tdate" ] || die "estimate: the price table has no table_date: $prices"

  # --- the estimate ------------------------------------------------------------
  local scope=all; [ "$remaining" -eq 1 ] && scope=remaining
  SET="$tmp/set" COSTS="$tmp/costs" PRICES="$tmp/prices" MODELS="$tmp/models" \
  EXP="$exp" SCOPE="$scope" NREC="$nrec" TDATE="$tdate" NBAD="$nbad" \
  NPACK="$(grep -c . "$tmp/packets")" awk -F'\t' '
    function money(x) { return sprintf("%.2f", x) }
    function int0(x)  { return sprintf("%.0f", x) }
    FILENAME == ENVIRON["MODELS"] { if ($0 != "") { nm++; mod[nm] = $0 }; next }
    FILENAME == ENVIRON["SET"]    { ns++; sp[ns] = $1; sm[ns] = $2; if (!($1 in inset)) { inset[$1] = 1; np++; pord[np] = $1 }; next }
    FILENAME == ENVIRON["PRICES"] {
      if ($2 ~ /^\.prices\.[^.]+\.(input|output|cache_read|cache_write_5m|cache_write_1h)$/ && $3 == "n" && $4 ~ /^[0-9.]+$/) {
        k = substr($2, 9); fld = k; sub(/\.[^.]*$/, "", k); sub(/^.*\./, "", fld)
        rate[k, fld] = $4 + 0; if (!(k in pid)) { pid[k] = 1; npid++; pids[npid] = k }
      }
      next
    }
    FILENAME == ENVIRON["COSTS"] {
      if (!($1 in inset)) next
      rows[$1]++; st[$1, $4]++
      if ($4 == "measured" && (!($1 in bgen) || $2 >= bgen[$1])) {
        bgen[$1] = $2; brun[$1] = $3; ti[$1] = $5; to[$1] = $6; tc[$1] = $7; tr[$1] = $8
      }
      next
    }
    function complete(k) {
      return ((k, "input") in rate) && ((k, "output") in rate) && ((k, "cache_read") in rate) && \
             ((k, "cache_write_5m") in rate) && ((k, "cache_write_1h") in rate)
    }
    function same(a, b) {
      return rate[a, "input"] == rate[b, "input"] && rate[a, "output"] == rate[b, "output"] && \
             rate[a, "cache_read"] == rate[b, "cache_read"] && rate[a, "cache_write_5m"] == rate[b, "cache_write_5m"] && \
             rate[a, "cache_write_1h"] == rate[b, "cache_write_1h"]
    }
    # resolve(m): sets use[m] to the price key and basis[m], or why[m].
    function resolve(m,   pre, j, k, ids, first, diff) {
      if ((m in pid) && complete(m)) { use[m] = m; basis[m] = m; return }
      if (m in pid) { why[m] = "the price-table entry " m " lacks one of input, output, cache_read, cache_write_5m, cache_write_1h"; return }
      pre = "claude-" m "-"; ids = ""; first = ""; diff = 0
      for (j = 1; j <= npid; j++) {
        k = pids[j]
        if (index(k, pre) != 1) continue
        ids = ids (ids == "" ? "" : ",") k
        if (!complete(k)) { diff = 2; continue }
        if (first == "") first = k; else if (!same(first, k)) diff = (diff ? diff : 1)
      }
      if (ids == "") { why[m] = "no price-table entry is keyed " m " or starts " pre; return }
      if (diff == 2) { why[m] = "a " pre "* entry lacks a rate (" ids ")"; return }
      if (diff == 1) { why[m] = "the " pre "* entries carry different rates, and which one " m " resolves to is not recorded (" ids ")"; return }
      use[m] = first; basis[m] = "family:" ids
    }
    function cost(p, k, cw) {
      return (ti[p] * rate[k, "input"] + to[p] * rate[k, "output"] + tr[p] * rate[k, "cache_read"] + tc[p] * rate[k, cw]) / 1000000
    }
    function line(label, r, e, ok, a, b, c, dd, lo, hi, priced, extra) {
      printf "ESTIMATE model=%s replays=%d estimated=%d", label, r, e
      if (r > 0 && e == 0)
        printf " tokens=unmeasured input=unmeasured output=unmeasured cache_creation=unmeasured cache_read=unmeasured"
      else
        printf " tokens=%s input=%s output=%s cache_creation=%s cache_read=%s", int0(a + b + c + dd), int0(a), int0(b), int0(c), int0(dd)
      if (r == 0) printf " dollars_min=0.00 dollars_max=0.00"
      else if (e == 0 || !priced) printf " dollars_min=unmeasured dollars_max=unmeasured"
      else printf " dollars_min=%s dollars_max=%s", money(lo), money(hi)
      printf "%s\n", extra
    }
    END {
      printf "EXPERIMENT=%s\nSCOPE=%s\n", ENVIRON["EXP"], ENVIRON["SCOPE"]
      ml = ""; for (i = 1; i <= nm; i++) ml = ml (i > 1 ? "," : "") mod[i]
      printf "MODELS=%s\nPACKETS=%d\nRECORDED=%d\nREPLAYS=%d\n", ml, ENVIRON["NPACK"], ENVIRON["NREC"], ns
      for (i = 1; i <= ns; i++) printf "REPLAY packet=%s model=%s\n", sp[i], sm[i]
      printf "PRICE_TABLE_DATE=%s\n", ENVIRON["TDATE"]

      # A packet counts only with a measured original cost; every other packet
      # in the set is named and left out, never priced as 0.
      for (j = 1; j <= np; j++) {
        p = pord[j]
        if (p in bgen) continue
        if (!(p in rows)) r = "no run-metrics row for the packet in the source repository"
        else r = "no measured row among " rows[p] " run-metrics row(s) (tokens null: " st[p, "null"] + 0 \
                 ", all zero: " st[p, "zero"] + 0 ", no transcript token source: " st[p, "source"] + 0 ")"
        printf "EXCLUDED packet=%s reason=original cost unmeasured, excluded from the estimate: %s\n", p, r
      }
      for (i = 1; i <= nm; i++) { resolve(mod[i]); if (mod[i] in why) printf "UNPRICED model=%s reason=%s\n", mod[i], why[mod[i]] }

      allpriced = 1
      for (i = 1; i <= nm; i++) {
        m = mod[i]; R = 0; E = 0; A = 0; B = 0; C = 0; D = 0; LO = 0; HI = 0
        for (s = 1; s <= ns; s++) {
          if (sm[s] != m) continue
          R++; p = sp[s]
          if (!(p in bgen)) continue
          E++; A += ti[p]; B += to[p]; C += tc[p]; D += tr[p]
          if (m in use) { LO += cost(p, use[m], "cache_write_5m"); HI += cost(p, use[m], "cache_write_1h") }
        }
        if (R > 0 && !(m in use)) allpriced = 0
        TR += R; TE += E; TA += A; TB += B; TC += C; TD += D; TLO += LO; THI += HI
        line(m, R, E, (m in use), A, B, C, D, LO, HI, (m in use), " price=" ((m in use) ? basis[m] : "unpriced"))
      }
      line("total", TR, TE, allpriced, TA, TB, TC, TD, TLO, THI, allpriced, "")
      if (ENVIRON["NBAD"] + 0 > 0)
        printf "NOTE %d run-metrics file(s) in the source repository could not be read; a packet whose only row is in one reads unmeasured\n", ENVIRON["NBAD"]
      printf "NOTE tokens are each packet'"'"'s original recorded tokens, held constant across models; fix rounds are not modelled\n"
      printf "NOTE dollars_min prices every cache-write token at the 5-minute rate and dollars_max at the 1-hour rate: the recorded tokens do not split write lifetime\n"
    }' "$tmp/models" "$tmp/set" "$tmp/prices" "$tmp/costs" > "$tmp/out" \
    || die "estimate: the estimate could not be computed"

  # --- the approval token: stored pending BEFORE it is printed ---------------
  local tok="none"
  if [ -s "$tmp/set" ]; then
    local setd issued replays
    setd="$(grep '^REPLAY ' "$tmp/out" | digest)" || exit 1
    tok="$(new_token)"
    [ -n "$tok" ] || die "estimate: no approval token could be generated"
    if [ -f "$dir/approvals.jsonl" ] && T="\"token\":\"$tok\"" awk 'index($0, ENVIRON["T"]) { f = 1 } END { exit !f }' "$dir/approvals.jsonl"; then
      die "estimate: the generated token already exists in $dir/approvals.jsonl; run estimate again"
    fi
    issued="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    replays="$(awk -F'\t' '{ printf "%s{\"packet\":\"%s\",\"model\":\"%s\"}", (NR > 1 ? "," : ""), $1, $2 }' "$tmp/set")"
    printf '{"token":"%s","state":"pending","experiment":"%s","scope":"%s","issued_at":"%s","set":"%s","replays":[%s]}\n' \
      "$tok" "$exp" "$scope" "$issued" "$setd" "$replays" >> "$dir/approvals.jsonl" \
      || die "estimate: the approval token could not be stored: $dir/approvals.jsonl"
  fi
  cat "$tmp/out"
  printf 'APPROVAL=%s\n' "$tok"
}

# --- prepare -----------------------------------------------------------------------

# names_model <name> <ids-file>: does <name> contain any identifier listed in
# <ids-file>, one per line, compared case-insensitively?
names_model() {
  NAME="$1" awk 'BEGIN { n = tolower(ENVIRON["NAME"]) } $0 != "" && index(n, tolower($0)) { f = 1 } END { exit !f }' "$2"
}

# opaque_name <prefix> <ids-file>: <prefix><16 hex>, redrawn while it contains
# any identifier in <ids-file>. Exit 1 when no draw is clean.
opaque_name() {
  local i t
  for i in 1 2 3 4 5 6 7 8 9 10; do
    t="$1$(new_token | cut -c1-16)"
    if [ "${#t}" -eq $(( ${#1} + 16 )) ] && ! names_model "$t" "$2"; then printf '%s' "$t"; return 0; fi
  done
  return 1
}

# set_routing <in> <out> <role> <model> <reviewer-model>: <in> (absent or not)
# rewritten to <out> with the top-level `model_routing` mapping <role> to
# <model> and `reviewer` to <reviewer-model>. Every other line is kept verbatim;
# the block's own entry indentation is reused (routing.sh requires one indent);
# a flow-form map is rewritten as a block; an absent key is appended. Exit 3
# when the map cannot be read (a flow value that is not one `{...}`, or a
# second `model_routing:` key, which routing.sh reads as unparseable anyway).
# An EMPTY <role> is the review view's reviewer-only form: every entry of the
# map is dropped (comment and blank lines in it are kept) and only `reviewer`
# is written, so no other agent's model is named by the view's routing.
set_routing() {
  local in="$1"
  [ -f "$in" ] || in=/dev/null
  ROLE="$3" MODEL="$4" RM="$5" awk '
    BEGIN { only = (ENVIRON["ROLE"] == "") }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function keyof(s,   p) {
      s = trim(s); p = match(s, /:([[:space:]]|$)/); if (p == 0) return ""
      s = trim(substr(s, 1, p - 1))
      if (length(s) >= 2 && (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/)) s = substr(s, 2, length(s) - 2)
      return s
    }
    function emit(   i, ind) {
      ind = (ei == "" ? "  " : ei)
      print "model_routing:"
      if (!only) print ind ENVIRON["ROLE"] ": " ENVIRON["MODEL"]
      print ind "reviewer: " ENVIRON["RM"]
      for (i = 1; i <= nb; i++) print buf[i]
      nb = 0; inb = 0; done = 1
    }
    { sub(/\r$/, "") }
    inb {
      if ($0 ~ /^[[:space:]]*(#.*)?$/) { buf[++nb] = $0; next }
      if ($0 ~ /^[[:space:]]/) {
        if (ei == "") { match($0, /^[[:space:]]+/); ei = substr($0, 1, RLENGTH) }
        k = keyof($0)
        if (only || k == ENVIRON["ROLE"] || k == "reviewer") next
        buf[++nb] = $0; next
      }
      emit()
    }
    /^model_routing:/ {
      if (done) { bad = 1; next }
      rest = substr($0, length("model_routing:") + 1)
      rest = trim(rest); if (rest ~ /^#/) rest = ""
      sub(/[[:space:]]+#.*$/, "", rest); rest = trim(rest)
      if (rest == "") { inb = 1; next }
      if (rest !~ /^\{[^{}]*\}$/) { bad = 1; done = 1; next }
      inner = trim(substr(rest, 2, length(rest) - 2))
      n = (inner == "" ? 0 : split(inner, pcs, ","))
      for (i = 1; i <= n; i++) {
        pc = trim(pcs[i]); if (pc == "") continue
        k = keyof(pc); if (k == "") { bad = 1; continue }
        if (only || k == ENVIRON["ROLE"] || k == "reviewer") continue
        buf[++nb] = "  " pc
      }
      emit(); next
    }
    { print }
    END {
      if (inb) emit()
      if (!done) {
        print "model_routing:"
        if (!only) print "  " ENVIRON["ROLE"] ": " ENVIRON["MODEL"]
        print "  reviewer: " ENVIRON["RM"]
      }
      if (bad) exit 3
    }' "$in" > "$2"
}

# first_dispatch <in> <out>: the handoff as its FIRST dispatch received it.
# The loop splices two marked blocks into a handoff after that dispatch, and a
# replay starts before the work they describe existed, so both are removed:
#   - `runstate.sh amend-handoff` appends "\n" + its block (begin marker line
#     through end marker line); the removed span is that "\n" plus the block,
#     which is what it added whether or not the file ended in a newline.
#   - `runstate.sh refresh-handoff` inserts its block after the header plus one
#     blank line after it; the removed span is the block plus that blank line,
#     exactly what its own "remove" path drops.
# Every other byte is kept, the `orch:budget` block and any driver REQUIRED
# lines included: the first dispatch had them. Amendment spans go first, so an
# amendment whose text quotes a partial-work marker is removed whole. A marker
# line left over afterwards (unterminated, or at the top of the file where
# neither command writes one) is not a span either command wrote: exit 3,
# refused rather than guessed. The markers are runstate.sh's `_RS_AMEND_*` and
# `_RS_PARTIAL_*` constants, repeated here because this script never sources it.
_CMP_AMEND_BEGIN='<!-- orch:decider-amendment -->'
_CMP_AMEND_END='<!-- /orch:decider-amendment -->'
_CMP_PARTIAL_BEGIN='<!-- orch:partial-work -->'
_CMP_PARTIAL_END='<!-- /orch:partial-work -->'
first_dispatch() {
  local c nl=$'\n' pre rest
  c="$(cat "$1" && printf x)" || return 1
  c="${c%x}"
  while :; do
    case "$c" in *"$nl$_CMP_AMEND_BEGIN$nl"*) ;; *) break ;; esac
    pre="${c%%"$nl$_CMP_AMEND_BEGIN$nl"*}"
    rest="${c#*"$nl$_CMP_AMEND_BEGIN$nl"}"
    case "$rest" in
      *"$nl$_CMP_AMEND_END$nl"*) rest="${rest#*"$nl$_CMP_AMEND_END$nl"}" ;;
      *"$nl$_CMP_AMEND_END") rest="" ;;
      *) return 3 ;;
    esac
    c="$pre$rest"
  done
  while :; do
    case "$c" in *"$nl$_CMP_PARTIAL_BEGIN$nl"*) ;; *) break ;; esac
    pre="${c%%"$nl$_CMP_PARTIAL_BEGIN$nl"*}$nl"
    rest="${c#*"$nl$_CMP_PARTIAL_BEGIN$nl"}"
    case "$rest" in
      *"$nl$_CMP_PARTIAL_END$nl"*) rest="${rest#*"$nl$_CMP_PARTIAL_END$nl"}"; rest="${rest#"$nl"}" ;;
      *"$nl$_CMP_PARTIAL_END") rest="" ;;
      *) return 3 ;;
    esac
    c="$pre$rest"
  done
  case "$nl$c$nl" in
    *"$nl$_CMP_AMEND_BEGIN$nl"*|*"$nl$_CMP_AMEND_END$nl"*|*"$nl$_CMP_PARTIAL_BEGIN$nl"*|*"$nl$_CMP_PARTIAL_END$nl"*)
      return 3 ;;
  esac
  printf '%s' "$c" > "$2"
}

# --- what a session leaves in its clone: harness-side git, copies and reads ----------
# A session can rewrite its clone's git configuration: compare-confine.sh refuses
# the file tools and the shell writes it recognises under `.git/`, but `git config`
# in Bash is no write it sees, and the sandbox allows the whole clone. What that
# configuration names, git runs, outside the sandbox when the harness runs it:
# core.fsmonitor, a hook under core.hooksPath or .git/hooks (reference-transaction
# on update-ref, post-index-change on any index write), a filter, diff or merge
# driver an attribute assigns. So every harness-side git command on a clone or
# view runs with those overridden at git's command scope, which outranks every
# configuration file: core.fsmonitor off, core.hooksPath at /dev/null (no hook of
# any name is found there), signature checks and signing off and every signing
# program emptied, submodules ignored, and every filter, diff and merge driver and any
# diff.external the repository's own configuration (local or worktree scope,
# includes followed) defines emptied, its filter not required. An emptied diff
# command fails rather than runs, so the harness's own diffs on a clone also
# pass --no-ext-diff --no-textconv. Lazy fetch and the transports it opens are
# neutralised too: a promisor remote (remote.<name>.promisor or
# .partialclonefilter, or extensions.partialClone) makes any git that looks up a
# missing object (`git log` on a sha that does not exist) fetch it, running the
# remote's uploadpack program; GIT_NO_LAZY_FETCH=1 turns that fetch off (git
# 2.45 on), and git_own_repo refuses a repository whose own configuration names a
# promisor remote at all, for an older git that ignores the variable. A
# command-scope protocol.allow=never is no substitute: a planted
# protocol.<name>.allow outranks it. The overrides travel in GIT_CONFIG_COUNT /
# GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n>, git's environment form of `-c`, so
# the git that runstate.sh, routing.sh and metrics.sh run in the clone is covered
# too, and GIT_NO_LAZY_FETCH with them; run_session takes both back off, so a
# session's own git is as its repository sets it. _CMP_GIT_BASE is the count the
# operator's own environment held (`none`: unset), and _CMP_GIT_NOLAZY its
# GIT_NO_LAZY_FETCH (empty: unset; `=<value>`: set), exported so a compare.sh
# this one starts appends at the same place and restores the same value.
_CMP_GIT_BASE="${_CMP_GIT_BASE:-${GIT_CONFIG_COUNT:-none}}"
export _CMP_GIT_BASE
_CMP_GIT_NOLAZY="${_CMP_GIT_NOLAZY-${GIT_NO_LAZY_FETCH+=$GIT_NO_LAZY_FETCH}}"
export _CMP_GIT_NOLAZY
_CMP_GIT_REPOS=""

# git_own_repo <dir>: 0 when <dir> is a repository of its own: `.git` a real
# directory (not a symlink, not a `gitdir:` file), git's directory and common
# directory both that one (no `commondir` file sending refs and configuration
# elsewhere), and its work tree <dir> itself (no core.worktree). Otherwise every
# harness command on it would act on some other repository or directory. And no
# other repository inside it: no `.git` (directory, file or link, any case) below
# <dir> outside its own `.git`, since git runs a nested repository's commands (a
# gitlink's filters on `git status`) from that repository's own configuration,
# which git_neutral does not list. And no promisor remote: its own configuration
# (local or worktree scope, includes followed) sets no extensions.partialClone and
# no remote.<name>.promisor or remote.<name>.partialclonefilter, any one of which
# makes git lazily fetch a missing object through that remote's uploadpack
# program, which a git before 2.45 does even with GIT_NO_LAZY_FETCH set.
git_own_repo() {
  local d g c t n scope name
  d="$(cd "$1" 2>/dev/null && pwd -P)" && [ -n "$d" ] || return 1
  [ -d "$d/.git" ] && [ ! -L "$d/.git" ] || return 1
  n="$(cd "$d" && find . -path ./.git -prune -o -iname .git -print 2>/dev/null)" || return 1
  [ -z "$n" ] || return 1
  # Names only, one per line (a configuration name holds no newline): the section
  # and key lowercased by git, the scope before a tab.
  n="$(git -C "$d" config --list --show-scope --name-only 2>/dev/null)" || return 1
  while IFS=$'\t' read -r scope name; do
    case "$scope" in local|worktree) ;; *) continue ;; esac
    case "$name" in
      extensions.partialclone|remote.?*.promisor|remote.?*.partialclonefilter) return 1 ;;
    esac
  done <<< "$n"
  g="$(cd "$d" && cd "$(git rev-parse --absolute-git-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  c="$(cd "$d" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  t="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  t="$(cd "$t" 2>/dev/null && pwd -P)" || return 1
  [ "$g" = "$d/.git" ] && [ "$c" = "$d/.git" ] && [ "$t" = "$d" ]
}

# git_neutral [<repo>...]: add each <repo> to the repositories this process acts
# on, then export the overrides for every one of them, recomputed from their
# configuration as it now stands (a session may have added a driver since the
# last call). Return 1 when a repository fails git_own_repo, its configuration
# cannot be listed, or git does not read the overrides back (a git before 2.31
# ignores the environment form): the caller stops rather than run git unguarded.
git_neutral() {
  local r base i n scope name sub s
  for r in "$@"; do _CMP_GIT_REPOS="$_CMP_GIT_REPOS$r"$'\n'; done
  case "$_CMP_GIT_BASE" in none) base=0 ;; ''|*[!0-9]*) return 1 ;; *) base="$_CMP_GIT_BASE" ;; esac
  [ -n "$_CMP_TMP" ] || return 1
  # No lazy fetch from here on, before this function's own git runs: the listing
  # below, and every git after it.
  export GIT_NO_LAZY_FETCH=1
  # The fixed overrides: the commands no driver name selects. Signature checks and
  # signing run gpg.program (log.showSignature makes every `git log` and `git show`
  # check each commit it prints, commit.gpgSign makes commit-tree sign), so those
  # are off and every signing program is emptied; submodules are ignored and never
  # recursed into, since a nested repository's own configuration is not listed here
  # (git_own_repo refuses a repository with one).
  local -a k=(core.fsmonitor core.hooksPath log.showSignature commit.gpgSign tag.gpgSign
              merge.verifySignatures gpg.program gpg.openpgp.program gpg.x509.program
              gpg.ssh.program gpg.ssh.defaultKeyCommand diff.ignoreSubmodules submodule.recurse)
  local -a v=(false /dev/null false false false false "" "" "" "" "" all false)
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    git_own_repo "$r" || return 1
    # Listed with only the operator's own overrides in force.
    GIT_CONFIG_COUNT="$base" git -C "$r" config --list --show-scope --name-only -z > "$_CMP_TMP/gn.cfg" 2>/dev/null \
      || return 1
    while IFS= read -r -d '' scope && IFS= read -r -d '' name; do
      case "$scope" in local|worktree) ;; *) continue ;; esac
      case "$name" in
        filter.?*.clean|filter.?*.smudge|filter.?*.process|filter.?*.required)
          sub="${name#filter.}"; sub="${sub%.*}"
          for s in clean smudge process; do k+=("filter.$sub.$s"); v+=(""); done
          k+=("filter.$sub.required"); v+=(false) ;;
        diff.?*.command|diff.?*.textconv)
          sub="${name#diff.}"; sub="${sub%.*}"
          k+=("diff.$sub.command" "diff.$sub.textconv"); v+=("" "") ;;
        merge.?*.driver)
          sub="${name#merge.}"; sub="${sub%.*}"
          k+=("merge.$sub.driver"); v+=("") ;;
        diff.external) k+=(diff.external); v+=("") ;;
      esac
    done < "$_CMP_TMP/gn.cfg"
  done <<< "$_CMP_GIT_REPOS"
  n=${#k[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    export "GIT_CONFIG_KEY_$((base + i))=${k[$i]}" "GIT_CONFIG_VALUE_$((base + i))=${v[$i]}"
    i=$((i + 1))
  done
  export GIT_CONFIG_COUNT=$((base + n))
  # Read back as text: `--type=bool` checks every value, and dies on the planted
  # path the override outranks.
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$(git -C "$r" config core.hooksPath 2>/dev/null)" = /dev/null ] \
      && [ "$(git -C "$r" config core.fsmonitor 2>/dev/null)" = false ] || return 1
  done <<< "$_CMP_GIT_REPOS"
}

# git_session_env: in a session's own (sub)shell, the operator's git environment
# back as it was: git_neutral's overrides and GIT_NO_LAZY_FETCH taken off.
git_session_env() {
  local i=0
  case "$_CMP_GIT_NOLAZY" in =*) export GIT_NO_LAZY_FETCH="${_CMP_GIT_NOLAZY#=}" ;; *) unset GIT_NO_LAZY_FETCH ;; esac
  unset _CMP_GIT_NOLAZY
  case "$_CMP_GIT_BASE" in none) unset GIT_CONFIG_COUNT ;; *) export GIT_CONFIG_COUNT="$_CMP_GIT_BASE"; i="$_CMP_GIT_BASE" ;; esac
  while [ -n "$(eval "printf '%s' \"\${GIT_CONFIG_KEY_$i+x}\"")" ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
    i=$((i + 1))
  done
  unset _CMP_GIT_BASE
}

# plain_file <file> <root>: 0 when <file> is a regular file that is neither a
# symlink nor one name of several (a hard link), in a directory that lies,
# physically, inside <root>: so reading it reads the clone's own bytes, never a
# file a session linked in from elsewhere.
plain_file() {
  local r d n
  r="$(cd "$2" 2>/dev/null && pwd -P)" && [ -n "$r" ] || return 1
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  case "$d/" in "$r/"*) ;; *) return 1 ;; esac
  n="$(ls -ld -- "$1" 2>/dev/null | awk 'NR == 1 { print $2 }')"
  [ "$n" = 1 ]
}

# runtime_links <clone>: 0 when no symlink and no file with another hard link
# stands where runstate.sh writes in <clone> (`.agents` itself, its run-state
# files, and the loop, metrics and findings trees, all of them runtime paths no
# commit carries), so its writes there land in the clone and nowhere else.
runtime_links() {
  local a="$1/.agents" p out
  for p in "$a" "$a/loop" "$a/metrics" "$a/findings" "$a/run-state.yaml" "$a/run-state-prev.yaml"; do
    [ ! -L "$p" ] || return 1
  done
  for p in "$a/run-state.yaml" "$a/run-state-prev.yaml"; do
    [ ! -e "$p" ] || [ "$(ls -ld -- "$p" 2>/dev/null | awk 'NR == 1 { print $2 }')" = 1 ] || return 1
  done
  for p in "$a/loop" "$a/metrics" "$a/findings"; do
    [ -e "$p" ] || continue
    out="$(find "$p" \( -type l -o \( -type f -links +1 \) \) -print 2>/dev/null)" || return 1
    [ -z "$out" ] || return 1
  done
}

# safe_copy <src> <src-root> <dest> <dest-root>: <src> copied to <dest>, where
# each side may be a clone or view a session has written in. <src> must be a
# plain_file of <src-root>. <dest>'s directory is made only below an existing
# ancestor that lies physically inside <dest-root>, and must itself lie there;
# an existing <dest> must be a writable regular file. The bytes go to a fresh
# file beside <dest> (created exclusively), which is then renamed over it. An
# existing <dest> that is a symlink or one name of several (a hard link) is
# refused; the rename is the second line: it replaces whatever name stands at
# <dest> rather than writing through it. Return 1, writing nothing through a
# link, when any check fails. A process a session left running could still
# move a name between these checks and the rename; the harness does not stop
# such a process.
safe_copy() {
  local s="$1" d="$3" dr dd a t
  plain_file "$s" "$2" || return 1
  dr="$(cd "$4" 2>/dev/null && pwd -P)" && [ -n "$dr" ] || return 1
  dd="$(dirname "$d")"
  a="$dd"
  while [ ! -e "$a" ] && [ ! -L "$a" ]; do a="$(dirname "$a")"; done
  a="$(cd "$a" 2>/dev/null && pwd -P)" || return 1
  case "$a/" in "$dr/"*) ;; *) return 1 ;; esac
  mkdir -p "$dd" 2>/dev/null || return 1
  dd="$(cd "$dd" 2>/dev/null && pwd -P)" || return 1
  case "$dd/" in "$dr/"*) ;; *) return 1 ;; esac
  if [ -L "$d" ]; then return 1; fi
  if [ -e "$d" ]; then
    [ -f "$d" ] && [ -w "$d" ] && [ "$(ls -ld -- "$d" 2>/dev/null | awk 'NR == 1 { print $2 }')" = 1 ] || return 1
  fi
  t="$(mktemp "$dd/.cmp-copy.XXXXXXXX" 2>/dev/null)" || return 1
  if cat -- "$s" > "$t" 2>/dev/null && mv -f -- "$t" "$dd/$(basename "$d")" 2>/dev/null; then return 0; fi
  rm -f -- "$t"
  return 1
}

# opaque_clone <cmd> <src> <start> <dest> <branch> <tmp>: a `git clone --shared
# --no-checkout` of <src> at <dest>, with <start> checked out on the new local
# <branch>, every other local branch and the `origin` remote dropped, so its
# refs are that one branch (and any tags) and nothing it does can reach <src>.
# Dies, naming <cmd>, on any failure; the caller's EXIT trap removes <dest>.
opaque_clone() {
  local cmd="$1" src="$2" start="$3" dest="$4" bname="$5" tmp="$6" ref
  git clone -q --shared --no-checkout "$src" "$dest" >/dev/null 2>"$tmp/git.err" \
    || die "$cmd: git clone --shared failed: $(head -1 "$tmp/git.err")"
  git -C "$dest" -c advice.detachedHead=false checkout -q -b "$bname" "$start" >/dev/null 2>"$tmp/git.err" \
    || die "$cmd: cannot check out $start in the clone: $(head -1 "$tmp/git.err")"
  git -C "$dest" for-each-ref --format='%(refname)' refs/heads/ > "$tmp/heads" 2>/dev/null
  while IFS= read -r ref; do
    [ -n "$ref" ] && [ "$ref" != "refs/heads/$bname" ] || continue
    git -C "$dest" update-ref -d "$ref" >/dev/null 2>&1 || die "$cmd: cannot drop the clone's branch $ref"
  done < "$tmp/heads"
  if git -C "$dest" remote 2>/dev/null | grep -qx origin; then
    git -C "$dest" remote remove origin >/dev/null 2>&1 || die "$cmd: cannot drop the clone's origin remote"
  fi
}

# Globals, not locals: the EXIT trap below runs after cmd_prepare has returned
# or died, when its locals are gone. The half-built clone is removed on every
# exit that does not clear _CMP_CLONE first.
_CMP_TMP=""
_CMP_CLONE=""
_cmp_prepare_cleanup() {
  if [ -n "$_CMP_TMP" ]; then rm -rf "$_CMP_TMP"; fi
  if [ -n "$_CMP_CLONE" ]; then rm -rf "$_CMP_CLONE"; fi
  return 0
}

cmd_prepare() {
  [ $# -eq 3 ] || usage
  local exp="$1" pkt="$2" model="$3"
  case "$exp" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "prepare: not an experiment id (12 hex, as \`settings\` prints it): $exp" ;;
  esac
  case "$pkt" in ''|*[!A-Za-z0-9._-]*) die "prepare: not a packet id: $pkt" ;; esac
  case "$model" in ''|*[!A-Za-z0-9._-]*) die "prepare: not a model token: $model" ;; esac
  [ -x "$ROUTING" ] || die "prepare: routing.sh is missing or not executable: $ROUTING" 2
  [ -x "$BACKLOG" ] || die "prepare: gspec-backlog.sh is missing or not executable: $BACKLOG" 2
  [ -x "$RUNSTATE" ] || die "prepare: runstate.sh is missing or not executable: $RUNSTATE" 2

  local store dir sel
  store="$(store_root)"
  dir="$store/$exp"
  sel="$dir/selection.json"
  [ -f "$sel" ] || die "prepare: no stored selection for experiment $exp (run \`compare.sh select\` first): $sel"

  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "prepare: cannot create a temp root"
  trap _cmp_prepare_cleanup EXIT
  local tmp="$_CMP_TMP"

  # --- the stored selection: settings, and this packet's row -----------------
  json_flat "$sel" > "$tmp/sel" || die "prepare: the stored selection is not readable JSON: $sel"
  local sexp src role rmodel
  sexp="$(awk -F'\t' '$2 == ".experiment" { print $4; exit }' "$tmp/sel")"
  [ "$sexp" = "$exp" ] || die "prepare: the stored selection names experiment [$sexp], not $exp: $sel"
  src="$(awk -F'\t' '$2 == ".settings.source_repo" { print $4; exit }' "$tmp/sel")"
  role="$(awk -F'\t' '$2 == ".settings.role" { print $4; exit }' "$tmp/sel")"
  rmodel="$(awk -F'\t' '$2 == ".settings.reviewer_model" { print $4; exit }' "$tmp/sel")"
  awk -F'\t' '$2 ~ /^\.settings\.models\[[0-9]+\]$/ { print $4 }' "$tmp/sel" > "$tmp/models"
  case "$role" in ''|*[!a-z-]*) die "prepare: the stored selection's role is malformed: [$role]" ;; esac
  case "$rmodel" in ''|*[!A-Za-z0-9._-]*) die "prepare: the stored selection's reviewer model is malformed: [$rmodel]" ;; esac
  if LC_ALL=C grep -q '[^A-Za-z0-9._-]' "$tmp/models" 2>/dev/null || [ ! -s "$tmp/models" ]; then
    die "prepare: the stored selection's models are malformed: $sel"
  fi
  if ! M="$model" awk '$0 == ENVIRON["M"] { f = 1 } END { exit !f }' "$tmp/models"; then
    die "prepare: $model is not one of experiment $exp's models ($(paste -sd, - < "$tmp/models"))"
  fi
  # Every identifier a name must not contain: each model, and the reviewer's.
  { cat "$tmp/models"; printf '%s\n' "$rmodel"; } > "$tmp/ids"

  local idx start kind tier
  idx="$(P="$pkt" awk -F'\t' '$2 ~ /^\.selected\[[0-9]+\]\.packet$/ && $4 == ENVIRON["P"] { i = $2; sub(/^\.selected\[/, "", i); sub(/\].*$/, "", i); print i; exit }' "$tmp/sel")"
  [ -n "$idx" ] || die "prepare: packet $pkt is not in experiment $exp's selection: $sel"
  start="$(I=".selected[$idx].start" awk -F'\t' '$2 == ENVIRON["I"] { print $4; exit }' "$tmp/sel")"
  kind="$(I=".selected[$idx].handoff" awk -F'\t' '$2 == ENVIRON["I"] { print $4; exit }' "$tmp/sel")"
  tier="$(I=".selected[$idx].tier" awk -F'\t' '$2 == ENVIRON["I"] { print $4; exit }' "$tmp/sel")"
  case "$start" in ''|*[!0-9a-f]*) die "prepare: packet $pkt's stored start is not a commit id: [$start]" ;; esac
  case "$kind" in original|rebuilt) ;; *) die "prepare: packet $pkt's stored handoff source is neither original nor rebuilt: [$kind]" ;; esac
  case "$tier" in ''|*[!a-z-]*) die "prepare: packet $pkt's stored tier is not [a-z-]+: [$tier]" ;; esac

  # --- the source and the scratch root -----------------------------------------
  [ -n "$src" ] && git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
    || die "prepare: the source repository is not a git repository: $src"
  git -C "$src" cat-file -e "${start}^{commit}" 2>/dev/null \
    || die "prepare: packet $pkt's start commit is not in the source repository: $start"
  local srctop scratch
  srctop="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  [ -n "$srctop" ] && srctop="$(cd "$srctop" && pwd -P)"
  scratch="${ORCH_COMPARE_SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$scratch" 2>/dev/null || die "prepare: cannot create the scratch root: $scratch"
  scratch="$(cd "$scratch" && pwd -P)" || die "prepare: cannot enter the scratch root: $scratch"
  if [ -n "$srctop" ]; then
    case "$scratch/" in
      "$srctop/"*) die "prepare: the scratch root lies inside the source repository's working tree, which a replay must leave untouched: $scratch" ;;
    esac
  fi

  # --- 1. the clone, on its opaque branch -----------------------------------------
  local dname bname rid clone
  dname="$(opaque_name "" "$tmp/ids")" || die "prepare: no directory name free of every model identifier could be drawn"
  bname="$(opaque_name "replay-" "$tmp/ids")" || die "prepare: no branch name free of every model identifier could be drawn"
  rid="$(opaque_name "" "$tmp/ids" | cut -c1-12)"
  [ "${#rid}" -eq 12 ] || die "prepare: no replay id could be drawn"
  clone="$scratch/$dname"
  [ ! -e "$clone" ] || die "prepare: the drawn clone path already exists: $clone"
  _CMP_CLONE="$clone"
  opaque_clone prepare "$src" "$start" "$clone" "$bname" "$tmp"

  # --- 2. model_routing in the clone's own configuration ---------------------------
  local ov got_role got_rev
  ov="$clone/.agents/project-overrides.yaml"
  mkdir -p "$clone/.agents" || die "prepare: cannot create $clone/.agents"
  set_routing "$ov" "$tmp/overrides" "$role" "$model" "$rmodel" \
    || die "prepare: the clone's model_routing cannot be read, so it cannot be set: $ov"
  cp "$tmp/overrides" "$ov" || die "prepare: cannot write $ov"
  got_role="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$clone" resolve "$role" 2>/dev/null | tr -d '\r')"
  got_rev="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$clone" resolve reviewer 2>/dev/null | tr -d '\r')"
  [ "$got_role" = "$model" ] && [ "$got_rev" = "$rmodel" ] \
    || die "prepare: routing.sh does not resolve the clone's routing as set ($role -> [$got_role], wanted $model; reviewer -> [$got_rev], wanted $rmodel)"

  # --- 3. run-state and begin-run, run in the clone ----------------------------------
  local rs bout run_id
  rs="$clone/.agents/run-state.yaml"
  printf "schema: 3\nstatus: 'running'\nbranch: '%s'\nlast_green_commit: '%s'\n" "$bname" "$start" \
    | (cd "$clone" && CLAUDE_PROJECT_DIR="$clone" "$RUNSTATE" write "$rs") >/dev/null 2>"$tmp/rs.err" \
    || die "prepare: runstate.sh write failed in the clone: $(head -1 "$tmp/rs.err")"
  bout="$(cd "$clone" && CLAUDE_PROJECT_DIR="$clone" "$RUNSTATE" begin-run "$rs" 2>"$tmp/rs.err" | tr -d '\r')" \
    || die "prepare: runstate.sh begin-run failed in the clone: $(head -1 "$tmp/rs.err")"
  run_id="$(printf '%s\n' "$bout" | sed -n 's/^RUN_ID=//p' | head -1)"
  [ -n "$run_id" ] || die "prepare: runstate.sh begin-run printed no RUN_ID"

  # --- 4. the handoff: cached once per packet, installed from the cache ----------------
  local pktdir target cache cached="reused" hout d orig=""
  pktdir="$clone/.agents/loop/$run_id/$pkt"
  target="$pktdir/handoff.md"
  cache="$dir/handoffs/$pkt.md"
  if [ ! -f "$cache" ]; then
    case "$kind" in
      original)
        # The earliest run's handoff (run ids sort by time), the first match,
        # as `candidates` detects it: the one its first dispatch received.
        set +f
        for d in "$src"/.agents/loop/*/; do
          if [ -f "${d}${pkt}/handoff.md" ]; then orig="${d}${pkt}/handoff.md"; break; fi
        done
        set -f
        [ -n "$orig" ] || die "prepare: packet $pkt's original handoff is no longer in the source repository, and none is cached: $cache"
        first_dispatch "$orig" "$tmp/handoff" \
          || die "prepare: the original handoff carries a loop splice block that cannot be removed as either command writes it, so its first-dispatch bytes are unknown: $orig"
        ;;
      rebuilt)
        (cd "$clone" && CLAUDE_PROJECT_DIR="$clone" "$BACKLOG" handoff "$pkt" "$clone" </dev/null) > "$tmp/body" 2>"$tmp/bl.err" \
          || die "prepare: gspec-backlog.sh handoff failed in the clone: $(head -1 "$tmp/bl.err")"
        case "$(head -1 "$tmp/body")" in
          PACKET=*) ;;
          *) die "prepare: gspec-backlog.sh does not resolve $pkt in the clone: $(sed -n 's/^REASON=//p' "$tmp/body" | head -1)" ;;
        esac
        hout="$(cd "$clone" && CLAUDE_PROJECT_DIR="$clone" "$RUNSTATE" handoff "$rs" "$pkt" --tier "$tier" --agent "$role" < "$tmp/body" 2>"$tmp/rs.err" | tr -d '\r')" \
          || die "prepare: runstate.sh handoff failed in the clone: $(head -1 "$tmp/rs.err")"
        case "$hout" in
          HANDOFF=*) ;;
          *) die "prepare: runstate.sh handoff wrote no handoff: $(printf '%s' "$hout" | head -1)" ;;
        esac
        cp "${hout#HANDOFF=}" "$tmp/handoff" || die "prepare: cannot read the rebuilt handoff: ${hout#HANDOFF=}"
        ;;
    esac
    # Written once: `ln` refuses an existing name, so a cache another prepare
    # wrote first is kept and used, never replaced.
    mkdir -p "$dir/handoffs" || die "prepare: cannot create the handoff cache: $dir/handoffs"
    cp "$tmp/handoff" "$dir/handoffs/.$pkt.md.$$" || die "prepare: cannot write the handoff cache: $cache"
    if ln "$dir/handoffs/.$pkt.md.$$" "$cache" 2>/dev/null; then cached="written"; fi
    rm -f "$dir/handoffs/.$pkt.md.$$"
    [ -f "$cache" ] || die "prepare: the handoff cache could not be written: $cache"
  fi
  mkdir -p "$pktdir" || die "prepare: cannot create $pktdir"
  cp "$cache" "$target" || die "prepare: cannot install the handoff: $target"

  # --- the replay's record, then the clone is kept -------------------------------------
  local out
  out="REPLAY=$rid
EXPERIMENT=$exp
PACKET=$pkt
MODEL=$model
ROLE=$role
REVIEWER_MODEL=$rmodel
SOURCE_REPO=$src
START=$start
CLONE=$clone
BRANCH=$bname
RUN_STATE=$rs
RUN_ID=$run_id
HANDOFF=$target
HANDOFF_SOURCE=$kind
HANDOFF_CACHE=$cache
HANDOFF_CACHED=$cached"
  mkdir -p "$dir/replays" || die "prepare: cannot create $dir/replays"
  printf '%s\n' "$out" > "$dir/replays/.$rid.env.$$" && mv "$dir/replays/.$rid.env.$$" "$dir/replays/$rid.env" \
    || die "prepare: cannot write the replay record: $dir/replays/$rid.env"
  _CMP_CLONE=""
  printf '%s\n' "$out"
}

# --- review-view ---------------------------------------------------------------------

# The fixed, neutral identity and text of every commit a review view holds: the
# same for every replay and every model, carrying no trailer of any kind.
_CMP_VIEW_NAME="compare"
_CMP_VIEW_EMAIL="compare@example.invalid"
_CMP_VIEW_DATE="2000-01-01T00:00:00Z"
_CMP_VIEW_BASE_MSG="Review configuration"
_CMP_VIEW_HEAD_MSG="Changes under review"

# The work clone's paths that never reach a view as changed: they stay as the
# start commit holds them. The routing configuration is handled on its own.
_CMP_VIEW_EXCLUDED=".agents/metrics .agents/loop .agents/run-state.yaml .agents/run-state-prev.yaml"

# redact <ids-file> <in> <out>: <in> with every word (a maximal run of
# [A-Za-z0-9_-], dots allowed only inside it, so a sentence's full stop is
# kept) containing any identifier in <ids-file>, compared
# case-insensitively, replaced whole by `[model]`, together with a version
# number that directly follows it after spaces (`Opus 4.5`). A whole word, so
# a resolved id such as `claude-sonnet-5` leaves no version or family behind.
redact() {
  awk '
    NR == FNR { if ($0 != "") ids[++n] = tolower($0); next }
    {
      s = $0; out = ""
      while (match(s, /[A-Za-z0-9_-]+([.][A-Za-z0-9_-]+)*/)) {
        pre = substr(s, 1, RSTART - 1); tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        lt = tolower(tok); hit = 0
        for (i = 1; i <= n; i++) if (index(lt, ids[i])) { hit = 1; break }
        if (hit) {
          tok = "[model]"
          if (match(s, /^[ ]+[0-9]+([.][0-9]+)*/)) s = substr(s, RLENGTH + 1)
        }
        out = out pre tok
      }
      print out s
    }' "$1" "$2" > "$3"
}

# view_header <in> <out> <run-state> <result> <review>: <in> with its header's
# `run-state:`, `result:` and `review:` lines (the first of each, before the
# first `PACKET=` or `<!--` line) pointing into the view, so no header path
# leads a reviewer back to the work clone or the source run.
view_header() {
  RS="$3" RES="$4" REV="$5" awk '
    !body && (/^PACKET=/ || /^<!--/) { body = 1 }
    !body && !rs  && /^run-state: / { print "run-state: " ENVIRON["RS"]; rs = 1; next }
    !body && !res && /^result: /    { print "result: " ENVIRON["RES"]; res = 1; next }
    !body && !rev && /^review: /    { print "review: " ENVIRON["REV"]; rev = 1; next }
    { print }' "$1" > "$2"
}

_CMP_VIEW=""
_cmp_view_cleanup() {
  if [ -n "$_CMP_TMP" ]; then rm -rf "$_CMP_TMP"; fi
  if [ -n "$_CMP_VIEW" ]; then rm -rf "$_CMP_VIEW"; fi
  return 0
}

cmd_review_view() {
  [ $# -eq 1 ] || usage
  local rid="$1"
  case "$rid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "review-view: not a replay id (12 hex, as \`prepare\` prints it): $rid" ;;
  esac
  [ -x "$ROUTING" ] || die "review-view: routing.sh is missing or not executable: $ROUTING" 2
  [ -x "$RUNSTATE" ] || die "review-view: runstate.sh is missing or not executable: $RUNSTATE" 2

  # --- the replay's record, found in whichever experiment holds it --------------
  local store env="" f n=0
  store="$(store_root)"
  set +f
  for f in "$store"/*/replays/"$rid".env; do
    if [ -f "$f" ]; then env="$f"; n=$((n + 1)); fi
  done
  set -f
  [ "$n" -gt 0 ] || die "review-view: no replay record for $rid under $store (run \`compare.sh prepare\` first)"
  [ "$n" -eq 1 ] || die "review-view: replay $rid is recorded in $n experiments under $store; refusing to guess"
  local exp pkt role rmodel src start clone run_id handoff
  exp="$(sed -n 's/^EXPERIMENT=//p' "$env" | head -1)"
  pkt="$(sed -n 's/^PACKET=//p' "$env" | head -1)"
  role="$(sed -n 's/^ROLE=//p' "$env" | head -1)"
  rmodel="$(sed -n 's/^REVIEWER_MODEL=//p' "$env" | head -1)"
  src="$(sed -n 's/^SOURCE_REPO=//p' "$env" | head -1)"
  start="$(sed -n 's/^START=//p' "$env" | head -1)"
  clone="$(sed -n 's/^CLONE=//p' "$env" | head -1)"
  run_id="$(sed -n 's/^RUN_ID=//p' "$env" | head -1)"
  handoff="$(sed -n 's/^HANDOFF=//p' "$env" | head -1)"
  case "$pkt" in ''|*[!A-Za-z0-9._-]*) die "review-view: the replay record's packet is malformed: [$pkt]" ;; esac
  case "$role" in ''|*[!a-z-]*) die "review-view: the replay record's role is malformed: [$role]" ;; esac
  case "$rmodel" in ''|*[!A-Za-z0-9._-]*) die "review-view: the replay record's reviewer model is malformed: [$rmodel]" ;; esac
  case "$start" in ''|*[!0-9a-f]*) die "review-view: the replay record's start is not a commit id: [$start]" ;; esac
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) die "review-view: the replay record's run id is malformed: [$run_id]" ;; esac
  [ -n "$clone" ] && git -C "$clone" rev-parse --git-dir >/dev/null 2>&1 \
    || die "review-view: the replay's work clone is not a git repository: $clone"
  git -C "$clone" cat-file -e "${start}^{commit}" 2>/dev/null \
    || die "review-view: the replay's start commit is not in its work clone: $start"

  local sel="$store/$exp/selection.json"
  [ -f "$sel" ] || die "review-view: no stored selection for the replay's experiment $exp: $sel"

  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "review-view: cannot create a temp root"
  trap _cmp_view_cleanup EXIT
  local tmp="$_CMP_TMP"
  git_neutral "$clone" \
    || die "review-view: the work clone is not a repository of its own (or holds another repository inside it, or names a promisor remote), or its git command hooks cannot be neutralised: $clone"

  # Every identifier of the settings' models: each model as the settings name
  # it (which is also its routing alias) and the reviewer's. A resolved id
  # (`claude-<alias>-...`) contains its alias, so `redact` replaces it whole.
  json_flat "$sel" > "$tmp/sel" || die "review-view: the stored selection is not readable JSON: $sel"
  { awk -F'\t' '$2 ~ /^\.settings\.models\[[0-9]+\]$/ { print $4 }' "$tmp/sel"; printf '%s\n' "$rmodel"; } > "$tmp/ids"
  if LC_ALL=C grep -q '[^A-Za-z0-9._-]' "$tmp/ids" 2>/dev/null || [ "$(grep -c . "$tmp/ids")" -lt 2 ]; then
    die "review-view: the stored selection's models are malformed: $sel"
  fi

  # --- 1. the work clone's current diff, as a tree, built without touching it ----------
  # A temp index and a temp object directory (the clone's own objects as an
  # alternate): the clone's index, object store and refs are only read.
  local cobj
  cobj="$(cd "$clone" && cd "$(git rev-parse --git-path objects 2>/dev/null)" 2>/dev/null && pwd -P)" \
    || die "review-view: cannot find the work clone's object store: $clone"
  mkdir -p "$tmp/objects" || die "review-view: cannot create a temp object store"
  _gw() { GIT_INDEX_FILE="$tmp/$1.idx" GIT_OBJECT_DIRECTORY="$tmp/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$cobj" \
            git -C "$clone" "${@:2}"; }
  local ov=".agents/project-overrides.yaml" p blob tbase thead
  # The routing configuration: the start's file and the work clone's current
  # file, each with `model_routing` reduced to the reviewer's entry alone. So
  # the reviewed change (base -> head) holds the packet's own edits to the file,
  # never the replay's routing, and the view resolves only the reviewer.
  if git -C "$clone" cat-file -e "$start:$ov" 2>/dev/null; then
    git -C "$clone" show "$start:$ov" > "$tmp/ov.start" 2>/dev/null || die "review-view: cannot read the start's $ov"
  fi
  set_routing "$tmp/ov.start" "$tmp/ov.base" "" "" "$rmodel" \
    || die "review-view: the start commit's model_routing cannot be read, so it cannot be reduced: $ov"
  if [ -L "$clone/$ov" ] || { [ -e "$clone/$ov" ] && ! plain_file "$clone/$ov" "$clone"; }; then
    die "review-view: the work clone's $ov is a symlink or has another hard link, so it is not read into the view"
  fi
  set_routing "$clone/$ov" "$tmp/ov.head" "" "" "$rmodel" \
    || die "review-view: the work clone's model_routing cannot be read, so it cannot be reduced: $clone/$ov"
  for p in base head; do
    _gw "$p" read-tree "$start" 2>"$tmp/git.err" || die "review-view: cannot read the start tree: $(head -1 "$tmp/git.err")"
  done
  _gw head add -A -- . 2>"$tmp/git.err" || die "review-view: cannot stage the work clone's changes: $(head -1 "$tmp/git.err")"
  for p in $_CMP_VIEW_EXCLUDED; do
    _gw head rm --cached -r -q --ignore-unmatch -- "$p" >/dev/null 2>"$tmp/git.err" \
      || die "review-view: cannot drop $p from the reviewed change: $(head -1 "$tmp/git.err")"
    git -C "$clone" ls-tree -r "$start" -- "$p" > "$tmp/keep" 2>/dev/null
    _gw head update-index --index-info < "$tmp/keep" 2>"$tmp/git.err" \
      || die "review-view: cannot restore $p as the start holds it: $(head -1 "$tmp/git.err")"
  done
  for p in base head; do
    blob="$(_gw "$p" hash-object -w "$tmp/ov.$p" 2>/dev/null)" || die "review-view: cannot store the reduced $ov"
    _gw "$p" update-index --add --cacheinfo "100644,$blob,$ov" 2>"$tmp/git.err" \
      || die "review-view: cannot stage the reduced $ov: $(head -1 "$tmp/git.err")"
  done
  tbase="$(_gw base write-tree 2>/dev/null)" || die "review-view: cannot write the view's base tree"
  thead="$(_gw head write-tree 2>/dev/null)" || die "review-view: cannot write the view's reviewed tree"
  _gw head diff --binary --no-renames --no-ext-diff --no-textconv "$tbase" "$thead" > "$tmp/change.patch" 2>"$tmp/git.err" \
    || die "review-view: cannot diff the reviewed change: $(head -1 "$tmp/git.err")"

  # --- 2. the view: a second opaque clone of the source at the start ------------------
  local scratch dname bname view
  [ -n "$src" ] && git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
    || die "review-view: the source repository is not a git repository: $src"
  scratch="${ORCH_COMPARE_SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$scratch" 2>/dev/null || die "review-view: cannot create the scratch root: $scratch"
  scratch="$(cd "$scratch" && pwd -P)" || die "review-view: cannot enter the scratch root: $scratch"
  local srctop
  srctop="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  [ -n "$srctop" ] && srctop="$(cd "$srctop" && pwd -P)"
  if [ -n "$srctop" ]; then
    case "$scratch/" in
      "$srctop/"*) die "review-view: the scratch root lies inside the source repository's working tree: $scratch" ;;
    esac
  fi
  # The reviewer works in the view, so its whole path is something it reads.
  if names_model "$scratch" "$tmp/ids"; then
    die "review-view: the scratch root's path names a model, which the reviewer would read: $scratch"
  fi
  dname="$(opaque_name "" "$tmp/ids")" || die "review-view: no directory name free of every model identifier could be drawn"
  bname="$(opaque_name "review-" "$tmp/ids")" || die "review-view: no branch name free of every model identifier could be drawn"
  view="$scratch/$dname"
  [ ! -e "$view" ] || die "review-view: the drawn view path already exists: $view"
  _CMP_VIEW="$view"
  opaque_clone review-view "$src" "$start" "$view" "$bname" "$tmp"

  # --- 3. two commits, fixed and neutral: the reviewer's configuration, then the change -
  _vc() {  # _vc <tree> <parent> <message> -> the new commit's id
    GIT_AUTHOR_NAME="$_CMP_VIEW_NAME" GIT_AUTHOR_EMAIL="$_CMP_VIEW_EMAIL" GIT_AUTHOR_DATE="$_CMP_VIEW_DATE" \
    GIT_COMMITTER_NAME="$_CMP_VIEW_NAME" GIT_COMMITTER_EMAIL="$_CMP_VIEW_EMAIL" GIT_COMMITTER_DATE="$_CMP_VIEW_DATE" \
      git -C "$view" -c commit.gpgsign=false commit-tree "$1" -p "$2" -m "$3" 2>/dev/null
  }
  local base head got
  mkdir -p "$view/.agents" || die "review-view: cannot create $view/.agents"
  cp "$tmp/ov.base" "$view/$ov" || die "review-view: cannot write the view's $ov"
  git -C "$view" add -f -- "$ov" >/dev/null 2>&1 || die "review-view: cannot stage the view's $ov"
  got="$(git -C "$view" write-tree 2>/dev/null)"
  [ "$got" = "$tbase" ] || die "review-view: the view's base tree [$got] is not the one built from the work clone [$tbase]"
  if [ "$tbase" = "$(git -C "$view" rev-parse "$start^{tree}" 2>/dev/null)" ]; then
    base="$start"
  else
    base="$(_vc "$tbase" "$start" "$_CMP_VIEW_BASE_MSG")" && [ -n "$base" ] || die "review-view: cannot commit the view's configuration"
  fi
  if [ -s "$tmp/change.patch" ]; then
    git -C "$view" apply --index --binary "$tmp/change.patch" 2>"$tmp/git.err" \
      || die "review-view: the work clone's change does not apply to the view: $(head -1 "$tmp/git.err")"
  fi
  got="$(git -C "$view" write-tree 2>/dev/null)"
  [ "$got" = "$thead" ] || die "review-view: the view's reviewed tree [$got] is not the work clone's change [$thead]"
  head="$(_vc "$thead" "$base" "$_CMP_VIEW_HEAD_MSG")" && [ -n "$head" ] || die "review-view: cannot commit the change under review"
  git -C "$view" update-ref -m "$_CMP_VIEW_HEAD_MSG" "refs/heads/$bname" "$head" >/dev/null 2>&1 \
    || die "review-view: cannot move the view's branch to the change under review"
  got="$(git -C "$view" status --porcelain=v1 --untracked-files=no 2>/dev/null)"
  [ -z "$got" ] || die "review-view: the view's tree is not clean at the change under review: $(printf '%s' "$got" | head -1)"
  local r_rev
  r_rev="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$view" resolve reviewer 2>/dev/null | tr -d '\r')"
  [ "$r_rev" = "$rmodel" ] \
    || die "review-view: routing.sh does not resolve the view's reviewer as set (reviewer -> [$r_rev], wanted $rmodel)"

  # --- 4. the view's own run-state and run directory ---------------------------------
  local rs bout vrun vdir
  rs="$view/.agents/run-state.yaml"
  printf "schema: 3\nstatus: 'running'\nbranch: '%s'\nlast_green_commit: '%s'\n" "$bname" "$base" \
    | (cd "$view" && CLAUDE_PROJECT_DIR="$view" "$RUNSTATE" write "$rs") >/dev/null 2>"$tmp/rs.err" \
    || die "review-view: runstate.sh write failed in the view: $(head -1 "$tmp/rs.err")"
  bout="$(cd "$view" && CLAUDE_PROJECT_DIR="$view" "$RUNSTATE" begin-run "$rs" 2>"$tmp/rs.err" | tr -d '\r')" \
    || die "review-view: runstate.sh begin-run failed in the view: $(head -1 "$tmp/rs.err")"
  vrun="$(printf '%s\n' "$bout" | sed -n 's/^RUN_ID=//p' | head -1)"
  [ -n "$vrun" ] || die "review-view: runstate.sh begin-run printed no RUN_ID in the view"

  # --- 5. the handoff and result file, redacted --------------------------------------
  local vh vres vrev wres
  vdir="$view/.agents/loop/$vrun/$pkt"
  vh="$vdir/handoff.md"; vres="$vdir/$role.md"; vrev="$vdir/review.md"
  mkdir -p "$vdir" || die "review-view: cannot create $vdir"
  [ -f "$handoff" ] || die "review-view: the replay's handoff is missing from its work clone: $handoff"
  # The handoff and result file are read out of the clone into the view: only
  # as the clone's own files, never through a link a session left.
  plain_file "$handoff" "$clone" \
    || die "review-view: the replay's handoff is a symlink, has another hard link, or lies outside its work clone: $handoff"
  redact "$tmp/ids" "$handoff" "$tmp/handoff.red" || die "review-view: cannot redact the handoff"
  view_header "$tmp/handoff.red" "$vh" "$rs" "$vres" "$vrev" || die "review-view: cannot write the view's handoff: $vh"
  wres="$clone/.agents/loop/$run_id/$pkt/$role.md"
  if [ -f "$wres" ] || [ -L "$wres" ]; then
    plain_file "$wres" "$clone" \
      || die "review-view: the work clone's result file is a symlink or has another hard link: $wres"
    redact "$tmp/ids" "$wres" "$vres" || die "review-view: cannot write the view's result file: $vres"
  else
    vres="none"
  fi

  local out
  out="REPLAY=$rid
VIEW=$view
BRANCH=$bname
START=$start
BASE=$base
HEAD=$head
RUN_STATE=$rs
RUN_ID=$vrun
HANDOFF=$vh
RESULT=$vres
REVIEW=$vrev"
  printf 'VIEW=%s\n' "$view" >> "$store/$exp/replays/$rid.views" \
    || die "review-view: cannot record the view: $store/$exp/replays/$rid.views"
  _CMP_VIEW=""
  printf '%s\n' "$out"
}

# --- replay --------------------------------------------------------------------------

# How long one agent session may run, in seconds, when ORCH_COMPARE_STEP_TIMEOUT
# is unset.
_CMP_STEP_TIMEOUT_DEFAULT=3600

# The verdicts a reviewer returns (templates/status-line.md). Anything else from
# a review ends the replay rather than being routed.
_CMP_REVIEW_TOKENS="pass fix escalate"

# The paths a landed replay commit keeps as the start holds them: the loop's own
# bookkeeping, which the live loop never commits as packet work, and the plan
# and roadmap, which a replay never edits. The routing configuration is handled
# on its own.
_CMP_LAND_EXCLUDED=".agents/metrics .agents/loop .agents/run-state.yaml .agents/run-state-prev.yaml .agents/roadmap.yaml gspec"

# new_session_id: a fresh version-4 UUID (new_token's 32 hex, its version and
# variant nibbles set), the form `claude --session-id` takes.
new_session_id() {
  local h v
  h="$(new_token)"
  v="$(printf '%x' $(( (0x${h:16:1} & 3) | 8 )))"
  printf '%s-%s-4%s-%s%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$v" "${h:17:3}" "${h:20:12}"
}

# sh_quote <s>: <s> as one single-quoted shell word.
sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# confine_settings <dir> <tmp>: the `--settings` JSON every session run_session
# starts is given, <root> being <dir> physical and <tmp> the session's own temp
# directory (session_tmp's, already physical). Three parts:
#   - `sandbox`: Claude Code's OS-level Bash sandbox, on, with filesystem writes
#     allowed in <root> (the session's working directory) and <tmp>, the two
#     paths `allowWrite` names. run_session sets <tmp> as the session's TMPDIR
#     and CLAUDE_CODE_TMPDIR, so the temp directory the sandbox opens for its
#     commands lies inside it. It is what confines a shell write this harness
#     cannot parse (`python3 -c`, a script).
#     `failIfUnavailable` makes a session whose sandbox cannot start exit
#     instead of running unsandboxed; `allowUnsandboxedCommands: false` removes
#     the `dangerouslyDisableSandbox` retry, which the bypass mode would
#     otherwise approve; `filesystem.disabled: false` outranks a user setting
#     that turns the filesystem layer off.
#   - `disableAllHooks: false`, outranking a replayed repo's own settings.
#   - One `PreToolUse` hook on the write tools and Bash,
#       '<harness>/scripts/compare-confine.sh' '<root>' '<tmp>'
#     which refuses a write whose target does not resolve inside <root> or
#     <tmp>, the same two strings `allowWrite` holds, so the hook and the
#     sandbox allow one boundary (the harness's own hook: never hooks/guard.sh
#     or hooks/hooks.json, which the live loop runs). The sandbox covers Bash
#     only; the file tools are this hook's alone.
# Return 1, printing nothing, when <dir> cannot be entered or <tmp> is not an
# absolute directory.
confine_settings() {
  local root tmp="$2"
  root="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  [ -n "$root" ] || return 1
  case "$tmp" in /?*) [ -d "$tmp" ] || return 1 ;; *) return 1 ;; esac
  printf '{"disableAllHooks":false,"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false,"filesystem":{"disabled":false,"allowWrite":[%s,%s]}},"hooks":{"PreToolUse":[{"matcher":"Edit|MultiEdit|Write|NotebookEdit|Bash","hooks":[{"type":"command","command":%s}]}]}}' \
    "$(rd_json_str "$root")" "$(rd_json_str "$tmp")" \
    "$(rd_json_str "$(sh_quote "$_CMP_HARNESS/scripts/compare-confine.sh") $(sh_quote "$root") $(sh_quote "$tmp")")"
}

# session_tmp <dir>: a fresh, empty temp directory for one session in <dir>,
# printed physical: `mktemp -d` directly under /tmp (mode 0700). /tmp, not
# $TMPDIR: Claude Code 2.1.281 (read from its binary, then observed by ADR
# 0030 §2's live probe) places the temp directory its sandboxed commands get at
# ${CLAUDE_CODE_TMPDIR:-/tmp}/claude-<uid>, and falls back to the shared
# /tmp/claude-<uid> when that path is longer than 44 bytes; a macOS $TMPDIR
# already is. Refused (return 1, nothing printed, nothing left behind) when it
# lies inside <dir>, the harness's main checkout or the source checkout
# (_CMP_SRC, when the caller set it), or one of those lies inside it.
session_tmp() {
  local d p top
  d="$(mktemp -d /tmp/cmp.XXXXXXXX 2>/dev/null)" || return 1
  p="$(cd "$d" 2>/dev/null && pwd -P)" || { rm -rf "$d"; return 1; }
  for top in "$(cd "$1" 2>/dev/null && pwd -P)" "$(main_checkout)" \
             "$( [ -n "${_CMP_SRC:-}" ] && cd "$_CMP_SRC" 2>/dev/null && pwd -P)"; do
    [ -n "$top" ] || continue
    case "$p/" in "$top/"*) rm -rf "$d"; return 1 ;; esac
    case "$top/" in "$p/"*) rm -rf "$d"; return 1 ;; esac
  done
  printf '%s' "$p"
}

# run_session <dir> <prompt-file> <out> <err>: one non-interactive session in
# <dir>, at the experiment's effort, killed at the time limit. Sets STEP_EXIT to
# its exit code, or `timeout`, and STEP_SESSION to the session id it was started
# on, so `record` can find its transcript. Polled rather than watched by a second
# process, so no watchdog outlives the step. CLAUDE_CODE_EFFORT_LEVEL outranks
# `--effort`, so it is removed from the session's environment. The session runs
# in the bypass permission mode: nobody can answer a prompt in it (one refuses
# the call or stalls the step), and `--plugin-dir` still loads the harness's
# hooks/guard.sh, whose hard-deny tier is meant to keep applying. A working
# directory confines nothing, so `--settings` adds confine_settings' Bash
# sandbox and hook, which keep writes inside <dir> and the session's own temp
# directory STEP_TMP (session_tmp's, set as its TMPDIR and CLAUDE_CODE_TMPDIR,
# known before launch and removed once the session has ended); a session whose
# temp directory or settings cannot be built is not started (its exit reads as
# a crash). git_session_env takes git_neutral's overrides off in the session's
# own shell: they are the harness's, not the replayed loop's.
run_session() {
  local dir="$1" pf="$2" out="$3" err="$4" pid t0 rc
  STEP_SESSION="$(new_session_id)"
  STEP_TMP="$(session_tmp "$dir")" || STEP_TMP=""
  ( [ -n "$STEP_TMP" ] && cd "$dir" && unset CLAUDE_CODE_EFFORT_LEVEL && git_session_env \
      && cset="$(confine_settings "$dir" "$STEP_TMP")" \
      && TMPDIR="$STEP_TMP" && CLAUDE_CODE_TMPDIR="$STEP_TMP" && export TMPDIR CLAUDE_CODE_TMPDIR \
      && exec "$_CMP_CLAUDE" --plugin-dir "$_CMP_HARNESS" --effort "$_CMP_EFFORT" \
           --permission-mode bypassPermissions --settings "$cset" \
           --session-id "$STEP_SESSION" -p "$(cat "$pf")" ) </dev/null >"$out" 2>"$err" &
  pid=$!
  t0=$SECONDS
  STEP_EXIT=""
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - t0)) -ge "$_CMP_TIMEOUT" ]; then
      kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL "$pid" 2>/dev/null
      STEP_EXIT="timeout"
      break
    fi
    sleep 0.2
  done
  wait "$pid" 2>/dev/null; rc=$?
  [ -n "$STEP_EXIT" ] || STEP_EXIT="$rc"
  if [ -n "$STEP_TMP" ]; then rm -rf "$STEP_TMP"; fi
}

# step_prompt <agent> <dir> <brief-file> <refusal-or-empty>: the session's prompt.
# It names no model: the model is whatever routing.sh resolves in <dir>.
step_prompt() {
  printf 'You are running one step of a packet replay. The harness that launched you is the loop driver; you do this one step and nothing else.\n\n'
  printf 'Dispatch the `%s` agent (the gaffer plugin'"'"'s agent of that name) exactly once. Set the dispatch'"'"'s model to what this command prints, and omit the model when it prints nothing; never choose a model yourself:\n\n' "$1"
  printf '    %s/scripts/routing.sh --root %s resolve %s\n\n' "$_CMP_HARNESS" "$2" "$1"
  printf 'Give the agent exactly this brief:\n\n'
  cat "$3"
  if [ -n "$4" ]; then
    printf '\nThe previous dispatch of this step returned a status line that `runstate.sh check-status` refused, with this reason:\n    %s\nAdd that reason to the brief so the agent returns a line that passes.\n' "$4"
  fi
  printf '\nDo not edit, commit or run anything else yourself. When the agent returns, print its one status line exactly as it returned it, as the last line of your output, with nothing after it.\n'
}

# dispatch_step <agent> <dir> <brief-file>: the step, with check-status's one
# re-dispatch. Sets D_LINE and D_TOKEN on success (return 0); D_EXIT on a
# crashed or timed-out session (return 1); D_REASON on a second refusal
# (return 2).
dispatch_step() {
  local agent="$1" dir="$2" brief="$3" try refusal="" chk rc
  D_LINE=""; D_TOKEN=""; D_EXIT=""; D_REASON=""
  for try in 1 2; do
    STEPN=$((STEPN + 1))
    step_prompt "$agent" "$dir" "$brief" "$refusal" > "$_CMP_TMP/prompt"
    run_session "$dir" "$_CMP_TMP/prompt" "$_CMP_TMP/out" "$_CMP_TMP/err"
    if [ "$STEP_EXIT" != 0 ]; then
      emit "STEP n=$STEPN agent=$agent try=$try exit=$STEP_EXIT status=none session=$STEP_SESSION"
      D_EXIT="$STEP_EXIT"
      return 1
    fi
    D_LINE="$(tr -d '\r' < "$_CMP_TMP/out" | awk 'NF { l = $0 } END { print l }')"
    if [ -z "$D_LINE" ]; then
      chk="the session returned no status line"; rc=1
    else
      chk="$(cd "$dir" && "$RUNSTATE" check-status --status "$D_LINE" 2>&1)"; rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      D_TOKEN="${D_LINE%% · *}"
      emit "STEP n=$STEPN agent=$agent try=$try exit=0 status=ok token=$D_TOKEN session=$STEP_SESSION"
      return 0
    fi
    refusal="$(printf '%s\n' "$chk" | head -1)"
    emit "STEP n=$STEPN agent=$agent try=$try exit=0 status=refused session=$STEP_SESSION"
  done
  D_REASON="$refusal"
  return 2
}

# route_in_clone <agent> <token> <line>: `runstate.sh route` in the work clone.
# Sets R_ACTION; emits the ROUTE line. Returns 1 when route fails.
route_in_clone() {
  local out a n l
  out="$(cd "$_RP_CLONE" && CLAUDE_PROJECT_DIR="$_RP_CLONE" "$RUNSTATE" route "$_RP_RS" "$_RP_PKT" "$2" --status "$3" 2>"$_CMP_TMP/rs.err" | tr -d '\r')" \
    || { R_ACTION=""; return 1; }
  R_ACTION="$(printf '%s\n' "$out" | sed -n 's/^ACTION=//p' | head -1)"
  a="$(printf '%s\n' "$out" | sed -n 's/^ATTEMPTS=//p' | head -1)"
  n="$(printf '%s\n' "$out" | sed -n 's/^LIMIT=//p' | head -1)"
  emit "ROUTE agent=$1 token=$2 action=$R_ACTION attempts=$a limit=$n"
  [ -n "$R_ACTION" ]
}

# refresh_in_clone: `runstate.sh refresh-handoff` in the work clone, before a
# continuation and before every fix/retry re-dispatch.
refresh_in_clone() {
  local out
  out="$(cd "$_RP_CLONE" && CLAUDE_PROJECT_DIR="$_RP_CLONE" "$RUNSTATE" refresh-handoff "$_RP_RS" "$_RP_PKT" 2>"$_CMP_TMP/rs.err" | tr -d '\r')" \
    || return 1
  emit "REFRESH partial_work=$(printf '%s\n' "$out" | sed -n 's/^PARTIAL_WORK=//p' | head -1) paths=$(printf '%s\n' "$out" | sed -n 's/^PATHS=//p' | head -1)"
}

# unset_routing <current> <start> <out>: <current> with its top-level
# `model_routing` block (the key line and the indented, non-blank lines
# directly under it) replaced by <start>'s block, or removed when <start> has
# none. Every other line of <current> is kept, so a packet's own edits to the
# file survive while the replay's routing does not; a packet's own edit inside
# the block is not kept (the review view reduces the block the same way).
# Exit 3 when <current> holds a second `model_routing:` key.
unset_routing() {
  S="$2" awk '
    BEGIN {
      while ((getline l < ENVIRON["S"]) > 0) {
        sub(/\r$/, "", l)
        if (sdone) continue
        if (sopen) { if (l ~ /^[[:space:]]+[^[:space:]]/) { sb[++ns] = l; continue } sdone = 1; continue }
        if (l ~ /^model_routing:/) { sb[++ns] = l; sopen = 1 }
      }
    }
    { sub(/\r$/, "") }
    cin { if ($0 ~ /^[[:space:]]+[^[:space:]]/) next; cin = 0 }
    /^model_routing:/ {
      if (cdone) { bad = 1; next }
      cin = 1; cdone = 1
      for (i = 1; i <= ns; i++) print sb[i]
      next
    }
    { print }
    END { if (bad) exit 3 }' "$1" > "$3"
}

# land_tree: the packet's diff, and only it, as a tree on the start: the work
# clone's tree as it stands (committed, staged, unstaged and untracked-but-not-
# ignored alike) with _CMP_LAND_EXCLUDED as the start holds it and the replay's
# routing change taken back out. Built through a temp index; the objects it
# needs are written wherever git's object environment points (the clone's own
# store for `land_commit`, a temp store for `sweeps`). Sets LAND_TREE. Returns 1
# on a git failure, 3 when the packet's own edit to the routing configuration
# cannot be separated from the replay's, 4 when that file is a symlink or has
# another hard link (plain_file). Its git runs under the caller's git_neutral.
land_tree() {
  local c="$_RP_CLONE" s="$_RP_START" idx="$_CMP_TMP/land.idx" ov=".agents/project-overrides.yaml" p blob
  _gl() { GIT_INDEX_FILE="$idx" git -C "$c" "$@"; }
  _gl read-tree "$s" 2>/dev/null || return 1
  _gl add -A -- . 2>/dev/null || return 1
  _restore() {  # _restore <path>: <path> as the start holds it (absent included)
    _gl rm --cached -r -q --ignore-unmatch -- "$1" >/dev/null 2>&1 || return 1
    git -C "$c" ls-tree -r "$s" -- "$1" > "$_CMP_TMP/keep" 2>/dev/null || return 1
    _gl update-index --index-info < "$_CMP_TMP/keep" 2>/dev/null
  }
  for p in $_CMP_LAND_EXCLUDED; do _restore "$p" || return 1; done
  # The routing configuration: what prepare wrote is the start's file with the
  # replay's routing set, so an unchanged file is the start's; a file the packet
  # also edited keeps those edits, with the start's model_routing block put back.
  : > "$_CMP_TMP/ov.start"
  if git -C "$c" cat-file -e "$s:$ov" 2>/dev/null; then
    git -C "$c" show "$s:$ov" > "$_CMP_TMP/ov.start" 2>/dev/null || return 1
    set_routing "$_CMP_TMP/ov.start" "$_CMP_TMP/ov.prepared" "$_RP_ROLE" "$_RP_MODEL" "$_RP_RMODEL" || return 3
  else
    set_routing /dev/null "$_CMP_TMP/ov.prepared" "$_RP_ROLE" "$_RP_MODEL" "$_RP_RMODEL" || return 3
  fi
  # Read only as the clone's own file: a symlink or hard link a session left
  # there would carry another file's bytes into the landed tree.
  if [ -L "$c/$ov" ] || { [ -e "$c/$ov" ] && ! plain_file "$c/$ov" "$c"; }; then return 4; fi
  if [ ! -f "$c/$ov" ]; then
    _gl rm --cached -q --ignore-unmatch -- "$ov" >/dev/null 2>&1 || return 1
  elif cmp -s "$c/$ov" "$_CMP_TMP/ov.prepared"; then
    _restore "$ov" || return 1
  else
    unset_routing "$c/$ov" "$_CMP_TMP/ov.start" "$_CMP_TMP/ov.land" || return 3
    blob="$(git -C "$c" hash-object -w "$_CMP_TMP/ov.land" 2>/dev/null)" || return 1
    _gl update-index --add --cacheinfo "100644,$blob,$ov" 2>/dev/null || return 1
  fi
  LAND_TREE="$(_gl write-tree 2>/dev/null)" && [ -n "$LAND_TREE" ] || return 1
}

# land_commit: land_tree's tree as one commit on the start; the replay's branch
# moved to it. Sets LAND_COMMIT (a sha, or `none` for an empty change). Returns
# land_tree's 1, 3 or 4, or 1 on a failed commit.
land_commit() {
  local c="$_RP_CLONE" s="$_RP_START" tree commit rc
  land_tree; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  tree="$LAND_TREE"
  if [ "$tree" = "$(git -C "$c" rev-parse "$s^{tree}" 2>/dev/null)" ]; then
    LAND_COMMIT="none"
    return 0
  fi
  commit="$(GIT_AUTHOR_NAME="$_CMP_VIEW_NAME" GIT_AUTHOR_EMAIL="$_CMP_VIEW_EMAIL" \
            GIT_COMMITTER_NAME="$_CMP_VIEW_NAME" GIT_COMMITTER_EMAIL="$_CMP_VIEW_EMAIL" \
            git -C "$c" -c commit.gpgsign=false commit-tree "$tree" -p "$s" \
              -m "$(printf 'Replay of packet %s\n\n[orch packet:%s]' "$_RP_PKT" "$_RP_PKT")" 2>/dev/null)" \
    && [ -n "$commit" ] || return 1
  git -C "$c" update-ref "refs/heads/$_RP_BRANCH" "$commit" >/dev/null 2>&1 || return 1
  # The clone's own index follows its branch; its work tree is left as it is.
  git -C "$c" reset -q >/dev/null 2>&1 || return 1
  LAND_COMMIT="$commit"
}

_RP_STEPS=""
emit() {
  printf '%s\n' "$1"
  printf '%s\n' "$1" >> "$_RP_STEPS"
}

cmd_replay() {
  [ $# -eq 1 ] || usage
  local rid="$1"
  case "$rid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "replay: not a replay id (12 hex, as \`prepare\` prints it): $rid" ;;
  esac
  [ -x "$ROUTING" ] || die "replay: routing.sh is missing or not executable: $ROUTING" 2
  [ -x "$RUNSTATE" ] || die "replay: runstate.sh is missing or not executable: $RUNSTATE" 2
  _CMP_CLAUDE="${ORCH_COMPARE_CLAUDE:-claude}"
  command -v "$_CMP_CLAUDE" >/dev/null 2>&1 || die "replay: no session command: $_CMP_CLAUDE (set ORCH_COMPARE_CLAUDE)" 2
  _CMP_TIMEOUT="${ORCH_COMPARE_STEP_TIMEOUT:-$_CMP_STEP_TIMEOUT_DEFAULT}"
  case "$_CMP_TIMEOUT" in ''|0|*[!0-9]*) die "replay: ORCH_COMPARE_STEP_TIMEOUT is not a positive number of seconds: $_CMP_TIMEOUT" 2 ;; esac
  _CMP_HARNESS="$(cd "$HERE/.." && pwd -P)"
  [ -x "$_CMP_HARNESS/scripts/compare-confine.sh" ] \
    || die "replay: compare-confine.sh is missing or not executable: $_CMP_HARNESS/scripts/compare-confine.sh" 2

  # --- the replay's record, found in whichever experiment holds it --------------
  local store env="" f n=0
  store="$(store_root)"
  set +f
  for f in "$store"/*/replays/"$rid".env; do
    if [ -f "$f" ]; then env="$f"; n=$((n + 1)); fi
  done
  set -f
  [ "$n" -gt 0 ] || die "replay: no replay record for $rid under $store (run \`compare.sh prepare\` first)"
  [ "$n" -eq 1 ] || die "replay: replay $rid is recorded in $n experiments under $store; refusing to guess"
  local exp run_id handoff
  exp="$(sed -n 's/^EXPERIMENT=//p' "$env" | head -1)"
  _RP_PKT="$(sed -n 's/^PACKET=//p' "$env" | head -1)"
  _RP_ROLE="$(sed -n 's/^ROLE=//p' "$env" | head -1)"
  _RP_MODEL="$(sed -n 's/^MODEL=//p' "$env" | head -1)"
  _RP_RMODEL="$(sed -n 's/^REVIEWER_MODEL=//p' "$env" | head -1)"
  _RP_START="$(sed -n 's/^START=//p' "$env" | head -1)"
  _RP_CLONE="$(sed -n 's/^CLONE=//p' "$env" | head -1)"
  _RP_BRANCH="$(sed -n 's/^BRANCH=//p' "$env" | head -1)"
  _RP_RS="$(sed -n 's/^RUN_STATE=//p' "$env" | head -1)"
  run_id="$(sed -n 's/^RUN_ID=//p' "$env" | head -1)"
  handoff="$(sed -n 's/^HANDOFF=//p' "$env" | head -1)"
  # The source checkout, which no session's temp directory may lie in (session_tmp).
  _CMP_SRC="$(sed -n 's/^SOURCE_REPO=//p' "$env" | head -1)"
  case "$_RP_PKT" in ''|*[!A-Za-z0-9._-]*) die "replay: the replay record's packet is malformed: [$_RP_PKT]" ;; esac
  case "$_RP_ROLE" in ''|*[!a-z-]*) die "replay: the replay record's role is malformed: [$_RP_ROLE]" ;; esac
  case "$_RP_MODEL" in ''|*[!A-Za-z0-9._-]*) die "replay: the replay record's model is malformed: [$_RP_MODEL]" ;; esac
  case "$_RP_RMODEL" in ''|*[!A-Za-z0-9._-]*) die "replay: the replay record's reviewer model is malformed: [$_RP_RMODEL]" ;; esac
  case "$_RP_START" in ''|*[!0-9a-f]*) die "replay: the replay record's start is not a commit id: [$_RP_START]" ;; esac
  case "$_RP_BRANCH" in ''|*[!A-Za-z0-9._-]*) die "replay: the replay record's branch is malformed: [$_RP_BRANCH]" ;; esac
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) die "replay: the replay record's run id is malformed: [$run_id]" ;; esac
  [ -n "$_RP_CLONE" ] && git -C "$_RP_CLONE" rev-parse --git-dir >/dev/null 2>&1 \
    || die "replay: the replay's work clone is not a git repository: $_RP_CLONE"
  [ -f "$_RP_RS" ] || die "replay: the replay's run-state is missing from its work clone: $_RP_RS"
  [ -f "$handoff" ] || die "replay: the replay's handoff is missing from its work clone: $handoff"

  # The one reasoning effort every session of the replay runs at: the stored
  # selection's `effort` setting, read before anything is started.
  local sel="$store/$exp/selection.json"
  case "$exp" in ''|*[!0-9a-f]*) die "replay: the replay record's experiment is malformed: [$exp]" ;; esac
  [ -f "$sel" ] || die "replay: no stored selection for the replay's experiment $exp: $sel"
  _CMP_EFFORT="$(json_flat "$sel" 2>/dev/null | sel_effort)" \
    || die "replay: the stored selection is not readable JSON: $sel"
  effort_is_level "$_CMP_EFFORT" \
    || die "replay: experiment $exp's stored settings name no effort in: ${EFFORT_LEVELS[*]} (got [$_CMP_EFFORT]): $sel"

  # Once per replay: the clone has moved on from its prepared state after one.
  _RP_STEPS="$(dirname "$env")/$rid.steps"
  ( set -C; : > "$_RP_STEPS" ) 2>/dev/null \
    || die "replay: replay $rid has already been run (or its step log cannot be created): $_RP_STEPS"

  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "replay: cannot create a temp root"
  trap '[ -n "$_CMP_TMP" ] && rm -rf "$_CMP_TMP"; :' EXIT
  local tmp="$_CMP_TMP"

  local pktdir result review="" vout view vh vrev t ok
  pktdir="$_RP_CLONE/.agents/loop/$run_id/$_RP_PKT"
  result="$pktdir/$_RP_ROLE.md"
  STEPN=0
  LAND_COMMIT="none"

  _end() {  # _end <end> [reason]: the replay's last two lines
    emit "END=$1"
    emit "COMMIT=$LAND_COMMIT"
    if [ -n "${2:-}" ]; then printf 'compare.sh: replay: %s\n' "$2" >&2; fi
  }
  _fail() { _end error "$1"; exit 1; }
  # Every git command the harness runs on the clone (its own, and runstate.sh's
  # and routing.sh's) runs with the clone's command hooks off, recomputed after
  # each session, which may have added one; and runstate.sh writes in the clone
  # only where no session has left a link.
  _neutral() {
    git_neutral "$_RP_CLONE" \
      || _fail "the work clone is not a repository of its own (or holds another repository inside it, or names a promisor remote), or its git command hooks cannot be neutralised: $_RP_CLONE"
    runtime_links "$_RP_CLONE" \
      || _fail "the work clone's .agents runtime paths hold a symlink or a hard link, where runstate.sh would write through it: $_RP_CLONE"
  }
  _neutral

  (cd "$_RP_CLONE" && CLAUDE_PROJECT_DIR="$_RP_CLONE" "$RUNSTATE" record-start "$_RP_PKT" "$rid") >/dev/null 2>"$tmp/rs.err" \
    || _fail "runstate.sh record-start failed in the work clone: $(head -1 "$tmp/rs.err")"

  while :; do
    # --- the varied role's step, in the work clone ---------------------------
    {
      printf 'Handoff: %s\n' "$handoff"
      printf 'run-state: %s\n' "$_RP_RS"
      printf 'result: %s\n' "$result"
      if [ -n "$review" ]; then printf 'review: %s\n' "$review"; fi
      printf "The handoff's own run-state:, result: and review: header lines may name another checkout; use the paths above.\n"
    } > "$tmp/brief"
    dispatch_step "$_RP_ROLE" "$_RP_CLONE" "$tmp/brief"
    case $? in
      1) if [ "$D_EXIT" = timeout ]; then _end timed-out; else _end crashed; fi; return 0 ;;
      2) _end refused "$_RP_ROLE's status line was refused twice: $D_REASON"; return 0 ;;
    esac
    _neutral
    if [ "$D_TOKEN" = continue ]; then
      route_in_clone "$_RP_ROLE" continue "$D_LINE" \
        || _fail "runstate.sh route failed in the work clone: $(head -1 "$tmp/rs.err")"
      case "$R_ACTION" in
        continue)
          (cd "$_RP_CLONE" && CLAUDE_PROJECT_DIR="$_RP_CLONE" "$RUNSTATE" record-start "$_RP_PKT" --continue "$rid") >/dev/null 2>"$tmp/rs.err" \
            || _fail "runstate.sh record-start --continue failed in the work clone: $(head -1 "$tmp/rs.err")"
          refresh_in_clone || _fail "runstate.sh refresh-handoff failed in the work clone: $(head -1 "$tmp/rs.err")"
          continue ;;
        stop) _end stop; return 0 ;;
        *) _fail "runstate.sh route mapped continue to an unexpected action: [$R_ACTION]" ;;
      esac
    fi

    # --- the review, in a fresh blinded view ---------------------------------------
    vout="$("$HERE/compare.sh" review-view "$rid" 2>"$tmp/view.err")" \
      || _fail "review-view failed: $(head -1 "$tmp/view.err")"
    view="$(printf '%s\n' "$vout" | sed -n 's/^VIEW=//p' | head -1)"
    vh="$(printf '%s\n' "$vout" | sed -n 's/^HANDOFF=//p' | head -1)"
    vrev="$(printf '%s\n' "$vout" | sed -n 's/^REVIEW=//p' | head -1)"
    [ -d "$view" ] && [ -f "$vh" ] || _fail "review-view printed no usable view: $view"
    emit "VIEW=$view"
    # On a re-attempt the reviewer is given the review path as well (run-loop
    # §3.4), holding the previous round's review: the blinded reviewer's own
    # earlier output, so it names nothing the reviewed diff does not.
    printf 'Handoff: %s\n' "$vh" > "$tmp/brief"
    rm -f "$tmp/review.seed"
    if [ -n "$review" ]; then
      # Out of the clone, where the last session could have left a link in its
      # place, into the view: safe_copy follows no symlink and writes through no
      # hard link on either side.
      [ -n "$vrev" ] && safe_copy "$review" "$_RP_CLONE" "$vrev" "$view" && cp "$vrev" "$tmp/review.seed" \
        || _fail "cannot copy the previous review into the review view: $vrev"
      printf 'review: %s\n' "$vrev" >> "$tmp/brief"
    fi
    dispatch_step reviewer "$view" "$tmp/brief"
    case $? in
      1) if [ "$D_EXIT" = timeout ]; then _end timed-out; else _end crashed; fi; return 0 ;;
      2) _end refused "the reviewer's status line was refused twice: $D_REASON"; return 0 ;;
    esac
    ok=0
    for t in $_CMP_REVIEW_TOKENS; do [ "$t" = "$D_TOKEN" ] && ok=1; done
    [ "$ok" -eq 1 ] || { _end refused "the reviewer returned [$D_TOKEN], not one of: $_CMP_REVIEW_TOKENS"; return 0; }
    # The review, for the next attempt's brief: the view is the reviewer's
    # checkout, so its review file is copied into the work clone's run directory.
    # A review file this session left as it was seeded is the previous round's,
    # not this one's, so the next attempt is briefed with no review then.
    review=""
    # A symlink at either end (the reviewer's in the view, the implementer's in
    # the clone) or a hard link is refused by safe_copy, never followed.
    if { [ -f "$vrev" ] || [ -L "$vrev" ]; } && ! { [ -f "$tmp/review.seed" ] && cmp -s "$vrev" "$tmp/review.seed"; }; then
      safe_copy "$vrev" "$view" "$pktdir/review.md" "$_RP_CLONE" \
        || _fail "cannot copy the review into the work clone: $pktdir/review.md"
      review="$pktdir/review.md"
    fi
    route_in_clone reviewer "$D_TOKEN" "$D_LINE" \
      || _fail "runstate.sh route failed in the work clone: $(head -1 "$tmp/rs.err")"
    case "$R_ACTION" in
      land)
        land_commit
        case $? in
          0) _end land; return 0 ;;
          3) _fail "the work clone's .agents/project-overrides.yaml cannot be read (a second model_routing key), so the replay's routing cannot be taken out of the commit" ;;
          4) _fail "the work clone's .agents/project-overrides.yaml is a symlink or has another hard link, so it is not read into the commit" ;;
          *) _fail "the land commit could not be made in the work clone" ;;
        esac ;;
      attempt)
        refresh_in_clone || _fail "runstate.sh refresh-handoff failed in the work clone: $(head -1 "$tmp/rs.err")"
        continue ;;
      decider|stop) _end "$R_ACTION"; return 0 ;;
      *) _fail "runstate.sh route mapped $D_TOKEN to an unexpected action: [$R_ACTION]" ;;
    esac
  done
}

# --- routing-check -------------------------------------------------------------------

# rc_flat_override <flat-packet>: the packet's audit.dispatches_with_model_override
# as it stands: a number, `null`, or `absent` when the packet has no such field.
rc_flat_override() {
  awk -F'\t' '
    $2 == ".audit.dispatches_with_model_override" { v = ($3 == "n") ? $4 : "?" $4; f = 1; exit }
    END { if (!f) v = "absent"; print v }' "$1"
}

# rc_flat_models <flat-packet> <role>: the model keys of by_agent_role.<role>.models,
# sorted and comma-joined (empty when there are none). An agent dispatched as the
# plugin's `gaffer:<role>` is keyed so in the packet; routing.sh strips that one
# prefix, so both keys are the role's.
rc_flat_models() {
  R="$2" awk -F'\t' '
    BEGIN { p1 = ".by_agent_role." ENVIRON["R"] ".models."; p2 = ".by_agent_role.gaffer:" ENVIRON["R"] ".models." }
    {
      m = ""
      if (index($2, p1) == 1) m = substr($2, length(p1) + 1)
      else if (index($2, p2) == 1) m = substr($2, length(p2) + 1)
      else next
      sub(/\.[^.]*$/, "", m)
      if (m != "" && !(m in s)) { s[m] = 1; print m }
    }' "$1" | LC_ALL=C sort | paste -sd, -
}

# rc_stamps <events-dir> <role> <out>: one line per `Agent` dispatch of <role> (or
# `gaffer:<role>`) in the directory's event logs, `stamped<TAB><routing_resolved>`
# or `unstamped`. Returns 1 when a log cannot be read as JSON lines.
rc_stamps() {
  local f
  : > "$3"
  set +f
  for f in "$1"/*.jsonl; do
    [ -f "$f" ] || continue
    json_flat "$f" > "$_CMP_TMP/ev.flat" 2>/dev/null || { set -f; return 1; }
    R="$2" awk -F'\t' '
      function flush() {
        if (d != "" && tool == "Agent" && (st == ENVIRON["R"] || st == "gaffer:" ENVIRON["R"]))
          print (hr ? "stamped\t" rr : "unstamped")
      }
      $1 != d { flush(); d = $1; tool = ""; st = ""; hr = 0; rr = "" }
      $2 == ".tool" { tool = $4 }
      $2 == ".subagent_type" { st = $4 }
      $2 == ".routing_resolved" { hr = 1; rr = $4 }
      END { flush() }' "$_CMP_TMP/ev.flat" >> "$3"
  done
  set -f
}

# rc_flat_efforts <flat-packet>: the levels totals.by_effort names, sorted and
# comma-joined (empty when it names none).
rc_flat_efforts() {
  awk -F'\t' '
    BEGIN { p = ".totals.by_effort." }
    index($2, p) == 1 {
      l = substr($2, length(p) + 1); sub(/\..*$/, "", l)
      if (l != "" && !(l in s)) { s[l] = 1; print l }
    }' "$1" | LC_ALL=C sort | paste -sd, -
}

# rc_effort <scope> <flat-packet>: the `effort` check. Every level the packet's
# totals.by_effort names must be the experiment's setting (_RC_EFFORT); a packet
# naming none passes, since a model that takes no effort carries none.
rc_effort() {
  local levels l bad=""
  levels="$(rc_flat_efforts "$2")"
  if [ -z "$levels" ]; then
    rc_emit "CHECK scope=$1 check=effort result=pass value=none reason=totals.by_effort names no level (a model that takes no effort carries none, and so does a transcript from before the per-turn effort field, so none is not proof that no effort was taken)"
    return 0
  fi
  for l in $(printf '%s' "$levels" | tr ',' ' '); do [ "$l" = "$_RC_EFFORT" ] || bad="$bad${bad:+,}$l"; done
  if [ -n "$bad" ]; then
    rc_emit "CHECK scope=$1 check=effort result=fail value=$levels reason=totals.by_effort names $bad, not only $_RC_EFFORT, the experiment's effort"
  else
    rc_emit "CHECK scope=$1 check=effort result=pass value=$levels"
  fi
}

_RC_OUT=""
_RC_PINS=""
_RC_EFFORT=""
rc_emit() {
  printf '%s\n' "$1"
  printf '%s\n' "$1" >> "$_RC_OUT"
  case "$1" in
    *" result=fail"*) _RC_FAIL=1 ;;
    *" result=not-run"*) _RC_NOTRUN=1 ;;
  esac
}

# rc_scope <scope> <dir> <packet-out> <role> <configured-model> <with-override-check 0|1>:
# collect the directory's metrics into <packet-out> and emit its CHECK lines.
# Check names, as a failing line gives them: `override-count` (the work clone
# only), `<role>-resolved-id`, `<role>-models`.
rc_scope() {
  local scope="$1" dir="$2" pout="$3" role="$4" want="$5" ovc="$6" err ov stamps n_un n_st ref models m pin bad=""
  local flat="$_CMP_TMP/packet.flat"
  if ! (cd "$dir" && "$METRICS" collect --all-sessions --main-root "$dir" --out "$pout") >/dev/null 2>"$_CMP_TMP/collect.err" \
     || ! json_flat "$pout" > "$flat" 2>/dev/null; then
    err="$(head -1 "$_CMP_TMP/collect.err" | tr -d '\r')"
    rc_emit "CHECK scope=$scope check=collect result=not-run reason=metrics.sh collect produced no readable packet${err:+: $err}"
    if [ "$ovc" = 1 ]; then rc_emit "CHECK scope=$scope check=override-count result=not-run value=unmeasured reason=no packet"; fi
    rc_emit "CHECK scope=$scope check=$role-resolved-id result=not-run value=unmeasured reason=no packet"
    rc_emit "CHECK scope=$scope check=$role-models result=not-run value=unmeasured reason=no packet"
    rc_emit "CHECK scope=$scope check=effort result=not-run value=unmeasured reason=no packet"
    return 0
  fi
  rc_emit "METRICS scope=$scope dir=$dir packet=$pout"

  # override-count: measured 0, and nothing else, passes.
  if [ "$ovc" = 1 ]; then
    ov="$(rc_flat_override "$flat")"
    case "$ov" in
      0) rc_emit "CHECK scope=$scope check=override-count result=pass value=0" ;;
      null|absent) rc_emit "CHECK scope=$scope check=override-count result=fail value=unmeasured reason=dispatches_with_model_override is $ov, so no override-free routing is shown" ;;
      *[!0-9]*|'') rc_emit "CHECK scope=$scope check=override-count result=fail value=unmeasured reason=dispatches_with_model_override is not a count: [$ov]" ;;
      *) rc_emit "CHECK scope=$scope check=override-count result=fail value=$ov reason=$ov dispatch(es) passed a model other than the one routing resolved" ;;
    esac
  fi

  # <role>-resolved-id: every dispatch of the role stamped, all with one value,
  # and that value the configured model.
  ref="$want"
  if ! rc_stamps "$dir/.agents/metrics/events" "$role" "$_CMP_TMP/stamps"; then
    rc_emit "CHECK scope=$scope check=$role-resolved-id result=fail value=unmeasured reason=an event log cannot be read, so the routing_resolved stamps are unmeasured"
  else
    n_un="$(grep -c '^unstamped$' "$_CMP_TMP/stamps")"
    awk -F'\t' '$1 == "stamped" { print $2 }' "$_CMP_TMP/stamps" | LC_ALL=C sort -u > "$_CMP_TMP/stamps.u"
    n_st="$(wc -l < "$_CMP_TMP/stamps.u" | tr -d ' ')"
    stamps="$(cat "$_CMP_TMP/stamps.u")"
    if [ ! -s "$_CMP_TMP/stamps" ]; then
      rc_emit "CHECK scope=$scope check=$role-resolved-id result=fail value=unmeasured reason=no $role dispatch is in the event logs, so no routing_resolved stamp was recorded"
    elif [ "$n_un" -gt 0 ]; then
      rc_emit "CHECK scope=$scope check=$role-resolved-id result=fail value=unmeasured reason=$n_un $role dispatch(es) carry no routing_resolved stamp"
    elif [ "$n_st" -ne 1 ]; then
      rc_emit "CHECK scope=$scope check=$role-resolved-id result=fail value=$(printf '%s' "$stamps" | paste -sd, -) reason=$role dispatches were stamped with more than one resolved id"
    elif [ -z "$stamps" ]; then
      rc_emit "CHECK scope=$scope check=$role-resolved-id result=fail value=unresolved reason=every $role dispatch carries an empty routing_resolved stamp: routing resolved no model"
    elif [ "$stamps" != "$want" ]; then
      ref="$stamps"
      rc_emit "CHECK scope=$scope check=$role-resolved-id result=fail value=$stamps reason=routing resolved [$stamps] at dispatch, not the configured $want"
    else
      rc_emit "CHECK scope=$scope check=$role-resolved-id result=pass value=$stamps"
    fi
  fi

  rc_effort "$scope" "$flat"

  # <role>-models: what the role actually ran on names the pinned id of the
  # alias routing resolved and nothing else, compared exactly.
  models="$(rc_flat_models "$flat" "$role")"
  if [ -z "$models" ]; then
    rc_emit "CHECK scope=$scope check=$role-models result=fail value=unmeasured reason=by_agent_role.$role.models names no model, so what the $role ran on is unmeasured"
    return 0
  fi
  pin="$(A="$ref" awk -F'\t' '$1 == ENVIRON["A"] { print $2; exit }' "$_RC_PINS")"
  if [ -z "$pin" ]; then
    rc_emit "CHECK scope=$scope check=$role-models result=fail value=$models reason=routing resolved [$ref], which the experiment's model_ids pins to no id"
    return 0
  fi
  for m in $(printf '%s' "$models" | tr ',' ' '); do [ "$m" = "$pin" ] || bad="$bad${bad:+,}$m"; done
  if [ -n "$bad" ]; then
    rc_emit "CHECK scope=$scope check=$role-models result=fail value=$models reason=by_agent_role.$role.models names $bad, not only $pin, the id model_ids pins $ref to"
  else
    rc_emit "CHECK scope=$scope check=$role-models result=pass value=$models"
  fi
}

cmd_routing_check() {
  [ $# -eq 1 ] || usage
  local rid="$1"
  case "$rid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "routing-check: not a replay id (12 hex, as \`prepare\` prints it): $rid" ;;
  esac
  METRICS="$HERE/metrics.sh"
  [ -x "$METRICS" ] || die "routing-check: metrics.sh is missing or not executable: $METRICS" 2

  # --- the replay's record, found in whichever experiment holds it --------------
  local store env="" f n=0
  store="$(store_root)"
  set +f
  for f in "$store"/*/replays/"$rid".env; do
    if [ -f "$f" ]; then env="$f"; n=$((n + 1)); fi
  done
  set -f
  [ "$n" -gt 0 ] || die "routing-check: no replay record for $rid under $store (run \`compare.sh prepare\` first)"
  [ "$n" -eq 1 ] || die "routing-check: replay $rid is recorded in $n experiments under $store; refusing to guess"
  local role model rmodel clone steps exp
  exp="$(sed -n 's/^EXPERIMENT=//p' "$env" | head -1)"
  role="$(sed -n 's/^ROLE=//p' "$env" | head -1)"
  model="$(sed -n 's/^MODEL=//p' "$env" | head -1)"
  rmodel="$(sed -n 's/^REVIEWER_MODEL=//p' "$env" | head -1)"
  clone="$(sed -n 's/^CLONE=//p' "$env" | head -1)"
  case "$role" in ''|*[!a-z-]*) die "routing-check: the replay record's role is malformed: [$role]" ;; esac
  case "$model" in ''|*[!A-Za-z0-9._-]*) die "routing-check: the replay record's model is malformed: [$model]" ;; esac
  case "$rmodel" in ''|*[!A-Za-z0-9._-]*) die "routing-check: the replay record's reviewer model is malformed: [$rmodel]" ;; esac
  [ -n "$clone" ] && git -C "$clone" rev-parse --git-dir >/dev/null 2>&1 \
    || die "routing-check: the replay's work clone is not a git repository: $clone"

  # --- only once every session has ended: the replay's step log carries its END -----
  steps="$(dirname "$env")/$rid.steps"
  [ -f "$steps" ] || die "routing-check: replay $rid has not been run (no step log): $steps"
  grep -q '^END=' "$steps" \
    || die "routing-check: replay $rid has not ended (no END= line in its step log), so a session may still be running: $steps"

  # Each review view of the replay, in order, with whether a reviewer session ran
  # in it (a reviewer STEP line between its VIEW= line and the next VIEW= or END=).
  local vlist
  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "routing-check: cannot create a temp root"
  trap '[ -n "$_CMP_TMP" ] && rm -rf "$_CMP_TMP"; :' EXIT

  # The experiment's pins, `<alias>\t<id>` per line, from its stored selection:
  # the replay's model and reviewer model must each have one.
  local sel="$store/$exp/selection.json" a
  case "$exp" in ''|*[!0-9a-f]*) die "routing-check: the replay record's experiment is malformed: [$exp]" ;; esac
  [ -f "$sel" ] || die "routing-check: no stored selection for the replay's experiment $exp: $sel"
  json_flat "$sel" > "$_CMP_TMP/sel" || die "routing-check: the stored selection is not readable JSON: $sel"
  _RC_PINS="$_CMP_TMP/pins"
  awk -F'\t' 'index($2, ".settings.model_ids.") == 1 && $3 == "s" && $4 != "" {
      print substr($2, length(".settings.model_ids.") + 1) "\t" $4 }' "$_CMP_TMP/sel" > "$_RC_PINS"
  for a in "$model" "$rmodel"; do
    A="$a" awk -F'\t' '$1 == ENVIRON["A"] { f = 1 } END { exit !f }' "$_RC_PINS" \
      || die "routing-check: experiment $exp's model_ids pins no id for $a: $sel"
  done
  _RC_EFFORT="$(sel_effort < "$_CMP_TMP/sel")"
  effort_is_level "$_RC_EFFORT" \
    || die "routing-check: experiment $exp's stored settings name no effort in: ${EFFORT_LEVELS[*]} (got [$_RC_EFFORT]): $sel"
  vlist="$_CMP_TMP/views"
  awk '
    function flush() { if (v != "") print s "\t" v }
    /^VIEW=/ { flush(); v = substr($0, 6); s = 0; next }
    /^END=/ { flush(); v = ""; next }
    /^STEP / && / agent=reviewer / { s = 1 }
    END { flush() }' "$steps" > "$vlist"

  # The packets go beside the replay's record, in the experiment's store: never
  # inside a view, where a reviewer could read them.
  local pdir k=0 sran view
  pdir="$(dirname "$env")/$rid.metrics"
  mkdir -p "$pdir" 2>/dev/null || die "routing-check: cannot create $pdir"
  pdir="$(cd "$pdir" && pwd -P)" || die "routing-check: cannot enter $pdir"
  while IFS='	' read -r sran view; do
    [ -d "$view" ] || continue
    view="$(cd "$view" && pwd -P)"
    case "$pdir/" in "$view/"*) die "routing-check: the metrics output would lie inside a review view: $pdir" ;; esac
    git_neutral "$view" || die "routing-check: a review view is not a repository of its own (or holds another repository inside it, or names a promisor remote), or its git command hooks cannot be neutralised: $view"
  done < "$vlist"
  # metrics.sh runs git in the clone and each view: with their command hooks off.
  git_neutral "$clone" || die "routing-check: the work clone is not a repository of its own (or holds another repository inside it, or names a promisor remote), or its git command hooks cannot be neutralised: $clone"

  _RC_OUT="$(dirname "$env")/$rid.routing"
  : > "$_RC_OUT" 2>/dev/null || die "routing-check: cannot write $_RC_OUT"
  _RC_FAIL=0; _RC_NOTRUN=0
  rc_emit "REPLAY=$rid"
  rc_emit "EFFORT=$_RC_EFFORT"
  rc_scope work "$clone" "$pdir/work.json" "$role" "$model" 1
  while IFS='	' read -r sran view; do
    k=$((k + 1))
    if [ "$sran" != 1 ]; then
      rc_emit "CHECK scope=view-$k check=reviewer-models result=not-run value=unmeasured reason=no review session ran in this view: $view"
    elif [ ! -d "$view" ]; then
      rc_emit "CHECK scope=view-$k check=reviewer-models result=not-run value=unmeasured reason=the review view is gone: $view"
    else
      rc_scope "view-$k" "$view" "$pdir/view-$k.json" reviewer "$rmodel" 0
    fi
  done < "$vlist"
  if [ "$_RC_FAIL" = 1 ]; then rc_emit "ROUTING_CHECK=fail"
  elif [ "$_RC_NOTRUN" = 1 ]; then rc_emit "ROUTING_CHECK=not-run"
  else rc_emit "ROUTING_CHECK=pass"
  fi
}

# --- sweeps --------------------------------------------------------------------------

# How long one required sweep may run, in seconds, when ORCH_COMPARE_SWEEP_TIMEOUT
# is unset.
_CMP_SWEEP_TIMEOUT_DEFAULT=1800

# sw_required <handoff>: every `scripts/test-<name>.sh` path the handoff names,
# sorted and de-duped, one per line. A path is read from each maximal run of
# path characters ([A-Za-z0-9._/-]) with its trailing full stops dropped, so a
# sentence's full stop is not part of it; the run must END in the sweep path,
# which must begin the run or follow a `/` (an absolute path to some checkout's
# sweep names that sweep). `scripts/test-*.sh`, a pattern, names none.
sw_required() {
  awk '
    { s = $0
      while (match(s, /[A-Za-z0-9._\/-]+/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/\.+$/, "", t)
        if (match(t, /(^|\/)scripts\/test-[A-Za-z0-9._-]+\.sh$/)) {
          t = substr(t, RSTART); sub(/^\//, "", t); print t
        }
      }
    }' "$1" | LC_ALL=C sort -u
}

# sw_tree_pids <pid>: <pid> and every process descended from it, one per line.
sw_tree_pids() {
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END {
      q[1] = root; n = 1
      for (i = 1; i <= n; i++) {
        print q[i]
        m = split(kids[q[i]], k, " ")
        for (j = 1; j <= m; j++) if (k[j] != "") q[++n] = k[j]
      }
    }'
}

# run_sweep <clone> <path> <log>: `bash <path>` in <clone>, stdin from /dev/null,
# stdout and stderr to <log>, killed together with every process it started
# when it outlives the sweep time limit. Its environment is the caller's with
# every ORCH_* and GIT_* variable removed and CLAUDE_PROJECT_DIR set to <clone>,
# so no harness setting or project root reaches it. Sets SW_EXIT to its exit
# code, or `timeout`.
run_sweep() {
  local dir="$1" path="$2" log="$3" pid t0 rc v pids
  local -a unset_args=()
  for v in $(compgen -e); do
    case "$v" in ORCH_*|GIT_*) unset_args+=(-u "$v") ;; esac
  done
  ( cd "$dir" && exec env ${unset_args[@]+"${unset_args[@]}"} CLAUDE_PROJECT_DIR="$dir" bash "$path" ) </dev/null >"$log" 2>&1 &
  pid=$!
  t0=$SECONDS
  SW_EXIT=""
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - t0)) -ge "$_CMP_SW_TIMEOUT" ]; then
      pids="$(sw_tree_pids "$pid")"
      kill -TERM $pids 2>/dev/null
      sleep 1
      kill -KILL $pids 2>/dev/null
      SW_EXIT="timeout"
      break
    fi
    sleep 0.2
  done
  wait "$pid" 2>/dev/null; rc=$?
  [ -n "$SW_EXIT" ] || SW_EXIT="$rc"
}

_SW_OUT=""
sw_emit() {
  printf '%s\n' "$1"
  printf '%s\n' "$1" >> "$_SW_OUT"
}

_CMP_SW_CLONE=""
_cmp_sweeps_cleanup() {
  if [ -n "$_CMP_TMP" ]; then rm -rf "$_CMP_TMP"; fi
  if [ -n "$_CMP_SW_CLONE" ]; then rm -rf "$_CMP_SW_CLONE"; fi
  return 0
}

cmd_sweeps() {
  [ $# -eq 1 ] || usage
  local rid="$1"
  case "$rid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "sweeps: not a replay id (12 hex, as \`prepare\` prints it): $rid" ;;
  esac
  _CMP_SW_TIMEOUT="${ORCH_COMPARE_SWEEP_TIMEOUT:-$_CMP_SWEEP_TIMEOUT_DEFAULT}"
  case "$_CMP_SW_TIMEOUT" in ''|0|*[!0-9]*) die "sweeps: ORCH_COMPARE_SWEEP_TIMEOUT is not a positive number of seconds: $_CMP_SW_TIMEOUT" 2 ;; esac

  # --- the replay's record, found in whichever experiment holds it --------------
  local store env="" f n=0
  store="$(store_root)"
  set +f
  for f in "$store"/*/replays/"$rid".env; do
    if [ -f "$f" ]; then env="$f"; n=$((n + 1)); fi
  done
  set -f
  [ "$n" -gt 0 ] || die "sweeps: no replay record for $rid under $store (run \`compare.sh prepare\` first)"
  [ "$n" -eq 1 ] || die "sweeps: replay $rid is recorded in $n experiments under $store; refusing to guess"
  local src cache steps
  _RP_PKT="$(sed -n 's/^PACKET=//p' "$env" | head -1)"
  _RP_ROLE="$(sed -n 's/^ROLE=//p' "$env" | head -1)"
  _RP_MODEL="$(sed -n 's/^MODEL=//p' "$env" | head -1)"
  _RP_RMODEL="$(sed -n 's/^REVIEWER_MODEL=//p' "$env" | head -1)"
  _RP_START="$(sed -n 's/^START=//p' "$env" | head -1)"
  _RP_CLONE="$(sed -n 's/^CLONE=//p' "$env" | head -1)"
  src="$(sed -n 's/^SOURCE_REPO=//p' "$env" | head -1)"
  cache="$(sed -n 's/^HANDOFF_CACHE=//p' "$env" | head -1)"
  case "$_RP_PKT" in ''|*[!A-Za-z0-9._-]*) die "sweeps: the replay record's packet is malformed: [$_RP_PKT]" ;; esac
  case "$_RP_ROLE" in ''|*[!a-z-]*) die "sweeps: the replay record's role is malformed: [$_RP_ROLE]" ;; esac
  case "$_RP_MODEL" in ''|*[!A-Za-z0-9._-]*) die "sweeps: the replay record's model is malformed: [$_RP_MODEL]" ;; esac
  case "$_RP_RMODEL" in ''|*[!A-Za-z0-9._-]*) die "sweeps: the replay record's reviewer model is malformed: [$_RP_RMODEL]" ;; esac
  case "$_RP_START" in ''|*[!0-9a-f]*) die "sweeps: the replay record's start is not a commit id: [$_RP_START]" ;; esac
  [ -n "$_RP_CLONE" ] && git -C "$_RP_CLONE" rev-parse --git-dir >/dev/null 2>&1 \
    || die "sweeps: the replay's work clone is not a git repository: $_RP_CLONE"
  git -C "$_RP_CLONE" cat-file -e "${_RP_START}^{commit}" 2>/dev/null \
    || die "sweeps: the replay's start commit is not in its work clone: $_RP_START"

  # --- only on the final diff: the replay's step log carries its END -----------------
  steps="$(dirname "$env")/$rid.steps"
  [ -f "$steps" ] || die "sweeps: replay $rid has not been run (no step log): $steps"
  grep -q '^END=' "$steps" \
    || die "sweeps: replay $rid has not ended (no END= line in its step log), so its diff is not final: $steps"

  # --- the required sweeps: from the packet's cached handoff, as first dispatched -----
  # Every model's replay of the packet reads the same bytes; the work clone's own
  # handoff may since carry a partial-work block naming what one model touched.
  [ -n "$cache" ] && [ -f "$cache" ] || die "sweeps: the replay's cached handoff is missing: $cache"
  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "sweeps: cannot create a temp root"
  trap _cmp_sweeps_cleanup EXIT
  local tmp="$_CMP_TMP" required
  git_neutral "$_RP_CLONE" \
    || die "sweeps: the work clone is not a repository of its own (or holds another repository inside it, or names a promisor remote), or its git command hooks cannot be neutralised: $_RP_CLONE"
  sw_required "$cache" > "$tmp/required" || die "sweeps: cannot read the cached handoff: $cache"
  required="$(paste -sd, - < "$tmp/required")"

  _SW_OUT="$(dirname "$env")/$rid.sweeps"
  : > "$_SW_OUT" 2>/dev/null || die "sweeps: cannot write $_SW_OUT"
  sw_emit "REPLAY=$rid"
  sw_emit "REQUIRED=${required:-none}"
  if [ -z "$required" ]; then
    sw_emit "SWEEPS=none-required"
    return 0
  fi

  # --- the final diff, as a tree, built without touching the work clone ---------------
  # land_tree's tree (what a land commit of the clone as it now stands holds),
  # built through a temp index and a temp object directory with the clone's own
  # objects as an alternate: the clone's index, object store and refs are only read.
  local cobj thead tstart rc
  cobj="$(cd "$_RP_CLONE" && cd "$(git rev-parse --git-path objects 2>/dev/null)" 2>/dev/null && pwd -P)" \
    || die "sweeps: cannot find the work clone's object store: $_RP_CLONE"
  mkdir -p "$tmp/objects" || die "sweeps: cannot create a temp object store"
  ( export GIT_OBJECT_DIRECTORY="$tmp/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$cobj"
    land_tree || exit $?
    printf '%s\n' "$LAND_TREE" > "$tmp/tree" ); rc=$?
  case "$rc" in
    0) ;;
    3) die "sweeps: the work clone's .agents/project-overrides.yaml cannot be read (a second model_routing key), so the replay's routing cannot be taken out of the final diff" ;;
    4) die "sweeps: the work clone's .agents/project-overrides.yaml is a symlink or has another hard link, so it is not read into the final diff" ;;
    *) die "sweeps: cannot build the final diff's tree from the work clone" ;;
  esac
  thead="$(cat "$tmp/tree")"
  tstart="$(git -C "$_RP_CLONE" rev-parse "${_RP_START}^{tree}" 2>/dev/null)" || die "sweeps: cannot read the start's tree"
  GIT_OBJECT_DIRECTORY="$tmp/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$cobj" \
    git -C "$_RP_CLONE" diff --binary --no-renames --no-ext-diff --no-textconv "$tstart" "$thead" > "$tmp/change.patch" 2>"$tmp/git.err" \
    || die "sweeps: cannot diff the final change: $(head -1 "$tmp/git.err")"
  sw_emit "TREE=$thead"

  # --- the scratch root: never inside the source's working tree ----------------------
  local scratch srctop
  [ -n "$src" ] && git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
    || die "sweeps: the source repository is not a git repository: $src"
  scratch="${ORCH_COMPARE_SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$scratch" 2>/dev/null || die "sweeps: cannot create the scratch root: $scratch"
  scratch="$(cd "$scratch" && pwd -P)" || die "sweeps: cannot enter the scratch root: $scratch"
  srctop="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  [ -n "$srctop" ] && srctop="$(cd "$srctop" && pwd -P)"
  if [ -n "$srctop" ]; then
    case "$scratch/" in
      "$srctop/"*) die "sweeps: the scratch root lies inside the source repository's working tree: $scratch" ;;
    esac
  fi

  # --- each required sweep, in its own fresh clone of the final diff -----------------
  local logs sw dname bname sc head got t0 failed=""
  logs="$(dirname "$env")/$rid.sweep-logs"
  rm -rf "$logs" && mkdir -p "$logs" || die "sweeps: cannot create $logs"
  : > "$tmp/noids"
  while IFS= read -r sw; do
    [ -n "$sw" ] || continue
    dname="$(opaque_name "" "$tmp/noids")" && bname="$(opaque_name "sweep-" "$tmp/noids")" \
      || die "sweeps: cannot draw a clone name"
    sc="$scratch/$dname"
    [ ! -e "$sc" ] || die "sweeps: the drawn clone path already exists: $sc"
    _CMP_SW_CLONE="$sc"
    opaque_clone sweeps "$src" "$_RP_START" "$sc" "$bname" "$tmp"
    if [ -s "$tmp/change.patch" ]; then
      git -C "$sc" apply --index --binary "$tmp/change.patch" 2>"$tmp/git.err" \
        || die "sweeps: the final diff does not apply to a fresh clone: $(head -1 "$tmp/git.err")"
    fi
    got="$(git -C "$sc" write-tree 2>/dev/null)"
    [ "$got" = "$thead" ] || die "sweeps: the fresh clone's tree [$got] is not the final diff's [$thead]"
    head="$(GIT_AUTHOR_NAME="$_CMP_VIEW_NAME" GIT_AUTHOR_EMAIL="$_CMP_VIEW_EMAIL" GIT_AUTHOR_DATE="$_CMP_VIEW_DATE" \
            GIT_COMMITTER_NAME="$_CMP_VIEW_NAME" GIT_COMMITTER_EMAIL="$_CMP_VIEW_EMAIL" GIT_COMMITTER_DATE="$_CMP_VIEW_DATE" \
            git -C "$sc" -c commit.gpgsign=false commit-tree "$thead" -p "$_RP_START" -m "Final diff under test" 2>/dev/null)" \
      && [ -n "$head" ] || die "sweeps: cannot commit the final diff in the fresh clone"
    git -C "$sc" update-ref "refs/heads/$bname" "$head" >/dev/null 2>&1 \
      || die "sweeps: cannot move the fresh clone's branch to the final diff"
    if [ ! -f "$sc/$sw" ]; then
      sw_emit "SWEEP path=$sw result=fail exit=not-run reason=absent-from-final-diff"
      failed="$failed${failed:+,}$sw"
    else
      t0=$SECONDS
      run_sweep "$sc" "$sw" "$logs/$(basename "$sw" .sh).log"
      if [ "$SW_EXIT" = 0 ]; then
        sw_emit "SWEEP path=$sw result=pass exit=0 seconds=$((SECONDS - t0)) log=$logs/$(basename "$sw" .sh).log"
      else
        sw_emit "SWEEP path=$sw result=fail exit=$SW_EXIT seconds=$((SECONDS - t0)) log=$logs/$(basename "$sw" .sh).log"
        failed="$failed${failed:+,}$sw"
      fi
    fi
    rm -rf "$sc"
    _CMP_SW_CLONE=""
  done < "$tmp/required"

  if [ -n "$failed" ]; then
    sw_emit "FAILED=$failed"
    sw_emit "SWEEPS=fail"
  else
    sw_emit "SWEEPS=pass"
  fi
}

# --- record ----------------------------------------------------------------------------

# rd_json_str <value>: <value> as a JSON string, `\` and `"` escaped and control
# characters dropped.
rd_json_str() {
  V="$1" awk 'BEGIN {
    s = ENVIRON["V"]; o = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\" || c == "\"") o = o "\\" c
      else if (c !~ /[[:cntrl:]]/) o = o c
    }
    printf "\"%s\"", o
  }'
}

# rd_route_pairs <routing.jsonl> <packet>: `<token>\t<action>` for each of the
# packet's routing records, in append order (the fields `runstate.sh route`
# writes); nothing when the file is absent.
rd_route_pairs() {
  [ -f "$1" ] || return 0
  P="$2" awk '
    function field(line, name,    pat, pos, rest, q) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      rest = substr(line, pos + length(pat))
      q = index(rest, "\"")
      if (q == 0) return ""
      return substr(rest, 1, q - 1)
    }
    { sub(/\r$/, ""); if (field($0, "packet") != ENVIRON["P"]) next
      print field($0, "token") "\t" field($0, "action") }' "$1"
}

# rd_step_field <line> <name>: the value of a `name=value` word of a step-log line.
rd_step_field() {
  printf '%s\n' "$1" | awk -v n="$2=" '{ for (i = 1; i <= NF; i++) if (index($i, n) == 1) { print substr($i, length(n) + 1); exit } }'
}

# rd_transcript_denials <transcript>: the denied calls one transcript records,
# read from its records parsed as JSON (json_flat), one line each:
#   K<TAB><kind><TAB><tools>  a denied call counted (its toolDenialKind, and the
#                    tool it asked for)
#   U<TAB><why>      the transcript cannot be read for denials
# <tools> is the name of the call the denial answers: the tool result's
# `message.content[].tool_use_id` joined to the `message.content[].id` of an
# assistant record in the same transcript, whose `.name` it takes. Each name is
# reduced to [A-Za-z0-9._-] (it is transcript text) and several are
# comma-joined; a denial whose call cannot be found reads `unrecorded`, never
# dropped. The count and the kind never depend on it.
# THE RECOGNISED FORM, as Claude Code writes it (read from real transcripts, main
# and subagent alike): a tool result is a top-level record of `"type":"user"`
# whose `message.content` array holds an object of `"type":"tool_result"`, and a
# call that did not run is such a record carrying a top-level string
# `toolDenialKind`. Only that top-level field is read, never the text anywhere on
# a line (a tool's output quoting the field is not a denial). The transcript is
# unreadable, so its denials unmeasured, when a line is not JSON; when it holds
# tool results (a `message.content[].type` of `tool_result` or a
# `message.content[].tool_use_id` in any record, or a top-level `toolUseResult`,
# `sourceToolAssistantUUID` or `toolDenialKind`) and none of them is in the
# recognised form; when a `toolDenialKind` sits anywhere but the top level of a
# recognised tool result, or is not a non-empty string there. So a format change
# that moves a tool result or the field reads unmeasured, never a silent 0. A
# transcript with no tool result at all denied nothing: 0, measured. Every kind
# counts but `interrupted` (a person's interrupt) and `cancelled` (the response
# stopped by a safety classifier), which no guard or permission rule decided.
rd_transcript_denials() {
  json_flat "$1" > "$_CMP_TMP/tx.flat" 2>/dev/null \
    || { printf 'U\ttranscript %s is not JSON lines, so its tool results cannot be read\n' "$1"; return 0; }
  F="$1" awk -F'\t' '
    $2 == ".type" { ty[$1] = $4; next }
    $2 ~ /^\.message\.content\[[0-9]+\]\.type$/ && $4 == "tool_result" { tr[$1] = 1; held = 1; next }
    $2 ~ /^\.message\.content\[[0-9]+\]\.tool_use_id$/ { held = 1; if ($3 == "s" && $4 != "") { nu[$1]++; tu[$1, nu[$1]] = $4 }; next }
    $2 ~ /^\.message\.content\[[0-9]+\]\.id$/   && $3 == "s" { p = $2; sub(/\.id$/, "", p); cid[$1, p] = $4; next }
    $2 ~ /^\.message\.content\[[0-9]+\]\.name$/ && $3 == "s" { p = $2; sub(/\.name$/, "", p); cnm[$1, p] = $4; next }
    $2 == ".toolDenialKind" { held = 1; if ($3 == "s" && $4 != "") dk[$1] = $4; else bad = "a toolDenialKind that is not a non-empty string"; next }
    $2 ~ /\.toolDenialKind(\.|\[|$)/ { held = 1; bad = "a toolDenialKind at " $2 ", not the top level of a tool result"; next }
    $2 ~ /^\.(toolUseResult|sourceToolAssistantUUID)(\.|\[|$)/ { held = 1 }
    END {
      for (d in tr) if (ty[d] == "user") rec++
      for (d in dk) if (!(d in tr) || ty[d] != "user") bad = "a toolDenialKind on a record that is not a tool result in the recognised form"
      if (bad != "") { printf "U\ttranscript %s carries %s\n", ENVIRON["F"], bad; exit }
      if (held && !rec) { printf "U\ttranscript %s holds tool results, none in the recognised form (a user record whose message.content holds a tool_result)\n", ENVIRON["F"]; exit }
      # A tool call is a message.content item of an assistant record, with an id and a name.
      for (k in cid) { split(k, kp, SUBSEP); if (ty[kp[1]] == "assistant" && (k in cnm)) nm[cid[k]] = cnm[k] }
      for (d in dk) if (dk[d] != "interrupted" && dk[d] != "cancelled") {
        tools = ""
        for (i = 1; i <= nu[d]; i++) if (tu[d, i] in nm) {
          t = nm[tu[d, i]]; gsub(/[^A-Za-z0-9._-]/, "?", t)
          if (index("," tools ",", "," t ",") == 0) tools = tools (tools == "" ? "" : ",") t
        }
        printf "K\t%s\t%s\n", dk[d], (tools == "" ? "unrecorded" : tools)
      }
    }' "$_CMP_TMP/tx.flat"
}

# rd_session_denials <projects-dir> <session-id>...: the tool calls denied in
# those sessions, one line:
#   measured<TAB><count><TAB><kinds, comma-joined, sorted, or none><TAB><tools, likewise>
# where <tools> are the denied calls' tool names, `unrecorded` among them for a
# denial whose call its transcript does not name.
#   null<TAB><why>
# A session's transcript is <projects-dir>/*/<id>.jsonl, and its subagents' are
# <projects-dir>/*/<id>/subagents/agent-*.jsonl, as metrics.sh finds them; each
# is read by rd_transcript_denials. A session id that is not the form
# `run_session` writes, a session with no transcript, or a transcript that
# cannot be read for denials leaves the count unmeasured: never 0.
rd_session_denials() {
  local proj="$1" sid f files main n=0 kinds="" tools="" why
  shift
  : > "$_CMP_TMP/denials"; : > "$_CMP_TMP/denials.tools"
  for sid in "$@"; do
    case "$sid" in
      -) printf 'null\ta STEP line names no session, so its transcript cannot be found\n'; return 0 ;;
      ''|*[!0-9a-f-]*) printf 'null\ta session id that is not one run_session writes: %s\n' "$sid"; return 0 ;;
    esac
    main=""; files=""
    set +f
    for f in "$proj"/*/"$sid".jsonl; do [ -f "$f" ] && main="$f"; done
    for f in "$proj"/*/"$sid"/subagents/agent-*.jsonl; do [ -f "$f" ] && files="$files$f"$'\n'; done
    set -f
    [ -n "$main" ] || { printf 'null\tsession %s has no transcript under %s\n' "$sid" "$proj"; return 0; }
    : > "$_CMP_TMP/denials.one"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rd_transcript_denials "$f" >> "$_CMP_TMP/denials.one"
    done <<EOF
$main
$files
EOF
    why="$(awk -F'\t' '$1 == "U" { print substr($0, 3); exit }' "$_CMP_TMP/denials.one")"
    [ -z "$why" ] || { printf 'null\tsession %s: %s\n' "$sid" "$why"; return 0; }
    awk -F'\t' '$1 == "K" { print $2 }' "$_CMP_TMP/denials.one" >> "$_CMP_TMP/denials"
    awk -F'\t' '$1 == "K" { print ($3 == "" ? "unrecorded" : $3) }' "$_CMP_TMP/denials.one" | tr ',' '\n' >> "$_CMP_TMP/denials.tools"
  done
  n="$(awk 'END { print NR }' "$_CMP_TMP/denials")"
  kinds="$(sort -u "$_CMP_TMP/denials" | paste -sd, -)"
  tools="$(sort -u "$_CMP_TMP/denials.tools" | paste -sd, -)"
  printf 'measured\t%s\t%s\t%s\n' "$n" "${kinds:-none}" "${tools:-none}"
}

# rd_denials <step-log> <projects-dir>: the tool calls denied in the replay's
# sessions, as rd_session_denials prints them. Every STEP line names the session
# it ran (`session=`, the id `run_session` started it on); a STEP line with no
# session leaves the count unmeasured: never 0.
rd_denials() {
  local sids
  sids="$(awk '/^STEP / { s = "-"; for (i = 2; i <= NF; i++) if (index($i, "session=") == 1) s = substr($i, 9); if (s == "") s = "-"; print s }' "$1")"
  # shellcheck disable=SC2086  # ids are one word each: split on purpose (set -f is on)
  rd_session_denials "$2" $sids
}

# rd_cost <flat-packet> <role> <packet>: the varied role's tokens, one line:
#   measured<TAB><input><TAB><output><TAB><cache_creation><TAB><cache_read>
#   null<TAB><why>
# `implementer`: the sum of the packet's packets[].dispatches[].tokens rows.
# Any other role: by_agent_role.<role>.tokens plus by_agent_role.gaffer:<role>'s.
# One null, absent or non-count figure anywhere makes the whole figure null.
rd_cost() {
  R="$2" P="$3" awk -F'\t' '
    BEGIN { split("input output cache_creation cache_read", F, " ")
            r1 = ".by_agent_role." ENVIRON["R"] "."; r2 = ".by_agent_role.gaffer:" ENVIRON["R"] "." }
    function isf(f) { return f == "input" || f == "output" || f == "cache_creation" || f == "cache_read" }
    match($2, /^\.packets\[[0-9]+\]/) {
      i = substr($2, 10, RLENGTH - 10) + 0; rest = substr($2, RLENGTH + 1)
      if (rest == ".id" && $3 == "s") { if ($4 == ENVIRON["P"]) want[i] = 1; next }
      if (rest == ".dispatches") { if ($4 == "null") dnull[i] = 1; next }
      if (match(rest, /^\.dispatches\[[0-9]+\]/)) {
        j = substr(rest, 13, RLENGTH - 13) + 0; r = substr(rest, RLENGTH + 1)
        d[i, j] = 1; if (j + 1 > nd[i]) nd[i] = j + 1
        if (r == ".tokens") tnull[i, j] = 1
        else if (index(r, ".tokens.") == 1 && isf(substr(r, 9))) {
          if ($3 == "n" && $4 ~ /^[0-9]+$/) tok[i, j, substr(r, 9)] = $4; else tbad[i, j] = 1
        }
      }
      next
    }
    {
      k = ""
      if (index($2, r1) == 1) k = "a"; else if (index($2, r2) == 1) k = "b"; else next
      seen[k] = 1
      r = substr($2, length(k == "a" ? r1 : r2) + 1)
      if (index(r, "tokens.") == 1 && isf(substr(r, 8))) {
        if ($3 == "n" && $4 ~ /^[0-9]+$/) rt[k, substr(r, 8)] = $4; else rbad[k] = 1
      }
    }
    function out(why) { if (why != "") { printf "null\t%s\n", why; exit } }
    END {
      if (ENVIRON["R"] == "implementer") {
        np = 0; ndisp = 0
        for (i in want) {
          np++
          if (i in dnull) out("the packet row'"'"'s dispatches is null")
          for (j = 0; j < nd[i]; j++) {
            if (!((i, j) in d)) continue
            ndisp++
            if (((i, j) in tnull) || ((i, j) in tbad)) out("a dispatch row'"'"'s tokens are null or not counts (no transcript turn resolved to it)")
            for (f = 1; f <= 4; f++) {
              if (!((i, j, F[f]) in tok)) out("a dispatch row lacks tokens." F[f])
              sum[F[f]] += tok[i, j, F[f]]
            }
          }
        }
        if (np == 0) out("the work clone'"'"'s packet has no row for " ENVIRON["P"])
        if (ndisp == 0) out("the packet row has no dispatch row")
      } else {
        if (!("a" in seen) && !("b" in seen)) out("by_agent_role." ENVIRON["R"] " is absent from the work clone'"'"'s packet")
        for (k in seen) {
          if (k in rbad) out("by_agent_role tokens for " ENVIRON["R"] " are null or not counts")
          for (f = 1; f <= 4; f++) {
            if (!((k, F[f]) in rt)) out("by_agent_role tokens for " ENVIRON["R"] " lack " F[f])
            sum[F[f]] += rt[k, F[f]]
          }
        }
      }
      printf "measured\t%.0f\t%.0f\t%.0f\t%.0f\n", sum["input"], sum["output"], sum["cache_creation"], sum["cache_read"]
    }' "$1"
}

cmd_record() {
  [ $# -eq 1 ] || usage
  local rid="$1"
  case "$rid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "record: not a replay id (12 hex, as \`prepare\` prints it): $rid" ;;
  esac

  # --- the replay's record, found in whichever experiment holds it --------------
  local store env="" f n=0
  store="$(store_root)"
  set +f
  for f in "$store"/*/replays/"$rid".env; do
    if [ -f "$f" ]; then env="$f"; n=$((n + 1)); fi
  done
  set -f
  [ "$n" -gt 0 ] || die "record: no replay record for $rid under $store (run \`compare.sh prepare\` first)"
  [ "$n" -eq 1 ] || die "record: replay $rid is recorded in $n experiments under $store; refusing to guess"
  local exp pkt role model rmodel clone run_id hsrc rdir
  rdir="$(dirname "$env")"
  exp="$(sed -n 's/^EXPERIMENT=//p' "$env" | head -1)"
  pkt="$(sed -n 's/^PACKET=//p' "$env" | head -1)"
  role="$(sed -n 's/^ROLE=//p' "$env" | head -1)"
  model="$(sed -n 's/^MODEL=//p' "$env" | head -1)"
  rmodel="$(sed -n 's/^REVIEWER_MODEL=//p' "$env" | head -1)"
  clone="$(sed -n 's/^CLONE=//p' "$env" | head -1)"
  run_id="$(sed -n 's/^RUN_ID=//p' "$env" | head -1)"
  hsrc="$(sed -n 's/^HANDOFF_SOURCE=//p' "$env" | head -1)"
  case "$exp" in ''|*[!0-9a-f]*) die "record: the replay record's experiment is malformed: [$exp]" ;; esac
  case "$pkt" in ''|*[!A-Za-z0-9._-]*) die "record: the replay record's packet is malformed: [$pkt]" ;; esac
  case "$role" in ''|*[!a-z-]*) die "record: the replay record's role is malformed: [$role]" ;; esac
  case "$model" in ''|*[!A-Za-z0-9._-]*) die "record: the replay record's model is malformed: [$model]" ;; esac
  case "$rmodel" in ''|*[!A-Za-z0-9._-]*) die "record: the replay record's reviewer model is malformed: [$rmodel]" ;; esac
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) die "record: the replay record's run id is malformed: [$run_id]" ;; esac
  case "$hsrc" in original|rebuilt) ;; *) die "record: the replay record's handoff source is malformed: [$hsrc]" ;; esac
  [ -n "$clone" ] && [ -d "$clone" ] || die "record: the replay's work clone is missing: $clone"

  # --- only an ended, routing-checked replay: every input the outcome needs -----
  local steps rcf end rcheck
  steps="$rdir/$rid.steps"
  rcf="$rdir/$rid.routing"
  [ -f "$steps" ] || die "record: replay $rid has not been run (no step log): $steps"
  end="$(sed -n 's/^END=//p' "$steps" | tail -1)"
  [ -n "$end" ] || die "record: replay $rid has not ended (no END= line in its step log), so its outcome is not decided: $steps"
  case "$end" in land|decider|stop|crashed|timed-out|refused|error) ;;
    *) die "record: the step log's END= line is not one replay writes: [$end]" ;; esac
  rcheck=""
  if [ -f "$rcf" ]; then rcheck="$(sed -n 's/^ROUTING_CHECK=//p' "$rcf" | tail -1)"; fi
  case "$rcheck" in pass|fail|not-run) ;;
    *) die "record: replay $rid has no ROUTING_CHECK= line (run \`compare.sh routing-check\` first), so its outcome is not decided: $rcf" ;; esac

  local records="$store/records.jsonl"
  if [ -f "$records" ] && R="\"replay\":\"$rid\"" awk 'index($0, ENVIRON["R"]) { f = 1 } END { exit !f }' "$records"; then
    die "record: replay $rid already has a record in $records (a rerun is a new replay)"
  fi

  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "record: cannot create a temp root"
  trap '[ -n "$_CMP_TMP" ] && rm -rf "$_CMP_TMP"; :' EXIT
  local tmp="$_CMP_TMP"

  # The clone's routing records for the packet must be the step log's ROUTE lines.
  local rj="$clone/.agents/loop/$run_id/routing.jsonl"
  rd_route_pairs "$rj" "$pkt" > "$tmp/pairs" || die "record: cannot read the work clone's routing records: $rj"
  awk '/^ROUTE / { t = ""; a = ""
         for (i = 2; i <= NF; i++) { if (index($i, "token=") == 1) t = substr($i, 7); else if (index($i, "action=") == 1) a = substr($i, 8) }
         print t "\t" a }' "$steps" > "$tmp/steps.pairs"
  cmp -s "$tmp/pairs" "$tmp/steps.pairs" \
    || die "record: the work clone's routing records for $pkt ($(wc -l < "$tmp/pairs" | tr -d ' ')) are not the step log's ROUTE lines ($(wc -l < "$tmp/steps.pairs" | tr -d ' ')): $rj"

  # --- the tool calls denied in the replay's sessions ---------------------------------
  local den dstate dcount="" dkinds="" dtools="" dnote=""
  den="$(rd_denials "$steps" "${ORCH_METRICS_PROJECTS_DIR:-$HOME/.claude/projects}")"
  dstate="$(printf '%s\n' "$den" | cut -f1)"
  if [ "$dstate" = measured ]; then
    dcount="$(printf '%s\n' "$den" | cut -f2)"; dkinds="$(printf '%s\n' "$den" | cut -f3)"; dtools="$(printf '%s\n' "$den" | cut -f4)"
    case "$dcount" in ''|*[!0-9]*) die "record: the denial count is not a count: [$dcount]" ;; esac
  else
    dnote="denials unmeasured: $(printf '%s\n' "$den" | cut -f2-)"
  fi

  # --- the outcome, in the PRD's order -----------------------------------------------
  local outcome reason last ltok lact att lim whose=""
  last="$(grep '^ROUTE ' "$steps" | tail -1)"
  ltok="$(tail -1 "$tmp/pairs" | cut -f1)"
  lact="$(tail -1 "$tmp/pairs" | cut -f2)"
  # END=refused: whose line was refused is the agent of the step log's last STEP
  # line, the step `replay` ended on (a second refusal, or a reviewer token
  # outside the review vocabulary).
  if [ "$end" = refused ]; then
    whose="$(rd_step_field "$(grep '^STEP ' "$steps" | tail -1)" agent)"
    case "$whose" in ''|*[!a-z:-]*) die "record: the replay ended refused, but its step log's last STEP line names no readable agent: $steps" ;; esac
  fi
  # `cause` is an invalid outcome's reason as one token (empty, stored null, for
  # every other outcome), so `report` and `rank-prepare` never parse the reason.
  local cause=""
  if [ "$rcheck" != pass ]; then
    outcome=invalid; cause=routing; reason="the routing check read $rcheck"
  elif case "$end" in crashed|timed-out|error) true ;; *) false ;; esac; then
    outcome=invalid; cause="$end"; reason="the replay ended $end without a verdict it could route"
  elif [ "$end" = refused ] && [ "$whose" != "$role" ]; then
    outcome=invalid; cause=fixed-role-refused; reason="the replay ended refused on the $whose's line, a role not under test (a harness fault)"
  elif [ -n "$dcount" ] && [ "$dcount" -gt 0 ]; then
    outcome=invalid; cause=denial; reason="$dcount tool call(s) were denied in the replay's sessions ($dkinds; tools: $dtools): a harness fault, not the model's"
  elif awk -F'\t' '$1 == "escalate" { f = 1 } END { exit !f }' "$tmp/pairs"; then
    outcome=escalated; reason="the reviewer returned escalate"
  elif [ "$end" = refused ]; then
    # The varied role's own line refused: the loop's stop on it, scored against
    # the model. Attempts are the last ROUTE line's; with none routed yet, 0 of a
    # limit that is at least 1 (runstate.sh reads a missing or 0 packet_attempts
    # as 1), so an attempt remained.
    if [ -z "$last" ]; then
      outcome=escalated; reason="the $role's own line was refused with no attempt routed yet, so an attempt remained"
    else
      att="$(rd_step_field "$last" attempts)"; lim="$(rd_step_field "$last" limit)"
      case "$att" in ''|*[!0-9]*) die "record: the last ROUTE line carries no readable attempts=: [$last]" ;; esac
      case "$lim" in ''|*[!0-9]*) die "record: the last ROUTE line carries no readable limit=: [$last]" ;; esac
      if [ "$att" -lt "$lim" ]; then
        outcome=escalated; reason="the $role's own line was refused with $att of $lim attempts used, so an attempt remained"
      else
        outcome=failed-at-limit; reason="the $role's own line was refused with $att of $lim attempts used: the attempt limit is reached"
      fi
    fi
  elif [ "$end" = decider ] || [ "$end" = stop ]; then
    [ "$lact" = "$end" ] || die "record: the replay ended $end, but its last routing record routed to [$lact]"
    att="$(rd_step_field "$last" attempts)"; lim="$(rd_step_field "$last" limit)"
    case "$att" in ''|*[!0-9]*) die "record: the last ROUTE line carries no readable attempts=: [$last]" ;; esac
    case "$lim" in ''|*[!0-9]*) die "record: the last ROUTE line carries no readable limit=: [$last]" ;; esac
    if [ "$att" -lt "$lim" ]; then
      outcome=escalated; reason="$ltok routed to $end with $att of $lim attempts used, so an attempt remained"
    else
      outcome=failed-at-limit; reason="$ltok routed to $end with $att of $lim attempts used: the attempt limit is reached"
    fi
  else
    [ "$ltok:$lact" = "pass:land" ] || die "record: the replay ended land, but its last routing record is [$ltok] routed to [$lact]"
    outcome=passed; reason="the reviewer returned pass"
  fi

  local first fixr sweeps=""
  first="$(awk -F'\t' '$1 == "pass" || $1 == "fix" || $1 == "retry" || $1 == "escalate" { print $1; exit }' "$tmp/pairs")"
  fixr="$(awk -F'\t' '$1 == "fix" && $2 == "attempt" { n++ } END { print n + 0 }' "$tmp/pairs")"
  if [ -f "$rdir/$rid.sweeps" ]; then sweeps="$(sed -n 's/^SWEEPS=//p' "$rdir/$rid.sweeps" | tail -1)"; fi
  case "$sweeps" in pass|fail|none-required) ;; *) sweeps="" ;; esac

  # --- the experiment's settings and the model's pinned id -------------------------------
  local sel="$store/$exp/selection.json" settings pin
  [ -f "$sel" ] || die "record: no stored selection for the replay's experiment $exp: $sel"
  json_flat "$sel" > "$tmp/sel" || die "record: the stored selection is not readable JSON: $sel"
  [ "$(awk -F'\t' '$2 == ".experiment" { print $4; exit }' "$tmp/sel")" = "$exp" ] \
    || die "record: the stored selection does not name experiment $exp: $sel"
  settings="$(awk 'index($0, "  \"settings\": {") == 1 { s = substr($0, 15); sub(/,[[:space:]]*$/, "", s); print s; exit }' "$sel" | tr -d '\r')"
  printf '{"s": %s}\n' "$settings" > "$tmp/settings.json"
  [ -n "$settings" ] && json_flat "$tmp/settings.json" > /dev/null 2>&1 \
    || die "record: the stored selection's settings cannot be read as one JSON object: $sel"
  pin="$(M="$model" awk -F'\t' '$2 == ".settings.model_ids." ENVIRON["M"] && $3 == "s" { print $4; exit }' "$tmp/sel")"
  local effort js_effort="null"
  effort="$(sel_effort < "$tmp/sel")"
  [ -n "$effort" ] && js_effort="$(rd_json_str "$effort")"

  # --- the cost ------------------------------------------------------------------------------
  local prices="${ORCH_COMPARE_PRICES:-$HERE/spend-prices.json}" tdate csrc="by_agent_role" note=""
  [ "$role" = implementer ] && csrc="dispatches"
  [ -f "$prices" ] || die "record: no price table: $prices"
  json_flat "$prices" > "$tmp/prices" || die "record: the price table is not readable JSON: $prices"
  tdate="$(awk -F'\t' '$2 == ".table_date" && $3 == "s" { print $4; exit }' "$tmp/prices")"
  [ -n "$tdate" ] || die "record: the price table has no table_date: $prices"
  local cost cstate ti to tc tr
  if [ -f "$rdir/$rid.metrics/work.json" ] && json_flat "$rdir/$rid.metrics/work.json" > "$tmp/work" 2>/dev/null; then
    cost="$(rd_cost "$tmp/work" "$role" "$pkt")"
  else
    cost="$(printf 'null\tthe work clone has no readable metrics packet (%s)' "$rdir/$rid.metrics/work.json")"
  fi
  cstate="$(printf '%s\n' "$cost" | cut -f1)"
  local tokens_json="null" dmin="null" dmax="null" price="null"
  if [ "$cstate" = measured ]; then
    ti="$(printf '%s\n' "$cost" | cut -f2)"; to="$(printf '%s\n' "$cost" | cut -f3)"
    tc="$(printf '%s\n' "$cost" | cut -f4)"; tr="$(printf '%s\n' "$cost" | cut -f5)"
    tokens_json="{\"input\":$ti,\"output\":$to,\"cache_creation\":$tc,\"cache_read\":$tr}"
    if [ "$rcheck" != pass ]; then
      note="tokens not priced: the routing check read $rcheck, so they are not shown to have been spent on the pinned model"
    elif [ -z "$pin" ]; then
      note="tokens not priced: the experiment's model_ids pins no id for $model"
    else
      local rates
      rates="$(price_rates "$tmp/prices" "$pin")"
      if [ -z "$rates" ]; then
        note="tokens not priced: the price table has no complete entry for $pin, the id model_ids pins $model to"
      else
        price="$(rd_json_str "$pin")"
        dmin="$(printf '%s\n' "$rates" | awk -v i="$ti" -v o="$to" -v c="$tc" -v r="$tr" '{ printf "%.6f", (i * $1 + o * $2 + r * $3 + c * $4) / 1000000 }')"
        dmax="$(printf '%s\n' "$rates" | awk -v i="$ti" -v o="$to" -v c="$tc" -v r="$tr" '{ printf "%.6f", (i * $1 + o * $2 + r * $3 + c * $5) / 1000000 }')"
      fi
    fi
  else
    note="tokens unmeasured: $(printf '%s\n' "$cost" | cut -f2-)"
  fi

  # --- the one record, appended only now that the outcome is decided ---------------------------
  local js_first="null" js_sweeps="null" js_note="null" js_den="null" js_dnote="null" line
  [ -n "$first" ] && js_first="$(rd_json_str "$first")"
  [ -n "$sweeps" ] && js_sweeps="$(rd_json_str "$sweeps")"
  [ -n "$note" ] && js_note="$(rd_json_str "$note")"
  [ -n "$dcount" ] && js_den="$dcount"
  [ -n "$dnote" ] && js_dnote="$(rd_json_str "$dnote")"
  # The denied calls' kinds and tool names, one string each and [] when none was
  # denied; null when the denials are unmeasured.
  local js_cause="null" js_dkinds="null" js_dtools="null" k
  [ -n "$cause" ] && js_cause="$(rd_json_str "$cause")"
  if [ -n "$dcount" ]; then
    js_dkinds=""; js_dtools=""
    if [ "$dcount" -gt 0 ]; then
      while IFS= read -r k; do
        [ -n "$k" ] && js_dkinds="$js_dkinds${js_dkinds:+,}$(rd_json_str "$k")"
      done < <(printf '%s\n' "$dkinds" | tr ',' '\n')
      while IFS= read -r k; do
        [ -n "$k" ] && js_dtools="$js_dtools${js_dtools:+,}$(rd_json_str "$k")"
      done < <(printf '%s\n' "${dtools:-unrecorded}" | tr ',' '\n')
    fi
    js_dkinds="[$js_dkinds]"; js_dtools="[$js_dtools]"
  fi
  line="$(printf '{"experiment":%s,"replay":%s,"packet":%s,"model":%s,"role":%s,"reviewer_model":%s,"effort":%s,"handoff_source":%s,"settings":%s,"outcome":%s,"outcome_reason":%s,"invalid_cause":%s,"first_verdict":%s,"fix_rounds":%s,"sweeps":%s,"routing_check":%s,"end":%s,"denials":%s,"denial_kinds":%s,"denial_tools":%s,"denial_note":%s,"tokens":%s,"dollars_min":%s,"dollars_max":%s,"price":%s,"price_table_date":%s,"cost_source":%s,"cost_note":%s,"recorded_at":%s}' \
    "$(rd_json_str "$exp")" "$(rd_json_str "$rid")" "$(rd_json_str "$pkt")" "$(rd_json_str "$model")" \
    "$(rd_json_str "$role")" "$(rd_json_str "$rmodel")" "$js_effort" "$(rd_json_str "$hsrc")" "$settings" \
    "$(rd_json_str "$outcome")" "$(rd_json_str "$reason")" "$js_cause" "$js_first" "$fixr" "$js_sweeps" \
    "$(rd_json_str "$rcheck")" "$(rd_json_str "$end")" "$js_den" "$js_dkinds" "$js_dtools" "$js_dnote" "$tokens_json" "$dmin" "$dmax" "$price" \
    "$(rd_json_str "$tdate")" "$(rd_json_str "$csrc")" "$js_note" "$(rd_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")")"
  printf '%s\n' "$line" > "$tmp/line.json"
  json_flat "$tmp/line.json" > /dev/null 2>&1 || die "record: the record could not be built as one JSON line"
  mkdir -p "$store" 2>/dev/null && printf '%s\n' "$line" >> "$records" \
    || die "record: the record could not be appended: $records"

  printf 'REPLAY=%s\nOUTCOME=%s\nREASON=%s\nFIRST_VERDICT=%s\nFIX_ROUNDS=%s\nSWEEPS=%s\n' \
    "$rid" "$outcome" "$reason" "${first:-none}" "$fixr" "${sweeps:-not-run}"
  printf 'DENIALS=%s\n' "${dcount:-unmeasured}"
  if [ "$cstate" = measured ]; then
    printf 'TOKENS=%s\n' "$(awk -v a="$ti" -v b="$to" -v c="$tc" -v d="$tr" 'BEGIN { printf "%.0f", a + b + c + d }')"
  else
    printf 'TOKENS=unmeasured\n'
  fi
  printf 'DOLLARS_MIN=%s\nDOLLARS_MAX=%s\nRECORDS=%s\n' \
    "$( [ "$dmin" = null ] && echo unmeasured || echo "$dmin")" "$( [ "$dmax" = null ] && echo unmeasured || echo "$dmax")" "$records"
}

# --- run ---------------------------------------------------------------------------

# run_records <records.jsonl> <experiment>: one
# `<line>\t<replay>\t<packet>\t<model>\t<outcome>\t<cause>\t<kinds>\t<tools>\t<denials>` row per
# record of that experiment, in file order, so the last row for a packet and
# model is its latest record (THE LATEST-RECORD RULE). <cause> is the record's
# `invalid_cause`, `unrecorded` when it holds none (a record written before the
# field existed); <kinds> its `denial_kinds` comma-joined, `unrecorded` when it
# names none (json_flat emits nothing for an empty list, so [] and a record
# written before the field existed read alike; a `denial` cause always has a
# kind); <tools> its `denial_tools` likewise (a `denial` cause always has one,
# `unrecorded` when the transcript did not name the call). Each is reduced to
# [A-Za-z0-9._-] per name (both are transcript text). <denials> is the record's
# `denials` count, `unrecorded` when it holds none (null: unmeasured, never 0).
# Exit 1 on a file it cannot read.
run_records() {
  local flat
  flat="$(json_flat "$1")" || return 1
  printf '%s\n' "$flat" | EXP="$2" awk -F'\t' '
    function safe(s) { gsub(/[^A-Za-z0-9._-]/, "?", s); return s }
    $1 + 0 > n { n = $1 + 0 }
    $2 == ".experiment" && $3 == "s" { e[$1] = $4 }
    $2 == ".replay"     && $3 == "s" { r[$1] = $4 }
    $2 == ".packet"     && $3 == "s" { p[$1] = $4 }
    $2 == ".model"      && $3 == "s" { m[$1] = $4 }
    $2 == ".outcome"    && $3 == "s" { o[$1] = $4 }
    $2 == ".invalid_cause" && $3 == "s" { c[$1] = safe($4) }
    $2 ~ /^\.denial_kinds\[[0-9]+\]$/ && $3 == "s" { k[$1] = k[$1] (k[$1] == "" ? "" : ",") safe($4) }
    $2 ~ /^\.denial_tools\[[0-9]+\]$/ && $3 == "s" { t[$1] = t[$1] (t[$1] == "" ? "" : ",") safe($4) }
    $2 == ".denials" && $3 == "n" && $4 ~ /^[0-9]+$/ { dn[$1] = $4 }
    END { for (d = 1; d <= n; d++) if ((d in e) && e[d] == ENVIRON["EXP"] && (d in p) && (d in m))
            print d "\t" r[d] "\t" p[d] "\t" m[d] "\t" o[d] "\t" ((d in c) ? c[d] : "unrecorded") "\t" ((d in k) ? k[d] : "unrecorded") "\t" ((d in t) ? t[d] : "unrecorded") "\t" ((d in dn) ? dn[d] : "unrecorded") }'
}

# run_pause: is a pause requested? Returns 0 and prints the reason when it is.
# The sentinel is read only through `runstate.sh pause-status`. Anything but
# its `PAUSE=0` answer reads as a pause: an unreadable answer stops the run
# rather than spending on.
run_pause() {
  local pf out
  pf="${ORCH_PAUSE_FILE:-$(main_checkout)/.agents/pause}"
  out="$("$RUNSTATE" pause-status "$pf" 2>/dev/null | tr -d '\r' | head -1)"
  case "$out" in
    PAUSE=0) return 1 ;;
    'PAUSE=1 reason='*) printf '%s' "${out#PAUSE=1 reason=}" ;;
    *) printf 'pause-status gave no answer it reads (%s), so the run stops' "${out:-nothing}" ;;
  esac
  return 0
}

# run_step <step> <args...>: this script's own subcommand, stdin from
# /dev/null, its stdout in $_CMP_TMP/step.out and both streams appended to the
# run's log under a header. Sets RS_RC.
run_step() {
  printf '== %s ==\n' "$*" >> "$RUN_LOG"
  "$RUN_SELF" "$@" < /dev/null > "$_CMP_TMP/step.out" 2>> "$RUN_LOG"; RS_RC=$?
  cat "$_CMP_TMP/step.out" >> "$RUN_LOG"
  printf -- '-- exit %s\n' "$RS_RC" >> "$RUN_LOG"
}

# run_one <experiment> <packet> <model>: prepare -> replay -> routing-check ->
# sweeps -> record for one replay. Returns 1 at a step that stops the run.
run_one() {
  local exp="$1" p="$2" m="$3" rid end v
  run_step prepare "$exp" "$p" "$m"
  rid="$(sed -n 's/^REPLAY=//p' "$_CMP_TMP/step.out" | head -1)"
  case "$rid" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) rid="" ;; esac
  printf 'STEP packet=%s model=%s replay=%s step=prepare exit=%s\n' "$p" "$m" "${rid:-none}" "$RS_RC"
  [ "$RS_RC" -eq 0 ] && [ -n "$rid" ] || return 1

  run_step replay "$rid"
  end=""
  if [ -f "$RUN_DIR/replays/$rid.steps" ]; then end="$(sed -n 's/^END=//p' "$RUN_DIR/replays/$rid.steps" | tail -1)"; fi
  printf 'STEP packet=%s model=%s replay=%s step=replay exit=%s end=%s\n' "$p" "$m" "$rid" "$RS_RC" "${end:-none}"
  # An END= line is what `record` decides from, `error` included; a replay
  # refused before it started leaves none, and nothing can be recorded.
  [ -n "$end" ] || return 1

  run_step routing-check "$rid"
  v="$(sed -n 's/^ROUTING_CHECK=//p' "$_CMP_TMP/step.out" | tail -1)"
  printf 'STEP packet=%s model=%s replay=%s step=routing-check exit=%s routing_check=%s\n' "$p" "$m" "$rid" "$RS_RC" "${v:-none}"
  [ "$RS_RC" -eq 0 ] && [ -n "$v" ] || return 1

  run_step sweeps "$rid"
  v="$(sed -n 's/^SWEEPS=//p' "$_CMP_TMP/step.out" | tail -1)"
  [ "$RS_RC" -eq 0 ] || v=""
  printf 'STEP packet=%s model=%s replay=%s step=sweeps exit=%s sweeps=%s\n' "$p" "$m" "$rid" "$RS_RC" "${v:-not-run}"

  run_step record "$rid"
  v="$(sed -n 's/^OUTCOME=//p' "$_CMP_TMP/step.out" | head -1)"
  printf 'STEP packet=%s model=%s replay=%s step=record exit=%s outcome=%s\n' "$p" "$m" "$rid" "$RS_RC" "${v:-none}"
  [ "$RS_RC" -eq 0 ] && [ -n "$v" ] || return 1
  printf 'DONE packet=%s model=%s replay=%s outcome=%s\n' "$p" "$m" "$rid" "$v"
}

cmd_run() {
  local exp="" tok="" rerun=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --approve) [ $# -ge 2 ] || usage; tok="$2"; shift 2 ;;
      --rerun)   [ $# -ge 2 ] || usage; rerun="$2"; shift 2 ;;
      -*) usage ;;
      *) [ -z "$exp" ] || usage; exp="$1"; shift ;;
    esac
  done
  [ -n "$exp" ] && [ -n "$tok" ] || usage
  case "$exp" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "run: not an experiment id (12 hex, as \`settings\` prints it): $exp" ;;
  esac
  case "$tok" in
    *[!0-9a-f]*) die "run: not an approval token (hex, as \`estimate\` prints it on its APPROVAL= line): $tok" ;;
  esac
  if [ -n "$rerun" ]; then
    case "$rerun" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) die "run: --rerun: not a replay id (12 hex, as \`prepare\` prints it): $rerun" ;;
    esac
  fi
  [ -x "$RUNSTATE" ] || die "run: runstate.sh is missing or not executable: $RUNSTATE" 2

  local store appr records
  store="$(store_root)"
  RUN_DIR="$store/$exp"
  RUN_SELF="$HERE/$(basename "$0")"
  appr="$RUN_DIR/approvals.jsonl"
  records="$store/records.jsonl"
  [ -f "$RUN_DIR/selection.json" ] || die "run: no stored selection for experiment $exp (run \`compare.sh select\` first): $RUN_DIR/selection.json"

  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "run: cannot create a temp root"
  _CMP_LOCK=""
  trap '[ -n "$_CMP_LOCK" ] && rmdir "$_CMP_LOCK" 2>/dev/null; [ -n "$_CMP_TMP" ] && rm -rf "$_CMP_TMP"; :' EXIT
  local tmp="$_CMP_TMP"

  # --- the lock: held from reading the token to consuming it, so two runs never
  # both find it pending -------------------------------------------------------------
  mkdir "$RUN_DIR/approvals.lock" 2>/dev/null \
    || die "run: the approvals lock is held, by another run consuming a token or one that stopped while it did (remove it only when no run is active): $RUN_DIR/approvals.lock"
  _CMP_LOCK="$RUN_DIR/approvals.lock"

  # --- the token: missing, spent, superseded or valid ----------------------------------
  [ -f "$appr" ] || die "run: token $tok is missing: no approval has been issued for experiment $exp (run \`compare.sh estimate\`): $appr"
  json_flat "$appr" > "$tmp/appr" || die "run: the approvals file is not readable JSONL, so no token in it can be checked: $appr"
  awk -F'\t' '
    $1 + 0 > n { n = $1 + 0 }
    $2 == ".token" && $3 == "s" { t[$1] = $4 }
    $2 == ".state" && $3 == "s" { s[$1] = $4 }
    END { for (d = 1; d <= n; d++) print d "\t" t[d] "\t" s[d] }' "$tmp/appr" > "$tmp/lines"
  local mine spent newer
  mine="$(TOK="$tok" awk -F'\t' '$2 == ENVIRON["TOK"] && $3 == "pending" { d = $1 } END { print d }' "$tmp/lines")"
  spent="$(TOK="$tok" awk -F'\t' '$2 == ENVIRON["TOK"] && $3 == "consumed" { f = 1 } END { print f + 0 }' "$tmp/lines")"
  [ "$spent" = 0 ] || die "run: token $tok is spent: a run has already consumed it (run \`compare.sh estimate --remaining\` for a new one): $appr"
  [ -n "$mine" ] || die "run: token $tok is missing: no estimate for experiment $exp issued it (run \`compare.sh estimate\`): $appr"
  newer="$(TOK="$tok" MINE="$mine" awk -F'\t' '$1 + 0 > ENVIRON["MINE"] + 0 && $3 == "pending" && $2 != ENVIRON["TOK"] { print $2; exit }' "$tmp/lines")"
  [ -z "$newer" ] || die "run: token $tok is superseded: a later estimate issued token $newer, and only the newest pending token runs: $appr"

  local scope setd
  scope="$(MINE="$mine" awk -F'\t' '$1 == ENVIRON["MINE"] && $2 == ".scope" && $3 == "s" { print $4; exit }' "$tmp/appr")"
  setd="$(MINE="$mine" awk -F'\t' '$1 == ENVIRON["MINE"] && $2 == ".set" && $3 == "s" { print $4; exit }' "$tmp/appr")"
  MINE="$mine" awk -F'\t' '
    $1 == ENVIRON["MINE"] && $2 ~ /^\.replays\[[0-9]+\]\.(packet|model)$/ && $3 == "s" {
      i = $2; sub(/^\.replays\[/, "", i); sub(/\].*$/, "", i); i += 0; if (i + 1 > n) n = i + 1
      if ($2 ~ /packet$/) p[i] = $4; else m[i] = $4
    }
    END { for (i = 0; i < n; i++) print p[i] "\t" m[i] }' "$tmp/appr" > "$tmp/set"
  if [ ! -s "$tmp/set" ] || LC_ALL=C grep -q -v '^[A-Za-z0-9._-][A-Za-z0-9._-]*	[A-Za-z0-9._-][A-Za-z0-9._-]*$' "$tmp/set"; then
    die "run: token $tok's stored replay set is empty or malformed: $appr"
  fi
  # The set it was issued for, byte for byte: the digest `estimate` stored.
  [ "$(awk -F'\t' '{ printf "REPLAY packet=%s model=%s\n", $1, $2 }' "$tmp/set" | digest)" = "$setd" ] \
    || die "run: token $tok's stored replays do not digest to its stored set [$setd], so they are not the set it approved: $appr"

  # --- the records: which replays are recorded, and each pair's latest ----------------
  : > "$tmp/recs"
  if [ -f "$records" ]; then
    run_records "$records" "$exp" > "$tmp/recs" \
      || die "run: the records file is not readable JSONL, so which replays are recorded cannot be read: $records"
  fi

  # --- --rerun: only an invalid replay whose record is its pair's latest ---------------
  local rpkt="" rmod=""
  if [ -n "$rerun" ]; then
    local renv="$RUN_DIR/replays/$rerun.env" rrow latest lrep lout
    [ -f "$renv" ] || die "run: --rerun $rerun: experiment $exp holds no replay of that id: $renv"
    rpkt="$(sed -n 's/^PACKET=//p' "$renv" | head -1)"
    rmod="$(sed -n 's/^MODEL=//p' "$renv" | head -1)"
    case "$rpkt:$rmod" in :*|*:|*[!A-Za-z0-9._:-]*) die "run: --rerun $rerun: the replay record's packet or model is malformed: [$rpkt] [$rmod]" ;; esac
    rrow="$(R="$rerun" awk -F'\t' '$2 == ENVIRON["R"]' "$tmp/recs" | tail -1)"
    [ -n "$rrow" ] || die "run: --rerun $rerun: the replay has no record, so it has no invalid outcome to rerun"
    latest="$(P="$rpkt" M="$rmod" awk -F'\t' '$3 == ENVIRON["P"] && $4 == ENVIRON["M"]' "$tmp/recs" | tail -1)"
    lrep="$(printf '%s\n' "$latest" | cut -f2)"
    lout="$(printf '%s\n' "$latest" | cut -f5)"
    [ "$lrep" = "$rerun" ] \
      || die "run: --rerun $rerun: its record is not the latest for packet $rpkt on $rmod: replay $lrep's (outcome ${lout:-unreadable}) is, and later readers use that one"
    [ "$lout" = invalid ] \
      || die "run: --rerun $rerun: its latest record's outcome is ${lout:-unreadable}, not invalid; only an invalid replay is rerun"
    P="$rpkt" M="$rmod" awk -F'\t' '$1 == ENVIRON["P"] && $2 == ENVIRON["M"] { f = 1 } END { exit !f }' "$tmp/set" \
      || die "run: --rerun $rerun: token $tok did not approve a replay of packet $rpkt on $rmod (run \`compare.sh estimate\` for a token whose set holds it)"
  fi

  # --- the plan: each pair of the set, to run or skip (already recorded) ---------------
  local p m k nrun=0
  : > "$tmp/plan"
  while IFS="$(printf '\t')" read -r p m; do
    if [ -n "$rerun" ]; then
      [ "$p:$m" = "$rpkt:$rmod" ] || continue
      k=run
    elif P="$p" M="$m" awk -F'\t' '$3 == ENVIRON["P"] && $4 == ENVIRON["M"] { f = 1 } END { exit !f }' "$tmp/recs"; then
      k=skip
    else
      k=run
    fi
    [ "$k" = run ] && nrun=$((nrun + 1))
    printf '%s\t%s\t%s\n' "$k" "$p" "$m" >> "$tmp/plan"
  done < "$tmp/set"

  printf 'RUN experiment=%s token=%s scope=%s replays=%s%s\n' "$exp" "$tok" "${scope:-unknown}" \
    "$(grep -c . "$tmp/set")" "${rerun:+ rerun=$rerun}"

  # --- a pause already requested: stop before the token is spent ----------------------
  local preason first
  if [ "$nrun" -gt 0 ] && preason="$(run_pause)"; then
    first="$(awk -F'\t' '$1 == "run" { print "packet=" $2 " model=" $3; exit }' "$tmp/plan")"
    printf 'PAUSED %s reason=%s\n' "$first" "$preason"
    printf 'RAN=0 SKIPPED=0 REMAINING=%s\nLOG=none\nRUN=paused\n' "$nrun"
    return 0
  fi

  # --- consume the token, then release the lock ---------------------------------------
  local js_rerun=null
  [ -n "$rerun" ] && js_rerun="\"$rerun\""
  printf '{"token":"%s","state":"consumed","experiment":"%s","consumed_at":"%s","rerun":%s}\n' \
    "$tok" "$exp" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$js_rerun" >> "$appr" \
    || die "run: token $tok could not be consumed, so no replay runs: $appr"
  rmdir "$_CMP_LOCK" 2>/dev/null; _CMP_LOCK=""
  printf 'APPROVED token=%s state=consumed\n' "$tok"

  # --- the replays, in the set's order --------------------------------------------------
  mkdir -p "$RUN_DIR/runs" 2>/dev/null || die "run: the run log directory could not be made: $RUN_DIR/runs"
  RUN_LOG="$RUN_DIR/runs/$tok.log"
  local state=complete started=0 ran=0 skipped=0 remaining=0
  while IFS="$(printf '\t')" read -r k p m; do
    if [ "$state" != complete ]; then
      [ "$k" = run ] && remaining=$((remaining + 1))
      continue
    fi
    if [ "$k" = skip ]; then
      printf 'SKIP packet=%s model=%s reason=recorded\n' "$p" "$m"; skipped=$((skipped + 1)); continue
    fi
    if [ "$started" -eq 1 ] && preason="$(run_pause)"; then
      printf 'PAUSED packet=%s model=%s reason=%s\n' "$p" "$m" "$preason"
      state=paused; remaining=$((remaining + 1)); continue
    fi
    started=1
    printf 'START packet=%s model=%s\n' "$p" "$m"
    if run_one "$exp" "$p" "$m"; then ran=$((ran + 1)); else state=error; fi
  done < "$tmp/plan"

  printf 'RAN=%s SKIPPED=%s REMAINING=%s\nLOG=%s\nRUN=%s\n' "$ran" "$skipped" "$remaining" "$RUN_LOG" "$state"
  [ "$state" != error ] || exit 1
}

# --- rank-prepare --------------------------------------------------------------------

# The outcomes a packet is ranked with: each one the replayed model's own work
# decided. `invalid` is a harness fault, so that replay is re-run first, unless
# a call was denied in it: the same rule would deny the rerun again.
_CMP_RANKABLE="passed escalated failed-at-limit"
# Where a ranking clone holds its letter-labelled final diffs, and the labels.
_CMP_RANK_DIR=".agents/ranking"
_CMP_RANK_LETTERS="A B C D E F G H I J K L M N O P Q R S T U V W X Y Z"

_CMP_RANK=""
_cmp_rank_cleanup() {
  if [ -n "$_CMP_TMP" ]; then rm -rf "$_CMP_TMP"; fi
  if [ -n "$_CMP_RANK" ]; then rm -rf "$_CMP_RANK"; fi
  return 0
}

cmd_rank_prepare() {
  [ $# -eq 2 ] || usage
  local exp="$1" pkt="$2"
  case "$exp" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "rank-prepare: not an experiment id (12 hex, as \`settings\` prints it): $exp" ;;
  esac
  case "$pkt" in ''|*[!A-Za-z0-9._-]*) die "rank-prepare: not a packet id: $pkt" ;; esac
  [ -x "$ROUTING" ] || die "rank-prepare: routing.sh is missing or not executable: $ROUTING" 2

  local store dir sel records
  store="$(store_root)"
  dir="$store/$exp"
  sel="$dir/selection.json"
  records="$store/records.jsonl"
  [ -f "$sel" ] || die "rank-prepare: no stored selection for experiment $exp (run \`compare.sh select\` first): $sel"

  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "rank-prepare: cannot create a temp root"
  trap _cmp_rank_cleanup EXIT
  local tmp="$_CMP_TMP"

  # --- the stored selection: the models, the reviewer and this packet's start -------
  json_flat "$sel" > "$tmp/sel" || die "rank-prepare: the stored selection is not readable JSON: $sel"
  local sexp src rmodel idx start nmod
  sexp="$(awk -F'\t' '$2 == ".experiment" { print $4; exit }' "$tmp/sel")"
  [ "$sexp" = "$exp" ] || die "rank-prepare: the stored selection names experiment [$sexp], not $exp: $sel"
  src="$(awk -F'\t' '$2 == ".settings.source_repo" { print $4; exit }' "$tmp/sel")"
  rmodel="$(awk -F'\t' '$2 == ".settings.reviewer_model" { print $4; exit }' "$tmp/sel")"
  awk -F'\t' '$2 ~ /^\.settings\.models\[[0-9]+\]$/ { print $4 }' "$tmp/sel" > "$tmp/models"
  case "$rmodel" in ''|*[!A-Za-z0-9._-]*) die "rank-prepare: the stored selection's reviewer model is malformed: [$rmodel]" ;; esac
  if LC_ALL=C grep -q '[^A-Za-z0-9._-]' "$tmp/models" 2>/dev/null || [ ! -s "$tmp/models" ]; then
    die "rank-prepare: the stored selection's models are malformed: $sel"
  fi
  nmod="$(grep -c . "$tmp/models")"
  [ "$nmod" -le 26 ] || die "rank-prepare: $nmod models is more than the 26 letters a ranking labels them with"
  { cat "$tmp/models"; printf '%s\n' "$rmodel"; } > "$tmp/ids"
  idx="$(P="$pkt" awk -F'\t' '$2 ~ /^\.selected\[[0-9]+\]\.packet$/ && $4 == ENVIRON["P"] { i = $2; sub(/^\.selected\[/, "", i); sub(/\].*$/, "", i); print i; exit }' "$tmp/sel")"
  [ -n "$idx" ] || die "rank-prepare: packet $pkt is not in experiment $exp's selection: $sel"
  start="$(I=".selected[$idx].start" awk -F'\t' '$2 == ENVIRON["I"] { print $4; exit }' "$tmp/sel")"
  case "$start" in ''|*[!0-9a-f]*) die "rank-prepare: packet $pkt's stored start is not a commit id: [$start]" ;; esac

  # --- every model's latest record for the packet: passed, escalated or failed-at-limit
  # THE LATEST-RECORD RULE: the last records.jsonl line naming the experiment,
  # packet and model. Each model that has none, or whose latest is `invalid` or
  # anything else, is named, and nothing is built.
  : > "$tmp/recs"
  if [ -f "$records" ]; then
    run_records "$records" "$exp" > "$tmp/recs" \
      || die "rank-prepare: the records file is not readable JSONL, so which replays are recorded cannot be read: $records"
  fi
  local m latest lrep lout lcause lkinds ltools lden nbad=0
  : > "$tmp/ranked"
  while IFS= read -r m; do
    latest="$(P="$pkt" M="$m" awk -F'\t' '$3 == ENVIRON["P"] && $4 == ENVIRON["M"]' "$tmp/recs" | tail -1)"
    if [ -z "$latest" ]; then
      printf 'UNRANKABLE packet=%s model=%s reason=missing\n' "$pkt" "$m" >&2
      nbad=$((nbad + 1)); continue
    fi
    lrep="$(printf '%s\n' "$latest" | cut -f2)"
    lout="$(printf '%s\n' "$latest" | cut -f5)"
    case " $_CMP_RANKABLE " in
      *" $lout "*) printf '%s\t%s\n' "$m" "$lrep" >> "$tmp/ranked" ;;
      *)
        if [ "$lout" = invalid ]; then
          # The invalid replay's cause, as its record stored it; a denial names
          # the denied calls' kinds and the tools they asked for too.
          lcause="$(printf '%s\n' "$latest" | cut -f6)"
          lkinds="$(printf '%s\n' "$latest" | cut -f7)"
          ltools="$(printf '%s\n' "$latest" | cut -f8)"
          lden="$(printf '%s\n' "$latest" | cut -f9)"
          if [ "$lcause" = denial ]; then
            printf 'UNRANKABLE packet=%s model=%s reason=invalid cause=denial kinds=%s tools=%s replay=%s\n' "$pkt" "$m" "${lkinds:-unrecorded}" "${ltools:-unrecorded}" "$lrep" >&2
          elif case "$lden" in ''|0|*[!0-9]*) false ;; *) true ;; esac; then
            # An earlier cause decided the outcome, but the record counts calls
            # denied too: a rerun would meet the same denial.
            printf 'UNRANKABLE packet=%s model=%s reason=invalid cause=%s denials=%s kinds=%s tools=%s replay=%s\n' "$pkt" "$m" "${lcause:-unrecorded}" "$lden" "${lkinds:-unrecorded}" "${ltools:-unrecorded}" "$lrep" >&2
          else
            printf 'UNRANKABLE packet=%s model=%s reason=invalid cause=%s replay=%s\n' "$pkt" "$m" "${lcause:-unrecorded}" "$lrep" >&2
          fi
        else
          printf 'UNRANKABLE packet=%s model=%s reason=outcome(%s) replay=%s\n' "$pkt" "$m" "${lout:-unreadable}" "$lrep" >&2
        fi
        nbad=$((nbad + 1)) ;;
    esac
  done < "$tmp/models"
  [ "$nbad" -eq 0 ] \
    || die "rank-prepare: packet $pkt is not ranked until every model's latest record is passed, escalated or failed-at-limit; $nbad of $nmod models' are not (an invalid replay is re-run first, through \`compare.sh run --rerun\`, unless a call was denied in it, named by kinds= above: the same rule would deny the rerun again until the harness configuration changes)"

  # --- each model's final diff: the tree `sweeps` tests, the work clone only read -------
  # land_tree's tree: _CMP_LAND_EXCLUDED (metrics, run directory, run-state,
  # roadmap, plan) as the start holds them and the replay's model_routing taken
  # back out, built through a temp index and a temp object directory.
  local k=0 rid env cobj tstart rc
  while IFS="$(printf '\t')" read -r m rid; do
    k=$((k + 1))
    env="$dir/replays/$rid.env"
    [ -f "$env" ] || die "rank-prepare: model $m's latest record names replay $rid, which experiment $exp holds no record of: $env"
    _RP_CLONE="$(sed -n 's/^CLONE=//p' "$env" | head -1)"
    _RP_START="$(sed -n 's/^START=//p' "$env" | head -1)"
    _RP_ROLE="$(sed -n 's/^ROLE=//p' "$env" | head -1)"
    _RP_MODEL="$(sed -n 's/^MODEL=//p' "$env" | head -1)"
    _RP_RMODEL="$(sed -n 's/^REVIEWER_MODEL=//p' "$env" | head -1)"
    [ "$_RP_MODEL" = "$m" ] || die "rank-prepare: replay $rid's record names model [$_RP_MODEL], not $m: $env"
    [ "$_RP_START" = "$start" ] || die "rank-prepare: replay $rid started at [$_RP_START], not packet $pkt's stored start $start: $env"
    [ "$_RP_RMODEL" = "$rmodel" ] || die "rank-prepare: replay $rid's reviewer model is [$_RP_RMODEL], not the selection's $rmodel: $env"
    case "$_RP_ROLE" in ''|*[!a-z-]*) die "rank-prepare: replay $rid's role is malformed: [$_RP_ROLE]" ;; esac
    [ -n "$_RP_CLONE" ] && git -C "$_RP_CLONE" rev-parse --git-dir >/dev/null 2>&1 \
      || die "rank-prepare: replay $rid's work clone is not a git repository: $_RP_CLONE"
    git -C "$_RP_CLONE" cat-file -e "${start}^{commit}" 2>/dev/null \
      || die "rank-prepare: replay $rid's start commit is not in its work clone: $start"
    git_neutral "$_RP_CLONE" \
      || die "rank-prepare: replay $rid's work clone is not a repository of its own (or holds another repository inside it, or names a promisor remote), or its git command hooks cannot be neutralised: $_RP_CLONE"
    cobj="$(cd "$_RP_CLONE" && cd "$(git rev-parse --git-path objects 2>/dev/null)" 2>/dev/null && pwd -P)" \
      || die "rank-prepare: cannot find replay $rid's work clone object store: $_RP_CLONE"
    tstart="$(git -C "$_RP_CLONE" rev-parse "${start}^{tree}" 2>/dev/null)" || die "rank-prepare: cannot read the start's tree"
    rm -rf "$tmp/objects" && mkdir -p "$tmp/objects" || die "rank-prepare: cannot create a temp object store"
    ( export GIT_OBJECT_DIRECTORY="$tmp/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$cobj"
      land_tree || exit $?
      git -C "$_RP_CLONE" diff --no-color --no-ext-diff --no-textconv --no-renames "$tstart" "$LAND_TREE" > "$tmp/diff.$k" 2>"$tmp/git.err" || exit 1
    ); rc=$?
    case "$rc" in
      0) ;;
      3) die "rank-prepare: replay $rid's .agents/project-overrides.yaml cannot be read (a second model_routing key), so its routing cannot be taken out of the final diff" ;;
      4) die "rank-prepare: replay $rid's .agents/project-overrides.yaml is a symlink or has another hard link, so it is not read into the final diff" ;;
      *) die "rank-prepare: cannot build replay $rid's final diff from its work clone: $(head -1 "$tmp/git.err" 2>/dev/null)" ;;
    esac
  done < "$tmp/ranked"

  # --- the order: shuffled for this packet alone -----------------------------------------
  # One fresh random key per diff, drawn on every call, sorted: no order is
  # shared with another packet or derived from the settings' model order.
  local j
  : > "$tmp/keys"
  j=0
  while [ "$j" -lt "$k" ]; do
    j=$((j + 1))
    printf '%s\t%s\n' "$(new_token)" "$j" >> "$tmp/keys"
  done
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$tmp/keys" | cut -f2 > "$tmp/order"
  [ "$(grep -c . "$tmp/order")" -eq "$k" ] || die "rank-prepare: cannot draw the order"

  # --- the ranking clone: opaque, at the start, reviewer-only routing --------------------
  local scratch srctop dname bname rkid rclone
  [ -n "$src" ] && git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
    || die "rank-prepare: the source repository is not a git repository: $src"
  git -C "$src" cat-file -e "${start}^{commit}" 2>/dev/null \
    || die "rank-prepare: packet $pkt's start commit is not in the source repository: $start"
  scratch="${ORCH_COMPARE_SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$scratch" 2>/dev/null || die "rank-prepare: cannot create the scratch root: $scratch"
  scratch="$(cd "$scratch" && pwd -P)" || die "rank-prepare: cannot enter the scratch root: $scratch"
  srctop="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  [ -n "$srctop" ] && srctop="$(cd "$srctop" && pwd -P)"
  if [ -n "$srctop" ]; then
    case "$scratch/" in
      "$srctop/"*) die "rank-prepare: the scratch root lies inside the source repository's working tree: $scratch" ;;
    esac
  fi
  # The ranking session works in the clone, so its whole path is something it reads.
  if names_model "$scratch" "$tmp/ids"; then
    die "rank-prepare: the scratch root's path names a model, which the ranking reviewer would read: $scratch"
  fi
  dname="$(opaque_name "" "$tmp/ids")" || die "rank-prepare: no directory name free of every model identifier could be drawn"
  bname="$(opaque_name "rank-" "$tmp/ids")" || die "rank-prepare: no branch name free of every model identifier could be drawn"
  rkid="$(opaque_name "" "$tmp/ids" | cut -c1-12)"
  [ "${#rkid}" -eq 12 ] || die "rank-prepare: no ranking id could be drawn"
  rclone="$scratch/$dname"
  [ ! -e "$rclone" ] || die "rank-prepare: the drawn ranking clone path already exists: $rclone"
  _CMP_RANK="$rclone"
  opaque_clone rank-prepare "$src" "$start" "$rclone" "$bname" "$tmp"
  if git -C "$rclone" cat-file -e "$start:$_CMP_RANK_DIR" 2>/dev/null || [ -e "$rclone/$_CMP_RANK_DIR" ]; then
    die "rank-prepare: the start already holds $_CMP_RANK_DIR, where the ranking's diffs go"
  fi

  # The reviewer-only model_routing the review view carries: every entry of the
  # start's map dropped, `reviewer: <reviewer model>` alone written, committed
  # with the view's fixed identity when it changes the start's tree.
  local ov=".agents/project-overrides.yaml" tbase base got r_rev
  : > "$tmp/ov.start"
  if git -C "$rclone" cat-file -e "$start:$ov" 2>/dev/null; then
    git -C "$rclone" show "$start:$ov" > "$tmp/ov.start" 2>/dev/null || die "rank-prepare: cannot read the start's $ov"
  else
    rm -f "$tmp/ov.start"
  fi
  set_routing "$tmp/ov.start" "$tmp/ov.base" "" "" "$rmodel" \
    || die "rank-prepare: the start commit's model_routing cannot be read, so it cannot be reduced: $ov"
  mkdir -p "$rclone/.agents" || die "rank-prepare: cannot create $rclone/.agents"
  cp "$tmp/ov.base" "$rclone/$ov" || die "rank-prepare: cannot write the ranking clone's $ov"
  git -C "$rclone" add -f -- "$ov" >/dev/null 2>&1 || die "rank-prepare: cannot stage the ranking clone's $ov"
  tbase="$(git -C "$rclone" write-tree 2>/dev/null)" || die "rank-prepare: cannot write the ranking clone's tree"
  if [ "$tbase" = "$(git -C "$rclone" rev-parse "$start^{tree}" 2>/dev/null)" ]; then
    base="$start"
  else
    base="$(GIT_AUTHOR_NAME="$_CMP_VIEW_NAME" GIT_AUTHOR_EMAIL="$_CMP_VIEW_EMAIL" GIT_AUTHOR_DATE="$_CMP_VIEW_DATE" \
            GIT_COMMITTER_NAME="$_CMP_VIEW_NAME" GIT_COMMITTER_EMAIL="$_CMP_VIEW_EMAIL" GIT_COMMITTER_DATE="$_CMP_VIEW_DATE" \
            git -C "$rclone" -c commit.gpgsign=false commit-tree "$tbase" -p "$start" -m "$_CMP_VIEW_BASE_MSG" 2>/dev/null)" \
      && [ -n "$base" ] || die "rank-prepare: cannot commit the ranking clone's configuration"
    git -C "$rclone" update-ref -m "$_CMP_VIEW_BASE_MSG" "refs/heads/$bname" "$base" >/dev/null 2>&1 \
      || die "rank-prepare: cannot move the ranking clone's branch to its configuration"
  fi
  got="$(git -C "$rclone" status --porcelain=v1 --untracked-files=no 2>/dev/null)"
  [ -z "$got" ] || die "rank-prepare: the ranking clone's tree is not clean at its configuration: $(printf '%s' "$got" | head -1)"
  r_rev="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$rclone" resolve reviewer 2>/dev/null | tr -d '\r')"
  [ "$r_rev" = "$rmodel" ] \
    || die "rank-prepare: routing.sh does not resolve the ranking clone's reviewer as set (reviewer -> [$r_rev], wanted $rmodel)"

  # --- the diffs, letter-labelled in the drawn order; the map kept outside ----------------
  local L lab labels="" jl="" om orid
  set -- $_CMP_RANK_LETTERS
  mkdir -p "$rclone/$_CMP_RANK_DIR" || die "rank-prepare: cannot create $rclone/$_CMP_RANK_DIR"
  while IFS= read -r j; do
    L="$1"; shift
    om="$(sed -n "${j}p" "$tmp/ranked" | cut -f1)"
    orid="$(sed -n "${j}p" "$tmp/ranked" | cut -f2)"
    cp "$tmp/diff.$j" "$rclone/$_CMP_RANK_DIR/$L.diff" || die "rank-prepare: cannot write $rclone/$_CMP_RANK_DIR/$L.diff"
    labels="$labels${labels:+,}$L"
    lab="{\"label\":$(rd_json_str "$L"),\"model\":$(rd_json_str "$om"),\"replay\":$(rd_json_str "$orid")}"
    jl="$jl${jl:+,}$lab"
  done < "$tmp/order"
  local line
  line="{\"experiment\":$(rd_json_str "$exp"),\"packet\":$(rd_json_str "$pkt"),\"ranking\":$(rd_json_str "$rkid"),\"dir\":$(rd_json_str "$rclone"),\"start\":$(rd_json_str "$start"),\"reviewer_model\":$(rd_json_str "$rmodel"),\"labels\":[$jl],\"prepared_at\":$(rd_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")}"
  printf '%s\n' "$line" > "$tmp/line.json"
  json_flat "$tmp/line.json" > /dev/null 2>&1 || die "rank-prepare: the label map could not be built as one JSON line"
  mkdir -p "$store" 2>/dev/null && printf '%s\n' "$line" >> "$store/labels.jsonl" \
    || die "rank-prepare: the label map could not be appended: $store/labels.jsonl"

  _CMP_RANK=""
  printf 'EXPERIMENT=%s\nPACKET=%s\nRANKING=%s\nDIR=%s\nBRANCH=%s\nSTART=%s\nBASE=%s\n' \
    "$exp" "$pkt" "$rkid" "$rclone" "$bname" "$start" "$base"
  for L in $(printf '%s' "$labels" | tr ',' ' '); do
    printf 'DIFF label=%s path=%s\n' "$L" "$rclone/$_CMP_RANK_DIR/$L.diff"
  done
  printf 'LABELS=%s\nLABELS_FILE=%s\n' "$labels" "$store/labels.jsonl"
}

# --- rank ------------------------------------------------------------------------------

# rank_prompt <dir> <labels-csv>: the ranking session's prompt. It names the
# diff files by label and no model: the reviewer's model is whatever routing.sh
# resolves in <dir>.
rank_prompt() {
  local L
  printf 'You are running one ranking step of a packet comparison. The harness that launched you is the loop driver; you do this one step and nothing else.\n\n'
  printf 'Dispatch the `reviewer` agent (the gaffer plugin'"'"'s agent of that name) exactly once. Set the dispatch'"'"'s model to what this command prints, and omit the model when it prints nothing; never choose a model yourself:\n\n'
  printf '    %s/scripts/routing.sh --root %s resolve reviewer\n\n' "$_CMP_HARNESS" "$1"
  printf 'Give the agent exactly this brief:\n\n'
  printf 'Rank these final diffs from best to worst. Each is an independent attempt at the same task, made from the commit this checkout holds; each is labelled with one letter:\n\n'
  for L in $(printf '%s' "$2" | tr ',' ' '); do
    printf '    %s  %s/%s/%s.diff\n' "$L" "$1" "$_CMP_RANK_DIR" "$L"
  done
  printf '\nJudge each diff as work under review: whether it does its task correctly and completely, its tests, and whether it stays in scope. The ranking is a strict order: every label exactly once, no ties, and a one-line reason for each label. Do not edit, commit or write anything. Return exactly this block, best first, and nothing after it:\n\n'
  printf 'RANKING\nRANK 1 <label> <one-line reason>\nRANK 2 <label> <one-line reason>\n...\n'
  printf '\nDo not edit, commit or run anything else yourself. When the agent returns, print its ranking block exactly as it returned it, the line RANKING first, as the last lines of your output, with nothing after it.\n'
}

# rank_parse <session-out> <labels-csv>: the ranking in the session's output (the
# lines after its last `RANKING` line), checked. Prints `<position>\t<label>\t
# <reason>` per line, best first, and returns 0 when it is a strict best-to-worst
# order of every label with a reason each; otherwise one `REFUSED rule=...` line
# per broken rule, and returns 1. The order is judged only when no other rule is
# broken, so a tie reads as a tie, not also as a gap in the order.
rank_parse() {
  LABELS="$2" awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { n = split(ENVIRON["LABELS"], lab, ","); for (i = 1; i <= n; i++) known[lab[i]] = 1 }
    { sub(/\r$/, ""); l[NR] = $0; if (trim($0) == "RANKING") start = NR }
    END {
      if (!start) { print "REFUSED rule=no-ranking"; exit 1 }
      k = 0; bad = 0
      for (i = start + 1; i <= NR; i++) {
        s = trim(l[i])
        if (s == "") continue
        ln = i - start
        if (!match(s, /^RANK[ \t]+[0-9]+/)) { printf "REFUSED rule=malformed-line line=%d\n", ln; bad = 1; continue }
        pos = substr(s, 1, RLENGTH); sub(/^RANK[ \t]+/, "", pos); pos += 0
        rest = substr(s, RLENGTH + 1)
        if (rest !~ /^[ \t]+[^ \t]/) { printf "REFUSED rule=malformed-line line=%d\n", ln; bad = 1; continue }
        rest = trim(rest)
        lb = rest; sub(/[ \t].*$/, "", lb)
        reason = trim(substr(rest, length(lb) + 1)); gsub(/\t/, " ", reason)
        if (!(lb in known)) { printf "REFUSED rule=unknown-label position=%d label=%s line=%d\n", pos, lb, ln; bad = 1 }
        if (reason == "") { printf "REFUSED rule=missing-reason position=%d label=%s line=%d\n", pos, lb, ln; bad = 1 }
        if (lb in seen) { printf "REFUSED rule=duplicate-label position=%d label=%s line=%d\n", pos, lb, ln; bad = 1 }
        seen[lb] = 1
        if (pos in taken) { printf "REFUSED rule=tie position=%d label=%s line=%d\n", pos, lb, ln; bad = 1 }
        taken[pos] = 1
        k++; P[k] = pos; B[k] = lb; R[k] = reason
      }
      if (k == 0 && !bad) { print "REFUSED rule=no-ranking"; exit 1 }
      for (i = 1; i <= n; i++) if (!(lab[i] in seen)) { printf "REFUSED rule=missing-label label=%s\n", lab[i]; bad = 1 }
      if (!bad) for (j = 1; j <= k; j++) if (P[j] != j) { printf "REFUSED rule=not-strict-order position=%d label=%s line=%d\n", P[j], B[j], j; bad = 1; break }
      if (bad) exit 1
      for (j = 1; j <= k; j++) printf "%d\t%s\t%s\n", P[j], B[j], R[j]
    }' "$1"
}

_cmp_rank_run_cleanup() {
  if [ -n "$_CMP_TMP" ]; then rm -rf "$_CMP_TMP"; fi
  return 0
}

cmd_rank() {
  [ $# -eq 2 ] || usage
  local exp="$1" pkt="$2"
  case "$exp" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "rank: not an experiment id (12 hex, as \`settings\` prints it): $exp" ;;
  esac
  case "$pkt" in ''|*[!A-Za-z0-9._-]*) die "rank: not a packet id: $pkt" ;; esac
  [ -x "$ROUTING" ] || die "rank: routing.sh is missing or not executable: $ROUTING" 2
  METRICS="$HERE/metrics.sh"
  [ -x "$METRICS" ] || die "rank: metrics.sh is missing or not executable: $METRICS" 2
  _CMP_CLAUDE="${ORCH_COMPARE_CLAUDE:-claude}"
  command -v "$_CMP_CLAUDE" >/dev/null 2>&1 || die "rank: no session command: $_CMP_CLAUDE (set ORCH_COMPARE_CLAUDE)" 2
  _CMP_TIMEOUT="${ORCH_COMPARE_STEP_TIMEOUT:-$_CMP_STEP_TIMEOUT_DEFAULT}"
  case "$_CMP_TIMEOUT" in ''|0|*[!0-9]*) die "rank: ORCH_COMPARE_STEP_TIMEOUT is not a positive number of seconds: $_CMP_TIMEOUT" 2 ;; esac
  _CMP_HARNESS="$(cd "$HERE/.." && pwd -P)"
  [ -x "$_CMP_HARNESS/scripts/compare-confine.sh" ] \
    || die "rank: compare-confine.sh is missing or not executable: $_CMP_HARNESS/scripts/compare-confine.sh" 2

  local store sel lfile rfile
  store="$(store_root)"
  sel="$store/$exp/selection.json"
  lfile="$store/labels.jsonl"
  rfile="$store/rankings.jsonl"
  [ -f "$sel" ] || die "rank: no stored selection for experiment $exp (run \`compare.sh select\` first): $sel"

  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "rank: cannot create a temp root"
  trap _cmp_rank_run_cleanup EXIT
  local tmp="$_CMP_TMP"

  # --- the selection: the reviewer model, its pinned id, the effort ------------------
  json_flat "$sel" > "$tmp/sel" || die "rank: the stored selection is not readable JSON: $sel"
  local sexp rmodel
  sexp="$(awk -F'\t' '$2 == ".experiment" { print $4; exit }' "$tmp/sel")"
  [ "$sexp" = "$exp" ] || die "rank: the stored selection names experiment [$sexp], not $exp: $sel"
  rmodel="$(awk -F'\t' '$2 == ".settings.reviewer_model" { print $4; exit }' "$tmp/sel")"
  # The source checkout, which the session's temp directory may not lie in (session_tmp).
  _CMP_SRC="$(awk -F'\t' '$2 == ".settings.source_repo" { print $4; exit }' "$tmp/sel")"
  case "$rmodel" in ''|*[!A-Za-z0-9._-]*) die "rank: the stored selection's reviewer model is malformed: [$rmodel]" ;; esac
  _RC_PINS="$tmp/pins"
  awk -F'\t' 'index($2, ".settings.model_ids.") == 1 && $3 == "s" && $4 != "" {
      print substr($2, length(".settings.model_ids.") + 1) "\t" $4 }' "$tmp/sel" > "$_RC_PINS"
  A="$rmodel" awk -F'\t' '$1 == ENVIRON["A"] { f = 1 } END { exit !f }' "$_RC_PINS" \
    || die "rank: experiment $exp's model_ids pins no id for the reviewer model $rmodel: $sel"
  _CMP_EFFORT="$(sel_effort < "$tmp/sel")"
  effort_is_level "$_CMP_EFFORT" \
    || die "rank: experiment $exp's stored settings name no effort in: ${EFFORT_LEVELS[*]} (got [$_CMP_EFFORT]): $sel"
  _RC_EFFORT="$_CMP_EFFORT"

  # --- the packet's latest prepared ranking: its labels only, never its models ------
  [ -f "$lfile" ] || die "rank: no prepared ranking for packet $pkt (run \`compare.sh rank-prepare\` first): $lfile"
  # The models are dropped as the map is read: nothing before the append can use them.
  json_flat "$lfile" | awk -F'\t' '$2 !~ /^\.labels\[[0-9]+\]\.model$/' > "$tmp/lmap" \
    || die "rank: the label map file is not readable JSONL: $lfile"
  local doc rkid rdir rstart lrev labels
  doc="$(E="$exp" P="$pkt" awk -F'\t' '
      $2 == ".experiment" && $3 == "s" { e[$1] = $4 }
      $2 == ".packet" && $3 == "s" { p[$1] = $4 }
      $1 + 0 > n { n = $1 + 0 }
      END { for (d = 1; d <= n; d++) if ((d in e) && e[d] == ENVIRON["E"] && (d in p) && p[d] == ENVIRON["P"]) last = d; print last }' "$tmp/lmap")"
  [ -n "$doc" ] || die "rank: no prepared ranking for packet $pkt in experiment $exp (run \`compare.sh rank-prepare\` first): $lfile"
  _lm() { D="$doc" K="$1" awk -F'\t' '$1 == ENVIRON["D"] && $2 == ENVIRON["K"] { print $4; exit }' "$tmp/lmap"; }
  rkid="$(_lm .ranking)"; rdir="$(_lm .dir)"; rstart="$(_lm .start)"; lrev="$(_lm .reviewer_model)"
  labels="$(D="$doc" awk -F'\t' '$1 == ENVIRON["D"] && $2 ~ /^\.labels\[[0-9]+\]\.label$/ { print $4 }' "$tmp/lmap" | paste -sd, -)"
  case "$rkid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "rank: the prepared ranking's id is malformed: [$rkid]" ;;
  esac
  case "$rstart" in ''|*[!0-9a-f]*) die "rank: ranking $rkid's start is not a commit id: [$rstart]" ;; esac
  [ "$lrev" = "$rmodel" ] || die "rank: ranking $rkid was prepared for reviewer [$lrev], not the selection's $rmodel"
  case ",$labels," in *,,*|*[!A-Z,]*) die "rank: ranking $rkid's labels are malformed: [$labels]" ;; esac
  if [ -f "$rfile" ]; then
    json_flat "$rfile" > "$tmp/ranks" || die "rank: the rankings file is not readable JSONL: $rfile"
    if R="$rkid" awk -F'\t' '$2 == ".ranking" && $4 == ENVIRON["R"] { f = 1 } END { exit !f }' "$tmp/ranks"; then
      die "rank: ranking $rkid is already recorded in $rfile (run \`compare.sh rank-prepare\` for a new one)"
    fi
  fi
  [ -n "$rdir" ] && git -C "$rdir" rev-parse --git-dir >/dev/null 2>&1 \
    || die "rank: ranking $rkid's clone is not a git repository: $rdir"
  # A ranking session may already have run in this clone (one that crashed or was
  # refused leaves it for a rerun), and this one will: every git command the
  # harness runs on it (routing.sh's, and metrics.sh's in the reviewer check) runs
  # with its command hooks off, recomputed once the session has ended.
  git_neutral "$rdir" \
    || die "rank: ranking $rkid's clone is not a repository of its own (or holds another repository inside it, or names a promisor remote), or its git command hooks cannot be neutralised: $rdir"
  local L r_rev
  for L in $(printf '%s' "$labels" | tr ',' ' '); do
    case "$L" in [A-Z]) ;; *) die "rank: ranking $rkid's label is not one letter: [$L]" ;; esac
    [ -f "$rdir/$_CMP_RANK_DIR/$L.diff" ] || die "rank: label $L has no diff in ranking $rkid's clone: $rdir/$_CMP_RANK_DIR/$L.diff"
  done
  r_rev="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$rdir" resolve reviewer 2>/dev/null | tr -d '\r')"
  [ "$r_rev" = "$rmodel" ] \
    || die "rank: routing.sh does not resolve ranking $rkid's reviewer as set (reviewer -> [$r_rev], wanted $rmodel)"

  # --- the one ranking session, at the experiment's effort --------------------------
  rank_prompt "$rdir" "$labels" > "$tmp/prompt"
  run_session "$rdir" "$tmp/prompt" "$tmp/out" "$tmp/err"
  if [ "$STEP_EXIT" = timeout ]; then
    printf 'REFUSED rule=session-timed-out\n' >&2
    die "rank: the ranking session outlived ${_CMP_TIMEOUT}s and was killed; nothing recorded"
  elif [ "$STEP_EXIT" != 0 ]; then
    printf 'REFUSED rule=session-crashed exit=%s\n' "$STEP_EXIT" >&2
    die "rank: the ranking session exited $STEP_EXIT; nothing recorded"
  fi
  git_neutral "$rdir" \
    || die "rank: ranking $rkid's clone is not a repository of its own (or holds another repository inside it, or names a promisor remote), or its git command hooks cannot be neutralised: $rdir"

  # --- the tool calls denied in the ranking session, read as `record` reads a replay's
  local den dcount dkinds dtools
  den="$(rd_session_denials "${ORCH_METRICS_PROJECTS_DIR:-$HOME/.claude/projects}" "$STEP_SESSION")"
  case "$(printf '%s\n' "$den" | cut -f1)" in
    measured)
      dcount="$(printf '%s\n' "$den" | cut -f2)"; dkinds="$(printf '%s\n' "$den" | cut -f3)"; dtools="$(printf '%s\n' "$den" | cut -f4)"
      case "$dcount" in ''|*[!0-9]*) die "rank: the denial count is not a count: [$dcount]" ;; esac
      if [ "$dcount" -gt 0 ]; then
        printf 'REFUSED rule=denied count=%s kinds=%s tools=%s\n' "$dcount" "$dkinds" "${dtools:-unrecorded}" >&2
        die "rank: ranking $rkid's session had $dcount tool call(s) denied ($dkinds; tools: ${dtools:-unrecorded}): a harness fault, not the reviewer's; nothing recorded"
      fi ;;
    *)
      printf 'REFUSED rule=denials-unmeasured\n' >&2
      die "rank: ranking $rkid's session was not shown to have no call denied (denials unmeasured: $(printf '%s\n' "$den" | cut -f2-)); nothing recorded" ;;
  esac

  # --- the result: a strict best-to-worst order of every label ----------------------
  if ! rank_parse "$tmp/out" "$labels" > "$tmp/rank"; then
    grep '^REFUSED ' "$tmp/rank" >&2
    die "rank: ranking $rkid's result breaks the rules above; nothing recorded"
  fi

  # --- the reviewer and effort checks on the ranking session -------------------------
  _RC_OUT=/dev/null; _RC_FAIL=0; _RC_NOTRUN=0
  rc_scope rank "$rdir" "$tmp/metrics.json" reviewer "$rmodel" 0 > "$tmp/checks"
  if [ "$_RC_FAIL" = 1 ] || [ "$_RC_NOTRUN" = 1 ]; then
    grep '^CHECK ' "$tmp/checks" >&2
    printf 'REFUSED rule=model-or-effort\n' >&2
    die "rank: ranking $rkid was not shown to run on the reviewer model $rmodel at effort $_CMP_EFFORT; nothing recorded"
  fi

  # --- the record: appended before any label is resolved ------------------------------
  local pos lab reason order="" line
  while IFS="$(printf '\t')" read -r pos lab reason; do
    order="$order${order:+,}{\"position\":$pos,\"label\":$(rd_json_str "$lab"),\"reason\":$(rd_json_str "$reason")}"
  done < "$tmp/rank"
  line="{\"experiment\":$(rd_json_str "$exp"),\"packet\":$(rd_json_str "$pkt"),\"ranking\":$(rd_json_str "$rkid"),\"dir\":$(rd_json_str "$rdir"),\"start\":$(rd_json_str "$rstart"),\"reviewer_model\":$(rd_json_str "$rmodel"),\"effort\":$(rd_json_str "$_CMP_EFFORT"),\"routing_check\":\"pass\",\"order\":[$order],\"ranked_at\":$(rd_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")}"
  printf '%s\n' "$line" > "$tmp/line.json"
  json_flat "$tmp/line.json" > /dev/null 2>&1 || die "rank: the ranking could not be built as one JSON line"
  mkdir -p "$store" 2>/dev/null && printf '%s\n' "$line" >> "$rfile" \
    || die "rank: the ranking could not be appended: $rfile"

  # --- only now: each label resolved to its model, from the stored map ---------------
  # The map is read again, whole, and the ranking's line found by its id.
  local om orid mdoc
  json_flat "$lfile" > "$tmp/lmodels" || die "rank: ranking $rkid is recorded in $rfile, but the label map file can no longer be read to resolve it: $lfile"
  mdoc="$(R="$rkid" awk -F'\t' '$2 == ".ranking" && $4 == ENVIRON["R"] { d = $1 } END { print d }' "$tmp/lmodels")"
  [ -n "$mdoc" ] || die "rank: ranking $rkid is recorded in $rfile, but its label map line is gone: $lfile"
  {
    printf 'EXPERIMENT=%s\nPACKET=%s\nRANKING=%s\nDIR=%s\nEFFORT=%s\nREVIEWER_MODEL=%s\n' \
      "$exp" "$pkt" "$rkid" "$rdir" "$_CMP_EFFORT" "$rmodel"
    grep '^CHECK ' "$tmp/checks"
    while IFS="$(printf '\t')" read -r pos lab reason; do
      printf 'RANK position=%s label=%s reason=%s\n' "$pos" "$lab" "$reason"
    done < "$tmp/rank"
    printf 'RECORDED=%s\n' "$rfile"
  } > "$tmp/stdout"
  while IFS="$(printf '\t')" read -r pos lab reason; do
    om="$(D="$mdoc" L="$lab" awk -F'\t' '
        $1 == ENVIRON["D"] && $2 ~ /^\.labels\[[0-9]+\]\.label$/ && $4 == ENVIRON["L"] { i = $2; sub(/\.label$/, "", i) }
        $1 == ENVIRON["D"] && $2 ~ /^\.labels\[[0-9]+\]\.model$/ { m[$2] = $4 }
        END { if (i != "") print m[i ".model"] }' "$tmp/lmodels")"
    orid="$(D="$mdoc" L="$lab" awk -F'\t' '
        $1 == ENVIRON["D"] && $2 ~ /^\.labels\[[0-9]+\]\.label$/ && $4 == ENVIRON["L"] { i = $2; sub(/\.label$/, "", i) }
        $1 == ENVIRON["D"] && $2 ~ /^\.labels\[[0-9]+\]\.replay$/ { r[$2] = $4 }
        END { if (i != "") print r[i ".replay"] }' "$tmp/lmodels")"
    printf 'RESOLVED position=%s label=%s model=%s replay=%s\n' "$pos" "$lab" "${om:-unresolved}" "${orid:-unresolved}" >> "$tmp/stdout"
  done < "$tmp/rank"
  printf 'RANKED=%s\n' "$rkid" >> "$tmp/stdout"
  cat "$tmp/stdout"
}

# --- report ------------------------------------------------------------------------

cmd_report() {
  [ $# -eq 1 ] || usage
  local exp="$1"
  case "$exp" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "report: not an experiment id (12 hex, as \`settings\` prints it): $exp" ;;
  esac
  local store sel
  store="$(store_root)"
  sel="$store/$exp/selection.json"
  [ -f "$sel" ] || die "report: no stored selection for experiment $exp (run \`compare.sh select\` first): $sel"

  local tmp
  tmp="$(mktemp -d 2>/dev/null)" || die "report: cannot create a temp root"
  # shellcheck disable=SC2064  # expand $tmp now: it is local to this function
  trap "rm -rf '$tmp'" EXIT

  json_flat "$sel" > "$tmp/sel" || die "report: the stored selection is not readable JSON: $sel"
  [ "$(awk -F'\t' '$2 == ".experiment" { print $4; exit }' "$tmp/sel")" = "$exp" ] \
    || die "report: the stored selection does not name experiment $exp: $sel"
  # The three stores, each read whole; an absent one holds nothing yet, an
  # unreadable one is refused rather than half-read.
  local name f
  for name in records rankings labels; do
    f="$store/$name.jsonl"
    : > "$tmp/$name"
    if [ -f "$f" ]; then
      json_flat "$f" > "$tmp/$name" || die "report: the $name file is not readable JSONL: $f"
    fi
  done
  # Every stored experiment's selection, this one's included, each flattened with
  # its experiment id as the first column: THE GROUP is read from their settings.
  # An unreadable one is refused rather than skipped, since skipping it could
  # drop a group member's records unseen.
  local x
  : > "$tmp/sels"
  while IFS= read -r f; do
    x="${f%/selection.json}"; x="${x##*/}"
    case "$x" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) continue ;;
    esac
    json_flat "$f" > "$tmp/one" || die "report: the stored selection is not readable JSON: $f"
    [ "$(awk -F'\t' '$2 == ".experiment" { print $4; exit }' "$tmp/one")" = "$x" ] \
      || die "report: the stored selection does not name experiment $x: $f"
    X="$x" awk -F'\t' 'BEGIN { OFS = "\t" } { $1 = ENVIRON["X"]; print }' "$tmp/one" >> "$tmp/sels" \
      || die "report: cannot read the stored selection: $f"
  done < <(find "$store" -mindepth 2 -maxdepth 2 -type f -name selection.json 2>/dev/null | LC_ALL=C sort)

  EXP="$exp" SELS="$tmp/sels" RECS="$tmp/records" RANKS="$tmp/rankings" LABELS="$tmp/labels" awk -F'\t' '
    function ix(path, pre,   s) { s = substr(path, length(pre) + 1); sub(/\].*$/, "", s); return s + 0 }
    function leaf(path,   s) { s = path; sub(/^.*\./, "", s); return s }
    function mean(s, n, fmt) { return n > 0 ? sprintf(fmt, s / n) : "unmeasured" }
    # agg <model> <classes>: the model'"'"'s cells over the space-separated classes,
    # pooled into the A* globals (sums and their n, never a mean of means). Its
    # rank is read from the one ranking set RSET only (0: none, so unmeasured):
    # ranks from different ranking sets are never averaged together.
    # Rs/Rn are read only through an `in` guard into a plain number (0 when
    # absent): GNU awk mishandles a never-assigned element passed to a
    # function and read again, printing garbage or aborting the render.
    function agg(m, cl,   n, k, a, rs, rn) {
      n = split(cl, a, " ")
      Asc = 0; Apa = 0; Ars = 0; Arn = 0; Atk = 0; Atn = 0; Alo = 0; Ahi = 0; Adn = 0
      for (k = 1; k <= n; k++) {
        rs = ((m, a[k], RSET) in Rs) ? Rs[m, a[k], RSET] + 0 : 0
        rn = ((m, a[k], RSET) in Rn) ? Rn[m, a[k], RSET] + 0 : 0
        Asc += Csc[m, a[k]]; Apa += Cpa[m, a[k]]; Ars += rs; Arn += rn
        Atk += Ctk[m, a[k]]; Atn += Ctn[m, a[k]]; Alo += Clo[m, a[k]]; Ahi += Chi[m, a[k]]; Adn += Cdn[m, a[k]]
      }
    }
    function fig(crit, m, cl) {
      agg(m, cl)
      if (crit == "pass") return sprintf("%.2f (%d passed, n=%d)", Apa / Asc, Apa, Asc)
      if (crit == "rank") return mean(Ars, Arn, "%.2f") " (n=" Arn ")"
      return (Adn > 0 ? sprintf("%.2f–%.2f", Alo / Adn, Ahi / Adn) : "unmeasured") " (n=" Adn ")"
    }
    # cite: the model'"'"'s figure over the classes and, over more than one, each
    # cell it is pooled from.
    function cite(crit, m, cl,   n, k, a, s) {
      s = m " " fig(crit, m, cl)
      n = split(cl, a, " ")
      if (n > 1) { s = s " from"; for (k = 1; k <= n; k++) s = s (k > 1 ? "," : "") " **" m ", " a[k] "** " fig(crit, m, a[k]) }
      return s
    }
    function scope(cl) { return (cl == "code prose" ? "over both classes" : "in " cl) }
    function signed(x, fmt,   s) { s = sprintf(fmt, x); if (s ~ /^-0(\.0*)?$/) s = substr(s, 2); return (s ~ /^-/ ? s : "+" s) }
    # THE PROPOSAL RULE, applied over <classes>: the highest pass rate, then the
    # lowest mean rank, then the lowest mean dollars (the midpoint of the mean
    # range), each deciding only among the models tied on every figure before
    # it. Sets DEC (the model) and DBY (the cited reason), or DEC="" and DWHY:
    # a figure the rule reaches that is unmeasured for a tied model stops it
    # (never read as 0), as does a tie on all three. Rank is read from the one
    # ranking set that ranked every tied model; none leaves it unmeasured, and
    # more than one stops the rule, since ranks from different ranking sets are
    # never averaged together.
    function decide(cl,   ci, crit, cn, i, nc, nk, bv, v, s, lead, um, t, all, ns, sl) {
      nc = 0; for (i = 1; i <= nm; i++) DC[++nc] = mod[i]
      lead = ""; RSET = 0
      for (ci = 1; ci <= 3; ci++) {
        crit = CRIT[ci]; um = ""; cn = CNAME[crit]
        if (crit == "rank") {
          ns = 0; sl = ""
          for (t = 1; t <= nset; t++) {
            all = 1; for (i = 1; i <= nc; i++) if (!((t, DC[i]) in SETHAS)) all = 0
            if (all) { ns++; RSET = t; sl = sl (sl == "" ? "" : ", ") SETNAME[t] }
          }
          if (ns > 1) { DEC = ""; DWHY = lead ", and the rule'"'"'s next figure, " cn ", comes from more than one ranking set ranking them together (" sl "), and ranks from different ranking sets are never averaged together"; return }
          if (ns == 0) RSET = 0
          else if (nset > 1) cn = cn " in ranking set " SETNAME[RSET]
        }
        for (i = 1; i <= nc; i++) {
          agg(DC[i], cl)
          if ((crit == "rank" && Arn == 0) || (crit == "dollars" && Adn == 0)) { um = um (um == "" ? "" : ", ") DC[i]; continue }
          v = (crit == "pass" ? -Apa / Asc : (crit == "rank" ? Ars / Arn : (Alo + Ahi) / (2 * Adn)))
          DV[i] = sprintf("%.6f", v) + 0
        }
        if (um != "") {
          DEC = ""; DWHY = lead ", and the rule'"'"'s next figure, " cn ", is unmeasured " scope(cl) " for " um
          if (crit == "rank" && RSET == 0 && nset > 0) DWHY = DWHY ": no one ranking set ranked them all together"
          return
        }
        bv = DV[1]; for (i = 2; i <= nc; i++) if (DV[i] < bv) bv = DV[i]
        nk = 0; for (i = 1; i <= nc; i++) if (DV[i] == bv) DK[++nk] = DC[i]
        if (nk == 1) {
          DEC = DK[1]; s = ""
          for (i = 1; i <= nc; i++) if (DC[i] != DEC) s = s (s == "" ? " over " : "; ") cite(crit, DC[i], cl)
          DBY = cn " " scope(cl) ": " cite(crit, DEC, cl) s (lead == "" ? "" : ", after " lead)
          return
        }
        s = ""; for (i = 1; i <= nk; i++) s = s (i > 1 ? " and " : "") cite(crit, DK[i], cl)
        lead = lead (lead == "" ? "" : "; then ") s " tied on " cn
        nc = nk; for (i = 1; i <= nk; i++) DC[i] = DK[i]
      }
      DEC = ""; DWHY = lead ", and the rule separates them no further"
    }
    # split_line <single> <code model> <prose model>: what routing each class to
    # its favoured model would change against the single value, pooled over both
    # classes. A cost figure unmeasured in any cell it needs reads unmeasured,
    # naming the cells.
    function split_line(W, A, B,   sp, ss, s, um, lo, hi, dn, tk, tn) {
      agg(W, "code prose")
      sp = Cpa[A, "code"] + Cpa[B, "prose"]; ss = Csc[A, "code"] + Csc[B, "prose"]
      s = sprintf("> A per-tier split (code: %s, prose: %s) against `%s: %s` for both: pass rate %.2f (%d passed, n=%d) against %.2f (%d passed, n=%d), difference %s", \
        A, B, role, W, sp / ss, sp, ss, Apa / Asc, Apa, Asc, signed(sp / ss - Apa / Asc, "%.2f"))
      um = ""
      if (Cdn[A, "code"] == 0) um = um ", **" A ", code**"
      if (Cdn[B, "prose"] == 0) um = um ", **" B ", prose**"
      if (Cdn[W, "code"] == 0) um = um ", **" W ", code**"
      if (Cdn[W, "prose"] == 0) um = um ", **" W ", prose**"
      if (um != "") s = s " · dollars unmeasured (no measured dollars in " substr(um, 3) ")"
      else {
        lo = Clo[A, "code"] + Clo[B, "prose"]; hi = Chi[A, "code"] + Chi[B, "prose"]; dn = Cdn[A, "code"] + Cdn[B, "prose"]
        s = s sprintf(" · dollars %.2f–%.2f (n=%d) against %.2f–%.2f (n=%d) per replay, difference %s min, %s max", \
          lo / dn, hi / dn, dn, Alo / Adn, Ahi / Adn, Adn, signed(lo / dn - Alo / Adn, "%.2f"), signed(hi / dn - Ahi / Adn, "%.2f"))
      }
      um = ""
      if (Ctn[A, "code"] == 0) um = um ", **" A ", code**"
      if (Ctn[B, "prose"] == 0) um = um ", **" B ", prose**"
      if (Ctn[W, "code"] == 0) um = um ", **" W ", code**"
      if (Ctn[W, "prose"] == 0) um = um ", **" W ", prose**"
      if (um != "") s = s " · tokens unmeasured (no measured tokens in " substr(um, 3) ")"
      else {
        tk = Ctk[A, "code"] + Ctk[B, "prose"]; tn = Ctn[A, "code"] + Ctn[B, "prose"]
        s = s sprintf(" · tokens %.0f (n=%d) against %.0f (n=%d) per replay, difference %s", tk / tn, tn, Atk / Atn, Atn, signed(tk / tn - Atk / Atn, "%.0f"))
      }
      return s
    }
    BEGIN { split("pass rank dollars", CRIT, " "); CNAME["pass"] = "pass rate"; CNAME["rank"] = "mean rank"; CNAME["dollars"] = "mean dollars" }
    # Every stored selection, keyed by its experiment id (the first column).
    FILENAME == ENVIRON["SELS"] {
      x = $1
      if (!(x in XSEEN)) { XSEEN[x] = 1; XL[++nx] = x }
      if ($2 == ".settings.role" && $3 == "s") Xrole[x] = $4
      else if ($2 == ".settings.reviewer_model" && $3 == "s") Xrev[x] = $4
      else if ($2 == ".settings.source_repo" && $3 == "s") Xsrc[x] = $4
      else if ($2 == ".settings.effort" && $3 == "s") Xeff[x] = $4
      else if ($2 ~ /^\.settings\.models\[[0-9]+\]$/ && $3 == "s") { Xnm[x]++; Xmod[x, Xnm[x]] = $4; XHAS[x, $4] = 1 }
      else if ($2 ~ /^\.selected\[[0-9]+\]\.(packet|class|title|handoff)$/) {
        i = ix($2, ".selected["); XS[x, i, leaf($2)] = $4; if (i + 1 > Xnp[x]) Xnp[x] = i + 1
      }
      next
    }
    FILENAME == ENVIRON["RECS"] {
      d = $1 + 0; if (d > nr) nr = d
      if ($2 == ".experiment" && $3 == "s") re[d] = $4
      else if ($2 == ".packet" && $3 == "s") rp[d] = $4
      else if ($2 == ".model" && $3 == "s") rmod[d] = $4
      else if ($2 == ".outcome" && $3 == "s") ro[d] = $4
      else if ($2 == ".invalid_cause" && $3 == "s") rc[d] = $4
      else if ($2 ~ /^\.denial_kinds\[[0-9]+\]$/ && $3 == "s") { v = $4; gsub(/[^A-Za-z0-9._-]/, "?", v); rk[d] = rk[d] (rk[d] == "" ? "" : ",") v }
      else if ($2 ~ /^\.denial_tools\[[0-9]+\]$/ && $3 == "s") { v = $4; gsub(/[^A-Za-z0-9._-]/, "?", v); rtl[d] = rtl[d] (rtl[d] == "" ? "" : ",") v }
      else if ($2 == ".denials" && $3 == "n" && $4 ~ /^[0-9]+$/) rdn[d] = $4 + 0
      else if ($2 == ".fix_rounds" && $3 == "n" && $4 ~ /^[0-9]+$/) rf[d] = $4 + 0
      else if ($2 ~ /^\.tokens\.(input|output|cache_creation|cache_read)$/ && $3 == "n" && $4 ~ /^[0-9]+$/) { rt[d] += $4; rtn[d]++ }
      else if ($2 == ".dollars_min" && $3 == "n" && $4 ~ /^[0-9]+(\.[0-9]+)?$/) rdl[d] = $4 + 0
      else if ($2 == ".dollars_max" && $3 == "n" && $4 ~ /^[0-9]+(\.[0-9]+)?$/) rdh[d] = $4 + 0
      next
    }
    FILENAME == ENVIRON["RANKS"] {
      d = $1 + 0; if (d > nk) nk = d
      if ($2 == ".experiment" && $3 == "s") ke[d] = $4
      else if ($2 == ".packet" && $3 == "s") kp[d] = $4
      else if ($2 == ".ranking" && $3 == "s") kr[d] = $4
      else if ($2 ~ /^\.order\[[0-9]+\]\.(position|label)$/) {
        i = ix($2, ".order["); KO[d, i, leaf($2)] = $4; if (i + 1 > ko[d]) ko[d] = i + 1
      }
      next
    }
    FILENAME == ENVIRON["LABELS"] {
      d = $1 + 0; if (d > nl) nl = d
      if ($2 == ".ranking" && $3 == "s") lr[d] = $4
      else if ($2 ~ /^\.labels\[[0-9]+\]\.(label|model)$/) {
        i = ix($2, ".labels["); LB[d, i, leaf($2)] = $4; if (i + 1 > lbn[d]) lbn[d] = i + 1
      }
      next
    }
    END {
      E = ENVIRON["EXP"]
      # THE GROUP: every stored experiment whose settings name the same varied
      # role, reviewer model and source repository as this one, this one first,
      # then the rest in id order. Cells pool the group'"'"'s records and never
      # anything outside it; an experiment missing any of the three is alone.
      role = Xrole[E]; rev = Xrev[E]; src = Xsrc[E]
      ng = 1; G[1] = E; ING[E] = 1
      for (k = 1; k <= nx; k++) {
        x = XL[k]
        if (x == E || role == "" || rev == "" || src == "") continue
        if (Xrole[x] == role && Xrev[x] == rev && Xsrc[x] == src) { G[++ng] = x; ING[x] = 1 }
      }
      # The group'"'"'s models, in its experiments'"'"' order, and its selected packets,
      # one per experiment and packet (a packet two experiments selected is two).
      nm = 0; np = 0
      for (g = 1; g <= ng; g++) {
        x = G[g]
        for (k = 1; k <= Xnm[x]; k++) if (!(Xmod[x, k] in INM)) { INM[Xmod[x, k]] = 1; mod[++nm] = Xmod[x, k] }
        for (j = 0; j < Xnp[x]; j++) {
          Sx[np] = x
          S[np, "packet"] = XS[x, j, "packet"]; S[np, "class"] = XS[x, j, "class"]
          S[np, "title"] = XS[x, j, "title"]; S[np, "handoff"] = XS[x, j, "handoff"]
          np++
        }
      }
      # THE LATEST-RECORD RULE: the last record naming the experiment, packet and model.
      for (d = 1; d <= nr; d++) if ((d in re) && (re[d] in ING) && (d in rp) && (d in rmod)) latest[re[d], rp[d], rmod[d]] = d
      # A packet'"'"'s ranking is its last recorded one in its experiment; its labels
      # resolve through the label map line carrying the same ranking id. Its
      # RANKING SET is the models it ranked together, in the group'"'"'s model
      # order; ranks are averaged only within one set.
      for (d = 1; d <= nk; d++) if ((d in ke) && (ke[d] in ING) && (d in kp) && (d in kr)) lastrank[ke[d], kp[d]] = d
      for (d = 1; d <= nl; d++) if (d in lr) lmap[lr[d]] = d
      unranked = 0; nset = 0
      for (j = 0; j < np; j++) {
        x = Sx[j]; p = S[j, "packet"]
        if (!((x, p) in lastrank)) { why[j] = "no ranking recorded"; unranked++; continue }
        d = lastrank[x, p]
        if (!(kr[d] in lmap)) { why[j] = "its ranking " kr[d] " has no label map line"; unranked++; continue }
        ld = lmap[kr[d]]; good = (ko[d] > 0)
        for (i = 0; i < ko[d]; i++) {
          mm[i] = ""
          for (k = 0; k < lbn[ld]; k++) if (LB[ld, k, "label"] == KO[d, i, "label"]) mm[i] = LB[ld, k, "model"]
          if (mm[i] == "" || !(mm[i] in INM) || KO[d, i, "position"] !~ /^[0-9]+$/) good = 0
        }
        if (!good) { why[j] = "its ranking " kr[d] " does not resolve to models"; unranked++; continue }
        for (i = 0; i < ko[d]; i++) { rankpos[j, mm[i]] = KO[d, i, "position"] + 0; inrk[j, mm[i]] = 1 }
        sk = ""; for (i = 1; i <= nm; i++) if ((j, mod[i]) in inrk) sk = sk (sk == "" ? "" : ", ") mod[i]
        sk = "{" sk "}"
        if (!(sk in SETIX)) {
          SETIX[sk] = ++nset; SETNAME[nset] = sk
          for (i = 1; i <= nm; i++) if ((j, mod[i]) in inrk) SETHAS[nset, mod[i]] = 1
        }
        kset[j] = SETIX[sk]
      }

      ml = ""; for (i = 1; i <= nm; i++) ml = ml (i > 1 ? ", " : "") mod[i]
      el = ""; gl = ""
      for (g = 1; g <= ng; g++) {
        x = G[g]; e = (Xeff[x] == "" ? "unrecorded" : Xeff[x])
        if (index(", " el ", ", ", " e ", ") == 0) el = el (el == "" ? "" : ", ") e
        s = ""; for (k = 1; k <= Xnm[x]; k++) s = s (k > 1 ? ", " : "") Xmod[x, k]
        gl = gl (g == 1 ? "" : (g == ng ? " and " : ", ")) "`" x "` (" s ", effort " e ")"
      }
      printf "**Model comparison** (experiment `%s`)\n", E
      printf "> Varied role: %s, across %s\n", role, ml
      printf "> Reviewer: %s, at effort %s\n", rev, el
      printf "> Source repository: %s\n", (src == "" ? "unrecorded" : src)
      printf "> Group: every stored experiment with this varied role, reviewer model and source repository, %d: %s. No cell pools records from outside it.\n", ng, gl
      printf "> Pass rate is passed over replays not invalid. Fix rounds are over passed replays. Rank is 1 for best, over ranked packets. Tokens and dollars are means over replays not invalid with a measured figure. n is what each figure is over.\n"

      printf "\n**Cells**\n"
      split("code prose", cls, " ")
      for (mi = 1; mi <= nm; mi++) for (ci = 1; ci <= 2; ci++) {
        m = mod[mi]; c = cls[ci]
        npk = 0; rec = 0; inval = 0; scored = 0; passed = 0
        frs = 0; frn = 0; tks = 0; tkn = 0; lo = 0; hi = 0; dn = 0
        for (j = 0; j < np; j++) {
          if (S[j, "class"] != c || !((Sx[j], m) in XHAS)) continue
          p = S[j, "packet"]; npk++
          if ((j, m) in rankpos) { Rs[m, c, kset[j]] += rankpos[j, m]; Rn[m, c, kset[j]]++ }
          if (!((Sx[j], p, m) in latest)) continue
          d = latest[Sx[j], p, m]; rec++
          if (ro[d] == "invalid") {
            inval++
            # A denial-invalid replay, counted per model beside the cells; its
            # kinds and tools are the record'"'"'s, or unrecorded when it stores none.
            if (rc[d] == "denial") {
              DNn[m]++
              if (rk[d] == "") DNu[m]++
              else {
                nkd = split(rk[d], kd, ",")
                for (t = 1; t <= nkd; t++) if (!((m, kd[t]) in DNseen)) { DNseen[m, kd[t]] = 1; DNk[m] = DNk[m] (DNk[m] == "" ? "" : ", ") kd[t] }
              }
              if (rtl[d] == "") DNtu[m]++
              else {
                nkd = split(rtl[d], kd, ",")
                for (t = 1; t <= nkd; t++) if (!((m, kd[t]) in DNtseen)) { DNtseen[m, kd[t]] = 1; DNt[m] = DNt[m] (DNt[m] == "" ? "" : ", ") kd[t] }
              }
            } else if (rdn[d] > 0) {
              # An earlier cause decided it, but its record counts calls denied
              # too: counted apart, naming the causes, the kinds and the tools.
              ECn[m]++
              cz = (rc[d] == "" ? "unrecorded" : rc[d])
              if (!((m, cz) in ECcseen)) { ECcseen[m, cz] = 1; ECc[m] = ECc[m] (ECc[m] == "" ? "" : ", ") cz }
              nkd = split((rk[d] == "" ? "unrecorded" : rk[d]), kd, ",")
              for (t = 1; t <= nkd; t++) if (!((m, kd[t]) in ECkseen)) { ECkseen[m, kd[t]] = 1; ECk[m] = ECk[m] (ECk[m] == "" ? "" : ", ") kd[t] }
              nkd = split((rtl[d] == "" ? "unrecorded" : rtl[d]), kd, ",")
              for (t = 1; t <= nkd; t++) if (!((m, kd[t]) in ECtseen)) { ECtseen[m, kd[t]] = 1; ECt[m] = ECt[m] (ECt[m] == "" ? "" : ", ") kd[t] }
            }
            continue
          }
          scored++
          if (ro[d] == "passed") { passed++; if (d in rf) { frs += rf[d]; frn++ } }
          if (rtn[d] == 4) { tks += rt[d]; tkn++ }
          if ((d in rdl) && (d in rdh)) { lo += rdl[d]; hi += rdh[d]; dn++ }
        }
        Csc[m, c] = scored; Cpa[m, c] = passed
        Ctk[m, c] = tks; Ctn[m, c] = tkn; Clo[m, c] = lo; Chi[m, c] = hi; Cdn[m, c] = dn
        if (scored == 0) {
          if (npk == 0) r = "no " c " packet is selected"
          else r = rec " of " npk " " c " packet(s) recorded, " inval " invalid"
          printf "> ⚠️ **%s, %s** — unmeasured: no scored replay (%s)\n", m, c, r
          unm = unm (unm == "" ? "" : ", ") "**" m ", " c "**"
          continue
        }
        printf "> **%s, %s** — pass rate %.2f (%d passed, n=%d%s)", m, c, passed / scored, passed, scored, \
          (inval > 0 ? "; " inval " invalid excluded" : "")
        printf " · fix rounds %s (n=%d)", mean(frs, frn, "%.2f"), frn
        # Rank: over the group'"'"'s one ranking set, or, when it has more than one,
        # per set that ranked this model, each named, never averaged together.
        # Rs/Rn go through an `in` guard into plain numbers first (see agg).
        if (nset <= 1) {
          rs = ((m, c, 1) in Rs) ? Rs[m, c, 1] + 0 : 0
          rn = ((m, c, 1) in Rn) ? Rn[m, c, 1] + 0 : 0
          printf " · rank %s (n=%d)", mean(rs, rn, "%.2f"), rn
        } else {
          r = ""
          for (t = 1; t <= nset; t++) if ((t, m) in SETHAS) {
            rs = ((m, c, t) in Rs) ? Rs[m, c, t] + 0 : 0
            rn = ((m, c, t) in Rn) ? Rn[m, c, t] + 0 : 0
            r = r (r == "" ? "" : "; ") mean(rs, rn, "%.2f") " (n=" rn ") in ranking set " SETNAME[t]
          }
          printf " · rank %s", (r == "" ? "unmeasured (n=0)" : r)
        }
        printf " · tokens %s (n=%d)", mean(tks, tkn, "%.0f"), tkn
        printf " · dollars %s (n=%d)\n", (dn > 0 ? sprintf("%.2f–%.2f", lo / dn, hi / dn) : "unmeasured"), dn
      }
      # Per model, the latest replays invalid for a denial, over both classes: a
      # count beside the cells (each already excludes them), changing no figure.
      # A model with none prints no line.
      for (mi = 1; mi <= nm; mi++) {
        m = mod[mi]
        if (DNn[m] == 0) continue
        r = DNk[m]
        if (DNu[m] > 0) r = r (r == "" ? "" : "; ") "kinds unrecorded for " DNu[m]
        tl = (DNt[m] == "" ? "" : "tools: " DNt[m])
        if (DNtu[m] > 0) tl = tl (tl == "" ? "" : "; ") "tools unrecorded for " DNtu[m]
        printf "> ⚠️ **%s** — %d replay(s) invalid for a denial (denied: %s; %s), excluded from its cells as a harness fault\n", m, DNn[m], r, tl
      }
      # Per model, the latest replays invalid for an earlier cause whose record
      # also counts denials above 0: the cause is not a denial, but a rerun
      # would meet the same denial. A count beside the cells, changing no figure.
      for (mi = 1; mi <= nm; mi++) {
        m = mod[mi]
        if (ECn[m] == 0) continue
        printf "> ⚠️ **%s** — %d replay(s) invalid for another cause (%s) that also had a call denied (denied: %s; tools: %s), excluded from its cells as a harness fault; a rerun would meet the same denial\n", m, ECn[m], ECc[m], ECk[m], ECt[m]
      }

      printf "\n**Packets**\n"
      for (j = 0; j < np; j++) {
        p = S[j, "packet"]
        printf "> **%s** (`%s`) — %s, handoff %s, %s%s\n", S[j, "title"], p, S[j, "class"], \
          (S[j, "handoff"] == "" ? "unrecorded" : S[j, "handoff"]), ((j in why) ? "unranked: " why[j] : "ranked"), \
          (ng > 1 ? ", in experiment `" Sx[j] "`" : "")
      }

      printf "\n**Ranking**\n"
      printf "> %s%d of %d packet(s) unranked\n", (unranked > 0 ? "⚠️ " : ""), unranked, np
      if (nset > 1) {
        s = ""; for (t = 1; t <= nset; t++) s = s (t > 1 ? ", " : "") SETNAME[t]
        printf "> %d ranking sets: %s. A rank is averaged only within the set that ranked those models together, never across sets.\n", nset, s
      }

      # The proposal: computed by THE PROPOSAL RULE, never written by a model,
      # and text only: nothing here writes routing configuration.
      printf "\n**Proposal**\n"
      printf "> The rule: the highest pass rate over both classes, then the lowest mean rank, then the lowest mean dollars (the midpoint of the range). A class favours a model by the same rule inside it.\n"
      if (unm != "") { printf "> ⚠️ No change proposed: unmeasured cells %s\n", unm; exit 0 }
      decide("code prose")
      if (DEC == "") { printf "> ⚠️ No change proposed: %s\n", DWHY; exit 0 }
      W = DEC
      printf "> 🔀 Proposed `model_routing` entry: `%s: %s`, for you to apply by hand or not. This report changes no routing configuration.\n", role, W
      printf "> Decided by %s\n", DBY
      decide("code"); FC = DEC; FCBY = DBY; FCWHY = DWHY
      decide("prose"); FP = DEC; FPBY = DBY; FPWHY = DWHY
      if (FC != "" && FC == FP && FC == W) { printf "> The code and prose cells agree: each favours %s\n", FC; exit 0 }
      # Both classes can favour one model while the pooled rule picks another
      # (uneven n across the classes): never claim agreement with the proposal.
      if (FC != "" && FC == FP) printf "> ⚠️ Both classes favour %s, but pooled over both the rule picks %s\n", FC, W
      else if (FC != "" && FP != "") printf "> ⚠️ The code and prose cells favour different models\n"
      if (FC != "") printf "> Code favours %s, by %s\n", FC, FCBY
      else printf "> ⚠️ The code cells favour no single model: %s\n", FCWHY
      if (FP != "") printf "> Prose favours %s, by %s\n", FP, FPBY
      else printf "> ⚠️ The prose cells favour no single model: %s\n", FPWHY
      if (FC != "" && FP != "") print split_line(W, FC, FP)
    }' "$tmp/sels" "$tmp/records" "$tmp/rankings" "$tmp/labels" > "$tmp/out" \
    || die "report: the report could not be rendered"
  cat "$tmp/out"
}

[ $# -ge 1 ] || usage
SUB="$1"; shift
case "$SUB" in
  settings)   cmd_settings "$@" ;;
  candidates) cmd_candidates "$@" ;;
  select)     cmd_select "$@" ;;
  estimate)   cmd_estimate "$@" ;;
  prepare)    cmd_prepare "$@" ;;
  review-view) cmd_review_view "$@" ;;
  replay)     cmd_replay "$@" ;;
  routing-check) cmd_routing_check "$@" ;;
  sweeps)     cmd_sweeps "$@" ;;
  record)     cmd_record "$@" ;;
  run)        cmd_run "$@" ;;
  rank-prepare) cmd_rank_prepare "$@" ;;
  rank)       cmd_rank "$@" ;;
  report)     cmd_report "$@" ;;
  *) usage ;;
esac
exit 0
