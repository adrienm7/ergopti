// tools/test/test-chord-native-mapping-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Chord Native-Mapping Single Source
 * DESCRIPTION:
 * The shared catalogue _shared/modules/actions/modifier_chords.json already says
 * what each OS calls each modifier and each key: `ahk_prefix` for the Windows
 * modifiers, `hammerspoon` for the macOS ones, `windows_key` / `macos_key` for
 * the keys AutoHotkey and Hammerspoon spell their own way. Three drivers read
 * that file for their gesture slot space.
 *
 * The chord notation then needs exactly the same facts to reach the OS, and the
 * adapters wrote them down a second time. Two tables saying the same thing is one
 * table that will eventually be wrong: a key added to the catalogue with the
 * right AutoHotkey spelling would bind to nothing, because the adapter's private
 * copy never heard of it, and no test would notice.
 *
 * WHAT IS CHECKED:
 * 1. Modifier prefixes — every `ahk_prefix` in the catalogue is the prefix the
 *    Windows adapter emits for the canonical modifier that Windows modifier maps
 *    onto ("win" is the canonical "cmd": same physical key, same position).
 * 2. Modifier names — every `hammerspoon` value is a canonical modifier the
 *    shared notation knows, and every catalogue modifier id is an accepted alias
 *    of it, so a chord written with the catalogue's vocabulary parses.
 * 3. Key spellings — every catalogue key whose AutoHotkey spelling differs from
 *    its chord key appears in the adapter's native-key map with exactly its
 *    `windows_hotkey_key` spelling. This is deliberately separate from
 *    brace-capable `windows_key`, which feeds Send rather than Hotkey.
 * 4. Slot vocabulary — the id → chord-key maps the two drivers keep for their
 *    shortcut slots agree with the catalogue's `chord_key`, so "enter" means the
 *    same key on both.
 *
 * WHY TEXT-PARSING AND NOT LOADING: neither an AutoHotkey global nor a Lua local
 * can be required from Node. Parsing the literal is what makes the check run in
 * CI on any OS, and the parse itself is floored — a regex that matched nothing
 * would turn this gate into a green light over an empty set.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const CATALOGUE = path.join(ROOT, 'static/ergopti_plus/_shared/modules/actions/modifier_chords.json');
const AHK_ADAPTER = path.join(ROOT, 'static/ergopti_plus/windows/adapters/hotkey_registrar.ahk');
const AHK_SLOTS = path.join(ROOT, 'static/ergopti_plus/windows/infra/config_io.ahk');
const LUA_CHORD = path.join(ROOT, 'static/ergopti_plus/_shared/lua/chord/init.lua');
const HS_SLOTS = path.join(ROOT, 'static/ergopti_plus/macos/modules/shortcuts/keyboard_shortcuts.lua');

// The catalogue's Windows vocabulary calls the Windows key "win"; the shared
// notation calls the same physical modifier "cmd". This is the one rename, and
// it is deliberate — see the adapter's HOTKEY_MOD_PREFIXES comment.
const CATALOGUE_MOD_TO_CANONICAL = { ctrl: 'ctrl', shift: 'shift', alt: 'alt', win: 'cmd' };

// Keys the adapter may spell natively without a catalogue entry. These are keys
// no slot uses today but that any chord may legitimately name. The values are
// part of the contract too: a Set would justify a brace-wrapped or mistyped
// spelling without comparing it to the exact Hotkey() syntax.
const ADAPTER_ONLY_KEYS = Object.freeze({
	enter: 'enter',
	tab: 'tab',
	escape: 'escape',
	backspace: 'backspace',
	delete: 'delete'
});

const errors = [];

/** @param {string} msg */
function fail(msg) {
	errors.push(msg);
}




// ==================================================
// ==================================================
// ======= 1/ Source Extraction =====================
// ==================================================
// ==================================================

/**
 * Extracts an AutoHotkey `Map("k", "v", …)` literal assigned to a global.
 * @param {string} src
 * @param {string} name The global's name.
 * @returns {Object<string,string>}
 */
function parseAhkMap(src, name) {
	const re = new RegExp(`global\\s+${name}\\s*:=\\s*Map\\(([\\s\\S]*?)\\n?\\)`, 'm');
	const m = src.match(re);
	if (!m) {
		fail(`could not find "global ${name} := Map(…)" — the parser drifted, and a gate over nothing passes forever`);
		return {};
	}
	const tokens = [...m[1].matchAll(/"((?:[^"`]|`.)*)"/g)].map((t) => t[1]);
	if (tokens.length === 0 || tokens.length % 2 !== 0) {
		fail(`${name}: parsed ${tokens.length} quoted token(s) — expected a non-zero even count of key/value pairs`);
		return {};
	}
	const out = {};
	for (let i = 0; i < tokens.length; i += 2) out[tokens[i]] = tokens[i + 1];
	return out;
}

/**
 * Extracts an AutoHotkey `static Name := Map("k", "v", …)` literal.
 * @param {string} src
 * @param {string} name
 * @returns {Object<string,string>}
 */
function parseAhkStaticMap(src, name) {
	const re = new RegExp(`static\\s+${name}\\s*:=\\s*Map\\(([^)]*)\\)`, 'm');
	const m = src.match(re);
	if (!m) {
		fail(`could not find "static ${name} := Map(…)" — the parser drifted`);
		return {};
	}
	const tokens = [...m[1].matchAll(/"((?:[^"`]|`.)*)"/g)].map((t) => t[1]);
	if (tokens.length === 0 || tokens.length % 2 !== 0) {
		fail(`${name}: parsed ${tokens.length} quoted token(s) — expected a non-zero even count`);
		return {};
	}
	const out = {};
	for (let i = 0; i < tokens.length; i += 2) out[tokens[i]] = tokens[i + 1];
	return out;
}

/**
 * Extracts a Lua `local NAME = { k = "v", … }` table of string values.
 * @param {string} src
 * @param {string} name
 * @returns {Object<string,string>}
 */
function parseLuaTable(src, name) {
	const re = new RegExp(`local\\s+${name}\\s*=\\s*\\{([\\s\\S]*?)\\n\\}`, 'm');
	const m = src.match(re);
	if (!m) {
		fail(`could not find "local ${name} = { … }" — the parser drifted`);
		return {};
	}
	const out = {};
	for (const pair of m[1].matchAll(/([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"((?:[^"\\]|\\.)*)"/g)) {
		out[pair[1]] = pair[2];
	}
	if (Object.keys(out).length === 0) {
		fail(`${name}: parsed zero entries — a gate over an empty table passes forever`);
	}
	return out;
}

/**
 * Extracts the canonical modifier list from the shared notation core.
 * @param {string} src
 * @returns {string[]}
 */
function parseModOrder(src) {
	const m = src.match(/M\.MOD_ORDER\s*=\s*\{([^}]*)\}/);
	if (!m) {
		fail('could not find M.MOD_ORDER in the shared chord core — the parser drifted');
		return [];
	}
	return [...m[1].matchAll(/"([^"]+)"/g)].map((t) => t[1]);
}

/**
 * Extracts the accepted modifier aliases from the shared notation core.
 * @param {string} src
 * @returns {Object<string,string>}
 */
function parseAliases(src) {
	const m = src.match(/local\s+MOD_ALIASES\s*=\s*\{([\s\S]*?)\n\}/);
	if (!m) {
		fail('could not find MOD_ALIASES in the shared chord core — the parser drifted');
		return {};
	}
	const out = {};
	for (const pair of m[1].matchAll(/([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"/g)) out[pair[1]] = pair[2];
	if (Object.keys(out).length === 0) fail('MOD_ALIASES parsed empty');
	return out;
}




// ==================================================
// ==================================================
// ======= 2/ Load Everything =======================
// ==================================================
// ==================================================

const catalogue = JSON.parse(fs.readFileSync(CATALOGUE, 'utf8'));
const ahkAdapterSrc = fs.readFileSync(AHK_ADAPTER, 'utf8');
const ahkSlotsSrc = fs.readFileSync(AHK_SLOTS, 'utf8');
const luaChordSrc = fs.readFileSync(LUA_CHORD, 'utf8');
const hsSlotsSrc = fs.readFileSync(HS_SLOTS, 'utf8');

const ahkPrefixes = parseAhkMap(ahkAdapterSrc, 'HOTKEY_MOD_PREFIXES');
const ahkNativeKeys = parseAhkMap(ahkAdapterSrc, 'HOTKEY_KEY_NATIVE');
const ahkSlotKeys = parseAhkStaticMap(ahkSlotsSrc, '_SlotKeyNames');
const hsSlotKeys = parseLuaTable(hsSlotsSrc, 'SPECIAL_KEYS');
const modOrder = parseModOrder(luaChordSrc);
const aliases = parseAliases(luaChordSrc);

// Floor the catalogue itself: an empty or truncated file would satisfy every
// "for each entry" loop below without checking a single fact.
if (!Array.isArray(catalogue.keys) || catalogue.keys.length < 36) {
	fail(`modifier_chords.json holds ${catalogue.keys ? catalogue.keys.length : 0} key(s) — expected at least the 36 alphanumerics`);
}
if (!catalogue.platforms || !catalogue.platforms.windows || !catalogue.platforms.macos) {
	fail('modifier_chords.json has no windows/macos platform block — nothing below can be checked');
}

/** The chord key for a catalogue entry; absent chord_key means the id is it. */
const chordKeyOf = (entry) => entry.chord_key || entry.id;




// ==================================================
// ==================================================
// ======= 3/ Modifier Agreement ====================
// ==================================================
// ==================================================

for (const mod of (catalogue.platforms.windows || {}).modifiers || []) {
	const canonical = CATALOGUE_MOD_TO_CANONICAL[mod.id];
	if (!canonical) {
		fail(`catalogue Windows modifier "${mod.id}" has no canonical counterpart — add it to CATALOGUE_MOD_TO_CANONICAL or to the notation`);
		continue;
	}
	if (ahkPrefixes[canonical] !== mod.ahk_prefix) {
		fail(
			`AutoHotkey prefix for "${mod.id}" (canonical "${canonical}"): catalogue says "${mod.ahk_prefix}", ` +
				`HOTKEY_MOD_PREFIXES says "${ahkPrefixes[canonical]}"`
		);
	}
}

for (const mod of (catalogue.platforms.macos || {}).modifiers || []) {
	if (!modOrder.includes(mod.hammerspoon)) {
		fail(`catalogue macOS modifier "${mod.id}" maps to Hammerspoon "${mod.hammerspoon}", which is not a canonical modifier (${modOrder.join(', ')})`);
	}
	if (aliases[mod.id] !== mod.hammerspoon) {
		fail(
			`catalogue macOS modifier id "${mod.id}" must be an accepted alias of "${mod.hammerspoon}" ` +
				`so a chord written in the catalogue's vocabulary parses — the notation resolves it to "${aliases[mod.id]}"`
		);
	}
}




// ==================================================
// ==================================================
// ======= 4/ Key Spelling Agreement ================
// ==================================================
// ==================================================

const justifiedNativeKeys = new Set(Object.keys(ADAPTER_ONLY_KEYS));

for (const [chordKey, winHotkeyKey] of Object.entries(ADAPTER_ONLY_KEYS)) {
	if (ahkNativeKeys[chordKey] !== winHotkeyKey) {
		fail(
			`AutoHotkey Hotkey spelling of adapter-only key "${chordKey}": expected "${winHotkeyKey}", ` +
				`HOTKEY_KEY_NATIVE says "${ahkNativeKeys[chordKey]}"`
		);
	}
}

for (const entry of catalogue.keys || []) {
	const chordKey = chordKeyOf(entry);
	const winHotkeyKey = entry.windows_hotkey_key || chordKey;
	if (winHotkeyKey !== chordKey || entry.windows_hotkey_key) {
		justifiedNativeKeys.add(chordKey);
		if (ahkNativeKeys[chordKey] !== winHotkeyKey) {
			fail(
				`AutoHotkey Hotkey spelling of "${entry.id}" (chord key "${chordKey}"): catalogue says "${winHotkeyKey}", ` +
					`HOTKEY_KEY_NATIVE says "${ahkNativeKeys[chordKey]}"`
			);
		}
	}

	// Hammerspoon takes the chord key as-is, lower-cased. A catalogue entry whose
	// macos_key disagrees would bind a different physical key on macOS than the
	// one the same slot binds on Windows.
	const macKey = entry.macos_key || entry.id;
	if (macKey !== chordKey.toLowerCase()) {
		fail(
			`Hammerspoon spelling of "${entry.id}": catalogue says "${macKey}", but the chord key is "${chordKey}" ` +
				`and the macOS adapter sends it lower-cased ("${chordKey.toLowerCase()}")`
		);
	}
}

for (const key of Object.keys(ahkNativeKeys)) {
	if (!justifiedNativeKeys.has(key)) {
		fail(
			`HOTKEY_KEY_NATIVE spells "${key}" natively, but no catalogue entry and no documented allowance asks for it — ` +
				'a private spelling nothing justifies is the drift this gate exists to catch'
		);
	}
}




// ==================================================
// ==================================================
// ======= 5/ Slot Vocabulary Agreement =============
// ==================================================
// ==================================================

// Both drivers translate their slot-id suffix into a chord key. Where the
// catalogue declares a chord_key, both must use exactly it: "enter" meaning
// "return" on one driver and "enter" on the other is one config file producing
// two different bindings.
for (const entry of catalogue.keys || []) {
	if (!entry.chord_key) continue;
	if (ahkSlotKeys[entry.id] !== undefined && ahkSlotKeys[entry.id] !== entry.chord_key) {
		fail(`Windows slot vocabulary: "${entry.id}" resolves to "${ahkSlotKeys[entry.id]}", catalogue says "${entry.chord_key}"`);
	}
	if (hsSlotKeys[entry.id] !== undefined && hsSlotKeys[entry.id] !== entry.chord_key) {
		fail(`macOS slot vocabulary: "${entry.id}" resolves to "${hsSlotKeys[entry.id]}", catalogue says "${entry.chord_key}"`);
	}
}

// The drivers may not invent a slot key the catalogue never declared: a suffix
// that means something on one driver and nothing on the other is exactly the
// divergence the shared catalogue was created to end.
const declaredChordKeys = new Set((catalogue.keys || []).filter((e) => e.chord_key).map((e) => e.id));
for (const [driver, table] of [['Windows', ahkSlotKeys], ['macOS', hsSlotKeys]]) {
	for (const id of Object.keys(table)) {
		if (!declaredChordKeys.has(id)) {
			fail(`${driver} slot vocabulary declares "${id}", which modifier_chords.json does not — add it to the catalogue`);
		}
	}
}

// Floor the comparison itself: if either driver's table parsed empty, every loop
// above ran zero times and reported success.
if (Object.keys(ahkSlotKeys).length === 0) fail('the Windows slot vocabulary parsed empty');
if (Object.keys(hsSlotKeys).length === 0) fail('the macOS slot vocabulary parsed empty');




// ==================================================
// ==================================================
// ======= 6/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the chord native mappings disagree with modifier_chords.json:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] chord native mappings match modifier_chords.json ` +
		`(${catalogue.keys.length} key(s), ${catalogue.platforms.windows.modifiers.length} Windows modifier(s), ` +
		`${catalogue.platforms.macos.modifiers.length} macOS modifier(s)).\x1b[0m`
);
