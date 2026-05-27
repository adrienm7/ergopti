--- lib/config_overrides.lua

--- ==============================================================================
--- MODULE: User Config Overrides
--- DESCRIPTION:
--- Loads the [script] / [features] sections from the driver-specific
--- config.toml (hammerspoon/config.toml) and applies them as overrides
--- to hs.settings. Mirror of the AHK driver's ApplyConfigTomlOverrides()
--- so both drivers share the same config format.
---
--- FEATURES & RATIONALE:
--- 1. Optional File: A missing config.toml is fine — overrides are opt-in.
--- 2. Schema: [script] holds simple key=value pairs forwarded to hs.settings.
---            [features] holds dotted-path keys, each setting a single value
---            in hs.settings keyed by the path. Callers read hs.settings to
---            consume the override at runtime.
--- 3. Single File: Overrides live in the driver-specific config file
---    (hammerspoon/config.toml) alongside GUI-managed preferences.
--- 4. Lightweight Parser: Only flat key=value lines are supported, no arrays /
---    nested tables. Anything more complex belongs in dedicated TOML files.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")
local LOG    = "config_overrides"




-- =================================
--- =================================
-- ======= 1/ Value Coercion =======
--- =================================
-- =================================

--- Converts a raw TOML literal into the appropriate Lua type.
--- - "true" / "false" → boolean
--- - integer / float  → number
--- - "..." string     → unquoted string (basic \", \\, \n escapes)
--- - anything else    → raw trimmed string
--- @param raw string The raw value as it appears after the ``=``.
--- @return any
function M.coerce(raw)
	local trimmed = raw:match("^%s*(.-)%s*$") or ""
	local lower = trimmed:lower()
	if lower == "true"  then return true  end
	if lower == "false" then return false end
	if trimmed:match("^-?%d+$") then return tonumber(trimmed) end
	if trimmed:match("^-?%d+%.%d+$") then return tonumber(trimmed) end
	-- Quoted string: strip the surrounding quotes and unescape common sequences.
	local body = trimmed:match("^\"(.*)\"$")
	if body then
		body = body:gsub("\\\\", "\\"):gsub("\\\"", "\""):gsub("\\n", "\n"):gsub("\\t", "\t")
		return body
	end
	return trimmed
end




-- ===================================
-- ===================================
-- ======= 2/ Override Loader =======
-- ===================================
-- ===================================

--- Reads file_path and applies its [script] / [features] sections to
--- hs.settings. Returns the number of overrides applied. A missing or
--- unreadable file is treated as a no-op (returns 0).
---
--- The [script] section maps `key = value` to hs.settings under the bare key.
--- The [features] section uses dotted-path keys (matching the Lua module's
--- registry layout) and writes them as-is — consumers read them via
--- hs.settings.get(path).
--- @param file_path string Absolute path to config.toml.
--- @return integer The number of overrides applied.
function M.apply(file_path)
	if type(file_path) ~= "string" or file_path == "" then return 0 end
	local fh = io.open(file_path, "r")
	if not fh then
		Logger.debug(LOG, "config.toml not found at '{1}' — skipping overrides.", file_path)
		return 0
	end
	local content = fh:read("*a")
	fh:close()

	Logger.start(LOG, "Applying user overrides from '{1}'…", file_path)
	local applied = 0
	local section = nil

	for line in content:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$") or ""
		if trimmed == "" or trimmed:sub(1, 1) == "#" then
			-- skip
		else
			local hdr = trimmed:match("^%[([^%[%]]+)%]$")
			if hdr then
				section = hdr:lower():match("^%s*(.-)%s*$")
			else
				-- key = value — accept both bare and "quoted" keys
				local key, value = trimmed:match("^\"([^\"\\]+)\"%s*=%s*(.+)$")
				if not key then
					key, value = trimmed:match("^([%w_]+)%s*=%s*(.+)$")
				end
				if key and value then
					local coerced = M.coerce(value)
					if section == "script" then
						hs.settings.set(key, coerced)
						applied = applied + 1
						Logger.debug(LOG, "Override [script].{1} = {2}.", key, tostring(coerced))
					elseif section == "features" then
						hs.settings.set(key, coerced)
						applied = applied + 1
						Logger.debug(LOG, "Override [features].{1} = {2}.", key, tostring(coerced))
					end
				end
			end
		end
	end

	Logger.success(LOG, "User overrides applied ({1} value(s)).", applied)
	return applied
end

return M
