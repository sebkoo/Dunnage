import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyStructuredResultV2 } from 'aws-lambda'
import { describe, expect, test } from 'vitest'
import * as complete from '../handlers/complete'
import * as create from '../handlers/create'
import * as parts from '../handlers/parts'
import { event, keyFor } from './support'

type Handler = (
  event: APIGatewayProxyEventV2WithJWTAuthorizer,
) => Promise<APIGatewayProxyStructuredResultV2>

// The three routes ADR-0006 §4 gives a handler in this commit; `urls` arrives with the one
// that serves it. Every refusal below is asked of all three, because the refusal is the
// shape they share and a handler that skipped it would be the one nothing looked at.
const handlers: ReadonlyArray<readonly [string, Handler]> = [
  ['create', create.handler],
  ['parts', parts.handler],
  ['complete', complete.handler],
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

  // One assertion over all three handlers, not an `expect` inside a loop. `expect` throws,
  // so a loop would report the first handler that misbehaved and hide the two behind it,
  // and this red is the evidence the commit rests on. Filtering names every handler that
  // answered wrongly, in one diff.
  //
  // Refused, and with nothing of the key in the answer: a 401 that echoed `uploads/` back
  // would be an empty prefix reached by another route, which is the default spec §5
  // refuses.
  test('testAMissingSubClaimIsRefusedRatherThanDefaulted', async () => {
    const answered = await Promise.all(
      handlers.map(async ([name, handler]) => {
        const res = await handler(event({ sub: undefined, ref: 'photo.jpg', body: { parts: 3 } }))
        return { name, statusCode: res.statusCode, namesThePrefix: JSON.stringify(res).includes('uploads/') }
      }),
    )
    expect(answered.filter(a => a.statusCode !== 401 || a.namesThePrefix)).toEqual([])
  })

  // Filed under claim 4, not claim 3: what is refused here is claim 4's grammar, and that
  // it is refused before the handler acts is what lets this run at all. There is no
  // credential in this process and no bucket anywhere; a handler that constructed a client
  // and called S3 before validating could not answer 400.
  test('testAHandlerRefusesARefTheGrammarRejectsBeforeItActs', async () => {
    const answered = await Promise.all(
      handlers.map(async ([name, handler]) => {
        const res = await handler(event({ sub: 'sub-1', ref: '../etc', body: { parts: 3 } }))
        return { name, statusCode: res.statusCode }
      }),
    )
    expect(answered.filter(a => a.statusCode !== 400)).toEqual([])
  })
})
