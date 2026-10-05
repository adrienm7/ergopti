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
---   - a hold is stored as the picker spells it: "Ctrl + Shift", "shift+ctrl"
---     and "AltGr" are read as "ctrl+shift" and "alt_gr" (the Windows loader
---     accepts the same spellings), and a modifier or layer no driver knows
---     is an outdated entry warned once and a hold dropped: the key keeps its
---     tap, as the Windows loader refuses an unknown hold where it reads it;
---   - a user key the Linux engine cannot remap, or a field no key has, is
---     warned once, naming tap_hold.toml, and left out; the rest applies;
---   - only [tap_hold] inherit_defaults = true lays the user file over the
---     shipped keys; otherwise it starts from no keys at all (an empty file is
---     the keyboard's own behaviour), and enabled = false switches the feature
---     off. The scope restore writes the preset explicitly instead;
---   - a threshold outside 0..10 s falls back to 0.2 s, a field of the wrong
---     type disables its key, and a malformed user file is reported and never
---     half-applied.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local TomlCodec = require("toml_codec")
local HoldOptions = require("tap_hold.hold_options")
local KeyCatalog = require("tap_hold.key_catalog")
local Manifest = require("infra.manifest_reader")
local Outdated = require("config_outdated")
local Shapes = require("platform.remap.tap_hold_shapes")

local LOG = "platform.remap.tap_hold_loader"

-- The Windows loader's bounds and fallback for time_activation_seconds.
local MAX_THRESHOLD_SECONDS = 10
M.FALLBACK_THRESHOLD_SECONDS = 0.2

local STRING_FIELDS = { "tap_action", "hold_modifier", "hold_layer" }

-- The per-key fields that decide what a key does, compared by key_report().
local BEHAVIOUR_FIELDS = { "tap_action", "hold_modifier", "hold_layer", "time_activation_seconds" }

-- Every field a tap-hold key has (the writer's OWNED_KEY_FIELDS).
local KEY_FIELDS = {
	tap_action = true, hold_modifier = true, hold_layer = true, enabled = true, time_activation_seconds = true,
}

-- What a warning names when a candidate document has no file path yet.
local USER_FILE_NAME = "tap_hold.toml"

--- Reads and decodes one TOML file.
--- @param path string
--- @return table|nil parsed, string|nil err ("absent" when the file does not exist)
local function read_toml(path, with_shapes)
	local fh = io.open(path, "r")
	if not fh then return nil, "absent" end
	local text = fh:read("*a")
	fh:close()
	local parsed, shapes
	if with_shapes then
		parsed, shapes = TomlCodec.decode_with_shapes(text)
	else
		-- Shipped data retains the established codec model; only user source
		-- needs the optional namespace identity receipt.
		parsed = TomlCodec.decode(text)
	end
	if type(parsed) ~= "table" then return nil, "malformed" end
	return parsed, nil, shapes
end

-- The hold fields and how each one is canonicalised.
local HOLD_FIELDS = {
	hold_modifier = HoldOptions.canonical_modifier,
	hold_layer = HoldOptions.canonical_layer,
}

--- Validates one key's fields; a bad field disables the key. A value the
--- user's file holds that this build no longer accepts is an outdated entry:
--- warned once, naming the file, never an ERROR. The same value in the shipped
--- defaults is a shipped-data bug, and stays an ERROR.
--- @param key_id string
--- @param fields table
--- @param hold_picker table|nil The shared `[tap_hold.hold_picker]` catalogue.
--- @param origin function origin(field) -> the file the field's value came
---   from, and whether that file is the user's.
--- @return table
local function validated(key_id, fields, hold_picker, origin)
	local key = {}
	for field, value in pairs(fields) do key[field] = value end
	local function outdated(field, detail)
		local file, from_user = origin(field)
		if from_user then
			Outdated.report_in_file(file, { "tap_hold", "keys", key_id, field }, detail)
		else
			Logger.error(LOG, "Shipped tap-hold defaults '%s': [tap_hold.keys.%s] %s — %s.", file, key_id, field, detail)
		end
	end
	for _, field in ipairs(STRING_FIELDS) do
		if key[field] ~= nil and type(key[field]) ~= "string" then
			outdated(field, "it must be a string; the key is disabled")
			key.enabled = false
		end
	end
	for field, canonical_of in pairs(HOLD_FIELDS) do
		if type(key[field]) == "string" then
			local canonical, err = canonical_of(key[field], hold_picker)
			if canonical then
				key[field] = canonical
			else
				-- The hold alone goes, as the Windows loader drops it
				-- (_TapHold_ParseFileInto): the key keeps its tap, so a
				-- CapsLock with a mistyped hold still types Enter.
				outdated(field, string.format("'%s': %s; the key keeps its tap and holds nothing", key[field], err))
				key[field] = nil
			end
		end
	end
	if key.enabled ~= nil and type(key.enabled) ~= "boolean" then
		outdated("enabled", "it must be true or false; the key is disabled")
		key.enabled = false
	end
	local seconds = tonumber(key.time_activation_seconds)
	if not seconds or seconds <= 0 or seconds > MAX_THRESHOLD_SECONDS then
		if key.time_activation_seconds ~= nil then
			outdated("time_activation_seconds", string.format("%s is outside 0..%d s; %.1f s is used",
				tostring(key.time_activation_seconds), MAX_THRESHOLD_SECONDS, M.FALLBACK_THRESHOLD_SECONDS))
		end
		key.time_activation_seconds = M.FALLBACK_THRESHOLD_SECONDS
	end
	return key
end

--- Reads the shared defaults, failing fast when the shipped file is unusable.
--- @param defaults_path string The shared defaults.toml.
--- @return table defaults Decoded defaults document.
local function read_defaults(defaults_path)
	local defaults, defaults_err = read_toml(defaults_path)
	if not defaults then
		error(string.format("tap-hold defaults unreadable (%s): %s", tostring(defaults_err), tostring(defaults_path)), 0)
	end
	return defaults
end

--- The shipped preset keys ([tap_hold.keys.*]), as detached raw fields. They
--- are Ergopti's recommendation, written explicitly by a scope restore; the
--- loader applies them only to a file that asks to inherit them.
--- @param defaults_path string The shared defaults.toml.
--- @return table keys key id -> { field = value }
function M.preset_keys(defaults_path)
	local defaults = read_defaults(defaults_path)
	local base = type(defaults.tap_hold) == "table" and type(defaults.tap_hold.keys) == "table"
		and defaults.tap_hold.keys or {}
	local keys = {}
	for key_id, fields in pairs(base) do
		if type(fields) == "table" then
			keys[key_id] = {}
			for field, value in pairs(fields) do keys[key_id][field] = value end
		end
	end
	return keys
end

--- Loads the effective configuration.
--- @param defaults_path string The shared defaults.toml.
--- @param user_path string|nil The user's tap_hold.toml.
--- @return table { enabled = boolean, keys = { [id] = fields }, user_error = string|nil,
---   hold_picker = table|nil, catalog = table } `catalog` is this driver's column
---   of the shared key catalogue: the keys the tray lists, in order, with hands.
function M.load(defaults_path, user_path)
	local user, user_err, shapes = nil, nil, nil
	if user_path then
		user, user_err, shapes = read_toml(user_path, true)
		if user_err == "absent" then user_err = nil end
		if user_err then Logger.error(LOG, "User tap_hold.toml '%s' is %s — tap-holds remain neutral.", user_path, user_err) end
	end
	return M.load_document(defaults_path, user, user_err, user_path, shapes)
end

--- Builds the effective configuration from an already decoded user document,
--- so a scope transaction can acknowledge its candidate before publishing it.
--- A user key this driver cannot remap, or a field no tap-hold key has, is an
--- outdated entry: warned once and left out, and the rest of the file applies.
--- @param defaults_path string The shared defaults.toml.
--- @param user table|nil Decoded user document; nil means no user file.
--- @param user_err string|nil Why the user file could not be read.
--- @param user_path string|nil Where the user document lives, named by warnings.
--- @param shapes table|nil Canonical receipt bound to this decoded document.
--- @return table Same shape as M.load(), plus `user_fields`: key id -> the
---   fields the user file sets.
function M.load_document(defaults_path, user, user_err, user_path, shapes)
	assert(shapes == nil or (type(shapes) == "table" and type(shapes.arrays) == "table"
		and shapes.document == user), "tap-hold shape receipt belongs to another document")
	local defaults = read_defaults(defaults_path)
	local base = type(defaults.tap_hold) == "table" and type(defaults.tap_hold.keys) == "table"
		and defaults.tap_hold.keys or {}
	local user_file = user_path or USER_FILE_NAME
	local function table_or_absent(value, path)
		if value == nil then return {} end
		if Shapes.is_table(value, shapes) then return value end
		Outdated.report_in_file(user_file, path, "it must be a table, not a scalar or array; repair the stored entry by hand")
		return {}
	end
	local section = table_or_absent(user and user.tap_hold, { "tap_hold" })
	local overrides = table_or_absent(section.keys, { "tap_hold", "keys" })
	local global = {}
	for _, field in ipairs({ "enabled", "inherit_defaults" }) do
		local value = section[field]
		if value ~= nil and type(value) ~= "boolean" then
			Outdated.report_in_file(user_file, { "tap_hold", field }, "it must be true or false; the stored value is ignored")
		else
			global[field] = value
		end
	end
	-- Shipped data like the hold picker: a user file cannot move a key.
	local catalog = KeyCatalog.for_platform(defaults, "linux")
	local remappable = {}
	for _, entry in ipairs(catalog) do remappable[entry.id] = true end
	local keys = {}
	if global.inherit_defaults == true then
		for key_id, fields in pairs(base) do
			if type(fields) == "table" then
				keys[key_id] = {}
				for field, value in pairs(fields) do keys[key_id][field] = value end
			end
		end
	end
	local user_fields = {}
	for key_id, override in pairs(overrides) do
		if not remappable[key_id] then
			Outdated.report_in_file(user_file, { "tap_hold", "keys", tostring(key_id) },
				"the Linux engine has no such tap-hold key")
		elseif Shapes.is_table(override, shapes) then
			local merged = keys[key_id] or {}
			user_fields[key_id] = {}
			-- A modifier hold and a layer hold exclude each other: the user's
			-- choice of one drops the default's other.
			if override.hold_modifier ~= nil then merged.hold_layer = nil end
			if override.hold_layer ~= nil then merged.hold_modifier = nil end
			for field, value in pairs(override) do
				if KEY_FIELDS[field] then
					merged[field] = value
					user_fields[key_id][field] = true
				else
					Outdated.report_in_file(user_file, { "tap_hold", "keys", key_id, tostring(field) },
						"no tap-hold key has this field")
				end
			end
			keys[key_id] = merged
		else
			Outdated.report_in_file(user_file, { "tap_hold", "keys", key_id },
				"it must be a table, not a scalar or array; repair the stored entry by hand")
		end
	end
	-- The hold picker's catalogue is the shipped one: a user file changes what a
	-- key does, not what the tray offers or what a hold may be.
	local hold_picker = type(defaults.tap_hold) == "table" and defaults.tap_hold.hold_picker or nil
	-- The typing keys decided by the order of the releases are the shipped list
	-- too: every driver reads the same one.
	local rollover = type(defaults.tap_hold) == "table" and defaults.tap_hold.rollover or nil
	local roll_keys = type(rollover) == "table" and rollover.keys or nil
	if type(roll_keys) ~= "table" then
		error(tostring(defaults_path) .. ": [tap_hold.rollover] declares no keys", 0)
	end
	for key_id, fields in pairs(keys) do
		local set_by_user = user_fields[key_id] or {}
		keys[key_id] = validated(key_id, fields, hold_picker, function(field)
			if set_by_user[field] then return user_file, true end
			return defaults_path, false
		end)
	end

	return {
		enabled = global.enabled == true or (global.enabled == nil and Manifest.default_for("tap_holds.enabled")),
		keys = keys,
		user_error = user_err,
		user_path = user_file,
		user_fields = user_fields,
		hold_picker = hold_picker,
		roll_keys = roll_keys,
		catalog = catalog,
	}
end

--- Whether a loaded key does exactly what the recommendation does.
--- @param fields table Validated fields of the key.
--- @param recommended table|nil Validated fields of its recommendation.
--- @return boolean
local function behaves_as(fields, recommended)
	if type(recommended) ~= "table" or (fields.enabled ~= false) ~= (recommended.enabled ~= false) then
		return false
	end
	for _, field in ipairs(BEHAVIOUR_FIELDS) do
		if fields[field] ~= recommended[field] then return false end
	end
	return true
end

--- The first-run wizard's view of a folder's tap_hold.toml: the Tap-Holds
--- switch in force and each key it configures, as the shipped recommendation or
--- as the user's own setting, compared through the same validation the engine
--- runs. A key the file leaves to the keyboard is absent, so the wizard may
--- import it; it never imports over another one.
--- @param defaults_path string The shared defaults.toml.
--- @param user_path string The folder's tap_hold.toml.
--- @return table|nil report `{ enabled = boolean, keys = { [id] = "recommended"|"customised" } }`
--- @return string|nil err Why the file could not be read.
function M.key_report(defaults_path, user_path)
	local user, user_err, shapes = read_toml(user_path, true)
	if user_err == "absent" then user, user_err = nil, nil end
	if user_err then return nil, "'" .. tostring(user_path) .. "' is " .. user_err end
	local loaded = M.load_document(defaults_path, user, nil, user_path, shapes)
	local recommended = M.load_document(defaults_path,
		{ tap_hold = { keys = M.preset_keys(defaults_path) } }, nil).keys
	local keys = {}
	for key_id, fields in pairs(loaded.keys) do
		keys[key_id] = behaves_as(fields, recommended[key_id]) and "recommended" or "customised"
	end
	return { enabled = loaded.enabled, keys = keys }
end

return M
