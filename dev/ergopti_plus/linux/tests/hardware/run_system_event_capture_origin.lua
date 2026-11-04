--- tests/hardware/run_system_event_capture_origin.lua

--- ==============================================================================
--- MODULE: Native System Capture Calendar Origin Contract
--- DESCRIPTION:
--- Replays the real sampler/collector/SQLite fixture from a fractional raw clock.
--- Calendar coordinates remain canonical integers; no duration or native deadline
--- is rounded, extended or replaced to satisfy the committed aggregate assertions.
--- ==============================================================================

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;"
	.. root .. "/../_shared/lua/?/init.lua;" .. package.path
local Clock = require("infra.monotonic")
local Calendar = require("modules.keystats.calendar")
local original_now = Clock.now_ms
-- This representable raw origin exposes subtraction below an integer boundary.
-- The actual Calendar owner, rather than the sampler fixture, admits its value.
local FRACTIONAL_ORIGIN_MS = 100000.001
Clock.now_ms = function() return FRACTIONAL_ORIGIN_MS end
local ok, failure = xpcall(function()
	assert(Calendar.capture().mono_ms == 100000, "the real Calendar must admit an integer origin")
	assert(loadfile(root .. "/tests/hardware/run_system_event_capture.lua"))()
end, debug.traceback)
Clock.now_ms = original_now
if not ok then error(failure, 0) end
print("Native system capture: fractional raw origin preserves canonical committed intervals.")
