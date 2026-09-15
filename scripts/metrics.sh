#!/usr/bin/env bash
# =============================================================================
# metrics.sh — run-metrics JOIN + ASSEMBLE core (ADR 0019 Tier 1)
# =============================================================================
# The deterministic, zero-token half of the metrics feature. The PostToolUse hook
# (hooks/metrics-log.sh) COLLECTS a per-session event spine as a run goes; this
# script JOINS that spine with (a) packet boundaries derived from the
# `[orch packet:<id>]` commit trailers that already exist in git, and (b) best-effort
# token/cost from the Claude Code session transcripts — into ONE self-contained,
# portable rollup: .agents/metrics/<run-id>/run-metrics.json. That packet is the
# artifact a human reads or hands to Claude (/gaffer:metrics analyze) for
# optimization.
#
# WHY DERIVE PACKET BOUNDARIES FROM GIT (not run-state, cf. ADR 0019 revision):
#   run-state's packets[] is a nested structure with a strict single-writer/atomic
#   contract (the driver). Threading timing into it would force a schema migration
#   (and would break an in-flight consumer run). The `[orch packet:<id>]` trailer is a
#   zero-migration source that already ties every green commit to its packet, so we
#   read boundaries from `git log` and leave run-state untouched.
#
# TOKEN SOURCE (ADR 0019 amended): transcript-parse is the DEFAULT. The on-disk
# transcript format is documented as internal/version-fragile, so every read is
# best-effort and FAILS SOFT to structural-only; the packet STAMPS `token_source`
# (transcript | transcript-degraded | none) so a partial or low-confidence run is
# never misread as complete. Token turns are BOUNDED to the run window (same as the
# event spine and trailer scan) so a whole-file transcript read cannot bleed a prior
# run's tokens into the totals; when the unattributable ('unknown' role) share of
# output is large the stamp downgrades to `transcript-degraded`. OTEL read-back is a
# deferred later upgrade (Tier 0), not built here. A `none`/degraded stamp always
# carries `token_diagnostics` (counts, no paths) saying WHICH failure it was —
# nothing on disk, lookup miss, format drift, or window miss.
#
# PORTABILITY TRAP — jq AND CRLF: the native Windows jq build writes \r\n, including
# to pipes. Two consequences, and the second is the one that bites twice:
#   1. `read` strips only the \n, so any `jq -r … > file` consumed by a `while read`
#      loop MUST be piped through `tr -d '\r'` (a no-op on POSIX). See the sids.txt
#      write — getting this wrong broke only the transcript-file globs, so every
#      structural number stayed right while the token half read as legitimately absent.
#   2. `$( )` looks safe but is not portably safe. MSYS bash strips a trailing \r\n
#      from command substitution; plain bash (Linux, macOS) strips only the \n. So
#      every scalar capture here was correct on Windows purely by accident of which
#      bash Git Bash ships. Hence jqr() — all raw reads go through it.
# Neither failure is loud, so neither is discoverable by looking at the output.
#
# Subcommands:
#   collect [opts]     assemble the run-metrics packet and print its path.
#   show    [file]     print a compact human summary of a run-metrics packet.
#   status  [opts]     report whether metrics is enabled + which sources are present.
#
# collect options (all optional; sensible defaults; flags exist mainly for tests):
#   --main-root DIR    the checkout whose .agents/ holds the run (default: resolved
#                      from `git rev-parse --git-common-dir`, so a lane worktree
#                      still finds the canonical dir).
#   --projects-dir DIR Claude Code transcript root (default: $ORCH_METRICS_PROJECTS_DIR
#                      or ~/.claude/projects). Point at a fixture in tests.
#   --run-id ID        override the run id (default: run-state branch task-id, else
#                      the current orch/<id> branch, else "adhoc-<session8>").
#   --session ID       include only this session's event log (repeatable). Default is
#                      the NEWEST session log by mtime — the run you just finished.
#   --all-sessions     include every session log (whole-history rollup; legacy).
#   --since ISO/--until ISO  narrow the run window explicitly; --since sets the lower
#                      bound that excludes prior runs' commit trailers, --until the
#                      upper. BOTH bounds are always enforced: without --until the
#                      upper bound is the last tool event PLUS a grace margin
#                      ($ORCH_METRICS_TRAILER_GRACE, default 3600s), because a run's
#                      last packet commits just after its last tool event — CAPPED at
#                      the earliest event of any other session after that point, so
#                      the grace can never reach into a concurrent or back-to-back
#                      run and claim its commits (ADR 0019 v3.2).
#   --out FILE         where to write the packet (default:
#                      <main-root>/.agents/metrics/<run-id>/run-metrics.json).
# =============================================================================

set -uo pipefail

die() { printf 'metrics.sh: %s\n' "$*" >&2; exit 1; }
warn() { printf 'metrics.sh: %s\n' "$*" >&2; }

# --- jqr: raw-mode jq with CR stripped (see PORTABILITY TRAP in the header) ----
# EVERY raw jq read goes through here. It is tempting to skip it for `$(jq -r …)`
# captures because MSYS bash strips a trailing \r\n from command substitution —
# but that is an MSYS QUIRK, not bash behavior. Plain bash (Linux, macOS) strips
# only the \n, so on any other shell a CRLF-emitting jq leaves every captured
# scalar one byte too long. Measured, with a CRLF jq under Linux bash: role keys
# became "implementer\r", window/packet timestamps gained a \r, `turns_have_ts`
# stopped equalling "true" (silently nulling every per-packet token split), and
# the turn counts failed their numeric guard and reset to 0. Depending on which
# bash the host happens to ship is exactly the hidden assumption that produced
# the original bug, so this does not rely on it.
# pipefail (set above) is what preserves jq's exit status through the pipe, so
# callers' `|| echo <default>` fallbacks still fire on a jq error.
jqr() { jq -r "$@" | tr -d '\r'; }

# --- shared jq fragment: parse a T1-shaped timestamp into a COMPARABLE ms key --
# runstate.sh's record-start/record-outcome/sweep-open (loop-measurement T1/T3)
# stamp sub-second UTC times ("...:08.311Z"), which do NOT sort correctly as
# strings against a whole-second stamp in the same second ("...:08.311Z" sorts
# BELOW "...:08Z" because "." (0x2E) sorts before "Z" (0x5A)). A live site did
# exactly this raw string compare (the outcomes-window filter below, pre-T4) and
# silently dropped same-second records. Every join over the outcomes log must
# compare PARSED times instead — this is the one definition, spliced (via bash
# concatenation) into every jq program below that needs it, so it cannot drift
# out of step with runstate.sh's own `_rs_ts_key`/`_rs_frac_ms` (same algorithm:
# epoch seconds * 1000 + the first 3 fractional digits, zero-padded). No fraction
# present (a pre-T1 whole-second record) reads as ms=0, matching `_rs_frac_ms`.
JQ_TS_MS='def ts_ms:
  . as $t
  | (($t | index("."))) as $dot
  | (if $dot == null then {bare: $t, frac: "0"}
     else {bare: ($t[0:$dot] + "Z"), frac: $t[$dot+1:-1]} end) as $p
  # RESILIENT, not throwing (M1): fromdateiso8601 throws on one unparseable
  # value, and this def runs unconditionally over EVERY record in a slurped
  # array before any window filter narrows it -- one malformed ts anywhere in
  # the outcomes log would abort the whole jq program, and the caller-side
  # `2>/dev/null || echo [] `/`{}` fallback then silently zeroes every
  # packet outcome for the run, not just the bad record. `?` degrades a
  # malformed bare-seconds value to epoch 0 instead, which sorts before any
  # real window and so drops out on its own rather than taking the run with it.
  | ($p.bare | fromdateiso8601? // 0) as $secs
  | (($p.frac + "000")[0:3] | tonumber) as $ms
  | $secs * 1000 + $ms;
'

# --- portable ISO-8601(Z) [+ optional .fff] -> epoch seconds -----------------
# STRIPS an optional fractional-seconds component before handing the timestamp to
# `date` (loop-measurement T4 finding): GNU `date -u -d` accepts the fraction fine,
# but the BSD/macOS `-j -f "%Y-%m-%dT%H:%M:%SZ"` arm REJECTS it outright and this
# function's un-fixed form returned 0 for any sub-second stamp on macOS while
# working on a GNU runner — a silent, platform-dependent wrong answer, since 0 is a
# valid-looking epoch. `runstate.sh record-start`/`record-outcome` (T1/T3) now stamp
# sub-second UTC times (`_rs_now_ts`), so any caller handing this function one of
# those records' `ts` fields would otherwise hit exactly this. Mirrors
# `runstate.sh`'s own `_rs_epoch_secs` (same fix, deliberately a separate copy — see
# that function's comment for why it is not a shared call).
epoch() {
  local t="${1:-}" bare; [ -n "$t" ] || { echo 0; return; }
  bare="$(printf '%s' "$t" | sed -E 's/\.[0-9]+Z$/Z/')"
  # GNU date first, then BSD/macOS.
  date -u -d "$bare" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$bare" +%s 2>/dev/null \
    || echo 0
}

# --- portable ISO-8601(Z) + N seconds -> ISO-8601(Z) --------------------------
# Used to give the commit-trailer scan a grace margin past the last tool event.
# Falls back to the input unchanged if the date cannot be parsed/formatted, so a
# platform without either `date` dialect degrades to the old open-ended behavior
# rather than dropping every trailer.
iso_plus() {
  local t="${1:-}" add="${2:-0}" e
  [ -n "$t" ] || { printf ''; return; }
  e="$(epoch "$t")"
  [ "$e" -gt 0 ] 2>/dev/null || { printf '%s' "$t"; return; }
  e=$(( e + add ))
  # BSD/macOS (-r) first, then GNU (-d @).
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$t"
}

# --- earliest event belonging to a session OTHER than this run's, after `after`.
# Feeds the next-session cap on the trailer grace (ADR 0019 v3.2). Prints empty when
# nothing else ran — the caller then keeps the full grace. Event logs are append-
# ordered by ts, so the first match per file is that file's earliest; `sort|head -1`
# picks the global minimum. Reads only `.ts`; no command text, no paths. Best-effort
# by construction: any unreadable/malformed log simply contributes nothing, which
# degrades to the pre-v3.2 flat-grace behaviour rather than dropping real packets.
next_foreign_event() {
  local agents_dir="${1:-}" sids_file="${2:-}" after="${3:-}"
  [ -n "$after" ] || { printf ''; return; }
  [ -d "$agents_dir/metrics/events" ] || { printf ''; return; }
  local ef esid
  for ef in "$agents_dir"/metrics/events/*.jsonl; do
    [ -e "$ef" ] || continue
    esid="$(basename "$ef" .jsonl)"
    # our own selected session(s) can never be "foreign"
    if [ -s "$sids_file" ] && grep -qxF "$esid" "$sids_file" 2>/dev/null; then continue; fi
    jq -r --arg a "$after" 'select((.ts // "") > $a) | .ts' "$ef" 2>/dev/null | head -1
  done | tr -d '\r' | sort | head -1
}

# --- resolve the main checkout that owns .agents/ -----------------------------
resolve_main_root() {
  local r="${1:-}"
  if [ -n "$r" ]; then printf '%s' "$r"; return; fi
  local gcd
  gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gcd" ] || gcd="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd || true)"
  [ -n "$gcd" ] || { printf '%s' "$PWD"; return; }
  dirname "$gcd"
}

# --- metrics enabled? (env -> project-overrides metrics.enabled -> default on) -
metrics_enabled() {
  local main_root="$1"
  case "${ORCH_METRICS:-}" in off|false|0|no) echo off; return ;; on|true|1|yes) echo on; return ;; esac
  local ov="${main_root}/.agents/project-overrides.yaml"
  if [ -f "$ov" ] && awk '
      /^[[:alnum:]_]+:/ { inblk = ($1 == "metrics:") }
      inblk && /^[[:space:]]+enabled:[[:space:]]*false/ { print "off"; exit }
    ' "$ov" 2>/dev/null | grep -q off; then
    echo off; return
  fi
  echo on
}

# --- idle-gap threshold (env -> project-overrides metrics.idle_gap_seconds -> 300) -
# An inter-event gap longer than this counts as IDLE wall-time, not active compute.
resolve_idle_gap() {
  local main_root="$1" v=""
  case "${ORCH_METRICS_IDLE_GAP:-}" in ''|*[!0-9]*) : ;; *) echo "$ORCH_METRICS_IDLE_GAP"; return ;; esac
  local ov="${main_root}/.agents/project-overrides.yaml"
  if [ -f "$ov" ]; then
    v="$(awk '
      /^[[:alnum:]_]+:/ { inblk = ($1 == "metrics:") }
      inblk && /^[[:space:]]+idle_gap_seconds:[[:space:]]*[0-9]+/ { for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit} }
    ' "$ov" 2>/dev/null)"
  fi
  case "$v" in ''|*[!0-9]*) echo 300 ;; *) echo "$v" ;; esac
}

# =============================================================================
# collect
# =============================================================================
cmd_collect() {
  local main_root="" projects_dir="" run_id="" out=""
  local all_sessions=0 opt_since="" opt_until="" sel_sessions=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --main-root)    main_root="$2"; shift 2 ;;
      --projects-dir) projects_dir="$2"; shift 2 ;;
      --run-id)       run_id="$2"; shift 2 ;;
      --out)          out="$2"; shift 2 ;;
      --session)      sel_sessions="${sel_sessions}${sel_sessions:+ }$2"; shift 2 ;;
      --all-sessions) all_sessions=1; shift ;;
      --since)        opt_since="$2"; shift 2 ;;
      --until)        opt_until="$2"; shift 2 ;;
      *) die "collect: unknown option '$1'" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "jq is required for collect (install jq); the event log is unaffected."

  main_root="$(resolve_main_root "$main_root")"
  projects_dir="${projects_dir:-${ORCH_METRICS_PROJECTS_DIR:-$HOME/.claude/projects}}"
  local agents="${main_root}/.agents"
  local evdir="${agents}/metrics/events"
  local rs="${agents}/run-state.yaml"

  # --- run identity ----------------------------------------------------------
  local mode="unknown" branch="" integ=""
  if [ -f "$rs" ]; then
    mode="$(awk -F: '/^mode:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$rs" 2>/dev/null)"
    branch="$(awk -F: '/^branch:/{sub(/^[^:]*:[[:space:]]*/,"",$0); gsub(/[[:space:]]/,"",$0); print; exit}' "$rs" 2>/dev/null)"
    integ="$(awk -F: '/^integration_branch:/{sub(/^[^:]*:[[:space:]]*/,"",$0); gsub(/[[:space:]]/,"",$0); print; exit}' "$rs" 2>/dev/null)"
    [ -n "$mode" ] || mode="unknown"
  fi
  # Autonomy level (env > .agents/autonomy > unknown). Recorded so two runs are
  # COMPARABLE: a `supervised` run (human answering questions, editing inline) is not
  # comparable to `full-autonomy`, and reading a before/after across the two is how a
  # measurement lies. Resolved at collect time — it is not in run-state.
  local autonomy="${ORCH_AUTONOMY:-}"
  if [ -z "$autonomy" ] && [ -f "${agents}/autonomy" ]; then
    # The file is COMMENTED (the template documents the levels inline), so take the
    # first non-blank, non-`#` line only — slurping the whole file yields the manual.
    autonomy="$(awk 'NF && $0 !~ /^[[:space:]]*#/ {
                       gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit }' \
                   "${agents}/autonomy" 2>/dev/null || true)"
  fi
  [ -n "$autonomy" ] || autonomy="unknown"
  # run_id from an explicit flag or an orch/<task-id> branch; the "adhoc" fallback
  # is DEFERRED to after session selection so it can be disambiguated by session id.
  if [ -z "$run_id" ]; then
    case "$branch" in orch/*) run_id="${branch#orch/}" ;; esac
    if [ -z "$run_id" ]; then
      local cur; cur="$(git -C "$main_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
      case "$cur" in orch/*) run_id="${cur#orch/}" ;; esac
    fi
  fi

  # --- self-host detection: is THIS collector measuring its OWN repo? -----------
  # Resolved from the SCRIPT'S OWN PATH, not the working directory and not
  # ${CLAUDE_PLUGIN_ROOT} (not dependable in every context this runs in, cf. the
  # statusline sensor) — the working directory is the thing being MEASURED, not
  # the thing doing the measuring. self_host is true only when BOTH git roots
  # resolve, are the SAME directory, AND that directory carries
  # .claude-plugin/plugin.json — the manifest check is what stops a coincidence
  # (e.g. a nested checkout with no plugin) from reading as self-host. Every git
  # call is best-effort under `2>/dev/null || true`; on any doubt this is false.
  # This is bookkeeping and must never be able to break `collect`.
  local self_host="false" self_script_dir="" self_repo_root="" driven_repo_root=""
  local self_gcd="" driven_gcd="" gcd_raw=""
  # BASH_SOURCE[0] must be non-empty. Falling back to $0 (e.g. "bash" when this
  # file is piped in) would dirname to ".", i.e. the WORKING directory — exactly
  # the basis this design rejected, so there is no fallback: absent means false.
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    self_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P 2>/dev/null || true)"
  fi
  if [ -n "$self_script_dir" ]; then
    # Resolve BOTH sides with the SAME rule resolve_main_root() uses
    # (--git-common-dir, worktree-NORMALISED), not --show-toplevel
    # (worktree-LOCAL): comparing a lane's local toplevel against the driven
    # side's normalised root read false for a self-host run collected through a
    # worktree lane's own copy of this script.
    self_gcd="$(git -C "$self_script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$self_gcd" ]; then
      # --path-format is a newer git; fall back to the relative form and resolve it
      # with cd+pwd — but ONLY when rev-parse actually produced something. Piping a
      # failed/empty result through `|| echo .` would cd to the COLLECTOR's own
      # working directory and silently invent a root, so an empty result here is
      # left empty instead.
      gcd_raw="$(git -C "$self_script_dir" rev-parse --git-common-dir 2>/dev/null || true)"
      [ -n "$gcd_raw" ] && self_gcd="$(cd "$self_script_dir/$gcd_raw" 2>/dev/null && pwd || true)"
    fi
    # No fallback to self_script_dir: an unresolved self_gcd (e.g. a non-git
    # archive/tarball copy of the plugin) must leave self_repo_root EMPTY, never
    # `dirname` a synthesized root — "on any doubt this is false" applies to a
    # missing answer too, not only a mismatched one.
    [ -n "$self_gcd" ] && self_repo_root="$(dirname "$self_gcd")"

    driven_gcd="$(git -C "$main_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$driven_gcd" ]; then
      # Same rule, driven side: only cd+pwd a NON-EMPTY rev-parse result. When git
      # genuinely fails (e.g. --main-root is not a git repo at all, or is a broken
      # submodule/worktree pointer git cannot resolve), the result is left empty
      # instead of resolving the collector's cwd — that substitution made a non-git
      # --main-root read self_host=true or false depending on the directory
      # `collect` happened to be launched from.
      gcd_raw="$(git -C "$main_root" rev-parse --git-common-dir 2>/dev/null || true)"
      [ -n "$gcd_raw" ] && driven_gcd="$(cd "$main_root/$gcd_raw" 2>/dev/null && pwd || true)"
    fi
    # No fallback to main_root either: an unresolved driven_gcd must leave
    # driven_repo_root EMPTY, never `dirname` --main-root itself — that fallback is
    # exactly what let a non-git --main-root sited under a real plugin root read
    # self_host=true (driven_repo_root landed on the plugin root by construction,
    # not by resolving anything).
    [ -n "$driven_gcd" ] && driven_repo_root="$(dirname "$driven_gcd")"

    if [ -n "$self_repo_root" ] && [ -n "$driven_repo_root" ] \
       && [ "$self_repo_root" = "$driven_repo_root" ] \
       && [ -f "$self_repo_root/.claude-plugin/plugin.json" ]; then
      self_host="true"
    fi
  fi

  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  # --- 1. events spine: SELECT this run's session logs, then concat -----------
  # A "run" is bounded by the sessions that produced its events. The events dir
  # accumulates EVERY session ever, so concatenating them all would fold unrelated
  # runs together (and stretch the window across weeks). Selection rule:
  #   --session ID ... : exactly those session logs
  #   --all-sessions   : every log (legacy behavior, kept for whole-history rollups)
  #   default          : the NEWEST session log by mtime (the run you just finished)
  : > "$tmp/evfiles.txt"
  if [ -d "$evdir" ]; then
    if [ -n "$sel_sessions" ]; then
      local sid
      for sid in $sel_sessions; do [ -e "$evdir/$sid.jsonl" ] && printf '%s\n' "$evdir/$sid.jsonl" >> "$tmp/evfiles.txt"; done
    elif [ "$all_sessions" -eq 1 ]; then
      ls "$evdir"/*.jsonl 2>/dev/null >> "$tmp/evfiles.txt" || true
    else
      ls -t "$evdir"/*.jsonl 2>/dev/null | head -1 >> "$tmp/evfiles.txt" || true
    fi
  fi
  : > "$tmp/events.ndjson"
  while IFS= read -r f; do [ -e "$f" ] || continue; cat "$f" >> "$tmp/events.ndjson"; done < "$tmp/evfiles.txt"
  jq -s '.' "$tmp/events.ndjson" > "$tmp/events_all.json" 2>/dev/null || echo '[]' > "$tmp/events_all.json"
  # optional explicit --since/--until narrowing WITHIN the selected sessions
  if [ -n "$opt_since" ] || [ -n "$opt_until" ]; then
    jq --arg s "$opt_since" --arg u "$opt_until" \
       'map(select(($s=="" or .ts>=$s) and ($u=="" or .ts<=$u)))' \
       "$tmp/events_all.json" > "$tmp/events.json" 2>/dev/null || cp "$tmp/events_all.json" "$tmp/events.json"
  else
    cp "$tmp/events_all.json" "$tmp/events.json"
  fi

  local run_start run_end tool_calls
  run_start="$(jqr 'map(.ts)|min // empty' "$tmp/events.json")"
  run_end="$(jqr 'map(.ts)|max // empty' "$tmp/events.json")"
  tool_calls="$(jqr 'length' "$tmp/events.json")"

  # --- active vs idle wall time (ADR 0019 v2): sum inter-event gaps; a gap longer
  # than the idle threshold is IDLE (a pause / rate-limit sleep / waiting on a human),
  # the rest is ACTIVE compute. Wall overstates effort when a run sat idle (observed in a real run).
  local idle_gap; idle_gap="$(resolve_idle_gap "$main_root")"
  jq --argjson gap "$idle_gap" '
    ([.[].ts] | sort | map(fromdateiso8601)) as $t
    | reduce range(0; ($t|length)-1) as $i ({active:0,idle:0};
        ($t[$i+1]-$t[$i]) as $d | if $d>$gap then .idle+=$d else .active+=$d end)
  ' "$tmp/events.json" > "$tmp/activity.json" 2>/dev/null || echo '{"active":0,"idle":0}' > "$tmp/activity.json"

  # --- ADR 0019 v2: skill attribution + command-class + duration (from enriched events)
  # by_skill: attribute EVERY tool event to the skill in effect for its (session,agent),
  # tracking the "current skill" as Skill-tool events appear in ts order (the missing
  # process dimension — which skill/process the compute was spent under).
  jq '
    sort_by(.ts)
    | reduce .[] as $e ({cur:{}, out:[]};
        ($e.session_id + "|" + ($e.agent_id // "")) as $k
        | (if ($e.skill // null) != null then .cur[$k] = $e.skill else . end)
        | .out += [$e + {_skill: (.cur[$k] // "none")}])
    | .out | group_by(._skill)
    | map({key:.[0]._skill, value:{tool_calls:length, duration_ms:(map(.duration_ms//0)|add)}})
    | from_entries
  ' "$tmp/events.json" > "$tmp/byskill.json" 2>/dev/null || echo '{}' > "$tmp/byskill.json"

  # by_tool: the raw tool mix — Bash vs Read vs Edit vs Agent vs Grep/Glob vs MCP.
  # The events always carried `.tool`, but nothing rolled it up, so the assembled
  # packet had no view of tool SELECTION at all — only `by_command_class`, which
  # classifies Bash and nothing else. That blind spot hid a real finding: across
  # ~6k tool calls in two consumer repos there were ZERO Grep/Glob calls and 1,568
  # shell `grep`s, i.e. agents were shelling out for work the structured tools do
  # with bounded output. That is invisible in by_command_class (which sees only a
  # healthy-looking `grep` entry) and obvious in by_tool.
  jq '
    group_by(.tool)
    | map({key:.[0].tool, value:{calls:length, duration_ms:(map(.duration_ms//0)|add)}})
    | from_entries
  ' "$tmp/events.json" > "$tmp/bytool.json" 2>/dev/null || echo '{}' > "$tmp/bytool.json"

  # by_command_class: Bash command heads -> {calls, duration_ms}. The rtk-targeting map.
  jq '
    [ .[] | select(.cmd_class != null) ] | group_by(.cmd_class)
    | map({key:.[0].cmd_class, value:{calls:length, duration_ms:(map(.duration_ms//0)|add)}})
    | from_entries
  ' "$tmp/events.json" > "$tmp/bycmd.json" 2>/dev/null || echo '{}' > "$tmp/bycmd.json"

  # per-tool-call duration: total + per-role (agent_type). duration_ms is a native
  # PostToolUse field (Step-0 probe) — no Pre/Post pairing needed.
  jq '{
    total: (map(.duration_ms//0)|add),
    by_role: (group_by(.agent_type)|map({key:.[0].agent_type, value:(map(.duration_ms//0)|add)})|from_entries)
  }' "$tmp/events.json" > "$tmp/durations.json" 2>/dev/null || echo '{"total":0,"by_role":{}}' > "$tmp/durations.json"

  # --- run window: the [start,end] the trailer scan and packet chaining use ---
  # Prefer explicit flags, else the selected-events span. win_start is the lower
  # bound that excludes prior runs' commit trailers; win_end is only enforced when
  # --until is given (collection happens at end-of-run, so nothing legit is after).
  local win_start win_end
  win_start="${opt_since:-$run_start}"
  win_end="${opt_until:-$run_end}"

  # aid -> agent_type map (for attributing subagent transcript files to a role)
  jq '[.[]|{key:.agent_id,value:.agent_type}]|from_entries' "$tmp/events.json" > "$tmp/aidmap.json" 2>/dev/null || echo '{}' > "$tmp/aidmap.json"
  # distinct session ids seen in events.
  #
  # CRLF (Windows): the native Windows jq build opens stdout in TEXT mode, so EVERY
  # jq line ends \r\n — on pipes too, not just consoles. `read` strips only the \n and
  # leaves the \r. This is the ONE jq-written LINE LIST consumed by a `while read`
  # loop, and the values are used to build GLOBS: a session id one byte too long makes
  # `<uuid>\r.jsonl` match nothing, so the transcript join found zero files and stamped
  # token_source=none on every Windows run — silently, via the legitimate fail-soft
  # path, while every structural number stayed correct.
  #
  # It is ONLY this site that broke in production, because MSYS bash strips a trailing
  # \r\n from `$( )` and so cleaned every scalar capture for free. Do NOT read that as
  # "the captures are safe" — it is an MSYS quirk, not bash behavior (verified: under
  # Linux bash 5.2 the same capture keeps the CR). That is why the scalar reads go
  # through jqr() rather than relying on the host shell.
  # RULE: any future `jq -r … > file` that a `read` loop consumes must be piped
  # through `tr -d '\r'` the same way.
  jq -r '[.[].session_id]|unique|.[]' "$tmp/events.json" 2>/dev/null | tr -d '\r' > "$tmp/sids.txt" || true
  # JSON form of the same selected-session set, for the record joins below (T4):
  # they need it as a jq array, not a line list a `while read` loop consumes, so the
  # CRLF hazard documented above does not apply to this particular read.
  jq -R -s 'split("\n")|map(select(length>0))' "$tmp/sids.txt" > "$tmp/sids.json" 2>/dev/null || echo '[]' > "$tmp/sids.json"

  # finalize the deferred "adhoc" run_id, disambiguated so two different sessions
  # never collide on .agents/metrics/adhoc/run-metrics.json. Prefer the (first)
  # session id's leading 8 chars; else a timestamp when there is no session at all.
  if [ -z "$run_id" ]; then
    local first_sid; first_sid="$(head -1 "$tmp/sids.txt" 2>/dev/null)"
    if [ -n "$first_sid" ]; then
      run_id="adhoc-${first_sid:0:8}"
    else
      run_id="adhoc-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
  fi

  # --- 2. packet boundaries from `[orch packet:<id>]` commit trailers ---------
  # Emit the AUTHOR time in the SAME UTC `...Z` form as event timestamps so the
  # window comparison below is a sound string compare (TZ=UTC0 + format-local). We
  # print a marker header line `===ORCHCOMMIT===<TAB><date>` before each commit's
  # raw body, then scan bodies for the `[orch packet:<id>]` trailer — this avoids
  # control-char RS/FS tricks that BWK/macOS awk does not interpret portably.
  #
  # SCOPING (ADR 0019 revision): the OLD scan was `git log --all` unbounded, which
  # folded EVERY packet ever committed on ANY branch into one "run" (156 phantom
  # packets in the first production capture). We now bound the scan to the run window:
  #   - events present  -> keep `--all` (so unmerged lane branches are still seen),
  #                        but filter trailers to win_start <= commit-time <= we_bound.
  #   - no events        -> fall back to a branch range `<integration_branch>..HEAD`
  #                        (mirrors runstate.sh reconstruct) so a lane at least scopes
  #                        to its own commits; `--all` only as a last resort.
  #
  # UPPER BOUND (phantom-packet fix): this bound used to be applied ONLY when --until
  # was explicit, on the assumption that "collection happens at end-of-run, so nothing
  # legit is after". That assumption fails for RETROSPECTIVE collection — exactly what
  # `/gaffer:metrics analyze` invites — and every run then absorbed every packet
  # committed after it. Observed: an 11-minute session reporting 45 packets, a 19-tool-
  # call session reporting 22, packet lists running to the repo's newest commit days
  # later. 12 of 19 captured runs across two consumer repos were inflated 2x-45x.
  # The bound is now ALWAYS enforced. The original concern is real but small, so it is
  # handled with a grace margin instead of an open end: a run's last packet commits
  # just AFTER its last tool event (the commit itself produces no tool event once the
  # loop hands off), so allow ORCH_METRICS_TRAILER_GRACE seconds past win_end.
  #
  # NEXT-SESSION CAP (ADR 0019 v3.2). A flat grace is only safe when THIS run is the
  # only thing running. In a repo with overlapping or back-to-back sessions the grace
  # reaches straight into the next session and claims its commits: measured in a real
  # consumer repo as 7 phantom rows out of 37, including 6 duplicated packet ids —
  # e.g. a session whose events ended 15:26 absorbed packets committed at 16:02/16:04
  # by a session that was running CONCURRENTLY. So cap the grace at the earliest event
  # belonging to any OTHER session after win_end. This handles both shapes: a
  # back-to-back session (its first event cuts the grace short) and a concurrent one
  # (it already has events just past our win_end, so the bound collapses to ~win_end).
  # When nothing else is running the full grace still applies, which is the case the
  # grace exists for. `--until` still wins verbatim — tests and manual scoping rely on
  # it being honoured exactly.
  local log_revs="--all" we_bound=""
  if [ -n "$win_start" ]; then
    if [ -n "$opt_until" ]; then
      we_bound="$win_end"                             # explicit --until wins verbatim
    else
      we_bound="$(iso_plus "$win_end" "${ORCH_METRICS_TRAILER_GRACE:-3600}")"
      local next_evt
      next_evt="$(next_foreign_event "$agents" "$tmp/sids.txt" "$win_end")"
      # string compare is sound: both are the same fixed-width UTC ...Z form
      if [ -n "$next_evt" ] && [ "$next_evt" \< "$we_bound" ]; then we_bound="$next_evt"; fi
    fi
  else
    local base="$integ"
    if [ -z "$base" ]; then
      local b
      for b in develop main master; do
        if git -C "$main_root" show-ref --verify --quiet "refs/heads/${b}"; then base="$b"; break; fi
      done
    fi
    if [ -n "$base" ] && git -C "$main_root" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
      log_revs="${base}..HEAD"
    fi
  fi
  : > "$tmp/packets_raw.tsv"
  # AUTHOR date, not committer date (ADR 0019 v3.2). Committer date is REWRITTEN by
  # rebase, cherry-pick, amend and squash-merge, so a packet's recorded time drifts to
  # whenever the branch was last replayed rather than when the work was done. Measured
  # in a real consumer repo: six packets authored 08:29-13:04 were folded into a run
  # that started at 13:56 because their MERGE commits landed inside its window, while a
  # packet genuinely committed in-window with a valid trailer went missing. Author date
  # survives every one of those rewrites. Traversal order is `--author-date-order` for
  # coherence only — correctness does not depend on it, since the per-packet reduction
  # below re-sorts on the emitted date column.
  # shellcheck disable=SC2086  # log_revs is an intentional word-split rev argument
  TZ=UTC0 git -C "$main_root" log $log_revs --author-date-order \
      --date=format-local:'%Y-%m-%dT%H:%M:%SZ' \
      --format='===ORCHCOMMIT===%x09%ad%n%B' 2>/dev/null \
    | awk -F'\t' -v ws="$win_start" -v we="$we_bound" '
        # Only a trailer on its OWN line counts (that is how commits/pause-check
        # emit it). This excludes prose that merely mentions the trailer format,
        # e.g. a doc commit saying "...the `[orch packet:<id>]` trailer...".
        # ADR 0019 (routing self-label): a commit may also carry two OPTIONAL
        # trailers on their own lines — `[orch tier:mechanical|integration|
        # design-heavy]` and `[orch impl:inline|delegated]` — the factual routing
        # decision recorded by the executor at the green gate. Buffer them per
        # commit and emit together with the packet trailer; absent -> empty.
        function flush() {
          # run-window filter: win_start <= d <= we_bound. BOTH bounds are always set
          # when events exist (we_bound = win_end + grace, or --until verbatim).
          if (pk != "" && d != "" && (ws=="" || d>=ws) && (we=="" || d<=we))
            print pk "\t" d "\t" tier "\t" impl
          pk=""; tier=""; impl=""
        }
        /^===ORCHCOMMIT===/ { flush(); d=$2; next }
        /^[[:space:]]*\[orch packet:[^]]+\][[:space:]]*$/ {
          if (match($0, /\[orch packet:[^]]+\]/)) {
            v=substr($0, RSTART+13, RLENGTH-14)     # strip "[orch packet:" .. "]"
            gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); pk=v
          }
        }
        /^[[:space:]]*\[orch tier:[^]]+\][[:space:]]*$/ {
          if (match($0, /\[orch tier:[^]]+\]/)) {
            v=substr($0, RSTART+11, RLENGTH-12); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); tier=v
          }
        }
        /^[[:space:]]*\[orch impl:[^]]+\][[:space:]]*$/ {
          if (match($0, /\[orch impl:[^]]+\]/)) {
            v=substr($0, RSTART+11, RLENGTH-12); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); impl=v
          }
        }
        END { flush() }' >> "$tmp/packets_raw.tsv" 2>/dev/null || true

  # keep the LATEST commit time per packet id, then order packets ascending.
  # emit JSON array: [{id, end}] ordered by end.
  if [ -s "$tmp/packets_raw.tsv" ]; then
    sort "$tmp/packets_raw.tsv" \
      | awk -F'\t' '{ last[$1]=$0 } END { for (k in last) print last[k] }' \
      | sort -t$'\t' -k2,2 \
      | jq -R -s 'split("\n")|map(select(length>0))|map(split("\t"))
                  |map({id:.[0], end:.[1],
                        tier:((.[2]//"")|if .=="" then null else . end),
                        impl:((.[3]//"")|if .=="" then null else . end)})' \
      > "$tmp/pk_ends.json" 2>/dev/null || echo '[]' > "$tmp/pk_ends.json"
  else
    echo '[]' > "$tmp/pk_ends.json"
  fi

  # --- 3. ATTESTED packet boundaries + outcomes (ADR 0019 v3.4, loop-measurement T4) -
  # Optional, append-only, written by the loop via `runstate.sh record-start` /
  # `record-outcome` / `sweep-open` at each packet boundary — including boundaries
  # that do NOT produce a commit, which is the entire point. The collector cannot
  # observe outcome from git alone: it reconstructs packets from green-commit
  # trailers, so a rolled-back or never-committed packet leaves no trace there.
  #
  # Deliberately NOT run-state: run-state has a single writer (the driver) and this must
  # be writable from a lane without contending for it — the same reasoning that kept
  # packet boundaries on commit trailers rather than migrating run-state's schema.
  #
  # A packet has STARTED in this run when the run's window holds a start record, a
  # continuation record, a commit trailer for it, OR an outcome record attributed to
  # the run (loop-measurement T4). Its outcome is the LAST record attributed to the
  # run at-or-after its latest start/continuation (falling back to the last outcome
  # record overall when no boundary record is attributed — the pre-T1 shape, where a
  # trailer-only packet's outcome came from whatever outcome log existed for it).
  #
  # ATTRIBUTION, not FILE SELECTION (the bug this section exists to avoid). An
  # `interrupted`/`abandoned` record is written by a LATER session's `sweep-open`, into
  # THAT session's own log file — but its `ts`/`session` fields are copied VERBATIM from
  # the start/continuation it closes. So this run's records can legitimately live in a
  # log file this run never wrote to, and the old file-name-based selection (loop over
  # sids.txt, `cat "$ocdir/$_sid.jsonl"`) would silently miss them. Every outcomes log in
  # the repo is now read (mirroring `runstate.sh sweep-open`'s own directory scan), and
  # each record's EFFECTIVE session is `.session` when present, else the log FILE's own
  # name (`_file_sid`) — which is exactly how a pre-T1 record (no `session` field, because
  # `record-outcome` always wrote into its own session's file before T1) still scopes
  # correctly. A record is attributed to this run when its effective session is one of
  # the selected sessions (or, with no event spine at all — the structural fallback below
  # — every file, since there is no session to select) AND its `ts` falls in
  # [win_start, we_bound] — same two-way scoping as every other join here, so a foreign
  # session's or an out-of-window record still cannot bleed into this run's verdict
  # (v3/v3.2 fixed the identical cross-run bleed for commit trailers).
  #
  # TIMES ARE PARSED, NEVER STRING-COMPARED (loop-measurement T4 finding): boundary and
  # outcome records carry a SUB-SECOND stamp (`runstate.sh _rs_now_ts`), and
  # "...:08.311Z" sorts BELOW "...:08Z" as a raw string ("." is 0x2E, "Z" is 0x5A) —
  # inverting same-second ordering. `$JQ_TS_MS` (defined above) is spliced into every
  # program below instead.
  echo '{}' > "$tmp/outcomes.json"
  local ocdir="${agents}/metrics/outcomes"
  : > "$tmp/records_raw.ndjson"
  if [ -d "$ocdir" ]; then
    local _of _ofsid
    for _of in "$ocdir"/*.jsonl; do
      [ -e "$_of" ] || continue
      _ofsid="$(basename "$_of" .jsonl)"
      # jq (no -s) streams one filtered value per input value, so this appends one
      # annotated line per record without slurping the whole repo's outcomes history
      # into memory at once.
      jq -c --arg fsid "$_ofsid" '. + {_file_sid: $fsid}' "$_of" 2>/dev/null >> "$tmp/records_raw.ndjson" || true
    done
  fi

  # attributed.json: every record (boundary or terminal), from every log, scoped to
  # THIS run by (effective session, parsed ts) as described above.
  jq -s "${JQ_TS_MS}"'
    ($sids[0] // []) as $sset
    | (if $ws == "" then null else ($ws|ts_ms) end) as $wsm
    | (if $we == "" then null else ($we|ts_ms) end) as $wem
    | map(select(.packet != null and .ts != null))
    | map(. + {_esess: (.session // ._file_sid // ""), _ms: (.ts|ts_ms)})
    | map(select(($sset|length) == 0 or (._esess as $es | ($sset | index($es)) != null)))
    | map(select($wsm == null or ._ms >= $wsm))
    | map(select($wem == null or ._ms <= $wem))
  ' --slurpfile sids "$tmp/sids.json" --arg ws "$win_start" --arg we "$we_bound" \
    "$tmp/records_raw.ndjson" > "$tmp/attributed.json" 2>/dev/null || echo '[]' > "$tmp/attributed.json"

  # recordjoin.json: {outcomes: {id:outcome}, started_ids: [id...], record_end: {id:ts},
  # swept_ids: [id...], has_start: bool}. Split from the attributed stream by field
  # shape (`kind` marks a boundary record, `outcome` marks a terminal one — same rule
  # runstate.sh's own `_rs_open_packets` uses), never by which log file a record
  # happened to land in.
  jq '
    (map(select(.kind != null))) as $boundary
    | (map(select(.outcome != null))) as $terminal
    | ($boundary | group_by(.packet)
       | map({key: .[0].packet, value: ((sort_by(._ms))[-1])}) | from_entries) as $latest_boundary
    | ($terminal | group_by(.packet) | map(
        . as $trecs
        | $trecs[0].packet as $pid
        | ($latest_boundary[$pid]._ms) as $lb
        | (if $lb != null then ($trecs | map(select(._ms >= $lb))) else $trecs end) as $eligible
        | if ($eligible | length) > 0
          then {key: $pid, value: (($eligible | sort_by(._ms))[-1])}
          else empty end
      ) | from_entries) as $winning_terminal
    | ($winning_terminal | map_values(.outcome)) as $outcomes
    | ((($boundary | map(.packet)) + ($terminal | map(.packet))) | unique) as $started
    | (($boundary + $terminal) | group_by(.packet)
       | map({key: .[0].packet, value: ((sort_by(._ms))[-1].ts)}) | from_entries) as $record_end
    # SWEPT (C1): sweep-open closes an open packet by copying the boundary ts
    # VERBATIM into the terminal record it writes (that verbatim copy is what
    # makes the close idempotent, see the comment above section 3). A terminal
    # record whose _ms is BYTE-IDENTICAL to the latest boundary it closes
    # therefore carries no information about how long the packet actually ran; a
    # terminal recorded directly (record-outcome id abandoned, not via sweep)
    # carries its own real ts and does NOT match. Detected by ts equality, not
    # by outcome value, since abandoned can come from either path.
    | ($winning_terminal | to_entries
       | map(select(.value._ms == ($latest_boundary[.key]._ms)))
       | map(.key)) as $swept_ids
    | { outcomes: $outcomes, started_ids: $started, record_end: $record_end,
        swept_ids: $swept_ids,
        has_start: (($boundary | map(select(.kind == "start")) | length) > 0) }
  ' "$tmp/attributed.json" > "$tmp/recordjoin.json" 2>/dev/null \
    || echo '{"outcomes":{},"started_ids":[],"record_end":{},"swept_ids":[],"has_start":false}' > "$tmp/recordjoin.json"

  jq -c '.outcomes // {}' "$tmp/recordjoin.json" > "$tmp/outcomes.json" 2>/dev/null || echo '{}' > "$tmp/outcomes.json"

  # merge record-only packet ids (no trailer — never committed, or a still-open
  # interruption) into pk_ends.json, ordered by PARSED end time (see above; a
  # trailer's whole-second end and a record's sub-second end must not be
  # string-compared). Trailer ids keep their trailer end/tier/impl unchanged.
  # `swept` (C1) carries forward so section 5 can null the derived metrics rather
  # than report a lying zero for a packet whose window collapsed to a point.
  jq -s "${JQ_TS_MS}"'
    .[0] as $trailer_pk
    | .[1] as $rj
    | ($trailer_pk | map(.id)) as $trailer_ids
    | (($rj.started_ids // []) | map(select(. as $i | ($trailer_ids | index($i)) == null))) as $extra_ids
    | ($extra_ids | map({id: ., end: ($rj.record_end[.] // null), tier: null, impl: null,
                          swept: ((($rj.swept_ids // []) | index(.)) != null)})
                  | map(select(.end != null))) as $extra_entries
    | ($trailer_pk + $extra_entries)
    | sort_by(.end | ts_ms)
  ' "$tmp/pk_ends.json" "$tmp/recordjoin.json" > "$tmp/pk_ends_merged.json" 2>/dev/null \
    && mv "$tmp/pk_ends_merged.json" "$tmp/pk_ends.json" || true

  # --- 4. tokens per turn (ADR 0019 v2) --------------------------------------
  # Emit ONE record per assistant turn: {role, ts, model, tok}. Per-turn `ts` lets us
  # bucket tokens into packet windows (per-packet split); `model` enables per-model
  # cost attribution (opus vs sonnet vs haiku are not comparable by raw token count).
  # Fail soft to structural-only; `ts` may be absent (older transcript) -> per-packet
  # tokens degrade to null while run/role totals stay intact.
  : > "$tmp/turns.ndjson"
  local token_source="none" tfiles=0
  while IFS= read -r sid; do
    # Belt-and-braces against the CRLF trap documented at the sids.txt write above:
    # strip ANY CR so a jq-fed list that skipped the source normalization still
    # cannot silently produce a glob that matches nothing.
    sid="$(printf '%s' "$sid" | tr -d '\r')"
    [ -n "$sid" ] || continue
    for mf in "$projects_dir"/*/"$sid".jsonl; do
      [ -e "$mf" ] || continue
      tfiles=$((tfiles + 1))
      jq -c --arg aid "main:$sid" 'select((.message.usage // .usage) != null)
        | {role:"main", aid:$aid, id:(.message.id // null),
           ts:(.timestamp // null), model:(.message.model // .model // null),
           effort:(.effort // null),
           tok:((.message.usage // .usage) | {input:(.input_tokens//0), output:(.output_tokens//0),
                cache_creation:(.cache_creation_input_tokens//0), cache_read:(.cache_read_input_tokens//0)})}' \
        "$mf" 2>/dev/null >> "$tmp/turns.ndjson" || true
    done
    for sf in "$projects_dir"/*/"$sid"/subagents/agent-*.jsonl; do
      [ -e "$sf" ] || continue
      tfiles=$((tfiles + 1))
      local base aid role
      base="$(basename "$sf")"; aid="${base#agent-}"; aid="${aid%.jsonl}"
      role="$(jqr --arg a "$aid" '.[$a] // "unknown"' "$tmp/aidmap.json" 2>/dev/null)"
      [ -n "$role" ] || role="unknown"
      jq -c --arg role "$role" --arg aid "$aid" 'select((.message.usage // .usage) != null)
        | {role:$role, aid:$aid, id:(.message.id // null),
           ts:(.timestamp // null), model:(.message.model // .model // null),
           effort:(.effort // null),
           tok:((.message.usage // .usage) | {input:(.input_tokens//0), output:(.output_tokens//0),
                cache_creation:(.cache_creation_input_tokens//0), cache_read:(.cache_read_input_tokens//0)})}' \
        "$sf" 2>/dev/null >> "$tmp/turns.ndjson" || true
    done
  done < "$tmp/sids.txt"
  # DEDUP BY MESSAGE ID (ADR 0019 v3.3). A transcript records the SAME assistant
  # message more than once — observed 3x for one message id, at +2ms and +26s — so
  # summing rows double-counts its usage block. Measured inflation across four real
  # sessions: cacheCreation 2.3x-3.2x, output 3.3x-6.3x. The two rates DIFFER, and
  # differ per session, so this does NOT cancel in a ratio: CC:out read 6.4 raw vs
  # 9.0 deduped on one session and 14.9 vs 33.8 on another. Every absolute token
  # figure and every ratio was wrong until this landed. ADR 0012's own measurement
  # deduplicated by message id; the collector never did — that gap is the bug.
  #
  # Keep the EARLIEST row per id (duplicates carry identical usage, so the choice is
  # cosmetic for totals, but it must be deterministic for the invalidation scan,
  # which reads per-turn ts). Rows with no message id are kept verbatim: `.uuid` is
  # per-ROW, not per-message, so keying on it would silently dedupe nothing while
  # looking like it worked — better to under-dedupe than to invent collisions.
  # Order is not preserved and does not need to be: every consumer either groups or
  # sorts by ts itself.
  jq -s '
      ( map(select(.id != null)) | group_by(.id) | map(sort_by(.ts // "") | .[0]) )
    + ( map(select(.id == null)) )
  ' "$tmp/turns.ndjson" > "$tmp/turns_raw.json" 2>/dev/null || echo '[]' > "$tmp/turns_raw.json"

  # WINDOW-BLEED FIX (ADR 0019): the event spine and the trailer scan are bounded to
  # the run window, but the transcript files above are read WHOLE. A session whose
  # transcript holds a long prior conversation (e.g. a 2-minute /metrics run reusing a
  # day-old transcript) would fold all that out-of-window history into the run/role/
  # model totals — this is the "501k phantom output on a 122s no-op" bug. Bound token
  # turns to the SAME [win_start, win_end] the rest of the collector uses. Compared at
  # second precision (.ts[0:19]) so sub-second transcript timestamps cannot straddle a
  # boundary against the seconds-precision event/commit times. ts==null turns are KEPT
  # (older transcripts with no per-turn ts still yield intact run/role totals, per the
  # fail-soft contract at step 4). `<synthetic>` turns are non-API injected messages
  # that carry no real usage and only add a noisy empty by_model bucket — drop them.
  jq --arg ws "$win_start" --arg we "$win_end" '
    map(select((.model // "") != "<synthetic>"))
    | map(select(.ts == null
                 or ((.ts[0:19] >= ($ws[0:19])) and ($we == "" or .ts[0:19] <= ($we[0:19])))))
  ' "$tmp/turns_raw.json" > "$tmp/turns.json" 2>/dev/null || cp "$tmp/turns_raw.json" "$tmp/turns.json"

  # per-role totals + per-model split within role, PLUS the cache-creation shape.
  #
  # cc_shape exists because the totals are too noisy to steer by. Measured across four
  # untouched same-regime sessions, coordinator cacheCreation-per-packet spans 1.76x
  # (9x across all sessions) — so a change that trims ~150k of standing context is
  # invisible underneath ordinary run-to-run variation.
  #
  # The shape is not noisy, because it separates the two things the total conflates.
  # A coordinator turn is either steady-state (a small delta appended to a warm cache)
  # or a full re-cache of everything it is holding. Measured per session, the MEDIAN
  # turn is flat everywhere — 1,893 / 2,105 / 2,130 / 3,500 / 4,683 — while `max`
  # separates cleanly by regime: 24,190 on the cheap July session against 147,817 /
  # 198,397 / 221,962 / 239,851 on the expensive ones. `max`/`p90` therefore read the
  # size of the standing context itself, which is the thing a read-list or run-state
  # diet actually changes, and they move by more than their own spread when it does.
  #
  # Read them as: median = incremental cost of one more turn; p90/max = what it costs
  # to rebuild this role's context once. A high max with a flat median is not "an
  # expensive agent" — it is a large payload being re-cached.
  jq '
    def sumtok(f): {input:(map(f.input)|add//0), output:(map(f.output)|add//0),
                    cache_creation:(map(f.cache_creation)|add//0), cache_read:(map(f.cache_read)|add//0)};
    def pctl(s; p): if (s|length) == 0 then null else s[((s|length) * p | floor) | if . >= (s|length) then (s|length)-1 else . end] end;
    group_by(.role) | map({
      key: .[0].role,
      value: {
        tokens: (map(.tok) | sumtok(.)),
        models: (group_by(.model) | map(select(.[0].model != null))
                 | map({key:(.[0].model), value:(map(.tok)|sumtok(.))}) | from_entries),
        cc_shape: ((map(.tok.cache_creation) | sort) as $s
                   | { turns: ($s|length),
                       median: pctl($s; 0.5), p90: pctl($s; 0.9), max: ($s|max),
                       # how concentrated the spend is: a coordinator re-caching a large
                       # payload puts ~87% of a dispatch above 50k in <10% of its turns.
                       turns_over_50k: ($s | map(select(. > 50000)) | length),
                       cc_over_50k:    ($s | map(select(. > 50000)) | add // 0) })
      }}) | from_entries
  ' "$tmp/turns.json" > "$tmp/roletokens.json" 2>/dev/null || echo '{}' > "$tmp/roletokens.json"

  # by_model rollup (run-wide) — the cost-normalization surface
  jq '
    def sumtok(f): {input:(map(f.input)|add//0), output:(map(f.output)|add//0),
                    cache_creation:(map(f.cache_creation)|add//0), cache_read:(map(f.cache_read)|add//0)};
    group_by(.model) | map(select(.[0].model != null))
    | map({key:(.[0].model), value:(map(.tok)|sumtok(.))}) | from_entries
  ' "$tmp/turns.json" > "$tmp/bymodel.json" 2>/dev/null || echo '{}' > "$tmp/bymodel.json"

  # by_effort rollup (ADR 0019 v3.2). Reasoning effort is a per-turn request parameter
  # the user can change mid-session; nothing else in the packet records it, so a run
  # spanning two effort levels was previously indistinguishable from one that did not.
  # Null on transcripts that predate the field — an absent bucket, never a zero.
  jq '
    def sumtok(f): {input:(map(f.input)|add//0), output:(map(f.output)|add//0),
                    cache_creation:(map(f.cache_creation)|add//0), cache_read:(map(f.cache_read)|add//0)};
    group_by(.effort) | map(select(.[0].effort != null))
    | map({key:(.[0].effort), value:((map(.tok)|sumtok(.)) + {turns: length})}) | from_entries
  ' "$tmp/turns.json" > "$tmp/byeffort.json" 2>/dev/null || echo '{}' > "$tmp/byeffort.json"

  # context_invalidations (ADR 0019 v3.2) — the cost of CHANGING a request parameter,
  # as distinct from the cost of its value. Changing `effort` or the model mid-context
  # invalidates the cached prefix, so the whole context is re-written to cache on the
  # next turn. Measured in production: three such flips cost 372,588 / 380,005 /
  # 115,509 cache-creation tokens against session medians of 1,380 / 856 / ~1,700 —
  # 270x, 444x and 68x. It fires in BOTH directions (high->xhigh AND xhigh->high), which
  # is what identifies it as invalidation rather than "higher effort costs more"; the
  # size tracks how deep into the context the flip happens, not which way it went.
  #
  # Scanned per (role, aid) — one agent context — and NOT per role. Two dispatches of
  # the same role are separate contexts, so an implementer that ran opus once and
  # sonnet once is normal tier routing, not a mid-context switch; grouping by role
  # alone would report it as an invalidation. Turns with no ts cannot be ordered and
  # are excluded, so this degrades to 0 rather than guessing on older transcripts.
  jq '
    [ group_by([.role, .aid])[]
      | (map(select(.ts != null)) | sort_by(.ts)) as $t
      | range(1; ($t | length)) as $i
      | select( (($t[$i].effort // "") != ($t[$i-1].effort // ""))
             or (($t[$i].model  // "") != ($t[$i-1].model  // "")) )
      | { role: $t[$i].role, ts: $t[$i].ts,
          from: { effort: $t[$i-1].effort, model: $t[$i-1].model },
          to:   { effort: $t[$i].effort,   model: $t[$i].model   },
          cache_creation: ($t[$i].tok.cache_creation // 0) } ]
    | sort_by(.ts)
    | { count: length,
        cache_creation: (map(.cache_creation) | add // 0),
        events: .[0:20] }
  ' "$tmp/turns.json" > "$tmp/ctxinval.json" 2>/dev/null \
    || echo '{"count":0,"cache_creation":0,"events":[]}' > "$tmp/ctxinval.json"

  if jq -e 'map(.tok.input+.tok.output+.tok.cache_read+.tok.cache_creation)|add>0' "$tmp/turns.json" >/dev/null 2>&1; then
    token_source="transcript"
  fi
  local turns_have_ts; turns_have_ts="$(jqr 'any(.ts != null)' "$tmp/turns.json" 2>/dev/null || echo false)"

  # --- 4b. token diagnostics: make a `none` stamp DIAGNOSABLE -----------------
  # `token_source=none` used to conflate three completely different failures, and
  # the emitted note asserted "no transcript found" in all of them — actively
  # misleading when transcripts were sitting on disk (that wording cost a half-hour
  # bisect on the Windows CRLF bug). Record the counts that separate them:
  #   files_present=0                      -> genuinely nothing on disk
  #   files_present>0, files_matched=0     -> LOOKUP is broken (id mismatch/glob bug)
  #   files_matched>0, usage_turns=0       -> the on-disk FORMAT changed (ADR 0019)
  #   usage_turns>0, in_window=0           -> the WINDOW is wrong, not the parse
  # Counts only — no paths — so the packet stays safe to hand to Claude.
  local tpresent=0 _tf
  for _tf in "$projects_dir"/*/*.jsonl; do [ -e "$_tf" ] && tpresent=$((tpresent + 1)); done
  for _tf in "$projects_dir"/*/*/subagents/agent-*.jsonl; do [ -e "$_tf" ] && tpresent=$((tpresent + 1)); done
  local turns_raw turns_win
  turns_raw="$(jqr 'length' "$tmp/turns_raw.json" 2>/dev/null || echo 0)"
  turns_win="$(jqr 'length' "$tmp/turns.json" 2>/dev/null || echo 0)"
  case "$turns_raw" in ''|*[!0-9]*) turns_raw=0 ;; esac
  case "$turns_win" in ''|*[!0-9]*) turns_win=0 ;; esac
  # Rows the message-id dedup removed (ADR 0019 v3.3). Surfaced, not hidden: a
  # sudden move toward 0 means the transcript stopped repeating messages OR stopped
  # carrying `message.id` — the second silently disables the dedup, and the packet
  # would re-inflate ~2.6x while still stamping token_source=transcript.
  local turns_dup=0
  turns_dup="$(wc -l < "$tmp/turns.ndjson" 2>/dev/null | tr -d ' ')"
  case "$turns_dup" in ''|*[!0-9]*) turns_dup=0 ;; esac
  turns_dup=$(( turns_dup - turns_raw )); [ "$turns_dup" -ge 0 ] 2>/dev/null || turns_dup=0

  # ATTRIBUTION CONFIDENCE (ADR 0019): role='unknown' is a subagent transcript whose
  # agent_id was never seen in the event spine, so it could not be mapped to a role
  # (aidmap miss at step 4). Quantify its share instead of burying it; if it dominates
  # the output split, DOWNGRADE the stamp to `transcript-degraded` so show/analyze flag
  # the per-role/model split as low-confidence rather than presenting it as clean. This
  # is the self-reporting reconcile check that turns silent fragility into a loud note.
  local unknown_note=""
  if [ "$token_source" = "transcript" ]; then
    local unknown_out total_out
    unknown_out="$(jqr '(.unknown.tokens.output // 0)' "$tmp/roletokens.json" 2>/dev/null || echo 0)"
    total_out="$(jqr '[.[].tokens.output // 0] | add // 0' "$tmp/roletokens.json" 2>/dev/null || echo 0)"
    case "$unknown_out$total_out" in *[!0-9]*) unknown_out=0; total_out=0 ;; esac
    if [ "${total_out:-0}" -gt 0 ] && [ "${unknown_out:-0}" -gt 0 ]; then
      local unknown_pct=$(( unknown_out * 100 / total_out ))
      unknown_note="attribution: ${unknown_pct}% of output tokens are role='unknown' (subagent transcripts whose agent_id was absent from the event spine)."
      [ "$unknown_pct" -ge 10 ] && token_source="transcript-degraded"
    fi
  fi

  # --- 5. per-packet windows + event/token rollup ----------------------------
  # Contiguous windows: start = prev end (or run_start), end = trailer commit time;
  # roll up events whose ts falls in (start, end], plus per-packet active_seconds
  # (idle-gap-aware) and per-packet tokens (from turns with a ts in the window).
  jq \
     --slurpfile ev "$tmp/events.json" \
     --slurpfile outc "$tmp/outcomes.json" \
     --slurpfile turns "$tmp/turns.json" \
     --argjson gap "$idle_gap" \
     --arg have_ts "$turns_have_ts" \
     --arg run_start "$win_start" \
     "${JQ_TS_MS}"'
     def sumtok(f): {input:(map(f.input)|add//0), output:(map(f.output)|add//0),
                     cache_creation:(map(f.cache_creation)|add//0), cache_read:(map(f.cache_read)|add//0)};
     . as $ends
     | ($ev[0] // []) as $events
     | ($turns[0] // []) as $turns
     | ($outc[0] // {}) as $outcomes
     | ($have_ts=="true") as $ts_ok
     # Does this run use the tier/impl convention at ALL? A run where NO packet
     # carries a label predates the convention (or ran with it off) — flagging
     # every packet there is noise, not signal, so the unlabelled flags below are
     # suppressed wholesale and the run-level note carries the caveat instead.
     # A run where SOME packets are labelled and others are not is the real
     # discipline gap, and those stragglers DO get flagged.
     | (. | any(.tier != null or .impl != null)) as $run_labelled
     | reduce range(0; length) as $i ([];
         . as $acc
         | $ends[$i] as $p
         | (if $i==0 then ($run_start // $p.end) else $ends[$i-1].end end) as $start
         # PARSED, not string-compared (loop-measurement T4/T8 finding, I1): $start/
         # $p.end can be sub-second (record-only packet boundaries) while event ts is
         # always whole-second, and "...:05Z" > "...:05.500Z" as a raw string — the
         # same inversion $JQ_TS_MS exists to fix everywhere else in this file.
         | ($start | ts_ms) as $start_ms
         | ($p.end | ts_ms) as $end_ms
         | ($events | map(select(.ts != null and ((.ts|ts_ms) > $start_ms) and ((.ts|ts_ms) <= $end_ms)))) as $win
         | (($win | map(.ts) | sort | map(fromdateiso8601)) as $wt
            | reduce range(0; ($wt|length)-1) as $k (0;
                . + (($wt[$k+1]-$wt[$k]) as $d | if $d>$gap then 0 else $d end))) as $active
         | ($turns | map(select($ts_ok and .ts != null and ((.ts|ts_ms) > $start_ms) and ((.ts|ts_ms) <= $end_ms)))) as $wtok
         # ROUTING AUDIT (ADR 0019): who actually wrote code, and what was dispatched,
         # so the executor self-label (tier/impl) can be cross-checked against reality.
         # Same write surface as guard.sh and hooks/metrics-log.sh — keep all three in
         # step. MultiEdit was absent here, so multi-edit work read as zero edits.
         | ($win | map(select(.tool=="Edit" or .tool=="Write" or .tool=="MultiEdit" or .tool=="NotebookEdit"))
                 | group_by(.agent_type) | map({key:(.[0].agent_type),value:length}) | from_entries) as $edits
         | ($win | map(select(.tool=="Agent" and (.subagent_type != null)))
                 | group_by(.subagent_type) | map({key:(.[0].subagent_type),value:length}) | from_entries) as $disp
         # orchestrator implementation edits = code writes by roles that are SUPPOSED
         # to delegate (the opus top-level loop + chief-engineer), not the architect/
         # ux-designer (whose edits are their own legitimate domain).
         | (($edits["main"]//0) + ($edits["gaffer:chief-engineer"]//0)) as $orch_edits
         | (($disp["gaffer:implementer"]//0) > 0) as $impl_dispatched
         | (($disp["gaffer:reviewer"]//0)) as $rev
         | ([ (if ($orch_edits>0 and ($impl_dispatched|not)) then "leak:orchestrator-edited-on-opus-without-delegating(\($orch_edits))" else empty end),
              (if ($p.impl=="delegated" and ($impl_dispatched|not)) then "label-contradiction:impl=delegated-but-no-implementer-dispatch" else empty end),
              (if ($p.tier=="mechanical" and $orch_edits>0) then "waste:mechanical-tier-edited-inline-on-opus" else empty end),
              (if ($p.tier=="integration" and $orch_edits>0) then "waste:integration-tier-edited-inline-on-opus" else empty end),
              (if ($p.tier=="docs" and $orch_edits>0) then "waste:docs-tier-edited-inline-on-opus-not-doc-writer" else empty end),
              (if ($p.tier=="design-heavy" and $rev>1) then "suspect:design-heavy-label-with-\($rev)-review-rounds" else empty end),
              # run-loop §3.2/§3.4 make both trailers required; without them the
              # routing for this packet is unmeasurable and every check above
              # silently no-ops (a null tier matches none of them). Say so
              # explicitly rather than letting an unlabelled packet read as clean.
              (if ($run_labelled and $p.tier == null) then "unlabelled:no-tier-trailer" else empty end),
              (if ($run_labelled and $p.impl == null) then "unlabelled:no-impl-trailer" else empty end)
            ]) as $flags
         # SWEPT (C1, loop-measurement T4/T8 finding). `sweep-open` closes an open
         # packet by copying its boundary ts VERBATIM (that is what makes the close
         # idempotent) — so for a swept packet $p.end == the ts it STARTED at, and
         # $win above collapses to a zero-width window: every derived count below
         # would read a real, honest 0. A reader cannot tell that from "this packet
         # genuinely did nothing", which is the opposite of what an interrupted
         # packet means. Report the derived fields as null (unmeasured), not 0 —
         # same rule as the pre-instrumentation-run nulls elsewhere in this file.
         | ($p.swept == true) as $is_swept
         | {
             id: $p.id,
             # OUTCOME IS NOT OBSERVABLE, AND MUST NOT CLAIM TO BE (ADR 0019 v3.4).
             # This read "green" unconditionally. It was not a measurement: a packet
             # EXISTS here only because a `[orch packet:]` trailer was found, and that
             # trailer is written on a green commit — so failed, abandoned and
             # rolled-back work has no trailer and never becomes a row at all. "42 of
             # 42 green" was survivorship restated as quality, and the more work a run
             # threw away the healthier it looked.
             #
             # Emitting null is the honest floor: an analysis can then say "unknown"
             # instead of inferring a success rate from a filter. Attesting it needs a
             # writer at the packet boundary (the loop knows the outcome; the collector
             # never can), which is why this reads an OPTIONAL outcomes log rather than
             # guessing — absent log, absent claim.
             outcome: ($outcomes[$p.id] // null),
             tier: $p.tier,
             impl: $p.impl,
             start: $start,
             end: $p.end,
             tool_calls: ($win|length),
             active_seconds: ($active|floor),
             duration_ms: ($win|map(.duration_ms//0)|add),
             by_agent: ($win|group_by(.agent_type)|map({key:(.[0].agent_type),value:length})|from_entries),
             by_tool: ($win|group_by(.tool)|map({key:(.[0].tool),value:length})|from_entries),
             # EDIT OVERLAP (ADR 0019 v3.4). Counting edits per role cannot tell
             # correction from division of labour: "implementer 34, main 3" is either
             # the orchestrator fixing the implementer or the two working on separate
             # files, and those have opposite meanings for a rework rate. Overlap on
             # the SAME file is what separates them.
             #
             # Values are opaque hashes from the hook (never paths), so this reports
             # SHAPE only — how many distinct files, how many were touched by more than
             # one role, and by which roles. `contended_files` is the rework signal;
             # `files_touched` is its denominator. Both null when no edit in this packet
             # carried a hash, i.e. a run predating the field — never 0, which would
             # read as "measured, no overlap".
             edits: (($win | map(select(.file_hash != null))) as $fe
                     | if ($fe|length) == 0 then null
                       else ($fe | group_by(.file_hash)
                             | map({roles: (map(.agent_type) | unique)})) as $byfile
                         | { edits: ($fe|length),
                             files_touched: ($byfile|length),
                             contended_files: ($byfile | map(select((.roles|length) > 1)) | length),
                             contended_by: ($byfile | map(select((.roles|length) > 1))
                                            | map(.roles | join("+")) | group_by(.)
                                            | map({key:.[0], value:length}) | from_entries) }
                       end),
             # REWORK PROXY (ADR 0019): per-packet command classes. The payload carries no
             # exit code, so repeat invocations are the reliable signal — a packet that ran
             # `dotnet test` 5 times almost certainly failed 4 of them. Read alongside
             # failed_tool_calls (derived from the response SHAPE, see hook) and
             # dispatched[] (a second implementer/reviewer dispatch = an explicit fix round).
             by_command_class: ($win|map(select(.cmd_class != null))|group_by(.cmd_class)
                                |map({key:(.[0].cmd_class),value:length})|from_entries),
             failed_tool_calls: ($win|map(select(.ok == false))|length),
             human_interactions: ($win|map(select(.tool=="AskUserQuestion"))|length),
             impl_edits_by_role: $edits,
             dispatched: $disp,
             audit: { orchestrator_impl_edits: $orch_edits, implementer_dispatched: $impl_dispatched,
                      review_dispatches: $rev, flags: $flags },
             tokens: (if $ts_ok then ($wtok|map(.tok)|sumtok(.)) else null end)
           } as $obj
         | $acc + [
             if $is_swept then
               ($obj + {
                 swept: true,
                 end: null,
                 tool_calls: null,
                 active_seconds: null,
                 duration_ms: null,
                 by_agent: null,
                 by_tool: null,
                 edits: null,
                 by_command_class: null,
                 failed_tool_calls: null,
                 human_interactions: null,
                 impl_edits_by_role: null,
                 dispatched: null,
                 tokens: null,
                 audit: ($obj.audit + {
                   orchestrator_impl_edits: null,
                   implementer_dispatched: null,
                   review_dispatches: null,
                   flags: ($obj.audit.flags + ["unmeasured:swept-by-later-session"])
                 })
               })
             else ($obj + {swept: false})
             end
           ]
       )
     ' "$tmp/pk_ends.json" > "$tmp/packets.json" 2>/dev/null || echo '[]' > "$tmp/packets.json"

  # --- 6. unattributed: events in NO packet window (wasted/between-packet calls) --
  # PARSED, not string-compared (I1, same reasoning as section 5): a packet's
  # start/end can be sub-second while event ts is whole-second.
  jq --slurpfile pk "$tmp/packets.json" "${JQ_TS_MS}"'
    ($pk[0] // []) as $packets
    | [ .[] | . as $e | select($e.ts != null) | select( ($packets | any(.start != null and .end != null and (($e.ts|ts_ms) > (.start|ts_ms)) and (($e.ts|ts_ms) <= (.end|ts_ms)))) | not ) ]
    | { count: length, by_agent: (group_by(.agent_type)|map({key:(.[0].agent_type),value:length})|from_entries) }
  ' "$tmp/events.json" > "$tmp/unattributed.json" 2>/dev/null || echo '{"count":0,"by_agent":{}}' > "$tmp/unattributed.json"

  # --- 6b. same-file overlap between file-editing agents (retire-unused-loop-modes T3) -
  # Parallel worktree isolation used to guarantee file-disjointness MECHANICALLY, by
  # scheduling — that guarantee is gone, so this is the observability that replaces it:
  # a run-level count of how often the main session and a dispatched subagent actually
  # edited the SAME file. Derived entirely from events the hook already writes (no new
  # hook field): a subagent's SPAN is its first-to-last recorded event (any tool, not
  # just edits); the main session pairs with a subagent only through the main session's
  # OWN edit events whose ts falls inside that span (inclusive); the pair counts once,
  # however many file hashes they share, and ONLY subagent<->main pairs are counted —
  # two subagents are never paired against each other. Ts comparison is a plain string
  # compare here (safe: every hook event ts is the same whole-second `...Z` form; no
  # sub-second boundary/outcome record ever enters this join).
  #
  # `0` and `unmeasured` must never be conflated (this repo has already shipped a `show`
  # that rendered a null as 0 and told a legacy run it was clean): unmeasured when the
  # run has NO events at all, or when ANY Edit/Write/MultiEdit/NotebookEdit event in the
  # run is missing a file_hash (an older hook build, or a hash the hook could not
  # compute) — either makes the count unreliable, so it must not read as a clean 0.
  # Logs no file path: file_hash is the opaque 12-char token the hook already stamps,
  # so this reports SHAPE only ("did they touch the same file?"), same rule as the
  # edits/contended_files signal above.
  jq '
    def is_edit_tool: (.tool=="Edit" or .tool=="Write" or .tool=="MultiEdit" or .tool=="NotebookEdit");
    . as $all
    | ([ $all[] | select(is_edit_tool) ]) as $edits
    | if ($all|length) == 0 then
        { pairs: null, reason: "no_events", edit_events: 0, edit_events_missing_hash: 0 }
      elif ($edits | any(.file_hash == null)) then
        { pairs: null, reason: "missing_hash",
          edit_events: ($edits|length),
          edit_events_missing_hash: ($edits | map(select(.file_hash == null)) | length) }
      else
        ( $edits | map(select((.agent_id // "") != "")) | group_by(.agent_id) ) as $sub_edit_groups
        | ( $all | map(select((.agent_id // "") != "")) | group_by(.agent_id)
            | map({key: .[0].agent_id, value: {start: (map(.ts)|min), end: (map(.ts)|max)}})
            | from_entries ) as $spans
        | ( $edits | map(select((.agent_id // "") == "")) ) as $main_edits
        | ( $sub_edit_groups | map(.[0].agent_id) ) as $sub_ids
        | ( [ $sub_ids[] as $sid
              | ( $sub_edit_groups | map(select(.[0].agent_id == $sid)) | .[0] ) as $sub_own
              | ( $sub_own | map(.file_hash) | unique ) as $sub_hashes
              | ( $spans[$sid] ) as $span
              | ( $main_edits | map(select(.ts >= $span.start and .ts <= $span.end))
                  | map(.file_hash) | unique ) as $main_hashes
              | select( $sub_hashes | any(. as $h | ($main_hashes | index($h)) != null) )
            ] | length ) as $n
        | { pairs: $n, reason: null, edit_events: ($edits|length), edit_events_missing_hash: 0 }
      end
  ' "$tmp/events.json" > "$tmp/overlap.json" 2>/dev/null \
    || echo '{"pairs":null,"reason":"error","edit_events":0,"edit_events_missing_hash":0}' > "$tmp/overlap.json"

  # --- 7. assemble the packet -------------------------------------------------
  [ -n "$out" ] || out="${agents}/metrics/${run_id}/run-metrics.json"
  mkdir -p "$(dirname "$out")" 2>/dev/null || die "cannot create $(dirname "$out")"
  local generated; generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local wall=0
  [ -n "$win_start" ] && [ -n "$win_end" ] && wall=$(( $(epoch "$win_end") - $(epoch "$win_start") ))
  [ "$wall" -ge 0 ] 2>/dev/null || wall=0

  jq -n \
    --arg run_id "$run_id" \
    --arg generated "$generated" \
    --arg token_source "$token_source" \
    --arg mode "$mode" \
    --arg autonomy "$autonomy" \
    --argjson self_host "$self_host" \
    --arg run_start "$win_start" \
    --arg run_end "$win_end" \
    --argjson wall "$wall" \
    --argjson tool_calls "${tool_calls:-0}" \
    --arg transcript_dir "$([ -d "$projects_dir" ] && echo present || echo absent)" \
    --argjson tfiles "${tfiles:-0}" \
    --argjson tpresent "${tpresent:-0}" \
    --argjson turns_raw "${turns_raw:-0}" \
    --argjson turns_win "${turns_win:-0}" \
    --argjson turns_dup "${turns_dup:-0}" \
    --slurpfile packets "$tmp/packets.json" \
    --slurpfile roletokens "$tmp/roletokens.json" \
    --slurpfile bymodel "$tmp/bymodel.json" \
    --slurpfile byeffort "$tmp/byeffort.json" \
    --slurpfile ctxinval "$tmp/ctxinval.json" \
    --slurpfile activity "$tmp/activity.json" \
    --slurpfile unattr "$tmp/unattributed.json" \
    --slurpfile byskill "$tmp/byskill.json" \
    --slurpfile bytool "$tmp/bytool.json" \
    --slurpfile bycmd "$tmp/bycmd.json" \
    --slurpfile durations "$tmp/durations.json" \
    --slurpfile overlap "$tmp/overlap.json" \
    --slurpfile sids "$tmp/events.json" \
    --slurpfile recj "$tmp/recordjoin.json" \
    --arg unknown_note "$unknown_note" \
    '
    ($roletokens[0] // {}) as $rt
    | ($activity[0] // {active:0,idle:0}) as $act
    | ($unattr[0] // {count:0,by_agent:{}}) as $un
    | ($durations[0] // {total:0,by_role:{}}) as $dur
    | ($overlap[0] // {pairs:null,reason:null,edit_events:0,edit_events_missing_hash:0}) as $ov
    | ($rt | to_entries | map(.value.tokens) | {
        input:(map(.input//0)|add // 0), output:(map(.output//0)|add // 0),
        cache_read:(map(.cache_read//0)|add // 0), cache_creation:(map(.cache_creation//0)|add // 0)
      }) as $tot
    | ($tot.cache_read + $tot.cache_creation) as $cache_total
    # Was this run captured by the ok/model-aware hook? `ok` is stamped on essentially
    # every tool call, so its total absence means the run PREDATES the instrumentation.
    # Report the derived counters as null (unmeasured) rather than 0/all — otherwise a
    # legacy run reads as "zero failures, every dispatch unnamed", which is a lie.
    | (($sids[0] // []) | any(has("ok"))) as $instrumented
    | ($recj[0] // {outcomes:{}, started_ids:[], record_end:{}, has_start:false}) as $rj
    | {
      schema: 2,
      run_id: $run_id,
      generated_at: $generated,
      token_source: $token_source,
      # Why token_source reads the way it does — counts only, no paths. Read
      # top-down: dir absent < nothing on disk < nothing matched the session ids of
      # this run (LOOKUP bug) < nothing parsed (FORMAT drift) < nothing in window.
      # (No apostrophes in here: the whole program is one single-quoted shell word.)
      token_diagnostics: {
        transcript_dir: $transcript_dir,
        transcript_files_present: $tpresent,
        transcript_files_matched: $tfiles,
        usage_turns: $turns_raw,
        usage_turns_in_window: $turns_win,
        duplicate_turns_dropped: $turns_dup
      },
      mode: $mode,
      autonomy: $autonomy,
      # Purely additive (schema stays 2): a packet collected before this field
      # existed simply has no `self_host` key, and absent MUST read as UNKNOWN,
      # never as false — a legacy packet is not evidence a run was a consumer run.
      self_host: $self_host,
      sessions: ($sids[0] // [] | map(.session_id) | unique),
      window: { start: (($run_start|select(.!="")) // null), end: (($run_end|select(.!="")) // null),
                wall_seconds: $wall, active_seconds: ($act.active|floor), idle_seconds: ($act.idle|floor) },
      totals: {
        packets: ($packets[0] // [] | length),
        tool_calls: $tool_calls,
        unattributed_tool_calls: $un.count,
        unattributed_by_agent: $un.by_agent,
        duration_ms: $dur.total,
        by_role_duration_ms: $dur.by_role,
        by_tool: ($bytool[0] // {}),
        by_command_class: ($bycmd[0] // {}),
        by_skill: ($byskill[0] // {}),
        # SAME-FILE OVERLAP (retire-unused-loop-modes T3). Parallel mode used to
        # guarantee file-disjointness mechanically; this is the observability that
        # replaces it now that the guarantee is gone. null means UNMEASURED (no
        # events, or an edit event with no file_hash), never a clean 0 — see the
        # section-6b comment above for the exact pairing rule. (No apostrophes in
        # here: the whole program is one single-quoted shell word.)
        same_file_overlaps: $ov.pairs,
        same_file_overlap_diagnostics: {
          edit_events: ($ov.edit_events // 0),
          edit_events_missing_hash: ($ov.edit_events_missing_hash // 0)
        },
        tokens: $tot,
        by_model: ($bymodel[0] // {}),
        by_effort: ($byeffort[0] // {}),
        context_invalidations: ($ctxinval[0] // {count:0, cache_creation:0, events:[]}),
        cache_hit_ratio: (if $cache_total>0 then (($tot.cache_read / $cache_total)*1000|floor)/1000 else null end),
        failed_tool_calls: (if $instrumented then (($sids[0] // []) | map(select(.ok == false)) | length) else null end),
        human_interactions: (($sids[0] // []) | map(select(.tool=="AskUserQuestion")) | length),
        # OUTCOME COVERAGE (loop-measurement T5). Every STARTED packet (trailer,
        # start/continuation record, or attributed outcome record — see the T4 join
        # above) is counted exactly once here, `interrupted` included alongside the
        # other four terminal values. `outcome_counts` only tallies packets that HAVE
        # a terminal record; `started_without_outcome` is the complementary count —
        # a packet the run began but never closed (a live pause, or a crash the next
        # sweep for a later session has not yet run). `outcome_coverage` is the run-level read:
        # "unmeasured" when this run holds NO `record-start` boundary at all (every
        # run before this feature, or one where the loop never called it) — never
        # inferred from packet COUNT, since a trailer-only legacy run can have many
        # packets and zero instrumentation. "incomplete" when at least one started
        # packet lacks a terminal outcome; "complete" only when every one has one.
        # `null`/`unmeasured` must never render as clean — see `show` below.
        outcome_counts: ($packets[0] // [] | map(select(.outcome != null))
                          | group_by(.outcome) | map({key:.[0].outcome,value:length}) | from_entries),
        started_without_outcome: ($packets[0] // [] | map(select(.outcome == null)) | length),
        outcome_coverage: (if ($rj.has_start | not) then "unmeasured"
                            elif (($packets[0] // [] | map(select(.outcome == null)) | length) > 0) then "incomplete"
                            else "complete" end)
      },
      by_agent_role: $rt,
      audit: (($packets[0] // []) as $pk
        | (($sids[0] // []) | map(select(.tool=="Agent" and (.subagent_type != null)))) as $dispatches
        | {
        labels_present: ($pk | any(.tier != null or .impl != null)),
        orchestrator_impl_edits: ($pk | map(.audit.orchestrator_impl_edits // 0) | add // 0),
        implementer_dispatches: ($pk | map(.dispatched["gaffer:implementer"] // 0) | add // 0),
        # DISPATCH MODEL (corrected 2026-07-23). An omitted `model` at dispatch is
        # the NORMAL, correct case: the Agent tool resolves it to the `model:`
        # frontmatter of the target agent, and every orchestration agent declares
        # one — that frontmatter is the routing policy (run-loop §3.3). Counting
        # omissions as violations manufactured false positives (a clean run of
        # architect/reviewer dispatches read as "8 unnamed models" when all 8
        # resolved correctly to opus). What is actually worth seeing is the
        # OVERRIDE: a caller deliberately deviating from a declared tier. Ground
        # truth for what each role really ran on is `by_agent_role.<role>.models`,
        # not this field.
        dispatches_total: ($dispatches | length),
        dispatches_with_model_override: (if $instrumented then ($dispatches | map(select(.model != null)) | length) else null end),
        by_dispatch_model_override: ($dispatches | map(select(.model != null)) | group_by(.model)
                            | map({key:(.[0].model),value:length}) | from_entries),
        # TIER COVERAGE (ADR 0019). run-loop §3.2 makes `tier` a required packet
        # field and §3.4 requires copying it into the commit trailer. Packets with
        # no tier trailer are unmeasurable — surface the count and the ids rather
        # than silently shrinking the by_tier denominator.
        by_tier: ($pk | map(.tier) | map(select(. != null)) | group_by(.) | map({key:.[0],value:length}) | from_entries),
        packets_total: ($pk | length),
        packets_missing_tier: ($pk | map(select(.tier == null)) | length),
        packets_missing_impl: ($pk | map(select(.impl == null)) | length),
        unlabelled_packet_ids: ($pk | map(select(.tier == null or .impl == null)) | map(.id)),
        flagged_packets: ($pk | map(select((.audit.flags // []) | length > 0)) | map({id, tier, impl, flags:.audit.flags}))
      }),
      packets: ($packets[0] // []),
      notes: ([
        # A `none` stamp must say WHICH of the four failures happened. The old note
        # asserted "no transcript found" unconditionally, which lied whenever files
        # existed but the lookup or the window dropped them (ADR 0019 v3.1).
        (if $token_source=="none" then
           (if $transcript_dir=="absent" then
              "token_source=none: the transcript directory does not exist (--projects-dir / ORCH_METRICS_PROJECTS_DIR); structural metrics only (ADR 0019 Open Q1)."
            elif $tpresent==0 then
              "token_source=none: no transcript files on disk at all; structural metrics only (ADR 0019 Open Q1)."
            elif $tfiles==0 then
              "token_source=none: LOOKUP FAILURE — \($tpresent) transcript file(s) are on disk but NONE matched the session id(s) of this run. The parse is fine; the file resolution is not. Structural metrics only."
            elif $turns_raw==0 then
              "token_source=none: \($tfiles) transcript file(s) opened but NONE yielded a usage block — the on-disk transcript format has likely changed (ADR 0019 version-fragility). Structural metrics only."
            else
              "token_source=none: \($turns_raw) usage turn(s) parsed but 0 fell inside the run window — the WINDOW is wrong, not the parse. Structural metrics only."
            end)
         elif $token_source=="transcript-degraded" then "token_source=transcript-degraded: parse succeeded but a large share of tokens is unattributed; treat per-role/model splits as low-confidence (ADR 0019)."
         else "token_source=transcript: version-fragile on-disk parse (ADR 0019 Open Q1)." end),
        $unknown_note,
        "Per-packet token split needs per-turn transcript timestamps; packets[].tokens is null when absent.",
        "Token turns are bounded to the run window (ADR 0019 window-bleed fix); ts==null turns are kept unwindowed.",
        "Guard ASK-tier prompt frequency is not captured in v1 (PostToolUse hook sees allowed calls only).",
        "Packet rows come from [orch packet:<id>] commit trailers AND runstate.sh record-start/record-outcome/sweep-open attestations (loop-measurement T4): a packet the loop started now appears even if it never committed (failed, rolled-back) or was interrupted mid-run. totals.outcome_coverage says whether that instrumentation is present for THIS run: `unmeasured` with no record-start boundary at all (pre-feature or a non-loop run — never infer completeness from packet count), `incomplete` when a started packet still lacks a terminal outcome, `complete` otherwise.",
        (($packets[0] // []) | map(select(.swept == true)) | map(.id)) as $swept_ids
         | (if ($swept_ids|length) > 0 then
              "swept: true on \($swept_ids|length) packet(s) (\($swept_ids|join(", "))) — sweep-open closes an open packet by copying its own start ts as the close ts, so tool_calls/active_seconds/duration_ms/edits/by_agent/by_tool/by_command_class/failed_tool_calls/human_interactions/dispatched/tokens/audit counts read null there, not 0. The work happened; this collector cannot reconstruct its window from a verbatim-copied close (loop-measurement C1)."
            else empty end),
        "Trailer scan is bounded at BOTH ends: [win_start, last-event + grace] (grace=ORCH_METRICS_TRAILER_GRACE, default 3600s), or --until verbatim. Before this the upper bound was open, so a retrospective collect absorbed packets committed by every later run.",
        "Trailer times are AUTHOR dates, not committer dates (v3.2): committer date is rewritten by rebase/cherry-pick/squash-merge, which moved packets into whichever run last replayed the branch and dropped in-window work whose merge landed later.",
        "The trailer grace is CAPPED at the earliest event of any other session after win_end (v3.2), so commits made by a concurrent or back-to-back session cannot be claimed by this run; the full grace applies only when nothing else was running.",
        "by_skill is STICKY: set by the most recent slash-command/Skill invocation and never cleared, so it is an UPPER BOUND on the spend of that skill, not an exact span.",
        "totals.context_invalidations counts turns where `effort` or the model CHANGED within one agent context — each re-writes the whole cached prefix, so its cost scales with how deep in the context the change happened, not with which direction it went. An empty by_effort means the transcripts predate the per-turn `effort` field (unmeasured), not that effort never changed.",
        "by_tool is the tool-SELECTION mix (Bash/Read/Edit/Grep/...); shell `grep`/`find`/`sed` showing up in by_command_class while Grep/Glob sit at zero here is context waste, not search volume.",
        "active/idle from inter-event gaps (idle_gap_seconds); unattributed_tool_calls = events outside all packet windows.",
        "totals.same_file_overlaps counts (main session, subagent) pairs that edited the SAME file: the span of a subagent is its first-to-last event, the main session pairs with it only through its own edit events falling inside that span, and a pair counts once no matter how many files it shares. This replaces the mechanical file-disjointness guarantee parallel mode used to provide, now that the guarantee is gone; it never logs a path, only opaque file hashes.",
        (if $ov.pairs == null then
           (if $ov.reason == "no_events" then
              "same_file_overlaps=unmeasured: this run has no events."
            elif $ov.reason == "missing_hash" then
              "same_file_overlaps=unmeasured: \($ov.edit_events_missing_hash) of \($ov.edit_events) edit event(s) in this run carry no file_hash (pre-instrumentation hook, or a hash the hook could not compute)."
            else "same_file_overlaps=unmeasured." end)
         else empty end),
        "audit.* cross-checks the executor [orch tier:/impl:] self-label against who actually edited (impl_edits_by_role) and what was dispatched; leak = opus orchestrator wrote code without dispatching the implementer.",
        "audit.dispatches_with_model_override counts EXPLICIT `model` args at dispatch (a deliberate deviation). An omitted model is correct — it resolves to the `model:` frontmatter of the target agent; read by_agent_role.<role>.models for what each role actually ran on.",
        (($packets[0] // []) as $pkn
         | ($pkn | any(.tier != null or .impl != null)) as $lab
         | ($pkn | map(select(.tier == null or .impl == null)) | length) as $miss
         | if ($lab|not) then "labels: NO packet in this run carries a [orch tier:]/[orch impl:] trailer — routing is entirely UNMEASURED for this run (legacy or convention off), not clean; per-packet unlabelled flags are suppressed (run-loop §3.2/§3.4)."
           elif $miss > 0 then "labels: \($miss) of \(($pkn|length)) packets are missing a [orch tier:]/[orch impl:] trailer — their routing is UNMEASURED, not clean (run-loop §3.2/§3.4)."
           else empty end),
        (if $instrumented then empty else "instrumentation: no event carries `ok` — this run PREDATES the ok/model hook capture, so failed_tool_calls and dispatches_with_model_override are null (unmeasured), NOT zero." end),
        (if $self_host then "self_host: this run is the plugin driving its OWN repo (dogfooding), not a consumer app — do not average it with consumer-repo runs." else empty end)
      ] | map(select(. != null and . != "")))
    }
    ' > "$out" 2>/dev/null || die "failed to assemble packet"

  printf '%s\n' "$out"
}

# =============================================================================
# show — compact human summary of a run-metrics packet
# =============================================================================
cmd_show() {
  local f="${1:-}"
  if [ -z "$f" ]; then
    local main_root; main_root="$(resolve_main_root "")"
    # newest run-metrics.json under .agents/metrics/*/
    f="$(ls -t "${main_root}/.agents/metrics/"*/run-metrics.json 2>/dev/null | head -1)"
  fi
  [ -n "$f" ] && [ -f "$f" ] || die "no run-metrics packet found (run: metrics.sh collect)"
  command -v jq >/dev/null 2>&1 || { cat "$f"; return; }
  jq -r '
    "run: \(.run_id)   mode: \(.mode)   autonomy: \(.autonomy // "?")   token_source: \(.token_source)\(if .self_host == true then "   self-host: yes" elif (has("self_host") | not) or .self_host == null then "   self-host: unknown" else "" end)",
    "window: \(.window.wall_seconds)s wall (active \(.window.active_seconds // "?")s / idle \(.window.idle_seconds // "?")s)   packets: \(.totals.packets)   tool_calls: \(.totals.tool_calls) (+\(.totals.unattributed_tool_calls // 0) unattributed)",
    # outcome coverage is never allowed to render as "all green" — see the T4/T5
    # comment on totals.outcome_coverage. Absent (a packet collected before this
    # field existed) reads the same as "unmeasured", not as clean.
    (((.totals.outcome_coverage // "unmeasured")) as $cov
     | if $cov == "unmeasured" then
         "outcome coverage: unmeasured — no record-start boundary in this run (pre-instrumentation, or the loop never ran record-start)"
       elif $cov == "incomplete" then
         "outcome coverage: incomplete — \(.totals.started_without_outcome // "?") started packet(s) with no terminal outcome yet"
       else
         "outcome coverage: complete — every started packet has a terminal outcome (not all necessarily green — see \"by outcome\" below)"
       end),
    "tokens: in=\(.totals.tokens.input) out=\(.totals.tokens.output) cacheR=\(.totals.tokens.cache_read) cacheC=\(.totals.tokens.cache_creation)   cache_hit_ratio: \(.totals.cache_hit_ratio // "n/a")",
    # Surface WHY the token half is missing/low-confidence, rather than leaving a
    # bare `none` that reads identically to "this run had no transcripts".
    (if (.token_source // "") != "transcript" then
       ((.token_diagnostics // {}) as $d
        | "  token diagnostics: dir=\($d.transcript_dir // "?")  files_present=\($d.transcript_files_present // "?")  files_matched=\($d.transcript_files_matched // "?")  usage_turns=\($d.usage_turns // "?")  in_window=\($d.usage_turns_in_window // "?")")
     else empty end),
    "",
    "by model:",
    ((.totals.by_model // {}) | to_entries[] | "  \(.key): out=\(.value.output) cacheC=\(.value.cache_creation) cacheR=\(.value.cache_read)"),
    (if ((.totals.by_effort // {}) | length) > 0 then
       "", "by effort:",
       ((.totals.by_effort) | to_entries[] | "  \(.key): turns=\(.value.turns) out=\(.value.output) cacheC=\(.value.cache_creation)")
     else empty end),
    (((.totals.context_invalidations // {count:0}) ) as $ci
     | if ($ci.count // 0) > 0 then
         "", "context invalidations (effort/model changed mid-context — each re-caches the whole prefix):",
         "  \($ci.count) change(s), \($ci.cache_creation) cacheC",
         ($ci.events[]? | "  \(.ts)  \(.role)  \(.from.effort // "?")/\(.from.model // "?") -> \(.to.effort // "?")/\(.to.model // "?")  cacheC=\(.cache_creation)")
       else empty end),
    "",
    "by role:",
    (.by_agent_role | to_entries[] | "  \(.key): out=\(.value.tokens.output) cacheR=\(.value.tokens.cache_read) cacheC=\(.value.tokens.cache_creation)   models=\((.value.models // {} | keys | join(",")))"),
    # cc_shape is the ONLY view here that can detect a context diet, and it has to be
    # in `show` because it is the stated verification mechanism for ADR 0022 — a
    # detector reachable only via `analyze` is a detector nobody reads on the run that
    # matters. Aggregate cacheCreation cannot do this job: it spans 1.76x across
    # untouched same-regime sessions, so a 20-30% trim sits inside the noise. Split
    # out, the MEDIAN is flat everywhere while p90/max track the standing-context SIZE.
    # Read it that way: a flat median with a large max is not an expensive agent, it is
    # a large payload being re-cached.
    (if ((.by_agent_role // {}) | map(select(.cc_shape != null)) | length) > 0 then
       "",
       "cc_shape — payload per turn, NOT agent cost (flat median + large max = a big standing context being re-cached):",
       (.by_agent_role | to_entries[] | select(.value.cc_shape != null)
        | "  \(.key): median=\(.value.cc_shape.median) p90=\(.value.cc_shape.p90) max=\(.value.cc_shape.max)   turns>50k=\(.value.cc_shape.turns_over_50k) (\(.value.cc_shape.cc_over_50k) cacheC)")
     else "", "cc_shape: unmeasured (no per-turn token data for this run)" end),
    "",
    "by skill (tool_calls / duration):",
    ((.totals.by_skill // {}) | to_entries | sort_by(-.value.tool_calls)[] | "  \(.key): \(.value.tool_calls) calls / \(.value.duration_ms)ms"),
    "",
    # Reports tool SELECTION. It does NOT report cost: shell search output was
    # measured at ~187k tokens against 105M DEDUPED lifetime cacheCreation (~0.18%), so
    # the earlier "shell grep here is waste" framing was unfounded (ADR 0019 v3.3).
    # (279M/0.07% was the pre-dedup inflated denominator — v3.3 corrected it.)
    # `sed -i`/`cat >` remain worth watching, as WRITES that bypass diff review.
    "by tool (selection, not cost):",
    ((.totals.by_tool // {}) | to_entries | sort_by(-.value.calls)[] | "  \(.key): \(.value.calls) calls / \(.value.duration_ms)ms"),
    "",
    "by command class (rtk-targeting: calls / duration):",
    ((.totals.by_command_class // {}) | to_entries | sort_by(-.value.duration_ms)[] | "  \(.key): \(.value.calls) calls / \(.value.duration_ms)ms"),
    "",
    # `0` and `unmeasured` must render as visibly different strings — see the
    # section-6b comment in collect (above) for why they are never allowed to collapse.
    (((.totals.same_file_overlaps)) as $sfo
     | if $sfo == null then
         "same-file overlaps (main + subagent editing the same file while both active): unmeasured (\(.totals.same_file_overlap_diagnostics.edit_events // 0) edit event(s), \(.totals.same_file_overlap_diagnostics.edit_events_missing_hash // 0) missing a file_hash)"
       else
         "same-file overlaps (main + subagent editing the same file while both active): \($sfo)"
       end),
    "",
    # The audit sits ABOVE the packets table on purpose: it is the "something is off"
    # section, and a run with 14 packets pushed it far enough down the page that a real
    # deviation (16 of 83 dispatches overriding a declared model, 13 onto opus) went
    # unread. Counters that the collector emits as null mean UNMEASURED — a legacy run
    # predating the instrumentation — and must never render as 0, which reads as clean.
    # That distinction is deliberate in the packet and used to be erased right here.
    "routing audit (opus orchestrator edits vs implementer dispatches; label \(if (.audit.labels_present) then "present" else "ABSENT — pre-instrumentation run" end)):",
    "  orchestrator_impl_edits=\(.audit.orchestrator_impl_edits // 0)   implementer_dispatches=\(.audit.implementer_dispatches // 0)   by_tier=\(.audit.by_tier // {})",
    "  tier labels: \((.audit.packets_total // 0) - (.audit.packets_missing_tier // 0))/\(.audit.packets_total // 0) packets labelled\(if (.audit.packets_missing_tier // 0) > 0 then "   ⚠ UNMEASURED: \(.audit.unlabelled_packet_ids // [] | join(", "))" else "" end)",
    "  dispatches=\(.audit.dispatches_total // 0) (explicit model overrides: \(if .audit.dispatches_with_model_override == null then "unmeasured — pre-instrumentation run" else .audit.dispatches_with_model_override end))   by_dispatch_model_override=\(.audit.by_dispatch_model_override // {})",
    "  failed_tool_calls=\(if .totals.failed_tool_calls == null then "unmeasured — pre-instrumentation run" else .totals.failed_tool_calls end)   human_interactions=\(.totals.human_interactions // 0) (interactivity confound)",
    ((.audit.flagged_packets // []) | if length==0 then "  no flags" else (.[] | "  ⚠ \(.id): \(.flags | join("; "))") end),
    "",
    # by outcome: each STARTED packet counted once (loop-measurement T5/T6). A row
    # here is no longer survivorship over green commits — a failed, rolled-back, or
    # still-open packet now appears too (T4), so this table can show real failures.
    (if ((.totals.outcome_counts // {}) | length) > 0 then
       "", "by outcome:",
       ((.totals.outcome_counts) | to_entries[] | "  \(.key): \(.value)")
     else empty end),
    "",
    # `outcome` renders as `?` when null, never as "green". Before loop-measurement T4
    # a packet existed here only because a green-commit trailer was found, so failed and
    # rolled-back work left NO row at all — that is no longer true once the run carries
    # record-start/record-outcome attestations (see totals.outcome_coverage above): a
    # started packet with no commit, or a pause commit that never got a terminal
    # outcome, now appears with outcome=null (not green). `?` still means unattested,
    # never "clean" or "green".
    "packets (id | outcome | tool_calls | active | dur | out-tok):",
    (.packets[] | "  \(.id) | \(.outcome // "?") | \(.tool_calls // "?") calls | \(.active_seconds // "?")s | \(.duration_ms // "-")ms | \(.tokens.output // "-")\(if .swept == true then "  ⚠ swept by a later session — unmeasured, not zero" else "" end)"),
    # Per-role edit counts alone cannot tell "the orchestrator corrected the implementer"
    # from "they worked on different files". Only same-file overlap can, so print the
    # counts and the contention together or the numbers invite the wrong reading.
    (if (.packets | map(select(.edits != null)) | length) > 0 then
       "",
       "edits per packet (rework signal — an edit count means little without the contention):",
       (.packets[] | select(.edits != null)
        | "  \(.id): \(.edits.edits) edits across \(.edits.files_touched) file(s), contended=\(.edits.contended_files)\(if (.edits.contended_files // 0) > 0 then "  ⚠ same file touched by \((.edits.contended_by // {}) | to_entries | map("\(.key) (\(.value))") | join(", "))" else "" end)")
     else empty end)
  ' "$f"
  printf '\npacket: %s\n' "$f"
}

# =============================================================================
# status — is metrics on, and which sources are available?
# =============================================================================
cmd_status() {
  local main_root=""
  while [ $# -gt 0 ]; do case "$1" in --main-root) main_root="$2"; shift 2 ;; *) shift ;; esac; done
  main_root="$(resolve_main_root "$main_root")"
  local projects_dir="${ORCH_METRICS_PROJECTS_DIR:-$HOME/.claude/projects}"
  local evdir="${main_root}/.agents/metrics/events"
  printf 'metrics: %s\n' "$(metrics_enabled "$main_root")"
  printf 'main_root: %s\n' "$main_root"
  printf 'jq: %s\n' "$(command -v jq >/dev/null 2>&1 && echo present || echo MISSING)"
  printf 'event_logs: %s\n' "$( { ls "$evdir"/*.jsonl 2>/dev/null | wc -l | tr -d ' '; } )"
  printf 'transcript_dir: %s (%s)\n' "$projects_dir" "$([ -d "$projects_dir" ] && echo present || echo absent)"
  printf 'run_state: %s\n' "$([ -f "${main_root}/.agents/run-state.yaml" ] && echo present || echo absent)"
}

# =============================================================================
cmd="${1:-}"; shift || true
case "$cmd" in
  collect) cmd_collect "$@" ;;
  show)    cmd_show    "$@" ;;
  status)  cmd_status  "$@" ;;
  ""|-h|--help)
    cat >&2 <<'USAGE'
metrics.sh — run-metrics assembly (ADR 0019 Tier 1)
  collect [--main-root D] [--projects-dir D] [--run-id ID] [--out F]
          [--session ID ...] [--all-sessions] [--since ISO] [--until ISO]
  show    [run-metrics.json]
  status  [--main-root D]
USAGE
    exit 0 ;;
  *) die "unknown subcommand '$cmd' (try: collect | show | status)" ;;
esac
