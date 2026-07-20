--- lib/timings.lua

--- ==============================================================================
--- MODULE: Shared Timings Reader (Hammerspoon)
--- DESCRIPTION:
--- Fail-fast reader over the cross-driver timing registry at
--- `_shared/modules/timings/constants.toml`. That TOML file is the single authoritative
--- source for every tunable timing in the project (debounces, timeouts, poll
--- intervals, …) and even names the AHK + HS constant that each value used to
--- duplicate. This module exposes those values to the macOS driver so the
--- per-module literals can be deleted and the two drivers stay in sync.
---
--- FEATURES & RATIONALE:
--- 1. cwd-independent load: the TOML is located relative to THIS file via
---    `debug.getinfo`, so it resolves identically under Hammerspoon and the
---    headless test runner regardless of the working directory (mirrors
---    `ui/tooltip/config.lua` and `lib/manifest_reader.lua`).
--- 2. Fail fast: a missing file, section, or key raises an error rather than
---    silently returning nil — the registry is committed and exhaustive, so a
---    miss is a real misconfiguration, not a tunable default.
--- 3. Unit helpers: every value in the registry is an integer number of
---    milliseconds; `M.ms` returns it verbatim and `M.sec` divides by 1000 for
---    the OS timer APIs that take a seconds argument.
---
--- USAGE:
---   local Timings = require("lib.timings")
---   local DEBOUNCE_MAX_SEC = Timings.sec("llm", "prediction_debounce_max_ms")
---   local SYNTH_MATCH_DELAY_MS = Timings.ms("keylogger", "synth_match_delay_ms")
--- ==============================================================================

local M = {}
local Logger = require("lib.logger")
local Paths = require("lib.paths")
local TomlReader = require("lib.toml.reader")
local LOG = "timings"

-- Number of milliseconds in one second — the registry stores every value in ms.
local MS_PER_SEC = 1000




-- ==================================
-- ==================================
-- ======= 1/ Registry load =========
-- ==================================
-- ==================================

--- Reads _shared/modules/timings/constants.toml relative to this file. Missing file or a
--- malformed parse raises an error (fail fast — no driver-side fallbacks).
--- @return table The parsed `sections` table ([section][key] = number).
local function load_registry()
	-- Guard the PATH first: Paths.shared() returns nil when the _shared/ tree is
	-- unreachable, and TomlReader.parse(nil) short-circuits to an empty result. The
	-- path would then be nil inside the message below, so the failure has to be
	-- caught here — while it can still name the actual cause.
	local toml_path = Paths.shared("modules/timings/constants.toml")
	if type(toml_path) ~= "string" or toml_path == "" then
		error("[timings] the _shared/ tree is unreachable — cannot locate modules/timings/constants.toml")
	end

	local parsed   = TomlReader.parse(toml_path)
	local sections = (type(parsed) == "table") and parsed.sections or nil
	-- Emptiness, not type, is the real signal: both of TomlReader.parse's failure
	-- exits return a well-formed result whose `sections` is an empty table, so the
	-- previous `type(sections) ~= "table"` test could never fire. A missing or
	-- unreadable file silently produced an empty registry and boot died much later
	-- with a misleading "missing section [ui]".
	if type(sections) ~= "table" or next(sections) == nil then
		error("[timings] constants.toml is missing or empty: " .. toml_path)
	end
	return sections
end

local _sections = load_registry()

local _section_count = 0
for _ in pairs(_sections) do _section_count = _section_count + 1 end
Logger.done(LOG, "Shared timings registry loaded (%d section(s)).", _section_count)




-- =====================================
-- =====================================
-- ======= 2/ Public accessors =========
-- =====================================
-- =====================================

--- Returns the raw millisecond value for a `[section] key` pair. FAIL-FAST when
--- the section or key is absent — every consumed timing must exist in the
--- registry, so a miss is a misconfiguration to surface loudly.
--- @param section string The TOML section name (e.g. "keylogger").
--- @param key string The key within that section (e.g. "synth_match_delay_ms").
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

--- Same lookup as `M.ms` but converted to seconds, for the OS timer APIs that
--- take a seconds argument.
--- @param section string The TOML section name.
--- @param key string The key within that section.
--- @return number The value in seconds.
function M.sec(section, key)
	return M.ms(section, key) / MS_PER_SEC
end

return M
