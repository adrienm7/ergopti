// tools/test/test-menu-shared-delegation.cjs

/** Independent controls for function-bound native/shared menu reachability. */
'use strict';

const assert = require('assert');
const {
	delegatedMenuSources,
	combineMenuVisibility
} = require('../lib/menu-shared-delegation.cjs');

const fixture = `local M = {}
function M.build_entry(manifest, child)
 return manifest.build("programmable_hotstring_entry", nil, nil, { programmable_hotstrings = child })
end
function M.build_entry_rows(manifest, child)
 return M.build_entry(manifest, child)
end
function M.build(ports)
 return ports.manifest.build("programmable_hotstrings", nil, nil, nil, {
  commands = { open_user_hotstring_source = command(ports.open), reload_user_hotstring_source = command(ports.reload) }
 })
end
return M`;
const entry =
	'local Policy = require("menu.programmable_hotstrings")\nreturn Policy.build_entry_rows(Manifest, child)';
const child = 'local Policy = require("menu.programmable_hotstrings")\nreturn Policy.build(ports)';
const resolve = (sources, shared = fixture) =>
	delegatedMenuSources(
		sources.map((src, index) => ({ rel: `native${index}.lua`, src })),
		'/independent/shared',
		() => shared
	);
const names = (records) => records.map((record) => record.rel).sort();
const handlers = (records) => new Set(records.flatMap((record) => [...record.handlers]));

const platforms = ['ahk', 'hs', 'linux'];
assert.deepStrictEqual(
	combineMenuVisibility(platforms, ['hs', 'linux'], ['ahk']),
	platforms,
	'the Windows direct child and Lua parent route must both remain reachable'
);
assert.deepStrictEqual(
	combineMenuVisibility(platforms, ['ahk'], ['hs', 'linux']),
	platforms,
	'incoming route order cannot hide an earlier platform'
);
assert.deepStrictEqual(
	combineMenuVisibility(platforms, undefined, ['hs']),
	['hs'],
	'a restricted edge cannot grant undeclared native platforms'
);
assert.deepStrictEqual(
	combineMenuVisibility(platforms, ['hs'], []),
	['hs'],
	'an unavailable later route cannot erase an actual earlier route'
);

assert.deepStrictEqual(names(resolve([entry, child])), [
	'menu.programmable_hotstrings.build',
	'menu.programmable_hotstrings.build_entry',
	'menu.programmable_hotstrings.build_entry_rows'
]);
assert(handlers(resolve([entry, child])).has('open_user_hotstring_source'));
assert.deepStrictEqual(names(resolve([entry])), [
	'menu.programmable_hotstrings.build_entry',
	'menu.programmable_hotstrings.build_entry_rows'
]);
assert(
	!handlers(resolve([entry])).has('open_user_hotstring_source'),
	'a parent import cannot credit unused child commands'
);
assert.deepStrictEqual(names(resolve([child])), ['menu.programmable_hotstrings.build']);
assert(
	!resolve([child]).some((record) => record.src.includes('"programmable_hotstring_entry"')),
	'an actual child call cannot credit an unused entry'
);

for (const inactive of [
	'local Policy = require("menu.programmable_hotstrings")',
	'local Policy = require("menu.programmable_hotstrings")\n-- Policy.build(ports)',
	'local Policy = require("menu.programmable_hotstrings")\nlocal prose = "Policy.build(ports)"',
	'-- local Policy = require("menu.programmable_hotstrings")\nPolicy.build(ports)',
	'local prose = [[local Policy = require("menu.programmable_hotstrings")]]\nPolicy.build(ports)',
	'local Policy = require("menu.unowned")\nPolicy.build(ports)',
	'local Policy = require("menu.programmable_hotstrings")\nOther.build(ports)',
	'local Policy = require("menu.programmable_hotstrings")\nPolicy.not_a_method(ports)'
])
	assert.deepStrictEqual(
		resolve([inactive]),
		[],
		'imports, prose and unrelated calls convey no reachability'
	);
assert.deepStrictEqual(
	resolve([child], fixture.replace('return ports.manifest.build(', 'return ignored(')),
	[],
	'a native call without the actual shared renderer cannot credit commands'
);
assert.deepStrictEqual(
	resolve([entry], fixture.replace('return M.build_entry(manifest, child)', 'return {}')),
	[],
	'removing the actual shared entry delegation closes its route'
);

const personal = `local M = {}
function M.build(ports)
 local rows = ports.manifest.build("personal_file_controls")
 M.unavailable(ports.manifest)
 return rows
end
function M.unavailable(manifest)
 return manifest.build("personal_file_unavailable")
end
function M.directory_unavailable(manifest)
 return manifest.build("personal_directory_unavailable")
end
return M`;
const personalCall = 'local Personal = require("menu.personal_files")\nPersonal.build(ports)';
assert.deepStrictEqual(names(resolve([personalCall], personal)), [
	'menu.personal_files.build',
	'menu.personal_files.unavailable'
]);
assert.deepStrictEqual(
	names(resolve([personalCall + '\nPersonal.directory_unavailable(manifest)'], personal)),
	[
		'menu.personal_files.build',
		'menu.personal_files.directory_unavailable',
		'menu.personal_files.unavailable'
	]
);
console.log(
	'[OK] shared menu delegation: real entry/child/control routes and independent dormant-call mutations'
);
