--- infra/config_overrides.lua

--- ==============================================================================
--- MODULE: User Config Overrides
--- DESCRIPTION:
--- Loads the [script] / [features] sections from the driver-specific
--- config.toml and applies their scalar values to hs.settings.
---
--- FEATURES & RATIONALE:
--- 1. Optional File: a missing config.toml is a valid no-op.
--- 2. Shared Schema: [script] owns driver settings and [features] owns dotted
---    feature keys, matching the AutoHotkey driver.
--- 3. Canonical Parser: the shared TOML codec owns strings, comments, and
---    continuations. This module only projects the two flat sections it owns,
---    so text inside a multiline value can never become executable settings.
--- 4. Fail Closed: incomplete reads, close failures, and invalid TOML publish
---    no partial override state.
--- ==============================================================================

local M = {}
local hs        = hs
local Logger    = require("infra.logger")
local TomlCodec = require("infra.toml.codec")
local LOG       = "config_overrides"





-- =================================
-- =================================
-- ======= 1/ Value Coercion =======
-- =================================
-- =================================

--- Converts a raw scalar literal for the cross-driver coercion corpus.
--- Runtime file parsing uses TomlCodec.decode(); this public function remains
--- the small parity surface shared with the AHK override loader.
--- @param raw string Raw scalar literal.
--- @return any coerced
function M.coerce(raw)
	local trimmed = raw:match("^%s*(.-)%s*$") or ""
	local lower = trimmed:lower()
	if lower == "true" then return true end
	if lower == "false" then return false end
	if trimmed:match("^-?%d+$") then return tonumber(trimmed) end
	if trimmed:match("^-?%d+%.%d+$") then return tonumber(trimmed) end
	local body = trimmed:match('^"(.*)"$')
	if body then
		body = body:gsub("\\\\", "\\"):gsub('\\"', '"')
			:gsub("\\n", "\n"):gsub("\\t", "\t")
		return body
	end
	return trimmed
end





-- ==================================
-- ==================================
-- ======= 2/ Override Loader =======
-- ==================================
-- ==================================

local function read_committed(path)
	local open_ok, file_or_err = pcall(io.open, path, "r")
	if not open_ok or not file_or_err then return nil, "absent" end
	local file = file_or_err
	local read_ok, content = pcall(file.read, file, "*a")
	local close_ok, closed, close_err = pcall(file.close, file)
	if not read_ok or type(content) ~= "string" or not close_ok or closed ~= true then
		return nil, tostring(read_ok and (close_err or closed) or content)
	end
	return content, nil
end

local function is_scalar(value)
	local value_type = type(value)
	return value_type == "string" or value_type == "number" or value_type == "boolean"
end

--- Reads file_path and applies scalar [script] / [features] values.
--- @param file_path string Absolute path to config.toml.
--- @return integer applied Number of settings committed.
function M.apply(file_path)
	if type(file_path) ~= "string" or file_path == "" then return 0 end
	local content, read_err = read_committed(file_path)
	if not content then
		if read_err == "absent" then
			Logger.debug(LOG, "config.toml not found at '%s' — skipping overrides.", file_path)
		else
			Logger.error(LOG, "config.toml read did not commit for '%s': %s.",
				file_path, tostring(read_err))
		end
		return 0
	end

	local decode_ok, decoded = pcall(TomlCodec.decode, content)
	if not decode_ok or type(decoded) ~= "table" then
		Logger.error(LOG, "config.toml is invalid; no overrides were applied from '%s'.", file_path)
		return 0
	end

	Logger.start(LOG, "Applying user overrides from '%s'…", file_path)
	local applied = 0
	local function apply_section(section_name, values)
		if type(values) ~= "table" then return end
		for key, value in pairs(values) do
			if type(key) ~= "string" or not is_scalar(value) then
				Logger.warn(LOG, "Ignoring non-scalar override in [%s].", section_name)
			else
				local setting_key = key
				if section_name == "script" then
					local lower_key = key:lower()
					if lower_key == "log_level" or lower_key == "loglevel" then
						setting_key = "ergopti.log_level"
					end
				end
				hs.settings.set(setting_key, value)
				applied = applied + 1
				Logger.debug(LOG, "Override [%s].%s = %s.",
					section_name, key, tostring(value))
			end
		end
	end

	apply_section("script", decoded.script)
	apply_section("features", decoded.features)
	Logger.success(LOG, "User overrides applied (%d value(s)).", applied)
	return applied
end

return M
