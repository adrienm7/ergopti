// tools/codegen/codegen-keycode-data-js.cjs

/**
 * ==============================================================================
 * MODULE: Keycode Data JS Codegen (DC-1)
 * DESCRIPTION:
 * Generates `_shared/ui/metrics_typing/_generated/keycode_data.js` from the
 * shared canon `_shared/data/keycodes/azerty.json` — the macOS virtual-keycode
 * to finger/hand/home mapping used by the typing-heatmap dashboard.
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: `state.js` used to hand-copy the full azerty.json
 *    key set as a literal `KEYCODE_DATA` array with no mechanism catching drift
 *    against the canonical JSON. This generator makes azerty.json the loaded
 *    (via build-time generation) source instead.
 * 2. Classic-script compatible: `_shared/ui/*` pages load plain `<script src>`
 *    tags (no bundler/ES modules), so the generated file is included via a
 *    `<script>` tag placed before `state.js` in `metrics_typing/index.html` —
 *    top-level `const` declarations in one classic script are visible to
 *    later classic scripts in the same document.
 * 3. Shape parity: only `kc`, `finger`, and `home` (when true) are emitted —
 *    the same three fields the hand-written KEYCODE_DATA array carried;
 *    `qwerty`/`azerty`/`hand` are display/derivable fields state.js never used.
 * 4. Encoding: written as plain UTF-8 with CRLF line endings, no BOM — matching
 *    every sibling file already committed under `_shared/ui/metrics_typing/`.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared, sharedRel } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '../..');
const OUT_PATH = path.resolve(
	ROOT,
	'static/ergopti_plus/_shared/ui/metrics_typing/_generated/keycode_data.js'
);
const AZERTY_JSON_PATH = shared('data/keycodes/azerty.json');
const AZERTY_JSON_REL = sharedRel('data/keycodes/azerty.json');

// ==================================================
// ==================================================
// ======= 1/ Source Data Loading =======
// ==================================================
// ==================================================

/**
 * Loads and validates azerty.json's `keys` array.
 * @returns {Array<{kc:number, finger:string, home?:boolean}>}
 */
function loadKeys() {
	const raw = fs.readFileSync(AZERTY_JSON_PATH, 'utf8');
	const parsed = JSON.parse(raw);
	if (!Array.isArray(parsed.keys) || parsed.keys.length === 0) {
		throw new Error(`${AZERTY_JSON_REL} must decode to an object with a non-empty "keys" array`);
	}
	for (const entry of parsed.keys) {
		if (typeof entry.kc !== 'number' || typeof entry.finger !== 'string' || entry.finger === '') {
			throw new Error(
				`${AZERTY_JSON_REL} has a "keys" entry missing a numeric "kc" or non-empty "finger": ${JSON.stringify(entry)}`
			);
		}
	}
	return parsed.keys;
}

// ==================================================
// ==================================================
// ======= 2/ JS Source Builder =======
// ==================================================
// ==================================================

/**
 * Builds the full JS source for the generated keycode data file.
 * @param {Array<{kc:number, finger:string, home?:boolean}>} keys
 * @returns {string} JS source text with bare LF newlines (normalised later).
 */
function buildJsSource(keys) {
	const lines = [];

	lines.push('// _shared/ui/metrics_typing/_generated/keycode_data.js');
	lines.push('');
	lines.push('// ==========================================');
	lines.push('// AUTO-GENERATED — do not edit manually');
	lines.push(`// Source: ${AZERTY_JSON_REL}`);
	lines.push('// Run: npm run codegen:keycode-data:js');
	lines.push('// ==========================================');
	lines.push('');
	lines.push('// Single source of truth for keycode -> finger / home assignments (DC-1).');
	lines.push('// Loaded via a <script> tag placed before state.js, which reads this global.');
	lines.push('const KEYCODE_DATA = [');
	for (const { kc, finger, home } of keys) {
		const homePart = home ? ', home: true' : '';
		lines.push(`\t{ kc: ${kc}, finger: '${finger}'${homePart} },`);
	}
	lines.push('];');

	return lines.join('\n');
}

// ==================================================
// ==================================================
// ======= 3/ File Writer =======
// ==================================================
// ==================================================

/**
 * Writes content to outPath with CRLF line endings and no BOM, matching every
 * sibling file already committed under `_shared/ui/metrics_typing/`.
 * @param {string} outPath  Absolute path to the output file.
 * @param {string} content  Source text with bare LF newlines.
 */
function writeWithCrlf(outPath, content) {
	const normalized = content.replace(/\r?\n/g, '\r\n');
	fs.mkdirSync(path.dirname(outPath), { recursive: true });
	fs.writeFileSync(outPath, normalized, 'utf8');
}

// ==================================================
// ==================================================
// ======= 4/ Main =======
// ==================================================
// ==================================================

/**
 * Entry point — loads azerty.json, builds the JS source, writes the file.
 */
function main() {
	console.log('codegen:keycode-data:js — generating keycode data JS adapter…');

	const keys = loadKeys();
	const source = buildJsSource(keys);
	writeWithCrlf(OUT_PATH, source);

	const relOut = path.relative(ROOT, OUT_PATH);
	console.log(`  Written: ${relOut} (${keys.length} key(s))`);
	console.log('codegen:keycode-data:js — done.');
}

main();
