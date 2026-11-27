// packages/hotstrings-web/tests/vectors.test.ts

/**
 * Replays Ergopti's own cross-driver hotstring corpus against this engine.
 * The vectors are read live from static/ergopti_plus/_shared/tests/corpus/
 * hotstrings/, the files the Lua (macOS, Linux) and AutoHotkey (Windows) test
 * suites replay, so a change of contract there reaches this package's tests.
 */

import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { ExpansionUndo, HotstringMatcher, lowerCase, type Hotstring } from '../src/index.js';

const CORPUS = new URL(
	'../../../static/ergopti_plus/_shared/tests/corpus/hotstrings/',
	import.meta.url
);

function corpus(name: string): Record<string, unknown[]> {
	return JSON.parse(readFileSync(new URL(name, CORPUS), 'utf8'));
}

interface Mapping {
	trigger: string;
	replacement: string;
	is_word?: boolean;
	auto_expand?: boolean;
	is_case_sensitive?: boolean;
	is_case_sensitive_strict?: boolean;
	priority?: number;
}

/** Maps a corpus mapping to a hotstring, as the v1 reader maps a personal entry. */
function fromMapping(m: Mapping, expand?: Hotstring['expand']): Hotstring {
	const hotstring: Hotstring = {
		trigger: m.trigger,
		output: m.replacement,
		expand: expand ?? (m.auto_expand ? 'immediate' : 'terminator'),
		terminator: 'echo',
		caseSensitive: m.is_case_sensitive_strict === true,
		wordStart: m.is_word === true
	};
	if (m.is_case_sensitive && !m.is_case_sensitive_strict) hotstring.conformCase = false;
	if (m.priority !== undefined) hotstring.priority = m.priority;
	return hotstring;
}

/** Code points in the last `units` UTF-16 units of `text`. */
function pointsAtEnd(text: string, units: number): number {
	return Array.from(text.slice(text.length - units)).length;
}

/** Types keys into a line, applying every expansion as an editor would. */
function typeKeys(matcher: HotstringMatcher, keys: string[], line = '') {
	let last = null;
	for (const key of keys) {
		last = matcher.match(line, key);
		if (last) {
			line = line.slice(0, line.length - last.deleteCount) + last.insert;
			if (!last.consumedKey) line += key;
		} else {
			line += key;
		}
	}
	return { line, last };
}

// static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json, "vectors":
// single-trigger matching. A unit replay matches as the trigger's last
// character is typed; the terminator only matters when it is consumed.
describe('vectors.json single-trigger contract', () => {
	interface Vector extends Mapping {
		id: string;
		buffer: string;
		terminator?: string;
		terminator_consumed?: boolean;
		driver_specific?: string;
		expected: { matched: boolean; replacement?: string; backspace_count?: number };
	}
	const vectors = corpus('vectors.json').vectors as Vector[];

	it('holds the corpus', () => {
		expect(vectors.length).toBeGreaterThan(40);
	});

	for (const v of vectors) {
		// The rolling buffer cap is a per-driver constant; the web reads the line.
		const run = v.driver_specific === 'rolling_buffer_cap' ? it.skip : it;
		run(v.id, () => {
			if (v.terminator_consumed) {
				// The consumed terminator is the key that fires; Ergopti counts it.
				const matcher = new HotstringMatcher([fromMapping(v, 'terminator')]);
				const e = matcher.match(v.buffer, v.terminator as string);
				expect(e?.insert).toBe(v.expected.replacement);
				expect(e?.consumedKey).toBe(true);
				expect(pointsAtEnd(v.buffer, e!.deleteCount) + 1).toBe(v.expected.backspace_count);
				return;
			}
			const matcher = new HotstringMatcher([fromMapping(v)]);
			const points = Array.from(v.buffer);
			const last = points.pop();
			const before = points.join('');
			const e = last === undefined ? null : matcher.match(before, last);
			if (!v.expected.matched) {
				expect(e).toBeNull();
				return;
			}
			expect(e?.insert).toBe(v.expected.replacement);
			expect(pointsAtEnd(before, e!.deleteCount) + 1).toBe(v.expected.backspace_count);
		});
	}
});

// static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json,
// "collision_vectors": length > priority > first registered.
describe('vectors.json collision contract', () => {
	interface Collision {
		id: string;
		mappings: Mapping[];
		buffer: string;
		expected: { matched: boolean; winner?: string };
	}
	for (const v of corpus('vectors.json').collision_vectors as Collision[]) {
		it(v.id, () => {
			const matcher = new HotstringMatcher(v.mappings.map((m) => fromMapping(m)));
			const points = Array.from(v.buffer);
			const last = points.pop() as string;
			const e = matcher.match(points.join(''), last);
			expect(e?.insert ?? null).toBe(v.expected.matched ? v.expected.winner : null);
		});
	}
});

// static/ergopti_plus/_shared/tests/corpus/hotstrings/end_character_vectors.json:
// a bare or typographic (NBSP / NNBSP) colon or semicolon ends a trigger.
describe('end_character_vectors.json', () => {
	interface EndVector {
		id: string;
		mappings: Mapping[];
		typed: string[];
		expected: { fires: boolean; replacement?: string; backspace_count?: number };
	}
	for (const v of corpus('end_character_vectors.json').vectors as EndVector[]) {
		it(v.id, () => {
			const matcher = new HotstringMatcher(v.mappings.map((m) => fromMapping(m)));
			const before = v.typed.slice(0, -1).join('');
			const e = matcher.match(before, v.typed[v.typed.length - 1]!);
			if (!v.expected.fires) {
				expect(e).toBeNull();
				return;
			}
			expect(e?.insert.startsWith(v.expected.replacement as string)).toBe(true);
			// Ergopti counts the end character, already in its buffer, as replaced.
			const counted = pointsAtEnd(before, e!.deleteCount) + 1;
			expect(counted).toBe(v.expected.backspace_count);
		});
	}
});

// static/ergopti_plus/_shared/tests/corpus/hotstrings/backspace_restore_vectors.json:
// what a Backspace after an expansion leaves on screen, then the keys after it.
describe('backspace_restore_vectors.json', () => {
	interface RestoreVector {
		id: string;
		trigger: string;
		output: string;
		terminator?: string;
		terminator_consumed?: boolean;
		magic_key: string;
		enabled: boolean;
		window_ms: number;
		elapsed_ms: number;
		key_between?: boolean;
		undoes: boolean;
		screen_after: string;
		then?: string[];
		screen_then?: string;
	}
	for (const v of corpus('backspace_restore_vectors.json').vectors as RestoreVector[]) {
		it(v.id, () => {
			const hotstring: Hotstring = {
				trigger: lowerCase(v.trigger),
				output: v.output,
				expand: v.terminator === undefined ? 'immediate' : 'terminator',
				terminator: v.terminator_consumed ? 'consume' : 'echo',
				caseSensitive: false,
				conformCase: false,
				wordStart: false
			};
			const matcher = new HotstringMatcher([hotstring], { magicKey: v.magic_key });
			const undo = new ExpansionUndo(v.window_ms);
			const keys = Array.from(v.trigger);
			if (v.terminator !== undefined) keys.push(v.terminator === '\n' ? 'Enter' : v.terminator);
			let { line, last } = typeKeys(matcher, keys);
			expect(last).not.toBeNull();
			if (v.enabled) undo.record({ trigger: last!.restore, insert: last!.insert, at: 0 });
			if (v.key_between) undo.clear();
			const backspace = (now: number) => {
				const edit = undo.backspace(now);
				if (edit) line = line.slice(0, line.length - edit.deleteCount) + edit.insert;
				else line = Array.from(line).slice(0, -1).join('');
				return edit;
			};
			expect(backspace(v.elapsed_ms) !== null).toBe(v.undoes);
			expect(line).toBe(v.screen_after);
			if (!v.then) return;
			let now = v.elapsed_ms;
			for (const key of v.then) {
				now += 10;
				if (key === '{BS}') {
					backspace(now);
					continue;
				}
				const step = typeKeys(matcher, [key], line);
				line = step.line;
				if (step.last && v.enabled) {
					undo.record({ trigger: step.last.restore, insert: step.last.insert, at: now });
				} else {
					undo.clear();
				}
			}
			expect(line).toBe(v.screen_then);
		});
	}
});
