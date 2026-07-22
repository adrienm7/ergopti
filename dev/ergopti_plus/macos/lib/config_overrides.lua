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
-- =================================
-- ======= 1/ Value Coercion =======
-- =================================
-- =================================

--- Finds the end of a double-quoted TOML string, honouring `\"` escapes.
--- Lua patterns have no alternation, so a naive `'^"[^"]*"'` (or any pattern
--- built from character classes) cannot skip over an escaped quote — it always
--- stops at the FIRST literal `"`, even one preceded by a backslash. This walks
--- the string character by character, jumping two positions on `\` so an
--- escaped quote is never mistaken for the closing delimiter (F-MED-23: without
--- this, `"a \"quoted\" word"  -- comment` truncated to `"a \"` and silently
--- dropped both the rest of the value and the genuine trailing comment).
--- @param value string String starting with `"` (the opening quote).
--- @return string|nil The substring from the opening quote through its matching
---   closing quote (inclusive), or nil if no unescaped closing quote is found.
local function match_quoted_prefix(value)
	if value:sub(1, 1) ~= '"' then return nil end
	local len = #value
	local i = 2
	while i <= len do
		local c = value:sub(i, i)
		if c == "\\" then
			i = i + 2 -- skip the escaped character; it can never close the string
		elseif c == '"' then
			return value:sub(1, i)
		else
			i = i + 1
		end
	end
	return nil -- unterminated quoted value — caller falls back to the raw string
end


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
-- ==================================
-- ======= 2/ Override Loader =======
-- ==================================
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
		Logger.debug(LOG, "config.toml not found at '%s' — skipping overrides.", file_path)
		return 0
	end
	local content = fh:read("*a")
	fh:close()

	Logger.start(LOG, "Applying user overrides from '%s'…", file_path)
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
					-- Accept dots so that dotted keys like llm.enabled are not silently dropped
					key, value = trimmed:match("^([%w_.]+)%s*=%s*(.+)$")
				end
				if key and value then
					-- Strip inline TOML comments before coercion so  "DEBUG" # note  → "DEBUG"
					-- Quote-aware: quoted strings are extracted through their closing quote;
					-- unquoted values strip from the first # (old `[^"]*$` pattern stopped
					-- at a " inside the comment, leaving the remainder unsplit — lib-config-1).
					if value:sub(1, 1) == '"' then
						-- Escape-aware: skip over `\"` sequences instead of treating them as
						-- the closing quote (F-MED-23 — the old `'^"[^"]*"'` pattern truncated
						-- at the first literal ", silently dropping the rest of the value AND
						-- the genuine trailing comment).
						value = match_quoted_prefix(value) or value
					else
						value = value:gsub('%s*#.*$', "")
					end
					value = value:match("^%s*(.-)%s*$")
					local coerced = M.coerce(value)
					if section == "script" then
						-- The logger restore reads the canonical "ergopti.log_level" key, so map
						-- the expert [script] log_level / LogLevel (AHK parity) override onto it —
						-- a bare "log_level"/"LogLevel" settings key has no reader and would no-op.
						local setting_key = key
						local kl = key:lower()
						if kl == "log_level" or kl == "loglevel" then setting_key = "ergopti.log_level" end
						hs.settings.set(setting_key, coerced)
						applied = applied + 1
						Logger.debug(LOG, "Override [script].%s = %s.", key, tostring(coerced))
					elseif section == "features" then
						hs.settings.set(key, coerced)
						applied = applied + 1
						Logger.debug(LOG, "Override [features].%s = %s.", key, tostring(coerced))
					end
				end
			end
		end
	end

	Logger.success(LOG, "User overrides applied (%d value(s)).", applied)
	return applied
end

return M
