--- _shared/core/logger/engine/level_setting.lua

--- ==============================================================================
--- MODULE: Log Level Setting (Shared)
--- DESCRIPTION:
--- Resolves the stored `script.log_level` value to the logger threshold it
--- selects, from the manifest declaration alone, for the macOS and Linux drivers.
--- The Windows logger resolves the same names in `LoggerResolveLevel`, and the
--- `level_setting` cases of `_shared/tests/corpus/logger/parity_vectors.json`
--- hold the three to one answer.
---
--- FEATURES & RATIONALE:
--- 1. Manifest-owned policy. The accepted names and the default are the
---    declaration's `enum_values` and `default`. The macOS boot kept its own list
---    of four names and its own default: a stored TRACE, DONE, START or SUCCESS,
---    and an absent level, all booted at DEBUG, where Windows and Linux applied
---    the threshold of the name or the INFO default (logger parity audit LOG-01).
--- 2. Visible refusal. A value that is no declared name resolves to the default
---    and says so (`refused`), so the caller can log it; nothing is silently
---    replaced.
--- 3. One threshold table. A name maps to a core variant, and its threshold is
---    the core's `level_of`: TRACE and DONE share DEBUG's, START and SUCCESS
---    share INFO's.
--- ==============================================================================

local M = {}




-- =====================================
-- =====================================
-- ======= 1/ Name to Variant ==========
-- =====================================
-- =====================================

--- Every declared level name and the core variant whose threshold it selects.
local VARIANT_BY_LEVEL = {
	DEBUG   = "debug",
	TRACE   = "trace",
	DONE    = "done",
	INFO    = "info",
	START   = "start",
	SUCCESS = "success",
	WARNING = "warn",
	ERROR   = "error",
}




-- =====================================
-- =====================================
-- ======= 2/ Resolution ===============
-- =====================================
-- =====================================

--- Checks the manifest declaration before any value is resolved against it.
--- @param entry table The `script.log_level` declaration.
--- @return table entry The same declaration, validated.
local function checked(entry)
	if type(entry) ~= "table" or type(entry.default) ~= "string" or type(entry.enum_values) ~= "table" then
		error("level_setting: invalid script.log_level declaration", 3)
	end
	for _, name in ipairs(entry.enum_values) do
		if VARIANT_BY_LEVEL[name] == nil then
			error("level_setting: declared level '" .. tostring(name) .. "' has no logger variant", 3)
		end
	end
	return entry
end

--- Returns the declared name a value spells, case-insensitively, or nil.
--- @param value any Stored or requested value.
--- @param entry table The `script.log_level` declaration.
--- @return string|nil name Upper-case declared name.
function M.canonical(value, entry)
	checked(entry)
	if type(value) ~= "string" then return nil end
	local candidate = value:upper()
	for _, accepted in ipairs(entry.enum_values) do
		if candidate == accepted then return candidate end
	end
	return nil
end

--- Returns the threshold of one declared name.
--- @param name string Upper-case declared name.
--- @param core table The shared logger core (its `level_of`).
--- @return number threshold
function M.threshold(name, core)
	local variant = VARIANT_BY_LEVEL[name]
	local value = variant and core.level_of(variant) or nil
	if type(value) ~= "number" then
		error("level_setting: the logger has no threshold for '" .. tostring(name) .. "'", 2)
	end
	return value
end

--- Resolves a stored value: its own name when declared, else the default.
--- @param stored any The stored value; nil when none is stored.
--- @param entry table The `script.log_level` declaration.
--- @param core table The shared logger core.
--- @return table resolved { level = name, threshold = number, refused = boolean }
---   `refused` is true when a value was stored and is no declared name.
function M.resolve(stored, entry, core)
	local name = M.canonical(stored, entry)
	local refused = stored ~= nil and name == nil
	if name == nil then
		name = M.canonical(entry.default, entry)
		if name == nil then error("level_setting: the declared default is not one of its values", 2) end
	end
	return { level = name, threshold = M.threshold(name, core), refused = refused }
end

return M
