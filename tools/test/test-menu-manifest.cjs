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

			for (const declaration of Object.values(item.status_rows || {})) {
				for (const row of declaration) {
					if (row.type !== 'label') continue;
					for (const [locale, keys] of Object.entries(localeKeys))
						if (!keys.has(row.i18n))
							violations.push(`${where}: status label missing from ${locale}.json`);
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
			'tools/lib/menu-row-availability.cjs',
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
		const acknowledgedTemplates = fs.readFileSync(output);
		const legacyHeaders = [
			'shortcuts_menu',
			'metrics_menu',
			'layout_menu',
			'hotstrings_menu',
			'tap_holds_menu'
		].flatMap((key) => {
			const rows = menu[key];
			return Array.isArray(rows) ? rows.filter((row) => row.type === 'section_header') : [];
		});
		assert.equal(legacyHeaders.length, 12, 'all existing id-less headers survive compilation');
		assert(
			legacyHeaders.every((row) => !Object.hasOwn(row, 'id')),
			'the header primitive cannot impose identities on existing records'
		);
		const headerSource =
			'\n[[menu.fixture_header_template]]\ntype = "section_header"\ni18n = "menu.metrics.privacy_header"\n';
		for (const fields of [
			'',
			'id = "named_header"\n',
			'platforms = ["hs"]\nreason_key = "platform_reason.layout_bundle_and_menubar_are_macos"\n',
			'platforms = ["hs"]\nunavailable = "grey"\nreason_key = "platform_reason.layout_bundle_and_menubar_are_macos"\n'
		]) {
			result = execute(original + headerSource + fields);
			assert.equal(result.status, 0, result.stderr);
			const declared = JSON.parse(fs.readFileSync(output, 'utf8')).fixture_header_template;
			assert.equal(declared.length, 1, 'actual compiler projects one inert header');
			assert.equal(declared[0].type, 'section_header');
			assert.equal(declared[0].i18n, 'menu.metrics.privacy_header');
			assert.equal(
				Object.hasOwn(declared[0], 'command'),
				false,
				'compiler invents no native callback'
			);
		}
		result = execute(original);
		assert.equal(result.status, 0, result.stderr);
		assert.deepEqual(
			fs.readFileSync(output),
			acknowledgedTemplates,
			'positive fixture compilation preserves the original artifact after restoration'
		);
		for (const [name, fields, caption, reason] of [
			['empty id', 'id = ""', 'menu.metrics.privacy_header', /section header needs/],
			['numeric id', 'id = 7', 'menu.metrics.privacy_header', /section header needs/],
			['empty caption', '', '', /section header needs/],
			[
				'empty unavailable',
				'platforms = ["hs"]\nunavailable = ""',
				'menu.metrics.privacy_header',
				/unavailable must/
			],
			[
				'grey header without reason',
				'platforms = ["hs"]\nunavailable = "grey"',
				'menu.metrics.privacy_header',
				/greyed row needs/
			],
			['empty reason', 'reason_key = ""', 'menu.metrics.privacy_header', /section header needs/],
			['numeric reason', 'reason_key = 7', 'menu.metrics.privacy_header', /section header needs/],
			...[
				'command',
				'caption_getter',
				'checked_when',
				'disabled_when',
				'disabled',
				'action',
				'items',
				'foreign_field',
				'I18N'
			].map((field) => [
				field,
				`${field} = "unowned"`,
				'menu.metrics.privacy_header',
				/section header needs/
			])
		]) {
			const source =
				original + headerSource.replace('menu.metrics.privacy_header', caption) + fields + '\n';
			result = execute(source);
			assert.notEqual(result.status, 0, name + ': actual compiler refuses invalid header metadata');
			assert.match(result.stderr, reason, name + ': header refusal is classified');
			assert.deepEqual(
				fs.readFileSync(output),
				acknowledgedTemplates,
				name + ': refusal cannot publish a partial artifact'
			);
		}

		const backendStatus = menu.llm_menu.find((row) => row.id === 'llm_backend').status_rows;
		assert.deepEqual(
			backendStatus.unavailable,
			[
				{ type: '---' },
				{ type: 'label', i18n: 'menu.llm.local_servers.header' },
				{ type: 'label', i18n: 'menu.llm.unavailable' }
			],
			'existing provider owns exact independent status data'
		);
		assert.equal(
			Object.hasOwn(menu, 'llm_local_servers_unavailable'),
			false,
			'status is not another menu'
		);
		for (const [name, source, reason] of [
			[
				'status effect',
				original.replace(
					'type = "label", i18n = "menu.llm.unavailable"',
					'type = "label", i18n = "menu.llm.unavailable", action = "foreign"'
				),
				/only inert/
			],
			[
				'status empty caption',
				original.replace(
					'type = "label", i18n = "menu.llm.unavailable"',
					'type = "label", i18n = ""'
				),
				/only inert/
			],
			[
				'status submenu',
				original.replace(
					'type = "label", i18n = "menu.llm.unavailable"',
					'type = "group", i18n = "menu.llm.unavailable"'
				),
				/only inert/
			]
		]) {
			assert.notEqual(source, original, name + ': mutation reaches actual metadata');
			result = execute(source);
			assert.notEqual(result.status, 0, name + ': actual generator refuses');
			assert.match(result.stderr, reason, name + ': classified refusal');
			assert.deepEqual(
				fs.readFileSync(output),
				acknowledgedTemplates,
				name + ': published data retained'
			);
		}

		for (const [name, source, reason] of [
			[
				'missing include',
				original.replace(
					'section = "tap_hold_key_native_commands"',
					'section = "absent_child_template"'
				),
				/include needs an existing menu section/
			],
			[
				'cyclic include',
				original.replace(
					'section = "tap_hold_key_native_commands"',
					'section = "tap_hold_key_head"'
				),
				/cyclic child-template include/
			],
			[
				'include payload',
				original.replace(
					'section = "tap_hold_key_native_commands"',
					'section = "tap_hold_key_native_commands"\ncommand = "foreign"'
				),
				/include only composes/
			],
			[
				'empty caption getter',
				original.replace('caption_getter = "tap_hold_key_tap_caption"', 'caption_getter = ""'),
				/caption_getter needs a labelled command, check or group/
			],
			[
				'numeric caption getter',
				original.replace('caption_getter = "tap_hold_key_tap_caption"', 'caption_getter = 42'),
				/caption_getter needs a labelled command, check or group/
			],
			[
				'empty checkbox caption getter',
				original.replace(
					'caption_getter = "tap_hold_key_global_delay_caption"',
					'caption_getter = ""'
				),
				/caption_getter needs a labelled command, check or group/
			],
			[
				'numeric checkbox caption getter',
				original.replace(
					'caption_getter = "tap_hold_key_global_delay_caption"',
					'caption_getter = 42'
				),
				/caption_getter needs a labelled command, check or group/
			],
			[
				'unsupported caption row',
				original.replace(
					'[[menu.tap_hold_key_head]]\ntype = "command"',
					'[[menu.tap_hold_key_head]]\ntype = "list"'
				),
				/caption_getter needs a labelled command, check or group/
			]
		]) {
			assert.notEqual(source, original, name + ': mutation targets a real declaration');
			result = execute(source);
			assert.notEqual(result.status, 0, name + ': actual generator must refuse invalid metadata');
			assert.match(result.stderr, reason, name + ': classified refusal');
			assert.deepEqual(
				fs.readFileSync(output),
				acknowledgedTemplates,
				name + ': refusal cannot publish'
			);
		}
		const statusHeader = '[[menu.metrics_migration_unavailable_rows]]\ntype = "label"\n';
		for (const [name, mutated] of [
			[
				'missing identity',
				original.replace(statusHeader + 'id = "metrics_migration_unavailable"\n', statusHeader)
			],
			[
				'empty caption',
				original.replace('i18n = "menu.metrics.migration_unavailable"', 'i18n = ""')
			],
			[
				'numeric caption',
				original.replace('i18n = "menu.metrics.migration_unavailable"', 'i18n = 42')
			],
			...['command', 'caption_getter', 'checked_when', 'disabled', 'I18N'].map((field) => [
				field,
				original.replace(statusHeader, statusHeader + field + ' = "foreign"\n')
			])
		]) {
			assert.notEqual(mutated, original, name + ': label mutation must target the real source');
			result = execute(mutated);
			assert.notEqual(result.status, 0, name + ': the compiler rejects invalid inert labels');
			assert.match(
				result.stderr,
				/inert label needs an identity and caption without behavior metadata/
			);
			assert.deepEqual(
				fs.readFileSync(output),
				acknowledgedTemplates,
				name + ': rejected label cannot publish'
			);
		}
		result = execute(original);
		assert.equal(result.status, 0, result.stderr);
		assert.deepEqual(
			fs.readFileSync(output),
			acknowledgedTemplates,
			'template validation is repeatable'
		);
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

// Limit structural proofs to the genuine native provider and its private data helpers.
function profileFrameOwnerSource(source, platform) {
	const tokens = require('../lib/script-source.cjs').scriptTokens(
		source,
		platform === 'ahk' ? '.ahk' : '.lua'
	);
	const [start, end] =
		platform === 'ahk'
			? [
					['_LLM_Menu_ProfileRows', '(', ')', '{'],
					['_LLM_Menu_PerAppProfileRows', '(', ')', '{']
				]
			: platform === 'hs'
				? [
						['local', 'function', 'build_profile_menu', '('],
						['function', 'M', '.', 'new', '(']
					]
				: [
						['dynamic_handlers', '[', 'llm_profile', ']', '=', 'function'],
						['dynamic_handlers', '[', 'llm_display', ']', '=', 'function']
					];
	function matches(at, values) {
		if (tokens[at - 1]?.kind === 'symbol' && ['.', ':'].includes(tokens[at - 1].value))
			return false;
		return values.every((value, offset) => {
			const token = tokens[at + offset];
			if (platform === 'ahk' && offset === 0 && token) {
				const before = source.charCodeAt(token.start - 1);
				if (before > 0x7f || /[A-Za-z0-9_]/.test(source[token.start - 1] || '')) return false;
			}
			const string = platform === 'linux' && offset === 2;
			const kind = string ? 'string' : /^[A-Za-z_]\w*$/.test(value) ? 'identifier' : 'symbol';
			return token?.kind === kind && token.value === value;
		});
	}
	const starts = tokens.map((_, at) => at).filter((at) => matches(at, start));
	if (starts.length !== 1) return '';
	const at = starts[0];
	const until = tokens.findIndex((_, index) => index > at && matches(index, end));
	return until > at ? source.slice(tokens[at].start, tokens[until].start) : '';
}

// Actual provider -> ordered frame -> exact shared command import; never a vestigial direct call.
function consumesProfileFrameCommand(source, file, menu, section, id) {
	source = profileFrameOwnerSource(
		source,
		file.startsWith('windows/') ? 'ahk' : file.startsWith('macos/') ? 'hs' : 'linux'
	);
	const tokens = require('../lib/script-source.cjs').scriptTokens(
		source,
		file.endsWith('.ahk') ? '.ahk' : '.lua'
	);
	const has = (values) =>
		tokens.some((_, index) =>
			values.every((value, offset) => tokens[index + offset]?.value === value)
		);
	const windows = file.startsWith('windows/');
	const frame = windows ? 'llm_profile_windows_frame' : 'llm_profile_lua_frame';
	if (
		!has(
			windows
				? ['return', 'MenuRenderer_TemplateRows', '(', frame, ',']
				: ['local', 'rows', '=', 'ManifestMenu', '.', 'template_rows', '(', frame, ',']
		)
	)
		return false;
	const native = windows
		? id === 'llm_profile_create'
			? 'LLM_Menu_PromptCreateProfile'
			: 'LLM_Menu_CloneActiveBuiltinProfile'
		: id === 'llm_profile_create'
			? file.startsWith('macos/')
				? 'create_profile'
				: 'function'
			: 'function';
	if (!has(windows ? [id, ',', native] : ['[', id, ']', '=', native])) return false;
	const ready =
		id === 'llm_profile_create' ? 'llm_profile_create_ready' : 'llm_profile_clone_ready';
	if (
		!has(
			windows
				? [ready, ',', '_LLM_Menu_CreateProfileReady', '.', 'Bind', '(']
				: ['[', ready, ']', '=', 'create_ready']
		)
	)
		return false;
	function imported(key, visiting = new Set()) {
		if (visiting.has(key) || !Array.isArray(menu[key])) return false;
		visiting.add(key);
		for (const row of menu[key]) {
			if (row.type !== 'include') continue;
			if (row.section === section && row.row_id === id) return true;
			if (row.row_id === undefined && imported(row.section, new Set(visiting))) return true;
		}
		return false;
	}
	return imported(frame);
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
			consumesProfileFrameCommand(source, file, menu, corpus.section, corpus.id),
			`${file}: the actual provider must consume the declared Create command`
		);
		assert(
			!/label\s*=\s*i18n(?:_safe|\.get)\("menu\.profiles\.create_profile"\)|"label",\s*t\("menu\.profiles\.create_profile"\)/.test(
				source
			),
			`${file}: a native provider cannot redeclare the fixed command label`
		);
		const frame = file.startsWith('windows/')
			? 'llm_profile_windows_frame'
			: 'llm_profile_lua_frame';
		for (const changed of [
			source.replaceAll('"' + frame + '"', '"wrong_frame"'),
			source.replaceAll('"' + corpus.id + '"', '"wrong_callback"'),
			source.replaceAll('"' + corpus.ready + '"', '"wrong_readiness"')
		])
			assert.equal(
				consumesProfileFrameCommand(changed, file, menu, corpus.section, corpus.id),
				false
			);
		const wrong = structuredClone(menu);
		for (const rows of Object.values(wrong))
			if (Array.isArray(rows))
				for (const row of rows)
					if (row.type === 'include' && row.section === corpus.section && row.row_id === corpus.id)
						row.row_id = 'missing';
		assert.equal(
			consumesProfileFrameCommand(source, file, wrong, corpus.section, corpus.id),
			false
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
			consumesProfileFrameCommand(source, file, menu, corpus.section, corpus.id),
			`${file}: the actual Clone provider must consume the shared declaration`
		);
		assert(
			!/label\s*=\s*i18n(?:_safe|\.get)\("menu\.profiles\.clone_builtin"\)|"label",\s*t\("menu\.profiles\.clone_builtin"\)/.test(
				source
			),
			`${file}: native providers cannot redeclare the fixed Clone command label`
		);
		const frame = file.startsWith('windows/')
			? 'llm_profile_windows_frame'
			: 'llm_profile_lua_frame';
		for (const changed of [
			source.replaceAll('"' + frame + '"', '"wrong_frame"'),
			source.replaceAll('"' + corpus.id + '"', '"wrong_callback"'),
			source.replaceAll('"' + corpus.ready + '"', '"wrong_readiness"')
		])
			assert.equal(
				consumesProfileFrameCommand(changed, file, menu, corpus.section, corpus.id),
				false
			);
		const wrong = structuredClone(menu);
		for (const rows of Object.values(wrong))
			if (Array.isArray(rows))
				for (const row of rows)
					if (row.type === 'include' && row.section === corpus.section && row.row_id === corpus.id)
						row.row_id = 'missing';
		assert.equal(
			consumesProfileFrameCommand(source, file, wrong, corpus.section, corpus.id),
			false
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

// Per-key clearing keeps the established caption and native owner on each platform.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const corpus = JSON.parse(
		readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus/_shared/tests/corpus/menus/tap_hold_key_native.json'),
			'utf8'
		)
	);
	assert.equal(
		corpus.variants.length,
		2,
		'both established platform caption variants remain independent'
	);
	assert.deepEqual(
		manifest[corpus.section],
		corpus.variants.map((variant) => ({
			type: 'command',
			id: variant.id,
			i18n: variant.label_key,
			disabled_when: ['tap_hold_key_configured'],
			platforms: variant.platforms,
			unavailable: 'hide'
		})),
		'the shared declaration owns each platform caption and per-key availability'
	);
	const head = JSON.parse(
		readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus/_shared/tests/corpus/menus/tap_hold_key_head.json'),
			'utf8'
		)
	);
	assert.deepEqual(manifest[head.section], head.rows, 'independent full child-template order');
	function assertWiring(source, consumer, nativeId, tapId, holdId, section, target) {
		assert(
			source.includes(consumer + '("tap_hold_key_rows"'),
			'actual provider consumes the declared complete template'
		);
		assert.deepEqual(
			target.tap_hold_key_rows,
			[
				{ type: 'include', section },
				{ type: 'include', section: 'tap_hold_key_delay_tail' }
			],
			'complete root includes unchanged head before the delay tail'
		);
		assert.equal(target[section][0].type, 'include', 'head begins with a real declared include');
		assert.equal(
			target[section][0].section,
			corpus.section,
			'head includes the original clearing declaration'
		);
		for (const binding of [
			nativeId,
			tapId,
			holdId,
			'tap_hold_key_configured',
			'tap_hold_key_tap_caption',
			'tap_hold_key_hold_caption'
		]) {
			const declaration =
				consumer === 'MenuRenderer_TemplateRows'
					? new RegExp('"' + binding + '"\\s*,\\s*(?:_TH_Make|_HoldRowsBuilder|\\(\\(Value\\))')
					: new RegExp(
							'\\["' + binding + '"\\]\\s*=\\s*(?:function|hold_rows|build_action_picker)'
						);
			assert(declaration.test(source), 'actual provider supplies literal binding: ' + binding);
		}
	}
	for (const [path, consumer, nativeId, tapId, holdId, start, end] of [
		[
			'windows/ui/menu/menu_taphold.ahk',
			'MenuRenderer_TemplateRows',
			'tap_hold_key_native',
			'tap_hold_key_tap',
			'tap_hold_key_hold',
			'_TH_KeyRows(Hand) {',
			'; Return the "none" hold option'
		],
		[
			'macos/ui/menu/menu_tap_holds.lua',
			'ManifestMenu.template_rows',
			'tap_hold_key_no_action',
			'tap_hold_key_tap_picker',
			'tap_hold_key_hold_picker',
			'local function build_one_tap_hold_item(',
			'--- Builds the tap / hold rows of one hand'
		],
		[
			'linux/ui/menu/menu_builder.lua',
			'ManifestMenu.template_rows',
			'tap_hold_key_native',
			'tap_hold_key_tap',
			'tap_hold_key_hold',
			'local function hand_rows(hand)',
			'local providers = {'
		]
	]) {
		const file = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', path), 'utf8');
		const begin = file.indexOf(start);
		const finish = file.indexOf(end, begin);
		assert(begin >= 0 && finish > begin, path + ': real provider body must exist');
		const source = file.slice(begin, finish);
		assertWiring(source, consumer, nativeId, tapId, holdId, head.section, manifest);
		assert.throws(
			() =>
				assertWiring(
					source.replaceAll(consumer, 'WrongProvider'),
					consumer,
					nativeId,
					tapId,
					holdId,
					head.section,
					manifest
				),
			/actual provider/
		);
		assert.throws(
			() =>
				assertWiring(
					source.replace('"tap_hold_key_rows"', '"wrong_template"'),
					consumer,
					nativeId,
					tapId,
					holdId,
					head.section,
					manifest
				),
			/actual provider/
		);
		for (const mutate of [
			(target) => {
				target.tap_hold_key_rows[0].section = 'wrong_head';
			},
			(target) => {
				target.tap_hold_key_rows.reverse();
			}
		]) {
			const wrongRoot = structuredClone(manifest);
			mutate(wrongRoot);
			assert.throws(
				() => assertWiring(source, consumer, nativeId, tapId, holdId, head.section, wrongRoot),
				/complete root/
			);
		}
		const broken = structuredClone(manifest);
		broken[head.section][0].section = 'wrong_head';
		assert.throws(
			() => assertWiring(source, consumer, nativeId, tapId, holdId, head.section, broken),
			/original clearing/
		);
		for (const binding of [
			nativeId,
			tapId,
			holdId,
			'tap_hold_key_configured',
			'tap_hold_key_tap_caption',
			'tap_hold_key_hold_caption'
		])
			assert.throws(
				() =>
					assertWiring(
						source.replaceAll('"' + binding + '"', '"wrong_binding"'),
						consumer,
						nativeId,
						tapId,
						holdId,
						head.section,
						manifest
					),
				/literal binding/
			);
	}
	const locales = JSON.parse(
		readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus/_shared/data/locale_order.json'), 'utf8')
	).order;
	assert.equal(locales.length, 21);
	for (const code of locales) {
		const strings = JSON.parse(
			readFileSync(
				resolve(REPO_ROOT, 'static/ergopti_plus/_shared/data/locales/' + code + '.json'),
				'utf8'
			)
		);
		for (const row of head.rows.filter((row) => row.caption_getter)) {
			assert.equal(typeof strings[row.i18n], 'string', code + ': ' + row.i18n);
			assert.equal(
				(strings[row.i18n].match(/%s/g) || []).length,
				1,
				code + ': one current-action placeholder'
			);
		}
	}
	console.log('Tap-Hold key clearing: declared platform captions and unchanged native owners.');
}

{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const corpus = JSON.parse(
		readFileSync(
			resolve(
				REPO_ROOT,
				'static/ergopti_plus/_shared/tests/corpus/metrics/migration_status_menu.json'
			),
			'utf8'
		)
	);
	assert.equal(corpus.statuses.length, 2, 'exactly the two existing fixed migration statuses');
	for (const status of corpus.statuses)
		assert.deepEqual(
			manifest[status.section],
			[status.row],
			'handwritten inert-status declaration'
		);
	const source = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/linux/ui/menu/menu_builder.lua'),
		'utf8'
	);
	const begin = source.indexOf('local function _migration_row(k)');
	const end = source.indexOf('--- Renders the rows of the metrics submenu', begin);
	assert(begin >= 0 && end > begin, 'actual native migration provider must exist');
	const body = source.slice(begin, end);
	function assertStatusWiring(text, statuses) {
		for (const status of statuses)
			assert(
				text.includes('ManifestMenu.template_rows("' + status.section + '")'),
				'actual native provider must consume each shared inert-status declaration'
			);
		assert.match(text, /if type\(k\.get_migration_progress\) ~= "function" then/);
		assert.match(text, /if not progress\.running then/);
		assert.match(
			text,
			/label = string\.format\(i18n_safe\("menu\.metrics\.migration_progress"\),\s*progress\.scanned, progress\.total\)/
		);
		assert.match(
			text,
			/if type\(k\.cancel_migration\) == "function" then k\.cancel_migration\(\) end/
		);
	}
	assertStatusWiring(body, corpus.statuses);
	assert.throws(
		() =>
			assertStatusWiring(
				body.replaceAll('ManifestMenu.template_rows', 'WrongProvider'),
				corpus.statuses
			),
		/consume each shared/
	);
	for (const status of corpus.statuses)
		assert.throws(
			() =>
				assertStatusWiring(
					body.replace('"' + status.section + '"', '"wrong_status"'),
					corpus.statuses
				),
			/consume each shared/
		);
	const locales = JSON.parse(
		readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus/_shared/data/locale_order.json'), 'utf8')
	).order;
	assert.equal(locales.length, 21);
	for (const code of locales) {
		const strings = JSON.parse(
			readFileSync(
				resolve(REPO_ROOT, 'static/ergopti_plus/_shared/data/locales/' + code + '.json'),
				'utf8'
			)
		);
		for (const status of corpus.statuses) {
			assert.equal(typeof strings[status.row.i18n], 'string', code + ': existing inert caption');
			assert.notEqual(strings[status.row.i18n], '');
			if (status.locales[code]) assert.equal(strings[status.row.i18n], status.locales[code]);
		}
		if (corpus.running.locales[code])
			assert.equal(
				strings['menu.metrics.migration_progress']
					.replace('%d', corpus.running.scanned)
					.replace('%d', corpus.running.total),
				corpus.running.locales[code]
			);
	}
	console.log(
		'Metrics migration labels: independent inert declarations, 21 translations and actual state-provider wiring.'
	);
}

// Independent Mac swipe modes: presentation is shared, native mutation remains
// the current per-slot owner. Never substitute source presence for actual edge wiring.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/gesture_slot_modes.json'), 'utf8')
	);
	const generated = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const declared = parseToml(readFileSync(MANIFEST_PATH, 'utf8')).menu;
	const expected = corpus.rows.map(({ value, ...row }) => row);
	assert.deepEqual(
		corpus.rows.map((row) => row.value),
		['x1', 'incremental']
	);
	assert.deepEqual(declared[corpus.section], expected);
	assert.deepEqual(generated[corpus.section], expected);
	assert.deepEqual(corpus.platform_rows, {
		ahk: [],
		hs: ['gesture_mode_single', 'gesture_mode_incremental'],
		linux: []
	});
	assert.deepEqual(corpus.states, [
		{ mode: 'x1', checked: [true, false] },
		{ mode: 'incremental', checked: [false, true] },
		{ mode: 'future_mode', checked: [false, false] }
	]);
	const sourcePath = resolve(REPO_ROOT, 'static/ergopti_plus/macos/ui/menu/menu_gestures.lua');
	const source = readFileSync(sourcePath, 'utf8');
	const graph = readFileSync(resolve(__dirname, 'test-menu-parity.cjs'), 'utf8');
	function modeGraph(source) {
		const start = source.indexOf('const OPENS_SUBMENU = {');
		const end = source.indexOf('\n};', start);
		assert(start >= 0 && end > start, 'actual graph registry is bounded');
		return require('node:vm').runInNewContext(
			source.slice(start, end + 3) + '; OPENS_SUBMENU',
			{},
			{ timeout: 1000 }
		);
	}
	function assertModeWiring(owner, edges) {
		const registry = modeGraph(edges);
		assert.match(
			owner,
			/if slot:match\("swipe"\) then\s+modeSubmenu = ManifestMenu\.template_rows\("gesture_slot_mode_commands"/,
			'actual swipe template'
		);
		for (const [id, value] of [
			['gesture_mode_single', 'x1'],
			['gesture_mode_incremental', 'incremental']
		]) {
			assert.ok(owner.includes('["' + id + '"] = function()'), 'literal mode owner');
			assert.ok(
				owner.includes(
					'commit_gesture_row_value("get_mode", "set_mode", slot, "' + value + '", "mode")'
				),
				'actual mutation owner'
			);
		}
		for (const [id, value] of [
			['gesture_mode_is_single', 'x1'],
			['gesture_mode_is_incremental', 'incremental']
		])
			assert.ok(
				owner.includes('["' + id + '"] = function() return currentMode == "' + value + '" end'),
				'literal checked getter'
			);
		const tokens = require('../lib/script-source.cjs').scriptTokens(owner, '.lua');
		assert.ok(
			tokens.some((_, i) =>
				['[', 'gesture_mode_options', ']', '=', 'modeSubmenu'].every(
					(v, n) => tokens[i + n]?.value === v
				)
			),
			'actual rendered child'
		);
		for (const finger of [2, 3, 4, 5]) {
			assert.ok(
				owner.includes('["gesture_slots_' + finger + '"] = slots_provider(' + finger + ')'),
				'actual slot provider'
			);
			const entries = registry['gesture_slots_' + finger];
			const declared = Array.isArray(entries) ? entries : [entries];
			assert.ok(
				declared.some(
					(entry) =>
						entry &&
						(typeof entry === 'string'
							? entry === 'gesture_slot_mode_commands'
							: entry.menu === 'gesture_slot_mode_commands' &&
								entry.kind !== 'compose' &&
								(!entry.platforms || entry.platforms.includes('hs')))
				),
				'actual provider edge'
			);
		}
	}
	assertModeWiring(source, graph);
	for (const name of [
		corpus.section,
		'gesture_mode_single',
		'gesture_mode_incremental',
		'gesture_mode_is_single',
		'gesture_mode_is_incremental',
		'gesture_slots_2'
	])
		assert.throws(() =>
			assertModeWiring(source.replaceAll('"' + name + '"', '"wrong_binding"'), graph)
		);
	assert.throws(() =>
		assertModeWiring(
			source.replace('["gesture_mode_options"] = modeSubmenu', '["gesture_mode_options"] = {}'),
			graph
		)
	);
	for (const finger of [2, 3, 4, 5])
		assert.throws(() =>
			assertModeWiring(source, graph.replace('gesture_slots_' + finger + ':', 'wrong_edge:'))
		);
	assert.throws(
		() =>
			assertModeWiring(
				source,
				graph.replaceAll(
					"menu: 'gesture_slot_mode_commands', platforms: ['hs']",
					"menu: 'gesture_slot_mode_commands', platforms: ['ahk']"
				)
			),
		/actual provider edge/
	);
	assert.throws(
		() =>
			assertModeWiring(
				source,
				graph.replaceAll(
					"menu: 'gesture_slot_mode_commands', platforms: ['hs']",
					"menu: 'gesture_slot_mode_commands', platforms: ['hs'], kind: 'compose'"
				)
			),
		/actual provider edge/
	);
	const locales = JSON.parse(readFileSync(resolve(SHARED, 'data/locale_order.json'), 'utf8')).order;
	assert.deepEqual(Object.keys(corpus.captions).sort(), [...locales].sort());
	for (const code of locales) {
		const strings = JSON.parse(readFileSync(resolve(LOCALES_DIR, code + '.json'), 'utf8'));
		assert.deepEqual(
			expected.map((row) => strings[row.i18n]),
			corpus.captions[code]
		);
	}
	for (const relative of ['_shared/lua/menu/renderer.lua', 'windows/infra/manifest_menu.ahk']) {
		const renderer = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', relative), 'utf8');
		assert.match(
			renderer,
			relative.endsWith('.lua')
				? /elseif item\.type == "check" then\s+row = R\.check_row\(key, item\.id, commands, getters\)/
				: /else if ItemType == "check" \{\s+Row := MenuRenderer_CheckRow\(ManifestKey, Id, Commands, StateGetters\)/
		);
	}
	console.log(
		'Gesture modes: independent shared order/captions/platforms and actual native owner wiring.'
	);
}

// Complete per-key delay metadata: independent declarations and actual owners.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/tap_hold_key_delay.json'), 'utf8')
	);
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(manifest[corpus.complete_section], corpus.complete);
	assert.deepEqual(manifest[corpus.tail_section], corpus.tail);
	assert.deepEqual(manifest[corpus.children_section], corpus.children);
	const locales = JSON.parse(readFileSync(resolve(SHARED, 'data/locale_order.json'), 'utf8')).order;
	assert.equal(locales.length, 21);
	for (const code of locales) {
		const strings = JSON.parse(readFileSync(resolve(LOCALES_DIR, code + '.json'), 'utf8'));
		for (const row of [...corpus.tail, ...corpus.children]) {
			if (!row.i18n) continue;
			assert.equal(typeof strings[row.i18n], 'string', code + ': ' + row.i18n);
			assert.notEqual(strings[row.i18n], row.i18n, 'caption resolves to a translation');
			if (row.caption_getter)
				assert.equal(
					(strings[row.i18n].match(/%s/g) || []).length,
					1,
					'one native value placeholder'
				);
		}
	}
	for (const [file, start, end, required] of [
		[
			'macos/ui/menu/menu_tap_holds.lua',
			'local function build_one_tap_hold_item(',
			'--- Builds the tap / hold rows of one hand',
			[
				'tap_hold_key_delay_set',
				'tap_hold_key_delay_use_global',
				'tap_hold_key_delay',
				'tap_hold_key_delay_is_global',
				'tap_hold_key_delay_has_override',
				'tap_hold_key_delay_caption',
				'tap_hold_key_global_delay_caption'
			]
		],
		[
			'linux/ui/menu/menu_builder.lua',
			'local function hand_rows(hand)',
			'local providers = {',
			['tap_hold_key_delay_set', 'tap_hold_key_delay', 'tap_hold_key_delay_caption']
		]
	]) {
		const text = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', file), 'utf8');
		const begin = text.indexOf(start),
			finish = text.indexOf(end, begin);
		assert(begin >= 0 && finish > begin);
		const source = text.slice(begin, finish);
		function wiring(candidate) {
			assert(
				candidate.includes('ManifestMenu.template_rows("tap_hold_key_rows"'),
				'actual complete provider'
			);
			assert(
				candidate.includes('ManifestMenu.template_rows("tap_hold_key_delay_rows"'),
				'actual declared delay children'
			);
			for (const id of required)
				assert(
					new RegExp('\\["' + id + '"\\]\\s*=\\s*(?:function|delay_rows)').test(candidate),
					'actual delay binding: ' + id
				);
		}
		wiring(source);
		for (const id of ['tap_hold_key_rows', 'tap_hold_key_delay_rows', ...required])
			assert.throws(() => wiring(source.replaceAll('"' + id + '"', '"missing_owner"')), /actual/);
		for (const key of [
			'menu.tapholds.key_tap_delay',
			'menu.tapholds.key_tap_delay_set',
			'menu.tapholds.key_tap_delay_use_global'
		])
			assert(!source.includes('"' + key + '"'), 'native providers retire caption metadata: ' + key);
	}
	const windows = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/windows/ui/menu/menu_taphold.ahk'),
		'utf8'
	);
	assert(windows.includes('MenuRenderer_TemplateRows("tap_hold_key_rows"'));
	for (const binding of [
		'tap_hold_key_delay_rows',
		'tap_hold_key_delay_set',
		'tap_hold_key_delay',
		'tap_hold_key_delay_caption'
	])
		assert(
			windows.includes('"' + binding + '"'),
			'Windows binds a genuine per-key timing owner: ' + binding
		);
	assert(
		windows.includes('_TH_MakeDelayPickerFn(KeyId)'),
		'Windows captures the physical key for its real prompt'
	);
	assert(
		windows.includes('WriteTapHoldDuration(KeyId, Ms / 1000, 0, 0, 0, 0, SourceWitness)'),
		'Windows persists through the existing native transaction owner'
	);
	console.log(
		'Tap-Hold per-key delay: independent platform/state metadata, existing keys resolved in 21 locales and actual native owners.'
	);
}

// Independent fixed wrap controls must reach the actual native providers.
{
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/wrap_symbol_controls.json'), 'utf8')
	);
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	for (const section of corpus.sections) {
		const expected = section.rows.map((row) => {
			const declared = { type: row.separator ? '---' : 'command' };
			if (row.id) Object.assign(declared, { id: row.id, i18n: row.i18n });
			if (row.disabled_when) declared.disabled_when = row.disabled_when;
			return { ...declared, platforms: corpus.platforms, unavailable: 'hide' };
		});
		assert.deepEqual(
			menu[section.section],
			expected,
			'handwritten complete fixed control section: ' + section.section
		);
	}
	const catalogue = JSON.parse(
		readFileSync(resolve(SHARED, 'modules/wrap_symbols/wrap_symbols.json'), 'utf8')
	);
	assert.deepEqual(
		catalogue.groups.map((group) => ({
			i18n: group.i18n,
			lefts: group.pairs.map((pair) => pair.left)
		})),
		corpus.catalogue_groups
	);
	const localeOrder = JSON.parse(
		readFileSync(resolve(SHARED, 'data/locale_order.json'), 'utf8')
	).order;
	assert.deepEqual(
		[...localeOrder].sort(),
		[...corpus.locales].sort(),
		'all 21 published locale identities'
	);
	for (const locale of corpus.locales) {
		const strings = JSON.parse(
			readFileSync(resolve(LOCALES_DIR, locale + '.json'), 'utf8').replace(/^\uFEFF/, '')
		);
		for (const section of corpus.sections)
			for (const row of section.rows)
				if (row.i18n) {
					assert.equal(typeof strings[row.i18n], 'string', locale + ': fixed wrap caption');
					assert.notEqual(strings[row.i18n], '');
					assert.notEqual(strings[row.i18n], row.i18n);
				}
	}
	const sources = {
		windows: readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus/windows/ui/menu/menu_shortcuts.ahk'),
			'utf8'
		),
		macos: readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus/macos/ui/menu/menu_shortcuts.lua'),
			'utf8'
		)
	};
	const helper = readFileSync(resolve(SHARED, 'lua/menu/wrap_mutation.lua'), 'utf8');
	function tokens(source, extension = '.lua') {
		return scriptTokens(source, extension).map((token) => token.kind + ':' + token.value);
	}
	function hasCode(source, snippet, extension = '.lua') {
		const code = tokens(source, extension),
			required = tokens(snippet, extension);
		return code.some((_, at) => required.every((token, offset) => code[at + offset] === token));
	}
	function assertWrapMutation(candidate) {
		for (const [snippet, purpose] of [
			[
				'local FIELDS = { "wrap_symbol_states", "custom_wrap_symbols" }',
				'exact two-field ownership'
			],
			['function M.commit(state, mutate, save)', 'actual shared mutation owner'],
			['if claims[state] then return false,', 'same-state reentrancy refusal'],
			['claims[state] = { view = clone(prior) }', 'acknowledged pending input view'],
			['local called, changed = pcall(mutate, candidate)', 'detached candidate transformation'],
			['if not called or changed ~= true then', 'exact transform acknowledgement'],
			['if rawget(state, field) ~= prior[field] then', 'construction successor refusal'],
			['local saved, acknowledged = pcall(save)', 'existing native save authority'],
			['if not saved or acknowledged ~= true then', 'native exact save receipt remains'],
			[
				'if rawget(state, field) == candidate[field] then rawset(state, field, prior[field]) end',
				'conditional owned inverse'
			],
			[
				'if rawget(state, field) ~= candidate[field] then owned = false end',
				'publication successor refusal'
			],
			['function M.view(state)', 'actual input view owner'],
			['return claim and claim.view or state', 'input retains acknowledged state'],
			['function M.pending(state)', 'actual readiness owner'],
			['return claims[state] ~= nil', 'pending claim predicate']
		])
			assert.ok(hasCode(candidate, snippet), purpose);
	}
	function assertWrapProvider(source, platform, mutationSource = helper) {
		const begin =
			platform === 'windows'
				? source.indexOf('_WS_BuildSymbolRows() {')
				: source.indexOf('local function build_wrap_symbols_submenu(');
		const end =
			platform === 'windows'
				? source.indexOf('; Native callbacks capture payloads with Bind', begin)
				: source.indexOf('\n\treturn sub\nend', begin);
		assert.ok(begin >= 0 && end > begin, 'actual wrap provider body is bounded');
		const body = source.slice(begin, end);
		const api = platform === 'windows' ? 'MenuRenderer_TemplateRows' : 'ManifestMenu.template_rows';
		for (const section of corpus.sections)
			assert.ok(
				body.includes(api + '("' + section.section + '"'),
				'actual provider consumes each shared section: ' + section.section
			);
		for (const section of corpus.sections)
			assert.ok(
				hasCode(body, api + '("' + section.section + '"', platform === 'windows' ? '.ahk' : '.lua'),
				'live provider consumes each shared section: ' + section.section
			);
		for (const section of corpus.sections)
			for (const row of section.rows)
				if (row.id) {
					const binding = platform === 'windows' ? '"' + row.id + '",' : '["' + row.id + '"] =';
					assert.ok(body.includes(binding), 'literal native command binding: ' + row.id);
				}
		if (platform === 'windows') {
			assert.ok(
				body.includes('Map("wrap_symbols_ready", (*) => true)'),
				'existing native eligibility reader'
			);
			assert.ok(
				body.includes('_WS_ControlSetGroup.Bind(GroupLefts, true)'),
				'bound group enable payload'
			);
			assert.ok(
				body.includes('_WS_ControlSetGroup.Bind(GroupLefts, false)'),
				'bound group disable payload'
			);
			assert.ok(body.includes('_WS_ControlRemoveCustom.Bind(Idx)'), 'bound custom index payload');
		} else {
			assert.ok(
				hasCode(
					body,
					'wrap_symbols_ready = function() return not paused and not WrapMutation.pending(state) end'
				),
				'existing native pause eligibility'
			);
			assert.ok(
				body.includes('items = del_sub'),
				'actual canonical custom child reaches the shared renderer'
			);
			assert.ok(
				hasCode(
					body,
					'local committed, reason = WrapMutation.commit(state, mutate, ctx.save_prefs)'
				),
				'native exact save receipt remains'
			);
			assert.ok(
				hasCode(source, 'local WrapMutation = require("menu.wrap_mutation")'),
				'actual shared mutation dependency'
			);
			assert.ok(
				hasCode(body, 'if committed ~= true then'),
				'native callback refuses failed shared publication'
			);
			assert.ok(
				hasCode(body, 'local view = WrapMutation.view(state)'),
				'live native getter uses acknowledged input'
			);
			const call = tokens('return mutate_wrap(function(candidate)');
			const code = tokens(body);
			const count = code.filter((_, at) =>
				call.every((value, offset) => code[at + offset] === value)
			).length;
			assert.equal(count, 8, 'all eight actual Wrap callback sites retain detached mutation');
			assertWrapMutation(mutationSource);
		}
	}
	for (const [platform, source] of Object.entries(sources)) {
		assertWrapProvider(source, platform);
		assert.throws(
			() =>
				assertWrapProvider(
					source.replace('"wrap_symbols_global_controls"', '"wrap_symbols_add_controls"'),
					platform
				),
			/consumes each shared section/
		);
		assert.throws(
			() =>
				assertWrapProvider(
					source.replace('"wrap_symbols_enable_group"', '"unowned_wrap_group"'),
					platform
				),
			/literal native command binding/
		);
	}
	assert.throws(
		() =>
			assertWrapProvider(
				sources.windows.replace(
					'_WS_ControlSetGroup.Bind(GroupLefts, true)',
					'_WS_ControlRemoveCustom.Bind(GroupLefts, true)'
				),
				'windows'
			),
		/bound group enable payload/
	);
	assert.throws(
		() => assertWrapProvider(sources.macos.replace('items = del_sub', 'menu = del_sub'), 'macos'),
		/canonical custom child/
	);
	for (const [before, after, reason] of [
		[
			'WrapMutation.commit(state, mutate, ctx.save_prefs)',
			'OtherOwner.commit(state, mutate, ctx.save_prefs)',
			/native exact save/
		],
		['WrapMutation.pending(state)', 'OtherOwner.pending(state)', /pause eligibility/],
		['WrapMutation.view(state)', 'OtherOwner.view(state)', /acknowledged input/],
		[
			'return mutate_wrap(function(candidate)',
			'return other_mutation(function(candidate)',
			/eight actual Wrap/
		]
	])
		assert.throws(() => assertWrapProvider(sources.macos.replace(before, after), 'macos'), reason);
	for (const [before, after, reason] of [
		['acknowledged ~= true', 'not acknowledged', /native exact save/],
		[
			'rawset(state, field, prior[field])',
			'rawset(state, field, candidate[field])',
			/owned inverse/
		],
		['if claims[state] then return false,', 'if false then return false,', /reentrancy refusal/],
		['return claim and claim.view or state', 'return state', /acknowledged state/]
	]) {
		const malformed = helper.replace(before, after);
		assert.notEqual(malformed, helper, 'real helper mutation was applied');
		assert.throws(() => assertWrapMutation(malformed), reason);
		assert.throws(
			() => assertWrapMutation(malformed + '\n-- ' + before + '\nlocal fake = [[' + before + ']]'),
			reason,
			'comment or quoted source cannot manufacture a live shared owner'
		);
	}
	console.log(
		'Wrap controls: independent complete sections, 21 existing translations, actual provider graph and native payload bindings.'
	);
}

// Append to tools/test/test-menu-manifest.cjs after actual root publication.
// This complementary guard credits real tokens; native owner cases remain the oracle.
{
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/gesture_slot_controls.json'), 'utf8')
	);
	const generated = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const declared = parseToml(readFileSync(MANIFEST_PATH, 'utf8')).menu;
	for (const [section, rows] of Object.entries(corpus.sections)) {
		assert.deepEqual(declared[section], rows, 'handwritten controls source: ' + section);
		assert.deepEqual(generated[section], rows, 'actual generated controls: ' + section);
	}
	assert.deepEqual(
		corpus.sensitivity_values,
		[1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 6, 7, 8, 10, 12, 15, 20, 25, 30]
	);
	const locales = JSON.parse(readFileSync(resolve(SHARED, 'data/locale_order.json'), 'utf8')).order;
	assert.equal(locales.length, 21);
	assert.deepEqual(Object.keys(corpus.caption_snapshots).sort(), [...locales].sort());
	for (const code of locales) {
		const actual = JSON.parse(readFileSync(resolve(LOCALES_DIR, code + '.json'), 'utf8'));
		for (const [key, expected] of Object.entries(corpus.caption_snapshots[code]))
			assert.equal(actual[key], expected, code + ': unchanged existing caption ' + key);
	}
	const owner = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/macos/ui/menu/menu_gestures.lua'),
		'utf8'
	);
	function hasTemplate(tokens, section) {
		return tokens.some(
			(token, i) =>
				token.kind === 'identifier' &&
				token.value === 'ManifestMenu' &&
				tokens[i + 1]?.value === '.' &&
				tokens[i + 2]?.value === 'template_rows' &&
				tokens[i + 3]?.value === '(' &&
				tokens[i + 4]?.kind === 'string' &&
				tokens[i + 4]?.value === section &&
				[',', ')'].includes(tokens[i + 5]?.value)
		);
	}
	function hasBinding(tokens, id) {
		return tokens.some(
			(token, i) =>
				token.value === '[' &&
				tokens[i + 1]?.kind === 'string' &&
				tokens[i + 1]?.value === id &&
				tokens[i + 2]?.value === ']' &&
				tokens[i + 3]?.value === '=' &&
				tokens[i + 4]?.kind === 'identifier' &&
				tokens[i + 4]?.value === 'function'
		);
	}
	function assertControlWiring(candidate) {
		const tokens = scriptTokens(candidate, '.lua');
		for (const section of ['gesture_sensitivity_head', 'gesture_change_action'])
			assert.ok(hasTemplate(tokens, section), 'actual controls template call: ' + section);
		for (const id of ['gesture_slot_change_action', 'gesture_slot_choice_ready'])
			assert.ok(hasBinding(tokens, id), 'actual native controls binding: ' + id);
		assert.match(candidate, /table\.insert\(sensSubmenu,/, 'native numeric payload retained');
		assert.ok(
			tokens.some((_, i) =>
				['[', 'gesture_sensitivity_options', ']', '=', 'sensSubmenu'].every(
					(v, n) => tokens[i + n]?.value === v
				)
			),
			'actual rendered sensitivity child'
		);
		assert.ok(hasTemplate(tokens, 'gesture_swipe_slot_menu'), 'actual swipe command payload');
		assert.match(candidate, /items\s*=\s*swipeSubmenu/, 'actual full swipe materialization');
		assert.match(candidate, /items\s*=\s*change_action_rows/, 'actual tap command payload');
		for (const finger of [2, 3, 4, 5])
			assert.ok(
				candidate.includes('["gesture_slots_' + finger + '"] = slots_provider(' + finger + ')'),
				'real native slot provider: ' + finger
			);
	}
	assertControlWiring(owner);
	for (const name of [
		'gesture_sensitivity_head',
		'gesture_change_action',
		'gesture_slot_change_action',
		'gesture_slot_choice_ready',
		'gesture_slots_2'
	])
		assert.throws(() => assertControlWiring(owner.replaceAll('"' + name + '"', '"wrong_owner"')));
	for (const section of ['gesture_sensitivity_head', 'gesture_change_action']) {
		const renamed = owner.replaceAll('"' + section + '"', '"wrong_template"');
		assert.throws(() =>
			assertControlWiring(renamed + '\n-- ManifestMenu.template_rows("' + section + '")')
		);
		assert.throws(() =>
			assertControlWiring(
				renamed + '\nlocal decorative = [[ManifestMenu.template_rows("' + section + '")]]'
			)
		);
	}
	assert.throws(() =>
		assertControlWiring(
			owner.replace(
				'["gesture_sensitivity_options"] = sensSubmenu',
				'["gesture_sensitivity_options"] = {}'
			)
		)
	);
	assert.throws(() =>
		assertControlWiring(owner.replace('items    = change_action_rows', 'items    = {}'))
	);
	console.log(
		'Gesture controls: independently declared heading/choice, 21 existing captions and actual tokenized native owners.'
	);
}

// Mac-only fixed Tap-Hold guidance delegates native status/actions unchanged.
{
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/tap_hold_guidance.json'), 'utf8')
	);
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	for (const [section, expected] of Object.entries(corpus.declarations))
		assert.deepEqual(manifest[section], expected, 'handwritten guidance descriptor: ' + section);
	const source = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/macos/ui/menu/menu_tap_holds.lua'),
		'utf8'
	);
	function tokens(text) {
		return scriptTokens(text, '.lua').map((token) => token.kind + ':' + token.value);
	}
	function contains(haystack, needle) {
		return haystack.some((_, index) =>
			needle.every((value, offset) => haystack[index + offset] === value)
		);
	}
	function wiring(candidate) {
		const code = tokens(candidate);
		for (const section of Object.keys(corpus.declarations))
			assert(
				contains(code, [
					'identifier:ManifestMenu',
					'symbol:.',
					'identifier:template_rows',
					'symbol:(',
					'string:' + section,
					'symbol:,'
				]),
				'actual guidance template call: ' + section
			);
		for (const [id, owner] of [
			['tap_hold_login_items_steps', 'login_items_steps_command'],
			['tap_hold_login_items_open', 'function'],
			['tap_hold_legacy_rules_cleanup', 'function']
		])
			assert(
				contains(code, ['symbol:[', 'string:' + id, 'symbol:]', 'symbol:=', 'identifier:' + owner]),
				'actual guidance native binding: ' + id
			);
	}
	wiring(source);
	for (const section of Object.keys(corpus.declarations)) {
		const call = 'ManifestMenu.template_rows("' + section + '",';
		for (const replacement of [
			'WrongOwner.template_rows("' + section + '",',
			'ManifestMenu.template_rows("unowned_guidance",'
		])
			assert.throws(() => wiring(source.replace(call, replacement)), /actual guidance template/);
		const missing = source.replace(call, 'WrongOwner.template_rows("' + section + '",');
		assert.throws(
			() => wiring(missing + '\n-- ' + call + '\nlocal fake = [[' + call + ']]'),
			/actual guidance template/,
			'comment/quoted code cannot fake consumption'
		);
	}
	for (const id of [
		'tap_hold_login_items_steps',
		'tap_hold_login_items_open',
		'tap_hold_legacy_rules_cleanup'
	])
		assert.throws(
			() => wiring(source.replaceAll('"' + id + '"', '"unowned_guidance"')),
			/actual guidance native binding/
		);
	for (const [section, rows] of Object.entries(corpus.declarations))
		for (const row of rows)
			assert(
				!source.includes('"' + row.i18n + '"'),
				'fixed native caption retired: ' + section + '/' + row.id
			);
	const locales = JSON.parse(readFileSync(resolve(SHARED, 'data/locale_order.json'), 'utf8')).order;
	assert.equal(locales.length, 21);
	for (const code of locales) {
		const strings = JSON.parse(readFileSync(resolve(LOCALES_DIR, code + '.json'), 'utf8'));
		for (const rows of Object.values(corpus.declarations))
			for (const row of rows) {
				assert.equal(typeof strings[row.i18n], 'string');
				assert(
					strings[row.i18n].trim().length > 0 && strings[row.i18n] !== row.i18n,
					code + ': translated caption'
				);
			}
	}
	console.log(
		'Tap-Hold guidance: exact independent declarations, 21 existing translations and genuine native template/callback bindings.'
	);
}

// The Apps provider consumes one inert shared caption; dynamic bundles stay native.
{
	const assertAppsEmpty = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const appsEmptyCorpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menu/apps_empty_caption.json'), 'utf8')
	);
	const appsEmptyManifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assertAppsEmpty.deepEqual(appsEmptyManifest[appsEmptyCorpus.section], [appsEmptyCorpus.row]);
	assertAppsEmpty.deepEqual(appsEmptyCorpus.row, {
		type: 'label',
		id: 'apps_empty',
		i18n: 'menu.apps.no_apps',
		platforms: ['hs'],
		unavailable: 'hide'
	});
	assertAppsEmpty.equal(Object.keys(appsEmptyCorpus.captions).length, 21);
	for (const [locale, expected] of Object.entries(appsEmptyCorpus.captions)) {
		const catalogue = JSON.parse(readFileSync(resolve(LOCALES_DIR, locale + '.json'), 'utf8'));
		assertAppsEmpty.equal(
			catalogue['menu.apps.no_apps'],
			expected,
			locale + ' independent Apps caption'
		);
	}
	const appsEmptyNative = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/macos/ui/menu/menu_apps.lua'),
		'utf8'
	);
	function appsEmptyOwns(source) {
		const tokens = scriptTokens(source, '.lua').map((token) => ({
			kind: token.kind,
			value: token.value
		}));
		const has = (fragment) => {
			const expected = scriptTokens(fragment, '.lua').map((token) => ({
				kind: token.kind,
				value: token.value
			}));
			return tokens.some((_, index) =>
				expected.every(
					(token, offset) =>
						tokens[index + offset]?.kind === token.kind &&
						tokens[index + offset]?.value === token.value
				)
			);
		};
		return (
			has('local ManifestMenu = require("infra.manifest_menu")') &&
			has(
				'if #rows == 0 then rows = ManifestMenu.template_rows("apps_empty_rows") if not rows then return nil end end'
			) &&
			has(
				'ManifestMenu.build("apps_menu", "Apps", nil, nil, ctx, { ["apps_installed"] = function() return rows end, })'
			)
		);
	}
	assertAppsEmpty.ok(
		appsEmptyOwns(appsEmptyNative),
		'actual shared binding, empty template and provider edge'
	);
	const appsEmptyNeedle = 'ManifestMenu.template_rows("apps_empty_rows")';
	assertAppsEmpty.ok(appsEmptyNative.includes(appsEmptyNeedle), 'bounded causal mutation preimage');
	for (const mutation of [
		'ManifestMenu.template_rows("wrong_section")',
		'Foreign.template_rows("apps_empty_rows")',
		'{}'
	]) {
		assertAppsEmpty.equal(appsEmptyOwns(appsEmptyNative.replace(appsEmptyNeedle, mutation)), false);
	}
	const appsEmptyRemoved = appsEmptyNative.replace(appsEmptyNeedle, '{}');
	assertAppsEmpty.equal(
		appsEmptyOwns(appsEmptyRemoved + '\n-- ' + appsEmptyNeedle),
		false,
		'comment cannot satisfy ownership'
	);
	assertAppsEmpty.equal(
		appsEmptyOwns(appsEmptyRemoved + "\nlocal inert = '" + appsEmptyNeedle + "'"),
		false,
		'quoted source cannot satisfy ownership'
	);
}

// Append after root publishes the canonical record. Native owner tests remain
// the behavior oracle; these tokens refuse comments, strings and wrong bindings.
{
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/gesture_system_refresh.json'), 'utf8')
	);
	const generated = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const source = parseToml(readFileSync(MANIFEST_PATH, 'utf8')).menu;
	assert.deepEqual(source[corpus.section], corpus.rows, 'independent refresh source declaration');
	assert.deepEqual(generated[corpus.section], corpus.rows, 'actual generated refresh declaration');
	assert.deepEqual(corpus.platform_rows, {
		ahk: ['gesture_system_refresh'],
		hs: ['gesture_system_refresh'],
		linux: []
	});
	const locales = JSON.parse(readFileSync(resolve(SHARED, 'data/locale_order.json'), 'utf8')).order;
	assert.equal(locales.length, 21);
	assert.deepEqual(Object.keys(corpus.captions).sort(), [...locales].sort());
	for (const locale of locales) {
		const strings = JSON.parse(readFileSync(resolve(LOCALES_DIR, locale + '.json'), 'utf8'));
		assert.equal(
			strings['ui_apps.btn_refresh'],
			corpus.captions[locale],
			'unchanged existing refresh caption: ' + locale
		);
	}
	function hasSequence(tokens, sequence) {
		return tokens.some((_, index) =>
			sequence.every((value, offset) => tokens[index + offset]?.value === value)
		);
	}
	function assertRefreshWiring(owner, extension) {
		const tokens = scriptTokens(owner, extension);
		if (extension === '.lua') {
			assert.ok(
				hasSequence(tokens, ['ManifestMenu', '.', 'template_rows', '(', corpus.section, ',', '{'])
			);
			assert.ok(
				hasSequence(tokens, ['[', 'gesture_system_refresh', ']', '=', 'function', '(', ')'])
			);
			assert.ok(
				hasSequence(tokens, [
					'return',
					'gestures',
					'.',
					'refresh_system_gestures',
					'(',
					'ctx',
					'.',
					'updateMenu',
					')'
				])
			);
			assert.ok(
				hasSequence(tokens, ['for', '_', ',', 'row', 'in', 'ipairs', '(', 'controls', ')'])
			);
			assert.ok(hasSequence(tokens, ['items', '=', 'rows']));
		} else {
			assert.ok(
				hasSequence(tokens, [
					'MenuRenderer_TemplateRows',
					'(',
					corpus.section,
					',',
					'Map',
					'(',
					'gesture_system_refresh',
					',',
					'GestureSystemRequestRefresh',
					')'
				])
			);
			assert.ok(hasSequence(tokens, ['for', 'Row', 'in', 'Controls']));
			assert.ok(hasSequence(tokens, ['Children', '.', 'Push', '(', 'Row', ')']));
			assert.ok(hasSequence(tokens, ['SetTimer', '(', 'GestureSystemRefresh', ',', '-', '1', ')']));
		}
	}
	for (const [extension, nativePath] of [
		['.lua', 'macos/ui/menu/menu_gestures.lua'],
		['.ahk', 'windows/ui/gesture_conflicts.ahk']
	]) {
		const owner = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', nativePath), 'utf8');
		assertRefreshWiring(owner, extension);
		for (const id of [corpus.section, 'gesture_system_refresh'])
			assert.throws(() =>
				assertRefreshWiring(owner.replaceAll('"' + id + '"', '"unowned_refresh"'), extension)
			);
		const changed =
			extension === '.lua'
				? owner.replaceAll('gestures.refresh_system_gestures', 'gestures.unowned_refresh')
				: owner.replaceAll('GestureSystemRequestRefresh)', 'UnownedRefresh)');
		assert.throws(() => assertRefreshWiring(changed, extension));
		const comment = extension === '.lua' ? '-- ' : '; ';
		const erased = owner.replaceAll('"' + corpus.section + '"', '"unowned_refresh"');
		const call =
			extension === '.lua'
				? `ManifestMenu.template_rows("${corpus.section}", {})`
				: `MenuRenderer_TemplateRows("${corpus.section}", Map(), Map(), Map())`;
		assert.throws(() => assertRefreshWiring(erased + '\n' + comment + call, extension));
		assert.throws(() => assertRefreshWiring(erased + '\n' + JSON.stringify(call), extension));
	}
}

// Complementary exact records and actual consumer/import wiring after root publication.
// Replace only the older controls guard's obsolete ipairs(change_action_rows)
// swipe assertion with this stronger whole-template/import/payload contract;
// retain its original tap, numeric value, callback/getter and all locale assertions.
{
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/gesture_swipe_template.json'), 'utf8')
	);
	const generated = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const declared = parseToml(readFileSync(MANIFEST_PATH, 'utf8')).menu;
	assert.deepEqual(declared[corpus.section], corpus.rows, 'handwritten complete swipe source');
	assert.deepEqual(generated[corpus.section], corpus.rows, 'actual generated swipe template');
	assert.deepEqual(corpus.child_sections, {
		gesture_mode_options: 'gesture_slot_mode_commands',
		gesture_sensitivity_options: 'gesture_sensitivity_head'
	});
	assert.deepEqual(corpus.platform_rows, {
		ahk: [],
		hs: [
			'gesture_slot_change_action',
			'separator',
			'gesture_mode_options',
			'gesture_sensitivity_options'
		],
		linux: []
	});
	const locales = JSON.parse(readFileSync(resolve(SHARED, 'data/locale_order.json'), 'utf8')).order;
	assert.equal(locales.length, 21);
	assert.deepEqual(Object.keys(corpus.captions).sort(), [...locales].sort());
	for (const locale of locales) {
		const actual = JSON.parse(readFileSync(resolve(LOCALES_DIR, locale + '.json'), 'utf8'));
		assert.equal(
			actual['menu.gestures.mode_current'],
			actual['menu.gestures.mode_prefix'] + '%s',
			'exact existing translated mode prefix: ' + locale
		);
		assert.equal(
			actual['menu.gestures.sensitivity_current'],
			actual['menu.gestures.sensitivity_prefix'] + '%s',
			'exact existing translated sensitivity prefix: ' + locale
		);
		assert.equal(
			corpus.captions[locale].mode_x1,
			actual['menu.gestures.mode_prefix'] + actual['menu.gestures.mode_single']
		);
		assert.equal(
			corpus.captions[locale].mode_incremental,
			actual['menu.gestures.mode_prefix'] + actual['menu.gestures.mode_incremental']
		);
		assert.equal(
			corpus.captions[locale].sensitivity_3_5,
			actual['menu.gestures.sensitivity_prefix'] + '3.5'
		);
	}
	const owner = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/macos/ui/menu/menu_gestures.lua'),
		'utf8'
	);
	function hasSequence(tokens, sequence) {
		return tokens.some((_, index) =>
			sequence.every((value, offset) => tokens[index + offset]?.value === value)
		);
	}
	function assertSwipeWiring(source, records) {
		assert.deepEqual(
			records[0],
			{ type: 'include', section: 'gesture_change_action' },
			'real import of unchanged command declaration'
		);
		const tokens = scriptTokens(source, '.lua');
		assert.ok(
			hasSequence(tokens, [
				'ManifestMenu',
				'.',
				'template_rows',
				'(',
				corpus.section,
				',',
				'slot_commands',
				',',
				'slot_getters',
				',',
				'{'
			])
		);
		for (const [id, payload] of [
			['gesture_mode_options', 'modeSubmenu'],
			['gesture_sensitivity_options', 'sensSubmenu']
		])
			assert.ok(
				hasSequence(tokens, ['[', id, ']', '=', payload]),
				'actual native child payload: ' + id
			);
		for (const id of [
			'gesture_slot_change_action',
			'gesture_slot_choice_ready',
			'gesture_mode_current_label',
			'gesture_sensitivity_current_label',
			'gesture_mode_incremental_ready'
		])
			assert.ok(
				hasSequence(tokens, ['[', id, ']', '=', 'function', '(', ')']),
				'actual native callback/getter: ' + id
			);
		assert.ok(
			hasSequence(tokens, [
				'ManifestMenu',
				'.',
				'template_rows',
				'(',
				'gesture_change_action',
				',',
				'slot_commands',
				',',
				'slot_getters',
				')'
			]),
			'actual tap child retains existing command path'
		);
		assert.ok(
			hasSequence(tokens, ['items', '=', 'swipeSubmenu']),
			'actual whole swipe child materialization'
		);
		assert.ok(
			hasSequence(tokens, ['items', '=', 'change_action_rows']),
			'actual tap child materialization'
		);
		for (const section of Object.values(corpus.child_sections))
			assert.ok(
				hasSequence(tokens, ['ManifestMenu', '.', 'template_rows', '(', section]),
				'actual unchanged native child declaration: ' + section
			);
	}
	assertSwipeWiring(owner, declared[corpus.section]);
	for (const id of [
		corpus.section,
		'gesture_mode_options',
		'gesture_sensitivity_options',
		'gesture_mode_current_label',
		'gesture_sensitivity_current_label',
		'gesture_mode_incremental_ready'
	])
		assert.throws(() =>
			assertSwipeWiring(
				owner.replaceAll('"' + id + '"', '"unowned_swipe"'),
				declared[corpus.section]
			)
		);
	const wrongImport = structuredClone(declared[corpus.section]);
	wrongImport[0].section = 'gesture_slot_mode_commands';
	assert.throws(() => assertSwipeWiring(owner, wrongImport));
	const erased = owner.replaceAll('"' + corpus.section + '"', '"unowned_swipe"');
	const falseCall =
		'ManifestMenu.template_rows("' + corpus.section + '", slot_commands, slot_getters, {})';
	assert.throws(() => assertSwipeWiring(erased + '\n-- ' + falseCall, declared[corpus.section]));
	assert.throws(() =>
		assertSwipeWiring(erased + '\n' + JSON.stringify(falseCall), declared[corpus.section])
	);
}

// Shared full-slot composition is separate from genuine clickable mode payloads.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/gesture_swipe_template.json'), 'utf8')
	);
	const records = parseToml(readFileSync(MANIFEST_PATH, 'utf8')).menu[corpus.section];
	function assertSwipeRecords(actual) {
		assert.deepEqual(actual, corpus.rows, 'exact independently handwritten full-slot declaration');
	}
	assertSwipeRecords(records);
	for (const changed of [
		(rows) => {
			rows[2].i18n = 'menu.gestures.sensitivity_current';
		},
		(rows) => {
			rows[3].caption_getter = 'gesture_mode_current_label';
		},
		(rows) => {
			rows[2].id = 'gesture_sensitivity_options';
		},
		(rows) => {
			rows[3].disabled_when = ['gesture_slot_choice_ready'];
		},
		(rows) => {
			rows[1].platforms = ['linux'];
		}
	]) {
		const wrong = structuredClone(records);
		changed(wrong);
		assert.throws(() => assertSwipeRecords(wrong));
	}
	const source = readFileSync(resolve(__dirname, 'test-menu-parity.cjs'), 'utf8');
	const start = source.indexOf('const OPENS_SUBMENU = {');
	const end = source.indexOf('\n};', start);
	assert(start >= 0 && end > start, 'bounded actual graph registry');
	const graph = require('node:vm').runInNewContext(
		source.slice(start, end + 3) + '; OPENS_SUBMENU',
		{},
		{ timeout: 1000 }
	);
	function assertSwipeGraph(actual) {
		for (const finger of [2, 3, 4, 5]) {
			const entries = actual['gesture_slots_' + finger];
			assert(Array.isArray(entries));
			const edge = entries.find((e) => e && e.menu === corpus.section);
			assert(edge, 'actual full-slot edge');
			assert.equal(edge.kind, 'compose');
			assert.equal(edge.platforms.length, 1);
			assert.equal(edge.platforms[0], 'hs');
			assert.equal(edge.native_sources?.hs, 'macos/ui/menu/menu_gestures.lua');
		}
		const mode = actual.gesture_mode_options;
		assert.equal(mode.menu, 'gesture_slot_mode_commands');
		assert.notEqual(mode.kind, 'compose');
		assert.equal(mode.platforms.length, 1);
		assert.equal(mode.platforms[0], 'hs');
		const sens = actual.gesture_sensitivity_options;
		assert.equal(sens.menu, 'gesture_sensitivity_head');
		assert.equal(sens.kind, 'compose');
		assert.equal(sens.platforms.length, 1);
		assert.equal(sens.platforms[0], 'hs');
		assert.equal(sens.native_sources?.hs, 'macos/ui/menu/menu_gestures.lua');
	}
	assertSwipeGraph(graph);
	for (const changed of [
		(g) => {
			g.gesture_slots_2.find((e) => e?.menu === corpus.section).menu = 'gesture_change_action';
		},
		(g) => {
			g.gesture_slots_3.find((e) => e?.menu === corpus.section).native_sources.hs =
				'macos/ui/menu/menu_shortcuts.lua';
		},
		(g) => {
			g.gesture_slots_4.find((e) => e?.menu === corpus.section).platforms = ['linux'];
		},
		(g) => {
			g.gesture_slots_5.find((e) => e?.menu === corpus.section).kind = 'clicked';
		},
		(g) => {
			g.gesture_mode_options.kind = 'compose';
		},
		(g) => {
			g.gesture_sensitivity_options.kind = 'clicked';
		},
		(g) => {
			g.gesture_mode_options.menu = 'gesture_sensitivity_head';
		}
	]) {
		const wrong = structuredClone(graph);
		changed(wrong);
		assert.throws(() => assertSwipeGraph(wrong));
	}
}

// About's dynamic build identity stays native/shared formatter data; its fixed tail is declared once.
{
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/about_version_separator.json'), 'utf8')
	);
	assert.deepEqual(corpus.rows, [{ type: '---' }], 'handwritten original fixed separator');
	assert.equal(corpus.version_index, 1);
	assert.equal(corpus.separator_index, 2);
	assert.equal(corpus.channel_index, 3);
	const source = parseToml(readFileSync(MANIFEST_PATH, 'utf8')).menu;
	assert.deepEqual(source[corpus.section], corpus.rows);
	assert.deepEqual(JSON.parse(readFileSync(MENU_PATH, 'utf8'))[corpus.section], corpus.rows);
	function sequence(tokens, values) {
		return tokens.some((_, i) => values.every((value, n) => tokens[i + n]?.value === value));
	}
	function wiring(text, driver) {
		const tokens = scriptTokens(text, driver === 'ahk' ? '.ahk' : '.lua');
		const call =
			driver === 'ahk'
				? [
						'MenuRenderer_TemplateRows',
						'(',
						corpus.section,
						',',
						'Map',
						'(',
						')',
						',',
						'Map',
						'(',
						')',
						',',
						'Map',
						'(',
						')',
						')'
					]
				: ['ManifestMenu', '.', 'template_rows', '(', corpus.section, ')'];
		assert(sequence(tokens, call), 'actual fixed fragment call: ' + driver);
		const append =
			driver === 'ahk'
				? ['Rows', '.', 'Push', '(', 'Row', ')']
				: driver === 'hs'
					? ['table', '.', 'insert', '(', 'menu_items', ',', 'row', ')']
					: ['out', '[', '#', 'out', '+', '1', ']', '=', 'row'];
		assert(sequence(tokens, append), 'actual provider materialization: ' + driver);
	}
	for (const [driver, file] of [
		['ahk', 'windows/ui/menu/menu_init.ahk'],
		['hs', 'macos/ui/menu/menu_about.lua'],
		['linux', 'linux/ui/menu/menu_builder.lua']
	]) {
		const text = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', file), 'utf8');
		wiring(text, driver);
		const wrong = text.replaceAll('"' + corpus.section + '"', '"wrong_fragment"');
		assert.throws(() => wiring(wrong, driver));
		const fake =
			driver === 'ahk'
				? 'MenuRenderer_TemplateRows("' + corpus.section + '", Map(), Map(), Map())'
				: 'ManifestMenu.template_rows("' + corpus.section + '")';
		assert.throws(() => wiring(wrong + '\n' + (driver === 'ahk' ? '; ' : '-- ') + fake, driver));
		assert.throws(() => wiring(wrong + '\n' + JSON.stringify(fake), driver));
	}
	console.log(
		'About version separator: independent fixed source, shared fragment and three genuine provider consumers.'
	);
}

{
	const assert = require('node:assert/strict');
	const text = readFileSync(resolve(__dirname, 'test-menu-parity.cjs'), 'utf8');
	const start = text.indexOf('const OPENS_SUBMENU = {');
	const end = text.indexOf('\n};', start);
	assert(start >= 0 && end > start);
	const graph = require('node:vm').runInNewContext(
		text.slice(start, end + 3) + '; OPENS_SUBMENU',
		{},
		{ timeout: 1000 }
	);
	function aboutEdges(g) {
		const rows = g.about_updates;
		assert(Array.isArray(rows));
		for (const prior of [
			'about_update_channel_menu',
			'about_update_frequency_menu',
			'about_source_menu'
		])
			assert(rows.includes(prior), 'original About edge retained: ' + prior);
		const row = rows.find((e) => e?.menu === 'about_version_separator');
		assert(row);
		assert.equal(row.kind, 'compose');
		for (const platform of ['ahk', 'hs', 'linux']) assert(row.platforms.includes(platform));
		for (const [platform, path] of [
			['ahk', 'windows/ui/menu/menu_init.ahk'],
			['hs', 'macos/ui/menu/menu_about.lua'],
			['linux', 'linux/ui/menu/menu_builder.lua']
		])
			assert.equal(row.native_sources[platform], path);
	}
	aboutEdges(graph);
	for (const mutate of [
		(g) => {
			g.about_updates.find((e) => e?.menu === 'about_version_separator').menu = 'about_menu';
		},
		(g) => {
			g.about_updates.find((e) => e?.menu === 'about_version_separator').kind = 'clicked';
		},
		(g) => {
			g.about_updates.find((e) => e?.menu === 'about_version_separator').native_sources.linux =
				'linux/ui/menu/agent_rows.lua';
		},
		(g) => {
			g.about_updates = g.about_updates.filter((e) => e !== 'about_update_channel_menu');
		}
	]) {
		const wrong = structuredClone(graph);
		mutate(wrong);
		assert.throws(() => aboutEdges(wrong));
	}
}

// Custom-profile child callbacks stay native; their fixed presentation is shared.
{
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const expected = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/custom_profile_children.json'), 'utf8')
	);
	const declared = parseToml(readFileSync(MANIFEST_PATH, 'utf8')).menu;
	const generated = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(declared[expected.section], expected.declaration);
	assert.deepEqual(generated[expected.section], expected.declaration);
	const languages = JSON.parse(
		readFileSync(resolve(SHARED, 'data/locale_order.json'), 'utf8')
	).order;
	assert.equal(languages.length, 21);
	assert.deepEqual(Object.keys(expected.caption_snapshots).sort(), [...languages].sort());
	for (const code of languages) {
		const values = JSON.parse(readFileSync(resolve(LOCALES_DIR, code + '.json'), 'utf8'));
		for (const [key, value] of Object.entries(expected.caption_snapshots[code]))
			assert.equal(values[key], value, code + ': original native caption ' + key);
	}
	function wiring(source, platform) {
		const tokens = scriptTokens(source, '.lua').map((token) => token.value);
		function has(sequence) {
			return tokens.some((_, i) => sequence.every((value, n) => tokens[i + n] === value));
		}
		assert(
			has(['ManifestMenu', '.', 'template_rows', '(', expected.section, ',']),
			'actual canonical renderer consumer'
		);
		for (const id of expected.platform_rows[platform]) {
			if (id === '---') continue;
			assert(has(['[', id, ']', '=', 'function']), 'actual native callback binding: ' + id);
		}
		assert(has(['[', 'llm_custom_profile_active', ']', '=', 'function']), 'native active getter');
		assert(
			has(['[', 'llm_custom_profile_ready', ']', '=', 'child_ready']),
			'native current-owner admission'
		);
		assert(has(['local', 'function', 'child_ready', '(', ')']), 'actual readiness function');
		assert(
			platform === 'hs'
				? has(['item', '.', 'items', '=', 'ManifestMenu', '.', 'template_rows'])
				: has(['items', '=', 'ManifestMenu', '.', 'template_rows']),
			'actual child payload materializes template'
		);
	}
	for (const [platform, file] of [
		['hs', 'macos/ui/menu/menu_llm/profiles_manager.lua'],
		['linux', 'linux/ui/menu/menu_builder.lua']
	]) {
		const source = readFileSync(resolve(REPO_ROOT, 'static/ergopti_plus', file), 'utf8');
		wiring(source, platform);
		for (const name of [
			expected.section,
			...expected.platform_rows[platform].filter((id) => id !== '---'),
			'llm_custom_profile_active',
			'llm_custom_profile_ready'
		])
			assert.throws(() => wiring(source.replaceAll('"' + name + '"', '"wrong_owner"'), platform));
		const wrong = source.replace(
			'ManifestMenu.template_rows("' + expected.section + '"',
			'Foreign.template_rows("' + expected.section + '"'
		);
		assert.throws(() =>
			wiring(wrong + '\n-- ManifestMenu.template_rows("' + expected.section + '")', platform)
		);
		assert.throws(() =>
			wiring(
				wrong + '\nlocal decorative = [[ManifestMenu.template_rows("' + expected.section + '")]]',
				platform
			)
		);
	}
	const graphText = readFileSync(resolve(__dirname, 'test-menu-parity.cjs'), 'utf8');
	const start = graphText.indexOf('const OPENS_SUBMENU = {');
	const end = graphText.indexOf('\n};', start);
	const graph = require('node:vm').runInNewContext(
		graphText.slice(start, end + 3) + '; OPENS_SUBMENU'
	);
	function childEdges(candidate) {
		assert(Array.isArray(candidate.llm_profile));
		assert(
			candidate.llm_profile.includes('llm_profile_commands'),
			'original Create/Clone child retained'
		);
		const edge = candidate.llm_profile.find((row) => row?.menu === expected.section);
		assert(edge);
		assert.equal(edge.kind, undefined, 'ordinary clicked child retains actionable-row floor');
		assert.deepEqual([...edge.platforms], ['hs', 'linux']);
	}
	childEdges(graph);
	for (const mutate of [
		(g) => {
			g.llm_profile.find((e) => e?.menu === expected.section).menu = 'llm_menu';
		},
		(g) => {
			g.llm_profile.find((e) => e?.menu === expected.section).kind = 'compose';
		},
		(g) => {
			g.llm_profile.find((e) => e?.menu === expected.section).platforms = ['ahk'];
		},
		(g) => {
			g.llm_profile = g.llm_profile.filter((e) => e !== 'llm_profile_commands');
		}
	]) {
		const wrong = structuredClone(graph);
		mutate(wrong);
		assert.throws(() => childEdges(wrong));
	}
	console.log(
		'Custom profile children: independent declared order, 21 existing captions, actual native bindings and clicked graph ownership.'
	);
}

// Linux's five numeric preset pickers share the complete free-entry tail.
{
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const expected = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/linux_numeric_custom_tail.json'), 'utf8')
	);
	const section = 'llm_numeric_custom_rows';
	const declared = parseToml(readFileSync(MANIFEST_PATH, 'utf8')).menu;
	const generated = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	function declaration(candidate) {
		assert.deepEqual(candidate[section], expected.declaration);
	}
	declaration(declared);
	declaration(generated);
	for (const mutate of [
		(m) => (m[section][1].i18n = 'button.cancel'),
		(m) => m[section].reverse(),
		(m) => (m[section][1].platforms = ['hs']),
		(m) => (m[section][1].id = 'foreign_owner')
	]) {
		const wrong = structuredClone(generated);
		mutate(wrong);
		assert.throws(() => declaration(wrong));
	}
	const languages = JSON.parse(
		readFileSync(resolve(SHARED, 'data/locale_order.json'), 'utf8')
	).order;
	assert.equal(languages.length, 21);
	assert.deepEqual(Object.keys(expected.captions).sort(), [...languages].sort());
	for (const code of languages) {
		const strings = JSON.parse(readFileSync(resolve(LOCALES_DIR, code + '.json'), 'utf8'));
		assert.equal(strings['menu.llm.generation.custom_value'], expected.captions[code]);
	}
	function wiring(source) {
		for (const [owner, receiver] of [
			['llm_trigger', 'delay_choices'],
			['llm_generation', 'choices']
		]) {
			const begin = source.indexOf('dynamic_handlers["' + owner + '"] = function(target)');
			assert(begin >= 0, 'actual numeric provider ' + owner);
			const rest = source.slice(begin + 1);
			const end = rest.indexOf('dynamic_handlers[');
			const body = source.slice(begin, end < 0 ? source.length : begin + 1 + end);
			const tokens = scriptTokens(body, '.lua').map((t) => t.value);
			function has(seq) {
				return tokens.some((_, i) => seq.every((v, n) => tokens[i + n] === v));
			}
			assert(
				has([
					'local',
					'custom_rows',
					'=',
					'ManifestMenu',
					'.',
					'template_rows',
					'(',
					section,
					',',
					'{',
					'[',
					'llm_numeric_custom_value',
					']',
					'=',
					'function',
					'(',
					')'
				]),
				'actual native command binding in ' + owner
			);
			assert(
				has([
					'for',
					'_',
					',',
					'row',
					'in',
					'ipairs',
					'(',
					'custom_rows',
					'or',
					'{',
					'}',
					')',
					'do',
					receiver,
					'[',
					'#',
					receiver,
					'+',
					'1',
					']',
					'=',
					'row',
					'end'
				]),
				'actual numeric tail appended to preset owner ' + owner
			);
		}
	}
	const native = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/linux/ui/menu/menu_builder.lua'),
		'utf8'
	);
	wiring(native);
	for (const mutate of [
		(s) =>
			s.replace(
				'ManifestMenu.template_rows("' + section + '"',
				'Foreign.template_rows("' + section + '"'
			),
		(s) => s.replace('["llm_numeric_custom_value"] = function()', '["foreign_owner"] = function()'),
		(s) => s.replace('do choices[#choices + 1] = row end', 'do unused[#unused + 1] = row end'),
		(s) => s.replace('dynamic_handlers["llm_trigger"]', 'dynamic_handlers["unreachable"]')
	])
		assert.throws(() => wiring(mutate(native)));
	const graphText = readFileSync(resolve(__dirname, 'test-menu-parity.cjs'), 'utf8');
	const start = graphText.indexOf('const OPENS_SUBMENU = {');
	const end = graphText.indexOf('\n};', start);
	const graph = require('node:vm').runInNewContext(
		graphText.slice(start, end + 3) + '; OPENS_SUBMENU'
	);
	function edges(g) {
		for (const [provider, oldChild] of [
			['llm_trigger', 'llm_trigger_menu'],
			['llm_generation', 'llm_generation_menu']
		]) {
			assert(Array.isArray(g[provider]));
			assert(g[provider].includes(oldChild), 'original clicked child retained');
			const edge = g[provider].find((e) => e?.menu === section);
			assert(edge);
			assert.equal(edge.kind, 'compose');
			assert.deepEqual([...edge.platforms], ['linux']);
			assert.equal(edge.native_sources.linux, 'linux/ui/menu/menu_builder.lua');
		}
	}
	edges(graph);
	for (const mutate of [
		(g) => (g.llm_trigger.find((e) => e?.menu === section).menu = 'llm_trigger_menu'),
		(g) => (g.llm_generation.find((e) => e?.menu === section).kind = 'clicked'),
		(g) => (g.llm_trigger.find((e) => e?.menu === section).platforms = ['hs']),
		(g) =>
			(g.llm_generation.find((e) => e?.menu === section).native_sources.linux =
				'linux/ui/menu/agent_rows.lua'),
		(g) => (g.llm_trigger = g.llm_trigger.filter((e) => e !== 'llm_trigger_menu'))
	]) {
		const wrong = structuredClone(graph);
		mutate(wrong);
		assert.throws(() => edges(wrong));
	}
	console.log(
		'Linux numeric tails: independent shared declaration, 21 existing captions, real preset receivers and preserved clicked children.'
	);
}

// Profile section headings are real inert fragments, never clicked children.
{
	const assert = require('node:assert/strict');
	const fs = require('node:fs');
	const path = require('node:path');
	const vm = require('node:vm');
	const shared = path.resolve(__dirname, '../../static/ergopti_plus/_shared');
	const declared = JSON.parse(
		fs.readFileSync(path.join(shared, 'modules/menu/menu_manifest.json'), 'utf8')
	);
	const expected = JSON.parse(
		fs.readFileSync(path.join(shared, 'tests/corpus/menus/profile_section_headings.json'), 'utf8')
	);
	const sections = ['llm_profile_builtin_heading', 'llm_profile_custom_heading'];
	function declaration(document) {
		for (const section of sections) assert.deepEqual(document[section], expected.sections[section]);
	}
	declaration(declared);
	for (const mutate of [
		(d) => delete d.llm_profile_builtin_heading,
		(d) => d.llm_profile_custom_heading.reverse(),
		(d) => (d.llm_profile_builtin_heading[0].i18n = 'button.cancel'),
		(d) => (d.llm_profile_custom_heading[1].platforms = ['hs']),
		(d) => (d.llm_profile_builtin_heading[1].type = 'label'),
		(d) => (d.llm_profile_custom_heading[0].type = 'label')
	]) {
		const wrong = structuredClone(declared);
		mutate(wrong);
		assert.throws(() => declaration(wrong));
	}
	assert.equal(Object.keys(expected.captions).length, 21);
	for (const [language, captions] of Object.entries(expected.captions)) {
		const values = JSON.parse(
			fs.readFileSync(path.join(shared, 'data/locales', language + '.json'), 'utf8')
		);
		assert.deepEqual(
			expected.keys.map((key) => values[key]),
			captions
		);
	}
	const owners = {
		ahk: 'windows/ui/menu/menu_llm/menu_profiles.ahk',
		hs: 'macos/ui/menu/menu_llm/profiles_manager.lua',
		linux: 'linux/ui/menu/menu_builder.lua'
	};
	const { scriptTokens } = require('../lib/script-source.cjs');
	function sequence(tokens, values) {
		return tokens.some((_, index) =>
			values.every((value, offset) => tokens[index + offset]?.value === value)
		);
	}
	function wiring(source, platform, document = declared) {
		source = profileFrameOwnerSource(source, platform);
		const frame = platform === 'ahk' ? 'llm_profile_windows_frame' : 'llm_profile_lua_frame';
		const tokens = scriptTokens(source, platform === 'ahk' ? '.ahk' : '.lua');
		const call =
			platform === 'ahk'
				? ['return', 'MenuRenderer_TemplateRows', '(', frame, ',']
				: ['local', 'rows', '=', 'ManifestMenu', '.', 'template_rows', '(', frame, ','];
		assert(sequence(tokens, call), 'actual provider consumes the complete declared frame');
		const native =
			platform === 'ahk'
				? ['llm_profile_builtin_rows', 'llm_profile_custom_rows']
				: ['llm_profile_builtin_rows', 'llm_profile_custom_rows'];
		for (const id of native) {
			const payload = id.includes('builtin')
				? platform === 'ahk'
					? '_LLM_Menu_ProfileBuiltinRows'
					: 'builtin_rows'
				: platform === 'ahk'
					? '_LLM_Menu_ProfileCustomRows'
					: 'custom_rows';
			assert(
				sequence(
					tokens,
					platform === 'ahk' ? [id, ',', payload, '.', 'Bind', '('] : ['[', id, ']', '=', payload]
				),
				'actual lazy native data binding: ' + id
			);
		}
		const builtin = document[frame].filter(
			(row) => row.type === 'include' && row.section === sections[0]
		);
		assert.equal(builtin.length, 1, 'exact frame import of original builtin presentation');
		assert.equal(builtin[0].on_refusal, 'omit_presentation');
		const custom = document[frame].filter(
			(row) => row.type === 'include' && row.section === 'llm_profile_custom_section'
		);
		assert.equal(custom.length, 1);
		assert.equal(
			custom[0].present_when,
			'llm_profile_custom_present',
			'original registry predicate controls heading and data together'
		);
		assert.deepEqual(document.llm_profile_custom_section, [
			{ type: 'include', section: sections[1], on_refusal: 'omit_presentation' },
			{ type: 'list', id: 'llm_profile_custom_rows' }
		]);
		if (platform === 'ahk') {
			assert(
				sequence(tokens, [
					'llm_profile_custom_present',
					',',
					'_LLM_Menu_ProfileCustomPresent',
					'.',
					'Bind',
					'('
				])
			);
			assert(sequence(tokens, ['return', 'user_profiles', '.', 'Length', '>', '0']));
		} else {
			assert(sequence(tokens, ['[', 'llm_profile_custom_present', ']', '=', 'custom_present']));
			assert(
				sequence(
					tokens,
					platform === 'hs'
						? [
								'return',
								'type',
								'(',
								'user_profiles',
								')',
								'=',
								'=',
								'table',
								'and',
								'#',
								'user_profiles',
								'>',
								'0'
							]
						: ['return', '#', 'user_profiles', '>', '0']
				)
			);
			assert(
				sequence(
					tokens,
					platform === 'hs'
						? ['return', 'ManifestMenu', '.', 'render_rows', '(', 'rows', ',']
						: ['items', '=', 'rows']
				)
			);
		}
		assert(
			!/(?:t|i18n_safe|i18n\.section)\("menu\.profiles\.header_(?:default|custom)_profiles"\)/.test(
				source
			)
		);
	}
	for (const [platform, owner] of Object.entries(owners)) {
		const source = fs.readFileSync(path.resolve(shared, '..', owner), 'utf8');
		wiring(source, platform);
		for (const id of [
			platform === 'ahk' ? 'llm_profile_windows_frame' : 'llm_profile_lua_frame',
			'llm_profile_builtin_rows',
			'llm_profile_custom_rows',
			'llm_profile_custom_present'
		])
			assert.throws(() => wiring(source.replaceAll('"' + id + '"', '"unowned_frame"'), platform));
		for (const section of sections) {
			const wrong = structuredClone(declared);
			for (const rows of Object.values(wrong)) {
				if (!Array.isArray(rows)) continue;
				for (const row of rows)
					if (row.type === 'include' && row.section === section)
						row.section = 'llm_profile_commands';
			}
			assert.throws(() => wiring(source, platform, wrong));
		}
		const erased = source.replaceAll(
			'"' + (platform === 'ahk' ? 'llm_profile_windows_frame' : 'llm_profile_lua_frame') + '"',
			'"unowned_frame"'
		);
		const fake =
			platform === 'ahk'
				? 'return MenuRenderer_TemplateRows("llm_profile_windows_frame", Map(), Map(), Map())'
				: 'local rows = ManifestMenu.template_rows("llm_profile_lua_frame", {}, {}, {})';
		assert.throws(() => wiring(erased + (platform === 'ahk' ? '\n; ' : '\n-- ') + fake, platform));
		assert.throws(() => wiring(erased + '\n' + JSON.stringify(fake), platform));
		const ownerMarker =
			platform === 'ahk'
				? '_LLM_Menu_ProfileRows() {'
				: platform === 'hs'
					? 'local function build_profile_menu('
					: 'dynamic_handlers["llm_profile"] = function';
		const unrelatedOwner =
			platform === 'ahk'
				? '_LLM_Menu_UnrelatedRows() {'
				: platform === 'hs'
					? 'local function unrelated_build_profile_menu('
					: 'dynamic_handlers["unrelated_profile"] = function';
		const fakeOwner = source.replace(
			ownerMarker,
			(platform === 'ahk' ? '; ' : '-- ') + ownerMarker + '\n' + unrelatedOwner
		);
		assert.notEqual(fakeOwner, source, 'actual provider definition was renamed');
		assert.throws(
			() => wiring(fakeOwner, platform),
			'a commented owner marker cannot authenticate a renamed native builder'
		);
		for (const id of ['llm_profile_create', 'llm_profile_clone'])
			assert.equal(
				consumesProfileFrameCommand(fakeOwner, owner, declared, 'llm_profile_commands', id),
				false
			);
		if (platform === 'linux') {
			const foreignHandler = source.replace(
				ownerMarker,
				'local decoy = {dynamic_handlers={}}; decoy.' + ownerMarker
			);
			assert.notEqual(foreignHandler, source);
			assert.throws(
				() => wiring(foreignHandler, platform),
				'a foreign table receiver cannot authenticate the real dynamic provider'
			);
			for (const id of ['llm_profile_create', 'llm_profile_clone'])
				assert.equal(
					consumesProfileFrameCommand(foreignHandler, owner, declared, 'llm_profile_commands', id),
					false
				);
		}
		if (platform === 'ahk') {
			const unicodeOwner = source.replace(ownerMarker, 'É' + ownerMarker);
			assert.notEqual(unicodeOwner, source);
			assert.throws(
				() => wiring(unicodeOwner, platform),
				'an ASCII suffix of a different Unicode AHK identifier is not the actual owner'
			);
			for (const id of ['llm_profile_create', 'llm_profile_clone'])
				assert.equal(
					consumesProfileFrameCommand(unicodeOwner, owner, declared, 'llm_profile_commands', id),
					false
				);
		}
		// An executable decoy outside the actual provider cannot repair withdrawn ownership.
		assert.throws(() => wiring(erased + '\n' + fake, platform));
		if (platform !== 'ahk') {
			const discarded = profileFrameOwnerSource(source, platform).replace(
				platform === 'hs'
					? 'return ManifestMenu.render_rows(rows, "llm_profile")'
					: 'items = rows,',
				platform === 'hs' ? 'return {}' : 'items = discarded_rows,'
			);
			assert.throws(() => wiring(discarded, platform));
		}
	}
	const graphSource = fs.readFileSync(path.resolve(__dirname, 'test-menu-parity.cjs'), 'utf8');
	const start = graphSource.indexOf('const OPENS_SUBMENU = {');
	const end = graphSource.indexOf('\n};', start);
	const graph = vm.runInNewContext(graphSource.slice(start, end + 3) + '; OPENS_SUBMENU');
	function edges(value) {
		assert(Array.isArray(value.llm_profile));
		assert(
			value.llm_profile.includes('llm_profile_commands'),
			'the original clicked command child survives'
		);
		const original = value.llm_profile.find((edge) => edge?.menu === 'llm_custom_profile_controls');
		assert(original);
		assert.deepEqual([...original.platforms], ['hs', 'linux']);
		for (const [frame, platforms] of [
			['llm_profile_windows_frame', ['ahk']],
			['llm_profile_lua_frame', ['hs', 'linux']]
		]) {
			const edge = value.llm_profile.find((item) => item?.menu === frame);
			assert(edge);
			assert.equal(edge.kind, 'compose');
			assert.deepEqual([...edge.platforms], platforms);
			for (const platform of platforms)
				assert.equal(edge.native_sources[platform], owners[platform]);
		}
		// Include graph preserves both original inert descendants through the actual frame.
		for (const section of sections) {
			const target = section.includes('custom')
				? declared.llm_profile_custom_section
				: declared.llm_profile_windows_frame;
			assert(target.some((row) => row.type === 'include' && row.section === section));
		}
	}
	edges(graph);
	for (const mutate of [
		(g) =>
			(g.llm_profile.find((e) => e?.menu === 'llm_profile_windows_frame').menu =
				'llm_profile_commands'),
		(g) => (g.llm_profile.find((e) => e?.menu === 'llm_profile_lua_frame').kind = 'submenu'),
		(g) => (g.llm_profile.find((e) => e?.menu === 'llm_profile_windows_frame').platforms = ['hs']),
		(g) =>
			(g.llm_profile.find((e) => e?.menu === 'llm_profile_lua_frame').native_sources.linux =
				owners.hs),
		(g) => (g.llm_profile = g.llm_profile.filter((e) => e !== 'llm_profile_commands'))
	]) {
		const wrong = structuredClone(graph);
		mutate(wrong);
		assert.throws(() => edges(wrong));
	}
	console.log(
		'Profile headings: independent declaration, original 21 captions, real three-driver fragment publication and clicked-child preservation.'
	);
}

// Exact direct-row selectors reuse canonical commands without a second policy.
{
	const assertFrame = require('node:assert/strict');
	const { validateChildTemplates } = require('../lib/menu-row-availability.cjs');
	const originalFrame = {
		frame: [
			{ type: 'list', id: 'native_data' },
			{ type: 'include', section: 'commands', row_id: 'clone', present_when: 'clone_present' },
			{ type: 'include', section: 'commands', row_id: 'create' }
		],
		commands: [
			{ type: 'command', id: 'create', i18n: 'menu.profiles.create_profile' },
			{ type: 'command', id: 'clone', i18n: 'menu.profiles.clone_builtin' }
		]
	};
	assertFrame.doesNotThrow(() => validateChildTemplates(originalFrame));
	const controls = [
		['empty selector', (m) => (m.frame[1].row_id = '')],
		['unknown selector', (m) => (m.frame[1].row_id = 'absent')],
		['wrong-case selector', (m) => (m.frame[1].row_id = 'Clone')],
		['nonstring selector', (m) => (m.frame[1].row_id = false)],
		['duplicate selector', (m) => (m.commands[0].id = 'clone')],
		[
			'nested selector',
			(m) => {
				m.commands[1] = { type: 'include', section: 'nested' };
				m.nested = [{ type: 'command', id: 'clone' }];
			}
		],
		['empty presence', (m) => (m.frame[1].present_when = '')],
		['nonstring presence', (m) => (m.frame[1].present_when = true)],
		['absent section', (m) => (m.frame[1].section = 'missing')],
		['competing caption', (m) => (m.frame[1].i18n = 'native caption')]
	];
	for (const [name, mutate] of controls) {
		const m = structuredClone(originalFrame);
		mutate(m);
		assertFrame.throws(() => validateChildTemplates(m), undefined, name);
	}
	const legacyFrame = structuredClone(originalFrame);
	delete legacyFrame.frame[1].row_id;
	delete legacyFrame.frame[1].present_when;
	assertFrame.doesNotThrow(() => validateChildTemplates(legacyFrame));
}

// Presentation omission is opt-in and compiler-proven inert throughout its target.
{
	const assertPresentation = require('node:assert/strict');
	const { validateChildTemplates } = require('../lib/menu-row-availability.cjs');
	const original = {
		frame: [
			{ type: 'include', section: 'presentation', on_refusal: 'omit_presentation' },
			{ type: 'list', id: 'native' }
		],
		presentation: [
			{ type: 'section_header', i18n: 'menu.profiles.header_default_profiles' },
			{ type: '---' },
			{ type: 'include', section: 'nested' }
		],
		nested: [{ type: 'label', id: 'custom', i18n: 'menu.profiles.header_custom_profiles' }]
	};
	assertPresentation.doesNotThrow(() => validateChildTemplates(original));
	const controls = [
		['empty enum', (m) => (m.frame[0].on_refusal = '')],
		['unknown enum', (m) => (m.frame[0].on_refusal = 'ignore')],
		['wrong-case enum', (m) => (m.frame[0].on_refusal = 'OMIT_PRESENTATION')],
		['false enum', (m) => (m.frame[0].on_refusal = false)],
		['wrong owner', (m) => (m.frame[1].on_refusal = 'omit_presentation')],
		['missing target', (m) => (m.frame[0].section = 'missing')],
		['empty target', (m) => (m.presentation = [])],
		['malformed header', (m) => (m.presentation[0].i18n = '')],
		['header action', (m) => (m.presentation[0].action = 'native')],
		['header getter', (m) => (m.presentation[0].caption_getter = 'read')],
		['header children', (m) => (m.presentation[0].items = [])],
		['nested presence', (m) => (m.presentation[2].present_when = 'read')],
		['nested omission', (m) => (m.presentation[2].on_refusal = 'omit_presentation')],
		['nested cycle', (m) => (m.presentation[2].section = 'presentation')],
		['unknown row', (m) => (m.nested[0].type = 'unknown')],
		['command', (m) => (m.nested[0].type = 'command')],
		['check', (m) => (m.nested[0].type = 'check')],
		['group', (m) => (m.nested[0].type = 'group')],
		['list', (m) => (m.nested[0] = { type: 'list', id: 'native' })],
		['feature', (m) => (m.nested[0].type = 'feature')],
		[
			'hidden clicked row',
			(m) =>
				(m.nested[0] = {
					type: 'command',
					id: 'native',
					i18n: 'caption',
					platforms: ['ahk'],
					unavailable: 'hide'
				})
		],
		[
			'mixed target selected safe row',
			(m) => {
				m.frame[0].row_id = 'safe';
				m.presentation[0].id = 'safe';
				m.presentation.push({ type: 'command', id: 'unsafe', i18n: 'caption' });
			}
		],
		['wrong platform shape', (m) => (m.presentation[0].platforms = 'hs')],
		['unknown platform', (m) => (m.presentation[0].platforms = ['other'])],
		['duplicate platform', (m) => (m.presentation[0].platforms = ['hs', 'hs'])]
	];
	for (const [name, mutate] of controls) {
		const menu = structuredClone(original);
		mutate(menu);
		assertPresentation.throws(() => validateChildTemplates(menu), undefined, name);
	}
	const selected = structuredClone(original);
	selected.presentation[0].id = 'safe';
	selected.frame[0].row_id = 'safe';
	assertPresentation.doesNotThrow(() => validateChildTemplates(selected));
	const conditional = structuredClone(original);
	conditional.frame[0].present_when = 'native_present';
	assertPresentation.doesNotThrow(() => validateChildTemplates(conditional));
	const ordinary = structuredClone(original);
	delete ordinary.frame[0].on_refusal;
	ordinary.nested[0].type = 'command';
	assertPresentation.doesNotThrow(() => validateChildTemplates(ordinary));
}

// Both native Agent systems consume the independent fixed model-control frame.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/agent_system_model.json'), 'utf8')
	);
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(corpus.systems, ['system1', 'system2']);
	assert.deepEqual(
		manifest[corpus.section],
		corpus.rows,
		'the complete two-row frame is independently pinned'
	);
	assert.equal(corpus.rows.length, 2);
	assert.equal(corpus.row_id, 'agent_system_model');
	assert.equal(corpus.model, 'hand/50%');
	assert.equal(corpus.caption, 'Model… (hand/50%)');
	assert.equal(corpus.variants.length, 2);
	for (const variant of corpus.variants) {
		assert.deepEqual(manifest[variant.section], [
			{ type: '---' },
			{
				type: 'command',
				id: 'agent_system_model',
				i18n: variant.label_key,
				disabled_when: ['agent_system_model_ready']
			}
		]);
		const mac = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus/macos/ui/menu/menu_llm/agent_panel.lua'),
			'utf8'
		);
		assert(mac.includes('ManifestMenu.template_rows("' + variant.section + '"'));
	}
	for (const [driver, relative, call] of [
		['windows', 'ui/menu/menu_llm/menu_agent.ahk', 'MenuRenderer_TemplateRows'],
		['macos', 'ui/menu/menu_llm/agent_panel.lua', 'ManifestMenu.template_rows'],
		['linux', 'ui/menu/agent_rows.lua', 'require("infra.manifest_menu").template_rows']
	]) {
		const source = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
			'utf8'
		);
		assert(
			source.includes(call + '("agent_system_model_controls"'),
			driver + ' consumes the real shared frame'
		);
	}
	console.log('Agent system Model: canonical two-row frame and three actual native owners.');
}

// API creation keeps its actual platform-specific dialog/provider owner.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const corpus = JSON.parse(
		readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus/_shared/tests/corpus/menus/api_add_controls.json'),
			'utf8'
		)
	);
	assert.deepEqual(manifest[corpus.command_section], [corpus.command]);
	assert.deepEqual(manifest[corpus.group_section], [corpus.group]);
	assert.deepEqual(manifest[corpus.separator_section], [corpus.separator]);
	for (const code of [
		'ar',
		'cs',
		'da',
		'de',
		'en',
		'es',
		'fr',
		'he',
		'hi',
		'it',
		'ja',
		'ko',
		'no',
		'nl',
		'pl',
		'pt',
		'ru',
		'sv',
		'tr',
		'uk',
		'zh'
	]) {
		const strings = JSON.parse(
			readFileSync(
				resolve(REPO_ROOT, 'static/ergopti_plus/_shared/data/locales/' + code + '.json'),
				'utf8'
			)
		);
		assert.equal(
			typeof strings[corpus.label_key],
			'string',
			code + ' keeps the existing Add caption'
		);
		assert(strings[corpus.label_key].length > 0);
		if (code === 'en') {
			assert.equal(strings[corpus.label_key], corpus.label);
			assert.equal(strings[corpus.mutated_key], corpus.mutated_label);
		}
	}
	for (const [driver, relative, call, section] of [
		[
			'windows',
			'ui/menu/menu_llm/menu_api_entries.ahk',
			'MenuRenderer_TemplateRows',
			corpus.command_section
		],
		['macos', 'ui/menu/menu_llm/api_panel.lua', 'ManifestMenu.template_rows', corpus.group_section],
		['linux', 'ui/menu/llm_backend_rows.lua', 'ManifestMenu.template_rows', corpus.group_section]
	]) {
		const source = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
			'utf8'
		);
		assert(source.includes(call + '("' + section + '"'), driver + ' consumes the actual Add frame');
		assert(
			source.includes(call + '("' + corpus.separator_section + '"'),
			driver + ' consumes the existing separator'
		);
	}
	console.log(
		'API Add: independent declarations, 21 existing captions, authentic native dialog/provider and separator owners.'
	);
}

// Backend choices retain their native controls; only two drivers allocate this boundary.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/backend_choice_boundary.json'), 'utf8')
	);
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(manifest[corpus.section], corpus.rows);
	assert.deepEqual(corpus.platform_rows, {
		ahk: [{ separator: true }],
		hs: [],
		linux: [{ separator: true }]
	});
	for (const code of [
		'ar',
		'cs',
		'da',
		'de',
		'en',
		'es',
		'fr',
		'he',
		'hi',
		'it',
		'ja',
		'ko',
		'no',
		'nl',
		'pl',
		'pt',
		'ru',
		'sv',
		'tr',
		'uk',
		'zh'
	]) {
		const labels = JSON.parse(
			readFileSync(resolve(SHARED, 'data/locales/' + code + '.json'), 'utf8')
		);
		for (const key of [corpus.marker_key, corpus.windows_next_key, ...corpus.linux_choice_keys]) {
			assert.equal(typeof labels[key], 'string', code + ': existing control key ' + key);
			assert(labels[key].trim().length > 0);
		}
		if (code === 'en') {
			assert.equal(labels[corpus.marker_key], corpus.marker_english);
			assert.equal(labels[corpus.windows_next_key], corpus.windows_next_english);
			assert.deepEqual(
				corpus.linux_choice_keys.map((key) => labels[key]),
				corpus.linux_choice_english
			);
		}
	}
	for (const [driver, relative, call] of [
		['windows', 'ui/menu/menu_llm/menu_models.ahk', 'MenuRenderer_TemplateRows'],
		['linux', 'ui/menu/llm_backend_rows.lua', 'ManifestMenu.template_rows']
	]) {
		const source = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
			'utf8'
		);
		assert(source.includes(call + '("llm_backend_choice_boundary"'));
	}
	const mac = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/macos/ui/menu/menu_llm/backend_panel.lua'),
		'utf8'
	);
	assert(!mac.includes('"llm_backend_choice_boundary"'));
	assert(mac.includes('ctx.local_server_rows(activate_api)'));
	console.log(
		'Backend boundary: independent two-driver rows, genuine macOS absence and21 existing captions.'
	);
}

// Independent per-model frame declarations retain bare Windows and decorated Mac headings.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/model_readout_frames.json'), 'utf8')
	);
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	for (const key of ['specs', 'caps']) {
		const expected = corpus[key];
		assert.deepEqual(manifest[expected.section], expected.rows);
		assert.deepEqual(expected.platform_rows, {
			ahk: [{ separator: true }, { label: expected.english, disabled: true }],
			hs: [{ separator: true }, { label: '— ' + expected.english + ' —', disabled: true }],
			linux: []
		});
		for (const code of [
			'ar',
			'cs',
			'da',
			'de',
			'en',
			'es',
			'fr',
			'he',
			'hi',
			'it',
			'ja',
			'ko',
			'no',
			'nl',
			'pl',
			'pt',
			'ru',
			'sv',
			'tr',
			'uk',
			'zh'
		]) {
			const strings = JSON.parse(
				readFileSync(resolve(SHARED, 'data/locales/' + code + '.json'), 'utf8')
			);
			for (const caption of [expected.key, corpus.selection_key, corpus.marker_key]) {
				assert.equal(typeof strings[caption], 'string', code + ': existing caption ' + caption);
				assert(strings[caption].trim().length > 0);
			}
			if (code === 'en') {
				assert.equal(strings[expected.key], expected.english);
				assert.equal(strings[corpus.selection_key], corpus.selection_english);
				assert.equal(strings[corpus.marker_key], corpus.marker_english);
			}
		}
		for (const [driver, relative, call] of [
			['windows', 'ui/menu/menu_llm/menu_models.ahk', 'MenuRenderer_TemplateRows'],
			['macos', 'ui/menu/menu_llm/models_selector.lua', 'ManifestMenu.template_rows']
		]) {
			const source = readFileSync(
				resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
				'utf8'
			);
			assert(
				source.includes(call + '("' + expected.section + '"'),
				driver + ': genuine per-model frame owner'
			);
		}
		const linux = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus/linux/ui/menu/menu_builder.lua'),
			'utf8'
		);
		assert(
			!linux.includes('"' + expected.section + '"'),
			'Linux has no per-model detail sheet to populate'
		);
	}
	const providers = JSON.parse(readFileSync(resolve(SHARED, 'modules/llm/models.json'), 'utf8'));
	const actual = providers
		.flatMap((p) => p.families.flatMap((f) => f.models))
		.filter((m) => m.name === corpus.native_model);
	assert.equal(
		actual.length,
		1,
		'the hand-pinned native model must exist exactly once in the shipped catalogue'
	);
	assert.equal(typeof actual[0].urls.ollama, 'string');
	assert.equal(typeof actual[0].capabilities, 'object');
	console.log(
		'Model readouts: authentic two-driver frames, genuine Linux absence and21 unchanged captions.'
	);
}

// Actual numeric providers retain each driver's existing boundary and caption policy.
{
	const assert = require('node:assert/strict');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/generation_boundaries.json'), 'utf8')
	);
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	for (const key of ['count', 'context', 'words']) {
		const expected = corpus.boundaries[key];
		assert.deepEqual(manifest[expected.section], expected.rows);
		assert.deepEqual(expected.projections.linux, [], 'Linux has no native numeric boundary');
		if (key !== 'count')
			assert.deepEqual(expected.projections.hs, [], 'macOS has no later numeric boundary');
		for (const [driver, relative, call] of [
			['windows', 'ui/menu/menu_llm/menu_settings.ahk', 'MenuRenderer_TemplateRows'],
			['macos', 'ui/menu/menu_llm/init.lua', 'ManifestMenu.template_rows']
		]) {
			const source = readFileSync(
				resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
				'utf8'
			);
			assert.equal(
				source.includes(call + '("' + expected.section + '"'),
				driver === 'windows' || key === 'count'
			);
		}
		const linux = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus/linux/ui/menu/menu_builder.lua'),
			'utf8'
		);
		assert(!linux.includes('"' + expected.section + '"'));
	}
	for (const code of [
		'ar',
		'cs',
		'da',
		'de',
		'en',
		'es',
		'fr',
		'he',
		'hi',
		'it',
		'ja',
		'ko',
		'no',
		'nl',
		'pl',
		'pt',
		'ru',
		'sv',
		'tr',
		'uk',
		'zh'
	]) {
		const strings = JSON.parse(
			readFileSync(resolve(SHARED, 'data/locales/' + code + '.json'), 'utf8')
		);
		for (const key of [...corpus.caption_keys, corpus.published_marker_key]) {
			assert.equal(typeof strings[key], 'string', code + ': existing numeric caption ' + key);
			assert(strings[key].trim().length > 0);
		}
	}
	console.log(
		'Generation boundaries: four actual constructors, authentic cross-platform absence and21 unchanged caption sets.'
	);
}

// The extension-list boundary has two actual native owners, independent of its children.
{
	const assert = require('assert');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const contract = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/shortcut_extension_boundary.json'), 'utf8')
	);
	assert.deepStrictEqual(manifest[contract.section], contract.rows);
	assert.deepStrictEqual(contract.projections.linux, []);
	assert.deepStrictEqual(contract.nonempty_order, ['separator', 'heading', 'extension_group']);
	for (const [driver, call] of [
		['windows', 'MenuRenderer_TemplateRows'],
		['macos', 'ManifestMenu.template_rows']
	]) {
		const source = readFileSync(
			resolve(
				REPO_ROOT,
				'static/ergopti_plus',
				driver,
				'ui/menu/menu_shortcuts.' + (driver === 'windows' ? 'ahk' : 'lua')
			),
			'utf8'
		);
		assert.ok(
			source.includes(call + '("' + contract.section + '"'),
			driver + ': actual extension boundary owner'
		);
	}
	for (const file of readdirSync(resolve(SHARED, 'data/locales')).filter((name) =>
		name.endsWith('.json')
	)) {
		const locale = JSON.parse(readFileSync(resolve(SHARED, 'data/locales', file), 'utf8'));
		assert.strictEqual(typeof locale[contract.caption_key], 'string');
		assert.ok(locale[contract.caption_key].trim().length > 0);
		assert.ok(locale[contract.caption_key] !== contract.caption_key);
	}
}

// Independently pinned catalogue boundaries retain the real native family/sheet order.
{
	const assert = require('node:assert/strict');
	const manifest = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/model_catalogue_boundaries.json'), 'utf8')
	);
	for (const key of ['family', 'origin']) {
		const expected = corpus.boundaries[key];
		assert.deepEqual(manifest[expected.section], expected.rows);
		assert.deepEqual(expected.projections.linux, []);
		for (const [driver, relative, call] of [
			['windows', 'ui/menu/menu_llm/menu_models.ahk', 'MenuRenderer_TemplateRows'],
			['macos', 'ui/menu/menu_llm/models_selector.lua', 'ManifestMenu.template_rows']
		]) {
			const source = readFileSync(
				resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
				'utf8'
			);
			assert.ok(
				source.includes(call + '("' + expected.section + '"'),
				driver + ': actual catalogue boundary owner'
			);
		}
	}
	const providers = JSON.parse(readFileSync(resolve(SHARED, 'modules/llm/models.json'), 'utf8'));
	const provider = providers.filter((item) => item.label === corpus.provider_caption);
	assert.equal(provider.length, 1);
	for (const [index, name] of [corpus.first_family_model, corpus.second_family_model].entries()) {
		const admitted = provider[0].families[index].models.filter(
			(model) => typeof model.urls.ollama === 'string' && model.urls.ollama.length > 0
		);
		assert.equal(admitted.length, 1);
		assert.equal(admitted[0].name, name);
	}
	for (const file of readdirSync(LOCALES_DIR).filter((name) => name.endsWith('.json'))) {
		const locale = JSON.parse(readFileSync(resolve(LOCALES_DIR, file), 'utf8'));
		for (const key of corpus.caption_keys) {
			assert.equal(typeof locale[key], 'string');
			assert.ok(locale[key].trim().length > 0 && locale[key] !== key);
		}
	}
}

// Independent absent-module messages are disabled presentation, with native ownership untouched.
{
	const assert = require('node:assert/strict');
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const expected = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/linux_absent_modules.json'), 'utf8')
	);
	const source = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/linux/ui/menu/menu_builder.lua'),
		'utf8'
	);
	assert.equal(expected.owners.length, 5);
	assert.equal(
		expected.owners.reduce((count, owner) => count + owner.rows.length, 0),
		6
	);
	for (const owner of expected.owners) {
		assert.deepEqual(menu[owner.section], owner.rows);
		assert.ok(source.includes('ManifestMenu.template_rows("' + owner.section + '"'));
		assert.ok(
			source.includes('if (' + owner.predicate + ')') ||
				source.includes('if ' + owner.predicate + ' then')
		);
		for (const file of readdirSync(LOCALES_DIR).filter((name) => name.endsWith('.json'))) {
			const locale = JSON.parse(readFileSync(resolve(LOCALES_DIR, file), 'utf8'));
			for (const row of owner.rows) {
				assert.equal(typeof locale[row.i18n], 'string');
				assert.ok(locale[row.i18n].trim().length > 0 && locale[row.i18n] !== row.i18n);
			}
		}
	}
}

// Actual hardware data and distinct native availability remain outside the inert boundary policy.
{
	const assert = require('node:assert/strict');
	const expected = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/model_hardware_boundary.json'), 'utf8')
	);
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	assert.deepEqual(menu[expected.section], expected.rows);
	assert.deepEqual(expected.projections.linux, []);
	const catalogue = JSON.parse(readFileSync(resolve(SHARED, 'modules/llm/models.json'), 'utf8'));
	const actual = catalogue
		.flatMap((provider) => provider.families.flatMap((family) => family.models))
		.filter((model) => model.name === expected.native_model);
	assert.equal(actual.length, 1);
	assert.deepEqual(actual[0].hardware_requirements.ollama, expected.hardware_ollama);
	assert.equal(typeof actual[0].urls.ollama, 'string');
	assert.ok(actual[0].urls.ollama.length > 0);
	for (const [driver, relative, call] of [
		['windows', 'ui/menu/menu_llm/menu_models.ahk', 'MenuRenderer_TemplateRows'],
		['macos', 'ui/menu/menu_llm/models_selector.lua', 'ManifestMenu.template_rows']
	]) {
		const source = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
			'utf8'
		);
		assert.ok(source.includes(call + '("' + expected.section + '"'));
	}
	for (const file of readdirSync(LOCALES_DIR).filter((name) => name.endsWith('.json'))) {
		const locale = JSON.parse(readFileSync(resolve(LOCALES_DIR, file), 'utf8'));
		for (const key of expected.caption_keys) {
			assert.equal(typeof locale[key], 'string');
			assert.ok(locale[key].trim().length > 0 && locale[key] !== key);
		}
	}
}

// Native trigger, display and live separators keep their true platform-specific roles.
{
	const assert = require('node:assert/strict');
	const expected = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/llm_control_boundaries.json'), 'utf8')
	);
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	for (const boundary of Object.values(expected.boundaries))
		assert.deepEqual(menu[boundary.section], boundary.rows);
	for (const [driver, relative, call, keys] of [
		[
			'windows',
			'ui/menu/menu_llm/menu_settings.ahk',
			'MenuRenderer_TemplateRows',
			['trigger', 'display']
		],
		['macos', 'ui/menu/menu_llm/live_mode_panel.lua', 'ManifestMenu.template_rows', ['live']],
		['linux', 'ui/menu/menu_builder.lua', 'ManifestMenu.template_rows', ['trigger']]
	]) {
		const source = readFileSync(
			resolve(REPO_ROOT, 'static/ergopti_plus', driver, relative),
			'utf8'
		);
		for (const key of keys)
			assert.ok(source.includes(call + '("' + expected.boundaries[key].section + '"'));
	}
	for (const file of readdirSync(LOCALES_DIR).filter((name) => name.endsWith('.json'))) {
		const locale = JSON.parse(readFileSync(resolve(LOCALES_DIR, file), 'utf8'));
		for (const key of expected.caption_keys) {
			assert.equal(typeof locale[key], 'string');
			assert.ok(locale[key].trim().length > 0 && locale[key] !== key);
		}
	}
}

// The Linux selection boundaries are inert fragments of the actual native provider.
{
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const { publishesMenuTemplate } = require('../lib/menu-shared-delegation.cjs');
	const corpus = JSON.parse(
		readFileSync(resolve(SHARED, 'tests/corpus/menus/linux_selection_boundaries.json'), 'utf8')
	);
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const source = readFileSync(
		resolve(REPO_ROOT, 'static/ergopti_plus/linux/ui/menu/menu_builder.lua'),
		'utf8'
	);
	const tokens = scriptTokens(source, '.lua');
	const sections = ['selection_case_boundary', 'selection_helper_boundary'];
	assert.equal(corpus.selection_child_order.length, 9);
	assert.deepEqual(
		corpus.selection_child_order.filter((row) => row.separator).map((row) => row.section),
		sections
	);
	for (const section of sections) {
		assert.deepEqual(menu[section], [corpus.fragment]);
		assert.ok(publishesMenuTemplate(source, '.lua', section));
	}
	const methods = {
		selection_caps_word_control: 'check_row',
		selection_case_commands: 'get_array',
		selection_helper_commands: 'get_array',
		selection_case_boundary: 'template_rows',
		selection_helper_boundary: 'template_rows'
	};
	const at = (value) =>
		tokens.findIndex(
			(token, index) =>
				token.kind === 'string' &&
				token.value === value &&
				tokens[index - 1]?.value === '(' &&
				tokens[index - 2]?.kind === 'identifier' &&
				tokens[index - 2]?.value === methods[value] &&
				tokens[index - 3]?.value === '.' &&
				tokens[index - 4]?.kind === 'identifier' &&
				tokens[index - 4]?.value === 'ManifestMenu' &&
				!['function', '.', ':'].includes(tokens[index - 5]?.value)
		);
	const order = [
		'selection_caps_word_control',
		sections[0],
		'selection_case_commands',
		sections[1],
		'selection_helper_commands'
	].map(at);
	assert.ok(order.every((position) => position >= 0));
	assert.ok(order.every((position, index) => index === 0 || position > order[index - 1]));
	for (const file of readdirSync(LOCALES_DIR).filter((name) => name.endsWith('.json'))) {
		const locale = JSON.parse(readFileSync(resolve(LOCALES_DIR, file), 'utf8'));
		for (const row of corpus.selection_child_order.filter((row) => !row.separator)) {
			assert.equal(typeof locale[row.key], 'string');
			assert.ok(locale[row.key].trim().length > 0 && locale[row.key] !== row.key);
		}
	}
}
