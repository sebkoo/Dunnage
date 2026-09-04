import type { Answer } from './support'

// Not a `*.test.ts` file, and `vitest.config.mts` includes only `test/**/*.test.ts`, so
// this is imported by a suite rather than collected as one — `support.ts`'s position
// exactly.
//
// The other half of one instrument. `respond` in `support.ts` asks a handler and returns
// an `Answer`: the status and the `error` the body names. This asks the stand-in over HTTP
// and returns the same `Answer`, so the parity diff compares two sides measured the same
// way rather than two measurements that can drift apart. There is one `Answer` type and it
// lives in `support.ts`, where the first side already needed it.

export type Route = 'create' | 'urls' | 'parts' | 'complete'

// One argument set, four request shapes — ADR-0006 §4's table. `create` carries its
// reference in the body because the object it names does not exist yet; the other three
// carry it in the path. `parts` carries its uploadId in the query, because it is a GET.
// A field that is `undefined` is absent from the request, which is what the fixture
// "a body without an uploadId" has to mean.
export type RouteArgs = {
  readonly sub?: string
  readonly ref: string
  readonly uploadId?: string
  readonly parts?: number
}

export async function ask(base: string, route: Route, args: RouteArgs): Promise<Answer> {
  // The bearer token is the `sub` (spec §3.1). No token at all is the request the plane's
  // side makes with no `sub` claim: the authorizer's answer is what is missing in both.
  const headers: Record<string, string> = { 'content-type': 'application/json' }
  if (args.sub !== undefined) headers.authorization = `Bearer ${args.sub}`

  const body: Record<string, unknown> = {}
  if (args.uploadId !== undefined) body.uploadId = args.uploadId
  if (args.parts !== undefined) body.parts = args.parts

  // Percent-encoded per segment. For a reference the grammar admits this is the identity —
  // `[0-9A-Za-z._-]` has nothing a path escapes — and `ControlPlaneWire` therefore sends
  // one unencoded. It is here for the reference the grammar rejects: `../etc` written
  // into a path is resolved away by any URL parser before the server sees it, and the
  // fixture would then be asking the stand-in a question nobody asked the plane.
  const ref = encodeURIComponent(args.ref)

  const [url, init] = ((): [string, RequestInit] => {
    switch (route) {
      case 'create':
        return [`${base}/uploads`, { method: 'POST', headers, body: JSON.stringify({ ref: args.ref, ...body }) }]
      case 'urls':
        return [`${base}/uploads/${ref}/urls`, { method: 'POST', headers, body: JSON.stringify(body) }]
      case 'parts': {
        const query = args.uploadId === undefined ? '' : `?uploadId=${encodeURIComponent(args.uploadId)}`
        return [`${base}/uploads/${ref}/parts${query}`, { method: 'GET', headers }]
      }
      case 'complete':
        return [`${base}/uploads/${ref}/complete`, { method: 'POST', headers, body: JSON.stringify(body) }]
    }
  })()

  const res = await fetch(url, init)
  const rendered = await res.text()
  // The refusal's own reason, read out of the body exactly as `respond` reads it out of a
  // handler's. A status code alone does not say which guard produced it, and on three of
  // the four routes two guards answer 400.
  let reason: unknown
  try {
    reason = (JSON.parse(rendered) as { error?: unknown }).error
  } catch {
    reason = undefined
  }
  // `rendered` is the response body as it arrived. The parity diff never reads it — the
  // two sides render different things by construction, a `statusCode` and a body here, an
  // `APIGatewayProxyStructuredResultV2` there — and it is filled rather than left empty
  // because `Answer` is one shape and a field that lied would be worse than one nothing
  // compares.
  return { statusCode: res.status, reason, rendered }
}
