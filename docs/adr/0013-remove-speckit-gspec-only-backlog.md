# ADR 0013 — Remove GitHub Spec Kit; gspec-only two-tier execution backlog

- Status: Accepted
- Date: 2026-07-17
- Deciders: user (tech lead), orchestration plugin
- Supersedes in part: [ADR 0002](0002-spec-driven-bootstrap-via-live-installers.md) (the Spec Kit installer half)
- **Amended by: [ADR 0020](0020-gspec-boundary-and-version-pin.md) (2026-08-03).** The
  Spec Kit removal stands. The two file paths below do NOT: gspec 2.x moved plans from
  `gspec/features/<x>.plan.md` to `gspec/tasks/<slug>.md`, and `gspec/roadmap.md` moved
  out of `gspec/` to a slimmed, plugin-owned `.agents/roadmap.yaml` (its `status` and
  `parallel_group` fields are now derived, not stored). All gspec reads go through
  `scripts/gspec-backlog.sh` against a pinned version. The "one roadmap" standing rule
  survives unchanged.

## Context

A 2026-07-17 audit of the three consumer repos found **Spec Kit was never a live
driver in any of them**:

- **The web app** produced zero speckit artifacts across 78 commits (`specs/` held only
  a `.gitkeep`); execution ran on gspec + `docs/backlog.md` + `.agents/run-state.yaml`.
- **The Unity game** quarantined both of its speckit chains on 2026-07-15
  (SUPERSEDED banners, `tasks.md` → `tasks.superseded.md` specifically so the
  run-loop could not discover them); one frozen plan actively contradicted the
  current art direction. Execution ran on `gspec/features/<x>.plan.md` checkboxes.
- **The reference consumer repo** had already removed the `.specify/` engine and `.junie/` surface (its
  own ADR 0002) and hand-maintained only the `specs/NNN/{spec,plan,tasks}.md`
  artifact *shape* as gate-tagged execution wrappers.

The full speckit chain **over-documents** (6–8 files per feature — spec, plan,
tasks, research, data-model, quickstart, contracts, checklists — of which only
`spec.md` and `tasks.md` are ever read back) and is **drift-prone** (frozen plans
encode overturned decisions). Meanwhile the plugin-propagated `spec-setup.md` still
narrated the hybrid gspec+SpecKit workflow as current, making it stale in all three
repos at once. gspec PRDs + ADRs + the orchestration autonomy loop already *are* the
real workflow.

The three repos had also diverged on where the execution backlog lives
(`specs/NNN/tasks.md` vs `gspec/features/<x>.plan.md` vs `docs/backlog.md`), and the
`run-loop`/`resume` skills carried a dual discovery path to cope.

## Decision

Remove Spec Kit as a tool from the plugin bootstrap and from the consumer repos.
Replace its execution role with **two gspec-owned files**:

1. **`gspec/features/<x>.plan.md`** — per-feature task checklist. Tasks may carry
   gate tags ported from the reference consumer repo (`[GATE:*]` soft gate, `[STOP:*]` hard stop) so the
   autonomy loop knows its hard/soft gate split. This is what the loop *executes*.
2. **`gspec/roadmap.md`** — an ordered, dependency-aware feature DAG (per feature:
   `slug`, `order`, `depends_on`, `parallel_group`, `status`, a required `why`
   rationale, and `prd`/`plan` links). The loop reads it to pick the next feature
   (lowest `order` whose `depends_on` are all `done`) and the parallel-safe set.

`.agents/run-state.yaml` remains the durable cursor. gspec stays the source of truth
for product/architecture knowledge and feature PRDs; ADRs stay durable decisions.

Two **standing rules** apply to every repo:

1. **One roadmap.** `gspec/roadmap.md` is the *single* sequencing source. No parallel
   hand-maintained prose roadmap/backlog survives beside it (retire `docs/roadmap.md`,
   `docs/backlog.md`, …); fold any "why here" rationale into the `why` field. A
   human-readable rollup, if ever wanted, is *generated* from the roadmap.
2. **No off-map gspec docs.** A speckit-style "constitution" or bundled
   "non-negotiable principles" doc is **distributed**, not recreated as a new gspec
   doc: descriptive knowledge → the standard gspec docs (product identity/philosophy
   → `profile.md`; architectural invariants → a "Core Invariants" section in
   `architecture.md`; testing/verification → `practices.md`; tech constraints →
   `stack.md`); the enforceable "MUST never / refuse or escalate" subset →
   `.agents/domain-rules.md` (+ mirrored `guard-extra-*`). The gspec doc set stays
   standard: profile/stack/style/practices/research/architecture/features.

## Alternatives Considered

- **Keep the hybrid (status quo):** rejected — pays a drift/duplication cost for a
  tool no repo actually runs.
- **Per-repo `specs/NNN/tasks.md` (reference-repo shape) without the tool** as the canonical
  home: rejected — keeps a second top-level tree; the gate-tagged task shape is
  preserved by folding it into `gspec/features/<x>.plan.md` instead.
- **Single `docs/backlog.md` (web-app shape)** as the sole mechanism: rejected — loses
  the per-feature altitude; its ordering/dependency idea is preserved in `roadmap.md`.
- **A dedicated `gspec/constitution.md`** to re-home constitution-style content:
  rejected — a new off-map gspec doc that triplicates content already owned by
  profile/architecture/practices/stack + `.agents/domain-rules.md` (which already
  carries the enforceable subset). Distribute instead.

## Consequences

- `new-project` stops installing Spec Kit (drops the `specify init` step and the
  `SPECKIT_REF` pin); the `spec-setup.md` and `CLAUDE.md` templates are rewritten to
  the gspec-only model and encode the two standing rules above.
- `run-loop`/`resume` read `gspec/roadmap.md` → `gspec/features/<slug>.plan.md`, not
  `specs/**/tasks.md` / `.specify/`; the dual backlog discovery path collapses.
- The architect authors `roadmap.md` + `.plan.md` (via the `gspec-*` skills) instead
  of speckit spec/plan/tasks; the `speckit-*` surface is dropped from agent briefs.
- Consumer migration is required (see the migration plan): the reference consumer repo additionally
  re-homes ~20 inbound ADR/roadmap links off `specs/NNN/…`; the Unity game
  distributes its constitution and relocates it out of the deleted `.specify/`.
- gspec `analyze` (spec-to-spec) and `audit` (spec-to-code) still cover drift
  detection; ADR 0002's gspec-installer decision still stands.

## Related Artifacts

- [ADR 0002](0002-spec-driven-bootstrap-via-live-installers.md)
- [ADR 0012](0012-delegated-loop-driver.md) (the loop driver the backlog feeds)
- `templates/spec-driven-base/spec-setup.md`
