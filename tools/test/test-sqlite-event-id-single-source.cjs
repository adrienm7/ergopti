// tools/test/test-sqlite-event-id-single-source.cjs

/**
 * ==============================================================================
 * MODULE: SQLite Event ID Numeric Policy Single Source
 * DESCRIPTION:
 * Lua cursor arithmetic has one shared exact-integer ceiling. This source guard
 * prevents a driver copy and requires the Linux allocator to consume the policy.
 * Native SQLite regressions independently exercise refusal and boundary IDs.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { scriptTokens, stripComments } = require('../lib/script-source.cjs');

const root = path.resolve(__dirname, '../../static/ergopti_plus');
const policy = stripComments(
	fs.readFileSync(path.join(root, '_shared/lua/sqlite/event_id_policy.lua'), 'utf8'),
	'.lua'
);
assert.match(policy, /M\.MAX_EXACT_LUA_CURSOR\s*=\s*2\s*\^\s*53\s*-\s*1/);
assert.equal((policy.match(/M\.MAX_EXACT_LUA_CURSOR\s*=/g) || []).length, 1);

let scanned = 0;
for (const driver of ['linux', 'macos']) {
	const source = fs.readFileSync(
		path.join(root, driver, 'modules/keylogger/sqlite_writer.lua'),
		'utf8'
	);
	const code = scriptTokens(source, '.lua')
		.filter((token) => token.kind !== 'string')
		.map((token) => token.value)
		.join(' ');
	scanned += 1;
	assert.doesNotMatch(
		code,
		/(?:2\s*\^\s*5\s*3|9\s*0\s*0\s*7\s*1\s*9\s*9\s*2\s*5\s*4\s*7\s*4\s*0\s*9\s*9\s*1)/,
		`${driver} must consume the shared exact cursor bound instead of copying it`
	);
	assert.doesNotMatch(code, /MAX_EXACT_LUA_CURSOR\s*=/);
	if (driver === 'linux') {
		const withoutComments = stripComments(source, '.lua');
		const binding = withoutComments.match(
			/local\s+(\w+)\s*=\s*require\(["']sqlite\.event_id_policy["']\)/
		);
		assert.ok(binding, 'Linux allocator must import the shared numeric policy');
		assert.match(code, new RegExp('\\b' + binding[1] + '\\s*\\.\\s*MAX_EXACT_LUA_CURSOR\\b'));
	}
}
assert.equal(scanned, 2, 'both native Lua writers must be scanned');
console.log('SQLite event cursor policy: one shared bound, two Lua writers checked.');
