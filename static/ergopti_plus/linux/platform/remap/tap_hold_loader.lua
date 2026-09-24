--- platform/remap/tap_hold_loader.lua

--- ==============================================================================
--- MODULE: Tap-Hold Configuration (Linux)
--- DESCRIPTION:
--- Reads the tap-hold keys from the shared defaults
--- (_shared/tap_hold/defaults.toml) and the user's tap_hold.toml, with the
--- rules the Windows loader applies to the same files:
---   - the user file is laid over the defaults key by key and field by field;
---   - choosing a hold modifier drops the default layer and the reverse, so a
---     key is never both;
---   - tap_action "" is the native key and "none" swallows it, hold_modifier ""
---     is no hold;
---   - [tap_hold] inherit_defaults = false starts from no keys at all (what
---     "Disable all" writes) and enabled = false switches the feature off;
---   - a threshold outside 0..10 s falls back to 0.2 s, a field of the wrong
---     type disables its key, and a malformed user file is reported and never
---     half-applied.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local TomlCodec = require("toml_codec")

local LOG = "platform.remap.tap_hold_loader"

-- The Windows loader's bounds and fallback for time_activation_seconds.
local MAX_THRESHOLD_SECONDS = 10
M.FALLBACK_THRESHOLD_SECONDS = 0.2

local STRING_FIELDS = { "tap_action", "hold_modifier", "hold_layer" }

--- Reads and decodes one TOML file.
--- @param path string
--- @return table|nil parsed, string|nil err ("absent" when the file does not exist)
local function read_toml(path)
	local fh = io.open(path, "r")
	if not fh then return nil, "absent" end
	local text = fh:read("*a")
	fh:close()
	local parsed = TomlCodec.decode(text)
	if type(parsed) ~= "table" then return nil, "malformed" end
	return parsed
end

--- Validates one key's fields; a bad field disables the key.
--- @param key_id string
--- @param fields table
--- @return table
local function validated(key_id, fields)
	local key = {}
	for field, value in pairs(fields) do key[field] = value end
	for _, field in ipairs(STRING_FIELDS) do
		if key[field] ~= nil and type(key[field]) ~= "string" then
			Logger.error(LOG, "Tap-hold key '%s': %s must be a string — key disabled.", key_id, field)
			key.enabled = false
		end
	end
	if key.enabled ~= nil and type(key.enabled) ~= "boolean" then
		Logger.error(LOG, "Tap-hold key '%s': enabled must be true or false — key disabled.", key_id)
		key.enabled = false
	end
	local seconds = tonumber(key.time_activation_seconds)
	if not seconds or seconds <= 0 or seconds > MAX_THRESHOLD_SECONDS then
		if key.time_activation_seconds ~= nil then
			Logger.warn(LOG, "Tap-hold key '%s': threshold %s is outside 0..%d s — using %.1f s.",
				key_id, tostring(key.time_activation_seconds), MAX_THRESHOLD_SECONDS, M.FALLBACK_THRESHOLD_SECONDS)
		end
		key.time_activation_seconds = M.FALLBACK_THRESHOLD_SECONDS
	end
	return key
end

--- Loads the effective configuration.
--- @param defaults_path string The shared defaults.toml.
--- @param user_path string|nil The user's tap_hold.toml.
--- @return table { enabled = boolean, keys = { [id] = fields }, user_error = string|nil }
function M.load(defaults_path, user_path)
	local defaults, defaults_err = read_toml(defaults_path)
	if not defaults then
		error(string.format("tap-hold defaults unreadable (%s): %s", tostring(defaults_err), tostring(defaults_path)), 0)
	end
	local base = type(defaults.tap_hold) == "table" and type(defaults.tap_hold.keys) == "table"
		and defaults.tap_hold.keys or {}

	local user, user_err = nil, nil
	if user_path then
		user, user_err = read_toml(user_path)
		if user_err == "absent" then user_err = nil end
		if user_err then Logger.error(LOG, "User tap_hold.toml '%s' is %s — shared defaults used.", user_path, user_err) end
	end
	local section = user and type(user.tap_hold) == "table" and user.tap_hold or {}
	local overrides = type(section.keys) == "table" and section.keys or {}

	local keys = {}
	if section.inherit_defaults ~= false then
		for key_id, fields in pairs(base) do
			if type(fields) == "table" then
				keys[key_id] = {}
				for field, value in pairs(fields) do keys[key_id][field] = value end
			end
		end
	end
	for key_id, override in pairs(overrides) do
		if type(override) == "table" then
			local merged = keys[key_id] or {}
			-- A modifier hold and a layer hold exclude each other: the user's
			-- choice of one drops the default's other.
			if override.hold_modifier ~= nil then merged.hold_layer = nil end
			if override.hold_layer ~= nil then merged.hold_modifier = nil end
			for field, value in pairs(override) do merged[field] = value end
			keys[key_id] = merged
		end
	end
	for key_id, fields in pairs(keys) do keys[key_id] = validated(key_id, fields) end

	return { enabled = section.enabled ~= false, keys = keys, user_error = user_err }
end

return M
