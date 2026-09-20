---
spec-version: v2
feature: runstate-write-integrity-gaps
---

# Plan: runstate-write-integrity-gaps

**The live defect lands first; the riskiest one lands behind a fixture.** T1 is the only capability here fixing a failure that has already cost a run a workaround (the 2026-09-15 cursor advance), so it is first and depends on nothing. The decoder unification touches every read path in the file at once, and a decoder regression is silent in exactly the way the defects it closes are silent — so T2 builds the fixture table and the round-trip assertion **before** any decoder moves, asserting only what is true today, and T3/T4 extend that one table as each cell becomes true. Tests-first here means the fixture arrives first and the sweep stays green at every boundary; it never means landing a red sweep.

**Deferred decision 1, resolved: the refusal is computed from the target file's own shape, not from a maintained list of keys known to be nested-only.** A list is a claim about every future schema — the same construct as the plain-scalar allowlist the parent built and deleted in one afternoon — and it cannot see defect 1's second shape at all, since `backlog` *is* at column 0. Shape detection answers both from the file in front of it: matched only at indentation > 0 ⇒ nested; matched at column 0 with an empty remainder and an indented next line ⇒ a mapping or list header.

**Deferred decision 2, resolved: one shell function plus one shared awk function text, not a per-record shell-out.** The PRD defers this pending a measurement of the per-record cost inside `trim-note`'s single pass, and this feature does not carry that measurement — so choose the form that does not need it. The awk expression lives once, in a shell variable prepended to each awk program, so the three awk sites (the PRD's "two inline awk sites" undercounts by one — `_findings_default` is awk too) share one implementation *string* rather than three hand-copied blocks. Two expressions of one rule remain (shell and awk); T2's fixture table is what keeps them honest, which is the PRD's own stated contract.

**`hooks/pause-check.sh` gets a third expression of the decode rule, deliberately.** It resolves the sentinel itself and reads it with its own grep, and it must stay grep-only: spawning the 3,900-line `runstate.sh` on every tool call while a pause is live is a cost and a failure mode a best-effort advisory hook must not take on. Capability 2's "all four" are the decoders **inside `runstate.sh`**; the hook's unwrap sits outside that set and is pinned by T5's hook cases rather than by a comment. If it is ever collapsed, the honest way is the hook calling `pause-status`, and that is a different decision than this feature's.

**Two constraints bind every task and are not tasks.** No `jq`, `python3`, `yq` or any `command -v` gate enters `runstate.sh` — only T6's PATH-scrub case is executable work against that, and it rides the `NOTOOLS`/`bare` block the parent's T8 already built. And `scan_pipe_grep_q` in the same sweep scans `runstate.sh` for a pipe-fed `grep -q`/`grep >/dev/null` with an **empty** exception list, so new detection code reads its file directly; adding a hit there fails the sweep and correctly so.

**File contention, and why only the last two tasks are `[P]`.** T1, T3 and T4 all write `scripts/runstate.sh` *and* `scripts/test-runstate.sh`, and T2/T6 write the sweep, so they serialize and none is marked. T6 (sweep) and T7 (`CLAUDE.md`) have every dep backwards and disjoint files, so those two are honestly parallel-safe. `.agents/task-files.yaml` carries no entry for this feature, so every packet resolves to empty scope and runs serialized regardless — do not describe the sidecar as populated until it is.

**Reflexivity: `runstate.sh` takes effect mid-run, in the run that edits it.** It is the loop's own single writer, so a wrong refusal predicate in T1 breaks the next `heartbeat`, `touch` or `status` write of the very packet that lands it — which is why T1's cases include `set` against all six live keys and a fresh-run-state `claim-driver`, not only the two refusals. `hooks/pause-check.sh` is a hook **body**, live on the next matching tool call in the same run; only registration would need a session boundary, and no task touches `hooks/hooks.json` or any settings file.

**The parent is not re-opened.** `runstate-write-integrity` is derived-done: no checked task line and no capability checkbox of it is edited. Every assertion it authored — including T10's block-scalar cases and T8's no-tools block — must still pass unchanged after every task here.

**The `**P<n>**` label is the highest priority among the capabilities a task covers.** T5's `P0` comes from the sentinel's legacy-bare-reason compatibility criterion, not from capability 3, which is P1; T2's comes from the compatibility and non-vacuous-case capabilities, not from capability 2.

Every regression sweep must pass after every task, and `claude plugin validate .` must stay clean.

## Plan

- [x] **T1** **P0** Make `cmd_set` refuse a key it cannot address at column 0, deciding from the target file's own shape and refusing **before** it creates its temp file, so a refused call leaves the target byte-identical.

  - refuse a key that matches only at an indentation greater than zero — `cursor` under `backlog:` — with a non-zero exit and a message naming the key and pointing the caller at `write`;
  - refuse a column-0 key whose value is a nested mapping or list (matched header, empty remainder, next non-blank line indented) with its **own** message and reason: a mapping header's remainder carries no body boundary, so replacing it strands the children at exit 0 — not the same failure as the nested key above, and not worth conflating in one message;
  - leave both existing branches intact: a key **absent from the file entirely** is still appended at column 0, which is how `claim-driver` creates its four `driver_*` keys against a fresh run-state; and a block-scalar target is still handled by the parent's T10 path, whose remainder is a block indicator, so the mapping rule must not fire on it;
  - cases in `scripts/test-runstate.sh`: each refusal asserting a non-zero exit, a target checksum identical to its pre-call value, no new column-0 key, and the key named in the message; a first `claim-driver` against a fresh run-state inserting all four `driver_*` keys, so the refusal cannot be written as "refuse what is not already there"; and `set` against each of the six live keys still green.
  - deps: —
  - covers: `set` refuses any key it cannot address at column 0, and writes nothing when it refuses · Every hazard has a case in the sweep that owns it — `scripts/test-runstate.sh`, and `scripts/test-pause.sh` for the sentinel — and no case can pass vacuously
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh

- [x] **T2** **P0** Add the shared decoder fixture table and the round-trip contract to `scripts/test-runstate.sh`, asserting today's behaviour only, so T3 and T4 extend one table rather than each writing its own.

  - one fixture list of raw values — plain, `: `, an embedded `'`, a literal newline, a trailing `:`, a leading `-`, a backslash — each paired with its `_yaml_encode_value` output and its expected decode (newlines collapsed);
  - the contract asserted **directly**: decoding what `_yaml_encode_value` produced returns the collapsed original exactly, rather than being inferred from whichever caller happens to exercise it;
  - each of the four read sites driven over the table on the quote shape its own caller produces today, plus a legacy **bare** value that must pass through unchanged: `get`/`cursor` and `findings` on the single-quoted shape, `trim-note`'s first-line unwrap on both shapes, `lanes` on the legacy double-quoted shape;
  - every new parse assertion goes through the sweep's existing `yamlok`, so it reports a counted, loud skip on a parser-less host and cannot pass vacuously; the summary's skip count keeps reporting.
  - deps: —
  - covers: One decoder, mirroring the one encoder, with every read path migrated to it · Existing on-disk state still reads correctly, including files written before the parent feature · Every hazard has a case in the sweep that owns it — `scripts/test-runstate.sh`, and `scripts/test-pause.sh` for the sentinel — and no case can pass vacuously
  - arch: —
  - files: scripts/test-runstate.sh

- [x] **T3** **P1** Make one decode rule canonical in two expressions — the `_yaml_decode_value` shell function and one shared awk function text — and migrate the shell readers and `trim-note`'s inline unwrap to them.

  - extend `_yaml_decode_value` to the legacy double-quoted shape as well as the single-quoted one, still a no-op on a bare value, so `cmd_get` and `cmd_cursor` decode both without a flag day;
  - add the awk expression once, as a shell variable prepended to an awk program (resolved in the preamble: no per-record shell-out inside `trim-note`'s single pass), and replace `cmd_trim_note`'s hand-written unwrap with a call to it, applied **after** its block-indicator check so an already-block note is still skipped;
  - delete the comment in `cmd_trim_note` that asks for the decoders to be kept in step by hand and names only two of the four — it is the thing this capability exists to remove;
  - extend T2's table to the cells that become true, and keep every existing `trim-note` shape case green.
  - deps: T2
  - covers: One decoder, mirroring the one encoder, with every read path migrated to it · Existing on-disk state still reads correctly, including files written before the parent feature · Every hazard has a case in the sweep that owns it — `scripts/test-runstate.sh`, and `scripts/test-pause.sh` for the sentinel — and no case can pass vacuously
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh

- [x] **T4** **P1** Migrate the two remaining awk decoders — `_findings_default`'s summary unwrap and `_list_records`' field unwrap — to T3's shared awk function text, so no read path in the file carries its own copy.

  - `_findings_default` gains the legacy double-quoted shape alongside the single-quoted one `add-finding` writes; `_list_records` gains the single-quoted shape alongside the double-quoted one it strips today, for every field it returns — the widening this capability exists for, not a side effect;
  - extend T2's table so all four sites are asserted over **both** quote shapes and a legacy bare value, each case asserting the decoded result equals the collapsed original exactly rather than merely returning something;
  - add the cross-site assertion that all four sites yield the same decoding for the same input, so the anti-drift property is pinned mechanically rather than by a comment.
  - deps: T3
  - covers: One decoder, mirroring the one encoder, with every read path migrated to it · Existing on-disk state still reads correctly, including files written before the parent feature · Every hazard has a case in the sweep that owns it — `scripts/test-runstate.sh`, and `scripts/test-pause.sh` for the sentinel — and no case can pass vacuously
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh

- [x] **T5** **P0** Route the pause reason through `_yaml_encode_value` in `cmd_request_pause`, decode it on both read paths, and pin it in `scripts/test-pause.sh`.

  - `cmd_pause_status` decodes through the shared decoder and returns the bare reason, unchanged in output shape for every existing caller (`PAUSE=1 reason=<bare>`);
  - `hooks/pause-check.sh` keeps its own grep and gains the same unwrap, so the advisory it injects carries no quote characters — the deliberate third expression the preamble states, pinned by the cases below rather than by a comment, and the hook stays context-only and always exits 0;
  - cases: a reason carrying `: `, an embedded `'` and a newline round-trips bare — newline collapsed, byte-exact — through `pause-status` and appears bare in the hook's advisory; a sentinel whose `reason:` was written **bare** by an earlier version still reads correctly on both paths; no new case emits a `permissionDecision`.
  - deps: T3
  - covers: The pause reason is written through the shared encoder · Existing on-disk state still reads correctly, including files written before the parent feature · Every hazard has a case in the sweep that owns it — `scripts/test-runstate.sh`, and `scripts/test-pause.sh` for the sentinel — and no case can pass vacuously
  - arch: —
  - files: scripts/runstate.sh, hooks/pause-check.sh, scripts/test-pause.sh

- [x] **T6** [P] **P0** Extend the sweep's existing no-tools block — the `NOTOOLS` stubs and the `bare` wrapper — to this feature's new behaviour, demanding it be byte-identical with `jq` and `python3` absent from `PATH`.

  - both `set` refusals (exit code, message text, unchanged target checksum), a decode of each quote shape through `get`, `findings` and `lanes`, and `request-pause`/`pause-status` round-tripping a hostile reason;
  - the scrub wraps **only** the `runstate.sh` invocations, never the sweep's own `have_yaml`/`yamlok`, which would trip the loud skip and fail the run for the wrong reason while telling us nothing about `runstate.sh`.
  - deps: T1, T4, T5
  - covers: Every hazard has a case in the sweep that owns it — `scripts/test-runstate.sh`, and `scripts/test-pause.sh` for the sentinel — and no case can pass vacuously
  - arch: —
  - files: scripts/test-runstate.sh

- [ ] **T7** [P] **P1** Record the two durable decisions in `CLAUDE.md`'s ADR 0027 bullet: that `set` **refuses** a key it cannot address at column 0 rather than learning YAML path addressing, and that one decoder now serves every read path in the file.

  - state why addressing was not built — a large new correctness surface in POSIX shell over the loop's only unrecoverable state, bought to remove a trap a loud refusal closes — so the next reader does not re-derive it, and note that the pause reason now goes through the same encoder;
  - one deliberate edit to the repo's most contended file instead of five tasks each nudging it; beyond capability 1's "and stays so", the record is repo-convention upkeep rather than a PRD criterion.
  - deps: T1, T3, T4, T5
  - covers: `set` refuses any key it cannot address at column 0, and writes nothing when it refuses
  - arch: —
  - files: CLAUDE.md
