import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { App, Stack, Token } from 'aws-cdk-lib'
import { Template } from 'aws-cdk-lib/assertions'
import { transformSync } from 'esbuild'
import { describe, expect, test } from 'vitest'
import { DunnageStack } from '../lib/stack'

// Claim 1. Everything below is read off a template this machine produced, or off the sources
// that produced it. Nothing here is deployed, so none of it is evidence about any AWS
// account: a synthesised template is a document, and the properties asserted are properties
// of that document and of the repository that generates it.

const ROOT = join(__dirname, '..')

// The stack's own sources, and nothing else. The narrowness is the assertion's, not an
// oversight:
//   test/          this file writes `fromLookup`, `ContextProvider`, `NodejsFunction` and
//                  `aws-lambda-nodejs` out in its own patterns, so a scan that reached test/
//                  would fail against itself — and the first repair anyone reaches for is to
//                  weaken the pattern until it stops matching.
//   dist/          the built asset is a copy of handlers/. It adds no source and doubles
//                  every match.
//   node_modules/  aws-cdk-lib ships the string `aws-lambda-nodejs` inside its own tree.
const SOURCE_DIRS = ['bin', 'lib', 'handlers'] as const

type SourceFile = readonly [path: string, text: string]

// Comments are stripped before anything is matched, by the same esbuild that builds the
// asset. The assertion is about what a source *does*, not about what it says: `lib/stack.ts`
// explains in prose why it refuses `NodejsFunction` and why a `fromLookup` would make claim 1
// false, and a scan over raw text reads that explanation as the violation it warns against.
// The two repairs that suggest themselves are both wrong. Weakening the pattern until it
// stops matching is the failure this file's own narrowness was written to avoid, and deleting
// the explanation from the stack removes the reason the code is the way it is. Stripping
// comments makes the scan read the code, which is what it always claimed to be reading.
function sources(): readonly SourceFile[] {
  return SOURCE_DIRS.flatMap(dir =>
    readdirSync(join(ROOT, dir))
      .filter(name => name.endsWith('.ts'))
      .map(name => {
        const text = readFileSync(join(ROOT, dir, name), 'utf8')
        return [`${dir}/${name}`, transformSync(text, { loader: 'ts' }).code] as const
      }),
  )
}

// Every source that matches any forbidden pattern, named with the pattern that caught it —
// collected rather than asserted one at a time, so one red names every file and every
// pattern. A scan that read nothing is itself reported: an empty scan asserts nothing and
// would otherwise pass green forever.
function sourcesMatching(forbidden: readonly RegExp[]): readonly string[] {
  const files = sources()
  if (files.length === 0) return ['no sources were read — the scan matched no file, and an empty scan asserts nothing']
  return files.flatMap(([path, text]) => forbidden.filter(pattern => pattern.test(text)).map(pattern => `${path} matches ${pattern}`))
}

// Synthesised once. `Template.fromStack` is called inside a test and never at module scope:
// `vitest list` imports this file to collect it, and a stack constructed during collection
// would stage the Lambda asset before `npm run build` has necessarily run.
let synthesised: { readonly stack: Stack; readonly template: Template } | undefined

function stackAndTemplate(): { readonly stack: Stack; readonly template: Template } {
  if (synthesised === undefined) {
    const stack = new DunnageStack(new App(), 'Dunnage')
    synthesised = { stack, template: Template.fromStack(stack) }
  }
  return synthesised
}

describe('the stack synthesises without an account, a region or a credential', () => {
  test('testTheStackSynthesisesWithNoAccountNoRegionAndNoCredential', () => {
    const rendered = JSON.stringify(stackAndTemplate().template.toJSON())
    // A twelve-digit run bounded by non-word characters is an account number written out.
    // Asset hashes are hex, so a digit run inside one is adjacent to a hex letter and does
    // not bound.
    const accountLiterals = rendered.match(/\b\d{12}\b/g) ?? []
    expect({ synthesised: rendered.length > 0, accountLiterals }).toEqual({ synthesised: true, accountLiterals: [] })
  })

  test('testTheStackDeclaresNoEnvironmentAndLooksNothingUp', () => {
    const { stack } = stackAndTemplate()
    const pinned = ([['account', stack.account], ['region', stack.region]] as const)
      .filter(([, value]) => !Token.isUnresolved(value))
      .map(([name, value]) => `${name} is pinned to ${value}`)
    const lookups = sourcesMatching([/\bfromLookup\b/, /\bContextProvider\b/])
    expect({ pinned, lookups }).toEqual({ pinned: [], lookups: [] })
  })

  test('testTheLambdaCodeIsAPrebuiltAssetAndNothingBundlesDuringSynth', () => {
    const bundlers = sourcesMatching([/aws-lambda-nodejs/, /\bNodejsFunction\b/])
    const functions = Object.entries(stackAndTemplate().template.findResources('AWS::Lambda::Function'))
    const notAnAsset = functions.length === 0
      ? ['the template declares no AWS::Lambda::Function — this assertion read nothing']
      : functions.filter(([, resource]) => resource.Properties?.Code?.S3Key === undefined).map(([id]) => id)
    expect({ bundlers, notAnAsset }).toEqual({ bundlers: [], notAnAsset: [] })
  })

  // Recorded, not guessed. The synth was run first and the issuer rendered as
  // `{"Fn::GetAtt": ["Users…", "ProviderURL"]}` — the user pool's own attribute, resolved by
  // CloudFormation at deploy time. So `userPool.userPoolProviderUrl` does survive an
  // environment-agnostic stack, and the plan's fallback of building the issuer out of
  // `Aws.REGION` is not needed. A literal region here would make claim 1 false: the stack
  // would name an environment, which is the precondition every lookup needs.
  //
  // The logical id is not asserted. It carries a hash of the construct path, so pinning it
  // would make this test fail on a rename that changes nothing it is about.
  test('testTheJWTIssuerRendersAsATokenAndNotALiteralRegion', () => {
    const authorizers = Object.values(stackAndTemplate().template.findResources('AWS::ApiGatewayV2::Authorizer'))
    // Every issuer that is wrong, with the reason, rather than the first one — `expect`
    // throws, and one authorizer today is not a reason to write an assertion that would hide
    // the second.
    const wrong = authorizers.flatMap((resource): readonly string[] => {
      const issuer: unknown = resource.Properties?.JwtConfiguration?.Issuer
      if (typeof issuer === 'string') return [`the issuer is the literal string ${issuer}`]
      const rendered = JSON.stringify(issuer)
      if (/[a-z]{2}-[a-z]+-\d/.test(rendered)) return [`the issuer names a region: ${rendered}`]
      const attribute = (issuer as { readonly 'Fn::GetAtt'?: readonly unknown[] })['Fn::GetAtt']
      return attribute?.[1] === 'ProviderURL' ? [] : [`the issuer is not the pool's ProviderURL: ${rendered}`]
    })
    expect({ count: authorizers.length, wrong }).toEqual({ count: 1, wrong: [] })
  })

  // ADR-0006 §4a's open item, closed by an assertion rather than by care. Nothing in this
  // phase deploys, so a stack that set `BUCKET_NAME` beside handlers reading `BUCKET` would
  // synthesise green and fail at the first real request in 4b. This reads the name out of
  // `handlers/` and out of the template and compares them, which is the only mechanism in the
  // repository that can see the two drift apart.
  //
  // The set of names is asserted, not a single name assumed. A handler that started reading a
  // second variable would change the set, and the test would report that rather than pass on
  // the one name it was looking for — which is why `handlers/urls.ts` takes an already-built
  // client instead of sourcing a region and a credential pair from the environment.
  test('testEveryHandlerFunctionIsHandedTheBucketUnderTheNameItsHandlerReads', () => {
    const read = [
      ...new Set(
        sources()
          .filter(([path]) => path.startsWith('handlers/'))
          .flatMap(([, text]) => [...text.matchAll(/process\.env\.([A-Za-z_][A-Za-z0-9_]*)/g)].map(match => match[1])),
      ),
    ]
    // The four functions this stack declares, identified by the entry point each is given. The
    // fifth `AWS::Lambda::Function` in the template is CDK's auto-delete-objects provider,
    // which reads none of these and is not this assertion's subject.
    const entryPoints = ['create', 'parts', 'complete', 'urls']
    const ours = Object.entries(stackAndTemplate().template.findResources('AWS::Lambda::Function'))
      .filter(([, resource]) => entryPoints.some(entry => resource.Properties?.Handler === `${entry}.handler`))
    const missing = ours.flatMap(([id, resource]) => {
      const handed = Object.keys(resource.Properties?.Environment?.Variables ?? {})
      return read.filter(name => !handed.includes(name)).map(name => `${id} is not handed ${name}`)
    })
    expect({ read, functions: ours.length, missing }).toEqual({ read: ['BUCKET'], functions: 4, missing: [] })
  })
})
