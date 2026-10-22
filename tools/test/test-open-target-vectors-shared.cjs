// tools/test/test-open-target-vectors-shared.cjs

/**
 * ==============================================================================
 * MODULE: Shared Open-Target Corpus Gate
 * DESCRIPTION:
 * Checks the corpus of the copy_selected_path action,
 * _shared/tests/corpus/shortcuts/open_target_vectors.json, pins the two ports
 * of its rule together (_shared/lua/open_target for macOS and Linux,
 * windows/infra/open_target.ahk for Windows) and checks that every driver
 * suite replays it.
 *
 * WHY:
 * The classifier is implemented twice. Each port is replayed against the
 * corpus by its own suites, which run on their own OS; this gate, which runs
 * everywhere, is what keeps their vocabularies, the search fallback and the
 * user-facing reports from drifting apart, and the IP-address regression
 * (192.168.1.1 sent to a web search) from leaving the corpus.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CORPUS = path.join(SP, '_shared', 'tests', 'corpus', 'shortcuts', 'open_target_vectors.json');
const LUA = path.join(SP, '_shared', 'lua', 'open_target', 'init.lua');
const AHK = path.join(SP, 'windows', 'infra', 'open_target.ahk');
const MANIFEST = path.join(SP, '_shared', 'modules', 'features', 'manifest.toml');
const ACTIONS = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

const KINDS = ['url', 'path', 'registry', 'search', 'file_name', 'unsupported', 'empty'];
const REPORT_KEYS = [
	'open_target.missing_path',
	'open_target.bare_file_name',
	'open_target.open_failed',
	'open_target.windows_only'
];

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const read = (file) => fs.readFileSync(file, 'utf8').replace(/^﻿/, '');

// ------------------------------------------------------------------
// The corpus itself.
// ------------------------------------------------------------------
const corpus = JSON.parse(read(CORPUS));
check(
	typeof corpus.rule === 'string' && corpus.rule.length > 200,
	'the corpus must document its rule'
);
check(
	corpus.env && corpus.env.windows && corpus.env.posix,
	'the corpus must give a Windows and a POSIX environment'
);
check(
	Array.isArray(corpus.vectors) && corpus.vectors.length >= 60,
	'the corpus must hold at least 60 vectors'
);
const ids = new Set();
const seen = { windows: new Set(), posix: new Set() };
const byId = {};
for (const vector of corpus.vectors || []) {
	check(
		typeof vector.id === 'string' && !ids.has(vector.id),
		`duplicate or missing id ${vector.id}`
	);
	ids.add(vector.id);
	byId[vector.id] = vector;
	check(typeof vector.text === 'string', `${vector.id}: text must be a string`);
	const windows = vector.windows || vector.expect;
	const macos = vector.macos || vector.posix || vector.expect;
	const linux = vector.linux || vector.posix || vector.expect;
	for (const [os, want] of [
		['windows', windows],
		['macos', macos],
		['linux', linux]
	]) {
		if (!want) {
			check(false, `${vector.id}: no expectation for ${os}`);
			continue;
		}
		check(KINDS.includes(want.kind), `${vector.id}: unknown kind ${want.kind} on ${os}`);
		check(typeof want.target === 'string', `${vector.id}: target must be a string on ${os}`);
		check(
			want.kind === 'unsupported' ? want.reason === 'windows_only' : want.reason === undefined,
			`${vector.id}: only an unsupported target carries the windows_only reason (${os})`
		);
		check(
			!(os === 'windows' && want.kind === 'unsupported'),
			`${vector.id}: nothing the rule names is unsupported on Windows`
		);
		check(
			!(os !== 'windows' && want.kind === 'registry'),
			`${vector.id}: only Windows opens a registry key`
		);
		seen[os === 'windows' ? 'windows' : 'posix'].add(want.kind);
	}
}
for (const kind of KINDS) {
	if (kind !== 'unsupported') check(seen.windows.has(kind), `no Windows vector of kind ${kind}`);
	if (kind !== 'registry') check(seen.posix.has(kind), `no macOS/Linux vector of kind ${kind}`);
}
// The reported bug: a selected IP address was searched instead of opened.
for (const [id, target] of [
	['ipv4_bare', 'http://192.168.1.1'],
	['ipv4_port_and_path', 'http://10.0.0.1:8080/admin']
]) {
	const vector = byId[id];
	check(
		vector &&
			vector.text &&
			vector.expect &&
			vector.expect.kind === 'url' &&
			vector.expect.target === target,
		`the corpus must keep the IP regression vector ${id} -> ${target}`
	);
}

// ------------------------------------------------------------------
// The two ports share their vocabularies.
// ------------------------------------------------------------------
const lua = read(LUA);
const ahk = read(AHK);

/**
 * Reads one list literal: Lua strings unescape their backslashes, AHK strings
 * hold them verbatim (its escape character is the backtick).
 * @param {string} source
 * @param {RegExp} pattern Captures the list's body.
 * @param {boolean} luaEscapes
 * @returns {string[]|null}
 */
function quotedList(source, pattern, luaEscapes) {
	const found = source.match(pattern);
	if (!found) return null;
	const items = luaEscapes ? /"((?:[^"\\]|\\.)*)"/g : /"([^"]*)"/g;
	return [...found[1].matchAll(items)].map((match) =>
		luaEscapes ? match[1].replace(/\\(.)/g, '$1') : match[1]
	);
}

for (const [luaName, ahkName] of [
	['KINDS', 'OPEN_TARGET_KINDS'],
	['OPAQUE_SCHEMES', 'OPEN_TARGET_OPAQUE_SCHEMES'],
	['WINDOWS_SCHEMES', 'OPEN_TARGET_WINDOWS_SCHEMES'],
	['SCRIPT_SCHEMES', 'OPEN_TARGET_SCRIPT_SCHEMES'],
	['FILE_EXTENSIONS', 'OPEN_TARGET_FILE_EXTENSIONS'],
	['REGISTRY_PREFIXES', 'OPEN_TARGET_REGISTRY_PREFIXES']
]) {
	const fromLua = quotedList(lua, new RegExp(`^M\\.${luaName} = \\{([^}]*)\\}`, 'm'), true);
	const fromAhk = quotedList(ahk, new RegExp(`^global ${ahkName} := \\[([^\\]]*)\\]`, 'm'), false);
	check(
		fromLua !== null && fromLua.length > 0,
		`the Lua port must declare M.${luaName} on one line`
	);
	check(fromAhk !== null && fromAhk.length > 0, `the AHK port must declare ${ahkName} on one line`);
	if (fromLua && fromAhk) {
		check(
			JSON.stringify(fromLua) === JSON.stringify(fromAhk),
			`M.${luaName} and ${ahkName} differ:\n  lua ${JSON.stringify(fromLua)}\n  ahk ${JSON.stringify(fromAhk)}`
		);
	}
	if (luaName === 'KINDS' && fromLua) {
		check(JSON.stringify(fromLua) === JSON.stringify(KINDS), 'the kinds changed without this gate');
	}
}
const luaRoots = [...lua.matchAll(/\b(HK[A-Z_]+) = "(HKEY_[A-Z_]+)"/g)]
	.map((m) => `${m[1]}=${m[2]}`)
	.sort();
const ahkRoots = [...ahk.matchAll(/"(HK[A-Z_]+)", "(HKEY_[A-Z_]+)"/g)]
	.map((m) => `${m[1]}=${m[2]}`)
	.sort();
check(
	luaRoots.length === 10,
	`the Lua port must spell 10 registry roots, found ${luaRoots.length}`
);
check(
	JSON.stringify(luaRoots) === JSON.stringify(ahkRoots),
	'the registry roots of the two ports differ'
);

// ------------------------------------------------------------------
// One search fallback.
// ------------------------------------------------------------------
const luaSearch = (lua.match(/^M\.DEFAULT_SEARCH_URL = "([^"]+)"/m) || [])[1];
const manifestSearch = (read(MANIFEST).match(
	/^default = \{ enabled = \w+, search_engine = "[^"]+", search_engine_url_query = "([^"]+)" \}/m
) || [])[1];
check(Boolean(luaSearch), 'the Lua port must declare M.DEFAULT_SEARCH_URL');
check(Boolean(manifestSearch), 'the shortcuts.search feature must declare search_engine_url_query');
check(
	luaSearch === manifestSearch,
	`the macOS/Linux search fallback ${luaSearch} must be the Windows default ${manifestSearch}`
);
const macApps = read(path.join(SP, 'macos', 'modules', 'shortcuts', 'actions', 'apps.lua'));
check(
	!macApps.includes('google.com/search'),
	'macOS must search through OpenTarget.DEFAULT_SEARCH_URL, not its own copy of the URL'
);

// ------------------------------------------------------------------
// The action, its reports and its consumers.
// ------------------------------------------------------------------
const actionBlock =
	(read(ACTIONS).match(/\[sg_actions\.copy_selected_path\]([\s\S]*?)\n\[/) || [])[1] || '';
check(
	/^platform = "all"$/m.test(actionBlock),
	'copy_selected_path must be offered on all three drivers'
);

for (const file of fs.readdirSync(LOCALES).filter((name) => name.endsWith('.json'))) {
	const locale = JSON.parse(read(path.join(LOCALES, file)));
	for (const key of REPORT_KEYS) {
		const text = locale[key];
		check(
			typeof text === 'string' && text.split('%s').length === 2,
			`${file}: ${key} must be a message holding exactly one %s`
		);
	}
}

const CONSUMERS = [
	{
		file: 'macos/tests/unit/modules/shortcuts/text_actions/test_open_target_vectors.lua',
		path: 'tests/corpus/shortcuts/open_target_vectors.json'
	},
	{
		file: 'linux/tests/unit/modules/shortcuts/actions/test_open_selection.lua',
		path: '_shared/tests/corpus/shortcuts/open_target_vectors.json'
	},
	{
		file: 'windows/tests/unit/modules/shortcuts/test_open_target_vectors.ahk',
		path: '\\tests\\corpus\\shortcuts\\open_target_vectors.json'
	}
];
for (const consumer of CONSUMERS) {
	const abs = path.join(SP, consumer.file);
	const source = fs.existsSync(abs) ? read(abs) : '';
	check(source.includes(consumer.path), `${consumer.file} must read the shared open-target corpus`);
}
const linuxManifest = read(path.join(SP, 'linux', 'tests', 'test_manifest.lua'));
check(
	linuxManifest.includes('"tests.unit.modules.shortcuts.actions.test_open_selection"'),
	'the Linux test manifest must list test_open_selection'
);
const ahkRunner = read(path.join(SP, 'windows', 'tests', 'run_all.ahk'));
check(
	/^#Include unit\/modules\/shortcuts\/test_open_target_vectors\.ahk$/m.test(ahkRunner),
	'windows/tests/run_all.ahk must #Include unit/modules/shortcuts/test_open_target_vectors.ahk'
);
check(
	/^#Include \.\.\/infra\/open_target\.ahk$/m.test(ahkRunner),
	'windows/tests/run_all.ahk must #Include ../infra/open_target.ahk'
);
const ahkEntry = read(path.join(SP, 'windows', 'ErgoptiPlus.ahk'));
check(
	/^#Include infra\/open_target\.ahk$/m.test(ahkEntry),
	'ErgoptiPlus.ahk must #Include infra/open_target.ahk'
);

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] shared open-target corpus: ${checks} check(s) passed (${corpus.vectors.length} vectors).\x1b[0m`
);
