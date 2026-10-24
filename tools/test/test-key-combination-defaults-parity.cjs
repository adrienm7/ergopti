// tools/test/test-key-combination-defaults-parity.cjs

/**
 * ==============================================================================
 * MODULE: Key-Combination Defaults Parity (PAR-17)
 * DESCRIPTION:
 * The key-combination defaults the three drivers ship are the same, by physical
 * position of the keys, except where an OS-specific reason is real and recorded
 * here. Windows and Linux ship three recommended "tap while another key is held"
 * pairs (AltGr then LAlt, AltGr then CapsLock, LAlt then CapsLock) declared once
 * in the feature manifest. macOS declares its pairs under `[hs_combos]` of
 * _shared/tap_hold/defaults.toml, keyed by the Mac key names; a Mac bottom row
 * carries command where a PC carries alt, so the correspondence is by position:
 * AltGr is the right Command key, LAlt the left Command key.
 *
 * WHAT THIS HOLDS:
 * 1. Each of the three Windows/Linux pairs ships, on macOS, the position-equivalent
 *    pair with the position-equivalent action in its tap slot: Ctrl+Backspace is
 *    Option+Backspace, Ctrl+Delete is Option+Delete forward, CapsWord is CapsWord.
 * 2. Nothing else ships on macOS: no other pair, no chord (combo) slot and no hold
 *    slot, because Windows and Linux have none. An exception is added to
 *    ALLOWED_MACOS_EXTRAS with its reason, never silently.
 * 3. Windows and Linux declare the same recommendation (platforms and values).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const paths = require('../lib/paths.cjs');

// PC key id -> macOS combo key id, by position on the board.
const MAC_KEY = { alt_gr: 'rcmd', left_alt: 'lcmd', caps_lock: 'caps' };

// PC action id -> the macOS action id that does the same thing there.
const MAC_ACTION = {
	ctrl_backspace: 'opt_backspace',
	ctrl_delete: 'opt_delete_fwd',
	caps_word: 'capsword'
};

// macOS pairs that ship something Windows and Linux do not, each with a real
// OS-specific reason. Empty today: the list may only grow with a reason.
const ALLOWED_MACOS_EXTRAS = {};

/**
 * Reads the `[hs_combos]` rows of the shared defaults.
 * @param {string} source Text of defaults.toml.
 * @returns {Map<string, {combo: string, tap: string, hold: string}>} Rows by id.
 */
function macosCombos(source) {
	const section = /^\[hs_combos\]$([\s\S]*?)(?=^\[|(?![\s\S]))/m.exec(source);
	assert(section, '[hs_combos] must exist in the shared tap-hold defaults');
	const rows = new Map();
	for (const line of section[1].split('\n')) {
		const m =
			/^([a-z0-9_]+)\s*=\s*\{\s*combo\s*=\s*"([^"]*)",\s*tap\s*=\s*"([^"]*)",\s*hold\s*=\s*"([^"]*)"\s*\}/.exec(
				line
			);
		if (m) rows.set(m[1], { combo: m[2], tap: m[3], hold: m[4] });
	}
	return rows;
}

async function main() {
	const { parse: parseSource } = await import('smol-toml');
	const tomlOwnData = require('./fixtures/toml-own-data.cjs');
	const parse = (source) => tomlOwnData(parseSource(source));
	const manifest = parse(
		fs
			.readFileSync(paths.shared('modules/features/manifest.toml'), 'utf8')
			.replace(
				/^\[\[features\.([^\]]+)\]\]$/gm,
				(_match, section) => `[[entries]]\nsection = "${section}"`
			)
	);
	const pairs = manifest.entries.filter(
		(entry) => entry.section === 'shortcuts.key_combination_taps'
	);
	assert.equal(pairs.length, 3, 'the three recommended pairs are the whole shipped set');
	const rows = macosCombos(fs.readFileSync(paths.shared('tap_hold/defaults.toml'), 'utf8'));
	assert(rows.size > 100, 'the full macOS combination matrix must be loaded');

	const expectedMacos = new Map();
	for (const entry of pairs) {
		assert.deepEqual(
			entry.platforms,
			['ahk', 'linux'],
			`${entry.id}: Windows and Linux declare the same recommendation`
		);
		const [first, second] = entry.id.split('_then_');
		const id = `${MAC_KEY[first]}_${MAC_KEY[second]}`;
		const action = MAC_ACTION[entry.recommended];
		assert(MAC_KEY[first] && MAC_KEY[second], `${entry.id}: no macOS position for its keys`);
		assert(action, `${entry.id}: no macOS action for ${entry.recommended}`);
		expectedMacos.set(id, action);
		const row = rows.get(id);
		assert(row, `macOS declares no ${id} combination row`);
		assert.equal(
			row.tap,
			action,
			`${id}: macOS must ship ${action} (the position-equivalent of ${entry.recommended})`
		);
	}
	for (const [id, row] of rows) {
		const tap = expectedMacos.get(id) ?? 'none';
		const extra = ALLOWED_MACOS_EXTRAS[id];
		if (extra) continue;
		assert.equal(
			row.combo,
			'none',
			`${id}: Windows and Linux have no chord slot, macOS ships none`
		);
		assert.equal(row.hold, 'none', `${id}: no hold slot is shipped on any driver`);
		assert.equal(row.tap, tap, `${id}: shipped on macOS but not on Windows and Linux`);
	}
	console.log(
		`\x1b[32m[OK] key-combination defaults agree: ${expectedMacos.size} pair(s) shipped identically ` +
			`across ${rows.size} macOS rows, no chord, no hold, no extra pair.\x1b[0m`
	);
}

main().catch((error) => {
	console.error('\x1b[31m[ERROR] key-combination defaults parity:\x1b[0m', error.message);
	process.exit(1);
});
