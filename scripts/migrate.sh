#!/usr/bin/env bash
# =============================================================================
# migrate.sh — retrofit a consumer repo to the current plugin layout (v2.0.0)
# =============================================================================
# The deterministic half of `/gaffer:migrate`. It DETECTS what shape a
# repo is in, PLANS the moves, APPLIES the mechanical ones, and VERIFIES the
# result through the adapter. Judgment — reconciling a hand-written roadmap's
# prose, deciding whether to regenerate a legacy plan — lives in the skill.
#
# WHY VERIFY IS NOT OPTIONAL. The v2.0.0 move renames
# `gspec/features/<slug>.plan.md` to `gspec/tasks/<slug>.md`. Renaming is easy
# and the result LOOKS right — but a plan whose task lines the adapter cannot
# parse yields an EMPTY backlog, which reads as "nothing to do" rather than as
# "unreadable". Both production repos this was built against hit exactly that
# (0 packets from a pure rename) before the adapter learned their legacy task
# shapes. So `apply` always ends by counting real packets, and says so.
#
# Subcommands:
#   detect  [root]   what version/shape is this repo in? Prints FROM=<state> plus
#                    one FINDING= line per thing that needs doing. Read-only.
#   plan    [root]   the ordered move list, as human-readable steps. Read-only.
#   apply   [root]   perform the MECHANICAL moves (git mv where the repo is a git
#                    repo, else mv), then verify. Refuses on a dirty tree unless
#                    --force: a migration you cannot `git diff` is not reviewable.
#   verify  [root]   post-migration checks: paths, adapter parse, packet counts.
#
# WHAT IT WILL NOT DO (the skill's job, with a human):
#   - convert legacy task lines to canonical form. That edits CHECKED tasks,
#     which gspec's task-immutability floor blocks and which destroys the record
#     of what was built. Regeneration via /gspec-plan is the supported path.
#   - translate a roadmap's prose (`## Notes`, `## Unsequenced`) — only the
#     structured `features:` entries convert; prose is reported for a human.
#   - delete anything. Superseded files are left in place and reported.
#
# Exit codes: 0 = ok / nothing to do; 1 = usage; 2 = migration needed (detect);
#             3 = applied but verification found a problem.
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$HERE/gspec-backlog.sh"

die() { printf 'migrate.sh: %s\n' "$1" >&2; exit "${2:-1}"; }
_root() { printf '%s' "${1:-.}"; }

# --- detection ---------------------------------------------------------------

# Each finding is `FINDING=<id>\t<what>\t<why it matters>`.
_findings() {
  local root="$1" n=0

  # 1. Plans still beside the PRD (pre-2.0 / gspec v1 location).
  local plans; plans="$(ls "$root"/gspec/features/*.plan.md 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$plans" != "0" ]; then
    printf 'FINDING=plans\t%s plan file(s) at gspec/features/*.plan.md\tgspec 2.x writes gspec/tasks/<slug>.md; the loop reads that path\n' "$plans"
    n=$((n+1))
  fi

  # 2. Roadmap inside gspec/ (trips gspec's own spec-integrity floor).
  if [ -f "$root/gspec/roadmap.md" ]; then
    printf 'FINDING=roadmap\tgspec/roadmap.md exists\tit is plugin-owned, and every .md under gspec/ is governed by gspec spec-integrity (flags on write; blocks every turn on Codex)\n'
    n=$((n+1))
  fi

  # 3. project-overrides pointing at the old paths.
  if [ -f "$root/.agents/project-overrides.yaml" ] \
     && grep -q 'gspec/roadmap\.md\|features/\*\*\.plan\.md' "$root/.agents/project-overrides.yaml" 2>/dev/null; then
    printf 'FINDING=overrides\t.agents/project-overrides.yaml references old spec paths\tallowed_paths must cover gspec/tasks/** and .agents/roadmap.yaml\n'
    n=$((n+1))
  fi

  # 4. Consumer CLAUDE.md narrating the old layout.
  if [ -f "$root/CLAUDE.md" ] && grep -q 'gspec/roadmap\.md\|\.plan\.md' "$root/CLAUDE.md" 2>/dev/null; then
    printf 'FINDING=claudemd\tCLAUDE.md describes the old backlog layout\tit is the operating brief agents read every session; stale paths there outlive the file move\n'
    n=$((n+1))
  fi

  # 5. Legacy task-line shapes — the one that silently empties a backlog.
  local legacy=0 f
  for f in "$root"/gspec/features/*.plan.md "$root"/gspec/tasks/*.md; do
    [ -f "$f" ] || continue
    grep -qE '^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*T[0-9]+\*\*' "$f" && continue
    grep -qE '^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*[A-Za-z]' "$f" && legacy=$((legacy+1))
  done
  if [ "$legacy" != "0" ]; then
    printf 'FINDING=legacy-tasks\t%s plan file(s) use a pre-2.0 task-line shape\tthe adapter reads them, but ids/deps/covers are non-canonical; regenerate with /gspec-plan when convenient\n' "$legacy"
    n=$((n+1))
  fi

  # 6. Missing pause sentinel ignores (ADR 0017).
  if [ -f "$root/.gitignore" ] && ! grep -q 'agents/pause' "$root/.gitignore" 2>/dev/null; then
    printf 'FINDING=gitignore\t.gitignore does not ignore .agents/pause\ta pause request would dirty the tree and could be committed\n'
    n=$((n+1))
  fi

  # 7. Spec-version drift against the pinned gspec.
  if [ -d "$root/gspec" ] && ! "$ADAPTER" check "$root" >/dev/null 2>&1; then
    printf 'FINDING=spec-version\tgspec specs fail the version pin\trun `gspec-backlog.sh check` for the offenders; /gspec-migrate or a plugin pin bump resolves it\n'
    n=$((n+1))
  fi

  printf 'FINDINGS=%s\n' "$n"
}

cmd_detect() {
  local root; root="$(_root "${1:-}")"
  [ -d "$root" ] || die "no such directory: $root"
  local state='current'
  [ -f "$root/gspec/roadmap.md" ] && state='pre-2.0'
  ls "$root"/gspec/features/*.plan.md >/dev/null 2>&1 && state='pre-2.0'
  [ -d "$root/gspec" ] || state='no-gspec'
  printf 'ROOT=%s\nFROM=%s\n' "$root" "$state"
  local out; out="$(_findings "$root")"
  printf '%s\n' "$out"
  local n; n="$(printf '%s\n' "$out" | sed -n 's/^FINDINGS=//p')"
  [ "${n:-0}" = "0" ] || return 2
}

cmd_plan() {
  local root; root="$(_root "${1:-}")"
  printf 'Migration plan for %s\n\n' "$root"
  local i=1
  while IFS=$'\t' read -r id what why; do
    case "$id" in FINDING=*) ;; *) continue ;; esac
    printf '%d. [%s] %s\n     why: %s\n' "$i" "${id#FINDING=}" "$what" "$why"
    i=$((i+1))
  done < <(_findings "$root")
  [ "$i" -gt 1 ] || printf '  Nothing to do — this repo is already on the current layout.\n'
}

# --- apply -------------------------------------------------------------------

_is_git() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
_mv() { # history-preserving where possible
  local root="$1" from="$2" to="$3"
  if _is_git "$root"; then git -C "$root" mv "$from" "$to" 2>/dev/null && return 0; fi
  mv "$root/$from" "$root/$to"
}

# A migrated plan needs gspec frontmatter: the version pin asserts `spec-version`,
# and `feature:` ties the plan to its PRD. Architect-authored pre-2.0 plans have
# neither (they open straight into `# Plan - <Name>`). PREPENDING frontmatter is
# safe in a way that rewriting task lines is not: it cannot touch a checked task,
# so the historical record and gspec's immutability floor are both untouched.
_ensure_frontmatter() {
  local file="$1" slug="$2" ver="$3"
  head -1 "$file" | grep -qE '^-{3}[[:space:]]*$' && return 1   # already has some
  local tmp; tmp="$(mktemp)"
  { printf -- '---\nspec-version: %s\nfeature: %s\n---\n\n' "$ver" "$slug"; cat "$file"; } > "$tmp"
  mv "$tmp" "$file"
  return 0
}

# gspec/roadmap.md -> .agents/roadmap.yaml, keeping ONLY the four fields the new
# schema has. `status` and `parallel_group` are dropped on purpose: completion is
# derived from PRD checkboxes and concurrency is computed per run, so storing
# either is a drift source (ADR 0020 D2). Prose sections are NOT translated.
_convert_roadmap() {
  local src="$1" dest="$2"
  {
    printf '# Feature sequencing (plugin ADR 0020 D2) — migrated from gspec/roadmap.md\n'
    printf '#\n'
    printf '# Converted automatically: slug/order/why/depends_on are carried over.\n'
    printf '# `status` and `parallel_group` were DROPPED on purpose — completion is derived\n'
    printf '# from each PRD s capability checkboxes, and concurrency is computed per run by\n'
    printf '# packet-graph.sh. Storing either is how they drift.\n'
    printf '#\n'
    printf '# REVIEW THIS FILE: any prose in the old roadmap (## Notes, ## Unsequenced,\n'
    printf '# rationale in comments) was NOT translated. It is still in the original file.\n'
    printf 'schema: 1\n'
    printf 'features:\n'
    awk '
      function flush() {
        if (slug == "") return
        printf "  - slug: %s\n", slug
        if (order != "") printf "    order: %s\n", order
        printf "    why: %s\n", (why != "" ? why : "\"(carry the rationale over from the old roadmap)\"")
        printf "    depends_on: %s\n", (deps != "" ? deps : "[]")
        slug=""; order=""; why=""; deps=""
      }
      function val(l){ sub(/^[^:]*:[[:space:]]*/,"",l); sub(/[[:space:]]+$/,"",l); return l }
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*-[[:space:]]+slug[[:space:]]*:/ { flush(); l=$0; sub(/^[[:space:]]*-[[:space:]]+/,"",l); slug=val(l); next }
      /^[[:space:]]+order[[:space:]]*:/       { order=val($0); next }
      /^[[:space:]]+why[[:space:]]*:/         { why=val($0);   next }
      /^[[:space:]]+depends_on[[:space:]]*:/  { deps=val($0);  next }
      END { flush() }
    ' "$src"
  } > "$dest"
}

cmd_apply() {
  local root force=0 a
  root="$(_root "${1:-}")"
  for a in "$@"; do [ "$a" = "--force" ] && force=1; done
  [ -d "$root" ] || die "no such directory: $root"

  # A migration you cannot `git diff` is not a migration you can review.
  if _is_git "$root" && [ "$force" -eq 0 ] && [ -n "$(git -C "$root" status --porcelain)" ]; then
    die "working tree is dirty — commit or stash first so the migration is reviewable as one diff (or pass --force)" 1
  fi

  local did=0

  # 1. plan files -> gspec/tasks/
  if ls "$root"/gspec/features/*.plan.md >/dev/null 2>&1; then
    mkdir -p "$root/gspec/tasks"
    local f base slug
    for f in "$root"/gspec/features/*.plan.md; do
      base="$(basename "$f")"; slug="${base%.plan.md}"
      if [ -e "$root/gspec/tasks/$slug.md" ]; then
        printf 'SKIP=gspec/tasks/%s.md already exists — left gspec/features/%s in place for you to reconcile\n' "$slug" "$base"
        continue
      fi
      _mv "$root" "gspec/features/$base" "gspec/tasks/$slug.md"
      printf 'MOVED=gspec/features/%s -> gspec/tasks/%s.md\n' "$base" "$slug"
      did=1
    done
  fi

  # 1b. give migrated plans the frontmatter the version pin requires
  if ls "$root"/gspec/tasks/*.md >/dev/null 2>&1; then
    local ver stamped=0 g base slug
    ver="$("$ADAPTER" pin | sed -n 's/^GSPEC_SPEC_VERSIONS=//p' | awk '{print $1}')"
    for g in "$root"/gspec/tasks/*.md; do
      base="$(basename "$g")"; slug="${base%.md}"
      if _ensure_frontmatter "$g" "$slug" "${ver:-v1}"; then
        stamped=$((stamped+1))
      fi
    done
    if [ "$stamped" != "0" ]; then
      printf 'STAMPED=%s plan file(s) given spec-version %s + feature frontmatter\n' "$stamped" "${ver:-v1}"
      did=1
    fi
  fi

  # 2. roadmap -> .agents/roadmap.yaml
  if [ -f "$root/gspec/roadmap.md" ]; then
    mkdir -p "$root/.agents"
    if [ -e "$root/.agents/roadmap.yaml" ]; then
      printf 'SKIP=.agents/roadmap.yaml already exists — gspec/roadmap.md left in place\n'
    else
      _convert_roadmap "$root/gspec/roadmap.md" "$root/.agents/roadmap.yaml"
      printf 'CONVERTED=gspec/roadmap.md -> .agents/roadmap.yaml (%s feature entries)\n' \
        "$(grep -c '^  - slug:' "$root/.agents/roadmap.yaml" || printf 0)"
      printf 'KEPT=gspec/roadmap.md left in place — it still holds prose the converter does not translate. Delete it yourself once reviewed.\n'
      did=1
    fi
  fi

  [ "$did" = "1" ] || printf 'NOCHANGE=nothing mechanical left to move\n'
  printf '\n'
  cmd_verify "$root"
}

# --- verify ------------------------------------------------------------------

cmd_verify() {
  local root; root="$(_root "${1:-}")"
  local problems=0

  printf 'VERIFY %s\n' "$root"
  if ls "$root"/gspec/features/*.plan.md >/dev/null 2>&1; then
    printf '  ✗ plan files still at gspec/features/*.plan.md\n'; problems=$((problems+1))
  else
    printf '  ✓ no plan files left beside the PRDs\n'
  fi
  if [ -f "$root/gspec/roadmap.md" ] && [ ! -f "$root/.agents/roadmap.yaml" ]; then
    printf '  ✗ gspec/roadmap.md present with no .agents/roadmap.yaml\n'; problems=$((problems+1))
  fi

  if [ -d "$root/gspec" ]; then
    if "$ADAPTER" check "$root" >/dev/null 2>&1; then
      printf '  ✓ specs pass the gspec version pin\n'
    else
      printf '  ✗ specs fail the version pin (run: gspec-backlog.sh check)\n'; problems=$((problems+1))
    fi

    # THE check that matters: does the backlog actually parse to packets?
    local plans packets
    plans="$(ls "$root"/gspec/tasks/*.md 2>/dev/null | wc -l | tr -d ' ')"
    packets="$("$ADAPTER" nodes-all "$root" 2>/dev/null | grep -c . || true)"; packets="${packets:-0}"
    printf '  · %s plan file(s) -> %s unchecked packet(s)\n' "$plans" "$packets"
    if [ "$plans" != "0" ] && [ "$packets" = "0" ]; then
      printf '  ✗ plans exist but produce ZERO packets — the backlog would read as "nothing to do".\n'
      printf '    This is the failure the migration exists to catch. Inspect a plan file: its task\n'
      printf '    lines are in a shape the adapter cannot read, and it needs /gspec-plan.\n'
      problems=$((problems+1))
    fi
    local nx; nx="$("$ADAPTER" next "$root" 2>/dev/null | sed -n 's/^NEXT=//p')"
    printf '  · next feature: %s\n' "${nx:-none}"
  fi

  if [ "$problems" = "0" ]; then printf 'VERIFY=ok\n'; return 0; fi
  printf 'VERIFY=problems (%s)\n' "$problems"; return 3
}

case "${1:-}" in
  detect) shift; cmd_detect "$@" ;;
  plan)   shift; cmd_plan   "$@" ;;
  apply)  shift; cmd_apply  "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) die "usage: migrate.sh {detect|plan|apply [--force]|verify} [root]" ;;
esac
