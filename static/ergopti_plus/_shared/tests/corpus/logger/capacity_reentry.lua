--- _shared/tests/corpus/logger/capacity_reentry.lua

--- ==============================================================================
--- MODULE: Logger Capacity Reentry Regression Scenario
--- DESCRIPTION:
--- A summary sink must observe the incoming streak already published, so its
--- nested repeats cannot be overwritten when the original emission resumes.
--- ==============================================================================

--- Runs against a fresh shared core instance with no native filesystem sink.
--- @param Logger table Fresh logger core.
return function(Logger)
	Logger.clock_fn = function() return 0 end
	Logger.timestamp_fn = function() return "2026-10-02 20:38:23:000" end
	Logger.set_level("debug")
	Logger.set_sink(function() end)
	Logger.enable_repeat_collapsing()
	Logger.info("reentry", "victim %d", 1)
	Logger.info("reentry", "victim %d", 2)
	-- Spec section 4.2 bounds the live table at 64 streaks.
	for i = 1, 63 do Logger.info("reentry", "distinct " .. i) end
	local seen, reentered = {}, false
	Logger.set_sink(function(line)
		seen[#seen + 1] = line
		if not reentered and line:find('"victim %d" repeated', 1, true) then
			reentered = true
			Logger.info("reentry", "incoming %d", 100)
			Logger.info("reentry", "incoming %d", 101)
		end
	end)
	Logger.info("reentry", "incoming %d", 1)
	Logger.flush_repeats(true)
	local incoming_summaries = 0
	for _, line in ipairs(seen) do
		if line:find('"incoming %d" repeated', 1, true) then
			incoming_summaries = incoming_summaries + 1
			assert(line:find("repeated 2 more times", 1, true), "both nested occurrences must be retained")
		end
	end
	Logger.set_sink(nil)
	Logger.disable_repeat_collapsing()
	assert(reentered, "the eviction summary sink must reenter")
	assert(incoming_summaries == 1, "the outer emission must not overwrite nested repeat counts")
end
