--- _shared/lua/gestures/contact_join.lua

--- ==============================================================================
--- MODULE: Third Contact Admission — Shared Lua Implementation
--- DESCRIPTION:
--- Whether three contacts on the pad can be three fingers of one hand. A
--- resting thumb joining two swiping fingers turned a two-finger swipe into a
--- three-finger one and fired tab_close, and a thumb beside a two-finger tap
--- fired tap_3 (Mac field report of 2026-11-05: that contact sat about 60 mm
--- from the pair). The macOS engine (modules/gestures/engine.lua) asks this
--- module at both of its join paths and at the three-finger tap commit, and the
--- Linux decoder (modules/gestures/mt_decoder.lua) before a count of three
--- becomes the gesture's, in millimetres on both: the macOS trackpad reports
--- them, and the Linux decoder converts evdev units with the pad's resolution.
---
--- FEATURES & RATIONALE:
--- 1. Far contact: every contact must have another one within MAX_FINGER_GAP_MM.
---    The fingertips of an adult index, middle and ring finger sit about 18 to
---    22 mm apart centre to centre when side by side, and rarely beyond 30 mm
---    when spread for a swipe; a thumb resting on the pad's lower edge is 50 mm
---    or more from them. 35 mm keeps headroom over a spread hand.
--- 2. Oversized contact: where every contact reports its major axis, none may
---    exceed MAX_MAJOR_RATIO times the largest of the others. A thumb or palm
---    contact is about twice a fingertip's; fingertips of one hand differ by a
---    quarter at most. The ratio has no unit, so the major axis needs none.
--- 3. Only a count of exactly three is judged: four- and five-finger gestures
---    take the thumb in on purpose, and a pair is the native scroll count.
---    Neither bound comes from a field calibration: both were chosen from the
---    finger geometry above, the conservative side (a real third finger is never
---    refused), decided by the coordinator on 2026-11-11 overnight, to review by
---    the maintainer once a field report logs real positions.
--- ==============================================================================

local M = {}

-- The finger count this rule judges.
M.JOINED_COUNT = 3

-- Largest distance, in millimetres, from a contact to its nearest neighbour.
M.MAX_FINGER_GAP_MM = 35

-- Largest major axis of a contact, relative to the largest of the others.
M.MAX_MAJOR_RATIO = 1.5

--- Tells why three contacts cannot be three fingers of one hand.
--- @param contacts table Array of { x = mm, y = mm, major = number|nil }.
--- @return string|nil reason "far" or "oversized", nil when admitted or not judged.
--- @return string|nil detail The measured value, for the caller's log.
function M.refusal(contacts)
	if type(contacts) ~= "table" or #contacts ~= M.JOINED_COUNT then return nil end
	for i, c in ipairs(contacts) do
		if type(c.x) ~= "number" or type(c.y) ~= "number" then
			error("contact positions must be numbers of millimetres")
		end
		local nearest = math.huge
		for j, other in ipairs(contacts) do
			if j ~= i then
				local gap = math.sqrt((c.x - other.x) ^ 2 + (c.y - other.y) ^ 2)
				if gap < nearest then nearest = gap end
			end
		end
		if nearest > M.MAX_FINGER_GAP_MM then
			return "far", string.format("contact %d is %.1f mm from the nearest (max %.0f)",
				i, nearest, M.MAX_FINGER_GAP_MM)
		end
	end
	for _, c in ipairs(contacts) do
		if type(c.major) ~= "number" or c.major <= 0 then return nil end
	end
	for i, c in ipairs(contacts) do
		local largest_other = 0
		for j, other in ipairs(contacts) do
			if j ~= i and other.major > largest_other then largest_other = other.major end
		end
		if c.major > M.MAX_MAJOR_RATIO * largest_other then
			return "oversized", string.format("contact %d major axis %.2f is %.2f times the largest other (max %.2f)",
				i, c.major, c.major / largest_other, M.MAX_MAJOR_RATIO)
		end
	end
	return nil
end

return M
