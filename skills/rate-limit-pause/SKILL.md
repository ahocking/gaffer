---
name: rate-limit-pause
description: Show or set rate-limit-aware auto-pause (ADR 0018). `on` wires the plugin's status-line sensor into your user settings.json and enables it for this repo; `off` disables it per-repo (leaving the status line rendering); `off --teardown` also removes the global sensor; `status` reports the effective state. Use when the user wants a long unattended run to pause itself before a Claude Code 5-hour or 7-day usage limit is hit, or to turn that off / check it.
argument-hint: on | off | off --teardown | status  (omit to just show the current state)
---

# Rate-limit auto-pause → $ARGUMENTS

Wire the plugin's **status-line sensor** (`scripts/statusline-pause-sensor.sh`,
[ADR 0018](../../docs/adr/0018-rate-limit-aware-cooperative-pause.md)) so a long
unattended `run-loop` **pauses itself just before a Claude Code rolling usage limit
is hit** — the **5-hour** and the **7-day (weekly)** window. The sensor reads both
windows' usage percentages (the status line is the *only* place they are exposed)
and, when either crosses its threshold, writes the **same ADR 0017 pause sentinel** a
human would — from there everything is the ordinary cooperative pause, unchanged.

This is **show-or-set**, like `/gaffer:set-autonomy`. The **Chief Engineer**
runs it. It mutates **two config files** — the user-global `settings.json` (only on
`on` / `off --teardown`) and *this* repo's `.agents/project-overrides.yaml`. Both are
reversible; do **not** cross a hard gate to perform it.

**Two honest preconditions to state up front** (the sensor is inert otherwise, by
design — correctness never depends on it):

- **Pro/Max account.** The `rate_limits` block is absent under API-key / Console
  auth, so the sensor simply renders a bare label and never arms.
- **A `statusLine` entry in `settings.json`** pointing at the installed sensor. A
  plugin cannot write that for you, **and `${CLAUDE_PLUGIN_ROOT}` does not expand in
  the `statusLine` command context** — so the entry must carry a **resolved absolute
  path**. `on` resolves it and writes it for you.

## 1. Resolve intent

Read `$ARGUMENTS` (trim/lowercase the first token; note a `--teardown` flag):

- **empty / `status` / `show`** → write nothing; go to **§5 (status)**.
- **`on`** → **§2** then **§4**.
- **`off`** (no flag) → **§3** (per-repo disable only).
- **`off --teardown`** → **§3** then **§6** (also remove the global sensor — warn first).
- **anything else** → write nothing; say the valid forms are `on` / `off` /
  `off --teardown` / `status`, then show state (**§5**).

Resolve these paths once, up front:

- **Sensor (absolute).** Skill *content* **does** expand the placeholder, so the real
  installed path is `${CLAUDE_PLUGIN_ROOT}/scripts/statusline-pause-sensor.sh`.
  Capture the expanded value — it is version-hashed and changes on every plugin
  update, which is exactly why re-running `on` re-resolves it:
  ```bash
  SENSOR="${CLAUDE_PLUGIN_ROOT}/scripts/statusline-pause-sensor.sh"
  [ -x "$SENSOR" ] || { echo "sensor not found/executable at $SENSOR"; }   # stop & report if missing
  ```
- **User settings.** `SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"`.
- **This repo's overrides.** `OVR="$PWD/.agents/project-overrides.yaml"` (repo root).

## 2. `on` — wire `settings.json` (idempotent, never clobber a foreign status line)

Ensure the `statusLine` block points at **our** `SENSOR`. **Back up first**, then act
on three cases — do **not** overwrite a status line that is not ours:

```bash
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
cp "$SETTINGS" "${SETTINGS}.bak"                       # timestamped backup is fine too

existing="$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || echo "")"
case "$existing" in
  "")                               act=set  ;;        # none configured -> add ours
  *statusline-pause-sensor.sh)      act=set  ;;        # already ours -> re-resolve the path (update-safe)
  *)                                act=warn ;;        # a DIFFERENT status line -> do not clobber
esac
```

- **`act=set`** → write our command atomically, preserving every other settings key:
  ```bash
  tmp="$(mktemp)"; jq --arg cmd "$SENSOR" \
    '.statusLine = {"type":"command","command":$cmd}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  ```
- **`act=warn`** → **stop and report**, do not edit `settings.json`. Show the user
  the existing command and the exact block they can paste to switch (the `jq` above),
  and note the backup at `${SETTINGS}.bak`. Still proceed to **§4** so the per-repo
  gate is set — but make clear the sensor won't render until they resolve the
  conflict. (`jq` unavailable? Do the same edit by hand via Read/Edit, preserving all
  other keys, and back up first.)

Then continue to **§4**.

## 3. `off` — per-repo disable (the normal way to turn it back off)

Set `rate_limit_pause.enabled: false` in **`OVR`**, idempotently, **preserving every
other key** (create the block if absent). This is a **per-repo** disable: the global
`statusLine` sensor stays in place and keeps rendering the percentages, but because
it reads *this* repo's `enabled` gate at run time, it will **not arm the sentinel
here**. Prefer editing the file with Read/Edit so surrounding keys and comments
survive:

- block + `enabled:` present → set the value to `false`.
- block present, no `enabled:` → insert `  enabled: false` as its first child.
- block absent → append:
  ```yaml
  rate_limit_pause:
    enabled: false
  ```

Do **not** touch `settings.json` on a plain `off`. Then report (**§5**). If this was
`off --teardown`, continue to **§6** as well.

## 4. `on` — enable the per-repo gate

Set `rate_limit_pause.enabled: true` in **`OVR`** the same idempotent way as §3
(preserve other keys; create the block if absent). Leave `five_hour_threshold_pct` /
`seven_day_threshold_pct` untouched unless the user asked to change them — absent,
the sensor uses **90 / 85**. Then report (**§5**).

## 5. Report the effective state, then stop

State concisely, for **this repo**:

- **Sensor wired?** Read `.statusLine.command` from `SETTINGS`. Report one of:
  *ours* (path ends `statusline-pause-sensor.sh`), *a different status line*
  (quote it — our sensor is not active), or *none*.
- **Enabled here?** `ORCH_RATE_PAUSE=off` env → `rate_limit_pause.enabled` in `OVR` →
  default **on**. Name which source won.
- **Thresholds.** 5h: `ORCH_RATE_PAUSE_PCT` → `five_hour_threshold_pct` → **90**;
  7d: `ORCH_RATE_PAUSE_7D_PCT` → `seven_day_threshold_pct` → **85**.
- **Account caveat (always):** works **only on Pro/Max**; under API-key auth there is
  no `rate_limits` payload and the sensor is inert. The numbers **update once per API
  response**, so both thresholds carry margin (the weekly one lower on purpose).
- **Contract (always):** this is **early-warning that arms the ADR 0017 cooperative
  pause — not a hard stop.** Both cutoffs are enforced server-side; if the cutoff
  outruns the drain, reconcile `restart` is still the floor.

```bash
jq -r '.statusLine.command // "(none)"' "$SETTINGS" 2>/dev/null
grep -A4 '^rate_limit_pause:' "$OVR" 2>/dev/null || echo "(no rate_limit_pause block — defaults: on, 90/85)"
```

Then stop. Do not start a loop as a side effect.

## 6. `off --teardown` — remove the GLOBAL sensor (explicit, warned)

Only reached on `off --teardown`. **This is global-scoped:** `settings.json` is
user-global, so removing the sensor disables it — and stops the percentages
rendering — for **every** repo, not just this one. **Warn the user of that blast
radius before doing it.**

Remove the `statusLine` entry **only if it is ours** (never clobber a status line the
user set for something else). Back up first:

```bash
cp "$SETTINGS" "${SETTINGS}.bak"
cmd="$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || echo "")"
case "$cmd" in
  *statusline-pause-sensor.sh)
    tmp="$(mktemp)"; jq 'del(.statusLine)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    echo "removed our global statusLine sensor (backup: ${SETTINGS}.bak)";;
  "") echo "no statusLine entry to remove";;
  *)  echo "statusLine is NOT our sensor — left untouched: $cmd";;
esac
```

Report (**§5**) and stop.
