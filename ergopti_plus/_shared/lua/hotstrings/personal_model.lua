--- _shared/lua/hotstrings/personal_model.lua

--- ==============================================================================
--- MODULE: Personal Editor Source Preservation
--- DESCRIPTION:
--- Replaces only projected hotstring rows and displayed section descriptions.
--- Hidden assignments, metadata and standalone comments remain source-owned.
--- ==============================================================================

local M = {}
local Codec = require("toml_codec")
local Reader = require("toml_codec.reader")
local Scanner = require("toml_codec.record_scanner")
local Keys = require("toml_codec.key_path")
local Metadata = require("hotstrings.personal_metadata")
local FLAGS = { "is_word", "auto_expand", "is_case_sensitive", "final_result", "is_case_sensitive_strict" }

local function section_name(header)
	if not header or not header.segments then return nil end
	return header.raw_name
end

local function raw_record(scan, record)
	local parts = {}
	for index = record.first, record.last do
		parts[#parts + 1] = scan.lines[index].text .. scan.lines[index].eol
	end
	return table.concat(parts)
end

local function record_tail(scan, record)
	local depth, quote, offset = 0, nil, nil
	for index = record.first, record.last do
		depth, quote, offset = Scanner.advance(scan.lines[index].text, depth, quote)
	end
	local last = scan.lines[record.last]
	return offset and last.text:sub(offset) or "", last.eol
end

local function normalized(entry, normalize)
	local result = { output = normalize(entry.output) }
	for _, field in ipairs(FLAGS) do result[field] = entry[field] == true end
	if entry.priority ~= nil then result.priority = entry.priority end
	return result
end

local OWNED = { output = true, priority = true }
for _, field in ipairs(FLAGS) do OWNED[field] = true end
local OWNED_ORDER = { "output", "is_word", "auto_expand", "is_case_sensitive", "final_result", "is_case_sensitive_strict", "priority" }
local function render_value(value, record)
	if not record or type(record.value) ~= "table" then return Codec.encode_value(value) end
	local keys, members = {}, {}
	for key in pairs(value) do if not OWNED[key] then keys[#keys + 1] = key end end
	table.sort(keys)
	-- The hotstring projection reader recognizes the displayed fields before
	-- stopping at an extension value whose nested shape it does not project.
	for index = #OWNED_ORDER, 1, -1 do
		local key = OWNED_ORDER[index]
		if value[key] ~= nil then table.insert(keys, 1, key) end
	end
	for _, key in ipairs(keys) do
		local encoded = OWNED[key] and Codec.encode_value(value[key])
			or Codec.encode_value_with_shapes(value[key], record.shapes, record.value, key)
		members[#members + 1] = Keys.render({ key }) .. " = " .. encoded
	end
	return "{ " .. table.concat(members, ", ") .. " }"
end

local function same_entry(a, b)
	if a.output ~= b.output or a.priority ~= b.priority then return false end
	for _, field in ipairs(FLAGS) do if (a[field] == true) ~= (b[field] == true) then return false end end
	return true
end

--- Builds a candidate from one classified opening source and the whole UI model.
--- Explicit deletions own projected rows, never hidden assignments or metadata.
--- @param source table Exact classified source receipt.
--- @param model table Validated editor sections and order.
--- @return string|nil candidate
--- @return string|nil refusal
function M.prepare(source, model, normalize)
	normalize = type(normalize) == "function" and normalize or function(value) return value end
	if type(source) ~= "table" or (source.status ~= "ok" and source.status ~= "absent")
		or type(model) ~= "table" or type(model.sections) ~= "table"
		or type(model.sections_order) ~= "table" then return nil, "invalid-personal-model" end
	local content = source.status == "absent" and "" or source.content
	if type(content) ~= "string" then return nil, "unreadable-personal-source" end
	local document = Codec.decode(content)
	local original, admitted = Reader.parse_text(content)
	local scan = Scanner.scan_records(content, { quoted_headers = true })
	if type(document) ~= "table" or admitted ~= true or not scan then return nil, "malformed-personal-source" end
	-- Every editor publication owns the exact _meta.sections_order leaf.
	-- Reject a differently cased ancestor before treating it as a user section.
	for key in pairs(document) do
		if type(key) == "string" and key:lower() == "_meta" and key ~= "_meta" then
			return nil, "ambiguous-personal-metadata"
		end
	end
	local groups, requested, ordered = {}, {}, {}
	for _, name in ipairs(model.sections_order) do
		if name ~= "-" then
			if type(name) ~= "string" or name == "" or requested[name] or type(model.sections[name]) ~= "table"
				or not Keys.parse(name, true) then return nil, "invalid-personal-section" end
			requested[name] = model.sections[name]; ordered[#ordered + 1] = name
		end
	end
	for name in pairs(model.sections) do if not requested[name] then return nil, "unlisted-personal-section" end end
	for _, section in pairs(requested) do
		if type(section.entries) ~= "table" then return nil, "invalid-personal-row" end
		local seen = {}
		for _, entry in ipairs(section.entries) do
			if type(entry) ~= "table" or type(entry.trigger) ~= "string" or entry.trigger == ""
				or type(entry.output) ~= "string" or seen[entry.trigger]
				or entry.priority ~= nil and not Metadata.valid("priority", entry.priority) then return nil, "invalid-personal-row" end
			seen[entry.trigger] = true
			for _, flag in ipairs(FLAGS) do if entry[flag] ~= nil and type(entry[flag]) ~= "boolean" then return nil, "invalid-personal-row" end end
		end
	end
	for _, header in ipairs(scan.headers) do
		local text = scan.lines[header.index].text:gsub("^\239\187\191", "")
		local _, _, offset = Scanner.advance(text, 0, nil)
		if offset then text = text:sub(1, offset - 1) end
		header.raw_name = header.array and text:match("^%s*%[%[(.-)%]%]%s*$") or text:match("^%s*%[(.-)%]%s*$")
		local name = section_name(header)
		if original.sections[name] then
			local group = groups[name] or { headers = {}, records = {}, owned = {}, projected = {}, foreign = false }
			groups[name] = group; group.headers[#group.headers + 1] = header
			for _, entry in ipairs(original.sections[name].entries or {}) do group.projected[entry.trigger] = entry end
		end
	end
	-- A descendant table belongs to a particular array element. Keep every
	-- original header and row in place rather than moving foreign children.
	for _, header in ipairs(scan.headers) do
		for _, group in pairs(groups) do
			local parent = group.headers[1].segments
			if header.segments and #header.segments > #parent then
				local descendant = true
				for index, segment in ipairs(parent) do
					if header.segments[index] ~= segment then descendant = false; break end
				end
				if descendant then group.foreign = true end
			end
		end
	end
	for _, record in ipairs(scan.records) do
		local group = groups[section_name(record.header)]
		if group then
			local key = record.key_text and Keys.parse(record.key_text, true)
			local trigger = key and #key == 1 and key[1]
			if trigger and group.projected[trigger] and not group.owned[trigger] then
				local decoded, shapes = Codec.decode_with_shapes(raw_record(scan, record))
				local value = decoded and decoded[trigger]
				if type(value) ~= "string" and type(value) ~= "table" then return nil, "unaddressable-personal-row" end
				record.trigger, record.value, record.shapes = trigger, value, shapes
				group.owned[trigger] = record
			else group.foreign = true end
			group.records[#group.records + 1] = record
		end
	end
	local replacements, removed, insertions = {}, {}, {}
	local function insert(index, text) insertions[index] = (insertions[index] or "") .. text end
	for name, group in pairs(groups) do
		local wanted, lines, desired = requested[name], {}, {}
		if not wanted and group.foreign then return nil, "unowned-personal-section" end
		for _, entry in ipairs(wanted and wanted.entries or {}) do
			if type(entry) ~= "table" or type(entry.trigger) ~= "string" or entry.trigger == ""
				or type(entry.output) ~= "string" or desired[entry.trigger] then return nil, "invalid-personal-row" end
			desired[entry.trigger] = entry
			local record = group.owned[entry.trigger]
			local text
			if record and same_entry(group.projected[entry.trigger], entry) then text = raw_record(scan, record)
			else
				local value = normalized(entry, normalize)
				if record and type(record.value) == "table" then
					for key, previous in pairs(record.value) do
						if value[key] == nil and key ~= "priority" then value[key] = previous end
					end
				end
				local comment, eol = "", "\n"
				if record then
					comment, eol = record_tail(scan, record)
					if comment ~= "" then comment = " " .. comment end
				end
				text = Codec.encode_value(entry.trigger) .. " = " .. render_value(value, record) .. comment .. eol
			end
			lines[#lines + 1] = text
		end
		if group.foreign then
			local expected, present = {}, {}
			for _, record in ipairs(group.records) do
				if record.trigger and desired[record.trigger] then expected[#expected + 1] = record.trigger; present[record.trigger] = true end
			end
			for _, entry in ipairs(wanted.entries or {}) do if not present[entry.trigger] then expected[#expected + 1] = entry.trigger end end
			for index, entry in ipairs(wanted.entries or {}) do
				if expected[index] ~= entry.trigger then return nil, "unowned-personal-order" end
				local record = group.owned[entry.trigger]
				if record then replacements[record.first] = lines[index]
				else
					local last = group.headers[#group.headers].index
					local stop = #scan.lines + 1
					for _, header in ipairs(scan.headers) do if header.index > last then stop = header.index; break end end
					insert(stop, lines[index])
				end
			end
		else
			local first = group.records[1] and group.records[1].first or (group.headers[1].index + 1)
			insert(first, table.concat(lines))
		end
		for _, record in ipairs(group.records) do
			if record.trigger then
				for index = record.first, record.last do removed[index] = true end
				if not desired[record.trigger] then
					local comment, eol = record_tail(scan, record)
					if comment ~= "" then replacements[record.first] = comment .. eol end
				end
			end
		end
		if not wanted then
			for _, header in ipairs(group.headers) do
				removed[header.index] = true
				local line = scan.lines[header.index]
				local _, _, offset = Scanner.advance(line.text, 0, nil)
				if offset then replacements[header.index] = line.text:sub(offset) .. line.eol end
			end
		end
	end
	local output = {}
	local function append(text)
		if text ~= "" and #output > 0 and output[#output]:sub(-1) ~= "\n" then output[#output + 1] = "\n" end
		if text ~= "" then output[#output + 1] = text end
	end
	for index, line in ipairs(scan.lines) do
		if insertions[index] then append(insertions[index]); insertions[index] = nil end
		if replacements[index] then append(replacements[index]) end
		if not removed[index] then append(line.text .. line.eol) end
	end
	for _, text in pairs(insertions) do append(text) end
	local body = table.concat(output)
	for _, name in ipairs(ordered) do
		if not groups[name] then
			local lines
			do
				lines = ""
				for _, entry in ipairs(requested[name].entries or {}) do
					if type(entry.trigger) ~= "string" or type(entry.output) ~= "string" then return nil, "invalid-personal-row" end
					lines = lines .. Codec.encode_value(entry.trigger) .. " = " .. Codec.encode_value(normalized(entry, normalize)) .. "\n"
				end
			end
			body = body .. (body ~= "" and body:sub(-1) ~= "\n" and "\n" or "") .. "[[" .. name .. "]]\n" .. lines
		end
	end
	local updates = { { section = "_meta", key = "sections_order", value = model.sections_order } }
	if source.status == "absent" then
		updates[#updates + 1] = { section = "_meta", key = "description", value = (model.meta or {}).description or "" }
	end
	local metadata = type(document._meta) == "table" and document._meta.sections or {}
	for _, name in ipairs(ordered) do
		local stored = type(metadata) == "table" and metadata[name]
		local description = type(stored) == "table" and stored.description or stored
		local desired_description = type(requested[name].description) == "string" and requested[name].description or name
		if description ~= nil and type(description) ~= "string" then
			if desired_description ~= name then return nil, "unowned-personal-description" end
		else
			updates[#updates + 1] = { section = type(stored) == "table" and Keys.render({ "_meta", "sections", name }) or "_meta.sections",
				key = type(stored) == "table" and "description" or name, literal_key = true, value = desired_description }
		end
	end
	for _, row in ipairs(updates) do
		local target = Keys.parse(row.section, true); target[#target + 1] = row.key
		local node = document
		for _, segment in ipairs(target) do
			if type(node) ~= "table" then break end
			for key in pairs(node) do
				if type(key) == "string" and key:lower() == segment:lower() and key ~= segment then
					return nil, "ambiguous-personal-metadata"
				end
			end
			node = node[segment]
		end
	end
	if not Metadata.exact_rows_available(body, updates) then return nil, "ambiguous-personal-metadata" end
	local Writer = require("toml_codec.writer")
	local ok, detail, candidate = Writer.prepare_batch("personal-editor.toml", updates,
		{ read_with_status = function() return body, "ok" end }, { status = "ok", content = body })
	if ok ~= true then return nil, detail end
	local checked, valid = Reader.parse_text(candidate)
	if valid ~= true or not Codec.decode(candidate) then return nil, "invalid-personal-candidate" end
	for _, name in ipairs(ordered) do
		local actual = checked.sections[name]
		if not actual or #actual.entries ~= #(requested[name].entries or {}) then return nil, "personal-projection-mismatch" end
		for index, entry in ipairs(requested[name].entries or {}) do
			local expected = entry
			if actual.entries[index].output ~= entry.output then
				expected = {}; for field, value in pairs(entry) do expected[field] = value end
				expected.output = normalize(entry.output)
			end
			if actual.entries[index].trigger ~= entry.trigger or not same_entry(actual.entries[index], expected) then
				return nil, "personal-projection-mismatch"
			end
		end
	end
	return candidate
end

return M
