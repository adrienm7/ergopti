// tools/test/test-magic-key-source.cjs

/**
 * ==============================================================================
 * MODULE: Physical Magic Key Single Source
 * DESCRIPTION:
 * `hotstrings.magic_key_source` names the physical key that types the magic
 * key on every driver, by its W3C KeyboardEvent.code. Its candidates live in
 * the feature manifest's enum_values, and three other files depend on that
 * list: the physical-key tables every driver resolves a code with, the config
 * schema v5 migration that turns the Windows scan code into a code, and the
 * shipped Ergopti layout extension whose declaration is the Windows last-resort
 * key. This gate pins the four together, so a candidate added to one and not
 * the others fails here instead of leaving a key no driver can resolve or a
 * Windows choice the migration drops.
 *
 * FEATURES & RATIONALE:
 * 1. Candidates. "auto" first, then exactly the character keys a registry
 *    layout defines (mac_keycodes.json) except Space, in its keyboard order.
 * 2. Resolution. Every candidate has a Windows scan code, a macOS keycode and
 *    an evdev code in physical_keys.json, and the Windows scan code equals the
 *    one mac_keycodes.json gives the emulation.
 * 3. Last resort. The shipped Ergopti extension declares a candidate, whose
 *    scan code is SC02E: the former Windows default is unchanged.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const TOML = require('smol-toml');
const tomlOwnData = require('./fixtures/toml-own-data.cjs');
const { shared, REPO_ROOT } = require('../lib/paths.cjs');
const path = require('path');

const PATH = 'hotstrings.magic_key_source';
const RETIRED_KEY = 'magic_key_source_scan';
const FORMER_WINDOWS_DEFAULT = 'SC02E';

const manifest = TOML.parse(
	fs.readFileSync(shared('settings/data/features/manifest.toml'), 'utf8')
);
const entry = (manifest.features.hotstrings || []).find(
	(feature) => feature.id === 'magic_key_source'
);
assert.ok(entry, `${PATH} must be declared in the feature manifest`);
assert.strictEqual(entry.type, 'enum', `${PATH} lists its candidates as enum_values`);
assert.strictEqual(entry.default, 'auto', 'the automatic key is the neutral default');
assert.strictEqual(
	entry.recommended,
	'auto',
	'recommending the automatic key restores the layout key'
);
assert.strictEqual(entry.platforms, undefined, 'one setting, identical on the three drivers');
assert.strictEqual(entry.enum_values[0], 'auto');

// 1. Candidates.
const layoutKeys = JSON.parse(
	fs.readFileSync(shared('layouts/data/mac_keycodes.json'), 'utf8')
).keys;
const expected = layoutKeys.map((key) => key.code).filter((code) => code !== 'Space');
assert.deepStrictEqual(
	entry.enum_values.slice(1),
	expected,
	'the candidates are the character keys a registry layout defines, Space excepted, in keyboard order'
);

// 2. Resolution.
const physical = JSON.parse(
	fs.readFileSync(shared('layouts/data/keycodes/physical_keys.json'), 'utf8')
).keys;
const scanOf = new Map(layoutKeys.map((key) => [key.code, key.ahk]));
for (const code of expected) {
	const record = physical[code];
	assert.ok(record, `${code} is in the physical-key registry`);
	for (const field of ['ahk', 'hs', 'evdev']) {
		assert.ok(record[field] !== null && record[field] !== undefined, `${code} has a ${field} id`);
	}
	assert.strictEqual(record.ahk, scanOf.get(code), `${code}: the two scan-code tables agree`);
}

// 3. Last resort.
const ergopti = TOML.parse(
	fs.readFileSync(
		path.join(REPO_ROOT, 'static', 'layouts', 'registry', 'ergopti', 'manifest.toml'),
		'utf8'
	)
);
const declared =
	ergopti.extension && ergopti.extension.magic_key && ergopti.extension.magic_key.key;
assert.ok(
	entry.enum_values.includes(declared),
	'the shipped Ergopti layout declares a candidate key'
);
assert.strictEqual(
	scanOf.get(declared),
	FORMER_WINDOWS_DEFAULT,
	'the Windows last-resort key is still the former default scan code'
);

console.log(
	`PASS: ${expected.length} physical magic-key candidates pinned to the key tables ` +
		`and the shipped Ergopti declaration (${declared}).`
);

// Configured tap ownership is independent of temporary feature gates. The
// golden corpus is hand-captured; native suites replay their real readers.
const claims = JSON.parse(
	fs.readFileSync(shared('tests/corpus/keymap/magic_source_tap_claims.json'), 'utf8')
);
const taps = JSON.parse(
	fs.readFileSync(shared('shortcuts/data/actions/tap_keys.json'), 'utf8')
).keys;
assert.strictEqual(claims.cases.length, 9, 'the independent admission cases remain complete');
for (const test of claims.cases) {
	assert.ok(entry.enum_values.includes(test.source), test.name);
	for (const platform of ['ahk', 'hs', 'evdev']) {
		const record = physical[test.source];
		const ids = record ? [record[platform]] : [];
		if (platform === 'hs' && record?.macos_iso) ids.push(record.macos_iso.hs);
		const key = taps.find((tap) => {
			const native = tap[platform === 'evdev' ? 'linux' : platform];
			return (
				(Array.isArray(native) ? native : [native]).some((id) => ids.includes(id)) &&
				(test.assignments[tap.id] || 'none') !== 'none'
			);
		});
		assert.strictEqual(key?.id || '', test.expected[platform], `${test.name}: ${platform}`);
	}
}
const luaPolicy = fs.readFileSync(shared('layouts/engine/layers/magic_key_source.lua'), 'utf8');
const windowsChoice = fs.readFileSync(
	path.join(REPO_ROOT, 'static/ergopti_plus/windows/core/ui/ui/editors.ahk'),
	'utf8'
);
assert.ok(luaPolicy.includes(claims.reason_key), 'shared source policy owns the translated reason');
assert.ok(
	windowsChoice.includes(claims.reason_key),
	'Windows uses the same existing translated reason'
);
for (const platform of ['linux', 'macos']) {
	const source = fs.readFileSync(
		path.join(
			REPO_ROOT,
			`static/ergopti_plus/${platform}/modules/${platform === 'linux' ? 'hotstrings' : 'keymap'}/magic_key_source.lua`
		),
		'utf8'
	);
	assert.ok(
		source.includes('Shared.tap_conflict('),
		`${platform} consumes the shared configured ownership policy`
	);
}

const windowsCorpusReader = fs.readFileSync(
	path.join(
		REPO_ROOT,
		'static/ergopti_plus/windows/tests/unit/modules/hotstrings/magic_key/test_magic_key_source_menu.ahk'
	),
	'utf8'
);
assert.ok(
	windowsCorpusReader.includes(
		'JsonParse(FileRead(_SharedDir . "\\tests\\corpus\\keymap\\magic_source_tap_claims.json"'
	),
	'the native Windows corpus runs through its actual JSON owner'
);

const windowsHarness = fs.readFileSync(
	path.join(REPO_ROOT, 'static/ergopti_plus/windows/tests/test_stubs.ahk'),
	'utf8'
);
assert.match(
	windowsHarness,
	/global _SharedDir\s*:=/,
	'the corpus reader uses the actual native harness shared-root owner'
);
