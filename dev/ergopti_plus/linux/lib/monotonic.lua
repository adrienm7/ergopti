--- lib/monotonic.lua

--- ==============================================================================
--- MODULE: Monotonic Wall-Clock Source (Linux)
--- DESCRIPTION:
--- A single sub-second, monotonic, wall-clock time source for the Linux daemon.
--- Every timing decision that must reflect elapsed real time — gesture tap/swipe
--- classification, file-watcher debounce — needs this instead of os.clock().
---
--- FEATURES & RATIONALE:
--- 1. os.clock() is the wrong clock. It returns CPU time, not wall-clock time.
---    In an I/O-bound daemon that spends almost all of its life blocked on a
---    pipe read, CPU time barely advances, so "elapsed" is always ~0 — a gesture
---    held for two seconds looks instantaneous and is misclassified as a tap, and
---    a debounce deadline computed from os.clock() never lines up with real time.
--- 2. Prefer luv.hrtime(). libuv's high-resolution monotonic clock (nanoseconds)
---    is always current regardless of whether the event loop is running, unlike
---    luv.now() which only refreshes at the top of each loop iteration. luv is
---    the daemon's event-loop dependency, so this is the normal path.
--- 3. Degraded fallback. When luv is absent (pump-only / minimal environments)
---    fall back to os.time() — 1-second resolution, but wall-clock and never CPU
---    time. Callers that need sub-second precision run under luv in production;
---    tests inject their own clock, so the coarse fallback only affects degraded
---    setups, where a coarse-but-correct clock still beats os.clock().
--- ==============================================================================

local M = {}

local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end

-- Nanoseconds per millisecond — luv.hrtime() reports nanoseconds.
local NS_PER_MS = 1e6




-- ==================================================
-- ==================================================
-- ======= 1/ Monotonic Wall-Clock Time Source ======
-- ==================================================
-- ==================================================

--- Returns a monotonic wall-clock timestamp in milliseconds.
--- The absolute value is arbitrary (an offset from an unspecified epoch); only
--- differences between two readings are meaningful.
--- @return number Milliseconds.
function M.now_ms()
	if luv and luv.hrtime then
		return luv.hrtime() / NS_PER_MS
	end
	-- No luv: coarse wall-clock. Deliberately NOT os.clock() (CPU time).
	return os.time() * 1000
end

--- Returns a monotonic wall-clock timestamp in seconds.
--- @return number Seconds.
function M.now_sec()
	return M.now_ms() / 1000
end

--- Reports which backend is in use, for diagnostics.
--- @return string "luv.hrtime" when the high-resolution clock is available,
---   otherwise "os.time".
function M.backend()
	if luv and luv.hrtime then return "luv.hrtime" end
	return "os.time"
end

--- Returns true when a sub-second (high-resolution) clock is available.
--- @return boolean
function M.has_hires()
	return luv ~= nil and luv.hrtime ~= nil
end

return M
