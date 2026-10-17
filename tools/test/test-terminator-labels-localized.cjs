// tools/test/test-terminator-labels-localized.cjs

/**
 * ==============================================================================
 * MODULE: Terminator Label Localization Guard
 * DESCRIPTION:
 * The rows of Hotstrings > Settings > Word expanders must show the active
 * language on every driver. Each built-in catalogue slot carries a locale key,
 * every locale translates it, and each driver's row provider resolves it.
 *
 * ROOT CAUSE ENCODED:
 * The shared catalogue (Terminators.spec.js) shipped French display strings
 * ("␣ : Espace", "; : Point-virgule", …) and the generated AHK and Lua copies
 * carried them verbatim. Windows and Linux rendered them as-is; macOS
 * re-resolved five of the twenty-five through i18n and patched two more with
 * French-to-English gsub calls. An English user therefore saw a French menu.
 *
 * WHY THE EXISTING LOCALE GATES MISSED IT:
 * `audit-translations.cjs` checks the keys passed to t(), and
 * `test-locale-catalogue-complete.cjs` compares the catalogues key-for-key.
 * A display string held in data is neither a t() call nor a key, so both gates
 * were green while every non-French user read French. This guard checks the
 * data itself, the locale values and the three renderers.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SPEC = path.join(SP, '_shared', 'core', 'domain', 'Terminators.spec.js');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');
const GENERATED = {
	ahk: path.join(SP, 'windows', '_generated', 'terminators.ahk'),
	lua: path.join(SP, '_shared', 'lua', 'keymap', 'terminators_catalogue.lua')
};
const RENDERERS = [
	{
		file: path.join(SP, 'windows', 'ui', 'menu', 'menu_hotstrings.ahk'),
		resolves: 't(D["label_key"])',
		forbidden: ['D["label"]']
	},
	{
		file: path.join(SP, 'macos', 'ui', 'menu', 'menu_hotstrings_management.lua'),
		resolves: 'i18n.get(def.label_key)',
		forbidden: ['def.label or ""', 'Guillemets fermants', 'Tiret bas']
	},
	{
		file: path.join(SP, 'linux', 'ui', 'menu', 'menu_builder.lua'),
		resolves: 'i18n_safe(def.label_key)',
		forbidden: ['(def.label or key)']
	}
];

// Floors: a guard that reads nothing passes for free.
const MIN_SLOTS = 20;
const MIN_LOCALES = 21;

const errors = [];

// =========================================
// =========================================
// ======= 1/ The shared catalogue =======
// =========================================
// =========================================

// The spec is CommonJS inside an ESM package; load it the way its codegen does.
const specModule = { exports: {} };
new Function('require', 'module', 'exports', fs.readFileSync(SPEC, 'utf8'))(
	require,
	specModule,
	specModule.exports
);
const slots = specModule.exports.TERMINATOR_DEFS.filter((def) => def.type !== 'separator');
if (slots.length < MIN_SLOTS) {
	errors.push(`only ${slots.length} built-in slot(s) found — the spec shape changed`);
}

for (const def of slots) {
	const expected = `terminators.label_${def.key}`;
	if (def.label !== undefined) {
		errors.push(
			`Terminators.spec.js slot "${def.key}" carries the literal label ${JSON.stringify(def.label)}; ` +
				'a literal shows one language to every user — declare only its label_key'
		);
	}
	if (def.label_key !== expected) {
		errors.push(`Terminators.spec.js slot "${def.key}" must declare label_key "${expected}"`);
	}
}

// =========================================
// =========================================
// ======= 2/ Every locale translates every slot =======
// =========================================
// =========================================

const locales = {};
for (const file of fs.readdirSync(LOCALES).filter((name) => name.endsWith('.json'))) {
	locales[file.replace(/\.json$/, '')] = JSON.parse(
		fs.readFileSync(path.join(LOCALES, file), 'utf8')
	);
}
if (Object.keys(locales).length < MIN_LOCALES) {
	errors.push(`only ${Object.keys(locales).length} locale file(s) found — expected ${MIN_LOCALES}`);
}
const french = locales.fr || {};
const english = locales.en || {};

for (const def of slots) {
	const key = `terminators.label_${def.key}`;
	for (const [code, strings] of Object.entries(locales)) {
		const value = strings[key];
		if (typeof value !== 'string' || value.trim() === '') {
			errors.push(`${code}.json has no value for ${key}`);
			continue;
		}
		// A French value in another locale is the original symptom. A word that
		// French shares with English ("Slash") is a loanword, not a copy.
		if (code !== 'fr' && value === french[key] && value !== english[key]) {
			errors.push(`${code}.json copies the French text for ${key}: ${JSON.stringify(value)}`);
		}
	}
}

// =========================================
// =========================================
// ======= 3/ Generated copies and renderers =======
// =========================================
// =========================================

const ahk = fs.readFileSync(GENERATED.ahk, 'utf8');
const lua = fs.readFileSync(GENERATED.lua, 'utf8');
for (const def of slots) {
	const key = `terminators.label_${def.key}`;
	if (!ahk.includes(`"label_key", "${key}"`)) {
		errors.push(
			`windows/_generated/terminators.ahk does not carry ${key}; run npm run codegen:terminators`
		);
	}
	if (!lua.includes(`label_key = "${key}"`)) {
		errors.push(`terminators_catalogue.lua does not carry ${key}; run npm run codegen:terminators`);
	}
}
if (/Map\("key", "(?!separator_)[^"]+", "chars", \[[^\]]*\], "label",/.test(ahk)) {
	errors.push('windows/_generated/terminators.ahk still carries a literal built-in label');
}
if (/\{ key = "[^"]+", chars = \{[^}]*\}, label =/.test(lua)) {
	errors.push('terminators_catalogue.lua still carries a literal built-in label');
}

for (const renderer of RENDERERS) {
	const source = fs.readFileSync(renderer.file, 'utf8');
	const rel = path.relative(ROOT, renderer.file).replace(/\\/g, '/');
	if (!source.includes(renderer.resolves)) {
		errors.push(`${rel} must resolve each catalogue row with ${renderer.resolves}`);
	}
	for (const needle of renderer.forbidden) {
		if (source.includes(needle)) {
			errors.push(`${rel} still renders catalogue text without i18n (${needle})`);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Word-expander rows are not localized:\x1b[0m');
	for (const error of errors) console.error('    - ' + error);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${slots.length} word-expander slot(s) resolve a translated label in ` +
		`${Object.keys(locales).length} locale(s) on Windows, macOS and Linux.\x1b[0m`
);
