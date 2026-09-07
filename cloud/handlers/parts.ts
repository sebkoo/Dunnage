import { ListPartsCommand, S3Client } from '@aws-sdk/client-s3'
import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyStructuredResultV2 } from 'aws-lambda'
import { forgottenOperation, objectKey, validateRef, verifiedSub } from './identity'

// `GET /uploads/{ref}/parts?uploadId=` — ADR-0006 §4. It serves `confirmedProgress`, and
// the answer is set-shaped because the authority's answer is: S3 reports which part numbers
// it holds, not a resumable byte offset. Nothing here turns that set into a number.
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

  // Refused rather than handed to the authority as nothing. This guard carries no test of
  // its own: it belongs to no claim in this phase, and the call it stands in front of is
  // itself unchecked until 4b's contract run.
  const uploadId = event.queryStringParameters?.uploadId
  if (typeof uploadId !== 'string' || uploadId.length === 0) {
    return { statusCode: 400, body: JSON.stringify({ error: 'missing uploadId' }) }
  }

  const key = objectKey(sub, ref)
  // Constructed here and not at module scope: a client built when this file is imported is
  // built before any refusal above has run.
  let listed
  // An operation the authority has no record of is a refusal a device can read, not a fault:
  // `ControlPlaneWire` reads this 404 as `noSuchUpload` and the transport reads that as
  // `TransportError.unknownSession`, which Core replaces the operation on (ADR-0009 §4).
  // Every other error is rethrown, because a plane that answered 404 for an unrelated failure
  // would have Core replace an operation that is still there.
  try {
    listed = await new S3Client({}).send(
      new ListPartsCommand({ Bucket: process.env.BUCKET, Key: key, UploadId: uploadId }),
    )
  } catch (error) {
    if (!forgottenOperation(error)) throw error
    return { statusCode: 404, body: JSON.stringify({ error: 'no such upload' }) }
  }
  // ListParts pages at 1000 (MaxParts), and this handler reads one page. A truncated answer
  // served as if it were whole reports fewer parts than the authority holds, and Core would
  // then re-send parts already confirmed — which is the one thing this repository claims
  // never happens. So it is refused loudly rather than served short. Whether there is a page
  // loop over NextPartNumberMarker at all is ADR-0006 O-20 and undecided: a contract run could
  // exercise one, but whether this repository supports an upload that needs it is the question.
  //
  // This branch carries no test. Reaching it needs a truncated page, nothing here may fake
  // one — a stubbed S3Client is a double of a vendor's product, which ADR-0006 §4 forbids —
  // and the alternative is a single documented branch that fails loudly.
  if (listed.IsTruncated === true) {
    return { statusCode: 500, body: JSON.stringify({ error: 'part list truncated — this handler reads one page' }) }
  }
  // The ETags stay here. `finalize` is a control-plane call precisely so the device never
  // retains them (ADR-0006 §4), and ADR-0001 says an ETag is not an application content
  // hash, so handing them out would be a per-chunk store of transport identifiers the
  // application is not entitled to read as content.
  const held = (listed.Parts ?? []).flatMap(part => (part.PartNumber === undefined ? [] : [part.PartNumber]))
  return { statusCode: 200, body: JSON.stringify({ parts: held }) }
}
