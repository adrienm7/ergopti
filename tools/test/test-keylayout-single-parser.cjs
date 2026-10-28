// tools/test/test-keylayout-single-parser.cjs

/**
 * ==============================================================================
 * MODULE: One .keylayout Reader
 * DESCRIPTION:
 * `_shared/lua/layouts/keylayout.lua` reads a macOS .keylayout into the canonical
 * parsed form that the XKB converter, the macOS and Linux managers and the
 * composer check consume (PAR-76 R23). This gate refuses a second reader in the
 * code the Lua drivers load and in the repository's JavaScript tooling, so a
 * quoting or entity rule fixed in one place cannot stay wrong in another.
 *
 * FEATURES & RATIONALE:
 * 1. A reader is recognised by what it must do: name a keylayout element in a
 *    quoted tag comparison or pattern ("keyMapSet", '<keyMap ', ...).
 * 2. Two readers are admitted with a stated reason: the web composer's own reader
 *    (a web view cannot load Lua) and the layout index builder's element-presence
 *    check. The list may only shrink: an entry whose file no longer reads a
 *    keylayout fails as stale.
 * 3. The canonical reader and its vectors must exist, and the Lua callers named
 *    below must go through it.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const CANONICAL = 'static/ergopti_plus/_shared/lua/layouts/keylayout.lua';
const ROOTS = [
	'static/ergopti_plus/macos',
	'static/ergopti_plus/linux',
	'static/ergopti_plus/_shared',
	'tools'
];
const SKIPPED = /node_modules|\/tests?\/|_generated|\/fixtures\/|\/corpus\//;
const ELEMENT = /(["'`])<?(?:keyMapSet|keyMapSelect|modifierMap|keyMap)[ >]?\1/;

/** Admitted second readers, each with the reason it cannot call the Lua one. */
const ADMITTED = new Map([
	[
		'static/ergopti_plus/_shared/ui/layout_composer/composer_model.js',
		'the web composer runs in a web view and cannot load Lua; it replays the shared vectors in _shared/tests/corpus/keylayout'
	],
	[
		'tools/build/build-layouts-index.cjs',
		'the layout index builder only checks that the required elements are present; it reads no value'
	]
]);

/** Source files whose text names a keylayout element the way a reader does. */
function readers() {
	const found = [];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			if (SKIPPED.test(full.split(path.sep).join('/') + '/')) continue;
			if (entry.isDirectory()) walk(full);
			else if (/\.(lua|cjs|js|mjs)$/.test(entry.name) && !entry.name.startsWith('test-')) {
				const code = fs
					.readFileSync(full, 'utf8')
					.split('\n')
					.filter((line) => !/^\s*(--|\/\/|\*|\/\*)/.test(line))
					.join('\n');
				if (ELEMENT.test(code)) found.push(path.relative(ROOT, full).split(path.sep).join('/'));
			}
		}
	};
	for (const root of ROOTS) walk(path.join(ROOT, root));
	return found.sort();
}

const found = readers();
assert(
	found.includes(CANONICAL),
	'the canonical reader is not recognised: the gate would admit anything'
);
const extra = found.filter((file) => file !== CANONICAL && !ADMITTED.has(file));
assert.deepStrictEqual(
	extra,
	[],
	`a second .keylayout reader appeared: ${extra.join(', ')}. Call layouts.keylayout instead, or admit it here with a reason.`
);
const stale = [...ADMITTED.keys()].filter((file) => !found.includes(file));
assert.deepStrictEqual(
	stale,
	[],
	`admitted readers that no longer read a keylayout (delete them): ${stale.join(', ')}`
);

// The Lua callers go through the canonical reader.
for (const [file, needle] of [
	['static/ergopti_plus/_shared/lua/layouts/composer.lua', 'Keylayout.parse('],
	['static/ergopti_plus/_shared/lua/layouts/xkb_converter.lua', 'keylayout']
]) {
	assert(
		fs.readFileSync(path.join(ROOT, file), 'utf8').includes(needle),
		`${file} must use the canonical reader`
	);
}
const composer = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/_shared/lua/layouts/composer.lua'),
	'utf8'
);
assert(
	!/<keyboard|<layout%s|decode_attribute/.test(composer),
	'composer.lua matches keylayout text itself'
);
for (const vector of [
	'edge_cases.json',
	'composed.canonical.json',
	'xkb_conversion_vectors.json'
]) {
	assert(
		fs.existsSync(path.join(ROOT, 'static/ergopti_plus/_shared/tests/corpus/keylayout', vector)),
		vector
	);
}

console.log(
	`[OK] one .keylayout reader in the Lua drivers and tooling; ${ADMITTED.size} admitted web/tooling reader(s) with a reason.`
);
