# skill-prompt-trim — ledger

The tracked record for the `skill-prompt-trim` feature
(`gspec/features/skill-prompt-trim/prd.md`). It holds the starting figures the
size gate is measured against, the reported `cc_shape` baseline, and the
results later tasks record. Every figure below was measured before any skill
was edited.

## Preconditions

Every task in `gspec/features/loop-prose-consistency-gaps/tasks.md` (3 of 3)
and `gspec/features/implementer-continuation/tasks.md` (8 of 8) was checked at
the baseline commit.

## Baseline

- **Baseline commit:** `48de82d11040cbee0374a0601a30f7faaff59ead`
  (`git rev-parse HEAD` at measurement, 2026-09-25).

Each byte count is `wc -c` of the file at the baseline commit; to reproduce
one, run `git show 48de82d11040cbee0374a0601a30f7faaff59ead:<path> | wc -c`.

### Loop skills (gated)

- `skills/run-loop/SKILL.md`: 83774 bytes
- `skills/resume/SKILL.md`: 42632 bytes
- `skills/pause/SKILL.md`: 17418 bytes
- **Total:** 143824 bytes
- **Gate figure** (half the total, rounded down): **71912 bytes**. The three
  loop skills together meet the size gate when their combined `wc -c` is at or
  under this figure.

### One-shot skills (reported, not gated)

- `skills/migrate/SKILL.md`: 29622 bytes
- `skills/metrics/SKILL.md`: 22028 bytes
- `skills/new-project/SKILL.md`: 9373 bytes
- `skills/review-change/SKILL.md`: 6512 bytes

## `cc_shape` (reported, never gating)

The driving session's `cc_shape` (ADR 0019 v3.4 §1) is the `main` role in
`by_agent_role`, read through `scripts/metrics.sh`. Per the PRD it is reported
against ADR 0019's noted run-to-run variance and is never offered as proof on
its own.

### Before the trim — the `loop-prose-consistency-gaps` run

Run `20260925T182537-3f4b`, driving session
`67b3c5ad-a97f-4212-8c60-12dc9c1cd37a`. That run went on to start this
feature's packets, so the window ends at the `loop-prose-consistency-gaps-t3`
`green` outcome (`2026-09-25T18:41:30.720Z` in the session's outcomes log).

Two windows are recorded, because they give materially different figures. The
session's first turn (`2026-09-25T18:21:52Z`, 73888 cache-creation tokens, the
full load of its standing context) happened before the run id's start time.

- **Run window** (`18:25:37Z` to `18:41:31Z`, the run id's start to the t3
  outcome): `main` p90 **1429**, max **2161** (28 turns, median 721, no turn
  over 50k).
  Command: `scripts/metrics.sh collect --session 67b3c5ad-a97f-4212-8c60-12dc9c1cd37a --since 2026-09-25T18:25:37Z --until 2026-09-25T18:41:31Z --out <file>`
- **Session window** (from before the session's first turn to the t3
  outcome): `main` p90 **3600**, max **73888** (43 turns, median 912, one turn
  over 50k).
  Command: `scripts/metrics.sh collect --session 67b3c5ad-a97f-4212-8c60-12dc9c1cd37a --since 2026-09-25T18:00:00Z --until 2026-09-25T18:41:31Z --out <file>`

**Run-to-run variance noted in ADR 0019** (v3.4 §1): across four untouched
same-regime sessions, coordinator cache-creation per packet spans **1.76x**,
and across all sessions **9x**. A change removing about 150k of context is
20–30%, inside that noise. `cc_shape` was added because its `max`/`p90`
separate by an order of magnitude between regimes (session `max` from 24,190 to
239,851 in that ADR's table) while the median stays flat. ADR 0019 gives no
separate variance figure for `cc_shape` itself.

### After the trim

- **After-trim `cc_shape` (`main` p90 / max):** *to be filled on the first
  loop run after this feature lands.* Measure it over the same window type as
  the baseline figure it is compared with.

## Changed sweep assertions

- **T4 (record-completion at the four sites):** no existing assertion changed.
  No sweep pinned the prose the four sites gave up. `test-report-conventions.sh`
  gains one section: each site calls `record-completion` with its own restore
  source, keeps its own staging, commit, restore and report rules, and carries
  no copy of the exit-code table.

## Loop-skill rule review

## One-shot skill rule review
