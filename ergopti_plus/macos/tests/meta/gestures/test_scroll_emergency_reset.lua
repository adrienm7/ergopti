--- tests/meta/gestures/test_scroll_emergency_reset.lua

--- ==============================================================================
--- MODULE: Scroll emergency reset (meta)
--- DESCRIPTION:
--- The gesture engine exports emergency_reset and the frame callback calls it when process_frame errors.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

helpers.describe("scroll emergency reset", function()

	-- ============================================================
	-- ===== 3a) Scroll deadlock — M.emergency_reset() exported
	-- ============================================================

	helpers.it("engine.lua must export M.emergency_reset() for scroll unblock on crash", function()
		local src = read_source("local function triggerLiveAxisIfNeeded") -- modules/gestures/engine.lua
		assert(src, "modules/gestures/engine.lua must be readable")
		-- The bug: process_frame can crash after startScrollBlock(); isBlockingScroll
		-- stays true forever because no cleanup runs on the error path.
		-- The fix: export M.emergency_reset() which calls resetGS() (and thus
		-- stopScrollBlock()), giving the frame-callback error handler a safe hook.
		assert(
			src:find("function M%.emergency_reset", 1, false),
			"engine.lua: M.emergency_reset() must be exported so the frame-callback " ..
			"error path can force a scroll unblock"
		)
		assert(
			src:find("resetGS()", 1, true),
			"engine.lua: M.emergency_reset() must call resetGS() to clear isBlockingScroll"
		)
	end)

	-- ======================================================================
	-- ===== 3b) Scroll deadlock — error path in gestures/init.lua calls it
	-- ======================================================================

	helpers.it("gestures/init.lua frame callback must call emergency_reset on process_frame error", function()
		local src = read_source("local function schedule_emergency_recycle") -- modules/gestures/init.lua
		assert(src, "modules/gestures/init.lua must be readable")
		-- The fix adds: if not Logger.pcall(...) then pcall(Engine.emergency_reset) end
		assert(
			src:find("Engine%.emergency_reset", 1, false),
			"gestures/init.lua: frame callback must call Engine.emergency_reset " ..
			"when process_frame throws, to prevent permanent scroll deadlock"
		)
	end)

end)
