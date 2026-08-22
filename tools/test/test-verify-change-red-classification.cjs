// tools/test/test-verify-change-red-classification.cjs

/**
 * A red result is evidence of an outcome, not automatically evidence that the
 * current diff caused it. Pin the three-way classification used by the
 * change-scoped diagnostic mode.
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

const { classifyGateResult } = require(path.resolve(__dirname, 'verify-change.cjs'));

let result = classifyGateResult('js', { status: 1 }, true);
assert.equal(result.kind, 'candidate-regression');
assert.equal(result.blockingInDiagnosis, true);

result = classifyGateResult('js', { status: 1 }, false);
assert.equal(result.kind, 'baseline-or-history');
assert.equal(result.blockingInDiagnosis, false);

result = classifyGateResult('js', { status: null, error: new Error('spawn failed') }, true);
assert.equal(result.kind, 'environment-failure');
assert.equal(result.blockingInDiagnosis, true);

result = classifyGateResult('ahk-suite', { skipped: 'interpreter absent' }, true);
assert.equal(result.kind, 'environment-deferral');
assert.equal(result.blockingInDiagnosis, false);

result = classifyGateResult('js', { status: 0 }, true);
assert.equal(result.kind, 'pass');

console.log('verify-change red classification: ok');
