--- _shared/lua/toml_codec/record_list.lua

--- ==============================================================================
--- MODULE: Source-bound Saved Model Records
--- DESCRIPTION:
--- Retains opaque physical list members through ordinary native edits. Explicit
--- cleanup owns only a still-invalid row of the exact previewed source.
--- ==============================================================================

local M = {}
local Codec = require("toml_codec.codec")
local Scanner = require("toml_codec.record_scanner")
local KeyPath = require("toml_codec.key_path")
local Bom = require("toml_codec.bom")
local LeafRows = require("toml_codec.leaf_rows")
local Models = require("config_user_models")
local operations = setmetatable({}, { __mode = "k" })
local removals = setmetatable({}, { __mode = "k" })
local transitions = {}

local function prefix(path, wanted)
	if #path > #wanted then return false end
	for index, value in ipairs(path) do if value ~= wanted[index] then return false end end
	return true
end

local function same(path, wanted)
	return #path == #wanted and prefix(path, wanted)
end

local function lookup(document)
	local value = document
	for _, key in ipairs(Models.PATH) do
		if type(value) ~= "table" then return nil end
		value = value[key]
	end
	return value
end

local function offsets(scan)
	local starts, cursor = {}, 1
	for index, line in ipairs(scan.lines) do
		starts[index] = cursor
		cursor = cursor + #line.text + #line.eol
	end
	starts[#scan.lines + 1] = cursor
	return starts
end

local function field_spans(source, scan, starts, header)
	local fields = {}
	for _, record in ipairs(scan.records) do
		local keys = record.key_text and KeyPath.parse(record.key_text)
		if record.header == header and keys and #keys == 1 then
			local _, _, rhs = Scanner.split_assignment(scan.lines[record.first].text)
			if rhs then
				local first = starts[record.first] + #scan.lines[record.first].text - #rhs
				local raw = source:sub(first, starts[record.last + 1] - 1)
				local token = Codec.string_value_span(raw)
				if token then fields[keys[1]] = { first = first + token.first - 1, last = first + token.last - 1 } end
			end
		end
	end
	return fields
end

--- Captures canonical physical list records without granting write authority.
--- @param source string Exact source bytes.
--- @return table|nil capture Actual list shape and physical member boundaries.
function M.capture(source)
	local document, shapes = LeafRows.decode_source(source)
	assert(document, "saved model source is not valid TOML")
	local rows = lookup(document)
	if rows == nil then return nil end
	if type(rows) ~= "table" or shapes.arrays[rows] ~= true then return { obsolete = true, rows = rows } end
	local scan = assert(Scanner.scan_records(source, { quoted_headers = true }))
	local starts = offsets(scan)
	local result = { source = source, rows = rows, shapes = shapes, elements = {} }
	for position, header in ipairs(scan.headers) do
		if header.array and same(header.segments, Models.PATH) then
			local last = #source
			for next_index = position + 1, #scan.headers do
				local next_header = scan.headers[next_index]
				if same(next_header.segments, Models.PATH) or not prefix(Models.PATH, next_header.segments) then
					last = starts[next_header.index] - 1
					break
				end
			end
			result.kind = "aot"
			local first = starts[header.index]
			if header.index == 1 then first = first + #source - #Bom.strip_prefix(source) end
			result.elements[#result.elements + 1] = { first = first, last = last,
				fields = field_spans(source, scan, starts, header) }
		end
	end
	if result.kind == "aot" then
		assert(#result.elements == #rows, "saved model array record census differs from the canonical decoder")
		result.first, result.last = result.elements[1].first, result.elements[#rows].last
	else
		for _, record in ipairs(scan.records) do
			local path = {}
			for _, key in ipairs(record.header and record.header.segments or {}) do path[#path + 1] = key end
			for _, key in ipairs(record.key_text and KeyPath.parse(record.key_text) or {}) do path[#path + 1] = key end
			if #path > 0 and prefix(path, Models.PATH) then
				local _, _, rhs = Scanner.split_assignment(scan.lines[record.first].text)
				local first = starts[record.first] + #scan.lines[record.first].text - #rhs
				local last = starts[record.last + 1] - 1
				local raw = source:sub(first, last)
				while #path < #Models.PATH do
					local spans = assert(Codec.inline_member_spans(raw:gsub("[\r\n]+$", "")), "saved model inline parent has no canonical source span")
					local matched
					for _, member in ipairs(spans.members) do
						local candidate = {}; for _, key in ipairs(path) do candidate[#candidate + 1] = key end
						for _, key in ipairs(member.segments) do candidate[#candidate + 1] = key end
						if prefix(candidate, Models.PATH) then
							assert(not matched, "saved model inline parent is ambiguous")
							matched = { path = candidate, first = first + member.value_first - 1,
								last = first + member.value_last - 1, raw = member.value_source }
						end
					end
					assert(matched, "saved model inline parent cannot address the list")
					path, first, last, raw = matched.path, matched.first, matched.last, matched.raw
				end
				local spans = assert(Codec.array_element_spans(raw), "saved model array has no canonical source spans")
				result.kind, result.first, result.last = "array", first + spans.first - 1, first + spans.last - 1
				result.trailing = spans.trailing or ""
				for _, span in ipairs(spans.elements) do
					local element = { first = first + span.first - 1, last = first + span.last - 1, fields = {} }
					local cell = raw:sub(span.first, span.last)
					for key, token in pairs(Codec.record_string_spans(cell) or {}) do
						element.fields[key] = { first = element.first + token.first - 1, last = element.first + token.last - 1 }
					end
					result.elements[#result.elements + 1] = element
				end
				break
			end
		end
		assert(result.kind and #result.elements == #rows, "saved model list cannot be physically addressed")
	end
	for index, row in ipairs(rows) do
		local element = result.elements[index]
		element.valid = Models.fits(row, shapes)
		element.raw = source:sub(element.first, element.last)
		if element.valid then assert(element.fields.backend and element.fields.name, "saved model owned string span is missing") end
	end
	return result
end

local function extras(row)
	local copy = LeafRows.clone_value(row)
	copy.backend, copy.name = nil, nil
	return LeafRows.value_literal(copy)
end

local function origin_key(row)
	local origin = LeafRows.source_origin(row)
	if not origin or #origin.path ~= #Models.PATH + 1 then return nil end
	local leading = {}; for index = 1, #Models.PATH do leading[index] = origin.path[index] end
	if not same(leading, Models.PATH) or type(origin.path[#origin.path]) ~= "number" then return nil end
	return origin.source .. "\0" .. origin.path[#origin.path], origin
end

local function desired_rows(rows)
	assert(type(rows) == "table" and getmetatable(rows) == nil, "saved model candidate needs a plain list")
	local count = 0
	for key, row in pairs(rows) do
		assert(type(key) == "number" and key >= 1 and key % 1 == 0 and Models.fits(row), "saved model candidate has an invalid record")
		count = count + 1
	end
	assert(count == #rows, "saved model candidate is not dense")
	for index = 1, count do assert(rows[index], "saved model candidate is not dense") end
end

local function map_rows(capture, desired, path)
	local used, mapping = {}, {}
	local transition = transitions[path]
	if transition and transition.source ~= capture.source then transition = nil end
	for position, row in ipairs(desired) do
		local key, origin = origin_key(row)
		local selected
		if key and origin.source == capture.source then selected = origin.path[#origin.path]
		elseif key and transition then selected = transition.origins[key] or transition.removed[key] end
		if not selected and origin then
			local okay, prior = pcall(M.capture, origin.source)
			local unchanged = okay and prior and not prior.obsolete and prior.kind == capture.kind and #prior.elements == #capture.elements
			if unchanged then
				for index, element in ipairs(prior.elements) do
					if element.raw ~= capture.elements[index].raw then unchanged = false; break end
				end
			end
			if unchanged then selected = origin.path[#origin.path] end
		end
		if type(selected) == "table" then
			assert(LeafRows.value_literal(row) == selected.literal, "acknowledged model inverse cannot change its removed record")
			assert(not used[selected], "saved model inverse is duplicated")
			used[selected] = true
			mapping[position] = selected
		else
			if selected then
				assert(capture.elements[selected] and capture.elements[selected].valid, "saved model origin is not an admitted current record")
			else
				for index, current in ipairs(capture.rows) do
					if capture.elements[index].valid and current.backend == row.backend and current.name == row.name and extras(current) == extras(row) then
						assert(not selected, "saved model identity is ambiguous")
						selected = index
					end
				end
			end
			if selected then
				assert(not used[selected], "saved model record is duplicated")
				assert(extras(row) == extras(capture.rows[selected]), "saved model edit cannot replace unowned fields")
				used[selected] = true
			else
				assert(not key, "saved model source origin is stale")
				assert(extras(row) == LeafRows.value_literal({}), "a new saved model record cannot mint unowned fields")
			end
			mapping[position] = selected or false
		end
	end
	local previous, appended, inverse_before, inverse_order = 0, false, 0, 0
	for _, index in ipairs(mapping) do
		if type(index) == "table" then
			assert(not appended and index.before > previous
				and (index.before > inverse_before or index.before == inverse_before and index.order > inverse_order),
				"acknowledged model inverse moved past its current source anchor")
			inverse_before, inverse_order = index.before, index.order
		elseif index then
			assert(not appended and index > previous and index >= inverse_before, "saved model source records cannot be reordered")
			previous = index
		else appended = true end
	end
	return mapping
end

--- Mints an exact row operation for a physically present canonical array.
--- Absent lists use the established writer; obsolete non-array parents retain
--- their existing refusal policy and never obtain a record capability.
--- @param source string Exact source bytes.
--- @param desired table Detached valid native rows.
--- @param path string Native destination identity.
--- @return table|nil row Authenticated operation when the array exists.
function M.prepare(source, desired, path)
	assert(type(path) == "string" and path ~= "", "saved model destination identity is missing")
	desired_rows(desired)
	local capture = M.capture(source)
	local transition = transitions[path]
	if not capture and transition and transition.source == source and next(transition.removed) then
		capture = { source = source, rows = {}, elements = {}, kind = "aot", insert = transition.insert }
	end
	if not capture then return nil end
	if capture.obsolete then
		assert(next(desired) == nil or type(capture.rows) == "table" and next(capture.rows) == nil,
			"Obsolete user model list 'llm.models.user_models' requires manual source cleanup before replacement")
		return nil
	end
	local row = { section = "llm.models", key = "user_models", value = desired, record_list = {} }
	operations[row] = { token = row.record_list, source = source, desired = desired,
		literal = LeafRows.value_literal(desired), path = path, mapping = map_rows(capture, desired, path), capture = capture }
	return row
end

--- Verifies the original operation identity, fields and unchanged desired rows.
function M.authentic(row, source, path)
	assert(type(row) == "table" and getmetatable(row) == nil, "saved model operation needs a plain row")
	local operation = operations[row]
	if not operation and row.record_list == nil then return false end
	assert(operation and rawequal(row.record_list, operation.token) and getmetatable(row.record_list) == nil and row.section == "llm.models" and row.key == "user_models"
		and row.delete == nil and rawequal(row.value, operation.desired), "saved model row capability is unowned or changed")
	assert(LeafRows.value_literal(row.value) == operation.literal, "saved model desired rows changed after preparation")
	if source ~= nil then assert(source == operation.source, "saved model operation belongs to another source") end
	if path ~= nil then assert(path == operation.path, "saved model operation belongs to another destination") end
	return true
end

local function splice(source, edits)
	table.sort(edits, function(left, right) return left.first > right.first end)
	local previous = #source + 1
	for _, edit in ipairs(edits) do
		assert(edit.last < previous and edit.first >= 1 and edit.last >= edit.first - 1, "saved model source edits overlap")
		source = source:sub(1, edit.first - 1) .. edit.value .. source:sub(edit.last + 1)
		previous = edit.first
	end
	return source
end

local function changed_fragment(capture, index, row)
	local element, current = capture.elements[index], capture.rows[index]
	local edits = {}
	for _, key in ipairs({ "backend", "name" }) do
		if current[key] ~= row[key] then
			local field = element.fields[key]
			edits[#edits + 1] = { first = field.first - element.first + 1, last = field.last - element.first + 1,
				value = Codec.encode_value(row[key]) }
		end
	end
	return splice(element.raw, edits)
end

local function render(capture, desired, mapping, removed)
	local kept, targets, new_rows, restored = {}, {}, {}, {}
	for position, index in ipairs(mapping) do
		if type(index) == "table" then
			restored[index.before] = restored[index.before] or {}
			restored[index.before][#restored[index.before] + 1] = { row = desired[position], raw = index.raw, restored = true }
		elseif index then targets[index] = desired[position] else new_rows[#new_rows + 1] = desired[position] end
	end
	for index, element in ipairs(capture.elements) do
		for _, entry in ipairs(restored[index] or {}) do kept[#kept + 1] = entry end
		if not removed[index] and (not element.valid or targets[index]) then
			kept[#kept + 1] = { original = index, raw = targets[index] and changed_fragment(capture, index, targets[index]) or element.raw }
		end
	end
	for _, entry in ipairs(restored[#capture.elements + 1] or {}) do kept[#kept + 1] = entry end
	for _, row in ipairs(new_rows) do
		local raw
		if capture.kind == "aot" then
			raw = "[[llm.models.user_models]]\nbackend = " .. Codec.encode_value(row.backend) .. "\nname = " .. Codec.encode_value(row.name) .. "\n"
		else raw = "{ backend = " .. Codec.encode_value(row.backend) .. ", name = " .. Codec.encode_value(row.name) .. " }" end
		kept[#kept + 1] = { row = row, raw = raw }
	end
	local fragments = {}; for _, element in ipairs(kept) do fragments[#fragments + 1] = element.raw end
	local replacement
	if capture.kind == "aot" then
		local edits = {}
		for index, element in ipairs(capture.elements) do
			local value = ""
			for _, kept_element in ipairs(kept) do
				if kept_element.original == index then value = kept_element.raw; break end
			end
			local leading = {}
			for _, entry in ipairs(restored[index] or {}) do leading[#leading + 1] = entry.raw end
			edits[#edits + 1] = { first = element.first, last = element.last, value = table.concat(leading) .. value }
		end
		local appended = {}
		for _, element in ipairs(kept) do if element.row and not element.restored then appended[#appended + 1] = element.raw end end
		local trailing = {}
		for _, entry in ipairs(restored[#capture.elements + 1] or {}) do trailing[#trailing + 1] = entry.raw end
		if #trailing > 0 then table.insert(appended, 1, table.concat(trailing)) end
		if #appended > 0 then
			if #edits == 0 then
				edits[1] = { first = capture.insert, last = capture.insert - 1, value = "" }
			end
			local final = edits[#edits]
			if final.value ~= "" and final.value:sub(-1) ~= "\n" then final.value = final.value .. "\n" end
			final.value = final.value .. table.concat(appended)
		end
		return splice(capture.source, edits), kept
	else
		replacement = "[" .. table.concat(fragments, ",")
		if capture.trailing ~= "" and #fragments > 0 then replacement = replacement .. "," end
		replacement = replacement .. capture.trailing .. "]"
	end
	local original = capture.source:sub(capture.first, capture.last)
	if replacement == original then return capture.source, kept end
	return splice(capture.source, { { first = capture.first, last = capture.last, value = replacement } }), kept
end

local function matching_capture(operation, candidate)
	local capture = M.capture(candidate)
	if not capture and #operation.capture.elements == 0 and operation.capture.kind == "aot" then
		assert(candidate == operation.source, "empty model inverse collides with another source update")
		capture = operation.capture
	end
	assert(capture, "saved model list disappeared during another update")
	assert(not capture.obsolete and capture.kind == operation.capture.kind
		and #capture.elements == #operation.capture.elements,
		"another update collides with the saved model source owner")
	for index, element in ipairs(capture.elements) do
		assert(element.raw == operation.capture.elements[index].raw, "another update changed a saved model physical record")
	end
	if capture.kind == "array" then
		assert(candidate:sub(capture.first, capture.last) == operation.source:sub(operation.capture.first, operation.capture.last),
			"another update changed saved model array trivia")
	end
	return capture
end


local function validate_rendered(content, kept, desired, mapping, original)
	local capture = M.capture(content)
	if #kept == 0 then
		assert(not capture or not capture.obsolete and #capture.rows == 0, "saved model empty candidate changed its source kind")
		return
	end
	assert(capture and not capture.obsolete and #capture.rows == #kept, "saved model candidate record census differs")
	local targets = {}
	for position, index in ipairs(mapping) do if type(index) == "number" then targets[index] = desired[position] end end
	for index, element in ipairs(kept) do
		local wanted = element.row or targets[element.original]
		if wanted then
			assert(capture.elements[index].valid and capture.rows[index].backend == wanted.backend
				and capture.rows[index].name == wanted.name and extras(capture.rows[index]) == extras(wanted),
				"saved model candidate differs from its requested owned fields or source kinds")
		else
			assert(not capture.elements[index].valid and capture.elements[index].raw == original.elements[element.original].raw,
				"saved model candidate changed an opaque invalid record")
		end
	end
end

--- Applies authenticated field edits only after ordinary writer rows preserve
--- this owner's exact list fragment; the writer retains final parse and CAS.
function M.apply(row, original, candidate)
	assert(M.authentic(row, original))
	local operation = operations[row]
	local capture = matching_capture(operation, candidate)
	local rendered, kept = render(capture, operation.desired, operation.mapping, {})
	validate_rendered(rendered, kept, operation.desired, operation.mapping, capture)
	operation.candidate, operation.kept, operation.applied_capture = rendered, kept, capture
	return rendered
end

--- Retains current origins and one acknowledged removal for an exact inverse.
--- External source drift withdraws the inverse; it cannot mint future fields.
function M.acknowledge(row, encoded)
	local operation = operations[row]
	assert(operation and encoded == operation.candidate, "saved model acknowledgement differs from its exact candidate")
	local origins, removed, retained = {}, {}, {}
	local prior = transitions[operation.path]
	if prior and prior.source ~= operation.source then prior = nil end
	for index, kept in ipairs(operation.kept) do
		if kept.original then retained[kept.original] = index end
	end
	for position, selected in ipairs(operation.mapping) do
		local key = origin_key(operation.desired[position])
		if key then
			for index, kept in ipairs(operation.kept) do
				if kept.original == selected or kept.restored and rawequal(kept.row, operation.desired[position]) then origins[key] = index end
			end
		end
	end
	for index, element in ipairs(operation.capture.elements) do
		if element.valid and not retained[index] then
			local before = #operation.kept + 1
			for position, kept in ipairs(operation.kept) do if not kept.original then before = position; break end end
			for position, kept in ipairs(operation.kept) do
				if kept.original and kept.original > index then before = position; break end
			end
			local entry = { raw = element.raw, literal = LeafRows.value_literal(operation.capture.rows[index]), before = before, order = index }
			local key = origin_key(operation.capture.rows[index])
			if key then removed[key] = entry end
			if prior then
				for alias, old_index in pairs(prior.origins) do if old_index == index then removed[alias] = entry end end
			end
		end
	end
	if prior then
		for alias, index in pairs(prior.origins) do if retained[index] then origins[alias] = retained[index] end end
	end
	local insert = operation.applied_capture.insert or operation.applied_capture.elements[1] and operation.applied_capture.elements[1].first
	transitions[operation.path] = { source = encoded, origins = origins, removed = removed, insert = insert }
end

--- Offers a whole row only when the actual reader reported that intrinsic
--- record and its canonical source still proves it invalid.
function M.cleanup_entries(source, outdated, file_path)
	local report_prefix, reported = KeyPath.render(Models.PATH) .. ".", false
	for path in pairs(outdated) do
		if path:sub(1, #report_prefix) == report_prefix and path:sub(#report_prefix + 1):match("^[1-9]%d*$") then
			reported = true
			break
		end
	end
	if not reported then return {}, false end
	local capture = M.capture(source)
	local entries = {}
	if not capture or capture.obsolete then return entries, false end
	for index, element in ipairs(capture.elements) do
		if not element.valid and outdated["llm.models.user_models." .. index] then
			local entry = { section = "llm.models.user_models", key = tostring(index), kind = "saved_model_record",
				path = { "llm", "models", "user_models", tostring(index) }, value = Codec.encode_value_with_shapes(capture.rows[index], capture.shapes, capture.rows, index), source_record = {} }
			removals[entry] = { source = source, index = index, raw = element.raw, path = entry.path, file_path = file_path, token = entry.source_record, value = entry.value }
			entries[#entries + 1] = entry
		end
	end
	return entries, true
end

--- Checks exact selection identity, fields, source, intrinsic kind and liveness.
--- @return boolean admitted
function M.cleanup_selection(source, entries, path)
	local seen, present = {}, false
	for _, entry in ipairs(entries) do
		local receipt = removals[entry]
		if receipt or entry.kind == "saved_model_record" or entry.source_record ~= nil then
			assert(receipt and not receipt.consumed and receipt.source == source
				and (path == nil or receipt.file_path == path), "saved model cleanup capability is unowned, stale or withdrawn")
			assert(entry.section == "llm.models.user_models" and entry.key == tostring(receipt.index)
				and entry.kind == "saved_model_record" and entry.value == receipt.value and rawequal(entry.source_record, receipt.token) and getmetatable(entry.source_record) == nil
				and getmetatable(entry) == nil and getmetatable(entry.path) == nil and rawequal(entry.path, receipt.path)
				and same(entry.path, { "llm", "models", "user_models", tostring(receipt.index) }), "saved model cleanup row changed")
			assert(not seen[receipt.index], "saved model cleanup row was selected twice")
			seen[receipt.index], present = true, true
		end
	end
	if present then
		local capture = assert(M.capture(source))
		for index in pairs(seen) do assert(capture.elements[index] and not capture.elements[index].valid
			and capture.elements[index].raw == source:sub(capture.elements[index].first, capture.elements[index].last), "saved model row is no longer invalid") end
		for _, entry in ipairs(entries) do
			if not removals[entry] and type(entry.path) == "table" then
				assert(not prefix(entry.path, Models.PATH) and not prefix(Models.PATH, entry.path), "saved model cleanup collides with another selection")
			end
		end
	end
	return present
end

--- Removes only minted invalid physical records from the unchanged array body.
function M.cleanup(source, candidate, entries)
	assert(M.cleanup_selection(source, entries))
	local original = assert(M.capture(source))
	local capture = matching_capture({ capture = original, source = source }, candidate)
	local desired, mapping, removed, count = {}, {}, {}, 0
	for _, entry in ipairs(entries) do
		local receipt = removals[entry]
		if receipt then removed[receipt.index] = true; count = count + 1 end
	end
	for index, element in ipairs(capture.elements) do
		if element.valid then desired[#desired + 1] = capture.rows[index]; mapping[#mapping + 1] = index end
	end
	local rendered, kept = render(capture, desired, mapping, removed)
	validate_rendered(rendered, kept, desired, mapping, capture)
	return rendered, count
end

--- Withdraws row capabilities only after acknowledged native cleanup.
function M.consume_cleanup(entries)
	for _, entry in ipairs(entries) do if removals[entry] then removals[entry].consumed = true end end
end

return M
