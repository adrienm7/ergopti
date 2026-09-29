--- tests/unit/modules/gestures/test_action_confirm.lua

--- ==============================================================================
--- MODULE: Destructive actions ask before they run (macOS)
--- DESCRIPTION:
--- The confirmation module (non-blocking alert, Cancel first, one question at
--- a time) and the dispatcher gate: every action the generated catalogue
--- declares `confirm = true` only asks when dispatched, and runs from the
--- answer under the parent that dispatched it.
---
--- ROOT CAUSE ENCODED:
--- The catalogue carried a `confirm` field that no driver read, so emptying
--- the trash or stripping a quarantine from a gesture would have run at once
--- on a stray swipe, against the approved decision that both ask first.
--- ==============================================================================

local helpers = require("tests.helpers")

local CONFIRM_OWNED = {
	"modules.gestures.action_confirm",
	"infra.dialog_util",
	"adapters.mouse_control",
	"infra.i18n",
	"infra.logger",
}

--- Loads the confirmation module over a recording alert.
--- @param body function fn(Confirm, alerts)
--- @param frame table|nil The screen frame under the pointer.
local function with_confirm(body, frame)
	helpers.with_fresh_modules(CONFIRM_OWNED, function()
		local alerts = {}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			format = function(key, value) return key .. ":" .. tostring(value) end,
		}
		package.loaded["adapters.mouse_control"] = {
			screen_frame_under_cursor = function() return frame end,
		}
		package.loaded["infra.dialog_util"] = {
			alert = function(...)
				alerts[#alerts + 1] = table.pack(...)
				return true
			end,
		}
		body(require("modules.gestures.action_confirm"), alerts)
	end)
end

local FRAME = { x = 0, y = 0, w = 1200, h = 900 }

helpers.describe("action confirmation (macOS)", function()
	helpers.it("shows a non-blocking alert with Cancel as the default button", function()
		with_confirm(function(Confirm, alerts)
			local ran = 0
			helpers.assert_eq(Confirm.ask("🗑 Empty", function() ran = ran + 1 end), true)
			local alert = alerts[1]
			helpers.assert_eq(alert[1], 600, "centered on the screen under the pointer")
			helpers.assert_eq(alert[2], 300)
			helpers.assert_eq(type(alert[3]), "function")
			helpers.assert_eq(alert[4], "dialog.confirm_action.title")
			helpers.assert_eq(alert[5], "dialog.confirm_action.message:🗑 Empty")
			helpers.assert_eq(alert[6], "button.cancel", "Cancel is the first, default button")
			helpers.assert_eq(alert[7], "dialog.confirm_action.confirm")
			helpers.assert_eq(ran, 0, "nothing runs before the answer")
			alert[3]("dialog.confirm_action.confirm")
			helpers.assert_eq(ran, 1)
			alert[3]("dialog.confirm_action.confirm")
			helpers.assert_eq(ran, 1, "one answer runs the action once")
		end, FRAME)
	end)

	helpers.it("cancel runs nothing and frees the next question", function()
		with_confirm(function(Confirm, alerts)
			local ran = false
			Confirm.ask("x", function() ran = true end)
			helpers.assert_eq(Confirm.is_pending(), true)
			helpers.assert_eq(Confirm.ask("y", function() ran = true end), false,
				"a second question while one is shown is refused")
			alerts[1][3]("button.cancel")
			helpers.assert_eq(ran, false)
			helpers.assert_eq(Confirm.is_pending(), false)
			helpers.assert_eq(Confirm.ask("y", function() end), true)
		end, FRAME)
	end)

	helpers.it("refuses to run when no screen can show the question", function()
		with_confirm(function(Confirm, alerts)
			helpers.assert_eq(Confirm.ask("x", function() error("must not run") end), false)
			helpers.assert_eq(#alerts, 0)
		end, nil)
	end)
end)





-- =====================================================
-- =====================================================
-- ======= The dispatcher asks for every confirm =======
-- =====================================================
-- =====================================================

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
package.loaded["modules.gestures.engine"] = nil
package.loaded["modules.gestures.actions"] = nil
package.loaded["modules.gestures.conflicts"] = nil
local _gestures = helpers.load_with_stubs("modules.gestures")
local Actions = require("modules.gestures.actions")
local Catalogue = require("_generated.action_catalogue")
local questions = {}

--- Replaces the confirmation and system-actions owners with recorders for the
--- duration of body.
--- @param body function fn(calls)
local function with_recorded_system(body)
	local saved_system = package.loaded["modules.gestures.system_actions"]
	local saved_confirm = package.loaded["modules.gestures.action_confirm"]
	local calls = {}
	package.loaded["modules.gestures.action_confirm"] = {
		ask = function(label, on_confirmed)
			questions[#questions + 1] = { label = label, on_confirmed = on_confirmed }
			return true
		end,
		is_pending = function() return false end,
	}
	package.loaded["modules.gestures.system_actions"] = setmetatable({}, {
		__index = function(_, method)
			return function(parent)
				calls[#calls + 1] = { method = method, parent = parent }
				return true
			end
		end,
	})
	local ok, err = pcall(body, calls)
	package.loaded["modules.gestures.system_actions"] = saved_system
	package.loaded["modules.gestures.action_confirm"] = saved_confirm
	if not ok then error(err, 0) end
end

helpers.describe("the macOS dispatcher confirms before destructive actions", function()
	helpers.it("the catalogue declares the approved confirmations", function()
		local confirmed = {}
		for id, meta in pairs(Catalogue.actions) do
			if meta.confirm == true then confirmed[#confirmed + 1] = id end
		end
		table.sort(confirmed)
		helpers.assert_eq(confirmed, { "empty_trash", "remove_quarantine_selection" })
	end)

	helpers.it("every confirm action asks, and runs only from the answer, under its parent", function()
		with_recorded_system(function(calls)
			for _, id in ipairs({ "empty_trash", "remove_quarantine_selection" }) do
				questions = {}
				local before = #calls
				helpers.assert_eq(Actions.execute_single(id, "keyboard__cmd_1"), true)
				helpers.assert_eq(#questions, 1, id .. " must ask")
				helpers.assert_eq(questions[1].label, Actions.get_label(id))
				helpers.assert_eq(#calls, before, id .. " must not run before the answer")
				questions[1].on_confirmed()
				helpers.assert_eq(calls[#calls], { method = id, parent = "shortcut_bindings" })
			end
		end)
	end)

	helpers.it("an action without confirm runs at once, with no question", function()
		with_recorded_system(function(calls)
			questions = {}
			helpers.assert_eq(Actions.execute_single("sleep_displays", "tap_3"), true)
			helpers.assert_eq(#questions, 0)
			helpers.assert_eq(calls[#calls], { method = "sleep_displays", parent = "gestures" })
		end)
	end)
end)
