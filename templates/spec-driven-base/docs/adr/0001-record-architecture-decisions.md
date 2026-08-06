# 0001. Record Architecture Decisions

Date: {{DATE}}

## Status

Accepted

## Context

This project uses AI-assisted development. Long-lived architectural decisions need a stable, version-controlled home that can be read by both humans and AI agents. Some decisions affect many future features and should not be buried inside one feature specification or implementation plan.

## Decision

We will record durable architectural decisions as Architecture Decision Records in `docs/adr/`.

The `gspec/architecture.md` file provides the current system overview. ADRs explain why important decisions were made, what alternatives were considered, and what consequences follow.

Planning and implementation must read relevant ADRs before proposing plans, tasks, or code changes.

## Consequences

- Major architectural decisions have a single canonical location.
- AI agents must not re-litigate accepted ADRs unless explicitly asked.
- Superseded decisions must be recorded by creating a new ADR rather than silently editing history.
- `gspec/architecture.md` may summarize ADRs but should not duplicate their full rationale.
