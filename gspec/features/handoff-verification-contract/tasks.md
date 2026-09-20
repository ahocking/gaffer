---
spec-version: v2
feature: handoff-verification-contract
---

# Plan: handoff-verification-contract

The template's text lands first, because every other task either emits it, points
at it, or tells an agent how to read it — and because the block's heading, the
`REQUIRED:` form of each line and the generic phrasing are all decided there, in
one file, rather than re-derived in the script and the two agent prompts. The
script work follows in the order the handoff is built: the fixed block, then the
per-repository extension appended behind it. The prose surfaces come after the
text exists to refer to, and the decision record last, as it always is here.
`scripts/runstate.sh` and `scripts/test-runstate.sh` are each one file touched by
two tasks, so **T2 and T3 are strictly sequential**; only T4 and T5 are `[P]`, and
each of those two touches a file no other `[P]` task touches. A task carrying
`deps: T1` alone is not thereby parallel-safe — judge `[P]` on the files column.

**Both of the PRD's deferred decisions are resolved here, one of them by
declining to decide it.** The block and its extension lines go **after** the
driver's two conditional lines, because those lines arrive inside the piped body
and `cmd_handoff` only ever appends after that stream: putting the block first
would mean the script splitting or re-ordering text it receives as one blob,
which is exactly the parsing of its own input it does not do today. The block's
delimiting heading therefore also marks where the task text ends. The second
deferred decision — an applicability hint on an extension line — stays deferred:
no task invents syntax for it, and T3 appends each extension line unconditionally.

**An extension line is framed, not filtered.** T3 writes `REQUIRED: ` followed by
the repository's line verbatim; the comment and blank-line rules remain the whole
filter on *which* lines are taken, and the prefix is what stops a line that reads
as prose or as a heading from dissolving the block's boundary — the PRD's own
risk. It also satisfies "a further `REQUIRED` line" without the template and the
consumer having to agree on a prefix.

**The config-root walk is reimplemented in `scripts/runstate.sh`, not shared with
`hooks/guard.sh`, and that is a deliberate duplication.** `guard.sh` is a hook
body: it reads a JSON payload on stdin, derives its candidate roots from that
payload's `cwd`, and exits with a tier decision — it has no callable form, and
sourcing it would run its policy. `runstate.sh` has no payload and today resolves
per-repository config from a *single* root (`_rs_main_checkout_root`, plus
`.agents/project-overrides.yaml`), which is not the multi-root restrictive union
the PRD asks for. What must match is ADR 0011's rules, stated in T3 as the
task's own criterion: candidates are `CLAUDE_PROJECT_DIR` and the cwd, every
ancestor declaring a `.agents/` directory, bounded by `$HOME` and `/`, deduped,
and unioned so a nested or foreign root can only add lines. The walk's cost (~80
`cd`/`pwd` subshells) is why `guard.sh` defers it behind a read-only fast path;
here it is paid once per packet, not once per tool call, so no laziness is needed.

**The extension mechanism is one task, not two, because an internal helper has no
observable behaviour to pin.** `scripts/test-runstate.sh` drives subcommands, not
sourced functions, and `runstate.sh` has no subcommand that prints its config
roots. Splitting discovery from the append would leave a task whose only honest
sweep case is a new subcommand nobody asked for; T3's fixtures exercise the walk
end-to-end through the written handoff instead.

**Every script task names its sweep case as its own acceptance criterion, with
the wrong implementation that case rules out.** That is the first of the six
lines this feature is delivering, so the plan is held to it: T2 and T3 each state
both the assertion and the mutation, and neither is satisfied by "the sweep
passes". T4, T5 and T6 are prose that no sweep can reach — each names the
concrete read or search a reviewer runs instead, and none of them invents a test
for prose.

**Reflexivity.** `scripts/runstate.sh` is invoked fresh per command, so T2 and T3
are live on the next `handoff` call **in the run that lands them** — the first
packet after T2 gets the block. `agents/*.md` bodies are read at dispatch, so T4
reaches the next implementer or reviewer this run dispatches, with no session
boundary; only agent frontmatter would cross one, and none changes here.
`skills/run-loop/SKILL.md` and `templates/task-packet.yaml` were read by the
driver at run start, so T5 first takes effect on the next `/gaffer:run-loop`, and
`CLAUDE.md` (T6) is standing instruction loaded at session start, so it reaches
the harness next session. No hook registration changes, so nothing else needs a
session boundary.

**Shared-file warning, outside this feature.** `escalation-decider` is being
planned against `scripts/runstate.sh`, `scripts/test-runstate.sh`,
`skills/run-loop/SKILL.md` and `CLAUDE.md` — four of the files this plan touches;
it touches neither `agents/reviewer.md` nor `agents/implementer.md`. Neither
feature depends on the other, so the loop is free to interleave them, but T2, T3,
T5 and T6 must not be in flight beside an `escalation-decider` packet on the same
file; T4 is the one task here free to interleave. `thin-loop-driver-gaps` carries
the same caution for the two scripts.

## Plan

- [x] **T1** **P1** Write `templates/handoff-required.md` — the six generic lines, each a `REQUIRED:` line in the same form the driver's two conditional lines use, under one heading that delimits the block from the task text above it, phrased by kind and naming no path, script, tool or field of this repository, since every consumer reads this file in place from the plugin root. Checkable by reading it beside `skills/run-loop/SKILL.md` §3.3's two lines: the forms match, and no line names anything repository-specific.
  - deps: —
  - covers: Every handoff carries the verification block by construction · The block's text has one source
  - arch: —
  - files: templates/handoff-required.md
- [x] **T2** **P0** Append that block to every handoff `cmd_handoff` writes in `scripts/runstate.sh`, resolving `templates/handoff-required.md` from the script's own location (a script-relative `HERE`, as `scripts/routing.sh` derives its own, overridable by `ORCH_HANDOFF_REQUIRED` for fixtures only — an override, never an omission path) rather than from the caller's cwd, emitting it verbatim after the piped body so the driver's two conditional lines stay ahead of it and are neither moved nor repeated, with no option to omit it on any of the three sources, and dying non-zero with the template's path in the message — after the body is read and before the temp file is created, so no partial handoff is left and the driver's producer never takes SIGPIPE in place of the message — when the template is missing, unreadable or whitespace-only, leaving the earlier `HANDOFF=refused` return untouched; `scripts/test-runstate.sh` gains a case asserting a written handoff holds the piped task text and then each of the six lines under the heading, a refusal case asserting a non-zero exit naming the template with no `handoff.md` on disk, and a location case run from a cwd that is not the plugin root with `ORCH_HANDOFF_REQUIRED` unset asserting the six lines still appear, each recording in its comment the mutation it rules out: with the append removed the first turns red, with the unreadable template warned-about-and-continued rather than refused the second turns red, and with the template resolved from `$PWD` instead of `HERE` the third turns red.
  - deps: T1
  - covers: Every handoff carries the verification block by construction
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [ ] **T3** **P1** Give `scripts/runstate.sh` a bounded upward config-root walk of its own — `CLAUDE_PROJECT_DIR` and the cwd, every ancestor declaring `.agents/`, bounded by `$HOME` and `/`, deduped, ADR 0011's rules reimplemented rather than shared because `hooks/guard.sh` is a hook body with no callable form — and append each non-blank, non-`#` line of every discovered root's `.agents/handoff-extra` after the six as `REQUIRED: ` plus that line verbatim, unioned so no root can remove another's line, refusing a present-but-unreadable file exactly as T2 refuses a missing template, and shipping a comments-only stub of the file in `templates/spec-driven-base/.agents/` so a consumer discovers the extension point (comments-only is byte-identical to absent, so the stub changes no handoff); `scripts/test-runstate.sh` covers a root with the file (each line appears with the `REQUIRED: ` prefix), one without (the handoff ends at the sixth line: no header, no empty section, no warning), one holding only comments and blank lines, one whose file is unreadable, and two nested roots whose lines both appear, with the mutations recorded in the case comments: append the lines without the prefix and the with-file case turns red, narrow the union to the nearest root and the two-root case turns red, drop the comment/blank filter and the comments-only root stops producing a handoff byte-identical to the no-file one, skip the unreadable file instead of refusing and the refusal case turns red.
  - deps: T2
  - covers: A repository extends the block with `.agents/handoff-extra`
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, templates/spec-driven-base/.agents/handoff-extra
- [ ] **T4** [P] **P0** State the contract from both sides of the dispatch — `agents/reviewer.md`, that a result file not satisfying an applicable block line is a `fix` naming that line with the same standing as any unmet acceptance criterion (a mutation-verification stating one count, neither, or not naming the wrong implementation its case rules out is a `fix`, never a pass with a note), and that the reviewer judges each line's *applicability* and never whether to check it, passing over an inapplicable line without waiving it; and `agents/implementer.md`, that the result file addresses every applicable line and that reporting a limitation where a line asks for one is the pass — both referring to the block by name and restating none of its six lines, with the `pass`/`fix`/`escalate` vocabulary and the routing of each unchanged. Prose only, no sweep case; checkable by reading each addition against `templates/handoff-required.md` and confirming no line's text appears in either agent file.
  - deps: T1, T2
  - covers: The reviewer treats each block line as an acceptance criterion
  - arch: —
  - files: agents/reviewer.md, agents/implementer.md
- [ ] **T5** [P] **P1** Point the two driver-facing surfaces at the block without restating it — a short comment in `templates/task-packet.yaml` naming `templates/handoff-required.md` as the source of the block every handoff carries (leaving its existing REQUIRED sweep-criterion rule, which is the driver's own first conditional line, exactly where and as it is), and a sentence in `skills/run-loop/SKILL.md` §3.3 stating that the driver appends only its two conditional lines and nothing from the block, which `runstate.sh handoff` adds itself, so a driver that forgets §3.3 entirely still produces a handoff carrying all six. Prose only, no sweep case; checkable by search — each line's distinctive phrase occurs in exactly one file under `templates/`, `agents/` and `skills/`.
  - deps: T1, T2
  - covers: The block's text has one source
  - arch: —
  - files: templates/task-packet.yaml, skills/run-loop/SKILL.md
- [ ] **T6** **P1** Record the decision where the harness and a future session will read it — a new ADR (next free number, 0029) stating that the verification contract is appended by the handoff writer rather than carried in the packet template, that a missing template refuses the handoff rather than degrading it, and that `.agents/handoff-extra` unions across config roots by ADR 0011's rules; and an amendment to `CLAUDE.md`'s driver-mode/ADR 0028 bullet naming `templates/handoff-required.md` as the block's one home, both naming the block and restating none of its six lines. Prose only, no sweep case; checkable by reading each new sentence against the template it cites and confirming neither file reproduces a line's text.
  - deps: T1, T2, T3, T4, T5
  - covers: The block's text has one source
  - arch: —
  - files: docs/adr/0029-handoff-verification-contract.md, CLAUDE.md
