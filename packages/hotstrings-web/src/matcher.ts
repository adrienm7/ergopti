// packages/hotstrings-web/src/matcher.ts

/**
 * The hotstring matcher: given the text before the caret and the key just
 * typed, it says which hotstring fires and the edit that applies it.
 *
 * It follows Ergopti's shared matcher (static/ergopti_plus/_shared/hotstrings/
 * engine/matcher/init.lua and core/text/engine/utils_core.lua):
 * 1. Two paths. An `immediate` trigger fires on its own last character; any
 *    other waits for its key, and the body it matches excludes that key. When
 *    both fire, the end-key trigger wins only when it is strictly longer.
 * 2. Longest trigger first, then the higher `priority`, then the first listed.
 * 3. Case: strict compares exactly; the default conforms the output to a lower,
 *    Title or UPPER typed trigger and fires nothing on another casing; the
 *    literal mode (`conformCase: false`) folds and keeps the output verbatim.
 * 4. Word start: the character before the trigger must not be a word character
 *    (ASCII letter, digit, `_`, `@`, or any non-ASCII character, the magic key
 *    included); the start of `before` is a word start.
 * 5. An output equal to what was typed fires nothing (the no-op guard).
 * 6. French typography: a no-break or narrow no-break space between a trigger
 *    and a typed `:` or `;` is tolerated and replaced with the trigger.
 * Each keystroke walks a trie of reversed, case-folded triggers from the
 * caret backwards, so its cost is bounded by the longest trigger, not by the
 * number of hotstrings.
 */

import type { Expansion, Hotstring } from './types.js';

/** The terminators Ergopti enables out of the box (Terminators.spec.js). */
export const DEFAULT_TERMINATORS = ' \t\n\r★,;.!?:';

/** Ergopti's magic key, the one terminator it consumes out of the box. */
export const DEFAULT_MAGIC_KEY = '★';

const NBSP = ' ';
const NNBSP = ' ';

/** Matcher settings. */
export interface MatcherOptions {
	/** Characters that end a `terminator` trigger. */
	terminators?: string;
	/** Terminators always consumed, whatever the hotstring says (default: the magic key). */
	consumed?: string;
	/** The magic key, dropped from the end of a trigger an undo gives back. */
	magicKey?: string;
}

type CaseMode = 'exact' | 'fold' | 'conform';

interface Entry {
	hotstring: Hotstring;
	seq: number;
	mode: CaseMode;
	/** The trigger compared in `mode`: as written, folded, or lower-cased. */
	compared: string;
	priority: number;
}

interface TrieNode {
	children: Map<string, TrieNode>;
	immediate: Entry[];
	ending: Entry[];
}

interface Candidate {
	entry: Entry;
	output: string;
	typed: string;
	depth: number;
}

function newNode(): TrieNode {
	return { children: new Map(), immediate: [], ending: [] };
}

/** Splits a string into code points. */
function codePoints(text: string): string[] {
	return Array.from(text);
}

/** The start index of the code point that ends at `end`. */
function previousStart(text: string, end: number): number {
	const low = text.charCodeAt(end - 1);
	if (low >= 0xdc00 && low <= 0xdfff && end >= 2) {
		const high = text.charCodeAt(end - 2);
		if (high >= 0xd800 && high <= 0xdbff) return end - 2;
	}
	return end - 1;
}

/** Lower-cases one code point, keeping it when lower-casing changes its length. */
function lowerPoint(cp: string): string {
	const lower = cp.toLowerCase();
	return lower.length === cp.length ? lower : cp;
}

/** Lower-cases a string code point by code point (Ergopti's trig_lower). */
export function lowerCase(text: string): string {
	return codePoints(text).map(lowerPoint).join('');
}

/** Folds one code point: lower case, final sigma read as sigma (trig_fold). */
function foldPoint(cp: string): string {
	const lower = lowerPoint(cp);
	return lower === 'ς' ? 'σ' : lower;
}

/** Folds a string for case-insensitive comparison. */
export function foldCase(text: string): string {
	return codePoints(text).map(foldPoint).join('');
}

/** Whether a code point continues a word for the word-start rule. */
export function isWordChar(cp: string): boolean {
	if (cp.charCodeAt(0) > 127) return true;
	return cp === '@' || /^[A-Za-z0-9_]$/.test(cp);
}

const PLACEHOLDER = /\{\{|\}\}|\{[^{}]*\}/g;

/** Upper-cases an output outside its placeholders (repl_upper). */
function upperOutput(output: string): string {
	let result = '';
	let last = 0;
	for (const match of output.matchAll(PLACEHOLDER)) {
		result += output.slice(last, match.index).toUpperCase() + match[0];
		last = match.index + match[0].length;
	}
	return result + output.slice(last).toUpperCase();
}

/** Upper-cases an output's first code point unless it opens a placeholder (repl_title). */
function titleOutput(output: string): string {
	if (/^\{[^{}]*\}/.test(output)) return output;
	const first = codePoints(output)[0] ?? '';
	return first.toUpperCase() + output.slice(first.length);
}

/**
 * The output for a typed casing of a lower-cased trigger (conform_replacement).
 * @returns The conformed output, or null when the casing is neither lower, Title nor UPPER.
 */
function conform(output: string, typed: string, lower: string): string | null {
	if (typed === lower) return output;
	const points = codePoints(lower);
	const title = points[0].toUpperCase() + points.slice(1).join('');
	if (typed === title && title !== lower) return titleOutput(output);
	if (typed === lower.toUpperCase()) return upperOutput(output);
	return null;
}

/** Validates one hotstring; throws on a shape the matcher cannot run. */
function validate(hotstring: Hotstring, index: number): void {
	if (typeof hotstring.trigger !== 'string' || hotstring.trigger === '') {
		throw new TypeError(`hotstring ${index}: the trigger must be a non-empty string`);
	}
	if (typeof hotstring.output !== 'string') {
		throw new TypeError(`hotstring ${index}: the output must be a string`);
	}
	if (hotstring.expand === 'key' && !hotstring.key) {
		throw new TypeError(`hotstring ${index}: expand 'key' needs a key`);
	}
}

/** Maps the key names Enter and Tab to their characters. */
function keyText(key: string): string {
	if (key === 'Enter') return '\n';
	if (key === 'Tab') return '\t';
	return key;
}

/** Matches typed text against a list of hotstrings. */
export class HotstringMatcher {
	private readonly root = newNode();
	private readonly terminators: Set<string>;
	private readonly consumed: Set<string>;
	private readonly magicKey: string;

	/**
	 * @param list The hotstrings; their order breaks the last ties.
	 * @param options Terminators, always-consumed terminators and magic key.
	 */
	constructor(list: Hotstring[], options: MatcherOptions = {}) {
		this.magicKey = options.magicKey ?? DEFAULT_MAGIC_KEY;
		this.terminators = new Set(codePoints(options.terminators ?? DEFAULT_TERMINATORS));
		this.consumed = new Set(codePoints(options.consumed ?? this.magicKey));
		list.forEach((hotstring, seq) => {
			validate(hotstring, seq);
			this.add(hotstring, seq);
		});
		this.sortNode(this.root);
	}

	private add(hotstring: Hotstring, seq: number): void {
		let mode: CaseMode = 'conform';
		if (hotstring.caseSensitive) mode = 'exact';
		else if (hotstring.conformCase === false) mode = 'fold';
		const compared =
			mode === 'exact'
				? hotstring.trigger
				: mode === 'fold'
					? foldCase(hotstring.trigger)
					: lowerCase(hotstring.trigger);
		const entry: Entry = { hotstring, seq, mode, compared, priority: hotstring.priority ?? 0 };
		let node = this.root;
		const points = codePoints(foldCase(hotstring.trigger));
		for (let i = points.length - 1; i >= 0; i -= 1) {
			let child = node.children.get(points[i]);
			if (!child) {
				child = newNode();
				node.children.set(points[i], child);
			}
			node = child;
		}
		(hotstring.expand === 'immediate' ? node.immediate : node.ending).push(entry);
	}

	private sortNode(node: TrieNode): void {
		const order = (a: Entry, b: Entry) => b.priority - a.priority || a.seq - b.seq;
		node.immediate.sort(order);
		node.ending.sort(order);
		node.children.forEach((child) => this.sortNode(child));
	}

	/**
	 * Finds the best entry ending at the end of `text`.
	 * @param text The text whose tail is matched.
	 * @param pick Chooses the entries of a node that may fire.
	 */
	private best(text: string, pick: (node: TrieNode) => Entry[]): Candidate | null {
		const levels: { node: TrieNode; start: number }[] = [];
		let node: TrieNode | undefined = this.root;
		let start = text.length;
		while (start > 0) {
			const from = previousStart(text, start);
			node = node.children.get(foldPoint(text.slice(from, start)));
			if (!node) break;
			start = from;
			levels.push({ node, start });
		}
		for (let depth = levels.length; depth > 0; depth -= 1) {
			const level = levels[depth - 1];
			const typed = text.slice(level.start);
			const prev = level.start > 0 ? text.slice(previousStart(text, level.start), level.start) : null;
			for (const entry of pick(level.node)) {
				const output = this.decide(entry, typed, prev);
				if (output !== null) return { entry, output, typed, depth };
			}
		}
		return null;
	}

	/** The output an entry gives for a typed tail, or null when it does not fire (decide). */
	private decide(entry: Entry, typed: string, prev: string | null): string | null {
		let output: string | null = null;
		const { hotstring } = entry;
		if (entry.mode === 'exact') {
			if (typed === entry.compared) output = hotstring.output;
		} else if (entry.mode === 'fold') {
			if (foldCase(typed) === entry.compared) output = hotstring.output;
		} else if (lowerCase(typed) === entry.compared) {
			output = conform(hotstring.output, typed, entry.compared);
		}
		if (output === null) return null;
		if (hotstring.wordStart && prev !== null && isWordChar(prev)) return null;
		if (output === typed) return null;
		return output;
	}

	/** Drops a final magic key from a typed trigger (backspace_restore.restored_text). */
	private withoutMagic(typed: string): string {
		const magic = this.magicKey;
		return magic !== '' && typed.endsWith(magic) ? typed.slice(0, -magic.length) : typed;
	}

	/**
	 * Says which hotstring the key just typed fires.
	 * @param before The text before the caret on the line.
	 * @param typed The key just typed: one character, or a key name (Enter, Tab, ...).
	 * @returns The edit to make, or null when nothing fires.
	 */
	match(before: string, typed: string): Expansion | null {
		const key = keyText(typed);
		const isChar = key !== '' && codePoints(key).length === 1;
		const immediate = isChar ? this.best(before + key, (node) => node.immediate) : null;

		const isTerminator = isChar && this.terminators.has(key);
		const fires = (entry: Entry): boolean => {
			const { expand } = entry.hotstring;
			if (expand === 'terminator') return isTerminator;
			if (expand === 'enter') return key === '\n';
			if (expand === 'tab') return key === '\t';
			const own = entry.hotstring.key as string;
			return own === typed || keyText(own) === key;
		};
		let body = before;
		let spacing = '';
		if ((key === ':' || key === ';') && (before.endsWith(NBSP) || before.endsWith(NNBSP))) {
			body = before.slice(0, -1);
			spacing = before.slice(-1);
		}
		const ending = this.best(body, (node) => node.ending.filter(fires));

		if (ending && (!immediate || ending.depth > immediate.depth)) {
			const { hotstring } = ending.entry;
			const consume = hotstring.terminator === 'consume' || this.consumed.has(key);
			const restore = this.withoutMagic(ending.typed);
			const deleteCount = ending.typed.length + spacing.length;
			if (consume) {
				return { hotstring, deleteCount, insert: ending.output, consumedKey: true, restore };
			}
			if (!isChar) {
				return { hotstring, deleteCount, insert: ending.output, consumedKey: false, restore };
			}
			const echo = spacing + key;
			return {
				hotstring,
				deleteCount,
				insert: ending.output + echo,
				consumedKey: true,
				restore: restore + echo
			};
		}
		if (immediate) {
			return {
				hotstring: immediate.entry.hotstring,
				deleteCount: immediate.typed.length - key.length,
				insert: immediate.output,
				consumedKey: true,
				restore: this.withoutMagic(immediate.typed)
			};
		}
		return null;
	}
}
