--- _shared/lua/script_chords.lua

--- ==============================================================================
--- MODULE: Script-Management Chords (shared rules)
--- DESCRIPTION:
--- The rule the macOS and Linux drivers apply to the four script-management
--- chords of _shared/modules/actions/script_chords.json (AltGr, or the right
--- Option key on macOS, with Enter, Backspace, Delete or Escape). Windows
--- applies the same rule in infra/config_io.ahk (ScriptShortcutSlotRunsAction);
--- tools/test/test-script-chords-three-os.cjs pins the three drivers together.
---
--- FEATURES & RATIONALE:
--- 1. A chord belongs to the driver only while its slot runs an action: an
---    unassigned slot, or every slot while the submenu's switch is off, leaves
---    the key combination to the system.
--- 2. While the driver is paused, a chord runs only a script-management action
---    (paused_actions), so a paused driver never fires anything else.
--- 3. Pure: the caller decodes the JSON and hands its table over; nothing here
---    touches a file, a clock or the OS.
--- ==============================================================================

local M = {}





-- =======================================
-- =======================================
-- ======= 1/ Catalogue validation =======
-- =======================================
-- =======================================

--- Validates the decoded script_chords.json and indexes it.
--- A malformed catalogue raises: a driver without its chords must not boot
--- silently without them.
--- @param document table Decoded script_chords.json.
--- @return table catalogue { slots = array of slot rows in menu order,
---   by_id = slot id -> row, paused_actions = action id -> true }
function M.catalogue(document)
	assert(type(document) == "table" and type(document.slots) == "table" and #document.slots > 0,
		"script chords: the catalogue declares no slot")
	assert(type(document.paused_actions) == "table" and #document.paused_actions > 0,
		"script chords: the catalogue declares no paused action")
	local catalogue = { slots = {}, by_id = {}, paused_actions = {} }
	for _, slot in ipairs(document.slots) do
		assert(type(slot) == "table" and type(slot.id) == "string" and slot.id ~= "",
			"script chords: a slot lacks its id")
		assert(catalogue.by_id[slot.id] == nil, "script chords: duplicate slot " .. slot.id)
		catalogue.slots[#catalogue.slots + 1] = slot
		catalogue.by_id[slot.id] = slot
	end
	for _, action in ipairs(document.paused_actions) do
		assert(type(action) == "string" and action ~= "", "script chords: a paused action is not an id")
		catalogue.paused_actions[action] = true
	end
	return catalogue
end





-- ===========================
-- ===========================
-- ======= 2/ The rule =======
-- ===========================
-- ===========================

--- Whether a slot holding `action` runs it now.
--- @param catalogue table From M.catalogue.
--- @param action string|nil The slot's action id, "none" when unassigned.
--- @param chords_on boolean The submenu's switch ([shortcuts.script_control] chords_enabled).
--- @param paused boolean Whether the driver is paused.
--- @return boolean runs
function M.runs(catalogue, action, chords_on, paused)
	if chords_on ~= true then return false end
	if type(action) ~= "string" or action == "" or action == "none" then return false end
	return paused ~= true or catalogue.paused_actions[action] == true
end

--- The slots a driver must take from the system, running and paused.
--- @param catalogue table From M.catalogue.
--- @param assignments table Slot id -> action id.
--- @param chords_on boolean The submenu's switch.
--- @return table plan { normal = slot id -> true, paused = slot id -> true }
function M.plan(catalogue, assignments, chords_on)
	assert(type(assignments) == "table", "script chords: the plan needs the slot assignments")
	local plan = { normal = {}, paused = {} }
	for _, slot in ipairs(catalogue.slots) do
		local action = assignments[slot.id]
		if M.runs(catalogue, action, chords_on, false) then plan.normal[slot.id] = true end
		if M.runs(catalogue, action, chords_on, true) then plan.paused[slot.id] = true end
	end
	return plan
end

return M
