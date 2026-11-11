// tools/audit/structure/census.cjs

/**
 * ==============================================================================
 * MODULE: Driver Structure Census (Rule B)
 * DESCRIPTION:
 * Measures the directory trees of the three drivers and of _shared as Git
 * tracks them: the direct entry count of every folder, the folders outside
 * the size bounds, and the folder paths that exist on some drivers only.
 *
 * It is a measurement shared by three consumers: the structure plan
 * (tools/audit/structure/plan.cjs) that writes the appendices of
 * docs/design/structure-plan.md, the ratchet test
 * tools/test/test-structure-folder-bounds.cjs, and anyone running it by hand.
 * It reads the Git index only, so personal or runtime files never move a
 * number.
 *
 * USAGE:
 *   node tools/audit/structure/census.cjs            print the summary
 *   node tools/audit/structure/census.cjs --json     print the full census
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const BASE = 'static/ergopti_plus';
const DRIVERS = ['windows', 'macos', 'linux'];
const TREES = [...DRIVERS, '_shared'];

// Decided by the coordinator on 2026-11-11, to review by the maintainer: a
// folder holds 2 to 20 direct entries. One entry is a folder that names a
// file; past twenty a reader can no longer see what the folder is for.
const MIN_ENTRIES = 2;
const MAX_ENTRIES = 20;
// Test suites are lists of behaviours whose file names carry their subject,
// so a test folder may hold twice as many before it has to split.
const MAX_TEST_ENTRIES = 40;

// Folders whose shape is owned by something other than the driver's
// architecture, and therefore not held to the bounds: third-party code, codegen
// output (its owner decides the file split), the SwiftPM package layout
// (Sources/<target> and Tests/<target> are singletons by convention), macOS
// application bundles, and data corpora that are one vector per file.
const EXEMPT = [
	{ re: /(^|\/)vendor(\/|$)/, why: 'third-party code keeps its upstream layout' },
	{ re: /(^|\/)_generated(\/|$)/, why: 'codegen output; its generator owns the split' },
	{
		re: /^macos\/launcher(\/|$)/,
		why: 'SwiftPM package layout (Sources/<target>, Tests/<target>)'
	},
	{ re: /\.app(\/|$)/, why: 'macOS application bundle layout' },
	{ re: /(^|\/)tests\/corpus(\/|$)/, why: 'data corpus, one vector per file' },
	{ re: /(^|\/)data\/locales$/, why: 'one catalogue per supported locale' },
	{ re: /^_shared\/core\/ports$/, why: 'the port catalogue, one specification per port' },
	{ re: /(^|\/)go\//, why: 'a Go package is one folder by language convention' },
	{ re: /(^|\/)(__pycache__|node_modules|\.[^/]+)(\/|$)/, why: 'tool residue' }
];

/** Repository-relative paths of every tracked file under the four trees. */
function trackedFiles(root = ROOT) {
	return execFileSync('git', ['ls-files', '--cached', '-z', '--', BASE], {
		cwd: root,
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024
	})
		.split('\0')
		.filter(Boolean)
		.map((rel) => rel.split(path.sep).join('/'));
}

/** The exemption that covers a tree-relative folder, or null. */
function exemptionOf(folder) {
	const hit = EXEMPT.find((e) => e.re.test(folder));
	return hit ? hit.why : null;
}

/**
 * Builds the folder table of the four trees from a list of tree-relative file
 * paths ("windows/infra/logger.ahk").
 * @param {string[]} files Paths relative to static/ergopti_plus.
 * @returns {Map<string, Set<string>>} Folder path to its direct entry names.
 */
function folderTable(files) {
	const table = new Map();
	for (const file of files) {
		const parts = file.split('/');
		for (let i = 1; i < parts.length; i++) {
			const folder = parts.slice(0, i).join('/');
			if (!table.has(folder)) table.set(folder, new Set());
			table.get(folder).add(parts[i]);
		}
	}
	return table;
}

/** The tree-independent name of a folder, shared by its driver counterparts. */
function counterpartKey(tree, folder) {
	if (DRIVERS.includes(tree)) return folder;
	if (tree !== '_shared' || /^(tests|lua\/test)(\/|$)/.test(folder)) return null;
	// Today's shared Lua sits under lua/; the target puts it at the root.
	return folder.startsWith('lua/') ? folder.slice(4) : folder;
}

/** True for the architecture part of a driver tree (tests and exemptions aside). */
function isArchitecture(driverRelFolder) {
	return !/^tests(\/|$)/.test(driverRelFolder) && exemptionOf(driverRelFolder) === null;
}

/**
 * Measures a set of tree-relative file paths.
 * @param {string[]} files Paths relative to static/ergopti_plus.
 * @returns {object} The census.
 */
function measure(files) {
	const table = folderTable(files);
	const folders = [];
	for (const [folder, entries] of table) {
		const tree = folder.split('/')[0];
		if (!TREES.includes(tree) || folder === tree) continue;
		const rel = folder.slice(tree.length + 1);
		const exempt = exemptionOf(folder) || exemptionOf(rel);
		const size = entries.size;
		const tests = /^tests(\/|$)/.test(rel) || /(^|\/)test(\/|$)/.test(rel);
		const max = tests ? MAX_TEST_ENTRIES : MAX_ENTRIES;
		folders.push({
			tree,
			folder: rel,
			entries: size,
			tests,
			exempt,
			violation: exempt ? null : size < MIN_ENTRIES ? 'singleton' : size > max ? 'oversized' : null
		});
	}
	folders.sort((a, b) => (a.tree + '/' + a.folder).localeCompare(b.tree + '/' + b.folder));

	// A one-entry folder whose counterpart on another driver (or, for
	// _shared/lua/<path>, on a driver) is a real folder is kept for parity:
	// Rule B's "same tree" wins over its "no singleton", and the gate counts
	// these apart so they stay visible.
	const largest = new Map();
	for (const f of folders) {
		const key = counterpartKey(f.tree, f.folder);
		if (key) largest.set(key, Math.max(largest.get(key) || 0, f.entries));
	}
	for (const f of folders) {
		const key = counterpartKey(f.tree, f.folder);
		if (f.violation === 'singleton' && key && largest.get(key) >= MIN_ENTRIES)
			f.violation = 'singleton_parity';
	}

	const architecture = new Map(
		DRIVERS.map((d) => [
			d,
			new Set(folders.filter((f) => f.tree === d && isArchitecture(f.folder)).map((f) => f.folder))
		])
	);
	const union = new Set();
	for (const set of architecture.values()) for (const p of set) union.add(p);
	// A module that is one file on a driver and a folder on another is the
	// same module: Rule B compares names, and a one-file folder is forbidden.
	const stems = new Map(DRIVERS.map((d) => [d, new Set()]));
	for (const file of files) {
		const [tree, ...rest] = file.split('/');
		if (stems.has(tree) && rest.length > 1)
			stems.get(tree).add(rest.join('/').replace(/\.[^./]+$/, ''));
	}
	const holds = (d, p) => architecture.get(d).has(p) || stems.get(d).has(p);
	const mismatches = [...union]
		.sort()
		.map((p) => ({ folder: p, on: DRIVERS.filter((d) => holds(d, p)) }))
		.filter((m) => m.on.length < DRIVERS.length);

	const summary = {};
	for (const tree of TREES) {
		const own = folders.filter((f) => f.tree === tree);
		const count = (kind, tests) =>
			own.filter((f) => f.violation === kind && f.tests === tests).length;
		summary[tree] = {
			folders: own.length,
			code_oversized: count('oversized', false),
			code_singleton: count('singleton', false),
			code_singleton_parity: count('singleton_parity', false),
			tests_oversized: count('oversized', true),
			tests_singleton: count('singleton', true),
			tests_singleton_parity: count('singleton_parity', true),
			exempt: own.filter((f) => f.exempt).length
		};
	}
	const shared = [...union].filter((p) => DRIVERS.every((d) => holds(d, p)));
	return {
		bounds: {
			min_entries: MIN_ENTRIES,
			max_entries: MAX_ENTRIES,
			max_test_entries: MAX_TEST_ENTRIES
		},
		summary,
		architecture_union: union.size,
		architecture_shared: shared.length,
		mismatches,
		folders
	};
}

/** Census of the Git index. */
function census(root = ROOT) {
	const prefix = `${BASE}/`;
	return measure(trackedFiles(root).map((f) => f.slice(prefix.length)));
}

function main() {
	const data = census();
	if (process.argv.includes('--json')) {
		process.stdout.write(JSON.stringify(data, null, '\t') + '\n');
		return;
	}
	console.log(
		`bounds: ${MIN_ENTRIES}..${MAX_ENTRIES} direct entries per folder (${MAX_TEST_ENTRIES} in tests)`
	);
	for (const [tree, s] of Object.entries(data.summary)) {
		console.log(
			`${tree}: ${s.folders} folders; code ${s.code_oversized} oversized, ${s.code_singleton} singleton ` +
				`(+${s.code_singleton_parity} kept for parity); ` +
				`tests ${s.tests_oversized} oversized, ${s.tests_singleton} singleton; ${s.exempt} exempt`
		);
	}
	console.log(
		`architecture folders shared by all three drivers: ${data.architecture_shared} of ${data.architecture_union}; ` +
			`${data.mismatches.length} on one or two drivers only`
	);
}

if (require.main === module) main();

module.exports = {
	counterpartKey,
	BASE,
	DRIVERS,
	TREES,
	MIN_ENTRIES,
	MAX_ENTRIES,
	MAX_TEST_ENTRIES,
	EXEMPT,
	exemptionOf,
	trackedFiles,
	folderTable,
	measure,
	census
};
