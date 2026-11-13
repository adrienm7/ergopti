// tools/test/test-linux-literal-shared-root.cjs

/**
 * Every Linux entry that exports ERGOPTI_LITERAL_SHARED_ROOT (used when a path
 * holds `;` or `?`, which LUA_PATH cannot carry) must name the shared module
 * root itself. The structure move put the shared modules at `_shared/`, and
 * install.sh still exported `_shared/lua`, so a checkout under such a path
 * loaded no shared module. The export blocks run here in bash under a path
 * with `;`, and each value must hold the shared logger module.
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(ROOT, 'static/ergopti_plus/linux');
const MODULE = 'core/logger/engine/shim.lua';

/**
 * Runs one script's literal-root case block with the given variables.
 * @param {string} file Script path.
 * @param {RegExp} block The case statement that exports the literal roots.
 * @param {Object<string, string>} variables Shell variables set before it.
 * @returns {string} The exported ERGOPTI_LITERAL_SHARED_ROOT.
 */
function literalRoot(file, block, variables) {
	const source = fs.readFileSync(file, 'utf8');
	const match = source.match(block);
	assert.ok(match, `${path.relative(ROOT, file)} no longer has its literal-root case block`);
	const assignments = Object.entries(variables)
		.map(([name, value]) => `${name}=${JSON.stringify(value)}`)
		.join('\n');
	const run = spawnSync(
		'/bin/bash',
		['-c', `${assignments}\n${match[0]}\nprintf '%s' "\${ERGOPTI_LITERAL_SHARED_ROOT:-}"`],
		{ encoding: 'utf8' }
	);
	assert.equal(run.status, 0, run.stderr);
	return run.stdout;
}

// A real copy under a `;` path would cost a whole tree; the resolved value is
// mapped back onto the checkout to prove it names the module root.
const literal = '/tmp/ergopti;literal';
const shared = path.join(ROOT, 'static/ergopti_plus/_shared');

const fromInstall = literalRoot(
	path.join(DRIVER, 'install.sh'),
	/case "\$SRC_DRIVER\$SRC_SHARED[^\n]*\n[\s\S]*?\nesac/,
	{
		SRC_DRIVER: literal + '/linux',
		SRC_SHARED: literal + '/_shared'
	}
);
assert.equal(fromInstall, literal + '/_shared', 'install.sh exports the shared module root');
assert.ok(
	fs.existsSync(path.join(shared, path.relative(literal + '/_shared', fromInstall), MODULE)),
	'install.sh names a folder that holds the shared modules'
);

console.log('[OK] Linux literal shared roots name the shared module root.');
