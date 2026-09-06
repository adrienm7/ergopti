// tools/test/test-lua-fixtures-stay-out-of-the-repo.cjs

/**
 * ==============================================================================
 * MODULE: Lua test fixtures stay out of the repository
 *         (macos-test-fixtures-escape-into-the-repo)
 * DESCRIPTION:
 * A test that writes its fixture to a relative path writes it into the process
 * working directory, which for both Lua suites is the driver root inside the
 * checkout. Ten macOS test files spelled their scratch directory as
 *
 *     (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
 *
 * On macOS -- the platform that suite exists for -- TEMP and TMP are normally
 * unset and TMPDIR is the one that is set, so every one of those expressions
 * resolved to ".". The suite wrote .toml fixtures straight into
 * static/ergopti_plus/macos/, and one of them left a stable
 * `.ergoptiplus-write-lock-v1` sidecar behind: a zero-byte file that shows up in
 * `git status` looking like real work, and that nothing ever cleans up.
 *
 * ROOT CAUSE ENCODED:
 * The defect is not the ten call sites, it is that a scratch path was allowed to
 * be relative at all. helpers.temp_dir() now resolves TMPDIR first and raises
 * rather than falling back to the working directory. This guard forbids the
 * pattern returning, in either Lua suite, and requires a positive count of
 * helpers.temp_dir() users so it cannot pass by the helper being deleted.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

const TEST_TREES = [
	'static/ergopti_plus/macos/tests',
	'static/ergopti_plus/linux/tests',
];

// A scratch-directory expression that can resolve to the working directory.
// Matches `or "."` and `or './…'` used as the last resort of a getenv chain.
const RELATIVE_FALLBACK_RE = /os\.getenv\(\s*"(?:TEMP|TMP|TMPDIR)"\s*\)[^\n]*\bor\s*"\.(?:\/[^"]*)?"/;

// Any absolute-path answer is fine; these are the shapes already in use.
const HELPER_USE_RE = /helpers\.temp_dir\(\)/;

/**
 * Collects every .lua file under a repository-relative directory.
 * @param {string} rel Repository-relative directory.
 * @returns {string[]} Repository-relative Lua file paths.
 */
function luaFiles(rel) {
	const out = [];
	const walk = (dir) => {
		const abs = path.join(ROOT, dir);
		if (!fs.existsSync(abs)) return;
		for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
			const child = `${dir}/${entry.name}`;
			if (entry.isDirectory()) {
				if (entry.name === 'vendor' || entry.name === 'node_modules') continue;
				walk(child);
			} else if (entry.name.endsWith('.lua')) {
				out.push(child);
			}
		}
	};
	walk(rel);
	return out;
}

const violations = [];
let helperUsers = 0;
let scanned = 0;

for (const tree of TEST_TREES) {
	for (const rel of luaFiles(tree)) {
		scanned++;
		const lines = fs.readFileSync(path.join(ROOT, rel), 'utf8').split('\n');
		let usesHelper = false;
		for (let i = 0; i < lines.length; i++) {
			// Prose is not a call site. The helper's own docstring quotes the
			// forbidden expression to explain it, and the guard that flagged its
			// own documentation would be the second instance of the comment trap
			// this repository already records.
			if (/^\s*--/.test(lines[i])) continue;
			if (HELPER_USE_RE.test(lines[i])) usesHelper = true;
			if (RELATIVE_FALLBACK_RE.test(lines[i])) {
				violations.push(`${rel}:${i + 1}  ${lines[i].trim()}`);
			}
		}
		if (usesHelper) helperUsers++;
	}
}

if (scanned === 0) {
	console.error('\x1b[31m[ERROR] no Lua test files were scanned — the guard is looking at the wrong tree.\x1b[0m');
	process.exit(1);
}

if (helperUsers === 0) {
	console.error('\x1b[31m[ERROR] no test uses helpers.temp_dir() — the isolated scratch helper was deleted, so this guard proves nothing.\x1b[0m');
	process.exit(1);
}

if (violations.length > 0) {
	console.error('\x1b[31m[ERROR] a test fixture can resolve to the working directory, which is the checkout.\x1b[0m');
	console.error('  Use helpers.temp_dir(): it resolves TMPDIR first and raises rather than falling back to ".".');
	for (const v of violations) console.error('    ' + v);
	process.exit(1);
}

console.log(`\x1b[32m[OK] No Lua test fixture can land in the checkout — ${scanned} file(s) scanned, ${helperUsers} using helpers.temp_dir().\x1b[0m`);
