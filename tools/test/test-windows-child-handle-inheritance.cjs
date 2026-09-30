// tools/test/test-windows-child-handle-inheritance.cjs

/**
 * ==============================================================================
 * MODULE: Windows Child Handle Inheritance Gate
 * DESCRIPTION:
 * The Windows driver launches its children with inherited standard streams,
 * which only the AHK suite can execute, on Windows CI. This gate checks from
 * the sources, anywhere, what keeps a task's capture file private to its own
 * process tree (shell-capture-lock):
 *
 * 1. Every CreateProcessW that inherits handles is inventoried: the shell
 *    runner's launch names its two streams in a PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
 *    and any other inheriting launch is an audited entry of INHERITING_LAUNCHES.
 * 2. The shell runner opens, passes and closes those inheritable streams inside
 *    one Critical window, so no other driver thread can launch in between.
 * 3. The AHK regression test is registered in run_all.ahk.
 *
 * ROOT CAUSE ENCODED:
 * CreateProcessW with bInheritHandles and no handle list copies every
 * inheritable handle of the driver into the child. A timer or callback thread
 * that started another task while a task's capture handle was open (the launch
 * ran outside Critical) gave that capture to an unrelated, possibly
 * session-long child. Once the task's own tree had exited, that copy, opened
 * without FILE_SHARE_DELETE, made DeleteFileW fail with ERROR_SHARING_VIOLATION
 * (the error window on opening the versions window).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WIN = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

// Inheriting launches that pass no handle list, each with why no task capture
// can reach it: the shell runner keeps its inheritable streams inside Critical,
// so no AHK thread, these included, can create a process while one is open.
const INHERITING_LAUNCHES = {
	'modules/updater/self_update.ahk':
		'the swap PowerShell inherits the driver process handle it waits on, at exit',
	'infra/uninstall.ahk':
		'the uninstaller PowerShell inherits the driver process handle it waits on, at exit'
};

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const read = (rel) => fs.readFileSync(path.join(WIN, rel), 'utf8').replace(/^﻿/, '');

/**
 * Removes full-line and trailing AHK comments, keeping line positions.
 * @param {string} source AHK source text.
 * @returns {string} Source without comments.
 */
const stripComments = (source) =>
	source
		.split('\n')
		.map((line) => (/^\s*;/.test(line) ? '' : line.replace(/\s+;.*$/, '')))
		.join('\n');

/**
 * Returns the body of an AHK function declared at column 0, its signature
 * possibly continued on the following lines.
 * @param {string} source AHK source text.
 * @param {string} name Function name.
 * @returns {string} Body text, "" when absent.
 */
const bodyOf = (source, name) => {
	const start = source.search(new RegExp(`^${name}\\(`, 'm'));
	if (start < 0) return '';
	const open = source.slice(start).search(/\)\s*\{[ \t]*$/m);
	if (open < 0) return '';
	const end = source.indexOf('\n}', start + open);
	return end < 0 ? '' : source.slice(start, end);
};

/**
 * Lists the production .ahk files of the Windows driver, relative to it.
 * @returns {string[]} Relative paths with forward slashes.
 */
const productionFiles = () => {
	const found = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			const rel = path.relative(WIN, full).replace(/\\/g, '/');
			if (entry.isDirectory()) {
				if (!/^(tests|vendor|_generated)$/.test(rel)) walk(full);
			} else if (entry.name.endsWith('.ahk')) {
				found.push(rel);
			}
		}
	};
	walk(WIN);
	return found;
};

/**
 * Splits the argument text of a call at its top-level commas.
 * @param {string} text Source starting right after the opening parenthesis.
 * @returns {string[]} Trimmed arguments up to the matching parenthesis.
 */
const callArguments = (text) => {
	const args = [];
	let depth = 0;
	let quote = '';
	let current = '';
	for (const ch of text) {
		if (quote) {
			current += ch;
			if (ch === quote) quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") quote = ch;
		else if (ch === '(' || ch === '[') depth += 1;
		else if (ch === ')' || ch === ']') {
			if (depth === 0) break;
			depth -= 1;
		} else if (ch === ',' && depth === 0) {
			args.push(current.trim());
			current = '';
			continue;
		}
		current += ch;
	}
	args.push(current.trim());
	return args;
};

// 1. The inheriting-launch inventory.
const inheritingCreators = [];
const plcCallers = new Set();
for (const rel of productionFiles()) {
	const source = stripComments(read(rel));
	for (const match of source.matchAll(/DllCall\(\s*"Kernel32\\CreateProcessW"/g)) {
		const args = callArguments(source.slice(match.index + 'DllCall('.length));
		// Name, then type/value pairs: bInheritHandles is the fifth parameter.
		const inherit = (args[10] || '').toLowerCase();
		check(
			['true', 'false', '0', '1'].includes(inherit),
			`${rel}: CreateProcessW must pass a literal bInheritHandles, found "${args[10]}"`
		);
		if (inherit === 'true' || inherit === '1') inheritingCreators.push(rel);
	}
	const withoutDefinition = source.replace(/^PLC_CreateProcessWithInheritedHandles\(/m, '');
	if (/\bPLC_CreateProcessWithInheritedHandles\b/.test(withoutDefinition)) plcCallers.add(rel);
}
check(
	inheritingCreators.length === 1 && inheritingCreators[0] === 'adapters/process_lifecycle.ahk',
	`only PLC_CreateProcessWithInheritedHandles may create a process with inherited handles, found: ${inheritingCreators.join(', ')}`
);
const expectedCallers = ['adapters/shell_runner.ahk', ...Object.keys(INHERITING_LAUNCHES)].sort();
check(
	JSON.stringify([...plcCallers].sort()) === JSON.stringify(expectedCallers),
	`inheriting launches changed: found ${[...plcCallers].sort().join(', ')}; a new one passes an ` +
		'explicit handle list like the shell runner, or is audited in INHERITING_LAUNCHES'
);

// 2. The shell runner's launch window.
const runner = stripComments(read('adapters/shell_runner.ahk'));
const constant = (name) => {
	const match = runner.match(new RegExp(`^global ${name} := (.+)$`, 'm'));
	return match ? match[1].trim() : '';
};
check(
	constant('SR_EXTENDED_STARTUPINFO_PRESENT') === '0x00080000',
	'EXTENDED_STARTUPINFO_PRESENT is 0x00080000'
);
check(
	constant('SR_PROC_THREAD_ATTRIBUTE_HANDLE_LIST') === '0x00020002',
	'PROC_THREAD_ATTRIBUTE_HANDLE_LIST is 0x00020002'
);
check(
	constant('SR_STARTUPINFO_BYTES') === '(A_PtrSize = 8) ? 104 : 68',
	'STARTUPINFOW is 104 bytes on x64 and 68 on x86; the attribute-list pointer follows it'
);
const create = bodyOf(runner, '_SR_TreeCreateSuspended');
check(create !== '', 'adapters/shell_runner.ahk must define _SR_TreeCreateSuspended');
const at = (needle, from = 0) => create.indexOf(needle, from);
const criticalOn = at('Critical("On")');
const firstStream = at('CreateFileW');
const list = at('_SR_NewInheritedHandleList([input_handle, output_handle])');
const pointer = at('NumPut("Ptr", handle_list["List"].Ptr, startup_info, SR_STARTUPINFO_BYTES)');
const creation = at('CreateFn.Call(');
const outputClosed = at('CloseStreamFn.Call(output_handle)');
const windowEnd = at('finally', outputClosed);
const leftoverClose = at('DllCall("Kernel32\\CloseHandle", "Ptr", stream_handle', windowEnd);
const listDeleted = at('_SR_DeleteInheritedHandleList(handle_list)', windowEnd);
const criticalRestored = at('Critical(previous_critical)', windowEnd);
check(
	criticalOn > 0 &&
		firstStream > criticalOn &&
		list > firstStream &&
		at('CreateFileW', firstStream + 1) < list &&
		pointer > list &&
		creation > pointer &&
		outputClosed > creation &&
		windowEnd > outputClosed &&
		leftoverClose > windowEnd &&
		listDeleted > windowEnd &&
		criticalRestored > leftoverClose &&
		criticalRestored > listDeleted,
	'_SR_TreeCreateSuspended must open both streams, list them, create the child and close them inside ' +
		'one Critical window, closing any refused stream before Critical is restored'
);
check(
	/creation_flags := SR_TREE_CREATE_SUSPENDED \| SR_TREE_CREATE_NO_WINDOW\s*\|\s*SR_EXTENDED_STARTUPINFO_PRESENT/.test(
		create
	) && create.includes('Buffer(SR_STARTUPINFO_BYTES + A_PtrSize, 0)'),
	'the launch must pass a STARTUPINFOEXW flagged EXTENDED_STARTUPINFO_PRESENT'
);
const handleList = bodyOf(runner, '_SR_NewInheritedHandleList');
check(
	/UpdateProcThreadAttribute"[\s\S]*SR_PROC_THREAD_ATTRIBUTE_HANDLE_LIST/.test(handleList) &&
		handleList.includes('InitializeProcThreadAttributeList') &&
		handleList.includes('DeleteProcThreadAttributeList'),
	'_SR_NewInheritedHandleList must build a PROC_THREAD_ATTRIBUTE_HANDLE_LIST and release it on failure'
);
check(
	bodyOf(runner, '_SR_DeleteInheritedHandleList').includes('DeleteProcThreadAttributeList'),
	'_SR_DeleteInheritedHandleList must release the attribute list'
);

// 3. The behavioural regression runs in the AHK suite.
const testFile = 'tests/unit/test_shell_runner_capture_lock.ahk';
check(
	/^#Include unit\/test_shell_runner_capture_lock\.ahk\s*$/m.test(read('tests/run_all.ahk')),
	`tests/run_all.ahk must include ${testFile}`
);
check(
	fs.existsSync(path.join(WIN, testFile)) && read(testFile).includes('(shell-capture-lock)'),
	`${testFile} must carry the shell-capture-lock slug`
);

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] Windows child handle inheritance: ${checks} check(s) passed.\x1b[0m`);
