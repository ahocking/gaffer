# ADR 0001 — Phase 2 targets new-app bootstrap first; existing-app onboarding is deferred

- Status: Accepted
- Date: 2026-07-04
- Deciders: user (tech lead), orchestration plugin

## Context

Phase 1 delivered the orchestration layer as a **Claude Code plugin** (agents,
skills, a task-packet template, and the `guard.sh` guardrail hook) rather than
the standalone `ai run chain` CLI sketched in the original design notes. The
roadmap's **Phase 2 = "project bootstrap"** must therefore be
interpreted through the plugin model, not the original CLI model.

Adopting this orchestration into a repo has two fundamentally different shapes:

1. **New app (greenfield).** Empty or near-empty repo. Bootstrap generates the
   full structure: source skeleton, `.agents/`, `.specify/`, `specs/`, `adr/`,
   `docs/`, and the plugin wiring. Nothing pre-exists to conflict with.

2. **Existing app (retrofit).** The repo already has source, and may already
   have spec/design artifacts authored by hand or by other tools. The reference
   consumer repo is exactly this case: it already carries `gspec/` (architecture, research,
   stack, style, practices, profile), `specs/001-*`, `docs/adr/`, and a
   roadmap. Retrofitting cannot blindly scaffold — it must first **analyze the
   app's existing use of spec/design docs (gspec + Spec Kit)**, detect what is
   present vs missing, and wire orchestration in **non-destructively**.

These are different enough that trying to serve both from one code path in
Phase 2 would slow down the common greenfield case and risk clobbering real
artifacts in the retrofit case.

## Decision

1. **Phase 2 focuses on the new-app / greenfield bootstrap path.** Templates,
   blueprints, and the bootstrap flow are designed for empty or new repos.

2. **Existing-app onboarding is a recognized, deferred capability.** It is not
   dropped — it is scheduled after the greenfield path is proven. When built, it
   must:
   - analyze the target repo's current use of **gspec** and **Spec Kit**
     (which artifacts exist, their completeness, and any drift),
   - report gaps rather than assume a blank slate,
   - wire orchestration in **idempotently and non-destructively** (never
     overwrite existing specs/ADRs/docs without explicit approval).

3. **The reference consumer repo is reserved as the test case for the retrofit path.**
   We deliberately leave it untouched now so it remains a realistic,
   hand-authored existing app to validate onboarding against later.

## Consequences

- The Phase 2 scaffolder is built for the greenfield case first, but should be
  written **idempotent and non-destructive from the start** so the same core can
  be reused by the future retrofit path (which adds an analyzer/onboarding step
  in front of it).
- A future ADR will cover the existing-app onboarding design (the gspec/Spec Kit
  analyzer, gap reporting, and safe-merge strategy).
- Nothing in the reference consumer repo changes as part of Phase 2.
