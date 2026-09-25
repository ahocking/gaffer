---
spec-version: v2
depends_on: [per-agent-model-routing, implementer-continuation, dispatch-progress-metrics, run-metrics, handoff-verification-contract]
---

# Feature: model-comparison-harness

## Overview

`per-agent-model-routing` made `model_routing` in `.agents/project-overrides.yaml`
the repo's routing policy. It deliberately left open which values belong in it,
and named a model comparison as the future source of them. Nothing produces that
evidence today. The only data point is one confounded run. In the
`capability-auto-complete` run, all four prose packets on Sonnet needed a
reviewer fix, and the one packet on Opus passed first time. The competing
explanation is that prose packets carried no test sweep, a gap
`handoff-verification-contract` has since closed. One run cannot tell those two
explanations apart.

This feature is a harness that replays packets which already landed, each from
its parent commit and in isolation. It varies one role's model through
`model_routing` and holds a blinded reviewer fixed as the judge. The replays of a
packet receive byte-identical handoff input, and every replay's quality and cost
is recorded. The reviewer then ranks the models' final diffs side by side. The
output is a report per model and packet class, plus a *proposed* `model_routing`
change that the operator applies by hand, or does not. The first experiment
varies the implementer, across Fable 5.1, Opus 5.5 and Sonnet 5.

## Users & Use Cases

- **The operator** wants to set implementer routing from evidence rather than
  one run, measured separately on prose and code packets. They approve the
  spend before anything runs, and read a report that says which model to route
  the role to, why, and whether prose and code disagree.
- **The operator, later** wants to compare another role, add a model such as
  Haiku 4.5, or point the harness at a consumer repository, each as a change of
  settings whose results add to the stored ones.

## Scope

**In**
- Experiment settings: the varied role, the model set, the fixed reviewer model,
  the pinned model ids, the reasoning effort every session runs at, the source
  repository, the number of packets per class, and the code and prose file
  sets.
- Selecting landed packets and classing each one as prose or code.
- Isolated replays from each packet's parent commit, with the varied role's
  model set through `model_routing` and one handoff per packet, original or
  rebuilt.
- Per-replay records of outcome, verdict, fix rounds, sweeps and cost, persisted
  so a stopped experiment resumes.
- A blinded side-by-side ranking per packet.
- A spend estimate, and a gate that waits for the operator's go-ahead.
- A per-cell report and a proposed `model_routing` change.

**Out**
- Using the reviewer as a subject. It is the fixed judge in every experiment.
- Writing to `project-overrides.yaml` or to any other routing configuration. The
  proposal is text for the operator.
- Running the first experiment against any repository other than this one. The
  source-repository setting still exists.
- Comparing reasoning-effort levels.
- Changing how the loop reviews, routes or lands a live packet. Replays use the
  loop's path as it stands, minus the escalation decider.
- Tier routing: building it, or filing a feature for it. `model_routing` keeps
  one model per agent; the report states only what a split would change.

**Deferred**
- A separate tier-routing feature, which the operator decides whether to file
  after reading the report.
- The items under Deferred Decisions below.

## Capabilities

- [x] **P0**: An experiment is defined entirely by settings
  - the settings are: the varied role, the model set, the reviewer model, the
    source repository, the per-class packet count, and the code and prose file
    sets. The first experiment's values are `implementer`; Fable 5.1, Opus 5.5
    and Sonnet 5; this repository; 8 prose plus 8 code packets; and the default
    file sets — code is `scripts/` and `hooks/`, prose is `agents/`,
    `skills/`, `templates/`, `docs/` and `CLAUDE.md`
  - the varied role may be any loop-dispatched role except the reviewer. A
    setting that names the reviewer, the loop-driver session or a role the loop
    does not dispatch is refused before selection, and the refusal names the
    setting
  - a model not accepted by the validation that `model_routing` already
    applies is refused in the same way, before selection

- [x] **P0**: Packets are selected from landed history and classed as prose or code
  - a candidate is a packet in the source repository with a landed
    `[orch packet:<id>]` commit whose handoff can be supplied: its original
    handoff file still exists, or its task resolves in the plan file at the
    parent commit. A packet with neither is excluded and named in the
    selection, never guessed. Class is decided from that commit's changed
    files, ignoring the loop's own plan and PRD checkbox flips under `gspec/`,
    and this is the feature's one definition of class: **code** when at least
    one file is in the code set; **prose** when none is and at least one is in
    the prose set. A packet matching neither is not a candidate
  - each class includes at least two distinct tiers, read from the landed
    commit's `[orch tier:...]` trailer, and at least one packet whose measured
    original fix rounds are 1 or more, where such candidates exist. The
    selection lists each chosen packet with its title, class, tier
    (`unrecorded` when the commit has no tier trailer) and original fix rounds,
    read from the routing records of the packet's original run; where the loop
    has pruned those, fix rounds read `unmeasured`, never 0
  - a shortfall — fewer candidates than a class asks for, or a class missing
    the tier or fix-round mix above — is reported, and selection proceeds with
    the candidates found. It never fills a gap from the other class

- [x] **P0**: The operator approves the spend before any replay starts
  - before the first replay, the harness states the replay count (packets ×
    models). It also states a cost estimate in tokens and API-equivalent
    dollars, derived from the selected packets' own recorded original cost
  - a selected packet whose original cost is unmeasured is named, and the
    estimate says it excludes that packet. It is never counted as 0
  - no replay starts until the operator says to go ahead. When a stopped
    experiment is resumed, the harness states the remaining count and its
    estimate, and waits again

- [x] **P0**: Each replay runs isolated from the parent commit on the configured model
  - a replay starts from the parent of the packet's landed commit, in an
    isolated checkout. The main checkout's working tree, its `.agents/` state
    and every branch other than the experiment's own are unchanged by any
    replay, and no replay writes a roadmap or plan edit or any commit beyond
    the packet's own work
  - every replay of one packet receives byte-identical handoff input: the
    original handoff file when that still exists, otherwise one rebuilt from
    the packet's task in the plan file at the parent commit, through the
    loop's handoff-writing path so the required-verification block is appended
    exactly as on a live handoff. The replay then runs the loop's attempt, fix
    and review path up to the packet attempt limit. The escalation decider
    never runs inside a replay
  - the varied role's model is set through `model_routing` in the replay's
    configuration, and never passed per dispatch. A replay whose run metrics
    show `dispatches_with_model_override` above 0, or a model other than the
    configured one in `by_agent_role.<role>.models`, fails the routing check

- [x] **P0**: The reviewer is fixed across the experiment and blind to the model
  - every review, and every ranking in an experiment, runs on the one reviewer
    model the settings name, and each replay record stores that model
  - nothing the reviewer receives, or can read in the checkout it reviews,
    names or identifies the model that produced a diff, in a review or a
    ranking. That covers the handoff, the result file, commit messages and
    trailers, branch and path names, the replay's routing configuration, and
    any metrics or attribution files in the tree. The diffs given for review
    and for ranking exclude the routing-configuration change, and the routing
    check reads metrics collected outside the reviewed checkout

- [x] **P0**: Every replay is recorded with its outcome, sweeps and cost
  - each replay ends in exactly one outcome, tested in this order: `invalid`
    when it fails the routing check, or crashes or pauses without a verdict;
    `escalated` when the reviewer returns `escalate`, or the loop would route
    it to the decider or to a stop while an attempt remains; `failed-at-limit`
    when the attempt limit is reached without a `pass` verdict, including the
    loop's own past-limit routing; `passed` when the reviewer returns `pass`
    - a replay that ends refused is scored by whose line was refused: the
      varied role's own line refused twice (or, were the varied role the
      reviewer, its token outside the routing vocabulary) counts against that
      model as not passed, `escalated` while an attempt remains and
      `failed-at-limit` when none does; a fixed role's line refused (the fixed
      reviewer's twice-refused line or out-of-vocabulary token, or any other
      role not under test) is `invalid`, a harness fault that is rerun and left
      out of the pass rate
  - the record carries the first-attempt verdict in the loop's routing
    vocabulary (`pass`, `fix`, `retry`, `escalate`), the number of fix rounds
    the replay ran (for a `passed` replay, the rounds before `pass`), and whether the sweeps the handoff required pass on the
    final diff
  - cost is recorded as tokens and API-equivalent dollars, from the existing
    run-metrics and spend tooling and the per-dispatch rows of
    `dispatch-progress-metrics`. A figure those sources cannot supply is
    `null`, never 0; every model in the price table the sources use is
    priced, so no arm's cost reads unpriced
  - every session an experiment starts runs at the one reasoning effort its
    settings name, which no environment override can change; a replay whose
    transcripts show another effort fails the routing check, and each record
    carries the effort
  - each record is stored with the experiment's settings once its outcome is
    decided, and survives the session. A resumed experiment runs only replays
    with no stored record, and re-running an `invalid` replay stores a new
    record that ranking and the report use in its place

- [x] **P0**: The fixed reviewer ranks each packet's final diffs side by side
  - a packet is ranked once every model in the set has a `passed`, `escalated`
    or `failed-at-limit` replay for it. The reviewer receives all of those
    final diffs together, unlabelled, in an order randomized per packet, and
    returns a strict best-to-worst order with no ties and a one-line reason for
    each diff
  - the mapping from label to model is stored apart from what the reviewer
    receives, and applied only after the ranking is recorded
  - a packet with an `invalid` replay is not ranked until that replay has been
    re-run, and the report counts the packets left unranked

- [x] **P0**: A report per cell proposes a `model_routing` change
  - one cell is one model × packet class. Each cell reports its pass rate
    (`passed` over non-`invalid` replays, so `escalated` counts as not
    passed), its mean fix rounds among `passed` replays, its mean rank, and its
    mean cost in tokens and dollars, each with its n. A cell with no scored
    replay reads unmeasured. The report states, per packet, whether its handoff
    was original or rebuilt
  - the report ends with a proposed `model_routing` change for the varied role:
    one model, the map's actual shape, reasoned by citing cells. Whenever the
    prose and code cells favour different models, it says so and states what a
    per-tier split would change in cost and quality against that single value
  - when any model in the set has an unmeasured cell, the report proposes no
    change and names the unmeasured cells as the reason
  - nothing in the repository's routing configuration changes as a result

- [x] **P1**: Stored results re-render and experiments accumulate
  - rendering the report twice from the same stored results produces identical
    output, and neither render runs a replay
  - a later experiment, whether on another role, another model or another
    repository, adds records beside the existing ones. Cells are never pooled
    across different varied roles, reviewer models or source repositories, and
    ranks from different ranking sets are never averaged together

- [x] **P0**: Every replay session runs unattended, and a denied action is a harness fault
  - every replay, review-view and ranking session starts in the bypass
    permission mode, confined to that session's disposable clone, so no step
    waits on a permission prompt nobody can answer. The guardrail's hard-deny
    rules still apply inside it
  - a replay in which any session had a tool call denied, by the guardrail or
    by the permission system, is `invalid`: a harness fault that is rerun and
    left out of the pass rate, never counted against the varied model

- [x] **P0**: A harness session cannot write outside its own clone, and every denial is read and explained
  - a write by any replay, review-view or ranking session whose target
    resolves outside that session's own clone or view is refused inside the
    session, whatever its permission mode; its working directory alone is never
    the confinement. A target that cannot be resolved is refused too
  - denied calls are read from every harness session, the ranking session
    included. A session whose transcript cannot be found or is not in a
    recognised form reads its denials as unmeasured, never as 0
  - an invalid replay's reason reaches the operator: the report counts
    denial-invalid replays per model, and a rerun is not recommended when the
    same denial would stop it again

- [x] **P0**: The confinement hook and the Bash sandbox allow the same write boundary
  - the session's own temp directory is writable under both halves of the
    confinement or under neither, never one, so an ordinary scratch write is
    not scored as a denial
  - an invalid replay whose record also counts denials says so wherever its
    cause is shown, so a rerun is never recommended past a denial that would
    stop it again

- [ ] **P2**: Harness steps never act on what a session planted in its clone
  - no harness-side step run outside the sandbox (staging, copying, landing)
    executes a command or follows a link that a session wrote into its clone:
    git command hooks such as `core.fsmonitor` are neutralised, the clone's
    `.git/` is not writable from a session, and harness-side copies never
    follow a symlink or write through a hard link

## Dependencies

- `per-agent-model-routing`: the `model_routing` lookup, its model validation,
  and `dispatches_with_model_override`. Shipped.
- `implementer-continuation`: the loop has to stop changing under the
  comparison, and continuations change how an implementer dispatch ends.
  Planned.
- `dispatch-progress-metrics`: the per-dispatch cost, kind and progress rows
  that replay cost is read from. Planned.
- `run-metrics`: the collector, `by_agent_role.<role>.models` and the spend
  tooling's dollar pricing. Derived-done.
- `handoff-verification-contract`: the required-verification block each
  replay's handoff carries. Shipped.

## Assumptions & Risks

- Assumption: replays run on the loop as it stands today, not as it stood when
  each packet first landed. The original outcome is context, not a baseline.
- Risk: 8 packets per cell is a small sample. Cells report their n, so a thin
  difference reads as thin.
- Risk: blinding can leak through a model's style of writing, and removing
  labels closes only the channels the reviewer can reach. When the fixed
  reviewer model is also one of the subject models, it may prefer its own
  diffs.
- Risk: the estimate rests on original costs recorded under older collectors. A
  replay under the current loop may cost more or less than that.

## Success Metrics

- After the first experiment, all six implementer cells (three models × two
  classes) are measured. The operator has one proposed `model_routing` value
  for the role, backed by cited cells, and applies or rejects it by hand.
  Where prose and code diverge, the operator also has the stated cost and
  quality difference of a per-tier split, and decides from it whether to file
  a tier-routing feature.
- A second experiment on a different role runs with changed settings and no
  change to the harness itself, checkable from the absence of any harness diff
  between the two experiments.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **How the estimate turns original cost into a forecast.** Whether to scale
  by model price and how to handle fix rounds belong to the architecture step.
  The capability fixes only what the estimate is derived from.
- **Where results are stored.** Any location works that survives run-directory
  pruning and stays gitignored as bookkeeping.
