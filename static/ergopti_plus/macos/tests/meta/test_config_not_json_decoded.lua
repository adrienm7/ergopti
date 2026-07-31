--- tests/meta/test_config_not_json_decoded.lua

--- ==============================================================================
--- MODULE: Config-File Format Guard
--- DESCRIPTION:
--- Ensures the v2 TOML config file is never parsed with a JSON decoder.
---
--- WHY THIS EXISTS (regression for json-decode-toml-config):
--- init.lua's legacy "Config Priming" block called `hs.json.decode` on the path
--- returned by menu_paths.get("ConfigTomlPath") — i.e. on config.toml. The config
--- migrated from JSON to TOML in v2, so this decoded TOML as JSON and FAILED on
--- every single boot, emitting a native `LuaSkin: Error deserialising JSON` line
--- to the console (captured as a [CONSOLE] ERROR). Because the call was wrapped in
--- pcall, the Lua-level failure was swallowed and the block was simply dead — the
--- trigger char / section states it meant to restore are now restored from
--- config.toml by menu_state. Tests never caught it because the native LuaSkin
--- error is not a Lua error a unit test would see, and init.lua is not executed by
--- the suite.
---
--- INVARIANTS PINNED HERE:
---   1. ConfigTomlPath resolves to a .toml file (so decoding it as JSON is wrong).
---   2. init.lua never reads config.toml into a buffer to JSON-decode it. The legit
---      consumers (config_overrides.apply, Preferences.load, onboarding) take the
---      path inline and parse it as TOML; the bug bound it to a local and io.open +
---      hs.json.decode'd it. We flag exactly that shape.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()  -- trailing slash

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "r")
	helpers.assert_true(fh ~= nil, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end





--- ================================================
--- ================================================
--- ======= 1/ Config file is TOML, not JSON =======
--- ================================================
--- ================================================

helpers.describe("boot config: the TOML config is never JSON-decoded (json-decode-toml-config)", function()
	helpers.it("ConfigTomlPath resolves to a .toml file", function()
		local menu_paths = helpers.load_with_stubs("ui.menu.menu_paths")
		local path = menu_paths.get("ConfigTomlPath")
		helpers.assert_true(type(path) == "string" and path:match("%.toml$") ~= nil,
			"ConfigTomlPath must point at a .toml file, got: " .. tostring(path))
	end)

	helpers.it("init.lua does not read config.toml into a buffer to JSON-decode it", function()
		-- The legacy priming bound `local config_file = menu_paths.get("ConfigTomlPath")`
		-- then io.open'd + hs.json.decode'd it. Legit consumers take the path inline
		-- and parse it as TOML, so they never io.open a config.toml-bound local here.
		-- Flag any config.toml-bound local that IS io.open'd — the JSON-priming shape.
		local src = read_source("init.lua")
		-- The anchor, before the scan: this check PASSES on an empty result, so a
		-- rename of ConfigTomlPath would retire it silently rather than fail it.
		helpers.assert_true(src:find("ConfigTomlPath", 1, true) ~= nil,
			"init.lua no longer mentions ConfigTomlPath — the scan below would find no "
			.. "offenders because it is looking for something that is gone, not because "
			.. "the shape was fixed")
		local offenders = {}
		for var in src:gmatch('local%s+([%w_]+)%s*=%s*menu_paths%.get%("ConfigTomlPath"%)') do
			if src:find("io%.open%(%s*" .. var) then
				offenders[#offenders + 1] = var
			end
		end
		helpers.assert_true(#offenders == 0,
			"init.lua reads config.toml into a buffer (" .. table.concat(offenders, ", ")
				.. ") — parse it as TOML, never hs.json.decode (json-decode-toml-config)")
	end)
end)
