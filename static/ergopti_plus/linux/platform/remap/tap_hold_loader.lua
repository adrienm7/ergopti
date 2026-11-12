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
---   - a user key no driver has, or a field no key has, is warned once,
---     naming tap_hold.toml, and left out; a catalogue key only another driver
---     has (the file is shared, _shared/tap_hold/SCHEMA.md) is left out
---     silently; the rest applies;
---   - only [tap_hold] inherit_defaults = true lays the user file over the
---     shipped keys; otherwise it starts from no keys at all (an empty file is
---     the keyboard's own behaviour). The scope restore writes the preset
---     explicitly instead;
---   - the switch and the two timings are manifest rows, read from config.toml
---     `[tap_holds]` (enabled, lone_modifier_tap_max_ms, sticky_timeout_ms), as
---     on every OS (maintainer decision of 2026-11-11). The same leaves still
---     found in tap_hold.toml `[tap_hold]` are left there by a migration that
---     could not finish: warned once, never read;
---   - a key's delay is its own `time_activation_seconds` when the user set one,
---     else the global delay: `[tap_hold] time_activation_seconds` when the user
---     set it, else the timing registry's default. No shipped key carries a
---     delay. The per-key delays this build used to ship, copied into a file by
---     a rewrite, are removed once by the versioned migration of
---     _shared/tap_hold/migrations.toml (platform/remap/tap_hold_migration.lua);
---     a file not yet migrated on disk is read as the migration leaves it;
---   - a threshold outside 0..10 s falls back to the global delay, a field of
---     the wrong type disables its key, and a malformed user file is reported and
---     never half-applied.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local TomlCodec = require("toml_codec")
local Writer = require("toml_codec.writer")
local HoldOptions = require("tap_hold.hold_options")
local KeyCatalog = require("tap_hold.key_catalog")
local Manifest = require("infra.manifest_reader")
local Outdated = require("config_outdated")
local Shapes = require("platform.remap.tap_hold_shapes")
local Migration = require("platform.remap.tap_hold_migration")
local ConfigKeys = require("config_keys")
local LoneTap = require("tap_hold.lone_tap")

local LOG = "platform.remap.tap_hold_loader"
local TIME_FIELD = require("config_keys").LEAF.TIME_ACTIVATION_SECONDS

-- The Windows loader's bound for time_activation_seconds; the global default is
-- the timing registry's, the one declaration every driver reads or is pinned to.
local MAX_THRESHOLD_SECONDS = 10
M.GLOBAL_DEFAULT_SECONDS = require("infra.timings").ms("tap_hold", "default_activation_ms") / 1000

-- How long a modifier key pressed alone still taps (config.toml [tap_holds]
-- lone_modifier_tap_max_ms, the manifest's tap_holds.lone_modifier_tap_max_ms).
M.LONE_TAP_FIELD = ConfigKeys.LEAF.LONE_MODIFIER_TAP_MAX_MS
local LONE_TAP_FIELD = M.LONE_TAP_FIELD
M.LONE_TAP_DEFAULT_MS = LoneTap.validate(Manifest.default_for(ConfigKeys.KEY.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS))

-- How long a one-shot Shift waits for its key (config.toml [tap_holds]
-- sticky_timeout_ms): a positive whole number of milliseconds within the timer
-- ceiling, the timing registry's default when absent. No zero or unlimited
-- value: macOS refuses them too.
M.ONE_SHOT_TIMEOUT_FIELD = ConfigKeys.LEAF.STICKY_TIMEOUT_MS
local ONE_SHOT_TIMEOUT_FIELD = M.ONE_SHOT_TIMEOUT_FIELD
M.ONE_SHOT_TIMEOUT_DEFAULT_MS = require("infra.timings").ms("tap_hold", "one_shot_shift_timeout_ms")

--- Whether a value is an admitted one-shot timeout.
--- @param ms any
--- @return boolean
function M.valid_one_shot_timeout_ms(ms)
	return type(ms) == "number" and require("number_policy").within_timer_ceiling(ms) and ms > 0 and ms % 1 == 0
end

local STRING_FIELDS = { "tap_action", "hold_modifier", "hold_layer" }

-- The per-key fields that decide what a key does, compared by key_report(). A
-- delay of the key's own is checked apart: the global delay is no key's setting.
local BEHAVIOUR_FIELDS = { "tap_action", "hold_modifier", "hold_layer" }

-- Every field a tap-hold key has (the writer's OWNED_KEY_FIELDS).
local KEY_FIELDS = {
	tap_action = true, hold_modifier = true, hold_layer = true, enabled = true, time_activation_seconds = true,
}

-- What a warning names when a candidate document has no file path yet.
local USER_FILE_NAME = require("tap_hold.shared_file").FILE_NAME

-- The [tap_hold] leaves config.toml [tap_holds] owns since config schema v22.
local CONFIG_OWNED_FIELDS = { "enabled", LONE_TAP_FIELD, ONE_SHOT_TIMEOUT_FIELD }

-- The shared file's layout, read once: [thumb_positions] places each Mac thumb
-- key on the PC key at its position (maintainer decision TCL-004).
local shared_spec = nil

--- The shared file's spec (_shared/tap_hold/shared_file.toml).
--- @return table See tap_hold.shared_file.parse_spec.
local function shared_file_spec()
	if shared_spec == nil then
		local path = require("infra.paths").shared("tap_hold/shared_file.toml")
		local text, status = Writer.read_classified(path)
		if status ~= "ok" or type(text) ~= "string" then
			error("the shared tap-hold file spec is unreadable: " .. tostring(path), 0)
		end
		shared_spec = require("tap_hold.shared_file").parse_spec(TomlCodec.decode(text))
	end
	return shared_spec
end

--- Reads and decodes one TOML file.
--- @param path string
--- @return table|nil parsed, string|nil err ("absent" when the file does not exist)
local function read_toml(path, with_shapes)
	local text, status = Writer.read_classified(path)
	if status == "absent" then return nil, "absent" end
	if status ~= "ok" or type(text) ~= "string" then return nil, "unreadable" end
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
--- @param global_seconds number The delay of a key that has none of its own.
--- @return table
local function validated(key_id, fields, hold_picker, origin, global_seconds)
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
				-- The left aliases (lctrl, lshift) name the left key even on the
				-- right Ctrl / Shift key: the spelling is read before it is
				-- canonicalised away, then rides along as `hold_left_modifiers`.
				if field == "hold_modifier" then
					-- A string, not a table: the manager compares keys field by field.
					key.hold_left_modifiers = HoldOptions.left_forced(key[field], hold_picker)
				end
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
	-- The key's own delay when it has a usable one, else the global delay.
	local seconds = key.time_activation_seconds
	if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 or seconds > MAX_THRESHOLD_SECONDS then
		if key.time_activation_seconds ~= nil then
			outdated(TIME_FIELD, string.format("%s is outside 0..%d s; the global delay %.3f s is used",
				tostring(key.time_activation_seconds), MAX_THRESHOLD_SECONDS, global_seconds))
		end
		key.time_activation_seconds = global_seconds
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

--- The config.toml beside a tap_hold.toml, where the switch and the timings
--- live: infra/config_paths.lua keeps every configuration file of a folder
--- together.
--- @param path string The tap_hold.toml path.
--- @return string
function M.config_path_for(path)
	local folder = assert(require("native_path").dirname(path), "tap_hold.toml needs a configuration folder")
	return folder .. "/config.toml"
end

--- Reads the config.toml the switch and the timings live in; an absent file is
--- an empty document, an unreadable or malformed one is reported and read as
--- absent, so every setting takes its default and nothing is half applied.
--- @param config_path string|nil
--- @return table|nil document
--- @return string|nil err
function M.read_config(config_path)
	if not config_path then return nil end
	local document, err = read_toml(config_path)
	if err == "absent" then return nil end
	if err then
		Logger.error(LOG, "'%s' is %s — the tap-hold switch and timings take their defaults.", config_path, err)
		return nil, err
	end
	return document
end

--- Loads the effective configuration.
--- @param defaults_path string The shared defaults.toml.
--- @param user_path string|nil The user's tap_hold.toml.
--- @param config_path string|nil The config.toml beside it, which holds the
---   switch and the timings; nil reads them as their defaults.
--- @return table { enabled = boolean, keys = { [id] = fields }, user_error = string|nil,
---   hold_picker = table|nil, catalog = table } `catalog` is this driver's column
---   of the shared key catalogue: the keys the tray lists, in order, with hands.
function M.load(defaults_path, user_path, config_path)
	local user, user_err, shapes = nil, nil, nil
	if user_path then
		user, user_err, shapes = read_toml(user_path, true)
		if user_err == "absent" then user_err = nil end
		if user_err then Logger.error(LOG, "User tap_hold.toml '%s' is %s — tap-holds remain neutral.", user_path, user_err) end
	end
	return M.load_document(defaults_path, user, user_err, user_path, shapes, M.read_config(config_path), config_path)
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
--- @param config table|nil Decoded config.toml: its `[tap_holds]` holds the
---   switch and the timings; nil reads them as their defaults.
--- @param config_path string|nil Where config.toml lives, named by warnings.
--- @return table Same shape as M.load(), plus `user_fields`: key id -> the
---   fields the user file sets.
function M.load_document(defaults_path, user, user_err, user_path, shapes, config, config_path)
	assert(shapes == nil or (type(shapes) == "table" and type(shapes.arrays) == "table"
		and shapes.document == user), "tap-hold shape receipt belongs to another document")
	local defaults = read_defaults(defaults_path)
	local base = type(defaults.tap_hold) == "table" and type(defaults.tap_hold.keys) == "table"
		and defaults.tap_hold.keys or {}
	local user_file = user_path or USER_FILE_NAME
	if type(user) == "table" then
		-- Migrated in place, like the boot does on disk: the caller owns a
		-- freshly decoded document and reads nothing from it afterwards.
		local outcome, detail = Migration.read_as_current(user, shapes, KeyCatalog.retired_delays_for_platform(defaults, "linux"))
		if outcome == "newer" then
			Logger.warn(LOG, "'%s' was saved by a newer build (schema v%s); it is read as it is and never written.",
				user_file, tostring(detail))
		elseif outcome == "invalid" then
			Outdated.report_in_file(user_file, { Migration.META_SECTION, Migration.VERSION_KEY },
				tostring(detail) .. "; the file is read as it is and never written")
		end
	end
	local function table_or_absent(value, path)
		if value == nil then return {} end
		if Shapes.is_table(value, shapes) then return value end
		Outdated.report_in_file(user_file, path, "it must be a table, not a scalar or array; repair the stored entry by hand")
		return {}
	end
	local section = table_or_absent(user and user.tap_hold, { "tap_hold" })
	local overrides = table_or_absent(section.keys, { "tap_hold", "keys" })
	-- A leaf config.toml owns, left in tap_hold.toml by a v22 move that could
	-- not delete it, is never read.
	for _, field in ipairs(CONFIG_OWNED_FIELDS) do
		if section[field] ~= nil then
			Outdated.report_in_file(user_file, { "tap_hold", field },
				"kept in config.toml [" .. ConfigKeys.KEY.TAP_HOLDS .. "] since config schema v22")
		end
	end
	local global = {}
	local inherit = section.inherit_defaults
	if inherit ~= nil and type(inherit) ~= "boolean" then
		Outdated.report_in_file(user_file, { "tap_hold", "inherit_defaults" }, "it must be true or false; the stored value is ignored")
	else
		global.inherit_defaults = inherit
	end
	local config_file = config_path or "config.toml"
	local settings = type(config) == "table" and config[ConfigKeys.KEY.TAP_HOLDS] or nil
	if settings ~= nil and type(settings) ~= "table" then
		Outdated.report_in_file(config_file, { ConfigKeys.KEY.TAP_HOLDS },
			"it must be a table; the tap-hold switch and timings take their defaults")
		settings = nil
	end
	settings = settings or {}
	if settings.enabled ~= nil and type(settings.enabled) ~= "boolean" then
		Outdated.report_in_file(config_file, { ConfigKeys.KEY.TAP_HOLDS, "enabled" },
			"it must be true or false; the stored value is ignored")
	else
		global.enabled = settings.enabled
	end
	-- The global delay: the user's when the file sets a usable one, else the
	-- registry's. A key with none of its own takes it.
	local global_seconds = M.GLOBAL_DEFAULT_SECONDS
	local global_user_set = false
	if section.time_activation_seconds ~= nil then
		local seconds = section.time_activation_seconds
		if type(seconds) == "number" and seconds > 0 and seconds <= MAX_THRESHOLD_SECONDS then
			global_seconds, global_user_set = seconds, true
		else
			Outdated.report_in_file(user_file, { "tap_hold", TIME_FIELD },
				string.format("%s is not a number of seconds in 0..%d; the global delay stays %.3f s",
					tostring(seconds), MAX_THRESHOLD_SECONDS, M.GLOBAL_DEFAULT_SECONDS))
		end
	end
	-- How long a modifier key pressed alone still taps: the user's when the file
	-- sets a valid one, else the manifest's default.
	local lone_tap_max_ms = M.LONE_TAP_DEFAULT_MS
	local stored_lone_tap = settings[LONE_TAP_FIELD]
	if stored_lone_tap ~= nil then
		if pcall(LoneTap.validate, stored_lone_tap) then
			lone_tap_max_ms = stored_lone_tap
		else
			Outdated.report_in_file(config_file, { ConfigKeys.KEY.TAP_HOLDS, LONE_TAP_FIELD },
				string.format("%s is not 0 or a whole number of milliseconds; the window stays %d ms",
					tostring(stored_lone_tap), M.LONE_TAP_DEFAULT_MS))
		end
	end
	local one_shot_timeout_ms = M.ONE_SHOT_TIMEOUT_DEFAULT_MS
	local stored_one_shot = settings[ONE_SHOT_TIMEOUT_FIELD]
	if stored_one_shot ~= nil then
		if M.valid_one_shot_timeout_ms(stored_one_shot) then
			one_shot_timeout_ms = stored_one_shot
		else
			Outdated.report_in_file(config_file, { ConfigKeys.KEY.TAP_HOLDS, ONE_SHOT_TIMEOUT_FIELD },
				string.format("%s is not a positive whole number of milliseconds; the one-shot timeout stays %d ms",
					tostring(stored_one_shot), M.ONE_SHOT_TIMEOUT_DEFAULT_MS))
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
	-- The shared file also holds the keys of the other drivers (_shared/tap_hold/SCHEMA.md):
	-- a catalogue key Linux lacks (Fn, the Mac Option and Command keys) is theirs.
	local catalogued = {}
	for _, entry in ipairs(defaults.tap_hold.catalog.keys) do catalogued[entry.id] = true end
	-- A Mac thumb key a Mac wrote under its own id is the PC key at its place,
	-- unless the file names that key too (shared_file.toml [thumb_positions]).
	local placed = {}
	for key_id, override in pairs(overrides) do
		local positional = type(key_id) == "string" and require("tap_hold.shared_file").positional_key(shared_file_spec(), key_id)
		if positional and positional ~= key_id and remappable[positional] and overrides[positional] == nil then
			placed[positional] = override
		end
	end
	-- A copy: the decoded document is the caller's.
	local entries = {}
	for key_id, override in pairs(overrides) do entries[key_id] = override end
	for key_id, override in pairs(placed) do entries[key_id] = override end
	for key_id, override in pairs(entries) do
		if catalogued[key_id] and not remappable[key_id] then
			-- Left as it is for the driver that has the key.
		elseif not remappable[key_id] then
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
				elseif field == "hold_action" then
					-- The shared file's macOS-only hold (_shared/tap_hold/SCHEMA.md).
					Outdated.report_in_file(user_file, { "tap_hold", "keys", key_id, field },
						"a macOS hold action; the key keeps its tap and holds nothing here")
				else
					Outdated.report_in_file(user_file, { "tap_hold", "keys", key_id, tostring(field) },
						"no tap-hold key has this field")
				end
			end
			-- An entry holding no field at all configures nothing.
			if keys[key_id] ~= nil or next(merged) ~= nil then keys[key_id] = merged end
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
		end, global_seconds)
	end

	return {
		enabled = global.enabled == true or (global.enabled == nil and Manifest.default_for(ConfigKeys.KEY.TAP_HOLDS_ENABLED)),
		keys = keys,
		global_seconds = global_seconds,
		global_user_set = global_user_set,
		lone_tap_max_ms = lone_tap_max_ms,
		one_shot_timeout_ms = one_shot_timeout_ms,
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
--- @param own_delay boolean Whether the user gave the key a delay of its own: the
---   recommendation ships none.
--- @return boolean
local function behaves_as(fields, recommended, own_delay)
	if own_delay or type(recommended) ~= "table" or (fields.enabled ~= false) ~= (recommended.enabled ~= false) then
		return false
	end
	for _, field in ipairs(BEHAVIOUR_FIELDS) do
		if fields[field] ~= recommended[field] then return false end
	end
	return true
end

--- The first-run wizard's view of a folder's tap_hold.toml: the Tap-Holds
--- switch in force (config.toml) and each key it configures, as the shipped
--- recommendation or as the user's own setting, compared through the same
--- validation the engine runs. A key the file leaves to the keyboard is
--- absent, so the wizard may import it; it never imports over another one.
--- @param defaults_path string The shared defaults.toml.
--- @param user_path string The folder's tap_hold.toml.
--- @param config_path string|nil The folder's config.toml; nil reads the switch as its default.
--- @return table|nil report `{ enabled = boolean, keys = { [id] = "recommended"|"customised" } }`
--- @return string|nil err Why the file could not be read.
function M.key_report(defaults_path, user_path, config_path)
	local user, user_err, shapes = read_toml(user_path, true)
	if user_err == "absent" then user, user_err = nil, nil end
	if user_err then return nil, "'" .. tostring(user_path) .. "' is " .. user_err end
	local config, config_err = M.read_config(config_path)
	if config_err then return nil, "'" .. tostring(config_path) .. "' is " .. config_err end
	local loaded = M.load_document(defaults_path, user, nil, user_path, shapes, config, config_path)
	local recommended = M.load_document(defaults_path,
		{ tap_hold = { keys = M.preset_keys(defaults_path) } }, nil).keys
	local keys = {}
	for key_id, fields in pairs(loaded.keys) do
		local own = loaded.user_fields[key_id]
		local own_delay = type(own) == "table" and own.time_activation_seconds == true
		keys[key_id] = behaves_as(fields, recommended[key_id], own_delay) and "recommended" or "customised"
	end
	return { enabled = loaded.enabled, keys = keys }
end

return M
