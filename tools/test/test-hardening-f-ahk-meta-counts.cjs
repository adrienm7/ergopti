// tools/test/test-hardening-f-ahk-meta-counts.cjs

/**
 * ==============================================================================
 * MODULE: AHK Meta Test Census Mirror (hardening-f-ahk-meta-counts)
 * DESCRIPTION:
 * Many Windows meta tests pin a census of production call sites: how many
 * notices a commit shows, how many times a function is called, which literal
 * i18n keys a branch passes. A production change that adds a call site turns
 * such a test red, which is its purpose, but only on the Windows lane: the
 * AutoHotkey suite cannot run on Linux or macOS, so the drift is found by CI
 * after the push instead of before the commit.
 *
 * ROOT CAUSE ENCODED (incident of 2026-09-30):
 * The first-run commit gained a second notice (the navigation layer import);
 * tests/meta/test_onboarding_no_appstate.ahk still counted one and failed
 * Windows CI run 642 (fixed by 0951955a8).
 *
 * FEATURES & RATIONALE:
 * 1. The AHK test stays the single source of truth: this mirror reads each
 *    `AssertEqual(<expected>, <actual>, ...)` from the meta test files and
 *    recomputes <actual> from the driver source. Expected values are never
 *    copied here, so updating the AHK test is the whole fix.
 * 2. Exact ports of the AHK framework's source helpers (_DriverSourceConcat,
 *    _DriverSourceNoComments, _StripFullLineComments, _DriverFuncBody,
 *    _DriverDirConcat) and of the counting idioms the meta tests define
 *    (InStr and StrReplace occurrence counters, RegExReplace counts, literal-key
 *    listers). An assertion whose expression uses anything else is left to the
 *    Windows lane and counted as not mirrored; floors keep the mirror from
 *    shrinking to nothing.
 * 3. A self-check runs a fixture assertion with a wrong census through the
 *    evaluator, which must report it.
 * 4. `--rev <commit>` evaluates a committed revision straight from Git.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const revArg = process.argv.indexOf('--rev');
const REV = revArg > 0 ? process.argv[revArg + 1] : null;
const VERBOSE = process.argv.includes('--verbose');
const WINDOWS_REL = 'static/ergopti_plus/windows';

// Floors: the mirror must keep evaluating at least this many assertions, and
// the incident's own census must stay among them.
const MIN_MIRRORED = 35;
const MIN_FILES = 10;
const REQUIRED = [
	{ file: 'tests/meta/test_onboarding_no_appstate.ahk', actual: 'NoticeCount' },
	{ file: 'tests/meta/test_onboarding_no_appstate.ahk', actual: 'Notices' },
	{ file: 'tests/meta/test_onboarding_no_appstate.ahk', actual: 'Listed' }
];

// ============================================
// ============================================
// ======= 1/ The Windows tree ================
// ============================================
// ============================================

/**
 * Every .ahk file of the Windows tree: [{ rel, content }], rel relative to
 * windows/ with forward slashes, in the case-insensitive order NTFS lists.
 */
function windowsFiles() {
	let files;
	if (!REV) {
		files = [];
		const base = path.join(ROOT, WINDOWS_REL);
		const walk = (dir) => {
			for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
				const full = path.join(dir, entry.name);
				if (entry.isDirectory()) walk(full);
				else if (entry.name.toLowerCase().endsWith('.ahk')) {
					const rel = path.relative(base, full).replace(/\\/g, '/');
					files.push({ rel, content: fs.readFileSync(full, 'utf8') });
				}
			}
		};
		walk(base);
	} else {
		const listing = execFileSync('git', ['ls-tree', '-r', REV, '--', WINDOWS_REL], {
			cwd: ROOT,
			encoding: 'utf8',
			maxBuffer: 64 * 1024 * 1024
		})
			.split('\n')
			.filter(Boolean)
			.map((line) => {
				const [meta, file] = line.split('\t');
				return { sha: meta.split(' ')[2], rel: file.slice(WINDOWS_REL.length + 1) };
			})
			.filter((entry) => entry.rel.toLowerCase().endsWith('.ahk'));
		const blob = execFileSync('git', ['cat-file', '--batch'], {
			cwd: ROOT,
			input: listing.map((entry) => entry.sha).join('\n') + '\n',
			maxBuffer: 256 * 1024 * 1024
		});
		files = [];
		let offset = 0;
		for (const entry of listing) {
			const headerEnd = blob.indexOf(0x0a, offset);
			const size = Number(blob.slice(offset, headerEnd).toString('utf8').split(' ')[2]);
			const start = headerEnd + 1;
			files.push({ rel: entry.rel, content: blob.slice(start, start + size).toString('utf8') });
			offset = start + size + 1;
		}
	}
	// FileRead(..., "UTF-8") drops the byte order mark.
	for (const file of files) file.content = file.content.replace(/^﻿/, '');
	return files.sort((a, b) => {
		const x = a.rel.toLowerCase();
		const y = b.rel.toLowerCase();
		return x < y ? -1 : x > y ? 1 : 0;
	});
}

// ============================================
// ============================================
// ======= 2/ Ports of the AHK helpers ========
// ============================================
// ============================================

/** _StripFullLineComments: StrSplit on "`n" trimming "`r", every piece kept. */
function stripFullLineComments(src) {
	let out = '';
	for (const piece of src.split('\n')) {
		const line = piece.replace(/^\r+|\r+$/g, '');
		if (!/^\s*;/.test(line)) out += line + '\n';
	}
	return out;
}

/** Spaces for every character of `text` but its line breaks. */
function blankNonNewlines(text) {
	return text.replace(/[^\r\n]/g, ' ');
}

/** _DriverMaskNonCode: blanks strings, `;` comments and block comments. */
function maskNonCode(src, blockCommentsOnly = false) {
	if (blockCommentsOnly && !src.includes('/*')) return src;
	const token = /'(?:`[\s\S]|[^'`])*'|"(?:`[\s\S]|[^"`])*"|;[^\r\n]*|^[ \t]*\/\*/gm;
	const closing = /(?:^[ \t]*\*\/|\*\/[ \t]*\r?$)/gm;
	let position = 0;
	let copied = 0;
	let out = '';
	for (;;) {
		token.lastIndex = position;
		const match = token.exec(src);
		if (!match) break;
		position = match.index + match[0].length;
		if (match[0].replace(/^[ \t]+/, '') === '/*') {
			closing.lastIndex = position;
			const end = closing.exec(src);
			position = end ? end.index + end[0].length : src.length;
		} else if (blockCommentsOnly) {
			continue;
		}
		out += src.slice(copied, match.index) + blankNonNewlines(src.slice(match.index, position));
		copied = position;
	}
	return copied === 0 ? src : out + src.slice(copied);
}

/** _DriverFindFunctionDefinition over a code mask: { idx, openPos } or null. */
function findDefinition(code, name, searchFrom) {
	const pattern = new RegExp(`^[ \\t]*${name}\\(`, 'gim');
	let from = searchFrom;
	for (;;) {
		pattern.lastIndex = from;
		const match = pattern.exec(code);
		if (!match) return null;
		const open = code.indexOf('(', match.index);
		let depth = 0;
		let quote = '';
		let cursor = open;
		while (cursor < code.length) {
			const ch = code[cursor];
			if (quote) {
				if (ch === '`') {
					cursor += 2;
					continue;
				}
				if (ch === quote) quote = '';
			} else if (ch === '"' || ch === "'") {
				quote = ch;
			} else if (ch === ';') {
				const lineEnd = code.indexOf('\n', cursor);
				cursor = lineEnd >= 0 ? lineEnd : code.length;
				continue;
			} else if (ch === '(') {
				depth += 1;
			} else if (ch === ')') {
				depth -= 1;
				if (depth === 0) break;
			}
			cursor += 1;
		}
		if (depth === 0) {
			let openPos = cursor + 1;
			while (openPos < code.length && ' \t\r\n'.includes(code[openPos])) openPos += 1;
			if (code[openPos] === '{') return { idx: match.index, openPos };
		}
		from = match.index + Math.max(1, match[0].length);
	}
}

/** _DriverExtractDefinedBody: signature through the matching brace, stripped. */
function extractBody(src, definition) {
	if (!definition) return '';
	let depth = 0;
	let i = definition.openPos;
	let end = src.length - 1;
	let quote = '';
	while (i < src.length) {
		const ch = src[i];
		if (quote) {
			if (ch === '`') {
				i += 2;
				continue;
			}
			if (ch === quote) quote = '';
		} else if (ch === '"' || ch === "'") {
			quote = ch;
		} else if (ch === ';') {
			const lineEnd = src.indexOf('\n', i);
			i = lineEnd >= 0 ? lineEnd : src.length;
			continue;
		} else if (ch === '{') {
			depth += 1;
		} else if (ch === '}') {
			depth -= 1;
			if (depth <= 0) {
				end = i;
				break;
			}
		}
		i += 1;
	}
	return stripFullLineComments(src.slice(definition.idx, end + 1));
}

/** One source image with the function-body lookup _DriverFuncBody performs. */
class SourceImage {
	constructor(text) {
		this.source = maskNonCode(text, true);
		this.code = maskNonCode(this.source);
		this.offsets = new Map();
		const head = /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)\(/gm;
		for (const match of this.code.matchAll(head)) {
			const key = match[1].toLowerCase();
			if (!this.offsets.has(key)) this.offsets.set(key, match.index);
		}
		this.bodies = new Map();
	}

	body(name) {
		const key = name.toLowerCase();
		if (this.bodies.has(key)) return this.bodies.get(key);
		const start = this.offsets.get(key);
		const found =
			start === undefined ? '' : extractBody(this.source, findDefinition(this.code, name, start));
		this.bodies.set(key, found);
		return found;
	}
}

/** The helpers' view of the Windows tree. */
class DriverModel {
	constructor(files) {
		this.files = files;
		this.concat = files
			.filter((file) => !/(^|\/)(tests|vendor|_generated)\//.test(file.rel))
			.map((file) => '\n' + file.content)
			.join('');
		this.noComments = stripFullLineComments(this.concat);
		this.image = new SourceImage(this.concat);
	}

	funcBody(name, orEmpty) {
		const body = this.image.body(name);
		if (body === '' && !orEmpty)
			throw new Unsupported(`_DriverFuncBody("${name}") finds no definition`);
		return body;
	}

	dirConcat(relDir) {
		const prefix = relDir.replace(/\\/g, '/').replace(/\/+$/, '') + '/';
		const text = this.files
			.filter((file) => file.rel.toLowerCase().startsWith(prefix.toLowerCase()))
			.map((file) => '\n' + file.content)
			.join('');
		if (!text) throw new Unsupported(`_DriverDirConcat("${relDir}") reads nothing`);
		return text;
	}
}

// ============================================
// ============================================
// ======= 3/ AHK expressions =================
// ============================================
// ============================================

/** Raised for anything this mirror does not evaluate: the assertion is left to AHK. */
class Unsupported extends Error {}

/** Decodes one AHK string literal (both quote styles, backtick escapes). */
function decodeString(literal) {
	const body = literal.slice(1, -1);
	const escapes = {
		n: '\n',
		t: '\t',
		r: '\r',
		'`': '`',
		'"': '"',
		"'": "'",
		';': ';',
		':': ':',
		'{': '{'
	};
	return body.replace(/`([\s\S])/g, (_, ch) => (ch in escapes ? escapes[ch] : ch));
}

/** Splits an expression into tokens: strings, names, numbers, punctuation. */
function tokenize(text) {
	const tokens = [];
	const pattern =
		/\s+|"(?:`[\s\S]|[^"`])*"|'(?:`[\s\S]|[^'`])*'|[A-Za-z_][A-Za-z0-9_.]*(?=\()|[A-Za-z_][A-Za-z0-9_]*|\d+|&[A-Za-z_][A-Za-z0-9_]*|[().,-]/y;
	let index = 0;
	while (index < text.length) {
		pattern.lastIndex = index;
		const match = pattern.exec(text);
		if (!match) throw new Unsupported(`cannot read "${text.slice(index, index + 20)}"`);
		index = pattern.lastIndex;
		if (/^\s+$/.test(match[0])) continue;
		tokens.push(match[0]);
	}
	return tokens;
}

/** Splits a call's argument text at top-level commas. */
function splitArguments(text) {
	const args = [];
	let depth = 0;
	let quote = '';
	let current = '';
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		if (quote) {
			current += ch;
			if (ch === '`') {
				current += text[i + 1] || '';
				i += 1;
			} else if (ch === quote) quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") quote = ch;
		else if (ch === '(' || ch === '[' || ch === '{') depth += 1;
		else if (ch === ')' || ch === ']' || ch === '}') depth -= 1;
		else if (ch === ',' && depth === 0) {
			args.push(current.trim());
			current = '';
			continue;
		}
		current += ch;
	}
	if (current.trim() !== '') args.push(current.trim());
	return args;
}

/** Index just past the parenthesis closing the one at `open`, quotes skipped. */
function closeParen(text, open) {
	let depth = 0;
	let quote = '';
	for (let i = open; i < text.length; i++) {
		const ch = text[i];
		if (quote) {
			if (ch === '`') i += 1;
			else if (ch === quote) quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") quote = ch;
		else if (ch === ';' && /\s/.test(text[i - 1] || ' ')) {
			const lineEnd = text.indexOf('\n', i);
			i = lineEnd >= 0 ? lineEnd : text.length;
		} else if (ch === '(') depth += 1;
		else if (ch === ')') {
			depth -= 1;
			if (depth === 0) return i + 1;
		}
	}
	return -1;
}

/**
 * Evaluates an expression: string literals, `.` concatenation, variables
 * resolved in `scope`, the source helpers, and numeric `- n` on a count.
 */
function evaluate(text, context) {
	const tokens = tokenize(text);
	let index = 0;
	const term = () => {
		const token = tokens[index];
		if (token === undefined) throw new Unsupported(`expression ends early: ${text}`);
		if (token.startsWith('"') || token.startsWith("'")) {
			index += 1;
			return decodeString(token);
		}
		if (/^\d+$/.test(token)) {
			index += 1;
			return Number(token);
		}
		if (token === '(') {
			index += 1;
			const value = sum();
			if (tokens[index] !== ')') throw new Unsupported(`unbalanced ( in ${text}`);
			index += 1;
			return value;
		}
		if (/^[A-Za-z_]/.test(token) && tokens[index + 1] === '(') {
			const name = token;
			index += 2;
			const args = [];
			while (tokens[index] !== ')') {
				if (tokens[index] === undefined) throw new Unsupported(`unclosed call in ${text}`);
				if (tokens[index] === ',') {
					index += 1;
					continue;
				}
				if (tokens[index].startsWith('&')) {
					args.push({ ref: tokens[index].slice(1) });
					index += 1;
					continue;
				}
				args.push(sum());
			}
			index += 1;
			return call(name, args, context);
		}
		if (/^[A-Za-z_]/.test(token)) {
			index += 1;
			return context.variable(token);
		}
		throw new Unsupported(`unexpected ${token} in ${text}`);
	};
	const concat = () => {
		let value = term();
		while (tokens[index] === '.') {
			index += 1;
			const right = term();
			if (typeof value !== 'string' || typeof right !== 'string') {
				throw new Unsupported(`non-string concatenation in ${text}`);
			}
			value += right;
		}
		return value;
	};
	const sum = () => {
		let value = concat();
		while (tokens[index] === '-') {
			index += 1;
			const right = concat();
			if (typeof value !== 'number' || typeof right !== 'number') {
				throw new Unsupported(`non-numeric subtraction in ${text}`);
			}
			value -= right;
		}
		return value;
	};
	const value = sum();
	if (index !== tokens.length) throw new Unsupported(`trailing tokens in ${text}`);
	return value;
}

/** Counts non-overlapping occurrences, as InStr and StrReplace loops do. */
function countOccurrences(haystack, needle, caseSensitive) {
	if (needle === '') return 0;
	const hay = caseSensitive ? haystack : haystack.toLowerCase();
	const pin = caseSensitive ? needle : needle.toLowerCase();
	let count = 0;
	let position = hay.indexOf(pin);
	while (position >= 0) {
		count += 1;
		position = hay.indexOf(pin, position + pin.length);
	}
	return count;
}

/** Translates an AHK regular expression with an options prefix. */
function ahkRegex(pattern, extraFlags = '') {
	let flags = extraFlags;
	let source = pattern;
	const options = /^([imsxU`]*)\)/.exec(pattern);
	if (options && /^[ims]*$/.test(options[1])) {
		flags += options[1];
		source = pattern.slice(options[0].length);
	} else if (options) {
		throw new Unsupported(`regex options ${options[1]}`);
	}
	if (/\(\?[<!=]?[imsx]|\\[QEKGAZz]|\(\*|\(\?\||\\p\{|\(\?>|[*+?]\+/.test(source)) {
		throw new Unsupported(`PCRE-only construct in ${pattern}`);
	}
	return new RegExp(source, [...new Set(flags + 'g')].join(''));
}

/** The source helpers the framework provides, and the test file's own ones. */
function call(name, args, context) {
	const model = context.model;
	const str = (value) => {
		if (typeof value !== 'string') throw new Unsupported(`${name} expects a string`);
		return value;
	};
	switch (name) {
		case '_DriverFuncBody':
			return model.funcBody(str(args[0]), false);
		case '_DriverFuncBodyOrEmpty':
			return model.funcBody(str(args[0]), true);
		case '_StripFullLineComments':
			return stripFullLineComments(str(args[0]));
		case '_DriverSourceConcat':
			return model.concat;
		case '_DriverSourceNoComments':
			return model.noComments;
		case '_DriverDirConcat':
			return model.dirConcat(str(args[0]));
		case 'StrLen':
			return str(args[0]).length;
		default:
			break;
	}
	const helper = context.helpers.get(name);
	if (!helper) throw new Unsupported(`unknown function ${name}`);
	return helper(args, context);
}

// ============================================
// ============================================
// ======= 4/ The meta test files =============
// ============================================
// ============================================

/**
 * One line of code with whitespace outside string literals collapsed, spaces
 * trimmed inside parentheses and around commas.
 */
function normalizeCode(code) {
	let out = '';
	let quote = '';
	for (let i = 0; i < code.length; i++) {
		const ch = code[i];
		if (quote) {
			out += ch;
			if (ch === '`') {
				out += code[i + 1] || '';
				i += 1;
			} else if (ch === quote) quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") {
			quote = ch;
			out += ch;
		} else if (/\s/.test(ch)) {
			if (!out.endsWith(' ')) out += ' ';
		} else out += ch;
	}
	// Only outside strings: re-scan and tidy the separators.
	let tidy = '';
	quote = '';
	for (let i = 0; i < out.length; i++) {
		const ch = out[i];
		if (quote) {
			tidy += ch;
			if (ch === '`') {
				tidy += out[i + 1] || '';
				i += 1;
			} else if (ch === quote) quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") quote = ch;
		if (ch === ' ' && (/[( ]$/.test(tidy) || out[i + 1] === ')' || out[i + 1] === ',')) continue;
		tidy += ch === ',' ? ', ' : ch;
	}
	return tidy.trim();
}

/**
 * Classifies a test file's own helper by its body, into an evaluator, or
 * returns null for any other shape.
 */
function classifyHelper(params, body) {
	const inner = body.slice(body.indexOf('{') + 1, body.lastIndexOf('}'));
	const lines = inner
		.split('\n')
		.map((line) =>
			dropTrailingComment(line)
				.trim()
				.replace(/^local\s+/i, '')
		)
		.filter((line) => line !== '');
	const code = normalizeCode(lines.join('\n'));
	const [hay, needle] = params;
	if (!hay || !needle) return null;
	const q = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const H = q(hay);
	const N = q(needle);
	const bump = '(?: \\+= 1|\\+\\+)';
	// An InStr loop: `while (Pos := InStr(H, N, true, Pos)) { Count += 1  Pos += StrLen(N) }`,
	// or `Found := InStr(..., Position)` then `Position := Found + StrLen(N)`.
	const inStr = new RegExp(
		`^(?:if \\(?${N} == ""\\)? return 0 )?(\\w+) := 0 (\\w+) := 1 while \\(?(\\w+) := InStr\\(${H}, ${N}(?:, (true|false|1|0|"On"|"Off")?)?, \\2\\)\\)? \\{ \\1${bump} (?:\\2 \\+= StrLen\\(${N}\\)|\\2 := \\3 \\+ StrLen\\(${N}\\)) \\} return \\1$`,
		'i'
	).exec(code);
	if (inStr) {
		const caseSensitive = /^(true|1|"On")$/i.test(inStr[4] || '');
		return (args) => {
			if (typeof args[0] !== 'string' || typeof args[1] !== 'string')
				throw new Unsupported('count helper args');
			return countOccurrences(args[0], args[1], caseSensitive);
		};
	}
	// return (StrLen(H) - StrLen(StrReplace(H, N))) // StrLen(N)
	if (
		new RegExp(
			`^return \\(StrLen\\(${H}\\) - StrLen\\(StrReplace\\(${H}, ${N}\\)\\)\\) // StrLen\\(${N}\\)$`,
			'i'
		).test(code)
	) {
		return (args) => {
			if (typeof args[0] !== 'string' || typeof args[1] !== 'string')
				throw new Unsupported('count helper args');
			return countOccurrences(args[0], args[1], false);
		};
	}
	// A RegExMatch loop whose pattern is the needle or an expression of it.
	const regexLoop = new RegExp(
		`^(\\w+) := 0 (\\w+) := 1 (?:\\w+ := 0 )?while \\(?(?:(\\w+) := )?RegExMatch\\(${H}, (.+?), &(\\w+), \\2\\)\\)? \\{ \\1${bump} \\2 := (?:\\3|\\5\\.Pos) \\+ \\5\\.Len \\} return \\1$`,
		'i'
	).exec(code);
	if (regexLoop) {
		const patternExpr = regexLoop[4];
		return (args, context) => {
			if (typeof args[0] !== 'string' || typeof args[1] !== 'string')
				throw new Unsupported('count helper args');
			const pattern = evaluate(patternExpr, {
				...context,
				variable: (name) => {
					if (name.toLowerCase() === needle.toLowerCase()) return args[1];
					throw new Unsupported(`helper pattern names ${name}`);
				}
			});
			return (args[0].match(ahkRegex(String(pattern))) || []).length;
		};
	}
	// RegExReplace(Body, Function . "<suffix>", "", &Count) then a literal-key
	// list built from RegExMatch(Body, Function . '<suffix>', &Match, Position).
	const counter = params[2];
	if (counter) {
		const literal = '("(?:[^"`]|`.)*"|\'(?:[^\'`]|`.)*\')';
		const listed = new RegExp(
			`^RegExReplace\\(${H}, ${N} \\. ${literal}, "", &${q(counter)}\\) (\\w+) := "" (\\w+) := 1 while \\(\\3 := RegExMatch\\(${H}, ${N} \\. ${literal}, &(\\w+), \\3\\)\\) \\{ \\2 \\.= \\5\\[1\\] \\. "\`n" \\3 \\+= \\5\\.Len \\} return \\2$`
		).exec(code);
		if (listed) {
			const countSuffix = decodeString(listed[1]);
			const keySuffix = decodeString(listed[4]);
			return (args, context) => {
				const [source, prefix, ref] = args;
				if (typeof source !== 'string' || typeof prefix !== 'string' || !ref || !ref.ref) {
					throw new Unsupported('literal-key helper args');
				}
				context.assign(ref.ref, (source.match(ahkRegex(prefix + countSuffix)) || []).length);
				let keys = '';
				for (const match of source.matchAll(ahkRegex(prefix + keySuffix))) keys += match[1] + '\n';
				return keys;
			};
		}
	}
	return null;
}

/** The statements of a function body, one per logical line (continuations joined). */
function statements(body) {
	const raw = body.split('\n');
	const out = [];
	for (let i = 0; i < raw.length; i++) {
		let line = raw[i].replace(/\r$/, '');
		const startLine = i;
		// A statement continues while its parentheses are open or the next line
		// starts with a continuation operator.
		const open = (text) => {
			let depth = 0;
			let quote = '';
			for (let k = 0; k < text.length; k++) {
				const ch = text[k];
				if (quote) {
					if (ch === '`') k += 1;
					else if (ch === quote) quote = '';
					continue;
				}
				if (ch === '"' || ch === "'") quote = ch;
				else if (ch === ';' && /\s/.test(text[k - 1] || ' ')) break;
				else if (ch === '(' || ch === '[') depth += 1;
				else if (ch === ')' || ch === ']') depth -= 1;
			}
			return depth;
		};
		while (
			i + 1 < raw.length &&
			(open(line) > 0 || /^\s*(\.(?!\w)|&&|\|\||\?|:(?!=)|,)/.test(raw[i + 1]))
		) {
			i += 1;
			line += '\n' + raw[i].replace(/\r$/, '');
		}
		out.push({ text: line, line: startLine });
	}
	return out;
}

/** Removes a trailing `; comment` outside strings. */
function dropTrailingComment(text) {
	let quote = '';
	for (let k = 0; k < text.length; k++) {
		const ch = text[k];
		if (quote) {
			if (ch === '`') k += 1;
			else if (ch === quote) quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") quote = ch;
		else if (ch === ';' && /\s/.test(text[k - 1] || ' ')) return text.slice(0, k);
	}
	return text;
}

/**
 * How many times each variable of a function body is written, by any form
 * (lowercased: AHK names are case-insensitive). A value written more than once
 * depends on control flow this mirror does not replay.
 */
function writeCounts(code) {
	const counts = new Map();
	const bump = (name) => {
		const key = name.toLowerCase();
		counts.set(key, (counts.get(key) || 0) + 1);
	};
	for (const m of code.matchAll(/\b([A-Za-z_]\w*)\s*(?::=|\+=|-=|\.=|\*=|\/\/=|\/=)/g)) bump(m[1]);
	for (const m of code.matchAll(/\b([A-Za-z_]\w*)\s*(?:\+\+|--)/g)) bump(m[1]);
	for (const m of code.matchAll(/(?:\+\+|--)\s*([A-Za-z_]\w*)/g)) bump(m[1]);
	for (const m of code.matchAll(/&([A-Za-z_]\w*)/g)) bump(m[1]);
	for (const m of code.matchAll(/\bfor\s+([A-Za-z_]\w*)(?:\s*,\s*([A-Za-z_]\w*))?\s+in\b/gi)) {
		bump(m[1]);
		if (m[2]) bump(m[2]);
	}
	return counts;
}

/** AHK's loose equality for the values a census compares. */
function ahkEqual(a, b) {
	const numeric = (v) =>
		typeof v === 'number' ||
		(typeof v === 'string' && /^\s*[-+]?(?:0x[0-9a-f]+|\d+(?:\.\d+)?)\s*$/i.test(v));
	if (numeric(a) && numeric(b)) return Number(a) === Number(b);
	return String(a) === String(b);
}

/**
 * Evaluates every top-level AssertEqual of one meta test file whose actual
 * value is computed from the driver source.
 * @returns {{ mirrored: object[], skipped: object[] }}
 */
function evaluateFile(rel, content, model) {
	const image = new SourceImage(content);
	const helpers = new Map();
	const functions = [];
	for (const match of image.code.matchAll(/^([A-Za-z_][A-Za-z0-9_]*)\(([^()\n]*)\)\s*\{/gm)) {
		const name = match[1];
		const params = match[2]
			.split(',')
			.map((p) =>
				p
					.trim()
					.replace(/^&/, '')
					.replace(/\s*:=.*$/, '')
			)
			.filter(Boolean);
		const body = image.body(name);
		if (!body) continue;
		const lineOffset = content.slice(0, match.index).split('\n').length;
		functions.push({ name, body, lineOffset });
		const helper = classifyHelper(params, body);
		if (helper) helpers.set(name, helper);
	}
	const mirrored = [];
	const skipped = [];
	for (const fn of functions) {
		const code = maskNonCode(fn.body);
		const writes = writeCounts(code);
		const scope = new Map();
		// Variables whose value was computed from the driver source.
		const derived = new Set();
		let touched = 0;
		let statementStart = 0;
		const context = {
			model: new Proxy(model, {
				get(target, key) {
					touched += 1;
					const value = target[key];
					return typeof value === 'function' ? value.bind(target) : value;
				}
			}),
			helpers,
			variable(name) {
				const key = name.toLowerCase();
				if (!scope.has(key)) throw new Unsupported(`variable ${name} is not a mirrored value`);
				const value = scope.get(key);
				if (value instanceof Unsupported) throw value;
				if (derived.has(key)) touched += 1;
				return value;
			},
			assign(name, value) {
				const key = name.toLowerCase();
				// A by-reference output is a second write only when written elsewhere too.
				scope.set(
					key,
					(writes.get(key) || 0) > 1 ? new Unsupported(`${name} is written more than once`) : value
				);
				if (touched > statementStart) derived.add(key);
			}
		};
		// Brace depth at each statement start, from the code mask (same offsets).
		let offset = 0;
		let depth = 0;
		let previous = '';
		for (const statement of statements(fn.body)) {
			const statementCode = code.slice(offset, offset + statement.text.length);
			const startDepth = depth;
			for (const ch of statementCode) {
				if (ch === '{') depth += 1;
				else if (ch === '}') depth -= 1;
			}
			offset += statement.text.length + 1;
			const text = dropTrailingComment(statement.text).trim();
			const line = fn.lineOffset + statement.line;
			statementStart = touched;
			// Top level of the function: depth 1, not the body of a braceless if/loop.
			const guarded =
				/^(?:\}\s*)?(?:if|else|while|for|loop|try|catch|finally)\b/i.test(previous) &&
				!/\{\s*$/.test(previous);
			const topLevel = startDepth === 1 && !guarded;
			if (text !== '') previous = dropTrailingComment(statementCode).trim();
			let match = /^([A-Za-z_]\w*)\s*:=\s*([\s\S]+)$/.exec(text);
			if (match && !/^(if|while|for|return|loop)\b/i.test(text)) {
				const key = match[1].toLowerCase();
				if (!topLevel || (writes.get(key) || 0) > 1) {
					scope.set(
						key,
						new Unsupported(`${match[1]} is written under control flow or more than once`)
					);
					continue;
				}
				try {
					scope.set(key, evaluate(match[2], context));
					if (touched > statementStart) derived.add(key);
				} catch (err) {
					if (!(err instanceof Unsupported)) throw err;
					scope.set(key, err);
				}
				continue;
			}
			match = /^RegExReplace\(([\s\S]+)\)$/.exec(text);
			if (match && topLevel) {
				const args = splitArguments(match[1]);
				const ref = args[3] && /^&(\w+)$/.exec(args[3]);
				if (ref && args[2] === '""' && args.length === 4) {
					try {
						const source = evaluate(args[0], context);
						const pattern = evaluate(args[1], context);
						context.assign(ref[1], (String(source).match(ahkRegex(String(pattern))) || []).length);
					} catch (err) {
						if (!(err instanceof Unsupported)) throw err;
						scope.set(ref[1].toLowerCase(), err);
					}
				}
				continue;
			}
			if (!text.startsWith('AssertEqual(') || !topLevel) continue;
			const end = closeParen(text, 'AssertEqual'.length);
			const args = splitArguments(text.slice('AssertEqual('.length, end - 1));
			const record = { rel, line, text: text.split('\n')[0].trim(), actualExpr: args[1] };
			try {
				if (args.length < 2) throw new Unsupported('AssertEqual needs two arguments');
				const literal = {
					...context,
					variable: () => {
						throw new Unsupported('expected is not a literal');
					}
				};
				const expected = evaluate(args[0], literal);
				const before = touched;
				const actual = evaluate(args[1], context);
				const fromSource = touched > before;
				if (!fromSource)
					throw new Unsupported('the actual value is not computed from the driver source');
				mirrored.push({ ...record, expected, actual, equal: ahkEqual(expected, actual) });
			} catch (err) {
				if (!(err instanceof Unsupported)) throw err;
				skipped.push({ ...record, why: err.message });
			}
		}
	}
	return { mirrored, skipped };
}

// ============================================
// ============================================
// ======= 5/ Main ============================
// ============================================
// ============================================

/** A fixture meta test with a wrong census must be reported. */
function selfCheck(model) {
	const fixture = [
		'_FX_Count(Haystack, Needle) {',
		'\tCount := 0',
		'\tPos := 1',
		'\twhile (Pos := InStr(Haystack, Needle, true, Pos)) {',
		'\t\tCount += 1',
		'\t\tPos += StrLen(Needle)',
		'\t}',
		'\treturn Count',
		'}',
		'_FX_Census() {',
		'\tBody := _StripFullLineComments(_DriverFuncBody("_Onboarding_Commit"))',
		'\t\t. _StripFullLineComments(',
		'\t\t\t_DriverFuncBody("_Onboarding_RollbackRefusedReload"))',
		'\tAssertEqual(999, _FX_Count(Body, "_Onboarding_ShowError("),',
		'\t\t"a census no production change can reach")',
		'\tRegExReplace(Body, "_Onboarding_CommitError\\(", "", &Calls)',
		'\tAssertEqual(999, Calls, "a second census no production change can reach")',
		'}'
	].join('\n');
	const { mirrored } = evaluateFile('fixture.ahk', fixture, model);
	const wrong = mirrored.filter((entry) => !entry.equal);
	if (mirrored.length !== 2 || wrong.length !== 2 || !wrong.every((entry) => entry.actual > 0)) {
		throw new Error(
			`self-check: the fixture census was not evaluated as wrong: ${JSON.stringify(mirrored)}`
		);
	}
}

function main() {
	const files = windowsFiles();
	const model = new DriverModel(files);
	selfCheck(model);
	const metaFiles = files.filter((file) => /^tests\/meta\/test_[^/]+\.ahk$/.test(file.rel));
	const mirrored = [];
	const skipped = [];
	const fileCount = new Set();
	for (const file of metaFiles) {
		const result = evaluateFile(file.rel, file.content, model);
		for (const entry of result.mirrored) fileCount.add(entry.rel);
		mirrored.push(...result.mirrored);
		skipped.push(...result.skipped);
	}
	const failures = [];
	for (const entry of mirrored) {
		if (!entry.equal) {
			failures.push(
				`${WINDOWS_REL}/${entry.rel}:${entry.line}: ${entry.text}\n` +
					`    expected ${JSON.stringify(entry.expected)}, the driver source gives ${JSON.stringify(entry.actual)}`
			);
		}
	}
	for (const need of REQUIRED) {
		if (!mirrored.some((entry) => entry.rel === need.file && entry.actualExpr === need.actual)) {
			failures.push(`${need.file}: the assertion on ${need.actual} is no longer mirrored`);
		}
	}
	if (mirrored.length < MIN_MIRRORED || fileCount.size < MIN_FILES) {
		failures.push(
			`only ${mirrored.length} assertion(s) in ${fileCount.size} file(s) mirrored ` +
				`(floors ${MIN_MIRRORED} and ${MIN_FILES}): the evaluator stopped understanding the meta tests`
		);
	}
	if (VERBOSE) {
		for (const entry of skipped)
			console.log(`  not mirrored ${entry.rel}:${entry.line} (${entry.why})`);
	}
	if (failures.length > 0) {
		console.error('[hardening-f-ahk-meta-counts] Windows meta test census out of date:');
		for (const failure of failures) console.error(`  ${failure}`);
		console.error(
			'  The Windows lane will fail on the same assertion: update the census in the AHK meta test ' +
				'after auditing the added or removed call site.'
		);
		process.exit(1);
	}
	console.log(
		`[hardening-f-ahk-meta-counts] ${mirrored.length} census assertion(s) of ${fileCount.size} Windows meta test ` +
			`file(s) match the driver source (${skipped.length} left to the Windows lane).`
	);
}

main();
