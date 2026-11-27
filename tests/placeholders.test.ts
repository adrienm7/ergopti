// packages/hotstrings-web/tests/placeholders.test.ts

import { describe, expect, it } from 'vitest';
import { expandOutput, formatDate } from '../src/index.js';

const date = new Date(2026, 10, 7);

describe('formatDate', () => {
	it('writes YYYY, MM and DD and keeps every other character', () => {
		expect(formatDate(date, 'DD/MM/YYYY')).toBe('07/11/2026');
		expect(formatDate(new Date(905, 0, 1), 'YYYY Y M D')).toBe('0905 Y M D');
	});
});

describe('expandOutput', () => {
	it('places the cursor at the first {cursor} and drops the others', () => {
		expect(expandOutput('a{cursor}b{cursor}c')).toEqual({ text: 'abc', cursor: 1 });
		expect(expandOutput('plain')).toEqual({ text: 'plain', cursor: null });
	});

	it('inserts the selection, empty when there is none', () => {
		expect(expandOutput('*{selection}*', { selection: 'bold' }).text).toBe('*bold*');
		expect(expandOutput('*{selection}*').text).toBe('**');
	});

	it('writes the ISO date and a formatted date, today by default', () => {
		expect(expandOutput('{date}|{date:DD.MM}', { date }).text).toBe('2026-11-07|07.11');
		expect(expandOutput('{date}').text).toMatch(/^\d{4}-\d{2}-\d{2}$/);
		expect(expandOutput('{date:YYYY}').text).toMatch(/^\d{4}$/);
	});

	it('reads named values and leaves an unknown one verbatim', () => {
		const ctx = { values: { title: 'The Book', pov: 'Mira' } };
		expect(expandOutput('{value:title} ({value:pov})', ctx).text).toBe('The Book (Mira)');
		expect(expandOutput('{value:place}', ctx).text).toBe('{value:place}');
		expect(expandOutput('{value:toString}').text).toBe('{value:toString}');
	});

	it('unescapes {{ and }} and leaves unknown or unclosed braces verbatim', () => {
		expect(expandOutput('{{cursor}} {unknown} {open').text).toBe('{cursor} {unknown} {open');
		expect(expandOutput('{a{cursor}')).toEqual({ text: '{a', cursor: 2 });
		expect(expandOutput('x}y').text).toBe('x}y');
	});

	it('keeps markup as plain text', () => {
		expect(expandOutput('#mention("mira")[Mira]{cursor}').text).toBe('#mention("mira")[Mira]');
	});
});
