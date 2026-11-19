// tools/test/test-windows-lua-export-out-parameters.cjs

/**
 * ==============================================================================
 * MODULE: Windows Lua Export Host Out-Parameter Initialization Test
 * DESCRIPTION:
 * The Windows build compiles the Lua export host (static/ergopti_plus/windows/
 * native/ergopti_lua_export.c, also included by ergopti_lua_export_test.c) with
 * MSVC /W4 /WX, where C4701 ("potentially uninitialized local variable") is an
 * error. MSVC does not follow a local through a function that fills it by
 * address when that call sits on one branch only: run_step's input_length,
 * filled by read_input unless the input file failed to open, failed the
 * Windows build although every path that reads it was assigned. gcc, the only
 * compiler of the local proof (build-lua-export-host.cjs), accepts that code,
 * and cl.exe exists only on the Windows runner. So every local whose address is
 * taken in these sources is initialized where it is declared, checked here
 * before any build job runs.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { REPO_ROOT } = require('../lib/paths.cjs');

const NATIVE = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows', 'native');
const SOURCES = ['ergopti_lua_export.c', 'ergopti_lua_export_test.c'];
// Statement keywords a declaration-shaped line can start with.
const KEYWORDS = new Set(['return', 'goto', 'break', 'continue', 'else', 'case', 'do']);
// One local declaration statement at function scope: a type, then declarators.
const DECLARATION =
	/^\t+((?:const\s+|unsigned\s+|struct\s+)*[A-Za-z_]\w*)((?:\s*\*)*\s+[^;(){}"]+);\s*$/;

/** Splits a declarator list on its top-level commas. */
function declarators(list) {
	const parts = [];
	let depth = 0;
	let current = '';
	for (const character of list) {
		if (character === '[' || character === '(') depth++;
		if (character === ']' || character === ')') depth--;
		if (character === ',' && depth === 0) {
			parts.push(current);
			current = '';
		} else current += character;
	}
	parts.push(current);
	return parts.map((part) => part.trim());
}

/** The names a source declares without an initializer, with their line numbers. */
function uninitializedLocals(text) {
	const found = new Map();
	text.split('\n').forEach((line, index) => {
		const match = DECLARATION.exec(line);
		if (!match || KEYWORDS.has(match[1].split(/\s+/)[0])) return;
		for (const declarator of declarators(match[2])) {
			if (declarator.includes('=')) continue;
			const name = /^[\s*]*([A-Za-z_]\w*)/.exec(declarator);
			if (name) found.set(name[1], index + 1);
		}
	});
	return found;
}

/** The names whose address the source takes (&name, not &&). */
function addressTaken(text) {
	const names = new Set();
	for (const match of text.matchAll(/(?<![&\w)\]])&\s*([A-Za-z_]\w*)/g)) names.add(match[1]);
	return names;
}

// The checker itself: the run_step shape that failed the Windows build.
const failing = '\tsize_t input_length;\n\tinput = read_input(stdin, bound, &input_length);\n';
assert(
	addressTaken(failing).has('input_length') && uninitializedLocals(failing).has('input_length'),
	'the checker recognizes an uninitialized out-parameter local'
);
assert.equal(
	uninitializedLocals('\tsize_t input_length = 0;\n\treturn status;\n').size,
	0,
	'the checker accepts an initialized local and ignores a return statement'
);

const offenders = [];
for (const file of SOURCES) {
	const text = fs
		.readFileSync(path.join(NATIVE, file), 'utf8')
		.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, ' '));
	const taken = addressTaken(text);
	for (const [name, line] of uninitializedLocals(text))
		if (taken.has(name)) offenders.push(`${file}:${line} ${name}`);
}
assert.deepEqual(
	offenders,
	[],
	'initialize every local whose address is taken where it is declared (MSVC C4701 under /WX)'
);
console.log(
	`[OK] Windows Lua export host: every out-parameter local is initialized (${SOURCES.join(', ')}).`
);
