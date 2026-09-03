import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyStructuredResultV2 } from 'aws-lambda'
import { validateRef, verifiedSub } from '../handlers/identity'

// Claim 6's control: the handler this service would be if the key came from the client. It
// is `handlers/create.ts`'s path with one line different — the key is read out of the
// request body instead of composed by `objectKey(sub, ref)` — and everything in front of
// that line is create's, line for line: the 401 on a missing `sub`, the JSON parse,
// `validateRef` and its 400 with the reason `invalid reference`. What holds it there is
// `testTheClientTrustedKeyHandlerKeepsTheContractItIsMeasuredAgainst`, which compares both
// handlers' answers to the same two refusals rather than restating what they should be.
//
// There is a second difference, and "exactly one thing" must not be allowed to cover it.
// create's 200 branch calls S3, and no test in phase 4a reaches an S3 call: there is no
// credential in this process and no bucket anywhere. So this returns `200 {key}` where
// create returns `200 {uploadId}` — the key it would have used, made observable, because a
// control whose failure happened inside an unreachable S3 call would demonstrate nothing.
// One difference in the path under test; the second is where that path stops, which is
// exactly where every 4a test of a real handler stops, before a client is constructed.
//
// It is never "fixed". If this stops putting two callers on one object, the control has
// been broken and `create` has nothing left to be measured against.
//
// Under `test/`, never under `handlers/`, and four things make it inert rather than merely
// tidily filed. `vitest.config.mts` includes only `test/**/*.test.ts`, so this file is
// imported by a suite and never collected as one — `support.ts`'s position exactly.
// `SOURCE_DIRS` in `synth.test.ts` is `['bin', 'lib', 'handlers']`, so claim 1's scan over
// the stack's own sources never reads it. `package.json`'s build script names
// `handlers/*.ts` one by one, so nothing bundles it into a Lambda asset and no route could
// reach it. And `tsconfig.json` includes `test`, so it is typechecked under the same strict
// settings as everything else: inert is not unchecked.
export async function handler(
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
): Promise<APIGatewayProxyStructuredResultV2> {
  const sub = verifiedSub(event)
  if (sub === undefined) return { statusCode: 401, body: JSON.stringify({ error: 'unauthenticated' }) }

  let ref: unknown
  try {
    ref = (JSON.parse(event.body ?? '{}') as { ref?: unknown }).ref
  } catch {
    ref = undefined
  }
  if (typeof ref !== 'string' || !validateRef(ref)) {
    return { statusCode: 400, body: JSON.stringify({ error: 'invalid reference' }) }
  }

  // The one line. `sub` is verified and in hand, and this reaches past it for a field the
  // caller chose. The parse cannot throw here: the parse above already succeeded, or `ref`
  // would be undefined and this line would not have been reached.
  const key = (JSON.parse(event.body ?? '{}') as { key?: unknown }).key
  return { statusCode: 200, body: JSON.stringify({ key }) }
}
