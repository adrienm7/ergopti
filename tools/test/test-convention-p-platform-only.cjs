// tools/test/test-convention-p-platform-only.cjs

/**
 * ==============================================================================
 * MODULE: Convention P Gate — platform/ is the only word meaning "differs by OS"
 * DESCRIPTION:
 * Two ratchets over the driver trees, both of which the TODO recorded as
 * "Convention P has no gate: without a test asserting the forbidden-word list
 * against paths it is decoration".
 *
 * 1. NO PATH outside platform/, adapters/ and vendor/ may name an OS or a
 *    vendor product. Before the platform/remap extraction there were three
 *    remap subsystems living under three vendor names in modules/ —
 *    modules/karabiner, modules/kanata, modules/tap_holds — which is how the
 *    same concern ended up with no common parent and three separate readers.
 *
 * 2. EVERY driver has the same platform/ sub-folders. A driver that implements
 *    a mechanism its siblings do not still ships the folder, so the asymmetry
 *    is legible in the tree rather than discovered by grepping.
 *
 * WHY vendor/ IS EXEMPT: it holds third-party binaries and their thin
 * manifests, and their names are not ours to choose. WebView2Loader.dll is
 * called that by Microsoft.
 *
 * WHY THIS IS A RATCHET AND NOT AN ASSERTION OF ZERO: linux/ui/webkit_host.lua
 * is a genuine violation that needs a placement decision rather than a
 * mechanical move. A gate that fails today teaches people to disable it; one
 * that freezes the number they cannot yet fix keeps counting while they decide.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('node:assert/strict');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER_PREFIX = 'static/ergopti_plus/';

// An OS or a vendor product. Anything here in a PATH says "this differs by OS"
// in a word other than `platform`.
const VENDOR_WORDS =
	/karabiner|kanata|webkit|webview2|hammerspoon|autohotkey|ydotool|\bgtk\b|\bdbus\b/i;

// Trees where a vendor name is legitimate: the OS seam itself, and third-party
// code whose names we did not choose. tests/ mirrors the source tree, so a test
// named after a vendor is a symptom of the source, not a separate offence.
const EXEMPT = /[/\\](platform|adapters|vendor|tests|docs)[/\\]/;

// Frozen baseline — driver-tree paths naming an OS or vendor outside the seam.
// Drive to zero; NEVER raise it.
// History: 3 (2026-08-02, first measurement, immediately after the platform/remap
//             extraction removed modules/karabiner, modules/kanata and
//             modules/tap_holds. The three that remain each need a placement
//             decision: linux/ui/webkit_host.lua is the Linux webview mechanism
//             and is OS-unique, so it belongs under platform/ once the other two
//             drivers have a platform/webview/ to be symmetrical with;
//             _shared/lua/tap_hold/kanata_generator.lua and its golden fixture
//             are the shared emitter for one of the three remap back-ends, and
//             Lot 8.4 turns them into one IR plus three named emitters.)
//          1 (2026-09-24, Linux retired kanata for the in-daemon tap-hold engine
//             under platform/remap/, which deleted kanata_generator.lua and its
//             golden fixture. webkit_host.lua is the one left.)
const PATH_BASELINE = 1;

/**
 * Every staged driver file, excluding local runtime residue.
 * @param {string} root - Repository root.
 * @returns {string[]} Repo-relative paths with forward slashes.
 */
function trackedDriverFiles(root = ROOT) {
	return execFileSync('git', ['ls-files', '--cached', '-z', '--', 'static/ergopti_plus'], {
		cwd: root,
		encoding: 'utf8'
	})
		.split('\0')
		.filter(Boolean);
}

/**
 * Top-level sub-folders of a driver's platform/ tree.
 * @param {string} driver - Driver directory name.
 * @param {string[]} files - The gate's tracked driver-file inventory.
 * @returns {string[]} Sorted folder names, empty when no platform/ file is tracked.
 */
function platformFolders(driver, files) {
	const prefix = `${DRIVER_PREFIX}${driver}/platform/`;
	const folders = new Set();
	for (const file of files) {
		if (!file.startsWith(prefix)) continue;
		const relative = file.slice(prefix.length);
		const separator = relative.indexOf('/');
		if (separator > 0) folders.add(relative.slice(0, separator));
	}
	return [...folders].sort();
}

/** Compare only shipped folders, using the same inventory as the path ratchet. */
function platformInventory(drivers, files) {
	const folders = new Map(drivers.map((driver) => [driver, platformFolders(driver, files)]));
	const union = [...new Set([...folders.values()].flat())].sort();
	const missing = [];
	for (const [driver, own] of folders) {
		for (const folder of union) {
			if (!own.includes(folder)) missing.push(`${driver}/platform/${folder}`);
		}
	}
	return { folders, union, missing };
}

/** Real Git fixtures distinguish generated folders from actual tracked asymmetry. */
function assertTrackedPlatformInventory() {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-platform-inventory-'));
	const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' });
	const put = (relative, content = 'fixture\n') => {
		const filename = path.join(root, relative);
		fs.mkdirSync(path.dirname(filename), { recursive: true });
		fs.writeFileSync(filename, content, { flag: 'wx' });
	};
	try {
		git('init', '--quiet');
		git('config', 'core.quotePath', 'true');
		const drivers = ['linux', 'macos', 'windows'];
		const folder = 'shared space é';
		const tracked = drivers.map(
			(driver) => `static/ergopti_plus/${driver}/platform/${folder}/README.md`
		);
		put('.gitignore', '**/__pycache__/\n');
		for (const filename of tracked) put(filename);
		git('add', '--', '.gitignore', ...tracked);
		const ignored = 'static/ergopti_plus/macos/platform/__pycache__/generated.pyc';
		const untracked = 'static/ergopti_plus/macos/platform/local-build/generated.txt';
		put(ignored);
		put(untracked);
		assert.equal(git('check-ignore', '--', ignored).trim(), ignored);
		let files = trackedDriverFiles(root);
		assert.deepEqual(files.sort(), tracked.sort(), 'NUL inventory must preserve quoted path bytes');
		assert.deepEqual(
			platformFolders('macos', files),
			[folder],
			'generated folders are not shipped'
		);
		assert.deepEqual(
			platformInventory(drivers, files).missing,
			[],
			'local caches must not fail parity'
		);
		const asymmetric = 'static/ergopti_plus/linux/platform/linux-only/README.md';
		put(asymmetric);
		git('add', '--', asymmetric);
		files = trackedDriverFiles(root);
		assert.deepEqual(
			platformInventory(drivers, files).missing,
			['macos/platform/linux-only', 'windows/platform/linux-only'],
			'a newly tracked Linux-only folder must still fail parity'
		);
		git('add', '-f', '--', ignored);
		files = trackedDriverFiles(root);
		assert.ok(
			platformFolders('macos', files).includes('__pycache__'),
			'tracked names are never exempt'
		);
		assert.ok(platformInventory(drivers, files).missing.includes('linux/platform/__pycache__'));
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
}

assertTrackedPlatformInventory();

// Both ratchets measure the staged candidate. Local caches and untracked
// scratch trees cannot invent a driver or a shipped platform folder.
const trackedFiles = trackedDriverFiles();
const DRIVERS = [
	...new Set(
		trackedFiles
			.filter((file) => file.startsWith(DRIVER_PREFIX))
			.map((file) => file.slice(DRIVER_PREFIX.length).split('/'))
			.filter((parts) => parts.length >= 3 && parts[1] === 'adapters')
			.map((parts) => parts[0])
	)
].sort();

if (DRIVERS.length < 3) {
	console.error(
		`\x1b[31m[ERROR] found ${DRIVERS.length} driver(s), expected at least 3 — the walk is broken, not the tree.\x1b[0m`
	);
	process.exit(1);
}

const offenders = trackedFiles.filter((f) => !EXEMPT.test(f) && VENDOR_WORDS.test(f));
const { folders, union, missing } = platformInventory(DRIVERS, trackedFiles);

if (process.argv.includes('--measure')) {
	console.log(`vendor-named paths outside the seam: ${offenders.length}`);
	for (const o of offenders) console.log('  ' + o);
	console.log(`\nplatform/ folders (union): ${union.join(', ') || '(none)'}`);
	for (const [d, own] of folders) console.log(`  ${d}: ${own.join(', ') || '(none)'}`);
	process.exit(0);
}

let failed = false;
if (union.length === 0) {
	failed = true;
	console.error(
		'\x1b[31m[ERROR] Convention P: no tracked platform/ sub-folders found — the candidate has no subjects.\x1b[0m'
	);
}
if (offenders.length > PATH_BASELINE) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] Convention P: ${offenders.length} path(s) name an OS or vendor outside platform/ (baseline ${PATH_BASELINE}).\x1b[0m`
	);
	for (const o of offenders) console.error('  ' + o);
	console.error(
		'\n  platform/ is the only word in the tree that means "this differs by OS". A vendor\n' +
			'  name anywhere else is how one concern ends up with three parents and three\n' +
			'  readers. Do NOT raise the baseline.'
	);
}
if (missing.length > 0) {
	failed = true;
	console.error(
		'\x1b[31m[ERROR] Convention P: platform/ is not symmetrical across the drivers.\x1b[0m'
	);
	for (const m of missing) console.error('  missing: ' + m);
	console.error(
		'\n  Every driver ships every platform/ sub-folder; one with nothing to put there\n' +
			'  ships a README.md explaining the mechanism it uses instead. An absence is\n' +
			'  indistinguishable from an oversight, which is the whole reason for the rule.'
	);
}
if (failed) {
	console.error(
		'  Run `node tools/test/test-convention-p-platform-only.cjs --measure` to list them.'
	);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Convention P: ${offenders.length}/${PATH_BASELINE} vendor-named path(s), platform/ symmetrical across ${DRIVERS.length} drivers (${union.join(', ')}).\x1b[0m`
);
