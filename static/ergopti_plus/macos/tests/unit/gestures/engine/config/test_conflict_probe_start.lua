--- tests/unit/gestures/engine/config/test_conflict_probe_start.lua

--- ==============================================================================
--- MODULE: System Gesture Probe Process Lifecycle
--- DESCRIPTION:
--- Models ShellRunner's prepared handles, start acknowledgement and settlement.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_probe(body)
	helpers.with_fresh_modules({ "gestures.engine.conflicts", "core.process.adapters.shell_runner", "core.logger.engine.logger" }, function()
		local tasks = {}
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["core.process.adapters.shell_runner"] = { spawn = function(_, args, callback)
			local task = { args = args, callback = callback, starts = 0, observers = {}, settled = false }
			function task.start()
				task.starts = task.starts + 1
				return not task.refuse_start
			end
			function task.isSettled() return task.settled end
			function task.terminate()
				task.terminations = (task.terminations or 0) + 1
				return false
			end
			function task.onSettled(observer) task.observers[#task.observers + 1] = observer; return true end
			function task.finish(code, text, stderr)
				task.settled = true
				task.callback(code, text, stderr)
				for _, observer in ipairs(task.observers) do observer() end
			end
			tasks[#tasks + 1] = task
			if #tasks == 1 and body.refuse_first then task.refuse_start = true end
			return task
		end }
		body.run(require("gestures.engine.conflicts"), tasks)
	end)
end

helpers.describe("system gesture probe startup", function()
	helpers.it("models disabled and enabled macOS gestures through the real conflict policy", function()
		local World = require("tests.e2e.boot.world")
		for _, enabled in ipairs({ false, true }) do
			with_probe({ run = function(conflicts, tasks)
				helpers.assert_eq(conflicts.refresh(), true)
				for _, task in ipairs(tasks) do
					local answer = assert(World.gesture_preferences_answer(task.args, enabled))
					task.finish(answer.code, answer.stdout, answer.stderr)
				end
				helpers.assert_eq(conflicts.slot_system_state("tap_3"), enabled and "taken" or "free")
				local warning = conflicts.on_action_changed("tap_3", "lookup")
				if enabled then helpers.assert_type(warning, "table") else helpers.assert_nil(warning) end
			end })
		end
		helpers.assert_nil(World.gesture_preferences_answer({ "read", "unknown.domain" }, false),
			"the model must not turn unknown defaults calls into success")
	end)
	helpers.it("starts all prepared processes and publishes only after all complete", function()
		with_probe({ run = function(conflicts, tasks)
			local calls = 0
			helpers.assert_eq(conflicts.refresh(function() calls = calls + 1 end), true)
			helpers.assert_eq(#tasks, 4)
			for _, task in ipairs(tasks) do helpers.assert_eq(task.starts, 1) end
			for index = 1, 3 do tasks[index].finish(0, "TrackpadThreeFingerTapGesture = 1;") end
			helpers.assert_eq(calls, 0)
			tasks[4].finish(0, "")
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(conflicts.slot_system_state("tap_3"), "taken")
		end })
	end)

	helpers.it("retains a failed start until its exact process settles", function()
		with_probe({ refuse_first = true, run = function(conflicts, tasks)
			helpers.assert_eq(conflicts.refresh(), true)
			helpers.assert_eq(tasks[1].starts, 1)
			helpers.assert_true(tasks[1].terminations >= 1)
			for index = 2, 4 do tasks[index].finish(0, "") end
			helpers.assert_eq(conflicts.refresh(), false)
			helpers.assert_eq(conflicts.refresh(), false)
			helpers.assert_eq(#tasks[1].observers, 1, "retries must not accumulate settlement observers")
			helpers.assert_eq(#tasks, 4, "a successor cannot hide the unsettled process")
			tasks[1].finish(15, "")
			helpers.assert_eq(conflicts.refresh(), true)
			helpers.assert_eq(#tasks, 8)
		end })
	end)

	helpers.it("fences cancelled callbacks and waits for every process at shutdown", function()
		with_probe({ run = function(conflicts, tasks)
			local calls = 0
			helpers.assert_eq(conflicts.refresh(function() calls = calls + 1 end), true)
			helpers.assert_eq(conflicts.restore_all_overrides(), false)
			for index = 1, 3 do tasks[index].finish(0, "TrackpadThreeFingerTapGesture = 1;") end
			helpers.assert_eq(conflicts.refresh(), false)
			helpers.assert_eq(#tasks, 4)
			tasks[4].finish(0, "TrackpadThreeFingerTapGesture = 1;")
			helpers.assert_eq(calls, 0, "shutdown fences every old completion")
			helpers.assert_eq(conflicts.refresh(), true)
			helpers.assert_eq(#tasks, 8)
		end })
	end)

	helpers.it("retains a refused watch timer and fences its callback", function()
		with_probe({ run = function(conflicts, tasks)
			local timer, can_stop, cancelled = {}, false, 0
			local scheduler = {
				every = function(_, callback) timer.callback = callback; return timer, true end,
				cancel = function(handle)
					helpers.assert_eq(handle, timer)
					cancelled = cancelled + 1
					return can_stop
				end,
			}
			helpers.assert_eq(conflicts.start_watch(scheduler), true)
			helpers.assert_eq(conflicts.restore_all_overrides(), false)
			timer.callback()
			helpers.assert_eq(#tasks, 0, "the stopped watch cannot start a probe")
			helpers.assert_eq(conflicts.start_watch(scheduler), false)
			can_stop = true
			helpers.assert_eq(conflicts.restore_all_overrides(), true)
			helpers.assert_true(cancelled >= 3, "the same timer is retried")
		end })
	end)

	helpers.it("holds an apparently free slot when a preference source failed", function()
		with_probe({ run = function(conflicts, tasks)
			helpers.assert_eq(conflicts.refresh(), true)
			tasks[1].finish(0, "TrackpadThreeFingerTapGesture = 0;")
			tasks[2].finish(1, "", "permission denied")
			tasks[3].finish(0, "")
			tasks[4].finish(0, "")
			helpers.assert_eq(conflicts.slot_system_state("tap_3"), "unverified")
			helpers.assert_eq(conflicts.slot_held_by_system("tap_3"), true)
			helpers.assert_type(conflicts.on_action_changed("tap_3", "lookup"), "table")
			helpers.assert_eq(conflicts.slot_system_state("tap_2"), "free")
			local changes = 0
			conflicts.set_state_listener(function() changes = changes + 1 end)
			helpers.assert_eq(conflicts.recheck(), true)
			for index = 5, 8 do tasks[index].finish(0, "TrackpadThreeFingerTapGesture = 0;") end
			helpers.assert_eq(conflicts.slot_system_state("tap_3"), "free")
			helpers.assert_eq(changes, 1, "the menu is refreshed when verification recovers")
		end })
	end)

	helpers.it("treats an explicitly absent preference domain as a normal default", function()
		with_probe({ run = function(conflicts, tasks)
			helpers.assert_eq(conflicts.refresh(), true)
			tasks[1].finish(0, "TrackpadThreeFingerTapGesture = 0;")
			tasks[2].finish(1, "", "2026-11-04 defaults[1] diagnostic\nDomain com.apple.driver.AppleBluetoothMultitouch.trackpad does not exist\n")
			tasks[3].finish(0, "")
			tasks[4].finish(0, "")
			helpers.assert_eq(conflicts.slot_system_state("tap_3"), "free")
			helpers.assert_nil(conflicts.on_action_changed("tap_3", "lookup"))
		end })
	end)
end)
