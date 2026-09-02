import { S3Client, UploadPartCommand } from '@aws-sdk/client-s3'
import type { S3ClientConfig } from '@aws-sdk/client-s3'
import { getSignedUrl } from '@aws-sdk/s3-request-presigner'
import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyStructuredResultV2 } from 'aws-lambda'
import { objectKey, validateRef, verifiedSub } from './identity'

// `POST /uploads/{ref}/urls {uploadId, parts}` — ADR-0006 §4. The reference is in the path
// here, unlike `create`, which reads it from the body because no object exists yet to name in
// a path.
//
// Fifteen minutes. The claim's own word is "expires", and this is the number behind it: the
// authority a device holds for one part dies on its own, and a device that has not finished a
// part by then asks for another URL rather than holding a longer-lived one. This constant
// carries no test — a test that passed it back to itself would assert nothing — while
// `testAPresignedURLIsScopedToOneMethodOneKeyOnePartAndAShortExpiry` signs with an expiry of
// its own and asserts that exact value comes back. It has to be the exact value: the
// presigner's default is 900, so an assertion that the URL merely expires within 900 seconds
// is satisfied by a URL that was signed with no expiry at all.
const EXPIRES_IN_SECONDS = 900

// S3's part numbers run 1 through 10000, so an unbounded count is a request to sign an
// arbitrary number of URLs.
const MAX_PART_NUMBER = 10_000

// The client this service signs with, and the one `test/urls.test.ts` signs with. It is a
// function rather than two `new S3Client` calls because the option below changes the *shape*
// of the URL: a test that signed with a differently-configured client would be asserting the
// shape of a URL this service does not mint, and nothing else in the repository would see the
// two drift apart.
//
// `requestChecksumCalculation: 'WHEN_REQUIRED'` is the whole reason it exists. Left at the
// SDK's default of `WHEN_SUPPORTED`, presigning an `UploadPartCommand` computes CRC32 over the
// body the command was given — and this service is given no body at all — then hoists
// `x-amz-checksum-crc32=AAAAAA==` and `x-amz-sdk-checksum-algorithm=CRC32` into the query
// string and signs them. `AAAAAA==` is the CRC32 of zero bytes. Every part a device actually
// sends is not zero bytes, so that is a signed statement about a payload this service has
// never seen and knows to be wrong. Declining to make it is the conservative act; whether S3
// would have enforced it is a question no test in 4a can ask, and it is recorded in the commit
// body as one more thing 4b's contract run settles.
export function partSigningClient(config: S3ClientConfig = {}): S3Client {
  return new S3Client({ ...config, requestChecksumCalculation: 'WHEN_REQUIRED' })
}

// One signed request, for one part of one operation on one key. It takes an already-built
// client rather than a region and a credential pair: the handler builds one through
// `partSigningClient()` and resolves both through the SDK's own chain, so nothing under
// `handlers/` names a credential, a region, or any environment variable but `BUCKET` — which
// is what `testEveryHandlerFunctionIsHandedTheBucketUnderTheNameItsHandlerReads` asserts as an
// exact set. The fake credentials the tests sign with therefore live in the test file and only
// there, and the presigner still signs offline: it builds a canonical request and an HMAC
// chain and reaches no network.
//
// `bucket` is `string | undefined` because `process.env.BUCKET` is, and the other three
// handlers hand it to their commands exactly as it comes. A default here would invent a bucket
// name; a cast would assert something this file cannot know.
export async function signPartUrl(args: {
  client: S3Client
  bucket: string | undefined
  key: string
  uploadId: string
  partNumber: number
  expiresIn: number
}): Promise<string> {
  return getSignedUrl(
    args.client,
    new UploadPartCommand({
      Bucket: args.bucket,
      Key: args.key,
      UploadId: args.uploadId,
      PartNumber: args.partNumber,
    }),
    { expiresIn: args.expiresIn },
  )
}

// The order below is the substance of this handler, not its preamble. The principal, then the
// grammar, then the key, then S3 — the same order the other three take — and the two refusals
// return before any client is constructed, which is what makes them answerable on a machine
// with no credential and no bucket.
export async function handler(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
): Promise<APIGatewayProxyStructuredResultV2> {
  const sub = verifiedSub(event)
  if (sub === undefined) return { statusCode: 401, body: JSON.stringify({ error: 'unauthenticated' }) }

  const ref = event.pathParameters?.ref
  if (typeof ref !== 'string' || !validateRef(ref)) {
    return { statusCode: 400, body: JSON.stringify({ error: 'invalid reference' }) }
  }

  let body: { uploadId?: unknown; parts?: unknown }
  try {
    body = JSON.parse(event.body ?? '{}') as { uploadId?: unknown; parts?: unknown }
  } catch {
    body = {}
  }
  // Refused rather than handed to the signer as nothing. This guard carries no test of its
  // own: it belongs to no claim in this phase, exactly as the `uploadId` guards in `parts.ts`
  // and `complete.ts` do not.
  const uploadId = body.uploadId
  if (typeof uploadId !== 'string' || uploadId.length === 0) {
    return { statusCode: 400, body: JSON.stringify({ error: 'missing uploadId' }) }
  }

  // `parts` is a count, not a list of part numbers. ADR-0006 §4 does not say which, and
  // `create.ts` — whose route takes the same field name — already reads it as one: "the part
  // count is what the caller will ask `POST /uploads/{ref}/urls` to sign". Two readings of one
  // field name across two routes would be the drift this repository refuses, so this is the
  // reading, and it is stated here rather than inferred from a test.
  //
  // Out of range is a 400 and not a clamp. S3's part numbers run 1 through 10000, so an
  // unbounded count is a request to sign an arbitrary number of URLs, and a clamped one would
  // hand back fewer authorities than the caller asked for without saying so. Like the guard
  // above it carries no test: it belongs to no claim in this phase.
  const parts = body.parts
  if (typeof parts !== 'number' || !Number.isInteger(parts) || parts < 1 || parts > MAX_PART_NUMBER) {
    return { statusCode: 400, body: JSON.stringify({ error: 'invalid part count' }) }
  }

  const key = objectKey(sub, ref)
  // Built here and not at module scope: a client built when this file is imported is built
  // before either refusal above has run.
  const client = partSigningClient()
  const urls = await Promise.all(
    Array.from({ length: parts }, (_unused, index) => index + 1).map(async partNumber => ({
      partNumber,
      url: await signPartUrl({
        client,
        bucket: process.env.BUCKET,
        key,
        uploadId,
        partNumber,
        expiresIn: EXPIRES_IN_SECONDS,
      }),
    })),
  )
  // Each URL is returned beside the part number it is for. The device is handed no key, no
  // uploadId it did not send, and no authority that outlives the expiry above.
  return { statusCode: 200, body: JSON.stringify({ urls }) }
}
