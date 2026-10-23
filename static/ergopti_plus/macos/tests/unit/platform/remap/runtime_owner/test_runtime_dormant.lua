--- tests/unit/platform/remap/runtime_owner/test_runtime_dormant.lua

--- ==============================================================================
--- MODULE: Owned Runtime Stays Dormant By Default
--- DESCRIPTION:
--- Proves that nothing about the owned Karabiner runtime (ADR 011) changes
--- today's behaviour unless `[karabiner] runtime = "owned"` is written by hand:
--- the command line tool stays the shared one, the selection is made once, and
--- the remap bridge's source reaches the owner only behind that opt-in.
---
--- ROOT CAUSE ENCODED: the bridge's init.lua cannot be loaded by the unit
--- suite, so a dormant guarantee that lived only in its control flow would be
--- unproven. The runtime-selected paths are behavioural; the opt-in gate is
--- pinned in source, the way the suite pins other boot paths.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local SHARED_CLI = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

--- Loads a fresh path module.
--- @return table KePaths
local function fresh_paths()
	package.loaded["platform.remap.ke_paths"] = nil
	return require("platform.remap.ke_paths")
end





-- =================================
-- =================================
-- ======= 1/ Selected Paths =======
-- =================================
-- =================================

helpers.describe("runtime-selected Karabiner paths", function()
	helpers.it("names the shared tool until a caller selects the owned runtime", function()
		local paths = fresh_paths()
		helpers.assert_eq(paths.CLI, SHARED_CLI)
		helpers.assert_eq(paths.selected_runtime(), "shared")
		helpers.assert_eq(paths.config_file_for("shared"), "~/.config/karabiner/karabiner.json")
		helpers.assert_eq(paths.cli_for("shared"), SHARED_CLI)
	end)

	helpers.it("keeps the shared tool after selecting shared, as the default boot does", function()
		local paths = fresh_paths()
		helpers.assert_true(paths.select_runtime("shared"))
		helpers.assert_true(paths.select_runtime("shared"))
		helpers.assert_eq(paths.CLI, SHARED_CLI)
	end)

	helpers.it("points every variable writer at the owned tool after an explicit selection", function()
		local paths = fresh_paths()
		helpers.assert_true(paths.select_runtime("owned"))
		helpers.assert_eq(paths.CLI, paths.OWNED.CLI)
		helpers.assert_eq(paths.CLI, "/Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli")
		helpers.assert_eq(paths.config_file_for("owned"),
			"~/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json")
		helpers.assert_eq(paths.cli_for("shared"), SHARED_CLI)
	end)

	helpers.it("refuses to switch runtime inside one Lua VM and refuses unknown names", function()
		local paths = fresh_paths()
		paths.select_runtime("owned")
		helpers.assert_throws(function() paths.select_runtime("shared") end)
		helpers.assert_eq(paths.CLI, paths.OWNED.CLI)
		local other = fresh_paths()
		helpers.assert_throws(function() other.select_runtime("both") end)
		helpers.assert_throws(function() other.cli_for(nil) end)
		helpers.assert_eq(other.CLI, SHARED_CLI)
	end)

	helpers.it("never places the owned runtime under the official application's directory", function()
		local owned = fresh_paths().OWNED
		for name, path in pairs(owned) do
			helpers.assert_true(not path:find("org.pqrs", 1, true), name .. " must not name the official application")
			helpers.assert_true(not path:find("/.config/karabiner", 1, true), name .. " must not touch ~/.config")
		end
	end)
end)





-- ==============================
-- ==============================
-- ======= 2/ Opt-In Gate =======
-- ==============================
-- ==============================

--- Reads the remap bridge source.
--- @return string source
local function init_source()
	return assert(SourceFile.read(helpers.driver_root() .. "platform/remap/init.lua"))
end

helpers.describe("the remap bridge reaches the owned runtime only after an opt-in", function()
	helpers.it("never requires the owner or its ports at load time", function()
		local source = init_source()
		for line in source:gmatch("[^\n]+") do
			if line:find("runtime_owner", 1, true) and line:find("require", 1, true) then
				helpers.assert_true(line:match("^%s") ~= nil, "a top-level require would load the owner at boot: " .. line)
			end
		end
		helpers.assert_true(source:find('require("platform.remap.runtime_owner")', 1, true) ~= nil)
	end)

	helpers.it("binds and starts the owner only inside the opt-in start function", function()
		local source = init_source()
		local _, inits = source:gsub("Owner%.init%(", "")
		helpers.assert_eq(inits, 1)
		local start = source:find("function M._owned.start()", 1, true)
		local bound = source:find("Owner.init(", 1, true)
		helpers.assert_true(start ~= nil and bound ~= nil and start < bound)
		local calls = {}
		for at in source:gmatch("()M%._owned%.start%(%)") do calls[#calls + 1] = at end
		helpers.assert_eq(#calls, 2, "the definition and one call")
		local gate = source:find("if M._owned.selected() and _state.enabled then\n\t\tif M._owned.start()", 1, true)
		helpers.assert_true(gate ~= nil, "the single call sits behind the opt-in and the integration switch")
	end)

	helpers.it("selects the shared runtime when the preference is absent", function()
		local source = init_source()
		helpers.assert_true(source:find("user_cfg.runtime or M._owned.paths.RUNTIME_SHARED", 1, true) ~= nil)
		package.loaded["platform.remap.ke_paths"] = nil
		helpers.assert_eq(require("platform.remap.config") ~= nil, true)
		helpers.assert_eq(require("platform.remap.config").RUNTIME_DEFAULT, "shared")
	end)

	helpers.it("generates nothing for an owned boot until the owner admitted the runtime", function()
		local source = init_source()
		local gate = source:find("owned-runtime-not-admitted", 1, true)
		local build = source:find("Generator.build_karabiner_json,", 1, true)
		helpers.assert_true(gate ~= nil and build ~= nil and gate < build)
	end)

	helpers.it("skips the official-application wizard for an owned boot", function()
		local source = init_source()
		helpers.assert_true(source:find("if _state.enabled and not M._owned.selected() and not _wizard_ran_this_session", 1, true) ~= nil)
	end)

	helpers.it("deploys an owned boot only through the owned writer", function()
		local source = init_source()
		local owned_deploy = source:find("Generator.deploy_owned_config(result, KARABINER_OUT)", 1, true)
		local shared_deploy = source:find("return Generator.merge_and_deploy_config(", 1, true)
		helpers.assert_true(owned_deploy ~= nil and shared_deploy ~= nil and owned_deploy < shared_deploy)
	end)
end)
