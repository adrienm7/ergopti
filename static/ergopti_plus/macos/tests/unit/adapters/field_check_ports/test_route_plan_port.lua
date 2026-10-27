--- tests/unit/adapters/field_check_ports/test_route_plan_port.lua

--- ==============================================================================
--- MODULE: Field Check Route Plan Port (macOS)
--- DESCRIPTION:
--- The route_plan port of the network check asks the launcher's route command for
--- each origin of the managed Ollama daemon, one after the other under the shared
--- lookup budget, and turns its ROUTE and STAGE lines into the answer the shared
--- check judges. Nothing but a closed token comes back from a failure.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"infra.logger", "adapters.field_check_ports", "adapters.shell_runner", "adapters.timer_scheduler",
	"platform.remap.lease_helper", "modules.llm.network_env",
}
local ORIGINS = { "https://registry.ollama.ai", "https://blob.ollama.example" }

--- Runs the port over a scripted launcher.
--- @param script function fn(origin) -> exit code, output
--- @param launcher string|nil The resolved launcher (nil: none).
--- @return table answer, table calls
local function run(script, launcher)
	local calls, answer = {}, nil
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.timer_scheduler"] = {
			after = function() return { stopped = false } end, cancel = function() return true end,
		}
		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, callback)
				calls[#calls + 1] = { executable = executable, args = args }
				return {
					isSettled = function() return false end,
					start = function() callback(script(args[2])); return true end,
					terminate = function() end,
				}
			end,
		}
		package.loaded["platform.remap.lease_helper"] = {
			resolve = function() return launcher, nil, { LAUNCHER = "1" } end,
		}
		package.loaded["modules.llm.network_env"] = {
			route_origins = function() return ORIGINS end,
			route_lookup_budget_seconds = function() return 20 end,
		}
		package.loaded["adapters.field_check_ports"] = nil
		require("adapters.field_check_ports").new().route_plan(function(value) answer = value end)
	end)
	return answer, calls
end

helpers.describe("network check route plan port", function()
	helpers.it("asks the launcher about each origin in order and returns the routes it names", function()
		local answer, calls = run(function(origin)
			if origin == ORIGINS[1] then return 0, "ROUTE http://relay.corp.example:3128\n" end
			return 0, "ROUTE direct\n"
		end, "/launcher")
		helpers.assert_eq(#calls, 2)
		helpers.assert_eq(calls[1].args, { "--managed-proxy-route", ORIGINS[1], "20" })
		helpers.assert_eq(calls[2].args[2], ORIGINS[2])
		helpers.assert_eq(answer.entries, {
			{ origin = ORIGINS[1], route = "http://relay.corp.example:3128" },
			{ origin = ORIGINS[2], route = "direct" },
		})
	end)

	helpers.it("stops at the first origin the system settings cannot route, naming the native stage", function()
		local answer, calls = run(function() return 1, "STAGE native_pac_evaluation\n" end, "/launcher")
		helpers.assert_eq(answer, { failure = "native_pac_evaluation" })
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(run(function() return nil, "" end, "/launcher").failure, "lookup_failed")
	end)

	helpers.it("names a missing launcher without running anything", function()
		local answer, calls = run(function() error("must not run") end, nil)
		helpers.assert_eq(answer, { failure = "launcher_unavailable" })
		helpers.assert_eq(#calls, 0)
	end)
end)
