// tools/test/test-caps-word-auto-off-single-source.cjs

/**
 * ==============================================================================
 * MODULE: CapsWord Auto-Off Single-Source Gate
 * DESCRIPTION:
 * What ends CapsWord on its own is declared once. The delay presets are the
 * shortcuts.caps_word.idle_timeout_seconds preset_values; the delimiters are
 * the hotstring delimiter catalogue (_shared/core/domain/Terminators.spec.js),
 * whose built-in keys are the only valid shortcuts.caps_word.terminators
 * values; the pointer kinds are the [shortcuts.caps_word.pointer] features.
 * This gate pins the defaults, the shared corpus and the menu rows to those
 * declarations and refuses a driver CapsWord source that spells a delimiter
 * list or the delay presets itself.
 *
 * WHY:
 * Each driver detects these events natively, so each needs the same lists. A
 * hand copy on one driver would keep offering, or silently ignoring, a choice
 * the others changed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'features', 'manifest.toml');
const SPEC = path.join(SP, '_shared', 'core', 'domain', 'Terminators.spec.js');
const CORPUS = path.join(SP, '_shared', 'tests', 'corpus', 'caps_word', 'auto_off_vectors.json');
const EN = path.join(SP, '_shared', 'data', 'locales', 'en.json');
const PLATFORMS = ['ahk', 'hs', 'linux'];
// Physical keys a driver may bind natively and name by their delimiter key;
// the magic key is spelled "star" by unrelated hotstring code.
const NATIVE_KEYS = new Set(['space', 'tab', 'enter', 'star']);

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// The spec is CommonJS inside a type:module package (see codegen-terminators).
const specModule = { exports: {} };
// eslint-disable-next-line no-new-func
new Function('require', 'module', 'exports', fs.readFileSync(SPEC, 'utf8'))(
	require,
	specModule,
	specModule.exports
);
const catalogueKeys = specModule.exports.TERMINATOR_DEFS.filter((def) => def.key).map(
	(def) => def.key
);

const raw = fs.readFileSync(MANIFEST, 'utf8');
const flattened = toml.parse(
	raw.replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_m, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	)
);
const feature = (prefix, id) =>
	(flattened.entries || []).find((entry) => entry.path_prefix === prefix && entry.id === id);
const menu = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json'), 'utf8')
);
const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
const en = JSON.parse(fs.readFileSync(EN, 'utf8'));

// 1. Delimiters: the defaults name built-in catalogue entries only.
const terminators = feature('shortcuts.caps_word', 'terminators');
check(
	terminators && terminators.type === 'array',
	'shortcuts.caps_word.terminators must be an array feature'
);
for (const field of ['default', 'recommended']) {
	const list = terminators ? terminators[field] : undefined;
	check(Array.isArray(list), `shortcuts.caps_word.terminators.${field} must be a list`);
	for (const key of list || []) {
		check(
			catalogueKeys.includes(key),
			`shortcuts.caps_word.terminators.${field} names "${key}", no catalogue key`
		);
	}
	check(
		same(
			list,
			catalogueKeys.filter((key) => (list || []).includes(key))
		),
		`shortcuts.caps_word.terminators.${field} must follow the catalogue order`
	);
}
const corpusRows = corpus.terminator_rows.filter((key) => key !== '-');
check(
	same(corpusRows, catalogueKeys),
	'the corpus terminator_rows must be the catalogue keys in order'
);

// 2. Delay: whole seconds from 0 (never), the defaults among them.
const idle = feature('shortcuts.caps_word', 'idle_timeout_seconds');
check(
	idle && idle.type === 'number',
	'shortcuts.caps_word.idle_timeout_seconds must be a number feature'
);
const presets = idle ? idle.preset_values : undefined;
check(
	Array.isArray(presets) &&
		presets[0] === 0 &&
		presets.every(
			(value, index) => Number.isSafeInteger(value) && (index === 0 || value > presets[index - 1])
		),
	'the delay presets must be ascending whole seconds from 0 (never)'
);
for (const field of ['default', 'recommended']) {
	check(
		Array.isArray(presets) && presets.includes(idle[field]),
		`shortcuts.caps_word.idle_timeout_seconds.${field} must be one of the presets`
	);
}

// The shipped defaults are a maintainer decision (2026-10-20): 10 s and the
// eight delimiters below. A parameter of CapsWord, so the neutral value and
// the preset agree and both restore and clear land on them.
check(
	idle && idle.default === 10 && idle.recommended === 10,
	'the CapsWord delay ships at 10 s, as default and as recommended value'
);
const SHIPPED_DELIMITERS = [
	'space',
	'nbsp',
	'nnbsp',
	'tab',
	'enter',
	'comma',
	'semicolon',
	'period'
];
for (const field of ['default', 'recommended']) {
	check(
		same(terminators ? terminators[field] : undefined, SHIPPED_DELIMITERS),
		`shortcuts.caps_word.terminators.${field} must be the eight shipped delimiters in catalogue order`
	);
}

// 3. Pointer kinds: one boolean feature each, mirrored by the shared corpus; a
// platform that cannot see a kind says why in its own language.
const kinds = (flattened.entries || []).filter(
	(entry) => entry.path_prefix === 'shortcuts.caps_word.pointer'
);
const kindIds = kinds.map((entry) => entry.id);
check(kinds.length > 0, '[shortcuts.caps_word.pointer] must declare the pointer kinds');
check(
	same(corpus.pointer_kinds, kindIds),
	'the corpus pointer_kinds must be the manifest kinds in order'
);
for (const entry of kinds) {
	// Windows labels a kind its platforms leave out from this spelling: the
	// generated unavailable entries carry no description_key.
	check(
		entry.description_key === `menu.caps_word.pointer.${entry.id}`,
		`pointer kind ${entry.id}: its description_key must be menu.caps_word.pointer.${entry.id}`
	);
	check(entry.type === 'boolean', `pointer kind ${entry.id} must be a boolean feature`);
	check(
		typeof en[entry.description_key] === 'string',
		`pointer kind ${entry.id}: en.json lacks ${entry.description_key}`
	);
	if ((entry.platforms || PLATFORMS).length < PLATFORMS.length) {
		check(
			typeof entry.reason_key === 'string' && typeof en[entry.reason_key] === 'string',
			`pointer kind ${entry.id}: a platform without it needs a translated reason_key`
		);
	}
}

// 4. Menu: the submenu offers exactly these declarations on every driver.
const group = menu.caps_word_auto_off_group || [];
check(
	(menu.shortcuts_menu || []).some(
		(row) => row.type === 'group' && row.id === 'caps_word_auto_off'
	),
	'the Shortcuts menu must open the caps_word_auto_off group'
);
const choice = group[0];
check(
	choice && choice.type === 'choice' && choice.path === 'shortcuts.caps_word.idle_timeout_seconds',
	'caps_word_auto_off_group must open with the delay choice row'
);
if (choice && choice.type === 'choice' && Array.isArray(presets)) {
	check(
		same(
			choice.choices.map((entry) => entry.value),
			presets
		),
		'the delay row must offer exactly the preset_values, in order'
	);
	check(
		choice.choices[0].i18n === 'menu.caps_word.idle_timeout_never',
		'0 must be labelled as never'
	);
	check(!('custom_command' in choice), 'the delay row offers no free entry');
}
check(
	group.some((row) => row.type === 'list' && row.id === 'caps_word_terminators'),
	'the delimiter rows must come from the caps_word_terminators provider'
);
check(
	group.some((row) => row.type === 'list' && row.id === 'caps_word_pointer_kinds') &&
		!group.some((row) => row.type === 'check'),
	'the pointer rows must come from the caps_word_pointer_kinds provider, one per declared kind'
);

// 5. No driver CapsWord source spells a delimiter list or the delay presets.
const forbidden = catalogueKeys.filter((key) => !NATIVE_KEYS.has(key));
const presetSpelling = new RegExp(
	`[\\[{(]\\s*${(idle?.preset_values || []).join('\\s*,\\s*')}\\s*[\\]})]`
);
function walk(directory, out) {
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const full = path.join(directory, entry.name);
		if (entry.isDirectory()) {
			if (['_generated', 'tests', 'node_modules', 'build'].includes(entry.name)) continue;
			walk(full, out);
		} else if (/\.(lua|ahk|json)$/.test(entry.name)) {
			out.push(full);
		}
	}
	return out;
}
// The CapsWord sources are the files named after it: a shared menu file that
// merely opens the submenu also lists wrap symbols such as "period".
for (const driver of ['windows', 'macos', 'linux']) {
	const sources = walk(path.join(SP, driver), []).filter((file) =>
		/caps_?word/i.test(path.basename(file))
	);
	// Linux keeps one since its per-letter engine mode was removed (2026-10-22):
	// modules/shortcuts/caps_word_auto_off.lua.
	check(sources.length >= 1, `${driver}: expected a CapsWord source to scan`);
	for (const file of sources) {
		const source = fs.readFileSync(file, 'utf8');
		const rel = path.relative(SP, file).replace(/\\/g, '/');
		for (const key of forbidden) {
			check(
				!new RegExp(`["']${key}["']`).test(source),
				`${rel} spells the delimiter "${key}": read the catalogue through the CapsWord policy instead`
			);
		}
		check(
			!presetSpelling.test(source),
			`${rel} spells the CapsWord delay presets: read the manifest`
		);
	}
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] CapsWord auto-off single source: ${checks} check(s) passed.\x1b[0m`);
