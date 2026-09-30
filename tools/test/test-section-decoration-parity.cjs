// tools/test/test-section-decoration-parity.cjs

/**
 * ==============================================================================
 * MODULE: Section-Title Decoration Parity & Single-Source Guard
 * DESCRIPTION:
 * The disabled menu section headers are decorated as "— Label —" on both
 * drivers. That decoration must live in exactly one place per driver and stay
 * identical across drivers, so a future edit cannot make Windows and macOS
 * render section titles differently (MS-3 audit item).
 *
 * This guard locks the root cause three ways (text-scan, no runtime needed —
 * runs in CI on any OS):
 *   1. macOS kernel: infra/i18n.lua exposes M.decorate_section wrapping text in
 *      the canonical dashes.
 *   2. AHK kernel: infra/menu_helpers.ahk's MenuSectionTitle uses the identical
 *      "— … —" decoration.
 *   3. Ratchet: NO macOS menu file re-inlines the decoration ("— " .. …) — every
 *      builder must route through the kernel (M.decorate_section / M.section /
 *      MenuUtils.build_section_header). Only the kernel file itself may contain
 *      the literal.
 *   4. No section header the feature manifest declares carries a dash of its
 *      own in any locale: the kernel frames it, and « Main gauche — Tap / Hold »
 *      read « — Main gauche — Tap / Hold — » (section-header-no-inner-dash).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const MACOS_ROOT = path.join(REPO_ROOT, 'static/ergopti_plus/macos');
const I18N_KERNEL = path.join(MACOS_ROOT, 'infra/i18n.lua');
const SHARED_LABELS = path.join(REPO_ROOT, 'static/ergopti_plus/_shared/lua/menu/labels.lua');

let total_pass = 0;
let total_fail = 0;

function check(label, file, pattern) {
	const filePath = path.join(REPO_ROOT, file);
	try {
		const content = fs.readFileSync(filePath, 'utf8');
		if (pattern.test(content)) {
			total_pass++;
			console.log(`  ${PASS_SYMBOL}  ${label}`);
		} else {
			total_fail++;
			console.log(`  ${FAIL_SYMBOL}  ${label}`);
			console.log(`       Violation: Pattern not found in ${file}`);
		}
	} catch (err) {
		total_fail++;
		console.log(`  ${FAIL_SYMBOL}  ${label}`);
		console.log(`       Error: ${err.message}`);
	}
}

// Recursively collect every .lua file under a directory.
function collectLua(dir, acc) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			collectLua(full, acc);
		} else if (entry.isFile() && entry.name.endsWith('.lua')) {
			acc.push(full);
		}
	}
	return acc;
}

// ==================================================
// ==================================================
// ======= 1/ Scan =================================
// ==================================================
// ==================================================

console.log('\n=== Section-Title Decoration Parity & Single-Source ===');

// 1. Shared kernel: _shared/lua/menu/labels.lua carries the canonical
//    decorate_section kernel. macOS i18n.lua delegates to it.
check(
	'shared: menu/labels.lua defines decorate_section with the "— … —" kernel',
	'static/ergopti_plus/_shared/lua/menu/labels.lua',
	/function M\.decorate_section\(text\)[\s\S]*return "— " \.\. text \.\. " —"/
);

check(
	'macOS: infra/i18n.lua M.decorate_section delegates to shared Labels.decorate_section',
	'static/ergopti_plus/macos/infra/i18n.lua',
	/function M\.decorate_section\(text\)[\s\S]*return Labels\.decorate_section\(text\)/
);

// 2. AHK kernel uses the identical decoration.
check(
	'AHK: infra/menu_helpers.ahk MenuSectionTitle uses the identical "— … —" decoration',
	'static/ergopti_plus/windows/infra/menu_helpers.ahk',
	/MenuSectionTitle\(Text\)\s*\{[\s\S]*return "— " \. Text \. " —"/
);

// 3. Ratchet: only the kernel file may inline the decoration; every macOS menu
//    builder must route through it. Test files are exempt — they legitimately
//    stub the i18n kernel (tests/helpers mirrors decorate_section verbatim).
const INLINE_DECORATION = /"— "\s*\.\./;
const isTest = (f) => /[\\/]tests[\\/]/.test(f);
const offenders = collectLua(MACOS_ROOT, [])
	.filter((f) => path.resolve(f) !== path.resolve(I18N_KERNEL))
	.filter((f) => path.resolve(f) !== path.resolve(SHARED_LABELS))
	.filter((f) => !isTest(f))
	.filter((f) => INLINE_DECORATION.test(fs.readFileSync(f, 'utf8')));

if (offenders.length === 0) {
	total_pass++;
	console.log(`  ${PASS_SYMBOL}  Ratchet: no macOS file re-inlines "— " .. (single source upheld)`);
} else {
	total_fail++;
	console.log(
		`  ${FAIL_SYMBOL}  Ratchet: ${offenders.length} macOS file(s) re-inline the decoration`
	);
	for (const f of offenders) {
		console.log(
			`       - ${path.relative(REPO_ROOT, f)} (route through i18n.decorate_section / M.section)`
		);
	}
}

// --- 4. Section header labels carry no dash of their own --------------------
const MANIFEST = path.join(REPO_ROOT, 'static/ergopti_plus/_shared/modules/features/manifest.toml');
const LOCALE_DIR = path.join(REPO_ROOT, 'static/ergopti_plus/_shared/data/locales');
const HEADER_KEY = /type\s*=\s*"section_header"\s*\n\s*i18n\s*=\s*"([^"]+)"/g;
const headerKeys = [...fs.readFileSync(MANIFEST, 'utf8').matchAll(HEADER_KEY)].map((m) => m[1]);
const dashed = [];
for (const file of fs.readdirSync(LOCALE_DIR).filter((f) => f.endsWith('.json'))) {
	const strings = JSON.parse(
		fs.readFileSync(path.join(LOCALE_DIR, file), 'utf8').replace(/^\uFEFF/, '')
	);
	for (const key of headerKeys) {
		if (typeof strings[key] === 'string' && strings[key].includes('—')) {
			dashed.push(`${file} ${key}: ${strings[key]}`);
		}
	}
}
if (headerKeys.length > 0 && dashed.length === 0) {
	total_pass++;
	console.log(
		`  ${PASS_SYMBOL}  ${headerKeys.length} manifest section header(s) carry no dash of their own`
	);
} else {
	total_fail++;
	console.log(
		`  ${FAIL_SYMBOL}  section headers the kernel frames must not add a dash (section-header-no-inner-dash)`
	);
	if (headerKeys.length === 0) console.log('       - no section_header found in the manifest');
	for (const line of dashed) console.log(`       - ${line}`);
}

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
