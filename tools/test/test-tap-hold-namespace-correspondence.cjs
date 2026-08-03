// tools/test/test-tap-hold-namespace-correspondence.cjs

/**
 * ==============================================================================
 * MODULE: Tap-Hold Namespace Correspondence
 * DESCRIPTION:
 * _shared/tap_hold/defaults.toml describes the same physical keys twice, under
 * two vocabularies that no code and no test has ever compared:
 *   [tap_hold.keys.*]  read by Windows and Linux, per-key threshold
 *   [hs_tap_hold]      read by macOS, one global threshold
 *
 * Unifying them is real work with a real design question in it, and it is
 * blocked. What was NOT true is that nobody could say which key answers to
 * which: this file is that correspondence, machine-checked, so the unification
 * has a specification instead of a paragraph.
 *
 * THE CORRESPONDENCE IS BY POSITION, NOT BY NAME. The plan said
 * left_ctrl↔left_control and left_alt↔left_option and that right_ctrl had no
 * macOS counterpart at all. Read that way, almost nothing lines up. Read by
 * where the key sits on the board — a Mac bottom row carries fn/control/option/
 * command where a PC carries ctrl/win/alt — the actions fall into place:
 *   left_alt  ↔ left_command   backspace/backspace, nav layer/layer   exact
 *   left_ctrl ↔ fn             paste/paste                            exact
 *   right_ctrl↔ right_option   one_shot_shift/sticky_shift            renamed
 *   alt_gr    ↔ right_command  tab/tab, alt_gr/altgr                  renamed
 * Under the name reading, every one of those is a mismatch. right_ctrl DOES have
 * a counterpart, and two of the "differences" are one action under two spellings.
 *
 * WHAT THIS GATE HOLDS:
 * 1. Every key in the correspondence exists in both namespaces — a rename on
 *    either side breaks the mapping loudly instead of silently un-pairing a key.
 * 2. Every pair agrees, EXCEPT the ones listed as known divergences with a
 *    recorded reason. A pair that starts agreeing is reported too: the exception
 *    list may only shrink.
 * 3. Every macOS key that has no counterpart is declared, so a key added to one
 *    namespace and not the other cannot pass unnoticed.
 *
 * IT DOES NOT ENFORCE THE UNIFICATION. Renaming ids in this file changes what
 * three loaders read at boot, and the "same action, two spellings" cases have to
 * be resolved in macos/platform/remap/data/actions.json first. This gate makes
 * that change checkable; it does not make it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DEFAULTS = path.join(ROOT, 'static/ergopti_plus/_shared/tap_hold/defaults.toml');

// The physical-position correspondence. `pc` is the [tap_hold.keys.*] id read by
// Windows and Linux; `mac` is the [hs_tap_hold] id read by macOS.
const CORRESPONDENCE = [
	{ pc: 'caps_lock', mac: 'caps_lock' },
	{ pc: 'left_shift', mac: 'left_shift' },
	{ pc: 'left_ctrl', mac: 'fn' },
	{ pc: 'left_alt', mac: 'left_command' },
	{ pc: 'right_ctrl', mac: 'right_option' },
	{ pc: 'alt_gr', mac: 'right_command' },
	{ pc: 'tab', mac: 'tab' }
];

// Action ids that name the SAME behaviour under two spellings. These are the
// cheapest half of the unification — a rename, no behaviour change — and listing
// them here is what makes the genuine divergences below visible as the short
// list they actually are.
const SYNONYMS = {
	enter: 'return',
	one_shot_shift: 'sticky_shift',
	alt_gr: 'altgr'
};

// Pairs that genuinely differ, each with the reason. This list may only shrink:
// a pair that starts agreeing is reported so the entry is removed deliberately
// rather than left as a stale excuse.
const KNOWN_DIVERGENCES = {
	'caps_lock.hold': {
		pc: 'ctrl',
		mac: 'cmd',
		reason:
			'the genuine cmdorctrl distinction — the same gesture is Ctrl on a PC and Cmd on a Mac, ' +
			'which is a platform truth and not drift'
	},
	'tab.tap': {
		pc: 'alt_tab_monitor',
		mac: 'alt_tab_windows',
		reason:
			'DRIFT, and measured 2026-08-03: two different behaviours, not two names for one. ' +
			'Windows AltTabMonitor() reads the mouse position, resolves the monitor under the ' +
			'cursor, and cycles only the windows ON THAT MONITOR. macOS start_alt_tab_windows_hotkey ' +
			'binds Shift+F17 to focus_previous_window_global — the previously focused window, ' +
			'unscoped, and itself migrated away from cmd_tab so it switches WINDOWS rather than ' +
			'apps. Renaming either side would be the wrong fix: calling the macOS action ' +
			'alt_tab_monitor would claim a display scoping it does not implement. Closing this ' +
			'means DECIDING whether macOS should scope to the display under the cursor too — a ' +
			'product question, not a namespace one, and it is open rather than justified'
	},
	'tab.hold': {
		pc: 'alt',
		mac: 'fn',
		reason:
			'a Mac has an fn key where a PC bottom row does not, so tab-hold reaches a modifier here ' +
			'that has no PC equivalent'
	},
	'left_ctrl.hold': {
		pc: 'ctrl',
		mac: 'cmd',
		reason: 'the same cmdorctrl distinction as caps_lock.hold'
	},
	'left_alt.hold': {
		pc: 'nav',
		mac: 'layer',
		reason:
			'both name the navigation layer — [tap_hold.keys.*] refers to it by its layer id, ' +
			'[hs_tap_hold] by the action that activates it. One vocabulary, two levels of indirection'
	}
};

// macOS keys with no PC counterpart. A Mac bottom row simply carries more keys,
// so this is expected — but it is declared, so a key ADDED to one namespace and
// not the other cannot slip through as "probably one of those".
const MAC_ONLY = [
	'escape',
	'left_control',
	'left_option',
	'spacebar',
	'right_shift',
	'return_or_enter',
	'delete_or_backspace'
];

const errors = [];
const notes = [];




// ==================================================
// ==================================================
// ======= 1/ Parse Both Namespaces =================
// ==================================================
// ==================================================

const src = fs.readFileSync(DEFAULTS, 'utf8');

/**
 * Reads the [tap_hold.keys.<id>] blocks.
 * @returns {Object<string,{tap:string|null,hold:string|null}>}
 */
function parsePcKeys() {
	const out = {};
	const re = /^\[tap_hold\.keys\.([a-z_]+)\]([\s\S]*?)(?=^\[|\Z)/gm;
	let m;
	while ((m = re.exec(src)) !== null) {
		const body = m[2];
		const tap = body.match(/^tap_action\s*=\s*"([^"]*)"/m);
		const holdMod = body.match(/^hold_modifier\s*=\s*"([^"]*)"/m);
		const holdLayer = body.match(/^hold_layer\s*=\s*"([^"]*)"/m);
		out[m[1]] = {
			tap: tap ? tap[1] : null,
			hold: holdMod ? holdMod[1] : holdLayer ? holdLayer[1] : null
		};
	}
	return out;
}

/**
 * Reads the [hs_tap_hold] inline tables.
 * @returns {Object<string,{tap:string|null,hold:string|null}>}
 */
function parseMacKeys() {
	const out = {};
	const section = src.match(/^\[hs_tap_hold\]([\s\S]*?)(?=^\[)/m);
	if (!section) return out;
	const re = /^([a-z_]+)\s*=\s*\{\s*tap\s*=\s*"([^"]*)"\s*,\s*hold\s*=\s*"([^"]*)"\s*\}/gm;
	let m;
	while ((m = re.exec(section[1])) !== null) {
		out[m[1]] = { tap: m[2], hold: m[3] };
	}
	return out;
}

const pc = parsePcKeys();
const mac = parseMacKeys();

// Floor both parsers: one that silently stopped matching would drive every
// comparison below to "key missing" or, worse, to nothing at all.
if (Object.keys(pc).length < 7) {
	errors.push(`parsed ${Object.keys(pc).length} [tap_hold.keys.*] block(s) — expected at least 7`);
}
if (Object.keys(mac).length < 14) {
	errors.push(`parsed ${Object.keys(mac).length} [hs_tap_hold] entr(ies) — expected at least 14`);
}




// ==================================================
// ==================================================
// ======= 2/ The Correspondence Holds ==============
// ==================================================
// ==================================================

/** True when two action ids name the same behaviour. */
function sameAction(a, b) {
	if (a === b) return true;
	return SYNONYMS[a] === b || SYNONYMS[b] === a;
}

const usedDivergences = new Set();

for (const { pc: pcKey, mac: macKey } of CORRESPONDENCE) {
	if (!pc[pcKey]) {
		errors.push(`[tap_hold.keys.${pcKey}] is gone — the correspondence names it, so a rename here un-pairs a key silently`);
		continue;
	}
	if (!mac[macKey]) {
		errors.push(`[hs_tap_hold] has no "${macKey}" — the correspondence pairs it with ${pcKey}`);
		continue;
	}

	for (const slot of ['tap', 'hold']) {
		const key = `${pcKey}.${slot}`;
		const a = pc[pcKey][slot];
		const b = mac[macKey][slot];
		const known = KNOWN_DIVERGENCES[key];

		if (a === null || b === null) {
			if (!known) errors.push(`${key}: one side declares no ${slot} action (${a} vs ${b}) and nothing records why`);
			continue;
		}

		if (sameAction(a, b)) {
			if (known) {
				usedDivergences.add(key);
				errors.push(
					`${key}: recorded as a divergence ("${known.pc}" vs "${known.mac}") but the two now agree ` +
						`("${a}" vs "${b}"). Remove the entry — the exception list may only shrink.`
				);
			}
			continue;
		}

		if (!known) {
			errors.push(
				`${key}: ${pcKey} says "${a}", ${macKey} says "${b}", and nothing records why. Either they are ` +
					'two spellings of one action (add a synonym) or they are drift (add a divergence with a reason).'
			);
			continue;
		}
		if (known.pc !== a || known.mac !== b) {
			errors.push(
				`${key}: the recorded divergence is "${known.pc}" vs "${known.mac}", but the file now says ` +
					`"${a}" vs "${b}". One side changed and the reason no longer describes it.`
			);
		}
		usedDivergences.add(key);
		notes.push(`${key}: "${a}" vs "${b}" — ${known.reason}`);
	}
}

for (const key of Object.keys(KNOWN_DIVERGENCES)) {
	if (!usedDivergences.has(key)) {
		errors.push(`the divergence recorded for ${key} was never reached — the key or its pairing is gone, and the note is stale`);
	}
}




// ==================================================
// ==================================================
// ======= 3/ Nothing Unaccounted For ===============
// ==================================================
// ==================================================

const pairedMac = new Set(CORRESPONDENCE.map((c) => c.mac));
const pairedPc = new Set(CORRESPONDENCE.map((c) => c.pc));

for (const key of Object.keys(mac)) {
	if (pairedMac.has(key) || MAC_ONLY.includes(key)) continue;
	errors.push(
		`[hs_tap_hold] declares "${key}", which is neither paired with a PC key nor listed as macOS-only. ` +
			'A key added to one namespace and not the other is exactly the drift this file exists to end.'
	);
}
for (const key of Object.keys(pc)) {
	if (pairedPc.has(key)) continue;
	errors.push(`[tap_hold.keys.${key}] is paired with nothing — add it to the correspondence or to a declared exception`);
}
for (const key of MAC_ONLY) {
	if (!mac[key]) {
		errors.push(`"${key}" is listed as macOS-only but [hs_tap_hold] no longer declares it — the list is stale`);
	}
}




// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the two tap-hold namespaces no longer correspond:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] tap-hold namespaces correspond: ${CORRESPONDENCE.length} paired key(s), ` +
		`${Object.keys(SYNONYMS).length} action(s) that are one behaviour under two spellings, ` +
		`${Object.keys(KNOWN_DIVERGENCES).length} recorded divergence(s), ${MAC_ONLY.length} macOS-only key(s).\x1b[0m`
);
for (const n of notes) console.log(`     · ${n}`);
