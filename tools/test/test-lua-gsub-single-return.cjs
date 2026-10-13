// tools/test/test-lua-gsub-single-return.cjs

/**
 * ==============================================================================
 * MODULE: Lua gsub Single-Return Guard
 * DESCRIPTION:
 * `return x:gsub(...)` returns TWO values — the string and gsub's replacement
 * COUNT. A function meant to return one string quietly returns two, and the
 * second one leaks wherever Lua expands a multi-value expression.
 *
 * WHAT THE INTERPRETER ACTUALLY DOES (measured, not assumed):
 *   string.format(fmt, x:gsub(..), y)  → truncated to one value.  Safe.
 *   string.format(fmt, y, x:gsub(..))  → expands; format ignores extras. Safe.
 *   { first, x:gsub(..) }              → expands: #t is 3, not 2.  LEAKS.
 *   return x:gsub(..)                  → the caller receives two values. LEAKS.
 *
 * That asymmetry is why this is worth a gate rather than a code review note: the
 * two shapes that look most dangerous are fine, and the innocuous-looking bare
 * `return` is the one that propagates. A caller writing `local s = f()` never
 * notices; a caller writing `{ f() }` or `t[#t + 1] = f()` in the wrong context
 * gets a stray integer with no error.
 *
 * ROOT CAUSE ENCODED:
 * The codebase already knew: 16 sites used the correct `return (x:gsub(...))`
 * while 20 did not. A convention applied to 44 % of its sites is not a
 * convention, and the difference is invisible in review because the parentheses
 * look decorative.
 *
 * SCOPE: production Lua across all drivers and _shared. Multi-line returns are
 * not matched — this checks the single-line form the fix applied to.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const { scriptTokens, stripComments } = require('../lib/script-source.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

const errors = [];
let scanned = 0;
let parenthesised = 0;

function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'tests' && e.name !== '_generated' && e.name !== 'vendor') walk(p, acc);
		} else if (e.name.endsWith('.lua')) {
			acc.push(p);
		}
	}
	return acc;
}

/** Classifies the final return expression, retaining literal and grouping boundaries. */
function gsubReturnKind(line) {
	const tokens = scriptTokens(line, '.lua');
	if (tokens[0]?.kind !== 'identifier' || tokens[0].value !== 'return') return 'none';
	const expression = tokens.slice(1);
	if (expression.at(-1)?.value === ';') expression.pop();
	const stack = [],
		depth = [],
		closes = new Map();
	let start = 0;
	for (let at = 0; at < expression.length; at++) {
		const token = expression[at];
		depth[at] = stack.length;
		if (token.kind !== 'symbol') continue;
		if (['(', '[', '{'].includes(token.value)) stack.push(at);
		else if ([')', ']', '}'].includes(token.value)) {
			const opening = stack.pop();
			if (
				opening === undefined ||
				'([{'.indexOf(expression[opening].value) !== ')]}'.indexOf(token.value)
			)
				return 'continued';
			closes.set(opening, at);
		} else if (token.value === ',' && stack.length === 0) start = at + 1;
	}
	if (stack.length) return 'continued';
	const last = expression.length - 1;
	// An outer group adjusts to one value. A grouped receiver followed by a
	// method call does not: `(source):gsub(...)` still returns two values.
	if (expression[start]?.value === '(' && closes.get(start) === last) {
		return expression.some((t, at) => t.value === 'gsub' && expression[at - 1]?.value === ':')
			? 'wrapped'
			: 'none';
	}
	for (let at = start; at < expression.length; at++) {
		if (
			depth[at] !== 0 ||
			expression[at].value !== ':' ||
			expression[at + 1]?.value !== 'gsub' ||
			expression[at + 2]?.value !== '(' ||
			closes.get(at + 2) !== last
		)
			continue;
		for (let before = start; before < at; before++) {
			const token = expression[before];
			if (depth[before] !== 0 || token.kind === 'string') continue;
			if (
				['and', 'or', 'not'].includes(token.value) ||
				['+', '-', '*', '/', '%', '^', '#', '<', '>', '=', '~', '&', '|'].includes(token.value) ||
				(token.value === '.' && expression[before + 1]?.value === '.')
			)
				return 'adjusted';
		}
		return 'bare';
	}
	return 'none';
}

// Independent classification controls include the actual concatenation shape
// and grouping that the former regex mistook for a protected complete return.
const controls = [
	['return source:gsub("x", "y")', 'bare'],
	['return (source):gsub("x", "y")', 'bare'],
	['return (source:gsub("x", "y")):gsub("y", "z")', 'bare'],
	['return source:gsub("x", "y") -- owned comment', 'bare'],
	['return first, source:gsub("x", "y")', 'bare'],
	['return (source:gsub("x", "y"))', 'wrapped'],
	['return scheme .. ":" .. tostring(number) .. (path:gsub("/+$", ""))', 'none'],
	['return scheme .. ":" .. tostring(number) .. path:gsub("/+$", "")', 'adjusted'],
	['return ready and source:gsub("x", "y")', 'adjusted'],
	['return not source:gsub("x", "y")', 'adjusted'],
	['return source:gsub("x", "y"), second', 'none'],
	['return "source:gsub(x, y)"', 'none'],
	['-- return source:gsub("x", "y")', 'none'],
	['return source:gsub(', 'continued']
];
for (const [line, expected] of controls) assert.equal(gsubReturnKind(line), expected, line);

for (const abs of walk(SP)) {
	scanned++;
	const rel = path.relative(SP, abs).split(path.sep).join('/');
	const lines = stripComments(fs.readFileSync(abs, 'utf8'), '.lua').split(/\r?\n/);
	lines.forEach((line, i) => {
		const kind = gsubReturnKind(line);
		if (kind === 'wrapped') {
			parenthesised++;
			return;
		}
		if (kind !== 'bare') return;
		errors.push(
			`${rel}:${i + 1}: bare \`return x:gsub(...)\` returns TWO values — the string and gsub's ` +
				'replacement count. Wrap it: `return (x:gsub(...))`. The extra value is invisible to a ' +
				'caller doing `local s = f()` and leaks in a table constructor or a varargs call.'
		);
	});
}

if (scanned < 200) {
	errors.push(`scanned only ${scanned} Lua file(s) — the walk is broken`);
}
if (parenthesised < 10) {
	errors.push(
		`found only ${parenthesised} correctly-parenthesised return(s) — the pattern that recognises ` +
			'them is probably wrong, which would make this gate pass by seeing nothing'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] gsub returning two values:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] no bare final gsub return expands (${parenthesised} grouped site(s), ` +
		`${scanned} Lua file(s) scanned).\x1b[0m`
);
