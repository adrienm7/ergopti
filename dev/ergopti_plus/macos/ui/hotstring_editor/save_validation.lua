--- ui/hotstring_editor/save_validation.lua

--- ==============================================================================
--- MODULE: Hotstring Editor Save Validation
--- DESCRIPTION:
--- Validates the complete bridge document before conversion can discard fields.
--- ==============================================================================

local M = {}
local BOOLEAN_FIELDS = { "is_word", "auto_expand", "is_case_sensitive", "final_result", "is_case_sensitive_strict" }

--- Checks a dense sequence without trusting the length of a sparse table.
--- @param value any Candidate sequence.
--- @return boolean dense
local function is_sequence(value)
	if type(value) ~= "table" then return false end
	local count, length = 0, #value
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then return false end
		count = count + 1
	end
	return count == length
end

--- Rejects malformed data as one document, never as a partial successful save.
--- @param data any Native bridge save payload.
--- @return boolean valid
--- @return string? reason Fixed diagnostic category, never payload content.
function M.validate(data)
	if type(data) ~= "table" then return false, "document" end
	if not is_sequence(data.sections_order) then return false, "section order" end
	if type(data.sections) ~= "table" then return false, "section map" end
	local seen = {}
	for _, name in ipairs(data.sections_order) do
		if type(name) ~= "string" or name == "" then return false, "section name" end
		if name ~= "-" then
			if seen[name] then return false, "duplicate section" end
			seen[name] = true
			local section = data.sections[name]
			if type(section) ~= "table" then return false, "section" end
			if section.description ~= nil and type(section.description) ~= "string" then return false, "description" end
			if not is_sequence(section.entries) then return false, "entry sequence" end
			for _, entry in ipairs(section.entries) do
				if type(entry) ~= "table" or type(entry.trigger) ~= "string" or type(entry.output) ~= "string" then
					return false, "entry"
				end
				for _, flag in ipairs(BOOLEAN_FIELDS) do
					if entry[flag] ~= nil and type(entry[flag]) ~= "boolean" then return false, "entry flag" end
				end
				local priority = entry.priority
				if priority ~= nil and (type(priority) ~= "number" or priority ~= priority or math.abs(priority) == math.huge) then
					return false, "priority"
				end
			end
		end
	end
	for name in pairs(data.sections) do
		if not seen[name] then return false, "unlisted section" end
	end
	return true
end

return M
