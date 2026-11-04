--- tests/unit/modules/keystats/context_tracker/test_context_tracker_ax_value_coalescing.lua

--- ==============================================================================
--- MODULE: Context Tracker AXValue Read Coalescing
--- DESCRIPTION:
--- Every keystroke changes the watched field's value. Reading the whole AXValue
--- at each one is a synchronous call into the typing application on the main
--- thread that also serves the event taps (issue #99 follow-up, ax-value-burst).
--- A change next to a keystroke is typing: it must cost no read, and one burst
--- of them costs one read, taken after typing paused. A change away from any
--- keystroke is still read at once so the autocorrect detection keeps working.
--- ==============================================================================

local helpers = require("tests.helpers")

local TYPING_WINDOW_MS = 100

--- Builds a tracker watching one element whose reads are counted.
--- @return table fixture
local function make_fixture()
	local reads = { count = 0, value = "" }
	local element = {
		attributeValue = function(_, attribute)
			if attribute ~= "AXValue" then return nil end
			reads.count = reads.count + 1
			return reads.value
		end,
	}
	local callback = nil
	local observer = {
		addWatcher = function(self) return self end,
		removeWatcher = function(self) return self end,
		callback = function(self, fn) callback = fn; return self end,
		start = function(self) return self end,
		stop = function(self) return self end,
	}
	-- Timers of an earlier scenario must not fire in this one.
	for index = #hs.timer.__timers, 1, -1 do hs.timer.__timers[index] = nil end
	-- The scheduler captured the previous scenario's native timers at require time.
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.keystats.context_tracker"] = nil
	local tracker = helpers.load_with_stubs("modules.keystats.context_tracker", {
		axuielement = {
			observer = { new = function() return observer end },
			applicationElement = function()
				return {
					attributeValue = function(_, attribute)
						if attribute == "AXFocusedUIElement" then return element end
						return nil
					end,
				}
			end,
		},
	})
	local logged = {}
	local state = {
		is_enabled = true, is_secure_field = false, active_app_name = "Editor",
		ax_observer = nil, last_time = 0,
	}
	helpers.assert_true(tracker.init(state, {
		flush_buffer = function() return true end,
		append_log = function(entry) logged[#logged + 1] = entry; return true end,
	}, function() return false end))
	helpers.assert_true(tracker.update_ax_observer(4242))
	helpers.assert_type(callback, "function")
	reads.count = 0
	return {
		tracker = tracker, state = state, reads = reads, logged = logged,
		changed = function() callback(observer, element, "AXValueChanged", nil) end,
	}
end

--- Fires the timers armed right now, once. The stub's own fire-all also fires a
--- timer armed by a callback in the same pass, which never happens at one instant.
local function fire_pending()
	local armed = {}
	for _, timer in ipairs(hs.timer.__timers) do
		if timer.running then armed[#armed + 1] = timer end
	end
	for _, timer in ipairs(armed) do
		if timer.running then timer:fire() end
	end
end

--- Runs a scenario with a controllable host clock (milliseconds).
--- @param body function body(set_now_ms)
local function with_clock(body)
	local now_ms = 10000
	local saved = hs.timer.absoluteTime
	hs.timer.absoluteTime = function() return now_ms * 1000000 end
	local ok, err = pcall(body, function(ms) now_ms = ms end)
	hs.timer.absoluteTime = saved
	if not ok then error(err, 0) end
end

helpers.describe("context tracker: AXValue reads while typing (ax-value-burst)", function()
	helpers.it("reads nothing at a change next to a keystroke and once after the burst", function()
		local fixture = make_fixture()
		with_clock(function(set_now_ms)
			for step = 1, 20 do
				set_now_ms(10000 + step * 10)
				fixture.state.last_time = 10000 + step * 10
				fixture.changed()
			end
			helpers.assert_eq(fixture.reads.count, 0,
				"twenty keystrokes must not read the whole field once")
			-- Typing stops; the pending refresh finds the field idle.
			set_now_ms(10000 + 20 * 10 + TYPING_WINDOW_MS + 50)
			fire_pending()
			helpers.assert_eq(fixture.reads.count, 1, "one read refreshes the baseline after the burst")
		end)
	end)

	helpers.it("waits while keystrokes continue instead of reading mid-burst", function()
		local fixture = make_fixture()
		with_clock(function(set_now_ms)
			fixture.state.last_time = 10000
			set_now_ms(10010)
			fixture.changed()
			-- The timer fires, but a key arrived since: no read yet.
			set_now_ms(10090)
			fixture.state.last_time = 10080
			fire_pending()
			helpers.assert_eq(fixture.reads.count, 0)
			set_now_ms(10300)
			fire_pending()
			helpers.assert_eq(fixture.reads.count, 1)
		end)
	end)

	helpers.it("still reads a change away from any keystroke and detects the substitution", function()
		local fixture = make_fixture()
		with_clock(function(set_now_ms)
			fixture.reads.value = "hello world"
			set_now_ms(10000)
			fixture.state.last_time = 9000
			fixture.changed()
			helpers.assert_eq(fixture.reads.count, 1, "a change with no keystroke nearby is read at once")
			fixture.reads.value = "hello world, and then some"
			set_now_ms(12000)
			fixture.changed()
			helpers.assert_eq(fixture.reads.count, 2)
			local kinds = {}
			for _, entry in ipairs(fixture.logged) do kinds[#kinds + 1] = entry.type end
			helpers.assert_true(table.concat(kinds, ","):find("sys_autocorrect", 1, true) ~= nil,
				"a large jump away from typing is still logged as a native substitution")
		end)
	end)
end)
