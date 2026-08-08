---
name: build-packet-dependency-tree
description: Analyze the gspec backlog and build the packet dependency graph the parallel loop runs from — nodes (packets) with ordering edges (task + feature deps) and mutual-exclusion edges (allowed_files overlap), grouped into parallel waves. Runs for one feature or, with no argument, the entire unimplemented featureset. Prerequisite for /gaffer:run-loop --parallel.
argument-hint: (optional — a feature slug; omit to analyze the whole unimplemented featureset)
---

# Build the packet dependency tree $ARGUMENTS

Produce `.agents/packet-graph.yaml` — the dependency DAG that
`/gaffer:run-loop --parallel` schedules against (ADR 0016). The graph
answers two questions for every packet: **what must finish before it** (ordering)
and **what it can never run beside** (a shared file where a parallel merge would
collide). The deterministic graph MATH lives in
`${CLAUDE_PLUGIN_ROOT}/scripts/packet-graph.sh`; your job here is to gather honest
NODES for it and to record the result.

This is **read-mostly**: you read the backlog through the adapter and write only
the graph artifact. Do not touch code, and do not write to `gspec/` — it is
gspec's to own (ADR 0020 D1).

## 0. Resolve scope

- **A feature slug in `$ARGUMENTS`** → analyze that feature's packets, plus enough
  of its dependencies to place its edges.
- **No argument** → the **entire unimplemented featureset**: every incomplete,
  unblocked feature the adapter reports. This is the default for a whole-repo
  parallel run.

State in one line which scope you chose and how many features it covers.

## 1. Gather the nodes

**The adapter produces the nodes — you do not hand-write them** (ADR 0020 D2):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh nodes-all > nodes.tsv     # whole featureset
${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh nodes <slug> > nodes.tsv  # one feature
```

It emits exactly the TSV `packet-graph.sh build` documents, one line per
**unchecked** gspec task:

```
<id>\t<feature>\t<allowed_files>\t<consumes>\t<produces>\t<feature_depends_on>
```

- **`id`** is `<feature>-t<n>` from the gspec task ID — stable, because gspec never
  renumbers a task (its `task-immutability` floor enforces that).
- **Ordering** comes from gspec's `deps:`, encoded as `produces: <feature>#T<n>` /
  `consumes: <feature>#T<d>`. A dep on an already-**checked** task finds no
  producer and correctly yields no edge — done work must not block anything.
- **`feature_depends_on`** comes from the PRD's `depends_on` frontmatter when
  present (upstream proposal U5), else `.agents/roadmap.yaml`.

**`allowed_files` is the one field the adapter usually cannot fill.** gspec task
lines carry no file scope, so unless an (upstream-proposal-U1) `files:` line is
present the field is **empty** — and `packet-graph.sh` treats empty scope as
"overlaps everything" and serializes that packet conservatively.

**Your judgment goes here, and only here — and it is recorded, not retyped.** Where
you can scope a packet's files honestly — from a built task-packet's `allowed_files`
(`${CLAUDE_PLUGIN_ROOT}/templates/task-packet.yaml`), from the task text narrowed to
the feature's `allowed_paths` in `.agents/project-overrides.yaml`, or from
`gspec/architecture.md`'s Project Structure — write it into
**`.agents/task-files.yaml`** so the adapter picks it up on every future run:

```yaml
schema: 1
tasks:
  - task: <feature>#T<n>
    files: [src/api/**, db/migrations/**]
    fingerprint: <the task's description text, verbatim>
```

**The `fingerprint` is required.** gspec preserves task IDs on regenerate but
re-decomposes *unchecked* work, so `T5` can keep its id while its text becomes
different work — and a stale entry would then hand two colliding lanes a narrow
scope. An entry whose fingerprint no longer matches is **ignored** (the packet falls
back to serializing) and reported by:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh files-status
```

**If you cannot scope a packet honestly, leave it out.** Never guess a *narrow*
scope: that is how two lanes collide on an unlisted shared file. Wrong-wide (or
empty) only costs parallelism, never correctness.

## 2. Build the graph

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/packet-graph.sh build <nodes.tsv> > .agents/packet-graph.yaml
```

`build` computes the interface edges, the feature edges, the `allowed_files`
overlap (mutual-exclusion) edges, and the topological **waves**. If it exits
non-zero it found a **dependency cycle** and named the packets in it — do not
write a partial graph; **stop and surface the cycle** (a cycle means two packets
each wait on the other, which is a spec problem for the human/architect to break).

## 3. Validate

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/packet-graph.sh validate .agents/packet-graph.yaml
```

Also run `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh files-status` and resolve
any `stale` or `unfingerprinted` entries — each one is a packet silently losing its
parallelism.

Confirm `VALIDATE=ok`. Note the `conservatively_serialized` count — those are
packets whose file scope you could not resolve; they will run one-at-a-time. If
that number is high and it matters, go back and scope those packets (build their
task-packets) rather than leaving parallelism on the table.

## 4. Record the result

The graph is now at `.agents/packet-graph.yaml` — committed, durable,
human-reviewable, and **regenerable, so never hand-edit it**.

**Do not write feature-level parallelism back anywhere.** Waves are *computed*, and
caching a computed result in a hand-maintained file is how the two disagree the
moment the graph is regenerated (ADR 0020 D2 — this is why `parallel_group` was
removed from the roadmap). `.agents/roadmap.yaml` carries planning preference
(`order`, `why`) only; the graph carries concurrency. If the graph disagrees with
what a human expected, that is a finding to report — not a file to reconcile.

## 5. Summarize

Report, in a few lines: scope (features covered), packet count, wave count, the
`max_wave_size` (the useful concurrency before the `max_parallel` cap), and the
count of conservatively-serialized packets. End with the single next action —
usually: *"run `/gaffer:run-loop --parallel` to execute it"* (at
`full-autonomy` it will also integrate lanes; below that it stops at
branches-ready). See ADR 0016.

**Use the kickoff shape** (`${CLAUDE_PLUGIN_ROOT}/templates/human-report.md`, shape
C) — this output *is* a plan, and the human reads it to decide whether to run it. So
name each wave by what it builds, not by its index, and give every packet a
plain-English title; `wbr-t14` and `max_wave_size: 4` are graph facts, and a graph
the human cannot check is one they approve on trust. **A conservatively-serialized
packet is worth a line of its own** — it means the file-scope sidecar could not
vouch for that packet, so it costs concurrency, and that is a thing the human can
actually fix (`gspec-backlog.sh files-status`).
