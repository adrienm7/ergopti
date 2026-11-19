// tools/test/lib/i18n-key-sites.cjs

/**
 * ==============================================================================
 * MODULE: Translation Key Call Sites
 * DESCRIPTION:
 * Finds every call of a translation accessor in the shipped JavaScript, Lua
 * and AutoHotkey source and reads its key argument as far as the source states
 * it: a whole key (a literal, a file constant, a page prefix plus a literal),
 * a family (a literal or constant head followed by a run-time part), or
 * nothing (a key read from a variable).
 *
 * FEATURES & RATIONALE:
 * 1. A page-prefixed accessor (editor_page.js `tl = (key) => t(PREFIX + key)`)
 *    is recognised from its definition, so `tl('caps.label')` reads as
 *    `layout_editor.caps.label`; the static audit read none of these keys.
 * 2. A member accessor (`view.t`, `INFO.t`) counts as a call: the layer
 *    model's `view.t('layer_editor.key.' + NAMED_KEYS[code])` names the key
 *    family the Studio showed raw.
 * 3. A family is reported with its literal head; the caller enumerates its
 *    keys from the data the code reads (i18n-dynamic-keys/*.cjs).
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');
const DRIVERS_DIR = path.join(REPO_ROOT, 'static', 'ergopti_plus');

// Directories that never carry shipped, user-facing source.
const SKIPPED = new Set(['node_modules', '.git', '_generated', 'tests', 'vendor']);

// The translation accessors of each language: a call of one of these names
// translates its first argument.
const ACCESSORS = Object.freeze({
	'.js': ['t', 'tl', 'tr', '_t', '*.t'],
	'.lua': [
		't',
		'tr',
		'i18n_safe',
		'i18n.get',
		'I18n.get',
		'i18n_mod.get',
		'locale_mod.get',
		'i18n.format',
		'options.tr',
		'ctx.t'
	],
	'.ahk': ['t']
});

// The concatenation operator of each language.
const CONCAT = Object.freeze({ '.js': '+', '.lua': '..', '.ahk': '.' });

// The shape of a catalogue key: dotted lower-case identifiers.
const KEY_SHAPE = /^[a-z][a-z0-9_]*(\.[A-Za-z0-9_]+)+$/;

/**
 * Lists the shipped source files of the drivers and the shared tree.
 * @param {string} dir - Directory to walk.
 * @param {string[]} out - Accumulator.
 * @returns {string[]} Absolute paths of the .js, .lua and .ahk files.
 */
function sourceFiles(dir = DRIVERS_DIR, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (SKIPPED.has(entry.name)) continue;
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) sourceFiles(full, out);
		else if (Object.hasOwn(ACCESSORS, path.extname(entry.name))) out.push(full);
	}
	return out;
}

/**
 * Blanks the comments of a source while keeping its strings and offsets.
 * @param {string} text - Source text.
 * @param {string} ext - '.js', '.lua' or '.ahk'.
 * @returns {string} The text with every comment replaced by spaces.
 */
function blankComments(text, ext) {
	// The comment ranges, blanked once the walk is done.
	const ranges = [];
	const blank = (from, to) => ranges.push([from, to]);
	let i = 0;
	const n = text.length;
	const lineStart = (at) => at === 0 || text[at - 1] === '\n';
	// Only these characters can open a comment or a string: jump between them.
	const opener = ext === '.js' ? /[/"'`]/g : ext === '.lua' ? /[-"']/g : /[;/"']/g;
	while (i < n) {
		opener.lastIndex = i;
		const next = opener.exec(text);
		if (!next) break;
		i = next.index;
		const c = text[i];
		if (ext === '.js') {
			if (c === '/' && text[i + 1] === '/') {
				const end = text.indexOf('\n', i);
				blank(i, end === -1 ? n : end);
				i = end === -1 ? n : end;
				continue;
			}
			if (c === '/' && text[i + 1] === '*') {
				const end = text.indexOf('*/', i + 2);
				blank(i, end === -1 ? n : end + 2);
				i = end === -1 ? n : end + 2;
				continue;
			}
			if (c === '"' || c === "'" || c === '`') {
				i = skipString(text, i, ext);
				continue;
			}
		} else if (ext === '.lua') {
			if (c === '-' && text[i + 1] === '-') {
				const long = /^--\[(=*)\[/.exec(text.slice(i, i + 12));
				const end = long ? text.indexOf(']' + long[1] + ']', i) : text.indexOf('\n', i);
				const stop = end === -1 ? n : long ? end + long[1].length + 2 : end;
				blank(i, stop);
				i = stop;
				continue;
			}
			if (c === '"' || c === "'") {
				i = skipString(text, i, ext);
				continue;
			}
		} else {
			// AutoHotkey: `;` opens a comment at a line start or after white space.
			if (c === ';' && (lineStart(i) || /\s/.test(text[i - 1]))) {
				const end = text.indexOf('\n', i);
				blank(i, end === -1 ? n : end);
				i = end === -1 ? n : end;
				continue;
			}
			if (
				c === '/' &&
				text[i + 1] === '*' &&
				/^\s*$/.test(text.slice(text.lastIndexOf('\n', i) + 1, i))
			) {
				const end = text.indexOf('*/', i + 2);
				blank(i, end === -1 ? n : end + 2);
				i = end === -1 ? n : end + 2;
				continue;
			}
			if (c === '"' || c === "'") {
				i = skipString(text, i, ext);
				continue;
			}
		}
		i++;
	}
	let out = '';
	let at = 0;
	for (const [from, to] of ranges) {
		out += text.slice(at, from) + text.slice(from, to).replace(/[^\n]/g, ' ');
		at = to;
	}
	return out + text.slice(at);
}

/**
 * The index just past the string literal that opens at `start`.
 * @param {string} text - Source text.
 * @param {number} start - Index of the opening quote.
 * @param {string} ext - Language extension.
 * @returns {number}
 */
function skipString(text, start, ext) {
	const quote = text[start];
	const escape = ext === '.ahk' ? '`' : '\\';
	let i = start + 1;
	while (i < text.length) {
		const c = text[i];
		if (c === escape) {
			i += 2;
			continue;
		}
		if (quote === '`' && c === '$' && text[i + 1] === '{') {
			i = skipBalanced(text, i + 1, ext);
			continue;
		}
		if (c === quote) return i + 1;
		if (c === '\n' && quote !== '`') return i;
		i++;
	}
	return i;
}

/**
 * The index just past the bracket group that opens at `start`.
 * @param {string} text - Source text.
 * @param {number} start - Index of an opening bracket.
 * @param {string} ext - Language extension.
 * @returns {number}
 */
function skipBalanced(text, start, ext) {
	const pairs = { '(': ')', '[': ']', '{': '}' };
	const stack = [pairs[text[start]]];
	let i = start + 1;
	while (i < text.length && stack.length) {
		const c = text[i];
		if (c === '"' || c === "'" || (c === '`' && ext === '.js')) {
			i = skipString(text, i, ext);
			continue;
		}
		if (Object.hasOwn(pairs, c)) stack.push(pairs[c]);
		else if (c === stack[stack.length - 1]) stack.pop();
		i++;
	}
	return i;
}

/**
 * The raw text of a call's first argument.
 * @param {string} text - Source text, comments blanked.
 * @param {number} open - Index just past the call's `(`.
 * @param {string} ext - Language extension.
 * @returns {string}
 */
function firstArgument(text, open, ext) {
	let i = open;
	while (i < text.length) {
		const c = text[i];
		if (c === '"' || c === "'" || (c === '`' && ext === '.js')) {
			i = skipString(text, i, ext);
			continue;
		}
		if (c === '(' || c === '[' || c === '{') {
			i = skipBalanced(text, i, ext);
			continue;
		}
		if (c === ',' || c === ')' || c === ']' || c === '}') break;
		i++;
	}
	return text.slice(open, i).trim();
}

/**
 * Splits an expression at its top-level concatenation operators.
 * @param {string} expr - Expression text.
 * @param {string} ext - Language extension.
 * @returns {string[]} The operands, trimmed.
 */
function concatParts(expr, ext) {
	const op = CONCAT[ext];
	const parts = [];
	let i = 0;
	let from = 0;
	while (i < expr.length) {
		const c = expr[i];
		if (c === '"' || c === "'" || (c === '`' && ext === '.js')) {
			i = skipString(expr, i, ext);
			continue;
		}
		if (c === '(' || c === '[' || c === '{') {
			i = skipBalanced(expr, i, ext);
			continue;
		}
		const isOp =
			ext === '.ahk'
				? c === '.' && /\s/.test(expr[i - 1] || '') && /\s/.test(expr[i + 1] || '')
				: ext === '.lua'
					? expr.startsWith('..', i) && expr[i + 2] !== '.'
					: c === '+' && expr[i + 1] !== '+' && expr[i - 1] !== '+' && expr[i + 1] !== '=';
		if (isOp) {
			parts.push(expr.slice(from, i).trim());
			i += op.length;
			from = i;
			continue;
		}
		i++;
	}
	parts.push(expr.slice(from).trim());
	return parts;
}

/**
 * Reads a plain string literal (no interpolation).
 * @param {string} part - One operand.
 * @param {string} ext - Language extension.
 * @returns {string|null} Its value, or null when the operand is not one.
 */
function literalValue(part, ext) {
	const m = /^(["'])((?:(?!\1)[^\\`\n]|\\.)*)\1$/.exec(part);
	if (!m) return null;
	if (ext === '.ahk' && m[2].includes('`')) return null;
	if (m[2].includes('\\')) return null;
	return m[2];
}

/**
 * The string constants a file declares once, by name.
 * @param {string} text - Source text, comments blanked.
 * @param {string} ext - Language extension.
 * @returns {Map<string, string>}
 */
function fileConstants(text, ext) {
	const pattern =
		ext === '.js'
			? /(?:^|[\s;{(])(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(['"])([^'"\\\n]*)\2\s*[;,\n]/g
			: ext === '.lua'
				? /(?:^|\s)local\s+([A-Za-z_]\w*)\s*=\s*(["'])([^'"\\\n]*)\2[ \t]*(?=[;\n]|$)/g
				: /(?:^|\n)\s*(?:global\s+|static\s+)?([A-Za-z_]\w*)\s*:=\s*(")([^"`\n]*)"\s*(?=\n)/g;
	const seen = new Map();
	for (const m of text.matchAll(pattern)) {
		const name = m[1];
		if (seen.has(name) && seen.get(name) !== m[3]) seen.set(name, null);
		else seen.set(name, m[3]);
	}
	return new Map([...seen].filter(([, value]) => value !== null));
}

/**
 * Resolves one operand to its string, as far as the file states it.
 * @param {string} part - The operand.
 * @param {string} ext - Language extension.
 * @param {Map<string, string>} constants - The file's string constants.
 * @returns {{text: string, whole: boolean}} The leading text it states, and
 *   whether that text is all of it.
 */
function resolvePart(part, ext, constants) {
	const literal = literalValue(part, ext);
	if (literal !== null) return { text: literal, whole: true };
	if (constants.has(part)) return { text: constants.get(part), whole: true };
	if (ext === '.js' && part.startsWith('`') && part.endsWith('`')) {
		let text = '';
		const body = part.slice(1, -1);
		let i = 0;
		while (i < body.length) {
			if (body[i] === '\\') return { text, whole: false };
			if (body[i] === '$' && body[i + 1] === '{') {
				const end = skipBalanced(body, i + 1, ext);
				const inner = body.slice(i + 2, end - 1).trim();
				if (!constants.has(inner)) return { text, whole: false };
				text += constants.get(inner);
				i = end;
				continue;
			}
			text += body[i];
			i++;
		}
		return { text, whole: true };
	}
	return { text: '', whole: false };
}

/**
 * Reads a key argument: a whole key, a family head, or nothing.
 * @param {string} expr - The argument text.
 * @param {string} ext - Language extension.
 * @param {Map<string, string>} constants - The file's string constants.
 * @returns {{kind: 'key'|'family'|'opaque', text: string}}
 */
function readKey(expr, ext, constants) {
	let text = '';
	for (const part of concatParts(expr, ext)) {
		const resolved = resolvePart(part, ext, constants);
		text += resolved.text;
		if (!resolved.whole) return { kind: text === '' ? 'opaque' : 'family', text };
	}
	return { kind: text === '' ? 'opaque' : 'key', text };
}

/**
 * The page-prefixed accessors a JavaScript file defines:
 * `const tl = (key, values) => t(PREFIX + key, values)`.
 * @param {string} text - Source text, comments blanked.
 * @param {Map<string, string>} constants - The file's string constants.
 * @returns {Map<string, string>} Accessor name -> the prefix it adds; its
 *   `spans` property lists the [start, end) offsets of the definitions, whose
 *   own inner call is not a site.
 */
function prefixedAccessors(text, constants) {
	const found = new Map();
	found.spans = [];
	const shapes = [
		/(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*\(\s*([A-Za-z_$][\w$]*)[^)]*\)\s*=>\s*([\w$.]+)\(\s*([^,()]+?)\s*\+\s*\2\s*[,)]/g,
		/function\s+([A-Za-z_$][\w$]*)\s*\(\s*([A-Za-z_$][\w$]*)[^)]*\)\s*\{\s*return\s+([\w$.]+)\(\s*([^,()]+?)\s*\+\s*\2\s*[,)]/g
	];
	for (const shape of shapes)
		for (const m of text.matchAll(shape)) {
			const head = readKey(m[4], '.js', constants);
			if (head.kind !== 'key') continue;
			found.set(m[1], head.text);
			found.spans.push([m.index, m.index + m[0].length]);
		}
	return found;
}

/**
 * Every translation call of one file.
 * @param {string} file - Absolute path.
 * @returns {{file: string, line: number, accessor: string, kind: string, text: string, expr: string}[]}
 */
function sitesOf(file) {
	const ext = path.extname(file);
	const raw = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
	const text = blankComments(raw, ext);
	const constants = fileConstants(text, ext);
	const prefixed =
		ext === '.js' ? prefixedAccessors(text, constants) : Object.assign(new Map(), { spans: [] });
	const names = ACCESSORS[ext].filter((name) => name !== '*.t');
	const member = ACCESSORS[ext].includes('*.t');
	const escaped = names.map((name) => name.replace(/[.$]/g, '\\$&'));
	const alternatives = [...escaped, ...[...prefixed.keys()].map((n) => n.replace(/\$/g, '\\$'))];
	const head = member
		? `(?:${alternatives.join('|')}|[A-Za-z_$][\\w$]*\\.t)`
		: `(?:${alternatives.join('|')})`;
	// Not a property of something else (`foo.t(` only through the member form),
	// and not a definition (`function t(`).
	const call = new RegExp(`(?<![\\w$.:])${head}\\(`, 'g');
	const relative = path.relative(REPO_ROOT, file).split(path.sep).join('/');
	const sites = [];
	// Line starts, for a site's line number without rescanning the file.
	const starts = [0];
	for (let i = raw.indexOf('\n'); i !== -1; i = raw.indexOf('\n', i + 1)) starts.push(i + 1);
	const lineOf = (at) => {
		let low = 0;
		let high = starts.length - 1;
		while (low < high) {
			const mid = (low + high + 1) >> 1;
			if (starts[mid] <= at) low = mid;
			else high = mid - 1;
		}
		return low + 1;
	};
	for (const m of text.matchAll(call)) {
		const before = text.slice(Math.max(0, m.index - 10), m.index);
		if (/function\s+$/.test(before)) continue;
		if (prefixed.spans.some(([from, to]) => m.index >= from && m.index < to)) continue;
		const accessor = m[0].slice(0, -1);
		const expr = firstArgument(text, m.index + m[0].length, ext);
		if (expr === '') continue;
		// A function definition's parameter list is not a call (AHK `t(Key) {`).
		const close = m.index + m[0].length + expr.length;
		if (ext === '.ahk' && /^\s*\)\s*\{/.test(text.slice(close, close + 40))) continue;
		const read = readKey(expr, ext, constants);
		const prefix = prefixed.get(accessor) || '';
		const line = lineOf(m.index);
		sites.push({
			file: relative,
			line,
			accessor,
			kind: read.kind,
			text: read.kind === 'opaque' ? '' : prefix + read.text,
			expr
		});
	}
	return sites;
}

/**
 * Every translation call of the shipped source.
 * @returns {ReturnType<typeof sitesOf>}
 */
function allSites() {
	return sourceFiles().flatMap(sitesOf);
}

module.exports = {
	ACCESSORS,
	KEY_SHAPE,
	REPO_ROOT,
	allSites,
	blankComments,
	readKey,
	sitesOf,
	sourceFiles,
	prefixedAccessors,
	fileConstants
};
