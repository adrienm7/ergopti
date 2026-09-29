// tools/test/test-space-wrap-toggle-retired.cjs

/**
 * ==============================================================================
 * MODULE: The Circular Spaces Toggle Stays Retired
 * DESCRIPTION:
 * The macOS « Navigation circulaire des Spaces » checkbox and its
 * gestures.space_wrap setting are retired. The wrap is its own pair of actions
 * on every driver (space_prev_wrap / space_next_wrap on macOS,
 * desktop_prev_wrap / desktop_next_wrap on Windows and Linux), bindable to a
 * gesture or a keyboard slot like any other action. A global switch next to
 * them would be a second, contradictory way to decide whether a step wraps —
 * and the old one never wrapped at all, since macOS stops at the last Space.
 *
 * WHAT THIS PINS, per surface, so a partial revert cannot pass:
 *   1. The features manifest declares no gestures.space_wrap and the menu
 *      manifest no circular_spaces row, in the source and in every generated
 *      copy (features manifests, config template, menu manifest).
 *   2. No locale carries the checkbox label.
 *   3. No driver source keeps the state key, its getter/setter or the row's
 *      command, comments included: a comment naming the setting describes
 *      code that no longer exists.
 *   4. The config migration that deletes gestures.space_wrap from an existing
 *      config.toml is still registered — the one place the old key may appear.
 *
 * Every scan asserts it read something first: an empty scan would pass this
 * gate while checking nothing.
 *
 * USAGE:
 *   node tools/test/test-space-wrap-toggle-retired.cjs [repository root]
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(process.argv[2] || path.join(__dirname, '..', '..'));
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');
const MIGRATIONS = path.join(SP, '_shared', 'core', 'config_schema', 'migrations.toml');

// Identifiers that existed only for the toggle. "space_wrap" also matches the
// state key gesture_space_wrap and the getter/setter get_/set_space_wrap.
const RETIRED_NAMES = ['space_wrap', 'circular_spaces'];
const RETIRED_KEY = 'menu.gestures.circular_spaces';

// Every tree a driver or a generated copy of the manifests lives in. The
// migration registry, its corpora and the shared migration contract
// (_shared/lua/test) are the deliberate exception: they must name the old key
// to delete it from an existing file.
const SCANNED = [
	{ dir: path.join(SP, 'macos'), exts: ['.lua', '.toml', '.json'] },
	{ dir: path.join(SP, 'windows'), exts: ['.ahk', '.toml', '.json'] },
	{ dir: path.join(SP, 'linux'), exts: ['.lua', '.toml', '.json'] },
	{ dir: path.join(SP, '_shared', 'modules'), exts: ['.toml', '.json', '.lua'] },
	{ dir: path.join(SP, '_shared', 'lua'), exts: ['.lua'], skip: ['test'] },
	{ dir: path.join(SP, '_shared', 'core', 'config_schema', 'examples'), exts: ['.toml'] }
];
const SKIPPED_DIRS = new Set(['node_modules', 'vendor']);

const errors = [];

// ==================================================
// ==================================================
// ======= 1/ Driver, manifest and generated trees ==
// ==================================================
// ==================================================

/**
 * Lists the files under a directory with one of the given extensions.
 * @param {string} dir Directory to walk.
 * @param {string[]} exts Extensions to keep.
 * @param {string[]} skip Top-level sub-directories left out.
 * @returns {string[]} Absolute paths.
 */
function filesUnder(dir, exts, skip) {
	const out = [];
	(function walk(current) {
		for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
			const full = path.join(current, entry.name);
			if (entry.isDirectory()) {
				const skipped = current === dir && skip.includes(entry.name);
				if (!SKIPPED_DIRS.has(entry.name) && !skipped) walk(full);
			} else if (exts.some((ext) => entry.name.endsWith(ext))) {
				out.push(full);
			}
		}
	})(dir);
	return out;
}

let scanned = 0;
for (const { dir, exts, skip = [] } of SCANNED) {
	const files = filesUnder(dir, exts, skip);
	if (files.length === 0) {
		errors.push(
			`${path.relative(ROOT, dir)}: no file read — the scan is broken and proves nothing.`
		);
		continue;
	}
	for (const file of files) {
		scanned += 1;
		const text = fs.readFileSync(file, 'utf8');
		for (const name of RETIRED_NAMES) {
			if (text.includes(name)) {
				errors.push(`${path.relative(ROOT, file)} still names the retired "${name}".`);
			}
		}
	}
}
if (scanned < 1000)
	errors.push(`only ${scanned} file(s) scanned — expected the three driver trees.`);

// ==================================================
// ==================================================
// ======= 2/ The locales ===========================
// ==================================================
// ==================================================

const localeFiles = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
if (localeFiles.length < 21) errors.push(`read ${localeFiles.length} locale file(s), expected 21`);
for (const file of localeFiles) {
	const table = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
	if (table[RETIRED_KEY] !== undefined) {
		errors.push(`${file} still carries the retired key "${RETIRED_KEY}".`);
	}
}

// ==================================================
// ==================================================
// ======= 3/ The migration that deletes it =========
// ==================================================
// ==================================================

const migrations = fs.readFileSync(MIGRATIONS, 'utf8');
if (
	!/\{\s*op\s*=\s*"delete",\s*section\s*=\s*"gestures",\s*key\s*=\s*"space_wrap"\s*\}/.test(
		migrations
	)
) {
	errors.push(
		'migrations.toml no longer deletes gestures.space_wrap: an existing config.toml would keep a key nothing reads.'
	);
}

// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] The circular Spaces toggle came back:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] The circular Spaces toggle stays retired: ${scanned} file(s) and ` +
		`${localeFiles.length} locales checked, the migration still deletes the old key.\x1b[0m`
);
