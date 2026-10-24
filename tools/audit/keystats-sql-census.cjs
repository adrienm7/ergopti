// tools/audit/keystats-sql-census.cjs

/**
 * ==============================================================================
 * MODULE: Keystats SQL Census
 * DESCRIPTION:
 * Lists every SQL statement the three keystats drivers build from string
 * literals and groups them twice: by exact normalized text and by shape (the
 * statement kind, its target table, its projected expressions and its grouping,
 * with transport wrappers such as `json_quote(x) AS x_json` and column aliases
 * removed). The shared query catalogue is built from this census, and any shape
 * whose text differs between drivers is a parity finding.
 *
 * FEATURES & RATIONALE:
 * 1. Heuristic by design. The drivers concatenate SQL across lines and splice
 *    filters, identifiers and literals in between; the scanner keeps the literal
 *    parts of each concatenation chain and replaces every spliced expression by
 *    `?`, which is exactly the part a catalogue template parameterizes.
 * 2. Statements already moved into the catalogue are counted through the
 *    `Queries.render("name"` / `KeystatsQuery("name"` call sites, so the census
 *    keeps describing the code after migration instead of shrinking silently.
 *
 * USAGE:
 *   node tools/audit/keystats-sql-census.cjs           print the report
 *   node tools/audit/keystats-sql-census.cjs --json    print the raw census
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const BASE = path.join(ROOT, 'static', 'ergopti_plus');

// The keystats source trees of each driver. Tests are excluded: they quote SQL
// to assert on it, and counting those quotes would double every statement.
const DRIVERS = {
	windows: { dirs: ['windows/modules/keystats'], ext: '.ahk' },
	macos: { dirs: ['macos/modules/keystats'], ext: '.lua' },
	linux: { dirs: ['linux/modules/keystats'], ext: '.lua' },
	shared: { dirs: ['_shared/lua/keystats', '_shared/lua/sqlite'], ext: '.lua' }
};

// Words that open an SQL statement. A string literal whose text starts with one
// of them (case-insensitively) opens a statement chain.
const STATEMENT_START =
	/^\s*(SELECT|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|PRAGMA|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|ATTACH|DETACH|VACUUM|ANALYZE|REPLACE|WITH|REINDEX)\b/;

// ==========================================
// ==========================================
// ======= 1/ Literal chain extraction ======
// ==========================================
// ==========================================

/**
 * Splits source text into string literals, concatenation operators and other
 * code, keeping line numbers. Comments are dropped so commented-out SQL and
 * documentation that quotes SQL are not counted.
 * @param {string} text - File content.
 * @param {'.lua'|'.ahk'} ext - Language of the file.
 * @returns {{kind: string, value: string, line: number}[]} Token stream.
 */
function tokenize(text, ext) {
	const tokens = [];
	let i = 0;
	let line = 1;
	const lua = ext === '.lua';
	const push = (kind, value, at) => tokens.push({ kind, value, line: at });
	while (i < text.length) {
		const ch = text[i];
		if (ch === '\n') {
			line++;
			i++;
			push('newline', '\n', line);
			continue;
		}
		// Comments.
		if (lua && text.startsWith('--', i)) {
			const block = text.slice(i + 2).match(/^\[(=*)\[/);
			if (block) {
				const close = ']' + block[1] + ']';
				const end = text.indexOf(close, i);
				const stop = end < 0 ? text.length : end + close.length;
				line += (text.slice(i, stop).match(/\n/g) || []).length;
				i = stop;
				continue;
			}
			while (i < text.length && text[i] !== '\n') i++;
			continue;
		}
		if (!lua && ch === ';' && (i === 0 || /\s/.test(text[i - 1]))) {
			while (i < text.length && text[i] !== '\n') i++;
			continue;
		}
		if (
			!lua &&
			text.startsWith('/*', i) &&
			/(^|\n)\s*$/.test(text.slice(Math.max(0, i - 200), i))
		) {
			const end = text.indexOf('*/', i);
			const stop = end < 0 ? text.length : end + 2;
			line += (text.slice(i, stop).match(/\n/g) || []).length;
			i = stop;
			continue;
		}
		// Long Lua strings.
		if (lua && ch === '[') {
			const long = text.slice(i).match(/^\[(=*)\[/);
			if (long) {
				const close = ']' + long[1] + ']';
				const start = i + long[0].length;
				const end = text.indexOf(close, start);
				const stop = end < 0 ? text.length : end;
				const at = line;
				line += (text.slice(i, stop).match(/\n/g) || []).length;
				push('string', text.slice(start, stop), at);
				i = stop + close.length;
				continue;
			}
		}
		// Quoted strings. AHK escapes with a backtick, Lua with a backslash.
		if (ch === '"' || ch === "'") {
			const esc = lua ? '\\' : '`';
			let j = i + 1;
			let value = '';
			while (j < text.length && text[j] !== ch && text[j] !== '\n') {
				if (text[j] === esc && j + 1 < text.length) {
					const next = text[j + 1];
					value += next === 'n' ? '\n' : next === 't' ? '\t' : next;
					j += 2;
					continue;
				}
				value += text[j];
				j++;
			}
			push('string', value, line);
			i = j + 1;
			continue;
		}
		if (lua && text.startsWith('..', i)) {
			push('concat', '..', line);
			i += 2;
			continue;
		}
		if (!lua && ch === '.' && /\s/.test(text[i - 1] || ' ') && /\s/.test(text[i + 1] || ' ')) {
			push('concat', '.', line);
			i++;
			continue;
		}
		if (!lua && text.startsWith('.=', i)) {
			push('concat', '.=', line);
			i += 2;
			continue;
		}
		push('code', ch, line);
		i++;
	}
	return tokens;
}

/**
 * Collapses a token stream into concatenation chains. A chain is a run of
 * string literals and spliced expressions joined by concatenation operators;
 * the expressions become `?`. `string.format` placeholders and AHK `Format`
 * slots also become `?`.
 * @param {ReturnType<typeof tokenize>} tokens - Token stream.
 * @returns {{text: string, line: number}[]} Chains whose first literal is SQL.
 */
function chains(tokens) {
	const out = [];
	// The open chain, the code of the operand being read after an operator,
	// that operand's bracket depth, whether an operator awaits its operand, and
	// whether a line ended after a complete operand (the chain then continues
	// only when the next line opens with an operator).
	let current = null;
	let operand = '';
	let depth = 0;
	let sawConcat = false;
	let awaiting = false;
	const flush = () => {
		if (current && STATEMENT_START.test(current.parts[0] || '')) {
			out.push({ text: current.parts.join(''), line: current.line });
		}
		current = null;
		operand = '';
		depth = 0;
		sawConcat = false;
		awaiting = false;
	};
	const closeOperand = () => {
		if (operand.trim()) current.parts.push(' ? ');
		operand = '';
		depth = 0;
	};
	for (const token of tokens) {
		if (token.kind === 'string') {
			if (current && sawConcat && depth === 0) {
				closeOperand();
				current.parts.push(token.value);
				sawConcat = false;
				awaiting = false;
			} else if (current && sawConcat) {
				// A literal inside a spliced call, such as `Fn("x")`: part of the operand.
				operand += '"' + token.value + '"';
			} else {
				flush();
				current = { parts: [token.value], line: token.line };
			}
		} else if (token.kind === 'concat') {
			if (!current) continue;
			if (depth === 0) {
				closeOperand();
				sawConcat = true;
				awaiting = false;
			} else operand += token.value;
		} else if (token.kind === 'newline') {
			if (!current || depth > 0) continue;
			if (sawConcat && operand.trim()) {
				closeOperand();
				sawConcat = false;
				awaiting = true;
			} else if (!sawConcat) awaiting = true;
		} else {
			if (!current || !token.value.trim()) {
				if (current && sawConcat) operand += token.value;
				continue;
			}
			if (awaiting || !sawConcat) {
				flush();
				continue;
			}
			if (/[([{]/.test(token.value)) depth++;
			if (/[)\]}]/.test(token.value)) {
				if (depth === 0) {
					closeOperand();
					flush();
					continue;
				}
				depth--;
			}
			if (token.value === ',' && depth === 0) {
				closeOperand();
				flush();
				continue;
			}
			operand += token.value;
		}
	}
	flush();
	return out.map((c) => ({
		text: c.text.replace(/%[-0-9.]*[sdfqi]/g, '?').replace(/\{\d+\}/g, '?'),
		line: c.line
	}));
}

// ==================================
// ==================================
// ======= 2/ Normalization =========
// ==================================
// ==================================

/**
 * Splits a chain into statements on top-level semicolons.
 * @param {string} sql - Chain text.
 * @returns {string[]} Non-empty statements.
 */
function splitStatements(sql) {
	const out = [];
	let depth = 0;
	let quote = null;
	let start = 0;
	for (let i = 0; i < sql.length; i++) {
		const ch = sql[i];
		if (quote) {
			if (ch === quote) quote = null;
			continue;
		}
		if (ch === "'" || ch === '"') quote = ch;
		else if (ch === '(') depth++;
		else if (ch === ')') depth--;
		else if (ch === ';' && depth === 0) {
			out.push(sql.slice(start, i));
			start = i + 1;
		}
	}
	out.push(sql.slice(start));
	return out.map((s) => s.trim()).filter((s) => STATEMENT_START.test(s));
}

/**
 * Whitespace- and case-normalized text: the exact-identity key.
 * @param {string} sql - One statement.
 * @returns {string} Normalized text.
 */
function normalize(sql) {
	return sql
		.replace(/\s+/g, ' ')
		.replace(/\s*([(),=<>+*/|-])\s*/g, '$1')
		.replace(/(\?\s*)+/g, '?')
		.replace(/([a-z0-9_)])\?/g, '$1 ?')
		.trim()
		.toLowerCase();
}

/**
 * Shape key: the normalized text without transport wrappers and aliases, so a
 * CLI driver's `json_quote(app) AS app_json` matches an in-process `app`.
 * @param {string} sql - One statement.
 * @returns {string} Shape key.
 */
function shape(sql) {
	return normalize(sql)
		.replace(/json_quote\(([a-z_.]+)\)as [a-z_]+_json/g, '$1')
		.replace(/json_quote\((max|min)\(([a-z_.]+)\)\)as [a-z_]+_json/g, '$1($2)')
		.replace(/\bas [a-z_]+/g, '')
		.replace(/\bwhere\b.*?(?=\bgroup by\b|\border by\b|\blimit\b|$)/, 'where ? ')
		.replace(/\?+/g, '?')
		.replace(/\s+/g, ' ')
		.trim();
}

/**
 * Names the statement family: its kind and the table it reads or writes.
 * @param {string} sql - One statement.
 * @returns {string} Family label such as `select agg_app_day`.
 */
function family(sql) {
	const n = normalize(sql);
	const kind = n.split(/[ (]/)[0];
	const target =
		n.match(/\binsert(?: or [a-z]+)? into ([a-z0-9_?]+)/) ||
		n.match(/\bupdate ([a-z0-9_?]+) set\b/) ||
		n.match(/\bdelete from ([a-z0-9_?]+)/) ||
		n.match(
			/\bcreate (?:temp |temporary )?(?:table|index|trigger|view)(?: if not exists)? ([a-z0-9_?.]+)/
		) ||
		n.match(/\bdrop (?:table|index|trigger|view)(?: if exists)? ([a-z0-9_?.]+)/) ||
		n.match(/\bfrom ([a-z0-9_?]+)/) ||
		n.match(/^pragma ([a-z0-9_?.]+)/);
	return target ? `${kind} ${target[1]}` : kind;
}

// =====================================
// =====================================
// ======= 3/ Census and report ========
// =====================================
// =====================================

/**
 * Walks one directory tree for source files of an extension.
 * @param {string} dir - Absolute directory.
 * @param {string} ext - Extension filter.
 * @returns {string[]} Absolute file paths, sorted.
 */
function walk(dir, ext) {
	if (!fs.existsSync(dir)) return [];
	const out = [];
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const abs = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name === 'tests') continue;
			out.push(...walk(abs, ext));
		} else if (entry.name.endsWith(ext)) out.push(abs);
	}
	return out.sort();
}

/**
 * Builds the census of every driver.
 * @returns {{driver: string, file: string, line: number, sql: string, family: string, exact: string, shape: string}[]}
 */
function census() {
	const rows = [];
	for (const [driver, spec] of Object.entries(DRIVERS)) {
		for (const dir of spec.dirs) {
			for (const file of walk(path.join(BASE, dir), spec.ext)) {
				const text = fs.readFileSync(file, 'utf8');
				const rel = path.relative(BASE, file).split(path.sep).join('/');
				for (const chain of chains(tokenize(text, spec.ext))) {
					for (const sql of splitStatements(chain.text)) {
						rows.push({
							driver,
							file: rel,
							line: chain.line,
							sql: sql.replace(/\s+/g, ' ').trim(),
							family: family(sql),
							exact: normalize(sql),
							shape: shape(sql)
						});
					}
				}
				// Catalogue call sites: one statement each, identified by name.
				const callSite = /(?:Queries\.render|KeystatsQuery)\(\s*["']([a-z0-9_.]+)["']/g;
				let match;
				while ((match = callSite.exec(text))) {
					const line = text.slice(0, match.index).split('\n').length;
					rows.push({
						driver,
						file: rel,
						line,
						sql: `catalogue:${match[1]}`,
						family: `catalogue ${match[1]}`,
						exact: `catalogue:${match[1]}`,
						shape: `catalogue:${match[1]}`
					});
				}
			}
		}
	}
	return rows;
}

/**
 * Renders the Markdown report from a census.
 * @param {ReturnType<typeof census>} rows - Census rows.
 * @returns {string} Report text.
 */
function report(rows) {
	const drivers = ['windows', 'macos', 'linux', 'shared'];
	const count = (pred) =>
		Object.fromEntries(
			drivers.map((d) => [d, rows.filter((r) => r.driver === d && pred(r)).length])
		);
	const lines = [];
	const total = count(() => true);
	lines.push('| Driver | Statements | Distinct exact | Distinct shapes |');
	lines.push('| --- | --- | --- | --- |');
	for (const d of drivers) {
		const mine = rows.filter((r) => r.driver === d);
		lines.push(
			`| ${d} | ${total[d]} | ${new Set(mine.map((r) => r.exact)).size} | ${new Set(mine.map((r) => r.shape)).size} |`
		);
	}
	const byShape = new Map();
	for (const r of rows) {
		if (!byShape.has(r.shape)) byShape.set(r.shape, []);
		byShape.get(r.shape).push(r);
	}
	const shared = [...byShape.entries()].filter(
		([, rs]) => new Set(rs.map((r) => r.driver)).size > 1
	);
	lines.push('');
	lines.push(`Shapes present in more than one driver: ${shared.length}.`);
	lines.push('');
	lines.push('| Family | Drivers | Exact texts | Sites |');
	lines.push('| --- | --- | --- | --- |');
	for (const [, rs] of shared.sort((a, b) => a[1][0].family.localeCompare(b[1][0].family))) {
		const ds = [...new Set(rs.map((r) => r.driver))].join(', ');
		const exact = new Set(rs.map((r) => r.exact)).size;
		const sites = rs.map((r) => `${r.file}:${r.line}`).join('<br>');
		lines.push(`| \`${rs[0].family}\` | ${ds} | ${exact} | ${sites} |`);
	}
	const byFamily = new Map();
	for (const r of rows) {
		if (!byFamily.has(r.family)) byFamily.set(r.family, new Map());
		const m = byFamily.get(r.family);
		if (!m.has(r.shape)) m.set(r.shape, new Set());
		m.get(r.shape).add(r.driver);
	}
	lines.push('');
	lines.push('Families whose shape differs between drivers (one line per shape):');
	lines.push('');
	lines.push('| Family | Shape drivers |');
	lines.push('| --- | --- |');
	for (const [fam, shapes] of [...byFamily.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
		const ds = new Set([...shapes.values()].flatMap((s) => [...s]));
		if (shapes.size < 2 || ds.size < 2) continue;
		lines.push(`| \`${fam}\` | ${[...shapes.values()].map((s) => [...s].join('+')).join(' / ')} |`);
	}
	return lines.join('\n') + '\n';
}

if (require.main === module) {
	const rows = census();
	if (process.argv.includes('--json'))
		process.stdout.write(JSON.stringify(rows, null, '\t') + '\n');
	else process.stdout.write(report(rows));
}

module.exports = { tokenize, chains, splitStatements, normalize, shape, family, census, report };
