#!/usr/bin/env bash
# =============================================================================
# routing.sh — per-agent model routing lookup (per-agent-model-routing)
# =============================================================================
# The ONE definition of how `model_routing` (and `extra_models`) in
# `<main checkout>/.agents/project-overrides.yaml` turn into the model a dispatch
# passes. No prompt parses that YAML or restates the precedence rule; every
# dispatch site names `routing.sh resolve <agent>` instead.
#
# Usage:  routing.sh [--root <dir>] <subcommand> [arg]
#
#   resolve <agent>   print the mapped alias when a VALID entry names <agent>
#                     (one leading `gaffer:` is stripped), else an EMPTY line.
#                     The output is exactly what the dispatch passes: non-empty
#                     goes in as `model`, empty means `model` is omitted and the
#                     agent's `model:` frontmatter applies.
#   validate          one line per invalid entry:
#                       ROUTING-INVALID key=<key> value=<value> reason=<reason>
#                     reasons: loop-driver | unknown-agent |
#                       unknown-model(add it to extra_models if the harness accepts it)
#                     An unparseable block is ONE line:
#                       ROUTING-INVALID key=model_routing value=- reason=unparseable
#                     (likewise key=extra_models; a bad extra_models item reads
#                     key=extra_models value=<item> reason=invalid-item).
#                     No output means the config is clean.
#   table             one line per valid entry whose alias differs from that
#                     agent's frontmatter model, sorted by agent:
#                       <agent> <frontmatter-model|-> <alias>
#
# Exit status: 0 in EVERY config state (missing file, missing key, invalid or
# unparseable config, not a git repo) so a dispatch never fails on routing.
# The only non-zero exit is 2, for a usage error (a caller bug, not a config
# state): an unknown subcommand, or `resolve` with no argument.
#
# Config root: `--root <dir>` reads <dir>/.agents/project-overrides.yaml.
# Without it the root is the dirname of `git rev-parse --git-common-dir` — the
# main checkout even from a worktree.
#
# Agent set: derived from ${ORCH_ROUTING_AGENTS_DIR:-<script dir>/../agents}/*.md
# (basename = agent name; frontmatter model = first `model:` line inside the
# leading `---` block). `loop-driver` is excluded — it is the session itself.
#
# Portability: parsing is an `awk` token-scan only (no jq, no python3), so this
# runs on stock Git Bash; no bash-4 features (macOS ships bash 3.2).
# =============================================================================

set -uo pipefail

# --- VALID_MODELS: the plugin's default accepted model aliases ----------------
# Source: the Agent tool's `model` dispatch-parameter enum as observed on
# 2026-09-18. The harness maps these family aliases to current versions, so
# this list changes only when a new model family ships. A repo that gets one
# first adds it via a top-level `extra_models:` key in project-overrides.yaml.
# Comparison is exact and case-sensitive (`Opus` is unknown-model).
VALID_MODELS=(sonnet opus haiku fable)

UNKNOWN_MODEL_REASON='unknown-model(add it to extra_models if the harness accepts it)'

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="${ORCH_ROUTING_AGENTS_DIR:-$HERE/../agents}"

usage() {
  echo "usage: routing.sh [--root <dir>] <resolve <agent>|validate|table>" >&2
  exit 2
}

# --- argument parsing ---------------------------------------------------------
ROOT=""
ROOT_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || usage
      ROOT="$2"; ROOT_SET=1; shift 2 ;;
    --root=*)
      ROOT="${1#--root=}"; ROOT_SET=1; shift ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || usage
SUB="$1"; shift
case "$SUB" in
  resolve) [ $# -ge 1 ] || usage ;;
  validate|table) ;;
  *) usage ;;
esac

# --- config root --------------------------------------------------------------
if [ "$ROOT_SET" -eq 0 ]; then
  gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$gcd" ]; then
    rel="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$rel" ]; then
      case "$rel" in
        /*) gcd="$rel" ;;
        *)  gcd="$(cd "$rel" 2>/dev/null && pwd || true)" ;;
      esac
    fi
  fi
  if [ -n "$gcd" ]; then ROOT="$(dirname "$gcd")"; fi
fi
OV=""
if [ -n "$ROOT" ]; then OV="$ROOT/.agents/project-overrides.yaml"; fi

# --- agent set: parallel arrays AG_NAMES / AG_MODELS ---------------------------
AG_NAMES=()
AG_MODELS=()
if [ -d "$AGENTS_DIR" ]; then
  for f in "$AGENTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .md)"
    [ "$name" = "loop-driver" ] && continue
    fm="$(awk '
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
    ' "$f" 2>/dev/null)"
    [ -n "$fm" ] || fm="-"
    AG_NAMES+=("$name")
    AG_MODELS+=("$fm")
  done
fi

# agent_model <name> -> frontmatter model; returns 1 when <name> is not an agent.
agent_model() {
  local i=0
  while [ "$i" -lt "${#AG_NAMES[@]}" ]; do
    if [ "${AG_NAMES[$i]}" = "$1" ]; then echo "${AG_MODELS[$i]}"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# --- config parse (awk token-scan) ---------------------------------------------
# Emits tab-separated records:
#   MR_STATE <absent|ok|unparseable>
#   MR <key> <value>          (only when MR_STATE is ok, in file order)
#   EX_STATE <absent|ok|unparseable>
#   EX <item>                 (only when EX_STATE is ok)
parse_config() {
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
    # add a "key: value" piece to the map; returns 0 on a parse failure.
    function add_pair(piece,    p, k, v) {
      piece = trim(piece)
      p = match(piece, /:([[:space:]]|$)/)
      if (p == 0) return 0
      k = unquote(trim(substr(piece, 1, p - 1)))
      v = unquote(trim(substr(piece, p + 1)))
      if (k == "" || v == "") return 0
      if (v ~ /^[\[{]/) return 0
      if (k in seen) return 0
      seen[k] = 1
      nk++; keys[nk] = k; vals[nk] = v
      return 1
    }
    function add_item(item) {
      item = unquote(trim(item))
      if (item == "") return 0
      ni++; items[ni] = item
      return 1
    }
    function close_block() { mode = "" }
    BEGIN { mr = "absent"; ex = "absent"; mode = ""; nk = 0; ni = 0 }
    { sub(/\r$/, "") }
    {
      line = $0
      # Inside an open block: indented / blank / comment lines belong to it.
      if (mode != "") {
        t = trim(line)
        if (t == "" || t ~ /^#/) next
        if (line ~ /^[[:space:]]/ || (mode == "exblock" && line ~ /^-([[:space:]]|$)/)) {
          ind = match(line, /[^[:space:]]/) - 1
          body = uncomment(t)
          if (mode == "mrflow") { mr = "unparseable"; next }
          if (mode == "exflow") { ex = "unparseable"; next }
          if (mode == "mrblock") {
            if (mr != "ok") next
            if (mrind < 0) mrind = ind
            if (ind != mrind || body ~ /^-/ || !add_pair(body)) mr = "unparseable"
            next
          }
          if (mode == "exblock") {
            if (ex != "ok") next
            if (exind < 0) exind = ind
            if (ind != exind || body !~ /^-([[:space:]]|$)/) { ex = "unparseable"; next }
            sub(/^-[[:space:]]*/, "", body)
            if (!add_item(body)) ex = "unparseable"
            next
          }
        }
        # A column-0 line under model_routing that is a sequence item is not a map.
        if (mode == "mrblock" && line ~ /^-([[:space:]]|$)/) { mr = "unparseable"; next }
        close_block()
      }
      if (line ~ /^model_routing:/) {
        if (mr != "absent") { mr = "unparseable"; mode = "mrflow"; next }
        rest = trim(uncomment(trim(substr(line, length("model_routing:") + 1))))
        mr = "ok"
        if (rest == "") { mode = "mrblock"; mrind = -1; next }
        mode = "mrflow"
        if (rest !~ /^\{/ || rest !~ /\}$/) { mr = "unparseable"; next }
        inner = trim(substr(rest, 2, length(rest) - 2))
        if (inner == "") next
        if (inner ~ /[{}]/) { mr = "unparseable"; next }
        n = split(inner, pcs, ",")
        for (i = 1; i <= n; i++) {
          if (trim(pcs[i]) == "" && i == n && n > 1) continue
          if (!add_pair(pcs[i])) { mr = "unparseable"; break }
        }
        next
      }
      if (line ~ /^extra_models:/) {
        if (ex != "absent") { ex = "unparseable"; mode = "exflow"; next }
        rest = trim(uncomment(trim(substr(line, length("extra_models:") + 1))))
        ex = "ok"
        if (rest == "") { mode = "exblock"; exind = -1; next }
        mode = "exflow"
        if (rest !~ /^\[/ || rest !~ /\]$/) { ex = "unparseable"; next }
        inner = trim(substr(rest, 2, length(rest) - 2))
        if (inner == "") next
        if (inner ~ /[\[\]{}]/) { ex = "unparseable"; next }
        n = split(inner, pcs, ",")
        for (i = 1; i <= n; i++) {
          if (trim(pcs[i]) == "" && i == n && n > 1) continue
          if (!add_item(pcs[i])) { ex = "unparseable"; break }
        }
        next
      }
    }
    END {
      # A bare `model_routing:` with no entries (YAML null) reads as an empty
      # map: every agent keeps its default, and there is nothing to report.
      print "MR_STATE\t" mr
      if (mr == "ok") for (i = 1; i <= nk; i++) print "MR\t" keys[i] "\t" vals[i]
      print "EX_STATE\t" ex
      if (ex == "ok") for (i = 1; i <= ni; i++) print "EX\t" items[i]
    }
  ' "$1" 2>/dev/null
}

MR_STATE="absent"
EX_STATE="absent"
MR_KEYS=()
MR_VALS=()
EX_ITEMS=()
if [ -n "$OV" ] && [ -f "$OV" ]; then
  parsed="$(parse_config "$OV" | tr -d '\r')"
  while IFS="$(printf '\t')" read -r kind a b; do
    case "$kind" in
      MR_STATE) MR_STATE="$a" ;;
      EX_STATE) EX_STATE="$a" ;;
      MR) MR_KEYS+=("$a"); MR_VALS+=("$b") ;;
      EX) EX_ITEMS+=("$a") ;;
    esac
  done <<EOF
$parsed
EOF
fi
[ -n "$MR_STATE" ] || MR_STATE="absent"
[ -n "$EX_STATE" ] || EX_STATE="absent"

# --- accepted models: VALID_MODELS + well-formed extra_models items ------------
ACCEPTED=("${VALID_MODELS[@]}")
REPORT=()
if [ "$EX_STATE" = "unparseable" ]; then
  REPORT+=("ROUTING-INVALID key=extra_models value=- reason=unparseable")
elif [ "$EX_STATE" = "ok" ] && [ "${#EX_ITEMS[@]}" -gt 0 ]; then
  for it in "${EX_ITEMS[@]}"; do
    case "$it" in
      *[!A-Za-z0-9._-]*|'') REPORT+=("ROUTING-INVALID key=extra_models value=$it reason=invalid-item") ;;
      *) ACCEPTED+=("$it") ;;
    esac
  done
fi

is_accepted() {
  local m
  for m in "${ACCEPTED[@]}"; do
    [ "$m" = "$1" ] && return 0
  done
  return 1
}

# --- validate model_routing entries: VALID_KEYS / VALID_VALS -------------------
VALID_KEYS=()
VALID_VALS=()
MR_REPORT=()
if [ "$MR_STATE" = "unparseable" ]; then
  MR_REPORT+=("ROUTING-INVALID key=model_routing value=- reason=unparseable")
elif [ "$MR_STATE" = "ok" ] && [ "${#MR_KEYS[@]}" -gt 0 ]; then
  i=0
  while [ "$i" -lt "${#MR_KEYS[@]}" ]; do
    k="${MR_KEYS[$i]}"; v="${MR_VALS[$i]}"
    reason=""
    if [ "$k" = "loop-driver" ]; then
      reason="loop-driver"
    elif ! agent_model "$k" >/dev/null; then
      reason="unknown-agent"
    elif ! is_accepted "$v"; then
      reason="$UNKNOWN_MODEL_REASON"
    fi
    if [ -n "$reason" ]; then
      MR_REPORT+=("ROUTING-INVALID key=$k value=$v reason=$reason")
    else
      VALID_KEYS+=("$k"); VALID_VALS+=("$v")
    fi
    i=$((i + 1))
  done
fi

# --- subcommands ----------------------------------------------------------------
case "$SUB" in
  resolve)
    agent="${1#gaffer:}"
    out=""
    i=0
    while [ "$i" -lt "${#VALID_KEYS[@]}" ]; do
      if [ "${VALID_KEYS[$i]}" = "$agent" ]; then out="${VALID_VALS[$i]}"; break; fi
      i=$((i + 1))
    done
    printf '%s\n' "$out"
    ;;
  validate)
    if [ "${#MR_REPORT[@]}" -gt 0 ]; then printf '%s\n' "${MR_REPORT[@]}"; fi
    if [ "${#REPORT[@]}" -gt 0 ]; then printf '%s\n' "${REPORT[@]}"; fi
    ;;
  table)
    i=0
    rows=""
    while [ "$i" -lt "${#VALID_KEYS[@]}" ]; do
      k="${VALID_KEYS[$i]}"; v="${VALID_VALS[$i]}"
      fm="$(agent_model "$k")"
      if [ "$fm" != "$v" ]; then rows="${rows}${k} ${fm} ${v}
"
      fi
      i=$((i + 1))
    done
    if [ -n "$rows" ]; then printf '%s' "$rows" | LC_ALL=C sort; fi
    ;;
esac
exit 0
