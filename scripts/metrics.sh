#!/usr/bin/env bash
# =============================================================================
# metrics.sh — run-metrics JOIN + ASSEMBLE core (ADR 0019 Tier 1)
# =============================================================================
# The deterministic, zero-token half of the metrics feature. The PostToolUse hook
# (hooks/metrics-log.sh) COLLECTS a per-session event spine as a run goes; this
# script JOINS that spine with (a) packet boundaries derived from the
# `[orch packet:<id>]` commit trailers that already exist in git, (b) the parallel
# wave map in .agents/packet-graph.yaml if present, and (c) best-effort token/cost
# from the Claude Code session transcripts — into ONE self-contained, portable
# rollup: .agents/metrics/<run-id>/run-metrics.json. That packet is the artifact a
# human reads or hands to Claude (/gaffer:metrics analyze) for optimization.
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
# deferred later upgrade (Tier 0), not built here.
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
#                      last packet commits just after its last tool event.
#   --out FILE         where to write the packet (default:
#                      <main-root>/.agents/metrics/<run-id>/run-metrics.json).
# =============================================================================

set -uo pipefail

die() { printf 'metrics.sh: %s\n' "$*" >&2; exit 1; }
warn() { printf 'metrics.sh: %s\n' "$*" >&2; }

# --- portable ISO-8601(Z) -> epoch seconds -----------------------------------
epoch() {
  local t="${1:-}"; [ -n "$t" ] || { echo 0; return; }
  # GNU date first, then BSD/macOS.
  date -u -d "$t" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$t" +%s 2>/dev/null \
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
  local graph="${agents}/packet-graph.yaml"

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
  run_start="$(jq -r 'map(.ts)|min // empty' "$tmp/events.json")"
  run_end="$(jq -r 'map(.ts)|max // empty' "$tmp/events.json")"
  tool_calls="$(jq -r 'length' "$tmp/events.json")"

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

  # by_lane (ADR 0019 v2 / P5-M): per-worktree-lane spend, for parallel runs. Empty on
  # sequential runs (no lane_id). Sum of lane durations >> wall means lanes overlapped
  # (real concurrency); ~= wall means the "parallel" run actually serialized.
  jq '
    [ .[] | select(.lane_id != null) ] | group_by(.lane_id)
    | map({key:.[0].lane_id, value:{tool_calls:length, duration_ms:(map(.duration_ms//0)|add)}})
    | from_entries
  ' "$tmp/events.json" > "$tmp/bylane.json" 2>/dev/null || echo '{}' > "$tmp/bylane.json"

  # --- run window: the [start,end] the trailer scan and packet chaining use ---
  # Prefer explicit flags, else the selected-events span. win_start is the lower
  # bound that excludes prior runs' commit trailers; win_end is only enforced when
  # --until is given (collection happens at end-of-run, so nothing legit is after).
  local win_start win_end
  win_start="${opt_since:-$run_start}"
  win_end="${opt_until:-$run_end}"

  # aid -> agent_type map (for attributing subagent transcript files to a role)
  jq '[.[]|{key:.agent_id,value:.agent_type}]|from_entries' "$tmp/events.json" > "$tmp/aidmap.json" 2>/dev/null || echo '{}' > "$tmp/aidmap.json"
  # distinct session ids seen in events
  jq -r '[.[].session_id]|unique|.[]' "$tmp/events.json" > "$tmp/sids.txt" 2>/dev/null || true

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
  # Emit the committer time in the SAME UTC `...Z` form as event timestamps so the
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
  local log_revs="--all" we_bound=""
  if [ -n "$win_start" ]; then
    if [ -n "$opt_until" ]; then
      we_bound="$win_end"                             # explicit --until wins verbatim
    else
      we_bound="$(iso_plus "$win_end" "${ORCH_METRICS_TRAILER_GRACE:-3600}")"
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
  # shellcheck disable=SC2086  # log_revs is an intentional word-split rev argument
  TZ=UTC0 git -C "$main_root" log $log_revs --date-order \
      --date=format-local:'%Y-%m-%dT%H:%M:%SZ' \
      --format='===ORCHCOMMIT===%x09%cd%n%B' 2>/dev/null \
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

  # --- 3. wave map from packet-graph.yaml (packet -> wave), if present --------
  # tolerant parse: look for `wave: N` headers and `- id: <pkt>` / `<pkt>:` entries.
  echo '{}' > "$tmp/waves.json"
  if [ -f "$graph" ]; then
    awk '
      /(^|[[:space:]])wave:[[:space:]]*[0-9]+/ {
        for (i=1;i<=NF;i++) if ($i=="wave:") { w=$(i+1) }
      }
      /- id:[[:space:]]*/ { id=$0; sub(/.*- id:[[:space:]]*/,"",id); gsub(/[[:space:]]/,"",id); if (w!="") print id "\t" w }
    ' "$graph" 2>/dev/null \
    | jq -R -s 'split("\n")|map(select(length>0))|map(split("\t"))|map({key:.[0],value:(.[1]|tonumber?)})|from_entries' \
    > "$tmp/waves.json" 2>/dev/null || echo '{}' > "$tmp/waves.json"
  fi

  # --- 4. tokens per turn (ADR 0019 v2) --------------------------------------
  # Emit ONE record per assistant turn: {role, ts, model, tok}. Per-turn `ts` lets us
  # bucket tokens into packet windows (per-packet split); `model` enables per-model
  # cost attribution (opus vs sonnet vs haiku are not comparable by raw token count).
  # Fail soft to structural-only; `ts` may be absent (older transcript) -> per-packet
  # tokens degrade to null while run/role totals stay intact.
  : > "$tmp/turns.ndjson"
  local token_source="none"
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    for mf in "$projects_dir"/*/"$sid".jsonl; do
      [ -e "$mf" ] || continue
      jq -c 'select((.message.usage // .usage) != null)
        | {role:"main", ts:(.timestamp // null), model:(.message.model // .model // null),
           tok:((.message.usage // .usage) | {input:(.input_tokens//0), output:(.output_tokens//0),
                cache_creation:(.cache_creation_input_tokens//0), cache_read:(.cache_read_input_tokens//0)})}' \
        "$mf" 2>/dev/null >> "$tmp/turns.ndjson" || true
    done
    for sf in "$projects_dir"/*/"$sid"/subagents/agent-*.jsonl; do
      [ -e "$sf" ] || continue
      local base aid role
      base="$(basename "$sf")"; aid="${base#agent-}"; aid="${aid%.jsonl}"
      role="$(jq -r --arg a "$aid" '.[$a] // "unknown"' "$tmp/aidmap.json" 2>/dev/null)"
      [ -n "$role" ] || role="unknown"
      jq -c --arg role "$role" 'select((.message.usage // .usage) != null)
        | {role:$role, ts:(.timestamp // null), model:(.message.model // .model // null),
           tok:((.message.usage // .usage) | {input:(.input_tokens//0), output:(.output_tokens//0),
                cache_creation:(.cache_creation_input_tokens//0), cache_read:(.cache_read_input_tokens//0)})}' \
        "$sf" 2>/dev/null >> "$tmp/turns.ndjson" || true
    done
  done < "$tmp/sids.txt"
  jq -s '.' "$tmp/turns.ndjson" > "$tmp/turns_raw.json" 2>/dev/null || echo '[]' > "$tmp/turns_raw.json"

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

  # per-role totals + per-model split within role
  jq '
    def sumtok(f): {input:(map(f.input)|add//0), output:(map(f.output)|add//0),
                    cache_creation:(map(f.cache_creation)|add//0), cache_read:(map(f.cache_read)|add//0)};
    group_by(.role) | map({
      key: .[0].role,
      value: {
        tokens: (map(.tok) | sumtok(.)),
        models: (group_by(.model) | map(select(.[0].model != null))
                 | map({key:(.[0].model), value:(map(.tok)|sumtok(.))}) | from_entries)
      }}) | from_entries
  ' "$tmp/turns.json" > "$tmp/roletokens.json" 2>/dev/null || echo '{}' > "$tmp/roletokens.json"

  # by_model rollup (run-wide) — the cost-normalization surface
  jq '
    def sumtok(f): {input:(map(f.input)|add//0), output:(map(f.output)|add//0),
                    cache_creation:(map(f.cache_creation)|add//0), cache_read:(map(f.cache_read)|add//0)};
    group_by(.model) | map(select(.[0].model != null))
    | map({key:(.[0].model), value:(map(.tok)|sumtok(.))}) | from_entries
  ' "$tmp/turns.json" > "$tmp/bymodel.json" 2>/dev/null || echo '{}' > "$tmp/bymodel.json"

  if jq -e 'map(.tok.input+.tok.output+.tok.cache_read+.tok.cache_creation)|add>0' "$tmp/turns.json" >/dev/null 2>&1; then
    token_source="transcript"
  fi
  local turns_have_ts; turns_have_ts="$(jq -r 'any(.ts != null)' "$tmp/turns.json" 2>/dev/null || echo false)"

  # ATTRIBUTION CONFIDENCE (ADR 0019): role='unknown' is a subagent transcript whose
  # agent_id was never seen in the event spine, so it could not be mapped to a role
  # (aidmap miss at step 4). Quantify its share instead of burying it; if it dominates
  # the output split, DOWNGRADE the stamp to `transcript-degraded` so show/analyze flag
  # the per-role/model split as low-confidence rather than presenting it as clean. This
  # is the self-reporting reconcile check that turns silent fragility into a loud note.
  local unknown_note=""
  if [ "$token_source" = "transcript" ]; then
    local unknown_out total_out
    unknown_out="$(jq -r '(.unknown.tokens.output // 0)' "$tmp/roletokens.json" 2>/dev/null || echo 0)"
    total_out="$(jq -r '[.[].tokens.output // 0] | add // 0' "$tmp/roletokens.json" 2>/dev/null || echo 0)"
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
     --slurpfile waves "$tmp/waves.json" \
     --slurpfile turns "$tmp/turns.json" \
     --argjson gap "$idle_gap" \
     --arg have_ts "$turns_have_ts" \
     --arg run_start "$win_start" \
     '
     def sumtok(f): {input:(map(f.input)|add//0), output:(map(f.output)|add//0),
                     cache_creation:(map(f.cache_creation)|add//0), cache_read:(map(f.cache_read)|add//0)};
     . as $ends
     | ($ev[0] // []) as $events
     | ($turns[0] // []) as $turns
     | ($waves[0] // {}) as $wavemap
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
         | ($events | map(select(.ts > $start and .ts <= $p.end))) as $win
         | (($win | map(.ts) | sort | map(fromdateiso8601)) as $wt
            | reduce range(0; ($wt|length)-1) as $k (0;
                . + (($wt[$k+1]-$wt[$k]) as $d | if $d>$gap then 0 else $d end))) as $active
         | ($turns | map(select($ts_ok and .ts != null and .ts > $start and .ts <= $p.end))) as $wtok
         # ROUTING AUDIT (ADR 0019): who actually wrote code, and what was dispatched,
         # so the executor self-label (tier/impl) can be cross-checked against reality.
         | ($win | map(select(.tool=="Edit" or .tool=="Write" or .tool=="NotebookEdit"))
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
         | $acc + [{
             id: $p.id,
             wave: ($wavemap[$p.id]),
             outcome: "green",
             tier: $p.tier,
             impl: $p.impl,
             start: $start,
             end: $p.end,
             tool_calls: ($win|length),
             active_seconds: ($active|floor),
             duration_ms: ($win|map(.duration_ms//0)|add),
             by_agent: ($win|group_by(.agent_type)|map({key:(.[0].agent_type),value:length})|from_entries),
             by_tool: ($win|group_by(.tool)|map({key:(.[0].tool),value:length})|from_entries),
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
           }]
       )
     ' "$tmp/pk_ends.json" > "$tmp/packets.json" 2>/dev/null || echo '[]' > "$tmp/packets.json"

  # --- 6. unattributed: events in NO packet window (wasted/between-packet calls) --
  jq --slurpfile pk "$tmp/packets.json" '
    ($pk[0] // []) as $packets
    | [ .[] | . as $e | select( ($packets | any(.start < $e.ts and $e.ts <= .end)) | not ) ]
    | { count: length, by_agent: (group_by(.agent_type)|map({key:(.[0].agent_type),value:length})|from_entries) }
  ' "$tmp/events.json" > "$tmp/unattributed.json" 2>/dev/null || echo '{"count":0,"by_agent":{}}' > "$tmp/unattributed.json"

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
    --arg run_start "$win_start" \
    --arg run_end "$win_end" \
    --argjson wall "$wall" \
    --argjson tool_calls "${tool_calls:-0}" \
    --slurpfile packets "$tmp/packets.json" \
    --slurpfile roletokens "$tmp/roletokens.json" \
    --slurpfile bymodel "$tmp/bymodel.json" \
    --slurpfile activity "$tmp/activity.json" \
    --slurpfile unattr "$tmp/unattributed.json" \
    --slurpfile byskill "$tmp/byskill.json" \
    --slurpfile bytool "$tmp/bytool.json" \
    --slurpfile bycmd "$tmp/bycmd.json" \
    --slurpfile durations "$tmp/durations.json" \
    --slurpfile bylane "$tmp/bylane.json" \
    --slurpfile sids "$tmp/events.json" \
    --arg unknown_note "$unknown_note" \
    '
    ($roletokens[0] // {}) as $rt
    | ($activity[0] // {active:0,idle:0}) as $act
    | ($unattr[0] // {count:0,by_agent:{}}) as $un
    | ($durations[0] // {total:0,by_role:{}}) as $dur
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
    | {
      schema: 2,
      run_id: $run_id,
      generated_at: $generated,
      token_source: $token_source,
      mode: $mode,
      autonomy: $autonomy,
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
        by_lane: ($bylane[0] // {}),
        tokens: $tot,
        by_model: ($bymodel[0] // {}),
        cache_hit_ratio: (if $cache_total>0 then (($tot.cache_read / $cache_total)*1000|floor)/1000 else null end),
        failed_tool_calls: (if $instrumented then (($sids[0] // []) | map(select(.ok == false)) | length) else null end),
        human_interactions: (($sids[0] // []) | map(select(.tool=="AskUserQuestion")) | length)
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
        (if $token_source=="none" then "token_source=none: no transcript found; structural metrics only (ADR 0019 Open Q1)."
         elif $token_source=="transcript-degraded" then "token_source=transcript-degraded: parse succeeded but a large share of tokens is unattributed; treat per-role/model splits as low-confidence (ADR 0019)."
         else "token_source=transcript: version-fragile on-disk parse (ADR 0019 Open Q1)." end),
        $unknown_note,
        "Per-packet token split needs per-turn transcript timestamps; packets[].tokens is null when absent.",
        "Token turns are bounded to the run window (ADR 0019 window-bleed fix); ts==null turns are kept unwindowed.",
        "Guard ASK-tier prompt frequency is not captured in v1 (PostToolUse hook sees allowed calls only).",
        "Packet boundaries derived from [orch packet:<id>] commit trailers; failed/uncommitted packets do not appear.",
        "Trailer scan is bounded at BOTH ends: [win_start, last-event + grace] (grace=ORCH_METRICS_TRAILER_GRACE, default 3600s), or --until verbatim. Before this the upper bound was open, so a retrospective collect absorbed packets committed by every later run.",
        "by_skill is STICKY: set by the most recent slash-command/Skill invocation and never cleared, so it is an UPPER BOUND on the spend of that skill, not an exact span.",
        "by_tool is the tool-SELECTION mix (Bash/Read/Edit/Grep/...); shell `grep`/`find`/`sed` showing up in by_command_class while Grep/Glob sit at zero here is context waste, not search volume.",
        "active/idle from inter-event gaps (idle_gap_seconds); unattributed_tool_calls = events outside all packet windows.",
        "audit.* cross-checks the executor [orch tier:/impl:] self-label against who actually edited (impl_edits_by_role) and what was dispatched; leak = opus orchestrator wrote code without dispatching the implementer.",
        "audit.dispatches_with_model_override counts EXPLICIT `model` args at dispatch (a deliberate deviation). An omitted model is correct — it resolves to the `model:` frontmatter of the target agent; read by_agent_role.<role>.models for what each role actually ran on.",
        (($packets[0] // []) as $pkn
         | ($pkn | any(.tier != null or .impl != null)) as $lab
         | ($pkn | map(select(.tier == null or .impl == null)) | length) as $miss
         | if ($lab|not) then "labels: NO packet in this run carries a [orch tier:]/[orch impl:] trailer — routing is entirely UNMEASURED for this run (legacy or convention off), not clean; per-packet unlabelled flags are suppressed (run-loop §3.2/§3.4)."
           elif $miss > 0 then "labels: \($miss) of \(($pkn|length)) packets are missing a [orch tier:]/[orch impl:] trailer — their routing is UNMEASURED, not clean (run-loop §3.2/§3.4)."
           else empty end),
        (if $instrumented then empty else "instrumentation: no event carries `ok` — this run PREDATES the ok/model hook capture, so failed_tool_calls and dispatches_with_model_override are null (unmeasured), NOT zero." end)
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
    "run: \(.run_id)   mode: \(.mode)   autonomy: \(.autonomy // "?")   token_source: \(.token_source)",
    "window: \(.window.wall_seconds)s wall (active \(.window.active_seconds // "?")s / idle \(.window.idle_seconds // "?")s)   packets: \(.totals.packets)   tool_calls: \(.totals.tool_calls) (+\(.totals.unattributed_tool_calls // 0) unattributed)",
    "tokens: in=\(.totals.tokens.input) out=\(.totals.tokens.output) cacheR=\(.totals.tokens.cache_read) cacheC=\(.totals.tokens.cache_creation)   cache_hit_ratio: \(.totals.cache_hit_ratio // "n/a")",
    "",
    "by model:",
    ((.totals.by_model // {}) | to_entries[] | "  \(.key): out=\(.value.output) cacheC=\(.value.cache_creation) cacheR=\(.value.cache_read)"),
    "",
    "by role:",
    (.by_agent_role | to_entries[] | "  \(.key): out=\(.value.tokens.output) cacheR=\(.value.tokens.cache_read) cacheC=\(.value.tokens.cache_creation)   models=\((.value.models // {} | keys | join(",")))"),
    "",
    "by skill (tool_calls / duration):",
    ((.totals.by_skill // {}) | to_entries | sort_by(-.value.tool_calls)[] | "  \(.key): \(.value.tool_calls) calls / \(.value.duration_ms)ms"),
    "",
    "by tool (tool SELECTION — shell `grep`/`find`/`sed` here instead of Grep/Glob/Edit is waste):",
    ((.totals.by_tool // {}) | to_entries | sort_by(-.value.calls)[] | "  \(.key): \(.value.calls) calls / \(.value.duration_ms)ms"),
    "",
    "by command class (rtk-targeting: calls / duration):",
    ((.totals.by_command_class // {}) | to_entries | sort_by(-.value.duration_ms)[] | "  \(.key): \(.value.calls) calls / \(.value.duration_ms)ms"),
    (if ((.totals.by_lane // {}) | length) > 0 then
       "", "by lane (parallel — sum(lane dur) >> wall means real concurrency):",
       ((.totals.by_lane) | to_entries | sort_by(-.value.duration_ms)[] | "  \(.key): \(.value.tool_calls) calls / \(.value.duration_ms)ms")
     else empty end),
    "",
    "packets (id | wave | tool_calls | active | dur | out-tok):",
    (.packets[] | "  \(.id) | wave \(.wave // "?") | \(.tool_calls) calls | \(.active_seconds // "?")s | \(.duration_ms // "-")ms | \(.tokens.output // "-")"),
    "",
    "routing audit (opus orchestrator edits vs implementer dispatches; label \(if (.audit.labels_present) then "present" else "ABSENT — pre-instrumentation run" end)):",
    "  orchestrator_impl_edits=\(.audit.orchestrator_impl_edits // 0)   implementer_dispatches=\(.audit.implementer_dispatches // 0)   by_tier=\(.audit.by_tier // {})",
    "  tier labels: \((.audit.packets_total // 0) - (.audit.packets_missing_tier // 0))/\(.audit.packets_total // 0) packets labelled\(if (.audit.packets_missing_tier // 0) > 0 then "   ⚠ UNMEASURED: \(.audit.unlabelled_packet_ids // [] | join(", "))" else "" end)",
    "  dispatches=\(.audit.dispatches_total // 0) (explicit model overrides: \(.audit.dispatches_with_model_override // 0))   by_dispatch_model_override=\(.audit.by_dispatch_model_override // {})",
    "  failed_tool_calls=\(.totals.failed_tool_calls // 0)   human_interactions=\(.totals.human_interactions // 0) (interactivity confound)",
    ((.audit.flagged_packets // []) | if length==0 then "  no flags" else (.[] | "  ⚠ \(.id): \(.flags | join("; "))") end)
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
