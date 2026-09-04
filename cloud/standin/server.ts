import { createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import { createServer as createHttpServer } from 'node:http'
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { objectKey, validateRef } from '../handlers/identity'

// The stand-in authority. It has S3 multipart's shape — a PUT per part, a list of the
// parts held, a complete — and it is a double of **this repository's contract, never of
// S3** (ADR-0007 §1 and §9). Its front half is the four routes ADR-0006 §4 wrote down and
// nothing else, which is what makes 4b the same transport against the deployed plane with
// a different base URL and token. The precedent is `InMemoryTransportDouble`: a double
// implements a boundary this repository declared and can therefore specify, and ADR-0006
// §4's rule against a stubbed `S3Client` — a double of a vendor's product runs a guess
// against itself — is kept rather than bent.
//
// Three things it does are assumptions about S3 that nothing in phase 5 checks: the 403
// for a URL used for another part or after its expiry, the 404 for an uploadId not under
// the key, and the 400 on a complete over parts it does not hold. Each is UNVERIFIED and
// each is 4b's contract run's (ADR-0007 §9). A green test here says the stand-in behaves
// as assumed and says nothing about S3.
//
// It authenticates nothing: the bearer token **is** the `sub`. That is the stand-in
// standing exactly where `verifiedSub` stands, after authentication (spec §3.1); a
// stand-in that verified a JWT would be a second authorizer to keep in step with the
// deployed one. It imports `objectKey` and `validateRef` from the handlers, so the ref
// grammar and the key derivation keep their one definition (ADR-0006 §2) rather than
// being copied into a second implementation of the same routes.
//
// State is one `Map` per uploadId and is lost on exit. Nothing here is durable, and
// nothing in this file is production code: it is bundled to `dist/standin.js`, a sibling
// of the `dist/handlers` asset and never inside it.

// The plane's expiry, in milliseconds. It is a copy of `EXPIRES_IN_SECONDS` in
// `cloud/handlers/urls.ts` — copied rather than imported, because importing that module
// would pull the S3 SDK into `dist/standin.js` — and a copy is a third site of the number
// ADR-0007 §6 couples to `partTransferLifetime` in
// `Sources/DunnageTransport/URLSessionPartTasks.swift`. So it is not held by a comment:
// `testAUrlIsRefusedForAnotherPartAndAfterItsExpiry` asserts that a URL this server mints
// carries exactly the plane's exported life. Without that equality the failure runs the
// wrong way — lower the plane's expiry alone and the stand-in keeps minting the longer
// one, and CI measures the transport against a plane more lenient than the real one.
// Nothing in CI waits out this number; the one test that reaches the expiry moves an
// injected clock.
const URL_LIFETIME_MS = 900_000

// S3's part numbers run 1 through 10000, as `cloud/handlers/urls.ts` has it.
const MAX_PART_NUMBER = 10_000

type HoldMode = 'after-store' | 'before-store'

type Hold = {
  readonly mode: HoldMode
  readonly withheld: Promise<void>
  readonly release: () => void
}

type Upload = {
  readonly key: string
  // The plan's N, as `create` was told it. The plane does not validate `parts` on create
  // and neither does this, so a create that named no usable count leaves N unknown and the
  // incomplete-complete refusal below is then not decidable — it is the only refusal here
  // that needs a number the caller supplied.
  readonly planned: number | undefined
  readonly stored: Map<number, Buffer>
  readonly receipts: Map<number, number>
  completes: number
}

export type StandInOptions = {
  // The one clock this server reads, injected so a test can reach a URL's expiry without
  // waiting out its life. Defaults to the wall clock, which is what the bundle runs on.
  readonly now?: () => number
}

export function createStandIn(options: StandInOptions = {}): Server {
  const now = options.now ?? (() => Date.now())
  // Per process, and never written down. A URL is a token over `(uploadId, part, expiry)`
  // signed with it, so the two refusals ADR-0007 §9 item 1 records are decidable from the
  // URL alone and no request has to be remembered to make them.
  const secret = randomBytes(32)
  const uploads = new Map<string, Upload>()
  // Keyed by part number, not by upload: the control surface says `{part, mode}`
  // (spec §3.3), and the harness holds one part of the one upload under test.
  const holds = new Map<number, Hold>()

  const server = createHttpServer((req, res) => {
    route(req, res).catch(error => {
      // A throw is answered rather than left to hang the socket the test is waiting on.
      json(res, 500, { error: `the stand-in threw: ${String(error)}` })
    })
  })

  async function route(req: IncomingMessage, res: ServerResponse): Promise<void> {
    // The host is the request's own, so a URL this server issues points back at the
    // interface the caller reached it on — the ephemeral port a test bound, or the address
    // the harness typed into the app.
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? '127.0.0.1'}`)
    // Decoded per segment, which is what API Gateway hands a handler in
    // `pathParameters`. A ref the grammar admits needs no escaping, so this changes
    // nothing for a real reference; it is what lets a refusal fixture carry `../etc`
    // through a path without a URL parser resolving the dot segments away.
    const path = url.pathname.split('/').filter(part => part.length > 0).map(decodeURIComponent)
    const method = req.method ?? 'GET'

    if (path[0] === '_standin') return standInControl(method, path, req, res)
    if (method === 'PUT' && path[0] === '_part' && path.length === 3) {
      return receivePart(path[1], path[2], url, req, res)
    }
    if (method === 'POST' && path.length === 1 && path[0] === 'uploads') return create(req, res)
    if (method === 'POST' && path.length === 3 && path[0] === 'uploads' && path[2] === 'urls') {
      return mintUrls(path[1], url, req, res)
    }
    if (method === 'GET' && path.length === 3 && path[0] === 'uploads' && path[2] === 'parts') {
      return listParts(path[1], url, req, res)
    }
    if (method === 'POST' && path.length === 3 && path[0] === 'uploads' && path[2] === 'complete') {
      return completeUpload(path[1], req, res)
    }
    json(res, 404, { error: 'no such route' })
  }

  // `POST /uploads {ref, parts} -> {uploadId}`. The order is `create.ts`'s and the
  // refusals are its refusals, because the parity diff asks both sides the same fixtures
  // and a different order answers a different one of them.
  async function create(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const sub = bearerSub(req)
    if (sub === undefined) return json(res, 401, { error: 'unauthenticated' })

    const body = await readJson(req)
    const ref = body.ref
    if (typeof ref !== 'string' || !validateRef(ref)) {
      return json(res, 400, { error: 'invalid reference' })
    }

    const uploadId = randomUUID()
    uploads.set(uploadId, {
      key: objectKey(sub, ref),
      planned: partCount(body.parts),
      stored: new Map(),
      receipts: new Map(),
      completes: 0,
    })
    json(res, 200, { uploadId })
  }

  // `POST /uploads/{ref}/urls {uploadId, parts} -> {urls: [{partNumber, url}]}`.
  async function mintUrls(ref: string, url: URL, req: IncomingMessage, res: ServerResponse): Promise<void> {
    const sub = bearerSub(req)
    if (sub === undefined) return json(res, 401, { error: 'unauthenticated' })
    if (!validateRef(ref)) return json(res, 400, { error: 'invalid reference' })

    const body = await readJson(req)
    const uploadId = body.uploadId
    if (typeof uploadId !== 'string' || uploadId.length === 0) {
      return json(res, 400, { error: 'missing uploadId' })
    }
    const parts = partCount(body.parts)
    if (parts === undefined) return json(res, 400, { error: 'invalid part count' })

    const upload = under(sub, ref, uploadId)
    if (upload === undefined) return json(res, 404, { error: 'no such upload' })

    const expiry = now() + URL_LIFETIME_MS
    const urls = Array.from({ length: parts }, (_unused, index) => index + 1).map(partNumber => ({
      partNumber,
      url: `${url.origin}/_part/${uploadId}/${partNumber}?e=${expiry}&s=${sign(uploadId, partNumber, expiry)}`,
    }))
    json(res, 200, { urls })
  }

  // `GET /uploads/{ref}/parts?uploadId= -> {parts: [n, ...]}`. Set-shaped, because the
  // authority's answer is: the part numbers it holds, and no byte offset anywhere.
  async function listParts(ref: string, url: URL, req: IncomingMessage, res: ServerResponse): Promise<void> {
    const sub = bearerSub(req)
    if (sub === undefined) return json(res, 401, { error: 'unauthenticated' })
    if (!validateRef(ref)) return json(res, 400, { error: 'invalid reference' })

    const uploadId = url.searchParams.get('uploadId')
    if (uploadId === null || uploadId.length === 0) {
      return json(res, 400, { error: 'missing uploadId' })
    }

    const upload = under(sub, ref, uploadId)
    if (upload === undefined) return json(res, 404, { error: 'no such upload' })
    json(res, 200, { parts: [...upload.stored.keys()].sort((a, b) => a - b) })
  }

  // `POST /uploads/{ref}/complete {uploadId} -> {etag}`, and the one refusal the plane
  // cannot make: a complete over a set that is not {1..N}. The stand-in knows N because
  // `create` was told it; the plane does not, and completes over whatever `ListParts`
  // returns. The body is the string `ControlPlaneWire.completed` reads as
  // `TransportError.incompleteUpload`.
  async function completeUpload(ref: string, req: IncomingMessage, res: ServerResponse): Promise<void> {
    const sub = bearerSub(req)
    if (sub === undefined) return json(res, 401, { error: 'unauthenticated' })
    if (!validateRef(ref)) return json(res, 400, { error: 'invalid reference' })

    const body = await readJson(req)
    const uploadId = body.uploadId
    if (typeof uploadId !== 'string' || uploadId.length === 0) {
      return json(res, 400, { error: 'missing uploadId' })
    }

    const upload = under(sub, ref, uploadId)
    if (upload === undefined) return json(res, 404, { error: 'no such upload' })

    const planned = upload.planned
    if (planned !== undefined) {
      const missing = Array.from({ length: planned }, (_unused, index) => index + 1).filter(
        part => !upload.stored.has(part),
      )
      if (missing.length > 0) return json(res, 400, { error: 'incomplete upload' })
    }
    upload.completes += 1
    json(res, 200, { etag: `"standin-${uploadId}-${upload.completes}"` })
  }

  // The data plane. A PUT on a URL this server issued, answered with a status and an ETag
  // header — which is as narrowly as the transport reads it (ADR-0007 §1, §5). Both
  // refusals are decided from the URL alone, before the body is read.
  //
  // A PUT for a part already stored is **accepted** and the earlier bytes are replaced.
  // That is the behaviour ADR-0001 wrote the invariant's weaker claim against, and the
  // reason a receipt is counted rather than the request refused: the counter is what makes
  // a re-send a number the negative control can read.
  async function receivePart(
    uploadId: string,
    partText: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const part = Number(partText)
    const expiry = Number(url.searchParams.get('e'))
    const presented = url.searchParams.get('s') ?? ''
    if (!Number.isInteger(part) || part < 1 || part > MAX_PART_NUMBER || !Number.isInteger(expiry)) {
      return refusePut(res)
    }
    // The signature covers the part number, so a URL presented for another part does not
    // verify — the refusal needs no record of which URL was issued for what.
    if (!verify(uploadId, part, expiry, presented)) return refusePut(res)
    if (now() > expiry) return refusePut(res)

    const body = await readBody(req)
    const hold = holds.get(part)

    if (hold?.mode === 'after-store') {
      store(uploadId, part, body)
      await hold.withheld
    } else if (hold?.mode === 'before-store') {
      await hold.withheld
      store(uploadId, part, body)
    } else {
      store(uploadId, part, body)
    }

    if (!uploads.has(uploadId)) return json(res, 404, { error: 'no such upload' })
    res.writeHead(200, { etag: `"standin-${uploadId}-${part}"` })
    res.end()
  }

  function store(uploadId: string, part: number, body: Buffer): void {
    const upload = uploads.get(uploadId)
    if (upload === undefined) return
    upload.stored.set(part, body)
    upload.receipts.set(part, (upload.receipts.get(part) ?? 0) + 1)
  }

  // The honesty controls, on a prefix the production plane never has. **No transport code
  // path knows this prefix exists**: the transport speaks the four routes and the signed
  // PUT, `ControlPlaneWire` names no `_standin` path, and the only clients are the vitest
  // suite and, from commit 8, the UI test.
  async function standInControl(
    method: string,
    path: readonly string[],
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    if (method === 'POST' && path[1] === 'reset' && path.length === 2) {
      uploads.clear()
      // A held answer whose upload has been forgotten is a socket nothing would ever
      // answer, so reset releases as well as forgets. The PUT then finds no upload and
      // answers 404, which is the honest answer for bytes with nowhere to land.
      for (const hold of holds.values()) hold.release()
      holds.clear()
      return json(res, 200, { reset: true })
    }
    if (method === 'GET' && path[1] === 'uploads' && path.length === 2) {
      return json(res, 200, {
        uploads: [...uploads.entries()].map(([uploadId, upload]) => ({ uploadId, key: upload.key })),
      })
    }
    if (method === 'GET' && path[1] === 'uploads' && path.length === 3) {
      const upload = uploads.get(path[2])
      if (upload === undefined) return json(res, 404, { error: 'no such upload' })
      // `puts` counts receipts — one per PUT stored for a `(uploadId, part)`, including
      // one that replaced bytes already held. A re-send is therefore a number a test
      // reads, and never an inference from timing or from a log line.
      return json(res, 200, {
        puts: Object.fromEntries([...upload.receipts.entries()].map(([part, count]) => [String(part), count])),
        completes: upload.completes,
        held: [...holds.keys()].sort((a, b) => a - b),
      })
    }
    if (method === 'POST' && path[1] === 'hold' && path.length === 2) {
      const body = await readJson(req)
      const part = partCount(body.part)
      const mode = body.mode
      if (part === undefined || (mode !== 'after-store' && mode !== 'before-store')) {
        return json(res, 400, { error: 'a hold names a part and one of after-store, before-store' })
      }
      let release = (): void => {}
      const withheld = new Promise<void>(resolve => {
        release = resolve
      })
      holds.set(part, { mode, withheld, release })
      return json(res, 200, { held: [...holds.keys()].sort((a, b) => a - b) })
    }
    if (method === 'POST' && path[1] === 'release' && path.length === 2) {
      const body = await readJson(req)
      const part = partCount(body.part)
      if (part === undefined) return json(res, 400, { error: 'a release names a part' })
      holds.get(part)?.release()
      holds.delete(part)
      return json(res, 200, { held: [...holds.keys()].sort((a, b) => a - b) })
    }
    json(res, 404, { error: 'no such control' })
  }

  // The uploadId, and the key it was opened under. `sub` first and then the reference, as
  // `objectKey` composes it, so one caller's uploadId is never found under another
  // caller's prefix.
  function under(sub: string, ref: string, uploadId: string): Upload | undefined {
    const upload = uploads.get(uploadId)
    return upload !== undefined && upload.key === objectKey(sub, ref) ? upload : undefined
  }

  function sign(uploadId: string, part: number, expiry: number): string {
    return createHmac('sha256', secret).update(`${uploadId}/${part}/${expiry}`).digest('hex')
  }

  function verify(uploadId: string, part: number, expiry: number, presented: string): boolean {
    const expected = Buffer.from(sign(uploadId, part, expiry))
    const given = Buffer.from(presented)
    return expected.length === given.length && timingSafeEqual(expected, given)
  }

  return server
}

// 403, with no body. The transport reads the status and nothing else (ADR-0007 §5), and a
// body here would be a shape this repository has not declared.
function refusePut(res: ServerResponse): void {
  res.writeHead(403)
  res.end()
}

// The bearer token **is** the `sub`. There is no verification, deliberately: see the
// header comment. An absent or empty token is the case `verifiedSub` answers `undefined`
// for, and the route answers it 401 exactly as the handler does.
function bearerSub(req: IncomingMessage): string | undefined {
  const header = req.headers.authorization
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return undefined
  const sub = header.slice('Bearer '.length)
  return sub.length > 0 ? sub : undefined
}

// A count, read the way `urls.ts` reads `parts`: an integer in 1...10000 or nothing. Out
// of range is not clamped — a clamp hands back fewer authorities than the caller asked for
// without saying so.
function partCount(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= MAX_PART_NUMBER
    ? value
    : undefined
}

async function readBody(req: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = []
  for await (const chunk of req) chunks.push(chunk as Buffer)
  return Buffer.concat(chunks)
}

// A body that is not JSON, or is not an object, carries no field — which is the reading
// every handler takes of the same case, and it is why a malformed request is a 400 here
// and not a 500.
async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const raw = (await readBody(req)).toString('utf8')
  if (raw.length === 0) return {}
  try {
    const parsed: unknown = JSON.parse(raw)
    return typeof parsed === 'object' && parsed !== null ? (parsed as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

function json(res: ServerResponse, statusCode: number, body: unknown): void {
  res.writeHead(statusCode, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}

function flag(argv: readonly string[], name: string): string | undefined {
  const index = argv.indexOf(name)
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : undefined
}

// The bundle's entry. `--port 0`, or no `--port` at all, binds a port the operating system
// assigns and prints it, which is what commit 8's job reads. `--bind 0.0.0.0` is the device
// harness's, where an operator types the Mac's address into the app (spec §3.4).
function main(argv: readonly string[]): void {
  const bind = flag(argv, '--bind') ?? '127.0.0.1'
  const port = Number(flag(argv, '--port') ?? '0')
  const server = createStandIn()
  server.listen(port, bind, () => {
    console.log(`listening on http://${bind}:${(server.address() as AddressInfo).port}`)
  })
}

// True in the bundle, which is run as a program, and false under vitest, which imports
// this file as a module and starts the server itself on a port it asks for. `typeof` on
// both, because neither identifier exists in an ES module.
if (typeof require !== 'undefined' && typeof module !== 'undefined' && require.main === module) {
  main(process.argv.slice(2))
}
