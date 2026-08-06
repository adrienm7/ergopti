--- infra/timings.lua

--- ==============================================================================
--- MODULE: Shared Timings Reader (Linux)
--- DESCRIPTION:
--- Fail-fast reader over the cross-driver timing registry at
--- `_shared/modules/timings/constants.toml`. Mirrors `macos/infra/timings.lua`:
--- parses the shared TOML via `toml_codec.reader` and exposes every timing as
--- `Timings.ms(section, key)`. The macOS driver uses `lib.toml.reader`;
--- Linux uses the shared `toml_codec.reader` (already required by the hotstring
--- loader). Both parsers produce the same `sections` shape.
---
--- FEATURES & RATIONALE:
--- 1. cwd-independent: resolves the TOML path relative to this file's location
---    so it works under the daemon, test runner, and any working directory.
--- 2. Fail fast: a missing file, section, or key raises an error — the registry
---    is committed and exhaustive, so a miss is a real misconfiguration.
--- 3. Unit helpers: `M.ms` returns milliseconds verbatim; `M.sec` divides by
---    1000 for OS timer APIs that take seconds.
---
--- USAGE:
---   local Timings = require("infra.timings")
---   local SESSION_TIMEOUT_MS = Timings.ms("keylogger", "session_timeout_ms")
--- ==============================================================================

local M = {}
local Logger = require("logger.shim")
local LOG    = "timings"

-- Load the shared TOML reader (pcall-guarded so a missing module produces a
-- clean error message rather than a raw Lua stack trace).
local ok_reader, Reader = pcall(require, "toml_codec.reader")
if not ok_reader then
	error("[timings] toml_codec.reader not available — is _shared/lua/ in package.path?")
end

local MS_PER_SEC = 1000


-- ==================================
-- ==================================
-- ======= 1/ Registry load =========
-- ==================================
-- ==================================

--- Resolves the absolute path to _shared/modules/timings/constants.toml by
--- walking up from this file's own location (linux/infra/ → repo root → _shared/).
--- @return string Absolute path to the TOML file.
local function resolve_toml_path()
	local src = debug and debug.getinfo and debug.getinfo(1, "S")
	if src and src.source then
		local s = src.source
		-- Strip leading '@' (LuaJIT) or '=' (Lua 5.4 chunk marker)
		if s:sub(1, 1) == "@" or s:sub(1, 1) == "=" then s = s:sub(2) end
		s = s:gsub("\\", "/")
		-- s is .../ergopti_plus/linux/infra/timings.lua — walk up 3 levels to .../ergopti_plus/
		local root = s:match("^(.*)/[^/]+/[^/]+/[^/]+$")  -- strips /linux/infra/timings.lua
		if root then
			return root .. "/_shared/modules/timings/constants.toml"
		end
	end
	return nil
end

--- Reads and parses the shared timings TOML. Fail-fast: a missing file or
--- malformed parse raises an error so a timing gap never goes undetected.
--- @return table The parsed `sections` table ([section][key] = number).
local function load_registry()
	local toml_path = resolve_toml_path()
	if not toml_path then
		error("[timings] cannot resolve _shared/modules/timings/constants.toml path")
	end

	local parsed   = Reader.parse(toml_path)
	local sections = (type(parsed) == "table") and parsed.sections or nil
	if type(sections) ~= "table" then
		error("[timings] _shared/modules/timings/constants.toml not readable: " .. toml_path)
	end
	return sections
end

local _sections = load_registry()

local _section_count = 0
for _ in pairs(_sections) do _section_count = _section_count + 1 end
Logger.info(LOG, "Shared timings registry loaded (%d section(s)).", _section_count)


-- =====================================
-- =====================================
-- ======= 2/ Public accessors =========
-- =====================================
-- =====================================

--- Returns the raw millisecond value for a `[section] key` pair. FAIL-FAST when
--- the section or key is absent — every consumed timing must exist in the registry.
--- @param section string The TOML section name (e.g. "keylogger").
--- @param key string The key within that section (e.g. "session_timeout_ms").
--- @return number The value in milliseconds.
function M.ms(section, key)
	local s = _sections[section]
	if type(s) ~= "table" then
		error(string.format("[timings] missing section [%s] in constants.toml", tostring(section)))
	end
	local v = s[key]
	if type(v) ~= "number" then
		error(string.format("[timings] missing or non-numeric key [%s].%s in constants.toml",
			tostring(section), tostring(key)))
	end
	return v
end

--- Same lookup as `M.ms` for a registry entry that is NOT a duration.
---
--- A few keys in the shared registry are plain counts — days of log retention,
--- ring-buffer entries. Reading them through `M.ms` works and reads as a lie at
--- the call site, which is how a number in days ends up divided by a thousand
--- by someone who trusted the accessor's name.
--- @param section string The TOML section name.
--- @param key string The key within that section.
--- @return number The raw value.
function M.count(section, key)
	return M.ms(section, key)
end

--- Same lookup as `M.ms` but converted to seconds.
--- @param section string The TOML section name.
--- @param key string The key within that section.
--- @return number The value in seconds.
function M.sec(section, key)
	return M.ms(section, key) / MS_PER_SEC
end

return M
