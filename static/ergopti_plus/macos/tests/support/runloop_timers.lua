--- tests/support/runloop_timers.lua

--- ==============================================================================
--- MODULE: Cooperative Native Timer Queue
--- DESCRIPTION:
--- Models unstarted repeating native timers with explicit runloop turns. Timer
--- delivery and elapsed work are independent of a caller's ingest cadence.
--- ==============================================================================

local M = {}

--- Construct an independent Hammerspoon-style native timer queue.
--- @return table loop Exposes api, step and drain.
function M.create()
	local loop = { queue = {}, clock_ns = 0, turns = 0 }
	loop.api = {
		absoluteTime = function()
			loop.clock_ns = loop.clock_ns + 1000000
			return loop.clock_ns
		end,
		secondsSinceEpoch = function() return os.time() end,
		new = function(delay, callback)
			local timer = { active = false, delay = delay, callback = callback, queued = false }
			function timer:start()
				self.active = true
				if not self.queued then loop.queue[#loop.queue + 1] = self; self.queued = true end
				return self
			end
			function timer:stop() self.active = false; return self end
			function timer:running() return self.active end
			return timer
		end,
	}
	function loop.step()
		while #loop.queue > 0 do
			local timer = table.remove(loop.queue, 1)
			timer.queued = false
			if timer.active then
				loop.turns = loop.turns + 1
				loop.clock_ns = loop.clock_ns + timer.delay * 1000000000
				timer.callback()
				if timer.active and not timer.queued then
					loop.queue[#loop.queue + 1], timer.queued = timer, true
				end
				return true
			end
		end
		return false
	end
	function loop.drain()
		for _ = 1, 10000 do if not loop.step() then return end end
		error("controlled native timer queue failed to settle")
	end
	return loop
end

return M
