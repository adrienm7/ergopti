// packages/hotstrings-web/tests/toml.test.ts

import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
	FORMAT_V2,
	parseHotstrings,
	quoteTomlString,
	serializeHotstrings,
	type Hotstring
} from '../src/index.js';

const full: Hotstring = {
	trigger: 'sig',
	output: 'Best regards,\n{cursor}\t"Mira" \\ \u0001\u007f\r',
	expand: 'key',
	key: 'F2',
	terminator: 'consume',
	caseSensitive: true,
	conformCase: false,
	wordStart: false,
	priority: 50,
	description: 'Signature',
	tags: ['mail', 'perso']
};
const minimal: Hotstring = {
	trigger: 'btw',
	output: 'by the way',
	expand: 'terminator',
	terminator: 'echo',
	caseSensitive: false,
	wordStart: true
};

describe('serializeHotstrings and parseHotstrings v2', () => {
	it('round-trips every field', () => {
		const text = serializeHotstrings([full, minimal]);
		expect(text.startsWith(`# Ergopti hotstrings, format 2\nformat = "${FORMAT_V2}"\n`)).toBe(true);
		expect(text.endsWith('\n')).toBe(true);
		expect(text).not.toContain('\r\n');
		expect(parseHotstrings(text)).toEqual({ version: 2, hotstrings: [full, minimal], errors: [] });
	});

	it('writes an empty list as a header only, and reads it back', () => {
		expect(parseHotstrings(serializeHotstrings([]))).toEqual({
			version: 2,
			hotstrings: [],
			errors: []
		});
	});

	it('applies the defaults of omitted fields', () => {
		const text = `format = "${FORMAT_V2}"\n[[hotstring]]\ntrigger = "a"\noutput = "b"\n`;
		expect(parseHotstrings(text).hotstrings).toEqual([
			{
				trigger: 'a',
				output: 'b',
				expand: 'terminator',
				terminator: 'echo',
				caseSensitive: false,
				wordStart: true
			}
		]);
	});

	it('quotes control characters', () => {
		expect(quoteTomlString('a"\\\n\t\r\u0000é')).toBe('"a\\"\\\\\\n\\t\\r\\u0000é"');
	});

	it('reports each bad entry with the line of its table and keeps the good ones', () => {
		const text = [
			`format = "${FORMAT_V2}"`,
			'[[hotstring]]',
			'trigger = ""',
			'output = "x"',
			'[[hotstring]]',
			'trigger = "ok"',
			'output = "fine"',
			'[[hotstring]]',
			'trigger = "k"',
			'output = "x"',
			'expand = "key"',
			'[[hotstring]]',
			'trigger = "e"',
			'output = "x"',
			'expand = "never"',
			'[[hotstring]]',
			'trigger = 1',
			'output = "x"',
			'[[hotstring]]',
			'trigger = "w"',
			'output = "x"',
			'word_start = "yes"',
			'[[hotstring]]',
			'trigger = "p"',
			'output = "x"',
			'priority = 1.5',
			'[[hotstring]]',
			'trigger = "t"',
			'output = "x"',
			'tags = [1]',
			'[[hotstring]]',
			'trigger = "u"',
			'output = "x"',
			'colour = "red"',
			'[[hotstring]]',
			'trigger = "n"',
			'output = "x"',
			'priority = "high"',
			'[[hotstring]]',
			'trigger = "s"',
			'output = "x"',
			'tags = "one"'
		].join('\n');
		const parsed = parseHotstrings(text);
		expect(parsed.hotstrings.map((h) => h.trigger)).toEqual(['ok']);
		expect(parsed.errors).toEqual([
			{ line: 2, message: "'trigger' must not be empty" },
			{ line: 8, message: 'expand = "key" needs a \'key\'' },
			{ line: 12, message: "'expand' must be one of terminator, immediate, enter, tab, key" },
			{ line: 16, message: "'trigger' must be a string" },
			{ line: 19, message: "'word_start' must be true or false" },
			{ line: 23, message: "'priority' must be an integer" },
			{ line: 27, message: "'tags' must be an array of strings" },
			{ line: 31, message: "unknown key 'colour'" },
			{ line: 35, message: "'priority' must be an integer" },
			{ line: 39, message: "'tags' must be an array of strings" }
		]);
	});

	it('reports unknown top-level keys and a hotstring key that is no array of tables', () => {
		const text = [
			`format = "${FORMAT_V2}"`,
			'extra = 1',
			'hotstring = 3',
			'[meta]',
			'a = 1',
			'[[other]]'
		].join('\n');
		expect(parseHotstrings(text).errors).toEqual([
			{ line: 2, message: "unknown key 'extra'" },
			{ line: 3, message: "'hotstring' must be an array of tables ([[hotstring]])" },
			{ line: 4, message: "unknown key 'meta'" },
			{ line: 6, message: "unknown key 'other'" }
		]);
	});

	it('locates a bad inline hotstring table on its key line', () => {
		const text = `format = "${FORMAT_V2}"\n\nhotstring = [{ trigger = "a" }]`;
		expect(parseHotstrings(text).errors).toEqual([
			{ line: 3, message: "'output' must be a string" }
		]);
	});

	it('refuses an unknown format and passes reader errors through, sorted', () => {
		expect(parseHotstrings('a = ?\nformat = "ergopti-hotstrings/3"')).toEqual({
			version: 2,
			hotstrings: [],
			errors: [
				{ line: 1, message: 'unsupported value' },
				{ line: 2, message: 'unsupported format "ergopti-hotstrings/3"' }
			]
		});
	});

	it('locates a header table, and falls back to line 1 for a table no line names', () => {
		expect(parseHotstrings(`format = "${FORMAT_V2}"\nx.y = 1\n[a]\nb = []`).errors).toEqual([
			{ line: 1, message: "unknown key 'x'" },
			{ line: 3, message: "unknown key 'a'" }
		]);
	});
});

describe('parseHotstrings v1 (personal_hotstrings.toml)', () => {
	it('maps the flags as Ergopti readers do', () => {
		const text = [
			'[_meta]',
			'description = { fr = "Perso", en = "Personal" }',
			'sections_order = ["mail"]',
			'',
			'[_meta.sections]',
			'mail = { en = "Mail" }',
			'',
			'[[mail]]',
			'"btw" = { output = "by the way", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }',
			'"adn" = { output = "ADN", is_word = false, auto_expand = true, is_case_sensitive = true, final_result = true, priority = 60 }',
			'"BTW" = { output = "B", is_word = false, auto_expand = false, is_case_sensitive = true, final_result = false, is_case_sensitive_strict = true }',
			'[stray]',
			'x = 1'
		].join('\n');
		expect(parseHotstrings(text)).toEqual({
			version: 1,
			errors: [],
			hotstrings: [
				{
					trigger: 'btw',
					output: 'by the way',
					expand: 'terminator',
					terminator: 'echo',
					caseSensitive: false,
					wordStart: true,
					tags: ['mail']
				},
				{
					trigger: 'adn',
					output: 'ADN',
					expand: 'immediate',
					terminator: 'echo',
					caseSensitive: false,
					conformCase: false,
					wordStart: false,
					priority: 60,
					tags: ['mail']
				},
				{
					trigger: 'BTW',
					output: 'B',
					expand: 'terminator',
					terminator: 'echo',
					caseSensitive: true,
					wordStart: false,
					tags: ['mail']
				}
			]
		});
	});

	it('reports a bad entry on its own line and keeps the others', () => {
		const text = [
			'[[s]]',
			'"a" = "not a table"',
			'"b" = { output = "x", is_word = true, auto_expand = false, is_case_sensitive = false }',
			'"c" = { output = "x", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false, action = "run" }',
			'"d" = { output = "x", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }',
			'e.output = "x"'
		].join('\n');
		const parsed = parseHotstrings(text);
		expect(parsed.hotstrings.map((h) => h.trigger)).toEqual(['d']);
		expect(parsed.errors).toEqual([
			{ line: 1, message: "'is_case_sensitive' must be true or false" },
			{ line: 2, message: "trigger 'a' must hold an inline table" },
			{ line: 3, message: "'final_result' must be true or false" },
			{ line: 4, message: "unsupported field 'action'" }
		]);
	});

	it('reads the demo extension file Ergopti ships', () => {
		const url = new URL(
			'../../../static/ergopti_plus/extensions/ergopti-demo/hotstrings/demo-phrases.toml',
			import.meta.url
		);
		const parsed = parseHotstrings(readFileSync(url, 'utf8'));
		expect(parsed.version).toBe(1);
		expect(parsed.errors).toEqual([]);
		expect(parsed.hotstrings.length).toBeGreaterThan(3);
		expect(parsed.hotstrings[0]).toMatchObject({
			trigger: 'helo★',
			output: 'Hello, world!',
			tags: ['greetings']
		});
		const again = parseHotstrings(serializeHotstrings(parsed.hotstrings));
		expect(again).toEqual({ version: 2, hotstrings: parsed.hotstrings, errors: [] });
	});
});
