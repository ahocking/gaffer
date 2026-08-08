# Human-facing report shapes — what the HUMAN reads (ADR 0003 / 0012)
# -----------------------------------------------------------------------------
# `check-in.md` is the AGENT-TO-AGENT wire format. A lane or a dispatched Chief
# Engineer returns that shape to the scheduler, which parses it and records state
# from it. It is unchanged and must stay machine-shaped.
#
# THIS file is the HUMAN-FACING layer. Whoever holds the main context window —
# usually the Chief Engineer driving the loop — renders the wire check-ins into one
# of the two shapes below before they reach the human. Two shapes, two moments:
#
#   A. CHECK-IN     — a packet or a wave of lanes came back. Emitted per landing.
#   B. STOP REPORT  — the loop stopped (done, paused, blocked, or out of gas).
#
# Render from the check-in text you were handed, and NOTHING else. Do not re-open
# the repo, re-read a diff, re-run tests, or re-derive a fact to write these. The
# rendering is free; going back to disk to embellish it is the context refill
# ADR 0012 forbids, and it is what makes a relayed loop expensive.
#
# ## Four rules both shapes obey
#
# 1. **Every id carries a plain-English title the first time it appears** — packets,
#    ADRs, findings, tasks, branches. `wbr-t14` alone is unreadable to someone who is
#    not holding the numbering in their head, and the human never is. Write
#    **Rate-limit auto-pause** (`wbr-t14`), or drop the id entirely. Same for an ADR:
#    **ADR 0017 (cooperative pause)**, never a bare number.
# 2. **One line per thing.** If a status needs two lines it is not a status — it is a
#    decision or a finding, and it belongs in the stop report or in
#    `.agents/findings/`.
# 3. **Omit an empty section entirely.** Never write "Findings: none" or
#    "Blockers: n/a". A line the human must read to learn nothing is exactly the
#    cost these shapes exist to remove.
# 4. **Leave out the machinery.** No diffs, no file lists, no test output, no tool
#    names, no token counts, no transcript quotes, no restating of the packet's own
#    goal text. The human asks a follow-up when they want depth — do not pre-empt
#    them with a paragraph they did not ask for.
#
# Status markers, fixed set:  ✅ landed green · ⚠️ needs a decision · ⏸ paused ·
# ⛔ failed or rolled back · 🔁 retried and landed.


# --- A. CHECK-IN (a packet landed, or a wave of lanes came back) ---------------
# One line per packet or lane, in the order they landed. In sequential mode that is
# a single line; in parallel mode it is one per lane. Keep the whole thing under
# roughly six lines — this is read on a phone, between other things.

### Check-in — <N> landed · <M> need you
<!-- drop the "· M need you" clause when M is 0 -->

✅ **<What is now true, in human words>** (`<id>`) — <one clause of outcome>. `<sha>`
⚠️ **<Title>** (`<id>`) — <what stopped it, one clause>. <the call you'd have to make>
⛔ **<Title>** (`<id>`) — <what failed>. Rolled back to `<sha>`, nothing lost.

**Next:** <plain title of the next packet> (`<id>`) · <N> left
**Worth knowing:** <one line, only when something genuinely changed the picture>

# `Worth knowing:` is for a fact that changes what the human expects — a scope that
# turned out bigger, an assumption that proved wrong, a dependency discovered. It is
# NOT a place to restate what landed, and it is NOT the findings index (that lives in
# run-state; the human reads it on request, not on every packet).

# Worked example — sequential, one packet:
#
#   ### Check-in — 1 landed
#
#   ✅ **Usage-limit auto-pause now stops the run before the weekly cap** (`wbr-t14`)
#      — sensor reads both windows, writes the existing pause file. green · `a3f9c21`
#
#   **Next:** **Pause regression sweep** (`wbr-t15`) · 4 left
#
# Worked example — parallel wave, one lane needs a decision:
#
#   ### Check-in — 2 landed · 1 needs you
#
#   ✅ **Findings moved out of run-state into their own files** (`f-t3`) — green · `9b21e04`
#   ✅ **Run-state note capped at one line** (`f-t4`) — green · `c40aa11`
#   ⚠️ **Outcome attestation** (`f-t6`) — needs a new field in the run-state schema.
#      Bump the schema, or attest to a side file? Nothing written yet.
#
#   **Next:** waiting on the decision above · 3 left


# --- B. STOP REPORT (the loop stopped, for any reason) ------------------------
# Emitted on backlog complete, on pause, on a hard gate, and on a blocking question.
# This is the one the human reads carefully, so it earns more room than a check-in —
# but every section still has to survive a ten-second scan.

## <What this run was about, in plain words> — <done | paused | blocked | stopped>
<one sentence: why it stopped, and whether anything is at risk right now>

**Shipped** — <N> of <M>
- **<What is now true that wasn't before>** — <one clause of consequence>
- **<…>** — <…>

**Not done**
- **<Title>** (`<id>`) — <why, one clause>

**Decisions for you**
1. **<The question, asked as an actual question>**
   - **<Option A>** → <what follows if you pick it>
   - **<Option B>** → <what follows if you pick it>
   - *I'd pick <A>* — <half a line of why> · *If you say nothing:* <the default path>

**Recommended next**
- <one imperative action> — <why, half a line>

**State:** branch `<branch>` at `<sha>`, tree clean · <how to pick it back up>

# ## Rules for the decisions block — this is the part that has to be right
#
# - **Each decision is answerable in one word.** If the human cannot reply "A" or
#   "yes", it is not scoped enough yet — split it or go decide the sub-parts
#   yourself. Two options is the target; three is the ceiling. If more exist, name
#   the two real ones and say in half a line what you ruled out and why.
# - **Each option states its CONSEQUENCE, not its rationale.** "→ ships this week,
#   schema migration later" is a consequence. "→ cleaner separation of concerns" is
#   an argument, and the human did not ask for one.
# - **Say the asymmetry out loud when there is one** — reversible vs not, an hour vs
#   a day, affects one packet vs the whole backlog. That is usually the only fact
#   they need to decide.
# - **Always give a lean, and always give the default.** "If you say nothing: <X>"
#   tells them whether silence is safe. Never present a menu with no recommendation.
# - **Order by what is blocking the most**, not by when you hit it.
# - **Cap the list at four.** Past that, list the top four and add
#   "*<N> more, lower stakes — ask and I'll lay them out.*" A decisions block too
#   long to scan does not get scanned.
# - **Detail lives elsewhere.** A decision that needs background points at the
#   finding or ADR by title (`.agents/findings/<id>.md`, "ADR 0017 (cooperative
#   pause)"); it does not inline the background.
#
# Worked example:
#
#   ## Pause and resume across sessions — paused
#   Stopped cleanly at a green commit after the fourth packet; nothing is at risk.
#
#   **Shipped** — 4 of 7
#   - **A run can now be stopped mid-flight and picked up in a new session** — the
#     stop always lands on a green commit, never mid-edit.
#   - **Usage-limit auto-pause** — a long unattended run halts before the weekly cap
#     strands the account for days.
#   - **Per-lane pause** — one parallel lane can be stopped without stopping the run.
#   - **Regression sweep for all of the above.**
#
#   **Not done**
#   - **Outcome attestation** (`f-t6`) — blocked on decision 1 below.
#   - **Rework-rate metric** (`f-t7`) — depends on `f-t6`.
#
#   **Decisions for you**
#   1. **Where should a failed packet's outcome be recorded?**
#      - **In run-state** → one file to read, but the schema version bumps and every
#        older run needs reconciling on resume.
#      - **In a side file next to the metrics** → no schema change, no migration;
#        one extra file for a resuming session to look at.
#      - *I'd pick the side file* — reversible, and run-state has a single-writer
#        rule that a lane cannot honour anyway. · *If you say nothing:* I'll take the
#        side file and note it as a finding.
#
#   **Recommended next**
#   - Answer decision 1 and let the loop finish the last three packets — it's ~40
#     minutes of work and nothing else is blocked.
#
#   **State:** branch `orch/pause-resume` at `c40aa11`, tree clean · `/gaffer:resume`
