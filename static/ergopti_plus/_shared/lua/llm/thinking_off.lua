--- _shared/lua/llm/thinking_off.lua

--- ==============================================================================
--- MODULE: Thinking Off — Shared Lua Implementation
--- DESCRIPTION:
--- Every request Ergopti sends to a cloud model turns its reasoning off, or
--- down to the lowest level the model accepts. Each provider of
--- _shared/modules/llm/api_providers.json lists, in `thinking_off`, ordered
--- rules { models = { glob, ... }, fields = { ... } }; this module picks the
--- rule of a model and deep-merges its fields into a request body.
---
--- FEATURES & RATIONALE:
--- 1. A glob matches the whole model id, case-insensitively; `*` is its only
---    wildcard. The first matching rule wins and no match adds nothing: an
---    unknown field is an HTTP 400 on a strict endpoint, so a model nobody
---    documented is sent as it is.
--- 2. A rule whose fields are empty matches and adds nothing: it shields a
---    model a broader glob below would otherwise reach.
--- 3. The merge is deep (Gemini's thinkingConfig sits inside the body's own
---    generationConfig) and the body wins at every level: a field the caller
---    set is never replaced.
--- 4. A malformed rule list is refused whole, never half-applied.
---
--- The AutoHotkey port is _shared/modules/llm/thinking_off.ahk. Both replay
--- _shared/tests/corpus/llm/thinking_off_vectors.json.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Characters a glob may hold: model ids plus the `*` wildcard
local GLOB_PATTERN = "^[%w%._:/@%+%-%*]+$"

-- A body field name: what every provider dialect uses
local FIELD_PATTERN = "^[A-Za-z_][A-Za-z0-9_]*$"




-- =============================================
-- =============================================
-- ======= 2/ Validation =======================
-- =============================================
-- =============================================

--- Tells whether a decoded value is a JSON object: every key a string. The
--- check is structural because each driver decodes with its own codec.
--- @param value any
--- @return boolean
local function is_object(value)
	if type(value) ~= "table" then return false end
	for key in pairs(value) do
		if type(key) ~= "string" then return false end
	end
	return true
end

--- Tells whether a decoded value is a non-empty JSON array.
--- @param value any
--- @return boolean
local function is_list(value)
	if type(value) ~= "table" or value[1] == nil then return false end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
		count = count + 1
	end
	return count == #value
end

--- Checks the fields of a rule: identifier names holding strings, numbers,
--- booleans or non-empty objects of the same.
--- @param fields any
--- @param allow_empty boolean True at the top level only.
--- @return boolean ok
local function fields_are_valid(fields, allow_empty)
	if not is_object(fields) then return false end
	if not allow_empty and next(fields) == nil then return false end
	for name, value in pairs(fields) do
		if not name:match(FIELD_PATTERN) then return false end
		local kind = type(value)
		if kind == "table" then
			if not fields_are_valid(value, false) then return false end
		elseif kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
			return false
		end
	end
	return true
end

--- Validates a provider's decoded `thinking_off` list.
--- @param raw any providers.<id>.thinking_off; nil when the provider has none.
--- @return table|nil rules Array of { models = { glob }, fields = table }.
--- @return string|nil reason Why the list is refused.
function M.parse(raw)
	if raw == nil or (type(raw) == "table" and next(raw) == nil) then return {}, nil end
	if not is_list(raw) then return nil, "thinking_off must be an array" end
	local rules = {}
	for index, rule in ipairs(raw) do
		if not is_object(rule) then return nil, "rule " .. index .. " is not an object" end
		for key in pairs(rule) do
			if key ~= "models" and key ~= "fields" and key:sub(1, 1) ~= "_" then
				return nil, "rule " .. index .. " has an unknown key " .. key
			end
		end
		if not is_list(rule.models) then
			return nil, "rule " .. index .. " names no model"
		end
		for _, glob in ipairs(rule.models) do
			if type(glob) ~= "string" or not glob:match(GLOB_PATTERN) then
				return nil, "rule " .. index .. " has an invalid glob"
			end
		end
		if not fields_are_valid(rule.fields, true) then
			return nil, "rule " .. index .. " has invalid fields"
		end
		rules[#rules + 1] = { models = rule.models, fields = rule.fields }
	end
	return rules, nil
end




-- =============================================
-- =============================================
-- ======= 3/ Matching =========================
-- =============================================
-- =============================================

--- Tells whether a glob matches a whole model id, ignoring case.
--- @param glob string Pattern whose only wildcard is `*`.
--- @param model string The model id.
--- @return boolean
function M.matches(glob, model)
	if type(glob) ~= "string" or type(model) ~= "string" then return false end
	local pattern, subject = glob:lower(), model:lower()
	local parts = {}
	for part in (pattern .. "*"):gmatch("([^*]*)%*") do parts[#parts + 1] = part end
	if #parts == 1 then return subject == parts[1] end
	local first, last = parts[1], parts[#parts]
	if subject:sub(1, #first) ~= first then return false end
	local position = #first + 1
	for i = 2, #parts - 1 do
		local found = subject:find(parts[i], position, true)
		if not found then return false end
		position = found + #parts[i]
	end
	return #subject - #last + 1 >= position and subject:sub(#subject - #last + 1) == last
end

--- Finds the rule of a model.
--- @param rules table parse() output.
--- @param model string The model id.
--- @return integer|nil index 1-based index of the first matching rule.
--- @return table|nil fields Its fields.
function M.resolve(rules, model)
	for index, rule in ipairs(type(rules) == "table" and rules or {}) do
		for _, glob in ipairs(rule.models) do
			if M.matches(glob, model) then return index, rule.fields end
		end
	end
	return nil, nil
end




-- =============================================
-- =============================================
-- ======= 4/ Merge ============================
-- =============================================
-- =============================================

--- Copies a rule value, so a request never shares a table with the catalogue.
--- @param value any
--- @return any
local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, nested in pairs(value) do result[key] = copy(nested) end
	return result
end

--- Deep-merges fields into a body; the body wins at every level.
--- @param body table The request body, changed in place.
--- @param fields table A rule's fields.
--- @return table body
function M.merge(body, fields)
	for name, value in pairs(fields) do
		local current = body[name]
		if current == nil then
			body[name] = copy(value)
		elseif type(value) == "table" and is_object(current) then
			M.merge(current, value)
		end
	end
	return body
end

--- Applies a model's rule to a body.
--- @param rules table parse() output.
--- @param model string The model id.
--- @param body table The request body, changed in place.
--- @return integer|nil index The rule applied, nil when none matched.
function M.apply(rules, model, body)
	if type(body) ~= "table" then error("thinking_off.apply: the body must be a table", 2) end
	local index, fields = M.resolve(rules, model)
	if index then M.merge(body, fields) end
	return index
end

return M
