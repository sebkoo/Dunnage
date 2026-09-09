import { App } from 'aws-cdk-lib'
import { Template } from 'aws-cdk-lib/assertions'
import { describe, expect, test } from 'vitest'
import { DunnageStack } from '../lib/stack'

// ADR-0010 §3. Nothing in the template says what a deploy produced, and the procedure needs
// four values to address the stack it has just created. They are outputs rather than prose
// because prose in this repository may not carry them: ADR-0010 §4 forbids an operator writing
// an endpoint or a pool identifier into a tracked file, so a deploy's own report is the only
// place those values are allowed to appear.
//
// Both halves are asserted together because either alone passes on a broken stack. Four
// outputs that do not exist cannot be caught carrying a literal, and four values that are
// references establish nothing if they are not the four the procedure reads by name.

// The four names the procedure reads, written here as the assertion's subject rather than
// derived from the template. A test that asked the template which outputs it declares would
// agree with whatever set it found, including the empty one.
const REPORTED = ['ApiEndpoint', 'BucketName', 'UserPoolId', 'UserPoolClientId'] as const

describe('a deploy reports the four values the procedure needs, and names no environment doing it', () => {
  test('testTheFourValuesADeployReportsExistByNameAndEachIsAReference', () => {
    const outputs = Template.fromStack(new DunnageStack(new App(), 'Dunnage')).findOutputs('*')

    const missing = REPORTED.filter(name => outputs[name] === undefined)

    // A literal arrives as a rendered string. CloudFormation resolves `Ref` and `Fn::GetAtt`
    // into objects, so a value this machine wrote down is a bare string and a value the deploy
    // resolves is not. Scanned over every output the stack declares rather than over the four:
    // the count below already refuses a fifth, and scanning all of them means a fifth carrying
    // a literal is named in the same red as the count instead of hiding behind it.
    const literals = Object.entries(outputs)
      .filter(([, output]) => typeof output.Value === 'string')
      .map(([name, output]) => `${name} is the literal ${String(output.Value)}`)

    expect({ declared: Object.keys(outputs).length, missing, literals })
      .toEqual({ declared: REPORTED.length, missing: [], literals: [] })
  })
})
