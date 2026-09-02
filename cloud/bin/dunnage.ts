#!/usr/bin/env node
import { App } from 'aws-cdk-lib'
import { DunnageStack } from '../lib/stack'

// `npm run build` compiles this file to `dist/app.js` with the esbuild that already builds
// the handler asset, and `cdk.json` runs `node dist/app.js`. No TypeScript loader is
// installed: `ts-node` cannot run under the pinned `typescript` 7.0.2 at all — TypeScript 7's
// main entry no longer exposes the legacy compiler API, `ts.sys` is undefined, and ts-node
// reads it during bootstrap and throws before compiling anything. Adding `tsx` would have
// meant a new pin for a job the pinned esbuild already does.
//
// The app is bundled with `--packages=external`, so `aws-cdk-lib` and `constructs` stay
// required from `node_modules` and only this file and `lib/stack.ts` are transpiled into it.
// Bundling the library in would break it: aws-cdk-lib resolves its vendored custom-resource
// handlers relative to `__dirname`, and the auto-delete-objects handler this stack uses is
// one of them. `dist/app.js` is 3.1kb for that reason, and the asset the bucket's
// auto-delete provider points at is CDK's own file rather than a copy this build made.
//
// This is compilation, not synth-time bundling: it happens in `npm run build` before `cdk`
// is invoked at all, so claim 1's "nothing bundles during synth" is untouched by it.

// No `env`, and that absence is the whole of claim 1's first property. An `env` fixes an
// account and a region, which is the precondition every context lookup needs — ADR-0006 §8.
// Nothing here reads a profile, a metadata endpoint or a credential file, so `cdk synth` on a
// machine with none of them produces the same template as `cdk synth` on a machine with all
// of them.
const app = new App()
new DunnageStack(app, 'Dunnage')
