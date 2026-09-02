import { CreateMultipartUploadCommand, S3Client } from '@aws-sdk/client-s3'
import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyStructuredResultV2 } from 'aws-lambda'
import { objectKey, validateRef, verifiedSub } from './identity'

// `POST /uploads {ref, parts}` — ADR-0006 §4. This route alone carries its reference in the
// body rather than the path, because the object it names does not exist yet and there is no
// `{ref}` in the path to carry it.
//
// The order below is the substance of this handler, not its preamble. The principal, then
// the grammar, then the key, then S3 — and the two refusals return before any client is
// constructed, which is what makes them answerable on a machine with no credential and no
// bucket. `parts` is read by no S3 call here: `CreateMultipartUpload` takes a bucket and a
// key, and the part count is what the caller will ask `POST /uploads/{ref}/urls` to sign.
export async function handler(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
): Promise<APIGatewayProxyStructuredResultV2> {
  const sub = verifiedSub(event)
  if (sub === undefined) return { statusCode: 401, body: JSON.stringify({ error: 'unauthenticated' }) }

  // A body that is not JSON, or is not an object, carries no reference, and the refusal
  // below answers that exactly as it answers a reference the grammar rejects. Parsing here
  // rather than trusting the body is what makes a malformed request a 400 and not a 500.
  let ref: unknown
  try {
    ref = (JSON.parse(event.body ?? '{}') as { ref?: unknown }).ref
  } catch {
    ref = undefined
  }
  if (typeof ref !== 'string' || !validateRef(ref)) {
    return { statusCode: 400, body: JSON.stringify({ error: 'invalid reference' }) }
  }

  const key = objectKey(sub, ref)
  // Constructed here and not at module scope: a client built when this file is imported is
  // built before either refusal above has run.
  const created = await new S3Client({}).send(
    new CreateMultipartUploadCommand({ Bucket: process.env.BUCKET, Key: key }),
  )
  // The transport composes `<ref> "/" <uploadId>` itself (ADR-0006 §2), so the uploadId is
  // what this returns and the composition is not done here.
  return { statusCode: 200, body: JSON.stringify({ uploadId: created.UploadId }) }
}
