#!/usr/bin/env bash
# =============================================================================
# gspec-backlog.sh — THE gspec adapter (ADR 0020 D2)
# =============================================================================
# The ONE place this plugin reads gspec. Every other component (run-loop §2,
# resume, new-project) goes through here, so a
# gspec format change is one file to fix rather than seven skills and two agents.
# That is the whole point: the 2026-08 breakage was not caused by gspec moving
# `features/<slug>.plan.md` to `tasks/<slug>.md` — it was caused by nothing
# checking, in seven places at once.
#
# THE CONSUMED CONTRACT (ADR 0020 D2) — nothing outside this list is read:
#   <plan>                     the execution backlog. Frontmatter `spec-version`
#                              + `feature`; task lines
#                              `- [ ] **T<n>** [P] **P<n>** <text>` with indented
#                              `- deps:` / `- covers:` / `- supersedes:` / `- arch:`
#                              and an OPTIONAL `- files:` (forward-compat with
#                              upstream proposal U1 — gspec does not emit it today).
#                              WRITTEN as well as read (ADR 0025 D1): `check-task`
#                              flips ONE task line's `[ ]` to `[x]` and nothing
#                              else — never the text, never any other line. This
#                              is the plan file's only write; it records that a
#                              unit of work executed, not what to build (ADR 0020 D2).
#   <prd>                      the PRD. Capability lines
#                              `- [ ] **P<n>**: <text>`; completion is DERIVED
#                              from them (ADR 0020 D2 — never stored). Optional
#                              frontmatter `depends_on:` (forward-compat with U5).
#                              A capability's indented acceptance-criteria
#                              sub-bullets (`  - <criterion>`, verbatim, a
#                              wrapped multi-line one included whole) are ALSO
#                              consumed — the D2 amendment (2026-09-15) that
#                              widened this contract for `handoff` below, the
#                              ONE reader of them (`_prd_capability`).
#                              ALSO WRITTEN, since capability-auto-complete-t1:
#                              `complete-capabilities` flips a capability's own
#                              `[ ]` to `[x]` once its covering tasks are all
#                              checked, in the same read-only-lookup-then-`sub()`
#                              shape as `check-task` — never the text, never a
#                              checked box unflipped. Completion stays DERIVED,
#                              never a second stored flag: this write only ever
#                              makes the checkbox agree with what the plan
#                              already showed to be true.
#                              `runstate.sh` still never reads gspec/.
#
# ...where <plan> and <prd> are LAYOUT-DEPENDENT and resolved in exactly one
# place each — `_resolve_plan_path` / `_resolve_prd_path`, enumerated by
# `_plan_paths` / `_prd_paths`. See LAYOUTS below.
#   .agents/roadmap.yaml       PLUGIN-OWNED sequencing (order/why, interim
#                              depends_on, and `deferred` — a human "not now",
#                              which is NOT the derived `status` D2 prohibits;
#                              see _roadmap_rows). An OVERRIDE, never a prerequisite.
#   .agents/task-files.yaml    PLUGIN-OWNED file scope per task (ADR 0020 U1-local).
#                              gspec task lines carry no file scope, so this is
#                              where `allowed_files` comes from until (or unless)
#                              upstream U1-up lands. FINGERPRINT-GUARDED — see below.
#   .gspec/build/status.json   read ONLY by `interlock`, and FAIL-SOFT: it sits
#                              outside the pinned contract, so an unreadable or
#                              unknown-shaped file must never block the loop.
#
# VERSION PIN (ADR 0020 D3). gspec does not stamp its package version into a
# project (`.gspec/config.json` holds only the install target + models map), so
# the pin has two axes: the TOOL pin below (what new-project installs) and the
# ARTIFACT pin (`spec-version` in the specs), asserted by `check`. The artifact
# pin is the one that actually protects the loop.
#
# Subcommands:
#   pin                      print the pinned gspec version + supported spec-versions.
#   check [root]             assert the artifact pin across gspec specs. Prints
#                            CHECK=ok, or CHECK=fail + one FAIL= line per offender.
#                            Exit 3 on a version mismatch; 0 when clean or when no
#                            gspec project is present (gspec is OPTIONAL — D4).
#   features [root]          TSV, one feature per line, order asc then slug asc:
#                              <slug>\t<order>\t<done>\t<blocked>\t<depends_on>\t<why>\t<deferred>
#                            done/blocked/deferred are 1/0. depends_on is
#                            '|'-separated. `deferred` is LAST so every existing
#                            column index keeps its meaning.
#   next [root]              print NEXT=<slug> (lowest order among
#                            unblocked-and-incomplete-and-not-deferred) or
#                            NEXT=none, plus REASON= distinguishing blocked from
#                            deferred from complete.
#   plans [root]             TSV, one plan file per line, sorted by slug:
#                              <slug>\t<relpath>\t<layout>\t<tasks>\t<unchecked>
#                            layout is `3.x` | `2.x` | `pre-2.0` (see LAYOUTS).
#                            <tasks> counts the task lines this adapter actually
#                            RECOGNIZES (all three shapes), which is the only
#                            signal that separates a FINISHED plan from an
#                            UNREADABLE one -- both yield zero packets, and
#                            conflating them is how a migration reports success
#                            over a backlog nothing can read. tasks>0 with
#                            unchecked=0 is complete; tasks=0 is the failure.
#                            Exists so /gaffer:migrate can report and verify which
#                            layout a repo is in WITHOUT globbing gspec/ itself —
#                            migrate.sh's standing rule is that every gspec read
#                            goes through this adapter, and a layout census is a
#                            gspec read like any other. Prints nothing when there
#                            is no gspec project (D4).
#   nodes <slug> [root]      emit a packet NODES TSV for one feature's UNCHECKED
#                            tasks — one row per packet (id, feature, files,
#                            consumes, produces, feature deps), read directly by
#                            the loop for ordering and file scope. (Formerly also
#                            fed to `packet-graph.sh build`, the parallel-mode
#                            scheduler retired in retire-unused-loop-modes T2.)
#   nodes-all [root]         the same for every incomplete, unblocked feature.
#   interlock [root]         INTERLOCK=clear|busy|unknown — is a `gspec build`
#                            driving this repo right now? (ADR 0020 D5.)
#   files-status [root]      audit `.agents/task-files.yaml` against the live plans:
#                            one `<state> <task>` line per entry
#                            (ok|stale|unfingerprinted|done|orphan) + a summary.
#   check-task <task> [root] the adapter's ONE write (ADR 0025 D1): flip a single
#                            task's checkbox from `[ ]` to `[x]` in
#                            gspec/tasks/<slug>.md, and touch nothing else — not
#                            the task text, not any other line. `<task>` accepts
#                            either `<feature>#T<n>` or the packet-id form
#                            `<feature>-t<n>` the loop actually holds at packet
#                            close. Idempotent (CHECKED=already); every "gspec is
#                            optional" case exits 0; a task id absent from an
#                            EXISTING plan is genuine drift and exits 4.
#   task-status <id[,id...]> [root]   READ-ONLY (run-state-cleanup T2): for each
#                            packet id, one `<id>\t<state>\t<task-ref-or-reason>`
#                            line, state one of finished|unchecked|gone|unknown,
#                            then one trailing `FINISHED=<comma-sep ids>` line fed
#                            VERBATIM to `runstate.sh findings --stale --finished`.
#                            `gone` (loop-measurement T2) is DISTINCT from
#                            `unknown`: it means the id's feature plan exists,
#                            PARSES (at least one task line this adapter
#                            recognizes -- see `_plan_task_line_count`, counted
#                            with the SAME regex `_task_lookup` matches against,
#                            never a second pattern), unambiguously resolved to
#                            that plan, no longer names that task, AND the id
#                            can be confirmed via `_task_history_probe` to have
#                            been a task line in that plan's git history at
#                            some earlier commit -- positive evidence the task
#                            was re-decomposed away, which `sweep-open --gone`
#                            (T3) records as `abandoned`. That history check is
#                            the last gate, not a replacement for the ones
#                            before it: a plan-id collision alone is not
#                            enough, because a NON-gspec packet id can happen
#                            to prefix-match a live feature's slug
#                            (`ts-fix-login-bug` against feature `ts`) without
#                            ever having been a task there -- without positive
#                            evidence that id reads `unknown`, never `gone`.
#                            `unknown` stays every case with no such positive
#                            evidence: no gspec/, unresolvable id, no plan file
#                            at all, a plan file with ZERO parseable task lines
#                            (empty, truncated, or a format this adapter cannot
#                            read -- an unreadable plan must never be reported
#                            as "yes, that task is gone"), an AMBIGUOUS
#                            packet-id resolution (the `<feature>-<id>`
#                            collision documented at `_resolve_task_id` --
#                            longest-slug-wins is safe for check-task, which
#                            only ever gets a loud not-found, but the same
#                            guess reported here as `gone` would silently claim
#                            a live task in the OTHER matching feature was
#                            abandoned, so an ambiguous resolution can only
#                            ever read `unknown` here, never `gone`), the id
#                            never appearing in the plan's git history (it was
#                            never a gspec task here), or that history being
#                            UNAVAILABLE (not a git repo, git missing, the plan
#                            file untracked, or a shallow clone whose "not
#                            found" could be truncated rather than genuine) --
#                            `sweep-open` records `unknown` as `interrupted`,
#                            the safe direction when absence of evidence is not
#                            evidence of absence. `gone` is excluded from
#                            `FINISHED=`, same as `unchecked` and `unknown`.
#                            Accepts the same two id forms as check-task and
#                            resolves them via the SAME shared function
#                            (`_resolve_task_id`) so the two can never drift.
#                            Every "gspec is optional" case reads `unknown`,
#                            mirroring check-task's `CHECKED=none`; exit 0 for all
#                            of them, non-zero only for a genuine usage error (no
#                            ids, an unreadable root, or the REFUSED path shared
#                            with check-task).
#   handoff <packet-id[,packet-id...]> [root]   print everything an agent
#                            needs to start a packet: the task text; its file
#                            scope, resolved by calling `_nodes_for` and
#                            reading its row for this packet id — the SAME
#                            precedence `nodes` uses (plan `files:` >
#                            fingerprint-matched sidecar > empty), never a
#                            second copy of it; each `covers:` capability
#                            (split on the `' · '` separator) with that
#                            capability's PRD acceptance-criteria sub-bullets
#                            verbatim (ADR 0020's D2 amendment); and the PRD
#                            and `arch.md` paths — `ARCH=` is always printed,
#                            as `absent` when there is no arch.md, so a caller
#                            never has to guess whether the line was omitted
#                            or forgotten. A `covers:` quote matching no PRD
#                            capability prints `UNMATCHED=<quote>`, never
#                            guessed. `<packet-id>` accepts the same two forms
#                            as check-task/task-status, resolved by the SAME
#                            `_resolve_task_id`. A CHECKED task still prints —
#                            handoff is a read — but its `FILES=` is always
#                            empty, since `nodes` never computes scope for a
#                            checked task (it emits no row for one); a `NOTE=`
#                            line says so. A packet id that cannot be resolved
#                            to a real task prints `HANDOFF=unknown` plus
#                            `REASON=`, exit 0 (mirrors task-status's `unknown`,
#                            not check-task's rc=4 — handoff never writes, so
#                            there is no "genuine drift" to report loudly here).
#                            Only a real usage error (no packet id, or a
#                            REFUSED unsafe canonical-form slug) is non-zero.
#                            Output is line-oriented (`KEY=value` lines, plus
#                            `COVERS=`/`UNMATCHED=` blocks with indented
#                            sub-bullet lines under a `COVERS=`) so a caller can
#                            pipe it straight into `runstate.sh handoff`'s
#                            stdin without reparsing it into another shape.
#                            BUNDLING (packet-bundling-t5): a comma-joined
#                            `<packet-id,packet-id,...>` prints each member's
#                            block UNCHANGED (exactly the single-id shape
#                            above, one per member, self-delimiting on its own
#                            `PACKET=`), in PLAN ORDER — never the order the
#                            caller listed them in — preceded by
#                            `BUNDLE=<id,id,...>` (the members, plan-order) and
#                            `BUNDLE_FILES=` (their scopes' union, through the
#                            SAME `_nodes_for` precedence `group` uses, so the
#                            two can never disagree about a packet's scope).
#                            A single id (no comma) takes the ORIGINAL code
#                            path unchanged and never prints either header
#                            line — byte-identical to before bundling existed.
#                            Every member is validated BEFORE anything is
#                            printed, so a refusal never leaves partial
#                            output: any member that does not resolve or
#                            carries no task reuses the `HANDOFF=unknown` +
#                            `REASON=` shape, naming that member; a list
#                            spanning more than one feature is refused the
#                            same way (grouping across features is out of
#                            scope); and a member whose LATEST routing record
#                            in this run's `routing.jsonl` is `hand-off-feature`
#                            (ADR 0028 T9) is refused with the SAME
#                            `HANDOFF=refused`/`REASON=hand-off-feature`/
#                            `PACKET=<id>` shape `runstate.sh handoff` already
#                            uses for the single-id case — read directly here
#                            (this adapter's FILES scope for T5 is itself
#                            alone), fail-soft exactly like `interlock`'s
#                            `.gspec/build/status.json` read: outside the
#                            pinned gspec contract, so a missing run-state,
#                            run_id or routing.jsonl always means "not
#                            routed", never a reason to refuse. `check-task`
#                            stays at exactly one id — the plugin's one write
#                            into `gspec/` is unwidened.
#   group <packet-id> [--cap <n>] [root]   form the bundle the loop would
#                            submit as ONE packet, starting from <packet-id>
#                            as the cursor: the cursor plus the UNCHECKED
#                            tasks consecutive after it in the same feature's
#                            plan order (a checked task between two members
#                            does not break consecutiveness -- `nodes`
#                            already emits no node for one, so this reads
#                            that same list rather than re-deriving it). A
#                            later task joins only when its declared file
#                            scope shares >=1 file with the union of the
#                            scopes already in the group AND every task its
#                            `deps:` names is either earlier in the same
#                            group or already checked; an empty scope shares
#                            nothing with anything, so an empty-scope task
#                            always ends the group right after it, whether it
#                            is the cursor itself or a rejected neighbour.
#                            Stops at `--cap` (default 1, so the command is
#                            inert unless a caller raises it), at the first
#                            disqualified task (`scope`|`deps`), or at the
#                            end of the feature's unchecked tasks (`end`) --
#                            never crossing into another feature, since the
#                            node list this reads from is already scoped to
#                            one. Scope comes from the SAME `_nodes_for`
#                            files: > fingerprint-matched sidecar > empty
#                            precedence `nodes`/`handoff` already use, read
#                            through that function, never re-derived. Output:
#                              GROUP=<packet-id>
#                              MEMBER=<node-id><TAB><title>  (one per member,
#                                                             plan order)
#                              FILES=<union, pipe-separated>
#                              STOP=<cap|scope|deps|end>
#                            An id resolving to no plan, no such task, or an
#                            already-checked task reuses `handoff`'s
#                            `HANDOFF=unknown` + `REASON=` refusal shape,
#                            exit 0 (gspec is optional, same as every other
#                            read here). A REFUSED canonical-form slug is the
#                            only non-zero exit, same as
#                            handoff/check-task/task-status. Never writes;
#                            `nodes` and every other subcommand are
#                            unaffected -- grouping is an execution-time
#                            decision on gaffer's side of ADR 0020's seam,
#                            not a change to what the backlog is.
#   capability-drift [root]  READ-ONLY (completion-record-drift-t1): walk
#                            every feature whose PRD AND plan both resolve
#                            (no plan is out of scope, not unjudgeable) and
#                            report each unchecked capability whose covering
#                            `covers:` tasks are ALL checked as
#                            `DRIFT=<slug>\t<capability text>` — the record a
#                            feature's own PRD checkbox never caught up to.
#                            Anything the scan cannot judge prints
#                            `UNJUDGEABLE=<class>\t<slug>\t<detail>` instead
#                            of drift, one of three classes: `unmatched-quote`
#                            (a `covers:` quote matches no PRD capability,
#                            reported per TASK rather than per capability —
#                            it is evidence about the task, not about any
#                            one capability, and is not deduplicated against
#                            an earlier occurrence), `uncovered-capability`
#                            (an unchecked capability no task's covers
#                            references), or `unrecognized-capability` (an
#                            unchecked capability line the verbatim matcher
#                            declines). A checked capability is never
#                            reported, drift or unjudgeable — the box being
#                            checked already answers "should this be
#                            checked?". Ends with one
#                            `CAPABILITY_DRIFT=ok|attention drift=<n>
#                            unjudgeable=<m>` line (the two counts are
#                            separate fields on purpose — a single zero could
#                            mean either "nothing drifted" or "nothing could
#                            be judged", the exact failure this report
#                            exists to close), or `CAPABILITY_DRIFT=none`
#                            plus a `NOTE=` line when there is no gspec/ at
#                            all (D4). Never writes; exits 0 on every path —
#                            a report, not a gate.
#   complete-capabilities <slug> [root]   WRITE (capability-auto-complete-t1):
#                            flip a feature's finished capabilities to `[x]`.
#                            Walks the same derivation `capability-drift`
#                            walks -- `_prd_capabilities` / `_plan_task_covers`
#                            / `_split_covers` / `_prd_capability` -- so a
#                            capability flips here iff it would have printed
#                            `DRIFT=<slug>\t<capability text>` there; never a
#                            second guess at the same question, and
#                            `capability-drift` itself is unchanged by this
#                            (same functions, same output, still read-only).
#                            Never flips an uncovered or unrecognized
#                            capability, and never unflips a checked one -- a
#                            checked capability is never even considered.
#                            A feature with an UNCHECKED task whose `covers:`
#                            quote matches no capability holds EVERY flip,
#                            never a partial one: a typo'd quote may be
#                            evidence against a capability that would
#                            otherwise flip, and a flip is never undone once
#                            applied. The same quote on an already-CHECKED
#                            task holds nothing -- stale evidence about a task
#                            that is itself already done. Output:
#                              COMPLETE_CAPABILITIES=<ok|blocked|none> completed=<n>
#                              COMPLETED=<slug>\t<capability text>  (n lines, PRD order)
#                              FILE=<relprd>          (present whenever the feature resolved)
#                              REASON=...             (blocked / none / unresolved)
#                            Exit codes mirror check-task (ADR 0025 D1): 0
#                            where there is no gspec/ at all (skipped, D4) or
#                            the feature resolved (whether or not anything
#                            flipped); 1 for a malformed slug (a path
#                            separator or '..' component -- REFUSED, `die`d,
#                            same as check-task's canonical-form guard); 4
#                            for a slug with no resolvable PRD+plan pair in
#                            any layout, distinguishable from the skip. Writes
#                            with check-task's read-only-lookup-then-`sub()`
#                            shape -- only the flipped lines' checkbox
#                            characters change. `check-task` remains the
#                            adapter's only writer of a TASK line; this is the
#                            only writer of a CAPABILITY line.
#
# FILE SCOPE, AND WHY IT IS FINGERPRINT-GUARDED (ADR 0020 U1-local). `allowed_files`
# is the field that decides which packets may run CONCURRENTLY, so a wrong value
# here is the one input that can cost correctness rather than speed. Precedence:
#   1. a plan-authored `files:` sub-bullet (the upstream U1-up shape) — always wins;
#   2. a `.agents/task-files.yaml` entry whose FINGERPRINT still matches the task's
#      current text;
#   3. empty — no scope recorded. (Parallel mode and its packet-graph.sh scheduler,
#      which used to read this field to decide concurrency, are retired; the loop
#      is sequential-only, so an empty scope has no behavioral effect today.)
# The fingerprint is REQUIRED for an entry to be used, and that is the whole point:
# gspec's `plan-decomposer` preserves task IDs on regenerate but RE-DECOMPOSES
# unchecked work, so an unchecked `T5` can keep its id while its text becomes
# different work. An unguarded sidecar would then hand a stale, NARROW scope to two
# lanes that actually collide. A missing or mismatched fingerprint drops the entry
# to empty scope: wrong-wide costs parallelism, wrong-narrow costs correctness.
# Comparison is normalized (case, markdown emphasis, whitespace) so reformatting a
# task does not invalidate its entry.
#
# HOW TASK DEPS BECOME NODE EDGES. `nodes` encodes ordering as a
# consumes/produces signature match, so an intra-feature `deps: T1` is emitted
# as produces `<feature>#T<n>` / consumes `<feature>#T<d>`. (This is the same
# encoding the retired packet-graph.sh scheduler used to derive concurrency
# from; the loop reads it directly now.) A dep on an ALREADY CHECKED task
# simply finds no producer (checked tasks are not nodes) and yields no edge —
# which is correct: done work must not block anything.
#
# LAYOUTS (ADR 0020 D3, gspec 3.x). gspec 3.0 moved everything about a feature
# into ONE folder, and the adapter reads all three shapes it has ever shipped:
#
#   layout        PRD                            plan
#   ------------  -----------------------------  -----------------------------
#   3.x (v2)      gspec/features/<slug>/prd.md   gspec/features/<slug>/tasks.md
#   2.x (v1)      gspec/features/<slug>.md       gspec/tasks/<slug>.md
#   pre-2.0       gspec/features/<slug>.md       gspec/features/<slug>.plan.md
#
# Reading all three is not politeness, it is the same lesson as the task-line
# shapes below: a consumer repo migrates on ITS schedule, and an adapter that
# knows only the new path does not report an error on an unmigrated repo — it
# reports an EMPTY BACKLOG, which reads as "nothing to do". gspec's own floor
# module (`plugin/hooks/floors/paths.mjs`) accepts both layouts for exactly this
# reason, and the task-immutability block it feeds fails open, so a matcher that
# knew only the flat form would stop firing with no error anywhere.
#
# The newer layout WINS wherever both exist for one slug: `/gspec-migrate` moves
# rather than copies, so a slug present in both is a half-finished migration, and
# resolving to the destination is what makes re-running it idempotent. A shadowed
# flat file is skipped by the enumerators, never read twice under two names.
#
# The 3.x feature folder also holds `arch.md` and `design.html`. Neither is in
# the consumed contract: they say what to build and how it should look, which is
# gspec's half of the seam — the loop hands their PATHS to an implementer, and
# this adapter never parses them.
#
# LEGACY TASK-LINE SHAPES (migration compatibility — /gaffer:migrate).
# gspec's canonical task line is `- [ ] **T<n>** ...`. Real pre-2.0 consumer repos
# carry plan files this plugin's own architect authored under the ADR 0013
# convention, in two OTHER shapes -- both observed in production repos:
#   A  `- [x] **T000 Some description.**`  id and description share one bold span
#   B  `- [x] **ser-t1** **P0** **[GATE:...]** ...`  feature-prefixed kebab id
# Recognizing them is what makes migration a safe MOVE. Rewriting task lines into
# canonical form would edit CHECKED tasks -- which gspec's task-immutability floor
# blocks, and which destroys the historical record of what was built. Refusing to
# recognize them is worse still: the file moves, parses to nothing, and the backlog
# reads as EMPTY rather than as unreadable -- the exact silent-failure class this
# adapter exists to prevent (measured: both production repos yielded 0 packets).
# Legacy files are reported on stderr; regenerate them with `/gspec-plan`.
#
# WHAT IS DELIBERATELY NOT INFERRED. gspec task lines carry no file scope, so
# `allowed_files` is empty unless an (upstream-proposal-U1) `files:` line is
# present. An empty scope is never widened by a guess here — guessing a narrow
# scope from task text is how two packets would end up colliding on an
# unlisted shared file, which mattered when packet-graph.sh (now retired) used
# this field to decide concurrency and still matters for `allowed_files`
# itself, whatever consumes it.
#
# Exit codes: 0 = ok; 1 = usage / bad input; 3 = version-pin mismatch;
#             4 = a required gspec artifact is missing.
# =============================================================================

set -euo pipefail

die() { printf 'gspec-backlog.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

# --- The pin (ADR 0020 D3) ---------------------------------------------------
# Raising these is a deliberate, reviewed change: bump, extend, re-run the
# sweeps, amend ADR 0020. Env overrides exist for testing and for a consumer repo
# that has deliberately moved ahead of the plugin.
GSPEC_PINNED_VERSION="${ORCH_GSPEC_PINNED_VERSION:-3.1.1}"
# BOTH artifact versions are supported, and that is the deliberate half of the
# 3.1.1 bump: v2 is what gspec writes now, v1 is what every unmigrated consumer
# repo still has on disk. Narrowing this to `v2` would make `check` fail — rc=3,
# the loop stops — on a repo whose backlog this adapter can read perfectly well.
# The version pin exists to catch a format this code CANNOT parse; it is not a
# lever for nagging a repo into migrating. `/gaffer:migrate` reports the layout
# and names /gspec-migrate; that is where the nudge belongs.
GSPEC_SPEC_VERSIONS="${ORCH_GSPEC_SPEC_VERSIONS:-v1 v2}"

cmd_pin() {
  printf 'GSPEC_PINNED_VERSION=%s\n' "$GSPEC_PINNED_VERSION"
  printf 'GSPEC_SPEC_VERSIONS=%s\n' "$GSPEC_SPEC_VERSIONS"
  printf 'INSTALL=npx gspec@%s --target claude\n' "$GSPEC_PINNED_VERSION"
}

# --- shared helpers ----------------------------------------------------------

# The one task-line shape every parser in this file must agree on
# (loop-measurement T2 Important 3): a checkbox followed by a bold-opened id,
# with the id ending at the closing bold (canonical/shape B) or running on
# into a space (shape A, where the bold spans id+description together). Split
# into building blocks so a match against a SPECIFIC id (the history probe)
# and a match against ANY id (lookup/count) derive from the same source
# instead of five copies that can silently drift apart -- which is exactly
# what let `_plan_task_line_count` and `_task_lookup` disagree before this.
# `_task_lookup`/`_plan_task_line_count`/`_task_history_probe` derive from
# these; `_nodes_for` (:714) and `cmd_plans` (:641) still carry their own
# copies of the full pattern -- migrating them is welcome but not required
# here (they agree with `_TASK_LINE_RE` today).
_TASK_LINE_PREFIX='^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*'
_TASK_ID_CLASS='[A-Za-z][A-Za-z0-9_-]*[0-9]+'
_TASK_LINE_SUFFIX='(\*\*|[[:space:]])'
_TASK_LINE_RE="${_TASK_LINE_PREFIX}${_TASK_ID_CLASS}${_TASK_LINE_SUFFIX}"

# The capability-line shape `_feature_done` tests -- extracted to a shared
# constant (completion-record-drift-t1) so `capability-drift` below tests the
# SAME thing `_feature_done` counts, never a second guess at what a
# capability line looks like. Canonical `**P0**: text`, and the legacy shape
# `**P0 — text**` where priority and description share one bold span
# (observed in production repos) -- both match here, exactly as they did
# inline before this extraction; only the pattern moved, not its meaning.
_CAPABILITY_LINE_RE='^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*P[0-9]+([^0-9]|\*\*)'

# Anchoring divergence from `_prd_capability` below, recorded rather than
# aligned (completion-record-drift-gaps-t6): this pattern admits leading
# whitespace (`^[[:space:]]*-`), but `_prd_capability`'s verbatim quote
# matcher is anchored `^-` -- column 0 only, no leading whitespace at all. An
# indented but otherwise canonical capability line is therefore enumerated
# HERE (via `_prd_capabilities`, which drives the capability-drift walk) and
# declined THERE (via `_prd_capability`, which every `covers:` quote is
# checked against) -- so such a line is always reported
# `uncovered-capability` (nothing ever registers a MATCH against it) plus one
# `unmatched-quote` per task whose `covers:` names it (that quote never
# matches either), and never a `DRIFT=` line, regardless of whether its
# covering tasks are all checked. Safe direction: an indented capability line
# can never be misread as delivered when it is not.
#
# Why the divergence stands rather than being aligned: widening
# `_prd_capability`'s `^-` anchor to admit leading whitespace, to match this
# pattern, would move the indentation-based block boundary it uses to
# extract a capability's acceptance-criteria sub-bullets (see its comment
# below) -- that boundary works only because the capability header is always
# at column 0, so ANY indented line unambiguously belongs to it as a
# sub-bullet; once the header itself can sit at some indent N, a sibling line
# at that same indent N (not a sub-bullet of it at all) would satisfy the
# identical "is this line indented" test and get swallowed into the block.
# `_prd_capability`'s match also feeds `cmd_handoff`'s `COVERS=` output --
# the acceptance criteria a packet is told is "done" -- so a widening here is
# judged against that caller too, not just this one, and a corrupted
# criteria block is worse than a declined quote. Neither pattern changes.

# Print a file's YAML frontmatter body (between the first `---` and the next),
# or nothing when the file has none.
_frontmatter() {
  [ -f "$1" ] || return 0
  awk '
    NR==1 && $0 !~ /^-{3}[[:space:]]*$/ { exit }
    NR==1 { infm=1; next }
    infm && /^-{3}[[:space:]]*$/ { exit }
    infm { print }
  ' "$1"
}

# _fm_scalar <file> <key> — a flat scalar from frontmatter ('' when absent).
_fm_scalar() {
  _frontmatter "$1" | awk -v k="$2" '
    $0 ~ "^" k "[[:space:]]*:" {
      sub("^" k "[[:space:]]*:[[:space:]]*", "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      sub(/[[:space:]]+$/, "")
      print; exit
    }'
}

# _fm_list <file> <key> — a frontmatter list as '|'-separated. Accepts the inline
# flow form (`depends_on: [a, b]`) and the block form (`depends_on:\n  - a`).
_fm_list() {
  _frontmatter "$1" | awk -v k="$2" '
    function emit(s){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); gsub(/^["'"'"']|["'"'"']$/,"",s);
                      if (s != "" && s != "-" && s != "—") out = (out=="" ? s : out "|" s) }
    $0 ~ "^" k "[[:space:]]*:" {
      line=$0; sub("^" k "[[:space:]]*:[[:space:]]*","",line)
      if (line ~ /^\[/) { gsub(/^\[|\]$/,"",line); n=split(line,a,","); for(i=1;i<=n;i++) emit(a[i]); done=1 }
      else if (line != "") { emit(line); done=1 }
      else block=1
      next
    }
    block && /^[[:space:]]+-[[:space:]]*/ { l=$0; sub(/^[[:space:]]+-[[:space:]]*/,"",l); emit(l); next }
    block && /^[^[:space:]]/ { block=0 }
    END { print out }
  '
}

# Resolve the repo root argument (default: cwd).
_root() { printf '%s' "${1:-.}"; }

# Is there a gspec project here at all? (D4: gspec is OPTIONAL.)
_has_gspec() { [ -d "$(_root "$1")/gspec" ]; }

# --- the LAYOUT seam (see LAYOUTS in the header) ------------------------------
# Four functions, and every gspec path in this file comes out of one of them. A
# fourth layout must only ever need editing here — which is the same promise
# `_resolve_plan_path` already made and the reason adding gspec 3.x cost a seam
# rather than a sweep through nine call sites.
#
# The two enumerators SHADOW: a slug whose newer-layout file exists suppresses
# its older-layout twin, so a half-finished /gspec-migrate yields one row per
# feature rather than two rows that disagree about how done it is.

# _prd_paths <root> — every feature PRD on disk, one absolute path per line.
_prd_paths() {
  local root="$1" p slug
  for p in "$root"/gspec/features/*/prd.md; do
    [ -f "$p" ] || continue
    printf '%s\n' "$p"
  done
  for p in "$root"/gspec/features/*.md; do
    [ -f "$p" ] || continue
    slug="$(basename "$p" .md)"
    # A plan file beside the PRD is a plan, not a feature (pre-2.0 layout).
    case "$slug" in *.plan) continue ;; esac
    [ -f "$root/gspec/features/$slug/prd.md" ] && continue
    printf '%s\n' "$p"
  done
}

# _plan_paths <root> — every plan file on disk, as "<abs path>\t<slug>".
# The slug is carried rather than re-derived because the folder layout encodes it
# in the DIRECTORY (features/<slug>/tasks.md), so `basename .md` — which every
# caller used to do — yields the literal string "tasks" for all of them.
_plan_paths() {
  local root="$1" p b slug
  for p in "$root"/gspec/features/*/tasks.md; do
    [ -f "$p" ] || continue
    printf '%s\t%s\n' "$p" "$(basename "$(dirname "$p")")"
  done
  for p in "$root"/gspec/tasks/*.md; do
    [ -f "$p" ] || continue
    slug="$(basename "$p" .md)"
    if [ -f "$root/gspec/features/$slug/tasks.md" ]; then continue; fi
    printf '%s\t%s\n' "$p" "$slug"
  done
  for p in "$root"/gspec/features/*.plan.md; do
    [ -f "$p" ] || continue
    b="$(basename "$p")"; slug="${b%.plan.md}"
    if [ -f "$root/gspec/features/$slug/tasks.md" ] || [ -f "$root/gspec/tasks/$slug.md" ]; then continue; fi
    printf '%s\t%s\n' "$p" "$slug"
  done
}

# _resolve_prd_path <slug> <root> — "<prd>\t<relprd>", or nothing when neither
# layout has one. Newest layout first (see LAYOUTS).
_resolve_prd_path() {
  local slug="$1" root="$2"
  if [ -f "$root/gspec/features/$slug/prd.md" ]; then
    printf '%s\t%s\n' "$root/gspec/features/$slug/prd.md" "gspec/features/$slug/prd.md"
  elif [ -f "$root/gspec/features/$slug.md" ]; then
    printf '%s\t%s\n' "$root/gspec/features/$slug.md" "gspec/features/$slug.md"
  fi
}

# --- check: the ARTIFACT pin (ADR 0020 D3) -----------------------------------

cmd_check() {
  local root; root="$(_root "${1:-}")"
  if ! _has_gspec "$root"; then
    printf 'CHECK=ok\nNOTE=no gspec/ directory — gspec is optional (ADR 0020 D4)\n'
    return 0
  fi
  local bad=0 f ver base
  # Only the artifacts we actually consume are asserted. Asserting gspec's whole
  # tree would make us fail on specs we never read - `arch.md`, `design.html` and
  # the foundation specs are gspec's to police, and it has a floor that does.
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    base="${f#"$root"/}"
    ver="$(_fm_scalar "$f" 'spec-version')"
    if [ -z "$ver" ]; then
      printf 'FAIL=%s has no spec-version frontmatter\n' "$base"; bad=1; continue
    fi
    case " $GSPEC_SPEC_VERSIONS " in
      *" $ver "*) ;;
      *) printf 'FAIL=%s has spec-version %s; this plugin supports %s (pinned gspec %s)\n' \
           "$base" "$ver" "$GSPEC_SPEC_VERSIONS" "$GSPEC_PINNED_VERSION"; bad=1 ;;
    esac
  done < <( { _prd_paths "$root"; _plan_paths "$root" | cut -f1; } )
  if [ "$bad" -ne 0 ]; then
    printf 'CHECK=fail\n'
    printf 'HINT=run /gspec-migrate to bring specs current, or raise the pin in scripts/gspec-backlog.sh (ADR 0020 D3)\n'
    return 3
  fi
  printf 'CHECK=ok\nSPEC_VERSIONS=%s\nPINNED_GSPEC=%s\n' "$GSPEC_SPEC_VERSIONS" "$GSPEC_PINNED_VERSION"
}

# --- completion, derived from PRD capability checkboxes (ADR 0020 D2) --------
# A feature is done when its PRD has >=1 capability checkbox and none unchecked.
# Zero checkboxes => NOT done: absence of evidence is not completion.
_feature_done() {
  local prd="$1"
  [ -f "$prd" ] || { printf '0'; return 0; }
  # `_CAPABILITY_LINE_RE` (see its definition above) is the shape this
  # recognizes; getting it wrong is not cosmetic: an unrecognized capability
  # line means the feature can NEVER read as done, so every feature depending
  # on it stays blocked forever and the backlog quietly reports nothing to do.
  awk '
    /'"$_CAPABILITY_LINE_RE"'/ {
      total++
      if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) checked++
    }
    END { print (total > 0 && total == checked) ? "1" : "0" }
  ' "$prd"
}

# --- .agents/roadmap.yaml (plugin-owned, OPTIONAL) ---------------------------
# Constrained shape only (ADR 0020 D2): schema + a `features:` list of flat maps
# with slug/order/why/depends_on/deferred. Not a general YAML parser, by design.
#
# `deferred: true` is NOT the `status` field ADR 0020 D2 prohibits, and the
# distinction is the rule's own reasoning rather than a loophole. That prohibition
# names two fields and says why: completion is DERIVED from the PRD's capability
# checkboxes and concurrency was DERIVED by packet-graph.sh (retired along with
# parallel mode), so storing either is a
# drift source. `deferred` is derived from neither — it is a HUMAN planning
# decision, which is precisely what this file owns. It answers "should the loop
# pick this up yet?", never "is this done?".
#
# It exists because the alternative for deferred-but-recorded work is worse in
# both directions: leave it out of the roadmap and `next` still reaches it (order
# only sequences, it does not gate), or leave the PRD out entirely and the
# deferral has no status at all — which is the tracking gap the backlog exists to
# close. Deferral is recorded, visible in `features`, and skipped by `next`.
_roadmap_rows() {
  local rm="$1"
  [ -f "$rm" ] || return 0
  awk '
    function flush(){ if (slug != "") printf "%s\t%s\t%s\t%s\t%s\n", slug, (order==""?"":order), deps, why, deferred;
                      slug=""; order=""; deps=""; why=""; deferred="" }
    function val(l){ sub(/^[^:]*:[[:space:]]*/,"",l); gsub(/^["'"'"']|["'"'"']$/,"",l);
                     sub(/[[:space:]]+$/,"",l); return l }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]+slug[[:space:]]*:/ { flush(); l=$0; sub(/^[[:space:]]*-[[:space:]]+/,"",l); slug=val(l); next }
    /^[[:space:]]+order[[:space:]]*:/ { order=val($0); next }
    /^[[:space:]]+why[[:space:]]*:/   { why=val($0);   next }
    # Only an explicit, unambiguous true defers. Anything else — false, absent,
    # a typo — reads as NOT deferred, so a malformed entry costs an unwanted
    # pickup the human can see and fix, never silent disappearance from the
    # backlog. Wrong-visible beats wrong-invisible for a gating field.
    /^[[:space:]]+deferred[[:space:]]*:/ {
      l=tolower(val($0))
      deferred = (l == "true" || l == "yes") ? "1" : ""
      next
    }
    /^[[:space:]]+depends_on[[:space:]]*:/ {
      l=val($0)
      if (l ~ /^\[/) { gsub(/^\[|\]$/,"",l); n=split(l,a,","); deps="";
                       for(i=1;i<=n;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",a[i]);
                                          if(a[i]!="") deps=(deps==""?a[i]:deps "|" a[i]) } }
      else deps=""
      next
    }
    END { flush() }
  ' "$rm"
}

# --- .agents/task-files.yaml (plugin-owned file scope, OPTIONAL) -------------
# Same constrained shape as the roadmap: a `tasks:` list of flat maps.
#   tasks:
#     - task: auth#T1
#       files: [db/migrations/**, src/models/user.ts]
#       fingerprint: create the schema migration
# Emits TSV: <task-key>\t<files '|'-sep>\t<fingerprint>
_sidecar_rows() {
  local sc="$1"
  [ -f "$sc" ] || return 0
  awk '
    function flush(){ if (key != "") printf "%s\t%s\t%s\n", key, files, fp; key=""; files=""; fp="" }
    function val(l){ sub(/^[^:]*:[[:space:]]*/,"",l); gsub(/^["'"'"']|["'"'"']$/,"",l);
                     sub(/[[:space:]]+$/,"",l); return l }
    function list(l,   n,a,i,out){
      gsub(/^\[|\]$/,"",l); n=split(l,a,",")
      for(i=1;i<=n;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",a[i]); gsub(/^["'"'"']|["'"'"']$/,"",a[i])
                         if(a[i]!="") out=(out==""?a[i]:out "|" a[i]) }
      return out
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]+task[[:space:]]*:/ { flush(); l=$0; sub(/^[[:space:]]*-[[:space:]]+/,"",l); key=val(l); next }
    /^[[:space:]]+files[[:space:]]*:/       { files=list(val($0)); next }
    /^[[:space:]]+fingerprint[[:space:]]*:/ { fp=val($0); next }
    END { flush() }
  ' "$sc"
}

# --- features: the sequencing table ------------------------------------------

cmd_features() {
  local root; root="$(_root "${1:-}")"
  _has_gspec "$root" || { printf 'FEATURES=none\n' >&2; return 0; }

  local rm="$root/.agents/roadmap.yaml"
  local tmp_rm; tmp_rm="$(mktemp)"; _roadmap_rows "$rm" > "$tmp_rm"

  local tmp; tmp="$(mktemp)"
  local prd slug order why deps done deferred
  while IFS= read -r prd; do
    [ -n "$prd" ] && [ -f "$prd" ] || continue
    # The 3.x folder layout carries the slug in the DIRECTORY name; the flat
    # layouts carry it in the basename. `_prd_paths` has already dropped plan
    # files and shadowed duplicates, so this is the only distinction left.
    case "$prd" in
      */prd.md) slug="$(basename "$(dirname "$prd")")" ;;
      *)        slug="$(basename "$prd" .md)" ;;
    esac

    done="$(_feature_done "$prd")"
    # depends_on: PRD frontmatter WINS (upstream proposal U5), roadmap is the
    # fallback. Never merged — a stale roadmap entry must not re-block a feature
    # whose PRD says it is clear (ADR 0020 Consequences, watch item e).
    deps="$(_fm_list "$prd" 'depends_on')"
    order=""; why=""; deferred=""
    if [ -s "$tmp_rm" ]; then
      local row; row="$(awk -F'\t' -v s="$slug" '$1==s {print; exit}' "$tmp_rm")"
      if [ -n "$row" ]; then
        order="$(printf '%s' "$row" | cut -f2)"
        [ -n "$deps" ] || deps="$(printf '%s' "$row" | cut -f3)"
        why="$(printf '%s' "$row" | cut -f4)"
        deferred="$(printf '%s' "$row" | cut -f5)"
      fi
    fi
    # Unlisted features sort after every explicitly ordered one, then by slug.
    [ -n "$order" ] || order=9999
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$order" "$done" "$deps" "$why" "$deferred" >> "$tmp"
  done < <(_prd_paths "$root")
  rm -f "$tmp_rm"

  # blocked = any dependency that is not done. Computed after the full set is
  # known, so a dependency's completion is read from the same snapshot.
  #
  # A DEFERRED feature still blocks its dependents, exactly like any other
  # incomplete one. Deferring says "not now", not "pretend it is done" — letting
  # it satisfy a dependency would release work whose prerequisite nobody built.
  # `deferred` is appended as the LAST field so every existing column index in
  # this TSV keeps its meaning for anything already parsing it.
  awk -F'\t' '
    { slug[NR]=$1; ord[NR]=$2; dn[NR]=$3; dep[NR]=$4; why[NR]=$5; df[NR]=$6; isdone[$1]=$3; n=NR }
    END {
      for (i=1; i<=n; i++) {
        blocked=0
        if (dep[i] != "") {
          m=split(dep[i], d, "|")
          for (j=1; j<=m; j++) if (d[j] != "" && isdone[d[j]] != "1") blocked=1
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", slug[i], ord[i], dn[i], blocked, dep[i], why[i], (df[i]=="1"?"1":"0")
      }
    }
  ' "$tmp" | sort -t"$(printf '\t')" -k2,2n -k1,1
  rm -f "$tmp"
}

# --- next: which feature does the loop pick up? (ADR 0020 D2) ----------------

cmd_next() {
  local root; root="$(_root "${1:-}")"
  if ! _has_gspec "$root"; then
    printf 'NEXT=none\nREASON=no gspec/ directory — supply a backlog another way (ADR 0020 D4)\n'
    return 0
  fi
  local rows; rows="$(cmd_features "$root")"
  if [ -z "$rows" ]; then
    printf 'NEXT=none\nREASON=no feature PRDs under gspec/features/\n'; return 0
  fi
  local pick
  pick="$(printf '%s\n' "$rows" | awk -F'\t' '$3=="0" && $4=="0" && $7!="1" && !seen {print $1; seen=1}')"
  if [ -z "$pick" ]; then
    # Three distinct nothing-to-do states, reported distinctly. Collapsing them
    # is how "the loop has stopped picking work up" gets misread as "the backlog
    # is finished" — the deferred case in particular is a human decision that can
    # be reversed by editing one line, and the reader has to be told which it is.
    #
    # Each state is a CAPTURED value tested with `[ -n ... ]`, never
    # `printf … | awk … | grep -q .` used directly as a condition. `grep -q`
    # exits on its first match and closes the pipe; the awk still writing takes
    # the signal, and the file-wide `pipefail` reports that signal in place of
    # grep's success — so a TRUE condition reads as FALSE and control falls
    # through to `all features complete`, reporting a finished backlog over work
    # nobody built. Measured, not theorised: 235 and 241 misreports in 400
    # iterations against this repository's own 18,756-byte payload. Command
    # substitution reads to end of file, so no reader can close before its
    # writer finishes. The captured rows then feed the per-feature lines through
    # the same formatting awk — which reads to EOF and so cannot misfire — so
    # each state is filtered once instead of twice and the output is unchanged.
    local blocked deferred
    blocked="$(printf '%s\n' "$rows" | awk -F'\t' '$3=="0" && $7!="1"')"
    if [ -n "$blocked" ]; then
      printf 'NEXT=none\nREASON=every incomplete feature is blocked by an unfinished dependency\n'
      printf '%s\n' "$blocked" | awk -F'\t' '{printf "BLOCKED=%s depends_on=%s\n", $1, $5}'
      return 0
    fi
    deferred="$(printf '%s\n' "$rows" | awk -F'\t' '$3=="0" && $7=="1"')"
    if [ -n "$deferred" ]; then
      printf 'NEXT=none\nREASON=every remaining feature is deferred in .agents/roadmap.yaml\n'
      printf '%s\n' "$deferred" | awk -F'\t' '{printf "DEFERRED=%s why=%s\n", $1, $6}'
      printf 'HINT=remove `deferred: true` from an entry to bring it back into the backlog\n'
      return 0
    fi
    printf 'NEXT=none\nREASON=all features complete\n'; return 0
  fi
  printf 'NEXT=%s\n' "$pick"
  local pp; pp="$(_resolve_plan_path "$pick" "$root")"
  if [ -n "$pp" ]; then
    local relplan; relplan="$(printf '%s' "$pp" | cut -f2)"
    printf 'PLAN=%s\n' "$relplan"
    # An older-layout plan is READ, never refused - but say so once, here, where
    # a human is looking at the next feature anyway. The remedy is gspec's own
    # migrator; this adapter does not move files.
    case "$relplan" in
      gspec/features/*/tasks.md) ;;
      *) printf 'WARN=%s is a pre-3.x plan location; /gspec-migrate relocates it to gspec/features/%s/tasks.md\n' "$relplan" "$pick" ;;
    esac
    # The 3.x feature folder's enriched siblings, when present: the loop hands
    # these PATHS to an implementer so it needs nothing else. Absent is normal
    # (a feature with no UI gets no design; an unmigrated repo has neither) and
    # never an error - /gspec-architect writes them.
    [ -f "$root/gspec/features/$pick/arch.md" ] \
      && printf 'ARCH=gspec/features/%s/arch.md\n' "$pick"
    [ -f "$root/gspec/features/$pick/design.html" ] \
      && printf 'DESIGN=gspec/features/%s/design.html\n' "$pick"
  else
    printf 'PLAN=none\n'
    printf 'HINT=run /gspec-plan %s to decompose the PRD before the loop can execute it\n' "$pick"
  fi
  [ -f "$root/.agents/roadmap.yaml" ] || \
    printf 'NOTE=no .agents/roadmap.yaml — ordering fell back to dependency then slug (ADR 0020 D2)\n'
}

# --- plans: the layout census (/gaffer:migrate reads this) -------------------
# Reports WHERE each plan is, never moves one. The move is /gspec-migrate's --
# gspec owns spec format and layout; this plugin owns execution (ADR 0020).

cmd_plans() {
  local root; root="$(_root "${1:-}")"
  _has_gspec "$root" || return 0
  local p slug rel layout counts
  while IFS=$'\t' read -r p slug; do
    [ -n "$p" ] || continue
    rel="${p#"$root"/}"
    case "$rel" in
      gspec/features/*/tasks.md) layout='3.x' ;;
      gspec/tasks/*.md)          layout='2.x' ;;
      *)                         layout='pre-2.0' ;;
    esac
    # The SAME task-line pattern `_nodes_for` uses -- canonical plus both legacy
    # shapes. It has to be the same or the count lies about what the backlog can
    # read, which is the one thing this column exists to report.
    counts="$(awk '
      /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*[A-Za-z][A-Za-z0-9_-]*[0-9]+(\*\*|[[:space:]])/ {
        t++
        if ($0 !~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) u++
      }
      END { printf "%d\t%d", t+0, u+0 }' "$p")"
    printf '%s\t%s\t%s\t%s\n' "$slug" "$rel" "$layout" "$counts"
  done < <(_plan_paths "$root") | sort -t"$(printf '\t')" -k1,1
}

# --- nodes: gspec tasks -> packet NODES TSV ----------------------------------

_nodes_for() {
  local root="$1" slug="$2"
  local pp; pp="$(_resolve_plan_path "$slug" "$root")"
  [ -n "$pp" ] || return 0
  local plan; plan="$(printf '%s' "$pp" | cut -f1)"
  local prd; prd="$(_resolve_prd_path "$slug" "$root" | cut -f1)"
  local fdeps; fdeps="$(_fm_list "$prd" 'depends_on')"
  if [ -z "$fdeps" ] && [ -f "$root/.agents/roadmap.yaml" ]; then
    fdeps="$(_roadmap_rows "$root/.agents/roadmap.yaml" | awk -F'\t' -v s="$slug" '$1==s && !seen {print $3; seen=1}')"
  fi

  local sc; sc="$(mktemp)"
  _sidecar_rows "$root/.agents/task-files.yaml" > "$sc"

  awk -v feature="$slug" -v fdeps="$fdeps" -v sidecar="$sc" -v planpath="$plan" '
    # Normalize for fingerprint comparison: case, markdown emphasis, whitespace.
    # Reformatting a task must not invalidate its scope; REWORDING it must.
    function norm(s) {
      s = tolower(s); gsub(/[*_`]/, "", s)
      gsub(/[[:space:]]+/, " ", s); gsub(/^ +| +$/, "", s)
      return s
    }
    BEGIN {
      while ((getline line < sidecar) > 0) {
        n = split(line, f, "\t")
        if (n >= 1 && f[1] != "") { sc_files[f[1]] = (n>=2 ? f[2] : ""); sc_fp[f[1]] = (n>=3 ? f[3] : "") }
      }
      close(sidecar)
    }
    function flush(   key) {
      if (id == "") return
      # Only UNCHECKED tasks are backlog. A checked task is done work: emitting it
      # would re-run it, and omitting it correctly dissolves edges into it.
      if (!checked) {
        produces = feature "#" id
        consumes = ""
        if (deps != "") {
          n = split(deps, d, ",")
          for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", d[i])
            if (d[i] == "" || d[i] == "-" || d[i] == "\342\200\224") continue
            consumes = (consumes == "" ? "" : consumes "|") feature "#" d[i]
          }
        }
        # Precedence: plan-authored files: > fingerprint-matched sidecar > empty.
        key = feature "#" id
        if (files == "" && (key in sc_files)) {
          if (sc_fp[key] == "")
            printf "gspec-backlog.sh: %s sidecar entry has no fingerprint — ignored (an unverifiable narrow scope is exactly what must not be trusted)\n", key > "/dev/stderr"
          else if (norm(sc_fp[key]) != norm(desc))
            printf "gspec-backlog.sh: %s sidecar fingerprint no longer matches the task text — ignored; the packet serializes conservatively. Re-scope it and update .agents/task-files.yaml\n", key > "/dev/stderr"
          else
            files = sc_files[key]
        }
        printf "%s-%s\t%s\t%s\t%s\t%s\t%s\n",
               feature, tolower(id), feature, files, consumes, produces, fdeps
      }
      id=""; checked=0; deps=""; files=""; desc=""
    }
    # Canonical `**T<n>**`, plus the two legacy shapes (see the header). An id is a
    # bold-opening token ending in digits; the bold may close right after it
    # (canonical / shape B) or run on into the description (shape A).
    /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*[A-Za-z][A-Za-z0-9_-]*[0-9]+(\*\*|[[:space:]])/ {
      flush()
      checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
      desc = $0
      sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*/, "", desc)
      match(desc, /^[A-Za-z][A-Za-z0-9_-]*[0-9]+/)
      id = substr(desc, 1, RLENGTH)
      if (id !~ /^T[0-9]+$/) legacy = 1
      desc = substr(desc, RLENGTH + 1)
      sub(/^\*\*/, "", desc)                  # canonical/B: bold closed after the id
      # Strip whatever marker run precedes the real description.
      sub(/^[[:space:]]*\[P\][[:space:]]*/, "", desc)
      sub(/^[[:space:]]*\*\*P[0-9]+\*\*[[:space:]]*/, "", desc)
      sub(/^[[:space:]]*\*\*\[GATE:[^]]*\]\*\*[[:space:]]*/, "", desc)
      sub(/^[[:space:]]*`?\[GATE:[^]]*\]`?[[:space:]]*/, "", desc)
      sub(/^[[:space:]]+/, "", desc)
      next
    }
    id != "" && /^[[:space:]]+-[[:space:]]*deps[[:space:]]*:/ {
      l=$0; sub(/^[[:space:]]+-[[:space:]]*deps[[:space:]]*:[[:space:]]*/,"",l); deps=l; next
    }
    # files: is NOT emitted by gspec today — forward-compat with upstream
    # proposal U1. Absent => empty scope in the TSV; unwidened, per the header note.
    id != "" && /^[[:space:]]+-[[:space:]]*files[[:space:]]*:/ {
      l=$0; sub(/^[[:space:]]+-[[:space:]]*files[[:space:]]*:[[:space:]]*/,"",l)
      gsub(/^\[|\]$/,"",l); gsub(/[[:space:]]*,[[:space:]]*/,"|",l)
      gsub(/[[:space:]]+$/,"",l); files=l; next
    }
    END {
      flush()
      if (legacy)
        printf "gspec-backlog.sh: %s uses a LEGACY task-line format (pre-2.0, architect-authored). It is read, but regenerate it with /gspec-plan for canonical ids, deps: and covers:.\n", planpath > "/dev/stderr"
    }
  ' "$plan"
  rm -f "$sc"
}

# --- files-status: audit the sidecar against the live plans ------------------
# The sidecar is the one hand-maintained input that can cost CORRECTNESS, so it
# gets an explicit audit rather than only a passing stderr note during `nodes`.
cmd_files_status() {
  local root; root="$(_root "${1:-}")"
  local scf="$root/.agents/task-files.yaml"
  if [ ! -f "$scf" ]; then
    printf 'FILES=none\nNOTE=no .agents/task-files.yaml — every packet gets empty scope and serializes conservatively (ADR 0020 U1-local)\n'
    return 0
  fi
  # Build the live task table from every plan: key \t checked \t normalized desc.
  local live; live="$(mktemp)"
  local plan slug
  while IFS=$'\t' read -r plan slug; do
    [ -n "$plan" ] && [ -f "$plan" ] || continue
    awk -v feature="$slug" '
      function norm(s) { s=tolower(s); gsub(/[*_`]/,"",s); gsub(/[[:space:]]+/," ",s); gsub(/^ +| +$/,"",s); return s }
      /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*T[0-9]+\*\*/ {
        checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
        match($0, /\*\*T[0-9]+\*\*/); id = substr($0, RSTART+2, RLENGTH-4)
        d=$0
        sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*/,"",d)
        sub(/^\*\*T[0-9]+\*\*[[:space:]]*/,"",d); sub(/^\[P\][[:space:]]*/,"",d)
        sub(/^\*\*P[0-9]+\*\*[[:space:]]*/,"",d)
        printf "%s#%s\t%s\t%s\n", feature, id, checked, norm(d)
      }' "$plan" >> "$live"
  done < <(_plan_paths "$root")

  local ok=0 stale=0 unfp=0 done_=0 orphan=0 key files fp row lchecked ldesc nfp
  while IFS=$'\t' read -r key files fp; do
    [ -n "$key" ] || continue
    row="$(awk -F'\t' -v k="$key" '$1==k {print; exit}' "$live")"
    if [ -z "$row" ]; then
      printf 'orphan          %s   (no such task in any plan — safe, but dead weight)\n' "$key"; orphan=$((orphan+1)); continue
    fi
    lchecked="$(printf '%s' "$row" | cut -f2)"; ldesc="$(printf '%s' "$row" | cut -f3)"
    if [ "$lchecked" = "1" ]; then
      printf 'done            %s   (task is already checked off — entry unused)\n' "$key"; done_=$((done_+1)); continue
    fi
    if [ -z "$fp" ]; then
      printf 'unfingerprinted %s   (IGNORED — add a fingerprint or the scope cannot be trusted)\n' "$key"; unfp=$((unfp+1)); continue
    fi
    nfp="$(printf '%s' "$fp" | tr '[:upper:]' '[:lower:]' | tr -d '*_`' | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"
    if [ "$nfp" = "$ldesc" ]; then
      printf 'ok              %s   -> %s\n' "$key" "$files"; ok=$((ok+1))
    else
      printf 'stale           %s   (IGNORED — task text changed; re-scope and update the entry)\n' "$key"; stale=$((stale+1))
    fi
  done < <(_sidecar_rows "$scf")
  rm -f "$live"

  printf 'FILES=%s ok=%d stale=%d unfingerprinted=%d done=%d orphan=%d\n' \
    "$([ $((stale+unfp)) -eq 0 ] && printf ok || printf attention)" "$ok" "$stale" "$unfp" "$done_" "$orphan"
  [ $((stale+unfp)) -eq 0 ] || printf 'NOTE=ignored entries do not break the run — those packets just serialize (wrong-wide, never wrong-narrow)\n'
}

# --- check-task: the adapter's ONE write (ADR 0025 D1 / ADR 0020 D2) ---------
# Flip exactly one task's checkbox `[ ]` -> `[x]` in the feature's plan file
# (whichever layout it is in -- `_resolve_plan_path` decides, never this), and
# NOTHING else. Every outcome except the last exits 0, because gspec is OPTIONAL
# (D4) -- a non-gspec backlog has no checkbox to flip, and its absence is not a
# failure. Only a task id that names an EXISTING plan but no such task is loud
# (exit 4): that is genuine drift -- a packet naming a gspec task that does not
# exist -- and drift must not be silent.
#
# <task> accepts two forms so no call site has to do its own id surgery:
#   canonical  <feature>#T<n>     (e.g. run-state-cleanup#T1)
#   packet-id  <feature>-t<n>     (e.g. run-state-cleanup-t1 -- the node id
#                                  _nodes_for emits, and what the loop actually
#                                  holds at packet close)
# _resolve_task_id <task> <root> — the id-resolution check-task and task-status
# (T2) share: both accept `<feature>#T<n>` and the packet-id form
# `<feature>-t<n>`, and must resolve them IDENTICALLY. A second copy that
# drifted from this one is the defect this factoring exists to prevent. Prints
# exactly one of:
#   NOGSPEC                    no gspec/ directory at all (ADR 0020 D4)
#   UNRESOLVED                 the token does not resolve to any real plan file
#   REFUSED <message>          a canonical-form slug contains a path separator
#                               or a '..' component (ADR 0025 D1) -- printed,
#                               never `die`d, here: this runs inside a caller's
#                               command substitution, where `exit` would only
#                               kill the subshell capturing it, not the script.
#                               Every caller must `die` on a REFUSED line itself.
#   RESOLVED\t<slug>\t<id>\t<ambiguous>
#                               resolved to a real plan file. Whether <id>
#                               actually EXISTS in that plan -- and its checked
#                               state -- is NOT determined here: check-task and
#                               task-status each need a different answer to
#                               that (flip-or-already-or-notfound vs.
#                               finished/unchecked/unknown), so it stays out of
#                               the shared part. See `_task_lookup`. <ambiguous>
#                               is `1` when the packet-id form matched MORE THAN
#                               ONE candidate slug (the `phase` / `phase-t2`
#                               collision below) and `0` otherwise -- ADDITIVE,
#                               field 4 on a line only ever read via `cut -f2`/
#                               `-f3` by every existing caller, so this cannot
#                               disturb check-task. Only task-status consumes
#                               it, and only to keep a collision from reading as
#                               `gone` (loop-measurement T2 Critical 2).
_resolve_task_id() {
  local task="$1" root="$2"
  local slug="" id="" ambiguous=0
  case "$task" in
    *'#'*)
      slug="${task%%#*}"
      id="${task#*#}"
      ;;
    *)
      : # resolved below, once we know gspec/ is even present to resolve against
      ;;
  esac

  if ! _has_gspec "$root"; then
    printf 'NOGSPEC\n'
    return 0
  fi

  if [ -n "$slug" ]; then
    # The canonical form's slug is caller-supplied text, not a resolved
    # filename -- unlike the packet-id form below, nothing guarantees it
    # stays inside gspec/. Reject a path separator or a '..'
    # component before any file test (ADR 0025 D1: the adapter's one write
    # is confined to the resolved plan path, and gspec 3.x's layout
    # INTERPOLATES the slug into a DIRECTORY name -- gspec/features/<slug>/
    # tasks.md -- so this check went from belt-and-braces to load-bearing when
    # that layout landed; task-status refuses the same
    # unsafe input even though it never writes, so the two callers cannot
    # silently diverge on it). This runs after the gspec-is-optional early
    # return above -- and can safely do so, because that return only ever
    # tests $root/gspec, never the caller-supplied slug -- so every
    # gspec-optional case still exits 0 regardless of what the caller passed
    # as a slug.
    case "$slug" in
      */*|*'..'*)
        printf 'REFUSED refusing a task id whose feature slug contains a path separator or '"'"'..'"'"' component (ADR 0025 D1)\n'
        return 0
        ;;
    esac
  fi

  if [ -z "$slug" ]; then
    # packet-id form: <feature>-<id>. Ids are NOT guaranteed to be hyphen-free
    # -- a legacy shape-B plan line (`- [ ] **ser-t1** ...`) has id `ser-t1`,
    # so peeling a trailing `-t<digits>` off the token is unsound (it would
    # read `ser-ser-t1` as slug `ser-ser`, id `t1`, and silently match
    # nothing). Resolve against the plan filenames that actually exist
    # instead: the token matches iff it is exactly "<slug>-<remainder>" for
    # some real plan basename, and the remainder is then the task id. This
    # also means the resolved slug is always a real basename on disk, so --
    # unlike the canonical form above -- it is structurally incapable of
    # containing a path separator or '..'; no separate check needed here.
    local best="" f cand matches=0
    while IFS=$'\t' read -r f cand; do
      [ -n "$cand" ] || continue
      case "$task" in
        "$cand"-*)
          # Prefer the LONGEST matching slug, so a feature whose slug itself
          # ends in -t<digits> (e.g. phase-t2, task phase-t2-t1) still
          # resolves to the right plan and id instead of the shorter decoy.
          # This is also why the ambiguity is safe for check-task: `nodes`
          # emits <feature>-<tolower(id)>, so feature `phase` task `t2-t1`
          # and feature `phase-t2` task `T1` both produce the node id
          # `phase-t2-t1` -- a pre-existing namespace collision. Longest-wins
          # always picks the longer slug here; when the live task is
          # actually in the shorter-slug plan, resolution against that
          # slug's id then fails and check-task's result is a loud rc=4 "no
          # such task", never a wrong flip. That argument does NOT transfer
          # to task-status, which has a silent success state (`gone`) that
          # check-task lacks -- so every candidate slug that matches is
          # counted, not just the longest, and the caller is told when more
          # than one did (see `ambiguous` below / loop-measurement T2
          # Critical 2).
          matches=$((matches + 1))
          if [ "${#cand}" -gt "${#best}" ]; then best="$cand"; fi
          ;;
      esac
    done < <(_plan_paths "$root")
    if [ -n "$best" ]; then
      slug="$best"
      id="${task#"$best"-}"
    fi
    [ "$matches" -gt 1 ] && ambiguous=1
  fi

  if [ -z "$slug" ] || [ -z "$id" ]; then
    printf 'UNRESOLVED\n'
    return 0
  fi

  printf 'RESOLVED\t%s\t%s\t%s\n' "$slug" "$id" "$ambiguous"
}

# _resolve_plan_path <slug> <root> — the plan-file location every caller shares,
# newest layout first: gspec/features/<slug>/tasks.md (3.x), then
# gspec/tasks/<slug>.md (2.x), then the pre-2.0 gspec/features/<slug>.plan.md.
# The promise this function made when it had two entries held when it grew to
# three: adding gspec 3.x's layout meant editing here and in the two enumerators,
# not in the nine places that used to build these paths inline. Prints
# "<plan>\t<relplan>" if any exists on disk, or nothing (empty output) if none
# does -- callers test for that emptiness.
_resolve_plan_path() {
  local slug="$1" root="$2"
  if [ -f "$root/gspec/features/$slug/tasks.md" ]; then
    printf '%s\t%s\n' "$root/gspec/features/$slug/tasks.md" "gspec/features/$slug/tasks.md"
  elif [ -f "$root/gspec/tasks/$slug.md" ]; then
    printf '%s\t%s\n' "$root/gspec/tasks/$slug.md" "gspec/tasks/$slug.md"
  elif [ -f "$root/gspec/features/$slug.plan.md" ]; then
    printf '%s\t%s\n' "$root/gspec/features/$slug.plan.md" "gspec/features/$slug.plan.md"
  fi
}

# _task_lookup <plan> <idlc> — the READ-ONLY duplicate-id lookup check-task and
# task-status share. Prefers the FIRST UNCHECKED match over an earlier checked
# one: a malformed plan with a duplicate id (`- [x] **T1**` sorted above
# `- [ ] **T1**`) must not report "already"/finished while leaving the real,
# unchecked task live for `nodes` to keep re-emitting forever. Only when no
# unchecked match exists anywhere in the file does an earlier checked match
# count as "already". Prints "flip <id>" (an unchecked match exists), "already
# <id>" (only checked matches exist), or nothing (no match at all).
_task_lookup() {
  local plan="$1" want="$2"
  awk -v want="$want" '
    /'"$_TASK_LINE_RE"'/ {
      desc = $0
      sub(/'"$_TASK_LINE_PREFIX"'/, "", desc)
      match(desc, /^'"$_TASK_ID_CLASS"'/)
      lid = substr(desc, 1, RLENGTH)
      if (tolower(lid) == want) {
        checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
        if (!checked) { print "flip " lid; found = 1; exit }
        if (checked_id == "") checked_id = lid
      }
    }
    END {
      if (!found && checked_id != "") print "already " checked_id
    }
  ' "$plan"
}

# _plan_task_line_count <plan> — how many task lines this adapter can actually
# PARSE in a plan file (loop-measurement T2 Critical 1). Uses `_TASK_LINE_RE`,
# the exact same pattern `_task_lookup` matches an id against -- NOT a second
# copy, per this repo's standing rule that a count from a different regex
# lies about precisely what it is asked to certify (see `cmd_plans`'s own
# counter, which duplicates this same pattern for the same reason). Zero means
# the plan is empty, truncated, mid-migration, or in a task-line shape this
# adapter has never learned -- every one of those is "we cannot tell", never
# positive evidence that a named task is gone.
_plan_task_line_count() {
  local plan="$1"
  awk '
    /'"$_TASK_LINE_RE"'/ { c++ }
    END { print c+0 }
  ' "$plan"
}

# _task_history_probe <relplan> <root> <idlc> <slug> — has a task line for
# <idlc> EVER existed anywhere in <slug>'s plan history, in ANY gspec layout
# (loop-measurement T2 "gone must require positive evidence")? Reuses
# `_TASK_LINE_PREFIX`/`_TASK_LINE_SUFFIX` -- the exact structural shape
# `_task_lookup`/`_plan_task_line_count` match, checkbox + bold id -- with the
# generic id class replaced by this call's literal, case-folded id, so a
# historical PROSE mention of the id text (a note, an acceptance criterion,
# "see also T77") can never read as positive evidence; only that exact shape,
# searched with `git log -i -G`, does. ONE `git log`, `--max-count=1` so the
# walk stops at the first hit rather than scanning full history -- this runs
# once per open packet id NOT found in its current plan, every sweep: 4 git
# invocations (is-inside-work-tree, ls-files, is-shallow-repository, log) for
# a genuinely missing id, and 0 for an id `_task_lookup` already resolved (the
# probe is never reached), so the cost is bounded to the case that actually
# needs it.
#
# Probes EVERY layout path for the slug in ONE `git log` invocation (3.x/2.x/
# pre-2.0 -- the same three paths `_resolve_plan_path` tries, newest first)
# rather than `git log --follow`, which was measurably WRONG here: `--follow`
# is similarity-based rename detection, and gspec plan files are boilerplate-
# heavy by construction (identical frontmatter, `# Plan:`, `## Plan`,
# `- [ ] **Tn** **P0** …`, `- deps: —`), so a commit that deletes ONE
# feature's plan and adds a DIFFERENT feature's plan gets paired as a rename
# well under 100% similarity -- reporting positive history for an id that was
# never a task in the plan actually being asked about. Multi-path probing has
# no such heuristic: every candidate path is only ever this SAME slug's plan
# under a different gspec layout, so a genuine 3.x relocation still resolves
# (its own commit touched that exact path) while a same-commit cross-feature
# swap does not (the id's pattern never touched the OTHER feature's path). Do
# not "fix" this with `-M100%` instead of dropping `--follow` -- this repo's
# own relocations are recorded R097-R099, not R100 (links were repaired
# during the move), so a 100% threshold would stop following the very rename
# it exists to handle. Prints exactly one of:
#   FOUND         a commit's diff added or removed a task line for this id,
#                 under any layout path for this slug
#   NEVER         history for every layout path is readable and holds no such
#                 line
#   UNAVAILABLE   not a git repo, git missing, the CURRENTLY RESOLVED plan
#                 file is untracked, or the repo is shallow (a "not found"
#                 there could be truncated rather than genuine) -- every one
#                 of these is "we cannot tell", never positive evidence
#                 either way.
# Every pathspec passed to git here is ROOT-RELATIVE (`gspec/...`, never
# `$root/gspec/...`) and matched under `git -C "$root"`: `-C` already moves
# git's effective cwd to `$root`, so a pathspec that re-prepends `$root` is
# resolved a SECOND time against that same directory whenever `$root` itself
# is relative (loop-measurement T2 Minor) -- `task-status ts#T99 ./sub`
# silently read `unknown` instead of `gone` because the old `$plan` argument
# carried the `$root/` prefix into the pathspec. An absolute `$root` masked
# this, which is how it shipped.
# Never lets a non-zero git exit escape under `set -euo pipefail` -- every
# invocation is guarded with `|| true` or an explicit early return.
_task_history_probe() {
  local relplan="$1" root="$2" idlc="$3" slug="$4"
  command -v git >/dev/null 2>&1 || { printf 'UNAVAILABLE\n'; return 0; }
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf 'UNAVAILABLE\n'; return 0; }

  # Untracked (never committed) reads UNAVAILABLE, not NEVER: an empty `git
  # log` result for a file with no history at all is not evidence the id was
  # never there, it is evidence there is no history to check. Tested against
  # the CURRENTLY RESOLVED plan path (the one this call already knows is
  # real), not the other layouts' candidate paths below, which may never have
  # existed for this slug at all.
  git -C "$root" ls-files --error-unmatch -- "$relplan" >/dev/null 2>&1 \
    || { printf 'UNAVAILABLE\n'; return 0; }

  local shallow
  shallow="$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null || true)"

  # `-G` takes an EXTENDED regex, not the BRE the old class assumed (loop-
  # measurement T2 Important 1): an unescaped `( ) | + ? { }` changes what the
  # pattern MATCHES rather than erroring, which is the dangerous direction --
  # `pr#T5|T77` and `pr#T(5)` both misread a still-live line as `gone` before
  # this class covered them.
  local esc pattern hit
  esc="$(printf '%s' "$idlc" | sed 's/[][\.*^$/(){}|+?]/\\&/g')"
  pattern="${_TASK_LINE_PREFIX}${esc}${_TASK_LINE_SUFFIX}"
  hit="$(git -C "$root" log -i -G"$pattern" --max-count=1 --format=%H -- \
    "gspec/features/$slug/tasks.md" \
    "gspec/tasks/$slug.md" \
    "gspec/features/$slug.plan.md" 2>/dev/null || true)"

  if [ -n "$hit" ]; then
    printf 'FOUND\n'
  elif [ "$shallow" = "true" ]; then
    printf 'UNAVAILABLE\n'
  else
    printf 'NEVER\n'
  fi
}

# --- handoff: everything an agent needs to start a packet --------------------
# (thin-loop-driver T2 / ADR 0020 D2 amendment, 2026-09-15; hardened in review,
# 2026-09-15.) Three helpers, read-only, each reusing a shared piece rather
# than copying it:
#   _task_record     the task-line shape, via the SAME `_TASK_LINE_RE` family
#                     `_task_lookup`/`_plan_task_line_count` already share —
#                     never a second regex for "what is a task line". Captures
#                     the FULL multi-line task body, not just the header's
#                     inline text — the handoff is the implementer's whole
#                     brief, so a nested bullet or a trailing paragraph must
#                     not be silently dropped.
#   _prd_capability   an exact (trimmed, unguessed) match of a `covers:` quote
#                     against a PRD capability line, plus that capability's
#                     sub-bullet block, verbatim.
#   _split_covers     the `' · '` (U+00B7) separator `covers:` uses for more
#                     than one capability, matched by its UTF-8 octal escape
#                     (`\302\267`) rather than a literal multibyte character in
#                     source — the same reason `_nodes_for` matches the em dash
#                     as `\342\200\224` rather than `—` (:719).
# Every value that can hold arbitrary plan/PRD text (a covers quote, task
# text) is passed to awk through `ENVIRON`, never `awk -v` — this repo's
# standing rule (see runstate.sh's `cmd_set`): `-v` runs escape-sequence
# processing on the VALUE, so a quote containing `\d` or similar reads as
# something other than what is on disk, corrupting a match silently rather
# than loudly.
# File SCOPE is deliberately not reparsed here at all: `cmd_handoff` calls
# `_nodes_for` itself and reads the row it already computes for this packet
# id, which is what "share the code path, do not copy it" means for the
# files: > sidecar > empty precedence — there is no second copy of that
# precedence anywhere in this section.

# _task_record <plan> <idlc> — everything `handoff` needs about the first task
# line whose id, case-folded, equals <idlc>: checked state, the plan's own
# literal id text (not <idlc>, so a caller gets the real casing regardless of
# how it typed the lookup), the header line's own inline text (marker-stripped
# exactly as `_nodes_for` strips it — [P] / **P<n>** / [GATE:...] — the same
# clean description `_nodes_for` uses for its fingerprint comparison), the raw
# `- covers:` value (unsplit — `_split_covers` is the one place that
# ' · '-splits it), and the task's FULL BODY: every line between the header
# and the next task line, EXCLUDING the `- deps:` / `- covers:` / `- arch:` /
# `- files:` / `- supersedes:` metadata lines. Nested bullets and a trailing
# paragraph are body, not metadata, and are captured verbatim, in order.
# Prints nothing when <idlc> is not a task in <plan>.
#
# Output is line-oriented, NEVER one row split with `cut`: one `KEY<TAB>value`
# line per header field (CHECKED, ID, COVERS, TEXT), then a bare `BODY` line,
# then the task's body lines verbatim, one per output line. A `cut -f<n>`
# against a single joined row is exactly what a tab embedded in free text (a
# task's own text, or a covers quote) would silently corrupt — shifting every
# later field — so this shape makes that structurally impossible instead of
# merely unlikely; `cmd_handoff` reads each header line with a first-tab
# split, whose remainder half keeps any further embedded tab in the value
# intact.
_task_record() {
  local plan="$1" want="$2"
  WANT="$want" awk '
    /'"$_TASK_LINE_RE"'/ {
      if (found) exit
      desc = $0
      sub(/'"$_TASK_LINE_PREFIX"'/, "", desc)
      match(desc, /^'"$_TASK_ID_CLASS"'/)
      lid = substr(desc, 1, RLENGTH)
      if (tolower(lid) != ENVIRON["WANT"]) { in_target = 0; next }
      in_target = 1; found = 1; realid = lid
      checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
      desc = substr(desc, RLENGTH + 1)
      sub(/^\*\*/, "", desc)                  # canonical/B: bold closed after the id
      sub(/^[[:space:]]*\[P\][[:space:]]*/, "", desc)
      sub(/^[[:space:]]*\*\*P[0-9]+\*\*[[:space:]]*/, "", desc)
      sub(/^[[:space:]]*\*\*\[GATE:[^]]*\]\*\*[[:space:]]*/, "", desc)
      sub(/^[[:space:]]*`?\[GATE:[^]]*\]`?[[:space:]]*/, "", desc)
      sub(/^[[:space:]]+/, "", desc)
      taskdesc = desc
      next
    }
    in_target && /^[[:space:]]+-[[:space:]]*covers[[:space:]]*:/ {
      l = $0; sub(/^[[:space:]]+-[[:space:]]*covers[[:space:]]*:[[:space:]]*/, "", l); covers = l
      next
    }
    # Everything else this plan line-shape uses is metadata, not body.
    in_target && /^[[:space:]]+-[[:space:]]*(deps|arch|files|supersedes)[[:space:]]*:/ { next }
    # Any other line while inside the target task -- a nested bullet, its
    # wrapped continuation, a blank separator, or a trailing paragraph -- is
    # body, captured verbatim and in order. A markdown heading ends the task
    # (the same rule _prd_capability uses): a `## Phase 2` or `## Notes` section
    # after a task is plan structure, never part of the task body.
    in_target && /^#/ { in_target = 0; next }
    in_target { bn++; body[bn] = $0 }
    END {
      if (!found) exit
      while (bn > 0 && body[bn] ~ /^[[:space:]]*$/) bn--   # trailing blanks are separators
      printf "CHECKED\t%s\n", checked
      printf "ID\t%s\n", realid
      printf "COVERS\t%s\n", covers
      printf "TEXT\t%s\n", taskdesc
      print "BODY"
      for (i = 1; i <= bn; i++) print body[i]
    }
  ' "$plan"
}

# _prd_capability <prd> <text> — is <text> (outer whitespace trimmed) the
# verbatim text of some `- [ ] **P<n>**: <text>` capability line in <prd>? No
# other normalization: a `covers:` quote is expected to be copied verbatim
# from the PRD, and a near-match is exactly the guess AC2 forbids. Prints
# "MATCH" followed by every physical line of that capability's sub-bullet
# block, verbatim — a wrapped multi-line bullet reproduces whole, across as
# many output lines as it has in the source — or "NOMATCH" alone. Recognizes
# only the canonical `**P<n>**:` capability shape (what `/gspec-feature`
# writes); the legacy `**P0 — text**` shape `_feature_done` also accepts has
# no reliable sub-bullet shape of its own to reproduce, so a quote against a
# legacy PRD correctly reads NOMATCH rather than guessing at one.
#
# Block-boundary rule (deliberately precise, not "blank line ends it"): the
# block ends at the NEXT capability line, at a heading (`^#`), or at the
# first line that is neither blank nor indented. A blank line is buffered,
# not decided on immediately — if the next line is still indented, the blank
# was interior to a wrapped multi-paragraph bullet and is flushed back in; if
# the next line is unindented (a stray top-level bullet, a new section, EOF),
# the buffered blank is discarded and the block ends there without ever
# printing that top-level line. This is also why `if (found) exit` on the
# NEXT capability-line match matters and is covered by a sweep case: `found`
# is sticky (never reset once a match is made), so without that `exit`,
# `inblock` would stay 1 across a later NON-matching capability line and its
# body would bleed into this one's block.
#
# Anchoring divergence from `_CAPABILITY_LINE_RE` above, recorded rather than
# aligned (completion-record-drift-gaps-t6): this matcher's opening pattern is
# anchored `^-` -- column 0 only -- while `_CAPABILITY_LINE_RE`
# (`_feature_done`'s and `_prd_capabilities`'s pattern) admits leading
# whitespace. An indented but otherwise canonical capability line is
# therefore enumerated by `_prd_capabilities` and declined here, so in the
# capability-drift walk it is always reported `uncovered-capability` plus one
# `unmatched-quote` per covering task, never `DRIFT=`, whichever way its
# covering tasks are checked. Widening this anchor to admit leading
# whitespace, to match `_CAPABILITY_LINE_RE`, would move the
# indentation-based block boundary above: it assumes the capability header
# sits at column 0, so any indented line is unambiguously a sub-bullet of it;
# letting the header itself sit at some indent N breaks that assumption,
# since a sibling line at that same indent N -- not a sub-bullet at all --
# would satisfy the same "is this line indented" test and get swallowed into
# the block, corrupting the criteria `cmd_handoff` reads to tell a packet
# what done means. Neither pattern changes here.
_prd_capability() {
  local prd="$1" want="$2"
  if [ ! -f "$prd" ]; then printf 'NOMATCH\n'; return 0; fi
  WANT="$want" awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^-[[:space:]]*\[[ xX]\][[:space:]]*\*\*P[0-9]+\*\*:/ {
      if (found) exit
      t = $0
      sub(/^-[[:space:]]*\[[ xX]\][[:space:]]*\*\*P[0-9]+\*\*:[[:space:]]*/, "", t)
      if (trim(t) == ENVIRON["WANT"]) { found = 1; print "MATCH" }
      inblock = found
      pend = 0
      next
    }
    inblock && /^#/ { exit }
    inblock && /^[[:space:]]*$/ { pend++; next }
    inblock && /^[[:space:]]+/ {
      while (pend > 0) { print ""; pend-- }
      print
      next
    }
    inblock { exit }   # unindented, non-blank, non-heading: the block ends here, unabsorbed
    END { if (!found) print "NOMATCH" }
  ' "$prd"
}

# _split_covers <covers> — one trimmed capability quote per line, splitting on
# `' · '` (U+00B7, matched by its UTF-8 octal escape \302\267 rather than a
# literal multibyte character in source — see the section header). Prints
# nothing for an empty value or the "no covers" sentinels `_nodes_for` already
# recognizes for `deps:` (`-`, the octal-escaped em dash) — `cmd_handoff`
# prints `COVERS=none` for that case, since nothing here reads that as
# distinct from a real, single, empty-after-split quote.
_split_covers() {
  local s="$1"
  [ -n "$s" ] || return 0
  S="$s" awk '
    BEGIN {
      s = ENVIRON["S"]
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (s == "" || s == "-" || s == "\342\200\224") exit
      n = split(s, a, " \302\267 ")
      for (i = 1; i <= n; i++) {
        v = a[i]
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v != "") print v
      }
    }
  '
}

# --- capability-drift: has a finished plan outrun its own PRD checkbox? -----
# (completion-record-drift-t1.) Read-only. A capability is DRIFT when every
# plan task covering it is checked while the capability's own box is not --
# the state a feature enters the instant its last covering task lands and
# nothing flips the capability. Built entirely from the existing seam:
# `_prd_paths` to enumerate features, `_resolve_prd_path`/`_resolve_plan_path`
# to locate one feature's PRD/plan pair (a feature with no plan is OUT OF
# SCOPE, not unjudgeable -- the intended state for undecomposed work),
# `_CAPABILITY_LINE_RE` (`_feature_done`'s own pattern, so this tests the
# SAME thing that function counts), `_TASK_LINE_RE`, and `_split_covers` /
# `_prd_capability` for the plan side -- no new parser, no fourth copy of an
# existing pattern.
#
# Anything the scan cannot judge is UNJUDGEABLE, never drift -- never folded
# into a clean-looking zero:
#   unmatched-quote          a `covers:` quote matches no PRD capability at
#                            all. The adapter already refuses to guess at the
#                            nearest capability for an unmatched quote
#                            (`cmd_handoff`'s `UNMATCHED=`); reading one as
#                            drift would turn that same guess back on.
#   uncovered-capability     an unchecked capability that no task's covers
#                            references, in a plan the adapter DID resolve --
#                            no covering task means no positive evidence of
#                            delivery, so absence of evidence is not read as
#                            completion.
#   unrecognized-capability  an unchecked capability line `_prd_capability`'s
#                            verbatim matcher declines (the legacy
#                            `**P0 — text**` shape `_feature_done` still
#                            counts toward completion but this matcher does
#                            not, since it has no reliable verbatim text of
#                            its own to reproduce).
# A capability with at least one UNCHECKED covering task is reported as
# NEITHER: a feature legitimately sitting part-ticked mid-flight is the
# likelier shape, and it is exactly what a per-feature test (no unchecked
# task lines and no checked capabilities) cannot see.

# _prd_capabilities <prd> — one line per capability line matched by
# `_CAPABILITY_LINE_RE`: <checked>\t<canonical>\t<text>. <canonical> is 1
# when the line also matches `_prd_capability`'s stricter `**P<n>**:` shape,
# and <text> is then that capability's own verbatim text -- the same string
# a `covers:` quote must equal, verbatim, to MATCH it there. <canonical> is 0
# for the legacy `**P0 — text**` shape, and <text> is then only a DISPLAY
# label (there is no verbatim text to match a quote against, which is
# exactly why `_prd_capability` declines it).
_prd_capabilities() {
  local prd="$1"
  [ -f "$prd" ] || return 0
  awk '
    /'"$_CAPABILITY_LINE_RE"'/ {
      checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
      rest = $0
      sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*P[0-9]+/, "", rest)
      canonical = 0
      text = rest
      if (rest ~ /^\*\*:/) {
        canonical = 1
        sub(/^\*\*:[[:space:]]*/, "", text)
      } else {
        sub(/^[[:space:]]*/, "", text)
        sub(/\*\*[[:space:]]*$/, "", text)
      }
      sub(/[[:space:]]+$/, "", text)
      printf "%s\t%s\t%s\n", checked, canonical, text
    }
  ' "$prd"
}

# _plan_task_covers <plan> — one line per task line matched by
# `_TASK_LINE_RE`: <checked>\t<covers-raw>, unsplit -- `_split_covers` is the
# one place that separates a multi-capability `covers:` value. The same
# `- covers:` sub-line shape `_task_record` already extracts, reused rather
# than re-derived.
_plan_task_covers() {
  local plan="$1"
  [ -f "$plan" ] || return 0
  awk '
    function flush() { if (started) printf "%s\t%s\n", checked, covers }
    /'"$_TASK_LINE_RE"'/ {
      flush()
      checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
      covers = ""
      started = 1
      next
    }
    started && /^[[:space:]]+-[[:space:]]*covers[[:space:]]*:/ {
      l = $0; sub(/^[[:space:]]+-[[:space:]]*covers[[:space:]]*:[[:space:]]*/, "", l); covers = l
      next
    }
    END { flush() }
  ' "$plan"
}

# _capability_drift_for <root> <slug> <prd> <plan> — the per-feature scan.
# Prints only `DRIFT=`/`UNJUDGEABLE=` lines, in the output contract fixed by
# `gspec/features/completion-record-drift/tasks.md` (binding on all five
# tasks in that plan):
#   DRIFT=<slug>\t<capability text>
#   UNJUDGEABLE=<class>\t<slug>\t<detail>
# `cmd_capability_drift` counts by grepping its own accumulated output rather
# than threading counters back through a subshell (this runs inside a pipe
# to `tee`).
_capability_drift_for() {
  local root="$1" slug="$2" prd="$3" plan="$4"

  local caps; caps="$(mktemp)"
  _prd_capabilities "$prd" > "$caps"

  local matched; matched="$(mktemp)"

  # `unmatched-quote` stays per TASK, deliberately not deduplicated against
  # earlier quotes in this feature: it is evidence about the task that wrote
  # a covers: quote matching nothing, not about any one capability, and the
  # two per-capability classes below already get their natural one-row-per-
  # capability shape from `_prd_capabilities`'s own enumeration.
  local tchecked craw q capout first
  while IFS=$'\t' read -r tchecked craw; do
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      capout="$(_prd_capability "$prd" "$q")"
      first="${capout%%$'\n'*}"
      if [ "$first" = "MATCH" ]; then
        printf '%s\t%s\n' "$q" "$tchecked" >> "$matched"
      else
        printf 'UNJUDGEABLE=unmatched-quote\t%s\t%s\n' "$slug" "$q"
      fi
    done < <(_split_covers "$craw")
  done < <(_plan_task_covers "$plan")

  local ccapchecked ccanonical ctext bits
  while IFS=$'\t' read -r ccapchecked ccanonical ctext; do
    [ "$ccapchecked" = "0" ] || continue
    if [ "$ccanonical" != "1" ]; then
      printf 'UNJUDGEABLE=unrecognized-capability\t%s\t%s\n' "$slug" "$ctext"
      continue
    fi
    bits="$(TXT="$ctext" awk -F'\t' '$1==ENVIRON["TXT"]{print $2}' "$matched")"
    if [ -z "$bits" ]; then
      printf 'UNJUDGEABLE=uncovered-capability\t%s\t%s\n' "$slug" "$ctext"
    elif ! grep -qx '0' <<< "$bits"; then
      printf 'DRIFT=%s\t%s\n' "$slug" "$ctext"
    fi
  done < "$caps"

  rm -f "$caps" "$matched"
  return 0
}

# cmd_capability_drift [root] — walk every feature whose PRD AND plan both
# resolve and report the capability-level drift described above, ending with
# `CAPABILITY_DRIFT=ok|attention drift=<n> unjudgeable=<m>` (the same
# `<status> field=value...` shape `files-status`'s `FILES=` line already
# uses; `attention` whenever either count is nonzero). `CAPABILITY_DRIFT=none`
# plus a `NOTE=` line only for the no-`gspec/` case (D4: gspec is optional,
# the same `<KEY>=none`/`NOTE=` shape `files-status` uses) -- every other
# path, including a clean scan, prints the counted summary. Exits 0 always:
# this is a report, never a gate.
cmd_capability_drift() {
  local root; root="$(_root "${1:-}")"
  if ! _has_gspec "$root"; then
    printf 'CAPABILITY_DRIFT=none\n'
    printf 'NOTE=no gspec/ directory — gspec is optional (ADR 0020 D4)\n'
    return 0
  fi

  local acc; acc="$(mktemp)"
  local prd slug pp plan prdpp prdabs
  while IFS= read -r prd; do
    [ -n "$prd" ] && [ -f "$prd" ] || continue
    case "$prd" in
      */prd.md) slug="$(basename "$(dirname "$prd")")" ;;
      *)        slug="$(basename "$prd" .md)" ;;
    esac

    pp="$(_resolve_plan_path "$slug" "$root")"
    [ -n "$pp" ] || continue   # no plan: out of scope, not unjudgeable
    plan="$(printf '%s' "$pp" | cut -f1)"

    prdpp="$(_resolve_prd_path "$slug" "$root")"
    prdabs="$(printf '%s' "$prdpp" | cut -f1)"
    [ -n "$prdabs" ] || prdabs="$prd"

    # A feature that reads as complete under the SAME derivation the rest of
    # this adapter already applies (`_feature_done`: >=1 recognized capability
    # line, none unchecked) contributes nothing to the scan: a checked box IS
    # the reconciled state, so the scan's question — should this box be
    # checked — is already answered for every capability the feature has. No
    # `DRIFT=` finding is lost by skipping, since the drift condition
    # (`ccapchecked = "0"`, gating only the SECOND loop in
    # `_capability_drift_for`) is reachable only from an unchecked capability.
    # `UNJUDGEABLE=unmatched-quote` rows from the FIRST loop carry no such
    # gate and ARE suppressed by this skip — intended, per this capability's
    # own wording ("no `UNJUDGEABLE=` line of any class"), not an oversight.
    # This is deliberately the SAME test `cmd_features` uses for completion,
    # not a second guess or a fourth copy of the capability pattern — the
    # justification is that property alone, never how many rows this happens
    # to remove in any one repository.
    [ "$(_feature_done "$prdabs")" = "1" ] && continue

    _capability_drift_for "$root" "$slug" "$prdabs" "$plan" | tee -a "$acc"
  done < <(_prd_paths "$root")

  local drift unjudgeable
  drift="$(grep -c '^DRIFT=' "$acc" 2>/dev/null || true)"
  unjudgeable="$(grep -c '^UNJUDGEABLE=' "$acc" 2>/dev/null || true)"
  rm -f "$acc"
  drift="${drift:-0}"; unjudgeable="${unjudgeable:-0}"
  printf 'CAPABILITY_DRIFT=%s drift=%d unjudgeable=%d\n' \
    "$([ "$drift" -eq 0 ] && [ "$unjudgeable" -eq 0 ] && printf ok || printf attention)" \
    "$drift" "$unjudgeable"
}

# --- complete-capabilities: flip a feature's finished capabilities ----------
# (capability-auto-complete-t1). WRITE -- a second write site alongside
# check-task's task-line flip (ADR 0025 D1): `check-task` remains the only
# writer of a TASK line, and this is the only writer of a CAPABILITY line; the
# two never touch the same line of the same file.
#
# Walks the SAME derivation `_capability_drift_for` walks -- built from
# `_prd_capabilities` / `_plan_task_covers` / `_split_covers` / `_prd_capability`
# -- rather than calling `_capability_drift_for` itself: that function's own
# `UNJUDGEABLE=unmatched-quote` line drops the covering task's checked state
# (a read-only report has no need of it -- an unmatched quote is unjudgeable
# either way), but the flip rule below needs exactly that bit, so this
# rebuilds the same walk from its four low-level pieces rather than widen
# `_capability_drift_for`'s own output shape for one caller.
# `_capability_drift_for`/`cmd_capability_drift` are UNTOUCHED by this --
# same functions, same output, still read-only, same checksum-pinned
# no-write guarantee its own sweep case already covers.
#
# Flip rule:
#   - flips a capability iff `_capability_drift_for` would print
#     `DRIFT=<slug>\t<capability text>` for it: >=1 covering task, all
#     checked, canonical (`**P<n>**:`) text. Never an uncovered-capability or
#     unrecognized-capability row -- neither ever reaches the flip branch.
#   - never unflips a checked capability -- only an UNCHECKED capability
#     (`ccapchecked=="0"`) is ever considered, so this is structural, not a
#     second check.
#   - a feature with an UNCHECKED task whose `covers:` quote matches no
#     capability holds EVERY flip, never a partial one: a typo'd quote may be
#     evidence against a capability that would otherwise flip, and a flip is
#     never undone once applied. The SAME quote on an already-CHECKED task
#     holds nothing -- it is stale evidence about a task that is itself
#     already done, not a live signal about what is still in flight.
#
# Output:
#   COMPLETE_CAPABILITIES=<ok|blocked|none> completed=<n>
#   COMPLETED=<slug>\t<capability text>     (n lines, PRD order)
#   FILE=<relprd>                           (present whenever the feature resolved)
#   REASON=...                              (blocked / none / unresolved)
#
# Exit codes mirror check-task (ADR 0025 D1):
#   0   no gspec/ at all (skipped, D4 -- gspec is optional), or a resolved
#       feature with zero or more capabilities flipped (blocked or ok)
#   1   a malformed slug -- a path separator or '..' component, which would
#       interpolate into a DIRECTORY name under gspec 3.x -- REFUSED, `die`d
#   4   the slug has no resolvable PRD+plan pair in any gspec layout: genuine
#       drift in the caller's own argument, distinguishable from the skip
#
# Writes with check-task's read-only-lookup-then-`sub()` shape: every flip
# target is decided by the read-only walk above, and the mutating awk pass
# re-confirms each target is still an unchecked, canonical capability line
# before touching it -- so only the flipped lines' checkbox characters
# change, byte-identical otherwise, through the same atomic
# temp-file-then-`mv` write check-task uses.
cmd_complete_capabilities() {
  local slug="${1:-}"; [ -n "$slug" ] || die "complete-capabilities: need a feature slug"
  local root; root="$(_root "${2:-}")"

  if ! _has_gspec "$root"; then
    printf 'COMPLETE_CAPABILITIES=none completed=0\n'
    printf 'REASON=no gspec/ directory — gspec is optional (ADR 0020 D4)\n'
    return 0
  fi

  # Same guard `_resolve_task_id`'s canonical-form branch applies to a
  # caller-supplied slug (ADR 0025 D1): gspec 3.x interpolates it into a
  # DIRECTORY name (gspec/features/<slug>/...), so a path separator or '..'
  # component is refused before any file test. Runs AFTER the gspec-optional
  # early return, for the same reason that ordering holds there: every
  # gspec-optional case must still exit 0 regardless of what was passed.
  case "$slug" in
    */*|*'..'*)
      die "complete-capabilities: refusing a feature slug containing a path separator or '..' component (ADR 0025 D1)"
      ;;
  esac

  local prdpp prdabs relprd
  prdpp="$(_resolve_prd_path "$slug" "$root")"
  prdabs="$(printf '%s' "$prdpp" | cut -f1)"
  relprd="$(printf '%s' "$prdpp" | cut -f2)"

  local pp plan
  pp="$(_resolve_plan_path "$slug" "$root")"
  plan="$(printf '%s' "$pp" | cut -f1)"

  if [ -z "$prdabs" ] || [ -z "$plan" ]; then
    printf 'COMPLETE_CAPABILITIES=none completed=0\n'
    printf 'REASON=feature %s has no resolvable PRD and plan pair in any gspec layout\n' "$slug"
    return 4
  fi

  # A feature already fully done (`_feature_done` -- ADR 0020 D2, never a
  # second guess) has nothing unchecked left to flip. Skipped entirely, same
  # as `cmd_capability_drift`'s own skip and for the same reason: the walk
  # below would otherwise raise a hold from a long-checked task's unmatched
  # quote with nothing left to flip anything against.
  if [ "$(_feature_done "$prdabs")" = "1" ]; then
    printf 'COMPLETE_CAPABILITIES=ok completed=0\n'
    printf 'FILE=%s\n' "$relprd"
    return 0
  fi

  local caps; caps="$(mktemp)"
  _prd_capabilities "$prdabs" > "$caps"
  local matched; matched="$(mktemp)"

  local hold=0 tchecked craw q capout first
  while IFS=$'\t' read -r tchecked craw; do
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      capout="$(_prd_capability "$prdabs" "$q")"
      first="${capout%%$'\n'*}"
      if [ "$first" = "MATCH" ]; then
        printf '%s\t%s\n' "$q" "$tchecked" >> "$matched"
      elif [ "$tchecked" = "0" ]; then
        hold=1
      fi
    done < <(_split_covers "$craw")
  done < <(_plan_task_covers "$plan")

  if [ "$hold" = "1" ]; then
    printf 'COMPLETE_CAPABILITIES=blocked completed=0\n'
    printf 'REASON=%s has an unchecked task whose covers: quote matches no capability — holding every flip until it is fixed\n' "$slug"
    printf 'FILE=%s\n' "$relprd"
    rm -f "$caps" "$matched"
    return 0
  fi

  local texts; texts="$(mktemp)"
  local ccapchecked ccanonical ctext bits
  while IFS=$'\t' read -r ccapchecked ccanonical ctext; do
    [ "$ccapchecked" = "0" ] || continue
    [ "$ccanonical" = "1" ] || continue
    bits="$(TXT="$ctext" awk -F'\t' '$1==ENVIRON["TXT"]{print $2}' "$matched")"
    [ -n "$bits" ] || continue
    grep -qx '0' <<< "$bits" && continue
    printf '%s\n' "$ctext" >> "$texts"
  done < "$caps"
  rm -f "$caps" "$matched"

  local n; n="$(wc -l < "$texts" | tr -d '[:space:]')"
  n="${n:-0}"
  if [ "$n" -eq 0 ]; then
    printf 'COMPLETE_CAPABILITIES=ok completed=0\n'
    printf 'FILE=%s\n' "$relprd"
    rm -f "$texts"
    return 0
  fi

  # Atomic write, same shape as check-task: build into a temp file beside the
  # PRD, then `mv` over it so a reader never observes a partial write.
  # GLOBALS, deliberately -- see check-task's own comment on the bash
  # 3.2-vs-5.2 EXIT-trap scoping difference this guards against; do not make
  # these `local` again.
  _cc_tmp=""; _cc_tmp2=""
  _cc_tmp="$(mktemp "$(dirname "$prdabs")/.gspec-complete-cap.XXXXXX")"
  trap 'for _f in "${_cc_tmp:-}" "${_cc_tmp2:-}"; do [ -n "$_f" ] && rm -f "$_f"; done; :' EXIT
  local tmp; tmp="$_cc_tmp"
  cp -p "$prdabs" "$tmp"

  # Re-derives, for the write pass only, exactly the checked/canonical/text
  # triple `_prd_capabilities` already computed above -- the same duplication
  # check-task accepts between its own read (`_task_lookup`) and write
  # passes, so the write re-confirms a target is still unchecked immediately
  # before flipping it rather than trusting a stale read.
  awk -v targetsfile="$texts" '
    BEGIN {
      while ((getline line < targetsfile) > 0) if (line != "") want[line]++
      close(targetsfile)
    }
    /'"$_CAPABILITY_LINE_RE"'/ {
      checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
      rest = $0
      sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*P[0-9]+/, "", rest)
      canonical = 0; text = rest
      if (rest ~ /^\*\*:/) { canonical = 1; sub(/^\*\*:[[:space:]]*/, "", text) }
      else { sub(/^[[:space:]]*/, "", text); sub(/\*\*[[:space:]]*$/, "", text) }
      sub(/[[:space:]]+$/, "", text)
      if (!checked && canonical == 1 && (text in want) && want[text] > 0) {
        line = $0
        sub(/\[ \]/, "[x]", line)
        print line
        want[text]--
        next
      }
    }
    { print }
  ' "$prdabs" > "$tmp"

  # Same no-trailing-newline guard as check-task: awk's print always
  # terminates the record it writes, so a PRD lacking a final newline would
  # otherwise gain one byte here.
  if [ -n "$(tail -c1 "$prdabs")" ]; then
    local sz; sz="$(wc -c < "$tmp")"; sz=$((sz - 1))
    _cc_tmp2="$(mktemp "$(dirname "$prdabs")/.gspec-complete-cap.XXXXXX")"
    head -c "$sz" "$tmp" > "$_cc_tmp2"
    cat "$_cc_tmp2" > "$tmp"
    rm -f "$_cc_tmp2"; _cc_tmp2=""
  fi

  mv "$tmp" "$prdabs"
  trap - EXIT

  printf 'COMPLETE_CAPABILITIES=ok completed=%d\n' "$n"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    printf 'COMPLETED=%s\t%s\n' "$slug" "$t"
  done < "$texts"
  printf 'FILE=%s\n' "$relprd"
  rm -f "$texts"
}

# _handoff_one <packet-id> [root] — the block for exactly ONE task id, byte-
# identical to what `cmd_handoff` printed before bundling existed (packet-
# bundling-t5 renamed this function; its body is otherwise untouched). See the
# `handoff` entry in the header Subcommands list for the full output-shape and
# exit-code contract. Output:
#   PACKET=<feature>-<id>
#   FEATURE=<slug>
#   ID=<the plan's own literal task id>
#   CHECKED=<0|1>
#   TEXT=<the task header's own inline text>
#     <body line, 2-space indented, one per following output line>
#     ...                                    (present only when the task has
#                                              a body beyond its header line)
#   FILES=<pipe-separated, or empty>
#   NOTE=...                                 (present only when CHECKED=1)
#   COVERS=<capability 1 text>
#     <criterion line, 2-space indented, verbatim, possibly several>
#   COVERS=<capability 2 text>
#     ...
#   COVERS=none                              (in place of the COVERS= blocks
#                                              above, when the task declares
#                                              no covers: at all)
#   UNMATCHED=<covers quote matching no PRD capability>   (zero or more)
#   PRD=<relpath, or "none">
#   ARCH=<relpath, or "absent">
_handoff_one() {
  local task="${1:-}"; [ -n "$task" ] || die "handoff: need a packet id"
  local root; root="$(_root "${2:-}")"

  local resolved; resolved="$(_resolve_task_id "$task" "$root")"
  case "$resolved" in
    NOGSPEC)
      printf 'HANDOFF=unknown\nREASON=no gspec/ directory — gspec is optional (ADR 0020 D4)\n'
      return 0
      ;;
    UNRESOLVED)
      printf 'HANDOFF=unknown\nREASON=not a gspec task id — no plan resolves this packet\n'
      return 0
      ;;
    REFUSED\ *)
      die "handoff: ${resolved#REFUSED }"
      ;;
  esac

  local slug id
  slug="$(printf '%s' "$resolved" | cut -f2)"
  id="$(printf '%s' "$resolved" | cut -f3)"

  local pp plan relplan
  pp="$(_resolve_plan_path "$slug" "$root")"
  if [ -n "$pp" ]; then
    plan="$(printf '%s' "$pp" | cut -f1)"; relplan="$(printf '%s' "$pp" | cut -f2)"
  else
    printf 'HANDOFF=unknown\nREASON=no plan file for feature %s in any gspec layout\n' "$slug"
    return 0
  fi

  local idlc; idlc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  local rec; rec="$(_task_record "$plan" "$idlc")"
  if [ -z "$rec" ]; then
    printf 'HANDOFF=unknown\nREASON=%s has no task %s in %s\n' "$slug" "$id" "$relplan"
    return 0
  fi

  # Parse _task_record's line-oriented output: header KEY<TAB>value lines,
  # then a bare BODY line, then the task's body lines verbatim. Never `cut`
  # against a joined row — see _task_record's own comment for why. Splitting
  # on the FIRST tab (parameter expansion, not a second `read`) keeps any
  # further embedded tab in a value intact, the same remainder-capture
  # `_resolve_task_id`'s callers already rely on `read` for elsewhere.
  local checked="" realid="" covers="" text="" mode="header" line key val body=""
  while IFS= read -r line; do
    if [ "$mode" = "header" ]; then
      if [ "$line" = "BODY" ]; then
        mode="body"
        continue
      fi
      key="${line%%$'\t'*}"
      val="${line#*$'\t'}"
      case "$key" in
        CHECKED) checked="$val" ;;
        ID)      realid="$val" ;;
        COVERS)  covers="$val" ;;
        TEXT)    text="$val" ;;
      esac
    else
      body="${body}${line}"$'\n'
    fi
  done <<EOF
$rec
EOF

  # Share the code path: ask `nodes` itself for this packet's row rather than
  # a second copy of its files: > sidecar > empty precedence. Reads the whole
  # stream to END rather than an early `exit` on match — an early-closing
  # consumer on the right of a pipe can SIGPIPE a still-writing producer
  # under `pipefail`, the exact shape this repo has been bitten by before
  # (see the `trim-note` flake in CLAUDE.md). `nodes` never emits a row for a
  # CHECKED task (it is not a backlog node), so a checked task's scope is
  # always empty here — documented below via NOTE=, not silently
  # indistinguishable from "an unchecked task with no scope".
  local files=""
  if [ "$checked" = "0" ]; then
    files="$(_nodes_for "$root" "$slug" | WANT="${slug}-${idlc}" awk -F'\t' '
      $1 == ENVIRON["WANT"] { f = $3 }
      END { print f }
    ')"
  fi

  local prdpp prdrel prdabs
  prdpp="$(_resolve_prd_path "$slug" "$root")"
  prdabs="$(printf '%s' "$prdpp" | cut -f1)"
  prdrel="$(printf '%s' "$prdpp" | cut -f2)"
  [ -n "$prdrel" ] || prdrel="none"

  local archrel="absent"
  [ -f "$root/gspec/features/$slug/arch.md" ] && archrel="gspec/features/$slug/arch.md"

  printf 'PACKET=%s-%s\n' "$slug" "$idlc"
  printf 'FEATURE=%s\n' "$slug"
  printf 'ID=%s\n' "$realid"
  printf 'CHECKED=%s\n' "$checked"
  printf 'TEXT=%s\n' "$text"
  if [ -n "$body" ]; then
    printf '%s' "$body" | while IFS= read -r line; do
      printf '  %s\n' "$line"
    done
  fi
  printf 'FILES=%s\n' "$files"
  if [ "$checked" = "1" ]; then
    printf 'NOTE=task is checked; nodes never computes file scope for a checked task (it emits no row for one), so FILES is always empty here regardless of any plan files: line or sidecar entry\n'
  fi

  local unmatched="" q capout first_line any_quote=0
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    any_quote=1
    capout="$(_prd_capability "$prdabs" "$q")"
    first_line="${capout%%$'\n'*}"
    if [ "$first_line" = "MATCH" ]; then
      printf 'COVERS=%s\n' "$q"
      printf '%s\n' "$capout" | tail -n +2 | sed 's/^/  /'
    else
      unmatched="${unmatched}${q}"$'\n'
    fi
  done < <(_split_covers "$covers")

  [ "$any_quote" = "1" ] || printf 'COVERS=none\n'

  if [ -n "$unmatched" ]; then
    printf '%s' "$unmatched" | while IFS= read -r q; do
      [ -n "$q" ] && printf 'UNMATCHED=%s\n' "$q"
    done
  fi

  printf 'PRD=%s\n' "$prdrel"
  printf 'ARCH=%s\n' "$archrel"
}

# --- group: bundle the cursor with the unchecked tasks that safely follow it -
# (packet-bundling-t4.) Read-only. Four small helpers, each reused rather than
# copied from what already exists.

# _pipe_has <list> <item> — is <item> one element of the '|'-separated <list>?
_pipe_has() {
  case "|$1|" in *"|$2|"*) return 0 ;; *) return 1 ;; esac
}

# _pipe_overlap <a> <b> — do the two '|'-separated file lists share >=1
# element? Prints "1" or "0". An empty list shares nothing with anything,
# including another empty list — that single property is the whole mechanism
# behind "an empty scope overlaps nothing and runs alone" below; nothing else
# in `cmd_group` special-cases it.
_pipe_overlap() {
  A="$1" B="$2" awk 'BEGIN{
    n=split(ENVIRON["A"],a,"|")
    for(i=1;i<=n;i++) if(a[i]!="") seen[a[i]]=1
    m=split(ENVIRON["B"],b,"|")
    for(i=1;i<=m;i++) if(b[i]!="" && (b[i] in seen)) { print "1"; exit }
    print "0"
  }'
}

# _pipe_union <a> <b> — the two '|'-separated lists, deduplicated, in
# first-seen order.
_pipe_union() {
  A="$1" B="$2" awk 'BEGIN{
    out=""
    n=split(ENVIRON["A"],a,"|")
    for(i=1;i<=n;i++) if(a[i]!="" && !(a[i] in seen)) { seen[a[i]]=1; out=(out==""?a[i]:out "|" a[i]) }
    m=split(ENVIRON["B"],b,"|")
    for(i=1;i<=m;i++) if(b[i]!="" && !(b[i] in seen)) { seen[b[i]]=1; out=(out==""?b[i]:out "|" b[i]) }
    print out
  }'
}

# _deps_ok <consumes> <slug> <plan> <members-pipe> — true (rc0) when every
# `feature#<dep>` token in <consumes> (the same field `_nodes_for` already
# computes from a task's `deps:`) is either already admitted into the group
# (present in the '|'-separated <members-pipe> of node ids) or already
# checked in <plan> — via `_task_lookup`, the same duplicate-id-safe lookup
# check-task/task-status already share, never a second one. Empty <consumes>
# is trivially satisfied.
_deps_ok() {
  local consumes="$1" slug="$2" plan="$3" members="$4"
  [ -n "$consumes" ] || return 0
  local tok depraw depidlc depnode lookup
  local IFS='|'
  for tok in $consumes; do
    [ -n "$tok" ] || continue
    depraw="${tok#*#}"
    depidlc="$(printf '%s' "$depraw" | tr '[:upper:]' '[:lower:]')"
    depnode="${slug}-${depidlc}"
    _pipe_has "$members" "$depnode" && continue
    lookup="$(_task_lookup "$plan" "$depidlc")"
    case "$lookup" in
      already\ *) continue ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# _rowfield <file> <row> <col> — one TSV column from one 1-based row number.
# awk, never `read -r a b c ...`, on THIS particular TSV — `_nodes_for`'s own
# output, whose empty `consumes` column is common and whose later columns
# must not silently shift left because of it (see the comment on this same
# gotcha in `cmd_nodes_all`, and `cmd_group`'s use of this helper below).
_rowfield() {
  R="$2" C="$3" awk -F'\t' 'NR==ENVIRON["R"]{print $(ENVIRON["C"]+0)}' "$1"
}

# _member_title <plan> <idlc> — a member's header inline text, via
# `_task_record` (the SAME marker-stripped description `handoff`'s TEXT= is
# built from), never a second reader of the header line.
_member_title() {
  local plan="$1" idlc="$2" line key val
  while IFS= read -r line; do
    key="${line%%$'\t'*}"
    [ "$key" = "BODY" ] && break
    val="${line#*$'\t'}"
    [ "$key" = "TEXT" ] && { printf '%s' "$val"; return 0; }
  done < <(_task_record "$plan" "$idlc")
}

# cmd_group <packet-id> [--cap <n>] [root] — see the `group` entry in the
# header Subcommands list for the full contract.
cmd_group() {
  local task="${1:-}"; [ -n "$task" ] || die "group: need a packet id"
  shift
  local cap="1" root=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cap)
        [ $# -ge 2 ] || die "group: --cap needs a value"
        cap="$2"; shift 2
        ;;
      *)
        [ -z "$root" ] || die "group: unexpected argument: $1"
        root="$1"; shift
        ;;
    esac
  done
  case "$cap" in
    ''|*[!0-9]*) die "group: --cap must be a positive whole number, got '$cap'" ;;
  esac
  [ "$cap" -ge 1 ] || die "group: --cap must be at least 1, got $cap"
  root="$(_root "$root")"

  local resolved; resolved="$(_resolve_task_id "$task" "$root")"
  case "$resolved" in
    NOGSPEC)
      printf 'HANDOFF=unknown\nREASON=no gspec/ directory — gspec is optional (ADR 0020 D4)\n'
      return 0
      ;;
    UNRESOLVED)
      printf 'HANDOFF=unknown\nREASON=not a gspec task id — no plan resolves this packet\n'
      return 0
      ;;
    REFUSED\ *)
      die "group: ${resolved#REFUSED }"
      ;;
  esac

  local slug id
  slug="$(printf '%s' "$resolved" | cut -f2)"
  id="$(printf '%s' "$resolved" | cut -f3)"

  local pp plan relplan
  pp="$(_resolve_plan_path "$slug" "$root")"
  if [ -n "$pp" ]; then
    plan="$(printf '%s' "$pp" | cut -f1)"; relplan="$(printf '%s' "$pp" | cut -f2)"
  else
    printf 'HANDOFF=unknown\nREASON=no plan file for feature %s in any gspec layout\n' "$slug"
    return 0
  fi

  local idlc; idlc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  local cursor_key="${slug}-${idlc}"

  # The node list for this ONE feature, in plan order. `_nodes_for` already
  # skips checked tasks — so a checked task between two members simply never
  # appears here, and consecutiveness reuses that rather than re-deriving it
  # — and already resolves file scope via the files: > sidecar > empty
  # precedence `nodes`/`handoff` share. Never crosses into another feature,
  # since this call is scoped to one slug.
  #
  # Read by ROW NUMBER via `_rowfield`, never by `read -r a b c ...` on this
  # TSV — the same bug `cmd_nodes_all`'s own comment documents: tab is an IFS
  # *whitespace* character, so `read` silently collapses an empty middle
  # field (a task with no consumes:) and shifts every later column left, even
  # with IFS set to tab alone. `awk -F'\t'` never does that.
  local rowsfile; rowsfile="$(mktemp)"
  _nodes_for "$root" "$slug" > "$rowsfile"
  local n; n="$(awk 'END{print NR+0}' "$rowsfile")"

  local cidx=0 r idatcol
  r=1
  while [ "$r" -le "$n" ]; do
    idatcol="$(_rowfield "$rowsfile" "$r" 1)"
    if [ "$idatcol" = "$cursor_key" ]; then cidx="$r"; break; fi
    r=$((r + 1))
  done

  if [ "$cidx" -eq 0 ]; then
    rm -f "$rowsfile"
    local lookup; lookup="$(_task_lookup "$plan" "$idlc")"
    case "$lookup" in
      already\ *)
        printf 'HANDOFF=unknown\nREASON=%s task %s is already checked; nothing to group\n' "$slug" "$id"
        ;;
      *)
        printf 'HANDOFF=unknown\nREASON=%s has no task %s in %s\n' "$slug" "$id" "$relplan"
        ;;
    esac
    return 0
  fi

  local -a gidx=("$cidx")
  local union; union="$(_rowfield "$rowsfile" "$cidx" 3)"
  local members; members="$(_rowfield "$rowsfile" "$cidx" 1)"
  local stop=""
  if [ "${#gidx[@]}" -ge "$cap" ]; then
    stop="cap"
  else
    local j=$((cidx + 1)) overlap cfiles cconsumes
    while :; do
      if [ "$j" -gt "$n" ]; then stop="end"; break; fi
      cfiles="$(_rowfield "$rowsfile" "$j" 3)"
      overlap="$(_pipe_overlap "$union" "$cfiles")"
      if [ "$overlap" != "1" ]; then stop="scope"; break; fi
      cconsumes="$(_rowfield "$rowsfile" "$j" 4)"
      if ! _deps_ok "$cconsumes" "$slug" "$plan" "$members"; then stop="deps"; break; fi
      gidx+=("$j")
      union="$(_pipe_union "$union" "$cfiles")"
      members="${members}|$(_rowfield "$rowsfile" "$j" 1)"
      if [ "${#gidx[@]}" -ge "$cap" ]; then stop="cap"; break; fi
      j=$((j + 1))
    done
  fi

  printf 'GROUP=%s\n' "$cursor_key"
  local k midlc mid mproduces
  for k in "${gidx[@]}"; do
    mid="$(_rowfield "$rowsfile" "$k" 1)"
    mproduces="$(_rowfield "$rowsfile" "$k" 5)"
    midlc="$(printf '%s' "${mproduces#*#}" | tr '[:upper:]' '[:lower:]')"
    printf 'MEMBER=%s\t%s\n' "$mid" "$(_member_title "$plan" "$midlc")"
  done
  printf 'FILES=%s\n' "$union"
  printf 'STOP=%s\n' "$stop"
  rm -f "$rowsfile"
}

# --- handoff bundling (packet-bundling-t5) -----------------------------------
# `cmd_handoff` below is the real dispatcher `handoff` invokes; it does
# nothing itself beyond picking `_handoff_one` (no comma — the original,
# unchanged path) or `_handoff_bundle` (a comma-joined list). The comma split
# itself is inlined at the top of `_handoff_bundle`, exactly mirroring
# `runstate.sh`'s own `_rs_split_pkt_ids` (same malformed-shape checks: a
# leading, trailing, or doubled comma is a usage error, before anything
# prints) rather than factored into its own function -- a helper that `die`s
# must be called DIRECTLY, never through a process-substitution `< <(...)`
# feeding a `while read` loop, which runs it in a DETACHED subshell whose
# `exit` is invisible to the caller's `set -e` (the read loop just sees the
# pipe close early and continues as if nothing happened — this shipped once,
# was caught by `test-gspec-backlog.sh`'s malformed-comma-list cases reading
# `rc=0`, and is exactly the same class of subshell trap CLAUDE.md's
# `trim-note` SIGPIPE story warns about). Two more small helpers, reused
# rather than copied: `_plan_order` gives the plan's OWN id order (both
# checked and unchecked — unlike `_nodes_for`, which only emits unchecked
# rows — because a bundle member's position in the file is what "plan order"
# means here, not its presence in the backlog); `_routed_hand_off_feature` is
# documented at the `handoff` header entry above.

# _plan_order <plan> — every task id in <plan>, lowercased, FIRST occurrence
# only, in plan (file) order. Same `_TASK_LINE_RE` family every other reader
# in this file shares — never a second pattern for "what is a task line".
_plan_order() {
  local plan="$1"
  awk '
    /'"$_TASK_LINE_RE"'/ {
      desc = $0
      sub(/'"$_TASK_LINE_PREFIX"'/, "", desc)
      match(desc, /^'"$_TASK_ID_CLASS"'/)
      lid = tolower(substr(desc, 1, RLENGTH))
      if (!(lid in seen)) { seen[lid] = 1; print lid }
    }
  ' "$plan"
}

# _routed_hand_off_feature <root> <pkt> — has <pkt>'s LATEST routing record in
# THIS run's `.agents/loop/<run_id>/routing.jsonl` already recorded token
# `hand-off-feature`? Mirrors `runstate.sh`'s own
# `_rs_latest_routing_token`/`cmd_handoff` check (ADR 0028 T9) rather than
# calling into `runstate.sh` — packet-bundling-t5's FILES scope is this
# adapter alone, and this read sits OUTSIDE the pinned gspec contract, exactly
# like `interlock`'s `.gspec/build/status.json` read: FAIL-SOFT. No
# run-state.yaml, no `run_id:` line, an unsafe run_id, or no routing.jsonl all
# mean "not routed" — never a reason to refuse a bundle. Returns 0 (true)
# only on a positive `hand-off-feature` match; 1 (false) otherwise, including
# every fail-soft case above.
_routed_hand_off_feature() {
  local root="$1" pkt="$2" rsfile run_id routing_file line token
  rsfile="$root/.agents/run-state.yaml"
  [ -f "$rsfile" ] || return 1
  run_id="$(awk '
    /^run_id:[[:space:]]*/ {
      sub(/^run_id:[[:space:]]*/, "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      print; exit
    }' "$rsfile")"
  [ -n "$run_id" ] || return 1
  # Validated before use as a path component -- the same discipline ADR
  # 0028's driver-mode mark applies to a session id, for the same reason: an
  # unvalidated value must never be trusted to build a filesystem path.
  case "$run_id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  routing_file="$root/.agents/loop/$run_id/routing.jsonl"
  [ -f "$routing_file" ] || return 1
  line="$(grep -F "\"packet\":\"${pkt}\"" "$routing_file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 1
  token="$(printf '%s' "$line" | sed -E 's/.*"token":"([^"]*)".*/\1/')"
  [ "$token" = "hand-off-feature" ]
}

# _handoff_bundle <raw-ids> <root> — see the `handoff` entry in the header
# Subcommands list. Validates every member BEFORE printing anything, so a
# refusal never leaves partial output: pass 1 resolves each id and confirms
# every member names the SAME feature; pass 2 confirms each member actually
# names a task in that feature's plan and has not already been routed
# `hand-off-feature` this run. Only once every member clears both passes does
# it print `BUNDLE=`/`BUNDLE_FILES=` and each member's block, UNCHANGED from
# `_handoff_one`'s own output, in PLAN ORDER — never the order the caller
# listed them in.
_handoff_bundle() {
  local raw="$1" root="$2"
  # Splits on a bare comma only (no whitespace form), duplicates kept -- the
  # three malformed shapes a comma list can take (leading, trailing, doubled)
  # are rejected up front, called DIRECTLY (no subshell) so `die`'s `exit`
  # terminates the whole script under `set -e`, exactly as it does everywhere
  # else in this file.
  case "$raw" in
    ,*|*,|*,,*) die "handoff: packet id list must not contain an empty member" ;;
  esac
  local -a raw_ids
  IFS=',' read -r -a raw_ids <<<"$raw"
  local n="${#raw_ids[@]}"

  # --- pass 1: resolve every member; confirm one shared feature -------------
  local -a idlcs
  local bundle_slug="" i=0 tid resolved slug id
  while [ "$i" -lt "$n" ]; do
    tid="${raw_ids[$i]}"
    resolved="$(_resolve_task_id "$tid" "$root")"
    case "$resolved" in
      NOGSPEC)
        printf 'HANDOFF=unknown\nREASON=no gspec/ directory — gspec is optional (ADR 0020 D4)\n'
        return 0
        ;;
      UNRESOLVED)
        printf 'HANDOFF=unknown\nREASON=%s does not resolve to a gspec task id — no plan resolves this packet\n' "$tid"
        return 0
        ;;
      REFUSED\ *)
        die "handoff: ${tid}: ${resolved#REFUSED }"
        ;;
    esac
    slug="$(printf '%s' "$resolved" | cut -f2)"
    id="$(printf '%s' "$resolved" | cut -f3)"
    if [ -z "$bundle_slug" ]; then
      bundle_slug="$slug"
    elif [ "$slug" != "$bundle_slug" ]; then
      printf 'HANDOFF=unknown\nREASON=%s resolves to feature %s, but this bundle is feature %s — grouping across features is out of scope\n' "$tid" "$slug" "$bundle_slug"
      return 0
    fi
    idlcs[i]="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
    i=$((i + 1))
  done

  local pp plan relplan
  pp="$(_resolve_plan_path "$bundle_slug" "$root")"
  if [ -n "$pp" ]; then
    plan="$(printf '%s' "$pp" | cut -f1)"; relplan="$(printf '%s' "$pp" | cut -f2)"
  else
    printf 'HANDOFF=unknown\nREASON=no plan file for feature %s in any gspec layout\n' "$bundle_slug"
    return 0
  fi

  # --- pass 2: confirm each member is a real task and not already routed ----
  # --- away as hand-off-feature ----------------------------------------------
  local rec pkt
  i=0
  while [ "$i" -lt "$n" ]; do
    rec="$(_task_record "$plan" "${idlcs[$i]}")"
    if [ -z "$rec" ]; then
      printf 'HANDOFF=unknown\nREASON=%s has no task %s in %s\n' "$bundle_slug" "${raw_ids[$i]}" "$relplan"
      return 0
    fi
    pkt="${bundle_slug}-${idlcs[$i]}"
    if _routed_hand_off_feature "$root" "$pkt"; then
      printf 'HANDOFF=refused\nREASON=hand-off-feature\nPACKET=%s\n' "$pkt"
      return 0
    fi
    i=$((i + 1))
  done

  # --- every member clears both passes: determine PLAN order ---------------
  # Walk the plan's own id order once and claim each member's FIRST unclaimed
  # occurrence -- `_plan_order` dedups by first sighting, so a duplicated
  # member id in the caller's list claims its slot once and any repeat is
  # simply not re-emitted, never a second copy of the same block.
  local -a order_idx claimed
  i=0
  while [ "$i" -lt "$n" ]; do claimed[i]=0; i=$((i + 1)); done
  local pid m_i
  while IFS= read -r pid; do
    m_i=0
    while [ "$m_i" -lt "$n" ]; do
      if [ "${claimed[$m_i]}" = "0" ] && [ "${idlcs[$m_i]}" = "$pid" ]; then
        order_idx+=("$m_i")
        claimed[m_i]=1
        break
      fi
      m_i=$((m_i + 1))
    done
  done < <(_plan_order "$plan")

  local bundle_ids="" oi
  for oi in "${order_idx[@]}"; do
    bundle_ids="${bundle_ids}${bundle_ids:+,}${bundle_slug}-${idlcs[$oi]}"
  done
  printf 'BUNDLE=%s\n' "$bundle_ids"

  # BUNDLE_FILES: the union of each member's own scope, through the SAME
  # `_nodes_for` files: > sidecar > empty precedence `group` uses -- ONE
  # `_nodes_for` call for the whole feature, read per member, never
  # re-derived.
  local nodesfile; nodesfile="$(mktemp)"
  _nodes_for "$root" "$bundle_slug" > "$nodesfile"
  local bundle_files="" mfiles
  for oi in "${order_idx[@]}"; do
    mfiles="$(WANT="${bundle_slug}-${idlcs[$oi]}" awk -F'\t' '$1 == ENVIRON["WANT"] { f = $3 } END { print f }' "$nodesfile")"
    bundle_files="$(_pipe_union "$bundle_files" "$mfiles")"
  done
  rm -f "$nodesfile"
  printf 'BUNDLE_FILES=%s\n' "$bundle_files"

  for oi in "${order_idx[@]}"; do
    _handoff_one "${raw_ids[$oi]}" "$root"
  done
}

# cmd_handoff <packet-id[,packet-id...]> [root] — the real dispatcher; see the
# `handoff` entry in the header Subcommands list. A comma anywhere in the
# first argument selects the bundling path; its absence takes the ORIGINAL,
# unwrapped single-id path, so a single id's output is byte-identical to
# before bundling existed.
cmd_handoff() {
  local task="${1:-}"; [ -n "$task" ] || die "handoff: need a packet id"
  local root; root="$(_root "${2:-}")"
  case "$task" in
    *,*) _handoff_bundle "$task" "$root" ;;
    *)   _handoff_one "$task" "$root" ;;
  esac
}

cmd_check_task() {
  local task="${1:-}"; [ -n "$task" ] || die "check-task: need a task id"
  local root; root="$(_root "${2:-}")"

  local resolved; resolved="$(_resolve_task_id "$task" "$root")"
  case "$resolved" in
    NOGSPEC)
      printf 'CHECKED=none\nREASON=no gspec/ directory — gspec is optional (ADR 0020 D4)\n'
      return 0
      ;;
    UNRESOLVED)
      printf 'CHECKED=none\nREASON=not a gspec task id — nothing to flip (ADR 0020 D4: gspec is optional)\n'
      return 0
      ;;
    REFUSED\ *)
      die "check-task: ${resolved#REFUSED }"
      ;;
  esac
  local slug id
  slug="$(printf '%s' "$resolved" | cut -f2)"
  id="$(printf '%s' "$resolved" | cut -f3)"

  local plan relplan pp
  pp="$(_resolve_plan_path "$slug" "$root")"
  if [ -n "$pp" ]; then
    plan="$(printf '%s' "$pp" | cut -f1)"; relplan="$(printf '%s' "$pp" | cut -f2)"
  else
    printf 'CHECKED=none\nREASON=no plan file for feature %s in any gspec layout — nothing to flip\n' "$slug"
    return 0
  fi

  local idlc; idlc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"

  # Pass 1: READ-ONLY lookup. Determines whether the target task exists and,
  # if so, whether it is already checked -- without touching the file. This is
  # what makes the idempotent and not-found paths provably byte-identical: the
  # file is never opened for writing unless a real flip is about to happen.
  local lookup status="notfound" foundid=""
  lookup="$(_task_lookup "$plan" "$idlc")"
  if [ -n "$lookup" ]; then
    status="${lookup%% *}"
    foundid="${lookup#* }"
  fi

  if [ "$status" = "notfound" ]; then
    printf 'CHECKED=none\nREASON=%s has no task %s in %s\n' "$slug" "$id" "$relplan"
    return 4
  fi

  if [ "$status" = "already" ]; then
    printf 'CHECKED=already\nFILE=%s\n' "$relplan"
    return 0
  fi

  # Pass 2: the actual write. Rewrite ONLY the leading `[ ]` marker of the
  # matched line -- a plain `sub()` against the untouched `$0` copy, never a
  # field-rebuild, so every other byte on that line (and every byte of every
  # other line) survives verbatim. Only the first UNCHECKED matching id is
  # flipped -- the same gate as pass 1, so the two passes cannot disagree
  # about which line a duplicated id resolves to.
  # Atomic: build into a temp file in the same directory, then `mv` over the
  # original -- a reader never observes a partially-written plan file.
  # `cp -p` (not a bare empty `mktemp` file) carries the plan's own mode onto
  # the temp file, so the later `mv` doesn't narrow it to mktemp's 0600 --
  # git tracks only the exec bit, so a silent 0644->0600 would be invisible
  # to `git diff` and to review.
  # These are GLOBALS, deliberately, and must not be made `local` again. An EXIT
  # trap fires while the shell is unwinding, and whether a function-local is still
  # in scope at that point is bash-version-dependent: 3.2 (macOS) still sees it, so
  # `trap 'rm -f "$tmp"' EXIT` cleaned up and the sweep passed; 5.2 (Linux, CI) does
  # not, and under `set -u` the trap died with `tmp: unbound variable` before
  # reaching the `rm`, stranding the temp file beside the plan. Reproduced in
  # both versions. The `${x:-}` guards keep the trap safe even if it somehow fires
  # before either assignment.
  _ct_tmp=""; _ct_tmp2=""
  _ct_tmp="$(mktemp "$(dirname "$plan")/.gspec-check-task.XXXXXX")"
  # No process-wide trap: scoped to this write only, set as soon as the temp
  # file exists and disarmed right after the final `mv` succeeds, so a
  # stranded temp file under set -euo pipefail (cp, awk, or mv failing) can't
  # survive as untracked scratch beside the plan file.
  trap 'for _f in "${_ct_tmp:-}" "${_ct_tmp2:-}"; do [ -n "$_f" ] && rm -f "$_f"; done; :' EXIT
  # Aliases so the body below reads unchanged. `tmp2` is deliberately NOT aliased:
  # it is assigned mid-body, and a local copy would leave the trap holding the
  # empty initial value — the same scope trap this fix exists for, one variable over.
  local tmp; tmp="$_ct_tmp"
  cp -p "$plan" "$tmp"
  awk -v want="$idlc" '
    BEGIN { done = 0 }
    /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*[A-Za-z][A-Za-z0-9_-]*[0-9]+(\*\*|[[:space:]])/ && !done {
      desc = $0
      sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*/, "", desc)
      match(desc, /^[A-Za-z][A-Za-z0-9_-]*[0-9]+/)
      lid = substr(desc, 1, RLENGTH)
      checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
      if (tolower(lid) == want && !checked) {
        line = $0
        sub(/\[ \]/, "[x]", line)   # leftmost "[ ]" on the line is always the
        print line                 # leading marker -- the header regex above
        done = 1                   # already confirmed this line is unchecked.
        next
      }
    }
    { print }
  ' "$plan" > "$tmp"

  # awk's print always terminates the record it writes, so a plan lacking a
  # final newline would gain one byte here. Drop that byte before the mv so
  # the write really does touch nothing else in the file.
  if [ -n "$(tail -c1 "$plan")" ]; then
    local sz; sz="$(wc -c < "$tmp")"; sz=$((sz - 1))
    _ct_tmp2="$(mktemp "$(dirname "$plan")/.gspec-check-task.XXXXXX")"
    head -c "$sz" "$tmp" > "$_ct_tmp2"
    cat "$_ct_tmp2" > "$tmp"       # rewrite tmp's own inode -- keeps its mode
    rm -f "$_ct_tmp2"; _ct_tmp2=""
  fi

  mv "$tmp" "$plan"
  trap - EXIT

  printf 'CHECKED=%s#%s\nFILE=%s\n' "$slug" "$foundid" "$relplan"
}

# --- task-status: read-only completion status for a drifted-record report ----
# (run-state-cleanup T2 / ADR 0020-adjacent). Reuses `_resolve_task_id` and
# `_task_lookup` verbatim -- the same id resolution and duplicate-id handling
# check-task has, never a second copy that can drift from it. NEVER writes:
# check-task remains the adapter's one write (ADR 0025 D1).
cmd_task_status() {
  local ids_raw="${1:-}"; [ -n "$ids_raw" ] || die "task-status: need at least one packet id"
  local root; root="$(_root "${2:-}")"
  [ -d "$root" ] || die "task-status: no such directory: $root"

  local finished_list="" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    local state="" reason=""
    local resolved; resolved="$(_resolve_task_id "$id" "$root")"
    case "$resolved" in
      NOGSPEC)
        state="unknown"; reason="no gspec/ directory — gspec is optional (ADR 0020 D4)"
        ;;
      UNRESOLVED)
        state="unknown"; reason="not a gspec task id"
        ;;
      REFUSED\ *)
        die "task-status: ${resolved#REFUSED }"
        ;;
      *)
        local slug tid ambiguous plan="" relplan="" pp
        slug="$(printf '%s' "$resolved" | cut -f2)"
        tid="$(printf '%s' "$resolved" | cut -f3)"
        ambiguous="$(printf '%s' "$resolved" | cut -f4)"
        pp="$(_resolve_plan_path "$slug" "$root")"
        if [ -n "$pp" ]; then
          plan="$(printf '%s' "$pp" | cut -f1)"; relplan="$(printf '%s' "$pp" | cut -f2)"
        fi
        if [ -z "$plan" ]; then
          state="unknown"; reason="no plan file for feature $slug in any gspec layout"
        else
          local idlc lookup tcount
          idlc="$(printf '%s' "$tid" | tr '[:upper:]' '[:lower:]')"
          # Critical 1: a plan file that resolved but has NO task lines this
          # adapter can parse (empty, truncated, mid-migration, or an
          # unrecognized task-line shape) must read `unknown`, not `gone` --
          # `_task_lookup` printing nothing means either "no such id" or "no
          # ids at all here", and only the first is positive evidence.
          tcount="$(_plan_task_line_count "$plan")"
          if [ "$tcount" -eq 0 ]; then
            state="unknown"
            reason="plan file $relplan has no task lines this adapter can parse"
          else
            lookup="$(_task_lookup "$plan" "$idlc")"
            case "$lookup" in
              flip\ *)    state="unchecked"; reason="${relplan}#$(printf '%s' "$lookup" | cut -d' ' -f2)" ;;
              already\ *) state="finished";  reason="${relplan}#$(printf '%s' "$lookup" | cut -d' ' -f2)" ;;
              *)
                # Critical 2: the packet-id form's longest-slug-wins guess is
                # safe for check-task (a wrong guess is a loud rc=4), but NOT
                # here -- reporting `gone` on an ambiguous resolution would
                # silently claim a task that is actually live in the OTHER
                # colliding feature was abandoned. An ambiguous resolution
                # can only ever read `unknown`.
                if [ "$ambiguous" = "1" ]; then
                  state="unknown"
                  reason="packet id $id is ambiguous -- its feature slug collides with another feature's ($slug matched among others); cannot confirm the task no longer exists"
                else
                  # The plan file itself resolved and parsed (we got this
                  # far), and no longer names this id -- but that absence is
                  # only positive evidence of re-decomposition if the id
                  # actually WAS a task here at some point (loop-measurement
                  # T2 "gone requires positive evidence" gate). Without this
                  # check, a non-gspec packet id that merely happens to
                  # prefix-match a live feature's slug (`ts-fix-login-bug`
                  # against feature `ts`) would misread as `gone` and
                  # `sweep-open --gone` would record it `abandoned` -- the
                  # PLAN preamble (loop-measurement) is explicit that a
                  # non-gspec id with no plan is `unknown`/`interrupted`, the
                  # safe direction; this is that same rule applied to a
                  # prefix-collision id whose feature DOES have a plan.
                  local hist
                  hist="$(_task_history_probe "$relplan" "$root" "$idlc" "$slug")"
                  case "$hist" in
                    FOUND)
                      state="gone"
                      reason="no task $tid in $relplan (confirmed removed: $tid appears earlier in $relplan's git history)"
                      ;;
                    NEVER)
                      state="unknown"
                      reason="no task $tid in $relplan; $tid never appears in $relplan's git history -- it was never a gspec task here"
                      ;;
                    *)
                      state="unknown"
                      reason="no task $tid in $relplan; $relplan's git history is unavailable, so this cannot be confirmed either way"
                      ;;
                  esac
                fi
                ;;
            esac
          fi
        fi
        ;;
    esac
    printf '%s\t%s\t%s\n' "$id" "$state" "$reason"
    [ "$state" = "finished" ] && finished_list="${finished_list:+${finished_list},}${id}"
  done <<EOF
$(printf '%s' "$ids_raw" | tr ',' '\n')
EOF

  printf 'FINISHED=%s\n' "$finished_list"
}

cmd_nodes() {
  local slug="${1:-}"; [ -n "$slug" ] || die "nodes: need a feature slug"
  local root; root="$(_root "${2:-}")"
  _nodes_for "$root" "$slug"
}

cmd_nodes_all() {
  local root; root="$(_root "${1:-}")"
  _has_gspec "$root" || return 0
  local slug
  # Deferred features emit no nodes, for the same reason `next` skips them:
  # otherwise the loop queues work the human has explicitly decided not to
  # start.
  #
  # The filter is awk, NOT `while IFS=$'\t' read -r a b c ...`, and that is a bug
  # fix rather than a style choice. TAB is an IFS *whitespace* character, so bash
  # collapses a run of them into ONE delimiter even when IFS is set to tab alone:
  # a row with an empty `depends_on` (field 5) silently shifts every later field
  # left. The old read form survived only because `done`/`blocked` sit BEFORE the
  # first field that can be empty; `deferred` sits after it and broke immediately.
  # awk -F'\t' does not collapse empty fields, so it stays correct as fields are
  # added. Any future reader of this TSV must use awk for the same reason.
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    _nodes_for "$root" "$slug"
  done < <(cmd_features "$root" | awk -F'\t' '$3=="0" && $4=="0" && $7!="1" {print $1}')
}

# --- interlock: is a `gspec build` already driving this repo? (D5) -----------
# FAIL-SOFT by contract: status.json sits outside the pinned artifact contract,
# so an absent, unreadable, or unknown-shaped file yields `unknown` and never
# blocks. Only an explicit live `running` is reported busy.
cmd_interlock() {
  local root; root="$(_root "${1:-}")"
  local sj="$root/.gspec/build/status.json"
  [ -f "$sj" ] || { printf 'INTERLOCK=clear\n'; return 0; }
  local state pid
  if command -v jq >/dev/null 2>&1; then
    state="$(jq -r '.state // empty' "$sj" 2>/dev/null || true)"
    pid="$(jq -r '.pid // empty' "$sj" 2>/dev/null || true)"
  else
    state="$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$sj" 2>/dev/null | head -1 || true)"
    pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$sj" 2>/dev/null | head -1 || true)"
  fi
  [ -n "$state" ] || { printf 'INTERLOCK=unknown\nREASON=unrecognized .gspec/build/status.json shape\n'; return 0; }
  if [ "$state" != "running" ]; then
    printf 'INTERLOCK=clear\nGSPEC_BUILD_STATE=%s\n' "$state"; return 0
  fi
  # `running` with a dead pid is gspec's own crash signal, not a live driver.
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    printf 'INTERLOCK=clear\nGSPEC_BUILD_STATE=running(stale pid %s — crashed)\n' "$pid"; return 0
  fi
  printf 'INTERLOCK=busy\nGSPEC_BUILD_STATE=running\nPID=%s\n' "${pid:-unknown}"
  printf 'REASON=a gspec build is driving this repo; two drivers fanning implementers into one checkout will collide (ADR 0020 D5)\n'
}

# --- dispatch ----------------------------------------------------------------
case "${1:-}" in
  pin)       shift; cmd_pin "$@" ;;
  check)     shift; cmd_check "$@" ;;
  features)  shift; cmd_features "$@" ;;
  next)      shift; cmd_next "$@" ;;
  plans)     shift; cmd_plans "$@" ;;
  nodes)     shift; cmd_nodes "$@" ;;
  nodes-all) shift; cmd_nodes_all "$@" ;;
  interlock) shift; cmd_interlock "$@" ;;
  files-status) shift; cmd_files_status "$@" ;;
  check-task) shift; cmd_check_task "$@" ;;
  task-status) shift; cmd_task_status "$@" ;;
  handoff)    shift; cmd_handoff "$@" ;;
  group)      shift; cmd_group "$@" ;;
  capability-drift) shift; cmd_capability_drift "$@" ;;
  complete-capabilities) shift; cmd_complete_capabilities "$@" ;;
  *) die "usage: gspec-backlog.sh {pin|check|features|next|plans|nodes <slug>|nodes-all|interlock|files-status|check-task <task>|task-status <id[,id...]>|handoff <packet-id>|group <packet-id> [--cap <n>]|capability-drift|complete-capabilities <slug>} [root]" ;;
esac
