--- _shared/lua/llm/prompt_action.lua

--- ==============================================================================
--- MODULE: Prompt Action Parameter — Shared Lua Implementation
--- DESCRIPTION:
--- Encodes and decodes the per-binding parameter of the "llm_prompt_prediction"
--- action: which prompt profile to run and how many predictions to request.
---
--- FEATURES & RATIONALE:
--- 1. A binding stores one string, so the value is "<profile_id>" (use the AI
---    menu's prediction count) or "<profile_id>|<count>" (a count of its own).
--- 2. Only the syntax is validated here. Whether the profile still exists is a
---    run-time question: deleting a custom prompt must not silently wipe the
---    bindings that name it when the configuration is next loaded.
--- 3. Profile ids are the built-in ids and the generated custom ids
---    ("user_…", "custom_…"): letters, digits, "_" and "-" only, so "|" can
---    never be part of an id.
---
--- The AutoHotkey port is windows/modules/llm/prompt_action.ahk; the action
--- picker page parses the same syntax. All are pinned by
--- _shared/tests/corpus/action_parameters/llm_prompt_vectors.json.
--- ==============================================================================

local M = {}
local Translate = require("llm.translate")




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Separator between the profile id and the prediction count
M.SEPARATOR = "|"

-- Bounds of a binding's own prediction count, those of the AI menu's setting
M.MIN_PREDICTIONS = 1
M.MAX_PREDICTIONS = 10

-- Longest accepted profile id; generated custom ids stay well below it
M.MAX_ID_LENGTH = 128




-- =====================================
-- =====================================
-- ======= 2/ Public API ===============
-- =====================================
-- =====================================

--- Parses a binding value.
--- @param value string The stored parameter.
--- @return table|nil parsed { profile_id = string, num_predictions = number|nil } (nil count = menu setting).
--- @return string|nil err Reason the value is invalid.
function M.parse(value)
	if type(value) ~= "string" then return nil, "not a string" end
	local profile_id, count = value:match("^([^|]*)|(.*)$")
	local target
	if count then
		local count_field, target_field = count:match("^([^|]*)|(.*)$")
		if count_field then
			if profile_id ~= "translate" or not Translate.is_language_text(target_field) then return nil, "invalid translation target" end
			count, target = count_field, target_field
		end
	end
	if not profile_id then profile_id, count = value, nil end
	if profile_id == "" then return nil, "empty profile id" end
	if #profile_id > M.MAX_ID_LENGTH then return nil, "profile id too long" end
	if not profile_id:match("^[%w_%-]+$") then return nil, "invalid profile id" end
	if count == nil then return { profile_id = profile_id }, nil end
	if not count:match("^[0-9]+$") then return nil, "invalid prediction count" end
	local n = tonumber(count)
	if n < M.MIN_PREDICTIONS or n > M.MAX_PREDICTIONS then
		return nil, "prediction count out of range"
	end
	return { profile_id = profile_id, num_predictions = n, translation_target = target }, nil
end

--- Tells whether a binding value is syntactically valid.
--- @param value string The stored parameter.
--- @return boolean ok True when parse() accepts it.
function M.is_valid(value)
	return M.parse(value) ~= nil
end

--- Builds a binding value.
--- @param profile_id string A valid profile id.
--- @param num_predictions number|nil A count of its own, or nil for the menu setting.
--- @return string value The encoded parameter.
function M.format(profile_id, num_predictions, translation_target)
	local value = num_predictions == nil and profile_id
		or (profile_id .. M.SEPARATOR .. tostring(num_predictions))
	if translation_target ~= nil then value = value .. M.SEPARATOR .. translation_target end
	local parsed, err = M.parse(value)
	if not parsed then error("prompt_action.format: " .. tostring(err)) end
	return value
end

return M
