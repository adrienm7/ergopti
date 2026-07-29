// tools/test/test-ahk-v2-syntax-antipatterns.cjs

/**
 * ==============================================================================
 * MODULE: AHK v2.0 Parse-Breaker Guard
 * DESCRIPTION:
 * Static gate that scans every windows/ AutoHotkey file (excluding vendor/) for
 * two syntax antipatterns that PARSE-FAIL under `#Requires AutoHotkey v2.0` and
 * therefore abort the ENTIRE test suite at load — silently disabling every AHK
 * test with no failing assertion to point at.
 *
 * Both patterns actually shipped once, undetected, because the suite was never
 * run after a refactor:
 * 1. v1 doubled-quote escaping — three or more consecutive double quotes
 *    (`""""` to render a literal quote). In v2 a literal quote is `` `" ``, so
 *    `""""` is a parse error.
 * 2. block-body fat arrows — `() => { stmt; stmt }`. A v2.1-only construct; under
 *    v2.0 the `{ ... }` after `=>` is parsed as an object literal, which errors
 *    ("Missing propertyname:" / "Error in object literal") on any statement body.
 * 3. an unbraced one-line `try` used as an `if` body, immediately followed by
 *    `else`. AHK v2's `Try` carries its OWN optional `Else` clause, so the `else`
 *    is captured by the `try` instead of the `if` and the parser aborts the whole
 *    script with `Unexpected "Else"`. This one shipped to a user's machine: the
 *    driver refused to start at all, and nothing caught it because ui/ files are
 *    not reachable from run_all.ahk — their only gate was an Ahk2Exe compile
 *    nobody runs. Braces on the if/else bodies are the fix.
 *
 * FEATURES & RATIONALE:
 * - Cross-platform: runs in the JS validation layer (npm run test:js) so a parse
 *   regression is caught in CI even where AutoHotkey is unavailable — long before
 *   the ~4-minute AHK suite would (fail to) run.
 * - Comment-safe: full-line `;` comments are stripped, so a comment that mentions
 *   the antipattern (e.g. documentation of this very rule) does not trip the gate.
 * - Object-literal-safe: the block-arrow check only fires when the brace is
 *   immediately followed by a statement (a call `word(` / member `word.` / an
 *   assignment `word :=`), never a `key:` object-literal entry.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WIN_DIR = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

// Recursively collect .ahk files, skipping vendored third-party libraries whose
// (possibly v2.1) syntax we neither own nor police.
function collectAhkFiles(dir, out) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name === 'vendor') continue;
			collectAhkFiles(full, out);
		} else if (entry.isFile() && entry.name.endsWith('.ahk')) {
			out.push(full);
		}
	}
}

const files = [];
collectAhkFiles(WIN_DIR, files);

const errors = [];

// A `=> {` (possibly across a newline) whose first token inside the brace is a
// statement — a function call, a member access, or a `:=` assignment. Object
// literals (`=> { key: value }`) start with `word:` and are intentionally NOT
// matched.
const BLOCK_ARROW = /=>\s*\{\s*(\w+\s*[(.]|\w+\s*:=)/g;

for (const file of files) {
	const rel = path.relative(ROOT, file).replace(/\\/g, '/');
	const src = fs.readFileSync(file, 'utf8');
	// Blank out full-line comments while preserving line numbering.
	const codeLines = src.split(/\r?\n/).map((l) => (l.trim().startsWith(';') ? '' : l));

	codeLines.forEach((line, i) => {
		if (/"{3,}/.test(line)) {
			errors.push(
				`${rel}:${i + 1}: three or more consecutive double-quotes — AHK v1 quote escaping; ` +
					'in v2 a literal quote is `" (backtick-quote).'
			);
		}
	});

	// An unbraced `try <statement>` whose next code line is a BARE `else`. A
	// `} else` is safe — the brace closes the if-body block, so the else binds to
	// the `if` as intended; only the brace-less form is ambiguous.
	codeLines.forEach((line, i) => {
		const stripped = line.replace(/\s+;.*$/, '').trim();
		if (!/^try\s+\S/i.test(stripped)) return;
		if (/^try\s*\{/i.test(stripped)) return;
		// Find the next line that carries code.
		let j = i + 1;
		while (j < codeLines.length && codeLines[j].trim() === '') j++;
		if (j >= codeLines.length) return;
		const next = codeLines[j].replace(/\s+;.*$/, '').trim();
		if (/^else\b/i.test(next)) {
			errors.push(
				`${rel}:${i + 1}: unbraced one-line \`try\` as an if-body followed by \`else\` on ` +
					`line ${j + 1} — AHK v2's \`try\` has its own \`else\` clause, so this aborts the ` +
					'whole script with `Unexpected "Else"`. Brace the if/else bodies.'
			);
		}
	});

	const joined = codeLines.join('\n');
	let m;
	while ((m = BLOCK_ARROW.exec(joined)) !== null) {
		const lineNo = joined.slice(0, m.index).split('\n').length;
		errors.push(
			`${rel}:${lineNo}: block-body fat arrow (=> { statement… }) — v2.1-only; under ` +
				'#Requires v2.0 it parses as an object literal. Use a named function.'
		);
	}
}

if (errors.length > 0) {
	console.error('AHK v2.0 parse-breaking antipatterns found (these abort the whole suite at load):');
	for (const e of errors) console.error('  ' + e);
	console.error(`\n${errors.length} issue(s) — exactly the class of parse error that silently disables the AHK suite.`);
	process.exit(1);
}

console.log(`OK — no AHK v2.0 parse-breaking antipatterns in ${files.length} windows/ file(s).`);
process.exit(0);
