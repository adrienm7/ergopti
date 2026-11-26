// _shared/ui/layout_analysis/shortcut_typing.js

/**
 * ==============================================================================
 * MODULE: Typing With The Ergopti+ Shortcuts
 * DESCRIPTION:
 * Turns a clean text into the keystroke stream an Ergopti+ user types for it:
 * each part of the text that one of the user's hotstrings produces is replaced
 * by that hotstring's trigger (« c’est » by « c★ »), everything else is kept
 * as written. The one definition the Studio pages (the Comparer's « Typed with
 * the Ergopti+ shortcuts » corpus option) and the Node tests share; the
 * codegen reads its flag bits to write the catalogue it reads. No DOM, no fetch.
 * docs/design/layout-analysis.md, « Typed with the Ergopti+ shortcuts ».
 *
 * FEATURES & RATIONALE:
 * 1. The drivers' rules: the shared Lua engine's (hotstrings/engine/matcher)
 *    registration shapes (cased family, literal, strict), word boundary,
 *    auto and end-character paths, longest trigger first, the consumed magic
 *    key and the reset after a final_result expansion, so the forward
 *    expander here (expand) gives what a driver types back.
 * 2. Fewest keystrokes, deterministically: a dynamic programme over the text
 *    picks the replacements that save the most keystrokes, never overlapping,
 *    a strictly saving one only, the longest output first on a tie.
 * 3. Proven, not assumed: the chosen stream is replayed through expand as it
 *    is built. A replacement that would not give the text back is typed as
 *    written instead; a hotstring that fires on text typed as written (« ya »
 *    in Spanish) is undone by one Backspace, as the drivers allow, and counted
 *    (`undos`), so expand(stream, undos) always gives the text back.
 * 4. Only the user's hotstrings: the sections they enabled and their personal
 *    hotstrings, never the whole catalogue by default.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
// eslint-disable-next-line no-unused-vars
var LAYOUT_SHORTCUT_TYPING = (function () {
	'use strict';

	// ====================================
	// ====================================
	// ======= 1/ Constants ===============
	// ====================================
	// ====================================

	// The magic key as hotstring data writes it (_shared/hotstrings/data/magic_key.json).
	const MARKER = '★';
	// One bit per flag of a catalogue entry, the codegen's compact form.
	const FLAGS = Object.freeze({ word: 1, auto: 2, caseSensitive: 4, strict: 8, final: 16 });
	// The engine's rolling buffer (matcher/init.lua BUFFER_MAX_CHARS).
	const BUFFER_MAX_CHARS = 256;
	const NBSP = ' ';
	const NNBSP = ' ';
	// The Ergopti Shift level of these signs is a no-break space and a sign
	// (core/text/engine/utils_core.lua UPPER_TRIGGERS): a trigger's capital form.
	const UPPER_TRIGGER_SIGNS = Object.freeze({
		"'": [NNBSP + '?', NBSP + '?'],
		',': [NNBSP + ':', NNBSP + ';', NBSP + ':', NBSP + ';'],
		'.': [NNBSP + ':', NBSP + ':']
	});
	// What an output may not hold to be text a typist sees (a key token, a line
	// or a tab press a key): such a hotstring is left out, and counted.
	const KEY_TOKEN = /[{}\n\t\r]/;
	// Where a personal hotstring comes from in the report.
	const PERSONAL_SOURCE = 'personal';

	/** A refusal with a stable code a page can word. */
	class ShortcutTypingError extends Error {
		constructor(code, message) {
			super(`shortcut_typing: ${code}: ${message}`);
			this.code = code;
		}
	}

	// ====================================
	// ====================================
	// ======= 2/ Case and word rules =====
	// ====================================
	// ====================================

	/** One code point's capital, kept when it has none of one code point. */
	function upperChar(c) {
		const u = c.toUpperCase();
		return Array.from(u).length === 1 ? u : c;
	}

	/** One code point's small letter, kept when it has none of one code point. */
	function lowerChar(c) {
		const l = c.toLowerCase();
		return Array.from(l).length === 1 ? l : c;
	}

	/** utils_core.lua trig_lower: each code point to its small letter. */
	function trigLower(s) {
		return Array.from(s, lowerChar).join('');
	}

	/** utils_core.lua trig_upper: every capital form of a trigger. */
	function trigUpper(s) {
		let results = [''];
		for (const c of s) {
			const forms = UPPER_TRIGGER_SIGNS[c] || [upperChar(c)];
			const next = [];
			for (const r of results) for (const f of forms) next.push(r + f);
			results = next;
		}
		return results;
	}

	/** utils_core.lua trig_title: the first code point's capitals, the rest small. */
	function trigTitle(s) {
		const cps = Array.from(s);
		if (cps.length === 0) return [s];
		const rest = trigLower(cps.slice(1).join(''));
		return trigUpper(cps[0]).map((first) => first + rest);
	}

	/** utils_core.lua repl_upper. */
	function replUpper(s) {
		return Array.from(s, upperChar).join('');
	}

	/** utils_core.lua repl_title: the first code point's capital. */
	function replTitle(s) {
		const cps = Array.from(s);
		return cps.length === 0 ? s : upperChar(cps[0]) + cps.slice(1).join('');
	}

	/**
	 * utils_core.lua is_hotstring_word_char: an is_word trigger fires only
	 * after a character that is not one of these. Every non-ASCII code point
	 * counts, the apostrophe ’ and the magic key included, as on macOS and Linux.
	 */
	function isWordChar(c) {
		if (c === undefined || c === '') return false;
		if (c.codePointAt(0) > 127) return true;
		return c === '@' || /^[A-Za-z0-9_]$/.test(c);
	}

	// ====================================
	// ====================================
	// ======= 3/ Hotstrings ==============
	// ====================================
	// ====================================

	/**
	 * Checks one hotstring and gives it the engine's field names.
	 * @param {object} raw - {trigger, output, is_word?, auto_expand?,
	 *   is_case_sensitive?, is_case_sensitive_strict?, final_result?}.
	 * @param {string} source - Its section id, or « personal ».
	 * @returns {object} The mapping.
	 * @throws {ShortcutTypingError} On a trigger or output that is not a non-empty string.
	 */
	function mapping(raw, source) {
		if (!raw || typeof raw.trigger !== 'string' || raw.trigger === '')
			throw new ShortcutTypingError('trigger_invalid', `${source} has a hotstring without trigger`);
		if (typeof raw.output !== 'string' || raw.output === '')
			throw new ShortcutTypingError('output_invalid', `${source} ${raw.trigger} has no output`);
		return {
			trigger: raw.trigger,
			output: raw.output,
			is_word: raw.is_word === true,
			auto_expand: raw.auto_expand === true,
			is_case_sensitive: raw.is_case_sensitive === true,
			is_case_sensitive_strict: raw.is_case_sensitive_strict === true,
			final_result: raw.final_result === true,
			source
		};
	}

	/**
	 * The hotstrings of the enabled catalogue sections, in catalogue order.
	 * @param {object} catalogue - LAYOUT_HOTSTRING_CATALOGUE.
	 * @param {string[]} enabled - Section ids (« group.section ») the user enabled.
	 * @returns {object[]} Mappings.
	 * @throws {ShortcutTypingError} On a section the catalogue does not have.
	 */
	function catalogueMappings(catalogue, enabled) {
		const wanted = new Set(enabled);
		const known = new Set(catalogue.sections.map((s) => s.id));
		for (const id of wanted)
			if (!known.has(id)) throw new ShortcutTypingError('section_unknown', `no section ${id}`);
		const out = [];
		for (const section of catalogue.sections) {
			if (!wanted.has(section.id)) continue;
			for (const [trigger, output, bits] of section.entries)
				out.push(
					mapping(
						{
							trigger,
							output,
							is_word: (bits & FLAGS.word) !== 0,
							auto_expand: (bits & FLAGS.auto) !== 0,
							is_case_sensitive: (bits & FLAGS.caseSensitive) !== 0,
							is_case_sensitive_strict: (bits & FLAGS.strict) !== 0,
							final_result: (bits & FLAGS.final) !== 0
						},
						section.id
					)
				);
		}
		return out;
	}

	/**
	 * The user's personal hotstrings, as their host sends them.
	 * @param {object[]} list - Raw mappings.
	 * @returns {object[]} Mappings.
	 */
	function personalMappings(list) {
		if (!Array.isArray(list))
			throw new ShortcutTypingError('personal_invalid', 'personal hotstrings must be a list');
		return list.map((raw) => mapping(raw, PERSONAL_SOURCE));
	}

	/** One registered variant, as the matcher compares it. */
	function variant(m, trigger, output, mode, seq) {
		const tcps = Array.from(trigger);
		return {
			trigger,
			tcps,
			tfold: mode === 'fold' ? tcps.map(lowerChar) : null,
			output,
			ocps: Array.from(output),
			mode,
			word: m.is_word,
			auto: m.auto_expand,
			final: m.final_result,
			source: m.source,
			base: m.trigger,
			seq
		};
	}

	/**
	 * Registers the hotstrings as the shared engine does (load_mappings): strict
	 * compares exactly, is_case_sensitive folds the case and types the output
	 * as written, any other gives its small, Title and capital forms with the
	 * output conformed; a trigger with an inner space also with each no-break
	 * space. A hotstring that presses a key is left out (`skipped`).
	 * @param {object[]} mappings - catalogueMappings and personalMappings, in order.
	 * @param {{terminators: Array<{chars: string[], consume: boolean}>}} options -
	 *   The enabled end characters (LAYOUT_HOTSTRING_CATALOGUE.terminators).
	 * @returns {object} The registry expand and toTyped read.
	 */
	function compile(mappings, options) {
		if (!options || !Array.isArray(options.terminators))
			throw new ShortcutTypingError('terminators_missing', 'compile needs the end characters');
		const endChars = new Set();
		const consumed = new Set();
		for (const slot of options.terminators)
			for (const c of slot.chars) (slot.consume ? consumed : endChars).add(c);
		const variants = [];
		const skipped = [];
		let seq = 0;
		const add = (m, trigger, output, mode) => {
			variants.push(variant(m, trigger, output, mode, seq++));
			if (trigger.charAt(0) !== ' ' && trigger.charAt(0) !== NBSP && trigger.charAt(0) !== NNBSP)
				if (trigger.includes(' ')) {
					variants.push(variant(m, trigger.split(' ').join(NBSP), output, mode, seq++));
					variants.push(variant(m, trigger.split(' ').join(NNBSP), output, mode, seq++));
				}
		};
		for (const m of mappings) {
			if (KEY_TOKEN.test(m.output)) {
				skipped.push(m);
				continue;
			}
			if (m.is_case_sensitive_strict) add(m, m.trigger, m.output, 'exact');
			else if (m.is_case_sensitive) add(m, m.trigger, m.output, 'fold');
			else {
				const lower = trigLower(m.trigger);
				add(m, lower, m.output, 'exact');
				const titles = trigTitle(lower);
				for (const t of titles) if (t !== lower) add(m, t, replTitle(m.output), 'exact');
				for (const u of trigUpper(lower))
					if (u !== lower && !titles.includes(u)) add(m, u, replUpper(m.output), 'exact');
			}
		}
		// The matcher's buckets: by the trigger's last code point (folded),
		// longest first, then registration order.
		const byTail = new Map();
		// The inverse's: by the output's first two code points (one for a
		// one-character output), longest output first, then registration order.
		const byOutput = new Map();
		const push = (map, key, v) => {
			if (!map.has(key)) map.set(key, []);
			map.get(key).push(v);
		};
		for (const v of variants) {
			push(byTail, lowerChar(v.tcps[v.tcps.length - 1]), v);
			push(byOutput, v.ocps.length === 1 ? v.ocps[0] : v.ocps[0] + v.ocps[1], v);
		}
		for (const list of byTail.values())
			list.sort((a, b) => b.tcps.length - a.tcps.length || a.seq - b.seq);
		for (const list of byOutput.values())
			list.sort((a, b) => b.ocps.length - a.ocps.length || a.seq - b.seq);
		return { variants, byTail, byOutput, endChars, consumed, skipped };
	}

	// ====================================
	// ====================================
	// ======= 4/ Forward expansion =======
	// ====================================
	// ====================================

	/** Whether a variant's trigger ends the buffer at `end`, its boundary kept. */
	function tailMatches(v, text, start, end) {
		const n = v.tcps.length;
		const from = end - n;
		if (from < start) return false;
		for (let k = 0; k < n; k++) {
			const b = text[from + k];
			if (v.mode === 'fold' ? lowerChar(b) !== v.tfold[k] : b !== v.tcps[k]) return false;
		}
		// The start of the buffer is a word boundary (a text start, or a reset).
		return !(v.word && from > start && isWordChar(text[from - 1]));
	}

	/** The longest variant of a path ending the buffer at `end`, or null. */
	function longest(registry, text, start, end, auto) {
		if (end <= start) return null;
		const bucket = registry.byTail.get(lowerChar(text[end - 1]));
		if (!bucket) return null;
		for (const v of bucket) if (v.auto === auto && tailMatches(v, text, start, end)) return v;
		return null;
	}

	/** A new expander's state: the text so far and where its buffer starts. */
	function newState() {
		return { text: [], start: 0, last: null };
	}

	/**
	 * Types one character, as the engine's on_char then apply_expansion do.
	 * @returns {object|null} The fire ({at, variant}), or null.
	 */
	function typeChar(registry, state, c) {
		const text = state.text;
		text.push(c);
		state.last = null;
		if (text.length - state.start > BUFFER_MAX_CHARS) state.start = text.length - BUFFER_MAX_CHARS;
		const len = text.length;
		const auto = longest(registry, text, state.start, len, true);
		let end = null;
		let stripped = 0;
		const isEnd = registry.endChars.has(c) || registry.consumed.has(c);
		if (isEnd) {
			let body = len - 1;
			if ((c === ':' || c === ';') && (text[body - 1] === NBSP || text[body - 1] === NNBSP)) {
				body -= 1;
				stripped = 1;
			}
			end = longest(registry, text, state.start, body, false);
		}
		let v;
		let erase;
		let tail = [];
		if (end && (!auto || end.tcps.length > auto.tcps.length)) {
			v = end;
			erase = end.tcps.length + stripped + 1;
			if (!registry.consumed.has(c)) tail = [c];
		} else if (auto) {
			v = auto;
			erase = auto.tcps.length;
		} else return null;
		const at = len - erase;
		const erased = text.splice(at, erase);
		for (const o of v.ocps) text.push(o);
		for (const o of tail) text.push(o);
		state.last = { at, erased, previousStart: state.start, variant: v };
		// A final_result expansion resets the buffer at a word boundary.
		if (v.final) state.start = text.length;
		return state.last;
	}

	/** Undoes the last fire by one Backspace: the typed text comes back. */
	function undo(state) {
		const last = state.last;
		if (!last) throw new ShortcutTypingError('undo_without_fire', 'nothing to undo');
		state.text.splice(last.at);
		for (const c of last.erased) state.text.push(c);
		state.start = last.previousStart;
		state.last = null;
	}

	/**
	 * Types a stream through the hotstrings, as a driver does.
	 * @param {string} stream - The characters typed.
	 * @param {object} registry - From compile.
	 * @param {number[]} [undos] - Indexes of the stream's characters after
	 *   which one Backspace undoes the expansion that character fired.
	 * @returns {string} The text the application receives.
	 * @throws {ShortcutTypingError} On an undo after a character that fired nothing.
	 */
	function expand(stream, registry, undos) {
		const after = new Set(undos || []);
		const state = newState();
		Array.from(stream).forEach((c, i) => {
			typeChar(registry, state, c);
			if (after.has(i)) undo(state);
		});
		return state.text.join('');
	}

	// ====================================
	// ====================================
	// ======= 5/ Clean text to keys ======
	// ====================================
	// ====================================

	/**
	 * Every replacement that may start at `i`: its variant, the keys typed and
	 * how far into the text it reaches (an end character it is typed with
	 * included).
	 */
	function candidatesAt(registry, clean, i) {
		const out = [];
		const keys = [clean[i]];
		if (i + 1 < clean.length) keys.unshift(clean[i] + clean[i + 1]);
		for (const key of keys) {
			const list = registry.byOutput.get(key);
			if (!list) continue;
			for (const v of list) {
				const n = v.ocps.length;
				if (i + n > clean.length) continue;
				let same = true;
				for (let k = 0; k < n && same; k++) same = clean[i + k] === v.ocps[k];
				if (!same) continue;
				if (v.word && i > 0 && isWordChar(clean[i - 1])) continue;
				const endAt = i + n;
				let typed;
				let reach;
				if (v.auto) {
					typed = v.tcps;
					reach = endAt;
				} else if (endAt < clean.length && registry.endChars.has(clean[endAt])) {
					typed = v.tcps.concat([clean[endAt]]);
					reach = endAt + 1;
				} else if (registry.consumed.has(MARKER)) {
					typed = v.tcps.concat([MARKER]);
					reach = endAt;
				} else continue;
				const saving = reach - i - typed.length;
				if (saving > 0) out.push({ variant: v, typed, reach, saving });
			}
		}
		return out;
	}

	/** The replacements that save the most keystrokes in all (backward DP). */
	function plan(registry, clean) {
		const n = clean.length;
		const best = new Float64Array(n + 1);
		const choice = new Array(n).fill(null);
		for (let i = n - 1; i >= 0; i--) {
			best[i] = best[i + 1];
			for (const c of candidatesAt(registry, clean, i)) {
				const total = c.saving + best[c.reach];
				if (total > best[i]) {
					best[i] = total;
					choice[i] = c;
				}
			}
		}
		return choice;
	}

	/** Whether the state's text is the clean text up to `upto`, from `from` on. */
	function agrees(state, clean, from, upto) {
		const text = state.text;
		if (text.length !== upto) return false;
		for (let k = from; k < upto; k++) if (text[k] !== clean[k]) return false;
		return true;
	}

	/**
	 * The keys an Ergopti+ user types for a clean text with these hotstrings.
	 * @param {string} text - The clean text.
	 * @param {object} registry - From compile.
	 * @returns {{typed: string, undos: number[], report: object}} The stream,
	 *   the characters after which one Backspace undoes an unwanted expansion,
	 *   and what changed: {characters, keystrokes, saved, undos, replaced,
	 *   triggers: [{trigger, output, source, count, saved}] most used first,
	 *   skipped}.
	 */
	function toTyped(text, registry) {
		if (typeof text !== 'string')
			throw new ShortcutTypingError('text_invalid', 'text must be a string');
		const clean = Array.from(text);
		const choice = plan(registry, clean);
		const state = newState();
		const typed = [];
		const undos = [];
		const uses = new Map();

		// One character typed as written; an expansion it fires that changes the
		// text is undone at once.
		const verbatim = (p) => {
			typed.push(clean[p]);
			const fire = typeChar(registry, state, clean[p]);
			if (fire && !agrees(state, clean, fire.at, p + 1)) {
				undo(state);
				undos.push(typed.length - 1);
			}
		};

		let i = 0;
		while (i < clean.length) {
			const c = choice[i];
			if (!c) {
				verbatim(i);
				i += 1;
				continue;
			}
			// Tried on a copy of the buffer's window: a replacement that does not
			// give the text back is typed as written instead.
			const savedText = state.text.slice(Math.max(0, state.text.length - BUFFER_MAX_CHARS - 2));
			const savedLength = state.text.length;
			const savedStart = state.start;
			let ok = true;
			c.typed.forEach((key, k) => {
				if (!ok) return;
				const fire = typeChar(registry, state, key);
				const last = k === c.typed.length - 1;
				if (last) ok = fire !== null && agrees(state, clean, fire.at, c.reach);
				else ok = fire === null;
			});
			if (ok) {
				for (const key of c.typed) typed.push(key);
				const v = c.variant;
				const id = `${v.source}\u0000${v.trigger}\u0000${v.output}`;
				const use = uses.get(id) || {
					trigger: v.trigger,
					output: v.output,
					source: v.source,
					count: 0,
					saved: 0
				};
				use.count += 1;
				use.saved += c.saving;
				uses.set(id, use);
				i = c.reach;
				continue;
			}
			state.text.length = savedLength - savedText.length;
			for (const k of savedText) state.text.push(k);
			state.start = savedStart;
			state.last = null;
			verbatim(i);
			i += 1;
		}
		const triggers = Array.from(uses.values()).sort(
			(a, b) => b.saved - a.saved || b.count - a.count || (a.trigger < b.trigger ? -1 : 1)
		);
		const replaced = triggers.reduce((sum, t) => sum + t.count, 0);
		return {
			typed: typed.join(''),
			undos,
			report: {
				characters: clean.length,
				keystrokes: typed.length + undos.length,
				saved: clean.length - typed.length - undos.length,
				undos: undos.length,
				replaced,
				triggers,
				skipped: registry.skipped.length
			}
		};
	}

	// ====================================
	// ====================================
	// ======= 6/ Magic key per layout ====
	// ====================================
	// ====================================

	/**
	 * The magic key's character on a layout (magic_key.json): a family's
	 * default when every key it names types its character on the base level,
	 * else the fallback (the configured default, ★).
	 * @param {function(string): (string|null)} baseOf - KeyboardEvent.code → base character.
	 * @param {{families: object[], fallback: string}} magicKey - LAYOUT_HOTSTRING_CATALOGUE.magic_key.
	 * @returns {string} The character the layout types the magic key with.
	 */
	function layoutMagicChar(baseOf, magicKey) {
		for (const family of magicKey.families)
			if (Object.entries(family.base).every(([code, c]) => baseOf(code) === c))
				return family.default_char;
		return magicKey.fallback;
	}

	/**
	 * The tables with the magic key typed as `char` (the stream writes ★).
	 * @param {{chars: object, bigrams: object, trigrams: object}} tables - Counts.
	 * @param {string} char - layoutMagicChar's.
	 * @returns {object} The same tables when `char` is ★, else renamed copies.
	 */
	function withMagicChar(tables, char) {
		if (char === MARKER) return tables;
		const rename = (table) => {
			const out = {};
			for (const [key, n] of Object.entries(table || {})) {
				const k = key.split(MARKER).join(char);
				out[k] = (out[k] || 0) + n;
			}
			return out;
		};
		return Object.assign({}, tables, {
			chars: rename(tables.chars),
			bigrams: rename(tables.bigrams),
			trigrams: rename(tables.trigrams)
		});
	}

	// ====================================
	// ====================================
	// ======= 7/ Built-in corpus text ====
	// ====================================
	// ====================================

	// The two-character spellings the old KLA conversion wrote for an accented letter.
	const DEAD_KEY_PAIRS = Object.freeze({
		'^': { a: 'â', e: 'ê', i: 'î', o: 'ô', u: 'û', A: 'Â', E: 'Ê', I: 'Î', O: 'Ô', U: 'Û' },
		'¨': { a: 'ä', e: 'ë', i: 'ï', o: 'ö', u: 'ü', y: 'ÿ', A: 'Ä', E: 'Ë', I: 'Ï', O: 'Ö', U: 'Ü' }
	});

	/** Turns those spellings (^e, ¨i) back into the accented letter. */
	function restoreDeadKeyPairs(text) {
		return text.replace(
			/([\^¨])([A-Za-z])/g,
			(pair, mark, letter) => DEAD_KEY_PAIRS[mark][letter] || pair
		);
	}

	/**
	 * The text of a built-in corpus file as the engine counts it: without its
	 * byte order marks, its dead-key pairs restored, a Leipzig file's sentence
	 * numbers and a tab-separated file's other columns dropped. The codegen
	 * counts the tables from this very text (corpusText).
	 * @param {string} raw - The file.
	 * @param {{id: string, format?: string, restore_dead_key_pairs?: boolean,
	 *   strip_sentence_numbers?: boolean, tsv_text_column?: number}} spec - Its corpora.json entry.
	 * @returns {string} The text.
	 * @throws {ShortcutTypingError} On a tab-separated file without its column.
	 */
	function sourceText(raw, spec) {
		let text = raw.replace(/﻿/g, '');
		if (spec.restore_dead_key_pairs) text = restoreDeadKeyPairs(text);
		// A Leipzig sentence file numbers its lines: « 12<TAB>sentence ».
		if (spec.strip_sentence_numbers) text = text.replace(/^\d+\t/gm, '');
		if ((spec.format || 'text') === 'tsv') {
			if (!Number.isInteger(spec.tsv_text_column))
				throw new ShortcutTypingError('tsv_column', `${spec.id} needs tsv_text_column`);
			text = text
				.split('\n')
				.filter((line) => line !== '')
				.map((line) => {
					const cell = line.split('\t')[spec.tsv_text_column];
					if (cell === undefined)
						throw new ShortcutTypingError('tsv_line', `${spec.id} has a short line`);
					return cell;
				})
				.join('\n');
		}
		return text;
	}

	return Object.freeze({
		MARKER,
		FLAGS,
		PERSONAL_SOURCE,
		ShortcutTypingError,
		isWordChar,
		catalogueMappings,
		personalMappings,
		compile,
		expand,
		toTyped,
		layoutMagicChar,
		withMagicChar,
		restoreDeadKeyPairs,
		sourceText
	});
})();

// Node (tests, codegen) reads the module through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_SHORTCUT_TYPING;
