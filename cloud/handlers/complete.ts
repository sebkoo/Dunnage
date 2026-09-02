import { CompleteMultipartUploadCommand, ListPartsCommand, S3Client } from '@aws-sdk/client-s3'
import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyStructuredResultV2 } from 'aws-lambda'
import { objectKey, validateRef, verifiedSub } from './identity'

// `POST /uploads/{ref}/complete {uploadId}` — ADR-0006 §4. `finalize` is a control-plane
// call and not a device call: `CompleteMultipartUpload` requires the caller to hand back
// the `(PartNumber, ETag)` list, the device retains no ETags, and it must not start —
// ADR-0001 states that an ETag is not an application content hash. So this asks the
// authority what it holds and completes from the authority's own answer, and a device
// cannot complete an object over parts it never sent.
//
// The order is the same in all three handlers and it is the substance of each: the
// principal, then the grammar, then the key, then S3. Both refusals return before any
// client is constructed.
export async function handler(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
): Promise<APIGatewayProxyStructuredResultV2> {
  const sub = verifiedSub(event)
  if (sub === undefined) return { statusCode: 401, body: JSON.stringify({ error: 'unauthenticated' }) }

  const ref = event.pathParameters?.ref
  if (typeof ref !== 'string' || !validateRef(ref)) {
    return { statusCode: 400, body: JSON.stringify({ error: 'invalid reference' }) }
  }

  // A body that is not JSON carries no uploadId, and this refuses rather than handing the
  // authority nothing. The guard carries no test of its own: it belongs to no claim in this
  // phase, and the calls it stands in front of are themselves unchecked until 4b's contract
  // run.
  let uploadId: unknown
  try {
    uploadId = (JSON.parse(event.body ?? '{}') as { uploadId?: unknown }).uploadId
  } catch {
    uploadId = undefined
  }
  if (typeof uploadId !== 'string' || uploadId.length === 0) {
    return { statusCode: 400, body: JSON.stringify({ error: 'missing uploadId' }) }
  }

  const key = objectKey(sub, ref)
  // Constructed here and not at module scope: a client built when this file is imported is
  // built before any refusal above has run.
  const client = new S3Client({})
  const listed = await client.send(
    new ListPartsCommand({ Bucket: process.env.BUCKET, Key: key, UploadId: uploadId }),
  )
  // ListParts pages at 1000 (MaxParts), and this handler reads one page. Completing over a
  // truncated page would not be a short answer, it would be data loss:
  // CompleteMultipartUpload assembles the object out of exactly the parts it is handed and
  // discards the rest. So a truncated answer is refused loudly here, before any
  // CompleteMultipartUpload call is made at all. The page loop over NextPartNumberMarker
  // belongs to 4b, where a contract run against a real bucket can exercise it.
  //
  // This branch carries no test. Reaching it needs a truncated page, nothing here may fake
  // one — a stubbed S3Client is a double of a vendor's product, which ADR-0006 §4 forbids —
  // and the alternative is a single documented branch that fails loudly.
  if (listed.IsTruncated === true) {
    return { statusCode: 500, body: JSON.stringify({ error: 'part list truncated — this handler reads one page' }) }
  }
  // Handed back exactly as `ListParts` returned it, quoting included and order untouched.
  // ADR-0006 §4 falsifier 2 is precisely this: if a transformation turns out to be needed,
  // this file is wrong, and 4b's recorded contract run is where that is found out.
  const parts = (listed.Parts ?? []).map(part => ({ PartNumber: part.PartNumber, ETag: part.ETag }))
  const completed = await client.send(
    new CompleteMultipartUploadCommand({
      Bucket: process.env.BUCKET,
      Key: key,
      UploadId: uploadId,
      MultipartUpload: { Parts: parts },
    }),
  )
  return { statusCode: 200, body: JSON.stringify({ etag: completed.ETag }) }
}
