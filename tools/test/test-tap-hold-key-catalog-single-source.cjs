// tools/test/test-tap-hold-key-catalog-single-source.cjs

/**
 * ==============================================================================
 * MODULE: One Tap-Hold Key Catalogue
 * DESCRIPTION:
 * The keys a tap-hold can be set on, their order in the tray, the hand each
 * belongs to and the label each carries are declared once, in
 * `[tap_hold.catalog]` of `_shared/tap_hold/defaults.toml`, and every driver
 * reads them there.
 *
 * ROOT CAUSE ENCODED:
 * the list lived in three copies that pointed at a fourth that never existed.
 * Windows kept `_TH_KeyDefs` "mirroring menu_manifest.json
 * tap_hold_keys_catalog", Linux kept its own `KEY_ORDER`, and the macOS menu
 * read that same missing manifest key, so its built-in fallback always won —
 * and the fallback said `action = true` where `fn = true` was meant, which put
 * Fn under « Main droite ». Nothing compared any of them.
 *
 * WHAT IS HELD:
 * 1. The catalogue parses, every entry names a hand and a translated label,
 *    and Fn sits on the left.
 * 2. Each driver's column is exactly the set of keys its engine can remap:
 *    macOS `tap_hold_keys.json` (in the same order), the Linux engine's evdev
 *    table, and the keys the Windows `platform/remap/*.ahk` hotkeys arm.
 * 3. Each driver reads the catalogue, and none keeps a list of its own.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DEFAULTS = path.join(SP, '_shared', 'tap_hold', 'defaults.toml');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');
const MAC_KEYS = path.join(SP, 'macos', 'platform', 'remap', 'data', 'tap_hold_keys.json');
const LINUX_ENGINE = path.join(SP, 'linux', 'platform', 'remap', 'tap_hold_engine.lua');
const WINDOWS_REMAP = path.join(SP, 'windows', 'platform', 'remap');

const PLATFORMS = ['ahk', 'hs', 'linux'];
const HANDS = new Set(['left', 'right']);

// Floors: a catalogue or a scan that yields nothing must not pass for free.
const MIN_ENTRIES = 14;
const MIN_PER_PLATFORM = 14;

const errors = [];

/**
 * Reads a file, recording its absence as a failure.
 * @param {string} file Absolute path.
 * @returns {string}
 */
function read(file) {
	try {
		return fs.readFileSync(file, 'utf8');
	} catch (e) {
		errors.push(`cannot read ${path.relative(ROOT, file)}: ${e.message}`);
		return '';
	}
}

/**
 * Removes Lua and AutoHotkey line comments, so a comment naming a key is
 * never mistaken for code that uses it.
 * @param {string} src Source text.
 * @param {string} ext ".lua" or ".ahk".
 * @returns {string}
 */
function stripLineComments(src, ext) {
	const marker = ext === '.ahk' ? /^\s*;.*$/gm : /^\s*--.*$/gm;
	return src.replace(marker, '');
}

// ==========================================
// ==========================================
// ======= 1/ The catalogue itself ==========
// ==========================================
// ==========================================

let entries = [];
try {
	const parsed = TOML.parse(read(DEFAULTS));
	const catalog = parsed.tap_hold && parsed.tap_hold.catalog;
	entries = catalog && Array.isArray(catalog.keys) ? catalog.keys : [];
} catch (e) {
	errors.push(`_shared/tap_hold/defaults.toml does not parse: ${e.message}`);
}

if (entries.length < MIN_ENTRIES) {
	errors.push(
		`[tap_hold.catalog] keys lists ${entries.length} key(s), expected at least ${MIN_ENTRIES}. ` +
			'Every tray builds its Tap-Hold key rows from it.'
	);
}

const locales = fs
	.readdirSync(LOCALES)
	.filter((f) => f.endsWith('.json'))
	.map((f) => ({ name: f, data: JSON.parse(read(path.join(LOCALES, f))) }));
if (locales.length !== 21) errors.push(`expected 21 locale files, found ${locales.length}`);

const columns = { ahk: [], hs: [], linux: [] };
const seenIds = new Set();
for (const [index, entry] of entries.entries()) {
	const where = `[tap_hold.catalog] keys[${index + 1}]`;
	if (typeof entry.id !== 'string' || entry.id === '') {
		errors.push(`${where} has no id`);
		continue;
	}
	if (seenIds.has(entry.id)) errors.push(`${where}: id "${entry.id}" is listed twice`);
	seenIds.add(entry.id);
	if (!HANDS.has(entry.hand)) {
		errors.push(
			`${where} "${entry.id}": hand must be "left" or "right", got ${JSON.stringify(entry.hand)}`
		);
	}
	if (typeof entry.label_key !== 'string' || entry.label_key === '') {
		errors.push(`${where} "${entry.id}" has no label_key`);
	} else {
		for (const locale of locales) {
			if (typeof locale.data[entry.label_key] !== 'string') {
				errors.push(`${where} "${entry.id}": ${locale.name} has no "${entry.label_key}"`);
			}
		}
	}
	let platforms = 0;
	for (const platform of PLATFORMS) {
		if (entry[platform] === undefined) continue;
		if (typeof entry[platform] !== 'string' || entry[platform] === '') {
			errors.push(`${where} "${entry.id}": ${platform} must be a non-empty key id`);
			continue;
		}
		columns[platform].push(entry[platform]);
		platforms += 1;
	}
	if (platforms === 0) errors.push(`${where} "${entry.id}" names no driver's key`);
	for (const field of Object.keys(entry)) {
		if (!['id', 'hand', 'label_key', ...PLATFORMS].includes(field)) {
			errors.push(`${where} "${entry.id}": unknown field "${field}" — no driver reads it`);
		}
	}
}

for (const platform of PLATFORMS) {
	const ids = columns[platform];
	if (ids.length < MIN_PER_PLATFORM) {
		errors.push(
			`the ${platform} column lists ${ids.length} key(s), expected at least ${MIN_PER_PLATFORM}`
		);
	}
	if (new Set(ids).size !== ids.length) errors.push(`the ${platform} column repeats a key id`);
}

// The bug this catalogue replaced: Fn listed under the right hand on macOS.
const fn = entries.find((entry) => entry.hs === 'fn');
if (!fn) {
	errors.push('the catalogue has no macOS Fn key');
} else if (fn.hand !== 'left') {
	errors.push(`the macOS Fn key is on the "${fn.hand}" hand; it is a left-hand key`);
}

// ==========================================
// ==========================================
// ======= 2/ Each column is its engine =====
// ==========================================
// ==========================================

/**
 * Compares a catalogue column with the key set a driver's engine implements.
 * @param {string} platform Catalogue column.
 * @param {string[]} engine Engine key ids.
 * @param {string} owner Where the engine set comes from.
 * @param {boolean} ordered Whether the order must match too.
 */
function sameKeys(platform, engine, owner, ordered) {
	if (engine.length < MIN_PER_PLATFORM) {
		errors.push(`read only ${engine.length} key(s) from ${owner} — the scan is broken`);
		return;
	}
	const column = columns[platform];
	const missing = engine.filter((id) => !column.includes(id));
	const extra = column.filter((id) => !engine.includes(id));
	if (missing.length > 0) {
		errors.push(
			`${owner} remaps ${missing.join(', ')}, which the catalogue's ${platform} column omits`
		);
	}
	if (extra.length > 0) {
		errors.push(
			`the catalogue's ${platform} column names ${extra.join(', ')}, which ${owner} cannot remap`
		);
	}
	if (ordered && missing.length === 0 && extra.length === 0 && column.join() !== engine.join()) {
		errors.push(
			`the catalogue's ${platform} order (${column.join(', ')}) differs from ${owner} (${engine.join(', ')})`
		);
	}
}

// macOS: the Karabiner matcher data, whose order is also the generated rule order.
let macKeys = [];
try {
	macKeys = JSON.parse(read(MAC_KEYS)).map((key) => key.id);
} catch (e) {
	errors.push(`tap_hold_keys.json does not parse: ${e.message}`);
}
sameKeys('hs', macKeys, 'macos/platform/remap/data/tap_hold_keys.json', true);

// Linux: the evdev code table of the tap-hold engine.
const linuxEngine = stripLineComments(read(LINUX_ENGINE), '.lua');
const codes = linuxEngine.match(/M\.KEY_CODES\s*=\s*\{([\s\S]*?)\}/);
const linuxKeys = codes ? [...codes[1].matchAll(/([a-z_]+)\s*=\s*\d+/g)].map((m) => m[1]) : [];
sameKeys('linux', linuxKeys, 'linux/platform/remap/tap_hold_engine.lua KEY_CODES', false);

// Windows: every key a platform/remap hotkey reads a tap or a hold for.
const windowsKeys = new Set();
for (const file of fs.readdirSync(WINDOWS_REMAP).filter((f) => f.endsWith('.ahk'))) {
	const src = stripLineComments(read(path.join(WINDOWS_REMAP, file)), '.ahk');
	for (const m of src.matchAll(
		/TapHold(?:TapAction|HoldModifier|HoldLayer)\(TapHold,\s*"([a-z_]+)"\)/g
	)) {
		windowsKeys.add(m[1]);
	}
}
sameKeys('ahk', [...windowsKeys], 'windows/platform/remap/*.ahk', false);

// ==========================================
// ==========================================
// ======= 3/ Every driver reads it =========
// ==========================================
// ==========================================

const READERS = [
	{
		file: 'macos/ui/menu/menu_tap_holds.lua',
		reads: /require\("tap_hold\.key_catalog"\)/,
		retired: [/tap_hold_keys_catalog/, /LEFT_HAND_IDS/, /_load_left_hand_from_catalog/]
	},
	{
		file: 'linux/ui/menu/menu_builder.lua',
		reads: /\.key_catalog\(\)/,
		retired: [/KEY_ORDER/]
	},
	{
		file: 'linux/platform/remap/tap_hold_engine.lua',
		reads: null,
		retired: [/KEY_ORDER/]
	},
	{
		file: 'linux/platform/remap/tap_hold_loader.lua',
		reads: /require\("tap_hold\.key_catalog"\)/,
		retired: []
	},
	{
		file: 'windows/platform/remap/tap_hold_writer.ahk',
		reads: /"tap_hold\.catalog"/,
		retired: [/tap_hold_keys_catalog/, /Map\("id",\s*"[a-z_]+",\s*"i18n",\s*"tap_hold\.group\./]
	}
];

for (const reader of READERS) {
	const ext = path.extname(reader.file);
	const src = stripLineComments(read(path.join(SP, reader.file)), ext);
	if (src.length < 500) {
		errors.push(`${reader.file} is unreadable or nearly empty (${src.length} bytes)`);
		continue;
	}
	if (reader.reads && !reader.reads.test(src)) {
		errors.push(`${reader.file} does not read the shared [tap_hold.catalog]`);
	}
	for (const pattern of reader.retired) {
		if (pattern.test(src)) {
			errors.push(`${reader.file} still keeps a key list of its own (${pattern})`);
		}
	}
}

// ================================================
// ================================================
// ======= 4/ Physical combination labels =========
// ================================================
// ================================================

const macMenu = stripLineComments(read(path.join(SP, 'macos/ui/menu/menu_tap_holds.lua')), '.lua');
if (
	!/require\("tap_hold\.combination_labels"\)/.test(macMenu) ||
	!macMenu.includes(
		'CombinationLabels.resolve(key_catalog(), keys[1].key_code, keys[2].key_code, i18n.get)'
	)
) {
	errors.push(
		'the macOS combination provider must resolve both physical keys through the shared label policy'
	);
}
if (/combo_def\.(?:label|group)\b/.test(macMenu)) {
	errors.push('the macOS combination provider still displays raw native matrix names');
}
if (!/local parts = \{ enabled and "1" or "0", i18n\.get_locale\(\) \}/.test(macMenu)) {
	errors.push('the combination picker cache must include the active locale');
}

const nativeMatrix = JSON.parse(read(path.join(SP, 'macos/platform/remap/data/mod_combos.json')));
if (nativeMatrix.length !== 182)
	errors.push('the full ordered macOS physical pair matrix must retain 182 entries');
const macIds = new Set(columns.hs);
for (const pair of nativeMatrix) {
	const physical = pair.from?.simultaneous;
	if (
		!Array.isArray(physical) ||
		physical.length !== 2 ||
		physical.some((key) => !macIds.has(key.key_code))
	) {
		errors.push(`native combination ${pair.id} lacks two canonical physical key labels`);
	}
}

// Windows already translates both the family and the pair from this catalogue.
const windowsCombos = stripLineComments(
	read(path.join(SP, 'windows/infra/key_combinations.ahk')),
	'.ahk'
);
if (
	!windowsCombos.includes('t(First["i18n"]) . " + " . t(Second["i18n"])') ||
	!windowsCombos.includes('Rows.Push(Map("label", t(First["i18n"])')
) {
	errors.push(
		'Windows combination families and pairs must keep the canonical translated key names'
	);
}

// Linux owns ordered taps/holds. The native wrapper is source-fenced and
// composed through the same tap-hold catalogue; simultaneous chords and native
// state-only tap actions are not declared by this admission.
const manifest = TOML.parse(
	read(path.join(SP, '_shared/modules/features/manifest.toml')).replace(
		/^\[\[features\.([^\]]+)\]\]$/gm,
		(_header, section) => `[[feature_records]]\nsection_path = \"${section}\"`
	)
);
const combinations = manifest.menu.shortcuts_menu.find((row) => row.id === 'key_combinations');
const linuxManager = stripLineComments(
	read(path.join(SP, 'linux/platform/remap/tap_hold_manager.lua')),
	'.lua'
);
const linuxPairs = stripLineComments(
	read(path.join(SP, 'linux/platform/remap/key_combination_engine.lua')),
	'.lua'
);
const linuxOwner = stripLineComments(
	read(path.join(SP, 'linux/modules/shortcuts/key_combinations.lua')),
	'.lua'
);
const linuxMenu = stripLineComments(
	read(path.join(SP, 'linux/ui/menu/key_combinations.lua')),
	'.lua'
);

const linuxHook = stripLineComments(
	read(path.join(SP, 'linux/adapters/keyboard_hook.lua')),
	'.lua'
);
const linuxDaemon = stripLineComments(read(path.join(SP, 'linux/ergopti_hotstrings.lua')), '.lua');
const linuxKeylogger = stripLineComments(
	read(path.join(SP, 'linux/modules/keylogger/keylogger.lua')),
	'.lua'
);

/**
 * Reads a named Lua body between consecutive declarations; absence is never evidence.
 * @param {string} source Comment-stripped source.
 * @param {string} declaration Exact function declaration.
 * @param {string} successor Next function declaration.
 * @returns {string} Body, or empty when either boundary is absent.
 */
function luaBody(source, declaration, successor) {
	const start = source.indexOf(declaration);
	const end = source.indexOf(successor, start + declaration.length);
	if (start < 0 || end < 0) return '';
	const body = source.slice(start + declaration.length, end).trim();
	return body.endsWith('end') ? body.slice(0, -3).trim() : '';
}

/**
 * Checks the saved intent route through its original live input controller.
 * @param {string[]} sources Manager, wrapper, owner, menu, Hook and bootstrap sources.
 * @returns {boolean} Bounded saved admission without public input authority.
 */
function savedLinuxOneShotClosure(sources) {
	const [manager, , , , hook, daemon, keylogger] = sources;
	const bodies = {
		tap: luaBody(
			manager,
			'local function _run_tap(action, binding)',
			'local function _read_one_shot()'
		),
		build: luaBody(manager, 'local function _build(loaded, boot)', 'local function _load(boot)'),
		init: luaBody(manager, 'function M.init(opts)', 'function M.reload()'),
		frame: luaBody(
			hook,
			'local function _run_owned_tap_frame(frame, tap, binding, exact, original_generation, origin, origin_view, source, at_ms)',
			'local function _dispatch_event(ev, source)'
		),
		runtime: luaBody(
			hook,
			'local function _input_runtime_current(ctx, active)',
			'local function _caps_semantics_current(ctx)'
		),
		guard: luaBody(
			hook,
			'local function _input_guard_current(ctx)',
			'local function _input_cleanup_current(ctx)'
		),
		capture: luaBody(
			hook,
			'function M.capture_input_owner()',
			'function M.input_owner_current(lease)'
		),
		current: luaBody(
			hook,
			'function M.input_owner_current(lease)',
			'function M.arm_one_shot(lease)'
		),
		arm: luaBody(hook, 'function M.arm_one_shot(lease)', 'function M.arm_caps_word(lease)'),
		caps: luaBody(hook, 'function M.arm_caps_word(lease)', 'function M.plan_caps_word(text)'),
		semantics: luaBody(
			hook,
			'local function _caps_semantics_current(ctx)',
			'local function _input_guard_current(ctx)'
		)
	};
	if (Object.values(bodies).some((body) => body === '')) return false;
	const assignment = bodies.build.match(
		/actions = \{ is_assignable = function\(action\)([\s\S]*?)end \}/
	)?.[1];
	const capture = '_native_hook = package.loaded["adapters.keyboard_hook"]';
	const managerAt = daemon.indexOf('require("modules.keylogger.keylogger")');
	const hookAt = daemon.indexOf('require("adapters.keyboard_hook")');
	return (
		assignment?.trim().replace(/\s+/g, ' ') ===
			'return action ~= "caps_word" and (action ~= "one_shot_shift" or _hook == _native_hook) and _tap_action_set()[action] == true' &&
		bodies.init.includes(capture) &&
		bodies.init.indexOf(capture) < bodies.init.indexOf('Logger.start(') &&
		bodies.init.indexOf(capture) < bodies.init.indexOf('_load(true)') &&
		manager.split('package.loaded["adapters.keyboard_hook"]').length === 2 &&
		manager.includes('local _native_hook = nil') &&
		managerAt >= 0 &&
		hookAt > managerAt &&
		daemon.indexOf('TapHold.init({') > hookAt &&
		keylogger.includes('require("platform.remap.tap_hold_manager")') &&
		bodies.tap.startsWith(
			'if action == "one_shot_shift" or action == "caps_word" then return action end'
		) &&
		!/(?:capture_input_owner|input_owner_current|arm_one_shot|arm_caps_word)\s*\(/.test(manager) &&
		bodies.frame.includes('origin_view.origin == "native-evdev" and _remapper_input_owner') &&
		bodies.frame.includes('origin_view.source == source') &&
		bodies.frame.includes('callback = _on_tap, at_ms = at_ms') &&
		bodies.frame.includes('local requested = callback(action, selected)') &&
		bodies.frame.includes('requested ~= tap or action ~= tap') &&
		bodies.frame.includes('local lease = original_input_hook_ports.capture_input_owner()') &&
		bodies.frame.includes(
			'if not lease or original_input_hook_ports.input_owner_current(lease) ~= true then return false end'
		) &&
		bodies.frame.includes('if tap == "one_shot_shift" or tap == "caps_word" then') &&
		bodies.frame.includes(
			'local arm = tap == "caps_word" and original_input_hook_ports.arm_caps_word or original_input_hook_ports.arm_one_shot'
		) &&
		bodies.frame.includes('return arm(lease) == true') &&
		bodies.frame.includes('and original_input_hook_ports.input_owner_current(lease) == true') &&
		!/M\.(?:capture_input_owner|input_owner_current|arm_one_shot|arm_caps_word)\s*\(/.test(
			bodies.frame
		) &&
		hook.includes(
			'local INPUT_HOOK_PORT_NAMES = { "capture_input_owner", "input_owner_current", "arm_one_shot", "arm_caps_word", "plan_caps_word", "set_remapper", "stop", "emergency_stop", "key_text" }'
		) &&
		hook.includes(
			'for _, name in ipairs(INPUT_HOOK_PORT_NAMES) do original_input_hook_ports[name] = rawget(M, name) end'
		) &&
		bodies.runtime.includes('active and _live_input_context ~= ctx') &&
		bodies.runtime.includes('_remapper_generation ~= ctx.generation') &&
		bodies.runtime.includes('_on_tap ~= ctx.callback') &&
		bodies.runtime.includes('_physical_sources[ctx.source] ~= true') &&
		bodies.runtime.includes('port ~= original_input_hook_ports[name]') &&
		bodies.runtime.includes('rawget(M, name) ~= port') &&
		bodies.runtime.includes(
			'_input_reader_ports.source_current(ctx.origin, ctx.sources[keyboard_slot(ctx.source)]'
		) &&
		bodies.runtime.includes('rawget(ctx.broker, "output_current") ~= ctx.output_current') &&
		bodies.runtime.includes('output.writer, name) ~= port') &&
		bodies.guard.includes('local checked, configured = pcall(ctx.guard)') &&
		bodies.guard.includes('configured ~= true or not _input_runtime_current(ctx, false)') &&
		bodies.guard.includes('view.busy == false and view.debt == false') &&
		bodies.guard.includes('debt == false and output_ok and output == true') &&
		bodies.capture.includes('_input_runtime_current(ctx, true)') &&
		bodies.capture.includes(
			'pcall(_input_ports.capture_input_guard, ctx.issuer, ctx.frame, ctx.action)'
		) &&
		bodies.capture.includes('local lease = {}; ctx.lease = lease; _input_leases[lease] = ctx') &&
		bodies.current.includes('getmetatable(lease) ~= nil or next(lease) ~= nil') &&
		bodies.current.includes('and _input_guard_current(ctx)') &&
		bodies.arm.includes('ctx.used or ctx.arming') &&
		bodies.arm.includes(
			'local function current() return _input_runtime_current(ctx, not ctx.used) and _input_guard_current(ctx) end'
		) &&
		bodies.arm.includes('pcall(_input_ports.arm_one_shot, ctx.issuer, ctx.at_ms, current)') &&
		bodies.arm.includes('if not ctx or ctx.action ~= "one_shot_shift" or ctx.used or ctx.arming') &&
		bodies.caps.includes('ctx.action ~= "caps_word"') &&
		bodies.caps.includes('pcall(caps_ports.capture)') &&
		bodies.caps.includes('pcall(_input_ports.arm_caps_word, ctx.issuer, current)') &&
		bodies.caps.includes('published ~= true or not _input_runtime_current(ctx, true)') &&
		bodies.semantics.includes('if ctx.action ~= "caps_word" then return true end') &&
		bodies.semantics.includes('NativeCapsWord.capture ~= caps_ports.capture') &&
		bodies.semantics.includes('caps_ports.current(ctx.semantic_owner) ~= true') &&
		bodies.semantics.includes(
			'_input_reader_ports.event_current(ctx.letter_origin, ctx.letter_event,'
		) &&
		bodies.guard.includes(
			'and _caps_semantics_current(ctx) and _input_runtime_current(ctx, false)'
		) &&
		hook.includes('local original_caps_constructor = assert(caps_constructor_source') &&
		hook.includes('local NativeCapsWord = assert(original_caps_constructor())')
	);
}

/**
 * Checks actual declaration and dispatch boundaries, including unavailable modes.
 * @param {object} declaration Canonical shared manifest.
 * @param {string[]} sources Manager, wrapper, owner, menu, Hook and bootstrap source bytes.
 * @returns {boolean} Exact ordered Linux admission, never a chord claim.
 */
function orderedLinuxAdmission(declaration, sources) {
	const [manager, wrapper, owner, menu] = sources;
	const row = declaration.menu.shortcuts_menu.find((item) => item.id === 'key_combinations');
	const taps = declaration.feature_records.filter(
		(item) => item.section_path === 'shortcuts.key_combination_taps'
	);
	const capsWord = taps.find((item) => item.id === 'left_alt_then_caps_lock');
	return (
		row?.platforms?.join(',') === 'ahk,hs,linux' &&
		row.reason_key === 'platform_reason.remap_engine_is_per_driver' &&
		capsWord?.recommended_per_platform?.linux === 'none' &&
		declaration.menu.key_combinations_group
			.filter((item) => ['combo_symmetric', 'combo_timings', 'copy_tap_to_combo'].includes(item.id))
			.every((item) => item.platforms?.join(',') === 'hs') &&
		manager.includes('require("platform.remap.key_combination_engine")') &&
		manager.includes('CombinationEngine.new(') &&
		manager.includes('.engine_options(') &&
		wrapper.includes('require("tap_hold.key_combinations")') &&
		wrapper.includes('receipt.physical == true') &&
		wrapper.includes('current.source == receipt.source') &&
		wrapper.includes('function result.admit(') &&
		wrapper.includes('function owner.begin_delivery(') &&
		taps.every(
			(item) => (item.recommended_per_platform?.linux ?? item.recommended) !== 'one_shot_shift'
		) &&
		savedLinuxOneShotClosure(sources) &&
		menu.includes('KeyCatalog.of_hand(keys,hand)') &&
		menu.includes('Shared.pair(first.id,second.id)') &&
		menu.includes('Scope.edit(rows,ctx.is_paused,source)')
	);
}
const linuxSources = [
	linuxManager,
	linuxPairs,
	linuxOwner,
	linuxMenu,
	linuxHook,
	linuxDaemon,
	linuxKeylogger
];
if (!orderedLinuxAdmission(manifest, linuxSources)) {
	errors.push(
		'Linux ordered combinations need their real shared/native source-fenced engine and truthful mode limits'
	);
}
// Independently reject each lost native admission boundary instead of replacing
// the previous unavailable-driver assertion with unconditional availability.
for (const [index, token] of [
	[0, 'require("platform.remap.key_combination_engine")'],
	[1, 'receipt.physical == true'],
	[1, 'current.source == receipt.source'],
	[0, 'action ~= "caps_word"'],
	[3, 'Scope.edit(rows,ctx.is_paused,source)']
]) {
	const changed = linuxSources.slice();
	changed[index] = changed[index].replace(token, 'OMITTED_BOUNDARY');
	if (orderedLinuxAdmission(manifest, changed))
		errors.push('Linux ordered admission accepted a missing native/source boundary');
}
// Each saved-route boundary remains necessary, including the conditional
// native state owner. Public assignment and recommendations stay unavailable.
for (const [index, token] of [
	[0, '_hook == _native_hook'],
	[0, '_tap_action_set()[action] == true'],
	[0, '_native_hook = package.loaded["adapters.keyboard_hook"]'],
	[0, 'if action == "one_shot_shift" or action == "caps_word" then return action end'],
	[0, 'function M.init(opts)'],
	[4, 'origin_view.origin == "native-evdev" and _remapper_input_owner'],
	[4, 'origin_view.source == source'],
	[4, 'callback = _on_tap, at_ms = at_ms'],
	[4, 'local requested = callback(action, selected)'],
	[4, 'requested ~= tap or action ~= tap'],
	[4, 'local lease = original_input_hook_ports.capture_input_owner()'],
	[
		4,
		'if not lease or original_input_hook_ports.input_owner_current(lease) ~= true then return false end'
	],
	[4, 'return arm(lease) == true'],
	[4, 'if tap == "one_shot_shift" or tap == "caps_word" then'],
	[
		4,
		'local arm = tap == "caps_word" and original_input_hook_ports.arm_caps_word or original_input_hook_ports.arm_one_shot'
	],
	[4, 'if not ctx or ctx.action ~= "one_shot_shift" or ctx.used or ctx.arming'],
	[4, 'ctx.action ~= "caps_word"'],
	[4, 'pcall(caps_ports.capture)'],
	[4, 'pcall(_input_ports.arm_caps_word, ctx.issuer, current)'],
	[4, 'published ~= true or not _input_runtime_current(ctx, true)'],
	[4, 'if ctx.action ~= "caps_word" then return true end'],
	[4, 'NativeCapsWord.capture ~= caps_ports.capture'],
	[4, 'caps_ports.current(ctx.semantic_owner) ~= true'],
	[4, '_input_reader_ports.event_current(ctx.letter_origin, ctx.letter_event,'],
	[4, 'and _caps_semantics_current(ctx) and _input_runtime_current(ctx, false)'],
	[4, 'local original_caps_constructor = assert(caps_constructor_source'],
	[4, 'local NativeCapsWord = assert(original_caps_constructor())'],
	[4, 'and original_input_hook_ports.input_owner_current(lease) == true'],
	[4, '"stop", "emergency_stop", "key_text"'],
	[
		4,
		'for _, name in ipairs(INPUT_HOOK_PORT_NAMES) do original_input_hook_ports[name] = rawget(M, name) end'
	],
	[4, 'active and _live_input_context ~= ctx'],
	[4, '_remapper_generation ~= ctx.generation'],
	[4, '_on_tap ~= ctx.callback'],
	[4, '_physical_sources[ctx.source] ~= true'],
	[4, 'port ~= original_input_hook_ports[name]'],
	[4, 'rawget(M, name) ~= port'],
	[4, '_input_reader_ports.source_current(ctx.origin, ctx.sources[keyboard_slot(ctx.source)]'],
	[4, 'rawget(ctx.broker, "output_current") ~= ctx.output_current'],
	[4, 'output.writer, name) ~= port'],
	[4, 'local checked, configured = pcall(ctx.guard)'],
	[4, 'configured ~= true or not _input_runtime_current(ctx, false)'],
	[4, 'view.busy == false and view.debt == false'],
	[4, 'debt == false and output_ok and output == true'],
	[4, 'pcall(_input_ports.capture_input_guard, ctx.issuer, ctx.frame, ctx.action)'],
	[4, 'local lease = {}; ctx.lease = lease; _input_leases[lease] = ctx'],
	[4, 'getmetatable(lease) ~= nil or next(lease) ~= nil'],
	[4, 'ctx.used or ctx.arming'],
	[
		4,
		'local function current() return _input_runtime_current(ctx, not ctx.used) and _input_guard_current(ctx) end'
	],
	[4, 'pcall(_input_ports.arm_one_shot, ctx.issuer, ctx.at_ms, current)'],
	[5, 'require("modules.keylogger.keylogger")'],
	[5, 'TapHold.init({'],
	[6, 'require("platform.remap.tap_hold_manager")']
]) {
	const changed = linuxSources.slice();
	if (!changed[index].includes(token))
		errors.push(`Missing saved-route omission subject: ${token}`);
	changed[index] = changed[index].replace(token, 'OMITTED_SAVED_BOUNDARY');
	if (orderedLinuxAdmission(manifest, changed))
		errors.push(`Linux saved OneShot admission accepted an omitted boundary: ${token}`);
}
const unsupported = structuredClone(manifest);
unsupported.menu.shortcuts_menu.find((row) => row.id === 'key_combinations').platforms = [
	'ahk',
	'hs'
];
if (orderedLinuxAdmission(unsupported, linuxSources))
	errors.push('An unsupported Linux declaration must remain unavailable');
const unavailableTap = structuredClone(manifest);
unavailableTap.feature_records.find(
	(row) =>
		row.section_path === 'shortcuts.key_combination_taps' && row.id === 'left_alt_then_caps_lock'
).recommended_per_platform.linux = 'caps_word';
if (orderedLinuxAdmission(unavailableTap, linuxSources))
	errors.push('Linux must not recommend an undispatched native-only pair tap');
for (const inherited of [false, true]) {
	const unavailableOneShot = structuredClone(manifest);
	const tap = unavailableOneShot.feature_records.find(
		(row) =>
			row.section_path === 'shortcuts.key_combination_taps' && row.id === 'alt_gr_then_left_alt'
	);
	if (inherited) {
		tap.recommended = 'one_shot_shift';
		delete tap.recommended_per_platform;
	} else
		tap.recommended_per_platform = { ...tap.recommended_per_platform, linux: 'one_shot_shift' };
	if (orderedLinuxAdmission(unavailableOneShot, linuxSources))
		errors.push('Linux saved OneShot input intent must not open a public recommendation');
}
for (const locale of locales) {
	if (
		typeof locale.data[combinations?.reason_key] !== 'string' ||
		locale.data[combinations?.reason_key] === ''
	) {
		errors.push(`${locale.name} lacks the combination mode availability reason`);
	}
}

// ==========================
// ==========================
// ======= 5/ Verdict =======
// ==========================
// ==========================

if (errors.length > 0) {
	console.error(`\x1b[31m[FAIL] tap-hold key catalogue: ${errors.length} problem(s)\x1b[0m`);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] One tap-hold key catalogue: ${entries.length} key(s), ` +
		`${columns.ahk.length} Windows / ${columns.hs.length} macOS / ${columns.linux.length} Linux, ` +
		'each matching its engine and read by its tray.\x1b[0m'
);
