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
 * 3. Migration. The v4_to_v5 step maps both spellings of every candidate's
 *    scan code to its code, then renames the key, for Windows files only.
 * 4. Last resort. The shipped Ergopti extension declares a candidate, whose
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

const manifest = TOML.parse(fs.readFileSync(shared('modules/features/manifest.toml'), 'utf8'));
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
	fs.readFileSync(shared('modules/layouts/mac_keycodes.json'), 'utf8')
).keys;
const expected = layoutKeys.map((key) => key.code).filter((code) => code !== 'Space');
assert.deepStrictEqual(
	entry.enum_values.slice(1),
	expected,
	'the candidates are the character keys a registry layout defines, Space excepted, in keyboard order'
);

// 2. Resolution.
const physical = JSON.parse(
	fs.readFileSync(shared('data/keycodes/physical_keys.json'), 'utf8')
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

// 3. Migration.
const registry = TOML.parse(fs.readFileSync(shared('core/config_schema/migrations.toml'), 'utf8'));
const step = registry.steps.v4_to_v5;
assert.ok(step, 'config schema v5 carries the physical magic-key step');
assert.deepStrictEqual(step.drivers, ['ahk'], 'only Windows files carry the retired scan code');
const maps = step.ops.filter((op) => op.op === 'map_value');
const renames = step.ops.filter((op) => op.op === 'rename');
assert.strictEqual(step.ops.at(-1), renames[0], 'the rename runs after every value is mapped');
assert.deepStrictEqual(
	tomlOwnData(renames),
	[{ op: 'rename', section: 'hotstrings', key: RETIRED_KEY, to_key: 'magic_key_source' }],
	'the retired key becomes the shared one'
);
const mapped = new Map();
for (const op of maps) {
	assert.strictEqual(op.section, 'hotstrings');
	assert.strictEqual(op.key, RETIRED_KEY, 'every value map reads the retired key');
	for (const pair of op.map) {
		assert.ok(!mapped.has(pair.from), `${pair.from} is mapped once`);
		mapped.set(pair.from, pair.to);
	}
}
// The Windows reader matched ^SC[0-9A-F]{3}$ without regard to case, so every
// letter-case spelling of a candidate's scan code was a working key: "Sc024" and
// "SC02e" as much as "SC024" and "sc024".
const caseSpellings = (text) =>
	[...text].reduce(
		(spellings, ch) => {
			const forms = [...new Set([ch.toUpperCase(), ch.toLowerCase()])];
			return spellings.flatMap((prefix) => forms.map((form) => prefix + form));
		},
		['']
	);
assert.deepStrictEqual(
	caseSpellings('SC02E').length,
	8,
	'S, C and the hex letter each take two cases'
);
const wanted = new Map();
for (const code of expected) {
	for (const spelling of caseSpellings(scanOf.get(code))) wanted.set(spelling, code);
}
assert.deepStrictEqual(
	[...mapped.entries()].sort(),
	[...wanted.entries()].sort(),
	'every letter case the Windows reader accepted maps every candidate scan code to its code'
);

// 4. Last resort.
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
	`PASS: ${expected.length} physical magic-key candidates pinned to the key tables, ` +
		`${mapped.size} migrated scan-code spellings and the shipped Ergopti declaration (${declared}).`
);

// Configured tap ownership is independent of temporary feature gates. The
// golden corpus is hand-captured; native suites replay their real readers.
const claims = JSON.parse(
	fs.readFileSync(shared('tests/corpus/keymap/magic_source_tap_claims.json'), 'utf8')
);
const taps = JSON.parse(fs.readFileSync(shared('modules/actions/tap_keys.json'), 'utf8')).keys;
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
const luaPolicy = fs.readFileSync(shared('lua/keymap/magic_key_source.lua'), 'utf8');
const windowsChoice = fs.readFileSync(
	path.join(REPO_ROOT, 'static/ergopti_plus/windows/ui/editors.ahk'),
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
	path.join(REPO_ROOT, 'static/ergopti_plus/windows/tests/unit/test_magic_key_source_menu.ahk'),
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
