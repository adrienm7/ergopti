--- _shared/lua/timings.lua

--- ==============================================================================
--- MODULE: Shared Timings Reader (Shared)
--- DESCRIPTION:
--- Reads `_shared/modules/timings/constants.toml`, the single authoritative
--- source of every tunable timing in the project (debounces, timeouts, poll
--- intervals, ...), for the macOS and Linux drivers. Each driver binds this
--- factory in infra/timings.lua with its logger, its shared-path resolver and
--- its TOML parser; the lookup rules live here once.
---
--- FEATURES & RATIONALE:
--- 1. Fail fast: a missing file, section, or key raises an error rather than
---    returning nil: the registry is committed and exhaustive, so a miss is a
---    real misconfiguration, not a tunable default.
--- 2. The path comes from the driver's shared-path resolver, never from the
---    location of this file, because an installed package does not keep the
---    checkout layout.
--- 3. Emptiness, not type, is the failure signal: the TOML parsers answer a
---    well-formed result with an empty `sections` for an unreadable file, so a
---    type test alone would let boot die later on a misleading missing section.
--- 4. Unit helpers: `ms` returns the value verbatim, `sec` divides by 1000 for
---    the OS timer APIs that take seconds, and `count` reads an entry that is
---    not a duration (days of retention, ring-buffer entries) without lying
---    about its unit at the call site.
--- ==============================================================================

local TableUtil = require("table_util")

local M = {}

-- The registry stores every duration in milliseconds.
local MILLISECONDS_PER_SECOND = 1000

-- The registry file under the shared tree.
M.REGISTRY_REL_PATH = "modules/timings/constants.toml"




-- =============================================
-- =============================================
-- ======= 1/ Public API =======================
-- =============================================
-- =============================================

--- Loads the registry and returns the accessors bound to it.
--- @param ports table {
---   logger = central logger, log = string namespace,
---   loaded_level = "done"|"info": the logger method that reports the load,
---   shared_path = function(rel) -> string|nil: absolute path under _shared/,
---   parse = function(path) -> table: the TOML parser, answering { sections } }
--- @return table timings { ms, sec, count }
function M.new(ports)
	assert(type(ports) == "table" and type(ports.logger) == "table" and type(ports.log) == "string"
		and type(ports.shared_path) == "function" and type(ports.parse) == "function"
		and (ports.loaded_level == "done" or ports.loaded_level == "info"),
		"a timings reader needs a logger, a log namespace, a loaded_level, a shared_path and a parse port")
	local path = ports.shared_path(M.REGISTRY_REL_PATH)
	-- Guard the path first: the parsers short-circuit a nil path to an empty
	-- result, so the failure has to be caught while it can still name the cause.
	if type(path) ~= "string" or path == "" then
		error("[timings] the _shared/ tree is unreachable — cannot locate " .. M.REGISTRY_REL_PATH)
	end
	local parsed = ports.parse(path)
	local sections = type(parsed) == "table" and parsed.sections or nil
	if type(sections) ~= "table" or next(sections) == nil then
		error("[timings] constants.toml is missing or empty: " .. path)
	end
	ports.logger[ports.loaded_level](ports.log, "Shared timings registry loaded (%d section(s)).", TableUtil.count(sections))

	local timings = {}

	--- The raw value of a `[section] key` pair, in the registry's unit.
	--- @param section string The TOML section name.
	--- @param key string The key within that section.
	--- @return number
	function timings.ms(section, key)
		local entries = sections[section]
		if type(entries) ~= "table" then
			error(string.format("[timings] missing section [%s] in constants.toml", tostring(section)))
		end
		local value = entries[key]
		if type(value) ~= "number" then
			error(string.format("[timings] missing or non-numeric key [%s].%s in constants.toml",
				tostring(section), tostring(key)))
		end
		return value
	end

	--- The same lookup converted to seconds.
	--- @param section string
	--- @param key string
	--- @return number
	function timings.sec(section, key)
		return timings.ms(section, key) / MILLISECONDS_PER_SECOND
	end

	--- The same lookup for an entry that is not a duration.
	--- @param section string
	--- @param key string
	--- @return number
	function timings.count(section, key)
		return timings.ms(section, key)
	end

	return timings
end

return M
