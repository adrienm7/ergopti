--- _shared/diagnostics/engine/healthcheck/share.lua

--- ==============================================================================
--- MODULE: Closed Diagnostic Sharing
--- DESCRIPTION:
--- Projects the host-retained snapshot through canonical typed rules. Free text,
--- paths and unknown fields never enter shared files, the clipboard or issue forms.
--- ==============================================================================

local M = {}
local Json = require("core.text.engine.json")
local TableUtil = require("core.text.engine.table_util")

local KINDS = { object = true, array = true, enum = true, boolean = true, number = true, integer = true,
	version = true, hash = true, utc = true, commit = true, runtime = true, setting_row = true,
	platform_name = true }

-- The value grammar of one configuration row, by its type. A path or a sentence
-- matches none of them: an enum is a bare identifier, a text or a list only a
-- count.
local SETTING_TYPES = { boolean = true, number = true, enum = true, text = true, list = true }
local MAX_SETTING_LENGTH = 96

--- Projects one configuration row {setting, type, value}; nil when any part is
--- outside its grammar, so a mislabelled value is dropped whole.
--- @param value any
--- @return table|nil
local function setting_row(value)
	if type(value) ~= "table" then return nil end
	local setting, kind, text = value.setting, value.type, value.value
	if type(setting) ~= "string" or #setting == 0 or #setting > MAX_SETTING_LENGTH
		or type(kind) ~= "string" or not SETTING_TYPES[kind] or type(text) ~= "string" then return nil end
	for segment in (setting .. "."):gmatch("([^.]*)%.") do
		if not segment:match("^[%w_%-]+$") then return nil end
	end
	local fits = false
	if kind == "boolean" then fits = text == "true" or text == "false"
	elseif kind == "number" then
		local number = tonumber(text)
		fits = #text <= 24 and text:match("^%-?%d[%d.]*[eE]?[+%-]?%d*$") ~= nil and number ~= nil
			and number == number and number ~= math.huge and number ~= -math.huge
	elseif kind == "enum" then fits = #text >= 1 and #text <= 40 and text:match("^[%w_+%-]+$") ~= nil
	else fits = #text >= 1 and #text <= 6 and text:match("^%d+$") ~= nil end
	if not fits then return nil end
	return { setting = setting, type = kind, value = text }
end

local function project(value, rule)
	assert(KINDS[rule.kind], "Unknown diagnostic sharing rule")
	if rule.kind == "setting_row" then return setting_row(value) end
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
			for _, item in ipairs(value) do
				if rule.max_items and #result >= rule.max_items then break end
				result[#result + 1] = project(item, rule.item)
			end
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
		-- An operating system or desktop name from the host: one of the rule's known
		-- families, then a closed set of name characters. A path, an address, a
		-- sentence or a name that is not listed never matches.
		if rule.kind == "platform_name" and #value <= 64 then
			for _, family in ipairs(rule.families) do
				local rest = value:sub(#family + 1)
				if value:sub(1, #family):lower() == family:lower() and rest:match("^[%w %.%+/:(),!%-]*$")
					and not rest:sub(1, 1):match("%a") then return value end
			end
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

--- Classifies only known technical failure shapes; all raw text remains local.
--- These are log observations, never native state, revocation or incident-cause proof.
--- @param entries table|string Host-retained recent errors, without page authority.
--- @param source string Existing collector source.
--- @param schema table Canonical closed rules.
--- @return table
function M.error_facts(entries, source, schema)
	local observed = type(entries) == "table"
	if observed then
		local length = #entries
		for key in pairs(entries) do
			if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > length then observed = false; break end
		end
	end
	local events, count = {}, 0
	local specs = schema.recent_error_facts
	for index, entry in ipairs(observed and entries or {}) do
		count = count + 1
		local first = type(entry) == "string" and entry:match("^[^\r\n]*") or ""
		local start = first:find(specs.owner_prefix, 1, true)
		local marker = start and first:find(specs.failure_marker, start + #specs.owner_prefix, true)
		local reason = marker and first:sub(marker + #specs.failure_marker) or ""
		for _, rule in ipairs(specs.rules) do
			local event, candidate = nil, reason
			if rule.message_prefix then
				local position = first:find(rule.message_prefix, 1, true)
				candidate = position and first:sub(position) or ""
				if rule.number_marker then
					local number_at = candidate:find(rule.number_marker, #rule.message_prefix + 1, true)
					candidate = number_at and candidate:sub(number_at) or ""
				end
			end
			if rule.literal and candidate == rule.literal then
				event = { entry_index = index, code = rule.code }
			elseif rule.prefix and candidate:sub(1, #rule.prefix) == rule.prefix then
				local value = candidate:sub(#rule.prefix + 1)
				if rule.suffix ~= "" then
					local finish = value:find(rule.suffix, 1, true)
					value = finish and value:sub(1, finish - 1) or ""
				end
				if value:match("^%-?%d+$") then
					local number = project(tonumber(value), { kind = "integer", minimum = rule.minimum, maximum = rule.maximum })
					if number and tostring(number) == value then event = { entry_index = index, code = rule.code, [rule.field] = number } end
				end
			end
			if event then events[#events + 1] = event; break end
		end
	end
	return { observed = observed, source = (source == "errors_file" or source == "ring") and source or "unavailable",
		qualification = "log_observation_only", examined_entries = count, excluded_entries = count - #events,
		events = Json.array(events) }
end

--- Returns a detached technical projection; no callback or native authority is exported.
--- @param snapshot table Host-retained snapshot.
--- @param schema table Canonical diagnostics schema.
--- @param with_day_log boolean|nil True when the action also saves the opt-in day
---   log: its closed record (included, bytes, lines) is then part of the report.
--- @return table
function M.snapshot(snapshot, schema, with_day_log)
	assert(type(schema.share_policy) == "table" and schema.share_policy.version == 1,
		"Diagnostic sharing policy unavailable")
	assert(type(snapshot) == "table" and (snapshot.driver == "macos" or snapshot.driver == "linux"
		or snapshot.driver == "windows"), "Diagnostic sharing identity unavailable")
	local safe = project(snapshot, schema.share_policy.projection)
	if not with_day_log then safe.day_log_attachment = nil end
	assert(not with_day_log or safe.day_log_attachment ~= nil,
		"The day log was asked for but the snapshot holds no record of it")
	local sections = type(snapshot.sections) == "table" and snapshot.sections or {}
	local issues = sections.issues
	if type(issues) == "table" then
		safe.sections.issues.recent_error_facts = M.error_facts(issues.recent, issues.recent_source, schema)
	end
	return safe
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

-- The operating-system name each driver is shown as: the issue form's Driver
-- dropdown options and the report's Driver line
local OS_NAMES = { macos = "macOS", windows = "Windows", linux = "Linux" }

-- Three backticks: a block of identifiers (probe ids, config.toml keys) that
-- GitHub shows verbatim, so an underscore never turns into emphasis
local FENCE = "```"

-- The probe facts the compact report shows after the state; the hashes and
-- deep-test provenance stay in the JSON block of the complete report
local PROBE_FACTS = { "detail", "cleanup", "native_status", "ms" }
local PAGE_CHECK_FACTS = { "reason", "ms" }

--- Renders a number the same way in the three ports: an integer without a
--- fraction, anything else with at most two decimals.
--- @param value number
--- @return string
local function number_text(value)
	if value == math.floor(value) then return string.format("%d", value) end
	local text = string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", "")
	return text
end

--- Renders a scalar of a section field by the field's schema type: units for
--- sizes and durations, yes or no for a boolean.
--- @param value any A projected scalar.
--- @param kind string|nil The schema field type.
--- @param label function English label lookup.
--- @return string
local function field_text(value, kind, label)
	if type(value) == "boolean" then return label(value and "healthcheck.value.yes" or "healthcheck.value.no") end
	if type(value) ~= "number" then return tostring(value) end
	if kind == "bool" then return label(value ~= 0 and "healthcheck.value.yes" or "healthcheck.value.no") end
	if kind == "bytes" then return string.format("%d MB", math.floor(value / 1048576 + 0.5)) end
	if kind == "percent" then return number_text(value) .. " %" end
	if kind == "seconds" then return number_text(value) .. " s" end
	if kind == "ms" then return number_text(value) .. " ms" end
	return number_text(value)
end

--- Joins the `key=value` facts of a record in the given key order, skipping
--- the absent ones.
--- @param record table
--- @param keys table
--- @return string "" when none is present, else " (k=v, k=v)".
local function facts(record, keys)
	local parts = {}
	for _, key in ipairs(keys) do
		local value = record[key]
		if value ~= nil then
			parts[#parts + 1] = key .. "=" .. (type(value) == "number" and number_text(value) or tostring(value))
		end
	end
	return #parts > 0 and " (" .. table.concat(parts, ", ") .. ")" or ""
end

--- Formats only detached approved leaves as readable English lines, grouped in
--- the order of share_policy.report_order, most useful first: when the issue
--- link cuts the report, the least useful part goes. The model.js and
--- report.ahk ports replay report_vectors.json byte for byte.
--- @param safe table The projected snapshot.
--- @param schema table The diagnostics schema with its English export strings.
--- @return string
local function readable(safe, schema)
	local function label(key)
		local value = schema.export_strings and schema.export_strings[key]
		assert(type(value) == "string" and value ~= "", "English export label unavailable: " .. key)
		return value
	end
	local sections = safe.sections or {}
	local specs = {}
	for _, section in ipairs(schema.sections) do specs[section.id] = section end
	local out = {}
	local function group(title, lines, fenced)
		if #lines == 0 then return end
		out[#out + 1] = "## " .. title
		if fenced then out[#out + 1] = FENCE end
		for _, line in ipairs(lines) do out[#out + 1] = line end
		if fenced then out[#out + 1] = FENCE end
		out[#out + 1] = ""
	end
	local function field_lines(id)
		local lines, data = {}, sections[id]
		if type(data) ~= "table" then return lines end
		for _, field in ipairs(specs[id].fields or {}) do
			local value = data[field.id]
			if value ~= nil and type(value) ~= "table" then
				lines[#lines + 1] = label("healthcheck.field." .. field.id) .. ": " .. field_text(value, field.type, label)
			end
		end
		return lines
	end
	local render = {}
	render.issues = function()
		local lines = field_lines("issues")
		local recent = sections.issues and sections.issues.recent_error_facts
		if type(recent) == "table" and recent.examined_entries ~= nil then
			-- An unread source is no count: "0" would say the log held no error
			lines[#lines + 1] = label("healthcheck.export.recent_errors_read") .. ": " .. (recent.observed
				and number_text(recent.examined_entries) .. " (" .. label("healthcheck.recent_source." .. recent.source) .. ")"
				or label("healthcheck.value.unknown"))
			for _, event in ipairs(recent.events or {}) do
				local keys = {}
				for _, key in ipairs(TableUtil.sorted_keys(event)) do
					if key ~= "code" and key ~= "entry_index" then keys[#keys + 1] = key end
				end
				lines[#lines + 1] = label("healthcheck.export.recognised_error") .. ": " .. event.code .. facts(event, keys)
			end
		end
		group(label("healthcheck.section.issues"), lines)
	end
	render.checks = function()
		local lines = {}
		for _, id in ipairs(TableUtil.sorted_keys(safe.probes or {})) do
			local probe = safe.probes[id]
			local shown = {}
			for _, key in ipairs(PROBE_FACTS) do
				if not (key == "cleanup" and probe.cleanup == "settled") then shown[#shown + 1] = key end
			end
			lines[#lines + 1] = id .. ": " .. tostring(probe.state) .. facts(probe, shown)
		end
		local pages = safe.page_check_observations and safe.page_check_observations.results or {}
		for _, id in ipairs(TableUtil.sorted_keys(pages)) do
			lines[#lines + 1] = "page." .. id .. ": " .. tostring(pages[id].state) .. facts(pages[id], PAGE_CHECK_FACTS)
		end
		local retired = type(safe.retired_probes) == "table" and #safe.retired_probes or 0
		if retired > 0 then lines[#lines + 1] = "retired_runs: " .. number_text(retired) end
		group(label("healthcheck.export.checks"), lines, true)
	end
	render.permissions = function()
		local lines = {}
		for _, item in ipairs(sections.permissions and sections.permissions.items or {}) do
			lines[#lines + 1] = label("healthcheck.permission." .. item.id) .. ": " .. tostring(item.state)
		end
		group(label("healthcheck.section.permissions"), lines)
	end
	render.configuration_files = function()
		local lines = {}
		for _, item in ipairs(sections.configuration_files and sections.configuration_files.items or {}) do
			lines[#lines + 1] = label("healthcheck.config_file." .. item.id) .. ": "
				.. label("healthcheck.config_state." .. item.state)
		end
		group(label("healthcheck.section.configuration_files"), lines)
	end
	render.report = function()
		local lines = { label("healthcheck.export.driver") .. ": " .. (OS_NAMES[safe.driver] or tostring(safe.driver)) }
		if safe.generated_at ~= nil then lines[#lines + 1] = label("healthcheck.export.generated") .. ": " .. safe.generated_at end
		if safe.schema_version ~= nil then
			lines[#lines + 1] = label("healthcheck.export.schema") .. ": " .. number_text(safe.schema_version)
		end
		if safe.detailed ~= nil then lines[#lines + 1] = label("healthcheck.export.details") .. ": " .. field_text(safe.detailed, nil, label) end
		if safe.extensive ~= nil then
			lines[#lines + 1] = label("healthcheck.export.extensive") .. ": " .. field_text(safe.extensive, nil, label)
		end
		local log = safe.day_log_attachment
		if type(log) == "table" and log.included ~= nil then
			lines[#lines + 1] = label("healthcheck.export.day_log") .. ": " .. field_text(log.included, nil, label)
				.. facts(log, { "bytes", "lines" })
		end
		group(label("healthcheck.export.report"), lines)
	end
	render.configuration = function()
		-- Until the configuration probe answers, an empty list would claim no
		-- setting was changed
		local probe = safe.probes and safe.probes.configuration
		if probe and probe.state ~= "ok" then
			group(label("healthcheck.export.changed_settings"), { label("healthcheck.value.unknown") })
			return
		end
		local lines = {}
		for _, item in ipairs(sections.configuration and sections.configuration.items or {}) do
			local value = item.value
			if item.type == "text" then value = value .. " " .. label("healthcheck.export.characters")
			elseif item.type == "list" then value = value .. " " .. label("healthcheck.export.items") end
			lines[#lines + 1] = item.setting .. " = " .. value
		end
		if #lines == 0 then
			group(label("healthcheck.export.changed_settings"), { label("healthcheck.value.none") })
			return
		end
		group(label("healthcheck.export.changed_settings"), lines, true)
	end
	for _, id in ipairs(schema.share_policy.report_order) do
		if render[id] then render[id]()
		else
			assert(specs[id], "report_order names an unknown section: " .. tostring(id))
			group(label("healthcheck.section." .. id), field_lines(id))
		end
	end
	return table.concat(out, "\n")
end

-- The session name shown for a display server
local SESSION_NAMES = { wayland = "Wayland", x11 = "X11" }

--- The version the issue form shows. A source run has no release version (the
--- host reports "local"), so it is named by its commit: a true statement, where
--- "unknown" would be false.
--- @param safe table The projected snapshot.
--- @param snapshot table The host snapshot, for the commit origin only.
--- @return string
local function form_version(safe, snapshot)
	local versions = safe.sections and safe.sections.versions or {}
	if versions.ergopti_version then return versions.ergopti_version end
	local raw = type(snapshot.sections) == "table" and snapshot.sections.versions or {}
	local from_git = type(raw.commit) == "string" and raw.commit:match(" %(git%)$") ~= nil
	if raw.ergopti_version == "local" or from_git then
		return "dev source" .. (versions.commit and " " .. versions.commit or "")
	end
	return "unknown"
end

--- The operating system the issue form shows: the name and version the host
--- reported, then the desktop, the session and the architecture when known.
--- @param safe table The projected snapshot.
--- @return string
local function form_os(safe)
	local sections = safe.sections or {}
	local system = sections.system or {}
	local details = {}
	if system.desktop then details[#details + 1] = system.desktop end
	if system.display_server and SESSION_NAMES[system.display_server] then
		details[#details + 1] = SESSION_NAMES[system.display_server]
	end
	if sections.hardware and sections.hardware.arch and sections.hardware.arch ~= "unknown" then
		details[#details + 1] = sections.hardware.arch
	end
	local name = system.os or ((OS_NAMES[safe.driver] or safe.driver) .. " (version unknown)")
	return name .. (#details > 0 and " (" .. table.concat(details, ", ") .. ")" or "")
end

--- Builds clipboard, file and issue-form content exclusively from the host snapshot.
--- @param snapshot table Host-retained snapshot.
--- @param schema table Canonical diagnostics schema.
--- @param notice string Localized privacy notice from the driver's catalogue.
--- @param with_day_log boolean|nil See M.snapshot.
--- @return table { text, fields, notes, name, snapshot }; fields.diagnostics is the
---   compact report (readable lines, no JSON block) the issue form is prefilled
---   with, and fields.driver the form's Driver dropdown option
function M.document(snapshot, schema, notice, with_day_log)
	local safe = M.snapshot(snapshot, schema, with_day_log)
	notice = schema.export_strings and schema.export_strings[schema.share_policy.notice_key]
	assert(type(notice) == "string" and notice ~= "", "English export notice unavailable")
	local truncated = schema.export_strings and schema.export_strings[schema.share_policy.truncated_note_key]
	assert(type(truncated) == "string" and truncated ~= "", "English export truncation note unavailable")
	local versions = safe.sections and safe.sections.versions or {}
	local stamp = safe.generated_at or "unknown"
	local head = "# ErgoptiPlus diagnostics\n\n" .. notice .. "\n\n" .. readable(safe, schema)
	return {
		snapshot = safe,
		summary = "A diagnostic attachment was saved locally. Attach that file here after reviewing it; no attachment is uploaded automatically.\n"
			.. "Driver: " .. safe.driver .. "\nVersion: " .. (versions.ergopti_version or "unknown")
			.. "\nCommit: " .. (versions.commit or "unknown") .. "\nDriver suites: NOT_RUN",
		text = head .. "\n```json\n" .. Json.encode(safe) .. "\n```\n",
		fields = { driver = OS_NAMES[safe.driver], version = form_version(safe, snapshot), os = form_os(safe), diagnostics = head },
		notes = { diagnostics = truncated },
		name = schema.report.name_prefix .. safe.driver .. "-" .. stamp:gsub("[^%w.-]", "_") .. schema.report.name_suffix,
	}
end

return M
