# ADR-0008 — The document guards, and what each one reads

## Context

Four guards in CI assert things about this repository's own documents and history.
What each reads, and why it reads that rather than the obvious thing, was recorded
only in the commit messages that built them.

## Decision

### 1. The claims guard anchors on a heading's prefix, and counts before it compares

`## Phase N: ` is the contract and everything after the colon is prose, so the anchor
matches the prefix and stops. An anchor over the whole heading makes the wording
load-bearing: rewording one side empties that extraction silently, and two empty
lists diff clean. The count check turns that into a failure, not a silent pass.

### 2. The name guard reconciles one document against every runner's list

The document names every test there is, whichever runner has it, so the comparison
needs every runner's list at once; a guard inside a build job sees only that job's
own. Each build job records the names it has and uploads them, and the guard
downloads them and compares. It therefore trusts a file another job wrote, bounded by
this: the document is not empty, so a list arriving empty or truncated still fails.

Each producer cuts its listing to the column holding the test name before grepping —
the last `/` field for one runner, the last ` > ` field for the other. Reading the
whole line extracts a match from a module, class, path or block spelled like a test
name; the guard then demands the document name a test that does not exist, and the
way to a green build becomes writing a lie into the document it keeps honest.

### 3. Both ends of that comparison are pinned to one collation

`diff` compares lines in order, so one set in two orders is a disagreement. The sides
are produced on different machines, and the guard sorts both itself under `LC_ALL=C`:
an artifact is a set, and its order is not the producer's to guarantee. Each producer
pins its own sort too, for a different reason — `sort -u` deduplicates by collation,
so an unpinned producer decides membership and not merely order, and no re-sorting
downstream recovers a dropped name.

### 4. Identity and trailers are audited over the whole history, field by field

The commit-msg hook cannot be the enforcement layer: rebase, cherry-pick and
`--no-verify` all skip it, and a clone does not install it at all. The hygiene job
runs the classifier over every commit reachable from HEAD, which is why its checkout
fetches the whole history rather than a shallow slice. It classifies trailer forms
instead of grepping the body, because a body naming a vendor is not a claim of
authorship. A second audit reads author and committer identity, which a message
audit cannot see, and reads each field on its own terms — the name for equality, the
address for its domain. A rule wide enough to catch every vendor mention deletes
people.

## What stays unverified

UNVERIFIED: neither runner's locale was read from the runner. Which collation each
side used is inferred from the logs, and sorting under `C` and under `en_US.UTF-8`
reproduces the disagreement hunk for hunk. Nor was a collating collision shown: the
document's names dedupe to the same count under either, so the producer's pin is
against what `sort -u` is defined to do and not against an observed loss.
