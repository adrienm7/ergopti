// tools/test/test-locale-names-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Locale Native-Name Single-Source Guard
 * DESCRIPTION:
 * Every shipped locale must have a native display name in every driver's
 * language menu, and all three must say the same thing.
 *
 * ROOT CAUSE ENCODED:
 * The display ORDER was already single-sourced from locale_order.json and gated.
 * The NAMES were not — three hand-maintained tables — and one had silently
 * fallen behind. `linux/infra/i18n.lua`'s `display_name()` carried a map of 16 of
 * the 21 shipped locales and ended in `return names[code] or code`, so `da`,
 * `no`, `cs`, `he` and `hi` rendered in the Linux language menu as those bare
 * two-letter codes, sitting between "Nederlands" and "Русский" while the other
 * sixteen showed their native names.
 *
 * Nothing failed. There is no error path for a missing name — `or code` is a
 * perfectly good fallback for an unknown locale, and indistinguishable from a
 * forgotten one. The five rows just looked like a bug nobody had filed.
 *
 * macOS and Windows agreed on all 21 names, which is what made the shared file
 * derivable rather than a judgement call about which spelling was right.
 *
 * WHAT THIS GUARDS:
 * 1. Order and names cover exactly the same locale set — a locale ordered but
 *    unnamed renders as a code; a locale named but unordered never appears.
 * 2. Every locale JSON that ships in data/locales/ is in both.
 * 3. No driver hand-maintains a name table any more. That is the assertion that
 *    prevents the regression rather than re-detecting it: a fourth copy is how
 *    the third one drifted.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DATA = path.join(SP, '_shared', 'data');
const SITE_LOADER = fs.readFileSync(
	path.join(ROOT, 'src', 'routes', 'ergopti-plus', '+page.server.js'),
	'utf8'
);

const errors = [];

const order = JSON.parse(fs.readFileSync(path.join(DATA, 'locale_order.json'), 'utf8')).order;
const names = JSON.parse(fs.readFileSync(path.join(DATA, 'locale_names.json'), 'utf8')).locales;

if (!/LOCALE_NAMES_PATH[\s\S]*?locale_names\.json/.test(SITE_LOADER)
	|| !/readJson\(LOCALE_NAMES_PATH\)\.locales/.test(SITE_LOADER)) {
	errors.push('the Ergopti+ site must read locale names from canonical locale_names.json');
}
if (/macos[/\\]lib[/\\]i18n\.lua/.test(SITE_LOADER)) {
	errors.push('the Ergopti+ site still reads the retired macOS lib/i18n.lua path');
}

// ── 1. Order and names describe the same set ────────────────────────────────

for (const code of order) {
	const entry = names[code];
	if (!entry || typeof entry.name !== 'string' || entry.name === '') {
		errors.push(
			`locale_names.json has no native name for "${code}", which locale_order.json lists. ` +
				'A menu row with no name falls back to the raw code — which is exactly how the Linux ' +
				'menu came to show five two-letter codes among sixteen native names.'
		);
		continue;
	}
	if (entry.name.trim() !== entry.name) {
		errors.push(
			`the name for "${code}" has leading or trailing whitespace ("${entry.name}") — it is ` +
				'rendered verbatim in the menu, and alignment padding belongs outside the string.'
		);
	}
}
for (const code of Object.keys(names)) {
	if (!order.includes(code)) {
		errors.push(
			`locale_names.json names "${code}", which locale_order.json does not list — an unordered ` +
				'locale never appears in any menu, so the name is unreachable.'
		);
	}
}

// ── 2. Every shipped locale file is covered ─────────────────────────────────

const shipped = fs
	.readdirSync(path.join(DATA, 'locales'))
	.filter((f) => f.endsWith('.json'))
	.map((f) => f.replace(/\.json$/, ''))
	.sort();

if (shipped.length < 15) {
	errors.push(`found only ${shipped.length} locale file(s) — the scan is broken and proves nothing`);
}
for (const code of shipped) {
	if (!order.includes(code)) {
		errors.push(
			`${code}.json ships in data/locales/ but is absent from locale_order.json, so the language ` +
				'menu never offers it — a translated locale nobody can select.'
		);
	}
}

// ── 3. No driver may hand-maintain a name table again ───────────────────────
//
// The generated tables are the single consumer-facing copy. A driver that
// spells the names out again is a fourth copy, and the third one drifted.

const NATIVE_NAME_MARKERS = ['Nederlands', 'Čeština', 'Português', 'Українська'];
const GENERATED = new Set([
	'macos/_generated/locale_table.lua',
	'linux/_generated/locale_table.lua',
	'windows/_generated/locale_table.ahk'
]);

/** Production sources of the three drivers. */
function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'tests' && e.name !== 'node_modules') walk(p, acc);
		} else if (/\.(lua|ahk)$/.test(e.name)) {
			acc.push(p);
		}
	}
	return acc;
}

let scanned = 0;
for (const driver of ['macos', 'linux', 'windows']) {
	for (const abs of walk(path.join(SP, driver))) {
		const rel = path.relative(SP, abs).split(path.sep).join('/');
		if (GENERATED.has(rel)) continue;
		scanned++;
		const src = fs.readFileSync(abs, 'utf8');
		const hits = NATIVE_NAME_MARKERS.filter((m) => src.includes(m));
		// Two or more native names together is a table, not a passing mention in
		// a comment or a single example in a docstring.
		if (hits.length >= 2) {
			errors.push(
				`${rel} spells out locale native names (${hits.join(', ')}). They come from ` +
					'_shared/data/locale_names.json through _generated/locale_table.*; a hand-written ' +
					'copy is how the Linux table came to hold 16 of 21.'
			);
		}
	}
}
if (scanned < 100) {
	errors.push(`scanned only ${scanned} driver source file(s) — the walk is broken`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] locale native names:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${order.length} ordered locale(s) have a native name in one shared source, ` +
		`covering every one of the ${shipped.length} shipped locale file(s); no driver hand-maintains ` +
		`a copy (${scanned} source file(s) scanned).\x1b[0m`
);
