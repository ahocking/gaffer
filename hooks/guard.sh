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
#   - No jq dependency required: uses jq if present, else python3, else a
#     best-effort grep/sed fallback. Matching is done on the extracted command
#     / file path so it works even without a JSON parser.
#   - Fails OPEN (exit 0) only if it cannot determine the tool at all, so a
#     malformed payload never bricks normal use. Risk matching itself fails
#     CLOSED: if a pattern matches, we always deny.
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

INPUT="$(cat)"

# --- extract a JSON string field, best-effort (jq -> python3 -> grep/sed) ---
json_field() {
  # $1 = raw json, $2..$n = key path (e.g. tool_input command)
  local raw="$1"; shift
  if command -v jq >/dev/null 2>&1; then
    local filter="."
    local k
    for k in "$@"; do filter="${filter}[\"${k}\"]?"; done
    printf '%s' "$raw" | jq -r "${filter} // empty" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$raw" | KEYS="$*" python3 -c '
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
' 2>/dev/null && return 0
  fi
  # Fallback: grab the last key in the path via grep/sed (shallow, best-effort).
  local last="${!#}"
  printf '%s' "$raw" \
    | grep -oE "\"${last}\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\"" \
    | head -n1 \
    | sed -E "s/^\"${last}\"[[:space:]]*:[[:space:]]*\"//; s/\"$//"
}

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
read_autonomy_file() {   # $1 = a config root
  local f="${1}/.agents/autonomy"
  [ -f "$f" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null \
    | tail -n1 | sed -E 's/[[:space:]]*#.*$//' \
    | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
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

# Can't tell what tool this is -> allow (fail open on unparseable envelope).
if [ -z "${TOOL:-}" ]; then
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
  local pat rpat
  for pat in "$@"; do
    # Relax a leading `(^|/)` anchor to any word boundary (a path token in a
    # command is preceded by whitespace/quote/`=`, not just `/`), and relax a
    # trailing `$` anchor so a path followed by more command text still matches.
    rpat="${pat/#(^|\/)/(^|[^[:alnum:]])}"
    rpat="${rpat/%\$/($|[^[:alnum:]])}"
    if printf '%s' "$cmd" | grep -Eiq "$rpat"; then
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
  esac
  echo "If this is intended, approve it explicitly (or run it yourself)." >&2
  exit 2
}

# JSON-encode a string (for permissionDecisionReason). jq -> python3 -> minimal
# fallback, mirroring json_field's dependency ladder.
json_string() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -Rs . && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$s" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' && return 0
  fi
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
    *'>'*|*'<'*|*'`'*|*'$'*|*';'*|*'&'*) return 1 ;;
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
    [ -z "${CMD:-}" ] && exit 0
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
    [ -z "${PATH_VAL:-}" ] && exit 0
    # Path writes need the guard-extra SECRET/REVIEW unions (autonomy is irrelevant
    # here — SECRET hard-denies and REVIEW asks at every level), so resolve config
    # but not autonomy.
    discover_config
    # SECRET first -> HARD DENY (irreversible exposure); else REVIEW -> ASK
    # (one-click prompt for reversible, review-worthy code/config). ADR 0014.
    for pat in "${SECRET_PATH_PATTERNS[@]}"; do
      if printf '%s' "$PATH_VAL" | grep -Eiq "$pat"; then
        deny "secret-path" "$pat" "$PATH_VAL"
      fi
    done
    for pat in "${REVIEW_PATH_PATTERNS[@]}"; do
      if printf '%s' "$PATH_VAL" | grep -Eiq "$pat"; then
        ask "review-path" "$pat" "$PATH_VAL"
      fi
    done
    ;;
esac

# No rule matched -> allow.
exit 0
