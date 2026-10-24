// tools/lib/log-vocabulary-scan.cjs

/**
 * ==============================================================================
 * MODULE: Log Vocabulary Scanner
 * DESCRIPTION:
 * Finds, in driver source, the four kinds of closed log vocabulary the cross-OS
 * parity audit (K11) counted as hand-typed strings:
 *
 *   reason          `reason = "…"`, `reason: '…'`, `Map("reason", "…")`,
 *                   `x["reason"] := "…"`, and the comparisons `reason == "…"`
 *   phase           the same shapes with `phase`
 *   log_tag         a `[TAG]` prefix opening the message of a logger call, or
 *                   opening a shell `echo` the driver runs (its output is
 *                   appended to the same logs and routed by sub_files.toml)
 *   evidence_field  `name=` keys in the templates of evidence calls
 *                   (`Logger.evidence`, `LoggerEvidence`) and in the declared
 *                   evidence-record formatters
 *
 * One scanner serves the census (tools/audit/census-log-vocabulary.cjs) and
 * the closed-enum gate (test-logger-scalars-single-source.cjs), so the two
 * cannot disagree about what a literal is.
 *
 * A literal that is immediately concatenated (`reason = "http_" .. code`) or is
 * not code-shaped (`reason = "unknown error"`) is recorded as free-form: it
 * cannot be a member of a closed enum, and the gate holds those to a
 * shrinking baseline instead.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const SCANNED_EXTENSIONS = /\.(lua|ahk|js)$/;
// Tests spell vocabulary on purpose; vendored code is not ours.
const EXCLUDED = /(^|\/)(tests|test|vendor|node_modules)\//;
const COMMENT_LINE = /^\s*(--|;|\/\/|\*|\/\*)/;
const CODE_SHAPED = /^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/;
const TAG_PREFIX = /^\[([A-Z][A-Z0-9]*(?:[-_][A-Z0-9]+)*)\]/;
const ECHO_TAG = /\becho\s+\\?["']?\[([A-Z][A-Z0-9]*(?:[-_][A-Z0-9]+)*)\]/g;
const EVIDENCE_FIELD = /(?:^|[\s(,;:])([a-z][a-z0-9_]*)=/g;
const KINDS = ['reason', 'phase', 'log_tag', 'evidence_field'];

const LITERAL = String.raw`(?:"([^"\\\n]*)"|'([^'\\\n]*)')`;
// The token after a literal decides whether it is a whole value or a prefix:
// Lua `..`, AHK ` . ` and JS ` + ` all build a string from it at runtime.
const CONCAT_AFTER = /^\s*(\.\.|\.\s|\+(?!\+))/;

/** Assignment, field and comparison shapes for one vocabulary word. */
function slotPatterns(word) {
	const W = word;
	const Wc = word[0].toUpperCase() + word.slice(1);
	return [
		// Lua `reason = "x"`, JS `reason: 'x'`, AHK `Reason := "x"`.
		new RegExp(String.raw`\b(?:${W}|${Wc})\s*(?::=|:|=(?!=))\s*${LITERAL}`, 'g'),
		// Comparisons: Lua `==`/`~=`, JS `===`/`!==`.
		new RegExp(String.raw`\b${W}\s*(?:===?|~=|!==?)\s*${LITERAL}`, 'g'),
		// `x["reason"] := "x"`, `x["reason"] = "x"`, `x["reason"] == "x"`.
		new RegExp(String.raw`\[\s*["']${W}["']\s*\]\s*(?::=|==|=|~=)\s*${LITERAL}`, 'g'),
		// AutoHotkey `Map("reason", "x")` pairs.
		new RegExp(String.raw`["']${W}["']\s*,\s*${LITERAL}`, 'g')
	];
}

const SLOTS = { reason: slotPatterns('reason'), phase: slotPatterns('phase') };

const LOGGER_CALL =
	/\bLogger(?:\.(debug|info|warn|error|start|success|trace|done|evidence)\b|(Debug|Info|Warn|Error|Start|Success|Trace|Done|Evidence)\s*\()/g;

/**
 * The text of one call starting at `open` (the index of its `(`), with string
 * literals skipped so a `)` inside a message does not close it.
 */
function callSpan(text, open) {
	let depth = 0;
	for (let i = open; i < text.length && i < open + 4000; i++) {
		const c = text[i];
		if (c === '"' || c === "'") {
			const end = text.indexOf(c, i + 1);
			if (end === -1) return text.slice(open);
			i = end;
		} else if (c === '(') depth++;
		else if (c === ')' && --depth === 0) return text.slice(open, i + 1);
	}
	return text.slice(open, open + 4000);
}

/** Every literal of a span, in order. */
function literals(span) {
	return [...span.matchAll(new RegExp(LITERAL, 'g'))].map((m) => m[1] ?? m[2]);
}

/** Text with comment lines blanked, so offsets and line numbers survive. */
function withoutCommentLines(text) {
	return text
		.split('\n')
		.map((line) => (COMMENT_LINE.test(line) ? '' : line))
		.join('\n');
}

function lineOf(text, index) {
	let line = 1;
	for (let i = 0; i < index; i++) if (text.charCodeAt(i) === 10) line++;
	return line;
}

/**
 * Scans one source text.
 * @param {string} text File contents.
 * @returns {Array<{kind: string, value: string, line: number, free: boolean}>}
 */
function scanText(text) {
	const code = withoutCommentLines(text.replace(/^﻿/, ''));
	const hits = [];
	for (const kind of ['reason', 'phase']) {
		for (const pattern of SLOTS[kind]) {
			for (const m of code.matchAll(pattern)) {
				const value = m[1] ?? m[2];
				const after = code.slice(m.index + m[0].length, m.index + m[0].length + 4);
				// An empty value is the documented "no reason" sentinel, not prose.
				const free = (value !== '' && !CODE_SHAPED.test(value)) || CONCAT_AFTER.test(after);
				hits.push({ kind, value, line: lineOf(code, m.index), free });
			}
		}
	}
	for (const m of code.matchAll(LOGGER_CALL)) {
		const open = code.indexOf('(', m.index);
		if (open === -1) continue;
		const span = callSpan(code, open);
		const strings = literals(span);
		// The message is the first literal (Lua passes LOG as a variable) or the
		// second (AutoHotkey passes the module tag first).
		for (const s of strings.slice(0, 2)) {
			const tag = TAG_PREFIX.exec(s);
			if (tag) {
				hits.push({ kind: 'log_tag', value: tag[1], line: lineOf(code, m.index), free: false });
				break;
			}
		}
		if ((m[1] || m[2] || '').toLowerCase() === 'evidence') {
			for (const s of strings)
				for (const f of s.matchAll(EVIDENCE_FIELD))
					hits.push({
						kind: 'evidence_field',
						value: f[1],
						line: lineOf(code, m.index),
						free: false
					});
		}
	}
	for (const m of code.matchAll(ECHO_TAG))
		hits.push({ kind: 'log_tag', value: m[1], line: lineOf(code, m.index), free: false });
	return hits;
}

/**
 * The body of a named function, for the declared evidence-record formatters.
 * @returns {string|null}
 */
function functionBody(text, name) {
	const escaped = name.replace(/[.$]/g, (c) => '\\' + c);
	const start = new RegExp(
		String.raw`(?:^|\n)\s*(?:local\s+)?(?:function\s+${escaped}\s*\(|${escaped}\s*\([^)\n]*\)\s*\{)`
	).exec(text);
	if (!start) return null;
	const rest = text.slice(start.index + start[0].length);
	// Lua bodies end at the first line that is exactly `end`, AHK ones at `}`.
	const close = /\n(end|\})\s*(\n|$)/.exec(rest);
	return close ? rest.slice(0, close.index) : rest;
}

/**
 * Field names a declared formatter writes into its evidence record.
 * @param {string} text The formatter's file.
 * @param {string} name The formatter's function name.
 * @returns {string[]|null} null when the function is not found.
 */
function formatterFields(text, name) {
	const body = functionBody(withoutCommentLines(text.replace(/^﻿/, '')), name);
	if (body === null) return null;
	const fields = [];
	for (const s of literals(body)) for (const f of s.matchAll(EVIDENCE_FIELD)) fields.push(f[1]);
	return fields;
}

/** Tracked driver source files, relative to the repository root. */
function sourceFiles(root, generated) {
	return execFileSync('git', ['ls-files', '-z', 'static/ergopti_plus'], { cwd: root })
		.toString('utf8')
		.split('\0')
		.filter((f) => SCANNED_EXTENSIONS.test(f) && !EXCLUDED.test(f) && !generated.has(f))
		.sort();
}

/**
 * Scans the whole tree.
 * @param {string} root Repository root.
 * @param {{generated?: Set<string>, formatters?: Array<{file: string, function: string}>}} [options]
 * @returns {{hits: Array<{kind: string, value: string, file: string, line: number, free: boolean}>, missingFormatters: string[]}}
 */
function scanTree(root, options = {}) {
	const generated = options.generated || new Set();
	const hits = [];
	for (const file of sourceFiles(root, generated)) {
		const abs = path.join(root, file);
		if (!fs.existsSync(abs)) continue;
		for (const hit of scanText(fs.readFileSync(abs, 'utf8'))) hits.push({ ...hit, file });
	}
	const missingFormatters = [];
	for (const formatter of options.formatters || []) {
		const abs = path.join(root, formatter.file);
		const fields = fs.existsSync(abs)
			? formatterFields(fs.readFileSync(abs, 'utf8'), formatter.function)
			: null;
		if (fields === null || fields.length === 0) {
			missingFormatters.push(`${formatter.file}: ${formatter.function}`);
			continue;
		}
		for (const value of fields)
			hits.push({ kind: 'evidence_field', value, file: formatter.file, line: 0, free: false });
	}
	return { hits, missingFormatters };
}

module.exports = {
	KINDS,
	CODE_SHAPED,
	scanText,
	formatterFields,
	scanTree
};
