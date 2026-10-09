--- tests/unit/modules/keylogger/test_context_tracker_app_switch_seals_buffer.lua

--- ==============================================================================
--- MODULE: Regression — application switches seal the open typing context
--- DESCRIPTION:
--- A separator-free typing run captures its application and title on the first
--- key. The application watcher must detach that run before publishing the next
--- foreground context, otherwise later keys are appended to the previous app's
--- row until some unrelated separator finally flushes it.
--- ==============================================================================

local helpers = require("tests.helpers")

local ACTIVATED = 1
local NOW_NS = 9000000000





-- =====================================
-- =====================================
-- ======= 1/ Scenario Harness =========
-- =====================================
-- =====================================

--- Runs one activation against a LogManager-shaped in-memory outbox.
--- @param options table Scenario state and destination application.
--- @return table snapshot Observable calls, rows, and final state.
local function drive_activation(options)
	local saved_detector = package.loaded["adapters.secure_field_detector"]
	local saved_tracker = package.loaded["modules.keylogger.context_tracker"]
	local rows = {}
	local order = {}
	local flush_calls = 0
	local switch_calls = 0
	local state = {
		active_app_name = options.active_app_name or "App A",
		active_app_start = 1000,
		active_app_bundle = "com.example.a",
		active_app_path = "/Applications/App A.app",
		active_app_pid = 101,
		active_win_title = "Document A",
		session_app_name = "App A",
		session_win_title = "Document A",
		buffer_events = options.buffer_events or {},
		buffer_text = options.buffer_text or "",
		rich_chunks = options.rich_chunks or {},
		last_time = 8000,
		last_flush_time = 0,
		pending_keyup = { [12] = true },
		session_mouse_clicks = options.mouse_clicks or 0,
		session_mouse_scrolls = options.mouse_scrolls or 0,
		mouse_distance_px = options.mouse_distance_px or 0,
	}

	local result
	local ok, err = xpcall(function()
		package.loaded["adapters.secure_field_detector"] = {
			refresh = function() end,
			isSecureField = function() return false end,
			isSecureApp = function() return false end,
		}
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function() return NOW_NS end },
			application = {
				watcher = { activated = ACTIVATED },
				frontmostApplication = function() return nil end,
			},
			window = {
				focusedWindow = function()
					return {
						title = function() return "Document B" end,
						isFullScreen = function() return false end,
					}
				end,
			},
			axuielement = {
				observer = { new = function() return nil end },
				windowElement = function() return nil end,
			},
		})

		local log_manager = {}
		function log_manager.flush_buffer()
			flush_calls = flush_calls + 1
			order[#order + 1] = "flush"
			local has_data = #state.buffer_events > 0
				or state.session_mouse_clicks > 0
				or state.session_mouse_scrolls > 0
			if not has_data then return end
			rows[#rows + 1] = {
				type = "typing",
				app = state.session_app_name,
				title = state.session_win_title,
				text = state.buffer_text,
				mouse_clicks = state.session_mouse_clicks,
				active_app_at_flush = state.active_app_name,
			}
			state.buffer_events = {}
			state.buffer_text = ""
			state.rich_chunks = {}
			state.last_time = 0
			state.pending_keyup = {}
			state.session_mouse_clicks = 0
			state.session_mouse_scrolls = 0
			state.mouse_distance_px = 0
			return true
		end
		function log_manager.log_app_switch(previous_app, next_app, duration_ms)
			switch_calls = switch_calls + 1
			order[#order + 1] = "switch"
			rows[#rows + 1] = {
				type = "app_switch",
				previous_app = previous_app,
				next_app = next_app,
				duration_ms = duration_ms,
			}
		end
		function log_manager.append_log() return true end

		helpers.assert_true(tracker.init(state, log_manager, function() return false end))
		tracker.app_watcher_cb(options.next_app_name or "App B", ACTIVATED, {
			bundleID = function() return "com.example.b" end,
			path = function() return "/Applications/App B.app" end,
			pid = function() return 202 end,
		})

		result = {
			state = state,
			rows = rows,
			order = order,
			flush_calls = flush_calls,
			switch_calls = switch_calls,
		}
	end, debug.traceback)

	package.loaded["modules.keylogger.context_tracker"] = saved_tracker
	package.loaded["adapters.secure_field_detector"] = saved_detector
	if not ok then error(err, 0) end
	return result
end





-- ==================================================
-- ==================================================
-- ======= 2/ Application Boundary Regression =======
-- ==================================================
-- ==================================================

helpers.describe("keylogger/context_tracker application boundary (HS-120)", function()
	helpers.it("seals an open typing run before the destination context is published", function()
		local result = drive_activation({
			buffer_events = { { "a", 25, {} }, { "b", 30, {} } },
			buffer_text = "ab",
			rich_chunks = { { type = "text", text = "ab" } },
		})

		helpers.assert_eq(result.flush_calls, 1,
			"a real application transition must seal the previous typing owner")
		helpers.assert_eq(result.switch_calls, 1)
		helpers.assert_eq(table.concat(result.order, ","), "flush,switch",
			"the typing snapshot must enter the FIFO before the app-switch row")
		helpers.assert_eq(#result.rows, 2)
		helpers.assert_eq(result.rows[1].type, "typing")
		helpers.assert_eq(result.rows[1].app, "App A")
		helpers.assert_eq(result.rows[1].title, "Document A")
		helpers.assert_eq(result.rows[1].text, "ab")
		helpers.assert_eq(result.rows[1].active_app_at_flush, "App A",
			"the old buffer must detach before active_app_name changes")
		helpers.assert_eq(result.rows[2].type, "app_switch")
		helpers.assert_eq(result.rows[2].previous_app, "App A")
		helpers.assert_eq(result.rows[2].next_app, "App B")
		helpers.assert_eq(result.state.active_app_name, "App B")
		helpers.assert_eq(#result.state.buffer_events, 0)
	end)

	helpers.it("also seals mouse-only context instead of guarding on key events", function()
		local result = drive_activation({
			mouse_clicks = 3,
			mouse_scrolls = 2,
			mouse_distance_px = 450,
		})

		helpers.assert_eq(result.flush_calls, 1)
		helpers.assert_eq(result.rows[1].type, "typing")
		helpers.assert_eq(result.rows[1].app, "App A")
		helpers.assert_eq(result.rows[1].mouse_clicks, 3)
		helpers.assert_eq(result.state.session_mouse_clicks, 0)
		helpers.assert_eq(result.state.session_mouse_scrolls, 0)
	end)

	helpers.it("does not split a duplicate activation of the same application", function()
		local result = drive_activation({
			next_app_name = "App A",
			buffer_events = { { "a", 25, {} } },
			buffer_text = "a",
			rich_chunks = { { type = "text", text = "a" } },
		})

		helpers.assert_eq(result.flush_calls, 0,
			"same-app activation noise must not fragment one typing run")
		helpers.assert_eq(result.switch_calls, 0)
		helpers.assert_eq(#result.state.buffer_events, 1)
	end)
end)
