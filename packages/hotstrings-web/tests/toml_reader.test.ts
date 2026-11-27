// packages/hotstrings-web/tests/toml_reader.test.ts

import { describe, expect, it } from 'vitest';
import { readToml, type TomlTable } from '../src/toml_reader.js';

/** Reads and turns the tables into plain objects for comparison. */
function plain(text: string) {
	const doc = readToml(text);
	return { root: JSON.parse(JSON.stringify(doc.root)), errors: doc.errors };
}

function errorsOf(text: string) {
	return readToml(text).errors;
}

describe('readToml values', () => {
	it('reads strings, escapes, booleans, numbers, arrays and inline tables', () => {
		const text = [
			'# comment',
			'a = "x\\ty\\n\\"q\\" \\\\ \\u00e9 \\U0001F600 \\b\\f\\r" # trailing',
			"b = 'C:\\path'",
			'c = true',
			'd = false',
			'e = -1_000',
			'f = 1.5e3',
			'g = [1, "two", [true], ] ',
			'h = { x = 1, "y z" = { w = "v" } }',
			'i = {}',
			'j = [',
			'  1, # one',
			'  2',
			']',
			'k = []',
			'"quoted key" = 1',
			"'lit key' = 2",
			'dotted . key = 3'
		].join('\r\n');
		expect(plain(text)).toEqual({
			root: {
				a: 'x\ty\n"q" \\ é 😀 \b\f\r',
				b: 'C:\\path',
				c: true,
				d: false,
				e: -1000,
				f: 1500,
				g: [1, 'two', [true]],
				h: { x: 1, 'y z': { w: 'v' } },
				i: {},
				j: [1, 2],
				k: [],
				'quoted key': 1,
				'lit key': 2,
				dotted: { key: 3 }
			},
			errors: []
		});
	});

	it('reads multi-line strings', () => {
		const text = [
			'a = """',
			'one',
			'two \\',
			'   three"""',
			'b = """x\\ty""""',
			"c = '''",
			'raw \\n',
			"line'''",
			"d = '''q'''''",
			'e = """\r\nwin"""'
		].join('\n');
		expect(plain(text).root).toEqual({
			a: 'one\ntwo three',
			b: 'x\ty"',
			c: 'raw \\n\nline',
			d: "q''",
			e: 'win'
		});
	});

	it('reads tables, arrays of tables and sub-tables of their last element', () => {
		const text = [
			'[a.b]',
			'x = 1',
			'[[list]]',
			'n = 1',
			'[list.sub]',
			'm = 2',
			'[[list]]',
			'n = 2'
		].join('\n');
		const doc = readToml(text);
		expect(JSON.parse(JSON.stringify(doc.root))).toEqual({
			a: { b: { x: 1 } },
			list: [{ n: 1, sub: { m: 2 } }, { n: 2 }]
		});
		const list = doc.root.list as unknown as TomlTable[];
		expect(doc.tableLines.get(list[0]!)).toBe(3);
		expect(doc.tableLines.get(list[1]!)).toBe(7);
		expect(doc.keyLines.get(list[1]!)?.get('n')).toBe(8);
	});

	it('keeps __proto__ as plain data', () => {
		const doc = readToml('__proto__ = 1');
		expect(Object.keys(doc.root)).toEqual(['__proto__']);
		expect(Object.getPrototypeOf(doc.root)).toBeNull();
	});
});

describe('readToml errors', () => {
	it.each([
		['a = 1979-05-27', 'unsupported value'],
		['a = 07:30', 'unsupported value'],
		['a = inf', 'unsupported value'],
		['a = 0x1F', 'unsupported value'],
		['a = 1 2', 'expected the end of the line'],
		['a 1', "expected '='"],
		['= 1', 'expected a key'],
		['[a', "expected ']'"],
		['[[a]', "expected ']]'"],
		['[a] x', 'expected the end of the line'],
		['a = "open', 'unterminated string'],
		["a = 'open", 'unterminated string'],
		["a = 'open\nb = 'x'", 'unterminated string'],
		['a = """open', 'unterminated string'],
		["a = '''open", 'unterminated string'],
		['a = "\\x"', "invalid escape '\\x'"],
		['a = "\\u12"', 'invalid unicode escape'],
		['a = "\\UFFFFFFFF"', 'invalid unicode escape'],
		['a = "\\uD800"', 'invalid unicode escape'],
		['a = [1 2]', "expected ']' or ','"],
		['a = { b = 1 c = 2 }', "expected '}' or ','"],
		['a = { b 1 }', "expected '='"],
		['a = 1\na = 2', "key 'a' is defined twice"],
		['[t]\n[t]', "table 't' is defined twice"],
		['a = 1\n[a.b]', "'a' is not a table"],
		['a = []\n[a.b]', "'a' is not a table"],
		['a = 1\n[[a]]', "'a' is not an array of tables"]
	])('reports %j', (text, message) => {
		const errors = errorsOf(text);
		expect(errors.map((e) => e.message)).toContain(message);
	});

	it('locates an error and resumes at the next line', () => {
		const doc = readToml('a = 1\nb = ?\nc = 3');
		expect(doc.errors).toEqual([{ line: 2, message: 'unsupported value' }]);
		expect(doc.root.c).toBe(3);
	});

	it('rethrows what is not a syntax error', () => {
		const original = String.fromCodePoint;
		String.fromCodePoint = () => {
			throw new Error('boom');
		};
		try {
			expect(() => readToml('a = "\\u0041"')).toThrow('boom');
		} finally {
			String.fromCodePoint = original;
		}
	});
});
