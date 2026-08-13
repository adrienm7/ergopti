// tools/test/test-source-trees-are-scanned.cjs

/**
 * ==============================================================================
 * MODULE: Source-Tree Scan Coverage Gate
 * DESCRIPTION:
 * Twenty meta-tests and tools enumerate a driver's source by a HARDCODED list of
 * top-level folders — `{ "adapters", "infra", "modules", "ui" }` and its
 * variants. Adding a new top-level tree makes every one of them quietly stop
 * covering it.
 *
 * This is not hypothetical. Extracting platform/ on 2026-08-02 moved 19 Windows
 * files out of modules/ and infra/, and the AHK suite went from 3626 tests to
 * 3607 with ZERO failures: test_ahk_brace_balance registers one case per file
 * under ["infra", "modules", "ui"], so nineteen cases simply stopped existing.
 * Nothing reported it. The suite's own floor ("at least one file checked") could
 * not fire, because the other three trees still had files.
 *
 * FEATURES & RATIONALE:
 * 1. The canonical list lives in ONE place — CANONICAL_TREES below — and this
 *    gate asserts two things against it: that every driver's real top-level
 *    source folders are in the list, and that every scanner names all of them.
 * 2. A scanner is found by its shape, not by a registry of file names: any file
 *    holding a list that names two or more canonical trees is one. A new
 *    scanner therefore joins the gate by being written, which is the only way a
 *    coverage rule survives contact with people who do not know it exists.
 * 3. Detection is by TOKEN, not by parsing each language's list syntax. A file
 *    that names "modules" and "infra" in a bracketed list and never says
 *    "platform" is the failure this gate exists for, whatever the brackets look
 *    like.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER_PREFIX = 'static/ergopti_plus/';
const REQUIRED_DRIVERS = ['linux', 'macos', 'windows'];

// The top-level trees that hold a driver's own source. `data`, `_generated`,
// `tests`, `vendor`, `build` and `docs` are deliberately NOT here: they are not
// hand-written driver source and the scanners that care about them say so.
const CANONICAL_TREES = ['adapters', 'infra', 'modules', 'platform', 'ui'];

// Folders that legitimately sit beside the canonical trees. `apps`, `launcher`
// and `bin` hold code in another language entirely (AppleScript bundles, a Swift
// package, a shell entry point), which is why no Lua/AHK scanner should reach
// them.
const NON_SOURCE = new Set([
	'tests', 'data', '_generated', 'vendor', 'build', 'docs', 'extensions', 'old', 'scripts',
	'apps', 'launcher', 'bin', '__pycache__', '.pytest_cache', '.venv',
]);

// A list literal naming two or more canonical trees, in any of the three
// languages: Lua `{ "a", "b" }`, AHK `["a", "b"]`, JS `['a', 'b']`.
const LIST_RE = /[[{]\s*(?:["'][a-z_/]+["']\s*,\s*){1,}["'][a-z_/]+["']\s*[\]}]/g;

/**
 * Canonical tree names quoted inside one list literal.
 * @param {string} literal - The matched list text.
 * @returns {string[]} Canonical names present, in canonical order.
 */
function treesIn(literal) {
	return CANONICAL_TREES.filter((t) => new RegExp(`["']${t}/?["']`).test(literal));
}

const trackedPaths = execFileSync(
	'git',
	['ls-files', '--cached', '-z'],
	{ cwd: ROOT, encoding: 'utf8' }
)
	.split('\0')
	.filter(Boolean)
	.map((rel) => rel.split(path.sep).join('/'));

const tracked = trackedPaths
	.filter((f) => /\.(ahk|lua|cjs|js|mjs)$/.test(f))
	.filter((f) => fs.existsSync(path.join(ROOT, f)))
	// This gate names every tree in its own canonical list, which is exactly the
	// shape it looks for.
	.filter((f) => !f.endsWith('test-source-trees-are-scanned.cjs'));

// The rule is narrower than "every list names every tree", because several
// lists are deliberately scoped — the OS-purity ratchet counts modules+infra
// against its own frozen baseline and has no business reading ui/.
//
// What is NOT deliberate is omitting the tree that things move INTO. platform/
// is carved out of modules/ and infra/, so a list naming either of those and
// not platform/ has a hole created by that migration, whatever it meant to
// cover. That is the exact shape that silently dropped 19 tests.
const REQUIRES_PLATFORM = ['modules', 'infra'];

const incomplete = [];
for (const rel of tracked) {
	const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
	for (const line of src.split(/\r?\n/)) {
		// A commented-out list is prose, not a scan.
		if (/^\s*(;|--|\/\/|#)/.test(line)) continue;
		LIST_RE.lastIndex = 0;
		let m;
		while ((m = LIST_RE.exec(line))) {
			const named = treesIn(m[0]);
			if (named.length < 2) continue;
			if (!named.some((t) => REQUIRES_PLATFORM.includes(t))) continue;
			if (named.includes('platform')) continue;
			incomplete.push({ rel, line: line.trim().slice(0, 110), absent: ['platform'] });
		}
	}
}

// Every driver's real top-level folders must be known.
const DRIVERS = [...new Set(
	trackedPaths
		.filter((rel) => rel.startsWith(DRIVER_PREFIX))
		.map((rel) => rel.slice(DRIVER_PREFIX.length).split('/'))
		.filter((parts) => parts.length >= 3 && parts[1] === 'adapters')
		.map((parts) => parts[0])
)].sort();

const driverTrees = new Map(DRIVERS.map((driver) => [driver, new Set()]));
for (const rel of trackedPaths) {
	if (!rel.startsWith(DRIVER_PREFIX)) continue;
	const parts = rel.slice(DRIVER_PREFIX.length).split('/');
	if (parts.length < 3 || !driverTrees.has(parts[0])) continue;
	driverTrees.get(parts[0]).add(parts[1]);
}

const unknown = [];
for (const driver of DRIVERS) {
	for (const tree of driverTrees.get(driver)) {
		if (CANONICAL_TREES.includes(tree) || NON_SOURCE.has(tree)) continue;
		unknown.push(`${driver}/${tree}`);
	}
}

if (process.argv.includes('--measure')) {
	console.log(`drivers: ${DRIVERS.join(', ')}`);
	console.log(`canonical trees: ${CANONICAL_TREES.join(', ')}`);
	console.log(`\nlists missing a canonical tree: ${incomplete.length}`);
	for (const i of incomplete) console.log(`  ${i.rel}\n     missing ${i.absent.join(', ')} — ${i.line}`);
	console.log(`\nunknown top-level driver folders: ${unknown.length}`);
	for (const u of unknown) console.log('  ' + u);
	process.exit(0);
}

let failed = false;
const missingDrivers = REQUIRED_DRIVERS.filter((driver) => !DRIVERS.includes(driver));
if (missingDrivers.length > 0) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] tracked-tree discovery missed required driver(s): ${missingDrivers.join(', ')}.\x1b[0m`
	);
}
if (incomplete.length > 0) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] ${incomplete.length} source-tree list(s) do not name every canonical tree.\x1b[0m`
	);
	for (const i of incomplete.slice(0, 12)) {
		console.error(`  ${i.rel} — missing ${i.absent.join(', ')}`);
		console.error(`     ${i.line}`);
	}
	console.error(
		'\n  A scanner that enumerates some of the trees covers some of the source, and the\n' +
			'  gap is silent: extracting platform/ dropped 19 AHK tests with no failure,\n' +
			'  because they are registered one per file under a list that had not heard of it.\n' +
			'  Add the missing name, or if the list is deliberately narrow, say so on the line\n' +
			'  above it and give it a name this pattern does not match.'
	);
}
if (unknown.length > 0) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] ${unknown.length} top-level driver folder(s) are neither a canonical source tree nor known non-source.\x1b[0m`
	);
	for (const u of unknown) console.error('  ' + u);
	console.error(
		'\n  A new top-level tree must be added to CANONICAL_TREES here (so every scanner is\n' +
			'  required to name it) or to NON_SOURCE (so it is knowingly excluded).'
	);
}
if (failed) {
	console.error('  Run `node tools/test/test-source-trees-are-scanned.cjs --measure` for the full list.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Every source-tree list names all ${CANONICAL_TREES.length} canonical trees across ${DRIVERS.length} drivers.\x1b[0m`
);
