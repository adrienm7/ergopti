// tools/test/test-defaults-single-source.cjs
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { isDeepStrictEqual } = require('node:util');
const paths = require('../lib/paths.cjs');

// Linux recommends exactly what Windows recommends (maintainer decision,
// 2026-10-22). Each exception names a Windows value Linux cannot run; the
// gate proves that reason still holds, so a stale exception fails too.
const LINUX_RECOMMENDATION_EXCEPTIONS = {
	// win_app_prev and win_app_next are absent from the Linux catalogue.
	'gestures.swipe_4_down': { linux: 'none', reason: 'windows-action-absent-on-linux' },
	'gestures.swipe_4_up': { linux: 'none', reason: 'windows-action-absent-on-linux' },
	// Linux only reports the layout's own number row (number_row_policy).
	'layout.direct_access_digits': { linux: 'native', reason: 'native-number-row-only' }
};

/**
 * Resolves the platforms of one manifest entry, inheriting from its sections.
 * @param {object} manifest Parsed manifest with flattened entries.
 * @param {object} entry One flattened feature entry.
 * @returns {string[]} Effective platforms.
 */
function entryPlatforms(manifest, entry) {
	if (Array.isArray(entry.platforms) && entry.platforms.length > 0) return entry.platforms;
	const parts = entry.section.split('.');
	while (parts.length > 0) {
		let node = manifest.sections;
		for (const part of parts) node = node?.[part];
		if (Array.isArray(node?.platforms) && node.platforms.length > 0) return node.platforms;
		parts.pop();
	}
	return ['ahk', 'hs', 'linux'];
}

/**
 * Lists every entry whose Linux recommendation differs from the Windows one
 * without a still-valid declared exception.
 * @param {object} manifest Parsed manifest with flattened entries.
 * @param {Set<string>} linuxActions Single-fire actions Linux can run.
 * @returns {string[]} One message per drifting or stale entry.
 */
function linuxRecommendationDrift(manifest, linuxActions) {
	const drift = [];
	const seen = new Set();
	for (const entry of manifest.entries) {
		const platforms = entryPlatforms(manifest, entry);
		if (!platforms.includes('ahk') || !platforms.includes('linux')) continue;
		const name = `${entry.section}.${entry.id}`;
		const windows = entry.recommended_per_platform?.ahk ?? entry.recommended;
		const linux = entry.recommended_per_platform?.linux ?? entry.recommended;
		const exception = LINUX_RECOMMENDATION_EXCEPTIONS[name];
		if (!exception) {
			if (!isDeepStrictEqual(windows, linux))
				drift.push(`${name}: linux ${JSON.stringify(linux)} != ahk ${JSON.stringify(windows)}`);
			continue;
		}
		seen.add(name);
		const reasonHolds =
			exception.reason === 'windows-action-absent-on-linux'
				? entry.type === 'action' && !linuxActions.has(windows)
				: exception.reason === 'native-number-row-only' && windows !== 'native';
		if (linux !== exception.linux || !reasonHolds)
			drift.push(`${name}: the declared Linux exception (${exception.reason}) no longer holds`);
	}
	for (const name of Object.keys(LINUX_RECOMMENDATION_EXCEPTIONS))
		if (!seen.has(name)) drift.push(`${name}: the declared Linux exception names no entry`);
	return drift;
}

/** Verify explicit neutral and recommended projections before driver boot. */
async function main() {
	const { parse: parseSource } = await import('smol-toml');
	const tomlOwnData = require('./fixtures/toml-own-data.cjs');
	const parse = (source) => tomlOwnData(parseSource(source));
	const source = fs.readFileSync(paths.shared('modules/features/manifest.toml'), 'utf8');
	const manifest = parse(
		source.replace(
			/^\[\[features\.([^\]]+)\]\]$/gm,
			(_match, section) => `[[entries]]\nsection = "${section}"`
		)
	);
	assert(manifest.entries.length > 200, 'the real feature registry must be loaded');
	// PAR-3: the metrics master switch is ONE key, `metrics.enabled`, read by
	// all three drivers. A second spelling (`metrics.metrics_enabled` on
	// Windows) left the declared key unread there, and a section-prefixed id
	// is how such a second spelling comes back.
	assert.deepEqual(
		manifest.onboarding.pages.metrics.master,
		{ ahk: 'metrics.enabled', hs: 'metrics.enabled', linux: 'metrics.enabled' },
		'the metrics consent page must name one master key on every platform'
	);
	assert.deepEqual(
		manifest.entries
			.filter((entry) => entry.section === 'metrics' && entry.id.startsWith('metrics_'))
			.map((entry) => entry.id),
		[],
		'no metrics key repeats its section name: one spelling per setting'
	);
	// PAR-4: the typing-speed readouts have ONE name set and ONE shipped answer
	// per setting. macOS used float_* and menubar_* (all on), Windows carried a
	// dead menubar key, and each was declared for its own driver only.
	const metricsEntries = manifest.entries.filter((entry) => entry.section === 'metrics');
	assert.deepEqual(
		metricsEntries.filter((entry) => /^(float_|menubar_)/.test(entry.id)).map((entry) => entry.id),
		[],
		'the macOS-only readout spellings are retired'
	);
	for (const [id, platforms, shipped] of [
		['wpm_widget_visible', ['ahk', 'hs', 'linux'], false],
		['wpm_widget_colors', ['ahk', 'hs', 'linux'], false],
		['wpm_widget_graph', ['ahk', 'hs', 'linux'], false],
		['wpm_menubar_visible', ['hs', 'linux'], false],
		['wpm_menubar_colors', ['hs', 'linux'], true]
	]) {
		const entry = metricsEntries.find((candidate) => candidate.id === id);
		assert(entry, `metrics.${id} must be declared`);
		assert.deepEqual(entryPlatforms(manifest, entry), platforms, `metrics.${id} platforms`);
		assert.equal(entry.default, shipped, `metrics.${id} ships ${shipped} on every driver`);
		assert.equal(entry.recommended, shipped, `metrics.${id} recommends what it ships`);
		assert.equal(entry.default_per_platform, undefined, `metrics.${id} has one default`);
	}
	// PAR-6: the base expansion delay has ONE declaration, the manifest default of
	// hotstrings.expansion_delay, read by all three drivers. Neither the shared
	// hotstring defaults nor the timing registry may declare it again.
	const delayEntry = manifest.entries.find(
		(entry) => entry.section === 'hotstrings' && entry.id === 'expansion_delay'
	);
	assert.deepEqual(
		entryPlatforms(manifest, delayEntry),
		['ahk', 'hs', 'linux'],
		'the base expansion delay is declared for every driver'
	);
	assert.equal(
		delayEntry.recommended,
		delayEntry.default,
		'the recommended base delay is the shipped one'
	);
	assert.equal(
		parse(fs.readFileSync(paths.shared('modules/hotstrings/defaults.toml'), 'utf8')).delays
			.default_sec,
		undefined,
		'hotstrings/defaults.toml must not declare the base delay a second time'
	);
	assert(
		!/^hotstring_expansion_ms\s*=/m.test(
			fs.readFileSync(paths.shared('modules/timings/constants.toml'), 'utf8')
		),
		'the timing registry must not mirror the base expansion delay: it has no reader'
	);
	assert.deepEqual(
		Object.keys(manifest.scopes || {}),
		[
			'tap_holds',
			'shortcuts',
			'key_combinations',
			'gestures',
			'keyboard_layout',
			'hotstrings',
			'llm',
			'metrics',
			'global'
		],
		'one ordered scopes registry must own every configuration action'
	);
	assert.deepEqual(
		manifest.scopes.shortcuts.includes,
		['key_combinations'],
		'the root Shortcuts owner includes its combination menu scope'
	);
	assert.deepEqual(manifest.scopes.key_combinations.action_parameters.domains, ['combination']);
	assert.deepEqual(
		manifest.scopes.key_combinations.clear_exclude,
		['mod_combos.enabled', 'category_enabled.key_combinations'],
		'both native clears preserve their group switch'
	);
	assert.deepEqual(
		manifest.menu.key_combinations_group.slice(0, 3).map((row) => row.id),
		['key_combinations_toggle', 'scope_restore', 'scope_clear'],
		'the shared menu exposes both bulk commands'
	);
	let inputCount = 0;
	// The declared exceptions to "an empty configuration alters no input": the
	// script-management chords the maintainer switched on (2026-09-30, « Je les
	// veux actifs par défaut »), then on the three drivers alike (« Oui sur
	// macOS et ils doivent être ajoutés sur Linux aussi. On met tout en commun
	// sur les 3 OS »). A new entry joins this list by a deliberate decision,
	// never by a default edit.
	const APPROVED_ACTIVE_BY_DEFAULT = [
		// The maintainer also requested a conditional ordinary editor shortcut
		// following only the actual unmodified physical magic source (2026-10-02).
		'shortcuts.keyboard.magic_editor',
		'shortcuts.script_control.script_altgr_backspace',
		'shortcuts.script_control.script_altgr_delete',
		'shortcuts.script_control.script_altgr_enter',
		'shortcuts.script_control.script_altgr_escape'
	];
	const activeByDefault = [];
	for (const entry of manifest.entries) {
		const name = `${entry.section}.${entry.id}`;
		assert.notEqual(
			entry.recommended !== undefined,
			entry.recommended_per_platform !== undefined,
			`${name}: exactly one explicit recommended source is required`
		);
		assert.equal(
			typeof entry.input_altering,
			'boolean',
			`${name}: classify activation versus parameters`
		);
		for (const platform of entry.platforms || ['ahk', 'hs', 'linux']) {
			const neutral = entry.default_per_platform?.[platform] ?? entry.default;
			const recommended = entry.recommended_per_platform?.[platform] ?? entry.recommended;
			if (neutral === undefined) continue; // Ancestor platform restrictions are resolved by codegen.
			assert.notEqual(recommended, undefined, `${name}: recommended value missing for ${platform}`);
			if (entry.input_altering && entry.active_by_default === true) {
				inputCount++;
				if (!activeByDefault.includes(name)) activeByDefault.push(name);
				assert.deepEqual(
					neutral,
					recommended,
					`${name}: an entry active by default starts with its preset on ${platform}`
				);
			} else if (entry.input_altering) {
				inputCount++;
				const enabled = entry.type === 'feature' ? neutral.enabled : neutral;
				assert(
					enabled === false ||
						enabled === 'none' ||
						enabled === '' ||
						(name === 'layout.direct_access_digits' &&
							entry.type === 'enum' &&
							enabled === 'native'),
					`${name}: empty ${platform} configuration must not activate input behavior`
				);
			} else {
				assert.deepEqual(neutral, recommended, `${name}: pure parameters retain their preset`);
			}
		}
	}
	assert(
		inputCount > 100,
		'activation coverage must include real shortcuts, gestures and hotstrings'
	);
	assert.deepEqual(
		activeByDefault.sort(),
		[...APPROVED_ACTIVE_BY_DEFAULT].sort(),
		'only approved script-management and physical magic editor slots may be active by default'
	);
	const numberRow = manifest.entries.find(
		(entry) => entry.section === 'layout' && entry.id === 'direct_access_digits'
	);
	assert.equal(numberRow.type, 'enum');
	assert.deepEqual(numberRow.enum_values, ['native', 'digits', 'symbols']);
	assert.equal(numberRow.default, 'native', 'an empty source retains the native input owner');
	assert.deepEqual(numberRow.recommended_per_platform, {
		ahk: 'digits',
		hs: 'native',
		linux: 'native'
	});
	const contextual = manifest.entries.find(
		(entry) => entry.section === 'shortcuts.keyboard' && entry.id === 'magic_editor'
	);
	assert.deepEqual(contextual.platforms, ['ahk', 'hs', 'linux']);
	assert.equal(
		contextual.cleared,
		'none',
		'explicit contextual removal is a durable ordinary assignment'
	);
	const shortcutMaster = manifest.entries.find(
		(entry) => entry.section === 'category_enabled' && entry.id === 'shortcuts'
	);
	assert.equal(
		shortcutMaster.default,
		false,
		'the contextual default must not re-enable the Shortcuts master'
	);
	const luaShortcutMaster = manifest.entries.find(
		(entry) => entry.section === 'shortcuts' && entry.id === 'enabled'
	);
	assert.equal(
		luaShortcutMaster.default,
		false,
		'both Lua masters stay disabled in an empty configuration'
	);
	for (const [platform, driver] of [
		['ahk', 'windows'],
		['hs', 'macos'],
		['linux', 'linux']
	]) {
		const template = parse(
			fs.readFileSync(paths.shared('..', driver, '_generated', 'config_template.toml'), 'utf8')
		);
		assert.equal(
			template.shortcuts.keyboard.magic_editor,
			'open_hotstrings_editor',
			`${driver}: ordinary contextual default`
		);
		const master =
			platform === 'ahk' ? template.category_enabled.shortcuts : template.shortcuts.enabled;
		assert.equal(master, false, `${driver}: default input capture stays closed`);
		assert.equal(
			template.layout.direct_access_digits,
			'native',
			`${driver}: the template reports native posture`
		);
		assert.equal(
			template.category_enabled?.layout ?? false,
			false,
			`${driver}: number-row status cannot activate its master`
		);
		for (const entry of manifest.entries.filter((item) => item.section === 'shortcuts.keyboard')) {
			if (entry.platforms && !entry.platforms.includes(platform)) continue;
			const value = entry.default_per_platform?.[platform] ?? entry.default;
			if (value === 'none')
				assert.equal(
					Object.hasOwn(template.shortcuts.keyboard, entry.id),
					false,
					`${driver}: a generated neutral ${entry.id} must not fabricate personal intent`
				);
		}
	}
	const linuxGestures = fs.readFileSync(
		paths.shared('..', 'linux', 'modules', 'gestures', 'manager.lua'),
		'utf8'
	);
	const projectedSlots = [
		...linuxGestures.matchAll(
			/M\.DEFAULT_GESTURES\[slot\]\s*=\s*Manifest\.default_for\("gestures\."\s*\.\.\s*slot\)/g
		)
	];
	assert.equal(
		projectedSlots.length,
		2,
		'both single and axis gesture defaults must come from the manifest'
	);
	const actionCatalogue = parseSource(
		fs.readFileSync(paths.shared('modules/actions/actions.toml'), 'utf8')
	);
	const linuxActions = new Set(
		Object.entries(actionCatalogue.sg_actions)
			.filter(([, action]) => {
				const tokens = String(action.platform).split(',');
				return tokens.includes('all') || tokens.includes('linux');
			})
			.map(([id]) => id)
	);
	assert(linuxActions.has('caps_word'), 'the Linux action catalogue must be loaded');
	assert.deepEqual(
		linuxRecommendationDrift(manifest, linuxActions),
		[],
		'Linux must recommend what Windows recommends (decision of 2026-10-22)'
	);
	const legacy = structuredClone(manifest);
	const capsWordSlot = legacy.entries.find(
		(entry) =>
			entry.section === 'shortcuts.key_combination_taps' && entry.id === 'left_alt_then_caps_lock'
	);
	delete capsWordSlot.recommended;
	capsWordSlot.recommended_per_platform = { ahk: 'caps_word', linux: 'none' };
	assert.deepEqual(
		linuxRecommendationDrift(legacy, linuxActions),
		['shortcuts.key_combination_taps.left_alt_then_caps_lock: linux "none" != ahk "caps_word"'],
		'the parity gate must reject the former Linux LAlt then CapsLock recommendation'
	);
	assert.deepEqual(manifest.scopes.llm.restore_exclude, ['llm.enabled']);
	assert.deepEqual(manifest.scopes.metrics.restore_exclude, ['metrics.enabled']);
	assert(
		manifest.scopes.global.prefixes.includes('script'),
		'global scope must include script preferences'
	);
	for (const key of [
		'autocorrection',
		'distances_reduction',
		'sfbs_reduction',
		'rolls',
		'magic_key'
	]) {
		assert(
			manifest.scopes.hotstrings.prefixes.includes(`category_enabled.${key}`),
			`hotstrings scope must include the ${key} subordinate master`
		);
	}
	console.log(`Neutral/recommended contract passed for ${manifest.entries.length} entries.`);
}

main().catch((error) => {
	console.error(error.stack);
	process.exitCode = 1;
});
