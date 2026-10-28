--- tests/unit/infra/logger/test_modal_wait_is_not_a_stall.lua

--- ==============================================================================
--- MODULE: Slow-callback report — a modal dialog's wait is not a stall
--- DESCRIPTION:
--- Issue #101 listed three timer callbacks as holding the main thread for 1.7 s
--- to 4.5 s: the model system check, the MLX repair offer and the startup
--- controller. Each one opens a modal dialog, so the "hold" was the time the
--- user took to read and answer it. The slow-callback report now subtracts the
--- time spent inside Logger.run_modal, and infra/dialog_util wraps every
--- blocking dialog in it.
---
--- FEATURES & RATIONALE:
--- 1. Scripted clock: the hs stub's absoluteTime is driven by the test, so a
---    "four second dialog" costs no wall time.
--- 2. Real wiring: the dialog_util assertions call its wrappers over a stubbed
---    hs.dialog/hs.osascript that advance the clock, so a wrapper that stops
---    using run_modal fails here.
--- ==============================================================================

local helpers = require("tests.helpers")

local NS_PER_MS = 1000000
local DIALOG_WAIT_MS = 4500
local REAL_STALL_MS = 1500

--- Runs `body` over a fresh logger installed on a scripted clock.
--- @param body function Receives (Logger, clock, captured).
local function with_capture(body)
	local saved_logger = package.loaded["infra.logger"]
	local saved_dialog = package.loaded["infra.dialog_util"]
	package.loaded["infra.logger"] = nil
	package.loaded["infra.dialog_util"] = nil
	local Fresh = require("infra.logger")
	helpers.admit_logger_privacy(Fresh)
	local hs = _G.hs
	local saved = {
		doAfter = hs.timer.doAfter, doEvery = hs.timer.doEvery, new = hs.timer.new,
		delayed_new = hs.timer.delayed and hs.timer.delayed.new or nil,
		absoluteTime = hs.timer.absoluteTime, print = _G.print,
		dialog = hs.dialog, osascript = hs.osascript,
	}
	local clock = { now = 0 }
	hs.timer.absoluteTime = function() return clock.now end
	hs.timer.doAfter = function(_delay, fn) if type(fn) == "function" then fn() end end
	local captured = {}
	Fresh.set_sink(function(line) captured[#captured + 1] = line end)
	Fresh.set_level("DEBUG")
	Fresh.install_runtime_error_capture()
	local ok, err = pcall(body, Fresh, clock, captured)
	Fresh.set_sink(nil)
	hs.timer.doAfter, hs.timer.doEvery, hs.timer.new = saved.doAfter, saved.doEvery, saved.new
	hs.timer.absoluteTime = saved.absoluteTime
	if hs.timer.delayed then hs.timer.delayed.new = saved.delayed_new end
	hs.dialog, hs.osascript = saved.dialog, saved.osascript
	_G.print = saved.print
	package.loaded["infra.logger"] = saved_logger
	package.loaded["infra.dialog_util"] = saved_dialog
	if not ok then error(err, 0) end
end

--- Counts captured lines that contain `needle`.
local function count_lines(captured, needle)
	local count = 0
	for _, line in ipairs(captured) do
		if line:find(needle, 1, true) then count = count + 1 end
	end
	return count
end

helpers.describe("slow-callback report: modal dialog wait (issue-101-modal-wait)", function()
	helpers.it("does not report a callback that only waited inside Logger.run_modal", function()
		with_capture(function(Logger, clock, captured)
			local function hosts_dialog()
				Logger.run_modal(function() clock.now = clock.now + DIALOG_WAIT_MS * NS_PER_MS end)
			end
			hs.timer.doAfter(0, hosts_dialog)
			helpers.assert_eq(count_lines(captured, "held the main thread"), 0,
				"the user's reading time inside a dialog is not a main-thread stall")
		end)
	end)

	helpers.it("still reports the work done around the dialog, without the wait", function()
		with_capture(function(Logger, clock, captured)
			local function work_then_dialog()
				clock.now = clock.now + REAL_STALL_MS * NS_PER_MS
				Logger.run_modal(function() clock.now = clock.now + DIALOG_WAIT_MS * NS_PER_MS end)
			end
			hs.timer.doAfter(0, work_then_dialog)
			helpers.assert_eq(count_lines(captured, "held the main thread for 1500 ms"), 1,
				"only the 1.5 s of real work is a hold")
		end)
	end)

	helpers.it("returns the call's results and counts the wait when it raises", function()
		with_capture(function(Logger, clock, captured)
			local a, b = Logger.run_modal(function(x, y) return y, x end, 1, 2)
			helpers.assert_eq(a, 2)
			helpers.assert_eq(b, 1)
			local function raising_dialog()
				local ok = pcall(Logger.run_modal, function()
					clock.now = clock.now + DIALOG_WAIT_MS * NS_PER_MS
					error("dialog failed", 0)
				end)
				helpers.assert_true(not ok, "the failure must propagate")
			end
			hs.timer.doAfter(0, raising_dialog)
			helpers.assert_eq(count_lines(captured, "Uncaught error"), 0,
				"the callback body itself must have run to completion")
			helpers.assert_eq(count_lines(captured, "held the main thread"), 0)
		end)
	end)

	helpers.it("is applied by every blocking dialog wrapper of dialog_util", function()
		with_capture(function(_, clock, captured)
			local hs = _G.hs
			local function wait() clock.now = clock.now + DIALOG_WAIT_MS * NS_PER_MS end
			hs.dialog = hs.dialog or {}
			hs.dialog.blockAlert = function() wait(); return "OK" end
			hs.dialog.textPrompt = function() wait(); return "OK", "text" end
			hs.osascript = hs.osascript or {}
			hs.osascript.applescript = function() wait(); return true, "", "" end
			local DialogUtil = require("infra.dialog_util")
			local callers = {
				block_alert = function() DialogUtil.block_alert("t", "m") end,
				text_prompt = function() DialogUtil.text_prompt("t", "m") end,
				choose = function() DialogUtil.choose("t", "m", { "a" }, "cancel", "ok") end,
				choose_application = function() DialogUtil.choose_application("m", "t") end,
			}
			for name, call in pairs(callers) do
				hs.timer.doAfter(0, call)
				helpers.assert_eq(count_lines(captured, "held the main thread"), 0,
					name .. " waits for the user and must not be reported as a stall")
			end
		end)
	end)
end)
