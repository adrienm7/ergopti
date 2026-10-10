--- _shared/lua/healthcheck/share.lua

--- ==============================================================================
--- MODULE: Closed Diagnostic Sharing
--- DESCRIPTION:
--- Projects the host-retained snapshot through canonical typed rules. Free text,
--- paths and unknown fields never enter shared files, the clipboard or issue forms.
--- ==============================================================================

local M = {}
local Json = require("json")

local KINDS = { object = true, array = true, enum = true, boolean = true, number = true, integer = true,
	version = true, hash = true, utc = true, commit = true, runtime = true }

local function project(value, rule)
	assert(KINDS[rule.kind], "Unknown diagnostic sharing rule")
	if rule.kind == "object" then
		local result = {}
		if type(value) ~= "table" then return result end
		for key, child in pairs(rule.fields) do
			if value[key] ~= nil or child.default ~= nil then
				local item = project(value[key], child)
				if item ~= nil then result[key] = item end
			end
		end
		return result
	elseif rule.kind == "array" then
		local result = {}
		if type(value) == "table" then
			for _, item in ipairs(value) do result[#result + 1] = project(item, rule.item) end
		end
		return Json.array(result)
	elseif rule.kind == "enum" then
		if type(value) == "string" then
			for _, accepted in ipairs(rule.values) do if value == accepted then return value end end
		end
		return rule.default
	elseif rule.kind == "boolean" then
		if value == true or value == 1 then return true end
		if value == false or value == 0 then return false end
	elseif rule.kind == "number" or rule.kind == "integer" then
		if type(value) == "number" and value == value and math.abs(value) <= 9007199254740991
			and (rule.minimum == nil or value >= rule.minimum) and (rule.maximum == nil or value <= rule.maximum)
			and (rule.kind ~= "integer" or value == math.floor(value)) then return value end
	elseif type(value) == "string" then
		if rule.kind == "commit" then
			local sha, origin = value:match("^([%da-fA-F]+) %((%a+)%)$")
			if sha and (origin == "build" or origin == "git") then return project(sha, { kind = "hash" }) end
			return project(value, { kind = "hash" })
		end
		if rule.kind == "runtime" then
			for _, prefix in ipairs(rule.prefixes) do for _, suffix in ipairs(rule.suffixes) do
				if value:sub(1, #prefix) == prefix and (suffix == "" or value:sub(-#suffix) == suffix) then
					local finish = suffix == "" and #value or #value - #suffix
					local version = project(value:sub(#prefix + 1, finish), { kind = "version" })
					if version ~= nil then return version end
				end
			end end
		end
		if rule.kind == "hash" and #value >= 7 and #value <= 64 and value:match("^[%da-fA-F]+$") then return value end
		if rule.kind == "utc" and (value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$")
			or value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d+Z$") and #value <= 30) then return value end
		if rule.kind == "version" then
			local base = value:match("^(.-)%-dev%.%d+$") or value:match("^(.-)%-beta%d+$") or value
			local count = 0
			for _ in base:gmatch("%d+") do count = count + 1 end
			if count >= 2 and count <= 4 and base:match("^%d[%d.]*%d$")
				and not base:find("..", 1, true) and base:gsub("%d+", ""):match("^%.+$") then return value end
		end
	end
	return nil
end

--- Returns a detached technical projection; no callback or native authority is exported.
--- @param snapshot table Host-retained snapshot.
--- @param schema table Canonical diagnostics schema.
--- @return table
function M.snapshot(snapshot, schema)
	assert(type(schema.share_policy) == "table" and schema.share_policy.version == 1,
		"Diagnostic sharing policy unavailable")
	assert(type(snapshot) == "table" and (snapshot.driver == "macos" or snapshot.driver == "linux"
		or snapshot.driver == "windows"), "Diagnostic sharing identity unavailable")
	return project(snapshot, schema.share_policy.projection)
end


--- Rebuilds only schema-owned installed-page observations, without native authority.
--- @param results table Untrusted page records.
--- @param schema table Canonical diagnostic checks.
--- @return table|nil observations
function M.page_checks(results, schema)
	if type(results) ~= "table" or type(schema.diagnostic_checks) ~= "table" then return nil end
	local accepted, expected = {}, {}
	for _, spec in ipairs(schema.diagnostic_checks.items) do
		expected[spec.id] = true
		local row = results[spec.id]
		if type(row) ~= "table" or row.scope ~= spec.scope then return nil end
		for key in pairs(row) do
			if key ~= "state" and key ~= "scope" and key ~= "reason" and key ~= "ms" then return nil end
		end
		local rule = schema.share_policy.projection.fields.page_check_observations.fields.results.fields[spec.id]
		local clean = project(row, rule)
		if clean.state == nil or clean.state ~= row.state or clean.scope ~= row.scope or clean.reason ~= row.reason or clean.ms ~= row.ms then return nil end
		if spec.reason then
			if row.state ~= "not_run" or row.reason ~= spec.reason or row.ms ~= nil then return nil end
		elseif row.state == "ok" or row.state == "error" then
			if row.ms == nil or (row.reason ~= nil and row.reason ~= "invalid_diagnostic_model") then return nil end
		elseif row.ms ~= nil or (row.state == "cancelled" and row.reason ~= nil)
			or (row.state ~= "cancelled" and row.reason ~= "opt_in_required") then return nil end
		accepted[spec.id] = clean
	end
	for id in pairs(results) do if not expected[id] then return nil end end
	return { source = "installed_page_reported", qualification = "unqualified", results = accepted }
end

--- Admits page records only into the exact current host snapshot generation.
--- @param snapshot table Host-retained report.
--- @param action table Validated export action.
--- @return boolean accepted
function M.capture_page_checks(snapshot, action)
	if action.page_check_observations == nil then return true end
	if action.generated_at ~= snapshot.generated_at or action.snapshot_revision ~= snapshot.export_revision then return false end
	snapshot.page_check_observations = action.page_check_observations
	return true
end

local function cell(value)
	return (tostring(value):gsub("[\r\n]+", " "):gsub("|", "\\|"))
end

local function rows_for(value, rule, prefix, rows)
	if rule.kind == "object" then
		local keys = {}
		for key in pairs(value) do keys[#keys + 1] = key end
		table.sort(keys)
		for _, key in ipairs(keys) do
			rows_for(value[key], rule.fields[key], prefix == "" and key or prefix .. "." .. key, rows)
		end
	elseif rule.kind == "array" then
		for index, item in ipairs(value) do rows_for(item, rule.item, prefix .. "." .. index, rows) end
	else
		local text = rule.kind == "boolean" and (value and "true" or "false")
			or type(value) == "number" and Json.encode(value) or value
		rows[#rows + 1] = "| " .. cell(prefix) .. " | " .. cell(text) .. " |"
	end
end

--- Formats only detached approved leaves, using the driver's existing catalogue.
local function readable(safe, schema)
	local function translate(key)
		local value = schema.export_strings and schema.export_strings[key]
		assert(type(value) == "string" and value ~= "", "English export label unavailable: " .. key)
		return value
	end
	local policy, lines, rows = schema.share_policy.projection.fields, {}, {}
	local keys = {}
	for key in pairs(safe) do
		if key ~= "sections" and key ~= "probes" and key ~= "retired_probes" then keys[#keys + 1] = key end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do rows_for(safe[key], policy[key], key, rows) end
	local function append(title)
		if #rows == 0 then return end
		if title then lines[#lines + 1] = "## " .. translate(title); lines[#lines + 1] = "" end
		lines[#lines + 1] = "| | |"; lines[#lines + 1] = "| --- | --- |"
		for _, row in ipairs(rows) do lines[#lines + 1] = row end
		lines[#lines + 1] = ""
	end
	append()
	for _, section in ipairs(schema.sections) do
		local data = safe.sections and safe.sections[section.id]
		if data then
			rows, keys = {}, {}
			for key in pairs(data) do keys[#keys + 1] = key end
			table.sort(keys)
			for _, key in ipairs(keys) do
				local label = key
				for _, field in ipairs(section.fields or {}) do
					if field.id == key then label = translate("healthcheck.field." .. key); break end
				end
				rows_for(data[key], policy.sections.fields[section.id].fields[key], label, rows)
			end
			append("healthcheck.section." .. section.id)
		end
	end
	rows = {}
	for _, key in ipairs({ "probes", "retired_probes" }) do
		if safe[key] then rows_for(safe[key], policy[key], key, rows) end
	end
	append("healthcheck.deep_tests.probe_inventory")
	return table.concat(lines, "\n")
end

--- Builds clipboard, file and issue-form content exclusively from the host snapshot.
--- @param snapshot table Host-retained snapshot.
--- @param schema table Canonical diagnostics schema.
--- @param notice string Localized privacy notice from the driver's catalogue.
--- @return table { text, fields, name, snapshot }
function M.document(snapshot, schema, notice)
	local safe = M.snapshot(snapshot, schema)
	notice = schema.export_strings and schema.export_strings[schema.share_policy.notice_key]
	assert(type(notice) == "string" and notice ~= "", "English export notice unavailable")
	local versions = safe.sections and safe.sections.versions or {}
	local stamp = safe.generated_at or "unknown"
	return {
		snapshot = safe,
		summary = "A diagnostic attachment was saved locally. Attach that file here after reviewing it; no attachment is uploaded automatically.\n"
			.. "Driver: " .. safe.driver .. "\nVersion: " .. (versions.ergopti_version or "unknown")
			.. "\nCommit: " .. (versions.commit or "unknown") .. "\nDriver suites: NOT_RUN",
		text = "# ErgoptiPlus diagnostics\n\n" .. notice
			.. "\n\ndriver-suites: not_run\npage-model-checks: " .. (safe.page_check_observations and "installed_page_reported (unqualified)" or "not_collected") .. "\n\n" .. readable(safe, schema)
			.. "\n```json\n" .. Json.encode(safe) .. "\n```\n",
		fields = { driver = safe.driver, version = versions.ergopti_version or "unknown", os = safe.driver },
		name = schema.report.name_prefix .. safe.driver .. "-" .. stamp:gsub("[^%w.-]", "_") .. schema.report.name_suffix,
	}
end

return M
