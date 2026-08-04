// tools/test/test-hotstrings-bridge-parity.cjs

/**
 * ==============================================================================
 * MODULE: Hotstrings Web-UI Bridge Parity
 * DESCRIPTION:
 * The two hotstrings windows — the personal-hotstring editor and the per-category
 * settings window — are ONE HTML/JS application in _shared/ui/, hosted by each
 * driver. So the window a user sees is identical by construction, and everything
 * that can differ between drivers is in the Lua/AHK bridge behind it.
 *
 * That makes the bridge the whole parity surface, and it was never checked.
 *
 * WHAT WAS TRUE ON 2026-08-04, measured by extracting the action vocabulary from
 * the shared scripts and grepping each bridge for it:
 *
 *   linux/hotstring_editor         had no branch for `save_pref` or
 *                                  `window_focus`, and — worse than a missing
 *                                  branch — answered `ready` with a payload of
 *                                  {hotstrings, groups, config_dir}, none of
 *                                  which the shared UI reads. It reads
 *                                  {sections, trigger_char, default_priority, …}.
 *                                  The editor therefore opened EMPTY on Linux,
 *                                  every time, and the four extra branches the
 *                                  bridge did carry (refresh, delete, test,
 *                                  duplicate) are actions the UI never sends.
 *   linux/hotstrings_config_window had no branch for `set_priority`,
 *                                  `clear_priority`, `set_all_grey` or `close`.
 *
 * Every one of those is a control the user clicks and nothing happens — which is
 * indistinguishable, from their side, from a misclick.
 *
 * WHY A BIJECTION AND NOT A SUBSET CHECK:
 * Both directions are bugs. An action the UI sends and the bridge ignores is a
 * dead button. An action the bridge handles and the UI never sends is dead code
 * that reads as a feature — the Linux editor's `delete` branch persists to disk
 * and cannot be reached, which is exactly the sort of thing that looks like
 * coverage when someone asks "does Linux support deleting a hotstring?".
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SHARED_UI = path.join(SP, '_shared', 'ui');

// The windows this gate covers, and where each driver hosts them. AHK is absent
// on purpose and not by oversight: the Windows driver renders these two settings
// surfaces as native menus rather than hosting the web UI, so it has no bridge to
// compare. If it ever gains one, add it here — the vocabulary is shared.
const WINDOWS = {
	hotstring_editor: {
		linux: 'linux/ui/hotstring_editor/bridge.lua',
		macos: 'macos/ui/hotstring_editor/init.lua'
	},
	hotstrings_config_window: {
		linux: 'linux/ui/hotstrings_config_window/bridge.lua',
		macos: 'macos/ui/hotstrings_config_window/init.lua'
	}
};

// Actions a bridge may legitimately not handle, with the reason. Empty, and it
// should stay that way: an entry here is a control that does nothing on one
// platform, which is the condition this gate exists to end.
const ALLOWED_UNHANDLED = {};

const errors = [];




// ==================================================
// ==================================================
// ======= 1/ What the shared UI sends ==============
// ==================================================
// ==================================================

/**
 * The action vocabulary of one shared window.
 *
 * Read out of the script rather than listed here, so adding a button to the UI
 * puts this gate red until every driver answers it. A hand-maintained list would
 * have to be remembered at exactly the moment nobody remembers it.
 * @param {string} name The directory under _shared/ui.
 * @returns {string[]} Sorted action names.
 */
function actionsOf(name) {
	const file = path.join(SHARED_UI, name, 'script.js');
	const src = fs.readFileSync(file, 'utf8');
	const found = new Set();
	// Both spellings the shared scripts use: the helper, and the raw object for
	// the handful of call sites that build the message inline.
	for (const m of src.matchAll(/toLua\(\s*['"]([a-zA-Z_]+)['"]/g)) found.add(m[1]);
	for (const m of src.matchAll(/action:\s*['"]([a-zA-Z_]+)['"]/g)) found.add(m[1]);
	return [...found].sort();
}

const VOCABULARY = {};
for (const name of Object.keys(WINDOWS)) {
	VOCABULARY[name] = actionsOf(name);
	// A floor per window. A regex that stopped matching would report every bridge
	// as complete while comparing nothing — the exact false green this gate is
	// meant to replace.
	if (VOCABULARY[name].length < 4) {
		errors.push(
			`${name}: extracted only ${VOCABULARY[name].length} action(s) from the shared script. The ` +
				'scan is broken, and every bridge below would pass while being compared to nothing.'
		);
	}
}




// ==================================================
// ==================================================
// ======= 2/ What each bridge answers ==============
// ==================================================
// ==================================================

/**
 * Whether a bridge source names an action.
 *
 * A quoted-string search rather than a parse: the two drivers dispatch
 * differently (a Lua if/elseif chain against `payload.action`, versus a handler
 * table), and any parse would encode one of those shapes and miss the other.
 * What both have in common is that the action name appears as a literal.
 * @param {string} src The bridge source.
 * @param {string} action The action name.
 * @returns {boolean}
 */
function handles(src, action) {
	return src.includes(`"${action}"`) || src.includes(`'${action}'`);
}

for (const [name, drivers] of Object.entries(WINDOWS)) {
	const vocabulary = VOCABULARY[name] || [];

	for (const [driver, relative] of Object.entries(drivers)) {
		const file = path.join(SP, relative);
		if (!fs.existsSync(file)) {
			errors.push(`${relative} does not exist — ${driver} cannot host ${name} at all.`);
			continue;
		}
		const src = fs.readFileSync(file, 'utf8');
		const allowed = new Set((ALLOWED_UNHANDLED[`${driver}/${name}`] || []));

		const unhandled = vocabulary.filter((a) => !handles(src, a) && !allowed.has(a));
		if (unhandled.length > 0) {
			errors.push(
				`${relative} has no branch for ${unhandled.length} action(s) the shared UI sends: ` +
					`${unhandled.join(', ')}. The window is one shared HTML/JS application, so the control ` +
					'is on screen for this driver too — it just does nothing when clicked, which the user ' +
					'cannot tell from a misclick.'
			);
		}

		// The other direction. An action name in a bridge that the UI never sends
		// is unreachable code, and unreachable code that persists to disk reads as
		// a working feature to anyone auditing by grep.
		const spurious = [];
		for (const m of src.matchAll(/action == "([a-z_]+)"/g)) {
			if (!vocabulary.includes(m[1])) spurious.push(m[1]);
		}
		const unique = [...new Set(spurious)];
		if (unique.length > 0) {
			errors.push(
				`${relative} dispatches on ${unique.length} action(s) the shared UI never sends: ` +
					`${unique.join(', ')}. Unreachable, and it reads as a feature — grep for "delete" and ` +
					'the driver looks like it supports deleting.'
			);
		}
	}
}




// ==================================================
// ==================================================
// ======= 3/ The payload the UI actually reads =====
// ==================================================
// ==================================================

// Handling `ready` is necessary and not sufficient: the bridge has to answer it
// with the shape the UI reads. The Linux editor answered with three keys the
// shared script never looks at, so every branch above was satisfied and the
// window still opened empty. These are the keys window.initData destructures.
const REQUIRED_PAYLOAD_KEYS = {
	hotstring_editor: ['sections', 'trigger_char', 'default_priority', 'open_mode']
};

for (const [name, keys] of Object.entries(REQUIRED_PAYLOAD_KEYS)) {
	const script = fs.readFileSync(path.join(SHARED_UI, name, 'script.js'), 'utf8');
	// Confirm the UI really does read them, so this list cannot rot into a set of
	// keys nobody consumes.
	for (const key of keys) {
		if (!script.includes(`d.${key}`) && !script.includes(`D.${key}`)) {
			errors.push(
				`${name}/script.js no longer reads "${key}" — this gate is requiring a key the UI ignores. ` +
					'Update REQUIRED_PAYLOAD_KEYS rather than the bridges.'
			);
		}
	}

	for (const [driver, relative] of Object.entries(WINDOWS[name])) {
		const src = fs.readFileSync(path.join(SP, relative), 'utf8');
		const absent = keys.filter((k) => !src.includes(k));
		if (absent.length > 0) {
			errors.push(
				`${relative} never mentions ${absent.length} key(s) the shared UI reads out of the ` +
					`initial payload: ${absent.join(', ')}. Answering "ready" with a different shape opens ` +
					`the window empty, which is what ${driver} did.`
			);
		}
	}
}




// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (process.argv.includes('--measure')) {
	for (const [name, vocabulary] of Object.entries(VOCABULARY)) {
		console.log(`${name}: ${vocabulary.join(', ')}`);
		for (const [driver, relative] of Object.entries(WINDOWS[name])) {
			const src = fs.readFileSync(path.join(SP, relative), 'utf8');
			const missing = vocabulary.filter((a) => !handles(src, a));
			console.log(`  ${driver.padEnd(6)} ${missing.length ? 'missing: ' + missing.join(', ') : 'complete'}`);
		}
	}
	process.exit(0);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the hotstrings windows are shared, and the bridges behind them are not:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

const total = Object.values(VOCABULARY).reduce((n, v) => n + v.length, 0);
console.log(
	`\x1b[32m[OK] hotstrings bridge parity — ${total} action(s) across ` +
		`${Object.keys(WINDOWS).length} shared window(s), every one answered by every driver that hosts ` +
		'them, with no unreachable branches and the initial payload in the shape the UI reads.\x1b[0m'
);
