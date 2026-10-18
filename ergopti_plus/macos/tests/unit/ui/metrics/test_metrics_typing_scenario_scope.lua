--- tests/unit/ui/metrics/test_metrics_typing_scenario_scope.lua

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
		"tests.unit.ui.metrics.test_metrics_typing_timer_transaction",
		"tests.unit.ui.metrics.test_metrics_typing_javascript_delivery",
		"tests.unit.ui.metrics.test_metrics_typing_cache_reads",
		"tests.unit.ui.metrics.test_metrics_typing_cache_save",
		"tests.unit.ui.metrics.test_metrics_typing_clear_cache",
		"tests.unit.ui.metrics.test_typing_publication_order",
		"tests.unit.ui.metrics.test_typing_publication_delivery",
		"tests.unit.ui.metrics.test_typing_cache_reset_transaction",
		"tests.unit.ui.metrics.test_typing_synchronous_delivery",
		"tests.unit.ui.metrics.test_typing_reset_completion",
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

-- Independent enrollment oracle: original families retain their 99 scenarios.
-- These eight additional native JSON regressions must join the same full scope.
local SCALAR_SCENARIOS = {
	"(hs-scalar-json-metrics) native table-only encoder accepts request 1",
	"(hs-scalar-json-metrics) native table-only encoder accepts request 17",
	"(hs-scalar-json-metrics) native table-only encoder accepts request 18",
	"(hs-scalar-json-metrics) canonical quotation refusal nil remains private",
	"(hs-scalar-json-metrics) canonical quotation refusal false remains private",
	"(hs-scalar-json-metrics) canonical quotation refusal throw remains private",
	"(hs-scalar-json-metrics) quotation reentry cannot reset a retired window",
	"(hs-scalar-json-metrics) invalid UTF-8 mailbox bytes refuse without publishing JavaScript",
}

helpers.describe("typing scenario lifetime (typing-scenario-scope)", function()
	for _, failure in ipairs({ false, true }) do
		helpers.it("restores every actual scenario after " .. (failure and "assertion failure" or "success"), function()
			local scenarios = collect_scenarios()
			helpers.assert_eq(#scenarios, 107, "all complete scenario families must be replayed")
			local original_count, scalar_names = 0, {}
			for _, scenario in ipairs(scenarios) do
				if scenario.name:find("(hs-scalar-json-metrics)", 1, true) then
					scalar_names[#scalar_names + 1] = scenario.name
				else original_count = original_count + 1 end
			end
			helpers.assert_eq(original_count, 99, "all original scenario families must remain enrolled")
			helpers.assert_eq(scalar_names, SCALAR_SCENARIOS, "all eight native JSON cases must remain enrolled")
			for _, scenario in ipairs(scenarios) do
				local before, native, original_open = {}, _G.hs, io.open
				local original_remove = os.remove
				for name, value in pairs(package.loaded) do before[name] = value end
				local original_assert = helpers.assert_eq
				if failure then helpers.assert_eq = function() error("forced typing scenario assertion", 0) end end
				local ok, err = xpcall(scenario.run, debug.traceback)
				helpers.assert_eq = original_assert
				helpers.assert_true(rawequal(io.open, original_open), scenario.name .. " must restore native file opening")
				helpers.assert_true(rawequal(os.remove, original_remove), scenario.name .. " must restore native file removal")
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
