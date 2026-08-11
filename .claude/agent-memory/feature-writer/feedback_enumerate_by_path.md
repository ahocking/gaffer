---
name: enumerate-by-path-not-description
description: When an acceptance criterion spans multiple artefacts, enumerate every one by path and verify the count on disk — descriptions make short lists read as complete
metadata:
  type: feedback
---

## Enumerate multi-artefact criteria by path, and count them on disk before writing the number

- target: gspec-product
- layer: skill
- trigger: "QA: capability heading said 'in every place that states it' but the criterion named only two of four places carrying the wrong claim; the two omitted were a runtime config file and the parent PRD's own prose"
- lesson: When a capability is *"fix X everywhere it appears"*, the criterion must list every occurrence **by file path**, discovered by grepping for the claim — not by descriptive noun phrase ("the standing repo instructions", "the packet template"). A description names an artefact the writer happens to be holding in context; a path list is checkable. Prose descriptions make a partial enumeration read as complete to both the writer and the planner, and the missing copy is then free to re-derive the error the capability just corrected.

**Why:** A "correct it everywhere" capability's whole value is exhaustiveness. If one uncorrected copy survives, someone re-derives the wrong model from it and the packet reads as done. The two occurrences that were missed were exactly the ones not already open in context.

**How to apply:**
- Any criterion containing *every / all / both / in each place* → grep the claim's distinctive wording across the repo first, then write the enumeration from the grep result, paths inline.
- Prefer `path` + a durable in-file locator (a field name, a section) over line numbers, which rot.
- Include **specs** in the sweep, not just code and config. A sibling or parent PRD restating the wrong fact is usually its most quotable copy.
- If a listed artefact is a *completed* feature's PRD, decide and **state in one clause** whether it is in scope. Correcting **prose** in a checked PRD alters no capability checkbox and no checked task, so it is normally safe and should be in scope — but say so explicitly, or planning silently drops it as "that feature is done".

Related: [[verifiable-claims-in-criteria]]
