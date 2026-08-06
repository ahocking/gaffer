# Contributing

Thanks for your interest in improving the **gaffer** plugin. This is a
portable, domain-agnostic Claude Code plugin — a reusable orchestration layer
(subagent team, skill chains, task-packet template, autonomy dial, and an
approval guardrail hook) that installs on top of any application repo. Keeping it
generic and safe is the whole point, so a few conventions matter more than usual.

For the deep, authoritative developer brief — the structure rules, the guard's
tier model, the loop's relay/inline crossover, parallel lanes, and the pause
sentinel — read [`CLAUDE.md`](CLAUDE.md). This file is the quick-start and the
etiquette; `CLAUDE.md` is the reference.

## Ground rules

- **Keep it domain-agnostic.** The plugin ships risk defaults common to *any*
  codebase (auth, secrets, DB migrations, dependency installs, deploys, git
  history). Do **not** add domain-specific patterns (money movement, PHI,
  grading, …) to `hooks/guard.sh`. Those belong in a consumer repo's
  `.agents/guard-extra-bash` / `.agents/guard-extra-paths`. A PR that bakes a
  specific domain into the plugin will be asked to move it out.
- **No secrets, ever.** No tokens, keys, emails, or machine-specific paths in any
  committed file. Credentials come from environment variables (`${VAR}`); `.env`
  is gitignored. Hook and skill commands reference files via
  `${CLAUDE_PLUGIN_ROOT}/...`, never an absolute or relative machine path.
- **A behavior worth having is a behavior worth a test.** See Testing below.
- **Record decisions.** Anything that changes the design, a safety boundary, or a
  measured tradeoff gets an ADR under `docs/adr/` (copy the numbering/format of
  the existing ones). If your change invalidates a measured claim in an ADR
  (e.g. the ~20-packet relay/inline crossover), update the ADR **and** the skills
  that cite it in the same PR.

## Repo structure (do not violate)

- Inside `.claude-plugin/` live **only** the two standard manifests:
  `plugin.json` and (optionally) `marketplace.json`. Nothing else.
- Every component directory (`agents/`, `skills/`, `hooks/`) and `.mcp.json`
  lives at the **repo root**, not inside `.claude-plugin/`.
- All component names are **kebab-case**.
- Hook scripts must be executable (`chmod +x`).

### Agents (`agents/*.md`)

YAML frontmatter with `name`, `description`, `tools`, `model`. Keep `tools`
**least-privilege** — the `reviewer`, for example, deliberately has no
`Edit`/`Write`. Two harness facts are easy to break by accident:

- A dispatched agent has **no `Skill` tool** — a brief must give the SKILL.md
  **path** to `Read`, not name a slash command.
- `Task` in agent frontmatter is what **grants** delegation (it maps to a tool
  named `Agent`). Do not rename it, or the agent silently loses the ability to
  delegate.

Model routing intent: **opus** = reasoning/architecture/review/security, **sonnet**
= implementation and research, **haiku** = summarization/docs.

### Skills (`skills/<name>/SKILL.md`)

Frontmatter with `name`, `description`, `argument-hint`. Reference shared files
via `${CLAUDE_PLUGIN_ROOT}/...`.

### The guardrail (`hooks/guard.sh`)

All default policy lives in the clearly-labeled pattern arrays at the top of the
file (`DENY_BASH_PATTERNS`, `ASK_BASH_PATTERNS`, `BASH_WRITE_PATTERNS`,
`SECRET_PATH_PATTERNS`, `REVIEW_PATH_PATTERNS`, …). **Extend coverage there** —
the code below the arrays is mechanism. When you add a risky pattern, add a
matching allow/deny pair to `scripts/test-guard.sh` in the same PR.

## Developing locally

```bash
# Load this directory as a plugin
claude --plugin-dir .

# After editing plugin files, inside the session:
/reload-plugins

# Validate the manifest & structure
claude plugin validate .
```

> Plugin hooks bind at session **process start**, and `/reload-plugins` does
> **not** reload them. To pick up a `hooks/*.sh` or `hooks.json` change, restart
> the session.

## Testing

Six deterministic sweeps guard the shell cores. Run the ones your change
touches; CI runs all of them on every push and pull request.

```bash
scripts/test-guard.sh                # guardrail allow/deny, closed bypasses, guard-extra
scripts/test-runstate.sh             # pause/resume + crash reconcile (seq + parallel lanes)
scripts/test-packet-graph.sh         # dependency-graph math (edges, waves, ready)
scripts/test-worktree.sh             # worktree lane lifecycle + safety gates
scripts/test-pause.sh                # pause sentinel + hook (incl. from a lane worktree)
scripts/test-parallel-pause-e2e.sh   # parallel-pause choreography
```

**Rule:** any change to a deterministic core (`guard.sh`, `runstate.sh`,
`packet-graph.sh`, `worktree.sh`) or the loop/pause skills needs a matching
addition to its sweep. Judgment lives in the agent/skill prompts; mechanism lives
in the scripts — and the scripts are tested.

## Submitting a change

1. Open an issue first for anything non-trivial, so we can agree on the approach
   (and whether it needs an ADR) before you write it.
2. Branch, make the change, add/extend the relevant test sweep, and run it.
3. Keep the diff focused. Prose in agent/skill prompts should match the density
   and idiom of what's already there.
4. In the PR description, note which sweeps you ran and link any ADR the change
   adds or amends.

Do not commit domain-specific risk patterns, secrets, or machine paths — the
guardrail blocks some of this, and review will catch the rest.

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
