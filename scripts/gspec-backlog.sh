#!/usr/bin/env bash
# =============================================================================
# gspec-backlog.sh — THE gspec adapter (ADR 0020 D2)
# =============================================================================
# The ONE place this plugin reads gspec. Every other component (run-loop §2,
# resume, build-packet-dependency-tree, new-project) goes through here, so a
# gspec format change is one file to fix rather than seven skills and two agents.
# That is the whole point: the 2026-08 breakage was not caused by gspec moving
# `features/<slug>.plan.md` to `tasks/<slug>.md` — it was caused by nothing
# checking, in seven places at once.
#
# THE CONSUMED CONTRACT (ADR 0020 D2) — nothing outside this list is read:
#   <plan>                     the execution backlog. Frontmatter `spec-version`
#                              + `feature`; task lines
#                              `- [ ] **T<n>** [P] **P<n>** <text>` with indented
#                              `- deps:` / `- covers:` / `- supersedes:` / `- arch:`
#                              and an OPTIONAL `- files:` (forward-compat with
#                              upstream proposal U1 — gspec does not emit it today).
#                              WRITTEN as well as read (ADR 0025 D1): `check-task`
#                              flips ONE task line's `[ ]` to `[x]` and nothing
#                              else — never the text, never any other line. This
#                              is the adapter's one write; it records that a unit
#                              of work executed, not what to build (ADR 0020 D2).
#   <prd>                      the PRD. Capability lines
#                              `- [ ] **P<n>**: <text>`; completion is DERIVED
#                              from them (ADR 0020 D2 — never stored). Optional
#                              frontmatter `depends_on:` (forward-compat with U5).
#
# ...where <plan> and <prd> are LAYOUT-DEPENDENT and resolved in exactly one
# place each — `_resolve_plan_path` / `_resolve_prd_path`, enumerated by
# `_plan_paths` / `_prd_paths`. See LAYOUTS below.
#   .agents/roadmap.yaml       PLUGIN-OWNED sequencing (order/why, interim
#                              depends_on, and `deferred` — a human "not now",
#                              which is NOT the derived `status` D2 prohibits;
#                              see _roadmap_rows). An OVERRIDE, never a prerequisite.
#   .agents/task-files.yaml    PLUGIN-OWNED file scope per task (ADR 0020 U1-local).
#                              gspec task lines carry no file scope, so this is
#                              where `allowed_files` comes from until (or unless)
#                              upstream U1-up lands. FINGERPRINT-GUARDED — see below.
#   .gspec/build/status.json   read ONLY by `interlock`, and FAIL-SOFT: it sits
#                              outside the pinned contract, so an unreadable or
#                              unknown-shaped file must never block the loop.
#
# VERSION PIN (ADR 0020 D3). gspec does not stamp its package version into a
# project (`.gspec/config.json` holds only the install target + models map), so
# the pin has two axes: the TOOL pin below (what new-project installs) and the
# ARTIFACT pin (`spec-version` in the specs), asserted by `check`. The artifact
# pin is the one that actually protects the loop.
#
# Subcommands:
#   pin                      print the pinned gspec version + supported spec-versions.
#   check [root]             assert the artifact pin across gspec specs. Prints
#                            CHECK=ok, or CHECK=fail + one FAIL= line per offender.
#                            Exit 3 on a version mismatch; 0 when clean or when no
#                            gspec project is present (gspec is OPTIONAL — D4).
#   features [root]          TSV, one feature per line, order asc then slug asc:
#                              <slug>\t<order>\t<done>\t<blocked>\t<depends_on>\t<why>\t<deferred>
#                            done/blocked/deferred are 1/0. depends_on is
#                            '|'-separated. `deferred` is LAST so every existing
#                            column index keeps its meaning.
#   next [root]              print NEXT=<slug> (lowest order among
#                            unblocked-and-incomplete-and-not-deferred) or
#                            NEXT=none, plus REASON= distinguishing blocked from
#                            deferred from complete.
#   nodes <slug> [root]      emit packet-graph NODES TSV for one feature's UNCHECKED
#                            tasks (feed to `packet-graph.sh build`).
#   nodes-all [root]         the same for every incomplete, unblocked feature.
#   interlock [root]         INTERLOCK=clear|busy|unknown — is a `gspec build`
#                            driving this repo right now? (ADR 0020 D5.)
#   files-status [root]      audit `.agents/task-files.yaml` against the live plans:
#                            one `<state> <task>` line per entry
#                            (ok|stale|unfingerprinted|done|orphan) + a summary.
#   check-task <task> [root] the adapter's ONE write (ADR 0025 D1): flip a single
#                            task's checkbox from `[ ]` to `[x]` in
#                            gspec/tasks/<slug>.md, and touch nothing else — not
#                            the task text, not any other line. `<task>` accepts
#                            either `<feature>#T<n>` or the packet-id form
#                            `<feature>-t<n>` the loop actually holds at packet
#                            close. Idempotent (CHECKED=already); every "gspec is
#                            optional" case exits 0; a task id absent from an
#                            EXISTING plan is genuine drift and exits 4.
#   task-status <id[,id...]> [root]   READ-ONLY (run-state-cleanup T2): for each
#                            packet id, one `<id>\t<state>\t<task-ref-or-reason>`
#                            line, state one of finished|unchecked|unknown, then
#                            one trailing `FINISHED=<comma-sep ids>` line fed
#                            VERBATIM to `runstate.sh findings --stale --finished`.
#                            Accepts the same two id forms as check-task and
#                            resolves them via the SAME shared function
#                            (`_resolve_task_id`) so the two can never drift.
#                            Every "gspec is optional" case reads `unknown`,
#                            mirroring check-task's `CHECKED=none`; exit 0 for all
#                            of them, non-zero only for a genuine usage error (no
#                            ids, or an unreadable root).
#
# FILE SCOPE, AND WHY IT IS FINGERPRINT-GUARDED (ADR 0020 U1-local). `allowed_files`
# is the field that decides which packets may run CONCURRENTLY, so a wrong value
# here is the one input that can cost correctness rather than speed. Precedence:
#   1. a plan-authored `files:` sub-bullet (the upstream U1-up shape) — always wins;
#   2. a `.agents/task-files.yaml` entry whose FINGERPRINT still matches the task's
#      current text;
#   3. empty — packet-graph.sh then treats the packet as overlapping everything and
#      serializes it.
# The fingerprint is REQUIRED for an entry to be used, and that is the whole point:
# gspec's `plan-decomposer` preserves task IDs on regenerate but RE-DECOMPOSES
# unchecked work, so an unchecked `T5` can keep its id while its text becomes
# different work. An unguarded sidecar would then hand a stale, NARROW scope to two
# lanes that actually collide. A missing or mismatched fingerprint drops the entry
# to empty scope: wrong-wide costs parallelism, wrong-narrow costs correctness.
# Comparison is normalized (case, markdown emphasis, whitespace) so reformatting a
# task does not invalidate its entry.
#
# HOW TASK DEPS BECOME GRAPH EDGES. packet-graph.sh derives ordering from
# consumes/produces signature matching, so an intra-feature `deps: T1` is encoded
# as produces `<feature>#T<n>` / consumes `<feature>#T<d>`. A dep on an ALREADY
# CHECKED task simply finds no producer (checked tasks are not nodes) and yields
# no edge — which is correct: done work must not block anything.
#
# LAYOUTS (ADR 0020 D3, gspec 3.x). gspec 3.0 moved everything about a feature
# into ONE folder, and the adapter reads all three shapes it has ever shipped:
#
#   layout        PRD                            plan
#   ------------  -----------------------------  -----------------------------
#   3.x (v2)      gspec/features/<slug>/prd.md   gspec/features/<slug>/tasks.md
#   2.x (v1)      gspec/features/<slug>.md       gspec/tasks/<slug>.md
#   pre-2.0       gspec/features/<slug>.md       gspec/features/<slug>.plan.md
#
# Reading all three is not politeness, it is the same lesson as the task-line
# shapes below: a consumer repo migrates on ITS schedule, and an adapter that
# knows only the new path does not report an error on an unmigrated repo — it
# reports an EMPTY BACKLOG, which reads as "nothing to do". gspec's own floor
# module (`plugin/hooks/floors/paths.mjs`) accepts both layouts for exactly this
# reason, and the task-immutability block it feeds fails open, so a matcher that
# knew only the flat form would stop firing with no error anywhere.
#
# The newer layout WINS wherever both exist for one slug: `/gspec-migrate` moves
# rather than copies, so a slug present in both is a half-finished migration, and
# resolving to the destination is what makes re-running it idempotent. A shadowed
# flat file is skipped by the enumerators, never read twice under two names.
#
# The 3.x feature folder also holds `arch.md` and `design.html`. Neither is in
# the consumed contract: they say what to build and how it should look, which is
# gspec's half of the seam — the loop hands their PATHS to an implementer, and
# this adapter never parses them.
#
# LEGACY TASK-LINE SHAPES (migration compatibility — /gaffer:migrate).
# gspec's canonical task line is `- [ ] **T<n>** ...`. Real pre-2.0 consumer repos
# carry plan files this plugin's own architect authored under the ADR 0013
# convention, in two OTHER shapes -- both observed in production repos:
#   A  `- [x] **T000 Some description.**`  id and description share one bold span
#   B  `- [x] **ser-t1** **P0** **[GATE:...]** ...`  feature-prefixed kebab id
# Recognizing them is what makes migration a safe MOVE. Rewriting task lines into
# canonical form would edit CHECKED tasks -- which gspec's task-immutability floor
# blocks, and which destroys the historical record of what was built. Refusing to
# recognize them is worse still: the file moves, parses to nothing, and the backlog
# reads as EMPTY rather than as unreadable -- the exact silent-failure class this
# adapter exists to prevent (measured: both production repos yielded 0 packets).
# Legacy files are reported on stderr; regenerate them with `/gspec-plan`.
#
# WHAT IS DELIBERATELY NOT INFERRED. gspec task lines carry no file scope, so
# `allowed_files` is empty unless an (upstream-proposal-U1) `files:` line is
# present. packet-graph.sh treats empty scope as "overlaps everything" and
# serializes conservatively. That costs parallelism and never costs correctness;
# guessing a narrow scope is how two lanes collide on an unlisted shared file.
#
# Exit codes: 0 = ok; 1 = usage / bad input; 3 = version-pin mismatch;
#             4 = a required gspec artifact is missing.
# =============================================================================

set -euo pipefail

die() { printf 'gspec-backlog.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

# --- The pin (ADR 0020 D3) ---------------------------------------------------
# Raising these is a deliberate, reviewed change: bump, extend, re-run the
# sweeps, amend ADR 0020. Env overrides exist for testing and for a consumer repo
# that has deliberately moved ahead of the plugin.
GSPEC_PINNED_VERSION="${ORCH_GSPEC_PINNED_VERSION:-3.1.1}"
# BOTH artifact versions are supported, and that is the deliberate half of the
# 3.1.1 bump: v2 is what gspec writes now, v1 is what every unmigrated consumer
# repo still has on disk. Narrowing this to `v2` would make `check` fail — rc=3,
# the loop stops — on a repo whose backlog this adapter can read perfectly well.
# The version pin exists to catch a format this code CANNOT parse; it is not a
# lever for nagging a repo into migrating. `/gaffer:migrate` reports the layout
# and names /gspec-migrate; that is where the nudge belongs.
GSPEC_SPEC_VERSIONS="${ORCH_GSPEC_SPEC_VERSIONS:-v1 v2}"

cmd_pin() {
  printf 'GSPEC_PINNED_VERSION=%s\n' "$GSPEC_PINNED_VERSION"
  printf 'GSPEC_SPEC_VERSIONS=%s\n' "$GSPEC_SPEC_VERSIONS"
  printf 'INSTALL=npx gspec@%s --target claude\n' "$GSPEC_PINNED_VERSION"
}

# --- shared helpers ----------------------------------------------------------

# Print a file's YAML frontmatter body (between the first `---` and the next),
# or nothing when the file has none.
_frontmatter() {
  [ -f "$1" ] || return 0
  awk '
    NR==1 && $0 !~ /^-{3}[[:space:]]*$/ { exit }
    NR==1 { infm=1; next }
    infm && /^-{3}[[:space:]]*$/ { exit }
    infm { print }
  ' "$1"
}

# _fm_scalar <file> <key> — a flat scalar from frontmatter ('' when absent).
_fm_scalar() {
  _frontmatter "$1" | awk -v k="$2" '
    $0 ~ "^" k "[[:space:]]*:" {
      sub("^" k "[[:space:]]*:[[:space:]]*", "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      sub(/[[:space:]]+$/, "")
      print; exit
    }'
}

# _fm_list <file> <key> — a frontmatter list as '|'-separated. Accepts the inline
# flow form (`depends_on: [a, b]`) and the block form (`depends_on:\n  - a`).
_fm_list() {
  _frontmatter "$1" | awk -v k="$2" '
    function emit(s){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); gsub(/^["'"'"']|["'"'"']$/,"",s);
                      if (s != "" && s != "-" && s != "—") out = (out=="" ? s : out "|" s) }
    $0 ~ "^" k "[[:space:]]*:" {
      line=$0; sub("^" k "[[:space:]]*:[[:space:]]*","",line)
      if (line ~ /^\[/) { gsub(/^\[|\]$/,"",line); n=split(line,a,","); for(i=1;i<=n;i++) emit(a[i]); done=1 }
      else if (line != "") { emit(line); done=1 }
      else block=1
      next
    }
    block && /^[[:space:]]+-[[:space:]]*/ { l=$0; sub(/^[[:space:]]+-[[:space:]]*/,"",l); emit(l); next }
    block && /^[^[:space:]]/ { block=0 }
    END { print out }
  '
}

# Resolve the repo root argument (default: cwd).
_root() { printf '%s' "${1:-.}"; }

# Is there a gspec project here at all? (D4: gspec is OPTIONAL.)
_has_gspec() { [ -d "$(_root "$1")/gspec" ]; }

# --- the LAYOUT seam (see LAYOUTS in the header) ------------------------------
# Four functions, and every gspec path in this file comes out of one of them. A
# fourth layout must only ever need editing here — which is the same promise
# `_resolve_plan_path` already made and the reason adding gspec 3.x cost a seam
# rather than a sweep through nine call sites.
#
# The two enumerators SHADOW: a slug whose newer-layout file exists suppresses
# its older-layout twin, so a half-finished /gspec-migrate yields one row per
# feature rather than two rows that disagree about how done it is.

# _prd_paths <root> — every feature PRD on disk, one absolute path per line.
_prd_paths() {
  local root="$1" p slug
  for p in "$root"/gspec/features/*/prd.md; do
    [ -f "$p" ] || continue
    printf '%s\n' "$p"
  done
  for p in "$root"/gspec/features/*.md; do
    [ -f "$p" ] || continue
    slug="$(basename "$p" .md)"
    # A plan file beside the PRD is a plan, not a feature (pre-2.0 layout).
    case "$slug" in *.plan) continue ;; esac
    [ -f "$root/gspec/features/$slug/prd.md" ] && continue
    printf '%s\n' "$p"
  done
}

# _plan_paths <root> — every plan file on disk, as "<abs path>\t<slug>".
# The slug is carried rather than re-derived because the folder layout encodes it
# in the DIRECTORY (features/<slug>/tasks.md), so `basename .md` — which every
# caller used to do — yields the literal string "tasks" for all of them.
_plan_paths() {
  local root="$1" p b slug
  for p in "$root"/gspec/features/*/tasks.md; do
    [ -f "$p" ] || continue
    printf '%s\t%s\n' "$p" "$(basename "$(dirname "$p")")"
  done
  for p in "$root"/gspec/tasks/*.md; do
    [ -f "$p" ] || continue
    slug="$(basename "$p" .md)"
    if [ -f "$root/gspec/features/$slug/tasks.md" ]; then continue; fi
    printf '%s\t%s\n' "$p" "$slug"
  done
  for p in "$root"/gspec/features/*.plan.md; do
    [ -f "$p" ] || continue
    b="$(basename "$p")"; slug="${b%.plan.md}"
    if [ -f "$root/gspec/features/$slug/tasks.md" ] || [ -f "$root/gspec/tasks/$slug.md" ]; then continue; fi
    printf '%s\t%s\n' "$p" "$slug"
  done
}

# _resolve_prd_path <slug> <root> — "<prd>\t<relprd>", or nothing when neither
# layout has one. Newest layout first (see LAYOUTS).
_resolve_prd_path() {
  local slug="$1" root="$2"
  if [ -f "$root/gspec/features/$slug/prd.md" ]; then
    printf '%s\t%s\n' "$root/gspec/features/$slug/prd.md" "gspec/features/$slug/prd.md"
  elif [ -f "$root/gspec/features/$slug.md" ]; then
    printf '%s\t%s\n' "$root/gspec/features/$slug.md" "gspec/features/$slug.md"
  fi
}

# --- check: the ARTIFACT pin (ADR 0020 D3) -----------------------------------

cmd_check() {
  local root; root="$(_root "${1:-}")"
  if ! _has_gspec "$root"; then
    printf 'CHECK=ok\nNOTE=no gspec/ directory — gspec is optional (ADR 0020 D4)\n'
    return 0
  fi
  local bad=0 f ver base
  # Only the artifacts we actually consume are asserted. Asserting gspec's whole
  # tree would make us fail on specs we never read - `arch.md`, `design.html` and
  # the foundation specs are gspec's to police, and it has a floor that does.
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    base="${f#"$root"/}"
    ver="$(_fm_scalar "$f" 'spec-version')"
    if [ -z "$ver" ]; then
      printf 'FAIL=%s has no spec-version frontmatter\n' "$base"; bad=1; continue
    fi
    case " $GSPEC_SPEC_VERSIONS " in
      *" $ver "*) ;;
      *) printf 'FAIL=%s has spec-version %s; this plugin supports %s (pinned gspec %s)\n' \
           "$base" "$ver" "$GSPEC_SPEC_VERSIONS" "$GSPEC_PINNED_VERSION"; bad=1 ;;
    esac
  done < <( { _prd_paths "$root"; _plan_paths "$root" | cut -f1; } )
  if [ "$bad" -ne 0 ]; then
    printf 'CHECK=fail\n'
    printf 'HINT=run /gspec-migrate to bring specs current, or raise the pin in scripts/gspec-backlog.sh (ADR 0020 D3)\n'
    return 3
  fi
  printf 'CHECK=ok\nSPEC_VERSIONS=%s\nPINNED_GSPEC=%s\n' "$GSPEC_SPEC_VERSIONS" "$GSPEC_PINNED_VERSION"
}

# --- completion, derived from PRD capability checkboxes (ADR 0020 D2) --------
# A feature is done when its PRD has >=1 capability checkbox and none unchecked.
# Zero checkboxes => NOT done: absence of evidence is not completion.
_feature_done() {
  local prd="$1"
  [ -f "$prd" ] || { printf '0'; return 0; }
  # Canonical `**P0**: text`, and the legacy shape `**P0 — text**` where priority
  # and description share one bold span (observed in production repos). Getting
  # this wrong is not cosmetic: an unrecognized capability line means the feature
  # can NEVER read as done, so every feature depending on it stays blocked forever
  # and the backlog quietly reports nothing to do.
  awk '
    /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*P[0-9]+([^0-9]|\*\*)/ {
      total++
      if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) checked++
    }
    END { print (total > 0 && total == checked) ? "1" : "0" }
  ' "$prd"
}

# --- .agents/roadmap.yaml (plugin-owned, OPTIONAL) ---------------------------
# Constrained shape only (ADR 0020 D2): schema + a `features:` list of flat maps
# with slug/order/why/depends_on/deferred. Not a general YAML parser, by design.
#
# `deferred: true` is NOT the `status` field ADR 0020 D2 prohibits, and the
# distinction is the rule's own reasoning rather than a loophole. That prohibition
# names two fields and says why: completion is DERIVED from the PRD's capability
# checkboxes and concurrency is DERIVED by packet-graph.sh, so storing either is a
# drift source. `deferred` is derived from neither — it is a HUMAN planning
# decision, which is precisely what this file owns. It answers "should the loop
# pick this up yet?", never "is this done?".
#
# It exists because the alternative for deferred-but-recorded work is worse in
# both directions: leave it out of the roadmap and `next` still reaches it (order
# only sequences, it does not gate), or leave the PRD out entirely and the
# deferral has no status at all — which is the tracking gap the backlog exists to
# close. Deferral is recorded, visible in `features`, and skipped by `next`.
_roadmap_rows() {
  local rm="$1"
  [ -f "$rm" ] || return 0
  awk '
    function flush(){ if (slug != "") printf "%s\t%s\t%s\t%s\t%s\n", slug, (order==""?"":order), deps, why, deferred;
                      slug=""; order=""; deps=""; why=""; deferred="" }
    function val(l){ sub(/^[^:]*:[[:space:]]*/,"",l); gsub(/^["'"'"']|["'"'"']$/,"",l);
                     sub(/[[:space:]]+$/,"",l); return l }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]+slug[[:space:]]*:/ { flush(); l=$0; sub(/^[[:space:]]*-[[:space:]]+/,"",l); slug=val(l); next }
    /^[[:space:]]+order[[:space:]]*:/ { order=val($0); next }
    /^[[:space:]]+why[[:space:]]*:/   { why=val($0);   next }
    # Only an explicit, unambiguous true defers. Anything else — false, absent,
    # a typo — reads as NOT deferred, so a malformed entry costs an unwanted
    # pickup the human can see and fix, never silent disappearance from the
    # backlog. Wrong-visible beats wrong-invisible for a gating field.
    /^[[:space:]]+deferred[[:space:]]*:/ {
      l=tolower(val($0))
      deferred = (l == "true" || l == "yes") ? "1" : ""
      next
    }
    /^[[:space:]]+depends_on[[:space:]]*:/ {
      l=val($0)
      if (l ~ /^\[/) { gsub(/^\[|\]$/,"",l); n=split(l,a,","); deps="";
                       for(i=1;i<=n;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",a[i]);
                                          if(a[i]!="") deps=(deps==""?a[i]:deps "|" a[i]) } }
      else deps=""
      next
    }
    END { flush() }
  ' "$rm"
}

# --- .agents/task-files.yaml (plugin-owned file scope, OPTIONAL) -------------
# Same constrained shape as the roadmap: a `tasks:` list of flat maps.
#   tasks:
#     - task: auth#T1
#       files: [db/migrations/**, src/models/user.ts]
#       fingerprint: create the schema migration
# Emits TSV: <task-key>\t<files '|'-sep>\t<fingerprint>
_sidecar_rows() {
  local sc="$1"
  [ -f "$sc" ] || return 0
  awk '
    function flush(){ if (key != "") printf "%s\t%s\t%s\n", key, files, fp; key=""; files=""; fp="" }
    function val(l){ sub(/^[^:]*:[[:space:]]*/,"",l); gsub(/^["'"'"']|["'"'"']$/,"",l);
                     sub(/[[:space:]]+$/,"",l); return l }
    function list(l,   n,a,i,out){
      gsub(/^\[|\]$/,"",l); n=split(l,a,",")
      for(i=1;i<=n;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",a[i]); gsub(/^["'"'"']|["'"'"']$/,"",a[i])
                         if(a[i]!="") out=(out==""?a[i]:out "|" a[i]) }
      return out
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]+task[[:space:]]*:/ { flush(); l=$0; sub(/^[[:space:]]*-[[:space:]]+/,"",l); key=val(l); next }
    /^[[:space:]]+files[[:space:]]*:/       { files=list(val($0)); next }
    /^[[:space:]]+fingerprint[[:space:]]*:/ { fp=val($0); next }
    END { flush() }
  ' "$sc"
}

# --- features: the sequencing table ------------------------------------------

cmd_features() {
  local root; root="$(_root "${1:-}")"
  _has_gspec "$root" || { printf 'FEATURES=none\n' >&2; return 0; }

  local rm="$root/.agents/roadmap.yaml"
  local tmp_rm; tmp_rm="$(mktemp)"; _roadmap_rows "$rm" > "$tmp_rm"

  local tmp; tmp="$(mktemp)"
  local prd slug order why deps done deferred
  while IFS= read -r prd; do
    [ -n "$prd" ] && [ -f "$prd" ] || continue
    # The 3.x folder layout carries the slug in the DIRECTORY name; the flat
    # layouts carry it in the basename. `_prd_paths` has already dropped plan
    # files and shadowed duplicates, so this is the only distinction left.
    case "$prd" in
      */prd.md) slug="$(basename "$(dirname "$prd")")" ;;
      *)        slug="$(basename "$prd" .md)" ;;
    esac

    done="$(_feature_done "$prd")"
    # depends_on: PRD frontmatter WINS (upstream proposal U5), roadmap is the
    # fallback. Never merged — a stale roadmap entry must not re-block a feature
    # whose PRD says it is clear (ADR 0020 Consequences, watch item e).
    deps="$(_fm_list "$prd" 'depends_on')"
    order=""; why=""; deferred=""
    if [ -s "$tmp_rm" ]; then
      local row; row="$(awk -F'\t' -v s="$slug" '$1==s {print; exit}' "$tmp_rm")"
      if [ -n "$row" ]; then
        order="$(printf '%s' "$row" | cut -f2)"
        [ -n "$deps" ] || deps="$(printf '%s' "$row" | cut -f3)"
        why="$(printf '%s' "$row" | cut -f4)"
        deferred="$(printf '%s' "$row" | cut -f5)"
      fi
    fi
    # Unlisted features sort after every explicitly ordered one, then by slug.
    [ -n "$order" ] || order=9999
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$order" "$done" "$deps" "$why" "$deferred" >> "$tmp"
  done < <(_prd_paths "$root")
  rm -f "$tmp_rm"

  # blocked = any dependency that is not done. Computed after the full set is
  # known, so a dependency's completion is read from the same snapshot.
  #
  # A DEFERRED feature still blocks its dependents, exactly like any other
  # incomplete one. Deferring says "not now", not "pretend it is done" — letting
  # it satisfy a dependency would release work whose prerequisite nobody built.
  # `deferred` is appended as the LAST field so every existing column index in
  # this TSV keeps its meaning for anything already parsing it.
  awk -F'\t' '
    { slug[NR]=$1; ord[NR]=$2; dn[NR]=$3; dep[NR]=$4; why[NR]=$5; df[NR]=$6; isdone[$1]=$3; n=NR }
    END {
      for (i=1; i<=n; i++) {
        blocked=0
        if (dep[i] != "") {
          m=split(dep[i], d, "|")
          for (j=1; j<=m; j++) if (d[j] != "" && isdone[d[j]] != "1") blocked=1
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", slug[i], ord[i], dn[i], blocked, dep[i], why[i], (df[i]=="1"?"1":"0")
      }
    }
  ' "$tmp" | sort -t"$(printf '\t')" -k2,2n -k1,1
  rm -f "$tmp"
}

# --- next: which feature does the loop pick up? (ADR 0020 D2) ----------------

cmd_next() {
  local root; root="$(_root "${1:-}")"
  if ! _has_gspec "$root"; then
    printf 'NEXT=none\nREASON=no gspec/ directory — supply a backlog another way (ADR 0020 D4)\n'
    return 0
  fi
  local rows; rows="$(cmd_features "$root")"
  if [ -z "$rows" ]; then
    printf 'NEXT=none\nREASON=no feature PRDs under gspec/features/\n'; return 0
  fi
  local pick
  pick="$(printf '%s\n' "$rows" | awk -F'\t' '$3=="0" && $4=="0" && $7!="1" && !seen {print $1; seen=1}')"
  if [ -z "$pick" ]; then
    # Three distinct nothing-to-do states, reported distinctly. Collapsing them
    # is how "the loop has stopped picking work up" gets misread as "the backlog
    # is finished" — the deferred case in particular is a human decision that can
    # be reversed by editing one line, and the reader has to be told which it is.
    if printf '%s\n' "$rows" | awk -F'\t' '$3=="0" && $7!="1"' | grep -q .; then
      printf 'NEXT=none\nREASON=every incomplete feature is blocked by an unfinished dependency\n'
      printf '%s\n' "$rows" | awk -F'\t' '$3=="0" && $7!="1" {printf "BLOCKED=%s depends_on=%s\n", $1, $5}'
      return 0
    fi
    if printf '%s\n' "$rows" | awk -F'\t' '$3=="0" && $7=="1"' | grep -q .; then
      printf 'NEXT=none\nREASON=every remaining feature is deferred in .agents/roadmap.yaml\n'
      printf '%s\n' "$rows" | awk -F'\t' '$3=="0" && $7=="1" {printf "DEFERRED=%s why=%s\n", $1, $6}'
      printf 'HINT=remove `deferred: true` from an entry to bring it back into the backlog\n'
      return 0
    fi
    printf 'NEXT=none\nREASON=all features complete\n'; return 0
  fi
  printf 'NEXT=%s\n' "$pick"
  local pp; pp="$(_resolve_plan_path "$pick" "$root")"
  if [ -n "$pp" ]; then
    local relplan; relplan="$(printf '%s' "$pp" | cut -f2)"
    printf 'PLAN=%s\n' "$relplan"
    # An older-layout plan is READ, never refused - but say so once, here, where
    # a human is looking at the next feature anyway. The remedy is gspec's own
    # migrator; this adapter does not move files.
    case "$relplan" in
      gspec/features/*/tasks.md) ;;
      *) printf 'WARN=%s is a pre-3.x plan location; /gspec-migrate relocates it to gspec/features/%s/tasks.md\n' "$relplan" "$pick" ;;
    esac
    # The 3.x feature folder's enriched siblings, when present: the loop hands
    # these PATHS to an implementer so it needs nothing else. Absent is normal
    # (a feature with no UI gets no design; an unmigrated repo has neither) and
    # never an error - /gspec-architect writes them.
    [ -f "$root/gspec/features/$pick/arch.md" ] \
      && printf 'ARCH=gspec/features/%s/arch.md\n' "$pick"
    [ -f "$root/gspec/features/$pick/design.html" ] \
      && printf 'DESIGN=gspec/features/%s/design.html\n' "$pick"
  else
    printf 'PLAN=none\n'
    printf 'HINT=run /gspec-plan %s to decompose the PRD before the loop can execute it\n' "$pick"
  fi
  [ -f "$root/.agents/roadmap.yaml" ] || \
    printf 'NOTE=no .agents/roadmap.yaml — ordering fell back to dependency then slug (ADR 0020 D2)\n'
}

# --- nodes: gspec tasks -> packet-graph NODES TSV ----------------------------

_nodes_for() {
  local root="$1" slug="$2"
  local pp; pp="$(_resolve_plan_path "$slug" "$root")"
  [ -n "$pp" ] || return 0
  local plan; plan="$(printf '%s' "$pp" | cut -f1)"
  local prd; prd="$(_resolve_prd_path "$slug" "$root" | cut -f1)"
  local fdeps; fdeps="$(_fm_list "$prd" 'depends_on')"
  if [ -z "$fdeps" ] && [ -f "$root/.agents/roadmap.yaml" ]; then
    fdeps="$(_roadmap_rows "$root/.agents/roadmap.yaml" | awk -F'\t' -v s="$slug" '$1==s && !seen {print $3; seen=1}')"
  fi

  local sc; sc="$(mktemp)"
  _sidecar_rows "$root/.agents/task-files.yaml" > "$sc"

  awk -v feature="$slug" -v fdeps="$fdeps" -v sidecar="$sc" -v planpath="$plan" '
    # Normalize for fingerprint comparison: case, markdown emphasis, whitespace.
    # Reformatting a task must not invalidate its scope; REWORDING it must.
    function norm(s) {
      s = tolower(s); gsub(/[*_`]/, "", s)
      gsub(/[[:space:]]+/, " ", s); gsub(/^ +| +$/, "", s)
      return s
    }
    BEGIN {
      while ((getline line < sidecar) > 0) {
        n = split(line, f, "\t")
        if (n >= 1 && f[1] != "") { sc_files[f[1]] = (n>=2 ? f[2] : ""); sc_fp[f[1]] = (n>=3 ? f[3] : "") }
      }
      close(sidecar)
    }
    function flush(   key) {
      if (id == "") return
      # Only UNCHECKED tasks are backlog. A checked task is done work: emitting it
      # would re-run it, and omitting it correctly dissolves edges into it.
      if (!checked) {
        produces = feature "#" id
        consumes = ""
        if (deps != "") {
          n = split(deps, d, ",")
          for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", d[i])
            if (d[i] == "" || d[i] == "-" || d[i] == "\342\200\224") continue
            consumes = (consumes == "" ? "" : consumes "|") feature "#" d[i]
          }
        }
        # Precedence: plan-authored files: > fingerprint-matched sidecar > empty.
        key = feature "#" id
        if (files == "" && (key in sc_files)) {
          if (sc_fp[key] == "")
            printf "gspec-backlog.sh: %s sidecar entry has no fingerprint — ignored (an unverifiable narrow scope is exactly what must not be trusted)\n", key > "/dev/stderr"
          else if (norm(sc_fp[key]) != norm(desc))
            printf "gspec-backlog.sh: %s sidecar fingerprint no longer matches the task text — ignored; the packet serializes conservatively. Re-scope it and update .agents/task-files.yaml\n", key > "/dev/stderr"
          else
            files = sc_files[key]
        }
        printf "%s-%s\t%s\t%s\t%s\t%s\t%s\n",
               feature, tolower(id), feature, files, consumes, produces, fdeps
      }
      id=""; checked=0; deps=""; files=""; desc=""
    }
    # Canonical `**T<n>**`, plus the two legacy shapes (see the header). An id is a
    # bold-opening token ending in digits; the bold may close right after it
    # (canonical / shape B) or run on into the description (shape A).
    /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*[A-Za-z][A-Za-z0-9_-]*[0-9]+(\*\*|[[:space:]])/ {
      flush()
      checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
      desc = $0
      sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*/, "", desc)
      match(desc, /^[A-Za-z][A-Za-z0-9_-]*[0-9]+/)
      id = substr(desc, 1, RLENGTH)
      if (id !~ /^T[0-9]+$/) legacy = 1
      desc = substr(desc, RLENGTH + 1)
      sub(/^\*\*/, "", desc)                  # canonical/B: bold closed after the id
      # Strip whatever marker run precedes the real description.
      sub(/^[[:space:]]*\[P\][[:space:]]*/, "", desc)
      sub(/^[[:space:]]*\*\*P[0-9]+\*\*[[:space:]]*/, "", desc)
      sub(/^[[:space:]]*\*\*\[GATE:[^]]*\]\*\*[[:space:]]*/, "", desc)
      sub(/^[[:space:]]*`?\[GATE:[^]]*\]`?[[:space:]]*/, "", desc)
      sub(/^[[:space:]]+/, "", desc)
      next
    }
    id != "" && /^[[:space:]]+-[[:space:]]*deps[[:space:]]*:/ {
      l=$0; sub(/^[[:space:]]+-[[:space:]]*deps[[:space:]]*:[[:space:]]*/,"",l); deps=l; next
    }
    # files: is NOT emitted by gspec today — forward-compat with upstream
    # proposal U1. Absent => empty scope => packet-graph serializes conservatively.
    id != "" && /^[[:space:]]+-[[:space:]]*files[[:space:]]*:/ {
      l=$0; sub(/^[[:space:]]+-[[:space:]]*files[[:space:]]*:[[:space:]]*/,"",l)
      gsub(/^\[|\]$/,"",l); gsub(/[[:space:]]*,[[:space:]]*/,"|",l)
      gsub(/[[:space:]]+$/,"",l); files=l; next
    }
    END {
      flush()
      if (legacy)
        printf "gspec-backlog.sh: %s uses a LEGACY task-line format (pre-2.0, architect-authored). It is read, but regenerate it with /gspec-plan for canonical ids, deps: and covers:.\n", planpath > "/dev/stderr"
    }
  ' "$plan"
  rm -f "$sc"
}

# --- files-status: audit the sidecar against the live plans ------------------
# The sidecar is the one hand-maintained input that can cost CORRECTNESS, so it
# gets an explicit audit rather than only a passing stderr note during `nodes`.
cmd_files_status() {
  local root; root="$(_root "${1:-}")"
  local scf="$root/.agents/task-files.yaml"
  if [ ! -f "$scf" ]; then
    printf 'FILES=none\nNOTE=no .agents/task-files.yaml — every packet gets empty scope and serializes conservatively (ADR 0020 U1-local)\n'
    return 0
  fi
  # Build the live task table from every plan: key \t checked \t normalized desc.
  local live; live="$(mktemp)"
  local plan slug
  while IFS=$'\t' read -r plan slug; do
    [ -n "$plan" ] && [ -f "$plan" ] || continue
    awk -v feature="$slug" '
      function norm(s) { s=tolower(s); gsub(/[*_`]/,"",s); gsub(/[[:space:]]+/," ",s); gsub(/^ +| +$/,"",s); return s }
      /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*T[0-9]+\*\*/ {
        checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
        match($0, /\*\*T[0-9]+\*\*/); id = substr($0, RSTART+2, RLENGTH-4)
        d=$0
        sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*/,"",d)
        sub(/^\*\*T[0-9]+\*\*[[:space:]]*/,"",d); sub(/^\[P\][[:space:]]*/,"",d)
        sub(/^\*\*P[0-9]+\*\*[[:space:]]*/,"",d)
        printf "%s#%s\t%s\t%s\n", feature, id, checked, norm(d)
      }' "$plan" >> "$live"
  done < <(_plan_paths "$root")

  local ok=0 stale=0 unfp=0 done_=0 orphan=0 key files fp row lchecked ldesc nfp
  while IFS=$'\t' read -r key files fp; do
    [ -n "$key" ] || continue
    row="$(awk -F'\t' -v k="$key" '$1==k {print; exit}' "$live")"
    if [ -z "$row" ]; then
      printf 'orphan          %s   (no such task in any plan — safe, but dead weight)\n' "$key"; orphan=$((orphan+1)); continue
    fi
    lchecked="$(printf '%s' "$row" | cut -f2)"; ldesc="$(printf '%s' "$row" | cut -f3)"
    if [ "$lchecked" = "1" ]; then
      printf 'done            %s   (task is already checked off — entry unused)\n' "$key"; done_=$((done_+1)); continue
    fi
    if [ -z "$fp" ]; then
      printf 'unfingerprinted %s   (IGNORED — add a fingerprint or the scope cannot be trusted)\n' "$key"; unfp=$((unfp+1)); continue
    fi
    nfp="$(printf '%s' "$fp" | tr '[:upper:]' '[:lower:]' | tr -d '*_`' | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"
    if [ "$nfp" = "$ldesc" ]; then
      printf 'ok              %s   -> %s\n' "$key" "$files"; ok=$((ok+1))
    else
      printf 'stale           %s   (IGNORED — task text changed; re-scope and update the entry)\n' "$key"; stale=$((stale+1))
    fi
  done < <(_sidecar_rows "$scf")
  rm -f "$live"

  printf 'FILES=%s ok=%d stale=%d unfingerprinted=%d done=%d orphan=%d\n' \
    "$([ $((stale+unfp)) -eq 0 ] && printf ok || printf attention)" "$ok" "$stale" "$unfp" "$done_" "$orphan"
  [ $((stale+unfp)) -eq 0 ] || printf 'NOTE=ignored entries do not break the run — those packets just serialize (wrong-wide, never wrong-narrow)\n'
}

# --- check-task: the adapter's ONE write (ADR 0025 D1 / ADR 0020 D2) ---------
# Flip exactly one task's checkbox `[ ]` -> `[x]` in the feature's plan file
# (whichever layout it is in -- `_resolve_plan_path` decides, never this), and
# NOTHING else. Every outcome except the last exits 0, because gspec is OPTIONAL
# (D4) -- a non-gspec backlog has no checkbox to flip, and its absence is not a
# failure. Only a task id that names an EXISTING plan but no such task is loud
# (exit 4): that is genuine drift -- a packet naming a gspec task that does not
# exist -- and drift must not be silent.
#
# <task> accepts two forms so no call site has to do its own id surgery:
#   canonical  <feature>#T<n>     (e.g. run-state-cleanup#T1)
#   packet-id  <feature>-t<n>     (e.g. run-state-cleanup-t1 -- the node id
#                                  _nodes_for emits, and what the loop actually
#                                  holds at packet close)
# _resolve_task_id <task> <root> — the id-resolution check-task and task-status
# (T2) share: both accept `<feature>#T<n>` and the packet-id form
# `<feature>-t<n>`, and must resolve them IDENTICALLY. A second copy that
# drifted from this one is the defect this factoring exists to prevent. Prints
# exactly one of:
#   NOGSPEC                    no gspec/ directory at all (ADR 0020 D4)
#   UNRESOLVED                 the token does not resolve to any real plan file
#   REFUSED <message>          a canonical-form slug contains a path separator
#                               or a '..' component (ADR 0025 D1) -- printed,
#                               never `die`d, here: this runs inside a caller's
#                               command substitution, where `exit` would only
#                               kill the subshell capturing it, not the script.
#                               Every caller must `die` on a REFUSED line itself.
#   RESOLVED\t<slug>\t<id>      resolved to a real plan file. Whether <id>
#                               actually EXISTS in that plan -- and its checked
#                               state -- is NOT determined here: check-task and
#                               task-status each need a different answer to
#                               that (flip-or-already-or-notfound vs.
#                               finished/unchecked/unknown), so it stays out of
#                               the shared part. See `_task_lookup`.
_resolve_task_id() {
  local task="$1" root="$2"
  local slug="" id=""
  case "$task" in
    *'#'*)
      slug="${task%%#*}"
      id="${task#*#}"
      ;;
    *)
      : # resolved below, once we know gspec/ is even present to resolve against
      ;;
  esac

  if ! _has_gspec "$root"; then
    printf 'NOGSPEC\n'
    return 0
  fi

  if [ -n "$slug" ]; then
    # The canonical form's slug is caller-supplied text, not a resolved
    # filename -- unlike the packet-id form below, nothing guarantees it
    # stays inside gspec/. Reject a path separator or a '..'
    # component before any file test (ADR 0025 D1: the adapter's one write
    # is confined to the resolved plan path, and gspec 3.x's layout
    # INTERPOLATES the slug into a DIRECTORY name -- gspec/features/<slug>/
    # tasks.md -- so this check went from belt-and-braces to load-bearing when
    # that layout landed; task-status refuses the same
    # unsafe input even though it never writes, so the two callers cannot
    # silently diverge on it). This runs after the gspec-is-optional early
    # return above -- and can safely do so, because that return only ever
    # tests $root/gspec, never the caller-supplied slug -- so every
    # gspec-optional case still exits 0 regardless of what the caller passed
    # as a slug.
    case "$slug" in
      */*|*'..'*)
        printf 'REFUSED refusing a task id whose feature slug contains a path separator or '"'"'..'"'"' component (ADR 0025 D1)\n'
        return 0
        ;;
    esac
  fi

  if [ -z "$slug" ]; then
    # packet-id form: <feature>-<id>. Ids are NOT guaranteed to be hyphen-free
    # -- a legacy shape-B plan line (`- [ ] **ser-t1** ...`) has id `ser-t1`,
    # so peeling a trailing `-t<digits>` off the token is unsound (it would
    # read `ser-ser-t1` as slug `ser-ser`, id `t1`, and silently match
    # nothing). Resolve against the plan filenames that actually exist
    # instead: the token matches iff it is exactly "<slug>-<remainder>" for
    # some real plan basename, and the remainder is then the task id. This
    # also means the resolved slug is always a real basename on disk, so --
    # unlike the canonical form above -- it is structurally incapable of
    # containing a path separator or '..'; no separate check needed here.
    local best="" f cand
    while IFS=$'\t' read -r f cand; do
      [ -n "$cand" ] || continue
      case "$task" in
        "$cand"-*)
          # Prefer the LONGEST matching slug, so a feature whose slug itself
          # ends in -t<digits> (e.g. phase-t2, task phase-t2-t1) still
          # resolves to the right plan and id instead of the shorter decoy.
          # This is also why the ambiguity is safe: `nodes` emits
          # <feature>-<tolower(id)>, so feature `phase` task `t2-t1` and
          # feature `phase-t2` task `T1` both produce the node id
          # `phase-t2-t1` -- a pre-existing namespace collision. Longest-wins
          # always picks the longer slug here; when the live task is
          # actually in the shorter-slug plan, resolution against that
          # slug's id then fails and the result is a loud rc=4 "no such
          # task", never a wrong flip.
          if [ "${#cand}" -gt "${#best}" ]; then best="$cand"; fi
          ;;
      esac
    done < <(_plan_paths "$root")
    if [ -n "$best" ]; then
      slug="$best"
      id="${task#"$best"-}"
    fi
  fi

  if [ -z "$slug" ] || [ -z "$id" ]; then
    printf 'UNRESOLVED\n'
    return 0
  fi

  printf 'RESOLVED\t%s\t%s\n' "$slug" "$id"
}

# _resolve_plan_path <slug> <root> — the plan-file location every caller shares,
# newest layout first: gspec/features/<slug>/tasks.md (3.x), then
# gspec/tasks/<slug>.md (2.x), then the pre-2.0 gspec/features/<slug>.plan.md.
# The promise this function made when it had two entries held when it grew to
# three: adding gspec 3.x's layout meant editing here and in the two enumerators,
# not in the nine places that used to build these paths inline. Prints
# "<plan>\t<relplan>" if any exists on disk, or nothing (empty output) if none
# does -- callers test for that emptiness.
_resolve_plan_path() {
  local slug="$1" root="$2"
  if [ -f "$root/gspec/features/$slug/tasks.md" ]; then
    printf '%s\t%s\n' "$root/gspec/features/$slug/tasks.md" "gspec/features/$slug/tasks.md"
  elif [ -f "$root/gspec/tasks/$slug.md" ]; then
    printf '%s\t%s\n' "$root/gspec/tasks/$slug.md" "gspec/tasks/$slug.md"
  elif [ -f "$root/gspec/features/$slug.plan.md" ]; then
    printf '%s\t%s\n' "$root/gspec/features/$slug.plan.md" "gspec/features/$slug.plan.md"
  fi
}

# _task_lookup <plan> <idlc> — the READ-ONLY duplicate-id lookup check-task and
# task-status share. Prefers the FIRST UNCHECKED match over an earlier checked
# one: a malformed plan with a duplicate id (`- [x] **T1**` sorted above
# `- [ ] **T1**`) must not report "already"/finished while leaving the real,
# unchecked task live for `nodes` to keep re-emitting forever. Only when no
# unchecked match exists anywhere in the file does an earlier checked match
# count as "already". Prints "flip <id>" (an unchecked match exists), "already
# <id>" (only checked matches exist), or nothing (no match at all).
_task_lookup() {
  local plan="$1" want="$2"
  awk -v want="$want" '
    /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*[A-Za-z][A-Za-z0-9_-]*[0-9]+(\*\*|[[:space:]])/ {
      desc = $0
      sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*/, "", desc)
      match(desc, /^[A-Za-z][A-Za-z0-9_-]*[0-9]+/)
      lid = substr(desc, 1, RLENGTH)
      if (tolower(lid) == want) {
        checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
        if (!checked) { print "flip " lid; found = 1; exit }
        if (checked_id == "") checked_id = lid
      }
    }
    END {
      if (!found && checked_id != "") print "already " checked_id
    }
  ' "$plan"
}

cmd_check_task() {
  local task="${1:-}"; [ -n "$task" ] || die "check-task: need a task id"
  local root; root="$(_root "${2:-}")"

  local resolved; resolved="$(_resolve_task_id "$task" "$root")"
  case "$resolved" in
    NOGSPEC)
      printf 'CHECKED=none\nREASON=no gspec/ directory — gspec is optional (ADR 0020 D4)\n'
      return 0
      ;;
    UNRESOLVED)
      printf 'CHECKED=none\nREASON=not a gspec task id — nothing to flip (ADR 0020 D4: gspec is optional)\n'
      return 0
      ;;
    REFUSED\ *)
      die "check-task: ${resolved#REFUSED }"
      ;;
  esac
  local slug id
  slug="$(printf '%s' "$resolved" | cut -f2)"
  id="$(printf '%s' "$resolved" | cut -f3)"

  local plan relplan pp
  pp="$(_resolve_plan_path "$slug" "$root")"
  if [ -n "$pp" ]; then
    plan="$(printf '%s' "$pp" | cut -f1)"; relplan="$(printf '%s' "$pp" | cut -f2)"
  else
    printf 'CHECKED=none\nREASON=no plan file for feature %s in any gspec layout — nothing to flip\n' "$slug"
    return 0
  fi

  local idlc; idlc="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"

  # Pass 1: READ-ONLY lookup. Determines whether the target task exists and,
  # if so, whether it is already checked -- without touching the file. This is
  # what makes the idempotent and not-found paths provably byte-identical: the
  # file is never opened for writing unless a real flip is about to happen.
  local lookup status="notfound" foundid=""
  lookup="$(_task_lookup "$plan" "$idlc")"
  if [ -n "$lookup" ]; then
    status="${lookup%% *}"
    foundid="${lookup#* }"
  fi

  if [ "$status" = "notfound" ]; then
    printf 'CHECKED=none\nREASON=%s has no task %s in %s\n' "$slug" "$id" "$relplan"
    return 4
  fi

  if [ "$status" = "already" ]; then
    printf 'CHECKED=already\nFILE=%s\n' "$relplan"
    return 0
  fi

  # Pass 2: the actual write. Rewrite ONLY the leading `[ ]` marker of the
  # matched line -- a plain `sub()` against the untouched `$0` copy, never a
  # field-rebuild, so every other byte on that line (and every byte of every
  # other line) survives verbatim. Only the first UNCHECKED matching id is
  # flipped -- the same gate as pass 1, so the two passes cannot disagree
  # about which line a duplicated id resolves to.
  # Atomic: build into a temp file in the same directory, then `mv` over the
  # original -- a reader never observes a partially-written plan file.
  # `cp -p` (not a bare empty `mktemp` file) carries the plan's own mode onto
  # the temp file, so the later `mv` doesn't narrow it to mktemp's 0600 --
  # git tracks only the exec bit, so a silent 0644->0600 would be invisible
  # to `git diff` and to review.
  # These are GLOBALS, deliberately, and must not be made `local` again. An EXIT
  # trap fires while the shell is unwinding, and whether a function-local is still
  # in scope at that point is bash-version-dependent: 3.2 (macOS) still sees it, so
  # `trap 'rm -f "$tmp"' EXIT` cleaned up and the sweep passed; 5.2 (Linux, CI) does
  # not, and under `set -u` the trap died with `tmp: unbound variable` before
  # reaching the `rm`, stranding the temp file beside the plan. Reproduced in
  # both versions. The `${x:-}` guards keep the trap safe even if it somehow fires
  # before either assignment.
  _ct_tmp=""; _ct_tmp2=""
  _ct_tmp="$(mktemp "$(dirname "$plan")/.gspec-check-task.XXXXXX")"
  # No process-wide trap: scoped to this write only, set as soon as the temp
  # file exists and disarmed right after the final `mv` succeeds, so a
  # stranded temp file under set -euo pipefail (cp, awk, or mv failing) can't
  # survive as untracked scratch beside the plan file.
  trap 'for _f in "${_ct_tmp:-}" "${_ct_tmp2:-}"; do [ -n "$_f" ] && rm -f "$_f"; done; :' EXIT
  # Aliases so the body below reads unchanged. `tmp2` is deliberately NOT aliased:
  # it is assigned mid-body, and a local copy would leave the trap holding the
  # empty initial value — the same scope trap this fix exists for, one variable over.
  local tmp; tmp="$_ct_tmp"
  cp -p "$plan" "$tmp"
  awk -v want="$idlc" '
    BEGIN { done = 0 }
    /^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*[A-Za-z][A-Za-z0-9_-]*[0-9]+(\*\*|[[:space:]])/ && !done {
      desc = $0
      sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*\*\*/, "", desc)
      match(desc, /^[A-Za-z][A-Za-z0-9_-]*[0-9]+/)
      lid = substr(desc, 1, RLENGTH)
      checked = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[xX]\]/) ? 1 : 0
      if (tolower(lid) == want && !checked) {
        line = $0
        sub(/\[ \]/, "[x]", line)   # leftmost "[ ]" on the line is always the
        print line                 # leading marker -- the header regex above
        done = 1                   # already confirmed this line is unchecked.
        next
      }
    }
    { print }
  ' "$plan" > "$tmp"

  # awk's print always terminates the record it writes, so a plan lacking a
  # final newline would gain one byte here. Drop that byte before the mv so
  # the write really does touch nothing else in the file.
  if [ -n "$(tail -c1 "$plan")" ]; then
    local sz; sz="$(wc -c < "$tmp")"; sz=$((sz - 1))
    _ct_tmp2="$(mktemp "$(dirname "$plan")/.gspec-check-task.XXXXXX")"
    head -c "$sz" "$tmp" > "$_ct_tmp2"
    cat "$_ct_tmp2" > "$tmp"       # rewrite tmp's own inode -- keeps its mode
    rm -f "$_ct_tmp2"; _ct_tmp2=""
  fi

  mv "$tmp" "$plan"
  trap - EXIT

  printf 'CHECKED=%s#%s\nFILE=%s\n' "$slug" "$foundid" "$relplan"
}

# --- task-status: read-only completion status for a drifted-record report ----
# (run-state-cleanup T2 / ADR 0020-adjacent). Reuses `_resolve_task_id` and
# `_task_lookup` verbatim -- the same id resolution and duplicate-id handling
# check-task has, never a second copy that can drift from it. NEVER writes:
# check-task remains the adapter's one write (ADR 0025 D1).
cmd_task_status() {
  local ids_raw="${1:-}"; [ -n "$ids_raw" ] || die "task-status: need at least one packet id"
  local root; root="$(_root "${2:-}")"
  [ -d "$root" ] || die "task-status: no such directory: $root"

  local finished_list="" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    local state="" reason=""
    local resolved; resolved="$(_resolve_task_id "$id" "$root")"
    case "$resolved" in
      NOGSPEC)
        state="unknown"; reason="no gspec/ directory — gspec is optional (ADR 0020 D4)"
        ;;
      UNRESOLVED)
        state="unknown"; reason="not a gspec task id"
        ;;
      REFUSED\ *)
        die "task-status: ${resolved#REFUSED }"
        ;;
      *)
        local slug tid plan="" relplan="" pp
        slug="$(printf '%s' "$resolved" | cut -f2)"
        tid="$(printf '%s' "$resolved" | cut -f3)"
        pp="$(_resolve_plan_path "$slug" "$root")"
        if [ -n "$pp" ]; then
          plan="$(printf '%s' "$pp" | cut -f1)"; relplan="$(printf '%s' "$pp" | cut -f2)"
        fi
        if [ -z "$plan" ]; then
          state="unknown"; reason="no plan file for feature $slug in any gspec layout"
        else
          local idlc lookup
          idlc="$(printf '%s' "$tid" | tr '[:upper:]' '[:lower:]')"
          lookup="$(_task_lookup "$plan" "$idlc")"
          case "$lookup" in
            flip\ *)    state="unchecked"; reason="${relplan}#$(printf '%s' "$lookup" | cut -d' ' -f2)" ;;
            already\ *) state="finished";  reason="${relplan}#$(printf '%s' "$lookup" | cut -d' ' -f2)" ;;
            *)          state="unknown";   reason="no task $tid in $relplan" ;;
          esac
        fi
        ;;
    esac
    printf '%s\t%s\t%s\n' "$id" "$state" "$reason"
    [ "$state" = "finished" ] && finished_list="${finished_list:+${finished_list},}${id}"
  done <<EOF
$(printf '%s' "$ids_raw" | tr ',' '\n')
EOF

  printf 'FINISHED=%s\n' "$finished_list"
}

cmd_nodes() {
  local slug="${1:-}"; [ -n "$slug" ] || die "nodes: need a feature slug"
  local root; root="$(_root "${2:-}")"
  _nodes_for "$root" "$slug"
}

cmd_nodes_all() {
  local root; root="$(_root "${1:-}")"
  _has_gspec "$root" || return 0
  local slug
  # Deferred features emit no nodes, for the same reason `next` skips them:
  # otherwise /gaffer:build-packet-dependency-tree schedules waves of work the
  # human has explicitly decided not to start.
  #
  # The filter is awk, NOT `while IFS=$'\t' read -r a b c ...`, and that is a bug
  # fix rather than a style choice. TAB is an IFS *whitespace* character, so bash
  # collapses a run of them into ONE delimiter even when IFS is set to tab alone:
  # a row with an empty `depends_on` (field 5) silently shifts every later field
  # left. The old read form survived only because `done`/`blocked` sit BEFORE the
  # first field that can be empty; `deferred` sits after it and broke immediately.
  # awk -F'\t' does not collapse empty fields, so it stays correct as fields are
  # added. Any future reader of this TSV must use awk for the same reason.
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    _nodes_for "$root" "$slug"
  done < <(cmd_features "$root" | awk -F'\t' '$3=="0" && $4=="0" && $7!="1" {print $1}')
}

# --- interlock: is a `gspec build` already driving this repo? (D5) -----------
# FAIL-SOFT by contract: status.json sits outside the pinned artifact contract,
# so an absent, unreadable, or unknown-shaped file yields `unknown` and never
# blocks. Only an explicit live `running` is reported busy.
cmd_interlock() {
  local root; root="$(_root "${1:-}")"
  local sj="$root/.gspec/build/status.json"
  [ -f "$sj" ] || { printf 'INTERLOCK=clear\n'; return 0; }
  local state pid
  if command -v jq >/dev/null 2>&1; then
    state="$(jq -r '.state // empty' "$sj" 2>/dev/null || true)"
    pid="$(jq -r '.pid // empty' "$sj" 2>/dev/null || true)"
  else
    state="$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$sj" 2>/dev/null | head -1 || true)"
    pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$sj" 2>/dev/null | head -1 || true)"
  fi
  [ -n "$state" ] || { printf 'INTERLOCK=unknown\nREASON=unrecognized .gspec/build/status.json shape\n'; return 0; }
  if [ "$state" != "running" ]; then
    printf 'INTERLOCK=clear\nGSPEC_BUILD_STATE=%s\n' "$state"; return 0
  fi
  # `running` with a dead pid is gspec's own crash signal, not a live driver.
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    printf 'INTERLOCK=clear\nGSPEC_BUILD_STATE=running(stale pid %s — crashed)\n' "$pid"; return 0
  fi
  printf 'INTERLOCK=busy\nGSPEC_BUILD_STATE=running\nPID=%s\n' "${pid:-unknown}"
  printf 'REASON=a gspec build is driving this repo; two drivers fanning implementers into one checkout will collide (ADR 0020 D5)\n'
}

# --- dispatch ----------------------------------------------------------------
case "${1:-}" in
  pin)       shift; cmd_pin "$@" ;;
  check)     shift; cmd_check "$@" ;;
  features)  shift; cmd_features "$@" ;;
  next)      shift; cmd_next "$@" ;;
  nodes)     shift; cmd_nodes "$@" ;;
  nodes-all) shift; cmd_nodes_all "$@" ;;
  interlock) shift; cmd_interlock "$@" ;;
  files-status) shift; cmd_files_status "$@" ;;
  check-task) shift; cmd_check_task "$@" ;;
  task-status) shift; cmd_task_status "$@" ;;
  *) die "usage: gspec-backlog.sh {pin|check|features|next|nodes <slug>|nodes-all|interlock|files-status|check-task <task>|task-status <id[,id...]>} [root]" ;;
esac
