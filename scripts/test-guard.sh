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

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="${HERE}/../hooks/guard.sh"

# Also pin CLAUDE_PROJECT_DIR and $PWD (resolved AFTER computing HERE/GUARD
# above, so this repo's own path stays known). The config-root walk (added
# below in guard.sh) discovers roots from BOTH the payload cwd AND
# $PWD/CLAUDE_PROJECT_DIR: a suite run from inside a consumer repo would
# otherwise inherit that repo's own `.agents/*` (guard-extra-*, bypass-ask-tier)
# for every no-cwd payload, silently widening or narrowing what's under test
# depending on where the suite happens to run from — a repo declaring
# `bypass-ask-tier: true` would turn every ASK case into an allow.
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
# match its `merge` prefix and route it into the merge soft-gate -> denied as a
# merge. The trailing boundary now excludes `-`, so it no longer misfires.
check 0 "bare git merge-base (fast-path)"          "$(bash_call '"git merge-base main HEAD"')"
check 0 "git merge-base in \$() (was merge-gate FP)" "$(bash_call '"git rev-list --count $(git merge-base main HEAD)..HEAD"')"
check 0 "git merge-base with a redirect"           "$(bash_call '"git merge-base main feature > base.txt"')"
check 0 "git merge-tree (plumbing, not merge)"     "$(bash_call '"git merge-tree $(git merge-base a b) a b"')"
# A REAL merge still routes into the soft-gate. Judged against a repo actually on
# `main`, so the denial is the merge gate's branch rule and not "not a repo" —
# a deny for the wrong reason would read as a pass.
MB_MAIN="$(mktemp -d)"
( git -C "$MB_MAIN" init -q
  git -C "$MB_MAIN" config user.email t@example.test
  git -C "$MB_MAIN" config user.name test
  printf 'seed\n' > "$MB_MAIN/seed.txt"
  git -C "$MB_MAIN" add seed.txt
  git -C "$MB_MAIN" commit -qm seed
  git -C "$MB_MAIN" branch -M main ) >/dev/null 2>&1
check 2 "real git merge into main still gated" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"git merge origin/x"}}' "$MB_MAIN")"

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

echo "== self-host: THIS repo's reflexive surface asks (self-host-hardening T1/T2) =="
# This repo IS the plugin, so the loop can edit the guard, the state writer and the
# agent prompts it is running from — impossible in a consumer repo, where the plugin
# sits outside the working tree. `.agents/guard-extra-review` routes that surface to
# the ASK tier. ADR 0014 tier 2b.
#
# The cases below load the REAL file rather than a copy. A copy would let the shipped
# rules and the sweep drift apart silently, which is the one failure mode a test of a
# config file exists to prevent.
SH="$(mktemp -d)"; mkdir -p "$SH/.agents"
cp "${HERE}/../.agents/guard-extra-review" "$SH/.agents/guard-extra-review"
sh_cwd() { printf '{"cwd":"%s","tool_name":"%s","tool_input":%s}' "$SH" "$1" "$2"; }

check_ask "self-host: scripts/runstate.sh asks (the loop's own state writer)" \
  "$(sh_cwd Edit '{"file_path":"scripts/runstate.sh"}')"
check_ask "self-host: a regression SWEEP asks too (a weakened test is the same risk)" \
  "$(sh_cwd Edit '{"file_path":"scripts/test-guard.sh"}')"
check_ask "self-host: hooks/guard.sh asks (the safety floor itself)" \
  "$(sh_cwd Edit '{"file_path":"hooks/guard.sh"}')"
check_ask "self-host: vendored .claude/hooks/ asks (enforcement code too)" \
  "$(sh_cwd Edit '{"file_path":".claude/hooks/gspec-spec-integrity.mjs"}')"
check_ask "self-host: agents/*.md asks (read at dispatch)" \
  "$(sh_cwd Edit '{"file_path":"agents/implementer.md"}')"
check_ask "self-host: skills/ asks" \
  "$(sh_cwd Edit '{"file_path":"skills/run-loop/SKILL.md"}')"
check_ask "self-host: .claude-plugin/ manifest asks" \
  "$(sh_cwd Edit '{"file_path":".claude-plugin/plugin.json"}')"
# The shell path matters as much as Edit/Write: `cat >` and `sed -i` bypass diff
# review, which is exactly why guard.sh pattern-matches them as a write surface.
check_ask "self-host: shell write to hooks/ asks" \
  "$(sh_cwd Bash '{"command":"cat > hooks/guard.sh"}')"
check_ask "self-host: sed -i on a script asks" \
  "$(sh_cwd Bash '{"command":"sed -i.bak s/x/y/ scripts/metrics.sh"}')"

# The guard's own configuration — the sharper case, since these weaken the control
# rather than the code it protects.
check_ask "self-host: guard-extra-review itself asks (a deletable rule is no rule)" \
  "$(sh_cwd Edit '{"file_path":".agents/guard-extra-review"}')"
check_ask "self-host: project-overrides asks (it carries bypass-ask-tier)" \
  "$(sh_cwd Edit '{"file_path":".agents/project-overrides.yaml"}')"
check_ask "self-host: .claude/settings.json asks (hook registration)" \
  "$(sh_cwd Edit '{"file_path":".claude/settings.json"}')"

# LOAD-BEARING NON-MATCHES. `(^|/)agents/` must NOT match `.agents/`, because the
# loop writes run-state, findings and metrics constantly through runstate.sh and
# metrics.sh. Gating those would prompt on every state write and deadlock the run.
# The `(^|/)` anchor is what separates them, so it gets a test rather than a comment.
check 0 "self-host: .agents/run-state.yaml does NOT ask (loop would deadlock)" \
  "$(sh_cwd Edit '{"file_path":".agents/run-state.yaml"}')"
check 0 "self-host: .agents/findings/ does NOT ask" \
  "$(sh_cwd Edit '{"file_path":".agents/findings/f-001.md"}')"
check 0 "self-host: .agents/metrics/ does NOT ask" \
  "$(sh_cwd Edit '{"file_path":".agents/metrics/events/s.jsonl"}')"
check 0 "self-host: runstate.sh writing run-state via shell does NOT ask" \
  "$(sh_cwd Bash '{"command":"cat > .agents/run-state.yaml"}')"
check 0 "self-host: templates/ does NOT ask (data, not enforcement)" \
  "$(sh_cwd Edit '{"file_path":"templates/task-packet.yaml"}')"
check 0 "self-host: ordinary source does NOT ask" \
  "$(sh_cwd Edit '{"file_path":"src/app/page.tsx"}')"

# The hard floor is unchanged: ASK never softens a DENY.
check 2 "self-host: the hard-deny floor still outranks the ask tier" \
  "$(sh_cwd Edit '{"file_path":".env"}')"

# CONSUMER REPOS ARE UNAFFECTED. These patterns live in this repo's `.agents/`,
# not in guard.sh's shipped defaults — a consumer with no such file must see no
# change at all. Without this direction the sweep could pass while the plugin had
# quietly started prompting every user on every `scripts/` edit.
CN="$(mktemp -d)"; mkdir -p "$CN/.agents"
cn_cwd() { printf '{"cwd":"%s","tool_name":"%s","tool_input":%s}' "$CN" "$1" "$2"; }
check 0 "consumer default: scripts/ does not ask" \
  "$(cn_cwd Edit '{"file_path":"scripts/deploy-helper.sh"}')"
check 0 "consumer default: hooks/ does not ask" \
  "$(cn_cwd Edit '{"file_path":"hooks/useAuth.ts"}')"
check 0 "consumer default: agents/ does not ask" \
  "$(cn_cwd Edit '{"file_path":"agents/notes.md"}')"
check 0 "consumer default: skills/ does not ask" \
  "$(cn_cwd Edit '{"file_path":"skills/index.ts"}')"

echo "== commit soft-gate: branch × staged diff (ADR 0004) =="
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

# commit_check <expected> <desc> <cwd> [command]
commit_check() {
  local want="$1" desc="$2" cwd="$3" cmd="${4:-git commit -m x}" got payload
  payload="$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$cwd" "$cmd")"
  printf '%s' "$payload" | "$GUARD" >/dev/null 2>&1
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
commit_check 2 "main + clean -> deny"                        "$R_MAIN_CLEAN"
commit_check 0 "feature + clean -> allow"                    "$R_FEAT_CLEAN"
commit_check 2 "feature + SECRET (.env) -> deny"             "$R_FEAT_SECRET"
commit_check 0 "feature + auth CODE -> allow (ADR 0014)"     "$R_FEAT_AUTHCODE"
commit_check 0 "second feature repo + clean -> allow"        "$R_AUTON_CLEAN"
commit_check 2 "feature + SECRET (secrets/ dir) -> deny"     "$R_AUTON_SECRET"

# Fail-closed: not a git repo, and detached HEAD.
NONREPO="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $NONREPO"
commit_check 2 "non-repo cwd -> deny (fail closed)"  "$NONREPO"
R_DETACHED="$(new_repo feature)"
git -C "$R_DETACHED" checkout -q "$(git -C "$R_DETACHED" rev-parse HEAD)"
commit_check 2 "detached HEAD -> deny (fail closed)" "$R_DETACHED"

# --amend stays hard-denied (history rewrite), even when otherwise allowable.
commit_check 2 "feature + --amend -> deny (history rewrite)" \
  "$R_FEAT_CLEAN" "git commit --amend -m x"

# -a/--all bypass closed: a SECRET tracked-but-unstaged change is swept in.
R_ALL="$(new_repo feature)"
printf 'a\n' > "$R_ALL/.env"
git -C "$R_ALL" add .env >/dev/null 2>&1
git -C "$R_ALL" commit -qm "add env" >/dev/null 2>&1
printf 'b\n' >> "$R_ALL/.env"   # tracked, unstaged
commit_check 2 "feature + 'commit -am' over SECRET tracked file -> deny" \
  "$R_ALL" "git commit -am x"

echo "== git-workflow soft-gate: merge/rebase/push (ADR 0006) =="
# The guard only INSPECTS the command (branch via git, best-effort diff); it never
# runs the merge/rebase/push, so source/target branches need not actually exist.
# commit_check is generic on the command, so reuse it here.
R_WF_FEAT="$(new_repo feature)"        # on a feature branch
R_WF_MAIN="$(new_repo main)"           # on main
R_WF_DEV="$(new_repo develop)"         # on an integration branch

# --- merge: delegated only into a NON-main branch ---
commit_check 0 "feature + merge -> allow"        "$R_WF_FEAT" "git merge orch/x"
commit_check 0 "develop + merge -> allow"        "$R_WF_DEV"  "git merge orch/x"
commit_check 2 "main + merge -> deny (branch)"   "$R_WF_MAIN" "git merge orch/x"

# --- merge carrying a SECRET path re-escalates anyway ---
R_WF_SENS="$(new_repo develop)"
( git -C "$R_WF_SENS" checkout -q -b orch/sens
  printf 'x\n' > "$R_WF_SENS/.env"
  git -C "$R_WF_SENS" add .env; git -C "$R_WF_SENS" commit -qm "env"
  git -C "$R_WF_SENS" checkout -q develop ) >/dev/null 2>&1
commit_check 2 "develop + merge of SECRET-bearing branch -> deny" \
  "$R_WF_SENS" "git merge orch/sens"

# --- rebase: delegated only on a NON-main branch; -i is a rewrite ---
commit_check 0 "feature + rebase base -> allow"        "$R_WF_FEAT" "git rebase develop"
commit_check 2 "feature + rebase -i -> deny (rewrite)" "$R_WF_FEAT" "git rebase -i develop"
commit_check 2 "main + rebase -> deny (branch)"        "$R_WF_MAIN" "git rebase develop"

# --- push: never to main, never forced ---
commit_check 0 "push feature ref -> allow"          "$R_WF_FEAT" "git push origin feature"
commit_check 0 "bare push on feature -> allow"      "$R_WF_FEAT" "git push"
commit_check 2 "push origin main -> deny (target)"  "$R_WF_FEAT" "git push origin main"
commit_check 2 "push HEAD:main -> deny (target)"    "$R_WF_FEAT" "git push origin HEAD:main"
commit_check 2 "bare push on main -> deny (target)" "$R_WF_MAIN" "git push"
commit_check 2 "push -f feature -> deny (force)"    "$R_WF_FEAT" "git push -f origin feature"

# --- the danger floor still hard-denies alongside a delegable git gate ---
# rm -rf and sensitive-path writes stay HARD wherever they are issued.
commit_check 2 "rm -rf -> deny (danger floor)" \
  "$R_WF_FEAT" "rm -rf build"
check 2 "edit .env -> deny (danger floor)" \
  "$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":".env"}}' "$R_WF_FEAT")"
# Migrations / dep installs are the ASK tier — they prompt, not deny (the human
# clicks; nothing auto-approves an ask). See ADR 0008.
migrate_payload="$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"dotnet ef database update"}}' "$R_WF_FEAT")"
out="$(printf '%s' "$migrate_payload" | "$GUARD" 2>/dev/null)"; got=$?
if [ "$got" = 0 ] && printf '%s' "$out" | grep -q '"permissionDecision":[[:space:]]*"ask"'; then
  printf 'ok   (ask)     db migration -> ask (routine tier)\n'; pass=$((pass + 1))
else
  printf 'FAIL (want ask, got exit %s) db migration\n' "$got"; fail=$((fail + 1))
fi

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
commit_check 0 "cwd=main-repo + 'git -C <feat> commit' -> allow (reads feature)" \
  "$T_MAIN" "git -C $T_FEAT commit -m x"
commit_check 0 "cwd=main-repo + 'cd <feat> && git commit' -> allow" \
  "$T_MAIN" "cd $T_FEAT && git commit -m x"
commit_check 0 "cwd=main-repo + 'git -C <feat> merge' -> allow" \
  "$T_MAIN" "git -C $T_FEAT merge orch/x"
# Reverse bypass closed: cwd = feature repo, but the command targets the main repo
# — must deny (judged against the tree the command actually writes).
commit_check 2 "cwd=feat-repo + 'git -C <main-repo> commit' -> deny (reads main)" \
  "$T_FEAT" "git -C $T_MAIN commit -m x"
# `git commit -C <ref>` (reuse message) must NOT be mistaken for a target dir.
stage "$T_MAIN" "src/util.ts"   # ensure the main repo has a clean staged change
commit_check 2 "main-repo + 'git commit -C HEAD' -> deny (not a dir; still main)" \
  "$T_MAIN" "git commit -C HEAD"

echo "== config-root discovery: cwd BELOW the repo root inherits the ancestor's .agents/* =="
# Regression for the PROJECT_DIR/SHELL_CWD split (ADR 0011): the payload cwd is
# routinely a SUBDIRECTORY of the project (a package cache, a submodule, src/).
# Before the fix, config was resolved from cwd alone, so any non-root cwd found no
# `.agents/` at all: `guard-extra-bash`/`guard-extra-paths` silently stopped
# loading (fail OPEN -- the repo's declared hard-gates vanished).
R_ROOT="$(new_repo feature)"; stage "$R_ROOT" "src/util.ts"
mkdir -p "$R_ROOT/.agents"
printf '# custom risky command declared at the repo root\n(^|[^[:alnum:]])make[[:space:]]+special-deploy([^[:alnum:]]|$)\n' \
  > "$R_ROOT/.agents/guard-extra-bash"
printf '# custom sensitive path declared at the repo root\n(^|/)src/critical/\n' \
  > "$R_ROOT/.agents/guard-extra-paths"
R_SUB="$R_ROOT/pkg/sub"; mkdir -p "$R_SUB"

check 2 "cwd below repo root: guard-extra-bash enforced (was: silently allowed)" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"make special-deploy"}}' "$R_SUB")"
check 2 "cwd below repo root: guard-extra-paths enforced on Edit (was: silently allowed)" \
  "$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"src/critical/x.ts"}}' "$R_SUB")"
check 2 "cwd below repo root: guard-extra-paths enforced via shell write (was: silently allowed)" \
  "$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo x > src/critical/x.ts"}}' "$R_SUB")"

echo "== nested-repo regression: cwd = a nested checkout ON MAIN inside an outer project =="
# The regression guard for the whole PROJECT_DIR/SHELL_CWD decoupling. The outer
# project is on a feature branch, but the tree the command actually TARGETS (cwd =
# a nested checkout, e.g. a vendored clone/submodule) is on `main`. Config
# resolution (which root's rules apply) and git-target resolution (which tree the
# soft gates judge) must stay fully independent -- if a "fix" let the discovered
# config root also drive GIT_CWD, this would wrongly read the OUTER branch
# (feature) and ALLOW. It must still DENY.
R_NEST_OUTER="$(new_repo feature)"
mkdir -p "$R_NEST_OUTER/.agents"
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
commit_check 2 "nested checkout on main inside an outer project -> still DENY" \
  "$R_NEST_INNER"

echo "== restrictive config merge: a foreign root can only ever RESTRICT =="
# A foreign CLAUDE_PROJECT_DIR declaring `bypass-ask-tier: true` must not remove
# the ASK the cwd project still wants -- resolution is restrictive, so EVERY
# discovered root has to opt in and the cwd root's silence vetoes the bypass.
# Whichever root CLAUDE_PROJECT_DIR points at, discovery can only ever ADD a
# restriction, never drop one.
R_MERGE_FOREIGN="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $R_MERGE_FOREIGN"
mkdir -p "$R_MERGE_FOREIGN/.agents"
printf 'bypass-ask-tier: true\n' > "$R_MERGE_FOREIGN/.agents/project-overrides.yaml"
R_MERGE_CWD="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $R_MERGE_CWD"
mkdir -p "$R_MERGE_CWD/.agents"
merge_payload="$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"src/Auth/Login.cs"}}' "$R_MERGE_CWD")"
merge_out="$(printf '%s' "$merge_payload" | CLAUDE_PROJECT_DIR="$R_MERGE_FOREIGN" "$GUARD" 2>/dev/null)"
merge_got=$?
if [ "$merge_got" = 0 ] && printf '%s' "$merge_out" | grep -q '"permissionDecision":[[:space:]]*"ask"'; then
  printf 'ok   (ask)     foreign CLAUDE_PROJECT_DIR bypass-ask-tier cannot remove the cwd project'"'"'s ask\n'
  pass=$((pass + 1))
else
  printf 'FAIL (want ask, got exit %s) foreign CLAUDE_PROJECT_DIR bypass-ask-tier cannot remove the cwd project'"'"'s ask\n' "$merge_got"
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

echo "== driver mode (ADR 0028 / thin-loop-driver T5): refuse a main-thread write outside .agents/ =="
DM="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $DM"
mkdir -p "$DM/.agents/driver-mode"
: > "$DM/.agents/driver-mode/sess-driver"

# dm_payload <tool> <tool_input-json> [session_id] [agent_id]
dm_payload() {
  local s="" a=""
  [ -n "${3:-}" ] && s=",\"session_id\":\"$3\""
  [ -n "${4:-}" ] && a=",\"agent_id\":\"$4\""
  printf '{"cwd":"%s","tool_name":"%s","tool_input":%s%s%s}' "$DM" "$1" "$2" "$s" "$a"
}

# check_deny_category <expected-category> <desc> <payload>: asserts exit 2 AND
# that deny()'s stderr names the given category, so a driver-mode refusal
# can't be mistaken for (or mask) an unrelated deny.
check_deny_category() {
  local want_cat="$1" desc="$2" payload="$3" err got
  err="$(printf '%s' "$payload" | "$GUARD" 2>&1 >/dev/null)"; got=$?
  if [ "$got" = 2 ] && printf '%s' "$err" | grep -q "category : ${want_cat}"; then
    printf 'ok   (deny:%s) %s\n' "$want_cat" "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL (want deny:%s, got exit %s) %s\n' "$want_cat" "$got" "$desc"; fail=$((fail + 1))
  fi
}

check 2 "driver mode: Edit outside .agents/ refused" \
  "$(dm_payload Edit '{"file_path":"src/util.ts"}' sess-driver)"
check 2 "driver mode: Write outside .agents/ refused" \
  "$(dm_payload Write '{"file_path":"src/util.ts","content":"x"}' sess-driver)"
check 2 "driver mode: MultiEdit outside .agents/ refused" \
  "$(dm_payload MultiEdit '{"file_path":"src/util.ts","edits":[]}' sess-driver)"
check 2 "driver mode: NotebookEdit outside .agents/ refused" \
  "$(dm_payload NotebookEdit '{"notebook_path":"nb.ipynb","new_source":"x"}' sess-driver)"

check 2 "driver mode: sed -i outside .agents/ refused" \
  "$(dm_payload Bash '{"command":"sed -i s/a/b/ src/util.ts"}' sess-driver)"
check 2 "driver mode: cat > outside .agents/ refused" \
  "$(dm_payload Bash '{"command":"cat > src/util.ts <<EOF"}' sess-driver)"
check 2 "driver mode: tee outside .agents/ refused" \
  "$(dm_payload Bash '{"command":"echo x | tee src/util.ts"}' sess-driver)"
check 2 "driver mode: cp outside .agents/ refused" \
  "$(dm_payload Bash '{"command":"cp tmp src/util.ts"}' sess-driver)"

echo "== driver mode: .agents/ targets stay allowed =="
check 0 "driver mode: Edit under .agents/ allowed" \
  "$(dm_payload Edit '{"file_path":".agents/run-state.yaml"}' sess-driver)"
check 0 "driver mode: Write under .agents/ allowed" \
  "$(dm_payload Write '{"file_path":".agents/findings/f-001.md","content":"x"}' sess-driver)"
check 0 "driver mode: cat > .agents/ heredoc allowed" \
  "$(dm_payload Bash '{"command":"cat > .agents/run-state.yaml <<EOF"}' sess-driver)"
# I3: a Windows-separated .agents/ target needs a REAL cwd to mean anything (an
# absolute drive-letter path can't be judged against a real config root on a
# POSIX test box) -- so this is RELATIVE, cwd-anchored, and paired with a
# Windows-separated path that names something else, which must still refuse.
check 0 "driver mode: relative backslash .agents/ target allowed" \
  "$(dm_payload Edit '{"file_path":".agents\\run-state.yaml"}' sess-driver)"
check 2 "driver mode: relative backslash path outside .agents/ refused" \
  "$(dm_payload Edit '{"file_path":"src\\util.ts"}' sess-driver)"

echo "== driver mode: agent_id present -> not the main thread, allowed =="
check 0 "driver mode: same mark but agent_id present allowed (Edit)" \
  "$(dm_payload Edit '{"file_path":"src/util.ts"}' sess-driver agent-123)"
check 0 "driver mode: same mark but agent_id present allowed (Bash write)" \
  "$(dm_payload Bash '{"command":"sed -i s/a/b/ src/util.ts"}' sess-driver agent-123)"

echo "== driver mode: no mark for this session -> judged as today =="
check 0 "driver mode: another session's mark does not apply" \
  "$(dm_payload Edit '{"file_path":"src/util.ts"}' sess-other)"
check 0 "driver mode: no session_id at all -> judged as today" \
  "$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"src/util.ts"}}' "$DM")"

echo "== driver mode: session_id path traversal never denies, never reads an arbitrary path =="
check 0 "driver mode: session_id='..' treated as no mark" \
  "$(dm_payload Edit '{"file_path":"src/util.ts"}' '..')"
check 0 "driver mode: session_id='.' treated as no mark" \
  "$(dm_payload Edit '{"file_path":"src/util.ts"}' '.')"
check 0 "driver mode: session_id with a path separator treated as no mark" \
  "$(dm_payload Edit '{"file_path":"src/util.ts"}' '../driver-mode/sess-driver')"

echo "== driver mode: secret floor first, then driver-mode -- and it survives bypass-ask-tier =="
check_deny_category "secret-path" "driver mode: .env still refused as a secret, not driver-mode" \
  "$(dm_payload Edit '{"file_path":".env"}' sess-driver)"
check_deny_category "driver-mode" "driver mode: refusal names driver-mode as the category" \
  "$(dm_payload Edit '{"file_path":"src/util.ts"}' sess-driver)"

DMB="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $DMB"
mkdir -p "$DMB/.agents/driver-mode"; : > "$DMB/.agents/driver-mode/sess-byp"
printf 'bypass-ask-tier: true\n' > "$DMB/.agents/project-overrides.yaml"
check 2 "driver mode still refuses with bypass-ask-tier: true" \
  "$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"src/util.ts"},"session_id":"sess-byp"}' "$DMB")"

echo "== driver mode: git commit and an .agents/ write are unaffected =="
DM_GIT="$(new_repo feature)"; stage "$DM_GIT" "src/util.ts"
mkdir -p "$DM_GIT/.agents/driver-mode"; : > "$DM_GIT/.agents/driver-mode/sess-git"

# dm_commit_check <expected> <desc> <commit-message>: a real git commit, on a
# feature branch, with a driver-mode mark on the session.
dm_commit_check() {
  local want="$1" desc="$2" msg="$3" payload got
  payload="$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m \\"%s\\""},"session_id":"sess-git"}' \
    "$DM_GIT" "$msg")"
  printf '%s' "$payload" | "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   (exit %s) %s\n' "$got" "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL (want %s, got %s) %s\n' "$want" "$got" "$desc"; fail=$((fail + 1))
  fi
}
dm_commit_check 0 "driver mode: plain git commit still allowed" "x"
# I2: a write-pattern MATCH inside a commit message is not a real write --
# these were wrongly refused before the sanitize-then-extract fix.
dm_commit_check 0 "driver mode: commit message containing 'install' allowed" \
  "feat: install the mv/cp path"
dm_commit_check 0 "driver mode: commit message containing '->' allowed" \
  "route escalate -> decider"
# I5: both false-positive sources (a write keyword AND a redirection-shaped
# '->') in the SAME message, still allowed.
dm_commit_check 0 "driver mode: commit message with both '->' and 'install' allowed" \
  "route escalate -> decider; install step"

# I2: the rest -- a real heredoc write into .agents/ whose BODY contains every
# false-positive word at once, two /dev/null-only redirects, and a quoted
# 'tee' inside a --summary value. None of these actually write outside
# .agents/, so none should be refused.
check 0 "driver mode: heredoc into .agents/ whose body says install/->/cp allowed" \
  "$(dm_payload Bash '{"command":"scripts/runstate.sh write .agents/run-state.yaml <<'"'"'EOF'"'"'\nnote: '"'"'ran npm install; next packet; route -> cp'"'"'\nEOF"}' sess-driver)"
check 0 "driver mode: stderr-to-/dev/null read allowed" \
  "$(dm_payload Bash '{"command":"scripts/runstate.sh status 2>/dev/null"}' sess-driver)"
check 0 "driver mode: stdout-to-/dev/null read allowed" \
  "$(dm_payload Bash '{"command":"bash scripts/gspec-backlog.sh nodes > /dev/null"}' sess-driver)"
check 0 "driver mode: quoted 'tee' inside a --summary value allowed" \
  "$(dm_payload Bash '{"command":"scripts/runstate.sh add-finding f1 x --summary \"use tee for logs\""}' sess-driver)"

echo "== driver mode: CRITICAL C1 -- a real write hiding past a naive .agents/ substring check =="
check 2 "driver mode: cp names .agents/ as SOURCE, writes outside -> refused" \
  "$(dm_payload Bash '{"command":"cp .agents/x src/y"}' sess-driver)"
check 2 "driver mode: cat reads .agents/, redirect writes outside -> refused" \
  "$(dm_payload Bash '{"command":"cat .agents/f > src/z"}' sess-driver)"
check 2 "driver mode: sed -i with one good and one bad file -> refused" \
  "$(dm_payload Bash '{"command":"sed -i s/a/b/ src/x .agents/y"}' sess-driver)"
check 2 "driver mode: tee target outside, .agents/ is only the INPUT redirect -> refused" \
  "$(dm_payload Bash '{"command":"tee src/x < .agents/y"}' sess-driver)"
check 2 "driver mode: .agents/ only in a trailing comment -> refused" \
  "$(dm_payload Bash '{"command":"echo hi > src/x # .agents/"}' sess-driver)"
check 2 "driver mode: a later segment names .agents/, an earlier one doesn't -> refused" \
  "$(dm_payload Bash '{"command":"echo hi > src/x; echo > .agents/y"}' sess-driver)"

echo "== driver mode: IMPORTANT I1 -- the Edit/Write path check is ANCHORED, not a substring test =="
check 2 "driver mode: .agents/../src/x (traversal out of .agents/) refused" \
  "$(dm_payload Edit '{"file_path":".agents/../src/x"}' sess-driver)"
check 2 "driver mode: src/.agents/evil (nested, not the real .agents/) refused" \
  "$(dm_payload Edit '{"file_path":"src/.agents/evil"}' sess-driver)"
check 2 "driver mode: ../.agents/x (traversal into a parent) refused" \
  "$(dm_payload Edit '{"file_path":"../.agents/x"}' sess-driver)"
# T4 narrowing: a foreign absolute root is OUTSIDE the driven repository, so it
# cannot reach a packet's commit and driver mode no longer refuses it. It used to
# expect exit 2. Its still-refused siblings sit either side of it: a nested
# `src/.agents/` INSIDE the repository is not the real one, and `../.agents/x`
# cannot be placed at all.
check 0 "driver mode: /tmp/other/.agents/x (outside the driven repo) allowed" \
  "$(dm_payload Edit '{"file_path":"/tmp/other/.agents/x"}' sess-driver)"
check 2 "driver mode: src/my-.agents/x (.agents/ is not a leading path segment) refused" \
  "$(dm_payload Edit '{"file_path":"src/my-.agents/x"}' sess-driver)"
check 2 "driver mode: src/foo.agents/x (foo.agents != .agents) refused" \
  "$(dm_payload Edit '{"file_path":"src/foo.agents/x"}' sess-driver)"

echo "== driver mode: T4 -- the permitted class is 'cannot reach a packet's commit' =="
# The narrowing (gaps T4): driver mode exists so the driver does not make a
# packet's edits itself, so a write that cannot enter any packet's commit -- one
# resolving OUTSIDE the repository the loop is driving -- is no longer refused.
# The worked example is the driver's own agent-memory file, which lives outside
# the repository entirely. Every case that PERMITS is paired here with one that
# still refuses, because a narrowing verified only by what it now permits is not
# verified at all.
DM_OUT="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $DM_OUT"   # no .agents/ anywhere above it
DM_PHYS="$(cd "$DM" && pwd -P)"                             # the repo's REAL path
DM_LINKDIR="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $DM_LINKDIR"
ln -s "$DM_PHYS" "$DM_LINKDIR/repo"                         # a symlink INTO the repo

# (1) permitted: outside the repository -> cannot reach a packet's commit.
check 0 "T4: an out-of-repo agent-memory write allowed (the worked example)" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_OUT}/projects/some-repo/memory/MEMORY.md\"}" sess-driver)"
check 0 "T4: out-of-repo write via a shell redirect allowed" \
  "$(dm_payload Bash "{\"command\":\"echo note > ${DM_OUT}/scratch.txt\"}" sess-driver)"

# (2) still enforcing: the floors and tiers that judge that same out-of-repo call.
#     SECRET is the hard floor and runs BEFORE driver mode, so it still denies.
check_deny_category "secret-path" "T4: out-of-repo .env still hard-denied as a secret" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_OUT}/.env\"}" sess-driver)"
check_deny_category "secret-path-via-bash" "T4: out-of-repo key material still hard-denied (bash)" \
  "$(dm_payload Bash "{\"command\":\"cp tmp ${DM_OUT}/server.pem\"}" sess-driver)"
#     ORDERING: driver mode sits BEFORE the ask tier. An out-of-repo REVIEW path
#     must reach that tier and ASK -- if driver mode had drifted below it this
#     would still be exit 2, and the in-repo case just below would ASK instead of
#     denying. The two together pin the position, not just the behaviour.
check_ask "T4: out-of-repo CI config reaches the REVIEW ask tier" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_OUT}/.github/workflows/ci.yml\"}" sess-driver)"
check_deny_category "driver-mode" "T4: in-repo CI config refused by driver mode, not asked" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_PHYS}/.github/workflows/ci.yml\"}" sess-driver)"

# (3) unchanged: an IN-REPOSITORY target outside .agents/ is still refused, by
#     absolute path as well as relative -- including one reached through a
#     symlink, which a lexical prefix test would have read as "outside".
check_deny_category "driver-mode" "T4: absolute in-repo target outside .agents/ still refused" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_PHYS}/src/util.ts\"}" sess-driver)"
check 2 "T4: in-repo target via the payload's own (possibly symlinked) cwd refused" \
  "$(dm_payload Edit "{\"file_path\":\"${DM}/src/util.ts\"}" sess-driver)"
# NOTE: this is the symlinked-ANCESTOR form only (a directory symlink in the
# path's prefix). The symlink-LEAF form -- a final component that is itself a
# link into the repository -- is a separate mechanism with its own cases in the
# B1 section immediately below. This case passing says nothing about that one.
check 2 "T4: in-repo target reached through a symlink refused" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_LINKDIR}/repo/src/util.ts\"}" sess-driver)"
check 2 "T4: absolute in-repo bash write outside .agents/ refused" \
  "$(dm_payload Bash "{\"command\":\"echo x > ${DM_PHYS}/src/util.ts\"}" sess-driver)"
check 0 "T4: absolute path under the repo's own .agents/ still allowed" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_PHYS}/.agents/run-state.yaml\"}" sess-driver)"

# (4) unchanged: a repository-relative target that resolves OUTSIDE stays
#     refused -- for being unverifiable, never permitted for being outside.
#     Wrong-and-refused costs a pause; wrong-and-allowed is the leak.
check 2 "T4: relative ../outside.txt refused (resolves outside, unverifiable)" \
  "$(dm_payload Edit '{"file_path":"../outside.txt"}' sess-driver)"
check 2 "T4: relative ../../elsewhere/x refused (deeper traversal out)" \
  "$(dm_payload Edit '{"file_path":"../../elsewhere/x"}' sess-driver)"
check 2 "T4: relative ../outside.txt refused via a shell write too" \
  "$(dm_payload Bash '{"command":"cp tmp ../outside.txt"}' sess-driver)"
check 2 "T4: an unresolved \$VAR absolute-looking target still refused" \
  "$(dm_payload Bash '{"command":"cp tmp $HOME/notes.md"}' sess-driver)"

echo "== driver mode: B1 -- an existing symlink LEAF is resolved, never left unjudged =="
# The gap the T4 cases above could not see: `_driver_mode_resolve_abs` resolves
# only the nearest existing ANCESTOR directory (the tail is deliberately left
# alone, because a write legitimately creates a new file). A target whose FINAL
# component is an existing symlink into the driven repository therefore compared
# as OUTSIDE it and was permitted, while the write followed the link into the
# checkout. Reproduced by direct invocation at exit 0 before the fix.
#
# Every case here is paired by DIRECTION, because this restores a refusal and
# must not re-broaden the one T4 narrowed:
#   REFUSE cases pin that a leaf resolving INTO the repository is judged on where
#   it really lands (and that an unfollowable leaf is refused, not guessed at);
#   PERMIT cases pin that a leaf genuinely outside the repository, and one
#   pointing at the driver's own .agents/, are still allowed.
DM_LEAF="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $DM_LEAF"   # no .agents/ above it
DM_LEAF_P="$(cd "$DM_LEAF" && pwd -P)"
mkdir -p "$DM_PHYS/src"; : > "$DM_PHYS/src/util.ts"           # a real in-repo link target
: > "$DM_PHYS/.agents/run-state.yaml"                         # the driver's own surface
printf 'plain\n' > "$DM_LEAF_P/plain.txt"

ln -s "$DM_PHYS/src/util.ts"             "$DM_LEAF_P/into-repo.txt"    # leaf -> repo source
ln -s "into-repo.txt"                    "$DM_LEAF_P/chain.txt"        # 2 hops -> repo source
ln -s "$DM_PHYS/src/not-yet.ts"          "$DM_LEAF_P/dangling.txt"     # dangling -> repo source
ln -s "$DM_PHYS/.agents/run-state.yaml"  "$DM_LEAF_P/into-agents.txt"  # -> driver's own surface
ln -s "plain.txt"                        "$DM_LEAF_P/outside.txt"      # outside -> outside
ln -s "loop-b.txt"                       "$DM_LEAF_P/loop-a.txt"       # a symlink loop:
ln -s "loop-a.txt"                       "$DM_LEAF_P/loop-b.txt"       #   unfollowable
ln -s "../src/util.ts"                   "$DM_PHYS/.agents/leaf-out.txt"  # .agents/ -> repo src
ln -s "run-state.yaml"                   "$DM_PHYS/.agents/leaf-in.txt"   # .agents/ -> .agents/

# dm_check <expected-exit> <desc> <payload>: `check`, plus a structural assert
# that the payload's tool_input survived the shell. A MANGLED payload is denied
# fail-closed (exit 2, ADR 0021), so a refuse-direction case can pass while
# testing nothing -- which is exactly what happened while these cases were being
# written. In `check 2 "desc" "$(dm_payload Write "{\"a\":\"1\",\"b\":\"2\"}" …)"`
# the brace-enclosed comma BRACE-EXPANDS: dm_payload was called twice, each time
# with one half and no braces, and the case reported `ok (exit 2)` against a
# payload the guard could not parse. Interpolate a path into a multi-key JSON
# body with single-quoted segments, as below -- never with `\"` escapes.
dm_check() {
  case "$3" in
    *'"tool_input":{'*) check "$1" "$2" "$3" ;;
    *) printf 'FAIL (payload mangled before the guard saw it) %s\n' "$2"; fail=$((fail + 1)) ;;
  esac
}

# (1) REFUSE: the leaf lands inside the repository, so the write could reach a packet.
check_deny_category "driver-mode" "B1: out-of-repo leaf symlink INTO the repo refused (Edit)" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_LEAF_P}/into-repo.txt\"}" sess-driver)"
dm_check 2 "B1: the same leaf symlink refused via a shell redirect" \
  "$(dm_payload Bash "{\"command\":\"echo x > ${DM_LEAF_P}/into-repo.txt\"}" sess-driver)"
dm_check 2 "B1: a 2-hop symlink chain ending in the repo refused" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_LEAF_P}/chain.txt\"}" sess-driver)"
dm_check 2 "B1: a DANGLING leaf symlink into the repo refused (the write creates it there)" \
  "$(dm_payload Write '{"file_path":"'"${DM_LEAF_P}"'/dangling.txt","content":"x"}' sess-driver)"
dm_check 2 "B1: an unfollowable leaf (symlink loop) refused as unverifiable" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_LEAF_P}/loop-a.txt\"}" sess-driver)"
# The two check_deny_category cases either side of these need no dm_check: a
# mangled payload denies with a DIFFERENT category, so they fail loudly by
# construction. So do the check 0 permits -- a mangled payload denies, and a
# permit case asserting exit 0 cannot pass on one.
# The same defect from the other side: the lexical `<root>/.agents/` fast path
# must not hand a free pass to a link that leaves .agents/ on resolution.
check_deny_category "driver-mode" "B1: leaf symlink UNDER .agents/ pointing at repo source refused" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_PHYS}/.agents/leaf-out.txt\"}" sess-driver)"

# (2) PERMIT: still outside the repository, or still the driver's own surface.
check 0 "B1: out-of-repo leaf symlink to an out-of-repo file still allowed" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_LEAF_P}/outside.txt\"}" sess-driver)"
check 0 "B1: a plain (non-symlink) out-of-repo file in the same directory still allowed" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_LEAF_P}/plain.txt\"}" sess-driver)"
check 0 "B1: out-of-repo leaf symlink into the repo's OWN .agents/ allowed" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_LEAF_P}/into-agents.txt\"}" sess-driver)"
check 0 "B1: leaf symlink under .agents/ pointing within .agents/ allowed" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_PHYS}/.agents/leaf-in.txt\"}" sess-driver)"
check 0 "B1: an ordinary .agents/ write is unaffected by the leaf check" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_PHYS}/.agents/run-state.yaml\"}" sess-driver)"

# (3) no usable `readlink` -- the stock-Git-Bash case this hook is built around.
#     `readlink` is probed by EXECUTION, not `command -v`, and a leaf that cannot
#     be followed is REFUSED rather than assumed outside. That costs precision on
#     such a host (every symlink leaf refuses, wherever it points) and keeps the
#     direction the tier requires. The permit case is the control: it proves the
#     stubbed PATH has not simply broken the guard into denying everything.
DM_NORL="$(mktemp -d)"; COMMIT_TMPS="$COMMIT_TMPS $DM_NORL"
printf '#!/bin/sh\nexit 127\n' > "$DM_NORL/readlink"; chmod +x "$DM_NORL/readlink"
dm_norl_check() {   # <expected-exit> <desc> <payload>
  local want="$1" desc="$2" payload="$3" got
  printf '%s' "$payload" | env PATH="$DM_NORL:/usr/bin:/bin" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   (exit %s) %s\n' "$got" "$desc"; pass=$((pass + 1))
  else
    printf 'FAIL (want %s, got %s) %s\n' "$want" "$got" "$desc"; fail=$((fail + 1))
  fi
}
dm_norl_check 2 "B1: no usable readlink -> leaf symlink into the repo still REFUSED" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_LEAF_P}/into-repo.txt\"}" sess-driver)"
dm_norl_check 0 "B1: no usable readlink -> a plain out-of-repo write still allowed (control)" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_LEAF_P}/plain.txt\"}" sess-driver)"

echo "== driver mode: B1b -- the RELATIVE arm and a symlinked DIRECTORY judged the same way =="
# The half of the same defect the B1 cases above could not see, because they all
# use ABSOLUTE paths. `<root>/.agents/` was a LEXICAL permit, so two shapes still
# wrote repository source while wearing an `.agents/` name:
#   (a) the RELATIVE form of a symlink leaf -- and relative is the form a driver
#       writes by default. It is self-reachable: `ln`'s write target is its LAST
#       positional argument, so `ln -s ../src/util.ts .agents/link.txt` is
#       permitted (at judgement time that path is not yet a link -- pinned as a
#       permit below), and the write THROUGH the link was permitted too. Two
#       calls, both inside the driver's own surface, no external setup.
#   (b) a symlinked DIRECTORY under `.agents/`, in BOTH path forms: a leaf test
#       cannot see a link in the path's MIDDLE. Contrast the T4 case above where
#       a symlinked directory OUTSIDE `.agents/` was already refused by `pwd -P`
#       -- it was specifically the lexical shortcut that defeated it.
# Both close by judging physically FIRST in both arms, with the lexical test kept
# only as the resolution-FAILURE fallback. Paired by direction as before: each
# refusal has a permit beside it, so restoring these refusals cannot be mistaken
# for re-broadening the one T4 narrowed.
ln -s "$DM_PHYS/src/util.ts" "$DM_PHYS/.agents/abs-leaf.txt"   # -> repo src, absolute target
ln -s "$DM_LEAF_P/plain.txt" "$DM_PHYS/.agents/out-leaf.txt"   # -> outside the repository
ln -s "../src"               "$DM_PHYS/.agents/dirlink"        # symlinked DIR -> repo source
ln -s "$DM_LEAF_P"           "$DM_PHYS/.agents/dirlink-out"    # symlinked DIR -> outside

# A permit case would pass just as well if `ln -s` had silently failed and the
# link never existed, because a plain `.agents/` write is permitted anyway. So
# assert the fixtures really ARE links, and the permits mean what they say.
dm_require_link() {   # <path>
  if [ -L "$1" ]; then
    printf 'ok   (fixture) .agents/%s is a symlink\n' "${1##*/}"; pass=$((pass + 1))
  else
    printf 'FAIL (fixture) %s is not a symlink -- cases below would be vacuous\n' "$1"
    fail=$((fail + 1))
  fi
}
for dm_l in leaf-out.txt leaf-in.txt abs-leaf.txt out-leaf.txt dirlink dirlink-out; do
  dm_require_link "$DM_PHYS/.agents/$dm_l"
done

# (1) REFUSE: the relative form of a symlink leaf leaving .agents/ for repo source.
#     `leaf-out.txt` is the SAME link the absolute case above already refuses --
#     only the path form differs, which is the whole point.
check_deny_category "driver-mode" "B1b: RELATIVE .agents/ leaf symlink into repo source refused (Edit)" \
  "$(dm_payload Edit '{"file_path":".agents/leaf-out.txt"}' sess-driver)"
dm_check 2 "B1b: the ./ form of that same relative leaf refused" \
  "$(dm_payload Edit '{"file_path":"./.agents/leaf-out.txt"}' sess-driver)"
dm_check 2 "B1b: relative .agents/ leaf whose link target is ABSOLUTE refused" \
  "$(dm_payload Edit '{"file_path":".agents/abs-leaf.txt"}' sess-driver)"
dm_check 2 "B1b: relative .agents/ leaf refused for Write too" \
  "$(dm_payload Write '{"file_path":".agents/leaf-out.txt","content":"x"}' sess-driver)"
dm_check 2 "B1b: relative .agents/ leaf refused via a shell redirect" \
  "$(dm_payload Bash '{"command":"echo x > .agents/leaf-out.txt"}' sess-driver)"
dm_check 2 "B1b: relative .agents/ leaf refused via sed -i" \
  "$(dm_payload Bash '{"command":"sed -i s/a/b/ .agents/leaf-out.txt"}' sess-driver)"

# (2) REFUSE: a symlinked DIRECTORY under .agents/, absolute AND relative.
check_deny_category "driver-mode" "B1b: symlinked dir under .agents/ into repo source refused (absolute)" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_PHYS}/.agents/dirlink/util.ts\"}" sess-driver)"
dm_check 2 "B1b: ... and for a not-yet-existing file under that symlinked dir" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_PHYS}/.agents/dirlink/new.ts\"}" sess-driver)"
dm_check 2 "B1b: symlinked dir under .agents/ refused in the RELATIVE form" \
  "$(dm_payload Edit '{"file_path":".agents/dirlink/util.ts"}' sess-driver)"
dm_check 2 "B1b: symlinked dir under .agents/ refused via a shell redirect" \
  "$(dm_payload Bash '{"command":"echo x > .agents/dirlink/util.ts"}' sess-driver)"

# (3) PERMIT: still the driver's own surface, or still outside the repository.
#     The last one pins the reachability described above -- creating the link is
#     permitted, which is exactly why writing THROUGH it must not be.
check 0 "B1b: relative .agents/ leaf pointing WITHIN .agents/ allowed" \
  "$(dm_payload Edit '{"file_path":".agents/leaf-in.txt"}' sess-driver)"
check 0 "B1b: relative .agents/ leaf pointing OUTSIDE the repository allowed" \
  "$(dm_payload Edit '{"file_path":".agents/out-leaf.txt"}' sess-driver)"
check 0 "B1b: symlinked dir under .agents/ pointing outside the repository allowed" \
  "$(dm_payload Edit "{\"file_path\":\"${DM_PHYS}/.agents/dirlink-out/plain.txt\"}" sess-driver)"
check 0 "B1b: an ordinary relative .agents/ write is unaffected" \
  "$(dm_payload Edit '{"file_path":".agents/run-state.yaml"}' sess-driver)"
check 0 "B1b: an ordinary relative .agents/ write via a shell redirect unaffected" \
  "$(dm_payload Bash '{"command":"echo x > .agents/findings/f-002.md"}' sess-driver)"
check 0 "B1b: creating the link itself is permitted (that path is not yet a link)" \
  "$(dm_payload Bash '{"command":"ln -s ../src/util.ts .agents/not-yet-a-link.txt"}' sess-driver)"

echo "== driver mode: unresolved shell variables and dangerous constructs refuse conservatively =="
check 2 "driver mode: an unresolved \$VAR write target refused" \
  "$(dm_payload Bash '{"command":"cp tmp $VAR"}' sess-driver)"
check 2 "driver mode: command substitution alongside a write refused" \
  "$(dm_payload Bash '{"command":"cp $(echo src/util.ts) .agents/y"}' sess-driver)"
check 2 "driver mode: xargs alongside a write refused" \
  "$(dm_payload Bash '{"command":"echo .agents/y | xargs cp tmp"}' sess-driver)"

echo "== driver mode: N1 CRITICAL -- a quoted target must not vanish into nothing =="
# Blanking a quoted region to SPACES erased both the write-pattern's own
# "non-space char" evidence and the target itself. Every one of these is a
# real write outside .agents/, or opaque enough that it must be refused.
check 2 "N1: double-quoted target, spaced" \
  "$(dm_payload Bash '{"command":"echo x > \"src/y\""}' sess-driver)"
check 2 "N1: double-quoted target, glued to >" \
  "$(dm_payload Bash '{"command":"echo x >\"src/y\""}' sess-driver)"
check 2 "N1: quoted unresolved variable target" \
  "$(dm_payload Bash '{"command":"echo x > \"$TMP\""}' sess-driver)"
check 2 "N1: cp .agents/ as source, quoted dest outside" \
  "$(dm_payload Bash '{"command":"cp .agents/a \"src/y\""}' sess-driver)"
check 2 "N1: tee .agents/ and a quoted outside target" \
  "$(dm_payload Bash '{"command":"echo x | tee .agents/a \"src/y\""}' sess-driver)"
check 2 "N1: sed -i with a QUOTED expression, one bad file" \
  "$(dm_payload Bash '{"command":"sed -i 's/a/b/' src/x .agents/y"}' sess-driver)"
check 2 "N1: unquoted backslash before a stray trailing quote" \
  "$(dm_payload Bash '{"command":"echo \\\" > src/y \""}' sess-driver)"

echo "== driver mode: N2 CRITICAL -- content after a heredoc terminator is a real command =="
check 2 "N2: a write AFTER the heredoc terminator is not part of the body" \
  "$(dm_payload Bash '{"command":"cat <<'EOF' > .agents/x\nhi\nEOF\necho pwn > src/y"}' sess-driver)"

echo "== driver mode: N3 CRITICAL -- '#' is a comment only at a word boundary, to end-of-line =="
check 2 "N3: a trailing comment does not swallow the next line" \
  "$(dm_payload Bash '{"command":"echo hi # note\necho pwn > src/y"}' sess-driver)"
check 2 "N3: '#' mid-word is not a comment; the ';' after it still separates" \
  "$(dm_payload Bash '{"command":"echo a#b; echo pwn > src/y"}' sess-driver)"

echo "== driver mode: N4 CRITICAL -- a newline is a statement separator for the fast-path too =="
# Pre-existing guard bug (not driver-mode-specific): only the FIRST word of a
# multi-line command was ever checked by the read-only fast-path.
check 2 "N4: multi-line command reaches the SECRET floor (no driver mode needed)" \
  "$(bash_call '"echo hi\ncp a .env"')"
check 2 "N4: multi-line write refused in driver mode" \
  "$(dm_payload Bash '{"command":"true\ncp a src/y"}' sess-driver)"
check 0 "N4: a purely read-only multi-line command still allows (slower path)" \
  "$(bash_call '"git status\ngit log -1"')"

echo "== driver mode: N5 IMPORTANT -- the clobber redirect (>|) is a write too =="
check 2 "N5: >| target outside .agents/ refused in driver mode" \
  "$(dm_payload Bash '{"command":"echo x >| src/y"}' sess-driver)"
check 2 "N5: >| .env hits the SECRET floor (no driver mode needed)" \
  "$(bash_call '">| .env"')"

echo "== driver mode: N6 IMPORTANT -- cd/pushd invalidates every relative target =="
check 2 "N6: cd src && a relative .agents/ write is really src/.agents/" \
  "$(dm_payload Bash '{"command":"cd src && echo x > .agents/y"}' sess-driver)"

echo "== driver mode: N7 IMPORTANT -- cp -t/--target-directory, and every mv source =="
check 2 "N7a: cp -t names the real destination, not the last positional arg" \
  "$(dm_payload Bash '{"command":"cp -t src .agents/x"}' sess-driver)"
check 2 "N7b: mv removes its source too -- that is a write outside .agents/" \
  "$(dm_payload Bash '{"command":"mv src/a .agents/b"}' sess-driver)"

echo "== driver mode: M2 -- re-confirm the earlier false-positive fixes still hold =="
m2_git_cmd='git commit -F - <<'"'"'EOF'"'"'\nnote: -> tee cp >\nEOF'
m2_git_payload="$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"sess-git"}' "$DM_GIT" "$m2_git_cmd")"
printf '%s' "$m2_git_payload" | "$GUARD" >/dev/null 2>&1
got=$?
if [ "$got" = 0 ]; then
  printf 'ok   (exit 0) M2: git commit -F - heredoc body with ->/tee/cp allowed\n'; pass=$((pass + 1))
else
  printf 'FAIL (want 0, got %s) M2: git commit -F - heredoc body with ->/tee/cp allowed\n' "$got"; fail=$((fail + 1))
fi
check 0 "M2: input redirect from a quoted variable allowed" \
  "$(dm_payload Bash '{"command":"scripts/runstate.sh write .agents/run-state.yaml < \"$TMP\""}' sess-driver)"
check 0 "M2: awk redirect into .agents/ allowed" \
  "$(dm_payload Bash '{"command":"awk '{print}' file > .agents/loop/r/x"}' sess-driver)"
check 0 "M2: a read-only pipeline ending in sed (no -i) allowed" \
  "$(dm_payload Bash '{"command":"git log | grep foo | sed -E s/a/b/"}' sess-driver)"

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
# COMMITTED .agents/ (project-overrides, guard-extra), and the gates judge the
# worktree's own branch. Prove all of that.
RW1="$(new_repo develop)"
mkdir -p "$RW1/.agents"
printf 'integration_branch: develop\n' > "$RW1/.agents/project-overrides.yaml"
printf '(^|/)src/critical/\n'          > "$RW1/.agents/guard-extra-paths"
git -C "$RW1" add -A >/dev/null 2>&1; git -C "$RW1" commit -qm "agents config" >/dev/null 2>&1
WTX="$(dirname "$RW1")/$(basename "$RW1")-wtx"; COMMIT_TMPS="$COMMIT_TMPS $WTX"
git -C "$RW1" worktree add -q -b orch/lane-x "$WTX" develop >/dev/null 2>&1

# commit gate resolves the worktree's branch (orch/lane-x, not main) — the
# enabling case for parallel lanes.
commit_check 0 "worktree lane commit -> allow"  "$WTX"

# path rules fire from a worktree cwd: SECRET denies, committed guard-extra
# denies, auth CODE asks (ADR 0014), ordinary allows.
gw() { printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$WTX" "$1"; }
check 2     "worktree cwd: SECRET (.env) denied"                 "$(gw ".env")"
check 2     "worktree cwd: committed guard-extra (src/critical) denied" "$(gw "src/critical/x.ts")"
check_ask   "worktree cwd: auth CODE asks (ADR 0014)"            "$(gw "src/Auth/Login.cs")"
check 0     "worktree cwd: ordinary path allowed"                "$(gw "src/util.ts")"

echo "== one fixed rule set: the four autonomy rank comparisons are gone (retire-autonomy-levels T1) =="
# The git soft gates used to lead with `autonomy_rank $ORCH_AUTONOMY -lt ...`,
# one per gate. Every behavioural case above pins what the gates now DO; this
# pins that the mechanism itself is absent, so a level cannot be reintroduced
# silently — a reader of the cases alone could not tell a removed comparison
# from one that happens to pass. Source-level because there is no payload that
# can observe an absent branch.
if grep -qiE 'autonomy_rank|ORCH_AUTONOMY|autonomy_ceiling|resolve_autonomy|ensure_autonomy|gate:autonomy' "$GUARD"; then
  printf 'FAIL (want none) guard.sh still carries autonomy resolution or a rank comparison\n'
  fail=$((fail + 1))
else
  printf 'ok   (absent)  guard.sh carries no autonomy resolution and no rank comparison\n'
  pass=$((pass + 1))
fi

echo
echo "-----------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
