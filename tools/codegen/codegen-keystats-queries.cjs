// tools/codegen/codegen-keystats-queries.cjs

/**
 * ==============================================================================
 * MODULE: Keystats Named-Query Codegen
 * DESCRIPTION:
 * Compiles `_shared/data/db/queries.sql`, the one catalogue of keystats SQL that
 * more than one driver runs, into a Lua module read by macOS and Linux and an
 * AHK function read by Windows. A driver renders a query by name with its own
 * filter clause; it never retypes the SQL, so the three drivers cannot drift.
 *
 * FEATURES & RATIONALE:
 * 1. Two dialects decided here, not at run time. In-process engines
 *    (Hammerspoon's hs.sqlite3, the AHK sqlite3.dll) read a TEXT column as is;
 *    the Linux sqlite3 CLI's JSON mode cuts raw TEXT at NUL, so its dialect
 *    selects `json_quote(<expr>) AS <name>_json`. The `{{text …}}` placeholder
 *    names the column once and both spellings are derived from it.
 * 2. Templates are precompiled into literal and parameter segments, so the
 *    runtime renderer is a concatenation with no pattern substitution: a `%`
 *    or a `{{` inside a filter value cannot be reinterpreted.
 * 3. Fail fast: an unknown placeholder, a duplicate name, an unterminated
 *    query or a body comment aborts generation instead of shipping a template
 *    that renders something else.
 * 4. Typed value slots for write statements. `{{s name}}` renders a TEXT
 *    literal, `{{i name}}` an integer and `{{r name}}` a real; a trailing `?` on
 *    the kind (`{{s? name}}`) renders NULL for a missing value and every other
 *    slot refuses one. The driver passes the raw Lua value and the generated
 *    renderer quotes it through the one shared literal encoder
 *    (sqlite.literal), so no driver formats a value into SQL by hand.
 *    `{{merge column}}` expands at generation time into the expression that
 *    sums a stored JSON number map with the incoming one key by key, the one
 *    accumulation every driver shares.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE = 'static/ergopti_plus/_shared/data/db/queries.sql';
const LUA_OUTPUT = 'static/ergopti_plus/_shared/lua/keystats/queries.lua';
const AHK_OUTPUT = 'static/ergopti_plus/windows/_generated/keystats_queries.ahk';

// The dialects every query is compiled for. "native" is the in-process engine
// spelling (macOS, Windows); "cli_json" is the Linux sqlite3 -json spelling.
const DIALECTS = ['native', 'cli_json'];

const NAME = /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/;
const PARAM = /^[a-z][a-z0-9_]*$/;
const IDENTIFIER = /^[a-z_][a-z0-9_]*$/;
const SLOT = /^([sir])(\?)?\s+([a-z][a-z0-9_]*)$/;

// The JSON number-map columns a `{{merge column}}` may name.
const MERGE_COLUMNS = new Set(['esrc_json', 'e_buckets_json', 'length_buckets_json']);

/**
 * The expression that adds an incoming JSON number map to the stored one, key
 * by key. Both maps are read with json_each, so a key present in only one of
 * them survives, a NULL stored map counts as empty, and a key is quoted by
 * json_quote so punctuation in it cannot alter the merged document.
 * @param {string} column - One of MERGE_COLUMNS.
 * @returns {string} SQL expression.
 */
function mergeExpression(column) {
	return (
		"(SELECT COALESCE('{' || group_concat(json_quote(k) || ':' || v, ',') || '}', '{}') FROM (" +
		`SELECT key AS k, SUM(value) AS v FROM (SELECT key, value FROM json_each(COALESCE(${column}, '{}')) ` +
		`UNION ALL SELECT key, value FROM json_each(COALESCE(excluded.${column}, '{}'))) GROUP BY key))`
	);
}

// ===================================
// ===================================
// ======= 1/ Catalogue parsing ======
// ===================================
// ===================================

/**
 * Collapses whitespace runs to one space outside quoted SQL literals, so the
 * generated constants stay single-line without altering a literal's bytes.
 * @param {string} sql - Query body.
 * @returns {string} Collapsed body.
 */
function collapse(sql) {
	let out = '';
	let quote = null;
	let space = false;
	for (const ch of sql) {
		if (quote) {
			out += ch;
			if (ch === quote) quote = null;
			continue;
		}
		if (/\s/.test(ch)) {
			space = true;
			continue;
		}
		if (space && out !== '') out += ' ';
		space = false;
		if (ch === "'" || ch === '"') quote = ch;
		out += ch;
	}
	if (quote) throw new SyntaxError('Unterminated SQL literal in a catalogue query.');
	return out;
}

/**
 * Splits a template into literal, parameter and text-column segments.
 * @param {string} name - Query name, for errors.
 * @param {string} body - Collapsed query body.
 * @returns {({literal: string}|{param: string}|{text: {expr: string, alias: string}})[]} Segments.
 */
function segments(name, body) {
	const out = [];
	let rest = body;
	while (rest.length > 0) {
		const open = rest.indexOf('{{');
		if (open < 0) {
			out.push({ literal: rest });
			break;
		}
		if (open > 0) out.push({ literal: rest.slice(0, open) });
		const close = rest.indexOf('}}', open);
		if (close < 0) throw new SyntaxError(`${name}: unterminated placeholder.`);
		const inner = rest.slice(open + 2, close).trim();
		const text = inner.match(/^text\s+(.+)$/);
		if (text) {
			const aliased = text[1].match(/^(.*\S)\s+AS\s+([a-z_][a-z0-9_]*)$/);
			const expr = aliased ? aliased[1] : text[1];
			const alias = aliased ? aliased[2] : text[1];
			if (!IDENTIFIER.test(alias))
				throw new SyntaxError(`${name}: a text column needs a column name or "EXPR AS name".`);
			out.push({ text: { expr, alias } });
		} else if (SLOT.test(inner)) {
			const [, kind, nullable, slot] = inner.match(SLOT);
			out.push({ slot: { name: slot, kind, nullable: nullable === '?' } });
		} else if (/^merge\s+/.test(inner)) {
			const column = inner.replace(/^merge\s+/, '');
			if (!MERGE_COLUMNS.has(column))
				throw new SyntaxError(`${name}: {{merge ${column}}} names no JSON number-map column.`);
			out.push({ literal: mergeExpression(column) });
		} else if (PARAM.test(inner)) {
			out.push({ param: inner });
		} else {
			throw new SyntaxError(`${name}: unknown placeholder {{${inner}}}.`);
		}
		rest = rest.slice(close + 2);
	}
	return out;
}

/**
 * Parses the catalogue into ordered query records.
 * @param {string} text - Catalogue content.
 * @returns {{name: string, doc: string[], params: string[], slots: Map<string, {kind: string, nullable: boolean}>, texts: string[], segments: object[]}[]}
 */
function parse(text) {
	const queries = [];
	const names = new Set();
	let current = null;
	const lines = text.replace(/\r\n/g, '\n').split('\n');
	lines.forEach((line, index) => {
		const where = `queries.sql:${index + 1}`;
		const header = line.match(/^--\s*name:\s*(\S+)\s*$/);
		if (header) {
			if (current) throw new SyntaxError(`${where}: query ${current.name} is not terminated.`);
			if (!NAME.test(header[1]))
				throw new SyntaxError(`${where}: invalid query name ${header[1]}.`);
			if (names.has(header[1])) throw new SyntaxError(`${where}: duplicate query ${header[1]}.`);
			names.add(header[1]);
			current = { name: header[1], doc: [], body: [] };
			return;
		}
		if (!current) return;
		const doc = line.match(/^--\s*doc:\s?(.*)$/);
		if (doc && current.body.length === 0) {
			current.doc.push(doc[1]);
			return;
		}
		if (/^\s*--/.test(line))
			throw new SyntaxError(`${where}: comments inside ${current.name} would reach the SQL text.`);
		if (line.trim() === '' && current.body.length === 0) return;
		if (line.trim() === '') throw new SyntaxError(`${where}: blank line inside ${current.name}.`);
		current.body.push(line);
		if (/;\s*$/.test(line)) {
			const body = collapse(current.body.join('\n'));
			if (body.indexOf(';') !== body.length - 1)
				throw new SyntaxError(`${where}: ${current.name} must hold exactly one statement.`);
			const segs = segments(current.name, body);
			const params = [];
			const slots = new Map();
			for (const seg of segs) {
				const name = seg.param ?? seg.slot?.name;
				if (name === undefined) continue;
				if (seg.slot) {
					const known = slots.get(name);
					if (known && (known.kind !== seg.slot.kind || known.nullable !== seg.slot.nullable))
						throw new SyntaxError(`${where}: ${current.name} gives the slot ${name} two kinds.`);
					if (!known && params.includes(name))
						throw new SyntaxError(
							`${where}: ${current.name} uses ${name} as a slot and a parameter.`
						);
					slots.set(name, { name, ...seg.slot });
				} else if (slots.has(name)) {
					throw new SyntaxError(
						`${where}: ${current.name} uses ${name} as a slot and a parameter.`
					);
				}
				if (!params.includes(name)) params.push(name);
			}
			// A UNION repeats its projection: the same column may recur, but one
			// name for two expressions would decode one as the other.
			const exprOf = new Map();
			for (const seg of segs.filter((s) => s.text)) {
				if (exprOf.has(seg.text.alias) && exprOf.get(seg.text.alias) !== seg.text.expr)
					throw new SyntaxError(
						`${where}: ${current.name} names two text columns ${seg.text.alias}.`
					);
				exprOf.set(seg.text.alias, seg.text.expr);
			}
			const texts = [...exprOf.keys()];
			queries.push({ name: current.name, doc: current.doc, params, slots, texts, segments: segs });
			current = null;
		}
	});
	if (current) throw new SyntaxError(`queries.sql: query ${current.name} is not terminated.`);
	if (queries.length === 0) throw new SyntaxError('queries.sql declares no query.');
	return queries;
}

/**
 * Resolves the text columns of a query for one dialect, merging adjacent
 * literals, so each template is an alternation of literals and parameters.
 * @param {ReturnType<typeof parse>[number]} query - Parsed query.
 * @param {string} dialect - One of DIALECTS.
 * @returns {({literal: string}|{param: string}|{slot: object})[]} Dialect template.
 */
function template(query, dialect) {
	if (!DIALECTS.includes(dialect)) throw new RangeError(`Unknown dialect ${dialect}.`);
	const out = [];
	const pushLiteral = (value) => {
		const last = out[out.length - 1];
		if (last && last.literal !== undefined) last.literal += value;
		else out.push({ literal: value });
	};
	for (const seg of query.segments) {
		if (seg.literal !== undefined) pushLiteral(seg.literal);
		else if (seg.param !== undefined) out.push({ param: seg.param });
		else if (seg.slot !== undefined) out.push({ slot: seg.slot });
		else if (dialect === 'cli_json')
			pushLiteral(`json_quote(${seg.text.expr}) AS ${seg.text.alias}_json`);
		else
			pushLiteral(
				seg.text.expr === seg.text.alias ? seg.text.expr : `${seg.text.expr} AS ${seg.text.alias}`
			);
	}
	return out;
}

/**
 * Renders a query in one dialect. Mirrors the generated runtime renderers and
 * is what the catalogue tests execute.
 * @param {ReturnType<typeof parse>} queries - Parsed catalogue.
 * @param {string} name - Query name.
 * @param {string} dialect - One of DIALECTS.
 * @param {Record<string, string>} params - Value of every declared parameter.
 * @returns {string} SQL text.
 */
function render(queries, name, dialect, params = {}) {
	const query = queries.find((q) => q.name === name);
	if (!query) throw new RangeError(`Unknown keystats query ${name}.`);
	for (const key of Object.keys(params))
		if (!query.params.includes(key)) throw new RangeError(`${name} declares no parameter ${key}.`);
	return template(query, dialect)
		.map((seg) => {
			if (seg.literal !== undefined) return seg.literal;
			if (seg.slot !== undefined) return renderSlot(name, seg.slot, params[seg.slot.name]);
			const value = params[seg.param];
			if (typeof value !== 'string')
				throw new TypeError(`${name} requires the string parameter ${seg.param}.`);
			return value;
		})
		.join('');
}

/**
 * Encodes content for a single-quoted SQLite value exactly as
 * _shared/lua/sqlite/literal.lua does: quotes doubled, CR and NUL spelled as
 * SQL char() expressions so no native boundary can cut them.
 * @param {string} value - Raw content.
 * @returns {string} Escaped content.
 */
function escapeLiteral(value) {
	return value
		.replaceAll("'", "''")
		.replaceAll('\r', "'||char(13)||'")
		.replaceAll('\0', "'||char(0)||'");
}

/**
 * Formats a finite number like C's "%.17g": the shortest fixed or exponent
 * spelling that carries 17 significant digits, trailing zeros removed. The
 * generated Lua renderer formats a real exactly this way, so the stored double
 * is the one the driver held.
 * @param {number} value - Finite number.
 * @returns {string} Text.
 */
function formatReal(value) {
	if (value === 0) return Object.is(value, -0) ? '-0' : '0';
	const [mantissa, exponentText] = value.toExponential(16).split('e');
	const exponent = Number(exponentText);
	if (exponent < -4 || exponent >= 17) {
		const digits = mantissa.replace(/\.?0+$/, '');
		const sign = exponent < 0 ? '-' : '+';
		return `${digits}e${sign}${String(Math.abs(exponent)).padStart(2, '0')}`;
	}
	const fixed = value.toFixed(Math.max(0, 16 - exponent));
	return fixed.includes('.') ? fixed.replace(/\.?0+$/, '') : fixed;
}

/**
 * Renders one typed slot. An absent value is NULL for a nullable slot and an
 * error for any other; an integer slot floors its number.
 * @param {string} name - Query name, for errors.
 * @param {{name: string, kind: string, nullable: boolean}} slot - Slot.
 * @param {unknown} value - Raw value.
 * @returns {string} SQL text.
 */
function renderSlot(name, slot, value) {
	if (value === undefined || value === null) {
		if (slot.nullable) return 'NULL';
		throw new TypeError(`${name} requires the value ${slot.name}.`);
	}
	if (slot.kind === 's') {
		if (typeof value !== 'string') throw new TypeError(`${name}: ${slot.name} must be a string.`);
		return `'${escapeLiteral(value)}'`;
	}
	if (typeof value !== 'number' || !Number.isFinite(value))
		throw new TypeError(`${name}: ${slot.name} must be a finite number.`);
	return slot.kind === 'i' ? String(Math.floor(value)) : formatReal(value);
}

// ===================================
// ===================================
// ======= 2/ Output rendering =======
// ===================================
// ===================================

/** Quotes a Lua string literal. */
function luaString(value) {
	return JSON.stringify(value);
}

/** Quotes an AHK expression string without turning SQL into executable code. */
function ahkString(value) {
	return '"' + value.replaceAll('`', '``').replaceAll('"', '`"').replaceAll(';', '`;') + '"';
}

/**
 * Builds the shared Lua module.
 * @param {ReturnType<typeof parse>} queries - Parsed catalogue.
 * @returns {string} Lua source.
 */
function renderLua(queries) {
	const entries = queries
		.map((query) => {
			const dialects = DIALECTS.map((dialect) => {
				const parts = template(query, dialect).map((seg) => {
					if (seg.literal !== undefined) return luaString(seg.literal);
					if (seg.slot !== undefined)
						return `{ slot = ${luaString(seg.slot.name)}, kind = ${luaString(seg.slot.kind)}, nullable = ${seg.slot.nullable} }`;
					return `{ param = ${luaString(seg.param)} }`;
				});
				return `\t\t\t${dialect} = {\n${parts.map((p) => `\t\t\t\t${p},`).join('\n')}\n\t\t\t},`;
			});
			return [
				`\t[${luaString(query.name)}] = {`,
				`\t\tparams = { ${query.params.map(luaString).join(', ')} },`,
				`\t\tslots = { ${[...query.slots.values()].map((slot) => `{ ${luaString(slot.name)}, ${luaString(slot.kind)}, ${slot.nullable} }`).join(', ')} },`,
				`\t\ttexts = { ${query.texts.map(luaString).join(', ')} },`,
				'\t\ttemplates = {',
				...dialects,
				'\t\t},',
				'\t},'
			].join('\n');
		})
		.join('\n');
	return `--- _shared/lua/keystats/queries.lua

--- Generated by tools/codegen/codegen-keystats-queries.cjs; do not edit.
--- Source: _shared/data/db/queries.sql (the named keystats queries).
local M = {}

local TableUtil = require("table_util")
local Literal = require("sqlite.literal")

--- In-process engines (Hammerspoon, AHK) and the Linux sqlite3 -json CLI.
M.DIALECTS = { ${DIALECTS.map(luaString).join(', ')} }

local QUERIES = {
${entries}
}

--- Renders one typed slot. An absent value is NULL for a nullable slot and an
--- error for any other; a text slot is quoted through sqlite.literal; an
--- integer slot floors its number; a real slot keeps 17 significant digits.
--- @param name string Query name, for errors.
--- @param part table Slot part { slot, kind, nullable }.
--- @param value any Raw value.
--- @return string SQL text.
local function render_slot(name, part, value)
	if value == nil then
		if part.nullable then return "NULL" end
		error(name .. " requires the value " .. part.slot, 3)
	end
	if part.kind == "s" then
		if type(value) ~= "string" then error(name .. ": " .. part.slot .. " must be a string", 3) end
		return "'" .. Literal.escape(value) .. "'"
	end
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error(name .. ": " .. part.slot .. " must be a finite number", 3)
	end
	if part.kind == "r" then return string.format("%.17g", value) end
	return string.format("%d", math.floor(value))
end

--- Renders a named query. Fails on an unknown name or dialect, a missing or
--- non-string parameter, a missing or mistyped slot value, and a parameter the
--- query does not declare.
--- @param name string Catalogue name, such as "manifest.app_day".
--- @param dialect string "native" or "cli_json".
--- @param params table|nil Raw string of every declared parameter, raw value of every slot.
--- @return string The SQL text.
function M.render(name, dialect, params)
	local query = QUERIES[name]
	if not query then error("Unknown keystats query: " .. tostring(name), 2) end
	local parts = type(dialect) == "string" and query.templates[dialect] or nil
	if not parts then
		error("Unknown keystats query dialect: " .. tostring(dialect), 2)
	end
	params = params or {}
	if type(params) ~= "table" then error(name .. " parameters must be a table", 2) end
	for key in pairs(params) do
		local declared = false
		for _, param in ipairs(query.params) do
			if param == key then declared = true end
		end
		if not declared then error(name .. " declares no parameter " .. tostring(key), 2) end
	end
	local out = {}
	for index, part in ipairs(parts) do
		if type(part) == "string" then
			out[index] = part
		elseif part.slot then
			out[index] = render_slot(name, part, params[part.slot])
		else
			local value = params[part.param]
			if type(value) ~= "string" then
				error(name .. " requires the string parameter " .. part.param, 2)
			end
			out[index] = value
		end
	end
	return table.concat(out)
end

--- Lists the TEXT columns a query projects; the CLI dialect names each one
--- "<column>_json".
--- @param name string Catalogue name.
--- @return table Array of column names.
function M.text_columns(name)
	local query = QUERIES[name]
	if not query then error("Unknown keystats query: " .. tostring(name), 2) end
	local out = {}
	for index, column in ipairs(query.texts) do out[index] = column end
	return out
end

--- Lists the parameters a query declares, in first-use order.
--- @param name string Catalogue name.
--- @return table Array of parameter names.
function M.params(name)
	local query = QUERIES[name]
	if not query then error("Unknown keystats query: " .. tostring(name), 2) end
	local out = {}
	for index, param in ipairs(query.params) do out[index] = param end
	return out
end

--- Lists the typed value slots a query declares, in first-use order.
--- @param name string Catalogue name.
--- @return table Array of { name, kind ("s", "i" or "r"), nullable }.
function M.slots(name)
	local query = QUERIES[name]
	if not query then error("Unknown keystats query: " .. tostring(name), 2) end
	local out = {}
	for index, slot in ipairs(query.slots) do
		out[index] = { name = slot[1], kind = slot[2], nullable = slot[3] }
	end
	return out
end

--- Lists every catalogue name, sorted.
--- @return table Array of names.
function M.names()
	return TableUtil.sorted_keys(QUERIES)
end

return M
`;
}

/**
 * Builds the Windows function. Windows runs the in-process dialect only.
 * @param {ReturnType<typeof parse>} queries - Parsed catalogue.
 * @returns {string} AHK source (without the BOM).
 */
function renderAhk(queries) {
	const entries = queries
		.map((query) => {
			const parts = template(query, 'native').map((seg) => {
				if (seg.literal !== undefined) return `"literal", ${ahkString(seg.literal)}`;
				if (seg.slot !== undefined)
					return `"slot", ${ahkString(seg.slot.name)}, ${ahkString(seg.slot.kind + (seg.slot.nullable ? '?' : ''))}`;
				return `"param", ${ahkString(seg.param)}`;
			});
			return `\t\t${ahkString(query.name)}, [\n${parts.map((p) => `\t\t\t[${p}]`).join(',\n')}\n\t\t]`;
		})
		.join(',\n');
	return `; _generated/keystats_queries.ahk

; Generated by tools/codegen/codegen-keystats-queries.cjs; do not edit.
; Source: _shared/data/db/queries.sql (the named keystats queries).

/**
 * Renders a named keystats query for the in-process SQLite engine. Queries with
 * typed value slots (the write statements) are refused until Windows adopts them.
 * @param {string} Name - Catalogue name, such as "manifest.app_day".
 * @param {Map} Params - Value of every parameter the query declares.
 * @returns {string} The SQL text.
 */
KeystatsQuery(Name, Params := Map()) {
\tstatic Queries := Map(
${entries}
\t)
\tif !Queries.Has(Name)
\t\tthrow ValueError("Unknown keystats query: " . Name)
\tif !(Params is Map)
\t\tthrow TypeError(Name . " parameters must be a Map.")
\tParts := Queries[Name]
\tfor Key in Params {
\t\tDeclared := false
\t\tfor Part in Parts
\t\t\tif (Part[1] = "param" && Part[2] == Key)
\t\t\t\tDeclared := true
\t\tif !Declared
\t\t\tthrow ValueError(Name . " declares no parameter " . Key)
\t}
\tSql := ""
\tfor Part in Parts {
\t\tif (Part[1] = "literal") {
\t\t\tSql .= Part[2]
\t\t\tcontinue
\t\t}
\t\tif !Params.Has(Part[2]) || !(Params[Part[2]] is String)
\t\t\tthrow ValueError(Name . " requires the string parameter " . Part[2])
\t\tSql .= Params[Part[2]]
\t}
\treturn Sql
}
`;
}

/**
 * Regenerates both outputs from the catalogue.
 * @param {string} root - Repository root.
 */
function main(root = ROOT) {
	const queries = parse(fs.readFileSync(path.join(root, SOURCE), 'utf8'));
	for (const [file, content] of [
		[LUA_OUTPUT, renderLua(queries)],
		[AHK_OUTPUT, '﻿' + renderAhk(queries)]
	]) {
		const target = path.join(root, file);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.writeFileSync(target, content, 'utf8');
	}
}

module.exports = {
	DIALECTS,
	SOURCE,
	LUA_OUTPUT,
	AHK_OUTPUT,
	collapse,
	parse,
	template,
	render,
	renderLua,
	renderAhk,
	main
};
if (require.main === module) main();
