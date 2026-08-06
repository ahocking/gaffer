# ADR 0008 — Guard three-tier enforcement: read-only fast-path, ask tier, hard deny

- Status: Accepted
- Date: 2026-07-06
- Deciders: user (tech lead), orchestration plugin
- Amends: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md) and
  [ADR 0006](0006-full-autonomy-branch-integration.md). Those ADRs list dependency
  installs, migrations, and deploys as part of the hard "danger floor" that denies
  at every autonomy level. This ADR reclassifies that routine-but-notable set from
  **hard deny** to a new **ask** tier, and adds a read-only fast-path. It does not
  change the git soft gates (commit/merge/rebase/push) or the irreversible danger
  floor (history destruction, `rm -rf`, sensitive-path writes).

## Context

`hooks/guard.sh` matched every `Bash` command against one denylist
(`RISKY_BASH_PATTERNS`) and either allowed (exit 0) or hard-denied (exit 2). Two
problems made it "arbitrarily get in the way":

1. **Matching command *text* cannot tell inspection from execution.** The denylist
   ran against the raw command string, so searching *for* a risky string was
   indistinguishable from *running* it. All of these were blocked:
   - `rg "npm install" docs/`
   - `grep -rn "pip install" .`
   - `git log --grep="rm -rf cleanup"`

2. **Unanchored substrings over-matched.** The rule
   `(aws|gcloud|az) .*(deploy|delete|rm)` matched the `rm` inside `cloudformation`
   and `--format`, so read-only cloud commands were denied:
   - `gcloud compute instances list --format=json`
   - `aws cloudformation describe-stacks`

3. **Binary allow-or-hard-deny left no middle ground.** Dependency installs and
   deploys are dev-routine, but a hard `exit 2` gave the model a dead end — the
   user had to change autonomy or run the command themselves. There was no
   one-click "yes, do it."

## Decision

Replace the single denylist with **three tiers**, evaluated in order:

### 1. READ-ONLY fast-path (allow immediately)

Before any denylist runs, a `Bash` command is allowed if it is unambiguously
read-only: it contains no character that could redirect output, substitute a
command, or chain a statement (`> < \` $ ; &`), **and** every `|`-separated
pipeline segment leads with a whitelisted read-only command (`grep`, `rg`, `ls`,
`cat`, `find` without `-delete`/`-exec`, a read-only `git` subcommand, …). This is
purely additive: a command that is not clearly read-only declines the fast-path
and is evaluated exactly as before, so it can only turn a false-deny into an allow,
never an allow into a deny. `env`/`command` (which can prefix any program) and
in-place writers (`sed -i`, `tee`, `cp`) are deliberately excluded; `find` is
admitted only without its mutating primaries so `find … -delete` never slips past
the hard-deny rule.

### 2. ASK tier (native one-click prompt)

Routine-but-notable commands — dependency installs, schema migrations, and
deploys/infra changes — return a PreToolUse JSON decision
`{"permissionDecision":"ask"}` on stdout (exit 0) instead of hard-denying. Claude
Code surfaces its normal approval prompt, so the human clicks yes/no rather than
hitting a wall. The cloud rule is re-anchored to a whole word
(`… .*(^|[^[:alnum:]])(deploy|delete|rm)([^[:alnum:]]|$)`) so it fires on
`aws s3 rm …` / `gcloud app deploy` but not on `--format` / `cloudformation`.

An `ask` is **not** auto-approved by any autonomy level — it always requires a
human. So an unattended `autonomous`/`full-autonomy` loop still cannot silently run
a migration or install: it stops at the prompt, exactly as a hard gate would stop
it. The change only improves the *attended* experience.

### 3. HARD DENY (exit 2, every level)

Irreversible or never-appropriate actions stay a hard `exit 2` at every autonomy
level: git history destruction (`--force`, `reset --hard`, `clean -f`, `--amend`,
`-i` rebase), recursive/forced delete (`rm -rf`, `find -delete`), raw-device
writes, and any write to a sensitive path (auth/secrets/CI/deploy, plus per-repo
`.agents/guard-extra-paths`). Per-repo `.agents/guard-extra-bash` patterns continue
to append to this hard-deny tier — declared per-project risk stays an enforced
hard floor, not a prompt. The git soft gates (commit/merge/rebase/push) are
unchanged.

#### Sensitive-path vocabulary: two-tier auth terms

The sensitive-path matcher blocks writes to auth-ish files. Its first cut matched
a flat list of keywords anywhere in a filename, including `identity`, `session`,
`token`, `policy`, `permission`, and an unbounded `auth` stem. Those words are
heavily overloaded outside authentication, so the danger floor fired on unrelated
code — scenario-artifact `identity.ts`, `game-session.ts`, a lexer's `tokens.ts`,
`policies/retry.ts`, and even `author.ts` (the `auth` stem matched `author`). A
false deny here is not benign: the blocked write forces a human to copy the file
into place and commit by hand — routing the change *around* the guarded, reviewed
path — and repeated false alarms desensitize the operator into reflex-approving
the *real* denials. So precision is itself a safety property, not just ergonomics.

The vocabulary is now split into two tiers (see the fragment comment in
`hooks/guard.sh`):

- **STRONG** terms are auth-specific enough to gate a file or directory on their
  own: `auth`/`authn`/`authz`/`authentication`/`authorization` (bounded so
  `author`/`authors` never match), `oauth`/`oidc`, `jwt`, `rbac`, `sso`,
  `login`/`logout`/`signin`, `credentials`.
- **WEAK** terms — `identity`, `session`, `token`, `policy`/`policies`,
  `permission` — gate only when the same basename also carries an auth
  **qualifier** (`provider`, `cookie`, `claim`, `principal`, `bearer`, `csrf`,
  `refresh`, `ticket`, `token`, or any STRONG term), in either order. So
  `identity-provider.ts` and `session-token.ts` still gate, while bare
  `identity.ts` / `game-session.ts` / `session-store.ts` no longer do.

**Accepted residual false-negative:** an overloaded-word file that *is* auth but
carries no qualifier and lives outside a STRONG-named directory (e.g. a bare
`identity.ts` that really is the user-identity model, or an `access-token.ts`)
now passes. A repo that needs it re-declares the path in
`.agents/guard-extra-paths` — the same escape hatch used for domain risk. Files
under an `auth*/`/`oauth/`/… directory are unaffected: the STRONG directory rule
gates the whole subtree regardless of filename.

## Consequences

- **Searches and inspection stop being denied.** The three reported false-positive
  classes (search-for-a-risky-string, read-only cloud reads, piped reads) now
  allow, verified by new `read-only fast-path` cases in `scripts/test-guard.sh`.
- **Routine mutations prompt instead of dead-ending.** `npm install`,
  `terraform apply`, `dotnet ef database update`, etc. move from deny to ask,
  asserted by a new `check_ask` helper.
- **The irreversible surface is unchanged.** `rm -rf`, history rewrite, and
  sensitive-path writes still hard-deny at `full-autonomy`; the fast-path is proven
  not to bypass `find -delete` or an `env`-prefixed install.
- **Amendment to ADR 0004/0006 danger-floor wording.** Those ADRs described deps/
  migrations/deploys as hard gates. They are now the ask tier. The *unattended*
  safety posture is preserved (an ask blocks an unattended loop just as a deny
  did); only the attended UX changes.
- **Risk:** a genuinely dangerous install/deploy now shows a prompt a distracted
  human could click through. Mitigation: the prompt states the exact command and
  matched rule; a repo that wants any of these hard-denied re-adds it to
  `.agents/guard-extra-bash`; and the irreversible/sensitive surface never entered
  the ask tier in the first place.
- **Sensitive-path false positives removed.** The two-tier auth vocabulary stops
  the danger floor firing on overloaded words (`identity`/`session`/`token`/
  `policy`/`permission`) and on `author`. Both the retained true positives and the
  new true negatives are pinned by `two-tier auth paths` cases in
  `scripts/test-guard.sh`. Residual false-negative (an unqualified overloaded-word
  file that really is auth) is covered by `.agents/guard-extra-paths`.
