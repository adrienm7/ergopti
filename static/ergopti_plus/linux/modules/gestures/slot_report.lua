--- modules/gestures/slot_report.lua

--- ==============================================================================
--- MODULE: Gesture Slot Reach
--- DESCRIPTION:
--- Which gesture slots a touchpad can never fire, and which ones the desktop
--- also acts on. Pure rules over slot names and the finger count the finder
--- read, so the menu, the reader start and the tests answer the same way.
---
--- FEATURES & RATIONALE:
--- 1. An unknown finger count reaches every slot: a probe that could not read
---    the hardware must never take a working gesture away.
--- 2. The two-finger slots are named apart, because every Linux desktop reads
---    the same ungrabbed touches as scrolling or a secondary click.
--- ==============================================================================

local M = {}

--- Whether a gesture slot can ever fire on this hardware.
---
--- Answers TRUE when the capability is unknown. A wrong parse must not remove a
--- gesture that works; the worst it may do is fail to explain one that cannot.
--- @param slot string e.g. "swipe_5_up", "tap_4"
--- @param max_fingers integer|nil 0 or nil means unknown.
--- @return boolean
function M.slot_is_reachable(slot, max_fingers)
	if type(max_fingers) ~= "number" or max_fingers <= 0 then return true end
	local needed = tostring(slot):match("^swipe_(%d)_") or tostring(slot):match("^tap_(%d)$")
	if not needed then return true end
	return tonumber(needed) <= max_fingers
end

--- Whether a slot is a two-finger one, which every Linux desktop reads as
--- scrolling (swipe) or a secondary click (tap) from the same ungrabbed events.
--- @param slot string
--- @return boolean
function M.slot_is_two_finger(slot)
	slot = tostring(slot)
	return slot:match("^swipe_2_") ~= nil or slot == "tap_2"
end

--- Names the slots this hardware cannot reach and the bound slots that compete
--- with the desktop, so a log line can say WHICH gesture will never fire.
--- @param slots table Every slot name.
--- @param bound table slot -> true for the slots with an action.
--- @param max_fingers integer|nil 0 or nil means unknown: nothing is unreachable.
--- @return table { unreachable, bound_unreachable, bound_two_finger }, each sorted.
function M.report(slots, bound, max_fingers)
	assert(type(slots) == "table" and type(bound) == "table", "slot report needs the slots and the bindings")
	local report = { unreachable = {}, bound_unreachable = {}, bound_two_finger = {} }
	for _, slot in ipairs(slots) do
		if not M.slot_is_reachable(slot, max_fingers) then
			report.unreachable[#report.unreachable + 1] = slot
			if bound[slot] then report.bound_unreachable[#report.bound_unreachable + 1] = slot end
		elseif bound[slot] and M.slot_is_two_finger(slot) then
			report.bound_two_finger[#report.bound_two_finger + 1] = slot
		end
	end
	for _, list in pairs(report) do table.sort(list) end
	return report
end

return M
