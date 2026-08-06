# ADR 0015 — `bypass-ask-tier`: repo-level opt-out of the guard's ASK tier

- Status: Accepted
- Date: 2026-07-18
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0008](0008-guard-three-tier-enforcement.md) (the ASK tier),
  [ADR 0014](0014-auth-code-is-ask-not-deny.md) (REVIEW-path writes are ASK),
  [ADR 0011](0011-guard-config-root-discovery.md) (config-root discovery/voting).
  Adds a single config knob; changes no default and no hard-deny behavior.

## Context

After ADR 0008 and ADR 0014 the guard has three effective tiers: a read-only
fast-path (allow), a **hard-deny floor** (secrets/`.env`/keys, `rm -rf`, history
rewrite, push/merge to `main`), and an **ASK tier** — a one-click native prompt for
routine-but-notable bash (`ASK_BASH_PATTERNS`: deps, migrations, deploys) and for
reversible review-worthy writes (`REVIEW_PATH_PATTERNS`: auth *code*, CI/deploy
config, appsettings).

The ASK tier is the right default: in an attended session the human clears the
prompt inline, and in an unattended loop the prompt is the checkpoint. But some
repos are run in a mode where the ask prompts are pure friction — the reviewer and
the PR gate are already the review boundary, the human trusts the loop on reversible
code, and every prompt is a reflex "yes." For those repos there was no supported way
to turn the ASK tier off short of editing the plugin or emptying the pattern arrays
(which would also disable the per-repo `guard-extra-*` additions and is not
per-repo). The escape hatch needs to be **declarative, per-repo, and unable to touch
the hard-deny floor.**

## Decision

Add a boolean `bypass-ask-tier` to `.agents/project-overrides.yaml`, default
**false**. When it resolves true, the guard **skips the entire ASK tier** and
enforces only the hard-deny floors and the git soft gates.

### Scope — exactly what it does and does not affect

- **Skips (allow, silently):** every `ask()` call — `ASK_BASH_PATTERNS`
  (deps/migrations/deploys), REVIEW-path shell writes, and REVIEW-path
  `Edit`/`Write` (auth code, CI/deploy config, appsettings).
- **Unaffected (still hard-deny / gate):** `DENY_BASH_PATTERNS` (`rm -rf`, history
  destruction, raw-device writes), `SECRET_PATH_PATTERNS` (`.env`, key material,
  secret/credential stores, plus `guard-extra-paths`), and the git soft gates
  (commit/merge/rebase/push, autonomy- and branch-gated). These all run **before**
  any `ask()` call, so the bypass can never turn a deny into an allow.

### Mechanism

One chokepoint. Every ask-tier decision already funnels through the `ask()`
function, so the flag is enforced there: `ask()` calls `ensure_bypass` and, if
bypass is true, `exit 0` (silent allow) instead of emitting the prompt. Resolution
(`read_bypass_flag` → `resolve_bypass_ask`) is lazy and memoized, mirroring
`ensure_autonomy`: a command that never reaches the ASK tier pays nothing.

### Resolution is restrictive (fail-closed), mirroring autonomy

The flag reduces restriction, so it is merged the same way autonomy privilege is
(ADR 0011): **every discovered config root must opt in.** A root that declares a
`.agents/` but does not set the flag — or sets it false/unparseable — vetoes the
bypass; with no config roots at all, bypass is false. So a foreign or nested
`.agents/` (a submodule, a vendored clone, an ancestor project) can only ever
*keep* the prompts on, never silently remove them. Ambiguity fails closed.

Truthy values: `true`/`yes`/`on`/`1` (case-insensitive). Anything else is false.

## Consequences

- **A repo can trade the ASK prompts for flow** with one line, without editing the
  plugin and without weakening the irreversible-action floor. The blast radius is
  bounded to exactly the reversible, reviewed surface the ASK tier covers.
- **The unattended story changes for opted-in repos:** at higher autonomy an
  unattended loop will now run deps/migrations/deploys and edit auth code without
  stopping. That is the point, and it is the repo owner's explicit, declared choice
  — but it is why the default is false and why the flag lives in the human-owned
  `project-overrides.yaml`, not in `.agents/autonomy`.
- **Hard-deny is provably untouched:** the tier ordering (deny before ask) plus a
  single-chokepoint implementation means no path can be constructed where bypass
  converts a hard-deny into an allow. Pinned by `bypass-ask-tier` cases in
  `scripts/test-guard.sh`: SECRET writes, `rm -rf`, and push-to-`main` still deny
  under bypass; ASK_BASH and REVIEW writes allow; default-false still asks; and a
  nested root without the flag vetoes an outer `true`.
- **No retrofit for existing consumers.** Default false = today's behavior. Repos
  opt in when they want it; the template `project-overrides.yaml` documents it.

## Alternatives considered

- **Tie it to an autonomy level** (e.g. auto-skip ASK at `full-autonomy`). Rejected:
  conflates two orthogonal axes — *how much git the loop may do* vs *whether routine
  actions prompt* — and would silently change behavior for every repo that already
  runs at full-autonomy. An explicit, separate knob is clearer and safer.
- **Per-pattern opt-out** (allow-listing specific ASK rules). Rejected as
  over-engineered for the stated need; a repo that wants finer control already has
  `guard-extra-review` (add) and can scope `guard-extra-paths`. This flag is the
  coarse "I don't want the prompts" switch.
- **Make it an env var** (`ORCH_BYPASS_ASK`) like `ORCH_AUTONOMY`. Rejected as the
  primary surface: a durable per-repo posture belongs in the committed
  `project-overrides.yaml`, reviewed like any other guard config, not in an
  ephemeral session env. (An env override could be added later if a transient
  need appears; it is intentionally out of scope here.)
