'use strict';
// Inspect the actual feature model and public projections, never a private model.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(process.argv[2] || '');
assert(process.argv[2], 'Pass repository root');
const model = require(path.join(root, 'tools/build/build-features-manifest.js')).loadFeatureModel();
const rows = model.features.filter(
	(row) => row.section === 'shortcuts.caps_word' || row.section === 'shortcuts.caps_word.pointer'
);
assert.equal(rows.length, 8);
const idle = rows.find((row) => row.id === 'idle_timeout_seconds');
assert.equal(idle.type, 'number');
assert.equal(idle.default, 10);
assert.equal(idle.recommended, 10);
assert.equal(idle.family, 'setting');
assert.deepEqual(idle.preset_values, [0, 1, 3, 5, 10, 30, 60]);
const terms = rows.find((row) => row.id === 'terminators');
assert.deepEqual(terms.default, [
	'space',
	'nbsp',
	'nnbsp',
	'tab',
	'enter',
	'comma',
	'semicolon',
	'period'
]);
assert.deepEqual(terms.recommended, terms.default);
assert.equal(terms.family, 'setting');
const site = JSON.parse(
	fs.readFileSync(path.join(root, 'src/routes/ergopti-plus/feature-inventory.json'), 'utf8')
);
const menu = JSON.parse(
	fs.readFileSync(
		path.join(root, 'static/ergopti_plus/_shared/modules/menu/menu_manifest.json'),
		'utf8'
	)
);
const languages = fs
	.readdirSync(path.join(root, 'static/ergopti_plus/_shared/data/locales'))
	.filter((name) => name.endsWith('.json'));
const mapping = { ahk: 'windows', hs: 'macos', linux: 'linux' };
let projectedChecks = 0;
for (const row of rows) {
	const full = `${row.section}.${row.id}`;
	assert.equal(row.family, 'setting');
	for (const os of ['macos', 'linux', 'windows']) {
		if (os === 'windows' && !row.platforms.includes('ahk')) assert.equal(os in row.requires, false);
		else
			assert.deepEqual(
				row.requires[os],
				os === 'macos' ? ['karabiner'] : os === 'linux' ? ['evdev', 'uinput'] : []
			);
	}
	const projected = site.find((value) => value.path === full);
	assert(projected, full);
	for (const [platform, os] of Object.entries(mapping)) {
		assert.equal(projected.platforms[os], row.platforms.includes(platform));
		projectedChecks++;
	}
	for (const language of languages) {
		const locale = JSON.parse(
			fs.readFileSync(path.join(root, 'static/ergopti_plus/_shared/data/locales', language), 'utf8')
		);
		assert.equal(typeof locale[row.description_key], 'string');
		assert(locale[row.description_key].trim());
		if (row.reason_key) assert(locale[row.reason_key]?.trim());
	}
}
const gesture = rows.find((row) => row.id === 'gesture');
assert.deepEqual(gesture.platforms, ['hs', 'linux']);
assert.equal(gesture.reason_key, 'platform_reason.caps_word_gestures_stay_with_windows');
const choice = menu.caps_word_auto_off_group.find((row) => row.id === 'caps_word_idle_timeout');
assert.deepEqual(
	choice.choices.map((row) => row.value),
	idle.preset_values
);
assert.equal(choice.choices[0].i18n, 'menu.caps_word.idle_timeout_never');
assert.equal('custom_command' in choice, false);
const actions = require(path.join(root, 'node_modules/smol-toml')).parse(
	fs.readFileSync(
		path.join(root, 'static/ergopti_plus/_shared/modules/actions/actions.toml'),
		'utf8'
	)
).sg_actions;
assert.equal(actions.caps_word.platform, 'ahk,linux');
assert.deepEqual(actions.caps_word.equivalent_hs, ['capsword']);
assert.equal(actions.capsword.platform, 'hs');
assert.deepEqual(actions.capsword.equivalent_ahk, ['caps_word']);
assert.deepEqual(actions.capsword.equivalent_linux, ['caps_word']);
assert.equal(actions.toggle_capslock.platform, 'all');
console.log(
	JSON.stringify({
		declared_rows: rows.length,
		projected_platform_checks: projectedChecks,
		locales: languages.length,
		idle: {
			default: idle.default,
			recommended: idle.recommended,
			presets: idle.preset_values
		},
		terminators: terms.default,
		pointer: rows
			.filter((row) => row.section.endsWith('.pointer'))
			.map((row) => ({
				id: row.id,
				platforms: row.platforms,
				default: row.default,
				reason_key: row.reason_key || null
			})),
		actions: { caps_word: actions.caps_word, capsword: actions.capsword },
		qualification:
			'Actual shared feature model, actual generated site/menu data and all current locale labels; not native availability or semantics.'
	})
);
