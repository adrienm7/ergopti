--- _shared/lua/test/owned_timer_slots_contract.lua

--- ==============================================================================
--- MODULE: Owned Timer Slots Contract
--- DESCRIPTION:
--- Pins the named one-shot timer slots (owned_timer_slots.lua) against a
--- modelled TimerScheduler on both Lua runners: delivery, refused start,
--- delivery or cancellation during acquisition, refused cancellation kept as
--- debt, and continuations behind settlement. register_sources() checks that
--- an owner does not carry its own copy of the state machine again.
--- ==============================================================================

local M = {}
local Slots = require("owned_timer_slots")

--- A modelled scheduler with the TimerScheduler handle shape: `timer` is
--- non-nil until the native timer settles, and settlement observers run first
--- when it fires, as the macOS adapter cancels before invoking the callback.
--- @return table scheduler
local function model()
	local s = { observers = {}, handles = {}, refuse_start = false, refuse_cancel = false }
	local function settle(handle)
		local observers = s.observers[handle] or {}
		s.observers[handle] = nil
		for _, observer in ipairs(observers) do observer() end
	end
	function s.after(_, fn)
		local handle = { timer = {}, fn = fn }
		s.handles[#s.handles + 1] = handle
		if s.during_after then s.during_after(handle) end
		return handle, not s.refuse_start
	end
	function s.cancel(handle)
		if s.refuse_cancel then return false end
		handle.timer = nil
		settle(handle)
		return true
	end
	function s.onSettled(handle, observer)
		if handle.timer == nil then observer(); return true end
		s.observers[handle] = s.observers[handle] or {}
		table.insert(s.observers[handle], observer)
		return true
	end
	--- Fires one handle the way the adapter does: settle, then deliver.
	function s.fire(handle)
		handle.timer = nil
		settle(handle)
		handle.fn()
	end
	--- Settles a handle whose cancellation the native layer refused earlier.
	function s.release(handle)
		handle.timer = nil
		settle(handle)
	end
	return s
end

--- A logger that records "<level> <text>" lines.
--- @return table logger
--- @return table lines
local function recording_logger()
	local lines = {}
	return {
		error = function(_, template, ...) lines[#lines + 1] = "error " .. string.format(template, ...) end,
		debug = function(_, template, ...) lines[#lines + 1] = "debug " .. string.format(template, ...) end,
	}, lines
end

--- Builds one owner's slots over a fresh model.
--- @return table timers
--- @return table scheduler
--- @return table lines
local function build()
	local scheduler = model()
	local logger, lines = recording_logger()
	return Slots.new({ scheduler = scheduler, logger = logger, log = "tests.owned_timers" }), scheduler, lines
end

--- Registers the slot vectors in a driver suite.
--- @param helpers table Driver test API.
function M.register(helpers)
	helpers.describe("shared owned timer slots (owned-timer-slots)", function()
		helpers.it("refuses invalid options", function()
			local logger = recording_logger()
			helpers.assert_true(pcall(Slots.new, { scheduler = model(), logger = logger, log = "x" }))
			helpers.assert_eq(pcall(Slots.new, { scheduler = model(), logger = logger, log = "" }), false)
			helpers.assert_eq(pcall(Slots.new, { logger = logger, log = "x" }), false)
			helpers.assert_eq(pcall(Slots.new, { scheduler = model(), log = "x" }), false)
			helpers.assert_eq(pcall(Slots.new, { scheduler = model(), logger = logger, log = "x", extra = 1 }), false)
		end)

		helpers.it("delivers once, then frees the slot", function()
			local timers, scheduler = build()
			local calls = 0
			helpers.assert_eq(timers.arm("hide", 1, function() calls = calls + 1 end, "Hide"), true)
			helpers.assert_type(timers.slots.hide, "table")
			helpers.assert_eq(timers.arm("hide", 1, function() end, "Hide"), false, "one owner per slot")
			scheduler.fire(scheduler.handles[1])
			helpers.assert_eq(calls, 1)
			helpers.assert_nil(timers.slots.hide)
			scheduler.handles[1].fn()
			helpers.assert_eq(calls, 1, "a repeated native delivery is inert")
		end)

		helpers.it("frees the slot and never calls back after a refused start", function()
			local timers, scheduler, lines = build()
			scheduler.refuse_start = true
			local called = false
			helpers.assert_eq(timers.arm("initial", 0, function() called = true end, "Initial"), false)
			helpers.assert_nil(timers.slots.initial)
			helpers.assert_nil(scheduler.handles[1].timer, "the armed candidate was cancelled")
			helpers.assert_eq(called, false)
			helpers.assert_true(lines[1]:find("Initial timer acquisition refused", 1, true) ~= nil, lines[1])
		end)

		helpers.it("refuses a delivery or a cancellation that lands during acquisition", function()
			local timers, scheduler = build()
			local called = false
			scheduler.during_after = function(handle) handle.fn() end
			helpers.assert_eq(timers.arm("deadline", 5, function() called = true end, "Deadline"), false)
			helpers.assert_eq(called, false, "an early delivery is not authorized")
			helpers.assert_nil(timers.slots.deadline)
			scheduler.during_after = function() helpers.assert_eq(timers.cancel("deadline", "Deadline"), false) end
			helpers.assert_eq(timers.arm("deadline", 5, function() called = true end, "Deadline"), false)
			helpers.assert_nil(timers.slots.deadline)
			helpers.assert_eq(called, false)
		end)

		helpers.it("keeps a refused cancellation as owned debt until the native timer settles", function()
			local timers, scheduler, lines = build()
			local called, continued = false, {}
			helpers.assert_eq(timers.arm("deadline", 5, function() called = true end, "Deadline"), true)
			scheduler.refuse_cancel = true
			helpers.assert_eq(timers.cancel("deadline", "Deadline"), false)
			helpers.assert_true(lines[#lines]:find("cancellation refused; exact handle retained", 1, true) ~= nil)
			helpers.assert_type(timers.slots.deadline, "table", "the exact handle stays owned")
			helpers.assert_eq(timers.arm("deadline", 5, function() end, "Deadline"), false, "no successor over debt")
			helpers.assert_eq(timers.when_settled("deadline", function() continued[#continued + 1] = "first" end), true)
			helpers.assert_eq(timers.when_settled("deadline", function() error("modelled continuation failure") end), true)
			helpers.assert_eq(timers.when_settled("deadline", function() continued[#continued + 1] = "third" end), true)
			helpers.assert_eq(continued, {}, "nothing runs before settlement")
			scheduler.release(scheduler.handles[1])
			helpers.assert_nil(timers.slots.deadline)
			helpers.assert_eq(continued, { "first", "third" }, "a failing continuation does not stop the others")
			helpers.assert_true(lines[#lines]:find("settlement callback failed", 1, true) ~= nil)
			helpers.assert_eq(called, false, "a cancelled timer never calls back")
			helpers.assert_eq(timers.when_settled("deadline", function() continued[#continued + 1] = "late" end), true)
			helpers.assert_eq(continued, { "first", "third", "late" }, "a free slot continues at once")
			helpers.assert_eq(timers.when_settled("deadline", "not a function"), false)
		end)

		helpers.it("cancels an armed timer and an empty slot", function()
			local timers, scheduler = build()
			helpers.assert_eq(timers.cancel("hide", "Hide"), true, "an empty slot is settled")
			helpers.assert_eq(timers.arm("hide", 1, function() error("must not run") end, "Hide"), true)
			helpers.assert_eq(timers.cancel("hide", "Hide"), true)
			helpers.assert_nil(timers.slots.hide)
			helpers.assert_nil(scheduler.handles[1].timer)
		end)
	end)
end

--- Checks that each owner source delegates to the shared slots.
--- @param helpers table Driver test API.
--- @param paths table Paths of the owners' Lua sources.
function M.register_sources(helpers, paths)
	helpers.describe("timer slot owners use the shared slots (owned-timer-slots)", function()
		for _, path in ipairs(paths) do
			helpers.it(path:match("[^/]+$") .. " requires owned_timer_slots and keeps no copy", function()
				local file = assert(io.open(path, "rb"))
				local source = assert(file:read("*a"))
				assert(file:close())
				helpers.assert_true(source:find('require("owned_timer_slots")', 1, true) ~= nil, "requires the slots")
				for _, copy in ipairs({ "local function arm_owned_timer", "local function cancel_owned_timer",
					"local function when_owned_timer_settled", "delivery_during_acquisition" }) do
					helpers.assert_true(source:find(copy, 1, true) == nil, "the owner carries its own " .. copy)
				end
			end)
		end
	end)
end

return M
