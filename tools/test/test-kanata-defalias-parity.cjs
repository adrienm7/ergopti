// tools/test/test-kanata-defalias-parity.cjs

/**
 * ==============================================================================
 * MODULE: Kanata Defalias Parity Gate (LNX-4 / DD-4)
 * DESCRIPTION:
 * Verifies that the kanata.kbd tap-hold-press/one-shot timeouts match the
 * shared defaults.toml, and that the golden corpus matches what the generator
 * produces. This prevents timeout drift between the hand-written kanata.kbd
 * and the single source of truth (_shared/tap_hold/defaults.toml +
 * _shared/modules/timings/constants.toml).
 *
 * Two checks:
 *   1. kanata.kbd defalias block: every tap-hold-press timeout ms ==
 *      round(defaults.toml time_activation_seconds * 1000), and the one-shot
 *      ms == timings constants.
 *   2. Golden corpus: _shared/tap_hold/golden_kanata_defalias.kbd matches
 *      the committed kanata.kbd (or the generator output, whichever is
 *      declared as the source of truth).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '../../static/ergopti_plus');

const PASS = '\u2713';
const FAIL = '\u2717';
let pass = 0;
let fail = 0;

// ─── Load defaults.toml key configs ─────────────────────────────────────

const TOML_PATH = path.join(ROOT, '_shared/tap_hold/defaults.toml');
const TIMINGS_PATH = path.join(ROOT, '_shared/modules/timings/constants.toml');
const KANATA_PATH = path.join(ROOT, 'kanata/kanata.kbd');
const GOLDEN_PATH = path.join(ROOT, '_shared/tap_hold/golden_kanata_defalias.kbd');

// Minimal TOML section parser — extracts [tap_hold.keys.<name>] blocks
function parseTapHoldKeys(tomlSrc) {
	const keys = {};
	// Match [tap_hold.keys.<key_id>] followed by key=value lines
	const keyBlockRe = /^\[tap_hold\.keys\.([a-z_]+)\]\r?\n([^[]*)/gm;
	let m;
	while ((m = keyBlockRe.exec(tomlSrc)) !== null) {
		const keyId = m[1];
		const block = m[2];
		const key = {};
		const tapAction = block.match(/^tap_action\s*=\s*"([^"]+)"/m);
		const holdMod = block.match(/^hold_modifier\s*=\s*"([^"]+)"/m);
		const holdLayer = block.match(/^hold_layer\s*=\s*"([^"]+)"/m);
		const timeSecs = block.match(/^time_activation_seconds\s*=\s*([\d.]+)/m);
		if (tapAction) key.tap_action = tapAction[1];
		if (holdMod) key.hold_modifier = holdMod[1];
		if (holdLayer) key.hold_layer = holdLayer[1];
		if (timeSecs) key.time_activation_seconds = parseFloat(timeSecs[1]);
		keys[keyId] = key;
	}
	return keys;
}

// Extract one_shot_shift_timeout_ms from timings/constants.toml
function parseOneShotMs(timingsSrc) {
	const m = timingsSrc.match(/^one_shot_shift_timeout_ms\s*=\s*(\d+)/m);
	return m ? parseInt(m[1], 10) : null;
}

// Parse tap-hold-press and one-shot lines from kanata.kbd defalias block.
// NOTE: multiline entries (e.g. ralt) are partially parsed — only tap_ms/hold_ms
// are captured; the hold expression on the next line is lost. This is acceptable
// because the test only asserts timeout values, not expression fidelity.
// Expression parity is an OS-specific concern that the kanata_generator
// explicitly does not handle (per its ralt docstring).
function parseKanataDefalias(kbdSrc) {
	const result = {};
	// Match: <alias> (tap-hold-press <tap_ms> <hold_ms> <tap_expr> <hold_expr>)
	const thRe = /^\s*(\w+)\s+\(tap-hold-press\s+(\d+)\s+(\d+)\s+(.+)\)\s*$/gm;
	let m;
	while ((m = thRe.exec(kbdSrc)) !== null) {
		result[m[1]] = {
			type: 'tap-hold-press',
			tap_ms: parseInt(m[2], 10),
			hold_ms: parseInt(m[3], 10),
			tap_expr: m[4].trim(),
		};
	}
	// Match: <alias> (one-shot <ms> <modifier>)
	const osRe = /^\s*(\w+)\s+\(one-shot\s+(\d+)\s+(\w+)\)\s*$/gm;
	while ((m = osRe.exec(kbdSrc)) !== null) {
		result[m[1]] = {
			type: 'one-shot',
			ms: parseInt(m[2], 10),
			modifier: m[3],
		};
	}
	return result;
}

function round(n) {
	return Math.floor(n + 0.5);
}

// ─── Key alias mapping: defaults.toml key_id → kanata alias name ────────

const KEY_ALIAS = {
	caps_lock: 'cap',
	left_shift: 'lsft',
	left_ctrl: 'lctl',
	left_alt: 'lalt',
	alt_gr: 'ralt',
	tab: 'alttab',
	right_ctrl: 'ossft',
};

// ─── Load all inputs ──────────────────────────────────────────────────────

const defaultsTxt = fs.readFileSync(TOML_PATH, 'utf8');
const timingsTxt = fs.readFileSync(TIMINGS_PATH, 'utf8');
const kanataTxt = fs.readFileSync(KANATA_PATH, 'utf8');
const goldenTxt = fs.readFileSync(GOLDEN_PATH, 'utf8');

const keys = parseTapHoldKeys(defaultsTxt);
const oneShotMs = parseOneShotMs(timingsTxt);
const kanataDefalias = parseKanataDefalias(kanataTxt);

// ================================================
// ======= 1/ Timeout parity: kanata.kbd vs defaults.toml
// ================================================

console.log('\nKanata defalias parity (kanata.kbd <-> defaults.toml)');
console.log('='.repeat(60));

for (const [keyId, alias] of Object.entries(KEY_ALIAS)) {
	const kc = keys[keyId];
	if (!kc) continue;

	const entry = kanataDefalias[alias];
	if (!entry) {
		console.log(`  ${FAIL}  ${alias} (${keyId}): missing in kanata.kbd`);
		fail++;
		continue;
	}

	if (entry.type === 'one-shot') {
		// One-shot shift timeout
		const want = oneShotMs;
		const got = entry.ms;
		if (got === want) {
			console.log(`  ${PASS}  ${alias}: one-shot ${got}ms (defaults=${want}ms)`);
			pass++;
		} else {
			console.log(`  ${FAIL}  ${alias}: one-shot ${got}ms !== ${want}ms (timings/constants.toml)`);
			fail++;
		}
	} else {
		// tap-hold-press timeout
		const wantMs = round((kc.time_activation_seconds || 0.20) * 1000);
		const gotMs = entry.tap_ms;
		if (gotMs === wantMs && entry.hold_ms === wantMs) {
			console.log(`  ${PASS}  ${alias}: tap-hold-press ${gotMs}/${gotMs}ms (defaults=${wantMs}ms)`);
			pass++;
		} else {
			console.log(`  ${FAIL}  ${alias}: tap-hold-press ${gotMs}/${entry.hold_ms}ms !== ${wantMs}ms (defaults.toml)`);
			fail++;
		}
	}
}

// ================================================
// ======= 2/ Golden corpus parity
// ================================================

console.log('');
console.log('Golden corpus parity (golden_kanata_defalias.kbd <-> kanata.kbd defalias)');
console.log('='.repeat(60));

const goldenDefalias = parseKanataDefalias(goldenTxt);

for (const alias of Object.keys(kanataDefalias)) {
	const k = kanataDefalias[alias];
	const g = goldenDefalias[alias];

	if (!g) {
		console.log(`  ${FAIL}  ${alias}: in kanata.kbd but missing from golden corpus`);
		fail++;
	} else if (k.type === g.type && k.tap_ms === g.tap_ms && k.hold_ms === g.hold_ms) {
		console.log(`  ${PASS}  ${alias}: ${k.type} matches golden corpus`);
		pass++;
	} else {
		console.log(`  ${FAIL}  ${alias}: kanata=${JSON.stringify(k)} !== golden=${JSON.stringify(g)}`);
		fail++;
	}
}

// Check for extra entries in golden that aren't in kanata.kbd
for (const alias of Object.keys(goldenDefalias)) {
	if (!kanataDefalias[alias]) {
		console.log(`  ${FAIL}  ${alias}: in golden corpus but missing from kanata.kbd`);
		fail++;
	}
}

console.log('');
console.log(`Total: ${pass + fail} check(s) - ${pass} passed, ${fail} failed`);
console.log('');

process.exit(fail > 0 ? 1 : 0);
