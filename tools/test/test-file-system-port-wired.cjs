// tools/test/test-file-system-port-wired.cjs

/**
 * ==============================================================================
 * MODULE: FileSystem Port Spec Wiring Gate
 * DESCRIPTION:
 * The three drivers' file-system owners must check themselves against the shared
 * lease and atomic write spec (_shared/lua/file_system/ports.lua) when they load,
 * as the last statement of their file, and the spec's method lists must be the
 * ones the corpus names. A driver that drops the call would again learn of a
 * missing method inside a publication.
 *
 * FEATURES & RATIONALE:
 * 1. Wiring pin: in Lua the check is the root-level statement right before
 *    `return M`; in AutoHotkey it is the root-level last line of the file.
 * 2. Mutation control: the detector refuses a copy where the call is commented
 *    out, indented into a branch, or moved before the end.
 * 3. Windows cannot load the Lua spec: its generated table must project ports.lua.
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

const WINDOWS_OWNER = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'adapters',
	'file_system.ahk'
);
const AHK_CALL = 'FSPortsCheckOwner(FILE_SYSTEM_OWNER)';

/**
 * Whether an AutoHotkey text ends with the root-level check.
 * @param {string} text AutoHotkey source.
 * @returns {boolean}
 */
function wiredAhk(text) {
	return text.replace(/\s+$/, '').split('\n').at(-1) === AHK_CALL;
}

const goodAhk = `global FILE_SYSTEM_OWNER := Map()\n${AHK_CALL}\n`;
assert(wiredAhk(goodAhk), 'the AutoHotkey detector accepts the wired shape');
assert(
	!wiredAhk(goodAhk.replace(AHK_CALL, `; ${AHK_CALL}`)),
	'a commented AutoHotkey call is refused'
);
assert(
	!wiredAhk(goodAhk.replace(AHK_CALL, `\t${AHK_CALL}`)),
	'an indented AutoHotkey call is refused'
);
assert(!wiredAhk(`${AHK_CALL}\nFoo() {\n}\n`), 'an AutoHotkey call before the end is refused');
assert(
	wiredAhk(fs.readFileSync(WINDOWS_OWNER, 'utf8')),
	`${path.relative(ROOT, WINDOWS_OWNER)} must end with ${AHK_CALL}`
);

const { parseSpec, render, TARGET } = require('../codegen/codegen-file-system-ports.cjs');
const spec = parseSpec(
	fs.readFileSync(
		path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'lua', 'file_system', 'ports.lua'),
		'utf8'
	)
);
const corpus = JSON.parse(
	fs.readFileSync(
		path.join(
			ROOT,
			'static',
			'ergopti_plus',
			'_shared',
			'tests',
			'corpus',
			'file_system',
			'port_vectors.json'
		),
		'utf8'
	)
);
assert.deepEqual(
	spec.contract,
	[...corpus.required].sort(),
	'the parser reads the required methods'
);
assert.deepEqual(
	spec.capabilities,
	Object.fromEntries(
		Object.entries(corpus.capabilities).map(([name, methods]) => [name, [...methods].sort()])
	),
	'the parser reads the capabilities'
);
assert.equal(
	fs.readFileSync(TARGET, 'utf8'),
	render(spec),
	'windows/_generated/file_system_ports.ahk must project ports.lua: run the codegen'
);

console.log('PASS file system port wired: the three owners check the shared spec when they load');
