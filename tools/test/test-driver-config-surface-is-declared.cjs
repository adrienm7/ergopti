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
const { stripComments, scriptTokens } = require('../lib/script-source.cjs');

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
function parseManifest(source = fs.readFileSync(MANIFEST, 'utf8')) {
	const lines = source.split(/\r?\n/);
	const records =
		parseToml(
			source.replace(
				/^\[\[features\.([^\]]+)\]\]$/gm,
				(_header, section) => `[[declarations]]\nsection_path = "${section}"`
			)
		).declarations || [];
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
			const record = records.find((value) => value.section_path === section && value.id === e.id);
			const fields =
				record?.type === 'feature'
					? new Set([
							...Object.keys(record.default || {}),
							...Object.keys(record.recommended || {})
						])
					: new Set();
			for (const p of eff) {
				declared.get(p)?.add(`${section}.${e.id}`);
				for (const field of fields) declared.get(p)?.add(`${section}.${e.id}.${field}`);
			}
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
const compositeProbe = parseManifest(`
[sections.hotstrings.dynamic]
platforms = ["hs"]
[[features.hotstrings.dynamic]]
id = "user_code"
type = "feature"
default = { enabled = false, time_activation_seconds = 0.5 }
recommended = { enabled = false, time_activation_seconds = 0.5 }
`);
for (const field of ['enabled', 'time_activation_seconds']) {
	assert.equal(
		isDeclaredSurface(`hotstrings.dynamic.user_code.${field}`, compositeProbe.get('hs')),
		true
	);
	assert.equal(
		isDeclaredSurface(`hotstrings.dynamic.user_code.${field}`, compositeProbe.get('linux')),
		false
	);
}
assert.equal(
	isDeclaredSurface('hotstrings.dynamic.user_code.arbitrary', compositeProbe.get('hs')),
	false
);
assert.equal(
	isDeclaredSurface('hotstrings.dynamic.other.enabled', compositeProbe.get('hs')),
	false
);
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

/** Keeps offsets stable while comments and multiline/long literal data stay opaque. */
function executableLua(source) {
	let result = stripComments(source, '.lua');
	for (const token of scriptTokens(source, '.lua')) {
		if (token.kind !== 'string') continue;
		const raw = source.slice(token.start, token.end);
		if (!raw.startsWith('[') && !raw.includes('\n')) continue;
		result = result.slice(0, token.start) + raw.replace(/[^\n]/g, ' ') + result.slice(token.end);
	}
	return result;
}

/** Returns only matches whose first token is executable code, preserving literal arguments. */
function executableMatches(pattern, source) {
	const starts = new Set(
		scriptTokens(source, '.lua')
			.filter((token) => token.kind !== 'string')
			.map((token) => token.start)
	);
	const flags = pattern.flags.includes('g') ? pattern.flags : pattern.flags + 'g';
	return [...source.matchAll(new RegExp(pattern.source, flags))].filter((match) =>
		starts.has(match.index)
	);
}

/** Returns one lexical code fact; this is not a flow or native-authority proof. */
function executableMatch(pattern, source) {
	return executableMatches(pattern, source)[0] || null;
}

/** Checks each fact inside the actual central constructor, rather than later quoted data. */
function canonicalParameterBuilder(source) {
	const constructor = executableMatch(
		/^function M\.action_parameter_update\(binding, action_name, value\)\r?\n[\s\S]*?^end\b/m,
		source
	);
	if (!constructor) return false;
	return [
		/M\.action_parameter_binding_fits\(binding\) == false/,
		/M\.get_action_parameter_spec\(action_name\) == nil/,
		/M\.validate_action_parameter\(action_name, value\) ~= true/,
		/return \{ section = CONFIG_SECTION_PARAMS, key = parameter_key\(binding, action_name\), value = value \}/
	].every((pattern) => executableMatch(pattern, constructor[0]));
}

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
	source = executableLua(source);
	storageOwner = executableLua(storageOwner);
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
	const constructor = executableMatch(/^function M\.new\(options\)\r?\n[\s\S]*?^end\b/m, source);
	if (!constructor) return false;
	const body = constructor[0];
	const legacyRow = executableMatch(
		/section\s*=\s*"gesture_parameters"\s*,\s*key\s*=\s*binding\s*\.\.\s*"__run_program"\s*,\s*value\s*=\s*options\.scalar/,
		body
	);
	const selectedRow = executableMatch(
		/local parameter = parameters\.action_parameter_update\(binding, action, options\.scalar\)/,
		body
	);
	const row = legacyRow || selectedRow;
	if (!row || constructor.index + row.index !== offset) return false;
	const selected = legacyRow === null;
	if (
		selected &&
		![
			/local action = options\.action == nil and "run_program" or options\.action/,
			/type\(action\) == "string"/,
			/type\(parameters\.get_action_parameter_spec\(action\)\) == "string"/,
			/parameters\.validate_action_parameter\(action, options\.scalar\) == true/,
			/type\(parameter\) == "table" and parameter\.section == "gesture_parameters"/,
			/parameter\.key == binding \.\. "__" \.\. action and parameter\.value == options\.scalar/,
			/parameter = \{ section = parameter\.section, key = parameter\.key, value = parameter\.value \}/,
			/local updates = \{\s*parameter,\s*\{ section = section, key = slot, value = action \}/,
			/scalar_state\[parameter\.key\] = parameter\.value/,
			/assignments\.assignments\[slot\] = action/,
			/assignments\.explicit_assignments\[slot\] = action/,
			/assert\(section ~= "shortcuts\.keyboard" or not PhysicalSlots\.is_namespace\(slot\)/
		].every((pattern) => executableMatch(pattern, body))
	)
		return false;
	if (
		selected &&
		(!executableMatch(/local PhysicalSlots = require\("shortcuts\.physical_slots"\)/, source) ||
			!executableMatch(/function M\.apply\(binding, scalar, is_paused, action\)/, source) ||
			!executableMatch(
				/binding = binding, scalar = scalar, is_paused = is_paused, action = action/,
				source
			) ||
			!canonicalParameterBuilder(storageOwner))
	)
		return false;
	const families = executableMatch(/local families = \{([\s\S]*?)\n\t\}/, body);
	const declaredFamilies =
		families &&
		executableMatches(/\{ "([a-z_]+)__", "([a-z_.]+)", "([a-z_.]+)" \}/g, families[1])
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
	return Boolean(
		executableMatch(
			/local parameters = options\.parameters or require\("modules\.gestures\.manager"\)/,
			body
		) &&
			executableMatch(/parameters\.DEFAULT_GESTURES\[binding\] ~= nil/, body) &&
			executableMatch(/provider\.configuration_domain\(binding\) == nil/, body) &&
			(selected ||
				executableMatch(
					/parameters\.validate_action_parameter\("run_program", options\.scalar\) == true/,
					body
				)) &&
			executableMatch(/Transaction\.new\(\{ path = options\.path/, body) &&
			executableMatch(/operations = updates, presets = \{\}/, body) &&
			executableMatch(/transaction\.apply\("program_binding", "configured"\)/, body) &&
			executableMatch(/require\("infra\.config_paths"\)\.config\("config\.toml"\)/, source) &&
			executableMatch(/_current = M\.new\(\{ path = path,/, source) &&
			executableMatch(/local CONFIG_SECTION_PARAMS = "gesture_parameters"/, storageOwner) &&
			executableMatch(/section = CONFIG_SECTION_PARAMS, key = key, value = value/, storageOwner) &&
			executableMatch(
				/walk_params\(CONFIG_SECTION_PARAMS, config\[CONFIG_SECTION_PARAMS\]\)/,
				storageOwner
			) &&
			executableMatch(/for action_name in pairs\(M\.ACTION_PARAMETER_SPECS\)/, storageOwner) &&
			executableMatch(/for action_name, meta in pairs\(Catalogue\.actions\)/, storageOwner) &&
			executableMatch(/M\.ACTION_PARAMETER_SPECS\[action_name\] = meta\.parameter/, storageOwner)
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
// Retain the genuine e525 producer as literal historical morphology, not current authority.
// Its original assertion/mutation block below remains byte-exact and meaningful.
const parameterWriter = String.raw`--- infra/program_binding_transaction.lua

--- Publishes an executable parameter and its binding under exact runtime ownership.
local M = {}
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local Logger = require("logger.shim")
local LOG = "infra.program_binding_transaction"
local _current, _sequence = nil, 0
local _constructing = false

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}; for key, child in pairs(value) do out[key] = copy(child) end
	return out
end

local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

--- Builds a conditional publication using existing preference and dispatch owners.
--- @param options table Exact binding, scalar, path, backup, pause and native file ports.
--- @return table owner Apply, retained debt and explicit compensation retry.
function M.new(options)
	assert(type(options) == "table" and type(options.is_paused) == "function", "program binding requires live pause ownership")
	local parameters = options.parameters or require("modules.gestures.manager")
	local binding, slot, section, provider = options.binding
	local families = {
		{ "keyboard__", "shortcuts.keyboard", "modules.shortcuts.keyboard_shortcuts" },
		{ "tap_key__", "shortcuts.tap_keys", "modules.shortcuts.tap_keys" },
		{ "script__", "shortcuts.script_control", "modules.shortcuts.script_chords" },
	}
	if type(binding) == "string" and parameters.DEFAULT_GESTURES[binding] ~= nil then
		slot, section = binding, "gestures"
	else
		for _, family in ipairs(families) do
			if type(binding) == "string" and binding:sub(1, #family[1]) == family[1] then
				provider = require(family[3])
				if provider.configuration_domain(binding) == nil then break end
				slot, section = binding:sub(#family[1] + 1), family[2]
				break
			end
		end
	end
	assert(type(slot) == "string" and parameters.validate_action_parameter("run_program", options.scalar) == true,
		"program binding model is invalid")
	local owner, held, retiring, busy = {}, {}, false, false
	local files = options.files or require("adapters.file_system")
	local checkpoint, reconcile_pending, inverse_source = nil, false, nil
	local ports = { { acquire = parameters.acquire_parameter_configuration, release = parameters.release_parameter_configuration,
		snapshot = function()
			local values = parameters.parameter_configuration_snapshot(owner)
			local actions = parameters.parameter_configuration_actions_snapshot(owner)
			if type(values) ~= "table" or type(actions) ~= "table" then return nil end
			return { parameters = values, actions = actions }
		end } }
	if provider then ports[#ports + 1] = { acquire = provider.acquire_configuration, release = provider.release_configuration,
		snapshot = function() return provider.configuration_snapshot(owner) end } end
	local function read_source()
		local content, status = Writer.read_classified(options.path, files)
		if status ~= "ok" and status ~= "absent" then return nil end
		return { status = status, content = status == "ok" and content or nil }
	end
	local function capture_release()
		if checkpoint ~= nil then return true end
		local source = read_source()
		if source == nil or (inverse_source ~= nil and not equal(source, inverse_source)) then return false end
		local snapshots = {}
		for index, port in ipairs(held) do
			local called, state = pcall(port.snapshot)
			if not called or type(state) ~= "table" then return false end
			snapshots[index] = state
		end
		checkpoint = { source = source, snapshots = snapshots }
		return true
	end
	--- A refused release can mutate ownership before returning. Reacquire only
	--- the missing lease while exact canonical and full runtime checkpoints hold.
	local function reconcile()
		if not capture_release() or not equal(read_source(), checkpoint.source) then return false end
		for index, port in ipairs(held) do
			local called, state = pcall(port.snapshot)
			if not called then return false end
			if state == nil then
				if not equal(read_source(), checkpoint.source) then return false end
				local acquired, receipt = pcall(port.acquire, owner)
				if not acquired or receipt ~= true then return false end
				called, state = pcall(port.snapshot)
			end
			if not called or not equal(state, checkpoint.snapshots[index]) then return false end
		end
		if not equal(read_source(), checkpoint.source) then return false end
		reconcile_pending = false
		return true
	end
	local function release()
		if #held == 0 then return true end
		reconcile_pending = true
		if not capture_release() then return false end
		local paused = options.is_paused()
		if type(paused) ~= "boolean" or parameters.set_program_paused(paused) ~= true
			or not equal(read_source(), checkpoint.source) then return false end
		for index = #held, 1, -1 do
			local called, receipt = pcall(held[index].release, owner)
			if not called or receipt ~= true then return false end
		end
		held, checkpoint, reconcile_pending = {}, nil, false
		return true
	end
	local function assignment_snapshot()
		if provider then return provider.configuration_snapshot(owner) end
		local actions = parameters.parameter_configuration_actions_snapshot(owner)
		return type(actions) == "table" and { assignments = actions } or nil
	end
	local function apply_assignments(state)
		if provider then return provider.apply_configuration(owner, state) == true end
		return parameters.apply_parameter_configuration_actions(owner, state.assignments) == true
	end
	local updates = {
		{ section = "gesture_parameters", key = binding .. "__run_program", value = options.scalar },
		{ section = section, key = slot, value = "run_program" },
	}
	local transaction = Transaction.new({ path = options.path, backup_path = options.backup_path,
		files = files,
		manifest = { scope_plan = function() return { operations = updates, presets = {} } end },
		capture = function()
			local scalar_state = parameters.parameter_configuration_snapshot(owner)
			local assignments = assignment_snapshot()
			if type(scalar_state) ~= "table" or type(assignments) ~= "table" then return nil end
			return { parameters = scalar_state, assignments = assignments }
		end,
		apply = function()
			if options.is_paused() then return false end
			local scalar_state = parameters.parameter_configuration_snapshot(owner)
			local assignments = assignment_snapshot()
			if type(scalar_state) ~= "table" or type(assignments) ~= "table" then return false end
			scalar_state[binding .. "__run_program"] = options.scalar
			assignments = copy(assignments)
			assignments.assignments[slot] = "run_program"
			if assignments.explicit_assignments then assignments.explicit_assignments[slot] = "run_program" end
			return parameters.apply_parameter_configuration(owner, scalar_state) == true and apply_assignments(assignments)
		end,
		restore = function(snapshot)
			return parameters.apply_parameter_configuration(owner, snapshot.parameters) == true
				and apply_assignments(snapshot.assignments)
		end,
	})
	function owner.pending() return #held > 0 or transaction.pending() or retiring or busy end
	local function recover()
		if retiring then
			if parameters.stop_programs() ~= true then return false end
			retiring = false
		end
		if reconcile_pending and not reconcile() then return false end
		if transaction.committed() then
			if transaction.revert() ~= true then return false end
		elseif transaction.retry_restore() ~= true then return false end
		-- A refused eager inverse becomes shared transaction debt. Once its
		-- retry restores the original source, that source replaces the candidate
		-- checkpoint just as it does after an immediately accepted inverse.
		inverse_source = nil
		checkpoint = nil
		if release() ~= true then return false end
		transaction.release()
		return true
	end
	local function apply()
		if options.is_paused() then return false end
		for _, port in ipairs(ports) do
			local ok, receipt = pcall(port.acquire, owner)
			if not ok or receipt ~= true then release(); return false end
			held[#held + 1] = port
		end
		retiring = true
		if parameters.stop_programs() ~= true then return false end
		retiring = false
		local accepted, _, candidate = transaction.apply("program_binding", "configured")
		if transaction.pending() then return false end
		if accepted == true then inverse_source = { status = "ok", content = candidate } end
		if release() ~= true then recover(); return false end
		transaction.release()
		return accepted == true
	end
	local function guarded(operation)
		if busy then return false end
		busy = true
		local called, receipt = pcall(operation)
		busy = false
		return called and receipt == true
	end
	function owner.apply()
		if owner.pending() then return false end
		return guarded(apply)
	end
	function owner.retry_restore() return guarded(recover) end
	function owner.claimed() return busy end
	return owner
end

--- Commits one picker confirmation while retaining any refused native inverse.
--- @param binding string Canonical binding identity.
--- @param scalar string Validated executable parameter.
--- @param is_paused function Live pause getter.
--- @return boolean committed
function M.apply(binding, scalar, is_paused)
	if type(is_paused) ~= "function" or _constructing then return false end
	_constructing = true
	local ok, accepted = pcall(function()
		if _current and _current.pending() and _current.retry_restore() ~= true then return false end
		_sequence = _sequence + 1
		local path = require("infra.config_paths").config("config.toml")
		_current = M.new({ path = path, backup_path = path .. ".program-binding-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak",
			binding = binding, scalar = scalar, is_paused = is_paused })
		return _current.apply()
	end)
	_constructing = false
	if not ok or accepted ~= true then
		Logger.error(LOG, "Private user program binding publication did not commit.")
		return false
	end
	return true
end

--- Reports logical debt even when a refused release removed its physical lease.
--- @return boolean pending
function M.pending() return _constructing or (_current ~= nil and _current.pending()) end

--- Identifies the exact journal token allowed to reconcile its missing lease.
--- @param owner table Exact transaction token, never a caller-provided substitute.
--- @return boolean owned
function M.owns(owner) return owner ~= nil and _current == owner and _current.claimed() end

return M
`;
const currentParameterWriter = fs.readFileSync(
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
// Current selected-action transport has a separate positive and handwritten refusals.
const currentParameterRow =
	/local parameter = parameters\.action_parameter_update\(binding, action, options\.scalar\)/.exec(
		currentParameterWriter
	);
assert.ok(currentParameterRow, 'the actual selected-action canonical constructor must exist');
const selectedParameterDeclared = (overrides = {}) => {
	const source = overrides.source ?? currentParameterWriter;
	const row =
		/local parameter = parameters\.action_parameter_update\(binding, action, options\.scalar\)/.exec(
			source
		);
	return isCanonicalParameterWrite(
		overrides.driver ?? 'linux',
		overrides.relative ?? parameterWriterPath,
		source,
		overrides.surface ?? 'gesture_parameters',
		overrides.offset ?? row?.index ?? currentParameterRow.index,
		overrides.scopes ?? scopes,
		overrides.actions ?? actions,
		overrides.storageOwner ?? parameterStorageOwner
	);
};
assert.equal(
	selectedParameterDeclared(),
	true,
	'the actual central selected-action transport remains owned'
);
for (const [before, after] of [
	[
		'parameters.action_parameter_update(binding, action, options.scalar)',
		'parameters.action_parameter_update(binding, "run_program", options.scalar)'
	],
	['type(parameters.get_action_parameter_spec(action)) == "string"', 'true'],
	['parameters.validate_action_parameter(action, options.scalar) == true', 'true'],
	['parameter.section == "gesture_parameters"', 'parameter.section == "unowned_parameters"'],
	['parameter.key == binding .. "__" .. action', 'true'],
	['parameter.value == options.scalar', 'true'],
	[
		'parameter = { section = parameter.section, key = parameter.key, value = parameter.value }',
		'parameter = parameter'
	],
	[
		'{ section = section, key = slot, value = action }',
		'{ section = section, key = slot, value = "run_program" }'
	],
	['scalar_state[parameter.key] = parameter.value', 'scalar_state[parameter.key] = options.other'],
	['assignments.assignments[slot] = action', 'assignments.assignments[slot] = "run_program"'],
	[
		'assignments.explicit_assignments[slot] = action',
		'assignments.explicit_assignments[slot] = "run_program"'
	],
	['action = action })', 'action = "run_program" })'],
	['not PhysicalSlots.is_namespace(slot)', 'true'],
	['provider.configuration_domain(binding) == nil', 'false'],
	['config("config.toml")', 'config("other.toml")']
]) {
	assert.ok(
		currentParameterWriter.includes(before),
		'each current mutation must target actual source'
	);
	const changed = currentParameterWriter.replace(before, after);
	assert.notEqual(changed, currentParameterWriter, 'the current source mutation must change bytes');
	assert.equal(
		selectedParameterDeclared({ source: changed }),
		false,
		'unowned selected-action transport is refused'
	);
}
for (const replacement of [
	'-- local parameter = parameters.action_parameter_update(binding, action, options.scalar)',
	'local decoy = [[\nlocal parameter = parameters.action_parameter_update(binding, action, options.scalar)\n]]'
]) {
	const changed = currentParameterWriter.replace(currentParameterRow[0], replacement);
	assert.notEqual(changed, currentParameterWriter);
	assert.equal(
		selectedParameterDeclared({ source: changed }),
		false,
		'comment/literal constructor text grants no transport'
	);
}
for (const [before, after] of [
	['M.validate_action_parameter(action_name, value) ~= true', 'false'],
	['M.action_parameter_binding_fits(binding) == false', 'false'],
	['key = parameter_key(binding, action_name)', 'key = parameter_key(binding, "run_program")']
]) {
	assert.ok(parameterStorageOwner.includes(before));
	const changed = parameterStorageOwner.replace(before, after);
	assert.notEqual(changed, parameterStorageOwner);
	assert.equal(
		selectedParameterDeclared({ storageOwner: changed }),
		false,
		'the actual canonical row constructor remains required'
	);
}
for (const overrides of [
	{ driver: 'macos' },
	{ relative: 'infra/another_writer.lua' },
	{ offset: 0 },
	{ surface: 'unowned_parameters' },
	{ actions: {} }
])
	assert.equal(selectedParameterDeclared(overrides), false);
for (const [scope, domain] of [
	['gestures', 'gesture'],
	['shortcuts', 'keyboard'],
	['shortcuts', 'script'],
	['shortcuts', 'tap_key']
]) {
	const changed = structuredClone(scopes);
	changed[scope].action_parameters.domains = changed[scope].action_parameters.domains.filter(
		(entry) => entry !== domain
	);
	assert.equal(
		selectedParameterDeclared({ scopes: changed }),
		false,
		'every selected-action domain remains required'
	);
}

// Ordinary quoted values also cannot replace executable validation facts.
for (const quote of ["'", '"']) {
	const fact = 'parameters.validate_action_parameter(action, options.scalar) == true';
	const changed = currentParameterWriter
		.replace(fact, 'true')
		.replace(
			'local parameter = parameters.action_parameter_update',
			`local spoof = ${quote}${fact}${quote}\n	local parameter = parameters.action_parameter_update`
		);
	assert.notEqual(changed, currentParameterWriter);
	assert.equal(
		selectedParameterDeclared({ source: changed }),
		false,
		'single-line quoted producer facts grant no transport'
	);
	const builderFact = 'M.validate_action_parameter(action_name, value) ~= true';
	const changedBuilder = parameterStorageOwner
		.replace(builderFact, 'false')
		.replace(
			'return { section = CONFIG_SECTION_PARAMS, key = parameter_key(binding, action_name), value = value }',
			`local spoof = ${quote}${builderFact}${quote}\n	return { section = CONFIG_SECTION_PARAMS, key = parameter_key(binding, action_name), value = value }`
		);
	assert.notEqual(changedBuilder, parameterStorageOwner);
	assert.equal(
		selectedParameterDeclared({ storageOwner: changedBuilder }),
		false,
		'central constructor facts cannot come from quoted data'
	);
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
