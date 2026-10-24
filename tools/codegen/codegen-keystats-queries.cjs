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
 * @returns {{name: string, doc: string[], params: string[], texts: string[], segments: object[]}[]}
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
			const params = [...new Set(segs.filter((s) => s.param).map((s) => s.param))];
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
			queries.push({ name: current.name, doc: current.doc, params, texts, segments: segs });
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
 * @returns {({literal: string}|{param: string})[]} Dialect template.
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
			const value = params[seg.param];
			if (typeof value !== 'string')
				throw new TypeError(`${name} requires the string parameter ${seg.param}.`);
			return value;
		})
		.join('');
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
				const parts = template(query, dialect).map((seg) =>
					seg.literal !== undefined ? luaString(seg.literal) : `{ param = ${luaString(seg.param)} }`
				);
				return `\t\t\t${dialect} = {\n${parts.map((p) => `\t\t\t\t${p},`).join('\n')}\n\t\t\t},`;
			});
			return [
				`\t[${luaString(query.name)}] = {`,
				`\t\tparams = { ${query.params.map(luaString).join(', ')} },`,
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

--- In-process engines (Hammerspoon, AHK) and the Linux sqlite3 -json CLI.
M.DIALECTS = { ${DIALECTS.map(luaString).join(', ')} }

local QUERIES = {
${entries}
}

--- Renders a named query. Fails on an unknown name or dialect, a missing or
--- non-string parameter, and a parameter the query does not declare.
--- @param name string Catalogue name, such as "manifest.app_day".
--- @param dialect string "native" or "cli_json".
--- @param params table|nil Value of every declared parameter.
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

--- Lists every catalogue name, sorted.
--- @return table Array of names.
function M.names()
	local out = {}
	for name in pairs(QUERIES) do out[#out + 1] = name end
	table.sort(out)
	return out
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
			const parts = template(query, 'native').map((seg) =>
				seg.literal !== undefined
					? `"literal", ${ahkString(seg.literal)}`
					: `"param", ${ahkString(seg.param)}`
			);
			return `\t\t${ahkString(query.name)}, [\n${parts.map((p) => `\t\t\t[${p}]`).join(',\n')}\n\t\t]`;
		})
		.join(',\n');
	return `; _generated/keystats_queries.ahk

; Generated by tools/codegen/codegen-keystats-queries.cjs; do not edit.
; Source: _shared/data/db/queries.sql (the named keystats queries).

/**
 * Renders a named keystats query for the in-process SQLite engine.
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
