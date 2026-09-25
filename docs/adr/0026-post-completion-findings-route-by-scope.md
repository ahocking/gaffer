# ADR 0026 — A finding found after a plan is complete routes by scope, not by editing the record

- Status: Accepted
- Date: 2026-08-10
- Revision (2026-09-17): **arm 2 always terminates at an operator question — no
  agent files the feature.** D2's split stands, but the half that let the
  main-context session author the PRD itself is withdrawn. See
  [Revision — 2026-09-17](#revision--2026-09-17--arm-2-terminates-at-the-operator-never-at-gspec-feature)
  below; the accepted text above it is unchanged.
- Revision (2026-09-20): **an end-of-run arm-2 proposal now leaves a routing record and
  is counted in the stop report's tally; the operator gate is unchanged.** See
  [Revision — 2026-09-20](#revision--2026-09-20--an-end-of-run-arm-2-proposal-leaves-a-routing-record-and-is-counted)
  below; nothing above it is rewritten.
- Amendment (2026-09-22): **the end-of-run routing step is retired.** `run-loop` §4 no
  longer dispatches an architect to route the whole-branch review's findings by these
  arms, and writes no `end-of-run-review` routing record; the review itself is unchanged
  and each note it reports becomes a finding. Both arms survive where they are still
  reachable — the escalation decider's `append-task`/`hand-off-feature` and the periodic
  review. See [Amendment — 2026-09-22](#amendment--2026-09-22--the-end-of-run-routing-step-is-retired)
  at the end; the 2026-09-17 and 2026-09-20 revisions above are not rewritten.
- Deciders: user (tech lead), orchestration plugin
- Amends: [ADR 0022](0022-findings-index-not-content.md) (its routing table is unchanged;
  this supplies the destination that made the "backlog, not a finding" rule un-followable
  when the parent plan was already complete);
  [ADR 0025](0025-remove-backlog-done.md) (its "this is the plugin's one write into
  `gspec/`" becomes two — arm 1 adds an append of a new unchecked task line alongside the
  `[ ]` → `[x]` flip)
- Relates to: [ADR 0020](0020-gspec-boundary-and-version-pin.md) D1 (the seam) and D2
  (completion is derived and never stored), [ADR 0012](0012-delegated-loop-driver.md)
  (a dispatched agent has no `Skill` tool),
  [ADR 0024](0024-findings-are-packet-scoped-and-expire.md) (why a findings file cannot
  hold future work).

## Context

### Two correct rules meet at the end of a run, and the record of why was wrong

`run-loop` §4 tells the loop that a Critical or Important issue from the whole-branch
review becomes **a new packet appended to the backlog**, not something shipped over.
gspec tells it that a checked task is a historical record and must not change. At the
end of the `self-host-hardening` run those two rules met: three follow-up tasks were to
be appended to `gspec/tasks/self-host-hardening.md`, and both attempts were rejected by
`.claude/hooks/gspec-task-immutability.mjs` with

> this edit would alter or remove checked-off task(s) T7, which are IMMUTABLE once
> complete.

The rejection is not a misconfiguration. But the diagnosis recorded at the time — that the
block is unworkable-around, because once every task is checked there is nothing left to
anchor on — is **false**, and correcting it is one of this ADR's contributions.

The hook does not inspect the anchor at all. `.claude/hooks/floors/task-immutability.mjs`
projects the edit onto the on-disk baseline and asks one question (`violations()`, lines
67-73): does **every checked task's block still appear verbatim in the resulting file**?
Executed directly, three cases settle it — anchoring on an *unchecked* task line and
appending passes; anchoring on a *checked* task's sub-bullet, reproducing it
byte-identically and appending after **also passes**; inserting text inside a checked block
is rejected. So an append to a fully-checked plan is mechanically possible, and the second
attempt recorded in `.agents/findings/cannot-append-to-checked-plan.md` failed for some
other reason. That finding named the right dead end for the wrong reason.

The dead end survives the correction because it was never mechanical. A plan whose tasks
are all checked reads as done, and that reading is correct; appending to it makes a shipped
feature carry unshipped work, which is the reopening of a derived-done feature ADR 0020 D2
forbids (below). **Do not append to a completed plan** is therefore policy, adjudicated by
the arm-1 scope test, not an impossibility the hook enforces for us. And the dead end
arrives where it always did: at exactly the moment the loop is designed to append, after
the final packet lands and the review runs.

### The easy way out is real, and was deliberately not taken

A shell append (`cat >>`, `printf >>`) would have succeeded, because the immutability hook
fires on `Edit`/`Write` and the guard's REVIEW tier does not cover `gspec/`. That is
routing around a control rather than passing it, and the fact that it is *easy* is the
reason not to do it. The correction above changes only the alternative: a byte-faithful
`Edit` would have passed the control too, so the choice was never bypass-or-nothing. It
does not change the refusal, and it does not make the append right — passing the control
mechanically is not the same as the append belonging there, which is what D1's scope test
decides. The tasks were reported to the human in prose instead — which is how the finding
that motivates this ADR exists at all.

### Where the loop is standing when it needs this

§4 runs inside a relay-dispatched Chief Engineer or a parallel lane. A dispatched agent
has **no `Skill` tool** (ADR 0012), so it cannot invoke `/gspec-plan` or `/gspec-feature`;
naming a slash command in a brief yields an improvised loop, not the command. Any
mechanism that is only reachable from a main-context session is not a mechanism the loop
can follow — at best it is something the loop can *ask for*.

### The immutability hook is vendored twice over

`.claude/hooks/gspec-task-immutability.mjs` is written by the gspec installer and — by
inference from the `<!-- gspec:preamble -->` block, the one re-stamping this repo has
directly observed — re-stamped on every `npx gspec@<pin> --target claude`. Installer
*placement* is directly evidenced; re-stamping of the hook specifically is the analogy,
and the rest of this section rests on it. It is git-tracked here, but
tracked is not safe: the installer overwrites it, exactly as it re-stamps the
`<!-- gspec:preamble -->` block in `CLAUDE.md` that this repo already documents as
"never edit inside it — corrections go here, outside the markers, or they are silently
lost on the next install." Its own file header states that it is never executed from the
source tree. And the decision logic is not even in it: it delegates to a second vendored
module, `.claude/hooks/floors/task-immutability.mjs`. A local allowance would therefore
have to patch a doubly-vendored surface, and would be reverted on the next install
without a diff, a warning, or a failing sweep.

### Completion is derived, so reopening a finished feature is not a local edit

Feature completion comes from the PRD's capability checkboxes and is never stored
(ADR 0020 D2). Adding an unchecked capability to a feature that reads done makes shipped
work read as incomplete, and — through the dependency rule — blocks everything
downstream of it until someone checks a box that is not about the shipped work at all.
This repo has already answered that twice by splitting: `metrics-coverage-gaps` out of
`run-metrics`, and `self-host-hardening-gaps` out of `self-host-hardening`. Both splits
exist for this reason and both are precedent, not improvisation.

### ADR 0022's routing table was correct and had nowhere to point

The table says "this should be built/fixed" → **backlog**, never a finding, because a
findings file holding future work is a second backlog competing with gspec. That rule was
un-followable in the one case that matters here: when the parent plan is complete, the
backlog had no reachable destination. The observable result is
`.agents/findings/selfhost-worktree-lane-unfixtured.md`, which says so in its own routing
note — recorded as a finding "only because there is currently no sanctioned way to add
it." That is the gap this ADR closes: the rule stays, the destination is supplied.

## Decision

**A finding discovered after a plan is complete is routed by the finding's own scope, in
two arms tried in order. The completed record is never edited, and the control that
protects it is never removed or bypassed — it adjudicates every write this decision makes
and is allowed to say no.**

### D1 — Arm 1: extend an incomplete feature that already covers the scope

If a feature exists that is **incomplete and whose existing scope covers the finding**,
the finding becomes an appended task line in that feature's plan. Both tests must hold,
and they are separate:

1. **Anchor availability.** The feature has a plan file with at least one **unchecked**
   task line for arm 1 to anchor on. An unchecked line is not mechanically *required* by
   the hook — see the predicate below — it is the anchor arm 1 specifies. The adapter
   already answers the plan-file half: a feature with unchecked
   capabilities and a plan emits packet nodes, while a feature with no plan reports
   `PLAN=none`. No plan file means no anchor, and therefore no arm 1 — regardless of how
   well the scope matches.
2. **Scope.** The finding is covered by an **unchecked capability already in that
   feature's PRD**, closely enough that the appended task can carry a truthful `covers:`
   naming it. If the finding would require a *new* capability, or would attach to a
   capability that is already checked, arm 1 does not apply.

The append is an `Edit` anchored on an **unchecked** task line. The rule the hook applies
is *not* "the `old_string` contains no `- [x]` line" — a checked task's **block** runs from
its task line to the start of the next task line, taking its `deps:`/`covers:` follow-on
lines with it, so an `old_string` carrying no `- [x]` at all can still break one. The real
predicate is: **every checked task's block — its task line and everything up to the next
task line — survives byte-identically in the resulting file.** Anchoring on
an unchecked task line satisfies that by construction, which is why arm 1 is specified that
way rather than by what the `old_string` avoids. The immutability hook still runs and still
adjudicates. If it rejects, that is information — the edit disturbed a checked task's
block, or arm 1 was the wrong arm — and never a cue to reach for the shell.

**The scope test is the whole guard, and it is what stops arm 1 becoming a junk drawer.**
The failure this rule exists to refuse is appending unrelated work to whichever plan
happens to be open. That failure is expensive rather than merely untidy: the host feature
can then never honestly read as done, so derived completion (ADR 0020 D2) stops meaning
anything, and the roadmap's ordering rationale stops describing what the feature contains.
The anchor plan is chosen by scope match, never by proximity, recency or convenience. "It
was the plan I was already in" is not a scope match.

### D2 — Arm 2: no incomplete feature covers it, so create the destination

Otherwise — and this includes every case where the parent plan is fully checked, which is
the motivating case — the finding becomes **a new feature**:

- a PRD authored through `/gspec-feature`, in the shape the existing splits already use;
- an entry in `.agents/roadmap.yaml` with `depends_on:` naming the parent and an `order`
  after it, since gspec has no cross-feature ordering;
- **no plan file.** A specced feature with no `gspec/tasks/<slug>.md` is the intended
  state for deferred work — the adapter reports `PLAN=none` and the `/gspec-plan` hint.
  Decompose when the work comes up, so the decomposition reflects the repo as it is then.

Because a dispatched loop context has no `Skill` tool, arm 2 is **split across the seam**:
the loop cannot author the PRD, so in-run it hands the routing decision off, and the
main-context session (or the human) runs `/gspec-feature` and adds the roadmap entry.

The carrier is an existing wire shape and no new one is needed: the
`### Check-in — question  [severity: normal]` block in `templates/check-in.md`. `gate:`
records the arm-2 routing decision, `question:` names the proposed slug, its scope in a
sentence, and the parent it depends on, and `state:` stays `continuing on other packets` —
arm 2 never blocks the run, which is what makes `normal` the honest severity. Two carriers
that do **not** work and must not be reached for: the `Findings:` key explicitly excludes
"this should be built/fixed" (that is backlog — the ADR 0020 seam), and the decision block
is a human-facing report convention (ADR 0023) that a relay-dispatched Chief Engineer or a
parallel lane never emits — it returns the wire format, and the main-context agent renders
the human-facing shape from it.

This is not the old prose-report failure mode: prose was the *terminus* before, and here it
is a handoff on a parsed key with a named destination and a named next command.

Arm 2 is the more expensive arm and that is accepted. Its cost is bounded and it pays
back: once the new feature exists with unchecked capabilities, the **next** finding in
the same scope is caught by arm 1. Arm 2 creates destinations; arm 1 uses them.

**`-gaps` does not stack.** `<parent>-gaps` is a convention, not a rule; a second-order
gap gets a slug naming its scope, because `…-gaps-gaps` is a sign the split was made for
bookkeeping rather than scope.

### D3 — Why regeneration through `/gspec-plan` is rejected

`/gspec-plan` remains the right tool for decomposing a feature when its work comes up —
it is the second half of arm 2, later. What is rejected is regeneration as the *append*
mechanism:

- **It is not reachable from where the loop needs it.** §4 runs in a dispatched context
  with no `Skill` tool (ADR 0012).
- **Regeneration re-decomposes unchecked work while preserving task ids**, so running it
  against a plan whose tasks are all checked puts the record it exists to protect at
  risk. This repo already forbids running it against `gspec/tasks/run-metrics.md` for
  exactly this reason.
- **It has nothing to generate against.** A plan is generated from the PRD's unchecked
  capabilities; a derived-done feature has none, so producing new tasks means first
  adding an unchecked capability — reopening the feature, making shipped work read as
  incomplete and blocking everything downstream (ADR 0020 D2). That is the outcome both
  existing splits were made to avoid.

### D4 — Why a purely-additive-at-EOF hook allowance is rejected

- **It is unnecessary, before it is anything else.** The additive append it would legalise
  already passes. The hook asks only that every checked block survive verbatim, so an
  append that disturbs none is accepted today — measured, in the three cases above. The
  candidate buys the loop no capability it lacks; it only removes the adjudication.
- **It would be silently reverted.** The hook is installer-written and re-stamped on
  every install, and its logic lives in a second vendored module
  (`.claude/hooks/floors/task-immutability.mjs`); the adapter's own header states that the
  `./floors/` import resolves at the installed location and that the adapter is never
  executed from the source tree. The patch survives until the next `npx gspec@<pin> --target
  claude`, after which the loop appends, the control rejects, and the failure is
  indistinguishable from the original bug — with a patch in the tree asserting it is fixed.
- **It crosses the seam in the direction the seam forbids.** gspec owns the specification
  record; this plugin owns governed execution (ADR 0020 D1). The plugin's writes into
  `gspec/` are confined to the adapter's contract (ADR 0025), and gspec's own enforcement
  code is not part of that contract. Patching another tool's control to make our write
  succeed is the plugin deciding what gspec's rules are.
- **It weakens a correct control to buy convenience.** The immutability rule is right.
  And "purely additive at EOF" is not the narrow predicate it sounds like: an append past
  the last checked task is *precisely* how unrelated scope gets bolted onto a finished
  feature, so the allowance would legalise, in code, the junk drawer D1's scope test
  refuses in prose.
- **It would drag the follow-up packet out of scope.** T5 is instruction-only; this
  candidate turns it into a patch of a vendored hook plus a sweep for behaviour the
  installer can remove.

## Consequences

- **ADR 0022's routing table is unchanged and now followable.** "This should be
  built/fixed" still goes to the backlog and still is not a finding. What changes is that
  the backlog now has a reachable destination in the one case where it had none.
- **`.agents/findings/` stops being a holding pen for future work.** Under ADR 0024
  findings are packet-scoped and expire, so a findings file used to park backlog is work
  with a deletion date on it. `selfhost-worktree-lane-unfixtured` is the current instance
  and says so itself.
- **No code change is required, so T5 stays instruction-only.** Both arms are existing
  mechanisms: arm 1 is an `Edit` the immutability hook already permits, arm 2 is
  `/gspec-feature` plus a `.agents/roadmap.yaml` entry, and the adapter already handles a
  feature with a PRD and no plan. Nothing in `scripts/` learns anything new, and no sweep
  gains a case.
- **The arm-1 scope test is prompt-enforced, and that is the fragile part.** Nothing
  mechanically checks that an appended task belongs to the feature it was appended to.
  The detector is a task whose `covers:` does not fit the capability it names; the review
  boundary is the packet's own review and the PR, the same boundary that catches every
  other scope error.
- **Arm 1 widens the plugin's write into `gspec/`, and the widening must stay bounded.**
  ADR 0025 named the first crossing (a `[ ]` → `[x]` flip on a task line). Arm 1 adds an
  append of a **new unchecked task line** to a plan. Bounds: append only, never modifying
  an existing line, never touching a PRD capability checkbox, and always carrying a
  `covers:` naming an existing unchecked capability. A format change on a write can
  corrupt a file the plugin does not own, which is why the write stays this narrow.
- **A rejection from the immutability hook is now a signal, not a wall.** It means the
  edit disturbed a checked task's block or the arm choice was wrong. The response is to
  re-evaluate the arm, never to switch tools.
- **The shell append stays easy and stays forbidden.** Nothing here makes `cat >>` harder;
  the decision is that the loop has a sanctioned path, so it no longer has a reason.
- **Feature count grows with distinct scopes, not with review events.** Arm 1 first is
  what keeps that true: a run that finds three defects inside one open feature's scope
  produces three tasks, not three features.

### The live case, walked through

`selfhost-worktree-lane-unfixtured` is a missing `scripts/test-metrics.sh` fixture for the
worktree-lane self-host case — a rationale asserted in a comment in `scripts/metrics.sh`
and never constructed, the same shape as the fail-open closed in
`self-host-hardening-gaps-t2`, verified manually during that packet's review. It was
discovered after `self-host-hardening`'s plan was fully checked, and its routing note says
"Promote this to a tracked task once T4 lands."

Arm 1 is tried first and fails, twice over:

- The scope's natural home is the `self-host-hardening-gaps` capability *The self-host
  marker yields no answer rather than a wrong one* — which is **checked**. Attaching to a
  checked capability is exactly the reopening D1 forbids.
- `metrics-coverage-gaps` is incomplete, but it has **no plan file**, so there is no
  unchecked task line to anchor on and the mechanical test fails before its scope is even
  argued.

**It does not go into `self-host-hardening-gaps`, and that is worth stating plainly**,
because this is the tempting error: that feature is open, it is the feature this ADR
itself belongs to, and its plan already anticipates an appended task. But the anticipated
append is reserved for a code change *this ADR's mechanism* might require, covered by the
unchecked P1 capability about routing findings. A metrics sweep fixture is not covered by
that capability by any honest reading of `covers:`. Appending it because the plan is open
and convenient is the junk drawer, demonstrated on the very feature that decided against
it.

So it lands in arm 2: a new feature scoped to the self-host marker's sweep coverage,
`depends_on: [self-host-hardening-gaps]`, ordered after it in `.agents/roadmap.yaml`, with
**no plan file** until the work comes up. The slug does not take a second `-gaps`. Once it
exists, a later finding of the same shape — another asserted-not-constructed claim in that
block — is caught by arm 1 and costs one task line.

The mechanism carries the case without forcing, and the case is a useful stress test
precisely because the cheap answer and the correct answer differ.

## Alternatives considered

- **Regenerate through `/gspec-plan`** — rejected in D3: unreachable from a dispatched
  context, re-decomposes unchecked work against a record that must not move, and requires
  reopening a derived-done feature to have anything to generate from.
- **A purely-additive-at-EOF allowance in the immutability hook** — rejected in D4:
  unnecessary (the additive append already passes), silently reverted on the next installer
  stamp, crosses the ADR 0020 seam into gspec's enforcement, weakens a correct control, and
  legalises the junk drawer.
- **Keep reporting findings to the human in prose and change nothing.** This is the
  status quo, and its outcome is already observable: findings files used as a holding pen,
  against the rule in ADR 0022 and with an expiry under ADR 0024.
- **A plugin-side "unplanned work" file the loop can always append to.** Reachable from
  anywhere and trivially writable, which is the appeal — and it is a second backlog
  competing with gspec, the exact structure ADR 0020's seam and ADR 0022's routing table
  exist to prevent. Worth naming because it is the answer that looks cheapest at the
  moment the loop is blocked.
- **Let the loop create the new feature itself in arm 2.** Rejected because it cannot: a
  dispatched agent has no `Skill` tool, and hand-writing a PRD around `/gspec-feature`
  would be authoring an unvalidated spec through the exact bypass this repo already
  refuses for the gspec skills.

## Revision — 2026-09-17 — arm 2 terminates at the operator, never at `/gspec-feature`

**Operator decision, this date.** D2 above splits arm 2 across the seam: the loop hands
the routing decision off, and "the main-context session (or the human) runs
`/gspec-feature` and adds the roadmap entry." **The parenthetical is withdrawn.** Arm 2
now always ends at a question in the stop report, and **no agent files the feature** —
not the architect that routed it, and not the session driving the loop, whether or not
driver mode has exited. Only the operator decides that a proposal becomes a feature.

### Why

D2 read the constraint as *reachability* — a dispatched context has no `Skill` tool, so
arm 2 must be handed to something that does. Under ADR 0028 the loop driver **is** the
main context, so the hand-off found a capable recipient inside the run and completed
there. The effect is that **finishing a feature files its successor**: a run terminates,
the whole-branch review finds something outside every open capability, and the same
session that just landed the work writes the next feature into the backlog with no
operator in the path. Five of this repo's 28 `.agents/roadmap.yaml` entries name arm 2 as
their own origin (`loop-prose-consistency`, `loop-prose-consistency-gaps`,
`loop-entry-routing`, `completion-record-drift-gaps`, `guard-write-target-detection`), and
several more were spawned by a whole-run review without naming the arm — so the backlog
was growing at review events, not at operator decisions. ADR 0026's own consequence
"feature count grows with distinct scopes, not with review events" was being satisfied
only in the arm-1 direction.

Reachability was never the *only* reason arm 2 stops short of authoring. The
"Alternatives considered" entry above gives the second, and it does not depend on which
context is holding the `Skill` tool: an autonomously-authored PRD is a spec nobody
approved, entering the ordered backlog the loop will later execute unattended. What the
`Skill`-tool argument concealed is that **the operator gate was the point, and
reachability was just what was enforcing it**. This revision states the gate directly, so
it no longer moves when the harness does.

### What is unchanged

- **Arm 1 is untouched.** An unchecked capability that covers the finding still takes an
  appended task line, committed in-run. The operator gate applies to *creating a
  destination*, not to using one that already exists and is already approved.
- **The arm ordering, the arm-1 scope test, and every write bound in D1.**
- **The carrier.** The routing decision still travels as a `normal`-severity question, and
  the architect still names the proposed slug, its scope in a sentence, and its parent in
  its result file and status line. What it feeds is a stop-report question, never a
  command.
- **D3 and D4.** Regeneration through `/gspec-plan` and a hook allowance stay rejected for
  their own reasons.

### Consequences of the revision

- **A run can end with an unfiled proposal, and that is the intended state.** The cost is
  that a proposal can be lost if the operator does not act on the stop report; the stop
  report carries `handoff-feature` lines for the whole run precisely so it is visible
  there. That exposure is accepted as cheaper than a backlog that writes itself.
- **Arm 2's pay-back is slower.** D2 notes that arm 2 creates the destinations arm 1 later
  uses; that now waits on an operator turn. Accepted.
- **Sites that must agree:** `skills/run-loop/SKILL.md` §4 (arm 2), `agents/chief-engineer.md`
  (`hand-off-feature`), `agents/architect.md`, and this repo's `CLAUDE.md` ADR 0026
  bullet. `agents/loop-driver.md` and `templates/report-templates.md` already describe
  hand-off as a stop-report question only, and needed no change.

## Revision — 2026-09-20 — an end-of-run arm-2 proposal leaves a routing record and is counted

`loop-driver-run-gaps` T5 (`ee8b869`). The 2026-09-17 revision above says the stop
report "carries `handoff-feature` lines for the whole run precisely so it is visible
there", and that what the architect's proposal feeds "is a stop-report question, never a
command". Both stand. What that revision did not say — because nothing wrote it — is
where the `handoff-feature` line for an **end-of-run** proposal comes from. A mid-run
`hand-off-feature` from the decider reaches the digest through `runstate.sh route`, and
so is counted; the proposal the end-of-run architect makes in `run-loop` §4 had no
record at all, so the stop report rendered its decision block beside a `DECISIONS`
figure that did not count it.

**Now the proposal is recorded through the core, under a fixed id that is not a
packet.** When the architect's status line reports an arm-2 proposal in its free-text
clause — the driver judges that from the line it already relays; arm 2 introduces no new
status token — the driver calls
`runstate.sh route <run-state> end-of-run-review hand-off-feature --status '<that line>'`
before the stop report reads `run-tally`. `end-of-run-review` names the run's termination
review: it fits the packet-id charset, reads as a title in the stop report, and cannot
collide with a packet. The printed `ACTION` is not acted on — the record is the purpose
of the call — and no outcome is ever recorded for the id, since it has no handoff file
and no start record. `run-digest` then emits one `handoff-feature` line for it carrying
the architect's status line, `run-tally`'s `DECISIONS` includes it once, and the stop
report's 🔀 section carries exactly that many blocks. An architect that routed everything
to arm 1, or found nothing to route, records nothing and changes no figure. ADR 0028
carries the matching amendment on the routing log's shape.

### What is unchanged

- **The operator gate.** The record counts the proposal; it files nothing. No agent runs
  `/gspec-feature` in the run, and a run can still end with an unfiled proposal — the
  record only makes the tally honest about how many there are.
- **The carrier.** The proposal still travels as the architect's status line and result
  file, and still lands as a stop-report question. The routing record carries that same
  status line; it is a second reader of the line, not a second line.
- **Arm 1, the arm ordering, the arm-1 scope test, D3 and D4.**

> **Retired 2026-09-22 — the end-of-run routing step this revision extends no longer
> exists.** The architect dispatch it records a routing record for is gone, and with it
> the `end-of-run-review` id and that record. See the amendment below; the text above
> stands as the record of what shipped on 2026-09-20.

## Amendment — 2026-09-22 — the end-of-run routing step is retired

**Operator decision, this date.** `run-loop` §4 dispatched the `architect` over the
whole-branch review's file to route each Critical/Important finding by D1 and D2, and
(since the 2026-09-20 revision) recorded an arm-2 proposal through `route` under the
fixed id `end-of-run-review`. **That whole step is deleted.** The whole-branch review
itself is untouched — the bounded diff, the reviewer dispatch, its `write-result` and
its one status line all stay exactly as they are.

### Why: arm 1 is structurally unreachable at §4, so the step could only ever propose

Arm 1 requires an **incomplete** feature with an unchecked task line to anchor on and an
unchecked capability covering the finding. By the time §4 runs, §3.6 has flipped every
task checkbox of the feature just finished at each land, and `complete-capabilities` has
flipped its capabilities — so for the feature the run was about, arm 1 fails its anchor
test on every run, by construction. Arm 2 is therefore the only arm the end-of-run
architect can reach, and since the 2026-09-17 revision arm 2 terminates at a question
for the operator to decline or accept. The step's entire reachable output was one
proposal per run.

The cost was measured on the run that prompted this retirement: the architect dispatch
cost **70,695 tokens** (operator's measurement) and produced **one proposal, declined**.
The prose removed from `skills/run-loop/SKILL.md` is **649 words**, and the replacement
below is 312, so §4 falls from 2,905 words to 2,553 and the skill from 12,493 to 12,156
(measured with `wc -w` against the pre-change file). The dispatch, not the prose, was
the expensive half. This is a deliberate subtraction for token cost, not a redesign —
nothing replaces the step with a mechanism of similar size.

### What replaces it: one durable record, and nothing else

Where §4 relays the review's status line, the driver now records **one finding per note
that line reports**, through `runstate.sh add-finding`. The reason is durability, not
routing: the findings index is the only thing §2's fresh-run write carries into the next
run, and `begin-run` prunes the run directory holding the review file after two runs, so
a note left only in that file is gone within two runs. Nothing new is built for this —
`add-finding` already exists and `scripts/runstate.sh` is unchanged by this retirement.

- The summary is **what the status line says**. The driver still never opens a result
  file (ADR 0028), so it can only record what it has read; inventing a finding about a
  file it has not read is the failure this constraint forbids.
- **`--packets` is mandatory**, so each finding names the packet or packets the note is
  about. At termination those are **landed** packets — that is truthful, and it is
  stated rather than worked around. **Expiry is unchanged**: the positive-evidence rule
  (ADR 0024, ADR 0025) governs these findings exactly as it governs every other one, and
  this amendment adds no expiry behaviour, no knob and no exemption.
- **A review reporting no notes records nothing.** No call, no finding, no figure moves.
- The driver relays the reviewer's own status line in the stop report and names the
  review file's path beside it, so the operator can open what the driver did not.

### What is unchanged

- **D1 and D2 themselves, the arm ordering, the arm-1 scope test and its write bounds,
  D3 and D4.** The arms are retired only at `run-loop` §4. They remain live where they
  are still reachable: the escalation decider's `append-task` (arm 1) and
  `hand-off-feature` (arm 2) triggers mid-run, and the Chief Engineer's periodic review
  of the findings index — both operate while a feature is still incomplete, which is
  exactly the condition §4 cannot satisfy.
- **The operator gate.** No agent files a feature, here or anywhere; the 2026-09-17
  revision's rule survives its own carrier.
- **A rejection from the immutability hook is still a signal, and the shell append is
  still forbidden.**

### Consequences

- **A `handoff-feature` line in the stop report now comes only from the decider or the
  periodic review.** `run-tally`'s `DECISIONS` no longer has a termination proposal to
  count, and `end-of-run-review` is written by nothing. `scripts/runstate.sh` never
  special-cased the id — it is an ordinary packet id to the core — so no code changed.
- **The end-of-run review's output is now durable rather than routed.** A note that
  really is "this should be built/fixed" reaches the operator as a finding and a relayed
  status line, and the operator decides whether it becomes backlog. That is slower than
  an in-run proposal and is accepted: the proposal was declined at the operator gate
  anyway, so the gate was always where the decision happened.
- **Sites that had to agree:** `skills/run-loop/SKILL.md` §4 (and §3.6's cross-reference
  to the arms), `agents/architect.md` (its termination duty), `agents/loop-driver.md`
  (the never-open-a-result-file rule, which is now absolute with no exception to
  explain), this repo's `CLAUDE.md` (the ADR 0026 section and the `end-of-run-review`
  bullet, replaced by one line under Retired features),
  `scripts/test-report-conventions.sh` (the two sections pinning the deleted clause,
  replaced by one pinning the review, the relay and the per-note finding), and
  [ADR 0028](0028-loop-driver-mode.md)'s matching amendment on the routing log's shape.

## Relocated from skills (2026-09-25) — the run-loop skill's whole-branch review reasons

Moved out of `skills/run-loop/SKILL.md` `## 4. Termination` by `skill-prompt-trim`.
The amendment above keeps the whole-branch review; the skill keeps each of its rules
with at most a one-clause reason, and the fuller wording is recorded here.

- **Why the review's diff is bounded to this run's own work.** The skill keeps "since
  a branch-vs-base diff re-presents earlier runs' already-reviewed commits". It used to
  read, the measurement being the reason for the rule:

  > A long-lived integration branch already carries earlier runs' already-reviewed
  > commits, so a plain branch-vs-base diff re-presents all of them: measured on the
  > run that found this defect, branch-vs-base was 211 files and about 30,000
  > insertions, against only the files that run actually landed.

- **When the branch-vs-base fallback applies.** The skill keeps "whether the digest
  names no packet or every packet ended failed, rolled-back, blocked or interrupted;
  such a run has no narrower boundary to offer". It used to read:

  > This includes, but is not limited to, a digest that names no packet at all — it
  > also covers a run whose packets all ended failed, rolled-back, blocked or
  > interrupted, which has a non-empty digest and still no such commit. Either way,
  > there is no run-owned trailer to anchor a parent on, so the base comparison is the
  > only diff available — it may re-present already-reviewed work from earlier runs,
  > but a run that landed nothing traceable has no narrower boundary to offer instead.

- **Why each note becomes a finding.** The skill keeps "since the findings index, not
  the review file, is what the next run can see". It used to read:

  > so the note survives this run: the findings index is the only thing §2's
  > fresh-run write carries forward, and `begin-run` prunes the run directory holding
  > the review file after two runs, so a note left only in that file is a note the
  > next run cannot see.
