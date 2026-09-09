# ADR-0010 — The recorded run, and the account the tree never names

- **Status:** accepted
- **Date:** 2026-09-07
- **Scope:** who issues the bearer token the plane verifies; what the stack tells an operator
  after a deploy; what may not appear in a tracked file; where the contract run lives, what
  gates it, and why its test names never reach `docs/invariants.md`; and what LocalStack is
  allowed to settle. One run is described here and none is performed.
- **Builds on:** ADR-0006 §4, whose six falsifiers this run asks and does not restate; ADR-0006
  §8, whose account-agnosticism §3 below extends rather than revisits; ADR-0007 §9, whose three
  assumptions join those six and whose sentence about a double is the one §6 applies to
  LocalStack.
- **Supersedes:** nothing. Every document it leans on it cites.

## Context

Phase 4b's other half needs an account, and this repository has spent four phases arranging
never to name one. The two are not in tension by accident: a claim CI can check and an
observation about a vendor's product are different kinds of statement, and the whole discipline
here is that neither is allowed to wear the other's clothes.

So the run is described before it is performed, and described in a document rather than in a
suite. What it will ask is already written down — ADR-0006 §4's six falsifiers and ADR-0007
§9's three assumptions — and what remains is who the run authenticates as, what the stack tells
it, what it may write down, and what a green result from it is worth.

## Decision

### 1. Identity: three options, all decidable now, and the one taken

The choice does not wait on the run. Each option is settled by a fact about this tree or about
a construct's rendered output, both of which are checkable with `cdk synth` and no account.
That is worth saying plainly, because a document that lists three options and picks one is a
decision, and one that lists three and defers is an open question with more words.

**A small development issuer, its secret a stack parameter — rejected.**
`HttpJwtAuthorizer` verifies an OIDC issuer's key set and cannot verify a shared secret, so
this replaces it with a Lambda authorizer — and two of 4a's claims are asserted against that
construct. It adds a secret whose only safe home is a deploy-time parameter, and a hand-written
verifier with none of the checks a real one makes. It buys nothing this repository needs.

**A key set the operator supplies — rejected for this run, and named for someone else.**
It removes the user pool that three of 4a's claims read and replaces it with two deploy-time
parameters, so the stack stops describing the identity it verifies, and the run comes to depend
on a provider this repository cannot describe. Behind an existing identity provider it is the
right answer, and naming it here is a statement about scope rather than a deferral.

**The user pool already in the template — taken.** No new secret, no new construct, no claim of
4a's disturbed. One property is added, and §2 is what it makes true.

**One consequence of the choice does wait on the run**, and it is not the choice: whether the
API's authorizer accepts this pool's access token. It is recorded under *What stays unverified*
with what would settle it, and it is kept there rather than here so that a reader does not take
the decision for provisional because a detail downstream of it is open.

### 2. The one property, and what it makes true

The device client passes no authentication flows today, and the construct library renders no
explicit set when none is given, so the template names none and no test reads one. An absent
`ExplicitAuthFlows` is not an empty one: Amazon Cognito's documented default for a client that
names none is `ALLOW_REFRESH_TOKEN_AUTH`, `ALLOW_USER_SRP_AUTH` and `ALLOW_CUSTOM_AUTH`. A user
this pool already holds can therefore sign in with a username and password over SRP at
`InitiateAuth`, an operation that does not accept IAM credentials at all. The template closes
self-service sign-up, so only an administrator can create such a user — but that bounds who
signs in, not what a token costs.

**The decision is to give the client the administrative user-password flow**, which renders
`ALLOW_ADMIN_USER_PASSWORD_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH` and no SRP, and whose
`AdminInitiateAuth` call is IAM-authorized where `InitiateAuth` is not. **Once that set is
rendered, the account's own credentials are the only way to a first token. Until it is, they
are not.** No hosted sign-in surface exists either way. Two tests assert the rendered set
exactly rather than its shape.

The app does not change. A token enters in one place, as it already does: the operator mints
one and pastes it in. It expires within the hour, so a longer run pastes another, and the
procedure says so rather than the app growing a sign-in flow.

### 3. Four outputs, each a reference

Nothing in the template said what a deploy produced, and the procedure needs four values: the
API endpoint, the bucket, the pool, and the client. Four outputs carry them, and **each is a
reference to a resource in this stack rather than a literal**, so the template still names no
environment. The test asserts both halves — that the four exist by name, and that each value is
a reference — because a literal that happened to be right would satisfy the first alone.

### 4. What may not appear in a tracked file, and what the scan does not establish

The phase's whole risk is an operator pasting a value into a document. A test walks the tracked
files for six shapes — an ARN carrying an account, an API endpoint, a pool identifier, an
access key, a bearer token, and a numeric account beside the word that introduces it — and
**collects every match rather than stopping at the first**, so one hit never hides the next.
The shapes are written where the test is; describing them twice would be two things to keep in
step.

**What it does not establish.** It catches shapes, not secrets. It cannot know the bucket name
the deploy generated, and such a name written into prose passes it untouched. The scan is a
floor and not a guarantee, and the discipline above it is the operator's: the procedure
requires a clean tree before the run and a clean tree after, and no value of any kind written
into the tree at any point. The gitignored target file joins the app's local configuration for
the same reason, and CI checks that it is not committed.

### 5. The contract run: its own suite, its gate, and why its names stay out of the document

The run asks the nine questions ADR-0006 §4 and ADR-0007 §9 already wrote down. **They are not
restated here.** Each lives as a named test in its own directory, under its own configuration
and its own script, and the default suite's include pattern does not reach it.

**Why the names never reach `docs/invariants.md`.** A name in that document is a claim CI
reconciles against a suite that ran. These nine are never run by CI — no job holds a credential
and none gains one — so listing them would place nine names beside tests that actually
executed, which is precisely the vacuous green this phase exists to avoid. Their answers go
where a device harness's answers go: an Observed section in the document that asked the
question. A test asserts the two include patterns are disjoint, so a later edit that widened
the default one reds by name rather than quietly enlisting nine tests nobody ran.

**The gate, and what "not run" has to look like.** The target file is absent from every clone.
Without it the run prints all nine questions, marks each as not run for want of a target, and
**exits zero while reporting no passes, no skips and no green count.** A skipped test that
prints as a pass is the failure mode of every gated suite; a test in CI asserts that this one
does not do it, and that test runs with no target on every push.

**And the instrument is shown able to fail.** A wrong authority — one that answers each of the
nine the other way — is pointed at by a second script that expects to fail, and CI asserts a
non-zero exit with all nine names in the output. So the evidence that these tests can go red is
produced on every push rather than once, in a commit message, by someone who saw it.

### 6. LocalStack settles mechanics and nothing else

It may be used while the runner and the procedure are being written, for deploy mechanics and
routing. Nothing is added to the manifest for it and nothing is committed for it; the procedure
names its two commands in an appendix and says what they are for.

Its standing is ADR-0007 §9's sentence about a double, applied to a third party's
reimplementation: *"a green stand-in test says the stand-in behaves as assumed and nothing
about S3."* A green run against LocalStack says LocalStack behaves as assumed. It is further
from an observation about S3 than the stand-in is from an observation about this repository's
contract, because it reimplements a vendor's interface rather than this repository's. **No
answer it gives is written into an Observed section, no claim rests on it, and no CI step runs
it.**

## What this costs

- **A token with an hour on it, pasted by hand.** The operator re-pastes for a longer run. The
  alternative is a sign-in flow in an app whose thesis has nothing to do with sign-in.
- **The scan is a floor.** §4. A value in prose passes it, and only the operator's discipline
  catches that.
- **Nine tests nobody runs by default.** They can rot: nothing compiles them on a push except
  the disjointness test and the wrong-authority step, and neither type-checks the questions
  against a real client. That is the price of not pretending CI asks them.
- **One deploy, one operator, one machine.** Nothing here is reproducible by a reader without
  an account, which is why every answer lands in an Observed section attributed to a run rather
  than in a claim.

## The honesty boundary

Nothing in this document is evidence about S3 or about a deployed plane. It decides who
authenticates, what the stack reports, what may be written down, and what a result is worth. It
establishes no answer to any of the nine questions, and a reader who wants those must read an
Observed section that a run has filled — not this one, which is empty.

## Deliberately not decided

- **Any identity beyond one operator's.** No roles, no per-device principals, no sign-in. The
  run needs one authenticated caller and this repository does not need a second.
- **Re-running the nine on a schedule.** They are an observation, not a monitor. A cadence
  would make them a claim, and the moment they are a claim they need a credential in CI.
- **What to do if a question answers unexpectedly.** The answer is recorded and the
  consequence decided then, in the document that asked it. Deciding the response in advance
  would be guessing at an observation this phase has not made.

## What stays unverified

**UNVERIFIED: whether the API's token authorizer accepts an access token from this pool** by
matching the claim that carries the client identifier against the configured audience. It is
documented behaviour of the service and no account was touched, so it is documented behaviour
and not an observation.

*What would settle it:* step 4 of the procedure mints an access token with the administrative
initiate-authentication call and makes one authenticated request with it. **A 2xx settles it
accepted; a 401 settles it refused.** The identity token — whose audience claim is the client
identifier, and which carries the same subject — is the named fallback, so a refusal is a step
in the procedure rather than a surprise during it. Whichever token the plane accepts is written
into the Observed section by name.

**UNVERIFIED: the shape of the error S3 raises for a mismatched key and upload identifier.**
The handlers read a particular error name and turn it into a refusal the transport reads as a
lost operation; nothing has confirmed that S3 raises that name.

*What would settle it:* contract questions 1 and 8 — a part listing for an upload identifier
that belongs under another key, and the deployed plane's answer for the same — **recording the
error's name and code verbatim rather than whether they matched.** Recording the value rather
than the verdict is what makes the record survive an unexpected answer. If the name differs,
the correction is one function and one commit, which is why the reading was written before the
run: it makes the run a check rather than an exploration.

**UNVERIFIED: that a client refuses an authentication flow its `ExplicitAuthFlows` does not
name.** The property is documented as the flows you want the client to support, and both
authentication operations can raise `UnsupportedOperationException` for an operation "not
enabled for the user pool client" — but no page joins those into one statement, and §2's
second paragraph rests on the join.

*What would settle it:* one `InitiateAuth` call with `USER_SRP_AUTH` against a deployed client
whose `ExplicitAuthFlows` names only the administrative flow and refresh, **recording the
error's name and code verbatim rather than whether the call was refused.**

## Observed against a deployed plane

Nothing yet. `docs/deploy.md` says what is recorded here and how.
