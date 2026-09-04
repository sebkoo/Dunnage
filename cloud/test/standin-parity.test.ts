import type { Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, describe, expect, test } from 'vitest'
import * as complete from '../handlers/complete'
import * as create from '../handlers/create'
import * as parts from '../handlers/parts'
import * as urls from '../handlers/urls'
import { createStandIn } from '../standin/server'
import { type Route, type RouteArgs, ask } from './http-to-answer'
import { type Handler, event, respond } from './support'

// Claim 6, and ADR-0007 §9's rider: the stand-in's front half is measured against the
// plane's with one instrument. `respond` asks a handler, `ask` asks the stand-in over
// HTTP, both return an `Answer`, and the twelve fixtures below are asked of both sides.
// A double that grew more lenient than the plane reds here, by name.
//
// **What is compared: the status, and the `error` the body names. Nothing else.** Not the
// rest of the body — the ids, the URLs, the part lists and the etags differ by
// construction, the stand-in minting its own, so a diff over them would compare fixtures
// and not behaviour — and not the headers, and not the timing. A parity test that compared
// everything would be red on its first green run and would then be loosened until it
// asserted nothing.
//
// **Why the table holds refusals only, as a property and not a convenience.** Every one of
// the twelve is decided before any `S3Client` is constructed, which is exactly what lets
// the plane's side of the diff run on a machine with no credential and no bucket
// (CLAUDE.md). A row that reached S3 could not be compared here at all — the plane's side
// would throw where the stand-in answered. That is why the table stops where it does, and
// not that the accepting paths matter less.
//
// **None of ADR-0007 §9's three assumptions is in the table**, each for a reason of its
// own, and each is carried to 4b:
//
//  1. The 403 for a presigned PUT used for another part or after its expiry. No handler
//     serves a PUT at all — the bytes go to the data plane, S3 in production and the
//     stand-in's own here — so there is nothing on the plane's side to diff against. It is
//     covered by the stand-in's own test, and settled by 4b's contract run with ADR-0006
//     §4's fourth falsifier.
//  2. The 404 for an uploadId not under the key. The plane renders none: `parts.ts` and
//     `complete.ts` catch nothing from S3, so `NoSuchUpload` escapes unhandled. Diffing a
//     404 against an unhandled error would assert the plane behaves as it does not. 4b
//     decides what the plane should render.
//  3. The 400 with `{"error":"incomplete upload"}` on complete. The plane cannot make that
//     refusal: it does not know the plan's N and completes over whatever `ListParts`
//     returns. Excluded for the same reason, and 4b's is the decision.
//
// Measured against the plane and not against a restated expectation, as the negative
// control is: the assertion is that the two answers are the same answer, so a change to a
// handler's refusals moves both sides or reds this test. The plane's own answers are
// `handlers.test.ts`'s to assert; restating them here would be a second copy that can
// drift from the first.

const planeHandlers: Readonly<Record<Route, Handler>> = {
  create: create.handler,
  urls: urls.handler,
  parts: parts.handler,
  complete: complete.handler,
}

// The refusals both sides owe, and nothing else. `parts` reads its uploadId from the query
// string and `event` builds one with an empty query, so a `parts` fixture never carries an
// uploadId — which is the fixture that row is for.
const refusals: ReadonlyArray<{ readonly fixture: string; readonly route: Route; readonly args: RouteArgs }> = [
  { fixture: 'create · a token carrying no sub claim', route: 'create', args: { ref: 'photo.jpg', parts: 3 } },
  { fixture: 'create · a reference the grammar rejects', route: 'create', args: { sub: 'sub-1', ref: '../etc', parts: 3 } },
  { fixture: 'urls · a token carrying no sub claim', route: 'urls', args: { ref: 'photo.jpg', uploadId: 'u-1', parts: 3 } },
  { fixture: 'urls · a reference the grammar rejects', route: 'urls', args: { sub: 'sub-1', ref: '../etc', uploadId: 'u-1', parts: 3 } },
  { fixture: 'urls · a body without an uploadId', route: 'urls', args: { sub: 'sub-1', ref: 'photo.jpg', parts: 3 } },
  { fixture: 'urls · a part count of zero', route: 'urls', args: { sub: 'sub-1', ref: 'photo.jpg', uploadId: 'u-1', parts: 0 } },
  { fixture: 'parts · a token carrying no sub claim', route: 'parts', args: { ref: 'photo.jpg' } },
  { fixture: 'parts · a reference the grammar rejects', route: 'parts', args: { sub: 'sub-1', ref: '../etc' } },
  { fixture: 'parts · no uploadId in the query', route: 'parts', args: { sub: 'sub-1', ref: 'photo.jpg' } },
  { fixture: 'complete · a token carrying no sub claim', route: 'complete', args: { ref: 'photo.jpg', uploadId: 'u-1' } },
  { fixture: 'complete · a reference the grammar rejects', route: 'complete', args: { sub: 'sub-1', ref: '../etc', uploadId: 'u-1' } },
  { fixture: 'complete · a body without an uploadId', route: 'complete', args: { sub: 'sub-1', ref: 'photo.jpg' } },
]

// One argument set, two request shapes — the same relation `event` already holds between
// a body and a path. A field the args do not carry is absent from the body, so "a body
// without an uploadId" is one fixture and not two.
function planeEvent(args: RouteArgs) {
  const body: Record<string, unknown> = {}
  if (args.uploadId !== undefined) body.uploadId = args.uploadId
  if (args.parts !== undefined) body.parts = args.parts
  return event({ sub: args.sub, ref: args.ref, body })
}

let server: Server
let base = ''

beforeAll(async () => {
  // Started in-process on a port the operating system assigns. The bundle is never spawned
  // and no port is written down: see the head of `standin.test.ts`.
  server = createStandIn()
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})

afterAll(async () => {
  server.closeAllConnections()
  await new Promise<void>((resolve, reject) => server.close(error => (error ? reject(error) : resolve())))
})

describe("the stand-in's front half, measured against the plane's", () => {
  // Every row runs, and the differing ones are collected into one assertion that names
  // each. An `expect` inside the loop would report the first row that disagreed and hide
  // the eleven behind it — and this diff is the evidence the commit rests on.
  test('testTheStandInRefusesWhatThePlaneRefusesWithTheSameAnswer', async () => {
    const rows = await Promise.all(
      refusals.map(async ({ fixture, route, args }) => {
        const plane = await respond(planeHandlers[route], planeEvent(args))
        const standIn = await ask(base, route, args)
        return {
          fixture,
          plane: { statusCode: plane.statusCode, reason: plane.reason },
          standIn: { statusCode: standIn.statusCode, reason: standIn.reason },
        }
      }),
    )
    expect(rows.filter(r => r.standIn.statusCode !== r.plane.statusCode || r.standIn.reason !== r.plane.reason)).toEqual([])
  })
})
