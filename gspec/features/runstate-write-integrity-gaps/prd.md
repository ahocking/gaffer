---
spec-version: v2
depends_on: [runstate-write-integrity]
---

# Feature: runstate-write-integrity-gaps

Three defects on the same surface `runstate-write-integrity` hardened —
`scripts/runstate.sh`, the single writer of the loop's only durable state — that
the parent deliberately scoped out. Every capability the parent shipped spoke to
the **value** a write encodes. These three are about **which key** a write lands
on, and about the **read side** that has to decode what the parent's unified
encoder now produces. All three were found while running the parent feature and
are verified still live in the current script.

Split out rather than appended, on the `metrics-coverage-gaps` precedent: the
parent is derived-done (six of six capabilities, nine of nine tasks checked), so
an unchecked capability added to it would make shipped work read as incomplete
forever and block everything downstream through the dependency rule.

**Defect 1 — `cmd_set` is flat-top-level-only and fails silently on a nested
key.** Two shapes, one cause. `set <file> cursor <pkt>` — the obvious way to
advance the backlog cursor — matches no column-0 `cursor:` line, so the insert
branch (`runstate.sh:466`) appends a **top-level** `cursor:` key. Exit 0, the
file still parses, and `runstate.sh cursor` still reads the *nested* value at
`:212`, so the loop never advances while run-state carries a shadow key. And
`set <file> backlog <x>` against a key holding a nested mapping replaces the
header and strands its children, breaking the parse with exit 0 — the same shape
T10 fixed for block scalars, which T10 does not reach because the matched
header's remainder is *empty* rather than a block indicator (`:457`). No live
caller does either today (`set` is used only for `status`, `note`,
`updated_at`, `last_green_commit`, `branch`, `driver_*`), but both are reachable
by exactly the reasoning that made `set note` reachable: nothing names a command
for the job, so an agent reaches for the obvious one. The cursor shape was hit
live during the 2026-09-15 loop run, which had to route the advance through
`write`.

**Defect 2 — the decode side was never unified.** The parent gave the write side
one `_yaml_encode_value` that both `cmd_set` and `cmd_add_finding` call, so a
future hardening of one cannot leave the other behind. Reads still go through
**four** hand-written decoders that must stay in step by hand: `_yaml_decode_value`
(`:395`, single-quote only), the `trim-note` awk unwrap (`:549`, both styles),
`_findings_default` (`:922`, single only), and `_list_records` (`:1593`, double
only). The comment at `:539` admits they must stay in step and names only two of
the four. Not a live defect — each decoder is correct for the shape its own
caller produces. It matters because it is the exact knowledge duplication the
parent existed to remove, **relocated from the write side to the read side
rather than closed**, and that split is precisely how the original
`set`/`add-finding` divergence was created.

**Defect 3 — the pause sentinel's reason is written unencoded.**
`cmd_request_pause` (`:1369`) writes an agent-supplied reason as a bare scalar,
the same unencoded-value class the parent fixed in `cmd_set`, and now one call
away from the shared encoder. Not a defect today: `pause-status` (`:1390`) and
`hooks/pause-check.sh` (`:59`, `:62`) both read it by grep, neither parses it, so a
colon in the reason cannot break anything. It becomes one the moment the
sentinel gains a parser. This closes a
latent hazard cheaply; it is not a fix for a live break.

## Users & Use Cases

- **An automated driver advancing state mid-run** — writes a status, a note, or a
  cursor between packets, and has no way to tell a silent no-op from a write.
- **A resuming or dispatched session reading state back** — reads values through
  whichever decoder its call path happens to use, and must see the bare value.
- **A human reconstructing after corruption** — the state is gitignored, so their
  only recovery is manual, which is what makes silence the expensive failure.

## Scope

**In**
- `cmd_set` refusing keys it cannot address at column 0.
- One decoder, with all four read call sites migrated to it.
- Routing the pause reason through the shared encoder.
- A regression case for every hazard each change introduces or closes.

**Out**
- Giving the pause sentinel a parser.
- Nested or dotted key addressing in `set`, in any form.
- Changing run-state's schema.
- Anything in `scripts/metrics.sh`.

**Deferred**
- Whether other single-purpose writers that compose values by hand (lane records,
  `pending_questions:`) should route through the shared encoder too.

## Capabilities

- [ ] **P0**: `set` refuses any key it cannot address at column 0, and writes nothing when it refuses
  - a key that resolves **only at an indentation greater than zero** — present in the file, but nested under a parent, as `cursor` is under `backlog` — exits non-zero, names the key and points the caller at `write`, and leaves the file byte-identical, asserted by checksum, since a partial write here is the failure being removed. A key that is **absent from the file entirely** is not that case and is still created at column 0: `claim-driver` creates all four of its `driver_*` keys that way against a fresh run-state, and must keep doing so
  - a key that *is* at column 0 but holds a nested mapping rather than a scalar is refused too, for its own reason rather than the one above: the parent's T10 replaces a block-scalar target safely because a block's body boundary is defined by YAML itself, but a mapping header's remainder is empty and carries no such signal, so replacing it strands the children with exit 0
  - refusal is the fix rather than addressing, and stays so: writing YAML path addressing in POSIX shell — no jq, no parser — against the loop's only durable state is a large new correctness surface bought to remove a trap that a loud refusal closes just as well. This mirrors the parent's own history: a plain-scalar allowlist was built and deleted the same day because it made a claim about every future value; a refusal makes a claim about none
  - the six live keys (`status`, `note`, `updated_at`, `last_green_commit`, `branch`, `driver_*`) keep working unchanged, so no skill, sweep fixture or caller is touched by the refusal

- [ ] **P1**: One decoder, mirroring the one encoder, with every read path migrated to it
  - a single decoding helper handles both the single-quoted shape the encoder writes and the legacy double-quoted shape, and **all four** current decoders call it: `_yaml_decode_value`, the `trim-note` unwrap, `_findings_default`, and `_list_records` — none left as a hand-maintained copy
  - the contract is round-tripping: for any value, decoding what `_yaml_encode_value` produced returns that value, newlines collapsed, exactly, asserted directly rather than inferred from the callers that happen to exercise it
  - the two inline awk sites cannot cheaply shell out per line, so unification there means one implementation kept honest by a shared fixture set rather than by a comment — and the comment at `runstate.sh:539` that asks for it by hand, naming only two of the four, goes away
  - all four read call sites yield the same decoding for the same input, asserted directly for both quote shapes, so the anti-drift property this capability exists for is pinned mechanically rather than by comment

- [ ] **P1**: The pause reason is written through the shared encoder
  - `cmd_request_pause` encodes the reason exactly as `set` and `add-finding` encode theirs, so no write path in the file composes an agent-supplied value by hand
  - `pause-status` returns the bare reason, unchanged in shape for every existing caller and hook that reads it
  - `hooks/pause-check.sh` reads the sentinel directly with its own grep rather than through `pause-status`, and still surfaces the bare reason in its advisory — an encoding decoded only on the `pause-status` path would leave quote characters visible in what that hook prints

- [ ] **P0**: Existing on-disk state still reads correctly, including files written before the parent feature
  - unquoted and legacy-shaped values — anything `write` produced, and anything that round-tripped bare before the encoder existed — pass through whichever decoder is in use unchanged, so no consumer repo has to migrate a run-state before its next run
  - the sentinel's pre-existing bare reasons still read correctly, whether or not the reason is yet written through the shared encoder
  - no flag day: compatibility stays the reader's job, exactly as the parent decided

- [ ] **P0**: Every hazard has a case in the sweep that owns it — `scripts/test-runstate.sh`, and `scripts/test-pause.sh` for the sentinel — and no case can pass vacuously
  - `set` is exercised against a nested-only key (`cursor`) and a nested-mapping key (`backlog`), each asserting a non-zero exit, an unchanged target checksum, and that no top-level key was added — and, on the other side of the rule, a first `claim-driver` against a fresh run-state still inserts its four `driver_*` keys, so the refusal cannot be written as "refuse what is not already there"
  - each read site is exercised on the quote shape its own caller actually produces, plus a legacy bare value and a hostile value carrying `: `, an embedded `'` and a newline, with every case asserting the decoded result equals the collapsed original exactly — not merely that the site returns something
  - every new parse assertion is a real YAML parse and **skips loudly** — visibly reported and counted in the sweep summary — when no parser is present. The parent's capability 5 exists because these assertions silently no-op'd on a host without PyYAML; a case added here that can quietly return success re-opens it
  - the new behaviour is exercised with `jq` and `python3` absent from `PATH`, since `runstate.sh` stays at the same dependency tier as the guard and must keep checkpointing on stock Git Bash

## Dependencies

- `runstate-write-integrity` — supplies `_yaml_encode_value`, the shared write-side
  encoder that capabilities 2 and 3 mirror, and the loud-skip rule capability 5
  inherits. Derived-done; nothing here re-opens it.
- `run-state-cleanup` — owns the findings index shape that `_findings_default`
  decodes. Complete; this feature changes how that field is decoded, never its shape.

## Assumptions & Risks

- Assumption: no caller outside `runstate.sh` addresses a nested key through `set`
  today, so a refusal breaks nothing that currently works.
- Risk: capability 2 touches every read path at once. A decoder regression is
  silent in the same way the defects it closes are silent, which is why the
  round-trip assertion is the contract rather than a convenience.
- Risk: the two inline awk decoders cannot literally share code with the shell
  helper, so "unified" must be enforced by shared fixtures; a comment claiming
  unity is what this feature exists to remove.
- Every agent-supplied value reaching this file is hostile input, and the file it
  writes is gitignored — no corruption here is recoverable by `git restore`.

## Success Metrics

- No write path in `runstate.sh` composes an agent-supplied value by hand, and no
  read path carries its own decoder — countable by inspection, and pinned by the
  same-encoding and same-decoding cases in the sweep.
- `set` returns non-zero for every key it cannot address, with zero silent no-ops:
  the failure mode that cost the 2026-09-15 run a workaround cannot recur quietly.
- The sweep reports how many parse assertions were skipped, so a green run on a
  parser-less host is distinguishable from one that actually parsed.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- Whether the refusal in capability 1 is computed from the target file's shape or
  from a maintained list of keys known to be nested-only. Deferred because both satisfy the
  capability and the choice is a decomposition call, not a scope one.
- Whether the unified decoder is one shell helper plus a shared awk function
  string, or one helper with the awk sites calling out per record. Deferred
  because the per-record cost inside `trim-note`'s single pass needs measuring,
  which this feature does not carry.
