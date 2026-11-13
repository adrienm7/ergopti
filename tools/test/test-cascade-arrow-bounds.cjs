// tools/test/test-cascade-arrow-bounds.cjs

/**
 * ==============================================================================
 * MODULE: Cascade Arrow Bounds Single Source
 * DESCRIPTION:
 * `hotstrings.cascade_max_arrows` counts the ARROWS of a hotstring chain: 1 is a
 * single expansion (no cascading), 2 allows `a` -> `b` -> `c`, up to 10. The
 * bounds are stated by the feature manifest (default, recommended and menu
 * presets), the config schema, the shared Lua engine (macOS and Linux) and the
 * Windows engine. This gate pins the four together. The v13 -> v14 step that
 * turned the former `cascade_depth` into the new leaf was squashed on
 * 2026-11-11 with every step below v20.
 *
 * FEATURES & RATIONALE:
 * 1. Manifest. Presets are exactly the whole numbers from the lower to the upper
 *    bound; the default and the recommended value are inside them.
 * 2. Schema. Its integer leaf has the same minimum and maximum.
 * 3. Engines. The shared Lua engine and the Windows engine declare the same two
 *    constants, and the Windows config reader restates the range.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const TOML = require('smol-toml');
const { shared, REPO_ROOT } = require('../lib/paths.cjs');
const path = require('path');

const read = (file) => fs.readFileSync(file, 'utf8');
const LEAF = 'cascade_max_arrows';

const manifest = TOML.parse(read(shared('settings/data/features/manifest.toml')));
const entry = (manifest.features.hotstrings || []).find((feature) => feature.id === LEAF);
assert.ok(entry, `hotstrings.${LEAF} must be declared in the feature manifest`);

// 1. Manifest.
const presets = entry.preset_values;
const low = presets[0];
const high = presets[presets.length - 1];
assert.strictEqual(low, 1, 'one arrow (a single expansion) is the lowest setting');
assert.deepStrictEqual(
	presets,
	Array.from({ length: high - low + 1 }, (_, index) => low + index),
	'the presets are every whole number from the lower to the upper bound'
);
assert.ok(entry.default >= low && entry.default <= high, 'the default is inside the bounds');
assert.ok(entry.recommended >= low && entry.recommended <= high, 'the recommended value is inside');
assert.strictEqual(entry.default, 3, 'the default chain is three arrows');
assert.strictEqual(entry.platforms, undefined, 'one setting, identical on the three drivers');

// 2. Schema.
const schema = JSON.parse(read(shared('settings/data/config_schema/config.schema.json')));
const findLeaf = (node) => {
	if (node === null || typeof node !== 'object') return undefined;
	if (Object.prototype.hasOwnProperty.call(node, LEAF)) return node[LEAF];
	for (const child of Object.values(node)) {
		const found = findLeaf(child);
		if (found) return found;
	}
	return undefined;
};
const leaf = findLeaf(schema);
assert.ok(leaf, `the schema must declare ${LEAF}`);
assert.strictEqual(leaf.type, 'integer');
assert.strictEqual(leaf.minimum, low, 'the schema minimum is the lowest setting');
assert.strictEqual(leaf.maximum, high, 'the schema maximum is the highest setting');

// 3. Engines.
const luaEngine = read(shared('hotstrings/engine/matcher/init.lua'));
assert.ok(luaEngine.includes(`M.CASCADE_MIN_ARROWS = ${low}`), 'the shared Lua engine lower bound');
assert.ok(
	luaEngine.includes(`M.CASCADE_MAX_ARROWS = ${high}`),
	'the shared Lua engine upper bound'
);
const windows = path.join(REPO_ROOT, 'static/ergopti_plus/windows/shortcuts/engine');
const ahkEngine = read(path.join(windows, 'hotstrings/hotstring_engine_main.ahk'));
assert.ok(ahkEngine.includes(`global HSE_CASCADE_MIN_ARROWS := ${low}`), 'the Windows lower bound');
assert.ok(
	ahkEngine.includes(`global HSE_CASCADE_MAX_ARROWS := ${high}`),
	'the Windows upper bound'
);
const ahkReader = read(path.join(windows, 'feature_state.ahk'));
assert.ok(
	ahkReader.includes(`(Raw is Integer) and Raw >= ${low} and Raw <= ${high}`),
	'the Windows config reader restates the same range'
);

console.log('Cascade arrow bounds: manifest, schema and both engines agree.');
