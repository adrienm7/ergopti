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
 * WHY THIS IS A RATCHET AND NOT AN ASSERTION OF ZERO: two files are genuine
 * violations that need a placement decision rather than a mechanical move —
 * linux/ui/webkit_host.lua and _shared/lua/tap_hold/kanata_generator.lua. A
 * gate that fails today teaches people to disable it; one that freezes the
 * number they cannot yet fix keeps counting while they decide.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS_DIR = path.join(ROOT, 'static', 'ergopti_plus');

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
const PATH_BASELINE = 3;

/**
 * Every tracked file under static/ergopti_plus.
 * @returns {string[]} Repo-relative paths with forward slashes.
 */
function trackedDriverFiles() {
	return execSync('git ls-files -- static/ergopti_plus', { cwd: ROOT, encoding: 'utf8' })
		.split('\n')
		.filter(Boolean);
}

/**
 * Top-level sub-folders of a driver's platform/ tree.
 * @param {string} driver - Driver directory name.
 * @returns {string[]} Sorted folder names, empty when platform/ is absent.
 */
function platformFolders(driver) {
	const dir = path.join(DRIVERS_DIR, driver, 'platform');
	if (!fs.existsSync(dir)) return [];
	return fs
		.readdirSync(dir, { withFileTypes: true })
		.filter((e) => e.isDirectory())
		.map((e) => e.name)
		.sort();
}

// A driver is a directory with an adapters/ tree — the hexagonal marker, the
// same discovery test-config-schema.cjs uses.
const DRIVERS = fs
	.readdirSync(DRIVERS_DIR, { withFileTypes: true })
	.filter((e) => e.isDirectory() && fs.existsSync(path.join(DRIVERS_DIR, e.name, 'adapters')))
	.map((e) => e.name)
	.sort();

if (DRIVERS.length < 3) {
	console.error(
		`\x1b[31m[ERROR] found ${DRIVERS.length} driver(s), expected at least 3 — the walk is broken, not the tree.\x1b[0m`
	);
	process.exit(1);
}

const offenders = trackedDriverFiles().filter((f) => !EXEMPT.test(f) && VENDOR_WORDS.test(f));

const folders = new Map(DRIVERS.map((d) => [d, platformFolders(d)]));
const union = [...new Set([...folders.values()].flat())].sort();
const missing = [];
for (const [driver, own] of folders) {
	for (const f of union) {
		if (!own.includes(f)) missing.push(`${driver}/platform/${f}`);
	}
}

if (process.argv.includes('--measure')) {
	console.log(`vendor-named paths outside the seam: ${offenders.length}`);
	for (const o of offenders) console.log('  ' + o);
	console.log(`\nplatform/ folders (union): ${union.join(', ') || '(none)'}`);
	for (const [d, own] of folders) console.log(`  ${d}: ${own.join(', ') || '(none)'}`);
	process.exit(0);
}

let failed = false;
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
	console.error('\x1b[31m[ERROR] Convention P: platform/ is not symmetrical across the drivers.\x1b[0m');
	for (const m of missing) console.error('  missing: ' + m);
	console.error(
		'\n  Every driver ships every platform/ sub-folder; one with nothing to put there\n' +
			'  ships a README.md explaining the mechanism it uses instead. An absence is\n' +
			'  indistinguishable from an oversight, which is the whole reason for the rule.'
	);
}
if (failed) {
	console.error('  Run `node tools/test/test-convention-p-platform-only.cjs --measure` to list them.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Convention P: ${offenders.length}/${PATH_BASELINE} vendor-named path(s), platform/ symmetrical across ${DRIVERS.length} drivers (${union.join(', ')}).\x1b[0m`
);
