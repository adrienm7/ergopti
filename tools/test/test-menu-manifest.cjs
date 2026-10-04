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

// Choice leaf and current-caption keys must exist in all published locales.
// The broader locale shape remains owned by the existing parity audits.
function loadLocaleKeys() {
	const keysByLocale = {};
	for (const name of readdirSync(LOCALES_DIR)
		.filter((file) => file.endsWith('.json'))
		.map((file) => file.slice(0, -5))) {
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
	const channelCorpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/update_channel_rows.json'), 'utf8')
	);
	const channelDeclaration = menu.about_update_channel_menu?.find(
		(row) => row.id === 'update_channel'
	);
	require('node:assert/strict').deepEqual(channelDeclaration?.choices, channelCorpus.choices);
	require('node:assert/strict').equal(channelDeclaration?.current_choice_placeholder, '{channel}');
	const frequencyCorpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/update_check_frequency.json'), 'utf8')
	);
	const frequencyDeclaration = menu.about_update_frequency_menu?.find(
		(row) => row.id === frequencyCorpus.id
	);
	require('node:assert/strict').deepEqual(frequencyDeclaration?.choices, frequencyCorpus.choices);
	require('node:assert/strict').equal(
		frequencyDeclaration?.current_choice_suffix,
		frequencyCorpus.suffix
	);

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
				if (
					typeof item.path !== 'string' ||
					(!featurePaths.has(item.path) &&
						!(
							listName === 'about_update_channel_menu' &&
							item.id === 'update_channel' &&
							item.path === 'updater.channel'
						) &&
						!(
							listName === 'about_update_frequency_menu' &&
							item.id === 'update_check_interval' &&
							item.path === 'updater.check_interval_seconds'
						))
				) {
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
						for (const loc of Object.keys(localeKeys)) {
							if (choice.current_i18n !== undefined && !localeKeys[loc].has(choice.current_i18n))
								violations.push(`${where}: current choice label missing from ${loc}.json`);
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
		for (const relativePath of [
			'tools/build/build-menu-manifest.js',
			'tools/lib/paths.cjs',
			'static/ergopti_plus/_shared/modules/updater/channels.json',
			'static/ergopti_plus/_shared/ui/update_channels.js',
			'static/ergopti_plus/_shared/modules/updater/defaults.json',
			'static/ergopti_plus/_shared/modules/updater/schedule.js'
		]) {
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
		const channelCorpus = JSON.parse(
			readFileSync(path.join(SHARED, 'tests/corpus/menus/update_channel_rows.json'), 'utf8')
		);
		assert.deepEqual(menu.about_update_channel_menu[0].choices, channelCorpus.choices);
		assert.equal(menu.about_update_channel_menu[0].current_choice_placeholder, '{channel}');
		assert.equal(Object.hasOwn(menu.about_update_channel_menu[0], 'choice_registry'), false);
		const frequencyCorpus = JSON.parse(
			readFileSync(path.join(SHARED, 'tests/corpus/menus/update_check_frequency.json'), 'utf8')
		);
		const frequencyRow = menu.about_update_frequency_menu[0];
		assert.deepEqual(frequencyRow.choices, frequencyCorpus.choices);
		assert.equal(frequencyRow.path, frequencyCorpus.path);
		assert.equal(frequencyRow.current_choice_suffix, frequencyCorpus.suffix);
		assert.equal(Object.hasOwn(frequencyRow, 'choice_registry'), false);
		const indentationCorpus = JSON.parse(
			readFileSync(path.join(SHARED, 'tests/corpus/menus/indentation_control.json'), 'utf8')
		);
		const indentation = menu.llm_display_menu.filter((row) => row.id === indentationCorpus.row.id);
		assert.equal(indentation.length, 1, 'one shared declaration owns the numeric submenu');
		assert.deepEqual(
			indentation[0].choices,
			indentationCorpus.choices.map(({ value, prefix, i18n }) => ({
				value,
				i18n,
				label_prefix: prefix
			}))
		);
		assert.equal(indentation[0].path, indentationCorpus.row.path);
		assert.equal(indentation[0].current_choice_suffix, ': {1}');
		assert.equal(
			Object.hasOwn(indentation[0], 'platforms'),
			false,
			'all drivers use identical row order'
		);
		assert.equal(Object.hasOwn(indentation[0], 'choice_registry'), false);
		const numericChoices = 'choice_values = [-7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7]';
		assert.equal(
			original.split(numericChoices).length - 1,
			1,
			'the numeric feature owns its values once'
		);
		const publishedIndentation = fs.readFileSync(output);
		for (const replacement of [
			'choice_values = []',
			'choice_values = [-1, -1, 0, 1]',
			'choice_values = [1, 0, -1]',
			'choice_values = [-1, 0.5, 1]',
			'choice_values = [-1, "0", 1]',
			'choice_values = [1, 2]',
			'choice_values = [-9007199254740992, 0, 1]'
		]) {
			result = execute(original.replace(numericChoices, replacement));
			assert.notEqual(result.status, 0, 'malformed numeric metadata refuses before publication');
			assert.deepEqual(
				fs.readFileSync(output),
				publishedIndentation,
				'refusal preserves exact acknowledged menu bytes'
			);
		}
		for (const replacement of [
			'choice_registry = "unknown.indentation"',
			'choice_registry = "llm.indentation"\nchoice_values = [-1, 0, 1]'
		]) {
			result = execute(original.replace('choice_registry = "llm.indentation"', replacement));
			assert.notEqual(
				result.status,
				0,
				'only the registered numeric feature may own choice values'
			);
			assert.deepEqual(fs.readFileSync(output), publishedIndentation);
		}
		result = execute(original.replace(numericChoices, 'choice_values = [-1, 0, 1]'));
		assert.equal(result.status, 0, result.stderr);
		assert.deepEqual(
			JSON.parse(fs.readFileSync(output))
				.llm_display_menu.find((row) => row.id === 'llm_indentation')
				.choices.map((row) => row.value),
			[-1, 0, 1],
			'the actual feature catalogue, not a native copied range, drives codegen'
		);
		result = execute(original);
		assert.equal(result.status, 0, result.stderr);
		menu = JSON.parse(fs.readFileSync(output));
		const timingPath = path.join(
			fixture,
			'static/ergopti_plus/_shared/modules/updater/defaults.json'
		);
		const timingBytes = fs.readFileSync(timingPath);
		const ownerTiming = JSON.parse(timingBytes);
		[
			ownerTiming.timing.check_interval_presets[0].code,
			ownerTiming.timing.check_interval_presets[1].code
		] = [
			ownerTiming.timing.check_interval_presets[1].code,
			ownerTiming.timing.check_interval_presets[0].code
		];
		fs.writeFileSync(timingPath, JSON.stringify(ownerTiming));
		result = execute(original);
		assert.equal(result.status, 0, result.stderr);
		const changedChoices = JSON.parse(fs.readFileSync(output)).about_update_frequency_menu[0]
			.choices;
		assert.equal(changedChoices[0].value, 300);
		assert.equal(changedChoices[0].i18n, 'menu.about.frequency.30m');
		assert.equal(changedChoices[1].value, 1800);
		assert.equal(changedChoices[1].i18n, 'menu.about.frequency.5m');
		fs.writeFileSync(timingPath, timingBytes);
		result = execute(original);
		assert.equal(result.status, 0, result.stderr);
		const acknowledgedCadence = fs.readFileSync(output);
		for (const mutation of ['duplicate_code', 'unordered_seconds', 'misplaced_never']) {
			const invalid = JSON.parse(timingBytes);
			if (mutation === 'duplicate_code') invalid.timing.check_interval_presets[1].code = '5m';
			if (mutation === 'unordered_seconds') invalid.timing.check_interval_presets[1].seconds = 1;
			if (mutation === 'misplaced_never') invalid.timing.check_interval_presets[0].code = 'never';
			fs.writeFileSync(timingPath, JSON.stringify(invalid));
			result = execute(original);
			assert.notEqual(result.status, 0, mutation);
			assert.deepEqual(
				fs.readFileSync(output),
				acknowledgedCadence,
				'an invalid canonical cadence registry must not replace acknowledged menu bytes'
			);
		}
		fs.writeFileSync(timingPath, timingBytes);
		for (const replacement of [
			'choice_registry = "unregistered.intervals"',
			'choice_registry = "updater.channels"',
			'choice_registry = "updater.check_intervals"\nchoice_values = [300, 1800]'
		]) {
			const changed = original.replace('choice_registry = "updater.check_intervals"', replacement);
			assert.notEqual(
				changed,
				original,
				'cadence registry metadata mutation must change the source'
			);
			result = execute(changed);
			assert.notEqual(result.status, 0, result.stdout + result.stderr);
			assert.deepEqual(fs.readFileSync(output), acknowledgedCadence);
		}
		result = execute(original);
		assert.equal(result.status, 0, result.stderr);

		const registryPath = path.join(
			fixture,
			'static/ergopti_plus/_shared/modules/updater/channels.json'
		);
		const registryBytes = fs.readFileSync(registryPath);
		const reorderedRegistry = JSON.parse(registryBytes);
		reorderedRegistry.channels.reverse();
		fs.writeFileSync(registryPath, JSON.stringify(reorderedRegistry));
		result = execute(original);
		assert.equal(result.status, 0, result.stderr);
		assert.deepEqual(
			JSON.parse(fs.readFileSync(output)).about_update_channel_menu[0].choices.map(
				(choice) => choice.value
			),
			channelCorpus.reordered_values
		);
		fs.writeFileSync(registryPath, registryBytes);
		result = execute(original);
		assert.equal(result.status, 0, result.stderr);
		const acknowledgedChannels = fs.readFileSync(output);
		for (const [before, after, reason] of [
			[
				'choice_registry = "updater.channels"',
				'choice_registry = "unknown.registry"',
				'choice_registry'
			],
			['path = "updater.channel"', 'path = "updater.future"', 'registry-owned path'],
			[
				'choice_registry = "updater.channels"',
				'choice_registry = "updater.channels"\nchoice_values = ["main", "dev"]',
				'registry choices'
			],
			[
				'current_choice_placeholder = "{channel}"',
				'current_choice_placeholder = false',
				'current_choice_placeholder'
			],
			[
				'current_choice_placeholder = "{channel}"',
				'current_choice_placeholder = "channel"',
				'current_choice_placeholder'
			],
			[
				'current_choice_placeholder = "{channel}"',
				'current_choice_placeholder = "{channel}{1}"',
				'current_choice_placeholder'
			]
		]) {
			const invalid = original.replace(before, after);
			assert.notEqual(invalid, original);
			result = execute(invalid);
			assert.notEqual(result.status, 0);
			assert.match(result.stderr, new RegExp(reason));
			assert.deepEqual(
				fs.readFileSync(output),
				acknowledgedChannels,
				'invalid registry presentation preserves published bytes'
			);
		}
		for (const corrupt of [
			(registry) => {
				registry.channels[1].id = registry.channels[0].id;
			},
			(registry) => {
				registry.channels[0].menu_label_key = false;
			}
		]) {
			const invalidRegistry = JSON.parse(registryBytes);
			corrupt(invalidRegistry);
			fs.writeFileSync(registryPath, JSON.stringify(invalidRegistry));
			result = execute(original);
			assert.notEqual(
				result.status,
				0,
				'the actual canonical registry validator refuses malformed data'
			);
			assert.deepEqual(fs.readFileSync(output), acknowledgedChannels);
		}
		fs.writeFileSync(registryPath, registryBytes);
		for (const [locale, expected] of Object.entries(channelCorpus.locales)) {
			const labels = JSON.parse(
				readFileSync(path.join(LOCALES_DIR, `${locale}.json`), 'utf8').replace(/^\uFEFF+/, '')
			);
			assert.equal(labels['menu.about.channel_menu'], expected.parent_template);
			for (const [index, choice] of channelCorpus.choices.entries()) {
				assert.equal(labels[choice.i18n], expected.leaf_labels[index]);
				assert.equal(
					labels['menu.about.channel_menu'].replace('{channel}', labels[choice.current_i18n]),
					expected.captions[index]
				);
			}
		}
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

function checkInfoBarControl() {
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/info_bar_control.json'), 'utf8')
	);
	const definition = JSON.parse(readFileSync(MENU_PATH, 'utf8')).llm_display_menu;
	assert.deepEqual(corpus.states, [false, true], 'both independently captured states execute');
	assert.equal(definition.length, 8);
	assert.deepEqual(definition[0], { type: 'list', id: 'llm_display_leading' });
	assert.equal(definition[1].type, 'check');
	assert.equal(definition[1].id, corpus.row.id);
	assert.equal(definition[1].i18n, corpus.row.i18n);
	assert.deepEqual(definition[1].checked_when, ['llm_info_bar_enabled']);
	assert.deepEqual(definition[1].disabled_when, ['llm_info_bar_ready']);
	assert.deepEqual(definition[2], {
		type: 'list',
		id: 'llm_display_remaining'
	});
	for (const [file, first, last] of [
		[
			'windows/ui/menu/menu_llm/menu_settings.ahk',
			'LLM_Menu_BuildDisplayMenu(',
			'LLM_Menu_BuildNavMenu('
		],
		['macos/ui/menu/menu_llm/streaming_panel.lua', 'function M.build(', '\nreturn M\n'],
		[
			'linux/ui/menu/menu_builder.lua',
			'dynamic_handlers["llm_display"] = function',
			'dynamic_handlers["llm_navigation"] = function'
		]
	]) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		const start = source.indexOf(first);
		const end = source.indexOf(last, start);
		assert(start >= 0 && end > start, `${file}: actual display consumer bounds must exist`);
		const body = source.slice(start, end);
		for (const owner of [
			'llm_display_menu',
			'llm_info_bar',
			'llm_info_bar_enabled',
			'llm_info_bar_ready',
			'llm_display_leading',
			'llm_display_remaining'
		]) {
			assert(
				body.includes(`"${owner}"`),
				`${file}: shared Info Bar owner ${owner} must be consumed`
			);
		}
		assert(
			!body.includes(corpus.row.i18n),
			`${file}: the fixed Info Bar label belongs to the shared declaration`
		);
	}
	console.log(
		'Info Bar control: both independent states, shared label and all three actual native owners qualified.'
	);
}

function checkAutoTemperatureControl() {
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/auto_raise_temperature.json'), 'utf8')
	);
	const root = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const definition = root.llm_generation_menu;
	assert.deepEqual(corpus.states, [false, true]);
	assert.deepEqual(corpus.prediction_counts, [1, 2]);
	assert.equal(definition.length, 2);
	assert.deepEqual(definition[0], {
		type: 'list',
		id: 'llm_generation_values'
	});
	assert.equal(definition[1].type, 'check');
	assert.equal(definition[1].id, corpus.row.id);
	assert.equal(definition[1].i18n, corpus.row.i18n);
	assert.deepEqual(definition[1].checked_when, ['llm_auto_raise_enabled']);
	assert.deepEqual(definition[1].disabled_when, ['llm_auto_raise_ready']);
	assert.equal(
		root.llm_menu.find((row) => row.id === 'llm_generation').type,
		'dynamic',
		'the Linux inline caller delivers the shared child without a private list policy'
	);
	for (const [file, first, last] of [
		[
			'windows/ui/menu/menu_llm/menu_settings.ahk',
			'LLM_Menu_BuildGenerationMenu(',
			'LLM_Menu_BuildDisplayMenu('
		],
		['macos/ui/menu/menu_llm/temperature_panel.lua', 'function M.build(', '\nreturn M\n'],
		[
			'linux/ui/menu/menu_builder.lua',
			'dynamic_handlers["llm_generation"] = function',
			"-- The category switch, the submenu's first row"
		]
	]) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		const start = source.indexOf(first);
		const end = source.indexOf(last, start);
		assert(start >= 0 && end > start, `${file}: the actual generation consumer bounds must exist`);
		const body = source.slice(start, end);
		for (const owner of [
			'llm_auto_raise_temperature',
			'llm_auto_raise_enabled',
			'llm_auto_raise_ready'
		]) {
			assert(
				body.includes(`"${owner}"`),
				`${file}: shared auto-raise owner ${owner} must be consumed`
			);
		}
		assert(
			!body.includes(corpus.row.i18n),
			`${file}: the fixed label belongs to the shared declaration`
		);
		if (!file.startsWith('macos/')) {
			for (const owner of ['llm_generation_menu', 'llm_generation_values'])
				assert(body.includes(`"${owner}"`), `${file}: numeric providers must use the shared child`);
		}
	}
	const mac = readFileSync(resolve(SHARED, '../macos/ui/menu/menu_llm/init.lua'), 'utf8');
	const first = mac.indexOf('local generation_ctx = TempPanel.build(');
	const last = mac.indexOf('-- ===== Display submenu =====', first);
	assert(first >= 0 && last > first, 'the actual Mac generation caller bounds must exist');
	const body = mac.slice(first, last);
	for (const owner of ['llm_generation_menu', 'llm_generation_values'])
		assert(body.includes(`"${owner}"`), `the Mac numeric provider consumes ${owner}`);
	console.log(
		'Automatic temperature diversity: independent states/counts and all three shared generation callers qualified.'
	);
}

function checkTokenStreamingControl() {
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/token_streaming_control.json'), 'utf8')
	);
	const rows = JSON.parse(readFileSync(MENU_PATH, 'utf8')).llm_display_menu;
	assert.equal(rows.length, 8);
	assert.deepEqual(rows[3], {
		type: 'check',
		id: corpus.row.id,
		i18n: corpus.row.i18n,
		platforms: ['hs', 'linux'],
		unavailable: 'grey',
		reason_key: 'platform_reason.token_streaming_transport_missing',
		checked_when: ['llm_token_streaming_enabled'],
		disabled_when: ['llm_token_streaming_ready']
	});
	for (const [file, first, last] of [
		[
			'windows/ui/menu/menu_llm/menu_settings.ahk',
			'LLM_Menu_BuildDisplayMenu(',
			'LLM_Menu_BuildNavMenu('
		],
		['macos/ui/menu/menu_llm/streaming_panel.lua', 'function M.build(', '\nreturn M\n'],
		[
			'linux/ui/menu/menu_builder.lua',
			'dynamic_handlers["llm_display"] = function',
			'dynamic_handlers["llm_navigation"] = function'
		]
	]) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		const start = source.indexOf(first),
			end = source.indexOf(last, start);
		assert(start >= 0 && end > start, `${file}: real streaming consumer bounds must exist`);
		const body = source.slice(start, end);
		for (const owner of [corpus.row.id, 'llm_token_streaming_enabled', 'llm_token_streaming_ready'])
			assert(body.includes(`"${owner}"`), `${file}: shared streaming owner ${owner} is consumed`);
		assert(
			!body.includes(corpus.row.i18n),
			`${file}: the streaming label belongs to the shared declaration`
		);
	}
	console.log(
		'Token streaming control: exact shared row, platform refusal and three actual consumers qualified.'
	);
}

function checkShowAllControl() {
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/show_all_control.json'), 'utf8')
	);
	assert.deepEqual(corpus.states, [
		{ progressive: false, show_all: true },
		{ progressive: true, show_all: false }
	]);
	assert.deepEqual(corpus.prediction_counts, [1, 2]);
	const rows = JSON.parse(readFileSync(MENU_PATH, 'utf8')).llm_display_menu;
	assert.equal(rows.length, 8);
	assert.deepEqual(
		rows.map((row) => row.id),
		[
			'llm_display_leading',
			'llm_info_bar',
			'llm_display_remaining',
			'llm_token_streaming',
			corpus.row.id,
			undefined, // Shared separator before the numeric submenu.
			'llm_indentation',
			'llm_display_trailing'
		]
	);
	assert.equal(rows[4].type, 'check');
	assert.equal(rows[4].i18n, corpus.row.i18n);
	assert.deepEqual(rows[4].checked_when, ['llm_show_all_enabled']);
	assert.deepEqual(rows[4].disabled_when, ['llm_show_all_ready']);
	for (const [file, first, last] of [
		[
			'windows/ui/menu/menu_llm/menu_settings.ahk',
			'LLM_Menu_BuildDisplayMenu(',
			'LLM_Menu_BuildNavMenu('
		],
		['macos/ui/menu/menu_llm/streaming_panel.lua', 'function M.build(', '\nreturn M\n'],
		[
			'linux/ui/menu/menu_builder.lua',
			'dynamic_handlers["llm_display"] = function',
			'dynamic_handlers["llm_navigation"] = function'
		]
	]) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		const start = source.indexOf(first),
			end = source.indexOf(last, start);
		assert(start >= 0 && end > start, `${file}: real display consumers must exist`);
		const body = source.slice(start, end);
		for (const owner of [
			'llm_show_all',
			'llm_show_all_enabled',
			'llm_show_all_ready',
			'llm_display_trailing'
		])
			assert(body.includes(`"${owner}"`), `${file}: the actual native consumer owns ${owner}`);
		assert(!body.includes(corpus.row.i18n), `${file}: the native label must be retired`);
	}
	for (const [file, first, last, projection] of [
		[
			'windows/ui/menu/menu_llm/_index.ahk',
			'LLM_Menu_ApplySharedDefaults() {',
			'LLM_Menu_ApplySharedDefaults()',
			'LLM_DisplayShowAll(LLM_Defaults[shared_key])'
		],
		[
			'windows/modules/llm/prediction_engine.ahk',
			'LLM_Engine_ApplySharedDefaults() {',
			'_LLM_Engine_FrameSignaturePart(',
			'LLM_DisplayShowAll(LLM_Defaults[shared_key])'
		],
		[
			'windows/ui/menu/menu_llm/persist.ahk',
			'_LLM_Menu_SyncToFeatures(',
			'_LLM_Menu_AppendPersistedUpdates(',
			'LLM_DisplayProgressive(Validated["show_all_at_once"])'
		],
		[
			'windows/ui/menu/menu_llm/persist.ahk',
			'LLM_Menu_BuildSavedOpts(',
			'\n}',
			'LLM_DisplayShowAll(opts["show_all_at_once"])'
		]
	]) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		const start = source.indexOf(first),
			end = source.indexOf(last, start + first.length);
		assert(start >= 0 && end > start, `${file}: the actual typed projection bounds must exist`);
		assert(
			source.slice(start, end).includes(projection),
			`${file}: canonical/native projection cannot drift`
		);
	}
	const contract = JSON.parse(
		readFileSync(resolve(SHARED, 'modules/llm/menu_persistence_contract.json'), 'utf8')
	);
	const wire = contract.entries.find((row) => row.id === 'streaming_multi').ahk;
	assert.equal(wire.sample, false);
	assert.equal(wire.persisted_sample, true);
	console.log(
		'Show-all display: independent polarities, actual native consumers and all four Windows boundaries qualified.'
	);
}

main();
checkChoiceProjection();
checkWordExpanderControls();
function checkAutomaticTriggerControls() {
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/automatic_trigger_controls.json'), 'utf8')
	);
	const root = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(corpus.states, [
		[false, false],
		[false, true],
		[true, false],
		[true, true]
	]);
	assert.deepEqual(corpus.prediction_counts, [1, 2]);
	assert.deepEqual(
		root.llm_trigger_menu.map((row) => row.id),
		[
			'llm_trigger_leading',
			'llm_instant_on_word_end',
			'llm_after_hotstring',
			undefined,
			'llm_url_bar_filter',
			'llm_secure_field_filter',
			'llm_trigger_remaining'
		]
	);
	for (const [index, expected] of corpus.rows.entries()) {
		const declaration = root.llm_trigger_menu[index + 1];
		assert.equal(declaration.type, 'check');
		assert.equal(declaration.id, expected.id);
		assert.equal(declaration.i18n, expected.i18n);
		assert.deepEqual(declaration.checked_when, [expected.id + '_enabled']);
		assert.deepEqual(declaration.disabled_when, ['llm_trigger_ready']);
	}
	for (const [file, first, last] of [
		[
			'windows/ui/menu/menu_llm/menu_settings.ahk',
			'LLM_Menu_BuildTriggerMenu(',
			'LLM_Menu_BuildLiveModeMenu('
		],
		['macos/ui/menu/menu_llm/trigger_panel.lua', 'function M.build(', '\nreturn M\n'],
		[
			'linux/ui/menu/menu_builder.lua',
			'dynamic_handlers["llm_trigger"] = function',
			'dynamic_handlers["llm_live_mode"] = function'
		]
	]) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		const start = source.indexOf(first),
			end = source.indexOf(last, start);
		assert(start >= 0 && end > start, `${file}: real trigger consumer bounds must exist`);
		const body = source.slice(start, end);
		for (const owner of [
			'llm_trigger_menu',
			'llm_trigger_leading',
			'llm_trigger_remaining',
			'llm_instant_on_word_end',
			'llm_after_hotstring',
			'llm_instant_on_word_end_enabled',
			'llm_after_hotstring_enabled',
			'llm_trigger_ready'
		]) {
			assert(
				body.includes(`"${owner}"`),
				`${file}: shared trigger owner ${owner} must be consumed`
			);
		}
		for (const expected of corpus.rows)
			assert(
				!body.includes(expected.i18n),
				`${file}: fixed trigger labels belong to the declaration`
			);
	}
	console.log(
		'Automatic triggers: independent bool pairs and both actual native command owners declared on all drivers.'
	);
}

checkInfoBarControl();
checkAutoTemperatureControl();
checkTokenStreamingControl();
checkShowAllControl();
checkAutomaticTriggerControls();

/** Guards the actual native read sites in addition to the shared registry data. */
function checkUpdateFrequencyControl() {
	const assert = require('node:assert/strict');
	for (const [file, declaration, endMarker, renderer] of [
		['windows/ui/menu/menu_init.ahk', '_MI_FrequencyPickerRow(', '\n}', 'MenuRenderer_ChoiceRow'],
		[
			'macos/ui/menu/menu_about.lua',
			'local function frequency_picker(',
			'\nend',
			'ManifestMenu.choice_row'
		],
		[
			'linux/ui/menu/menu_builder.lua',
			'local function _frequency_picker(',
			'\nend',
			'ManifestMenu.choice_row'
		]
	]) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		const start = source.indexOf('\n' + declaration);
		assert(start >= 0, `${file}: the registered cadence binding must exist`);
		const end = source.indexOf(endMarker, start + 1);
		assert(end > start, `${file}: cadence read-site body must be nonempty`);
		const body = source.slice(start, end);
		assert(body.includes(renderer), `${file}: cadence choices must use the actual shared renderer`);
		assert(body.includes('"about_update_frequency_menu"'));
		assert(body.includes('"updater.check_interval_seconds"'));
		assert(
			!source.includes('"menu.about.frequency."'),
			`${file}: native presets and caption labels are declared centrally`
		);
	}
	console.log(
		'Update frequency: canonical numeric registry, 21 translated labels and three actual native receipt owners.'
	);
}

checkUpdateFrequencyControl();

/** Qualifies the numeric registry and actual native providers without a storage enum. */
function checkIndentationControl() {
	const assert = require('node:assert/strict');
	const raw = readFileSync(MANIFEST_PATH, 'utf8');
	const parsed = parseToml(
		raw.replace(
			/^\[\[features\.([^\]]+)\]\]\r?$/gm,
			(_match, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
		)
	);
	const feature = parsed.entries.find(
		(entry) => entry.path_prefix === 'llm.display' && entry.id === 'pred_indent'
	);
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/indentation_control.json'), 'utf8')
	);
	assert.equal(feature.type, 'number', 'existing numeric persistence remains compatible');
	assert.deepEqual(
		[...feature.choice_values],
		corpus.choices.map((choice) => choice.value)
	);
	assert.equal(feature.default, 0);
	assert.equal(feature.recommended, 0);
	const declaration = JSON.parse(readFileSync(MENU_PATH, 'utf8')).llm_display_menu;
	const row = declaration.find((entry) => entry.id === corpus.row.id);
	assert.equal(declaration.filter((entry) => entry.id === corpus.row.id).length, 1);
	assert.equal(row.path, corpus.row.path);
	assert.equal(row.i18n, corpus.row.i18n);
	assert.deepEqual(row.disabled_when, ['llm_indentation_ready']);
	assert.equal(row.type, 'choice');
	assert.equal(declaration.at(-2).id, corpus.row.id, 'all drivers share one trailing placement');
	for (const locale of readdirSync(LOCALES_DIR).filter((name) => name.endsWith('.json'))) {
		const labels = JSON.parse(readFileSync(resolve(LOCALES_DIR, locale), 'utf8'));
		for (const key of [corpus.row.i18n, ...new Set(corpus.choices.map((choice) => choice.i18n))])
			assert.equal(typeof labels[key], 'string', `${locale}: numeric units must be translated`);
	}
	for (const [file, intent, writer] of [
		[
			'windows/ui/menu/menu_llm/menu_settings.ahk',
			'LLM_DisplayIndentIntent',
			'_LLM_Menu_EnableSourceMatches'
		],
		[
			'macos/ui/menu/menu_llm/streaming_panel.lua',
			'DisplayPolicy.indentation_intent',
			'SettingsManager.publication_guard'
		],
		['linux/ui/menu/menu_builder.lua', 'DisplayPolicy.indentation_intent', 'current.source']
	]) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		assert(
			source.includes('"llm_indentation"'),
			`${file}: native provider consumes the canonical declaration`
		);
		assert(source.includes(intent), `${file}: retained commands consume shared admission`);
		assert(source.includes(writer), `${file}: publication retains native source ownership`);
	}
	console.log(
		'Indentation: fifteen shared numeric choices, existing translated units, and three acknowledged source owners.'
	);
}

checkIndentationControl();

/** Executes the canonical feature-entry schema, including numeric presentation metadata. */
function checkNumericChoiceSchema() {
	const assert = require('node:assert/strict');
	const Ajv = require('ajv/dist/2020'); // Existing pinned package-lock dependency.
	const schema = JSON.parse(
		readFileSync(resolve(SHARED, 'modules/features/manifest.schema.json'), 'utf8')
	);
	const validate = new Ajv({ strict: false }).compile(schema.$defs.feature_entry);
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/indentation_control.json'), 'utf8')
	);
	const feature = {
		id: 'pred_indent',
		default: 0,
		recommended: 0,
		input_altering: false,
		description_key: 'menu.llm.indent_label',
		type: 'number',
		choice_values: corpus.choices.map((choice) => choice.value)
	};
	assert.equal(validate(feature), true, JSON.stringify(validate.errors));
	const absentChoices = { ...feature };
	delete absentChoices.choice_values;
	assert.equal(
		validate(absentChoices),
		true,
		'ordinary numeric features need no presentation metadata'
	);
	for (const invalid of [
		{ ...feature, choice_values: [] },
		{ ...feature, choice_values: [0] },
		{ ...feature, choice_values: [0, 0] },
		{ ...feature, choice_values: [0, 0.5] },
		{ ...feature, choice_values: [0, '1'] },
		{ ...feature, choice_values: [0, 9007199254740992] },
		{ ...feature, choice_values: [0, -9007199254740992] },
		{ ...feature, choice_values: '0,1' },
		{ ...feature, type: 'string' },
		{ ...feature, type: 'enum', enum_values: [0, 1] },
		{ ...feature, type: undefined },
		{ ...feature, future_presentation_field: true }
	])
		assert.equal(
			validate(invalid),
			false,
			'actual strict schema must reject malformed or misplaced choice metadata'
		);
	console.log(
		'Numeric feature schema: declared fifteen-value catalogue, unchanged plain numbers and twelve strict negative vectors.'
	);
}

checkNumericChoiceSchema();

function checkPrivacyTriggerControls() {
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/privacy_trigger_controls.json'), 'utf8')
	);
	const root = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(corpus.states, [
		[false, false],
		[false, true],
		[true, false],
		[true, true]
	]);
	assert.deepEqual(corpus.prediction_counts, [1, 2]);
	assert.equal(root.llm_trigger_menu[3].type, '---');
	for (const [index, expected] of corpus.rows.entries()) {
		const declaration = root.llm_trigger_menu[index + 4];
		assert.equal(declaration.type, 'check');
		assert.equal(declaration.id, expected.id);
		assert.equal(declaration.i18n, expected.i18n);
		assert.deepEqual(declaration.checked_when, [expected.id + '_enabled']);
		assert.deepEqual(declaration.disabled_when, [expected.id + '_ready']);
	}
	for (const [file, startToken, endToken] of [
		[
			'windows/ui/menu/menu_llm/menu_settings.ahk',
			'LLM_Menu_BuildTriggerMenu(',
			'LLM_Menu_BuildLiveModeMenu('
		],
		['macos/ui/menu/menu_llm/trigger_panel.lua', 'function M.build(', '\nreturn M\n'],
		[
			'linux/ui/menu/menu_builder.lua',
			'dynamic_handlers["llm_trigger"] = function',
			'dynamic_handlers["llm_live_mode"] = function'
		]
	]) {
		const source = readFileSync(resolve(SHARED, '..', file), 'utf8');
		const start = source.indexOf(startToken),
			end = source.indexOf(endToken, start);
		assert(start >= 0 && end > start, file + ': actual privacy consumer bounds');
		const body = source.slice(start, end);
		for (const expected of corpus.rows) {
			for (const key of [expected.id, expected.id + '_enabled', expected.id + '_ready'])
				assert(
					body.includes('"' + key + '"'),
					file + ': shared privacy command and predicates are wired'
				);
			assert(
				!body.includes(expected.i18n),
				file + ': static privacy labels remain in shared declarations'
			);
		}
		assert(
			body.includes('privacy_snapshot') || body.includes('_LLM_Menu_PrivacySnapshot'),
			file + ': native snapshots are current'
		);
	}
}

checkPrivacyTriggerControls();

// The personal editor command is shared even while the native input master is off.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(manifest.personal_hotstring_commands, [
		{
			type: 'command',
			id: 'personal_hotstring_open_editor',
			i18n: 'menu.hotstrings.open_editor',
			disabled_when: ['personal_hotstring_editor_ready']
		}
	]);
	const vectors = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/personal_editor_command.json'), 'utf8')
	).vectors;
	assert.equal(
		vectors.length,
		7,
		'the independent corpus covers live, stale and refused native owners'
	);
	assert(vectors.some((v) => v.enabled && v.calls === 1));
	assert(vectors.some((v) => v.enabled && v.calls === 0));
	assert(vectors.some((v) => !v.enabled && v.calls === 0));
	for (const [file, site] of [
		[
			'windows/ui/menu/menu_hotstrings.ahk',
			'PersonalRows.Push(_HS_PersonalEditorRow((*) => OpenPersonalEditor()))'
		],
		[
			'macos/ui/menu/menu_hotstrings_custom.lua',
			'ManifestMenu.command_row("personal_hotstring_commands"'
		],
		['linux/ui/menu/menu_builder.lua', 'ManifestMenu.command_row("personal_hotstring_commands"']
	]) {
		const source = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', file), 'utf8');
		assert(source.includes(site), `${file}: the actual personal provider consumes the declaration`);
		assert(
			!/label\s*=\s*i18n(?:_safe|\.get)\("menu\.hotstrings\.open_editor"\)|Map\("label",\s*t\("menu\.hotstrings\.open_editor"\)/.test(
				source
			),
			`${file}: the canonical row owns its label`
		);
	}
	console.log(
		'Personal editor command: one shared declaration, three actual providers and seven independent owner states.'
	);
}

// The two configured terminal commands take their labels from their root declaration.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(
		manifest.top_level.filter((row) => row.id === 'reload' || row.id === 'quit'),
		[
			{ type: 'command', id: 'reload', i18n: 'menu.global.reload' },
			{ type: 'command', id: 'quit', i18n: 'menu.global.quit' }
		],
		'the existing root owns both lifecycle labels and their order'
	);
	for (const file of ['macos/ui/menu/builder.lua', 'linux/ui/menu/menu_builder.lua']) {
		const source = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', file), 'utf8');
		for (const id of ['reload', 'quit']) {
			assert(
				source.includes(`ManifestMenu.command_row("top_level", "${id}"`),
				`${file}: the real lifecycle provider reads its shared command`
			);
			assert(
				!new RegExp(
					`(?:label|title)\\s*=.*(?:i18n_safe|i18n\\.get)\\("menu\\.global\\.${id}"\\)`
				).test(source),
				`${file}: the lifecycle provider cannot redeclare its label`
			);
		}
	}
	const windows = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/windows/ui/menu/menu_init.ahk'),
		'utf8'
	);
	for (const [name, id, owner] of [
		['Reload', 'reload', 'ActivateReload'],
		['Quit', 'quit', 'ActivateExitApp']
	]) {
		const body = windows.match(new RegExp(`_MI_Stage${name}\\(\\) \\{([\\s\\S]*?)\\n\\}`))?.[1];
		assert(body, `the real Windows ${id} builder must be readable`);
		assert(body.includes(`MenuRenderer_CommandRow("top_level", "${id}"`));
		assert(body.includes(`MenuStartupLifecycleDispatch.Bind("${id}", ${owner})`));
		assert(
			body.includes('TrayMenuStage_AddAction(Row["label"], MenuStartupSafeCommand(Row["action"]))'),
			'the shared callback wrapper must retain native startup lifecycle admission'
		);
		assert(
			!body.includes('t("menu.global.'),
			'the native stage cannot duplicate the canonical label'
		);
	}
	console.log(
		'Configured lifecycle commands: shared labels and preserved native startup admission on all three drivers.'
	);
}

// Profile creation is one ordinary command; native providers keep the editor owners.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/profile_create_command.json'), 'utf8')
	);
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(
		menu[corpus.section].filter((row) => row.id === corpus.id),
		[{ type: 'command', id: corpus.id, i18n: corpus.i18n, disabled_when: [corpus.ready] }]
	);
	for (const file of [
		'windows/ui/menu/menu_llm/menu_profiles.ahk',
		'macos/ui/menu/menu_llm/profiles_manager.lua',
		'linux/ui/menu/menu_builder.lua'
	]) {
		const source = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', file), 'utf8');
		assert(
			source.includes(`("${corpus.section}", "${corpus.id}"`),
			`${file}: the actual provider must consume the declared Create command`
		);
		assert(
			!/label\s*=\s*i18n(?:_safe|\.get)\("menu\.profiles\.create_profile"\)|"label",\s*t\("menu\.profiles\.create_profile"\)/.test(
				source
			),
			`${file}: a native provider cannot redeclare the fixed command label`
		);
	}
	console.log('Create Profile: one common declaration and three existing native editor owners.');
}

// Cloning keeps the existing native activation/edit owners and the Create declaration.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/profile_clone_command.json'), 'utf8')
	);
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(menu[corpus.section], [
		{
			type: 'command',
			id: 'llm_profile_create',
			i18n: 'menu.profiles.create_profile',
			disabled_when: ['llm_profile_create_ready']
		},
		{ type: 'command', id: corpus.id, i18n: corpus.i18n, disabled_when: [corpus.ready] }
	]);
	for (const file of [
		'windows/ui/menu/menu_llm/menu_profiles.ahk',
		'macos/ui/menu/menu_llm/profiles_manager.lua',
		'linux/ui/menu/menu_builder.lua'
	]) {
		const source = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', file), 'utf8');
		assert(
			source.includes(`("${corpus.section}", "${corpus.id}"`),
			`${file}: the actual Clone provider must consume the shared declaration`
		);
		assert(
			!/label\s*=\s*i18n(?:_safe|\.get)\("menu\.profiles\.clone_builtin"\)|"label",\s*t\("menu\.profiles\.clone_builtin"\)/.test(
				source
			),
			`${file}: native providers cannot redeclare the fixed Clone command label`
		);
	}
	console.log(
		'Clone Profile: one common declaration and existing native activation/editor owners.'
	);
}

// Optional category sources share the ordinary command and keep native opening owners.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/hotstring_file_command.json'), 'utf8')
	);
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(menu[corpus.section], [
		{
			type: 'command',
			id: corpus.id,
			i18n: corpus.i18n,
			disabled_when: [corpus.ready]
		}
	]);
	assert.equal(menu.hotstring_category_menu[corpus.position - 1].id, corpus.provider);
	for (const file of [
		'windows/ui/menu/menu_hotstring_switches.ahk',
		'macos/ui/menu/menu_hotstrings.lua',
		'linux/ui/menu/menu_builder.lua'
	]) {
		const source = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', file), 'utf8');
		assert(
			source.includes(`("${corpus.section}", "${corpus.id}"`),
			`${file}: actual category opening provider consumes the declaration`
		);
	}
	console.log('Category file: one shared opening command and three existing native owners.');
}

// Linux selection owns one CapsWord checkbox; other drivers retain their bindings.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const corpus = JSON.parse(
		readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus/_shared/tests/corpus/menus/linux_caps_word.json'),
			'utf8'
		)
	);
	assert.deepEqual(
		manifest[corpus.section],
		[
			{
				type: 'check',
				id: 'selection_caps_word',
				i18n: 'sg_actions.caps_word',
				checked_when: ['selection_caps_word_active'],
				disabled_when: ['selection_caps_word_ready'],
				platforms: ['linux'],
				unavailable: 'hide'
			}
		],
		'the canonical declaration owns identity, label, live readiness and platform policy'
	);
	const source = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/linux/ui/menu/menu_builder.lua'),
		'utf8'
	);
	const start = source.indexOf('local function _build_shortcuts(ctx)');
	const end = source.indexOf('local function _tap_hold_key_label', start);
	assert(start >= 0 && end > start, 'the actual shortcuts provider must be readable');
	const body = source.slice(start, end);
	assert(
		body.includes('ManifestMenu.check_row("selection_caps_word_control", "selection_caps_word"'),
		'the real selection provider consumes its declaration'
	);
	assert(
		!/label\s*=\s*i18n_safe\("sg_actions\.caps_word"\)/.test(body),
		'the selection provider cannot redeclare the CapsWord label'
	);
	assert.equal(
		manifest.shortcuts_menu.find((row) => row.id === 'selection_operations').platforms.join(','),
		'linux',
		'Windows and macOS keep their existing binding owners'
	);
	console.log(
		'CapsWord selection: one Linux-only declaration and the existing acknowledged native owner.'
	);
}

// The selection case provider owns native effects; shared metadata owns its trio.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const corpus = JSON.parse(
		readFileSync(
			resolve(
				REPO_ROOT,
				'static/ergopti_plus/_shared/tests/corpus/menus/linux_selection_case.json'
			),
			'utf8'
		)
	);
	assert.deepEqual(
		manifest[corpus.section],
		corpus.commands.map((command) => ({
			type: 'command',
			id: command.id,
			i18n: command.label_key,
			disabled_when: [command.id + '_ready'],
			platforms: ['linux'],
			unavailable: 'hide'
		})),
		'the independent trio owns order, labels, native readiness and placement'
	);
	const source = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/linux/ui/menu/menu_builder.lua'),
		'utf8'
	);
	const start = source.indexOf('local case_methods = {');
	const end = source.indexOf('local helper_methods = {', start);
	assert(start >= 0 && end > start, 'the actual case provider must be nonempty');
	const body = source.slice(start, end);
	assert(
		body.includes('ManifestMenu.get_array("selection_case_commands")'),
		'the provider follows shared declaration order'
	);
	assert(
		body.includes('ManifestMenu.command_row("selection_case_commands", id'),
		'the provider consumes canonical command data'
	);
	assert(body.includes('sc[method]() ~= true'), 'a truthy native receipt cannot be borrowed');
	assert(
		!/label\s*=\s*i18n_safe\(transform\.key\)/.test(body),
		'native transforms cannot redeclare the shared labels'
	);
	assert.equal(
		manifest.shortcuts_menu.find((row) => row.id === 'selection_operations').platforms.join(','),
		'linux',
		'Windows and macOS retain actual binding owners'
	);
	console.log(
		'Selection case commands: shared trio, strict native receipts and unchanged placement.'
	);
}

// Fixed selection helpers retain the existing platform-specific native effects.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const corpus = JSON.parse(
		readFileSync(
			resolve(
				REPO_ROOT,
				'static/ergopti_plus/_shared/tests/corpus/menus/linux_selection_helpers.json'
			),
			'utf8'
		)
	);
	assert.deepEqual(
		manifest[corpus.section],
		corpus.commands.map((command) => ({
			type: 'command',
			id: command.id,
			i18n: command.label_key,
			disabled_when: [command.id + '_ready'],
			platforms: ['linux'],
			unavailable: 'hide'
		})),
		'the independent helper trio owns captions, order, readiness and placement'
	);
	const source = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/linux/ui/menu/menu_builder.lua'),
		'utf8'
	);
	const start = source.indexOf('local helper_methods = {');
	const end = source.indexOf('local handlers = {}', start);
	assert(start >= 0 && end > start, 'the actual helper provider must be nonempty');
	const body = source.slice(start, end);
	assert(body.includes('ManifestMenu.get_array("selection_helper_commands")'));
	assert(body.includes('ManifestMenu.command_row("selection_helper_commands", id'));
	assert(body.includes('sc[method]() ~= true'), 'native delivery requires exact acknowledgement');
	assert(!body.includes('i18n_safe('), 'helper captions belong to the shared declaration');
	console.log('Selection helpers: shared trio, current native ownership and Linux-only placement.');
}

// Both Agent system providers publish the same declared Off control.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/agent_system_off.json'), 'utf8')
	);
	assert.deepEqual(corpus.systems, ['system1', 'system2']);
	assert.deepEqual(
		manifest.agent_system_controls,
		[
			{
				type: 'check',
				id: corpus.row_id,
				i18n: corpus.label_key,
				checked_when: ['agent_system_is_off'],
				disabled_when: ['agent_system_off_ready']
			}
		],
		'one canonical checked Off declaration owns both native system providers'
	);
	assert.equal(corpus.states.length, 3, 'the independent states must be nonempty');
	for (const state of corpus.states) {
		assert.equal(typeof state.spec, 'string');
		assert.equal(typeof state.checked, 'boolean');
	}
	for (const [driver, relative, call] of [
		['windows', 'ui/menu/menu_llm/menu_agent.ahk', 'MenuRenderer_CheckRow'],
		['macos', 'ui/menu/menu_llm/agent_panel.lua', 'ManifestMenu.check_row'],
		['linux', 'ui/menu/agent_rows.lua', 'require("infra.manifest_menu").check_row']
	]) {
		const source = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
			'utf8'
		);
		assert(
			source.includes(call + '("agent_system_controls", "agent_system_off"'),
			driver + ' must consume actual shared checked row data'
		);
	}
	console.log('Agent system Off: one shared checked control, three actual native consumers.');
}

// Fixed child declarations own native labels/order; picker shape remains per driver.
{
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/llm_navigation_rows.json'), 'utf8')
	);
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	require('node:assert/strict').deepEqual(menu.llm_navigation_rows, corpus.rows);
	const providers = [
		['windows/ui/menu/menu_llm/menu_settings.ahk', '_MR_GetMenuDef("llm_navigation_rows")'],
		['macos/ui/menu/menu_llm/init.lua', 'ManifestMenu.get_array("llm_navigation_rows")'],
		['linux/ui/menu/menu_builder.lua', 'ManifestMenu.get_array("llm_navigation_rows")']
	];
	for (const [native, read] of providers) {
		const source = readFileSync(resolve(SHARED, '..', native), 'utf8');
		require('node:assert/strict').ok(
			source.includes(read),
			`${native} consumes the real shared child owner`
		);
		for (const row of corpus.rows)
			require('node:assert/strict').ok(source.includes(row.id), `${native} binds ${row.id}`);
	}
}

// Number-row choices share one declaration; native capability stays adapter-owned.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const expectedChoices = ['native', 'digits', 'symbols'];
	assert.equal(manifest.number_row_policy_rows.length, 1);
	const row = manifest.number_row_policy_rows[0];
	assert.equal(row.type, 'choice');
	assert.equal(row.id, 'number_row_mode');
	assert.equal(row.path, 'layout.direct_access_digits');
	assert.deepEqual(
		row.choices.map((choice) => choice.value),
		expectedChoices
	);
	assert.deepEqual(
		row.choices.map((choice) => choice.i18n),
		expectedChoices.map((mode) => `menu.layout.number_row_${mode}`)
	);
	assert.equal(
		manifest.layout_menu.filter((item) => item.type === 'list' && item.id === 'number_row_policy')
			.length,
		1
	);
	assert.equal(
		manifest.layout_menu.filter((item) => item.type === 'feature' && item.path === row.path).length,
		0,
		'the obsolete Boolean native row cannot coexist'
	);
	const localeNames = readdirSync(LOCALES_DIR).filter((name) => name.endsWith('.json'));
	assert.equal(localeNames.length, 21, 'every published locale owns the new captions and refusals');
	for (const name of localeNames) {
		const locale = JSON.parse(
			readFileSync(resolve(LOCALES_DIR, name), 'utf8').replace(/^\uFEFF/, '')
		);
		for (const key of [
			'menu.layout.number_row',
			...expectedChoices.map((mode) => `menu.layout.number_row_${mode}`),
			'platform_reason.number_row_override_unsupported',
			'platform_reason.number_row_source_unavailable'
		]) {
			assert.equal(typeof locale[key], 'string', name + ': ' + key);
			assert(locale[key].trim().length > 0, name + ': nonempty translated value');
		}
	}
	for (const [driver, relative, call] of [
		['windows', 'ui/menu/menu_init.ahk', '_LAY_NumberRowRows()'],
		[
			'macos',
			'ui/menu/menu_keyboard_layout.lua',
			'NumberRowPolicy.native_rows(ManifestMenu, render_ctx.commands)'
		],
		[
			'linux',
			'ui/menu/menu_builder.lua',
			'NumberRowPolicy.native_rows(ManifestMenu, render_ctx.commands)'
		]
	]) {
		const source = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
			'utf8'
		);
		assert(source.includes(call), driver + ': actual declared choice provider');
	}
	console.log(
		'Number-row choices: one typed declaration, 21 translations and three native providers.'
	);
}
