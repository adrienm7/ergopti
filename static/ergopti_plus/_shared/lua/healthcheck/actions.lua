--- _shared/lua/healthcheck/actions.lua

--- ==============================================================================
--- MODULE: Diagnostics Page Actions (Shared Lua)
--- DESCRIPTION:
--- Validates what the diagnostics page asks its host to do, before the host
--- does it: copy a text, save it, open the GitHub bug form, open a folder or a
--- system settings page, collect again, close. The page is a web page, so a
--- message is untrusted input; the host never opens a path, a URL or a file
--- name it did not produce or allow itself.
---
--- FEATURES & RATIONALE:
--- 1. Ids, never paths or URLs: open_path names a path field of the schema
---    (_shared/modules/diagnostics/schema.json) and the host opens the value it
---    collected; open_settings names a permission whose settings page the
---    schema declares for this driver.
--- 2. Bounded text: a copied, saved or reported text is a non-empty string of
---    at most max_export_bytes UTF-8 bytes.
--- 3. A saved file keeps the report's prefix and suffix and only file-name-safe
---    characters, so it cannot leave the diagnostics folder.
--- 4. A report prefills only the fields of the bug form
---    (_shared/modules/diagnostics/issue_templates.json), except its
---    report_field: the host fills that one with the report text itself.
--- 5. A refusal returns a stable reason code for the host to log. The AHK port
---    (windows/ui/healthcheck/actions.ahk) replays the same vectors
---    (_shared/tests/corpus/healthcheck/action_vectors.json).
--- ==============================================================================

local M = {}





-- =================================
-- =================================
-- ======= 1/ Allowed Values =======
-- =================================
-- =================================

-- Every action the page may send, with the validator of its arguments
local VALIDATORS = {}

--- True when a value is a string of 1..max UTF-8 bytes.
--- @param value any
--- @param max number
--- @return boolean
local function bounded_text(value, max)
	return type(value) == "string" and #value > 0 and #value <= max
end

--- The ids of the schema's path fields that apply to a driver.
--- @param schema table
--- @param driver string
--- @return table Set of ids.
local function path_ids(schema, driver)
	local ids = {}
	for _, section in ipairs(schema.sections or {}) do
		for _, field in ipairs(section.fields or {}) do
			local applies = type(field.platforms) ~= "table"
			for _, platform in ipairs(field.platforms or {}) do
				if platform == driver then applies = true end
			end
			if field.type == "path" and applies then ids[field.id] = true end
		end
	end
	return ids
end

--- True when a report file name keeps the schema's prefix and suffix and only
--- file-name-safe characters in between.
--- @param name any
--- @param report table schema.report
--- @return boolean
local function valid_name(name, report)
	if type(name) ~= "string" or #name > report.name_max_length then return false end
	local prefix, suffix = report.name_prefix, report.name_suffix
	if #name <= #prefix + #suffix then return false end
	if name:sub(1, #prefix) ~= prefix or name:sub(-#suffix) ~= suffix then return false end
	return name:sub(#prefix + 1, -#suffix - 1):match("^[A-Za-z0-9._%-]+$") ~= nil
end





-- =============================
-- =============================
-- ======= 2/ Validators =======
-- =============================
-- =============================

function VALIDATORS.copy(message, context)
	if not bounded_text(message.text, context.schema.max_export_bytes) then return nil, "bad_text" end
	return { action = "copy", text = message.text }
end

function VALIDATORS.save(message, context)
	if not bounded_text(message.text, context.schema.max_export_bytes) then return nil, "bad_text" end
	if not valid_name(message.name, context.schema.report) then return nil, "bad_name" end
	return { action = "save", text = message.text, name = message.name }
end

function VALIDATORS.report(message, context)
	local limit = context.schema.max_export_bytes
	if not bounded_text(message.text, limit) then return nil, "bad_text" end
	if type(message.fields) ~= "table" then return nil, "bad_fields" end
	local bug = context.templates.templates.bug
	local allowed = {}
	for _, id in ipairs(bug.fields) do allowed[id] = true end
	-- The host fills the report field with the text itself
	allowed[bug.report_field] = nil
	local fields = {}
	for id, value in pairs(message.fields) do
		if not allowed[id] then return nil, "unknown_field" end
		if not bounded_text(value, limit) then return nil, "bad_fields" end
		fields[id] = value
	end
	return { action = "report", text = message.text, fields = fields }
end

function VALIDATORS.open_path(message, context)
	if type(message.id) ~= "string" or not path_ids(context.schema, context.driver)[message.id] then
		return nil, "unknown_path"
	end
	return { action = "open_path", id = message.id }
end

function VALIDATORS.open_settings(message, context)
	local permissions = (context.schema.permissions or {})[context.driver] or {}
	local entry = type(message.id) == "string" and permissions[message.id] or nil
	if type(entry) ~= "table" or type(entry.settings) ~= "string" then return nil, "unknown_settings" end
	return { action = "open_settings", id = message.id, url = entry.settings }
end

function VALIDATORS.refresh(message)
	local detailed = message.detailed
	if detailed == nil then detailed = false end
	if type(detailed) ~= "boolean" then return nil, "bad_detailed" end
	local extensive = message.extensive
	if extensive == nil then extensive = false end
	if type(extensive) ~= "boolean" then return nil, "bad_extensive" end
	return { action = "refresh", detailed = detailed, extensive = extensive }
end

function VALIDATORS.export_snapshot(message, context)
	local sequence = message.export_sequence
	if type(sequence) ~= "number" or sequence ~= math.floor(sequence) or sequence <= 0
		or sequence > context.schema.report.export_sequence_max then return nil, "bad_export_sequence" end
	local action = { action = "export_snapshot", export_sequence = sequence }
	if message.page_checks ~= nil then
		local observations = require("healthcheck.share").page_checks(message.page_checks, context.schema)
		if not observations then return nil, "bad_page_checks" end
		if not bounded_text(message.generated_at, 40) or type(message.snapshot_revision) ~= "number"
			or message.snapshot_revision <= 0 or message.snapshot_revision ~= math.floor(message.snapshot_revision)
			or message.snapshot_revision > context.schema.report.export_sequence_max then return nil, "bad_snapshot_identity" end
		action.generated_at, action.snapshot_revision = message.generated_at, message.snapshot_revision
		action.page_check_observations = observations
	end
	return action
end

function VALIDATORS.cancel()
	return { action = "cancel" }
end

function VALIDATORS.close()
	return { action = "close" }
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Validates one message of the diagnostics page.
--- @param message any The decoded message.
--- @param context table { schema, templates, driver }: the decoded schema.json
---   and issue_templates.json, and the driver the host runs.
--- @return table|nil action The normalized action, nil when refused.
--- @return string|nil reason A stable refusal code.
function M.validate(message, context)
	if type(context) ~= "table" or type(context.schema) ~= "table" or type(context.templates) ~= "table"
		or type(context.driver) ~= "string" then
		error("actions.validate: the context needs the schema, the templates and the driver", 2)
	end
	if type(message) ~= "table" then return nil, "not_a_message" end
	local validator = type(message.action) == "string" and VALIDATORS[message.action] or nil
	if not validator then return nil, "unknown_action" end
	return validator(message, context)
end

return M
