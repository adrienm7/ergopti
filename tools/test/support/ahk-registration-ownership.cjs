// tools/test/support/ahk-registration-ownership.cjs

/** Receives two real registration owners without loading their native callbacks. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { scriptTokens } = require('../../lib/script-source.cjs');
const root = path.resolve(__dirname, '../../..');
const source = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/tests/unit/test_key_combinations.ahk'),
	'utf8'
);
const owners = [
	['Assigned', '_KCT_RegisterPairClearAvailability', '_KCT_PairClearAvailability'],
	['Missing', '_KCT_RegisterAltGrUnsetCases', '_KCT_AltGrSuffixUnsetState']
];
function registrationBlocks(source) {
	const tokens = scriptTokens(source, '.ahk');
	const depth = [];
	let nesting = 0;
	for (const token of tokens) {
		if (token.value === '}' && token.kind === 'symbol') nesting -= 1;
		depth.push(nesting);
		if (token.value === '{' && token.kind === 'symbol') nesting += 1;
	}
	return owners.map(([variable, owner, callback]) => {
		const active = tokens
			.map((token, index) => ({ token, index }))
			.filter(({ token }) => token.kind === 'identifier' && token.value === owner);
		const start = active.length ? active[0].token.start : -1;
		if (start < 0) {
			// Retain the actual old registration for causal pre-fix receiving.
			const old = new RegExp('^for ' + variable + ' in [^\\n]+\\n(?:\\t[^\\n]+\\n)+', 'm').exec(
				source
			);
			assert.ok(old, 'the actual registration owner must be present: ' + owner);
			const first = tokens.findIndex((token) => token.start === old.index);
			assert.ok(
				first >= 0 && tokens[first].value === 'for' && depth[first] === 0,
				'the old loop is active top-level code'
			);
			return { text: old[0], old: old[0] };
		}
		assert.equal(active.length, 2, 'one active definition and one active immediate call: ' + owner);
		assert.equal(depth[active[0].index], 0, 'the actual definition is top-level');
		assert.equal(depth[active[1].index], 0, 'the actual registration call is top-level');
		for (const item of active)
			assert.deepEqual(
				tokens.slice(item.index + 1, item.index + 3).map((token) => token.value),
				['(', ')']
			);
		assert.equal(
			tokens[active[0].index + 3].value,
			'{',
			'the first active occurrence is the function definition'
		);
		const end = source.indexOf('\n}\n' + owner + '()\n', start);
		assert.ok(end > start, 'the immediate owner call must remain present');
		assert.equal(
			active[1].token.start,
			end + 3,
			'the exact immediate call is active code, not a comment/string'
		);
		const text = source.slice(start, end + ('\n}\n' + owner + '()\n').length);
		const prefix = owner + '() {\n\tlocal ' + variable + '\n';
		assert.ok(text.startsWith(prefix), 'the registration variable has explicit local ownership');
		const body = text.slice(prefix.length, text.indexOf('\n}\n') + 1);
		const lines = body.split(/(?<=\n)/);
		assert.ok(
			lines.every((line) => line.startsWith('\t')),
			'the exact body is owned by its helper'
		);
		const old = lines.map((line) => line.slice(1)).join('');
		assert.ok(old.startsWith('for ' + variable + ' in '));
		assert.equal((old.match(/\bTest\(/g) || []).length, 1, 'one real registration per vector');
		assert.ok(
			old.includes(callback + '.Bind(' + variable + ')'),
			'the native callback identity is unchanged'
		);
		return { text, old };
	});
}
const blocks = registrationBlocks(source);

for (const [index, block] of blocks.entries()) {
	if (block.text === block.old) continue; // The actual old loop proceeds to warning receiving.
	const owner = owners[index][1];
	const call = owner + '()\n';
	const definition = block.text.slice(0, -call.length);
	for (const replacement of [
		'/*\n' + block.text + '*/\n',
		'/*\n' + definition + '*/\n' + call,
		definition + '; ' + call,
		definition + '/*\n' + call + '*/\n',
		'ignored := "' + block.text.replace(/`/g, '``').replace(/"/g, '`"').replace(/\n/g, '`n') + '"\n'
	]) {
		const changed = source.replace(block.text, replacement);
		assert.notEqual(changed, source);
		assert.throws(
			() => registrationBlocks(changed),
			'commented-out actual definition/call must refuse'
		);
	}
}

for (const block of blocks) {
	assert.doesNotMatch(
		block.text,
		/#Include|::|\b(?:DllCall|Hotkey|SetTimer|Send|Run)\(/i,
		'the receiving graph contains no native action, include or input registration'
	);
}
const warningSources = [
	['static/ergopti_plus/windows/infra/toml/toml_document.ahk', '_TOML_ConfigInlineAssignment'],
	['static/ergopti_plus/windows/adapters/http_client.ahk', 'SystemProxy_ResolveAsync']
].map(([file, functionName]) => {
	const text = fs.readFileSync(path.join(root, file), 'utf8');
	const match = new RegExp('^' + functionName + '\\([^\\n]+\\) \\{\\n.*?^\\}\\n', 'ms').exec(text);
	assert.ok(match, 'the actual uncalled warning producer must be present: ' + functionName);
	assert.ok(
		scriptTokens(text, '.ahk').some(
			(token) =>
				token.kind === 'identifier' && token.start === match.index && token.value === functionName
		),
		'the producer definition must be active code'
	);
	assert.doesNotMatch(match[0], /^\s*#Include|^[^ \t\n][^\n]*::/m);
	return match[0];
});
const expected = [
	[
		'key combinations: shared clear availability assigned=0 (key-combination-pair-menu)',
		'_KCT_PairClearAvailability|0'
	],
	[
		'key combinations: shared clear availability assigned=1 (key-combination-pair-menu)',
		'_KCT_PairClearAvailability|1'
	],
	...['separator', 'none', 'holds', 'catalogue', 'taken', 'layer'].map((key) => [
		'key combinations: unset ' +
			key +
			' refuses parse-time AltGr suffix ownership (altgr-suffix-layer-boot)',
		'_KCT_AltGrSuffixUnsetState|' + key
	])
].map(([name, binding]) => name + ' | ' + binding);
if (process.platform !== 'win32') {
	console.log(
		'[NOT_RUN] actual AHK registration ownership requires Windows; bounded source admission checked.'
	);
} else {
	const ahk = path.join(
		process.env.ProgramFiles || 'C:/Program Files',
		'AutoHotkey/v2/AutoHotkey64.exe'
	);
	assert.ok(fs.existsSync(ahk), 'actual AHK receiving requires the installed v2 interpreter');
	// VarUnset is disabled only for uncalled producer definitions whose dependencies are absent.
	// LocalSameAsGlobal remains enabled; this is not the full compiler warning gate.
	const header = `#Requires AutoHotkey v2.0+
#Warn All, StdOut
#Warn VarUnset, Off
global _Rows := []
global _Arguments := []
_KCT_PairClearAvailability(Assigned) {
    global _Arguments
    _Arguments.Push("_KCT_PairClearAvailability|" . Assigned)
}
_KCT_AltGrSuffixUnsetState(Missing) {
    global _Arguments
    _Arguments.Push("_KCT_AltGrSuffixUnsetState|" . Missing)
}
Test(CaseLabel, Callback) {
    global _Rows
    _Rows.Push(CaseLabel)
    Callback.Call()
}
`;
	const footer = `
for ReceiptIndex, ReceiptLabel in _Rows
    FileAppend(ReceiptLabel . " | " . _Arguments[ReceiptIndex] . "\`n", "*")
FileAppend("REGISTRATION_RECEIVED\`n", "*")
ExitApp(0)
`;
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-registration-owner-'));
	const files = [];
	let terminal = true;
	try {
		function invoke(name, text) {
			const file = path.join(directory, name + '.ahk');
			files.push(file);
			fs.writeFileSync(file, '\ufeff' + header + warningSources.join('\n') + text + footer, 'utf8');
			terminal = false;
			const result = spawnSync(ahk, ['/ErrorStdOut', file], {
				encoding: 'utf8',
				windowsHide: true,
				timeout: 20000
			});
			terminal = result.status !== null && result.status !== undefined && !result.error;
			assert.ifError(result.error);
			assert.ok(terminal, 'physical AHK exit is required before fixture retirement');
			assert.equal(result.stderr, '', 'the actual registration fixture must not emit stderr');
			const rows = result.stdout
				.split(/\r?\n/)
				.filter((line) => line.startsWith('key combinations:'));
			assert.deepEqual(
				rows,
				expected,
				'all eight real names, order and Bind arguments must remain exact'
			);
			result.warnings = (result.stdout.match(/^.+ \(\d+\) : ==> Warning:/gm) || []).length;
			return result;
		}
		const actual = invoke('actual', blocks.map((block) => block.text).join('\n'));
		assert.equal(
			actual.status,
			0,
			'the actual registration fixture must complete: ' + actual.stdout
		);
		assert.equal(
			actual.warnings,
			0,
			'registration globals must not shadow actual producer locals: ' + actual.stdout
		);
		assert.match(actual.stdout, /^REGISTRATION_RECEIVED$/m);
		for (const index of [0, 1]) {
			const inverse = invoke(
				'inverse-' + index,
				blocks.map((block, row) => (row === index ? block.old : block.text)).join('\n')
			);
			assert.equal(inverse.status, 0);
			assert.equal(
				inverse.warnings,
				1,
				'withdrawing one owner must expose the actual producer warning'
			);
			assert.match(inverse.stdout, new RegExp('Specifically: ' + owners[index][0] + ' ', 'i'));
		}
		const restored = invoke('restored', blocks.map((block) => block.text).join('\n'));
		assert.equal(restored.status, 0);
		assert.equal(restored.stdout, actual.stdout);
		console.log(
			'AHK actual registration ownership: eight exact tuples; two lexical-owner withdrawals warned and restored.'
		);
	} finally {
		if (terminal) {
			const entries = fs.readdirSync(directory);
			assert.deepEqual(
				entries.sort(),
				files.map((file) => path.basename(file)).sort(),
				'only exact owned fixture files may retire'
			);
			for (const file of files) {
				assert.ok(fs.lstatSync(file).isFile() && !fs.lstatSync(file).isSymbolicLink());
				fs.unlinkSync(file);
			}
			fs.rmdirSync(directory);
		} else {
			console.error('AHK registration fixture retained without terminal ACK: ' + directory);
		}
	}
}
