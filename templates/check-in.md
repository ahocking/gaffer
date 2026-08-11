# Check-in shapes — what the guided loop PRODUCES (ADR 0004)
# -----------------------------------------------------------------------------
# The plugin produces well-formed check-ins at the right moments; it does NOT
# deliver them. Delivery is the frontend's job — Claude Desktop on the MacBook
# (synced to Claude Dispatch on the phone) or direct interaction. Build no
# notification transport here.
#
# There are exactly two shapes. Emit the STATUS UPDATE at every safe checkpoint
# (a packet landing green, a pause). Emit the BLOCKING QUESTION at a hard gate or
# a genuine ambiguity the loop cannot resolve on its own. Keep both short and
# action-oriented. Copy a shape and fill it in.
#
# THIS IS THE AGENT-TO-AGENT WIRE FORMAT, not what the human reads. A lane or a
# dispatched Chief Engineer returns this shape to the scheduler, which parses it and
# records run-state from it — so keep it machine-shaped and keep the keys stable.
# Whoever holds the main context window renders it into the human-facing shapes in
# `report-templates.md` before it reaches the human; that rendering is a pure transform
# of the text below, never a reason to go back to the repo.

# --- Status update (checkpoint) ----------------------------------------------
# Emitted when a packet lands green, or when the run pauses/completes.

### Check-in — status
- run:     <orch/task-id branch>
- landed:  <packet-id> @ <short-sha>   (build+tests green)
- cursor:  <next packet-id | "backlog complete">
- pending: <N packets>, <M blocking question(s)>
- next:    <one line: "continuing" | "paused — <reason>" | "branch ready for review">
- Findings:                            # omit the key entirely when there are none
  - packets: <id[,id...]> — <one line: a gotcha, a constraint, or a decision AND why>
- stale-findings: <N>                  # omit unless the index exceeds ORCH_FINDINGS_INDEX_MAX_BYTES

# `Findings:` is how a PARALLEL LANE reports something worth keeping past its packet.
# A lane must not call `runstate.sh add-finding` itself — it has no run-state in its
# worktree and it is not run-state's writer (ADR 0022 / ADR 0016) — so it states the
# line here and the scheduler records it on collection, and each line MUST carry the
# packet id(s) it scopes to (`add-finding --packets` is now mandatory — ADR 0024 —
# and there is no run-wide finding, so the scheduler has nothing to pass without it).
# In sequential mode the loop records findings directly and this key is usually
# unnecessary.
#
# What does NOT go here: "this should be built/fixed". That is backlog — a gspec
# task/feature ordered via .agents/roadmap.yaml (the ADR 0020 seam). A findings list
# holding future work is a shadow backlog competing with gspec.
#
# `stale-findings:` is a one-line count — a backstop for the days discipline slipped
# (ADR 0024), not a field the happy path fills in. Emit it when, and only when,
# `runstate.sh findings --stale` reports `OVER_THRESHOLD=yes`; `<N>` is that run's
# `STALE_COUNT`, which may legitimately be 0 (a large index of still-live findings).
# Its absence therefore means "index under threshold", NOT "checked and found zero".

# --- Blocking question (hard gate / ambiguity) -------------------------------
# Emitted when the loop cannot proceed without a human decision. `severity`:
#   blocking = the loop cannot continue on this packet until answered;
#   high     = other packets can proceed, but this needs an answer soon;
#   normal   = informational / can wait.

### Check-in — question  [severity: <blocking | high | normal>]
- run:      <orch/task-id branch>
- packet:   <packet-id>
- gate:     <hard gate crossed | ambiguity | conflicting spec>
- question: <what you need decided, in one or two sentences>
- state:    <paused at <short-sha> | continuing on other packets>
