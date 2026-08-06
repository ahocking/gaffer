#!/usr/bin/env bash
# =============================================================================
# packet-graph.sh — deterministic packet dependency-graph math (ADR 0016)
# =============================================================================
# The testable, agent-free core behind `/build-packet-dependency-tree` and the
# `--parallel` loop scheduler. It turns a flat list of packet NODES into a
# dependency DAG with parallel WAVES, and answers "what is safe to run right now"
# — so the skill and the driver make judgment calls while the graph MATH lives
# here where it can be unit-tested (mirrors runstate.sh / guard.sh).
#
# Two kinds of edge (ADR 0016 disjointness invariant):
#   depends_on  — ORDERING. B depends_on A when B.consumes a signature A.produces,
#                 or B's feature depends_on A's feature. B may not start until A is
#                 done. Drives wave assignment.
#   excludes    — MUTUAL EXCLUSION. P excludes Q when their allowed_files could
#                 touch a common path (glob-prefix overlap). They may run in EITHER
#                 order but NEVER concurrently — a shared file is where a parallel
#                 merge would conflict. Does NOT affect wave; constrains the
#                 runtime ready-set only. Unknown/empty file scope ⇒ excludes
#                 everything (conservative: serialize what we cannot prove disjoint).
#
# Subcommands:
#   build [nodes.tsv]                 read NODES (file arg or stdin), emit the
#                                     packet-graph YAML on stdout. Exit non-zero on
#                                     a dependency CYCLE (prints the cycle members).
#   validate <graph.yaml>             re-derive waves from the emitted graph; exit
#                                     non-zero on a cycle; report conservatively-
#                                     serialized (empty-scope) packets on stdout.
#   ready <graph.yaml> --max N [--done a,b,...] [--running c,d,...]
#                                     print the dispatchable packet ids (one per
#                                     line): not done/running, every depends_on in
#                                     --done, not excluded by any --running packet,
#                                     greedily selected so no two picked packets
#                                     exclude each other, capped at N − |running|.
#                                     Deterministic (wave asc, then id asc).
#
# NODES input format (TSV, one packet per line; the skill produces it):
#   <id>\t<feature>\t<allowed_files>\t<consumes>\t<produces>\t<feature_depends_on>
#   - Fields are TAB-separated. List fields (allowed_files, consumes, produces,
#     feature_depends_on) are '|'-separated; empty means none. List items must not
#     contain a TAB or a literal '|'. Blank lines and lines starting with '#' are
#     ignored. `id` and `feature` are required; the rest may be empty.
#   - consumes/produces are opaque signature tokens compared by EXACT string match;
#     the skill decides how to normalize them (copy signatures verbatim).
#
# Exit codes: 0 = ok; 2 = dependency cycle (build/validate); 1 = usage / bad input.
# =============================================================================

set -euo pipefail

die() { printf 'packet-graph.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

# -----------------------------------------------------------------------------
# build: NODES tsv -> packet-graph YAML (+ cycle detection)
# -----------------------------------------------------------------------------
cmd_build() {
  local src="${1:-/dev/stdin}"
  [ "$src" = "/dev/stdin" ] || [ -f "$src" ] || die "no nodes file at '$src'"
  awk -F'\t' '
    function trim(s){ sub(/^[ \t\r]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
    # literal path-prefix of a glob: segments before the first wildcarded one.
    # A leading wildcard (empty prefix) means "matches anything".
    function litprefix(g,   segs,n,i,out){
      n=split(g,segs,"/"); out="";
      for(i=1;i<=n;i++){
        if(segs[i] ~ /[*?\[]/) break;
        out = (out=="") ? segs[i] : out "/" segs[i];
      }
      return out;
    }
    # segment-aware prefix test: is a a path-prefix of b?
    function isprefix(a,b){ return (a==b) || (index(b, a "/")==1) }
    # do packets pi, pj share a possible path? (excludes edge)
    function overlap(pi,pj,   na,nb,ia,ib,ga,gb,pa,pb){
      # empty scope on either side => matches-all => overlap
      if(af_n[pi]==0 || af_n[pj]==0) return 1;
      for(ia=1;ia<=af_n[pi];ia++){
        ga=af[pi,ia]; pa=litprefix(ga);
        for(ib=1;ib<=af_n[pj];ib++){
          gb=af[pj,ib]; pb=litprefix(gb);
          if(pa=="" || pb=="") return 1;             # leading wildcard
          if(isprefix(pa,pb) || isprefix(pb,pa)) return 1;
        }
      }
      return 0;
    }

    # --- read all nodes -------------------------------------------------------
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    {
      id=trim($1); feat=trim($2);
      if(id==""){ printf("packet-graph.sh: node on line %d has no id\n",NR) > "/dev/stderr"; err=1; next }
      order[++N]=id; idx[id]=N; feature[id]=feat;
      afs[id]=$3; cons[id]=$4; prods[id]=$5; fdeps[id]=$6;
      # index allowed_files list
      an=split($3,ap,"|"); af_n[id]=0;
      for(i=1;i<=an;i++){ v=trim(ap[i]); if(v!=""){ af[id, ++af_n[id]]=v } }
      # record producers: producer_of[token] = id (last writer wins; also keep list)
      pn=split($5,pp,"|");
      for(i=1;i<=pn;i++){ v=trim(pp[i]); if(v!=""){ prod_by[v]= (v in prod_by ? prod_by[v] SUBSEP id : id) } }
      # map feature -> packet ids
      feat_pkts[feat] = (feat in feat_pkts ? feat_pkts[feat] SUBSEP id : id);
    }

    END{
      if(err){ exit 1 }
      # --- depends_on edges: interface (consumes -> producer) ---------------
      for(k=1;k<=N;k++){
        id=order[k];
        cn=split(cons[id],cc,"|");
        for(i=1;i<=cn;i++){
          tok=trim(cc[i]); if(tok=="") continue;
          if(tok in prod_by){
            m=split(prod_by[tok],prs,SUBSEP);
            for(j=1;j<=m;j++){ if(prs[j]!=id) dep[id]=adddep(dep[id],prs[j]) }
          }
          # a consumed token with no in-graph producer is external/pre-existing: ignore
        }
        # --- feature edges: depend on all packets of each depended feature ---
        fn=split(fdeps[id],ff,"|");
        for(i=1;i<=fn;i++){
          gf=trim(ff[i]); if(gf=="" || !(gf in feat_pkts)) continue;
          m=split(feat_pkts[gf],fp,SUBSEP);
          for(j=1;j<=m;j++){ if(fp[j]!=id) dep[id]=adddep(dep[id],fp[j]) }
        }
      }
      # --- excludes edges: pairwise allowed_files overlap -------------------
      for(a=1;a<=N;a++){ for(b=a+1;b<=N;b++){
        ia=order[a]; ib=order[b];
        if(overlap(ia,ib)){ exc[ia]=adddep(exc[ia],ib); exc[ib]=adddep(exc[ib],ia) }
      }}
      # --- waves: longest-path over depends_on (+ cycle detection) ----------
      for(k=1;k<=N;k++){ wave[order[k]]=0 }
      for(iter=0;iter<=N;iter++){
        changed=0;
        for(k=1;k<=N;k++){
          id=order[k]; mx=-1;
          dn=split(dep[id],dd,SUBSEP);
          for(i=1;i<=dn;i++){ if(dd[i]!="" && wave[dd[i]]>mx) mx=wave[dd[i]] }
          w = (dn>0 && dep[id]!="") ? mx+1 : 0;
          if(w>wave[id]){ wave[id]=w; changed=1 }
        }
        if(!changed) break;
      }
      if(changed){
        printf("packet-graph.sh: dependency CYCLE detected (waves did not converge)\n") > "/dev/stderr";
        # name the packets still implicated: those whose wave kept rising to N
        for(k=1;k<=N;k++){ if(wave[order[k]]>=N) printf("  in cycle: %s\n",order[k]) > "/dev/stderr" }
        exit 2;
      }
      # --- emit YAML, ordered by (wave asc, id asc) -------------------------
      # simple selection sort on (wave,id) into ord2[]
      for(k=1;k<=N;k++) ord2[k]=order[k];
      for(a=1;a<=N;a++){ for(b=a+1;b<=N;b++){
        if( wave[ord2[b]] < wave[ord2[a]] ||
            (wave[ord2[b]]==wave[ord2[a]] && ord2[b] < ord2[a]) ){ t=ord2[a]; ord2[a]=ord2[b]; ord2[b]=t }
      }}
      maxwave=0; for(k=1;k<=N;k++){ if(wave[ord2[k]]>maxwave) maxwave=wave[ord2[k]] }
      # per-wave counts for the concurrency hint
      for(k=1;k<=N;k++){ wc[wave[ord2[k]]]++ }
      biggest=0; for(w=0;w<=maxwave;w++){ if(wc[w]>biggest) biggest=wc[w] }

      print "# Packet dependency graph — generated by packet-graph.sh (ADR 0016).";
      print "# depends_on = ordering (interface + feature edges); excludes = must not";
      print "# run concurrently (allowed_files overlap). Regenerate; do not hand-edit.";
      print "schema: 1";
      printf("waves: %d\n", maxwave+1);
      printf("max_wave_size: %d   # upper bound on useful concurrency before the max_parallel cap\n", biggest);
      print "packets:";
      for(k=1;k<=N;k++){
        id=ord2[k];
        printf("  - id: %s\n", id);
        printf("    feature: %s\n", feature[id]);
        printf("    wave: %d\n", wave[id]);
        printf("    depends_on: %s\n", flow(dep[id]));
        printf("    excludes: %s\n", flow(exc[id]));
        printf("    allowed_files: %s\n", flowraw(afs[id]));
      }
    }
    # append to a SUBSEP-joined set without duplicates
    function adddep(set,item,   n,a,i){
      if(set=="") return item;
      n=split(set,a,SUBSEP);
      for(i=1;i<=n;i++){ if(a[i]==item) return set }
      return set SUBSEP item;
    }
    # SUBSEP-joined set -> YAML flow list "[a, b]" (sorted for stable output)
    function flow(set,   n,a,i,j,t,out){
      if(set=="") return "[]";
      n=split(set,a,SUBSEP);
      for(i=1;i<=n;i++){ for(j=i+1;j<=n;j++){ if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t} } }
      out=""; for(i=1;i<=n;i++){ out = (out=="") ? a[i] : out ", " a[i] }
      return "[" out "]";
    }
    # raw "|"-joined list -> YAML flow list, order preserved
    function flowraw(s,   n,a,i,v,out){
      if(trim(s)=="") return "[]";
      n=split(s,a,"|"); out="";
      for(i=1;i<=n;i++){ v=trim(a[i]); if(v!=""){ out = (out=="") ? v : out ", " v } }
      return "[" out "]";
    }
  ' "$src"
}

# -----------------------------------------------------------------------------
# helpers to read the emitted graph YAML (flow-style, one field per line)
# -----------------------------------------------------------------------------
# Print "id<TAB>wave<TAB>depends_on(csv)<TAB>excludes(csv)<TAB>allowed_files(csv)"
# per packet. Flow lists are unwrapped to comma-joined; "[]" -> empty.
_graph_records() {
  local g="$1"
  [ -f "$g" ] || die "no graph file at '$g'"
  awk '
    function unflow(s){ sub(/^[^[]*\[/,"",s); sub(/\].*$/,"",s); gsub(/[ \t]+/,"",s); return s }
    /^[ \t]*-[ \t]*id:/       { if(id!="") emit(); id=$0; sub(/^[^:]*:[ \t]*/,"",id); w=0;dep="";exc="";af=""; next }
    /^[ \t]*wave:/            { w=$0;   sub(/^[^:]*:[ \t]*/,"",w) }
    /^[ \t]*depends_on:/      { dep=unflow($0) }
    /^[ \t]*excludes:/        { exc=unflow($0) }
    /^[ \t]*allowed_files:/   { af=unflow($0) }
    END{ if(id!="") emit() }
    function emit(){ printf("%s\t%s\t%s\t%s\t%s\n", id, w, dep, exc, af) }
  ' "$g"
}

# -----------------------------------------------------------------------------
# validate: cycle check + conservatively-serialized report
# -----------------------------------------------------------------------------
cmd_validate() {
  local g="${1:-}"; [ -n "$g" ] || die "usage: validate <graph.yaml>"
  [ -f "$g" ] || die "no graph file at '$g'"
  # Rebuild waves from depends_on and re-run the convergence/cycle check.
  local out; out="$(_graph_records "$g")"
  printf '%s\n' "$out" | awk -F'\t' '
    { id=$1; wv[id]=$2; deps[id]=$3; af[id]=$5; ids[++N]=id }
    END{
      # cycle re-check via relaxation on depends_on
      for(k=1;k<=N;k++) w[ids[k]]=0;
      for(it=0;it<=N;it++){ ch=0;
        for(k=1;k<=N;k++){ id=ids[k]; mx=-1; n=split(deps[id],d,",");
          if(deps[id]!=""){ for(i=1;i<=n;i++){ if(w[d[i]]>mx)mx=w[d[i]] }; nw=mx+1 } else nw=0;
          if(nw>w[id]){ w[id]=nw; ch=1 } }
        if(!ch) break }
      if(ch){ print "VALIDATE=cycle"; exit 2 }
      # conservatively-serialized = empty allowed_files
      cons=0; for(k=1;k<=N;k++){ if(af[ids[k]]==""){ cons++; clist=(clist==""?ids[k]:clist ", " ids[k]) } }
      printf("VALIDATE=ok\npackets: %d\nconservatively_serialized: %d%s\n", N, cons, (cons? " ("clist")":""));
    }'
}

# -----------------------------------------------------------------------------
# ready: dispatchable set given done/running + a max_parallel cap
# -----------------------------------------------------------------------------
cmd_ready() {
  local g="" max="" done_csv="" running_csv=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max)     max="${2:-}"; shift 2 ;;
      --done)    done_csv="${2:-}"; shift 2 ;;
      --running) running_csv="${2:-}"; shift 2 ;;
      *)         [ -z "$g" ] && g="$1" && shift || die "unexpected arg '$1'" ;;
    esac
  done
  [ -n "$g" ] || die "usage: ready <graph.yaml> --max N [--done a,b] [--running c,d]"
  [ -n "$max" ] || die "ready needs --max N"
  [ -f "$g" ] || die "no graph file at '$g'"
  local records; records="$(_graph_records "$g")"
  printf '%s\n' "$records" | awk -F'\t' -v MAX="$max" -v DONE="$done_csv" -v RUN="$running_csv" '
    function inset(x,csv,   a,n,i){ n=split(csv,a,","); for(i=1;i<=n;i++){ if(a[i]==x) return 1 } return 0 }
    { id=$1; wv[id]=$2+0; deps[id]=$3; exc[id]=$4; order[++N]=id }
    END{
      dn=split(DONE,darr,","); rn=0; for(i=1;i<=split(RUN,rarr,",");i++){ if(rarr[i]!="") rn++ }
      slots = MAX - rn; if(slots<0) slots=0;
      # sort candidate order by (wave asc, id asc) for determinism
      for(a=1;a<=N;a++){ for(b=a+1;b<=N;b++){
        if( wv[order[b]]<wv[order[a]] || (wv[order[b]]==wv[order[a]] && order[b]<order[a]) ){ t=order[a];order[a]=order[b];order[b]=t } }}
      picked="";
      for(k=1;k<=N && slots>0;k++){
        id=order[k];
        if(inset(id,DONE) || inset(id,RUN)) continue;         # already handled
        # every dependency must be done
        ok=1; n=split(deps[id],d,","); if(deps[id]!=""){ for(i=1;i<=n;i++){ if(!inset(d[i],DONE)){ ok=0; break } } }
        if(!ok) continue;
        # not excluded by anything currently running
        n=split(exc[id],e,","); bad=0;
        if(exc[id]!=""){ for(i=1;i<=n;i++){ if(inset(e[i],RUN)){ bad=1; break } } }
        if(bad) continue;
        # not excluded by anything already picked in THIS batch
        if(exc[id]!=""){ for(i=1;i<=n;i++){ if(inset(e[i],picked)){ bad=1; break } } }
        if(bad) continue;
        print id;
        picked = (picked==""? id : picked "," id);
        slots--;
      }
    }'
}

# -----------------------------------------------------------------------------
# dispatch
# -----------------------------------------------------------------------------
cmd="${1:-}"; [ "$#" -gt 0 ] && shift || true
case "$cmd" in
  build)    cmd_build    "$@" ;;
  validate) cmd_validate "$@" ;;
  ready)    cmd_ready    "$@" ;;
  -h|--help|help|"") sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '${cmd}' (try --help)" ;;
esac
