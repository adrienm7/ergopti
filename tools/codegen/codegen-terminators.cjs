// tools/codegen/codegen-terminators.cjs

/**
 * ==============================================================================
 * MODULE: Terminators Codegen
 * DESCRIPTION:
 * Generates both the AHK v2 and Hammerspoon Lua implementations of the
 * Terminators port contract from the single source of truth defined in
 * static/ergopti_plus/shared/domain/Terminators.spec.js. Running this script
 * ensures both drivers start from identical catalogue data and expose the
 * same isTerminator / isConsumed / setEnabled / isEnabled / updateMagicKey /
 * addCustom / all() API surface.
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: TERMINATOR_DEFS lives in the spec; both outputs
 *    are generated from it so catalogue drift between drivers is impossible.
 * 2. UTF-8 BOM + CRLF for AHK: AHK v2 silently aborts mid-file on encoding
 *    drift; the writer enforces correct encoding at generation time.
 * 3. Pure codegen — no runtime dependency on the generated files; delete and
 *    re-run to reset both drivers to the canonical state.
 * ==============================================================================
 */

"use strict";

const fs   = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "../..");

// Load the spec by reading and eval-ing it as CommonJS, since the file uses
// module.exports but the package is type:module (ESM). We inline the CJS
// wrapper so require() works without needing a .cjs copy of the spec.
const specSource = fs.readFileSync(
	path.join(ROOT, "static/ergopti_plus/shared/domain/Terminators.spec.js"),
	"utf8"
);
const specModule = { exports: {} };
// eslint-disable-next-line no-new-func
new Function("require", "module", "exports", "__dirname", "__filename", specSource)(
	require,
	specModule,
	specModule.exports,
	path.join(ROOT, "static/ergopti_plus/shared/domain"),
	path.join(ROOT, "static/ergopti_plus/shared/domain/Terminators.spec.js")
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
		.replace(/`/g, "``")
		.replace(/"/g, '`"')
		.replace(/\r/g, "`r")
		.replace(/\n/g, "`n")
		.replace(/\t/g, "`t");
}

/**
 * Escapes a raw JS string value into a Lua double-quoted string literal.
 * @param {string} s - The raw string.
 * @returns {string} Lua-safe string literal body (without surrounding quotes).
 */
function luaEscape(s) {
	return s
		.replace(/\\/g, "\\\\")
		.replace(/"/g, '\\"')
		.replace(/\r/g, "\\r")
		.replace(/\n/g, "\\n")
		.replace(/\t/g, "\\t");
}

/**
 * Writes content to a file, creating parent directories as needed.
 * For .ahk files enforces UTF-8 BOM + CRLF line endings.
 * @param {string} filePath - Absolute path to write.
 * @param {string} content  - File content with LF line endings.
 */
function writeFile(filePath, content) {
	fs.mkdirSync(path.dirname(filePath), { recursive: true });
	if (filePath.endsWith(".ahk")) {
		// Enforce CRLF and prepend UTF-8 BOM (EF BB BF)
		const crlf    = content.replace(/\r\n/g, "\n").replace(/\n/g, "\r\n");
		const bom     = Buffer.from([0xef, 0xbb, 0xbf]);
		const body    = Buffer.from(crlf, "utf8");
		fs.writeFileSync(filePath, Buffer.concat([bom, body]));
	} else {
		fs.writeFileSync(filePath, content, "utf8");
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
	const defsLines = TERMINATOR_DEFS.map((def) => {
		const charsArr = def.chars
			.map((c) => `"${ahkEscape(c)}"`)
			.join(", ");
		const enabled  = def.default_enabled ? "true" : "false";
		const consume  = def.consume         ? "true" : "false";
		const label    = ahkEscape(def.label || def.key);
		return (
			`        Map("key", "${def.key}", ` +
			`"chars", [${charsArr}], ` +
			`"label", "${label}", ` +
			`"default_enabled", ${enabled}, ` +
			`"consume", ${consume})`
		);
	}).join(",\n");

	return [
		`; static/ergopti_plus/windows/_generated/terminators.ahk`,
		`; AUTO-GENERATED from shared/domain/Terminators.spec.js.`,
		`; DO NOT EDIT BY HAND — run \`npm run codegen:terminators\` to refresh.`,
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
		`            if entry["key"] = "magic_key" {`,
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
		`            return`,
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
		``,
	].join("\n");
}




// ==================================================
// ==================================================
// ======= 3/ Lua Generator =======
// ==================================================
// ==================================================

/**
 * Generates the Hammerspoon Lua Terminators module source.
 * @returns {string} Full file content with LF line endings.
 */
function generateLua() {
	// Build TERMINATOR_DEFS as a Lua table literal.
	const defsLines = TERMINATOR_DEFS.map((def) => {
		const charsArr = def.chars
			.map((c) => `"${luaEscape(c)}"`)
			.join(", ");
		const enabled  = def.default_enabled ? "true" : "false";
		const consume  = def.consume         ? "true" : "false";
		const label    = luaEscape(def.label || def.key);
		return (
			`\t{ key = "${def.key}", chars = { ${charsArr} }, ` +
			`label = "${label}", default_enabled = ${enabled}, consume = ${consume} }`
		);
	}).join(",\n");

	return [
		`--- static/ergopti_plus/macos/_generated/terminators.lua`,
		`--- AUTO-GENERATED from shared/domain/Terminators.spec.js.`,
		`--- DO NOT EDIT BY HAND — run \`npm run codegen:terminators\` to refresh.`,
		``,
		`--- ==============================================================================`,
		`--- CLASS: Terminators`,
		`--- DESCRIPTION:`,
		`--- Hammerspoon Lua implementation of the Terminators port contract. Owns the`,
		`--- terminator catalogue and the O(1) lookup tables used by the hotstring`,
		`--- engine. Generated from the shared spec so catalogue data is identical`,
		`--- across all drivers.`,
		`---`,
		`--- CONTRACT METHODS:`,
		`---   isTerminator(char)              — true if char belongs to an enabled slot.`,
		`---   isConsumed(char)                — true if the matching slot is consumed.`,
		`---   setEnabled(key, enabled)        — enable/disable a slot by key.`,
		`---   isEnabled(key)                  — query enabled state of a slot.`,
		`---   updateMagicKey(char)            — reassign the magic_key slot character.`,
		`---   addCustom(key, chars, label, consumed) — add a user-defined slot.`,
		`---   all()                           — return the full catalogue array.`,
		`--- ==============================================================================`,
		``,
		`local M = {}`,
		``,
		``,
		``,
		``,
		`-- ===========================================`,
		`-- ===========================================`,
		`-- ======= 1/ Constants & Catalogue =======`,
		`-- ===========================================`,
		`-- ===========================================`,
		``,
		`--- Built-in terminator definitions seeded from the shared spec.`,
		`M.TERMINATOR_DEFS = {`,
		defsLines,
		`}`,
		``,
		``,
		`-- Flat enable/disable table keyed by terminator key, seeded from default_enabled.`,
		`local _enabled = {}`,
		`for _, def in ipairs(M.TERMINATOR_DEFS) do`,
		`\t_enabled[def.key] = (def.default_enabled ~= false)`,
		`end`,
		``,
		``,
		`-- Cached O(1) lookup tables for the per-keystroke hot path. Rebuilt whenever`,
		`-- the catalogue is mutated (enable/disable, custom add, magic-key rename).`,
		`local _chars_set   = {}`,
		`local _consume_set = {}`,
		`local function rebuild_cache()`,
		`\t_chars_set   = {}`,
		`\t_consume_set = {}`,
		`\tfor _, def in ipairs(M.TERMINATOR_DEFS) do`,
		`\t\tif _enabled[def.key] and def.chars then`,
		`\t\t\tfor _, c in ipairs(def.chars) do`,
		`\t\t\t\tif type(c) == "string" and c ~= "" then`,
		`\t\t\t\t\t_chars_set[c] = true`,
		`\t\t\t\t\tif def.consume then _consume_set[c] = true end`,
		`\t\t\t\tend`,
		`\t\t\tend`,
		`\t\tend`,
		`\tend`,
		`end`,
		`rebuild_cache()`,
		``,
		``,
		``,
		``,
		`-- =========================================`,
		`-- =========================================`,
		`-- ======= 2/ Hot-Path Detection =======`,
		`-- =========================================`,
		`-- =========================================`,
		``,
		`--- Returns true if char belongs to any enabled terminator slot.`,
		`--- @param char string A single UTF-8 codepoint.`,
		`--- @return boolean`,
		`function M.isTerminator(char)`,
		`\treturn _chars_set[char] == true`,
		`end`,
		``,
		``,
		`--- Returns true if the enabled terminator for char is consumed (not echoed).`,
		`--- @param char string A single UTF-8 codepoint.`,
		`--- @return boolean`,
		`function M.isConsumed(char)`,
		`\treturn _consume_set[char] == true`,
		`end`,
		``,
		``,
		``,
		``,
		`-- =========================================`,
		`-- =========================================`,
		`-- ======= 3/ Enable / Disable =======`,
		`-- =========================================`,
		`-- =========================================`,
		``,
		`--- Enables or disables a terminator slot by key.`,
		`--- Logs and returns on unknown key per contract error_behavior.`,
		`--- @param key string The terminator key identifier.`,
		`--- @param enabled boolean True to enable, false to disable.`,
		`function M.setEnabled(key, enabled)`,
		`\tif _enabled[key] == nil then`,
		`\t\tprint(string.format("[Terminators] setEnabled: unknown key '%s'", tostring(key)))`,
		`\t\treturn`,
		`\tend`,
		`\t_enabled[key] = (enabled ~= false)`,
		`\trebuild_cache()`,
		`end`,
		``,
		``,
		`--- Returns true if the given terminator key is currently enabled.`,
		`--- @param key string The terminator key identifier.`,
		`--- @return boolean`,
		`function M.isEnabled(key)`,
		`\treturn _enabled[key] == true`,
		`end`,
		``,
		``,
		``,
		``,
		`-- =========================================`,
		`-- =========================================`,
		`-- ======= 4/ Magic Key Update =======`,
		`-- =========================================`,
		`-- =========================================`,
		``,
		`--- Reassigns the magic_key slot to a new character.`,
		`--- Rebuilds the O(1) lookup cache after the swap.`,
		`--- @param char string A single UTF-8 codepoint.`,
		`function M.updateMagicKey(char)`,
		`\tfor _, def in ipairs(M.TERMINATOR_DEFS) do`,
		`\t\tif def.key == "magic_key" then`,
		`\t\t\tdef.chars = { char }`,
		`\t\t\tbreak`,
		`\t\tend`,
		`\tend`,
		`\trebuild_cache()`,
		`end`,
		``,
		``,
		``,
		``,
		`-- =========================================`,
		`-- =========================================`,
		`-- ======= 5/ Custom Terminators =======`,
		`-- =========================================`,
		`-- =========================================`,
		``,
		`--- Adds a user-defined terminator slot.`,
		`--- Logs and returns on key collision per contract error_behavior.`,
		`--- @param key string Unique identifier (must not collide with built-in keys).`,
		`--- @param chars table Array of characters for this slot.`,
		`--- @param label string Display label.`,
		`--- @param consumed boolean Whether to swallow the character after expansion.`,
		`function M.addCustom(key, chars, label, consumed)`,
		`\tif _enabled[key] ~= nil then`,
		`\t\tprint(string.format("[Terminators] addCustom: key collision '%s'", tostring(key)))`,
		`\t\treturn`,
		`\tend`,
		`\ttable.insert(M.TERMINATOR_DEFS, {`,
		`\t\tkey             = key,`,
		`\t\tchars           = chars,`,
		`\t\tlabel           = label,`,
		`\t\tdefault_enabled = true,`,
		`\t\tconsume         = consumed or false,`,
		`\t\tcustom          = true,`,
		`\t})`,
		`\t_enabled[key] = true`,
		`\trebuild_cache()`,
		`end`,
		``,
		``,
		``,
		``,
		`-- =========================================`,
		`-- =========================================`,
		`-- ======= 6/ Catalogue Export =======`,
		`-- =========================================`,
		`-- =========================================`,
		``,
		`--- Returns a shallow copy of the full catalogue (enabled + disabled).`,
		`--- @return table`,
		`function M.all()`,
		`\tlocal copy = {}`,
		`\tfor _, def in ipairs(M.TERMINATOR_DEFS) do`,
		`\t\tcopy[#copy + 1] = def`,
		`\tend`,
		`\treturn copy`,
		`end`,
		``,
		``,
		`return M`,
		``,
	].join("\n");
}




// ==================================================
// ==================================================
// ======= 4/ Entry Point =======
// ==================================================
// ==================================================

const AHK_OUT = path.join(
	ROOT, "static/ergopti_plus/windows/_generated/terminators.ahk"
);
const LUA_OUT = path.join(
	ROOT, "static/ergopti_plus/macos/_generated/terminators.lua"
);

console.log("codegen:terminators — generating from terminators.spec.js…");
writeFile(AHK_OUT, generateAhk());
writeFile(LUA_OUT, generateLua());
console.log("codegen:terminators — done.");
