# ADR 0018 — Rate-limit-aware cooperative pause (status line as the usage-limit sensor)

- Status: Accepted
- Date: 2026-07-20
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md) (pausable loop),
  [ADR 0005](0005-crash-safe-resume.md) (crash reconcile / write-ahead trailer),
  [ADR 0016](0016-parallel-worktree-lanes.md) (parallel worktree lanes),
  [ADR 0017](0017-graceful-cooperative-pause.md) (cooperative pause sentinel + advisory hook).
- **Amends [ADR 0017](0017-graceful-cooperative-pause.md).** ADR 0017 built a
  cooperative pause that some *actor* (human, frontend, driver) requests by writing a
  sentinel. This adds one more actor — an automatic writer driven by the Claude Code
  **rolling usage limits (the 5-hour AND the 7-day windows)** — so a long unattended run
  pauses itself just before the account hits either wall, instead of a lane dying
  mid-packet when the server cuts it off. It reuses **all** of 0017's machinery
  unchanged; it invents no new pause path.

## Context

An unattended `run-loop` — especially a wide `--parallel` run (ADR 0016) burning
several lanes at once — can exhaust the account's **rolling usage limits** mid-flight.
Claude Code enforces two such windows: a fast-moving **5-hour** limit and a
slower-moving, more consequential **7-day (weekly)** limit. When *either* trips, the
harness stops serving API responses **server-side**. A lane blocked on that cutoff is
exactly the failure ADR 0017's
cooperative pause exists to avoid: work stranded on a **mid-edit tree**, not on a green
commit, with the dispatched subagent's conversation context unrecoverable by design
(run-state + git are the only durable memory, ADR 0009). The reconcile table then
`restart`s that lane and one packet's uncommitted work is lost. We would much rather
**see the limit coming and drain to a green checkpoint before it lands.**

The obstacle is *sensing* the limit. Three verified facts about current Claude Code
behavior constrain the whole design:

1. **The rolling-usage percentages are delivered to exactly ONE place: the status-line
   command's stdin JSON.** After the first API response of a session, the harness
   invokes the configured status-line command with a session JSON payload that includes
   **both windows**:
   ```json
   "rate_limits": {
     "five_hour": { "used_percentage": 0-100, "resets_at": <unix_epoch> },
     "seven_day": { "used_percentage": 0-100, "resets_at": <unix_epoch> }
   }
   ```
   It appears **only after the first API response** in a session; **only for Claude.ai
   Pro/Max** subscribers (absent under API-key / Console auth); and it **updates only
   once per API response**. Each field — including each window independently — can be
   **absent**, so every read must be guarded (`// empty`).

2. **No hook event payload carries rate-limit data, and Claude Code persists no
   usage/rate-limit file to disk.** A PreToolUse / PostToolUse / SessionStart hook
   therefore *cannot* sense the limit on its own, and `ccusage` / transcript logs do
   **not** contain the rolling-limit number. The status line is the **sole** source.

3. **The status line is a harness-invoked callback, not a process.** It is one more
   cooperating callback in the same family as the guard and the pause-advisory hook —
   there is **no separate monitoring daemon**, and the user explicitly does not want one.
   This design adds none.

So the only architecture available is **status-line-as-sensor → the existing
sentinel/prompt-poll as actuator.** The status line is where the number lives; the pause
sentinel is how a run is already told to stop. Wire the two together and correctness is
inherited from ADR 0017 rather than reinvented.

## Decision

**Ship a plugin status-line script that reads BOTH `rate_limits.five_hour.used_percentage`
and `rate_limits.seven_day.used_percentage` and, when *either* crosses its own
configurable threshold, writes the *existing* ADR 0017 pause sentinel. From there ADR
0017 does everything else, unchanged. No new pause path, no run-state schema change, no
change to the synchronous dispatch model.**

1. **The status line is the sensor; the sentinel is the actuator.** The shipped script
   parses the session JSON on stdin, extracts **both** `five_hour.used_percentage` and
   `seven_day.used_percentage`, and when *either* is **≥ its own threshold** writes the
   all-run sentinel `.agents/pause` — the *same* write `runstate.sh request-pause`
   performs, in the *same* format ADR 0017 defines (`requested_at:` + a `reason:` line).
   The reason is human-legible and **names which window tripped and its reset time**,
   e.g. `reason: 5h-limit at 91% (resets 14:30Z)` or
   `reason: weekly-limit at 87% (resets Tue 09:00Z)`; if both trip it notes both,
   e.g. `reason: 5h-limit at 96% + weekly-limit at 88% (resets 14:30Z / Tue 09:00Z)`.
   Nothing downstream can tell this sentinel apart from a human- or frontend-requested
   one — and nothing should.

2. **Everything after the write is ADR 0017, byte-for-byte.** The **prompt-poll**
   (`runstate.sh pause-status`, ADR 0017 #3) that the loop / chief-engineer / implementer
   run at safe boundaries remains the **authoritative** gate: on `PAUSE=1` each agent
   brings its step to a green commit with the `[orch packet:<id>]` trailer or leaves the
   last green commit and sets scratch aside — **never mid-edit** — then stops. The
   **advisory hook** (`hooks/pause-check.sh`, ADR 0017 #4) is the same best-effort
   context-only reinforcement. Parallel status writeback and `reconcile-parallel`
   resumability (ADR 0017 #5) are untouched. The sensor adds a *cause* for the sentinel;
   it changes **none** of the sentinel's *consequences*.

3. **Each window has its own threshold, set with deliberate margin below the server
   cutoff.** Defaults: **5-hour 90%**, **7-day 85%** (both configurable; see #6), chosen
   well under 100% so a full in-flight packet can still land a green commit before the
   server-side cutoff. The margin is not cosmetic: the numbers **update only once per API
   response** (fact #1), so the sensor may not observe every intermediate value, and a
   wide parallel run can consume a lot of budget between two observations. Pick each
   threshold to survive that quantization plus one packet's drain time. **The weekly
   threshold is intentionally lower than the 5-hour one**: the 7-day window is
   slower-moving and far more consequential — exhausting it strands the account for
   *days*, not the ~couple of hours a 5-hour reset costs — so an unattended run should
   park earlier and more conservatively against the weekly ceiling. 85% vs 90% gives the
   weekly window that extra cushion.

4. **Best-effort early-warning, never a guarantee — same contract as the 0017 hook.**
   Both the 5-hour and 7-day cutoffs are enforced **server-side**; no status line, hook,
   or sentinel can override either. This sensor only **arms the cooperative pause earlier
   than a human would have**. Correctness must **never depend on it**: if the sensor is
   disabled, the auth
   mode is API-key (no `rate_limits` block), the account is not Pro/Max, or the cutoff
   simply arrives faster than the drain, the run degrades to exactly today's behavior —
   a lane hits the wall and reconcile `restart`s it, losing at most one packet's
   uncommitted work (which is why packets are commit-sized). The authoritative stop is
   still the prompt-poll landing on a green commit, not this signal.

5. **Two implementation variants; (A) is recommended.**
   - **(A, recommended) — the status-line script thresholds and writes the sentinel
     directly. Zero hook changes.** The sensor owns the whole decision: read → compare →
     (maybe) write. `hooks/pause-check.sh`, `hooks.json`, and the run-state schema are
     **not touched at all**; the sensor's only coupling to ADR 0017 is that it writes a
     file 0017 already reads. This is the smallest possible surface and keeps the new
     concern (the number) in the one place that has the number.
   - **(B) — the status-line script caches only the raw percentages; the hook thresholds.**
     The sensor writes both `five_hour.used_percentage` and `seven_day.used_percentage` to
     a cache file (e.g. `.agents/rate-limits`) and does nothing else; a few added lines in
     `pause-check.sh` read that cache and arm the sentinel when *either* crosses its
     threshold. This keeps thresholding in the hook
     layer, but it splits one trivial decision across two callbacks, makes the hook
     stateful about something it cannot itself observe, adds a cache file to the
     lifecycle, and — because the hook runs per-tool-call inside every lane — invites
     redundant re-evaluation of a number only the main-session status line ever refreshes.
     **Rejected as the default.**
   We adopt **(A)**. It is the cleaner separation: the sensor is the *only* component with
   access to the number and the *only* component that needs to act on it, so it should
   both read and decide. (B) is recorded so a future need to threshold in a shared place
   has a documented fallback.

6. **Enable/disable and threshold are per-repo config, in the established style.** A new
   optional block in `.agents/project-overrides.yaml`, resolved by the sensor with an env
   fast-path first (mirroring `ORCH_AUTONOMY` / `ORCH_PAUSE_FILE`):
   ```yaml
   # Auto-pause the loop before a Claude Code rolling usage limit is hit — the 5-hour
   # AND the 7-day (weekly) window (ADR 0018). Requires a Pro/Max account AND the
   # statusLine wired up in your settings.json (a plugin cannot set that for you — see
   # README). No effect under API-key auth (no rate_limits payload) or if the statusLine
   # is not configured.
   rate_limit_pause:
     enabled: true               # default true; set false to keep the status line read-only
     five_hour_threshold_pct: 90 # write the pause sentinel at/above this five_hour percentage
     seven_day_threshold_pct: 85 # ...and at/above this seven_day (weekly) percentage.
                                 # Lower than the 5h default on purpose: the weekly ceiling
                                 # is slower-moving and far costlier to exhaust.
   ```
   Resolution order (same shape as the other knobs): `ORCH_RATE_PAUSE_PCT` env →
   `rate_limit_pause.five_hour_threshold_pct` → default **90**; `ORCH_RATE_PAUSE_7D_PCT`
   env → `rate_limit_pause.seven_day_threshold_pct` → default **85**; and a single
   `ORCH_RATE_PAUSE=off` env → `rate_limit_pause.enabled: false` → default **on** that
   disables **both** window checks together. These are the *only* new knobs — the sentinel
   path, lane resolution, and poll cadence are all inherited from ADR 0017.

### Implementation sketch — the shipped sensor + the user setup (no design-doc tree exists)

The plugin ships `scripts/statusline-pause-sensor.sh`. It is a normal status-line
command: it reads the session JSON on stdin, **prints a one-line status to stdout** (that
is what the status line renders), and as a **side effect** arms the sentinel when *either*
the 5-hour or the 7-day budget crosses its threshold. It touches nothing on the hot path
when the `rate_limits` block is absent, so it is safe under API-key auth and before the
first API response.

The extraction guards **each window** with `// empty` (fact #1 — either window can be
independently absent) and only writes when it actually crosses, and only once (skip if the
sentinel already exists), so it never rewrites the reason/timestamp on every subsequent
response:

```bash
#!/usr/bin/env bash
set -uo pipefail
# Resolve our sibling runstate.sh from THIS script's own location — NOT from
# ${CLAUDE_PLUGIN_ROOT}, which is not guaranteed in the statusLine command context.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
input="$(cat)"                                  # the harness feeds session JSON on stdin

# read BOTH windows; each field is independently optional -> guard each with // empty
p5="$(printf '%s'  "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')"
r5="$(printf '%s'  "$input" | jq -r '.rate_limits.five_hour.resets_at       // empty')"
p7="$(printf '%s'  "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')"
r7="$(printf '%s'  "$input" | jq -r '.rate_limits.seven_day.resets_at       // empty')"
[ -n "$p5$p7" ] || { printf 'orch'; exit 0; }   # no rate_limits at all (API-key / pre-first-response)

t5="${ORCH_RATE_PAUSE_PCT:-90}"                 # 5-hour threshold: env -> project-overrides -> 90
t7="${ORCH_RATE_PAUSE_7D_PCT:-85}"              # 7-day threshold:  env -> project-overrides -> 85
enabled="${ORCH_RATE_PAUSE:-on}"                # single switch disables BOTH checks

# render the status line regardless (integer compare; percentages may be fractional)
[ -n "$p5" ] && printf '5h %s%% ' "${p5%.*}"; [ -n "$p7" ] && printf '7d %s%%' "${p7%.*}"

# decide: does EITHER window cross its own threshold?
reason=""; hhmm() { [ -n "$1" ] && date -u -r "$1" +%H:%MZ 2>/dev/null || echo soon; }
if [ "$enabled" != off ]; then
  [ -n "$p5" ] && [ "${p5%.*}" -ge "$t5" ] && reason="5h-limit at ${p5%.*}% (resets $(hhmm "$r5"))"
  if [ -n "$p7" ] && [ "${p7%.*}" -ge "$t7" ]; then
    w="weekly-limit at ${p7%.*}% (resets $(hhmm "$r7"))"
    reason="${reason:+$reason + }$w"            # if both trip, name both
  fi
fi

# arm the EXISTING ADR 0017 sentinel, once, when either crossed
if [ -n "$reason" ]; then
  # resolve the canonical main-checkout sentinel exactly like hooks/pause-check.sh
  gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gcd" ] && pausefile="$(dirname "$gcd")/.agents/pause"
  if [ -n "${pausefile:-}" ] && [ ! -f "$pausefile" ]; then
    "${here}/runstate.sh" request-pause "$pausefile" "$reason" >/dev/null 2>&1 || true
    printf ' ⏸'
  fi
fi
exit 0
```

Notes: it reuses `runstate.sh request-pause` (atomic write, correct format) rather than
hand-rolling the sentinel; it resolves the **main-checkout** sentinel via
`git rev-parse --git-common-dir` so the same request reaches every lane with zero
env-propagation dependency (ADR 0017 #2); it is idempotent (the `! -f "$pausefile"`
guard); and the **single** `reason` accumulates whichever window(s) tripped, so one
sentinel write covers both. A matching regression case belongs in `scripts/test-pause.sh`
(feed JSON blobs with each window at/over and under its threshold — including only-7d and
both-tripped — and assert the sentinel appears/does-not and carries the expected
`5h-limit` / `weekly-limit` reason), consistent with the plugin's "a behavior worth having
is a behavior worth a test" rule.

**The user setup the plugin cannot do for you — and `${CLAUDE_PLUGIN_ROOT}` will NOT save
you here.** A plugin cannot write `statusLine` into a user's `settings.json`; this is
opt-in. Critically, **the `${CLAUDE_PLUGIN_ROOT}` placeholder does not expand in the
`statusLine` command context.** Per the plugins reference / status-line docs, that
placeholder is expanded only in skill and agent content, **hook** and **monitor**
commands, MCP servers, and LSP servers — **`statusLine` is not on that list**. A
`statusLine.command` of `${CLAUDE_PLUGIN_ROOT}/scripts/statusline-pause-sensor.sh` would be
passed **literally** and fail. So the `settings.json` block must carry a **resolved
absolute path** to the installed script, not the placeholder.

**Recommended setup — one toggle skill does it for you, both directions.** Ship a single
skill (proposed name `rate-limit-pause`, invoked `/gaffer:rate-limit-pause <on|off|
status>`), mirroring the plugin's existing `set-autonomy` "show or set" idiom rather than
an enable/disable pair. Its arguments:

- **`on`** — the full enable path. Skill *content* **does** expand `${CLAUDE_PLUGIN_ROOT}`,
  so the skill resolves the real installed sensor path and writes/ensures the `statusLine`
  block in the user's `settings.json`, then sets `rate_limit_pause.enabled: true` in *this*
  repo's `.agents/project-overrides.yaml`. This is the clean, update-safe path: no
  hand-copied path, and it survives plugin updates — the plugin cache directory carries a
  **version hash that changes on every update**, so a value resolved once by the skill (and
  re-resolvable by re-running `on`) beats a path the user pasted by hand. What it writes
  into `settings.json` is the resolved form:

  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "/Users/<you>/.claude/plugins/cache/<plugin>@<version-hash>/scripts/statusline-pause-sensor.sh"
    }
  }
  ```

- **`off`** — the **per-repo disable** (the normal way to turn it back off). It sets
  `rate_limit_pause.enabled: false` in *this* repo's `.agents/project-overrides.yaml`
  (idempotent, preserving every other key) and **nothing else**. The global `statusLine`
  sensor stays in place and keeps rendering the percentages, but because the sensor reads
  *this* repo's `project-overrides.yaml` and sees `enabled: false`, it **does not arm the
  sentinel for this repo**. This is the clean part worth stating explicitly: even though
  the sensor script is a single global `statusLine` command, the enable/disable is
  genuinely **per-repo**, because the `enabled` gate lives in per-repo config that the
  sensor resolves at read time (see Open implementation question #1).

- **`status`** (matches `set-autonomy`) — report the current effective state for this
  repo: whether `statusLine` is wired in `settings.json`, and the resolved
  `rate_limit_pause.enabled` plus the two thresholds (env → `project-overrides.yaml` →
  defaults 90/85).

**Per-repo disable vs. full teardown — do not conflate them.** Plain `off` above is
**per-repo** and is the normal case. Removing the `statusLine` entry from `settings.json`
is a different, **global-scoped** action — `settings.json` is user-global, so deleting the
sensor there disables it for **every** repo and stops the percentages rendering anywhere.
Because that blast radius is global, teardown must be an **explicit, separate** action —
e.g. `/gaffer:rate-limit-pause off --teardown` or a documented manual edit — and
**never** the default `off` behavior. The skill must warn, before tearing down, that it
disables the sensor everywhere, not just here.

**Manual fallback (honest caveat).** A user may instead hardcode an absolute path such as
`~/.claude/plugins/cache/<plugin>/scripts/statusline-pause-sensor.sh` directly in
`settings.json`. This works, but it is **brittle across plugin updates**: the
version-hashed cache directory changes on update, silently breaking the status line until
the path is re-pasted. Prefer the skill, which re-resolves the current path on demand.

The README section must also state plainly: **works only on Pro/Max** (no `rate_limits`
under API-key auth), the numbers **update once per API response** so both thresholds carry
margin (and the weekly one sits lower on purpose), and this is **early-warning that arms
the ADR 0017 pause when either the 5-hour or the 7-day window crosses — not a hard stop**.

### Open implementation questions

These are the mechanics this ADR deliberately leaves to the implementing packet; each is
verified against the current repo:

1. **Config plumbing: the YAML threshold layer is not wired to the sensor yet.** Decision
   #6 states resolution is `env → .agents/project-overrides.yaml → default`, but the sketch
   script only reads env + default (`${ORCH_RATE_PAUSE_PCT:-90}`) and never reads the YAML.
   Critically, the status line is **harness-invoked, not launched by the loop driver**, so
   nothing exports `ORCH_RATE_PAUSE*` into the sensor's environment — meaning a threshold
   set in `project-overrides.yaml` would, as sketched, **silently never reach the sensor**.
   Resolution: the sensor must parse `.agents/project-overrides.yaml` itself. There is an
   established bash pattern for exactly this in the repo — copy from `hooks/guard.sh`
   (~line 379, the `autonomy_ceiling` read) and `scripts/worktree.sh` (~line 82, the
   `integration_branch` read). The env fast-path still works for a human running
   `statusLine` under an env that carries it, but the YAML layer is the primary config
   surface and must be read directly.

2. **The toggle skill's user-config write/erase strategy is unspecified — for BOTH
   directions.** The `rate-limit-pause` skill is bidirectional and mutates two user-config
   files, so `on`, `off`, and `off --teardown` share one "safely edit user config,
   idempotently, preserve existing keys" concern that must be decided together in this
   packet:
   - **`on`** writes to `settings.json`: what happens if the user already has a
     `statusLine` configured (overwrite? refuse and warn? merge?); whether it backs up
     `settings.json` first; and how re-running stays idempotent and re-resolves the
     version-hashed path on a plugin update. It also sets `rate_limit_pause.enabled: true`
     in `project-overrides.yaml` without disturbing other keys.
   - **`off`** edits only `project-overrides.yaml` — set `rate_limit_pause.enabled: false`
     idempotently, preserving every other key (create the block if absent).
   - **`off --teardown`** additionally *removes* the `statusLine` entry from
     `settings.json` — but only if it is *our* sensor (do not clobber a user's unrelated
     status line), and with the global-scope warning above.
   This is the **highest-review-value packet** — it mutates user config *outside* the
   plugin tree, in both add and erase directions — so these behaviors must be decided
   during implementation, not assumed.

3. **Portability: `date -u -r <epoch>` in the sketch is BSD/macOS-only.** Linux
   `coreutils` needs `date -u -d @<epoch>`. The shipped sensor's `hhmm()` helper must
   handle both (try one, fall back to the other), since the plugin runs on both platforms.

## Consequences

- **Reuses a proven, tested core; adds one small sensor + one toggle skill.** No new
  pause mechanism, no run-state schema change (stays v3), no dispatch-model change. The
  only new code is the status-line script (plus its `test-pause.sh` case) and the
  bidirectional `rate-limit-pause` (`on`/`off`/`status`) skill; the sentinel, prompt-poll,
  advisory hook, parallel writeback, and reconcile are ADR 0017 as-is. If the sensor is
  wrong or disabled, the blast radius is "the run was not warned early" — never a corrupted
  pause.
- **Best-effort, honestly.** Like the 0017 advisory hook, correctness must never DEPEND
  on this. Both the 5-hour and 7-day server-side cutoffs are authoritative and cannot be
  overridden; the sensor only converts a hard mid-packet kill into an *earlier,
  cooperative, land-green* drain *when it fires in time*. When it does not (quantized
  updates, a very wide run, or a cutoff that outruns the drain), reconcile `restart` is
  still the floor.
- **Two windows, one sentinel, one switch.** Whichever window trips first arms the same
  `.agents/pause` all-run sentinel; a single `ORCH_RATE_PAUSE=off` disables both checks.
  The weekly threshold defaults lower (85% vs 90%) because exhausting the 7-day window
  strands the account for *days*, not the couple of hours a 5-hour reset costs — so an
  unattended weekend run parks well before spending the week's budget.
- **Opt-in, account-gated, and reversible per-repo.** Requires a `statusLine` entry in the
  user's `settings.json` (written for them by `/gaffer:rate-limit-pause on`, since
  `${CLAUDE_PLUGIN_ROOT}` does not expand there and a plugin cannot edit `settings.json`
  on its own) and a Pro/Max account. Under API-key / Console auth there is no `rate_limits`
  block and the sensor is inert. Turning it back off is `/gaffer:rate-limit-pause
  off` — a **per-repo** disable that sets `rate_limit_pause.enabled: false` and leaves the
  global sensor rendering percentages; full teardown (removing the `statusLine` entry, a
  **global** action) is the explicit `off --teardown`. A repo that wants the status line
  but not the auto-pause simply stays at `enabled: false` (or `ORCH_RATE_PAUSE=off`) and
  keeps a purely informational status line.
- **Most valuable in long unattended parallel runs (ADR 0016).** That is the scenario
  where budget is consumed fastest and a mid-packet cutoff is most likely and most
  costly. In a short attended relay run the human is already watching and the sensor
  rarely fires; the feature earns its keep on wide, hours-long backlogs.
- **Familiar knobs, one style.** The two thresholds and the enable switch live in
  `.agents/project-overrides.yaml` with an `ORCH_RATE_PAUSE_PCT` / `ORCH_RATE_PAUSE_7D_PCT`
  / `ORCH_RATE_PAUSE` env fast-path, matching how every other loop behavior is
  configured — nothing new to learn.

## Alternatives considered

- **A separate monitoring daemon/process polling usage.** Rejected outright: the user
  explicitly does not want a second process, and — decisively — **there is nothing to
  poll.** No file on disk and no hook payload carries the rolling-usage number (fact #2);
  the status-line stdin is the only place it exists. A daemon would have no source.
- **Sense the limit from a hook.** Impossible for the same reason — no hook event carries
  `rate_limits`. The hook layer can only *act* on a pause (which ADR 0017 already covers);
  it cannot *observe* the limit. This is exactly why the sensor lives in the status line
  and the actuator stays in the existing hooks/prompt-poll.
- **Variant (B) — cache the numbers, threshold in the hook.** Documented under Decision #5
  as a viable fallback but rejected as the default: it splits a trivial read→compare→write
  across two callbacks and makes the per-lane hook stateful about numbers only the
  main-session status line refreshes. Variant (A) keeps the decision where the data is.
- **A coercive, agent-choice-proof stop on the limit.** Out of scope and unchanged from
  ADR 0017: hard enforcement would need a PreToolUse `deny` gated on `agent_id`, which
  0017 already defers until parallel runs show lanes overshooting poll checkpoints. Both
  cutoffs are server-side anyway, so there is nothing here a coercive local channel could
  guarantee that the server does not already enforce.
