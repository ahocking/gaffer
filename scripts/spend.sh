#!/usr/bin/env bash
# =============================================================================
# spend.sh — machine-wide API-equivalent spend report (loop-measurement T9/T10)
# =============================================================================
# Unlike metrics.sh (one repo's run), this reads EVERY Claude Code session
# transcript on the machine — main sessions and subagents, every project — over
# a time window (default: the last 7 days) and reports API-equivalent token
# spend broken down by project folder name, model, agent role, effort and cost
# part (input / cache write 5m / cache write 1h / cache read / output), priced
# from scripts/spend-prices.json (or an override via --price-table).
#
# jq IS REQUIRED (unlike runstate.sh's plain-bash fallback): the transcript
# join, dedup, and price-table lookup are all jq. There is no meaningful
# degraded path without it, so this fails cleanly and immediately if jq is
# missing, rather than producing a silently-wrong report.
#
# THE RULES CARRIED OVER FROM metrics.sh, ASSERTED HERE RATHER THAN IMPORTED
# (see gspec/features/loop-measurement/tasks.md plan preamble):
#   - dedup keeps the EARLIEST row per `message.id`; a transcript can record the
#     SAME assistant message more than once (observed 3x for one id in
#     production), and summing rows re-inflates every total ~2.3x-3.2x
#     (cacheCreation) to 3.3x-6.3x (output) — this is the bug ADR 0019 v3.3
#     fixed in metrics.sh, and it is not optional here either. Rows with NO id
#     are kept verbatim and counted separately: `.uuid` is per-ROW, not
#     per-message, so keying on it would dedupe nothing while looking like it
#     worked — under-dedupe is the safe direction.
#   - every `jq -r … | while read` consumer goes through tr -d '\r' (jqr()
#     below). Native Windows jq emits \r\n on pipes too; `read` strips only the
#     \n, so an unshimmed read loop silently sees corrupted lines.
#   - effort, agent role and the cache-write 5m/1h split are PROBED from real
#     transcripts, not assumed from docs. What was found (2026-09-15, this
#     machine, jq 1.7-class):
#       * usage lives at `.message.usage` on every real row seen (top-level
#         `.usage` kept as a fallback for older-format rows; none were found).
#       * `.message.usage.cache_creation.{ephemeral_5m_input_tokens,
#         ephemeral_1h_input_tokens}` is the 5m/1h split, alongside the older
#         combined `.message.usage.cache_creation_input_tokens`. Present on
#         every row across every project scanned. If a future transcript ever
#         carries the combined field WITHOUT the breakdown object, that
#         row's cache-write tokens are counted but priced as neither lifetime
#         (never guessed) — see `cache_write_unmeasured_tokens` below.
#       * subagent transcripts (`<sid>/subagents/agent-*.jsonl`) carry the
#         acting role as `.attributionAgent` (e.g. "gaffer:implementer",
#         "feature-writer") directly on each row — no event-log join needed.
#         It is ABSENT ENTIRELY (not merely null) on some older transcripts
#         (observed in another project on this machine); those rows group
#         under agent role "unrecorded", per spec, rather than guessed.
#       * main-session rows carry no `attributionAgent` (it is main by
#         construction — the file is not under a `subagents/` directory).
#       * `.effort` is a top-level field on the row (not under `.message`).
#         Observed values: "high", "xhigh", "max", and absent (older rows) —
#         absent groups under effort "unrecorded".
#       * `.message.model` (assistant rows) carries the model id verbatim,
#         e.g. "claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001".
#         A literal model id of "<synthetic>" marks a non-API injected turn
#         with all-zero usage (same convention metrics.sh already drops) —
#         excluded from every count, tallied separately as
#         `messages_excluded_synthetic` so it is visible, not silently gone.
#       * every real row scanned on this machine carried both `usage` and
#         `.timestamp`; no row lacking either was found. The exclude-and-count
#         path exists for format drift, not a bug reproduced here — it is
#         exercised by synthetic fixtures in test-spend.sh instead.
#
# NO PATH, PROMPT TEXT OR MESSAGE CONTENT IS EVER READ: only .type,
# .timestamp, .message.id, .message.model, .message.usage*, .effort and
# .attributionAgent are extracted. Projects are identified by the Claude
# projects-dir FOLDER NAME only (already a dash-encoded absolute path with no
# separators — never joined with any other path fragment in the output).
#
# WINDOW COMPARISON IS STRING, NOT EPOCH (deliberate — see metrics.sh's own
# "WINDOW-BLEED FIX" note for the same idiom): transcript timestamps are
# `YYYY-MM-DDTHH:MM:SS.mmmZ`; comparing the [0:19] second-precision prefix
# lexicographically against a same-shaped --since/--until is exact and
# side-steps `date`'s GNU/BSD parsing-format split entirely for per-row
# comparison. `date` is used only to compute the DEFAULT window bound
# (now / now-N-days), where both dialects are tried (GNU `-d`, then BSD `-v`).
#
# Usage:
#   spend.sh [--projects-dir DIR] [--since ISO] [--until ISO] [--days N]
#            [--price-table FILE] [--project FOLDER]
#
#   --projects-dir DIR  Claude Code transcript root (default:
#                        $ORCH_METRICS_PROJECTS_DIR or ~/.claude/projects).
#   --since ISO          window lower bound, e.g. 2026-09-08T00:00:00Z
#                        (default: --until minus --days).
#   --until ISO          window upper bound (default: now).
#   --days N             window length in days when --since is not given
#                        (default: 7).
#   --price-table FILE   alternate price table (default: spend-prices.json
#                        next to this script).
#   --project FOLDER     scope the ENTIRE scan to one Claude-projects folder
#                        name (the same dash-encoded name that appears as a
#                        by_project key), so by_role, by_model, by_effort and
#                        totals all read as that one repo's numbers rather
#                        than a machine-wide mix — this is what the
#                        thin-loop-driver "main-session cost per landed
#                        packet" success metric needs (that repo's role
#                        "main" dollars over the same window, divided by the
#                        green-packet count `metrics.sh collect` reports for
#                        the same repo/window). Matched by EXACT directory
#                        name, never a prefix or substring, so "proj1" cannot
#                        also pull in a sibling folder "proj10". A folder
#                        that does not exist under projects_dir is not an
#                        error: it reports `project.status: "absent"` and an
#                        otherwise-empty (zero) report, the same "empty
#                        window is legitimate" rule --projects-dir absent
#                        already follows. Omit it for the prior machine-wide
#                        behavior, unchanged.
#
# Prints one JSON report to stdout. Exit 0 on success (including an empty
# window — that is a legitimate report, not a failure); exit 1 on a usage or
# configuration error (missing jq, unreadable/malformed price table, bad args).
# =============================================================================

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

die() { printf 'spend.sh: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required (this script has no plain-bash fallback) — install jq and retry."

# --- jqr: raw-mode jq with CR stripped ---------------------------------------
# Every raw jq read that a shell consumes as text goes through here (mirrors
# metrics.sh's jqr(); see the CRLF note in the header above).
jqr() { jq -r "$@" | tr -d '\r'; }

# --- portable "now" / "N days ago" as ISO-8601(Z) -----------------------------
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
days_ago_iso() {
  local n="$1"
  date -u -d "-${n} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${n}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf ''
}
# shift_iso_back_1day <ISO-Z>: best-effort "one day earlier", used only to
# widen the mtime pre-filter below by a safety margin. On failure (any input
# shape neither dialect can parse) it returns the input UNCHANGED — the
# pre-filter still works, just without the margin, never wrongly.
shift_iso_back_1day() {
  local t="$1"
  date -u -d "${t} -1 day" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-1d -j -f "%Y-%m-%dT%H:%M:%SZ" "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$t"
}
# to_findmt <ISO-Z>: reshape for `find -newermt`, whose date parser is a THIRD
# dialect split from the `-d`/`-v` one above — probed directly (not assumed):
# GNU find's -newermt accepts ISO-8601 with `T`/`Z` unchanged, but the real
# BSD find shipped as macOS's /usr/bin/find (distinct from a PATH-shadowing
# `bfs` or GNU coreutils some dev machines have ahead of it — this bit a first
# draft that passed interactively and silently fell back to unfiltered when
# actually run as a script) rejects `T`/`Z` outright ("Can't parse
# date/time"), only "%Y-%m-%d %H:%M:%S" (space-separated, no zone). Stripping
# the zone marker means BSD reads it as LOCAL time, off from the UTC value by
# up to the local UTC offset — inconsequential here because it only feeds the
# already-1-day-padded pre-filter threshold, never the row-level window test.
to_findmt() { printf '%s' "$1" | sed -E 's/^([0-9-]+)T([0-9:]+)Z?$/\1 \2/'; }

usage() {
  cat >&2 <<'USAGE'
spend.sh — machine-wide API-equivalent spend report (requires jq)
  spend.sh [--projects-dir DIR] [--since ISO] [--until ISO] [--days N]
           [--price-table FILE] [--project FOLDER]
Prints one JSON report to stdout, over a window (default: the last 7 days).
--project FOLDER scopes the whole report to one Claude-projects folder name
(exact match), so by_role/by_model/by_effort/totals read as that one repo.
USAGE
}

projects_dir="${ORCH_METRICS_PROJECTS_DIR:-$HOME/.claude/projects}"
since="" until="" days=7 price_table="${HERE}/spend-prices.json"
project_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --projects-dir) projects_dir="${2:-}"; shift 2 ;;
    --since) since="${2:-}"; shift 2 ;;
    --until) until="${2:-}"; shift 2 ;;
    --days) days="${2:-}"; shift 2 ;;
    --price-table) price_table="${2:-}"; shift 2 ;;
    --project) project_filter="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1' (try --help)" ;;
  esac
done

case "$days" in ''|*[!0-9]*) die "--days must be a non-negative integer, got '$days'" ;; esac

[ -n "$until" ] || until="$(now_iso)"
[ -n "$since" ] || since="$(days_ago_iso "$days")"
[ -n "$since" ] && [ -n "$until" ] || die "could not compute the default window (this platform's 'date' supports neither -d nor -v); pass --since and --until explicitly."

[ -f "$price_table" ] || die "price table not found: $price_table"
jq -e 'has("table_date") and has("prices")' "$price_table" >/dev/null 2>&1 \
  || die "price table '$price_table' is not valid JSON with the expected shape (needs top-level 'table_date' and 'prices' keys)."
table_date="$(jqr '.table_date' "$price_table")"
price_table_overridden="false"
[ "$price_table" = "${HERE}/spend-prices.json" ] || price_table_overridden="true"

# =============================================================================
# SCAN: every main + subagent transcript under projects_dir, one classified
# record per line into a temp ndjson spine. No `while read` loop consumes a
# jq-generated list here (unlike metrics.sh's sid join), so the CRLF-in-a-
# read-loop trap does not apply to file discovery — bash globs the files
# directly. jqr()/tr -d '\r' is still used for every scalar extraction below.
# =============================================================================
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
: > "$tmp/raw.ndjson"
files_scanned=0

# Shared per-row classification, parameterized on how `project`/`role`/`aid`
# are supplied (main files know role="main" from their location; subagent
# files read the acting role from `.attributionAgent`, falling back to
# "unrecorded" — never guessed — when the field is absent or null).
scan_main() { # scan_main <file> <project> <sid>
  jq -c --arg proj "$2" --arg sid "$3" '
    select(.type=="assistant")
    | ((.message.usage // .usage)) as $u
    | ((.message.model // .model)) as $m
    | if ($u == null) or (.timestamp == null) then
        {kind:"excluded_no_usage_or_ts"}
      elif ($m == "<synthetic>") then
        {kind:"excluded_synthetic"}
      else
        {
          kind:"turn", project:$proj, role:"main", aid:("main:"+$sid),
          id:(.message.id // null), ts:.timestamp,
          model:($m // "unrecorded"), effort:(.effort // null),
          tok: {
            input:($u.input_tokens // 0),
            output:($u.output_tokens // 0),
            cache_read:($u.cache_read_input_tokens // 0),
            cache_write_5m:(if $u.cache_creation != null then ($u.cache_creation.ephemeral_5m_input_tokens // 0) else null end),
            cache_write_1h:(if $u.cache_creation != null then ($u.cache_creation.ephemeral_1h_input_tokens // 0) else null end),
            cache_write_unsplit:(if $u.cache_creation == null then ($u.cache_creation_input_tokens // 0) else 0 end)
          }
        }
      end
  ' "$1" 2>/dev/null >> "$tmp/raw.ndjson"
}
scan_sub() { # scan_sub <file> <project> <aid>
  jq -c --arg proj "$2" --arg aid "$3" '
    select(.type=="assistant")
    | ((.message.usage // .usage)) as $u
    | ((.message.model // .model)) as $m
    | if ($u == null) or (.timestamp == null) then
        {kind:"excluded_no_usage_or_ts"}
      elif ($m == "<synthetic>") then
        {kind:"excluded_synthetic"}
      else
        {
          kind:"turn", project:$proj, role:(.attributionAgent // "unrecorded"), aid:$aid,
          id:(.message.id // null), ts:.timestamp,
          model:($m // "unrecorded"), effort:(.effort // null),
          tok: {
            input:($u.input_tokens // 0),
            output:($u.output_tokens // 0),
            cache_read:($u.cache_read_input_tokens // 0),
            cache_write_5m:(if $u.cache_creation != null then ($u.cache_creation.ephemeral_5m_input_tokens // 0) else null end),
            cache_write_1h:(if $u.cache_creation != null then ($u.cache_creation.ephemeral_1h_input_tokens // 0) else null end),
            cache_write_unsplit:(if $u.cache_creation == null then ($u.cache_creation_input_tokens // 0) else 0 end)
          }
        }
      end
  ' "$1" 2>/dev/null >> "$tmp/raw.ndjson"
}

# Transcript files are append-only, so a file's mtime is the timestamp of its
# LAST written row: if that predates the window's lower bound, EVERY row in the
# file does too, and the file cannot contribute anything in-window. Skipping
# such files is both a real performance fix — this machine alone carries 3000+
# transcript files spanning months, and without this every `--days 7` report
# would re-read the whole lifetime history — and a correctness one: dedup runs
# on whatever gets scanned, so scanning irrelevant history inflated
# `messages_deduped_dropped` with duplicates from conversations having nothing
# to do with the requested window (measured: 175,776 on an unfiltered
# machine-wide scan against 2,340 messages actually in a 1-day window).
# `-newermt` is a common GNU/BSD find extension, not POSIX, so it is PROBED
# (not assumed) and the loop falls back to scanning everything if unsupported,
# rather than silently dropping files a stricter probe might reject. The
# threshold is `since` minus a 1-day safety margin, not `since` itself: find's
# mtime comparison is a strict "newer than" and has coarser (often 1s)
# resolution than the row-level string compare below, so a file last written
# within seconds of the window's lower bound could otherwise be skipped at the
# file level even though a row inside it belongs in the window. The margin
# costs a little extra scanning near the boundary; it can never cost
# correctness, because the exact row-level window test still runs on every
# row of every file the pre-filter lets through.
newermt_ok=1
find "$tmp" -maxdepth 0 -newermt "$(to_findmt "1970-01-01T00:00:00Z")" >/dev/null 2>&1 || newermt_ok=0
mtime_floor="$(to_findmt "$(shift_iso_back_1day "$since")")"

# --project resolves to EXACTLY ONE project directory, matched by exact
# directory name — never a prefix/substring/glob, so "proj1" cannot also
# pull in a sibling folder "proj10". Built into a directory LIST rather than
# branching the scan body in two, so the per-file scanning logic below (the
# newermt probe, main vs. subagent discovery) is written and maintained once
# regardless of whether --project narrowed it.
: > "$tmp/projdirs.txt"
project_status="not_filtered"
if [ -d "$projects_dir" ]; then
  if [ -n "$project_filter" ]; then
    if [ -d "$projects_dir/$project_filter" ]; then
      printf '%s\n' "$projects_dir/$project_filter/" >> "$tmp/projdirs.txt"
      project_status="present"
    else
      project_status="absent"
    fi
  else
    for pf in "$projects_dir"/*/; do
      [ -d "$pf" ] || continue
      printf '%s\n' "$pf" >> "$tmp/projdirs.txt"
    done
  fi
  projects_dir_status="present"
else
  projects_dir_status="absent"
  [ -n "$project_filter" ] && project_status="absent"
fi

while IFS= read -r pf; do
  [ -n "$pf" ] || continue
  proj="$(basename "$pf")"
  if [ "$newermt_ok" = "1" ]; then
    main_files="$(find "$pf" -maxdepth 1 -name '*.jsonl' -newermt "$mtime_floor" 2>/dev/null)"
  else
    main_files="$(for mf in "$pf"*.jsonl; do [ -e "$mf" ] && printf '%s\n' "$mf"; done)"
  fi
  while IFS= read -r mf; do
    [ -n "$mf" ] || continue
    files_scanned=$((files_scanned + 1))
    sid="$(basename "$mf" .jsonl)"
    scan_main "$mf" "$proj" "$sid"
  done <<< "$main_files"
  if [ "$newermt_ok" = "1" ]; then
    sub_files="$(find "$pf" -path '*/subagents/agent-*.jsonl' -newermt "$mtime_floor" 2>/dev/null)"
  else
    sub_files="$(for sf in "$pf"*/subagents/agent-*.jsonl; do [ -e "$sf" ] && printf '%s\n' "$sf"; done)"
  fi
  while IFS= read -r sf; do
    [ -n "$sf" ] || continue
    files_scanned=$((files_scanned + 1))
    base="$(basename "$sf")"; aid="${base#agent-}"; aid="${aid%.jsonl}"
    scan_sub "$sf" "$proj" "$aid"
  done <<< "$sub_files"
done < "$tmp/projdirs.txt"

# =============================================================================
# JOIN + DEDUP + WINDOW + PRICE + GROUP, in one jq program (single source of
# truth for the dedup/window rules, rather than re-deriving them per axis).
# =============================================================================
jq -n \
  --arg since "$since" --arg until "$until" \
  --arg projects_dir_status "$projects_dir_status" \
  --arg table_date "$table_date" \
  --argjson price_table_overridden "$price_table_overridden" \
  --argjson files_scanned "$files_scanned" \
  --arg project_filter "$project_filter" \
  --arg project_status "$project_status" \
  --slurpfile pricefile "$price_table" \
  -f /dev/stdin "$tmp/raw.ndjson" <<'JQPROG'
def r6(n): (n*1000000|round)/1000000;

def sumtok(rows):
  { input:          (rows | map(.tok.input) | add // 0),
    cache_write_5m: (rows | map(.tok.cache_write_5m // 0) | add // 0),
    cache_write_1h: (rows | map(.tok.cache_write_1h // 0) | add // 0),
    cache_read:     (rows | map(.tok.cache_read) | add // 0),
    output:         (rows | map(.tok.output) | add // 0) };
def sumdollars(rows): r6(rows | map(select(.priced)) | map(.dollars) | add // 0);
def sumunpriced(rows):
  (rows | map(select(.priced|not))
        | map(.tok.input + .tok.output + .tok.cache_read
              + (.tok.cache_write_5m // 0) + (.tok.cache_write_1h // 0)
              + .tok.cache_write_unsplit)
        | add // 0);
def sumunsplit(rows): (rows | map(.tok.cache_write_unsplit) | add // 0);

# `keyfn` is a filter parameter re-applied per group (same idiom as
# metrics.sh's `sumtok(f)`), not a closed-over value.
def groupreport(rows; keyfn):
  rows | group_by(keyfn) | map({
    key: (.[0] | keyfn | tostring),
    value: { tokens: sumtok(.), dollars: sumdollars(.), unpriced_tokens: sumunpriced(.),
             cache_write_unmeasured_tokens: sumunsplit(.), priced: (sumunpriced(.) == 0) }
  }) | from_entries;

[inputs] as $raw
| ($pricefile[0].prices // {}) as $P
| ($raw | map(select(.kind=="excluded_no_usage_or_ts")) | length) as $exc_no_usage_ts
| ($raw | map(select(.kind=="excluded_synthetic")) | length) as $exc_synth
| ($raw | map(select(.kind=="turn"))) as $turns0
| ($turns0 | map(select(.id != null))) as $with_id
| ($turns0 | map(select(.id == null))) as $no_id
| ($with_id | length) as $with_id_total
# DEDUP (mirrors metrics.sh ADR 0019 v3.3): keep the EARLIEST row per message
# id; id-less rows are kept verbatim — `.uuid` is per-row, not per-message, so
# keying on it would silently dedupe nothing while looking like it worked.
# DEDUP RUNS BEFORE WINDOWING (M4, loop-measurement): a message whose earliest
# row sits just outside [since,until] but whose duplicate (observed up to +26s
# in the wild) sits inside it drops out of the window entirely, because the
# earliest row wins the dedup and that row is the one that then fails the
# window test below. Rare and bounded (duplicates land seconds apart, not
# windows apart) and arguably the right trade — an in-window duplicate of an
# out-of-window message is not new spend — but left uncorrected on purpose so
# this isn't rediscovered as a bug: fixing it would mean windowing first and
# deduping per-window, which reintroduces the SAME message being "new" again
# in the next window if its earliest row fell in a different one.
| ( $with_id | group_by(.id) | map(sort_by(.ts // "") | .[0]) ) as $with_id_deduped
| ( $with_id_total - ($with_id_deduped | length) ) as $dedup_dropped
| ( $with_id_deduped + $no_id ) as $deduped
# WINDOW: second-precision string comparison, both bounds inclusive (see
# header note on why this is a string compare, not an epoch compare).
| ( $deduped | map(select(
      (.ts != null)
      and (.ts[0:19] >= ($since[0:19]))
      and (.ts[0:19] <= ($until[0:19]))
    )) ) as $inwin
| ( $inwin | map(select(.id == null)) | length ) as $no_id_in_window
# PRICE each in-window row. A model absent from the table prices as 0 with
# priced:false — never $0-as-if-free; sumunpriced() carries the true token
# count so it is never silently read as "no cost".
| ( $inwin | map(
      . as $r
      | ($P[$r.model]) as $rt
      | $r + {
          priced: ($rt != null),
          dollars: (if $rt == null then 0 else
              r6( ( ($r.tok.input // 0) * ($rt.input // 0)
                  + ($r.tok.cache_write_5m // 0) * ($rt.cache_write_5m // 0)
                  + ($r.tok.cache_write_1h // 0) * ($rt.cache_write_1h // 0)
                  + ($r.tok.cache_read // 0) * ($rt.cache_read // 0)
                  + ($r.tok.output // 0) * ($rt.output // 0)
                  ) / 1000000 )
            end)
        }
    ) ) as $priced_rows
| {
    window: { since: $since, until: $until },
    # NO ABSOLUTE PATHS (I4, loop-measurement T9 P0): neither field below carries
    # a filesystem path or a username. `date`/`overridden` are what a reader
    # actually needs (which table, whether it is the bundled default); `status`
    # says whether the scan directory existed. The path itself added nothing the
    # report needs and leaked $HOME on a default run.
    price_table: { date: $table_date, overridden: $price_table_overridden },
    label: "API-equivalent spend estimate from published per-token API prices — not a bill.",
    projects_dir: { status: $projects_dir_status },
    # `filter` is the SAME folder-name shape as a by_project key (per the note
    # above, that name is already a dash-encoded path by Claude Code's own
    # convention — nothing new leaks). `status`: "present" when that exact
    # folder was found and scanned, "absent" when --project named a folder
    # that does not exist under projects_dir (an empty, zero-valued report
    # follows — not an error, same rule as projects_dir being absent),
    # "not_filtered" when --project was not given at all (prior, unscoped
    # behavior, unchanged).
    project: { filter: (if $project_filter == "" then null else $project_filter end),
               status: $project_status },
    counts: {
      files_scanned: $files_scanned,
      messages_counted: ($priced_rows | length),
      messages_no_id: $no_id_in_window,
      messages_deduped_dropped: $dedup_dropped,
      messages_excluded_no_usage_or_ts: $exc_no_usage_ts,
      messages_excluded_synthetic: $exc_synth
    },
    totals: {
      tokens: sumtok($priced_rows),
      dollars: sumdollars($priced_rows),
      unpriced_tokens: sumunpriced($priced_rows),
      cache_write_unmeasured_tokens: sumunsplit($priced_rows)
    },
    by_project: groupreport($priced_rows; .project),
    by_model:   groupreport($priced_rows; .model),
    by_role:    groupreport($priced_rows; .role),
    by_effort:  groupreport($priced_rows; (.effort // "unrecorded")),
    unmeasured: (
      [ (if $project_status == "absent" then
           "--project \"\($project_filter)\" does not match any project folder under projects_dir: no transcripts were scanned, so every figure in this report is zero because nothing matched — not because nothing was spent."
         else empty end),
        (if sumunsplit($priced_rows) > 0 then
           "cache-write 5m/1h split unavailable for \(sumunsplit($priced_rows)) token(s): the transcript usage block lacked the cache_creation breakdown object, so those tokens are excluded from dollar totals (never guessed which lifetime)."
         else empty end),
        ($priced_rows | map(select(.role=="unrecorded")) | length) as $urole
        | (if $urole > 0 then
             "\($urole) message(s) had no readable agent role (subagent transcript missing .attributionAgent); grouped as agent role 'unrecorded'."
           else empty end),
        (if (($priced_rows | length) > 0) and (($priced_rows | map(select(.effort==null)) | length) == ($priced_rows | length)) then
           "no scanned message in this window recorded an effort level; all grouped under 'unrecorded' in by_effort."
         else empty end),
        ($priced_rows | map(select(.model=="unrecorded")) | length) as $umodel
        | (if $umodel > 0 then
             "\($umodel) message(s) had no readable model id; grouped as model 'unrecorded' and priced as unpriced."
           else empty end)
      ]
    ),
    notes: [
      "dollars are API-equivalent estimates from the price table above, not a subscription bill.",
      "messages are deduplicated by message id, keeping the earliest row per id; id-less rows are counted and priced as-is (see counts.messages_no_id).",
      "messages_deduped_dropped is SCAN-scoped (every row in every file the mtime pre-filter let through), while messages_counted and every other counts.*/totals.* field is WINDOW-scoped (--since/--until) -- do not divide one by the other as a duplication rate, they are not counting the same set of rows.",
      "no message content, prompt text, or filesystem path is included in this report; projects are identified by Claude-projects folder name only (those folder names are dash-encoded absolute paths by Claude Code's own convention, so by_project keys are the one place a path shape survives)."
    ]
  }
JQPROG
