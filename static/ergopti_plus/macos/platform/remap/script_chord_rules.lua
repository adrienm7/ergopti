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
--- 5. A running chord is a sequence: right Option pressed, then the slot's key,
---    with no other key pressed between, as on Windows and Linux. Typing right
---    Option symbols then Return while it is still held is text: on Ergopti+ a
---    fast « (# » then Return paused the driver (the maintainer, 2026-11-17).
---    The sequence variable rises with the holder's own press and every other
---    key-down lowers it (M.apply_sequence); fn alone keeps it, since fn +
---    Backspace is the Delete slot on a Mac keyboard without the key.
--- 6. Paused, the chords keep the real Option key with no sequence rule (the
---    maintainer's decision of 2026-11-17): once Karabiner is bundled with
---    Ergopti, pausing Ergopti pauses Karabiner and the chord key goes back to
---    the physical Alt (Option) position.
--- ==============================================================================

local M = {}

local Keycodes  = require("platform.input.keycodes")
local Catalogue = require("infra.script_chord_catalogue")
local Paths     = require("core.fs.engine.paths")
local Json      = require("core.text.engine.json")
-- The shared keycode registry: each slot's sentinel constant and its number.
-- infra.keycodes only adds the Karabiner name of a code (to_name).
local SharedKeycodes = require("platform.input.keycodes.core")

-- The Karabiner key the Delete slot also reads with fn held.
local FN_DELETE_KEY = "delete_or_backspace"
local DELETE_FORWARD_KEY = "delete_forward"

-- The synthetic modifiers stamped onto every sentinel (generator.lua keeps the
-- rationale): a stray physical function key never carries both.
local SENTINEL_TAGS = { "left_control", "left_shift" }

-- The physical key whose held variable marks the running chord.
local HOLDER_KEY = "right_command"

-- Appended to the holder variable: the variable that is 1 from the holder's
-- press until any other key goes down. A ke_held_ name, so the deploy scopes
-- it to the lease generation like the holder's.
local SEQUENCE_SUFFIX = "_sequence"

-- The Karabiner key codes that end the sequence, sorted; nil until read.
local _sequence_keys = nil





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

--- The variable a running chord requires besides the holder's: 1 from the
--- holder's press until any other key goes down.
--- @param holder_var string Karabiner variable set while right_command is held.
--- @return string name
function M.sequence_var(holder_var)
	assert(type(holder_var) == "string" and holder_var ~= "", "script chord rules need the holder variable")
	return holder_var .. SEQUENCE_SUFFIX
end

--- The rules of the running chords: the physical right Command (the right
--- Option key of the layout) pressed, then a slot's key, emits its sentinel.
--- @param chords table|nil See M.plan_or_default.
--- @param holder_var string Karabiner variable set while right_command is held.
--- @return table rules
function M.running(chords, holder_var)
	local sequence_var = M.sequence_var(holder_var)
	local plan = M.plan_or_default(chords)
	local rules = {}
	for _, slot in ipairs(ordered(plan.normal)) do
		local sentinel = sentinel_of(slot)
		local manipulators = {}
		for _, from in ipairs(froms_of(slot)) do
			manipulators[#manipulators + 1] = {
				type = "basic",
				from = from,
				conditions = {
					{ type = "variable_if", name = holder_var, value = 1 },
					{ type = "variable_if", name = sequence_var, value = 1 },
				},
				-- The chord's own key ends the sequence: a second Return is text.
				to = {
					{ set_variable = { name = sequence_var, value = 0 } },
					{ key_code = sentinel, modifiers = SENTINEL_TAGS },
				},
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

--- The Karabiner key codes of the physical-key registry that end the
--- sequence: every key but the holder and fn, sorted, read once.
--- @return table key_codes
local function sequence_keys()
	if _sequence_keys then return _sequence_keys end
	-- The physical-key registry: its Karabiner key codes are every key that
	-- ends the sequence.
	local path = Paths.shared("layouts/data/keycodes/physical_keys.json")
	local handle = path and io.open(path, "rb")
	if not handle then error("script chord rules: cannot read " .. tostring(path)) end
	local read_ok, raw = pcall(handle.read, handle, "*a")
	local close_ok, closed = pcall(handle.close, handle)
	if not read_ok or type(raw) ~= "string" or not close_ok or closed ~= true then
		error("script chord rules: cannot complete read of " .. tostring(path))
	end
	local ok, registry = pcall(Json.decode, raw)
	if not ok or type(registry) ~= "table" or type(registry.keys) ~= "table" then
		error("script chord rules: " .. tostring(path) .. " is malformed")
	end
	local seen, keys = {}, {}
	for _, record in pairs(registry.keys) do
		local karabiner = type(record) == "table" and record.karabiner
		local code = type(karabiner) == "table" and karabiner.key_code
		-- Mouse buttons name no key ("undefined"); the wheel has no key code.
		if type(code) == "string" and code ~= "undefined" and code:match("^[a-z0-9_]+$")
			and code ~= HOLDER_KEY and code ~= "fn" and not seen[code] then
			seen[code] = true
			keys[#keys + 1] = code
		end
	end
	table.sort(keys)
	assert(#keys > 0, "script chord rules: the physical-key registry names no Karabiner key")
	_sequence_keys = keys
	return keys
end

--- Whether a list of Karabiner events sets a variable to a value.
--- @param events table|nil Karabiner events.
--- @param name string
--- @param value number
--- @return boolean
local function sets_variable(events, name, value)
	for _, event in ipairs(type(events) == "table" and events or {}) do
		local set = event.set_variable
		if type(set) == "table" and set.name == name and set.value == value then return true end
	end
	return false
end

--- Makes the running chords a sequence over the deployed rules (see 5.
--- above). The manipulator tracking the holder's press raises the sequence
--- variable, and its release lowers it; every other key manipulator lowers it
--- at its key-down; a rule appended last lowers it for a key no earlier rule
--- takes, then types that key unchanged. With the sequence down that last
--- rule matches nothing, so only the first key after right Option meets it.
--- @param rules table Deployed rules, updated in place; the new rule is appended.
--- @param holder_var string Karabiner variable set while right_command is held.
--- @return table rules The same list.
function M.apply_sequence(rules, holder_var)
	local sequence_var = M.sequence_var(holder_var)
	for _, rule in ipairs(rules) do
		for _, manipulator in ipairs(rule.manipulators or {}) do
			local from = type(manipulator.from) == "table" and manipulator.from or {}
			-- A running chord lowers the sequence itself (M.running).
			if manipulator.type == "basic" and not sets_variable(manipulator.to, sequence_var, 0) then
				if sets_variable(manipulator.to, holder_var, 1) then
					manipulator.to[#manipulator.to + 1] = { set_variable = { name = sequence_var, value = 1 } }
					manipulator.to_after_key_up = manipulator.to_after_key_up or {}
					manipulator.to_after_key_up[#manipulator.to_after_key_up + 1] =
						{ set_variable = { name = sequence_var, value = 0 } }
				elseif from.key_code ~= "fn" then
					local to = { { set_variable = { name = sequence_var, value = 0 } } }
					for _, event in ipairs(manipulator.to or {}) do to[#to + 1] = event end
					manipulator.to = to
				end
			end
		end
	end
	local manipulators = {}
	for _, key_code in ipairs(sequence_keys()) do
		manipulators[#manipulators + 1] = {
			type = "basic",
			from = { key_code = key_code, modifiers = { optional = { "any" } } },
			conditions = { { type = "variable_if", name = sequence_var, value = 1 } },
			to = { { set_variable = { name = sequence_var, value = 0 } }, { key_code = key_code } },
		}
	end
	rules[#rules + 1] = {
		description = "Script control: another key after physical rcmd ends the chord sequence",
		manipulators = manipulators,
	}
	return rules
end

--- The holder key of the running chords.
M.HOLDER_KEY = HOLDER_KEY

return M
