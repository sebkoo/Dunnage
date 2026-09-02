import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyStructuredResultV2 } from 'aws-lambda'
import { describe, expect, test } from 'vitest'
import * as complete from '../handlers/complete'
import * as create from '../handlers/create'
import * as parts from '../handlers/parts'
import * as urls from '../handlers/urls'
import { event, keyFor } from './support'

type Handler = (
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
) => Promise<APIGatewayProxyStructuredResultV2>

// One handler's answer, with a throw recorded as an answer rather than raised. A handler that
// throws inside the `Promise.all` below takes the whole array with it, and the run then reports
// one name where four were asked — which is the shape this repository's testing rule refuses,
// and it is reachable rather than theoretical: a handler whose refusals were removed reaches a
// client construction, and that fails outright on a machine with no region and no credential.
// So the throw becomes this handler's row, and the three that answered still report.
type Answer = {
  readonly statusCode: number | string | undefined
  readonly reason: unknown
  readonly rendered: string
}

async function respond(
  handler: Handler,
  requested: APIGatewayProxyEventV2WithJWTAuthorizer,
): Promise<Answer> {
  try {
    const res = await handler(requested)
    // The refusal's own reason, read out of the body every handler answers with. A status
    // code alone does not say which guard produced it, and the guards answer differently.
    let reason: unknown
    try {
      reason = (JSON.parse(res.body ?? '{}') as { error?: unknown }).error
    } catch {
      reason = undefined
    }
    return { statusCode: res.statusCode, reason, rendered: JSON.stringify(res) }
  } catch (thrown) {
    return { statusCode: `threw ${String(thrown)}`, reason: undefined, rendered: '' }
  }
}

// All four routes ADR-0006 §4 gives a handler. Every refusal below is asked of all four,
// because the refusal is the shape they share and a handler that skipped it would be the one
// nothing looked at — a fourth handler with the same front half, left out of this array, is
// precisely that handler.
const handlers: ReadonlyArray<readonly [string, Handler]> = [
  ['create', create.handler],
  ['parts', parts.handler],
  ['complete', complete.handler],
  ['urls', urls.handler],
]

describe('the refusals every handler makes before it acts', () => {
  // Not async: `keyFor` composes two pure functions and there is nothing to await. The
  // plan wrote this test `async`; the shape follows the code rather than the other way
  // round.
  //
  // The poisoned body carries a `key`, a `sub` and a `userId`, which is the whole set spec
  // §5 names, and it produces the key a body without them produces. `objectKey` has no
  // parameter any of them could arrive through, so this holds by the signature rather than
  // by a check that could be forgotten at one of four call sites.
  test('testARequestBodyNamingAKeyOrASubProducesTheSameKeyAsOneWithout', () => {
    const poisoned = event({
      sub: 'sub-1',
      ref: 'photo.jpg',
      body: { parts: 3, key: 'uploads/other/x', sub: 'other', userId: 'other' },
    })
    const plain = event({ sub: 'sub-1', ref: 'photo.jpg', body: { parts: 3 } })
    expect(keyFor(poisoned)).toBe(keyFor(plain))
    expect(keyFor(poisoned)).toBe('uploads/sub-1/photo.jpg')
  })

  // One assertion over all four handlers, not an `expect` inside a loop. `expect` throws, so
  // a loop would report the first handler that misbehaved and hide the three behind it, and
  // this red is the evidence the commit rests on. Filtering names every handler that answered
  // wrongly, in one diff.
  //
  // Refused, and with nothing of the key in the answer: a 401 that echoed `uploads/` back
  // would be an empty prefix reached by another route, which is the default spec §5
  // refuses.
  test('testAMissingSubClaimIsRefusedRatherThanDefaulted', async () => {
    const answered = await Promise.all(
      handlers.map(async ([name, handler]) => {
        const res = await respond(handler, event({ sub: undefined, ref: 'photo.jpg', body: { parts: 3 } }))
        return { name, statusCode: res.statusCode, namesThePrefix: res.rendered.includes('uploads/') }
      }),
    )
    expect(answered.filter(a => a.statusCode !== 401 || a.namesThePrefix)).toEqual([])
  })

  // Filed under claim 4, not claim 3: what is refused here is claim 4's grammar, and that it
  // is refused before the handler acts is what lets this run at all. There is no credential in
  // this process and no bucket anywhere; a handler that constructed a client and called S3
  // before validating could not answer 400.
  //
  // The refusal's reason is asserted and not only its status code, because a 400 is not
  // evidence that the grammar is what answered. Three of the four — `urls`, `parts` and
  // `complete` — carry a second guard that also answers 400, and no one request satisfies all
  // of them at once: `parts` reads its `uploadId` from the query string, so the one in this
  // body never reaches it, and with its grammar check deleted it still answers 400 — `missing
  // uploadId`. Checked by deleting it, green before the assertion read the reason and red
  // after. `create` is the fourth and has no second guard; with its grammar check deleted it
  // reaches a client construction instead, which `respond` records as its answer.
  test('testAHandlerRefusesARefTheGrammarRejectsBeforeItActs', async () => {
    const answered = await Promise.all(
      handlers.map(async ([name, handler]) => {
        const res = await respond(handler, event({ sub: 'sub-1', ref: '../etc', body: { parts: 3, uploadId: 'u-1' } }))
        return { name, statusCode: res.statusCode, reason: res.reason }
      }),
    )
    expect(answered.filter(a => a.statusCode !== 400 || a.reason !== 'invalid reference')).toEqual([])
  })
})
