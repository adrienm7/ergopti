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
	local body, err = helpers.read_driver_unit(selector)
	helpers.assert_not_nil(body, err)
	return body
end

helpers.describe("app-time interval lifecycle boundaries", function()
	helpers.it("closes the current foreground interval before keylogger shutdown", function()
		local src = source("local function ensure_browser_window_filter") -- modules/keylogger/init.lua
		local teardown_pos = assert(src:find("local function teardown_runtime()", 1, true))
		local interval_step_pos = assert(src:find(
			"name = \"active-app-interval\"", teardown_pos, true))
		local close_pos = assert(src:find(
			"ContextTracker.close_active_app()", interval_step_pos, true))
		local flush_step_pos = assert(src:find(
			"name = \"buffer-flush\"", close_pos, true))
		local flush_pos = assert(src:find(
			"LogManager.flush_buffer()", flush_step_pos, true))
		local transaction_pos = assert(src:find(
			"return TeardownTransaction.run(_teardown_state, steps)", flush_pos, true))
		local stop_pos = assert(src:find("function M.stop()", transaction_pos, true))
		local stop_teardown_pos = assert(src:find(
			"local complete = teardown_runtime()", stop_pos, true))

		helpers.assert_true(interval_step_pos < close_pos
			and close_pos < flush_step_pos and flush_step_pos < flush_pos,
			"the ordered teardown transaction must append the foreground interval "
			.. "before final log draining")
		helpers.assert_true(transaction_pos < stop_pos and stop_pos < stop_teardown_pos,
			"M.stop() must execute the transaction that owns both ordered boundaries")
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
