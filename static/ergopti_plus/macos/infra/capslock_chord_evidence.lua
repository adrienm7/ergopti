--- infra/capslock_chord_evidence.lua

--- ==============================================================================
--- MODULE: Ctrl+Caps Lock Slot Evidence
--- DESCRIPTION:
--- Counts, for the session, the physical Ctrl+Caps Lock presses the keymap's
--- modifier tap saw and the deliveries of the secondary_capslock slot's native
--- hotkey. The registrar tests say macOS may never fire a Caps Lock hotkey;
--- these two counts let the field run prove it either way as soon as the
--- person pressed the chord once, without asking anyone to type during it.
---
--- FEATURES & RATIONALE:
--- 1. Counts only: no key code, character or text is kept.
--- 2. Safe inside an event tap: one table write per note.
--- ==============================================================================

local M = {}

local _presses = 0
local _deliveries = 0

--- Clears both counts; tests and a full driver stop use it.
function M.reset()
	_presses, _deliveries = 0, 0
end

--- Records one physical Caps Lock modifier change made with Control held.
function M.note_press()
	_presses = _presses + 1
end

--- Records one delivery of the Caps Lock slot's native hotkey.
function M.note_delivery()
	_deliveries = _deliveries + 1
end

--- Returns the session counts.
--- @return table counts { presses, deliveries }
function M.counts()
	return { presses = _presses, deliveries = _deliveries }
end

return M
