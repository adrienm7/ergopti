// tools/test/test-wpm-chars-per-word-single-source.cjs

/**
 * ==============================================================================
 * MODULE: WPM Chars-Per-Word Single Source
 * DESCRIPTION:
 * The words-per-minute divisor is defined once, in
 * `_shared/metrics/engine/metrics.lua` as `DEFAULT_CHARS_PER_WORD`. No Lua driver
 * may divide by a literal instead, and the JavaScript metrics views may not add
 * a copy beyond the five they already have.
 *
 * ROOT CAUSE ENCODED:
 * The shared module existed, carried the constant AND the exact batch formula,
 * and its own docstring said "used by macOS log_manager/aggregator" — while
 * macOS computed `(#ring / 5) / (window / 60000)` inline in two places and never
 * required it. Linux did it correctly. So the shared copy existed only to be
 * shadowed: changing `DEFAULT_CHARS_PER_WORD` would have moved Linux's numbers
 * and left macOS reporting the old ones, with the two drivers disagreeing about
 * what a word is and nothing failing.
 *
 * That is the quiet kind of divergence. Both numbers look plausible on screen —
 * a WPM readout has no obviously-wrong value — so the first person to notice
 * would be a user comparing their Mac and their PC.
 *
 * WHY THE JS SIDE IS A RATCHET AND NOT A BAN:
 * The five remaining literals are in the metrics WebView (`data.js` ×3,
 * `charts.js`, `table.js`), which cannot `require` a Lua module. Removing them
 * means generating a JS constant — worth doing, and a different change from this
 * one. A named ledger of the five stops a sixth appearing in the meantime.
 * Remove the entries when the generated constant lands. Never add one.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { reportKnownDebt } = require('./lib/known-debt.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CANON = path.join(SP, '_shared', 'metrics', 'engine', 'metrics.lua');

// The metrics WebView's own copies, frozen on 2026-08-01 as a count of 5 and
// named on 2026-11-22: each file's copies in source order. The ledger only
// shrinks; the generated JS constant removes every entry.
const JS_COPY_REASON =
	'the WebView cannot require the Lua module and no generated JS constant exists yet';
const JS_COPY_LEDGER = {
	'_shared/ui/metrics_typing/charts.js #1': `daily WPM chart point: ${JS_COPY_REASON}`,
	'_shared/ui/metrics_typing/data.js #1': `daily WPM of the time series: ${JS_COPY_REASON}`,
	'_shared/ui/metrics_typing/data.js #2': `manifest WPM from CPM: ${JS_COPY_REASON}`,
	'_shared/ui/metrics_typing/data.js #3': `output WPM from CPM: ${JS_COPY_REASON}`,
	'_shared/ui/metrics_typing/table.js #1': `per-row WPM of the table: ${JS_COPY_REASON}`
};

// A WPM computation dividing by a bare number rather than by the constant.
// Anchored on the surrounding formula so an unrelated "/ 5" is not swept in.
const LUA_LITERAL = /\/\s*5\s*\)?\s*\/\s*\(?[\w.#\[\]]*\s*\/\s*60000/;
const JS_LITERAL = /\/\s*5\s*(?:\/|\)|;|$)/;

const errors = [];

if (!fs.existsSync(CANON)) {
	console.error(
		'\x1b[31m[ERROR] the shared metrics module is missing — there is no canonical divisor.\x1b[0m'
	);
	process.exit(1);
}

const canonSrc = fs.readFileSync(CANON, 'utf8');
const decl = canonSrc.match(/^M\.DEFAULT_CHARS_PER_WORD\s*=\s*(\d+)/m);
if (!decl) {
	errors.push(
		'_shared/metrics/engine/metrics.lua no longer declares M.DEFAULT_CHARS_PER_WORD — the single ' +
			'source is gone and every driver is now free to pick its own divisor'
	);
}

/** Every non-test source of one kind under a driver or the shared tree. */
function sources(rel, ext) {
	const base = path.join(SP, rel);
	const out = [];
	if (!fs.existsSync(base)) return out;
	(function walk(dir) {
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'tests' && e.name !== 'vendor' && e.name !== 'node_modules') walk(p);
			} else if (path.extname(e.name) === ext) {
				out.push(p);
			}
		}
	})(base);
	return out;
}

// ── Lua: no literal divisor anywhere, on any driver ─────────────────────────
const LUA_ROOTS = ['macos', 'linux', '_shared'];
let luaScanned = 0;
const luaScannedFiles = new Set();
for (const rel of LUA_ROOTS) {
	for (const abs of sources(rel, '.lua')) {
		// The canonical module is where the constant and the formula live.
		if (path.resolve(abs) === path.resolve(CANON)) continue;
		luaScanned++;
		luaScannedFiles.add(path.resolve(abs));
		const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);
		lines.forEach((line, i) => {
			if (/^\s*--/.test(line)) return; // Prose may quote the formula
			if (!LUA_LITERAL.test(line)) return;
			errors.push(
				`${path.relative(ROOT, abs).split(path.sep).join('/')}:${i + 1}: computes WPM with a ` +
					'literal divisor. Use Metrics.compute_wpm_from_events / compute_wpm_from_ring, or at ' +
					'minimum Metrics.DEFAULT_CHARS_PER_WORD — otherwise changing the constant moves one ' +
					"driver's numbers and not the other's, and nothing fails."
			);
		});
	}
}

// Git's index is the walk's oracle: every tracked Lua source outside tests/ and
// vendor/ must have been scanned, or the walk is broken and reports nothing.
const tracked = execFileSync(
	'git',
	['ls-files', '-z', '--', ...LUA_ROOTS.map((rel) => `static/ergopti_plus/${rel}`)],
	{ cwd: ROOT, encoding: 'utf8' }
)
	.split('\0')
	.filter((rel) => rel.endsWith('.lua') && !/\/(tests|vendor|node_modules)\//.test(rel))
	.map((rel) => path.resolve(ROOT, rel))
	.filter((abs) => abs !== path.resolve(CANON));
const unscanned = tracked.filter((abs) => !luaScannedFiles.has(abs));
if (tracked.length === 0 || unscanned.length > 0) {
	errors.push(
		`the walk scanned ${luaScanned} Lua file(s) but missed ${unscanned.length} of the ${tracked.length} ` +
			`tracked ones (${unscanned
				.slice(0, 3)
				.map((abs) => path.relative(ROOT, abs).split(path.sep).join('/'))
				.join(', ')}) — the walk is broken and would report nothing`
	);
}

// ── JavaScript: the WebView copies, frozen ──────────────────────────────────
let jsCopies = 0;
const jsSites = [];
// How far the `wpm`/`cpm` mention may sit from the divisor. table.js writes the
// formula across a ternary, so the naming line is the one above — a same-line
// requirement found 4 of the 5 and would have let the fifth be joined by more.
const NAMING_CONTEXT = 2;

for (const abs of sources('_shared/ui/metrics_typing', '.js')) {
	const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);
	let ordinal = 0;
	lines.forEach((line, i) => {
		const t = line.trimStart();
		if (t.startsWith('//') || t.startsWith('*')) return;
		if (!JS_LITERAL.test(line)) return;
		// A divisor sitting beside the milliseconds-per-minute constant is a WPM
		// computation whatever the surrounding lines are called; table.js names
		// its field five lines above the arithmetic, so naming context alone
		// found 4 of the 5 and would have let the fifth be joined by more.
		const selfEvident = /60000/.test(line);
		const window = lines.slice(Math.max(0, i - NAMING_CONTEXT), i + NAMING_CONTEXT + 1).join('\n');
		if (!selfEvident && !/wpm|cpm/i.test(window)) return;
		jsCopies++;
		ordinal++;
		jsSites.push(`${path.relative(SP, abs).split(path.sep).join('/')} #${ordinal}`);
	});
}

if (
	!reportKnownDebt({
		label: 'WPM divisor single source: metrics WebView literal divisor',
		found: jsSites,
		ledger: JS_COPY_LEDGER,
		ledgerName: 'JS_COPY_LEDGER',
		advice: '  Generate the constant instead of adding another copy. Do NOT add it to the ledger.'
	})
) {
	errors.push('the WebView literal divisors differ from JS_COPY_LEDGER (see above)');
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] WPM divisor single source:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] every Lua driver takes the WPM divisor from the shared module ` +
		`(${luaScanned} file(s) scanned); WebView copies ${jsCopies}, each in JS_COPY_LEDGER.\x1b[0m`
);
