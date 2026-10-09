--- modules/shortcuts/input_source_conflict.lua

--- ==============================================================================
--- MODULE: Input-Source Shortcut Conflict
--- DESCRIPTION:
--- Tells whether macOS's own input-source shortcuts still own a keyboard slot's
--- chord. "Select the previous input source" (symbolic hotkey 60, Ctrl+Space by
--- default) and "Select next source in Input menu" (61, Ctrl+Option+Space) are
--- handled by the system before any application: while one of them is enabled
--- on a slot's chord, the slot never fires, and nothing says why.
---
--- FEATURES & RATIONALE:
--- 1. Read through plutil, asynchronously: the preference file is small, but a
---    menu callback must not wait on a subprocess (hammerspoon-driver skill).
--- 2. An entry absent from the file is the macOS default, which is ENABLED: the
---    file only records what the user changed, so a fresh Mac has no entry for
---    60 and Ctrl+Space still switches the input source.
--- 3. Only the Space chords are checked: 60 and 61 are the two input-source
---    shortcuts and both live on Space unless the user moved them.
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local ShellRunner = require("adapters.shell_runner")
local JsonCodec   = require("adapters.json_codec")

local LOG = "shortcuts.input_source_conflict"

local PLUTIL = "/usr/bin/plutil"
local PREFERENCES_REL_PATH = "/Library/Preferences/com.apple.symbolichotkeys.plist"

-- The input-source shortcuts, by their symbolic hotkey id, with the value macOS
-- uses when the preference file has no entry for them: { character, virtual
-- key code, modifier flags }.
local INPUT_SOURCE_HOTKEYS = {
	{ id = "60", default = { enabled = true, value = { parameters = { 32, 49, 262144 } } } },
	{ id = "61", default = { enabled = true, value = { parameters = { 32, 49, 786432 } } } },
}

-- The virtual key code of each key a slot can name here.
local KEYCODE_OF = { space = 49 }

-- The NSEvent modifier flag of each canonical modifier.
local MODIFIER_FLAG = { shift = 131072, ctrl = 262144, alt = 524288, cmd = 1048576 }

-- Where the user turns the shortcuts off: Keyboard › Keyboard Shortcuts… ›
-- Input Sources.
M.SETTINGS_URL = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"





-- ====================================
-- ====================================
-- ======= 1/ Conflict decision =======
-- ====================================
-- ====================================

--- The input-source shortcuts that own a chord.
--- @param hotkeys table|nil The decoded AppleSymbolicHotKeys dictionary; nil
---   when the preference file records none (every shortcut at its default).
--- @param mods table Canonical modifier names of the chord.
--- @param key string Canonical key name of the chord.
--- @return table ids Symbolic hotkey ids, empty when nothing conflicts.
function M.conflicting_ids(hotkeys, mods, key)
	local keycode = KEYCODE_OF[key]
	if not keycode or type(mods) ~= "table" then return {} end
	local flags = 0
	for _, mod in ipairs(mods) do
		local flag = MODIFIER_FLAG[mod]
		if not flag then return {} end
		flags = flags + flag
	end
	local ids = {}
	for _, hotkey in ipairs(INPUT_SOURCE_HOTKEYS) do
		local entry = type(hotkeys) == "table" and hotkeys[hotkey.id] or nil
		if type(entry) ~= "table" then entry = hotkey.default end
		local enabled = entry.enabled == true or entry.enabled == 1
		local parameters = type(entry.value) == "table" and entry.value.parameters or nil
		if enabled and type(parameters) == "table"
			and parameters[2] == keycode and parameters[3] == flags then
			ids[#ids + 1] = hotkey.id
		end
	end
	return ids
end





-- =====================================
-- =====================================
-- ======= 2/ Preference reading =======
-- =====================================
-- =====================================

--- Reads the input-source shortcuts and reports which of them own a chord.
--- A non-zero plutil exit means the file or its dictionary is absent, which is
--- every shortcut at its macOS default; that reading is logged, not hidden.
--- @param mods table Canonical modifier names.
--- @param key string Canonical key name.
--- @param on_result function fn(ids) with the conflicting ids; not called when
---   the preferences could not be decoded (logged).
--- @return boolean started
function M.check(mods, key, on_result)
	if type(on_result) ~= "function" then
		Logger.error(LOG, "check(): a result callback is required.")
		return false
	end
	if not KEYCODE_OF[key] then
		on_result({})
		return true
	end
	local home = os.getenv("HOME")
	if type(home) ~= "string" or home == "" then
		Logger.error(LOG, "check(): HOME is not set — the input-source shortcuts cannot be read.")
		return false
	end
	local handle = ShellRunner.spawn(PLUTIL,
		{ "-extract", "AppleSymbolicHotKeys", "json", "-o", "-", home .. PREFERENCES_REL_PATH },
		function(exit_code, stdout, stderr)
			local hotkeys = nil
			if exit_code == 0 then
				local ok, decoded = pcall(JsonCodec.decode, stdout)
				if not ok or type(decoded) ~= "table" then
					Logger.warn(LOG, "Input-source shortcuts unreadable: %s.", tostring(decoded))
					return
				end
				hotkeys = decoded
			else
				Logger.info(LOG, "No customised input-source shortcut (plutil exit %s: %s) — macOS defaults apply.",
					tostring(exit_code), tostring(stderr))
			end
			on_result(M.conflicting_ids(hotkeys, mods, key))
		end)
	if not handle.start() then
		Logger.error(LOG, "check(): plutil could not start — the conflict is not checked.")
		return false
	end
	return true
end

return M
