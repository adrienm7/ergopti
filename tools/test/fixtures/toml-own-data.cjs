// tools/test/fixtures/toml-own-data.cjs

/** Exact own JSON-compatible TOML data for independent reference comparisons. */
'use strict';
const assert = require('node:assert/strict');

/** Retains every own JSON-compatible TOML field without depending on table prototypes. */
function tomlOwnData(value) {
	if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
	if (typeof value === 'number') {
		assert.ok(Number.isFinite(value), 'TOML reference data must contain finite numbers');
		return value;
	}
	if (Array.isArray(value)) {
		assert.deepStrictEqual(
			Reflect.ownKeys(value),
			Array.from({ length: value.length }, (_, index) => String(index)).concat('length'),
			'TOML reference arrays must be dense and carry no hidden fields'
		);
		return value.map(tomlOwnData);
	}
	assert.ok(
		value && typeof value === 'object',
		'TOML reference data must have a JSON-compatible type'
	);
	const prototype = Object.getPrototypeOf(value);
	assert.ok(
		prototype === null || prototype === Object.prototype,
		'TOML reference tables must have a plain prototype'
	);
	return Object.fromEntries(
		Reflect.ownKeys(value).map((key) => {
			assert.strictEqual(typeof key, 'string', 'TOML reference table keys must be strings');
			const field = Object.getOwnPropertyDescriptor(value, key);
			assert.ok(
				field.enumerable && Object.hasOwn(field, 'value'),
				'TOML reference fields must be own enumerable data'
			);
			return [key, tomlOwnData(field.value)];
		})
	);
}
module.exports = tomlOwnData;
