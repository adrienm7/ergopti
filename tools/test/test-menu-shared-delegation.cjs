// tools/test/test-menu-shared-delegation.cjs

/** Independent controls for function-bound native/shared menu reachability. */
'use strict';

const assert = require('assert');
const {
	delegatedMenuSources,
	combineMenuVisibility
} = require('../lib/menu-shared-delegation.cjs');

// Exercise the actual token filter independently of publication flow decisions.
{
	const fs = require('node:fs');
	const path = require('node:path');
	const vm = require('node:vm');
	const { parse } = require('acorn');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const helper = fs.readFileSync(path.join(__dirname, '../lib/menu-shared-delegation.cjs'), 'utf8');
	const owners = parse(helper, { ecmaVersion: 'latest' }).body.filter(
		(node) => node.type === 'FunctionDeclaration' && node.id.name === 'publishesSelectedMenuGroup'
	);
	assert.equal(owners.length, 1, 'one real selected-group owner must exist');
	const filters = owners[0].body.body
		.flatMap((node) => node.declarations || [])
		.filter((node) => node.id.name === 'executable');
	assert.equal(filters.length, 1, 'one actual executable filter must exist');
	const filter = filters[0].init;
	assert.equal(filter?.type, 'ArrowFunctionExpression', 'the actual executable filter must exist');
	const maskSource = fs.readFileSync(path.join(__dirname, 'test-ahk-loop-capture.cjs'), 'utf8');
	const masks = parse(maskSource, { ecmaVersion: 'latest' }).body.filter(
		(node) => node.type === 'FunctionDeclaration' && node.id.name === 'codeLines'
	);
	assert.equal(masks.length, 1, 'one actual lexical masker must exist');
	const mask = masks[0];
	const codeLines = vm.runInNewContext('(' + maskSource.slice(mask.start, mask.end) + ')');
	const executable = vm.runInNewContext('(' + helper.slice(filter.start, filter.end) + ')', {
		codeLines,
		scriptTokens
	});
	const reference = (text) => {
		const lines = codeLines(text);
		return scriptTokens(text, '.ahk').filter((token) => {
			if (token.kind === 'string')
				return text.slice(token.start, token.end) === JSON.stringify(token.value);
			const before = text.slice(0, token.start);
			const line = before.split('\n').length - 1;
			const column = before.length - before.lastIndexOf('\n') - 1;
			return lines[line]?.slice(column, column + token.value.length) === token.value;
		});
	};
	const samples = [
		'',
		'\n',
		'\r\n',
		'\r',
		'\uFEFFalpha := 1\n',
		'alpha := 1\nbeta := 2',
		'alpha := 1\r\nbeta := 2\r\n',
		'alpha := 1\rbeta := 2',
		'Alpha := "漢字😀"\nBeta := "é"',
		'Alpha := \'"mixed"\'\nBeta := 1',
		'Alpha := "semi; -- /* quoted"\n; fake := 1\nBeta := 2',
		'Alpha := "a`"b"\nBeta := 2',
		"Alpha := 'a`'b'\nBeta := 2",
		'; leading comment\nalpha := 1',
		'alpha;symbol\n beta := 2',
		'alpha := 1 ; comment\r\nbeta := 2',
		'/* block\ncomment */\nAlpha := 1',
		'/* inline block */ Alpha := 1\nBeta := 2',
		"Alpha := '\n(\nFake()\n)\n'\nBeta := 2",
		'Alpha := "one\ntwo"\nBeta := 2',
		'Alpha := "open',
		"Alpha := 'open",
		'/* missing close\nFake()',
		'"a"\n\n\nname',
		'x\u2028y\u2029z\nlast',
		'😀x\n漢y',
		'\tA:=\tB\n\tC:=D',
		'local := {quoted: "\\n"}\n(){}[]:=',
		'\n\nA\n\nB\n'
	];
	const dense = Array.from({ length: 256 }, (_, index) => `Name${index} := ${index}\n`).join('');
	samples.push(dense);
	for (const text of [...samples, ...samples.slice().reverse()]) {
		assert.deepStrictEqual(
			executable(text),
			reference(text),
			'preserve every literal and UTF-16 position'
		);
	}
	// A boxed input observes this call only; the tokenizer and global String stay intact.
	const observed = new String(dense);
	let requestedPrefixUnits = 0;
	observed.slice = (start, end) => {
		if (start === 0 && end !== undefined) requestedPrefixUnits += end;
		return dense.slice(start, end);
	};
	assert.deepStrictEqual(executable(observed), reference(dense));
	assert(
		requestedPrefixUnits <= dense.length,
		'locating token lines must not rebuild a growing source prefix for every token'
	);
}

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

// The new physical magic-key family is credited only through its executed native route.
{
	const shared = `local M = {}
function M.menu_rows(resolver, opts)
 local manifest = opts.manifest
 local commands = { magic_key_source_capture = function() return opts.capture() end,
 magic_key_source_automatic = function() return opts.choose("auto") end }
 local children = manifest.template_rows("magic_key_source_children", commands)
 return manifest.template_rows("magic_key_source_menu", commands, {}, {magic_key_source_heading=children})
end
return M`;
	const binding =
		'local Shared = require("keymap.magic_key_source")\nlocal ManifestMenu = require("infra.manifest_menu")';
	const call = 'Shared.menu_rows(resolver, {manifest=ManifestMenu})';
	assert.deepStrictEqual(names(resolve([binding + '\n' + call], shared)), [
		'keymap.magic_key_source.menu_rows'
	]);
	assert(handlers(resolve([binding + '\n' + call], shared)).has('magic_key_source_capture'));
	assert(handlers(resolve([binding + '\n' + call], shared)).has('magic_key_source_automatic'));
	const protectedBinding = binding.replace(
		'local ManifestMenu = require("infra.manifest_menu")',
		'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")'
	);
	assert.deepStrictEqual(names(resolve([protectedBinding + '\n' + call], shared)), [
		'keymap.magic_key_source.menu_rows'
	]);
	assert.deepStrictEqual(
		resolve(
			[protectedBinding.replace('infra.manifest_menu', 'foreign.renderer') + '\n' + call],
			shared
		),
		[]
	);

	for (const inactive of [
		binding,
		binding + '\n-- ' + call,
		binding + '\nlocal x = [[' + call + ']]',
		binding + '\nForeign.' + call,
		binding + '\nForeign:' + call,
		binding + '\nfunction ' + call,
		binding + '\nOther.menu_rows(resolver, opts)',
		binding + '\n' + call.replace('ManifestMenu', 'OtherRenderer'),
		binding + '\n' + call.replace('manifest=', 'unowned=')
	])
		assert.deepStrictEqual(
			resolve([inactive], shared),
			[],
			'a dormant or foreign native route cannot borrow the family'
		);
	assert.deepStrictEqual(
		resolve(
			[binding + '\n' + call],
			shared.replaceAll('manifest.template_rows(', 'Foreign.template_rows(')
		),
		[],
		'without the actual executed renderer no shared frame or command gets credit'
	);
	for (const inactive of [
		shared.replace('local manifest = opts.manifest', 'local manifest = Other'),
		shared.replaceAll('manifest.template_rows(', 'Foreign.manifest.template_rows('),
		shared.replaceAll('manifest.template_rows(', 'function manifest.template_rows(')
	])
		assert.deepStrictEqual(
			resolve([binding + '\n' + call], inactive),
			[],
			'foreign ports and declarations are not executed renderer authority'
		);
}

// Inspect every options field: a later Lua field must not counterfeit the renderer port.
{
	const shared = `local M = {}
function M.menu_rows(resolver, opts)
 local manifest = opts.manifest
 return manifest.template_rows("magic_key_source_menu", {magic_key_source_capture=function() end})
end
return M`;
	const prefix =
		'local ManifestMenu = require("infra.manifest_menu")\nlocal Shared = require("keymap.magic_key_source")\n';
	const reached = (options) =>
		resolve([prefix + 'Shared.menu_rows(resolver, {' + options + '})'], shared);
	for (const options of [
		'manifest = ManifestMenu',
		'["manifest"] = ManifestMenu',
		'manifest = ManifestMenu; current = "auto"',
		'current = "auto"; ["manifest"] = ManifestMenu'
	])
		assert.equal(
			reached(options).length,
			1,
			'one genuine renderer field remains an active source route'
		);
	for (const options of [
		'manifest = ManifestMenu, manifest = {}',
		'manifest = {}, manifest = ManifestMenu',
		'manifest = ManifestMenu; manifest = {}',
		'manifest = ManifestMenu, ["manifest"] = {}',
		'["manifest"] = {}, manifest = ManifestMenu',
		'["manifest"] = ManifestMenu; ["manifest"] = {}',
		'manifest = ManifestMenu, ["mani" .. "fest"] = {}',
		'manifest = ManifestMenu, [dynamic_key] = {}',
		'manifest = ManifestMenu, ["manifest"] = Foreign.ManifestMenu'
	])
		assert.deepStrictEqual(
			reached(options),
			[],
			'duplicate or unprovable physical fields cannot borrow renderer authority'
		);
}

// Raw bracket-key spelling must not hide an actual Lua alias of the renderer field.
{
	const shared = `local M = {}
function M.menu_rows(resolver, opts)
 local manifest = opts.manifest
 return manifest.template_rows("magic_key_source_menu", {})
end
return M`;
	const native =
		'local ManifestMenu=require("infra.manifest_menu")\nlocal Shared=require("keymap.magic_key_source")\n';
	for (const alias of [
		String.raw`"\109anifest"`,
		String.raw`"\x6danifest"`,
		String.raw`"\z  manifest"`,
		'[[manifest]]',
		'[=[\nmanifest]=]',
		'[==[manifest]==]'
	]) {
		const source =
			native + 'Shared.menu_rows(resolver, {manifest=ManifestMenu, [ ' + alias + ' ] = {}})';
		assert.deepStrictEqual(
			resolve([source], shared),
			[],
			'escaped/long bracket keys cannot counterfeit complete-options identity'
		);
	}
}
