// tools/test/test-ahk-loop-capture.cjs

/**
 * ==============================================================================
 * MODULE: AHK Loop-Capture Guard
 * DESCRIPTION:
 * Rejects the two closure shapes inside a `for` loop that make an AutoHotkey
 * test assert nothing: a closure that reads a variable of the loop itself, and
 * a test registration whose callable closes over the loop.
 *
 * ROOT CAUSE ENCODED:
 * 1. A closure never sees a `for` variable. AutoHotkey 2.0 binds a captured
 *    local to a shared cell when the function starts; `for` then backs the
 *    variable up, which resets it to an unset plain variable, and points it at
 *    a fresh reference for the enumerator (Line::PerformLoopFor calling
 *    Var::Backup then Var::GetRef, source v2.0.26). The loop and the closure
 *    no longer share anything: the closure reads the value from before the
 *    loop, usually unset, even when it runs inside the same iteration. Inside
 *    AssertThrows that read throws an UnsetError, which satisfies the
 *    assertion whatever the product does. Two CI failures of September 2026
 *    (the system-actions confirm gate) came from it, and seven assertion
 *    closures in five test files had been passing on that UnsetError. A local
 *    the body assigns is not affected: only the loop's own variables are
 *    backed up. The fix is a helper called once per item whose closure reads
 *    a parameter, or `.Bind(item)`.
 * 2. A registration outlives its iteration. Copying the loop variable into
 *    another local first (`VecCopy := Vec`) looks like a snapshot and is not:
 *    that local is one slot of the enclosing function, every registered
 *    closure shares it, and they all run after the loop and read the final
 *    value. Measured 2026-07-31 on three corpus consumers: dropping a
 *    keystroke from the first vector of a 13-vector corpus produced 13 green
 *    tests. `.Bind(Vec)` evaluates its arguments at registration and stores
 *    them per callable.
 *
 * FEATURES & RATIONALE:
 * 1. Flags the shape, not a spelling: fat arrows (one line or continued) and
 *    nested functions, at any depth of nested loops, with their own
 *    parameters, member names, object-literal keys, strings and comments set
 *    aside so a mention is not a read.
 * 2. Scans the whole Windows driver, tests and production, because the
 *    language rule does not depend on who wrote the loop.
 * 3. Self-tests on the shipped shapes and on the helper pattern before it may
 *    pass a tree, so a detector that stops matching fails instead of passing.
 * 4. A baseline of zero that only turns down.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

// Occurrences that are known-good today. NEVER raise this to admit a new one:
// the fix is always a per-item helper or .Bind, both a few lines.
const BASELINE = 0;

// Control-flow words that precede a parenthesis without naming a function,
// lower-cased because AutoHotkey keywords are case-insensitive.
const KEYWORDS = new Set([
	'if',
	'else',
	'while',
	'for',
	'loop',
	'until',
	'switch',
	'case',
	'catch',
	'finally',
	'try',
	'return',
	'throw',
	'not',
	'and',
	'or',
	'is',
	'in',
	'contains',
	'global',
	'local',
	'static'
]);

const IDENTIFIER = /^[\p{L}_][\p{L}\p{N}_]*$/u;
const IDENT_GLOBAL = /(?<![\p{L}\p{N}_])[\p{L}_][\p{L}\p{N}_]*/gu;

/**
 * Reports whether a text is exactly one AutoHotkey identifier.
 * @param {string} name Candidate name.
 * @returns {boolean} True for a bare identifier.
 */
function isIdentifier(name) {
	return IDENTIFIER.test(name);
}

/**
 * Splits the variable list of a `for` header into its named variables; an
 * omitted position (`for , Value in`) names nothing.
 * @param {string} list Text between `for` and `in`.
 * @returns {string[]} Variable names.
 */
function loopVariables(list) {
	return list
		.split(',')
		.map((name) => name.trim())
		.filter(isIdentifier);
}

// ======================================
// ======================================
// ======= 1/ Reading AutoHotkey code ===
// ======================================
// ======================================

/**
 * Blanks comments, string contents and continuation sections while keeping
 * every line and column, so positions found in the result point at the source.
 * @param {string} src File content.
 * @returns {string[]} One code line per source line.
 */
function codeLines(src) {
	const raw = src.replace(/^\uFEFF/, '').split(/\r?\n/);
	const out = [];
	let inBlockComment = false;
	let sectionQuote = '';
	for (let i = 0; i < raw.length; i += 1) {
		const line = raw[i];
		const trimmed = line.trim();
		if (inBlockComment) {
			if (trimmed.includes('*/')) inBlockComment = false;
			out.push('');
			continue;
		}
		let quote = '';
		let start = 0;
		let text = '';
		if (sectionQuote) {
			if (!trimmed.startsWith(')')) {
				out.push('');
				continue;
			}
			// The section closes on this line; the string it belongs to is still open.
			start = line.indexOf(')') + 1;
			text = ' '.repeat(start);
			quote = sectionQuote;
			sectionQuote = '';
		} else if (trimmed.startsWith('/*')) {
			inBlockComment = !trimmed.includes('*/');
			out.push('');
			continue;
		}
		for (let c = start; c < line.length; c += 1) {
			const char = line[c];
			if (quote) {
				if (char === '`') {
					text += '  ';
					c += 1;
					continue;
				}
				if (char === quote) {
					quote = '';
					text += char;
					continue;
				}
				text += ' ';
				continue;
			}
			if (char === '"' || char === "'") {
				quote = char;
				text += char;
				continue;
			}
			if (char === ';' && (c === 0 || /\s/.test(line[c - 1]))) break;
			text += char;
		}
		// A string still open at the end of a line opens a continuation section
		// when the next line starts with "(": its lines are data, not code.
		if (quote && i + 1 < raw.length && raw[i + 1].trim().startsWith('(')) {
			sectionQuote = quote;
			out.push(text);
			out.push('');
			i += 1;
			continue;
		}
		out.push(text);
	}
	return out;
}

/**
 * Measures a line's indentation, a tab counting as four columns.
 * @param {string} line Code line.
 * @returns {number} Leading whitespace width.
 */
function indentOf(line) {
	const lead = line.match(/^[\t ]*/)[0];
	return lead.replace(/\t/g, '    ').length;
}

/**
 * Finds the position of the brace closing the one at (line, col).
 * @param {string[]} lines Code lines.
 * @param {number} line Line of the opening brace.
 * @param {number} col Column of the opening brace.
 * @returns {{line: number, col: number}} Position of the closing brace, or the
 *   end of the file when it never closes.
 */
function matchBrace(lines, line, col) {
	let depth = 0;
	for (let l = line; l < lines.length; l += 1) {
		for (let c = l === line ? col : 0; c < lines[l].length; c += 1) {
			if (lines[l][c] === '{') depth += 1;
			else if (lines[l][c] === '}') {
				depth -= 1;
				if (depth === 0) return { line: l, col: c };
			}
		}
	}
	return { line: lines.length - 1, col: 0 };
}

/**
 * Reads an expression from a position to where it ends: an unmatched closing
 * bracket, a comma at its own depth, or a line end outside any bracket that the
 * next line does not continue with an operator.
 * @param {string[]} lines Code lines.
 * @param {number} line Start line.
 * @param {number} col Start column.
 * @returns {{text: string, line: number, col: number}} The expression text and
 *   the position just past it.
 */
function readExpression(lines, line, col) {
	let depth = 0;
	let text = '';
	for (let l = line; l < lines.length; l += 1) {
		for (let c = l === line ? col : 0; c < lines[l].length; c += 1) {
			const char = lines[l][c];
			if ('([{'.includes(char)) depth += 1;
			else if (')]}'.includes(char)) {
				if (depth === 0) return { text, line: l, col: c };
				depth -= 1;
			} else if (char === ',' && depth === 0) return { text, line: l, col: c };
			text += char;
		}
		const next = l + 1 < lines.length ? lines[l + 1].trim() : '';
		const continued = /^(\.\s|&&|\|\||\?|:(?!:)|and\b|or\b)/i.test(next);
		if (depth === 0 && !continued) return { text, line: l, col: lines[l].length };
		text += '\n';
	}
	return { text, line: lines.length - 1, col: 0 };
}

/**
 * Reads the arguments of a call from just past its opening parenthesis to the
 * parenthesis that closes it.
 * @param {string[]} lines Code lines.
 * @param {number} line Line of the opening parenthesis.
 * @param {number} col Column just past it.
 * @returns {string[]} The top-level arguments, in order.
 */
function readArguments(lines, line, col) {
	const args = [''];
	let depth = 0;
	for (let l = line; l < lines.length; l += 1) {
		for (let c = l === line ? col : 0; c < lines[l].length; c += 1) {
			const char = lines[l][c];
			if ('([{'.includes(char)) depth += 1;
			else if (')]}'.includes(char)) {
				if (depth === 0) return args;
				depth -= 1;
			} else if (char === ',' && depth === 0) {
				args.push('');
				continue;
			}
			args[args.length - 1] += char;
		}
		args[args.length - 1] += '\n';
	}
	return args;
}

/**
 * Extracts parameter names from a parameter list.
 * @param {string} list Text between the parentheses, or a bare parameter.
 * @returns {string[]} Parameter names.
 */
function parameterNames(list) {
	return list
		.split(',')
		.map((part) => part.replace(/:=.*$/s, '').replace(/[&*?]/g, '').trim())
		.filter(isIdentifier);
}

/**
 * Lists the variables a closure body reads or writes: identifiers that are not
 * member names after a dot, object-literal keys, or its own parameters.
 * @param {string} body Closure body with strings and comments blanked.
 * @param {string[]} own Names the closure declares itself.
 * @returns {Set<string>} Referenced outer names, lower-cased (AHK names are
 *   case-insensitive).
 */
function referencedNames(body, own) {
	const ownLower = new Set(own.map((name) => name.toLowerCase()));
	// A nested arrow's parameters shadow the outer names for its own body.
	for (const m of body.matchAll(/\(([^()]*)\)\s*=>/g))
		for (const name of parameterNames(m[1])) ownLower.add(name.toLowerCase());
	for (const m of body.matchAll(/(?<![\p{L}\p{N}_.)\]])([\p{L}_][\p{L}\p{N}_]*)\s*=>/gu))
		ownLower.add(m[1].toLowerCase());
	const found = new Set();
	for (const m of body.matchAll(IDENT_GLOBAL)) {
		const before = body.slice(0, m.index);
		const after = body.slice(m.index + m[0].length);
		if (/\S\.$/.test(before) || /^\.$/.test(before)) continue;
		if (/[{,]\s*$/.test(before) && /^\s*:(?!=)/.test(after)) continue;
		const lower = m[0].toLowerCase();
		if (!ownLower.has(lower)) found.add(lower);
	}
	return found;
}

// =================================
// =================================
// ======= 2/ Finding loops ========
// =================================
// =================================

/**
 * Lists every `for` loop with its variables and the lines of its body.
 * @param {string[]} lines Code lines.
 * @returns {Array<{line: number, vars: string[], from: number, to: number}>}
 *   Loops with 0-based header line and inclusive body line range.
 */
function forLoops(lines) {
	const loops = [];
	lines.forEach((line, i) => {
		const m = line.match(/^\s*for\b\s*\(?\s*(.*?)\s+in\b/i);
		if (!m) return;
		const vars = loopVariables(m[1]);
		// The header ends where its brackets balance, a block brace aside.
		let end = i;
		let depth = 0;
		for (;;) {
			const text = lines[end].replace(/\{\s*$/, '');
			for (const char of text) {
				if ('([{'.includes(char)) depth += 1;
				else if (')]}'.includes(char)) depth -= 1;
			}
			if (depth <= 0 || end + 1 >= lines.length) break;
			end += 1;
		}
		let next = end + 1;
		while (next < lines.length && lines[next].trim() === '') next += 1;
		let brace = null;
		if (/\{\s*$/.test(lines[end])) brace = { line: end, col: lines[end].lastIndexOf('{') };
		else if (next < lines.length && lines[next].trim() === '{')
			brace = { line: next, col: lines[next].indexOf('{') };
		if (brace) {
			const close = matchBrace(lines, brace.line, brace.col);
			loops.push({ line: i, vars, from: brace.line + 1, to: close.line - 1 });
			return;
		}
		// One unbraced statement: every following line indented deeper than the header.
		const base = indentOf(line);
		let to = end;
		for (let l = end + 1; l < lines.length; l += 1) {
			if (lines[l].trim() === '') continue;
			if (indentOf(lines[l]) <= base) break;
			to = l;
		}
		loops.push({ line: i, vars, from: end + 1, to });
	});
	return loops;
}

// ====================================
// ====================================
// ======= 3/ Finding closures ========
// ====================================
// ====================================

/**
 * Lists the outermost closures of a line range: fat arrows and nested
 * functions, each with the names it references from outside itself.
 * @param {string[]} lines Code lines.
 * @param {number} from First line of the range.
 * @param {number} to Last line of the range, inclusive.
 * @returns {Array<{line: number, kind: string, name: string, names: Set<string>,
 *   start: {line: number, col: number}, end: {line: number, col: number}}>}
 *   Closures with 0-based line, `arrow` or `function`, a function name when it
 *   has one, its referenced outer names, and the span it occupies.
 */
function closuresIn(lines, from, to) {
	const found = [];
	let line = from;
	let col = 0;
	while (line <= to && line < lines.length) {
		const text = lines[line];
		if (col === 0) {
			const def = text.match(/^\s*(?:static\s+)?([\p{L}_][\p{L}\p{N}_]*)\(/u);
			if (def && !KEYWORDS.has(def[1].toLowerCase())) {
				const open = text.indexOf('(', def[0].length - 1);
				const params = readExpression(lines, line, open + 1);
				const rest = lines[params.line].slice(params.col + 1);
				let brace = null;
				if (/^\s*\{\s*$/.test(rest))
					brace = { line: params.line, col: lines[params.line].indexOf('{', params.col) };
				else if (rest.trim() === '' && (lines[params.line + 1] || '').trim() === '{')
					brace = { line: params.line + 1, col: lines[params.line + 1].indexOf('{') };
				if (brace) {
					const close = matchBrace(lines, brace.line, brace.col);
					const body = lines.slice(brace.line, close.line + 1).join('\n');
					const own = parameterNames(params.text);
					for (const m of body.matchAll(/^\s*(?:local|static|global)\s+(.*)$/gim))
						for (const part of m[1].split(',')) {
							const declared = part.replace(/:=.*$/s, '').trim();
							if (isIdentifier(declared)) own.push(declared);
						}
					for (const m of body.matchAll(/^\s*for\b\s*\(?\s*(.*?)\s+in\b/gim))
						own.push(...loopVariables(m[1]));
					found.push({
						line,
						kind: 'function',
						name: def[1],
						names: referencedNames(body, own),
						start: { line, col: 0 },
						end: close
					});
					line = close.line + 1;
					col = 0;
					continue;
				}
			}
		}
		const arrow = text.indexOf('=>', col);
		if (arrow < 0) {
			line += 1;
			col = 0;
			continue;
		}
		const head = text.slice(0, arrow).replace(/\s+$/, '');
		let own = [];
		let name = '';
		if (head.endsWith(')')) {
			let depth = 0;
			let open = head.length - 1;
			for (; open >= 0; open -= 1) {
				if (head[open] === ')') depth += 1;
				else if (head[open] === '(') {
					depth -= 1;
					if (depth === 0) break;
				}
			}
			own = parameterNames(head.slice(open + 1, head.length - 1));
			const named = head.slice(0, open).match(/([\p{L}_][\p{L}\p{N}_]*)$/u);
			if (named && !KEYWORDS.has(named[1].toLowerCase())) name = named[1];
		} else {
			const bare = head.match(/([\p{L}_][\p{L}\p{N}_]*)$/u);
			if (bare) own = [bare[1]];
		}
		const body = readExpression(lines, line, arrow + 2);
		found.push({
			line,
			kind: 'arrow',
			name,
			names: referencedNames(body.text, own),
			start: { line, col: arrow },
			end: { line: body.line, col: body.col }
		});
		if (body.line === line && body.col <= arrow) col = arrow + 2;
		else {
			line = body.line;
			col = body.col;
		}
	}
	return found;
}

// ================================
// ================================
// ======= 4/ The two rules =======
// ================================
// ================================

/**
 * Reports whether a position lies inside a closure's span.
 * @param {{start: {line: number, col: number}, end: {line: number, col: number}}} closure
 * @param {number} line 0-based line.
 * @param {number} col Column.
 * @returns {boolean} True inside the span, bounds included.
 */
function within(closure, line, col) {
	const { start, end } = closure;
	const afterStart = line > start.line || (line === start.line && col >= start.col);
	const beforeEnd = line < end.line || (line === end.line && col <= end.col);
	return afterStart && beforeEnd;
}

/**
 * Lists the state one iteration leaves behind for a closure registered in it:
 * the loop's variables and every local the body assigns outside its nested
 * functions, including the variables of inner loops and output references.
 * @param {string[]} lines Code lines.
 * @param {{vars: string[], from: number, to: number}} loop The loop.
 * @param {Array<{kind: string, start: {line: number}, end: {line: number}}>} closures
 *   Closures of the body; nested function bodies are their own scope.
 * @returns {Map<string, string>} Lower-cased name to its spelling.
 */
function loopWrittenNames(lines, loop, closures) {
	const names = new Map(loop.vars.map((name) => [name.toLowerCase(), name]));
	const record = (name) => {
		if (!names.has(name.toLowerCase())) names.set(name.toLowerCase(), name);
	};
	const functions = closures.filter((c) => c.kind === 'function');
	for (let l = loop.from; l <= loop.to && l < lines.length; l += 1) {
		if (functions.some((f) => l >= f.start.line && l <= f.end.line)) continue;
		const text = lines[l];
		const inner = text.match(/^\s*for\b\s*\(?\s*(.*?)\s+in\b/i);
		if (inner) loopVariables(inner[1]).forEach(record);
		const assigned =
			/(?<![\p{L}\p{N}_.\]])([\p{L}_][\p{L}\p{N}_]*)\s*(?::=|\+=|-=|\*=|\/\/=|\/=|\.=|\|=|&=|\^=|>>>=|>>=|<<=|\?\?=|\+\+|--)/gu;
		for (const m of text.matchAll(assigned)) record(m[1]);
		for (const m of text.matchAll(/(?:\+\+|--|&)([\p{L}_][\p{L}\p{N}_]*)/gu)) record(m[1]);
		const caught = text.match(/\bcatch\b.*\bas\s+([\p{L}_][\p{L}\p{N}_]*)/iu);
		if (caught) record(caught[1]);
	}
	return names;
}

/**
 * Reports every closure inside a `for` body that references one of the loop's
 * variables, and every test registration inside a `for` body whose callable is
 * an inline arrow, or a nested function of that body reading state the
 * iteration wrote.
 * @param {string} src File content.
 * @returns {Array<{line: number, rule: string, detail: string}>} Findings with
 *   1-based lines.
 */
function analyse(src) {
	const lines = codeLines(src);
	// Keyed by line and rule: a closure inside nested loops is one finding that
	// names the variables of every loop it reads.
	const findings = new Map();
	const add = (line, rule, parts) => {
		const key = `${line}:${rule}`;
		if (!findings.has(key)) findings.set(key, { line: line + 1, rule, parts: [] });
		const prior = findings.get(key).parts;
		for (const part of parts) if (!prior.includes(part)) prior.push(part);
	};
	for (const loop of forLoops(lines)) {
		const vars = new Map(loop.vars.map((name) => [name.toLowerCase(), name]));
		const closures = closuresIn(lines, loop.from, loop.to);
		for (const closure of closures) {
			const read = [...closure.names]
				.filter((name) => vars.has(name))
				.map((name) => vars.get(name));
			if (read.length > 0) add(closure.line, 'reads-loop-variable', read);
		}
		const written = loopWrittenNames(lines, loop, closures);
		const nested = new Map(
			closures.filter((c) => c.kind === 'function').map((c) => [c.name.toLowerCase(), c])
		);
		for (let l = loop.from; l <= loop.to && l < lines.length; l += 1) {
			for (const call of lines[l].matchAll(/(?<![\p{L}\p{N}_.])Test\s*\(/gu)) {
				// A registration inside a closure of the body (the immediately
				// called arrow that binds the item) belongs to that closure's scope.
				if (closures.some((c) => within(c, l, call.index))) continue;
				const args = readArguments(lines, l, call.index + call[0].length);
				const callable = (args[args.length - 1] || '').trim();
				if (callable.includes('=>')) {
					add(l, 'registers-closure', ['Test(…, () => …)']);
					continue;
				}
				const fn = nested.get(callable.toLowerCase());
				const read = fn
					? [...fn.names].filter((name) => written.has(name)).map((name) => written.get(name))
					: [];
				if (read.length > 0)
					add(l, 'registers-closure', [`Test(…, ${callable}) reads ${read.join(', ')}`]);
			}
		}
	}
	return [...findings.values()]
		.sort((a, b) => a.line - b.line)
		.map((f) => ({ line: f.line, rule: f.rule, detail: f.parts.join(', ') }));
}

// ================================
// ================================
// ======= 5/ Self-test ===========
// ================================
// ================================

// Each fixture states what the analysis must report: the shipped shapes must be
// caught, the helper and Bind fixes must pass clean.
const FIXTURES = [
	{
		name: 'AssertThrows over the loop variable (virtual desktops, 2026-09)',
		expect: ['reads-loop-variable:Vector'],
		src: [
			'_Refuses() {',
			'\tfor _, Vector in Corpus["invalid"] {',
			'\t\tAssertThrows(() => Target(Vector["index"], Vector["count"],',
			'\t\t\tVector["wrap"]), Vector["id"] . " must be refused")',
			'\t}',
			'}'
		]
	},
	{
		name: 'the second line of a continued closure is still read',
		expect: ['reads-loop-variable:Item'],
		src: [
			'F() {',
			'\tfor Item in Items {',
			'\t\tAssertThrows(() => Product(1,',
			'\t\t\tItem))',
			'\t}',
			'}'
		]
	},
	{
		name: 'an unbraced inner loop inside a braced outer one',
		expect: ['reads-loop-variable:Scope, Mode'],
		src: [
			'F() {',
			'\tfor Scope in ["global", "tap_holds"] {',
			'\t\tfor Mode in ["recommended", "clear"]',
			'\t\t\tAssertThrows(() => Apply(Scope, Mode, Map()))',
			'\t}',
			'}'
		]
	},
	{
		name: 'a recorder arrow in an object literal (system actions, 2026-09)',
		expect: ['reads-loop-variable:Id'],
		src: [
			'F() {',
			'\tfor Id in Ids {',
			'\t\tActions[Id] := { Fn: (*) => Ran.Push(Id) }',
			'\t}',
			'}'
		]
	},
	{
		name: 'a nested function defined in the loop body',
		expect: ['reads-loop-variable:Id'],
		src: [
			'F() {',
			'\tfor Id in Ids {',
			'\t\tRecord(*) {',
			'\t\t\tRan.Push(Id)',
			'\t\t}',
			'\t\tRun(Record)',
			'\t}',
			'}'
		]
	},
	{
		name: 'a registration of an inline closure over a copy of the loop variable',
		expect: ['registers-closure:Test(…, () => …)'],
		src: [
			'F() {',
			'\tfor Vec in Corpus {',
			'\t\tVecCopy := Vec',
			'\t\tTest(VecCopy["id"], () => Run(VecCopy))',
			'\t}',
			'}'
		]
	},
	{
		name: 'a registration of a nested function reading a copy (TOML fuzz corpus, 2026-09)',
		expect: ['registers-closure:Test(…, _Fail) reads Name'],
		src: [
			'F() {',
			'\tfor Conflict in Conflicts {',
			'\t\tName := Conflict.name',
			'\t\t_Fail() {',
			'\t\t\tAssertEqual("", Name)',
			'\t\t}',
			'\t\tTest("conflict " . Conflict.name, _Fail)',
			'\t}',
			'}'
		]
	},
	{
		name: 'a registered nested function that reads nothing the loop wrote',
		expect: [],
		src: [
			'F() {',
			'\tfor Vec in Corpus {',
			'\t\tif (Vec["id"] = "SEC-009") {',
			'\t\t\t_Negative() {',
			'\t\t\t\tAssertTrue(!IsPassword("Edit", "0x80000000"))',
			'\t\t\t}',
			'\t\t\tTest("negative case", _Negative)',
			'\t\t}',
			'\t}',
			'}'
		]
	},
	{
		name: 'the immediately called arrow binds the item for the registration',
		expect: [],
		src: [
			'for _Entry in Siblings() {',
			'\t(_Sib => Test(',
			'\t\t"reset " . _Sib["reset_fn"],',
			'\t\t() => _CheckReset(_Sib)',
			'\t))(_Entry)',
			'}'
		]
	},
	{
		name: 'the helper pattern: the closure reads a parameter',
		expect: [],
		src: [
			'_RefusesCase(Vector) {',
			'\tAssertThrows(() => Target(Vector["index"]), Vector["id"] . " must be refused")',
			'}',
			'',
			'_Refuses() {',
			'\tfor _, Vector in Corpus["invalid"]',
			'\t\t_RefusesCase(Vector)',
			'}'
		]
	},
	{
		name: 'Bind stores the value per callable',
		expect: [],
		src: [
			'F() {',
			'\tfor Vec in Corpus {',
			'\t\tAssertThrows(Target.Bind(Vec["index"]), Vec["id"])',
			'\t\tTest(Vec["id"], _Run.Bind(Vec))',
			'\t}',
			'}'
		]
	},
	{
		name: 'shadowing, member names, keys, strings and comments are not reads',
		expect: [],
		src: [
			'F() {',
			'\tfor Name in Names {',
			'\t\tUse((Name) => Name . "!")',
			'\t\tUse((*) => Obj.Name . "Name")  ; () => Name',
			'\t\tUse((*) => { Name: 1 })',
			'\t}',
			'}'
		]
	},
	{
		name: 'a local the body assigned keeps its capture when the closure runs at once',
		expect: [],
		src: [
			'F() {',
			'\tfor Name in Names {',
			'\t\tPath := Dir . Name',
			'\t\tAssertThrows(() => Load(Path), Name . " must be rejected")',
			'\t}',
			'}'
		]
	},
	{
		name: 'a continuation section is data',
		expect: [],
		src: [
			'F() {',
			'\tfor Item in Items {',
			'\t\tText := "',
			'\t\t(',
			'\t\tUse(() => Item)',
			'\t\t)"',
			'\t}',
			'}'
		]
	}
];

/**
 * Runs every fixture and exits non-zero on the first that the analysis
 * misreads.
 */
function selfTest() {
	for (const fixture of FIXTURES) {
		const got = analyse(fixture.src.join('\n')).map((f) => `${f.rule}:${f.detail}`);
		if (JSON.stringify(got) !== JSON.stringify(fixture.expect)) {
			console.error(`\x1b[31m[ERROR] Loop-capture self-test failed: ${fixture.name}\x1b[0m`);
			console.error(
				`  expected ${JSON.stringify(fixture.expect)}\n  got      ${JSON.stringify(got)}`
			);
			process.exit(1);
		}
	}
}

// ==============================
// ==============================
// ======= 6/ Entry point =======
// ==============================
// ==============================

/**
 * Collects every AutoHotkey file below a directory, vendored code aside.
 * @param {string} dir Directory to walk.
 * @param {string[]} acc Accumulator.
 * @returns {string[]} Absolute paths.
 */
function walk(dir, acc = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name !== 'vendor') walk(full, acc);
		} else if (entry.name.endsWith('.ahk')) acc.push(full);
	}
	return acc;
}

selfTest();

const findings = [];
for (const file of walk(WINDOWS)) {
	for (const finding of analyse(fs.readFileSync(file, 'utf8')))
		findings.push({ file: path.relative(ROOT, file).replace(/\\/g, '/'), ...finding });
}

if (findings.length > BASELINE) {
	console.error(
		`\x1b[31m[ERROR] ${findings.length} closure(s) inside a for loop lose the loop's value (baseline ${BASELINE}).\x1b[0m`
	);
	console.error(
		'  reads-loop-variable: AutoHotkey 2.0 rebinds a for variable away from its captured cell, so\n' +
			'  the closure reads the value from before the loop (usually unset) even inside the same\n' +
			'  iteration; within AssertThrows that UnsetError passes whatever the product does.\n' +
			'  registers-closure: a registered closure runs after the loop and reads the last\n' +
			"  iteration's value, including through a copy of the loop variable.\n" +
			'  Fix: move the body into a helper called once per item whose closure reads a parameter,\n' +
			'  or pass the value with .Bind(item), which evaluates its arguments at once.\n'
	);
	for (const f of findings) console.error(`    ${f.file}:${f.line}  ${f.rule}  ${f.detail}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No closure inside a for loop loses the loop's value (${findings.length}/${BASELINE}, ${FIXTURES.length} self-test fixtures).\x1b[0m`
);
