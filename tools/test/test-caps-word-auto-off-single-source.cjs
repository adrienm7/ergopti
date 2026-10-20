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
 * This gate pins the defaults and the shared corpus to those declarations and
 * refuses a driver CapsWord source that spells a delimiter list or the presets
 * itself.
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

// 4. No driver CapsWord source spells a delimiter list or the delay presets.
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
for (const driver of ['windows', 'macos', 'linux']) {
	for (const file of walk(path.join(SP, driver), [])) {
		const source = fs.readFileSync(file, 'utf8');
		if (!/caps_?word/i.test(source)) continue;
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
