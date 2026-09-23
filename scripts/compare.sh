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
# Exit status: 0 printed settings / candidates / a selection; 1 refused, no
# experiment id could be computed, the source repository is not a git
# repository, or the selection could not be written; 2 usage error, or
# routing.sh / gspec-backlog.sh missing beside this script.
#
# Portability: awk + bash 3.2 (no associative arrays), no jq, no python3.
# =============================================================================

set -uo pipefail
set -f   # no globbing: list items are split on `,` and must never expand

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROUTING="$HERE/routing.sh"
BACKLOG="$HERE/gspec-backlog.sh"
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
usage() { printf 'usage: compare.sh {settings|candidates|select} <file>\n' >&2; exit 2; }

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

[ $# -ge 1 ] || usage
SUB="$1"; shift
case "$SUB" in
  settings)   cmd_settings "$@" ;;
  candidates) cmd_candidates "$@" ;;
  select)     cmd_select "$@" ;;
  *) usage ;;
esac
exit 0
