---
name: verifiable-claims-in-criteria
description: An acceptance criterion asserting a past failure must cite the id/commit a reviewer can check; a criterion already true today is not a criterion
metadata:
  type: feedback
---

## Cite the id behind a historical claim, and delete any criterion that is already satisfied

- target: gspec-product
- layer: skill
- trigger: "QA: 'it happened once during the parent's own run' was unverifiable from the named finding files; and another criterion described behaviour the target file already implemented"
- lesson: Two distinct defects in acceptance criteria, both caught by reading the artefacts instead of trusting the brief. (1) A criterion that leans on a past incident to justify its priority must carry the **packet id / commit / file** that evidences it — otherwise the load-bearing fact is unverifiable and a reviewer must either take it on faith or drop it. If the evidence is too long to cite, move the claim into the feature prose as motivation and leave the criterion observable. (2) A criterion that is **already true on disk** cannot be a criterion — it is satisfied at the moment of writing, so it can never distinguish done from not-done. Grep the instruction/behaviour before asserting it is missing.

**Why:** Criteria are the completion contract. An unverifiable one invites a checkbox flipped on faith; an already-true one gets flipped for free and pads the count while testing nothing.

**How to apply:**
- Writing *"this happened / this failed once / this was observed"* → attach the id, or move it to prose.
- Writing *"the system is instructed to X"* → grep for X first. If the instruction exists, the real gap is elsewhere (usually an *interaction* between two correct rules), and the prose should say that instead.
- Removing a criterion this way is fine — 2 is the floor, not 4. Three observable criteria beat four with one dead.
- Citing an **evidence artefact by path** is only a re-derivability promise if the path is *tracked*. Check it against `.gitignore` before writing it into a spec — bookkeeping directories are routinely ignored, and an ignored path makes the promise unkeepable for every reader but the author. Same test for a quote pulled from the current session's transcript: it is not in the repo, so mark it as transcript-only corroboration rather than letting it read as a derivable fact.
- An outcome bullet must name something **observable** even when its destination is deferred. *"…reaches a place where someone will act on it"* is unfalsifiable; *"no run ends with a flag that appears in nothing the human reads"* is testable and still leaves the surface open.

Related: [[enumerate-by-path-not-description]], [[measurement-derived-prd-evidence]]
