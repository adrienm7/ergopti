// tools/test/test-layer-actions-vocabulary.cjs

/**
 * ==============================================================================
 * MODULE: Layer-Action Vocabulary Gate
 * DESCRIPTION:
 * `_shared/keymap/layer_actions.toml` is the grammar every layer file is written
 * in and the table every driver resolves a binding through. This gate checks
 * that the vocabulary is complete and honest before any layer is read with it.
 *
 * WHAT IS CHECKED:
 * 1. Shape: the meta block, the primary modifier of every OS, the restricted
 *    modifiers and parameters, the call handlers.
 * 2. Resolution: every action resolves on every OS, or names the reason it does
 *    not; each resolution parses, uses only modifiers that exist on that OS and
 *    only call handlers that OS declares. No handler is declared for nothing.
 * 3. Catalogue: an id that also exists in _shared/modules/actions/actions.toml
 *    ([sg_actions]) must say so, and must send exactly the keystroke the
 *    catalogue emits on each OS where the catalogue emits one. A deliberate
 *    difference is declared per OS in `catalogue_divergence`, and a declared
 *    difference that no longer differs fails too, so the excuse cannot outlive
 *    its reason.
 * 4. Reasons: every reason_key reads in all 21 locales.
 * 5. Preset: the recommended layer never spells out, as a raw keystroke, a
 *    chord a catalogue action already sends on that OS; it names the action.
 *
 * WHY IT EXISTS:
 * Gestures, shortcuts and the navigation layer name the same actions. Without a
 * pin, "word_prev" could send Ctrl+Left from a gesture and Alt+Left from the
 * layer on the same OS, and nothing would notice until a user did.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { shared } = require('../lib/paths.cjs');
const {
	loadContext,
	loadLayers,
	parseResolution,
	VOCABULARY_PATH,
	RECOMMENDED_PATH
} = require('../lib/keymap-layers.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const CATALOGUE_PATH = shared('modules', 'actions', 'actions.toml');
const LOCALES_DIR = shared('data', 'locales');
const COMBO_EMITTER = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'linux',
	'modules',
	'gestures',
	'combo_emitter.lua'
);

// Floors: a vocabulary or a catalogue that stopped being read would otherwise
// pass with nothing compared.
const MIN_ACTIONS = 30;
const MIN_CATALOGUE_PINS = 40;
const MIN_LOCALES = 21;
const MIN_CATALOGUE_CHORDS_SCANNED = 80;

const errors = [];
const fail = (msg) => errors.push(msg);

if (!fs.existsSync(VOCABULARY_PATH)) {
	console.error(
		`\x1b[31m[FAIL] ${path.relative(ROOT, VOCABULARY_PATH)} is missing — layer bindings have no vocabulary.\x1b[0m`
	);
	process.exit(1);
}

const ctx = loadContext();
const vocabulary = ctx.vocabulary;
const keys = ctx.registry.keys;
const OSES = ['windows', 'macos', 'linux'];
const reasonKeys = new Set();

// ===================================
// ===================================
// ======= 1/ Vocabulary shape =======
// ===================================
// ===================================

const meta = vocabulary._meta || {};
if (JSON.stringify(meta.platforms) !== JSON.stringify(OSES))
	fail(
		`[_meta].platforms must be ${JSON.stringify(OSES)}, found ${JSON.stringify(meta.platforms)}`
	);
if (!Number.isInteger(meta.layers_schema_version) || meta.layers_schema_version < 1)
	fail('[_meta].layers_schema_version must be a positive integer');
if (meta.user_file !== 'layers.toml')
	fail(
		`[_meta].user_file must name the user's layers.toml, found ${JSON.stringify(meta.user_file)}`
	);
const modifierOrder = meta.modifier_order || [];
if (!Array.isArray(modifierOrder) || modifierOrder.length < 4)
	fail('[_meta].modifier_order must list the modifiers');

for (const os of OSES) {
	const primary = (vocabulary.primary_modifier || {})[os];
	if (!modifierOrder.includes(primary))
		fail(`[primary_modifier].${os} = ${JSON.stringify(primary)} is not a modifier`);
	if (!Array.isArray((vocabulary.call_handlers || {})[os]))
		fail(`[call_handlers].${os} must be a list`);
}

for (const [mod, rule] of Object.entries(vocabulary.modifiers || {})) {
	if (!modifierOrder.includes(mod))
		fail(`[modifiers.${mod}] restricts a modifier that is not in modifier_order`);
	if (!Array.isArray(rule.platforms) || rule.platforms.some((p) => !OSES.includes(p)))
		fail(`[modifiers.${mod}].platforms must list OSes`);
	if (rule.platforms.length < OSES.length) {
		if (typeof rule.reason_key !== 'string')
			fail(`[modifiers.${mod}] leaves an OS out without a reason_key`);
		else reasonKeys.add(rule.reason_key);
	}
}

// A restricted source kind must name a kind the registry uses, or the rule
// guards nothing; and the OS it leaves out must be told why.
const registryKinds = new Set(Object.values(keys).map((k) => k.kind));
for (const [kind, rule] of Object.entries(vocabulary.source_kinds || {})) {
	if (!registryKinds.has(kind))
		fail(
			`[source_kinds.${kind}] restricts a kind no physical key has (${[...registryKinds].join(', ')})`
		);
	if (!Array.isArray(rule.platforms) || rule.platforms.some((p) => !OSES.includes(p)))
		fail(`[source_kinds.${kind}].platforms must list OSes`);
	else if (rule.platforms.length === OSES.length)
		fail(`[source_kinds.${kind}] restricts nothing: every OS is listed`);
	else if (typeof rule.reason_key !== 'string')
		fail(`[source_kinds.${kind}] leaves an OS out without a reason_key`);
	else reasonKeys.add(rule.reason_key);
}

const repeatCount = (vocabulary.parameters || {}).repeat_count;
if (
	!repeatCount ||
	!Number.isInteger(repeatCount.min) ||
	!Number.isInteger(repeatCount.max) ||
	repeatCount.min < 1 ||
	repeatCount.max < repeatCount.min
)
	fail('[parameters.repeat_count] needs integer min >= 1 and max >= min');
for (const [name, param] of Object.entries(vocabulary.parameters || {})) {
	if (!Array.isArray(param.platforms) || param.platforms.some((p) => !OSES.includes(p)))
		fail(`[parameters.${name}].platforms must list OSes`);
	else if (param.platforms.length < OSES.length) {
		if (typeof param.reason_key !== 'string')
			fail(`[parameters.${name}] leaves an OS out without a reason_key`);
		else reasonKeys.add(param.reason_key);
	}
}

// ===================================
// ===================================
// ======= 2/ Every action resolves ==
// ===================================
// ===================================

const ACTION_FIELDS = new Set([
	'catalogue',
	'catalogue_divergence',
	'repeatable',
	'reason_key',
	'group',
	'all',
	...OSES
]);
const actions = vocabulary.actions || {};
const usedHandlers = new Set();
// action id -> os -> canonical chord text ("alt+shift+ArrowUp"), for section 3
const resolved = {};

/** The resolution text an action uses on one OS, or undefined. */
function resolutionFor(action, os) {
	return action[os] !== undefined ? action[os] : action.all;
}

/** Canonical form of one resolved chord: modifiers in modifier_order, then the key. */
function chordText(chord, os) {
	const mods = new Set(
		chord.mods.map((m) => (m === 'primary' ? vocabulary.primary_modifier[os] : m))
	);
	return [...modifierOrder.filter((m) => mods.has(m)), chord.key].join('+');
}

for (const [id, action] of Object.entries(actions)) {
	if (!/^[a-z][a-z0-9_]*$/.test(id)) fail(`action id "${id}" is not snake_case`);
	for (const field of Object.keys(action))
		if (!ACTION_FIELDS.has(field)) fail(`[actions.${id}].${field} is not a field`);
	if (typeof action.repeatable !== 'boolean')
		fail(`[actions.${id}].repeatable must be true or false`);
	resolved[id] = {};
	let missing = 0;
	for (const os of OSES) {
		const text = resolutionFor(action, os);
		if (text === undefined) {
			missing += 1;
			continue;
		}
		let res;
		try {
			res = parseResolution(text, os, ctx);
		} catch (e) {
			fail(`[actions.${id}] on ${os}: ${e.message}`);
			continue;
		}
		if (res.kind === 'call') usedHandlers.add(`${os}:${res.handler}`);
		if (res.kind !== 'keystroke') continue;
		for (const chord of res.chords) {
			for (const raw of chord.mods) {
				const mod = raw === 'primary' ? vocabulary.primary_modifier[os] : raw;
				const rule = (vocabulary.modifiers || {})[mod];
				if (rule && !rule.platforms.includes(os))
					fail(`[actions.${id}] on ${os} sends modifier "${mod}", which does not exist on ${os}`);
			}
		}
		if (res.chords.length === 1) resolved[id][os] = chordText(res.chords[0], os);
		if (action.repeatable === true && res.kind === 'none')
			fail(`[actions.${id}] is repeatable but does nothing on ${os}`);
	}
	if (missing > 0) {
		if (typeof action.reason_key !== 'string')
			fail(`[actions.${id}] has no resolution on ${missing} OS(es) and no reason_key`);
		else reasonKeys.add(action.reason_key);
	} else if (action.reason_key !== undefined) {
		fail(`[actions.${id}] resolves everywhere but declares a reason_key nothing can display`);
	}
}

for (const os of OSES) {
	for (const handler of vocabulary.call_handlers[os] || []) {
		if (!usedHandlers.has(`${os}:${handler}`))
			fail(`[call_handlers].${os} declares "${handler}" and no action calls it`);
	}
}

if (Object.keys(actions).length < MIN_ACTIONS)
	fail(`only ${Object.keys(actions).length} actions read (floor ${MIN_ACTIONS})`);

// ============================================
// ============================================
// ======= 3/ Catalogue ids send the same =====
// ============================================
// ============================================

const catalogue = TOML.parse(fs.readFileSync(CATALOGUE_PATH, 'utf8')).sg_actions || {};

// Catalogue key names are each driver's own. Windows names are AutoHotkey Send
// names (the registry's ahk_send); Linux names are the X11 keysyms the Linux
// combo emitter resolves (read from its table, then through evdev); macOS names
// are Hammerspoon's hs.keycodes.map names for the macOS virtual keycodes below.
const HS_NAME_TO_KEYCODE = {
	up: 126,
	down: 125,
	left: 123,
	right: 124,
	home: 115,
	end: 119,
	delete: 51,
	forwarddelete: 117,
	return: 36,
	escape: 53,
	tab: 48,
	space: 49
};
const MOD_ALIASES = {
	ctrl: 'ctrl',
	control: 'ctrl',
	shift: 'shift',
	alt: 'alt',
	option: 'alt',
	super: 'meta',
	win: 'meta',
	cmd: 'meta',
	meta: 'meta'
};

const emitterSource = fs.readFileSync(COMBO_EMITTER, 'utf8');
const keysymBlock = /local KEYSYM_TO_CODE = \{([\s\S]*?)\n\}/.exec(emitterSource);
const KEYSYM_TO_EVDEV = {};
if (!keysymBlock) fail('linux/modules/gestures/combo_emitter.lua: KEYSYM_TO_CODE table not found');
else
	for (const m of keysymBlock[1].matchAll(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\d+),/gm))
		KEYSYM_TO_EVDEV[m[1]] = Number(m[2]);
if (Object.keys(KEYSYM_TO_EVDEV).length < 15)
	fail(
		`only ${Object.keys(KEYSYM_TO_EVDEV).length} keysyms read from combo_emitter.lua (floor 15)`
	);

// The helpers below report through `onProblem`: section 3 fails on every name
// it cannot resolve, while the scan in section 5 skips catalogue entries this
// gate cannot name (letters, F17 triggers) and relies on its own floor.
function uniqueCode(pred, what, onProblem = fail) {
	const hits = Object.keys(keys).filter((code) => keys[code].kind === 'key' && pred(keys[code]));
	if (hits.length !== 1) {
		onProblem(`${what} matches ${hits.length} registry keys`);
		return null;
	}
	return hits[0];
}

function canonical(mods, code, what, onProblem = fail) {
	const set = new Set();
	for (const m of mods) {
		if (!MOD_ALIASES[m]) {
			onProblem(`${what}: unknown catalogue modifier "${m}"`);
			return null;
		}
		set.add(MOD_ALIASES[m]);
	}
	return code === null ? null : [...modifierOrder.filter((m) => set.has(m)), code].join('+');
}

/** What the catalogue sends for one action on one OS, canonical, or undefined when it emits nothing there. */
function catalogueChord(entry, os, id, onProblem = fail) {
	const what = `[sg_actions.${id}] on ${os}`;
	if (os === 'windows' && entry.emit_ahk_key !== undefined) {
		const code = uniqueCode(
			(k) => k.ahk_send && k.ahk_send.toLowerCase() === entry.emit_ahk_key.toLowerCase(),
			`${what}: AHK key "${entry.emit_ahk_key}"`,
			onProblem
		);
		return canonical(entry.emit_ahk_mods || [], code, what, onProblem);
	}
	if (os === 'macos' && entry.emit_hs_key !== undefined) {
		const keycode = HS_NAME_TO_KEYCODE[entry.emit_hs_key];
		if (keycode === undefined) {
			onProblem(
				`${what}: Hammerspoon key "${entry.emit_hs_key}" is not in this gate's name table — add its hs.keycodes.map code`
			);
			return null;
		}
		return canonical(
			entry.emit_hs_mods || [],
			uniqueCode((k) => k.hs === keycode, `${what}: macOS keycode ${keycode}`, onProblem),
			what,
			onProblem
		);
	}
	if (os === 'linux' && entry.emit_linux !== undefined) {
		const parts = entry.emit_linux.split('+');
		const name = parts.pop();
		const evdev = KEYSYM_TO_EVDEV[name];
		if (evdev === undefined) {
			onProblem(`${what}: keysym "${name}" is not in combo_emitter.lua's table`);
			return null;
		}
		return canonical(
			parts,
			uniqueCode((k) => k.evdev === evdev, `${what}: evdev ${evdev}`, onProblem),
			what,
			onProblem
		);
	}
	return undefined;
}

let pins = 0;
for (const [id, action] of Object.entries(actions)) {
	const entry = catalogue[id];
	if (action.catalogue === true && !entry)
		fail(`[actions.${id}] says catalogue = true but [sg_actions.${id}] does not exist`);
	if (action.catalogue !== true && entry)
		fail(
			`[actions.${id}] reuses the catalogue id "${id}" without catalogue = true — it must send what the catalogue sends`
		);
	if (action.catalogue_divergence !== undefined && action.catalogue !== true)
		fail(`[actions.${id}] declares a catalogue_divergence but is not a catalogue action`);
	if (!entry) continue;
	const divergent = new Set(action.catalogue_divergence || []);
	for (const os of divergent)
		if (!OSES.includes(os))
			fail(`[actions.${id}].catalogue_divergence names "${os}", which is not an OS`);
	for (const os of OSES) {
		const expected = catalogueChord(entry, os, id);
		if (expected === undefined) {
			if (divergent.has(os))
				fail(
					`[actions.${id}] declares a divergence on ${os}, where the catalogue emits nothing to diverge from`
				);
			continue;
		}
		if (expected === null) continue;
		const actual = resolved[id][os];
		if (divergent.has(os)) {
			if (actual === expected)
				fail(
					`[actions.${id}] declares a divergence on ${os} but sends exactly the catalogue's ${expected}: remove the stale declaration`
				);
			continue;
		}
		pins += 1;
		if (actual !== expected)
			fail(
				`[actions.${id}] on ${os} sends ${actual === undefined ? 'no single keystroke' : actual}; the catalogue sends ${expected}`
			);
	}
}
const brightness = JSON.parse(
	fs.readFileSync(shared('modules', 'actions', 'brightness.json'), 'utf8')
);
for (const id of ['brightness_up', 'brightness_down']) {
	if (catalogue[id].emit_ahk_key !== undefined)
		fail(`${id} must use the native backlight owner, not an unsupported AutoHotkey Send key`);
	if (!actions[id]) {
		fail(`${id} is missing from the shared layer vocabulary`);
		continue;
	}
	if (KEYSYM_TO_EVDEV[brightness.actions[id].linux_key] !== brightness.actions[id].linux_code)
		fail(`${id} must preserve the existing native evdev emitter identity`);
	for (const os of OSES) {
		if (resolutionFor(actions[id], os) !== `call:${id}`)
			fail(`${id} on ${os} must resolve to the same native brightness action`);
	}
	if (brightness.linux_program !== 'brightnessctl' || brightness.linux_class !== 'backlight')
		fail(`${id} must qualify the screen backlight class rather than keyboard LEDs`);
}

if (pins < MIN_CATALOGUE_PINS)
	fail(`only ${pins} catalogue keystrokes compared (floor ${MIN_CATALOGUE_PINS})`);

// =====================================
// =====================================
// ======= 4/ Reasons are readable =====
// =====================================
// =====================================

const localeFiles = fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json'));
if (localeFiles.length < MIN_LOCALES)
	fail(`only ${localeFiles.length} locale files found (floor ${MIN_LOCALES})`);
if (reasonKeys.size === 0)
	fail(
		'the vocabulary declares no reason_key: the OS restrictions it documents would be unexplained'
	);
for (const file of localeFiles) {
	const catalogueText = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, file), 'utf8'));
	for (const key of reasonKeys) {
		if (!key.startsWith('platform_reason.'))
			fail(`reason_key "${key}" is not under platform_reason.`);
		const value = catalogueText[key];
		if (typeof value !== 'string' || value.trim() === '')
			fail(`${file}: reason_key "${key}" is missing or blank`);
	}
}

// =====================================================
// =====================================================
// ======= 5/ The preset names catalogue actions =======
// =====================================================
// =====================================================

// A preset binding spelled as a raw keystroke that a catalogue action already
// sends on that OS hides the action's name from the layer editor and lets the
// two drift apart: the preset must bind the action by name instead.
const catalogueByChord = Object.fromEntries(OSES.map((os) => [os, new Map()]));
let scanned = 0;
for (const [id, entry] of Object.entries(catalogue)) {
	for (const os of OSES) {
		const chord = catalogueChord(entry, os, id, () => {});
		if (typeof chord !== 'string') continue;
		scanned += 1;
		if (!catalogueByChord[os].has(chord)) catalogueByChord[os].set(chord, []);
		catalogueByChord[os].get(chord).push(id);
	}
}
if (scanned < MIN_CATALOGUE_CHORDS_SCANNED)
	fail(`only ${scanned} catalogue keystrokes scanned (floor ${MIN_CATALOGUE_CHORDS_SCANNED})`);

const presetText = fs.readFileSync(RECOMMENDED_PATH, 'utf8');
let rawKeystrokes = 0;
for (const os of OSES) {
	for (const [layerId, bindings] of Object.entries(loadLayers(presetText, os, ctx).layers)) {
		for (const [code, res] of Object.entries(bindings)) {
			if (res.kind !== 'keystroke' || res.action !== null) continue;
			rawKeystrokes += 1;
			const chord = res.chords.map((c) => [...c.mods, c.key].join('+')).join(',');
			const ids = catalogueByChord[os].get(chord);
			if (ids)
				fail(
					`layers.recommended.toml: ${layerId}.${code} spells out ${chord} on ${os}, which the catalogue action ${ids.join(' / ')} sends — bind the action by name`
				);
		}
	}
}
if (rawKeystrokes === 0)
	fail('the recommended layer yielded no raw keystroke on any OS: the preset was not read');

// ================================================
// ================================================
// ======= 6/ The editor lists every action =======
// ================================================
// ================================================

// The layer editor (_shared/ui/layer_editor) lists the vocabulary under the
// headings [editor].groups names, in that order. An action without a group
// would be bindable by hand and missing from the picker; a group without an
// action would be an empty heading.
const editorGroups = (vocabulary.editor || {}).groups;
const groupSizes = new Map();
if (!Array.isArray(editorGroups) || editorGroups.length === 0)
	fail('[editor].groups must list the picker groups in order');
else {
	for (const group of editorGroups) {
		if (typeof group !== 'string' || !/^[a-z][a-z0-9_]*$/.test(group))
			fail(`[editor].groups entry ${JSON.stringify(group)} is not a snake_case id`);
		else if (groupSizes.has(group)) fail(`[editor].groups lists "${group}" twice`);
		else groupSizes.set(group, 0);
	}
	for (const [id, action] of Object.entries(actions)) {
		if (!groupSizes.has(action.group))
			fail(`[actions.${id}].group = ${JSON.stringify(action.group)} is not one of [editor].groups`);
		else groupSizes.set(action.group, groupSizes.get(action.group) + 1);
	}
	for (const [group, size] of groupSizes)
		if (size === 0) fail(`[editor].groups lists "${group}" and no action belongs to it`);
}

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] the layer-action vocabulary is incomplete or disagrees with the action catalogue:\x1b[0m'
	);
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] ${Object.keys(actions).length} layer actions resolve on ${OSES.join(', ')}; ${pins} catalogue keystrokes agree; ` +
		`${reasonKeys.size} reason key(s) read in ${localeFiles.length} locales; ${rawKeystrokes} preset keystroke(s) duplicate none of ` +
		`${scanned} catalogue keystrokes.\x1b[0m`
);
