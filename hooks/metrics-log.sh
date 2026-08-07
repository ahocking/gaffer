#!/usr/bin/env bash
# =============================================================================
# metrics-log.sh — run-metrics event logger (PostToolUse hook, ADR 0019 Tier 1)
# =============================================================================
# Runs AFTER every tool call (matcher `.*` — Bash/Edit/Write AND Read/Grep/Task/
# WebFetch/…; capturing Task dispatches and context-loading reads is the whole point
# of measuring fan-out), in the main session AND inside every dispatched subagent /
# parallel lane (the guard and pause-check already prove PreToolUse-family hooks fire
# inside lane worktrees — ADR 0016 #8 / ADR 0017 — and PostToolUse delivers
# identically). It appends ONE compact JSON line per tool call to the run's event
# spine, then exits. This is the always-on, zero-token COLLECTOR half of the metrics
# feature; scripts/metrics.sh is the JOIN/ASSEMBLE half.
#
# ADVISORY-SAFE, by construction — like pause-check.sh it MUST NOT be able to
# perturb a run:
#   - it prints NOTHING on stdout, so it never emits a permissionDecision and can
#     never weaken guard.sh or any gate;
#   - it FAILS SILENT (missing jq, no git, unwritable dir, malformed payload) — a
#     metrics hook must never break the tool call it observes;
#   - exit is ALWAYS 0.
#
# PRIVACY: it logs METADATA + a few LOW-SENSITIVITY labels — timestamp, session id,
# agent id/type, tool name, per-tool duration_ms, tool_use_id, the running skill name,
# the dispatched subagent_type, and a Bash command CLASS (argv0 [+ subcommand] only).
# It still does NOT log full command text, file paths, arguments, or tool output — the
# cmd_class deliberately strips env prefixes and args and keeps only the program
# basename, so no path or secret can leak (ADR 0019 v2). The assembled packet is still
# meant to be safe to hand to Claude; full-fidelity forensics live in the (deferred)
# transcript snapshot, not here.
#
# Event dir resolution (uniform from the main checkout and any lane worktree, the
# same trick pause-check.sh uses): $ORCH_METRICS_DIR fast-path, else
# <main-checkout>/.agents/metrics/events, where <main-checkout> is derived from
# `git rev-parse --git-common-dir` (a lane's common git dir points at the MAIN repo).
# =============================================================================

set -uo pipefail

# Drain stdin up front so the writer never blocks on a full pipe. Keep the payload.
input="$(cat 2>/dev/null || true)"

# No jq -> we cannot parse the envelope. Silent no-op (never break the run).
command -v jq >/dev/null 2>&1 || exit 0

# --- resolve the main checkout (works from a lane worktree too) ---------------
main_root=""
if [ -n "${ORCH_METRICS_DIR:-}" ]; then
  evdir="$ORCH_METRICS_DIR"
else
  gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gcd" ] || gcd="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" 2>/dev/null && pwd || true)"
  [ -n "$gcd" ] || exit 0                        # not in a git repo -> nothing to do
  main_root="$(dirname "$gcd")"
  evdir="${main_root}/.agents/metrics/events"
fi

# --- lane attribution (ADR 0019 v2 / P5-M): if this event fires inside a linked
# worktree LANE (parallel mode, ADR 0016), the worktree top differs from the main
# checkout. Stamp its basename as lane_id so the assembler can measure per-lane spend
# and parallel re-load overhead. Empty for the main checkout / sequential runs.
lane=""
if [ -n "$main_root" ]; then
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && [ "$top" != "$main_root" ] && lane="$(basename "$top")"
fi

# --- enabled? (env fast-path, then project-overrides.yaml; default ON) --------
# Cheap resolution — one env read + one grep. Mirrors the guard/worktree pattern.
enabled="${ORCH_METRICS:-}"
if [ -z "$enabled" ] && [ -n "$main_root" ]; then
  ov="${main_root}/.agents/project-overrides.yaml"
  if [ -f "$ov" ]; then
    # look for `enabled:` within the `metrics:` block; false disables.
    if awk '
      /^[[:alnum:]_]+:/ { inblk = ($1 == "metrics:") }
      inblk && /^[[:space:]]+enabled:[[:space:]]*false/ { print "off"; exit }
    ' "$ov" 2>/dev/null | grep -q off; then
      enabled="off"
    fi
  fi
fi
case "$enabled" in off|false|0|no) exit 0 ;; esac

# --- extract the metadata we log (each field independently optional) ----------
sid="$(printf '%s' "$input"   | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] || exit 0                          # no session id -> nothing to key on
tool="$(printf '%s' "$input"  | jq -r '.tool_name // empty'  2>/dev/null)"
[ -n "$tool" ] || exit 0
aid="$(printf '%s' "$input"   | jq -r '.agent_id // empty'   2>/dev/null)"
atype="$(printf '%s' "$input" | jq -r '.agent_type // "main"' 2>/dev/null)"
[ -n "$atype" ] || atype="main"

# ADR 0019 v2 enrichment (all optional; each independently absent). These are the
# PostToolUse fields the Step-0 probe confirmed present in-session:
#   duration_ms  — native per-tool wall time (no Pre/Post pairing needed);
#   tool_use_id  — per-call id;
#   skill        — from the Skill tool's input (which skill/process is running);
#   subagent_type— from the Agent (dispatch) tool's input;
#   cmd_class    — Bash command HEAD ONLY (argv0 [+ subcommand]) — the rtk-targeting
#                  classifier. NO args, NO paths, NO secrets: env assignments are
#                  skipped, only the program basename (+ a sanitized subcommand for
#                  known multiplexers) is kept. This is the sole content-derived field.
dur="$(printf '%s' "$input"   | jq -r '.duration_ms // empty'  2>/dev/null)"
tuid="$(printf '%s' "$input"  | jq -r '.tool_use_id // empty'  2>/dev/null)"
skill="$(printf '%s' "$input" | jq -r 'if .tool_name=="Skill" then (.tool_input.skill // empty) else empty end' 2>/dev/null)"
subtype="$(printf '%s' "$input" | jq -r 'if .tool_name=="Agent" then (.tool_input.subagent_type // empty) else empty end' 2>/dev/null)"

# `fh` — a stable, opaque token for the file an Edit/Write touched. NOT the path.
#
# Without some file identity, two roles editing the SAME file inside one packet is
# indistinguishable from them dividing the work across different files — so rework
# (the implementer correcting itself, or the orchestrator correcting the implementer)
# cannot be separated from parallel progress. That distinction is the whole point of a
# rework rate by editor role.
#
# A HASH, not the path, because the packet is designed to be safe to hand to Claude and
# to paste into an issue: paths leak directory structure, client names, and sometimes
# secrets in the filename itself. A hash answers "same file?" — the only question the
# rework metric asks — and answers nothing else. It is deliberately NOT reversible to a
# path, so `by_file` can never become a file listing.
#
# Digest choice is availability-driven, same rule as the parser probing in guard.sh:
# shasum/sha1sum/md5/md5sum vary by platform (macOS has md5+shasum, stock Linux has
# md5sum+sha1sum, minimal containers may have none), so probe by EXECUTION and fall
# back to cksum, which is POSIX and therefore always present. Truncated to 12 chars:
# collision risk is irrelevant when the comparison set is the files touched in one run.
fh=""
case "$tool" in
  Edit|Write|NotebookEdit)
    _fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
    if [ -n "$_fp" ]; then
      if   command -v shasum  >/dev/null 2>&1 && _h="$(printf '%s' "$_fp" | shasum 2>/dev/null)";  then :
      elif command -v sha1sum >/dev/null 2>&1 && _h="$(printf '%s' "$_fp" | sha1sum 2>/dev/null)"; then :
      elif command -v md5sum  >/dev/null 2>&1 && _h="$(printf '%s' "$_fp" | md5sum 2>/dev/null)";  then :
      else _h="$(printf '%s' "$_fp" | cksum 2>/dev/null)"; fi
      # first field of every one of those tools is the digest; keep 12 chars
      fh="$(printf '%s' "${_h%% *}" | cut -c1-12)"
    fi
    ;;
esac

# `model` — an EXPLICIT model override on an Agent dispatch. Its absence is the
# NORMAL case, not a finding: the Agent tool resolves an omitted `model` to the
# target agent's own `model:` frontmatter, and every orchestration agent declares
# one (implementer=sonnet, doc-writer=haiku, architect/reviewer/chief-engineer=opus).
# That frontmatter IS the routing policy, so a plain dispatch is already correctly
# tiered. PRESENCE is therefore the signal — it means the caller deliberately
# deviated from the declared tier (run-loop §3.3) — so we stamp it only when
# present and let the assembler count OVERRIDES, not gaps. For what each role
# actually ran on, read `by_agent_role.<role>.models` (derived from transcripts),
# which is the ground truth this field cannot provide.
# (`tool_response.resolvedModel` exists but PROBED empty on this version — version-
# fragile, deliberately not used.)
model="$(printf '%s' "$input" | jq -r 'if .tool_name=="Agent" then (.tool_input.model // empty) else empty end' 2>/dev/null)"

# `ok` — did the call succeed? PROBED (2026-07-22): the payload carries NO exit code
# and no is_error field. The RESPONSE SHAPE is the signal: a successful call returns
# an OBJECT ({stdout,stderr,interrupted,...} for Bash, {filePath,...} for Edit); a
# failed one returns a STRING beginning "Error:" (e.g. "Error: Exit code 1"). Record
# ONLY the boolean — never the error text, which carries paths/output/secrets. Omitted
# when the shape is unrecognized, so a format change degrades to "absent", not wrong.
ok=""
case "$(printf '%s' "$input" | jq -r '.tool_response | type' 2>/dev/null)" in
  object) ok="true" ;;
  string)
    if printf '%s' "$input" | jq -e '.tool_response | startswith("Error:")' >/dev/null 2>&1
    then ok="false"; else ok="true"; fi ;;
esac
cmd_class=""
if [ "$tool" = "Bash" ]; then
  raw="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  if [ -n "$raw" ]; then
    # Flatten newlines to ';' so a `cd DIR<newline>realcmd` block is one segment list,
    # then split on && || ; and walk segments: skip env prefixes and nav/setup commands
    # (cd/pushd/export/source) and return the FIRST real program (+ subcommand for known
    # multiplexers). Basename only, args stripped -> no paths/secrets. Very common shape:
    # agents run `cd <repo> && <cmd>` or `cd <repo>\n<cmd>`, which must classify as <cmd>.
    cmd_class="$(printf '%s' "$raw" | tr '\n' ';' | awk '
      { s=$0; gsub(/\|\|/, ";", s); gsub(/&&/, ";", s);
        n=split(s, seg, /;/); first="";
        for (k=1; k<=n; k++) {
          line=seg[k]; sub(/^[[:space:]]+/,"",line); sub(/[[:space:]]+$/,"",line);
          if (line=="") continue;
          m=split(line, w, /[[:space:]]+/);
          i=1; while (i<=m && w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++;   # skip VAR=val env
          if (i>m) continue;                                            # pure assignment
          prog=w[i]; sub(/.*\//,"",prog);                              # basename only
          if (prog !~ /^[A-Za-z0-9_.@][A-Za-z0-9_.@:+-]*$/) continue;  # skip non-program tokens ([, -flag, $(...), case-pat))
          if (first=="") first=prog;
          if (prog=="cd"||prog=="pushd"||prog=="popd"||prog=="export"||prog=="source"||prog==".") continue;
          mux=" git docker kubectl cargo npm pnpm yarn dotnet go pip python python3 bundle rails make terraform gh aws ";
          out=prog;
          if (index(mux, " " prog " ")>0 && (i+1)<=m) { t=w[i+1]; gsub(/[^A-Za-z0-9:._-]/,"",t); if(t!="") out=prog" "t }
          print substr(out,1,40); exit
        }
        if (first!="") print substr(first,1,40) }' 2>/dev/null)"
  fi
fi

mkdir -p "$evdir" 2>/dev/null || exit 0
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- current-skill resolution (ADR 0019 v3) ----------------------------------
# The `skill` extracted above is populated ONLY when this very call is the `Skill`
# tool. That covers a vanishingly small share of real invocations: the orchestration
# skills are run as SLASH COMMANDS, which the harness expands into a prompt without
# calling the `Skill` tool at all (measured: 3 Skill events in ~6k tool calls, so
# by_skill was `{"none": everything}` in 18 of 22 captured runs). `metrics-skill.sh`
# (UserPromptSubmit) records the slash-command name to a per-session state file; here
# we (a) keep that file current when the `Skill` tool IS used, and (b) otherwise stamp
# the session's current skill onto this event, which is what makes by_skill non-empty.
# Sticky by design — see the attribution-semantics note in metrics-skill.sh.
if [ -n "$skill" ]; then
  mkdir -p "${evdir}/_state" 2>/dev/null \
    && printf '%s\n' "$skill" > "${evdir}/_state/${sid}.skill" 2>/dev/null || true
else
  skill="$(head -1 "${evdir}/_state/${sid}.skill" 2>/dev/null || true)"
fi

line="$(jq -cn \
  --arg ts "$ts" --arg sid "$sid" --arg aid "$aid" --arg at "$atype" --arg tool "$tool" \
  --arg dur "$dur" --arg tuid "$tuid" --arg skill "$skill" --arg subtype "$subtype" --arg cc "$cmd_class" \
  --arg lane "$lane" --arg model "$model" --arg ok "$ok" --arg fh "$fh" \
  '{ts:$ts,session_id:$sid,agent_id:$aid,agent_type:$at,tool:$tool}
   + (if $dur!=""     then {duration_ms:($dur|tonumber?)} else {} end)
   + (if $tuid!=""    then {tool_use_id:$tuid}            else {} end)
   + (if $skill!=""   then {skill:$skill}                 else {} end)
   + (if $subtype!="" then {subagent_type:$subtype}       else {} end)
   + (if $cc!=""      then {cmd_class:$cc}                 else {} end)
   + (if $lane!=""    then {lane_id:$lane}                else {} end)
   + (if $model!=""   then {model:$model}                 else {} end)
   + (if $ok!=""      then {ok:($ok=="true")}             else {} end)
   + (if $fh!=""      then {file_hash:$fh}                else {} end)' 2>/dev/null)" || exit 0
[ -n "$line" ] || exit 0

# Append. Concurrent parallel lanes may be subagents that SHARE the parent session
# id (agent_id distinguishes them), so several can append to the SAME <sid>.jsonl at
# once. That is safe: `>>` opens O_APPEND and each line is a single sub-PIPE_BUF
# (~4 KB) write() — well under our ~150-byte lines — so appends are atomic and never
# interleave/tear. Ordering across lanes is nondeterministic, which is irrelevant:
# metrics.sh sorts by the `ts` field on read.
printf '%s\n' "$line" >> "${evdir}/${sid}.jsonl" 2>/dev/null || true
exit 0
