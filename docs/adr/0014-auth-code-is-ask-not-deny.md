# ADR 0014 — Sensitive-path hard-deny is secrets-only; auth/CI/infra source moves to ask

- Status: Accepted
- Date: 2026-07-17
- Deciders: user (tech lead), orchestration plugin
- Supersedes: the **sensitive-path hard-deny tier** of
  [ADR 0008](0008-guard-three-tier-enforcement.md). ADR 0008 lumped auth code,
  CI/deploy/infra config, and secrets into a single `SENSITIVE_PATH_PATTERNS`
  array that hard-denies (`exit 2`) writes at every autonomy level. This ADR
  splits that array in two: a **secret-exposure floor** that keeps hard-deny, and
  a **review tier** (auth code, CI/deploy/infra config) that moves to the **ask**
  tier ADR 0008 already built. It does not touch the read-only fast-path, the
  `ASK_BASH_PATTERNS` bash tier, or the irreversible bash floor (history
  destruction, `rm -rf`, raw-device writes). It leaves the git soft-gate **policy**
  unchanged but applies one **precision** fix to the gate's command router so it
  stops misfiring on read-only `git merge-base` (§6).

## Context

`hooks/guard.sh` hard-denies any `Edit`/`Write` (and shell write) whose target
matches `SENSITIVE_PATH_PATTERNS` (guard.sh:162). That one array conflates three
different risk types under one `exit 2` dead-end:

| Category | Example patterns | Underlying risk | Reversible? |
|---|---|---|---|
| Secret exposure | `.env`, `secrets/`, `credentials/`, `*.pem`/`*.key`/`*.pfx` | A leaked secret **cannot be un-leaked** | **No** |
| CI / deploy / infra | `.github/workflows/`, `Dockerfile`, `k8s/`, `terraform/`, `*.tf` | Can trigger irreversible *external* actions when run | Config itself: yes |
| **Auth source code** | `auth*/` (whole subtree), `LoginForm.tsx`, `jwt.ts`, `rbac.ts` | A subtle security **bug** | **Yes** — version-controlled, testable, PR-reviewed |

Three problems follow from treating these as one tier:

1. **Auth code is miscategorized.** Editing auth *source* is a normal, reversible,
   reviewed code change — the same risk class as any other important code, not the
   same class as leaking a secret. Secrets earn a hard wall because exposure is the
   one thing you can't take back; source edits have no such property.

2. **A hard-deny on code doesn't produce the review it claims to want, and ADR
   0008 already says so.** [ADR 0008:90](0008-guard-three-tier-enforcement.md:90)
   observes that a false deny *"forces a human to copy the file into place and
   commit by hand — routing the change around the guarded, reviewed path — and
   repeated false alarms desensitize the operator into reflex-approving the real
   denials. So precision is itself a safety property."* That argument was applied
   only to tightening the keyword vocabulary. Carried to its conclusion it argues
   against hard-denying auth *writes* at all: blocking the edit adds no review, it
   just reroutes the change around the guard and trains the operator to click
   through the alarms that matter.

3. **The auth *directory* rule over-gates by construction.** A static path rule
   cannot distinguish the JWT-verify function from the login button's CSS, so the
   directory rule gates the entire subtree — tests, DTOs, types, error strings, the
   folder's README. [ADR 0008:114](0008-guard-three-tier-enforcement.md:114) states
   this as intended (*"gates the whole subtree regardless of filename"*). For a
   folder of source files that guarantees the false-positive rate operators hit
   day to day, with no local escape hatch (guard-extra-paths only *adds* patterns;
   it cannot subtract one).

The net effect: the tier that fires most often in ordinary frontend/config work is
a dead-end (`exit 2`), while the genuinely routine-but-notable *bash* actions
(deps, migrations, deploys) get a one-click prompt. The friction is inverted.

## Decision

Split `SENSITIVE_PATH_PATTERNS` into two arrays and route them to two different
tiers.

### 1. `SECRET_PATH_PATTERNS` — hard-deny (`exit 2`), every level

The exposure floor. Writing one of these is treated as irreversible, exactly as
today:

- `.env` / `.env.*`
- `secrets/`, `credentials/`, `vault/` directory segments
- `*secret*`, `*credential*`, `*apikey*`, `*password*`, `*private-key*` files with
  a secret-bearing extension (`.json/.yaml/.env/.txt/.pem/.key`)
- `*.pem`, `*.key`, `*.pfx`, `*.p12`

**`.agents/guard-extra-paths` appends here** (unchanged contract). Per-repo declared
risk — money movement, PHI, grading, a repo's declared domain rules — stays an *enforced
hard floor*, not a prompt. This preserves the promise ADR 0008 and the consumer
retrofit rely on.

### 2. `REVIEW_PATH_PATTERNS` — ask tier (one-click native prompt)

Review-worthy but reversible. A write here emits
`{"permissionDecision":"ask"}` (the mechanism from ADR 0008 §2), so the human
clicks yes/no instead of hitting a wall:

- Auth **code**: the STRONG/WEAK auth vocabulary from ADR 0008 — filename rules
  unchanged, and the STRONG *directory* rule **constrained to code files** (see §3).
- CI / deploy / infra: `.github/workflows/`, `Dockerfile`, `docker-compose.*`,
  `k8s|kubernetes|helm|charts|deploy|terraform|infra/` dirs, `*.tf`/`*.tfvars`,
  `.gitlab-ci.yml`, `azure-pipelines.yml`, `Jenkinsfile`, `.circleci/`.
- `appsettings*.json` (config, not a dedicated secret store; real secrets there
  belong in user-secrets/env and are caught by the secret floor).

New per-repo hook `.agents/guard-extra-review` appends here (ask-tier additions),
mirroring `guard-extra-paths` but for the softer tier.

### 3. Constrain the auth *directory* rule to code files (not drop it)

The STRONG auth directory rule (guard.sh:165) currently matches *any* file under an
`auth*/`/`oauth/`/… directory, regardless of extension — which is exactly why a doc
under such a folder (`docs/auth/overview.md`, `docs/oauth/setup.md`) hard-denies. It
is **not** dropped — dropping it would silently un-gate real auth code whose filename
carries no auth term (`auth/middleware.ts`, `oauth/callback.ts`, `authz/guards.ts`).
Instead it is **restricted to a source-code extension** (`_AUTH_EXT`) and moved to
the ask tier:

```
(^|/)<STRONG>([^[:alnum:]/][^/]*)?/[^[:space:]]*\.<AUTH_EXT>$
```

- `src/auth/middleware.ts`, `src/oauth/callback.ts` → **ask** (auth code still
  covered — just a one-click prompt, not a wall).
- `docs/auth/overview.md`, `docs/oauth/setup.md` → **allow** (`.md` ∉ `_AUTH_EXT`;
  the doc false-positive that motivated this is gone).

A doc that happens to be an auth-named *config* file (`docs/examples/oauth.json`)
matches the code-ext rule and gets a one-click ask, not a wall — an acceptable
residual. A repo that wants a whole directory hard-denied regardless of extension
re-declares it in `.agents/guard-extra-paths`.

### 4. Ask-tier path support for `Edit`/`Write`

Today the `Edit|Write|MultiEdit|NotebookEdit` case only has a `deny` path
(guard.sh:780). It gains an ask path: match `SECRET_PATH_PATTERNS` → `deny`; else
match `REVIEW_PATH_PATTERNS` → `ask`. The shell-write check (`cmd_hits_sensitive_path`)
splits the same way: a shell write to a secret path hard-denies; to a review path
it asks.

### 5. Commit/merge soft gates check the secret floor only

`check_commit_policy` / `check_merge_policy` currently block a commit/merge whose
diff touches any `SENSITIVE_PATH_PATTERNS` file (guard.sh:573, :625). They now check
`SECRET_PATH_PATTERNS` only. Committing a branch that edited auth *code* is a normal
delegable commit (it's reviewed downstream); sweeping a secret file into a commit
stays blocked. This keeps the autonomous loop from ever committing a secret while
removing the surprise deny on ordinary auth-code commits.

### 6. Companion precision fix: git soft-gate routing must not match `merge-base`

Independent of the path tiers, the git soft-gate router (guard.sh:688)

```
grep_Eq_git() { grep -Eq "${GIT_PREFIX}$1([^[:alnum:]]|$)"; }
```

treats the `-` in `merge-base` as a valid word boundary, so `grep_Eq_git merge`
fires on the read-only plumbing command `git merge-base` and routes it into the
merge soft-gate (denied below full-autonomy). `merge-base` is already in
`READ_ONLY_GIT`, so a *bare* `git merge-base main HEAD` is fast-pathed and fine —
but the instant it appears inside `$(…)`, a redirect, or a `;`/`&&` chain (which
disqualifies the read-only fast-path), the loose matcher catches it. Same latent
bug for `merge-tree`/`merge-file`/`commit-tree`.

The boundary is tightened to exclude the hyphen:

```
grep -Eq "${GIT_PREFIX}$1([^[:alnum:]-]|$)"
```

so `git merge orch/x` (space) and `git merge` (EOL) still route, while
`git merge-base` no longer does. This is a precision fix in the exact spirit of ADR
0008's cloud-verb anchoring (`--format`/`cloudformation`), not a policy change.

## Consequences

- **The most common false-positive class becomes a one-click prompt.** Editing
  `LoginForm.tsx`, a file under `auth/`, `appsettings.Development.json`, or a
  Dockerfile now asks instead of dead-ending. In an attended session the human
  approves inline; the change no longer has to be routed around the guard.
- **Secret exposure is unchanged.** `.env`, `*.pem`, `credentials/`, and every
  `guard-extra-paths` domain pattern still hard-deny at every autonomy level. The
  one irreversible risk in the old array keeps its wall.
- **Unattended posture is preserved.** An `ask` is never auto-approved by any
  autonomy level (ADR 0008 §2), so an unattended `autonomous`/`full-autonomy` loop
  still *stops* at an auth-code or CI write exactly as a deny stopped it — it just
  stops at a prompt a present human can clear, instead of a wall.
- **`guard-extra-paths` semantics are intact**; new `guard-extra-review` is purely
  additive. No consumer repo loses enforcement.
- **Directory over-gating is gone.** A folder of source files is no longer treated
  as a secret.
- **Risk:** an auth-code change a distracted human clicks through unreviewed. This
  is the same residual risk ADR 0008 accepted for deps/deploys, and the mitigation
  is the same — the prompt names the exact file and matched rule; a repo that wants
  a specific auth path hard-denied re-adds it to `.agents/guard-extra-paths`; and
  the secret-exposure floor never entered the ask tier.
- **Test sweep:** `scripts/test-guard.sh` gains cases asserting (a) secret paths
  still `exit 2`; (b) auth-code / CI / `appsettings` writes now emit `ask`; (c) a
  file merely *inside* `auth/` but not auth-named no longer gates; (d)
  `guard-extra-paths` still hard-denies and new `guard-extra-review` asks; (e) a
  commit touching auth code is allowed while a commit touching a secret is denied.

## Alternatives considered

- **Leave auth code hard-denied, tighten vocabulary further.** This is the ADR 0008
  path continued. Rejected: no vocabulary is precise enough to separate the
  security-critical *lines* from their neighbors in the same file, and the tier is
  still a dead-end. Precision-tuning treats the symptom; the tier is the cause.
- **Add a `guard-allow-paths` subtract mechanism instead of reclassifying.** Lets a
  repo carve out its own false positives while keeping the hard-deny default.
  Rejected as the *primary* fix (keeps a wall the operator must discover and fight
  per repo) but worth revisiting as a companion for the secret floor — tracked
  separately, not part of this ADR.
- **Downgrade everything, including secrets, to ask.** Rejected: secret exposure is
  the one irreversible case in the array. It keeps its wall.
