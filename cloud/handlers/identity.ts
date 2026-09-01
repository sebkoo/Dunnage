// A reference names one leaf inside the caller's own prefix. The separator is excluded
// deliberately and not incidentally: a TransportSessionID is `<ref> "/" <uploadId>`, and
// `parseSession` in Swift splits it on the first '/'. That parse is total only because no
// ref this server accepts can contain one. See ADR-0006 §2 and
// `testARefContainingASeparatorIsRefused`, which is the only thing that enforces it.
const REF = /^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$/

export function validateRef(ref: string): boolean {
  return REF.test(ref)
}
