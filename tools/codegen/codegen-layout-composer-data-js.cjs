// tools/codegen/codegen-layout-composer-data-js.cjs

/**
 * ==============================================================================
 * MODULE: Layout Composer Data Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/layout_composer/_generated/composer_data.js`, the keys
 * the layout composer page and model know: the 49 keys a registry layout
 * defines, each with the macOS code the .keylayout numbers it by and its
 * geometry on an ANSI and an ISO board, from:
 *   - _shared/modules/layouts/mac_keycodes.json (keys, macOS codes, conventions);
 *   - _shared/data/keycodes/physical_keys.json (geometry).
 *
 * FEATURES & RATIONALE:
 * 1. Classic script: `_shared/ui/*` pages load plain `<script src>` tags and
 *    the macOS and Linux hosts inline them, so the data is a top-level const,
 *    not a module or a fetch.
 * 2. The key list keeps the order of the shared table, which reads by row.
 * 3. A key without geometry on a board (the ISO-only key left of Z) has no
 *    entry for it; the page draws the keys of the board it shows.
 * 4. Deterministic: no timestamp.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const { shared, sharedRel } = require('../lib/paths.cjs');

const OUT_PATH = shared('ui', 'layout_composer', '_generated', 'composer_data.js');
const MAC_KEYCODES_PATH = shared('modules', 'layouts', 'mac_keycodes.json');
const PHYSICAL_KEYS_PATH = shared('data', 'keycodes', 'physical_keys.json');
const SOURCES = ['modules/layouts/mac_keycodes.json', 'data/keycodes/physical_keys.json'];

// ======================
// ======= 1/ Data ======
// ======================

/**
 * Builds the data object.
 * @returns {{schema_version: number, conventions: string[], keys: object[]}}
 */
function buildData() {
	const table = JSON.parse(fs.readFileSync(MAC_KEYCODES_PATH, 'utf8'));
	const physical = JSON.parse(fs.readFileSync(PHYSICAL_KEYS_PATH, 'utf8')).keys;
	const keys = table.keys.map((entry) => {
		const record = physical[entry.code];
		if (!record || !record.geometry)
			throw new Error(`${entry.code} of mac_keycodes.json has no geometry in physical_keys.json`);
		return { code: entry.code, mac: entry.mac, geometry: record.geometry };
	});
	return { schema_version: 1, conventions: table.conventions, keys };
}

// ==========================
// ======= 2/ JS source =====
// ==========================

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 */
function buildSource() {
	const data = buildData();
	const keyLines = data.keys.map((key) => `\t\t${JSON.stringify(key)}`).join(',\n');
	const lines = [
		'// _shared/ui/layout_composer/_generated/composer_data.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		...SOURCES.map((s) => `// Source: ${sharedRel(s)}`),
		'// Run: npm run codegen:layout-composer-data:js',
		'// ==========================================',
		'',
		'// The keys a registry layout defines, as the layout composer reads them.',
		'// Loaded by a <script> tag before the model and the page scripts.',
		'const LAYOUT_COMPOSER_DATA = {',
		`\t"schema_version": ${data.schema_version},`,
		`\t"conventions": ${JSON.stringify(data.conventions)},`,
		'\t"keys": [',
		keyLines,
		'\t]',
		'};',
		''
	];
	return lines.join('\n');
}

/**
 * Writes the generated file.
 */
function main() {
	console.log('codegen:layout-composer-data:js — generating the layout composer data…');
	fs.mkdirSync(require('path').dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:layout-composer-data:js — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildData, buildSource, OUT_PATH };
