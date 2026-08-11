# Changelog

## 2.6.0 — 2026-08-11

Two features: the run-state cleanup (ADR 0024 + ADR 0025) and the write-path
hardening that followed from it. Backward compatible, with **one manual step for
existing repos** (see Upgrading).

### Upgrading — one step, and skipping it is not silent

Add this line to your repo's `.gitignore`:

```
.agents/run-state-prev.yaml
```

`runstate.sh write` now keeps a last-known-good copy of run-state beside it.
Without the ignore line that copy lands **untracked**, and `reconcile` reads
untracked files in `git status --porcelain` as scratch sitting on the green
checkpoint — so it discards the backup, and the pause path's
`git stash --include-untracked` sweeps it. The backup would be destroyed by the
very recovery path it exists to serve, and your tree would read dirty every run.

`/gaffer:migrate detect` reports this as `FINDING=writebackup-ignore`. `apply`
does **not** fix it: this plugin never edits a consumer's `.gitignore`, the same
rule that already applies to the `.agents/pause` entry.

New repos from `/gaffer:new-project` get the line automatically.

### The gspec task checkbox is the completion record (ADR 0025)

- At packet close a gspec-sourced packet's checkbox flips **inside the packet
  commit**, so the work and the record that it happened land atomically instead of
  in a follow-up commit that can be lost or reverted independently.
- Under `--parallel` the **scheduler** flips at green-lane merge, not the lane —
  the task file sits outside every packet's `allowed_files`, so lanes sharing a
  feature would otherwise contend on it.
- `run-loop` preflight reports any `[orch packet:<id>]` trailer naming a still-
  unchecked task. It reports only: a box may be unset because the work was
  reverted, so reconciling is a human decision.
- **`backlog.done` is deleted**, with no counter, tail or replacement. It stored
  exactly what the capability checkboxes derive, and because `write` replaces the
  whole file an agent re-emitted the entire list from memory every packet
  (measured: 95 entries, 16% of a 27,400-byte run-state, no checksum). `pending`
  survives deliberately — it carries the *chosen order*, which is a decision, not
  derivable state.
- Schema stays 3. A run-state still carrying `done:` parses and the field is
  ignored; there is no flag day.

### Findings expire (ADR 0024)

- `add-finding` requires `--packets` and there is no run-wide escape hatch: an
  entry that can never expire is the thing being removed.
- Expiry demands **positive evidence** — the gspec checkbox, or an
  `[orch packet:<id>]` trailer. Absence from `pending` reads as *unknown*, and
  unknown blocks expiry.
- Capture precedes drop, always: filing a backlog task **is** the capture; a spent
  sign-off is not.
- Finding bodies are opt-in (`--body`). Most findings are carried by their summary.
- `/gaffer:migrate` gained a one-entry-at-a-time findings triage. `apply` still
  never deletes a finding.

### The tally's ✅ is this session

Report conventions and both loop shapes now state that ✅ counts what **this
session** landed, from check-ins already rendered, with nothing read from disk.
The "buckets account for the whole backlog" rule applies to the forward buckets
only — a growing backlog is not a fixed set to partition, so *2 landed, 25 to go*
reads honestly.

### `runstate.sh` can no longer corrupt or lose run-state

run-state is the loop's only state that survives a session, and it is gitignored —
so a bad write had no `git restore`. Two paths could destroy it and both had fired
in production.

- **Every value is quoted on write**, with `'` doubled, and every reader strips
  symmetrically. `set` and `add-finding` share one encoder, so hardening one cannot
  leave the other behind — the split that caused the original bug. A value
  containing `: ` used to open a sibling key and break the file.
- There is deliberately **no plain-scalar allowlist**. One was built and removed
  the same day after producing two classes of silent wrongness: values ending in
  `:` wrote an unparseable file with `rc=0`, and `no`/`00`/`0755` parsed cleanly
  but returned `False`/`0`/`493`.
- **`write` validates structurally** — empty, whitespace-only, no `schema:` key, a
  malformed column-0 line — refusing with a nonzero exit and leaving the target
  byte-untouched. The bound is stated in the refusal message: this catches
  truncation and gross malformation, not a well-formed document that is
  semantically wrong.
- **`write` keeps a last-known-good copy**, because the checks cannot see a
  transform that dies *between* lines: `schema: 3` + `status: running` is exactly
  the 26 bytes the live truncation left.
- **`set` no longer strands a block scalar's body.** `trim-note` re-emits `note:`
  as a `|-` block by design, and a subsequent `set … note` used to orphan the body
  and break the parse.
- Run-state files now show `status: 'running'` rather than `status: running`.
  Functionally invisible — nothing greps those values and the readers strip — but
  visible if you read the file directly. Legacy unquoted files read correctly:
  verified across 408 values written by the old writer, 401 byte-identical and the
  7 differences all moving toward what a YAML parser returns.

### The sweeps no longer report green without checking

- `test-runstate.sh` and `test-migrate.sh` guarded their YAML-parse assertions
  behind a parser probe that returned success when PyYAML was absent. On a stock
  host — python3 present, PyYAML is not stdlib — **21 assertions passed while
  checking nothing** and the sweep reported 213/0 green. They now skip **loudly**,
  counted and named in the summary line.
- **CI declares PyYAML** rather than relying on the runner image. If you forked the
  workflow, take this: without it CI can report green while verifying nothing.
- A ~1-in-20 intermittent failure in the `trim-note` assertions is fixed. Piping
  into `grep -q` under `pipefail` races — `grep -q` exits on its first match and
  closes the pipe, the producer takes SIGPIPE, and `pipefail` reports rc 141
  instead of the successful match. Confirmed over 73 consecutive clean runs.
- `scripts/test-runstate.sh` 213 → 390 assertions; `test-migrate.sh` 207 → 208.

### Corrected documentation

- **The relay crossover is 40 packets, not 20.** The change landed in the skills
  on 2026-08-10 but never reached `README.md` or the plugin description, which
  additionally claimed relay was *cheaper* past the crossover — the opposite of the
  measurement that moved the number (relay costs **1.84x** inline per packet).
  Relay is retained rather than deleted because that figure is contaminated by
  busy-wait polling in the coordinator's own context; a clean two-arm A/B is the
  open question, and deleting relay is a legitimate outcome of it.
- `loop-cost-controls` is deferred. Both its P0s fix relay-mode behaviour, and
  relay has never engaged in production.
