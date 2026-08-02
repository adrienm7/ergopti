--- tests/unit/modules/keylogger/test_app_time_interval_boundaries.lua

--- ============================================================================
--- MODULE: Regression — foreground app time interval boundaries
--- DESCRIPTION:
--- App time is persisted only when a foreground interval closes. These source
--- assertions pin the two lifecycle boundaries that previously lost or misdated
--- whole work blocks: engine shutdown and a foreground interval spanning
--- midnight.
--- ============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function source(selector)
	local body = helpers.read_driver_source(selector)
	return body
end

helpers.describe("app-time interval lifecycle boundaries", function()
	helpers.it("closes the current foreground interval before keylogger shutdown", function()
		local src = source("local function ensure_browser_window_filter") -- modules/keylogger/init.lua
		local stop_pos = assert(src:find("function M.stop()", 1, true))
		local close_pos = assert(src:find("pcall(ContextTracker.close_active_app)", stop_pos, true))
		local flush_pos = assert(src:find("LogManager.flush_buffer()", close_pos, true))
		helpers.assert_true(close_pos < flush_pos,
			"the app-time interval must be appended before final log draining")
	end)

	helpers.it("splits an open foreground interval before midnight rollover", function()
		local src = source("local function poll_mouse_distance") -- modules/keylogger/watchers.lua
		local rotation_pos = assert(src:find("Midnight rotation: archiving", 1, true))
		local split_pos = assert(src:find("tracker.split_active_app_at_midnight, _current_day", rotation_pos, true))
		local flush_pos = assert(src:find("LogManager.flush_buffer()", split_pos, true))
		helpers.assert_true(split_pos < flush_pos,
			"the old-day interval must be written before today's log is drained")
	end)

	helpers.it("keeps shutdown and midnight closures out of the app-switch graph", function()
		local src = source("local function update_secure_field_state") -- modules/keylogger/context_tracker.lua
		helpers.assert_true(src:find("_log_manager.log_app_switch(_state.active_app_name, nil, duration_ms)", 1, true) ~= nil,
			"shutdown must persist next_app as nil")
		helpers.assert_true(src:find("previous_date .. \" 23:59:59.999\"", 1, true) ~= nil,
			"midnight must timestamp the interval on the previous date")
	end)
end)
