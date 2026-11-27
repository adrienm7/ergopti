// packages/hotstrings-web/tests/undo.test.ts

import { describe, expect, it } from 'vitest';
import { DEFAULT_UNDO_WINDOW_MS, ExpansionUndo } from '../src/index.js';

describe('ExpansionUndo', () => {
	it('defaults to Ergopti window of 500 ms and refuses an invalid window', () => {
		expect(DEFAULT_UNDO_WINDOW_MS).toBe(500);
		for (const bad of [0, -5, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
			expect(() => new ExpansionUndo(bad)).toThrow(RangeError);
		}
	});

	it('gives the trigger back within the window, the end included, once', () => {
		const undo = new ExpansionUndo();
		undo.record({ trigger: 'btw ', insert: 'by the way ', at: 1000 });
		expect(undo.backspace(1500)).toEqual({ deleteCount: 11, insert: 'btw ' });
		expect(undo.backspace(1501)).toBeNull();
	});

	it('answers null past the window, before the record, after clear and with nothing recorded', () => {
		const undo = new ExpansionUndo(250);
		expect(undo.backspace(0)).toBeNull();
		undo.record({ trigger: 'a', insert: 'b', at: 100 });
		expect(undo.backspace(351)).toBeNull();
		undo.record({ trigger: 'a', insert: 'b', at: 100 });
		expect(undo.backspace(99)).toBeNull();
		undo.record({ trigger: 'a', insert: 'b', at: 100 });
		undo.clear();
		expect(undo.backspace(101)).toBeNull();
	});

	it('keeps its own copy of the record', () => {
		const undo = new ExpansionUndo(1000);
		const entry = { trigger: 'td', insert: '2026-11-27', at: 0 };
		undo.record(entry);
		entry.insert = 'changed';
		expect(undo.backspace(10)).toEqual({ deleteCount: 10, insert: 'td' });
	});
});
