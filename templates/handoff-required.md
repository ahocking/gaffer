## REQUIRED — the verification contract

Each line below that applies to this packet is one of its acceptance
criteria, with the same standing as the criteria stated above. A line that
does not apply is passed over, never waived.

REQUIRED mutation-verification: when this packet adds or changes a test case, verify the case by mutation — break the behaviour it covers, run the tests, restore the behaviour, run them again — and state both observed counts together with the wrong implementation the case rules out. A case never observed to fail has not been shown to test anything.

REQUIRED unmeasured: a value that was not measured is reported as unmeasured — never as zero, as empty, or as a default that reads like a measurement — and a check that did not run is reported as not run. An unmeasured quantity rendered as a measured one is the defect this line exists to catch.

REQUIRED real-interface: a claim about anything this packet did not itself change — what a command prints, what a payload carries, how another component behaves — is verified against the real thing, by running it or by reading it as it now stands, and never against its documentation, its comment, or what it is expected to do.

REQUIRED report-the-limitation: where something asked for cannot be verified within this packet's scope, report the limitation plainly and say what would be needed to verify it. A stated limitation is a pass; an approximation presented as a result, or a criterion left silently unaddressed, is not.

REQUIRED current-file: when this packet depends on something earlier work may already have changed, read that thing as it now stands before relying on it — not your memory of it, not an earlier quotation of it, and not a summary of it.

REQUIRED second-run: after the change, run again the same search, check or command that found the work to be done, and report what that second run finds. One fixed instance is not the whole class, and only the second run tells them apart.
