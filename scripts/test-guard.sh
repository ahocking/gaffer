#!/usr/bin/env bash
# =============================================================================
# test-guard.sh — regression sweep for hooks/guard.sh
# =============================================================================
# The guardrail is the one safety-critical component here, so its behavior is
# pinned by tests rather than a manual sweep. Each case feeds a tool-call
# envelope to guard.sh and asserts the exit code (0 = allow, 2 = deny).
#
# Run:  scripts/test-guard.sh   (exit 0 = all passed, 1 = a case failed)
# When you add a risky pattern to guard.sh, add a deny case AND a benign allow
# case here so regressions are obvious.
# =============================================================================

set -uo pipefail

# Hermetic: don't let a developer's shell env change the resolved autonomy level.
# The commit-gate cases set ORCH_AUTONOMY explicitly per case.
unset ORCH_AUTONOMY 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="${HERE}/../hooks/guard.sh"

# Also pin CLAUDE_PROJECT_DIR and $PWD (resolved AFTER computing HERE/GUARD
# above, so this repo's own path stays known). The config-root walk (added
# below in guard.sh) discovers roots from BOTH the payload cwd AND
# $PWD/CLAUDE_PROJECT_DIR: a suite run from inside a consumer repo would
# otherwise inherit that repo's own `.agents/*` (autonomy, guard-extra-*) for
# every no-cwd payload, silently widening or narrowing what's under test
# depending on where the suite happens to run from. Confirmed empirically: from
# a neutral cwd the suite is 109/109 green; run from inside a repo declaring
# full-autonomy it drops to 106/3, with the 3 failures being `git commit` cases
# that get ALLOWED (exit 0, want 2) because they inherit that repo's autonomy.
# Pin both so the suite's result cannot depend on where it is invoked from.
unset CLAUDE_PROJECT_DIR 2>/dev/null || true
cd "$(mktemp -d)"

pass=0; fail=0

# check <expected-exit> <description> <json-payload>
check() {
  local want="$1" desc="$2" payload="$3" got
  printf '%s' "$payload" | "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   (exit %s) %s\n' "$got" "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL (want %s, got %s) %s\n' "$want" "$got" "$desc"
    fail=$((fail + 1))
  fi
}

# check_ask <description> <json-payload>: asserts the ASK tier — exit 0 AND a
# PreToolUse permissionDecision=ask on stdout (the native one-click prompt).
check_ask() {
  local desc="$1" payload="$2" out got
  out="$(printf '%s' "$payload" | "$GUARD" 2>/dev/null)"; got=$?
  if [ "$got" = 0 ] && printf '%s' "$out" | grep -q '"permissionDecision":[[:space:]]*"ask"'; then
    printf 'ok   (ask)     %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL (want ask, got exit %s) %s\n' "$got" "$desc"; fail=$((fail + 1))
  fi
}

bash_call()  { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1"; }
edit_call()  { printf '{"tool_name":"Edit","tool_input":{"file_path":%s}}' "$1"; }

echo "== hard-deny bash: deny (exit 2) =="
check 2 "git commit"                 "$(bash_call '"git commit -m x"')"
check 2 "git push"                   "$(bash_call '"git push origin main"')"
check 2 "git -C . commit (flag bypass)" "$(bash_call '"git -C . commit -m x"')"
check 2 "git -c user.name=x commit"  "$(bash_call '"git -c user.name=x commit -m x"')"
check 2 "git push --force"           "$(bash_call '"git push --force"')"
check 2 "rm -rf"                     "$(bash_call '"rm -rf build"')"
check 2 "find -delete"               "$(bash_call '"find . -name *.tmp -delete"')"

echo "== ask tier: routine-but-notable (exit 0 + permissionDecision=ask) =="
# Moved OUT of hard-deny: these are dev-routine, so the guard now surfaces a
# one-click prompt instead of a dead end. See ADR 0008.
check_ask "npm install"               "$(bash_call '"npm install left-pad"')"
check_ask "pip install"               "$(bash_call '"pip3 install requests"')"
check_ask "dotnet ef database update" "$(bash_call '"dotnet ef database update"')"
check_ask "terraform apply"           "$(bash_call '"terraform apply"')"
check_ask "kubectl apply"             "$(bash_call '"kubectl apply -f x.yaml"')"
check_ask "gcloud app deploy"         "$(bash_call '"gcloud app deploy"')"
check_ask "aws s3 rm (word-boundary)" "$(bash_call '"aws s3 rm s3://bucket/key"')"

echo "== read-only fast-path: allow (exit 0) — searches are not the thing searched =="
# The pre-fix bug: matching command TEXT blocked a search whose QUERY contained a
# risky word, and the unanchored cloud rule matched the "rm" inside cloudformation.
check 0 "rg for the literal 'npm install'"   "$(bash_call '"rg \"npm install\" docs/"')"
check 0 "grep for the literal 'pip install'" "$(bash_call '"grep -rn \"pip install\" ."')"
check 0 "git log --grep for 'rm -rf'"        "$(bash_call '"git log --grep=\"rm -rf cleanup\""')"
check 0 "find search (no -delete/-exec)"     "$(bash_call '"find . -name *.ts"')"
check 0 "read-only pipeline (rg | head)"     "$(bash_call '"rg foo src/ | head -n5"')"
check 0 "gcloud read with --format (was FP)" "$(bash_call '"gcloud compute instances list --format=json"')"
check 0 "aws cloudformation read (was FP)"   "$(bash_call '"aws cloudformation describe-stacks"')"
# Fast-path must NOT swallow a mutation hidden behind a read-only-looking prefix.
check 2 "find . -delete is still denied"     "$(bash_call '"find . -delete"')"
check_ask "env-prefixed npm install still asks" "$(bash_call '"env FOO=1 npm install left-pad"')"

# --- quoted `|` is DATA, not a pipe -------------------------------------------
# Regression: the splitter used to cut on the first literal `|`, so an alternation
# inside a quoted search pattern produced a bogus segment -> DECLINE -> fall
# through to the denylist -> hard-denied by the `rm -rf` inside its own QUERY.
# Reported by an agent auditing guard.sh, which is precisely who types these.
check 0 "grep \\| alternation over risky terms, piped to head (the repro)" \
  "$(bash_call '"grep -n \"rm -rf\\\\|DENY_BASH_PATTERNS\\\\|BASH_WRITE_PATTERNS\" -A 30 hooks/guard.sh | head -80"')"
check 0 "grep \\| alternation, no pipe at all" \
  "$(bash_call '"grep -rn \"rm -rf\\\\|git push --force\" docs/"')"
check 0 "rg | alternation (ERE, unescaped) in quotes" \
  "$(bash_call '"rg -e \"rm -rf|reset --hard\" docs/"')"
check 0 "single-quoted alternation" \
  "$(bash_call '"grep -n '\''rm -rf\\\\|chmod 777'\'' hooks/guard.sh"')"
# ...and a REAL pipe still gets judged segment by segment.
check 2 "real rm -rf (not a search) still denied"  "$(bash_call '"rm -rf /some/path"')"
check 2 "read-only cmd piped INTO xargs rm -rf"    "$(bash_call '"grep -rl foo . | xargs rm -rf"')"
check 2 "quoted pipe then a real pipe to a sensitive-path write" \
  "$(bash_call '"grep -n \"a\\\\|b\" f | tee server.pem"')"

echo "== git merge-base precision (ADR 0014 §6): read-only, not the merge soft-gate =="
# `git merge-base` is read-only plumbing. Bare, the fast-path allows it; but wrapped
# in a $()/redirect/chain (which disqualifies the fast-path) the git router used to
# match its `merge` prefix and route it into the merge soft-gate -> denied below
# full-autonomy. The trailing boundary now excludes `-`, so it no longer misfires.
check 0 "bare git merge-base (fast-path)"          "$(bash_call '"git merge-base main HEAD"')"
check 0 "git merge-base in \$() (was merge-gate FP)" "$(bash_call '"git rev-list --count $(git merge-base main HEAD)..HEAD"')"
check 0 "git merge-base with a redirect"           "$(bash_call '"git merge-base main feature > base.txt"')"
check 0 "git merge-tree (plumbing, not merge)"     "$(bash_call '"git merge-tree $(git merge-base a b) a b"')"
# A REAL merge still routes into the soft-gate: denied below full-autonomy.
check 2 "real git merge still gated (interactive)" "$(bash_call '"git merge origin/x"')"

echo "== shell writes to SECRET paths: deny (exit 2) — irreversible exposure =="
check 2 "cp over .env"               "$(bash_call '"cp tmp .env"')"
check 2 "tee a .pem"                 "$(bash_call '"echo x | tee server.pem"')"
check 2 "redirect into a secrets/ dir" "$(bash_call '"cat > config/secrets/db.json <<EOF"')"

echo "== shell writes to REVIEW paths: ask (exit 0 + ask) — reversible code/config =="
# ADR 0014: auth CODE and app config are review-worthy but reversible, so a shell
# write to one now surfaces a one-click prompt instead of a dead end.
check_ask "redirect into auth dir"    "$(bash_call '"cat > src/Auth/Login.cs <<EOF"')"
check_ask "sed -i appsettings.json"   "$(bash_call '"sed -i s/a/b/ src/appsettings.json"')"
check_ask "cp over qualified-weak file" "$(bash_call '"cp tmp src/session-token.ts"')"

echo "== SECRET-path Edit/Write: deny (exit 2) — irreversible exposure =="
check 2 "Edit .env"                  "$(edit_call '".env"')"
check 2 "Edit a .pem key"            "$(edit_call '"certs/server.pem"')"
check 2 "Edit credentials.json"      "$(edit_call '"src/credentials.json"')"
check 2 "Edit file in secrets/ dir"  "$(edit_call '"config/secrets/db.json"')"

echo "== REVIEW-path Edit/Write: ask (exit 0 + ask) — auth code / CI / config =="
# ADR 0014: reversible, PR-reviewed source and config prompt one-click instead of
# dead-ending. STRONG auth terms gate as a code filename OR a code file under an
# auth directory; WEAK terms only with an auth qualifier.
check_ask "Edit auth-dir code file"  "$(edit_call '"src/Auth/Login.cs"')"
check_ask "Edit authz dir code file" "$(edit_call '"src/authz/policy.cs"')"
check_ask "Edit oauth callback"      "$(edit_call '"src/oauth/callback.ts"')"
check_ask "Edit nested auth code"    "$(edit_call '"src/auth/providers/google.ts"')"
check_ask "Edit jwt.ts"              "$(edit_call '"src/jwt.ts"')"
check_ask "Edit auth-service.ts"     "$(edit_call '"src/auth-service.ts"')"
check_ask "Edit identity-provider.ts" "$(edit_call '"src/identity-provider.ts"')"
check_ask "Edit session-token.ts"    "$(edit_call '"src/session-token.ts"')"
check_ask "Edit refresh-token.ts"    "$(edit_call '"src/refresh-token.ts"')"
check_ask "Edit token-provider.ts"   "$(edit_call '"src/token-provider.ts"')"
check_ask "Edit github workflow"     "$(edit_call '".github/workflows/ci.yml"')"
check_ask "Edit appsettings"         "$(edit_call '"src/appsettings.Production.json"')"

echo "== auth DOCS no longer gate (the migration false-positive) — allow (exit 0) =="
# ADR 0014 §3: the auth directory rule is constrained to code extensions, so a doc
# living under an auth/oauth folder is no longer gated. This is the exact false
# positive reported during the speckit migration.
check 0 "doc under auth/ dir"        "$(edit_call '"docs/auth/overview.md"')"
check 0 "doc under oauth/ dir"       "$(edit_call '"docs/oauth/setup.md"')"
check 0 "auth-named markdown file"   "$(edit_call '"docs/oauth-notes.md"')"

echo "== two-tier auth paths: overloaded WEAK words -> allow (exit 0) — the FP fix =="
# The false positives the two-tier split removes: overloaded words with no auth
# qualifier, and the `auth`-prefix-matching-`author` bug. See ADR 0008.
check 0 "scenario identity.ts (reported FP)"  "$(edit_call '"packages/engine/src/generation/identity.ts"')"
check 0 "game-session.ts"            "$(edit_call '"src/game/game-session.ts"')"
check 0 "session-store.ts"           "$(edit_call '"src/net/session-store.ts"')"
check 0 "tmux-session.ts"            "$(edit_call '"src/util/tmux-session.ts"')"
check 0 "design-tokens.ts"           "$(edit_call '"src/styles/design-tokens.ts"')"
check 0 "lexer tokens.ts"            "$(edit_call '"src/lexer/tokens.ts"')"
check 0 "resilience policies dir"    "$(edit_call '"src/resilience/policies/retry.ts"')"
check 0 "orm identity-map.ts"        "$(edit_call '"src/orm/identity-map.ts"')"
check 0 "author.ts (auth != author)" "$(edit_call '"src/blog/author.ts"')"
check 0 "authors/ dir (auth != author)" "$(edit_call '"src/content/authors/index.ts"')"
check 0 "fs permissions.ts"          "$(edit_call '"src/fs/permissions.ts"')"
check 0 "author-session.ts (author+session, not auth)" "$(edit_call '"src/game/author-session.ts"')"

echo "== benign: allow (exit 0) =="
check 0 "dotnet test"                "$(bash_call '"dotnet test"')"
check 0 "git status"                 "$(bash_call '"git status"')"
check 0 "git diff"                   "$(bash_call '"git diff --staged"')"
check 0 "echo redirect to README"    "$(bash_call '"echo hi > README.md"')"
check 0 "sed -i on ordinary file"    "$(bash_call '"sed -i s/a/b/ src/util.ts"')"
check 0 "ls with 2>&1 redirect"      "$(bash_call '"ls -la 2>&1"')"
check 0 "Edit ordinary source"       "$(edit_call '"src/util.ts"')"
check 0 "read (cat) an auth file"    "$(bash_call '"cat src/Auth/Login.cs"')"
# Domain-specific risk is NOT a plugin default — the plugin is stack/domain
# agnostic. A financial repo re-adds these via .agents/guard-extra-paths
# (exercised in the guard-extra section below).
check 0 "Edit a 'plaid' file (not a default)" "$(edit_call '"src/plaid/sync.ts"')"
check 0 "Edit a 'payments' file (not a default)" "$(edit_call '"src/payments/charge.ts"')"

echo "== per-project guard-extra (declared -> enforced) =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.agents"
printf '# custom risky command for this repo\n(^|[^[:alnum:]])make[[:space:]]+deploy([^[:alnum:]]|$)\n' > "$TMP/.agents/guard-extra-bash"
# A financial consumer re-adds its money paths here, scoped to real
# module paths rather than bare keywords — this is where the removed plugin
# default now lives as declared-and-enforced per-repo risk.
printf '# custom sensitive paths for this repo\n(^|/)src/critical/\n(^|/)src/(payments|ledger)/\n' > "$TMP/.agents/guard-extra-paths"
# guard-extra-review: per-repo ASK-tier paths (prompt, don't dead-end). ADR 0014.
printf '# custom review paths for this repo\n(^|/)src/billing-ui/\n' > "$TMP/.agents/guard-extra-review"

with_cwd() { printf '{"cwd":"%s","tool_name":"%s","tool_input":%s}' "$TMP" "$1" "$2"; }
check 2 "extra-path (SECRET): edit src/critical blocked" "$(with_cwd Edit '{"file_path":"src/critical/x.ts"}')"
check 2 "extra-path via shell write blocked"    "$(with_cwd Bash '{"command":"echo x > src/critical/x.ts"}')"
check 2 "extra-path: repo re-adds a money path" "$(with_cwd Edit '{"file_path":"src/payments/charge.ts"}')"
check 2 "extra-bash: make deploy blocked"      "$(with_cwd Bash '{"command":"make deploy"}')"
check_ask "extra-review: src/billing-ui asks (not deny)" "$(with_cwd Edit '{"file_path":"src/billing-ui/page.tsx"}')"
check 0 "extra rules do not block benign"       "$(with_cwd Bash '{"command":"make build"}')"

echo "== commit soft-gate: autonomy × branch × staged diff (ADR 0004) =="
# Build a throwaway git repo on a named branch. Optionally stage/track a file so
# we can exercise the sensitive-staged-path check. Real repos are needed because
# the gate reads the branch and the staged diff from git.
mk_repo() {
  # $1 = final branch name. Echoes the repo path. Leaves it on $1 with a commit.
  local d; d="$(mktemp -d)"
  (
    git -C "$d" init -q
    git -C "$d" config user.email t@example.test
    git -C "$d" config user.name test
    printf 'seed\n' > "$d/seed.txt"
    git -C "$d" add seed.txt
    git -C "$d" commit -qm seed
    git -C "$d" branch -M "$1"
  ) >/dev/null 2>&1
  printf '%s' "$d"
}
stage() { # $1 repo, $2 path (relative), stages a new file at that path
  mkdir -p "$(dirname "$1/$2")" 2>/dev/null || true
  printf 'x\n' > "$1/$2"
  git -C "$1" add "$2" >/dev/null 2>&1
}

# commit_check <expected> <desc> <autonomy> <cwd> [command]
commit_check() {
  local want="$1" desc="$2" auton="$3" cwd="$4" cmd="${5:-git commit -m x}" got payload
  payload="$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$cwd" "$cmd")"
  printf '%s' "$payload" | ORCH_AUTONOMY="$auton" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   (exit %s) %s\n' "$got" "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL (want %s, got %s) %s\n' "$want" "$got" "$desc"; fail=$((fail + 1))
  fi
}

COMMIT_TMPS=""
new_repo() { local r; r="$(mk_repo "$1")"; COMMIT_TMPS="$COMMIT_TMPS $r"; printf '%s' "$r"; }
trap 'rm -rf $COMMIT_TMPS 2>/dev/null || true' EXIT

R_FEAT_CLEAN="$(new_repo feature)";       stage "$R_FEAT_CLEAN" "src/util.ts"
R_MAIN_CLEAN="$(new_repo main)";          stage "$R_MAIN_CLEAN" "src/util.ts"
R_FEAT_SECRET="$(new_repo feature)";      stage "$R_FEAT_SECRET" ".env"
R_AUTON_CLEAN="$(new_repo feature)";      stage "$R_AUTON_CLEAN" "src/util.ts"
R_AUTON_SECRET="$(new_repo feature)";     stage "$R_AUTON_SECRET" "config/secrets/db.json"
# ADR 0014: an auth-CODE commit is a normal delegable commit (the SECRET floor is
# what the gate checks now), so staging auth code must still ALLOW the commit.
R_FEAT_AUTHCODE="$(new_repo feature)";    stage "$R_FEAT_AUTHCODE" "src/Auth/Login.cs"

# The decision cube from the plan (sensitive == SECRET tier after ADR 0014).
commit_check 2 "interactive + feature + clean -> deny"       interactive "$R_FEAT_CLEAN"
commit_check 2 "supervised + main + clean -> deny"           supervised  "$R_MAIN_CLEAN"
commit_check 0 "supervised + feature + clean -> allow"       supervised  "$R_FEAT_CLEAN"
commit_check 2 "supervised + feature + SECRET (.env) -> deny" supervised  "$R_FEAT_SECRET"
commit_check 0 "supervised + feature + auth CODE -> allow (ADR 0014)" supervised "$R_FEAT_AUTHCODE"
commit_check 0 "autonomous + feature + clean -> allow"       autonomous  "$R_AUTON_CLEAN"
commit_check 2 "autonomous + feature + SECRET -> deny"       autonomous  "$R_AUTON_SECRET"

# Fail-closed: not a git repo, and detached HEAD.
NONREPO="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $NONREPO"
commit_check 2 "supervised + non-repo cwd -> deny (fail closed)"  supervised "$NONREPO"
R_DETACHED="$(new_repo feature)"
git -C "$R_DETACHED" checkout -q "$(git -C "$R_DETACHED" rev-parse HEAD)"
commit_check 2 "supervised + detached HEAD -> deny (fail closed)" supervised "$R_DETACHED"

# --amend stays hard-denied (history rewrite), even when otherwise allowable.
commit_check 2 "supervised + feature + --amend -> deny (history rewrite)" \
  supervised "$R_FEAT_CLEAN" "git commit --amend -m x"

# -a/--all bypass closed: a SECRET tracked-but-unstaged change is swept in.
R_ALL="$(new_repo feature)"
printf 'a\n' > "$R_ALL/.env"
git -C "$R_ALL" add .env >/dev/null 2>&1
git -C "$R_ALL" commit -qm "add env" >/dev/null 2>&1
printf 'b\n' >> "$R_ALL/.env"   # tracked, unstaged
commit_check 2 "supervised + feature + 'commit -am' over SECRET tracked file -> deny" \
  supervised "$R_ALL" "git commit -am x"

# Precedence: env unset, .agents/autonomy provides the level.
R_FILELVL="$(new_repo feature)"; stage "$R_FILELVL" "src/util.ts"
mkdir -p "$R_FILELVL/.agents"; printf 'supervised\n' > "$R_FILELVL/.agents/autonomy"
commit_check 0 ".agents/autonomy=supervised (env unset) + feature + clean -> allow" \
  "" "$R_FILELVL"

# Ceiling clamp: project-overrides caps autonomous down to interactive.
R_CEIL="$(new_repo feature)"; stage "$R_CEIL" "src/util.ts"
mkdir -p "$R_CEIL/.agents"; printf 'autonomy_ceiling: interactive\n' > "$R_CEIL/.agents/project-overrides.yaml"
commit_check 2 "autonomous clamped by autonomy_ceiling=interactive -> deny" \
  autonomous "$R_CEIL"

echo "== git-workflow soft-gate: merge/rebase/push at full-autonomy (ADR 0006) =="
# The guard only INSPECTS the command (branch via git, best-effort diff); it never
# runs the merge/rebase/push, so source/target branches need not actually exist.
# commit_check is generic on the command, so reuse it here.
R_WF_FEAT="$(new_repo feature)"        # on a feature branch
R_WF_MAIN="$(new_repo main)"           # on main
R_WF_DEV="$(new_repo develop)"         # on an integration branch

# --- merge: delegated only at full-autonomy, only into a NON-main branch ---
commit_check 0 "full-autonomy + feature + merge -> allow"        full-autonomy "$R_WF_FEAT" "git merge orch/x"
commit_check 0 "full-autonomy + develop + merge -> allow"        full-autonomy "$R_WF_DEV"  "git merge orch/x"
commit_check 2 "full-autonomy + main + merge -> deny (branch)"   full-autonomy "$R_WF_MAIN" "git merge orch/x"
commit_check 2 "autonomous + feature + merge -> deny (autonomy)" autonomous    "$R_WF_FEAT" "git merge orch/x"
commit_check 2 "supervised + feature + merge -> deny (autonomy)" supervised    "$R_WF_FEAT" "git merge orch/x"

# --- merge carrying a SECRET path re-escalates even at full-autonomy ---
R_WF_SENS="$(new_repo develop)"
( git -C "$R_WF_SENS" checkout -q -b orch/sens
  printf 'x\n' > "$R_WF_SENS/.env"
  git -C "$R_WF_SENS" add .env; git -C "$R_WF_SENS" commit -qm "env"
  git -C "$R_WF_SENS" checkout -q develop ) >/dev/null 2>&1
commit_check 2 "full-autonomy + develop + merge of SECRET-bearing branch -> deny" \
  full-autonomy "$R_WF_SENS" "git merge orch/sens"

# --- rebase: delegated only at full-autonomy on a NON-main branch; -i is rewrite ---
commit_check 0 "full-autonomy + feature + rebase base -> allow"      full-autonomy "$R_WF_FEAT" "git rebase develop"
commit_check 2 "full-autonomy + feature + rebase -i -> deny (rewrite)" full-autonomy "$R_WF_FEAT" "git rebase -i develop"
commit_check 2 "full-autonomy + main + rebase -> deny (branch)"      full-autonomy "$R_WF_MAIN" "git rebase develop"
commit_check 2 "autonomous + feature + rebase -> deny (autonomy)"    autonomous    "$R_WF_FEAT" "git rebase develop"

# --- push: delegated only at full-autonomy, never to main, never forced ---
commit_check 0 "full-autonomy + push feature ref -> allow"          full-autonomy "$R_WF_FEAT" "git push origin feature"
commit_check 0 "full-autonomy + bare push on feature -> allow"      full-autonomy "$R_WF_FEAT" "git push"
commit_check 2 "full-autonomy + push origin main -> deny (target)"  full-autonomy "$R_WF_FEAT" "git push origin main"
commit_check 2 "full-autonomy + push HEAD:main -> deny (target)"    full-autonomy "$R_WF_FEAT" "git push origin HEAD:main"
commit_check 2 "full-autonomy + bare push on main -> deny (target)" full-autonomy "$R_WF_MAIN" "git push"
commit_check 2 "full-autonomy + push -f feature -> deny (force)"    full-autonomy "$R_WF_FEAT" "git push -f origin feature"
commit_check 2 "autonomous + push feature ref -> deny (autonomy)"   autonomous    "$R_WF_FEAT" "git push origin feature"

# --- the danger floor still hard-denies at full-autonomy ---
# rm -rf and sensitive-path writes stay HARD even at the top autonomy level.
commit_check 2 "full-autonomy + rm -rf -> deny (danger floor)" \
  full-autonomy "$R_WF_FEAT" "rm -rf build"
check 2 "full-autonomy + edit .env -> deny (danger floor)" \
  "$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":".env"}}' "$R_WF_FEAT")"
# Migrations / dep installs are the ASK tier — they prompt, not deny, at every
# level (the human clicks; autonomy does not auto-approve an ask). See ADR 0008.
migrate_payload="$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"dotnet ef database update"}}' "$R_WF_FEAT")"
out="$(printf '%s' "$migrate_payload" | ORCH_AUTONOMY=full-autonomy "$GUARD" 2>/dev/null)"; got=$?
if [ "$got" = 0 ] && printf '%s' "$out" | grep -q '"permissionDecision":[[:space:]]*"ask"'; then
  printf 'ok   (ask)     full-autonomy + db migration -> ask (routine tier)\n'; pass=$((pass + 1))
else
  printf 'FAIL (want ask, got exit %s) full-autonomy + db migration\n' "$got"; fail=$((fail + 1))
fi

# --- resolution + ceiling for the new level ---
R_WF_FILELVL="$(new_repo feature)"
mkdir -p "$R_WF_FILELVL/.agents"; printf 'full-autonomy\n' > "$R_WF_FILELVL/.agents/autonomy"
commit_check 0 ".agents/autonomy=full-autonomy (env unset) + feature + merge -> allow" \
  "" "$R_WF_FILELVL" "git merge orch/x"
R_WF_CEIL="$(new_repo feature)"
mkdir -p "$R_WF_CEIL/.agents"; printf 'autonomy_ceiling: autonomous\n' > "$R_WF_CEIL/.agents/project-overrides.yaml"
commit_check 2 "full-autonomy clamped by autonomy_ceiling=autonomous + merge -> deny" \
  full-autonomy "$R_WF_CEIL" "git merge orch/x"

echo "== .agents/autonomy header format parses (skill writes a # header) =="
# Regression for the parser bug: the set-autonomy skill writes an explanatory
# comment header ABOVE the bare level. Stripping the whole file would fold the
# header in and silently fall back to interactive. The parser must read only the
# last non-comment line.
R_HDR="$(new_repo feature)"; stage "$R_HDR" "src/util.ts"
mkdir -p "$R_HDR/.agents"
cat > "$R_HDR/.agents/autonomy" <<'EOF'
# Default orchestration autonomy level for this repo (ADR 0004 / 0006).
# Resolution order: env ORCH_AUTONOMY -> this file -> plugin default (interactive).
#   interactive   — human approves every mutation gate
#   supervised    — CE auto-commits green work on a feature branch
supervised
EOF
commit_check 0 "header-format .agents/autonomy=supervised (env unset) -> allow" \
  "" "$R_HDR"
# And the top level, hyphenated, in the same header format.
R_HDR2="$(new_repo feature)"
mkdir -p "$R_HDR2/.agents"
printf '# header line\n#   another comment\nfull-autonomy\n' > "$R_HDR2/.agents/autonomy"
commit_check 0 "header-format .agents/autonomy=full-autonomy + merge -> allow" \
  "" "$R_HDR2" "git merge orch/x"

echo "== cross-tree git gate: payload cwd = one repo, command targets another =="
# A command can target a DIFFERENT checkout than the payload cwd via `git -C <dir>`
# or a leading `cd <dir> &&` (another clone, a submodule, any second repo). The gate
# must judge the branch of the tree the COMMAND targets, not just cwd — otherwise
# `git -C /other commit` from a feature-branch cwd would dodge the main gate. Two
# independent repos (a second clone, NOT a worktree) reproduce that split cleanly.
mk_two_trees() {   # echoes "<t_main> <t_feat>"; t_main on main, t_feat (a clone) on feature
  local p w
  p="$(mk_repo main)"; w="${p}.clone"
  ( git clone -q "$p" "$w"
    git -C "$w" config user.email t@example.test
    git -C "$w" config user.name test
    git -C "$w" checkout -q -b feature
    mkdir -p "$w/src"; printf 'x\n' > "$w/src/util.ts"; git -C "$w" add src/util.ts ) >/dev/null 2>&1
  COMMIT_TMPS="$COMMIT_TMPS $p $w"
  printf '%s %s' "$p" "$w"
}
read -r T_MAIN T_FEAT <<EOF
$(mk_two_trees)
EOF
# cwd = t_main (on main), but the command targets t_feat (on feature):
commit_check 0 "supervised + cwd=main-repo + 'git -C <feat> commit' -> allow (reads feature)" \
  supervised "$T_MAIN" "git -C $T_FEAT commit -m x"
commit_check 0 "supervised + cwd=main-repo + 'cd <feat> && git commit' -> allow" \
  supervised "$T_MAIN" "cd $T_FEAT && git commit -m x"
commit_check 0 "full-autonomy + cwd=main-repo + 'git -C <feat> merge' -> allow" \
  full-autonomy "$T_MAIN" "git -C $T_FEAT merge orch/x"
# Reverse bypass closed: cwd = feature repo, but the command targets the main repo
# — must deny (judged against the tree the command actually writes).
commit_check 2 "supervised + cwd=feat-repo + 'git -C <main-repo> commit' -> deny (reads main)" \
  supervised "$T_FEAT" "git -C $T_MAIN commit -m x"
# `git commit -C <ref>` (reuse message) must NOT be mistaken for a target dir.
stage "$T_MAIN" "src/util.ts"   # ensure the main repo has a clean staged change
commit_check 2 "supervised + main-repo + 'git commit -C HEAD' -> deny (not a dir; still main)" \
  supervised "$T_MAIN" "git commit -C HEAD"

echo "== config-root discovery: cwd BELOW the repo root inherits the ancestor's .agents/* =="
# Regression for the PROJECT_DIR/SHELL_CWD split (ADR 0011): the payload cwd is
# routinely a SUBDIRECTORY of the project (a package cache, a submodule, src/).
# Before the fix, config was resolved from cwd alone, so any non-root cwd found no
# `.agents/` at all: autonomy silently fell back to `interactive` (fail closed,
# confusing) and `guard-extra-bash`/`guard-extra-paths` silently stopped loading
# (fail OPEN -- the repo's declared hard-gates vanished).
R_ROOT="$(new_repo feature)"; stage "$R_ROOT" "src/util.ts"
mkdir -p "$R_ROOT/.agents"
printf 'supervised\n' > "$R_ROOT/.agents/autonomy"
printf '# custom risky command declared at the repo root\n(^|[^[:alnum:]])make[[:space:]]+special-deploy([^[:alnum:]]|$)\n' \
  > "$R_ROOT/.agents/guard-extra-bash"
printf '# custom sensitive path declared at the repo root\n(^|/)src/critical/\n' \
  > "$R_ROOT/.agents/guard-extra-paths"
R_SUB="$R_ROOT/pkg/sub"; mkdir -p "$R_SUB"

commit_check 0 "cwd below repo root: autonomy read from ancestor root (was: interactive -> deny)" \
  "" "$R_SUB"
check 2 "cwd below repo root: guard-extra-bash enforced (was: silently allowed)" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"make special-deploy"}}' "$R_SUB")"
check 2 "cwd below repo root: guard-extra-paths enforced on Edit (was: silently allowed)" \
  "$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"src/critical/x.ts"}}' "$R_SUB")"
check 2 "cwd below repo root: guard-extra-paths enforced via shell write (was: silently allowed)" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo x > src/critical/x.ts"}}' "$R_SUB")"

echo "== nested-repo regression: cwd = a nested checkout ON MAIN inside a full-autonomy outer project =="
# The regression guard for the whole PROJECT_DIR/SHELL_CWD decoupling. The outer
# project votes full-autonomy, but the tree the command actually TARGETS (cwd =
# a nested checkout, e.g. a vendored clone/submodule) is on `main`. Config
# resolution (which root's rules apply) and git-target resolution (which tree the
# soft gates judge) must stay fully independent -- if a "fix" let the discovered
# config root also drive GIT_CWD, this would wrongly read the OUTER branch
# (feature) and ALLOW. It must still DENY.
R_NEST_OUTER="$(new_repo feature)"
mkdir -p "$R_NEST_OUTER/.agents"; printf 'full-autonomy\n' > "$R_NEST_OUTER/.agents/autonomy"
R_NEST_INNER="$R_NEST_OUTER/vendor/nested-checkout"
mkdir -p "$R_NEST_INNER"
( git -C "$R_NEST_INNER" init -q
  git -C "$R_NEST_INNER" config user.email t@example.test
  git -C "$R_NEST_INNER" config user.name test
  printf 'seed\n' > "$R_NEST_INNER/seed.txt"
  git -C "$R_NEST_INNER" add seed.txt
  git -C "$R_NEST_INNER" commit -qm seed
  git -C "$R_NEST_INNER" branch -M main ) >/dev/null 2>&1
COMMIT_TMPS="$COMMIT_TMPS $R_NEST_INNER"
commit_check 2 "nested checkout on main inside a full-autonomy outer project -> still DENY" \
  "" "$R_NEST_INNER"

echo "== restrictive config merge: privilege across discovered roots can only be LOWERED =="
# (1) A nested .agents/autonomy=interactive UNDER a full-autonomy root: every
# discovered root VOTES and the LOWEST vote wins, so the nested `interactive`
# holds even though the ancestor root says full-autonomy.
R_MERGE_OUTER="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $R_MERGE_OUTER"
mkdir -p "$R_MERGE_OUTER/.agents"; printf 'full-autonomy\n' > "$R_MERGE_OUTER/.agents/autonomy"
R_MERGE_NESTED="$R_MERGE_OUTER/nested"
mkdir -p "$R_MERGE_NESTED/.agents"; printf 'interactive\n' > "$R_MERGE_NESTED/.agents/autonomy"
commit_check 2 "nested .agents/autonomy=interactive under a full-autonomy root -> deny (MIN vote)" \
  "" "$R_MERGE_NESTED"

# (2) A foreign CLAUDE_PROJECT_DIR declaring full-autonomy must not RAISE a cwd
# project that declares interactive -- privilege only ever goes DOWN, never up,
# regardless of which root CLAUDE_PROJECT_DIR points at.
R_MERGE_FOREIGN="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $R_MERGE_FOREIGN"
mkdir -p "$R_MERGE_FOREIGN/.agents"; printf 'full-autonomy\n' > "$R_MERGE_FOREIGN/.agents/autonomy"
R_MERGE_CWD="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $R_MERGE_CWD"
mkdir -p "$R_MERGE_CWD/.agents"; printf 'interactive\n' > "$R_MERGE_CWD/.agents/autonomy"
merge_payload="$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$R_MERGE_CWD")"
printf '%s' "$merge_payload" | CLAUDE_PROJECT_DIR="$R_MERGE_FOREIGN" "$GUARD" >/dev/null 2>&1
merge_got=$?
if [ "$merge_got" = 2 ]; then
  printf 'ok   (exit %s) foreign CLAUDE_PROJECT_DIR=full-autonomy cannot raise cwd=interactive project\n' "$merge_got"
  pass=$((pass + 1))
else
  printf 'FAIL (want 2, got %s) foreign CLAUDE_PROJECT_DIR=full-autonomy cannot raise cwd=interactive project\n' "$merge_got"
  fail=$((fail + 1))
fi

echo "== hot-path reorder: lazy discovery still enforces per-repo guard-extra =="
# The reorder resolves per-repo config LAZILY (only for non-read-only commands),
# and a read-only command exits before discovery runs at all. Pin both: the
# lazily-loaded guard-extra rules are still enforced, and a read-only command is
# still allowed without needing them.
R_LAZY="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $R_LAZY"
mkdir -p "$R_LAZY/.agents"
printf '(^|/)src/vault/\n' > "$R_LAZY/.agents/guard-extra-paths"
printf '(^|[^[:alnum:]])make[[:space:]]+ship([^[:alnum:]]|$)\n' > "$R_LAZY/.agents/guard-extra-bash"
check 2 "lazy discovery enforces guard-extra-paths on a non-read-only Edit" \
  "$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"src/vault/k.ts"}}' "$R_LAZY")"
check 2 "lazy discovery enforces guard-extra-bash on a non-read-only Bash command" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"make ship"}}' "$R_LAZY")"
check 0 "read-only command allowed without triggering discovery" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"grep -r foo src/"}}' "$R_LAZY")"

echo "== bypass-ask-tier (project-overrides.yaml): skip ASK tier, keep hard-deny =="
# A repo opts out of ask prompts entirely. The ASK tier (deps/migrations/deploys and
# REVIEW-path writes) is then ALLOWED silently, but every hard-deny floor and the git
# soft gates still enforce. Resolved restrictively: every config root must opt in.
R_BYPASS="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $R_BYPASS"
mkdir -p "$R_BYPASS/.agents"; printf 'bypass-ask-tier: true\n' > "$R_BYPASS/.agents/project-overrides.yaml"
byp() { printf '{"cwd":"%s","tool_name":"%s","tool_input":%s}' "$R_BYPASS" "$1" "$2"; }
# ASK tier -> now ALLOWED (exit 0), no prompt.
check 0 "bypass: npm install allowed (ASK_BASH skipped)"  "$(byp Bash '{"command":"npm install left-pad"}')"
check 0 "bypass: ef migrations add allowed"              "$(byp Bash '{"command":"dotnet ef migrations add X"}')"
check 0 "bypass: edit auth code allowed (REVIEW skipped)" "$(byp Edit '{"file_path":"src/Auth/Login.cs"}')"
check 0 "bypass: edit appsettings allowed"               "$(byp Edit '{"file_path":"src/appsettings.json"}')"
check 0 "bypass: edit github workflow allowed"           "$(byp Edit '{"file_path":".github/workflows/ci.yml"}')"
check 0 "bypass: shell write to auth code allowed"       "$(byp Bash '{"command":"cat > src/Auth/Login.cs <<EOF"}')"
# Hard-deny floors + git gates UNAFFECTED (still exit 2).
check 2 "bypass: edit .env still DENIED (SECRET floor)"  "$(byp Edit '{"file_path":".env"}')"
check 2 "bypass: edit a .pem still DENIED"               "$(byp Edit '{"file_path":"certs/server.pem"}')"
check 2 "bypass: rm -rf still DENIED"                    "$(byp Bash '{"command":"rm -rf build"}')"
check 2 "bypass: push to main still DENIED (git gate)"   "$(byp Bash '{"command":"git push origin main"}')"

# Default OFF: without the flag (or explicitly false), the ASK tier still prompts.
R_NOBYP="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $R_NOBYP"
mkdir -p "$R_NOBYP/.agents"; printf 'bypass-ask-tier: false\n' > "$R_NOBYP/.agents/project-overrides.yaml"
check_ask "bypass=false: npm install still asks" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"npm install left-pad"}}' "$R_NOBYP")"

# Restrictive resolution: a nested root WITHOUT the flag vetoes an outer bypass=true.
R_BYP_OUTER="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $R_BYP_OUTER"
mkdir -p "$R_BYP_OUTER/.agents"; printf 'bypass-ask-tier: true\n' > "$R_BYP_OUTER/.agents/project-overrides.yaml"
R_BYP_NESTED="$R_BYP_OUTER/nested"; mkdir -p "$R_BYP_NESTED/.agents"   # declares .agents, no bypass flag
check_ask "bypass vetoed by nested root without the flag -> still asks" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"npm install left-pad"}}' "$R_BYP_NESTED")"

echo "== payload parsing: the guard must fail CLOSED when it cannot READ its input =="
# Regression sweep for the "guard.sh fails open" report. Three independent
# defects each disabled path enforcement while the guard still looked healthy
# (it kept blocking simple ASCII bash, which is what made it invisible):
#   1. `command -v python3` is TRUE for the Microsoft Store App Execution Alias,
#      which is on PATH, prints "Python was not found…" and exits 49.
#   2. the grep/sed fallback never UNESCAPED, so a Windows path arrived as
#      `C:\\Users\\…` and could not match a rule written for one separator.
#   3. json_field returned 1 for an absent key, which `set -euo pipefail` turned
#      into exit 1 — a non-blocking error, i.e. the same fail-open.
# Every case here is run with a hobbled PATH so the FALLBACK is what's under test.
PARSE_TMPS=""
NOJQ_DIR="$(mktemp -d)"; PARSE_TMPS="$PARSE_TMPS $NOJQ_DIR"
printf '#!/bin/sh\nexit 49\n' > "$NOJQ_DIR/python3"   # the Store stub, exactly
chmod +x "$NOJQ_DIR/python3"
# A PATH with the stub first and no jq. Keep the real coreutils dirs so grep/sed
# still work — the fallback IS the code under test.
NOJQ_PATH="$NOJQ_DIR:/usr/bin:/bin"

# check_nojq <expected-exit> <description> <payload>
check_nojq() {
  local want="$1" desc="$2" payload="$3" got
  printf '%s' "$payload" | env PATH="$NOJQ_PATH" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   (exit %s) %s\n' "$got" "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL (want %s, got %s) %s\n' "$want" "$got" "$desc"; fail=$((fail + 1))
  fi
}

R_PARSE="$(mktemp -d)"; PARSE_TMPS="$PARSE_TMPS $R_PARSE"
mkdir -p "$R_PARSE/.agents"
printf '(^|[/\\])src[/\\]App[/\\]Journal[/\\]\n' > "$R_PARSE/.agents/guard-extra-paths"

# (1+2) The headline bug: a VALID payload naming a hard-floor path with Windows
# separators. `\\` is how that path is spelled in real JSON; before the fix the
# fallback matched the ENCODED form and allowed the write (verified exit 0).
check_nojq 2 "no parser: JSON-escaped Windows path still hits guard-extra-paths" \
  "$(printf '{"cwd":"%s","tool_name":"Write","tool_input":{"file_path":"C:\\\\Users\\\\me\\\\src\\\\App\\\\Journal\\\\x.cs","content":"//"}}' "$R_PARSE")"
check_nojq 2 "no parser: JSON-escaped Windows path still hits the SECRET floor (.env)" \
  '{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\me\\repo\\.env","content":"x"}}'
# Auth code is the ASK tier (ADR 0014), so this also proves json_string's own
# parser-free fallback still emits a well-formed permissionDecision.
check_nojq_ask() {
  local desc="$1" payload="$2" out got
  out="$(printf '%s' "$payload" | env PATH="$NOJQ_PATH" "$GUARD" 2>/dev/null)"; got=$?
  if [ "$got" = 0 ] && printf '%s' "$out" | grep -q '"permissionDecision":[[:space:]]*"ask"'; then
    printf 'ok   (ask)     %s\n' "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL (want ask, got exit %s) %s\n' "$got" "$desc"; fail=$((fail + 1))
  fi
}
check_nojq_ask "no parser: escaped Windows path to auth code still ASKs" \
  '{"tool_name":"Edit","tool_input":{"file_path":"C:\\repo\\src\\Auth\\Login.cs"}}'
# ...and the same path with forward slashes never regressed; pin it too.
check_nojq 2 "no parser: forward-slash path still hits guard-extra-paths" \
  "$(printf '{"cwd":"%s","tool_name":"Write","tool_input":{"file_path":"src/App/Journal/x.cs"}}' "$R_PARSE")"
check_nojq 0 "no parser: ordinary path still allowed (no over-blocking)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"C:\\repo\\src\\util.ts"}}'
check_nojq 2 "no parser: hard-deny bash still enforced" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'
check_nojq 0 "no parser: read-only bash still allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"grep -rn foo src/"}}'
# A command carrying JSON escapes must decode before matching, or the deny misses.
check_nojq 2 "no parser: escaped shell write to .env still denied" \
  '{"tool_name":"Bash","tool_input":{"command":"cp secrets.txt C:\\repo\\.env"}}'

# (3) An ABSENT optional key must not kill the hook. `cwd` is optional; before
# the fix this exited 1 (fail-open) whenever no parser could answer.
check_nojq 2 "no parser: absent optional key (cwd) does not kill the hook" \
  '{"tool_name":"Write","tool_input":{"file_path":".env","content":"x"}}'
# Same hazard via an all-comments autonomy file (leading `grep -v` exits 1).
R_ALLCOMMENT="$(mktemp -d)"; PARSE_TMPS="$PARSE_TMPS $R_ALLCOMMENT"
mkdir -p "$R_ALLCOMMENT/.agents"
printf '# just a header\n#\n\n' > "$R_ALLCOMMENT/.agents/autonomy"
check 2 "autonomy file of only comments does not kill the hook (falls back to interactive)" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$R_ALLCOMMENT")"

# Fail CLOSED on an unreadable payload, at every level of the envelope.
check 2 "malformed JSON payload -> DENY (cannot judge => must not allow)" \
  '{"tool_name":"Write","cwd":"/tmp","tool_input":{not valid json'
check 2 "payload with no tool_name -> DENY" \
  '{"cwd":"/tmp","tool_input":{"file_path":"src/x.ts"}}'
check 2 "Bash payload with no command -> DENY" \
  '{"tool_name":"Bash","cwd":"/tmp","tool_input":{}}'
check 2 "Edit payload with no path -> DENY" \
  '{"tool_name":"Edit","cwd":"/tmp","tool_input":{"old_string":"a"}}'
# ...but a completely EMPTY stdin is not a tool call at all -> allow.
check 0 "empty stdin is not a tool call -> allow" ''

echo "== path separators: Windows-style paths must hit the same rules as POSIX ones =="
# Found while writing the cases above, and INDEPENDENT of parsing: every pattern
# in this file spells segments with `/`, so on Windows `C:\Users\me\repo\.env`
# gave `(^|/)\.env(\.|$)` no `/` to anchor on and the single most important
# SECRET rule was inert — with a perfectly working jq (verified exit 0). Paths
# are now matched separator-normalized, which can only ever ADD matches.
# NOTE: these payloads MUST be built so `\\` survives into the JSON. Writing
# them by hand through a layer that collapses `\\` to `\` yields INVALID JSON,
# which the guard now (correctly) denies as unreadable — and a deny for the
# wrong reason reads as a pass. Each case below is paired with an allow case so
# a spurious deny cannot hide.
check 2   "backslash .env hits the SECRET floor" \
  '{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\me\\repo\\.env","content":"x"}}'
check 2   "backslash key material (.pem) hits the SECRET floor" \
  '{"tool_name":"Write","tool_input":{"file_path":"C:\\repo\\certs\\server.pem"}}'
check_ask "backslash auth code asks (ADR 0014)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"C:\\repo\\src\\Auth\\Login.cs"}}'
check_ask "backslash .github/workflows asks" \
  '{"tool_name":"Edit","tool_input":{"file_path":"repo\\.github\\workflows\\ci.yml"}}'
check_ask "backslash infra/*.tf asks" \
  '{"tool_name":"Edit","tool_input":{"file_path":"C:\\repo\\infra\\main.tf"}}'
check_ask "shell write to a backslash auth path asks" \
  '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ C:\\repo\\src\\Auth\\Login.cs"}}'
# ...and normalization must not start blocking innocent things.
check 0   "ordinary backslash path still allowed" \
  '{"tool_name":"Edit","tool_input":{"file_path":"C:\\repo\\src\\util.ts"}}'
check 0   "docs under a backslash auth dir still allowed (extension rule holds)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"C:\\repo\\docs\\auth\\overview.md"}}'
check 0   "grep whose pattern contains a backslash still fast-paths" \
  '{"tool_name":"Bash","tool_input":{"command":"grep -rn \"a\\\\|b\" src/"}}'

# --selftest reports readability without needing a live tool call.
if "$GUARD" --selftest >/dev/null 2>&1; then
  printf 'ok   (exit 0) --selftest passes with a real parser on PATH\n'; pass=$((pass + 1))
else
  printf 'FAIL (want 0) --selftest passes with a real parser on PATH\n'; fail=$((fail + 1))
fi
if env PATH="$NOJQ_PATH" "$GUARD" --selftest >/dev/null 2>&1; then
  printf 'ok   (exit 0) --selftest passes on the decoding fallback (no jq, stubbed python3)\n'; pass=$((pass + 1))
else
  printf 'FAIL (want 0) --selftest passes on the decoding fallback (no jq, stubbed python3)\n'; fail=$((fail + 1))
fi

echo "== parallel lanes: guard behavior INSIDE a git worktree (ADR 0016) =="
# A lane runs in its own worktree on orch/<id>. The worktree checks out the
# COMMITTED .agents/ (project-overrides, guard-extra), but a session-written
# .agents/autonomy is gitignored and absent there — so the driver passes
# ORCH_AUTONOMY via env, which the guard honors first. Prove all of that.
RW1="$(new_repo develop)"
mkdir -p "$RW1/.agents"
printf 'integration_branch: develop\n' > "$RW1/.agents/project-overrides.yaml"
printf '(^|/)src/critical/\n'          > "$RW1/.agents/guard-extra-paths"
git -C "$RW1" add -A >/dev/null 2>&1; git -C "$RW1" commit -qm "agents config" >/dev/null 2>&1
WTX="$(dirname "$RW1")/$(basename "$RW1")-wtx"; COMMIT_TMPS="$COMMIT_TMPS $WTX"
git -C "$RW1" worktree add -q -b orch/lane-x "$WTX" develop >/dev/null 2>&1

# commit gate resolves the worktree's branch (orch/lane-x, not main) and the
# env-supplied autonomy — the enabling case for parallel lanes.
commit_check 0 "worktree lane commit + ORCH_AUTONOMY=full-autonomy -> allow"  full-autonomy "$WTX"
commit_check 2 "worktree lane commit + ORCH_AUTONOMY=interactive -> deny"     interactive   "$WTX"

# path rules fire from a worktree cwd: SECRET denies, committed guard-extra
# denies, auth CODE asks (ADR 0014), ordinary allows.
gw() { printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$WTX" "$1"; }
check 2     "worktree cwd: SECRET (.env) denied"                 "$(gw ".env")"
check 2     "worktree cwd: committed guard-extra (src/critical) denied" "$(gw "src/critical/x.ts")"
check_ask   "worktree cwd: auth CODE asks (ADR 0014)"            "$(gw "src/Auth/Login.cs")"
check 0     "worktree cwd: ordinary path allowed"                "$(gw "src/util.ts")"

# a committed autonomy_ceiling in the worktree still clamps the env level down.
RW2="$(new_repo develop)"
mkdir -p "$RW2/.agents"
printf 'integration_branch: develop\nautonomy_ceiling: interactive\n' > "$RW2/.agents/project-overrides.yaml"
git -C "$RW2" add -A >/dev/null 2>&1; git -C "$RW2" commit -qm "agents config + ceiling" >/dev/null 2>&1
WTY="$(dirname "$RW2")/$(basename "$RW2")-wty"; COMMIT_TMPS="$COMMIT_TMPS $WTY"
git -C "$RW2" worktree add -q -b orch/lane-y "$WTY" develop >/dev/null 2>&1
commit_check 2 "worktree committed autonomy_ceiling=interactive clamps full-autonomy -> deny" \
  full-autonomy "$WTY"

echo
echo "-----------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
