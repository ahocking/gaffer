---
spec-version: v2
feature: per-agent-model-routing
---

# Plan: per-agent-model-routing

**The core lookup and its sweep land first. The metrics stamp, the template docs and the kickoff shape follow. The dispatch-site prose lands last.** T1 builds `scripts/routing.sh` and `scripts/test-routing.sh` and wires the new sweep into CI. T2 makes `hooks/metrics-log.sh` stamp every Agent event with the resolved routing. T3 rewrites the `model_routing` comment in both overrides files. T4 adds the two optional routing lines to shape C. T5 switches `metrics.sh collect`/`show` to count overrides against T2's stamp. T6 adds preflight validation, the kickoff lines and the `resolve` sentences to `run-loop` and `resume`. T7 adds `resolve` to the five remaining dispatching files and lands the dispatching-file sweep case in the same packet as the last prompt edit it checks.

**The dispatching-file case is deliberately not in T1.** It asserts `routing.sh resolve` in all seven dispatching files, so it would fail red until the last of them is edited. T7 owns that last edit and the case together.

**CI lists each sweep by name; it does not glob `scripts/test-*.sh`.** `.github/workflows/ci.yml` runs each sweep as its own step, and CLAUDE.md's "How to test the plugin" block lists them by name. T1 therefore owns both files.

**File contention and `[P]`.**
- `scripts/routing.sh` belongs to T1 alone.
- `scripts/test-routing.sh` belongs to T1 and T7, so T7 depends on T1.
- `.github/workflows/ci.yml` belongs to T1 alone.
- `CLAUDE.md` belongs to T1 (sweep list) and T5 (routing and override semantics), which are in different waves.
- `hooks/metrics-log.sh` belongs to T2 alone.
- `scripts/test-metrics.sh` belongs to T2 and T5, so T5 depends on T2.
- `scripts/metrics.sh` belongs to T5 alone.
- `templates/spec-driven-base/.agents/project-overrides.yaml` and `.agents/project-overrides.yaml` belong to T3 alone.
- `templates/report-templates.md`, `scripts/test-report-conventions.sh` and `scripts/report-lint.sh` belong to T4 alone.
- `skills/run-loop/SKILL.md` and `skills/resume/SKILL.md` belong to T6 alone.
- `skills/metrics/SKILL.md`, `skills/review-change/SKILL.md`, `skills/new-project/SKILL.md`, `agents/chief-engineer.md` and `agents/loop-driver.md` belong to T7 alone.

The waves are T1 → {T2, T3, T4} → {T5, T6} → {T7}. Every dep points strictly backwards, and no two tasks in one wave share a file.

**Reflexivity.**
- `scripts/routing.sh` and `scripts/metrics.sh` take effect mid-run, in the run that edits them.
- `hooks/metrics-log.sh` is a hook body. It takes effect on the next tool call in the run that lands T2. That run's Agent events before T2 have no stamp and the ones after it do, so once T5 lands, that run's `dispatches_with_model_override` collects as `null` with the "N of M dispatches carry no routing stamp" note. That is the intended reading, not a regression.
- `.agents/project-overrides.yaml` is re-read by `hooks/guard.sh` on every tool call. T3 changes only the comment above `model_routing:`, and must leave `bypass-ask-tier` and every other key byte-identical.
- Skills are read at dispatch. The driver of an in-flight run keeps the `run-loop` text it loaded at start, so T6's preflight and kickoff lines first render on the next `/gaffer:run-loop`. `agents/loop-driver.md` is re-read at compaction or at the next run. `agents/chief-engineer.md` is re-read at its next dispatch.
- T7 edits `agents/chief-engineer.md` and `agents/loop-driver.md` in their bodies only. No task touches any agent's frontmatter (`tools:` and `model:` stay unchanged), `hooks/hooks.json`, or `.claude/settings.json`, so no packet here needs a session boundary.

Every regression sweep must pass green after every task, and `claude plugin validate .` must stay clean.

## Plan

- [x] **T1** [P] **P0** Add `scripts/routing.sh` with its `resolve`/`validate`/`table` subcommands, and `scripts/test-routing.sh`, and wire the new sweep into CI and CLAUDE.md's sweep list.

  `routing.sh`:
  - executable, `set -uo pipefail` with no `-e`, parsing config by `awk` token-scan only (no `jq` or `python3`);
  - `--root` and `git --git-common-dir` root resolution;
  - agent set derived from `${ORCH_ROUTING_AGENTS_DIR:-<script dir>/../agents}/*.md`, with `loop-driver` excluded;
  - a labelled `VALID_MODELS=(sonnet opus haiku fable)` array at the top, with its dated source comment;
  - `extra_models`, flow and block forms;
  - exit 0 in every config state, and exit 2 only for a usage error.

  Write no condition as a pipe-fed `grep -q`, and pass any `jq`-free line list read by a `while read` loop through `tr -d '\r'`.

  In `scripts/test-routing.sh`, follow `test-runstate.sh`'s preamble and helpers. Use temp roots via `--root` and a fixture `ORCH_ROUTING_AGENTS_DIR`. Assert both the `resolve` output and the `validate` line for:
  - a mapped agent;
  - an unmapped agent;
  - a missing file;
  - `model_routing: {}`;
  - an unknown agent key (`reason=unknown-agent`);
  - a `loop-driver` key;
  - an unrecognized model value, whose reason names `extra_models`;
  - an unparseable block (the single `key=model_routing value=- reason=unparseable` line).

  Also cover:
  - block and flow forms giving identical output;
  - quoted keys and values, and a trailing `# comment`;
  - indented comment lines after `{}`;
  - a duplicate key read as unparseable;
  - `gaffer:implementer` resolving like `implementer`;
  - `Opus` read as `unknown-model`;
  - an `extra_models` value accepted;
  - a bad `extra_models` item reported, and an unparseable `extra_models` reported once while `model_routing` still applies;
  - `table` omitting an entry equal to frontmatter, and printing `-` for an agent with no `model:`;
  - `resolve Explore` printing an empty line;
  - exit 0 in every case above, and exit 2 for `resolve` with no argument and for an unknown subcommand;
  - the `VALID_MODELS` pin to exactly `sonnet opus haiku fable`.

  Add a `Model routing sweep` step to `.github/workflows/ci.yml`. Add a `scripts/test-routing.sh` line to CLAUDE.md's "How to test the plugin" block, and update its sweep-count sentence.
  - deps: —
  - covers: One deterministic lookup resolves an agent's model · Invalid entries fail safe and are reported, never dropped or fatal · The lookup, its fallbacks and the counting are pinned by sweep cases
  - arch: Rule: RoutingLookup · Rule: ModelRoutingParse · Rule: RoutingValidation · Entity: ModelRoutingConfig · Rule: RoutingPrecedence · Rule: RoutingSweeps
  - files: scripts/routing.sh, scripts/test-routing.sh, .github/workflows/ci.yml, CLAUDE.md
- [x] **T2** [P] **P0** In `hooks/metrics-log.sh`, stamp `routing_resolved` and `routing_table` onto every `Agent` event with a non-empty `subagent_type`, by calling `routing.sh resolve` and `table`.

  How the hook calls the script:
  - the path is `${CLAUDE_PLUGIN_ROOT:-<hook dir>/..}/scripts/routing.sh`;
  - it passes `--root "$main_root"` when `main_root` is set;
  - `table` lines become a `jq` object after `tr -d '\r'`;
  - both fields go into the existing `jq -cn` event builder, or both are omitted when the script is missing or not executable, or either call exits non-zero;
  - all call output is captured, so the hook still prints nothing and exits 0.

  In `scripts/test-metrics.sh`, add hook cases:
  - an Agent event carries both fields, with `routing_resolved` equal to `""` for an unmapped agent and to the alias for a mapped one;
  - a non-Agent event carries neither field;
  - with `CLAUDE_PLUGIN_ROOT` pointed at an empty directory, both fields are absent, stdout is empty, and the exit code is 0.
  - deps: T1
  - covers: Run-metrics records map routing as policy, not as override
  - arch: Entity: DispatchRoutingStamp · Rule: DispatchRoutingStamp
  - files: hooks/metrics-log.sh, scripts/test-metrics.sh
- [ ] **T3** [P] **P1** Replace the stale task/tier comment above `model_routing: {}` with the agent-keyed explanation and a commented `# extra_models: []` line, in both the consumer template and this repo's own overrides file.

  The comment states:
  - the key is keyed by `agents/*.md` basename, in block or flow form;
  - an unlisted agent keeps its `model:` frontmatter;
  - `loop-driver` is excluded;
  - an invalid entry falls back and is reported at run-loop and resume preflight.

  Keep the `model_routing` section (comment, key and the `# extra_models` line) as one paragraph with no internal blank line, separated from its neighbours by exactly one blank line — the layout `scripts/migrate.sh`'s section cleanup relies on. Keep both values `{}`. Leave every other key in `.agents/project-overrides.yaml` byte-identical, `bypass-ask-tier` above all. `scripts/test-migrate.sh` and `scripts/test-guard.sh` must stay green unedited.
  - deps: T1
  - covers: The consumer template documents the key
  - arch: Rule: RoutingTemplateDocs · Entity: ModelRoutingConfig
  - files: templates/spec-driven-base/.agents/project-overrides.yaml, .agents/project-overrides.yaml
- [ ] **T4** [P] **P1** In `templates/report-templates.md` shape C, add the optional `⚠️ **Routing config**` line after `⚠️ **Assuming**` and the optional `▶ **Routing**` line after `▶ **Session**`.

  Add one comment rule to the shape: both lines are rendered only from `routing.sh validate`/`table` output, and neither asks the operator to change anything.

  In `scripts/test-report-conventions.sh`, add:
  - a kickoff fixture carrying both lines, which lints `REPORT_LINT=clean` against an empty and a populated digest;
  - a control where the `▶ **Routing**` line carries a second glyph, which fires `two-glyphs`.

  Edit `scripts/report-lint.sh` only if the conforming fixture fires a rule the shape defines as conformant.
  - deps: T1
  - covers: The kickoff states routing that differs from defaults · Invalid entries fail safe and are reported, never dropped or fatal
  - arch: Rule: KickoffRouting
  - files: templates/report-templates.md, scripts/test-report-conventions.sh, scripts/report-lint.sh
- [ ] **T5** [P] **P0** In `scripts/metrics.sh`, count a stamped dispatch as an override exactly when `(.model // "") != .routing_resolved`, and record `audit.configured_routing` and `by_dispatch_model_override`.

  `collect`:
  - null when any dispatch is unstamped, with the "N of M dispatches carry no routing stamp" note;
  - 0 with `configured_routing: null` for a run with no dispatches;
  - `configured_routing` from the latest stamped Agent event by parsed `ts`;
  - `by_dispatch_model_override` keys overrides by the passed model, with `"(none)"` for a dispatch that passed nothing while its agent was mapped;
  - a mid-run-change note carrying the count of distinct tables;
  - the explanatory override note rewritten to state the new rule.

  `show`:
  - renders `configured routing: …`, `none` for `{}`, or `unmeasured — pre-routing run` for `null`;
  - uses no `// {}` or `// 0` fallback.

  Pass every `jq -r` output consumed by a `read` loop through `tr -d '\r'`. Leave `by_agent_role.<role>.models` untouched.

  In `scripts/test-metrics.sh`, add:
  - map-routed counts 0;
  - off-map counts 1;
  - a mapped agent sent back to its frontmatter model counts 1;
  - an unmapped agent passed its own frontmatter model counts 1;
  - `configured_routing` equals the stamped table;
  - a legacy unstamped fixture gives `configured_routing: null` and `dispatches_with_model_override: null`;
  - a mixed-stamp run gives `null` plus the note;
  - a `show` case asserting `unmeasured — pre-routing run` on `null`.

  Where an existing case asserted a count on unstamped Agent events, change its expectation to `null` and name the reason in the case label.

  In CLAUDE.md, amend the routing sentences ("Never pass `model` at dispatch", and the `dispatches_with_model_override` meaning) to the new rule: pass `routing.sh resolve`'s output, and an override is a passed model that differs from the routing resolved at dispatch.
  - deps: T2
  - covers: Run-metrics records map routing as policy, not as override · The lookup, its fallbacks and the counting are pinned by sweep cases
  - arch: Rule: ModelOverrideCounting · Entity: ConfiguredRouting · Entity: DispatchRoutingStamp
  - files: scripts/metrics.sh, scripts/test-metrics.sh, CLAUDE.md
- [ ] **T6** [P] **P0** In `skills/run-loop/SKILL.md` and `skills/resume/SKILL.md`, run `routing.sh validate` and `table` once at preflight — before driver mode is entered in run-loop (§1), and at resume's §1 preflight (after its §0 driver-mode entry, which is harmless because `routing.sh` is read-only) — and render T4's two kickoff lines from their output.

  In `run-loop` §3 (the `handoff --agent` packet agent, the `reviewer`, the `chief-engineer` decider stand-in) and §4 (the end-of-run `reviewer` and `architect`), add the sentence naming `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve <agent>` immediately before each dispatch. A non-empty result is passed as `model`, and an empty result means `model` is omitted.

  State once in §3 that a deliberate one-dispatch deviation carries `Model override: <alias> — <reason>` in its brief. In `resume`, add the one `resolve` sentence where it hands on to run-loop §3.

  A validate report never stops the run. No prose parses the YAML or restates precedence. `scripts/test-report-conventions.sh` must stay green unedited.
  - deps: T1, T4
  - covers: Every plugin dispatch uses the resolved model · Precedence is explicit deviation, then map, then frontmatter · The kickoff states routing that differs from defaults · Invalid entries fail safe and are reported, never dropped or fatal
  - arch: Rule: DispatchSiteRouting · Rule: RoutingPrecedence · Rule: KickoffRouting
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md
- [ ] **T7** **P0** Add the `routing.sh resolve` sentence at every dispatch site in the five remaining dispatching files, and add the dispatching-file sweep case to `scripts/test-routing.sh`.

  The five files and their sites:
  - `skills/metrics/SKILL.md`: the `architect` it delegates to for a deep `analyze`.
  - `skills/review-change/SKILL.md`: `chief-engineer`, `reviewer`, `architect`.
  - `skills/new-project/SKILL.md`: `chief-engineer`.
  - `agents/chief-engineer.md`: every delegation, including its decider `architect` dispatch. Its "which model tier fits" guidance becomes "which agent fits", and it carries the `Model override:` line rule. Body only; its frontmatter is unchanged.
  - `agents/loop-driver.md`: `ACTION=attempt`, `ACTION=decider`, and its question `researcher`.

  The sweep case:
  - enumerates the dispatching-file set by the arch definition (frontmatter `tools:` lists `Task`, or the case-insensitive dispatch/delegate regex over the agent set derived from `agents/*.md`) over the real repo;
  - asserts that each file contains `routing.sh resolve`;
  - carries a positive control that the set includes `skills/run-loop/SKILL.md`, `skills/review-change/SKILL.md` and `agents/chief-engineer.md`;
  - carries a negative control that a fixture dispatching file lacking the literal fails the check.

  Write the enumeration without a pipe-fed `grep -q`.
  - deps: T1, T6
  - covers: Every plugin dispatch uses the resolved model · Precedence is explicit deviation, then map, then frontmatter · The lookup, its fallbacks and the counting are pinned by sweep cases
  - arch: Rule: DispatchSiteRouting · Rule: RoutingPrecedence · Rule: RoutingSweeps
  - files: skills/metrics/SKILL.md, skills/review-change/SKILL.md, skills/new-project/SKILL.md, agents/chief-engineer.md, agents/loop-driver.md, scripts/test-routing.sh
