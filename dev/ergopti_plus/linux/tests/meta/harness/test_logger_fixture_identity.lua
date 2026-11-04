--- tests/meta/harness/test_logger_fixture_identity.lua

--- Genuine instrumentation fixtures must not replace another module's logger.
local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote

helpers.describe("instrumentation fixture logger ownership", function()
	helpers.it("(logger-fixture-identity) restores aliases and instrumentation after an assertion fails", function()
		local core, shim = package.loaded.logger, package.loaded["logger.shim"]
		local instrument = package.loaded["infra.perf_counters"]
		local ok, failure = pcall(require("tests.support.logger_fixture").with, { "infra.perf_counters" }, function()
			package.loaded.logger, package.loaded["logger.shim"] = nil, nil
			require("logger.shim")
			helpers.load_module("infra.perf_counters")
			error("controlled logger fixture failure")
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(failure, "controlled logger fixture failure")
		helpers.assert_true(package.loaded.logger == core)
		helpers.assert_true(package.loaded["logger.shim"] == shim)
		helpers.assert_true(package.loaded["infra.perf_counters"] == instrument)
	end)

	for _, scenario in ipairs({
		{ module = "tests.unit.infra.test_perf_counters", owned = { "infra.perf_counters", "infra.paths", "toml_codec.reader" } },
		{ module = "tests.unit.infra.test_phase_stats", owned = {
			"infra.phase_stats", "adapters.shell_runner", "ui.menu.timed_build", "infra.toml.reader", "infra.boot_profiler",
			"infra.perf_counters", "toml_codec.reader",
		} },
		{ module = "tests.unit.infra.lifecycle.test_boot_profiler_summary", owned = { "infra.boot_profiler", "infra.phase_stats" } },
	}) do
		local module_name = scenario.module
		for _, mode in ipairs({ "cold", "warm" }) do
			helpers.it("(logger-fixture-identity) retains captured guard after " .. mode .. " " .. module_name, function()
				local owned = {}
				for _, name in ipairs(scenario.owned) do owned[#owned + 1] = string.format("%q", name) end
				local child = [[
package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
require("test.runner_home").isolate()
require("compat.utf8").install()
if ]] .. string.format("%q", mode) .. [[ == "warm" then require("infra.timings") end
local helpers = require("tests.helpers")
helpers.reset_results()
local logger = require("logger.shim")
require("ui.menu.llm_config_guard")
local modules = { ]] .. table.concat(owned, ", ") .. [[ }
local previous = {}
for _, name in ipairs(modules) do
    if ]] .. string.format("%q", mode) .. [[ == "warm" then require(name) end
    previous[name] = package.loaded[name]
end
require(]] .. string.format("%q", module_name) .. [[)
for _, name in ipairs(modules) do
    assert(package.loaded[name] == previous[name], "the fixture must restore its owned consumer: " .. name)
end
assert(package.loaded.logger == logger, "the fixture must restore the original genuine core")
assert(package.loaded["logger.shim"] == logger, "the fixture must restore the captured logger identity")
require("tests.unit.ui.menu.llm.test_ai_config_parents")
local result = helpers.get_results()
assert(result.failed == 0, "all actual fixture and retained-click guard assertions must pass")
assert(result.passed > 2, "the actual instrumentation cases and both guard cases must execute")
]]
				local status = os.execute("luajit -e " .. quote(child))
				helpers.assert_true(status == true or status == 0,
					"the actual instrumentation fixture must preserve cached consumer identities")
			end)
		end
	end
end)
