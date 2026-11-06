// Execute the actual inventory guard/model and inspect the exact action scopes.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { createRequire } = require('node:module');
const root = path.resolve(process.argv[2]);
const requireRepository = createRequire(path.join(root, 'package.json'));
const toml = requireRepository('smol-toml');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const actions = toml.parse(read('static/ergopti_plus/_shared/modules/actions/actions.toml'));
const defaults = toml.parse(read('static/ergopti_plus/_shared/tap_hold/defaults.toml'));
const timings = toml.parse(read('static/ergopti_plus/_shared/modules/timings/constants.toml'));
const menu = toml.parse(read('static/ergopti_plus/_shared/modules/menu/menu.toml'));
const outputs = JSON.parse(read('src/routes/ergopti-plus/action-inventory.json'));
requireRepository(path.join(root, 'tools/codegen/codegen-feature-inventory.cjs')).check();
const model = requireRepository(
	path.join(root, 'tools/build/build-features-manifest.js')
).loadFeatureModel();
assert.equal(timings.tap_hold.one_shot_shift_timeout_ms, 2000);
assert.equal(defaults.tap_hold.keys.right_ctrl.tap_action, 'one_shot_shift');
assert.equal(defaults.hs_tap_hold.right_option.tap, 'sticky_shift');
assert.equal(actions.sg_actions.one_shot_shift.platform, 'ahk');
assert.equal(actions.sg_actions.sticky_shift.platform, 'hs');
assert.deepEqual(actions.sg_actions.one_shot_shift.equivalent_hs, ['sticky_shift']);
assert.deepEqual(actions.sg_actions.sticky_shift.equivalent_ahk, ['one_shot_shift']);
assert.equal(
	actions.sg_actions.one_shot_shift.reason_linux,
	'platform_reason.action_sticky_keys_are_the_systems'
);
const expected = {
	one_shot_shift: { windows: true, macos: false, linux: false },
	sticky_shift: { windows: false, macos: true, linux: false }
};
for (const [name, platforms] of Object.entries(expected)) {
	const row = outputs.find((row) => row.path === 'sg_actions.' + name);
	assert.ok(row);
	assert.deepEqual(row.platforms, platforms);
}
const timingMenu = menu.menu.tap_holds_menu.find((row) => row.id === 'tap_hold_timings');
assert.deepEqual(timingMenu.platforms, ['hs']);
assert.equal(timingMenu.reason_key, 'platform_reason.remap_engine_is_per_driver');
assert.ok(!model.features.some((row) => row.path === 'tap_holds.sticky_timeout_ms'));
assert.ok(
	JSON.parse(
		read('static/ergopti_plus/_shared/core/config_schema/config_key_extras.json')
	).paths.includes('tap_holds.sticky_timeout_ms')
);
for (const locale of fs
	.readdirSync(path.join(root, 'static/ergopti_plus/_shared/data/locales'))
	.filter((name) => name.endsWith('.json'))) {
	const values = JSON.parse(read('static/ergopti_plus/_shared/data/locales/' + locale));
	for (const key of [
		'sg_actions.one_shot_shift',
		'platform_reason.action_sticky_keys_are_the_systems',
		'menu.tapholds.sticky_title',
		'menu.tapholds.sticky_dialog_prompt'
	])
		assert.ok(typeof values[key] === 'string' && values[key], locale + ': ' + key);
}
console.log(
	JSON.stringify({
		actual_inventory_check: 'passed',
		actions: expected,
		shared_default_ms: timings.tap_hold.one_shot_shift_timeout_ms,
		recommended_carriers: { windows_linux: 'right_ctrl', macos: 'right_option' },
		mac_timing_menu: timingMenu,
		feature_model_has_sticky_leaf: false,
		qualification:
			'Actual feature model and generator guard plus declared action/menu data. Linux tap-only reserved one_shot_shift is not a generic action-catalogue entry; native execution and OS accessibility equivalence are not certified.'
	})
);
