// tools/test/test-macos-build-scripts-bash32.cjs

/**
 * ==============================================================================
 * MODULE: macOS Build Scripts Run Under Bash 3.2
 * DESCRIPTION:
 * The macOS app build (tools/build/build_macos_app.sh) and every script it
 * starts run under the system /bin/bash 3.2, whose cd has no -e option. A
 * `cd -Pe` there stops the build with "cd: -e: invalid option" (the macOS 26
 * build of run 42335206901), while the Linux scripts, run by a newer Bash,
 * keep it. This gate reads the build script and the tools/build scripts it
 * names, and refuses that spelling in any of them.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const ENTRY = 'tools/build/build_macos_app.sh';
// A cd whose bundled single-letter options include e (-e, -Pe, -eP, -LPe).
const CD_WITH_E = /(?:^|[\s;&|(`])cd\s+-[LP]*e[LP]*\s/;

/** Lines of a shell source that are not comments, numbered from 1. */
function codeLines(text) {
	return text
		.split('\n')
		.map((line, index) => ({ line, number: index + 1 }))
		.filter(({ line }) => !/^\s*#/.test(line));
}

/** The build script and the tools/build scripts it starts. */
function macosBuildScripts() {
	const entry = fs.readFileSync(path.join(ROOT, ENTRY), 'utf8');
	const named = [...entry.matchAll(/tools\/build\/[A-Za-z0-9_.-]+\.sh/g)].map((m) => m[0]);
	return [...new Set([ENTRY, ...named])].sort();
}

// The detector sees the spellings that break Bash 3.2 and nothing else.
for (const [sample, expected] of [
	['IFS= read -r -d "" R < <(CDPATH= cd -Pe -- "$D" && pwd)', true],
	['(cd -e "$D")', true],
	['cd -eP -- "$D"', true],
	['CDPATH= cd -P -- "$D"', false],
	['SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"', false],
	['abcd -Pe x', false]
])
	assert.equal(CD_WITH_E.test(sample), expected, `self-test: ${sample}`);

const scripts = macosBuildScripts();
assert.ok(scripts.length >= 2, 'the macOS build names the scripts it starts');
const offenders = [];
for (const script of scripts) {
	const text = fs.readFileSync(path.join(ROOT, script), 'utf8');
	for (const { line, number } of codeLines(text))
		if (CD_WITH_E.test(line)) offenders.push(`${script}:${number}: ${line.trim()}`);
}
assert.deepEqual(
	offenders,
	[],
	'the macOS build runs under /bin/bash 3.2, whose cd has no -e: use cd -P and check the result'
);
console.log(`[OK] ${scripts.length} macOS build script(s) use only Bash 3.2 cd options.`);
