# ADR 0011 — Guard config-root discovery: decouple config roots from the shell cwd, merge restrictively

- Status: Accepted
- Date: 2026-07-16
- Deciders: user (tech lead), orchestration plugin
- Amends: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md) and, by
  inheritance, [ADR 0006](0006-full-autonomy-branch-integration.md). ADR 0004
  states the autonomy resolution order as env `ORCH_AUTONOMY` → `<repo>/.agents/autonomy`
  → default. That order still holds, but it was silently wrong about **which
  repo** — see Context — and this ADR adds new semantics a reader of 0004 would
  not predict: when more than one `.agents/` root is discovered, the **lowest**
  declared level wins. The autonomy levels, the hard/soft gate split, and the
  git soft gates themselves are unchanged.
- Repairs a premise of [ADR 0008](0008-guard-three-tier-enforcement.md), which
  asserts that per-repo `.agents/guard-extra-*` makes declared per-project risk
  "an enforced hard floor, not a prompt." That guarantee was conditional on the
  shell cwd and silently false otherwise. The three-tier model itself is unchanged.

## Context

`hooks/guard.sh` resolved every per-repo config file beneath a single variable
(`:248-249`):

```bash
PROJECT_DIR="$(json_field "$INPUT" cwd)"
[ -z "${PROJECT_DIR:-}" ] && PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
```

The payload `cwd` won; `CLAUDE_PROJECT_DIR` was only a fallback for an empty
`cwd`. Everything per-repo hung off it: `.agents/autonomy` (`:286`),
`.agents/guard-extra-bash` (`:251`), `.agents/guard-extra-paths` (`:258`), and
`.agents/project-overrides.yaml` (`:272`).

An agent's shell cwd is routinely a **subdirectory** of the consumer repo — a
package cache, a submodule, `src/`. The reported trigger was a subagent that
`cd`'d into `Library/PackageCache/...` to read package source. From any such cwd,
**none** of that config is found, and the two halves fail in opposite directions:

- **Autonomy fails CLOSED.** No `.agents/autonomy` → fall back to
  `ORCH_AUTONOMY_DEFAULT="interactive"`. A routine commit was refused with
  `autonomy=interactive (needs >= supervised)` while the repo's file read
  `full-autonomy`. Confusing, but safe.
- **`guard-extra-*` fails OPEN.** The files are simply not loaded, and the repo's
  declared per-project hard-gates stop being enforced — silently, with no signal.
  This is the real defect.

### Scope of the exposure

The **danger floor was never affected.** The built-in `DENY_BASH_PATTERNS`
(history destruction, `rm -rf`, raw-device writes) and the built-in
`SENSITIVE_PATH_PATTERNS` (auth, secrets, CI/deploy) do not reference
`PROJECT_DIR` and held throughout, at every autonomy level, from every cwd. The
git soft gates also held. Only per-repo **additions** — the patterns a consumer
declares to extend the defaults — vanished. This is a hole in the
declared-risk-becomes-enforced-risk mechanism of ADR 0008, not a general failure
of the guard, and should not be read as one.

### The reframe: one variable doing two unrelated jobs

The fix is not a precedence correction. `PROJECT_DIR` conflated two independent
concerns, and the comment above `resolve_git_dir` (`:583`) already named the
distinction the code failed to make:

- **Where the command RUNS** — the payload `cwd`. This is the correct base for
  the git soft gates, and it **must stay cwd-anchored**. `resolve_git_dir` exists
  precisely because a command can target another tree via `cd <dir> &&` or git's
  global `git -C <dir>`; judging such a command against the wrong tree lets a
  commit into a *different* checkout dodge the branch gate.
- **Where the RULES live** — the `.agents/` root. Almost never the cwd.

Because `GIT_CWD="$PROJECT_DIR"` (`:593`), and relative `cd` resolves against
`${PROJECT_DIR}/...` (`:601`), **any fix that "corrects" `PROJECT_DIR` also
silently moves the tree the git gates evaluate.** That is what makes the obvious
fixes unsafe — not their surface-level risks.

### Both obvious candidates were empirically disproved

This section is the most load-bearing part of this ADR: it exists to stop a
future reader from "simplifying" the design back into the bug.

**Candidate A — `git -C "$cwd" rev-parse --show-toplevel` to normalize cwd up to
the repo root.** Rejected on two independent grounds:

1. **Redundant.** The toplevel is *always* an ancestor of the cwd, so an upward
   walk from the cwd subsumes it entirely. It contributes no candidate the walk
   would miss.
2. **Wrong.** It stops at the boundary of a **nested** checkout — a submodule, a
   vendored clone, or a package cache that is itself a git repo — and answers
   with that repo's root, not the project's. It then drags `GIT_CWD` along with
   it. It also fails outright in a git-free consumer repo.

**Candidate B — prefer `CLAUDE_PROJECT_DIR` over the payload `cwd` (invert the
precedence).** Rejected because it **opens a `main`-commit bypass**. Patching a
copy of the guard to implement B literally and running a nested checkout on
`main`, inside an outer project on `feature` at `full-autonomy`:

```
cwd     = <outer>/vendor/lib   (a nested repo, on main)
command = git commit -m x      → the shell commits to the NESTED repo's main

  today   (payload cwd wins)        : exit 2   (denies — but for the wrong reason:
                                                autonomy misread as interactive)
  naive B (CLAUDE_PROJECT_DIR wins) : exit 0   ← ALLOWS a commit onto main
```

B moves `PROJECT_DIR` to the outer project, `GIT_CWD` follows it, the gate reads
the *outer* branch (`feature`), and the commit onto the nested repo's `main` is
allowed. The pre-existing bug was masking this; "fixing" `PROJECT_DIR` in place
unmasks it. B's stated risk (is `CLAUDE_PROJECT_DIR` reliably set?) is real but
secondary — the bypass is disqualifying on its own.

Both candidates fail for the same underlying reason: they treat `PROJECT_DIR` as
one thing.

## Decision

**Split the variable, discover the roots, and merge them restrictively.**

### 1. Decouple execution from configuration

`SHELL_CWD` is the payload `cwd`, with the identical fallback chain
(`${CLAUDE_PROJECT_DIR:-$PWD}`) the old `PROJECT_DIR` had. It feeds `GIT_CWD` and
`resolve_git_dir` and nothing else. **The git soft gates are bit-for-bit
unchanged** — the tree a command *targets* and the project whose rules *bind* it
are now independent, as they always should have been.

### 2. Discover config roots by a bounded upward walk

`CONFIG_ROOTS` collects every ancestor of `$CLAUDE_PROJECT_DIR` and of
`SHELL_CWD` that declares a `.agents/` directory, deduplicated by canonical path.
The walk — not `rev-parse` — is the mechanism: it works in a git-free repo, and it
does **not** halt at a nested checkout's boundary, so it finds the real project
from inside a submodule or package cache. It is bounded by `$HOME` and `/`, and
by a depth cap, so a stray dotfile above the workspace can never be picked up.

### 3. Merge restrictively — never pick a winner

When more than one root is discovered, they are combined, not adjudicated:

- **`guard-extra-*` → UNION.** Patterns are only ever *added*.
- **`autonomy` → lowest vote wins.** Every discovered root votes; a root that
  declares a `.agents/` but no autonomy file — or an unparseable one — votes the
  default (`interactive`), exactly as before.
- **`autonomy_ceiling` → clamp to the lowest** ceiling any root declares.

Env `ORCH_AUTONOMY` still takes precedence over the files, and is still clamped by
the lowest ceiling.

### The durable invariant

> **Config resolution is monotonically restrictive over discovered roots.**

Adding a root can only add deny patterns or lower the autonomy level; it can never
remove a pattern or raise the level. This is what makes the safety requirement —
*resolution must never load a config less restrictive than the real project's* —
true **by construction rather than by argument**. It does not depend on
correctly identifying which root is the "real" project: as long as the real
project is *among* the candidates (it always is, whenever it is an ancestor of the
cwd or is `CLAUDE_PROJECT_DIR`), the resolved level is bounded above by what that
project declares, and the resolved patterns are a superset of the ones it
declares. Ambiguity fails closed for free.

Any future change to this block must preserve that invariant. A design that
*selects* a root — which is what A and B both do — cannot.

### Verification

Validated before adoption, on a patched copy:

- All three reported symptoms fixed from a subdirectory cwd (autonomy allows;
  both `guard-extra` tiers enforce again).
- The nested-repo `main`-commit case still denies (`exit 2`) — the decoupling
  holds.
- A foreign `CLAUDE_PROJECT_DIR` declaring `full-autonomy` cannot raise a cwd
  project that declares `interactive`.
- A nested `.agents/autonomy=interactive` lowers an outer `full-autonomy`.
- **The entire pre-existing regression suite passes 109/109, identical to
  baseline** — zero regressions.

New cases in `scripts/test-guard.sh` pin the subdirectory-cwd case for both the
fail-closed autonomy symptom and the fail-open `guard-extra` hole, the
nested-repo decoupling case, and the restrictive-merge cases.

## Consequences

- **Declared per-project risk is enforced from any cwd.** ADR 0008's
  "declared risk → enforced risk" guarantee is now unconditional, which is what it
  always claimed to be.
- **The autonomy level matches the file the human wrote**, from any cwd. The
  reported symptom — a routine commit refused as `interactive` while
  `.agents/autonomy` read `full-autonomy` — is gone.
- **ADR 0004's stated resolution order needs a footnote, and `README.md:115`
  needs a correction.** The README states the same
  `env → .agents/autonomy → default` order and is now incomplete: it does not say
  *which* `.agents/` is consulted, nor that multiple roots resolve to the lowest.
  Flagged here deliberately; the README edit is out of scope for this ADR and
  should be picked up separately.
- **One intentional behavior change, accepted by the human.** A cross-repo commit
  — `CLAUDE_PROJECT_DIR` = repo A (`interactive`), cwd = repo B
  (`full-autonomy`), command commits in B — now **denies** where today it allows.
  Both roots are discovered, and the lowest vote wins. This is a deliberate,
  human-approved consequence of the restrictive-merge rule, **not a bugfix side
  effect**: when two projects' rules could both plausibly bind an action, the
  stricter one should win. It is strictly more restrictive than today, so it
  cannot mask a gate.
- **A repo directly under `$HOME` inherits nothing.** The walk stops before
  `$HOME`, so `~/project` gets no config from above it. This is the deliberate
  bound that prevents a stray `~/.agents` from silently governing every repo. A
  repo that wants shared config puts it at its own root.
- **Cost: roughly 20 extra subshells per hook invocation** (the walk's `cd`/`pwd -P`
  and dedup). Negligible against the `jq`/`python3` processes the hook already
  spawns per call.
- **A pre-existing test-hermeticity leak was found, and it fails permissively.**
  `scripts/test-guard.sh` unsets `ORCH_AUTONOMY` for hermeticity but not
  `CLAUDE_PROJECT_DIR`, and its three no-`cwd` cases fall back to ambient `$PWD`.
  Run from inside a consumer repo the suite scores 106/3 on **unmodified**
  `guard.sh` — the three `git commit` cases are **allowed** because they inherit
  that repo's `full-autonomy`. From a neutral cwd it is 109/109. The failure mode
  is permissive, which is the dangerous direction for a safety suite: it can
  report green while judging the wrong config. Fixed alongside this change by
  unsetting `CLAUDE_PROJECT_DIR` and pinning `$PWD` to a scratch dir.
- **Residual risk:** the walk trusts the filesystem. A `.agents/` directory
  planted anywhere between the cwd and `$HOME` will be discovered and merged. By
  the invariant it can only *tighten* the guard — the worst case is a denial-of-
  service via spurious deny patterns or a floor pinned at `interactive`, both
  loud and diagnosable, never a weakened gate.
