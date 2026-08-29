// tools/codegen/codegen-terminators.cjs

/**
 * ==============================================================================
 * MODULE: Terminators Codegen
 * DESCRIPTION:
 * Generates both the AHK v2 and Hammerspoon Lua implementations of the
 * Terminators port contract from the single source of truth defined in
 * static/ergopti_plus/_shared/core/domain/Terminators.spec.js. Running this script
 * ensures both drivers start from identical catalogue data and expose the
 * same isTerminator / isConsumed / setEnabled / isEnabled / updateMagicKey /
 * addCustom / all() API surface.
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: TERMINATOR_DEFS lives in the spec; both outputs
 *    are generated from it so catalogue drift between drivers is impossible.
 * 2. UTF-8 BOM + LF for AHK: AHK v2 silently aborts mid-file on encoding
 *    drift; the writer enforces correct encoding at generation time.
 * 3. Pure codegen — no runtime dependency on the generated files; delete and
 *    re-run to reset both drivers to the canonical state.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '../..');

// Load the spec by reading and eval-ing it as CommonJS, since the file uses
// module.exports but the package is type:module (ESM). We inline the CJS
// wrapper so require() works without needing a .cjs copy of the spec.
const specSource = fs.readFileSync(
	shared('core/domain/Terminators.spec.js'),
	'utf8'
);
const specModule = { exports: {} };
// eslint-disable-next-line no-new-func
new Function('require', 'module', 'exports', '__dirname', '__filename', specSource)(
	require,
	specModule,
	specModule.exports,
	shared('core/domain'),
	shared('core/domain/Terminators.spec.js')
);
const { TERMINATOR_DEFS } = specModule.exports;

// ==================================================
// ==================================================
// ======= 1/ Helpers =======
// ==================================================
// ==================================================

/**
 * Escapes a raw JS string value into an AHK v2 double-quoted string literal.
 * Backtick is the AHK escape character; double-quotes inside use `".
 * @param {string} s - The raw string.
 * @returns {string} AHK-safe string literal body (without surrounding quotes).
 */
function ahkEscape(s) {
	return s
		.replace(/`/g, '``')
		.replace(/"/g, '`"')
		.replace(/\r/g, '`r')
		.replace(/\n/g, '`n')
		.replace(/\t/g, '`t');
}

/**
 * Escapes a raw JS string value into a Lua double-quoted string literal.
 * @param {string} s - The raw string.
 * @returns {string} Lua-safe string literal body (without surrounding quotes).
 */
function luaEscape(s) {
	return s
		.replace(/\\/g, '\\\\')
		.replace(/"/g, '\\"')
		.replace(/\r/g, '\\r')
		.replace(/\n/g, '\\n')
		.replace(/\t/g, '\\t');
}

/**
 * Writes content to a file, creating parent directories as needed.
 * For .ahk files enforces UTF-8 BOM + LF line endings.
 * @param {string} filePath - Absolute path to write.
 * @param {string} content  - File content with LF line endings.
 */
function writeFile(filePath, content) {
	fs.mkdirSync(path.dirname(filePath), { recursive: true });
	if (filePath.endsWith('.ahk')) {
             // Enforce LF and prepend UTF-8 BOM (EF BB BF)
             const lf = content.replace(/\r\n?/g, '\n');
             const bom = Buffer.from([0xef, 0xbb, 0xbf]);
             const body = Buffer.from(lf, 'utf8');
		fs.writeFileSync(filePath, Buffer.concat([bom, body]));
	} else {
		fs.writeFileSync(filePath, content, 'utf8');
	}
	console.log(`  written: ${path.relative(ROOT, filePath)}`);
}

// ==================================================
// ==================================================
// ======= 2/ AHK Generator =======
// ==================================================
// ==================================================

/**
 * Generates the AHK v2 Terminators class source.
 * @returns {string} Full file content with LF line endings.
 */
function generateAhk() {
	// Build the catalogue entries as AHK Map literals.
	const defsLines = TERMINATOR_DEFS.map((def, i) => {
		// Separator: a fully-formed but disabled, char-less slot so the engine
		// loops skip it naturally (no guard needed); the menus render it as "-".
		if (def.type === 'separator') {
			return `        Map("key", "separator_${i}", "chars", [], "label", "-", "default_enabled", false, "consume", false, "type", "separator")`;
		}
		const charsArr = def.chars.map((c) => `"${ahkEscape(c)}"`).join(', ');
		const enabled = def.default_enabled ? 'true' : 'false';
		const consume = def.consume ? 'true' : 'false';
		const label = ahkEscape(def.label || def.key);
		return (
			`        Map("key", "${def.key}", ` +
			`"chars", [${charsArr}], ` +
			`"label", "${label}", ` +
			`"default_enabled", ${enabled}, ` +
			`"consume", ${consume})`
		);
	}).join(',\n');

	return [
		`; static/ergopti_plus/windows/_generated/terminators.ahk`,
		`; AUTO-GENERATED from _shared/core/domain/Terminators.spec.js.`,
		`; DO NOT EDIT BY HAND — run \`npm run codegen:terminators\` to refresh.`,
		`#Requires AutoHotkey v2.0`,
		``,
		`; ==============================================================================`,
		`; CLASS: Terminators`,
		`; DESCRIPTION:`,
		`; AHK v2 implementation of the Terminators port contract. Owns the terminator`,
		`; catalogue and the O(1) lookup maps used by the hotstring engine. Generated`,
		`; from the shared spec so catalogue data is identical across all drivers.`,
		`;`,
		`; CONTRACT METHODS:`,
		`;   isTerminator(char)              — true if char belongs to an enabled slot.`,
		`;   isConsumed(char)                — true if the matching slot is consumed.`,
		`;   setEnabled(key, enabled)        — enable/disable a slot by key.`,
		`;   isEnabled(key)                  — query enabled state of a slot.`,
		`;   updateMagicKey(char)            — reassign the magic_key slot character.`,
		`;   addCustom(key, chars, label, consumed) — add a user-defined slot.`,
		`;   all()                           — return the full catalogue array.`,
		`; ==============================================================================`,
		``,
		``,
		``,
		``,
		`; ==============================`,
		`; ==============================`,
		`; ======= 1/ Terminators =======`,
		`; ==============================`,
		`; ==============================`,
		``,
		`class Terminators {`,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; Internal state — catalogue array, enable map, O(1) char lookup maps.`,
		`    ; -----------------------------------------------------------------------`,
		`    _catalogue  := []`,
		`    _enabled    := Map()`,
		`    _charsSet   := Map()`,
		`    _consumeSet := Map()`,
		``,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; __New — initialise from the generated catalogue.`,
		`    ; -----------------------------------------------------------------------`,
		`    __New() {`,
		`        this._catalogue := [`,
		defsLines,
		`        ]`,
		`        for entry in this._catalogue {`,
		`            this._enabled[entry["key"]] := entry["default_enabled"]`,
		`        }`,
		`        this._RebuildCache()`,
		`    }`,
		``,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; _RebuildCache — rebuild O(1) lookup maps from the current enabled state.`,
		`    ; -----------------------------------------------------------------------`,
		`    _RebuildCache() {`,
		`        this._charsSet   := Map()`,
		`        this._consumeSet := Map()`,
		`        for entry in this._catalogue {`,
		`            if !this._enabled.Has(entry["key"])`,
		`                continue`,
		`            if !this._enabled[entry["key"]]`,
		`                continue`,
		`            for ch in entry["chars"] {`,
		`                this._charsSet[ch] := true`,
		`                if entry["consume"]`,
		`                    this._consumeSet[ch] := true`,
		`            }`,
		`        }`,
		`    }`,
		``,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; isTerminator(char) — true if char belongs to any enabled slot.`,
		`    ; -----------------------------------------------------------------------`,
		`    isTerminator(char) {`,
		`        return this._charsSet.Has(char) && this._charsSet[char]`,
		`    }`,
		``,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; isConsumed(char) — true if the matching enabled slot is consumed.`,
		`    ; -----------------------------------------------------------------------`,
		`    isConsumed(char) {`,
		`        return this._consumeSet.Has(char) && this._consumeSet[char]`,
		`    }`,
		``,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; setEnabled(key, enabled) — enable or disable a slot by key.`,
		`    ; -----------------------------------------------------------------------`,
		`    setEnabled(key, enabled) {`,
		`        if !this._enabled.Has(key) {`,
		`            ; Unknown key — log and return per contract error_behavior`,
		`            OutputDebug("[Terminators] setEnabled: unknown key '" key "'")`,
		`            return`,
		`        }`,
		`        this._enabled[key] := enabled`,
		`        this._RebuildCache()`,
		`    }`,
		``,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; isEnabled(key) — query the enabled state of a slot.`,
		`    ; -----------------------------------------------------------------------`,
		`    isEnabled(key) {`,
		`        if !this._enabled.Has(key)`,
		`            return false`,
		`        return this._enabled[key]`,
		`    }`,
		``,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; updateMagicKey(char) — reassign the magic_key slot to a new character.`,
		`    ; -----------------------------------------------------------------------`,
		`    updateMagicKey(char) {`,
		`        for entry in this._catalogue {`,
		`            if entry["key"] = "star" {`,
		`                entry["chars"] := [char]`,
		`                break`,
		`            }`,
		`        }`,
		`        this._RebuildCache()`,
		`    }`,
		``,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; addCustom(key, chars, label, consumed) — add a user-defined terminator.`,
		`    ; -----------------------------------------------------------------------`,
		`    addCustom(key, chars, label, consumed) {`,
		`        if this._enabled.Has(key) {`,
		`            ; Key collision — log and return per contract error_behavior`,
		`            OutputDebug("[Terminators] addCustom: key collision '" key "'")`,
		`            return false`,
		`        }`,
		`        for candidateChar in chars {`,
		`            for entry in this._catalogue {`,
		`                for existingChar in entry["chars"] {`,
		`                    if existingChar == candidateChar {`,
		`                        ; Character collision — one input value has one policy owner`,
		`                        OutputDebug("[Terminators] addCustom: character collision")`,
		`                        return false`,
		`                    }`,
		`                }`,
		`            }`,
		`        }`,
		`        local entry := Map(`,
		`            "key",             key,`,
		`            "chars",           chars,`,
		`            "label",           label,`,
		`            "default_enabled", true,`,
		`            "consume",         consumed`,
		`        )`,
		`        this._catalogue.Push(entry)`,
		`        this._enabled[key] := true`,
		`        this._RebuildCache()`,
		`        return true`,
		`    }`,
		``,
		``,
		`    ; -----------------------------------------------------------------------`,
		`    ; all() — return a copy of the full catalogue array.`,
		`    ; -----------------------------------------------------------------------`,
		`    all() {`,
		`        local copy := []`,
		`        for entry in this._catalogue`,
		`            copy.Push(entry)`,
		`        return copy`,
		`    }`,
		``,
		`}`,
		``
	].join('\n');
}

// ==================================================
// ==================================================
// ======= 3/ Lua Generator =======
// ==================================================
// ==================================================

/**
 * Generates the shared Lua terminator-catalogue DATA module.
 *
 * This is intentionally pure data (a single `return { … }` table) rather than a
 * full module: the macOS driver keeps its hand-written logic module
 * (_shared/lua/keymap/terminators.lua — O(1) caches, multi-codepoint safety,
 * i18n, custom/magic-key lifecycle) and simply consumes this catalogue for its
 * TERMINATOR_DEFS. That keeps the macOS hot path untouched while still sourcing
 * the catalogue data from the single spec, so AHK and macOS can never drift.
 * @returns {string} Full file content with LF line endings.
 */
function generateLua() {
	// Build the catalogue as a Lua array literal. Separators are emitted WITHOUT
	// a key (matching the macOS logic module's keyless { type = "separator" }):
	// its enable-seed and bulk loops gate on `def.key`, so a keyless separator is
	// skipped naturally while the menus still render it as a "-" divider.
	const defsLines = TERMINATOR_DEFS.map((def) => {
		if (def.type === 'separator') {
			return `\t{ label = "-", type = "separator" }`;
		}
		const charsArr = def.chars.map((c) => `"${luaEscape(c)}"`).join(', ');
		const enabled = def.default_enabled ? 'true' : 'false';
		const consume = def.consume ? 'true' : 'false';
		const label = luaEscape(def.label || def.key);
		return (
			`\t{ key = "${def.key}", chars = { ${charsArr} }, ` +
			`label = "${label}", default_enabled = ${enabled}, consume = ${consume} }`
		);
	}).join(',\n');

	return [
		`--- _shared/lua/keymap/terminators_catalogue.lua`,
		`--- AUTO-GENERATED from _shared/core/domain/Terminators.spec.js.`,
		`--- DO NOT EDIT BY HAND — run \`npm run codegen:terminators\` to refresh.`,
		``,
		`--- ==============================================================================`,
		`--- DATA: Terminator Catalogue`,
		`--- DESCRIPTION:`,
		`--- Pure, ordered terminator definitions seeded from the shared spec. Consumed`,
		`--- by keymap.terminators (the hand-written logic module) so the macOS driver`,
		`--- and the AHK driver start from byte-identical catalogue data. The list`,
		`--- ORDER is the menu order; { type = "separator" } entries render as "-".`,
		`--- ==============================================================================`,
		``,
		`return {`,
		defsLines,
		`}`,
		``
	].join('\n');
}

// ==================================================
// ==================================================
// ======= 4/ Entry Point =======
// ==================================================
// ==================================================

const AHK_OUT = path.join(ROOT, 'static/ergopti_plus/windows/_generated/terminators.ahk');
const LUA_OUT = shared('lua/keymap/terminators_catalogue.lua');

console.log('codegen:terminators — generating from terminators.spec.js…');
writeFile(AHK_OUT, generateAhk());
writeFile(LUA_OUT, generateLua());
console.log('codegen:terminators — done.');
