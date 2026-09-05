# The device harness

ADR-0007 §2's third tier: a numbered procedure a person runs on a real iPhone against the
stand-in, and writes down. Writing the procedure is not running it. This file asserts nothing
about a device this repository has not seen, and ADR-0007's "Observed on a device" reads
"Nothing yet" until someone runs these steps and records what they saw there.

## The line between the tiers

| | shows | where it lives |
|---|---|---|
| tier 2 | a real kill of a process on the simulator, a second process deriving its state from the log, and nothing re-sent that the authority confirmed | `testAfterTheSimulatorTerminatedTheAppMidTransferTheRelaunchResendsNothingTheAuthorityConfirmed`, and the control beside it |
| tier 3 | suspension, jetsam, force-quit, radio and power — none of which a simulator reaches | this document, recorded into ADR-0007 |

What tier 3 records and tier 2 cannot, one line each, each naming its open question:

- **O-13** — whether `timeoutIntervalForResource` counts while the app is suspended. The
  number (`partTransferLifetime`, 900 s) is right either way; what it bounds differs.
- **O-14** — which signal the kill delivers, and whether the daemon keeps or cancels a killed
  app's tasks. The `last-exit` marker is evidence only when present: a process killed before
  the hook ran and a hook that never ran leave the same missing file, so its absence says
  nothing, and no step here writes SIGKILL against an observation.
- **O-15** — whether the daemon can read a security-scoped URL after relaunch, or copies the
  file itself. Nothing in the repository rests on either answer.

**What this document does not claim.** It establishes no invariant, adds no test and no claim
to `docs/invariants.md` or `README.md`, and no CI step depends on it or reads it. The table
above is the only place a tier-2 test name appears here; where a step below needs the evidence
CI already holds, it says "claim 4's test, cited above" rather than restating what that test
proves.

## Why the hold is `before-store` here, and never in CI

Spec §3.3 gives `hold` two modes, and CI uses one of them. `after-store` stores the bytes
first, so `GET /uploads/{ref}/parts` reports the part while its answer is still outstanding;
that is how tier 2 makes a kill land mid-transfer without a sleep, and it is deliberately the
easier case — the authority is already holding the part before anything dies. `before-store`
reads the body, stores nothing, and answers only on release, so a kill lands with bytes in
flight and nothing stored. Whether the daemon finishes that PUT for a killed app is the
unverified fact (O-14). That is why the mode exists, why no CI assertion uses it, and why it
is step 1's instrument rather than a convenience.

## A run that falsifies the claim

If a step shows a part re-sent that the authority had already confirmed, that is the phase's
claim failing on a device, and it is the outcome "Observed on a device" exists to be able to
hold. Record it with the same template as any other run, and with the stand-in's counter for
that part — the number, not a characterisation — never omitted, and never explained inside the
record. It then opens an open question in ADR-0007 under the next number, **O-18**, where the
reasoning belongs. Neither this document nor the claim it contradicts is edited to make the
run fit: a procedure that only knows how to record success is not a third tier.

## Where a record goes

ADR-0007's "Observed on a device" is the only in-tree record. Spec §9 also names the phase
ledger; the ledger is workspace and is not in the tree, so a run recorded only there is a run
this repository does not have. One template, copied in filled:

```
### <ISO date>, iPhone <model>, iOS <version>
Build: Debug, signed with a team supplied locally. Stand-in at <commit>, bound 0.0.0.0.
Step <n> (<O-number>): <field>: <value>; <field>: <value>
Does not establish: <the step's own line, kept>
```

Fields are observations and nothing else. **No name, employer, Apple ID, team identifier,
device name or UDID, LAN address or home path is ever written into the tree.** The model and
the iOS version are what make one run comparable with another; the rest is not.

## Setup

**A team, in a file the tree never gains.** A device build needs a `DEVELOPMENT_TEAM` and this
repository refuses to commit one. Create `App/Local.xcconfig` — gitignored, and
`App/Shared.xcconfig` already `#include?`s it — holding `DEVELOPMENT_TEAM = <the operator's
own>` and nothing else. Run `git status` before the run and again after it, and see a clean
tree both times. The CI guard is unchanged and is not a thing to work around: the app-simulator
job still fails on a non-empty team in a committed file and on `Local.xcconfig` being
committed, which is why the include is optional rather than an inconvenience.

**The network.** Mac and phone on one network. Build the bundle and start the stand-in on the
Mac, bound wide (spec §3.4), and note the commit it was built at:

```
npm --prefix cloud run build
node cloud/dist/standin.js --bind 0.0.0.0 --port <p>
```

Type `http://<the Mac's address>:<p>` into the app's `base URL` field and any non-empty string
into `token`. The token is the `Bearer` principal the object key is derived from, so the same
string has to be used for every request in one run — the app's and the operator's `curl`s
alike. `App/Dunnage-Info.plist` already carries `NSAllowsLocalNetworking`, so ATS is not the
operator's problem; iOS may still ask for permission to find devices on the local network, and
whether it asked is a line in the record.

**Run the app from the Home screen, with the debugger detached.** An app under Xcode is not an
app the system suspends or ends, and an observation made under the debugger is an observation
about a different process.

**Reading the counters, from the Mac.** `GET /_standin/uploads` lists every upload the stand-in
has seen as `{uploadId, key}`, where the key is `uploads/<token>/<ref>` and the ref is the
UUID the app minted. Then, for one upload:

```
curl -s http://127.0.0.1:<p>/_standin/uploads/<uploadId>
curl -s -H "Authorization: Bearer <token>" \
     "http://127.0.0.1:<p>/uploads/<ref>/parts?uploadId=<uploadId>"
curl -s -X POST http://127.0.0.1:<p>/_standin/hold    -d '{"part":3,"mode":"before-store"}'
curl -s -X POST http://127.0.0.1:<p>/_standin/release -d '{"part":3}'
```

`puts` counts receipts per part, so a re-send is a number and never an inference. Under
`before-store` a part's receipt is counted on release and not on arrival, so a count of 1 after
release says the whole body had arrived; it does not say the answer reached the app.

**One reading, and its limit.** A `puts` count that rises while the phone is untouched is not
evidence that the app's process ran: the daemon can finish a task the previous process created.
A `completes` count that rises is, because `POST /uploads/{ref}/complete` goes over the app's
own foreground session and only a running process makes it.

**One datum that is nobody's step.** Record, in one line, whether the team-signed device
build's part tasks run at all. That is a datum for O-16 and is not what any step below is for.

**The payload.** The sample is four chunks of 64 KiB and exists only in a Debug build; a picked
file is step 4's.

## Step 1 — Background, then a kill by the system

### Purpose

O-14, and O-13's suspension half: what the system does to a suspended app's held transfer, and
what the daemon does with its tasks once the app is gone.

### Do

Hold part 3 `before-store`. Start the upload from the sample, background the app, lock the
phone, and leave it untouched for **thirty minutes** — a convention, chosen so that two runs
compare, and a field in the record so a longer wait can say so. Watch the counters from the
Mac, not from the phone: foregrounding is a thing that changes what is being measured. Do not
force the kill by loading the device; an operator who does has run a different thing, and says
so in the record.

Then release part 3 and read the counter before foregrounding, so the question "did the daemon
still have that socket" is answered without the operator's own foregrounding having supplied
the answer. Foreground the app last, and read the screen.

### Record

Whether the held PUT was finished, as the stand-in's counter for part 3 after the release;
whether the app was relaunched for the event before the operator foregrounded it, and by which
reading above; the value of `last exit` on the screen — present is evidence, absent is not, and
absent is never read as a signal; the `phase` row and the per-chunk rows; what
`GET /uploads/{ref}/parts` reports afterwards; and the elapsed time from backgrounding.

If the process was not ended inside the window, the run is still a record. Write the elapsed
time, whether the held transfer progressed while the app was suspended — O-13's suspension
half, which is observed either way — and that **O-14's kill half was not reached in this run**.

### What this step does not establish

Which signal the system delivered, unless something other than the marker's absence says so;
that a kill will happen again on another device or another day; and nothing at all about
force-quit, which is step 2's, or about the radio, which is step 3's.

## Step 2 — Force-quit

### Purpose

O-14, on the half a user causes: what iOS does with a force-quit app's background tasks.

### Do

The same as step 1 — part 3 held `before-store`, the upload started, the app backgrounded —
with the operator swiping the app away in the app switcher instead of waiting for the system.
Release part 3 before foregrounding, as in step 1.

### Record

Every field step 1 records, and one more: whether iOS relaunched the app for the event at all
afterwards, over whatever period the operator waited, with that period written down.

This step is what would give `FailureReason.userForceQuit` a meaning. Nothing in this phase
appends that reason, and nothing here proposes that it should; the observation is what a later
decision would rest on.

### What this step does not establish

That the system's own kill behaves the way a force-quit does — that is step 1's question and
they are not the same event — and no change to Core, which still appends no `userForceQuit`.

## Step 3 — Airplane mode mid-transfer

### Purpose

O-13: whether a task ends at `partTransferLifetime` and what the next `send` does when it does.

### Do

Two runs, with no hold in either.

First: start the upload, turn the radio off during a transfer, and turn it on again well
inside the bound.

Second: start the upload, turn the radio off during a transfer, and leave it off past
`partTransferLifetime` — 900 s, so this run costs a quarter of an hour of waiting, and the
operator should expect to spend it. **Keep the app in the foreground for that quarter of an
hour, and record that it was kept there**: the suspended-time half of O-13 is step 1's
question, and a run that mixes the two answers neither.

### Record

For the first run: whether the task resumed, and whether it completed.

For the second: whether the task ended at the bound, with what error the app's `note` row
shows, and what the next `send` did — whether it created a new task and minted a URL at that
send. Record that the app was kept in the foreground throughout.

### What this step does not establish

What `timeoutIntervalForResource` does while the app is suspended. This step deliberately keeps
the app foregrounded, so it answers the foreground half of O-13 and nothing else.

## Step 4 — The scoped-URL assumption

### Purpose

O-15: whether anything after a relaunch needs the picker's security-scoped URL, or only the
copy `PayloadRef` names.

### Do

Pick a real file with the picker rather than using the sample. Start the upload, hold a part
`before-store` so a kill lands mid-transfer, let the app be ended, and relaunch it.

### Record

Whether the bytes the authority ends up holding are the copy in the container, and whether
anything needed the picker's URL after the relaunch — an error naming the scoped URL, a chunk
that could not be read, or neither.

### What this step does not establish

Whether the daemon *could* have read a scoped URL. The app never gives it one, so a run in
which nothing needed it is consistent with both answers, and the question stays open.
