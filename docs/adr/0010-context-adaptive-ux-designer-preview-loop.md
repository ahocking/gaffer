# ADR 0010 — Context-adaptive ux-designer preview loop (web + Unity)

- Status: Accepted
- Date: 2026-07-14
- Deciders: user (tech lead), orchestration plugin
- Relates to: `agents/ux-designer.md` and the overlay
  `templates/spec-driven-base/.agents/project-overrides.yaml`. Consumes the
  per-repo override mechanism established across the `.agents/` config surface.

## Context

The `ux-designer` agent iterates against the **rendered** UI through a preview
loop. That loop was **web-only** in two hardwired ways:

1. **Static tool grant.** Its `tools:` frontmatter listed only
   `mcp__Claude_Preview__*` (a host-provided web/DOM preview). Claude Code agent
   tool grants are static — there is no runtime "if Unity, grant X" — so an agent
   simply cannot call a server that is not in its list, even when connected.
2. **DOM-shaped workflow.** Loop 1 booted a dev server from `.claude/launch.json`
   and drove the DOM (`preview_inspect` computed styles + bounding boxes,
   `preview_snapshot` accessibility tree, `preview_click`/`fill`/`eval`).

The first Unity consumer (a Unity 6000.x game) drives its UI
through the **Unity MCP** (`com.ivanmurzak.unity.mcp`, server `ai-game-developer`),
which exposes generic GameObject/Component/`script-execute` tools — no dev server,
no DOM, no CSS. Out of the box the ux-designer could not see or touch that surface;
it fell to graceful degradation (ask for screenshots).

The user wants the **shared** plugin — not a per-repo override — to serve both web
and Unity, switching by project context, while existing web repos keep working
unchanged.

## Decision

**One adaptive `ux-designer`: union tool grant + a declared mode that selects one
of two loops, defaulting to web.**

- **Union tool grant.** The agent's `tools:` now also carries
  `mcp__ai-game-developer__*` alongside the existing `mcp__Claude_Preview__*`.
  Tools whose server is not connected are simply uncallable, so carrying both is
  harmless.
- **Mode resolution — explicit → auto-detect → web.** The agent picks its loop by:
  1. `ux.preview_mode` in `.agents/project-overrides.yaml` (`web` | `unity` |
     `none`), if set;
  2. else auto-detect — **unity** if `ProjectSettings/ProjectVersion.txt` or a
     Unity-style `Packages/manifest.json` exists, **web** if `.claude/launch.json`
     or a `package.json` dev script exists;
  3. else **default `web`**. Repos that predate this field keep the web loop.
- **Two loops, one prompt.** Loop **1A** is the unchanged web/DOM loop. Loop **1B**
  drives the *already-open* Unity Editor via the Unity MCP: game-view screenshots
  for the spatial read; `RectTransform`/`LayoutGroup`/`CanvasScaler` inspection as
  the analog of computed styles + bounding boxes; Game-view resolution switching
  for adaptivity; play-mode toggling to walk a flow. A shared **graceful
  degradation** section covers either surface being unavailable.
- **Declared schema.** The overlay `project-overrides.yaml` documents an optional
  `ux:` block (`preview_mode`, `unity_mcp_server`); omitting it triggers the
  auto-detect-with-web-fallback above.

**Accepted constraints, documented in the agent prompt:**

- **Server-name coupling.** Because tool grants are static, the grant hardcodes the
  default server name `ai-game-developer` (what `unity-mcp-cli setup-mcp` writes).
  `ux.unity_mcp_server` is informational; a repo that renames the server must
  re-grant the tools itself.
- **No a11y tree in Unity.** Loop 1B has no `preview_snapshot` equivalent, so
  accessibility becomes a manual reasoning step with flagged, unverifiable gaps.
- **Editor-mediated writes bypass the guard.** Unity scene/prefab edits made
  through the MCP are saved by the Editor, not the Edit/Write tools, so the
  approval guardrail does not see them. Mitigation is scope discipline
  (`allowed_paths.frontend` + `.agents/domain-rules.md`), not enforcement.

## Consequences

- **Web repos are unaffected.** With no `ux:` block, auto-detect + web fallback
  reproduces prior behavior; web consumers need no change.
- **Unity repos need two things.** Set `ux.preview_mode: unity` in
  `project-overrides.yaml` and have the Editor open (the agent cannot boot it). No
  per-repo agent override is required — the reason this lives in the plugin.
- **Rejected alternatives.** (a) Two agents (`ux-designer-web`/`-unity`) + routing —
  rejected because the orchestration chains delegate to the name `ux-designer`;
  keeping one name avoids rewiring every chain. (b) A per-repo override agent in
  each Unity consumer — rejected as duplicated prompt surface that drifts from the
  plugin.
- **Validation.** `claude plugin validate .` for frontmatter, plus a smoke test in
  a web repo and a Unity repo. One item to confirm on
  the installed Claude Code version: that the `mcp__ai-game-developer__*` wildcard
  grant is accepted in agent frontmatter (else the grant must enumerate tools).
