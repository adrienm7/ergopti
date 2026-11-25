--- _shared/shortcuts/engine/workflows/model.lua

--- ==============================================================================
--- MODULE: User Workflow Model (Shared)
--- DESCRIPTION:
--- The macOS and Linux check of a user workflow file against
--- _shared/shortcuts/data/workflows/steps.json, the placeholder expansion of
--- step texts and the digest a shell approval is bound to. The canonical JS
--- check (_shared/ui/workflow_model.js) and the AutoHotkey port
--- replay the same _shared/tests/corpus/workflows/ vectors.
---
--- FEATURES & RATIONALE:
--- 1. Closed key sets and one deterministic order: keys and fields are
---    visited sorted, so the first refusal and its JSON Pointer are the same
---    as in JavaScript, whose object order differs from a Lua table's.
--- 2. A document is decoded with Json.decode_lossless, which keeps an empty
---    array apart from an empty object and a null apart from an absent key, as
---    JSON.parse does in the editor.
--- 3. A key combination uses the send_shortcut grammar of send_keys.json
---    (platform.input.send_input), never a second vocabulary.
--- 4. A shell command never takes placeholders: OCR or clipboard text would
---    otherwise become shell syntax. The variables reach the command as
---    environment variables instead (interpreter.lua).
--- 5. Pure: no logger, no i18n, no I/O; callers report and localize.
--- ==============================================================================

local Json = require("core.text.engine.json")
local SendInput = require("platform.input.send_input")
local Sha256 = require("core.crypto.engine.sha256")

local M = {}

--- Where the catalogue lives under _shared/.
M.CATALOGUE_PATH = "shortcuts/data/workflows/steps.json"

-- The byte bounds of the control characters, and the ones a multiline text keeps.
local LAST_CONTROL_BYTE = 31
local DELETE_BYTE = 127
local MULTILINE_BYTES = { [9] = true, [10] = true, [13] = true }

local ACTION_PATTERN_HEAD = "^[a-z][a-z0-9_]*$"
local ACTION_MAX_BYTES = 64
local BASE64_QUANTUM = 4




-- ========================================
-- ========================================
-- ======= 1/ Value shapes ================
-- ========================================
-- ========================================

--- @param value any
--- @return boolean Whether value is a decoded JSON object.
local function is_object(value)
	return type(value) == "table" and not Json.is_array(value) and not Json.is_null(value)
end

--- @param value any
--- @return boolean Whether value is a decoded JSON array.
local function is_list(value)
	return Json.is_array(value)
end

--- @param value any
--- @return boolean Whether value is an integral finite number.
local function is_integer(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
		and value == math.floor(value)
end

--- Whether a byte string is valid UTF-8 (no surrogate, no overlong form).
--- @param text string
--- @return boolean
local function valid_utf8(text)
	local index, size = 1, #text
	while index <= size do
		local byte = text:byte(index)
		local extra, minimum
		if byte < 0x80 then extra, minimum = 0, 0
		elseif byte >= 0xC2 and byte <= 0xDF then extra, minimum = 1, 0x80
		elseif byte >= 0xE0 and byte <= 0xEF then extra, minimum = 2, 0x800
		elseif byte >= 0xF0 and byte <= 0xF4 then extra, minimum = 3, 0x10000
		else return false end
		if index + extra > size then return false end
		local code = extra == 0 and byte or (byte % (2 ^ (6 - extra)))
		for offset = 1, extra do
			local next_byte = text:byte(index + offset)
			if next_byte < 0x80 or next_byte > 0xBF then return false end
			code = code * 64 + (next_byte - 0x80)
		end
		if code < minimum or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then return false end
		index = index + extra + 1
	end
	return true
end

--- Whether a string holds a control byte a field refuses.
--- @param text string
--- @param multiline boolean
--- @return boolean
local function has_forbidden_control(text, multiline)
	for index = 1, #text do
		local byte = text:byte(index)
		if byte == DELETE_BYTE then return true end
		if byte <= LAST_CONTROL_BYTE and not (multiline and MULTILINE_BYTES[byte]) then return true end
	end
	return false
end

--- Escapes one JSON Pointer segment (RFC 6901).
--- @param segment string|number
--- @return string
local function pointer_segment(segment)
	return (tostring(segment):gsub("~", "~0"):gsub("/", "~1"))
end

--- The sorted string keys of an object.
--- @param value table
--- @return table
local function sorted_keys(value)
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

--- A set of the given lists' strings.
--- @return table
local function key_set(...)
	local set = {}
	for _, list in ipairs({ ... }) do
		for _, key in ipairs(list) do set[key] = true end
	end
	return set
end

--- Whether a Lua pattern-free identifier matches steps.json's pattern
--- ^[A-Za-z_][A-Za-z0-9_]{0,31}$ (the pattern is checked equal at load).
--- @param value string
--- @return boolean
local function is_identifier(value)
	return #value <= 32 and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

--- ^[A-Za-z0-9_-]{1,64}$
--- @param value string
--- @return boolean
local function is_workflow_id(value)
	return #value >= 1 and #value <= 64 and value:match("^[A-Za-z0-9_%-]+$") ~= nil
end




-- ========================================
-- ========================================
-- ======= 2/ Checker =====================
-- ========================================
-- ========================================

-- The patterns this port spells by hand, held to the catalogue's text.
local EXPECTED_PATTERNS = {
	identifier_pattern = "^[A-Za-z_][A-Za-z0-9_]{0,31}$",
	workflow_id_pattern = "^[A-Za-z0-9_-]{1,64}$",
}

--- Raises unless the catalogue is the decoded steps.json this port reads.
--- @param catalogue table
local function require_catalogue(catalogue)
	if type(catalogue) ~= "table" or type(catalogue.kinds) ~= "table" or type(catalogue.limits) ~= "table" then
		error("workflows.model: the catalogue is not the decoded steps.json", 3)
	end
	for name, pattern in pairs(EXPECTED_PATTERNS) do
		if catalogue[name] ~= pattern then
			error("workflows.model: steps.json changed " .. name .. "; port the new pattern", 3)
		end
	end
end

--- Builds the checker of one catalogue and context.
--- @param catalogue table Decoded steps.json.
--- @param context table { vocabulary = decoded send_keys.json, timings = { wait_max_ms } }.
--- @return table checker
local function new_checker(catalogue, context)
	require_catalogue(catalogue)
	if type(context) ~= "table" or type(context.vocabulary) ~= "table" or type(context.timings) ~= "table" then
		error("workflows.model: a check needs the send_keys vocabulary and the timings", 3)
	end
	local limits = catalogue.limits
	local reasons = key_set(catalogue.reasons)
	local REFUSAL = {}

	local function refuse(reason, path)
		if not reasons[reason] then error("workflows.model: undeclared reason " .. tostring(reason), 2) end
		error({ [REFUSAL] = true, reason = reason, path = path }, 0)
	end

	local function bound(name)
		if limits[name] ~= nil then return limits[name] end
		if context.timings[name] ~= nil then return context.timings[name] end
		error("workflows.model: no bound named " .. tostring(name), 2)
	end

	local function check_keys(value, allowed, path)
		for _, key in ipairs(sorted_keys(value)) do
			if not allowed[key] then refuse("unknown_key", path .. "/" .. pointer_segment(key)) end
		end
	end

	local function check_text(value, spec, path, maximum)
		if type(value) ~= "string" then refuse("bad_type", path) end
		if not valid_utf8(value) then refuse("bad_text", path) end
		if #value > maximum then refuse("too_long", path) end
		if value == "" and not spec.allow_empty then refuse("bad_text", path) end
		if has_forbidden_control(value, spec.multiline == true) then refuse("bad_text", path) end
	end

	local check_value, check_steps

	local function check_fields(value, fields, path, state)
		for _, name in ipairs(sorted_keys(fields)) do
			local spec = fields[name]
			local field_path = path .. "/" .. pointer_segment(name)
			if value[name] == nil then
				if spec.required then refuse("missing_field", field_path) end
			else
				check_value(value[name], spec, field_path, state)
			end
		end
	end

	local function check_typed(value, table_of_types, path, state)
		if not is_object(value) then refuse("not_object", path) end
		if value.type == nil then refuse("missing_field", path .. "/type") end
		if type(value.type) ~= "string" then refuse("bad_type", path .. "/type") end
		local declared = table_of_types[value.type]
		if declared == nil then refuse("bad_enum", path .. "/type") end
		local fields = declared.fields or declared
		check_keys(value, key_set({ "type" }, sorted_keys(fields)), path)
		check_fields(value, fields, path, state)
		if value.type == "matches" then
			if value.source == "variable" and value.variable == nil then refuse("variable_required", path .. "/variable") end
			if value.op ~= "empty" and value.value == nil then refuse("value_required", path .. "/value") end
		end
	end

	function check_value(value, spec, path, state)
		local kind = spec.type
		if kind == "text" then
			check_text(value, spec, path, limits.text_bytes)
		elseif kind == "shortcut" then
			if type(value) ~= "string" then refuse("bad_type", path) end
			if not SendInput.parse_shortcut(value, context.vocabulary) then refuse("bad_shortcut", path) end
		elseif kind == "integer" then
			if not is_integer(value) then refuse("bad_type", path) end
			local maximum = spec.max_limit ~= nil and bound(spec.max_limit) or spec.max
			if value < spec.min or value > maximum then refuse("out_of_range", path) end
		elseif kind == "enum" then
			if type(value) ~= "string" then refuse("bad_type", path) end
			if not key_set(spec.values)[value] then refuse("bad_enum", path) end
		elseif kind == "variable" then
			if type(value) ~= "string" then refuse("bad_type", path) end
			if not is_identifier(value) then refuse("bad_identifier", path) end
			if not state.variables[value] then
				state.variables[value] = true
				state.variable_count = state.variable_count + 1
			end
			if state.variable_count > limits.variables_max then refuse("too_many_variables", path) end
		elseif kind == "action" then
			if type(value) ~= "string" then refuse("bad_type", path) end
			if #value > ACTION_MAX_BYTES or not value:match(ACTION_PATTERN_HEAD) then refuse("bad_identifier", path) end
		elseif kind == "image" then
			if type(value) ~= "string" then refuse("bad_type", path) end
			if not is_identifier(value) then refuse("bad_identifier", path) end
			if state.images[value] == nil then refuse("unknown_image", path) end
		elseif kind == "target" then
			check_typed(value, catalogue.targets, path, state)
		elseif kind == "condition" then
			check_typed(value, catalogue.conditions, path, state)
		elseif kind == "steps" then
			check_steps(value, path, state.depth + 1, state)
		else
			error("workflows.model: no field type " .. tostring(kind), 2)
		end
	end

	local function check_step(step, path, depth, state)
		if not is_object(step) then refuse("not_object", path) end
		if depth > limits.depth_max then refuse("too_deep", path) end
		state.count = state.count + 1
		if state.count > limits.steps_max then refuse("too_many_steps", state.steps_path) end
		if step.kind == nil then refuse("missing_field", path .. "/kind") end
		if type(step.kind) ~= "string" then refuse("bad_type", path .. "/kind") end
		local declared = catalogue.kinds[step.kind]
		if declared == nil then refuse("unknown_kind", path .. "/kind") end
		check_keys(step, key_set(catalogue.common_step_keys, sorted_keys(declared.fields)), path)
		if step.note ~= nil then check_text(step.note, {}, path .. "/note", limits.name_bytes) end
		local outer = state.depth
		state.depth = depth
		check_fields(step, declared.fields, path, state)
		state.depth = outer
	end

	function check_steps(list, path, depth, state)
		if not is_list(list) then refuse("bad_type", path) end
		for index, step in ipairs(list) do check_step(step, path .. "/" .. (index - 1), depth, state) end
	end

	local function check_images(images, path)
		if not is_object(images) then refuse("not_object", path) end
		local names = sorted_keys(images)
		if #names > limits.images_max then refuse("too_many_images", path) end
		for _, name in ipairs(names) do
			local image_path = path .. "/" .. pointer_segment(name)
			local data = images[name]
			if not is_identifier(name) then refuse("bad_identifier", image_path) end
			if type(data) ~= "string" then refuse("bad_type", image_path) end
			if #data > limits.image_base64_bytes then refuse("too_long", image_path) end
			if not data:match("^[A-Za-z0-9+/]+=?=?$") or #data % BASE64_QUANTUM ~= 0
				or data:sub(1, #catalogue.png_base64_prefix) ~= catalogue.png_base64_prefix then
				refuse("bad_image", image_path)
			end
		end
	end

	local checker = {}

	function checker.workflow(workflow, path)
		if not is_object(workflow) then refuse("not_object", path) end
		check_keys(workflow, key_set(catalogue.workflow_keys), path)
		for _, name in ipairs({ "id", "name", "origin", "steps" }) do
			if workflow[name] == nil then refuse("missing_field", path .. "/" .. name) end
		end
		if type(workflow.id) ~= "string" then refuse("bad_type", path .. "/id") end
		if not is_workflow_id(workflow.id) then refuse("bad_identifier", path .. "/id") end
		check_text(workflow.name, {}, path .. "/name", limits.name_bytes)
		if type(workflow.origin) ~= "string" then refuse("bad_type", path .. "/origin") end
		if not key_set(catalogue.origins)[workflow.origin] then refuse("bad_enum", path .. "/origin") end
		local images = workflow.images or {}
		if workflow.images ~= nil then check_images(images, path .. "/images") end
		local state = { count = 0, depth = 0, images = images, variables = {}, variable_count = 0,
			steps_path = path .. "/steps" }
		check_steps(workflow.steps, path .. "/steps", 1, state)
	end

	function checker.file(doc)
		if not is_object(doc) then refuse("not_object", "") end
		check_keys(doc, key_set({ "schema_version", "workflows" }), "")
		if doc.schema_version ~= catalogue.schema_version then refuse("schema_version", "/schema_version") end
		if doc.workflows == nil then refuse("missing_field", "/workflows") end
		if not is_list(doc.workflows) then refuse("bad_type", "/workflows") end
		if #doc.workflows > limits.workflows_max then refuse("too_many_workflows", "/workflows") end
		local seen = {}
		for index, workflow in ipairs(doc.workflows) do
			local path = "/workflows/" .. (index - 1)
			checker.workflow(workflow, path)
			if seen[workflow.id] then refuse("duplicate_id", path .. "/id") end
			seen[workflow.id] = true
		end
	end

	--- Runs one check and turns a refusal into a result.
	--- @param body function
	--- @return table { ok, reason, path }
	function checker.outcome(body, ...)
		local ok, err = pcall(body, ...)
		if ok then return { ok = true } end
		if type(err) == "table" and err[REFUSAL] then return { ok = false, reason = err.reason, path = err.path } end
		error(err, 0)
	end

	return checker
end




-- ========================================
-- ========================================
-- ======= 3/ Public API ==================
-- ========================================
-- ========================================

--- Checks a whole workflow file, decoded with Json.decode_lossless.
--- @param doc any
--- @param catalogue table Decoded steps.json.
--- @param context table { vocabulary, timings }.
--- @return table { ok = boolean, reason = string|nil, path = string|nil }
function M.validate_file(doc, catalogue, context)
	local checker = new_checker(catalogue, context)
	return checker.outcome(checker.file, doc)
end

--- Checks one workflow, its refusal path rooted at the workflow.
--- @param workflow any
--- @param catalogue table Decoded steps.json.
--- @param context table { vocabulary, timings }.
--- @return table { ok, reason, path }
function M.validate_workflow(workflow, catalogue, context)
	local checker = new_checker(catalogue, context)
	return checker.outcome(checker.workflow, workflow, "")
end

--- Expands the {{name}} placeholders of a step text.
--- A {{ that does not open an identifier closed by }} stays text.
--- @param text string
--- @param variables table name -> string.
--- @return string|nil expanded
--- @return string|nil missing The first unknown variable name.
function M.expand(text, variables)
	local out, index = {}, 1
	while true do
		local open = text:find("{{", index, true)
		if not open then
			out[#out + 1] = text:sub(index)
			break
		end
		local close = text:find("}}", open + 2, true)
		local name = close and text:sub(open + 2, close - 1)
		if name and is_identifier(name) then
			local value = variables[name]
			if value == nil then return nil, name end
			out[#out + 1] = text:sub(index, open - 1)
			out[#out + 1] = value
			index = close + 2
		else
			out[#out + 1] = text:sub(index, open + 1)
			index = open + 2
		end
	end
	return table.concat(out)
end

--- The shell commands of a workflow, in document order (then before else).
--- @param steps table
--- @param out table|nil Accumulator.
--- @return table
function M.shell_commands(steps, out)
	out = out or {}
	for _, step in ipairs(steps or {}) do
		if step.kind == "shell" then out[#out + 1] = step.command end
		if step.kind == "if" then
			M.shell_commands(step["then"], out)
			M.shell_commands(step["else"], out)
		elseif step.kind == "repeat" then
			M.shell_commands(step.steps, out)
		end
	end
	return out
end

--- The digest a shell approval is bound to: SHA-256 of the workflow id, then
--- each shell command after a NUL byte, in document order. nil without a
--- shell step. Any edit of a command, or another id, changes it.
--- @param workflow table A valid workflow.
--- @return string|nil hex
function M.shell_digest(workflow)
	local commands = M.shell_commands(workflow.steps)
	if #commands == 0 then return nil end
	return Sha256.hex(workflow.id .. "\0" .. table.concat(commands, "\0"))
end

return M
