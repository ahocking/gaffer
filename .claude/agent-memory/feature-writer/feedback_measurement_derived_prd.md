---
name: measurement-derived-prd-evidence
description: In a PRD built from one measurement run, apply the contamination test to every capability, and attack a decision record's actual basis rather than an adjacent figure
metadata:
  type: feedback
---

## When a PRD's evidence is one measured run, no capability gets to borrow another's defect

- target: gspec-product
- layer: skill
- trigger: "QA: a P0 defect contaminated the run's wall clock; the PRD said so in its ordering rule, then two other capabilities cited that same contaminated wall clock as their own evidence. Also: the case against an ADR argued wall clock at a crossover the ADR derived purely from tokens."
- lesson: A PRD whose capabilities all draw on **one** measurement run will usually contain a capability describing a defect that *contaminates the run itself*. The moment you write an ordering rule of the form "fix A first, because A contaminates the measurement," you have committed to auditing **every other capability's numbers against A** — including the ones that look unrelated. The failure is invisible when the borrowed number is directionally right: a 22.7x spread and a 2.5x spread both say "this varies too much", so the wrong one survives review on plausibility. Test it arithmetically: pull the contaminating dimension out and see whether the effect survives (here, the two packets with zero polling calls were simply the two shortest — the spread *was* the defect). Keep the capability if the question is real; re-source its evidence to a dimension the defect cannot touch, and state plainly that it is pending re-measurement.

**Why:** A PRD that names a contamination and then relies on it is self-refuting, and the borrowed evidence propagates into the plan as a target derived from a number nobody will be able to reproduce.

**How to apply:**
- **Contamination audit.** For every capability, ask: is this figure downstream of a defect another capability describes? Prefer a dimension the defect cannot reach (a *wall span* over *summed tool duration*; a per-turn payload shape over an aggregate share).
- **Arguing against a decision record, read it first and attack its actual input.** A threshold derived from tokens is not unseated by a wall-clock argument, however contaminated the wall clock is — the wall-clock row was never an input. Find the path that genuinely reaches the conclusion (here: the contaminating work ran *inside* the very context whose token cost was the headline evidence). And a measurement that cannot observe the regime a decision rests on cannot license the strong outcome: a 6-packet single-arm run may license "re-measure", never "the mechanism is never worth it". Say which outcomes the re-measurement is licensed to record, and **name the arms and the size** it must span.
- **Re-derive every percentage from the raw pair before writing it.** A share of the wrong denominator (duration vs cache, attributed tool calls vs Bash calls) reads as authoritative and is unfalsifiable to a reader who has only the PRD. Where the measurement framework designates a *specific* measure for the question being asked, cite that one — the designated measure is usually sharper than the share, and using the share instead invites exactly this error.
- **Report the whole flagged set, or say what you excluded and why.** Dropping the flags that do not fit the narrative is the same defect one level up — and the dropped one is often the sharpest (here, the flag that literally restated the capability's own outcome).

Related: [[verifiable-claims-in-criteria]], [[enumerate-by-path-not-description]]
