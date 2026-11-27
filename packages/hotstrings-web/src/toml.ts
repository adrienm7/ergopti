// packages/hotstrings-web/src/toml.ts

/**
 * Hotstring files: TOML v2, the common format of Ergopti's web tools and the
 * BookTool editor, and Ergopti's v1 personal format (personal_hotstrings.toml).
 *
 * v2 starts with `format = "ergopti-hotstrings/2"` and holds one
 * `[[hotstring]]` table per hotstring (see README.md). v1 holds `[[section]]`
 * tables whose keys are triggers with an inline table each:
 * `"btw" = { output = "by the way", is_word = true, auto_expand = false,
 * is_case_sensitive = false, final_result = false }`, optionally with
 * `is_case_sensitive_strict` and `priority`, and a `[_meta]` table. A v1 file
 * is mapped as Ergopti's readers do (windows/hotstrings/engine/catalogue/
 * personal_toml_io.ahk): `is_word` is `wordStart`, `auto_expand` is
 * `immediate`, `is_case_sensitive_strict` is `caseSensitive`,
 * `is_case_sensitive` alone is the literal casing (`conformCase: false`), the
 * section is a tag. `final_result` (whether a cascade may continue) has no
 * meaning without a cascade and is read but not kept.
 */

import { readToml, type TomlDocument, type TomlTable, type TomlValue } from './toml_reader.js';
import type { ExpandMode, Hotstring, TerminatorMode } from './types.js';

/** The value of the `format` key that marks a v2 file. */
export const FORMAT_V2 = 'ergopti-hotstrings/2';

/** A located problem in a hotstring file. */
export interface HotstringFileError {
	line: number;
	message: string;
}

/** A read hotstring file. */
export interface ParsedHotstrings {
	version: 1 | 2;
	hotstrings: Hotstring[];
	errors: HotstringFileError[];
}

const EXPAND_MODES: readonly ExpandMode[] = ['terminator', 'immediate', 'enter', 'tab', 'key'];
const TERMINATOR_MODES: readonly TerminatorMode[] = ['consume', 'echo'];
const V2_KEYS = new Set([
	'trigger',
	'output',
	'expand',
	'key',
	'terminator',
	'case_sensitive',
	'conform_case',
	'word_start',
	'priority',
	'description',
	'tags'
]);
const V1_KEYS = new Set([
	'output',
	'is_word',
	'auto_expand',
	'is_case_sensitive',
	'final_result',
	'is_case_sensitive_strict',
	'priority'
]);

class EntryError extends Error {}

function isTable(value: TomlValue | undefined): value is TomlTable {
	return typeof value === 'object' && !Array.isArray(value);
}

function isTableArray(value: TomlValue | undefined): value is TomlTable[] {
	return Array.isArray(value) && value.length > 0 && value.every(isTable);
}

/** Reads the typed fields of one table, failing on a wrong type. */
class Fields {
	constructor(private readonly table: TomlTable) {}

	private get(key: string): TomlValue | undefined {
		return Object.hasOwn(this.table, key) ? this.table[key] : undefined;
	}

	string(key: string, required: boolean): string | undefined {
		const value = this.get(key);
		if (value === undefined && !required) return undefined;
		if (typeof value !== 'string') throw new EntryError(`'${key}' must be a string`);
		return value;
	}

	boolean(key: string, required: boolean): boolean | undefined {
		const value = this.get(key);
		if (value === undefined && !required) return undefined;
		if (typeof value !== 'boolean') throw new EntryError(`'${key}' must be true or false`);
		return value;
	}

	integer(key: string): number | undefined {
		const value = this.get(key);
		if (value === undefined) return undefined;
		if (typeof value !== 'number' || !Number.isInteger(value)) {
			throw new EntryError(`'${key}' must be an integer`);
		}
		return value;
	}

	choice<T extends string>(key: string, allowed: readonly T[], fallback: T): T {
		const value = this.string(key, false) ?? fallback;
		if (!(allowed as readonly string[]).includes(value)) {
			throw new EntryError(`'${key}' must be one of ${allowed.join(', ')}`);
		}
		return value as T;
	}

	strings(key: string): string[] | undefined {
		const value = this.get(key);
		if (value === undefined) return undefined;
		if (!Array.isArray(value) || !value.every((item) => typeof item === 'string')) {
			throw new EntryError(`'${key}' must be an array of strings`);
		}
		return [...value] as string[];
	}

	unknown(known: Set<string>): string | undefined {
		return Object.keys(this.table).find((key) => !known.has(key));
	}
}

/** The line of a key: its own line, else the header line of the table it names. */
function lineOf(doc: TomlDocument, table: TomlTable, key: string): number {
	const own = doc.keyLines.get(table)?.get(key);
	if (own !== undefined) return own;
	const value = table[key];
	const named = Array.isArray(value) ? value[0] : value;
	return doc.tableLines.get(named as TomlTable) ?? 1;
}

function v2Entry(table: TomlTable): Hotstring {
	const fields = new Fields(table);
	const unknown = fields.unknown(V2_KEYS);
	if (unknown !== undefined) throw new EntryError(`unknown key '${unknown}'`);
	const trigger = fields.string('trigger', true) as string;
	if (trigger === '') throw new EntryError("'trigger' must not be empty");
	const expand = fields.choice('expand', EXPAND_MODES, 'terminator');
	const key = fields.string('key', false);
	if (expand === 'key' && !key) throw new EntryError('expand = "key" needs a \'key\'');
	const hotstring: Hotstring = {
		trigger,
		output: fields.string('output', true) as string,
		expand,
		terminator: fields.choice('terminator', TERMINATOR_MODES, 'echo'),
		caseSensitive: fields.boolean('case_sensitive', false) ?? false,
		wordStart: fields.boolean('word_start', false) ?? true
	};
	if (key !== undefined) hotstring.key = key;
	const conformCase = fields.boolean('conform_case', false);
	if (conformCase !== undefined) hotstring.conformCase = conformCase;
	const priority = fields.integer('priority');
	if (priority !== undefined) hotstring.priority = priority;
	const description = fields.string('description', false);
	if (description !== undefined) hotstring.description = description;
	const tags = fields.strings('tags');
	if (tags !== undefined) hotstring.tags = tags;
	return hotstring;
}

function v1Entry(trigger: string, value: TomlValue, section: string): Hotstring {
	if (!isTable(value)) throw new EntryError(`trigger '${trigger}' must hold an inline table`);
	const fields = new Fields(value);
	const unknown = fields.unknown(V1_KEYS);
	if (unknown !== undefined) throw new EntryError(`unsupported field '${unknown}'`);
	const literal = fields.boolean('is_case_sensitive', true) as boolean;
	const strict = fields.boolean('is_case_sensitive_strict', false) ?? false;
	fields.boolean('final_result', true);
	const hotstring: Hotstring = {
		trigger,
		output: fields.string('output', true) as string,
		expand: fields.boolean('auto_expand', true) ? 'immediate' : 'terminator',
		terminator: 'echo',
		caseSensitive: strict,
		wordStart: fields.boolean('is_word', true) as boolean,
		tags: [section]
	};
	if (literal && !strict) hotstring.conformCase = false;
	const priority = fields.integer('priority');
	if (priority !== undefined) hotstring.priority = priority;
	return hotstring;
}

function readV2(doc: TomlDocument, out: ParsedHotstrings): void {
	for (const key of Object.keys(doc.root)) {
		if (key !== 'format' && key !== 'hotstring') {
			out.errors.push({ line: lineOf(doc, doc.root, key), message: `unknown key '${key}'` });
		}
	}
	const list = doc.root.hotstring;
	if (list === undefined) return;
	if (!isTableArray(list)) {
		out.errors.push({
			line: lineOf(doc, doc.root, 'hotstring'),
			message: "'hotstring' must be an array of tables ([[hotstring]])"
		});
		return;
	}
	for (const table of list) {
		try {
			out.hotstrings.push(v2Entry(table));
		} catch (error) {
			const line = doc.tableLines.get(table) ?? lineOf(doc, doc.root, 'hotstring');
			out.errors.push({ line, message: (error as Error).message });
		}
	}
}

function readV1(doc: TomlDocument, out: ParsedHotstrings): void {
	for (const [section, value] of Object.entries(doc.root)) {
		if (section === '_meta' || !isTableArray(value)) continue;
		for (const table of value) {
			for (const [trigger, entry] of Object.entries(table)) {
				try {
					out.hotstrings.push(v1Entry(trigger, entry, section));
				} catch (error) {
					out.errors.push({ line: lineOf(doc, table, trigger), message: (error as Error).message });
				}
			}
		}
	}
}

/**
 * Reads a hotstring file, v2 or v1.
 * @param text The file's text.
 * @returns The version, the hotstrings read, and every problem with its line.
 */
export function parseHotstrings(text: string): ParsedHotstrings {
	const doc = readToml(text);
	const out: ParsedHotstrings = { version: 1, hotstrings: [], errors: [...doc.errors] };
	const format = doc.root.format;
	if (format === undefined) {
		readV1(doc, out);
	} else {
		out.version = 2;
		if (format === FORMAT_V2) readV2(doc, out);
		else {
			out.errors.push({
				line: lineOf(doc, doc.root, 'format'),
				message: `unsupported format ${JSON.stringify(format)}`
			});
		}
	}
	out.errors.sort((a, b) => a.line - b.line);
	return out;
}

/** Quotes a TOML basic string. */
export function quoteTomlString(value: string): string {
	let out = '"';
	for (const ch of value) {
		const code = ch.codePointAt(0) as number;
		if (ch === '"' || ch === '\\') out += `\\${ch}`;
		else if (ch === '\n') out += '\\n';
		else if (ch === '\t') out += '\\t';
		else if (ch === '\r') out += '\\r';
		else if (code < 0x20 || code === 0x7f) out += `\\u${code.toString(16).padStart(4, '0')}`;
		else out += ch;
	}
	return `${out}"`;
}

/**
 * Writes hotstrings as a v2 file.
 * @param list The hotstrings, written in this order.
 * @returns The TOML text, LF line endings, ending with a newline.
 */
export function serializeHotstrings(list: Hotstring[]): string {
	const lines = ['# Ergopti hotstrings, format 2', `format = ${quoteTomlString(FORMAT_V2)}`];
	for (const hotstring of list) {
		lines.push('', '[[hotstring]]');
		lines.push(`trigger = ${quoteTomlString(hotstring.trigger)}`);
		lines.push(`output = ${quoteTomlString(hotstring.output)}`);
		lines.push(`expand = ${quoteTomlString(hotstring.expand)}`);
		if (hotstring.key !== undefined) lines.push(`key = ${quoteTomlString(hotstring.key)}`);
		lines.push(`terminator = ${quoteTomlString(hotstring.terminator)}`);
		lines.push(`case_sensitive = ${hotstring.caseSensitive}`);
		if (hotstring.conformCase !== undefined) lines.push(`conform_case = ${hotstring.conformCase}`);
		lines.push(`word_start = ${hotstring.wordStart}`);
		if (hotstring.priority !== undefined) lines.push(`priority = ${hotstring.priority}`);
		if (hotstring.description !== undefined) {
			lines.push(`description = ${quoteTomlString(hotstring.description)}`);
		}
		if (hotstring.tags !== undefined) {
			lines.push(`tags = [${hotstring.tags.map(quoteTomlString).join(', ')}]`);
		}
	}
	return `${lines.join('\n')}\n`;
}
