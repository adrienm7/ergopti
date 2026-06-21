// tools/test/test-doc-paths.cjs

/**
 * ==============================================================================
 * MODULE: Driver-Doc Path Guard
 * DESCRIPTION:
 * Regression guard for stale pre-reorg paths in the driver documentation. The
 * static/drivers -> static/ergopti_plus reorg renamed every driver root, but the
 * path-migration commit (a3590e6) fixed only SOME blocks of
 * macos/tests/README.md and left the Windows/PowerShell block instructing
 * `cd static\drivers\hammerspoon` — a directory that no longer exists. A
 * contributor following that README lands in a dead path and the suite is silent.
 *
 * ROOT CAUSE ENCODED:
 * Markdown docs under static/ergopti_plus/ must never instruct a path into the
 * pre-reorg driver layout (drivers/hammerspoon, drivers/autohotkey, drivers/linux).
 * This guard scans only *.md (so the deliberate dead-path *guards* in .ahk/.lua
 * test sources — which assert the old path never returns — are not flagged) and
 * fails with file:line if any dead driver path reappears in a doc. It is scoped
 * to static/ergopti_plus/ so the historical record in docs/PROJECT_MEMORY.md and
 * the archived audits are untouched.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DOCS_ROOT = path.join(ROOT, 'static', 'ergopti_plus');

// Dead pre-reorg driver roots (slash form). The matcher below checks each one in
// BOTH slash and backslash form, so a regression in either a bash or a PowerShell
// block is caught from this single list.
const DEAD_PATHS = [
	'drivers/hammerspoon',
	'drivers/autohotkey',
	'drivers/linux',
];

/**
 * Recursively collects every Markdown file under a directory.
 * @param {string} dir - Absolute directory to walk.
 * @param {string[]} acc - Accumulator for matched file paths.
 * @returns {string[]} The accumulator, populated with absolute *.md paths.
 */
function collectMarkdown(dir, acc) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			collectMarkdown(full, acc);
		} else if (entry.isFile() && entry.name.endsWith('.md')) {
			acc.push(full);
		}
	}
	return acc;
}

const errors = [];

for (const file of collectMarkdown(DOCS_ROOT, [])) {
	const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
	lines.forEach((line, i) => {
		for (const dead of DEAD_PATHS) {
			if (line.includes('static/' + dead) || line.includes('static\\' + dead.replace(/\//g, '\\'))) {
				const rel = path.relative(ROOT, file).replace(/\\/g, '/');
				errors.push(`${rel}:${i + 1} references dead pre-reorg path "static/${dead}" — use static/ergopti_plus/<driver>.`);
			}
		}
	});
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Stale pre-reorg driver paths in documentation:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] No stale static/drivers paths in driver docs.\x1b[0m');
