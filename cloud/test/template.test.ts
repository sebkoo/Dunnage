import { App } from 'aws-cdk-lib'
import { Template } from 'aws-cdk-lib/assertions'
import { describe, expect, test } from 'vitest'
import { DunnageStack } from '../lib/stack'

// The assertions read off a template this machine produced, and the two claims they serve.
// Claim 2's first half — "a device holds no principal and no standing grant on the bucket" —
// is the first `describe`; claim 5 — "the control plane holds nothing its routes do not use,
// and every principal that can enumerate parts is one this stack defines and no device can
// become" — is the second. They are in one file because they read the same document: the
// bucket policy's single `Allow` is claim 2's question about principals and claim 5's about
// actions, and a reader who finds one is entitled to find the other without opening a second
// file. Nothing here is deployed, so none of it is evidence about any AWS account: a
// synthesised template is a document, and what is asserted is a property of that document.
//
// Four of the six cannot go red without sabotaging the stack, and none was made to. There is
// no identity pool to remove, no role trusted by anything but a service, no `Allow` on the
// bucket naming a principal this template does not define, and no route that aborts. Adding
// one to watch a test fail would be manufacturing a failure, which this repository refuses;
// the commit body says so rather than a red run standing in for it. The other two — the
// per-role permission map and the holder set — went red genuinely in the commit that landed
// them, once before the grant was split and once after.

// Synthesised once, and inside a test rather than at module scope. `vitest list` imports this
// file to collect it, and a stack constructed during collection would stage the Lambda asset
// before `npm run build` has necessarily run — which is the property the CI comment above
// `npm run build` says the name-recording step depends on.
let synthesised: Template | undefined

function template(): Template {
  if (synthesised === undefined) {
    synthesised = Template.fromStack(new DunnageStack(new App(), 'Dunnage'))
  }
  return synthesised
}

// Every logical id a CloudFormation value points at, however deeply it is nested. A principal
// is `{"AWS": {"Fn::GetAtt": ["SomeRole", "Arn"]}}` today, and reading that one shape by hand
// would silently return nothing the day it is a `Ref`, a `Fn::Join` or a list — and returning
// nothing is what makes an assertion pass while reading past the thing it is about.
function referencedLogicalIds(value: unknown): readonly string[] {
  if (Array.isArray(value)) return value.flatMap(referencedLogicalIds)
  if (value === null || typeof value !== 'object') return []
  const record = value as Record<string, unknown>
  const attribute = record['Fn::GetAtt']
  if (Array.isArray(attribute) && typeof attribute[0] === 'string') return [attribute[0]]
  const reference = record['Ref']
  if (typeof reference === 'string') return [reference]
  return Object.values(record).flatMap(referencedLogicalIds)
}

describe('a device holds no principal and no standing grant on the bucket', () => {
  // A user pool and an app client, and no identity pool. That is the stronger form of the
  // claim: an identity pool is the only thing in Cognito that exchanges a token for AWS
  // credentials, so without one there is no role a device could assume at all, rather than a
  // narrow one it could.
  //
  // `resourceCountIs(…, 0)` is not the empty-scan defect that a filter-and-expect-empty would
  // be: it reds if an identity pool appears, and reads a count rather than a set it might have
  // failed to collect.
  test('testTheStackDeclaresNoIdentityPool', () => {
    template().resourceCountIs('AWS::Cognito::IdentityPool', 0)
  })

  // Every role this template declares is assumable by an AWS service and by nothing else. A
  // `Federated` principal is how a web identity — a Cognito identity pool, an OIDC provider —
  // becomes an assumable role, and an `AWS` principal is how an account or a user does; either
  // one appearing in a trust policy is a role something outside this stack could take on.
  //
  // Collected and asserted once, never an `expect` inside the loop: `expect` throws, so a run
  // in which two roles were wrong would name the first and hide the second. A scan that read no
  // role at all reports itself, because an empty scan asserts nothing and would otherwise pass
  // green forever.
  test('testEveryRoleInTheTemplateIsAssumableOnlyByAnAWSService', () => {
    const roles = Object.entries(template().findResources('AWS::IAM::Role'))
    const wrong = roles.flatMap(([id, resource]): readonly string[] => {
      const statements: unknown = resource.Properties?.AssumeRolePolicyDocument?.Statement
      if (!Array.isArray(statements) || statements.length === 0) {
        return [`${id} has no trust policy statement this assertion could read`]
      }
      return statements.flatMap((statement: unknown): readonly string[] => {
        const principal = (statement as { readonly Principal?: Record<string, unknown> }).Principal
        if (principal === undefined) return [`${id} has a trust statement with no principal`]
        const offending = ['Federated', 'AWS', 'CanonicalUser'].filter(key => key in principal)
        if (offending.length > 0) return [`${id} is assumable by ${offending.join(' and ')}: ${JSON.stringify(principal)}`]
        return 'Service' in principal ? [] : [`${id} names no service principal: ${JSON.stringify(principal)}`]
      })
    })
    expect({ roles: roles.length > 0, wrong }).toEqual({ roles: true, wrong: [] })
  })

  // `Allow` statements only. `enforceSSL` adds a `Deny` on `Principal: {"AWS": "*"}`, and a
  // blanket "no `*` principal" assertion would either fail on that or be loosened until it
  // asserted nothing.
  //
  // What this asserts is what its name says: every `Allow` on the bucket names a role this
  // template defines, so there is no standing grant to an account, a user, or anyone outside
  // this stack — which is the half of claim 2 about grants. It says nothing about which actions
  // an `Allow` carries, and that boundary is deliberate. The auto-delete provider's role holds
  // `s3:List*` here, which matches `s3:ListMultipartUploadParts`; whether that contests claim
  // 5's wording is a question about actions, and
  // `testEveryPrincipalThatCanEnumeratePartsIsOneThisStackDefines` below answers it. Widening
  // this assertion to read actions, or narrowing it to skip the provider role, would each take
  // that decision quietly inside this one.
  test('testEveryAllowInTheBucketPolicyNamesARoleThisStackDefines', () => {
    const defined = new Set(Object.keys(template().findResources('AWS::IAM::Role')))
    const policies = Object.entries(template().findResources('AWS::S3::BucketPolicy'))
    const allows = policies.flatMap(([id, resource]) => {
      const statements: unknown = resource.Properties?.PolicyDocument?.Statement
      return (Array.isArray(statements) ? statements : [])
        .map((statement: unknown, index: number) => ({ id, index, statement }))
        .filter(({ statement }) => (statement as { readonly Effect?: unknown }).Effect === 'Allow')
    })
    const granted = allows.flatMap(({ id, index, statement }): readonly string[] => {
      const principal = (statement as { readonly Principal?: unknown }).Principal
      const named = referencedLogicalIds(principal)
      const strangers = named.filter(logicalId => !defined.has(logicalId))
      if (named.length === 0) return [`${id} statement ${index} allows a principal that is not a role in this template: ${JSON.stringify(principal)}`]
      return strangers.map(logicalId => `${id} statement ${index} allows ${logicalId}, which this template does not define as a role`)
    })
    // The count is asserted, not merely the emptiness of the offender list. A policy that lost
    // its `Allow` statements, or a `Statement` key that was renamed, would leave nothing to
    // filter and this test would pass having read nothing at all.
    expect({ policies: policies.length, allows: allows.length, granted }).toEqual({ policies: 1, allows: 1, granted: [] })
  })
})

// Where a grant can live in this template, and what an action pattern means. IAM action
// patterns are not literals: `*` matches any run of characters, `?` matches one, and matching
// is case-insensitive. `s3:List*`, `s3:*` and `*` all match `s3:ListMultipartUploadParts`, and
// this template grants the enumeration permission under two of those spellings. A sweep over
// the template text finds the literal four times and misses the fifth grant entirely, which is
// exactly the case claim 5's holder test exists for.
function actionMatches(pattern: string, action: string): boolean {
  const expression = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')
  return new RegExp(`^${expression}$`, 'i').test(action)
}

// A CloudFormation value flattened to one line. A resource is
// `{"Fn::Join": ["", [{"Fn::GetAtt": ["Uploads…", "Arn"]}, "/uploads/*"]]}`, and a diff over
// that structure buries the two things the assertion is about — which bucket, and which key
// prefix — under the shape they arrived in. Rendered, it is `${Uploads….Arn}/uploads/*`, and
// both halves are readable on one line.
function renderedValue(value: unknown): string {
  if (typeof value === 'string') return value
  if (Array.isArray(value)) return value.map(renderedValue).join('')
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  const record = value as Record<string, unknown>
  const attribute = record['Fn::GetAtt']
  if (Array.isArray(attribute)) return `\${${attribute.map(String).join('.')}}`
  const reference = record['Ref']
  if (typeof reference === 'string') return `\${${reference}}`
  const join = record['Fn::Join']
  if (Array.isArray(join) && join.length === 2) {
    return asList(join[1]).map(renderedValue).join(String(join[0]))
  }
  const substitution = record['Fn::Sub']
  if (typeof substitution === 'string') return substitution
  return JSON.stringify(value)
}

// `Action`, `Resource` and `Policies` are each a single value or a list depending on what was
// written, and the bucket policy in this template uses both spellings in adjacent statements:
// its `Deny` names one action as a string and its `Allow` names four as a list.
function asList(value: unknown): readonly unknown[] {
  return Array.isArray(value) ? value : value === undefined ? [] : [value]
}

interface Statement {
  readonly Effect?: unknown
  readonly Action?: unknown
  readonly Principal?: unknown
  readonly Condition?: unknown
  readonly Resource?: unknown
}

// One grant: a principal, the action patterns it was given, and the resources they are scoped
// to. A statement naming several principals becomes several of these.
interface Grant {
  readonly holder: string
  readonly actions: readonly string[]
  readonly resources: readonly string[]
}

interface TemplateGrants {
  readonly roles: readonly string[]
  readonly identityStatements: number
  readonly bucketPolicyStatements: number
  readonly identity: readonly Grant[]
  readonly resource: readonly Grant[]
  readonly denies: readonly string[]
  readonly allowsCarryingACondition: readonly string[]
  readonly invertedStatements: readonly string[]
  readonly managedPolicies: Record<string, readonly string[]>
}

// Every statement in this template that can grant an S3 action to a principal, read once and
// counted as it is read. Two places, not one: a role holds an action through the statements
// attached to it — an inline `Policies` entry, or an `AWS::IAM::Policy` whose `Roles` names it
// — and a principal holds one through the bucket policy's `Allow`. This template puts nothing
// inline at all, so a reader that stopped at `AWS::IAM::Role`'s `Policies` would return an
// empty set and report success having read nothing, and CDK's auto-delete provider holds no S3
// action in its role at all and reaches the bucket only through the bucket policy.
//
// Trust policies are out of scope deliberately. `AssumeRolePolicyDocument` says who may become
// a role rather than what a role may do, and it is claim 2's
// `testEveryRoleInTheTemplateIsAssumableOnlyByAnAWSService` that reads it.
function templateGrants(): TemplateGrants {
  const roleResources = template().findResources('AWS::IAM::Role')
  const roles = Object.keys(roleResources).sort()
  const attachedPolicies = Object.entries(template().findResources('AWS::IAM::Policy'))
  const bucketPolicies = Object.entries(template().findResources('AWS::S3::BucketPolicy'))

  const identityStatements: readonly { where: string; role: string; statement: Statement }[] = [
    ...roles.flatMap(role =>
      asList(roleResources[role].Properties?.Policies).flatMap((inline, i) =>
        asList((inline as { readonly PolicyDocument?: { readonly Statement?: unknown } })?.PolicyDocument?.Statement).map(
          (statement, j) => ({ where: `${role} inline policy ${i} statement ${j}`, role, statement: statement as Statement }),
        ),
      ),
    ),
    ...attachedPolicies.flatMap(([id, policy]) =>
      referencedLogicalIds(policy.Properties?.Roles).flatMap(role =>
        asList(policy.Properties?.PolicyDocument?.Statement).map((statement, j) => ({
          where: `${id} statement ${j}`,
          role,
          statement: statement as Statement,
        })),
      ),
    ),
  ]
  const bucketStatements = bucketPolicies.flatMap(([id, policy]) =>
    asList(policy.Properties?.PolicyDocument?.Statement).map((statement, j) => ({
      where: `${id} statement ${j}`,
      statement: statement as Statement,
    })),
  )

  const actionsOf = (statement: Statement): readonly string[] =>
    asList(statement.Action).filter((action): action is string => typeof action === 'string')
  const resourcesOf = (statement: Statement): readonly string[] => asList(statement.Resource).map(renderedValue)
  const conditionKeys = (statement: Statement): readonly string[] =>
    Object.values((statement.Condition ?? {}) as Record<string, unknown>).flatMap(operand =>
      Object.keys((operand ?? {}) as Record<string, unknown>),
    )
  const all = [...identityStatements, ...bucketStatements]

  return {
    roles,
    identityStatements: identityStatements.length,
    bucketPolicyStatements: bucketStatements.length,
    identity: identityStatements
      .filter(({ statement }) => statement.Effect === 'Allow')
      .map(({ role, statement }) => ({ holder: role, actions: actionsOf(statement), resources: resourcesOf(statement) })),
    // A principal that resolves to no logical id — a bare ARN, an account, `*` — is recorded by
    // its literal JSON and never dropped. Dropping it is how a grant to somebody outside this
    // template would leave the holder set exactly as it was.
    resource: bucketStatements
      .filter(({ statement }) => statement.Effect === 'Allow')
      .flatMap(({ statement }) => {
        const named = referencedLogicalIds(statement.Principal)
        const holders = named.length > 0 ? named : [JSON.stringify(statement.Principal ?? null)]
        return holders.map(holder => ({ holder, actions: actionsOf(statement), resources: resourcesOf(statement) }))
      }),
    denies: all
      .filter(({ statement }) => statement.Effect === 'Deny')
      .map(({ where, statement }) => {
        const conditions = conditionKeys(statement).join(', ') || 'no condition'
        return `${where} denies ${actionsOf(statement).join(', ')} under ${conditions}`
      }),
    allowsCarryingACondition: all
      .filter(({ statement }) => statement.Effect === 'Allow' && statement.Condition !== undefined)
      .map(({ where }) => where),
    invertedStatements: all.flatMap(({ where, statement }) => {
      const inverted = ['NotAction', 'NotPrincipal', 'NotResource'].filter(key => key in (statement as Record<string, unknown>))
      return inverted.length > 0 ? [`${where} uses ${inverted.join(' and ')}`] : []
    }),
    managedPolicies: Object.fromEntries(
      roles.map(role => [
        role,
        asList(roleResources[role].Properties?.ManagedPolicyArns).map(arn => {
          const rendered = renderedValue(arn)
          return rendered.slice(rendered.lastIndexOf('/') + 1)
        }),
      ]),
    ),
  }
}

// Which principals hold an action, in both places a grant can live, each named once and
// sorted. Sorted because `findResources` decides an order this assertion must not depend on.
function holdersOf(action: string): { readonly identity: readonly string[]; readonly resource: readonly string[] } {
  const grants = templateGrants()
  const held = (from: readonly Grant[]): readonly string[] =>
    [...new Set(from.filter(grant => grant.actions.some(pattern => actionMatches(pattern, action))).map(grant => grant.holder))].sort()
  return { identity: held(grants.identity), resource: held(grants.resource) }
}

// The logical ids CDK generated, read out of the synthesised template rather than written from
// memory. The suffix is a hash of the construct path, so renaming a construct reds every
// assertion below — which is the point of asserting sets rather than counts: a holder that
// changed identity is a holder somebody should look at.
const CREATE_ROLE = 'CreateFunctionServiceRole58157AB4'
const URLS_ROLE = 'UrlsFunctionServiceRole88710EC3'
const PARTS_ROLE = 'PartsFunctionServiceRole6966D38A'
const COMPLETE_ROLE = 'CompleteFunctionServiceRole670C4FA0'
const AUTO_DELETE_PROVIDER_ROLE = 'CustomS3AutoDeleteObjectsCustomResourceProviderRole3B1BD092'
const UPLOADS_PREFIX = '${Uploads4F6EB0FD.Arn}/uploads/*'

describe('the control plane holds nothing its routes do not use, and every principal that can enumerate parts is one this stack defines and no device can become', () => {
  // What each role holds, against what its own route uses. `create` calls
  // `CreateMultipartUpload`, `parts` calls `ListParts`, `complete` calls both, and `urls` calls
  // nothing at all — it signs a request the device makes, and a presigned URL carries the
  // authority of the principal that signed it, so the PUT is made with the `Urls` role's
  // permission. "Uses", not "calls", for exactly that reason: a name about calls would be false
  // of the one function whose grant is least obvious.
  //
  // The resource is asserted beside the actions rather than separately, because a permission is
  // an action on a resource and "holds only" means nothing without both. It is compared as a
  // rendered literal — `${bucket.Arn}/uploads/*` — so the logical id and the key prefix are
  // both readable in a diff, which is what the spec asks to be checked: not `s3:*`, not
  // `<bucket>/*`.
  //
  // The map is over every role the template declares, not over the four this claim is about.
  // The auto-delete provider holds no S3 action in its role, and saying so as an empty list is
  // a read rather than an omission; a fifth role that gained an identity grant would red here
  // instead of being absent from a four-row expectation.
  //
  // Two guards ride along, each stopping something this map cannot see on its own. The
  // `s3:PutObject` holder set is read across both policy shapes, because a per-role map built
  // from identity policies alone would reproduce for `s3:PutObject` the blind spot the sibling
  // test exists for: the bucket policy grants it to nobody today and nothing else would notice
  // if it did. And `ManagedPolicyArns` is pinned by name, because a managed policy's statements
  // are AWS's and are not in this template, so they cannot be expanded and read — attaching any
  // other managed policy reds this test rather than widening a role invisibly.
  //
  // This overlaps the holder test below deliberately. That one asks who else holds an action,
  // anywhere; this one asks how much a role holds. They are transposes on the identity side and
  // neither covers the other's edges — one reaches the bucket policy, the other reaches the
  // resource scoping and the actions no other test names.
  test('testEachFunctionRoleHoldsOnlyThePermissionsItsOwnRouteUses', () => {
    const grants = templateGrants()
    const permissions = Object.fromEntries(
      [...new Set([...grants.roles, ...grants.identity.map(grant => grant.holder)])].sort().map(role => {
        const held = grants.identity.filter(grant => grant.holder === role)
        return [
          role,
          {
            actions: [...new Set(held.flatMap(grant => grant.actions))].sort(),
            resources: [...new Set(held.flatMap(grant => grant.resources))].sort(),
          },
        ]
      }),
    )
    expect({
      scan: {
        roles: grants.roles.length,
        identityStatements: grants.identityStatements,
        bucketPolicyStatements: grants.bucketPolicyStatements,
      },
      permissions,
      managedPolicies: grants.managedPolicies,
      putObject: holdersOf('s3:PutObject'),
    }).toEqual({
      scan: { roles: 5, identityStatements: 4, bucketPolicyStatements: 2 },
      permissions: {
        [CREATE_ROLE]: { actions: ['s3:PutObject'], resources: [UPLOADS_PREFIX] },
        [URLS_ROLE]: { actions: ['s3:PutObject'], resources: [UPLOADS_PREFIX] },
        [PARTS_ROLE]: { actions: ['s3:ListMultipartUploadParts'], resources: [UPLOADS_PREFIX] },
        [COMPLETE_ROLE]: {
          actions: ['s3:ListMultipartUploadParts', 's3:PutObject'],
          resources: [UPLOADS_PREFIX],
        },
        [AUTO_DELETE_PROVIDER_ROLE]: { actions: [], resources: [] },
      },
      managedPolicies: {
        [CREATE_ROLE]: ['AWSLambdaBasicExecutionRole'],
        [URLS_ROLE]: ['AWSLambdaBasicExecutionRole'],
        [PARTS_ROLE]: ['AWSLambdaBasicExecutionRole'],
        [COMPLETE_ROLE]: ['AWSLambdaBasicExecutionRole'],
        [AUTO_DELETE_PROVIDER_ROLE]: ['AWSLambdaBasicExecutionRole'],
      },
      // Sorted, so the assertion does not depend on the order `findResources` returned.
      putObject: { identity: [COMPLETE_ROLE, CREATE_ROLE, URLS_ROLE], resource: [] },
    })
  })

  // Who can enumerate parts, in both places a grant can live, as an exact set. Not "no other
  // role holds it": a negative passes when the scan reads nothing, and this template gives that
  // failure a live shape — no role here carries an inline `Policies` at all, so a reader that
  // stopped at `AWS::IAM::Role` would return an empty offender list and report success. And not
  // a count, which the wrong two satisfy. A holder that arrives has to red this and make
  // somebody decide, which is what `s3:List*` did not do when it arrived inside
  // `autoDeleteObjects: true`.
  //
  // The resource half is the provider's role, and it stays. Removing `autoDeleteObjects` would
  // answer this by deleting the evidence; the provider genuinely holds the permission, and the
  // claim is true of it because it is a role this stack defines and no device can become it —
  // which is claim 2's `testEveryRoleInTheTemplateIsAssumableOnlyByAnAWSService`, not this.
  //
  // Three guards ride along. Exactly one `Deny` and it is enforceSSL's, because the computation
  // ignores `Deny` statements — a Deny grants nothing — and an exclusion that could hide a real
  // revocation is worse than no exclusion. No `Allow` carrying a `Condition`, because a holder
  // reported without its condition is a holder reported wrongly. And no statement inverting its
  // match with `NotAction`, `NotPrincipal` or `NotResource`, which reads `Action` and would
  // miss a grant of everything-but.
  test('testEveryPrincipalThatCanEnumeratePartsIsOneThisStackDefines', () => {
    const grants = templateGrants()
    expect({
      scan: {
        roles: grants.roles.length,
        identityStatements: grants.identityStatements,
        bucketPolicyStatements: grants.bucketPolicyStatements,
      },
      denies: grants.denies,
      allowsCarryingACondition: grants.allowsCarryingACondition,
      invertedStatements: grants.invertedStatements,
      holders: holdersOf('s3:ListMultipartUploadParts'),
    }).toEqual({
      scan: { roles: 5, identityStatements: 4, bucketPolicyStatements: 2 },
      denies: ['UploadsPolicy148F8199 statement 0 denies s3:* under aws:SecureTransport'],
      allowsCarryingACondition: [],
      invertedStatements: [],
      holders: {
        identity: [COMPLETE_ROLE, PARTS_ROLE],
        resource: [AUTO_DELETE_PROVIDER_ROLE],
      },
    })
  })

  // The first clause of claim 5 at zero: no route aborts, so nothing in the template may. The
  // name says "nothing in this template" and not "no role", because "no role" names the place a
  // grant was assumed to live rather than the property — the identical defect the sibling test
  // exists to have caught. Abort could arrive in a bucket policy exactly as `s3:List*` did.
  //
  // This cannot go red without sabotaging the stack, and no failure was manufactured. What
  // stops the emptiness from being vacuous is the two sibling tests: they assert non-empty
  // exact sets computed by this same function, so a matcher that matched nothing reds them
  // rather than passing here. The scan counts are asserted with it for the same reason, so the
  // empty set is a result and not a silence.
  test('testNothingInThisTemplateMayAbortAMultipartUpload', () => {
    const grants = templateGrants()
    expect({
      scan: {
        roles: grants.roles.length,
        identityStatements: grants.identityStatements,
        bucketPolicyStatements: grants.bucketPolicyStatements,
      },
      holders: holdersOf('s3:AbortMultipartUpload'),
    }).toEqual({
      scan: { roles: 5, identityStatements: 4, bucketPolicyStatements: 2 },
      holders: { identity: [], resource: [] },
    })
  })
})
