--- tests/unit/adapters/test_field_probe_ports_exec_input.lua

--- ==============================================================================
--- MODULE: Field Run Stdin Port Streams Its Request
--- DESCRIPTION:
--- The launcher's HTTP worker reads its JSON request on stdin to EOF, and
--- xmllint reads a whole layout there. hs.task queues setInput bytes written
--- BEFORE the start and closes stdin itself, on a task with no streaming
--- callback (modules/llm/api_token_crypto.lua relies on it). Writing after the
--- start lost the request (exit_64:not_reached on 2026-10-30 20:51 and 21:53)
--- and cut layouts short (keylayout_xml refused_7_of_8). The port must queue
--- the input before the start, never stream, never call closeInput.
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
					set_input = function(data)
						world.order[#world.order + 1] = running and "input_while_running" or "input_before_start"
						world.input = data
						return true
					end,
					start = function()
						running = true
						world.order[#world.order + 1] = "start"
						on_done(0, '\0\0\0\44H{"version":1,"status":204}', "")
						return true
					end,
					close_input = function() world.order[#world.order + 1] = "close"; return true end,
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
	helpers.it("queues the request before the start of a non-streaming task", function()
		local world = run_exec_input()
		helpers.assert_true(not world.streaming, "setInput closes stdin itself only without a streaming callback")
		helpers.assert_eq(table.concat(world.order, ","), "input_before_start,start")
		helpers.assert_eq(world.input, "{}")
		helpers.assert_eq(world.environment.E, "1")
		helpers.assert_eq(world.code, 0)
		helpers.assert_eq(world.stdout, '\0\0\0\44H{"version":1,"status":204}')
	end)
end)
