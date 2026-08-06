# ADR 0021 — the guard fails CLOSED when it cannot read its input

- Status: Accepted
- Date: 2026-08-06
- Deciders: user (tech lead), gaffer plugin
- Relates to: [ADR 0008](0008-guard-three-tier-enforcement.md) (the three tiers),
  [ADR 0014](0014-auth-code-is-ask-not-deny.md) (SECRET vs REVIEW path tiers),
  [ADR 0011](0011-guard-config-root-discovery.md) (config-root discovery).
  Changes the guard's behavior on **unreadable input** only; every tier's policy
  is untouched.

## Context

`hooks/guard.sh` decides what to block by pulling fields out of the PreToolUse
JSON payload. The extractor tried `jq`, then `python3`, then a `grep`/`sed`
regex fallback. When all three failed to produce a value, the tool branches read
the empty result as *"nothing to check"* and **allowed the call**:

```sh
[ -z "${CMD:-}" ] && exit 0        # Bash branch
[ -z "${PATH_VAL:-}" ] && exit 0   # Edit|Write|MultiEdit|NotebookEdit branch
```

A bug report from a Windows 11 / Git Bash consumer repo showed this is not
theoretical. Four independent defects, each verified by probe in this repo:

1. **`command -v python3` is true for a non-parser.** On Windows `python3`
   routinely resolves to the Microsoft Store App Execution Alias, which is on
   PATH, prints `Python was not found…` and exits 49. Presence was tested;
   capability was not. Confirmed on the maintainer's own machine.
2. **The regex fallback never unescaped JSON.** A Windows path arrives over the
   wire as `C:\\Users\\me\\src\\App\\Journal\\x.cs`; the fallback stripped the
   surrounding quotes but left the doubled separators, so it compared an
   *encoded* string against patterns written for a single separator. Nothing
   matched, nothing was blocked. This also produced a **diagnostic inversion**:
   a hand-built payload with single backslashes is *invalid* JSON, and against
   that the broken fallback matched correctly and returned exit 2 — so probing
   by hand made the guard look healthy. It cost the reporter two sessions, and
   it recurred while writing this ADR's tests.
3. **`set -euo pipefail` turned an absent key into a dead hook.** `json_field`
   ended in a pipeline whose leading `grep` exits 1 when the key is absent;
   `pipefail` propagated it, so `SHELL_CWD="$(json_field "$INPUT" cwd)"` on a
   payload without `cwd` killed the hook with **exit 1**. Claude Code treats any
   non-zero-other-than-2 as a *non-blocking* error — the same fail-open by
   another road. `read_autonomy_file` had the identical hazard for an autonomy
   file containing only comments.
4. **Every path pattern is spelled with `/`.** Found while writing the
   regression cases for (1)–(3), and independent of parsing: `(^|/)\.env(\.|$)`
   has no `/` to anchor on in `C:\Users\me\repo\.env`, so the single most
   important SECRET rule was **inert on Windows with a perfectly working `jq`**
   (verified exit 0).

The through-line is what made it dangerous: the Bash branch parses fine for
simple ASCII commands, so the guard kept blocking `rm -rf` while every path rule
— built-in `.env`/key-material floors and per-repo `guard-extra-paths` alike —
had silently stopped enforcing. There was no banner, no stderr, and no denial.
**A user could not tell a working guard from a disabled one.**

## Decision

**A control that cannot read its input must deny, not allow.**

1. **Fail closed on an unreadable payload.** This hook is registered only for
   `Bash|Edit|Write|MultiEdit|NotebookEdit`, and every one of those calls carries
   a target — a command or a path. So an empty extraction is *never* a legitimate
   absence; it is a parse failure. `deny_unreadable` blocks with category
   `payload-unreadable`, naming the field, the detected parser, and the fix.
   This applies at all three levels of the envelope: `tool_name`,
   `tool_input.command`, `tool_input.file_path`.
2. **One remaining allow-on-ignorance: an entirely empty stdin.** That is not a
   tool call (a manual probe, a harness glitch); there is nothing to judge.
3. **Probe parsers by execution, never by presence.** `detect_json_parser` feeds
   each candidate a canary and checks the answer: `jq` → `python3` → `python` →
   `none`. Detection runs **once, eagerly, in the main shell** — `json_field` is
   always called as `VAR="$(json_field …)"`, so a memo set inside that subshell
   was discarded on return, re-probing three times per invocation and leaving the
   parent unable to even report which parser it had.
4. **Keep the regex fallback, but make it decode.** `_json_unescape` handles
   `\\ \" \/ \n \r \t \b \f` and ASCII `\uXXXX` in pure bash (bash-3.2 safe, and
   there is no parser available by definition). Any escape it cannot faithfully
   decode — non-ASCII `\u`, a malformed escape — yields an empty value, which
   under (1) is a deny. A fallback that silently mismatches is worse than none;
   a fallback that decodes or refuses is worth keeping, because stock Git Bash
   ships neither `jq` nor a real `python3` and hard-requiring `jq` would brick
   the plugin there.
5. **Match paths separator-normalized.** `Edit`/`Write` matches on
   `${PATH_VAL//\\//}` while *reporting* the original spelling, and
   `cmd_hits_path` tests both the raw command and a normalized copy. Normalizing
   can only ever ADD matches, so the direction is fail-closed; testing the raw
   too keeps escape-sensitive bash matching intact. This fixes built-in **and**
   per-repo patterns at once, which rewriting the patterns as `[/\]` would not.
6. **No helper may return non-zero for a merely-absent value.** `json_field` and
   `read_autonomy_file` always `return 0` under `set -euo pipefail`.
7. **Make the health question answerable.** `hooks/guard.sh --selftest` takes no
   stdin, feeds itself a canary `Write` whose path is a JSON-escaped Windows
   path — the exact shape that defeated the old fallback — and reports the parser
   in use. Exit 0 = payloads are readable; exit 1 = the guard would deny
   everything until a parser is on PATH. The `payload-unreadable` deny hint
   points at it.

### What is deliberately NOT changed

- **No tier's policy moves.** Nothing that was allowed on a *readable* payload is
  denied now, and nothing denied is allowed. Only the unreadable case moved.
- **`jq` is not made a hard requirement.** Point 4 is why. It is documented as
  strongly recommended, and `--selftest` names it.
- **Over-matching on bash command *content* stays.** The reporter noted that a
  message merely *containing* a delete verb inside a quoted payload is blocked.
  It is real, but tightening it trades a false positive for a false negative on
  the surface with the fewest structural guarantees. Left alone on purpose.

## Consequences

- On a machine with no working parser, a genuinely malformed payload now blocks
  the tool call instead of passing it. That is the intended trade: the failure is
  loud, names the missing dependency, and is one `winget install jqlang.jq` away.
  The blast radius is bounded by the hook's own matcher — five mutating tools.
- A harness change to the payload envelope would now surface as denials rather
  than as silent non-enforcement. This is the correct direction for a safety
  control, and the deny message says exactly what to check.
- The eager parser probe costs one process spawn per invocation, replacing the
  three that the broken memoization was already paying.

## Verification

`scripts/test-guard.sh` grows 26 cases (159 → 185, all green), each run against
the payload shapes that actually failed:

- the fallback under a **hobbled PATH** (no `jq`, a `python3` shim that exits 49
  exactly like the Store stub) — JSON-escaped Windows paths hitting
  `guard-extra-paths`, the `.env` floor, and the auth ASK tier, plus the
  read-only fast-path and hard-deny bash still behaving;
- an absent optional key (`cwd`) and an all-comments autonomy file, neither of
  which may kill the hook;
- unreadable payloads at each envelope level → deny; empty stdin → allow;
- Windows-separator paths against the SECRET floor, the REVIEW ASK tier and the
  shell-write surface, each **paired with an allow case** so a deny for the wrong
  reason cannot read as a pass;
- `--selftest` green both with a real parser and on the decoding fallback.

The regression cases carry an explicit warning that payloads must be built so
`\\` survives into the JSON (defect 2's inversion), because a case that denies
for the wrong reason still prints `ok`.
