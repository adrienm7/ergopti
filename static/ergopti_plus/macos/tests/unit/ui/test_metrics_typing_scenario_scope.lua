--- tests/unit/ui/test_metrics_typing_scenario_scope.lua

--- ==============================================================================
--- MODULE: Typing Metrics Scenario Isolation Tests
--- DESCRIPTION:
--- Replays actual registered UI scenarios and checks native and cache predecessors.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Collects actual scoped callbacks without publishing replacement registrations.
--- @return table scenarios Registered names and callbacks.
local function collect_scenarios()
	local names = {
		"tests.unit.ui.test_metrics_typing_timer_transaction",
		"tests.unit.ui.test_metrics_typing_javascript_delivery",
	}
	return helpers.with_fresh_modules(names, function()
		local scenarios, original_it = {}, helpers.it
		helpers.it = function(name, callback) scenarios[#scenarios + 1] = { name = name, run = callback } end
		local ok, err = xpcall(function()
			for _, name in ipairs(names) do
				package.loaded[name] = nil
				require(name)
			end
		end, debug.traceback)
		helpers.it = original_it
		if not ok then error(err, 0) end
		return scenarios
	end)
end

helpers.describe("typing scenario lifetime (typing-scenario-scope)", function()
	for _, failure in ipairs({ false, true }) do
		helpers.it("restores every actual scenario after " .. (failure and "assertion failure" or "success"), function()
			local scenarios = collect_scenarios()
			helpers.assert_eq(#scenarios, 16, "both complete scenario families must be replayed")
			for _, scenario in ipairs(scenarios) do
				local before, native = {}, _G.hs
				for name, value in pairs(package.loaded) do before[name] = value end
				local original_assert = helpers.assert_eq
				if failure then helpers.assert_eq = function() error("forced typing scenario assertion", 0) end end
				local ok, err = xpcall(scenario.run, debug.traceback)
				helpers.assert_eq = original_assert
				helpers.assert_eq(ok, not failure, scenario.name .. ": " .. tostring(err))
				if failure then
					helpers.assert_true(tostring(err):find("forced typing scenario assertion", 1, true) ~= nil,
						"the original callback failure must remain visible")
				end
				helpers.assert_true(rawequal(_G.hs, native), scenario.name .. " must restore the exact native predecessor")
				for name, value in pairs(package.loaded) do
					helpers.assert_true(rawequal(value, before[name]), scenario.name .. " leaked " .. name)
				end
				for name, value in pairs(before) do
					helpers.assert_true(rawequal(package.loaded[name], value), scenario.name .. " removed " .. name)
				end
			end
		end)
	end
end)
