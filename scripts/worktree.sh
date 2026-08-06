#!/usr/bin/env bash
# =============================================================================
# worktree.sh — per-lane git worktree isolation for PARALLEL orchestration
# =============================================================================
# Gives each concurrent packet lane its own directory + branch so parallel
# specialists never collide with each other or with the user's main checkout.
# Used ONLY by the `--parallel` loop mode (ADR 0016); the default sequential
# loop stays single-checkout (ADR 0009). See docs/adr/0016-parallel-worktree-lanes.md.
#
# Layout (settled decision, ADR 0016 / phase-3 plan):
#   - Worktrees live in a SIBLING directory of the primary checkout:
#         <parent>/<repo-name>-worktrees/<task-id>
#     so worktree files never appear inside the main tree (nothing to gitignore,
#     no risk of editing the wrong copy). Override with $ORCH_WORKTREES_ROOT.
#   - Each lane is on branch  orch/<task-id>  (greppable; lets cleanup and the
#     guardrail reason about orchestration branches).
#   - The base branch is the INTEGRATION branch, resolved (never hardcoded):
#         $ORCH_BASE_BRANCH  >  project-overrides integration_branch  >  develop
#         >  origin/HEAD  >  main/master  >  the primary's current branch.
#     The driver passes $ORCH_BASE_BRANCH so a dependent lane is cut from the
#     integration tip AFTER its dependencies were merged in (ADR 0016).
#
# Subcommands:
#   create  <task-id>            create orch/<task-id> off the base branch and add
#                                a worktree. Idempotent (exit 0 if it exists).
#   list                         list orchestration worktrees + branch + state.
#   remove  <task-id>            remove ONLY if clean and merged; else refuse and
#                                explain (safety gate — never lose unmerged work).
#   discard <task-id> [ref] [--remove]
#                                lane-local throw-away: `git reset --hard` the
#                                worktree to <ref> (default HEAD — drop uncommitted
#                                scratch only) + clean untracked, optionally remove.
#                                Destructive BY DESIGN and contained to the throwaway
#                                lane — it never touches the user's main checkout.
#   path    <task-id>            print the worktree path (for cd-ing into).
#   diff    <task-id>            print the review diff (<base>...HEAD) for the lane.
#
# Safety rules baked in:
#   - Never operates on the primary worktree (refuses if a path resolves to it).
#   - Never --force past uncommitted changes EXCEPT under `discard`.
#   - `remove` refuses when the branch has commits not reachable from the base
#     branch — losing an unreviewed green checkpoint is the failure mode to stop.
#   - Runs `git worktree prune` opportunistically to clear stale metadata.
#
# NOTE on the guard: an agent types `worktree.sh discard …`, NOT `git reset --hard`,
# so the guard gates the sanctioned verb, not a raw history-destroying command — and
# the reset only ever hits the isolated lane. This is the contained discard path
# ADR 0016 reintroduces on top of ADR 0009's single-checkout `git stash` default.
#
# Exit codes: 0 = success, non-zero = refused / error (stderr explains why).
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Config — the small amount of policy lives here.
# -----------------------------------------------------------------------------
BRANCH_PREFIX="orch/"          # orchestration branch namespace

usage() {
  sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'worktree.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

# Must be inside a git repo to do anything.
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

# --- primary worktree = the first entry of `git worktree list --porcelain` ----
# (substr avoids splitting paths that contain spaces).
main_worktree() {
  git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}'
}

REPO_ROOT="$(main_worktree)"
REPO_NAME="$(basename "$REPO_ROOT")"
REPO_PARENT="$(dirname "$REPO_ROOT")"
WORKTREES_ROOT="${ORCH_WORKTREES_ROOT:-${REPO_PARENT}/${REPO_NAME}-worktrees}"

# --- read the repo's declared integration branch (ADR 0009/0016) --------------
read_integration_branch() {
  local f="${REPO_ROOT}/.agents/project-overrides.yaml" v
  [ -f "$f" ] || return 0
  v="$(grep -E '^[[:space:]]*integration_branch:' "$f" 2>/dev/null | head -1 \
       | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]*$//')"
  printf '%s' "$v"
}

# --- detect the base branch to fork lanes from (never hardcode main) ----------
# The integration branch is the base: the loop cuts orch/<task-id> FROM it and, at
# full-autonomy, merges lanes back INTO it (ADR 0006/0016). The driver may pin it
# via $ORCH_BASE_BRANCH so a dependent lane forks from the tip that already has its
# integrated dependencies.
default_branch() {
  local ref b v
  if [ -n "${ORCH_BASE_BRANCH:-}" ]; then printf '%s\n' "$ORCH_BASE_BRANCH"; return 0; fi
  v="$(read_integration_branch)"
  if [ -n "$v" ] && git show-ref --verify --quiet "refs/heads/${v}"; then printf '%s\n' "$v"; return 0; fi
  if git show-ref --verify --quiet "refs/heads/develop"; then printf 'develop\n'; return 0; fi
  if ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref#origin/}"; return 0
  fi
  for b in main master; do
    if git show-ref --verify --quiet "refs/heads/${b}"; then printf '%s\n' "$b"; return 0; fi
  done
  git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || die "cannot determine a base branch"
}

validate_id() {
  local id="${1:-}"
  [ -n "$id" ] || die "task-id required"
  printf '%s' "$id" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' \
    || die "invalid task-id '$id': must be kebab-case ([a-z0-9], single hyphens)"
}

# A registered, live git worktree at $1?
worktree_dir_active() {
  [ -d "$1" ] && git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Refuse if $1 resolves to the primary checkout.
refuse_if_primary() {
  local p="$1" rp mp
  rp="$(cd "$p" 2>/dev/null && pwd -P || printf '%s' "$p")"
  mp="$(cd "$REPO_ROOT" && pwd -P)"
  [ "$rp" != "$mp" ] || die "refusing: '$p' is the primary worktree — never operate on it"
}

# Count commits on <branch> not reachable from the base branch.
unmerged_count() {
  local path="$1" base
  base="$(default_branch)"
  git -C "$path" rev-list --count "${base}..HEAD" 2>/dev/null || echo "?"
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
cmd_create() {
  validate_id "${1:-}"
  local id="$1" branch="${BRANCH_PREFIX}${1}" path="${WORKTREES_ROOT}/$1"
  git worktree prune
  if worktree_dir_active "$path"; then
    echo "worktree already exists: ${path} (branch ${branch})"; return 0
  fi
  refuse_if_primary "$path"
  local base; base="$(default_branch)"
  mkdir -p "$WORKTREES_ROOT"
  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    # branch already exists (e.g. resuming) — attach a worktree to it.
    git worktree add "$path" "$branch"
  else
    git worktree add -b "$branch" "$path" "$base"
  fi
  echo "created worktree ${path} on ${branch} (base ${base})"
}

cmd_list() {
  git worktree prune
  printf '%-24s %-26s %-10s %s\n' "TASK-ID" "BRANCH" "STATE" "PATH"
  local wt="" br=""
  emit() {
    local p="$1" b="$2" id state ahead
    case "$b" in "${BRANCH_PREFIX}"*) ;; *) return ;; esac
    id="${b#${BRANCH_PREFIX}}"
    if [ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]; then
      state="dirty"
    else
      ahead="$(unmerged_count "$p")"
      if [ "$ahead" = "0" ]; then state="merged"; else state="ahead:${ahead}"; fi
    fi
    printf '%-24s %-26s %-10s %s\n' "$id" "$b" "$state" "$p"
  }
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }" ;;
      "branch "*)   br="${line#branch refs/heads/}" ;;
      "detached")   br="(detached)" ;;
      "")           [ -n "$wt" ] && emit "$wt" "$br"; wt=""; br="" ;;
    esac
  done < <(git worktree list --porcelain)
  [ -n "$wt" ] && emit "$wt" "$br"
  return 0
}

cmd_remove() {
  validate_id "${1:-}"
  local id="$1" branch="${BRANCH_PREFIX}${1}" path="${WORKTREES_ROOT}/$1"
  git worktree prune
  worktree_dir_active "$path" || die "no worktree for '${id}' at ${path}"
  refuse_if_primary "$path"
  if [ -n "$(git -C "$path" status --porcelain)" ]; then
    die "refusing: worktree '${id}' has uncommitted changes — use 'discard ${id}' to throw scratch away"
  fi
  local base ahead; base="$(default_branch)"; ahead="$(unmerged_count "$path")"
  if [ "$ahead" != "0" ]; then
    printf 'worktree.sh: refusing: branch %s has %s unmerged commit(s) not in %s.\n' \
      "$branch" "$ahead" "$base" >&2
    printf "  merge them, or run 'discard %s <green-ref> --remove' to throw them away.\n" "$id" >&2
    exit 1
  fi
  git worktree remove "$path"
  git branch -d "$branch" 2>/dev/null || true   # fully merged -> safe delete
  git worktree prune
  echo "removed worktree '${id}' (branch ${branch} was merged into ${base})"
}

cmd_discard() {
  validate_id "${1:-}"
  local id="$1" branch="${BRANCH_PREFIX}${1}" path="${WORKTREES_ROOT}/$1"
  shift
  local green="" do_remove=0 a
  for a in "$@"; do
    case "$a" in
      --remove) do_remove=1 ;;
      -*)       die "unknown flag '$a'" ;;
      *)        green="$a" ;;
    esac
  done
  git worktree prune
  worktree_dir_active "$path" || die "no worktree for '${id}' at ${path}"
  refuse_if_primary "$path"
  local target="${green:-HEAD}"
  git -C "$path" rev-parse --verify --quiet "${target}^{commit}" >/dev/null \
    || die "refusing: '${target}' is not a valid commit in worktree '${id}'"
  git -C "$path" reset --hard "$target"
  git -C "$path" clean -fd
  echo "discarded worktree '${id}' to ${target}"
  if [ "$do_remove" = 1 ]; then
    # explicit throw-away: force past the (now intentional) branch/worktree state.
    git worktree remove --force "$path"
    git branch -D "$branch" 2>/dev/null || true
    git worktree prune
    echo "removed worktree '${id}'"
  fi
}

cmd_path() {
  validate_id "${1:-}"
  local path="${WORKTREES_ROOT}/$1"
  worktree_dir_active "$path" || die "no worktree for '$1' at ${path}"
  printf '%s\n' "$path"
}

# Review diff for the reviewer: what orch/<task-id> adds on top of the base
# branch (three-dot = from the merge-base, i.e. "what would merge").
cmd_diff() {
  validate_id "${1:-}"
  local path="${WORKTREES_ROOT}/$1" base
  worktree_dir_active "$path" || die "no worktree for '$1' at ${path}"
  base="$(default_branch)"
  if [ -n "$(git -C "$path" status --porcelain)" ]; then
    echo "worktree.sh: note: worktree '$1' has uncommitted changes NOT in this diff" >&2
  fi
  git -C "$path" diff "${base}...HEAD"
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
cmd="${1:-}"; [ "$#" -gt 0 ] && shift || true
case "$cmd" in
  create)  cmd_create  "$@" ;;
  list)    cmd_list    "$@" ;;
  remove)  cmd_remove  "$@" ;;
  discard) cmd_discard "$@" ;;
  path)    cmd_path    "$@" ;;
  diff)    cmd_diff    "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown subcommand '${cmd}' (try --help)" ;;
esac
