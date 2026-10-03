--- _shared/lua/keymap/magic_key_source.lua

--- ==============================================================================
--- MODULE: Physical Magic Key (shared)
--- DESCRIPTION:
--- The decisions the two Lua drivers share about `hotstrings.magic_key_source`,
--- the physical key that types the magic key while the magic key's `replace`
--- section is on: which values name a key, which native key a value names,
--- which value a pressed key names, whether a press is plain enough to be
--- remapped, and the menu rows that choose the key.
---
--- FEATURES & RATIONALE:
--- 1. One value on every driver. The setting is a W3C KeyboardEvent.code, the
---    spelling layout extensions already use for their own magic key; the
---    physical-key registry (_shared/data/keycodes/physical_keys.json) gives each
---    driver its native id — the macOS virtual keycode, the Linux evdev code.
--- 2. The feature manifest owns the candidates and the automatic value. A value
---    outside its enum_values is outdated configuration: it reads as automatic
---    and the reader reports it, it never fails a boot.
--- 3. Data in, decisions out. The manifest entry and the decoded registry are
---    passed in, so this module reads no file and needs no driver API.
--- 4. Only a plain press is remapped. Shift, AltGr, Option and every shortcut
---    chord keep the key's own character and shortcuts, as Windows does for a
---    key the user chose (layout_registry.ahk LayoutRegistry_MagicKeyHotkeys).
--- ==============================================================================

local M = {}

-- The modifier names the two drivers report: macOS event flags (shift, ctrl,
-- alt, cmd) and the Linux hook's held modifiers (shift, ctrl, alt, altgr, meta).
local MODIFIERS = { "shift", "ctrl", "alt", "altgr", "meta", "cmd" }

-- The i18n keys of the menu rows, shared by both Lua drivers.
local LABEL_KEY = "menu.layout.magic_key_source"
local AUTOMATIC_KEY = "menu.layout.magic_key_source.auto"
local CAPTURE_KEY = "menu.layout.magic_key_source.capture"

-- Reuse the assignment-priority reason already translated for every driver.
M.TAP_CONFLICT_REASON = "menu.shortcuts.keyboard.magic_editor_reason.explicit_assignment"





-- ===============================
-- ===============================
-- ======= 1/ Construction =======
-- ===============================
-- ===============================

--- Reads the native id of one registry record, a per-form override first.
--- @param record table Registry record of one key.
--- @param field string Native id field ("hs", "evdev").
--- @param override string|nil Field of a per-form override record ("macos_iso").
--- @return number|nil native
local function native_of(record, field, override)
	local special = override and record[override]
	if type(special) == "table" and type(special[field]) == "number" then return special[field] end
	if type(record[field]) == "number" then return record[field] end
	return nil
end

--- Builds the resolver of one driver.
--- @param opts table {
---   entry    table       Manifest entry of hotstrings.magic_key_source ({ default, enum_values }).
---   registry table       Decoded physical_keys.json ({ keys = { [code] = record } }).
---   field    string      Registry field of this driver's native id ("hs", "evdev").
---   override string|nil  Registry field of a per-form override ("macos_iso"). }
--- @return table resolver
function M.new(opts)
	if type(opts) ~= "table" then error("magic_key_source.new needs options", 2) end
	local entry, registry, field = opts.entry, opts.registry, opts.field
	if type(entry) ~= "table" or type(entry.default) ~= "string" or type(entry.enum_values) ~= "table" then
		error("magic_key_source.new needs the manifest entry of hotstrings.magic_key_source", 2)
	end
	if type(registry) ~= "table" or type(registry.keys) ~= "table" then
		error("magic_key_source.new needs the decoded physical-key registry", 2)
	end
	if type(field) ~= "string" or field == "" then
		error("magic_key_source.new needs the registry field of the native id", 2)
	end

	assert(opts.aliases == nil or type(opts.aliases) == "table", "magic_key_source: aliases must be an array")
	for _, form in ipairs(opts.aliases or {}) do
		assert(type(form) == "string" and form ~= "", "magic_key_source: alias form must be a name")
	end
	local automatic = entry.default
	local candidates, native_for, code_for = {}, {}, {}
	for _, value in ipairs(entry.enum_values) do
		if value ~= automatic then
			local record = registry.keys[value]
			if type(record) ~= "table" then
				error("magic_key_source: '" .. tostring(value) .. "' is not in the physical-key registry", 2)
			end
			local native = native_of(record, field, opts.override)
			if native == nil then
				error("magic_key_source: '" .. tostring(value) .. "' has no " .. field .. " key", 2)
			end
			if code_for[native] ~= nil then
				error("magic_key_source: " .. field .. " key " .. tostring(native) .. " is named twice", 2)
			end
			candidates[#candidates + 1] = value
			native_for[value] = native
			code_for[native] = value
		end
	end
	if #candidates == 0 then error("magic_key_source: the manifest declares no candidate key", 2) end

	local resolver = { automatic = automatic }

	--- The candidate keys, in manifest (keyboard) order.
	--- @return table codes A fresh array.
	function resolver.candidates()
		local copy = {}
		for index, code in ipairs(candidates) do copy[index] = code end
		return copy
	end

	--- Whether a value names a candidate key.
	--- @param value any
	--- @return boolean
	function resolver.is_candidate(value)
		return type(value) == "string" and native_for[value] ~= nil
	end

	--- Reads a stored value: a candidate stays, an absent value is automatic,
	--- anything else is automatic and outdated.
	--- @param value any Stored value, nil when absent.
	--- @return string value
	--- @return string|nil outdated Why a present value was not used.
	function resolver.normalize(value)
		if value == nil or value == automatic then return automatic end
		if resolver.is_candidate(value) then return value end
		return automatic, "'" .. tostring(value) .. "' is no longer one of its values"
	end

	--- The native id of a value; nil for the automatic value.
	--- @param value string A candidate or the automatic value.
	--- @return number|nil native
	function resolver.native(value)
		if value == automatic then return nil end
		local native = native_for[value]
		if native == nil then error("magic_key_source: '" .. tostring(value) .. "' names no candidate key", 2) end
		return native
	end

	--- Every native identity a chosen key can use, including configured board forms.
	--- @param value string Candidate or automatic value.
	--- @return table native_codes Fresh, deduplicated native identity array.
	function resolver.native_codes(value)
		local primary = resolver.native(value)
		if primary == nil then return {} end
		local result, seen = { primary }, { [primary] = true }
		for _, form in ipairs(opts.aliases or {}) do
			local code = native_of(registry.keys[value], field, form)
			if code ~= nil and not seen[code] then
				seen[code] = true
				result[#result + 1] = code
			end
		end
		return result
	end

	--- The value naming a native key, nil when that key is no candidate.
	--- @param native any Native id of a pressed key.
	--- @return string|nil code
	function resolver.code_for(native)
		return code_for[native]
	end

	return resolver
end





-- =================================
-- =================================
-- ======= 2/ Press decision =======
-- =================================
-- =================================

--- Finds a configured tap assignment intersecting the source's actual native identities.
--- Temporary category or pause gates do not release the persisted assignment.
--- @param resolver table Physical-source resolver.
--- @param value string Candidate or automatic value.
--- @param keys table Canonical tap-key catalogue rows.
--- @param field string Native catalogue field (hs or linux).
--- @param get_action function Reads the recognized assignment of a tap id.
--- @return string|nil id Configured owner, nil when there is no conflict.
function M.tap_conflict(resolver, value, keys, field, get_action)
	assert(type(keys) == "table" and type(get_action) == "function", "magic_key_source: tap owners are required")
	local native = {}
	for _, code in ipairs(resolver.native_codes(value)) do native[code] = true end
	for _, key in ipairs(keys) do
		local ids = key[field]
		if type(ids) ~= "table" then ids = { ids } end
		for _, code in ipairs(ids) do
			if native[code] and get_action(key.id) ~= "none" then return key.id end
		end
	end
	return nil
end

--- Whether a press carries no modifier, the only press the remap takes.
--- @param mods table|nil Held modifiers, name to truthy (event flags or hook state).
--- @return boolean
function M.unmodified(mods)
	if type(mods) ~= "table" then return true end
	for _, name in ipairs(MODIFIERS) do
		if mods[name] then return false end
	end
	return true
end





-- ============================
-- ============================
-- ======= 3/ Menu rows =======
-- ============================
-- ============================

--- The label of one key: what the user's own layout types there, then its
--- KeyboardEvent.code, which names the same key on every keyboard.
--- @param code string Candidate code.
--- @param text string|nil Character the OS layout types on that key.
--- @return string
function M.label(code, text)
	if type(text) == "string" and text ~= "" and not text:match("^%s+$") then
		return text .. "   (" .. code .. ")"
	end
	return code
end

--- Builds the rows of the `magic_key_source` list: one row naming the key in
--- effect, whose submenu captures a key, restores the automatic key or lists
--- every candidate with the one in effect ticked. Windows draws the same rows
--- (windows/ui/editors.ahk MagicKeySourceMenuRows).
--- @param resolver table From M.new.
--- @param opts table {
---   t        fn(key) -> string        Translator.
---   current  string                   The value in effect.
---   key_text fn(code) -> string|nil   What the OS layout types on that key.
---   choose   fn(value)                Persists and applies a value.
---   capture  fn()|nil                 Captures the next key; nil greys the row. }
--- @return table rows
function M.menu_rows(resolver, opts)
	if type(resolver) ~= "table" or type(opts) ~= "table" then
		error("magic_key_source.menu_rows needs a resolver and options", 2)
	end
	for _, name in ipairs({ "t", "key_text", "choose" }) do
		if type(opts[name]) ~= "function" then error("magic_key_source.menu_rows needs " .. name, 2) end
	end
	local t, current = opts.t, opts.current
	-- A layout that cannot answer leaves the code alone: the row still names
	-- the key, and a menu build never fails on a keymap query.
	local function label_of(code)
		local ok, text = pcall(opts.key_text, code)
		return M.label(code, ok and text or nil)
	end
	local function chooser(value)
		return function() opts.choose(value) end
	end

	local capture = type(opts.capture) == "function" and opts.capture or nil
	local items = {
		{ label = t(CAPTURE_KEY), disabled = capture == nil or nil, action = capture },
		{ separator = true },
		{ label = t(AUTOMATIC_KEY), checked = current == resolver.automatic, action = chooser(resolver.automatic) },
		{ separator = true },
	}
	for _, code in ipairs(resolver.candidates()) do
		local reason = opts.reason and opts.reason(code) or nil
		local label = label_of(code)
		if reason ~= nil then label = label .. " — " .. t(reason) end
		items[#items + 1] = { label = label, checked = current == code,
			disabled = reason ~= nil or nil, action = reason == nil and chooser(code) or nil }
	end
	local shown = current == resolver.automatic and t(AUTOMATIC_KEY) or label_of(current)
	return { { label = t(LABEL_KEY) .. " : " .. shown, items = items } }
end

return M
