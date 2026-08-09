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
[ "$rc" = 2 ] && ok 'detect exits 2 when migration is needed' || bad 'detect exit 2' "rc=$rc"

printf '\n== detect: a current repo is left alone ==\n'
R="$TMP/current"; mkdir -p "$R/gspec/tasks" "$R/gspec/features" "$R/.agents"
printf -- '---\nspec-version: v1\n---\n- [ ] **P0**: x\n' > "$R/gspec/features/a.md"
printf -- '---\nspec-version: v1\nfeature: a\n---\n- [ ] **T1** **P0** do it\n' > "$R/gspec/tasks/a.md"
printf 'schema: 1\nfeatures: []\n' > "$R/.agents/roadmap.yaml"
printf '.agents/pause\n' > "$R/.gitignore"
out="$("$MIG" detect "$R" 2>&1)"; rc=$?
has 'a current repo reports no findings' 'FINDINGS=0' "$out"
[ "$rc" = 0 ] && ok 'detect exits 0 when nothing to do' || bad 'detect exit 0' "rc=$rc"
out="$("$MIG" plan "$R" 2>&1)"
has 'plan says there is nothing to do' 'Nothing to do' "$out"

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
has 'spec-version is stamped'    'spec-version: v1' "$(head -3 "$R/gspec/tasks/alpha.md")"
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

printf '\n----------------------------------------\n'
printf 'migrate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
