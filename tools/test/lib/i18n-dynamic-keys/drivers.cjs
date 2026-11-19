// tools/test/lib/i18n-dynamic-keys/drivers.cjs

/**
 * ==============================================================================
 * MODULE: Driver Key Families
 * DESCRIPTION:
 * The run-time key families of the Windows, macOS and Linux drivers: gesture
 * slots and parameters, hotstring categories, the input probe, the LLM menus,
 * shortcuts, tap keys, tap-holds and the remap pickers. A family reads the
 * shared data its code reads (actions.toml, menu.toml, the features manifest,
 * the JSON catalogues) where there is one. Where the ids are only written in
 * the driver's own code (a constant table, the literals a function returns,
 * the cases of a switch), the family reads that code, so a renamed or added id
 * changes the enumeration with it.
 * ==============================================================================
 */

'use strict';

const ctx = require('./context.cjs');

const ROOT = 'static/ergopti_plus/';
const ACTIONS_TOML = ROOT + '_shared/shortcuts/data/actions/actions.toml';
const MENU_TOML = ROOT + '_shared/menu/data/menu.toml';
const HOTSTRING_INDEX = ROOT + '_shared/hotstrings/data/catalogue/_index.toml';
const FEATURES_MANIFEST = ROOT + '_shared/settings/data/features/manifest.toml';
const TAP_HOLD_DEFAULTS = ROOT + '_shared/tap_hold/data/defaults.toml';
const PROFILES_JSON = ROOT + '_shared/ai/data/profiles.json';
const API_PROVIDERS = ROOT + '_shared/ai/data/api_providers.json';
const TAP_KEYS_JSON = ROOT + '_shared/shortcuts/data/actions/tap_keys.json';
const SCRIPT_CHORDS = ROOT + '_shared/shortcuts/data/actions/script_chords.json';
const BRIGHTNESS = ROOT + '_shared/shortcuts/data/actions/brightness.json';
const SHARED_SEND_INPUT = ROOT + '_shared/platform/input/send_input.lua';
const MAGIC_CORE_LUA = ROOT + '_shared/shortcuts/engine/magic_editor_core.lua';
const MAGIC_CORE_AHK = ROOT + '_shared/shortcuts/data/magic_editor.ahk';
const DEBUG_REPORT = ROOT + '_shared/diagnostics/engine/healthcheck/report.lua';

const LINUX_GESTURES = ROOT + 'linux/gestures/engine/manager.lua';
const LINUX_CONFLICTS = ROOT + 'linux/gestures/ui/conflicts.lua';
const LINUX_HOTSTRINGS = ROOT + 'linux/hotstrings/ui/menu/hotstrings.lua';
const LINUX_BACKEND_ROWS = ROOT + 'linux/ai/ui/menu/backend_rows.lua';
const LINUX_TAP_KEYS = ROOT + 'linux/modules/shortcuts/tap_keys.lua';
const LINUX_ACCENTED = ROOT + 'linux/modules/shortcuts/accented_shortcuts.lua';
const LINUX_PREDICTION = ROOT + 'linux/ai/engine/prediction/engine.lua';
const LINUX_TAP_HOLDS_MENU = ROOT + 'linux/ui/menu/menu_tap_holds.lua';
const LINUX_SHORTCUTS_MENU = ROOT + 'linux/ui/menu/menu_shortcuts.lua';
const LINUX_LAYOUTS_MENU = ROOT + 'linux/ui/menu/menu_layouts.lua';

const MACOS_GESTURE_ACTIONS = ROOT + 'macos/gestures/engine/actions.lua';
const MACOS_GESTURES_MENU = ROOT + 'macos/gestures/ui/menu/gestures.lua';
const MACOS_PROFILES = ROOT + 'macos/ai/engine/settings/profiles.lua';
const MACOS_API_PANEL = ROOT + 'macos/ai/ui/menu/panels/api_panel.lua';
const MACOS_KEYBOARD_SHORTCUTS = ROOT + 'macos/modules/shortcuts/keyboard_shortcuts.lua';
const MACOS_MAGIC_EDITOR = ROOT + 'macos/modules/shortcuts/magic_editor.lua';
const MACOS_TAP_KEYS = ROOT + 'macos/modules/shortcuts/tap_keys.lua';
const MACOS_REMAP = ROOT + 'macos/platform/remap/config.lua';
const MACOS_REMAP_ACTIONS = ROOT + 'macos/platform/remap/data/actions.json';

const WIN_GESTURE_CONFIG = ROOT + 'windows/gestures/engine/config.ahk';
const WIN_GESTURE_INIT = ROOT + 'windows/gestures/engine/init.ahk';
const WIN_GESTURE_CONSTANTS = ROOT + 'windows/gestures/engine/constants.ahk';
const WIN_GESTURES_MENU = ROOT + 'windows/gestures/ui/menu/gestures.ahk';
const WIN_HOTSTRINGS_MENU = ROOT + 'windows/hotstrings/ui/menu/hotstrings.ahk';
const WIN_USER_CODE = ROOT + 'windows/hotstrings/engine/dynamic/user_code.ahk';
const WIN_INPUT_PROBE = ROOT + 'windows/diagnostics/engine/field_run/input_probe.ahk';
const WIN_AGENT_ACTION = ROOT + 'windows/ai/engine/agent/action.ahk';
const WIN_PROFILES_MENU = ROOT + 'windows/ai/ui/menu/profiles.ahk';
const WIN_PROFILE_ORDER = ROOT + 'windows/ai/engine/api/option_validation.ahk';
const WIN_SHORTCUTS_MENU = ROOT + 'windows/ui/menu/menu_shortcuts.ahk';
const WIN_API_ENTRIES = ROOT + 'windows/ai/ui/menu/api_entries.ahk';
const WIN_MAGIC_EDITOR = ROOT + 'windows/infra/magic_editor.ahk';
const WIN_TAP_KEYS = ROOT + 'windows/infra/tap_keys.ahk';
const WIN_PROXY_OVERRIDE = ROOT + 'windows/core/network/proxy_override.ahk';
const WIN_PROXY_PARSE = ROOT + 'windows/core/network/adapters/proxy_override.ahk';
const WIN_BRIGHTNESS = ROOT + 'windows/adapters/screen_brightness.ahk';
const WIN_TAP_HOLD_WRITER = ROOT + 'windows/platform/remap/tap_hold_writer.ahk';

// ==========================================
// ==========================================
// ======= 1/ Readers =======================
// ==========================================
// ==========================================

/**
 * The first group of every match of a pattern in a text, failing when none is
 * found so a renamed site cannot read as an empty family.
 * @param {string} text - The text searched.
 * @param {RegExp} pattern - A global pattern with one capture.
 * @param {string} where - What the text is, for the error.
 * @returns {string[]}
 */
function capture(text, pattern, where) {
	const found = [...new Set(Array.from(text.matchAll(pattern), (m) => m[1]))];
	if (found.length === 0) throw new Error(`${where}: ${pattern} matches nothing`);
	return found;
}

/**
 * The source of one top-level function: from its header to the first closing
 * line at column 0 (`}` in AutoHotkey, `end` in Lua). The literals a function
 * returns are the ids when no table names them.
 * @param {string} rel - Repository-relative path.
 * @param {string} header - The text that opens the function, e.g. `_IP_Admission(`.
 * @returns {string}
 */
function functionBody(rel, header) {
	const text = ctx.read(rel);
	const start = text.search(new RegExp('^' + header.replace(/[.()$]/g, '\\$&'), 'm'));
	if (start < 0) throw new Error(`${rel} defines no ${header}`);
	const close = rel.endsWith('.lua') ? /^end\b/m : /^\}/m;
	const end = text.slice(start).search(close);
	if (end < 0) throw new Error(`${rel}: ${header} is not closed`);
	return text.slice(start, start + end);
}

/**
 * The single-fire actions of the shared catalogue, headers excluded: a header
 * row is a picker heading, never an action a site labels.
 * @returns {string[]}
 */
function catalogueActions() {
	const actions = ctx.toml(ACTIONS_TOML).sg_actions;
	return Object.keys(actions).filter((id) => actions[id].is_header !== true);
}

/**
 * The feature ids of one features-manifest section. The manifest nests
 * arrays of tables ([[features.shortcuts]] then
 * [[features.shortcuts.caps_word.pointer]]), so a TOML parser files each
 * deeper array under the last element of the one above it: every element of
 * each level is searched.
 * @param {string[]} section - The section path under [features].
 * @returns {string[]}
 */
function manifestFeatures(section) {
	let nodes = [ctx.toml(FEATURES_MANIFEST).features];
	for (const name of section) nodes = nodes.flatMap((node) => [].concat(node[name] ?? []));
	const ids = nodes.map((entry) => entry.id).filter((id) => typeof id === 'string');
	if (ids.length === 0)
		throw new Error(`${FEATURES_MANIFEST} declares no features.${section.join('.')}`);
	return ids;
}

/**
 * The placeholders of every catalogue address and the optional address field:
 * the values the add-entry form asks for, each labelled by its name.
 * @returns {{fields: string[], optional: string[]}}
 */
function apiAddressFields() {
	const fields = new Set();
	const optional = new Set();
	for (const provider of Object.values(ctx.json(API_PROVIDERS).providers)) {
		for (const m of String(provider.base_url || '').matchAll(/\{([a-z0-9_]+)\}/g)) fields.add(m[1]);
		if (provider.optional_address) optional.add(provider.optional_address.field);
	}
	if (fields.size === 0 || optional.size === 0)
		throw new Error(`${API_PROVIDERS} holds no address template or optional address`);
	return { fields: [...fields, ...optional], optional: [...optional] };
}

/**
 * Every reason the input probe can abort with: the literals its admission
 * checks return and every literal assigned to a reason.
 * @returns {string[]}
 */
function inputProbeReasons() {
	const returned = ['_IP_Admission(', '_IP_TryAcquire(', '_IP_TargetAdmission('].flatMap((header) =>
		capture(functionBody(WIN_INPUT_PROBE, header), /return "(\w+)"/g, header)
	);
	// The right-hand side only, and no subscript: `Result["reason"] := Before["reason"]`
	// copies a reason, it names none.
	const assignments = capture(
		ctx.read(WIN_INPUT_PROBE),
		/(?:\["reason"\]|\bReason) :=([^\n]*"\w+"[^\n]*)/g,
		WIN_INPUT_PROBE
	);
	const assigned = assignments.flatMap((rhs) =>
		Array.from(rhs.matchAll(/(?<!\[)"(\w+)"(?!\])/g), (m) => m[1])
	);
	return [...returned, ...assigned];
}

/**
 * Every reason the physical magic editor's row can show: the decision reasons
 * of the shared Lua core and its AutoHotkey port, the source-selection reasons,
 * and the macOS owner's own early answers.
 * @returns {string[]}
 */
function magicEditorReasons() {
	return [
		...capture(ctx.read(MAGIC_CORE_LUA), /decision\.reason = "(\w+)"/g, MAGIC_CORE_LUA),
		...capture(ctx.read(MAGIC_CORE_LUA), /return nil, "(\w+)"/g, MAGIC_CORE_LUA),
		...capture(
			ctx.read(MAGIC_CORE_AHK),
			/(?:"reason", |Decision\["reason"\] := )"(\w+)"/g,
			MAGIC_CORE_AHK
		),
		// The source selection's last reason is a ternary chain.
		...capture(ctx.read(MAGIC_CORE_AHK), /[?:] "(source_\w+)"/g, MAGIC_CORE_AHK),
		...capture(
			functionBody(MACOS_MAGIC_EDITOR, 'function M.reason('),
			/return "(\w+)"/g,
			MACOS_MAGIC_EDITOR
		)
	];
}

// ==========================================
// ==========================================
// ======= 2/ Families ======================
// ==========================================
// ==========================================

const SEND_INPUT_SPECS = () => [
	...Object.keys(ctx.literal(SHARED_SEND_INPUT, 'M.KINDS')),
	...Object.keys(ctx.literal(LINUX_GESTURES, 'SEND_INPUT_KINDS'))
];

module.exports = [
	{
		prefix: 'category.',
		files: [LINUX_HOTSTRINGS],
		source:
			'the hotstring group ids of menu.toml [menu.hotstring_groups] outside the language packs of ' +
			'_index.toml (those are named by their own pack description), and the PERSONAL_CATEGORY id',
		keys: () => {
			const languages = ctx.toml(HOTSTRING_INDEX).languages.order;
			const groups = Object.values(ctx.toml(MENU_TOML).menu.hotstring_groups)
				.flat()
				.filter((id) => !languages.some((language) => id.startsWith(language + '_')));
			const personal = capture(
				ctx.read(LINUX_HOTSTRINGS),
				/local PERSONAL_CATEGORY = "(\w+)"/g,
				LINUX_HOTSTRINGS
			);
			return ctx.keysOf('category.', [...groups, ...personal]);
		}
	},
	{
		prefix: 'dialog.gestures.param_',
		files: [LINUX_GESTURES, MACOS_GESTURE_ACTIONS, WIN_GESTURE_CONFIG],
		source:
			'the send-input parameter kinds of _shared/platform/input/send_input.lua and SEND_INPUT_KINDS',
		keys: () => ctx.keysOf('dialog.gestures.param_', SEND_INPUT_SPECS())
	},
	{
		prefix: 'dialog.gestures.param_err_',
		files: [LINUX_GESTURES, MACOS_GESTURE_ACTIONS, WIN_GESTURE_CONFIG],
		source:
			'the send-input parameter kinds of _shared/platform/input/send_input.lua and SEND_INPUT_KINDS',
		keys: () => ctx.keysOf('dialog.gestures.param_err_', SEND_INPUT_SPECS())
	},
	{
		prefix: 'gesture.slots.',
		files: [
			LINUX_GESTURES,
			LINUX_CONFLICTS,
			MACOS_GESTURES_MENU,
			WIN_GESTURE_CONFIG,
			WIN_GESTURE_INIT,
			WIN_GESTURES_MENU
		],
		source: 'the slot key-space of actions.toml [slots] and the Windows GestureSlotIds() table',
		keys: () => {
			const slots = ctx.toml(ACTIONS_TOML).slots;
			return ctx.keysOf('gesture.slots.', [
				...slots.single,
				...slots.axis,
				...ctx.literal(WIN_GESTURE_CONSTANTS, 'Slots')
			]);
		}
	},
	{
		prefix: 'hs_config.label_',
		files: [WIN_HOTSTRINGS_MENU],
		source: 'the field names the personal-file menu rows pass to _HS_PromptPersonalFileField',
		keys: () =>
			ctx.keysOf(
				'hs_config.label_',
				ctx.matches(WIN_HOTSTRINGS_MENU, /_HS_PromptPersonalFileField\(Owner, Section, "(\w+)"\)/g)
			)
	},
	{
		prefix: 'input_probe.hook_',
		files: [WIN_INPUT_PROBE],
		source: 'the phase orders InputProbe_HookPhaseOrder returns',
		keys: () =>
			ctx.keysOf(
				'input_probe.hook_',
				capture(
					functionBody(WIN_INPUT_PROBE, 'InputProbe_HookPhaseOrder('),
					/"(\w+)"/g,
					WIN_INPUT_PROBE
				)
			)
	},
	{
		prefix: 'input_probe.hook_changed_',
		files: [WIN_INPUT_PROBE],
		source: 'the changed verdicts InputProbe_HookVerdict assigns, less the one the dialog skips',
		keys: () => {
			const skipped = ctx.matches(WIN_INPUT_PROBE, /Verdict\["changed"\] != "(\w+)"/g);
			const verdicts = ctx.matches(WIN_INPUT_PROBE, /Verdict\["changed"\] := "(\w+)"/g);
			return ctx.keysOf(
				'input_probe.hook_changed_',
				verdicts.filter((id) => !skipped.includes(id))
			);
		}
	},
	{
		prefix: 'input_probe.reason.',
		files: [WIN_INPUT_PROBE],
		source: 'the reasons the probe admission checks return and every reason literal it assigns',
		keys: () => ctx.keysOf('input_probe.reason.', inputProbeReasons())
	},
	{
		prefix: 'input_probe.scenario.',
		files: [WIN_INPUT_PROBE],
		source: 'the scenario ids _IP_Scenarios builds',
		keys: () =>
			ctx.keysOf(
				'input_probe.scenario.',
				capture(
					functionBody(WIN_INPUT_PROBE, '_IP_Scenarios('),
					/Map\("id", "(\w+)"/g,
					WIN_INPUT_PROBE
				)
			)
	},
	{
		prefix: 'llm.agent.done_',
		files: [WIN_AGENT_ACTION],
		source: 'the action types of the switch case that builds the key',
		keys: () => {
			const cases = capture(
				ctx.read(WIN_AGENT_ACTION),
				/case ((?:"\w+",?\s*)+):\s*\n[^\n]*t\("llm\.agent\.done_" \./g,
				WIN_AGENT_ACTION
			);
			return ctx.keysOf(
				'llm.agent.done_',
				cases.flatMap((line) => capture(line, /"(\w+)"/g, WIN_AGENT_ACTION))
			);
		}
	},
	{
		prefix: 'llm.profile.',
		files: [MACOS_PROFILES, WIN_PROFILES_MENU],
		source:
			'the built-in profile ids of _shared/ai/data/profiles.json and LLM_PROFILE_BUILTIN_ORDER',
		keys: () =>
			[
				...ctx.json(PROFILES_JSON).map((profile) => profile.id),
				...ctx.literal(WIN_PROFILE_ORDER, 'LLM_PROFILE_BUILTIN_ORDER')
			]
				.map((id) => `llm.profile.${id}.label`)
				.filter((key, index, keys) => keys.indexOf(key) === index)
	},
	{
		prefix: 'menu.caps_word.pointer.',
		files: [WIN_SHORTCUTS_MENU],
		source: 'the pointer kinds of the features manifest [[features.shortcuts.caps_word.pointer]]',
		keys: () =>
			ctx.keysOf('menu.caps_word.pointer.', manifestFeatures(['shortcuts', 'caps_word', 'pointer']))
	},
	{
		prefix: 'menu.debug.',
		files: [DEBUG_REPORT],
		source: 'the debug menu rows of the menu_slots table',
		keys: () => ctx.keysOf('menu.debug.', Object.keys(ctx.literal(DEBUG_REPORT, 'menu_slots')))
	},
	{
		prefix: 'menu.hotstrings.user_code.problem_',
		files: [WIN_HOTSTRINGS_MENU],
		source: 'the problem values of USER_HOTSTRINGS_SOURCE_PROBLEMS',
		keys: () => {
			const table = capture(
				ctx.read(WIN_USER_CODE),
				/USER_HOTSTRINGS_SOURCE_PROBLEMS := Map\(([^)]*)\)/g,
				WIN_USER_CODE
			)[0];
			// Map(kind, problem, ...): the problems are the values, every second literal.
			const literals = Array.from(table.matchAll(/"([^"]*)"/g), (m) => m[1]);
			return ctx.keysOf(
				'menu.hotstrings.user_code.problem_',
				literals.filter((_, index) => index % 2 === 1)
			);
		}
	},
	{
		prefix: 'menu.llm.',
		files: [LINUX_BACKEND_ROWS],
		source: 'the failure kinds and the body/title suffixes the API failure dialog joins',
		keys: () => {
			const text = ctx.read(LINUX_BACKEND_ROWS);
			const kinds = capture(
				text,
				/local kind = [^\n]* and "(\w+)" or "\w+"/g,
				LINUX_BACKEND_ROWS
			).concat(capture(text, /local kind = [^\n]* and "\w+" or "(\w+)"/g, LINUX_BACKEND_ROWS));
			const suffixes = capture(
				text,
				/tr\("menu\.llm\." \.\. kind \.\. "(\w+)"\)/g,
				LINUX_BACKEND_ROWS
			);
			return ctx.keysOf(
				'menu.llm.',
				kinds.flatMap((kind) => suffixes.map((suffix) => kind + suffix))
			);
		}
	},
	{
		prefix: 'menu.llm.api_prompt_field.',
		files: [LINUX_BACKEND_ROWS, MACOS_API_PANEL, WIN_API_ENTRIES],
		source:
			'the address placeholders and optional address fields of _shared/ai/data/api_providers.json',
		keys: () => ctx.keysOf('menu.llm.api_prompt_field.', apiAddressFields().fields)
	},
	{
		prefix: 'menu.llm.api_prompt_field_invalid.',
		files: [LINUX_BACKEND_ROWS, MACOS_API_PANEL, WIN_API_ENTRIES],
		source: 'the optional address fields of _shared/ai/data/api_providers.json',
		keys: () => ctx.keysOf('menu.llm.api_prompt_field_invalid.', apiAddressFields().optional)
	},
	{
		prefix: 'menu.shortcuts.keyboard.magic_editor_reason.',
		files: [MACOS_KEYBOARD_SHORTCUTS, WIN_MAGIC_EDITOR],
		source:
			'the decision and source reasons of the shared magic editor policy (Lua and AHK) and M.reason()',
		keys: () => ctx.keysOf('menu.shortcuts.keyboard.magic_editor_reason.', magicEditorReasons())
	},
	{
		prefix: 'menu.shortcuts.tap_keys.',
		files: [LINUX_TAP_KEYS, MACOS_TAP_KEYS, WIN_TAP_KEYS],
		source: 'the key ids of _shared/shortcuts/data/actions/tap_keys.json and TAP_KEY_ORDER',
		keys: () =>
			ctx.keysOf('menu.shortcuts.tap_keys.', [
				...ctx.json(TAP_KEYS_JSON).keys.map((key) => key.id),
				...ctx.literal(WIN_TAP_KEYS, 'TAP_KEY_ORDER')
			])
	},
	{
		prefix: 'proxy_override.saved_',
		files: [WIN_PROXY_OVERRIDE],
		source: 'the modes ProxyOverride_Parse returns',
		keys: () =>
			ctx.keysOf(
				'proxy_override.saved_',
				capture(
					functionBody(WIN_PROXY_PARSE, 'ProxyOverride_Parse('),
					/Map\("mode", "(\w+)"/g,
					WIN_PROXY_PARSE
				)
			)
	},
	{
		prefix: 'remap.category.',
		files: [MACOS_REMAP],
		source:
			'the categories of macos/platform/remap/data/actions.json and of the appended modifier chords',
		keys: () =>
			ctx.keysOf('remap.category.', [
				...ctx
					.json(MACOS_REMAP_ACTIONS)
					.map((action) => action.category)
					.filter((category) => category !== undefined),
				...ctx.matches(MACOS_REMAP, /category = "(\w+)"/g)
			])
	},
	{
		prefix: 'sg_actions.',
		files: [LINUX_PREDICTION, LINUX_TAP_HOLDS_MENU, WIN_BRIGHTNESS],
		source:
			'the [sg_actions.*] of actions.toml, the VISION_ACTIONS and agent actions of the Linux engine, ' +
			'and the actions of brightness.json',
		keys: () => {
			const engine = ctx.read(LINUX_PREDICTION);
			return ctx.keysOf('sg_actions.', [
				...catalogueActions(),
				...Object.keys(ctx.literal(LINUX_PREDICTION, 'VISION_ACTIONS')),
				...capture(engine, /local AGENT_\w+_ACTION = "(\w+)"/g, LINUX_PREDICTION),
				...Object.keys(ctx.json(BRIGHTNESS).actions)
			]);
		}
	},
	{
		prefix: 'sg_labels.',
		files: [LINUX_SHORTCUTS_MENU],
		source: 'the slot ids of _shared/shortcuts/data/actions/script_chords.json',
		keys: () =>
			ctx.keysOf(
				'sg_labels.',
				ctx.json(SCRIPT_CHORDS).slots.map((slot) => slot.id)
			)
	},
	{
		prefix: 'shortcuts.',
		files: [LINUX_LAYOUTS_MENU],
		source:
			'the accented shortcut ids of accented_shortcuts.lua M.IDS, underscores removed as the menu does',
		keys: () =>
			ctx.keysOf(
				'shortcuts.',
				ctx.literal(LINUX_ACCENTED, 'M.IDS').map((id) => id.replace(/_/g, ''))
			)
	},
	{
		prefix: 'tap_hold.hold.',
		files: [WIN_TAP_HOLD_WRITER],
		source: 'the layers of [tap_hold.hold_picker] in _shared/tap_hold/data/defaults.toml',
		keys: () =>
			ctx
				.toml(TAP_HOLD_DEFAULTS)
				.tap_hold.hold_picker.layers.map((id) => `tap_hold.hold.${id}_layer`)
	}
];
