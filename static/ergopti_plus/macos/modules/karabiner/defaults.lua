--- modules/karabiner/defaults.lua

--- ==============================================================================
--- MODULE: Karabiner Defaults
--- DESCRIPTION:
--- Single source of truth for all user-configurable karabiner defaults, loaded
--- from the cross-driver shared file _shared/tap_hold/defaults.toml (sections
--- [hs_timeouts], [hs_tap_hold], [hs_combos]) at require-time.
---
--- The values previously lived inline in this file as a Lua table; they now live
--- in the shared TOML so both drivers seed their tap-hold config from one source.
--- The macOS-specific paradigm (Karabiner key codes, the N*N modifier-combo
--- matrix, a single global tap/hold timeout) has no AutoHotkey analog, so it
--- occupies its own [hs_*] sections; the AHK loader ignores them and reads the
--- [tap_hold.*] sections of the same file. Action IDs reference
--- modules/karabiner/data/actions.json. Edit the TOML to change what
--- "Reset to defaults" restores.
---
--- FAIL FAST: a missing file or missing [hs_*] section is an error at load time —
--- there is no driver-side fallback table (would mask a broken install).
--- ==============================================================================

local TomlReader = require("infra.toml.reader")

local D = {}

-- toml_reader tags every parsed section with these bookkeeping fields; they are
-- not data entries and must be skipped when iterating a section's keys.
local READER_ARTIFACT_KEYS = { description = true, entries = true }





-- =====================================
-- =====================================
-- ======= 1/ Shared-file loader =======
-- =====================================
-- =====================================

--- Resolves _shared/tap_hold/defaults.toml.
---
--- Asks infra.paths first — the resolver that exists precisely so the shared
--- root lives in one place and survives the symlinked and packaged layouts,
--- and which the SIBLING file config.lua already uses. The hand-rolled walk
--- below stays only as a last resort.
---
--- The order matters more than it looks. A wrong path here does not fail
--- politely: TomlReader.parse() returns an EMPTY result for a file it cannot
--- open, so the `type(parsed.sections) == "table"` guard passes and the failure
--- surfaces later as require_section() raising at MODULE LOAD time. This module
--- is required from config.lua, which is required from karabiner/init.lua, so
--- until init.lua learned to pcall that chain a defaults.toml the walk could not
--- reach cost the entire boot rather than one feature.
---
--- Requiring the resolver LAZILY, inside the function: this file's body runs at
--- require time, and a top-level require of infra.paths would put a second
--- module on the same un-pcall'd load path this comment is about.
--- @return string Absolute path to the shared tap-hold defaults TOML.
local function shared_defaults_path()
	local ok_paths, Paths = pcall(require, "infra.paths")
	if ok_paths and type(Paths) == "table" and type(Paths.shared) == "function" then
		local resolved = Paths.shared("tap_hold/defaults.toml")
		if type(resolved) == "string" and resolved ~= "" then return resolved end
	end

	-- Fallback: walk up from this file.
	-- macos/modules/karabiner/defaults.lua → … → ergopti_plus → /_shared.
	local src = debug.getinfo(1, "S").source:gsub("^@", "")
	local dir = src:match("^(.*)[/\\][^/\\]+$") or src   -- → macos/modules/karabiner
	dir = dir:match("^(.*)[/\\][^/\\]+$") or dir          -- → macos/modules
	dir = dir:match("^(.*)[/\\][^/\\]+$") or dir          -- → macos
	local ergopti_plus = dir:match("^(.*)[/\\][^/\\]+$") or dir  -- → ergopti_plus
	return ergopti_plus .. "/_shared/tap_hold/defaults.toml"
end

--- Returns the parsed sections table, erroring if the file is unreadable.
--- @return table sections keyed by section name.
local function load_sections()
	local path = shared_defaults_path()
	local parsed = TomlReader.parse(path)
	if type(parsed) ~= "table" or type(parsed.sections) ~= "table" then
		error("[karabiner/defaults] _shared/tap_hold/defaults.toml not readable: " .. tostring(path))
	end
	return parsed.sections
end

--- Fetches a required section, erroring when absent (fail fast).
--- @param sections table The parsed sections table.
--- @param name string Section name (e.g. "hs_tap_hold").
--- @return table The section table.
local function require_section(sections, name)
	local s = sections[name]
	if type(s) ~= "table" then
		error(string.format("[karabiner/defaults] missing section [%s] in defaults.toml", name))
	end
	return s
end





-- =========================================
-- =========================================
-- ======= 2/ Build the defaults set =======
-- =========================================
-- =========================================

local sections = load_sections()

-- ----- Timeouts + flags ([hs_timeouts]) -----
local timeouts = require_section(sections, "hs_timeouts")
D.tap_hold_timeout_ms        = timeouts.tap_hold_timeout_ms        -- KE basic.to_if_alone_timeout_milliseconds
D.sticky_timeout_ms          = timeouts.sticky_timeout_ms          -- One-shot modifier auto-cancel delay
D.simultaneous_threshold_ms  = timeouts.simultaneous_threshold_ms  -- Combo activation window
D.combo_symmetric            = timeouts.combo_symmetric            -- A+B == B+A for the chord slot

-- ----- Tap / hold per key ([hs_tap_hold]) -----
-- key_id = { tap_action_id, hold_action_id } (positional, as consumers expect).
D.tap_hold = {}
for key, slots in pairs(require_section(sections, "hs_tap_hold")) do
	if not READER_ARTIFACT_KEYS[key] and type(slots) == "table" then
		D.tap_hold[key] = { slots.tap, slots.hold }
	end
end

-- ----- Modifier combos ([hs_combos]) -----
-- combo_id = { combo_action_id, tap_action_id, hold_action_id } (positional).
--   combo : press k1 then k2 within simultaneous_threshold_ms → chord-style fire.
--   tap   : hold k1 + briefly tap k2              → fires once on short release.
--   hold  : hold k1 + hold k2 past tap_hold delay → fires after long press.
D.combos = {}
for id, slots in pairs(require_section(sections, "hs_combos")) do
	if not READER_ARTIFACT_KEYS[id] and type(slots) == "table" then
		D.combos[id] = { slots.combo, slots.tap, slots.hold }
	end
end

return D
