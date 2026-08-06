# ADR 0007 — Cross-harness parity: a Codex (GPT-5.x) overlay alongside the Claude Code plugin

- Status: Accepted
- Date: 2026-07-06
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0001](0001-phase2-scope-new-apps-first.md) (portability
  intent), the whole agent/skill/guard component model. Does **not** change any
  existing Claude Code behavior — it adds a second host target.

## Context

This repo is packaged as a **Claude Code plugin**: subagents (`agents/*.md`),
skills (`skills/<name>/SKILL.md`), an approval guardrail hook
(`hooks/guard.sh` + `hooks/hooks.json`), MCP stubs (`.mcp.json`), and a
`CLAUDE.md` operating brief. The design intent was
always an "AI Engineering Operating System" that is IDE-agnostic and
repository-centric — not tied to one vendor's agent runtime.

The user asked whether the same orchestration experience — **multi-agent
orchestration, agent personas, and skills** (guardrails explicitly
de-emphasized) — can run on **OpenAI Codex (CLI + VS Code extension) backed by
GPT-5.5 / GPT-5.1-Codex**.

A verified deep-research pass (21 sources, 25 claims adversarially verified, 22
confirmed) established that Codex now has **first-party equivalents for every
primitive this plugin depends on**, one of which is literally the same open
standard:

| This plugin (Claude Code) | Codex native equivalent | Parity |
|---|---|---|
| Subagent `.md` (persona + `tools` + `model`) | `.codex/agents/*.toml` (project) / `~/.codex/agents/*.toml` — `name`, `description`, `developer_instructions` + per-agent `model`, `model_reasoning_effort`, `sandbox_mode`, `mcp_servers` | near 1:1 |
| `skills/<name>/SKILL.md` | `SKILL.md` on the **same open "agent skills" standard**; explicit (`/skills`, `$name`) **and** implicit/description-triggered invocation | identical standard |
| Chief-engineer delegating via the Task tool | Native gaffer: parent spawns specialized subagents in parallel, consolidates results; `[agents]` in `config.toml` (`max_threads` default 6, `max_depth` default 1); `/agent` thread control; model-callable `spawn_agent`/`wait_agent`/… | high, with one caveat |
| `CLAUDE.md` | `AGENTS.md` (hierarchical, root-down concatenation, closer files override) | full |
| `.mcp.json` | `.codex/config.toml` `[mcp_servers.*]` (STDIO + Streamable HTTP; CLI and IDE share config) | full |

Two gaps matter for our use case, both mitigable:

1. **No autonomous self-delegation by default.** Codex spawns subagents only
   when explicitly asked; the parent does not decide on its own to delegate the
   way our chief-engineer does. Because `spawn_agent` is exposed to the model as
   a tool, an `AGENTS.md` directive pre-authorizing delegation restores the
   behavior. A first-class opt-in is requested-but-unshipped upstream
   (openai/codex#18513).
2. **Per-persona model routing is CLI-only.** Profiles (`--profile`, which bind a
   persona to a model + reasoning effort) do not apply in the VS Code panel,
   which offers only a manual model switcher. Full-fidelity multi-persona routing
   therefore runs from the **Codex CLI inside the VS Code integrated terminal**,
   not the IDE chat panel.

Time-sensitivity is real: Codex's subagents/skills surface shipped and churned
across early–mid 2026 (docs snapshots Mar–Jul 2026, CLI ~v0.125–v0.131); exact
defaults and IDE feature-gating may move. Verify against live docs at build time.

## Decision

**Ship a Codex overlay as a second host target for the same orchestration layer,
without disturbing the Claude Code plugin.** Concretely:

1. **The prompts are the shared asset; the packaging is per-host.** The persona
   instructions and skill bodies are portable English. The Claude Code manifest
   (`.claude-plugin/`, `agents/*.md` frontmatter, `hooks.json`) and the Codex
   manifest (`.codex/agents/*.toml`, `config.toml`, `AGENTS.md`) are thin,
   host-specific adapters over that shared content.

2. **Personas → `.codex/agents/*.toml`.** One project-scoped TOML per existing
   agent (`chief-engineer`, `architect`, `implementer`, `reviewer`,
   `ux-designer`), each carrying the agent's instructions as
   `developer_instructions` plus per-agent `model`, `model_reasoning_effort`, and
   `sandbox_mode` chosen to mirror the Claude least-privilege intent (e.g.
   reviewer = high reasoning / `read-only`; implementer = `workspace-write`).

3. **Skills → Codex `SKILL.md`.** Reuse the same standard; where a
   `skills/<name>/SKILL.md` is already standard-compliant it ports with little or
   no change. Do **not** target Codex's `~/.codex/prompts` custom prompts — they
   are deprecated in favor of skills.

4. **`CLAUDE.md` operating brief → `AGENTS.md`**, and use `AGENTS.md` to
   pre-authorize delegation, closing gap #1.

5. **MCP stubs → `.codex/config.toml` `[mcp_servers.*]`**, secrets still via
   `${VAR}`, never inlined — same rule as `.mcp.json`.

6. **Primary host is the Codex CLI** (runnable in the VS Code terminal), because
   per-persona model routing via profiles is CLI-only (gap #2). The IDE panel is
   a supported-but-lower-fidelity single-model host.

7. **Guardrails are out of scope for v1** per the user's ask. `guard.sh`'s logic
   is portable bash and can later be wired to Codex's gating model, but this ADR
   does not commit to it. The Codex overlay ships **without** the approval
   guardrail initially; this is called out as a known reduction in safety posture
   relative to the Claude Code target (see Consequences).

8. **Incremental, not a rewrite.** v1 is a generated `codex/` (or root
   `.codex/`) overlay derived from the existing prompts. A later refactor to a
   single shared-core + two generated adapters (Claude + Codex) is deferred to a
   follow-up ADR if the duplication proves costly.

The concrete file layout, mapping, and build/verify steps live in the companion
overlay plan.

## Consequences

- **A high-fidelity replica of the persona team + skills runs on Codex + GPT-5.x
  today**, mostly via native mechanisms and reuse of existing prompt content. The
  one behavioral difference the user will feel is having to authorize/trigger
  delegation (via `AGENTS.md`) rather than relying on a fully autonomous
  orchestrator.
- **Two manifests now describe one behavior.** Until the shared-core refactor,
  persona/skill edits must be reflected in both the Claude and Codex adapters.
  Mitigation: keep the authored prose in one place per persona/skill and treat
  the TOML/frontmatter as generated-ish wrappers; the plan proposes a source of
  truth to minimize drift.
- **No guardrail on the Codex path in v1.** The Claude target keeps `guard.sh`;
  the Codex target relies only on Codex's own `sandbox_mode`/approval modes,
  which are coarser than our path/pattern gates. Acceptable because the user
  de-prioritized guards and `sandbox_mode` (e.g. `read-only` for the reviewer)
  still provides a floor — but it is a deliberate, documented gap, not parity.
- **Upstream drift risk.** Codex's subagent/skill defaults and IDE gating are
  moving. The plan requires a live-docs verification step before building and
  records the exact assumptions (defaults, deprecations) so they can be
  re-checked.
- **The repo's stated portability goal is realized concretely** — it becomes
  harness-agnostic in fact, not just in intent.

## Open questions (carried into the plan)

- Exact current Codex model IDs / reasoning tiers assignable per agent (the
  "GPT-5.5 / GPT-5.1-Codex" naming was not independently confirmed); the design
  holds regardless since per-agent model is a config field.
- Whether to adopt the community `leonardsellem/codex-subagents-mcp` (or its
  successor `codex-specialized-subagents`) for stronger, PR-reviewable
  file-based delegation with harder context isolation, vs. relying solely on
  native subagents.
- Whether/when to do the shared-core + dual-adapter refactor to eliminate the
  two-manifest duplication.
