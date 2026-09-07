import type { APIGatewayProxyEventV2WithJWTAuthorizer } from 'aws-lambda'

// A reference names one leaf inside the caller's own prefix. The separator is excluded
// deliberately and not incidentally: a TransportSessionID is `<ref> "/" <uploadId>`, and
// `parseSession` in Swift splits it on the first '/'. That parse is total only because no
// ref this server accepts can contain one. See ADR-0006 §2 and
// `testARefContainingASeparatorIsRefused`, which is the only thing that enforces it.
const REF = /^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$/

export function validateRef(ref: string): boolean {
  return REF.test(ref)
}

// The key is composed from the verified principal and the reference, in that order, and
// from nothing else. There is no third parameter, so there is no parameter a request body
// could arrive through: the claim is made in the signature rather than defended by a check
// inside the body, because a check can be omitted at one of four call sites and a parameter
// that does not exist cannot be passed at any of them. `sub` first, so one caller's prefix
// can never be reached from another caller's reference — claim 4's grammar is what keeps a
// reference inside the prefix this composes.
export function objectKey(sub: string, ref: string): string {
  return `uploads/${sub}/${ref}`
}

// The one place a principal enters this service. Everything else a request carries is data:
// a body naming a `key`, a `sub` or a `userId` reaches no function that composes a key.
// ADR-0006 §9 records this as a supersession of the 4a spec's §5, which lists two functions
// in this file — the path §5 makes its claim about has to live somewhere, and four copies
// in four handlers is four places to get it wrong.
//
// The optional chaining is not defensive habit. The event type asserts an authorizer is
// present, and only a deployed route's configuration makes that true; an event that arrives
// without one is refused by the caller rather than throwing here, and a claim that is
// present but not a non-empty string is absent for this purpose. There is no default and no
// empty prefix to fall back to.
export function verifiedSub(event: APIGatewayProxyEventV2WithJWTAuthorizer): string | undefined {
  const sub = event.requestContext?.authorizer?.jwt?.claims?.sub
  return typeof sub === 'string' && sub.length > 0 ? sub : undefined
}

// The one reading of "the authority has no record of this operation", in one place because two
// handlers need it and a second copy is a second thing to get wrong — the same argument
// `objectKey` above is here for.
//
// It reads a shape and never a client. ADR-0006 §4 forbids a double of a vendor's product, so
// what is asserted about this function is asserted over hand-made objects, which is exactly why
// it can be established with no account and no credential.
//
// Both `name` and `Code` are read: the v3 client sets `name`, and an older or wrapped error
// carries `Code`. Equality and not a substring — an error whose name merely contains the token
// is a different error, and reading it as this one would turn an unrelated refusal into a
// forgotten operation.
//
// **What this does not establish:** that S3 raises this name for a mismatched key and upload
// identifier. That is ADR-0010's second UNVERIFIED, and only the recorded run settles it. This
// function is the middle of three links, and it is the only one that can be established here.
export function forgottenOperation(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false
  const { name, Code } = error as { name?: unknown; Code?: unknown }
  return name === 'NoSuchUpload' || Code === 'NoSuchUpload'
}
