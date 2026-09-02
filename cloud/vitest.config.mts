import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    // The first test in each file that synthesises pays for `Template.fromStack`, which
    // stages and fingerprints the `dist/handlers` asset — four esbuild bundles totalling
    // 5.37 MB. Measured at 1.5-2.5 s on a ten-core machine, and slower on CI, where the
    // step runs immediately after `npm run build` and two synthesising files contend for
    // fewer cores. Vitest's default ceiling is 5 s, which that has already crossed under
    // load: a run of this suite reported two failures, and both were the first test of a
    // synthesising file timing out rather than asserting anything.
    //
    // 30 s is a ceiling against a hang, not a budget. Nothing here is allowed to take that
    // long, and no assertion changes because of it — a timeout is a property of the
    // harness, not an invariant of the library, and the tests assert exactly what they
    // asserted before.
    testTimeout: 30_000,
  },
})
