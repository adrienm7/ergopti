// tools/test/test-ahk-local-same-as-global.cjs

/**
 * ==============================================================================
 * MODULE: AHK LocalSameAsGlobal Gate
 * DESCRIPTION:
 * Static gate for #Warn LocalSameAsGlobal. AutoHotkey shows only the first few
 * of these warnings per load, so a test child run under "#Warn All" turned red
 * one local at a time (Any, IsAlnum, File, Type, then t, Promise and Features
 * in the v1.0.7 preflight). This gate replays the rule without AutoHotkey and
 * lists every hit at once.
 *
 * FEATURES & RATIONALE:
 * 1. Self-test: the replay must flag the shapes that shipped (a built-in
 *    class or function, the user function t, a vendor class, a script-level
 *    loop variable, a function nested in a script-level block, a hotkey body)
 *    and must not flag a parameter, a declaration, a member write or a
 *    fat-arrow parameter.
 * 2. Library: every production file of the Windows driver and _shared, read as
 *    one load, holds no local that shadows a global. Each child loads a subset
 *    of these files, so this covers every combination a test can build. The
 *    entry script that turns the warning off itself is not part of any child.
 * 3. Children: every test that writes a "#Warn All" child is resolved to the
 *    files that child loads (the production owners of the symbols it names,
 *    the .ahk paths it names, its fixtures, and their #Include closure); the
 *    child's own globals then shadow no local of what it loads.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { analyse, hitsAmong, localSameAsGlobal } = require('./lib/ahk-local-same-as-global.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BASE = path.join(ROOT, 'static', 'ergopti_plus');
const WINDOWS = path.join(BASE, 'windows');
const TESTS = path.join(WINDOWS, 'tests');
// The resident entry declares "#Warn LocalSameAsGlobal, Off"; no child includes it.
const ENTRY = path.join(WINDOWS, 'ErgoptiPlus.ahk');

let failures = 0;
function check(condition, message) {
	if (condition) return;
	failures++;
	console.error(`FAIL: ${message}`);
}

function relative(file) {
	return path.relative(BASE, file).split(path.sep).join('/');
}

function readAhk(file) {
	return fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
}

function listAhk(directory, skip) {
	const out = [];
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const full = path.join(directory, entry.name);
		if (skip(full)) continue;
		if (entry.isDirectory()) out.push(...listAhk(full, skip));
		else if (entry.name.endsWith('.ahk')) out.push(full);
	}
	return out.sort();
}

// ── 1. Self-test on the shapes that shipped ─────────────────────────────────

function names(files) {
	return localSameAsGlobal(files.map(([file, source]) => ({ path: file, source })))
		.map((hit) => `${hit.fn}:${hit.name}`)
		.sort();
}

const flagged = [
	['built-in class', [['a', 'F() {\n\tAny := 1\n}\n']], ['F:Any']],
	['built-in function', [['a', 'F() {\n\tIsAlnum := 1\n}\n']], ['F:IsAlnum']],
	[
		'user function t',
		[
			['a', 't(Key) {\n\treturn Key\n}\n'],
			['b', 'F() {\n\tif FileExist(t := "x")\n\t\treturn t\n}\n']
		],
		['F:t']
	],
	[
		'vendor class from a method',
		[
			['a', 'class Promise {\n}\n'],
			['b', 'class W {\n\tBegin() {\n\t\tPromise := this.Fn.Call()\n\t}\n}\n']
		],
		['W.Begin:Promise']
	],
	[
		'script-level loop variable',
		[
			['a', 'for sc, entry in M()\n\tR(entry)\n'],
			['b', 'G() {\n\tEntry := 1\n}\n']
		],
		['G:Entry']
	],
	[
		'function nested in a script-level block',
		[
			[
				'a',
				'if X {\n\tSearch(*) {\n\t\tCount := 1\n\t}\n}\nG() {\n\tSearch := 1\n\tCount := 2\n}\n'
			]
		],
		['G:Search']
	],
	['hotkey body', [['a', '^a:: {\n\tFile := 1\n}\n']], ['hotkey:File']],
	['multi-line parameter list', [['a', 'F(A,\n\t\tB) {\n\tMenu := A\n}\n']], ['F:Menu']],
	['catch variable', [['a', 'F() {\n\ttry X()\n\tcatch as Format\n\t\treturn\n}\n']], ['F:Format']]
];
for (const [label, files, expected] of flagged)
	check(
		JSON.stringify(names(files)) === JSON.stringify(expected),
		`self-test must flag ${label}: ${names(files)}`
	);

const silent = [
	['a parameter', 'F(Menu) {\n\tMenu := 1\n}\n'],
	[
		'a global declaration on a continuation line',
		'F() {\n\tglobal A\n\t\t, Menu\n\tMenu := 1\n}\n'
	],
	['an unclosed initialiser', 'F() {\n\tglobal Menu := G(\n\t\t1)\n}\n'],
	['a local or static declaration', 'F() {\n\tlocal Menu := 1\n\tstatic File := 0\n}\n'],
	['an assume-global function', 'F() {\n\tglobal\n\tMenu := 1\n}\n'],
	['a member write', 'F() {\n\tthis.Menu := 1, Obj.File := 2, ++Owner.generation\n}\n'],
	['a fat-arrow parameter', 'F() {\n\treturn (Menu := "") => Menu\n}\n'],
	['a built-in variable', 'F() {\n\tA_MaxHotkeysPerInterval := 1\n}\n'],
	[
		'text in strings and comments',
		'F() {\n\tX := "Menu := 1" ; File := 2\n\t/*\n\tGui := 3\n\t*/\n}\n'
	],
	[
		'a closure sharing its outer local',
		'class Owner {\n}\nF() {\n\tOwnerName := 1\n\tInner() {\n\t\tOwnerName := 2\n\t}\n}\n'
	]
];
for (const [label, source] of silent)
	check(
		names([['a', source]]).length === 0,
		`self-test must not flag ${label}: ${names([['a', source]])}`
	);

// ── 2. Production library ───────────────────────────────────────────────────

const production = [
	...listAhk(WINDOWS, (full) => full === TESTS || full === ENTRY),
	...listAhk(path.join(BASE, '_shared'), () => false)
];
check(
	production.length > 400,
	`the production inventory looks truncated: ${production.length} files`
);
const entrySource = readAhk(ENTRY);
check(
	/^#Warn LocalSameAsGlobal, Off$/m.test(entrySource),
	'the excluded entry must turn the warning off itself'
);
const analysed = new Map(production.map((file) => [file, analyse(relative(file), readAhk(file))]));
function report(label, hits) {
	for (const hit of hits)
		check(
			false,
			`${label}: ${hit.path}:${hit.line} ${hit.fn} assigns local ${hit.name}, a global name`
		);
}
report('library', hitsAmong([...analysed.values()]));

// ── 3. Every "#Warn All" child ──────────────────────────────────────────────

const owners = new Map();
for (const [file, result] of analysed)
	for (const name of result.defined) {
		const key = name.toLowerCase();
		if (!owners.has(key)) owners.set(key, []);
		owners.get(key).push(file);
	}
const knownFiles = [...production, ...listAhk(TESTS, () => false)];

/** Files a #Include line of `file` names, relative to that file (AHK v2). */
function includesOf(file, source) {
	const out = [];
	let base = path.dirname(file);
	for (const match of source.matchAll(
		/^[ \t]*#Include[ \t]+(?:\*i[ \t]+)?([^;\r\n]+?)[ \t]*(?:[ \t];.*)?$/gim
	)) {
		const target = match[1].trim();
		if (target.startsWith('<')) continue;
		const resolved = path.resolve(
			base,
			target.replace(/%A_LineFile%\\\.\.\\?/i, '').replace(/\\/g, '/')
		);
		if (fs.existsSync(resolved) && fs.statSync(resolved).isDirectory()) base = resolved;
		else if (fs.existsSync(resolved)) out.push(resolved);
	}
	return out;
}

/** The files a test's child loads, from the symbols and paths the test names. */
function childClosure(testSource) {
	const seeds = new Set();
	for (const literal of testSource.matchAll(/"([^"\r\n]*)"|'([^'\r\n]*)'/g)) {
		const value = literal[1] ?? literal[2];
		if (/^[A-Za-z_]\w*$/.test(value))
			for (const owner of owners.get(value.toLowerCase()) ?? []) seeds.add(owner);
		for (const named of value.matchAll(/[\w\\/.]*\.ahk/g)) {
			const suffix = '/' + named[0].replace(/\\/g, '/').replace(/^[./]+/, '');
			for (const file of knownFiles)
				if (file.split(path.sep).join('/').endsWith(suffix)) seeds.add(file);
		}
	}
	const closure = new Set();
	const queue = [...seeds];
	while (queue.length) {
		const file = queue.pop();
		if (closure.has(file) || file === ENTRY) continue;
		closure.add(file);
		queue.push(...includesOf(file, readAhk(file)));
	}
	return closure;
}

const children = listAhk(TESTS, () => false).filter((file) => {
	const source = readAhk(file);
	return source.includes('#Warn All') && !/LocalSameAsGlobal,\s*Off/.test(source);
});
check(
	children.length > 50,
	`the "#Warn All" child inventory looks truncated: ${children.length} tests`
);
const testAnalyses = new Map();
for (const test of children) {
	const closure = childClosure(readAhk(test));
	const loaded = [...closure].map((file) => {
		if (analysed.has(file)) return analysed.get(file);
		if (!testAnalyses.has(file)) testAnalyses.set(file, analyse(relative(file), readAhk(file)));
		return testAnalyses.get(file);
	});
	report(`child of ${relative(test)}`, hitsAmong(loaded));
}

// The v1.0.7 child that went red must resolve to the owners that warned.
const errorChild = path.join(TESTS, 'unit', 'ui', 'webview', 'test_error_dialog_startup_owner.ahk');
const errorClosure = new Set([...childClosure(readAhk(errorChild))].map(relative));
for (const expected of [
	'windows/vendor/WebView2.ahk',
	'windows/vendor/Promise.ahk',
	'windows/infra/webview_browser_warmup.ahk',
	'windows/ui/healthcheck/core.ahk',
	'windows/tests/fixtures/error_dialog_startup_owner_body.ahk'
])
	check(errorClosure.has(expected), `the error-startup child must resolve to ${expected}`);

if (failures) {
	console.error(`${failures} LocalSameAsGlobal check(s) failed.`);
	process.exit(1);
}
console.log(
	`OK: LocalSameAsGlobal replay — ${production.length} production files, ${children.length} "#Warn All" children, no local shadows a global.`
);
