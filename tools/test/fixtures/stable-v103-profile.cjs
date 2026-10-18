// tools/test/fixtures/stable-v103-profile.cjs
'use strict';

/**
 * Loads the real qualification module as if its v1.0.3 scope list held only
 * `scopes`: the one-line constant edit plus the matching JSON file (or its
 * deletion when empty) that the release manager makes as scopes turn green.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');

const HELPER = path.resolve(__dirname, '../../ci/dev-release-qualification.cjs');
const CONSTANT = /const STABLE_V103_SCOPE_IDS = Object\.freeze\(\[[^\]]*\]\);/;

/** Rows for any deferrable scope: the v1.0.3 file's own, else the identical v1.0.2 row. */
function policyFor(q, scopes) {
	const real = JSON.parse(fs.readFileSync(q.STABLE_V103_POLICY_PATH, 'utf8'));
	const v102 = JSON.parse(fs.readFileSync(q.STABLE_V102_POLICY_PATH, 'utf8'));
	return {
		...real,
		scopes: Object.fromEntries(
			scopes.map((scope) => [scope, structuredClone(real.scopes[scope] || v102.scopes[scope])])
		)
	};
}

/**
 * Compiles the module with `scopes` as the v1.0.3 list. `filePresent`
 * defaults to the shipped rule: a file exists exactly when a scope remains.
 */
function loadWithV103Scopes(scopes, filePresent = scopes.length > 0) {
	const q = require(HELPER);
	const source = fs.readFileSync(HELPER, 'utf8');
	assert.equal(source.split(CONSTANT).length, 2, 'the v1.0.3 scope list must stay one constant');
	const patched = source.replace(
		CONSTANT,
		() => 'const STABLE_V103_SCOPE_IDS = Object.freeze(' + JSON.stringify(scopes) + ');'
	);
	const file = path.resolve(q.STABLE_V103_POLICY_PATH);
	const raw = JSON.stringify(policyFor(q, scopes.length ? scopes : q.STABLE_V103_SCOPE_IDS));
	const original = { readFileSync: fs.readFileSync, existsSync: fs.existsSync };
	fs.existsSync = (name) =>
		path.resolve(String(name)) === file ? filePresent : original.existsSync(name);
	fs.readFileSync = (name, ...rest) => {
		if (path.resolve(String(name)) !== file) return original.readFileSync(name, ...rest);
		if (!filePresent) throw Object.assign(new Error('ENOENT: ' + file), { code: 'ENOENT' });
		return raw;
	};
	try {
		const loaded = new Module(HELPER, module);
		loaded.filename = HELPER;
		loaded.paths = Module._nodeModulePaths(path.dirname(HELPER));
		loaded._compile(patched, HELPER);
		return loaded.exports;
	} finally {
		Object.assign(fs, original);
	}
}

/** Runs `callback` while every `require` of the module returns `exports`. */
function withQualificationModule(exports, callback) {
	const key = require.resolve(HELPER);
	require(HELPER);
	const saved = require.cache[key].exports;
	require.cache[key].exports = exports;
	try {
		return callback();
	} finally {
		require.cache[key].exports = saved;
	}
}

/** Every non-empty subset of `values`, each in the original order. */
function subsets(values) {
	const result = [];
	for (let mask = 1; mask < 1 << values.length; mask++)
		result.push(values.filter((_, index) => mask & (1 << index)));
	return result;
}

module.exports = { loadWithV103Scopes, policyFor, subsets, withQualificationModule };
