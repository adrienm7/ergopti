--- _shared/lua/llm/thinking_off.lua

--- ==============================================================================
--- MODULE: Thinking Off — Shared Lua Implementation
--- DESCRIPTION:
--- Every request Ergopti sends to a model turns its reasoning off, or down to
--- the lowest level the model accepts. What a model needs depends on its
--- FAMILY (_shared/modules/llm/thinking_off.json); how a request carries it
--- depends on the PROVIDER (thinking_dialect of api_providers.json). This
--- module crosses the two into body fields and deep-merges them.
---
--- FEATURES & RATIONALE:
--- 1. A model id is normalized (lowercase, last path segment, an Ollama
---    :tag dropped), so a qwen3 model gets the same family on Groq, Cerebras,
---    OpenRouter, Together or Fireworks with no per-provider model list.
--- 2. The first family whose glob (`*` its only wildcard) matches wins. Its
---    controls are tried in order; the first kind the provider's dialect
---    carries applies, with the string "$level" replaced by the control's
---    level. A family with no control, or a provider without the kind, sends
---    nothing: an unknown field is an HTTP 400 on a strict endpoint.
--- 3. The merge is deep and the body wins at every level; it reports the
---    paths it added, so a provider refusing one of them (HTTP 400 naming it)
---    can be asked once more without it (refused_field, strip).
--- 4. A malformed table is refused whole, never half-applied.
--- 5. Refused fields persist (refusals_parse, refusals_export): a model a
---    provider refused once is never sent that field again, even after a
---    restart. The store is bounded; each driver owns where it lives.
--- 6. A family may say its models accept only the default sampling
---    (default_sampling_only): the drivers then send no temperature.
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

-- The placeholder a dialect template holds for the family's level
M.LEVEL = "$level"

-- The reasoning control kinds; a toggle carries no level
M.KINDS = {
	toggle = true, effort = true, anthropic_thinking = true,
	anthropic_effort = true, gemini_budget = true, gemini_level = true,
}

-- What a control asks for
local INTENTS = { off = true, lowest = true }

-- Most (provider, model) pairs whose refusals persist
M.MAX_REFUSALS = 200




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

--- Tells whether a decoded value is a JSON array (an empty table counts).
--- @param value any
--- @return boolean
local function is_list(value)
	if type(value) ~= "table" then return false end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
		count = count + 1
	end
	return count == #value
end

--- Checks body fields: identifier names holding strings, numbers, booleans or
--- non-empty objects of the same.
--- @param fields any
--- @return boolean ok
local function fields_are_valid(fields)
	if not is_object(fields) or next(fields) == nil then return false end
	for name, value in pairs(fields) do
		if not name:match(FIELD_PATTERN) then return false end
		local kind = type(value)
		if kind == "table" then
			if not fields_are_valid(value) then return false end
		elseif kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
			return false
		end
	end
	return true
end

--- Tells whether a template holds the level placeholder.
--- @param fields table
--- @return boolean
local function holds_level(fields)
	for _, value in pairs(fields) do
		if value == M.LEVEL or (type(value) == "table" and holds_level(value)) then return true end
	end
	return false
end

--- Validates the decoded thinking_off.json.
--- @param raw any
--- @return table|nil families Array of { models = { glob }, controls = { { kind, intent, level } } }.
--- @return string|nil reason Why the table is refused.
function M.parse_families(raw)
	if not is_object(raw) or not is_list(raw.families) or raw.families[1] == nil then
		return nil, "thinking_off.json holds no families array"
	end
	local families = {}
	for index, family in ipairs(raw.families) do
		local where = "family " .. index
		if not is_object(family) then return nil, where .. " is not an object" end
		for key in pairs(family) do
			if key ~= "models" and key ~= "controls" and key ~= "default_sampling_only" and key:sub(1, 1) ~= "_" then
				return nil, where .. " has an unknown key " .. key
			end
		end
		if not is_list(family.models) or family.models[1] == nil then return nil, where .. " names no model" end
		for _, glob in ipairs(family.models) do
			if type(glob) ~= "string" or not glob:match(GLOB_PATTERN) then return nil, where .. " has an invalid glob" end
		end
		if not is_list(family.controls) then return nil, where .. " has no controls array" end
		if family.default_sampling_only ~= nil and type(family.default_sampling_only) ~= "boolean" then
			return nil, where .. ": default_sampling_only must be a boolean"
		end
		local controls = {}
		for _, control in ipairs(family.controls) do
			if not is_object(control) or not M.KINDS[control.kind] or not INTENTS[control.intent] then
				return nil, where .. " has an invalid control"
			end
			local level, level_type = control.level, type(control.level)
			if control.kind == "toggle" then
				if level ~= nil or control.intent ~= "off" then return nil, where .. ": a toggle only turns off" end
			elseif level_type ~= "string" and level_type ~= "number" then
				return nil, where .. ": a " .. control.kind .. " control needs a level"
			end
			controls[#controls + 1] = { kind = control.kind, intent = control.intent, level = level }
		end
		families[#families + 1] = { models = family.models, controls = controls,
			default_sampling_only = family.default_sampling_only == true }
	end
	return families, nil
end

--- Validates a provider's decoded thinking_dialect.
--- @param raw any providers.<id>.thinking_dialect; nil when the provider has none.
--- @return table|nil dialect kind -> fields template.
--- @return string|nil reason Why the dialect is refused.
function M.parse_dialect(raw)
	if raw == nil then return {}, nil end
	if not is_object(raw) then return nil, "thinking_dialect must be an object" end
	local dialect = {}
	for kind, fields in pairs(raw) do
		if kind:sub(1, 1) ~= "_" then
			if not M.KINDS[kind] then return nil, "thinking_dialect has an unknown kind " .. kind end
			if not fields_are_valid(fields) then return nil, "thinking_dialect." .. kind .. " has invalid fields" end
			if (kind == "toggle") == holds_level(fields) then
				return nil, "thinking_dialect." .. kind .. (kind == "toggle" and " cannot hold a level" or " needs a level")
			end
			dialect[kind] = fields
		end
	end
	return dialect, nil
end




-- =============================================
-- =============================================
-- ======= 3/ Matching =========================
-- =============================================
-- =============================================

--- Normalizes a model id for matching: lowercase, its last path segment
--- (openai/gpt-5.1 -> gpt-5.1), an Ollama :tag dropped.
--- @param model string
--- @return string
function M.normalize(model)
	local name = tostring(model):lower():match("([^/]*)$")
	return (name:gsub(":.*$", ""))
end

--- Tells whether a glob matches a whole normalized model id, ignoring case.
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
		if parts[i] ~= "" then
			local found = subject:find(parts[i], position, true)
			if not found then return false end
			position = found + #parts[i]
		end
	end
	return #subject - #last + 1 >= position and subject:sub(#subject - #last + 1) == last
end

--- Finds the family of a model.
--- @param families table parse_families() output.
--- @param model string The model id.
--- @return integer|nil index, table|nil family
local function family_of(families, model)
	local name = M.normalize(model)
	for index, family in ipairs(families) do
		for _, glob in ipairs(family.models) do
			if M.matches(glob, name) then return index, family end
		end
	end
	return nil, nil
end

--- Tells whether a model accepts only the default sampling: a request to it
--- must carry no temperature (an HTTP 400 otherwise).
--- @param families table parse_families() output.
--- @param model string The model id.
--- @return boolean
function M.default_sampling_only(families, model)
	local _, family = family_of(families, model)
	return family ~= nil and family.default_sampling_only == true
end

--- Copies a template with the level placeholder filled.
--- @param value any
--- @param level any
--- @return any
local function fill(value, level)
	if value == M.LEVEL then return level end
	if type(value) ~= "table" then return value end
	local result = {}
	for key, nested in pairs(value) do result[key] = fill(nested, level) end
	return result
end

--- Resolves the fields a model needs on a provider.
--- @param families table parse_families() output.
--- @param dialect table parse_dialect() output.
--- @param model string The model id as the request names it.
--- @param refused table|nil Set of top-level field names refused for this provider and model.
--- @return integer|nil family 1-based index of the matching family.
--- @return string|nil kind The control kind applied, nil when none is carried.
--- @return table|nil fields The body fields, nil when nothing applies.
function M.resolve(families, dialect, model, refused)
	local index, family = family_of(families, model)
	if not family then return nil, nil, nil end
	for _, control in ipairs(family.controls) do
		local template = dialect[control.kind]
		if template then
			local fields = fill(template, control.level)
			for field in pairs(refused or {}) do fields[field] = nil end
			if next(fields) == nil then return index, control.kind, nil end
			return index, control.kind, fields
		end
	end
	return index, nil, nil
end




-- =============================================
-- =============================================
-- ======= 4/ Merge And Refusal ================
-- =============================================
-- =============================================

--- Deep-merges fields into a body; the body wins at every level.
--- @param body table The request body, changed in place.
--- @param fields table Body fields.
--- @param prefix table|nil Path of body inside the request (internal).
--- @param added table|nil Paths added so far (internal).
--- @return table added Paths added, each an array of field names.
function M.merge(body, fields, prefix, added)
	prefix, added = prefix or {}, added or {}
	for name, value in pairs(fields) do
		local path = {}
		for i, segment in ipairs(prefix) do path[i] = segment end
		path[#path + 1] = name
		local current = body[name]
		if current == nil then
			-- A copy: a request never shares a table with the catalogue
			body[name] = fill(value, M.LEVEL)
			added[#added + 1] = path
		elseif type(value) == "table" and is_object(current) then
			M.merge(current, value, path, added)
		end
	end
	return added
end

--- Applies a model's family through a provider's dialect to a body.
--- @param families table parse_families() output.
--- @param dialect table parse_dialect() output.
--- @param model string The model id.
--- @param body table The request body, changed in place.
--- @param refused table|nil Refused top-level field names for this provider and model.
--- @return integer|nil family The matching family.
--- @return string|nil kind The control kind applied.
--- @return table added Paths added to the body.
function M.apply(families, dialect, model, body, refused)
	if type(body) ~= "table" then error("thinking_off.apply: the body must be a table", 2) end
	local family, kind, fields = M.resolve(families, dialect, model, refused)
	return family, kind, fields and M.merge(body, fields) or {}
end

-- Added keys too generic to name a refusal alone: matched with their parent
local GENERIC_KEYS = { type = true, effort = true, enabled = true }

--- Tells whether a provider message names a key, snake or camel case.
--- @param text string Lowercase message.
--- @param name string
--- @return boolean
local function names(text, name)
	local snake = name:gsub("(%l)(%u)", "%1_%2"):lower()
	return text:find(name:lower(), 1, true) ~= nil or text:find(snake, 1, true) ~= nil
end

--- Names the top-level field a provider refused, when its HTTP 400 message
--- names a key apply() added (a generic leaf such as type as parent.leaf).
--- @param status any The HTTP status.
--- @param message any The provider's error message.
--- @param added table Paths apply() added.
--- @return string|nil field The refused top-level field.
function M.refused_field(status, message, added)
	if tonumber(status) ~= 400 or type(message) ~= "string" or type(added) ~= "table" then return nil end
	local text = message:lower()
	for _, path in ipairs(added) do
		local leaf = path[#path]
		local key = (GENERIC_KEYS[leaf] and #path > 1) and (path[#path - 1] .. "." .. leaf) or leaf
		if names(text, key) then return path[1] end
	end
	return nil
end

--- Removes the added paths under a refused top-level field.
--- @param body table The request body, changed in place.
--- @param added table Paths apply() added.
--- @param field string The refused top-level field.
--- @return table body
function M.strip(body, added, field)
	for _, path in ipairs(added) do
		if path[1] == field then
			local node = body
			for i = 1, #path - 1 do node = type(node) == "table" and node[path[i]] or nil end
			if type(node) == "table" then node[path[#path]] = nil end
		end
	end
	return body
end

--- Reads a persisted refusal store: "<provider>|<model>" -> array of field
--- names. Malformed entries are dropped, and counted for the driver's log.
--- @param raw any The decoded store.
--- @return table refused key -> set of field names.
--- @return integer dropped Entries that were not kept.
function M.refusals_parse(raw)
	local refused, dropped, count = {}, 0, 0
	if type(raw) ~= "table" then return refused, raw == nil and 0 or 1 end
	for key, fields in pairs(raw) do
		local set = {}
		if type(key) == "string" and key:find("|", 1, true) and is_list(fields) and count < M.MAX_REFUSALS then
			for _, field in ipairs(fields) do
				if type(field) == "string" and field:match(FIELD_PATTERN) then set[field] = true end
			end
		end
		if next(set) then
			refused[key] = set
			count = count + 1
		else
			dropped = dropped + 1
		end
	end
	return refused, dropped
end

--- Records a refused field. The store keeps at most MAX_REFUSALS pairs: a
--- pair beyond them is refused (the caller still skips the field this session).
--- @param refused table key -> set of field names, changed in place.
--- @param provider string
--- @param model string
--- @param field string
--- @return boolean stored False when the store is full.
function M.record_refusal(refused, provider, model, field)
	local key = provider .. "|" .. model
	if not refused[key] then
		local count = 0
		for _ in pairs(refused) do count = count + 1 end
		if count >= M.MAX_REFUSALS then return false end
		refused[key] = {}
	end
	refused[key][field] = true
	return true
end

--- The refusal store as plain data: key -> sorted array of field names.
--- @param refused table key -> set of field names.
--- @return table
function M.refusals_export(refused)
	local out = {}
	for key, set in pairs(refused) do
		local fields = {}
		for field in pairs(set) do fields[#fields + 1] = field end
		table.sort(fields)
		out[key] = fields
	end
	return out
end

return M
