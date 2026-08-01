// tools/test/test-locale-order-single-source.cjs
/**
 * ==============================================================================
 * MODULE: Locale Display-Order Single-Source Guard
 * DESCRIPTION:
 * Verifies that the language-menu display order is single-sourced from
 * _shared/data/locale_order.json and can never desync across the surfaces that
 * list locales:
 *   - The order array covers EXACTLY the locale JSON files shipped in
 *     _shared/data/locales/ (no missing, no extra, no duplicates) — so adding
 *     or removing a locale forces a matching order edit.
 *   - The macOS locale table (macos/_generated/locale_table.lua) is emitted in
 *     that order. It used to be hand-written in infra/i18n.lua, with the native
 *     NAMES hand-written in three places — and the Linux copy had fallen five
 *     locales behind, so both columns are generated now.
 *   - The Windows locale table (windows/_generated/locale_table.ahk) is emitted in
 *     that order.
 *   - The site loader (routes/ergopti-plus/+page.server.js) and the Linux
 *     driver (linux/infra/i18n.lua) read locale_order.json at runtime rather
 *     than sorting on their own.
 *
 * ROOT CAUSE ENCODED:
 * The four surfaces each computed their own order (macOS: name in UTF-8 byte
 * order; Windows: StrCompare by name; Linux: alphabetical by code; site:
 * Latin-first localeCompare) so Čeština landed in a different place on each.
 * They now derive from one file; this gate keeps every surface pinned to it.
 * ==============================================================================
 */
'use strict';
const fs = require('fs');
const p = require('path');

const ROOT = p.resolve(__dirname, '..', '..');
const SHARED = p.join(ROOT, 'static/ergopti_plus/_shared');
const ORDER_PATH = p.join(SHARED, 'data/locale_order.json');
const LOCALES_DIR = p.join(SHARED, 'data/locales');

const errors = [];
const read = (rel) => fs.readFileSync(p.isAbsolute(rel) ? rel : p.join(ROOT, rel), 'utf-8');

// ── 1. The order file itself ────────────────────────────────────────────────
let order = [];
try {
	const doc = JSON.parse(read(ORDER_PATH));
	if (!Array.isArray(doc.order)) {
		errors.push('locale_order.json has no "order" array.');
	} else {
		order = doc.order;
	}
} catch (e) {
	errors.push(`locale_order.json is missing or invalid JSON: ${e.message}`);
}

if (order.length > 0) {
	const dupes = order.filter((c, i) => order.indexOf(c) !== i);
	if (dupes.length) errors.push(`locale_order.json has duplicate codes: ${[...new Set(dupes)].join(', ')}`);

	// ── 2. Exact coverage of the shipped locale files ───────────────────────
	const shipped = fs
		.readdirSync(LOCALES_DIR)
		.filter((f) => f.endsWith('.json') && !f.startsWith('_'))
		.map((f) => f.replace(/\.json$/, ''))
		.sort();
	const ordered = [...order].sort();
	const missing = shipped.filter((c) => !order.includes(c));
	const extra = order.filter((c) => !shipped.includes(c));
	if (missing.length) errors.push(`Locales shipped but absent from locale_order.json: ${missing.join(', ')}`);
	if (extra.length) errors.push(`Codes in locale_order.json with no locale file: ${extra.join(', ')}`);
	void ordered;

	// ── 3. macOS table declared in canonical order ──────────────────────────
	const luaCodes = [...read('static/ergopti_plus/macos/_generated/locale_table.lua').matchAll(/code\s*=\s*"([a-z]+)"/g)].map(
		(m) => m[1]
	);
	if (luaCodes.join(',') !== order.join(',')) {
		errors.push(
			`macOS locale table order != locale_order.json.\n    order.json: ${order.join(' ')}\n    generated : ${luaCodes.join(' ')}`
		);
	}

	// ── 4. Windows table declared in canonical order ────────────────────────
	const ahkCodes = [
		...read('static/ergopti_plus/windows/_generated/locale_table.ahk').matchAll(/Code:\s*"([a-z]+)"/g)
	].map((m) => m[1]);
	if (ahkCodes.join(',') !== order.join(',')) {
		errors.push(
			`Windows locale table order != locale_order.json.\n    order.json: ${order.join(' ')}\n    generated : ${ahkCodes.join(' ')}`
		);
	}
}

// ── 5. Site + Linux read the shared file (do not roll their own order) ───────
const site = read('src/routes/ergopti-plus/+page.server.js');
if (!/locale_order\.json/.test(site)) {
	errors.push('+page.server.js does not read locale_order.json — it must single-source the order.');
}
const linux = read('static/ergopti_plus/linux/infra/i18n.lua');
if (!/locale_order\.json/.test(linux)) {
	errors.push('linux/infra/i18n.lua does not read locale_order.json — it must single-source the order.');
}

// ── Report ───────────────────────────────────────────────────────────────────
if (errors.length) {
	console.error('✗ locale display-order single-source guard FAILED:\n');
	for (const e of errors) console.error('  • ' + e);
	process.exit(1);
}
console.log(`✓ locale display order single-sourced from locale_order.json (${order.length} locales, 4 surfaces pinned).`);
