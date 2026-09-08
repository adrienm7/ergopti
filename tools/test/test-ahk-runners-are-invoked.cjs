// tools/test/test-ahk-runners-are-invoked.cjs

/**
 * ==============================================================================
 * MODULE: Orphan AHK Runner Guard
 * DESCRIPTION:
 * Every `run_*.ahk` and `bench_*.ahk` under windows/tests must be referenced by
 * something tracked — a CI workflow, a doc, an npm script, or another test.
 *
 * ROOT CAUSE ENCODED:
 * Three of them were referenced by nothing. Two carried ten Test() calls that
 * existed only there, so those ten tests had never run; and one of them had
 * silently rotted out of the code — the model browser stopped probing Ollama
 * synchronously in favour of an async snapshot, the runner still stubbed only
 * the old entry point, and its catalogue test failed on an unassigned name.
 * Nothing reported that, because nothing invoked the file.
 *
 * A test file that nobody runs is worse than no test: it reads as coverage in
 * the tree and answers no question at all.
 *
 * FEATURES & RATIONALE:
 * 1. Discovers runners from disk, so a new one is covered the day it lands.
 * 2. "Referenced" is deliberately generous — a mention anywhere in a tracked
 *    text file counts. The bar is not "wired perfectly", it is "somebody can
 *    find it".
 * 3. An allowlist would defeat the purpose, so there is none. Delete the runner
 *    or reference it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const TESTS = path.join(ROOT, 'static', 'ergopti_plus', 'windows', 'tests');

function walk(dir, acc = []) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) walk(p, acc);
		else if (/^(run|bench)_.+\.ahk$/i.test(e.name)) acc.push(p);
	}
	return acc;
}

const tracked = execSync('git ls-files', { cwd: ROOT, encoding: 'utf8' }).split('\n').filter(Boolean);
// `git ls-files` reports the INDEX, so a file deleted on disk but not yet staged
// is listed and unreadable. Reading it unguarded made this gate die with ENOENT
// halfway through deleting a superseded test — a crash where a finding belongs,
// and one that says nothing about the invariant. A file that is gone cannot
// reference a runner, so skipping it is also the right answer.
const runners = walk(TESTS);
if (runners.length === 0) {
	console.error('\x1b[31m[ERROR] no run_*/bench_* file found under windows/tests — the walk is broken, not the tree.\x1b[0m');
	process.exit(1);
}

const subjects = runners.map((abs) => ({
	base: path.basename(abs),
	rel: path.relative(ROOT, abs).replace(/\\/g, '/'),
	referenced: false,
}));
// Retain only runner metadata, not every tracked text in the repository. Keep
// reading after all references are found so unreadable inputs still fail fast.
for (const file of tracked) {
	if (!/\.(ahk|cjs|js|mjs|yml|yaml|json|md|ps1|sh|toml)$/i.test(file)) continue;
	if (!fs.existsSync(path.join(ROOT, file))) continue;
	const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
	for (const subject of subjects) {
		if (!subject.referenced && file !== subject.rel && text.includes(subject.base)) {
			subject.referenced = true;
		}
	}
}
const orphans = subjects.filter((subject) => !subject.referenced).map((subject) => subject.rel);

if (orphans.length > 0) {
	console.error(`\x1b[31m[ERROR] ${orphans.length} AHK runner(s) are referenced by nothing — nothing invokes them.\x1b[0m`);
	console.error(
		'  A runner nobody runs holds tests that never execute and drifts out of the code it\n' +
			'  stubs, silently. Reference it from CI, from an npm script, or from a doc that says\n' +
			'  how to run it — or delete it.\n'
	);
	for (const o of orphans) console.error(`    ${o}`);
	process.exit(1);
}

console.log(`\x1b[32m[OK] All ${runners.length} AHK runner(s) under windows/tests are referenced.\x1b[0m`);
