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
	"core.logger.engine.logger", "adapters.field_check_ports", "adapters.shell_runner", "core.events.timer_scheduler",
	"platform.remap.lease_helper", "modules.llm.network_env",
}
local ORIGINS = { "https://registry.ollama.ai", "https://blob.ollama.example" }

helpers.describe("field check command deadlines", function()
	helpers.it("retains a partially started child when launch refuses (field-command-start-owner)", function()
		helpers.with_stub_scope(MODULES, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			local observer, done, terminations = nil, nil, 0
			package.loaded["core.events.timer_scheduler"] = { after = function() error("no timer after refused start") end,
				cancel = function() return true end }
			package.loaded["adapters.shell_runner"] = { spawn = function()
				return { isSettled = function() return false end, start = function() return false end,
					onSettled = function(fn) observer = fn; return true end,
					terminate = function() terminations = terminations + 1; return true, "pending" end }
			end }
			package.loaded["adapters.field_check_ports"] = nil
			require("adapters.field_check_ports").exec("/bin/echo", {}, 5, function(code) done = { code = code } end)
			helpers.assert_eq(terminations, 1)
			helpers.assert_nil(done, "a refused start can still own a live native child")
			observer()
			helpers.assert_true(type(done) == "table")
			helpers.assert_nil(done.code)
		end)
	end)
	helpers.it("waits for process retirement after a timeout signal (field-command-timeout-owner)", function()
		helpers.with_stub_scope(MODULES, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			local observer, deadline, done = nil, nil, nil
			package.loaded["core.events.timer_scheduler"] = {
				after = function(_, callback) deadline = callback; return {}, true end, cancel = function() return true end,
			}
			package.loaded["adapters.shell_runner"] = { spawn = function()
				return { isSettled = function() return false end, start = function() return true end,
					onSettled = function(fn) observer = fn; return true end,
					terminate = function() return true, "pending" end }
			end }
			package.loaded["adapters.field_check_ports"] = nil
			require("adapters.field_check_ports").exec("/bin/echo", {}, 5, function(code) done = { code = code } end)
			deadline()
			helpers.assert_nil(done, "a signalled process can still perform effects")
			observer()
			helpers.assert_true(type(done) == "table")
			helpers.assert_nil(done.code)
		end)
	end)
	helpers.it("cancels a deadline if the child completes while it is being armed (field-command-timer-race)", function()
		helpers.with_stub_scope(MODULES, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			local completion, cancelled, result = nil, 0, nil
			local handle = {}
			package.loaded["core.events.timer_scheduler"] = {
				after = function() completion(0, "ok", ""); return handle, true end,
				cancel = function(value) helpers.assert_eq(value, handle); cancelled = cancelled + 1; return true end,
			}
			package.loaded["adapters.shell_runner"] = { spawn = function(_, _, done)
				completion = done
				return { isSettled = function() return false end, start = function() return true end }
			end }
			package.loaded["adapters.field_check_ports"] = nil
			require("adapters.field_check_ports").exec("/bin/echo", {}, 5, function(code) result = code end)
			helpers.assert_eq(result, 0)
			helpers.assert_eq(cancelled, 1, "no orphan deadline may survive the completed child")
		end)
	end)
	helpers.it("retires the exact child after deadline allocation refusal (field-command-timer-refusal)", function()
		helpers.with_stub_scope(MODULES, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			local observer, done, terminations = nil, nil, 0
			package.loaded["core.events.timer_scheduler"] = { after = function() return {}, false end, cancel = function() return true end }
			package.loaded["adapters.shell_runner"] = { spawn = function()
				return { isSettled = function() return false end, start = function() return true end,
					onSettled = function(fn) observer = fn; return true end,
					terminate = function() terminations = terminations + 1; return true, "pending" end }
			end }
			package.loaded["adapters.field_check_ports"] = nil
			local port = require("adapters.field_check_ports")
			port.exec("/bin/echo", {}, 5, function(code) done = { code = code } end)
			helpers.assert_eq(terminations, 1)
			helpers.assert_nil(done, "an accepted signal is not process retirement")
			helpers.assert_true(type(observer) == "function")
			observer()
			helpers.assert_true(type(done) == "table", "the caller settles only after exact retirement")
			helpers.assert_nil(done.code)
		end)
	end)
end)

--- Runs the port over a scripted launcher.
--- @param script function fn(origin) -> exit code, stdout, stderr
--- @param launcher string|nil The resolved launcher (nil: none).
--- @return table answer, table calls
local function run(script, launcher)
	local calls, answer, timers = {}, nil, {}
	helpers.with_stub_scope(MODULES, function()
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["core.events.timer_scheduler"] = {
			after = function() local handle = { stopped = false }; timers[#timers + 1] = handle; return handle end,
			cancel = function() return true end,
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
	return answer, calls, timers
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

	helpers.it("does not arm a deadline after an inline launcher completion", function()
		local answer, _, timers = run(function() return 0, "ROUTE direct\n" end, "/launcher")
		helpers.assert_eq(#answer.entries, 2)
		helpers.assert_eq(#timers, 0, "completed route lookups must not leave live deadline timers")
	end)

	-- Field run 2026-10-27 19:47 read "lookup_failed" for an unreachable PAC:
	-- the role writes STAGE on stderr and the port only read stdout.
	helpers.it("stops at the first origin the system settings cannot route, naming the native stage", function()
		local answer, calls = run(function() return 78, "", "STAGE native_pac_evaluation\n" end, "/launcher")
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

-- docs/design/proxy-auth-relay.md: the relay beside the launcher answers the probe.
helpers.describe("network check relay probe port", function()
	local function probe(script, launcher, present)
		local calls, answers = {}, {}
		helpers.with_stub_scope({ "core.logger.engine.logger", "adapters.field_check_ports", "adapters.shell_runner",
			"core.events.timer_scheduler", "platform.remap.lease_helper", "core.fs.adapters.file_system" }, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			package.loaded["core.events.timer_scheduler"] = {
				after = function() return { stopped = false } end, cancel = function() return true end,
			}
			package.loaded["adapters.shell_runner"] = {
				spawn = function(executable, args, callback)
					calls[#calls + 1] = { executable = executable, args = args }
					return { isSettled = function() return false end,
						start = function() callback(script(args)); return true end, terminate = function() end }
				end,
			}
			package.loaded["platform.remap.lease_helper"] = {
				resolve = function() return launcher, nil, {} end,
			}
			local FileSystem = require("core.fs.adapters.file_system")
			local real_exists = FileSystem.exists
			package.loaded["core.fs.adapters.file_system"] = setmetatable({
				exists = function(path)
					if path:find("ergopti-proxy-relay", 1, true) then return present end
					return real_exists(path)
				end,
			}, { __index = FileSystem })
			package.loaded["adapters.field_check_ports"] = nil
			require("adapters.field_check_ports").new().relay_probe("http://proxy.corp.example:3128",
				function(answer, reason) answers[#answers + 1] = { answer = answer, reason = reason } end)
		end)
		return answers, calls
	end

	helpers.it("(proxy-auth-relay) runs the bundled relay's probe for the registry", function()
		local answers, calls = probe(function()
			return 0, '{"schema":1,"status":"required","scheme":"negotiate"}\n'
		end, "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus", true)
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(calls[1].executable, "/Applications/ErgoptiPlus.app/Contents/MacOS/ergopti-proxy-relay")
		helpers.assert_eq(calls[1].args[1], "probe")
		helpers.assert_eq(calls[1].args[3], "http://proxy.corp.example:3128")
		helpers.assert_eq(calls[1].args[5], "registry.ollama.ai:443")
		helpers.assert_eq(answers[1].answer.scheme, "negotiate")
	end)

	helpers.it("(proxy-auth-relay) a relay that is not bundled answers not_installed without a child", function()
		local answers, calls = probe(function() error("must not run") end, "/Applications/X.app/Contents/MacOS/ErgoptiPlus", false)
		helpers.assert_eq(#calls, 0)
		helpers.assert_eq(answers[1].answer.status, "not_installed")
		local none = probe(function() error("must not run") end, nil, true)
		helpers.assert_eq(none[1].answer.status, "not_installed")
	end)

	helpers.it("(proxy-auth-relay) a relay that answers off contract is relay_unavailable", function()
		local answers = probe(function() return 1, "panic: boom\n" end,
			"/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus", true)
		helpers.assert_eq(answers[1].reason, "relay_unavailable")
		local timeout = probe(function() return nil, "" end, "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus", true)
		helpers.assert_eq(timeout[1].reason, "relay_unavailable")
	end)
end)
