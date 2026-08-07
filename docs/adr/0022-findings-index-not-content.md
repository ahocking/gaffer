# ADR 0022 — Findings live outside run-state; run-state keeps only the index

- Status: Accepted
- Date: 2026-08-07
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0005](0005-crash-safe-resume.md) (run-state is the durable memory),
  [ADR 0012](0012-delegated-loop-driver.md) (what a relayed coordinator actually needs),
  [ADR 0019](0019-run-metrics-observability.md) v3.4 (`trim-note`, and the measurement
  that made the cost visible), [ADR 0020](0020-gspec-boundary-and-version-pin.md)
  (the gspec seam this routing decision rests on).

## Context

Pausing a run, or ending one, produces information that belongs to nothing else in the
repo: a gotcha that cost an hour, a constraint discovered the hard way, a question the
human answered and the reasoning behind it. It is not an ADR (not an architectural
decision), not a PRD, and not code. The loop needs it to survive into the next session.

There was exactly one place guaranteed to be read, so it went there. Two real fields
show what that produced:

| Field | Size | In the schema? |
|---|---|---|
| `note` | **164,678 chars** (~41k tokens), 15 stacked "earlier history" sections | Yes — documented as **one line** |
| `resolved_questions` | 21,664 chars (~5.4k tokens) | **No.** Not in `templates/run-state.yaml`, not in `runstate.sh` |

The second is the important one. `resolved_questions` was **invented by the agent**
because the schema offered nowhere to put it. This is not an agent being sloppy — it is
a design gap being routed around, and it will recur under any amount of prompt
discipline as long as run-state is the only durable, guaranteed-read file.

**Why it costs more than "a big file."** Run-state is read at dispatch start, so it sits
in the coordinator's standing context for the entire dispatch — and that context is
re-written to cache repeatedly. Measured on one real dispatch (ADR 0019 v3.4
`cc_shape`): **32 cache writes above 50k in a single dispatch**, the coordinator being
the only role with any (architect, implementer, reviewer, researcher and doc-writer all
sit at 19k–36k `max` with **zero**). So a 46.8k-token run-state is not paid once per
packet; it is paid on every one of those re-caches, in every packet, for information
that usually concerns one.

## Decision

**Run-state carries a one-line index. The body lives in `.agents/findings/<id>.md`.**

```yaml
findings:
  - id: f-001
    summary: <one line, specific enough to decide on without opening the body>
    file: .agents/findings/f-001.md
    packets: [feature-002-scope]      # optional
```

### Index hot, body cold — not "links instead of content"

The tempting version is to move the content out and link it. That trades an expensive
failure for a worse one: content nobody reads. A gotcha exists *precisely* to prevent
rework, so a link that is never followed costs more than the tokens it saved.

The summary is therefore load-bearing, and it has one job: let an agent decide whether
it needs the body **without opening it**. Both instincts are wrong on their own, and
the prompts say so explicitly — reading every body rebuilds the 41k-token run-state in
a different file; skipping the index causes the rework the finding existed to prevent.
The index is cheap and mandatory; bodies are not free and are conditional.

Rough shape: **46.8k → ~5k** (control state + pending questions + a 15-line index).
Against a coordinator `cc_shape.max` of 198,397 that is ~21% of the re-cached payload.

### Two destinations, and merging them would build a shadow backlog

Routing comes from the ADR 0020 seam — **gspec owns what to build and in what order;
this plugin owns how a unit of work is safely executed**:

| What you have | Where it goes |
|---|---|
| "this should be built/fixed" | **Backlog.** A gspec task/feature, sequenced via `.agents/roadmap.yaml`. **Not a finding.** |
| a gotcha, a constraint, a decision **and its rationale**, a resolved question | **A finding.** Execution context, plugin-owned. |
| "where we stopped", one sentence | `note:` |

A findings file holding future work is a second backlog competing with gspec — exactly
what ADR 0020 exists to prevent. Resolved questions are findings (a decision plus its
rationale), which is why no `resolved_questions:` field is being added: the field that
appeared in the wild was the symptom, not the requirement.

### Mechanism, because appending to a YAML list is where agents corrupt state

`runstate.sh add-finding <file> <id> <summary>` appends the index entry and creates the
body stub; `runstate.sh findings <file>` prints the index and nothing else. Judgment
(what is a finding, which bodies to open) stays in the prompts — the standard split.

Three details are load-bearing:

- **Insertion is immediately after the `findings:` key**, making entries newest-first.
  This is the only placement that cannot land in the wrong section: locating the end of
  a YAML list means guessing where the block stops, and guessing wrong writes the entry
  into `note:` or `pending_questions:`. Newest-first is also the right order for an
  index that is scanned rather than paged.
- **Ids are constrained to `[a-zA-Z0-9._-]`** because an id becomes a filename; `../`
  is rejected outright.
- **Newlines in a summary are collapsed, not rejected.** A raw newline would break the
  single-line scalar and could inject a sibling top-level key. The caller is an agent
  mid-loop, so degrade rather than fail.

`trim-note` (ADR 0019 v3.4) remains, demoted to a **backstop** for when discipline
slips. Findings are the intended path; a byte budget is what catches the days they are
not used.

### The summary is untrusted text (revision, 2026-08-07)

The first cut wrote the summary as a **plain, unquoted** YAML scalar. A summary is
free text written by an agent about code, so the single most likely thing in it is
`": "` — which a plain scalar cannot hold: it parses as a nested mapping and the file
stops loading. The function whose stated purpose was "appending to a YAML list is the
one edit that reliably produces malformed run-state" was itself the way to produce it.

**Summaries are now single-quoted, with `'` doubled.** Single- and not double-quoted
because a single-quoted YAML scalar performs *no* escape processing: `'' → '` is the
entire rule, and a backslash is already literal, so a Windows path needs nothing.
Double-quoting would need `\` and `"` escaped and would then re-interpret `\n`.

That choice also keeps `jq` out of it. Encoding is one `sed` substitution in any POSIX
shell, so `add-finding` still works on stock Git Bash, which ships neither `jq` nor a
real `python3` — the constraint `guard.sh` is already built around. Requiring `jq` here
would have narrowed a guarantee the plugin makes elsewhere, to buy nothing.

Two smaller defects in the same function, same revision. The value was interpolated
via **`awk -v`, which expands backslash escapes in the value** — so a literal `\n` in a
summary became a real newline *after* the collapse above had run, reopening the exact
injection that collapse exists to close. It now passes through `ENVIRON`, which does
not. And the **duplicate-id check scanned the whole file with a regex**: schema 3
carries `packets:` entries in the same `  - id: <x>` shape, so a finding named after
the packet it concerns — the natural name — was silently refused; and `.` is both a
legal id character and a live metacharacter, so `f.001` collided with `f-001`. The
check is now scoped to the findings block and matched literally.

The lesson generalizes past this function: **run-state's writers must treat every value
an agent supplies as hostile input**, because run-state is the only state that survives
a session and a parse failure is unrecoverable. `test-runstate.sh` now asserts a real
YAML **parse** after each mutating subcommand rather than grepping for a substring;
grep is what let all of this through.

### Where finding bodies live: gitignored, with run-state (revision, 2026-08-07)

`.agents/findings/` is **gitignored**, in both the plugin's `.gitignore` and
`templates/spec-driven-base/.gitignore`, alongside `.agents/run-state.yaml` — as is
`run-state-note-archive.md`. This amends nothing in ADR 0009; it applies it. Two
reasons, and the second is the one that forced the decision:

1. **Consistency.** The index is inside gitignored run-state. Tracking the bodies while
   the index is local produces a checkout with orphan bodies and no index — the "durable
   and reviewable" property below delivered backwards.
2. **They are only durable if ignored.** Untracked is not the same as ignored here.
   `/gaffer:pause` sets scratch aside with `git stash --include-untracked`, and
   `runstate.sh reconcile` reads `git status --porcelain` — which lists untracked files
   — as "scratch sitting on top of the green checkpoint", and discards it. An untracked
   finding is therefore destroyed by the pause path, which is the ADR's own headline use
   case. An **ignored** file is invisible to both, exactly like `run-state.yaml`.

The cost is that findings are **same-machine**, like run-state (ADR 0009's existing
trade-off). A finding worth sharing across machines is not a finding; it is an ADR or a
gspec item, and the routing table above already sends it there.

One consequence that is easy to miss: `runstate.sh write` **replaces** the whole file
while `add-finding` **appends** to it. So the loop must carry the `findings:` index
through every whole-file write, and must record findings *after* that write, not
before. Dropping an index line does not remove a finding — it unlinks a body that is
still on disk. Both loop skills state the ordering explicitly.

### A parallel lane reports findings; it does not record them (revision, 2026-08-07)

Under ADR 0016 the scheduler is run-state's single writer and lanes are stateless
workers. `add-finding` mutates run-state, so a lane must not call it: its worktree has
no `.agents/run-state.yaml` to append to, and two lanes appending at once is exactly the
contention the single-writer rule exists to prevent.

A lane therefore returns findings **in its check-in**, under a `Findings:` key, and the
scheduler records them on collection — prefixing ids with the lane's task-id so two
lanes cannot collide. This is the same conclusion `record-outcome` reached from the
other direction: that command *is* lane-callable precisely because it writes append-only
to `.agents/metrics/outcomes/` and never touches run-state. Two mechanisms, one rule —
**nothing but the scheduler writes run-state.**

The alternative was to give `add-finding` the `git rev-parse --git-common-dir`
resolution `record-outcome` uses, letting a lane write through to the main checkout.
Rejected: it would make concurrent lanes contend on the one file whose corruption is
unrecoverable, to save relaying one line through a check-in the scheduler already reads.

## Consequences

- **A relayed coordinator stops paying for other packets' history.** The saving is
  per-re-cache, not per-read, so it is larger than the raw token difference suggests.
- **`.agents/findings/` is durable and reviewable** — a human can read one finding
  without paging through a run's whole narrative, and it survives the run. "Durable"
  means *gitignored local bookkeeping that the pause path cannot sweep*, not *committed*
  — see the revision above; the bodies are same-machine, like run-state itself.
- **The discipline is the fragile part**, and it is prompt-enforced, not mechanical.
  Nothing stops an agent from pasting bodies into a brief. `cc_shape.max` is the
  detector: if it does not fall, the rule is not being followed.
- **The index can rot.** A vague summary makes agents either over-read or miss the
  finding. Summary quality is a real maintenance burden with no mechanical check.
- **Not yet measured.** This rests on the mechanism plus measured payload sizes, not on
  a before/after. `cc_shape` is what will confirm or refute it on the next real run —
  which is the point of having landed the metric first.

## Alternatives considered

- **Leave it in run-state and rely on `trim-note`.** A byte budget cuts by position,
  not relevance, and can truncate mid-narrative. It also does nothing about
  agent-invented fields like `resolved_questions`, which is where the gap actually
  showed itself.
- **Put findings in ADRs.** Most findings are not architectural decisions, and an ADR
  per gotcha would destroy the signal in `docs/adr/`.
- **Put findings in gspec.** Correct for "this should be built" and wrong for
  everything else; gspec's `spec-integrity` floor governs every `.md` under `gspec/`
  and would flag files it does not own (the same reason `.agents/roadmap.yaml` lives
  outside `gspec/` — ADR 0020 D2).
- **Add a schema'd `resolved_questions:` list.** Reproduces the original problem with
  a nicer name: still unbounded, still in the file every packet reads.
