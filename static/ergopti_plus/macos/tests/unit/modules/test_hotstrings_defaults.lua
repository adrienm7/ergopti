--- tests/unit/modules/test_hotstrings_defaults.lua

--- ==============================================================================
--- MODULE: hotstrings_config Shared-Defaults Single-Source Tests
--- DESCRIPTION:
--- A4 — the hotstring resolution fallbacks (global default delay, global default
--- color, and the per-category "personal" baseline) are mutualised across the
--- AHK and Hammerspoon drivers: both read them from the shared cross-driver canon
--- _shared/modules/hotstrings/defaults.toml instead of a per-driver literal.
---
--- These tests pin two things:
---   1. The module loaded the values FROM the shared file — resolve()'s fallbacks
---      equal the values parsed straight out of defaults.toml (not a stale local).
---   2. The canonical values are exactly what both drivers expect. The AHK suite
---      asserts the SAME literals against the SAME file (test_hotstrings_config.ahk
---      §SharedDefaultsAreSingleSource), so a drift on either driver — or an
---      accidental edit to the shared file — turns one of these red.
--- ==============================================================================

local helpers = require("tests.helpers")

-- hotstrings_config logs through lib.logger; load it first under the stub.
package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local defaults_path = helpers.shared("modules/hotstrings/defaults.toml")

--- Build a unique writable temp path (the module itself creates the file).
local function temp_path(name)
	local base = (os.getenv("TEMP") or os.getenv("TMPDIR") or "."):gsub("\\", "/")
	return base .. "/hcfg_def_" .. name .. "_" .. tostring(os.time()) .. ".toml"
end

--- Reload the module so its require-time load_shared_defaults() re-runs against
--- the real shared file, then init it with an empty override + no-op TOML
--- resolver so resolve() exercises ONLY the hard fallbacks.
local function fresh_module(path)
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
	mod.init({ override_path = path, toml_resolver = function() return nil end })
	return mod
end

--- Parse the canonical shared file directly (same reader both drivers use).
local function read_defaults()
	local reader = require("lib.toml.reader")
	local parsed = reader.parse(defaults_path)
	return parsed and parsed.sections or nil
end




helpers.describe("hotstrings_config: shared defaults are the single source", function()
	helpers.it("resolve() fallbacks equal the values parsed from defaults.toml", function()
		local sections = read_defaults()
		helpers.assert_true(type(sections) == "table" and type(sections.colors) == "table"
			and type(sections.delays) == "table", "defaults.toml parses with [colors] and [delays]")

		local path = temp_path("src")
		os.remove(path)
		local mod = fresh_module(path)

		-- A category with no TOML metadata and no override → global fallbacks.
		local r = mod.resolve("rolls", nil)
		helpers.assert_eq(r.color, sections.colors.global_default,
			"global default color is loaded from [colors] global_default")
		helpers.assert_eq(r.delay, tonumber(sections.delays.default_sec),
			"global default delay is loaded from [delays] default_sec")

		-- The "personal" category has its own baseline color from the same file.
		local rp = mod.resolve("personal", nil)
		helpers.assert_eq(rp.color, sections.colors.personal,
			"personal baseline is loaded from [colors] personal")

		os.remove(path)
	end)

	helpers.it("pins the canonical cross-driver values", function()
		local path = temp_path("canon")
		os.remove(path)
		local mod = fresh_module(path)

		helpers.assert_eq(mod.resolve("rolls", nil).color, "#1e88e5",
			"canonical global default color")
		helpers.assert_eq(mod.resolve("rolls", nil).delay, 0.75,
			"canonical global default delay (seconds)")
		helpers.assert_eq(mod.resolve("personal", nil).color, "#6e6e73",
			"canonical personal baseline color")

		os.remove(path)
	end)

	-- Cross-driver SSoT for the dynamic-hotstrings default delay. The AHK driver
	-- now LOADS DYN_HOTSTRINGS_DEFAULT_DELAY from [delays] dynamichotstrings_sec
	-- (test_hotstrings_config.ahk §SharedDefaultsAreSingleSource); macOS keeps the
	-- value in the keymap DELAYS_DEFAULT table (a static table built at module
	-- load), so this pins that literal to the same shared key — a change to the
	-- TOML that is not mirrored here turns this red.
	helpers.it("keymap DELAYS_DEFAULT.dynamichotstrings equals the shared [delays] dynamichotstrings_sec", function()
		local sections = read_defaults()
		helpers.assert_true(sections.delays.dynamichotstrings_sec ~= nil,
			"defaults.toml [delays] must declare dynamichotstrings_sec")
		local keymap = helpers.load_with_stubs("modules.keymap")
		helpers.assert_eq(keymap.DELAYS_DEFAULT.dynamichotstrings, tonumber(sections.delays.dynamichotstrings_sec),
			"macOS keymap DELAYS_DEFAULT.dynamichotstrings must equal the shared TOML dynamichotstrings_sec (cross-driver SSoT)")
		helpers.assert_eq(2.0, keymap.DELAYS_DEFAULT.dynamichotstrings,
			"canonical dynamic-hotstrings default delay (seconds)")
	end)
end)
