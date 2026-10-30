--- tests/unit/adapters/test_field_probe_ports_exec_input.lua

--- ==============================================================================
--- MODULE: Field Run Stdin Port Streams Its Request
--- DESCRIPTION:
--- The launcher's HTTP worker reads its JSON request on stdin to EOF. The
--- field run's loopback check spawned it as a non-streaming task, which never
--- received the bytes: the worker refused an empty request with 64 on the
--- maintainer's Mac (field run of 2026-10-30 20:51, exit_64:not_reached). The
--- port must spawn a streaming task, write the input once it runs, close it,
--- and hand back the stdout its chunks and its completion carried together.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "adapters.field_probe_ports" }

--- Runs exec_input over a recording shell runner.
--- @return table world
local function run_exec_input()
	local world = { order = {} }
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.field_probe_ports"] = nil
		local Ports = require("adapters.field_probe_ports")
		Ports._shell_runner = {
			spawn = function(executable, args, on_done, on_chunk, environment)
				world.streaming = type(on_chunk) == "function"
				world.environment = environment
				local running = false
				return {
					isSettled = function() return false end,
					start = function() running = true; world.order[#world.order + 1] = "start"; return true end,
					set_input = function(data)
						world.order[#world.order + 1] = running and "input_while_running" or "input_before_start"
						world.input = data
						return true
					end,
					close_input = function()
						world.order[#world.order + 1] = "close"
						on_chunk({}, '\0\0\0\44H{"version":1,', "")
						on_done(0, '"status":204}', "")
						return true
					end,
					terminate = function() return true end,
				}
			end,
		}
		Ports.new().exec_input("/x/ErgoptiPlus", { "--managed-http-worker", "5", "5" }, "{}", 10,
			function(code, stdout) world.code, world.stdout = code, stdout end, { E = "1" })
		Ports._shell_runner = nil
	end)
	return world
end

helpers.describe("field run stdin port", function()
	helpers.it("streams the request to a running task, closes it, and joins the output", function()
		local world = run_exec_input()
		helpers.assert_true(world.streaming, "a non-streaming task never receives its stdin")
		helpers.assert_eq(table.concat(world.order, ","), "start,input_while_running,close")
		helpers.assert_eq(world.input, "{}")
		helpers.assert_eq(world.environment.E, "1")
		helpers.assert_eq(world.code, 0)
		helpers.assert_eq(world.stdout, '\0\0\0\44H{"version":1,"status":204}')
	end)
end)
