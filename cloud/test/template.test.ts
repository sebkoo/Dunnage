import { App } from 'aws-cdk-lib'
import { Template } from 'aws-cdk-lib/assertions'
import { describe, expect, test } from 'vitest'
import { DunnageStack } from '../lib/stack'

// Claim 2's first half — "a device holds no principal and no standing grant on the bucket" —
// read off a template this machine produced. Nothing here is deployed, so none of it is
// evidence about any AWS account: a synthesised template is a document, and what is asserted
// is a property of that document.
//
// None of the three can go red without sabotaging the stack, and none was made to. There is no
// identity pool to remove, no role trusted by anything but a service, and no `Allow` on the
// bucket naming a principal this template does not define. Adding one to watch a test fail
// would be manufacturing a failure, which this repository refuses; the commit body says so
// rather than a red run standing in for it.

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
  // 5's wording is a question about actions, and it belongs to the commit that lands claim 5.
  // Widening this assertion to read actions, or narrowing it to skip the provider role, would
  // each take that decision quietly inside this one.
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
