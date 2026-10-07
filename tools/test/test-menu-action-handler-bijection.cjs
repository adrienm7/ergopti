// tools/test/test-menu-action-handler-bijection.cjs

/**
 * ==============================================================================
 * MODULE: Menu Action ↔ Handler Bijection (I3)
 * DESCRIPTION:
 * Every `action` or `dynamic` row the manifest declares for a platform must have
 * a handler named in that driver. Windows is held at **zero** unresolved rows;
 * macOS and Linux are frozen at their current gap so it cannot grow.
 *
 * WHAT AN UNRESOLVED ROW DOES:
 * The manifest says the user gets a row. The renderer looks up a handler by id,
 * finds none, and — depending on the driver — logs a warning nobody reads or
 * renders a row that does nothing when clicked. Neither raises. The row is in
 * the manifest, so every manifest-reading gate is satisfied; it just does not
 * work.
 *
 * WHY WINDOWS IS ZERO AND THE OTHERS ARE NOT:
 * Windows renders its menu from the manifest and resolves all 38 of its declared
 * action rows. macOS renders part of its menu that way and leaves 20 unresolved.
 * Linux renders **none** of it: the manifest carries no `linux` platform value
 * anywhere (27 rows are `[ahk]`, 19 `[hs]`, 2 both), so its 27 rows are visible
 * to Linux only because an unrestricted row defaults to every platform — while
 * `ui/menu/menu_builder.lua` builds its 97 rows by hand.
 *
 * That gap is the I2/I3 migration, not a defect to fix here. Freezing it is what
 * this guard is for: Windows cannot regress from zero, and the other two cannot
 * drift further from the manifest while the migration proceeds. Lower these
 * baselines as rows are wired. Never raise them.
 *
 * WHAT THIS DOES NOT PROVE:
 * A row counts as handled when its id appears as a quoted string anywhere in the
 * driver's production source. That is a **necessary** condition, not a
 * sufficient one — it catches the case this guard is for, a manifest row no
 * driver mentions at all, and it will NOT catch a handler renamed away while the
 * same id survives elsewhere in the file (`MenuRenderer_ResolveDisabledWhen(…,
 * "shortcut_typing", …)` on the next line keeps it "named").
 *
 * A tighter "the id must be bound to a callable on the same line" rule was tried
 * and rejected: it reported `"tap_hold_keys", _TH_DynKeys,` as unbound, because
 * that handler is a function REFERENCE rather than a lambda. Distinguishing a
 * handler-map entry from a call argument needs a parser, not a regex, and a
 * predicate that flags correct bindings is worse than a coarse one — the change
 * it demands is to rewrite working code. The floors below are what keep the
 * coarse version honest: if the scan stops matching, it fails instead of
 * reporting everything resolved.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const { scriptTokens } = require('../lib/script-source.cjs');
const { publishesMenuTemplate } = require('../lib/menu-shared-delegation.cjs');
const { delegatedMenuSources } = require('../lib/menu-shared-delegation.cjs');

const { nativeTemplateBinding } = require('../lib/menu-template-binding.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');

// Frozen baselines — declared rows with no handler named, on 2026-08-01.
// 2026-08-04: hs 20 → 16, linux 27 → 10. Two different kinds of progress, and
// the distinction matters more than the numbers.
//
// SIX of the eleven that came off Linux are real handlers: its metrics submenu
// is the first on that driver to render from the manifest at all, with
// disabled_when and checked_when resolved declaratively instead of re-derived.
//
// The rest came off BOTH Lua drivers, because the rows could never have been
// rendered on either: each enumerates features the FEATURE manifest already
// declares platforms = ["ahk"]. layout_features_base and layout_features_altgr
// list features.layout.*, all five of which are ahk. script_control_shortcuts
// lists features.shortcuts.script_control, all four ahk. extensions_shortcuts
// walks a Windows extensions directory. And seven metrics rows configure the WPM
// widget, the two window shortcuts and the app-exclusion list — none of which
// exists on Linux, where ui/wpm is absent and the keylogger exposes no
// disabled-apps setter. A row declared for a driver that cannot draw it is not a
// gap in the driver; it is the manifest making a promise on the driver's behalf.
// hs 5 → 4 on 2026-08-06: `hotstring_bulk_actions` was one row that expanded
// to two, and macOS had no handler for the id at all — it built its bulk rows
// by hand in builder.lua and the manifest's promise went unanswered. Splitting
// it into two `command` rows is what let the declaration and the driver meet.
// ── ahk 0 → 1 and hs 4 → 7 on 2026-08-06, and NEITHER is a regression ──
//
// Read the filter before reading the numbers. Until today this gate looked only
// at `action` and `dynamic` rows, so every `list` row in the manifest was
// invisible to it — and `list` is what a repeated block becomes. Widening the
// set to every type that names a behaviour (BEHAVIOUR_TYPES below) is what
// revealed these, and all of them predate the migration that prompted the
// widening:
//
//   ahk llm_menu.llm_models — Windows does not read `llm_menu` from the
//     manifest at all; it builds its LLM menu by hand under ui/menu/menu_llm/.
//     Two rows declared for every platform, answered by one driver.
//   hs — the same llm_models, layout_menu.active_layouts, and the five
//     hotstrings rows, because macOS assembles its hotstrings menu by hand in
//     ui/menu/builder.lua and reads the manifest for none of it.
//
// So the honest number rose while the code improved, exactly as the row-bypass
// ratchet's own linux 2 → 124 did when ITS definition was corrected. Lower these
// by wiring the rows or by putting those two menus on the renderer — never by
// narrowing the filter again.
// hs 7 → 6: active_layouts is answered now — macOS's keyboard-layout menu
// renders the manifest's own rows through the shared renderer instead of
// building that list in place.
// hs 6 → 5: llm_models is answered — macOS places its model row through the
// shared renderer now instead of inserting it in place.
// ahk 1 → 0: `llm_models` and `llm_generation` were declared for every platform
// while only Linux ever drew them, so Windows was promised two rows it has never
// had. They say platforms = ["linux"] now, and the eight rows Windows DOES draw
// are declared beside them — the IA menu's second shared description folded into
// the manifest. Windows answers every row the manifest offers it.
// hs 5 → 0: the hotstrings submenu reads the manifest. Those five were its five
// declared `list` rows — the standard, dynamic, ergopti, personal and extension
// category blocks — which this driver assembled by hand while the declaration
// named slots nothing filled. Every row every driver declares is answered now.
const BASELINE = { ahk: 0, hs: 0, linux: 0 };

// The manifest types that name a behaviour the driver must register: `action`
// and `dynamic` hand the id to a handler, `list` to a provider, `check` and
// `command` to a named command. A row of any other type is drawn from the
// declaration alone and has nothing for a driver to miss.
const BEHAVIOUR_TYPES = new Set(['action', 'dynamic', 'list', 'check', 'command', 'choice']);

// WHY LINUX IS ZERO AND macOS IS NOT, AND WHAT THE FIVE ARE.
// Linux reached zero by wiring every row: its metrics and hotstrings submenus
// render from the manifest, and the rows it could never draw were restricted
// away with reasons. macOS wired its hotstrings-parameters group the same way
// and stopped at five, for a reason worth writing down rather than re-deriving:
//
//   hotstring_bulk_actions, hotstring_categories_{standard,dynamic,ergopti}
//     macOS assembles this submenu in a DIFFERENT SHAPE from the manifest. Its
//     section headers carry live counts (menu.hotstrings.header_common_count,
//     formatted with a total) where a manifest section_header is a static key,
//     and it merges the standard and dynamic categories into one non-Ergopti
//     block. Making the three ids true means reshaping the menu the user sees —
//     three categories with plain headers — or teaching section_header to carry
//     a count. Either is a product decision, not a wiring job.
//
//   active_layouts
//     Built by hand in menu_keyboard_layout.lua, which does not go through the
//     renderer at all. One handler once that submenu is routed.
//
// A CAUTION FROM THE SAME PASS. An unresolved id does NOT mean the driver lacks
// the feature. Seven macOS rows counted here were handled all along — their
// dispatch tables used bare Lua keys, which this scan cannot see because it
// looks for a quoted string. Quoting them changed nothing but the count. Worse,
// magic_key_config was read as "no Lua driver can edit the magic key" and nearly
// restricted out of the macOS menu it has always been in: the row is built
// inline in menu_hotstrings_management, id unnamed. Check the driver before
// concluding anything from a number here.

// Floors: a driver whose scan collapses would report zero unresolved rows and
// pass while having read nothing.
// linux 20 → 12 on 2026-08-04. The floor guards against a broken manifest walk,
// which would report ~0 declared rows; it is not a target. Eleven rows were
// restricted away from this driver in the same pass because they enumerate
// ahk-only features, so the honest declared count fell to 16 and a floor of 20
// would have failed on correct data. Twelve still separates "16 real rows" from
// "the walk returned nothing".
const MIN_DECLARED = { ahk: 30, hs: 30, linux: 12 };

const PLATFORMS = [
	{ key: 'ahk', driver: 'windows', ext: '.ahk' },
	{ key: 'hs', driver: 'macos', ext: '.lua' },
	{ key: 'linux', driver: 'linux', ext: '.lua' }
];

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const sections = Object.entries(manifest).filter(
	([k, v]) => !k.startsWith('_') && Array.isArray(v)
);

/** A row with no `platforms` list is visible everywhere — that is the documented default. */
function visibleOn(entry, platform) {
	if (!Array.isArray(entry.platforms)) return true;
	return entry.platforms.includes(platform);
}

/** Credits actual bare callback references only in a reached renderer command table. */
function nativeFunctionReferenceKeys(source) {
	const tokens = scriptTokens(source, '.lua'),
		scopes = [],
		stack = [],
		functions = [],
		result = new Set();
	let nextScope = 0;
	for (let i = 0; i < tokens.length; i++) {
		scopes[i] = stack.slice();
		if (tokens[i].kind !== 'identifier') continue;
		const word = tokens[i].value;
		if (word === 'elseif' || word === 'else') stack.pop();
		if (['function', 'do', 'then', 'repeat', 'else'].includes(word)) stack.push(++nextScope);
		if (word === 'end' || word === 'until') stack.pop();
	}
	const ancestor = (parent, child) =>
		parent.length <= child.length && parent.every((id, i) => id === child[i]);
	for (let i = 0; i + 4 < tokens.length; i++) {
		if (
			tokens[i].kind !== 'identifier' ||
			tokens[i].value !== 'local' ||
			tokens[i + 1]?.kind !== 'identifier' ||
			tokens[i + 1].value !== 'function' ||
			tokens[i + 2]?.kind !== 'identifier' ||
			tokens[i + 3]?.kind !== 'symbol' ||
			tokens[i + 3].value !== '('
		)
			continue;
		let cursor = i + 4,
			depth = 1;
		for (; cursor < tokens.length && depth; cursor++) {
			if (tokens[cursor].kind === 'symbol' && tokens[cursor].value === '(') depth++;
			if (tokens[cursor].kind === 'symbol' && tokens[cursor].value === ')') depth--;
		}
		if (depth === 0 && tokens[cursor] && tokens[cursor].value !== 'end')
			functions.push({ name: tokens[i + 2].value, declared: i, body: cursor, scope: scopes[i] });
	}
	function withdrawn(fn, call) {
		for (let i = fn.body; i < call; i++) {
			if (tokens[i].kind !== 'identifier') continue;
			if (tokens[i].value === 'local') {
				let cursor = i + 1;
				if (tokens[cursor]?.value === 'function') cursor++;
				while (tokens[cursor]?.kind === 'identifier') {
					if (tokens[cursor].value === fn.name) return true;
					if (tokens[cursor + 1]?.value !== ',') break;
					cursor += 2;
				}
			}
			if (tokens[i].value === 'function') {
				let cursor = i + 1;
				while (cursor < call && tokens[cursor].value !== '(') cursor++;
				for (cursor++; cursor < call && tokens[cursor].value !== ')'; cursor++)
					if (tokens[cursor].kind === 'identifier' && tokens[cursor].value === fn.name) return true;
			}
			if (tokens[i].value !== fn.name || ['.', ':'].includes(tokens[i - 1]?.value)) continue;
			let cursor = i + 1;
			while (tokens[cursor]?.value === ',' && tokens[cursor + 1]?.kind === 'identifier')
				cursor += 2;
			if (tokens[cursor]?.kind === 'symbol' && tokens[cursor].value === '=') return true;
		}
		return false;
	}
	for (let i = 0; i + 7 < tokens.length; i++) {
		if (
			tokens[i].kind !== 'identifier' ||
			tokens[i].value !== 'ManifestMenu' ||
			['.', ':', 'function'].includes(tokens[i - 1]?.value) ||
			tokens[i + 1]?.kind !== 'symbol' ||
			tokens[i + 1].value !== '.' ||
			tokens[i + 2]?.kind !== 'identifier' ||
			tokens[i + 2].value !== 'template_rows' ||
			tokens[i + 3]?.kind !== 'symbol' ||
			tokens[i + 3].value !== '(' ||
			tokens[i + 4]?.kind !== 'string' ||
			tokens[i + 5]?.kind !== 'symbol' ||
			tokens[i + 5].value !== ',' ||
			tokens[i + 6]?.kind !== 'symbol' ||
			tokens[i + 6].value !== '{' ||
			!publishesMenuTemplate(source, '.lua', tokens[i + 4].value)
		)
			continue;
		const entries = [],
			keys = new Set();
		let cursor = i + 7,
			ambiguous = false;
		while (cursor < tokens.length && tokens[cursor].value !== '}') {
			let key;
			if (tokens[cursor]?.kind === 'identifier' && tokens[cursor + 1]?.value === '=') {
				key = tokens[cursor].value;
				cursor += 2;
			} else if (
				tokens[cursor]?.kind === 'symbol' &&
				tokens[cursor].value === '[' &&
				tokens[cursor + 1]?.kind === 'string' &&
				tokens[cursor + 2]?.kind === 'symbol' &&
				tokens[cursor + 2].value === ']' &&
				tokens[cursor + 3]?.value === '='
			) {
				const spelling = source.slice(tokens[cursor + 1].start, tokens[cursor + 1].end);
				if (
					!['"', "'"].includes(spelling[0]) ||
					spelling.at(-1) !== spelling[0] ||
					spelling.includes('\\')
				) {
					ambiguous = true;
					break;
				}
				key = tokens[cursor + 1].value;
				cursor += 4;
			} else {
				ambiguous = true;
				break;
			}
			if (keys.has(key)) {
				ambiguous = true;
				break;
			}
			keys.add(key);
			const value = cursor;
			let depth = 0;
			for (; cursor < tokens.length; cursor++) {
				const token = tokens[cursor];
				if (token.kind === 'symbol' && depth === 0 && [',', ';', '}'].includes(token.value)) break;
				if (token.kind === 'symbol' && ['{', '(', '['].includes(token.value)) depth++;
				if (token.kind === 'symbol' && ['}', ')', ']'].includes(token.value)) depth--;
				// A function expression is a supported ordinary binding but ambiguous to
				// this extra reference-only proof. The original quoted-id scan remains.
				if (token.kind === 'identifier' && token.value === 'function') {
					ambiguous = true;
					break;
				}
			}
			if (ambiguous || depth !== 0 || !tokens[cursor]) {
				ambiguous = true;
				break;
			}
			if (cursor === value + 1 && tokens[value]?.kind === 'identifier')
				entries.push({ key, name: tokens[value].value });
			if (tokens[cursor].value === '}') break;
			cursor++;
		}
		if (ambiguous || tokens[cursor]?.kind !== 'symbol' || tokens[cursor].value !== '}') continue;
		for (const entry of entries) {
			const candidates = functions.filter(
				(fn) => fn.name === entry.name && fn.body < i && ancestor(fn.scope, scopes[i])
			);
			if (candidates.length !== 1 || withdrawn(candidates[0], i)) continue;
			result.add(entry.key);
		}
	}
	return result;
}
{
	const source =
		'local function actual_callback() return real_owner() end\nManifestMenu.template_rows("frame", { actual_row = actual_callback }, {}, {})';
	assert.equal(nativeFunctionReferenceKeys(source).has('actual_row'), true);
	for (const changed of [
		source.replace('actual_row = actual_callback', 'actual_row = "actual_callback"'),
		source.replace('actual_row = actual_callback', 'actual_row = Foreign.actual_callback'),
		source.replace('return real_owner()', ''),
		source.replace('ManifestMenu.template_rows', 'Foreign.ManifestMenu.template_rows'),
		source.replace('ManifestMenu.template_rows', '-- ManifestMenu.template_rows'),
		source.replace(
			'ManifestMenu.template_rows',
			'actual_callback = nil; ManifestMenu.template_rows'
		)
	])
		assert.equal(nativeFunctionReferenceKeys(changed).has('actual_row'), false);

	for (const changed of [
		source.replace(
			'ManifestMenu.template_rows',
			'local actual_callback; ManifestMenu.template_rows'
		),
		source.replace(
			'ManifestMenu.template_rows',
			'local other, actual_callback; ManifestMenu.template_rows'
		),
		source.replace(
			'ManifestMenu.template_rows',
			'local other; actual_callback, other = nil, nil; ManifestMenu.template_rows'
		),
		source.replace(
			'{ actual_row = actual_callback }',
			'{ actual_row = actual_callback, actual_row = nil }'
		),
		source.replace(
			'{ actual_row = actual_callback }',
			'{ actual_row = actual_callback, ["actual_row"] = nil }'
		),
		source.replace(
			'{ actual_row = actual_callback }',
			'{ actual_row = actual_callback, [chosen] = nil }'
		),
		source.replace(
			'local function actual_callback() return real_owner() end',
			'do local function actual_callback() return real_owner() end end'
		),
		source.replace(
			'ManifestMenu.template_rows',
			'local function other_owner(actual_callback) return ManifestMenu.template_rows'
		) + ' end'
	])
		assert.equal(nativeFunctionReferenceKeys(changed).has('actual_row'), false);
	const actual = fs.readFileSync(path.join(SP, 'macos/ui/menu/menu_hotstrings_custom.lua'), 'utf8');
	assert.equal(nativeFunctionReferenceKeys(actual).has('personal_legacy_shortcut'), true);
	for (const changed of [
		actual.replace('local legacy_rows = {}', 'local sc_fn\n\tlocal legacy_rows = {}'),
		actual.replace(
			'{ personal_legacy_shortcut = sc_fn }',
			String.raw`{ personal_legacy_shortcut = sc_fn, ["personal_legacy_short\099ut"] = nil }`
		),
		actual.replace(
			'{ personal_legacy_shortcut = sc_fn }',
			'{ personal_legacy_shortcut = sc_fn, [ [=[personal_legacy_shortcut]=] ] = nil }'
		),
		actual.replace('local legacy_rows = {}', 'local other, sc_fn\n\tlocal legacy_rows = {}'),
		actual.replace(
			'{ personal_legacy_shortcut = sc_fn }',
			'{ personal_legacy_shortcut = sc_fn, personal_legacy_shortcut = nil }'
		),
		actual.replace(
			'{ personal_legacy_shortcut = sc_fn }',
			'{ personal_legacy_shortcut = sc_fn, ["personal_legacy_shortcut"] = nil }'
		),
		actual.replace(
			'{ personal_legacy_shortcut = sc_fn }',
			'{ personal_legacy_shortcut = sc_fn, [chosen] = nil }'
		)
	])
		assert.equal(nativeFunctionReferenceKeys(changed).has('personal_legacy_shortcut'), false);

	for (const changed of [
		actual.replace(
			'{ personal_legacy_shortcut = sc_fn }',
			'{ personal_legacy_shortcut = "sc_fn" }'
		),
		actual.replace('local function sc_fn()', 'local function withdrawn_sc_fn()'),
		actual.replace(
			'ManifestMenu.template_rows("hotstring_personal_legacy_shortcut"',
			'Foreign.ManifestMenu.template_rows("hotstring_personal_legacy_shortcut"'
		)
	])
		assert.equal(nativeFunctionReferenceKeys(changed).has('personal_legacy_shortcut'), false);
}

// Independently authored binding controls preserve necessary static evidence.
{
	const assigned =
		'local callback = function() return real_owner() end\nManifestMenu.template_rows("actual_frame", { actual_command = callback }, {}, {})';
	assert.equal(nativeTemplateBinding(assigned, '.lua', 'actual_frame', 'actual_command', 1), true);
	for (const changed of [
		assigned.replace('actual_command = callback', 'other_command = callback'),
		assigned.replace('actual_command = callback', 'actual_command = "callback"'),
		assigned.replace('actual_command = callback', 'actual_command = Foreign.callback'),
		assigned.replace('return real_owner()', ''),
		assigned.replace('ManifestMenu.template_rows', '-- ManifestMenu.template_rows'),
		assigned.replace('ManifestMenu.template_rows', 'Foreign.ManifestMenu.template_rows'),
		assigned.replace('ManifestMenu.template_rows', 'local callback; ManifestMenu.template_rows'),
		assigned.replace(
			'ManifestMenu.template_rows',
			'local other, callback; ManifestMenu.template_rows'
		),
		assigned.replace('ManifestMenu.template_rows', 'callback = nil; ManifestMenu.template_rows'),
		assigned.replace(
			'actual_command = callback',
			'actual_command = callback, actual_command = nil'
		),
		assigned.replace(
			'actual_command = callback',
			String.raw`actual_command = callback, ["actual_\099ommand"] = nil`
		),
		assigned.replace('actual_command = callback', 'actual_command = callback, [chosen] = nil'),
		assigned.replace('actual_command = callback', '[ [=[actual_command]=] ] = callback'),
		assigned.replace(
			'local callback = function() return real_owner() end',
			'do local callback = function() return real_owner() end end'
		)
	])
		assert.equal(
			nativeTemplateBinding(changed, '.lua', 'actual_frame', 'actual_command', 1),
			false
		);
	const child =
		'ManifestMenu.template_rows("actual_frame", {}, {}, { actual_children = function() return real_children end })';
	assert.equal(nativeTemplateBinding(child, '.lua', 'actual_frame', 'actual_children', 3), true);
	for (const changed of [
		child.replace('actual_children = function', 'withdrawn = function'),
		child.replace('return real_children', ''),
		child.replace('function() return real_children end', '"not_callable"')
	])
		assert.equal(
			nativeTemplateBinding(changed, '.lua', 'actual_frame', 'actual_children', 3),
			false
		);
	const callback = 'ActualCallback(*) {\n NativeAction()\n}\n',
		ahk =
			callback +
			'Owner() {\n MenuRenderer_TemplateRows("actual_frame", Map("actual_command", ActualCallback), Map(), Map())\n}';
	assert.equal(nativeTemplateBinding(ahk, '.ahk', 'actual_frame', 'actual_command', 1), true);
	for (const changed of [
		ahk.replace('"actual_command",', '"withdrawn",'),
		ahk.replace('Map("actual_command", ActualCallback)', 'Map("actual_command", "ActualCallback")'),
		ahk.replace(
			'Map("actual_command", ActualCallback)',
			'Map("actual_command", Foreign.ActualCallback)'
		),
		ahk.replace(
			'Map("actual_command", ActualCallback)',
			'Map("actual_command", ActualCallback, "actual_command", false)'
		),
		ahk.replace(' NativeAction()', ''),
		ahk.replace(' MenuRenderer_', ' local ActualCallback\n MenuRenderer_'),
		ahk.replace(' MenuRenderer_', ' local other, ActualCallback\n MenuRenderer_'),
		ahk.replace('Owner()', 'Owner(ActualCallback)'),
		ahk.replace('Owner()', 'Owner(actualcallback)'),
		ahk.replace(' MenuRenderer_', ' LOCAL other, actualcallback\n MenuRenderer_'),
		ahk.replace(
			'Map("actual_command", ActualCallback)',
			'Map("actual_command", ActualCallback, "ACTUAL_COMMAND", false)'
		),
		ahk.replace(callback, 'Outer() {\n' + callback + '}\n'),
		ahk.replace(' MenuRenderer_', ' ActualCallback := false\n MenuRenderer_')
	])
		assert.equal(
			nativeTemplateBinding(changed, '.ahk', 'actual_frame', 'actual_command', 1),
			false
		);
	const mac = fs.readFileSync(
		path.join(SP, 'macos/ui/menu/menu_hotstrings_management.lua'),
		'utf8'
	);
	assert.equal(
		nativeTemplateBinding(mac, '.lua', 'hotstrings_magic_trigger_frame', 'magic_key_change', 1),
		true
	);
	assert.equal(
		nativeTemplateBinding(
			mac.replace('magic_key_change = magic_key_action', 'withdrawn = magic_key_action'),
			'.lua',
			'hotstrings_magic_trigger_frame',
			'magic_key_change',
			1
		),
		false
	);
	const linux = fs.readFileSync(path.join(SP, 'linux/ui/menu/menu_builder.lua'), 'utf8');
	assert.equal(
		nativeTemplateBinding(linux, '.lua', 'hotstrings_magic_trigger_frame', 'magic_key_change', 1),
		true
	);
	assert.equal(
		nativeTemplateBinding(
			linux,
			'.lua',
			'hotstrings_magic_trigger_frame',
			'magic_key_reset_if_custom',
			3
		),
		true
	);
	assert.equal(
		nativeTemplateBinding(linux, '.lua', 'hotstrings_magic_trigger_reset', 'magic_key_reset', 1),
		true
	);
	for (const [section, key, port, from, to] of [
		[
			'hotstrings_magic_trigger_frame',
			'magic_key_change',
			1,
			'magic_key_change = change',
			'withdrawn = change'
		],
		[
			'hotstrings_magic_trigger_frame',
			'magic_key_change',
			1,
			'local change = function()',
			'local change = false; local withdrawn = function()'
		],
		[
			'hotstrings_magic_trigger_reset',
			'magic_key_reset',
			1,
			'{ magic_key_reset = reset }',
			'{ magic_key_reset = "reset" }'
		],
		[
			'hotstrings_magic_trigger_frame',
			'magic_key_reset_if_custom',
			3,
			'magic_key_reset_if_custom = function()',
			'withdrawn_children = function()'
		]
	])
		assert.equal(nativeTemplateBinding(linux.replace(from, to), '.lua', section, key, port), false);
	const win = fs.readFileSync(path.join(SP, 'windows/ui/menu/menu_hotstrings.ahk'), 'utf8'),
		editor = fs.readFileSync(path.join(SP, 'windows/ui/editors.ahk'), 'utf8');
	assert.equal(
		nativeTemplateBinding(win, '.ahk', 'hotstrings_magic_trigger_frame', 'magic_key_change', 1, [
			{ src: win },
			{ src: editor }
		]),
		true
	);
	assert.equal(
		nativeTemplateBinding(
			win.replace('Map("magic_key_change", MagicKeyEditor)', 'Map("withdrawn", MagicKeyEditor)'),
			'.ahk',
			'hotstrings_magic_trigger_frame',
			'magic_key_change',
			1,
			[{ src: win }, { src: editor }]
		),
		false
	);
	assert.equal(
		nativeTemplateBinding(win, '.ahk', 'hotstrings_magic_trigger_frame', 'magic_key_change', 1, [
			{ src: win }
		]),
		false
	);
}

const errors = [];
const summary = [];

for (const { key, driver, ext } of PLATFORMS) {
	const base = path.join(SP, driver);
	if (!fs.existsSync(base)) {
		errors.push(`${driver}: driver directory is missing — its rows are unchecked`);
		continue;
	}

	// The driver's production source, as one corpus. A handler is "named" when
	// the row id appears as a quoted string: every driver dispatches by id, and
	// the id has to be written down somewhere to be dispatched on.
	const chunks = [],
		nativeSources = [];
	(function walk(dir) {
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'tests' && e.name !== 'vendor' && e.name !== 'node_modules') walk(p);
			} else if (path.extname(e.name) === ext) {
				const src = fs.readFileSync(p, 'utf8');
				chunks.push(src);
				nativeSources.push({ rel: path.relative(base, p), src });
			}
		}
	})(base);
	const delegated = delegatedMenuSources(nativeSources, path.join(SP, '_shared', 'lua'));
	const sharedHandlers = new Set(delegated.flatMap((source) => [...source.handlers]));
	const nativeReferences =
		ext === '.lua'
			? new Set(nativeSources.flatMap((source) => [...nativeFunctionReferenceKeys(source.src)]))
			: new Set();
	const corpus = chunks.concat(delegated.map((source) => source.src)).join('\n');

	if (chunks.length < 20) {
		errors.push(`${driver}: read only ${chunks.length} source file(s) — the scan is broken`);
		continue;
	}

	const declared = [];
	for (const [section, rows] of sections) {
		for (const row of rows) {
			if (!row || typeof row !== 'object') continue;
			// Every id-bearing type whose behaviour the driver has to supply.
			//
			// Was `action` and `dynamic` alone, and that made the floor below
			// measure the OLD shape: each migration to `list`, `check` or
			// `command` moved rows out of the count, and the floor fired as if
			// the manifest walk had broken. The set has to be what the renderer
			// looks a driver up for, or the guard fights the work it guards.
			if (!BEHAVIOUR_TYPES.has(row.type)) continue;
			if (typeof row.id !== 'string' || row.id === '') continue;
			if (!visibleOn(row, key)) continue;
			declared.push({ section, id: row.id });
		}
	}

	if (declared.length < MIN_DECLARED[key]) {
		errors.push(
			`${key}: only ${declared.length} behaviour row(s) declared (floor ${MIN_DECLARED[key]}) — ` +
				'the manifest walk is broken, and every row would then look resolved'
		);
		continue;
	}

	const unresolved = declared.filter(
		({ section, id }) =>
			!corpus.includes(`"${id}"`) &&
			!corpus.includes(`'${id}'`) &&
			!sharedHandlers.has(id) &&
			!nativeReferences.has(id) &&
			!nativeSources.some((native) => {
				const row = manifest[section]?.find((r) => r.id === id);
				if (!row || !['command', 'list'].includes(row.type) || !native.src.includes(section))
					return false;
				return nativeTemplateBinding(
					native.src,
					ext,
					section,
					row.command || row.id,
					row.type === 'list' ? 3 : 1,
					nativeSources
				);
			})
	);
	summary.push(`${key} ${unresolved.length}/${BASELINE[key]}`);

	if (unresolved.length > BASELINE[key]) {
		const added = unresolved.slice(0, 6).map((u) => `${u.section}.${u.id}`);
		errors.push(
			`${key}: ${unresolved.length} declared menu row(s) have no handler named in ${driver}/ ` +
				`(baseline ${BASELINE[key]}). The manifest promises the user a row; the renderer looks up a ` +
				'handler by id and finds none, so the row either vanishes with a warning nobody reads or ' +
				'does nothing when clicked — and every manifest-reading gate still passes. ' +
				`Wire it up, or drop the row. Do NOT raise the baseline.\n      unresolved: ${added.join(', ')}` +
				`${unresolved.length > 6 ? `, +${unresolved.length - 6} more` : ''}`
		);
	}

	// A ratchet that only stops the number rising lets a hard-won drop be given
	// back for free: wire five rows today, unwire them next month, gate still
	// green. Lowering the baseline is one line and it is the line that makes the
	// gain permanent.
	if (unresolved.length < BASELINE[key]) {
		errors.push(
			`${key}: only ${unresolved.length} unresolved row(s) remain, below the baseline of ` +
				`${BASELINE[key]}. That is progress — lower BASELINE.${key} to ${unresolved.length} so it ` +
				'cannot be silently given back.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu rows with no handler:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(`\x1b[32m[OK] No new unresolved menu rows (${summary.join(', ')}).\x1b[0m`);
