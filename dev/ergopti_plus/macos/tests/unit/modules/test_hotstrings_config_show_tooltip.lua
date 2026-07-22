--- tests/unit/modules/test_hotstrings_config_show_tooltip.lua

--- ==============================================================================
--- MODULE: hotstrings_config show_tooltip Round-Trip Tests
--- DESCRIPTION:
--- Regression tests for the "hotstrings-config-show-tooltip-pattern" audit
--- finding in modules/hotstrings_config.lua.
---
--- ROOT CAUSE ENCODED:
--- The TOML parser for hotstrings_config used a single pattern
---   line:match("^show_tooltip%s*=%s*(true|false)%s*$")
--- Lua patterns do not support alternation (|); the pattern matched only the
--- literal string "true|false", not "true" or "false" separately. show_tooltip
--- was therefore never parsed from disk — a false override written by
--- set_override() survived in memory but was always true after reload(), making
--- it impossible to persistently disable tooltip hints per category.
---
--- The fix uses two separate match() calls:
---   line:match("^show_tooltip%s*=%s*(true)%s*$") or
---   line:match("^show_tooltip%s*=%s*(false)%s*$")
---
--- This test pins the full round-trip: set false → serialize → parse → reload
--- → still false. It mirrors the existing priority round-trip test structure.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

--- Returns a unique writable temp path for each test case.
--- @param name string Short discriminator so concurrent tests never collide.
--- @return string
local function temp_path(name)
	local base = (os.getenv("TEMP") or os.getenv("TMPDIR") or "."):gsub("\\", "/")
	return base .. "/hcfg_stt_" .. name .. "_" .. tostring(os.time()) .. ".toml"
end

--- Reloads the module (resetting module-level state) and inits against a fresh
--- override file with a no-op TOML resolver (no package defaults).
--- @param path string Override file path.
--- @return table Freshly-initialised module.
local function fresh_module(path)
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
	mod.init({ override_path = path, toml_resolver = function() return nil end })
	return mod
end





-- ==============================================================
-- =============================================================
-- ======= 1/ show_tooltip false round-trip through disk =======
-- =============================================================
-- ==============================================================

helpers.describe("hotstrings_config: show_tooltip override round-trip", function()
	helpers.it("show_tooltip=false survives serialize → disk → reload", function()
		local path = temp_path("rt_false")
		os.remove(path)
		local mod = fresh_module(path)

		local ok = mod.set_override("rolls", nil, "show_tooltip", false)
		helpers.assert_eq(ok, true, "set_override must accept show_tooltip field")

		-- In-memory check.
		local ov = mod.get_user_override("rolls", nil)
		helpers.assert_true(ov ~= nil, "get_user_override must return a non-nil table after set")
		helpers.assert_eq(ov.show_tooltip, false,
			"show_tooltip must be false in memory immediately after set_override")

		-- Reload from disk: the TOML parser must read the boolean correctly.
		mod.reload()
		local ov2 = mod.get_user_override("rolls", nil)
		helpers.assert_true(ov2 ~= nil,
			"get_user_override must return a non-nil table after reload")
		helpers.assert_eq(ov2.show_tooltip, false,
			"show_tooltip=false must survive disk serialization and reload (hotstrings-config-show-tooltip-pattern)")

		os.remove(path)
	end)

	helpers.it("show_tooltip=true survives serialize → disk → reload", function()
		local path = temp_path("rt_true")
		os.remove(path)
		local mod = fresh_module(path)

		-- Explicitly set true (non-default, so it is written to the override file).
		mod.set_override("abbrevs", nil, "show_tooltip", true)
		mod.reload()
		local ov = mod.get_user_override("abbrevs", nil)
		helpers.assert_true(ov ~= nil, "get_user_override must return data after reload with show_tooltip=true")
		helpers.assert_eq(ov.show_tooltip, true,
			"show_tooltip=true must survive disk serialization and reload")

		os.remove(path)
	end)

	helpers.it("section-level show_tooltip=false survives reload", function()
		local path = temp_path("rt_sec")
		os.remove(path)
		local mod = fresh_module(path)

		mod.set_override("rolls", "ct", "show_tooltip", false)
		mod.reload()
		local ov = mod.get_user_override("rolls", "ct")
		helpers.assert_true(ov ~= nil, "section-level override must survive reload")
		helpers.assert_eq(ov.show_tooltip, false,
			"section-level show_tooltip=false must survive disk round-trip (hotstrings-config-show-tooltip-pattern)")

		os.remove(path)
	end)

	helpers.it("show_tooltip serializes as bare boolean, not a quoted string", function()
		local path = temp_path("rt_bare")
		os.remove(path)
		local mod = fresh_module(path)

		mod.set_override("rolls", nil, "show_tooltip", false)

		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "override file must exist after set_override")
		if not fh then return end
		local content = fh:read("*a")
		fh:close()

		-- Must appear as an unquoted boolean in the TOML output.
		helpers.assert_true(content:find("show_tooltip%s*=%s*false", 1, false) ~= nil,
			"show_tooltip must serialize as 'show_tooltip = false' (bare boolean, not quoted string)")
		helpers.assert_true(content:find('"false"') == nil,
			"show_tooltip must not be serialized as the quoted string \"false\"")

		os.remove(path)
	end)
end)
