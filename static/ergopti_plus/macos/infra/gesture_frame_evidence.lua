--- infra/gesture_frame_evidence.lua

--- ==============================================================================
--- MODULE: Touch Frame Clock Evidence
--- DESCRIPTION:
--- Counts, for the session, the touch frames that carried a capture stamp and
--- those that did not, and the mean spacing of consecutive stamps. The
--- gestures engine times frames on that stamp (modules/gestures/frame_clock.lua)
--- since a main-thread stall delivered 35 queued frames in 2 ms and a real
--- three-finger swipe was refused (ledger L46). The field run proves the stamp
--- with these counts instead of a person reading the log.
---
--- FEATURES & RATIONALE:
--- 1. Counts and one sum only: no position, finger or device identity is kept.
--- 2. Safe in the touch callback (up to 120 frames a second): a few arithmetic
---    operations per frame, no allocation.
--- 3. A spacing over MAX_SPACING_SEC is a pause between two touches, not a
---    frame interval, and is left out of the mean.
--- ==============================================================================

local M = {}

-- Longest gap between two stamps that still counts as one frame interval.
M.MAX_SPACING_SEC = 0.1

local _stamped, _unstamped = 0, 0
local _last_stamp = nil
local _spacing_sum, _spacing_count = 0, 0

--- Clears every count; tests and a full driver stop use it.
function M.reset()
	_stamped, _unstamped = 0, 0
	_last_stamp = nil
	_spacing_sum, _spacing_count = 0, 0
end

--- Records one touch frame.
--- @param stamp number|nil Capture stamp in seconds, nil when the frame had none.
function M.note(stamp)
	if stamp == nil then
		_unstamped = _unstamped + 1
		return
	end
	_stamped = _stamped + 1
	if _last_stamp ~= nil then
		local spacing = stamp - _last_stamp
		if spacing > 0 and spacing <= M.MAX_SPACING_SEC then
			_spacing_sum = _spacing_sum + spacing
			_spacing_count = _spacing_count + 1
		end
	end
	_last_stamp = stamp
end

--- Returns the session counts.
--- @return table counts { stamped, unstamped, mean_spacing_ms } (mean nil before two frames).
function M.counts()
	return {
		stamped = _stamped,
		unstamped = _unstamped,
		mean_spacing_ms = _spacing_count > 0 and (_spacing_sum / _spacing_count * 1000) or nil,
	}
end

return M
