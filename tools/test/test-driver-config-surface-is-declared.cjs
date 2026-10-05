// tools/test/test-driver-config-surface-is-declared.cjs

/**
 * ==============================================================================
 * MODULE: Driver Config Surface — Declared in the Manifest
 * DESCRIPTION:
 * Every config.toml section/key a driver reads or writes must be declared in
 * _shared/modules/features/manifest.toml FOR THAT PLATFORM. The manifest is the
 * single source of truth for what a config file contains; a key the driver
 * persists but the manifest has never heard of is a setting with no default, no
 * type, no schema entry and no menu row — invisible to every gate that exists.
 *
 * WHY THIS GATE EXISTS:
 * The backlog recorded the Linux half of the namespace invariant as "0 of 324
 * features carry `linux`", which reads like a labelling job. It is not. Measured
 * 2026-08-02, of the ten config surfaces the Linux driver actually touches,
 * exactly ZERO are declared for it:
 *
 *   script.locale            declared for ahk+hs only — Linux writes it anyway
 *   llm.enabled              same
 *   script.layout            no entry
 *   script.onboarding_done   no entry
 *   llm.model                no entry — and llm.models.ollama already means this
 *   llm.ollama_url           no entry
 *   llm.prompt               no entry
 *   paths.*                  no section at all
 *   linux.gestures           a DRIVER-NAMESPACED silo, the exact shape Lot 4
 *   linux.action_parameters  dissolved for [ahk.*] and [hs.*]
 *
 * So adding `linux` to existing features would not have fixed it: most of the
 * keys do not exist, and one of them duplicates a canonical key under another
 * name. That is why this counts SURFACES rather than tokens.
 *
 * HOW THE SURFACE IS FOUND: the writers go through a batch_write of
 * `{ section = "…", key = "…" }` rows, and the readers through
 * `storage.get("section.key")` / `default_for("section.key")`. Both shapes are
 * literal by construction — a driver that computed a section name at runtime
 * would be unable to declare it either.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const assert = require('node:assert/strict');
const path = require('path');
const { parse: parseToml } = require('smol-toml');
const { normalizeScopes } = require('../lib/configuration-scopes.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS_DIR = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(DRIVERS_DIR, '_shared', 'modules', 'features', 'manifest.toml');

// Frozen baseline — config surfaces a driver touches that the manifest does not
// declare for it. Drive to zero; NEVER raise.
// History: 11 (2026-08-02, first measurement. Ten are Linux; the eleventh is
//            macOS — ui/onboarding/init.lua persists [hotstrings] enabled,
//            a key the manifest has never declared, and its own comment says
//            so: "use_ergopti → [hotstrings].enabled". The wizard writes a
//            setting with no default, no type and no menu row.)
// 2026-09-28: 11 -> 7 after recognizing declared dynamic namespaces. Keep
// the measured floor tight: four corrected false positives are not new slack.
// 2026-09-28: 7 -> 5 after reading the scope-owned hotstring namespaces.
// 2026-09-29: 5 -> 3 once the setup wizard wrote catalogue paths only: the
// Linux [hotstrings] enabled answer and [script] onboarding_done are gone.
const BASELINE = 3;

const PLATFORM_OF_DRIVER = { windows: 'ahk', macos: 'hs', linux: 'linux' };

/**
 * Parses the manifest into the set of "section.key" paths declared per platform,
 * plus the set of declared section names.
 * @returns {{keys: Map<string, Set<string>>, sections: Map<string, Set<string>>}}
 */
function parseManifest() {
	const lines = fs.readFileSync(MANIFEST, 'utf8').split(/\r?\n/);
	const sectionPlatforms = new Map();
	const keys = new Map();

	let table = null;
	let entry = null;
	for (const line of lines) {
		const sec = line.match(/^\[sections\.([A-Za-z0-9_.]+)\]\s*$/);
		if (sec) {
			table = { kind: 'section', name: sec[1] };
			entry = null;
			continue;
		}
		const arr = line.match(/^\[\[features\.([A-Za-z0-9_.]+)\]\]\s*$/);
		if (arr) {
			table = { kind: 'features', name: arr[1] };
			entry = { id: null, platforms: null };
			if (!keys.has(arr[1])) keys.set(arr[1], []);
			keys.get(arr[1]).push(entry);
			continue;
		}
		if (/^\[/.test(line)) {
			table = null;
			entry = null;
			continue;
		}
		if (!table) continue;
		const p = line.match(/^platforms\s*=\s*\[(.*)\]/);
		const plats = p
			? p[1]
					.replace(/["'\s]/g, '')
					.split(',')
					.filter(Boolean)
			: null;
		if (table.kind === 'section' && plats && !sectionPlatforms.has(table.name)) {
			sectionPlatforms.set(table.name, new Set(plats));
		}
		if (table.kind === 'features' && entry) {
			const id = line.match(/^id\s*=\s*"([^"]+)"/);
			if (id) entry.id = id[1];
			if (plats) entry.platforms = new Set(plats);
		}
	}

	// Effective platform set per "section.key".
	const declared = new Map(); // platform -> Set of "section.key" and "section"
	for (const [platform] of Object.entries(PLATFORM_OF_DRIVER).map(([, v]) => [v])) {
		declared.set(platform, new Set());
	}
	for (const [section, plats] of sectionPlatforms) {
		for (const p of plats) declared.get(p)?.add(section);
	}
	for (const [section, entries] of keys) {
		for (const e of entries) {
			if (!e.id) continue;
			const eff = e.platforms || sectionPlatforms.get(section) || new Set();
			for (const p of eff) declared.get(p)?.add(`${section}.${e.id}`);
		}
	}
	return declared;
}

/**
 * Reads literal paths and marks a dotted prefix only when Lua concatenates it.
 * A computed suffix is checked as a namespace, never as a literal empty key.
 * @param {string} source - Driver source text.
 * @returns {string[]} Literal paths or dynamic namespace patterns.
 */
function configReadSurfaces(source) {
	return [
		...source.matchAll(
			/(?:storage\.(?:get|set)|default_for|find_entry_by_path)\(\s*"([A-Za-z0-9_]+\.[A-Za-z0-9_.]+)"(\s*\.\.)?/g
		)
	].map((match) => (match[2] && match[1].endsWith('.') ? match[1] + '*' : match[1]));
}

/**
 * A dynamic namespace needs a platform child or a typed scope declaration.
 * Runtime suffix validity still belongs to the manifest lookup owner.
 * @param {string} surface - Extracted config surface.
 * @param {Set<string>} known - Paths declared for one platform.
 * @param {object[]} dynamic - Typed scope namespaces with exact depth and suffix.
 * @returns {boolean} Whether the manifest owns the surface.
 */
function isDeclaredSurface(surface, known, dynamic = []) {
	const wildcard = surface.endsWith('.*');
	if (!wildcard && known.has(surface)) return true;
	if (wildcard) {
		const prefix = surface.slice(0, -1);
		if ([...known].some((key) => key.startsWith(prefix) && key.length > prefix.length)) return true;
	}
	return dynamic.some((definition) => {
		const fixed = wildcard ? surface.slice(0, -2) : surface;
		// A runtime-key writer exposes its bare table. A typed, one-leaf
		// namespace owns that table only with platform declaration evidence.
		if (!wildcard && fixed === definition.prefix) {
			return (
				definition.depth === 1 &&
				!definition.suffix &&
				['boolean', 'string', 'integer', 'number', 'array'].includes(definition.type) &&
				[...known].some((key) => key.startsWith(fixed + '.') && key.length > fixed.length + 1)
			);
		}
		if (wildcard && fixed === definition.prefix) return true;
		if (!fixed.startsWith(definition.prefix + '.')) return false;
		const tail = fixed.slice(definition.prefix.length + 1).split('.');
		if (tail.some((part) => part === '')) return false;
		if (wildcard) return tail.length < definition.depth;
		return (
			tail.length === definition.depth && (!definition.suffix || tail.at(-1) === definition.suffix)
		);
	});
}

// Regression oracles: concatenation is a namespace, but a literal trailing dot,
// unknown child, similarly named section or wrong platform is never exempted.
assert.deepEqual(configReadSurfaces('Manifest.default_for("shortcuts.keys." .. name)'), [
	'shortcuts.keys.*'
]);
assert.deepEqual(configReadSurfaces('Manifest.default_for("shortcuts.keys.")'), [
	'shortcuts.keys.'
]);
const declaredProbe = new Set(['shortcuts.keys.ctrl_s']);
assert.equal(isDeclaredSurface('shortcuts.keys.*', declaredProbe), true);
assert.equal(isDeclaredSurface('shortcuts.keys.', declaredProbe), false);
assert.equal(isDeclaredSurface('shortcuts.keys.unknown', declaredProbe), false);
assert.equal(isDeclaredSurface('shortcuts.key.*', declaredProbe), false);
assert.equal(isDeclaredSurface('shortcuts.keys.*', new Set()), false);
const dynamicProbe = [
	{ prefix: 'hotstrings.modules', depth: 2 },
	{ prefix: 'llm.profiles.shortcuts', depth: 2, suffix: 'key' }
];
assert.equal(isDeclaredSurface('hotstrings.modules.*', new Set(), dynamicProbe), true);
assert.equal(isDeclaredSurface('hotstrings.modules.rolls.hc', new Set(), dynamicProbe), true);
assert.equal(isDeclaredSurface('hotstrings.modules.rolls.*', new Set(), dynamicProbe), true);
for (const unknown of [
	'hotstrings.module.*',
	'hotstrings.modules.rolls',
	'hotstrings.modules.rolls.hc.extra',
	'hotstrings.modules..hc',
	'llm.profiles.shortcuts.profile.unknown',
	'llm.profiles.shortcuts.profile.key.*'
]) {
	assert.equal(isDeclaredSurface(unknown, new Set(), dynamicProbe), false, unknown);
}
assert.equal(
	isDeclaredSurface('llm.profiles.shortcuts.profile.key', new Set(), dynamicProbe),
	true
);

const keyboardNamespace = [{ prefix: 'shortcuts.keyboard', depth: 1, type: 'string' }];
const keyboardPlatform = new Set(['shortcuts.keyboard.magic_editor']);
assert.equal(isDeclaredSurface('shortcuts.keyboard', keyboardPlatform, keyboardNamespace), true);
for (const surface of [
	'shortcuts.keyboards',
	'shortcuts.keyboard.unknown.extra',
	'shortcuts.keyboard.'
]) {
	assert.equal(isDeclaredSurface(surface, keyboardPlatform, keyboardNamespace), false, surface);
}
for (const definitions of [
	[],
	[{ ...keyboardNamespace[0], depth: 2 }],
	[{ prefix: 'shortcuts.keyboard', depth: 1 }],
	[{ ...keyboardNamespace[0], type: 'unknown' }],
	[{ ...keyboardNamespace[0], suffix: 'key' }]
]) {
	assert.equal(isDeclaredSurface('shortcuts.keyboard', keyboardPlatform, definitions), false);
}
assert.equal(isDeclaredSurface('shortcuts.keyboard', new Set(), keyboardNamespace), false);
assert.equal(
	isDeclaredSurface(
		'shortcuts.keyboard',
		new Set(['shortcuts.keyboards.magic_editor']),
		keyboardNamespace
	),
	false
);

/**
 * Projects one binding owner's physical transport onto typed scope policy.
 * Other writers and neighbouring keys do not inherit this ownership proof.
 * @param {string} driver Driver name.
 * @param {string} relative Driver-relative writer path.
 * @param {string} source Exact writer source.
 * @param {string} surface Extracted runtime-key table.
 * @param {number} offset Extracted row offset.
 * @param {object} scopes Normalized shared scope declarations.
 * @param {object} actions Shared action declarations.
 * @param {string} storageOwner Exact Linux parameter loader/writer source.
 * @returns {boolean} Whether this row has declared canonical ownership.
 */
function isCanonicalParameterWrite(
	driver,
	relative,
	source,
	surface,
	offset,
	scopes,
	actions,
	storageOwner
) {
	if (
		driver !== 'linux' ||
		relative !== 'infra/program_binding_transaction.lua' ||
		surface !== 'gesture_parameters'
	)
		return false;
	const action = actions?.run_program;
	if (action?.parameter !== 'program' || !['all', 'linux'].includes(action.platform)) return false;
	const owned = (scope, domain) =>
		scopes[scope]?.action_parameters?.restore === 'remove' &&
		Array.isArray(scopes[scope].action_parameters.domains) &&
		scopes[scope].action_parameters.domains.includes(domain);
	if (
		!owned('gestures', 'gesture') ||
		!['keyboard', 'script', 'tap_key'].every((domain) => owned('shortcuts', domain))
	)
		return false;
	const constructor = /^function M\.new\(options\)\r?\n[\s\S]*?^end\b/m.exec(source);
	if (!constructor) return false;
	const body = constructor[0];
	const row =
		/section\s*=\s*"gesture_parameters"\s*,\s*key\s*=\s*binding\s*\.\.\s*"__run_program"\s*,\s*value\s*=\s*options\.scalar/.exec(
			body
		);
	if (!row || constructor.index + row.index !== offset) return false;
	const families = /local families = \{([\s\S]*?)\n\t\}/.exec(body);
	const declaredFamilies =
		families &&
		[...families[1].matchAll(/\{ "([a-z_]+)__", "([a-z_.]+)", "([a-z_.]+)" \}/g)]
			.map((match) => match.slice(1).join(':'))
			.sort();
	if (
		!declaredFamilies ||
		JSON.stringify(declaredFamilies) !==
			JSON.stringify([
				'keyboard:shortcuts.keyboard:modules.shortcuts.keyboard_shortcuts',
				'script:shortcuts.script_control:modules.shortcuts.script_chords',
				'tap_key:shortcuts.tap_keys:modules.shortcuts.tap_keys'
			])
	)
		return false;
	return (
		/local parameters = options\.parameters or require\("modules\.gestures\.manager"\)/.test(
			body
		) &&
		/parameters\.DEFAULT_GESTURES\[binding\] ~= nil/.test(body) &&
		/provider\.configuration_domain\(binding\) == nil/.test(body) &&
		/parameters\.validate_action_parameter\("run_program", options\.scalar\) == true/.test(body) &&
		/Transaction\.new\(\{ path = options\.path/.test(body) &&
		/operations = updates, presets = \{\}/.test(body) &&
		/transaction\.apply\("program_binding", "configured"\)/.test(body) &&
		/require\("infra\.config_paths"\)\.config\("config\.toml"\)/.test(source) &&
		/_current = M\.new\(\{ path = path,/.test(source) &&
		/local CONFIG_SECTION_PARAMS = "gesture_parameters"/.test(storageOwner) &&
		/section = CONFIG_SECTION_PARAMS, key = key, value = value/.test(storageOwner) &&
		/walk_params\(CONFIG_SECTION_PARAMS, config\[CONFIG_SECTION_PARAMS\]\)/.test(storageOwner) &&
		/for action_name in pairs\(M\.ACTION_PARAMETER_SPECS\)/.test(storageOwner) &&
		/for action_name, meta in pairs\(Catalogue\.actions\)/.test(storageOwner) &&
		/M\.ACTION_PARAMETER_SPECS\[action_name\] = meta\.parameter/.test(storageOwner)
	);
}

/**
 * Verifies the shared recovery owner's actual conditional-writer argument route.
 * Only the internal mutation proofs inject another source root; production always
 * reads the helper shipped beside the driver, and missing source grants no claim.
 * @param {string} sourceRoot ErgoptiPlus source directory.
 * @returns {boolean} Whether the exact helper retains the publication route.
 */
function hasSecondaryRecoveryTransport(sourceRoot) {
	const helperPath = path.join(sourceRoot, '_shared/lua/hotstrings/publication_recovery.lua');
	if (!fs.existsSync(helperPath)) return false;
	const helper = fs.readFileSync(helperPath, 'utf8');
	const constructor = /^function M\.new\(options\)\r?\n[\s\S]*?^end\b/m.exec(helper);
	if (!constructor) return false;
	const body = constructor[0];
	const publish =
		/^\tlocal function publish\(path, candidate, adapter, expected, on_error, publisher\)\r?\n[\s\S]*?^\tend\b/m.exec(
			body
		);
	const inverse = /^\tlocal function settle_pending\(\)\r?\n[\s\S]*?^\tend\b/m.exec(body);
	if (!publish || !inverse) return false;
	return (
		/^local function copy_source\(source\)\r?\n\s*return \{ status = source\.status, content = source\.content \}\s*\r?\nend\b/m.test(
			helper
		) &&
		/^\tlocal files = options\.files\s*$/m.test(body) &&
		/^\tlocal writer = options\.writer or require\("toml_codec\.writer"\)\s*$/m.test(body) &&
		/adapter ~= files/.test(publish[0]) &&
		/local record = \{ path = path, candidate = candidate, expected = copy_source\(expected\),\s+on_error = on_error, attempt = attempt, publisher = publisher or writer\.publish_if_unchanged \}/.test(
			publish[0]
		) &&
		/^\t\tlocal called, acknowledged, detail, native = pcall\(record\.publisher,\s+path, candidate, files, record\.expected, on_error\)/m.test(
			publish[0]
		) &&
		/inverse = \{ path = record\.path, expected = copy_source\(view\.source\),\s+candidate = record\.expected\.content, on_error = record\.on_error, attempt = record\.attempt \}/.test(
			inverse[0]
		) &&
		/^\t\tlocal called, acknowledged, detail, native = pcall\(record\.publisher,\s+inverse\.path, inverse\.candidate, files, inverse\.expected, inverse\.on_error\)/m.test(
			inverse[0]
		) &&
		/return \{ begin = begin, finish = finish, publish = publish, retry = retry,/.test(body)
	);
}

/**
 * Recognizes one exact secondary-file writer, not a globally exempt config key.
 * The row must belong to its preparation function and retain its override-path
 * publication chain. A different owner, function, key or destination is scanned.
 * @param {string} driver - Driver directory name.
 * @param {string} relative - Source path relative to the driver.
 * @param {string} source - Complete source text.
 * @param {string} surface - Literal section/key pair.
 * @param {number} offset - Row offset in the source.
 * @param {string} sourceRoot - Actual helper source root; injected only by internal proofs.
 * @returns {boolean} Whether the secondary override owner handles this row.
 */
function isSecondaryWrite(driver, relative, source, surface, offset, sourceRoot = DRIVERS_DIR) {
	if (
		driver !== 'macos' ||
		relative !== 'modules/hotstrings/hotstrings_config.lua' ||
		surface !== '__global__.word_delimiters'
	)
		return false;
	const prepare =
		/^local function prepare_override_content\(overrides, word_delimiters\)\r?\n[\s\S]*?^end\b/gm.exec(
			source
		);
	const save =
		/^local function save_to_disk\(overrides, word_delimiters\)\r?\n[\s\S]*?^end\b/gm.exec(source);
	const init = /^function M\.init\(opts\)\r?\n[\s\S]*?^end\b/gm.exec(source);
	if (
		!prepare ||
		!save ||
		!init ||
		offset < prepare.index ||
		offset >= prepare.index + prepare[0].length
	)
		return false;
	const row = /section\s*=\s*"__global__"\s*,\s*key\s*=\s*"word_delimiters"/.exec(prepare[0]);
	if (!row || prepare.index + row.index !== offset) return false;
	const directPublication =
		/^\tlocal function publish\(\)\r?\n\s*return FileSystem\.write_if_unchanged\(_state\.path, content, _state\.source_snapshot\) == true\s*\r?\n\tend\b/m.test(
			save[0]
		);
	const recoveryPublication =
		/^local FileSystem\s*= require\("adapters\.file_system"\)\s*$/m.test(source) &&
		/^local PublicationRecovery = require\("hotstrings\.publication_recovery"\)\s*$/m.test(
			source
		) &&
		/^local function publish_native_override\(path, content, files, expected, on_error\)\r?\n\s*return files\.write_if_unchanged\(path, content, expected, on_error\)\s*\r?\nend\b/m.test(
			source
		) &&
		/^\tlocal function publish\(\)\r?\n\s*return _state\.recovery\.publish\(_state\.path, content, FileSystem,\s*_state\.source_snapshot, _state\.on_publication_error, publish_native_override\)\s*\r?\n\tend\b/m.test(
			save[0]
		) &&
		/^\tlocal state = _state\s*$/m.test(init[0]) &&
		/state\.recovery = PublicationRecovery\.new\(\{ files = FileSystem,\s*capture = function\(\) return capture_publication_owner\(state\) end,\s*current = publication_owner_current \}\)/.test(
			init[0]
		) &&
		/_state\.source_snapshot = source_snapshot/.test(init[0]) &&
		hasSecondaryRecoveryTransport(sourceRoot);
	return (
		/local snapshot = _state\.source_snapshot/.test(prepare[0]) &&
		/TomlRecordEditor\.patch_table_field\(content,/.test(prepare[0]) &&
		/local prepared, prepare_error = prepare_override_content\(overrides, word_delimiters\)/.test(
			save[0]
		) &&
		/content = prepared/.test(save[0]) &&
		(directPublication || recoveryPublication) &&
		/parse_overrides\(opts\.override_path\)/.test(init[0]) &&
		/path\s*= opts\.override_path/.test(init[0])
	);
}

// The production bootstrap binds this owner to its secondary TOML file.
// Redirecting that owner to config.toml must fail the gate too.
const secondaryBootstrap = fs.readFileSync(path.join(DRIVERS_DIR, 'macos', 'init.lua'), 'utf8');
const secondaryDestination =
	/override_path = override_path \.\. "hotstrings_config\.toml"\s+local hotstring_config_ready = hotstrings_config\.init\(\{\s+override_path = override_path,/;
assert.equal(
	secondaryDestination.test(secondaryBootstrap),
	true,
	'override owner must target its secondary file'
);
assert.equal(
	secondaryDestination.test(
		secondaryBootstrap.replace('"hotstrings_config.toml"', '"config.toml"')
	),
	false
);

// The secondary-file exclusion is tied to the actual preparation/publication
// chain. Neither another writer nor an undeclared neighbouring leaf inherits it.
const secondaryOwner = 'modules/hotstrings/hotstrings_config.lua';
const secondarySource = fs.readFileSync(path.join(DRIVERS_DIR, 'macos', secondaryOwner), 'utf8');
const secondaryRow = /section\s*=\s*"__global__"\s*,\s*key\s*=\s*"word_delimiters"/.exec(
	secondarySource
);
assert.ok(secondaryRow, 'secondary owner must still expose the literal row under test');
assert.equal(
	isSecondaryWrite(
		'macos',
		secondaryOwner,
		secondarySource,
		'__global__.word_delimiters',
		secondaryRow.index
	),
	true
);
assert.equal(
	isSecondaryWrite(
		'macos',
		'infra/config.lua',
		secondarySource,
		'__global__.word_delimiters',
		secondaryRow.index
	),
	false
);
assert.equal(
	isSecondaryWrite(
		'linux',
		secondaryOwner,
		secondarySource,
		'__global__.word_delimiters',
		secondaryRow.index
	),
	false
);
assert.equal(
	isSecondaryWrite(
		'macos',
		secondaryOwner,
		secondarySource,
		'__global__.unknown',
		secondaryRow.index
	),
	false
);
for (const offset of [0, secondaryRow.index + 1]) {
	assert.equal(
		isSecondaryWrite(
			'macos',
			secondaryOwner,
			secondarySource,
			'__global__.word_delimiters',
			offset
		),
		false,
		'only the exact literal preparation row inherits secondary ownership'
	);
}
const secondaryPublicationCall =
	/(?:FileSystem\.write_if_unchanged\(_state\.path,\s*content,\s*_state\.source_snapshot\)|_state\.recovery\.publish\(_state\.path,\s*content,\s*FileSystem,\s*_state\.source_snapshot,\s*_state\.on_publication_error,\s*publish_native_override\))/.exec(
		secondarySource
	);
assert.ok(secondaryPublicationCall, 'the actual secondary publication route must exist');
for (const [before, after] of [
	['_state.path', 'config_path'],
	['_state.source_snapshot', 'other_source_snapshot']
]) {
	const changedCall = secondaryPublicationCall[0].replace(before, after);
	const changedSource = secondarySource.replace(secondaryPublicationCall[0], changedCall);
	assert.notEqual(
		changedCall,
		secondaryPublicationCall[0],
		'publication mutation must change arguments'
	);
	assert.notEqual(changedSource, secondarySource, 'publication mutation must change actual source');
	assert.equal(
		isSecondaryWrite(
			'macos',
			secondaryOwner,
			changedSource,
			'__global__.word_delimiters',
			secondaryRow.index
		),
		false,
		'a different destination or expected source never inherits secondary ownership'
	);
}

/**
 * Every "section.key" (or bare section) a driver's own source reads or writes.
 * @param {string} driver - Driver directory name.
 * @returns {Set<string>} Config surfaces, as written in the source.
 */
function surfaceOf(driver) {
	const out = new Set();
	const root = path.join(DRIVERS_DIR, driver);
	(function walk(dir) {
		if (!fs.existsSync(dir)) return;
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (e.name === 'tests' || e.name === '_generated' || e.name === 'vendor') continue;
				walk(p);
				continue;
			}
			if (!/\.(lua|ahk)$/.test(e.name)) continue;
			const src = fs.readFileSync(p, 'utf8');
			// batch_write rows: { section = "x", key = "y" }
			for (const m of src.matchAll(
				/section\s*=\s*"([A-Za-z0-9_.]+)"\s*,\s*key\s*=\s*"([A-Za-z0-9_.]+)"/g
			)) {
				const surface = `${m[1]}.${m[2]}`;
				const relative = path.relative(root, p).split(path.sep).join('/');
				if (!isSecondaryWrite(driver, relative, src, surface, m.index)) out.add(surface);
			}
			// A row whose key is a runtime value still names its section.
			for (const m of src.matchAll(/section\s*=\s*"([A-Za-z0-9_.]+)"\s*,\s*key\s*=\s*[A-Za-z_]/g)) {
				const relative = path.relative(root, p).split(path.sep).join('/');
				if (
					isCanonicalParameterWrite(
						driver,
						relative,
						src,
						m[1],
						m.index,
						scopes,
						actions,
						parameterStorageOwner
					)
				)
					continue;
				out.add(m[1]);
			}
			// storage.get("section.key") / default_for("section.key")
			for (const surface of configReadSurfaces(src)) out.add(surface);
			// Windows boot-owned scalar reads. These bypass the manifest-backed
			// Features tree, so omitting them made a real config surface invisible
			// to this ratchet.
			for (const m of src.matchAll(
				/_FeatureStateIniGet\(\s*[^,]+,\s*"([A-Za-z0-9_.]+)"\s*,\s*"([A-Za-z0-9_.]+)"/g
			)) {
				out.add(`${m[1]}.${m[2]}`);
			}
			// The [linux.*] silo is read as a TABLE, not key by key, so no pattern
			// above reaches it — and a silo nobody can see is how it survived the
			// migration that dissolved [ahk.*] and [hs.*].
			for (const m of src.matchAll(/\blinux\.(gestures|action_parameters)\b/g)) {
				out.add(`linux.${m[1]}`);
			}
		}
	})(root);
	return out;
}

const declared = parseManifest();
const scopes = normalizeScopes(parseToml(fs.readFileSync(MANIFEST, 'utf8')).scopes);
const dynamic = Object.values(scopes).flatMap((scope) => scope.dynamic_defaults || []);
assert.ok(dynamic.length > 0, 'the scope registry must declare dynamic defaults');
const actions = parseToml(
	fs.readFileSync(path.join(DRIVERS_DIR, '_shared/modules/actions/actions.toml'), 'utf8')
).sg_actions;
const parameterStorageOwner = fs.readFileSync(
	path.join(DRIVERS_DIR, 'linux/modules/gestures/manager.lua'),
	'utf8'
);
const parameterWriterPath = 'infra/program_binding_transaction.lua';
const parameterWriter = fs.readFileSync(
	path.join(DRIVERS_DIR, 'linux', parameterWriterPath),
	'utf8'
);
const parameterRow = /section\s*=\s*"gesture_parameters"\s*,\s*key\s*=\s*binding/.exec(
	parameterWriter
);
assert.ok(parameterRow, 'canonical owner must still expose its physical transport row');
const parameterDeclared = (overrides = {}) => {
	const source = overrides.source ?? parameterWriter;
	const row = /section\s*=\s*"[A-Za-z0-9_.]+"\s*,\s*key\s*=\s*binding/.exec(source);
	return isCanonicalParameterWrite(
		overrides.driver ?? 'linux',
		overrides.relative ?? parameterWriterPath,
		source,
		overrides.surface ?? 'gesture_parameters',
		overrides.offset ?? row?.index ?? parameterRow.index,
		overrides.scopes ?? scopes,
		overrides.actions ?? actions,
		overrides.storageOwner ?? parameterStorageOwner
	);
};
assert.equal(
	parameterDeclared(),
	true,
	'typed shared policy owns the actual canonical parameter writer'
);
for (const overrides of [
	{ driver: 'macos' },
	{ relative: 'infra/another_writer.lua' },
	{ offset: 0 },
	{ surface: 'gesture_parameter' },
	{ surface: 'gesture_parameters.child' },
	{
		source: parameterWriter.replace(
			'section = "gesture_parameters"',
			'section = "unowned_parameters"'
		)
	},
	{ source: parameterWriter.replace('binding .. "__run_program"', 'binding .. "__unknown"') },
	{ source: parameterWriter.replace('provider.configuration_domain(binding) == nil', 'false') },
	{
		source: parameterWriter.replace(
			'parameters.validate_action_parameter("run_program", options.scalar) == true',
			'true'
		)
	},
	{ source: parameterWriter.replace('"shortcuts.keyboard"', '"shortcuts.keyboards"') },
	{ source: parameterWriter.replace('config("config.toml")', 'config("other.toml")') },
	{
		storageOwner: parameterStorageOwner.replace(
			'local CONFIG_SECTION_PARAMS = "gesture_parameters"',
			'local CONFIG_SECTION_PARAMS = "other_parameters"'
		)
	},
	{
		storageOwner: parameterStorageOwner.replace(
			'M.ACTION_PARAMETER_SPECS[action_name] = meta.parameter',
			'M.ACTION_PARAMETER_SPECS[action_name] = "unowned"'
		)
	},
	{ actions: {} },
	{ actions: { ...actions, run_program: { ...actions.run_program, parameter: 'text' } } },
	{ actions: { ...actions, run_program: { ...actions.run_program, platform: 'hs' } } }
])
	assert.equal(
		parameterDeclared(overrides),
		false,
		'unowned parameter transport is never exempted'
	);
for (const [scope, domain] of [
	['gestures', 'gesture'],
	['shortcuts', 'keyboard'],
	['shortcuts', 'script'],
	['shortcuts', 'tap_key']
]) {
	const missing = structuredClone(scopes);
	delete missing[scope].action_parameters;
	assert.equal(parameterDeclared({ scopes: missing }), false, `${scope} declaration is required`);
	const wrongDomain = structuredClone(scopes);
	wrongDomain[scope].action_parameters.domains = wrongDomain[
		scope
	].action_parameters.domains.filter((entry) => entry !== domain);
	assert.equal(
		parameterDeclared({ scopes: wrongDomain }),
		false,
		`${domain} ownership is required`
	);
	const wrongPolicy = structuredClone(scopes);
	wrongPolicy[scope].action_parameters.restore = 'retain';
	assert.equal(parameterDeclared({ scopes: wrongPolicy }), false, `${scope} policy is required`);
}
const DRIVERS = Object.keys(PLATFORM_OF_DRIVER).filter((d) =>
	fs.existsSync(path.join(DRIVERS_DIR, d, 'adapters'))
);

const undeclared = [];
for (const driver of DRIVERS) {
	const platform = PLATFORM_OF_DRIVER[driver];
	const known = declared.get(platform) || new Set();
	for (const surface of [...surfaceOf(driver)].sort()) {
		if (isDeclaredSurface(surface, known, dynamic)) continue;
		// A key is covered when its own section is declared AND the key is too;
		// a bare section is covered by the section alone.
		undeclared.push({ driver, platform, surface });
	}
}

if (process.argv.includes('--measure')) {
	console.log(`drivers: ${DRIVERS.join(', ')}`);
	console.log(`\nundeclared config surfaces: ${undeclared.length}`);
	for (const u of undeclared) console.log(`  ${u.driver.padEnd(8)} ${u.surface}`);
	process.exit(0);
}

if (undeclared.length > BASELINE) {
	console.error(
		`\x1b[31m[ERROR] Undeclared driver config surfaces rose to ${undeclared.length} (baseline ${BASELINE}).\x1b[0m`
	);
	for (const u of undeclared) console.error(`  ${u.driver.padEnd(8)} ${u.surface}`);
	console.error(
		'\n  A config key the driver persists but the manifest has never heard of has no\n' +
			'  default, no type, no schema entry and no menu row — it is invisible to every\n' +
			'  gate in this repo. Declare it in manifest.toml with the right platforms, or\n' +
			'  point the driver at the canonical key that already means the same thing.\n' +
			'  Do NOT raise the baseline.'
	);
	console.error(
		'  Run `node tools/test/test-driver-config-surface-is-declared.cjs --measure` to list them.'
	);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Driver config surfaces declared in the manifest (${undeclared.length}/${BASELINE} undeclared).\x1b[0m`
);
