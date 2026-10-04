--- tests/support/physical_capture_fixture.lua

--- Exercises the dormant owner over actual accounting, delivery and transport.
local helpers = require("tests.helpers")
local Frames = require("tests.support.physical_stream_frames")
local M = {}

--- Runs one isolated owner with explicit native task completion and settlement.
---@param callback function Receives owner, observation log and control ports.
function M.run(callback)
	helpers.with_stub_scope({
		"infra.logger", "modules.keylogger.physical_capture",
		"modules.keylogger.physical_accounting_mode",
	}, function()
		local observed = { tasks = {}, spawns = {}, warnings = {}, errors = {}, credits = {}, writes = {} }
		local logger = helpers.make_logger_stub()
		function logger.warn(_, message, ...) observed.warnings[#observed.warnings + 1] = string.format(message, ...) end
		function logger.error(_, message, ...) observed.errors[#observed.errors + 1] = string.format(message, ...) end
		package.loaded["infra.logger"] = logger
		local mode = require("modules.keylogger.physical_accounting_mode")
		local capture = require("modules.keylogger.physical_capture")
		local frames = Frames.new("production-fixture", "7", { "41" })
		for _, frame in pairs(frames) do frame.coverage = "complete" end
		local controls = { frames = frames, mode = mode }
		local dependencies = {
			spawn = function(executable, arguments, done, chunk)
				local task = { executable = executable, arguments = arguments, done = done, chunk = chunk,
					stops = 0, state = "prepared" }
				function task.onSettled(settled)
					function task.settle() task.state = "settled"; settled() end
					if task.state == "settled" then settled() end
					return true
				end
				function task.start() task.started, task.state = true, "running"; return true end
				function task.terminate()
					task.stops = task.stops + 1
					if task.refuse_stop then return false, "pending" end
					if task.state == "prepared" and not controls.delay_prepared_settlement then
						task.state = "settled"
						if task.settle then task.settle() end
						return true, "settled"
					end
					return true, "pending"
				end
				function task.set_input(bytes) observed.writes[#observed.writes + 1] = bytes; return true end
				observed.tasks[#observed.tasks + 1] = task
				observed.spawns[#observed.spawns + 1] = { executable = executable, arguments = arguments }
				if controls.on_spawn then controls.on_spawn(task) end
				return task
			end,
			decode = function(line) return frames[line] end,
			encode = function(receipt) return receipt.baseline_ack or receipt.ack end,
			context = function() return { allowed = true, app = "ObservedApp", timestamp = "2026-09-12 12:00:00.000" } end,
			keycode = Frames.keycode,
			emit = function(press) observed.credits[#observed.credits + 1] = press end,
		}
		controls.dependencies = dependencies
		controls.options = { executable = "/owned/runtime/karabiner_cli", arguments = { "--hs274-capture", "25" },
			requirement = 'certificate leaf = H"0123456789abcdef0123456789abcdef01234567"',
			batch_limit = 8, frame_limit = 32 }
		function controls.verified()
			local task = observed.tasks[1]
			task.done(0)
			task.settle()
		end
		function controls.open()
			local task = observed.tasks[2]
			task.chunk(nil, "opened\npage\nready\n")
		end
		callback(capture, observed, controls)
	end)
end

return M
