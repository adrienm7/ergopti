// tools/lib/logger-lifecycle-pairing.cjs

/**
 * ==============================================================================
 * MODULE: Logger Lifecycle Pairing Census
 * DESCRIPTION:
 * Counts the lifecycle log calls of every production source file, per driver,
 * and applies the rule the Windows suite has always held
 * (windows/tests/meta/core/logger/test_pairing.ahk): a file that opens a START
 * must hold a SUCCESS, and a file must not hold more TRACE operations than DONE
 * terminals. A START with no SUCCESS is the log's only signal of a silent
 * failure, so a missing terminal is a missing diagnosis.
 *
 * FEATURES & RATIONALE:
 * 1. One rule, three drivers: AHK spells the calls LoggerStart(...), Lua spells
 *    them Logger.start(...) on a receiver named Logger, logger or log (the
 *    shared engines receive the logger as a port). The same counts apply.
 * 2. Lexical, not textual: comments and string literals are tokenized away by
 *    tools/lib/script-source.cjs, so a quoted "Logger.success(" or a commented
 *    call can never balance a real START.
 * 3. Definitions are not calls: the logger's own `LoggerStart(...) {` and
 *    `function Logger.start(` declare the API and are not counted.
 * 4. Per-file, as on Windows: a pair that closes in another file is invisible
 *    to the count, so such files are exempt by name with their justification,
 *    and every exemption must still exist.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { scriptTokens } = require('./script-source.cjs');

/** Path segments that hold no hand-written production source. */
const NON_PRODUCTION = new Set(['tests', 'vendor', 'build', '_generated', 'node_modules']);

/** The four lifecycle variants, keyed by their Lua method name. */
const VARIANTS = ['start', 'success', 'trace', 'done'];

/** AHK function name of each lifecycle variant. */
const AHK_NAMES = new Map(VARIANTS.map((v) => [`logger${v}`, v]));

/** Lua receivers that hold the logger (the module, a port field, a local alias). */
const LUA_RECEIVER = /^(?:logger|log)$/i;

/** Lua functions that call their first argument with the rest. */
const PROTECTED_CALLERS = new Set(['pcall', 'xpcall']);

/**
 * Files whose START legitimately closes in another file, asynchronously. Each
 * entry exempts the START/SUCCESS pair only (TRACE/DONE stays counted) and is
 * a place the census stops looking, so each one carries its justification.
 */
const EXEMPT = new Map([
	[
		'windows/gestures/engine/actions.ahk',
		'opens "Capturing screen to…" and GestureScreenshotComplete closes it in ' +
			'gestures/adapters/screenshots.ahk once the PowerShell worker has finished'
	],
	[
		'macos/ai/engine/prediction/engine.lua',
		'opens "LLM request — request=…" before the backend call; the callbacks of ' +
			'StreamingHandler.build_callbacks close it in ai/engine/api/streaming_handler.lua ' +
			'("%d prediction(s) received" or a failure warning) when the response arrives'
	]
]);

/**
 * Index of the token after the parenthesis that closes the one at `open`.
 * @param {Array<{kind: string, value: string}>} tokens Code tokens.
 * @param {number} open Index of an opening parenthesis.
 * @returns {number} Index after the matching close, or tokens.length.
 */
function afterClose(tokens, open) {
	let depth = 0;
	for (let i = open; i < tokens.length; i += 1) {
		if (tokens[i].kind !== 'symbol') continue;
		if (tokens[i].value === '(') depth += 1;
		else if (tokens[i].value === ')') {
			depth -= 1;
			if (depth === 0) return i + 1;
		}
	}
	return tokens.length;
}

/** True when no code token precedes `index` on its line. */
function startsLine(source, tokens, index) {
	if (index === 0) return true;
	return source.slice(tokens[index - 1].end, tokens[index].start).includes('\n');
}

/**
 * Counts the lifecycle calls of one source.
 * @param {string} source File content.
 * @param {string} extension '.ahk' or '.lua'.
 * @returns {{start: number, success: number, trace: number, done: number}}
 */
function lifecycleCounts(source, extension) {
	const text = source.replace(/^﻿/, '');
	const tokens = scriptTokens(text, extension);
	const counts = { start: 0, success: 0, trace: 0, done: 0 };
	for (let i = 0; i < tokens.length; i += 1) {
		const token = tokens[i];
		if (token.kind !== 'identifier') continue;
		const next = tokens[i + 1];
		if (!next || next.kind !== 'symbol') continue;
		const called = next.value === '(';
		if (extension === '.ahk') {
			if (!called) continue;
			// AHK function names are case-insensitive.
			const variant = AHK_NAMES.get(token.value.toLowerCase());
			if (!variant) continue;
			const previous = tokens[i - 1];
			if (previous && previous.kind === 'symbol' && previous.value === '.') continue;
			const after = tokens[afterClose(tokens, i + 1)];
			const isDefinition =
				startsLine(text, tokens, i) && after && after.kind === 'symbol' && after.value === '{';
			if (!isDefinition) counts[variant] += 1;
			continue;
		}
		if (!VARIANTS.includes(token.value)) continue;
		const separator = tokens[i - 1];
		const receiver = tokens[i - 2];
		if (!separator || separator.kind !== 'symbol' || !['.', ':'].includes(separator.value))
			continue;
		if (!receiver || receiver.kind !== 'identifier' || !LUA_RECEIVER.test(receiver.value)) continue;
		// `function Logger.start(` declares the API; walk back over the dotted name.
		let head = i - 2;
		while (
			head >= 2 &&
			tokens[head - 1].kind === 'symbol' &&
			tokens[head - 1].value === '.' &&
			tokens[head - 2].kind === 'identifier'
		)
			head -= 2;
		const before = tokens[head - 1];
		if (called) {
			if (before && before.kind === 'identifier' && before.value === 'function') continue;
			counts[token.value] += 1;
			continue;
		}
		// `pcall(Logger.done, LOG, …)` calls it too, behind a protected boundary.
		const protector = tokens[head - 2];
		if (
			next.value === ',' &&
			before &&
			before.kind === 'symbol' &&
			before.value === '(' &&
			protector &&
			protector.kind === 'identifier' &&
			PROTECTED_CALLERS.has(protector.value)
		)
			counts[token.value] += 1;
	}
	return counts;
}

/**
 * The Windows rule applied to one file's counts.
 * @param {{start: number, success: number, trace: number, done: number}} counts
 * @returns {string[]} One message per broken pair; empty when balanced.
 */
function pairingViolations(counts) {
	const violations = [];
	if (counts.start > 0 && counts.success === 0)
		violations.push(`${counts.start} START but no SUCCESS`);
	if (counts.trace > counts.done) violations.push(`${counts.trace} TRACE but ${counts.done} DONE`);
	return violations;
}

/**
 * Every production source of one extension below a root.
 * @param {string} root Absolute directory.
 * @param {string} extension '.ahk' or '.lua'.
 * @returns {string[]} Forward-slash paths relative to root, sorted.
 */
function productionSources(root, extension) {
	if (!fs.statSync(root, { throwIfNoEntry: false })?.isDirectory())
		throw new Error(`The lifecycle census requires an existing directory: ${root}`);
	const found = [];
	const walk = (directory, relative) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const rel = relative ? `${relative}/${entry.name}` : entry.name;
			if (entry.isDirectory()) {
				if (!NON_PRODUCTION.has(entry.name)) walk(path.join(directory, entry.name), rel);
			} else if (entry.isFile() && entry.name.endsWith(extension)) found.push(rel);
		}
	};
	walk(root, '');
	if (found.length === 0)
		throw new Error(`The lifecycle census found no ${extension} file in ${root}`);
	return found.sort();
}

/**
 * Applies the pairing rule to one tree.
 * @param {string} root Absolute directory of the tree.
 * @param {string} extension '.ahk' or '.lua'.
 * @param {string} label Prefix of each relative path in reports and EXEMPT keys.
 * @param {Map<string, string>} [exempt] Exempt files, keyed by labelled path.
 * @returns {{files: number, producers: number, violations: string[], exemptUsed: string[]}}
 */
function censusTree(root, extension, label, exempt = EXEMPT) {
	const violations = [];
	const exemptUsed = [];
	let producers = 0;
	const files = productionSources(root, extension);
	for (const rel of files) {
		const key = `${label}/${rel}`;
		const counts = lifecycleCounts(fs.readFileSync(path.join(root, rel), 'utf8'), extension);
		if (exempt.has(key)) {
			exemptUsed.push(key);
			// The START closes elsewhere; the TRACE/DONE count still applies.
			counts.start = 0;
			counts.success = 0;
		}
		producers += counts.start + counts.trace;
		for (const message of pairingViolations(counts)) violations.push(`${key}: ${message}`);
	}
	return { files: files.length, producers, violations, exemptUsed };
}

module.exports = {
	EXEMPT,
	lifecycleCounts,
	pairingViolations,
	productionSources,
	censusTree
};
