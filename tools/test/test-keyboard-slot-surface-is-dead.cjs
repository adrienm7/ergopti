// tools/test/test-keyboard-slot-surface-is-dead.cjs

/**
 * ==============================================================================
 * MODULE: macOS Keyboard-Slot Configuration Surface — Reachability
 * DESCRIPTION:
 * Records, as an executable measurement, that the macOS keyboard-shortcut slot
 * module has a configuration surface nothing uses. This is not a bug to fix by
 * deleting: the module is half of a feature whose other half — a binding UI —
 * was never built. The gate exists so the state is visible and cannot quietly
 * change in either direction.
 *
 * WHAT WAS MEASURED (macos/modules/shortcuts/keyboard_shortcuts.lua):
 *   M.DEFAULTS            empty, with a comment saying so by design
 *   M.get_action          0 production callers
 *   M.get_slot_label      0 production callers
 *   M.get_assignments     0 production callers
 *   M.set_action          1 production caller, which writes the literal "none"
 *   M.start / M.stop      real work — the module is not dead, its CONFIG is
 *
 * The single writer is `clear_keyboard_shortcut_settings()` in ui/menu/init.lua:
 * a reset routine that walks hs.settings for the `keyboard_shortcut_` prefix and
 * sets each match to "none". Nothing in the driver ever writes a key with that
 * prefix, and DEFAULTS is empty, so it is a reset path for a feature that cannot
 * be configured — it iterates over keys that cannot exist.
 *
 * WHY A GATE AND NOT A DELETION:
 * Deleting the surface would make building the binding UI harder, and the module
 * genuinely runs (start/stop are live). Deleting the reset routine would leave
 * settings stranded if the UI ever lands. The honest move is to hold the
 * measurement still: if someone builds the UI, the reader counts stop being zero
 * and this gate says so, prompting a deliberate update rather than leaving a
 * stale comment behind.
 *
 * IT ALSO STOPS THE DEAD SURFACE GROWING. A new unread getter here is a new
 * thing that looks implemented and is not, which is the exact shape of the 136
 * unreachable label entries and the 16-of-21 locale table already found in this
 * codebase.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MAC = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const MODULE_REL = 'modules/shortcuts/keyboard_shortcuts.lua';
const FACADE_REL = 'modules/shortcuts/init.lua';

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
	errors.push(`walked only ${sources.length} macOS source file(s) — the scan is broken`);
}

const moduleSrc = (sources.find((s) => s.rel === MODULE_REL) || {}).src;
if (!moduleSrc) {
	errors.push(`${MODULE_REL} is missing — it moved, and this measurement no longer describes anything`);
}

// ── DEFAULTS must stay empty, or the feature has gained real defaults ───────

if (moduleSrc) {
	const block = moduleSrc.match(/M\.DEFAULTS\s*=\s*\{([\s\S]*?)\n\}/);
	if (!block) {
		errors.push(`${MODULE_REL}: M.DEFAULTS not found in the expected form`);
	} else {
		const entries = block[1]
			.split('\n')
			.map((l) => l.replace(/--.*$/, '').trim())
			.filter(Boolean);
		if (entries.length > 0) {
			errors.push(
				`${MODULE_REL}: M.DEFAULTS now declares ${entries.length} default assignment(s). That is a ` +
					'real change — slots would start bound on a fresh install. Update this gate deliberately.'
			);
		}
	}
}

// ── The façade re-exports, and who actually calls them ─────────────────────

const FACADE_READERS = ['get_keyboard_action', 'get_keyboard_slot_label', 'get_keyboard_assignments'];
const FACADE_WRITER = 'set_keyboard_action';

/** Files calling `name`, excluding the façade's own re-export line. */
function callersOf(name) {
	return sources
		.filter((s) => s.rel !== FACADE_REL && s.rel !== MODULE_REL)
		.filter((s) => s.src.includes(name))
		.map((s) => s.rel);
}

for (const reader of FACADE_READERS) {
	const callers = callersOf(reader);
	if (callers.length > 0) {
		errors.push(
			`${reader} now has ${callers.length} production caller(s) (${callers.join(', ')}). Something ` +
				'reads a slot assignment for the first time — the binding UI may have landed, in which ' +
				'case this gate should be replaced by tests of that UI.'
		);
	}
}

{
	const callers = callersOf(FACADE_WRITER);
	if (callers.length === 0) {
		errors.push(
			`${FACADE_WRITER} now has NO production caller. The reset routine in ui/menu/init.lua was the ` +
				'only one; if it went away, slot settings can no longer be cleared at all.'
		);
	} else if (callers.length > 1) {
		errors.push(
			`${FACADE_WRITER} now has ${callers.length} production callers (${callers.join(', ')}). It had ` +
				'exactly one, writing the literal "none". A second writer means slots can now be bound — ' +
				'update this gate.'
		);
	} else {
		// The single caller must still be writing only "none". Anything else means
		// a real assignment is being made somewhere.
		const src = sources.find((s) => s.rel === callers[0]).src;
		const call = src.match(/set_keyboard_action[,\s]+([^)\n]*)/);
		if (call && !/["']none["']/.test(call[1])) {
			errors.push(
				`${callers[0]}: set_keyboard_action is called with something other than "none" ` +
					`(${call[1].trim()}). Slots are being bound for real now.`
			);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] keyboard-slot configuration surface changed:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	console.error(
		'    This gate holds a measurement, not a rule. If the binding UI landed, that is good news — ' +
			'replace this file with tests of it.'
	);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] macOS keyboard-slot config surface is still unreachable: DEFAULTS empty, 0 readers, ' +
		'1 writer that only clears to "none".\x1b[0m'
);
