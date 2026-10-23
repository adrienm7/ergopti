--- tests/unit/adapters/processes/test_task_output_turn.lua

--- ==============================================================================
--- MODULE: Task Output Turn Probe Regression
--- DESCRIPTION:
--- Issue #100: hs.task reads streaming output only in the default run loop mode,
--- so a deadline fired during an open menu could not tell a silent child from
--- an unread pipe. The probe proves a read turn with an echo that travels the
--- same streaming path (task-output-turn).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the probe over a recording ShellRunner double.
--- @param options table|nil start_result and input_result overrides.
--- @return table probe_module Fresh adapters.task_output_turn.
--- @return table spawns Recorded spawns.
local function load_probe(options)
	options = options or {}
	local spawns = {}
	package.loaded["adapters.task_output_turn"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args, on_done, on_chunk)
			local task = { executable = executable, args = args, on_done = on_done,
				on_chunk = on_chunk, inputs = {}, closed = false, terminated = false }
			spawns[#spawns + 1] = task
			return {
				isSettled = function() return false end,
				start = function()
					if options.start_result == nil then return true end
					return options.start_result
				end,
				set_input = function(data)
					if options.input_result == false then return false end
					task.inputs[#task.inputs + 1] = data
					return true
				end,
				close_input = function() task.closed = true; return true end,
				terminate = function() task.terminated = true; return true end,
			}
		end,
	}
	return require("adapters.task_output_turn"), spawns
end

--- Runs one case with every stubbed module restored afterwards.
--- @param callback function Test body.
local function with_probe(callback)
	return helpers.with_stub_scope({ "adapters.task_output_turn", "adapters.shell_runner", "infra.logger" },
		callback)
end

helpers.describe("task output turn probe", function()
	helpers.it("(task-output-turn) reports a turn only once its echo is read", function()
		with_probe(function()
			local Probe, spawns = load_probe()
			local outcomes = {}
			local probe = Probe.request("test", function(delivered, reason)
				outcomes[#outcomes + 1] = { delivered, reason }
			end)
			helpers.assert_not_nil(probe)
			helpers.assert_eq(spawns[1].executable, "/bin/cat", "the echo child stays alive until its input closes")
			helpers.assert_eq(spawns[1].inputs, { "turn\n" })
			helpers.assert_eq(#outcomes, 0, "writing the line proves nothing: it is the read that counts")
			spawns[1].on_chunk(nil, "", "unrelated\n")
			helpers.assert_eq(#outcomes, 0, "stderr is not the echo")
			spawns[1].on_chunk(nil, "turn\n", "")
			helpers.assert_eq(outcomes, { { true, nil } })
			helpers.assert_true(spawns[1].closed, "the echo child is released once it answered")
			spawns[1].on_done(0, "", "")
			helpers.assert_eq(#outcomes, 1, "the probe settles exactly once")
		end)
	end)

	helpers.it("(task-output-turn) an echo child that exits first reports no turn", function()
		with_probe(function()
			local Probe, spawns = load_probe()
			local outcome
			Probe.request("test", function(delivered, reason) outcome = { delivered, reason } end)
			spawns[1].on_done(1, "", "")
			helpers.assert_eq(outcome[1], false)
			helpers.assert_true(tostring(outcome[2]):find("exited (exit 1)", 1, true) ~= nil, tostring(outcome[2]))
		end)
	end)

	helpers.it("(task-output-turn) a cancelled probe never calls back and closes its child", function()
		with_probe(function()
			local Probe, spawns = load_probe()
			local calls = 0
			local probe = Probe.request("test", function() calls = calls + 1 end)
			probe.cancel()
			helpers.assert_true(spawns[1].closed)
			spawns[1].on_chunk(nil, "turn\n", "")
			spawns[1].on_done(0, "", "")
			helpers.assert_eq(calls, 0)
		end)
	end)

	helpers.it("(task-output-turn) a probe that cannot start or write is refused at once", function()
		with_probe(function()
			local Probe = load_probe({ start_result = false })
			local probe, err = Probe.request("test", function() end)
			helpers.assert_nil(probe)
			helpers.assert_eq(err, "the output probe could not start")
			local Writeless, spawns = load_probe({ input_result = false })
			probe, err = Writeless.request("test", function() end)
			helpers.assert_nil(probe)
			helpers.assert_eq(err, "the output probe refused its input")
			helpers.assert_true(spawns[1].terminated, "a probe that cannot be asked is not left running")
		end)
	end)
end)
