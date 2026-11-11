// _shared/ui/layout_editor/unicode_names.js

/**
 * ==============================================================================
 * MODULE: Unicode Names
 * DESCRIPTION:
 * Decodes the generated Unicode names table (_generated/unicode_names.js,
 * from tools/codegen/codegen-unicode-names.cjs) and answers the layout
 * editor's name search and character magnifier: the name, aliases and block
 * of a code point, and the characters whose name, alias, glyph or code point
 * matches a query with `*` and `?` wildcards.
 *
 * FEATURES & RATIONALE:
 * 1. Pure and lazy: the table decodes on first use and the module has no DOM
 *    dependency, so the Node tests run it in a vm; `ensure` alone loads the
 *    table into a page that does not list it (the website).
 * 2. Algorithmic names (CJK, Tangut, Hangul and other numbered runs) are rules,
 *    computed per code point exactly as the codegen collapsed them.
 * 3. A control character is named by its first control alias, as the
 *    Unicode name of a control is empty.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
var UnicodeNames = (function () {
	'use strict';

	const DIGITS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
	const DEFAULT_LIMIT = 1000;
	const MAX_LIMIT = 20000;
	// Hangul syllable name parts, Unicode chapter 3.12.
	const JAMO_L = [
		'G',
		'GG',
		'N',
		'D',
		'DD',
		'R',
		'M',
		'B',
		'BB',
		'S',
		'SS',
		'',
		'J',
		'JJ',
		'C',
		'K',
		'T',
		'P',
		'H'
	];
	const JAMO_V = [
		'A',
		'AE',
		'YA',
		'YAE',
		'EO',
		'E',
		'YEO',
		'YE',
		'O',
		'WA',
		'WAE',
		'OE',
		'YO',
		'U',
		'WEO',
		'WE',
		'WI',
		'YU',
		'EU',
		'YI',
		'I'
	];
	const JAMO_T = [
		'',
		'G',
		'GG',
		'GS',
		'N',
		'NJ',
		'NH',
		'D',
		'L',
		'LG',
		'LM',
		'LB',
		'LS',
		'LT',
		'LP',
		'LH',
		'M',
		'B',
		'BS',
		'S',
		'SS',
		'NG',
		'J',
		'C',
		'K',
		'T',
		'P',
		'H'
	];
	// The script element of this module, to find the table beside it.
	const OWN_SCRIPT = typeof document !== 'undefined' ? document.currentScript : null;

	let decoded = null;
	let loading = null;

	function hex(point) {
		return point.toString(16).toUpperCase().padStart(4, '0');
	}

	/** U+XXXX notation of a code point. */
	function codeLabel(point) {
		return `U+${hex(point)}`;
	}

	function table() {
		const data = typeof UNICODE_NAMES_DATA !== 'undefined' ? UNICODE_NAMES_DATA : null;
		if (!data) throw new Error('unicode_names_not_loaded');
		return data;
	}

	/** Decodes the table once: explicit names, rules, aliases and blocks. */
	function decode() {
		if (decoded) return decoded;
		const data = table();
		const words = data.words.split(' ');
		const names = new Map();
		const text = data.names;
		let point = -1;
		let position = 0;
		const next = () => {
			let value = 0;
			let scale = 1;
			for (;;) {
				const digit = DIGITS.indexOf(text[position++]);
				if (digit < 0) throw new Error('unicode_names_corrupt');
				if (digit < 32) return value + digit * scale;
				value += (digit - 32) * scale;
				scale *= 32;
			}
		};
		while (position < text.length) {
			point += next() + 1;
			const parts = [];
			for (let word = next(); word !== 0; word = next()) parts.push(words[word - 1]);
			names.set(point, parts.join(' '));
		}
		const aliases = new Map();
		for (const [code, alias, type] of data.aliases) {
			if (!aliases.has(code)) aliases.set(code, []);
			aliases.get(code).push({ alias, type });
		}
		decoded = { version: data.version, names, rules: data.rules, aliases, blocks: data.blocks };
		return decoded;
	}

	/** True once the table is in the page. */
	function available() {
		return typeof UNICODE_NAMES_DATA !== 'undefined';
	}

	/**
	 * Loads the table into a page that does not list it, beside this script.
	 * @returns {Promise<void>}
	 */
	function ensure() {
		if (available()) return Promise.resolve();
		if (loading) return loading;
		if (typeof document === 'undefined' || !OWN_SCRIPT || !OWN_SCRIPT.src)
			return Promise.reject(new Error('unicode_names_not_loaded'));
		loading = new Promise((resolve, reject) => {
			const script = document.createElement('script');
			script.src = new URL('_generated/unicode_names.js', OWN_SCRIPT.src).href;
			script.onload = () =>
				available() ? resolve() : reject(new Error('unicode_names_not_loaded'));
			script.onerror = () => {
				loading = null;
				reject(new Error('unicode_names_not_loaded'));
			};
			document.head.append(script);
		});
		return loading;
	}

	function ruleName(rule, point) {
		const [first, , kind, prefix, start] = rule;
		if (kind === 'hangul') {
			const s = point - 0xac00;
			return `HANGUL SYLLABLE ${JAMO_L[Math.floor(s / 588)]}${JAMO_V[Math.floor((s % 588) / 28)]}${JAMO_T[s % 28]}`;
		}
		if (kind === 'hex') return prefix + hex(point);
		return prefix + String(Number(start) + point - first).padStart(start.length, '0');
	}

	/**
	 * The Unicode name of a code point, a control's first control alias, or
	 * null (unassigned, private use, surrogate).
	 * @param {number} point
	 * @returns {string|null}
	 */
	function nameOf(point) {
		const data = decode();
		if (data.names.has(point)) return data.names.get(point);
		for (const rule of data.rules)
			if (point >= rule[0] && point <= rule[1]) return ruleName(rule, point);
		const control = (data.aliases.get(point) || []).find((entry) => entry.type === 'control');
		return control ? control.alias : null;
	}

	/** Every alias of a code point, as {alias, type}. */
	function aliasesOf(point) {
		return (decode().aliases.get(point) || []).slice();
	}

	/** The Unicode block name holding a code point, or null. */
	function blockOf(point) {
		const block = decode().blocks.find((entry) => point >= entry[0] && point <= entry[1]);
		return block ? block[2] : null;
	}

	/** Every block as {from, to, name}. */
	function blocks() {
		return decode().blocks.map(([from, to, name]) => ({ from, to, name }));
	}

	/**
	 * What the magnifier shows for a text: one row per code point.
	 * @param {string} text
	 * @returns {Array<{char: string, point: number, code: string, name: string|null, block: string|null}>}
	 */
	function describe(text) {
		return Array.from(text || '').map((char) => {
			const point = char.codePointAt(0);
			return { char, point, code: codeLabel(point), name: nameOf(point), block: blockOf(point) };
		});
	}

	/** A query term as a regex: `*` any run, `?` one character; others literal. */
	function termPattern(term) {
		const body = term
			.split('')
			.map((c) => (c === '*' ? '.*' : c === '?' ? '.' : c.replace(/[.+^${}()|[\]\\]/g, '\\$&')))
			.join('');
		// A wildcard term spans whole words; a plain word matches inside one.
		return /[*?]/.test(term) ? new RegExp(`(^|[ -])${body}($|[ -])`) : new RegExp(body);
	}

	/** The single code point a query names, if it is U+XXXX, 0xXXXX or one character. */
	function queryPoint(query) {
		const form = /^(?:U\+|0x)([0-9A-Fa-f]{1,6})$/.exec(query);
		if (form) {
			const point = parseInt(form[1], 16);
			return point <= 0x10ffff ? point : null;
		}
		const chars = Array.from(query);
		if (chars.length === 1 && !/^[A-Za-z0-9*?]$/.test(query)) return chars[0].codePointAt(0);
		return null;
	}

	/** Every named code point in order, with its name. */
	function* everyName() {
		const data = decode();
		const explicit = [...data.names.keys()];
		const rules = data.rules;
		let r = 0;
		for (let i = 0; i <= explicit.length; i++) {
			const point = i < explicit.length ? explicit[i] : Infinity;
			while (r < rules.length && rules[r][0] < point) {
				for (let p = rules[r][0]; p <= rules[r][1]; p++) yield [p, ruleName(rules[r], p)];
				r++;
			}
			if (point !== Infinity) yield [point, data.names.get(point)];
		}
	}

	/**
	 * Characters matching a query, by code point order.
	 * @param {string} query - Words (all must match, case-insensitive, with `*`
	 *   and `?`), a glyph, or U+XXXX.
	 * @param {number} [limit] - Result cap (default 1000).
	 * @returns {{results: Array<{point: number, char: string, code: string, name: string}>, truncated: boolean}}
	 */
	function search(query, limit) {
		const cap = Math.min(Math.max(1, Math.floor(Number(limit) || DEFAULT_LIMIT)), MAX_LIMIT);
		const raw = String(query || '').trim();
		if (!raw) return { results: [], truncated: false };
		const results = [];
		const seen = new Set();
		const push = (point, name) => {
			if (seen.has(point)) return true;
			if (results.length >= cap) return false;
			seen.add(point);
			results.push({
				point,
				char: String.fromCodePoint(point),
				code: codeLabel(point),
				name: name || ''
			});
			return true;
		};
		const point = queryPoint(raw);
		if (point !== null && !(point >= 0xd800 && point <= 0xdfff)) push(point, nameOf(point));
		const terms = raw.toUpperCase().split(/\s+/).map(termPattern);
		const matches = (name) => terms.every((pattern) => pattern.test(name));
		const data = decode();
		const aliasHits = new Map();
		for (const [code, list] of data.aliases)
			for (const { alias } of list) if (matches(alias)) aliasHits.set(code, alias);
		let truncated = false;
		for (const [code, name] of everyName()) {
			if (!matches(name) && !aliasHits.has(code)) continue;
			if (!push(code, name)) {
				truncated = true;
				break;
			}
			aliasHits.delete(code);
		}
		for (const [code, alias] of [...aliasHits].sort((a, b) => a[0] - b[0]))
			if (!push(code, nameOf(code) || alias)) {
				truncated = true;
				break;
			}
		return { results, truncated };
	}

	return {
		DEFAULT_LIMIT,
		MAX_LIMIT,
		available,
		ensure,
		nameOf,
		aliasesOf,
		blockOf,
		blocks,
		describe,
		search,
		codeLabel,
		version: () => decode().version
	};
})();
