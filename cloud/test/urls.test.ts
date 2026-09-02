import { afterAll, beforeAll, describe, expect, test, vi } from 'vitest'
import { partSigningClient, signPartUrl } from '../handlers/urls'

// Claim 2's second half. The presigner signs offline — it builds a canonical request and an
// HMAC chain out of the credentials it is handed and reaches no network — so these two tests
// run on a machine holding no AWS credential and touching no bucket. What they establish is
// the *shape* of the authority a device is handed. Whether S3 refuses a URL used outside that
// shape is ADR-0006 §4's falsifier 4, and nothing in 4a can ask it.
//
// Obviously-fake, non-AKIA-shaped placeholders. Nothing key-shaped enters this repository, a
// diff, or a secret scanner's output. They live in this file and only here: `signPartUrl`
// takes an already-built client, so `handlers/urls.ts` names no credential and no region of
// its own and reads `BUCKET` and nothing else out of the environment.
//
// The client comes from `handlers/urls.ts` rather than from a second `new S3Client` here. The
// option it sets changes what is in the URL, so a client built two ways would let this file
// assert the shape of a URL the service does not mint.
const client = partSigningClient({
  region: 'us-east-1',
  credentials: { accessKeyId: 'test-access-key-id', secretAccessKey: 'test-secret-access-key' },
})

// A bucket name S3 would accept. The name is load-bearing and was not always: signed against a
// one-character bucket the SDK falls back to path-style addressing and the bucket lands in the
// path, so an assertion on `pathname` alone passes while reading a fallback rather than the
// key. A DNS-compatible name gets virtual-hosted addressing, which is what a deployed bucket
// gets, and the bucket and the key are then asserted in the two places the URL puts them.
const BUCKET = 'dunnage-uploads'
const KEY = 'uploads/sub-1/photo.jpg'

// A fixed signing instant, because SigV4 puts `X-Amz-Date` in the URL and covers it by the
// signature. Two URLs signed either side of a second boundary would differ in the date as well
// as in the part number, and the second test's whole subject is that the part number is what
// differs. A virtual clock rather than a real one is this repository's rule, and a signer is a
// place a wall clock enters unannounced.
beforeAll(() => {
  vi.setSystemTime(new Date('2026-09-01T00:00:00Z'))
})
afterAll(() => {
  vi.useRealTimers()
})

describe('the authority a device is handed for one part', () => {
  // Every property asserted here was read off a URL printed before it was written down, at the
  // pinned `@aws-sdk/s3-request-presigner` 3.1124.0. The HTTP method is not a query parameter —
  // SigV4 covers it in the canonical request and it is not readable back out — so what stands
  // for "one operation" is `x-id`, the SDK's own operation marker, which is signed with the
  // rest.
  //
  // The expiry is asserted as the exact value signed for, not as a bound. The presigner's
  // default is 900 seconds, so `X-Amz-Expires <= 900` is satisfied by a URL signed with no
  // expiry at all — checked by dropping `{ expiresIn }` from `signPartUrl` and watching the
  // bounded form stay green while this one goes red naming 900 against 300.
  //
  // The full set of parameter names is asserted, not only the ones the claim names. That is
  // what makes the absence of a payload binding visible: at the SDK's default checksum setting
  // this URL also carries `x-amz-checksum-crc32` — a CRC32 of the empty body the command was
  // built with — and an authority scoped to one part that must be empty is not the authority
  // the claim describes. `handlers/urls.ts` says why the setting is what it is.
  //
  // One assertion over every property, not one `expect` per property: `expect` throws, so a run
  // in which two of them were wrong would name the first and hide the second.
  test('testAPresignedURLIsScopedToOneMethodOneKeyOnePartAndAShortExpiry', async () => {
    const url = new URL(
      await signPartUrl({
        client,
        bucket: BUCKET,
        key: KEY,
        uploadId: 'u-1',
        partNumber: 2,
        expiresIn: 300,
      }),
    )
    expect({
      host: url.host,
      pathname: url.pathname,
      operation: url.searchParams.get('x-id'),
      signedAt: url.searchParams.get('X-Amz-Date'),
      partNumber: url.searchParams.get('partNumber'),
      uploadId: url.searchParams.get('uploadId'),
      expires: url.searchParams.get('X-Amz-Expires'),
      signedHeaders: url.searchParams.get('X-Amz-SignedHeaders'),
      signature: url.searchParams.get('X-Amz-Signature'),
      parameters: [...url.searchParams.keys()].sort(),
    }).toEqual({
      host: 'dunnage-uploads.s3.us-east-1.amazonaws.com',
      pathname: '/uploads/sub-1/photo.jpg',
      operation: 'UploadPart',
      signedAt: '20260901T000000Z',
      partNumber: '2',
      uploadId: 'u-1',
      expires: '300',
      signedHeaders: 'host',
      signature: expect.stringMatching(/^[0-9a-f]{64}$/),
      parameters: [
        'X-Amz-Algorithm',
        'X-Amz-Content-Sha256',
        'X-Amz-Credential',
        'X-Amz-Date',
        'X-Amz-Expires',
        'X-Amz-Signature',
        'X-Amz-SignedHeaders',
        'partNumber',
        'uploadId',
        'x-id',
      ],
    })
  })

  // Not a cardinality test. Each of the two names its own part, which is what the claim says
  // about every authority the device holds — and what the wording this claim replaced denied.
  //
  // The two calls are written out and differ in exactly one argument, so what the comparison
  // reports is the part number's doing and nothing else's. It asserts the whole set of query
  // parameters that differ rather than the signature alone: two URLs that also differed in the
  // key, or in the uploadId, would satisfy a signature-only assertion while proving something
  // weaker than the claim.
  test('testTwoPartsOfOneUploadAreTwoDifferentSignedRequests', async () => {
    const one = new URL(
      await signPartUrl({
        client,
        bucket: BUCKET,
        key: KEY,
        uploadId: 'u-1',
        partNumber: 1,
        expiresIn: 300,
      }),
    )
    const two = new URL(
      await signPartUrl({
        client,
        bucket: BUCKET,
        key: KEY,
        uploadId: 'u-1',
        partNumber: 2,
        expiresIn: 300,
      }),
    )
    const differing = [...new Set([...one.searchParams.keys(), ...two.searchParams.keys()])]
      .filter(name => one.searchParams.get(name) !== two.searchParams.get(name))
      .sort()
    expect({
      samePath: one.host === two.host && one.pathname === two.pathname,
      differing,
      parts: [one.searchParams.get('partNumber'), two.searchParams.get('partNumber')],
    }).toEqual({
      samePath: true,
      differing: ['X-Amz-Signature', 'partNumber'],
      parts: ['1', '2'],
    })
  })
})
