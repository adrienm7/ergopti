--- _shared/lua/tap_hold/key_catalog.lua

--- ==============================================================================
--- MODULE: Tap-Hold Key Catalogue (shared)
--- DESCRIPTION:
--- Reads `[tap_hold.catalog]` from `_shared/tap_hold/defaults.toml`: every key a
--- tap-hold can be set on, in tray order, with its hand and its label key, and
--- the id each driver's engine gives it. A driver asks for its own column and
--- gets its keys in order; the Tap-Hold submenu lists them under one header per
--- hand.
---
--- WHY THIS IS SHARED:
--- three drivers kept three lists, each claiming to mirror a menu-manifest key
--- (`tap_hold_keys_catalog`) that never existed. The macOS one fell back to a
--- built-in table in which `action = true` stood where `fn = true` was meant, so
--- Fn was listed under the right hand. The Windows reader of the same table is
--- windows/platform/remap/tap_hold_writer.ahk (_TH_BuildKeyDefs).
---
--- FAIL FAST: a malformed catalogue raises. A tray that silently guessed a hand
--- or a key would be the exact failure this table exists to end.
--- ==============================================================================

local M = {}

--- The driver columns an entry may carry.
M.PLATFORMS = { "ahk", "hs", "linux" }

--- The hands, in the order the Tap-Hold submenu shows them.
M.HANDS = { "left", "right" }

local KNOWN_FIELDS = { id = true, hand = true, label_key = true, ahk = true, hs = true, linux = true }




-- ==================================
-- ==================================
-- ======= 1/ Validation ============
-- ==================================
-- ==================================

--- Whether a value is a non-empty string.
--- @param value any
--- @return boolean
local function is_name(value)
	return type(value) == "string" and value ~= ""
end

--- Validates the whole catalogue, every column included, and raises on the
--- first defect so no driver reads a table another would refuse.
--- @param keys table The `keys` array of `[tap_hold.catalog]`.
local function validate(keys)
	local hands = {}
	for _, hand in ipairs(M.HANDS) do hands[hand] = true end
	local seen = {}
	local seen_by_platform = {}
	for _, platform in ipairs(M.PLATFORMS) do seen_by_platform[platform] = {} end
	for index, entry in ipairs(keys) do
		local where = string.format("[tap_hold.catalog] keys[%d]", index)
		if type(entry) ~= "table" then error(where .. " is not a table", 0) end
		if not is_name(entry.id) then error(where .. " has no id", 0) end
		where = where .. " '" .. entry.id .. "'"
		if seen[entry.id] then error(where .. " is listed twice", 0) end
		seen[entry.id] = true
		if not hands[entry.hand] then
			error(string.format("%s: hand must be 'left' or 'right', got '%s'", where, tostring(entry.hand)), 0)
		end
		if not is_name(entry.label_key) then error(where .. " has no label_key", 0) end
		local columns = 0
		for _, platform in ipairs(M.PLATFORMS) do
			local id = entry[platform]
			if id ~= nil then
				if not is_name(id) then error(string.format("%s: %s must be a key id", where, platform), 0) end
				if seen_by_platform[platform][id] then
					error(string.format("%s: the %s key '%s' is listed twice", where, platform, id), 0)
				end
				seen_by_platform[platform][id] = true
				columns = columns + 1
			end
		end
		if columns == 0 then error(where .. " names no driver's key", 0) end
		for field in pairs(entry) do
			if not KNOWN_FIELDS[field] then
				error(string.format("%s: unknown field '%s'", where, tostring(field)), 0)
			end
		end
	end
end




-- ==================================
-- ==================================
-- ======= 2/ Public API ============
-- ==================================
-- ==================================

--- One driver's keys, in catalogue order.
--- @param defaults table The decoded `_shared/tap_hold/defaults.toml`.
--- @param platform string "ahk", "hs" or "linux".
--- @return table Array of { id, key, hand, label_key }: `id` is the driver's own
---   key id, `key` the catalogue id.
function M.for_platform(defaults, platform)
	local known = false
	for _, name in ipairs(M.PLATFORMS) do known = known or name == platform end
	if not known then error("unknown tap-hold platform '" .. tostring(platform) .. "'", 2) end
	local catalog = type(defaults) == "table" and type(defaults.tap_hold) == "table"
		and defaults.tap_hold.catalog or nil
	if type(catalog) ~= "table" or type(catalog.keys) ~= "table" or #catalog.keys == 0 then
		error("the shared tap-hold defaults declare no [tap_hold.catalog] keys", 0)
	end
	validate(catalog.keys)
	local out = {}
	for _, entry in ipairs(catalog.keys) do
		if entry[platform] ~= nil then
			out[#out + 1] = { id = entry[platform], key = entry.id, hand = entry.hand, label_key = entry.label_key }
		end
	end
	if #out == 0 then error("[tap_hold.catalog] lists no key for '" .. platform .. "'", 0) end
	return out
end

--- Reads and validates the shared defaults document.
--- @param path string Absolute defaults path.
--- @return table decoded
local function read_defaults(path)
	local fh, open_err = io.open(path, "r")
	if not fh then error("cannot read the tap-hold key catalogue: " .. tostring(open_err), 0) end
	local text = fh:read("*a")
	fh:close()
	local ok, decoded = pcall(require("toml_codec").decode, text)
	if not ok or type(decoded) ~= "table" then
		error("the tap-hold key catalogue does not parse: " .. tostring(path), 0)
	end
	return decoded
end

--- Reads the shared defaults file and returns one driver's keys.
--- @param path string Absolute path of `_shared/tap_hold/defaults.toml`.
--- @param platform string "ahk", "hs" or "linux".
--- @return table See M.for_platform.
function M.load(path, platform)
	return M.for_platform(read_defaults(path), platform)
end

--- Resolves the shared typing-priority list to one driver's catalogue ids.
--- @param defaults table Decoded shared tap-hold defaults.
--- @param platform string Driver column.
--- @return table set Driver key id -> true; unsupported catalogue keys omitted.
function M.rollover_for_platform(defaults, platform)
	local catalog = M.for_platform(defaults, platform)
	local rollover = defaults.tap_hold.rollover
	local keys = type(rollover) == "table" and rollover.keys or nil
	if type(keys) ~= "table" or #keys == 0 then
		error("[tap_hold.rollover] declares no keys", 0)
	end
	local aliases, known, seen, result = {}, {}, {}, {}
	local count = 0
	for _, entry in ipairs(defaults.tap_hold.catalog.keys) do known[entry.id] = true end
	for _, entry in ipairs(catalog) do aliases[entry.key] = entry.id end
	for index, key in pairs(keys) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #keys
			or type(key) ~= "string" or not known[key] or seen[key] then
			error("[tap_hold.rollover] contains an invalid or repeated key: " .. tostring(key), 0)
		end
		count = count + 1
		seen[key] = true
		if aliases[key] then result[aliases[key]] = true end
	end
	if count ~= #keys then error("[tap_hold.rollover] keys must be dense", 0) end
	return result
end

--- Reads one driver's typing-priority key set from the shared defaults.
--- @param path string Absolute defaults path.
--- @param platform string Driver column.
--- @return table set Driver key id -> true.
function M.load_rollover(path, platform)
	return M.rollover_for_platform(read_defaults(path), platform)
end

--- The keys of one hand, in order.
--- @param keys table A result of M.for_platform.
--- @param hand string "left" or "right".
--- @return table
function M.of_hand(keys, hand)
	local out = {}
	for _, key in ipairs(keys) do
		if key.hand == hand then out[#out + 1] = key end
	end
	return out
end

return M
