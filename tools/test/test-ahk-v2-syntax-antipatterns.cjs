// tools/test/test-ahk-v2-syntax-antipatterns.cjs

/**
 * ==============================================================================
 * MODULE: AHK v2.0 Parse-Breaker Guard
 * DESCRIPTION:
 * Static gate that scans every windows/ AutoHotkey file (excluding vendor/) for
 * syntax antipatterns that PARSE-FAIL under `#Requires AutoHotkey v2.0` and
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
 * 4. JavaScript's strict-equality operator (`===`). AHK v2's case-sensitive
 *    equality operator is `==`; `===` aborts parsing with `Missing operand`.
 * 5. an unbalanced bracket: one `)` too many in a test's nested call
 *    (`Unexpected ")"`) stopped the whole suite from loading.
 * 6. a line that starts with `(` and has no `)` opens a continuation section,
 *    whose remainder AHK reads as section options. A multi-line condition
 *    split that way inside an InputBox call (`Invalid option`) stopped every
 *    script from loading. Both shipped in one push because AutoHotkey was not
 *    available where the code was written; the checks self-test on those exact
 *    lines before scanning.
 * 7. a reserved word used as a parameter, an assignment target or a for-loop
 *    variable (`for Case in Cases`), which AHK rejects at load with a modal
 *    dialog. The loop form was written again in a test on 2026-09-30, and the
 *    gate then checked only the first two positions.
 *
 * 8. a captured catch variable followed by a statement on the SAME line
 *    (`catch as Err Failure := Err.Message`). AHK treats the trailing text as
 *    a class declaration and aborts every included test with `Invalid class`.
 *    Put the statement on its own line or inside braces.
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

// AHK strings may legitimately embed JavaScript containing `===`, so this
// scanner removes both quote styles and an inline comment before checking the
// remaining AHK code. Backtick escapes consume the following source character.
function stripAhkStringsAndComment(line) {
	let out = '';
	let quote = '';
	for (let i = 0; i < line.length; i += 1) {
		const char = line[i];
		if (quote) {
			if (char === '`') {
				out += ' ';
				if (i + 1 < line.length) {
					i += 1;
					out += ' ';
				}
				continue;
			}
			if (char === quote) quote = '';
			out += ' ';
			continue;
		}
		if (char === '"' || char === "'") {
			quote = char;
			out += ' ';
			continue;
		}
		if (char === ';') break;
		out += char;
	}
	return out;
}

/**
 * Finds the native parse breaker where a captured catch also carries a statement.
 * @param {string} line One source line; quoted text and comments are not code.
 * @returns {boolean} Whether AHK rejects the same-line captured catch at load.
 */
function inlineCapturedCatch(line) {
	const code = stripAhkStringsAndComment(line);
	return /^\s*(?:}\s*)?catch\s+(?:[\w.]+\s*(?:,\s*[\w.]+\s*)*)?as\s+\w+\s+(?!\{)\S/i.test(code);
}

// The first vector is the exact line which stopped native run_all before any
// selected personal-menu case. Legal catch bodies and literal text stay valid.
for (const [line, rejected] of [
	['\t\t\t\tcatch as Err Failure := Err.Message', true],
	['} catch TypeError as Err Failure := Err.Message', true],
	['catch ValueError, TypeError as Err Failure := Err.Message', true],
	['catch as Err', false],
	['\tFailure := Err.Message', false],
	['catch as Err {', false],
	['catch as Err { Failure := Err.Message }', false],
	['} catch TypeError as Err {', false],
	['catch ValueError, TypeError as Err', false],
	['; catch as Err Failure := Err.Message', false],
	['catch as Err ; Failure := Err.Message', false],
	['Message := "catch as Err Failure := Err.Message"', false],
	["Message := 'catch as Err Failure := Err.Message'", false]
]) {
	if (inlineCapturedCatch(line) !== rejected) {
		console.error('The captured-catch guard misclassified a native syntax control: ' + line);
		process.exit(1);
	}
}

// Words AHK v2 refuses as identifiers. The list is deliberately the control-flow
// keywords rather than every reserved name: those are the ones that read as
// perfectly ordinary variable names ("Case", "Loop", "Until", "Catch") and so are
// the ones actually reached for. "Case" cost a full debugging session — a test
// file using it as a loop variable blocked the entire suite at load, silently.
const RESERVED_LOWER = new Set(
	[
		'Case',
		'Loop',
		'Until',
		'Catch',
		'Finally',
		'Switch',
		'Break',
		'Continue',
		'Return',
		'Throw',
		'Goto',
		'Global',
		'Static',
		'Local'
	].map((w) => w.toLowerCase())
);

// Options a genuine continuation section may carry after its opening "(".
const SECTION_OPTION = /^(Join.*|LTrim0?|RTrim0|Comments?|Com|C|%|,|`)$/i;

/**
 * Reports whether a line opens a continuation section and whether its options
 * are ones AHK accepts.
 * @param {string} line Source line with comments already blanked.
 * @returns {null|{valid: boolean}} null when the line opens no section.
 */
function sectionOpening(line) {
	const trimmed = line.trim();
	// Another bracket on the line makes it an expression, e.g. `(_Sib => Test(`.
	if (!trimmed.startsWith('(') || /[()]/.test(trimmed.slice(1))) return null;
	const options = trimmed.slice(1).trim().split(/\s+/).filter(Boolean);
	return { valid: options.every((option) => SECTION_OPTION.test(option)) };
}

/**
 * Finds bracket and continuation-section errors in comment-blanked code lines.
 * @param {string[]} codeLines Lines with comments blanked, numbering preserved.
 * @returns {{line: number, message: string}[]}
 */
function bracketErrors(codeLines) {
	const found = [];
	let depth = 0;
	let inSection = false;
	codeLines.forEach((line, i) => {
		if (inSection) {
			if (line.trim().startsWith(')')) inSection = false;
			return;
		}
		const opening = sectionOpening(line);
		if (opening) {
			if (!opening.valid) {
				found.push({
					line: i + 1,
					message:
						'a line starting with "(" and no ")" opens a ' +
						'continuation section, and its text is not section options (`Invalid option` at load). ' +
						'Keep the "(" on the previous line or compute the value first.'
				});
			} else {
				inSection = true;
			}
			return;
		}
		for (const char of stripAhkStringsAndComment(line)) {
			if (char === '(' || char === '[') depth += 1;
			else if (char === ')' || char === ']') {
				depth -= 1;
				if (depth < 0) {
					found.push({
						line: i + 1,
						message: 'a closing bracket with no opening one ' + '(`Unexpected ")"` at load).'
					});
					depth = 0;
				}
			}
		}
	});
	if (depth !== 0)
		found.push({ line: codeLines.length, message: `${depth} bracket(s) never closed.` });
	return found;
}

/**
 * The reserved words a line binds as for-loop variables (`for Key, Value in`).
 * @param {string} line Source line with comments and strings already blanked.
 * @returns {string[]} The offending names.
 */
function reservedLoopVariables(line) {
	const loop = line.match(/^\s*for\s+(\w+)(?:\s*,\s*(\w+))?\s+in\b/i);
	if (!loop) return [];
	return [loop[1], loop[2]].filter((name) => name && RESERVED_LOWER.has(name.toLowerCase()));
}

if (reservedLoopVariables('\t\t\tfor Case in [').join() !== 'Case') {
	console.error('The reserved-word check no longer detects a for-loop variable named Case.');
	process.exit(1);
}

// The two lines that shipped: the gate must see both before it may pass a tree.
const SELF_TEST = [
	['\t\tExpected := JsonParse(Build("openai", Map(', '\t\t\t"image", "QUJD", "max_tokens", 1))))'],
	[
		'\t\tResult := InputBox(Prompt, Title,',
		'\t\t\t(Spec = "wrap_pair" || Spec = "llm_prompt"',
		'\t\t\t\t|| Spec = "llm_vision") ? "w680 h300" : "w680 h160", Existing)'
	]
];
for (const sample of SELF_TEST) {
	if (bracketErrors(sample).length === 0) {
		console.error(
			'The bracket check no longer detects a line that aborted the AHK suite:\n' + sample.join('\n')
		);
		process.exit(1);
	}
}

for (const file of files) {
	const rel = path.relative(ROOT, file).replace(/\\/g, '/');
	const src = fs.readFileSync(file, 'utf8');
	// Blank out full-line and documentation-block comments while preserving line
	// numbering. Project block comments use AHK's line-leading /* ... */ form.
	let inBlockComment = false;
	const codeLines = src.split(/\r?\n/).map((line) => {
		const trimmed = line.trim();
		if (inBlockComment) {
			if (trimmed.includes('*/')) inBlockComment = false;
			return '';
		}
		if (trimmed.startsWith('/*')) {
			if (!trimmed.includes('*/')) inBlockComment = true;
			return '';
		}
		return trimmed.startsWith(';') ? '' : line;
	});

	codeLines.forEach((line, i) => {
		if (/"{3,}/.test(line)) {
			errors.push(
				`${rel}:${i + 1}: three or more consecutive double-quotes — AHK v1 quote escaping; ` +
					'in v2 a literal quote is `" (backtick-quote).'
			);
		}
		if (inlineCapturedCatch(line)) {
			errors.push(
				`${rel}:${i + 1}: a captured catch variable is followed by a statement on the same line — ` +
					'AHK v2 aborts parsing with `Invalid class`. Move the statement to its own line or use braces.'
			);
		}
		const executable = stripAhkStringsAndComment(line);
		if (/(?<!!)===(?!=)/.test(executable)) {
			errors.push(
				`${rel}:${i + 1}: JavaScript-style strict equality (===) — AHK v2 uses == ` +
					'for case-sensitive equality; === aborts parsing with `Missing operand`.'
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

	// A reserved word used as a variable, parameter or loop variable. AHK v2
	// rejects it at LOAD time — which means a modal error dialog, which in a
	// headless run is a process that blocks forever at ~0% CPU with no output at
	// all. That is far worse than a failing test: the suite does not fail, it
	// stops existing, and the run looks like a slow machine.
	codeLines.forEach((line, i) => {
		// String literals are blanked first: half this repo's test names contain
		// the word "case", and matching inside them would report 20 findings on a
		// tree that loads perfectly — a gate nobody could act on.
		const stripped = line.replace(/\s+;.*$/, '').replace(/"(?:[^"`]|`.)*"/g, '""');

		// A function's PARAMETER list is the position AHK actually rejects.
		const decl = stripped.match(/^\s*(\w+)\s*\(([^)]*)\)\s*\{?\s*$/);
		if (decl) {
			for (const param of decl[2].split(',')) {
				const name = param
					.trim()
					.replace(/^&/, '')
					.split(/[\s:=*]/)[0];
				if (RESERVED_LOWER.has(name.toLowerCase())) {
					errors.push(
						`${rel}:${i + 1}: "${name}" is an AHK v2 reserved word used as a parameter of ` +
							`${decl[1]}() — this fails at LOAD time with a modal dialog, so a headless run ` +
							'blocks forever at ~0% CPU with no output instead of reporting a failure. ' +
							'Rename the parameter.'
					);
				}
			}
		}

		for (const name of reservedLoopVariables(stripped)) {
			errors.push(
				`${rel}:${i + 1}: "${name}" is an AHK v2 reserved word used as a for-loop ` +
					'variable — this fails at LOAD time with a modal dialog. Rename the variable.'
			);
		}

		// And as an assignment target, which AHK rejects the same way.
		const assign = stripped.match(/(?:^|[\s(,])(\w+)\s*:=/);
		if (assign && RESERVED_LOWER.has(assign[1].toLowerCase())) {
			errors.push(
				`${rel}:${i + 1}: "${assign[1]}" is an AHK v2 reserved word used as an assignment ` +
					'target — this fails at LOAD time with a modal dialog. Rename the variable.'
			);
		}
	});

	for (const problem of bracketErrors(codeLines))
		errors.push(`${rel}:${problem.line}: ${problem.message}`);

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
	console.error(
		'AHK v2.0 parse-breaking antipatterns found (these abort the whole suite at load):'
	);
	for (const e of errors) console.error('  ' + e);
	console.error(
		`\n${errors.length} issue(s) — exactly the class of parse error that silently disables the AHK suite.`
	);
	process.exit(1);
}

console.log(`OK — no AHK v2.0 parse-breaking antipatterns in ${files.length} windows/ file(s).`);
process.exit(0);
