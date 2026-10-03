#!/usr/bin/env node
// tools/test/test-menu-manifest.cjs
//
// Drift gate for the shared tray-menu manifest
// (_shared/modules/menu/menu_manifest.json). The menu is a single shared file
// both drivers read at runtime; its `feature` items reference canonical v2
// feature paths declared in _shared/modules/features/manifest.toml, and every
// item label is an i18n key resolved against _shared/data/locales/*.json. Those
// references can silently drift (a renamed feature path, a removed locale key)
// because nothing validated them — a stale `path` just renders a dead toggle,
// a missing i18n key shows the raw key string.
//
// This check is the validation layer that makes the menu provably consistent
// with the manifest (the "1 SSoT" goal): it is also the gate any future
// codegen-emitted menu tree must pass. It asserts, for every menu item across
// every list in the manifest:
//   - type === "feature" with a `path` → the path resolves to a real
//     manifest.toml feature entry;
//   - any i18n key (i18n / i18n_dynamic) exists in the
//     reference locales (fr + en — full parity is enforced separately);
//   - any `platforms` value is one of the known drivers (ahk / hs);
//   - type === "toggle" carries a non-empty `category` and ONE `i18n` key (a
//     checkbox label, never an alternating i18n_on / i18n_off pair), and is the
//     first row of its menu: it is the category's master switch.
//
// Exit 0 when clean, 1 with a list of violations otherwise.

const { readFileSync, readdirSync } = require('fs');
const { resolve, dirname } = require('path');
const { parse: parseToml } = require('smol-toml');

const REPO_ROOT = resolve(__dirname, '..', '..');
const SHARED = resolve(REPO_ROOT, 'static/ergopti_plus/_shared');
const MENU_PATH = resolve(SHARED, 'modules/menu/menu_manifest.json');
const MANIFEST_PATH = resolve(SHARED, 'modules/features/manifest.toml');
const LOCALES_DIR = resolve(SHARED, 'data/locales');

// "linux" is expressible even though no row declares it yet: I2 fixes the
// vocabulary at windows | macos | linux, and a value the schema rejects cannot
// be adopted incrementally. Rows carrying no platforms list already default to
// every platform, so admitting the name changes nothing until one is written.
const KNOWN_PLATFORMS = new Set(['ahk', 'hs', 'linux', 'both']);

// Section sub-keys that are metadata, not nested sections.
const SECTION_META_KEYS = new Set(['order', 'description_key', 'platforms', 'subsections']);

// Recursively collect every section path under [sections.*] (e.g.
// "ahk.shortcuts.alt_gr_lalt"). A menu `feature` item may target a section
// rather than a leaf feature: the renderer expands a section path into a
// mutually-exclusive sub-menu of its per-action toggles (the modifier combos).
function collectSectionPaths(node, parts, out) {
	if (!node || typeof node !== 'object' || Array.isArray(node)) return;
	for (const [key, val] of Object.entries(node)) {
		if (SECTION_META_KEYS.has(key)) continue;
		if (val && typeof val === 'object' && !Array.isArray(val)) {
			out.add([...parts, key].join('.'));
			collectSectionPaths(val, [...parts, key], out);
		}
	}
}

// Same pre-process as tools/build/build-features-manifest.js: rewrite the nested
// [[features.X.Y]] blocks into a flat [[entries]] AoT carrying a path_prefix so
// the TOML parser yields independent entries instead of sub-AoTs. Returns the
// set of all resolvable menu target paths: leaf feature paths AND section paths.
function loadResolvablePaths() {
	const raw = readFileSync(MANIFEST_PATH, 'utf8');
	const preprocessed = raw.replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_m, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	);
	const parsed = parseToml(preprocessed);
	const paths = new Set();
	for (const entry of parsed.entries || []) {
		if (entry.id && entry.path_prefix) {
			paths.add(`${entry.path_prefix}.${entry.id}`);
		}
	}
	collectSectionPaths(parsed.sections || {}, [], paths);
	return paths;
}

// Reference locale key sets. Full cross-locale parity is enforced by
// test_locale_json_valid / audit-translations; here we only need a key to
// exist, so fr (source) + en (fallback) are a sufficient reference.
function loadLocaleKeys() {
	const keysByLocale = {};
	for (const name of ['fr', 'en']) {
		const file = resolve(LOCALES_DIR, `${name}.json`);
		// Locale JSON files are UTF-8-with-BOM by convention (matches the AHK
		// driver) — strip the leading BOM code point before parsing, the same
		// fix as audit-translations.cjs already applies to these same files.
		let raw = readFileSync(file, 'utf8');
		raw = raw.replace(/^\uFEFF+/, '');
		keysByLocale[name] = new Set(Object.keys(JSON.parse(raw)));
	}
	return keysByLocale;
}

function main() {
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const featurePaths = loadResolvablePaths();
	const localeKeys = loadLocaleKeys();
	const logTokens = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/log_level_rows.json'), 'utf8')
	).levels;
	const violations = [];

	const i18nFields = ['i18n', 'i18n_dynamic'];

	// Walk every array at the top level of the manifest and validate each
	// object element. Maps (gesture_slots, hotstring_groups, …) and string
	// arrays carry no validatable references, so non-object elements are skipped.
	for (const [listName, value] of Object.entries(menu)) {
		if (!Array.isArray(value)) continue;
		value.forEach((item, idx) => {
			if (!item || typeof item !== 'object') return;
			const where = `${listName}[${idx}]`;

			if (item.type === 'feature' && typeof item.path === 'string') {
				if (!featurePaths.has(item.path)) {
					violations.push(`${where}: feature path "${item.path}" not found in manifest.toml`);
				}
			}

			if (item.type === 'toggle') {
				if (typeof item.category !== 'string' || item.category === '') {
					violations.push(`${where}: toggle is missing a non-empty "category"`);
				}
				if (typeof item.i18n !== 'string' || item.i18n === '') {
					violations.push(`${where}: toggle must name its checkbox label with one "i18n" key`);
				}
				if ('i18n_on' in item || 'i18n_off' in item) {
					violations.push(`${where}: toggle carries i18n_on/i18n_off — a checkbox has one label`);
				}
				if (idx !== 0) {
					violations.push(
						`${where}: a toggle is its menu's master switch and must be its first row`
					);
				}
			}

			if (item.type === 'choice') {
				if (typeof item.path !== 'string' || !featurePaths.has(item.path)) {
					violations.push(`${where}: choice path "${item.path}" not found in manifest.toml`);
				}
				if (!Array.isArray(item.choices) || item.choices.length < 2) {
					violations.push(`${where}: choice carries no projected values — run npm run build:menu`);
				} else {
					for (const choice of item.choices) {
						if (choice.label !== undefined) {
							// Literal labels are admitted only for the existing logger's
							// technical enum tokens, checked independently below.
							if (
								item.path !== 'script.log_level' ||
								choice.i18n !== undefined ||
								!logTokens.some(
									(entry) => entry.value === choice.value && entry.label === choice.label
								)
							)
								violations.push(`${where}: literal choice labels are reserved for log tokens`);
							continue;
						}
						for (const loc of ['fr', 'en']) {
							if (!localeKeys[loc].has(choice.i18n)) {
								violations.push(`${where}: choice label "${choice.i18n}" missing from ${loc}.json`);
							}
						}
					}
				}
			}

			for (const field of i18nFields) {
				const key = item[field];
				if (typeof key !== 'string' || key === '') continue;
				for (const loc of ['fr', 'en']) {
					if (!localeKeys[loc].has(key)) {
						violations.push(`${where}: ${field} "${key}" missing from ${loc}.json`);
					}
				}
			}

			if (item.platforms !== undefined) {
				if (!Array.isArray(item.platforms)) {
					violations.push(`${where}: "platforms" must be an array`);
				} else {
					for (const p of item.platforms) {
						if (!KNOWN_PLATFORMS.has(p)) {
							violations.push(
								`${where}: unknown platform "${p}" (expected ${[...KNOWN_PLATFORMS].join('/')})`
							);
						}
					}
				}
			}
		});
	}

	if (violations.length > 0) {
		console.error(`menu manifest drift gate: ${violations.length} violation(s):`);
		for (const v of violations) console.error(`  - ${v}`);
		process.exit(1);
	}

	console.log(
		`menu manifest drift gate: OK — ${featurePaths.size} feature paths, ` +
			`all menu feature paths + i18n keys + platforms valid.`
	);
}

/**
 * Runs the actual menu generator in an owned fixture. Fixed choice data belongs
 * to its enum feature; projection and malformed metadata are independently
 * checked before a driver renders that data.
 */
function checkChoiceProjection() {
	const assert = require('node:assert/strict');
	const fs = require('node:fs');
	const os = require('node:os');
	const path = require('node:path');
	const { spawnSync } = require('node:child_process');
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-menu-choice-'));
	try {
		for (const relativePath of ['tools/build/build-menu-manifest.js', 'tools/lib/paths.cjs']) {
			const target = path.join(fixture, relativePath);
			fs.mkdirSync(path.dirname(target), { recursive: true });
			fs.copyFileSync(path.join(REPO_ROOT, relativePath), target);
		}
		fs.writeFileSync(path.join(fixture, 'package.json'), '{"type":"module"}\n');
		fs.mkdirSync(path.join(fixture, 'node_modules'), { recursive: true });
		fs.cpSync(
			path.join(REPO_ROOT, 'node_modules/smol-toml'),
			path.join(fixture, 'node_modules/smol-toml'),
			{ recursive: true }
		);
		const manifest = path.join(
			fixture,
			'static/ergopti_plus/_shared/modules/features/manifest.toml'
		);
		const output = path.join(
			fixture,
			'static/ergopti_plus/_shared/modules/menu/menu_manifest.json'
		);
		fs.mkdirSync(path.dirname(manifest), { recursive: true });
		fs.mkdirSync(path.dirname(output), { recursive: true });
		const original = readFileSync(MANIFEST_PATH, 'utf8');
		const execute = (source) => {
			fs.writeFileSync(manifest, source);
			return spawnSync(process.execPath, ['tools/build/build-menu-manifest.js'], {
				cwd: fixture,
				encoding: 'utf8'
			});
		};
		let result = execute(original);
		assert.equal(result.status, 0, result.stderr);
		let menu = JSON.parse(fs.readFileSync(output, 'utf8'));
		assert.equal(menu.agent_menu[0].type, 'choice');
		assert.equal(menu.agent_menu[0].show_current_choice, true);
		assert.equal(
			Object.hasOwn(menu.agent_menu[0], 'choice_label_prefix'),
			false,
			'compiler metadata is consumed before runtime publication'
		);
		assert.deepEqual(menu.agent_menu[0].choices, [
			{ value: 'off', i18n: 'menu.agent.mode_off' },
			{ value: 'action', i18n: 'menu.agent.mode_action' },
			{ value: 'auto', i18n: 'menu.agent.mode_auto' }
		]);
		const reordered = original.replace(
			'enum_values = ["off", "action", "auto"]',
			'enum_values = ["auto", "off", "action"]'
		);
		assert.notEqual(reordered, original, 'the actual feature source must be changed');
		result = execute(reordered);
		assert.equal(result.status, 0, result.stderr);
		menu = JSON.parse(fs.readFileSync(output, 'utf8'));
		assert.deepEqual(
			menu.agent_menu[0].choices.map((choice) => choice.value),
			['auto', 'off', 'action']
		);
		const logCorpus = JSON.parse(
			readFileSync(path.join(SHARED, 'tests/corpus/menus/log_level_rows.json'), 'utf8')
		);
		result = execute(original);
		assert.equal(result.status, 0, result.stderr);
		menu = JSON.parse(fs.readFileSync(output, 'utf8'));
		const logRow = menu.debug_menu.find((row) => row.id === 'log_level');
		assert.equal(logRow.type, 'choice');
		assert.equal(logRow.path, 'script.log_level');
		assert.deepEqual(logRow.choices, logCorpus.levels);
		assert.equal(logRow.current_choice_suffix, ' : {1}');
		for (const key of ['choice_values', 'choice_label_kind', 'choice_icons'])
			assert.equal(Object.hasOwn(logRow, key), false, 'source metadata is consumed');
		const logOrder = original.replace(
			'choice_values = ["DEBUG", "INFO", "WARNING", "ERROR"]',
			'choice_values = ["ERROR", "DEBUG", "WARNING", "INFO"]'
		);
		assert.notEqual(logOrder, original);
		result = execute(logOrder);
		assert.equal(result.status, 0, result.stderr);
		assert.deepEqual(
			JSON.parse(fs.readFileSync(output, 'utf8'))
				.debug_menu.find((row) => row.id === 'log_level')
				.choices.map((choice) => choice.value),
			logCorpus.reordered_values
		);
		const acknowledged = fs.readFileSync(output);
		for (const [oldValue, invalidValue, reason] of [
			[
				'choice_values = ["DEBUG", "INFO", "WARNING", "ERROR"]',
				'choice_values = ["DEBUG", "DEBUG"]',
				'choice_values'
			],
			[
				'choice_values = ["DEBUG", "INFO", "WARNING", "ERROR"]',
				'choice_values = ["DEBUG", "UNKNOWN"]',
				'choice_values'
			],
			[
				'choice_values = ["DEBUG", "INFO", "WARNING", "ERROR"]',
				'choice_values = []',
				'choice_values'
			],
			[
				'choice_label_kind = "log_level_token"',
				'choice_label_kind = "literal"',
				'choice_label_kind'
			],
			[
				'path = "script.log_level"\nchoice_values',
				'path = "llm.agent_mode"\nchoice_values',
				'choice_values'
			],
			['ERROR = "❌"', 'ERROR = "untranslated caption"', 'choice_icons'],
			[
				'current_choice_suffix = " : {1}"',
				'current_choice_suffix = " level: {1}"',
				'current_choice_suffix'
			],
			['ERROR = "❌"', 'OTHER = "❌"', 'choice_icons'],
			[
				'current_choice_suffix = " : {1}"',
				'current_choice_suffix = " : {2}"',
				'current_choice_suffix'
			]
		]) {
			const invalid = original.replace(oldValue, invalidValue);
			assert.notEqual(invalid, original);
			result = execute(invalid);
			assert.notEqual(result.status, 0, 'invalid log choice projection must refuse publication');
			assert.match(result.stderr, new RegExp(reason));
			assert.deepEqual(
				fs.readFileSync(output),
				acknowledged,
				'refusal preserves acknowledged bytes'
			);
		}
		for (const [oldValue, invalidValue, reason] of [
			[
				'choice_label_prefix = "menu.agent.mode_"',
				'choice_label_prefix = ""',
				'choice_label_prefix'
			],
			[
				'choice_label_prefix = "menu.agent.mode_"',
				'choice_label_prefix = false',
				'choice_label_prefix'
			],
			['show_current_choice = true', 'show_current_choice = "true"', 'show_current_choice']
		]) {
			const invalid = original.replace(oldValue, invalidValue);
			assert.notEqual(invalid, original, 'malformed metadata must affect the actual declaration');
			result = execute(invalid);
			assert.notEqual(result.status, 0, 'malformed choice metadata must refuse publication');
			assert.match(result.stderr, new RegExp(reason));
			assert.deepEqual(
				fs.readFileSync(output),
				acknowledged,
				'a refusal preserves the last acknowledged manifest'
			);
		}
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
	console.log(
		'menu choice projection: actual enum order, legacy label keys, four log states and 12 malformed receipts qualified.'
	);
}

function checkWordExpanderControls() {
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/word_expander_controls.json'), 'utf8')
	);
	const definition = JSON.parse(readFileSync(MENU_PATH, 'utf8')).word_expanders_menu;
	assert.equal(corpus.rows.length, 3, 'every independently captured bulk control executes');
	assert.equal(definition.length, 5);
	for (const [index, expected] of corpus.rows.entries()) {
		assert.equal(definition[index].type, 'command');
		assert.equal(definition[index].id, expected.id);
		assert.equal(definition[index].i18n, expected.i18n);
		assert.deepEqual(definition[index].disabled_when, ['word_expanders_ready']);
	}
	assert.equal(definition[3].type, '---');
	assert.equal(definition[4].type, 'list');
	assert.equal(definition[4].id, 'word_expander_entries');
	const native = [
		[
			'windows/ui/menu/menu_hotstrings.ahk',
			'_HS_WordExpanderRows(',
			'; Toggle a whole catalogue entry'
		],
		[
			'macos/ui/menu/menu_hotstrings_management.lua',
			'local function bulk_set_terminators',
			'local delay_menu'
		],
		[
			'linux/ui/menu/menu_builder.lua',
			'["word_expanders"] = function()',
			'["magic_key_config"] = function()'
		]
	];
	for (const [file, first, last] of native) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		const start = source.indexOf(first);
		const end = source.indexOf(last, start);
		assert(start >= 0 && end > start, `${file}: actual provider bounds must exist`);
		const body = source.slice(start, end);
		assert.match(body, /["']word_expanders_menu["']/);
		assert.match(body, /["']word_expander_entries["']/);
		assert.match(body, /submenu/i);
		for (const expected of corpus.rows) {
			assert(
				!body.includes(expected.i18n),
				`${file}: fixed bulk labels belong to the shared section`
			);
		}
	}
	console.log(
		'word-expander controls: three independent rows and every native shared-section consumer qualified.'
	);
}

main();
checkChoiceProjection();
checkWordExpanderControls();
