# Domain rules — {{PROJECT_NAME}}

> This file is the project-specific complement to the `gaffer` plugin's
> built-in guardrails. The plugin already treats the risks common to any codebase
> — auth, secrets, DB schema/migrations, dependency installs, deploys, and git
> history — as high-risk. **Domain-specific** risk (money movement, PHI, grading,
> …) is not built in; record **this project's** domain boundaries, invariants, and
> risk areas here — and mirror the enforceable ones into `.agents/guard-extra-paths`
> / `.agents/guard-extra-bash` — so every agent honors them.

## Domain overview

_One or two paragraphs: what this system is, the core domain concepts, and the
invariants that must never be silently broken. Link to `gspec/profile.md` and
`gspec/architecture.md` rather than duplicating them._

## Risk boundaries (require human approval)

List the changes that must **stop and ask** before proceeding. Starter set —
keep, cut, or extend to fit the domain:

- Authentication / authorization logic
- Anything that moves money, changes balances, or touches payment/banking
  integrations _(delete if not applicable)_
- Database schema changes and migrations
- Secrets, credentials, `.env`, and CI/deploy configuration
- Public API contract changes (breaking changes to request/response shapes)
- _<add domain-critical modules here>_

## Invariants (must always hold)

- _e.g. "every write to <X> is audit-logged"_
- _e.g. "user-scoped data is never returned across tenant boundaries"_

## Sensitive paths

Globs where changes deserve extra scrutiny (the reviewer weighs these heavily):

- _e.g. `src/**/Auth/**`_
- _e.g. `src/**/Payments/**`_

> **Make these enforced, not just advisory.** The paths you list here are only
> honored voluntarily by agents unless you also add them (as `grep -E` regexes)
> to `.agents/guard-extra-paths`, which the guardrail hook loads and blocks
> writes against. Likewise, project-specific risky commands go in
> `.agents/guard-extra-bash`. Keep the two in sync with this list.

## Not our concern

Things agents can safely change without escalation (helps avoid over-caution):

- _e.g. copy/docs/styling tweaks, test fixtures, non-exported helpers_
