// tools/test/lib/i18n-dynamic-keys/context.cjs

/**
 * ==============================================================================
 * MODULE: Dynamic Key Family Context
 * DESCRIPTION:
 * The readers a dynamic key family uses to enumerate its ids from the data
 * the code reads: the repository's JSON and TOML files, a constant literal of
 * a source file, and the globals a set of classic page scripts defines. The
 * locale catalogues are refused: a family read from en.json would agree with
 * en.json by construction and could never fail.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { parse: parseToml } = require('smol-toml');
const { blankComments, REPO_ROOT } = require('../i18n-key-sites.cjs');

const LOCALES = path.join('static', 'ergopti_plus', '_shared', 'core', 'i18n', 'data', 'locales');
const cache = new Map();

/**
 * The absolute path of a repository file, refusing the locale catalogues.
 * @param {string} rel - Repository-relative path.
 * @returns {string}
 */
function resolve(rel) {
	const full = path.resolve(REPO_ROOT, rel);
	if (path.relative(path.join(REPO_ROOT, LOCALES), full).split(path.sep)[0] !== '..')
		throw new Error(`a key family may not enumerate itself from the catalogue: ${rel}`);
	if (!fs.existsSync(full)) throw new Error(`a key family reads a missing file: ${rel}`);
	return full;
}

/**
 * Reads a repository text file.
 * @param {string} rel - Repository-relative path.
 * @returns {string}
 */
function read(rel) {
	return fs.readFileSync(resolve(rel), 'utf8').replace(/^﻿/, '');
}

/**
 * Parses a repository JSON file.
 * @param {string} rel - Repository-relative path.
 * @returns {any}
 */
function json(rel) {
	return JSON.parse(read(rel));
}

/**
 * Parses a repository TOML file.
 * @param {string} rel - Repository-relative path.
 * @returns {any}
 */
function toml(rel) {
	return parseToml(read(rel));
}

/**
 * Evaluates the literal a source file assigns to a name (`const NAME = [...]`,
 * `local NAME = {...}`, `NAME := [...]`): the bracketed text after the first
 * declaration, read as a JavaScript literal. A Lua table is read when it holds
 * only strings ({ "a", "b" }) or string-keyed fields ({ a = 1 }).
 * @param {string} rel - Repository-relative path.
 * @param {string} name - The declared name.
 * @returns {any}
 */
function literal(rel, name) {
	const ext = path.extname(rel);
	const text = blankComments(read(rel), ext);
	const escaped = name.replace(/[.$]/g, '\\$&');
	const pattern =
		ext === '.lua'
			? new RegExp(`(?:^|[\\s;])(?:local\\s+)?${escaped}\\s*=\\s*`, 'm')
			: ext === '.ahk'
				? new RegExp(`(?:^|\\s)(?:global\\s+|static\\s+)?${escaped}\\s*:=\\s*`, 'm')
				: new RegExp(`(?:const|let|var)\\s+${escaped}\\s*=\\s*`);
	const m = pattern.exec(text);
	if (!m) throw new Error(`${rel} declares no ${name}`);
	let start = m.index + m[0].length;
	// Object.freeze( [...] ) and similar wrappers.
	const wrapper = /^(?:Object\.freeze|Map|Set)\s*\(\s*/.exec(text.slice(start));
	if (wrapper) start += wrapper[0].length;
	const open = text[start];
	const close = { '[': ']', '{': '}' }[open];
	if (!close) throw new Error(`${rel}: ${name} is not a bracketed literal`);
	let depth = 0;
	let end = start;
	for (; end < text.length; end++) {
		const c = text[end];
		if (c === '"' || c === "'") {
			const q = c;
			for (end++; end < text.length && text[end] !== q; end++) if (text[end] === '\\') end++;
			continue;
		}
		if (c === open) depth++;
		else if (c === close && --depth === 0) break;
	}
	let body = text.slice(start, end + 1);
	if (ext === '.lua') {
		body = body
			.replace(/\[\s*"([^"]+)"\s*\]\s*=/g, '"$1":')
			.replace(/(^|[{,\s])([A-Za-z_]\w*)\s*=(?!=)/g, '$1"$2":');
		if (!/:/.test(body)) body = '[' + body.slice(1, -1) + ']';
	}
	if (ext === '.ahk') body = body.replace(/\bMap\(/g, '(');
	return vm.runInNewContext('(' + body.replace(/Object\.freeze\(/g, '(') + ')');
}

/**
 * Runs classic page scripts in one context, as the page does, and returns
 * what an expression reads from it.
 * @param {string[]} rels - Repository-relative script paths, in page order.
 * @param {string} expression - Evaluated in the scripts' context.
 * @returns {any}
 */
function page(rels, expression) {
	const id = rels.join('|');
	let context = cache.get(id);
	if (!context) {
		// The scripts only define their globals at load; a document reader they
		// call then (currentScript for their own URL) gets an empty answer.
		const document = {
			currentScript: null,
			addEventListener() {},
			querySelector: () => null,
			querySelectorAll: () => []
		};
		const window = { _i18n_strings: {}, addEventListener() {}, document };
		window.window = window;
		context = vm.createContext(window);
		for (const rel of rels) vm.runInContext(read(rel), context, { filename: rel });
		cache.set(id, context);
	}
	return vm.runInContext(expression, context);
}

/**
 * The first capture of every match of a pattern in a source file, comments
 * blanked: the ids a file writes inline (`offer('toml', …)`, `lost.push('x')`).
 * A pattern that matches nothing is an error, so a renamed call cannot leave a
 * family empty.
 * @param {string} rel - Repository-relative path.
 * @param {RegExp} pattern - A global pattern with one capture.
 * @returns {string[]} The captures, in order, without duplicates.
 */
function matches(rel, pattern) {
	if (!pattern.global) throw new Error(`matches(${rel}) needs a global pattern`);
	const text = blankComments(read(rel), path.extname(rel));
	const found = [...new Set(Array.from(text.matchAll(pattern), (m) => m[1]))];
	if (found.length === 0) throw new Error(`${rel}: ${pattern} matches nothing`);
	return found;
}

/**
 * The literal first argument of every call of a function in a source file.
 * A call whose first argument is not a plain string literal is an error: its
 * key could not be enumerated.
 * @param {string} rel - Repository-relative path.
 * @param {string} name - The called function's name.
 * @returns {string[]}
 */
function callArguments(rel, name) {
	const text = blankComments(read(rel), path.extname(rel));
	const escaped = name.replace(/[.$]/g, '\\$&');
	const found = [];
	for (const m of text.matchAll(new RegExp(`(?<![\\w$.])${escaped}\\(\\s*([^,)]*)`, 'g'))) {
		const before = text.slice(Math.max(0, m.index - 10), m.index);
		if (/function\s+$/.test(before)) continue;
		const literal = /^(['"])([\w.]+)\1$/.exec(m[1].trim());
		if (!literal) throw new Error(`${rel}: ${name}(${m[1].trim()}) does not name its id literally`);
		found.push(literal[2]);
	}
	if (found.length === 0) throw new Error(`${rel}: no call of ${name}`);
	return [...new Set(found)];
}

/**
 * Prefixes each id with a family's head.
 * @param {string} prefix - The family head.
 * @param {Iterable<string>} ids - The ids the code reads.
 * @returns {string[]}
 */
function keysOf(prefix, ids) {
	return [...new Set([...ids].map((id) => prefix + id))];
}

module.exports = { callArguments, json, keysOf, literal, matches, page, read, toml };
