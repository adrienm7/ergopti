// tools/test/test-report.cjs

/**
 * ==============================================================================
 * MODULE: report.cjs parser self-test
 * DESCRIPTION:
 * Exercises report.cjs's format-agnostic parseResults against representative TAP
 * (AHK run_all.ahk) and Lua-runner output, so the unified reporter cannot
 * silently miscount or miss failures (which would let a red CI run look green).
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const { parseResults } = require('./report.cjs');

let checks = 0;
function check(label, cond) {
	assert.ok(cond, label);
	checks++;
}

// --- TAP, all green ---
let r = parseResults(['ok 1 - alpha', 'ok 2 - beta', '1..2', '# 2 passed, 0 failed'].join('\n'));
check('tap pass: format', r.format === 'tap');
check('tap pass: counts', r.passed === 2 && r.failed === 0);
check('tap pass: no failures', r.failures.length === 0);

// --- TAP, one failure (with diagnostic tail) ---
r = parseResults(['ok 1 - alpha', 'not ok 2 - beta gamma - boom expected', '# 1 passed, 1 failed'].join('\n'));
check('tap fail: counts', r.passed === 1 && r.failed === 1);
check('tap fail: failure captured', r.failures.length === 1 && r.failures[0] === 'beta gamma - boom expected');

// --- Lua, all green ---
r = parseResults(['  ok   alpha', '  ok   beta', 'Passed tests:  2', 'Failed tests:  0', '[OK] All Lua unit tests passed.'].join('\n'));
check('lua pass: format', r.format === 'lua');
check('lua pass: counts', r.passed === 2 && r.failed === 0);
check('lua pass: no failures', r.failures.length === 0);

// --- Lua, one failure (inline FAIL + DETAILED FAILURES duplicate must dedupe) ---
r = parseResults([
	'  ok   alpha',
	'  FAIL beta gamma — assertion failed: x',
	'Passed tests:  1',
	'Failed tests:  1',
	'--- DETAILED FAILURES ---',
	'[1] beta gamma',
].join('\n'));
check('lua fail: counts', r.passed === 1 && r.failed === 1);
check('lua fail: single deduped failure', r.failures.length === 1 && r.failures[0] === 'beta gamma');

console.log(`\x1b[32m[OK] report.cjs parser: ${checks} assertion(s) passed (TAP + Lua formats).\x1b[0m`);
