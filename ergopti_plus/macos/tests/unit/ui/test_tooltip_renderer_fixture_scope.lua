--- tests/unit/ui/test_tooltip_renderer_fixture_scope.lua

--- ==============================================================================
--- MODULE: Tooltip Renderer Fixture Isolation Tests
--- DESCRIPTION:
--- Actual renderer scenarios must restore the logger, native state and module cache.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Collects the actual renderer callbacks without retaining their registration module.
--- @return table scenarios Ordered names and callbacks.
local function collect_scenarios()
	local name = "tests.unit.ui.test_tooltip_renderer_native_commit"
	return helpers.with_fresh_modules({ name }, function()
		local scenarios, original_it = {}, helpers.it
		helpers.it = function(label, callback) scenarios[#scenarios + 1] = { label, callback } end
		package.loaded[name] = nil
		local ok, err = xpcall(function() require(name) end, debug.traceback)
		helpers.it = original_it
		if not ok then error(err, 0) end
		return scenarios
	end)
end

helpers.describe("renderer scenario isolation (tooltip-renderer-scope)", function()
	for _, failure in ipairs({ false, true }) do
		helpers.it("restores all renderer scenarios after " .. (failure and "assertion failure" or "success"), function()
			local scenarios = collect_scenarios()
			helpers.assert_eq(#scenarios, 11, "the complete native renderer corpus must be replayed")
			for _, scenario in ipairs(scenarios) do
				local before, native = {}, _G.hs
				for name, value in pairs(package.loaded) do before[name] = value end
				local original_assert = helpers.assert_eq
				if failure then helpers.assert_eq = function() error("forced renderer assertion", 0) end end
				local ok, err = xpcall(scenario[2], debug.traceback)
				helpers.assert_eq = original_assert
				helpers.assert_eq(ok, not failure, scenario[1] .. ": " .. tostring(err))
				if failure then
					helpers.assert_true(tostring(err):find("forced renderer assertion", 1, true) ~= nil,
						"the original scenario failure must remain visible")
				end
				helpers.assert_true(rawequal(_G.hs, native), scenario[1] .. " replaced native state")
				for name, value in pairs(package.loaded) do
					helpers.assert_true(rawequal(value, before[name]), scenario[1] .. " leaked " .. name)
				end
				for name, value in pairs(before) do
					helpers.assert_true(rawequal(package.loaded[name], value), scenario[1] .. " removed " .. name)
				end
			end
		end)
	end
end)
