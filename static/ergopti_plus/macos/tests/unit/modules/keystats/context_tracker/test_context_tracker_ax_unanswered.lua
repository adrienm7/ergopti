--- tests/unit/modules/keystats/context_tracker/test_context_tracker_ax_unanswered.lua

--- ==============================================================================
--- MODULE: Context Tracker — an application that does not answer Accessibility
--- DESCRIPTION:
--- hs.axuielement raises "Messaging failed" (kAXErrorCannotComplete) when the
--- application does not answer, as one still launching does. Issue #99 logged
--- four such WARNINGs, each with a fifteen-line traceback, for applications that
--- were simply not ready. That state is the application's, so it is an INFO
--- line naming the PID; any other setup failure stays a WARNING
--- (ax-unanswered-is-info).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Attaches an observer whose focus watcher raises `message`.
--- @param message string Error raised by addWatcher.
--- @return boolean attached Result of update_ax_observer.
--- @return string rendered Every log line written meanwhile.
local function attach_with_add_error(message)
	package.loaded["modules.keystats.context_tracker"] = nil
	local stops = 0
	local observer = {
		addWatcher = function() error(message, 0) end,
		removeWatcher = function(self) return self end,
		callback = function(self) return self end,
		start = function(self) return self end,
		stop = function(self) stops = stops + 1; return self end,
	}
	local tracker = helpers.load_with_stubs("modules.keystats.context_tracker", {
		axuielement = {
			observer = { new = function() return observer end },
			applicationElement = function() return { attributeValue = function() return nil end } end,
		},
	})
	local core_state = { is_enabled = true, is_secure_field = true, active_app_name = "Launching", ax_observer = nil }
	helpers.assert_true(tracker.init(core_state, {
		flush_buffer = function() return true end,
		append_log = function() return true end,
	}, function() return false end))
	local lines = {}
	local Logger = require("infra.logger")
	helpers.admit_logger_privacy(Logger)
	Logger.set_level("DEBUG")
	Logger.set_sink(function(line) lines[#lines + 1] = line end)
	local ok, attached = pcall(tracker.update_ax_observer, 95163)
	Logger.set_sink(nil)
	if not ok then error(attached, 0) end
	helpers.assert_eq(stops, 1, "the rejected candidate must still be rolled back")
	return attached, table.concat(lines, "\n")
end

helpers.describe("context tracker: an unanswered Accessibility request (ax-unanswered-is-info)", function()
	helpers.it("logs Messaging failed at INFO with the PID and no traceback", function()
		local attached, rendered = attach_with_add_error(
			"context_tracker.lua:613: Messaging failed\nstack traceback:\n\t[C]: in method 'addWatcher'")
		helpers.assert_eq(attached, false, "the observer is still not attached")
		helpers.assert_contains(rendered, "[INFO]")
		helpers.assert_contains(rendered, "PID 95163")
		helpers.assert_contains(rendered, "did not answer Accessibility")
		helpers.assert_true(rendered:find("[WARNING]", 1, true) == nil,
			"an application that is not ready is not a driver fault")
		helpers.assert_true(rendered:find("stack traceback", 1, true) == nil,
			"the traceback names only the driver line that asked")
	end)

	helpers.it("keeps any other setup failure a WARNING", function()
		local attached, rendered = attach_with_add_error("observer refused: invalid element")
		helpers.assert_eq(attached, false)
		helpers.assert_contains(rendered, "[WARNING]")
		helpers.assert_contains(rendered, "Accessibility observer setup failed: observer refused: invalid element")
	end)
end)
