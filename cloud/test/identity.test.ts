import { describe, expect, test } from 'vitest'
import { validateRef } from '../handlers/identity'

describe('validateRef', () => {
  // One assertion over every case, not an assertion inside a loop. `expect` throws, so a
  // loop reports the first failure and hides the seven behind it — and this red is the
  // evidence for the commit. Filtering names every ref that misbehaved, in one diff.
  // Every one of them is refused, and there is no repaired form to return: sanitising maps
  // two distinct refs onto one key, so two uploads become one object.
  test('testARefThatIsNotALeafInTheCallersOwnPrefixIsRefusedRatherThanRepaired', () => {
    const refs = ['../', '..', '%2e%2e', 'a/b', '/a', '.hidden', '', 'x'.repeat(65)]
    expect(refs.filter(ref => validateRef(ref))).toEqual([])
  })

  // The rule this asserts is ADR-0006 §2, not a property of the regex it happens to be
  // written next to. `parseSession` in 4b splits a TransportSessionID on the first '/',
  // and that parse is total only because a ref can never contain one. Swift, another
  // suite, another phase: nothing but this test connects them.
  test('testARefContainingASeparatorIsRefused', () => {
    expect(['a/b', 'a/', '/', 'a/b/c'].filter(ref => validateRef(ref))).toEqual([])
  })

  test('testARefAtTheGrammarsBoundariesIsAccepted', () => {
    const refs = ['a', '0', 'x'.repeat(64), 'a.b_c-1']
    expect(refs.filter(ref => !validateRef(ref))).toEqual([])
  })
})
