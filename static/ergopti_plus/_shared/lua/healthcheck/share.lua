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

--- Builds clipboard, file and issue-form content exclusively from the host snapshot.
--- @param snapshot table Host-retained snapshot.
--- @param schema table Canonical diagnostics schema.
--- @param notice string Localized privacy notice from the driver's catalogue.
--- @return table { text, fields, name, snapshot }
function M.document(snapshot, schema, notice)
	local safe = M.snapshot(snapshot, schema)
	local versions = safe.sections and safe.sections.versions or {}
	local stamp = safe.generated_at or "unknown"
	return {
		snapshot = safe,
		text = "# ErgoptiPlus diagnostics\n\n" .. notice
			.. "\n\ndriver-suites: not_run\npage-model-checks: not_collected\n\n```json\n" .. Json.encode(safe) .. "\n```\n",
		fields = { driver = safe.driver, version = versions.ergopti_version or "unknown", os = safe.driver },
		name = schema.report.name_prefix .. safe.driver .. "-" .. stamp:gsub("[^%w.-]", "_") .. schema.report.name_suffix,
	}
end

return M
