--- tests/unit/modules/keystats/context_tracker/test_context_tracker_ax_own_process.lua

--- ==============================================================================
--- MODULE: Context Tracker — Ergopti's own windows
--- DESCRIPTION:
--- hs.axuielement refuses an application element for the runtime's own process,
--- so focusing an Ergopti menu, dialog or page logged "Accessibility observer
--- setup failed" as a WARNING on every visit (field ledger L31). The maintainer
--- decided that typing there counts: the event tap still counts it, and only the
--- secure-field and autocorrect hints are unavailable. That refusal is an INFO
--- line naming the PID; another application's refusal stays a WARNING
--- (ax-own-process-is-info).
--- ==============================================================================

local helpers = require("tests.helpers")

local OWN_PID = 4242

--- Attaches an observer to `pid` while every application element is refused.
--- @param pid number The PID handed to update_ax_observer.
--- @return boolean attached Result of update_ax_observer.
--- @return string rendered Every log line written meanwhile.
--- @return number stops Observer stops (the rollback).
local function attach_refused(pid)
	package.loaded["modules.keystats.context_tracker"] = nil
	local stops = 0
	local observer = {
		addWatcher = function(self) return self end,
		removeWatcher = function(self) return self end,
		callback = function(self) return self end,
		start = function(self) return self end,
		stop = function(self) stops = stops + 1; return self end,
	}
	local tracker = helpers.load_with_stubs("modules.keystats.context_tracker", {
		axuielement = {
			observer = { new = function() return observer end },
			applicationElement = function() return nil end,
		},
		processInfo = { processID = OWN_PID },
	})
	local core_state = { is_enabled = true, is_secure_field = true, active_app_name = "ErgoptiPlus", ax_observer = nil }
	helpers.assert_true(tracker.init(core_state, {
		flush_buffer = function() return true end,
		append_log = function() return true end,
	}, function() return false end))
	local lines = {}
	local Logger = require("infra.logger")
	helpers.admit_logger_privacy(Logger)
	Logger.set_level("DEBUG")
	Logger.set_sink(function(line) lines[#lines + 1] = line end)
	local ok, attached = pcall(tracker.update_ax_observer, pid)
	Logger.set_sink(nil)
	if not ok then error(attached, 0) end
	return attached, table.concat(lines, "\n"), stops
end

helpers.describe("context tracker: Ergopti's own windows (ax-own-process-is-info)", function()
	helpers.it("logs the runtime's own refused element at INFO and rolls the observer back", function()
		local attached, rendered, stops = attach_refused(OWN_PID)
		helpers.assert_eq(attached, false, "no observer is attached to the runtime itself")
		helpers.assert_eq(stops, 1, "the candidate observer is still rolled back")
		helpers.assert_contains(rendered, "[INFO]")
		helpers.assert_contains(rendered, "PID " .. OWN_PID)
		helpers.assert_contains(rendered, "counted from the event tap")
		helpers.assert_true(rendered:find("[WARNING]", 1, true) == nil,
			"the runtime's own windows are not a setup fault")
	end)

	helpers.it("keeps another application's refused element a WARNING", function()
		local attached, rendered = attach_refused(OWN_PID + 1)
		helpers.assert_eq(attached, false)
		helpers.assert_contains(rendered, "[WARNING]")
		helpers.assert_contains(rendered, "failed to get AX application element for PID " .. (OWN_PID + 1))
	end)
end)
