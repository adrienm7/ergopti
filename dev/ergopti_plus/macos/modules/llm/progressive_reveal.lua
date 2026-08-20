--- modules/llm/progressive_reveal.lua

--- ==============================================================================
--- MODULE: LLM Progressive Reveal
--- DESCRIPTION:
--- Owns the zero-delay timer chain that reveals batch predictions one slot at a
--- time. A timer capability is published only after explicit scheduler commit;
--- refused cleanup stays retained and callback-inert, while scheduling failure
--- falls forward to the complete result so the tooltip is never truncated.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local ApiCommon      = require("modules.llm.api_common")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "llm.progressive_reveal"

--- Reveals one result at a time while retaining exact timer ownership.
--- @param results table Ordered prediction strings.
--- @param on_success function|nil Prediction callback.
--- @param elapsed_ms number|nil Elapsed request time.
--- @param is_current function|nil Identity predicate for stale-request fencing.
--- @return boolean started True when at least the first reveal was delivered.
function M.deliver(results, on_success, elapsed_ms, is_current)
	if type(results) ~= "table" or #results == 0 then return false end
	local generation = 0
	local timer = nil
	local finished = false

	local function request_is_current()
		if type(is_current) ~= "function" then return true end
		local ok, current = xpcall(is_current, debug.traceback)
		if not ok then
			Logger.error(LOG, "Progressive reveal identity check raised: %s.", tostring(current))
			return false
		end
		return current == true
	end

	local function publish(subset, is_final)
		if type(on_success) == "function" then
			ApiCommon.protected_call(on_success, "on_success", subset, elapsed_ms,
				is_final, not is_final)
		end
	end

	local function publish_complete_fallback()
		if finished or not request_is_current() then return end
		finished = true
		generation = generation + 1
		publish(results, true)
	end

	local reveal_next
	reveal_next = function(index)
		if finished or not request_is_current() then return end
		local subset = {}
		for result_index = 1, index do subset[result_index] = results[result_index] end
		local is_final = index == #results
		publish(subset, is_final)
		if is_final then
			finished = true
			return
		end

		generation = generation + 1
		local my_generation = generation
		local candidate
		local committed
		local schedule_ok, schedule_err = xpcall(function()
			candidate, committed = TimerScheduler.after(0, function()
				if timer == candidate then
					if candidate.timer ~= nil and TimerScheduler.cancel(candidate) ~= true then
						Logger.error(LOG, "Progressive reveal timer cleanup was refused; retained exact handle.")
						publish_complete_fallback()
						return
					end
					timer = nil
				end
				if committed ~= true or my_generation ~= generation or not request_is_current() then return end
				reveal_next(index + 1)
			end)
		end, debug.traceback)
		if type(candidate) == "table" and candidate.timer ~= nil then timer = candidate end
		if not schedule_ok or committed ~= true then
			if type(candidate) == "table" and candidate.timer ~= nil
				and TimerScheduler.cancel(candidate) == true and timer == candidate then
				timer = nil
			end
			Logger.error(LOG, "Progressive reveal timer did not commit; publishing complete result: %s.",
				tostring(schedule_ok and candidate or schedule_err))
			publish_complete_fallback()
			return
		end
		timer = candidate
	end

	reveal_next(1)
	return true
end

return M
