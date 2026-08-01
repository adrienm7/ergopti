// tools/test/test-linux-shared-path-resolver.cjs

/**
 * ==============================================================================
 * MODULE: Linux Shared-Tree Resolver Guard
 * DESCRIPTION:
 * No Linux module may derive the `_shared` tree by counting `..` steps of its
 * own. It asks infra/paths.lua, which derives the root once.
 *
 * ROOT CAUSE ENCODED — TWO SHIPPED BUGS, SAME SHAPE:
 * Twelve independent `_shared` expressions existed across the Linux driver, at
 * four different depths, and two of them were wrong:
 *
 *   * infra/i18n.lua walked "../../" from the driver root for
 *     _shared/data/locales. One level too high. `ls` on the missing directory
 *     printed nothing, the scan collected zero codes, and the {"en","fr"}
 *     fallback took over — so the language menu offered 2 locales out of the 21
 *     that ship. Nothing failed; the menu just quietly had two rows. The same
 *     file carried the same wrong depth for the display-order file, so the two
 *     survivors also sorted alphabetically instead of canonically.
 *
 *   * modules/keylogger/sqlite_writer.lua walked "../../../" for
 *     _shared/data/db/schema.sql — two levels too high — and fell back to a BARE
 *     RELATIVE path, making schema loading depend on the process's current
 *     directory rather than on where the driver is installed.
 *
 * A per-file path cannot be verified and degrades silently when wrong. This
 * guard makes the resolver the only way to reach the tree.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const RESOLVER = path.join(DRIVER, 'infra', 'paths.lua');

/** Every production Lua file in the Linux driver. */
function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'tests') walk(p, acc);
		} else if (e.name.endsWith('.lua')) {
			acc.push(p);
		}
	}
	return acc;
}

const errors = [];

if (!fs.existsSync(RESOLVER)) {
	errors.push('linux/infra/paths.lua is missing — every module would go back to counting ".." itself');
}

// The resolver is allowed to know where the tree is; that is its job. Two more
// are exempt with a reason:
//   - infra/locale.lua walks UPWARD looking for the tree rather than assuming a
//     depth, which is a search, not a hardcoded count.
//   - ui/webkit_host.lua probes a candidate list for the file:// base a webview
//     needs before any module has loaded.
const EXEMPT = new Set([
	'infra/paths.lua',
	'infra/locale.lua',
	'ui/webkit_host.lua',
	// The two bootstraps, whose depth is asserted separately below rather than
	// trusted: they run before package.path includes the shared tree.
	'ergopti_hotstrings.lua',
	'modules/hotstrings/engine.lua',
]);

const files = walk(DRIVER);
if (files.length < 40) {
	errors.push(`walked only ${files.length} Linux .lua file(s) — the scan is broken and would report nothing`);
}

// A hardcoded hop to the shared tree: any ".." step immediately followed by
// "_shared" in a string literal.
const HARDCODED = /\.\.[/\\](?:\.\.[/\\])*_shared/;

for (const abs of files) {
	const rel = path.relative(DRIVER, abs).split(path.sep).join('/');
	if (EXEMPT.has(rel)) continue;
	const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);
	lines.forEach((line, i) => {
		if (/^\s*--/.test(line)) return; // prose may cite the old path
		if (!HARDCODED.test(line)) return;
		errors.push(
			`${rel}:${i + 1}: derives the shared tree by counting ".." — require("lib.paths") and ` +
				'call Paths.shared(…). A per-file depth cannot be verified, and a wrong one degrades ' +
				'silently: this is how the language menu came to offer 2 locales of 21.'
		);
	});
}

// The two bootstraps cannot use the resolver — they run BEFORE package.path
// includes the shared tree, which is exactly what they are computing — so their
// hand-counted depth is checked against the real layout instead of taken on
// faith. engine.lua was wrong here once: it walked "../../" from a root its own
// pattern had already reached.
const BOOTSTRAPS = [
	{ file: 'ergopti_hotstrings.lua', note: 'SCRIPT_DIR is the driver root' },
	{ file: 'modules/hotstrings/engine.lua', note: '_linux_root is the driver root' },
];
for (const b of BOOTSTRAPS) {
	const abs = path.join(DRIVER, b.file);
	if (!fs.existsSync(abs)) {
		errors.push(`${b.file}: missing — the bootstrap moved and this check no longer covers it`);
		continue;
	}
	const src = fs.readFileSync(abs, 'utf8');
	// From the driver root, _shared is exactly ONE level up. Two or more steps
	// resolve outside the tree, and the read then fails silently.
	const TOO_DEEP = /\.\.[/\\]\.\.[/\\](?:\.\.[/\\])*_shared/g;
	for (const m of src.matchAll(TOO_DEEP)) {
		const line = src.slice(0, m.index).split('\n').length;
		errors.push(
			`${b.file}:${line}: reaches _shared with two or more ".." steps. ${b.note}, so _shared is ` +
				'ONE level up — more than that resolves outside the tree and the read fails silently.'
		);
	}
}

// ── The user's directories, same rule, same reason ──────────────────────────
//
// Fifteen files derived $HOME themselves, across nineteen call sites, with SIX
// different answers for a missing HOME: "/tmp", "~", "", ".", "/home/user", and
// one bare concatenation with no fallback at all. Two of those were wrong rather
// than merely inconsistent — the bare concat THROWS on nil and took the menu
// build with it, and "~" is never expanded by io.open, so those paths addressed
// a literal directory named "~" beside the process. "/home/user" is the worst of
// the three: a plausible path belonging to nobody, so a write there looks like it
// worked.
const HOME_EXEMPT = new Set(['infra/config_paths.lua']);
const USER_ENV = /os\.getenv\(\s*"(HOME|XDG_CONFIG_HOME|XDG_DATA_HOME)"\s*\)/;

for (const abs of files) {
	const rel = path.relative(DRIVER, abs).split(path.sep).join('/');
	if (HOME_EXEMPT.has(rel)) continue;
	fs.readFileSync(abs, 'utf8')
		.split(/\r?\n/)
		.forEach((line, i) => {
			if (/^\s*--/.test(line)) return;
			const m = line.match(USER_ENV);
			if (!m) return;
			errors.push(
				`${rel}:${i + 1}: reads ${m[1]} directly — require("lib.config_paths"). Fifteen files ` +
					'once did this with six different fallbacks, two of them broken: a bare concatenation ' +
					'throws on nil, and "~" is never expanded by io.open.'
			);
		});
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Linux modules bypassing the shared-path resolver:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] All ${files.length} Linux module(s) reach _shared through infra/paths.lua ` +
		`(${EXEMPT.size} documented exemption(s)).\x1b[0m`
);
