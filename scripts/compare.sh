#!/usr/bin/env bash
# =============================================================================
# compare.sh — the model-comparison harness (model-comparison-harness)
# =============================================================================
# Replays packets that already landed, varying one role's model through
# `model_routing` and holding a blinded reviewer fixed as the judge. This file
# grows one subcommand per plan task; see gspec/features/model-comparison-harness.
#
# Usage:  compare.sh <subcommand> [args]
#
#   settings <file>   read an experiment settings file (annotated reference:
#                     templates/model-comparison.yaml), apply the defaults and
#                     print the normalized settings, one `KEY=value` line each,
#                     in this fixed order:
#                       ROLE= MODELS= REVIEWER_MODEL= SOURCE_REPO= PER_CLASS=
#                       CODE_FILES= PROSE_FILES=
#                     then `EXPERIMENT=<12 hex>`, a digest of exactly those
#                     seven lines. List values are sorted (LC_ALL=C), de-duped
#                     and comma-joined, so settings that differ only in key
#                     order, item order or repeats get the same id.
#
#                     A setting that cannot be used is REFUSED: one line per
#                     refusal on stderr,
#                       REFUSED setting=<key> value=<value> reason=<reason>
#                     and exit 1, with nothing on stdout. Refusals come in two
#                     phases. Phase 1 (the file itself, every scalar and the
#                     role) reads nothing but the settings file. Phase 2 (each
#                     `models` / `reviewer_model` entry) additionally reads the
#                     source repository's `.agents/project-overrides.yaml` and
#                     runs routing.sh against a temp root. Neither phase runs
#                     git: every refusal happens before any git read.
#
#   candidates <file> read the settings exactly as `settings` does (the same
#                     refusals, before any git read), then list every packet
#                     with an `[orch packet:<id>]` trailer on its own line in
#                     any commit of the source repository (`git log --all`).
#                     One line per packet, oldest first (the order of each
#                     packet's earliest trailer commit):
#                       CANDIDATE packet=<id> class=<code|prose> handoff=<original|rebuilt> start=<sha> commits=<sha,...>
#                       DROPPED packet=<id> class=neither
#                       EXCLUDED packet=<id> reason=<why>
#                     `commits` lists every trailer commit of the packet,
#                     earliest first (--author-date-order: ancestry first,
#                     then author date); `start`, the replay start, is the
#                     earliest one's first parent. Class is decided from the
#                     union of those commits' changed files, each commit's
#                     `gspec/` files dropped when that commit changed only
#                     checkbox characters in them: code when a file is in
#                     CODE_FILES, prose when none is and one is in
#                     PROSE_FILES, neither otherwise (not a candidate). A set
#                     item ending in `/` matches by prefix; any other item
#                     matches that file or anything beneath it. The handoff is
#                     `original` when `.agents/loop/*/<id>/handoff.md` exists
#                     in the source repository, else `rebuilt` when
#                     gspec-backlog.sh (beside this script) resolves the task
#                     against the start commit's `gspec/` tree; a packet with
#                     neither is EXCLUDED with the reason. This script never
#                     parses a gspec file: resolution is the adapter's.
#
#   select <file>     choose the experiment's packets from `candidates`, per
#                     class, and store the choice ONCE as
#                       <store>/<EXPERIMENT>/selection.json
#                     where <store> is `.agents/metrics/comparisons` in the
#                     main checkout of the repository this script runs from
#                     (ORCH_COMPARE_STORE overrides it). When that file already
#                     exists it is printed back unchanged and nothing is
#                     recomputed; otherwise it is computed, written and
#                     printed. Stdout is always the stored file's bytes; one
#                     line on stderr says which happened.
#                     Per class, from that class's candidates only, taken
#                     newest first (the reverse of the `candidates` order):
#                       1. the newest packet whose fix rounds are 1 or more;
#                       2. while fewer than two distinct recorded tiers are
#                          chosen, the newest packet with a recorded tier not
#                          yet chosen;
#                       3. the rest newest first, up to PER_CLASS.
#                     Tier is the own-line `[orch tier:<tier>]` trailer of the
#                     latest of the packet's trailer commits carrying one, else
#                     `unrecorded`, which is an absence and never counts toward
#                     the tier mix. Fix rounds are the `fix` routing records for
#                     the packet across the source's `.agents/loop/*/routing.jsonl`;
#                     a packet with no routing record there at all (pruned, or
#                     run before routing records existed) reads `unmeasured`,
#                     never 0. Title is the earliest trailer commit's subject.
#                     A class short of its count, of two recorded tiers or of a
#                     measured fix round gets a `shortfalls` entry; a gap is
#                     never filled from the other class. EXCLUDED and DROPPED
#                     packets from `candidates` are named in the selection.
#
#   estimate <experiment> [--remaining]
#                     state the spend of the experiment's stored selection
#                     (`select` first) and issue the approval token for it.
#                     The replay set is every selected packet × every model,
#                     in stored order (packet, then model); under --remaining,
#                     only the replays with no stored record. A record counts
#                     for a replay when a line of <store>/records.jsonl has
#                     top-level `experiment`, `packet` and `model` fields equal
#                     to it (any outcome, `invalid` included). Output, in order:
#                       EXPERIMENT= SCOPE=<all|remaining> MODELS= PACKETS=
#                       RECORDED=<replays already recorded> REPLAYS=<count>
#                       REPLAY packet=<id> model=<m>        one per replay
#                       PRICE_TABLE_DATE=<the table's table_date>
#                       EXCLUDED packet=<id> reason=<why>   unmeasured cost
#                       UNPRICED model=<m> reason=<why>
#                       ESTIMATE model=<m|total> replays= estimated= tokens=
#                         input= output= cache_creation= cache_read=
#                         dollars_min= dollars_max= [price=<basis>]
#                       NOTE ...
#                       APPROVAL=<token>   (`none` when no replay is in the set)
#                     THE ESTIMATE RULE (the plan's decision 3): tokens are
#                     held constant and priced per model. A packet's forecast
#                     is its original recorded `packets[].tokens` from the
#                     source repository's `.agents/metrics/*/run-metrics.json`
#                     (the newest `generated_at` row whose four token fields
#                     are numbers, whose file's token_source is a transcript
#                     one, and whose sum is not 0), identical for every model;
#                     fix rounds are not modelled. A packet with no such row is
#                     EXCLUDED and named: its cost is unmeasured, never 0.
#                     `estimated` counts the replays the figures cover. Prices
#                     come from ${ORCH_COMPARE_PRICES:-spend-prices.json beside
#                     this script}: the entry keyed by the model itself, else
#                     the `claude-<model>-*` entries when all of them carry the
#                     same five rates (`price=family:<ids>`); otherwise the
#                     model is UNPRICED and its dollars read `unmeasured`, as
#                     does the total's. Packet tokens do not split cache writes
#                     by lifetime, so dollars_min prices them all at the
#                     5-minute rate and dollars_max at the 1-hour rate.
#                     The token is single-use and bound to exactly the printed
#                     set: one line appended to <store>/<experiment>/approvals.jsonl
#                       {"token", "state": "pending", "scope", "issued_at",
#                        "set": <digest of the REPLAY lines>, "replays": [...]}
#                     before it is printed. Append-only: the newest pending
#                     line supersedes every earlier one; `run` consumes it.
#
#   prepare <experiment> <packet> <model>
#                     build one replay's isolated work clone from the stored
#                     selection (`select` first). <packet> must be selected and
#                     <model> one of the settings' models. Steps, in order:
#                       1. `git clone --shared --no-checkout` of the source
#                          repository into <scratch>/<16 hex>, where <scratch> is
#                          ${ORCH_COMPARE_SCRATCH:-${TMPDIR:-/tmp}} and must lie
#                          outside the source's working tree; check out the
#                          packet's stored `start` (the earliest trailer
#                          commit's first parent) on a new branch
#                          `replay-<16 hex>`, then delete every other local
#                          branch and the `origin` remote, so the clone's refs
#                          are that one branch (and any tags) and nothing it does
#                          can reach the source. Neither name contains any of
#                          the settings' model identifiers (checked,
#                          case-insensitive, and redrawn when one does).
#                       2. rewrite the clone's `.agents/project-overrides.yaml`
#                          so `model_routing` maps the settings' role to <model>
#                          and `reviewer` to the settings' reviewer model. Every
#                          other entry, key, comment and line is kept as it was
#                          (a flow-form map becomes a block; an absent key is
#                          appended). Then `routing.sh --root <clone> resolve`
#                          must print exactly those two models, or it is refused.
#                       3. write a minimal run-state and run `runstate.sh
#                          begin-run` in the clone.
#                       4. install the packet's handoff at
#                          <clone>/.agents/loop/<run_id>/<packet>/handoff.md
#                          from the experiment's handoff cache,
#                            <store>/<experiment>/handoffs/<packet>.md
#                          written ONCE per packet (never replaced), so every
#                          model's replay receives identical bytes. On a miss the
#                          cache is filled from the `original` handoff (the
#                          source's earliest `.agents/loop/*/<packet>/handoff.md`,
#                          the one `candidates` finds first) as first
#                          dispatched, loop splice blocks removed: every
#                          `orch:decider-amendment` and `orch:partial-work`
#                          span the loop added after that dispatch is dropped
#                          as `amend-handoff`/`refresh-handoff` placed it, and
#                          every other byte is kept, the budget block included
#                          (a marker it cannot place that way is refused); or,
#                          for a `rebuilt` one, from
#                          `gspec-backlog.sh handoff <packet> <clone>` piped into
#                          `runstate.sh handoff <run-state> <packet> --tier
#                          <stored tier> --agent <role>` in the clone, which
#                          appends the verification contract exactly as a live
#                          handoff gets it. The stored tier is passed as it
#                          stands, `unrecorded` included: never a guessed tier.
#                     Output (and <store>/<experiment>/replays/<replay>.env,
#                     the same lines, where <replay> is a fresh 12 hex id):
#                       REPLAY= EXPERIMENT= PACKET= MODEL= ROLE=
#                       REVIEWER_MODEL= SOURCE_REPO= START= CLONE= BRANCH=
#                       RUN_STATE= RUN_ID= HANDOFF= HANDOFF_SOURCE=<original|rebuilt>
#                       HANDOFF_CACHE= HANDOFF_CACHED=<written|reused>
#                     Nothing is written in the source repository outside
#                     the experiment's own store, <store>/<experiment>/: its
#                     tree, `.agents/` and refs are otherwise unchanged (the
#                     default store lies inside the harness's main checkout,
#                     so when that is the source the handoff cache and
#                     replay records land under its `.agents/metrics/`,
#                     which this repository's .gitignore ignores). The source
#                     handoff is only read, never modified. On any failure the
#                     half-built clone is removed. The scripts used are the
#                     ones beside this file, never the clone's own copies.
#                     A cached handoff's header names the run-state, result
#                     and review paths of wherever it was written (the source
#                     run for an original, the first clone for a rebuild):
#                     identical bytes mean those paths are not this clone's.
#
#   review-view <replay>
#                     build the checkout a reviewer is given for a prepared
#                     replay (its record, <store>/*/replays/<replay>.env, must
#                     exist in exactly one experiment): a second opaque clone
#                     that names none of the settings' models. Steps, in order:
#                       1. the work clone's current diff against the start
#                          (committed on its branch, staged, unstaged and
#                          untracked-but-not-ignored alike) is taken as a tree,
#                          through a temp index and a temp object directory, so
#                          the work clone itself is only read. Everything under
#                          `.agents/metrics/` and `.agents/loop/`, and the
#                          run-state (`.agents/run-state.yaml`,
#                          `.agents/run-state-prev.yaml`), stays as the start
#                          holds it. `.agents/project-overrides.yaml` keeps the
#                          packet's own edits but its `model_routing` is reduced
#                          to the one `reviewer: <reviewer model>` entry (every
#                          other entry dropped, the start's included), so the
#                          replay's routing change is not in the view.
#                       2. `git clone --shared --no-checkout` of the source at
#                          the start into <scratch>/<16 hex>, on the one branch
#                          `review-<16 hex>`, with no remote, as `prepare` does.
#                          Refused when the scratch root's path names a model.
#                       3. commit A (only when the start's own `model_routing`
#                          is not already reviewer-only): the start with that
#                          reduced configuration; commit B: A plus the change.
#                          Both are made by `git commit-tree` (no hook, no
#                          template, no trailer) with a fixed author, committer,
#                          date and message: "Review configuration" and
#                          "Changes under review", by compare
#                          <compare@example.invalid> at 2000-01-01T00:00:00Z.
#                          B's tree must equal the tree built in step 1, and
#                          `routing.sh --root <view> resolve reviewer` must print
#                          the reviewer model, or it is refused. The change under
#                          review is BASE..HEAD.
#                       4. a run-state (`last_green_commit` = BASE) and
#                          `runstate.sh begin-run` in the view.
#                       5. under <view>/.agents/loop/<run_id>/<packet>/: the work
#                          clone's current handoff as `handoff.md`, and its result
#                          file (<clone>/.agents/loop/<run_id>/<packet>/<role>.md)
#                          as `<role>.md`, each with every word containing an
#                          identifier of the settings' models (each model and
#                          the reviewer's, as the settings name them, which is
#                          also the routing alias; a resolved id such as
#                          `claude-<alias>-5` contains its alias), matched
#                          case-insensitively, replaced by `[model]` together
#                          with a directly following version number. The
#                          handoff header's `run-state:`, `result:` and
#                          `review:` lines are pointed at the view's own paths.
#                     Output (the view's path is also appended as a `VIEW=`
#                     line to <store>/<experiment>/replays/<replay>.views):
#                       REPLAY= VIEW= BRANCH= START= BASE= HEAD= RUN_STATE=
#                       RUN_ID= HANDOFF= RESULT=<path|none> REVIEW=<path>
#                     The reviewed change's own content is carried as it is:
#                     a diff that itself names a model is not redacted, since
#                     redacting it would change the work under review. On any
#                     failure the half-built view is removed.
#
# Exit status: 0 printed settings / candidates / a selection / an estimate / a
# prepared replay / a review view; 1 refused, no experiment id could be computed, the source
# repository is not a git repository, the selection could not be written, or
# (estimate) no stored selection, an unreadable selection, records file or
# price table, or the token could not be stored, or (prepare) no stored
# selection, a packet or model outside it, a scratch root inside the source,
# or a clone, routing, run-state or handoff step that failed, or (review-view)
# no single replay record, a work clone, source or selection that cannot be
# read, a scratch root inside the source or naming a model, or a diff, clone,
# commit, routing, run-state or redaction step that failed; 2 usage error,
# or routing.sh / gspec-backlog.sh / runstate.sh missing beside this script.
#
# Portability: awk + bash 3.2 (no associative arrays), no jq, no python3.
# =============================================================================

set -uo pipefail
set -f   # no globbing: list items are split on `,` and must never expand

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROUTING="$HERE/routing.sh"
BACKLOG="$HERE/gspec-backlog.sh"
RUNSTATE="$HERE/runstate.sh"
AGENTS_DIR="${ORCH_ROUTING_AGENTS_DIR:-$HERE/../agents}"

# --- REPLAYABLE_ROLES: the roles an experiment may vary ------------------------
# Stated once, here. These are the agents a `run-loop` §3.2 handoff may name as
# `--agent` (implementer for mechanical/integration, architect or ux-designer
# for design-heavy, doc-writer for docs) — the only dispatches a replay drives
# from a handoff. Deliberately absent:
#   reviewer        the fixed judge of every experiment, never a subject.
#   loop-driver     the session itself; routing never sets its model.
#   chief-engineer  the escalation decider, which never runs inside a replay,
#                   so varying its model would measure nothing.
REPLAYABLE_ROLES=(implementer architect ux-designer doc-writer)

# --- the defaults (model-comparison-harness PRD, first experiment) ------------
# SOURCE_REPO defaults to the checkout this script runs from ("this
# repository"), found without git. REVIEWER_MODEL defaults to what the loop's
# reviewer runs on in the source repository today: its `model_routing` entry
# through routing.sh, else the reviewer agent's frontmatter model.
DEFAULT_ROLE="implementer"
DEFAULT_MODELS="fable,opus,sonnet"
DEFAULT_PER_CLASS="8"
DEFAULT_CODE_FILES="scripts/,hooks/"
DEFAULT_PROSE_FILES="agents/,skills/,templates/,docs/,CLAUDE.md"

die()   { printf 'compare.sh: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { printf 'usage: compare.sh {settings|candidates|select} <file> | estimate <experiment> [--remaining] | prepare <experiment> <packet> <model> | review-view <replay>\n' >&2; exit 2; }

# --- digest: 12 hex of sha256 over stdin, probed by execution ------------------
digest() {
  local data out
  data="$(cat)"
  out="$(printf '%s' "$data" | sha256sum 2>/dev/null)"
  if [ -z "$out" ]; then out="$(printf '%s' "$data" | shasum -a 256 2>/dev/null)"; fi
  [ -n "$out" ] || die "no sha256 tool (sha256sum or shasum) available"
  printf '%s' "${out%% *}" | cut -c1-12
}

# --- settings-file parse (awk token-scan) --------------------------------------
# Emits tab-separated records, in file order:
#   S <key> <value>     a scalar `key: value`
#   L <key> <item>      one list item (flow `[a, b]` or block `- a`)
#   E <key>             a list key given no items (`key: []` or a bare `key:`)
#   D <key>             a key seen a second time (its value is ignored)
#   X <line-no>         a line that is not `key: value`, a list item or comment
#   U <key>             a list the parser could not read
parse_settings() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function uncomment(s) {
      if (s ~ /^#/) return ""
      sub(/[[:space:]]+#.*$/, "", s)
      return s
    }
    function unquote(s) {
      if (length(s) >= 2 && (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/)) s = substr(s, 2, length(s) - 2)
      return s
    }
    function close_block() {
      if (mode == "block" && nitems == 0) print "E\t" cur
      mode = ""
    }
    BEGIN { mode = ""; cur = ""; nitems = 0 }
    { sub(/\r$/, "") }
    {
      line = $0
      t = trim(line)
      if (t == "" || t ~ /^#/) next
      if (line ~ /^[[:space:]]/ || line ~ /^-([[:space:]]|$)/) {
        if (mode == "skip") next
        if (mode != "block") { print "X\t" NR; next }
        body = trim(uncomment(t))
        if (body !~ /^-([[:space:]]|$)/) { print "U\t" cur; mode = "skip"; next }
        sub(/^-[[:space:]]*/, "", body)
        item = unquote(trim(body))
        if (item == "") { print "U\t" cur; mode = "skip"; next }
        print "L\t" cur "\t" item
        nitems++
        next
      }
      close_block()
      p = match(line, /:([[:space:]]|$)/)
      if (p == 0) { print "X\t" NR; next }
      k = trim(substr(line, 1, p - 1))
      rest = trim(uncomment(trim(substr(line, p + 1))))
      if (k in seen) { print "D\t" k; mode = "skip"; next }
      seen[k] = 1
      cur = k
      if (rest == "") { mode = "block"; nitems = 0; next }
      if (rest ~ /^\[/) {
        if (rest !~ /\]$/) { print "U\t" k; next }
        inner = trim(substr(rest, 2, length(rest) - 2))
        if (inner == "") { print "E\t" k; next }
        if (inner ~ /[\[\]{}]/) { print "U\t" k; next }
        n = split(inner, pcs, ",")
        for (i = 1; i <= n; i++) {
          it = unquote(trim(pcs[i]))
          if (it == "") { if (i == n && n > 1) continue; print "U\t" k; break }
          print "L\t" k "\t" it
        }
        next
      }
      if (rest ~ /^\{/) { print "U\t" k; next }
      print "S\t" k "\t" unquote(rest)
    }
    END { close_block() }
  ' "$1" 2>/dev/null
}

# --- refusal collection ----------------------------------------------------------
REFUSALS=()
refuse() { REFUSALS+=("REFUSED setting=$1 value=$2 reason=$3"); }
flush_refusals() {
  if [ "${#REFUSALS[@]}" -gt 0 ]; then
    printf '%s\n' "${REFUSALS[@]}" >&2
    exit 1
  fi
}

# norm_list <csv> -> sorted, de-duped, comma-joined (LC_ALL=C).
norm_list() {
  printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

# role_is_replayable <role>
role_is_replayable() {
  local r
  for r in "${REPLAYABLE_ROLES[@]}"; do
    [ "$r" = "$1" ] && return 0
  done
  return 1
}

# frontmatter_model <agent> -> the `model:` inside the leading `---` block.
frontmatter_model() {
  local f="$AGENTS_DIR/$1.md"
  [ -f "$f" ] || return 0
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^model:/ {
      v = $0
      sub(/^model:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      print v
      exit
    }
  ' "$f" 2>/dev/null
}

# extra_models_block <overrides-file> -> the top-level `extra_models:` key and
# every line belonging to it, verbatim, so routing.sh parses it exactly as it
# parses the source repository's own file.
extra_models_block() {
  [ -f "$1" ] || return 0
  awk '
    { sub(/\r$/, "") }
    on && ($0 ~ /^[[:space:]]/ || $0 ~ /^-([[:space:]]|$)/ || $0 ~ /^[[:space:]]*$/ || $0 ~ /^#/) { print; next }
    { on = 0 }
    /^extra_models:/ { on = 1; print }
  ' "$1" 2>/dev/null
}

cmd_settings() {
  [ $# -eq 1 ] || usage
  local file="$1"
  [ -f "$file" ] || die "settings: no such file: $file" 2
  local file_dir
  file_dir="$(cd "$(dirname "$file")" && pwd -P)"

  # --- phase 1: the file, the scalars and the role (no git, no source read) ---
  local role="" role_set=0 models="" models_set=0 reviewer="" reviewer_set=0
  local source="" source_set=0 per_class="" per_class_set=0
  local code="" code_set=0 prose="" prose_set=0
  local parsed kind k v
  parsed="$(parse_settings "$file" | tr -d '\r')"
  while IFS="$(printf '\t')" read -r kind k v; do
    [ -n "$kind" ] || continue
    case "$kind" in
      X) refuse "-" "line-$k" "unparseable(not a key: value line or list item)"; continue ;;
      D) refuse "$k" "-" "duplicate-setting"; continue ;;
      U) refuse "$k" "-" "unparseable-list"; continue ;;
    esac
    case "$k" in
      role|reviewer_model|source_repo|per_class)
        case "$kind" in
          S) case "$k" in
               role)           role="$v";      role_set=1 ;;
               reviewer_model) reviewer="$v";  reviewer_set=1 ;;
               source_repo)    source="$v";    source_set=1 ;;
               per_class)      per_class="$v"; per_class_set=1 ;;
             esac ;;
          *) refuse "$k" "-" "expected-a-single-value" ;;
        esac ;;
      models|code_files|prose_files)
        case "$kind" in
          S|L)
            # An item is one token: a comma or whitespace inside it would be
            # split apart below, so each half would be judged (and printed)
            # as if it were a separate item.
            case "$v" in *,*) refuse "$k" "$v" "comma-in-item"; continue ;; esac
            case "$v" in *[[:space:]]*) refuse "$k" "$v" "whitespace-in-item"; continue ;; esac
            case "$k" in
              models)      models="${models:+$models,}$v"; models_set=1 ;;
              code_files)  code="${code:+$code,}$v";       code_set=1 ;;
              prose_files) prose="${prose:+$prose,}$v";    prose_set=1 ;;
            esac ;;
          E) case "$k" in
               models)      models_set=1 ;;
               code_files)  code_set=1 ;;
               prose_files) prose_set=1 ;;
             esac ;;
        esac ;;
      *) refuse "$k" "-" "unknown-setting(known: role models reviewer_model source_repo per_class code_files prose_files)" ;;
    esac
  done <<EOF
$parsed
EOF

  [ "$role_set" -eq 1 ] || role="$DEFAULT_ROLE"
  [ "$models_set" -eq 1 ] || models="$DEFAULT_MODELS"
  [ "$per_class_set" -eq 1 ] || per_class="$DEFAULT_PER_CLASS"
  [ "$code_set" -eq 1 ] || code="$DEFAULT_CODE_FILES"
  [ "$prose_set" -eq 1 ] || prose="$DEFAULT_PROSE_FILES"

  # role: the reviewer, the loop-driver session, or anything outside the set.
  case "$role" in
    reviewer)    refuse role "$role" "reviewer-is-the-fixed-judge" ;;
    loop-driver) refuse role "$role" "loop-driver-is-the-session" ;;
    *) if ! role_is_replayable "$role"; then
         refuse role "$role" "not-replay-dispatchable(replayable: ${REPLAYABLE_ROLES[*]})"
       fi ;;
  esac

  # per_class: a positive integer, normalized (08 -> 8).
  case "$per_class" in
    ''|*[!0-9]*) refuse per_class "$per_class" "not-a-positive-integer" ;;
    *) per_class="$(printf '%s' "$per_class" | sed 's/^0*//')"
       [ -n "$per_class" ] || refuse per_class "0" "not-a-positive-integer" ;;
  esac

  # models / reviewer_model: an alias token routing.sh can be handed safely.
  local m
  [ -n "$models" ] || refuse models "-" "empty-list"
  for m in $(printf '%s' "$models" | tr ',' ' '); do
    case "$m" in *[!A-Za-z0-9._-]*) refuse models "$m" "invalid-model-token" ;; esac
  done
  if [ "$reviewer_set" -eq 1 ]; then
    case "$reviewer" in
      ''|*[!A-Za-z0-9._-]*) refuse reviewer_model "$reviewer" "invalid-model-token" ;;
    esac
  fi

  # code_files / prose_files: repo-relative path prefixes, a leading ./ dropped.
  local set_name set_val item out_list
  for set_name in code_files prose_files; do
    if [ "$set_name" = code_files ]; then set_val="$code"; else set_val="$prose"; fi
    [ -n "$set_val" ] || { refuse "$set_name" "-" "empty-list"; continue; }
    out_list=""
    for item in $(printf '%s' "$set_val" | tr ',' ' '); do
      item="${item#./}"
      case "$item" in
        ''|/*|*[!A-Za-z0-9._/@+-]*) refuse "$set_name" "$item" "not-a-repo-relative-path" ; continue ;;
      esac
      case "/$item/" in
        */../*|*/./*) refuse "$set_name" "$item" "not-a-repo-relative-path"; continue ;;
      esac
      out_list="${out_list:+$out_list,}$item"
    done
    if [ "$set_name" = code_files ]; then code="$out_list"; else prose="$out_list"; fi
  done

  # source_repo: a directory, relative paths resolved against the settings file.
  if [ "$source_set" -eq 1 ]; then
    case "$source" in /*) ;; *) source="$file_dir/$source" ;; esac
    if [ -d "$source" ]; then
      source="$(cd "$source" && pwd -P)"
    else
      refuse source_repo "$source" "not-a-directory"
    fi
  else
    source="$(cd "$HERE/.." && pwd -P)"
  fi

  flush_refusals

  # --- phase 2: each model through routing.sh's own validation ---------------
  # A temp root carries the source repository's `extra_models` verbatim plus one
  # `model_routing` entry, so routing.sh judges the model exactly as it judges a
  # live `model_routing` value in that repository.
  local tmp ex out line
  # routing.sh prints nothing for a clean config, so a routing.sh that could
  # not run would read as "every model accepted": require it up front.
  [ -x "$ROUTING" ] || die "settings: routing.sh is missing or not executable: $ROUTING" 2
  tmp="$(mktemp -d 2>/dev/null)" || die "settings: cannot create a temp root"
  mkdir -p "$tmp/.agents"
  ex="$(extra_models_block "$source/.agents/project-overrides.yaml")"

  # validate_model <setting> <routing-key> <model>: refuse on any report line
  # naming <routing-key>; carry the source's own extra_models report alongside.
  validate_model() {
    {
      printf 'model_routing:\n  %s: %s\n' "$2" "$3"
      if [ -n "$ex" ]; then printf '%s\n' "$ex"; fi
    } > "$tmp/.agents/project-overrides.yaml"
    out="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$tmp" validate 2>/dev/null | tr -d '\r')"
    local refused=0 exnote=""
    while IFS= read -r line; do
      case "$line" in
        "ROUTING-INVALID key=$2 value=$3 reason="*)
          refuse "$1" "$3" "${line#"ROUTING-INVALID key=$2 value=$3 reason="}"; refused=1 ;;
        "ROUTING-INVALID key=extra_models "*)
          exnote="$line" ;;
      esac
    done <<EOF2
$out
EOF2
    if [ "$refused" -eq 1 ] && [ -n "$exnote" ]; then
      REFUSALS+=("NOTE source extra_models: $exnote")
    fi
  }

  models="$(norm_list "$models")"
  for m in $(printf '%s' "$models" | tr ',' ' '); do
    validate_model models "$role" "$m"
  done

  if [ "$reviewer_set" -eq 0 ]; then
    reviewer="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$source" resolve reviewer 2>/dev/null | tr -d '\r')"
    [ -n "$reviewer" ] || reviewer="$(frontmatter_model reviewer)"
    if [ -z "$reviewer" ]; then
      refuse reviewer_model "-" "no-default(the source repository routes no reviewer model and the reviewer agent names none; set reviewer_model)"
    fi
  fi
  if [ -n "$reviewer" ]; then
    case "$reviewer" in
      *[!A-Za-z0-9._-]*) refuse reviewer_model "$reviewer" "invalid-model-token" ;;
      *) validate_model reviewer_model reviewer "$reviewer" ;;
    esac
  fi
  rm -rf "$tmp"

  flush_refusals

  # --- normalized output -----------------------------------------------------
  local body
  body="ROLE=$role
MODELS=$models
REVIEWER_MODEL=$reviewer
SOURCE_REPO=$source
PER_CLASS=$per_class
CODE_FILES=$(norm_list "$code")
PROSE_FILES=$(norm_list "$prose")"
  # The id is produced before anything is printed: an id that could not be
  # computed is a failure with nothing on stdout, never an empty EXPERIMENT=.
  local id
  id="$(printf '%s\n' "$body" | digest)" || exit 1
  [ -n "$id" ] || die "settings: the experiment id could not be computed"
  printf '%s\n' "$body"
  printf 'EXPERIMENT=%s\n' "$id"
}

# --- candidates ------------------------------------------------------------------

# in_set <file> <comma-list>: is <file> in the set? An item ending in `/` is a
# prefix; any other item is that file or a directory holding it.
in_set() {
  local item
  for item in $(printf '%s' "$2" | tr ',' ' '); do
    case "$item" in
      */) case "$1" in "$item"*) return 0 ;; esac ;;
      *)  [ "$1" = "$item" ] && return 0
          case "$1" in "$item"/*) return 0 ;; esac ;;
    esac
  done
  return 1
}

# trailer_rows <src>: one `<id>\t<commit>\t<first-parent>` row per own-line
# `[orch packet:<id>]` trailer (the line shape metrics.sh counts), commits
# earliest first. A root commit's parent column is empty.
trailer_rows() {
  git -C "$1" log --all --author-date-order --reverse \
      --format='===ORCHCOMMIT===%x09%H%x09%P%n%B' 2>/dev/null | tr -d '\r' \
    | awk -F'\t' '
        /^===ORCHCOMMIT===\t/ { c = $2; p = $3; sub(/ .*/, "", p); next }
        /^[[:space:]]*\[orch packet:[^]]+\][[:space:]]*$/ {
          if (c != "" && match($0, /\[orch packet:[^]]+\]/)) {
            v = substr($0, RSTART + 13, RLENGTH - 14)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (v != "" && !((c SUBSEP v) in seen)) { seen[c SUBSEP v] = 1; print v "\t" c "\t" p }
          }
        }'
}

# changed_files <src> <commit> <parent-or-empty>: the commit's changed paths.
changed_files() {
  if [ -n "$3" ]; then
    git -C "$1" -c core.quotePath=false diff-tree -r --name-only --no-renames "$3" "$2" 2>/dev/null
  else
    git -C "$1" -c core.quotePath=false diff-tree -r --root --no-commit-id --name-only --no-renames "$2" 2>/dev/null
  fi
}

# checkbox_only_files <src> <commit> <parent>: the `gspec/` files this commit
# changed in nothing but checkbox characters. Judged hunk by hunk on the diff's
# characters (a list item's leading `[ ]`/`[x]`/`[X]` is the only position
# allowed to differ); no gspec file is parsed. A moved line, an added or
# deleted file, a binary or mode-only change is never checkbox-only.
checkbox_only_files() {
  [ -n "$3" ] || return 0
  git -C "$1" -c core.quotePath=false diff -U0 --no-renames --no-color --no-ext-diff \
      --no-textconv --src-prefix=a/ --dst-prefix=b/ "$3" "$2" -- gspec/ 2>/dev/null \
    | awk '
        function norm(s) {
          if (match(s, /^[[:space:]]*[-*+][[:space:]]+\[[ xX]\]/))
            s = substr(s, 1, RLENGTH - 2) " " substr(s, RLENGTH)
          return s
        }
        function endhunk(   i) {
          if (nr != na) ok = 0
          else for (i = 1; i <= nr; i++) if (norm(r[i]) != norm(a[i])) { ok = 0; break }
          nr = 0; na = 0; last = ""
        }
        function endfile() {
          if (inh) endhunk()
          if (f != "" && ok && hunks > 0) print f
          f = ""; ok = 1; hunks = 0; inh = 0; nr = 0; na = 0; last = ""
        }
        BEGIN { ok = 1 }
        /^diff --git / { endfile(); next }
        !inh && /^\+\+\+ / { n = substr($0, 5); if (n ~ /^b\//) f = substr(n, 3); else ok = 0; next }
        !inh && /^--- / { if ($0 == "--- /dev/null") ok = 0; next }
        !inh && /^Binary files / { ok = 0; next }
        /^@@/ { if (inh) endhunk(); inh = 1; hunks++; next }
        inh && /^-/ { r[++nr] = substr($0, 2); last = "r"; next }
        inh && /^\+/ { a[++na] = substr($0, 2); last = "a"; next }
        inh && /^\\/ { if (last == "r") r[nr] = r[nr] "\n\\"; else if (last == "a") a[na] = a[na] "\n\\"; next }
        END { endfile() }
      '
}

cmd_candidates() {
  [ $# -eq 1 ] || usage
  local sout
  sout="$(cmd_settings "$1")" || exit $?
  [ -x "$BACKLOG" ] || die "candidates: gspec-backlog.sh is missing or not executable: $BACKLOG" 2
  local src code prose
  src="$(printf '%s\n' "$sout" | sed -n 's/^SOURCE_REPO=//p')"
  code="$(printf '%s\n' "$sout" | sed -n 's/^CODE_FILES=//p')"
  prose="$(printf '%s\n' "$sout" | sed -n 's/^PROSE_FILES=//p')"
  git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
    || die "candidates: the source repository is not a git repository: $src"

  local tmp
  tmp="$(mktemp -d 2>/dev/null)" || die "candidates: cannot create a temp root"
  # shellcheck disable=SC2064  # expand $tmp now: it is local to this function
  trap "rm -rf '$tmp'" EXIT
  trailer_rows "$src" > "$tmp/rows"

  local loop_dirs
  set +f; loop_dirs=( "$src"/.agents/loop/*/ ); set -f

  local id rows start commits c p f class d tree reason out rc
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9._-]*)
        printf 'EXCLUDED packet=%s reason=packet id outside [A-Za-z0-9._-]\n' "$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '?')"
        continue ;;
    esac
    rows="$(ID="$id" awk -F'\t' '$1 == ENVIRON["ID"]' "$tmp/rows")"
    start="$(printf '%s\n' "$rows" | sed -n '1p' | cut -f3)"
    commits="$(printf '%s\n' "$rows" | cut -f2 | paste -sd, -)"
    if [ -z "$start" ]; then
      printf 'EXCLUDED packet=%s reason=its earliest trailer commit is a root commit, so there is no replay start\n' "$id"
      continue
    fi

    # Class: the union of every trailer commit's changed files, each commit's
    # checkbox-only gspec/ files dropped.
    : > "$tmp/files"
    while IFS="$(printf '\t')" read -r _ c p; do
      changed_files "$src" "$c" "$p" | LC_ALL=C sort -u > "$tmp/changed"
      checkbox_only_files "$src" "$c" "$p" | LC_ALL=C sort -u > "$tmp/cbx"
      LC_ALL=C comm -23 "$tmp/changed" "$tmp/cbx" >> "$tmp/files"
    done <<EOF
$rows
EOF
    class="neither"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if in_set "$f" "$code"; then class="code"; break; fi
      if in_set "$f" "$prose"; then class="prose"; fi
    done < "$tmp/files"
    if [ "$class" = neither ]; then
      printf 'DROPPED packet=%s class=neither\n' "$id"
      continue
    fi

    # Handoff: the original file, else one the adapter rebuilds at the start.
    reason=""
    for d in "${loop_dirs[@]}"; do
      if [ -f "${d}${id}/handoff.md" ]; then reason="original"; break; fi
    done
    if [ -z "$reason" ]; then
      # `<rev>:gspec^{tree}` would read `^{tree}` as part of the path, so the
      # object is resolved first and its type checked apart.
      tree="$(git -C "$src" rev-parse --verify -q "${start}:gspec" 2>/dev/null)"
      if [ -n "$tree" ] && [ "$(git -C "$src" cat-file -t "$tree" 2>/dev/null)" != tree ]; then tree=""; fi
      if [ -z "$tree" ]; then
        reason="no original handoff, and the start commit has no gspec/ tree to rebuild one from"
      else
        if [ ! -d "$tmp/g-$tree" ]; then
          mkdir -p "$tmp/g-$tree/gspec"
          git -C "$src" archive --format=tar "$tree" 2>/dev/null | tar -x -f - -C "$tmp/g-$tree/gspec" 2>/dev/null \
            || rm -rf "$tmp/g-$tree"
        fi
        if [ ! -d "$tmp/g-$tree" ]; then
          reason="no original handoff, and the start commit's gspec/ tree could not be extracted"
        else
          out="$("$BACKLOG" handoff "$id" "$tmp/g-$tree" 2>"$tmp/bl.err" </dev/null | tr -d '\r')"; rc=$?
          case "$rc:$out" in
            0:PACKET=*) reason="rebuilt" ;;
            0:*) reason="no original handoff, and gspec-backlog.sh does not resolve the task at the start commit: $(printf '%s\n' "$out" | sed -n 's/^REASON=//p' | head -1)" ;;
            *)   reason="no original handoff, and gspec-backlog.sh handoff failed at the start commit: $(head -1 "$tmp/bl.err")" ;;
          esac
        fi
      fi
    fi
    case "$reason" in
      original|rebuilt)
        printf 'CANDIDATE packet=%s class=%s handoff=%s start=%s commits=%s\n' "$id" "$class" "$reason" "$start" "$commits" ;;
      *)
        printf 'EXCLUDED packet=%s reason=%s\n' "$id" "$(printf '%s' "$reason" | tr '\n\t' '  ')" ;;
    esac
  done <<EOF
$(awk -F'\t' '!seen[$1]++ { print $1 }' "$tmp/rows")
EOF
}

# --- select ------------------------------------------------------------------------

# store_root: where experiment results live. ORCH_COMPARE_STORE when set (the
# sweep's fixture store); otherwise `.agents/metrics/comparisons` in the main
# checkout of the harness repository (the checkout this script runs from, a
# worktree resolved to its main checkout through the common git dir), and the
# script's own parent directory when that is not a git checkout.
store_root() {
  if [ -n "${ORCH_COMPARE_STORE:-}" ]; then printf '%s' "$ORCH_COMPARE_STORE"; return 0; fi
  local top common
  top="$(cd "$HERE/.." && pwd -P)"
  common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null | tr -d '\r')"
  if [ -n "$common" ]; then
    case "$common" in /*) ;; *) common="$top/$common" ;; esac
    if [ -d "$common" ]; then top="$(cd "$common/.." && pwd -P)"; fi
  fi
  printf '%s/.agents/metrics/comparisons' "$top"
}

# fix_round_rows <src>: one `<packet>\t<fix-count>` row for every packet that
# has at least one routing record in any `.agents/loop/*/routing.jsonl` of the
# source repository. The count is the records whose token is `fix` (each is
# one review that sent the packet back for a fix round). A packet with no row
# has no routing record left to read (pruned, or run before routing records
# existed): its fix rounds are unmeasured, never 0.
fix_round_rows() {
  local logs=() l
  set +f
  for l in "$1"/.agents/loop/*/routing.jsonl; do [ -f "$l" ] && logs+=("$l"); done
  set -f
  [ "${#logs[@]}" -gt 0 ] || return 0
  awk '
    function field(line, name,    pat, pos, rest, q) {
      pat = "\"" name "\":\""
      pos = index(line, pat)
      if (pos == 0) return ""
      rest = substr(line, pos + length(pat))
      q = index(rest, "\"")
      if (q == 0) return ""
      return substr(rest, 1, q - 1)
    }
    { sub(/\r$/, ""); p = field($0, "packet"); if (p == "") next
      if (!(p in n)) { n[p] = 0; order[++k] = p }
      if (field($0, "token") == "fix") n[p]++ }
    END { for (i = 1; i <= k; i++) print order[i] "\t" n[order[i]] }
  ' "${logs[@]}" 2>/dev/null
}

# commit_tier <src> <commit>: the value of the commit's own-line
# `[orch tier:<tier>]` trailer (the line shape metrics.sh reads; the last one
# when a message carries several), or nothing.
commit_tier() {
  git -C "$1" log -1 --format=%B "$2" 2>/dev/null | tr -d '\r' | awk '
    /^[[:space:]]*\[orch tier:[^]]+\][[:space:]]*$/ {
      if (match($0, /\[orch tier:[^]]+\]/)) {
        v = substr($0, RSTART + 11, RLENGTH - 12); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v != "") t = v
      }
    }
    END { if (t != "") print t }'
}

cmd_select() {
  [ $# -eq 1 ] || usage
  local sout
  sout="$(cmd_settings "$1")" || exit $?
  local exp store dir sel
  exp="$(printf '%s\n' "$sout" | sed -n 's/^EXPERIMENT=//p')"
  store="$(store_root)"
  dir="$store/$exp"
  sel="$dir/selection.json"

  # Written once: a stored selection is read back unchanged, never recomputed.
  if [ -f "$sel" ]; then
    cat "$sel"
    printf 'compare.sh: selection read back unchanged: %s\n' "$sel" >&2
    return 0
  fi

  local cout rc
  cout="$(cmd_candidates "$1")"; rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  local src per
  src="$(printf '%s\n' "$sout" | sed -n 's/^SOURCE_REPO=//p')"
  per="$(printf '%s\n' "$sout" | sed -n 's/^PER_CLASS=//p')"

  local tmp
  tmp="$(mktemp -d 2>/dev/null)" || die "select: cannot create a temp root"
  # shellcheck disable=SC2064  # expand $tmp now: it is local to this function
  trap "rm -rf '$tmp'" EXIT
  fix_round_rows "$src" > "$tmp/fix"

  # One TSV row per candidate, NEWEST first (the reverse of the candidates
  # order, which is each packet's earliest trailer commit, oldest first):
  #   class tier fix packet handoff start commits title
  local ln id class handoff start commits c tier fix title first
  : > "$tmp/rows"
  while IFS= read -r ln; do
    case "$ln" in CANDIDATE\ *) ;; *) continue ;; esac
    id="$(printf '%s\n' "$ln" | sed -n 's/.* packet=\([^ ]*\).*/\1/p')"
    class="$(printf '%s\n' "$ln" | sed -n 's/.* class=\([^ ]*\).*/\1/p')"
    handoff="$(printf '%s\n' "$ln" | sed -n 's/.* handoff=\([^ ]*\).*/\1/p')"
    start="$(printf '%s\n' "$ln" | sed -n 's/.* start=\([^ ]*\).*/\1/p')"
    commits="$(printf '%s\n' "$ln" | sed -n 's/.* commits=\([^ ]*\).*/\1/p')"
    # Tier: the latest of the packet's trailer commits that carries one.
    tier=""
    for c in $(printf '%s' "$commits" | tr ',' '\n' | sed -n '1!G;h;$p'); do
      tier="$(commit_tier "$src" "$c")"
      [ -z "$tier" ] || break
    done
    tier="$(printf '%s' "${tier:-unrecorded}" | tr '\t' ' ')"
    fix="$(ID="$id" awk -F'\t' '$1 == ENVIRON["ID"] { print $2; exit }' "$tmp/fix")"
    [ -n "$fix" ] || fix="unmeasured"
    # Title: the subject line of the packet's earliest trailer commit.
    first="${commits%%,*}"
    title="$(git -C "$src" log -1 --format=%s "$first" 2>/dev/null | tr -d '\r' | tr '\t' ' ')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$class" "$tier" "$fix" "$id" "$handoff" "$start" "$commits" "$title" >> "$tmp/rows"
  done <<EOF
$cout
EOF
  sed -n '1!G;h;$p' "$tmp/rows" > "$tmp/newest"

  # Per class, within that class's own candidates only (never the other's):
  #   1. the newest packet with measured fix rounds of 1 or more, if any;
  #   2. while fewer than two distinct RECORDED tiers are chosen, the newest
  #      packet with a recorded tier not yet chosen (`unrecorded` is the
  #      absence of a trailer, so it never counts toward the tier mix);
  #   3. fill the rest newest-first.
  # Selected rows keep newest-first order. A shortfall is one `F` row:
  #   F class kind wanted found available [unmeasured]
  awk -F'\t' -v N="$per" '
    { cls = $1; i = ++cnt[cls]; row[cls, i] = $0; tr[cls, i] = $2; fx[cls, i] = $3 }
    function pick(c, i) {
      sel[c, i] = 1; picked[c]++
      if (tr[c, i] != "unrecorded" && !((c, tr[c, i]) in tiers)) { tiers[c, tr[c, i]] = 1; ntiers[c]++ }
    }
    function fixed(c, i) { return fx[c, i] ~ /^[0-9]+$/ && fx[c, i] + 0 >= 1 }
    END {
      split("code prose", classes, " ")
      for (k = 1; k <= 2; k++) {
        c = classes[k]; n = cnt[c] + 0; picked[c] = 0; ntiers[c] = 0
        for (i = 1; i <= n; i++) if (picked[c] < N && fixed(c, i)) { pick(c, i); break }
        while (picked[c] < N && ntiers[c] < 2) {
          got = 0
          for (i = 1; i <= n; i++)
            if (!((c, i) in sel) && tr[c, i] != "unrecorded" && !((c, tr[c, i]) in tiers)) { pick(c, i); got = 1; break }
          if (!got) break
        }
        for (i = 1; i <= n; i++) if (picked[c] < N && !((c, i) in sel)) pick(c, i)
        for (i = 1; i <= n; i++) if ((c, i) in sel) print "S\t" row[c, i]

        avt = 0; avf = 0; unm = 0; delete seen
        for (i = 1; i <= n; i++) {
          if (tr[c, i] != "unrecorded" && !(tr[c, i] in seen)) { seen[tr[c, i]] = 1; avt++ }
          if (fixed(c, i)) avf++
          if (fx[c, i] == "unmeasured") unm++
        }
        sf = 0
        for (i = 1; i <= n; i++) if (((c, i) in sel) && fixed(c, i)) sf++
        if (n < N) print "F\t" c "\tcount\t" N "\t" n "\t" n
        if (ntiers[c] < 2) print "F\t" c "\ttiers\t2\t" ntiers[c] "\t" avt
        if (sf < 1) print "F\t" c "\tfix-rounds\t1\t" sf "\t" avf "\t" unm
      }
    }' "$tmp/newest" > "$tmp/picked"

  printf '%s\n' "$cout" | awk '
    /^EXCLUDED / { p = $2; sub(/^packet=/, "", p); r = $0; sub(/^EXCLUDED packet=[^ ]* reason=/, "", r); print "X\t" p "\t" r }
    /^DROPPED /  { p = $2; sub(/^packet=/, "", p); print "D\t" p }' > "$tmp/other"

  # The selection document: one packet, shortfall or exclusion per line, so it
  # reads as the listing it is. `fix_rounds` is a number only when measured.
  printf '%s\n' "$sout" > "$tmp/settings"
  SRC="$src" SETTINGS="$tmp/settings" PICKED="$tmp/picked" OTHER="$tmp/other" awk -F'\t' '
    function esc(s) {
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s)
      gsub(/[[:cntrl:]]/, " ", s)
      return "\"" s "\""
    }
    function arr(csv,    n, a, i, o) {
      n = split(csv, a, ","); o = ""
      for (i = 1; i <= n; i++) o = o (i > 1 ? ", " : "") esc(a[i])
      return "[" o "]"
    }
    FILENAME == ENVIRON["SETTINGS"] {
      p = index($0, "="); if (p) kv[substr($0, 1, p - 1)] = substr($0, p + 1); next
    }
    FILENAME == ENVIRON["PICKED"] && $1 == "S" {
      ns++
      S[ns] = "    {\"packet\": " esc($5) ", \"class\": " esc($2) ", \"tier\": " esc($3) \
              ", \"fix_rounds\": " ($4 ~ /^[0-9]+$/ ? $4 : esc($4)) ", \"title\": " esc($9) \
              ", \"handoff\": " esc($6) ", \"start\": " esc($7) ", \"commits\": " arr($8) "}"
      next
    }
    FILENAME == ENVIRON["PICKED"] && $1 == "F" {
      nf++
      F[nf] = "    {\"class\": " esc($2) ", \"kind\": " esc($3) ", \"wanted\": " $4 ", \"found\": " $5 \
              ", \"available\": " $6 ($3 == "fix-rounds" ? ", \"unmeasured\": " $7 : "") "}"
      next
    }
    FILENAME == ENVIRON["OTHER"] && $1 == "X" { nx++; X[nx] = "    {\"packet\": " esc($2) ", \"reason\": " esc($3) "}"; next }
    FILENAME == ENVIRON["OTHER"] && $1 == "D" { nd++; D[nd] = "    " esc($2); next }
    function block(name, A, n, last,    i) {
      printf "  \"%s\": [", name
      if (n == 0) { printf "]%s\n", (last ? "" : ","); return }
      printf "\n"
      for (i = 1; i <= n; i++) printf "%s%s\n", A[i], (i < n ? "," : "")
      printf "  ]%s\n", (last ? "" : ",")
    }
    END {
      printf "{\n"
      printf "  \"experiment\": %s,\n", esc(kv["EXPERIMENT"])
      printf "  \"settings\": {\"role\": %s, \"models\": %s, \"reviewer_model\": %s, \"source_repo\": %s, \"per_class\": %s, \"code_files\": %s, \"prose_files\": %s},\n", \
        esc(kv["ROLE"]), arr(kv["MODELS"]), esc(kv["REVIEWER_MODEL"]), esc(ENVIRON["SRC"]), kv["PER_CLASS"] + 0, arr(kv["CODE_FILES"]), arr(kv["PROSE_FILES"])
      block("selected", S, ns, 0)
      block("shortfalls", F, nf, 0)
      block("excluded", X, nx, 0)
      block("dropped", D, nd, 1)
      printf "}\n"
    }' "$tmp/settings" "$tmp/picked" "$tmp/other" > "$tmp/selection.json" \
    || die "select: the selection could not be rendered"

  mkdir -p "$dir" || die "select: cannot create the experiment store: $dir"
  cp "$tmp/selection.json" "$dir/.selection.json.$$" && mv "$dir/.selection.json.$$" "$sel" \
    || die "select: cannot write the selection: $sel"
  cat "$sel"
  printf 'compare.sh: selection written: %s\n' "$sel" >&2
}

# --- estimate ----------------------------------------------------------------------

# json_flat <file>: one `<doc>\t<path>\t<type>\t<value>` row per scalar leaf of
# the JSON in <file>, where <doc> numbers the top-level values (1 for a plain
# JSON file, one per line of a JSONL file), <path> is jq-style (`.a.b[0].c`),
# <type> is `s` for a string and `n` for any other literal (number, true,
# false, null), and <value> is the string unescaped (a tab or newline in it
# becomes a space). An empty container emits nothing. Exit 1 on a token it
# cannot read, so a damaged file is refused rather than half-read.
json_flat() {
  awk '
    function here(   p) {
      if (d == 0) { doc++; return "" }
      if (ty[d] == "o") return pre[d] "." ky[d]
      return pre[d] "[" ix[d] "]"
    }
    function emit(t, v) { if (d == 0) { bad = 1; exit } p = here(); print doc "\t" p "\t" t "\t" v }
    function open(kind,   p) { p = here(); d++; ty[d] = kind; pre[d] = p; ix[d] = 0; wk[d] = (kind == "o"); ky[d] = "" }
    function unesc(s) {
      gsub(/\\\\/, "\001", s); gsub(/\\"/, "\"", s); gsub(/\\\//, "/", s)
      gsub(/\\[tnr]/, " ", s); gsub(/\t/, " ", s); gsub(/\001/, "\\", s)
      return s
    }
    BEGIN { d = 0; doc = 0; bad = 0 }
    { sub(/\r$/, "") }
    {
      line = $0
      while (length(line) > 0) {
        if (match(line, /^[ \t]+/)) { line = substr(line, RLENGTH + 1); continue }
        c = substr(line, 1, 1)
        if (c == "\"") {
          if (!match(line, /^"([^"\\]|\\.)*"/)) { bad = 1; exit }
          tok = unesc(substr(line, 2, RLENGTH - 2)); line = substr(line, RLENGTH + 1)
          if (d > 0 && ty[d] == "o" && wk[d]) { ky[d] = tok; wk[d] = 0 } else emit("s", tok)
          continue
        }
        if (c == "{") { open("o"); line = substr(line, 2); continue }
        if (c == "[") { open("a"); line = substr(line, 2); continue }
        if (c == "}" || c == "]") {
          if (d == 0 || (c == "}") != (ty[d] == "o")) { bad = 1; exit }
          d--; line = substr(line, 2); continue
        }
        if (c == ",") {
          if (d == 0) { bad = 1; exit }
          if (ty[d] == "a") ix[d]++; else wk[d] = 1
          line = substr(line, 2); continue
        }
        if (c == ":") { if (d == 0 || ty[d] != "o") { bad = 1; exit } line = substr(line, 2); continue }
        if (match(line, /^[-+.0-9A-Za-z]+/)) {
          tok = substr(line, 1, RLENGTH); line = substr(line, RLENGTH + 1)
          # A bare word must be a JSON literal, and only inside a container:
          # every file read here is an object (or one object per line).
          if (d == 0 || tok !~ /^(true|false|null|-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?)$/) { bad = 1; exit }
          emit("n", tok); continue
        }
        bad = 1; exit
      }
    }
    END { if (bad || d != 0) exit 1 }
  ' "$1"
}

# cost_rows <run-metrics.json>: one `<packet>\t<generated_at>\t<run_id>\t<state>\t
# <input>\t<output>\t<cache_creation>\t<cache_read>` row per packets[] entry.
# <state> is `measured`, `null` (a token field is null, absent or not a
# number), `zero` (all four are 0: the packet window caught no usage, and a
# landed packet cost something), or `source` (the file's token_source is not a
# transcript one, so its token figures were never read from a transcript).
cost_rows() {
  local flat
  flat="$(json_flat "$1")" || return 1
  printf '%s\n' "$flat" | awk -F'\t' '
    $2 == ".generated_at" { gen = $4; next }
    $2 == ".token_source" { ts = $4; next }
    $2 == ".run_id"       { rid = $4; next }
    $2 ~ /^\.packets\[[0-9]+\]\./ {
      i = $2; sub(/^\.packets\[/, "", i); sub(/\].*$/, "", i); i += 0; if (i + 1 > n) n = i + 1
      rest = substr($2, index($2, "].") + 2)
      if (rest == "id" && $3 == "s") id[i] = $4
      else if (rest ~ /^tokens\.(input|output|cache_creation|cache_read)$/ && $3 == "n" && $4 ~ /^[0-9]+$/)
        tok[i, substr(rest, 8)] = $4
    }
    END {
      for (i = 0; i < n; i++) {
        if (!(i in id)) continue
        st = "measured"; sum = 0
        split("input output cache_creation cache_read", f, " ")
        for (k = 1; k <= 4; k++) { if (!((i, f[k]) in tok)) st = "null"; else sum += tok[i, f[k]] }
        if (ts !~ /^transcript/) st = "source"
        else if (st == "measured" && sum == 0) st = "zero"
        printf "%s\t%s\t%s\t%s", id[i], gen, rid, st
        for (k = 1; k <= 4; k++) printf "\t%s", ((i, f[k]) in tok) ? tok[i, f[k]] : ""
        printf "\n"
      }
    }'
}

# new_token: 32 hex of /dev/urandom, else a digest of the time, pid and $RANDOM.
new_token() {
  local t
  t="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  case "$t" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) t="$( { date -u +%Y%m%dT%H%M%S; printf '%s %s %s %s\n' "$$" "$RANDOM" "$RANDOM" "$RANDOM"; } | digest)$( printf '%s %s\n' "$RANDOM" "$$" | digest)" ;;
  esac
  printf '%s' "$t"
}

cmd_estimate() {
  local exp="" remaining=0 a
  for a in "$@"; do
    case "$a" in
      --remaining) remaining=1 ;;
      -*) usage ;;
      *) [ -z "$exp" ] || usage; exp="$a" ;;
    esac
  done
  [ -n "$exp" ] || usage
  case "$exp" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "estimate: not an experiment id (12 hex, as \`settings\` prints it): $exp" ;;
  esac
  local store dir sel prices
  store="$(store_root)"
  dir="$store/$exp"
  sel="$dir/selection.json"
  prices="${ORCH_COMPARE_PRICES:-$HERE/spend-prices.json}"
  [ -f "$sel" ] || die "estimate: no stored selection for experiment $exp (run \`compare.sh select\` first): $sel"

  local tmp
  tmp="$(mktemp -d 2>/dev/null)" || die "estimate: cannot create a temp root"
  # shellcheck disable=SC2064  # expand $tmp now: it is local to this function
  trap "rm -rf '$tmp'" EXIT

  # --- the stored selection: its experiment, models, source and packets -------
  json_flat "$sel" > "$tmp/sel" || die "estimate: the stored selection is not readable JSON: $sel"
  local sexp src
  sexp="$(awk -F'\t' '$2 == ".experiment" { print $4; exit }' "$tmp/sel")"
  [ "$sexp" = "$exp" ] || die "estimate: the stored selection names experiment [$sexp], not $exp: $sel"
  src="$(awk -F'\t' '$2 == ".settings.source_repo" { print $4; exit }' "$tmp/sel")"
  awk -F'\t' '$2 ~ /^\.settings\.models\[[0-9]+\]$/ { print $4 }' "$tmp/sel" > "$tmp/models"
  awk -F'\t' '$2 ~ /^\.selected\[[0-9]+\]\.packet$/ { print $4 }' "$tmp/sel" > "$tmp/packets"
  # Every id goes into output lines and the approvals JSON: only safe tokens.
  if LC_ALL=C grep -q '[^A-Za-z0-9._-]' "$tmp/models" "$tmp/packets" 2>/dev/null \
     || [ ! -s "$tmp/models" ]; then
    die "estimate: the stored selection's models or packets are malformed: $sel"
  fi

  # --- the replay set: packet x model, stored order; recorded ones set apart ---
  : > "$tmp/recorded"
  if [ "$remaining" -eq 1 ] && [ -f "$store/records.jsonl" ]; then
    json_flat "$store/records.jsonl" > "$tmp/records.flat" \
      || die "estimate: the records file is not readable JSONL, so the remaining replays cannot be counted: $store/records.jsonl"
    EXP="$exp" awk -F'\t' '
      $2 == ".experiment" && $3 == "s" { e[$1] = $4 }
      $2 == ".packet"     && $3 == "s" { p[$1] = $4 }
      $2 == ".model"      && $3 == "s" { m[$1] = $4 }
      END { for (d in e) if (e[d] == ENVIRON["EXP"] && (d in p) && (d in m)) print p[d] "\t" m[d] }
    ' "$tmp/records.flat" | LC_ALL=C sort -u > "$tmp/recorded"
  fi
  local p m nrec=0
  : > "$tmp/set"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      if [ "$remaining" -eq 1 ] && P="$p" M="$m" awk -F'\t' '$1 == ENVIRON["P"] && $2 == ENVIRON["M"] { f = 1 } END { exit !f }' "$tmp/recorded"; then
        nrec=$((nrec + 1)); continue
      fi
      printf '%s\t%s\n' "$p" "$m" >> "$tmp/set"
    done < "$tmp/models"
  done < "$tmp/packets"

  # --- each packet's original cost from the source's stored run-metrics --------
  local f nbad=0
  : > "$tmp/costs"
  if [ -n "$src" ] && [ -d "$src/.agents/metrics" ]; then
    set +f
    for f in "$src"/.agents/metrics/*/run-metrics.json; do
      [ -f "$f" ] || continue
      cost_rows "$f" >> "$tmp/costs" 2>/dev/null || nbad=$((nbad + 1))
    done
    set -f
  fi

  # --- the price table ------------------------------------------------------
  [ -f "$prices" ] || die "estimate: no price table: $prices"
  json_flat "$prices" > "$tmp/prices" || die "estimate: the price table is not readable JSON: $prices"
  local tdate
  tdate="$(awk -F'\t' '$2 == ".table_date" && $3 == "s" { print $4; exit }' "$tmp/prices")"
  [ -n "$tdate" ] || die "estimate: the price table has no table_date: $prices"

  # --- the estimate ------------------------------------------------------------
  local scope=all; [ "$remaining" -eq 1 ] && scope=remaining
  SET="$tmp/set" COSTS="$tmp/costs" PRICES="$tmp/prices" MODELS="$tmp/models" \
  EXP="$exp" SCOPE="$scope" NREC="$nrec" TDATE="$tdate" NBAD="$nbad" \
  NPACK="$(grep -c . "$tmp/packets")" awk -F'\t' '
    function money(x) { return sprintf("%.2f", x) }
    function int0(x)  { return sprintf("%.0f", x) }
    FILENAME == ENVIRON["MODELS"] { if ($0 != "") { nm++; mod[nm] = $0 }; next }
    FILENAME == ENVIRON["SET"]    { ns++; sp[ns] = $1; sm[ns] = $2; if (!($1 in inset)) { inset[$1] = 1; np++; pord[np] = $1 }; next }
    FILENAME == ENVIRON["PRICES"] {
      if ($2 ~ /^\.prices\.[^.]+\.(input|output|cache_read|cache_write_5m|cache_write_1h)$/ && $3 == "n" && $4 ~ /^[0-9.]+$/) {
        k = substr($2, 9); fld = k; sub(/\.[^.]*$/, "", k); sub(/^.*\./, "", fld)
        rate[k, fld] = $4 + 0; if (!(k in pid)) { pid[k] = 1; npid++; pids[npid] = k }
      }
      next
    }
    FILENAME == ENVIRON["COSTS"] {
      if (!($1 in inset)) next
      rows[$1]++; st[$1, $4]++
      if ($4 == "measured" && (!($1 in bgen) || $2 >= bgen[$1])) {
        bgen[$1] = $2; brun[$1] = $3; ti[$1] = $5; to[$1] = $6; tc[$1] = $7; tr[$1] = $8
      }
      next
    }
    function complete(k) {
      return ((k, "input") in rate) && ((k, "output") in rate) && ((k, "cache_read") in rate) && \
             ((k, "cache_write_5m") in rate) && ((k, "cache_write_1h") in rate)
    }
    function same(a, b) {
      return rate[a, "input"] == rate[b, "input"] && rate[a, "output"] == rate[b, "output"] && \
             rate[a, "cache_read"] == rate[b, "cache_read"] && rate[a, "cache_write_5m"] == rate[b, "cache_write_5m"] && \
             rate[a, "cache_write_1h"] == rate[b, "cache_write_1h"]
    }
    # resolve(m): sets use[m] to the price key and basis[m], or why[m].
    function resolve(m,   pre, j, k, ids, first, diff) {
      if ((m in pid) && complete(m)) { use[m] = m; basis[m] = m; return }
      if (m in pid) { why[m] = "the price-table entry " m " lacks one of input, output, cache_read, cache_write_5m, cache_write_1h"; return }
      pre = "claude-" m "-"; ids = ""; first = ""; diff = 0
      for (j = 1; j <= npid; j++) {
        k = pids[j]
        if (index(k, pre) != 1) continue
        ids = ids (ids == "" ? "" : ",") k
        if (!complete(k)) { diff = 2; continue }
        if (first == "") first = k; else if (!same(first, k)) diff = (diff ? diff : 1)
      }
      if (ids == "") { why[m] = "no price-table entry is keyed " m " or starts " pre; return }
      if (diff == 2) { why[m] = "a " pre "* entry lacks a rate (" ids ")"; return }
      if (diff == 1) { why[m] = "the " pre "* entries carry different rates, and which one " m " resolves to is not recorded (" ids ")"; return }
      use[m] = first; basis[m] = "family:" ids
    }
    function cost(p, k, cw) {
      return (ti[p] * rate[k, "input"] + to[p] * rate[k, "output"] + tr[p] * rate[k, "cache_read"] + tc[p] * rate[k, cw]) / 1000000
    }
    function line(label, r, e, ok, a, b, c, dd, lo, hi, priced, extra) {
      printf "ESTIMATE model=%s replays=%d estimated=%d", label, r, e
      if (r > 0 && e == 0)
        printf " tokens=unmeasured input=unmeasured output=unmeasured cache_creation=unmeasured cache_read=unmeasured"
      else
        printf " tokens=%s input=%s output=%s cache_creation=%s cache_read=%s", int0(a + b + c + dd), int0(a), int0(b), int0(c), int0(dd)
      if (r == 0) printf " dollars_min=0.00 dollars_max=0.00"
      else if (e == 0 || !priced) printf " dollars_min=unmeasured dollars_max=unmeasured"
      else printf " dollars_min=%s dollars_max=%s", money(lo), money(hi)
      printf "%s\n", extra
    }
    END {
      printf "EXPERIMENT=%s\nSCOPE=%s\n", ENVIRON["EXP"], ENVIRON["SCOPE"]
      ml = ""; for (i = 1; i <= nm; i++) ml = ml (i > 1 ? "," : "") mod[i]
      printf "MODELS=%s\nPACKETS=%d\nRECORDED=%d\nREPLAYS=%d\n", ml, ENVIRON["NPACK"], ENVIRON["NREC"], ns
      for (i = 1; i <= ns; i++) printf "REPLAY packet=%s model=%s\n", sp[i], sm[i]
      printf "PRICE_TABLE_DATE=%s\n", ENVIRON["TDATE"]

      # A packet counts only with a measured original cost; every other packet
      # in the set is named and left out, never priced as 0.
      for (j = 1; j <= np; j++) {
        p = pord[j]
        if (p in bgen) continue
        if (!(p in rows)) r = "no run-metrics row for the packet in the source repository"
        else r = "no measured row among " rows[p] " run-metrics row(s) (tokens null: " st[p, "null"] + 0 \
                 ", all zero: " st[p, "zero"] + 0 ", no transcript token source: " st[p, "source"] + 0 ")"
        printf "EXCLUDED packet=%s reason=original cost unmeasured, excluded from the estimate: %s\n", p, r
      }
      for (i = 1; i <= nm; i++) { resolve(mod[i]); if (mod[i] in why) printf "UNPRICED model=%s reason=%s\n", mod[i], why[mod[i]] }

      allpriced = 1
      for (i = 1; i <= nm; i++) {
        m = mod[i]; R = 0; E = 0; A = 0; B = 0; C = 0; D = 0; LO = 0; HI = 0
        for (s = 1; s <= ns; s++) {
          if (sm[s] != m) continue
          R++; p = sp[s]
          if (!(p in bgen)) continue
          E++; A += ti[p]; B += to[p]; C += tc[p]; D += tr[p]
          if (m in use) { LO += cost(p, use[m], "cache_write_5m"); HI += cost(p, use[m], "cache_write_1h") }
        }
        if (R > 0 && !(m in use)) allpriced = 0
        TR += R; TE += E; TA += A; TB += B; TC += C; TD += D; TLO += LO; THI += HI
        line(m, R, E, (m in use), A, B, C, D, LO, HI, (m in use), " price=" ((m in use) ? basis[m] : "unpriced"))
      }
      line("total", TR, TE, allpriced, TA, TB, TC, TD, TLO, THI, allpriced, "")
      if (ENVIRON["NBAD"] + 0 > 0)
        printf "NOTE %d run-metrics file(s) in the source repository could not be read; a packet whose only row is in one reads unmeasured\n", ENVIRON["NBAD"]
      printf "NOTE tokens are each packet'"'"'s original recorded tokens, held constant across models; fix rounds are not modelled\n"
      printf "NOTE dollars_min prices every cache-write token at the 5-minute rate and dollars_max at the 1-hour rate: the recorded tokens do not split write lifetime\n"
    }' "$tmp/models" "$tmp/set" "$tmp/prices" "$tmp/costs" > "$tmp/out" \
    || die "estimate: the estimate could not be computed"

  # --- the approval token: stored pending BEFORE it is printed ---------------
  local tok="none"
  if [ -s "$tmp/set" ]; then
    local setd issued replays
    setd="$(grep '^REPLAY ' "$tmp/out" | digest)" || exit 1
    tok="$(new_token)"
    [ -n "$tok" ] || die "estimate: no approval token could be generated"
    if [ -f "$dir/approvals.jsonl" ] && T="\"token\":\"$tok\"" awk 'index($0, ENVIRON["T"]) { f = 1 } END { exit !f }' "$dir/approvals.jsonl"; then
      die "estimate: the generated token already exists in $dir/approvals.jsonl; run estimate again"
    fi
    issued="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    replays="$(awk -F'\t' '{ printf "%s{\"packet\":\"%s\",\"model\":\"%s\"}", (NR > 1 ? "," : ""), $1, $2 }' "$tmp/set")"
    printf '{"token":"%s","state":"pending","experiment":"%s","scope":"%s","issued_at":"%s","set":"%s","replays":[%s]}\n' \
      "$tok" "$exp" "$scope" "$issued" "$setd" "$replays" >> "$dir/approvals.jsonl" \
      || die "estimate: the approval token could not be stored: $dir/approvals.jsonl"
  fi
  cat "$tmp/out"
  printf 'APPROVAL=%s\n' "$tok"
}

# --- prepare -----------------------------------------------------------------------

# names_model <name> <ids-file>: does <name> contain any identifier listed in
# <ids-file>, one per line, compared case-insensitively?
names_model() {
  NAME="$1" awk 'BEGIN { n = tolower(ENVIRON["NAME"]) } $0 != "" && index(n, tolower($0)) { f = 1 } END { exit !f }' "$2"
}

# opaque_name <prefix> <ids-file>: <prefix><16 hex>, redrawn while it contains
# any identifier in <ids-file>. Exit 1 when no draw is clean.
opaque_name() {
  local i t
  for i in 1 2 3 4 5 6 7 8 9 10; do
    t="$1$(new_token | cut -c1-16)"
    if [ "${#t}" -eq $(( ${#1} + 16 )) ] && ! names_model "$t" "$2"; then printf '%s' "$t"; return 0; fi
  done
  return 1
}

# set_routing <in> <out> <role> <model> <reviewer-model>: <in> (absent or not)
# rewritten to <out> with the top-level `model_routing` mapping <role> to
# <model> and `reviewer` to <reviewer-model>. Every other line is kept verbatim;
# the block's own entry indentation is reused (routing.sh requires one indent);
# a flow-form map is rewritten as a block; an absent key is appended. Exit 3
# when the map cannot be read (a flow value that is not one `{...}`, or a
# second `model_routing:` key, which routing.sh reads as unparseable anyway).
# An EMPTY <role> is the review view's reviewer-only form: every entry of the
# map is dropped (comment and blank lines in it are kept) and only `reviewer`
# is written, so no other agent's model is named by the view's routing.
set_routing() {
  local in="$1"
  [ -f "$in" ] || in=/dev/null
  ROLE="$3" MODEL="$4" RM="$5" awk '
    BEGIN { only = (ENVIRON["ROLE"] == "") }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function keyof(s,   p) {
      s = trim(s); p = match(s, /:([[:space:]]|$)/); if (p == 0) return ""
      s = trim(substr(s, 1, p - 1))
      if (length(s) >= 2 && (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/)) s = substr(s, 2, length(s) - 2)
      return s
    }
    function emit(   i, ind) {
      ind = (ei == "" ? "  " : ei)
      print "model_routing:"
      if (!only) print ind ENVIRON["ROLE"] ": " ENVIRON["MODEL"]
      print ind "reviewer: " ENVIRON["RM"]
      for (i = 1; i <= nb; i++) print buf[i]
      nb = 0; inb = 0; done = 1
    }
    { sub(/\r$/, "") }
    inb {
      if ($0 ~ /^[[:space:]]*(#.*)?$/) { buf[++nb] = $0; next }
      if ($0 ~ /^[[:space:]]/) {
        if (ei == "") { match($0, /^[[:space:]]+/); ei = substr($0, 1, RLENGTH) }
        k = keyof($0)
        if (only || k == ENVIRON["ROLE"] || k == "reviewer") next
        buf[++nb] = $0; next
      }
      emit()
    }
    /^model_routing:/ {
      if (done) { bad = 1; next }
      rest = substr($0, length("model_routing:") + 1)
      rest = trim(rest); if (rest ~ /^#/) rest = ""
      sub(/[[:space:]]+#.*$/, "", rest); rest = trim(rest)
      if (rest == "") { inb = 1; next }
      if (rest !~ /^\{[^{}]*\}$/) { bad = 1; done = 1; next }
      inner = trim(substr(rest, 2, length(rest) - 2))
      n = (inner == "" ? 0 : split(inner, pcs, ","))
      for (i = 1; i <= n; i++) {
        pc = trim(pcs[i]); if (pc == "") continue
        k = keyof(pc); if (k == "") { bad = 1; continue }
        if (only || k == ENVIRON["ROLE"] || k == "reviewer") continue
        buf[++nb] = "  " pc
      }
      emit(); next
    }
    { print }
    END {
      if (inb) emit()
      if (!done) {
        print "model_routing:"
        if (!only) print "  " ENVIRON["ROLE"] ": " ENVIRON["MODEL"]
        print "  reviewer: " ENVIRON["RM"]
      }
      if (bad) exit 3
    }' "$in" > "$2"
}

# first_dispatch <in> <out>: the handoff as its FIRST dispatch received it.
# The loop splices two marked blocks into a handoff after that dispatch, and a
# replay starts before the work they describe existed, so both are removed:
#   - `runstate.sh amend-handoff` appends "\n" + its block (begin marker line
#     through end marker line); the removed span is that "\n" plus the block,
#     which is what it added whether or not the file ended in a newline.
#   - `runstate.sh refresh-handoff` inserts its block after the header plus one
#     blank line after it; the removed span is the block plus that blank line,
#     exactly what its own "remove" path drops.
# Every other byte is kept, the `orch:budget` block and any driver REQUIRED
# lines included: the first dispatch had them. Amendment spans go first, so an
# amendment whose text quotes a partial-work marker is removed whole. A marker
# line left over afterwards (unterminated, or at the top of the file where
# neither command writes one) is not a span either command wrote: exit 3,
# refused rather than guessed. The markers are runstate.sh's `_RS_AMEND_*` and
# `_RS_PARTIAL_*` constants, repeated here because this script never sources it.
_CMP_AMEND_BEGIN='<!-- orch:decider-amendment -->'
_CMP_AMEND_END='<!-- /orch:decider-amendment -->'
_CMP_PARTIAL_BEGIN='<!-- orch:partial-work -->'
_CMP_PARTIAL_END='<!-- /orch:partial-work -->'
first_dispatch() {
  local c nl=$'\n' pre rest
  c="$(cat "$1" && printf x)" || return 1
  c="${c%x}"
  while :; do
    case "$c" in *"$nl$_CMP_AMEND_BEGIN$nl"*) ;; *) break ;; esac
    pre="${c%%"$nl$_CMP_AMEND_BEGIN$nl"*}"
    rest="${c#*"$nl$_CMP_AMEND_BEGIN$nl"}"
    case "$rest" in
      *"$nl$_CMP_AMEND_END$nl"*) rest="${rest#*"$nl$_CMP_AMEND_END$nl"}" ;;
      *"$nl$_CMP_AMEND_END") rest="" ;;
      *) return 3 ;;
    esac
    c="$pre$rest"
  done
  while :; do
    case "$c" in *"$nl$_CMP_PARTIAL_BEGIN$nl"*) ;; *) break ;; esac
    pre="${c%%"$nl$_CMP_PARTIAL_BEGIN$nl"*}$nl"
    rest="${c#*"$nl$_CMP_PARTIAL_BEGIN$nl"}"
    case "$rest" in
      *"$nl$_CMP_PARTIAL_END$nl"*) rest="${rest#*"$nl$_CMP_PARTIAL_END$nl"}"; rest="${rest#"$nl"}" ;;
      *"$nl$_CMP_PARTIAL_END") rest="" ;;
      *) return 3 ;;
    esac
    c="$pre$rest"
  done
  case "$nl$c$nl" in
    *"$nl$_CMP_AMEND_BEGIN$nl"*|*"$nl$_CMP_AMEND_END$nl"*|*"$nl$_CMP_PARTIAL_BEGIN$nl"*|*"$nl$_CMP_PARTIAL_END$nl"*)
      return 3 ;;
  esac
  printf '%s' "$c" > "$2"
}

# opaque_clone <cmd> <src> <start> <dest> <branch> <tmp>: a `git clone --shared
# --no-checkout` of <src> at <dest>, with <start> checked out on the new local
# <branch>, every other local branch and the `origin` remote dropped, so its
# refs are that one branch (and any tags) and nothing it does can reach <src>.
# Dies, naming <cmd>, on any failure; the caller's EXIT trap removes <dest>.
opaque_clone() {
  local cmd="$1" src="$2" start="$3" dest="$4" bname="$5" tmp="$6" ref
  git clone -q --shared --no-checkout "$src" "$dest" >/dev/null 2>"$tmp/git.err" \
    || die "$cmd: git clone --shared failed: $(head -1 "$tmp/git.err")"
  git -C "$dest" -c advice.detachedHead=false checkout -q -b "$bname" "$start" >/dev/null 2>"$tmp/git.err" \
    || die "$cmd: cannot check out $start in the clone: $(head -1 "$tmp/git.err")"
  git -C "$dest" for-each-ref --format='%(refname)' refs/heads/ > "$tmp/heads" 2>/dev/null
  while IFS= read -r ref; do
    [ -n "$ref" ] && [ "$ref" != "refs/heads/$bname" ] || continue
    git -C "$dest" update-ref -d "$ref" >/dev/null 2>&1 || die "$cmd: cannot drop the clone's branch $ref"
  done < "$tmp/heads"
  if git -C "$dest" remote 2>/dev/null | grep -qx origin; then
    git -C "$dest" remote remove origin >/dev/null 2>&1 || die "$cmd: cannot drop the clone's origin remote"
  fi
}

# Globals, not locals: the EXIT trap below runs after cmd_prepare has returned
# or died, when its locals are gone. The half-built clone is removed on every
# exit that does not clear _CMP_CLONE first.
_CMP_TMP=""
_CMP_CLONE=""
_cmp_prepare_cleanup() {
  if [ -n "$_CMP_TMP" ]; then rm -rf "$_CMP_TMP"; fi
  if [ -n "$_CMP_CLONE" ]; then rm -rf "$_CMP_CLONE"; fi
  return 0
}

cmd_prepare() {
  [ $# -eq 3 ] || usage
  local exp="$1" pkt="$2" model="$3"
  case "$exp" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "prepare: not an experiment id (12 hex, as \`settings\` prints it): $exp" ;;
  esac
  case "$pkt" in ''|*[!A-Za-z0-9._-]*) die "prepare: not a packet id: $pkt" ;; esac
  case "$model" in ''|*[!A-Za-z0-9._-]*) die "prepare: not a model token: $model" ;; esac
  [ -x "$ROUTING" ] || die "prepare: routing.sh is missing or not executable: $ROUTING" 2
  [ -x "$BACKLOG" ] || die "prepare: gspec-backlog.sh is missing or not executable: $BACKLOG" 2
  [ -x "$RUNSTATE" ] || die "prepare: runstate.sh is missing or not executable: $RUNSTATE" 2

  local store dir sel
  store="$(store_root)"
  dir="$store/$exp"
  sel="$dir/selection.json"
  [ -f "$sel" ] || die "prepare: no stored selection for experiment $exp (run \`compare.sh select\` first): $sel"

  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "prepare: cannot create a temp root"
  trap _cmp_prepare_cleanup EXIT
  local tmp="$_CMP_TMP"

  # --- the stored selection: settings, and this packet's row -----------------
  json_flat "$sel" > "$tmp/sel" || die "prepare: the stored selection is not readable JSON: $sel"
  local sexp src role rmodel
  sexp="$(awk -F'\t' '$2 == ".experiment" { print $4; exit }' "$tmp/sel")"
  [ "$sexp" = "$exp" ] || die "prepare: the stored selection names experiment [$sexp], not $exp: $sel"
  src="$(awk -F'\t' '$2 == ".settings.source_repo" { print $4; exit }' "$tmp/sel")"
  role="$(awk -F'\t' '$2 == ".settings.role" { print $4; exit }' "$tmp/sel")"
  rmodel="$(awk -F'\t' '$2 == ".settings.reviewer_model" { print $4; exit }' "$tmp/sel")"
  awk -F'\t' '$2 ~ /^\.settings\.models\[[0-9]+\]$/ { print $4 }' "$tmp/sel" > "$tmp/models"
  case "$role" in ''|*[!a-z-]*) die "prepare: the stored selection's role is malformed: [$role]" ;; esac
  case "$rmodel" in ''|*[!A-Za-z0-9._-]*) die "prepare: the stored selection's reviewer model is malformed: [$rmodel]" ;; esac
  if LC_ALL=C grep -q '[^A-Za-z0-9._-]' "$tmp/models" 2>/dev/null || [ ! -s "$tmp/models" ]; then
    die "prepare: the stored selection's models are malformed: $sel"
  fi
  if ! M="$model" awk '$0 == ENVIRON["M"] { f = 1 } END { exit !f }' "$tmp/models"; then
    die "prepare: $model is not one of experiment $exp's models ($(paste -sd, - < "$tmp/models"))"
  fi
  # Every identifier a name must not contain: each model, and the reviewer's.
  { cat "$tmp/models"; printf '%s\n' "$rmodel"; } > "$tmp/ids"

  local idx start kind tier
  idx="$(P="$pkt" awk -F'\t' '$2 ~ /^\.selected\[[0-9]+\]\.packet$/ && $4 == ENVIRON["P"] { i = $2; sub(/^\.selected\[/, "", i); sub(/\].*$/, "", i); print i; exit }' "$tmp/sel")"
  [ -n "$idx" ] || die "prepare: packet $pkt is not in experiment $exp's selection: $sel"
  start="$(I=".selected[$idx].start" awk -F'\t' '$2 == ENVIRON["I"] { print $4; exit }' "$tmp/sel")"
  kind="$(I=".selected[$idx].handoff" awk -F'\t' '$2 == ENVIRON["I"] { print $4; exit }' "$tmp/sel")"
  tier="$(I=".selected[$idx].tier" awk -F'\t' '$2 == ENVIRON["I"] { print $4; exit }' "$tmp/sel")"
  case "$start" in ''|*[!0-9a-f]*) die "prepare: packet $pkt's stored start is not a commit id: [$start]" ;; esac
  case "$kind" in original|rebuilt) ;; *) die "prepare: packet $pkt's stored handoff source is neither original nor rebuilt: [$kind]" ;; esac
  case "$tier" in ''|*[!a-z-]*) die "prepare: packet $pkt's stored tier is not [a-z-]+: [$tier]" ;; esac

  # --- the source and the scratch root -----------------------------------------
  [ -n "$src" ] && git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
    || die "prepare: the source repository is not a git repository: $src"
  git -C "$src" cat-file -e "${start}^{commit}" 2>/dev/null \
    || die "prepare: packet $pkt's start commit is not in the source repository: $start"
  local srctop scratch
  srctop="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  [ -n "$srctop" ] && srctop="$(cd "$srctop" && pwd -P)"
  scratch="${ORCH_COMPARE_SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$scratch" 2>/dev/null || die "prepare: cannot create the scratch root: $scratch"
  scratch="$(cd "$scratch" && pwd -P)" || die "prepare: cannot enter the scratch root: $scratch"
  if [ -n "$srctop" ]; then
    case "$scratch/" in
      "$srctop/"*) die "prepare: the scratch root lies inside the source repository's working tree, which a replay must leave untouched: $scratch" ;;
    esac
  fi

  # --- 1. the clone, on its opaque branch -----------------------------------------
  local dname bname rid clone
  dname="$(opaque_name "" "$tmp/ids")" || die "prepare: no directory name free of every model identifier could be drawn"
  bname="$(opaque_name "replay-" "$tmp/ids")" || die "prepare: no branch name free of every model identifier could be drawn"
  rid="$(opaque_name "" "$tmp/ids" | cut -c1-12)"
  [ "${#rid}" -eq 12 ] || die "prepare: no replay id could be drawn"
  clone="$scratch/$dname"
  [ ! -e "$clone" ] || die "prepare: the drawn clone path already exists: $clone"
  _CMP_CLONE="$clone"
  opaque_clone prepare "$src" "$start" "$clone" "$bname" "$tmp"

  # --- 2. model_routing in the clone's own configuration ---------------------------
  local ov got_role got_rev
  ov="$clone/.agents/project-overrides.yaml"
  mkdir -p "$clone/.agents" || die "prepare: cannot create $clone/.agents"
  set_routing "$ov" "$tmp/overrides" "$role" "$model" "$rmodel" \
    || die "prepare: the clone's model_routing cannot be read, so it cannot be set: $ov"
  cp "$tmp/overrides" "$ov" || die "prepare: cannot write $ov"
  got_role="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$clone" resolve "$role" 2>/dev/null | tr -d '\r')"
  got_rev="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$clone" resolve reviewer 2>/dev/null | tr -d '\r')"
  [ "$got_role" = "$model" ] && [ "$got_rev" = "$rmodel" ] \
    || die "prepare: routing.sh does not resolve the clone's routing as set ($role -> [$got_role], wanted $model; reviewer -> [$got_rev], wanted $rmodel)"

  # --- 3. run-state and begin-run, run in the clone ----------------------------------
  local rs bout run_id
  rs="$clone/.agents/run-state.yaml"
  printf "schema: 3\nstatus: 'running'\nbranch: '%s'\nlast_green_commit: '%s'\n" "$bname" "$start" \
    | (cd "$clone" && CLAUDE_PROJECT_DIR="$clone" "$RUNSTATE" write "$rs") >/dev/null 2>"$tmp/rs.err" \
    || die "prepare: runstate.sh write failed in the clone: $(head -1 "$tmp/rs.err")"
  bout="$(cd "$clone" && CLAUDE_PROJECT_DIR="$clone" "$RUNSTATE" begin-run "$rs" 2>"$tmp/rs.err" | tr -d '\r')" \
    || die "prepare: runstate.sh begin-run failed in the clone: $(head -1 "$tmp/rs.err")"
  run_id="$(printf '%s\n' "$bout" | sed -n 's/^RUN_ID=//p' | head -1)"
  [ -n "$run_id" ] || die "prepare: runstate.sh begin-run printed no RUN_ID"

  # --- 4. the handoff: cached once per packet, installed from the cache ----------------
  local pktdir target cache cached="reused" hout d orig=""
  pktdir="$clone/.agents/loop/$run_id/$pkt"
  target="$pktdir/handoff.md"
  cache="$dir/handoffs/$pkt.md"
  if [ ! -f "$cache" ]; then
    case "$kind" in
      original)
        # The earliest run's handoff (run ids sort by time), the first match,
        # as `candidates` detects it: the one its first dispatch received.
        set +f
        for d in "$src"/.agents/loop/*/; do
          if [ -f "${d}${pkt}/handoff.md" ]; then orig="${d}${pkt}/handoff.md"; break; fi
        done
        set -f
        [ -n "$orig" ] || die "prepare: packet $pkt's original handoff is no longer in the source repository, and none is cached: $cache"
        first_dispatch "$orig" "$tmp/handoff" \
          || die "prepare: the original handoff carries a loop splice block that cannot be removed as either command writes it, so its first-dispatch bytes are unknown: $orig"
        ;;
      rebuilt)
        (cd "$clone" && CLAUDE_PROJECT_DIR="$clone" "$BACKLOG" handoff "$pkt" "$clone" </dev/null) > "$tmp/body" 2>"$tmp/bl.err" \
          || die "prepare: gspec-backlog.sh handoff failed in the clone: $(head -1 "$tmp/bl.err")"
        case "$(head -1 "$tmp/body")" in
          PACKET=*) ;;
          *) die "prepare: gspec-backlog.sh does not resolve $pkt in the clone: $(sed -n 's/^REASON=//p' "$tmp/body" | head -1)" ;;
        esac
        hout="$(cd "$clone" && CLAUDE_PROJECT_DIR="$clone" "$RUNSTATE" handoff "$rs" "$pkt" --tier "$tier" --agent "$role" < "$tmp/body" 2>"$tmp/rs.err" | tr -d '\r')" \
          || die "prepare: runstate.sh handoff failed in the clone: $(head -1 "$tmp/rs.err")"
        case "$hout" in
          HANDOFF=*) ;;
          *) die "prepare: runstate.sh handoff wrote no handoff: $(printf '%s' "$hout" | head -1)" ;;
        esac
        cp "${hout#HANDOFF=}" "$tmp/handoff" || die "prepare: cannot read the rebuilt handoff: ${hout#HANDOFF=}"
        ;;
    esac
    # Written once: `ln` refuses an existing name, so a cache another prepare
    # wrote first is kept and used, never replaced.
    mkdir -p "$dir/handoffs" || die "prepare: cannot create the handoff cache: $dir/handoffs"
    cp "$tmp/handoff" "$dir/handoffs/.$pkt.md.$$" || die "prepare: cannot write the handoff cache: $cache"
    if ln "$dir/handoffs/.$pkt.md.$$" "$cache" 2>/dev/null; then cached="written"; fi
    rm -f "$dir/handoffs/.$pkt.md.$$"
    [ -f "$cache" ] || die "prepare: the handoff cache could not be written: $cache"
  fi
  mkdir -p "$pktdir" || die "prepare: cannot create $pktdir"
  cp "$cache" "$target" || die "prepare: cannot install the handoff: $target"

  # --- the replay's record, then the clone is kept -------------------------------------
  local out
  out="REPLAY=$rid
EXPERIMENT=$exp
PACKET=$pkt
MODEL=$model
ROLE=$role
REVIEWER_MODEL=$rmodel
SOURCE_REPO=$src
START=$start
CLONE=$clone
BRANCH=$bname
RUN_STATE=$rs
RUN_ID=$run_id
HANDOFF=$target
HANDOFF_SOURCE=$kind
HANDOFF_CACHE=$cache
HANDOFF_CACHED=$cached"
  mkdir -p "$dir/replays" || die "prepare: cannot create $dir/replays"
  printf '%s\n' "$out" > "$dir/replays/.$rid.env.$$" && mv "$dir/replays/.$rid.env.$$" "$dir/replays/$rid.env" \
    || die "prepare: cannot write the replay record: $dir/replays/$rid.env"
  _CMP_CLONE=""
  printf '%s\n' "$out"
}

# --- review-view ---------------------------------------------------------------------

# The fixed, neutral identity and text of every commit a review view holds: the
# same for every replay and every model, carrying no trailer of any kind.
_CMP_VIEW_NAME="compare"
_CMP_VIEW_EMAIL="compare@example.invalid"
_CMP_VIEW_DATE="2000-01-01T00:00:00Z"
_CMP_VIEW_BASE_MSG="Review configuration"
_CMP_VIEW_HEAD_MSG="Changes under review"

# The work clone's paths that never reach a view as changed: they stay as the
# start commit holds them. The routing configuration is handled on its own.
_CMP_VIEW_EXCLUDED=".agents/metrics .agents/loop .agents/run-state.yaml .agents/run-state-prev.yaml"

# redact <ids-file> <in> <out>: <in> with every word (a maximal run of
# [A-Za-z0-9_-], dots allowed only inside it, so a sentence's full stop is
# kept) containing any identifier in <ids-file>, compared
# case-insensitively, replaced whole by `[model]`, together with a version
# number that directly follows it after spaces (`Opus 4.5`). A whole word, so
# a resolved id such as `claude-sonnet-5` leaves no version or family behind.
redact() {
  awk '
    NR == FNR { if ($0 != "") ids[++n] = tolower($0); next }
    {
      s = $0; out = ""
      while (match(s, /[A-Za-z0-9_-]+([.][A-Za-z0-9_-]+)*/)) {
        pre = substr(s, 1, RSTART - 1); tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        lt = tolower(tok); hit = 0
        for (i = 1; i <= n; i++) if (index(lt, ids[i])) { hit = 1; break }
        if (hit) {
          tok = "[model]"
          if (match(s, /^[ ]+[0-9]+([.][0-9]+)*/)) s = substr(s, RLENGTH + 1)
        }
        out = out pre tok
      }
      print out s
    }' "$1" "$2" > "$3"
}

# view_header <in> <out> <run-state> <result> <review>: <in> with its header's
# `run-state:`, `result:` and `review:` lines (the first of each, before the
# first `PACKET=` or `<!--` line) pointing into the view, so no header path
# leads a reviewer back to the work clone or the source run.
view_header() {
  RS="$3" RES="$4" REV="$5" awk '
    !body && (/^PACKET=/ || /^<!--/) { body = 1 }
    !body && !rs  && /^run-state: / { print "run-state: " ENVIRON["RS"]; rs = 1; next }
    !body && !res && /^result: /    { print "result: " ENVIRON["RES"]; res = 1; next }
    !body && !rev && /^review: /    { print "review: " ENVIRON["REV"]; rev = 1; next }
    { print }' "$1" > "$2"
}

_CMP_VIEW=""
_cmp_view_cleanup() {
  if [ -n "$_CMP_TMP" ]; then rm -rf "$_CMP_TMP"; fi
  if [ -n "$_CMP_VIEW" ]; then rm -rf "$_CMP_VIEW"; fi
  return 0
}

cmd_review_view() {
  [ $# -eq 1 ] || usage
  local rid="$1"
  case "$rid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "review-view: not a replay id (12 hex, as \`prepare\` prints it): $rid" ;;
  esac
  [ -x "$ROUTING" ] || die "review-view: routing.sh is missing or not executable: $ROUTING" 2
  [ -x "$RUNSTATE" ] || die "review-view: runstate.sh is missing or not executable: $RUNSTATE" 2

  # --- the replay's record, found in whichever experiment holds it --------------
  local store env="" f n=0
  store="$(store_root)"
  set +f
  for f in "$store"/*/replays/"$rid".env; do
    if [ -f "$f" ]; then env="$f"; n=$((n + 1)); fi
  done
  set -f
  [ "$n" -gt 0 ] || die "review-view: no replay record for $rid under $store (run \`compare.sh prepare\` first)"
  [ "$n" -eq 1 ] || die "review-view: replay $rid is recorded in $n experiments under $store; refusing to guess"
  local exp pkt role rmodel src start clone run_id handoff
  exp="$(sed -n 's/^EXPERIMENT=//p' "$env" | head -1)"
  pkt="$(sed -n 's/^PACKET=//p' "$env" | head -1)"
  role="$(sed -n 's/^ROLE=//p' "$env" | head -1)"
  rmodel="$(sed -n 's/^REVIEWER_MODEL=//p' "$env" | head -1)"
  src="$(sed -n 's/^SOURCE_REPO=//p' "$env" | head -1)"
  start="$(sed -n 's/^START=//p' "$env" | head -1)"
  clone="$(sed -n 's/^CLONE=//p' "$env" | head -1)"
  run_id="$(sed -n 's/^RUN_ID=//p' "$env" | head -1)"
  handoff="$(sed -n 's/^HANDOFF=//p' "$env" | head -1)"
  case "$pkt" in ''|*[!A-Za-z0-9._-]*) die "review-view: the replay record's packet is malformed: [$pkt]" ;; esac
  case "$role" in ''|*[!a-z-]*) die "review-view: the replay record's role is malformed: [$role]" ;; esac
  case "$rmodel" in ''|*[!A-Za-z0-9._-]*) die "review-view: the replay record's reviewer model is malformed: [$rmodel]" ;; esac
  case "$start" in ''|*[!0-9a-f]*) die "review-view: the replay record's start is not a commit id: [$start]" ;; esac
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) die "review-view: the replay record's run id is malformed: [$run_id]" ;; esac
  [ -n "$clone" ] && git -C "$clone" rev-parse --git-dir >/dev/null 2>&1 \
    || die "review-view: the replay's work clone is not a git repository: $clone"
  git -C "$clone" cat-file -e "${start}^{commit}" 2>/dev/null \
    || die "review-view: the replay's start commit is not in its work clone: $start"

  local sel="$store/$exp/selection.json"
  [ -f "$sel" ] || die "review-view: no stored selection for the replay's experiment $exp: $sel"

  _CMP_TMP="$(mktemp -d 2>/dev/null)" || die "review-view: cannot create a temp root"
  trap _cmp_view_cleanup EXIT
  local tmp="$_CMP_TMP"

  # Every identifier of the settings' models: each model as the settings name
  # it (which is also its routing alias) and the reviewer's. A resolved id
  # (`claude-<alias>-...`) contains its alias, so `redact` replaces it whole.
  json_flat "$sel" > "$tmp/sel" || die "review-view: the stored selection is not readable JSON: $sel"
  { awk -F'\t' '$2 ~ /^\.settings\.models\[[0-9]+\]$/ { print $4 }' "$tmp/sel"; printf '%s\n' "$rmodel"; } > "$tmp/ids"
  if LC_ALL=C grep -q '[^A-Za-z0-9._-]' "$tmp/ids" 2>/dev/null || [ "$(grep -c . "$tmp/ids")" -lt 2 ]; then
    die "review-view: the stored selection's models are malformed: $sel"
  fi

  # --- 1. the work clone's current diff, as a tree, built without touching it ----------
  # A temp index and a temp object directory (the clone's own objects as an
  # alternate): the clone's index, object store and refs are only read.
  local cobj
  cobj="$(cd "$clone" && cd "$(git rev-parse --git-path objects 2>/dev/null)" 2>/dev/null && pwd -P)" \
    || die "review-view: cannot find the work clone's object store: $clone"
  mkdir -p "$tmp/objects" || die "review-view: cannot create a temp object store"
  _gw() { GIT_INDEX_FILE="$tmp/$1.idx" GIT_OBJECT_DIRECTORY="$tmp/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$cobj" \
            git -C "$clone" "${@:2}"; }
  local ov=".agents/project-overrides.yaml" p blob tbase thead
  # The routing configuration: the start's file and the work clone's current
  # file, each with `model_routing` reduced to the reviewer's entry alone. So
  # the reviewed change (base -> head) holds the packet's own edits to the file,
  # never the replay's routing, and the view resolves only the reviewer.
  if git -C "$clone" cat-file -e "$start:$ov" 2>/dev/null; then
    git -C "$clone" show "$start:$ov" > "$tmp/ov.start" 2>/dev/null || die "review-view: cannot read the start's $ov"
  fi
  set_routing "$tmp/ov.start" "$tmp/ov.base" "" "" "$rmodel" \
    || die "review-view: the start commit's model_routing cannot be read, so it cannot be reduced: $ov"
  set_routing "$clone/$ov" "$tmp/ov.head" "" "" "$rmodel" \
    || die "review-view: the work clone's model_routing cannot be read, so it cannot be reduced: $clone/$ov"
  for p in base head; do
    _gw "$p" read-tree "$start" 2>"$tmp/git.err" || die "review-view: cannot read the start tree: $(head -1 "$tmp/git.err")"
  done
  _gw head add -A -- . 2>"$tmp/git.err" || die "review-view: cannot stage the work clone's changes: $(head -1 "$tmp/git.err")"
  for p in $_CMP_VIEW_EXCLUDED; do
    _gw head rm --cached -r -q --ignore-unmatch -- "$p" >/dev/null 2>"$tmp/git.err" \
      || die "review-view: cannot drop $p from the reviewed change: $(head -1 "$tmp/git.err")"
    git -C "$clone" ls-tree -r "$start" -- "$p" > "$tmp/keep" 2>/dev/null
    _gw head update-index --index-info < "$tmp/keep" 2>"$tmp/git.err" \
      || die "review-view: cannot restore $p as the start holds it: $(head -1 "$tmp/git.err")"
  done
  for p in base head; do
    blob="$(_gw "$p" hash-object -w "$tmp/ov.$p" 2>/dev/null)" || die "review-view: cannot store the reduced $ov"
    _gw "$p" update-index --add --cacheinfo "100644,$blob,$ov" 2>"$tmp/git.err" \
      || die "review-view: cannot stage the reduced $ov: $(head -1 "$tmp/git.err")"
  done
  tbase="$(_gw base write-tree 2>/dev/null)" || die "review-view: cannot write the view's base tree"
  thead="$(_gw head write-tree 2>/dev/null)" || die "review-view: cannot write the view's reviewed tree"
  _gw head diff --binary --no-renames "$tbase" "$thead" > "$tmp/change.patch" 2>"$tmp/git.err" \
    || die "review-view: cannot diff the reviewed change: $(head -1 "$tmp/git.err")"

  # --- 2. the view: a second opaque clone of the source at the start ------------------
  local scratch dname bname view
  [ -n "$src" ] && git -C "$src" rev-parse --git-dir >/dev/null 2>&1 \
    || die "review-view: the source repository is not a git repository: $src"
  scratch="${ORCH_COMPARE_SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$scratch" 2>/dev/null || die "review-view: cannot create the scratch root: $scratch"
  scratch="$(cd "$scratch" && pwd -P)" || die "review-view: cannot enter the scratch root: $scratch"
  local srctop
  srctop="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  [ -n "$srctop" ] && srctop="$(cd "$srctop" && pwd -P)"
  if [ -n "$srctop" ]; then
    case "$scratch/" in
      "$srctop/"*) die "review-view: the scratch root lies inside the source repository's working tree: $scratch" ;;
    esac
  fi
  # The reviewer works in the view, so its whole path is something it reads.
  if names_model "$scratch" "$tmp/ids"; then
    die "review-view: the scratch root's path names a model, which the reviewer would read: $scratch"
  fi
  dname="$(opaque_name "" "$tmp/ids")" || die "review-view: no directory name free of every model identifier could be drawn"
  bname="$(opaque_name "review-" "$tmp/ids")" || die "review-view: no branch name free of every model identifier could be drawn"
  view="$scratch/$dname"
  [ ! -e "$view" ] || die "review-view: the drawn view path already exists: $view"
  _CMP_VIEW="$view"
  opaque_clone review-view "$src" "$start" "$view" "$bname" "$tmp"

  # --- 3. two commits, fixed and neutral: the reviewer's configuration, then the change -
  _vc() {  # _vc <tree> <parent> <message> -> the new commit's id
    GIT_AUTHOR_NAME="$_CMP_VIEW_NAME" GIT_AUTHOR_EMAIL="$_CMP_VIEW_EMAIL" GIT_AUTHOR_DATE="$_CMP_VIEW_DATE" \
    GIT_COMMITTER_NAME="$_CMP_VIEW_NAME" GIT_COMMITTER_EMAIL="$_CMP_VIEW_EMAIL" GIT_COMMITTER_DATE="$_CMP_VIEW_DATE" \
      git -C "$view" -c commit.gpgsign=false commit-tree "$1" -p "$2" -m "$3" 2>/dev/null
  }
  local base head got
  mkdir -p "$view/.agents" || die "review-view: cannot create $view/.agents"
  cp "$tmp/ov.base" "$view/$ov" || die "review-view: cannot write the view's $ov"
  git -C "$view" add -f -- "$ov" >/dev/null 2>&1 || die "review-view: cannot stage the view's $ov"
  got="$(git -C "$view" write-tree 2>/dev/null)"
  [ "$got" = "$tbase" ] || die "review-view: the view's base tree [$got] is not the one built from the work clone [$tbase]"
  if [ "$tbase" = "$(git -C "$view" rev-parse "$start^{tree}" 2>/dev/null)" ]; then
    base="$start"
  else
    base="$(_vc "$tbase" "$start" "$_CMP_VIEW_BASE_MSG")" && [ -n "$base" ] || die "review-view: cannot commit the view's configuration"
  fi
  if [ -s "$tmp/change.patch" ]; then
    git -C "$view" apply --index --binary "$tmp/change.patch" 2>"$tmp/git.err" \
      || die "review-view: the work clone's change does not apply to the view: $(head -1 "$tmp/git.err")"
  fi
  got="$(git -C "$view" write-tree 2>/dev/null)"
  [ "$got" = "$thead" ] || die "review-view: the view's reviewed tree [$got] is not the work clone's change [$thead]"
  head="$(_vc "$thead" "$base" "$_CMP_VIEW_HEAD_MSG")" && [ -n "$head" ] || die "review-view: cannot commit the change under review"
  git -C "$view" update-ref -m "$_CMP_VIEW_HEAD_MSG" "refs/heads/$bname" "$head" >/dev/null 2>&1 \
    || die "review-view: cannot move the view's branch to the change under review"
  got="$(git -C "$view" status --porcelain=v1 --untracked-files=no 2>/dev/null)"
  [ -z "$got" ] || die "review-view: the view's tree is not clean at the change under review: $(printf '%s' "$got" | head -1)"
  local r_rev
  r_rev="$(ORCH_ROUTING_AGENTS_DIR="$AGENTS_DIR" "$ROUTING" --root "$view" resolve reviewer 2>/dev/null | tr -d '\r')"
  [ "$r_rev" = "$rmodel" ] \
    || die "review-view: routing.sh does not resolve the view's reviewer as set (reviewer -> [$r_rev], wanted $rmodel)"

  # --- 4. the view's own run-state and run directory ---------------------------------
  local rs bout vrun vdir
  rs="$view/.agents/run-state.yaml"
  printf "schema: 3\nstatus: 'running'\nbranch: '%s'\nlast_green_commit: '%s'\n" "$bname" "$base" \
    | (cd "$view" && CLAUDE_PROJECT_DIR="$view" "$RUNSTATE" write "$rs") >/dev/null 2>"$tmp/rs.err" \
    || die "review-view: runstate.sh write failed in the view: $(head -1 "$tmp/rs.err")"
  bout="$(cd "$view" && CLAUDE_PROJECT_DIR="$view" "$RUNSTATE" begin-run "$rs" 2>"$tmp/rs.err" | tr -d '\r')" \
    || die "review-view: runstate.sh begin-run failed in the view: $(head -1 "$tmp/rs.err")"
  vrun="$(printf '%s\n' "$bout" | sed -n 's/^RUN_ID=//p' | head -1)"
  [ -n "$vrun" ] || die "review-view: runstate.sh begin-run printed no RUN_ID in the view"

  # --- 5. the handoff and result file, redacted --------------------------------------
  local vh vres vrev wres
  vdir="$view/.agents/loop/$vrun/$pkt"
  vh="$vdir/handoff.md"; vres="$vdir/$role.md"; vrev="$vdir/review.md"
  mkdir -p "$vdir" || die "review-view: cannot create $vdir"
  [ -f "$handoff" ] || die "review-view: the replay's handoff is missing from its work clone: $handoff"
  redact "$tmp/ids" "$handoff" "$tmp/handoff.red" || die "review-view: cannot redact the handoff"
  view_header "$tmp/handoff.red" "$vh" "$rs" "$vres" "$vrev" || die "review-view: cannot write the view's handoff: $vh"
  wres="$clone/.agents/loop/$run_id/$pkt/$role.md"
  if [ -f "$wres" ]; then
    redact "$tmp/ids" "$wres" "$vres" || die "review-view: cannot write the view's result file: $vres"
  else
    vres="none"
  fi

  local out
  out="REPLAY=$rid
VIEW=$view
BRANCH=$bname
START=$start
BASE=$base
HEAD=$head
RUN_STATE=$rs
RUN_ID=$vrun
HANDOFF=$vh
RESULT=$vres
REVIEW=$vrev"
  printf 'VIEW=%s\n' "$view" >> "$store/$exp/replays/$rid.views" \
    || die "review-view: cannot record the view: $store/$exp/replays/$rid.views"
  _CMP_VIEW=""
  printf '%s\n' "$out"
}

[ $# -ge 1 ] || usage
SUB="$1"; shift
case "$SUB" in
  settings)   cmd_settings "$@" ;;
  candidates) cmd_candidates "$@" ;;
  select)     cmd_select "$@" ;;
  estimate)   cmd_estimate "$@" ;;
  prepare)    cmd_prepare "$@" ;;
  review-view) cmd_review_view "$@" ;;
  *) usage ;;
esac
exit 0
