--- tests/unit/modules/gestures/test_search_web_clipboard_restore_retry.lua

--- ==============================================================================
--- MODULE: Gesture search clipboard restore retry
--- DESCRIPTION:
--- Executes the production search_web closure. A writeAllData(false) restore must
--- retain the first user snapshot and arm a logged retry instead of releasing
--- ownership and letting the next gesture snapshot copied selection text.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("search_web: native clipboard refusal retains ownership", function()
	helpers.it("retries writeAllData(false) with the original all-type snapshot", function()
		for name in pairs(package.loaded) do
			if type(name) == "string" and name:match("^modules%.gestures%.actions") then
				package.loaded[name] = nil
			end
		end
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub

		local restores = {}
		local snapshots = 0
		local copies = 0
		local original = {
			["public.utf8-plain-text"] = "ORIGINAL",
			["public.html"] = "<b>ORIGINAL</b>",
		}
		hs_stub.pasteboard.readAllData = function() snapshots = snapshots + 1; return original end
		hs_stub.pasteboard.clearContents = function() end
		hs_stub.pasteboard.getContents = function() return "selected words" end
		hs_stub.pasteboard.writeAllData = function(value)
			restores[#restores + 1] = value
			return #restores > 1
		end
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_log, message, ...)
			errors[#errors + 1] = string.format(message, ...)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.timings"] = {
			sec = function() return 0.2 end,
		}
		package.loaded["adapters.synthetic_input"] = setmetatable({
			emit_key_stroke = function() copies = copies + 1; return true end,
		}, { __index = function() return function() return true end end })

		local actions = require("modules.gestures.actions")
		actions.init({ action_params = {} })
		helpers.assert_true(actions.set_action_parameter(
			"tap_3", "search_web", "https://example.test/?q=%s"))
		helpers.assert_true(actions.execute_single("search_web", "tap_3"))
		helpers.assert_true(actions.execute_single("search_web", "tap_3"))
		helpers.assert_eq(snapshots, 1,
			"an overlapping gesture must not replace the first all-type snapshot")
		helpers.assert_eq(copies, 1,
			"an overlapping gesture must not post a second Cmd+C")

		local capture_timer = hs_stub.timer.__timers[#hs_stub.timer.__timers]
		helpers.assert_not_nil(capture_timer)
		capture_timer:fire()
		helpers.assert_eq(#restores, 1)
		helpers.assert_true(restores[1] == original)
		helpers.assert_true(#errors > 0,
			"timer-callback refusal must reach the file logger")

		local retry_timer = hs_stub.timer.__timers[#hs_stub.timer.__timers]
		helpers.assert_true(retry_timer ~= capture_timer,
			"restore refusal must arm a retained retry")
		retry_timer:fire()
		helpers.assert_eq(#restores, 2)
		helpers.assert_true(restores[2] == original,
			"retry must use the first user snapshot, not the copied selection")
	end)

	helpers.it("timer refusal restores before posting Cmd+C", function()
		for name in pairs(package.loaded) do
			if type(name) == "string" and name:match("^modules%.gestures%.actions") then
				package.loaded[name] = nil
			end
		end
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub
		local original = { ["public.png"] = "PNG" }
		local restored = nil
		hs_stub.pasteboard.readAllData = function() return original end
		hs_stub.pasteboard.clearContents = function() end
		hs_stub.pasteboard.writeAllData = function(value)
			restored = value
			return true
		end
		hs_stub.timer.doAfter = function() return nil end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.timings"] = { sec = function() return 0.2 end }
		local copies = 0
		package.loaded["adapters.synthetic_input"] = setmetatable({
			emit_key_stroke = function() copies = copies + 1; return true end,
			defer_after_callback = function() return false end,
		}, { __index = function() return function() return true end end })

		local actions = require("modules.gestures.actions")
		actions.init({ action_params = {} })
		helpers.assert_true(actions.set_action_parameter(
			"tap_3", "search_web", "https://example.test/?q=%s"))
		helpers.assert_true(actions.execute_single("search_web", "tap_3"))
		helpers.assert_eq(copies, 0,
			"Cmd+C must not be posted unless the capture/restore callback is retained")
		helpers.assert_true(restored == original,
			"timer refusal must restore the exact all-type snapshot synchronously")
	end)

	helpers.it("Cmd+C refusal restores before any selection is read", function()
		for name in pairs(package.loaded) do
			if type(name) == "string" and name:match("^modules%.gestures%.actions") then
				package.loaded[name] = nil
			end
		end
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub
		local original = { ["public.html"] = "<b>ORIGINAL</b>" }
		local restored = nil
		local selection_reads = 0
		hs_stub.pasteboard.readAllData = function() return original end
		hs_stub.pasteboard.clearContents = function() end
		hs_stub.pasteboard.getContents = function()
			selection_reads = selection_reads + 1
			return "stale"
		end
		hs_stub.pasteboard.writeAllData = function(value)
			restored = value
			return true
		end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.timings"] = { sec = function() return 0.2 end }
		package.loaded["adapters.synthetic_input"] = setmetatable({
			emit_key_stroke = function() return false end,
		}, { __index = function() return function() return true end end })

		local actions = require("modules.gestures.actions")
		actions.init({ action_params = {} })
		helpers.assert_true(actions.set_action_parameter(
			"tap_3", "search_web", "https://example.test/?q=%s"))
		helpers.assert_true(actions.execute_single("search_web", "tap_3"))
		helpers.assert_true(restored == original)
		helpers.assert_eq(selection_reads, 0,
			"a refused Copy dispatch must cancel the capture callback")
	end)
end)
