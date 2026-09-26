---
spec-version: v2
feature: per-agent-model-routing
module: plugin
---

# Architecture: per-agent-model-routing

The whole `gaffer` plugin is one module, `plugin`: bash scripts under `scripts/`, hook scripts under `hooks/`, agent prompts under `agents/*.md`, skill prompts under `skills/*/SKILL.md`, and consumer templates under `templates/`. There is no application stack. Verification for every task in this feature is `claude plugin validate .` followed by `for s in scripts/test-*.sh; do bash "$s" || exit 1; done` (CI lists each sweep as its own step in `.github/workflows/ci.yml`, so a new sweep needs a CI step and a line in CLAUDE.md's test list).

Constraints every script here inherits from the plugin: a script must run on stock Git Bash, which ships **no `jq`** and no real `python3`, so config parsing is `awk` token-scanning. Any `jq -r` output consumed by `read` goes through `tr -d '\r'`, because the Windows jq build writes CRLF. A hook prints **nothing** to stdout and always exits 0.

**Settled decisions** (operator-approved):

1. **The lookup lives in a new script, `scripts/routing.sh`.** It is the single definition, and every caller invokes it as `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh`. `runstate.sh` was the alternative. It was rejected because it is the run-state single writer and is already very large, and because routing is read by contexts that hold no run-state: `review-change`, a dispatched chief-engineer, and the metrics hook.
2. **The comparison basis is stamped per dispatch.** The metrics hook is a PostToolUse hook, so it resolves the agent's model when the Agent call completes and writes that value onto the event. A config edit made while that one dispatch is still in flight can record it as an override, which is the safe direction. The collector compares against the stamp. It never compares against the file as it stands at collect time, because that would re-judge old dispatches against config edited afterwards. It also needs no run-start snapshot, because every dispatch carries the value in force when it completed.
3. **Valid model values are a plugin default list plus a repo extension.** `VALID_MODELS` sits at the top of `routing.sh`. A repo adds values through a top-level `extra_models:` key in `project-overrides.yaml`, which is one key beyond the PRD. The harness publishes no queryable list, and the Agent tool's `model` parameter takes family aliases that the harness maps to current versions. So the plugin list changes only when a new family ships, and a repo that gets one first needs no plugin release.

## Data

### Entity: ModelRoutingConfig
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

Two top-level keys in `<main checkout>/.agents/project-overrides.yaml`. Both are optional.

- `model_routing` maps an agent name to a model alias. It takes a block form (`model_routing:` then indented `implementer: opus` lines) or a single-line flow form (`model_routing: {}`, `model_routing: {implementer: opus, reviewer: fable}`). Keys are bare agent names as they appear in `agents/<name>.md`, with no `gaffer:` prefix. Each key or value may be single- or double-quoted; one matching pair of quotes is stripped. A trailing `# comment` is ignored.
- `extra_models` is a list of additional accepted aliases. It takes a flow form (`extra_models: [foo-1]`) or a block list of `- foo-1` lines. Each item must match `^[A-Za-z0-9._-]+$`, because the value ends up inside a dispatch brief. An item that does not match is reported, not accepted.

The key stays `model_routing: {}` in `templates/spec-driven-base/`, and `extra_models` is absent there, so a new consumer runs on frontmatter defaults.

### Entity: DispatchRoutingStamp
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

These are fields added to an event line in `.agents/metrics/events/<session>.jsonl`, written by `hooks/metrics-log.sh` **on `tool_name == "Agent"` events only**. They sit alongside the existing `subagent_type` and `model` (the passed `model`, absent when none was passed).

| field | type | meaning |
|---|---|---|
| `routing_resolved` | string | `routing.sh resolve <subagent_type>` output. `""` means the dispatch should pass no model (frontmatter default). |
| `routing_table` | object | `{ "<agent>": "<alias>" }` for the valid entries that differ from frontmatter (`routing.sh table`). `{}` when there are none. |

The two fields are written together or not at all. **An absent `routing_resolved` means unmeasured**, and it is never read as `""`. That is why the empty string is always written explicitly when the lookup succeeds.

### Entity: ConfiguredRouting
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

This is `audit.configured_routing` in `.agents/metrics/<run-id>/run-metrics.json`, an object of the same shape as `routing_table`. It takes the `routing_table` of the **latest** stamped Agent event in the run window, ordered by parsed `ts`. The value is `{}` when stamps exist and the table is empty. It is **`null`** when no Agent event in the window carries a stamp: a run collected before this feature, or a run with no dispatches. `null` means unmeasured, never "no routing". `by_agent_role.<role>.models` is untouched.

## API

**Not Applicable.** The feature publishes and consumes no HTTP or network endpoint. Its only interface is the `routing.sh` command-line contract, which is specified in `### Rule: RoutingLookup`, because the anchor grammar has no command-line form.

## UI

**Not Applicable.** The plugin ships no user interface. The only human-facing output is report text: two kickoff lines (`### Rule: KickoffRouting`) and one `metrics show` line (`### Rule: ModelOverrideCounting`).

## Logic

### Rule: RoutingLookup
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

`scripts/routing.sh` (executable, `set -uo pipefail`, **no `-e`**) is the only code that reads `model_routing` or `extra_models`. Its usage is `routing.sh [--root <dir>] <subcommand> [arg]`, and **every subcommand exits 0 in every failure mode below**. The one non-zero exit is a usage error: an unknown subcommand, or `resolve` with no argument (exit 2). That is a caller bug, not a config state.

- **Config location.** With `--root <dir>`, the script reads `<dir>/.agents/project-overrides.yaml`. Without it, the root is the dirname of `git rev-parse --path-format=absolute --git-common-dir`, which is the main checkout even from a worktree. Outside a git repo, or with the file or key missing, every agent resolves to the default.
- **Agent set.** The script derives the agent set from `${ORCH_ROUTING_AGENTS_DIR:-<script dir>/../agents}/*.md`. The name is the file's basename, and its frontmatter model is the first `model:` line inside the leading `---` block. `loop-driver` is excluded. There is no maintained list, so a new agent file is routable with no edit here.
- **`resolve <agent>`** strips one leading `gaffer:` from its argument. It prints the mapped alias when a **valid** entry names that agent. Otherwise it prints an empty line. That covers an unmapped agent, an invalid entry, an unparseable block, an absent file, and a non-plugin type such as `Explore` or `general-purpose`. The output is exactly what the dispatch passes: a non-empty value goes in as `model`, and an empty value means `model` is omitted.
- **`validate`** prints one line per invalid entry in the format `ROUTING-INVALID key=<key> value=<value> reason=<reason>`. When the whole block is unparseable it prints the single line `ROUTING-INVALID key=model_routing value=- reason=unparseable`. No output means the config is clean.
- **`table`** prints one line per valid entry whose alias differs from that agent's frontmatter model, in the format `<agent> <frontmatter-model> <alias>`, sorted by agent. An agent file with no `model:` line reads its frontmatter model as `-`, so the three-field format holds. An entry equal to frontmatter is valid and resolves, but it is omitted here.

### Rule: ModelRoutingParse
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

This is an `awk` token-scan in the house shape of `runstate.sh`'s `_rs_packet_attempts_limit`: match the key at column 0, take the remainder, strip a trailing `#` comment, and strip one matching pair of quotes per token. The one difference is that this scan reads a map rather than a scalar.

- **Flow form.** The remainder starts with `{` and closes with `}` on the same line. The inner text is split on `,`, and each piece must be `key: value`. `{}` is an empty map.
- **Block form.** The remainder is empty. It is followed by indented `key: value` lines, and the block ends at the next non-blank, non-comment line in column 0. Indented `#` lines and blank lines are skipped in both forms. This matters because the template follows `model_routing: {}` with indented example comments.
- **Unparseable.** Any of these makes the whole block unparseable: an unclosed flow brace, an indented non-comment line after a flow map, a block line that is not `key: value` (a `- item`, or a deeper nesting), an empty key or value, or a **duplicate key**. Strict YAML rejects duplicate keys, and picking a winner would hide the conflict. An unparseable block is reported once, and every agent then takes its default.
- `extra_models` uses the same flow and block rules with list items. An unparseable `extra_models` is reported once as `key=extra_models value=- reason=unparseable`, and only `VALID_MODELS` is then accepted. `model_routing` still applies.

### Rule: RoutingValidation
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

Each entry of a parseable `model_routing` is checked in order. The first failure is its reason, and the entry is then invalid.

| reason | condition |
|---|---|
| `loop-driver` | the key is `loop-driver`. That role is the session itself (`model: inherit`), so routing never sets its model. |
| `unknown-agent` | the key names no `agents/*.md` file. This is what an agent rename turns a consumer's key into. |
| `unknown-model` | the value is in neither `VALID_MODELS` nor `extra_models`. The report line's reason reads `unknown-model(add it to extra_models if the harness accepts it)`. |

An invalid entry resolves that agent to its default, and every other entry still applies.

`VALID_MODELS` is a labelled array at the top of `routing.sh`, and currently holds `sonnet opus haiku fable`. Its comment states its source and the date: it is the Agent tool's `model` enum as observed on 2026-09-18, and it changes only when a new model family ships. Comparison is exact and case-sensitive, so `Opus` is `unknown-model`.

### Rule: RoutingPrecedence
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

For each agent, an explicit deviation beats the map, and the map beats frontmatter.

- **Explicit deviation.** This is a prompt-level choice. A dispatch site may pass a model other than `resolve`'s output for one dispatch, but only if its brief carries the line `Model override: <alias> — <reason>`. The deviation covers that dispatch and no other. It is **counted** as an override (`### Rule: ModelOverrideCounting`), which is the intended signal. Nothing mechanically checks the reason line, and the reviewer is the check.
- **Map over frontmatter.** This is implemented by passing `resolve`'s output. An agent the map does not name resolves to `""`, the dispatch omits `model`, and the harness applies frontmatter.
- The lookup never changes any `model:` frontmatter, and never sets the model of the session driving the loop.

### Rule: DispatchSiteRouting
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

Each dispatch site runs `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve <agent>` immediately before the Agent call. A non-empty result is passed as `model`, and an empty result means `model` is omitted. No prompt parses the YAML or restates precedence, and each site names the subcommand in one sentence. The call is made per dispatch rather than cached, so a mid-run config edit takes effect at the next dispatch.

The sites that change are the set below, derived by running definitions (a) and (b) over the repo:

- `skills/run-loop/SKILL.md` §3: the packet agent chosen from `handoff --agent` (`implementer`, `architect`, `ux-designer`, `doc-writer`), the `reviewer`, the `chief-engineer` decider stand-in, and §4's end-of-run `reviewer` and `architect`.
- `skills/resume/SKILL.md`: it makes no dispatch of its own, but it is in the swept set. It carries one `resolve` sentence where it hands on to run-loop §3.
- `skills/metrics/SKILL.md`: the `architect` it delegates to via `Task` for a deep `analyze`.
- `skills/review-change/SKILL.md`: `chief-engineer`, `reviewer`, `architect`.
- `skills/new-project/SKILL.md`: `chief-engineer`.
- `agents/chief-engineer.md`: every delegation, including its decider `architect` dispatch. Its "which model tier fits" guidance becomes "which agent fits", because the lookup, not the chief-engineer, picks the model.
- `agents/loop-driver.md`: `ACTION=attempt`, `ACTION=decider`, and the `researcher` it dispatches for a question.

**The dispatching-file set is defined mechanically**, so the sweep case is objective. A file is a dispatching file if it is a `skills/*/SKILL.md` or `agents/*.md` and either:

- (a) its frontmatter `tools:` line lists `Task`, or
- (b) its body matches, case-insensitively, `(dispatch(es|ed|ing)?|delegat(e|es|ed|ing) to)[[:space:]]+([[:alnum:]-]+[[:space:]]+){0,2}(\*\*|`)(gaffer:)?<agent>(\*\*|`)`, where `<agent>` is any name in the derived agent set. This allows up to two intervening words, for example "a single". Descriptive matches, such as resume's "dispatches a single `implementer`", are deliberately included: the sweep errs toward coverage.

Every file in the set must contain the literal `routing.sh resolve`. Because the agent names are derived rather than listed, **the future `escalation-decider`'s dispatch site is swept automatically** once its `agents/escalation-decider.md` exists. Replacing the chief-engineer stand-in's dispatch line in run-loop must carry the `resolve` sentence, or `test-routing.sh` fails.

### Rule: DispatchRoutingStamp
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

This is in `hooks/metrics-log.sh`, and it runs only when `tool == "Agent"` and `subtype` is non-empty. The script path is `${CLAUDE_PLUGIN_ROOT:-<hook dir>/..}/scripts/routing.sh`, called with `--root "$main_root"` when `main_root` is set, and otherwise with no root, so the script resolves the root itself. The hook makes two calls, `resolve "$subtype"` and `table`. The table lines are converted to an object with `jq` (the hook already requires `jq`), with `tr -d '\r'` applied first. Both values are added in the existing `jq -nc` event builder.

If the script is missing or not executable, or either call exits non-zero, **both fields are omitted**. A missing stamp reads as unmeasured, while a wrong stamp would be silently miscounted. All output from the calls is captured, so the hook still prints nothing and exits 0.

### Rule: ModelOverrideCounting
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

This is in `scripts/metrics.sh collect`'s `audit` block. Dispatches are the run's Agent events that carry `subagent_type`. For each **stamped** dispatch, override means `(.model // "") != .routing_resolved`. So a map-routed dispatch counts 0, an off-map model counts 1, a mapped agent passed its frontmatter model counts 1, and an unmapped agent passed its own frontmatter model counts 1.

- `dispatches_with_model_override` is the override count when **every** dispatch in the window is stamped. It is `null` when **any** dispatch is unstamped, because a partial count would read as clean. `null` also covers a run where the `ok`-capture predates instrumentation. A run with zero dispatches gives `dispatches_with_model_override: 0`, with `configured_routing: null`.
- `by_dispatch_model_override` groups overridden dispatches by the passed model. A dispatch that passed nothing while the map routed its agent is keyed `"(none)"`.
- `configured_routing` is set per `### Entity: ConfiguredRouting`. When more than one distinct `routing_table` appears in the window, a `notes[]` line records that routing changed mid-run and gives the count of distinct tables.
- **notes[] rewrites.** The explanatory note for `dispatches_with_model_override` is rewritten to state the new rule: an override is a passed model that differs from the routing resolved at dispatch, and `by_agent_role.<role>.models` is the ground truth. When the value is null for missing stamps, a note states `N of M dispatches carry no routing stamp`.
- **`show`.** The routing-audit line renders `configured routing: <agent> <alias>, …`, or `none` for `{}`. It renders `unmeasured — pre-routing run` for `null`, and never uses `// {}` or `// 0` to turn a null into a clean-looking value.

### Rule: KickoffRouting
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

- **Preflight.** `skills/run-loop/SKILL.md` §1 and `skills/resume/SKILL.md`'s preflight each run `routing.sh validate` and `routing.sh table` once — before driver mode is entered in run-loop, and after it in resume, whose §0 enters driver mode first (harmless, since `routing.sh` is read-only). A validate report never stops the run.
- **Kickoff lines.** `templates/report-templates.md` shape C gains two optional lines. Both are rendered only from those two outputs and never from the YAML:
  - `⚠️ **Routing config** — <n> entr(y|ies) ignored: <key> (<reason>), …`: one line total. It is placed after `⚠️ **Assuming**`, and it appears when `validate` printed anything.
  - `▶ **Routing** <agent> <frontmatter> → <alias> · …`: one line total. It is placed after `▶ **Session**`, and it appears when `table` printed anything. An empty or all-default map adds no line.

  The shape's comment block gets one rule stating that both lines come from `routing.sh`, and that neither asks the operator to change anything.

### Rule: RoutingTemplateDocs
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

The comment above `model_routing:` in `templates/spec-driven-base/.agents/project-overrides.yaml` is replaced. It currently describes task/tier keys, which is wrong. The new comment states:

- the key is a map keyed by agent name (the `agents/*.md` basenames), with block or flow form;
- an unlisted agent keeps its `model:` frontmatter;
- `loop-driver` is excluded;
- an invalid entry falls back to frontmatter and is reported at run-loop and resume preflight.

A commented `# extra_models: []` follows, with one line on when to use it. The value stays `{}`. The same comment text replaces the stale comment in this repo's own `.agents/project-overrides.yaml`, whose value also stays `{}`, because setting it is operator configuration.

### Rule: RoutingSweeps
- **module:** plugin
- **defined-in:** gspec/features/per-agent-model-routing/arch.md

**`scripts/test-routing.sh`** (new) follows the existing sweep preamble and assertion helpers, as in `test-runstate.sh`. It uses temporary roots with `--root` and a fixture `ORCH_ROUTING_AGENTS_DIR`. It asserts both the `resolve` output and the `validate` line for each of these cases:

- a mapped agent;
- an unmapped agent;
- a missing file;
- `model_routing: {}`;
- an unknown agent key;
- a `loop-driver` key;
- an unrecognized model value, with a report that names `extra_models`;
- an unparseable block.

It also covers:

- block and flow forms giving identical results;
- quoted values and trailing comments;
- a duplicate key read as unparseable;
- `gaffer:implementer` resolving like `implementer`;
- an `extra_models` value accepted;
- `table` omitting an entry equal to frontmatter;
- exit 0 in every case above.

Two further cases:

- **`VALID_MODELS` pin.** A case pins the list to exactly `sonnet opus haiku fable`, so any change is deliberate.
- **Dispatching-file sweep.** A case enumerates the dispatching-file set by `### Rule: DispatchSiteRouting`'s definition over the real repo and asserts that each file contains `routing.sh resolve`. A positive control asserts that the set includes `skills/run-loop/SKILL.md`, `skills/review-change/SKILL.md` and `agents/chief-engineer.md`, so a broken regex cannot pass by matching nothing.

**`scripts/test-metrics.sh`** (existing) gains these cases, using synthetic Agent events with stamps:

- map-routed counts 0;
- off-map counts 1;
- a mapped agent sent back to its frontmatter model counts 1;
- an unmapped agent passed its own frontmatter model counts 1;
- `configured_routing` equals the stamped table;
- a legacy fixture with no stamps gives `configured_routing: null` and `dispatches_with_model_override: null`;
- a mixed-stamp run gives `null` plus the note.

Hook cases in the same sweep:

- an Agent event carries both fields;
- a non-Agent event carries neither;
- with `routing.sh` unavailable, via a `CLAUDE_PLUGIN_ROOT` pointed at an empty directory, both fields are absent and the hook still prints nothing and exits 0.
