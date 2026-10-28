--- tests/unit/modules/gestures/actions/confirmation/test_confirmation_lifecycle.lua

--- ==============================================================================
--- MODULE: Confirmation Parent Lifecycle Regression
--- DESCRIPTION:
--- Composes real dispatcher, confirmation, dialog and system-action owners over
--- native alert/task ports. A parent reopened after cleanup cannot adopt the
--- unanswered destructive request from its earlier generation.
--- ==============================================================================

local helpers = require("tests.helpers")
local Gesture = require("tests.support.gesture_actions_fixture")
local OWNED = {
	"native_app_switcher_owner",
	"modules.gestures.action_confirm", "modules.gestures.system_actions",
	"infra.dialog_util", "adapters.mouse_control", "adapters.window_info",
	"adapters.window_manager", "adapters.running_application", "adapters.tcc_grant",
	"adapters.shell_runner", "adapters.task_environment", "infra.launcher_environment",
	"infra.deferred_work", "diagnostics.runtime_log", "file_selection", "window_titles",
}

--- Runs real business owners with only their native calls recorded.
--- @param callback function Receives the world; no business callback is supplied.
local function with_world(callback)
	return helpers.with_stub_scope(OWNED, function()
		return Gesture.with_fixture(function(fresh)
			fresh()
			local w = { alerts = {}, starts = {}, tasks = {}, focus = {} }
			local native = hs
			local target = {
				pid = function() return 4242 end,
				bundleID = function() return "example.confirm.target" end,
				activate = function() w.focus[#w.focus + 1] = "target"; return true end,
			}
			local driver = { activate = function() return true end }
			native.processInfo = {
				processID = 9000, bundleID = "example.confirm.driver",
				bundlePath = "/Applications/ErgoptiPlus.app",
			}
			native.focus = function() return true end
			native.application.frontmostApplication = function() return target end
			native.application.applicationForPID = function(pid)
				if pid == 4242 then return target end
				if pid == 9000 then return driver end
			end
			native.application.applicationsForBundleID = function(id)
				return id == "example.confirm.target" and { target } or {}
			end
			native.mouse.getCurrentScreen = function()
				return { fullFrame = function() return { x = 0, y = 0, w = 1200, h = 900 } end }
			end
			native.dialog.alert = function(...)
				local args = table.pack(...)
				w.alerts[#w.alerts + 1] = args
				-- The public native Lua wrapper returns no values (read as nil).
				-- Never create or directly invoke the business on_confirmed callback.
				return
			end
			native.task.new = function(executable, done, third, fourth)
				local args = fourth or third
				local environment, task = { PATH = "/usr/bin:/bin" }, { running = false }
				function task:environment()
					local copy = {}; for key, value in pairs(environment) do copy[key] = value end
					return copy
				end
				function task:setEnvironment(value) environment = value; return self end
				function task:start()
					self.running = true
					w.starts[#w.starts + 1] = { executable = executable, args = args }
					return self
				end
				function task:isRunning() return self.running end
				function task:terminate() self.running = false; return self end
				function task:finish()
					if not self.running then return end
					self.running = false
					done(0, "", "")
				end
				w.tasks[#w.tasks + 1] = task
				return task
			end

			-- Replace the central fixture's Aux facade before constructing Actions:
			-- both the aggregate and SystemActions must share the real same owner.
			package.loaded["adapters.shell_runner"] = nil
			package.loaded["infra.dialog_util"] = nil
			package.loaded["modules.gestures.system_actions"] = nil
			package.loaded["modules.gestures.action_confirm"] = nil
			package.loaded["modules.gestures.actions_aux_owner"] = nil
			package.loaded["modules.gestures.actions"] = nil
			local Actions = require("modules.gestures.actions")
			Actions.init({ action_params = {} })
			local Confirm = require("modules.gestures.action_confirm")
			local i18n = require("infra.i18n")
			w.actions, w.confirm_owner = Actions, Confirm
			function w.ask()
				helpers.assert_eq(Actions.execute_single("force_quit_frontmost", "tap_3"), true)
				helpers.assert_eq(Confirm.is_pending(), true)
				helpers.assert_eq(#w.starts, 0, "no command before the native answer")
				return #w.alerts
			end
			function w.answer(index, confirmed)
				local alert = assert(w.alerts[index], "real alert callback not captured")
				alert[3](i18n.get(confirmed and "dialog.confirm_action.confirm" or "button.cancel"))
			end
			function w.pause(parent)
				helpers.assert_eq(Actions.force_cleanup(parent or "gestures"), true)
			end
			function w.resume(parent)
				helpers.assert_eq(Actions.resume_after_cleanup(parent or "gestures"), true)
			end
			local outcome = table.pack(xpcall(callback, debug.traceback, w))
			if Confirm.is_pending() then w.answer(#w.alerts, false) end
			for _, task in ipairs(w.tasks) do task:finish() end
			helpers.assert_eq(Actions.force_cleanup("gestures"), true, "exact aggregate cleanup")
			helpers.assert_eq(Actions.force_cleanup("shortcut_bindings"), true, "sibling cleanup")
			helpers.assert_eq(Confirm.is_pending(), false, "question owner released")
			if not outcome[1] then error(outcome[2], 0) end
		end)
	end)
end

helpers.describe("confirmation retains its original parent generation", function()
	helpers.it("runs a healthy confirmation once through the real native command boundary", function()
		with_world(function(w)
			local question = w.ask()
			w.answer(question, true)
			helpers.assert_eq(w.starts, { { executable = "/bin/kill", args = { "-KILL", "4242" } } })
			w.answer(question, true)
			helpers.assert_eq(#w.starts, 1, "the real question owner refuses duplicate native answers")
		end)
	end)

	helpers.it("cancels without starting the destructive command", function()
		with_world(function(w)
			w.answer(w.ask(), false)
			helpers.assert_eq(#w.starts, 0)
			helpers.assert_eq(w.confirm_owner.is_pending(), false)
		end)
	end)

	helpers.it("refuses the pending question while its parent remains paused", function()
		with_world(function(w)
			local question = w.ask()
			w.pause()
			w.answer(question, true)
			helpers.assert_eq(#w.starts, 0)
		end)
	end)

	helpers.it("refuses the old confirmation after the same parent has resumed", function()
		with_world(function(w)
			local question = w.ask()
			w.pause()
			w.resume()
			w.answer(question, true)
			helpers.assert_eq(#w.starts, 0, "a fresh admission cannot adopt the revoked question")
			helpers.assert_eq(w.confirm_owner.is_pending(), false)
		end)
	end)

	helpers.it("permits a fresh question after the earlier generation was refused", function()
		with_world(function(w)
			local old = w.ask()
			w.pause()
			w.answer(old, true)
			helpers.assert_eq(#w.starts, 0)
			w.resume()
			local fresh = w.ask()
			w.answer(old, true)
			helpers.assert_eq(w.confirm_owner.is_pending(), true,
				"the retired question cannot consume its pending successor")
			w.answer(fresh, true)
			helpers.assert_eq(#w.starts, 1)
		end)
	end)

	helpers.it("does not revoke a gesture question when only the shortcut parent cycles", function()
		with_world(function(w)
			local question = w.ask()
			w.pause("shortcut_bindings")
			w.resume("shortcut_bindings")
			w.answer(question, true)
			helpers.assert_eq(#w.starts, 1)
		end)
	end)
end)
