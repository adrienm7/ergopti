--- _shared/shortcuts/engine/actions/sticky_label.lua

--- ==============================================================================
--- MODULE: Sticky Action Labels
--- DESCRIPTION:
--- Names a sticky_* action in the user's language. Each locale's
--- sg_actions.sticky_<mods> text is a template whose {1} the modifiers fill,
--- named from the shared key name table on the platform that shows them
--- (« 📌 Cmd + Maj rémanents » on macOS, « 📌 Win + Maj rémanents » on
--- Windows). The labels used to spell macOS's English names in every locale.
--- Port: windows/modules/gestures/actions.ahk _GestureActionLabel.
---
--- FEATURES & RATIONALE:
--- 1. The id spells the modifiers, as the catalogue does on every driver:
---    cmd, ctrl, option and shift, Option being the Alt key.
--- 2. sticky_hyper is named by its own word and holds no {1}.
--- 3. Fail fast: an unknown modifier token raises rather than dropping it.
--- ==============================================================================

local KeyNames = require("platform.input.keycodes.key_names")

local M = {}

-- The key name id of each token a sticky id spells.
local MODIFIER_IDS = { cmd = "cmd", ctrl = "ctrl", option = "alt", shift = "shift" }

--- The key name ids a sticky action holds, in the order its id spells them.
--- @param id string A sticky_* action id.
--- @return table|nil modifiers nil for sticky_hyper, named by its own word.
function M.modifiers(id)
	local rest = type(id) == "string" and id:match("^sticky_(.+)$")
	if not rest then error("sticky label: not a sticky action: " .. tostring(id), 2) end
	if rest == "hyper" then return nil end
	local modifiers = {}
	for token in rest:gmatch("[^_]+") do
		local modifier = MODIFIER_IDS[token]
		if modifier == nil then error("sticky label: unknown modifier " .. token .. " in " .. id, 2) end
		modifiers[#modifiers + 1] = modifier
	end
	return modifiers
end

--- Whether an action id is a sticky action.
--- @param id string Any action id.
--- @return boolean
function M.is_sticky(id)
	return type(id) == "string" and id:match("^sticky_.") ~= nil
end

--- The translated label of one sticky action.
--- @param id string A sticky_* action id.
--- @param key string Its label key (sg_actions.<id>).
--- @param platform string "windows", "macos" or "linux".
--- @param translate function Takes a locale key, returns its text.
--- @return string
function M.label(id, key, platform, translate)
	local modifiers = M.modifiers(id)
	if modifiers == nil then return translate(key) end
	return KeyNames.fill(key, KeyNames.modifiers_label(modifiers, platform, translate), translate)
end

return M
