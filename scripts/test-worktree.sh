#!/usr/bin/env bash
# =============================================================================
# test-worktree.sh — regression sweep for scripts/worktree.sh (ADR 0016)
# =============================================================================
# Mirrors test-guard.sh: builds throwaway git repos, drives worktree.sh through
# the create/list/remove/discard lifecycle, and asserts the safety gates hold.
# The full guard-inside-a-worktree matrix (SECRET deny / auth ASK per ADR 0014,
# and the ORCH_AUTONOMY-in-worktree commit case) lives in test-guard.sh; here we
# keep a small smoke-check that the guard still fires from a worktree cwd.
#
# Run:  scripts/test-worktree.sh   (exit 0 = all passed, 1 = a case failed)
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WT="${HERE}/worktree.sh"
GUARD="${HERE}/../hooks/guard.sh"

pass=0; fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

# assert_exit <want> <desc> <cmd...>
assert_exit() {
  local want="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then ok "(exit $got) $desc"; else bad "(want $want, got $got) $desc"; fi
}
assert_true()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
assert_false() { if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }

# --- throwaway repo (realpath so paths match git's stored worktree paths) -----
REPO="$(cd "$(mktemp -d)" && pwd -P)"
WTROOT="$(dirname "$REPO")/$(basename "$REPO")-worktrees"
REPO2="$(cd "$(mktemp -d)" && pwd -P)"
WTROOT2="$(dirname "$REPO2")/$(basename "$REPO2")-worktrees"
cleanup() { rm -rf "$REPO" "$WTROOT" "$REPO2" "$WTROOT2"; }
trap cleanup EXIT

git -c init.defaultBranch=main init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  tester
mkdir -p "$REPO/.agents" "$REPO/src"
# a committed guard-extra rule — the worktree inherits it via its own checkout.
printf '(^|/)src/critical/\n' > "$REPO/.agents/guard-extra-paths"
printf 'hello\n' > "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"
MAIN_SHA="$(git -C "$REPO" rev-parse main)"

# run worktree.sh from inside the repo
wt() { ( cd "$REPO" && "$WT" "$@" ); }
main_clean() { [ -z "$(git -C "$REPO" status --porcelain)" ]; }

echo "== create + list =="
assert_exit 0 "create feature-a"                 wt create feature-a
assert_true  "worktree dir exists"               "[ -d '$WTROOT/feature-a' ]"
assert_true  "branch orch/feature-a exists"      "git -C '$REPO' show-ref --verify --quiet refs/heads/orch/feature-a"
assert_true  "worktree HEAD is orch/feature-a"   "[ \"\$(git -C '$WTROOT/feature-a' symbolic-ref --short HEAD)\" = orch/feature-a ]"
assert_true  "main tree clean after create"      "main_clean"
assert_true  "list shows feature-a"              "wt list | grep -q feature-a"

echo "== create is idempotent =="
assert_exit 0 "create feature-a again"           wt create feature-a

echo "== reject bad task-ids =="
assert_exit 1 "reject empty id"                  wt create ""
assert_exit 1 "reject non-kebab id"              wt create Feature_A

echo "== remove refuses on unmerged committed work =="
wt create feature-b >/dev/null 2>&1
printf 'work\n' > "$WTROOT/feature-b/newfile.txt"
git -C "$WTROOT/feature-b" add -A
git -C "$WTROOT/feature-b" commit -qm "unmerged work"
assert_exit 1 "remove refuses (1 unmerged commit)" wt remove feature-b
assert_true  "worktree survived the refusal"       "[ -d '$WTROOT/feature-b' ]"
assert_true  "main tree untouched by refusal"      "main_clean"
assert_true  "list flags it ahead:1"               "wt list | grep -q 'ahead:1'"

echo "== diff shows the review diff (base...HEAD) =="
assert_true  "diff includes the committed new file" "wt diff feature-b | grep -q newfile.txt"
assert_exit 1 "diff refuses unknown task-id"        wt diff nope-nope

echo "== discard resets to a given green commit =="
printf 'scratch\n' > "$WTROOT/feature-b/scratch.txt"   # uncommitted scratch too
assert_exit 0 "discard feature-b to MAIN_SHA"      wt discard feature-b "$MAIN_SHA"
assert_true  "worktree HEAD == green sha"          "[ \"\$(git -C '$WTROOT/feature-b' rev-parse HEAD)\" = '$MAIN_SHA' ]"
assert_true  "worktree clean after discard"        "[ -z \"\$(git -C '$WTROOT/feature-b' status --porcelain)\" ]"
assert_true  "scratch file gone"                   "[ ! -f '$WTROOT/feature-b/scratch.txt' ]"
assert_true  "main tree untouched by discard"      "main_clean"

echo "== remove a clean/merged worktree =="
# feature-b now points at MAIN_SHA -> fully merged -> safe to remove.
assert_exit 0 "remove merged feature-b"            wt remove feature-b
assert_true  "worktree dir gone"                   "[ ! -d '$WTROOT/feature-b' ]"
assert_true  "branch orch/feature-b deleted"       "! git -C '$REPO' show-ref --verify --quiet refs/heads/orch/feature-b"

echo "== never operate on the primary worktree =="
# point the worktrees root at the repo's PARENT so <basename> resolves to the
# primary checkout itself, then confirm the guard refuses.
PRIMARY_ID="$(basename "$REPO")"
assert_exit 1 "remove refuses primary" \
  env ORCH_WORKTREES_ROOT="$(dirname "$REPO")" bash -c "cd '$REPO' && '$WT' remove '$PRIMARY_ID'"

echo "== guard.sh still fires from a linked worktree cwd (smoke) =="
wt create guard-check >/dev/null 2>&1
WTP="$WTROOT/guard-check"
guard_call() { printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$WTP" "$1" | "$GUARD"; }
assert_exit 2 "SECRET path (.env) denied from worktree cwd"        guard_call ".env"
assert_exit 2 "committed guard-extra (src/critical) fires in worktree" guard_call "src/critical/x.ts"
assert_exit 0 "ordinary path allowed from worktree cwd"            guard_call "src/util.ts"

echo "== base-branch detection honors integration_branch (ADR 0009/0016) =="
git -c init.defaultBranch=main init -q "$REPO2"
git -C "$REPO2" config user.email t@example.com
git -C "$REPO2" config user.name  tester
mkdir -p "$REPO2/.agents"
printf 'integration_branch: develop\n' > "$REPO2/.agents/project-overrides.yaml"
printf 'x\n' > "$REPO2/README.md"; git -C "$REPO2" add -A; git -C "$REPO2" commit -qm init
git -C "$REPO2" branch develop
git -C "$REPO2" switch -q develop
printf 'y\n' >> "$REPO2/README.md"; git -C "$REPO2" commit -qam "develop-only work"
DEV_SHA="$(git -C "$REPO2" rev-parse develop)"
wt2() { ( cd "$REPO2" && env ORCH_WORKTREES_ROOT="$WTROOT2" "$WT" "$@" ); }
wt2 create lane-x >/dev/null 2>&1
assert_true "lane cut from develop tip (integration_branch)" \
  "[ \"\$(git -C '$WTROOT2/lane-x' rev-parse HEAD)\" = '$DEV_SHA' ]"
# explicit override wins over the file.
git -C "$REPO2" branch feature-base main
wt2b() { ( cd "$REPO2" && env ORCH_WORKTREES_ROOT="$WTROOT2" ORCH_BASE_BRANCH=feature-base "$WT" "$@" ); }
wt2b create lane-y >/dev/null 2>&1
assert_true "ORCH_BASE_BRANCH override wins over integration_branch" \
  "[ \"\$(git -C '$WTROOT2/lane-y' rev-parse HEAD)\" = \"\$(git -C '$REPO2' rev-parse feature-base)\" ]"

echo
echo "-----------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
