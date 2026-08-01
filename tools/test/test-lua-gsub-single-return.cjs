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

// `return <something>:gsub( … )` on one line, with balanced parentheses, and not
// already wrapped.
const BARE = /^\s*return\s+(?!\()(.+:gsub\(.*\))\s*$/;
const WRAPPED = /^\s*return\s+\(.*:gsub\(/;

for (const abs of walk(SP)) {
	scanned++;
	const rel = path.relative(SP, abs).split(path.sep).join('/');
	const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);
	lines.forEach((line, i) => {
		const trimmed = line.trim();
		if (trimmed.startsWith('--')) return;
		if (WRAPPED.test(line)) {
			parenthesised++;
			return;
		}
		const m = BARE.exec(line);
		if (!m) return;
		const expr = m[1];
		// Unbalanced means the statement continues on the next line; those are
		// out of scope rather than silently mis-reported.
		if ((expr.match(/\(/g) || []).length !== (expr.match(/\)/g) || []).length) return;
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
	`\x1b[32m[OK] every single-line gsub return is parenthesised (${parenthesised} site(s), ` +
		`${scanned} Lua file(s) scanned).\x1b[0m`
);
