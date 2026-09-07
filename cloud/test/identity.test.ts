import { describe, expect, test } from 'vitest'
import { forgottenOperation, objectKey, validateRef } from '../handlers/identity'

describe('validateRef', () => {
  // One assertion over every case, not an assertion inside a loop. `expect` throws, so a
  // loop reports the first failure and hides the seven behind it — and this red is the
  // evidence for the commit. Filtering names every ref that misbehaved, in one diff.
  // Every one of them is refused, and there is no repaired form to return: sanitising maps
  // two distinct refs onto one key, so two uploads become one object.
  test('testARefThatIsNotALeafInTheCallersOwnPrefixIsRefusedRatherThanRepaired', () => {
    const refs = ['../', '..', '%2e%2e', 'a/b', '/a', '.hidden', '', 'x'.repeat(65)]
    expect(refs.filter(ref => validateRef(ref))).toEqual([])
  })

  // The rule this asserts is ADR-0006 §2, not a property of the regex it happens to be
  // written next to. `parseSession` in 4b splits a TransportSessionID on the first '/',
  // and that parse is total only because a ref can never contain one. Swift, another
  // suite, another phase: nothing but this test connects them.
  test('testARefContainingASeparatorIsRefused', () => {
    expect(['a/b', 'a/', '/', 'a/b/c'].filter(ref => validateRef(ref))).toEqual([])
  })

  test('testARefAtTheGrammarsBoundariesIsAccepted', () => {
    const refs = ['a', '0', 'x'.repeat(64), 'a.b_c-1']
    expect(refs.filter(ref => !validateRef(ref))).toEqual([])
  })
})

describe('objectKey', () => {
  // Two parameters, and the claim is what is absent from them. There is no third parameter
  // a request body could arrive through, so the key cannot be composed out of anything the
  // client chose except the reference — which claim 4's grammar has already refused if it
  // is not a leaf in this caller's own prefix.
  test('testTheObjectKeyIsDerivedFromTheVerifiedPrincipalAndTheRefAlone', () => {
    expect(objectKey('sub-1', 'photo.jpg')).toBe('uploads/sub-1/photo.jpg')
  })
})

describe('forgottenOperation', () => {
  // ADR-0009 §4 and ADR-0010's second UNVERIFIED. This is the middle link of three: S3 raises
  // something for a mismatched key and upload identifier (UNVERIFIED, the recorded run's), the
  // plane maps an error of the shape read here to a 404 (this function), and the transport
  // reads that 404 as `TransportError.unknownSession` (already in the tree).
  //
  // **It is not a stubbed `S3Client`.** ADR-0006 §4 forbids doubling a vendor's product, so
  // this is our own reading over our own fixtures — which is exactly why it can be established
  // with no account and no credential.
  test('testAnOperationTheAuthorityForgotIsRenderedAsARefusalTheTransportReads', () => {
    // Both shapes the SDK is documented to use, and each on its own: a v3 error carries `name`,
    // and an older or wrapped one carries `Code`. Every case is collected and asserted over, so
    // one shape failing never hides the next.
    const forgotten: ReadonlyArray<readonly [string, unknown]> = [
      ['an error whose name is the one read', { name: 'NoSuchUpload' }],
      ['an error whose Code is the one read', { Code: 'NoSuchUpload' }],
      ['both, as a real client sends', { name: 'NoSuchUpload', Code: 'NoSuchUpload', $metadata: {} }],
    ]
    const other: ReadonlyArray<readonly [string, unknown]> = [
      ['a different refusal', { name: 'AccessDenied' }],
      ['a different refusal by Code', { Code: 'NoSuchKey' }],
      ['a name that merely contains it', { name: 'NotNoSuchUploadEither' }],
      ['nothing at all', undefined],
      ['null', null],
      ['a string', 'NoSuchUpload'],
      ['an object with no name and no Code', { $metadata: {} }],
    ]

    const missed = forgotten.filter(([, e]) => !forgottenOperation(e)).map(([what]) => what)
    const overreached = other.filter(([, e]) => forgottenOperation(e)).map(([what]) => what)

    expect({ missed, overreached }).toEqual({ missed: [], overreached: [] })
  })
})
