# Check-in shapes — what the guided loop PRODUCES (ADR 0003 / 0004)
# -----------------------------------------------------------------------------
# The plugin produces well-formed check-ins at the right moments; it does NOT
# deliver them. Delivery is the frontend's job — Claude Desktop on the MacBook
# (synced to Claude Dispatch on the phone) or direct interaction. Build no
# notification transport here.
#
# There are exactly two shapes. Emit the STATUS UPDATE at every safe checkpoint
# (a packet landing green, a pause). Emit the BLOCKING QUESTION at a hard gate or
# a genuine ambiguity the loop cannot resolve on its own. Keep both short and
# action-oriented — they are read on a phone. Copy a shape and fill it in.

# --- Status update (checkpoint) ----------------------------------------------
# Emitted when a packet lands green, or when the run pauses/completes.

### Check-in — status
- run:     <orch/task-id branch>
- landed:  <packet-id> @ <short-sha>   (build+tests green)
- cursor:  <next packet-id | "backlog complete">
- pending: <N packets>, <M blocking question(s)>
- next:    <one line: "continuing" | "paused — <reason>" | "branch ready for review">

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
