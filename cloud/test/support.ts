import type { APIGatewayProxyEventV2WithJWTAuthorizer } from 'aws-lambda'
import { objectKey, verifiedSub } from '../handlers/identity'

// Not a `*.test.ts` file, and vitest.config.mts includes only `test/**/*.test.ts`, so this
// is imported by suites rather than collected as one. Nothing here asserts; a name in this
// file shaped like a test name would be a name docs/invariants.md is then asked to carry
// for a test that does not exist.

// One fixture, two request shapes. ADR-0006 §4 gives `POST /uploads` the reference in the
// body and gives `/uploads/{ref}/parts` and `/uploads/{ref}/complete` the same reference in
// the path, so this sets both from one argument. A fixture that set only one would exercise
// one handler and quietly pass over the other two.
//
// `sub: undefined` models a verified token that carries no `sub` claim, not a route with no
// authorizer: the authorizer ran, `claims` is present, and the claim the key would be built
// from is missing. That is the case spec §5 calls a 401 rather than a default.
export function event(args: {
  sub?: string
  ref: string
  body?: Record<string, unknown>
}): APIGatewayProxyEventV2WithJWTAuthorizer {
  const claims: { [name: string]: string } = args.sub === undefined ? {} : { sub: args.sub }
  return {
    version: '2.0',
    routeKey: 'POST /uploads',
    rawPath: `/uploads/${args.ref}`,
    rawQueryString: '',
    headers: { 'content-type': 'application/json' },
    queryStringParameters: {},
    pathParameters: { ref: args.ref },
    body: JSON.stringify({ ref: args.ref, ...args.body }),
    isBase64Encoded: false,
    // Fixed, not read from a clock. Nothing here depends on the values, and a fixture that
    // called `Date.now()` would put a wall clock in a suite that is not allowed one.
    requestContext: {
      accountId: '000000000000',
      apiId: 'api-under-test',
      domainName: 'api-under-test.execute-api.test.invalid',
      domainPrefix: 'api-under-test',
      http: {
        method: 'POST',
        path: `/uploads/${args.ref}`,
        protocol: 'HTTP/1.1',
        sourceIp: '198.51.100.1',
        userAgent: 'dunnage-test',
      },
      requestId: 'request-under-test',
      routeKey: 'POST /uploads',
      stage: '$default',
      time: '01/Sep/2026:00:00:00 +0000',
      timeEpoch: 1_788_220_800_000,
      authorizer: {
        principalId: args.sub ?? '',
        integrationLatency: 0,
        jwt: { claims, scopes: null },
      },
    },
  }
}

// The two steps a handler takes to reach a key, composed the way a handler composes them
// and with nothing between them: the principal from the verified token, the reference from
// the request. The reference is read the way `create` reads it — out of the body, which is
// where a caller could also put a `key`, a `sub` or a `userId` — so the composition under
// test is the one those fields would have to reach.
export function keyFor(e: APIGatewayProxyEventV2WithJWTAuthorizer): string | undefined {
  const sub = verifiedSub(e)
  if (sub === undefined) return undefined
  const ref = (JSON.parse(e.body ?? '{}') as { ref?: unknown }).ref
  return typeof ref === 'string' ? objectKey(sub, ref) : undefined
}
