--- tests/unit/modules/gestures/test_action_confirm.lua

--- ==============================================================================
--- MODULE: Destructive actions ask before they run (macOS)
--- DESCRIPTION:
--- The confirmation module (non-blocking alert, Cancel first, one question at
--- a time) and the dispatcher gate: every action the generated catalogue
--- declares `confirm = true` only asks when dispatched, and runs from the
--- answer under the parent that dispatched it.
---
--- ROOT CAUSES ENCODED:
--- 1. The catalogue carried a `confirm` field that no driver read, so emptying
---    the trash or stripping a quarantine from a gesture would have run at once
---    on a stray swipe, against the approved decision that both ask first.
--- 2. force_quit_frontmost killed the frontmost application unasked, against
---    the decision of 2026-09-29 that it asks like the other destructive ones.
--- 3. The alert brings the driver to the front: a confirmed force quit then
---    found the driver frontmost. Giving the focused window its focus back did
---    not cover an application with no window or a hung one, whose window the
---    accessibility API cannot read: the application the user acted from is
---    read before the alert, and the confirmed action gets it.
--- ==============================================================================

local helpers = require("tests.helpers")

local CONFIRM_OWNED = {
	"modules.gestures.action_confirm",
	"infra.dialog_util",
	"adapters.mouse_control",
	"adapters.window_info",
	"adapters.window_manager",
	"infra.i18n",
	"infra.logger",
}

--- Loads the confirmation module over a recording alert.
--- @param body function fn(Confirm, alerts, focus)
--- @param frame table|nil The screen frame under the pointer.
--- @param focus table|nil { front = frontmost application, activates = true|false }.
local function with_confirm(body, frame, focus)
	focus = focus or { front = nil, activates = true }
	focus.activated = {}
	helpers.with_fresh_modules(CONFIRM_OWNED, function()
		local alerts = {}
		package.loaded["adapters.window_info"] = {
			frontmost_application = function() return focus.front end,
		}
		package.loaded["adapters.window_manager"] = {
			activate = function(spec)
				focus.activated[#focus.activated + 1] = spec
				return focus.activates
			end,
		}
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
		body(require("modules.gestures.action_confirm"), alerts, focus)
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

	-- The alert brings the driver to the front: what is frontmost once it is
	-- answered is the driver, never the application the user acted from.
	helpers.it("hands the action the application read before the alert (confirm-acted-from)", function()
		local safari = { pid = 4242, bundle_id = "com.apple.Safari" }
		local focus = { front = safari, activates = true }
		with_confirm(function(Confirm, alerts)
			local got = {}
			Confirm.ask("x", function(acted_from) got[#got + 1] = acted_from end)
			focus.front = { pid = 500, bundle_id = "com.ergoptiplus.app" }
			helpers.assert_eq(#focus.activated, 0, "the focus stays with the alert while it asks")
			alerts[1][3]("dialog.confirm_action.confirm")
			helpers.assert_eq(got, { safari })
			helpers.assert_eq(focus.activated, { "com.apple.Safari" }, "that application gets its focus back")
		end, FRAME, focus)
	end)

	-- A hung application may refuse the focus: the action it was confirmed for
	-- targets the application it got, so it still runs.
	helpers.it("runs even when that application cannot get its focus back (confirm-acted-from)", function()
		local safari = { pid = 4242, bundle_id = "com.apple.Safari" }
		local focus = { front = safari, activates = false }
		with_confirm(function(Confirm, alerts)
			local got = {}
			Confirm.ask("x", function(acted_from) got[#got + 1] = acted_from end)
			alerts[1][3]("dialog.confirm_action.confirm")
			helpers.assert_eq(got, { safari })
			helpers.assert_eq(Confirm.is_pending(), false)
		end, FRAME, focus)
	end)

	helpers.it("with no readable application, the action runs with none (confirm-acted-from)", function()
		local focus = { front = nil, activates = false }
		with_confirm(function(Confirm, alerts)
			local runs = 0
			local got = "unset"
			Confirm.ask("x", function(acted_from)
				runs = runs + 1
				got = acted_from
			end)
			alerts[1][3]("dialog.confirm_action.confirm")
			helpers.assert_eq(runs, 1)
			helpers.assert_eq(got, nil)
			helpers.assert_eq(#focus.activated, 0)
		end, FRAME, focus)
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
			return function(parent, acted_from)
				calls[#calls + 1] = { method = method, parent = parent, acted_from = acted_from }
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
		helpers.assert_eq(confirmed, { "empty_trash", "force_quit_frontmost", "remove_quarantine_selection" })
	end)

	helpers.it("every confirm action asks, and runs only from the answer, under its parent", function()
		local acted_from = { pid = 4242, bundle_id = "com.apple.Safari" }
		with_recorded_system(function(calls)
			for _, id in ipairs({ "empty_trash", "remove_quarantine_selection", "force_quit_frontmost" }) do
				questions = {}
				local before = #calls
				helpers.assert_eq(Actions.execute_single(id, "keyboard__cmd_1"), true)
				helpers.assert_eq(#questions, 1, id .. " must ask")
				helpers.assert_eq(questions[1].label, Actions.get_label(id))
				helpers.assert_eq(#calls, before, id .. " must not run before the answer")
				questions[1].on_confirmed(acted_from)
				helpers.assert_eq(calls[#calls], { method = id, parent = "shortcut_bindings", acted_from = acted_from },
					id .. " gets the application read before its question (confirm-acted-from)")
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
