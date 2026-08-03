// tools/test/test-keyboard-slot-surface-is-live.cjs

/**
 * ==============================================================================
 * MODULE: macOS Keyboard-Slot Configuration Surface — Reachability
 * DESCRIPTION:
 * Asserts that the macOS keyboard-shortcut slot module can actually be configured
 * from the driver. This file replaces test-keyboard-slot-surface-is-dead.cjs,
 * which held the opposite measurement and said so in its own error text: the
 * module bound, persisted and released shortcuts, but its whole configuration
 * surface — get_keyboard_action, get_keyboard_slot_label, get_keyboard_assignments
 * — had zero readers, and its single writer was a reset routine clearing settings
 * that could not exist. The binding UI landed; this gate keeps it landed.
 *
 * WHY THE DIRECTION MATTERS:
 * The old gate could not tell "nobody built the UI yet" from "somebody deleted
 * it". Both look like zero readers. Now that the readers exist, an accidental
 * removal — a refactor that inlines the façade, a menu entry dropped from the
 * manifest — takes the feature back to unreachable, silently, because a feature
 * with no way in still loads, still logs, and still passes every other test.
 *
 * WHAT IS CHECKED:
 * 1. Every façade reader has at least one production caller outside the module
 *    and the façade itself.
 * 2. The writer is called with something other than the literal "none", i.e. a
 *    real assignment can be made and not merely cleared.
 * 3. The manifest still declares the menu entry that renders the UI, and the
 *    driver still registers a provider for it — a row whose provider vanished is
 *    logged and skipped at runtime, which is invisible to a user who simply finds
 *    the section gone.
 * 4. The slot groups are consistent with the prefixes the module can resolve, so
 *    no group can offer rows that resolve to no chord.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MAC = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const MODULE_REL = 'modules/shortcuts/keyboard_shortcuts.lua';
const FACADE_REL = 'modules/shortcuts/init.lua';
const MANIFEST = path.join(ROOT, 'static/ergopti_plus/_shared/modules/menu/menu_manifest.json');
const MENU_ENTRY_ID = 'keyboard_slots';

const errors = [];

/** Production Lua sources, excluding tests. */
function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'tests') walk(p, acc);
		} else if (e.name.endsWith('.lua')) acc.push(p);
	}
	return acc;
}

const sources = walk(MAC).map((f) => ({
	rel: path.relative(MAC, f).split(path.sep).join('/'),
	src: fs.readFileSync(f, 'utf8')
}));

if (sources.length < 100) {
	errors.push(`walked only ${sources.length} macOS source file(s) — the scan is broken, and every check below would pass over nothing`);
}

const moduleSrc = (sources.find((s) => s.rel === MODULE_REL) || {}).src;
if (!moduleSrc) {
	errors.push(`${MODULE_REL} is missing — it moved, and this gate no longer describes anything`);
}




// ==================================================
// ==================================================
// ======= 1/ The Surface Has Readers ===============
// ==================================================
// ==================================================

const FACADE_READERS = [
	'get_keyboard_action',
	'get_keyboard_slot_label',
	'get_keyboard_slot_groups',
	'available_keyboard_slots',
	'assigned_keyboard_slots'
];
const FACADE_WRITER = 'set_keyboard_action';

/** Files calling `name`, excluding the module and its façade. */
function callersOf(name) {
	return sources
		.filter((s) => s.rel !== FACADE_REL && s.rel !== MODULE_REL)
		.filter((s) => s.src.includes(name))
		.map((s) => s.rel);
}

for (const reader of FACADE_READERS) {
	if (callersOf(reader).length === 0) {
		errors.push(
			`${reader} has no production caller. The keyboard-slot surface is drifting back to unreachable: ` +
				'a getter nothing reads is a feature with no way in, which still loads and still logs.'
		);
	}
}

{
	const callers = callersOf(FACADE_WRITER);
	if (callers.length === 0) {
		errors.push(`${FACADE_WRITER} has no production caller — nothing can assign a slot at all.`);
	} else {
		// At least one caller must write something that is not the literal "none".
		// A driver that can only CLEAR assignments cannot create one, which is the
		// exact state this feature was in before the UI existed.
		const writesReal = callers.some((rel) => {
			const src = sources.find((s) => s.rel === rel).src;
			return [...src.matchAll(/set_keyboard_action[(\s]+([^)\n]*)/g)].some((m) => !/["']none["']/.test(m[1]));
		});
		if (!writesReal) {
			errors.push(
				`every ${FACADE_WRITER} call site writes the literal "none" (${callers.join(', ')}). Slots can be ` +
					'cleared but not bound — the feature is configurable in name only.'
			);
		}
	}
}




// ==================================================
// ==================================================
// ======= 2/ The Menu Entry Still Exists ===========
// ==================================================
// ==================================================

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const shortcutsMenu = manifest.shortcuts_menu;
if (!Array.isArray(shortcutsMenu) || shortcutsMenu.length === 0) {
	errors.push('menu_manifest.json has no shortcuts_menu array — the parse is wrong or the menu is gone');
} else {
	const entry = shortcutsMenu.find((e) => e && e.id === MENU_ENTRY_ID);
	if (!entry) {
		errors.push(
			`menu_manifest.json no longer declares the "${MENU_ENTRY_ID}" entry in shortcuts_menu — the UI ` +
				'has no place to render, and nothing else reports its absence.'
		);
	} else if (entry.type !== 'list') {
		errors.push(
			`the "${MENU_ENTRY_ID}" manifest entry is now type "${entry.type}", not "list". The rows are the ` +
				"user's own assignments; any other type either enumerates them statically (it cannot) or " +
				'builds them outside the renderer.'
		);
	}

	// A provider must be registered for it. A "list" entry with no provider is
	// logged and skipped at runtime — the section simply is not there.
	const providerRegistered = sources.some(
		(s) => s.rel !== FACADE_REL && new RegExp(`${MENU_ENTRY_ID}\\s*=\\s*function`).test(s.src)
	);
	if (!providerRegistered) {
		errors.push(
			`no macOS source registers a list provider for "${MENU_ENTRY_ID}". The manifest entry would be ` +
				'skipped with a warning nobody reads, and the section would vanish from the menu.'
		);
	}
}




// ==================================================
// ==================================================
// ======= 3/ Groups Resolve To Real Chords =========
// ==================================================
// ==================================================

if (moduleSrc) {
	// Anchored to the line start: each SLOT_MODS row is `{ "prefix", {mods} }`, so
	// an unanchored match would also collect the modifier names from the inner
	// table and report every one of them as a prefix no group offers.
	const slotMods = [...(moduleSrc.match(/local\s+SLOT_MODS\s*=\s*\{([\s\S]*?)\n\}/) || [, ''])[1].matchAll(/^\s*\{\s*"([^"]+)"/gm)].map(
		(m) => m[1]
	);
	const groups = [...(moduleSrc.match(/M\.SLOT_GROUPS\s*=\s*\{([\s\S]*?)\n\}/) || [, ''])[1].matchAll(/prefix\s*=\s*"([^"]+)"/g)].map(
		(m) => m[1]
	);

	if (slotMods.length === 0) errors.push('SLOT_MODS parsed empty — the prefix check below would pass over nothing');
	if (groups.length === 0) errors.push('M.SLOT_GROUPS parsed empty — the menu would render no groups at all');

	for (const prefix of groups) {
		if (!slotMods.includes(prefix)) {
			errors.push(
				`M.SLOT_GROUPS offers the prefix "${prefix}", which SLOT_MODS cannot resolve. Every row in that ` +
					'group would produce no chord, so the group would look configurable and bind nothing.'
			);
		}
	}

	// And every resolvable prefix should be offered: a prefix the module can bind
	// but the menu never shows is a shortcut the user cannot reach.
	for (const prefix of slotMods) {
		if (!groups.includes(prefix)) {
			errors.push(
				`SLOT_MODS resolves the prefix "${prefix}", but no group offers it. Those slots can be bound ` +
					'from a persisted setting yet never created or seen.'
			);
		}
	}
}




// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] the macOS keyboard-slot surface is not reachable:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] macOS keyboard-slot surface is live: ${FACADE_READERS.length} reader(s) called, a writer that ` +
		`binds and not only clears, and a "${MENU_ENTRY_ID}" list entry with a registered provider.\x1b[0m`
);
