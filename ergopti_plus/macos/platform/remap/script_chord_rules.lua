--- platform/remap/script_chord_rules.lua

--- ==============================================================================
--- MODULE: Script Chord Karabiner Rules
--- DESCRIPTION:
--- Builds the Karabiner rules that turn each script-management chord into its
--- sentinel (infra/keycodes SCRIPT_CHORD_SENTINELS), which the script-control
--- eventtap (modules/shortcuts/script_control.lua) dispatches. Only a slot that
--- runs an action gets a rule: an unassigned slot, every slot while the
--- submenu's switch is off, and while paused every slot outside the
--- script-management actions keep the key combination native.
---
--- FEATURES & RATIONALE:
--- 1. Running, the chord is the physical right Command key, which the remap
---    turns into the right Option key (this driver's AltGr), held with the key:
---    the rule reads the held variable of right_command, as the three
---    historical sentinel rules of generator.lua did.
--- 2. Paused, every other remap is off and the user reaches the chord with the
---    real Option key, either side, as the historical paused rules did.
--- 3. fn + Backspace is the Delete of a Mac keyboard without the key: the Delete
---    slot reads it too, and its rule comes first, because the Backspace rule's
---    modifiers are optional and would take it.
--- 4. A plan is the one ScriptChords.plan returns. A state without one (a test
---    fixture, a deploy before the script-control owner registered) deploys the
---    plan of an empty configuration, every slot on its preset.
--- ==============================================================================

local M = {}

local Keycodes  = require("infra.keycodes")
local Catalogue = require("infra.script_chord_catalogue")
-- The shared keycode registry: each slot's sentinel constant and its number.
-- infra.keycodes only adds the Karabiner name of a code (to_name).
local SharedKeycodes = require("keycodes")

-- The Karabiner key the Delete slot also reads with fn held.
local FN_DELETE_KEY = "delete_or_backspace"
local DELETE_FORWARD_KEY = "delete_forward"

-- The synthetic modifiers stamped onto every sentinel (generator.lua keeps the
-- rationale): a stray physical function key never carries both.
local SENTINEL_TAGS = { "left_control", "left_shift" }

-- The physical key whose held variable marks the running chord.
local HOLDER_KEY = "right_command"





-- ===========================
-- ===========================
-- ======= 1/ The plan =======
-- ===========================
-- ===========================

--- Validates a plan, or gives the plan of an empty configuration.
--- @param chords table|nil { normal = slot id -> true, paused = slot id -> true }
--- @return table chords
function M.plan_or_default(chords)
	if chords == nil then return Catalogue.default_plan() end
	assert(type(chords) == "table" and type(chords.normal) == "table" and type(chords.paused) == "table",
		"script chord rules need a plan with normal and paused slots")
	local by_id = Catalogue.get().by_id
	for _, set in ipairs({ chords.normal, chords.paused }) do
		for id, on in pairs(set) do
			assert(by_id[id] ~= nil and on == true, "script chord rules: unknown slot " .. tostring(id))
		end
	end
	return chords
end

--- The slots of a set, in rule order: the Delete slot first (see 3. above),
--- then the catalogue's order.
--- @param set table Slot id -> true.
--- @return table slots Catalogue rows.
local function ordered(set)
	local first, rest = {}, {}
	for _, slot in ipairs(Catalogue.get().slots) do
		if set[slot.id] then
			local list = slot.karabiner == DELETE_FORWARD_KEY and first or rest
			list[#list + 1] = slot
		end
	end
	for _, slot in ipairs(rest) do first[#first + 1] = slot end
	return first
end

--- The Karabiner `from` blocks of one slot.
--- @param slot table Catalogue row.
--- @param mandatory table|nil Modifiers every block requires.
--- @return table froms
local function froms_of(slot, mandatory)
	local function from(key_code, extra)
		local required = {}
		for _, name in ipairs(mandatory or {}) do required[#required + 1] = name end
		if extra then required[#required + 1] = extra end
		local modifiers = { optional = { "any" } }
		if #required > 0 then modifiers.mandatory = required end
		return { key_code = key_code, modifiers = modifiers }
	end
	local list = { from(slot.karabiner) }
	if slot.karabiner == DELETE_FORWARD_KEY then list[#list + 1] = from(FN_DELETE_KEY, "fn") end
	return list
end

--- The sentinel key name of one slot.
--- @param slot table Catalogue row.
--- @return string key_code
local function sentinel_of(slot)
	local code = SharedKeycodes[SharedKeycodes.SCRIPT_CHORD_SENTINELS[slot.id] or ""]
	assert(type(code) == "number", "script chord rules: no sentinel for " .. slot.id)
	return Keycodes.to_name(code)
end





-- ============================
-- ============================
-- ======= 2/ The rules =======
-- ============================
-- ============================

--- The rules of the running chords: the physical right Command held (the
--- right Option key of the layout) with a slot's key emits its sentinel.
--- @param chords table|nil See M.plan_or_default.
--- @param holder_var string Karabiner variable set while right_command is held.
--- @return table rules
function M.running(chords, holder_var)
	assert(type(holder_var) == "string" and holder_var ~= "", "script chord rules need the holder variable")
	local plan = M.plan_or_default(chords)
	local rules = {}
	for _, slot in ipairs(ordered(plan.normal)) do
		local sentinel = sentinel_of(slot)
		local manipulators = {}
		for _, from in ipairs(froms_of(slot)) do
			manipulators[#manipulators + 1] = {
				type = "basic",
				from = from,
				conditions = { { type = "variable_if", name = holder_var, value = 1 } },
				to = { { key_code = sentinel, modifiers = SENTINEL_TAGS } },
			}
		end
		rules[#rules + 1] = {
			description = string.format("Script control: physical rcmd + %s → %s", slot.karabiner, sentinel),
			manipulators = manipulators,
		}
	end
	return rules
end

--- The rules of the paused chords: the real Option key with a slot's key emits
--- its sentinel, for the script-management actions only.
--- @param chords table|nil See M.plan_or_default.
--- @return table rules
function M.paused(chords)
	local plan = M.plan_or_default(chords)
	local rules = {}
	for _, slot in ipairs(ordered(plan.paused)) do
		local sentinel = sentinel_of(slot)
		local manipulators = {}
		for _, from in ipairs(froms_of(slot, { "option" })) do
			manipulators[#manipulators + 1] = {
				type = "basic",
				from = from,
				to = { { key_code = sentinel, modifiers = SENTINEL_TAGS } },
			}
		end
		rules[#rules + 1] = {
			description = string.format("Paused script control: option + %s → %s", slot.karabiner, sentinel),
			manipulators = manipulators,
		}
	end
	return rules
end

--- The holder key of the running chords.
M.HOLDER_KEY = HOLDER_KEY

return M
