# Security Policy

This plugin's core value is a **safety guardrail**: a PreToolUse hook
(`hooks/guard.sh`) and an autonomy model that gate what a Claude Code agent may
do on your behalf. Because that surface is security-relevant, we take reports
about it seriously — and we're explicit below about what it does and does not
protect against, so reports land on the right things.

## Reporting a vulnerability

**Please do not open a public issue for a security vulnerability.**

Report it privately through GitHub's **Report a vulnerability** flow (the
repository's **Security** tab → **Advisories** → **Report a vulnerability**).
This opens a private advisory visible only to you and the maintainers.

Please include:

- The affected file(s) and version/commit.
- A concrete reproduction — for a guard bypass, the exact tool envelope or shell
  command that should have been denied/asked but was allowed.
- The impact you believe it has.

We aim to acknowledge a report within a few days and to work toward a fix and a
coordinated disclosure. Please give us reasonable time to address the issue
before disclosing it publicly.

## Supported versions

Security fixes target the **latest released version** and the `main` branch.
Older tags are not maintained.

## Threat model — what the guardrail is, and is not

The guardrail exists to stop an **over-eager or mistaken AI agent** from taking
an irreversible or high-risk action without a human in the loop. It is a
speed bump and an approval gate, **not a sandbox** and **not a defense against a
malicious operator or a compromised environment.** Keep that boundary in mind
when deciding whether something is a vulnerability.

**In scope** (please report):

- A way to make a **hard-deny** gate allow an action it should block — git
  history destruction (`force`-push, `reset --hard`, `--amend`, interactive
  rebase, `git -C`/`git -c` forms), recursive/raw-device deletes, commit/merge/
  push to `main`/`master`, or a write to a secret path (`.env`, keys,
  credential stores).
- A payload that makes `guard.sh` **fail open** on input it is designed to deny
  (e.g. an envelope shape or quoting trick that slips past parsing into an
  allow).
- A bypass of the **autonomy resolution or config-root discovery** that *loosens*
  the guard — e.g. making a higher autonomy level or a permissive `guard-extra`
  apply when the restrictive merge rule should have clamped it down (adding a
  config root must only ever *tighten*).
- Any committed **secret, token, or credential**, or a path that leaks one.
- Path-traversal or injection in the deterministic cores (`guard.sh`,
  `runstate.sh`, `packet-graph.sh`, `worktree.sh`).

**Out of scope** (by design, not a bug):

- The guard gates *writes* to sensitive paths, not *reads*. It is not an
  exfiltration sandbox; it does not try to stop an agent from *reading* secrets
  it has filesystem access to.
- A consumer intentionally loosening their **own** repo's rules (e.g. via
  `bypass-ask-tier` or their own `guard-extra-*`). They own their repo; the plugin
  resolves restrictively across roots but cannot override a repo's owner.
- The **cooperative pause** not force-stopping a subagent. By design the pause
  hook injects a *context-only advisory* (never a `permissionDecision`), and the
  authoritative stop is the agent's prompt-poll at a safe checkpoint — not the
  hook. This is documented in ADR 0017; correctness does not depend on the hook,
  and a "the advisory didn't hard-halt an agent" report is expected behavior, not
  a vulnerability.
- Risks from an untrusted MCP server, a malicious plugin loaded alongside this
  one, or a compromised host. Those are outside this plugin's control.

## Design notes worth reading

The guard fails **closed** on any hard-deny match and on unreadable input (not a
repo, detached HEAD, unreadable diff), and fails **open** only when it cannot
parse the tool envelope at all. The tier model, the restrictive config-root
merge, and the pause semantics are documented in the ADRs under
[`docs/adr/`](docs/adr/) (0008, 0011, 0014, 0015, 0017 are the most
security-relevant). Reading those first will make a report sharper.
