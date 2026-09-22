---
spec-version: v2
feature: handoff-spec-inlining
---

# Plan: handoff-spec-inlining

**Resolver first, inlining second, budget and bundle third, prose last.** Every
site that names `arch.md` or `design.html` takes its path from one resolver (T1)
before anything reads a section out of either file, so the inlining (T2–T6) is
built on the one pinned location rather than becoming a fourth silent reader —
gspec has moved these files twice. The implementer prose (T7) and the corrected
standing statements (T8) land after the handoff's final shape is settled, so no
prompt or document names a marker that does not exist yet.

**The adapter judges everything; the driver judges nothing.** Anchor resolution,
the word budget and the statement line all live in `scripts/gspec-backlog.sh
handoff`, which reads the budget key itself. The driver keeps piping `handoff`
into `runstate.sh handoff` exactly as today, so `skills/run-loop/SKILL.md` and
`scripts/runstate.sh` are untouched — the markers travel in the piped body, and
the REQUIRED block is still appended after it.

**Deferred decisions, fixed here.** Marker names are the PRD's working names,
plus `ARCH-SEEN=`/`DESIGN-SEEN=` (a section already inlined earlier in the same
bundle), `BUDGET-REACHED=` and `SPEC=` (the statement line). A design block
joins the bundle's seen set exactly as an arch anchor does (`DESIGN-SEEN=`). A
budget of zero reads as the 6000 default, like a missing, empty or non-numeric
value, so no value ever makes the budget unbounded. Words are counted by
whitespace split. The override key is `handoff_inline_word_budget`, read from the
repository's own `.agents/project-overrides.yaml` only — a numeric limit has no
restrictive union, and no need for a per-root rule has been seen.

**`next` does not change.** Its `ARCH=`/`DESIGN=` lines are for the driver and
keep printing paths; T1 only re-routes where they get the path. The two
`handoff` sweep cases that assert `ARCH=absent`/`ARCH=<path>` are inverted by T2
— that line leaves `handoff` output entirely.

**Every script task names its sweep case.** T1–T6 → `scripts/test-gspec-backlog.sh`,
each with a named mutation that must turn a case red. T7 and T8 are prose and
comments, checkable by reading, with no sweep case.

**File contention, and why two tasks are `[P]`.** T1–T6 all edit
`scripts/gspec-backlog.sh` and its sweep, so they run in order. T7
(`agents/implementer.md`) and T8 (comments and documents) share no file, and each
depends only on the barrier T6.

**Cross-feature overlap.** `gspec-adapter-consistency` edits the same adapter and
sweep as T1–T6, and `implementer-continuation` edits `agents/implementer.md` as
T7 does; neither may be in flight against those files alongside this one.

**Reflexivity.** `scripts/gspec-backlog.sh` takes effect mid-run, but this feature
has no `arch.md`, so its own handoffs never exercise the inlining.
`agents/implementer.md` is read at dispatch. No task touches `hooks/hooks.json`,
a settings file, or any agent's or skill's frontmatter, so no packet owes a
`session_boundary` declaration.

Every regression sweep must pass green after every task.

## Plan

- [x] **T1** **P0** Add `_resolve_arch_path <slug> <root>` and `_resolve_design_path <slug> <root>` to `scripts/gspec-backlog.sh` beside `_resolve_prd_path`/`_resolve_plan_path`, each returning `"<abs>\t<rel>"` or nothing, and each enumerating the layouts the file has existed in newest first through its own list (today only the 3.x `gspec/features/<slug>/` folder). Route `cmd_next`'s `ARCH=`/`DESIGN=` lines through them so no literal `gspec/features/$pick/arch.md` or `design.html` test remains, with `next`'s output byte-unchanged. Add `scripts/test-gspec-backlog.sh` cases for both resolvers finding each file in its 3.x fixture location and returning nothing when it is absent, keep every existing `next` case passing, and confirm by mutation that pointing the resolver's layout list at another directory turns the layout case red.
  - deps: —
  - covers: The two files are read through one resolver and pinned by the sweep
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T2** **P0** Make `_handoff_one` in `scripts/gspec-backlog.sh` inline the `arch.md` section each `- arch:` anchor names.
  (a) `_task_record` emits the task's `- arch:` value as a header key, and the line stays out of the printed body.
  (b) The value is split on ` · ` through `_split_covers`. Each entry is accepted as `#entity-order`, `### Entity: Order` or `Entity: Order`, compared by slug with hyphens ignored; `—` means no anchors.
  (c) Each anchor is resolved against the H3 headings of the `arch.md` that `_resolve_arch_path` names, using the gspec-conventions H2/H3 grammar only. A heading form it does not recognise resolves to nothing.
  (d) A resolved anchor prints `ARCH-SECTION=<anchor>`, then the block from its heading through the line before the next H2 or H3, indented two spaces as `COVERS=` indents criteria. A `- **route:**` line inside a `### Screen:` block is block text.
  (e) An anchor with no match prints `UNMATCHED-ARCH=<anchor>`, never a nearest match, on checked and unchecked tasks alike.
  (f) Every marker prints after the `COVERS=`/`UNMATCHED=` blocks, so `runstate.sh handoff`'s appended REQUIRED block still follows them.
  (g) The `ARCH=` line is deleted from `handoff` output entirely, the `absent` sentinel included.
  In `scripts/test-gspec-backlog.sh`, invert the existing `ARCH=absent`/`ARCH=<path>` handoff cases into refutes of any `ARCH=` line, and add cases for: each of the three anchor forms resolving to its text under the marker; an unmatched anchor on an unchecked and on a checked task; a task with no anchors printing neither marker nor `ARCH=`; a `- **route:**` line carried without ending its screen block; and a heading outside the grammar reading as unmatched. Confirm by mutation that a prefix (nearest-match) lookup turns the unmatched case red.
  - deps: T1
  - covers: A handoff inlines the `arch.md` section each `- arch:` anchor names · The two files are read through one resolver and pinned by the sweep
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T3** **P0** Bound what one handoff inlines with a word budget in `scripts/gspec-backlog.sh`.
  (a) A reader for `handoff_inline_word_budget` in `.agents/project-overrides.yaml`, in the same token-scanning shape as `runstate.sh`'s `_rs_packet_attempts_limit`. It returns 6000 for a missing file, missing key, empty, non-numeric or zero value — never unbounded.
  (b) Words are counted by whitespace split over inlined section text only; `COVERS=` criteria are outside the count and unchanged.
  (c) Sections are inlined in `- arch:` order until the next would carry the running count over the budget. From that section on, each remaining resolved section prints `ARCH-HEADING=<anchor> lines=<n>` with its heading instead of its text, and one `BUDGET-REACHED=<budget> words` line follows. An under-budget handoff carries no such line.
  Document the key, its default, and what raising it costs in handoff size in `templates/spec-driven-base/.agents/project-overrides.yaml`, and commented out in this repo's `.agents/project-overrides.yaml`, beside `bundle_max_tasks` and in its voice. Add `scripts/test-gspec-backlog.sh` cases for: the default with no overrides file; a missing, empty and non-numeric value each reading as 6000; an override read back; the budget reached, with headings, line counts and the statement line; an under-budget handoff with no statement; and criteria text not counted. Confirm by mutation that reading a non-numeric value as 0 or unbounded turns a case red.
  - deps: T2
  - covers: A word budget bounds what one handoff inlines
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh, .agents/project-overrides.yaml, templates/spec-driven-base/.agents/project-overrides.yaml
- [x] **T4** **P0** Carry the inlining and the budget through a bundle.
  (a) `_handoff_bundle` holds one seen-anchor set and one running word count across all members, reset on the single-id path.
  (b) A distinct anchor's text is inlined once, at the first member that names it. A later member naming it prints `ARCH-SEEN=<anchor> packet=<first member's packet id>` with no text.
  (c) The budget spans the whole bundle handoff, and `BUDGET-REACHED=` prints once.
  (d) A single id's output stays byte-identical to T3's.
  Add `scripts/test-gspec-backlog.sh` cases for: a three-member bundle where two members name one anchor (text present once, at the first member); a bundle crossing the budget in its second member (later sections named by heading, one statement line); no `ARCH=` line in any member; and a single id unchanged. Confirm by mutation that resetting the seen set per member turns the once-only case red.
  - deps: T3
  - covers: A handoff inlines the `arch.md` section each `- arch:` anchor names · A word budget bounds what one handoff inlines
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T5** **P0** Add the statement line to `handoff` output in `scripts/gspec-backlog.sh`, printed once per handoff after the last section marker (for a bundle, after the last member).
  (a) When at least one section was inlined and none was named by heading or reported unmatched, print one fixed `SPEC=` line. It states that the specification text this task needs is inlined under the section markers above and there is no spec file to open for it.
  (b) When any section was named by heading, or any `UNMATCHED-ARCH=` was printed, the `SPEC=` line instead names, once each, the path of every file the handoff drew sections from. It says the named sections are to be read there by heading, not the whole file. This is the only place a spec-file path (`arch.md`, `design.html`, the PRD body) appears in `handoff` output; the `PRD=` bookkeeping line the loop's recovery steps read is not a spec-file path and stays.
  (c) A task with no anchors carries no `SPEC=` line.
  Add `scripts/test-gspec-backlog.sh` cases for: a fully inlined handoff (fixed line, no `gspec/features/` path anywhere in the output outside the `PRD=` line); a budget-reached handoff naming `arch.md` once; an unmatched arch anchor naming `arch.md`; a no-anchor task with no `SPEC=` line; and a bundle printing exactly one `SPEC=` line. Confirm by mutation that printing the fixed line despite an unmatched anchor turns a case red.
  - deps: T4
  - covers: The handoff says the spec it needs is in it
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T6** **P1** Inline the design block a screen section names, in `scripts/gspec-backlog.sh`.
  (a) When an inlined section is a `### Screen: <Name>` block and `_resolve_design_path` finds a `design.html` holding `<section id="screen-<kebab>">` for the slugified name (CamelCase split, lowercased, non-alphanumeric runs to one hyphen), print `DESIGN-SECTION=screen-<kebab>`, then that element's markup from its opening tag through its matching close. Matching counts nested `<section` opens and closes; the markup is indented and placed after its screen's `ARCH-SECTION=` block.
  (b) A present `design.html` with no matching element prints `UNMATCHED-DESIGN=screen-<kebab>` and inlines nothing.
  (c) When no inlined section is a screen, or the feature has no `design.html`, the file is not named at all: no `DESIGN=` line and no empty marker.
  (d) The block counts against the same budget, and T5's `SPEC=` line treats an `UNMATCHED-DESIGN=` or a design block named by heading exactly as its arch counterpart, naming `design.html` alongside `arch.md`. Past the budget it prints `ARCH-HEADING=screen-<kebab> lines=<n>`, and in a bundle it takes part in the seen set as `DESIGN-SEEN=`.
  Add `scripts/test-gspec-backlog.sh` cases for: a screen's design block inlined, including a nested `<section>` closing at the right tag; `design.html` unnamed when no screen is inlined; unnamed when the file is absent; an unmatched design element with the `SPEC=` line naming both files; and a design block tipping the budget. Confirm by mutation that closing at the first `</section>` turns the nested case red.
  - deps: T5
  - covers: The design block a screen section names rides with it · The handoff says the spec it needs is in it
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T7** [P] **P0** Add to `agents/implementer.md`:
  (a) under "When the loop dispatches you", that the `ARCH-SECTION=`/`DESIGN-SECTION=` blocks in the handoff are the specification for the packet. A spec file the handoff draws from is opened only for a section it named by heading, or to investigate an anchor it reported unmatched, and then by heading with `offset`/`limit`, never whole.
  (b) under "Build, test, report", run the narrowest test target that covers the change, and report the summary and failures rather than piping a whole test log into context — the full log belongs in the result file when the reviewer needs it.
  (c) beside "Do not re-read what you already have", never `Read` a skill or agent prompt file, its own or another's, and never search for one with `Grep`/`Glob` — its instructions are already in context, and the handoff is the whole brief.
  State the rule only, never the measurement behind it. Prose only, no sweep case, checkable by reading the three passages against T5's `SPEC=` line and confirming every marker named exists in `handoff` output.
  - deps: T6
  - covers: The handoff says the spec it needs is in it · The implementer keeps its own context lean
  - arch: —
  - files: agents/implementer.md
- [ ] **T8** [P] **P0** Correct the standing statements that `arch.md` and `design.html` are outside the consumed contract and never parsed, so each says anchored sections are now inside it through `_resolve_arch_path`/`_resolve_design_path` and no path surfaces in a handoff. The statements are:
  - in `scripts/gspec-backlog.sh` (comments only): the opening consumed-contract list ("nothing outside this list is read"), the "3.x feature folder also holds" layout comment, the `handoff` output contract in the subcommand summary header, and the output block above `_handoff_one` (replacing the `ARCH=<relpath, or "absent">` line with the T2–T6 markers);
  - the ADR 0020 bullet in `CLAUDE.md`;
  - the "Scope stays narrow on purpose" paragraph of `docs/adr/0020-gspec-boundary-and-version-pin.md`;
  - the "also holds" paragraph of `docs/gspec-3.2.0-migration.md`.
  Comments and prose only, no sweep case, checkable by a case-insensitive search for single-line fragments — "also holds `arch.md`", "never parses them", "does not parse either" — and `ARCH=` across those four files returning only `next`'s `ARCH=`/`DESIGN=` description, with every regression sweep still green.
  - deps: T6
  - covers: The two files are read through one resolver and pinned by the sweep
  - arch: —
  - files: scripts/gspec-backlog.sh, CLAUDE.md, docs/adr/0020-gspec-boundary-and-version-pin.md, docs/gspec-3.2.0-migration.md
