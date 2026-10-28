--- tests/unit/infra/scope/test_scope_registry.lua

--- ==============================================================================
--- MODULE: Scope Owner Registry (Linux)
--- DESCRIPTION:
--- The tray's Quit asks one registry whether any configuration scope write or
--- rollback is still pending, as the macOS global writer fence does for every
--- category (quit-waits-for-writer). Each scope module registers a probe over the
--- owner it already keeps.
--- ==============================================================================

local helpers = require("tests.helpers")

local SCOPE_MODULES = {
	script_scope = "infra.script_scope", tap_hold_scope = "infra.tap_hold_scope",
	shortcuts_scope = "infra.shortcuts_scope", llm_scope = "infra.llm_scope", metrics_scope = "infra.metrics_scope",
	hotstrings_scope = "infra.hotstrings_scope", dynamic_hotstrings_scope = "infra.dynamic_hotstrings_scope",
	key_combinations_scope = "infra.key_combinations_scope", global_scope = "infra.global_scope",
	gesture_scope = "modules.gestures.manager",
}

helpers.describe("Linux scope owner registry (quit-waits-for-writer)", function()
	helpers.it("reports the scopes whose probe says pending, sorted, and nothing else", function()
		local Registry = require("infra.scope_registry")
		Registry._reset_for_test()
		local ok, err = pcall(function()
			helpers.assert_eq(Registry.pending(), false)
			local state = { b = false, a = false }
			Registry.register("b", function() return state.b end)
			Registry.register("a", function() return state.a end)
			helpers.assert_eq(Registry.pending(), false)
			state.b, state.a = true, true
			helpers.assert_eq(Registry.pending_names(), { "a", "b" })
			state.a = false
			helpers.assert_eq(Registry.pending_names(), { "b" })
			Registry.register("b", function() return false end)
			helpers.assert_eq(Registry.pending(), false, "a probe registered again replaces the first one")
		end)
		Registry._reset_for_test()
		for _, module in pairs(SCOPE_MODULES) do package.loaded[module] = nil; require(module) end
		if not ok then error(err, 0) end
	end)

	helpers.it("reads a raising probe as not pending so Quit stays reachable", function()
		local Registry = require("infra.scope_registry")
		Registry._reset_for_test()
		Registry.register("broken", function() error("boom") end)
		helpers.assert_eq(Registry.pending(), false)
		Registry._reset_for_test()
	end)

	helpers.it("rejects a probe without a name or a function", function()
		local Registry = require("infra.scope_registry")
		helpers.assert_eq(select(1, pcall(Registry.register, "", function() end)), false)
		helpers.assert_eq(select(1, pcall(Registry.register, "x", nil)), false)
	end)

	helpers.it("has every scope module register its probe under its scope name when it loads", function()
		local Registry = require("infra.scope_registry")
		for name, module in pairs(SCOPE_MODULES) do
			package.loaded[module] = nil
			Registry._reset_for_test()
			require(module)
			local found = false
			for _, registered in ipairs(Registry.names()) do found = found or registered == name end
			helpers.assert_true(found, module .. " must register '" .. name .. "'")
			helpers.assert_eq(Registry.pending(), false, name .. " has no owner yet, so nothing is pending")
		end
		Registry._reset_for_test()
		for _, module in pairs(SCOPE_MODULES) do package.loaded[module] = nil; require(module) end
	end)
end)

return true
