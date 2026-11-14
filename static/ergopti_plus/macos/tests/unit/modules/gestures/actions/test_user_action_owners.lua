--- tests/unit/modules/gestures/actions/test_user_action_owners.lua

--- ==============================================================================
--- MODULE: Owners of the user actions (macOS)
--- DESCRIPTION:
--- The pieces run_command, open_path and run_apple_shortcut rely on, each
--- against its real module: the auxiliary owner's private bounded runner and
--- its pause listeners, the binding editors (command, file or folder, shortcut)
--- and the field run's Apple Shortcuts check.
---
--- ROOT CAUSE ENCODED:
--- The auxiliary owner bounded every child by one shared deadline and logged
--- each one's arguments; a user's command line needs its own deadline, an
--- output bound and a payload-free task, and a shortcut run spanning several
--- processes needs the pause of its parent to reach it.
--- ==============================================================================

local helpers = require("tests.helpers")

local SHORTCUT_ID = "1B2C3D4E-5F60-4718-9A0B-C1D2E3F40516"

--- Runs body against a fresh actions_aux_owner over recording process and
--- timer layers.
--- @param body function fn(Aux, world)
local function with_aux(body)
	helpers.with_fresh_modules({ "modules.gestures.actions_aux_owner", "core.process.adapters.shell_runner",
		"core.events.timer_scheduler", "core.logger.engine.logger" }, function()
		local world = { spawned = {}, timers = {} }
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["core.events.timer_scheduler"] = {
			after = function(delay, fn)
				local handle = { delay = delay, observers = {} }
				-- A fired timer settles: its observers run after its callback
				function handle.fn()
					fn()
					for _, observer in ipairs(handle.observers) do observer() end
				end
				world.timers[#world.timers + 1] = handle
				return handle, true
			end,
			onSettled = function(handle, observer)
				handle.observers[#handle.observers + 1] = observer
				return true
			end,
			cancel = function(handle) handle.cancelled = true; return true end,
		}
		package.loaded["core.process.adapters.shell_runner"] = { spawn = function(executable, args, on_done, on_chunk, env, private)
			local handle = { executable = executable, args = args, on_done = on_done, on_chunk = on_chunk,
				env = env, private = private, observers = {} }
			world.spawned[#world.spawned + 1] = handle
			function handle.start() return true end
			function handle.finish(code, out, err)
				handle.settled = true
				on_done(code, out, err)
				for _, observer in ipairs(handle.observers) do observer() end
			end
			function handle.terminate()
				handle.terminated = true
				if not handle.settled then handle.finish(15, "", "") end
				return true, "settled"
			end
			function handle.isSettled() return handle.settled == true end
			function handle.onSettled(observer)
				if handle.settled then observer() else handle.observers[#handle.observers + 1] = observer end
				return true
			end
			return handle
		end }
		body(require("modules.gestures.actions_aux_owner"), world)
	end)
end

helpers.describe("actions_aux_owner runs a user's child privately and bounded (macOS)", function()
	helpers.it("spawns a payload-free task under the caller's own deadline", function()
		with_aux(function(Aux, world)
			local result
			helpers.assert_eq(Aux.run_private("/bin/sh", { "-l", "-c", "true" }, "run_command",
				function(value) result = value end, "gestures", 7, 100), true)
			local task = world.spawned[1]
			helpers.assert_eq(task.private, true)
			helpers.assert_eq(type(task.on_chunk), "function")
			helpers.assert_eq(world.timers[#world.timers].delay, 7)
			task.on_chunk(nil, "out", "err")
			task.finish(0, "put", "")
			helpers.assert_eq(result, { code = 0, stdout = "output", stderr = "err", overflow = false })
		end)
	end)

	helpers.it("stops a child whose output passes the bound and reports the overflow", function()
		with_aux(function(Aux, world)
			local result
			Aux.run_private("/bin/sh", { "-l", "-c", "yes" }, "run_command", function(value) result = value end,
				"gestures", 7, 10)
			local task = world.spawned[1]
			helpers.assert_eq(task.on_chunk(nil, "12345", ""), true)
			helpers.assert_eq(task.on_chunk(nil, "678901", ""), false)
			helpers.assert_eq(task.terminated, true)
			helpers.assert_eq(result.overflow, true)
			helpers.assert_eq(result.stdout, "12345")
		end)
	end)

	helpers.it("reports the deadline as false", function()
		with_aux(function(Aux, world)
			local result = "unset"
			Aux.run_private("/bin/sh", { "-l", "-c", "sleep 99" }, "run_command", function(value) result = value end,
				"gestures", 7, 10)
			world.timers[#world.timers].fn()
			helpers.assert_eq(result, false)
		end)
	end)

	helpers.it("refuses a missing deadline or bound", function()
		with_aux(function(Aux)
			helpers.assert_eq(pcall(Aux.run_private, "/bin/sh", {}, "x", nil, "gestures", nil, 10), false)
			helpers.assert_eq(pcall(Aux.run_private, "/bin/sh", {}, "x", nil, "gestures", 1, 0), false)
		end)
	end)

	helpers.it("tells every pause listener which parent paused", function()
		with_aux(function(Aux)
			local paused = {}
			Aux.register_pause_listener("probe", function(parent) paused[#paused + 1] = parent end)
			Aux.pause("shortcut_bindings")
			Aux.resume("shortcut_bindings")
			helpers.assert_eq(paused, { "shortcut_bindings" })
			helpers.assert_eq(pcall(Aux.register_pause_listener, "", function() end), false)
		end)
	end)
end)

--- Runs body against the real shortcut editor helpers over recording dialogs.
--- @param answers table { texts = {...}, choices = {...} } consumed in order.
--- @param body function fn(ShortcutUtils, seen)
local function with_editor(answers, body)
	helpers.with_fresh_modules({ "ui.menu.shortcut_utils", "core.ui.engine.dialog_util", "adapters.apple_shortcuts_cli",
		"core.i18n.engine.i18n" }, function()
		local seen = { choices = {}, alerts = {} }
		package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end,
			format = function(key) return key end }
		package.loaded["core.ui.engine.dialog_util"] = {
			text_prompt = function(_, _, initial, save)
				seen.initial = initial
				return save, table.remove(answers.texts, 1)
			end,
			choose = function(_, message, labels)
				seen.choices[#seen.choices + 1] = { message = message, labels = labels }
				return table.remove(answers.choices, 1)
			end,
			block_alert = function(_, text) seen.alerts[#seen.alerts + 1] = text end,
			choose_path = function() return answers.path end,
		}
		package.loaded["adapters.apple_shortcuts_cli"] = { list_blocking = function() return answers.rows, answers.reason end }
		body(require("ui.menu.shortcut_utils"), seen)
	end)
end

local GESTURES = { parameter_prompt = function(action) return "prompt:" .. action end }

helpers.describe("the user action editors store one canonical value (macOS)", function()
	helpers.it("a command is typed, then its mode and its output are chosen", function()
		with_editor({ texts = { "date +%F" }, choices = { 1, 3 } }, function(Utils, seen)
			local value = Utils.ask_parameter_value(GESTURES, "run_command", "command", "Title", "")
			helpers.assert_eq(value, '{"version":1,"command":"date +%F","mode":"hidden","output":"copy"}')
			helpers.assert_eq(seen.choices[1].labels, {
				"dialog.gestures.param_command_mode_hidden", "dialog.gestures.param_command_mode_terminal" })
		end)
	end)

	helpers.it("a terminal command asks no output, and the stored mode is offered first", function()
		local prior = '{"version":1,"command":"htop","mode":"terminal","output":"none"}'
		with_editor({ texts = { "htop" }, choices = { 1 } }, function(Utils, seen)
			helpers.assert_eq(Utils.ask_parameter_value(GESTURES, "run_command", "command", "Title", prior), prior)
			helpers.assert_eq(seen.initial, "htop")
			helpers.assert_eq(#seen.choices, 1)
			helpers.assert_eq(seen.choices[1].labels[1], "dialog.gestures.param_command_mode_terminal")
		end)
	end)

	helpers.it("a blank command is returned as typed for the validator to refuse", function()
		with_editor({ texts = { "  " }, choices = { 1, 1 } }, function(Utils)
			local value = Utils.ask_parameter_value(GESTURES, "run_command", "command", "Title", "")
			helpers.assert_eq(value, '{"version":1,"command":"  ","mode":"hidden","output":"none"}')
			helpers.assert_eq(require("shortcuts.engine.user_action_parameter").parse("command", value), nil)
		end)
	end)

	helpers.it("a file or folder comes from the native picker", function()
		with_editor({ path = "/Users/me/Docs" }, function(Utils)
			helpers.assert_eq(Utils.ask_parameter_value(GESTURES, "open_path", "path", "Title", ""), "/Users/me/Docs")
		end)
	end)

	helpers.it("a shortcut is picked from the library, then its input and output", function()
		with_editor({ rows = { { id = SHORTCUT_ID, name = "Resize Image" } }, choices = { 1, 2, 2 } },
			function(Utils, seen)
				local value = Utils.ask_parameter_value(GESTURES, "run_apple_shortcut", "apple_shortcut", "Title", "")
				helpers.assert_eq(require("shortcuts.engine.user_action_parameter").parse("apple_shortcut", value),
					{ id = SHORTCUT_ID, name = "Resize Image", input = "selection", output = "type" })
				helpers.assert_eq(seen.choices[1].labels, { "Resize Image" })
			end)
	end)

	helpers.it("an unreadable or empty library is explained, and nothing is stored", function()
		with_editor({ rows = nil, reason = "query_refused" }, function(Utils, seen)
			helpers.assert_eq(Utils.ask_parameter_value(GESTURES, "run_apple_shortcut", "apple_shortcut", "T", ""), nil)
			helpers.assert_eq(seen.alerts, { "user_actions.shortcuts_unavailable" })
		end)
		with_editor({ rows = {} }, function(Utils, seen)
			helpers.assert_eq(Utils.ask_parameter_value(GESTURES, "run_apple_shortcut", "apple_shortcut", "T", ""), nil)
			helpers.assert_eq(seen.alerts, { "dialog.gestures.param_shortcuts_empty" })
		end)
	end)

	helpers.it("the file-or-folder panel accepts both and the listing is bounded", function()
		local Dialog = helpers.load_with_stubs("core.ui.engine.dialog_util")
		local script = Dialog.path_picker_script("Message", "Title")
		helpers.assert_true(script:find("setCanChooseFiles:true", 1, true) ~= nil, "files")
		helpers.assert_true(script:find("setCanChooseDirectories:true", 1, true) ~= nil, "folders")
		local Cli = helpers.load_with_stubs("adapters.apple_shortcuts_cli")
		helpers.assert_true(Cli.bounded_list_command(20):find("( sleep 20; kill $pid ) >/dev/null 2>&1 &", 1, true) ~= nil,
			"the editor's listing is stopped at the owner's query deadline")
	end)
end)

helpers.describe("the field run checks the Apple Shortcuts action (macOS)", function()
	local Check = require("infra.field_check_apple_shortcuts")

	--- Runs the check against a fake action.
	--- @param rows table|nil The library the fake lists.
	--- @param outcome table|nil { success, category } the fake run reports.
	--- @return table steps
	--- @return table|nil fields What the fake ran.
	local function run_check(rows, outcome)
		local steps, ran, finished = {}, nil, 0
		local report = { step = function(id, state, value) steps[#steps + 1] = { id, state, value } end }
		Check.apple_shortcuts({ apple_shortcut_action = function()
			return {
				list = function(finish) finish(rows, rows == nil and "query_refused" or nil); return true end,
				run = function(fields, _, _, on_finished)
					ran = fields
					on_finished(outcome[1], outcome[2])
					return true
				end,
			}
		end }, report, function() finished = finished + 1 end)
		helpers.assert_eq(finished, 1, "finish is called once")
		return steps, ran
	end

	helpers.it("runs the shortcut named Ergopti Field Test", function()
		local steps, ran = run_check({ { id = SHORTCUT_ID, name = "Ergopti Field Test" } }, { true, "completed" })
		helpers.assert_eq(ran, { id = SHORTCUT_ID, name = "Ergopti Field Test", input = "none", output = "none" })
		helpers.assert_eq(steps, { { "shortcuts_listed", "pass", 1 }, { "field_test_shortcut", "info", "present" },
			{ "field_test_run", "pass", "completed" } })
	end)

	helpers.it("skips the run by name when the library lacks it", function()
		local steps, ran = run_check({ { id = SHORTCUT_ID, name = "Other" } }, { true, "completed" })
		helpers.assert_eq(ran, nil)
		helpers.assert_eq(steps[2], { "field_test_shortcut", "skip", "absent" })
	end)

	helpers.it("fails by name when the library cannot be listed", function()
		local steps = run_check(nil, nil)
		helpers.assert_eq(steps[1], { "shortcuts_listed", "fail", "query_refused" })
	end)

	helpers.it("reports a synchronous listing refusal once even when start returns false", function()
		local steps, finished = {}, 0
		local report = { step = function(id, state, value) steps[#steps + 1] = { id, state, value } end }
		Check.apple_shortcuts({ apple_shortcut_action = function()
			return { list = function(callback)
				callback(nil, "query_refused")
				return false, "start_refused"
			end }
		end }, report, function() finished = finished + 1 end)
		helpers.assert_eq(finished, 1)
		helpers.assert_eq(steps, { { "shortcuts_listed", "fail", "query_refused" },
			{ "field_test_shortcut", "skip", "no_listing" } })
	end)

	helpers.it("is one of the field run's checks", function()
		helpers.assert_eq(require("infra.field_check_checks").checks.apple_shortcuts, Check.apple_shortcuts)
	end)
end)
