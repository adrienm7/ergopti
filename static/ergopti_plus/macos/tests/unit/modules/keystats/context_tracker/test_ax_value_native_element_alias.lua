--- tests/unit/modules/keystats/context_tracker/test_ax_value_native_element_alias.lua

--- ==============================================================================
--- MODULE: AXValue Baseline Native Element Equality
--- DESCRIPTION:
--- Drives real observer admission, deferred baseline reads and the autocorrect
--- writer with distinct wrappers for one native AX element. The established
--- public runtime owns dependencies and native retirement even when a causal
--- assertion fails before the remainder of its test body.
--- ==============================================================================

local helpers = require("tests.helpers")
local Native = require("tests.support.modules.keystats.context_tracker.ax_native_callback_fixture")

local WINDOW_MS = 100




-- ===========================================
-- ===========================================
-- ======= 1/ Scoped Native Baseline Owner ===
-- ===========================================
-- ===========================================

--- Owns only extra clock, value-read and timer observation ports.
--- @param callback function Receives native alias and baseline controls.
--- @return ... results Original callback results.
local function with_baseline(callback)
	return Native.with_runtime(function(runtime)
		local hs, field = runtime.hs, runtime.ax_native.field
		local clock, timer_new, attribute = hs.timer.absoluteTime, hs.timer.new, field.attributeValue
		local scheduler = assert(package.loaded["adapters.timer_scheduler"])
		local now, reads, timers = clock() / 1000000, { count = 0 }, {}
		hs.timer.absoluteTime = function() return now * 1000000 end
		hs.timer.new = function(delay, work)
			local timer = timer_new(delay, work)
			if delay == WINDOW_MS / 1000 then timers[#timers + 1] = timer end
			return timer
		end
		field.attributeValue = function(self, name)
			if name == "AXValue" then reads.count = reads.count + 1 end
			return attribute(self, name)
		end
		local fixture = { runtime = runtime, field = field, reads = reads,
			timers = timers, original_clock = clock, original_timer_new = timer_new,
			original_native_attribute = runtime.ax_native.original_attribute }
		function fixture.time(ms) now = ms end
		function fixture.changed(element)
			runtime.ax_native.emit("AXValueChanged", nil, element or fixture.alias)
		end
		function fixture.prime()
			now = 10000
			runtime.state.last_time = 9000
			runtime.native.field_value = "old"
			fixture.changed(field)
			helpers.assert_eq(reads.count, 1, "The current native observer must reach the actual value reader")
			reads.count = 0
		end
		function fixture.fire_pending()
			local pending = {}
			for _, timer in ipairs(timers) do
				if timer.running then pending[#pending + 1] = timer end
			end
			for _, timer in ipairs(pending) do if timer.running then timer:fire() end end
		end
		function fixture.typing(value)
			now = 10010
			runtime.state.last_time, runtime.native.field_value = now, value
			fixture.changed()
			helpers.assert_eq(reads.count, 0, "Typing must not synchronously read the whole field")
			helpers.assert_eq(#timers, 1, "The admitted native alias must acquire exactly one baseline timer")
		end
		local values = table.pack(xpcall(function()
			fixture.alias = runtime.ax_native.alias(field)
			return callback(fixture)
		end, debug.traceback))
		-- Detach before restoration and before propagating a failed causal assertion.
		-- The scheduler retains any refused native stop itself; retry its exact debt.
		local detached, result = pcall(runtime.tracker.update_ax_observer, nil)
		local retried, settled = pcall(scheduler.retryCleanup)
		local quiet = true
		for _, timer in ipairs(timers) do if timer.running then quiet = false end end
		hs.timer.absoluteTime, hs.timer.new, field.attributeValue = clock, timer_new, attribute
		if not detached or result ~= true or not retried or settled ~= true or not quiet then
			error("AX baseline fixture could not retire its exact deferred owner", 0)
		end
		if not values[1] then error(values[2], 0) end
		return table.unpack(values, 2, values.n)
	end)
end

--- Counts only actual autocorrect persistence rows, not context setup events.
--- @param runtime table Established public runtime.
--- @return integer count Autocorrect rows.
local function corrections(runtime)
	local count = 0
	for _, row in ipairs(runtime.observation.context_rows) do
		if row.type == "sys_autocorrect" then count = count + 1 end
	end
	return count
end




-- ===============================================
-- ===============================================
-- ======= 2/ Native Alias Business Regressions ===
-- ===============================================
-- ===============================================

helpers.describe("AXValue baseline: native element aliases", function()
	helpers.it("refreshes one equal native element once after a typing burst", function()
		with_baseline(function(fixture)
			fixture.prime()
			helpers.assert_true(fixture.alias == fixture.field)
			helpers.assert_true(not rawequal(fixture.alias, fixture.field))
			for step = 1, 20 do
				fixture.time(10000 + step * 10)
				fixture.runtime.state.last_time = 10000 + step * 10
				fixture.runtime.native.field_value = "typed phrase " .. step
				fixture.changed()
			end
			helpers.assert_eq(fixture.reads.count, 0)
			helpers.assert_eq(#fixture.timers, 1)
			fixture.time(10350); fixture.fire_pending()
			helpers.assert_eq(fixture.reads.count, 1,
				"An equal native AX element must refresh the baseline after typing becomes idle")
		end)
	end)

	helpers.it("does not mistake typed text for autocorrect after an equal native refresh", function()
		with_baseline(function(fixture)
			fixture.prime()
			local before = corrections(fixture.runtime)
			fixture.typing("the typed phrase")
			fixture.time(10150); fixture.fire_pending()
			fixture.time(10200)
			fixture.runtime.native.field_value = "the typed phrase!"
			fixture.changed(fixture.field)
			helpers.assert_eq(corrections(fixture.runtime), before,
				"A native alias must refresh typing before a one-character edit reaches the autocorrect writer")
			helpers.assert_eq(fixture.reads.count, 2)
		end)
	end)

	helpers.it("rejects a different native element before scheduling a baseline", function()
		with_baseline(function(fixture)
			fixture.prime()
			local foreign_reads = 0
			local foreign = fixture.runtime.ax_native.alias({ attributeValue = function()
				foreign_reads = foreign_reads + 1; return "foreign value"
			end })
			fixture.runtime.state.last_time = 10000
			fixture.time(10010); fixture.changed(foreign)
			helpers.assert_eq(fixture.reads.count, 0)
			helpers.assert_eq(foreign_reads, 0)
			helpers.assert_eq(#fixture.timers, 0)
		end)
	end)

	helpers.it("fences a retained baseline callback when focus changes", function()
		with_baseline(function(fixture)
			fixture.prime(); fixture.typing("typed before focus changed")
			local timer = fixture.timers[1]
			local replacement = { attributeValue = function(_, name)
				if name == "AXRole" then return "AXTextField" end
				if name == "AXValue" then return "replacement field" end
			end }
			fixture.runtime.ax_native.emit("AXFocusedUIElementChanged", nil, replacement)
			fixture.time(11000); timer.fn(); fixture.changed(fixture.alias)
			helpers.assert_eq(timer.running, false)
			helpers.assert_eq(fixture.reads.count, 0)
		end)
	end)

	helpers.it("fences a retained baseline callback after observer detachment", function()
		with_baseline(function(fixture)
			fixture.prime(); fixture.typing("typed before observer stopped")
			local timer, observer = fixture.timers[1], fixture.runtime.state.ax_observer
			local callback = assert(observer.observer_callback)
			helpers.assert_eq(fixture.runtime.tracker.update_ax_observer(nil), true)
			helpers.assert_nil(fixture.runtime.state.ax_observer)
			fixture.time(11000); timer.fn()
			callback(observer, fixture.alias, "AXValueChanged", {})
			helpers.assert_eq(timer.running, false)
			helpers.assert_eq(fixture.reads.count, 0)
		end)
	end)

	helpers.it("keeps an admitted alias baseline silent while the public runtime is paused", function()
		with_baseline(function(fixture)
			fixture.prime(); fixture.typing("typed before pause")
			local timer = fixture.timers[1]
			fixture.runtime.pause()
			local before = corrections(fixture.runtime)
			fixture.time(11000); timer.fn()
			helpers.assert_eq(fixture.reads.count, 0)
			helpers.assert_eq(corrections(fixture.runtime), before)
		end)
	end)

	helpers.it("retires pending alias work and restores exact ports after a body failure", function()
		local incoming_hs, incoming_tracker = rawget(_G, "hs"), package.loaded["modules.keystats.context_tracker"]
		local observed
		local ok, detail = pcall(with_baseline, function(fixture)
			fixture.prime(); fixture.typing("typed before forced cleanup")
			observed = fixture
			error("forced AX baseline alias body failure", 0)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(detail):find("forced AX baseline alias body failure", 1, true) ~= nil)
		helpers.assert_true(rawequal(rawget(_G, "hs"), incoming_hs))
		helpers.assert_true(rawequal(package.loaded["modules.keystats.context_tracker"], incoming_tracker))
		helpers.assert_true(rawequal(observed.runtime.hs.timer.absoluteTime, observed.original_clock))
		helpers.assert_true(rawequal(observed.runtime.hs.timer.new, observed.original_timer_new))
		helpers.assert_true(rawequal(observed.field.attributeValue, observed.original_native_attribute))
		helpers.assert_nil(getmetatable(observed.field))
		for _, timer in ipairs(observed.timers) do helpers.assert_eq(timer.running, false) end
		helpers.assert_eq(observed.runtime.observation.ui_live, 0)
		helpers.assert_eq(observed.runtime.observation.ax_started, observed.runtime.observation.ax_stopped)
	end)
end)

return true
