#!/usr/bin/env bash
# =============================================================================
# compare-confine.sh — the model-comparison harness's confinement hook
# =============================================================================
# A `PreToolUse` hook that `compare.sh` hands to every session `run_session`
# launches (each replay step, each review view, each `rank` session) through
# `--settings`, with that session's clone or view and its own temp directory
# as its two arguments:
#
#   compare-confine.sh <root> <tmp>  (the payload on stdin, as Claude Code sends it)
#
# Those sessions run in the bypass permission mode, and a working directory
# confines nothing. The same `--settings` turns on Claude Code's OS-level Bash
# sandbox with writes allowed only in <root> and <tmp>, the two paths its
# `allowWrite` names, byte for byte, so the two halves of the confinement allow
# the same places: a scratch write the sandbox allows is never a denial here.
# <tmp> is the directory compare.sh makes for that one session, outside every
# checkout, and names as the session's TMPDIR and CLAUDE_CODE_TMPDIR. Any other
# temp directory (another session's, a bare /tmp path, Claude Code's shared
# per-uid one) is outside both, and refused. Given <root> alone, it allows
# <root> alone.
# The sandbox is what confines a shell write this scanner cannot read
# (`python3 -c`, a script, `git -C`), and it covers Bash alone. This hook is the
# only confinement of the file tools (`Edit`, `Write`, `NotebookEdit`), and a
# first line for the shell writes it recognises.
# It belongs to the harness alone: it is not registered in hooks/hooks.json and
# the live loop never runs it.
#
# THE RULE. A write whose target does not physically resolve inside <root> or
# <tmp> is refused (exit 2, the reason on stderr, which Claude Code shows the model and
# records as a denied call). Everything else is allowed (exit 0, no output).
#   - `Edit`, `MultiEdit`, `Write`: `tool_input.file_path`; `NotebookEdit`:
#     `tool_input.notebook_path`. These tools take a path as it stands, so a
#     glob, bracket or paren character in it (`app/[id]/page.tsx`) is only a
#     character; a `$` or backtick is still refused. Every other tool but
#     `Bash` is allowed: this hook judges writes, never reads.
#   - `Bash`: `tool_input.command`, reduced to the writes this scanner can
#     recognise: an output redirection (`>`, `>>`, `>|`, `&>`, fd-numbered), and
#     the commands `tee`, `cp`, `mv`, `install`, `ln`, `link`, `rsync`, `dd of=`,
#     `truncate`, `sed -i`, `rm`, `rmdir`, `touch`, `mkdir`, `unlink`, each read
#     for the paths it writes. A hard link's source is judged as a target too
#     (`ln` without `-s`/`--symbolic`, `cp -l`/`--link`, `link`, and BSD
#     `install -l <flags>` whatever its flags), as `mv`'s is, and
#     `rsync --link-dest` is refused: a hard link gives the source a second
#     name, and a write through either lands on both. A symbolic link (`ln -s`)
#     to a place outside <root> is allowed, since it writes nothing there; a
#     write through it is judged where it physically lands, and refused.
#   - A DIRECTORY DESTINATION. `cp`, `install`, `ln`, `mv` and `rsync` into a
#     directory (a last operand ending in `/` or naming an existing directory,
#     or `-t`/`--target-directory`) write `<dest>/<basename of each source>`,
#     so that name is judged too, where a symlink or a hard link already
#     sitting there would carry the write. A recursive copy (`cp -r`/`-R`/`-a`,
#     `rsync -r`/`-a`) into an existing directory writes below those names,
#     so it is refused when `find` finds any symlink, or any file with another
#     hard link, under `<dest>/<basename>` (under <dest> itself for a source
#     ending in `/` or naming `.`), or cannot search there.
#     A command with none of these is allowed, whatever it reads.
#   - NOT RECOGNISED, and this hook does not claim to see them: a write a
#     command makes some other way (a script it runs, `git -C`, an
#     interpreter's own file calls; the Bash sandbox is what confines these),
#     and any MCP tool (`mcp__*`). The `--settings` matcher compare.sh gives
#     this hook names only the write tools and `Bash`, so an MCP call never
#     reaches it; a harness session loaded with `--plugin-dir` has the
#     harness's `.mcp.json` servers (`git`, `filesystem`, `github`), whose own
#     scopes are all that confine them, since the sandbox covers Bash alone.
# A target is resolved against the payload's `cwd` when relative, then placed
# physically: its nearest existing ancestor through `pwd -P` and an existing
# symlink leaf followed, so neither a symlinked directory nor a symlink file
# can carry a write out of <root>. An existing file with more than one hard
# link is refused wherever it is, since no path names where its other name
# lies (a hard link made between two files inside <root> therefore makes
# both unwritable for the rest of the session). Inside <root>, the paths
# Claude Code loads configuration and code from at the root are refused too:
# `.claude` itself, its `settings.json`, `settings.local.json` and
# `scheduled_tasks.json`, its `skills`, `agents`, `commands`, `hooks` and
# `workflows` trees, and `.mcp.json`. A write there could add a hook or an
# MCP server that runs outside the sandbox, or widen the sandbox's paths, in
# this session or the next step's in the same clone; the sandbox protects the
# same paths from Bash, but the bypass mode lets the file tools write them.
#
# ASSUMED, NOT VERIFIED HERE: that the payload's `cwd` is the directory the
# `Bash` tool's shell is in when the command runs. Claude Code keeps that
# shell's directory from one `Bash` call to the next, so a `cd` in one call
# (not a write, so allowed) moves the relative targets of the next; if the
# payload then named the session's start directory instead, a relative write
# would be judged in the wrong place. Only a live session can show it: one
# `Bash` call that runs `cd` out of <root>, then a second that writes to a
# relative path; it holds when that file is not written outside <root>.
#
# FAILING CLOSED. Each of these is refused, never guessed at:
#   - a target holding an unexpanded variable (`$`), a command substitution, a
#     glob or bracket character, or a quoted region this scanner cannot read
#     literally;
#   - a target with any `..` segment, or starting with `~`;
#   - a relative target when the payload names no absolute `cwd`, or when the
#     command changes directory anywhere but a single leading `cd <literal>`;
#   - a recognised write command whose targets cannot be picked out, and any
#     recognisable write beside a construct that can hide one (`$(`, backticks,
#     `eval`, `xargs`, `sh|bash|zsh -c`, process substitution); `find` with
#     `-exec`, `-delete` or a `-fprint` form is such a construct on its own;
#   - a payload that is not a JSON object, or no working JSON reader (`jq`,
#     else `python3`, each probed by running it);
#   - a <root> or <tmp> that is missing, relative or `/` (a <tmp> given but
#     unusable refuses every write, never falls back to <root> alone);
#   - anything that stops the decision before it completes: only an explicit
#     ALLOW from the decision exits 0.
#
# Portability: bash 3.2, awk, sed, grep; `jq` or `python3` for the payload.
# =============================================================================

REFUSE_PREFIX="compare-confine: refused"

# The decision runs in a subshell and prints one line, `ALLOW` or `REFUSE
# <reason>`. The caller exits 0 only on an exact `ALLOW`.
decide_refuse() { printf 'REFUSE %s\n' "$1"; exit 0; }

# --- the payload --------------------------------------------------------------

PARSER=""
probe_parser() {
  if printf '{"a":"b"}' | jq -e '.a == "b"' >/dev/null 2>&1; then PARSER=jq; return 0; fi
  if printf '{"a":"b"}' | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["a"] == "b" else 1)' >/dev/null 2>&1; then
    PARSER=python3; return 0
  fi
  return 1
}

# payload_is_object: 0 when the payload parses as a JSON object.
payload_is_object() {
  case "$PARSER" in
    jq) printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 ;;
    python3) printf '%s' "$PAYLOAD" | python3 -c 'import json,sys; sys.exit(0 if isinstance(json.load(sys.stdin), dict) else 1)' >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# field <dotted.path>: the string at that path, exactly (no trailing newline
# added); nothing when it is absent or not a string.
field() {
  case "$PARSER" in
    jq) printf '%s' "$PAYLOAD" | jq -j --arg k "$1" 'getpath($k | split(".")) | if type == "string" then . else empty end' 2>/dev/null ;;
    python3) printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
if isinstance(d, str):
    sys.stdout.write(d)' "$1" 2>/dev/null ;;
  esac
}

# --- placing a path physically ------------------------------------------------

# follow_leaf <abs>: an existing symlink leaf followed to what it names, one
# `readlink` hop at a time (at most 16). Nothing, return 1, when it cannot be.
follow_leaf() {
  local cur="$1" tgt hops=0
  while [ -L "$cur" ] && [ "$hops" -lt 16 ]; do
    tgt="$(readlink "$cur" 2>/dev/null)" || return 1
    [ -n "$tgt" ] || return 1
    case "$tgt" in
      /*) cur="$tgt" ;;
      *)  cur="${cur%/*}/${tgt}" ;;
    esac
    hops=$((hops + 1))
  done
  [ -L "$cur" ] && return 1
  case "$cur" in /*) ;; *) return 1 ;; esac
  printf '%s' "$cur"
}

# resolve_abs <abs>: the physical location of an absolute target: its nearest
# existing ancestor through `pwd -P`, plus the not-yet-existing tail. Nothing,
# return 1, when it cannot be placed.
resolve_abs() {
  local p="$1" dir tail phys
  if [ -L "$p" ]; then p="$(follow_leaf "$p")" || return 1; fi
  case "/$p/" in *'/../'*) return 1 ;; esac
  case "$p" in /*/*) dir="${p%/*}"; tail="${p##*/}" ;; /*) dir="/"; tail="${p#/}" ;; *) return 1 ;; esac
  [ -n "$dir" ] || dir="/"
  while [ ! -d "$dir" ]; do
    [ "$dir" = / ] && break
    tail="${dir##*/}/${tail}"; dir="${dir%/*}"; [ -n "$dir" ] || dir="/"
  done
  [ -d "$dir" ] || return 1
  phys="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  [ -n "$phys" ] || return 1
  if [ -n "$tail" ]; then printf '%s/%s' "${phys%/}" "$tail"; else printf '%s' "$phys"; fi
}

# link_count <abs>: the hard-link count of an existing non-directory, from
# `ls -ld` (POSIX, unlike `stat`'s flags). Nothing, return 1, when unreadable.
link_count() {
  local n
  n="$(ls -ld -- "$1" 2>/dev/null | awk 'NR == 1 { print $2 }')"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$n"
}

# judge <target> <base> [literal]: 0 when <target> lands inside ROOT. <base> is
# the directory a relative target is resolved against (empty: none is known).
# <literal> is 1 for a path a tool takes as it stands (Edit, Write,
# NotebookEdit), where a glob, bracket or paren character is just a character;
# a shell-derived target leaves it empty. Sets REASON on refusal.
REASON=""
judge() {
  local t="$1" base="$2" literal="${3:-}" abs phys links
  REASON=""
  if [ -z "$t" ]; then REASON="a write with no target"; return 1; fi
  case "$t" in
    *'$'*|*'`'*) REASON="a target this hook cannot resolve: $t"; return 1 ;;
  esac
  if [ "$literal" != 1 ]; then
    case "$t" in
      *'__Q__'*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'('*|*')'*|*'<'*|*'>'*)
        REASON="a target this hook cannot resolve: $t"; return 1 ;;
    esac
  fi
  case "$t" in
    '~'*) REASON="a home-directory target, outside the session's clone: $t"; return 1 ;;
  esac
  case "/$t/" in *'/../'*) REASON="a target with a '..' segment: $t"; return 1 ;; esac
  case "$t" in
    /*) abs="$t" ;;
    *)
      case "$base" in
        /*) abs="${base%/}/$t" ;;
        *) REASON="a relative target with no known working directory: $t"; return 1 ;;
      esac ;;
  esac
  if ! phys="$(resolve_abs "$abs")"; then
    REASON="a target that cannot be placed on disk: $t"; return 1
  fi
  # A trailing `/` (`mkdir .claude/`) names the same place.
  while [ "${phys%/}" != "$phys" ] && [ -n "${phys%/}" ]; do phys="${phys%/}"; done
  case "$phys" in
    "$ROOT"|"$ROOT"/*) ;;
    *)
      # The session's own temp directory, the second place the sandbox's
      # `allowWrite` names. Nothing in it is configuration a session loads, so
      # only the hard-link check below applies there.
      case "${TMPROOT:+x}:$phys" in
        x:"$TMPROOT"|x:"$TMPROOT"/*) ;;
        *) REASON="a write outside the session's clone ($ROOT)${TMPROOT:+ and its temp directory ($TMPROOT)}: $t"; return 1 ;;
      esac ;;
  esac
  # What Claude Code loads configuration and code from, at the root: a write
  # there could add a hook, an MCP server or a sandbox path that runs or
  # writes outside ROOT, in this session or the next one in the same clone.
  # The sandbox refuses these to Bash; the bypass mode lets the file tools
  # through, so this hook refuses them to every write it judges.
  case "$phys" in
    "$ROOT/.claude"|"$ROOT/.claude/settings.json"|"$ROOT/.claude/settings.local.json"|\
    "$ROOT/.claude/scheduled_tasks.json"|"$ROOT/.mcp.json"|\
    "$ROOT/.claude/skills"|"$ROOT/.claude/skills/"*|"$ROOT/.claude/agents"|"$ROOT/.claude/agents/"*|\
    "$ROOT/.claude/commands"|"$ROOT/.claude/commands/"*|"$ROOT/.claude/hooks"|"$ROOT/.claude/hooks/"*|\
    "$ROOT/.claude/workflows"|"$ROOT/.claude/workflows/"*)
      REASON="a write to the Claude Code configuration a session in this clone loads: $t"; return 1 ;;
  esac
  # A hard link places one file in two directories, and no path says where the
  # other name is, so an existing file with more than one link is refused even
  # inside ROOT: its other name may lie outside, and a write lands on both.
  if [ -e "$phys" ] && [ ! -d "$phys" ]; then
    if ! links="$(link_count "$phys")"; then
      REASON="a target whose hard-link count cannot be read: $t"; return 1
    fi
    if [ "$links" -gt 1 ]; then
      REASON="a file with another hard link, which may lie outside the session's clone: $t"; return 1
    fi
  fi
  return 0
}

# --- reading a shell command --------------------------------------------------

# drop_heredocs <cmd>: every heredoc body and its terminator line removed; the
# line that opens it is kept, and so is everything after the terminator.
drop_heredocs() {
  local cmd="$1" out='' line delim='' in_doc=0 strip=0 rest tag k ch check
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_doc" = 1 ]; then
      check="$line"
      if [ "$strip" = 1 ]; then
        while [ "${check:0:1}" = "$(printf '\t')" ]; do check="${check:1}"; done
      fi
      [ "$check" = "$delim" ] && in_doc=0
      continue
    fi
    out="${out}${line}"$'\n'
    case "$line" in
      *'<<<'*) ;;
      *'<<'*)
        rest="${line#*<<}"; strip=0
        case "$rest" in -*) strip=1; rest="${rest#-}" ;; esac
        while [ -n "$rest" ]; do
          case "${rest:0:1}" in ' '|"$(printf '\t')") rest="${rest:1}" ;; *) break ;; esac
        done
        tag="${rest#[\"\']}"; delim=""
        for ((k = 0; k < ${#tag}; k++)); do
          ch="${tag:$k:1}"
          case "$ch" in [A-Za-z0-9_]) delim="${delim}${ch}" ;; *) break ;; esac
        done
        [ -n "$delim" ] && in_doc=1
        ;;
    esac
  done <<< "$cmd"
  printf '%s' "${out%$'\n'}"
}

# sanitize <cmd>: heredoc bodies dropped, `#` comments dropped, and every quoted
# region replaced by its literal text when that text is a plain word (letters,
# digits and `._/@%+=:,-` only), else by the one word `__Q__`, which no target
# judgment accepts. A quoted `;`, `|` or `>` therefore never splits a command
# or reads as a redirection.
sanitize() {
  local cmd out='' i=0 n c q='' prev='' buf='' extra=''
  cmd="$(drop_heredocs "$1")"
  n=${#cmd}
  while [ "$i" -lt "$n" ]; do
    c="${cmd:$i:1}"
    if [ -n "$q" ]; then
      if [ "$q" = '"' ] && [ "$c" = '\' ]; then
        buf="${buf}${cmd:$((i + 1)):1}"; i=$((i + 2)); continue
      fi
      if [ "$c" = "$q" ]; then
        case "$buf" in
          ''|*[!A-Za-z0-9._/@%+=:,-]*) out="${out}__Q__" ;;
          *) out="${out}${buf}" ;;
        esac
        # A command substitution inside double quotes still runs: its text is
        # kept, as a command of its own, where the write checks can see it.
        if [ "$q" = '"' ]; then
          case "$buf" in *'$('*|*'`'*) extra="${extra}"$'\n'"${buf}" ;; esac
        fi
        q=''; buf=''; prev='x'
      else
        buf="${buf}${c}"
      fi
      i=$((i + 1)); continue
    fi
    case "$c" in
      "'"|'"') q="$c"; buf=''; i=$((i + 1)); continue ;;
      '\') out="${out}${c}${cmd:$((i + 1)):1}"; prev='x'; i=$((i + 2)); continue ;;
      '#')
        case "$prev" in
          ''|' '|$'\t'|$'\n'|';'|'&'|'|'|'(')
            while [ "$i" -lt "$n" ] && [ "${cmd:$i:1}" != $'\n' ]; do i=$((i + 1)); done
            continue ;;
        esac ;;
    esac
    out="${out}${c}"; prev="$c"; i=$((i + 1))
  done
  # An unterminated quote: what it held cannot be read.
  [ -n "$q" ] && out="${out}__Q__"
  printf '%s%s' "$out" "$extra"
}

# neutralize <sanitized>: redirections that name no file this hook judges
# removed: to /dev/null, /dev/stdout, /dev/stderr, /dev/tty and /dev/fd/N, and
# fd duplication (`2>&1`, `>&2`, `2>&-`).
neutralize() {
  printf '%s' "$1" \
    | sed -E 's#[0-9&]?(>>?|>\|)[[:space:]]*/dev/(null|stdout|stderr|tty|fd/[0-9]+)([^[:alnum:]/._-]|$)#\3#g' \
    | sed -E 's/[0-9]?>&[0-9-]+//g'
}

# write_like <neutralized>: 0 when anything in it looks like a write.
write_like() {
  printf '%s' "$1" | grep -Eq '>|(^|[^[:alnum:]_])(tee|cp|mv|dd|rsync|install|ln|truncate|rm|rmdir|touch|mkdir|unlink|link)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])sed[[:space:]].*-(i|-in-place)|(^|[^[:alnum:]_])find[[:space:]].*-(exec|execdir|ok|okdir|delete|fprint|fprintf|fls)([^[:alnum:]]|$)'
}

# hides_writes <neutralized>: 0 when it holds a construct that can hide a write
# or a target from this scanner.
hides_writes() {
  case "$1" in *'$('*|*'`'*|*'<('*|*'>('*) return 0 ;; esac
  printf '%s' "$1" | grep -Eq '(^|[^[:alnum:]_])(eval|xargs)([^[:alnum:]_]|$)' && return 0
  printf '%s' "$1" | grep -Eq '(^|[^[:alnum:]_])(sh|bash|zsh|dash|ksh)[[:space:]]+(-[[:alnum:]]*[[:space:]]+)*-[[:alnum:]]*c' && return 0
  printf '%s' "$1" | grep -Eq '(^|[^[:alnum:]_])find[[:space:]].*-(exec|execdir|ok|okdir|delete|fprint|fprintf|fls)([^[:alnum:]]|$)' && return 0
  return 1
}

# segments <neutralized>: one simple command per line, split on newlines, `;`,
# `&&`, `||`, `|`, `&`, `(` and `)` (the sanitizer already removed every quoted
# one, and a `$(`, `<(` or `>(` beside a write has already been refused).
segments() {
  local s="$1"
  s="${s//'&&'/$'\n'}"; s="${s//'||'/$'\n'}"
  s="${s//;/$'\n'}"; s="${s//|/$'\n'}"; s="${s//&/$'\n'}"
  s="${s//(/$'\n'}"; s="${s//)/$'\n'}"
  printf '%s\n' "$s"
}

# words_of <segment>: the segment's words with every redirection (and a bare
# operator's following word) dropped, and the words that only prefix a command
# (`(`, `{`, `!`, shell keywords, `command`, `exec`, `env`, `nohup`, `time`,
# `sudo` and `VAR=value` assignments) removed from the front. Sets WORDS.
WORDS=()
words_of() {
  local -a raw
  local w skip=0 lead=1
  read -ra raw <<< "$1"
  WORDS=()
  for w in ${raw[@]+"${raw[@]}"}; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$w" in
      '>'|'>>'|'>|'|'<'|'<<'|'<<-'|[0-9]'>'|[0-9]'>>'|[0-9]'>|'|[0-9]'<') skip=1; continue ;;
      '>'*|'<'*|[0-9]'>'*|[0-9]'<'*) continue ;;
    esac
    if [ "$lead" = 1 ]; then
      while :; do
        case "$w" in
          '('*|'{'*|'!'*) w="${w#?}" ;;
          *) break ;;
        esac
      done
      case "$w" in
        ''|then|do|else|elif|if|while|until|time|command|builtin|exec|env|nohup|sudo|'-'*) continue ;;
        [A-Za-z_]*=*) continue ;;
      esac
      lead=0
    fi
    WORDS+=("$w")
  done
}

# redirect_targets <segment>: every output redirection's target, one per line.
redirect_targets() {
  printf '%s' "$1" \
    | grep -oE '[0-9&]?(>{1,2}|>\|)[[:space:]]*[^[:space:];&|]*' \
    | sed -E 's/^[0-9&]?(>{1,2}|>\|)[[:space:]]*//' \
    | while IFS= read -r t; do printf '%s\n' "${t:-__EMPTY__}"; done
}

# dir_dest <dest>: 0 when <dest> names a directory a copy writes into: it ends
# in `/`, or it is an existing directory, placed against `base` (decide_bash's)
# when relative. A relative <dest> with no absolute `base` counts as one, so the
# names written into it are emitted and then refused as relative targets.
dir_dest() {
  local d="$1"
  case "$d" in */) return 0 ;; esac
  case "$d" in
    /*) ;;
    *) case "${base:-}" in /*) d="${base%/}/$d" ;; *) return 0 ;; esac ;;
  esac
  [ -d "$d" ]
}

# into_dir <recursive> <dest> <source>...: the names a copy into the directory
# <dest> writes, one per line: `<dest>/<basename of source>` for each source,
# which judge then places (an existing symlink there followed, an existing hard
# link refused). For a recursive copy, also `__TREE__<path>` for each tree the
# copy writes below: `<dest>/<basename>`, and <dest> itself for a source ending
# in `/` or naming `.`, whose contents land there directly.
into_dir() {
  local rec="$1" dest="${2%/}" s b
  shift 2
  [ -n "$dest" ] || dest="/"
  for s in "$@"; do
    b="${s%/}"; b="${b##*/}"
    [ -n "$b" ] || b="__NONE__"
    printf '%s/%s\n' "${dest%/}" "$b"
    if [ "$rec" = 1 ]; then
      printf '__TREE__%s/%s\n' "${dest%/}" "$b"
      case "$s" in */|.|*/.) printf '__TREE__%s\n' "$dest" ;; esac
    fi
  done
}

# tree_ok <path>: 0 when the existing directory tree a recursive copy writes
# into holds no symbolic link and no file with another hard link, since a copy
# writes through either to wherever it leads; 0 too when <path> is not an
# existing directory (the copy creates it; <path> itself is judged as a
# target). Placed against `base` (decide_bash's) when relative, and refused
# when it cannot be, or cannot be searched. Sets REASON on refusal.
tree_ok() {
  local p="$1" abs found
  REASON=""
  case "$p" in
    /*) abs="$p" ;;
    *)
      case "${base:-}:${relok:-1}" in
        /*:1) abs="${base%/}/$p" ;;
        *) REASON="a recursive copy into a directory this hook cannot place: $p"; return 1 ;;
      esac ;;
  esac
  [ -d "$abs" ] || return 0
  if ! found="$(find "${abs%/}/" \( -type l -o \( ! -type d -links +1 \) \) -print 2>&1)"; then
    REASON="a recursive copy into a directory this hook cannot search: $p"; return 1
  fi
  if [ -n "$found" ]; then
    REASON="a recursive copy into a directory holding a symbolic or hard link, which can carry a write out of the session's clone: $p"; return 1
  fi
  return 0
}

# command_targets: the targets the command in WORDS writes, one per line; the
# one line `__NONE__` when it is a write command whose targets cannot be picked
# out, and `__TREE__<path>` for a directory tree a recursive copy writes into.
# Nothing when WORDS is not a write command this hook recognises.
command_targets() {
  [ "${#WORDS[@]}" -gt 0 ] || return 0
  local cmd="${WORDS[0]##*/}" k w tdir='' seen=0 n=${#WORDS[@]} out=''
  cmd="${cmd#\\}"
  case "$cmd" in
    tee|rm|rmdir|unlink|link)
      for ((k = 1; k < n; k++)); do
        case "${WORDS[$k]}" in -*) ;; *) out="${out}${WORDS[$k]}"$'\n' ;; esac
      done
      [ "$cmd" = tee ] || [ -n "$out" ] || out=$'__NONE__\n' ;;
    touch|mkdir)
      for ((k = 1; k < n; k++)); do
        w="${WORDS[$k]}"
        case "$cmd:$w" in
          touch:-r|touch:-t|touch:-d|mkdir:-m) k=$((k + 1)) ;;
          *:-*) ;;
          *) out="${out}${w}"$'\n' ;;
        esac
      done
      [ -n "$out" ] || out=$'__NONE__\n' ;;
    cp|install|ln|mv)
      # A hard link (`ln` without -s, `cp -l`, BSD `install -l <flags>`, any
      # flags: `h` is hard and `m` may be) gives its source a second name at
      # the destination, so a later write there lands on the source too.
      local hard=0 rec=0 idir=0 dest=''
      local -a ops=()
      [ "$cmd" = ln ] && hard=1
      for ((k = 1; k < n; k++)); do
        w="${WORDS[$k]}"
        case "$w" in
          -t) tdir="${WORDS[$((k + 1))]:-__NONE__}"; k=$((k + 1)); continue ;;
          --target-directory=*) tdir="${w#--target-directory=}"; continue ;;
          --) continue ;;
        esac
        case "$cmd:$w" in
          ln:--symbolic) hard=0 ;;
          cp:--link) hard=1 ;;
          cp:--recursive|cp:--archive) rec=1 ;;
          *:--*) ;;
          ln:-*s*) hard=0 ;;
          install:-d) idir=1 ;;
          install:-*l)
            # `-l <flags>`: the flags word is not an operand.
            hard=1; k=$((k + 1)) ;;
          install:-*l*) hard=1 ;;
          cp:-*)
            case "$w" in -*l*) hard=1 ;; esac
            case "$w" in -*[rRa]*) rec=1 ;; esac ;;
          *:-*) ;;
          *) ops+=("$w") ;;
        esac
      done
      if [ -n "$tdir" ]; then out="${tdir}"$'\n'; fi
      if [ "$cmd" = mv ] || [ "$hard" = 1 ] || [ "$idir" = 1 ]; then
        # mv removes each source it renames; a hard link's source gains a name
        # at the destination; install -d creates each argument. Every operand
        # is judged.
        for w in ${ops[@]+"${ops[@]}"}; do out="${out}${w}"$'\n'; done
        # `ln <source>` alone makes its link in the working directory.
        if [ "$cmd" = ln ] && [ -z "$tdir" ] && [ "${#ops[@]}" -eq 1 ]; then
          w="${ops[0]%/}"; out="${out}${w##*/}"$'\n'
        fi
      elif [ -z "$tdir" ]; then
        if [ "${#ops[@]}" -ge 2 ]; then out="${ops[$((${#ops[@]} - 1))]}"$'\n'; else out=$'__NONE__\n'; fi
      fi
      # Into a directory, a copy writes <dest>/<basename of each source>, and
      # that name, not <dest>, is where a link there would carry the write.
      if [ "$idir" = 0 ]; then
        if [ -n "$tdir" ]; then
          dest="$tdir"
        elif [ "${#ops[@]}" -ge 2 ]; then
          dest="${ops[$((${#ops[@]} - 1))]}"; unset "ops[$((${#ops[@]} - 1))]"
        fi
        if [ -n "$dest" ] && [ "$dest" != __NONE__ ] && [ "${#ops[@]}" -gt 0 ] && dir_dest "$dest"; then
          out="${out}$(into_dir "$rec" "$dest" "${ops[@]}")"$'\n'
        fi
      fi ;;
    rsync)
      local rec=0 dest=''
      local -a ops=()
      for ((k = 1; k < n; k++)); do
        w="${WORDS[$k]}"
        case "$w" in
          # --link-dest hard-links files from a directory named relative to
          # the destination; it is not followed, so the call is refused.
          --link-dest*) printf '__NONE__\n'; return 0 ;;
          --recursive|--archive) rec=1 ;;
          --*) ;;
          -*) case "$w" in -*[ra]*) rec=1 ;; esac ;;
          *) ops+=("$w") ;;
        esac
      done
      w="${WORDS[$((n - 1))]}"
      case "$w" in -*|*:*) printf '__NONE__\n'; return 0 ;; esac
      [ "$n" -gt 2 ] && [ "${#ops[@]}" -ge 2 ] || { printf '__NONE__\n'; return 0; }
      out="${w}"$'\n'
      unset "ops[$((${#ops[@]} - 1))]"
      if dir_dest "$w"; then
        out="${out}$(into_dir "$rec" "$w" "${ops[@]}")"$'\n'
      fi ;;
    dd)
      for ((k = 1; k < n; k++)); do
        case "${WORDS[$k]}" in of=*) out="${out}${WORDS[$k]#of=}"$'\n' ;; esac
      done ;;
    truncate)
      for ((k = 1; k < n; k++)); do
        case "${WORDS[$k]}" in
          -s|-r) k=$((k + 1)) ;;
          -*) ;;
          *) out="${out}${WORDS[$k]}"$'\n' ;;
        esac
      done
      [ -n "$out" ] || out=$'__NONE__\n' ;;
    sed)
      local inplace=0
      for ((k = 1; k < n; k++)); do
        case "${WORDS[$k]}" in -i*|--in-place*|-[!-]*i*) inplace=1 ;; esac
      done
      if [ "$inplace" = 1 ]; then
        local expr=0
        for ((k = 1; k < n; k++)); do
          w="${WORDS[$k]}"
          case "$w" in
            -e|-f|--expression|--file) expr=1; k=$((k + 1)) ;;
            -*) ;;
            *) if [ "$expr" = 0 ]; then expr=1; else out="${out}${w}"$'\n'; fi ;;
          esac
        done
        [ -n "$out" ] || out=$'__NONE__\n'
      fi ;;
  esac
  printf '%s' "$out"
}

# --- the decision -------------------------------------------------------------

decide_bash() {
  local cmd="$1" san neutral seg t base="$CWD" ncd=0 first=1 cdarg='' relok=1 segs
  san="$(sanitize "$cmd")"
  neutral="$(neutralize "$san")"
  write_like "$neutral" || { printf 'ALLOW\n'; exit 0; }
  hides_writes "$neutral" && decide_refuse "a write beside a construct that can hide its target (command substitution, eval, xargs, sh -c, process substitution or find -exec)"
  segs="$(segments "$neutral")"

  # A directory change moves every relative target. Only a single leading
  # `cd <literal>` is followed; any other makes relative targets unjudgeable.
  while IFS= read -r seg; do
    [ -n "${seg//[[:space:]]/}" ] || continue
    words_of "$seg"
    case "${WORDS[0]:-}" in
      cd|pushd|popd)
        ncd=$((ncd + 1))
        if [ "$first" = 1 ] && [ "${#WORDS[@]}" -eq 2 ]; then cdarg="${WORDS[1]}"; fi ;;
    esac
    first=0
  done <<< "$segs"
  # The directory followed need not be inside ROOT: every target is still
  # judged on where it physically lands.
  if [ "$ncd" -gt 0 ]; then
    relok=0
    # A `cd` inside a subshell does not outlive it, so with any `(` present
    # the directory a later target is relative to is not the one followed.
    if [ "$ncd" -eq 1 ] && [ -n "$cdarg" ] && [ "${neutral#*(}" = "$neutral" ]; then
      case "$cdarg" in
        *'$'*|*'`'*|*'__Q__'*|'~'*|-*|*'*'*|*'?'*|*'['*) ;;
        *)
          case "/$cdarg/" in
            *'/../'*) ;;
            *)
              case "$cdarg" in
                /*) base="$cdarg"; relok=1 ;;
                *) case "$CWD" in /*) base="${CWD%/}/$cdarg"; relok=1 ;; esac ;;
              esac ;;
          esac ;;
      esac
    fi
  fi

  while IFS= read -r seg; do
    [ -n "${seg//[[:space:]]/}" ] || continue
    words_of "$seg"
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      case "$t" in
        __NONE__) decide_refuse "a write whose target this hook cannot pick out: ${seg}" ;;
        __EMPTY__) decide_refuse "a redirection with no readable target: ${seg}" ;;
        __TREE__*) tree_ok "${t#__TREE__}" || decide_refuse "$REASON"; continue ;;
      esac
      if [ "$relok" = 0 ]; then
        case "$t" in /*) ;; *) decide_refuse "a relative target after a change of directory this hook cannot follow: $t" ;; esac
      fi
      judge "$t" "$base" || decide_refuse "$REASON"
    done < <(redirect_targets "$seg"; command_targets)
  done <<< "$segs"
  printf 'ALLOW\n'
  exit 0
}

decide() {
  [ -n "$ROOT" ] || decide_refuse "the confinement root is unusable: ${ROOT_ARG:-<none>}"
  probe_parser || decide_refuse "no working JSON reader (jq or python3) to read the tool call"
  payload_is_object || decide_refuse "the tool call's payload is not a JSON object"
  local tool target
  tool="$(field tool_name)"
  CWD="$(field cwd)"
  case "$tool" in
    Edit|MultiEdit|Write)
      target="$(field tool_input.file_path)"
      judge "$target" "$CWD" 1 || decide_refuse "$REASON" ;;
    NotebookEdit)
      target="$(field tool_input.notebook_path)"
      judge "$target" "$CWD" 1 || decide_refuse "$REASON" ;;
    Bash)
      decide_bash "$(field tool_input.command)" ;;
    '') decide_refuse "the tool call names no tool" ;;
  esac
  printf 'ALLOW\n'
  exit 0
}

# phys_root <arg>: <arg> placed physically, when it is an absolute, existing
# directory other than `/`; nothing otherwise.
phys_root() {
  local r=""
  case "$1" in
    /*) r="$(cd "$1" 2>/dev/null && pwd -P)" || r="" ;;
  esac
  [ "$r" = / ] && r=""
  printf '%s' "$r"
}

ROOT_ARG="${1:-}"
TMP_ARG="${2:-}"
ROOT=""
TMPROOT=""
if [ $# -eq 1 ] || [ $# -eq 2 ]; then
  ROOT="$(phys_root "$ROOT_ARG")"
  if [ $# -eq 2 ]; then
    TMPROOT="$(phys_root "$TMP_ARG")"
    # A temp directory named but unusable leaves no root at all: every write is
    # refused, as for an unusable <root>.
    if [ -z "$TMPROOT" ]; then ROOT=""; ROOT_ARG="$ROOT_ARG (temp directory: ${TMP_ARG:-<none>})"; fi
  fi
fi
PAYLOAD="$(cat)"
CWD=""

VERDICT="$(decide 2>/dev/null | tail -n 1)"
if [ "$VERDICT" = ALLOW ]; then exit 0; fi
WHERE="${ROOT:-its clone}${TMPROOT:+ and its temp directory $TMPROOT}"
case "$VERDICT" in
  'REFUSE '*) printf '%s: %s. This session may write only inside %s.\n' "$REFUSE_PREFIX" "${VERDICT#REFUSE }" "$WHERE" >&2 ;;
  *) printf '%s: the confinement check did not complete, so the call is refused. This session may write only inside %s.\n' "$REFUSE_PREFIX" "$WHERE" >&2 ;;
esac
exit 2
