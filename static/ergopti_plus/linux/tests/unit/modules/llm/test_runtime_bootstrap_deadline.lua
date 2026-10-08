--- tests/unit/modules/llm/test_runtime_bootstrap_deadline.lua

--- ==============================================================================
--- MODULE: Original Bootstrap Deadline Projection
--- DESCRIPTION:
--- Independent clocks distinguish the immutable master bound from a recomputed
--- now-plus-remaining value. Projection never owns another timer or retirement.
--- ==============================================================================

local helpers = require("tests.helpers")
local Budget = helpers.load_module("llm.bootstrap_budget")

local function fixture()
	local clock = { now = 100, constructed = 0, closed = false }
	local timer = {}
	function timer:cancel() return clock.closed end
	function timer:is_settled() return clock.closed end
	function timer:on_settled() return true end
	clock.owner, clock.capability = Budget.new(50, {
		now_ms = function() return clock.now end,
		after = function(duration)
			assert(duration == 50)
			clock.constructed = clock.constructed + 1
			return timer
		end,
	})
	return clock
end

helpers.describe("Original bootstrap deadline", function()
	helpers.it("projects the exact original bound after independent clock progress", function()
		local f = fixture()
		assert(f.capability.deadline_ms() == 150)
		f.now = 149
		assert(f.capability.deadline_ms() == 150 and f.capability.remaining_ms() == 1)
		assert(f.constructed == 1 and not f.owner:is_settled())
		f.owner:cancel(); f.closed = true; assert(f.owner:retire())
	end)
	helpers.it("cannot mutate the original bound through the public capability", function()
		local f = fixture()
		assert(not pcall(function() f.capability.deadline_ms = function() return 9999 end end))
		assert(f.capability.deadline_ms() == 150 and next(f.capability) == nil)
		f.owner:cancel(); f.closed = true; assert(f.owner:retire())
	end)
	helpers.it("refuses projection at original deadline without claiming timer closure", function()
		local f = fixture(); f.now = 150
		assert(f.capability.deadline_ms() == nil and f.capability.reason() == "bootstrap_timeout")
		assert(not f.owner:is_settled() and f.constructed == 1)
		f.closed = true; assert(f.owner:retire())
	end)
	helpers.it("refuses a backward native clock instead of reconstructing availability", function()
		local f = fixture(); f.now = 99
		assert(f.capability.deadline_ms() == nil and f.capability.reason() == "bootstrap_clock_invalid")
		assert(not f.owner:is_settled())
		f.closed = true; assert(f.owner:retire())
	end)
	helpers.it("original timer retirement leaves its still-live bound unchanged", function()
		local f = fixture(); f.closed = true
		assert(f.owner:retire() and f.capability.deadline_ms() == 150)
		assert(f.owner:finish() and f.capability.deadline_ms() == nil)
	end)
	helpers.it("cancellation withdraws projection while exact timer debt remains", function()
		local f = fixture(); f.owner:cancel("original_source_changed")
		assert(f.capability.deadline_ms() == nil and not f.owner:is_settled())
		assert(f.capability.reason() == "original_source_changed" and f.constructed == 1)
		f.closed = true; assert(f.owner:retire())
	end)
end)
