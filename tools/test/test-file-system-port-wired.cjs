// tools/test/test-file-system-port-wired.cjs

/**
 * ==============================================================================
 * MODULE: FileSystem Port Spec Wiring Gate
 * DESCRIPTION:
 * Both Lua drivers' file-system owners must check themselves against the shared
 * lease and atomic write spec (_shared/lua/file_system/ports.lua) when they load,
 * as the last statement before they return, and the spec's method lists must be
 * the ones the corpus names. A driver that drops the call would again learn of a
 * missing method inside a publication.
 *
 * FEATURES & RATIONALE:
 * 1. Wiring pin: the check is the root-level statement right before `return M`.
 * 2. Mutation control: the detector refuses a copy where the call is commented
 *    out, indented into a branch, or moved before the end.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = ['macos', 'linux'].map((driver) =>
	path.join(ROOT, 'static', 'ergopti_plus', driver, 'adapters', 'file_system.lua')
);
const CALL = 'require("file_system.ports").check_owner(M)';

/**
 * Whether a Lua text ends with the root-level check followed only by the return.
 * @param {string} text Lua source.
 * @returns {boolean}
 */
function wired(text) {
	const lines = text.replace(/\s+$/, '').split('\n');
	return (
		lines.length > 2 && lines.at(-1) === 'return M' && lines.at(-3) === CALL && lines.at(-2) === ''
	);
}

const good = `local M = {}\n${CALL}\n\nreturn M\n`;
assert(wired(good), 'the detector accepts the wired shape');
assert(!wired(good.replace(CALL, `-- ${CALL}`)), 'a commented call is refused');
assert(!wired(good.replace(CALL, `\t${CALL}`)), 'an indented call is refused');
assert(!wired(`${CALL}\nlocal M = {}\n\nreturn M\n`), 'a call before the end is refused');

for (const file of DRIVERS) {
	assert(
		wired(fs.readFileSync(file, 'utf8')),
		`${path.relative(ROOT, file)} must end with ${CALL}`
	);
}

console.log('PASS file system port wired: both owners check the shared spec when they load');
