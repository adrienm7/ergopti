--- tests/unit/modules/shortcuts/test_screenshot_pause_ownership.lua

--- ==============================================================================
--- MODULE: Shared Screenshot Pause Ownership
--- DESCRIPTION:
--- Exercises the real shared screenshot state machine with exact ShellRunner
--- handles. Shortcut and gesture claims retain false/nil/throw termination debt
--- and fence late terminals without revoking or blocking the sibling parent.
--- ==============================================================================

local helpers = require("tests.helpers")


local function fresh_screenshot()
	for _, name in ipairs({
		"modules.shortcuts.actions.screenshot_save",
		"adapters.shell_runner",
		"adapters.file_system",
		"infra.logger",
		"infra.notifications",
		"infra.i18n",
	}) do package.loaded[name] = nil end

	local fixture = {
		tasks = {},
		next_options = {},
		notifications = {},
	}

	function fixture.queue(options)
		fixture.next_options[#fixture.next_options + 1] = options or {}
	end

	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args, callback)
			local options = table.remove(fixture.next_options, 1) or {}
			local task = {
				role = executable == "/bin/mkdir" and "directory" or "capture",
				executable = executable,
				args = args,
				callback = callback,
				start_mode = options.start_mode or "true",
				terminate_mode = options.terminate_mode or "pending",
				start_calls = 0,
				terminate_calls = 0,
				terminate_identities = {},
				settled = false,
				running = false,
				observers = {},
			}
			function task.start()
				task.start_calls = task.start_calls + 1
				local mode = task.start_mode
				if mode == "sync_success" then
					task.running = true
					task:deliver(0, "", "")
					return true
				end
				if mode == "false_mutate" or mode == "nil_mutate"
					or mode == "throw_mutate" then task.running = true end
				if mode == "false_mutate" then return false end
				if mode == "nil_mutate" then return nil end
				if mode == "throw_mutate" then error("screenshot start exploded") end
				task.running = true
				return true
			end
			function task.isSettled() return task.settled end
			function task.onSettled(observer)
				if task.settled then observer()
				else task.observers[#task.observers + 1] = observer end
				return true
			end
			function task.terminate()
				task.terminate_calls = task.terminate_calls + 1
				task.terminate_identities[task.terminate_calls] = task
				if task.terminate_mode == "false" then return false, "refused" end
				if task.terminate_mode == "nil" then return nil, "refused" end
				if task.terminate_mode == "throw" then error("screenshot terminate exploded") end
				if task.terminate_mode == "sync" then
					task:deliver(-15, "", "terminated")
					return true, "settled"
				end
				return true, "pending"
			end
			function task:deliver(exit_code, stdout, stderr)
				local first = self.settled ~= true
				self.settled = true
				self.running = false
				self.callback(exit_code, stdout or "", stderr or "")
				if first then
					local observers = self.observers
					self.observers = {}
					for _, observer in ipairs(observers) do observer() end
				end
			end
			fixture.tasks[#fixture.tasks + 1] = task
			if type(options.on_spawn) == "function" then options.on_spawn(task) end
			return task
		end,
	}
	package.loaded["adapters.file_system"] = {
		expand_path = function() return "/tmp/hs012-home" end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.notifications"] = {
		notify = function(message, _, kind)
			fixture.notifications[#fixture.notifications + 1] = {
				message = message,
				kind = kind,
			}
			return true
		end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key)
			if key == "shortcuts.saved" then return "Saved %s" end
			return key
		end,
	}
	_G.hs = {
		processInfo = { processID = 7123 },
		timer = { absoluteTime = function() return 987654321 end },
	}
	package.loaded["modules.shortcuts.actions.screenshot_save"] = nil
	fixture.subject = require("modules.shortcuts.actions.screenshot_save")
	return fixture
end


local function reach_phase(fixture, phase)
	helpers.assert_eq(fixture.subject.save({ "-w" }, "window"), true)
	if phase == "directory" then return fixture.tasks[1] end
	fixture.tasks[1]:deliver(0, "", "")
	helpers.assert_eq(#fixture.tasks, 2)
	return fixture.tasks[2]
end


helpers.describe("shared screenshot owner: positive controls", function()
	helpers.it("completes save and direct clipboard capture exactly once", function()
		local f = fresh_screenshot()
		helpers.assert_eq(f.subject.save({}, "full"), true)
		f.tasks[1]:deliver(0, "", "")
		f.tasks[2]:deliver(0, "", "")
		f.tasks[2]:deliver(0, "", "")
		helpers.assert_eq(#f.notifications, 1)
		helpers.assert_eq(f.subject.has_pending_screenshot_action(), false)

		helpers.assert_eq(f.subject.capture({ "-ci" }), true)
		helpers.assert_eq(f.tasks[3].args, { "-ci" })
		helpers.assert_eq(f.subject.resume_screenshot_actions("shortcut_bindings"), true)
		helpers.assert_eq(f.tasks[3].terminate_calls, 0,
			"a duplicate parent RESUME without a claim must not revoke active work")
		f.tasks[3]:deliver(0, "", "")
		helpers.assert_eq(#f.notifications, 1,
			"clipboard capture success deliberately has no save notification")
	end)

	helpers.it("replays synchronous directory and capture terminals exactly once", function()
		local f = fresh_screenshot()
		f.queue({ start_mode = "sync_success" })
		f.queue({ start_mode = "sync_success" })
		helpers.assert_eq(f.subject.save({ "-w" }, "window"), true)
		helpers.assert_eq(#f.tasks, 2,
			"the synchronous mkdir terminal must advance into capture")
		helpers.assert_eq(f.tasks[1].start_calls, 1)
		helpers.assert_eq(f.tasks[2].start_calls, 1)
		helpers.assert_eq(#f.notifications, 1)
		helpers.assert_eq(f.subject.has_pending_screenshot_action(), false)

		f.tasks[1]:deliver(0, "", "")
		f.tasks[2]:deliver(0, "", "")
		helpers.assert_eq(#f.tasks, 2,
			"duplicate synchronous terminals must not create another phase")
		helpers.assert_eq(#f.notifications, 1,
			"duplicate synchronous terminals must not publish twice")
	end)
end)


helpers.describe("shared screenshot owner: parent isolation", function()
	helpers.it("pauses only the matching in-flight operation", function()
		local f = fresh_screenshot()
		f.queue({ terminate_mode = "false" })
		helpers.assert_eq(
			f.subject.capture({ "-ci" }, "gestures"), true)
		local gesture_task = f.tasks[1]

		helpers.assert_eq(
			f.subject.save({ "-w" }, "shortcut", "shortcut_bindings"), true)
		local shortcut_directory = f.tasks[2]
		helpers.assert_eq(
			f.subject.pause_screenshot_actions("gestures"), false)
		helpers.assert_eq(gesture_task.terminate_calls, 1)
		helpers.assert_eq(shortcut_directory.terminate_calls, 0,
			"gesture cleanup must not terminate shortcut work")

		shortcut_directory:deliver(0, "", "")
		local shortcut_capture = f.tasks[3]
		shortcut_capture:deliver(0, "", "")
		helpers.assert_eq(#f.notifications, 1,
			"the live sibling must still publish its terminal result")
		helpers.assert_eq(
			f.subject.has_pending_screenshot_action("shortcut_bindings"), false)

		gesture_task:deliver(0, "", "")
		helpers.assert_eq(#f.notifications, 1,
			"the revoked parent must not publish a late terminal")
		helpers.assert_eq(
			f.subject.pause_screenshot_actions("gestures"), true)
		helpers.assert_eq(
			f.subject.resume_screenshot_actions("gestures"), true)
		helpers.assert_eq(
			f.subject.has_pending_screenshot_action("gestures"), false)
	end)
end)


helpers.describe("shared screenshot owner: phase settlement and claims", function()
	for _, phase in ipairs({ "directory", "capture" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains " .. phase .. " after terminate " .. mode, function()
				local f = fresh_screenshot()
				local target = reach_phase(f, phase)
				local task_count = #f.tasks
				target.terminate_mode = mode
				helpers.assert_eq(
					f.subject.pause_screenshot_actions("shortcut_bindings"), false)
				helpers.assert_eq(f.subject.is_screenshot_actions_paused(), true)
				helpers.assert_eq(f.subject.has_pending_screenshot_action(), true)
				helpers.assert_eq(target.terminate_calls, 1)
				helpers.assert_eq(target.terminate_identities[1] == target, true)
				helpers.assert_eq(f.subject.save({}, "blocked"), false)
				helpers.assert_eq(f.subject.capture({ "-c" }), false)
				helpers.assert_eq(#f.tasks, task_count)

				target.terminate_mode = "pending"
				helpers.assert_eq(
					f.subject.pause_screenshot_actions("shortcut_bindings"), false)
				helpers.assert_eq(target.terminate_calls, 2)
				target:deliver(0, "", "")
				target:deliver(0, "", "")
				helpers.assert_eq(#f.tasks, task_count,
					"a revoked mkdir terminal must never create capture")
				helpers.assert_eq(#f.notifications, 0,
					"revoked capture terminals must never publish")
				helpers.assert_eq(
					f.subject.pause_screenshot_actions("shortcut_bindings"), true)
				helpers.assert_eq(f.subject.pause_screenshot_actions("gestures"), true)
				helpers.assert_eq(
					f.subject.resume_screenshot_actions("shortcut_bindings"), true)
				helpers.assert_eq(
					f.subject.is_screenshot_actions_paused("shortcut_bindings"), false,
					"a sibling claim must not close shortcut admission")
				helpers.assert_eq(
					f.subject.is_screenshot_actions_paused("gestures"), true)
				helpers.assert_eq(
					f.subject.capture({ "-c" }, "shortcut_bindings"), true)
				local sibling_task = f.tasks[#f.tasks]
				sibling_task:deliver(0, "", "")
				helpers.assert_eq(
					f.subject.capture({ "-c" }, "gestures"), false)
				helpers.assert_eq(f.subject.resume_screenshot_actions("gestures"), true)
				helpers.assert_eq(
					f.subject.is_screenshot_actions_paused("gestures"), false)
				helpers.assert_eq(f.subject.has_pending_screenshot_action(), false)
			end)
		end
	end
end)


helpers.describe("shared screenshot owner: reentrant construction pause", function()
	helpers.it("settles the exact spawn handle without starting after revocation", function()
		local f = fresh_screenshot()
		local reentrant_pause
		f.queue({
			start_mode = "throw_mutate",
			terminate_mode = "false",
			on_spawn = function()
				reentrant_pause = f.subject.pause_screenshot_actions("gestures")
			end,
		})

		helpers.assert_eq(f.subject.capture({ "-ci" }, "gestures"), false)
		local target = f.tasks[1]
		helpers.assert_eq(reentrant_pause, false,
			"PAUSE must retain the in-progress construction acquisition")
		helpers.assert_eq(target.start_calls, 0,
			"revoked construction must never dispatch the mutation-sensitive start")
		helpers.assert_eq(target.running, false)
		helpers.assert_eq(target.terminate_calls, 1)
		helpers.assert_eq(target.terminate_identities[1] == target, true)
		helpers.assert_eq(f.subject.has_pending_screenshot_action("gestures"), true)
		helpers.assert_eq(f.subject.capture({ "-c" }, "gestures"), false)

		target.terminate_mode = "pending"
		helpers.assert_eq(f.subject.pause_screenshot_actions("gestures"), false)
		helpers.assert_eq(target.terminate_calls, 2)
		helpers.assert_eq(target.terminate_identities[2] == target, true)
		target:deliver(0, "", "")
		helpers.assert_eq(#f.notifications, 0,
			"the late terminal of an unstarted revoked task must stay fenced")
		helpers.assert_eq(f.subject.pause_screenshot_actions("gestures"), true)
		helpers.assert_eq(f.subject.resume_screenshot_actions("gestures"), true)
		helpers.assert_eq(f.subject.has_pending_screenshot_action("gestures"), false)
	end)
end)


helpers.describe("shared screenshot owner: start rollback debt", function()
	for _, start_mode in ipairs({ "false_mutate", "nil_mutate", "throw_mutate" }) do
		helpers.it("retains a mutate-then-" .. start_mode .. " task", function()
			local f = fresh_screenshot()
			f.queue({ start_mode = start_mode, terminate_mode = "false" })
			helpers.assert_eq(f.subject.capture({ "-c" }, "gestures"), false)
			local target = f.tasks[1]
			helpers.assert_eq(target.terminate_calls, 1)
			helpers.assert_eq(f.subject.has_pending_screenshot_action("gestures"), true)
			helpers.assert_eq(f.subject.pause_screenshot_actions("gestures"), false)
			helpers.assert_eq(target.terminate_calls, 2)
			target:deliver(0, "", "")
			helpers.assert_eq(#f.notifications, 1,
				"only the visible start refusal may notify; the late success is fenced")
			helpers.assert_eq(f.subject.pause_screenshot_actions("gestures"), true)
			helpers.assert_eq(f.subject.resume_screenshot_actions("gestures"), true)
		end)
	end
end)
