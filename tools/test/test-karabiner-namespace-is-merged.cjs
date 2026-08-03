// tools/test/test-karabiner-namespace-is-merged.cjs

/**
 * ==============================================================================
 * MODULE: The Karabiner and Gesture Action Namespaces Are One
 * DESCRIPTION:
 * macos/platform/remap/data/actions.json and _shared/modules/actions/actions.toml
 * describe the same actions. Until 2026-08-03 they overlapped on 18 ids out of 73
 * and nothing compared them, so a feature could be reachable from a remapped key
 * and unreachable from a swipe with no symptom anywhere.
 *
 * WHAT THE MERGE ACTUALLY WAS, once measured:
 *   18 already shared an id.
 *   32 were genuinely missing and became rows.
 *    4 were NOT missing — they are Karabiner spellings of an action the catalogue
 *      already carried, and became aliases.
 *   19 are hold-only and stay out.
 * The four are the interesting number. `return` emits the same key as `enter`,
 * `delete_fwd` the same as `delete`, and `cmd_tab` and `alt_tab_apps_list` both
 * emit cmd+tab, which `app_switcher` already did. Declaring them as rows put four
 * duplicate entries in the gesture picker — the same label twice, for the same
 * keystroke — which is not a merged namespace but a doubled one.
 *
 * THE FOUR RULES HELD HERE:
 * 1. Every TAPPABLE Karabiner action is either a catalogue row or an alias. A new
 *    one added to actions.json fails here rather than quietly becoming a feature
 *    only the remap layer can reach.
 * 2. Every HOLD-ONLY action is neither. A gesture has no duration, so a row for
 *    one is a picker entry that cannot work.
 * 3. Every alias resolves to a real row, and is not itself a row. An alias to a
 *    deleted row makes the remap picker fall back to a raw identifier.
 * 4. No two rows emit the same macOS keystroke — which is what made the four
 *    duplicates findable in the first place. The one recorded exception is
 *    declared below with its reason.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CATALOGUE = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');
const KARABINER = path.join(SP, 'macos', 'platform', 'remap', 'data', 'actions.json');

// Floors — a walk that collapses would find nothing missing and pass having
// compared nothing, which is the failure mode every gate in this suite shares.
const MIN_KARABINER_ACTIONS = 70;
const MIN_CATALOGUE_ROWS = 150;

// Rows that legitimately emit the same macOS keystroke, each with the reason.
// This list may only shrink: a pair that stops colliding is reported so the
// entry is removed deliberately rather than left as a stale excuse.
const KNOWN_SAME_KEYSTROKE = {
	'close_window+tab_close':
		'cmd+w is genuinely one keystroke with two meanings on macOS — it closes the front TAB in a ' +
		'tabbed application and the WINDOW everywhere else. The two rows name the two intents the ' +
		'user has; the platform, not the catalogue, is what collapses them'
};

const errors = [];




// ==================================================
// ==================================================
// ======= 1/ Read both namespaces ==================
// ==================================================
// ==================================================

const parsed = toml.parse(fs.readFileSync(CATALOGUE, 'utf8'));
const rows = parsed.sg_actions || {};
const aliases = parsed.karabiner_aliases || {};
const order = (parsed.sg_order && parsed.sg_order.items) || [];

const karabiner = JSON.parse(fs.readFileSync(KARABINER, 'utf8'));

if (!Array.isArray(karabiner) || karabiner.length < MIN_KARABINER_ACTIONS) {
	errors.push(
		`read ${Array.isArray(karabiner) ? karabiner.length : 0} Karabiner action(s), floor ` +
			`${MIN_KARABINER_ACTIONS} — the catalogue walk is broken and every comparison below is vacuous`
	);
}
if (Object.keys(rows).length < MIN_CATALOGUE_ROWS) {
	errors.push(
		`read ${Object.keys(rows).length} sg_actions row(s), floor ${MIN_CATALOGUE_ROWS} — the TOML ` +
			'parse is broken'
	);
}




// ==================================================
// ==================================================
// ======= 2/ Nothing tappable is unreachable =======
// ==================================================
// ==================================================

const tappable = [];
const holdOnly = [];
for (const action of karabiner) {
	if (!action || typeof action.id !== 'string') continue;
	(action.tappable === false ? holdOnly : tappable).push(action.id);
}

const unreachable = tappable.filter((id) => !rows[id] && !aliases[id]);
if (unreachable.length > 0) {
	errors.push(
		`${unreachable.length} tappable Karabiner action(s) have neither a catalogue row nor an alias: ` +
			`${unreachable.join(', ')}. The remap layer can put them on a key and the gesture picker ` +
			'cannot offer them, so the feature exists on one input path and not the other — with no ' +
			'error on either. Add a row, or an alias if the catalogue already carries the behaviour.'
	);
}

const heldButDeclared = holdOnly.filter((id) => rows[id] || aliases[id]);
if (heldButDeclared.length > 0) {
	errors.push(
		`${heldButDeclared.length} hold-only Karabiner action(s) are declared as gesture actions: ` +
			`${heldButDeclared.join(', ')}. A gesture has no duration — a swipe happens and ends — so ` +
			'"hold Shift" cannot be expressed as one. These would be picker rows the user can bind and ' +
			'that can never work.'
	);
}




// ==================================================
// ==================================================
// ======= 3/ Every alias is honest =================
// ==================================================
// ==================================================

for (const [alias, target] of Object.entries(aliases)) {
	if (rows[alias]) {
		errors.push(
			`"${alias}" is both an alias and a row. The alias exists precisely so there is no row: ` +
				'keeping both puts the action in the picker twice.'
		);
	}
	if (!rows[target]) {
		errors.push(
			`"${alias}" aliases "${target}", which is not a catalogue row. The remap picker resolves ` +
				`its label through the alias, so it would fall back to showing the raw id "${alias}".`
		);
	}
	if (order.includes(alias)) {
		errors.push(`"${alias}" is an alias but appears in sg_order — the picker would list an id with no row`);
	}
}

if (Object.keys(aliases).length === 0) {
	errors.push(
		'the alias table is empty. Four Karabiner ids were measured as exact duplicates of existing ' +
			'rows on 2026-08-03; an empty table means either they became rows again (four duplicate ' +
			'picker entries) or the section was dropped (four raw identifiers in the remap menu).'
	);
}




// ==================================================
// ==================================================
// ======= 4/ No two rows emit one keystroke ========
// ==================================================
// ==================================================

/** The macOS keystroke a row emits, or null when it emits none. */
function keystrokeOf(entry) {
	if (!entry || typeof entry !== 'object' || !entry.emit_hs_key) return null;
	const mods = (entry.emit_hs_mods || []).slice().sort().join('+');
	return `${String(entry.emit_hs_key).toLowerCase()}|${mods}`;
}

const byKeystroke = new Map();
for (const [id, entry] of Object.entries(rows)) {
	const key = keystrokeOf(entry);
	if (!key) continue;
	if (!byKeystroke.has(key)) byKeystroke.set(key, []);
	byKeystroke.get(key).push(id);
}

const seenExceptions = new Set();
for (const [keystroke, ids] of byKeystroke) {
	if (ids.length < 2) continue;
	const label = ids.slice().sort().join('+');
	if (KNOWN_SAME_KEYSTROKE[label]) {
		seenExceptions.add(label);
		continue;
	}
	errors.push(
		`${ids.join(' and ')} both emit ${keystroke.replace('|', ' with mods ')} on macOS. The picker ` +
			'would list them as separate choices doing the same thing. Either one is an alias of the ' +
			'other, or the difference is real and one of the two rows is wrong.'
	);
}

for (const label of Object.keys(KNOWN_SAME_KEYSTROKE)) {
	if (!seenExceptions.has(label)) {
		errors.push(
			`the recorded same-keystroke exception for ${label} was never reached — the rows changed and ` +
				'the reason no longer describes anything. Remove it; this list may only shrink.'
		);
	}
}




// ==================================================
// ==================================================
// ======= 5/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the Karabiner and gesture namespaces have come apart:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] one action namespace: ${tappable.length} tappable Karabiner action(s) all reachable ` +
		`(${tappable.length - Object.keys(aliases).length} rows, ${Object.keys(aliases).length} aliases), ` +
		`${holdOnly.length} hold-only correctly absent, ${Object.keys(KNOWN_SAME_KEYSTROKE).length} ` +
		'recorded same-keystroke pair(s).\x1b[0m'
);
