// packages/hotstrings-web/src/toml_reader.ts

/**
 * A minimal TOML reader, enough for hotstring files and nothing more.
 *
 * It reads tables, arrays of tables, dotted and quoted keys, basic and literal
 * strings (single and multi-line, with escapes), booleans, decimal integers
 * and floats, arrays and inline tables, and comments. Dates, times, `inf`,
 * `nan` and hexadecimal, octal or binary integers are reported as errors.
 * An error is recorded with its line and the reader resumes at the next line,
 * so one bad entry never hides the others.
 */

/** A TOML value. */
export type TomlValue = string | number | boolean | TomlValue[] | TomlTable;

/** A TOML table. */
export interface TomlTable {
	[key: string]: TomlValue;
}

/** A located reader error. */
export interface TomlError {
	/** 1-based line of the error. */
	line: number;
	message: string;
}

/** What the reader returns. */
export interface TomlDocument {
	root: TomlTable;
	/** The line of each table header ([table] or [[array]]). */
	tableLines: Map<TomlTable, number>;
	/** The line of each key, per table. */
	keyLines: Map<TomlTable, Map<string, number>>;
	errors: TomlError[];
}

class TomlSyntaxError extends Error {}

const BARE_KEY = /[A-Za-z0-9_-]/;
const NUMBER = /^[+-]?(?:0|[1-9](?:_?\d)*)(?:\.\d(?:_?\d)*)?(?:[eE][+-]?\d(?:_?\d)*)?/;
const ESCAPES: Record<string, string> = {
	b: '\b',
	t: '\t',
	n: '\n',
	f: '\f',
	r: '\r',
	'"': '"',
	'\\': '\\'
};

/** A table without a prototype, so a key such as `__proto__` is plain data. */
function newTable(): TomlTable {
	return Object.create(null) as TomlTable;
}

function isTable(value: TomlValue | undefined): value is TomlTable {
	return typeof value === 'object' && !Array.isArray(value);
}

class Reader {
	private pos = 0;
	private line = 1;
	private current: TomlTable;
	private readonly defined = new Set<TomlTable>();
	private readonly doc: TomlDocument;

	constructor(private readonly text: string) {
		const root = newTable();
		this.current = root;
		this.doc = { root, tableLines: new Map(), keyLines: new Map(), errors: [] };
	}

	read(): TomlDocument {
		for (;;) {
			this.skipBlank(true);
			if (this.pos >= this.text.length) return this.doc;
			try {
				this.statement();
			} catch (error) {
				if (!(error instanceof TomlSyntaxError)) throw error;
				this.doc.errors.push({ line: this.line, message: error.message });
				this.skipLine();
			}
		}
	}

	private fail(message: string): never {
		throw new TomlSyntaxError(message);
	}

	private peek(offset = 0): string {
		return this.text[this.pos + offset] ?? '';
	}

	private startsWith(token: string): boolean {
		return this.text.startsWith(token, this.pos);
	}

	/** Advances past a character, counting lines. */
	private advance(): string {
		const ch = this.text[this.pos];
		this.pos += 1;
		if (ch === '\n') this.line += 1;
		return ch;
	}

	/** Skips spaces and tabs, then comments and newlines when `lines` is set. */
	private skipBlank(lines: boolean): void {
		while (this.pos < this.text.length) {
			const ch = this.peek();
			if (ch === ' ' || ch === '\t') this.advance();
			else if (ch === '#') this.skipComment();
			else if (lines && (ch === '\n' || ch === '\r')) this.advance();
			else return;
		}
	}

	private skipComment(): void {
		while (this.pos < this.text.length && this.peek() !== '\n') this.pos += 1;
	}

	/** After an error: moves to the end of the line the error was met on. */
	private skipLine(): void {
		while (this.pos < this.text.length && this.peek() !== '\n') this.pos += 1;
	}

	private endOfLine(): void {
		this.skipBlank(false);
		if (this.startsWith('\r\n')) this.pos += 1;
		if (this.pos < this.text.length && this.peek() !== '\n')
			this.fail('expected the end of the line');
	}

	private statement(): void {
		if (this.startsWith('[[')) {
			this.pos += 2;
			const path = this.keyPath();
			if (!this.startsWith(']]')) this.fail("expected ']]'");
			this.pos += 2;
			this.endOfLine();
			this.arrayTable(path);
		} else if (this.peek() === '[') {
			this.pos += 1;
			const path = this.keyPath();
			if (this.peek() !== ']') this.fail("expected ']'");
			this.pos += 1;
			this.endOfLine();
			this.table(path);
		} else {
			const line = this.line;
			const path = this.keyPath();
			if (this.peek() !== '=') this.fail("expected '='");
			this.pos += 1;
			this.skipBlank(false);
			const value = this.value();
			this.endOfLine();
			this.assign(this.current, path, value, line);
		}
	}

	private keyPath(): string[] {
		const path: string[] = [];
		for (;;) {
			this.skipBlank(false);
			path.push(this.key());
			this.skipBlank(false);
			if (this.peek() !== '.') return path;
			this.pos += 1;
		}
	}

	private key(): string {
		const ch = this.peek();
		if (ch === '"') return this.basicString();
		if (ch === "'") return this.literalString();
		const start = this.pos;
		while (BARE_KEY.test(this.peek())) this.pos += 1;
		if (this.pos === start) this.fail('expected a key');
		return this.text.slice(start, this.pos);
	}

	/** Walks to the table a header or dotted key names, creating missing ones. */
	private descend(table: TomlTable, path: string[]): TomlTable {
		let node = table;
		for (const key of path) {
			let next = node[key];
			if (next === undefined) {
				next = newTable();
				node[key] = next;
			}
			if (Array.isArray(next)) next = next[next.length - 1];
			if (!isTable(next)) this.fail(`'${key}' is not a table`);
			node = next;
		}
		return node;
	}

	private table(path: string[]): void {
		const table = this.descend(this.doc.root, path);
		if (this.defined.has(table)) this.fail(`table '${path.join('.')}' is defined twice`);
		this.defined.add(table);
		this.doc.tableLines.set(table, this.line);
		this.current = table;
	}

	private arrayTable(path: string[]): void {
		const parent = this.descend(this.doc.root, path.slice(0, -1));
		const key = path[path.length - 1];
		const list = parent[key] ?? [];
		if (!Array.isArray(list)) this.fail(`'${key}' is not an array of tables`);
		const table = newTable();
		list.push(table);
		parent[key] = list;
		this.defined.add(table);
		this.doc.tableLines.set(table, this.line);
		this.current = table;
	}

	private assign(table: TomlTable, path: string[], value: TomlValue, line: number): void {
		const target = this.descend(table, path.slice(0, -1));
		const key = path[path.length - 1];
		if (Object.hasOwn(target, key)) this.fail(`key '${key}' is defined twice`);
		target[key] = value;
		let lines = this.doc.keyLines.get(target);
		if (!lines) {
			lines = new Map();
			this.doc.keyLines.set(target, lines);
		}
		lines.set(key, line);
	}

	private value(): TomlValue {
		if (this.startsWith('"""')) return this.multilineBasic();
		if (this.startsWith("'''")) return this.multilineLiteral();
		const ch = this.peek();
		if (ch === '"') return this.basicString();
		if (ch === "'") return this.literalString();
		if (ch === '[') return this.array();
		if (ch === '{') return this.inlineTable();
		if (this.startsWith('true')) {
			this.pos += 4;
			return true;
		}
		if (this.startsWith('false')) {
			this.pos += 5;
			return false;
		}
		const match = NUMBER.exec(this.text.slice(this.pos));
		if (!match) this.fail('unsupported value');
		this.pos += match[0].length;
		if (BARE_KEY.test(this.peek()) || this.peek() === ':') this.fail('unsupported value');
		return Number(match[0].replaceAll('_', ''));
	}

	private escape(): string {
		const ch = this.advance();
		if (Object.hasOwn(ESCAPES, ch)) return ESCAPES[ch];
		if (ch === 'u' || ch === 'U') {
			const width = ch === 'u' ? 4 : 8;
			const hex = this.text.slice(this.pos, this.pos + width);
			if (!new RegExp(`^[0-9A-Fa-f]{${width}}$`).test(hex)) this.fail('invalid unicode escape');
			const code = parseInt(hex, 16);
			if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff))
				this.fail('invalid unicode escape');
			this.pos += width;
			return String.fromCodePoint(code);
		}
		this.fail(`invalid escape '\\${ch}'`);
	}

	private basicString(): string {
		this.pos += 1;
		let out = '';
		for (;;) {
			const ch = this.peek();
			if (ch === '' || ch === '\n') this.fail('unterminated string');
			this.pos += 1;
			if (ch === '"') return out;
			out += ch === '\\' ? this.escape() : ch;
		}
	}

	private literalString(): string {
		const end = this.text.indexOf("'", this.pos + 1);
		const newline = this.text.indexOf('\n', this.pos + 1);
		if (end < 0 || (newline >= 0 && newline < end)) this.fail('unterminated string');
		const out = this.text.slice(this.pos + 1, end);
		this.pos = end + 1;
		return out;
	}

	/** Skips the newline that directly follows an opening triple quote. */
	private skipOpeningNewline(): void {
		if (this.startsWith('\r\n')) this.pos += 1;
		if (this.peek() === '\n') this.advance();
	}

	/** Takes up to two quotes that end a multi-line string's content. */
	private closingQuotes(quote: string): string {
		let extra = '';
		while (extra.length < 2 && this.peek() === quote) extra += this.advance();
		return extra;
	}

	private multilineBasic(): string {
		this.pos += 3;
		this.skipOpeningNewline();
		let out = '';
		for (;;) {
			if (this.pos >= this.text.length) this.fail('unterminated string');
			if (this.startsWith('"""')) {
				this.pos += 3;
				return out + this.closingQuotes('"');
			}
			const ch = this.advance();
			if (ch !== '\\') {
				out += ch;
			} else if (/^[ \t]*\r?\n/.test(this.text.slice(this.pos))) {
				while (/[ \t\r\n]/.test(this.peek())) this.advance();
			} else {
				out += this.escape();
			}
		}
	}

	private multilineLiteral(): string {
		this.pos += 3;
		this.skipOpeningNewline();
		const end = this.text.indexOf("'''", this.pos);
		if (end < 0) this.fail('unterminated string');
		let out = '';
		while (this.pos < end) out += this.advance();
		this.pos += 3;
		return out + this.closingQuotes("'");
	}

	private array(): TomlValue[] {
		this.pos += 1;
		const out: TomlValue[] = [];
		for (;;) {
			this.skipBlank(true);
			if (this.peek() === ']') break;
			out.push(this.value());
			this.skipBlank(true);
			if (this.peek() !== ',') break;
			this.pos += 1;
		}
		if (this.peek() !== ']') this.fail("expected ']' or ','");
		this.pos += 1;
		return out;
	}

	private inlineTable(): TomlTable {
		this.pos += 1;
		const table = newTable();
		this.skipBlank(false);
		if (this.peek() === '}') {
			this.pos += 1;
			return table;
		}
		for (;;) {
			const line = this.line;
			const path = this.keyPath();
			if (this.peek() !== '=') this.fail("expected '='");
			this.pos += 1;
			this.skipBlank(false);
			this.assign(table, path, this.value(), line);
			this.skipBlank(false);
			if (this.peek() === '}') {
				this.pos += 1;
				return table;
			}
			if (this.peek() !== ',') this.fail("expected '}' or ','");
			this.pos += 1;
		}
	}
}

/**
 * Reads a TOML text.
 * @param text The TOML source.
 * @returns The tables, the lines of their headers and keys, and the errors.
 */
export function readToml(text: string): TomlDocument {
	return new Reader(text).read();
}
