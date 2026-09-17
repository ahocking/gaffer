#!/usr/bin/env bash
# =============================================================================
# guard.sh — approval guardrail (PreToolUse hook)
# =============================================================================
# Runs before Bash / Edit / Write / MultiEdit / NotebookEdit tool calls.
# Reads the tool name + input as JSON on stdin. If the call matches a
# high-risk category it DENIES the call (exit 2) and prints to stderr WHY, so a
# human must explicitly approve. Otherwise it allows the call (exit 0).
#
# Exit codes (Claude Code PreToolUse convention):
#   0 -> allow the tool call
#   0 + JSON {"hookSpecificOutput":{...,"permissionDecision":"ask"}} on stdout ->
#        defer to Claude Code's native approval prompt (the routine-but-notable
#        tier: dependency installs, migrations, deploys — a one-click yes/no
#        instead of a dead end).
#   2 -> block the tool call; stderr is shown and fed back to the model
#
# Three tiers of Bash policy (see the pattern blocks below):
#   READ-ONLY  -> allowed immediately, before any denylist runs, so searching
#                 FOR a risky string is never mistaken for RUNNING it.
#   ASK        -> routine-but-notable; returns permissionDecision=ask.
#   HARD DENY  -> irreversible / never-appropriate; exit 2 at every level.
#
# Path writes (Edit/Write and shell writes) are TWO tiers (ADR 0014):
#   SECRET  -> HARD DENY. Irreversible exposure (.env, keys, secret stores).
#   REVIEW  -> ASK. Reversible, review-worthy code/config (auth code, CI/deploy).
#
# Design notes:
#   - No jq dependency required: uses jq if present, else python3/python, else a
#     best-effort grep/sed fallback. Matching is done on the extracted command
#     / file path so it works even without a JSON parser. Parsers are probed by
#     EXECUTION, never by `command -v` (see detect_json_parser).
#   - Fails CLOSED when it cannot READ its input. This hook is registered only
#     for Bash/Edit/Write/MultiEdit/NotebookEdit, and every one of those calls
#     carries a target — a command or a path. So an empty extraction is never a
#     legitimate absence; it means the payload could not be read, and a control
#     that cannot read its input must deny (exit 2), not allow. The one
#     remaining allow-on-ignorance is a completely EMPTY stdin, which is not a
#     tool call at all. Risk matching also fails CLOSED: if a pattern matches,
#     we always deny.
#   - `set -euo pipefail` is in force, so no helper may return non-zero on a
#     merely-absent value: a non-zero return from a `VAR="$(helper …)"`
#     assignment kills the hook, and Claude Code treats any non-zero-other-than-2
#     exit as a NON-BLOCKING error — i.e. another silent fail-open. json_field
#     and read_autonomy_file therefore always return 0.
#   - Coverage is defense-in-depth, not a sandbox: it closes the obvious holes
#     (writes to sensitive paths via the shell, git flags before the subcommand)
#     but a determined shell can still evade it. Treat it as a backstop.
#   - To EXTEND coverage, edit the clearly-marked pattern block below, OR — for
#     per-repo rules without editing the plugin — drop extra regexes in the
#     consumer repo under `.agents/guard-extra-bash` and `.agents/guard-extra-paths`
#     (one regex per line, `#` comments allowed). Those are loaded and appended
#     to the arrays below at runtime, so declared per-project risk becomes
#     ENFORCED risk, not just voluntarily-honored risk.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# RISK PATTERNS  — edit here to tune the guardrail. Extended regex (grep -E).
# -----------------------------------------------------------------------------

# Flexible `git` prefix: matches `git` while tolerating `-c <cfg>` / `-C <path>`
# flags between `git` and the subcommand, so `git -C . commit` and
# `git -c user.name=x commit` cannot slip past the version-control rules.
GIT_PREFIX='(^|[^[:alnum:]])git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+'

# (1) HARD-DENY Bash commands (exit 2). Irreversible or never-appropriate:
#     history destruction, recursive delete, raw-device writes. Denied at EVERY
#     autonomy level; never downgraded to a prompt. Per-repo `.agents/guard-extra-bash`
#     patterns are appended here (declared risk -> ENFORCED as a hard floor).
#     NOTE: `git commit`/`merge`/`rebase`/`push` are deliberately NOT here — each is
#     a SOFT gate handled by its check_*_policy below (autonomy-aware). commit is
#     delegable >= supervised; merge/rebase/push are delegable only at full-autonomy
#     and only onto NON-main targets.
DENY_BASH_PATTERNS=(
  # --- version control: history-destruction (hard-deny at EVERY level) ---
  "${GIT_PREFIX}.*--force([^[:alnum:]]|\$)"
  "${GIT_PREFIX}reset[[:space:]]+--hard([^[:alnum:]]|\$)"
  "${GIT_PREFIX}clean[[:space:]]+.*-[[:alnum:]]*f"
  # --- destructive filesystem ops ---
  '(^|[^[:alnum:]])rm[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*[fF]|-[[:alnum:]]*[fF][[:alnum:]]*[rR])'
  '(^|[^[:alnum:]])rm[[:space:]]+-[rRfF]'
  '(^|[^[:alnum:]])git[[:space:]]+clean[[:space:]]+.*-[[:alnum:]]*f'
  '(^|[^[:alnum:]])(find)[[:space:]]+.*-delete'
  '>[[:space:]]*/dev/sd'
  'truncate[[:space:]]+-s[[:space:]]*0'
)

# (1b) ASK Bash commands. Routine in day-to-day dev but notable enough to confirm.
#      NOT hard-denied: the hook returns permissionDecision=ask so Claude Code
#      surfaces a one-click approval instead of a dead end. If you want one of
#      these to hard-deny in a specific repo, add it to `.agents/guard-extra-bash`
#      (which is appended to DENY_BASH_PATTERNS above).
ASK_BASH_PATTERNS=(
  # --- database migrations ---
  'dotnet[[:space:]]+ef[[:space:]]+database[[:space:]]+update'
  'dotnet[[:space:]]+ef[[:space:]]+migrations[[:space:]]+(add|remove)'
  '(^|[^[:alnum:]])flyway([^[:alnum:]]|$)'
  'alembic[[:space:]]+(upgrade|downgrade)'
  'prisma[[:space:]]+migrate'
  'sequelize[[:space:]]+db:migrate'
  # --- dependency installs / upgrades ---
  '(^|[^[:alnum:]])(npm|pnpm|yarn)[[:space:]]+(install|add|up|upgrade|update)([^[:alnum:]]|$)'
  'dotnet[[:space:]]+add[[:space:]]+package'
  'dotnet[[:space:]]+(restore|tool[[:space:]]+install)'
  '(^|[^[:alnum:]])nuget[[:space:]]+(install|restore)'
  '(^|[^[:alnum:]])pip3?[[:space:]]+install'
  '(^|[^[:alnum:]])poetry[[:space:]]+(add|install|update)'
  '(^|[^[:alnum:]])brew[[:space:]]+(install|upgrade)'
  # --- deploys / infra ---
  '(^|[^[:alnum:]])docker[[:space:]]+push'
  '(^|[^[:alnum:]])docker[[:space:]]+compose[[:space:]]+.*up'
  '(^|[^[:alnum:]])kubectl[[:space:]]+(apply|delete|rollout)'
  '(^|[^[:alnum:]])helm[[:space:]]+(install|upgrade|uninstall)'
  '(^|[^[:alnum:]])terraform[[:space:]]+(apply|destroy)'
  '(^|[^[:alnum:]])(flyctl|fly)[[:space:]]+deploy'
  '(^|[^[:alnum:]])vercel[[:space:]]+(deploy|--prod)'
  # Anchor the verb to a whole word: the old `.*(deploy|delete|rm)` matched the
  # "rm" inside `cloudformation` / `--format` and the "delete" nowhere, so common
  # READ-ONLY reads (`aws cloudformation …`, `gcloud … --format=json`) were blocked.
  '(^|[^[:alnum:]])(aws|gcloud|az)[[:space:]]+.*(^|[^[:alnum:]])(deploy|delete|rm)([^[:alnum:]]|$)'
)

# (1c) READ-ONLY fast-path. A Bash command whose every pipeline segment leads with
#      one of these commands — and which contains no redirection / command
#      substitution / statement separator that could hide a mutation — is allowed
#      immediately, before any denylist runs. This is why `rg "npm install"`,
#      `grep -rn "pip install" .` and `git log --grep="rm -rf"` are searches, not
#      denials. Purely additive: a command that is not clearly read-only simply
#      declines the fast-path and is evaluated exactly as before. `env`/`command`
#      (which can prefix any program) and in-place writers (`sed -i`, `yq -i`,
#      `tee`, `cp`) are deliberately absent; `find` is handled specially so
#      `find … -delete`/`-exec` never fast-paths past the hard-deny rule.
READ_ONLY_CMDS='grep|egrep|fgrep|rg|ag|ack|ls|cat|bat|head|tail|wc|fd|stat|file|tree|pwd|echo|printf|which|type|printenv|date|whoami|id|hostname|uname|du|df|sort|uniq|cut|column|comm|join|tr|nl|fold|basename|dirname|realpath|readlink|jq|xxd|hexdump|od|strings|cksum|sha1sum|sha256sum|md5sum|diff|cmp|true|false|test|seq|tput'
READ_ONLY_GIT='status|log|diff|show|blame|rev-parse|rev-list|describe|shortlog|reflog|ls-files|ls-tree|cat-file|whatchanged|grep|for-each-ref|name-rev|merge-base'

# (1b) Shell constructs that WRITE/modify a file. When a Bash command matches one
#      of these AND also references a sensitive path (see below), it is denied —
#      this closes the hole where `cat > src/Auth/x.cs`, `sed -i … appsettings.json`,
#      or `cp … .env` would otherwise bypass the Edit/Write sensitive-path check.
BASH_WRITE_PATTERNS=(
  '>[[:space:]]*[^|&>[:space:]]'                          # output redirection to a file
  '>\|[[:space:]]*[^&>[:space:]]'                         # clobber redirect (>|) -- N5
  '(^|[^[:alnum:]])tee([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])sed[[:space:]]+.*-i'                   # in-place sed
  '(^|[^[:alnum:]])(cp|mv|dd|rsync|install|ln)([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])truncate([^[:alnum:]]|$)'
)

# (2) Sensitive file paths for Edit/Write/MultiEdit/NotebookEdit, and (via the
#     write-construct check above) for shell writes too. Matched (case-insensitive)
#     against the target file path / command. Split into TWO tiers (ADR 0014):
#
#       SECRET_PATH_PATTERNS  -> HARD DENY (exit 2). Exposure is irreversible — a
#                                leaked secret cannot be un-leaked. `.env`, key
#                                material, dedicated secret/credential stores.
#                                `.agents/guard-extra-paths` appends HERE, so
#                                per-repo declared risk (money, PHI, …) stays an
#                                enforced hard floor, exactly as before ADR 0014.
#       REVIEW_PATH_PATTERNS  -> ASK (one-click prompt). Review-worthy but fully
#                                REVERSIBLE: auth *code*, CI/deploy/infra config,
#                                appsettings. These are version-controlled, tested,
#                                and PR-reviewed; blocking the edit added no review,
#                                it just rerouted the change around the guard and
#                                trained the operator to click through real denials
#                                (ADR 0008's own "precision is a safety property"
#                                argument, carried to its conclusion in ADR 0014).
#                                `.agents/guard-extra-review` appends here.
#
#     These defaults are GENERIC software-development risk. DOMAIN-specific risk
#     (money movement / banking / Plaid in a financial app, PHI in a health app,
#     grading in an LMS) is NOT baked in here — it lives in the consumer repo via
#     `.agents/guard-extra-paths` (hard floor) / `.agents/guard-extra-review` (ask).
#     Scope those per-repo patterns to real module paths, not bare keywords, so
#     generic words like "transfer"/"balance"/"portfolio" don't false-positive.
# Auth path rules use a TWO-TIER vocabulary so the danger floor fires on real
# auth code without tripping on overloaded words (ADR 0008). STRONG terms are
# auth-specific enough to gate a file or directory on their own. WEAK terms
# (identity/session/token/policy/permission) are heavily overloaded — scenario
# identity, HTTP/game/terminal sessions, lexer/design tokens, resilience
# policies, filesystem permissions — so they gate ONLY when the same filename
# also carries an auth QUALIFIER (identity-provider, session-token, …). The
# `auth` stem is bounded ([^[:alnum:]] after it) so it never matches
# `author`/`authors`/`authoring`. A repo that genuinely uses a bare
# `identity/`/`session/` dir for auth re-adds it via `.agents/guard-extra-paths`.
_AUTH_EXT='(cs|ts|tsx|js|jsx|py|go|rb|json|ya?ml)'
_AUTH_STRONG='(auth(entication|orization|n|z)?|oauth2?|oidc|jwt|rbac|sso|login|logout|signin|credentials?)'
_AUTH_WEAK='(identity|sessions?|tokens?|policy|policies|permissions?)'
_AUTH_QUAL='(auth(entication|orization|n|z)?|oauth2?|oidc|jwt|rbac|sso|login|logout|signin|providers?|cookies?|claims?|principals?|bearer|csrf|refresh|tickets?|credentials?|tokens?)'

# (2a) SECRET tier — HARD DENY (exit 2), every autonomy level. Irreversible
#      exposure only. `.agents/guard-extra-paths` is appended here at runtime.
SECRET_PATH_PATTERNS=(
  # --- secrets / credentials / env / key material ---
  '(^|/)\.env(\.|$)'
  '(^|/)(secrets?|credentials?|vault)([^/]*)?/'
  '(secret|credential|apikey|api-key|password|private-?key)[^/]*\.(json|ya?ml|env|txt|pem|key)$'
  '\.(pem|key|pfx|p12)$'
)

# (2b) REVIEW tier — ASK (one-click prompt). Reversible, review-worthy source and
#      config. `.agents/guard-extra-review` is appended here at runtime.
REVIEW_PATH_PATTERNS=(
  # --- auth / authz code (two-tier vocab; see the fragment comment above) ---
  # STRONG term as a directory segment, but ONLY gating source-code files under it
  # (ADR 0014): `src/auth/middleware.ts` asks; `docs/auth/overview.md` does not.
  # `[^[:space:]]*` spans nested dirs (auth/providers/google.ts) without crossing a
  # command-token boundary when this pattern is reused against a shell command.
  "(^|/)${_AUTH_STRONG}([^[:alnum:]/][^/]*)?/[^[:space:]]*\.${_AUTH_EXT}\$"
  # STRONG term as a filename (fires standalone): jwt.ts, auth-service.ts, login.tsx.
  "(^|/)${_AUTH_STRONG}([^[:alnum:]/][^/]*)?\.${_AUTH_EXT}\$"
  # WEAK (overloaded) term only when an auth QUALIFIER co-occurs in the same
  # basename, in either order (identity-provider, session-token, token-provider).
  "(^|/)([^/]*[^[:alnum:]])?${_AUTH_WEAK}[^[:alnum:]][^/]*[^[:alnum:]]?${_AUTH_QUAL}([^[:alnum:]][^/]*)?\.${_AUTH_EXT}\$"
  "(^|/)([^/]*[^[:alnum:]])?${_AUTH_QUAL}[^[:alnum:]][^/]*[^[:alnum:]]?${_AUTH_WEAK}([^[:alnum:]][^/]*)?\.${_AUTH_EXT}\$"
  # --- app config (not a dedicated secret store; real secrets there hit SECRET) ---
  'appsettings(\.[^/]*)?\.json$'
  # --- CI / deploy / infra config ---
  '(^|/)\.github/workflows/'
  '(^|/)(Dockerfile|docker-compose(\.[^/]*)?\.ya?ml)$'
  '(^|/)(k8s|kubernetes|helm|charts|deploy|terraform|infra)([^/]*)?/'
  '\.(tf|tfvars)$'
  '(^|/)(\.gitlab-ci\.yml|azure-pipelines\.yml|Jenkinsfile|\.circleci/)'
)

# (3) Autonomy levels, lowest -> highest privilege (ADR 0004 / ADR 0006). The
#     active level is resolved at runtime below (env ORCH_AUTONOMY > .agents/autonomy
#     > default), then clamped DOWN to `autonomy_ceiling` in
#     .agents/project-overrides.yaml. It gates the SOFT git decisions only —
#     `git commit` (delegable >= supervised) and `git merge`/`rebase`/`push`
#     (delegable only at `full-autonomy`, and only onto NON-main targets). It does
#     NOT affect the other tiers: DENY_BASH_PATTERNS (history destruction, rm -rf,
#     raw-device writes) and SECRET-path writes hard-deny regardless of level;
#     ASK_BASH_PATTERNS (migrations, deps, deploys) and REVIEW-path writes (auth
#     code, CI/deploy config) always prompt regardless of level — UNLESS the repo
#     sets `bypass-ask-tier: true` in .agents/project-overrides.yaml, which skips
#     the ASK tier entirely (hard-deny floors and git soft gates still enforce).
#     See resolve_bypass_ask below. Default false; resolved restrictively (every
#     discovered config root must opt in).
ORCH_AUTONOMY_DEFAULT="interactive"
autonomy_rank() {   # interactive < supervised < autonomous < full-autonomy; unknown -> -1
  case "$1" in
    interactive)   echo 0 ;;
    supervised)    echo 1 ;;
    autonomous)    echo 2 ;;
    full-autonomy) echo 3 ;;
    *)             echo -1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Below this line is mechanism, not policy. Prefer editing the blocks above.
# -----------------------------------------------------------------------------

# `--selftest` answers the question the reported bug made unanswerable: is this
# guard actually reading payloads, or has it quietly degraded? It takes no stdin.
if [ "${1:-}" = "--selftest" ]; then
  INPUT=""
else
  INPUT="$(cat)"
fi

# --- JSON parsing -------------------------------------------------------------
# Which parser this invocation will use: "jq", "python3", "python", or "none".
# Probed ONCE, by EXECUTION rather than by `command -v`, because presence is not
# capability: on Windows `python3` routinely resolves to
# %LOCALAPPDATA%\Microsoft\WindowsApps\python3, an App Execution Alias that is on
# PATH, prints "Python was not found…" and exits 49. `command -v` calls that a
# hit, so the old code entered the python branch, got nothing, and fell through
# to the regex fallback — the first step of the reported fail-open.
JSON_PARSER=""
detect_json_parser() {
  [ -n "$JSON_PARSER" ] && return 0
  if printf '{"_p":"ok"}' | jq -er '._p' 2>/dev/null | grep -q '^ok$'; then
    JSON_PARSER="jq"
  elif printf '{"_p":"ok"}' | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["_p"])' 2>/dev/null | grep -q '^ok$'; then
    JSON_PARSER="python3"
  elif printf '{"_p":"ok"}' | python  -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["_p"])' 2>/dev/null | grep -q '^ok$'; then
    JSON_PARSER="python"
  else
    JSON_PARSER="none"
  fi
  return 0
}

# Decode JSON string escapes in a value pulled out by the regex fallback.
# WITHOUT this the fallback compares an ENCODED string against the patterns: a
# Windows path arrives as `C:\\Users\\me\\src\\Auth\\x.cs` (doubled separators)
# and cannot match a rule written for a single one, so EVERY path rule silently
# misses — the second step of the reported fail-open, and a nasty diagnostic
# inversion too (a hand-built payload with single backslashes is invalid JSON,
# matches fine, and makes the guard look healthy).
# Returns 1 — "this value cannot be trusted" — on any escape it cannot faithfully
# decode, so the caller denies rather than matching against a wrong string.
# Pure bash (no parser exists by definition here) and bash-3.2 safe.
_json_unescape() {
  local s="$1"
  case "$s" in
    *'\'*) ;;                         # has escapes -> decode below
    *) printf '%s' "$s"; return 0 ;;  # fast path: nothing to decode
  esac
  local out='' i=0 n=${#s} c d hex cp
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    if [ "$c" != '\' ]; then out="${out}${c}"; i=$((i + 1)); continue; fi
    i=$((i + 1)); d="${s:$i:1}"; i=$((i + 1))
    case "$d" in
      '\'|'"'|/) out="${out}${d}" ;;
      n) out="${out}"$'\n' ;;
      t) out="${out}"$'\t' ;;
      r) out="${out}"$'\r' ;;
      b) out="${out}"$'\b' ;;
      f) out="${out}"$'\f' ;;
      u)
        hex="${s:$i:4}"; i=$((i + 4))
        case "$hex" in
          [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
          *) return 1 ;;
        esac
        cp=$((16#$hex))
        case "$cp" in
          9)  out="${out}"$'\t' ;;
          10) out="${out}"$'\n' ;;
          13) out="${out}"$'\r' ;;
          *)
            # Only ASCII is faithfully decodable without a parser. Anything else
            # (NUL, non-ASCII) is UNTRUSTED -> tell the caller to deny.
            [ "$cp" -gt 0 ] && [ "$cp" -lt 128 ] || return 1
            out="${out}$(printf "\\$(printf '%03o' "$cp")")"
            ;;
        esac
        ;;
      *) return 1 ;;                  # not a legal JSON escape -> untrusted
    esac
  done
  printf '%s' "$out"
  return 0
}

# --- extract a JSON string field (jq -> python3 -> python -> grep/sed) --------
# ALWAYS returns 0. An absent key and an unreadable payload both yield the empty
# string; the caller decides what emptiness means for its tool (for every tool
# this hook guards, it means "deny"). Returning non-zero here used to kill the
# whole hook under `set -euo pipefail` — e.g. `SHELL_CWD="$(json_field "$INPUT"
# cwd)"` on a payload with no `cwd` exited 1, which Claude Code reports as a
# non-blocking error and the guard is bypassed. Verified: exit=1, guard inert.
json_field() {
  # $1 = raw json, $2..$n = key path (e.g. tool_input command)
  local raw="$1"; shift
  detect_json_parser
  case "$JSON_PARSER" in
    jq)
      local filter="." k
      for k in "$@"; do filter="${filter}[\"${k}\"]?"; done
      printf '%s' "$raw" | jq -r "${filter} // empty" 2>/dev/null || true
      return 0
      ;;
    python3|python)
      printf '%s' "$raw" | KEYS="$*" "$JSON_PARSER" -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in os.environ.get("KEYS","").split():
    if isinstance(d, dict) and k in d:
        d = d[k]
    else:
        sys.exit(0)
if isinstance(d, (str, int, float)):
    print(d)
' 2>/dev/null || true
      return 0
      ;;
  esac
  # Fallback: grab the last key in the path via grep/sed (shallow, best-effort),
  # then DECODE it — matching an encoded value against the patterns is the bug.
  local last="${!#}" enc
  enc="$(printf '%s' "$raw" \
    | grep -oE "\"${last}\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\"" \
    | head -n1 \
    | sed -E "s/^\"${last}\"[[:space:]]*:[[:space:]]*\"//; s/\"\$//" || true)"
  [ -n "$enc" ] || return 0
  _json_unescape "$enc" || return 0    # undecodable -> empty -> caller denies
  return 0
}

# Detect EAGERLY, in the main shell. json_field is always called as
# `VAR="$(json_field …)"`, i.e. in a subshell, so a JSON_PARSER memoized in
# there is discarded on return: every call re-probed (three spawns per
# invocation instead of one) and the parent never learned the answer, so
# deny_unreadable could only report "unknown". One probe here fixes both.
detect_json_parser

# --- selftest -----------------------------------------------------------------
# `hooks/guard.sh --selftest` — prove the guard can READ a payload. Feeds itself
# a canary Write whose path is a JSON-escaped Windows path (the exact shape that
# silently defeated the old regex fallback) and reports the parser in use.
# Exit 0 = the guard can read its input; exit 1 = it cannot, and would deny.
if [ -z "${INPUT}" ] && [ "${1:-}" = "--selftest" ]; then
  detect_json_parser
  _canary='{"tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":"C:\\Users\\me\\repo\\src\\Auth\\Login.cs"}}'
  _want='C:\Users\me\repo\src\Auth\Login.cs'
  _got_tool="$(json_field "$_canary" tool_name)"
  _got_path="$(json_field "$_canary" tool_input file_path)"
  echo "guard.sh selftest"
  echo "  json parser : ${JSON_PARSER}$([ "$JSON_PARSER" = none ] && printf ' (regex fallback — install jq)')"
  echo "  tool_name   : ${_got_tool:-<UNREADABLE>}"
  echo "  file_path   : ${_got_path:-<UNREADABLE>}"
  echo "  expected    : ${_want}"
  if [ "$_got_tool" = "Write" ] && [ "$_got_path" = "$_want" ]; then
    echo "  result      : OK — payloads are readable, path rules will match."
    exit 0
  fi
  echo "  result      : BROKEN — the guard cannot read its input and will DENY" >&2
  echo "                every guarded tool call until a JSON parser is on PATH." >&2
  echo "                Install jq. On Windows/Git Bash 'python3' is usually the" >&2
  echo "                Microsoft Store stub: on PATH, but not a parser." >&2
  exit 1
fi

# --- where the command RUNS vs where the CONFIG lives (two different things) --
# SHELL_CWD is the payload `cwd`: where the harness thinks the shell is. It is the
# base the git soft gates judge against (see resolve_git_dir below) and it is NOT
# the config root -- an agent's cwd is routinely a SUBDIRECTORY of the project
# (a package cache, a submodule, src/). Resolving per-repo config from it made
# `.agents/*` vanish for any non-root cwd: autonomy silently fell back to
# `interactive` (fail closed, merely confusing) while `guard-extra-*` silently
# stopped loading (fail OPEN -- the repo's declared hard-gates disappeared).
SHELL_CWD="$(json_field "$INPUT" cwd)"
[ -z "${SHELL_CWD:-}" ] && SHELL_CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

# --- discover EVERY plausible config root ------------------------------------
# Candidates: $CLAUDE_PROJECT_DIR (the harness's project root, when set) and every
# ancestor of it / of SHELL_CWD that declares a `.agents/` directory. The upward
# walk -- not `git rev-parse --show-toplevel` -- is what finds the root: the walk
# also works in a git-free repo, and it does not stop at a NESTED checkout's
# boundary (a submodule / vendored clone / package cache that is itself a repo),
# which is exactly where rev-parse would answer with the wrong repo. Bounded by
# $HOME and `/` so a stray dotfile above the workspace can never be picked up.
#
# Multiple roots are merged RESTRICTIVELY, never by picking a winner:
#   - guard-extra-* patterns are UNIONed  (patterns are only ever ADDED)
#   - autonomy takes the MINIMUM vote     (privilege is only ever REDUCED)
# so resolution can never yield a config LESS restrictive than the real project's,
# even if a foreign `.agents/` is discovered. Ambiguity fails closed by construction.
CONFIG_ROOTS=()
_add_config_root() {
  local d="${1:-}" r e
  [ -n "$d" ] && [ -d "${d}/.agents" ] || return 0
  r="$(cd "$d" 2>/dev/null && pwd -P)" || return 0
  for e in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do
    [ "$e" = "$r" ] && return 0
  done
  CONFIG_ROOTS+=("$r")
}
_walk_up_for_config() {
  local d n=0
  d="$(cd "${1:-/nonexistent}" 2>/dev/null && pwd -P)" || return 0
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "${HOME:-}" ] && [ "$n" -lt 40 ]; do
    _add_config_root "$d"
    d="$(dirname "$d")"
    n=$((n + 1))
  done
}
# The discovery WALK (up to ~80 cd/pwd subshells per call) and the guard-extra
# unioning are wrapped in `discover_config`, called LAZILY — only for commands that
# are not read-only (the read-only fast-path in the Bash case exits before this),
# so a read-only command pays none of it (the ADR 0008 hot path). Memoized per
# process so it runs at most once per invocation (both the Bash gate and
# ensure_autonomy may ask for it).
_CONFIG_DISCOVERED=""
discover_config() {
  [ -n "$_CONFIG_DISCOVERED" ] && return 0
  _CONFIG_DISCOVERED=1

  _walk_up_for_config "${CLAUDE_PROJECT_DIR:-}"
  _walk_up_for_config "$SHELL_CWD"

  # Kept for messages/back-compat: the most specific root, else the shell cwd.
  PROJECT_DIR="$SHELL_CWD"
  for _r in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do PROJECT_DIR="$_r"; break; done

  # UNION the per-project extra patterns from every discovered root.
  local _root line
  for _root in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do
    if [ -f "${_root}/.agents/guard-extra-bash" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|\#*) continue ;; esac
        DENY_BASH_PATTERNS+=("$line")
      done < "${_root}/.agents/guard-extra-bash"
    fi
    # guard-extra-paths -> SECRET tier (hard floor): declared per-repo risk stays an
    # ENFORCED hard-deny, exactly as before ADR 0014 (money/PHI/domain paths).
    if [ -f "${_root}/.agents/guard-extra-paths" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|\#*) continue ;; esac
        SECRET_PATH_PATTERNS+=("$line")
      done < "${_root}/.agents/guard-extra-paths"
    fi
    # guard-extra-review -> REVIEW tier (ask): per-repo paths that should prompt but
    # not dead-end (e.g. a repo's own auth/ layout, a bespoke deploy dir).
    if [ -f "${_root}/.agents/guard-extra-review" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|\#*) continue ;; esac
        REVIEW_PATH_PATTERNS+=("$line")
      done < "${_root}/.agents/guard-extra-review"
    fi
  done
}

# --- driver mode (ADR 0028 / thin-loop-driver T5) -----------------------------
# A driver-mode mark is a FILE `.agents/driver-mode/<session_id>` in a
# discovered config root, written/removed only by `runstate.sh driver-mode`
# (T3). Its CONTENT is irrelevant -- existence alone means "this session is
# the loop driver." The guard refuses a write only when ALL of:
#   1) the payload's session_id has a mark in some discovered config root,
#   2) the payload carries NO agent_id (a dispatched subagent always does --
#      ADR 0028 Result 1. NEVER branch on agent_type: a `claude --agent` main
#      thread carries agent_type with no agent_id and must still be refused),
#   3) the target COULD REACH A PACKET'S COMMIT -- i.e. it is inside the
#      repository the loop is driving and outside that repository's .agents/,
#      or its real location cannot be verified at all.
# On (3): the reason this tier exists is that the driver must not make a
# packet's edits itself (cost, and the reviewer is the boundary) -- so the
# permitted class is stated as a CRITERION, not a list of paths. A target that
# RESOLVES OUTSIDE every discovered config root cannot enter any packet's
# commit, so driver mode does not refuse it (a driver writing its own
# agent-memory file, which lives outside the repository entirely, is the worked
# example); every OTHER tier still judges that call, the secret/key-material
# floor first. What stays refused is anything the guard cannot place outside the
# repository: an unresolved $VAR, a `..` segment, a relative path whose cwd is
# not the repository root, an unrecognised shell write shape. Wrong-and-refused
# costs a pause; wrong-and-allowed is the leak this tier exists to stop.
# Known limit, stated rather than guessed at: a SECOND CHECKOUT of the driven
# repository (a worktree whose own .agents/ is not discovered) reads as outside.
# Nothing in the loop creates one during a run, and its commits are not this
# run's packet commits -- but do not read "outside every config root" as a
# stronger claim than it is.
# Checked AFTER the secret floor (a secret path is refused as a secret first)
# and BEFORE the ask tier -- and it refuses even when bypass-ask-tier is true,
# because this is a hard deny via deny(), not something ask()'s bypass skips.
#
# session_id becomes a PATH COMPONENT below, so it is validated FIRST: anything
# outside [A-Za-z0-9._-], or exactly "." or "..", is treated as NO mark -- judge
# the call exactly as it is today, never deny, never stat an arbitrary path.
_valid_session_id() {   # $1 = raw session_id
  local s="$1"
  [ -n "$s" ] || return 1
  case "$s" in
    .|..)                return 1 ;;
    *[!A-Za-z0-9._-]*)   return 1 ;;
  esac
  return 0
}

# Does a mark exist for this (already-validated) session id, in ANY discovered
# config root? Existence only -- content is never read.
driver_mode_marked() {   # $1 = validated session_id
  local root
  discover_config
  for root in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do
    [ -f "${root}/.agents/driver-mode/${1}" ] && return 0
  done
  return 1
}

# Does the payload cwd RESOLVE to a discovered config root exactly (not merely
# live somewhere under one)? A relative `.agents/...` target only unambiguously
# names the repo's real .agents/ directory when cwd IS that root.
#
# On success it PUBLISHES the matched root in DRIVER_MODE_CWD_ROOT, which is
# already physical (both sides of the comparison go through `pwd -P`). That
# value is load-bearing, not a convenience: a relative target has to be judged
# on where it really lands, and doing that needs an absolute candidate built
# from the cwd's PHYSICAL root. Never build one from $SHELL_CWD directly -- the
# payload cwd may itself be a symlinked path, and assuming otherwise is the
# asymmetry this whole defect family comes from.
DRIVER_MODE_CWD_ROOT=""
_cwd_is_config_root() {
  local resolved r
  DRIVER_MODE_CWD_ROOT=""
  resolved="$(cd "$SHELL_CWD" 2>/dev/null && pwd -P)" || return 1
  for r in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do
    if [ "$r" = "$resolved" ]; then DRIVER_MODE_CWD_ROOT="$r"; return 0; fi
  done
  return 1
}

# Is `$1` (a normalized path) inside `<root>/.agents/` for some discovered
# config root? Case-insensitive, for Windows path/drive-letter casing.
_driver_mode_in_agents_dir() {   # $1 = normalized path
  local lc root lc_root
  lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for root in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do
    lc_root="$(printf '%s' "${root%/}" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in "${lc_root}/.agents/"*) return 0 ;; esac
  done
  return 1
}

# Is `$1` (a normalized path) inside -- or exactly -- a discovered config root?
# That is the "could reach a packet's commit" test: the loop commits from the
# repository whose `.agents/` was discovered, so a target under it can land in a
# packet, and a target under none of them cannot.
_driver_mode_in_repo() {   # $1 = normalized path
  local lc root lc_root
  lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for root in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do
    lc_root="$(printf '%s' "${root%/}" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in "$lc_root"|"${lc_root}/"*) return 0 ;; esac
  done
  return 1
}

# Resolve a target whose FINAL component is itself an existing symlink, by
# following it. `_driver_mode_resolve_abs` deliberately leaves the tail
# unresolved (a write legitimately creates a new file), and a symlink leaf is
# the one case where that tail names an existing object somewhere else -- so an
# out-of-repository leaf pointing INTO the repository would otherwise compare as
# outside and be permitted while the write lands in the checkout.
#
# Plain `readlink` ONLY, one hop per iteration: `readlink -f` is not a safe
# dependency under the stock-Git-Bash constraint this hook is built around, and
# it is probed by EXECUTION, not `command -v` (a Windows shim can be on PATH and
# still not work). A relative link target resolves against the LINK's own
# directory. Every failure -- no usable `readlink`, an empty target, a chain
# longer than the hop bound, a symlink loop, a tail of `.`/`..` that names no
# file -- prints nothing and returns 1, i.e. REFUSE. Interior `..` segments in a
# link target are NOT refused here: the caller re-resolves the result's
# ancestors through `cd`/`pwd -P`, which resolves them physically.
#
# A `\` in a link target is rewritten to `/`, matching how `norm` is normalized
# in `_driver_mode_path_ok` and right for Windows; on POSIX a backslash is a
# legal filename character, so a contrived target containing one resolves to a
# path that is not literally the link's own. It errs toward judging a
# repository-shaped path, i.e. toward refusing -- the safe direction here.
_driver_mode_follow_leaf() {   # $1 = absolute path whose final component is a symlink
  local cur="$1" tgt hops=0
  while [ -L "$cur" ] && [ "$hops" -lt 16 ]; do
    tgt="$(readlink "$cur" 2>/dev/null)" || return 1
    [ -n "$tgt" ] || return 1
    tgt="${tgt//\\//}"
    case "$tgt" in
      /*|[A-Za-z]:/*) cur="$tgt" ;;                 # absolute link target
      *)              cur="${cur%/*}/${tgt}" ;;     # relative to the link's dir
    esac
    hops=$((hops + 1))
  done
  if [ -L "$cur" ]; then return 1; fi              # hop bound hit: unverifiable
  case "$cur" in */*) : ;; *) return 1 ;; esac
  case "${cur##*/}" in .|..) return 1 ;; esac      # not a file target
  printf '%s' "$cur"
}

# PHYSICAL location of an absolute target: the nearest EXISTING ancestor
# directory resolved with `pwd -P`, plus the not-yet-existing tail (a write
# legitimately creates the file, and may create directories under it). Two
# symlink forms would otherwise compare as OUTSIDE the repository and be
# permitted while writing straight into it, and each is handled by a different
# half of this function:
#   - a symlinked ANCESTOR -- `/var/...` -> `/private/var/...` on macOS, or a
#     link whose target directory is the checkout, INCLUDING one in the middle
#     of an otherwise `.agents/`-named path (`.agents/d -> ../src`) -- by the
#     `pwd -P` below;
#   - an existing symlink LEAF pointing into the checkout -- by following it
#     first, via `_driver_mode_follow_leaf`, and resolving the result's
#     ancestors here.
# Prints nothing and returns 1 when the target cannot be placed, which the
# caller must treat as REFUSE -- including a symlink leaf that cannot be
# followed. That direction is the tier's own rule: wrong-and-refused costs a
# pause, wrong-and-allowed is the leak it exists to stop.
_driver_mode_resolve_abs() {   # $1 = normalized absolute target
  local dir tail phys followed
  if [ -L "$1" ]; then
    followed="$(_driver_mode_follow_leaf "$1")" || return 1
    set -- "$followed"
  fi
  case "$1" in */*) dir="${1%/*}"; tail="${1##*/}" ;; *) return 1 ;; esac
  [ -n "$dir" ] || dir="/"
  while [ ! -d "$dir" ]; do
    case "$dir" in
      /) break ;;
      */?*) tail="${dir##*/}/${tail}"; dir="${dir%/*}"; [ -n "$dir" ] || dir="/" ;;
      *) return 1 ;;   # a drive-letter root or anything else we cannot walk
    esac
  done
  [ -d "$dir" ] || return 1
  phys="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  [ -n "$phys" ] || return 1
  printf '%s/%s' "${phys%/}" "$tail"
}

# ANCHORED judgment of a single candidate write target -- not a substring
# test. Used for Edit/Write/MultiEdit/NotebookEdit paths directly, and for
# every target `_driver_mode_extract_targets` pulls out of a Bash command.
#   - an unresolved shell variable ($VAR) in the target can never be verified
#     safe -> refuse;
#   - any ".." path segment -> refuse (traversal, and an unverifiable way to
#     leave the repository: a repository-relative target resolving outside is
#     refused for being unverifiable, not permitted for being outside);
#   - an absolute path (POSIX or a Windows drive letter) becomes the candidate
#     as-is;
#   - a relative path must match `^(\./)?\.agents/` AND the payload cwd must
#     itself be a discovered config root (see _cwd_is_config_root); the
#     candidate is then that root's PHYSICAL path joined to the target. Every
#     other relative target is refused as unverifiable -- the cwd it would be
#     resolved against is not known to be the repository root. Naming
#     `.agents/` is NECESSARY here, not SUFFICIENT: it decides only which
#     cwd-relative names are judgeable at all, never the outcome.
#
# Then ONE judgment, shared by both forms, on where the write PHYSICALLY lands:
# under some root's `.agents/` -> OK (the driver's own surface); elsewhere
# inside a discovered root -> refuse (it could reach a packet's commit);
# outside every root -> OK (it cannot).
#
# That order -- name gate, then physical judgment, with NO lexical fast path --
# is the whole design, because "it is called `.agents/`" is precisely what a
# symlink can lie about. "Physically" covers ALL THREE ways a name can lie, and
# each is closed by a different mechanism:
#   - a symlinked ANCESTOR (`/var/...` -> `/private/var/...`, or a link whose
#     target directory is the checkout) -- by `pwd -P` in
#     `_driver_mode_resolve_abs`;
#   - an existing symlink LEAF (`.agents/x -> ../src/util.ts`) -- by following
#     it in `_driver_mode_follow_leaf`, and refusing when it cannot be
#     followed;
#   - a symlinked DIRECTORY under `.agents/` (`.agents/d -> ../src`, so
#     `.agents/d/util.ts` writes repository source) -- by that same `pwd -P`,
#     which now reaches it only because nothing short-circuits on the name
#     first. This is why the lexical `<root>/.agents/` test could not stay a
#     fast path even once the leaf form was handled: a leaf test cannot see a
#     link in the path's MIDDLE.
#
# When resolution FAILS the fallback is deliberately asymmetric:
#   - an existing symlink leaf -> REFUSE. Unverifiable, and this tier's rule is
#     that wrong-and-refused costs a pause while wrong-and-allowed is the leak.
#   - anything else lexically under `<root>/.agents/` -> OK. This is the ONLY
#     surviving use of the lexical test, and it exists so the driver can still
#     write its own run-state on a layout whose ancestors this hook cannot walk
#     (a drive-letter root it cannot descend from, an unreadable ancestor).
#   - anything else -> refuse.
_driver_mode_path_ok() {   # $1 = raw candidate target
  local raw="${1:-}" norm abs phys
  [ -n "$raw" ] || return 1
  # unresolved variable, or the sanitizer's quoted-region placeholder -> a
  # target we cannot verify at all is refused, never guessed at (N1).
  case "$raw" in *'$'*|*'__Q__'*) return 1 ;; esac
  norm="${raw//\\//}"
  case "/${norm}/" in *'/../'*) return 1 ;; esac  # any ".." segment -> refuse
  discover_config
  # (1) NAME gate -> one absolute candidate to judge.
  case "$norm" in
    /*|[A-Za-z]:/*)
      abs="$norm"
      ;;
    *)
      # A relative target is anchored only when cwd IS the repository root, and
      # only `.agents/...` is judgeable from there. The candidate is built from
      # the root's PHYSICAL path so this arm reaches exactly the same judgment
      # as the absolute one -- it is the arm where a lexical `.agents/*` permit
      # used to END the story, which let `.agents/link -> ../src/util.ts` (a
      # link the driver can create with one permitted `ln -s`) write repository
      # source under an `.agents/` name, in the path form a driver writes by
      # default.
      _cwd_is_config_root || return 1
      case "$norm" in
        .agents/*|./.agents/*) : ;;
        *)                     return 1 ;;
      esac
      # Belt and braces: an empty root would build `/.agents/...`, which
      # resolves outside every root and would PERMIT. A control must not
      # fail open on a value it only believes is set.
      [ -n "$DRIVER_MODE_CWD_ROOT" ] || return 1
      abs="${DRIVER_MODE_CWD_ROOT%/}/${norm#./}"
      ;;
  esac
  # (2) judge on where the write REALLY lands.
  if phys="$(_driver_mode_resolve_abs "$abs")"; then
    _driver_mode_in_agents_dir "$phys" && return 0
    _driver_mode_in_repo "$phys" && return 1   # in the repo, outside .agents/
    return 0                                   # outside the driven repository
  fi
  # (3) resolution failed. An existing symlink leaf is unverifiable and must
  #     NOT fall through to a test on its own name.
  #     (Written as an `if`, not `[ -L … ] || _in_agents_dir … && return 0`:
  #     `&&`/`||` are left-associative, so that reads as
  #     `([ -L ] || _in_agents_dir) && return 0` and would PERMIT every symlink
  #     leaf -- the exact inverse of this rule.)
  if [ -L "$abs" ]; then return 1; fi
  _driver_mode_in_agents_dir "$abs" && return 0
  return 1
}

# --- driver mode: sanitizing and target-extraction for Bash writes -----------
# A raw Bash command cannot be judged by pattern-matching the whole string (a
# BASH_WRITE_PATTERNS hit inside a commit message, a heredoc body, a quoted
# arg, or a `2>/dev/null`/`2>&1` redirect is not a real write). So in driver
# mode ONLY, the command is reduced to a form safe to re-match and to extract
# real targets from. This NEVER changes how the existing SECRET/REVIEW/ASK
# checks match -- those still run against the raw command exactly as before.

# Drop every heredoc BODY (and its terminator line), on ANY line of the
# command, then keep scanning what follows -- a command AFTER the terminator
# is a real, separate statement and must still be judged (N2). The delimiter
# is read off the SAME line as `<<`/`<<-`: an optional `-` (strips leading
# tabs from candidate terminator lines too), optional surrounding quotes, then
# the delimiter's leading `[A-Za-z0-9_]+` run. No terminator found before the
# command ends -> drop to the end (the same fail-safe direction as before,
# now reached only when it's actually true, not the default).
_driver_mode_drop_heredocs() {   # $1 = raw command
  local cmd="$1" out='' line delim='' in_heredoc=0 strip_tabs=0 rest tag k tn ch check
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_heredoc" = 1 ]; then
      check="$line"
      if [ "$strip_tabs" = 1 ]; then
        while [ "${check:0:1}" = "$(printf '\t')" ]; do check="${check:1}"; done
      fi
      [ "$check" = "$delim" ] && in_heredoc=0
      continue   # the body line, and the terminator line itself, are dropped
    fi
    out="${out}${line}"$'\n'
    case "$line" in
      *'<<'*)
        rest="${line#*<<}"
        strip_tabs=0
        case "$rest" in -*) strip_tabs=1; rest="${rest#-}" ;; esac
        while [ -n "$rest" ]; do
          case "${rest:0:1}" in
            ' '|"$(printf '\t')") rest="${rest:1}" ;;
            *) break ;;
          esac
        done
        tag="${rest#[\"\']}"
        delim=""
        tn=${#tag}
        for ((k = 0; k < tn; k++)); do
          ch="${tag:$k:1}"
          case "$ch" in
            [A-Za-z0-9_]) delim="${delim}${ch}" ;;
            *) break ;;
          esac
        done
        [ -n "$delim" ] && in_heredoc=1
        ;;
    esac
  done <<< "$cmd"
  printf '%s' "${out%$'\n'}"
}

# Blank every quoted region to ONE placeholder word (never spaces -- see N1)
# and every `#` comment (only when `#` starts a word: at the very start, or
# right after whitespace / `;` / `&` / `|` / `(`, and only to the next
# newline, per N3), leaving redirection operators, command names and real
# (unquoted) targets untouched so they can still be pattern-matched and
# extracted. A single placeholder word means a quoted arg still occupies
# exactly one token position (so e.g. a quoted sed EXPRESSION doesn't
# silently vanish and shift a real file onto seen_expr -- N1), and it can
# never itself look like a safe target: `_driver_mode_path_ok` refuses it.
_driver_mode_sanitize_cmd() {   # $1 = raw command
  local cmd firstline
  cmd="$(_driver_mode_drop_heredocs "$1")"
  local out='' i=0 n=${#cmd} c q='' prev=''
  while [ "$i" -lt "$n" ]; do
    c="${cmd:$i:1}"
    if [ -n "$q" ]; then
      if [ "$q" = '"' ] && [ "$c" = '\' ]; then
        i=$((i + 2)); continue        # escaped char inside "..." -> consumed
      fi
      if [ "$c" = "$q" ]; then
        q=''; out="${out} __Q__ "; prev='x'
      fi
      i=$((i + 1)); continue
    fi
    case "$c" in
      "'"|'"') q="$c"; i=$((i + 1)); continue ;;
      '\')
        out="${out}${c}${cmd:$((i + 1)):1}"; prev='x'; i=$((i + 2)); continue ;;
      '#')
        case "$prev" in
          ''|' '|$'\t'|$'\n'|';'|'&'|'|'|'(')
            while [ "$i" -lt "$n" ] && [ "${cmd:$i:1}" != $'\n' ]; do i=$((i + 1)); done
            continue
            ;;
          *) out="${out}${c}"; prev="$c"; i=$((i + 1)); continue ;;
        esac
        ;;
      *) out="${out}${c}"; prev="$c"; i=$((i + 1)); continue ;;
    esac
  done
  printf '%s' "$out"
}

# Remove redirects that never name a real file -- `>`/`>>`/`N>` to /dev/null,
# and fd-duplication (`2>&1`, `1>&2`, `2>&-`). Applied on top of the sanitized
# copy, before both the write-pattern re-check and target extraction, so a
# command whose ONLY "write" is one of these is never treated as a write at
# all (e.g. `bash x.sh > /dev/null`, `scripts/runstate.sh status 2>/dev/null`).
_driver_mode_neutralize_redirects() {   # $1 = sanitized command
  printf '%s' "$1" \
    | sed -E 's/[0-9]?(>>?|>\|)[[:space:]]*\/dev\/null//g' \
    | sed -E 's/[0-9]?>&[0-9-]+//g'
}

# Constructs that can hide an additional write or target from this simple
# scanner, so their presence alongside a matched write form is refused rather
# than guessed at: command substitution, backticks, `eval`, `xargs`, and
# `sh -c`/`bash -c`. Checked on the sanitized copy, so one QUOTED (inert) is
# not mistaken for a real one.
_driver_mode_bash_dangerous() {   # $1 = sanitized command
  local s="$1"
  case "$s" in
    *'$('*|*'`'*) return 0 ;;
  esac
  printf '%s' "$s" | grep -Eq '(^|[^[:alnum:]])(eval|xargs)([^[:alnum:]]|$)' && return 0
  printf '%s' "$s" | grep -Eq '(^|[^[:alnum:]])(sh|bash)[[:space:]]+-c([^[:alnum:]]|$)' && return 0
  return 1
}

# Split a sanitized command into segments on `;`, `&&`, `||` and `|` (plain
# substring replace -- the sanitizer already blanked every quoted region, so
# none of these can be DATA at this point). One segment per output line.
_driver_mode_bash_segments() {   # $1 = sanitized (and redirect-neutralized) command
  local s="$1"
  s="${s//'&&'/$'\n'}"
  s="${s//'||'/$'\n'}"
  s="${s//;/$'\n'}"
  s="${s//|/$'\n'}"
  printf '%s\n' "$s"
}

# Extracts every write TARGET from one segment, one per output line. Narrow by
# design: it recognizes exactly the forms BASH_WRITE_PATTERNS matches (a bare
# `>`/`>>` redirect, `tee`, `sed -i`, the `cp`/`mv`/`install`/`ln`/`rsync`
# last-arg family, `dd of=`, `truncate`) and prints NOTHING for anything else
# -- an unrecognized write shape yields no target, which the caller treats as
# "refuse", never as "allow".
_driver_mode_extract_targets() {   # $1 = one segment
  local seg="$1" tok first
  # (1) explicit `>`/`>>`/`>|` (optionally fd-numbered) redirection targets.
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      '&'*) ;;
      *) printf '%s\n' "$tok" ;;
    esac
  done < <(printf '%s' "$seg" \
    | grep -oE '[0-9]?(>{1,2}|>\|)[[:space:]]*[^[:space:];&|]+' \
    | sed -E 's/^[0-9]?(>{1,2}|>\|)[[:space:]]*//')

  # Tokenize on whitespace via `read -a` (never unquoted `( )`, which would
  # glob-expand `*`/`?`/`[` against the guard process's own cwd).
  local -a words plain
  read -ra words <<< "$seg"
  [ "${#words[@]}" -gt 0 ] || return 0

  # Drop any redirection operator (bare or glued to its target, e.g. `>`,
  # `>file`, `>|file`, `2>&1`) and, for a BARE operator, the token right after
  # it too -- so a `<`/`>`/`>|` target is never mistaken for a plain argument.
  plain=()
  local w skip_next=0
  for w in "${words[@]}"; do
    if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
    case "$w" in
      '>'|'>>'|'>|'|'<'|[0-9]'>'|[0-9]'>>'|[0-9]'>|'|[0-9]'<') skip_next=1; continue ;;
      '>'*|'>>'*|'>|'*|'<'*|[0-9]'>'*|[0-9]'>>'*|[0-9]'>|'*|[0-9]'<'*) continue ;;
      *) plain+=("$w") ;;
    esac
  done
  [ "${#plain[@]}" -gt 0 ] || return 0
  first="${plain[0]##*/}"

  case "$first" in
    tee)
      for w in "${plain[@]:1}"; do
        case "$w" in -*) ;; *) printf '%s\n' "$w" ;; esac
      done
      ;;
    cp|install|ln)
      # -t/--target-directory NAMES the real destination (N7a): without it,
      # every other positional arg is a SOURCE (only read), and only the last
      # positional arg is written. rsync has no -t/--target-directory (its
      # own -t means "preserve times") so it is NOT in this case.
      local tdir='' k
      for ((k = 1; k < ${#plain[@]}; k++)); do
        case "${plain[$k]}" in
          -t) tdir="${plain[$((k + 1))]:-}"; break ;;
          --target-directory=*) tdir="${plain[$k]#--target-directory=}"; break ;;
        esac
      done
      if [ -n "$tdir" ]; then
        printf '%s\n' "$tdir"
      elif [ "${#plain[@]}" -gt 1 ]; then
        printf '%s\n' "${plain[${#plain[@]}-1]}"
      fi
      ;;
    mv)
      # mv REMOVES every source it renames away from, which is a write at
      # that path too (N7b) -- so every positional arg is a target, not just
      # the destination (or the -t/--target-directory value, if given).
      local tdir='' k
      for ((k = 1; k < ${#plain[@]}; k++)); do
        case "${plain[$k]}" in
          -t) tdir="${plain[$((k + 1))]:-}"; break ;;
          --target-directory=*) tdir="${plain[$k]#--target-directory=}"; break ;;
        esac
      done
      [ -n "$tdir" ] && printf '%s\n' "$tdir"
      for w in "${plain[@]:1}"; do
        case "$w" in -*) ;; *) printf '%s\n' "$w" ;; esac
      done
      ;;
    rsync)
      [ "${#plain[@]}" -gt 1 ] && printf '%s\n' "${plain[${#plain[@]}-1]}"
      ;;
    dd)
      printf '%s' "$seg" | grep -oE '(^|[^[:alnum:]])of=[^[:space:];&|]+' | sed -E 's/^.*of=//'
      ;;
    truncate)
      local i=1 n=${#plain[@]}
      while [ "$i" -lt "$n" ]; do
        case "${plain[$i]}" in
          -s)          i=$((i + 2)); continue ;;
          --size=*|-s*|-*) ;;
          *)           printf '%s\n' "${plain[$i]}" ;;
        esac
        i=$((i + 1))
      done
      ;;
    sed)
      case "$seg" in
        *-i*)
          local j=1 m=${#plain[@]} seen_expr=0
          while [ "$j" -lt "$m" ]; do
            case "${plain[$j]}" in
              -*) ;;
              *)
                if [ "$seen_expr" = 0 ]; then seen_expr=1
                else printf '%s\n' "${plain[$j]}"
                fi
                ;;
            esac
            j=$((j + 1))
          done
          ;;
      esac
      ;;
  esac
}

# The whole driver-mode Bash decision: 0 = REFUSE, 1 = no objection.
_driver_mode_bash_refuses() {   # $1 = raw command
  local raw="$1" san neutral seg tgt matched=1 targets_found=0 wp saw_cd=0 first_word

  san="$(_driver_mode_sanitize_cmd "$raw")"
  neutral="$(_driver_mode_neutralize_redirects "$san")"

  for wp in "${BASH_WRITE_PATTERNS[@]}"; do
    if printf '%s' "$neutral" | grep -Eq "$wp"; then matched=0; break; fi
  done
  [ "$matched" = 1 ] && return 1   # nothing left that looks like a real write

  _driver_mode_bash_dangerous "$neutral" && return 0   # can't be judged safely

  # N6: `cd`/`pushd` anywhere in the command invalidates every RELATIVE
  # target -- once the working directory can change mid-command, a relative
  # target that looks like `.agents/...` may really land at `src/.agents/...`,
  # which this scanner has no way to resolve. Scanned as its own pass (not
  # sequentially) because a change anywhere makes every relative target
  # suspect, not only the ones after it.
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    read -r first_word _ <<< "$seg"
    case "$first_word" in cd|pushd) saw_cd=1 ;; esac
  done < <(_driver_mode_bash_segments "$neutral")

  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    while IFS= read -r tgt; do
      [ -n "$tgt" ] || continue
      targets_found=$((targets_found + 1))
      if [ "$saw_cd" = 1 ]; then
        case "$tgt" in
          /*|[A-Za-z]:/*) ;;             # absolute -- unaffected by cd/pushd
          *) return 0 ;;                 # relative after a cd/pushd -- refuse
        esac
      fi
      _driver_mode_path_ok "$tgt" || return 0   # a bad/unresolvable target
    done < <(_driver_mode_extract_targets "$seg")
  done < <(_driver_mode_bash_segments "$neutral")

  [ "$targets_found" -ge 1 ] || return 0   # write matched, no target found
  return 1
}

# Lazy + memoized: session_id/agent_id are read from the payload only once, and
# only by a caller that actually reaches a driver-mode check (Edit/Write/
# MultiEdit/NotebookEdit, or a matched Bash write pattern) -- never paid for on
# the read-only Bash fast-path.
_DRIVER_MODE_INFO_READ=""
SESSION_ID=""
AGENT_ID=""
_read_driver_mode_info() {
  [ -n "$_DRIVER_MODE_INFO_READ" ] && return 0
  SESSION_ID="$(json_field "$INPUT" session_id)"
  AGENT_ID="$(json_field "$INPUT" agent_id)"
  _DRIVER_MODE_INFO_READ=1
}

# True iff this call must be judged as a MAIN-THREAD driver-mode call: a
# validated session_id carries a mark, and the payload has no agent_id. A
# payload with no session_id (or an invalid one) is judged exactly as it is
# today, because _valid_session_id already returns false for it.
driver_mode_active() {
  _read_driver_mode_info
  [ -n "${AGENT_ID:-}" ] && return 1
  _valid_session_id "$SESSION_ID" || return 1
  driver_mode_marked "$SESSION_ID"
}

# --- resolve the active autonomy level (ADR 0004) ----------------------------
# Precedence: env ORCH_AUTONOMY > <repo>/.agents/autonomy > default. An unknown
# value falls back to the default (the most restrictive, fail-safe choice). The
# result is then clamped DOWN to the repo's ceiling if project-overrides.yaml
# declares `autonomy_ceiling:`. Exposed as ORCH_AUTONOMY for check_commit_policy.
read_autonomy_ceiling() {   # $1 = a config root
  local f="${1}/.agents/project-overrides.yaml" v
  [ -f "$f" ] || return 0
  v="$(grep -Ei '^[[:space:]]*autonomy_ceiling[[:space:]]*:' "$f" 2>/dev/null | head -n1)" || return 0
  [ -n "$v" ] || return 0
  # strip `key:`, trailing comment, surrounding quotes and whitespace.
  printf '%s' "$v" \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]*$//' \
    | tr '[:upper:]' '[:lower:]'
}

# Read the declared level from one root's `.agents/autonomy`, or "" if absent.
# Reads only the LAST non-comment, non-blank line: the set-autonomy skill writes an
# explanatory `#` header above the bare level, and stripping whitespace from the
# whole file would fold that header into the token and never parse (a silent
# fallback-to-interactive bug). Strip any inline `# comment`, then whitespace.
# Always returns 0: an autonomy file that is entirely comments makes the leading
# `grep -v` exit 1, which `pipefail` propagates and `set -e` turns into a dead
# hook (exit 1 = a non-blocking error to Claude Code = the guard is bypassed).
read_autonomy_file() {   # $1 = a config root
  local f="${1}/.agents/autonomy"
  [ -f "$f" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null \
    | tail -n1 | sed -E 's/[[:space:]]*#.*$//' \
    | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true
  return 0
}

# Precedence: env ORCH_AUTONOMY > the discovered `.agents/autonomy` files > default.
# Every discovered root VOTES and the LOWEST vote wins; a root that declares a
# `.agents/` but no (or an unparseable) autonomy votes the default. So a foreign or
# nested `.agents/` can only ever LOWER the level, never raise it. The result is
# then clamped DOWN to the LOWEST `autonomy_ceiling` any root declares.
resolve_autonomy() {
  local level="" ceiling="" root rlevel rceil
  if [ -n "${ORCH_AUTONOMY:-}" ]; then
    level="$(printf '%s' "$ORCH_AUTONOMY" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ "$(autonomy_rank "$level")" = "-1" ] && level="$ORCH_AUTONOMY_DEFAULT"
  else
    for root in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do
      rlevel="$(read_autonomy_file "$root")"
      [ -n "$rlevel" ] && [ "$(autonomy_rank "$rlevel")" != "-1" ] || rlevel="$ORCH_AUTONOMY_DEFAULT"
      if [ -z "$level" ] || [ "$(autonomy_rank "$rlevel")" -lt "$(autonomy_rank "$level")" ]; then
        level="$rlevel"
      fi
    done
    [ -n "$level" ] || level="$ORCH_AUTONOMY_DEFAULT"
  fi
  for root in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do
    rceil="$(read_autonomy_ceiling "$root")"
    [ -n "$rceil" ] && [ "$(autonomy_rank "$rceil")" != "-1" ] || continue
    if [ -z "$ceiling" ] || [ "$(autonomy_rank "$rceil")" -lt "$(autonomy_rank "$ceiling")" ]; then
      ceiling="$rceil"
    fi
  done
  if [ -n "$ceiling" ] && [ "$(autonomy_rank "$level")" -gt "$(autonomy_rank "$ceiling")" ]; then
    level="$ceiling"
  fi
  printf '%s' "$level"
}

# Resolve the autonomy level LAZILY: only the git soft gates (commit/merge/rebase/
# push) consult it, so a read-only command or a non-git write never pays for it.
# Memoized. resolve_autonomy reads the ENV ORCH_AUTONOMY first (still intact here),
# then this overwrites the shell var with the fully-resolved value — same result as
# the old eager call, just deferred to first use. discover_config must run first
# (resolve_autonomy votes across CONFIG_ROOTS).
_AUTONOMY_RESOLVED=""
ensure_autonomy() {
  [ -n "$_AUTONOMY_RESOLVED" ] && return 0
  discover_config
  ORCH_AUTONOMY="$(resolve_autonomy)"
  _AUTONOMY_RESOLVED=1
}

# --- resolve `bypass-ask-tier` (project-overrides.yaml) -----------------------
# When true, the guard SKIPS the entire ASK tier (routine-but-notable bash —
# deps/migrations/deploys — and REVIEW-path writes — auth code/CI/appsettings) and
# enforces ONLY the hard-deny floors (DENY_BASH_PATTERNS, SECRET_PATH_PATTERNS) and
# the git soft gates. Default false. A repo opts out of prompts by declaring
# `bypass-ask-tier: true` in .agents/project-overrides.yaml.
#
# Resolution is RESTRICTIVE, mirroring autonomy: every discovered config root must
# opt in. A root that declares a `.agents/` but does not set the flag (or sets it
# false / an unparseable value) VETOES the bypass — so a foreign or nested
# `.agents/` can only ever KEEP the prompts, never silently remove them. With no
# config roots at all, bypass is false. Ambiguity fails closed (prompts stay on).
read_bypass_flag() {   # $1 = a config root; echoes "true"/"false"/"" (unset)
  local f="${1}/.agents/project-overrides.yaml" v
  [ -f "$f" ] || return 0
  v="$(grep -Ei '^[[:space:]]*bypass-ask-tier[[:space:]]*:' "$f" 2>/dev/null | head -n1)" || return 0
  [ -n "$v" ] || return 0
  # strip `key:`, trailing comment, surrounding quotes and whitespace; lowercase.
  v="$(printf '%s' "$v" \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]*$//' \
    | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    true|yes|on|1) printf 'true' ;;
    *)             printf 'false' ;;
  esac
}
resolve_bypass_ask() {   # echoes "true" only if EVERY discovered root opts in
  local root vote saw=0
  for root in ${CONFIG_ROOTS[@]+"${CONFIG_ROOTS[@]}"}; do
    saw=1
    vote="$(read_bypass_flag "$root")"
    [ "$vote" = "true" ] || { printf 'false'; return 0; }
  done
  [ "$saw" = "1" ] && printf 'true' || printf 'false'
}

# Resolve bypass LAZILY, memoized — only ask() consults it, so a command that never
# reaches the ask tier pays nothing. discover_config must run first (it votes across
# CONFIG_ROOTS); ensure_bypass calls it defensively in case ask() is reached by a
# path that somehow skipped discovery.
_BYPASS_RESOLVED=""
BYPASS_ASK="false"
ensure_bypass() {
  [ -n "$_BYPASS_RESOLVED" ] && return 0
  discover_config
  BYPASS_ASK="$(resolve_bypass_ask)"
  _BYPASS_RESOLVED=1
}

TOOL="$(json_field "$INPUT" tool_name)"

# Nothing on stdin at all is not a tool call (a manual probe, a harness glitch):
# there is nothing to judge, so allow. This is the ONE remaining
# allow-on-ignorance. A NON-EMPTY payload whose tool_name cannot be read is a
# different case entirely and fails CLOSED — see the deny just below deny().
if [ -z "${INPUT//[[:space:]]/}" ]; then
  exit 0
fi

MATCHED_SENSITIVE=""
# Does a command string reference a path matching one of the given patterns?
#   cmd_hits_path "<command>" "<pat1>" "<pat2>" ...
# The pattern list is passed positionally (no bash-4 namerefs — macOS ships bash
# 3.2) so the same matcher serves both the SECRET and REVIEW tiers. Relaxes each
# pattern's anchors so a path embedded mid-command still matches.
cmd_hits_path() {
  local cmd="$1"; shift
  # Match against BOTH the raw command and a separator-normalized copy. A Windows
  # path embedded in a command (`cp x C:\repo\src\Auth\y.cs`) offers no `/` for a
  # pattern's segment anchors to bite on, so multi-segment rules silently miss it.
  # Testing both keeps every escape-sensitive match intact and can only ADD hits
  # (the fail-closed direction). Anchors still apply per line.
  local haystack="$cmd" pat rpat
  case "$cmd" in *'\'*) haystack="${cmd}"$'\n'"${cmd//\\//}" ;; esac
  for pat in "$@"; do
    # Relax a leading `(^|/)` anchor to any word boundary (a path token in a
    # command is preceded by whitespace/quote/`=`, not just `/`), and relax a
    # trailing `$` anchor so a path followed by more command text still matches.
    rpat="${pat/#(^|\/)/(^|[^[:alnum:]])}"
    rpat="${rpat/%\$/($|[^[:alnum:]])}"
    if printf '%s' "$haystack" | grep -Eiq "$rpat"; then
      MATCHED_SENSITIVE="$pat"
      return 0
    fi
  done
  return 1
}

deny() {
  # $1 = category, $2 = matched pattern, $3 = the offending value
  echo "GUARDRAIL: blocked a high-risk action — explicit human approval required." >&2
  echo "  category : $1" >&2
  echo "  rule     : $2" >&2
  echo "  target   : $3" >&2
  echo "  tool     : ${TOOL}" >&2
  # Category-specific remediation — especially useful on Claude Desktop, where
  # you cannot prepend `ORCH_AUTONOMY=… claude` to change autonomy per session.
  case "$1" in
    commit-gate:autonomy)
      echo "  hint     : raise autonomy in-session with /gaffer:set-autonomy supervised (or set env ORCH_AUTONOMY, e.g. .claude/settings.json -> env). A main/master commit still ALWAYS requires the human, regardless of autonomy." >&2 ;;
    commit-gate:branch)
      echo "  hint     : main/master is a hard gate at every autonomy level — commit on a feature branch, or run the commit yourself." >&2 ;;
    merge-gate:autonomy|rebase-gate:autonomy|push-gate:autonomy)
      echo "  hint     : merge/rebase/push are delegated only at full-autonomy — raise it with /gaffer:set-autonomy full-autonomy (or env ORCH_AUTONOMY). Even then, only NON-main targets are allowed." >&2 ;;
    merge-gate:branch|rebase-gate:branch|push-gate:target)
      echo "  hint     : merging/pushing to main/master (or remote main) ALWAYS requires the human, at every level. Target a non-main integration/feature branch, or run it yourself." >&2 ;;
    commit-gate:secret-path|merge-gate:secret-path)
      echo "  hint     : this change touches a SECRET path (.env / key material / a secrets or credentials store, plus any per-repo path in .agents/guard-extra-paths). The exposure floor holds at every autonomy level — escalate it to the human. (Auth CODE and CI config are the ask tier now, not this hard floor — ADR 0014.)" >&2 ;;
    payload-unreadable)
      echo "  hint     : the guardrail could not read this tool call's payload, so it cannot judge it — and a control that cannot read its input must DENY, not allow. Install a working JSON parser on PATH: 'jq' is the reliable one. On Windows/Git Bash, 'python3' is usually the Microsoft Store App Execution Alias, which is on PATH but is NOT a parser. Check with: hooks/guard.sh --selftest" >&2 ;;
    driver-mode|driver-mode-via-bash)
      echo "  hint     : this session is in driver mode (ADR 0028) — it dispatches agents to make the packet's edits and must not edit the repository it is driving. Two things are refused, each with its own way forward: (a) a target INSIDE this repository and outside .agents/ — dispatch an agent to make that edit, or keep driver-owned scratch under .agents/; (b) a target whose real location can't be verified — an unresolved shell variable (\$VAR), a '..' segment, a path relative to a cwd that isn't the repository root, or a shell write whose target can't be read — re-issue it as a fully resolved absolute path and it will be judged on where it actually lands. A write that resolves OUTSIDE this repository is not refused here (every other tier still judges it). If you need to make this edit by hand yourself, pause the loop first: /gaffer:pause." >&2 ;;
  esac
  echo "If this is intended, approve it explicitly (or run it yourself)." >&2
  exit 2
}

# Every tool this hook is registered for (Bash|Edit|Write|MultiEdit|NotebookEdit)
# carries a target — a command or a path. So an EMPTY extraction is never a
# legitimate absence; it means the payload could not be read. The branches below
# used to `exit 0` here, which meant ANY parsing failure — a stubbed python3, a
# JSON-escaped Windows path, a missing parser — silently disabled the guard with
# no banner, no stderr and no denial, while it kept blocking simple ASCII bash
# commands and so looked healthy.
deny_unreadable() {   # $1 = the field that could not be extracted
  local head
  head="$(printf '%s' "$INPUT" | tr '\n\r\t' '   ' | cut -c1-200 || true)"
  deny "payload-unreadable" \
       "cannot extract '$1' from the tool payload (json parser: ${JSON_PARSER:-unknown})" \
       "${head:-<empty>}"
}

# A payload arrived, but we cannot tell which tool it is. Since this hook only
# runs for the five guarded tools, "unreadable" here means an unjudged guarded
# call -> fail closed. (Truly empty stdin already returned 0 above.)
if [ -z "${TOOL:-}" ]; then
  TOOL="(unreadable)"
  deny_unreadable "tool_name"
fi

# JSON-encode a string (for permissionDecisionReason). jq -> python3 -> minimal
# fallback, mirroring json_field's dependency ladder.
json_string() {
  local s="$1"
  detect_json_parser
  case "$JSON_PARSER" in
    jq)             printf '%s' "$s" | jq -Rs . && return 0 ;;
    python3|python) printf '%s' "$s" | "$JSON_PARSER" -c 'import json,sys; print(json.dumps(sys.stdin.read()))' && return 0 ;;
  esac
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"
  printf '"%s"' "$s"
}

# ASK: routine-but-notable action. Emit a PreToolUse JSON decision on stdout and
# exit 0, so Claude Code shows its native one-click approval prompt instead of a
# hard block. $1 = category, $2 = matched pattern, $3 = offending value.
#
# `bypass-ask-tier: true` (project-overrides.yaml) short-circuits this to a silent
# allow: the repo has opted out of ask prompts entirely. This is the ONLY effect of
# the flag — every hard-deny tier runs before any ask() call, so bypass can never
# turn a deny into an allow.
ask() {
  ensure_bypass
  if [ "$BYPASS_ASK" = "true" ]; then
    exit 0
  fi
  local reason
  reason="GUARDRAIL: '$1' needs confirmation (rule: $2). Approve to run: $3"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":%s}}\n' \
    "$(json_string "$reason")"
  exit 0
}

# Split a pipeline into segments on UNQUOTED `|` only, so a `|` inside a quoted
# argument (`grep "rm -rf\|foo" f`) is understood as DATA, not a pipe separator.
# Pure bash, no subshells. Populates the global SPLIT_SEGS; returns 1 if a quote
# is left open (ambiguous -> the caller must DECLINE, never allow).
#
# Quoting rules honored, matching the shell: inside '…' every character is
# literal; inside "…" a backslash escapes the next character; outside quotes a
# backslash escapes the next character (so `\|` is a literal pipe, not a split).
SPLIT_SEGS=()
split_pipeline() {
  local cmd="$1" n=${#1} i=0 c q='' seg=''
  SPLIT_SEGS=()
  while [ "$i" -lt "$n" ]; do
    c="${cmd:i:1}"
    if [ -n "$q" ]; then
      if [ "$q" = '"' ] && [ "$c" = '\' ]; then     # \" inside "…" doesn't close it
        i=$((i + 1)); seg="${seg}${c}${cmd:i:1}"; i=$((i + 1)); continue
      fi
      [ "$c" = "$q" ] && q=''
      seg="${seg}${c}"; i=$((i + 1)); continue
    fi
    case "$c" in
      '\')     i=$((i + 1)); seg="${seg}${c}${cmd:i:1}" ;;   # escaped char is literal
      "'"|'"') q="$c"; seg="${seg}${c}" ;;                   # quote opens
      '|')     SPLIT_SEGS+=("$seg"); seg='' ;;               # a REAL pipe: split here
      *)       seg="${seg}${c}" ;;
    esac
    i=$((i + 1))
  done
  [ -n "$q" ] && return 1        # unterminated quote -> ambiguous -> DECLINE
  SPLIT_SEGS+=("$seg")
  return 0
}

# READ-ONLY fast-path predicate. Returns 0 (allow immediately) iff the command is
# unambiguously read-only: it contains no character that could redirect output,
# substitute a command, or chain a second statement (`> < \` $ ; &`), AND every
# pipeline segment leads with a whitelisted read-only command (or a read-only
# `git` subcommand). `find` is admitted only when it carries none of the mutating
# primaries (`-delete`/`-exec…`), so it can never fast-path past the hard-deny rule.
#
# Splitting is quote-aware (see split_pipeline). It used to split on the first
# literal `|`, which broke the fast-path's whole purpose: `grep "rm -rf\|foo" f`
# split into a bogus second "segment", declined, fell through to the denylist, and
# was HARD-DENIED by matching the `rm -rf` inside its own search string — exactly
# the "searching FOR a risky string is not RUNNING it" case this exists to allow.
# The fail-safe DIRECTION is unchanged: anything ambiguous (an unbalanced quote, a
# segment that isn't clearly read-only) still returns 1 and falls through to the
# normal denylist. This function can decline a safe command; it must never allow
# an unsafe one.
is_read_only() {
  local cmd="$1" seg first
  case "$cmd" in
    # A literal newline is a statement separator exactly like `;` -- without
    # this, only the FIRST word of a multi-line command was ever checked
    # (e.g. "echo hi\ncp a .env" fast-pathed on "echo" alone, and the second
    # line's write never got judged at all -- a pre-existing hole, not a
    # driver-mode one). This can only DECLINE more commands, never allow one.
    *'>'*|*'<'*|*'`'*|*'$'*|*';'*|*'&'*|*$'\n'*) return 1 ;;
  esac
  split_pipeline "$cmd" || return 1
  for seg in "${SPLIT_SEGS[@]}"; do
    seg="${seg#"${seg%%[![:space:]]*}"}"   # strip leading whitespace
    first="${seg%%[[:space:]]*}"
    if [ "$first" = "git" ]; then
      printf '%s' "$seg" \
        | grep -Eq "^git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+(${READ_ONLY_GIT})([[:space:]]|\$)" \
        || return 1
    elif [ "$first" = "find" ]; then
      # find IS a search tool — but -delete/-exec mutate; those must not fast-path.
      printf '%s' "$seg" | grep -Eq -- '-(delete|exec|execdir|ok|okdir|fprint|fprintf|fls)([[:space:]]|$)' \
        && return 1
    else
      printf '%s' "$first" | grep -Eq "^(${READ_ONLY_CMDS})\$" || return 1
    fi
  done
  return 0
}

# `git commit` is a SOFT gate (ADR 0004): allowed only when ALL hold —
#   1) autonomy >= supervised,
#   2) the current branch is not main/master, and
#   3) the diff this commit would create touches no SECRET_PATH_PATTERNS path.
#      (ADR 0014: the SECRET tier only — committing auth *code* or CI config is a
#      normal delegable commit, reviewed downstream; sweeping in a secret is not.)
# Anything else DENIES with the standard explanation. Fails CLOSED on any error
# (not a repo, no commits, detached HEAD, unreadable diff). Green build+tests is
# NOT checked here — a PreToolUse hook can't run the suite; that invariant is the
# Chief Engineer's responsibility before it ever issues the commit.
# Returns 0 (allow) so the caller continues to the shell-write check; never
# reached on deny (deny exits 2).
check_commit_policy() {
  local cmd="$1"
  # --amend rewrites history -> stays hard-denied exactly as before.
  if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]])--amend([^[:alnum:]]|$)'; then
    deny "git-history-rewrite" "commit --amend" "$cmd"
  fi
  # (1) autonomy must be at least supervised.
  if [ "$(autonomy_rank "$ORCH_AUTONOMY")" -lt "$(autonomy_rank supervised)" ]; then
    deny "commit-gate:autonomy" "autonomy=${ORCH_AUTONOMY} (needs >= supervised)" "$cmd"
  fi
  # (2) must be on a feature branch, not main/master. Fail closed if undetectable.
  #     Read from GIT_CWD (the tree the command targets), not the payload cwd.
  local branch
  branch="$(git -C "$GIT_CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    || deny "commit-gate:branch" "cannot determine branch (not a repo / no commits)" "$cmd"
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    deny "commit-gate:branch" "detached HEAD or undetectable branch" "$cmd"
  fi
  case "$branch" in
    main|master) deny "commit-gate:branch" "commit to protected branch '${branch}'" "$cmd" ;;
  esac
  # (3) the paths this commit would include must hit no SECRET pattern.
  #     Normally the staged diff; with -a/--all, also the tracked-but-unstaged
  #     changes `git commit -a` sweeps in (closes the staging-area bypass).
  local files
  files="$(git -C "$GIT_CWD" diff --cached --name-only 2>/dev/null)" \
    || deny "commit-gate:staged" "cannot read staged diff" "$cmd"
  if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])(--all|-[[:alnum:]]*a[[:alnum:]]*)([[:space:]]|=|$)'; then
    local unstaged
    unstaged="$(git -C "$GIT_CWD" diff --name-only 2>/dev/null || true)"
    files="$(printf '%s\n%s' "$files" "$unstaged")"
  fi
  local f pat
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for pat in "${SECRET_PATH_PATTERNS[@]}"; do
      if printf '%s' "$f" | grep -Eiq "$pat"; then
        deny "commit-gate:secret-path" "$pat" "$f"
      fi
    done
  done <<EOF
$files
EOF
  return 0   # all soft-gate conditions satisfied -> allow.
}

# Resolve the current branch into CURRENT_BRANCH, or deny (fail closed) via the
# given category. deny runs in the MAIN shell (after `||` / at function top level,
# never inside a $(...) subshell) so `exit 2` ends the hook, not a subshell. Shared
# by the merge/rebase/push soft gates.
CURRENT_BRANCH=""
resolve_branch_or_deny() {
  local category="$1" cmd="$2"
  CURRENT_BRANCH="$(git -C "$GIT_CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    || deny "$category" "cannot determine branch (not a repo / no commits)" "$cmd"
  if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "HEAD" ]; then
    deny "$category" "detached HEAD or undetectable branch" "$cmd"
  fi
}

# `git merge` is a SOFT gate (ADR 0006): allowed only when ALL hold —
#   1) autonomy == full-autonomy,
#   2) the branch being merged INTO (current HEAD) is not main/master, and
#   3) best-effort: the incoming change touches no SECRET_PATH_PATTERNS path.
# Merging to main/master is a hard gate at EVERY level. Below full-autonomy this
# denies exactly as before. Never reached on deny (deny exits 2); returns 0 to
# continue to the shell-write check.
check_merge_policy() {
  local cmd="$1"
  if [ "$(autonomy_rank "$ORCH_AUTONOMY")" -lt "$(autonomy_rank full-autonomy)" ]; then
    deny "merge-gate:autonomy" "autonomy=${ORCH_AUTONOMY} (needs full-autonomy)" "$cmd"
  fi
  resolve_branch_or_deny merge-gate:branch "$cmd"
  case "$CURRENT_BRANCH" in
    main|master) deny "merge-gate:branch" "merge into protected branch '${CURRENT_BRANCH}'" "$cmd" ;;
  esac
  # (3) Defense in depth: if we can identify the source ref and read the incoming
  #     file list, deny on any sensitive path. Best-effort — a merge of branches
  #     the loop itself produced can't contain sensitive paths (the commit gate
  #     blocks them), so an unparseable/unknown ref is allowed to proceed here.
  local src f pat files
  src="$(printf '%s' "$cmd" \
    | sed -E 's/^.*(^|[^[:alnum:]])merge([[:space:]]+-[^[:space:]]+)*[[:space:]]+//; s/[[:space:]].*$//')"
  if [ -n "$src" ]; then
    files="$(git -C "$GIT_CWD" diff --name-only "HEAD...${src}" 2>/dev/null || true)"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      for pat in "${SECRET_PATH_PATTERNS[@]}"; do
        if printf '%s' "$f" | grep -Eiq "$pat"; then
          deny "merge-gate:secret-path" "$pat" "$f"
        fi
      done
    done <<EOF
$files
EOF
  fi
  return 0
}

# `git rebase` is a SOFT gate (ADR 0006): allowed only at full-autonomy, and only
# when rebasing a NON-main branch. Interactive rebase (`-i`) rewrites history and
# stays a hard gate at every level. Below full-autonomy this denies as before.
check_rebase_policy() {
  local cmd="$1"
  if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]])(-i|--interactive)([^[:alnum:]]|$)'; then
    deny "git-history-rewrite" "rebase --interactive" "$cmd"
  fi
  if [ "$(autonomy_rank "$ORCH_AUTONOMY")" -lt "$(autonomy_rank full-autonomy)" ]; then
    deny "rebase-gate:autonomy" "autonomy=${ORCH_AUTONOMY} (needs full-autonomy)" "$cmd"
  fi
  resolve_branch_or_deny rebase-gate:branch "$cmd"
  case "$CURRENT_BRANCH" in
    main|master) deny "rebase-gate:branch" "rebase of protected branch '${CURRENT_BRANCH}'" "$cmd" ;;
  esac
  return 0
}

# `git push` is a SOFT gate (ADR 0006): allowed only at full-autonomy, only for a
# NON-main target, and never forced. Pushing main/master (or a forced push) stays
# a hard gate at every level. Below full-autonomy this denies as before. Fails
# CLOSED when the target ref cannot be determined.
check_push_policy() {
  local cmd="$1"
  # Forced push is history destruction on the remote — deny at every level.
  # (The DENY_BASH_PATTERNS `--force` rule catches most of these first; this is a
  #  belt-and-suspenders check that also covers `-f` / `--force-with-lease`.)
  if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]])(--force([^[:alnum:]]|$)|--force-with-lease|-[[:alnum:]]*f[[:alnum:]]*([[:space:]]|$))'; then
    deny "push-gate:force" "forced push" "$cmd"
  fi
  if [ "$(autonomy_rank "$ORCH_AUTONOMY")" -lt "$(autonomy_rank full-autonomy)" ]; then
    deny "push-gate:autonomy" "autonomy=${ORCH_AUTONOMY} (needs full-autonomy)" "$cmd"
  fi
  # Explicit main/master target anywhere in the refspec (e.g. `push origin main`,
  # `push origin HEAD:main`, `push origin develop main`) -> deny.
  if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]/])(main|master)([^[:alnum:]/]|$)'; then
    deny "push-gate:target" "push targets protected branch (main/master)" "$cmd"
  fi
  # No explicit ref -> a bare `git push` pushes the current branch's upstream.
  # Deny if the current branch is main/master; fail closed if undetectable.
  if printf '%s' "$cmd" | grep -Eq "${GIT_PREFIX}push([[:space:]]*(-[^[:space:]]+[[:space:]]*)*)?\$"; then
    resolve_branch_or_deny push-gate:target "$cmd"
    case "$CURRENT_BRANCH" in
      main|master) deny "push-gate:target" "bare push of protected branch '${CURRENT_BRANCH}'" "$cmd" ;;
    esac
  fi
  return 0
}

# Does the command (on stdin) invoke `git <subcommand>`? Tolerates `-c`/`-C` flags
# between `git` and the subcommand via GIT_PREFIX. Used to route the git soft gates.
# The trailing boundary EXCLUDES `-` (ADR 0014 §6): otherwise `grep_Eq_git merge`
# fires on the read-only plumbing command `git merge-base` (and merge-tree/-file,
# commit-tree), routing it into the merge soft-gate and denying it below
# full-autonomy. A real subcommand is followed by whitespace, EOL, or a separator —
# never a hyphen — so `git merge orch/x` still routes while `git merge-base` does not.
grep_Eq_git() { grep -Eq "${GIT_PREFIX}$1([^[:alnum:]-]|\$)"; }

# Determine the directory a git command will actually operate in, and expose it as
# GIT_CWD (defaults to PROJECT_DIR). The payload `cwd` is only where the harness
# THINKS we are: a command can target another tree with a leading `cd <dir> &&` or
# git's global `git -C <dir>`. If such a command were judged against `cwd`'s branch
# instead of the tree it actually names, a commit/merge into a DIFFERENT checkout
# (another clone, a submodule, any second repo) would dodge the branch gate — e.g.
# `git -C /other commit` from a cwd on a feature branch reads as a safe commit even
# if it targets `main`. Honoring the tree the command names closes that bypass in
# both directions. Only the GLOBAL `git -C` (before the subcommand) is treated as a
# directory — `git commit -C <ref>` reuses a message and must not be mistaken for a
# path. Config (autonomy, ceiling, guard-extra) resolves from CONFIG_ROOTS instead:
# the tree a command TARGETS and the project whose rules bind it are independent.
GIT_CWD="$SHELL_CWD"
_unquote() { local s="$1"; s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"; printf '%s' "$s"; }
resolve_git_dir() {
  local cmd="$1" base="$SHELL_CWD" tok
  # (1) leading `cd <dir> &&` / `cd <dir>;` — the shell moves before git runs.
  tok="$(printf '%s' "$cmd" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:];&|]+).*/\1/p")"
  if [ -n "$tok" ]; then
    tok="$(_unquote "$tok")"
    case "$tok" in /*) base="$tok" ;; *) base="${SHELL_CWD%/}/$tok" ;; esac
  fi
  # (2) `git [-c k=v]* -C <dir>` — git's own global flag; authoritative. Anchored to
  #     the git-global position so `git commit -C <ref>` cannot match. Last wins.
  tok="$(printf '%s' "$cmd" \
    | grep -oE "(^|[^[:alnum:]])git([[:space:]]+-c[[:space:]]+[^[:space:]]+)*[[:space:]]+-C[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:];&|]+)" \
    | tail -n1 | sed -E 's/^.*-C[[:space:]]+//' || true)"
  if [ -n "$tok" ]; then
    tok="$(_unquote "$tok")"
    case "$tok" in /*) base="$tok" ;; *) base="${base%/}/$tok" ;; esac
  fi
  if [ -d "$base" ]; then GIT_CWD="$base"; else GIT_CWD="$SHELL_CWD"; fi
}

case "$TOOL" in
  Bash)
    CMD="$(json_field "$INPUT" tool_input command)"
    # A Bash call always has a command -> empty means unreadable, not absent.
    [ -n "${CMD:-}" ] || deny_unreadable "tool_input.command"
    # (0) read-only fast-path: allow unambiguous searches/inspection immediately,
    #     so grepping FOR a risky string isn't mistaken for RUNNING it. Runs BEFORE
    #     any config-root discovery or autonomy resolution (the expensive per-call
    #     work): the common case — grep/ls/cat/git status — pays none of it. Its
    #     matching uses only the static lists above, so nothing here needs the
    #     per-repo config we skip.
    if is_read_only "$CMD"; then
      exit 0
    fi
    # Not read-only: NOW resolve per-repo config (the guard-extra unions the
    # hard-deny / SECRET / REVIEW matching below depends on).
    discover_config
    # (a) HARD-DENY commands (irreversible / never-appropriate).
    for pat in "${DENY_BASH_PATTERNS[@]}"; do
      if printf '%s' "$CMD" | grep -Eq "$pat"; then
        deny "risky-bash" "$pat" "$CMD"
      fi
    done
    # git soft gates (commit/merge/rebase/push). Only these consult the autonomy
    # level and the target tree, so resolve both LAZILY behind a cheap prefilter —
    # a non-git write (deps, deploys, file edits) never pays for autonomy
    # resolution or tree resolution.
    if printf '%s' "$CMD" | grep -Eq "${GIT_PREFIX}(commit|merge|rebase|push)([^[:alnum:]-]|\$)"; then
      ensure_autonomy
      # Resolve which tree the git soft gates should inspect (the tree the command
      # actually names via `cd`/`git -C`, not just the payload cwd).
      resolve_git_dir "$CMD"
      # (a2) git commit — soft gate, delegable above `interactive` (ADR 0004).
      if printf '%s' "$CMD" | grep_Eq_git commit; then
        check_commit_policy "$CMD"
      fi
      # (a3) git merge / rebase / push — soft gates, delegable only at
      #      full-autonomy and only onto NON-main targets (ADR 0006).
      if printf '%s' "$CMD" | grep_Eq_git merge; then
        check_merge_policy "$CMD"
      fi
      if printf '%s' "$CMD" | grep_Eq_git rebase; then
        check_rebase_policy "$CMD"
      fi
      if printf '%s' "$CMD" | grep_Eq_git push; then
        check_push_policy "$CMD"
      fi
    fi
    # (b) shell writes to a guarded path. A write to a SECRET path HARD-DENIES
    #     (exposure floor); a write to a REVIEW path ASKS (one-click). SECRET is
    #     checked first so the deny always wins (ADR 0014).
    for wp in "${BASH_WRITE_PATTERNS[@]}"; do
      if printf '%s' "$CMD" | grep -Eq "$wp"; then
        if cmd_hits_path "$CMD" "${SECRET_PATH_PATTERNS[@]}"; then
          deny "secret-path-via-bash" "$MATCHED_SENSITIVE" "$CMD"
        # Driver mode (ADR 0028 T5): checked after the secret floor, before the
        # REVIEW ask below. The command is sanitized (quotes/heredoc body/
        # comments blanked, benign /dev/null and fd-dup redirects removed)
        # before it is re-matched and its write targets extracted, so a
        # commit message, heredoc body or quoted arg that merely CONTAINS a
        # write-shaped word never trips this. Every extracted target must
        # anchor inside .agents/ or resolve outside the driven repository
        # altogether (it cannot reach a packet's commit there); an unrecognised
        # write shape (no target could be determined) or a dangerous construct
        # ($( ` eval xargs sh -c) refuses conservatively rather than guessing.
        elif driver_mode_active && _driver_mode_bash_refuses "$CMD"; then
          deny "driver-mode-via-bash" "session ${SESSION_ID} is in driver mode (no agent_id)" "$CMD"
        elif cmd_hits_path "$CMD" "${REVIEW_PATH_PATTERNS[@]}"; then
          ask "review-path-via-bash" "$MATCHED_SENSITIVE" "$CMD"
        fi
        break
      fi
    done
    # (c) ASK tier: routine-but-notable (deps, migrations, deploys) -> native
    #     one-click prompt. Runs LAST so any hard deny above takes precedence.
    for pat in "${ASK_BASH_PATTERNS[@]}"; do
      if printf '%s' "$CMD" | grep -Eq "$pat"; then
        ask "risky-bash-confirm" "$pat" "$CMD"
      fi
    done
    ;;
  Edit|Write|MultiEdit|NotebookEdit)
    # Different tools name the path differently; try the common keys.
    PATH_VAL="$(json_field "$INPUT" tool_input file_path)"
    [ -z "${PATH_VAL:-}" ] && PATH_VAL="$(json_field "$INPUT" tool_input notebook_path)"
    [ -z "${PATH_VAL:-}" ] && PATH_VAL="$(json_field "$INPUT" tool_input path)"
    # An edit tool always names a target -> empty means unreadable, not absent.
    [ -n "${PATH_VAL:-}" ] || deny_unreadable "tool_input.file_path"
    # Path writes need the guard-extra SECRET/REVIEW unions (autonomy is irrelevant
    # here — SECRET hard-denies and REVIEW asks at every level), so resolve config
    # but not autonomy.
    discover_config
    # Match on a SEPARATOR-NORMALIZED copy. Every pattern here — built-in and
    # per-repo alike — spells path segments with `/`, but on Windows the harness
    # hands us `C:\Users\me\repo\.env`, where `(^|/)\.env(\.|$)` has no `/` to
    # anchor on and simply does not match: the single most important SECRET rule
    # was inert on Windows even with a perfectly working jq (verified exit 0).
    # Normalizing can only ever ADD matches, so it fails closed. The ORIGINAL
    # spelling is what gets reported, so the message still names the real target.
    PATH_MATCH="${PATH_VAL//\\//}"
    # SECRET first -> HARD DENY (irreversible exposure); else REVIEW -> ASK
    # (one-click prompt for reversible, review-worthy code/config). ADR 0014.
    for pat in "${SECRET_PATH_PATTERNS[@]}"; do
      if printf '%s' "$PATH_MATCH" | grep -Eiq "$pat"; then
        deny "secret-path" "$pat" "$PATH_VAL"
      fi
    done
    # Driver mode (ADR 0028 T5): after the secret floor, before the REVIEW ask.
    # Anchored, not a substring test -- _driver_mode_path_ok rejects a ".."
    # segment, admits an absolute path either under a discovered config root's
    # .agents/ or resolving outside every root (it cannot reach a packet's
    # commit), and requires a relative path's cwd to BE that root.
    if driver_mode_active && ! _driver_mode_path_ok "$PATH_VAL"; then
      deny "driver-mode" "session ${SESSION_ID} is in driver mode (no agent_id)" "$PATH_VAL"
    fi
    for pat in "${REVIEW_PATH_PATTERNS[@]}"; do
      if printf '%s' "$PATH_MATCH" | grep -Eiq "$pat"; then
        ask "review-path" "$pat" "$PATH_VAL"
      fi
    done
    ;;
esac

# No rule matched -> allow.
exit 0
