#!/usr/bin/env bash
# =============================================================================
# test-migrate.sh — regression sweep for the v2.0.0 retrofit (scripts/migrate.sh)
# =============================================================================
# Synthetic repos on disk, no live agent. Exit 0 = all passed.
#
# The fixtures deliberately reproduce the shapes found in REAL pre-2.0 consumer
# repos, because those are what broke a naive migration:
#   - task lines `**T000 Description.**`   (id + description in one bold span)
#   - task lines `**ser-t1** **P0** ...`   (feature-prefixed kebab id)
#   - capability lines `**P0 — Text**`     (priority + text in one bold span)
#   - plan files with NO frontmatter at all
# A migration that only renames files passes none of the packet assertions here.
# =============================================================================

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIG="$HERE/migrate.sh"
ADAPTER="$HERE/gspec-backlog.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected: $2
     got: $3";; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "should not contain: $2";; *) ok "$1";; esac; }
# have_yaml -- true if a real YAML parser (python3 + PyYAML) is available. The one
# place this probe lives; yamlok(), yaml_cursor() and the notice below all call it
# rather than each carrying their own copy to drift out of sync.
have_yaml() { command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; }

# YAML_SKIP_COUNT -- how many parse-assertion helpers (below) had to loudly skip
# for lack of a parser on this host. Surfaced in the summary line at the bottom so
# a parser-less green-looking run cannot be mistaken for one that actually parsed.
YAML_SKIP_COUNT=0

# yamlok <file> -- true if some available parser accepts it. Same technique as
# test-runstate.sh (ADR 0022): "it usually parses" is not a property worth having
# for run-state, the loop's only durable state, so a mutating subcommand earns a
# real parse assertion, not a grep -- and LOUDLY skips (a counted, reported FAIL,
# never a silent pass) when no parser is available on this host.
yamlok() {
  if have_yaml; then
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$1" 2>/dev/null
  else
    YAML_SKIP_COUNT=$((YAML_SKIP_COUNT + 1))
    return 1   # no parser available -> the caller's own bad() reports a real FAIL
  fi
}
# yaml_cursor <file> -- prints the REAL parsed value of backlog.cursor. `yamlok`
# only proves the file parses; the blank-line corruption case (T##) parses cleanly
# while silently folding the following orphaned list item into `cursor` as a
# multi-line string, so only reading the resolved value back out (not grepping the
# source line, which is untouched byte-for-byte) can catch it. Exits 2 (distinct
# from a legitimately empty cursor) when no parser is available, so a caller can
# tell "no parser" apart from "cursor parsed to empty" -- collapsing those two into
# one "empty string" return was the sharper defect this helper had: a caller
# comparing only the printed value, never the exit status, read a no-parser skip as
# a pass. NOTE: every real caller reads this exit status through `$(yaml_cursor …)`
# command substitution, which forks a subshell -- so YAML_SKIP_COUNT is bumped by
# the CALLER on rc=2, not in here, or the increment would be lost with the subshell.
yaml_cursor() {
  if ! have_yaml; then
    return 2
  fi
  python3 -c "
import yaml, sys
d = yaml.safe_load(open(sys.argv[1])) or {}
b = d.get('backlog') or {}
sys.stdout.write(str(b.get('cursor', '')))
" "$1" 2>/dev/null
}
if ! have_yaml; then
  YAML_SKIP_COUNT=$((YAML_SKIP_COUNT + 1))
  bad 'a YAML parser is available for the parse-assertion cases below' \
      'no python3+PyYAML on this host — not asserting vacuously; every yamlok()/yaml_cursor() case below now correctly reports FAIL instead of silently passing'
fi
# yaml_cursor_is <desc> <file> <expected> -- asserts the REAL parsed backlog.cursor
# equals <expected>. yaml_cursor's exit 2 (no parser) is reported as its own loud,
# counted FAIL here rather than being read as agreement with <expected> -- the
# defect this pairing exists to avoid.
yaml_cursor_is() {
  local desc="$1" file="$2" want="$3" got rc
  got="$(yaml_cursor "$file")"; rc=$?
  if [ "$rc" = 2 ]; then
    YAML_SKIP_COUNT=$((YAML_SKIP_COUNT + 1))
    bad "$desc" 'no python3+PyYAML on this host — not asserting vacuously'
  elif [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "got: $got"
  fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fixture: a pre-2.0 repo in the shape the real ones are in ---------------
mk_repo() { # mk_repo <dir> <task-style: legacy-a|legacy-b|canonical>
  local d="$1" style="$2"
  mkdir -p "$d/gspec/features" "$d/.agents"
  cat > "$d/gspec/features/alpha.md" <<'EOF'
---
spec-version: v1
---
# Feature: Alpha
- [x] **P0 — Shipped capability**
- [ ] **P1 — Open capability**
EOF
  cat > "$d/gspec/features/beta.md" <<'EOF'
---
spec-version: v1
---
# Feature: Beta
- [ ] **P0 — Needs alpha first**
EOF
  case "$style" in
    legacy-a) cat > "$d/gspec/features/alpha.plan.md" <<'EOF'
# Plan — Alpha

- [x] **T000 Bootstrap the thing.** Some detail.
- [ ] **T001 Build the open capability.** More detail.
EOF
      ;;
    legacy-b) cat > "$d/gspec/features/alpha.plan.md" <<'EOF'
# Plan — Alpha

- [x] **alp-t1** **P0** **[GATE: schema]** Bootstrap.
- [ ] **alp-t2** [P] **P0** Build the open capability.
EOF
      ;;
    canonical) cat > "$d/gspec/features/alpha.plan.md" <<'EOF'
---
spec-version: v1
feature: alpha
---
## Plan
- [x] **T1** **P0** bootstrap
  - deps: —
- [ ] **T2** **P0** build the open capability
  - deps: T1
EOF
      ;;
  esac
  cat > "$d/gspec/roadmap.md" <<'EOF'
# gspec/roadmap.md — sequencing

<!-- prose the converter cannot translate -->

features:
  - slug: alpha
    order: 1
    depends_on: []
    parallel_group: A
    status: active
    why: the foundation everything builds on
  - slug: beta
    order: 2
    depends_on: [alpha]
    parallel_group: B
    status: queued
    why: needs alpha

## Notes
Some strategic prose that must survive in the original file.
EOF
  printf 'allowed_paths:\n  specs:\n    - "gspec/features/**"\n    - "gspec/roadmap.md"\n' > "$d/.agents/project-overrides.yaml"
  printf '# Repo brief\nExecution runs off gspec/roadmap.md + per-feature .plan.md.\n' > "$d/CLAUDE.md"
  printf '.agents/run-state.yaml\n' > "$d/.gitignore"
  git -c init.defaultBranch=main init -q "$d"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=t@e -c user.name=t commit -qm base >/dev/null 2>&1
}

# =============================================================================
printf '\n== detect ==\n'
R="$TMP/detect"; mk_repo "$R" legacy-a
out="$("$MIG" detect "$R" 2>&1)"; rc=$?
has 'reports a pre-2.0 repo'           'FROM=pre-2.0' "$out"
has 'finds the misplaced plan files'   'FINDING=plans' "$out"
has 'finds the in-gspec roadmap'       'FINDING=roadmap' "$out"
has 'finds stale allowed_paths'        'FINDING=overrides' "$out"
has 'finds the stale CLAUDE.md'        'FINDING=claudemd' "$out"
has 'finds the pause-sentinel gap'     'FINDING=gitignore' "$out"
# The write backup (runstate.sh write's last-known-good copy) must be ignored too, or
# it lands as `?? .agents/` and reconcile discards it as scratch on the green
# checkpoint — the backup destroyed by the recovery path it exists to serve.
has 'finds the write-backup ignore gap' 'FINDING=writebackup-ignore' "$out"
[ "$rc" = 2 ] && ok 'detect exits 2 when migration is needed' || bad 'detect exit 2' "rc=$rc"

printf '\n== detect: a current repo is left alone ==\n'
# "Current" means the gspec 3.x feature-folder layout at spec-version v2. This
# fixture was a 2.x repo and had to change with the pin: a repo that would now
# correctly report the gspec-v2-layout finding is not the right fixture for
# "nothing to do", and leaving it would have made every future assertion in this
# section pass against a repo the script has something to say about.
R="$TMP/current"; mkdir -p "$R/gspec/features/a" "$R/.agents"
printf -- '---\nspec-version: v2\n---\n- [ ] **P0**: x\n' > "$R/gspec/features/a/prd.md"
printf -- '---\nspec-version: v2\nfeature: a\n---\n- [ ] **T1** **P0** do it\n' > "$R/gspec/features/a/tasks.md"
printf 'schema: 1\nfeatures: []\n' > "$R/.agents/roadmap.yaml"
printf '.agents/pause\n.agents/run-state-prev.yaml\n' > "$R/.gitignore"
out="$("$MIG" detect "$R" 2>&1)"; rc=$?
has 'a current repo reports no findings' 'FINDINGS=0' "$out"
[ "$rc" = 0 ] && ok 'detect exits 0 when nothing to do' || bad 'detect exit 0' "rc=$rc"
out="$("$MIG" plan "$R" 2>&1)"
has 'plan says there is nothing to do' 'Nothing to do' "$out"
out="$("$MIG" verify "$R" 2>&1)"
has 'verify says the layout is current' 'every plan is in the gspec 3.x feature-folder layout' "$out"
has 'and the backlog still yields a packet' '1 plan file(s) -> 1 unchecked packet(s)' "$out"

# =============================================================================
printf '\n== detect: the gspec 3.x layout is REPORTED, never applied ==\n'
# The decision this pins: /gaffer:migrate detects the pre-3.x layout and names
# /gspec-migrate; it does not move the files. gspec owns spec format and layout
# (ADR 0020), and the move needs link repair and per-file reformatting that a
# shell script cannot do. A future edit that "helpfully" adds the move here
# should fail this case rather than pass quietly.
R="$TMP/v2layout"; mkdir -p "$R/gspec/tasks" "$R/gspec/features" "$R/.agents"
printf -- '---\nspec-version: v1\n---\n- [ ] **P0**: x\n' > "$R/gspec/features/a.md"
printf -- '---\nspec-version: v1\nfeature: a\n---\n- [ ] **T1** **P0** do it\n' > "$R/gspec/tasks/a.md"
printf 'schema: 1\nfeatures: []\n' > "$R/.agents/roadmap.yaml"
printf '.agents/pause\n.agents/run-state-prev.yaml\n' > "$R/.gitignore"
out="$("$MIG" detect "$R" 2>&1)"
has 'the pre-3.x layout is a finding'  'FINDING=gspec-v2-layout' "$out"
has 'it names the destination layout'  'gspec/features/<slug>/' "$out"
has 'it names the remedy'              '/gspec-migrate' "$out"
has 'and says this script will not do it' 'deliberately does not do' "$out"
# Worded as "your gspec commands moved on", NOT as breakage: the adapter reads
# every layout, so an unmigrated repo's loop works fine and saying otherwise
# would be false.
has 'the reason given is /gspec-plan divergence, not loop breakage' 'WRITES to the new one' "$out"

out="$("$MIG" apply "$R" --force 2>&1)"
[ -f "$R/gspec/tasks/a.md" ] && ok 'apply leaves the pre-3.x plan exactly where it is' \
  || bad 'apply must not relocate to the feature folder' "$(find "$R/gspec" -type f)"
[ ! -e "$R/gspec/features/a/tasks.md" ] && ok 'and creates no feature folder' \
  || bad 'apply created a feature folder' "$(find "$R/gspec" -type f)"
[ -f "$R/gspec/features/a.md" ] && ok 'and leaves the flat PRD in place' \
  || bad 'apply moved the PRD' "$(find "$R/gspec" -type f)"
out="$("$MIG" verify "$R" 2>&1)"; rc=$?
has 'verify reports the split layout'  'still pre-3.x' "$out"
# Informational, not a failure: nothing is wrong with this repo.
has 'and still goes green'             'VERIFY=ok' "$out"
[ "$rc" = 0 ] && ok 'verify exits 0 on a readable pre-3.x repo' || bad 'verify exit 0' "rc=$rc"

# =============================================================================
printf '\n== detect: a HALF-moved feature is its own finding ==\n'
# The shape /gspec-migrate leaves if it is interrupted. Both directions matter,
# and the first is the dangerous one: completion is DERIVED from the PRD, so a
# folder with a plan and no PRD can never read as done, and everything depending
# on that feature stays blocked forever.
R="$TMP/halfmoved"; mkdir -p "$R/gspec/features/a" "$R/.agents"
printf -- '---\nspec-version: v2\nfeature: a\n---\n- [ ] **T1** **P0** do it\n' > "$R/gspec/features/a/tasks.md"
printf 'schema: 1\nfeatures: []\n' > "$R/.agents/roadmap.yaml"
printf '.agents/pause\n.agents/run-state-prev.yaml\n' > "$R/.gitignore"
out="$("$MIG" detect "$R" 2>&1)"
has 'a plan with no PRD is flagged'    'FINDING=half-moved' "$out"
has 'and names the file that is missing' 'no prd.md' "$out"
has 'and says why it is not cosmetic'  'can never read as done' "$out"

# The reverse: PRD moved, plan did not. Harmless today, but the next /gspec-plan
# writes to the folder and the repo ends up with two plans for one feature.
R="$TMP/halfmoved2"; mkdir -p "$R/gspec/features/a" "$R/gspec/tasks" "$R/.agents"
printf -- '---\nspec-version: v2\n---\n- [ ] **P0**: x\n' > "$R/gspec/features/a/prd.md"
printf -- '---\nspec-version: v1\nfeature: a\n---\n- [ ] **T1** **P0** do it\n' > "$R/gspec/tasks/a.md"
printf 'schema: 1\nfeatures: []\n' > "$R/.agents/roadmap.yaml"
printf '.agents/pause\n.agents/run-state-prev.yaml\n' > "$R/.gitignore"
out="$("$MIG" detect "$R" 2>&1)"
has 'a stranded plan is flagged'       'FINDING=half-moved' "$out"
has 'and names both halves'            'gspec/tasks/a.md' "$out"
has 'and says nothing is broken yet'   'nothing breaks' "$out"

printf '\n== apply refuses to run on a dirty tree ==\n'
R="$TMP/dirty"; mk_repo "$R" legacy-a
printf 'scratch\n' > "$R/uncommitted.txt"
out="$("$MIG" apply "$R" 2>&1)"; rc=$?
has 'a dirty tree is refused'   'working tree is dirty' "$out"
[ "$rc" != 0 ] && ok 'and it exits non-zero' || bad 'dirty exit' "rc=$rc"
[ -f "$R/gspec/features/alpha.plan.md" ] && ok 'nothing was moved on refusal' || bad 'refusal moved files'

# =============================================================================
for style in legacy-a legacy-b canonical; do
printf '\n== apply: %s task shape ==\n' "$style"
R="$TMP/apply-$style"; mk_repo "$R" "$style"
out="$("$MIG" apply "$R" 2>&1)"

has 'the plan file moves to gspec/tasks/' 'MOVED=gspec/features/alpha.plan.md -> gspec/tasks/alpha.md' "$out"
[ -f "$R/gspec/tasks/alpha.md" ] && ok 'plan is at its new path' || bad 'plan at new path'
[ -f "$R/gspec/features/alpha.plan.md" ] && bad 'old plan path still exists' || ok 'old plan path is gone'
git -C "$R" log --diff-filter=R --oneline >/dev/null 2>&1 && ok 'moved via git (history preserved)' || bad 'git mv'

has 'the roadmap converts'   'CONVERTED=gspec/roadmap.md -> .agents/roadmap.yaml (2 feature entries)' "$out"
[ -f "$R/gspec/roadmap.md" ] && ok 'the original roadmap is KEPT, never deleted' || bad 'roadmap deleted'
rm_out="$(cat "$R/.agents/roadmap.yaml")"
has 'slug survives'          'slug: alpha' "$rm_out"
has 'order survives'         'order: 1' "$rm_out"
has 'why survives'           'the foundation everything builds on' "$rm_out"
has 'depends_on survives'    'depends_on: [alpha]' "$rm_out"
# Assert on the FIELD form, not the word: the converted file's header comment
# legitimately explains that both were dropped and why.
fields="$(grep -E '^[[:space:]]+[a-z_]+:' "$R/.agents/roadmap.yaml" | sed 's/:.*//' | sort -u | tr '\n' ' ')"
hasnt 'status is DROPPED'         'status' "$fields"
hasnt 'parallel_group is DROPPED' 'parallel_group' "$fields"

# THE assertion: the backlog must actually parse, not merely relocate.
pk="$("$ADAPTER" nodes alpha "$R" 2>/dev/null | grep -c . || true)"
[ "${pk:-0}" -ge 1 ] && ok "packets come out the other end ($pk)" \
  || bad 'migration produced ZERO packets — a rename that reads as "nothing to do"' "packets=$pk"
has 'verify passes'  'VERIFY=ok' "$out"
done

printf '\n== apply: frontmatter is stamped only where missing ==\n'
R="$TMP/fm"; mk_repo "$R" legacy-a
out="$("$MIG" apply "$R" 2>&1)"
has 'stamping is reported'       'STAMPED=1' "$out"
# The NEWEST supported version, not the first. GSPEC_SPEC_VERSIONS is a READ
# set ("v1 v2") and taking $1 from it stamped v1 the moment the pin widened --
# producing a file gspec's own spec-integrity floor (which demands v2)
# immediately flags. A file with no marker is being written now, so it is
# written current.
has 'spec-version is stamped current' 'spec-version: v2' "$(head -3 "$R/gspec/tasks/alpha.md")"
has 'feature slug is stamped'    'feature: alpha' "$(head -4 "$R/gspec/tasks/alpha.md")"
has 'the version pin now passes' 'specs pass the gspec version pin' "$out"

R="$TMP/fm-keep"; mk_repo "$R" canonical
"$MIG" apply "$R" >/dev/null 2>&1
[ "$(grep -c '^spec-version:' "$R/gspec/tasks/alpha.md")" = 1 ] \
  && ok 'existing frontmatter is not duplicated' || bad 'frontmatter duplicated'

printf '\n== apply: an existing destination is never overwritten ==\n'
R="$TMP/collide"; mk_repo "$R" legacy-a
mkdir -p "$R/gspec/tasks"; printf 'PRE-EXISTING\n' > "$R/gspec/tasks/alpha.md"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.email=t@e -c user.name=t commit -qm pre >/dev/null 2>&1
out="$("$MIG" apply "$R" 2>&1)"
has 'the collision is reported'  'SKIP=gspec/tasks/alpha.md already exists' "$out"
has 'the destination is intact'  'PRE-EXISTING' "$(cat "$R/gspec/tasks/alpha.md")"
[ -f "$R/gspec/features/alpha.plan.md" ] && ok 'the source is left for reconciliation' || bad 'source removed on collision'

printf '\n== verify: catches the silent-empty-backlog failure ==\n'
R="$TMP/empty"; mkdir -p "$R/gspec/tasks" "$R/gspec/features"
printf -- '---\nspec-version: v1\n---\n- [ ] **P0** — open\n' > "$R/gspec/features/a.md"
# A plan whose "tasks" are prose bullets: relocated, unreadable, and NOT done.
printf -- '---\nspec-version: v1\nfeature: a\n---\n## Plan\n- do a thing\n- do another\n' > "$R/gspec/tasks/a.md"
out="$("$MIG" verify "$R" 2>&1)"; rc=$?
has 'zero packets is called out'    'produce ZERO packets' "$out"
has 'and named as the real failure' 'nothing to do' "$out"
has 'verify reports problems'       'VERIFY=problems' "$out"
[ "$rc" = 3 ] && ok 'verify exits 3 on a problem' || bad 'verify exit 3' "rc=$rc"

printf '\n== apply: report conventions are stamped into CLAUDE.md ==\n'
# The consumer-facing half of the report-format fix. A repo whose CLAUDE.md does not
# carry the conventions reports in free prose on every turn outside a gaffer skill,
# so `detect` names it and `apply` stamps it VERBATIM (a paraphrase drifts from the
# plugin's contract, and the marker is what suppresses the SessionStart hook).
R="$TMP/conv"; mk_repo "$R" legacy-a
out="$("$MIG" detect "$R" 2>&1)"
has 'detect names the missing conventions' 'FINDING=report-conventions' "$out"
out="$("$MIG" apply "$R" 2>&1)"
has 'apply reports the stamp'      'STAMPED_CONVENTIONS=' "$out"
has 'the marker lands'             'gaffer:report-conventions' "$(cat "$R/CLAUDE.md")"
has 'the glyph vocabulary lands'   '✅ landed' "$(cat "$R/CLAUDE.md")"
has 'the decision block lands'     '**→ Pick A**' "$(cat "$R/CLAUDE.md")"
has 'the project prose survives'   'Execution runs off' "$(cat "$R/CLAUDE.md")"
# BYTE-VERBATIM, not "close enough": drift between the card, the CLAUDE.md overlay
# and the hook injection is the whole failure this layering exists to prevent.
card="$HERE/../templates/report-conventions-card.md"
if diff <(tail -n +2 "$card") <(awk '/gaffer:report-conventions/{f=1;next} f' "$R/CLAUDE.md") >/dev/null 2>&1; then
  ok 'the card is inserted byte-verbatim'
else
  bad 'the card is inserted byte-verbatim' "stamped CLAUDE.md differs from templates/report-conventions-card.md"
fi
out="$("$MIG" detect "$R" 2>&1)"
hasnt 'and detect stops reporting it' 'FINDING=report-conventions' "$out"

printf '\n== apply: the card lands BEFORE the routing section when there is one ==\n'
# The overlay keeps it there, so a migrated repo should end up matching a bootstrapped
# one. Appending is only the fallback for a CLAUDE.md with no routing section.
R="$TMP/conv-routing"; mk_repo "$R" legacy-a
printf '# Repo brief\nExecution runs off gspec/roadmap.md + per-feature .plan.md.\n\n## Routing — how to engage the team\n\nroute things here.\n' > "$R/CLAUDE.md"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.email=t@e -c user.name=t commit -qm rt >/dev/null 2>&1
"$MIG" apply "$R" >/dev/null 2>&1
marker_line="$(grep -n 'gaffer:report-conventions' "$R/CLAUDE.md" | cut -d: -f1)"
routing_line="$(grep -n '^## Routing' "$R/CLAUDE.md" | cut -d: -f1)"
[ -n "$marker_line" ] && [ -n "$routing_line" ] && [ "$marker_line" -lt "$routing_line" ] \
  && ok 'the card is inserted above the routing section' \
  || bad 'card placement' "marker=$marker_line routing=$routing_line"
has 'the routing section survives intact' 'route things here.' "$(cat "$R/CLAUDE.md")"

printf '\n== apply: an existing marker is never double-stamped ==\n'
R="$TMP/conv-twice"; mk_repo "$R" legacy-a
"$MIG" apply "$R" >/dev/null 2>&1
"$MIG" apply "$R" --force >/dev/null 2>&1
n="$(grep -c 'gaffer:report-conventions' "$R/CLAUDE.md")"
[ "$n" = 1 ] && ok 'the marker appears exactly once' || bad 'double-stamped' "marker count=$n"

printf '\n== apply: a repo with no CLAUDE.md is left alone ==\n'
R="$TMP/conv-none"; mk_repo "$R" legacy-a; rm -f "$R/CLAUDE.md"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.email=t@e -c user.name=t commit -qm rm >/dev/null 2>&1
out="$("$MIG" apply "$R" 2>&1)"
hasnt 'nothing is stamped'   'STAMPED_CONVENTIONS=' "$out"
[ -f "$R/CLAUDE.md" ] && bad 'a CLAUDE.md was created' || ok 'no CLAUDE.md is created out of thin air'

printf '\n== idempotence: a second apply changes nothing ==\n'
R="$TMP/twice"; mk_repo "$R" legacy-a
"$MIG" apply "$R" >/dev/null 2>&1
before="$(find "$R/gspec" -type f | sort | md5 2>/dev/null || find "$R/gspec" -type f | sort | md5sum)"
out="$("$MIG" apply "$R" --force 2>&1)"
after="$(find "$R/gspec" -type f | sort | md5 2>/dev/null || find "$R/gspec" -type f | sort | md5sum)"
[ "$before" = "$after" ] && ok 'the file set is unchanged on re-run' || bad 're-run changed the file set'
has 'and it says so' 'NOCHANGE' "$out"

printf '\n== detect/apply: legacy backlog.done drains via the adapter, never gspec/ (T17) ==\n'
R="$TMP/backlogdone"; mk_repo "$R" canonical
mkdir -p "$R/.agents/findings"
# The findings: block below (with a quoted summary containing a colon -- the
# exact shape runstate.sh's own single-quoted encoding produces, ADR 0022) is
# the fixture the post-apply YAML-parse assertion needs: _drop_backlog_done is
# a new mutation of this file, and a mutating subcommand earns a real parse
# assertion (or a loud, counted FAIL in place of one on a parser-less host,
# never a silent pass), not a grep (same rule test-runstate.sh applies to every
# one of ITS mutating subcommands).
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
    - alpha-t1
    - alpha-t2
    - ghost-t1
  pending:
    - alpha-t2
findings:
  - id: f-colon
    summary: 'a note with a colon: right here'
    file: .agents/findings/f-colon.md
    packets: [alpha-t1]
EOF
printf 'body for f-colon\n' > "$R/.agents/findings/f-colon.md"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "add run-state" >/dev/null 2>&1

out="$("$MIG" detect "$R" 2>&1)"; rc=$?
has 'detect finds the legacy backlog.done block'        'FINDING=backlog-done' "$out"
has 'and reports the still-unchecked id via the adapter' 'UNCHECKED=alpha-t2' "$out"
hasnt 'a finished id is NOT reported as unchecked'       'UNCHECKED=alpha-t1' "$out"
hasnt 'an id unknown to gspec is NOT reported as unchecked (it is unknown, not unchecked)' 'UNCHECKED=ghost-t1' "$out"
[ "$rc" = 2 ] && ok 'detect exits 2 when migration is needed' || bad 'detect exit 2' "rc=$rc"

# Minor 3: _drop_backlog_done must carry run-state's own mode onto the temp
# file (cp -p), the same discipline cmd_check_task uses in gspec-backlog.sh --
# a bare mktemp+mv would silently narrow it to mktemp's 0600.
modebefore="$(stat -f%Lp "$R/.agents/run-state.yaml" 2>/dev/null || stat -c%a "$R/.agents/run-state.yaml" 2>/dev/null)"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
has 'apply reports the unchecked id BEFORE the block is dropped' 'UNCHECKED=alpha-t2' "$out"
has 'apply reports the drop itself'                               'DROPPED=' "$out"
grep -q '^[[:space:]]*done:[[:space:]]*$' "$R/.agents/run-state.yaml" \
  && bad 'apply drops the done: block' "still present: $(cat "$R/.agents/run-state.yaml")" \
  || ok 'apply drops the done: block'
rs="$(cat "$R/.agents/run-state.yaml")"
has 'cursor survives untouched'  'cursor: alpha-t2' "$rs"
has 'pending survives untouched' 'pending:' "$rs"
has 'and its one entry survives' '- alpha-t2' "$rs"
has 'findings: survives the drop untouched'      "id: f-colon" "$rs"
has 'including the colon inside its quoted summary' "a note with a colon: right here" "$rs"
yamlok "$R/.agents/run-state.yaml" \
  && ok '_drop_backlog_done leaves a REAL-parseable run-state.yaml (not just grep-shaped)' \
  || bad '_drop_backlog_done leaves a REAL-parseable run-state.yaml' "$(cat "$R/.agents/run-state.yaml")"
has 'verify asserts the block is gone' 'no legacy backlog.done block' "$out"
[ "$rc" = 0 ] && ok 'apply+verify exit 0 once the block is drained' || bad 'apply+verify exit 0' "rc=$rc"

modeafter="$(stat -f%Lp "$R/.agents/run-state.yaml" 2>/dev/null || stat -c%a "$R/.agents/run-state.yaml" 2>/dev/null)"
[ -n "$modebefore" ] && [ "$modebefore" = "$modeafter" ] \
  && ok '_drop_backlog_done preserves run-state.yaml'"'"'s file mode (Minor 3)' \
  || bad '_drop_backlog_done preserves file mode' "before=$modebefore after=$modeafter"

# apply never flips a checkbox reconciling the unchecked id -- reverted work is
# a human decision, never made here.
grep -qF -- '- [ ] **T2** **P0** build the open capability' "$R/gspec/tasks/alpha.md" \
  && ok 'apply does not flip the still-unchecked task while draining backlog.done' \
  || bad 'apply must not flip while draining backlog.done' "$(cat "$R/gspec/tasks/alpha.md")"

# idempotence: a second apply reports nothing left to drop.
out2="$("$MIG" apply "$R" --force 2>&1)"
hasnt 'a second apply finds no backlog.done left to report' 'UNCHECKED=' "$out2"
hasnt 'and reports no further drop'                          'DROPPED=' "$out2"

printf '\n== apply: a comment line INSIDE the done: list must not orphan it (Important 1) ==\n'
R="$TMP/backlogdone-comment"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
    - alpha-t1
    # a stray comment inside the done: list
    - alpha-t2
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "add run-state with a commented done: list" >/dev/null 2>&1

out="$("$MIG" apply "$R" 2>&1)"
grep -q '^[[:space:]]*done:[[:space:]]*$' "$R/.agents/run-state.yaml" \
  && bad 'apply drops the commented done: block' "still present: $(cat "$R/.agents/run-state.yaml")" \
  || ok 'apply drops the commented done: block'
yamlok "$R/.agents/run-state.yaml" \
  && ok 'the result is REAL-parseable YAML with a comment inside done: (Important 1)' \
  || bad 'the result is real-parseable YAML with a comment inside done:' "$(cat "$R/.agents/run-state.yaml")"
rs="$(cat "$R/.agents/run-state.yaml")"
has 'cursor survives untouched'  'cursor: alpha-t2' "$rs"
has 'pending survives untouched' 'pending:'         "$rs"
has 'and its one entry survives' '- alpha-t2'       "$rs"
yaml_cursor_is 'the PARSED cursor value is still exactly alpha-t2, not corrupted' \
  "$R/.agents/run-state.yaml" alpha-t2

printf '\n== apply: a BLANK line INSIDE the done: list must not orphan it (Important 1) ==\n'
R="$TMP/backlogdone-blank"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<EOF
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
    - alpha-t1

    - alpha-t2
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "add run-state with a blank line in done: list" >/dev/null 2>&1

out="$("$MIG" apply "$R" 2>&1)"
grep -q '^[[:space:]]*done:[[:space:]]*$' "$R/.agents/run-state.yaml" \
  && bad 'apply drops the done: block with a blank line inside it' "still present: $(cat "$R/.agents/run-state.yaml")" \
  || ok 'apply drops the done: block with a blank line inside it'
# This is the dangerous case: yamlok alone is not enough, because the bug
# still parses -- it silently folds the orphaned list item into `cursor` as a
# multi-line string. Only reading the resolved value back out catches it, and on
# a parser-less host that resolved value cannot be read at all -- a loud, counted
# FAIL, not a silent skip (yamlok below is a real but weaker fallback: it only
# proves the file parses, not that `cursor` holds the right value).
cur="$(yaml_cursor "$R/.agents/run-state.yaml")"; cur_rc=$?
if [ "$cur_rc" = 2 ]; then
  YAML_SKIP_COUNT=$((YAML_SKIP_COUNT + 1))
  bad 'the resume cursor is not silently rewritten by the blank line' \
      'no python3+PyYAML on this host — not asserting vacuously'
else
  [ "$cur" = "alpha-t2" ] \
    && ok 'the resume cursor is NOT silently rewritten by the blank line (Important 1)' \
    || bad 'the resume cursor is not silently rewritten by the blank line' "got: $(printf '%s' "$cur" | sed -n l)"
fi
yamlok "$R/.agents/run-state.yaml" \
  && ok 'the result is REAL-parseable YAML with a blank line inside done:' \
  || bad 'the result is real-parseable YAML with a blank line inside done:' "$(cat "$R/.agents/run-state.yaml")"
rs="$(cat "$R/.agents/run-state.yaml")"
has 'pending survives untouched' 'pending:'   "$rs"
has 'and its one entry survives' '- alpha-t2' "$rs"

printf '\n== detect/apply/verify: an UNRELATED nested done: key must converge (Important 2) ==\n'
R="$TMP/nesteddone"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  pending:
    - alpha-t2
checklist:
  done:
    - something
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "add run-state with an unrelated nested done:" >/dev/null 2>&1

out="$("$MIG" detect "$R" 2>&1)"
hasnt 'detect does not flag an unrelated nested done: key as backlog-done' 'FINDING=backlog-done' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
hasnt 'apply reports no DROPPED= for the unrelated done: key' 'DROPPED=' "$out"
has   'and verify (run inside apply) reports the clean state' 'no legacy backlog.done block' "$out"
[ "$rc" = 0 ] && ok 'apply+verify converge to exit 0 -- the unrelated done: key never blocks it' \
  || bad 'apply+verify converge to exit 0 with an unrelated done: key' "rc=$rc"
rs="$(cat "$R/.agents/run-state.yaml")"
has 'the unrelated checklist: key survives untouched' 'checklist:' "$rs"
has 'its done: key survives untouched'                '  done:'   "$rs"
has 'and its item survives untouched'                 '- something' "$rs"

# idempotence: a second apply converges the same way, not a permanent 3/0 flap.
out2="$("$MIG" apply "$R" --force 2>&1)"; rc2=$?
hasnt 'a second apply still reports no DROPPED=' 'DROPPED=' "$out2"
[ "$rc2" = 0 ] && ok 'a second apply is still exit 0 (no detect/apply/verify non-convergence)' \
  || bad 'a second apply stays exit 0' "rc=$rc2"

printf '\n== detect/verify: a repo with no legacy backlog.done is unaffected (T17) ==\n'
R="$TMP/nobacklogdone"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "add clean run-state" >/dev/null 2>&1
out="$("$MIG" detect "$R" 2>&1)"
hasnt 'no FINDING=backlog-done when there is no done: block' 'FINDING=backlog-done' "$out"
out="$("$MIG" verify "$R" 2>&1)"
has 'verify still reports the clean state' 'no legacy backlog.done block' "$out"

printf '\n== detect/apply/verify: items at the done: key'"'"'s OWN indent (round 4, Defect 1) ==\n'
# Valid, indentless-sequence YAML -- the default emission of PyYAML/js-yaml --
# where the list items sit at the SAME indent as `done:` itself, not deeper.
R="$TMP/done-ownindent"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
  - alpha-t1
  - alpha-t2
  pending:
  - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "own-indent done: list" >/dev/null 2>&1

out="$("$MIG" detect "$R" 2>&1)"
has 'detect recognizes an own-indent done: list' 'FINDING=backlog-done' "$out"
hasnt 'and does not call it unrecognized' 'FINDING=backlog-done-unrecognized' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
grep -q '^[[:space:]]*done:[[:space:]]*$' "$R/.agents/run-state.yaml" \
  && bad 'apply drops the own-indent done: block' "still present: $(cat "$R/.agents/run-state.yaml")" \
  || ok 'apply drops the own-indent done: block'
yamlok "$R/.agents/run-state.yaml" \
  && ok 'the result is REAL-parseable YAML (Defect 1)' \
  || bad 'the result is real-parseable YAML (own-indent)' "$(cat "$R/.agents/run-state.yaml")"
yaml_cursor_is 'the PARSED cursor value is exactly alpha-t2 (own-indent)' \
  "$R/.agents/run-state.yaml" alpha-t2
rs="$(cat "$R/.agents/run-state.yaml")"
has 'pending survives untouched' '- alpha-t2' "$rs"
[ "$rc" = 0 ] && ok 'apply+verify converge to exit 0' || bad 'apply+verify exit 0 (own-indent)' "rc=$rc"

printf '\n== detect/apply/verify: a NESTED MAPPING list item is UNRECOGNIZED, never dropped (round 4) ==\n'
R="$TMP/done-nestedmap"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
    - id: alpha-t1
      note: something extra
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "nested-mapping done: item" >/dev/null 2>&1
cp "$R/.agents/run-state.yaml" "$TMP/rsf-nestedmap.before"

out="$("$MIG" detect "$R" 2>&1)"
has 'detect reports it as unrecognized, distinctly from the recognized finding' \
  'FINDING=backlog-done-unrecognized' "$out"
hasnt 'and does NOT also report it as a normal (droppable) backlog-done finding' \
  'FINDING=backlog-done	' "$out"
has 'and says plainly it needs a human / will not be dropped' 'human' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
hasnt 'apply never claims a DROPPED= for an unrecognized shape' 'DROPPED=' "$out"
has 'apply reports the unrecognized block instead' 'UNRECOGNIZED_BACKLOG_DONE=' "$out"
cmp -s "$TMP/rsf-nestedmap.before" "$R/.agents/run-state.yaml" \
  && ok 'run-state.yaml is BYTE-IDENTICAL after apply (nested mapping item)' \
  || bad 'run-state.yaml byte-identical (nested mapping item)' \
       "$(diff "$TMP/rsf-nestedmap.before" "$R/.agents/run-state.yaml")"
has 'verify flags it with the alert glyph, not a clean checkmark' '⚠' "$out"
hasnt 'verify does not print a clean ✓ for this file' \
  '✓ no legacy backlog.done block in .agents/run-state.yaml' "$out"
hasnt 'and the run overall does not claim VERIFY=ok' 'VERIFY=ok' "$out"
[ "$rc" = 3 ] && ok 'apply exits 3 -- verification found a problem it will not silently fix' \
  || bad 'apply exits 3 for an unrecognized backlog-done block' "rc=$rc"

printf '\n== detect/apply/verify: a FOLDED SCALAR list item ("- >") is UNRECOGNIZED (round 4) ==\n'
R="$TMP/done-folded"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
    - >
      alpha-t1
      spread across lines
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "folded-scalar done: item" >/dev/null 2>&1
cp "$R/.agents/run-state.yaml" "$TMP/rsf-folded.before"

out="$("$MIG" detect "$R" 2>&1)"
has 'detect reports the folded scalar shape as unrecognized' 'FINDING=backlog-done-unrecognized' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
hasnt 'apply never drops a folded-scalar done: block' 'DROPPED=' "$out"
cmp -s "$TMP/rsf-folded.before" "$R/.agents/run-state.yaml" \
  && ok 'run-state.yaml is BYTE-IDENTICAL after apply (folded scalar item)' \
  || bad 'run-state.yaml byte-identical (folded scalar item)' \
       "$(diff "$TMP/rsf-folded.before" "$R/.agents/run-state.yaml")"
[ "$rc" = 3 ] && ok 'apply exits 3 for the folded-scalar shape' || bad 'apply exit 3 (folded scalar)' "rc=$rc"

printf '\n== detect/apply/verify: a MAPPING-valued done: (id: date entries, no dash items) is UNRECOGNIZED (round 5) ==\n'
R="$TMP/done-mapping"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t3
  done:
    alpha-t1: 2026-08-01
    alpha-t2: 2026-08-02
  pending:
    - alpha-t9
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "mapping-valued done:" >/dev/null 2>&1
cp "$R/.agents/run-state.yaml" "$TMP/rsf-mapping.before"

out="$("$MIG" detect "$R" 2>&1)"
has 'detect reports the mapping-valued done: as unrecognized' 'FINDING=backlog-done-unrecognized' "$out"
hasnt 'and does NOT also report it as a normal (droppable) backlog-done finding' \
  'FINDING=backlog-done	' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
hasnt 'apply never drops a mapping-valued done: block' 'DROPPED=' "$out"
cmp -s "$TMP/rsf-mapping.before" "$R/.agents/run-state.yaml" \
  && ok 'run-state.yaml is BYTE-IDENTICAL after apply (mapping-valued done:)' \
  || bad 'run-state.yaml byte-identical (mapping-valued done:)' \
       "$(diff "$TMP/rsf-mapping.before" "$R/.agents/run-state.yaml")"
[ "$rc" = 3 ] && ok 'apply exits 3 for the mapping-valued done: shape' || bad 'apply exit 3 (mapping-valued done:)' "rc=$rc"

printf '\n== detect/apply/verify: an ANCHORED list item ("- &a alpha-t1") is UNRECOGNIZED (round 5) ==\n'
R="$TMP/done-anchor"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
    - &a alpha-t1
  pending:
    - *a
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "anchored done: item, referenced elsewhere" >/dev/null 2>&1
cp "$R/.agents/run-state.yaml" "$TMP/rsf-anchor.before"

out="$("$MIG" detect "$R" 2>&1)"
has 'detect reports the anchored item as unrecognized' 'FINDING=backlog-done-unrecognized' "$out"
hasnt 'and does NOT also report it as a normal (droppable) backlog-done finding' \
  'FINDING=backlog-done	' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
hasnt 'apply never drops an anchored done: item (the anchor is referenced elsewhere)' 'DROPPED=' "$out"
cmp -s "$TMP/rsf-anchor.before" "$R/.agents/run-state.yaml" \
  && ok 'run-state.yaml is BYTE-IDENTICAL after apply (anchored item)' \
  || bad 'run-state.yaml byte-identical (anchored item)' \
       "$(diff "$TMP/rsf-anchor.before" "$R/.agents/run-state.yaml")"
[ "$rc" = 3 ] && ok 'apply exits 3 for the anchored-item shape' || bad 'apply exit 3 (anchored item)' "rc=$rc"

printf '\n== regression: legitimate multi-line SCALAR continuations still RECOGNIZED and still drop (round 5 gate) ==\n'
R="$TMP/done-scalarcont"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
    - alpha
      t1
    - 'alpha
      t2'
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "multi-line scalar continuation done: items" >/dev/null 2>&1

out="$("$MIG" detect "$R" 2>&1)"
has 'detect still recognizes the multi-line scalar continuation shape' 'FINDING=backlog-done' "$out"
hasnt 'and still does not call it unrecognized' 'FINDING=backlog-done-unrecognized' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
grep -q '^[[:space:]]*done:[[:space:]]*$' "$R/.agents/run-state.yaml" \
  && bad 'apply drops the multi-line scalar continuation block' "still present: $(cat "$R/.agents/run-state.yaml")" \
  || ok 'apply drops the multi-line scalar continuation block'
yamlok "$R/.agents/run-state.yaml" \
  && ok 'the result is REAL-parseable YAML (multi-line scalar continuation)' \
  || bad 'the result is real-parseable YAML (multi-line scalar continuation)' "$(cat "$R/.agents/run-state.yaml")"
yaml_cursor_is 'the PARSED cursor value is unchanged at alpha-t2 (multi-line scalar continuation)' \
  "$R/.agents/run-state.yaml" alpha-t2
[ "$rc" = 0 ] && ok 'apply+verify converge to exit 0 (multi-line scalar continuation)' \
  || bad 'apply+verify exit 0 (multi-line scalar continuation)' "rc=$rc"

printf '\n== detect/apply/verify: the INLINE FLOW form "done: [a, b]" is UNRECOGNIZED (round 4) ==\n'
R="$TMP/done-inlineflow"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done: [alpha-t1, alpha-t2]
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "inline flow done:" >/dev/null 2>&1
cp "$R/.agents/run-state.yaml" "$TMP/rsf-inlineflow.before"

out="$("$MIG" detect "$R" 2>&1)"
has 'detect reports the inline flow form as unrecognized' 'FINDING=backlog-done-unrecognized' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
hasnt 'apply never drops the inline flow form' 'DROPPED=' "$out"
cmp -s "$TMP/rsf-inlineflow.before" "$R/.agents/run-state.yaml" \
  && ok 'run-state.yaml is BYTE-IDENTICAL after apply (inline flow form)' \
  || bad 'run-state.yaml byte-identical (inline flow form)' \
       "$(diff "$TMP/rsf-inlineflow.before" "$R/.agents/run-state.yaml")"
[ "$rc" = 3 ] && ok 'apply exits 3 for the inline flow form' || bad 'apply exit 3 (inline flow)' "rc=$rc"

printf '\n== detect/apply/verify: a HYPHENATED top-level key carrying an unrelated done: (round 4, Defect 3/4) ==\n'
R="$TMP/done-hyphenkey"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  pending:
    - alpha-t2
my-checklist:
  done:
    - something
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "hyphenated top-level key with unrelated done:" >/dev/null 2>&1
cp "$R/.agents/run-state.yaml" "$TMP/rsf-hyphenkey.before"

out="$("$MIG" detect "$R" 2>&1)"
hasnt 'detect does not flag it as backlog-done' 'FINDING=backlog-done' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
hasnt 'apply never drops it' 'DROPPED=' "$out"
hasnt 'apply never even reports it as unrecognized (it is not backlog.done at all)' \
  'UNRECOGNIZED_BACKLOG_DONE=' "$out"
cmp -s "$TMP/rsf-hyphenkey.before" "$R/.agents/run-state.yaml" \
  && ok 'run-state.yaml is BYTE-IDENTICAL after apply (hyphenated unrelated key)' \
  || bad 'run-state.yaml byte-identical (hyphenated unrelated key)' \
       "$(diff "$TMP/rsf-hyphenkey.before" "$R/.agents/run-state.yaml")"
has 'verify reports the clean state' 'no legacy backlog.done block' "$out"
[ "$rc" = 0 ] && ok 'apply+verify converge to exit 0 -- the hyphenated unrelated key never blocks it' \
  || bad 'apply+verify exit 0 (hyphenated unrelated key)' "rc=$rc"

printf '\n== detect/apply: a CRLF run-state.yaml must still surface the UNCHECKED= warning (round 4, Defect 5) ==\n'
R="$TMP/done-crlf"; mk_repo "$R" canonical
printf 'schema: 3\r\nstatus: paused\r\nbacklog:\r\n  cursor: alpha-t2\r\n  done:\r\n    - alpha-t1\r\n    - alpha-t2\r\n  pending:\r\n    - alpha-t2\r\n' > "$R/.agents/run-state.yaml"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "CRLF run-state" >/dev/null 2>&1

out="$("$MIG" detect "$R" 2>&1)"
has 'detect finds the CRLF backlog.done block' 'FINDING=backlog-done' "$out"
has 'AND still reports the still-unchecked id despite the \r (Defect 5)' 'UNCHECKED=alpha-t2' "$out"

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
has 'apply reports the unchecked id BEFORE dropping, CRLF included' 'UNCHECKED=alpha-t2' "$out"
has 'apply drops the CRLF block' 'DROPPED=' "$out"
[ "$rc" = 0 ] && ok 'apply+verify converge to exit 0 on a CRLF run-state' \
  || bad 'apply+verify exit 0 (CRLF)' "rc=$rc"

printf '\n== apply: a trailing COMMENT BANNER after the done: block must survive (round 4, Defect 6) ==\n'
R="$TMP/done-trailcomment"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
    - alpha-t1
    - alpha-t2
  # note: everything above is derived from the gspec checkbox now, ignore
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "done: block with a trailing comment banner after it" >/dev/null 2>&1

out="$("$MIG" apply "$R" 2>&1)"; rc=$?
grep -q '^[[:space:]]*done:[[:space:]]*$' "$R/.agents/run-state.yaml" \
  && bad 'apply drops the block' "still present: $(cat "$R/.agents/run-state.yaml")" \
  || ok 'apply drops the block'
rs="$(cat "$R/.agents/run-state.yaml")"
has 'the trailing comment banner AFTER the block SURVIVES (Defect 6)' \
  'note: everything above is derived from the gspec checkbox now, ignore' "$rs"
has 'cursor survives untouched'  'cursor: alpha-t2' "$rs"
has 'pending survives untouched' 'pending:' "$rs"
yamlok "$R/.agents/run-state.yaml" \
  && ok 'the result is REAL-parseable YAML (trailing comment banner)' \
  || bad 'the result is real-parseable YAML (trailing comment banner)' "$rs"
yaml_cursor_is 'the PARSED cursor value is exactly alpha-t2 (trailing comment banner)' \
  "$R/.agents/run-state.yaml" alpha-t2
[ "$rc" = 0 ] && ok 'apply+verify converge to exit 0' || bad 'apply+verify exit 0 (trailing comment banner)' "rc=$rc"

printf '\n== detect: an EMPTY done: key reads differently from "0 ids parsed" (round 4, Defect 7) ==\n'
R="$TMP/done-emptykey"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "bare empty done:" >/dev/null 2>&1
out="$("$MIG" detect "$R" 2>&1)"
has 'detect describes a truly bare done: key as empty' 'empty' "$out"

R="$TMP/done-emptybody"; mk_repo "$R" canonical
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  done:
    # nothing landed yet
  pending:
    - alpha-t2
EOF
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "done: with only a comment inside" >/dev/null 2>&1
out="$("$MIG" detect "$R" 2>&1)"
has 'detect distinguishes a comment-only body from a bare empty key' '0 id' "$out"

printf '\n== findings-audit: read-only, per-entry live/dead/unknown, no body opened (T18) ==\n'
R="$TMP/findingsaudit"; mk_repo "$R" canonical
mkdir -p "$R/.agents/findings"
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  pending:
    - alpha-t2
findings:
  - id: f-dead
    summary: 'a finished task fully covers this, safe to triage'
    file: .agents/findings/f-dead.md
    packets: [alpha-t1]
  - id: f-live
    summary: 'the packet naming this is still open, keep it'
    file: .agents/findings/f-live.md
    packets: [alpha-t2]
  - id: f-unknown
    summary: 'names a packet gspec has never heard of'
    packets: [nowhere-t1]
  - id: f-nopackets
    summary: 'no packets field at all'
EOF
printf 'body for f-dead\n' > "$R/.agents/findings/f-dead.md"
printf 'a somewhat longer body for f-live, several bytes\n' > "$R/.agents/findings/f-live.md"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "add findings" >/dev/null 2>&1

out="$("$MIG" detect "$R" 2>&1)"
has 'detect reports the findings situation' 'FINDING=findings' "$out"

out="$("$MIG" findings-audit "$R" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok 'findings-audit exits 0' || bad 'findings-audit exit 0' "rc=$rc"
has 'a finished-packet entry reads dead'       'ENTRY=f-dead PACKETS=yes VERDICT=dead' "$out"
has 'a still-open-packet entry reads live'     'ENTRY=f-live PACKETS=yes VERDICT=live' "$out"
has 'an unrecognized packet reads unknown'     'ENTRY=f-unknown PACKETS=yes VERDICT=unknown' "$out"
has 'no packets: at all reads unknown too'     'ENTRY=f-nopackets PACKETS=no VERDICT=unknown' "$out"
has 'per-entry summary bytes are reported'     'SUMMARY_BYTES=' "$out"
has 'per-entry body bytes are reported'        'BODY_BYTES=' "$out"
has 'the f-dead body size is a real byte count (not opened, just measured)' \
  "$(printf 'BODY=yes BODY_BYTES=%s' "$(wc -c < "$R/.agents/findings/f-dead.md" | tr -d ' ')")" "$out"
has 'an entry with no body file on disk says so'  'BODY=no BODY_BYTES=0' "$out"
has 'index total is reported'                     'INDEX_BYTES=' "$out"
has 'body total is reported'                       'BODY_BYTES_TOTAL=' "$out"
has 'entry count is reported'                      'ENTRIES=4' "$out"

printf '\n== apply: findings-audit is read-only -- apply deletes NO finding, ever (T18) ==\n'
"$MIG" apply "$R" --force >/dev/null 2>&1
has 'every finding index entry survives apply' 'id: f-dead' "$(cat "$R/.agents/run-state.yaml")"
has 'even the dead one'                         'id: f-live' "$(cat "$R/.agents/run-state.yaml")"
has 'and the unknown one'                       'id: f-unknown' "$(cat "$R/.agents/run-state.yaml")"
has 'and the packet-less one'                   'id: f-nopackets' "$(cat "$R/.agents/run-state.yaml")"
[ -f "$R/.agents/findings/f-dead.md" ] && ok 'the f-dead BODY file still exists on disk' \
  || bad 'apply deleted a finding body' 'f-dead.md is gone'
[ -f "$R/.agents/findings/f-live.md" ] && ok 'the f-live BODY file still exists on disk' \
  || bad 'apply deleted a finding body' 'f-live.md is gone'

printf '\n== findings-audit: the trailer scan is ANCHORED, not a substring match ==\n'
# A bare substring --grep also fires on prose that merely MENTIONS the trailer
# format -- the same bug scripts/metrics.sh already fixed once (see its comment
# above the trailer scan). Both packet ids below are unresolvable via gspec (no
# such task exists), so _packet_finished_state falls through to _trailer_landed
# for each.
R="$TMP/traileranchor"; mk_repo "$R" canonical
mkdir -p "$R/.agents/findings"
cat > "$R/.agents/run-state.yaml" <<'EOF'
schema: 3
status: paused
backlog:
  cursor: alpha-t2
  pending:
    - alpha-t2
findings:
  - id: f-prose
    summary: 'names a packet only ever MENTIONED in commit prose'
    file: .agents/findings/f-prose.md
    packets: [zzz-prose-only]
  - id: f-real
    summary: 'names a packet with a real trailer commit'
    file: .agents/findings/f-real.md
    packets: [zzz-real-trailer]
EOF
printf 'body\n' > "$R/.agents/findings/f-prose.md"
printf 'body\n' > "$R/.agents/findings/f-real.md"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@e -c user.name=t commit -qm "add findings" >/dev/null 2>&1
# A commit that only MENTIONS the trailer format, inline in a sentence -- must
# NOT count as zzz-prose-only having landed.
git -C "$R" -c user.email=t@e -c user.name=t commit --allow-empty -qm \
  "docs: explain that a commit carries [orch packet:zzz-prose-only] as a trailer" >/dev/null 2>&1
# A commit that actually CARRIES the trailer, on its own line -- the real thing
# the anchored regex must still catch.
git -C "$R" -c user.email=t@e -c user.name=t commit --allow-empty -qm \
  "$(printf 'fix: land the real packet\n\n[orch packet:zzz-real-trailer]\n')" >/dev/null 2>&1

out="$("$MIG" findings-audit "$R" 2>&1)"
has   'a packet only ever mentioned in commit prose reads unknown' \
  'ENTRY=f-prose PACKETS=yes VERDICT=unknown' "$out"
hasnt 'and never reads dead from prose alone (a substring match would say dead)' \
  'ENTRY=f-prose PACKETS=yes VERDICT=dead' "$out"
has   'a packet with a REAL trailer commit still reads dead (the anchor still matches the real thing)' \
  'ENTRY=f-real PACKETS=yes VERDICT=dead' "$out"

printf '\n----------------------------------------\n'
if [ "$YAML_SKIP_COUNT" -gt 0 ]; then
  printf 'migrate: %d passed, %d failed   (no python3+PyYAML on this host — %d parse assertion(s) could not assert; not asserting vacuously)\n' \
    "$PASS" "$FAIL" "$YAML_SKIP_COUNT"
else
  printf 'migrate: %d passed, %d failed\n' "$PASS" "$FAIL"
fi
[ "$FAIL" -eq 0 ] || exit 1
