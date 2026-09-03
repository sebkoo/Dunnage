import { describe, expect, test } from 'vitest'
import * as create from '../handlers/create'
import * as clientTrustedKey from './client-trusted-key'
import { event, keyFor, respond } from './support'

// Claim 6, and the only test file in this phase whose subject is a handler this repository
// would never deploy. `client-trusted-key.ts` is `handlers/create.ts` with the key taken
// from the request body, and what it is here to keep working is the collision claim 3
// removes. It is never "fixed": if it stops putting two callers on one object, the control
// has been broken and `create` has nothing left to be measured against.

// The two requests, built once and shared by the last two tests, so "the same two requests"
// is a fact of this file rather than a claim in a comment. Two callers the token tells
// apart, one reference, and one `key` in both bodies — `sub-2` sending the key `sub-1`
// would send. Nothing else about the two differs.
const callers = [
  event({ sub: 'sub-1', ref: 'photo.jpg', body: { key: 'uploads/sub-1/photo.jpg' } }),
  event({ sub: 'sub-2', ref: 'photo.jpg', body: { key: 'uploads/sub-1/photo.jpg' } }),
] as const

// The two refusals `create` makes before it acts, asked of both handlers. The bodies carry
// a `key` for the same reason the two above do: a request that never named one would not be
// a request this control answers differently from `create`.
const refusals = [
  ['a token carrying no sub claim', event({ sub: undefined, ref: 'photo.jpg', body: { key: 'uploads/sub-1/photo.jpg' } })],
  ['a reference the grammar rejects', event({ sub: 'sub-1', ref: '../etc', body: { key: 'uploads/sub-1/photo.jpg' } })],
] as const

describe('the failure mode a client-trusted key reintroduces, kept working on purpose', () => {
  // What the other two tests do not assert. Without this one the control shows that *some*
  // handler puts two callers on one object, and a handler that answered 200 to everything
  // would show that too — the collision would then be a property of a handler that refuses
  // nothing, not of a client-trusted key. Measured against `create` and not against a
  // restated expectation: the assertion is that the two answers are the same answer, so a
  // change to `create`'s refusals moves both sides or reds this test.
  //
  // Both handlers are asked through `respond`, which is why it lives in `support.ts`: a
  // comparison between two handlers has to be made with one instrument. A throw is recorded
  // as an answer rather than raised, and both fixtures report in one diff — the second is
  // not hidden behind the first.
  test('testTheClientTrustedKeyHandlerKeepsTheContractItIsMeasuredAgainst', async () => {
    const rows = await Promise.all(
      refusals.map(async ([fixture, requested]) => {
        const derived = await respond(create.handler, requested)
        const clientTrusted = await respond(clientTrustedKey.handler, requested)
        return {
          fixture,
          derived: { statusCode: derived.statusCode, reason: derived.reason },
          clientTrusted: { statusCode: clientTrusted.statusCode, reason: clientTrusted.reason },
        }
      }),
    )
    expect(
      rows.filter(
        r => r.clientTrusted.statusCode !== r.derived.statusCode || r.clientTrusted.reason !== r.derived.reason,
      ),
    ).toEqual([])
  })

  // The failure itself. Two callers the authorizer told apart, one object — and the caller
  // that reached the other's prefix did so by asking for it, with a body the server
  // believed.
  //
  // The two halves are asserted in one object so a run reports both: a control that started
  // refusing one of the callers would otherwise pass the key comparison over a single row
  // and say nothing about the refusal it had grown.
  test('testAClientTrustedKeyPutsTwoCallersOnOneObject', async () => {
    const landed = await Promise.all(
      callers.map(async requested => {
        const res = await clientTrustedKey.handler(requested)
        return {
          statusCode: res.statusCode,
          key: (JSON.parse(res.body ?? '{}') as { key?: unknown }).key,
        }
      }),
    )
    expect({
      refused: landed.filter(l => l.statusCode !== 200),
      distinctKeys: [...new Set(landed.map(l => l.key))],
    }).toEqual({ refused: [], distinctKeys: ['uploads/sub-1/photo.jpg'] })
  })

  // The contrast, over the same two requests and not over a second pair written to suit it.
  // `keyFor` is the two steps a handler takes to reach a key — `verifiedSub` then
  // `objectKey` — and the `key` both bodies carry reaches neither, because `objectKey` has
  // no parameter it could arrive through. Two callers, two keys.
  //
  // Not async: `keyFor` composes two pure functions and there is nothing to await.
  test('testTheDerivedKeyAfterTheSameTwoRequestsKeepsTheCallersApart', () => {
    expect([...new Set(callers.map(keyFor))]).toEqual([
      'uploads/sub-1/photo.jpg',
      'uploads/sub-2/photo.jpg',
    ])
  })
})
