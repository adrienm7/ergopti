// tools/audit/shared-literal-inventory.cjs

/**
 * ==============================================================================
 * MODULE: Shared Literal and Logic Inventory (Rule A)
 * DESCRIPTION:
 * Lists what the three drivers declare by hand that belongs in _shared: named
 * constants (durations, sizes and limits, colours, file names, enum and key
 * names), bare timer delays, and Lua functions or data tables that macOS and
 * Linux both carry. Each item gets a kind, a proposed shared home and name,
 * and the mechanism that fits it (a shared data file every driver reads, a
 * generated constant, or one Lua module).
 *
 * It is a measurement for docs/design/structure-plan.md, not a gate: the
 * detectors are lexical and over-report on purpose, so the ratchet
 * (tools/test/test-shared-literal-inventory.cjs) holds the counts per driver
 * and kind, which can only go down, rather than each line.
 *
 * USAGE:
 *   node tools/audit/shared-literal-inventory.cjs            print the summary
 *   node tools/audit/shared-literal-inventory.cjs --write    rewrite the appendix
 *   node tools/audit/shared-literal-inventory.cjs --json     print the counts
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { stripComments } = require('../lib/script-source.cjs');
const Census = require('./structure/census.cjs');
const Rules = require('./structure/rules.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const PREFIX = `${Census.BASE}/`;
const OUT_DIR = 'docs/design/structure-plan';

// Production driver source only: tests, vendored and generated code are not
// the drivers' own declarations.
const EXCLUDED = /(^|\/)(tests?|vendor|_generated|launcher|apps)(\/|$)/;

// ──────────────────────────────────────────────────────────────────────────────
// Kinds
// ──────────────────────────────────────────────────────────────────────────────

// Ordered: the first matching kind wins.
const NAME_KINDS = [
	[
		'duration',
		/(^|_)(MS|SEC|SECS|SECONDS|TIMEOUT|DELAY|INTERVAL|DURATION|TTL|PERIOD|WAIT|BACKOFF|DEBOUNCE|THROTTLE|GRACE|POLL)(_|$)/
	],
	[
		'limit',
		/(^|_)(BYTES|MAX|MIN|LIMIT|CAP|SIZE|COUNT|THRESHOLD|LEN|LENGTH|CAPACITY|DEPTH|RETRIES|ATTEMPTS|WIDTH|HEIGHT|MARGIN|PADDING|RADIUS|ALPHA|OPACITY)(_|$)/
	],
	['color', /(^|_)(COLOR|COLOUR|BG|FG|TINT)(_|$)/]
];

const HOMES = {
	duration: {
		home: '_shared/core/timing/data/constants.toml',
		mechanism: 'shared data file every driver reads at boot (Timings.ms/sec, TimingsGet)'
	},
	limit: {
		home: '_shared/core/timing/data/constants.toml [limits] or _shared/<domain>/constants.toml',
		mechanism: 'shared data file every driver reads at boot'
	},
	color: {
		home: '_shared/core/ui/data/native_theme.toml (native) or _shared/ui/theme_tokens.js (web)',
		mechanism: 'shared data file; AHK and Lua read native_theme.toml'
	},
	path_name: {
		home: '_shared/core/text/data/identifiers.json',
		mechanism: 'generated constant (tools/codegen/codegen-identifiers.cjs)'
	},
	enum_name: {
		home: '_shared/<domain>/*.json, projected by a generator',
		mechanism: 'generated constant table that raises on an unknown name (config_keys pattern)'
	},
	timer_literal: {
		home: '_shared/core/timing/data/constants.toml',
		mechanism: 'shared data file; the call reads a named registry key'
	},
	lua_function: {
		home: '_shared/<feature>/engine/',
		mechanism: 'one Lua module both Lua drivers require'
	},
	lua_table: {
		home: '_shared/<feature>/data/*.json or _shared/<feature>/engine/',
		mechanism: 'shared data file (AHK can read it) or one Lua module'
	}
};

// ──────────────────────────────────────────────────────────────────────────────
// Scan
// ──────────────────────────────────────────────────────────────────────────────

function driverSources() {
	return Census.trackedFiles(ROOT)
		.map((f) => f.slice(PREFIX.length))
		.filter((f) => {
			const [tree, ...rest] = f.split('/');
			if (!Census.DRIVERS.includes(tree)) return false;
			if (EXCLUDED.test(rest.join('/'))) return false;
			return (
				(tree === 'windows' && f.endsWith('.ahk')) || (tree !== 'windows' && f.endsWith('.lua'))
			);
		});
}

const LUA_CONST =
	/^[ \t]*(?:local[ \t]+|M\.|[A-Za-z_]\w*\.)?([A-Z][A-Z0-9_]{2,})[ \t]*=[ \t]*([^\n]+)$/gm;
const AHK_CONST =
	/^[ \t]*(?:static[ \t]+|global[ \t]+)?([A-Z][A-Z0-9_]{2,})[ \t]*:=[ \t]*([^\n]+)$/gm;
const LUA_TIMER =
	/\b(?:hs\.timer\.doAfter|hs\.timer\.new|hs\.timer\.doEvery|hs\.timer\.usleep|timer:start|:start)\s*\(\s*(\d+(?:\.\d+)?)\s*[,)]/g;
const AHK_TIMER = /\b(?:SetTimer\s*\([^,()]+,\s*(-?\d+)|Sleep\s*\(?\s*(\d+))/g;

const IDENTITY_NAMES =
	/^(LOG|LOG_TAG|TAG|OWNER|MODULE|MODULE_NAME|NAME|COMPONENT|SOURCE|SCOPE|DRIVER|PLATFORM|CATALOGUE_DRIVER|M)$/;

/** Classifies the right-hand side of a constant declaration. */
function valueOf(rhs) {
	const v = rhs.trim().replace(/[,;]\s*$/, '');
	const num = v.match(/^-?(0x[0-9A-Fa-f]+|\d+(?:\.\d+)?(?:e\d+)?)\s*(?:\*\s*\d+(?:\.\d+)?)?$/);
	if (num) return { type: 'number', literal: v };
	const str = v.match(/^(["'])([^"'\n]*)\1$/);
	if (str) return { type: 'string', literal: str[2] };
	return null;
}

function kindOf(name, value) {
	if (value.type === 'string') {
		if (/^#?[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/.test(value.literal)) return 'color';
		if (
			/\.(toml|json|log|db|sqlite3?|lua|ahk|txt|plist|ini|lock|md)$/i.test(value.literal) ||
			/ErgoptiPlus|ergopti/i.test(value.literal)
		)
			return 'path_name';
		if (/^[a-z][a-z0-9_.-]*$/.test(value.literal)) return 'enum_name';
		return null;
	}
	if (/^0x[0-9A-Fa-f]{6}$/.test(value.literal) && /COLOR|COLOUR|BG|FG/.test(name)) return 'color';
	const hit = NAME_KINDS.find(([, re]) => re.test(name));
	return hit ? hit[0] : null;
}

/** The domain a driver file lands in under the structure plan. */
function domainOf(treeRel) {
	const target = Rules.mapPath(treeRel).split('/').slice(1);
	// A feature root, or core/<domain> and platform/<domain>.
	return ['core', 'platform', 'tray'].includes(target[0]) && target.length > 2
		? `${target[0]}/${target[1]}`
		: target[0];
}

function lineOf(text, index) {
	let n = 1;
	for (let i = 0; i < index; i++) if (text.charCodeAt(i) === 10) n++;
	return n;
}

/** Lua function bodies, normalised for cross-driver comparison. */
function luaFunctions(text) {
	const out = [];
	const re = /^[ \t]*(?:local[ \t]+)?function[ \t]+([A-Za-z_][\w.:]*)[ \t]*\(([^)]*)\)/gm;
	for (const m of text.matchAll(re)) {
		const start = m.index;
		const indent = (text.slice(start).match(/^[ \t]*/) || [''])[0];
		const endRe = new RegExp(`^${indent}end\\b`, 'm');
		const rest = text.slice(start + m[0].length);
		const end = rest.search(endRe);
		if (end < 0) continue;
		const body = rest.slice(0, end);
		const lines = body.split('\n').filter((l) => l.trim()).length;
		if (lines < 4) continue;
		const norm = body
			.replace(/\s+/g, ' ')
			.replace(/\b(local|self)\b/g, '')
			.trim();
		const short = m[1].split(/[.:]/).pop();
		out.push({
			name: short,
			line: lineOf(text, start),
			lines,
			norm,
			tokens: new Set(norm.split(/[^A-Za-z0-9_]+/).filter(Boolean))
		});
	}
	return out;
}

function jaccard(a, b) {
	let inter = 0;
	for (const x of a) if (b.has(x)) inter++;
	return inter / (a.size + b.size - inter || 1);
}

/** Lua data tables with many string keys, for cross-driver comparison. */
function luaTables(text) {
	const out = [];
	const re = /^[ \t]*(?:local[ \t]+)?([A-Za-z_][\w.]*)[ \t]*=[ \t]*\{/gm;
	for (const m of text.matchAll(re)) {
		let depth = 0;
		let i = m.index + m[0].length - 1;
		for (; i < text.length; i++) {
			if (text[i] === '{') depth++;
			else if (text[i] === '}' && --depth === 0) break;
		}
		const body = text.slice(m.index, i);
		const keys = new Set(
			[...body.matchAll(/\[?["']?([A-Za-z_][\w-]*)["']?\]?\s*=/g)].map((k) => k[1])
		);
		if (keys.size >= 8) out.push({ name: m[1], line: lineOf(text, m.index), keys });
	}
	return out;
}

function inventory() {
	const items = [];
	const constants = new Map(); // NAME -> [{tree,file,line,value}]
	const functions = { macos: [], linux: [] };
	const tables = { macos: [], linux: [] };
	const files = driverSources();
	for (const file of files) {
		const tree = file.split('/')[0];
		const ext = path.extname(file);
		const text = stripComments(fs.readFileSync(path.join(ROOT, PREFIX + file), 'utf8'), ext);
		const domain = domainOf(file);
		const re = ext === '.ahk' ? AHK_CONST : LUA_CONST;
		for (const m of text.matchAll(re)) {
			const value = valueOf(m[2]);
			if (!value) continue;
			const kind = kindOf(m[1], value);
			if (!kind) continue;
			// A file's own identity (its log tag, owner name, driver name) is not
			// a shared value, even though every file spells one.
			if (IDENTITY_NAMES.test(m[1]) || Census.DRIVERS.includes(value.literal)) continue;
			const line = lineOf(text, m.index);
			items.push({ tree, file, line, kind, name: m[1], value: value.literal, domain });
			if (!constants.has(m[1])) constants.set(m[1], []);
			constants.get(m[1]).push({ tree, file, line, value: value.literal, kind });
		}
		const timer = ext === '.ahk' ? AHK_TIMER : LUA_TIMER;
		for (const m of text.matchAll(timer)) {
			const literal = m[1] || m[2];
			if (!literal || /^-?[01]$/.test(literal)) continue; // 0 and ±1 mean "next turn", not a delay
			items.push({
				tree,
				file,
				line: lineOf(text, m.index),
				kind: 'timer_literal',
				name: m[0].split('(')[0].trim(),
				value: literal,
				domain
			});
		}
		if (ext === '.lua') {
			for (const f of luaFunctions(text)) functions[tree].push({ ...f, file });
			for (const t of luaTables(text)) tables[tree].push({ ...t, file });
		}
	}

	// Cross-driver duplicates: one name declared on two or three drivers.
	const duplicates = [];
	for (const [name, decls] of constants) {
		const trees = [...new Set(decls.map((d) => d.tree))];
		if (trees.length < 2) continue;
		const values = [...new Set(decls.map((d) => d.value))];
		duplicates.push({
			name,
			kind: decls[0].kind,
			trees,
			divergent: values.length > 1,
			values,
			decls
		});
	}
	duplicates.sort(
		(a, b) =>
			b.trees.length - a.trees.length ||
			b.decls.length - a.decls.length ||
			a.name.localeCompare(b.name)
	);

	// Lua logic that macOS and Linux both carry: same name and similar body,
	// or an identical body under any name.
	const logic = [];
	const byNorm = new Map(functions.linux.map((f) => [f.norm, f]));
	const byName = new Map();
	for (const f of functions.linux) {
		if (!byName.has(f.name)) byName.set(f.name, []);
		byName.get(f.name).push(f);
	}
	for (const f of functions.macos) {
		const same = byNorm.get(f.norm);
		if (same) {
			logic.push({ kind: 'lua_function', similarity: 1, macos: f, linux: same });
			continue;
		}
		for (const g of byName.get(f.name) || []) {
			const sim = jaccard(f.tokens, g.tokens);
			if (sim >= 0.75) logic.push({ kind: 'lua_function', similarity: sim, macos: f, linux: g });
		}
	}
	for (const t of tables.macos) {
		for (const u of tables.linux) {
			const sim = jaccard(t.keys, u.keys);
			if (sim >= 0.7) logic.push({ kind: 'lua_table', similarity: sim, macos: t, linux: u });
		}
	}
	logic.sort((a, b) => b.similarity - a.similarity || (b.macos.lines || 0) - (a.macos.lines || 0));
	for (const l of logic) {
		const home = `_shared/${domainOf(l.linux.file)}/engine/`;
		items.push({
			tree: 'macos+linux',
			file: `${l.macos.file}:${l.macos.line} = ${l.linux.file}`,
			line: l.linux.line,
			kind: l.kind,
			name: l.macos.name,
			value: `similarity ${l.similarity.toFixed(2)}`,
			domain: home
		});
	}
	return { files: files.length, items, duplicates, logic };
}

// ──────────────────────────────────────────────────────────────────────────────
// Counts and report
// ──────────────────────────────────────────────────────────────────────────────

/** Counts per driver and kind: what the ratchet holds. */
function counts(inv) {
	const out = {};
	for (const it of inv.items) {
		out[it.tree] ||= {};
		out[it.tree][it.kind] = (out[it.tree][it.kind] || 0) + 1;
	}
	out.cross_driver_names = inv.duplicates.length;
	out.cross_driver_divergent = inv.duplicates.filter((d) => d.divergent).length;
	return out;
}

function proposedName(it) {
	const section = it.domain.split('/').pop();
	return `[${section}] ${it.name.toLowerCase()}`;
}

/** Formats one repository file in place with the repository's Prettier. */
function prettier(rel) {
	const bin = path.join(
		ROOT,
		'node_modules',
		'.bin',
		process.platform === 'win32' ? 'prettier.cmd' : 'prettier'
	);
	if (!fs.existsSync(bin)) throw new Error('Prettier is not installed: run npm ci before --write');
	require('node:child_process').execFileSync(bin, ['--write', '--log-level', 'warn', rel], {
		cwd: ROOT,
		stdio: 'inherit'
	});
}

function write(rel, text) {
	fs.mkdirSync(path.dirname(path.join(ROOT, rel)), { recursive: true });
	fs.writeFileSync(path.join(ROOT, rel), text.endsWith('\n') ? text : text + '\n', 'utf8');
	// The repository formats Markdown with Prettier; the appendix is written
	// in that form so the format gate holds it like any other document.
	if (rel.endsWith('.md')) prettier(rel);
	console.log(`wrote ${rel}`);
}

function main() {
	const inv = inventory();
	const c = counts(inv);
	if (process.argv.includes('--json')) {
		process.stdout.write(JSON.stringify(c, null, '\t') + '\n');
		return;
	}
	console.log(`${inv.files} production driver files scanned, ${inv.items.length} item(s)`);
	for (const [tree, kinds] of Object.entries(c)) {
		if (typeof kinds !== 'object') continue;
		console.log(
			`  ${tree}: ${Object.entries(kinds)
				.map(([k, v]) => `${k} ${v}`)
				.join(', ')}`
		);
	}
	console.log(
		`  names declared on two or more drivers: ${c.cross_driver_names} (${c.cross_driver_divergent} with different values)`
	);
	if (!process.argv.includes('--write')) return;

	const tsv = ['file\tline\tkind\tname\tvalue\tproposed_home\tproposed_name\tmechanism'];
	for (const it of inv.items.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line)) {
		const home = it.kind.startsWith('lua_') ? it.domain : HOMES[it.kind].home;
		const file = it.kind.startsWith('lua_') ? it.file : `${PREFIX}${it.file}`;
		tsv.push(
			[
				file,
				it.line,
				it.kind,
				it.name,
				String(it.value).replace(/\t/g, ' '),
				home,
				proposedName(it),
				HOMES[it.kind].mechanism
			].join('\t')
		);
	}
	write(`${OUT_DIR}/rule-a-inventory.tsv`, tsv.join('\n'));

	const lines = [
		`<!-- ${OUT_DIR}/rule-a-duplicates.md -->`,
		'',
		'# Cross-driver duplicates (structure plan, appendix 5)',
		'',
		'GENERATED by `node tools/audit/shared-literal-inventory.cjs --write`; do not edit.',
		'',
		'## Constants declared under one name on two or three drivers',
		'',
		'| name | kind | drivers | values | proposed home |',
		'| --- | --- | --- | --- | --- |'
	];
	for (const d of inv.duplicates) {
		const vals = d.values
			.slice(0, 4)
			.map((v) => `\`${String(v).replace(/\|/g, '\\|')}\``)
			.join(', ');
		lines.push(
			`| \`${d.name}\` | ${d.kind} | ${d.trees.join(' + ')} | ${vals}${d.divergent ? ' **(divergent)**' : ''} | ${HOMES[d.kind].home} |`
		);
	}
	lines.push(
		'',
		'## Lua logic carried by both macOS and Linux',
		'',
		'| similarity | macOS | Linux | proposed home |',
		'| --: | --- | --- | --- |'
	);
	for (const l of inv.logic.slice(0, 150)) {
		const label = l.kind === 'lua_table' ? `table \`${l.macos.name}\`` : `\`${l.macos.name}\``;
		lines.push(
			`| ${l.similarity.toFixed(2)} | ${label} \`${l.macos.file}:${l.macos.line}\` | \`${l.linux.file}:${l.linux.line}\` | \`_shared/${domainOf(l.linux.file)}/engine/\` |`
		);
	}
	if (inv.logic.length > 150)
		lines.push('', `${inv.logic.length - 150} more pairs in rule-a-inventory.tsv.`);
	write(`${OUT_DIR}/rule-a-duplicates.md`, lines.join('\n'));
	const gates = writeGates();
	console.log(
		`${gates.length} gates; not in CI: ${
			gates
				.filter((g) => !g.in_ci)
				.map((g) => g.name)
				.join(', ') || 'none'
		}`
	);
}

// ──────────────────────────────────────────────────────────────────────────────
// Existing single-source gates
// ──────────────────────────────────────────────────────────────────────────────

const GATE_NAME =
	/single-source|parity|duplicate|hardcoded|literal|shared|registry|tree|i18n|locale|visible-text|no-fallback|defaults|catalogue|vectors/;

/** The repository gates that hold one value or one tree, and how strict each is. */
function gateInventory() {
	const dir = path.join(ROOT, 'tools/test');
	const suites = fs
		.readdirSync(path.join(dir, 'features'))
		.map((f) => path.join(dir, 'features', f, 'suite.json'))
		.filter((f) => fs.existsSync(f))
		.map((f) => fs.readFileSync(f, 'utf8'))
		.join('\n');
	const pkg = fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8');
	const rows = [];
	for (const name of fs.readdirSync(dir).sort()) {
		if (!/^test-.*\.cjs$/.test(name) || !GATE_NAME.test(name)) continue;
		const text = fs.readFileSync(path.join(dir, name), 'utf8');
		const desc = (text.match(/MODULE:\s*([^\n]+)/) || [, ''])[1].trim();
		const baselines = [
			...new Set([...text.matchAll(/['"]([\w-]+-baseline\.json)['"]/g)].map((m) => m[1]))
		];
		let entries = 0;
		for (const b of baselines) {
			const file = [path.join(dir, b), path.join(ROOT, 'tools/lint', b)].find((f) =>
				fs.existsSync(f)
			);
			if (!file) continue;
			const data = JSON.parse(fs.readFileSync(file, 'utf8'));
			entries += Array.isArray(data)
				? data.length
				: Object.keys(data).filter((k) => !k.startsWith('_')).length;
		}
		const ratchet = /BASELINE_[A-Z_]+\s*=\s*\d+/.test(text);
		rows.push({
			name,
			desc,
			strictness: baselines.length
				? `baseline (${entries} entr${entries === 1 ? 'y' : 'ies'})`
				: ratchet
					? 'numeric ratchet'
					: 'strict',
			in_ci: suites.includes(`tools/test/${name}`),
			in_package: pkg.includes(`tools/test/${name}`)
		});
	}
	return rows;
}

function writeGates() {
	const rows = gateInventory();
	const lines = [
		`<!-- ${OUT_DIR}/rule-a-gates.md -->`,
		'',
		'# Existing single-source and tree gates (structure plan, appendix 6)',
		'',
		'GENERATED by `node tools/audit/shared-literal-inventory.cjs --write`; do not edit.',
		'',
		'"In CI" means a check of tools/test/features/*/suite.json runs it; a gate that only has an npm script runs when someone types it. A baseline gate tolerates the listed debt and fails only on growth.',
		'',
		'| gate | holds | strictness | in CI |',
		'| --- | --- | --- | --- |'
	];
	for (const r of rows)
		lines.push(
			`| \`${r.name}\` | ${r.desc.replace(/\|/g, '/')} | ${r.strictness} | ${r.in_ci ? 'yes' : r.in_package ? '**npm script only**' : '**no**'} |`
		);
	write(`${OUT_DIR}/rule-a-gates.md`, lines.join('\n'));
	return rows;
}

if (require.main === module) main();

module.exports = { inventory, counts, gateInventory, kindOf, valueOf, HOMES };
