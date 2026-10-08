// tools/lib/karabiner-runtime-setting.cjs

/**
 * ==============================================================================
 * MODULE: Native Karabiner Runtime Setting
 * DESCRIPTION:
 * Validates the single native-file declaration used by the choice compiler.
 * This data names persistence ownership; it grants no installation authority.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { shared } = require('./paths.cjs');

/** Refuses an ambiguous native setting before projecting its menu values. */
function validateRuntimeSetting(setting) {
	assert.ok(setting && typeof setting === 'object' && !Array.isArray(setting));
	assert.deepEqual(
		Object.keys(setting).sort(),
		[
			'$schema',
			'path',
			'file',
			'owner',
			'platforms',
			'type',
			'enum_values',
			'default',
			'recommended',
			'description_key',
			'unavailable_key'
		].sort()
	);
	assert.equal(setting.$schema, './runtime_setting.schema.json');
	assert.equal(setting.path, 'karabiner.runtime');
	assert.equal(setting.file, 'config_karabiner.toml');
	assert.equal(setting.owner, 'platform.remap.config');
	assert.deepEqual(setting.platforms, ['hs']);
	assert.equal(setting.type, 'enum');
	assert.ok(Array.isArray(setting.enum_values) && setting.enum_values.length >= 2);
	assert.equal(new Set(setting.enum_values).size, setting.enum_values.length);
	assert.ok(
		setting.enum_values.every((value) => typeof value === 'string' && /^[a-z][a-z_]*$/.test(value))
	);
	assert.ok(setting.enum_values.includes(setting.default));
	assert.ok(setting.enum_values.includes(setting.recommended));
	assert.equal(setting.description_key, 'menu.global.karabiner_runtime');
	assert.equal(setting.unavailable_key, 'menu.global.karabiner_runtime_unavailable');
	return setting;
}

/** Reads canonical native-file metadata without a competing default literal. */
function runtimeSetting() {
	return validateRuntimeSetting(
		JSON.parse(readFileSync(shared('platform/remap/runtime_setting.json'), 'utf8'))
	);
}

module.exports = { validateRuntimeSetting, runtimeSetting };
