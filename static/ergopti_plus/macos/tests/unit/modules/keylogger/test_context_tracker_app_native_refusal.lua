--- tests/unit/modules/keylogger/test_context_tracker_app_native_refusal.lua

--- ==============================================================================
--- MODULE: Regression — application metadata refusal cannot abort a switch
--- DESCRIPTION:
--- A terminating application may raise from bundleID(), path(), or pid(). The
--- application watcher must still close the previous interval, publish a safe
--- new context, and retarget or tear down the AX observer as appropriate.
--- ==============================================================================

local helpers = require("tests.helpers")

local ACTIVATED = 1
local NOW_NS = 7500000000
local NOT_PAUSED = function() return false end





-- =====================================
-- =====================================
-- ======= 1/ Scenario Harness =========
-- =====================================
-- =====================================

--- Drives one application switch whose selected native metadata reader raises.
--- @param failing_reader string One of bundleID, path, or pid.
--- @return table snapshot Observable transaction results.
local function drive_refusal(failing_reader)
	local saved_logger = package.loaded["infra.logger"]
	local saved_detector = package.loaded["adapters.secure_field_detector"]
	local warnings = {}
	local logger = helpers.make_logger_stub()
	logger.warn = function(_module, message, ...)
		warnings[#warnings + 1] = string.format(message, ...)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["adapters.secure_field_detector"] = nil

	local snapshot
	local ok, err = xpcall(function()
		local calls = { bundleID = 0, path = 0, pid = 0 }
		local old_observer_stops = 0
		local new_observer_starts = 0
		local observer_pid = nil
		local app_element_pid = nil
		local switch_rows = {}
		local new_observer = {
			addWatcher = function() end,
			callback = function() end,
			start = function() new_observer_starts = new_observer_starts + 1 end,
			stop = function() end,
		}
		local app_element = {
			attributeValue = function() return nil end,
		}
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function() return NOW_NS end },
			application = {
				watcher = { activated = ACTIVATED },
				frontmostApplication = function() return nil end,
			},
			window = { focusedWindow = function() return nil end },
			axuielement = {
				observer = {
					new = function(pid)
						observer_pid = pid
						return new_observer
					end,
				},
				applicationElement = function(pid)
					app_element_pid = pid
					return app_element
				end,
			},
		})
		local state = {
			active_app_name = "Previous",
			active_app_start = 1000,
			active_app_bundle = "com.example.Previous",
			active_app_path = "/Applications/Previous.app",
			active_app_pid = 7,
			ax_observer = {
				stop = function() old_observer_stops = old_observer_stops + 1 end,
			},
		}
		helpers.assert_true(tracker.init(state, {
			flush_buffer = function() return true end,
			log_app_switch = function(previous_app, next_app, duration_ms)
				switch_rows[#switch_rows + 1] = {
					previous_app = previous_app,
					next_app = next_app,
					duration_ms = duration_ms,
				}
			end,
		}, NOT_PAUSED))

		local function native_value(reader, value)
			return function()
				calls[reader] = calls[reader] + 1
				if reader == failing_reader then
					error("dying process " .. reader .. " access", 0)
				end
				return value
			end
		end
		local app = {
			bundleID = native_value("bundleID", "com.example.Next"),
			path = native_value("path", "/Applications/Next.app"),
			pid = native_value("pid", 4242),
		}
		local callback_ok, callback_err = pcall(
			tracker.app_watcher_cb, "Next", ACTIVATED, app)

		snapshot = {
			callback_ok = callback_ok,
			callback_err = callback_err,
			calls = calls,
			warnings = warnings,
			state = state,
			switch_rows = switch_rows,
			old_observer_stops = old_observer_stops,
			new_observer_starts = new_observer_starts,
			observer_pid = observer_pid,
			app_element_pid = app_element_pid,
		}
	end, debug.traceback)

	package.loaded["modules.keylogger.context_tracker"] = nil
	package.loaded["adapters.secure_field_detector"] = saved_detector
	package.loaded["infra.logger"] = saved_logger
	if not ok then error(err, 0) end
	return snapshot
end





-- =====================================================
-- =====================================================
-- ======= 2/ Native Refusal Transaction ===============
-- =====================================================
-- =====================================================

helpers.describe("keylogger/context_tracker native app metadata refusals (HS-044)", function()
	for _, reader in ipairs({ "bundleID", "path", "pid" }) do
		helpers.it(reader .. " refusal cannot abort the application switch", function()
			local result = drive_refusal(reader)
			helpers.assert_true(result.callback_ok,
				reader .. " refusal escaped the watcher callback: " .. tostring(result.callback_err))
			helpers.assert_eq(result.calls.bundleID, 1)
			helpers.assert_eq(result.calls.path, 1)
			helpers.assert_eq(result.calls.pid, 1)

			helpers.assert_eq(#result.switch_rows, 1,
				"the previous foreground interval must be closed exactly once")
			helpers.assert_eq(result.switch_rows[1].previous_app, "Previous")
			helpers.assert_eq(result.switch_rows[1].next_app, "Next")
			helpers.assert_eq(result.switch_rows[1].duration_ms, 6500)

			helpers.assert_eq(result.state.active_app_name, "Next")
			helpers.assert_eq(result.state.active_app_start, 7500)
			local expected_bundle = "com.example.Next"
			local expected_path = "/Applications/Next.app"
			local expected_pid = 4242
			if reader == "bundleID" then expected_bundle = nil end
			if reader == "path" then expected_path = nil end
			if reader == "pid" then expected_pid = nil end
			helpers.assert_eq(result.state.active_app_bundle, expected_bundle)
			helpers.assert_eq(result.state.active_app_path, expected_path)
			helpers.assert_eq(result.state.active_app_pid, expected_pid)

			helpers.assert_eq(#result.warnings, 1,
				"each rejected native read must produce one visible diagnostic")
			helpers.assert_true(result.warnings[1]:find(reader .. "()", 1, true) ~= nil)
			helpers.assert_true(
				result.warnings[1]:find("dying process " .. reader .. " access", 1, true) ~= nil)

			helpers.assert_eq(result.old_observer_stops, 1,
				"the observer for the previous app must always be retired")
		if reader == "pid" then
			helpers.assert_nil(result.observer_pid)
			helpers.assert_nil(result.app_element_pid)
			helpers.assert_eq(result.new_observer_starts, 0)
			helpers.assert_nil(result.state.ax_observer)
		else
			helpers.assert_eq(result.observer_pid, 4242)
			helpers.assert_eq(result.app_element_pid, 4242)
			helpers.assert_eq(result.new_observer_starts, 1)
		end
		end)
	end
end)
