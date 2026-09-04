import type { Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'vitest'
import { EXPIRES_IN_SECONDS } from '../handlers/urls'
import { createStandIn } from '../standin/server'

// Claim 6. The stand-in's own contract, asked of the stand-in and of nothing else. Every
// answer below is the stand-in behaving as it says it does; none of it is evidence about
// S3, and the three assumptions ADR-0007 §9 records — the 403, the 404, and the 400 on an
// incomplete complete — are exactly the ones this file tests as the stand-in's own and the
// parity diff therefore cannot compare (`standin-parity.test.ts` says why, per assumption).
//
// The server is started here, in-process, on a port the operating system assigns:
// `listen(0)`, and the port is read off the server. The bundle `npm run build` emits is
// never spawned and no port is written down — a suite that shelled out to `dist/standin.js`
// would fail the day the build order changes, and a fixed port fails the day something else
// holds it. That the bundle lands beside the handler asset rather than inside it is proven
// by CI's `ls dist/handlers` and its synth grep, which is what those checks are for.

// The stand-in's one clock, injected. The expiry a URL carries is the only thing in the
// server that reads time, and the alternative to a virtual clock here is a suite that waits
// out 900 real seconds. Moved by the expiry test and by nothing else.
let now = 0
let server: Server
let base = ''

beforeAll(async () => {
  server = createStandIn({ now: () => now })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})

afterAll(async () => {
  // Connections first: a withheld answer is a socket the server is still holding, and
  // `close` waits for every one of them.
  server.closeAllConnections()
  await new Promise<void>((resolve, reject) => server.close(error => (error ? reject(error) : resolve())))
})

beforeEach(async () => {
  now = 0
  await control('POST', '/_standin/reset')
})

// The bearer token is the `sub` — the stand-in verifies no JWT (spec §3.1), and this is
// the one place the suite says so.
function asCaller(sub: string): Record<string, string> {
  return { authorization: `Bearer ${sub}`, 'content-type': 'application/json' }
}

async function control(method: string, path: string, body?: unknown): Promise<Record<string, unknown>> {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  return (await res.json()) as Record<string, unknown>
}

async function counters(uploadId: string): Promise<unknown> {
  return control('GET', `/_standin/uploads/${uploadId}`)
}

async function openUpload(sub: string, ref: string, parts: number): Promise<string> {
  const res = await fetch(`${base}/uploads`, {
    method: 'POST',
    headers: asCaller(sub),
    body: JSON.stringify({ ref, parts }),
  })
  return String(((await res.json()) as { uploadId?: unknown }).uploadId)
}

async function partUrls(sub: string, ref: string, uploadId: string, parts: number): Promise<readonly string[]> {
  const res = await fetch(`${base}/uploads/${ref}/urls`, {
    method: 'POST',
    headers: asCaller(sub),
    body: JSON.stringify({ uploadId, parts }),
  })
  const body = (await res.json()) as { urls?: ReadonlyArray<{ url?: unknown }> }
  return (body.urls ?? []).map(entry => String(entry.url))
}

async function heldParts(sub: string, ref: string, uploadId: string): Promise<unknown> {
  const res = await fetch(`${base}/uploads/${ref}/parts?uploadId=${encodeURIComponent(uploadId)}`, {
    headers: asCaller(sub),
  })
  return ((await res.json()) as { parts?: unknown }).parts
}

describe("the stand-in's own contract", () => {
  // A re-send is a number, not an inference. The part list still holds one entry for part
  // 1 after the second PUT — S3 replaces the bytes rather than refusing the request, which
  // is the behaviour ADR-0001 wrote the invariant's weaker claim against — and the counter
  // is what tells the two receipts apart. Asserted as one object so a run reports the
  // counter and the part list together: a stand-in that refused the second PUT would still
  // report `[1]`, and only the counter names that.
  test('testAPartReceivedIsCountedEvenWhenItReplacesOneAlreadyHeld', async () => {
    const uploadId = await openUpload('sub-1', 'photo.jpg', 1)
    const [first] = await partUrls('sub-1', 'photo.jpg', uploadId, 1)
    const answers = [
      (await fetch(first, { method: 'PUT', body: 'the first bytes' })).status,
      (await fetch(first, { method: 'PUT', body: 'the second bytes' })).status,
    ]
    expect({ answers, counters: await counters(uploadId), parts: await heldParts('sub-1', 'photo.jpg', uploadId) }).toEqual({
      answers: [200, 200],
      counters: { puts: { '1': 2 }, completes: 0, held: [] },
      parts: [1],
    })
  })

  // `after-store`: the bytes land, `/parts` reports them, and the answer is withheld. This
  // is `InMemoryTransportDouble`'s stall-but-land case on a real socket, and it is how
  // commit 8 makes a kill land mid-transfer with no sleep.
  //
  // How "withheld" is asserted, there being no clock: as an ordering. The PUT's promise is
  // raced against a marker resolved in the same turn, at a point where a `/parts` round
  // trip has already been made and answered — real I/O, so an answer the server had
  // already sent would have arrived. `Promise.race` resolves with the PUT when the PUT has
  // settled, because `Promise.resolve` of an already-settled promise is that promise and
  // its reaction is queued first; the marker wins only when the PUT is still pending.
  //
  // The limit, stated plainly: this shows the answer had not arrived by that point. It
  // does not show it never would have.
  test('testAHoldAfterStoreIsHeldByPartsAndWithholdsTheAnswer', async () => {
    const uploadId = await openUpload('sub-1', 'photo.jpg', 1)
    const [first] = await partUrls('sub-1', 'photo.jpg', uploadId, 1)
    await control('POST', '/_standin/hold', { part: 1, mode: 'after-store' })

    const answering = fetch(first, { method: 'PUT', body: 'the bytes' })
    const marker = 'the answer had not arrived by this point'
    const whileHeld = {
      parts: await heldParts('sub-1', 'photo.jpg', uploadId),
      raced: await Promise.race([answering, Promise.resolve(marker)]),
      counters: await counters(uploadId),
    }

    await control('POST', '/_standin/release', { part: 1 })
    const afterRelease = { status: (await answering).status, counters: await counters(uploadId) }

    expect({ whileHeld, afterRelease }).toEqual({
      whileHeld: { parts: [1], raced: marker, counters: { puts: { '1': 1 }, completes: 0, held: [1] } },
      afterRelease: { status: 200, counters: { puts: { '1': 1 }, completes: 0, held: [] } },
    })
  })

  // `before-store`: the body is read, nothing is stored, the answer is withheld; on release
  // the bytes are stored and then answered. Whether a killed app's task survives to be
  // answered is the daemon's decision and unverified, so this mode is the device harness's
  // (spec §3.3) and never a CI assertion — this test asserts the mode's own behaviour on
  // this server, and nothing about a daemon.
  //
  // "Withheld" is the same ordering as above, with the same limit.
  test('testAHoldBeforeStoreWithholdsAndHoldsNothingUntilRelease', async () => {
    const uploadId = await openUpload('sub-1', 'photo.jpg', 1)
    const [first] = await partUrls('sub-1', 'photo.jpg', uploadId, 1)
    await control('POST', '/_standin/hold', { part: 1, mode: 'before-store' })

    const answering = fetch(first, { method: 'PUT', body: 'the bytes' })
    const marker = 'the answer had not arrived by this point'
    const whileHeld = {
      parts: await heldParts('sub-1', 'photo.jpg', uploadId),
      raced: await Promise.race([answering, Promise.resolve(marker)]),
      counters: await counters(uploadId),
    }

    await control('POST', '/_standin/release', { part: 1 })
    const afterRelease = {
      status: (await answering).status,
      parts: await heldParts('sub-1', 'photo.jpg', uploadId),
      counters: await counters(uploadId),
    }

    expect({ whileHeld, afterRelease }).toEqual({
      whileHeld: { parts: [], raced: marker, counters: { puts: {}, completes: 0, held: [1] } },
      afterRelease: { status: 200, parts: [1], counters: { puts: { '1': 1 }, completes: 0, held: [] } },
    })
  })

  // ADR-0007 §9's first assumption, tested as the stand-in's own and never as S3's. The URL
  // is a token over `(uploadId, part, expiry)`, so both refusals are decidable from the URL
  // alone: presented at another part the signature does not verify, and presented after the
  // expiry it carries the clock has passed it.
  //
  // The accepted row is first and is not decoration: without it a server that answered 403
  // to every PUT would pass this test.
  test('testAUrlIsRefusedForAnotherPartAndAfterItsExpiry', async () => {
    const uploadId = await openUpload('sub-1', 'photo.jpg', 2)
    const [forPartOne, forPartTwo] = await partUrls('sub-1', 'photo.jpg', uploadId, 2)
    // The stand-in copies the plane's expiry rather than importing it — importing
    // `urls.ts` would pull the S3 SDK into `dist/standin.js` — so the copy is held to the
    // plane's here, by the test whose subject the expiry already is. Lower
    // `EXPIRES_IN_SECONDS` without lowering the copy and this reds, rather than CI quietly
    // measuring the transport against a plane more lenient than the real one.
    const minted = Number(new URL(forPartOne).searchParams.get('e')) - now
    expect(minted).toEqual(EXPIRES_IN_SECONDS * 1000)
    // Part 1's signature, presented at part 2's path.
    const misdirected = new URL(forPartOne)
    misdirected.pathname = new URL(forPartTwo).pathname

    const rows = [
      { fixture: 'its own part, inside its expiry', status: (await fetch(forPartOne, { method: 'PUT', body: 'a' })).status },
      { fixture: 'the same URL presented for another part', status: (await fetch(misdirected, { method: 'PUT', body: 'b' })).status },
    ]
    now = 900_001
    rows.push({
      fixture: 'its own part, after its expiry',
      status: (await fetch(forPartOne, { method: 'PUT', body: 'c' })).status,
    })

    expect(rows).toEqual([
      { fixture: 'its own part, inside its expiry', status: 200 },
      { fixture: 'the same URL presented for another part', status: 403 },
      { fixture: 'its own part, after its expiry', status: 403 },
    ])
  })

  // ADR-0007 §9's second assumption, tested as the stand-in's own. An uploadId is held
  // under the key it was opened under, and the key is `sub` then `ref` — so a second
  // caller's token and a second reference each miss it, and the answer is a 404 rather than
  // an empty part list. The plane renders none of this: `parts.ts` and `complete.ts` catch
  // nothing from S3.
  //
  // The accepted row is first, for the reason the expiry test gives.
  test('testAnUploadIdNotUnderTheKeyIsRefused', async () => {
    const uploadId = await openUpload('sub-1', 'photo.jpg', 1)
    const rows = [
      { fixture: 'the key it was opened under', status: await status(`/uploads/photo.jpg/parts?uploadId=${uploadId}`, 'sub-1') },
      { fixture: 'another reference, same caller', status: await status(`/uploads/other.jpg/parts?uploadId=${uploadId}`, 'sub-1') },
      { fixture: 'another caller, same reference', status: await status(`/uploads/photo.jpg/parts?uploadId=${uploadId}`, 'sub-2') },
      { fixture: 'an uploadId it never minted', status: await status('/uploads/photo.jpg/parts?uploadId=u-none', 'sub-1') },
      { fixture: 'complete under another reference', status: await completeStatus('other.jpg', uploadId, 'sub-1') },
    ]
    expect(rows).toEqual([
      { fixture: 'the key it was opened under', status: 200 },
      { fixture: 'another reference, same caller', status: 404 },
      { fixture: 'another caller, same reference', status: 404 },
      { fixture: 'an uploadId it never minted', status: 404 },
      { fixture: 'complete under another reference', status: 404 },
    ])
  })

  // ADR-0007 §9's third assumption, tested as the stand-in's own. The stand-in knows the
  // plan's N, because `create` was told it, and refuses a complete over a set that is not
  // {1..N} with the body `ControlPlaneWire` reads as `TransportError.incompleteUpload`. The
  // plane cannot make this refusal at all: it does not know N and completes over whatever
  // `ListParts` returns.
  test('testACompleteOverPartsItDoesNotHoldIsRefused', async () => {
    const uploadId = await openUpload('sub-1', 'photo.jpg', 3)
    const urls = await partUrls('sub-1', 'photo.jpg', uploadId, 3)
    await fetch(urls[0], { method: 'PUT', body: 'one' })
    await fetch(urls[1], { method: 'PUT', body: 'two' })
    const refused = await complete('photo.jpg', uploadId, 'sub-1')
    await fetch(urls[2], { method: 'PUT', body: 'three' })
    const accepted = await complete('photo.jpg', uploadId, 'sub-1')

    expect({
      refused: { status: refused.status, error: refused.error },
      accepted: { status: accepted.status, error: accepted.error, hasEtag: accepted.etag !== undefined },
      counters: await counters(uploadId),
    }).toEqual({
      refused: { status: 400, error: 'incomplete upload' },
      accepted: { status: 200, error: undefined, hasEtag: true },
      counters: { puts: { '1': 1, '2': 1, '3': 1 }, completes: 1, held: [] },
    })
  })
})

async function status(path: string, sub: string): Promise<number> {
  return (await fetch(`${base}${path}`, { headers: asCaller(sub) })).status
}

async function complete(
  ref: string,
  uploadId: string,
  sub: string,
): Promise<{ status: number; error?: unknown; etag?: unknown }> {
  const res = await fetch(`${base}/uploads/${ref}/complete`, {
    method: 'POST',
    headers: asCaller(sub),
    body: JSON.stringify({ uploadId }),
  })
  const body = (await res.json()) as { error?: unknown; etag?: unknown }
  return { status: res.status, error: body.error, etag: body.etag }
}

async function completeStatus(ref: string, uploadId: string, sub: string): Promise<number> {
  return (await complete(ref, uploadId, sub)).status
}
