// tools/test/test-duplicate-constant-names.cjs

/**
 * ==============================================================================
 * MODULE: Duplicate Timing and Size Constant Names Ratchet
 * DESCRIPTION:
 * A delay, timeout or byte cap declared under the same name in more than one
 * production file is two hand-maintained copies of one number, or two
 * different numbers that a reader will take for one. This gate freezes the
 * names that are declared that way today and fails on any new one, so the list
 * can only shrink.
 *
 * ROOT CAUSE ENCODED:
 * `TAP_WATCHDOG_INTERVAL_SEC` was 2 in script_control.lua and 5 in
 * keystats/init.lua, whose comment said it "mirrors" the other.
 * `DEFAULT_TIMEOUT_MS = 30000` was typed in four adapters, `STALE_TEMP_MS :=
 * 60000` in five AHK files and `LONG_SESSION_THRESHOLD_MS` in three pages. No
 * check noticed any of it: each copy was correct on the day it was written.
 *
 * WHAT IS SCANNED:
 * Single-name declarations of `*_MS`, `*_SEC`, `*_TIMEOUT`, `*_MAX` and
 * `*_BYTES` names in production AHK (`static`/`global`), Lua (`local`, `M.`),
 * JavaScript (`const`/`let`/`var`) and Swift (`let`/`var`) under
 * static/ergopti_plus. Tests, vendor and generated code are excluded.
 *
 * A name is a duplicate when it is declared in two files or more and at least
 * one declaration is hand-made (a literal or a computed value). Declarations
 * that read the timing registry, the `0` sentinels AHK reassigns at boot and
 * re-exports of the same name are not copies and do not count on their own.
 * Copies are divergent when they hold two different literal values.
 *
 * FEATURES & RATIONALE:
 * 1. Ratchet: the baseline (duplicate-constant-names-baseline.json) lists each
 *    duplicate, its files and whether its copies diverge. A new name, a new
 *    file for a listed name, or copies that start to diverge fail.
 * 2. It can only shrink: an entry that no longer matches the tree fails too,
 *    until `--update-baseline` rewrites it. That flag refuses to run while
 *    anything has grown.
 * 3. The walk is floored and the gate proves it can fail on synthetic inputs.
 * ==============================================================================
 */

'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const BASELINE_PATH = path.join(__dirname, 'duplicate-constant-names-baseline.json');
const MIN_SOURCE_FILES = 1000;

const SKIPPED_DIRECTORIES = new Set([
	'node_modules',
	'.git',
	'.build',
	'tests',
	'Tests',
	'vendor',
	'_generated'
]);

const NAME = '([A-Z][A-Z0-9_]*(?:_MS|_SEC|_TIMEOUT|_MAX|_BYTES))';
const DECLARATIONS = {
	'.ahk': new RegExp(`^[ \\t]*(?:static|global)[ \\t]+${NAME}[ \\t]*:=[ \\t]*(.*)$`),
	'.lua': new RegExp(`^[ \\t]*(?:local[ \\t]+|M\\.)${NAME}[ \\t]*=(?!=)[ \\t]*(.*)$`),
	'.js': new RegExp(
		`^[ \\t]*(?:export[ \\t]+)?(?:const|let|var)[ \\t]+${NAME}[ \\t]*=(?!=)[ \\t]*(.*)$`
	),
	'.swift': new RegExp(
		'^[ \\t]*(?:(?:private|fileprivate|internal|public)[ \\t]+)?(?:static[ \\t]+)?' +
			`(?:let|var)[ \\t]+${NAME}[ \\t]*(?::[ \\t]*[\\w.]+[ \\t]*)?=(?!=)[ \\t]*(.*)$`
	)
};
const LINE_COMMENT = {
	'.ahk': /[ \t];.*$/,
	'.lua': /--.*$/,
	'.js': /\/\/.*$/,
	'.swift': /\/\/.*$/
};
const REGISTRY_READ = /\b(?:Timings\.(?:ms|sec|count)|TimingsGet(?:Sec)?)\(/;
const NUMERIC_EXPRESSION = /^[\d_.eE+\-*/() ]+$/;

/**
 * Every production source file the scan covers.
 * @returns {{rel: string, text: string}[]}
 */
function productionSources() {
	const out = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const abs = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (!SKIPPED_DIRECTORIES.has(entry.name)) walk(abs);
			} else if (
				Object.hasOwn(DECLARATIONS, path.extname(entry.name)) &&
				!entry.name.endsWith('.generated.swift')
			) {
				out.push({
					rel: path.relative(SP, abs).split(path.sep).join('/'),
					text: fs.readFileSync(abs, 'utf8')
				});
			}
		}
	};
	walk(SP);
	return out;
}

/**
 * Evaluates a declaration value made only of numbers, + - * / and parentheses
 * (`90 * 60 * 1000`, `4 * 1024 * 1024`, `30_000`, `1e6`).
 * @param {string} value Declaration right-hand side, comment stripped.
 * @returns {number|null} The value, or null when it is not a numeric literal.
 */
function literalValue(value) {
	if (!NUMERIC_EXPRESSION.test(value) || !/\d/.test(value)) return null;
	const tokens = value.replace(/_/g, '').match(/\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[-+*/()]|\S/g);
	let at = 0;
	const peek = () => tokens[at];
	const primary = () => {
		const token = tokens[at++];
		if (token === '(') {
			const inner = sum();
			return tokens[at++] === ')' ? inner : NaN;
		}
		if (token === '-') return -primary();
		return /^\d/.test(token || '') ? Number(token) : NaN;
	};
	const product = () => {
		let acc = primary();
		while (peek() === '*' || peek() === '/')
			acc = tokens[at++] === '*' ? acc * primary() : acc / primary();
		return acc;
	};
	const sum = () => {
		let acc = product();
		while (peek() === '+' || peek() === '-')
			acc = tokens[at++] === '+' ? acc + product() : acc - product();
		return acc;
	};
	const result = sum();
	return at === tokens.length && Number.isFinite(result) ? result : null;
}

/**
 * Classifies one declaration of `name`.
 * @returns {{kind: string, value: number|null}}
 */
function classify(name, rawValue, ext) {
	const value = rawValue.replace(LINE_COMMENT[ext], '').trim().replace(/[,;]$/, '').trim();
	if (REGISTRY_READ.test(value)) return { kind: 'registry', value: null };
	if (new RegExp(`\\b${name}\\b`).test(value)) return { kind: 'alias', value: null };
	const literal = literalValue(value);
	if (literal === 0) return { kind: 'sentinel', value: null };
	if (literal !== null) return { kind: 'literal', value: literal };
	return { kind: 'expression', value: null };
}

/**
 * The duplicates of a set of sources.
 * @param {{rel: string, text: string}[]} sources Production sources.
 * @returns {Map<string, {files: string[], divergent: boolean}>}
 */
function duplicates(sources) {
	const byName = new Map();
	for (const source of sources) {
		const ext = path.extname(source.rel);
		const pattern = DECLARATIONS[ext];
		for (const line of source.text.split(/\r?\n/)) {
			const m = line.match(pattern);
			if (!m) continue;
			const decl = classify(m[1], m[2], ext);
			if (decl.kind === 'alias') continue;
			if (!byName.has(m[1])) byName.set(m[1], new Map());
			const files = byName.get(m[1]);
			if (!files.has(source.rel)) files.set(source.rel, []);
			files.get(source.rel).push(decl);
		}
	}
	const out = new Map();
	for (const [name, files] of [...byName].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
		if (files.size < 2) continue;
		const decls = [...files.values()].flat();
		if (!decls.some((d) => d.kind === 'literal' || d.kind === 'expression')) continue;
		const literals = new Set(decls.filter((d) => d.kind === 'literal').map((d) => d.value));
		out.set(name, { files: [...files.keys()].sort(), divergent: literals.size > 1 });
	}
	return out;
}

/**
 * Compares the live duplicates with the baseline.
 * @returns {{grown: string[], stale: string[]}} Growth fails; staleness asks for a shrink.
 */
function compare(live, baseline) {
	const grown = [];
	const stale = [];
	for (const [name, entry] of live) {
		const frozen = baseline[name];
		if (!frozen) {
			grown.push(
				`${name} is declared in ${entry.files.length} files (${entry.files.join(', ')}). ` +
					'Give it one home — read the shared timing registry (Timings / TimingsGet), ' +
					'require the module that defines it, or rename it if it is a different concept.'
			);
			continue;
		}
		const added = entry.files.filter((f) => !frozen.files.includes(f));
		if (added.length > 0)
			grown.push(`${name} gained a copy in ${added.join(', ')} — it may only lose copies.`);
		if (entry.divergent && !frozen.divergent)
			grown.push(
				`${name}'s copies now hold different values (${entry.files.join(', ')}): ` +
					'one of them drifted.'
			);
	}
	for (const [name, frozen] of Object.entries(baseline)) {
		if (name.startsWith('_')) continue;
		const entry = live.get(name);
		if (!entry) {
			stale.push(`${name} is no longer duplicated — remove it from the baseline.`);
			continue;
		}
		const gone = frozen.files.filter((f) => !entry.files.includes(f));
		if (gone.length > 0) stale.push(`${name} lost its copy in ${gone.join(', ')}.`);
		if (frozen.divergent && !entry.divergent) stale.push(`${name}'s copies agree again.`);
	}
	return { grown, stale };
}

/** Proves the comparison fails on what it exists to stop. */
function selfTest() {
	const failures = [];
	const src = (rel, text) => ({ rel, text });
	const base = [
		src('macos/a.lua', 'local WAIT_MS = 30000\n'),
		src('linux/b.lua', 'local WAIT_MS = 30000 -- same\n')
	];
	const live = duplicates(base);
	const frozen = { WAIT_MS: { files: ['linux/b.lua', 'macos/a.lua'], divergent: false } };
	const check = (name, result, grown, stale) => {
		if (result.grown.length !== grown || result.stale.length !== stale)
			failures.push(
				`${name}: expected ${grown} grown / ${stale} stale, got ` +
					`${result.grown.length} / ${result.stale.length}`
			);
	};
	check('frozen tree', compare(live, frozen), 0, 0);
	check('new duplicate', compare(live, {}), 1, 0);
	check(
		'copy spread to a third file',
		compare(duplicates([...base, src('windows/c.ahk', 'global WAIT_MS := 30000\n')]), frozen),
		1,
		0
	);
	check(
		'copies drifted',
		compare(duplicates([base[0], src('linux/b.lua', 'local WAIT_MS = 5000\n')]), frozen),
		1,
		0
	);
	check('duplicate resolved', compare(duplicates([base[0]]), frozen), 0, 1);
	check(
		'registry reads and sentinels are not copies',
		compare(
			duplicates([
				src('macos/a.lua', 'local WAIT_MS = Timings.ms("ui", "wait_ms")\n'),
				src('windows/c.ahk', '\tstatic WAIT_MS := 0\n')
			]),
			{}
		),
		0,
		0
	);
	check(
		're-exports are not copies',
		compare(duplicates([base[0], src('macos/b.lua', 'M.WAIT_MS = require("a").WAIT_MS\n')]), {}),
		0,
		0
	);
	return failures;
}

function main() {
	const update = process.argv.includes('--update-baseline');
	const sources = productionSources();
	const errors = [];
	if (sources.length < MIN_SOURCE_FILES)
		errors.push(
			`walked only ${sources.length} production source file(s) — the walk is broken, ` +
				'and an empty scan proves nothing'
		);
	errors.push(...selfTest().map((f) => `self-test: ${f}`));
	const baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
	const live = duplicates(sources);
	const { grown, stale } = compare(live, baseline);

	if (update && errors.length === 0 && grown.length === 0) {
		const next = { _comment: baseline._comment };
		for (const [name, entry] of live) next[name] = entry;
		fs.writeFileSync(BASELINE_PATH, JSON.stringify(next, null, '\t') + '\n', 'utf8');
		// The repository formatter owns the layout of every tracked JSON file.
		execFileSync(
			process.execPath,
			[require.resolve('prettier/bin/prettier.cjs'), '--write', BASELINE_PATH],
			{
				stdio: 'ignore'
			}
		);
		console.log(`baseline rewritten: ${live.size} duplicate name(s).`);
		return;
	}
	errors.push(...grown);
	if (update && grown.length > 0)
		errors.push('--update-baseline refused: a duplicate grew, and the baseline only shrinks.');
	errors.push(...stale.map((s) => `${s} Run with --update-baseline to shrink it.`));

	if (errors.length > 0) {
		console.error('\x1b[31m[ERROR] Duplicate constant names out of step with the baseline:\x1b[0m');
		for (const e of errors) console.error('    ' + e);
		process.exit(1);
	}
	const divergent = [...live.values()].filter((e) => e.divergent).length;
	console.log(
		`\x1b[32m[OK] ${live.size} duplicate constant name(s), ${divergent} divergent, none new — ` +
			`${sources.length} file(s) scanned.\x1b[0m`
	);
}

if (require.main === module) main();

module.exports = { duplicates, compare, productionSources, selfTest };
