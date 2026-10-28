--- adapters/unicode_carrier.lua

--- ==============================================================================
--- MODULE: Unicode Text Carrier Key
--- DESCRIPTION:
--- Chooses the key code that carries a synthetic Unicode text event. Quartz
--- keyboard events always name a key; the text itself travels in the event's
--- Unicode string, so any plain character key can carry it.
---
--- FEATURES & RATIONALE:
--- 1. Never a held key: a synthetic key-down on a key the user still holds is
---    lost. Typing « axa » then Space with the A not yet released expanded to
---    « XA »: the replacement's first event rode key code 0, the A the user was
---    holding, and only the next events, after its synthetic key-up, landed
---    (field report 2026-10-28, 18:14). The keymap taps report
---    every physical edge here and text moves to the first carrier not held.
--- 2. Self-healing marks: a key-up lost upstream would otherwise mark its key
---    held for good. A key with no event for KeyEventHealth.STUCK_MS is not
---    held (a held key repeats), so a stale mark only costs a moved carrier.
--- 3. Hot path: table writes per physical edge and, per text event, a scan
---    that stops at the first free carrier (the first one unless it is held).
--- ==============================================================================

local M = {}

local KeyEventHealth = require("infra.key_event_health")

--- Plain character keys of the ANSI block, key code 0 (A) first as Quartz and
--- hs.eventtap.keyStrokes use it. Return (36), Tab (48), Space (49), Delete
--- (51), Escape (53) and the keypad are left out: applications act on those
--- key codes whatever the event's text says.
M.CARRIER_KEYCODES = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
	21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 38, 39,
	40, 41, 42, 43, 44, 45, 46, 47, 50,
}

-- Key code → awake-clock milliseconds of its latest physical key-down.
local _held_since_ms = {}

--- Forgets every held key; tests use it between cases.
function M.reset()
	_held_since_ms = {}
end

--- Records one physical key edge seen by the keymap taps.
--- @param phase string "down" (autorepeats included) or "up".
--- @param keycode number Physical key code.
function M.note_physical_key(phase, keycode)
	assert(phase == "down" or phase == "up",
		"adapters.unicode_carrier.note_physical_key: phase must be 'down' or 'up'")
	assert(type(keycode) == "number",
		"adapters.unicode_carrier.note_physical_key: keycode must be a number")
	if phase == "up" then
		_held_since_ms[keycode] = nil
		return
	end
	_held_since_ms[keycode] = KeyEventHealth.now_ms()
end

--- Whether the user holds this key right now, by the taps' own edges.
--- @param keycode number
--- @param now_ms number Awake-clock milliseconds.
--- @return boolean
local function is_held(keycode, now_ms)
	local since = _held_since_ms[keycode]
	if since == nil then return false end
	if now_ms - since >= KeyEventHealth.STUCK_MS then
		_held_since_ms[keycode] = nil
		return false
	end
	return true
end

--- Returns the key code the next Unicode text event must ride.
--- @return number keycode First carrier the user does not hold.
--- @return boolean moved True when the default carrier is held.
function M.keycode()
	if next(_held_since_ms) == nil then return M.CARRIER_KEYCODES[1], false end
	local now_ms = KeyEventHealth.now_ms()
	for index, keycode in ipairs(M.CARRIER_KEYCODES) do
		if not is_held(keycode, now_ms) then return keycode, index > 1 end
	end
	error("adapters.unicode_carrier.keycode: every carrier key is held", 0)
end

return M
