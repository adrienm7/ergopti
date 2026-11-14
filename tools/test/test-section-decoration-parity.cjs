// tools/test/test-section-decoration-parity.cjs

/**
 * ==============================================================================
 * MODULE: Section-Title Decoration Parity & Single-Source Guard
 * DESCRIPTION:
 * Every disabled menu section header of the three drivers is drawn by one
 * format, _shared/menu/data/section_header.json, so its style changes in one
 * place and no title frames itself (the maintainer, 2026-11-03: « — Section
 * truc — », the case as the locale writes it, never capitals by hand).
 *
 * This guard locks it five ways (text scan, no runtime needed; runs in CI on
 * any OS):
 *   1. The generated Lua data and AHK constants carry the format of the JSON,
 *      and the Lua kernel (menu.labels, delegated to by macOS and Linux i18n)
 *      and the AHK kernel (MenuSectionTitle) frame with them.
 *   2. (part of 1) the AHK kernel reads the generated constants.
 *   3. Ratchet: no driver or shared Lua/AHK source outside the tests frames a
 *      header by hand (a literal joined to the prefix or the suffix, or a
 *      literal framed at both ends) (section-header-one-format).
 *   4. No locale value is framed by dashes, no section header title holds one
 *      (« Main gauche — Tap / Hold » read « — Main gauche — Tap / Hold — »), and
 *      no menu title is written in capitals (section-header-locale-case).
 *   5. Per platform, a declared header is never followed by a separator or by
 *      another header, and ends its menu only in a fragment a driver splices
 *      into its own rows (section-header-titles-rows). The built-menu tests of
 *      each driver check the same rule on the rendered menus.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const MACOS_ROOT = path.join(REPO_ROOT, 'static/ergopti_plus/macos');
const I18N_KERNEL = path.join(MACOS_ROOT, 'core/i18n/engine/i18n.lua');
const SHARED_LABELS = path.join(REPO_ROOT, 'static/ergopti_plus/_shared/menu/engine/labels.lua');

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

// 1. One format: _shared/menu/data/section_header.json, projected into the
//    Lua data menu.labels reads and the AHK constants MenuSectionTitle reads.
const FORMAT = JSON.parse(
	fs.readFileSync(
		path.join(REPO_ROOT, 'static/ergopti_plus/_shared/menu/data/section_header.json'),
		'utf8'
	)
).format;
const [PREFIX, SUFFIX] = FORMAT.split('{label}');
function generated(label, file, pattern) {
	const content = fs.readFileSync(path.join(REPO_ROOT, file), 'utf8');
	const match = pattern.exec(content);
	const ok = match !== null && match[1] === PREFIX && match[2] === SUFFIX;
	total_pass += ok ? 1 : 0;
	total_fail += ok ? 0 : 1;
	console.log(`  ${ok ? PASS_SYMBOL : FAIL_SYMBOL}  ${label}`);
	if (!ok)
		console.log(
			`       Violation: ${file} is stale; run tools/codegen/codegen-menu-section-header.cjs`
		);
}
generated(
	'shared: menu/section_header_data.lua carries the format of section_header.json',
	'static/ergopti_plus/_shared/menu/engine/section_header_data.lua',
	/prefix = "([^"]*)",\s*suffix = "([^"]*)"/
);
generated(
	'AHK: _generated/menu_section_header.ahk carries the format of section_header.json',
	'static/ergopti_plus/windows/_generated/menu_section_header.ahk',
	/MENU_SECTION_HEADER_PREFIX := "([^"]*)"\s*global MENU_SECTION_HEADER_SUFFIX := "([^"]*)"/
);
check(
	'shared: menu/labels.lua decorate_section frames with the generated format',
	'static/ergopti_plus/_shared/menu/engine/labels.lua',
	/require\("menu\.engine\.section_header_data"\)[\s\S]*function M\.decorate_section\(text\)\s*return SectionHeader\.prefix \.\. text \.\. SectionHeader\.suffix/
);
check(
	'macOS: infra/i18n.lua M.decorate_section delegates to shared Labels.decorate_section',
	'static/ergopti_plus/macos/core/i18n/engine/i18n.lua',
	/function M\.decorate_section\(text\)[\s\S]*return Labels\.decorate_section\(text\)/
);
check(
	'Linux: infra/i18n.lua M.decorate_section delegates to shared Labels.decorate_section',
	'static/ergopti_plus/linux/core/i18n/engine/i18n.lua',
	/function M\.decorate_section\(text\)[\s\S]*return Labels\.decorate_section\(text\)/
);

// 2. AHK kernel reads the same generated format.
check(
	'AHK: infra/menu_helpers.ahk MenuSectionTitle frames with the generated format',
	'static/ergopti_plus/windows/infra/menu_helpers.ahk',
	/MenuSectionTitle\(Text\)\s*\{\s*return MENU_SECTION_HEADER_PREFIX \. Text \. MENU_SECTION_HEADER_SUFFIX/
);

// 3. Ratchet: no driver or shared source frames a header by hand. Every builder
//    routes through the kernel (Labels.decorate_section, i18n.section,
//    MenuUtils.build_section_header, MenuSectionTitle); only the kernels hold the
//    frame, and they read it from the generated format. Test files are exempt:
//    they stub the kernel.
const DRIVER_ROOTS = ['macos', 'linux', 'windows', '_shared', '_shared'].map((d) =>
	path.join(REPO_ROOT, 'static/ergopti_plus', d)
);
function collectSources(dir, acc) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name !== 'tests' && entry.name !== 'test' && entry.name !== 'node_modules')
				collectSources(full, acc);
		} else if (entry.isFile() && /\.(lua|ahk)$/.test(entry.name)) {
			acc.push(full);
		}
	}
	return acc;
}
const escaped = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// A string literal that opens with the frame's prefix and is joined to more
// text, or one literal framed at both ends.
const HAND_FRAMES = [
	new RegExp(`["']${escaped(PREFIX)}["']\\s*(?:\\.\\.|\\.)`),
	new RegExp(`(?:\\.\\.|\\.)\\s*["']${escaped(SUFFIX)}["']`),
	new RegExp(`["']${escaped(PREFIX)}[^"'\\n]+${escaped(SUFFIX)}["']`)
];
const handFramed = [];
for (const file of DRIVER_ROOTS.flatMap((dir) => collectSources(dir, []))) {
	const lines = fs.readFileSync(file, 'utf8').split('\n');
	lines.forEach((line, index) => {
		const code = line.replace(/^\s*(?:--|;).*$/, '');
		if (HAND_FRAMES.some((pattern) => pattern.test(code)))
			handFramed.push(`${path.relative(REPO_ROOT, file)}:${index + 1}: ${line.trim()}`);
	});
}
if (handFramed.length === 0) {
	total_pass++;
	console.log(`  ${PASS_SYMBOL}  Ratchet: no driver or shared source frames a header by hand`);
} else {
	total_fail++;
	console.log(
		`  ${FAIL_SYMBOL}  Ratchet: ${handFramed.length} hand-framed header(s) (section-header-one-format)`
	);
	for (const line of handFramed)
		console.log(`       - ${line} (route through decorate_section / MenuSectionTitle)`);
}

// 4. No locale value forms a header by hand: no value framed by a dash at both
//    ends, no section header title carrying a dash, and no menu title in
//    capitals, which the maintainer retired (« Section truc », as the locale
//    writes it).
const LOCALE_DIR = path.join(REPO_ROOT, 'static/ergopti_plus/_shared/core/i18n/data/locales');
const MANIFEST = JSON.parse(
	fs.readFileSync(
		path.join(REPO_ROOT, 'static/ergopti_plus/_shared/menu/data/menu_manifest.json'),
		'utf8'
	)
);
// Every section_header row of the manifest, status rows included.
const headerKeys = new Set();
(function visit(node) {
	if (Array.isArray(node)) node.forEach(visit);
	else if (node && typeof node === 'object') {
		if (node.type === 'section_header' && typeof node.i18n === 'string') headerKeys.add(node.i18n);
		Object.values(node).forEach(visit);
	}
})(MANIFEST);
const FRAMED = /^\s*[—–]\s.*\s[—–]\s*$/u;
// Capitals: every letter cased and upper case, and one word of five capitals
// for a menu row (units and acronyms such as « GB RAM » or « ANSI » stay), of
// two for a header. A value holding a letter of a script without case (Han,
// kana, Hangul, Arabic, Hebrew, Devanagari) cannot shout in its own script:
// its capitals are Latin names such as « GNOME, KDE or X11 ».
function shouted(value, minimum) {
	const text = value.replace(/%[sd]|\{[^}]*\}/g, '');
	const letters = text.match(/\p{L}/gu) || [];
	const longest = Math.max(0, ...(text.match(/\p{Lu}+/gu) || []).map((word) => word.length));
	return (
		longest >= minimum &&
		letters.every((c) => c.toLowerCase() !== c.toUpperCase() && c === c.toUpperCase())
	);
}
for (const [value, minimum, expected] of [
	['RÉGLAGES DU CLAVIER', 5, true],
	['Réglages du clavier', 5, false],
	['此桌面不可用（仅限 GNOME、KDE 或 X11）', 5, false],
	['GB RAM', 5, false],
	['— OPTIONS —', 2, true]
])
	if (shouted(value, minimum) !== expected)
		throw new Error(`self-test: shouted(${JSON.stringify(value)}) must be ${expected}`);
const localeDefects = [];
for (const file of fs.readdirSync(LOCALE_DIR).filter((f) => f.endsWith('.json'))) {
	const strings = JSON.parse(
		fs.readFileSync(path.join(LOCALE_DIR, file), 'utf8').replace(/^﻿/, '')
	);
	for (const [key, value] of Object.entries(strings)) {
		if (typeof value !== 'string') continue;
		const header = headerKeys.has(key);
		if (FRAMED.test(value)) localeDefects.push(`${file} ${key}: framed by hand: ${value}`);
		else if (header && value.includes('—'))
			localeDefects.push(`${file} ${key}: a header title holds a dash: ${value}`);
		if ((header || key.startsWith('menu.')) && shouted(value, header ? 2 : 5))
			localeDefects.push(`${file} ${key}: written in capitals: ${value}`);
	}
}
if (headerKeys.size > 10 && localeDefects.length === 0) {
	total_pass++;
	console.log(
		`  ${PASS_SYMBOL}  no locale value frames a header, in capitals or with dashes (${headerKeys.size} header titles)`
	);
} else {
	total_fail++;
	console.log(
		`  ${FAIL_SYMBOL}  locale values form headers by hand (section-header-no-inner-dash, section-header-locale-case)`
	);
	if (headerKeys.size <= 10)
		console.log(`       - only ${headerKeys.size} section_header row(s) found`);
	for (const line of localeDefects) console.log(`       - ${line}`);
}

// 5. Declaration layout, per platform: a header titles the rows under it, so the
//    next row drawn there is never a separator or another header, and only a
//    fragment a driver splices into its own rows (an include target, a template
//    it renders with template_rows) may end with its header.
const PLATFORMS = ['ahk', 'hs', 'linux'];
const drawnOn = (row, platform) =>
	!Array.isArray(row.platforms) || row.unavailable === 'grey' || row.platforms.includes(platform);
const templateSources = DRIVER_ROOTS.flatMap((dir) => collectSources(dir, []))
	.map((file) => fs.readFileSync(file, 'utf8'))
	.join('\n');
const fragments = new Set();
for (const [key, rows] of Object.entries(MANIFEST)) {
	if (!Array.isArray(rows)) continue;
	for (const row of rows) if (row && row.type === 'include') fragments.add(row.section);
	if (
		new RegExp(`(?:template_rows|TemplateRows)\\(\\s*["']${escaped(key)}["']`).test(templateSources)
	)
		fragments.add(key);
}
const layoutDefects = [];
for (const [key, rows] of Object.entries(MANIFEST)) {
	if (!Array.isArray(rows) || !rows.every((row) => row && typeof row.type === 'string')) continue;
	for (const platform of PLATFORMS) {
		const drawn = rows.filter((row) => drawnOn(row, platform));
		drawn.forEach((row, index) => {
			if (row.type !== 'section_header') return;
			const next = drawn[index + 1];
			const where = `${platform} ${key}: header ${row.i18n}`;
			if (next === undefined && !fragments.has(key)) layoutDefects.push(`${where} ends its menu`);
			else if (next && next.type === '---')
				layoutDefects.push(`${where} is followed by a separator`);
			else if (next && next.type === 'section_header')
				layoutDefects.push(`${where} is followed by another header`);
		});
	}
}
if (layoutDefects.length === 0) {
	total_pass++;
	console.log(`  ${PASS_SYMBOL}  every declared section header titles real rows on each platform`);
} else {
	total_fail++;
	console.log(`  ${FAIL_SYMBOL}  section headers that title nothing (section-header-titles-rows)`);
	for (const line of layoutDefects) console.log(`       - ${line}`);
}

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
