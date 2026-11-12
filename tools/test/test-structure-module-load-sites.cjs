// tools/test/test-structure-module-load-sites.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan One-Word Module Names
 * DESCRIPTION:
 * The structure plan renames Lua modules (`json` becomes
 * `core.text.engine.json`). A one-word module name is also an ordinary word:
 * a file type ("json"), a slot kind ("chord"), an action ("wrap_pair") or a
 * timings section ("logger"). Applying the plan once rewrote all 404 such strings in
 * S01, turning `Timings.count("logger", "retention_days")` into a read of a
 * section that does not exist. A one-word name now moves only where it is
 * loaded: a require argument or a package.loaded / package.preload key.
 * Dotted names keep the context-free rewrite, which their module lists rely on.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Plan = require('../audit/structure/plan.cjs');

/** Whether the first quoted `token` in `text` is a module load site. */
function site(text, token) {
	const index = text.indexOf(`"${token}"`);
	assert.ok(index >= 0, `the probe holds "${token}"`);
	return Plan.isModuleLoadSite(text, index);
}

const loads = [
	'local Json = require("json")',
	'local Json = require "json"',
	'package.loaded["json"] = stub',
	'package.preload["json"] = loader',
	'local ok, Json = pcall(require, "json")'
];
for (const text of loads) assert.equal(site(text, 'json'), true, `a load site: ${text}`);

const words = [
	'pcall(Timings.count, "logger", "retention_days")',
	'if kind == "chord" then',
	'local types = { "json", "toml" }',
	'action = "wrap_pair"'
];
for (const text of words) {
	const token = text.match(/"([a-z_]+)"/)[1];
	assert.equal(site(text, token), false, `an ordinary word, not a module: ${text}`);
}
console.log('[OK] one-word module names move only where they are loaded.');
