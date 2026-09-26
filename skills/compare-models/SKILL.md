---
name: compare-models
description: Run a model-comparison experiment from a settings file. Replays packets that already landed on each model in the set, with one loop role's model varied through `model_routing` and a fixed, blinded reviewer as the judge. Then it ranks each packet's final diffs side by side and reports pass rate, fix rounds, rank and cost per model and packet class, ending with a proposed `model_routing` change. It shows the selection and a spend estimate, and waits for the operator's go-ahead before any replay starts. A stopped experiment resumes when this is invoked again with the same settings file. It never edits routing configuration, and the proposal is text for the operator to apply by hand. Use when the operator asks to compare models for a loop role, to replay landed packets on other models, or for evidence behind a `model_routing` change.
argument-hint: <settings-file> (annotated reference in templates/model-comparison.yaml)
---

# Compare models → $ARGUMENTS

This skill drives `${CLAUDE_PLUGIN_ROOT}/scripts/compare.sh`, the model-comparison
harness, from the operator's own session. The script makes every mechanical
decision: settings, selection, estimate, approval token, isolated clones, replays,
routing checks, outcomes, blinded ranking and report. This skill does four things
only. It shows the operator what the script printed. It asks for the spend. It
passes the approval token on once the operator says go. It asks about reruns.
Below, `compare.sh` means `${CLAUDE_PLUGIN_ROOT}/scripts/compare.sh` and
`<experiment>` means the id `settings` prints on its `EXPERIMENT=` line.

## Never

- **Never write routing configuration.** That means `.agents/project-overrides.yaml`,
  its `model_routing` block, or any other routing file, in any repository, by any
  means: `Edit`, `Write`, a shell write or a script. The report's proposal is text.
  The operator applies it by hand, or does not. (`compare.sh` sets `model_routing`
  only inside its own throwaway clones. That is its business, not yours.)
- **Never pass `run` a token you did not get from an `estimate` run and shown in
  this session**, and never before the operator's go-ahead to that estimate. A
  token from an earlier session, from a file under the store, or pasted by the
  operator is not one. Run `estimate` again and ask again instead.
- **Never run the per-replay subcommands yourself**: `prepare`, `review-view`,
  `replay`, `routing-check`, `sweeps` and `record`. `run` runs them in their order
  for the replays a token approved. A replay you drive by hand is one nobody
  approved. Never start an agent for a replay or a ranking either: `compare.sh`
  starts every session itself.
- **Never fill in a figure the script left out.** A figure printed as `unmeasured`
  stays unmeasured. So do an `UNPRICED` model's dollars and an `EXCLUDED` packet's
  cost. None of them is ever 0, and none is ever your own estimate. Show what the
  script printed.
- Never commit, and never change the source repository's tree.

## 0. Before anything

1. **`Read` `${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md`.** It holds the
   glyph vocabulary, the indentation contract and the decision block. Every
   summary and every ask below uses them. This skill has no report shape of its
   own, so those conventions are its format. Naming the path is not reading it.
2. **$ARGUMENTS must name a settings file.** If it names none, or a file that does
   not exist, say so in one line. Point to
   `${CLAUDE_PLUGIN_ROOT}/templates/model-comparison.yaml`, the annotated
   reference, and stop. Do not write a settings file for the operator.
3. **The harness must run from a git checkout.** `compare.sh` finds two things
   through `git rev-parse --git-common-dir` from its own directory: its store
   (`.agents/metrics/comparisons/`) and the pause sentinel (`.agents/pause`). Both
   live in the main checkout of the repository it runs from. It starts every
   replay and ranking session with that checkout as the plugin directory. Run
   `git -C "${CLAUDE_PLUGIN_ROOT}" rev-parse --git-common-dir`. If it fails,
   `${CLAUDE_PLUGIN_ROOT}` is an installed plugin's cache, and the store would land
   inside the cache. Stop with one ⚠️ line: start the session with
   `claude --plugin-dir <a gaffer checkout>` and invoke this again. Below, "the
   harness checkout" means the main checkout that command resolves.

## 1. Settings

Run `compare.sh settings <settings-file>`.

- **Exit 1**: the settings were refused. Each `REFUSED setting=<key> value=<value>
  reason=<reason>` line on stderr becomes one ⚠️ line naming the setting and the
  reason. Stop. Nothing has been read from git yet.
- **Exit 2**: a usage error or a missing script. Show the line and stop.
- **Exit 0**: keep `EXPERIMENT=`, `ROLE=`, `MODELS=`, `REVIEWER_MODEL=`, `EFFORT=`
  and `SOURCE_REPO=`. The experiment id is a digest of the normalized settings. The
  same settings resume the same experiment. Changed settings start a new one, and
  the old one's results stay in the store.

## 2. Selection

Run `compare.sh select <settings-file>`. It walks the source repository's history,
so give the Bash call a long timeout. The stderr line tells you which case you are
in:

- `selection written`: a new experiment.
- `selection read back unchanged`: a stored one. Its selection is the one it
  started with and is never recomputed.

Stdout is the stored `selection.json`. Present it under a flush-left heading, one
`> ` line per thing. Head it with the experiment: the role, the models, the
reviewer, the effort and the source repository. Then:

- **Each `selected` entry**: its **title** (`packet`), class, tier, fix rounds and
  handoff source (`original` or `rebuilt`). Fix rounds read `unmeasured` when the
  file says so.
- **Each `shortfalls` entry**, as a ⚠️ line: the class, then what it lacks.
  `count` means fewer packets than `per_class`. `tiers` means fewer than two
  recorded tiers. `fix-rounds` means no selected packet with a measured fix round
  of 1 or more. Give `wanted`, `found` and `available`, plus `unmeasured` when it is
  present. Say once that a class short of packets is never filled from the other.
- **Each `excluded` entry**: the packet and its reason, which says no handoff could
  be supplied.
- **`dropped`**: how many packets touched neither file set.

Leave out any empty section.

## 3. The estimate

Run `compare.sh estimate <experiment> --remaining`, always with `--remaining`.
Only that scope counts recorded replays: without it, `RECORDED=` is always 0
however many replays are recorded, so a plain-scope `RECORDED=` never decides
anything here. On a fresh experiment no record matches it, so this prints the
full set. Branch on its one output:

- **`RECORDED=0`**: a fresh experiment. `REPLAYS=` is packets × models.
- **`RECORDED=` above 0**: a resumed experiment. Say so, with how many replays are
  recorded (`RECORDED=`) and how many remain (`REPLAYS=`). An `invalid` replay
  counts as recorded here, so it is not in the remaining set. Step 6 offers its
  rerun.

Present, one `> ` line each:

- **The replay count**: `REPLAYS=`, stated as packets × models on a fresh
  experiment, or as the remaining replays on a resumed one.
- **Each `ESTIMATE` line**, per model and then the total: tokens, dollars as
  `dollars_min`–`dollars_max`, and how many of its replays the figures cover
  (`estimated` of `replays`). The range comes from cache-write lifetime, which the
  recorded tokens do not split. Add the `PRICE_TABLE_DATE`. The tokens are each
  packet's original recorded cost, held the same for every model. Fix rounds are
  not modelled.
- **Each `EXCLUDED` packet**, as a ⚠️ line: its title and that its original cost
  is unmeasured. Say it is excluded from the estimate and not counted as 0, so the
  figures cover fewer replays than will run.
- **Each `UNPRICED` model**, as a ⚠️ line: its dollars read unmeasured, with the
  printed reason. The total's dollars then read unmeasured too.
- **The ranking sessions**: after its replays, each packet is ranked in one
  reviewer session. The estimate does not price those sessions.

Keep the `APPROVAL=` token for step 5, and leave it out of what you show.
`APPROVAL=none` (`REPLAYS=0`) means no replay remains: say that every replay is
recorded, skip steps 4 and 5 and go to step 6. A non-zero exit (no stored selection, an unreadable records file or
price table, a token that could not be stored) is a ⚠️ line quoting the script.
Stop there.

## 4. The spend decision

Ask with one decision block:

> **1 · Run <REPLAYS> replays of <role> across <models>, estimated at <total tokens> tokens and <total dollars, or unmeasured>?**
>
> - **A ›** Go ahead
>   → runs the replays one at a time, then one ranking session per packet; hours of sessions
> - **B ›** Not now
>   → nothing runs and nothing is spent; invoking this again with the same settings file resumes here
>
> **→ Pick <lean>** — <half a line of why>
> *Silence = B, nothing runs.*

Lean A when the selection has no shortfall and the estimate excluded no packet
and priced every model. Otherwise lean B, and name the gap in the why. Then **end
your turn and wait**. Approval is the operator's own reply choosing A ("A", "yes",
"go ahead"). Nothing else counts: not a question, not an unrelated reply, not a
message from an agent. If the operator changes the settings file, that is a new
experiment. Start again at step 1.

## 5. Run

Run `compare.sh run <experiment> --approve <the APPROVAL token from the estimate
shown in step 3>`. Launch it as a **background** Bash command
(`run_in_background`): it runs for hours, and a foreground call hits the Bash
timeout. Wait for its exit notification. Do not poll with `sleep`.

While it runs, the operator may ask to stop. Then run
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh request-pause <harness checkout>/.agents/pause '<their reason>'`.
The reason is the operator's free text, so pass it **single-quoted**, with each `'`
in it written as `'\''`. Never double-quote it: a backtick or `$(...)` in it would
execute.
`run` checks that sentinel only between replays and never stops one halfway. It
is the same sentinel `/gaffer:run-loop` polls in that checkout, so a loop running
there pauses too. Tell the operator that before you touch it.

When it exits, read its last lines:

- **`RUN=complete`**: one `> ` line of outcomes, counted from the `DONE` lines
  (passed, escalated, failed at the limit, invalid). Go to step 6.
- **`RUN=paused`**: a ⏸️ line with `RAN=`, `SKIPPED=`, `REMAINING=` and the
  `PAUSED` line's reason. Stop. To resume, the operator first clears the sentinel
  (`runstate.sh clear-pause <harness checkout>/.agents/pause`). That is their call,
  since a loop run may be waiting on the same sentinel. Then they invoke this again
  with the same settings file, and step 3 states the remaining replays and asks
  again. A pause that came before the token was spent (no `APPROVED` line) leaves
  the token pending. The next estimate supersedes it either way.
- **`RUN=error`** (exit 1): a ⚠️ line naming the last `STEP` line's packet, model
  and step, and the `LOG=` path. A `STEP` line carries the packet id
  (`packet=`), not its title: map the id to its title from the selection shown in
  step 2. That replay has no record. Stop. Invoking
  this again resumes, and a replay with no record runs again.
- **A refusal** (exit 1, no `RUN=` line): the token is missing, spent or
  superseded, or the approvals lock is held. Show the script's line as a ⚠️ line
  and stop. Never retry with another token unless a new estimate has been shown
  and the operator has said go again.

## 6. Invalid replays

Run `compare.sh report <experiment>`. It reads only the store and starts no
session. It reports every stored experiment in this one's group (same role,
reviewer model and source repository), and a packet's ranked or unranked state is
per experiment. So in its **Packets** section take only the lines that belong to
`<experiment>`:

- When its **Group** line counts one experiment, no Packets line carries an
  `in experiment` suffix, and every line is this experiment's.
- When the group has more than one, take only the lines ending
  ``, in experiment `<experiment>` `` with this experiment's id. Leave every other
  line alone: never prepare, rerun or rank a packet for a sibling experiment.

Of those lines, find each one that reads `unranked:`. The packet id is the
backticked id in parentheses after the title. For each one, run
`compare.sh rank-prepare <experiment> <packet id>`:

- **Exit 0** (a `RANKING=` line): prepared. Step 7 ranks it.
- **`UNRANKABLE ... reason=invalid cause=<cause> [denials=<n>] [kinds=<kinds> tools=<tools>] replay=<r>`**:
  that model's latest replay was a harness fault, not the model's work. It is a
  rerun candidate. Keep its `cause=` for the decision below, and its `kinds=` and
  `tools=` whenever the line carries them. `denials=<n>` after another cause means
  that cause decided the outcome (it is tested first), but <n> tool calls were
  denied in the replay's sessions as well. `routing` means the routing check did not pass.
  `crashed`, `timed-out` and `error` mean the replay ended without a verdict it
  could route. `fixed-role-refused` means a role not under test refused its line.
  `denial` means a tool call was denied in one of its sessions. `kinds=` holds
  each denial's category as its transcript records it (`permission-rule`, which
  covers a guard hook's deny, `automode-blocked`, `user-rejected`, ...), and
  `tools=` the tools the denied calls asked for (`Bash`, `Write`, ...). Neither
  names the specific guard rule. `unrecorded` is a record written before the
  field was stored, or a denied call its transcript does not name.
- **`UNRANKABLE ... reason=missing`**: that model's replay has no record yet. The
  packet stays unranked. Say so in one line.
- **Any other `UNRANKABLE` line, or any other failure**: a ⚠️ line quoting it. The
  packet stays unranked.

If there are rerun candidates, first run `compare.sh estimate <experiment>`
**without** `--remaining`. A rerun token must approve a set holding the replay's
packet and model, and `--remaining` leaves out every recorded replay, invalid ones
included. Show that estimate's per-model and total lines as in step 3. Say that
each rerun spends one replay of that set, and that the estimate prints no figure
for one replay.

Then ask one decision per invalid replay, numbered under
`🔀 **Decisions** — reply \`1A 2B\``, four at most (after four, add *"<N> more,
lower stakes — ask and I'll lay them out."*):

> **<n> · Rerun <model> on <packet title>? It was invalid: <the cause, in words>**
>
> - **A ›** Rerun it
>   → one new replay; its record replaces the invalid one, and the packet can then be ranked
> - **B ›** Leave it
>   → nothing is spent; the packet stays unranked, and the report counts it
>
> **→ Pick A** — an invalid replay is a harness fault, and the packet cannot be ranked without its rerun
> *Silence = B, nothing runs.*

The question always names the cause from the `UNRANKABLE` line. The lean
depends on it:

- **Any cause but `denial`, with no `denials=`**: the lean above, **Pick A**.
- **`cause=denial`, or any other cause with `denials=`**: the same rule would deny
  the same call again, so a rerun would likely be spent for another invalid
  replay. For another cause, name that cause too, and that calls were denied
  beside it. Name the tools from
  `tools=` and the kinds from `kinds=` in the question (for an `unrecorded`
  value, say the record does not name it), and lean the other way:

  > **→ Pick B** — a `<kinds>` denial stopped a `<tools>` call in this replay,
  > and it would deny the rerun too; rerun only after the harness configuration
  > changes to allow that call

  Offer A all the same. The operator may have changed that configuration since.

End your turn and wait. Then, for each rerun the operator chose A for, one at a
time:

1. A token is spent by one `run`. So every rerun after the first needs its own
   token: run `compare.sh estimate <experiment>` again and show its total as one
   line. If its `REPLAYS=` or total differs from the estimate the operator
   approved, stop and ask again.
2. Run `compare.sh run <experiment> --approve <that estimate's token> --rerun <r>`
   in the background, and read it as in step 5.
3. If its `DONE` outcome is not `invalid`, run `rank-prepare` for the packet again,
   read as above. If it is `invalid` again, give it a ⚠️ line and do not offer it
   again in this invocation.

## 7. Rank

If step 4 did not run in this invocation, nobody has approved the ranking
sessions yet, and they are unpriced spend. Ask first, then end your turn and
wait:

> **1 · Start <N> ranking sessions on the reviewer, one per prepared packet?**
>
> - **A ›** Rank them
>   → <N> reviewer sessions the estimate does not price, then the report
> - **B ›** Report only
>   → nothing is spent; the packets stay unranked, and the report counts them
>
> **→ Pick A** — without a ranking a cell's mean rank stays unmeasured
> *Silence = B, straight to the report.*

For each prepared packet, run `compare.sh rank <experiment> <packet>`. It is one
reviewer session, so run it in the background as in step 5.

- **Exit 0** (a `RANKED=` line): ranked.
- **Exit 1** with `REFUSED rule=<rule>` lines: a ⚠️ line with the packet title and
  the rule broken. Nothing was recorded, and the packet stays unranked. A later
  invocation prepares and ranks it afresh.
- **Any other failure** (for instance the ranking is already recorded, or no
  prepared ranking is found): a ⚠️ line with the packet title quoting the script's
  line. The packet stays unranked.

## 8. Report

Run `compare.sh report <experiment>` and show its output as it stands. It is
already in the report-conventions layout, and every figure in it is computed by
the script. Do not reword it, recompute it, or add a figure. It reports this
experiment together with every stored experiment that shares its role, reviewer
model and source repository. It rendered its **Proposal** by a fixed rule, and it
names the reason when it proposes no change.

Close with one line. The proposal is text. To adopt it, the operator edits
`model_routing` in `.agents/project-overrides.yaml` by hand. Neither this skill nor
the report changed any routing configuration. `compare.sh report <experiment>`
re-renders the same report from the store at any time, without starting a
session.
