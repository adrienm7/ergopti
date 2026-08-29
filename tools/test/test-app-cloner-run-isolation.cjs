// tools/test/test-app-cloner-run-isolation.cjs

/**
 * ============================================================================
 * MODULE: App Cloner Run Isolation - Source Contract Guard
 * DESCRIPTION:
 * Verifies that each App Cloner run owns a private temporary directory and
 * that result, status, and completion files never use shared /tmp names.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE_PATH = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'apps',
	'App Cloner.app', 'Contents', 'Resources', 'ShortcutBuilder.applescript');
const source = fs.readFileSync(SOURCE_PATH, 'utf8');
const results = [];

function test(name, ok, detail = '') {
	results.push({ name, ok, detail });
}

function count(haystack, needle) {
	return haystack.split(needle).length - 1;
}

function contract(candidate) {
	return {
		privateRoot: candidate.includes('mktemp -d \\"${TMPDIR:-/tmp}/ergopti-appcloner.XXXXXXXX\\"'),
		derivedFiles: candidate.includes('set resultPath to runDir & "/result"')
			&& candidate.includes('set statusPath to runDir & "/status"')
			&& candidate.includes('set donePath to runDir & "/done"'),
		quotedBoundaries: count(candidate, 'quoted form of resultPath') >= 3
			&& count(candidate, 'quoted form of statusPath') >= 2
			&& count(candidate, 'quoted form of donePath') >= 2,
		noSharedSentinels: !candidate.includes('/tmp/appcloner_done')
			&& !candidate.includes('/tmp/appcloner_result'),
	};
}

const actual = contract(source);
test('each run allocates a private temporary directory under TMPDIR',
	actual.privateRoot, JSON.stringify(actual));
test('result, status, and completion paths derive from the private directory',
	actual.derivedFiles && actual.quotedBoundaries, JSON.stringify(actual));
test('shared predictable App Cloner sentinel names are absent',
	actual.noSharedSentinels, JSON.stringify(actual));

const fixedSentinelMutant = source
	.replace(/quoted form of donePath/g, '"/tmp/appcloner_done"')
	.replace(/quoted form of resultPath/g, '"/tmp/appcloner_result"');
const mutant = contract(fixedSentinelMutant);
test('the guard rejects a regression to fixed cross-run sentinel paths',
	!mutant.noSharedSentinels && !mutant.quotedBoundaries, JSON.stringify(mutant));

console.log('TAP version 14');
console.log(`1..${results.length}`);
results.forEach((result, index) => {
	console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
	if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
});
console.log(`# passed: ${results.filter((result) => result.ok).length}/${results.length}`);
if (results.some((result) => !result.ok)) process.exitCode = 1;
