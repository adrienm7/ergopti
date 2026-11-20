--- _shared/shortcuts/engine/magic_key_save_core.lua

--- ==============================================================================
--- MODULE: Modifiers + Magic Key Save Policy
--- DESCRIPTION:
--- Decides what a press of the layout's own magic key does when modifiers are
--- held: ★ alone stays the magic key, and a shortcut chord on it sends the same
--- modifiers with S (Ctrl+Shift+★ gives Ctrl+Shift+S). The three drivers apply
--- this one rule; the AHK twin (_shared/shortcuts/data/magic_key_save.ahk) and
--- this module replay the common corpus
--- (_shared/tests/corpus/shortcuts/magic_key_save_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. A shortcut chord holds Ctrl, Alt or the system key (Win, Cmd, Super).
---    Shift alone selects the key's own Shift level and never saves; it is kept
---    as an extra modifier of a shortcut chord.
--- 2. The AltGr exception: the chord that selects the layout's AltGr level keeps
---    typing the layout's AltGr character. Windows reads AltGr as Ctrl+Alt
---    without Win, macOS as Option without Cmd or Ctrl, Linux as its own level
---    three modifier, whatever else is held.
--- 3. A keyboard shortcut assigned to the exact chord keeps it, the physical
---    magic editor's system key + ★ included: the save takes only the chords no
---    shortcut owns.
--- 4. Only while the magic key is replaced, the driver is not paused and the key
---    is the layout's own magic key: a physical key the user chose
---    (hotstrings.magic_key_source) keeps every chord the layout gives it.
--- ==============================================================================

local M = {}

-- The letter the chord sends, and the canonical modifier order of the chord sent.
M.SAVE_KEY = "s"
M.ORDER = { "ctrl", "alt", "shift", "meta" }

-- The modifiers that make a press a shortcut chord.
local SHORTCUT = { ctrl = true, alt = true, meta = true }

-- The modifiers each OS reports for a press.
local KNOWN = {
	windows = { ctrl = true, alt = true, shift = true, meta = true },
	macos = { ctrl = true, alt = true, shift = true, meta = true },
	linux = { ctrl = true, alt = true, shift = true, meta = true, altgr = true },
}

-- Whether the held modifiers select the layout's AltGr level on one OS.
local ALTGR = {
	windows = function(held) return held.ctrl and held.alt and not held.meta end,
	macos = function(held) return held.alt and not held.ctrl and not held.meta end,
	linux = function(held) return held.altgr end,
}





-- ================================
-- ================================
-- ======= 1/ The modifiers =======
-- ================================
-- ================================

--- Normalizes a list or set of held modifiers, refusing a name the OS lacks.
--- @param os_name string "windows", "macos" or "linux".
--- @param held table List { "ctrl", ... } or set { ctrl = true, ... }.
--- @return table set { [name] = true }.
local function held_set(os_name, held)
	local known = KNOWN[os_name]
	assert(known, "magic key save: unknown OS " .. tostring(os_name))
	assert(type(held) == "table", "magic key save: the held modifiers are missing")
	local set = {}
	for key, value in pairs(held) do
		local name = type(key) == "number" and value or (value == true and key or nil)
		if name ~= nil then
			assert(known[name], "magic key save: " .. os_name .. " reports no modifier " .. tostring(name))
			set[name] = true
		end
	end
	return set
end

--- The modifiers a chord of the magic key sends with S.
--- @param os_name string "windows", "macos" or "linux".
--- @param held table Held modifiers, as a list or a set.
--- @return table|nil sends Modifier names in M.ORDER, nil when the press stays the layout's.
--- @return string|nil reason "no_shortcut_modifier" or "altgr_level" when nil.
function M.decide(os_name, held)
	local set = held_set(os_name, held)
	local shortcut = false
	for name in pairs(SHORTCUT) do
		if set[name] then shortcut = true end
	end
	if not shortcut and not set.altgr then return nil, "no_shortcut_modifier" end
	if ALTGR[os_name](set) then return nil, "altgr_level" end
	if not shortcut then return nil, "no_shortcut_modifier" end
	local sends = {}
	for _, name in ipairs(M.ORDER) do
		if set[name] then sends[#sends + 1] = name end
	end
	return sends
end





-- ==================================
-- ==================================
-- ======= 2/ The whole press =======
-- ==================================
-- ==================================

--- Decides one press of a key with modifiers held.
--- @param input table { os, held, paused, replace_on, chosen_source, is_magic_key,
---   shortcut_owns } where every gate is a boolean the driver read at the press.
--- @return table decision { action = "save", sends } or { action = "pass", reason }.
function M.resolve(input)
	assert(type(input) == "table", "magic key save: the press is missing")
	for _, gate in ipairs({ "paused", "replace_on", "chosen_source", "is_magic_key", "shortcut_owns" }) do
		assert(type(input[gate]) == "boolean", "magic key save: the gate " .. gate .. " is not a boolean")
	end
	if input.paused then return { action = "pass", reason = "paused" } end
	if not input.replace_on then return { action = "pass", reason = "magic_key_not_replaced" } end
	if input.chosen_source then return { action = "pass", reason = "chosen_source" } end
	if not input.is_magic_key then return { action = "pass", reason = "not_magic_key" } end
	local sends, reason = M.decide(input.os, input.held)
	if sends == nil then return { action = "pass", reason = reason } end
	if input.shortcut_owns then return { action = "pass", reason = "shortcut_owns_chord" } end
	return { action = "save", sends = sends }
end

return M
