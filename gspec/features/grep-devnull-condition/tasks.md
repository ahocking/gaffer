---
spec-version: v2
feature: grep-devnull-condition
---

# Plan: grep-devnull-condition

**The fix and the sweep case that reproduces the bug land together, first. The wider guard lands second.** T1 changes `_dirty_has_reviewed_output` in `scripts/runstate.sh` so no reader can close the pipe before its writers finish. In the same packet it adds a repeat-loop reconcile case to `scripts/test-runstate.sh`. T2 widens `PIPE_GREP_Q_RE` in both sweeps, adds the self-proof checks for each new shape, and rewrites both KNOWN BOUNDARY comments.

**The case and the fix share one packet because either order alone leaves CI red.** CI runs on `ubuntu-latest`, which has GNU grep. The new case fails there against the old code, and that failure is the evidence the PRD asks for. If the case landed first, CI would stay red on develop until the fix landed. So T1 writes the case, runs it against the old code under GNU grep and records the failure in the case's comment, then applies the fix. It commits only when green.

**The guard comes after the fix, never before.** The wider guard in `scripts/test-runstate.sh` scans `scripts/runstate.sh`. Today that file still holds `| grep -E "$combined" >/dev/null` (`_dirty_has_reviewed_output`, ~:3644). This is its only stdout-to-`/dev/null` grep. `scripts/gspec-backlog.sh` has none. A guard that landed first would be red on a known instance, which the PRD rules out.

**Both copies of the regex change in one packet.** `PIPE_GREP_Q_RE` must be byte-identical in the two sweeps after the change. Splitting the edit would leave a commit where the two copies differ.

**Deferred decision, settled here: a redirect to any path other than `/dev/null` is not matched.** GNU grep stops at the first match only when stdout is the null device. Output to a regular file does not do that, so flagging it would be a false positive the exception list would then have to carry. The other deferred choice is left to T1's implementer: hold the listing in a captured value tested from a here-string, or fold an emptiness test into the writer. It has one constraint: whatever form T1 picks must not match T2's wider shape.

**No CI change is needed.** `.github/workflows/ci.yml` already runs both sweeps by name, on GNU grep.

**File ownership and `[P]`.**
- `scripts/runstate.sh` belongs to T1 alone.
- `scripts/test-runstate.sh` belongs to T1 and T2, so T2 depends on T1. Neither task is `[P]`: T1 is alone in its wave, so the marker would parallelise nothing.
- `scripts/test-gspec-backlog.sh` belongs to T2 alone.

The waves are T1 → T2.

**Reflexivity.** `scripts/runstate.sh` takes effect mid-run, in the run that edits it. The reconcile path runs only on `/gaffer:resume`, so the first live use of the fix is the next crash recovery. T1's sweep case stands in for it until then. No task touches a hook body, an agent, a skill, `hooks/hooks.json` or `.claude/settings.json`.

Every regression sweep must pass after every task.

## Plan

- [ ] **T1** **P0** Make `_dirty_has_reviewed_output` in `scripts/runstate.sh` read the whole `git status` listing before it decides, and extend the large-dirty-tree reconcile case in `scripts/test-runstate.sh` (~:433–451) into a repeat loop that asserts `escalate` by name on every iteration.

  The function:
  - keeps its never-fails contract and its true/false meaning: a tree with no reviewed-output path reads false, and a tree that cannot be listed reads as it does today;
  - leaves `_reconcile_tree`'s `elif` and the branches around it unchanged;
  - contains no pipe-fed grep, whether with `-q` or with a `/dev/null` stdout;
  - carries a rewritten comment (~:3621–3640), not a deleted one. It says why `-q` is correct again in the new form, that the `>/dev/null` form it replaces stops at the first match under GNU grep, and that holding the whole listing in memory is deliberate. That way no later reader restores the redirect or turns the new form back into a pipe-fed grep.

  The sweep case:
  - builds a dirty tree with one reviewed-output path plus enough untracked leaf files that the status listing is far larger than any pipe buffer;
  - asserts `[ "$(decision)" = escalate ]` on every pass of a repeat loop. It never asserts only that the decision differs from `discard`, because several wrong answers would pass that.

  Before applying the fix, run the case against the old code under GNU grep (CI, or a GNU grep first on PATH) and watch it fail. The case's comment records:
  - that observation;
  - the host it was made on;
  - that a green run on a BSD grep or ugrep host does not certify the fix.

  If no GNU grep host was reachable, the comment says the failure was not observed.
  - deps: —
  - covers: Reconcile's reviewed-output check reads its whole input before deciding · A reconcile sweep case reproduces the misfire under GNU grep and pins the fix
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [ ] **T2** **P1** Widen `PIPE_GREP_Q_RE` in `scripts/test-runstate.sh` and `scripts/test-gspec-backlog.sh`, byte-identical in both, so it flags a pipe-fed grep whose stdout goes to `/dev/null` and a pipe-fed grep with a `q`-bearing option after its pattern. Add one self-proof check per new shape to each guard, and rewrite both KNOWN BOUNDARY comments.

  The regex:
  - matches `>/dev/null`, `> /dev/null`, `1>/dev/null` and `&>/dev/null` on a pipe-fed grep;
  - matches a `q`-bearing option (`-q`, `-qx`, `--quiet`) after the pattern;
  - does not match a bare `2>/dev/null` on its own;
  - does not match a redirect to any path other than `/dev/null`;
  - still does not match a here-string grep;
  - finds 0 hits on the real `scripts/runstate.sh` (after T1) and on `scripts/gspec-backlog.sh`, with both exception lists still empty.

  Each guard gets one self-proof check per new shape, next to the existing `-q` ones and carrying a `__guard_selfproof_*` marker. Each is shown to turn the guard red wherever it is planted in the scanned file, and that is recorded in the case's comment.

  Each KNOWN BOUNDARY comment:
  - no longer names the `/dev/null` shape, the `runstate.sh` line T1 removed, or any other shape the guard now catches;
  - states the limits that remain: a construct inside a trailing comment, a pipeline split across a `\`-continuation, and a stdout redirect to a path other than `/dev/null`.
  - deps: T1
  - covers: Both source guards flag a stdout-to-`/dev/null` or `q`-after-pattern grep condition as they flag `-q`
  - arch: —
  - files: scripts/test-runstate.sh, scripts/test-gspec-backlog.sh
